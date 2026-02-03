const std = @import("std");
const Allocator = std.mem.Allocator;

/// Strip CSI (`\x1b[...m`, cursor moves, etc.) and OSC (`\x1b]...\x07` or
/// `\x1b\\`) escape sequences from `input`.
///
/// Returns the original slice when no ESC byte is found — caller must compare
/// pointer identity before freeing. Otherwise returns a newly-allocated slice.
///
/// `noinline` forces outlining so all call sites share a single copy — critical
/// for R6 binary budget with 7+ filter modules that each strip ANSI.
pub noinline fn strip(allocator: Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, 0x1b) == null) return input;
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try stripAppend(&buf, allocator, input);
    return buf.toOwnedSlice(allocator);
}

/// Strip ANSI into a caller-owned scratch buffer. Returns a slice borrowed
/// from `scratch`, which stays valid until `scratch.clearRetainingCapacity()`
/// or the next `stripInto` call. When `input` has no ESC bytes, returns
/// `input` directly without touching `scratch` — caller must compare ptrs
/// before reusing the scratch slot.
///
/// This is the per-line hot-path entry: reuses capacity across thousands of
/// lines in test-runner / log filters instead of bump-allocating each time.
pub fn stripInto(scratch: *std.ArrayList(u8), allocator: Allocator, input: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, input, 0x1b) == null) return input;
    scratch.clearRetainingCapacity();
    try stripAppend(scratch, allocator, input);
    return scratch.items;
}

noinline fn stripAppend(buf: *std.ArrayList(u8), allocator: Allocator, input: []const u8) !void {
    var i: usize = 0;
    while (i < input.len) {
        // Jump to the next ESC (or end) in one SIMD-friendly scan, then bulk-
        // copy the literal run. Byte-at-a-time was the bottleneck for dense
        // ANSI inputs like colorized test-runner output.
        const next_esc = std.mem.indexOfScalarPos(u8, input, i, 0x1b) orelse input.len;
        if (next_esc > i) try buf.appendSlice(allocator, input[i..next_esc]);
        i = next_esc;
        if (i >= input.len) break;
        if (i + 1 >= input.len) {
            i += 1;
            continue;
        }
        const c2 = input[i + 1];
        if (c2 == '[') {
            // CSI: \x1b[ ... final-byte (0x40..0x7E)
            i += 2;
            while (i < input.len and (input[i] < 0x40 or input[i] > 0x7E)) i += 1;
            if (i < input.len) i += 1;
        } else if (c2 == ']') {
            // OSC: \x1b] ... (BEL | ESC\)
            i += 2;
            while (i < input.len) {
                if (input[i] == 0x07) {
                    i += 1;
                    break;
                }
                if (input[i] == 0x1b and i + 1 < input.len and input[i + 1] == '\\') {
                    i += 2;
                    break;
                }
                i += 1;
            }
        } else {
            // Other ESC seq (cursor move etc.): skip ESC + one byte.
            i += 2;
        }
    }
}

test "strip: no escapes returns input ptr" {
    const s = "no escapes here";
    const got = try strip(std.testing.allocator, s);
    try std.testing.expect(got.ptr == s.ptr);
}

test "strip: removes CSI" {
    const stripped = try strip(std.testing.allocator, "\x1b[31mred\x1b[0m plain");
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("red plain", stripped);
}

test "strip: removes OSC" {
    const stripped = try strip(std.testing.allocator, "\x1b]0;title\x07after");
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("after", stripped);
}

test "stripInto: reuses scratch, returns borrowed slice" {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(std.testing.allocator);
    const a = try stripInto(&scratch, std.testing.allocator, "\x1b[31mfoo\x1b[0m");
    try std.testing.expectEqualStrings("foo", a);
    // Second call on a clean line returns input pointer (scratch not touched).
    const raw = "clean line";
    const b = try stripInto(&scratch, std.testing.allocator, raw);
    try std.testing.expect(b.ptr == raw.ptr);
    // Third call rewrites scratch; prior borrowed slice `a` is now invalid but
    // the API only promises validity up to the next stripInto call.
    const c = try stripInto(&scratch, std.testing.allocator, "\x1b[1;32mbar\x1b[0m");
    try std.testing.expectEqualStrings("bar", c);
}
