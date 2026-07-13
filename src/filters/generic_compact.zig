const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// Size-gated generic compactor — on by default (v0.6). Runs only when no
// bespoke dispatch arm claimed the command AND stdout exceeds THRESHOLD.
// Set SMLL_LOSSLESS=1 to bypass.
//
// Four-pass pipeline, fused into a single streaming sweep over the input:
//   1. ANSI strip (per-line via shared ansi.stripInto scratch).
//   2. Per-line trailing-whitespace trim.
//   3. Consecutive blank-line collapse (>=2 blanks -> 1).
//   4. Consecutive-identical-line RLE: `<line>  (xN)` for N >= 2.
//
// Contract:
//   • Format-lossy — every distinct fact survives; only padding / banners /
//     dup chatter collapse.
//   • Errors fall open at the call site to raw passthrough + exit 1.

pub const THRESHOLD_BYTES: usize = 4 * 1024;

// Lower gate for wrapper-mode dispatch on commands we already know are text
// (git, gh, kubectl, rg, find, ls, tree, cat, ...). The binary heuristic
// below still guards against malformed inputs; we just stop excluding small
// outputs that have measurable headroom.
pub const THRESHOLD_BYTES_TEXT: usize = 256;

pub fn matches(input: []const u8) bool {
    return matchesAtThreshold(input, THRESHOLD_BYTES);
}

pub fn matchesText(input: []const u8) bool {
    return matchesAtThreshold(input, THRESHOLD_BYTES_TEXT);
}

fn matchesAtThreshold(input: []const u8, threshold: usize) bool {
    if (input.len <= threshold) return false;
    if (looksLikeJson(input)) return false;
    // Reject binary data: check first 512 bytes for NUL or high-density non-ASCII.
    const sample = input[0..@min(input.len, 512)];
    var non_text: usize = 0;
    for (sample) |c| {
        if (c == 0) return false; // NUL byte → binary
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t' and c != 0x1b) non_text += 1;
    }
    // >10% control chars → likely binary
    if (non_text * 10 > sample.len) return false;
    return true;
}

fn looksLikeJson(input: []const u8) bool {
    const trimmed_ws = std.mem.trimStart(u8, input, " \t\r\n");
    const trimmed = if (std.mem.startsWith(u8, trimmed_ws, "\xef\xbb\xbf")) trimmed_ws[3..] else trimmed_ws;
    if (trimmed.len == 0) return false;
    if (trimmed[0] == '{') return looksLikeJsonObject(trimmed[1..]);
    if (trimmed[0] != '[') return false;
    return looksLikeJsonArray(trimmed[1..]);
}

fn looksLikeJsonObject(after_open: []const u8) bool {
    const rest = std.mem.trimStart(u8, after_open, " \t\r\n");
    return rest.len > 0 and (rest[0] == '"' or rest[0] == '}');
}

fn looksLikeJsonArray(after_open: []const u8) bool {
    const rest = std.mem.trimStart(u8, after_open, " \t\r\n");
    if (rest.len == 0) return false;
    if (rest[0] == ']') return true;
    if (rest[0] == '{' or rest[0] == '[' or rest[0] == '"') return true;
    if (std.mem.startsWith(u8, rest, "true")) return jsonValueHasDelimiter(rest[4..]);
    if (std.mem.startsWith(u8, rest, "false")) return jsonValueHasDelimiter(rest[5..]);
    if (std.mem.startsWith(u8, rest, "null")) return jsonValueHasDelimiter(rest[4..]);
    if (rest[0] == '-' or (rest[0] >= '0' and rest[0] <= '9')) return jsonNumberHasDelimiter(rest);
    return false;
}

fn jsonValueHasDelimiter(after_value: []const u8) bool {
    const rest = std.mem.trimStart(u8, after_value, " \t\r\n");
    return rest.len > 0 and (rest[0] == ',' or rest[0] == ']');
}

fn jsonNumberHasDelimiter(s: []const u8) bool {
    var i: usize = 0;
    if (i < s.len and s[i] == '-') i += 1;
    const digits_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == digits_start) return false;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == frac_start) return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == exp_start) return false;
    }
    return jsonValueHasDelimiter(s[i..]);
}

