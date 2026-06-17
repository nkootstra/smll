const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `cargo build` / `cargo check` / `cargo clippy` /
// `make` / `ninja` / `go build` /
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
// Shape of summary line (emitted once per tool/status that fired at least one
// progress line): `Compiled N (cargo)` / `Checked N (cargo)` /
// `Compiled N (make)` / `built N (ninja)` / `Compiled N (go)`. For successful
// `zig build --summary all`, the original `Build Summary: …` line is forwarded
// verbatim; no synthesized count line is emitted.

// Source-line prefixes that count as build progress and collapse into a count.
// Cargo right-aligns status words to 12 columns, so `Compiling` and `Checking`
// have different leading-space counts. Make progress covers shell-ish build
// tool invocations at column 0. Go progress covers `go build:` leader lines.
const CARGO_PROGRESS_PREFIX = "   Compiling ";
const CARGO_CHECK_PREFIX = "    Checking ";
const GO_PROGRESS_PREFIX = "go build:";
pub fn matches(stdout: []const u8, stderr: []const u8) bool {
    return scanForAny(stdout) or scanForAny(stderr);
}

pub fn matchesCompilerDiagnostics(stdout: []const u8, stderr: []const u8) bool {
    return scanForCompilerDiagnostic(stdout) or scanForCompilerDiagnostic(stderr);
}

fn scanForAny(input: []const u8) bool {
    if (input.len == 0) return false;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "Build Summary: ")) return true;
        if (classify(line) != .other) return true;
    }
    return false;
}

fn scanForCompilerDiagnostic(input: []const u8) bool {
    if (input.len == 0) return false;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |line| {
        if (isCompilerDiagnosticStart(std.mem.trim(u8, line, " \t\r"))) return true;
    }
    return false;
}

const LineKind = enum {
    cargo_progress,
    cargo_check_progress,
    cargo_verbose_invocation,
    make_progress,
    ninja_progress,
    go_progress,
    warning,
    err,
    other,
};

fn classify(line: []const u8) LineKind {
    if (line.len == 0) return .other;
    // Progress classification first — these prefixes are anchored.
    if (std.mem.startsWith(u8, line, CARGO_PROGRESS_PREFIX)) return .cargo_progress;
    if (std.mem.startsWith(u8, line, CARGO_CHECK_PREFIX)) return .cargo_check_progress;
    if (std.mem.startsWith(u8, line, "     Running `rustc ")) return .cargo_verbose_invocation;
    if (std.mem.startsWith(u8, line, GO_PROGRESS_PREFIX)) return .go_progress;
    if (ninjaProgressCompleted(line) != null) return .ninja_progress;
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
        try writer.writeAll(summary);
        try writer.writeByte('\n');
        return;
    }

    var cargo_count: usize = 0;
    var cargo_check_count: usize = 0;
    var cargo_verbose_count: usize = 0;
    var make_count: usize = 0;
    var ninja_count: usize = 0;
    var go_count: usize = 0;
    var cargo_warning_count: usize = 0;
    var cargo_error_count: usize = 0;
    var cargo_finished_profile: ?[]const u8 = null;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    try processStream(allocator, stdout, writer, &strip_buf, &cargo_count, &cargo_check_count, &cargo_verbose_count, &make_count, &ninja_count, &go_count, &cargo_warning_count, &cargo_error_count, &cargo_finished_profile);
    try processStream(allocator, stderr, writer, &strip_buf, &cargo_count, &cargo_check_count, &cargo_verbose_count, &make_count, &ninja_count, &go_count, &cargo_warning_count, &cargo_error_count, &cargo_finished_profile);

    const cargo_crates = cargo_count + cargo_check_count;
    if (cargo_crates > 0) {
        try writer.writeAll("cargo: ");
        if (cargo_finished_profile) |profile| {
            try writer.writeAll("Finished ");
            try writer.writeAll(profile);
            try writer.writeAll("; ");
        }
        try ansi.writeDecimal(writer, cargo_error_count);
        try writer.writeByte('e');
        try writer.writeByte(' ');
        try ansi.writeDecimal(writer, cargo_warning_count);
        try writer.writeByte('w');
        try writer.writeByte(' ');
        try ansi.writeDecimal(writer, cargo_crates);
        try writer.writeAll(" crates\n");
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
    if (ninja_count > 0) {
        try writer.writeAll("built ");
        try ansi.writeDecimal(writer, ninja_count);
        try writer.writeAll(" (ninja)\n");
    }
    if (go_count > 0) {
        try writer.writeAll("Compiled ");
        try ansi.writeDecimal(writer, go_count);
        try writer.writeAll(" (go)\n");
    }
}

