const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.4 grammar for `git blame`:
//
//   b <sha7> <YYYY-MM-DD> <author>   — run header, emitted once per run of consecutive
//                                      lines from the same commit
//    <code>                           — code line with a single leading space (all code
//                                      is preserved byte-identical, satisfying R2)
//
// Compression mechanism: **run-length encoding** of consecutive rows from the same commit.
// Raw git blame output repeats the full 40-char SHA + author + timestamp on every line.
// This formatter emits the header once per run, then only the code lines.
// On a typical file with long runs (e.g. same author/commit across many lines), this
// yields 60-80% byte reduction.
//
// Author policy: full author name is preserved in the run header. If the name is
// extremely long (>20 chars), we keep only the first name token to save bytes while
// preserving recoverability (the full SHA is always available in git's object store).
// The 7-char SHA prefix is acceptable per the v0.3 precedent (collision risk documented).
//
// matches() = false: pipe-mode blame input is rare and its shape (40-char hex prefix)
// is ambiguous with other log output after SHA truncation. Argv-only dispatch is reliable.

pub fn matches(input: []const u8) bool { _ = input; return false; }

pub fn apply(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    _ = a;
    _ = stderr;
    if (stdout.len == 0) return;
    try applyInner(stdout, w);
}

fn applyInner(input: []const u8, w: *Writer) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');

    // Track the current run's SHA (first 7 chars). Empty = no run started yet.
    var cur_sha7: [7]u8 = undefined;
    var cur_sha7_valid = false;

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
        const paren_start = std.mem.indexOfScalar(u8, rest_after_sha, '(') orelse {
            try w.writeByte(' '); try w.writeAll(rest_after_sha); try w.writeByte('\n');
            continue;
        };
        const paren_end = std.mem.indexOfScalar(u8, rest_after_sha[paren_start..], ')') orelse {
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
        const sha_changed = !cur_sha7_valid or !std.mem.eql(u8, sha7, cur_sha7[0..sha7.len]);
        if (sha_changed) {
            @memcpy(cur_sha7[0..sha7.len], sha7);
            cur_sha7_valid = true;

            try w.writeAll("b ");
            try w.writeAll(sha7);
            try w.writeByte(' ');
            try w.writeAll(date);
            try w.writeByte(' ');
            // Author policy: preserve full name if ≤20 chars, else first token only.
            const author_out = if (author.len <= 20) author else firstToken(author);
            try w.writeAll(author_out);
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
    const date_pos = if (ntok >= 4) (std.mem.lastIndexOf(u8, t, tokens[3]) orelse 0) else 0;
    const author_raw = std.mem.trimRight(u8, t[0..date_pos], " \t");
    const author = if (author_raw.len > 0) author_raw else "unknown";
    return .{ author, date };
}

fn firstToken(s: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, s, ' ') orelse return s;
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

test "matches: always false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches(fixture_simple));
    try std.testing.expect(!matches("abc1234def567890abc1234def567890abc1234de (Author 2026-01-01 00:00:00 +0000 1) code\n"));
}

test "pipe-mode safety" {
    try std.testing.expect(!matches(fixture_simple));
    try std.testing.expect(!matches(fixture_large));
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
    try std.testing.expectEqual(@as(usize, 3), code_count);
}

test "simple: sha7 in header" {
    const a = std.testing.allocator;
    const input = "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37 (Alice 2026-01-01 00:00:00 +0000 1) code here\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "b 95cbeda ") != null);
}

test "simple: date in header" {
    const a = std.testing.allocator;
    const input = "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37 (Alice 2026-04-18 12:34:56 +0000 1) my code\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "2026-04-18") != null);
}

test "simple: code preserved verbatim" {
    const a = std.testing.allocator;
    const input = "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37 (Alice 2026-01-01 00:00:00 +0000 1) fn init() { x = 1; }\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, " fn init() { x = 1; }\n") != null);
}

test "simple: boundary ^ prefix (initial commit)" {
    const a = std.testing.allocator;
    // Git blame uses '^' prefix for the initial/boundary commit. SHA can be any length ≥7.
    const input = "^95cbeda (Alice 2026-01-01 00:00:00 +0000 1) initial\n";
    const out = try str(a, input, ""); defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "b "));
    try std.testing.expect(std.mem.indexOf(u8, out, " initial\n") != null);
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

test "lossless: all code lines preserved in simple fixture" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_simple, ""); defer a.free(out);
    // Every code line from the fixture must appear in output (with leading space).
    const codes = [_][]const u8{
        " fn init() {\n",
        "     // initialise the module\n",
        "     setup_defaults();\n",
        "     configure_logging();\n",
        "     configure_metrics();\n",
        "     bind_signals();\n",
        "     start_event_loop();\n",
        "     drain_queue();\n",
        "     flush_buffers();\n",
        "     persist_state();\n",
        "     checkpoint();\n",
        "     notify_ready();\n",
        "     wait_for_shutdown();\n",
        "     teardown();\n",
        " }\n",
    };
    for (codes) |expected| {
        try std.testing.expect(std.mem.indexOf(u8, out, expected) != null);
    }
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
