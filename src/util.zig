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

/// True when a trimmed line starts with hex chars followed by ".." — a git ref-update line.
pub fn isRefUpdateLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and i < 82) : (i += 1) {
        if (line[i] == '.' and i + 1 < line.len and line[i + 1] == '.') {
            if (i < 4) return false;
            for (line[0..i]) |c| if (!std.ascii.isHex(c)) return false;
            return true;
        }
    }
    return false;
}

/// Write "<sigil> sha7..sha7 <rest>\n" from a trimmed ref-update line.
pub fn writeRefUpdateLine(line: []const u8, writer: anytype, sigil: u8) !void {
    const dot_pos = std.mem.indexOf(u8, line, "..") orelse return;
    const sha_a = line[0..dot_pos];
    const after_dot = line[dot_pos + 2 ..];
    var sha_b_end: usize = 0;
    while (sha_b_end < after_dot.len and after_dot[sha_b_end] != ' ') sha_b_end += 1;
    const sha_b = after_dot[0..sha_b_end];
    const rest = std.mem.trim(u8, after_dot[sha_b_end..], " \t");
    const a7 = sha_a[0..@min(sha_a.len, 7)];
    const b7 = sha_b[0..@min(sha_b.len, 7)];
    try writer.writeByte(sigil);
    try writer.writeByte(' ');
    try writer.writeAll(a7);
    try writer.writeAll("..");
    try writer.writeAll(b7);
    if (rest.len > 0) {
        try writer.writeByte(' ');
        try writer.writeAll(rest);
    }
    try writer.writeByte('\n');
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
