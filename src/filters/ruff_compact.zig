const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var kept: usize = 0;
    try scan(allocator, stdout, writer, &strip_buf, &kept);
    try scan(allocator, stderr, writer, &strip_buf, &kept);
}

fn scan(allocator: Allocator, input: []const u8, writer: *Writer, strip_buf: *std.ArrayList(u8), kept: *usize) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const clean = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        if (shouldKeep(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            kept.* += 1;
        }
    }
}

fn shouldKeep(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "All checks passed")) return true;
    if (std.mem.endsWith(u8, line, "would be reformatted") or std.mem.endsWith(u8, line, "left unchanged")) return true;
    if (std.mem.indexOf(u8, line, " files would be reformatted") != null) return true;
    if (std.mem.indexOf(u8, line, " files left unchanged") != null) return true;
    return looksLikeDiagnostic(line);
}

fn looksLikeDiagnostic(line: []const u8) bool {
    // Ruff text format: path:line:col: CODE message
    const c1 = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    var p = c1 + 1;
    const d1 = p;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    if (p == d1 or p >= line.len or line[p] != ':') return false;
    p += 1;
    const d2 = p;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    return p > d2 and p < line.len and line[p] == ':';
}

test "ruff check diagnostics are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input = "src/a.py:1:8: F401 `os` imported but unused\nFound 1 error.\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings("src/a.py:1:8: F401 `os` imported but unused\n", out.written());
}

test "ruff no issues summary is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "All checks passed!\n", "", &out.writer);
    try std.testing.expectEqualStrings("All checks passed!\n", out.written());
}

test "ruff format summary is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "1 file would be reformatted, 2 files left unchanged\n", "", &out.writer);
    try std.testing.expectEqualStrings("1 file would be reformatted, 2 files left unchanged\n", out.written());
}

test "ruff stderr diagnostics are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "src/a.py:2:1: E402 module level import not at top of file\n", &out.writer);
    try std.testing.expectEqualStrings("src/a.py:2:1: E402 module level import not at top of file\n", out.written());
}

test "ansi is stripped" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "\x1b[31msrc/a.py:1:8: F401 bad\x1b[0m\n", "", &out.writer);
    try std.testing.expectEqualStrings("src/a.py:1:8: F401 bad\n", out.written());
}