pub fn apply(allocator: Allocator, stdout: []const u8, writer: *Writer) !void {
    if (stdout.len == 0) return;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    // Phase 1: Parse all lines, strip ANSI + trailing whitespace.
    // Build a list of cleaned lines.
    var clean_lines: std.ArrayList([]const u8) = .empty;
    defer clean_lines.deinit(allocator);
    var owned_strs: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_strs.items) |s| allocator.free(s);
        owned_strs.deinit(allocator);
    }

    var raw_lines = std.mem.splitScalar(u8, stdout, '\n');
    while (raw_lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trimEnd(u8, clean, " \t\r");
        if (trimmed.len == 0) {
            try clean_lines.append(allocator, "");
            continue;
        }
        // Interior whitespace collapse: 2+ spaces/tabs → single space,
        // preserving leading indent (important for code/yaml/errors).
        const line = try collapseInteriorWs(allocator, trimmed);
        if (line.ptr != trimmed.ptr) {
            try owned_strs.append(allocator, line);
        } else if (@intFromPtr(line.ptr) >= @intFromPtr(stdout.ptr) and (@intFromPtr(line.ptr) + line.len) <= (@intFromPtr(stdout.ptr) + stdout.len)) {
            // Zero-copy: unchanged slice into original input
        } else {
            // From strip_buf — need to own it
            const owned = try allocator.dupe(u8, line);
            try owned_strs.append(allocator, owned);
            try clean_lines.append(allocator, owned);
            continue;
        }
        try clean_lines.append(allocator, line);
    }

    // Phase 2: Consecutive RLE with byte-identical comparison + global
    // line frequency counting. On first occurrence: emit. On subsequent:
    // just increment the count in the frequency map.
    const BodyCount = struct { first_line: []const u8, count: usize };
    var body_map = std.StringHashMap(BodyCount).init(allocator);
    defer body_map.deinit();

    // First pass: count frequencies per body
    for (clean_lines.items) |line| {
        if (line.len == 0) continue;
        const body = line;
        if (body_map.getPtr(body)) |entry| {
            entry.count += 1;
        } else {
            try body_map.put(body, .{ .first_line = line, .count = 1 });
        }
    }

    // Second pass: collect byte-identical deduplicated output lines.
    var emitted_bodies = std.StringHashMap(void).init(allocator);
    defer emitted_bodies.deinit();

    // output_lines holds borrowed views. A unique line (count <= 1) points
    // directly into clean_lines memory, which lives for the whole function, so
    // it needs no allocation. Only collapsed `<line> ×N` lines are freshly
    // allocated; those are owned by fmt_owned and freed there.
    var output_lines: std.ArrayList([]const u8) = .empty;
    defer output_lines.deinit(allocator);
    var fmt_owned: std.ArrayList([]u8) = .empty;
    defer {
        for (fmt_owned.items) |s| allocator.free(s);
        fmt_owned.deinit(allocator);
    }

    var prev_body: []const u8 = "";
    var prev_line: []const u8 = "";
    var run_count: usize = 0;
    var pending_blank: bool = false;

    for (clean_lines.items) |line| {
        if (line.len == 0) {
            pending_blank = true;
            continue;
        }

        const body = line;

        if (run_count > 0 and std.mem.eql(u8, prev_body, body)) {
            run_count += 1;
            pending_blank = false;
            continue;
        }

        if (run_count > 0) {
            const total_count = body_map.get(prev_body).?.count;
            if (pending_blank and output_lines.items.len > 0) {
                try output_lines.append(allocator, "");
            }
            try appendOutputLine(allocator, &output_lines, &fmt_owned, prev_line, total_count);
        }

        const freq = body_map.get(body).?.count;
        if (freq >= 3 and emitted_bodies.contains(body)) {
            run_count = 0;
            prev_body = "";
            prev_line = "";
            pending_blank = false;
            continue;
        }

        pending_blank = false;
        if (freq >= 3) {
            try emitted_bodies.put(body, {});
        }

        prev_line = line;
        prev_body = body;
        run_count = 1;
    }

    if (run_count > 0) {
        const total_count = body_map.get(prev_body).?.count;
        try appendOutputLine(allocator, &output_lines, &fmt_owned, prev_line, total_count);
    }

    // Only byte-identical bodies are collapsed above. Prefix similarity is not
    // enough: suffixes commonly contain the path, error, or identifier that
    // makes each line actionable.
    for (output_lines.items) |ol| {
        if (ol.len == 0) {
            try writer.writeByte('\n');
            continue;
        }
        try writer.writeAll(ol);
        try writer.writeByte('\n');
    }
}

