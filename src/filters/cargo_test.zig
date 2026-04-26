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
    "error[",
    "error:",
    "warning:",
    "test result:",
    "panicked at",
    "---- ",
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
    const head_cap: usize = 200;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    // Sliding window: keep recent non-kept lines so we can emit
    // before-context when an error/warning appears.
    const BEFORE_CTX = 3;
    const AFTER_CTX = 3;
    var before_ring: [BEFORE_CTX][]const u8 = .{""} ** BEFORE_CTX;
    var before_owned: [BEFORE_CTX]?[]u8 = .{null} ** BEFORE_CTX;
    var before_count: usize = 0;
    var ring_idx: usize = 0;
    defer for (&before_owned) |*slot| if (slot.*) |s| allocator.free(s);

    // "sticky" mode: after an error/warning line, keep subsequent context
    // lines (file location, code snippet, pointer, help notes) until we
    // hit a blank line or a non-context line.
    var in_error_context = false;
    var after_remaining: usize = 0;

    while (lines.next()) |raw| {
        if (kept.* >= head_cap) break;
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            if (in_error_context) in_error_context = false;
            after_remaining = 0;
            continue;
        }

        if (shouldKeep(trimmed)) {
            // Emit before-context (recent non-kept lines).
            if (before_count > 0) {
                const total = @min(before_count, BEFORE_CTX);
                var start_idx: usize = if (before_count >= BEFORE_CTX) ring_idx else 0;
                for (0..total) |_| {
                    const ctx = before_ring[start_idx % BEFORE_CTX];
                    if (ctx.len > 0) {
                        try out.appendSlice(allocator, ctx);
                        try out.append(allocator, '\n');
                        kept.* += 1;
                    }
                    start_idx += 1;
                }
                before_count = 0;
            }

            // Start sticky context for error/warning lines.
            in_error_context = std.mem.startsWith(u8, trimmed, "error") or
                std.mem.startsWith(u8, trimmed, "warning");
            after_remaining = AFTER_CTX;

            if (std.mem.startsWith(u8, trimmed, "test result:")) {
                try writeCompactResult(allocator, trimmed, out);
                in_error_context = false;
                after_remaining = 0;
            } else {
                try out.appendSlice(allocator, trimmed);
                try out.append(allocator, '\n');
            }
            kept.* += 1;
            continue;
        }

        // Keep compiler error context lines (-->, |, ^^^, = help, etc.)
        if (in_error_context and isErrorContext(trimmed)) {
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            kept.* += 1;
            continue;
        }

        // Keep after-context lines (lines immediately following an error).
        if (after_remaining > 0) {
            try out.appendSlice(allocator, trimmed);
            try out.append(allocator, '\n');
            kept.* += 1;
            after_remaining -= 1;
            continue;
        }

        in_error_context = false;

        // Store in before-context ring buffer.
        if (before_owned[ring_idx % BEFORE_CTX]) |old| allocator.free(old);
        const owned = try allocator.dupe(u8, trimmed);
        before_owned[ring_idx % BEFORE_CTX] = owned;
        before_ring[ring_idx % BEFORE_CTX] = owned;
        ring_idx = (ring_idx + 1) % BEFORE_CTX;
        before_count += 1;
    }
}

/// Lines that are part of a compiler error/warning context block.
fn isErrorContext(line: []const u8) bool {
    if (line.len == 0) return false;
    // "--> src/file.rs:42:5" — file location
    if (std.mem.startsWith(u8, line, "-->")) return true;
    // "= help: ..." or "= note: ..." — compiler hints
    if (std.mem.startsWith(u8, line, "= ")) return true;
    // Lines starting with a digit (line numbers like "42 | ...") or pipe
    if (std.ascii.isDigit(line[0])) return true;
    if (line[0] == '|') return true;
    // "^^^" pointer lines, "---" underlines
    if (line[0] == '^' or line[0] == '-') return true;
    // "For more information about this error..." help line
    if (std.mem.startsWith(u8, line, "For more info")) return true;
    return false;
}

fn writeCompactResult(allocator: Allocator, line: []const u8, out: *std.ArrayList(u8)) !void {
    const passed = numberBefore(line, " passed") orelse "0";
    const failed = numberBefore(line, " failed") orelse "0";
    try out.appendSlice(allocator, "res ");
    try out.appendSlice(allocator, passed);
    try out.appendSlice(allocator, "p ");
    try out.appendSlice(allocator, failed);
    try out.appendSlice(allocator, "f");
    if (std.mem.indexOf(u8, line, "finished in ")) |i| {
        const dur = firstToken(line[i + "finished in ".len ..]);
        if (dur.len > 0) {
            try out.appendSlice(allocator, " ");
            try out.appendSlice(allocator, dur);
        }
    }
    try out.append(allocator, '\n');
}

