const std = @import("std");

/// True when `line` is a git transfer progress line that should be filtered.
pub fn isGitProgressLine(line: []const u8) bool {
    if (line.len == 0) return false;
    return switch (line[0]) {
        'r' => std.mem.startsWith(u8, line, "remote"),
        'C' => std.mem.startsWith(u8, line, "Counting") or std.mem.startsWith(u8, line, "Compressing"),
        'R' => std.mem.startsWith(u8, line, "Receiving") or std.mem.startsWith(u8, line, "Resolving"),
        'W' => std.mem.startsWith(u8, line, "Writing objects"),
        'T' => std.mem.startsWith(u8, line, "Total "),
        'D' => std.mem.startsWith(u8, line, "Delta "),
        else => false,
    };
}

/// Handle bracket-tagged ref lines like [new branch], [deleted], [rejected].
/// Returns true if the line was handled.
pub fn handleBracketRef(line: []const u8, writer: *std.Io.Writer) !bool {
    if (std.mem.find(u8, line, "[new branch]") != null or
        std.mem.find(u8, line, "[new tag]") != null)
    {
        const bracket_end = std.mem.find(u8, line, "]") orelse return false;
        const after = std.mem.trim(u8, line[bracket_end + 1 ..], " \t");
        try writer.writeAll("+ new ");
        try writer.writeAll(after);
        try writer.writeByte('\n');
        return true;
    }
    if (std.mem.find(u8, line, "[deleted]") != null) {
        const bracket_end = std.mem.find(u8, line, "]") orelse return false;
        const ref = std.mem.trim(u8, line[bracket_end + 1 ..], " \t");
        if (ref.len > 0) {
            try writer.writeAll("- deleted ");
            try writer.writeAll(ref);
            try writer.writeByte('\n');
        }
        return true;
    }
    if (std.mem.find(u8, line, "[rejected]") != null) {
        const bracket_end = std.mem.find(u8, line, "]") orelse return false;
        const rest = std.mem.trim(u8, line[bracket_end + 1 ..], " \t");
        if (rest.len > 0) {
            try writer.writeAll("! rejected ");
            try writer.writeAll(rest);
            try writer.writeByte('\n');
        }
        return true;
    }
    return false;
}

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
    const dot_pos = std.mem.find(u8, line, "..") orelse return;
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

/// Write a compressed stat line "<path> |<N>\n" from a trimmed git stat line.
/// Input: "path | N +++---"  Output: "path |N\n"
pub noinline fn writeStatLine(t: []const u8, writer: *std.Io.Writer) !void {
    const pipe = std.mem.find(u8, t, " | ") orelse {
        try writer.writeAll(t); try writer.writeByte('\n'); return;
    };
    const after = t[pipe + 3 ..];
    var ne: usize = 0;
    while (ne < after.len and std.ascii.isDigit(after[ne])) ne += 1;
    try writer.writeAll(t[0..pipe]);
    try writer.writeAll(" |");
    try writer.writeAll(after[0..ne]);
    try writer.writeByte('\n');
}

/// Write "+<ins>/-<del> files=<N>\n" from a git stat summary line.
/// Input: " 3 files changed, 10 insertions(+), 2 deletions(-)"
pub noinline fn writeSummary(t: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeByte('+');
    try writer.writeAll(extractN(t, " insertion"));
    try writer.writeAll("/-");
    try writer.writeAll(extractN(t, " deletion"));
    try writer.writeAll(" files=");
    try writer.writeAll(firstNum(t));
    try writer.writeByte('\n');
}

fn extractN(s: []const u8, marker: []const u8) []const u8 {
    const idx = std.mem.find(u8, s, marker) orelse return "0";
    var e = idx; while (e > 0 and s[e-1] == ' ') e -= 1;
    var b = e; while (b > 0 and std.ascii.isDigit(s[b-1])) b -= 1;
    return if (b < e) s[b..e] else "0";
}

fn firstNum(s: []const u8) []const u8 {
    var i: usize = 0; while (i < s.len and !std.ascii.isDigit(s[i])) i += 1;
    var j = i; while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    return if (i < j) s[i..j] else "0";
}

/// Skip a mode number token (e.g. "100644 ") and return the remainder.
pub fn skipModeNum(s: []const u8) []const u8 {
    return if (std.mem.findScalar(u8, s, ' ')) |sp| s[sp + 1 ..] else s;
}

/// Extract the conflicted path from a CONFLICT line.
/// "CONFLICT (...): Merge conflict in <path>" → "<path>"
/// Falls back to text after ": " if no " in " marker found.
pub noinline fn conflictPath(line: []const u8) []const u8 {
    if (std.mem.findLast(u8, line, " in ")) |p| {
        return std.mem.trim(u8, line[p + 4 ..], " \t\r");
    }
    if (std.mem.find(u8, line, ": ")) |c| {
        return std.mem.trim(u8, line[c + 2 ..], " \t\r");
    }
    return "";
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
