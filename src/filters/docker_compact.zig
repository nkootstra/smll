const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `docker ps` — on by default (v0.6). Set
// SMLL_LOSSLESS=1 to bypass.
//
// Design point: agents usually need container names and up/exit state to act.
// Ports, IDs, images, and commands are recoverable via a follow-up
// `docker inspect <name>`. Dropping them shrinks output by ~90% while leaving
// the caller with actionable identifiers.
//
// Grammar:
//   d <N> <state>: <name1> <name2> ...
//
// Where <state> is one of:
//   "up"    — all rows have a STATUS starting with "Up"
//   "mixed" — mixed running / stopped
//   "none"  — nothing running (all not-Up)
//
// Detection: first non-empty line starts with "CONTAINER ID".

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return std.mem.startsWith(u8, line, "CONTAINER ID");
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    const header = lines.next() orelse return;
    const status_col = findColumnStart(header, "STATUS") orelse 0;
    const names_col = findColumnStart(header, "NAMES") orelse 0;

    // First pass: count rows + determine aggregate state.
    var saved = lines;
    var count: usize = 0;
    var up_count: usize = 0;
    while (saved.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        if (status_col < line.len and std.mem.startsWith(u8, line[status_col..], "Up")) {
            up_count += 1;
        }
    }

    const state: []const u8 = blk: {
        if (count == 0) break :blk "none";
        if (up_count == count) break :blk "up";
        if (up_count == 0) break :blk "none";
        break :blk "m";
    };

    // Parity target: very compact summary, but keep one exemplar container name
    // for actionability and better alignment with RTK-like compact output.
    try writer.print("d{d}{s}", .{ count, state });

    var emit = std.mem.splitScalar(u8, stdout, '\n');
    _ = emit.next(); // skip header
    while (emit.next()) |line| {
        if (line.len == 0) continue;
        const name = extractName(line, names_col);
        if (name.len == 0) continue;
        try writer.writeByte(' ');
        try writer.writeAll(name);
        break;
    }
    try writer.writeByte('\n');
}

/// Locate column-start index of a named header in the HEADER row.
fn findColumnStart(header: []const u8, name: []const u8) ?usize {
    return std.mem.find(u8, header, name);
}

/// Extract name field. If names_col points into the line, take from there;
/// otherwise fall back to the last whitespace-gap field.
fn extractName(line: []const u8, names_col: usize) []const u8 {
    if (names_col > 0 and names_col < line.len) {
        return std.mem.trim(u8, line[names_col..], " \t\r");
    }
    return lastField(line);
}

fn lastField(line: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
    if (trimmed.len == 0) return trimmed;
    var i: usize = trimmed.len;
    while (i >= 2) : (i -= 1) {
        if (trimmed[i - 1] == ' ' and trimmed[i - 2] == ' ') {
            // Gap ends at i-1. Field begins at i.
            return trimmed[i..];
        }
    }
    return trimmed;
}

test "matches: CONTAINER ID header" {
    const input = "CONTAINER ID   IMAGE\nabc123   nginx\n";
    try std.testing.expect(matches(input));
}

test "matches: non-docker rejected" {
    try std.testing.expect(!matches("NAME  READY\npod1  1/1\n"));
    try std.testing.expect(!matches(""));
}

test "apply: fixture produces compact summary" {
    const fixture = @embedFile("fixture_docker_ps");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, fixture, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.startsWith(u8, got, "d4"));
    try std.testing.expect(std.mem.endsWith(u8, got, "\n"));
    try std.testing.expect(std.mem.find(u8, got, "helios-assistant") != null);
    try std.testing.expect(std.mem.find(u8, got, "helios-convex-dashboard") != null);
    try std.testing.expect(std.mem.find(u8, got, "helios-convex-backend") != null);
    try std.testing.expect(std.mem.find(u8, got, "helios-mysql") != null);
}

test "apply: empty input produces nothing" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", &.{}, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: zero rows produces d0none:" {
    const input = "CONTAINER ID   IMAGE   STATUS   NAMES\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("d0none\n", out.written());
}

test "lastField: single field" {
    try std.testing.expectEqualStrings("helios-mysql", lastField("helios-mysql"));
}

test "lastField: with preceding double-space gap" {
    try std.testing.expectEqualStrings("abc", lastField("foo  abc"));
}

test "lastField: trailing whitespace trimmed" {
    try std.testing.expectEqualStrings("abc", lastField("foo  abc   "));
}
