const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return std.mem.startsWith(u8, line, "diff --git a/");
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    const input = stdout;

    const had_trailing_newline = input.len > 0 and input[input.len - 1] == '\n';
    const content = if (had_trailing_newline) input[0 .. input.len - 1] else input;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_hunk = false;
    var first = true;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            in_hunk = false;
        } else if (std.mem.startsWith(u8, line, "@@")) {
            in_hunk = true;
        }

        if (!in_hunk and isDroppedHeaderLine(line)) continue;

        if (!first) try writer.writeByte('\n');
        try writer.writeAll(line);
        first = false;
    }
    if (had_trailing_newline) try writer.writeByte('\n');
}

fn isDroppedHeaderLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "index ") or
        std.mem.startsWith(u8, line, "similarity index ") or
        std.mem.startsWith(u8, line, "dissimilarity index ") or
        std.mem.startsWith(u8, line, "--- ") or
        std.mem.startsWith(u8, line, "+++ ");
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

const simple_fixture = @embedFile("fixture_git_diff_simple");
const multi_fixture = @embedFile("fixture_git_diff_multi");
const rename_fixture = @embedFile("fixture_git_diff_rename");
const rename_modify_fixture = @embedFile("fixture_git_diff_rename_modify");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: simple diff fixture" {
    try std.testing.expect(matches(simple_fixture));
}

test "matches: multi-file diff fixture" {
    try std.testing.expect(matches(multi_fixture));
}

test "matches: rename diff fixture" {
    try std.testing.expect(matches(rename_fixture));
}

test "matches: rename+modify diff fixture" {
    try std.testing.expect(matches(rename_modify_fixture));
}

test "matches: non-diff input returns false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("On branch main\n"));
    try std.testing.expect(!matches("commit abc123\nAuthor: x\n"));
    try std.testing.expect(!matches("some text with diff --git in middle\n"));
}

test "matches: leading blank lines are skipped" {
    try std.testing.expect(matches("\n\ndiff --git a/x b/x\n"));
}

test "apply: drops index line on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "index ") == null);
}

test "apply: drops --- a/ and +++ b/ twin on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "--- a/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+++ b/") == null);
}

test "apply: preserves diff --git header on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "diff --git a/simple.txt b/simple.txt") != null);
}

test "apply: preserves hunk header on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@@ -1 +1,3 @@") != null);
}

test "apply: preserves every + line on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "+line two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+line three") != null);
}

test "apply: preserves every file header on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "diff --git a/color.txt b/color.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "diff --git a/fruit.txt b/fruit.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "diff --git a/numbers.txt b/numbers.txt") != null);
}

test "apply: drops every index line on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "index ") == null);
}

test "apply: preserves +/- content lines on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "+green") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+blue") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-apple") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+banana") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "-two") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+TWO") != null);
}

test "apply: preserves context lines on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, " red") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " one") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " three") != null);
}

test "apply: drops similarity index on rename" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "similarity index ") == null);
}

test "apply: preserves rename from/to lines on rename" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "rename from fruit.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rename to produce.txt") != null);
}

test "apply: preserves diff --git header on rename" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "diff --git a/fruit.txt b/produce.txt") != null);
}

test "apply: drops similarity, index, and twin on rename+modify" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_modify_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "similarity index ") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "index ") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "--- a/") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+++ b/") == null);
}

test "apply: preserves rename from/to and hunk on rename+modify" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_modify_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "rename from old.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rename to new.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@@ -1,3 +1,4 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+date") != null);
}

test "apply: hunk-internal line starting with --- is preserved (state tracking)" {
    const allocator = std.testing.allocator;
    const input =
        "diff --git a/x b/x\n" ++
        "index abc..def 100644\n" ++
        "--- a/x\n" ++
        "+++ b/x\n" ++
        "@@ -1 +1 @@\n" ++
        "---- content\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "---- content") != null);
}

test "apply: directional compression on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(wordCount(out) < wordCount(simple_fixture));
}

test "apply: directional compression on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(wordCount(out) < wordCount(multi_fixture));
}

test "apply: preserves trailing newline when input has one" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len > 0 and out[out.len - 1] == '\n');
}
