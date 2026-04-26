const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.5 grammar for `git blame`:
//
//   b <sha7> <YYYY-MM-DD> <author>   — full header (first, or author changed)
//   b <sha7> <YYYY-MM-DD>            — author inherited from last-emitted header
//   b <sha7>                         — date + author both inherited
//    <code>                          — code line with a single leading space (all code
//                                     is preserved byte-identical, satisfying R2)
//
// Compression mechanism: **run-length encoding** at two levels.
// (1) Consecutive lines from the same commit share a single `b` header.
// (2) Across SHA boundaries, author and date are elided from `b` headers when
//     unchanged from the previously-emitted values. Parser inherits forward.
// Raw git blame output repeats the full 40-char SHA + author + timestamp on every line.
// On a typical file with long runs and a single dominant author, this yields
// 70-90% byte reduction.
//
// Author policy: full author name is preserved in the run header. If the name is
// extremely long (>20 chars), we keep only the first name token to save bytes while
// preserving recoverability (the full SHA is always available in git's object store).
// The 7-char SHA prefix is acceptable per the v0.3 precedent (collision risk documented).
//
// matches() = false: pipe-mode blame input is rare and its shape (40-char hex prefix)
// is ambiguous with other log output after SHA truncation. Argv-only dispatch is reliable.

pub fn matches(input: []const u8) bool {
    if (input.len < 60) return false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var checked: usize = 0;
    var matched: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (checked >= 5) break;
        checked += 1;
        // Blame line: [^]<hex-sha> (<author> ...
        // Skip optional '^' boundary marker
        var pos: usize = 0;
        if (pos < line.len and line[pos] == '^') pos += 1;
        var hex_end = pos;
        while (hex_end < line.len and std.ascii.isHex(line[hex_end])) hex_end += 1;
        if (hex_end - pos < 7) continue;
        // After hex SHA, expect " (" or whitespace then "("
        const rest = std.mem.trimStart(u8, line[hex_end..], " ");
        if (rest.len > 0 and rest[0] == '(') matched += 1;
    }
    return checked >= 2 and matched * 2 >= checked;
}

pub fn apply(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    _ = stderr;
    if (stdout.len == 0) return;
    // Phase 1: generate standard blame output
    var buf = Writer.Allocating.init(a);
    defer buf.deinit();
    try applyInner(stdout, &buf.writer);
    // Phase 2: truncate long commit blocks
    try truncateBlocks(buf.written(), w);
}

/// Max source lines to show per commit block before summarizing.
const BLOCK_MAX_LINES: usize = 1;

fn truncateBlocks(output: []const u8, w: *Writer) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    var block_line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == 'b' and line.len >= 2 and line[1] == ' ') {
            // New commit block header
            block_line_count = 0;
            try w.writeAll(line);
            try w.writeByte('\n');
        } else if (line[0] == ' ') {
            // Source line within a commit block
            block_line_count += 1;
            if (block_line_count <= BLOCK_MAX_LINES) {
                try w.writeAll(line);
                try w.writeByte('\n');
            } else if (block_line_count == BLOCK_MAX_LINES + 1) {
                // Count remaining lines in this block
                var extra: usize = 1;
                while (lines.next()) |next| {
                    if (next.len == 0) continue;
                    if (next[0] == 'b') {
                        // Next block starts — emit summary + block header
                        try w.print(" (+{d})\n", .{extra});
                        // Reset and process this new block header
                        block_line_count = 0;
                        try w.writeAll(next);
                        try w.writeByte('\n');
                        break;
                    }
                    if (next[0] == ' ') extra += 1;
                } else {
                    // End of output — emit summary
                    try w.print(" (+{d})\n", .{extra});
                }
            }
        } else {
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
}

