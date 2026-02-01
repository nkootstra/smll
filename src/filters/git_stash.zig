const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.4 grammar for `git stash`:
//
//   $ <sha7> <branch> <subject>    — save / default shape
//   $<N> <sha7> <branch> <subject> — list shape (N = stash index)
//
// matches() = false: stash output shapes overlap with git-status
// ("On branch ...") so pipe-mode passthrough avoids false matches.
//
// apply() detects the sub-subcommand from stdout shape:
//   - Starts with "Saved working directory" → save shape
//   - Starts with "stash@{" or contains "stash@{" lines → list shape
//   - Otherwise (show, drop, apply, pop, unknown) → passthrough verbatim.
//     These shapes are out of scope for v0.4; extend in a later unit.
//
// Note: `git stash save` stdout line:
//   "Saved working directory and index state WIP on <branch>: <sha7> <subject>"
// or (newer git, no "WIP on"):
//   "Saved working directory and index state On <branch>: <subject>"
//
// `git stash list` stdout lines:
//   "stash@{0}: WIP on <branch>: <sha7> <subject>"
// or:
//   "stash@{0}: On <branch>: <subject>"

pub fn matches(input: []const u8) bool { _ = input; return false; }

pub fn apply(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    _ = a;
    const src = if (stdout.len > 0) stdout else stderr;
    if (src.len == 0) return;

    const trimmed = std.mem.trimLeft(u8, src, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "Saved working directory")) {
        // Save shape: single line output.
        // "Saved working directory and index state WIP on <branch>: <sha7> <subject>"
        // "Saved working directory and index state On <branch>: <subject>"
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            try applySaveLine(t, w);
            break;
        }
        return;
    }

    if (std.mem.startsWith(u8, trimmed, "stash@{")) {
        // List shape: one line per entry.
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            if (std.mem.startsWith(u8, t, "stash@{")) {
                try applyListLine(t, w);
            }
        }
        return;
    }

    // Out-of-scope shapes (show, drop, apply, pop, or unknown): passthrough.
    try w.writeAll(stdout);
    try std.fs.File.stderr().writeAll(stderr);
}

/// Parse and emit a save-shape line.
/// Input: "Saved working directory and index state WIP on <branch>: <sha7> <subject>"
///     or "Saved working directory and index state On <branch>: <subject>"
/// Output: "$ <branch> <subject>\n"  (no SHA in newer git output)
fn applySaveLine(line: []const u8, w: *Writer) !void {
    // Find "on <branch>:" — case: "WIP on " or "On "
    const wip_on = " WIP on ";
    const plain_on = " On ";
    var branch_start: usize = 0;
    var found = false;

    if (std.mem.indexOf(u8, line, wip_on)) |pos| {
        branch_start = pos + wip_on.len;
        found = true;
    } else if (std.mem.indexOf(u8, line, plain_on)) |pos| {
        branch_start = pos + plain_on.len;
        found = true;
    }
    if (!found) {
        // Unrecognised save line — passthrough.
        try w.writeAll(line); try w.writeByte('\n');
        return;
    }

    const after_on = line[branch_start..];
    // Find the colon that separates branch from the rest.
    const colon = std.mem.indexOfScalar(u8, after_on, ':') orelse {
        try w.writeAll("$ "); try w.writeAll(after_on); try w.writeByte('\n');
        return;
    };
    const branch = after_on[0..colon];
    const after_colon = std.mem.trimLeft(u8, after_on[colon + 1 ..], " \t");

    // after_colon may be "<sha7> <subject>" or just "<subject>".
    // We emit: "$ <branch> <after_colon>" (preserve whatever git gives us).
    try w.writeAll("$ ");
    try w.writeAll(branch);
    if (after_colon.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(after_colon);
    }
    try w.writeByte('\n');
}

