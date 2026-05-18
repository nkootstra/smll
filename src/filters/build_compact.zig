const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `cargo build` / `make` / `go build` — on by
// default (v0.6). Set SMLL_LOSSLESS=1 to bypass.
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
    make_progress,
    go_progress,
    warning,
    err,
    other,
};

fn classify(line: []const u8) LineKind {
    if (line.len == 0) return .other;
    // Progress classification first — these prefixes are anchored.
    if (std.mem.startsWith(u8, line, CARGO_PROGRESS_PREFIX)) return .cargo_progress;
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

    var cargo_count: usize = 0;
    var make_count: usize = 0;
    var go_count: usize = 0;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    try processStream(allocator, stdout, writer, &strip_buf, &cargo_count, &make_count, &go_count);
    try processStream(allocator, stderr, writer, &strip_buf, &cargo_count, &make_count, &go_count);

    if (cargo_count > 0) {
        try writer.writeAll("Compiled ");
        try ansi.writeDecimal(writer, cargo_count);
        try writer.writeAll(" (cargo)\n");
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
            .make_progress => make_count.* += 1,
            .go_progress => go_count.* += 1,
            .warning, .err, .other => {
                try writer.writeAll(line);
                try writer.writeByte('\n');
            },
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
