const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.4 grammar for `git checkout`:
//
//   ^ <branch>                  — switched to branch (sigil '^' chosen; does not
//                                 collide with # M A D R S d ? UU c p : d @ + - ! * > < $ x)
//   ^ detached <sha7> <subject> — HEAD detached at sha7, subject line
//   = <remote>/<branch>         — up to date with remote (collapses the verbose message)
//   M <path>                    — unstaged modified file in dirty-checkout output
//   d <path>                    — unstaged deleted file in dirty-checkout output
//
// matches() = false unconditionally.  Checkout's identifying output lands on
// stderr in current git versions, so pipe mode has nothing to match against;
// wrapper-mode argv dispatch is the sole entry point.

pub fn matches(input: []const u8) bool { _ = input; return false; }

pub fn apply(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    _ = a;
    // Emit from stderr: switch confirmation lines.
    if (stderr.len > 0) try scanStderr(stderr, w);
    // Emit from stdout: dirty-state file markers (e.g. "M path").
    if (stdout.len > 0) try scanStdout(stdout, w);
    // Edge case: if both are empty nothing is emitted (silent checkout passthrough).
}

/// Parse checkout stderr lines:
///   "Switched to branch 'feature'"           → "^ feature"
///   "Switched to a new branch 'feature'"     → "^ feature"
///   "HEAD is now at abc1234 subject"          → "^ detached abc1234 subject"
///   "Your branch is up to date with '...'"   → "= origin/feature"
///   "Your branch is ahead/behind …"          → (dropped — status handles this)
fn scanStderr(src: []const u8, w: *Writer) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "Switched to")) {
            // "Switched to branch 'feature'" or "Switched to a new branch 'feature'"
            if (std.mem.indexOf(u8, line, "'")) |q| {
                const after_q = line[q + 1 ..];
                if (std.mem.indexOf(u8, after_q, "'")) |eq| {
                    const branch = after_q[0..eq];
                    try w.writeAll("^ ");
                    try w.writeAll(branch);
                    try w.writeByte('\n');
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "HEAD is now at ")) {
            // "HEAD is now at abc1234 subject line here"
            const rest = line["HEAD is now at ".len..];
            var sp: usize = 0;
            while (sp < rest.len and rest[sp] != ' ') sp += 1;
            const sha = rest[0..@min(sp, 7)];
            const subj = if (sp < rest.len) std.mem.trim(u8, rest[sp..], " \t") else "";
            try w.writeAll("^ detached ");
            try w.writeAll(sha);
            if (subj.len > 0) {
                try w.writeByte(' ');
                try w.writeAll(subj);
            }
            try w.writeByte('\n');
            continue;
        }

        if (std.mem.startsWith(u8, line, "Your branch is up to date with '")) {
            // "Your branch is up to date with 'origin/feature'."
            const after = line["Your branch is up to date with '".len..];
            if (std.mem.indexOf(u8, after, "'")) |eq| {
                const remote_ref = after[0..eq];
                try w.writeAll("= ");
                try w.writeAll(remote_ref);
                try w.writeByte('\n');
            }
            continue;
        }
        // Other lines (ahead/behind counts, hint lines, etc.) are dropped.
    }
}

/// Parse checkout stdout lines for dirty-state markers.
/// Git emits lines like "M\tpath" or "D\tpath" on a dirty-tree checkout.
fn scanStdout(src: []const u8, w: *Writer) !void {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len < 2) continue;
        // Lines of form "<X>\t<path>" where X is M/D/A etc.
        const marker = line[0];
        if (line[1] == '\t') {
            const path = line[2..];
            switch (marker) {
                'M' => { try w.writeAll("M "); try w.writeAll(path); try w.writeByte('\n'); },
                'D' => { try w.writeAll("d "); try w.writeAll(path); try w.writeByte('\n'); },
                'A' => { try w.writeAll("A "); try w.writeAll(path); try w.writeByte('\n'); },
                else => { try w.writeByte(marker); try w.writeByte(' '); try w.writeAll(path); try w.writeByte('\n'); },
            }
        }
        // Lines not matching the <X>\t<path> pattern are dropped (progress text etc.).
    }
}

