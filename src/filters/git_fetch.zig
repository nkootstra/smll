const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.4 grammar for `git fetch` output:
//
// All identifying output arrives on stderr ("From <remote>" + ref summary).
// stdout is empty on success. matches() always returns false — argv-only dispatch.
//
// Output grammar (from stderr):
//   < <sha7>..<sha7> <remote> -> <local>  — updated ref
//   + new <ref>                           — new remote-tracking branch/tag
//   - deleted <ref>                       — pruned remote-tracking ref
//   ! rejected <ref> <reason>            — rejected ref
//
// "From <remote>", "* branch ... -> FETCH_HEAD", and progress lines are dropped.
//
// Note: no large fixture for git_fetch. The simple fixture (~73 B stderr)
// passes R3 on its own; add large fixture in Unit 9 if needed.

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stdout;
    try util.processRefStderr(stderr, writer, '<', "From ", "-> FETCH_HEAD");
}

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const simple_stdout_fixture = @embedFile("fixture_git_fetch_simple_stdout");
const simple_stderr_fixture = @embedFile("fixture_git_fetch_simple_stderr");

fn applyToString(allocator: Allocator, in_stdout: []const u8, in_stderr: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, in_stdout, in_stderr, &out.writer);
    return allocator.dupe(u8, out.written());
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

test "matches: always false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("From github.com:foo/bar.git\n"));
}

test "apply: simple fetch emits < ref row" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_stdout_fixture, simple_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "< 2cee6f5..81a7b77") != null);
}

test "apply: drops From-remote header" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_stdout_fixture, simple_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "From ") == null);
}

test "apply: drops FETCH_HEAD lines" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_stdout_fixture, simple_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "FETCH_HEAD") == null);
}

test "apply: new remote-tracking branch emits + new" {
    const allocator = std.testing.allocator;
    const stderr = "From github.com:foo/bar.git\n * [new branch]      feat-x -> origin/feat-x\n";
    const out = try applyToString(allocator, "", stderr);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+ new feat-x") != null);
}

test "apply: deleted remote branch emits - deleted" {
    const allocator = std.testing.allocator;
    const stderr = "From github.com:foo/bar.git\n - [deleted]         origin/old-feat\n";
    const out = try applyToString(allocator, "", stderr);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "- deleted origin/old-feat\n") != null);
}

test "apply: two ref updates produce two < rows" {
    const allocator = std.testing.allocator;
    const stderr =
        "From github.com:foo/bar.git\n" ++
        "   abc1234..def5678  main -> origin/main\n" ++
        "   111aaaa..222bbbb  feat -> origin/feat\n";
    const out = try applyToString(allocator, "", stderr);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "< abc1234..def5678") != null);
    try std.testing.expect(std.mem.find(u8, out, "< 111aaaa..222bbbb") != null);
}

test "apply: R3 gate — simple fixture ≤ 80% of raw" {
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

test "apply: empty stderr produces empty output" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, "", "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "pipe-mode: matches returns false for fixture stderr" {
    try std.testing.expect(!matches(simple_stderr_fixture));
}
