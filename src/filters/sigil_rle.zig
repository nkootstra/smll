const std = @import("std");
const Allocator = std.mem.Allocator;

// Byte-exact prefix RLE with explicit SIGIL marker.
//
// Unlike the ambiguous prefix_rle in detect.zig, this encoding is provably
// byte-reversible: decode(encode(X)) == X for all X. The SIGIL (0x01, SOH)
// marks elided lines so the decoder can distinguish "naturally short line"
// from "elided remainder, inherit prev prefix".
//
// Escape rule: natural input lines starting with SIGIL are emitted doubled
// (SIGIL + SIGIL + line). Elision is also skipped when the 17th byte of a
// candidate line equals SIGIL, which would otherwise collide with the escape
// marker on the decoder side.

pub const PLEN: usize = 16;
pub const SIGIL: u8 = 0x01;

pub fn encode(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var prev_prefix: []const u8 = "";
    var first_line = true;
    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];

        if (line.len > 0 and line[0] == SIGIL) {
            // Natural SIGIL-prefixed line: escape by doubling.
            try out.append(allocator, SIGIL);
            try out.appendSlice(allocator, line);
        } else {
            const cur_plen = @min(line.len, PLEN);
            const this_prefix = line[0..cur_plen];
            const can_elide = !first_line and
                cur_plen == PLEN and
                std.mem.eql(u8, this_prefix, prev_prefix) and
                (line.len == PLEN or line[PLEN] != SIGIL);
            if (can_elide) {
                try out.append(allocator, SIGIL);
                try out.appendSlice(allocator, line[PLEN..]);
            } else {
                try out.appendSlice(allocator, line);
            }
        }

        // prev_prefix tracks the original line prefix, not the encoded form.
        prev_prefix = line[0..@min(line.len, PLEN)];

        if (i < input.len) {
            try out.append(allocator, '\n');
            i += 1;
        }
        first_line = false;
    }
    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var prev_prefix_buf: [PLEN]u8 = undefined;
    var prev_prefix_len: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];

        if (line.len >= 2 and line[0] == SIGIL and line[1] == SIGIL) {
            // Escaped natural SIGIL-prefixed line: strip one SIGIL.
            const decoded_line = line[1..];
            try out.appendSlice(allocator, decoded_line);
            const plen = @min(decoded_line.len, PLEN);
            @memcpy(prev_prefix_buf[0..plen], decoded_line[0..plen]);
            prev_prefix_len = plen;
        } else if (line.len >= 1 and line[0] == SIGIL) {
            // Elided line: prepend remembered prev_prefix.
            try out.appendSlice(allocator, prev_prefix_buf[0..prev_prefix_len]);
            try out.appendSlice(allocator, line[1..]);
            // prev_prefix is inherited, so no update.
        } else {
            try out.appendSlice(allocator, line);
            const plen = @min(line.len, PLEN);
            @memcpy(prev_prefix_buf[0..plen], line[0..plen]);
            prev_prefix_len = plen;
        }

        if (i < input.len) {
            try out.append(allocator, '\n');
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Round-trip tests
// ---------------------------------------------------------------------------

fn roundTripEq(a: Allocator, input: []const u8) !void {
    const encoded = try encode(a, input);
    defer a.free(encoded);
    const decoded = try decode(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}

test "round-trip: empty input" {
    try roundTripEq(std.testing.allocator, "");
}

test "round-trip: single line without newline" {
    try roundTripEq(std.testing.allocator, "hello world");
}

test "round-trip: simple file listing compresses and round-trips" {
    const input =
        "src/filters/dir/file1.zig\n" ++
        "src/filters/dir/file2.zig\n" ++
        "src/filters/dir/file3.zig\n";
    const a = std.testing.allocator;
    const encoded = try encode(a, input);
    defer a.free(encoded);
    const decoded = try decode(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
    try std.testing.expect(encoded.len < input.len);
}

test "round-trip: short line between long shared-prefix lines" {
    // Line 2 is shorter than PLEN and doesn't share prefix; must not be
    // decoded as inheritance.
    const input =
        "src/filters/dir/longfile.zig\n" ++
        "README.md\n" ++
        "src/filters/dir/another.zig\n";
    try roundTripEq(std.testing.allocator, input);
}

test "round-trip: natural SIGIL at line start is escaped" {
    const input = "\x01natural_sigil_line\nsrc/foo\n";
    try roundTripEq(std.testing.allocator, input);
}

test "round-trip: 17th byte is SIGIL — elision skipped, still byte-exact" {
    const input =
        "abcdefghijklmnopX\n" ++
        "abcdefghijklmnop\x01Y\n";
    try roundTripEq(std.testing.allocator, input);
}

test "round-trip: 20 consecutive identical-prefix lines" {
    const a = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    var n: usize = 0;
    while (n < 20) : (n += 1) {
        try list.appendSlice(a, "src/filters/dir/file");
        try list.append(a, '0' + @as(u8, @intCast(n % 10)));
        try list.append(a, '\n');
    }
    const encoded = try encode(a, list.items);
    defer a.free(encoded);
    const decoded = try decode(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings(list.items, decoded);
    // Each line after first elides 15 bytes (16 prefix - 1 sigil).
    try std.testing.expect(encoded.len < list.items.len);
}

test "round-trip: no trailing newline" {
    try roundTripEq(std.testing.allocator, "line1\nline2");
}

test "round-trip: arbitrary binary-ish bytes (no SIGIL at line start)" {
    try roundTripEq(std.testing.allocator, "\x02\x03\x04foo\n\x05\x06bar\n");
}