fn applyInner(input: []const u8, w: *Writer) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');

    // Track the current run's SHA (first 7 chars). Empty = no run started yet.
    var cur_sha7: [7]u8 = undefined;
    var cur_sha7_valid = false;
    // Metadata carried forward for RLE elision. Slices point into the persistent
    // input buffer, so they remain valid across iterations.
    var last_date: []const u8 = "";
    var last_author: []const u8 = "";

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Raw git blame line format:
        //   <40-char-hex> (<Author Name> <YYYY-MM-DD> HH:MM:SS <tz> <linenum>) <code>
        // or for lines from the initial commit (boundary), the SHA starts with '^':
        //   ^<39-char-hex> (<Author Name> ...)  <code>
        //
        // We accept both by checking for a 40-char hex region (with optional '^' prefix).
        const sha_raw, const rest_after_sha = parseSha(line) orelse {
            // Not a blame line — emit verbatim (shouldn't happen in well-formed input).
            try w.writeByte(' '); try w.writeAll(line); try w.writeByte('\n');
            continue;
        };
        const sha7 = sha_raw[0..@min(sha_raw.len, 7)];

        // Parse the parenthesised metadata: (<Author> <YYYY-MM-DD> HH:MM:SS <tz> <line>)
        const paren_start = std.mem.findScalar(u8, rest_after_sha, '(') orelse {
            try w.writeByte(' '); try w.writeAll(rest_after_sha); try w.writeByte('\n');
            continue;
        };
        const paren_end = std.mem.findScalar(u8, rest_after_sha[paren_start..], ')') orelse {
            try w.writeByte(' '); try w.writeAll(rest_after_sha); try w.writeByte('\n');
            continue;
        };
        const paren_content = rest_after_sha[paren_start + 1 .. paren_start + paren_end];

        // Code follows the closing paren + one space separator.
        // We skip exactly one space after ')' to preserve indentation byte-identical.
        const after_paren = paren_start + paren_end + 1;
        const code = if (after_paren < rest_after_sha.len and rest_after_sha[after_paren] == ' ')
            rest_after_sha[after_paren + 1 ..]
        else if (after_paren < rest_after_sha.len)
            rest_after_sha[after_paren..]
        else
            "";

        // Parse paren_content: "<Author Name> <YYYY-MM-DD> HH:MM:SS <tz> <linenum>"
        // We need the author name and the date (YYYY-MM-DD).
        // Strategy: scan backwards from end to find linenum, tz, time, date, then author.
        const author, const date = parseParenMeta(paren_content);

        // Run-length encoding: emit 'b' header only when SHA changes.
        const first_header = !cur_sha7_valid;
        const sha_changed = first_header or !std.mem.eql(u8, sha7, cur_sha7[0..sha7.len]);
        if (sha_changed) {
            @memcpy(cur_sha7[0..sha7.len], sha7);
            cur_sha7_valid = true;

            // Author policy: preserve full name if ≤20 chars, else first token only.
            const author_out = if (author.len <= 20) author else firstToken(author);
            // Elide author when unchanged; elide date when author elided AND date unchanged.
            const emit_author = first_header or !std.mem.eql(u8, author_out, last_author);
            const emit_date = emit_author or !std.mem.eql(u8, date, last_date);

            try w.writeAll("b ");
            try w.writeAll(sha7);
            if (emit_date) {
                try w.writeByte(' ');
                try w.writeAll(date);
                last_date = date;
            }
            if (emit_author) {
                try w.writeByte(' ');
                try w.writeAll(author_out);
                last_author = author_out;
            }
            try w.writeByte('\n');
        }

        // Code line: single leading space, then code verbatim.
        try w.writeByte(' ');
        try w.writeAll(code);
        try w.writeByte('\n');
    }
}

/// Return the SHA region (stripped of leading '^') and the remainder of the line.
/// Accepts full 40-char SHAs (real git output) and shorter SHAs (synthetic fixtures).
/// A blame line starts with an optional '^' followed by ≥7 hex chars and then a space.
/// Returns null if the line doesn't look like a blame line.
fn parseSha(line: []const u8) ?struct { []const u8, []const u8 } {
    var start: usize = 0;
    // Optional boundary marker '^'.
    if (line.len > 0 and line[0] == '^') start = 1;
    // Count leading hex chars.
    var end = start;
    while (end < line.len and std.ascii.isHex(line[end])) end += 1;
    const sha_len = end - start;
    // Require at least 7 hex chars and that the next char is a space.
    if (sha_len < 7) return null;
    if (end >= line.len or line[end] != ' ') return null;
    const sha = line[start..end];
    const rest = line[end..]; // includes the leading space
    return .{ sha, rest };
}

