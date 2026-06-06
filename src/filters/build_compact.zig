const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `cargo build` / `make` / `go build` /
// successful `zig build --summary all` output — on by default (v0.6).
// Set SMLL_LOSSLESS=1 to bypass.
//
// Collapses per-unit compile progress lines into one summary line per tool.
// Warnings and errors are preserved verbatim. Empty lines are preserved so
// error snippets (caret, source line) stay readable.
//
// Stream placement: `cargo build` emits progress on stderr; `go build` emits
// errors on stderr; `make` splits across both. `apply` folds stderr after
// stdout into a single virtual stream before classification.
//
// Shape of summary line (emitted once per tool that fired at least one
// progress line): `Compiled N (cargo)` / `Compiled N (make)` /
// `Compiled N (go)`.

// Source-line prefixes that count as "compiler progress" and collapse into
// a count. Two space-prefixed entries cover cargo's leading 3-space indent
// ("   Compiling foo v0.1.0"). Make progress covers shell-ish build tool
// invocations at column 0. Go progress covers `go build:` leader lines.
const CARGO_PROGRESS_PREFIX = "   Compiling ";
const GO_PROGRESS_PREFIX = "go build:";
const ZIG_SUMMARY_PREFIX = "Build Summary: ";

pub fn matches(stdout: []const u8, stderr: []const u8) bool {
    return scanForAny(stdout) or scanForAny(stderr);
}

fn scanForAny(input: []const u8) bool {
    if (input.len == 0) return false;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (classify(line) != .other) return true;
    }
    return false;
}

const LineKind = enum {
    cargo_progress,
    cargo_verbose_invocation,
    make_progress,
    go_progress,
    zig_success_summary,
    warning,
    err,
    other,
};

fn classify(line: []const u8) LineKind {
    if (line.len == 0) return .other;
    // Progress classification first — these prefixes are anchored.
    if (isZigSuccessSummary(line)) return .zig_success_summary;
    if (std.mem.startsWith(u8, line, CARGO_PROGRESS_PREFIX)) return .cargo_progress;
    if (std.mem.startsWith(u8, line, "     Running `rustc ")) return .cargo_verbose_invocation;
    if (std.mem.startsWith(u8, line, GO_PROGRESS_PREFIX)) return .go_progress;
    // Make progress: first-char switch avoids iterating the prefix array.
    switch (line[0]) {
        'g' => if (std.mem.startsWith(u8, line, "gcc ") or std.mem.startsWith(u8, line, "g++ ")) return .make_progress,
        'c' => if (std.mem.startsWith(u8, line, "cc ") or std.mem.startsWith(u8, line, "clang ") or std.mem.startsWith(u8, line, "clang++ ")) return .make_progress,
        'C' => if (std.mem.startsWith(u8, line, "CC ") or std.mem.startsWith(u8, line, "CXX ")) return .make_progress,
        'L' => if (std.mem.startsWith(u8, line, "LD ") or std.mem.startsWith(u8, line, "LINK ")) return .make_progress,
        'A' => if (std.mem.startsWith(u8, line, "AR ")) return .make_progress,
        else => {},
    }
    // Errors before warnings.
    if (std.mem.find(u8, line, "error:") != null or std.mem.find(u8, line, "error[") != null or
        std.mem.find(u8, line, "ERROR") != null or std.mem.find(u8, line, "FAIL") != null) return .err;
    if (std.mem.find(u8, line, "warning:") != null or std.mem.find(u8, line, "WARN") != null) return .warning;
    return .other;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    if (findZigSuccessSummary(stdout) orelse findZigSuccessSummary(stderr)) |summary| {
        try writeZigSuccess(allocator, stdout, stderr, summary, writer);
        return;
    }

    var cargo_count: usize = 0;
    var cargo_verbose_count: usize = 0;
    var make_count: usize = 0;
    var go_count: usize = 0;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    try processStream(allocator, stdout, writer, &strip_buf, &cargo_count, &cargo_verbose_count, &make_count, &go_count);
    try processStream(allocator, stderr, writer, &strip_buf, &cargo_count, &cargo_verbose_count, &make_count, &go_count);

    if (cargo_count > 0) {
        try writer.writeAll("Compiled ");
        try ansi.writeDecimal(writer, cargo_count);
        try writer.writeAll(" (cargo)\n");
    } else if (cargo_verbose_count > 0) {
        try writer.writeAll("Ran ");
        try ansi.writeDecimal(writer, cargo_verbose_count);
        try writer.writeAll(" rustc invocations (cargo -vv)\n");
    }
    if (make_count > 0) {
        try writer.writeAll("Compiled ");
        try ansi.writeDecimal(writer, make_count);
        try writer.writeAll(" (make)\n");
    }
    if (go_count > 0) {
        try writer.writeAll("Compiled ");
        try ansi.writeDecimal(writer, go_count);
        try writer.writeAll(" (go)\n");
    }
}

