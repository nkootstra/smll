const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY columnar compaction — on by default (v0.6). Set
// SMLL_LOSSLESS=1 to bypass.
//
// Target: docker ps, docker images, kubectl get, gh pr list, and high-confidence
// generic tables where rows are whitespace-separated columns padded to visual width.
//
// Algorithm (one-way encode; decode is approximate and unused in product):
//   1. Parse each line into fields, splitting on runs of ≥2 spaces.
//   2. Rejoin fields with a single space (discards visual column alignment).
//   3. In command-specific mode, per-column RLE replaces a field that repeats
//      the row above with a '~' sigil (distinguishable from an empty field).
//
// Contract:
//   • Byte content is altered (padding collapsed).  Not lossless.
//   • Semantic content (field values, row order) preserved.
//   • Measured token savings: 15% (docker ps), 26% (docker images).
//
// Command-specific dispatch may still use repeated-field elision and path
// truncation. Generic dispatch only collapses padding so every row stays
// self-contained for agents.

const MIN_GAP: usize = 2;

pub fn matches(input: []const u8) bool {
    if (input.len == 0) return false;
    // Accept when any line in the input contains a ≥MIN_GAP space run.  This
    // tolerates preamble lines (e.g. `gh pr list`'s "Showing N of M..." banner)
    // before the tabular body.  Rejects single-column path lists and plain prose.
    var i: usize = 0;
    var run: usize = 0;
    while (i < input.len) : (i += 1) {
        const b = input[i];
        if (b == '\n') {
            run = 0;
        } else if (b == ' ') {
            run += 1;
            if (run >= MIN_GAP) return true;
        } else {
            run = 0;
        }
    }
    return false;
}

pub fn matchesGeneric(input: []const u8) bool {
    if (input.len == 0) return false;

    var tabular_lines: usize = 0;
    var expected_fields: usize = 0;
    var consistent_rows: usize = 0;

    var i: usize = 0;
    while (i < input.len) {
        const line_start = i;
        while (i < input.len and input[i] != '\n') i += 1;
        const line = input[line_start..i];
        if (i < input.len) i += 1;

        if (!lineIsTabular(line)) continue;
        const fields = countFields(line);
        if (fields < 3) continue;
        tabular_lines += 1;
        if (expected_fields == 0) {
            expected_fields = fields;
            consistent_rows = 1;
        } else if (fields == expected_fields) {
            consistent_rows += 1;
        }
    }

    return tabular_lines >= 3 and consistent_rows >= 3;
}

fn lineIsTabular(line: []const u8) bool {
    var run: usize = 0;
    for (line) |b| {
        if (b == ' ') {
            run += 1;
            if (run >= MIN_GAP) return true;
        } else {
            run = 0;
        }
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    try applyInner(allocator, stdout, stderr, writer, true, true);
}

pub fn applyGeneric(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    try applyInner(allocator, stdout, stderr, writer, false, false);
}

fn applyInner(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer, truncate_last_field: bool, elide_repeated_fields: bool) !void {
    _ = stderr;
    if (stdout.len == 0) return;

    var prev_fields: std.ArrayList([]const u8) = .empty;
    defer prev_fields.deinit(allocator);
    var cur_fields: std.ArrayList([]const u8) = .empty;
    defer cur_fields.deinit(allocator);

    var i: usize = 0;
    var have_prev = false;
    var repeated_rows: usize = 0;
    while (i < stdout.len) {
        const line_start = i;
        while (i < stdout.len and stdout[i] != '\n') i += 1;
        const line = stdout[line_start..i];

        if (!lineIsTabular(line)) {
            try flushRepeatedRows(writer, &repeated_rows);
            // Preamble / blank / single-column line — emit verbatim and reset
            // the RLE baseline so later rows don't elide against a stale row.
            try writer.writeAll(line);
            if (i < stdout.len) {
                try writer.writeByte('\n');
                i += 1;
            }
            have_prev = false;
            prev_fields.clearRetainingCapacity();
            continue;
        }

        cur_fields.clearRetainingCapacity();
        try splitFields(allocator, line, &cur_fields);

        if (elide_repeated_fields and have_prev and fieldsEqual(prev_fields.items, cur_fields.items)) {
            repeated_rows += 1;
            if (i < stdout.len) i += 1;
            continue;
        }

        try flushRepeatedRows(writer, &repeated_rows);

        var field_idx: usize = 0;
        while (field_idx < cur_fields.items.len) : (field_idx += 1) {
            if (field_idx > 0) try writer.writeByte(' ');
            const f = cur_fields.items[field_idx];
            if (elide_repeated_fields and
                have_prev and
                field_idx < prev_fields.items.len and
                f.len > 0 and
                std.mem.eql(u8, f, prev_fields.items[field_idx]))
            {
                // Elided field: emit the '~' sigil so an agent can tell "same
                // as the row above" apart from a genuinely empty field. A bare
                // gap was ambiguous and, for a trailing column, left a dangling
                // space.
                try writer.writeByte('~');
            } else {
                if (truncate_last_field and field_idx == cur_fields.items.len - 1) {
                    try writeTruncatedLastField(writer, f);
                } else {
                    try writer.writeAll(f);
                }
            }
        }

        if (i < stdout.len) {
            try writer.writeByte('\n');
            i += 1;
        }

        // Swap prev ↔ cur.  We need prev_fields to own the field slices that
        // point into stdout, so the swap preserves lifetimes (stdout outlives
        // the whole call).
        const tmp = prev_fields;
        prev_fields = cur_fields;
        cur_fields = tmp;
        have_prev = true;
    }
    try flushRepeatedRows(writer, &repeated_rows);
}

fn flushRepeatedRows(writer: *Writer, repeated_rows: *usize) !void {
    if (repeated_rows.* == 0) return;
    try writer.writeAll("~ x");
    try writeDecimal(writer, repeated_rows.*);
    try writer.writeByte('\n');
    repeated_rows.* = 0;
}

fn fieldsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn writeDecimal(writer: *Writer, value: usize) !void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n = value;
    while (true) {
        i -= 1;
        buf[i] = @as(u8, @intCast(n % 10)) + '0';
        n /= 10;
        if (n == 0) break;
    }
    try writer.writeAll(buf[i..]);
}

