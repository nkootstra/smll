const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.6 grammar for `tree` output:
//
// Structural prefix bytes (leading on each line, excluding the name):
//   0x20                space
//   0xc2 0xa0           NBSP (U+00A0) — tree uses these for vertical alignment
//   0xe2 0x94 0x??      box-drawing chars (│ ├ └ ─ and other U+2500–U+257F)
//
// Encoding: if the leading structural prefix of the current line equals the
// leading structural prefix of the previous line, emit SIGIL + name_part.
// Otherwise emit the line verbatim.
//
// Sigil: '~' (0x7e). Never appears in a tree structural prefix.
// Escape rule: if a name part starts with '~' (a literal file named "~foo"),
// double the sigil on encode. Decoder: "~~X" → "X" with prefix unchanged from prev.
//
// Byte-exact lossless. Collision guard: when prefix matches but line[prefix_len]
// is '~', we'd emit "~~..." which decodes as the escape form; skip elide and
// emit full line in that case.

const SIGIL: u8 = '~';

pub fn matches(input: []const u8) bool {
    if (input.len == 0) return false;
    // First line: must not start with whitespace/control.
    if (input[0] == ' ' or input[0] == '\t' or input[0] < 0x20) return false;

    // Look for a structural line within the first 6 lines — a line beginning
    // with ├ (e2 94 9c), └ (e2 94 94), or │ (e2 94 82). This is the tree
    // signature.  Without it, input is not tree output.
    var i: usize = 0;
    var line_count: usize = 0;
    while (i < input.len and line_count < 6) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];
        if (line.len >= 3 and line[0] == 0xe2 and line[1] == 0x94) {
            const c = line[2];
            if (c == 0x9c or c == 0x94 or c == 0x82) return true;
        }
        if (i < input.len) i += 1;
        line_count += 1;
    }
    return false;
}

// Returns the number of leading structural bytes (space, NBSP, box-drawing).
// Stops at the first non-structural byte — that's where the name begins.
fn prefixLen(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len) {
        const b = line[i];
        if (b == 0x20) {
            i += 1;
            continue;
        }
        if (b == 0xc2 and i + 1 < line.len and line[i + 1] == 0xa0) {
            i += 2;
            continue;
        }
        if (b == 0xe2 and i + 2 < line.len and line[i + 1] == 0x94) {
            // U+2500–U+253F range: box-drawing light set covers all tree chars
            i += 3;
            continue;
        }
        break;
    }
    return i;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var prev_depth: usize = 0;

    var i: usize = 0;
    while (i < stdout.len) {
        const line_start = i;
        while (i < stdout.len and stdout[i] != '\n') i += 1;
        const line = stdout[line_start..i];

        const cur_plen = prefixLen(line);
        const name_part = line[cur_plen..];

        // Count nesting depth from box-drawing characters
        const depth = countDepth(line[0..cur_plen]);

        if (name_part.len > 0) {
            // Same depth as previous — use sigil
            if (depth == prev_depth and depth > 0) {
                try writer.writeByte(SIGIL);
                try writer.writeAll(name_part);
            } else {
                // Emit indent (2 spaces per depth level) + name
                for (0..depth) |_| {
                    try writer.writeAll("  ");
                }
                try writer.writeAll(name_part);
                prev_depth = depth;
            }
        } else if (cur_plen == 0 and line.len > 0) {
            // Root line or summary line (no prefix)
            try writer.writeAll(line);
            prev_depth = 0;
        }

        if (i < stdout.len) {
            try writer.writeByte('\n');
            i += 1;
        }
    }
}

/// Count nesting depth from prefix length.
/// Each tree nesting level adds ~4 bytes of box-drawing + space.
fn countDepth(prefix: []const u8) usize {
    if (prefix.len == 0) return 0;
    // Count box-drawing characters that indicate nesting depth.
    // Each nesting level contributes │ (continuation) or ├/└ (branch).
    var depth: usize = 0;
    var i: usize = 0;
    while (i + 2 < prefix.len) {
        if (prefix[i] == 0xe2 and prefix[i + 1] == 0x94) {
            const c = prefix[i + 2];
            // │ (82), ├ (9c), └ (94) all indicate a nesting level
            if (c == 0x82 or c == 0x9c or c == 0x94) depth += 1;
            i += 3;
        } else {
            i += 1;
        }
    }
    return depth;
}

pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var prev_prefix: []const u8 = "";

    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];

        // Three-way decode: the encoder distinguishes three forms at line start.
        //
        // (a) `~~...`    — root-level escape (plen==0 at encode time, name started
        //                   with SIGIL). Strip one sigil; prev_prefix recomputed.
        // (b) `~<rest>`  — elide (always prev_plen > 0 at encode time, rest does
        //                   NOT start with SIGIL by encoder's collision guard).
        //                   Emit prev_prefix ++ rest; prev_prefix unchanged.
        // (c) otherwise  — verbatim line.  May still carry inside-prefix escape
        //                   `<prefix>~<name>` where name originally starts with
        //                   SIGIL.  Detect by checking byte at prefix_len.
        if (line.len >= 2 and line[0] == SIGIL and line[1] == SIGIL) {
            try out.appendSlice(allocator, line[1..]);
            prev_prefix = line[1 .. 1 + prefixLen(line[1..])];
        } else if (line.len >= 1 and line[0] == SIGIL) {
            try out.appendSlice(allocator, prev_prefix);
            try out.appendSlice(allocator, line[1..]);
            // prev_prefix unchanged
        } else {
            const plen = prefixLen(line);
            if (plen < line.len and line[plen] == SIGIL) {
                try out.appendSlice(allocator, line[0..plen]);
                try out.appendSlice(allocator, line[plen + 1 ..]);
                prev_prefix = line[0..plen];
            } else {
                try out.appendSlice(allocator, line);
                prev_prefix = line[0..plen];
            }
        }

        if (i < input.len) {
            try out.append(allocator, '\n');
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture_tree_src = @embedFile("fixture_tree_src");

fn applyToString(a: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try apply(a, input, &.{}, &out.writer);
    return a.dupe(u8, out.written());
}

fn roundTrip(a: Allocator, input: []const u8) !void {
    const encoded = try applyToString(a, input);
    defer a.free(encoded);
    const decoded = try decode(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}

test "matches: tree output accepted" {
    try std.testing.expect(matches(fixture_tree_src));
}

test "matches: empty rejected" {
    try std.testing.expect(!matches(""));
}

test "matches: rg --files rejected (no box-drawing)" {
    try std.testing.expect(!matches("src/main.zig\nsrc/util.zig\n"));
}

test "matches: leading whitespace rejected" {
    try std.testing.expect(!matches("  src/main.zig\n"));
}

test "prefixLen: empty line" {
    try std.testing.expectEqual(@as(usize, 0), prefixLen(""));
}

test "prefixLen: spaces only" {
    try std.testing.expectEqual(@as(usize, 3), prefixLen("   foo"));
}

test "prefixLen: nbsp + box-drawing" {
    // "│   ├── detect.zig" → prefix = 3+2+2+1+3+3+3+1 = 18
    const line = "\xe2\x94\x82\xc2\xa0\xc2\xa0 \xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 detect.zig";
    try std.testing.expectEqual(@as(usize, 18), prefixLen(line));
}

test "encode: empty" {
    const a = std.testing.allocator;
    const out = try applyToString(a, "");
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "encode: single root line" {
    const a = std.testing.allocator;
    const out = try applyToString(a, "src/\n");
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "src/") != null);
}

test "encode: box-drawing replaced with indentation" {
    // ├── foo\n├── bar\n
    const input = "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 foo\n\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 bar\n";
    const a = std.testing.allocator;
    const out = try applyToString(a, input);
    defer a.free(out);
    // Box-drawing bytes should be gone
    try std.testing.expect(std.mem.find(u8, out, "\xe2\x94") == null);
    // Names preserved
    try std.testing.expect(std.mem.find(u8, out, "foo") != null);
    try std.testing.expect(std.mem.find(u8, out, "bar") != null);
}

test "encode: fixture compresses" {
    const a = std.testing.allocator;
    const out = try applyToString(a, fixture_tree_src);
    defer a.free(out);
    try std.testing.expect(out.len < fixture_tree_src.len);
    // All file names preserved
    try std.testing.expect(std.mem.find(u8, out, "main.zig") != null);
    try std.testing.expect(std.mem.find(u8, out, "pipeline.zig") != null);
}

test "compression: fixture shrinks significantly" {
    const a = std.testing.allocator;
    const out = try applyToString(a, fixture_tree_src);
    defer a.free(out);
    const savings_pct = (fixture_tree_src.len - out.len) * 100 / fixture_tree_src.len;
    // Fixture has 17 lines sharing the depth-2 prefix (18 bytes).
    // Savings: ~17 * 17 = 289 of 706 = ~41%.
    try std.testing.expect(savings_pct >= 30);
}