fn processStream(
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    strip_buf: *std.ArrayList(u8),
    cargo_count: *usize,
    cargo_verbose_count: *usize,
    make_count: *usize,
    go_count: *usize,
) !void {
    if (input.len == 0) return;
    // splitScalar yields an empty final element when input ends in '\n'.
    // Trimming that trailing '\n' keeps the loop from emitting a phantom
    // blank line after the real content.
    const trimmed = if (input[input.len - 1] == '\n') input[0 .. input.len - 1] else input;
    if (trimmed.len == 0) return;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |raw| {
        const line = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const kind = classify(line);
        switch (kind) {
            .cargo_progress => cargo_count.* += 1,
            .cargo_verbose_invocation => cargo_verbose_count.* += 1,
            .make_progress => make_count.* += 1,
            .go_progress => go_count.* += 1,
            .zig_success_summary => {
                try writer.writeAll(line);
                try writer.writeByte('\n');
            },
            .warning, .err, .other => {
                try writer.writeAll(line);
                try writer.writeByte('\n');
            },
        }
    }
}

fn isZigSuccessSummary(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, ZIG_SUMMARY_PREFIX)) return false;
    if (std.mem.find(u8, line, "steps succeeded") == null) return false;
    if (std.mem.find(u8, line, "failed") != null) return false;
    return true;
}

fn findZigSuccessSummary(input: []const u8) ?[]const u8 {
    if (input.len == 0) return null;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (isZigSuccessSummary(line)) return line;
    }
    return null;
}

fn writeZigSuccess(
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    summary: []const u8,
    writer: *Writer,
) !void {
    try writer.writeAll(summary);
    try writer.writeByte('\n');

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    try writeZigWarnings(allocator, stdout, writer, &strip_buf);
    try writeZigWarnings(allocator, stderr, writer, &strip_buf);
}

fn writeZigWarnings(
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    strip_buf: *std.ArrayList(u8),
) !void {
    if (input.len == 0) return;
    const trimmed = if (input[input.len - 1] == '\n') input[0 .. input.len - 1] else input;
    if (trimmed.len == 0) return;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |raw| {
        const line = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        switch (classify(line)) {
            .warning, .err => {
                try writer.writeAll(line);
                try writer.writeByte('\n');
            },
            else => {},
        }
    }
}

test "matches: cargo progress" {
    try std.testing.expect(matches("   Compiling foo v0.1.0\n", ""));
    try std.testing.expect(matches("", "   Compiling foo v0.1.0\n"));
}

test "matches: make progress" {
    try std.testing.expect(matches("gcc -c foo.c\n", ""));
    try std.testing.expect(matches("LINK bin/app\n", ""));
}

test "matches: go progress" {
    try std.testing.expect(matches("go build: compiling foo\n", ""));
}

test "matches: zig successful build summary" {
    try std.testing.expect(matches(
        "Build Summary: 140/140 steps succeeded; 871/871 tests passed\n",
        "",
    ));
}

test "matches: warning alone" {
    try std.testing.expect(matches("warning: unused variable\n", ""));
    try std.testing.expect(matches("", "WARN: something\n"));
}

test "matches: error alone" {
    try std.testing.expect(matches("error[E0308]: mismatched types\n", ""));
    try std.testing.expect(matches("", "FAIL: bar\n"));
}

test "matches: rejects empty and unrelated" {
    try std.testing.expect(!matches("", ""));
    try std.testing.expect(!matches("hello world\n", ""));
    try std.testing.expect(!matches("", "hello world\n"));
}

test "apply: cargo happy path collapses to summary" {
    const input =
        \\   Compiling a v0.1.0
        \\   Compiling b v0.1.0
        \\   Compiling c v0.1.0
        \\    Finished dev [unoptimized + debuginfo] target(s) in 1.23s
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", input, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Compiled 3 (cargo)") != null);
    try std.testing.expect(std.mem.find(u8, got, "Finished dev") != null);
    try std.testing.expect(std.mem.find(u8, got, "Compiling") == null);
}

test "apply: cargo verbose rustc invocations are dropped" {
    const input =
        \\   Compiling serde v1.0.0
        \\     Running `rustc --crate-name serde --edition=2021`
        \\   Compiling reqwest v0.12.0
        \\     Running `rustc --crate-name reqwest --edition=2021`
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", input, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Compiled 2 (cargo)") != null);
    try std.testing.expect(std.mem.find(u8, got, "rustc --crate-name") == null);
}

