const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `docker logs` / `kubectl logs` — on by
// default (v0.6). Set SMLL_LOSSLESS=1 to bypass.
//
// Collapses consecutive identical log lines (ignoring the leading ISO-8601
// timestamp) into a single line + `(×N)` suffix. Strips ANSI escapes.
//
// Fingerprint: stripTimestamp(line). If leading token looks like
//   "YYYY-MM-DDTHH:MM:SS...Z" or "YYYY-MM-DD HH:MM:SS" it is elided for the
//   purpose of comparison only — the first occurrence is emitted verbatim.
//
// Detection: called unconditionally by the `docker logs` / `kubectl logs` /
// `docker compose logs` dispatch arm (wrapper mode only — no pipe-mode
// detection).

pub const Mode = enum { plain, compose };

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    try applyStream(allocator, stdout, writer, .plain);
    if (stderr.len != 0) {
        try applyStream(allocator, stderr, writer, .plain);
    }
}

pub fn applyCompose(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    try applyStream(allocator, stdout, writer, .compose);
    if (stderr.len != 0) {
        try applyStream(allocator, stderr, writer, .compose);
    }
}

fn applyStream(allocator: Allocator, input: []const u8, writer: *Writer, mode: Mode) !void {
    if (input.len == 0) return;

    var deduper = StreamDeduper.init(allocator, mode);
    defer deduper.deinit();

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        try deduper.feedLine(raw, writer, false);
    }
    try deduper.flush(writer, false);
}

const PreparedLine = struct {
    line: []const u8,
    payload_start: usize,
};

fn prepareLine(buf: *std.ArrayList(u8), allocator: Allocator, line: []const u8, mode: Mode) !PreparedLine {
    if (mode == .compose) {
        if (try normalizeComposeLine(buf, allocator, line)) {
            return .{ .line = buf.items, .payload_start = 0 };
        }
    }
    return .{ .line = line, .payload_start = timestampEnd(line) };
}

fn normalizeComposeLine(buf: *std.ArrayList(u8), allocator: Allocator, line: []const u8) !bool {
    const pipe_idx = std.mem.indexOfScalar(u8, line, '|') orelse return false;
    const service = std.mem.trim(u8, line[0..pipe_idx], " \t\r");
    if (service.len == 0) return false;

    const raw_payload = std.mem.trimStart(u8, line[pipe_idx + 1 ..], " \t\r");
    const payload = raw_payload[timestampEnd(raw_payload)..];

    try buf.appendSlice(allocator, service);
    try buf.append(allocator, '|');
    if (payload.len > 0) {
        try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, payload);
    }
    return true;
}

pub const StreamDeduper = struct {
    allocator: Allocator,
    mode: Mode,
    pending: std.ArrayList(u8) = .empty,
    pending_payload_start: usize = 0,
    repeat_count: usize = 0,
    strip_buf: std.ArrayList(u8) = .empty,
    normalized: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator, mode: Mode) StreamDeduper {
        return .{ .allocator = allocator, .mode = mode };
    }

    pub fn deinit(self: *StreamDeduper) void {
        self.pending.deinit(self.allocator);
        self.strip_buf.deinit(self.allocator);
        self.normalized.deinit(self.allocator);
    }

    pub fn feedLine(self: *StreamDeduper, raw: []const u8, writer: *Writer, immediate: bool) !void {
        const clean = ansi.stripInto(&self.strip_buf, self.allocator, raw) catch raw;
        const trimmed = std.mem.trimEnd(u8, clean, " \t\r");
        if (trimmed.len == 0) {
            try self.flush(writer, immediate);
            return;
        }

        self.normalized.clearRetainingCapacity();
        const prepared = try prepareLine(&self.normalized, self.allocator, trimmed, self.mode);
        const payload = prepared.line[prepared.payload_start..];

        if (self.repeat_count > 0) {
            const prev_payload = self.pending.items[self.pending_payload_start..];
            if (std.mem.eql(u8, prev_payload, payload)) {
                self.repeat_count += 1;
                return;
            }
            try self.flush(writer, immediate);
        }

        self.pending_payload_start = prepared.payload_start;
        try self.pending.appendSlice(self.allocator, prepared.line);
        self.repeat_count = 1;
        if (immediate) try writePrepared(writer, self.pending.items, self.pending_payload_start, null);
    }

    pub fn flush(self: *StreamDeduper, writer: *Writer, immediate: bool) !void {
        if (self.repeat_count == 0) return;
        if (immediate) {
            if (self.repeat_count > 1) {
                try writePrepared(writer, self.pending.items, self.pending_payload_start, self.repeat_count - 1);
            }
        } else {
            const suffix = if (self.repeat_count > 1) self.repeat_count else null;
            try writePrepared(writer, self.pending.items, self.pending_payload_start, suffix);
        }
        self.pending.clearRetainingCapacity();
        self.repeat_count = 0;
    }
};

fn writePrepared(writer: *Writer, line: []const u8, payload_start: usize, repeat_suffix: ?usize) !void {
    // Timestamp is usually low-value noise for agent actions; keep payload only.
    if (payload_start > 0 and payload_start < line.len) {
        try writer.writeAll(line[payload_start..]);
    } else {
        try writer.writeAll(line);
    }
    if (repeat_suffix) |count| {
        try writer.writeAll(" ×");
        try ansi.writeDecimal(writer, count);
    }
    try writer.writeByte('\n');
}

