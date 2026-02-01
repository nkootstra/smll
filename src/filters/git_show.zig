const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const git_log = @import("git_log");
const git_diff = @import("git_diff");

pub fn matches(input: []const u8) bool {
    if (!git_log.matches(input)) return false;
    return findDiffStart(input) != null;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    const input = stdout;
    const diff_start = findDiffStart(input) orelse {
        return git_log.apply(allocator, input, &.{}, writer);
    };

    const header_end = stripTrailingBlankLines(input[0..diff_start]);
    try git_log.apply(allocator, input[0..header_end], &.{}, writer);
    try writer.writeAll("\n\n");
    try git_diff.apply(allocator, input[diff_start..], &.{}, writer);
}

fn findDiffStart(input: []const u8) ?usize {
    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];
        if (std.mem.startsWith(u8, line, "diff --git a/")) return line_start;
        if (i < input.len) i += 1;
    }
    return null;
}

fn stripTrailingBlankLines(header: []const u8) usize {
    var end = header.len;
    while (end > 0) {
        var line_start = end;
        if (header[end - 1] == '\n') {
            line_start = end - 1;
            while (line_start > 0 and header[line_start - 1] != '\n') line_start -= 1;
            const line = header[line_start .. end - 1];
            if (std.mem.trim(u8, line, " \t").len == 0) {
                end = line_start;
                continue;
            }
        }
        break;
    }
    return end;
}

const simple_fixture = @embedFile("fixture_git_show_simple");
const body_fixture = @embedFile("fixture_git_show_body");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: simple show fixture" {
    try std.testing.expect(matches(simple_fixture));
}

test "matches: body show fixture" {
    try std.testing.expect(matches(body_fixture));
}

test "matches: log-only (no diff) returns false" {
    const log_only = "commit abcdef0123456789abcdef0123456789abcdef01\nAuthor: x <x@x>\nDate:   Sat Apr 18 09:00:00 2026 +0000\n\n    subject\n";
    try std.testing.expect(!matches(log_only));
}

test "matches: diff-only (no commit) returns false" {
    const diff_only = "diff --git a/x b/x\nindex 0..1\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n";
    try std.testing.expect(!matches(diff_only));
}

test "matches: empty input returns false" {
    try std.testing.expect(!matches(""));
}

test "apply: compacts SHA on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit 95cbeda\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37") == null);
}

test "apply: strips email domain on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Author: Alice Anderson <alice>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@example.com") == null);
}

test "apply: compacts date on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Date:   2026-04-18") != null);
}

test "apply: drops index line in diff section on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "index ") == null);
}

test "apply: preserves diff --git header on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "diff --git a/a.txt b/a.txt") != null);
}

test "apply: preserves new file mode on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "new file mode 100644") != null);
}

test "apply: preserves added lines on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "+line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@@ -0,0 +1 @@") != null);
}

test "apply: preserves multi-line body on body show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, body_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    feat: extend a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    This body explains why we added a second line.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    It spans multiple lines and contains punctuation.") != null);
}

test "apply: preserves hunk and + lines on body show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, body_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@@ -1 +1,2 @@") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+line2") != null);
}

test "apply: directional compression on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < simple_fixture.len);
}

test "apply: directional compression on body show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, body_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < body_fixture.len);
}

test "apply: preserves trailing newline when input has one" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len > 0 and out[out.len - 1] == '\n');
}
