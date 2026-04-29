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
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or isSeparator(line) or isHeader(line)) continue;
        try writeCollapsed(line, writer);
        try writer.writeByte('\n');
    }
    try writer.writeAll(stderr);
}

fn isSeparator(line: []const u8) bool {
    var saw_dash = false;
    for (line) |c| {
        if (c == '-') {
            saw_dash = true;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return saw_dash;
}

fn isHeader(line: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(line, "Package ") or std.ascii.eqlIgnoreCase(line, "Package Version");
}

fn writeCollapsed(line: []const u8, writer: *Writer) !void {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var first = true;
    while (it.next()) |tok| {
        if (!first) try writer.writeByte(' ');
        first = false;
        try writer.writeAll(tok);
    }
}

test "pip list table collapses padding" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "Package    Version\n" ++
        "---------- -------\n" ++
        "requests   2.31.0\n" ++
        "urllib3    2.0.7\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings("requests 2.31.0\nurllib3 2.0.7\n", out.written());
}

test "pip list empty leaves no package rows" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "Package Version\n------- -------\n", "", &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "pip outdated table keeps latest and type" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "Package Version Latest Type\n" ++
        "------- ------- ------ -----\n" ++
        "pip     23.0    24.0   wheel\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings("pip 23.0 24.0 wheel\n", out.written());
}

test "stderr is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "ERROR: no such option\n", &out.writer);
    try std.testing.expectEqualStrings("ERROR: no such option\n", out.written());
}
