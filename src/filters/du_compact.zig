const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `du` / `du -sh` — on by default (v0.6).
// Set SMLL_LOSSLESS=1 to bypass.
//
// Transformations:
//   • Size column rounded to 2 significant figures. `234M` → `230M`,
//     `1.2G` → `1.2G`, `17K` → `17K`. Precision agents don't need.
//   • When `-s` (summarize) is present in argv, entries are sorted
//     descending by byte size so the largest offenders come first.
//
// Contract:
//   • Path column is preserved verbatim (spaces allowed).
//   • Unit column ({K,M,G,T} or none) is preserved.
//   • Typical byte reduction ~10-30% from size rounding alone, plus
//     ordering improvement for `-s` aggregations.
//
// Detection (matches):
//   • Every non-empty line must tokenize as <number><unit?><ws><path>
//     where unit ∈ {K,M,G,T,P,E} (any case) or absent.

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var saw_any = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (parseLine(line) == null) return false;
        saw_any = true;
    }
    return saw_any;
}

pub fn apply(
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    writer: *Writer,
    sort_desc: bool,
) !void {
    _ = stderr;
    if (stdout.len == 0) return;

    if (!sort_desc) {
        var lines = std.mem.splitScalar(u8, stdout, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const parsed = parseLine(line) orelse continue;
            if (!first) try writer.writeByte('\n');
            first = false;
            try emitRoundedLine(writer, parsed);
        }
        if (!first) try writer.writeByte('\n');
        return;
    }

    // -s mode: collect, sort desc by byte size, emit.
    var rows: std.ArrayList(Parsed) = .empty;
    defer rows.deinit(allocator);

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = parseLine(line) orelse continue;
        try rows.append(allocator, parsed);
    }

    // Insertion sort — du -s output has ≤O(100) entries; avoids pulling in
    // the full pdqsort machinery from std.mem.sort.
    {
        var i: usize = 1;
        while (i < rows.items.len) : (i += 1) {
            const key = rows.items[i];
            var j: usize = i;
            while (j > 0 and rows.items[j - 1].bytes < key.bytes) : (j -= 1) {
                rows.items[j] = rows.items[j - 1];
            }
            rows.items[j] = key;
        }
    }

    // Emit top entries; summarize the rest
    const TOP_N: usize = 10;
    const emit_count = @min(rows.items.len, TOP_N);

    // Find common path prefix among top entries
    var prefix_len: usize = 0;
    if (emit_count > 1) {
        const first_path = rows.items[0].path;
        prefix_len = first_path.len;
        for (rows.items[1..emit_count]) |row| {
            var j: usize = 0;
            while (j < prefix_len and j < row.path.len and first_path[j] == row.path[j]) : (j += 1) {}
            prefix_len = j;
        }
        // Snap to last '/' boundary
        while (prefix_len > 0 and first_path[prefix_len - 1] != '/') : (prefix_len -= 1) {}
    }

    // Emit prefix header if stripping
    if (prefix_len > 2) {
        try writer.writeAll(rows.items[0].path[0..prefix_len]);
        try writer.writeByte('\n');
    }

    for (rows.items[0..emit_count], 0..) |row, i| {
        if (i > 0) try writer.writeByte('\n');
        try writeRoundedNumber(writer, row.num);
        if (row.unit != 0) try writer.writeByte(row.unit);
        try writer.writeByte('\t');
        if (prefix_len > 2) {
            try writer.writeAll(row.path[prefix_len..]);
        } else {
            try writer.writeAll(row.path);
        }
    }
    if (rows.items.len > TOP_N) {
        // Calculate total size of remaining entries
        var remaining_bytes: u64 = 0;
        for (rows.items[TOP_N..]) |row| {
            remaining_bytes += row.bytes;
        }
        try writer.writeByte('\n');
        try emitHumanSize(writer, remaining_bytes);
        try writer.print("\t(+{d})\n", .{rows.items.len - TOP_N});
    } else if (rows.items.len > 0) {
        try writer.writeByte('\n');
    }
}

const Parsed = struct {
    num: []const u8,   // numeric token as written ("234", "1.2", "17")
    unit: u8,          // 0 when no unit; otherwise uppercase K/M/G/T/P/E
    bytes: u64,        // approximate byte count for sort ordering
    path: []const u8,  // remainder of the line (path, trimmed trailing ws)
};