fn numberBefore(line: []const u8, marker: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, line, marker) orelse return null;
    if (idx == 0) return null;
    var start = idx;
    while (start > 0 and std.ascii.isDigit(line[start - 1])) start -= 1;
    if (start == idx) return null;
    return line[start..idx];
}

fn firstToken(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r");
    var i: usize = 0;
    while (i < t.len and t[i] != ' ' and t[i] != '\t') : (i += 1) {}
    return t[0..i];
}

fn shouldKeep(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "error: test failed, to rerun pass")) return false;
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
    try std.testing.expect(std.mem.find(u8, got, "---- tests::b stdout ----") != null);
    try std.testing.expect(std.mem.find(u8, got, "panicked at") != null);
    try std.testing.expect(std.mem.find(u8, got, "res 1p 1f") != null);
}

test "apply: strips ANSI from kept lines" {
    const input = "running 1 test\ntest x ... \x1b[31mFAILED\x1b[0m\ntest result: FAILED. 0 passed; 1 failed\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "res 0p 1f") != null);
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
    // Summary kept in compact form.
    try std.testing.expect(std.mem.find(u8, got, "res 0p 0f") != null);
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
    try std.testing.expect(std.mem.find(u8, got, "res 1p 0f") != null);
}

test "apply: compiler error with ANSI preserves context" {
    const input = "\x1b[0m\x1b[1m\x1b[38;5;9merror[E0308]\x1b[0m\x1b[1m: type mismatch\x1b[0m\n\x1b[0m  \x1b[1m\x1b[38;5;12m--> \x1b[0msrc/stream.rs:42:5\x1b[0m\n\x1b[0m   \x1b[1m\x1b[38;5;12m|\x1b[0m\n\x1b[0m\x1b[1m\x1b[38;5;12m42\x1b[0m \x1b[1m\x1b[38;5;12m|\x1b[0m     let x: u32 = \"hello\";\x1b[0m\n\x1b[0m   \x1b[1m\x1b[38;5;12m|\x1b[0m \x1b[1m\x1b[38;5;9m                  ^^^^^^^\x1b[0m expected u32\n\ntest result: FAILED. 0 passed; 1 failed\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", input, &out.writer);
    const result = out.written();
    // Must contain file location
    try std.testing.expect(std.mem.indexOf(u8, result, "src/stream.rs:42:5") != null);
    // Must contain the code line  
    try std.testing.expect(std.mem.indexOf(u8, result, "let x: u32") != null);
    // Must contain the pointer
    try std.testing.expect(std.mem.indexOf(u8, result, "^^^^^^^") != null);
}

test "apply: stderr compiler error + stdout test results" {
    // Simulates real cargo test: compiler error on stderr, test results on stdout.
    // This is the actual case that was failing.
    const stderr_input = "\x1b[0m\x1b[1m\x1b[38;5;9merror[E0308]\x1b[0m\x1b[0m\x1b[1m: type mismatch\x1b[0m\n\x1b[0m  \x1b[0m\x1b[0m\x1b[1m\x1b[38;5;12m--> \x1b[0m\x1b[0msrc/stream.rs:42:5\x1b[0m\n\x1b[0m   \x1b[0m\x1b[0m\x1b[1m\x1b[38;5;12m|\x1b[0m\n\x1b[0m\x1b[1m\x1b[38;5;12m42\x1b[0m \x1b[0m\x1b[0m\x1b[1m\x1b[38;5;12m| \x1b[0m\x1b[0m    let x: u32 = \"hello\";\x1b[0m\n\x1b[0m   \x1b[0m\x1b[0m\x1b[1m\x1b[38;5;12m|\x1b[0m \x1b[0m\x1b[0m\x1b[1m\x1b[38;5;9m                  ^^^^^^^ expected `u32`, found `&str`\x1b[0m\n";
    const stdout_input = "running 1691 tests\ntest core::tests::test_a ... ok\ntest result: ok. 1691 passed; 0 failed; finished in 0.90s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, stdout_input, stderr_input, &out.writer);
    const result = out.written();
    // Must contain file location from stderr
    try std.testing.expect(std.mem.indexOf(u8, result, "src/stream.rs:42:5") != null);
    // Must contain the pointer
    try std.testing.expect(std.mem.indexOf(u8, result, "^^^^^^^") != null);
}
