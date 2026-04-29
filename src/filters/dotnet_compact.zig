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
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    if (containsIgnoreCase(trimmed, ": error ") or containsIgnoreCase(trimmed, ": warning ")) return true;
    if (std.mem.indexOf(u8, trimmed, " error CS") != null or std.mem.indexOf(u8, trimmed, " warning CS") != null) return true;
    if (containsIgnoreCase(trimmed, "build failed")) return true;
    if (containsIgnoreCase(trimmed, "build succeeded")) return true;
    if (containsIgnoreCase(trimmed, "restore failed")) return true;
    if (containsIgnoreCase(trimmed, "restore succeeded")) return true;
    if (containsIgnoreCase(trimmed, "test run failed")) return true;
    if (containsIgnoreCase(trimmed, "failed!")) return true;
    if (containsIgnoreCase(trimmed, "passed!")) return true;
    if (containsIgnoreCase(trimmed, "failed:")) return true;
    if (containsIgnoreCase(trimmed, "passed:")) return true;
    if (containsIgnoreCase(trimmed, "total tests:")) return true;
    if (containsIgnoreCase(trimmed, "failed tests:")) return true;
    if (containsIgnoreCase(trimmed, "format complete")) return true;
    if (containsIgnoreCase(trimmed, "formatted code file")) return true;
    if (containsIgnoreCase(trimmed, "would be formatted")) return true;
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "build errors and summary are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "  Determining projects to restore...\n" ++
        "Program.cs(10,5): error CS1002: ; expected [/tmp/app.csproj]\n" ++
        "Build FAILED.\n" ++
        "    0 Warning(s)\n" ++
        "    1 Error(s)\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "error CS1002") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Build FAILED") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Determining projects") == null);
}

test "build warnings are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "Program.cs(3,1): warning CS0168: variable unused\nBuild succeeded.\n", "", &out.writer);
    try std.testing.expectEqualStrings("Program.cs(3,1): warning CS0168: variable unused\nBuild succeeded.\n", out.written());
}

test "test failure summary is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input = "Test run failed.\nTotal tests: 3\n     Passed: 2\n     Failed: 1\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "Test run failed") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Failed: 1") != null);
}

test "test pass summary is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "Passed!  - Failed: 0, Passed: 12, Skipped: 0, Total: 12\n", "", &out.writer);
    try std.testing.expectEqualStrings("Passed!  - Failed: 0, Passed: 12, Skipped: 0, Total: 12\n", out.written());
}

test "format output is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "Formatted code file '/tmp/A.cs'.\nFormat complete.\n", "", &out.writer);
    try std.testing.expectEqualStrings("Formatted code file '/tmp/A.cs'.\nFormat complete.\n", out.written());
}

test "stderr diagnostics are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "MSBUILD : error MSB1009: Project file does not exist.\n", &out.writer);
    try std.testing.expectEqualStrings("MSBUILD : error MSB1009: Project file does not exist.\n", out.written());
}

test "ansi is stripped" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "\x1b[31mProgram.cs(1,1): error CS1002: bad\x1b[0m\n", "", &out.writer);
    try std.testing.expectEqualStrings("Program.cs(1,1): error CS1002: bad\n", out.written());
}
