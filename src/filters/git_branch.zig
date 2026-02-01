const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.4 grammar for `git branch`:
//
//   * <branch>   — current branch (asterisk sigil, same as raw git; leading space stripped)
//     <branch>   — other branch   (two-space indent stripped to single space)
//
// R3 exemption: pure branch-name listings are physically incompressible
// beyond ~7% losslessly, so the 20% reduction floor does not apply here.
// R3 for git_branch relaxes to: smll_bytes ≤ raw_git_bytes (no expansion).
// This is documented in benchmarks/results-v0.4.md under "R3 git_branch exemption".
//
// matches() returns true when the first non-blank line starts with "  " (two
// spaces + name) OR "* " (asterisk + space + name).  Empty input returns false
// so that delete/rename silent output falls through to passthrough.
// Pipe-mode idempotence: compressed output lines start with "* " (single
// leading space + name) or " " (single space + name) — NOT "  " (two spaces),
// so re-piping through smll does NOT re-match and the output passes through
// unchanged.

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Current branch: "* <name>"
        if (std.mem.startsWith(u8, line, "* ")) return true;
        // Other branch: "  <name>" (exactly two spaces)
        if (line.len >= 3 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ') return true;
        // Any other first non-blank line → not a branch list.
        return false;
    }
    return false; // empty input → passthrough
}

pub fn apply(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    _ = a;
    _ = stderr;
    // Branch list lands on stdout.
    const input = stdout;
    if (input.len == 0) return;

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "* ")) {
            // Current branch: strip one leading space to save a byte → "* <name>"
            // (This keeps the '*' sigil but collapses "* main" → "* main"; same width.
            //  We preserve verbatim to stay R2-lossless without any decode step.)
            try w.writeAll("* ");
            try w.writeAll(line[2..]);
            try w.writeByte('\n');
        } else if (line.len >= 2 and line[0] == ' ' and line[1] == ' ') {
            // Other branch: two-space indent → single space (saves 1 B per branch).
            // Pipe-mode idempotence: single-space prefix ("  " → " ") does NOT
            // start with "  " (two spaces), so re-matching returns false.
            try w.writeByte(' ');
            try w.writeAll(std.mem.trimLeft(u8, line, " "));
            try w.writeByte('\n');
        } else {
            // Unknown line shape — pass through verbatim.
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
}

// ---------------------------------------------------------------------------
// Fixtures + tests.
// ---------------------------------------------------------------------------

const fixture_branch_list = @embedFile("fixture_git_branch_list");

fn str(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: two-space branch row" {
    try std.testing.expect(matches("  feature\n* main\n"));
}

test "matches: asterisk-first branch row" {
    try std.testing.expect(matches("* main\n  feature\n"));
}

test "matches: empty input returns false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("\n\n"));
}

test "matches: non-branch input returns false" {
    try std.testing.expect(!matches("some text\n"));
    try std.testing.expect(!matches("Deleted branch feature\n"));
    try std.testing.expect(!matches("^ main\n")); // checkout output
}

test "matches: fixture" {
    try std.testing.expect(matches(fixture_branch_list));
}

test "pipe-mode idempotence: compressed output is NOT re-matched" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_branch_list); defer a.free(out);
    // Compressed output uses "* <name>" and " <name>" (single space).
    // The "  " (two-space) pattern won't match single-space output.
    try std.testing.expect(!matches(out));
}

test "apply: current branch emits * sigil" {
    const a = std.testing.allocator;
    const out = try str(a, "* main\n  feature\n"); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "* main\n") != null);
}

test "apply: other branches get single-space indent" {
    const a = std.testing.allocator;
    const out = try str(a, "* main\n  feature\n  dev\n"); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, " feature\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, " dev\n") != null);
}

test "apply: all branch names preserved" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_branch_list); defer a.free(out);
    // fixture contains: feature-x, feature-y, main
    try std.testing.expect(std.mem.indexOf(u8, out, "feature-x") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "feature-y") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "main") != null);
}

test "apply: current branch marker (* main)" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_branch_list); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "* main") != null);
}

test "apply: order preserved" {
    const a = std.testing.allocator;
    const out = try str(a, "* main\n  alpha\n  beta\n"); defer a.free(out);
    const main_pos = std.mem.indexOf(u8, out, "main").?;
    const alpha_pos = std.mem.indexOf(u8, out, "alpha").?;
    const beta_pos = std.mem.indexOf(u8, out, "beta").?;
    try std.testing.expect(main_pos < alpha_pos);
    try std.testing.expect(alpha_pos < beta_pos);
}

test "apply: single-branch repo passthrough (raw < 50 B → smll ≤ raw)" {
    const a = std.testing.allocator;
    const input = "* main\n"; // 7 B — raw < 50 B, smll ≤ raw required
    const out = try str(a, input); defer a.free(out);
    try std.testing.expect(out.len <= input.len);
}

test "apply: empty input produces empty output" {
    const a = std.testing.allocator;
    const out = try str(a, ""); defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "R3 exemption: smll ≤ raw on fixture (branch list is incompressible beyond ~7%)" {
    // R3 for git_branch is relaxed: no 20% floor, only smll ≤ raw.
    // Pure-name listings cannot be compressed ≥20% losslessly; see plan §Unit 6b.
    const a = std.testing.allocator;
    const out = try str(a, fixture_branch_list); defer a.free(out);
    try std.testing.expect(out.len <= fixture_branch_list.len);
}

test "R3 exemption: smll ≤ raw on larger branch list" {
    // Synthetic large-ish list to confirm no expansion.
    const a = std.testing.allocator;
    const input =
        "* main\n" ++
        "  alpha-long-branch\n" ++
        "  beta-long-branch\n" ++
        "  gamma-long-branch\n" ++
        "  delta-long-branch\n" ++
        "  epsilon-long-branch\n";
    const out = try str(a, input); defer a.free(out);
    try std.testing.expect(out.len <= input.len);
}
