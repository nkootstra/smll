const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `find -ls` — on by default (v0.6).
// Set SMLL_LOSSLESS=1 to bypass.
//
// `find -ls` emits columns: inode, blocks, mode, nlink, user, group,
// size, month, day, time/year, path. All but the path are dropped.
// Directory marker (trailing "/") is added when the mode starts with
// "d", mirroring `ls -F` conventions used by ls_compact.
//
// Contract:
//   • Lossy — inode, mode bits, ownership, size, timestamps gone.
//   • Path list preserved in input order. Paths with embedded
//     whitespace are preserved verbatim.
//   • Typical reduction ~70-85% on GNU/BSD `find -ls` output.
//
// Detection (matches):
//   • First non-empty line: leading digit(s), followed by at least 10
//     whitespace-separated tokens (i.e. a trailing path exists after
//     field 10). Both GNU and BSD `find -ls` share this shape.
//   • Reject if any non-empty line fails the inode-leading check.

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var saw_any = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!isFindLsLine(line)) return false;
        saw_any = true;
    }
    return saw_any;
}

fn isFindLsLine(line: []const u8) bool {
    if (line.len == 0) return false;
    // Leading optional whitespace (BSD find -ls indents the inode).
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return false;
    // Inode must be all digits.
    const inode_start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') i += 1;
    if (i == inode_start) return false;
    if (i >= line.len or (line[i] != ' ' and line[i] != '\t')) return false;
    // Require at least 10 further whitespace-separated tokens followed
    // by a path. extractPath handles the tokenization; we just confirm
    // it succeeds.
    return extractPath(line) != null;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!isFindLsLine(line)) continue;
        const path = extractPath(line) orelse continue;
        if (path.len == 0) continue;
        if (!first) try writer.writeByte('\n');
        first = false;
        try writer.writeAll(path);
        // Directory marker: mode is field 3 (inode, blocks, mode). If
        // mode starts with 'd', append '/'. extractMode returns the
        // third whitespace-separated token.
        if (extractMode(line)) |mode| {
            if (mode.len > 0 and mode[0] == 'd') try writer.writeByte('/');
        }
    }
    if (!first) try writer.writeByte('\n');
}

/// Skip 10 whitespace-separated fields (inode, blocks, mode, nlink,
/// user, group, size, month, day, time-or-year). Return the rest of
/// the line (path; may contain spaces). Returns null if the line has
/// fewer than 10 fields + a path.
fn extractPath(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    var fields_consumed: usize = 0;
    while (i < line.len and fields_consumed < 10) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) return null;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
        fields_consumed += 1;
    }
    if (fields_consumed < 10) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return null;
    return std.mem.trimEnd(u8, line[i..], " \t\r");
}

fn extractMode(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    var field_index: usize = 0;
    while (i < line.len and field_index < 2) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) return null;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
        field_index += 1;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return null;
    const start = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    return line[start..i];
}

test "matches: GNU find -ls line" {
    const input = "2055938    0 drwxr-xr-x   2 user     staff          64 Apr 23 12:34 ./path\n";
    try std.testing.expect(matches(input));
}

test "matches: BSD find -ls with leading whitespace on inode" {
    const input = "  2055938 0 drwxr-xr-x   2 user staff 64 Apr 23 12:34 ./path\n";
    try std.testing.expect(matches(input));
}

test "matches: rejects non-find output" {
    try std.testing.expect(!matches("hello world\n"));
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("drwxr-xr-x 1 a b 1 Apr 1 00:00 x\n"));
    // Fewer than 10 fields before path.
    try std.testing.expect(!matches("2055938 0 drwxr-xr-x ./path\n"));
}

test "matches: mixed lines rejected" {
    const bad = "2055938    0 drwxr-xr-x   2 user staff 64 Apr 23 12:34 ./path\nnot a find line\n";
    try std.testing.expect(!matches(bad));
}

test "apply: GNU find -ls small fixture → path list" {
    const input =
        "2055938    0 drwxr-xr-x   2 user staff 64 Apr 23 12:34 ./src\n" ++
        "2055939    8 -rw-r--r--   1 user staff 421 Apr 23 12:34 ./src/main.zig\n" ++
        "2055940    8 -rw-r--r--   1 user staff 123 Apr 23 12:34 ./README.md\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings(
        "./src/\n./src/main.zig\n./README.md\n",
        out.written(),
    );
}

test "apply: filename with spaces preserved" {
    const input = "2055938 0 -rw-r--r-- 1 user staff 10 Apr 23 12:34 ./hello world.txt\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("./hello world.txt\n", out.written());
}

test "apply: empty input → empty output" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", &.{}, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: BSD-style indented output" {
    const input = "  2055938 0 drwxr-xr-x 2 user staff 64 Apr 23 12:34 ./dir\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("./dir/\n", out.written());
}

test "apply: small fixture reduces output and keeps paths" {
    const fixture = @embedFile("fixture_find_ls");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, fixture, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "./src/main.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "./src/") != null);
    try std.testing.expect(std.mem.find(u8, got, "./README.md") != null);
    try std.testing.expect(std.mem.find(u8, got, "user") == null);
}

test "apply: 60% reduction on synthetic fixture" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (0..50) |i| {
        const line = try std.fmt.allocPrint(
            alloc,
            "205{d:0>4}    8 -rw-r--r--   1 user staff 421 Apr 23 12:34 ./src/file_{d}.zig\n",
            .{ i, i },
        );
        defer alloc.free(line);
        try buf.appendSlice(alloc, line);
    }
    var out = Writer.Allocating.init(alloc);
    defer out.deinit();
    try apply(alloc, buf.items, &.{}, &out.writer);
    const got = out.written();
    const reduction = (buf.items.len - got.len) * 100 / buf.items.len;
    try std.testing.expect(reduction >= 60);
}
