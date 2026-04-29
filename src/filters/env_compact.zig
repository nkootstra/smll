const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        try writeLine(raw, writer);
    }
    try writer.writeAll(stderr);
}

fn writeLine(raw: []const u8, writer: *Writer) !void {
    const line = std.mem.trimEnd(u8, raw, "\r");
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
        try writer.writeAll(line);
        try writer.writeByte('\n');
        return;
    };
    const key = line[0..eq];
    const value = line[eq + 1 ..];
    try writer.writeAll(key);
    try writer.writeByte('=');
    if (isSensitiveKey(key)) {
        try writeMasked(value, writer);
    } else if (value.len > 100) {
        try writer.writeAll(value[0..50]);
        try writer.writeAll("...");
    } else {
        try writer.writeAll(value);
    }
    try writer.writeByte('\n');
}

fn isSensitiveKey(key: []const u8) bool {
    return containsIgnoreCase(key, "key") or
        containsIgnoreCase(key, "secret") or
        containsIgnoreCase(key, "password") or
        containsIgnoreCase(key, "token") or
        containsIgnoreCase(key, "credential") or
        containsIgnoreCase(key, "auth") or
        containsIgnoreCase(key, "private") or
        containsIgnoreCase(key, "api_key") or
        containsIgnoreCase(key, "apikey") or
        containsIgnoreCase(key, "access_key") or
        containsIgnoreCase(key, "jwt");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn writeMasked(value: []const u8, writer: *Writer) !void {
    if (value.len <= 4) {
        try writer.writeAll("****");
        return;
    }
    try writer.writeAll(value[0..@min(2, value.len)]);
    try writer.writeAll("****");
    try writer.writeAll(value[value.len - 2 ..]);
}

test "mask short values" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "API_KEY=abc\nEMPTY_TOKEN=\n", "", &out.writer);
    try std.testing.expectEqualStrings("API_KEY=****\nEMPTY_TOKEN=****\n", out.written());
}

test "mask long values preserves prefix and suffix" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "SECRET_TOKEN=supersecrettoken\n", "", &out.writer);
    try std.testing.expectEqualStrings("SECRET_TOKEN=su****en\n", out.written());
}

test "non sensitive values pass through" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "HOME=/tmp/example\nLANG=en_US.UTF-8\n", "", &out.writer);
    try std.testing.expectEqualStrings("HOME=/tmp/example\nLANG=en_US.UTF-8\n", out.written());
}

test "long non sensitive values truncate" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "BIG=abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\n", "", &out.writer);
    try std.testing.expectEqualStrings("BIG=abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwx...\n", out.written());
}

test "stderr preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "env: bad option\n", &out.writer);
    try std.testing.expectEqualStrings("env: bad option\n", out.written());
}
