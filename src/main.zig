const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};
const pipe_filters = @import("pipe_filters.zig");
const filter_catalog = @import("filter_catalog.zig");
const pipeline = @import("pipeline.zig");
const state_io = @import("state_io.zig");
const stats = @import("stats.zig");
const tee = @import("tee.zig");
const wrapper = @import("wrapper.zig");
const wrapper_git = @import("wrapper_git.zig");
const wrapper_util = @import("wrapper_util.zig");
const cargo_test = @import("cargo_test");
const pytest = @import("pytest");
const jest = @import("jest");
const js_test = @import("js_test");
const tsc = @import("tsc");
const go_test = @import("go_test");
const npm_install = @import("npm_install");
const signals = @import("signals");
const setup = @import("setup.zig");
const hook_eval = @import("hook_eval.zig");

// The pipe-mode filter chain lives in pipe_filters.zig so both stdin pipe mode
// (here) and wrapper.zig's `sh -c` re-dispatch share one definition.
const Filters = pipe_filters.Filters;

// rg filter is wrapper-mode only (`smll rg --files src/`). Its output grammar
// overlaps too many non-rg tools in pipe mode (diff stats, generic listings),
// so auto-detection via matches() produces false positives and breaks the
// lossless contract for those other tools.

test {
    _ = pipe_filters;
    _ = pipeline;
    _ = wrapper;
    _ = wrapper_git;
    _ = wrapper_util;
}

// --- signals pre-classifier safety net ---------------------------------------
//
// The pipe dispatcher (src/pipeline.zig) skips a gated filter's `matches()`
// whenever its `sigGate` is false. That is only sound if every gate is a
// SUPERSET of its `matches()` — i.e. `matches(x) ⟹ sigGate(compute(x))`. These
// tests pin that invariant against real captured output so a future edit to a
// filter's `matches()` (a new detection path whose needle isn't in the gate)
// fails the build instead of silently misrouting an agent's pipe output.

test "signals gate is a superset of matches for every gated filter (real fixtures)" {
    const MatchFn = *const fn ([]const u8) bool;
    const GateFn = *const fn (signals.Signals) bool;
    const Gated = struct { matches: MatchFn, gate: GateFn };
    const gated = [_]Gated{
        .{ .matches = cargo_test.matches, .gate = cargo_test.sigGate },
        .{ .matches = jest.matches, .gate = jest.sigGate },
        .{ .matches = js_test.matches, .gate = js_test.sigGate },
        .{ .matches = tsc.matches, .gate = tsc.sigGate },
        .{ .matches = go_test.matches, .gate = go_test.sigGate },
        .{ .matches = pytest.matches, .gate = pytest.sigGate },
        .{ .matches = npm_install.matches, .gate = npm_install.sigGate },
    };
    const corpus = [_][]const u8{
        @embedFile("sigfix_cargo_test"),    @embedFile("sigfix_jest"),
        @embedFile("sigfix_mocha"),         @embedFile("sigfix_node_test"),
        @embedFile("sigfix_tsc"),           @embedFile("sigfix_go_test"),
        @embedFile("sigfix_pytest"),        @embedFile("sigfix_npm"),
        @embedFile("sigfix_pnpm"),          @embedFile("sigfix_pnpm9"),
        @embedFile("sigfix_bun"),           @embedFile("sigfix_yarn"),
        @embedFile("sigfix_composer"),      @embedFile("sigfix_journalctl"),
        @embedFile("sigfix_ps_auxww"),      @embedFile("sigfix_pip"),
        @embedFile("sigfix_cargo_verbose"),
    };
    for (corpus) |data| {
        const sig = signals.compute(data);
        for (gated) |g| {
            // matches ⟹ gate. A false gate must forbid a match, or the
            // dispatcher would skip a filter that would have claimed the input.
            if (g.matches(data)) try std.testing.expect(g.gate(sig));
        }
    }
}

test "signals gate accepts each real positive fixture's target filter" {
    inline for (.{
        .{ cargo_test, @embedFile("sigfix_cargo_test") },
        .{ jest, @embedFile("sigfix_jest") },
        .{ js_test, @embedFile("sigfix_mocha") },
        .{ js_test, @embedFile("sigfix_node_test") },
        .{ tsc, @embedFile("sigfix_tsc") },
        .{ go_test, @embedFile("sigfix_go_test") },
        .{ pytest, @embedFile("sigfix_pytest") },
        .{ npm_install, @embedFile("sigfix_npm") },
        .{ npm_install, @embedFile("sigfix_pnpm") },
        .{ npm_install, @embedFile("sigfix_pnpm9") },
        .{ npm_install, @embedFile("sigfix_bun") },
        .{ npm_install, @embedFile("sigfix_yarn") },
        .{ npm_install, @embedFile("sigfix_composer") },
    }) |pair| {
        const F = pair[0];
        const data = pair[1];
        try std.testing.expect(F.matches(data)); // real positive still detected
        try std.testing.expect(F.sigGate(signals.compute(data))); // and not gated out
    }
}

