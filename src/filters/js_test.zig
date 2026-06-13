const std = @import("std");
const ansi = @import("ansi");
const signals = @import("signals");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for Mocha and node:test output. It drops passing test
// chatter while preserving failure blocks and count summaries.

pub fn sigGate(s: signals.Signals) bool {
    return s.jsTest();
}

pub fn matches(input: []const u8) bool {
    return matchesMocha(input) or matchesNodeTest(input);
}

fn matchesMocha(input: []const u8) bool {
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (isNumberSummary(trimmed, " passing") or isNumberSummary(trimmed, " failing")) return true;
    }
    return false;
}

fn matchesNodeTest(input: []const u8) bool {
    var has_tests = false;
    var has_result = false;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "# tests ")) has_tests = true;
        if (std.mem.startsWith(u8, trimmed, "# fail ") or
            std.mem.startsWith(u8, trimmed, "# pass ") or
            std.mem.startsWith(u8, trimmed, "not ok ") or
            startsWithUnicodeFail(trimmed))
        {
            has_result = true;
        }
    }
    return has_tests and has_result;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    switch (detectMode(stdout, stderr) orelse .mocha) {
        .mocha => {
            var state = MochaState{};
            try scanMocha(allocator, stdout, &out, &state);
            try scanMocha(allocator, stderr, &out, &state);
        },
        .node_test => {
            var state = NodeState{};
            try scanNodeTest(allocator, stdout, &out, &state);
            try scanNodeTest(allocator, stderr, &out, &state);
        },
    }

    if (out.items.len == 0) {
        try writer.writeAll("all tests passed\n");
        return;
    }
    try writer.writeAll(out.items);
}

const Mode = enum { mocha, node_test };

const MochaState = struct {
    in_failure: bool = false,
};

const NodeState = struct {
    in_failure: bool = false,
    skipping_pass: bool = false,
};

fn detectMode(stdout: []const u8, stderr: []const u8) ?Mode {
    if (matchesNodeTest(stdout) or matchesNodeTest(stderr)) return .node_test;
    if (matchesMocha(stdout) or matchesMocha(stderr)) return .mocha;
    return null;
}

fn scanMocha(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), state: *MochaState) !void {
    if (input.len == 0) return;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    const trimmed_input = if (input[input.len - 1] == '\n') input[0 .. input.len - 1] else input;
    if (trimmed_input.len == 0) return;

    var lines = std.mem.splitScalar(u8, trimmed_input, '\n');
    while (lines.next()) |raw| {
        const stripped = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = trimRight(stripped);
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (startsWithUnicodePass(trimmed)) {
            continue;
        }

        if (isMochaSummary(trimmed)) {
            state.in_failure = false;
            try appendLine(allocator, out, trimmed);
            continue;
        }

        if (isMochaFailureHeader(trimmed)) {
            state.in_failure = true;
            try appendLine(allocator, out, trimmed);
            continue;
        }

        if (state.in_failure) {
            try appendLine(allocator, out, line);
        }
    }

    state.in_failure = false;
}

fn scanNodeTest(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), state: *NodeState) !void {
    if (input.len == 0) return;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    const trimmed_input = if (input[input.len - 1] == '\n') input[0 .. input.len - 1] else input;
    if (trimmed_input.len == 0) return;

    var lines = std.mem.splitScalar(u8, trimmed_input, '\n');
    while (lines.next()) |raw| {
        const stripped = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = trimRight(stripped);
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (state.skipping_pass) {
            if (std.mem.eql(u8, trimmed, "...")) state.skipping_pass = false;
            continue;
        }

        if (startsWithUnicodePass(trimmed)) {
            continue;
        }

        if (isNodePassLine(trimmed)) {
            state.skipping_pass = true;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "TAP version ")) {
            continue;
        }

        if (isNodeTrailer(trimmed)) {
            state.in_failure = false;
            try appendLine(allocator, out, trimmed);
            continue;
        }

        if (isNodeFailureHeader(trimmed)) {
            state.in_failure = true;
            try appendLine(allocator, out, trimmed);
            continue;
        }

        if (state.in_failure) {
            try appendLine(allocator, out, line);
            if (std.mem.eql(u8, trimmed, "...")) state.in_failure = false;
        }
    }

    state.in_failure = false;
    state.skipping_pass = false;
}