test "apply: cargo verbose without progress emits invocation count" {
    const input =
        \\     Running `rustc --crate-name serde --edition=2021`
        \\     Running `rustc --crate-name reqwest --edition=2021`
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", input, &out.writer);
    try std.testing.expectEqualStrings("Ran 2 rustc invocations (cargo -vv)\n", out.written());
}

test "apply: make mixed progress + warning" {
    const input =
        \\gcc -c foo.c
        \\gcc -c bar.c
        \\warning: unused variable 'x'
        \\LINK bin/app
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "warning: unused variable") != null);
    try std.testing.expect(std.mem.find(u8, got, "Compiled 3 (make)") != null);
    try std.testing.expect(std.mem.find(u8, got, "gcc -c") == null);
    try std.testing.expect(std.mem.find(u8, got, "LINK") == null);
}

test "apply: go build progress collapses" {
    const input =
        \\go build: compiling ./cmd/foo
        \\go build: compiling ./cmd/bar
        \\go build: compiling ./cmd/baz
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", input, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Compiled 3 (go)") != null);
    try std.testing.expect(std.mem.find(u8, got, "go build:") == null);
}

test "apply: zig successful build summary drops step tree" {
    const input =
        \\Build Summary: 140/140 steps succeeded; 871/871 tests passed
        \\test success
        \\+- run test 194 pass (194 total) 42s MaxRSS:71M
        \\|  +- compile test ReleaseSmall native success 2s MaxRSS:226M
        \\warning: cache directory is not writable
        \\+- compile exe smll Debug native cached 70ms MaxRSS:36M
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings(
        "Build Summary: 140/140 steps succeeded; 871/871 tests passed\n" ++
            "warning: cache directory is not writable\n",
        out.written(),
    );
}

test "apply: failed zig build summary preserves evidence" {
    const input =
        \\test
        \\+- run test 191 pass, 3 fail (194 total)
        \\error: 'integration_test.test.wrapper: stats record agent-visible stdout and stderr bytes' failed without output
        \\Build Summary: 138/140 steps succeeded (1 failed); 868/871 tests passed (3 failed)
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "run test 191 pass, 3 fail") != null);
    try std.testing.expect(std.mem.find(u8, got, "stats record agent-visible") != null);
    try std.testing.expect(std.mem.find(u8, got, "Build Summary: 138/140") != null);
}

test "apply: empty input yields empty output" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "", &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: no progress, only warning → no summary line" {
    const input = "warning: unused variable 'x'\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "warning: unused") != null);
    try std.testing.expect(std.mem.find(u8, got, "Compiled") == null);
}

test "apply: compile error block emitted verbatim, no progress collapse inside" {
    const input =
        \\   Compiling foo v0.1.0
        \\error[E0308]: mismatched types
        \\  --> src/lib.rs:3:5
        \\   |
        \\ 3 |     "hello"
        \\   |     ^^^^^^^ expected `i32`, found `&str`
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", input, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "error[E0308]: mismatched types") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/lib.rs:3:5") != null);
    try std.testing.expect(std.mem.find(u8, got, "expected `i32`") != null);
    try std.testing.expect(std.mem.find(u8, got, "Compiled 1 (cargo)") != null);
}

test "apply: mixed cargo + make emits two summary lines" {
    const input =
        \\   Compiling rust_dep v0.1.0
        \\gcc -c c_dep.c
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Compiled 1 (cargo)") != null);
    try std.testing.expect(std.mem.find(u8, got, "Compiled 1 (make)") != null);
}

test "apply: strips ANSI on kept lines" {
    const input = "\x1b[33mwarning:\x1b[0m unused variable 'x'\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "warning: unused") != null);
}

test "apply: large synthetic cargo fixture reduces ≥ 60%" {
    const alloc = std.testing.allocator;
    var fixture = Writer.Allocating.init(alloc);
    defer fixture.deinit();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        try fixture.writer.print("   Compiling crate_{d} v0.1.0\n", .{i});
    }
    try fixture.writer.writeAll("    Finished dev [unoptimized + debuginfo] target(s) in 12.34s\n");
    const raw = fixture.written();

    var out = Writer.Allocating.init(alloc);
    defer out.deinit();
    try apply(alloc, "", raw, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Compiled 500 (cargo)") != null);
    try std.testing.expect(std.mem.find(u8, got, "Finished dev") != null);
    // Reduction target: ≥ 60%.  got/raw < 0.4 → got * 5 < raw * 2.
    try std.testing.expect(got.len * 5 < raw.len * 2);
}