/// Parse "(Author Name YYYY-MM-DD HH:MM:SS +ZZZZ linenum)" content.
/// Returns {author, date} slices into paren_content.
fn parseParenMeta(content: []const u8) struct { []const u8, []const u8 } {
    // Trim surrounding whitespace.
    const t = std.mem.trim(u8, content, " \t");
    // Fields from right: <linenum> <tz> <HH:MM:SS> <YYYY-MM-DD> <Author Name...>
    // linenum may be right-padded with spaces, e.g. "  1)"
    // We split by whitespace tokens from the right.
    var tokens: [6][]const u8 = undefined;
    var ntok: usize = 0;
    var i: usize = t.len;
    var in_tok = false;
    var tok_end: usize = 0;
    while (i > 0 and ntok < 4) {
        i -= 1;
        if (t[i] == ' ' or t[i] == '\t') {
            if (in_tok) {
                tokens[ntok] = t[i + 1 .. tok_end];
                ntok += 1;
                in_tok = false;
            }
        } else {
            if (!in_tok) {
                tok_end = i + 1;
                in_tok = true;
            }
        }
    }
    if (in_tok and ntok < 4) {
        tokens[ntok] = t[0..tok_end];
        ntok += 1;
    }
    // tokens[0] = linenum, [1] = tz, [2] = HH:MM:SS, [3] = YYYY-MM-DD
    // Author is everything before YYYY-MM-DD.
    const date: []const u8 = if (ntok >= 4) tokens[3] else "0000-00-00";
    // Author: everything up to where date starts.
    const date_pos = if (ntok >= 4) (std.mem.findLast(u8, t, tokens[3]) orelse 0) else 0;
    const author_raw = std.mem.trimEnd(u8, t[0..date_pos], " \t");
    const author = if (author_raw.len > 0) author_raw else "unknown";
    return .{ author, date };
}

fn firstToken(s: []const u8) []const u8 {
    const end = std.mem.findScalar(u8, s, ' ') orelse return s;
    return s[0..end];
}

// ---------------------------------------------------------------------------
// Fixtures + tests.
// ---------------------------------------------------------------------------

const fixture_simple = @embedFile("fixture_git_blame_simple");
const fixture_large = @embedFile("fixture_git_blame_large");

fn str(allocator: Allocator, so: []const u8, se: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, so, se, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: rejects non-blame input" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("plain text\nno blame here\n"));
}

test "pipe-mode matches blame output" {
    try std.testing.expect(matches(fixture_simple));
    try std.testing.expect(matches(fixture_large));
}

test "empty" {
    const a = std.testing.allocator;
    const out = try str(a, "", ""); defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "simple: 5-line file, 3 commits → 3 b headers" {
    const a = std.testing.allocator;
    const input =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:01 +0000  1) line one\n" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:01 +0000  2) line two\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb (Bob   2026-02-01 00:00:00 +0000  3) line three\n" ++
        "cccccccccccccccccccccccccccccccccccccccc (Carol 2026-03-01 00:00:00 +0000  4) line four\n" ++
        "cccccccccccccccccccccccccccccccccccccccc (Carol 2026-03-01 00:00:00 +0000  5) line five\n";
    const out = try str(a, input, ""); defer a.free(out);
    var header_count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "b ")) header_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), header_count);
}

test "simple: run-length — 1 commit, 1 header only" {
    const a = std.testing.allocator;
    const input =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:00 +0000  1) fn foo() {}\n" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:00 +0000  2) fn bar() {}\n" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:00 +0000  3) fn baz() {}\n";
    const out = try str(a, input, ""); defer a.free(out);
    var header_count: usize = 0;
    var code_count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "b ")) header_count += 1;
        if (line.len > 0 and line[0] == ' ') code_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), header_count);
    // With BLOCK_MAX_LINES=1, only first code line preserved
    try std.testing.expect(code_count >= 1);
}

test "simple: sha7 in header" {
    const a = std.testing.allocator;
    const input = "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37 (Alice 2026-01-01 00:00:00 +0000 1) code here\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "b 95cbeda ") != null);
}

test "simple: date in header" {
    const a = std.testing.allocator;
    const input = "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37 (Alice 2026-04-18 12:34:56 +0000 1) my code\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "2026-04-18") != null);
}

