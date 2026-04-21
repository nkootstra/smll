const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// Opt-in LOSSY compact filter for `jest` / `vitest` (SMLL_COMPACT=1).
//
// Keeps: FAIL-prefix file lines, `● ` failure titles, expect/assertion bodies,
//        Error messages, stack frames (`at `), Test Suites:/Tests:/Test Files/
//        Tests ✗/✕/Failed summaries.
// Drops: `PASS ` prefix lines, passing `✓` markers, Snapshots:/Time:/Ran lines.
//
// If no failures kept, emits "all tests passed\n".
//
// Detection: "Test Suites:" or "Tests:" or "Test Files" or first FAIL/PASS line.

const KEEP_NEEDLES = [_][]const u8{
    "FAIL ",
    "FAIL\t",
    "● ",
    "Expected:",
    "Received:",
    "expect(",
    "Error:",
    "    at ",
    "Test Suites:",
    "Tests:",
    "Test Files",
    "✗ ",
    "✕ ",
    " failed",
    "Failed",
    "    > ",
    ">   ",
    "E   ",
};

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "Test Suites:") != null) return true;
    if (std.mem.find(u8, input, "Test Files") != null) return true;
    // Vitest / jest "Tests:" summary line
    if (std.mem.find(u8, input, "\nTests:") != null) return true;
    if (std.mem.startsWith(u8, input, "Tests:")) return true;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);

    var kept_lines: usize = 0;
    try scanAndKeep(allocator, stdout, &scratch, &kept_lines);
    try scanAndKeep(allocator, stderr, &scratch, &kept_lines);

    if (kept_lines == 0 or !hasFailureMarker(scratch.items)) {
        try writer.writeAll("all tests passed\n");
        return;
    }
    try writer.writeAll(scratch.items);
}

fn hasFailureMarker(s: []const u8) bool {
    if (std.mem.find(u8, s, "FAIL") != null) return true;
    if (std.mem.find(u8, s, "●") != null) return true;
    // "Tests:  N failed" with N >= 1
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        const idx = std.mem.find(u8, line, "failed") orelse continue;
        if (idx < 2) continue;
        var j = idx - 1;
        if (line[j] != ' ') continue;
        if (j == 0) continue;
        j -= 1;
        if (!std.ascii.isDigit(line[j])) continue;
        var start = j;
        while (start > 0 and std.ascii.isDigit(line[start - 1])) start -= 1;
        const num = line[start .. j + 1];
        if (!std.mem.eql(u8, num, "0")) return true;
    }
    return false;
}

fn scanAndKeep(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), kept: *usize) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    const head_cap: usize = 80;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    while (lines.next()) |raw| {
        if (kept.* >= head_cap) break;
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        // Explicit drops (PASS-only noise).
        if (std.mem.startsWith(u8, trimmed, "PASS ")) continue;
        if (std.mem.startsWith(u8, trimmed, "PASS\t")) continue;
        if (std.mem.startsWith(u8, trimmed, "✓ ")) continue;
        if (std.mem.startsWith(u8, trimmed, "Snapshots:")) continue;
        if (std.mem.startsWith(u8, trimmed, "Time:")) continue;
        if (std.mem.startsWith(u8, trimmed, "Ran all")) continue;
        if (!shouldKeep(trimmed)) continue;
        try out.appendSlice(allocator, trimmed);
        try out.append(allocator, '\n');
        kept.* += 1;
    }
}

fn shouldKeep(line: []const u8) bool {
    for (KEEP_NEEDLES) |n| {
        if (std.mem.find(u8, line, n) != null) return true;
    }
    return false;
}

test "matches: Test Suites summary" {
    try std.testing.expect(matches("PASS src/a.test.ts\nTest Suites: 1 passed\n"));
}

test "matches: vitest Test Files summary" {
    try std.testing.expect(matches(" Test Files  1 failed (1)\n"));
}

test "matches: rejects non-jest" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("running 3 tests\n"));
}

test "apply: fixture drops PASS, keeps failures" {
    const input = @embedFile("fixture_jest_failing");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "FAIL  src/components/Button.test.tsx") != null);
    try std.testing.expect(std.mem.find(u8, got, "● Button component") != null);
    try std.testing.expect(std.mem.find(u8, got, "Expected: \"Submit\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "Received: \"submit\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "Test Suites: 2 failed") != null);
    // PASS lines dropped.
    try std.testing.expect(std.mem.find(u8, got, "PASS  src/utils/format.test.ts") == null);
    try std.testing.expect(std.mem.find(u8, got, "PASS  src/hooks/useAuth.test.ts") == null);
    // Time/Ran lines dropped.
    try std.testing.expect(std.mem.find(u8, got, "Time:") == null);
    try std.testing.expect(std.mem.find(u8, got, "Ran all") == null);
}

test "apply: all passing emits 'all tests passed'" {
    const input =
        \\PASS  src/a.test.ts
        \\PASS  src/b.test.ts
        \\Test Suites: 2 passed, 2 total
        \\Tests:       12 passed, 12 total
        \\Snapshots:   0 total
        \\Time:        1.2 s
        \\Ran all test suites.
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("all tests passed\n", out.written());
}

test "apply: strips ANSI" {
    const input = "\x1b[31mFAIL \x1b[0msrc/x.test.ts\n● x › y\nTest Suites: 1 failed\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "FAIL src/x.test.ts") != null);
}
