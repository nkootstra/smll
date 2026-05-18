const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// `git reflog` default format:
//
//   <sha7> HEAD@{N}: <op>: <subject>
//
// Compaction:
//   • Drop the `HEAD@{` and `}` scaffolding around N; keep `@N` so the
//     identifier remains actionable (`git reset @5` is not valid, but
//     the agent can reconstruct `HEAD@{5}` from `@5`). Saves ~7 bytes
//     per line on typical reflog entries.
//   • SHA-prefix RLE: consecutive entries with the same SHA omit the SHA
//     on subsequent lines (replaced by an equivalent leading 7-space
//     gutter so column alignment is preserved). Triggers on runs of 2+.
//   • Unknown line shapes pass through verbatim.

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return isReflogLine(line);
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var prev_sha: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 };
    var run_len: usize = 0;

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const parsed = parseLine(line) orelse {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            run_len = 0;
            continue;
        };

        const same_sha = run_len > 0 and std.mem.eql(u8, &prev_sha, &parsed.sha);
        if (same_sha) {
            // SHA-prefix RLE — 7-space gutter preserves column alignment.
            try writer.writeAll("       ");
        } else {
            try writer.writeAll(&parsed.sha);
            prev_sha = parsed.sha;
            run_len = 0;
        }
        try writer.writeAll(" @");
        try writer.writeAll(parsed.index);
        try writer.writeByte(' ');
        try writer.writeAll(parsed.rest);
        try writer.writeByte('\n');
        run_len += 1;
    }
}

const ParsedLine = struct {
    sha: [7]u8,
    index: []const u8,
    rest: []const u8,
};

fn parseLine(line: []const u8) ?ParsedLine {
    // Minimum shape: "1234567 HEAD@{0}: x"
    if (line.len < 19) return null;
    if (!isHex(line[0]) or !isHex(line[1]) or !isHex(line[2]) or
        !isHex(line[3]) or !isHex(line[4]) or !isHex(line[5]) or
        !isHex(line[6])) return null;
    if (line[7] != ' ') return null;
    if (!std.mem.startsWith(u8, line[8..], "HEAD@{")) return null;
    const after_brace = line[14..];
    const close = std.mem.indexOfScalar(u8, after_brace, '}') orelse return null;
    if (close == 0) return null;
    const index = after_brace[0..close];
    for (index) |c| if (c < '0' or c > '9') return null;
    const after_close = after_brace[close + 1 ..];
    if (!std.mem.startsWith(u8, after_close, ": ")) return null;
    const rest = after_close[2..];
    return .{
        .sha = .{ line[0], line[1], line[2], line[3], line[4], line[5], line[6] },
        .index = index,
        .rest = rest,
    };
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

fn isReflogLine(line: []const u8) bool {
    return parseLine(line) != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @embedFile("fixture_git_reflog");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: fixture is detected as reflog" {
    try std.testing.expect(matches(fixture));
}

test "matches: non-reflog input is rejected" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("On branch main\n"));
    try std.testing.expect(!matches("commit abc1234\nAuthor: Foo\n"));
}

test "apply: single line drops HEAD@{N} scaffolding" {
    const allocator = std.testing.allocator;
    const input = "1a1f2f7 HEAD@{0}: checkout: moving from main to feature\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "1a1f2f7 @0 checkout: moving from main to feature\n",
        out,
    );
}

test "apply: consecutive same-sha entries collapse to a gutter" {
    const allocator = std.testing.allocator;
    const input =
        "1edb490 HEAD@{4}: checkout: a to b\n" ++
        "1edb490 HEAD@{5}: pull --ff-only: Fast-forward\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "1edb490 @4 checkout: a to b\n" ++
            "        @5 pull --ff-only: Fast-forward\n",
        out,
    );
}

test "apply: sha change breaks the run" {
    const allocator = std.testing.allocator;
    const input =
        "1edb490 HEAD@{4}: checkout: a\n" ++
        "78a9d9e HEAD@{5}: checkout: b\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "1edb490 @4 checkout: a\n" ++
            "78a9d9e @5 checkout: b\n",
        out,
    );
}

test "apply: unknown line shape passes through verbatim" {
    const allocator = std.testing.allocator;
    const input =
        "1a1f2f7 HEAD@{0}: commit: foo\n" ++
        "warning: something\n" ++
        "1a1f2f7 HEAD@{1}: commit: bar\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    // The warning resets the run, so the second 1a1f2f7 emits its SHA again.
    try std.testing.expectEqualStrings(
        "1a1f2f7 @0 commit: foo\n" ++
            "warning: something\n" ++
            "1a1f2f7 @1 commit: bar\n",
        out,
    );
}

test "apply: fixture compresses and preserves every distinct SHA + index" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < fixture.len);
    // Every SHA from the fixture remains discoverable in the output.
    const shas = [_][]const u8{
        "1a1f2f7", "1edb490", "a8b4598", "78a9d9e", "474d0d9", "9ce95e8", "5a7170a",
    };
    for (shas) |sha| {
        try std.testing.expect(std.mem.find(u8, out, sha) != null);
    }
    // Every index 0..11 remains discoverable as `@N`.
    var n: u8 = 0;
    while (n < 12) : (n += 1) {
        var idx_buf: [4]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "@{d}", .{n}) catch unreachable;
        try std.testing.expect(std.mem.find(u8, out, idx_str) != null);
    }
}

test "apply: empty input produces empty output" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}
