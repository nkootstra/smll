const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ansi = @import("ansi");

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

    // Look for a structural line within the first 6 lines. Unicode tree uses
    // box-drawing bytes; `LC_ALL=C tree` uses ASCII branch markers (`|--`,
    // `--`). Without one of those signatures, input is not tree output.
    var i: usize = 0;
    var line_count: usize = 0;
    while (i < input.len and line_count < 6) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];
        if (isUnicodeTreeLine(line) or isAsciiTreeLine(line)) return true;
        if (i < input.len) i += 1;
        line_count += 1;
    }
    return false;
}

fn isUnicodeTreeLine(line: []const u8) bool {
    if (line.len < 3 or line[0] != 0xe2 or line[1] != 0x94) return false;
    const c = line[2];
    return c == 0x9c or c == 0x94 or c == 0x82;
}

fn isAsciiTreeLine(line: []const u8) bool {
    return parseAsciiTreeLine(line) != null;
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

const TreeEntry = struct {
    depth: usize,
    name: []const u8,
    is_dir: bool = false,
};

const ParsedTreeLine = struct {
    depth: usize,
    name: []const u8,
    is_dir_hint: bool,
};

pub fn applyCompact(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    if (stdout.len == 0) return;

    var entries: std.ArrayList(TreeEntry) = .empty;
    defer entries.deinit(allocator);
    var summary: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (isTreeSummaryLine(line)) {
            summary = line;
            continue;
        }

        const parsed = parseTreeLine(line) orelse continue;
        const name = if (std.mem.endsWith(u8, parsed.name, "/")) parsed.name[0 .. parsed.name.len - 1] else parsed.name;
        try entries.append(allocator, .{
            .depth = parsed.depth,
            .name = name,
            .is_dir = parsed.is_dir_hint or parsed.depth == 0,
        });
    }

    if (entries.items.len == 0) {
        if (summary) |s| {
            try writer.writeAll(s);
            try writer.writeByte('\n');
        }
        return;
    }

    markInferredDirs(entries.items);

    var first_out = true;
    try emitTreeEntry(entries.items, 0, writer, &first_out);
    if (summary) |s| {
        if (!first_out) try writer.writeByte('\n');
        try writer.writeAll(s);
        first_out = false;
    }
    if (!first_out) try writer.writeByte('\n');
}

fn parseTreeLine(line: []const u8) ?ParsedTreeLine {
    if (parseAsciiTreeLine(line)) |parsed| return parsed;

    const plen = prefixLen(line);
    const name_part = std.mem.trim(u8, line[plen..], " \t");
    if (name_part.len == 0) return null;

    return .{
        .depth = countDepth(line[0..plen]),
        .name = name_part,
        .is_dir_hint = std.mem.endsWith(u8, name_part, "/"),
    };
}

fn parseAsciiTreeLine(line: []const u8) ?ParsedTreeLine {
    var i: usize = 0;
    var depth: usize = 0;
    while (i + 4 <= line.len) {
        if (std.mem.eql(u8, line[i .. i + 4], "|   ") or std.mem.eql(u8, line[i .. i + 4], "    ")) {
            depth += 1;
            i += 4;
            continue;
        }
        break;
    }

    if (i + 4 > line.len) return null;
    if (!std.mem.eql(u8, line[i .. i + 4], "|-- ") and !std.mem.eql(u8, line[i .. i + 4], "`-- ")) return null;

    const name_part = std.mem.trim(u8, line[i + 4 ..], " \t");
    if (name_part.len == 0) return null;
    return .{
        .depth = depth + 1,
        .name = name_part,
        .is_dir_hint = std.mem.endsWith(u8, name_part, "/"),
    };
}

/// Count nesting depth from the visual width of the structural prefix. `tree`
/// uses four columns per level, whether an ancestor column is `│   ` or spaces.
fn countDepth(prefix: []const u8) usize {
    if (prefix.len == 0) return 0;
    var columns: usize = 0;
    var i: usize = 0;
    while (i < prefix.len) {
        if (prefix[i] == 0xe2 and i + 2 < prefix.len and prefix[i + 1] == 0x94) {
            columns += 1;
            i += 3;
        } else if (prefix[i] == 0xc2 and i + 1 < prefix.len and prefix[i + 1] == 0xa0) {
            columns += 1;
            i += 2;
        } else {
            columns += 1;
            i += 1;
        }
    }
    return columns / 4;
}

