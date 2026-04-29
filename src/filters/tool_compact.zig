const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn applyPackage(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    try scanKeep(allocator, stdout, stderr, writer, shouldKeepPackage, "ok\n");
}

pub fn applyAppleBuild(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    try scanKeep(allocator, stdout, stderr, writer, shouldKeepAppleBuild, "ok\n");
}

pub fn applyGh(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    try scanKeep(allocator, stdout, stderr, writer, shouldKeepGh, "ok\n");
}

fn scanKeep(
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    writer: *Writer,
    comptime keepFn: fn ([]const u8) bool,
    empty_msg: []const u8,
) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var kept: usize = 0;
    try scanOne(allocator, stdout, writer, &strip_buf, &kept, keepFn);
    try scanOne(allocator, stderr, writer, &strip_buf, &kept, keepFn);
    if (kept == 0 and stdout.len > 0 and stderr.len == 0) try writer.writeAll(empty_msg);
}

fn scanOne(
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    strip_buf: *std.ArrayList(u8),
    kept: *usize,
    comptime keepFn: fn ([]const u8) bool,
) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const clean = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        if (keepFn(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            kept.* += 1;
        }
    }
}

fn shouldKeepPackage(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return contains(t, "ERR!") or contains(t, "WARN") or containsIgnore(t, "error") or
        containsIgnore(t, "failed") or containsIgnore(t, "deprecated") or
        containsIgnore(t, "vulnerab") or containsIgnore(t, "added ") or
        containsIgnore(t, "removed ") or containsIgnore(t, "changed ") or
        containsIgnore(t, "packages") or containsIgnore(t, "done in") or
        std.mem.startsWith(u8, t, "✓") or std.mem.startsWith(u8, t, "✕");
}

fn shouldKeepAppleBuild(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return containsIgnore(t, "error:") or containsIgnore(t, "warning:") or
        contains(t, "** BUILD FAILED **") or contains(t, "** BUILD SUCCEEDED **") or
        contains(t, "** TEST FAILED **") or contains(t, "** TEST SUCCEEDED **") or
        contains(t, "SwiftCompile") or contains(t, "CompileSwift") or
        contains(t, "Failing tests:") or contains(t, "Test Suite") or
        contains(t, "Executed ");
}

fn shouldKeepGh(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return containsIgnore(t, "error") or containsIgnore(t, "failed") or
        containsIgnore(t, "failure") or containsIgnore(t, "cancelled") or
        containsIgnore(t, "success") or containsIgnore(t, "passed") or
        containsIgnore(t, "pending") or containsIgnore(t, "usage:") or
        containsIgnore(t, "pull request") or containsIgnore(t, "issue") or
        contains(t, "https://") or contains(t, "#");
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn containsIgnore(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

test "package keeps install summary and warnings" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPackage(std.testing.allocator, "Progress: resolved 1\nWARN deprecated left-pad\nadded 12 packages\n", "", &out.writer);
    try std.testing.expectEqualStrings("WARN deprecated left-pad\nadded 12 packages\n", out.written());
}

test "package keeps stderr errors" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPackage(std.testing.allocator, "", "ERR! failed to resolve dependency\n", &out.writer);
    try std.testing.expectEqualStrings("ERR! failed to resolve dependency\n", out.written());
}

test "apple build keeps errors and summary" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyAppleBuild(std.testing.allocator, "CompileSwift A.swift\nA.swift:1:1: error: bad\n** BUILD FAILED **\n", "", &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "error: bad") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "BUILD FAILED") != null);
}

test "gh keeps errors and urls" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyGh(std.testing.allocator, "noise\nhttps://github.com/o/r/pull/1\nerror: nope\n", "", &out.writer);
    try std.testing.expectEqualStrings("https://github.com/o/r/pull/1\nerror: nope\n", out.written());
}
