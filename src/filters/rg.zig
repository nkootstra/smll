const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.6 grammar for `rg --files` output (file-list mode):
//
//   path\n              — full path, literal
//   :remainder\n        — inherit prev line's dirname (through last '/'), append remainder
//   ::escaped\n         — natural path literally starting with ':' (escaped by doubling)
//
// Sigil: ':' (colon). Never appears at the start of a normal filesystem path.
// Decoder rule:
//   - If line starts with "::" → emit line[1..] (escape; natural ':'-prefixed path)
//   - Elif line starts with ":" → emit dirname(prev_decoded) ++ line[1..]
//   - Else → emit line verbatim
//
// Byte-exact lossless. Collision guard: never elide if line[prev_dirname.len] == ':',
// which would otherwise collide with the escape marker on decode.
//
// Scope: --files mode for v0.6.0. Pattern mode (path:line:content) added in v0.7.
//
// v0.7 grammar for `rg <pattern>` output (pattern mode, no-heading, default):
//
//   path:line:content\n          — full match line
//   :line:content\n              — same path as previous line (elided)
//
// Sigil: ':' at start of line. Real rg pattern-mode lines never start with ':'
// because paths begin with '.' '/' or alphanumeric. The decoder:
//   - If line starts with ':' AND second char is a digit → prepend prev_path + ':'
//   - Else → emit verbatim, update prev_path (portion before first ':digit')
//
// Lossless: path, line number, and content are all preserved. The path prefix
// is simply omitted on consecutive lines sharing the same file.
//
// Not activated for rg --count, --files-with-matches, --json, --no-line-number (-N)
// because those formats differ (matchesPattern guards against them).

const SIGIL: u8 = ':';

pub fn matches(input: []const u8) bool {
    if (input.len == 0) return false;
    // Heuristic: first line must look like a path. No ':', no leading whitespace,
    // no control bytes.  rg --files always outputs paths, one per line, no prefix.
    var end: usize = 0;
    while (end < input.len and input[end] != '\n') end += 1;
    const first = input[0..end];
    if (first.len == 0) return false;
    if (first[0] == ' ' or first[0] == '\t') return false;
    if (first[0] < 0x20) return false;
    // Reject lines containing ':' followed by a digit (path:line: pattern-mode shape).
    for (first, 0..) |c, i| {
        if (c == ':' and i > 0 and i + 1 < first.len and first[i + 1] >= '0' and first[i + 1] <= '9') {
            return false;
        }
    }
    return true;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var prev_dirname_len: usize = 0;
    var prev_line: []const u8 = "";
    _ = &prev_line; // silence unused if compiler complains; used below

    var i: usize = 0;
    while (i < stdout.len) {
        const line_start = i;
        while (i < stdout.len and stdout[i] != '\n') i += 1;
        const line = stdout[line_start..i];

        if (line.len > 0 and line[0] == SIGIL) {
            // Escape natural ':'-prefixed path.
            try writer.writeByte(SIGIL);
            try writer.writeAll(line);
        } else if (prev_dirname_len > 0 and
            line.len > prev_dirname_len and
            std.mem.startsWith(u8, line, prev_line[0..prev_dirname_len]) and
            line[prev_dirname_len] != SIGIL)
        {
            try writer.writeByte(SIGIL);
            try writer.writeAll(line[prev_dirname_len..]);
        } else {
            try writer.writeAll(line);
        }

        prev_line = line;
        prev_dirname_len = dirnameLen(line);

        if (i < stdout.len) {
            try writer.writeByte('\n');
            i += 1;
        }
    }
}

pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var prev_decoded: std.ArrayList(u8) = .empty;
    defer prev_decoded.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];

        prev_decoded.clearRetainingCapacity();

        if (line.len >= 2 and line[0] == SIGIL and line[1] == SIGIL) {
            try out.appendSlice(allocator, line[1..]);
            try prev_decoded.appendSlice(allocator, line[1..]);
        } else if (line.len >= 1 and line[0] == SIGIL) {
            // Inherit: we need prev_decoded's dirname. We tracked it in out above.
            // Find the last full line in out (before the most recent '\n') and take its dirname.
            const prev = lastLineOf(out.items);
            const dlen = dirnameLen(prev);
            try out.appendSlice(allocator, prev[0..dlen]);
            try out.appendSlice(allocator, line[1..]);
            try prev_decoded.appendSlice(allocator, prev[0..dlen]);
            try prev_decoded.appendSlice(allocator, line[1..]);
        } else {
            try out.appendSlice(allocator, line);
            try prev_decoded.appendSlice(allocator, line);
        }

        if (i < input.len) {
            try out.append(allocator, '\n');
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn dirnameLen(line: []const u8) usize {
    var k: usize = line.len;
    while (k > 0) : (k -= 1) {
        if (line[k - 1] == '/') return k;
    }
    return 0;
}

fn lastLineOf(buf: []const u8) []const u8 {
    if (buf.len == 0) return buf;
    var end = buf.len;
    if (buf[end - 1] == '\n') end -= 1;
    var start = end;
    while (start > 0 and buf[start - 1] != '\n') start -= 1;
    return buf[start..end];
}

// ---------------------------------------------------------------------------
// Pattern mode (rg <pattern>, default --no-heading output)
// ---------------------------------------------------------------------------

/// Detect a single `path:digits:content` line.
/// Returns the byte index of the first ':' that starts the `:digits:` sequence,
/// or null if the line doesn't match the pattern-mode shape.
fn patternSepIdx(line: []const u8) ?usize {
    if (line.len == 0) return null;
    // Must not start with '{' (JSON mode) or whitespace.
    if (line[0] == '{' or line[0] == ' ' or line[0] == '\t') return null;
    // Find first ':' followed by one or more digits then ':' (the line-number field).
    var i: usize = 1; // path must be at least 1 char
    while (i < line.len) : (i += 1) {
        if (line[i] != ':') continue;
        // Check that at least one digit follows the colon.
        var j = i + 1;
        if (j >= line.len or line[j] < '0' or line[j] > '9') continue;
        while (j < line.len and line[j] >= '0' and line[j] <= '9') j += 1;
        // After the digits must come another ':' (content separator).
        if (j < line.len and line[j] == ':') return i;
    }
    return null;
}

/// True when stdout looks like `rg <pattern>` output (path:line:content format).
/// Requires the first non-empty line to have the `:digits:` shape and at least
/// one more line (single-match output is fine to compress too).
pub fn matchesPattern(input: []const u8) bool {
    if (input.len == 0) return false;
    // Walk lines until we find a non-empty one.
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return patternSepIdx(line) != null;
    }
    return false;
}

/// Encode pattern-mode output: elide repeated path prefixes.
/// Lines sharing the same path as the previous line are emitted as
/// `:digits:content` (path dropped). First occurrence of each path is full.
pub fn applyPattern(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var prev_path_end: usize = 0; // byte length of the path portion of the previous full line
    var prev_line: []const u8 = "";

    var i: usize = 0;
    while (i < stdout.len) {
        const line_start = i;
        while (i < stdout.len and stdout[i] != '\n') i += 1;
        const line = stdout[line_start..i];

        if (line.len == 0) {
            // Preserve blank lines verbatim.
            if (i < stdout.len) {
                try writer.writeByte('\n');
                i += 1;
            }
            continue;
        }

        const sep = patternSepIdx(line);
        if (sep) |s| {
            // This is a pattern line: path is line[0..s], rest is line[s..].
            const can_elide = prev_path_end > 0 and
                s == prev_path_end and
                std.mem.eql(u8, line[0..s], prev_line[0..prev_path_end]);

            if (can_elide) {
                // Drop the path prefix; emit from ':' onwards.
                try writer.writeAll(line[s..]);
            } else {
                try writer.writeAll(line);
                prev_path_end = s;
                prev_line = line;
            }
        } else {
            // Not a pattern line (e.g. context separator "--"): emit verbatim,
            // reset path tracking so next real line is always emitted in full.
            try writer.writeAll(line);
            prev_path_end = 0;
            prev_line = "";
        }

        if (i < stdout.len) {
            try writer.writeByte('\n');
            i += 1;
        }
    }
}

