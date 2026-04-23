const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY columnar compaction — on by default (v0.6). Set
// SMLL_LOSSLESS=1 to bypass.
//
// Target: docker ps, docker images, kubectl get, gh pr list — any format where
// rows are whitespace-separated columns padded to visual width, and rows often
// share column values (e.g. identical image, identical status).
//
// Algorithm (one-way encode; decode is approximate and unused in product):
//   1. Parse each line into fields, splitting on runs of ≥2 spaces.
//   2. Rejoin fields with a single space (discards visual column alignment).
//   3. Per-column RLE: if row N's field[i] equals row N-1's field[i] (exact
//      byte match and field is non-empty), replace with SIGIL '~'.
//   4. Literal-sigil escape: if a field equals "~" in the input, the encoder
//      leaves it alone (it would collide with RLE, but as a one-way encode we
//      accept the decode ambiguity).  In practice tool columns don't contain a
//      literal '~' field.
//
// Contract:
//   • Byte content is altered (padding collapsed).  Not lossless.
//   • Semantic content (field values, row order) preserved.
//   • Measured token savings: 15% (docker ps), 26% (docker images).
//
// Not routed in default dispatch — the R3 lossless contract requires explicit
// user opt-in.

const SIGIL: u8 = '~';
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
    _ = stderr;
    if (stdout.len == 0) return;

    var prev_fields: std.ArrayList([]const u8) = .empty;
    defer prev_fields.deinit(allocator);
    var cur_fields: std.ArrayList([]const u8) = .empty;
    defer cur_fields.deinit(allocator);

    var i: usize = 0;
    var have_prev = false;
    while (i < stdout.len) {
        const line_start = i;
        while (i < stdout.len and stdout[i] != '\n') i += 1;
        const line = stdout[line_start..i];

        if (!lineIsTabular(line)) {
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

        var field_idx: usize = 0;
        while (field_idx < cur_fields.items.len) : (field_idx += 1) {
            if (field_idx > 0) try writer.writeByte(' ');
            const f = cur_fields.items[field_idx];
            if (have_prev and
                field_idx < prev_fields.items.len and
                f.len > 0 and
                std.mem.eql(u8, f, prev_fields.items[field_idx]))
            {
                try writer.writeByte(SIGIL);
            } else {
                try writer.writeAll(f);
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

test "encode: docker ps compresses" {
    const a = std.testing.allocator;
    const out = try applyToString(a, fixture_docker_ps);
    defer a.free(out);
    // Expect substantial byte shrinkage from padding collapse alone.
    const savings_pct = (fixture_docker_ps.len - out.len) * 100 / fixture_docker_ps.len;
    try std.testing.expect(savings_pct >= 25);
}
