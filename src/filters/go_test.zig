const std = @import("std");
const ansi = @import("ansi");
const signals = @import("signals");
const util = @import("util");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `go test -v` — on by default (v0.6). Set
// SMLL_LOSSLESS=1 to bypass.
//
// Keeps: `--- FAIL:` lines, error context under a FAIL, `FAIL\t<pkg>`/`ok\t<pkg>`
//        package summaries, benchmark result lines (`BenchmarkX-N  ...`), and
//        fuzz final stats.
// Drops: `--- PASS:` per-test output, `=== RUN` markers (passing), blank-line
//        padding between passing tests, intermediate fuzz progress lines, and
//        the redundant bare `PASS` / `FAIL` verdict markers + `exit status N`
//        (the per-package summary and process exit code already convey them).
//
// If no failures AND no benchmark/fuzz output kept, emits "all tests passed\n".
//
// Detection: stdout contains "=== RUN" or "--- FAIL:" or "--- PASS:" or
//            "FAIL\t" / "ok  \t" package lines or "Benchmark" prefix.

/// Superset gate for the pipe dispatcher: every match-path needs one of
/// "=== ", "--- ", "Benchmark", "ok  \t", "FAIL\t", so a false gate guarantees
/// `matches()` is false. See src/signals.zig.
pub fn sigGate(s: signals.Signals) bool {
    return s.goTest();
}

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "=== RUN") != null) return true;
    if (std.mem.find(u8, input, "--- FAIL:") != null) return true;
    if (std.mem.find(u8, input, "--- PASS:") != null) return true;
    // Benchmark lines: "BenchmarkX-N  ..."
    if (std.mem.find(u8, input, "\nBenchmark") != null) return true;
    if (std.mem.startsWith(u8, input, "Benchmark")) return true;
    // Fuzz lines: "=== FUZZ" or "--- FUZZ:"
    if (std.mem.find(u8, input, "=== FUZZ") != null) return true;
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
    var has_bench_or_fuzz: bool = false;
    try scanAndKeep(allocator, stdout, &scratch, &kept_lines, &has_bench_or_fuzz);
    try scanAndKeep(allocator, stderr, &scratch, &kept_lines, &has_bench_or_fuzz);

    if (has_bench_or_fuzz or hasFailureMarker(scratch.items)) {
        try util.writeHeadTail(writer, scratch.items, 120, 80);
        return;
    }
    try writer.writeAll("all tests passed\n");
}