/// Append one logical output line. Unique lines (count <= 1) are borrowed
/// directly from `line` — no allocation, since `line` outlives the output
/// pass. Only collapsed runs (count > 1) allocate a `<line> ×N` string, owned
/// by `fmt_owned` so it is freed exactly once.
fn appendOutputLine(
    allocator: Allocator,
    output_lines: *std.ArrayList([]const u8),
    fmt_owned: *std.ArrayList([]u8),
    line: []const u8,
    total_count: usize,
) !void {
    if (total_count > 1) {
        const fmt_line = try fmtLine(allocator, line, total_count);
        {
            // fmt_line is untracked until fmt_owned takes ownership. The errdefer
            // is scoped to *only* this block: it frees fmt_line if the tracking
            // append fails, and discharges on normal exit. It must not cover the
            // output_lines.append below — once fmt_owned owns fmt_line, the defer
            // in apply() frees it, so freeing here too would be a double free.
            errdefer allocator.free(fmt_line);
            try fmt_owned.append(allocator, fmt_line);
        }
        try output_lines.append(allocator, fmt_line);
    } else {
        try output_lines.append(allocator, line);
    }
}

/// Format a collapsed run as `<line> ×N`. Caller guarantees total_count > 1;
/// unique lines are emitted borrowed (see appendOutputLine) so they never
/// reach here.
fn fmtLine(allocator: Allocator, line: []const u8, total_count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, line);
    try buf.appendSlice(allocator, " \xc3\x97");
    var tmp: [20]u8 = undefined;
    var n = total_count;
    var ti: usize = tmp.len;
    while (n > 0) {
        ti -= 1;
        tmp[ti] = @intCast('0' + n % 10);
        n /= 10;
    }
    try buf.appendSlice(allocator, tmp[ti..]);
    return try buf.toOwnedSlice(allocator);
}

/// Collapse interior whitespace runs (2+ spaces/tabs) to a single space.
/// Preserves leading indent verbatim. Returns the original slice when no
/// collapse is needed (zero-copy fast path).
fn collapseInteriorWs(allocator: Allocator, line: []const u8) ![]u8 {
    // Skip leading indent
    var lead: usize = 0;
    while (lead < line.len and (line[lead] == ' ' or line[lead] == '\t')) lead += 1;
    // Scan for any interior multi-space run
    var has_run = false;
    var i = lead;
    while (i < line.len) : (i += 1) {
        if ((line[i] == ' ' or line[i] == '\t') and i + 1 < line.len and (line[i + 1] == ' ' or line[i + 1] == '\t')) {
            has_run = true;
            break;
        }
    }
    if (!has_run) return @constCast(line);
    // Build collapsed copy
    var out = try allocator.alloc(u8, line.len);
    @memcpy(out[0..lead], line[0..lead]);
    var o = lead;
    i = lead;
    while (i < line.len) {
        if (line[i] == ' ' or line[i] == '\t') {
            out[o] = ' ';
            o += 1;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        } else {
            out[o] = line[i];
            o += 1;
            i += 1;
        }
    }
    // Shrink to actual size
    const result = allocator.realloc(out, o) catch out[0..o];
    return result;
}

test "matches: threshold boundary" {
    const below = [_]u8{'x'} ** THRESHOLD_BYTES;
    const at = [_]u8{'x'} ** (THRESHOLD_BYTES + 1);
    try std.testing.expect(!matches(&below));
    try std.testing.expect(matches(&at));
}

test "matchesText: lower threshold gates small wrapper-mode outputs" {
    const below = [_]u8{'x'} ** THRESHOLD_BYTES_TEXT;
    const at = [_]u8{'x'} ** (THRESHOLD_BYTES_TEXT + 1);
    try std.testing.expect(!matchesText(&below));
    try std.testing.expect(matchesText(&at));
    // Inputs between TEXT and full threshold pass matchesText but not matches.
    const between = [_]u8{'x'} ** (THRESHOLD_BYTES_TEXT + 100);
    try std.testing.expect(matchesText(&between));
    try std.testing.expect(!matches(&between));
}

test "matchesText: still rejects binary input" {
    var buf: [THRESHOLD_BYTES_TEXT + 50]u8 = undefined;
    @memset(&buf, 'x');
    buf[100] = 0; // NUL byte
    try std.testing.expect(!matchesText(&buf));
}

test "matches: empty input" {
    try std.testing.expect(!matches(""));
}

test "apply: empty input is no-op" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: strips ANSI" {
    const input = "\x1b[31mred\x1b[0m plain\nother\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("red plain\nother\n", out.written());
}

