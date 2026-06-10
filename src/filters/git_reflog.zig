const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// `git reflog` / `git reflog <ref>` / `git reflog show stash` format:
//
//   <sha7> <ref>@{N}: <op>: <subject>     (<ref> = HEAD, stash, branch…)
//
// Compaction:
//   • Drop the `@{` and `}` scaffolding around N. For the implicit HEAD ref
//     keep just `@N`; for any other ref keep `ref@N` (e.g. `stash@0`,
//     `main@2`) so the identifier remains reconstructible.
//   • SHA-prefix RLE: consecutive entries with the same SHA replace the SHA
//     on subsequent lines with a single `~` sigil. Triggers on runs of 2+.
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
            // SHA-prefix RLE — a single `~` sigil marks "same SHA as above".
            try writer.writeByte('~');
        } else {
            try writer.writeAll(&parsed.sha);
            prev_sha = parsed.sha;
            run_len = 0;
        }
        try writer.writeByte(' ');
        // HEAD is the implicit ref — drop it (`@N`). Any other ref (stash,
        // branch name) is kept so the identifier stays reconstructible (`ref@N`).
        if (!std.mem.eql(u8, parsed.ref, "HEAD")) {
            try writer.writeAll(parsed.ref);
        }
        try writer.writeByte('@');
        try writer.writeAll(parsed.index);
        try writer.writeByte(' ');
        try writer.writeAll(parsed.rest);
        try writer.writeByte('\n');
        run_len += 1;
    }
}

const ParsedLine = struct {
    sha: [7]u8,
    ref: []const u8,
    index: []const u8,
    rest: []const u8,
};

fn parseLine(line: []const u8) ?ParsedLine {
    // Shape: "<sha7> <ref>@{N}: <rest>" where <ref> is HEAD, stash, or a
    // branch name. Minimum is "1234567 X@{0}: y" (16 bytes).
    if (line.len < 16) return null;
    if (!isHex(line[0]) or !isHex(line[1]) or !isHex(line[2]) or
        !isHex(line[3]) or !isHex(line[4]) or !isHex(line[5]) or
        !isHex(line[6])) return null;
    if (line[7] != ' ') return null;
    const after_sha = line[8..];
    // The ref is the token before "@{". Branch names cannot contain "@{"
    // or whitespace, so this split is unambiguous across HEAD/stash/branch.
    const at_brace = std.mem.indexOf(u8, after_sha, "@{") orelse return null;
    if (at_brace == 0) return null; // empty ref
    const ref = after_sha[0..at_brace];
    if (std.mem.indexOfScalar(u8, ref, ' ') != null) return null;
    const after_brace = after_sha[at_brace + "@{".len ..];
    const close = std.mem.indexOfScalar(u8, after_brace, '}') orelse return null;
    if (close == 0) return null;
    const index = after_brace[0..close];
    for (index) |c| if (c < '0' or c > '9') return null;
    const after_close = after_brace[close + 1 ..];
    if (!std.mem.startsWith(u8, after_close, ": ")) return null;
    const rest = after_close[2..];
    return .{
        .sha = .{ line[0], line[1], line[2], line[3], line[4], line[5], line[6] },
        .ref = ref,
        .index = index,
        .rest = rest,
    };
}

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
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
            "~ @5 pull --ff-only: Fast-forward\n",
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

test "apply: stash reflog ref is preserved as stash@N" {
    // Real `git reflog show stash` line.
    const allocator = std.testing.allocator;
    const input = "de9b67d stash@{0}: WIP on main: 05132ce second commit on main\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "de9b67d stash@0 WIP on main: 05132ce second commit on main\n",
        out,
    );
}

test "apply: branch reflog ref is preserved as branch@N" {
    // Real `git reflog main` line.
    const allocator = std.testing.allocator;
    const input = "05132ce main@{0}: commit: second commit on main\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "05132ce main@0 commit: second commit on main\n",
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
