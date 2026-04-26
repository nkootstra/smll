const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `pytest` — on by default (v0.6). Set
// SMLL_LOSSLESS=1 to bypass.
//
// Keeps: FAILED/ERROR markers, assertion context, short test summary, session totals.
// Drops: platform banner, plugin list, rootdir, configfile, passing progress dots,
// cachedir, ANSI escapes.
//
// If no failures kept, emits "all tests passed\n".
//
// Detection: first 200 lines contain "test session starts" or "collected " or
// a "passed" / "failed" summary line framed by "=" separators.

const KEEP_NEEDLES = [_][]const u8{
    "FAILED",
    "ERROR",
    "failed",
    "error",
    "assert",
    "collected",
    "short test summary",
    "==== ",
    ">   ",
    "E   ",
};

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "test session starts") != null) return true;
    // "collected N item" — must have digits before "item" to avoid
    // false positives on pip's "Installing collected packages:".
    if (std.mem.find(u8, input, "collected ") != null) {
        var it = std.mem.splitScalar(u8, input, '\n');
        while (it.next()) |line| {
            if (std.mem.find(u8, line, "collected ") != null and
                std.mem.find(u8, line, " item") != null) return true;
        }
    }
    // Trailing summary like "====== 1 failed, 4 passed in 0.12s ======"
    if (std.mem.find(u8, input, "passed in ") != null) return true;
    if (std.mem.find(u8, input, "failed in ") != null) return true;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);

    var kept_lines: usize = 0;
    try scanAndKeep(allocator, stdout, &scratch, &kept_lines);
    try scanAndKeep(allocator, stderr, &scratch, &kept_lines);

    // Pytest's passing-run summary has "failed" nowhere but still has "error" in
    // phrases like "no tests ran" — we distinguish by checking if any actual
    // failure marker was kept.
    if (kept_lines == 0 or !hasFailureMarker(scratch.items)) {
        try writer.writeAll("all tests passed\n");
        return;
    }
    try writer.writeAll(scratch.items);
}

fn hasFailureMarker(s: []const u8) bool {
    if (std.mem.find(u8, s, "FAILED") != null) return true;
    if (std.mem.find(u8, s, "ERROR") != null) return true;
    // Summary line with count: " N failed" where N >= 1.
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        const idx = std.mem.find(u8, line, "failed") orelse continue;
        // Look backwards for " N failed" where N is a digit.
        if (idx < 2) continue;
        var j = idx - 1;
        if (line[j] != ' ') continue;
        if (j == 0) continue;
        j -= 1;
        if (!std.ascii.isDigit(line[j])) continue;
        // Found digit-space-failed; now ensure digit isn't "0".
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
    const head_cap: usize = 200;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    // Sticky context: after a FAILED/ERROR line, keep subsequent lines
    // (tracebacks, assertions, file paths) until we hit a blank line or
    // a non-indented non-error line.
    var in_error_context = false;
    while (lines.next()) |raw| {
        if (kept.* >= head_cap) break;
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            if (in_error_context) {
                in_error_context = false;
            }
            continue;
        }
        if (shouldKeep(trimmed)) {
            in_error_context = true;
            const stripped = std.mem.trim(u8, trimmed, "= ");
            if (stripped.len > 0) {
                try out.appendSlice(allocator, stripped);
            } else {
                try out.appendSlice(allocator, trimmed);
            }
            try out.append(allocator, '\n');
            kept.* += 1;
            continue;
        }
        // Keep traceback context: indented lines, file paths, assertion details.
        if (in_error_context) {
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            kept.* += 1;
            continue;
        }
    }
}

fn shouldKeep(line: []const u8) bool {
    for (KEEP_NEEDLES) |n| {
        if (std.mem.find(u8, line, n) != null) return true;
    }
    return false;
}

test "matches: session start" {
    try std.testing.expect(matches("============ test session starts ============\n"));
}

test "matches: collected" {
    try std.testing.expect(matches("collected 5 items\n\ntests/test_x.py .....\n"));
}

test "matches: passed summary" {
    try std.testing.expect(matches("==== 5 passed in 0.12s ====\n"));
}

test "matches: rejects non-pytest" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello\n"));
}

test "apply: all passing emits 'all tests passed'" {
    const input =
        \\============ test session starts ============
        \\platform darwin -- Python 3.12.0
        \\collected 3 items
        \\
        \\tests/test_a.py ...                        [100%]
        \\
        \\==================== 3 passed in 0.10s ====================
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("all tests passed\n", out.written());
}

test "apply: keeps failure context" {
    const input =
        \\============ test session starts ============
        \\collected 2 items
        \\
        \\tests/test_a.py .F                         [100%]
        \\
        \\================== FAILURES ==================
        \\______ test_b ______
        \\
        \\    def test_b():
        \\>       assert False
        \\E       assert False
        \\
        \\tests/test_a.py:5: AssertionError
        \\==================== short test summary info ====================
        \\FAILED tests/test_a.py::test_b - assert False
        \\==================== 1 failed, 1 passed in 0.12s ====================
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "FAILED") != null);
    try std.testing.expect(std.mem.find(u8, got, "short test summary") != null);
    try std.testing.expect(std.mem.find(u8, got, "1 failed, 1 passed") != null);
    try std.testing.expect(std.mem.find(u8, got, "assert False") != null);
    // Platform banner dropped.
    try std.testing.expect(std.mem.find(u8, got, "platform darwin") == null);
}

test "apply: strips ANSI from kept lines" {
    const input = "collected 1 item\n\x1b[31mFAILED\x1b[0m tests/x.py::t\n1 failed in 0.1s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "FAILED") != null);
}