test "apply: trims trailing whitespace" {
    const input = "hello   \t\nworld \n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("hello\nworld\n", out.written());
}

test "apply: collapses consecutive blanks" {
    const input = "a\n\n\n\nb\n\n\nc\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.indexOf(u8, got, "a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "b\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "c\n") != null);
}

test "apply: RLE collapses identical lines" {
    const input = "log entry\nlog entry\nlog entry\nother\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("log entry ×3\nother\n", out.written());
}

test "apply: all identical lines collapse to single marker" {
    const input = "same\nsame\nsame\nsame\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("same ×4\n", out.written());
}

test "apply: all blank lines collapse to nothing" {
    const input = "\n\n\n\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: distinct lines passthrough with ANSI stripped" {
    const input = "\x1b[32malpha\x1b[0m\nbeta\ngamma\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", out.written());
}

test "apply: unique long lines remain whole" {
    const line = "unique diagnostic: " ++ ("0123456789" ** 16);
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, line ++ "\n", &out.writer);
    try std.testing.expectEqualStrings(line ++ "\n", out.written());
}

test "apply: highly repeated long UTF-8 lines remain whole with an exact repeat count" {
    const line = ("a" ** 63) ++ "€" ++ ("z" ** 20);
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(std.testing.allocator);
    for (0..51) |_| {
        try input.appendSlice(std.testing.allocator, line);
        try input.append(std.testing.allocator, '\n');
    }

    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input.items, &out.writer);
    try std.testing.expectEqualStrings(line ++ " ×51\n", out.written());
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.written()));
}

test "apply: invalid UTF-8 bytes remain unchanged in unique and repeated lines" {
    const unique = "unique diagnostic: \xff\xfe";
    var unique_out = Writer.Allocating.init(std.testing.allocator);
    defer unique_out.deinit();
    try apply(std.testing.allocator, unique ++ "\n", &unique_out.writer);
    try std.testing.expectEqualSlices(u8, unique ++ "\n", unique_out.written());

    const repeated = "repeated diagnostic: \xf5\x80";
    var repeated_out = Writer.Allocating.init(std.testing.allocator);
    defer repeated_out.deinit();
    try apply(std.testing.allocator, (repeated ++ "\n") ** 3, &repeated_out.writer);
    try std.testing.expectEqualSlices(u8, repeated ++ " ×3\n", repeated_out.written());
}

test "apply: borrowed unique lines, owned RLE line, and interior blank coexist" {
    // Exercises every output-line ownership path in one pass so the leak-
    // checking allocator validates the borrowed/owned split:
    //   • "x" and "b" are unique → borrowed directly from input (no alloc)
    //   • "a ×2" is a collapsed run → freshly allocated and owned
    //   • the blank between the "a" run and "b" → borrowed "" (previously a
    //     pointless dupe of an empty string)
    const input = "x\na\na\n\nb\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("x\n\na ×2\nb\n", out.written());
}

test "appendOutputLine: owned path leaks nothing when any allocation fails" {
    // Targets the owned-allocation path directly via checkAllAllocationFailures,
    // which injects an OOM at every allocation index in turn and asserts the
    // callee both propagates error.OutOfMemory and leaks nothing. total_count > 1
    // forces fmtLine -> fmt_owned.append, where fmt_line is briefly untracked; a
    // missing or mis-scoped errdefer would surface here as a leak (no guard) or a
    // double free (guard covering output_lines.append too).
    //
    // We drive appendOutputLine rather than apply() on purpose: apply() falls
    // open on OOM via `ansi.stripInto(...) catch raw`, so it does not propagate
    // error.OutOfMemory at every index and is incompatible with this harness.
    const Helper = struct {
        fn run(allocator: Allocator) !void {
            var output_lines: std.ArrayList([]const u8) = .empty;
            defer output_lines.deinit(allocator);
            var fmt_owned: std.ArrayList([]u8) = .empty;
            defer {
                for (fmt_owned.items) |s| allocator.free(s);
                fmt_owned.deinit(allocator);
            }
            try appendOutputLine(allocator, &output_lines, &fmt_owned, "repeated line", 3);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Helper.run, .{});
}

test "apply: full pipeline fuses passes" {
    const input = "\x1b[31mlog\x1b[0m   \nlog\nlog\n\n\n\nafter\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.indexOf(u8, got, "log ×3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "after\n") != null);
}