/// Returns the byte index where the timestamp ends (pointing at the first
/// non-space char after the timestamp + its trailing whitespace). If the line
/// does not begin with an ISO-ish timestamp, returns 0.
fn timestampEnd(line: []const u8) usize {
    if (!looksLikeTimestamp(line)) return 0;
    var i: usize = 0;
    if (looksLikeDateSpaceTime(line)) {
        i = 19;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    } else {
        // Advance past the timestamp token, then past space(s).
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

/// Heuristic: first 10 chars look like "YYYY-MM-DD" (4 digits, '-', 2 digits,
/// '-', 2 digits).
fn looksLikeTimestamp(line: []const u8) bool {
    if (line.len < 10) return false;
    for (0..4) |i| if (!std.ascii.isDigit(line[i])) return false;
    if (line[4] != '-') return false;
    for (5..7) |i| if (!std.ascii.isDigit(line[i])) return false;
    if (line[7] != '-') return false;
    for (8..10) |i| if (!std.ascii.isDigit(line[i])) return false;
    return true;
}

fn looksLikeDateSpaceTime(line: []const u8) bool {
    if (line.len < 19 or line[10] != ' ') return false;
    for (11..13) |i| if (!std.ascii.isDigit(line[i])) return false;
    if (line[13] != ':') return false;
    for (14..16) |i| if (!std.ascii.isDigit(line[i])) return false;
    if (line[16] != ':') return false;
    for (17..19) |i| if (!std.ascii.isDigit(line[i])) return false;
    return true;
}

test "timestampEnd: ISO docker line" {
    const line = "2026-04-19T08:42:01.123456Z INFO  starting server";
    const idx = timestampEnd(line);
    try std.testing.expect(idx > 0);
    try std.testing.expectEqualStrings("INFO  starting server", line[idx..]);
}

test "timestampEnd: space-separated date time line" {
    const line = "2026-04-19 08:42:01 starting server";
    const idx = timestampEnd(line);
    try std.testing.expect(idx > 0);
    try std.testing.expectEqualStrings("starting server", line[idx..]);
}

test "timestampEnd: no timestamp returns 0" {
    try std.testing.expectEqual(@as(usize, 0), timestampEnd("starting"));
    try std.testing.expectEqual(@as(usize, 0), timestampEnd("INFO foo"));
}

test "apply: fixture collapses repeated health checks" {
    const input = @embedFile("fixture_docker_logs");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    // Repeated GET /health collapsed.
    try std.testing.expect(std.mem.find(u8, got, "×5") != null);
    // Repeated redis errors collapsed.
    try std.testing.expect(std.mem.find(u8, got, "failed to connect to redis: connection refused ×4") != null);
    // Unique lines preserved.
    try std.testing.expect(std.mem.find(u8, got, "starting server on :8080") != null);
    try std.testing.expect(std.mem.find(u8, got, "shutting down gracefully") != null);
    try std.testing.expect(std.mem.find(u8, got, "slow query") != null);
}

test "StreamDeduper: immediate mode emits first line and later repeat marker" {
    var deduper = StreamDeduper.init(std.testing.allocator, .plain);
    defer deduper.deinit();
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try deduper.feedLine("2026-04-19T08:42:01Z ready", &out.writer, true);
    try std.testing.expectEqualStrings("ready\n", out.written());
    try deduper.feedLine("2026-04-19T08:42:02Z ready", &out.writer, true);
    try deduper.feedLine("2026-04-19T08:42:03Z ready", &out.writer, true);
    try std.testing.expectEqualStrings("ready\n", out.written());
    try deduper.flush(&out.writer, true);
    try std.testing.expectEqualStrings("ready\nready ×2\n", out.written());
}

test "StreamDeduper: immediate mode reports one suppressed duplicate" {
    var deduper = StreamDeduper.init(std.testing.allocator, .plain);
    defer deduper.deinit();
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try deduper.feedLine("2026-04-19T08:42:01Z ready", &out.writer, true);
    try deduper.feedLine("2026-04-19T08:42:02Z ready", &out.writer, true);
    try deduper.flush(&out.writer, true);
    try std.testing.expectEqualStrings("ready\nready ×1\n", out.written());
}

test "applyCompose: strips compose prefix spacing and collapses repeated payloads" {
    const input = @embedFile("fixture_docker_compose_logs");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyCompose(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expectEqualStrings(
        "echoer-1| ready ×3\n" ++
            "echoer-1| done\n",
        got,
    );
}

test "apply: no duplicates passes through verbatim" {
    const input =
        \\2026-04-19T08:42:01.1Z INFO  line a
        \\2026-04-19T08:42:02.1Z INFO  line b
        \\2026-04-19T08:42:03.1Z INFO  line c
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "line a") != null);
    try std.testing.expect(std.mem.find(u8, got, "line b") != null);
    try std.testing.expect(std.mem.find(u8, got, "line c") != null);
    try std.testing.expect(std.mem.find(u8, got, "×") == null);
}

test "apply: non-consecutive duplicates are not collapsed" {
    const input =
        \\2026-04-19T08:42:01Z A
        \\2026-04-19T08:42:02Z B
        \\2026-04-19T08:42:03Z A
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "×") == null);
}

test "apply: strips ANSI" {
    const input = "2026-04-19T08:42:01Z \x1b[31mERROR\x1b[0m boom\n2026-04-19T08:42:02Z \x1b[31mERROR\x1b[0m boom\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "ERROR boom ×2") != null);
}

test "apply: lines without timestamps still dedup by full text" {
    const input = "loading\nloading\nloading\ndone\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "loading ×3") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "done") != null);
}
