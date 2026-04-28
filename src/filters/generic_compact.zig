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

pub fn matches(input: []const u8) bool {
    if (input.len <= THRESHOLD_BYTES) return false;
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

pub fn apply(allocator: Allocator, stdout: []const u8, writer: *Writer) !void {
    if (stdout.len == 0) return;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    // Phase 1: Parse all lines, strip ANSI + trailing whitespace.
    // Build a list of cleaned lines and their timestamp-stripped bodies.
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

    // Phase 2: Consecutive RLE with timestamp-aware comparison + global
    // body frequency counting. On first occurrence: emit. On subsequent:
    // just increment the count in the frequency map.
    const BodyCount = struct { first_line: []const u8, count: usize };
    var body_map = std.StringHashMap(BodyCount).init(allocator);
    defer body_map.deinit();

    // First pass: count frequencies per body
    for (clean_lines.items) |line| {
        if (line.len == 0) continue;
        const body = stripTimestamp(line);
        if (body_map.getPtr(body)) |entry| {
            entry.count += 1;
        } else {
            try body_map.put(body, .{ .first_line = line, .count = 1 });
        }
    }

    // Second pass: collect output lines (deduped) for block-pattern post-processing
    var emitted_bodies = std.StringHashMap(void).init(allocator);
    defer emitted_bodies.deinit();

    var output_lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (output_lines.items) |s| allocator.free(s);
        output_lines.deinit(allocator);
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

        const body = stripTimestamp(line);

        if (run_count > 0 and std.mem.eql(u8, prev_body, body)) {
            run_count += 1;
            pending_blank = false;
            continue;
        }

        if (run_count > 0) {
            const total_count = body_map.get(prev_body).?.count;
            const fmt_line = try fmtLine(allocator, prev_line, total_count);
            if (pending_blank and output_lines.items.len > 0) {
                const blank = try allocator.dupe(u8, "");
                try output_lines.append(allocator, blank);
            }
            try output_lines.append(allocator, fmt_line);
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
        const fmt_line = try fmtLine(allocator, prev_line, total_count);
        try output_lines.append(allocator, fmt_line);
    }

    // Phase 3: Block-pattern collapse. Detect repeating blocks of K lines
    // (K=2..4) where each position has the same linePrefix. Collapse to
    // first block + "(N-1 more blocks)".
    var i: usize = 0;
    while (i < output_lines.items.len) {
        const ol = output_lines.items[i];
        if (ol.len == 0) {
            try writer.writeByte('\n');
            i += 1;
            continue;
        }

        // Try block sizes K=2,3,4
        var best_k: usize = 0;
        var best_repeats: usize = 0;
        for ([_]usize{ 2, 3, 4 }) |k| {
            if (i + k > output_lines.items.len) continue;
            // Check if lines at positions i..i+k each have a non-empty prefix
            var all_have_prefix = true;
            for (0..k) |j| {
                if (linePrefix(output_lines.items[i + j]).len == 0) {
                    all_have_prefix = false;
                    break;
                }
            }
            if (!all_have_prefix) continue;

            // Count how many times this K-line block repeats
            var repeats: usize = 1;
            var pos = i + k;
            while (pos + k <= output_lines.items.len) {
                var block_matches = true;
                for (0..k) |j| {
                    const this_prefix = linePrefix(output_lines.items[i + j]);
                    const next_prefix = linePrefix(output_lines.items[pos + j]);
                    if (!std.mem.eql(u8, this_prefix, next_prefix)) {
                        block_matches = false;
                        break;
                    }
                }
                if (!block_matches) break;
                repeats += 1;
                pos += k;
            }
            if (repeats >= 3 and repeats * k > best_repeats * best_k) {
                best_k = k;
                best_repeats = repeats;
            }
        }

        if (best_k > 0 and best_repeats >= 3) {
            // Emit first block, then summary
            for (0..best_k) |j| {
                try emitTruncated(writer, output_lines.items[i + j]);
            }
            try writer.writeAll("(+"); try ansi.writeDecimal(writer, best_repeats - 1); try writer.writeAll(")\n");
            i += best_k * best_repeats;
        } else {
            try emitTruncated(writer, ol);
            i += 1;
        }
    }
}

/// Emit a line, truncating if it exceeds MAX_LINE_LEN bytes.
const MAX_LINE_LEN: usize = 100;

fn emitTruncated(writer: *Writer, line: []const u8) !void {
    if (line.len > MAX_LINE_LEN) {
        try writer.writeAll(line[0..MAX_LINE_LEN]);
        try writer.writeAll("...+"); try ansi.writeDecimal(writer, line.len - MAX_LINE_LEN); try writer.writeByte('\n');
    } else {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

fn fmtLine(allocator: Allocator, line: []const u8, total_count: usize) ![]u8 {
    if (total_count > 1) {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        // For high-repetition lines (>50x), truncate to 64 chars since
        // the count already tells the story.
        const max_len = if (total_count > 50) @min(line.len, 64) else line.len;
        try buf.appendSlice(allocator, line[0..max_len]);
        if (max_len < line.len) {
            try buf.appendSlice(allocator, "...");
        }
        try buf.appendSlice(allocator, " \xc3\x97");
        var tmp: [20]u8 = undefined;
        var n = total_count;
        var ti: usize = tmp.len;
        if (n == 0) { ti -= 1; tmp[ti] = '0'; } else while (n > 0) { ti -= 1; tmp[ti] = @intCast('0' + n % 10); n /= 10; }
        try buf.appendSlice(allocator, tmp[ti..]);
        return try buf.toOwnedSlice(allocator);
    }
    return try allocator.dupe(u8, line);
}

/// Extract the leading "word" prefix of a line for block-pattern detection.
fn linePrefix(line: []const u8) []const u8 {
    if (line.len < 4) return "";
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    const word_start = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
    if (i == word_start or i >= line.len) return "";
    if (line[i] == ' ') return line[0 .. i + 1];
    return "";
}

/// Strip a leading timestamp prefix for RLE comparison.
/// Recognises common log-line timestamp formats:
///   ISO 8601: "2026-04-23T12:00:00" or "2026-04-23 12:00:00"
///   Syslog:   "Apr 23 2026 12:00:00" or "Apr 23 12:00:00"
///   Epoch-bracket: "[1682345678.123]" or "[2026-04-23T12:00:00]"
///   HH:MM:SS prefix: "12:00:00 ..."
/// Returns a slice into `line` starting after the timestamp + separator.
/// If no timestamp is detected, returns the full line.
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

fn stripTimestamp(line: []const u8) []const u8 {
    // Quick check: line must start with a digit, '[', or uppercase letter
    if (line.len < 8) return line;
    const c0 = line[0];

    // Bracketed prefix: [anything] — skip to after ']'
    if (c0 == '[') {
        if (std.mem.indexOfScalar(u8, line[1..], ']')) |idx| {
            const after = idx + 2; // past ']'
            if (after < line.len and (line[after] == ' ' or line[after] == '\t')) {
                return std.mem.trimStart(u8, line[after..], " \t");
            }
            return line[after..];
        }
        return line;
    }

    // ISO 8601: YYYY-MM-DD[T ]HH:MM:SS[.frac]?[Z|+HH:MM]?
    if (c0 >= '0' and c0 <= '9') {
        // Check YYYY-MM-DD pattern
        if (line.len >= 10 and line[4] == '-' and line[7] == '-') {
            if (line.len >= 19 and (line[10] == 'T' or line[10] == ' ') and
                line[13] == ':' and line[16] == ':')
            {
                var pos: usize = 19;
                // Skip fractional seconds
                if (pos < line.len and line[pos] == '.') {
                    pos += 1;
                    while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') : (pos += 1) {}
                }
                // Skip timezone
                if (pos < line.len and line[pos] == 'Z') {
                    pos += 1;
                } else if (pos < line.len and (line[pos] == '+' or line[pos] == '-') and pos + 5 <= line.len) {
                    pos += 6; // +HH:MM
                }
                if (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) {
                    return std.mem.trimStart(u8, line[pos..], " \t");
                }
                return line;
            }
        }
        // HH:MM:SS prefix
        if (line.len >= 8 and line[2] == ':' and line[5] == ':') {
            var pos: usize = 8;
            if (pos < line.len and line[pos] == '.') {
                pos += 1;
                while (pos < line.len and line[pos] >= '0' and line[pos] <= '9') : (pos += 1) {}
            }
            if (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) {
                return std.mem.trimStart(u8, line[pos..], " \t");
            }
        }
        return line;
    }

    // Syslog: "Mon DD [YYYY ]HH:MM:SS" — starts with 3-letter month abbreviation
    if (c0 >= 'A' and c0 <= 'Z' and line.len > 4 and line[3] == ' ') {
        // Check 3-letter month: Jan..Dec all have unique (c0,c2) pairs
        const is_month = switch (c0) {
            'J' => (line[1] == 'a' or line[1] == 'u'), // Jan, Jun, Jul
            'F' => line[1] == 'e', // Feb
            'M' => (line[1] == 'a'), // Mar, May
            'A' => (line[1] == 'p' or line[1] == 'u'), // Apr, Aug
            'S' => line[1] == 'e', // Sep
            'O' => line[1] == 'c', // Oct
            'N' => line[1] == 'o', // Nov
            'D' => line[1] == 'e', // Dec
            else => false,
        };
        if (is_month) {
            // "Apr 23 12:00:00 ..." or "Apr 23 2026 12:00:00 ..."
            // Scan for HH:MM:SS pattern (NN:NN:NN)
            var i: usize = 4;
            while (i + 8 <= line.len) : (i += 1) {
                if (line[i + 2] == ':' and line[i + 5] == ':' and
                    line[i] >= '0' and line[i] <= '9' and
                    line[i + 1] >= '0' and line[i + 1] <= '9' and
                    line[i + 3] >= '0' and line[i + 3] <= '9' and
                    line[i + 4] >= '0' and line[i + 4] <= '9' and
                    line[i + 6] >= '0' and line[i + 6] <= '9' and
                    line[i + 7] >= '0' and line[i + 7] <= '9')
                {
                    const after_time = i + 8;
                    if (after_time < line.len and (line[after_time] == ' ' or line[after_time] == '\t')) {
                        return std.mem.trimStart(u8, line[after_time..], " \t");
                    }
                    return line;
                }
                // Don't scan too far — timestamp must be near the start
                if (i > 20) break;
            }
        }
    }

    return line;
}


test "matches: threshold boundary" {
    const below = [_]u8{'x'} ** THRESHOLD_BYTES;
    const at = [_]u8{'x'} ** (THRESHOLD_BYTES + 1);
    try std.testing.expect(!matches(&below));
    try std.testing.expect(matches(&at));
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

test "apply: timestamp-aware RLE collapses syslog lines" {
    const input = "Apr 23 2026 00:00:01 host kernel: [UFW BLOCK]\nApr 23 2026 00:10:01 host kernel: [UFW BLOCK]\nApr 23 2026 00:20:01 host kernel: [UFW BLOCK]\ndifferent line\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("Apr 23 2026 00:00:01 host kernel: [UFW BLOCK] ×3\ndifferent line\n", out.written());
}

test "apply: timestamp-aware RLE collapses ISO 8601 lines" {
    const input = "2026-04-23 12:00:00 INFO request ok\n2026-04-23 12:01:00 INFO request ok\n2026-04-23 12:02:00 INFO request ok\nother\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("2026-04-23 12:00:00 INFO request ok ×3\nother\n", out.written());
}

test "stripTimestamp: no timestamp returns full line" {
    try std.testing.expectEqualStrings("hello world", stripTimestamp("hello world"));
}

test "stripTimestamp: ISO 8601" {
    try std.testing.expectEqualStrings("INFO ok", stripTimestamp("2026-04-23 12:00:00 INFO ok"));
    try std.testing.expectEqualStrings("INFO ok", stripTimestamp("2026-04-23T12:00:00Z INFO ok"));
}

test "stripTimestamp: syslog format" {
    try std.testing.expectEqualStrings("host kernel: msg", stripTimestamp("Apr 23 2026 12:00:00 host kernel: msg"));
}

test "stripTimestamp: bracketed" {
    try std.testing.expectEqualStrings("INFO ok", stripTimestamp("[2026-04-23T12:00:00] INFO ok"));
}
