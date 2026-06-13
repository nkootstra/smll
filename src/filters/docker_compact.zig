const std = @import("std");
const ansi = @import("ansi");
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
// Detection: first non-empty line is either `docker ps` ("CONTAINER ID ...")
// or `docker compose ps` ("NAME IMAGE ... SERVICE ... STATUS ...").

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return isDockerPsHeader(line) or isComposePsHeader(line);
    }
    return false;
}

pub fn matchesImages(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return isDockerImagesHeader(line);
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
    const names_col = findColumnStart(header, "NAMES") orelse findColumnStart(header, "NAME") orelse 0;
    const name_is_first_col = names_col == 0 and std.mem.startsWith(u8, header, "NAME");

    // First pass: count rows + determine aggregate state.
    var saved = lines;
    var count: usize = 0;
    var up_count: usize = 0;
    while (saved.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        if (statusStartsWithUp(line, status_col)) {
            up_count += 1;
        }
    }

    const state: []const u8 = blk: {
        if (count == 0) break :blk "none";
        if (up_count == count) break :blk "up";
        if (up_count == 0) break :blk "none";
        break :blk "m";
    };

    try writer.writeByte('d');
    try ansi.writeDecimal(writer, count);
    try writer.writeAll(state);

    // Second pass: emit name, image, and status for each container.
    var emit = std.mem.splitScalar(u8, stdout, '\n');
    _ = emit.next(); // skip header
    const image_col = findColumnStart(header, "IMAGE") orelse 0;
    while (emit.next()) |line| {
        if (line.len == 0) continue;
        const name = if (name_is_first_col) firstField(line) else extractName(line, names_col);
        if (name.len == 0) continue;
        try writer.writeByte(' ');
        try writer.writeAll(name);
        // Append image (truncated at column boundary) and status.
        if (image_col > 0 and image_col < line.len) {
            const img_start = image_col;
            // Image field ends at next multi-space gap.
            var img_end = img_start;
            while (img_end < line.len) : (img_end += 1) {
                if (img_end + 1 < line.len and line[img_end] == ' ' and line[img_end + 1] == ' ') break;
            }
            const image = std.mem.trim(u8, line[img_start..img_end], " ");
            if (image.len > 0) {
                try writer.writeByte('(');
                try writer.writeAll(image);
                // Add status indicator.
                if (status_col > 0 and status_col < line.len) {
                    const st = std.mem.trim(u8, line[status_col..@min(status_col + 25, line.len)], " ");
                    // Trim status at first multi-space gap.
                    var st_end: usize = 0;
                    while (st_end < st.len) : (st_end += 1) {
                        if (st_end + 1 < st.len and st[st_end] == ' ' and st[st_end + 1] == ' ') break;
                    }
                    if (st_end > 0) {
                        try writer.writeByte(',');
                        try writer.writeAll(st[0..st_end]);
                    }
                }
                try writer.writeByte(')');
            }
        }
    }
    try writer.writeByte('\n');
}

pub fn applyImages(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    const header = firstNonEmpty(&lines) orelse return;
    const tag_col = findColumnStart(header, "TAG") orelse return;
    const image_id_col = findColumnStart(header, "IMAGE ID") orelse return;
    const size_col = findColumnStart(header, "SIZE") orelse return;

    var count: usize = 0;
    var named_count: usize = 0;
    var dangling_count: usize = 0;
    var scan = lines;
    while (scan.next()) |line| {
        const row = parseImageRow(line, tag_col, image_id_col, size_col) orelse continue;
        count += 1;
        if (isDanglingImage(row)) {
            dangling_count += 1;
        } else {
            named_count += 1;
        }
    }

    try writer.writeAll("images ");
    try ansi.writeDecimal(writer, count);
    if (count == 0) {
        try writer.writeByte('\n');
        return;
    }
    try writer.writeByte(':');

    const max_examples = 8;
    var emitted: usize = 0;
    var emit = std.mem.splitScalar(u8, stdout, '\n');
    _ = firstNonEmpty(&emit);
    while (emit.next()) |line| {
        if (emitted >= max_examples) break;
        const row = parseImageRow(line, tag_col, image_id_col, size_col) orelse continue;
        if (isDanglingImage(row)) continue;
        try writer.writeByte(' ');
        try writer.writeAll(row.repository);
        try writer.writeByte(':');
        try writer.writeAll(row.tag);
        try writer.writeByte('(');
        try writer.writeAll(row.size);
        try writer.writeByte(')');
        emitted += 1;
    }
    if (dangling_count > 0) {
        try writer.writeAll(" dangling x");
        try ansi.writeDecimal(writer, dangling_count);
    }
    if (named_count > emitted) {
        try writer.writeAll(" (+");
        try ansi.writeDecimal(writer, named_count - emitted);
        try writer.writeByte(')');
    }
    try writer.writeByte('\n');
}

