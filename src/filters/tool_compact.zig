const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const gh_pr_state_field = 3;

pub fn applyPackage(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    try scanKeep(allocator, stdout, stderr, writer, shouldKeepPackage, writeRawLine, false, "ok\n");
}

pub fn applyAppleBuild(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    try scanKeep(allocator, stdout, stderr, writer, shouldKeepAppleBuild, writeRawLine, false, "ok\n");
}

pub fn applyGh(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    try scanKeep(allocator, stdout, stderr, writer, shouldKeepGh, writeGhLine, true, "ok\n");
}

pub fn matchesPupTable(input: []const u8) bool {
    var saw_border = false;
    var saw_row = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (isPupBorderLine(line)) {
            saw_border = true;
        } else if (isPupPipeRow(line)) {
            saw_row = true;
        }
    }
    return saw_border and saw_row;
}

pub fn applyPupTable(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(allocator);

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, "\r");
        if (line.len == 0 or isPupBorderLine(line) or isPupSeparatorRow(line)) continue;
        if (!isPupPipeRow(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        fields.clearRetainingCapacity();
        try splitPupPipeFields(allocator, line, &fields);
        while (fields.items.len > 0 and fields.items[fields.items.len - 1].len == 0) {
            _ = fields.pop();
        }
        if (fields.items.len == 0) continue;
        for (fields.items, 0..) |field, idx| {
            if (idx > 0) try writer.writeByte('\t');
            try writer.writeAll(field);
        }
        try writer.writeByte('\n');
    }
}

fn scanKeep(
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    writer: *Writer,
    comptime keepFn: fn ([]const u8) bool,
    comptime writeFn: fn (*Writer, []const u8) anyerror!void,
    comptime preserve_trailing_tabs: bool,
    empty_msg: []const u8,
) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var kept: usize = 0;
    try scanOne(allocator, stdout, writer, &strip_buf, &kept, keepFn, writeFn, preserve_trailing_tabs);
    try scanOne(allocator, stderr, writer, &strip_buf, &kept, keepFn, writeFn, preserve_trailing_tabs);
    if (kept == 0 and stdout.len > 0 and stderr.len == 0) try writer.writeAll(empty_msg);
}

fn scanOne(
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    strip_buf: *std.ArrayList(u8),
    kept: *usize,
    comptime keepFn: fn ([]const u8) bool,
    comptime writeFn: fn (*Writer, []const u8) anyerror!void,
    comptime preserve_trailing_tabs: bool,
) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const clean = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        if (keepFn(line)) {
            const write_line = if (preserve_trailing_tabs)
                std.mem.trimEnd(u8, clean, "\r")
            else
                line;
            try writeFn(writer, write_line);
            try writer.writeByte('\n');
            kept.* += 1;
        }
    }
}

fn writeRawLine(writer: *Writer, line: []const u8) !void {
    try writer.writeAll(line);
}

fn writeGhLine(writer: *Writer, line: []const u8) !void {
    if (try writeCompactGhTabularRow(writer, line)) return;
    try writer.writeAll(line);
}

fn splitPupPipeFields(allocator: Allocator, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    const start: usize = if (line.len > 0 and line[0] == '|') 1 else 0;
    const end: usize = if (line.len > start and line[line.len - 1] == '|') line.len - 1 else line.len;
    var fields = std.mem.splitScalar(u8, line[start..end], '|');
    while (fields.next()) |field| {
        try out.append(allocator, std.mem.trim(u8, field, " \t"));
    }
}

fn isPupPipeRow(line: []const u8) bool {
    return line.len >= 2 and line[0] == '|' and std.mem.indexOfScalar(u8, line[1..], '|') != null;
}

fn isPupBorderLine(line: []const u8) bool {
    if (line.len == 0 or line[0] != '+') return false;
    var saw_rule = false;
    for (line) |c| {
        switch (c) {
            '+', '-', '=' => saw_rule = true,
            else => return false,
        }
    }
    return saw_rule;
}