/// Parse and emit a list-shape line.
/// Input: "stash@{N}: WIP on <branch>: <sha7> <subject>"
///     or "stash@{N}: On <branch>: <subject>"
/// Output: "$N <branch> <subject>\n"
fn applyListLine(line: []const u8, w: *Writer) !void {
    // Extract N from "stash@{N}:".
    const open = std.mem.indexOfScalar(u8, line, '{') orelse {
        try w.writeAll(line); try w.writeByte('\n'); return;
    };
    const close = std.mem.indexOfScalar(u8, line[open..], '}') orelse {
        try w.writeAll(line); try w.writeByte('\n'); return;
    };
    const n_str = line[open + 1 .. open + close];

    // Everything after "stash@{N}: " → parse as save-like.
    const prefix_end = open + close + 1; // points at '}'
    const after_brace = line[prefix_end..];
    // Skip ": " separator.
    const body = if (std.mem.startsWith(u8, after_brace, ": ")) after_brace[2..] else after_brace;

    // Now body is "WIP on <branch>: ..." or "On <branch>: ..."
    const wip_on = "WIP on ";
    const plain_on = "On ";
    var branch_start: usize = 0;
    var found = false;
    if (std.mem.startsWith(u8, body, wip_on)) {
        branch_start = wip_on.len;
        found = true;
    } else if (std.mem.startsWith(u8, body, plain_on)) {
        branch_start = plain_on.len;
        found = true;
    }

    if (!found) {
        try w.writeByte('$'); try w.writeAll(n_str); try w.writeByte(' ');
        try w.writeAll(body); try w.writeByte('\n');
        return;
    }

    const after_on = body[branch_start..];
    const colon = std.mem.indexOfScalar(u8, after_on, ':') orelse {
        try w.writeByte('$'); try w.writeAll(n_str); try w.writeByte(' ');
        try w.writeAll(after_on); try w.writeByte('\n');
        return;
    };
    const branch = after_on[0..colon];
    const after_colon = std.mem.trimLeft(u8, after_on[colon + 1 ..], " \t");

    try w.writeByte('$');
    try w.writeAll(n_str);
    try w.writeByte(' ');
    try w.writeAll(branch);
    if (after_colon.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(after_colon);
    }
    try w.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Fixtures + tests.
// ---------------------------------------------------------------------------

const fixture_save = @embedFile("fixture_git_stash_save");
const fixture_list = @embedFile("fixture_git_stash_list");

fn str(allocator: Allocator, so: []const u8, se: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, so, se, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: always false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("Saved working directory and index state On main: abc1234 wip\n"));
    try std.testing.expect(!matches("stash@{0}: On main: abc1234 wip\n"));
}

test "pipe-mode safety" {
    try std.testing.expect(!matches(fixture_save));
    try std.testing.expect(!matches(fixture_list));
}

test "save: sigil and branch" {
    const a = std.testing.allocator;
    // Modern git stash save format (no WIP on).
    const input = "Saved working directory and index state On main: wip: fixture stash entry 1\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "$ main "));
    try std.testing.expect(std.mem.indexOf(u8, out, "wip: fixture stash entry 1") != null);
}

test "save: WIP on branch format" {
    const a = std.testing.allocator;
    const input = "Saved working directory and index state WIP on feature/x: abc1234 do the thing\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "$ feature/x "));
    try std.testing.expect(std.mem.indexOf(u8, out, "abc1234 do the thing") != null);
}

test "save: fixture" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_save, ""); defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "$ main "));
    try std.testing.expect(std.mem.indexOf(u8, out, "wip: fixture stash entry 1") != null);
}

test "list: 2-entry fixture" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_list, ""); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "$0 main ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$1 main ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "wip: fixture stash entry 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "wip: fixture stash entry 1") != null);
}

test "list: 3-entry list" {
    const a = std.testing.allocator;
    const input =
        "stash@{0}: On feat: add widget\n" ++
        "stash@{1}: WIP on main: abc1234 fix bug\n" ++
        "stash@{2}: On dev: something else\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "$0 feat ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$1 main ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "$2 dev ") != null);
}

test "passthrough: show/drop/apply output" {
    const a = std.testing.allocator;
    const input = "diff --git a/foo.txt b/foo.txt\nindex abc..def 100644\n";
    const out = try str(a, input, ""); defer a.free(out);
    // Unknown shapes pass through verbatim.
    try std.testing.expectEqualStrings(input, out);
}

test "empty" {
    const a = std.testing.allocator;
    const out = try str(a, "", ""); defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "R3: save fixture" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_save, ""); defer a.free(out);
    const raw = fixture_save.len;
    if (raw >= 50) try std.testing.expect(out.len <= raw)
    else try std.testing.expect(out.len <= raw);
}

test "R3: list fixture" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_list, ""); defer a.free(out);
    const raw = fixture_list.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100)
    else try std.testing.expect(out.len <= raw);
}
