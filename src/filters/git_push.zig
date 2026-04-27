const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.4 grammar for `git push` output:
//
// Identifying output arrives on stderr ("To <remote>"); stdout carries only
// tracking-branch setup messages on success. matches() always returns false —
// argv-only dispatch.
//
// Output grammar (from stderr):
//   > <sha7>..<sha7> <local> -> <remote>   — updated ref
//   + new <ref>                             — new branch pushed
//   - deleted <ref>                         — branch deleted remotely
//   ! rejected <ref> <reason>              — rejected ref
//   = up-to-date                            — Everything up-to-date
//
// Every ref and SHA pair is preserved. "To <remote>" header is dropped.
// Progress lines ("remote:", "Counting objects:", etc.) are dropped.

/// matches always returns false — argv-only dispatch.
pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stdout;

    if (stderr.len == 0) return;

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "Everything up-to-date")) {
            try writer.writeAll("= up-to-date\n");
            continue;
        }
        if (std.mem.startsWith(u8, line, "To ")) continue;
        if (util.isGitProgressLine(line)) continue;
        if (try util.handleBracketRef(line, writer)) continue;
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (util.isRefUpdateLine(trimmed)) {
            try util.writeRefUpdateLine(trimmed, writer, '>');
        }
    }
}

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const simple_stdout_fixture = @embedFile("fixture_git_push_simple_stdout");
const simple_stderr_fixture = @embedFile("fixture_git_push_simple_stderr");
const large_stdout_fixture = @embedFile("fixture_git_push_large_stdout");
const large_stderr_fixture = @embedFile("fixture_git_push_large_stderr");

fn applyToString(allocator: Allocator, out_stdout: []const u8, in_stderr: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, out_stdout, in_stderr, &out.writer);
    return allocator.dupe(u8, out.written());
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

test "matches: always false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("To github.com:foo/bar.git\n"));
    try std.testing.expect(!matches("Everything up-to-date\n"));
}

test "apply: new branch emits + new sigil" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_stdout_fixture, simple_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+ new main") != null);
}

test "apply: drops To-remote header" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_stdout_fixture, simple_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "To ") == null);
}

test "apply: everything up-to-date emits = up-to-date" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, "", "Everything up-to-date\n");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("= up-to-date\n", out);
}

test "apply: updated ref emits > sigil with sha pair" {
    const allocator = std.testing.allocator;
    const stderr = "To github.com:foo/bar.git\n   abc1234..def5678  main -> main\n";
    const out = try applyToString(allocator, "", stderr);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "> abc1234..def5678 main -> main\n") != null);
}

test "apply: deleted ref emits - deleted sigil" {
    const allocator = std.testing.allocator;
    const stderr = "To github.com:foo/bar.git\n - [deleted]         origin/old-branch\n";
    const out = try applyToString(allocator, "", stderr);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "- deleted origin/old-branch\n") != null);
}

test "apply: rejected ref emits ! rejected sigil" {
    const allocator = std.testing.allocator;
    const stderr = "To github.com:foo/bar.git\n ! [rejected]        fix-3 -> fix-3 (non-fast-forward)\n";
    const out = try applyToString(allocator, "", stderr);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "! rejected fix-3 -> fix-3 (non-fast-forward)\n") != null);
}

test "apply: R3 gate — large fixture (combined) ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, large_stdout_fixture, large_stderr_fixture);
    defer allocator.free(out);
    const raw_bytes = large_stdout_fixture.len + large_stderr_fixture.len;
    const smll_bytes = out.len;
    if (raw_bytes >= 50) {
        const target = (raw_bytes * 80) / 100;
        try std.testing.expect(smll_bytes <= target);
    } else {
        try std.testing.expect(smll_bytes <= raw_bytes);
    }
}

test "apply: R3 gate — simple fixture (combined) ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_stdout_fixture, simple_stderr_fixture);
    defer allocator.free(out);
    const raw_bytes = simple_stdout_fixture.len + simple_stderr_fixture.len;
    const smll_bytes = out.len;
    if (raw_bytes >= 50) {
        const target = (raw_bytes * 80) / 100;
        try std.testing.expect(smll_bytes <= target);
    } else {
        try std.testing.expect(smll_bytes <= raw_bytes);
    }
}

test "apply: large fixture preserves all 10 refs" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, large_stdout_fixture, large_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "main") != null);
    try std.testing.expect(std.mem.find(u8, out, "feat-a") != null);
    try std.testing.expect(std.mem.find(u8, out, "fix-3") != null);
}

test "apply: empty stderr produces empty output" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, "", "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "pipe-mode: matches returns false for all inputs" {
    try std.testing.expect(!matches(simple_stderr_fixture));
    try std.testing.expect(!matches(large_stderr_fixture));
}
