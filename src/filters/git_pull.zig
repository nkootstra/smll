const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.4 grammar for `git pull` output:
//
// stderr: "From <remote>" + per-ref summary lines.
// stdout: merge result ("Updating abc..def", "Fast-forward", "Already up to date.").
//
// matches() always returns false — argv-only dispatch.
//
// Output grammar:
//   < <sha7>..<sha7> <remote> -> <local>  — incoming ref (from stderr)
//   @ fast-forward <range>               — fast-forward merge (from stdout)
//   @ up-to-date                         — already up to date (from stdout)
//   @ merge-commit [<range>]             — true merge created (from stdout)

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;

    if (stderr.len > 0) {
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "From ")) continue;
            if (util.isGitProgressLine(line)) continue;
            if (std.mem.find(u8, line, "-> FETCH_HEAD") != null) continue;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (util.isRefUpdateLine(trimmed)) {
                try util.writeRefUpdateLine(trimmed, writer, '<');
            }
        }
    }

    if (stdout.len > 0) {
        if (std.mem.find(u8, stdout, "Already up to date.") != null) {
            try writer.writeAll("@ up-to-date\n");
            return;
        }

        var updating_range: ?[]const u8 = null;
        var is_fast_forward = false;
        var is_merge = false;

        var lines = std.mem.splitScalar(u8, stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "Updating ")) {
                updating_range = line["Updating ".len..];
            } else if (std.mem.eql(u8, line, "Fast-forward") or
                std.mem.startsWith(u8, line, "Fast forward"))
            {
                is_fast_forward = true;
            } else if (std.mem.startsWith(u8, line, "Merge made by")) {
                is_merge = true;
            }
        }

        if (is_fast_forward) {
            if (updating_range) |range| {
                try writer.writeAll("@ fast-forward ");
                try writer.writeAll(range);
                try writer.writeByte('\n');
            } else {
                try writer.writeAll("@ fast-forward\n");
            }
        } else if (is_merge) {
            if (updating_range) |range| {
                try writer.writeAll("@ merge-commit ");
                try writer.writeAll(range);
                try writer.writeByte('\n');
            } else {
                try writer.writeAll("@ merge-commit\n");
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

const ff_stdout_fixture = @embedFile("fixture_git_pull_ff_stdout");
const ff_stderr_fixture = @embedFile("fixture_git_pull_ff_stderr");
const uptodate_stdout_fixture = @embedFile("fixture_git_pull_uptodate_stdout");
const uptodate_stderr_fixture = @embedFile("fixture_git_pull_uptodate_stderr");

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
    try std.testing.expect(!matches("Already up to date.\n"));
}

test "apply: fast-forward emits @ fast-forward line" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, ff_stdout_fixture, ff_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@ fast-forward") != null);
}

test "apply: fast-forward emits incoming < ref row" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, ff_stdout_fixture, ff_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "< 43fe7da..2cee6f5") != null);
}

test "apply: fast-forward preserves SHA range" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, ff_stdout_fixture, ff_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "43fe7da..2cee6f5") != null);
}

test "apply: already up-to-date emits @ up-to-date" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, uptodate_stdout_fixture, uptodate_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@ up-to-date\n") != null);
}

test "apply: drops From-remote header" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, ff_stdout_fixture, ff_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "From ") == null);
}

test "apply: drops FETCH_HEAD lines" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, ff_stdout_fixture, ff_stderr_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "FETCH_HEAD") == null);
}

test "apply: stderr-only (no merge stdout) produces valid output" {
    const allocator = std.testing.allocator;
    const stderr = "From github.com:foo/bar.git\n   abc1234..def5678  main -> origin/main\n";
    const out = try applyToString(allocator, "", stderr);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "< abc1234..def5678") != null);
}

test "apply: R3 gate — ff fixture (combined) ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, ff_stdout_fixture, ff_stderr_fixture);
    defer allocator.free(out);
    const raw_bytes = ff_stdout_fixture.len + ff_stderr_fixture.len;
    const smll_bytes = out.len;
    if (raw_bytes >= 50) {
        const target = (raw_bytes * 80) / 100;
        try std.testing.expect(smll_bytes <= target);
    } else {
        try std.testing.expect(smll_bytes <= raw_bytes);
    }
}

test "apply: R3 gate — up-to-date fixture (combined) ≤ raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, uptodate_stdout_fixture, uptodate_stderr_fixture);
    defer allocator.free(out);
    const raw_bytes = uptodate_stdout_fixture.len + uptodate_stderr_fixture.len;
    const smll_bytes = out.len;
    if (raw_bytes >= 50) {
        const target = (raw_bytes * 80) / 100;
        try std.testing.expect(smll_bytes <= target);
    } else {
        try std.testing.expect(smll_bytes <= raw_bytes);
    }
}

test "apply: merge-commit case emits @ merge-commit" {
    const allocator = std.testing.allocator;
    const stdout_in =
        "Merge made by the 'ort' strategy.\n" ++
        " x.txt | 1 +\n" ++
        " 1 file changed, 1 insertion(+)\n";
    const stderr_in = "From github.com:foo/bar.git\n   abc1234..def5678  main -> origin/main\n";
    const out = try applyToString(allocator, stdout_in, stderr_in);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@ merge-commit") != null);
}

test "pipe-mode: matches returns false for fixture output" {
    try std.testing.expect(!matches(ff_stdout_fixture));
    try std.testing.expect(!matches(ff_stderr_fixture));
    try std.testing.expect(!matches(uptodate_stdout_fixture));
}
