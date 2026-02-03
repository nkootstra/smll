const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const sigil_rle = @import("sigil_rle.zig");

// Byte-exact validator for the sigil-marked prefix RLE rule.
//
// Validates a candidate encoding against the lossless contract by checking
// decode(encode(X)) == X via memcmp. On REJECT, the runtime gate falls back
// to raw passthrough so the output is always correct — the validator
// protects against rule bugs, not just detector misclassification.

pub const Verdict = union(enum) {
    ok,
    reject: Reject,

    pub const Reject = struct {
        offset: usize,
        reason: []const u8,
    };
};

pub fn validateByteExact(
    allocator: Allocator,
    input: []const u8,
    encoded: []const u8,
) !Verdict {
    const decoded = try sigil_rle.decode(allocator, encoded);
    defer allocator.free(decoded);
    if (decoded.len != input.len) {
        return .{ .reject = .{
            .offset = @min(decoded.len, input.len),
            .reason = "length mismatch",
        } };
    }
    for (input, decoded, 0..) |a, b, i| {
        if (a != b) return .{ .reject = .{
            .offset = i,
            .reason = "byte mismatch",
        } };
    }
    return .ok;
}

// Runtime gate for SMLL_VALIDATE=1: encode with sigil_rle, validate, emit
// encoded on OK or raw on REJECT. Passthrough on tiny input (<256 B).
pub fn apply(allocator: Allocator, input: []const u8, writer: *Writer) !void {
    if (input.len == 0) return;
    if (input.len < 256) {
        try writer.writeAll(input);
        return;
    }
    const encoded = try sigil_rle.encode(allocator, input);
    defer allocator.free(encoded);
    const verdict = try validateByteExact(allocator, input, encoded);
    switch (verdict) {
        .ok => try writer.writeAll(encoded),
        .reject => try writer.writeAll(input),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "validateByteExact: OK on genuine round-trip" {
    const a = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    var n: usize = 0;
    while (n < 30) : (n += 1) {
        try list.appendSlice(a, "src/filters/dir/file");
        try list.append(a, '0' + @as(u8, @intCast(n % 10)));
        try list.append(a, '\n');
    }
    const encoded = try sigil_rle.encode(a, list.items);
    defer a.free(encoded);
    const verdict = try validateByteExact(a, list.items, encoded);
    try std.testing.expect(verdict == .ok);
    try std.testing.expect(encoded.len < list.items.len);
}

test "validateByteExact: REJECT on corrupted encoding" {
    const a = std.testing.allocator;
    const input = "src/filters/dir/file1.zig\nsrc/filters/dir/file2.zig\n";
    const encoded = try sigil_rle.encode(a, input);
    defer a.free(encoded);
    // Corrupt one byte to force a mismatch.
    var mutated = try a.dupe(u8, encoded);
    defer a.free(mutated);
    mutated[0] = 'X';
    const verdict = try validateByteExact(a, input, mutated);
    try std.testing.expect(verdict == .reject);
    try std.testing.expectEqualStrings("byte mismatch", verdict.reject.reason);
    try std.testing.expect(verdict.reject.offset == 0);
}

test "apply: passthrough on input under 256 B" {
    const a = std.testing.allocator;
    const input = "tiny\n";
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try apply(a, input, &out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}

test "apply: emits encoded on OK verdict" {
    const a = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);
    var n: usize = 0;
    while (n < 30) : (n += 1) {
        try list.appendSlice(a, "src/filters/dir/file");
        try list.append(a, '0' + @as(u8, @intCast(n % 10)));
        try list.append(a, '\n');
    }
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try apply(a, list.items, &out.writer);
    try std.testing.expect(out.written().len < list.items.len);
    // Decode must reproduce input byte-for-byte.
    const decoded = try sigil_rle.decode(a, out.written());
    defer a.free(decoded);
    try std.testing.expectEqualStrings(list.items, decoded);
}