// ---------------------------------------------------------------------------
// Fixtures + tests.
// ---------------------------------------------------------------------------

const fixture_switch_stdout = @embedFile("fixture_git_checkout_switch_stdout");
const fixture_switch_stderr = @embedFile("fixture_git_checkout_switch_stderr");

fn str(allocator: Allocator, so: []const u8, se: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, so, se, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: always false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("Switched to branch 'main'\n"));
    try std.testing.expect(!matches("HEAD is now at abc1234 subject\n"));
    try std.testing.expect(!matches("^ main\n")); // already-compressed output
}

test "pipe-mode safety: matches returns false on fixture" {
    try std.testing.expect(!matches(fixture_switch_stderr));
    try std.testing.expect(!matches(fixture_switch_stdout));
}

test "switch: basic branch switch" {
    const a = std.testing.allocator;
    const out = try str(a, "", "Switched to branch 'feature-x'\n"); defer a.free(out);
    try std.testing.expectEqualStrings("^ feature-x\n", out);
}

test "switch: new branch" {
    const a = std.testing.allocator;
    const out = try str(a, "", "Switched to a new branch 'my-feature'\n"); defer a.free(out);
    try std.testing.expectEqualStrings("^ my-feature\n", out);
}

test "switch: detached HEAD" {
    const a = std.testing.allocator;
    const input = "HEAD is now at abc1234f feat: add thing\n";
    const out = try str(a, "", input); defer a.free(out);
    try std.testing.expectEqualStrings("^ detached abc1234 feat: add thing\n", out);
}

test "switch: detached HEAD sha truncated to 7" {
    const a = std.testing.allocator;
    const input = "HEAD is now at abcdefghij some commit\n";
    const out = try str(a, "", input); defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "^ detached abcdefg "));
}

test "switch: up-to-date with remote" {
    const a = std.testing.allocator;
    const input = "Switched to branch 'feature-x'\nYour branch is up to date with 'origin/feature-x'.\n";
    const out = try str(a, "", input); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "^ feature-x\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "= origin/feature-x\n") != null);
}

test "switch: empty output (silent checkout) passthrough" {
    const a = std.testing.allocator;
    const out = try str(a, "", ""); defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "switch: dirty-state stdout markers" {
    const a = std.testing.allocator;
    const out = try str(a, "M\tsrc/main.zig\nD\told_file.zig\n", "Switched to branch 'main'\n");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "^ main\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "M src/main.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "d old_file.zig\n") != null);
}

test "switch fixture: emits ^ sigil" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_switch_stdout, fixture_switch_stderr); defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "^ "));
}

test "R3: switch fixture (raw < 50 B → smll ≤ raw)" {
    // The switch fixture is small (< 50 B), so R3 requires smll ≤ raw only.
    const a = std.testing.allocator;
    const out = try str(a, fixture_switch_stdout, fixture_switch_stderr); defer a.free(out);
    const raw = fixture_switch_stdout.len + fixture_switch_stderr.len;
    if (raw >= 50) {
        try std.testing.expect(out.len <= (raw * 80) / 100);
    } else {
        try std.testing.expect(out.len <= raw);
    }
}

test "R3: larger checkout input (branch + remote)" {
    // Build a synthetic input ≥ 50 B to verify 20% reduction.
    const a = std.testing.allocator;
    const input = "Switched to branch 'very-long-feature-branch-name-for-testing'\nYour branch is up to date with 'origin/very-long-feature-branch-name-for-testing'.\n";
    const out = try str(a, "", input); defer a.free(out);
    const raw = input.len;
    if (raw >= 50) {
        try std.testing.expect(out.len <= (raw * 80) / 100);
    } else {
        try std.testing.expect(out.len <= raw);
    }
}

test "compressed output is not re-matched by matches (idempotent)" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_switch_stdout, fixture_switch_stderr); defer a.free(out);
    // ^ prefix does not match any pipe-mode pattern, so re-running gives passthrough.
    try std.testing.expect(!matches(out));
}