test "apply: 100 KiB synthetic reduces >=30%" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    // 50 repeats of one line + ANSI + trailing spaces + padding.
    const payload = "2026-04-23 12:00:00 INFO handler served request ok ";
    for (0..2000) |_| {
        try buf.appendSlice(std.testing.allocator, "\x1b[33m");
        try buf.appendSlice(std.testing.allocator, payload);
        try buf.appendSlice(std.testing.allocator, "\x1b[0m\n");
    }
    try std.testing.expect(buf.items.len > 64 * 1024);

    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, buf.items, &out.writer);
    const got = out.written();
    const reduction = (buf.items.len - got.len) * 100 / buf.items.len;
    try std.testing.expect(reduction >= 30);
}

test "matches: large JSON object is treated as machine-readable passthrough" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "{\"items\":[");
    for (0..600) |i| {
        if (i > 0) try buf.append(std.testing.allocator, ',');
        const item = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":{d},\"name\":\"item-{d}\"}}", .{ i, i });
        defer std.testing.allocator.free(item);
        try buf.appendSlice(std.testing.allocator, item);
    }
    try buf.appendSlice(std.testing.allocator, "]}\n");
    try std.testing.expect(buf.items.len > THRESHOLD_BYTES);
    try std.testing.expect(!matches(buf.items));
}

test "matches: large JSON array is treated as machine-readable passthrough" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.append(std.testing.allocator, '[');
    for (0..600) |i| {
        if (i > 0) try buf.append(std.testing.allocator, ',');
        const item = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":{d}}}", .{i});
        defer std.testing.allocator.free(item);
        try buf.appendSlice(std.testing.allocator, item);
    }
    try buf.appendSlice(std.testing.allocator, "]\n");
    try std.testing.expect(buf.items.len > THRESHOLD_BYTES);
    try std.testing.expect(!matches(buf.items));
}

test "matches: large JSON with UTF-8 BOM is treated as machine-readable passthrough" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "\xef\xbb\xbf{\"items\":[");
    for (0..600) |i| {
        if (i > 0) try buf.append(std.testing.allocator, ',');
        const item = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":{d}}}", .{i});
        defer std.testing.allocator.free(item);
        try buf.appendSlice(std.testing.allocator, item);
    }
    try buf.appendSlice(std.testing.allocator, "]}\n");
    try std.testing.expect(buf.items.len > THRESHOLD_BYTES);
    try std.testing.expect(!matches(buf.items));
}

test "matches: bracketed log output still qualifies for compaction" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (0..300) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "[INFO] request {d} ok\n", .{i});
        defer std.testing.allocator.free(line);
        try buf.appendSlice(std.testing.allocator, line);
    }
    try std.testing.expect(buf.items.len > THRESHOLD_BYTES);
    try std.testing.expect(matches(buf.items));
}

test "matches: bracketed numeric progress logs still qualify for compaction" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (0..300) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "[{d}/300] building crate_{d}\n", .{ i, i });
        defer std.testing.allocator.free(line);
        try buf.appendSlice(std.testing.allocator, line);
    }
    try std.testing.expect(buf.items.len > THRESHOLD_BYTES);
    try std.testing.expect(matches(buf.items));
}

test "matches: bracketed ISO timestamp logs still qualify for compaction" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (0..200) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "[2026-04-28T12:00:{d}Z] request ok\n", .{i});
        defer std.testing.allocator.free(line);
        try buf.appendSlice(std.testing.allocator, line);
    }
    try std.testing.expect(buf.items.len > THRESHOLD_BYTES);
    try std.testing.expect(matches(buf.items));
}

test "matches: brace-prefixed logs still qualify for compaction" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (0..250) |i| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "{{worker-{d}}} request ok\n", .{i});
        defer std.testing.allocator.free(line);
        try buf.appendSlice(std.testing.allocator, line);
    }
    try std.testing.expect(buf.items.len > THRESHOLD_BYTES);
    try std.testing.expect(matches(buf.items));
}

test "apply: distinct syslog lines remain distinct" {
    const input = "Apr 23 2026 00:00:01 host kernel: [UFW BLOCK]\nApr 23 2026 00:10:01 host kernel: [UFW BLOCK]\nApr 23 2026 00:20:01 host kernel: [UFW BLOCK]\ndifferent line\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}

test "apply: distinct timestamped lines remain distinct" {
    const input = "2026-04-23 12:00:00 INFO request ok\n2026-04-23 12:01:00 INFO request ok\n2026-04-23 12:02:00 INFO request ok\nother\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}