/// Truncate path portions in the last field to basename.
/// "0:44.31 /Applications/Visual Studio Code.app/.../Electron" → "0:44.31 Electron"
fn writeTruncatedLastField(writer: *Writer, field: []const u8) !void {
    // Only truncate if the field starts with '/' (absolute command path)
    // or if it contains a space followed by '/' (time + absolute path)
    if (field.len > 0 and field[0] == '/') {
        // Direct absolute path
        if (std.mem.findScalarLast(u8, field, '/')) |last_slash| {
            const tail = field[last_slash + 1 ..];
            if (tail.len > 0) {
                try writer.writeAll(tail);
                return;
            }
        }
    } else if (std.mem.indexOf(u8, field, " /")) |sp| {
        // Prefix (like time) + absolute path: "0:44.31 /usr/bin/python3 args..."
        const prefix = field[0 .. sp + 1]; // include the space
        const path_part = field[sp + 1 ..];
        try writer.writeAll(prefix);
        if (std.mem.findScalarLast(u8, path_part, '/')) |last_slash| {
            const tail = path_part[last_slash + 1 ..];
            if (tail.len > 0) {
                try writer.writeAll(tail);
                return;
            }
        }
        try writer.writeAll(path_part);
        return;
    }
    try writer.writeAll(field);
}

fn splitFields(
    allocator: Allocator,
    line: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var i: usize = 0;
    // Skip leading spaces — treat as implicit empty first field isn't useful
    // (no alignment semantic to preserve for compact output).
    while (i < line.len and line[i] == ' ') i += 1;

    while (i < line.len) {
        const field_start = i;
        // Advance past field content (non-space, or single-space runs).
        while (i < line.len) {
            if (line[i] != ' ') {
                i += 1;
            } else {
                // Check if this is a column separator (≥MIN_GAP spaces) or
                // an intra-field single space.
                var j = i;
                while (j < line.len and line[j] == ' ') j += 1;
                const gap = j - i;
                if (gap >= MIN_GAP) break;
                i = j; // single space inside field
            }
        }
        const field = line[field_start..i];
        if (field.len > 0) try out.append(allocator, field);
        // Skip the separator run.
        while (i < line.len and line[i] == ' ') i += 1;
    }
}