fn appendLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn trimRight(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t' or line[end - 1] == '\r')) end -= 1;
    return line[0..end];
}

fn isMochaSummary(line: []const u8) bool {
    return isNumberSummary(line, " passing") or isNumberSummary(line, " failing");
}

fn isNumberSummary(line: []const u8, marker: []const u8) bool {
    const idx = std.mem.indexOf(u8, line, marker) orelse return false;
    if (idx == 0) return false;
    for (line[0..idx]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    const after = line[idx + marker.len ..];
    return after.len == 0 or (after.len >= 2 and after[0] == ' ' and after[1] == '(');
}

fn isMochaFailureHeader(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    return i > 0 and i + 1 < line.len and line[i] == ')' and line[i + 1] == ' ';
}

fn isNodePassLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "ok ");
}

fn isNodeFailureHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "not ok ") or startsWithUnicodeFail(line);
}

fn isNodeTrailer(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "1..")) return true;
    return std.mem.startsWith(u8, line, "# tests ") or
        std.mem.startsWith(u8, line, "# suites ") or
        std.mem.startsWith(u8, line, "# pass ") or
        std.mem.startsWith(u8, line, "# fail ") or
        std.mem.startsWith(u8, line, "# cancelled ") or
        std.mem.startsWith(u8, line, "# skipped ") or
        std.mem.startsWith(u8, line, "# todo ") or
        std.mem.startsWith(u8, line, "# duration_ms ");
}

fn startsWithUnicodePass(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "✔ ") or std.mem.startsWith(u8, line, "✓ ");
}

fn startsWithUnicodeFail(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "✖ ") or std.mem.startsWith(u8, line, "✕ ");
}

test "matches: mocha summary" {
    try std.testing.expect(matches("  1 passing (4ms)\n  1 failing\n"));
}

test "matches: node test summary" {
    try std.testing.expect(matches("# tests 2\n# pass 1\n# fail 1\n"));
}

test "matches: rejects unrelated text" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("# failover started\n"));
    try std.testing.expect(!matches("1 passing thought\n"));
}

test "apply: mocha fixture drops passing line and keeps failure block" {
    const input = @embedFile("fixture_mocha_failing");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "1 passing (4ms)") != null);
    try std.testing.expect(std.mem.find(u8, got, "1 failing") != null);
    try std.testing.expect(std.mem.find(u8, got, "AssertionError [ERR_ASSERTION]") != null);
    try std.testing.expect(std.mem.find(u8, got, "adds numbers") == null);
}

test "apply: node fixture drops ok block and keeps failing TAP diagnostics" {
    const input = @embedFile("fixture_node_test_failing");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "not ok 2 - divides by zero") != null);
    try std.testing.expect(std.mem.find(u8, got, "ERR_ASSERTION") != null);
    try std.testing.expect(std.mem.find(u8, got, "# tests 2") != null);
    try std.testing.expect(std.mem.find(u8, got, "# fail 1") != null);
    try std.testing.expect(std.mem.find(u8, got, "ok 1 - adds numbers") == null);
}

test "apply: mocha mode does not let ok status lines swallow summaries" {
    const input =
        \\ok - build step started
        \\  1 passing
        \\  1 failing
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings("1 passing\n1 failing\n", out.written());
}

test "apply: mocha failure state resets before stderr chatter" {
    const stderr =
        \\ExperimentalWarning: noisy warning after tests
        \\tool wrapper footer
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, @embedFile("fixture_mocha_failing"), stderr, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "AssertionError [ERR_ASSERTION]") != null);
    try std.testing.expect(std.mem.find(u8, got, "ExperimentalWarning") == null);
    try std.testing.expect(std.mem.find(u8, got, "tool wrapper footer") == null);
}
