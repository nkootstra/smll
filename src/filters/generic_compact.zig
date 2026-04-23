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

pub const THRESHOLD_BYTES: usize = 64 * 1024;

pub fn matches(input: []const u8) bool {
    return input.len > THRESHOLD_BYTES;
}

pub fn apply(allocator: Allocator, stdout: []const u8, writer: *Writer) !void {
    if (stdout.len == 0) return;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var prev_line: std.ArrayList(u8) = .empty;
    defer prev_line.deinit(allocator);

    var run_count: usize = 0;
    var pending_blank: bool = false;
    var emitted_any: bool = false;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");

        if (line.len == 0) {
            pending_blank = true;
            continue;
        }

        if (run_count > 0 and std.mem.eql(u8, prev_line.items, line)) {
            run_count += 1;
            pending_blank = false;
            continue;
        }
        if (run_count > 0) {
            try flush(writer, prev_line.items, run_count);
            emitted_any = true;
        }
        if (pending_blank and emitted_any) {
            try writer.writeByte('\n');
        }
        pending_blank = false;
        prev_line.clearRetainingCapacity();
        try prev_line.appendSlice(allocator, line);
        run_count = 1;
    }

    if (run_count > 0) {
        try flush(writer, prev_line.items, run_count);
    }
}

fn flush(writer: *Writer, line: []const u8, count: usize) !void {
    try writer.writeAll(line);
    if (count > 1) {
        try writer.print("  (x{d})", .{count});
    }
    try writer.writeByte('\n');
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
    try std.testing.expectEqualStrings("a\n\nb\n\nc\n", out.written());
}

test "apply: RLE collapses identical lines" {
    const input = "log entry\nlog entry\nlog entry\nother\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("log entry  (x3)\nother\n", out.written());
}

test "apply: all identical lines collapse to single marker" {
    const input = "same\nsame\nsame\nsame\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &out.writer);
    try std.testing.expectEqualStrings("same  (x4)\n", out.written());
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
    try std.testing.expectEqualStrings("log  (x3)\n\nafter\n", out.written());
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
