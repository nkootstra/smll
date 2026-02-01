const std = @import("std");

/// True when `s` is exactly 40 hexadecimal characters — the shape of a git SHA-1.
pub fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Truncate a git SHA to the 7-char short form used across v0.4 grammars.
/// Caller guarantees `full.len >= 7`.
pub fn sha7(full: []const u8) [7]u8 {
    var out: [7]u8 = undefined;
    @memcpy(&out, full[0..7]);
    return out;
}

test "isHex40: exact 40-char hex returns true" {
    try std.testing.expect(isHex40("95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37"));
    try std.testing.expect(isHex40("0123456789abcdef0123456789ABCDEF01234567"));
}

test "isHex40: wrong length returns false" {
    try std.testing.expect(!isHex40(""));
    try std.testing.expect(!isHex40("abc"));
    try std.testing.expect(!isHex40("95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f3"));
    try std.testing.expect(!isHex40("95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f370"));
}

test "isHex40: non-hex char returns false" {
    try std.testing.expect(!isHex40("95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0fXY"));
    try std.testing.expect(!isHex40("g5cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37"));
}

test "sha7: extracts first 7 chars of a 40-char SHA" {
    const full = "95cbeda7f53ff8b55d96fa2b5a6ffda1d2da0f37";
    const short = sha7(full);
    try std.testing.expectEqualSlices(u8, "95cbeda", &short);
}

test "sha7: works on exactly-7-char input" {
    const short = sha7("abc1234");
    try std.testing.expectEqualSlices(u8, "abc1234", &short);
}