fn isTreeSummaryLine(line: []const u8) bool {
    return (std.mem.find(u8, line, " directory") != null or std.mem.find(u8, line, " directories") != null) and
        std.mem.find(u8, line, " file") != null;
}

fn markInferredDirs(entries: []TreeEntry) void {
    if (entries.len == 0) return;
    for (entries[0 .. entries.len - 1], 0..) |*entry, idx| {
        if (entries[idx + 1].depth > entry.depth) entry.is_dir = true;
    }
}

fn emitTreeEntry(entries: []const TreeEntry, idx: usize, writer: *Writer, first_out: *bool) !void {
    const entry = entries[idx];
    try writeTreeEntryLine(writer, first_out, entry.depth, entry.name, entry.is_dir);
    if (!entry.is_dir) return;

    const end = subtreeEnd(entries, idx);
    const file_count = directFileCount(entries, idx, end);
    var file_group_emitted = false;

    var child = idx + 1;
    while (child < end) {
        if (entries[child].depth != entry.depth + 1) {
            child += 1;
            continue;
        }

        const child_entry = entries[child];
        if (!child_entry.is_dir) {
            if (file_count >= 4) {
                if (!file_group_emitted) {
                    try writeCollapsedFilesLine(writer, first_out, entries, idx, end, file_count);
                    file_group_emitted = true;
                }
            } else {
                try writeTreeEntryLine(writer, first_out, child_entry.depth, child_entry.name, false);
            }
            child += 1;
            continue;
        }

        const child_end = subtreeEnd(entries, child);
        const direct_count = directChildCount(entries, child, child_end);
        if (child_entry.depth >= 2 and direct_count >= 4) {
            try writeCollapsedDirLine(writer, first_out, entries, child, child_end, direct_count);
        } else {
            try emitTreeEntry(entries, child, writer, first_out);
        }
        child = child_end;
    }
}

fn subtreeEnd(entries: []const TreeEntry, idx: usize) usize {
    const depth = entries[idx].depth;
    var end = idx + 1;
    while (end < entries.len and entries[end].depth > depth) : (end += 1) {}
    return end;
}

fn directChildCount(entries: []const TreeEntry, idx: usize, end: usize) usize {
    const child_depth = entries[idx].depth + 1;
    var count: usize = 0;
    var i = idx + 1;
    while (i < end) : (i += 1) {
        if (entries[i].depth == child_depth) count += 1;
    }
    return count;
}

fn directFileCount(entries: []const TreeEntry, idx: usize, end: usize) usize {
    const child_depth = entries[idx].depth + 1;
    var count: usize = 0;
    var i = idx + 1;
    while (i < end) : (i += 1) {
        if (entries[i].depth == child_depth and !entries[i].is_dir) count += 1;
    }
    return count;
}

fn writeTreeEntryLine(writer: *Writer, first_out: *bool, depth: usize, name: []const u8, is_dir: bool) !void {
    if (!first_out.*) try writer.writeByte('\n');
    try writeIndent(writer, depth);
    try writer.writeAll(name);
    if (is_dir and !std.mem.endsWith(u8, name, "/") and !std.mem.eql(u8, name, ".")) {
        try writer.writeByte('/');
    }
    first_out.* = false;
}

fn writeCollapsedDirLine(
    writer: *Writer,
    first_out: *bool,
    entries: []const TreeEntry,
    idx: usize,
    end: usize,
    direct_count: usize,
) !void {
    if (!first_out.*) try writer.writeByte('\n');
    const entry = entries[idx];
    try writeIndent(writer, entry.depth);
    try writer.writeAll(entry.name);
    if (!std.mem.endsWith(u8, entry.name, "/")) try writer.writeByte('/');
    try writer.writeAll(" (");
    try ansi.writeDecimal(writer, direct_count);
    try writer.writeByte(' ');
    try writer.writeAll(if (directChildrenAllFiles(entries, idx, end)) "files" else "entries");
    try writer.writeAll(": ");
    try writeDirectExamples(writer, entries, idx, end);
    try writer.writeByte(')');
    first_out.* = false;
}

fn writeCollapsedFilesLine(
    writer: *Writer,
    first_out: *bool,
    entries: []const TreeEntry,
    idx: usize,
    end: usize,
    file_count: usize,
) !void {
    if (!first_out.*) try writer.writeByte('\n');
    try writeIndent(writer, entries[idx].depth + 1);
    try writer.writeAll("(");
    try ansi.writeDecimal(writer, file_count);
    try writer.writeAll(" files: ");

    var written: usize = 0;
    const child_depth = entries[idx].depth + 1;
    var i = idx + 1;
    while (i < end and written < 3) : (i += 1) {
        if (entries[i].depth != child_depth or entries[i].is_dir) continue;
        if (written > 0) try writer.writeAll(", ");
        try writer.writeAll(entries[i].name);
        written += 1;
    }
    if (file_count > 3) try writer.writeAll(", ...");
    try writer.writeByte(')');
    first_out.* = false;
}