fn isPupSeparatorRow(line: []const u8) bool {
    if (!isPupPipeRow(line)) return false;
    var saw_rule = false;
    for (line) |c| {
        switch (c) {
            '|', '-' => saw_rule = true,
            else => return false,
        }
    }
    return saw_rule;
}

fn writeCompactGhTabularRow(writer: *Writer, line: []const u8) !bool {
    if (!isGhTabularRow(line)) return false;

    var fields = std.mem.splitScalar(u8, line, '\t');
    var field_idx: usize = 0;
    while (fields.next()) |field| : (field_idx += 1) {
        if (field_idx > 0) try writer.writeByte('\t');
        if (looksLikeIsoTimestamp(field)) {
            try writer.writeAll(field[0..10]);
        } else if (field_idx == gh_pr_state_field) {
            try writer.writeAll(compactGhPrState(field));
        } else {
            try writer.writeAll(field);
        }
    }
    return true;
}

fn compactGhPrState(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "OPEN")) return "O";
    if (std.mem.eql(u8, state, "CLOSED")) return "C";
    if (std.mem.eql(u8, state, "MERGED")) return "M";
    return state;
}

fn looksLikeIsoTimestamp(field: []const u8) bool {
    return field.len >= 20 and
        field[4] == '-' and field[7] == '-' and field[10] == 'T' and
        field[field.len - 1] == 'Z' and
        allAsciiDigits(field[0..4]) and allAsciiDigits(field[5..7]) and
        allAsciiDigits(field[8..10]);
}

fn looksLikeDate(field: []const u8) bool {
    return field.len == 10 and
        field[4] == '-' and field[7] == '-' and
        allAsciiDigits(field[0..4]) and allAsciiDigits(field[5..7]) and
        allAsciiDigits(field[8..10]);
}

fn shouldKeepPackage(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (std.mem.startsWith(u8, t, "Preparing packages")) return false;
    if (isPackageChangeLine(t)) return true;
    return contains(t, "ERR!") or contains(t, "WARN") or containsIgnore(t, "error") or
        containsIgnore(t, "failed") or containsIgnore(t, "deprecated") or
        containsIgnore(t, "vulnerab") or containsIgnore(t, "added ") or
        containsIgnore(t, "removed ") or containsIgnore(t, "changed ") or
        containsIgnore(t, "packages") or containsIgnore(t, "done in") or
        std.mem.startsWith(u8, t, "✓") or std.mem.startsWith(u8, t, "✕");
}

fn isPackageChangeLine(line: []const u8) bool {
    if (!(std.mem.startsWith(u8, line, "+ ") or std.mem.startsWith(u8, line, "- "))) return false;
    const rest = std.mem.trim(u8, line[2..], " \t");
    return rest.len > 0 and std.mem.indexOf(u8, rest, "==") != null;
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
        containsGhCheckStatus(t, "pass") or containsGhCheckStatus(t, "fail") or
        containsGhCheckStatus(t, "skipping") or containsGhCheckStatus(t, "cancel") or
        isGhTabularRow(t) or
        containsIgnore(t, "pull request") or containsIgnore(t, "issue") or
        contains(t, "https://") or contains(t, "#");
}

fn isGhTabularRow(line: []const u8) bool {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const first = fields.next() orelse return false;

    var field_count: usize = 1;
    var has_date = looksLikeIsoTimestamp(first) or looksLikeDate(first);
    while (fields.next()) |field| {
        field_count += 1;
        if (looksLikeIsoTimestamp(field) or looksLikeDate(field)) has_date = true;
    }
    if (field_count < 3) return false;
    return allAsciiDigits(first) or has_date;
}

fn allAsciiDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn containsGhCheckStatus(line: []const u8, status: []const u8) bool {
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field, status)) return true;
    }
    return false;
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

test "package keeps uv install package result lines" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "  Preparing packages...\n" ++
        "Installed 5 packages in 23ms\n" ++
        " + certifi==2023.11.17\n" ++
        " + requests==2.31.0\n";
    try applyPackage(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings(
        "Installed 5 packages in 23ms\n" ++
            " + certifi==2023.11.17\n" ++
            " + requests==2.31.0\n",
        out.written(),
    );
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