test "large generic streams route past every gated filter unchanged" {
    inline for (.{
        @embedFile("sigfix_journalctl"), @embedFile("sigfix_ps_auxww"),
        @embedFile("sigfix_pip"),        @embedFile("sigfix_cargo_verbose"),
    }) |data| {
        // None of the gated filters claim a generic stream, so dispatch falls
        // through to the generic compactor exactly as before the gate existed.
        try std.testing.expect(!cargo_test.matches(data));
        try std.testing.expect(!jest.matches(data));
        try std.testing.expect(!js_test.matches(data));
        try std.testing.expect(!tsc.matches(data));
        try std.testing.expect(!go_test.matches(data));
        try std.testing.expect(!pytest.matches(data));
        try std.testing.expect(!npm_install.matches(data));
    }
}

const envFlagOn = wrapper_util.envFlagOn;

const help_text =
    \\Usage:
    \\smll|smll <cmd...>|<cmd>|smll
    \\-h --help --version --filters
    \\--raw [--] <cmd...>|<cmd>|smll --raw
    \\--explain|--err|--test|--rewrite <cmd...>
    \\--stats [--reset [--all]|--verbose|--by-command|--since <24h|7d|30d>|--project]
    \\--discover [--since <24h|7d|30d>|--project]
    \\--setup[=]T --unsetup[=]T [--dry-run]
    \\T=claude|opencode|cursor|codex
