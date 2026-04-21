const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// Opt-in LOSSY compact filter for `go test -v` (SMLL_COMPACT=1).
//
// Keeps: `--- FAIL:` lines, error context under a FAIL, `FAIL`/`ok` package
//        summary, final `exit status` + `PASS`/`FAIL` marker.
// Drops: `--- PASS:` per-test output, `=== RUN` markers (passing), blank-line
//        padding between passing tests.
//
// If no failures kept, emits "all tests passed\n".
//
// Detection: stdout contains "=== RUN" or "--- FAIL:" or "--- PASS:" or
//            "FAIL\t" / "ok  \t" package lines.

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "=== RUN") != null) return true;
    if (std.mem.find(u8, input, "--- FAIL:") != null) return true;
    if (std.mem.find(u8, input, "--- PASS:") != null) return true;
    // Package summary lines
    if (std.mem.find(u8, input, "\nok  \t") != null) return true;
    if (std.mem.startsWith(u8, input, "ok  \t")) return true;
    if (std.mem.find(u8, input, "\nFAIL\t") != null) return true;
    if (std.mem.startsWith(u8, input, "FAIL\t")) return true;
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
    if (std.mem.find(u8, s, "--- FAIL:") != null) return true;
    if (std.mem.find(u8, s, "FAIL\t") != null) return true;
    if (std.mem.startsWith(u8, s, "FAIL\n")) return true;
    // "FAIL" on its own line (package-level)
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "FAIL")) return true;
    }
    return false;
}

// In Go, indented error lines precede the `--- FAIL:` marker:
//
//     === RUN   TestDivide
//         math_test.go:42: boom          <-- indented error lines
//     --- FAIL: TestDivide (0.00s)        <-- outcome marker
//
// So we accumulate lines between `=== RUN` and the next `--- RESULT:` in a
// per-test buffer, then either flush (on FAIL) or discard (on PASS/SKIP).
fn scanAndKeep(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), kept: *usize) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    const head_cap: usize = 80;
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    while (lines.next()) |raw| {
        if (kept.* >= head_cap) break;
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // --- FAIL: flush pending buffer (test output) then the marker.
        if (std.mem.startsWith(u8, trimmed, "--- FAIL:")) {
            try out.appendSlice(allocator, pending.items);
            pending.clearRetainingCapacity();
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            kept.* += 1;
            continue;
        }
        // --- PASS: / --- SKIP: discard pending output (test passed, noise).
        if (std.mem.startsWith(u8, trimmed, "--- PASS:") or
            std.mem.startsWith(u8, trimmed, "--- SKIP:"))
        {
            pending.clearRetainingCapacity();
            continue;
        }
        // === RUN / === PAUSE / === CONT: reset pending buffer.
        if (std.mem.startsWith(u8, trimmed, "=== ")) {
            pending.clearRetainingCapacity();
            continue;
        }

        // Indented content (likely test output / t.Errorf): buffer for current test.
        if (std.mem.startsWith(u8, line, "    ") or std.mem.startsWith(u8, line, "\t")) {
            try pending.appendSlice(allocator, trimmed);
            try pending.append(allocator, '\n');
            continue;
        }

        // Non-indented line outside a test block: package-level summary.
        // Flush any pending buffer as-is (defensive; shouldn't normally have
        // content here — but a bare FAIL/PASS marker terminates the test run).
        try out.appendSlice(allocator, pending.items);
        pending.clearRetainingCapacity();
        if (std.mem.startsWith(u8, trimmed, "FAIL") or
            std.mem.startsWith(u8, trimmed, "ok\t") or
            std.mem.startsWith(u8, trimmed, "ok  ") or
            std.mem.startsWith(u8, trimmed, "PASS") or
            std.mem.startsWith(u8, trimmed, "exit status"))
        {
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            kept.* += 1;
        }
    }
    // End of stream: discard any leftover pending (no outcome seen).
}

test "matches: go verbose" {
    try std.testing.expect(matches("=== RUN   TestX\n--- PASS: TestX (0.00s)\n"));
}

test "matches: ok summary" {
    try std.testing.expect(matches("ok  \tgithub.com/x/y\t0.012s\n"));
}

test "matches: rejects non-go" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello\n"));
}

test "apply: fixture keeps FAIL + error context + package summary" {
    const input = @embedFile("fixture_go_test_v");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "--- FAIL: TestDivide") != null);
    try std.testing.expect(std.mem.find(u8, got, "--- FAIL: TestSqrt") != null);
    try std.testing.expect(std.mem.find(u8, got, "divide(10, 0) panic expected") != null);
    try std.testing.expect(std.mem.find(u8, got, "sqrt(-1) = 0, want NaN") != null);
    try std.testing.expect(std.mem.find(u8, got, "FAIL\tgithub.com/example/math") != null);
    // PASS markers dropped.
    try std.testing.expect(std.mem.find(u8, got, "--- PASS:") == null);
    try std.testing.expect(std.mem.find(u8, got, "=== RUN") == null);
    try std.testing.expect(std.mem.find(u8, got, "TestAdd") == null);
    try std.testing.expect(std.mem.find(u8, got, "TestMultiply") == null);
}

test "apply: all passing emits 'all tests passed'" {
    const input = "=== RUN   TestA\n" ++
        "--- PASS: TestA (0.00s)\n" ++
        "=== RUN   TestB\n" ++
        "--- PASS: TestB (0.00s)\n" ++
        "PASS\n" ++
        "ok  \tgithub.com/x/y\t0.005s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("all tests passed\n", out.written());
}

test "apply: FAIL on own line counts as failure" {
    const input =
        \\=== RUN   TestA
        \\    foo_test.go:5: boom
        \\--- FAIL: TestA (0.00s)
        \\FAIL
        \\exit status 1
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "--- FAIL: TestA") != null);
    try std.testing.expect(std.mem.find(u8, got, "foo_test.go:5: boom") != null);
    try std.testing.expect(std.mem.find(u8, got, "exit status 1") != null);
}
