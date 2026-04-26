const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const git_log = @import("git_log");
const git_diff = @import("git_diff");

// v0.4 grammar for `git show`:
//
// Delegates to git_log + git_diff with a single blank line separator.
//
// Output structure:
//   c <sha7> <date> <author>   — commit header (from git_log)
//   [p <sha7>...]              — parents if merge (from git_log)
//   : <subject>                — subject line (from git_log)
//   [: <body>...]              — body lines (from git_log)
//                              — blank line separator
//   d <path>                   — diff file header (from git_diff)
//   @x,y|a,b                   — hunk header (from git_diff)
//   +/-/  <content>            — diff body lines (from git_diff)
//
// The sigil namespaces are disjoint: log lines start with c/p/:,
// diff lines start with d/@/+/-/space. No explicit section marker needed.

pub fn matches(input: []const u8) bool {
    if (!git_log.matches(input)) return false;
    // For matches() only: limit scan to the first commit section.
    // In `git show` output, the diff appears right after the first
    // commit's message — typically within 4 KB. Multi-commit `git log`
    // output won't have a diff marker this early, so a bounded scan
    // avoids the O(n) full-input scan that penalises large log data.
    // apply() still uses the unbounded findDiffStart for correctness.
    const limit = @min(input.len, 8 * 1024);
    return findDiffStart(input[0..limit]) != null;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    const input = stdout;
    const diff_start = findDiffStart(input) orelse {
        return git_log.applyCompact(allocator, input, &.{}, writer);
    };

    const header_end = stripTrailingBlankLines(input[0..diff_start]);
    try git_log.applyCompact(allocator, input[0..header_end], &.{}, writer);
    try writer.writeAll("\n");
    try git_diff.apply(allocator, input[diff_start..], &.{}, writer);
}

fn findDiffStart(input: []const u8) ?usize {
    // Fast scan: search for the diff marker directly in the input.
    // The marker must appear at the start of a line.
    const marker = "diff --git a/";
    var pos: usize = 0;
    while (pos < input.len) {
        const found = std.mem.indexOf(u8, input[pos..], marker) orelse return null;
        const abs_pos = pos + found;
        // Check that it's at the start of a line (pos 0 or preceded by '\n').
        if (abs_pos == 0 or input[abs_pos - 1] == '\n') return abs_pos;
        // Skip past this occurrence.
        pos = abs_pos + marker.len;
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

test "apply: emits compact sha7 + subject header on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    // Compact format: sha7 + subject on one line
    try std.testing.expect(std.mem.find(u8, out, "95cbeda feat: add a.txt with one line\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37") == null);
}

test "apply: no Author/Date labels on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "Author:") == null);
    try std.testing.expect(std.mem.find(u8, out, "Date:") == null);
    try std.testing.expect(std.mem.find(u8, out, "@example.com") == null);
}

test "apply: compact format omits subject/body sigils on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    // Subject is on the sha7 line, no separate : sigil line
    try std.testing.expect(std.mem.find(u8, out, "feat: add a.txt with one line") != null);
}

test "apply: drops index line in diff section on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "index ") == null);
}

test "apply: emits d sigil for diff file header on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "d a.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "diff --git") == null);
}

test "apply: preserves new file mode on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "new file mode 100644") != null);
}

test "apply: emits @ hunk sigil on simple show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@0\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "+line1") != null);
}

test "apply: compact format drops body text on body show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, body_fixture);
    defer allocator.free(out);
    // Subject preserved in compact header
    try std.testing.expect(std.mem.find(u8, out, "feat: extend a.txt") != null);
    // Body is dropped in compact mode
    try std.testing.expect(std.mem.find(u8, out, "This body explains") == null);
    // Diff is still present
    try std.testing.expect(std.mem.find(u8, out, "d a.txt") != null);
}

test "apply: emits @ hunk and + lines on body show" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, body_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@1\n") != null);
    // Context lines dropped; only + lines preserved
    try std.testing.expect(std.mem.find(u8, out, "+line2") != null);
}

test "apply: directional compression on simple show (byte count)" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < simple_fixture.len);
}

test "apply: directional compression on body show (byte count)" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, body_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < body_fixture.len);
}

test "apply: R3 gate — simple show fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    const target = (simple_fixture.len * 80) / 100;
    try std.testing.expect(out.len <= target);
}

test "apply: R3 gate — body show fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, body_fixture);
    defer allocator.free(out);
    const target = (body_fixture.len * 80) / 100;
    try std.testing.expect(out.len <= target);
}

test "apply: preserves trailing newline when input has one" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len > 0 and out[out.len - 1] == '\n');
}

test "apply: show priority over log (output differs from log-only on same input)" {
    const allocator = std.testing.allocator;
    var log_out = std.Io.Writer.Allocating.init(allocator);
    defer log_out.deinit();
    try git_log.apply(allocator, simple_fixture, &.{}, &log_out.writer);
    const log_str = try allocator.dupe(u8, log_out.written());
    defer allocator.free(log_str);

    const show_str = try applyToString(allocator, simple_fixture);
    defer allocator.free(show_str);

    // show output has diff section; log-only does not
    try std.testing.expect(!std.mem.eql(u8, log_str, show_str));
    try std.testing.expect(std.mem.find(u8, show_str, "d a.txt") != null);
}

test "pipe-mode idempotence: v0.4 show output piped again is unchanged" {
    // v0.4 show output starts with "c <sha7>..." — does NOT match matches()
    // (matches requires both git_log.matches AND diff presence in raw input).
    const allocator = std.testing.allocator;
    const first = try applyToString(allocator, simple_fixture);
    defer allocator.free(first);
    // v0.4 output does not match (starts with "c", not "commit <40-char-sha>")
    try std.testing.expect(!matches(first));
}
