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
    if (kept == 0 and stdout.len == 0 and stderr.len == 0) return;
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
    return std.mem.indexOf(u8, line, ": error:") != null or
        std.mem.indexOf(u8, line, ": note:") != null or
        std.mem.startsWith(u8, line, "Found ") or
        std.mem.startsWith(u8, line, "Success: ") or
        std.mem.startsWith(u8, line, "mypy: ");
}

test "mypy errors are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "src/a.py:10: error: Incompatible types [assignment]\n" ++
        "src/b.py:3: note: Revealed type is builtins.str\n" ++
        "Found 1 error in 1 file (checked 2 source files)\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}

test "mypy success summary is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "Success: no issues found in 12 source files\n", "", &out.writer);
    try std.testing.expectEqualStrings("Success: no issues found in 12 source files\n", out.written());
}

test "mypy stderr diagnostics are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "mypy: can't read file 'missing.py': No such file or directory\n", &out.writer);
    try std.testing.expectEqualStrings("mypy: can't read file 'missing.py': No such file or directory\n", out.written());
}

test "mypy drops progress chatter" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "LOG:  Processing SCC\nsrc/a.py:1: error: bad [misc]\n", "", &out.writer);
    try std.testing.expectEqualStrings("src/a.py:1: error: bad [misc]\n", out.written());
}

test "ansi is stripped" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "\x1b[31msrc/a.py:1: error: bad [misc]\x1b[0m\n", "", &out.writer);
    try std.testing.expectEqualStrings("src/a.py:1: error: bad [misc]\n", out.written());
}
