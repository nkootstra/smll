const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `cargo test` — on by default (v0.6). Set
// SMLL_LOSSLESS=1 to bypass.
//
// Keeps: failure markers, panic frames, compile errors/warnings, result summary.
// Drops: "test X ... ok" pass lines, Compiling/Finished/Running progress,
// blank-line padding, ANSI escapes.
//
// If no failures are kept, emits "all tests passed\n" (on_empty contract).
//
// Detection: stdout contains "running " + "tests" line OR "test result:" line.

const KEEP_NEEDLES = [_][]const u8{
    "FAILED",
    "error[",
    "error:",
    "warning:",
    "test result:",
    "failures:",
    "panicked at",
    "---- ",
    "thread '",
    "bench:", // cargo bench / cargo test --bench result lines
};

pub fn matches(input: []const u8) bool {
    // Quick scan for either the "running N tests" or "test result:" markers.
    if (std.mem.find(u8, input, "test result:") != null) return true;
    // Match "running <digits> test" to avoid false positives on "running X".
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        const stripped = stripLeadingSpace(line);
        if (std.mem.startsWith(u8, stripped, "running ") and
            std.mem.find(u8, stripped, " test") != null) return true;
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);

    var kept_lines: usize = 0;
    try scanAndKeep(allocator, stdout, &scratch, &kept_lines);
    try scanAndKeep(allocator, stderr, &scratch, &kept_lines);

    if (kept_lines == 0) {
        try writer.writeAll("all tests passed\n");
        return;
    }
    try writer.writeAll(scratch.items);
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

fn stripLeadingSpace(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return line[i..];
}

test "matches: running N tests" {
    try std.testing.expect(matches("running 3 tests\ntest foo ... ok\n"));
}

test "matches: test result summary" {
    try std.testing.expect(matches("test result: ok. 5 passed; 0 failed\n"));
}

test "matches: rejects non-cargo" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello\n"));
    try std.testing.expect(!matches("running low\n"));
}

test "apply: all passing emits 'all tests passed'" {
    const input =
        \\   Compiling foo v0.1.0
        \\    Finished test [unoptimized + debuginfo] target(s)
        \\     Running unittests src/lib.rs
        \\
        \\running 3 tests
        \\test tests::a ... ok
        \\test tests::b ... ok
        \\test tests::c ... ok
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("all tests passed\n", out.written());
}

test "apply: keeps failure context" {
    const input =
        \\running 2 tests
        \\test tests::a ... ok
        \\test tests::b ... FAILED
        \\
        \\failures:
        \\
        \\---- tests::b stdout ----
        \\thread 'tests::b' panicked at 'assertion failed'
        \\
        \\test result: FAILED. 1 passed; 1 failed
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "FAILED") != null);
    try std.testing.expect(std.mem.find(u8, got, "failures:") != null);
    try std.testing.expect(std.mem.find(u8, got, "---- tests::b stdout ----") != null);
    try std.testing.expect(std.mem.find(u8, got, "panicked at") != null);
    // Pass lines dropped.
    try std.testing.expect(std.mem.find(u8, got, "tests::a ... ok") == null);
}

test "apply: strips ANSI from kept lines" {
    const input = "running 1 test\ntest x ... \x1b[31mFAILED\x1b[0m\ntest result: FAILED. 0 passed; 1 failed\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "FAILED") != null);
}

test "apply: benchmark results preserved (cargo test --bench)" {
    const input =
        \\   Compiling foo v0.1.0
        \\    Finished bench [optimized] target(s) in 0.42s
        \\     Running benches/bench.rs
        \\
        \\running 2 tests
        \\test bench_add      ... bench:         10 ns/iter (+/- 1)
        \\test bench_multiply ... bench:         15 ns/iter (+/- 2)
        \\
        \\test result: ok. 0 passed; 0 failed; 0 ignored; 2 measured; 0 filtered out; finished in 0.12s
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // Benchmark result lines must be preserved.
    try std.testing.expect(std.mem.find(u8, got, "bench_add") != null);
    try std.testing.expect(std.mem.find(u8, got, "10 ns/iter") != null);
    try std.testing.expect(std.mem.find(u8, got, "bench_multiply") != null);
    try std.testing.expect(std.mem.find(u8, got, "15 ns/iter") != null);
    // Summary kept.
    try std.testing.expect(std.mem.find(u8, got, "test result: ok") != null);
    // Noise dropped.
    try std.testing.expect(std.mem.find(u8, got, "Compiling") == null);
    // Must NOT emit "all tests passed" when benchmark results are present.
    try std.testing.expect(std.mem.find(u8, got, "all tests passed") == null);
}

test "apply: mixed unit tests + benchmarks" {
    const input =
        \\running 3 tests
        \\test tests::add   ... ok
        \\test bench_add    ... bench:         10 ns/iter (+/- 1)
        \\test bench_mul    ... bench:         15 ns/iter (+/- 2)
        \\
        \\test result: ok. 1 passed; 0 failed; 0 ignored; 2 measured; finished in 0.15s
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "10 ns/iter") != null);
    try std.testing.expect(std.mem.find(u8, got, "15 ns/iter") != null);
    try std.testing.expect(std.mem.find(u8, got, "test result:") != null);
    // Passing unit test line dropped.
    try std.testing.expect(std.mem.find(u8, got, "tests::add   ... ok") == null);
}