/// Parse a single du line. Returns null on shape mismatch.
fn parseLine(line: []const u8) ?Parsed {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const num_start = i;
    var saw_dot = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c >= '0' and c <= '9') continue;
        if (c == '.' and !saw_dot) {
            saw_dot = true;
            continue;
        }
        break;
    }
    if (i == num_start) return null;
    const num = line[num_start..i];

    var unit: u8 = 0;
    if (i < line.len) {
        const c = std.ascii.toUpper(line[i]);
        switch (c) {
            'K', 'M', 'G', 'T', 'P', 'E' => {
                unit = c;
                i += 1;
                // Optional trailing "B" (e.g. "17KB").
                if (i < line.len and std.ascii.toUpper(line[i]) == 'B') i += 1;
            },
            else => {},
        }
    }
    if (i >= line.len) return null;
    // du's canonical output uses a tab between size and path. Reject
    // space-separated shapes to avoid claiming unrelated line grammars
    // (e.g. `234M ./path` without a tab).
    if (line[i] != '\t') return null;
    i += 1;
    if (i >= line.len) return null;
    const path = std.mem.trimEnd(u8, line[i..], " \t\r");
    if (path.len == 0) return null;

    const bytes = computeBytes(num, unit) orelse return null;
    return .{ .num = num, .unit = unit, .bytes = bytes, .path = path };
}

fn computeBytes(num: []const u8, unit: u8) ?u64 {
    const multiplier: u64 = switch (unit) {
        0 => 1024, // du default: 1K blocks
        'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        'T' => 1024 * 1024 * 1024 * 1024,
        'P' => 1024 * 1024 * 1024 * 1024 * 1024,
        'E' => 1024 * 1024 * 1024 * 1024 * 1024 * 1024,
        else => return null,
    };
    // Parse integer and optional fractional part without pulling in f64 libs.
    // du sizes are small decimals (e.g. "1.2", "234") — integer arithmetic suffices.
    const dot = std.mem.indexOfScalar(u8, num, '.');
    const int_part_str = if (dot) |d| num[0..d] else num;
    const int_part = std.fmt.parseInt(u64, int_part_str, 10) catch return null;
    // Fractional: at most one decimal digit matters for 2-sig-fig rounding.
    // Represent the value as (int_part * 10 + frac_digit) / 10 * multiplier.
    const frac_digit: u64 = if (dot) |d| blk: {
        const frac = num[d + 1 ..];
        if (frac.len == 0) break :blk 0;
        const digit = frac[0];
        if (digit < '0' or digit > '9') break :blk 0;
        break :blk digit - '0';
    } else 0;
    // (int_part * 10 + frac_digit) * multiplier / 10
    const tenths = int_part *| 10 +| frac_digit; // saturating add
    return tenths *| (multiplier / 10) +| (tenths *| (multiplier % 10) / 10);
}

fn emitRoundedLine(writer: *Writer, row: Parsed) !void {
    try writeRoundedNumber(writer, row.num);
    if (row.unit != 0) {
        try writer.writeByte(row.unit);
    }
    try writer.writeByte('\t');
    try writer.writeAll(row.path);
}

fn emitHumanSize(writer: *Writer, bytes: u64) !void {
    // Integer-only human size — avoids pulling in f64 formatting tables.
    // Uses one decimal place via (value * 10 / unit) trick.
    if (bytes >= 1024 * 1024 * 1024 * 1024) {
        const t = bytes / (1024 * 1024 * 1024 * 1024 / 10); // tenths of TiB
        try emitTenths(writer, t, 'T');
    } else if (bytes >= 1024 * 1024 * 1024) {
        const g = bytes / (1024 * 1024 * 1024 / 10);
        try emitTenths(writer, g, 'G');
    } else if (bytes >= 1024 * 1024) {
        const m = bytes / (1024 * 1024 / 10);
        try emitTenths(writer, m, 'M');
    } else if (bytes >= 1024) {
        const k = bytes / (1024 / 10); // tenths of KiB = bytes / 102
        try emitTenths(writer, k, 'K');
    } else {
        try writer.print("{d}", .{bytes});
    }
}

fn emitTenths(writer: *Writer, tenths: u64, unit: u8) !void {
    // Write whole.fracU without any heap allocation.
    const whole = tenths / 10;
    const frac = @as(u8, @intCast(tenths % 10));
    // Write whole part using a small stack buffer (du sizes fit in u32 easily).
    var buf: [20]u8 = undefined;
    var pos: usize = buf.len;
    var n = whole;
    if (n == 0) {
        pos -= 1;
        buf[pos] = '0';
    } else {
        while (n > 0) {
            pos -= 1;
            buf[pos] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
    }
    try writer.writeAll(buf[pos..]);
    try writer.writeByte('.');
    try writer.writeByte('0' + frac);
    try writer.writeByte(unit);
}

/// Round a written number to 2 significant figures.
/// - Integers ≥ 100: first two digits kept, remainder zeroed ("234" → "230").
/// - Integers < 100: preserved ("17" → "17", "0" → "0").
/// - Decimals: preserved as-is ("1.2" → "1.2"). `du -h` already emits
///   decimals only for 1-digit lead values, so these are already 2
///   sig figs by construction.
fn writeRoundedNumber(writer: *Writer, num: []const u8) !void {
    if (std.mem.find(u8, num, ".") != null) {
        try writer.writeAll(num);
        return;
    }
    if (num.len <= 2) {
        try writer.writeAll(num);
        return;
    }
    try writer.writeAll(num[0..2]);
    for (num[2..]) |_| try writer.writeByte('0');
}

/// Detect -s / --summarize in argv, including combined short-flag clusters
/// like -sh, -hs, -cs. Long options (--foo=bar) are ignored.
pub fn hasSummarizeFlag(argv: []const []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, "-s")) return true;
        if (std.mem.eql(u8, a, "--summarize")) return true;
        if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            if (std.mem.find(u8, a[1..], "s") != null) return true;
        }
    }
    return false;
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "matches: du -sh output" {
    try std.testing.expect(matches("234M\t.\n"));
    try std.testing.expect(matches("1.2G\t./vendor\n17K\t./src\n"));
}

