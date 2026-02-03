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
// Scope: --files mode only for v0.6.0. Pattern/count/json modes land separately.

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
// Tests
// ---------------------------------------------------------------------------

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