pub fn applyCompilerDiagnostics(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var wrote_line = false;
    var pending_blank = false;
    try processCompilerStream(allocator, stdout, writer, &strip_buf, &wrote_line, &pending_blank);
    try processCompilerStream(allocator, stderr, writer, &strip_buf, &wrote_line, &pending_blank);
}

fn processStream(
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    strip_buf: *std.ArrayList(u8),
    cargo_count: *usize,
    cargo_check_count: *usize,
    cargo_verbose_count: *usize,
    make_count: *usize,
    ninja_count: *usize,
    go_count: *usize,
    cargo_warning_count: *usize,
    cargo_error_count: *usize,
    cargo_finished_profile: *?[]const u8,
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
        // B13: drop GNU make's recursive `Entering/Leaving directory` chatter.
        if (isMakeDirNoise(line)) continue;
        const kind = classify(line);
        switch (kind) {
            .cargo_progress => cargo_count.* += 1,
            .cargo_check_progress => cargo_check_count.* += 1,
            .cargo_verbose_invocation => cargo_verbose_count.* += 1,
            .make_progress => make_count.* += 1,
            .ninja_progress => if (ninjaProgressCompleted(line)) |completed| {
                ninja_count.* = @max(ninja_count.*, completed);
            },
            .go_progress => go_count.* += 1,
            .warning, .err, .other => {
                if (isCargoFinishedLine(line)) {
                    if (cargo_finished_profile.* == null) cargo_finished_profile.* = cargoFinishedProfile(line);
                    continue;
                }
                if (isCargoGeneratedWarningSummary(line)) continue;
                if (kind == .warning and isRustWarningStart(line)) cargo_warning_count.* += 1;
                if (kind == .err and isRustErrorStart(line)) cargo_error_count.* += 1;
                try writer.writeAll(line);
                try writer.writeByte('\n');
            },
        }
    }
}

fn processCompilerStream(
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    strip_buf: *std.ArrayList(u8),
    wrote_line: *bool,
    pending_blank: *bool,
) !void {
    if (input.len == 0) return;
    const trimmed_input = if (input[input.len - 1] == '\n') input[0 .. input.len - 1] else input;
    if (trimmed_input.len == 0) return;
    var it = std.mem.splitScalar(u8, trimmed_input, '\n');
    while (it.next()) |raw| {
        const clean = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            if (wrote_line.*) pending_blank.* = true;
            continue;
        }
        if (isCompilerIncludeStack(trimmed) or isGeneratedDiagnosticCount(trimmed)) continue;
        if (pending_blank.*) {
            try writer.writeByte('\n');
            pending_blank.* = false;
        }
        try writer.writeAll(line);
        try writer.writeByte('\n');
        wrote_line.* = true;
    }
}

fn ninjaProgressCompleted(line: []const u8) ?usize {
    if (line.len < 6 or line[0] != '[') return null;
    var slash: usize = 1;
    var current: usize = 0;
    while (slash < line.len and std.ascii.isDigit(line[slash])) : (slash += 1) {
        current = current * 10 + (line[slash] - '0');
    }
    if (slash == 1 or slash >= line.len or line[slash] != '/') return null;
    var end: usize = slash + 1;
    var total_digits = false;
    while (end < line.len and std.ascii.isDigit(line[end])) : (end += 1) {
        total_digits = true;
    }
    if (!total_digits or end >= line.len or line[end] != ']') return null;
    if (end + 1 >= line.len or line[end + 1] != ' ') return null;
    return current;
}

/// GNU make prints `make[N]: Entering directory '…'` / `Leaving directory`
/// around every recursive sub-make. It's pure navigation chatter with no
/// build signal, so drop it.
fn isMakeDirNoise(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "make")) return false;
    return std.mem.find(u8, line, ": Entering directory") != null or
        std.mem.find(u8, line, ": Leaving directory") != null;
}

fn isCargoFinishedLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "    Finished ");
}

fn cargoFinishedProfile(line: []const u8) []const u8 {
    const rest = line["    Finished ".len..];
    var end: usize = 0;
    while (end < rest.len and rest[end] != ' ' and rest[end] != '\t' and rest[end] != '[') : (end += 1) {}
    return rest[0..end];
}

fn isCargoGeneratedWarningSummary(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "warning: `") and
        std.mem.find(u8, line, " generated ") != null;
}

fn isRustWarningStart(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "warning:");
}

fn isRustErrorStart(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "error:") or std.mem.startsWith(u8, line, "error[");
}

fn isCompilerDiagnosticStart(line: []const u8) bool {
    return std.mem.find(u8, line, ": error:") != null or
        std.mem.find(u8, line, ": warning:") != null or
        std.mem.find(u8, line, ": fatal error:") != null;
}

fn isCompilerIncludeStack(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "In file included from ") or
        (std.mem.startsWith(u8, line, "from ") and std.mem.endsWith(u8, line, ":"));
}