fn hasFailureMarker(s: []const u8) bool {
    // B8 drops the bare `FAIL` line, so a kept failure is signalled by the
    // `--- FAIL:` test marker or the `FAIL\t<pkg>` package summary — both of
    // which survive. (A bare `FAIL` never reaches `s` anymore.)
    if (std.mem.find(u8, s, "--- FAIL:") != null) return true;
    if (std.mem.find(u8, s, "FAIL\t") != null) return true;
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
fn isBenchmarkLine(line: []const u8) bool {
    // Benchmark result: "BenchmarkXxx-N  <iterations>  <ns/op> ..."
    if (!std.mem.startsWith(u8, line, "Benchmark")) return false;
    // Must contain at least one tab (separates fields in benchmark output)
    for (line) |c| {
        if (c == '\t') return true;
    }
    return false;
}

fn isFuzzLine(line: []const u8) bool {
    // Fuzz progress: "fuzz: elapsed: 3s, execs: 1234 ..." or "=== FUZZ"
    if (std.mem.startsWith(u8, line, "fuzz: ")) return true;
    if (std.mem.startsWith(u8, line, "=== FUZZ")) return true;
    if (std.mem.startsWith(u8, line, "--- FUZZ:")) return true;
    return false;
}

fn scanAndKeep(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), kept: *usize, has_bench_or_fuzz: *bool) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    // Track the last fuzz progress line so we can keep only the final one.
    var last_fuzz_progress: std.ArrayList(u8) = .empty;
    defer last_fuzz_progress.deinit(allocator);

    while (lines.next()) |raw| {
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Benchmark result lines: preserve verbatim.
        if (isBenchmarkLine(trimmed)) {
            try out.appendSlice(allocator, pending.items);
            pending.clearRetainingCapacity();
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            kept.* += 1;
            has_bench_or_fuzz.* = true;
            continue;
        }

        // Fuzz progress lines: keep only the last one (intermediate are noise).
        if (std.mem.startsWith(u8, trimmed, "fuzz: ")) {
            last_fuzz_progress.clearRetainingCapacity();
            try last_fuzz_progress.appendSlice(allocator, trimmed);
            try last_fuzz_progress.append(allocator, '\n');
            has_bench_or_fuzz.* = true;
            continue;
        }
        // Fuzz outcome markers: preserve.
        if (std.mem.startsWith(u8, trimmed, "--- FUZZ:") or
            std.mem.startsWith(u8, trimmed, "=== FUZZ"))
        {
            try out.appendSlice(allocator, pending.items);
            pending.clearRetainingCapacity();
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            kept.* += 1;
            has_bench_or_fuzz.* = true;
            continue;
        }

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
        // B8: keep the per-package `FAIL\t<pkg>\t<time>` / `ok\t<pkg>` summary,
        // but drop the bare `FAIL` / `PASS` verdict markers and `exit status N`.
        // Each is redundant with the `--- FAIL:` marker (kept above), the
        // package summary, and the propagated process exit code.
        if (std.mem.startsWith(u8, trimmed, "FAIL\t") or
            std.mem.startsWith(u8, trimmed, "ok\t") or
            std.mem.startsWith(u8, trimmed, "ok  "))
        {
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            kept.* += 1;
        }
    }
    // Flush final fuzz progress line (the last one seen).
    if (last_fuzz_progress.items.len > 0) {
        try out.appendSlice(allocator, last_fuzz_progress.items);
        kept.* += 1;
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

test "matches: benchmark output" {
    try std.testing.expect(matches("BenchmarkAdd-8\t1000000\t1234 ns/op\n"));
    try std.testing.expect(matches("goos: darwin\nBenchmarkAdd-8\t1000000\t1234 ns/op\n"));
}

test "matches: fuzz output" {
    try std.testing.expect(matches("=== FUZZ  FuzzAdd\n"));
}

test "apply: benchmark-only run preserves benchmark results" {
    const input = "goos: darwin\n" ++
        "goarch: arm64\n" ++
        "pkg: github.com/example/math\n" ++
        "BenchmarkAdd-8\t1000000000\t0.3194 ns/op\n" ++
        "BenchmarkMultiply-8\t1000000000\t0.3201 ns/op\n" ++
        "PASS\n" ++
        "ok  \tgithub.com/example/math\t1.234s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // Benchmark results must be preserved
    try std.testing.expect(std.mem.find(u8, got, "BenchmarkAdd-8") != null);
    try std.testing.expect(std.mem.find(u8, got, "BenchmarkMultiply-8") != null);
    try std.testing.expect(std.mem.find(u8, got, "0.3194 ns/op") != null);
    // Must NOT emit "all tests passed" when benchmarks are present
    try std.testing.expect(std.mem.find(u8, got, "all tests passed") == null);
}

test "apply: fuzz output preserves final stats" {
    const input = "=== FUZZ  FuzzAdd\n" ++
        "fuzz: elapsed: 0s, execs: 100 (seed), new interesting: 0\n" ++
        "fuzz: elapsed: 3s, execs: 12345, new interesting: 2\n" ++
        "fuzz: elapsed: 6s, execs: 24680, new interesting: 3\n" ++
        "--- FUZZ: FuzzAdd (6.01s)\n" ++
        "PASS\n" ++
        "ok  \tgithub.com/example/math\t6.234s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // Final fuzz stats preserved (last progress line)
    try std.testing.expect(std.mem.find(u8, got, "execs: 24680") != null);
    // Intermediate fuzz progress dropped
    try std.testing.expect(std.mem.find(u8, got, "execs: 12345") == null);
    // Fuzz outcome marker preserved
    try std.testing.expect(std.mem.find(u8, got, "--- FUZZ: FuzzAdd") != null);
    // Must NOT emit "all tests passed"
    try std.testing.expect(std.mem.find(u8, got, "all tests passed") == null);
}

test "apply: mixed benchmarks + unit tests with failures" {
    const input = "=== RUN   TestAdd\n" ++
        "--- PASS: TestAdd (0.00s)\n" ++
        "=== RUN   TestFail\n" ++
        "    math_test.go:42: oops\n" ++
        "--- FAIL: TestFail (0.00s)\n" ++
        "BenchmarkAdd-8\t1000000\t1234 ns/op\n" ++
        "FAIL\n" ++
        "exit status 1\n" ++
        "FAIL\tgithub.com/example/math\t2.345s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "--- FAIL: TestFail") != null);
    try std.testing.expect(std.mem.find(u8, got, "BenchmarkAdd-8") != null);
    try std.testing.expect(std.mem.find(u8, got, "1234 ns/op") != null);
}

test "apply: bare PASS marker dropped (redundant with ok summary)" {
    // Symmetry with B8's bare-`FAIL` drop: the standalone `PASS` line is
    // redundant with the `ok\t<pkg>` summary, so it is dropped too. Use a
    // benchmark run so scratch is actually emitted (not folded to "all passed").
    const input = "BenchmarkAdd-8\t1000000\t1234 ns/op\n" ++
        "PASS\n" ++
        "ok  \tgithub.com/example/math\t1.234s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // Benchmark result + package summary survive.
    try std.testing.expect(std.mem.find(u8, got, "BenchmarkAdd-8") != null);
    try std.testing.expect(std.mem.find(u8, got, "ok  \tgithub.com/example/math") != null);
    // B8: the bare `PASS` verdict marker is dropped.
    try std.testing.expect(std.mem.find(u8, got, "\nPASS\n") == null);
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
    // B8: the bare `FAIL` line and `exit status N` are redundant with the
    // `--- FAIL:` marker and the propagated exit code, so they're dropped.
    try std.testing.expect(std.mem.find(u8, got, "exit status") == null);
    try std.testing.expect(std.mem.find(u8, got, "\nFAIL\n") == null);
}