;

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    var environ_map = try init.environ.createMap(std.heap.page_allocator);
    defer environ_map.deinit();
    const environ = &environ_map;
    const args = try init.args.toSlice(arena_allocator);

    var out_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &out_buf);

    var err_buf: [1024]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &err_buf);

    // Fast path: no extra argv -> help for humans, stdin mode for pipes.
    // Skip setup check and wrapper-mode arena init entirely in pipe mode.
    if (args.len <= 1) {
        if (stdinIsTty()) {
            try printHelp(&stdout_writer.interface);
            try stdout_writer.interface.flush();
            return;
        }

        var pipe_out_buf: [32768]u8 = undefined;
        var pipe_stdout_writer = stdout_file.writer(io, &pipe_out_buf);
        var in_buf: [4096]u8 = undefined;
        var stdin_file = std.Io.File.stdin();
        var stdin_reader = stdin_file.reader(io, &in_buf);
        if (envFlagOn(environ, "SMLL_LOSSLESS")) {
            var copy_buf: [32768]u8 = undefined;
            while (true) {
                const got = stdin_reader.interface.readSliceShort(&copy_buf) catch |err| switch (err) {
                    error.ReadFailed => return err,
                };
                if (got == 0) break;
                try pipe_stdout_writer.interface.writeAll(copy_buf[0..got]);
            }
        } else {
            try pipeline.run(
                std.heap.page_allocator,
                &stdin_reader.interface,
                &pipe_stdout_writer.interface,
                Filters,
            );
        }
        try pipe_stdout_writer.interface.flush();
        return;
    }

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        try printHelp(&stdout_writer.interface);
        try stdout_writer.interface.flush();
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try stdout_writer.interface.writeAll("smll ");
        try stdout_writer.interface.writeAll(build_options.smll_version);
        try stdout_writer.interface.writeByte('\n');
        try stdout_writer.interface.flush();
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--filters")) {
        try filter_catalog.write(&stdout_writer.interface);
        try stdout_writer.interface.flush();
        return;
    }

    const home = environ.get("HOME") orelse "";

    if (std.mem.eql(u8, args[1], "--raw")) {
        if (args.len == 2) {
            if (stdinIsTty()) {
                try stderr_writer.interface.writeAll("usage: smll --raw [--] <cmd...>\n       <cmd> | smll --raw\n");
                try stderr_writer.interface.flush();
                std.process.exit(2);
            }
            var pipe_out_buf: [32768]u8 = undefined;
            var pipe_stdout_writer = stdout_file.writer(io, &pipe_out_buf);
            var in_buf: [4096]u8 = undefined;
            var stdin_file = std.Io.File.stdin();
            var stdin_reader = stdin_file.reader(io, &in_buf);
            try copyRaw(&stdin_reader.interface, &pipe_stdout_writer.interface);
            try pipe_stdout_writer.interface.flush();
            return;
        }

        const child_start: usize = if (std.mem.eql(u8, args[2], "--")) 3 else 2;
        if (child_start == args.len) {
            try stderr_writer.interface.writeAll("usage: smll --raw [--] <cmd...>\n       <cmd> | smll --raw\n");
            try stderr_writer.interface.flush();
            std.process.exit(2);
        }

        const code = try wrapper.runRaw(
            arena_allocator,
            io,
            environ,
            args[child_start..],
            &stdout_writer.interface,
            &stderr_writer.interface,
        );
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        exitIfNonzero(code);
        return;
    }

    if (try hook_eval.maybeRun(arena_allocator, io, args, &stdout_writer.interface, &stderr_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        exitIfNonzero(code);
        return;
    }

    if (try maybeRunRewrite(args, &stdout_writer.interface, &stderr_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        exitIfNonzero(code);
        return;
    }

    if (std.mem.eql(u8, args[1], "--explain")) {
        if (args.len < 3) {
            try stderr_writer.interface.writeAll("usage: smll --explain <cmd...>\n");
            try stderr_writer.interface.flush();
            std.process.exit(2);
        }
        const code = try runWrappedAndRecord(
            io,
            environ,
            home,
            args[2..],
            &stdout_writer.interface,
            &stderr_writer.interface,
            .explain,
        );
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        exitIfNonzero(code);
        return;
    }

    if (std.mem.eql(u8, args[1], "--err") or std.mem.eql(u8, args[1], "--test")) {
        const mode: RunMode = if (std.mem.eql(u8, args[1], "--err")) .err else .test_cmd;
        if (args.len < 3) {
            try stderr_writer.interface.writeAll("usage: smll --err <cmd...>\n       smll --test <cmd...>\n");
            try stderr_writer.interface.flush();
            std.process.exit(2);
        }
        const code = try runWrappedAndRecord(
            io,
            environ,
            home,
            args[2..],
            &stdout_writer.interface,
            &stderr_writer.interface,
            mode,
        );
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        exitIfNonzero(code);
        return;
    }

    // Stats display: --stats, --stats --reset
    if (try stats.maybeRun(arena_allocator, io, home, args, &stdout_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        exitIfNonzero(code);
        return;
    }

    // Setup check: only needed with args (--setup, --unsetup, etc.)
    if (try setup.maybeRun(arena_allocator, io, environ, args, &stdout_writer.interface, &stderr_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        exitIfNonzero(code);
        return;
    }

    // Wrapper mode: forward extra args as a child-process invocation.
    // Use the arena-owned argument slice directly so commands with many file
    // operands do not fail before the child process gets a chance to run.
    const child_argv = args[1..];

    const code = try runWrappedAndRecord(
        io,
        environ,
        home,
        child_argv,
        &stdout_writer.interface,
        &stderr_writer.interface,
        .normal,
    );
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    exitIfNonzero(code);
}

fn maybeRunRewrite(args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !?u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[1], "--rewrite")) return null;
    if (args.len < 3) {
        try stderr.writeAll("usage: smll --rewrite <cmd...>\n");
        return 2;
    }
    const child_argv = args[2..];
    const should_wrap = shouldWrapForRewrite(child_argv);
    if (should_wrap) {
        try stdout.writeAll("smll ");
    }
    for (child_argv, 0..) |arg, i| {
        if (i > 0) try stdout.writeByte(' ');
        try writeShellEscaped(stdout, arg);
    }
    try stdout.writeByte('\n');
    return 0;
}

fn shouldWrapForRewrite(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const base = pathBasename(argv[0]);
    if (std.mem.eql(u8, base, "smll")) return false;
    if (!filter_catalog.shouldAutoWrap(base)) return false;
    if (wrapper_util.isStreamingCommand(base, argv)) return false;
    return true;
}

fn pathBasename(path: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, path, '/')) |idx| path[idx + 1 ..] else path;
}

fn writeShellEscaped(stdout: *std.Io.Writer, arg: []const u8) !void {
    if (arg.len == 0) {
        try stdout.writeAll("''");
        return;
    }
    if (isShellSafe(arg)) {
        try stdout.writeAll(arg);
        return;
    }
    try stdout.writeByte('\'');
    for (arg) |c| {
        if (c == '\'') {
            try stdout.writeAll("'\\''");
        } else {
            try stdout.writeByte(c);
        }
    }
    try stdout.writeByte('\'');
}

fn isShellSafe(arg: []const u8) bool {
    for (arg) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        switch (c) {
            '_', '-', '.', '/', ':', '=', ',', '+', '@', '%' => continue,
            else => return false,
        }
    }
    return true;
}

const RunMode = enum {
    normal,
    explain,
    err,
    test_cmd,
};

