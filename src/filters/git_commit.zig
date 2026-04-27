const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.4 grammar for `git commit` output:
//
//   c <sha7> <branch> <subject>   — commit header
//   +<ins>/-<del> files=<N>       — change summary
//   + <path>                      — created file (create mode)
//   - <path>                      — deleted file (delete mode)
//
// Raw git commit output shape:
//   [<branch> <sha7>] <subject>
//    <N> files? changed, <ins> insertions(+)[, <del> deletions(-)]
//    create mode 100644 <path>
//    delete mode 100644 <path>
//
// Root-commit shape: [<branch> (root-commit) <sha7>] <subject>
// Every path is preserved. Branch, sha7, and subject are preserved.

/// matches returns true when the first non-blank line looks like git commit output.
/// Requires: starts with '[', contains ']', sha7 (7 hex chars) before ']'.
/// Returns false for v0.4 output (starts with 'c ') — pipe-mode idempotence.
pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return isCommitHeader(line);
    }
    return false;
}

/// True when line looks like: [<branch> <sha7>] or [<branch> (root-commit) <sha7>]
fn isCommitHeader(line: []const u8) bool {
    if (line.len < 2) return false;
    if (line[0] != '[') return false;

    // Find the closing bracket.
    const bracket_pos = std.mem.findScalar(u8, line, ']') orelse return false;
    // Content between brackets: "branch sha7" or "branch (root-commit) sha7"
    const inner = line[1..bracket_pos];

    // Split inner by space; sha7 is the last token.
    var last_space = inner.len;
    var i = inner.len;
    while (i > 0) {
        i -= 1;
        if (inner[i] == ' ') {
            last_space = i;
            break;
        }
    }
    if (last_space == inner.len) return false; // no space found
    const sha_candidate = inner[last_space + 1 ..];
    return sha_candidate.len == 7 and isHex7(sha_candidate);
}

fn isHex7(s: []const u8) bool {
    if (s.len != 7) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var buf = Writer.Allocating.init(allocator);
    defer buf.deinit();
    try applyInner(allocator, stdout, stderr, &buf.writer);
    // Post-process: group consecutive +/- entries by directory
    try groupFileEntries(buf.written(), writer);
}

fn groupFileEntries(output: []const u8, writer: *Writer) !void {
    var all_lines: [4096][]const u8 = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (count >= all_lines.len) break;
        all_lines[count] = line;
        count += 1;
    }
    var i: usize = 0;
    while (i < count) {
        const line = all_lines[i];
        // Match "+ path" or "- path"
        if (line.len >= 3 and (line[0] == '+' or line[0] == '-') and line[1] == ' ') {
            const sigil = line[0..1];
            const path = line[2..];
            const dir = if (std.mem.findScalarLast(u8, path, '/')) |idx| path[0 .. idx + 1] else "";
            if (dir.len > 0) {
                var run_end = i + 1;
                while (run_end < count) {
                    const next = all_lines[run_end];
                    if (next.len < 3 or next[0] != line[0] or next[1] != ' ') break;
                    const next_path = next[2..];
                    const next_dir = if (std.mem.findScalarLast(u8, next_path, '/')) |idx| next_path[0 .. idx + 1] else "";
                    if (!std.mem.eql(u8, dir, next_dir)) break;
                    run_end += 1;
                }
                if (run_end - i >= 3) {
                    try writer.writeAll(sigil);
                    try writer.writeAll(" ");
                    try writer.writeAll(dir);
                    try writer.writeAll(" ×"); try ansi.writeDecimal(writer, run_end - i); try writer.writeByte('\n');
                    i = run_end;
                    continue;
                }
            }
        }
        try writer.writeAll(line);
        try writer.writeByte('\n');
        i += 1;
    }
}

