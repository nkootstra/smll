const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.6 prototype: tool-agnostic detection filter.
//
// Three single-pass byte-level transforms, chained:
//   1. ANSI CSI escape strip   — ESC [ ... final-byte → dropped
//   2. Whitespace collapse     — runs of 2+ spaces → 1 space (outside leading indent);
//                                trailing whitespace stripped
//   3. Prefix RLE              — if first 16 bytes of line == prev line's first 16 bytes,
//                                emit only the remainder (inherit rule on reader side)
//
// Not a shipping filter yet — this is for measurement under `SMLL_DETECT=1`.
// pipe-mode only. Passthrough on size < 256 B (overhead > savings).

pub fn matches(input: []const u8) bool {
    _ = input;
    return true;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    if (stdout.len == 0) return;
    if (stdout.len < 256) {
        try writer.writeAll(stdout);
        return;
    }

    const step1 = try stripAnsi(allocator, stdout);
    defer allocator.free(step1);
    const step2 = try collapseWhitespace(allocator, step1);
    defer allocator.free(step2);
    try prefixRleEmit(step2, writer);
}

fn stripAnsi(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;
            while (i < input.len) {
                const c = input[i];
                i += 1;
                if (c >= 0x40 and c <= 0x7e) break;
            }
            continue;
        }
        try out.append(allocator, input[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn collapseWhitespace(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    var i: usize = 0;
    while (i < input.len) {
        // preserve leading indent verbatim
        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) {
            try out.append(allocator, input[i]);
            i += 1;
        }
        // collapse interior spaces; strip trailing spaces
        while (i < input.len and input[i] != '\n') {
            if (input[i] == ' ') {
                var run_end = i;
                while (run_end < input.len and input[run_end] == ' ') run_end += 1;
                if (run_end == input.len or input[run_end] == '\n') {
                    i = run_end;
                } else {
                    try out.append(allocator, ' ');
                    i = run_end;
                }
            } else {
                try out.append(allocator, input[i]);
                i += 1;
            }
        }
        if (i < input.len) {
            try out.append(allocator, '\n');
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn prefixRleEmit(input: []const u8, writer: *Writer) !void {
    const plen: usize = 16;
    var prev_prefix: []const u8 = "";
    var first_line = true;
    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];
        const cur_plen = @min(line.len, plen);
        const this_prefix = line[0..cur_plen];
        if (!first_line and cur_plen == plen and std.mem.eql(u8, this_prefix, prev_prefix)) {
            try writer.writeAll(line[plen..]);
        } else {
            try writer.writeAll(line);
            prev_prefix = this_prefix;
        }
        if (i < input.len) {
            try writer.writeByte('\n');
            i += 1;
        }
        first_line = false;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "passthrough: input under 256 B" {
    const input = "tiny output\n";
    const got = try applyToString(std.testing.allocator, input);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(input, got);
}

test "ansi strip: removes CSI sequences" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var n: usize = 0;
    while (n < 20) : (n += 1) {
        try list.appendSlice(std.testing.allocator, "\x1b[31mred line\x1b[0m text here padding padding\n");
    }
    const got = try applyToString(std.testing.allocator, list.items);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.find(u8, got, "\x1b[") == null);
    try std.testing.expect(std.mem.find(u8, got, "red line") != null);
}

test "whitespace collapse: runs of spaces shrunk, trailing stripped, leading kept" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var n: usize = 0;
    while (n < 15) : (n += 1) {
        try list.appendSlice(std.testing.allocator, "  indent_kept   alpha    beta     gamma   \n");
    }
    const got = try applyToString(std.testing.allocator, list.items);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.find(u8, got, "  indent_kept alpha beta gamma\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "gamma   \n") == null);
}

test "prefix RLE: identical 16-byte prefix on consecutive lines elided" {
    // "src/filters/dir/" is exactly 16 chars — stable across all lines.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var n: usize = 0;
    while (n < 20) : (n += 1) {
        try list.appendSlice(std.testing.allocator, "src/filters/dir/file");
        try list.append(std.testing.allocator, '0' + @as(u8, @intCast(n % 10)));
        try list.append(std.testing.allocator, '\n');
    }
    const got = try applyToString(std.testing.allocator, list.items);
    defer std.testing.allocator.free(got);
    try std.testing.expect(got.len < list.items.len);
    // First line: full "src/filters/dir/fileN"
    try std.testing.expect(std.mem.startsWith(u8, got, "src/filters/dir/file0"));
}

test "combined: all three levers together yield net reduction" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);
    var n: usize = 0;
    while (n < 30) : (n += 1) {
        try list.appendSlice(std.testing.allocator, "\x1b[32m");
        try list.appendSlice(std.testing.allocator, "src/filters/detect.zig   ");
        try list.appendSlice(std.testing.allocator, "\x1b[0m");
        try list.appendSlice(std.testing.allocator, " status ok   \n");
    }
    const got = try applyToString(std.testing.allocator, list.items);
    defer std.testing.allocator.free(got);
    try std.testing.expect(got.len < list.items.len);
    // Rough expectation: ≥20% reduction on this highly-repetitive colored input
    const target = (list.items.len * 80) / 100;
    try std.testing.expect(got.len <= target);
}