fn runWrappedAndRecord(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    home: []const u8,
    child_argv: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    mode: RunMode,
) !u8 {
    // Arena over the wrapper lifetime — filter loops allocate per-line and
    // free at scope exit. page_allocator is a syscall per alloc; arena bumps
    // a pointer. Output buffers + per-line ansi.strip buffers both benefit.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var result = try wrapper.run(
        allocator,
        io,
        environ,
        child_argv,
        stdout,
        stderr,
    );
    const duration_ms = elapsedMs(start, io);

    const should_record = result.record_stats and home.len > 0 and !envFlagOn(environ, "DO_NOT_TRACK");
    const recorded = if (should_record) blk: {
        const history_filter_name = try historyFilterName(allocator, mode, result.filter_name);
        break :blk finalizeState(allocator, io, home, child_argv, history_filter_name, duration_ms, &result, stdout);
    } else false;

    if (mode == .explain) {
        const pct = if (result.bytes.raw_bytes > 0)
            (result.bytes.formatting_saved_bytes * 100) / result.bytes.raw_bytes
        else
            0;
        try stderr.print(
            "\n(smll explain: filter={s} raw={d} displayed={d} omitted={d} diagnostics={d} saved={d}% exit={d} history={s})\n",
            .{
                result.filter_name,
                result.bytes.raw_bytes,
                result.bytes.displayed_bytes,
                result.bytes.omitted_bytes,
                result.bytes.diagnostic_bytes,
                pct,
                result.exit_code,
                if (recorded) "recorded" else "not-recorded",
            },
        );
    }

    return result.exit_code;
}

fn finalizeState(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    child_argv: []const []const u8,
    history_filter_name: []const u8,
    duration_ms: u64,
    result: *wrapper.Result,
    stdout: *std.Io.Writer,
) bool {
    var tee_path: ?[]const u8 = null;
    var recorded = false;
    {
        const state_lock = state_io.openStateLock(allocator, io, home) catch return false;
        defer if (state_lock) |file| file.close(io);

        if (result.tee_action != .none) {
            const raw = wrapper.rawOutput();
            tee_path = tee.recordUnderStateLock(
                allocator,
                io,
                home,
                child_argv,
                result.exit_code,
                raw.stdout,
                raw.stderr,
            );
            if (tee_path) |path| {
                if (result.tee_action == .publish_with_breadcrumb) {
                    const breadcrumb_bytes = tee.breadcrumbBytes(path);
                    result.bytes.displayed_bytes += breadcrumb_bytes;
                    result.bytes.diagnostic_bytes += breadcrumb_bytes;
                }
            }
        }

        recorded = stats.recordUnderStateLock(allocator, io, home, child_argv, result.bytes, .{
            .exit_code = result.exit_code,
            .filter_name = history_filter_name,
            .duration_ms = duration_ms,
        });
    }

    // Process output remains outside the shared-state lock. The breadcrumb is
    // emitted only after its matching private log was successfully published.
    if (tee_path) |path| {
        if (result.tee_action == .publish_with_breadcrumb) tee.writeBreadcrumb(stdout, path) catch {};
    }
    return recorded;
}

fn historyFilterName(allocator: std.mem.Allocator, mode: RunMode, filter_name: []const u8) ![]const u8 {
    return switch (mode) {
        .normal, .explain => filter_name,
        .err => try prefixedFilterName(allocator, "err:", filter_name),
        .test_cmd => try prefixedFilterName(allocator, "test:", filter_name),
    };
}

fn prefixedFilterName(allocator: std.mem.Allocator, prefix: []const u8, filter_name: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, prefix.len + filter_name.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], filter_name);
    return out;
}

fn exitIfNonzero(code: u8) void {
    if (code != 0) std.process.exit(code);
}

fn printHelp(stdout: *std.Io.Writer) !void {
    try stdout.writeAll(help_text);
}

fn copyRaw(reader: *std.Io.Reader, writer: *std.Io.Writer) !void {
    var buf: [32768]u8 = undefined;
    while (true) {
        const got = reader.readSliceShort(&buf) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (got == 0) return;
        try writer.writeAll(buf[0..got]);
    }
}

fn stdinIsTty() bool {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        var wsz: std.posix.winsize = undefined;
        const rc = std.os.linux.syscall3(.ioctl, 0, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
        return std.os.linux.errno(rc) == .SUCCESS;
    }
    const rc = std.posix.system.isatty(0);
    return std.posix.errno(rc - 1) == .SUCCESS;
}

fn elapsedMs(start: std.Io.Clock.Timestamp, io: std.Io) u64 {
    const elapsed = start.untilNow(io);
    const ns: i64 = @intCast(elapsed.raw.nanoseconds);
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}