/// Decode pattern-mode encoded output back to the original rg format.
/// Used in tests to verify losslessness.
pub fn decodePattern(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len + input.len / 4);

    var prev_path: std.ArrayList(u8) = .empty;
    defer prev_path.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];

        // Elided line: starts with ':' and second char is a digit.
        if (line.len >= 2 and line[0] == ':' and line[1] >= '0' and line[1] <= '9') {
            try out.appendSlice(allocator, prev_path.items);
            try out.appendSlice(allocator, line);
        } else {
            try out.appendSlice(allocator, line);
            // Update prev_path to the path portion of this line.
            if (patternSepIdx(line)) |s| {
                prev_path.clearRetainingCapacity();
                try prev_path.appendSlice(allocator, line[0..s]);
            } else {
                prev_path.clearRetainingCapacity();
            }
        }

        if (i < input.len) {
            try out.append(allocator, '\n');
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

const fixture_rg_files = @embedFile("fixture_rg_files");

fn applyToString(a: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try apply(a, input, &.{}, &out.writer);
    return a.dupe(u8, out.written());
}

fn roundTrip(a: Allocator, input: []const u8) !void {
    const encoded = try applyToString(a, input);
    defer a.free(encoded);
    const decoded = try decode(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}

test "matches: rg --files output" {
    try std.testing.expect(matches("src/main.zig\nsrc/util.zig\n"));
}

test "matches: pattern-mode output rejected" {
    // rg "pub fn" produces path:line:text — "file.zig:42:pub fn foo..."
    try std.testing.expect(!matches("src/main.zig:42:pub fn main\n"));
}

test "matches: empty input rejected" {
    try std.testing.expect(!matches(""));
}

test "matches: leading whitespace rejected" {
    try std.testing.expect(!matches("  src/main.zig\n"));
}

test "round-trip: empty" {
    try roundTrip(std.testing.allocator, "");
}

test "round-trip: single path" {
    try roundTrip(std.testing.allocator, "src/main.zig\n");
}

test "round-trip: two paths same dir" {
    try roundTrip(std.testing.allocator, "src/a.zig\nsrc/b.zig\n");
}

test "round-trip: nested paths with shared prefix" {
    try roundTrip(std.testing.allocator, "src/main.zig\nsrc/filters/a.zig\nsrc/filters/b.zig\n");
}

test "round-trip: path with colon in middle" {
    try roundTrip(std.testing.allocator, "src/weird:name.zig\nsrc/normal.zig\n");
}

test "round-trip: natural colon-prefixed path escaped" {
    try roundTrip(std.testing.allocator, ":odd-file\nsrc/main.zig\n");
}

test "round-trip: path whose remainder starts with colon — elision skipped" {
    // If prev_dirname = "dir/", cur line = "dir/:tricky" → elide would emit ":::tricky"
    // which collides with escape. Encoder must skip elide and emit full line.
    try roundTrip(std.testing.allocator, "dir/normal.txt\ndir/:tricky\n");
}

test "round-trip: no trailing newline" {
    try roundTrip(std.testing.allocator, "src/a.zig\nsrc/b.zig");
}

test "round-trip: fixture" {
    try roundTrip(std.testing.allocator, fixture_rg_files);
}

test "compression: fixture shrinks significantly" {
    const a = std.testing.allocator;
    const out = try applyToString(a, fixture_rg_files);
    defer a.free(out);
    // Fixture is 19 paths, 15 sharing "src/filters/" (12 bytes) + 3 sharing "src/" (4 bytes).
    // Expected savings: 15 * 11 + 3 * 3 ≈ 174 bytes of 455 = ~38%.
    const savings_pct = (fixture_rg_files.len - out.len) * 100 / fixture_rg_files.len;
    try std.testing.expect(savings_pct >= 30);
}

// ---------------------------------------------------------------------------
// Pattern-mode tests
// ---------------------------------------------------------------------------

fn applyPatternToString(a: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try applyPattern(a, input, &.{}, &out.writer);
    return a.dupe(u8, out.written());
}

fn roundTripPattern(a: Allocator, input: []const u8) !void {
    const encoded = try applyPatternToString(a, input);
    defer a.free(encoded);
    const decoded = try decodePattern(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}

test "matchesPattern: accepts path:line:content" {
    try std.testing.expect(matchesPattern("src/main.zig:42:pub fn main\n"));
    try std.testing.expect(matchesPattern("./src/main.zig:1:hello\n"));
    try std.testing.expect(matchesPattern("/abs/path.zig:99:content\n"));
}

test "matchesPattern: rejects --files output (no line number)" {
    try std.testing.expect(!matchesPattern("src/main.zig\nsrc/util.zig\n"));
}

test "matchesPattern: rejects --count output (path:N no trailing colon)" {
    try std.testing.expect(!matchesPattern("src/main.zig:42\n"));
}

test "matchesPattern: rejects JSON output" {
    try std.testing.expect(!matchesPattern("{\"type\":\"begin\"}\n"));
}

test "matchesPattern: rejects empty" {
    try std.testing.expect(!matchesPattern(""));
}

test "pattern round-trip: single match" {
    try roundTripPattern(std.testing.allocator, "src/main.zig:42:pub fn main\n");
}

test "pattern round-trip: multiple matches same file" {
    try roundTripPattern(std.testing.allocator,
        "src/main.zig:7:pub fn matches\n" ++
        "src/main.zig:12:pub fn apply\n" ++
        "src/main.zig:21:pub fn run\n");
}

test "pattern round-trip: multiple files" {
    try roundTripPattern(std.testing.allocator,
        "src/main.zig:7:pub fn matches\n" ++
        "src/main.zig:12:pub fn apply\n" ++
        "src/util.zig:4:pub fn isHex40\n" ++
        "src/util.zig:12:pub fn sha7\n");
}

test "pattern round-trip: no trailing newline" {
    try roundTripPattern(std.testing.allocator,
        "src/main.zig:7:hello\n" ++
        "src/main.zig:8:world");
}

test "pattern round-trip: colon in content" {
    try roundTripPattern(std.testing.allocator,
        "src/main.zig:7:url: http://example.com\n" ++
        "src/main.zig:8:key: value: extra\n");
}

test "pattern round-trip: context separator (--)" {
    try roundTripPattern(std.testing.allocator,
        "src/main.zig:7:pub fn foo\n" ++
        "--\n" ++
        "src/util.zig:4:pub fn bar\n");
}

test "pattern compression: repeated path elided" {
    const a = std.testing.allocator;
    const input =
        "src/main.zig:7:pub fn matches\n" ++
        "src/main.zig:12:pub fn apply\n" ++
        "src/main.zig:21:pub fn run\n" ++
        "src/util.zig:4:pub fn isHex40\n" ++
        "src/util.zig:12:pub fn sha7\n";
    const encoded = try applyPatternToString(a, input);
    defer a.free(encoded);
    try std.testing.expect(std.mem.startsWith(u8, encoded, "src/main.zig:7:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, encoded, 1, "\n:12:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, encoded, 1, "\n:21:"));
    try std.testing.expect(encoded.len < input.len);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, encoded, "src/main.zig"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, encoded, "src/util.zig"));
}