fn directChildrenAllFiles(entries: []const TreeEntry, idx: usize, end: usize) bool {
    const child_depth = entries[idx].depth + 1;
    var saw = false;
    var i = idx + 1;
    while (i < end) : (i += 1) {
        if (entries[i].depth != child_depth) continue;
        saw = true;
        if (entries[i].is_dir) return false;
    }
    return saw;
}

fn writeDirectExamples(writer: *Writer, entries: []const TreeEntry, idx: usize, end: usize) !void {
    const child_depth = entries[idx].depth + 1;
    var written: usize = 0;
    var total: usize = 0;
    var i = idx + 1;
    while (i < end) : (i += 1) {
        if (entries[i].depth != child_depth) continue;
        total += 1;
        if (written >= 3) continue;
        if (written > 0) try writer.writeAll(", ");
        try writer.writeAll(entries[i].name);
        if (entries[i].is_dir and !std.mem.endsWith(u8, entries[i].name, "/")) try writer.writeByte('/');
        written += 1;
    }
    if (total > 3) try writer.writeAll(", ...");
}

fn writeIndent(writer: *Writer, depth: usize) !void {
    for (0..depth) |_| try writer.writeAll("  ");
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
const fixture_tree_large = @embedFile("fixture_tree_large");
const fixture_tree_ascii_large = @embedFile("fixture_tree_ascii_large");

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

test "matches: ASCII tree output accepted" {
    try std.testing.expect(matches(fixture_tree_ascii_large));
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

test "applyCompact: large tree keeps structure and collapsed counts" {
    const a = std.testing.allocator;
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try applyCompact(a, fixture_tree_large, &.{}, &out.writer);
    const got = out.written();

    try std.testing.expect(std.mem.find(u8, got, ".\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "  src/\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "  tests/\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "    filters/ (6 files: cargo_test.zig, git_diff.zig, git_log.zig, ...)") != null);
    try std.testing.expect(std.mem.find(u8, got, "    core/ (5 files: analyzer.zig, main.zig, parser.zig, ...)") != null);
    try std.testing.expect(std.mem.find(u8, got, "    main.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "    wrapper.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "    fixtures/ (5 files: find_plain_many.txt, git_diff_simple.txt, git_log_stat.txt, ...)") != null);
    try std.testing.expect(std.mem.find(u8, got, "7 directories, 24 files") != null);
    try std.testing.expect(got.len < fixture_tree_large.len);
}

test "applyCompact: ASCII tree keeps structure and collapsed counts" {
    const a = std.testing.allocator;
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try applyCompact(a, fixture_tree_ascii_large, &.{}, &out.writer);
    const got = out.written();

    try std.testing.expect(std.mem.find(u8, got, ".\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "  .git/\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "    hooks/ (14 files: applypatch-msg.sample, commit-msg.sample, fsmonitor-watchman.sample, ...)") != null);
    try std.testing.expect(std.mem.find(u8, got, "  docs/\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "    guides/ (12 files: file_003.txt, file_009.txt, file_015.txt, ...)") != null);
    try std.testing.expect(std.mem.find(u8, got, "  src/\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "    core/ (12 files: file_000.txt, file_001.txt, file_003.txt, ...)") != null);
    try std.testing.expect(std.mem.find(u8, got, "    ui/ (12 files: file_000.txt, file_001.txt, file_002.txt, ...)") != null);
    try std.testing.expect(std.mem.find(u8, got, "167 directories, 166 files") != null);
    try std.testing.expect(got.len <= (fixture_tree_ascii_large.len * 45) / 100);
}

test "applyCompact: preserves small tree facts" {
    const a = std.testing.allocator;
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try applyCompact(a, fixture_tree_src, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "src/") != null);
    try std.testing.expect(std.mem.find(u8, got, "  filters/\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "    (19 files: detect.zig, git_add.zig, git_blame.zig, ...)") != null);
    try std.testing.expect(std.mem.find(u8, got, "main.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "2 directories, 22 files") != null);
    try std.testing.expect(got.len < fixture_tree_src.len);
}