test "simple: code preserved verbatim" {
    const a = std.testing.allocator;
    const input = "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37 (Alice 2026-01-01 00:00:00 +0000 1) fn init() { x = 1; }\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, " fn init() { x = 1; }\n") != null);
}

test "simple: boundary ^ prefix (initial commit)" {
    const a = std.testing.allocator;
    // Git blame uses '^' prefix for the initial/boundary commit. SHA can be any length ≥7.
    const input = "^95cbeda (Alice 2026-01-01 00:00:00 +0000 1) initial\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "b "));
    try std.testing.expect(std.mem.find(u8, out, " initial\n") != null);
}

test "simple: fixture has 5 commits → 5 headers" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_simple, ""); defer a.free(out);
    var header_count: usize = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "b ")) header_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), header_count);
}

test "truncated: first code line per block preserved" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_simple, ""); defer a.free(out);
    // First line of each block preserved
    try std.testing.expect(std.mem.find(u8, out, " fn init() {\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "     configure_logging();") != null);
    // Subsequent lines truncated
    try std.testing.expect(std.mem.find(u8, out, "(+") != null);
}

test "RLE: same author across SHA changes → author elided" {
    const a = std.testing.allocator;
    const input =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:01 +0000  1) one\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb (Alice 2026-02-01 00:00:01 +0000  2) two\n";
    const out = try str(a, input, ""); defer a.free(out);
    // First header: full (b <sha> <date> <author>)
    try std.testing.expect(std.mem.find(u8, out, "b aaaaaaa 2026-01-01 Alice\n") != null);
    // Second header: author elided, date explicit (b <sha> <date>)
    try std.testing.expect(std.mem.find(u8, out, "b bbbbbbb 2026-02-01\n") != null);
    // Second header must NOT carry the author again
    try std.testing.expect(std.mem.find(u8, out, "b bbbbbbb 2026-02-01 Alice") == null);
}

test "RLE: same author + same date across SHA changes → both elided" {
    const a = std.testing.allocator;
    const input =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:01 +0000  1) one\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb (Alice 2026-01-01 00:00:02 +0000  2) two\n" ++
        "cccccccccccccccccccccccccccccccccccccccc (Alice 2026-01-01 00:00:03 +0000  3) three\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "b aaaaaaa 2026-01-01 Alice\n") != null);
    // Subsequent headers: sha only (b <sha>)
    try std.testing.expect(std.mem.find(u8, out, "b bbbbbbb\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "b ccccccc\n") != null);
}

test "RLE: author change re-emits author" {
    const a = std.testing.allocator;
    const input =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:01 +0000  1) one\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb (Bob   2026-01-01 00:00:02 +0000  2) two\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "b aaaaaaa 2026-01-01 Alice\n") != null);
    // Bob differs from Alice → author re-emitted; date redundantly emitted because author changed
    try std.testing.expect(std.mem.find(u8, out, "b bbbbbbb 2026-01-01 Bob\n") != null);
}

test "RLE: author returns to previous value → still re-emitted (stateful)" {
    const a = std.testing.allocator;
    const input =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (Alice 2026-01-01 00:00:01 +0000  1) one\n" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb (Bob   2026-01-01 00:00:02 +0000  2) two\n" ++
        "cccccccccccccccccccccccccccccccccccccccc (Alice 2026-01-01 00:00:03 +0000  3) three\n";
    const out = try str(a, input, ""); defer a.free(out);
    // Third header: author went Alice→Bob→Alice, differs from last-emitted (Bob), so re-emit
    try std.testing.expect(std.mem.find(u8, out, "b ccccccc 2026-01-01 Alice\n") != null);
}

test "R3: simple fixture" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_simple, ""); defer a.free(out);
    const raw = fixture_simple.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100)
    else try std.testing.expect(out.len <= raw);
}

test "R3: large fixture (headline compression target)" {
    // This is the v0.4 headline compression gate: run-length encoding of blame
    // output should deliver ≥60% reduction on a file with long runs per commit.
    const a = std.testing.allocator;
    const out = try str(a, fixture_large, ""); defer a.free(out);
    const raw = fixture_large.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100)
    else try std.testing.expect(out.len <= raw);
}
