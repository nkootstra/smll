const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.4 grammar for `git rebase`:
//   @ rebased <branch>   — successful rebase
//   @ up-to-date         — nothing to rebase
//   r <subject>          — Applying: row
//   ! conflict <path>    — conflicted file
// matches() = false (argv-only dispatch).

pub fn matches(input: []const u8) bool { _ = input; return false; }

pub fn apply(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    _ = a;
    const src = if (stdout.len > 0) stdout else stderr;
    if (src.len == 0) return;
    try scan(src, w);
    if (stdout.len > 0 and stderr.len > 0) try scan(stderr, w);
}

/// Scan input for rebase output tokens.  We use indexOf rather than line-split
/// to handle CR-interleaved progress ("Rebasing (N/M)\r...") without pulling
/// in splitAny.  The key tokens always appear at a CR/LF boundary or start.
fn scan(src: []const u8, w: *Writer) !void {
    const rebased = "Successfully rebased and updated ";
    const uptodate_marker = " is up to date";
    const applying = "Applying: ";
    const conflict = "CONFLICT (";

    var i: usize = 0;
    while (i < src.len) {
        // Find next printable token start (skip CR/LF/spaces at boundary).
        if (src[i] == '\r' or src[i] == '\n') { i += 1; continue; }

        // Check for "Successfully rebased and updated <branch>."
        if (std.mem.startsWith(u8, src[i..], rebased)) {
            var branch = src[i + rebased.len ..];
            // Trim to end of line or \r.
            var end: usize = 0;
            while (end < branch.len and branch[end] != '\n' and branch[end] != '\r') end += 1;
            branch = branch[0..end];
            if (std.mem.endsWith(u8, branch, ".")) branch = branch[0 .. branch.len - 1];
            try w.writeAll("@ rebased "); try w.writeAll(branch); try w.writeByte('\n');
            i += rebased.len + end;
            continue;
        }

        // Check for "Current branch <name> is up to date."
        if (std.mem.startsWith(u8, src[i..], "Current branch ")) {
            var rest = src[i + "Current branch ".len ..];
            var end: usize = 0;
            while (end < rest.len and rest[end] != '\n' and rest[end] != '\r') end += 1;
            rest = rest[0..end];
            if (std.mem.find(u8, rest, uptodate_marker) != null) {
                try w.writeAll("@ up-to-date\n");
            }
            i += "Current branch ".len + end;
            continue;
        }

        // Check for "Applying: <subject>"
        if (std.mem.startsWith(u8, src[i..], applying)) {
            var subj = src[i + applying.len ..];
            var end: usize = 0;
            while (end < subj.len and subj[end] != '\n' and subj[end] != '\r') end += 1;
            try w.writeAll("r "); try w.writeAll(subj[0..end]); try w.writeByte('\n');
            i += applying.len + end;
            continue;
        }

        // Check for "CONFLICT (...): ..."
        if (std.mem.startsWith(u8, src[i..], conflict)) {
            var line = src[i..];
            var end: usize = 0;
            while (end < line.len and line[end] != '\n' and line[end] != '\r') end += 1;
            line = line[0..end];
            const p = util.conflictPath(line);
            if (p.len > 0) { try w.writeAll("! conflict "); try w.writeAll(p); try w.writeByte('\n'); }
            i += end;
            continue;
        }

        // Skip to next line/CR boundary.
        while (i < src.len and src[i] != '\n' and src[i] != '\r') i += 1;
    }
}

// ---------------------------------------------------------------------------
// Fixtures + tests.
// ---------------------------------------------------------------------------

const fixture_simple = @embedFile("fixture_git_rebase_simple");
const fixture_large = @embedFile("fixture_git_rebase_large");

fn str(allocator: Allocator, so: []const u8, se: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, so, se, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: always false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("Successfully rebased and updated refs/heads/main.\n"));
    try std.testing.expect(!matches("CONFLICT (content): Merge conflict in x.zig\n"));
}

test "pipe-mode" {
    try std.testing.expect(!matches(fixture_simple));
}

test "simple: @ rebased" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_simple, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@ rebased refs/heads/rebase-branch\n") != null);
}

test "simple: no progress noise" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_simple, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "Rebasing") == null);
}

test "large: @ rebased" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_large, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@ rebased refs/heads/large-rebase-branch\n") != null);
}

test "up-to-date" {
    const a = std.testing.allocator;
    const input = "Current branch main is up to date.\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expectEqualStrings("@ up-to-date\n", out);
}

test "conflict path" {
    const a = std.testing.allocator;
    const input = "CONFLICT (content): Merge conflict in src/main.zig\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "! conflict src/main.zig\n") != null);
}

test "Applying becomes r row" {
    const a = std.testing.allocator;
    const input = "Applying: feat: add feature\nSuccessfully rebased and updated refs/heads/main.\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "r feat: add feature\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "@ rebased refs/heads/main\n") != null);
}

test "R3: simple" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_simple, ""); defer a.free(out);
    const raw = fixture_simple.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100)
    else try std.testing.expect(out.len <= raw);
}

test "R3: large" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_large, ""); defer a.free(out);
    const raw = fixture_large.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100)
    else try std.testing.expect(out.len <= raw);
}

test "empty" {
    const a = std.testing.allocator;
    const out = try str(a, "", ""); defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}
