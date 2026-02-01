const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return std.mem.startsWith(u8, line, "On branch ") or
            std.mem.startsWith(u8, line, "HEAD detached ") or
            std.mem.startsWith(u8, line, "interactive rebase in progress");
    }
    return false;
}

pub fn apply(allocator: Allocator, input: []const u8, writer: *Writer) !void {
    _ = allocator;

    const had_trailing_newline = input.len > 0 and input[input.len - 1] == '\n';
    const content = if (had_trailing_newline) input[0 .. input.len - 1] else input;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    var prev_blank = false;
    while (lines.next()) |line| {
        if (isHintLine(line)) continue;

        const is_blank = std.mem.trim(u8, line, " \t").len == 0;
        if (is_blank and prev_blank) continue;

        if (!first) try writer.writeByte('\n');
        try writer.writeAll(line);
        first = false;
        prev_blank = is_blank;
    }
    if (had_trailing_newline) try writer.writeByte('\n');
}

fn isHintLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "  (") and std.mem.endsWith(u8, line, ")");
}

fn wordCount(s: []const u8) usize {
    var count: usize = 0;
    var in_word = false;
    for (s) |c| {
        const is_space = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        if (!is_space and !in_word) count += 1;
        in_word = !is_space;
    }
    return count;
}

const dirty_fixture = @embedFile("fixture_git_status_dirty");
const clean_fixture = @embedFile("fixture_git_status_clean");
const conflict_fixture = @embedFile("fixture_git_status_conflict");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: dirty fixture" {
    try std.testing.expect(matches(dirty_fixture));
}

test "matches: clean fixture" {
    try std.testing.expect(matches(clean_fixture));
}

test "matches: conflict fixture" {
    try std.testing.expect(matches(conflict_fixture));
}

test "matches: detached HEAD" {
    try std.testing.expect(matches("HEAD detached at abc123\n"));
}

test "matches: interactive rebase" {
    try std.testing.expect(matches("interactive rebase in progress; onto main\n"));
}

test "matches: leading blank line is skipped" {
    try std.testing.expect(matches("\n\nOn branch main\n"));
}

test "matches: non-git input returns false" {
    try std.testing.expect(!matches("some random text\nnot a git status\n"));
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("error: fatal: not a git repository\n"));
}

test "apply: self-recognizable on dirty" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    try std.testing.expect(matches(out));
}

test "apply: self-recognizable on clean" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, clean_fixture);
    defer allocator.free(out);
    try std.testing.expect(matches(out));
}

test "apply: self-recognizable on conflict" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, conflict_fixture);
    defer allocator.free(out);
    try std.testing.expect(matches(out));
}

test "apply: preserves every file path verbatim on dirty" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    const paths = [_][]const u8{
        "\tmodified:   src/main.zig",
        "\tmodified:   src/pipeline.zig",
        "\tsrc/filters/git_status.zig",
        "\ttests/fixtures/git_status_dirty.txt",
    };
    for (paths) |p| {
        try std.testing.expect(std.mem.indexOf(u8, out, p) != null);
    }
}

test "apply: preserves both modified: path on conflict" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, conflict_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\tboth modified:   src/filters/git_status.zig") != null);
}

test "apply: drops hint lines on dirty" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(use \"git add <file>...\" to update") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(use \"git restore <file>...\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(use \"git add <file>...\" to include") == null);
}

test "apply: preserves section headers" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Changes not staged for commit:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Untracked files:") != null);
}

test "apply: collapses consecutive blank lines" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, "On branch main\n\n\n\nmodified: x\n");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n\n\n") == null);
}

test "apply: directional compression on dirty fixture (wc -w style)" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    const before = wordCount(dirty_fixture);
    const after = wordCount(out);
    try std.testing.expect(after < before);
}