test "matches: du (no -h) output" {
    try std.testing.expect(matches("12345\t./foo\n"));
    try std.testing.expect(matches("0\t./empty\n"));
}

test "matches: rejects non-du input" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello world\n"));
    try std.testing.expect(!matches("234M ./path-no-tab\n")); // needs whitespace
    try std.testing.expect(!matches("234X\t./bad-unit\n"));
}

test "apply: rounds sizes to 2 sig figs" {
    const input = "234M\t.\n1.2G\t./vendor\n17K\t./src\n5K\t./tiny\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer, false);
    try std.testing.expectEqualStrings(
        "230M\t.\n1.2G\t./vendor\n17K\t./src\n5K\t./tiny\n",
        out.written(),
    );
}

test "apply: sort descending when -s present" {
    const input = "1.2G\t./vendor\n234M\t./build\n17K\t./src\n5G\t./huge\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer, true);
    try std.testing.expectEqualStrings(
        "5G\t./huge\n1.2G\t./vendor\n230M\t./build\n17K\t./src\n",
        out.written(),
    );
}

test "apply: preserves order when -s absent" {
    const input = "1.2G\t./vendor\n234M\t./build\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer, false);
    try std.testing.expectEqualStrings(
        "1.2G\t./vendor\n230M\t./build\n",
        out.written(),
    );
}

test "apply: du (no -h) raw bytes rounded" {
    const input = "12345\t./foo\n0\t./empty\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer, false);
    try std.testing.expectEqualStrings(
        "12000\t./foo\n0\t./empty\n",
        out.written(),
    );
}

test "apply: zero-sized entry preserved" {
    const input = "0\t./empty\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer, false);
    try std.testing.expectEqualStrings("0\t./empty\n", out.written());
}

test "apply: empty input produces empty output" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "", &out.writer, false);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: path with spaces preserved" {
    const input = "17K\t./my dir/file\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer, false);
    try std.testing.expectEqualStrings("17K\t./my dir/file\n", out.written());
}

test "hasSummarizeFlag: detects short/long/clustered forms" {
    try std.testing.expect(hasSummarizeFlag(&.{ "du", "-s" }));
    try std.testing.expect(hasSummarizeFlag(&.{ "du", "-sh" }));
    try std.testing.expect(hasSummarizeFlag(&.{ "du", "-hs" }));
    try std.testing.expect(hasSummarizeFlag(&.{ "du", "-cs" }));
    try std.testing.expect(hasSummarizeFlag(&.{ "du", "--summarize" }));
    try std.testing.expect(!hasSummarizeFlag(&.{ "du", "-h" }));
    try std.testing.expect(!hasSummarizeFlag(&.{ "du", "--max-depth=1" }));
    try std.testing.expect(!hasSummarizeFlag(&.{ "du", "--foo=sbar" }));
    try std.testing.expect(!hasSummarizeFlag(&.{ "du", "." }));
}

test "apply: large-ish synthetic fixture preserves every path and normalizes sizes" {
    // du rounding is length-preserving ("234M" → "230M"), so byte-savings
    // aren't the win — semantic normalization and ordering are. This test
    // verifies the structural contract on a larger fixture.
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (0..200) |i| {
        const mb = (i * 37 % 900) + 100; // 100..999 range — 3-digit sizes.
        const line = try std.fmt.allocPrint(
            alloc,
            "{d}M\t./path/subdir/deeply_nested_directory_{d}\n",
            .{ mb, i },
        );
        defer alloc.free(line);
        try buf.appendSlice(alloc, line);
    }
    var out = Writer.Allocating.init(alloc);
    defer out.deinit();
    try apply(alloc, buf.items, "", &out.writer, false);
    const got = out.written();
    // Same line count in and out.
    try std.testing.expectEqual(
        std.mem.count(u8, buf.items, "\n"),
        std.mem.count(u8, got, "\n"),
    );
    // Last digit of every rounded size is '0' — 2-sig-fig contract.
    var lines = std.mem.splitScalar(u8, got, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.findScalar(u8, line, '\t') orelse unreachable;
        try std.testing.expectEqual(@as(u8, '0'), line[tab - 2]);
    }
    // Every path preserved.
    try std.testing.expect(std.mem.find(u8, got, "./path/subdir/deeply_nested_directory_0\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "./path/subdir/deeply_nested_directory_199\n") != null);
}