fn isGeneratedDiagnosticCount(line: []const u8) bool {
    if (!std.mem.endsWith(u8, line, " generated.")) return false;
    var i: usize = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
    if (i == 0 or i >= line.len or line[i] != ' ') return false;
    const rest = line[i + 1 ..];
    return std.mem.startsWith(u8, rest, "warning") or std.mem.startsWith(u8, rest, "error");
}

fn findZigSuccessSummary(input: []const u8) ?[]const u8 {
    const start = std.mem.find(u8, input, "Build Summary: ") orelse return null;
    const rest = input[start..];
    const end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
    const line = rest[0..end];
    if (std.mem.find(u8, line, "failed") == null) return line;
    return null;
}

test "matches: cargo progress" {
    try std.testing.expect(matches("   Compiling foo v0.1.0\n", ""));
    try std.testing.expect(matches("", "   Compiling foo v0.1.0\n"));
    try std.testing.expect(matches("", "    Checking foo v0.1.0\n"));
}

test "matches: make progress" {
    try std.testing.expect(matches("gcc -c foo.c\n", ""));
    try std.testing.expect(matches("LINK bin/app\n", ""));
}

test "matches: ninja progress" {
    try std.testing.expect(matches("[1/2] CC main.o\n", ""));
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
    try std.testing.expect(std.mem.find(u8, got, "cargo: Finished dev; 0e 0w 3 crates") != null);
    try std.testing.expect(std.mem.find(u8, got, "Compiling") == null);
}

test "apply: ninja fixture collapses progress and keeps warning" {
    const input = @embedFile("fixture_ninja_build");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "built 2 (ninja)") != null);
    try std.testing.expect(std.mem.find(u8, got, "[1/2]") == null);
    try std.testing.expect(std.mem.find(u8, got, "warning: unused variable 'unused'") != null);
}

test "apply: ninja reports completed steps on early failure" {
    const input =
        \\[1/100] CC main.o
        \\main.c:1:1: error: expected expression
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "built 1 (ninja)") != null);
    try std.testing.expect(std.mem.find(u8, got, "built 100 (ninja)") == null);
    try std.testing.expect(std.mem.find(u8, got, "error: expected expression") != null);
}

test "apply: cargo check progress collapses to checked summary" {
    const input =
        \\    Checking a v0.1.0
        \\    Checking b v0.1.0
        \\    Finished dev [unoptimized + debuginfo] target(s) in 1.23s
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", input, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "cargo: Finished dev; 0e 0w 2 crates") != null);
    try std.testing.expect(std.mem.find(u8, got, "Checking") == null);
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
    try std.testing.expect(std.mem.find(u8, got, "cargo: 0e 0w 2 crates") != null);
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
        "Build Summary: 140/140 steps succeeded; 871/871 tests passed\n",
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

test "apply: drops make recursive directory chatter" {
    const input =
        \\make[1]: Entering directory '/home/user/project/src'
        \\gcc -c foo.c
        \\make[1]: Leaving directory '/home/user/project/src'
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    // B13: make directory navigation is dropped; real progress still collapses.
    try std.testing.expect(std.mem.find(u8, got, "Compiled 1 (make)") != null);
    try std.testing.expect(std.mem.find(u8, got, "Entering directory") == null);
    try std.testing.expect(std.mem.find(u8, got, "Leaving directory") == null);
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
    try std.testing.expect(std.mem.find(u8, got, "cargo:") == null);
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
    try std.testing.expect(std.mem.find(u8, got, "cargo: 1e 0w 1 crates") != null);
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
    try std.testing.expect(std.mem.find(u8, got, "cargo: 0e 0w 1 crates") != null);
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
    try std.testing.expect(std.mem.find(u8, got, "cargo: Finished dev; 0e 0w 500 crates") != null);
    // Reduction target: ≥ 60%.  got/raw < 0.4 → got * 5 < raw * 2.
    try std.testing.expect(got.len * 5 < raw.len * 2);
}

test "applyCompilerDiagnostics: drops include stack and generated counters" {
    const input =
        \\In file included from /usr/include/stdio.h:42:
        \\                 from main.c:1:
        \\main.c:10:5: error: use of undeclared identifier 'foo'
        \\    foo();
        \\    ^
        \\main.c:15:12: warning: unused variable 'x' [-Wunused-variable]
        \\    int x = 42;
        \\        ^
        \\2 warnings generated.
        \\1 error generated.
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyCompilerDiagnostics(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "main.c:10:5: error") != null);
    try std.testing.expect(std.mem.find(u8, got, "main.c:15:12: warning") != null);
    try std.testing.expect(std.mem.find(u8, got, "foo();") != null);
    try std.testing.expect(std.mem.find(u8, got, "In file included") == null);
    try std.testing.expect(std.mem.find(u8, got, "warnings generated") == null);
    try std.testing.expect(got.len < input.len);
}