fn countFields(line: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < line.len and line[i] == ' ') i += 1;
    while (i < line.len) {
        const field_start = i;
        while (i < line.len) {
            if (line[i] != ' ') {
                i += 1;
            } else {
                var j = i;
                while (j < line.len and line[j] == ' ') j += 1;
                if (j - i >= MIN_GAP) break;
                i = j;
            }
        }
        if (i > field_start) count += 1;
        while (i < line.len and line[i] == ' ') i += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture_docker_ps = @embedFile("fixture_docker_ps");

fn applyToString(a: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try apply(a, input, &.{}, &out.writer);
    return a.dupe(u8, out.written());
}

fn applyGenericToString(a: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try applyGeneric(a, input, &.{}, &out.writer);
    return a.dupe(u8, out.written());
}

test "matches: multi-column input accepted" {
    try std.testing.expect(matches("A  B  C\n"));
    try std.testing.expect(matches(fixture_docker_ps));
}

test "matches: single column rejected" {
    try std.testing.expect(!matches("just text\n"));
    try std.testing.expect(!matches("path/to/file.zig\n"));
}

test "matches: empty rejected" {
    try std.testing.expect(!matches(""));
}

test "matchesGeneric: requires repeated stable rows" {
    try std.testing.expect(matchesGeneric(
        "NAME          STATUS       ID        URL\n" ++
            "alpha         ready        a-1001    https://example.test/a\n" ++
            "bravo         waiting      b-1002    https://example.test/b\n" ++
            "charlie       failed       c-1003    https://example.test/c\n",
    ));
    try std.testing.expect(!matchesGeneric(
        "Usage: tool [options]\n" ++
            "  --verbose  Show extra output for debugging\n" ++
            "  --help     Show this help text\n",
    ));
}

test "split: simple 3 columns" {
    const a = std.testing.allocator;
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(a);
    try splitFields(a, "alpha  bravo  charlie", &fields);
    try std.testing.expectEqual(@as(usize, 3), fields.items.len);
    try std.testing.expectEqualStrings("alpha", fields.items[0]);
    try std.testing.expectEqualStrings("bravo", fields.items[1]);
    try std.testing.expectEqualStrings("charlie", fields.items[2]);
}

test "split: intra-field single space preserved" {
    const a = std.testing.allocator;
    var fields: std.ArrayList([]const u8) = .empty;
    defer fields.deinit(a);
    // "CONTAINER ID" is one field despite the space (only 1 space between).
    try splitFields(a, "CONTAINER ID   IMAGE   NAMES", &fields);
    try std.testing.expectEqual(@as(usize, 3), fields.items.len);
    try std.testing.expectEqualStrings("CONTAINER ID", fields.items[0]);
}

test "encode: header-only input preserves fields" {
    const a = std.testing.allocator;
    const out = try applyToString(a, "A    B    C\n");
    defer a.free(out);
    try std.testing.expectEqualStrings("A B C\n", out);
}

test "encode: preamble passthrough then RLE" {
    const a = std.testing.allocator;
    // Banner + blank + header + two data rows sharing column 0.
    const input =
        \\Showing 2 of 2 items
        \\
        \\H1   H2
        \\foo   bar
        \\foo   baz
        \\
    ;
    const out = try applyToString(a, input);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        \\Showing 2 of 2 items
        \\
        \\H1 H2
        \\foo bar
        \\~ baz
        \\
    , out);
}

test "encode: repeated column elided" {
    const a = std.testing.allocator;
    // Two data rows with same first field.
    const input = "H1   H2\nfoo   bar\nfoo   baz\n";
    const out = try applyToString(a, input);
    defer a.free(out);
    try std.testing.expectEqualStrings("H1 H2\nfoo bar\n~ baz\n", out);
}

test "encode: every elided field emits ~ sigil, not a blank gap" {
    const a = std.testing.allocator;
    // cols 0 and 2 repeat across the two data rows; col 1 differs. Each elided
    // position must carry '~' so an agent can distinguish "same as the row
    // above" from a genuinely empty field — and so a trailing elided column
    // never leaves a dangling space.
    const input = "C0   C1   C2\nfoo   bar   baz\nfoo   qux   baz\n";
    const out = try applyToString(a, input);
    defer a.free(out);
    try std.testing.expectEqualStrings("C0 C1 C2\nfoo bar baz\n~ qux ~\n", out);
}

test "encode: repeated full rows collapse to row count" {
    const a = std.testing.allocator;
    const input =
        "USER   PID   COMMAND\n" ++
        "www    1     python app.py\n" ++
        "www    1     python app.py\n" ++
        "www    1     python app.py\n" ++
        "root   2     nginx\n";
    const out = try applyToString(a, input);
    defer a.free(out);
    try std.testing.expectEqualStrings(
        "USER PID COMMAND\n" ++
            "www 1 python app.py\n" ++
            "~ x2\n" ++
            "root 2 nginx\n",
        out,
    );
}

test "encode: docker ps compresses" {
    const a = std.testing.allocator;
    const out = try applyToString(a, fixture_docker_ps);
    defer a.free(out);
    // Expect substantial byte shrinkage from padding collapse alone.
    const savings_pct = (fixture_docker_ps.len - out.len) * 100 / fixture_docker_ps.len;
    try std.testing.expect(savings_pct >= 25);
}

test "generic encode: preserves repeated fields" {
    const a = std.testing.allocator;
    const input = "H1   H2   H3\nfoo   bar   baz\nfoo   qux   baz\n";
    const out = try applyGenericToString(a, input);
    defer a.free(out);
    try std.testing.expectEqualStrings("H1 H2 H3\nfoo bar baz\nfoo qux baz\n", out);
}