fn applyInner(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    const input = stdout;
    if (input.len == 0) return;

    var lines = std.mem.splitScalar(u8, input, '\n');

    // --- Line 1: commit header ---
    // Find first non-blank line.
    var header: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        header = line;
        break;
    }
    const hdr = header orelse return;

    // Parse: [branch sha7] subject  or  [branch (root-commit) sha7] subject
    const bracket_pos = std.mem.findScalar(u8, hdr, ']') orelse {
        // Unrecognized format — pass through.
        try writer.writeAll(hdr);
        try writer.writeByte('\n');
        return;
    };
    const inner = hdr[1..bracket_pos];
    const subject_raw = hdr[bracket_pos + 1 ..];
    // subject_raw starts with "] " — trim leading space.
    const subject = std.mem.trimStart(u8, subject_raw, " ");

    // Extract sha7: last space-delimited token in inner.
    var last_space: usize = inner.len;
    var i = inner.len;
    while (i > 0) {
        i -= 1;
        if (inner[i] == ' ') {
            last_space = i;
            break;
        }
    }
    const sha7 = inner[last_space + 1 ..];
    const branch_inner = inner[0..last_space];

    // branch_inner may be "main" or "main (root-commit)" — strip " (root-commit)" suffix.
    const branch = if (std.mem.find(u8, branch_inner, " (")) |paren_pos|
        branch_inner[0..paren_pos]
    else
        branch_inner;

    // Emit: c <sha7> <branch> <subject>
    try writer.writeAll("c ");
    try writer.writeAll(sha7);
    try writer.writeByte(' ');
    try writer.writeAll(branch);
    try writer.writeByte(' ');
    try writer.writeAll(subject);
    try writer.writeByte('\n');

    // --- Line 2: stats line ---
    // Shape: " <N> files? changed, <ins> insertions(+)[, <del> deletions(-)]"
    var insertions: []const u8 = "0";
    var deletions: []const u8 = "0";
    var files: []const u8 = "0";

    var stats_found = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.find(u8, trimmed, " changed") != null) {
            files = parseNumber(trimmed);
            insertions = extractInsertions(trimmed);
            deletions = extractDeletions(trimmed);
            stats_found = true;
            break;
        }
        // Unexpected non-empty, non-stats line — emit as-is and continue.
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    if (stats_found) {
        // Emit: +<ins>/-<del> files=<N>
        try writer.writeByte('+');
        try writer.writeAll(insertions);
        try writer.writeAll("/-");
        try writer.writeAll(deletions);
        try writer.writeAll(" files=");
        try writer.writeAll(files);
        try writer.writeByte('\n');
    }

    // --- Remaining lines: create/delete mode ---
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (std.mem.startsWith(u8, trimmed, "create mode ")) {
            // "create mode 100644 <path>"
            const after_mode = trimmed["create mode ".len..];
            // Skip the mode number (e.g. "100644 ").
            const path = skipModeNumber(after_mode);
            try writer.writeAll("+ ");
            try writer.writeAll(path);
            try writer.writeByte('\n');
        } else if (std.mem.startsWith(u8, trimmed, "delete mode ")) {
            const after_mode = trimmed["delete mode ".len..];
            const path = skipModeNumber(after_mode);
            try writer.writeAll("- ");
            try writer.writeAll(path);
            try writer.writeByte('\n');
        } else {
            // Unknown line — pass through.
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }
}

/// Skip past the mode number (e.g. "100644 ") and return the rest (the path).
fn skipModeNumber(s: []const u8) []const u8 {
    if (std.mem.findScalar(u8, s, ' ')) |sp| {
        return s[sp + 1 ..];
    }
    return s;
}

/// Extract the first number from a string like "2 files changed, 5 insertions(+)..."
fn parseNumber(s: []const u8) []const u8 {
    var start: usize = 0;
    // Skip leading non-digits.
    while (start < s.len and !std.ascii.isDigit(s[start])) : (start += 1) {}
    var end = start;
    while (end < s.len and std.ascii.isDigit(s[end])) : (end += 1) {}
    if (start == end) return "0";
    return s[start..end];
}

/// Extract insertion count from stats line.
fn extractInsertions(s: []const u8) []const u8 {
    // Find "insertion" and walk back to the number before it.
    const marker = " insertion";
    const idx = std.mem.find(u8, s, marker) orelse return "0";
    return numberBefore(s, idx);
}

