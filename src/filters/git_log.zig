const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return isCommitLine(line);
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
    var first = true;
    while (lines.next()) |line| {
        if (!first) try writer.writeByte('\n');
        try writeTransformed(writer, line);
        first = false;
    }
    if (had_trailing_newline) try writer.writeByte('\n');
}

fn writeTransformed(writer: *Writer, line: []const u8) !void {
    if (isCommitLine(line)) {
        try writer.writeAll("commit ");
        try writer.writeAll(line[7..][0..7]);
        return;
    }
    if (std.mem.startsWith(u8, line, "Author: ")) {
        if (std.mem.indexOfScalar(u8, line, '@')) |at| {
            try writer.writeAll(line[0..at]);
            try writer.writeAll(">");
            return;
        }
    }
    if (std.mem.startsWith(u8, line, "Date:")) {
        if (try writeCompactDate(writer, line)) return;
    }
    try writer.writeAll(line);
}

fn writeCompactDate(writer: *Writer, line: []const u8) !bool {
    var prefix_end: usize = "Date:".len;
    while (prefix_end < line.len and (line[prefix_end] == ' ' or line[prefix_end] == '\t')) {
        prefix_end += 1;
    }
    const rest = line[prefix_end..];
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    _ = it.next() orelse return false;
    const month_abbr = it.next() orelse return false;
    const day_str = it.next() orelse return false;
    _ = it.next() orelse return false;
    const year_str = it.next() orelse return false;

    const month = monthNumber(month_abbr) orelse return false;
    const day = std.fmt.parseInt(u8, day_str, 10) catch return false;
    if (day < 1 or day > 31) return false;
    if (year_str.len != 4) return false;
    for (year_str) |c| if (!std.ascii.isDigit(c)) return false;

    try writer.writeAll(line[0..prefix_end]);
    try writer.print("{s}-{d:0>2}-{d:0>2}", .{ year_str, month, day });
    return true;
}

fn monthNumber(abbr: []const u8) ?u8 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (months, 0..) |m, i| {
        if (std.mem.eql(u8, abbr, m)) return @intCast(i + 1);
    }
    return null;
}

fn isCommitLine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "commit ")) return false;
    if (line.len < 7 + 40) return false;
    const sha = line[7..][0..40];
    for (sha) |c| if (!std.ascii.isHex(c)) return false;
    if (line.len > 7 + 40) {
        const c = line[7 + 40];
        if (c != ' ' and c != '\t') return false;
    }
    return true;
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

const linear_fixture = @embedFile("fixture_git_log_linear");
const merge_fixture = @embedFile("fixture_git_log_merge");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: linear fixture" {
    try std.testing.expect(matches(linear_fixture));
}

test "matches: merge fixture" {
    try std.testing.expect(matches(merge_fixture));
}

test "matches: leading blank lines are skipped" {
    try std.testing.expect(matches("\n\ncommit abcdef0123456789abcdef0123456789abcdef01\n"));
}

test "matches: non-log input returns false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("On branch main\n"));
    try std.testing.expect(!matches("diff --git a/x b/x\n"));
    try std.testing.expect(!matches("commit short\n"));
    try std.testing.expect(!matches("commit g0ad49edaad09b3977b23cc38c5552c76734c2de\n"));
}

test "apply: truncates commit SHA to 7 chars" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit f0ad49e\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit f666a84\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit 95cbeda\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "f0ad49edaad09b3977b23cc38c5552c76734c2de") == null);
}

test "apply: strips email domain from Author line" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Author: Alice Anderson <alice>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@example.com") == null);
}

test "apply: compacts Date to YYYY-MM-DD" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Date:   2026-04-18") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Sat Apr 18") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "+0200") == null);
}

test "apply: preserves commit subjects verbatim" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    fix: third line") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    feat: extend a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    feat: add a.txt with one line") != null);
}

test "apply: preserves multi-line commit body verbatim" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "    This body explains why we added a second line.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    It spans multiple lines and contains punctuation.") != null);
}

test "apply: preserves Merge: line on merge fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Merge: 50c52b3 cb42c80") != null);
}

test "apply: compacts every commit SHA on merge fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit 012aa35\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit 50c52b3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit cb42c80\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit f0ad49e\n") != null);
}

test "apply: directional compression on linear fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < linear_fixture.len);
    _ = wordCount(out);
}

test "apply: directional compression on merge fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < merge_fixture.len);
}

test "apply: preserves trailing newline when input has one" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len > 0 and out[out.len - 1] == '\n');
}

test "apply: author without @ passes through unchanged" {
    const allocator = std.testing.allocator;
    const input = "commit abcdef0123456789abcdef0123456789abcdef01\nAuthor: Just A Name\nDate:   Sat Apr 18 09:00:00 2026 +0000\n\n    subject\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Author: Just A Name\n") != null);
}

test "apply: malformed Date passes through unchanged" {
    const allocator = std.testing.allocator;
    const input = "commit abcdef0123456789abcdef0123456789abcdef01\nAuthor: n <n@n>\nDate:   garbage\n\n    subject\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Date:   garbage") != null);
}
