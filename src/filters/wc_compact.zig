const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    if (stdout.len == 0) {
        try writer.writeAll(stderr);
        return;
    }

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        try compactLine(raw, writer);
        try writer.writeByte('\n');
    }
    try writer.writeAll(stderr);
}

fn compactLine(raw: []const u8, writer: *Writer) !void {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0) return;

    var pos: usize = 0;
    var counts: usize = 0;
    while (pos < line.len and counts < 3) {
        const start = pos;
        while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') pos += 1;
        if (pos == start) break;
        if (counts > 0) try writer.writeByte(' ');
        try writer.writeAll(line[start..pos]);
        counts += 1;
        while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    }

    if (counts == 0) {
        try writer.writeAll(raw);
        return;
    }

    if (pos < line.len) {
        try writer.writeByte(' ');
        try writer.writeAll(line[pos..]);
    }
}

test "single file full wc output collapses padding" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "      12      34     567 README.md\n", "", &out.writer);
    try std.testing.expectEqualStrings("12 34 567 README.md\n", out.written());
}

test "lines only output keeps count and path" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "      42 src/main.zig\n", "", &out.writer);
    try std.testing.expectEqualStrings("42 src/main.zig\n", out.written());
}

test "stdin count without filename" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "      3       9      27\n", "", &out.writer);
    try std.testing.expectEqualStrings("3 9 27\n", out.written());
}

test "multiple files and total" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "       1       2      10 a.txt\n" ++
        "      20      30     400 b.txt\n" ++
        "      21      32     410 total\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings(
        "1 2 10 a.txt\n20 30 400 b.txt\n21 32 410 total\n",
        out.written(),
    );
}

test "stderr is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "wc: missing: No such file or directory\n", &out.writer);
    try std.testing.expectEqualStrings("wc: missing: No such file or directory\n", out.written());
}