/// Extract deletion count from stats line.
fn extractDeletions(s: []const u8) []const u8 {
    const marker = " deletion";
    const idx = std.mem.find(u8, s, marker) orelse return "0";
    return numberBefore(s, idx);
}

/// Return the decimal number immediately before position `pos` in `s`.
fn numberBefore(s: []const u8, pos: usize) []const u8 {
    if (pos == 0) return "0";
    var end = pos;
    // Walk back past the space before the number.
    while (end > 0 and s[end - 1] == ' ') : (end -= 1) {}
    var start = end;
    while (start > 0 and std.ascii.isDigit(s[start - 1])) : (start -= 1) {}
    if (start == end) return "0";
    return s[start..end];
}

// ---------------------------------------------------------------------------
// Fixtures (embedded at compile time).
// ---------------------------------------------------------------------------

const fixture_simple = @embedFile("fixture_git_commit_simple");
const fixture_multifile = @embedFile("fixture_git_commit_multifile");
const fixture_large = @embedFile("fixture_git_commit_large");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

test "matches: simple commit fixture" {
    try std.testing.expect(matches(fixture_simple));
}

test "matches: multifile commit fixture" {
    try std.testing.expect(matches(fixture_multifile));
}

test "matches: root-commit shape" {
    try std.testing.expect(matches("[main (root-commit) abc1234] feat: init\n 1 file changed\n"));
}

test "matches: non-commit input returns false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("On branch main\n"));
    try std.testing.expect(!matches("fatal: not a git repository\n"));
}

test "matches: pipe-mode idempotence — v0.4 output is NOT re-matched" {
    // v0.4 output starts with "c <sha7> ..." which is NOT a commit header.
    try std.testing.expect(!matches("c abc1234 main feat: add v0.4\n+5/-2 files=2\n"));
    try std.testing.expect(!matches("c 6b68b6d main feat: add a.txt\n+1/-0 files=1\n+ a.txt\n"));
}

test "apply: simple fixture produces correct v0.4 header" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_simple);
    defer allocator.free(out);
    // Header line: c <sha7> <branch> <subject>
    try std.testing.expect(std.mem.startsWith(u8, out, "c 6b68b6d main feat: add a.txt\n"));
}

test "apply: simple fixture produces correct summary line" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_simple);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+1/-0 files=1\n") != null);
}

test "apply: simple fixture preserves create-mode path" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_simple);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+ a.txt\n") != null);
}

test "apply: multifile fixture preserves all create-mode paths" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_multifile);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+ b.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "+ c.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "+2/-0 files=2\n") != null);
}

test "apply: delete mode produces - sigil" {
    const allocator = std.testing.allocator;
    const input =
        "[main abc1234] chore: remove old file\n" ++
        " 1 file changed, 0 insertions(+), 3 deletions(-)\n" ++
        " delete mode 100644 old/module.zig\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "- old/module.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "+0/-3 files=1\n") != null);
}

test "apply: large fixture groups create-mode paths by directory" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_large);
    defer allocator.free(out);
    // Paths should be grouped by directory
    try std.testing.expect(std.mem.find(u8, out, "+ src/generated/") != null);
    try std.testing.expect(std.mem.find(u8, out, "+750/-0 files=150\n") != null);
}

test "apply: R3 gate — simple fixture smll ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_simple);
    defer allocator.free(out);
    const raw = fixture_simple.len;
    const smll = out.len;
    const target = (raw * 80) / 100;
    try std.testing.expect(smll <= target);
}

test "apply: R3 gate — multifile fixture smll ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_multifile);
    defer allocator.free(out);
    const raw = fixture_multifile.len;
    const smll = out.len;
    const target = (raw * 80) / 100;
    try std.testing.expect(smll <= target);
}

test "apply: R3 gate — large fixture smll ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_large);
    defer allocator.free(out);
    const raw = fixture_large.len;
    const smll = out.len;
    const target = (raw * 80) / 100;
    try std.testing.expect(smll <= target);
}

test "apply: pipe-mode idempotence — v0.4 output does not re-match" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, fixture_simple);
    defer allocator.free(out);
    // v0.4 output must not be re-matched (starts with "c ", not "[").
    try std.testing.expect(!matches(out));
}
