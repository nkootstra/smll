const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `find -ls` — on by default (v0.6).
// Set SMLL_LOSSLESS=1 to bypass.
//
// `find -ls` emits columns: inode, blocks, mode, nlink, user, group,
// size, month, day, time/year, path. All but the path are dropped.
// Paths sharing a parent directory collapse to a single
// "<dir>/ (N entries: a, b, c, ...)" line when ≥3 share it; lone
// files (1-2 per dir) are emitted individually. Directory-typed
// entries (mode starts with 'd') get the trailing slash in both forms.
//
// Contract:
//   • Lossy — inode, mode bits, ownership, size, timestamps gone.
//     Paths under a parent dir collapse to a count plus examples when
//     ≥3 share it.
//   • Lone paths (≤2 per parent) preserved verbatim.
//   • Typical reduction ~95% on GNU/BSD `find -ls` output of a
//     populated directory tree.
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

const Entry = struct {
    path: []const u8,
    parent: []const u8,
    is_dir: bool,
};

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    if (stdout.len == 0) return;

    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!isFindLsLine(line)) continue;
        const path = extractPath(line) orelse continue;
        if (path.len == 0) continue;
        const is_dir = blk: {
            if (extractMode(line)) |mode| {
                break :blk (mode.len > 0 and mode[0] == 'd');
            }
            break :blk false;
        };
        try entries.append(allocator, .{
            .path = path,
            .parent = parentDir(path),
            .is_dir = is_dir,
        });
    }

    if (entries.items.len == 0) return;

    std.sort.insertion(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            const cmp = std.mem.order(u8, a.parent, b.parent);
            if (cmp != .eq) return cmp == .lt;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    var first = true;
    var i: usize = 0;
    while (i < entries.items.len) {
        const parent = entries.items[i].parent;
        var j = i + 1;
        while (j < entries.items.len and std.mem.eql(u8, entries.items[j].parent, parent)) : (j += 1) {}
        const count = j - i;
        if (count >= 3) {
            if (!first) try writer.writeByte('\n');
            first = false;
            try writeCollapsedGroup(writer, entries.items[i..j], parent, count);
        } else {
            for (entries.items[i..j]) |e| {
                if (!first) try writer.writeByte('\n');
                first = false;
                try writer.writeAll(e.path);
                if (e.is_dir) try writer.writeByte('/');
            }
        }
        i = j;
    }
    if (!first) try writer.writeByte('\n');
}

const max_examples_per_group = 3;

fn writeCollapsedGroup(writer: *Writer, group: []const Entry, parent: []const u8, count: usize) !void {
    try writer.writeAll(parent);
    try writer.writeAll("/ (");
    try ansi.writeDecimal(writer, count);
    try writer.writeAll(" entries: ");

    const examples = @min(count, max_examples_per_group);
    for (group[0..examples], 0..) |entry, idx| {
        if (idx > 0) try writer.writeAll(", ");
        try writeChildName(writer, parent, entry);
    }
    if (count > max_examples_per_group) try writer.writeAll(", ...");
    try writer.writeByte(')');
}

fn writeChildName(writer: *Writer, parent: []const u8, entry: Entry) !void {
    var child = entry.path;
    if (std.mem.eql(u8, parent, ".")) {
        if (std.mem.startsWith(u8, child, "./")) child = child[2..];
    } else if (std.mem.eql(u8, parent, "/")) {
        if (std.mem.startsWith(u8, child, "/")) child = child[1..];
    } else if (std.mem.startsWith(u8, child, parent) and child.len > parent.len and child[parent.len] == '/') {
        child = child[parent.len + 1 ..];
    }
    try writer.writeAll(child);
    if (entry.is_dir) try writer.writeByte('/');
}

/// Parent directory of a path. "./src/main.zig" → "./src",
/// "./README.md" → ".", "/etc/hosts" → "/etc", "foo" → ".".
fn parentDir(path: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, path, '/')) |idx| {
        if (idx == 0) return "/";
        return path[0..idx];
    }
    return ".";
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

test "apply: small input — all groups <3 → emit per-path sorted" {
    const input =
        "2055938    0 drwxr-xr-x   2 user staff 64 Apr 23 12:34 ./src\n" ++
        "2055939    8 -rw-r--r--   1 user staff 421 Apr 23 12:34 ./src/main.zig\n" ++
        "2055940    8 -rw-r--r--   1 user staff 123 Apr 23 12:34 ./README.md\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    // Sort puts "." parent before "./src" parent; within "." group,
    // "./README.md" < "./src" lexicographically.
    try std.testing.expectEqualStrings(
        "./README.md\n./src/\n./src/main.zig\n",
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

test "apply: ≥3 entries in same parent collapse to count" {
    const input =
        "2055938 0 -rw-r--r-- 1 u s 1 Apr 1 00:00 ./a.txt\n" ++
        "2055939 0 -rw-r--r-- 1 u s 1 Apr 1 00:00 ./b.txt\n" ++
        "2055940 0 -rw-r--r-- 1 u s 1 Apr 1 00:00 ./c.txt\n" ++
        "2055941 0 -rw-r--r-- 1 u s 1 Apr 1 00:00 ./d.txt\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("./ (4 entries: a.txt, b.txt, c.txt, ...)\n", out.written());
}

test "apply: small fixture reduces output and keeps paths" {
    const fixture = @embedFile("fixture_find_ls");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, fixture, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < fixture.len);
    // Fixture has 5 entries: 3 in "." (./src, ./README.md, ./tests) → collapse
    // with examples; 2 in "./src" (./src/main.zig, ./src/filter.zig) → emit
    // individually.
    try std.testing.expect(std.mem.find(u8, got, "./src/main.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "./src/filter.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "./ (3 entries: README.md, src/, tests/)") != null);
    try std.testing.expect(std.mem.find(u8, got, "user") == null);
}

test "apply: large same-parent fixture collapses (≥95% reduction)" {
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
    try std.testing.expect(std.mem.find(u8, got, "./src/ (50 entries: ") != null);
    try std.testing.expect(std.mem.find(u8, got, "file_0.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "file_1.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, ", ...)\n") != null);
    const reduction = (buf.items.len - got.len) * 100 / buf.items.len;
    try std.testing.expect(reduction >= 95);
}

test "parentDir basic cases" {
    try std.testing.expectEqualStrings(".", parentDir("./README.md"));
    try std.testing.expectEqualStrings("./src", parentDir("./src/main.zig"));
    try std.testing.expectEqualStrings("/etc", parentDir("/etc/hosts"));
    try std.testing.expectEqualStrings("/", parentDir("/etc"));
    try std.testing.expectEqualStrings(".", parentDir("foo"));
}