/// Locate column-start index of a named header in the HEADER row.
fn findColumnStart(header: []const u8, name: []const u8) ?usize {
    return std.mem.find(u8, header, name);
}

fn firstNonEmpty(lines: *std.mem.SplitIterator(u8, .scalar)) ?[]const u8 {
    while (lines.next()) |line| {
        if (line.len != 0) return line;
    }
    return null;
}

fn isDockerPsHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "CONTAINER ID");
}

fn isDockerImagesHeader(line: []const u8) bool {
    return firstHeaderFieldIs(line, "REPOSITORY") and
        findColumnStart(line, "TAG") != null and
        findColumnStart(line, "IMAGE ID") != null and
        findColumnStart(line, "SIZE") != null;
}

fn isComposePsHeader(line: []const u8) bool {
    return firstHeaderFieldIs(line, "NAME") and
        findColumnStart(line, "IMAGE") != null and
        findColumnStart(line, "SERVICE") != null and
        findColumnStart(line, "STATUS") != null;
}

fn firstHeaderFieldIs(line: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, line, name)) return false;
    return line.len == name.len or line[name.len] == ' ' or line[name.len] == '\t';
}

fn statusStartsWithUp(line: []const u8, status_col: usize) bool {
    if (status_col >= line.len) return false;
    const status = std.mem.trim(u8, line[status_col..@min(status_col + 25, line.len)], " \t\r");
    return std.mem.startsWith(u8, status, "Up");
}

/// Extract name field. If names_col points into the line, take from there;
/// otherwise fall back to the last whitespace-gap field.
fn extractName(line: []const u8, names_col: usize) []const u8 {
    if (names_col > 0 and names_col < line.len) {
        return std.mem.trim(u8, line[names_col..], " \t\r");
    }
    return lastField(line);
}

fn firstField(line: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t\r");
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r') {
            return trimmed[0..i];
        }
    }
    return trimmed;
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

const ImageRow = struct {
    repository: []const u8,
    tag: []const u8,
    size: []const u8,
};

fn parseImageRow(line: []const u8, tag_col: usize, image_id_col: usize, size_col: usize) ?ImageRow {
    if (line.len == 0 or tag_col >= line.len or image_id_col > line.len or size_col >= line.len) return null;
    const repository = std.mem.trim(u8, line[0..@min(tag_col, line.len)], " \t\r");
    const tag = std.mem.trim(u8, line[tag_col..@min(image_id_col, line.len)], " \t\r");
    const size = std.mem.trim(u8, line[size_col..], " \t\r");
    if (repository.len == 0 or tag.len == 0 or size.len == 0) return null;
    return .{ .repository = repository, .tag = tag, .size = size };
}

fn isDanglingImage(row: ImageRow) bool {
    return std.mem.eql(u8, row.repository, "<none>") or std.mem.eql(u8, row.tag, "<none>");
}

test "matches: CONTAINER ID header" {
    const input = "CONTAINER ID   IMAGE\nabc123   nginx\n";
    try std.testing.expect(matches(input));
}

test "matches: docker compose ps header" {
    const input = "NAME   IMAGE   COMMAND   SERVICE   CREATED   STATUS   PORTS\nsvc-1  nginx   x         web       now       Up 1s\n";
    try std.testing.expect(matches(input));
}

test "matches: NAME-prefixed non-compose header rejected" {
    try std.testing.expect(!matches("NAMESPACE   IMAGE   SERVICE   STATUS\nprod        nginx   web       Up\n"));
}

test "matches: non-docker rejected" {
    try std.testing.expect(!matches("NAME  READY\npod1  1/1\n"));
    try std.testing.expect(!matches(""));
}

test "matchesImages: docker images header" {
    try std.testing.expect(matchesImages("REPOSITORY   TAG   IMAGE ID   CREATED   SIZE\nnode   24-alpine   abc   now   161MB\n"));
}

test "matchesImages: generic repository table rejected" {
    try std.testing.expect(!matchesImages("REPOSITORY   STATUS\norigin       ready\n"));
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

test "apply: docker compose fixture produces compact summary" {
    const fixture = @embedFile("fixture_docker_compose_ps");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, fixture, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.startsWith(u8, got, "d1up "));
    try std.testing.expect(std.mem.find(u8, got, "smll_d4_fixture-echoer-1(node:24-alpine,Up 2 seconds)") != null);
}

test "applyImages: fixture summarizes named and dangling images" {
    const fixture = @embedFile("fixture_docker_images");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyImages(std.testing.allocator, fixture, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.startsWith(u8, got, "images 25: "));
    try std.testing.expect(std.mem.find(u8, got, "postgres:18(479MB)") != null);
    try std.testing.expect(std.mem.find(u8, got, "node:24-alpine(161MB)") != null);
    try std.testing.expect(std.mem.find(u8, got, "dangling x3") != null);
    try std.testing.expect(std.mem.find(u8, got, "(+14)") != null);
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
