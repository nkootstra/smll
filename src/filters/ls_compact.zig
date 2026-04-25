const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `ls -l` / `ls -la` — on by default (v0.6).
// Set SMLL_LOSSLESS=1 to bypass.
//
// Drops: permissions, link count, owner, group, size, date/time, the
// leading "total N" line.
// Keeps: filenames only, one per line, in original order. Directory vs file
// distinction is marked with a trailing "/" on dirs, matching ls -F behavior.
//
// Safety: if stdout contains non-empty content lines but the parser extracts
// zero filenames (e.g. eza/exa/lsd date format, non-English locale), returns
// `error.ParsedNothing` so the caller can fall back to raw passthrough.
// This prevents silently returning "(empty)" for non-empty directories.
//
// Contract:
//   • Lossy — permissions, ownership, size, timestamps gone.
//   • Filename list is preserved in order.
//   • Byte reduction typically ~80-85% on ls -la output.
//
// Detection (matches):
//   • First non-empty line starts with "total "; OR
//   • First non-empty line matches [dl-cb][rwx-]{9} (mode bits).

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (isTotalLine(line)) return true;
        return isLsLongLine(line);
    }
    return false;
}

fn isTotalLine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "total ")) return false;
    const rest = line["total ".len..];
    if (rest.len == 0) return false;
    for (rest) |b| {
        if (b < '0' or b > '9') return false;
    }
    return true;
}

fn isLsLongLine(line: []const u8) bool {
    if (line.len < 10) return false;
    const c0 = line[0];
    if (c0 != 'd' and c0 != '-' and c0 != 'l' and c0 != 'c' and c0 != 'b' and c0 != 'p' and c0 != 's') return false;
    for (line[1..10]) |b| {
        switch (b) {
            'r', 'w', 'x', '-', 's', 'S', 't', 'T' => {},
            else => return false,
        }
    }
    return true;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var first = true;
    var had_content_lines = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (isTotalLine(line)) {
            had_content_lines = true;
            continue;
        }
        if (!isLsLongLine(line)) continue;
        had_content_lines = true;

        const parsed = extractNameAndSize(line) orelse continue;
        const name = parsed.name;
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        if (!first) try writer.writeByte('\n');
        first = false;
        try writer.writeAll(name);
        if (line[0] == 'd') {
            try writer.writeByte('/');
        } else if (parsed.size.len > 0) {
            try writer.writeAll("  ");
            try writer.writeAll(parsed.size);
        }
    }
    // Safety net: if we saw content lines (total or mode-prefixed) but
    // extracted zero filenames, the parser likely failed on an unexpected
    // format (eza/exa/lsd, non-English locale). Signal the caller to fall
    // back to raw passthrough instead of returning empty output.
    if (first and had_content_lines) return error.ParsedNothing;
    if (!first) try writer.writeByte('\n');
}

/// Skip 8 whitespace-separated fields (mode, links, owner, group, size, mon, day, time/year).
/// Return the rest of the line (filename, which may contain spaces).
/// macOS ls -l may emit ACL markers ("@", "+") after mode — tokenizer ignores them
/// because the "@" sticks to the mode token.
const ParsedNameSize = struct {
    name: []const u8,
    size: []const u8,
};

fn extractNameAndSize(line: []const u8) ?ParsedNameSize {
    var i: usize = 0;
    var fields_consumed: usize = 0;
    var size_tok: []const u8 = "";
    while (i < line.len and fields_consumed < 8) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) return null;
        const start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
        if (fields_consumed == 4) size_tok = line[start..i];
        fields_consumed += 1;
    }
    if (fields_consumed < 8) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return null;
    return .{ .name = std.mem.trimEnd(u8, line[i..], " \t\r"), .size = size_tok };
}


test "matches: total line" {
    try std.testing.expect(matches("total 24\n-rw-r--r-- 1 a b 1 Apr 1 00:00 x\n"));
}

test "matches: bare mode line" {
    try std.testing.expect(matches("drwxr-xr-x 1 a b 1 Apr 1 00:00 d\n"));
}

test "matches: rejects non-ls" {
    try std.testing.expect(!matches("hello world\n"));
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("total abc\n"));
}

test "apply: fixture produces filename list" {
    const fixture = @embedFile("fixture_ls_la");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, fixture, &.{}, &out.writer);
    const got = out.written();

    try std.testing.expect(std.mem.find(u8, got, "main.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "pipeline.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "filters/") != null);
    try std.testing.expect(std.mem.find(u8, got, "./") == null);
    try std.testing.expect(std.mem.find(u8, got, "main.zig  ") != null);
    // Ensure metadata stripped
    try std.testing.expect(std.mem.find(u8, got, "nielskootstra") == null);
    try std.testing.expect(std.mem.find(u8, got, "total") == null);
}

test "apply: filename with spaces preserved" {
    const input = "-rw-r--r-- 1 a b 1 Apr 1 00:00 hello world.txt\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("hello world.txt\n", out.written());
}

test "apply: eza day-first date format triggers ParsedNothing" {
    // eza uses day-first dates: "22 Apr 14:30" vs POSIX "Apr 22 14:30".
    // The extra field shifts the name column; extractName returns null for
    // every line → ParsedNothing so caller can fall back.
    const input = "total 8\n" ++
        "drwxr-xr-x  - user 22 Apr 14:30 src\n" ++
        "-rw-r--r--  1 user 22 Apr 14:30 README.md\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const result = apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectError(error.ParsedNothing, result);
}

test "apply: empty stdout produces no output (no ParsedNothing)" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", &.{}, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: all file types handled" {
    // Verify character device, block device, pipe, socket don't get dropped
    const input = "crw-rw-rw- 1 root wheel 0 Apr 23 12:00 /dev/null\n" ++
        "brw-r----- 1 root disk 8 Apr 23 12:00 /dev/sda\n" ++
        "prw-r--r-- 1 user staff 0 Apr 23 12:00 mypipe\n" ++
        "srwxrwxrwx 1 user staff 0 Apr 23 12:00 mysocket\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "/dev/null") != null);
    try std.testing.expect(std.mem.find(u8, got, "/dev/sda") != null);
    try std.testing.expect(std.mem.find(u8, got, "mypipe") != null);
    try std.testing.expect(std.mem.find(u8, got, "mysocket") != null);
}
