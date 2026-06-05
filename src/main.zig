const std = @import("std");
const build_options = @import("build_options");
pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};
const pipe_filters = @import("pipe_filters.zig");
const filter_catalog = @import("filter_catalog.zig");
const pipeline = @import("pipeline.zig");
const stats = @import("stats.zig");
const wrapper = @import("wrapper.zig");
const wrapper_util = @import("wrapper_util.zig");
const git_status = @import("git_status");
const git_diff = @import("git_diff");
const git_show = @import("git_show");
const git_commit = @import("git_commit");
const git_merge = @import("git_merge");
const git_branch = @import("git_branch");
const git_reflog = @import("git_reflog");
const git_blame = @import("git_blame");
const tree = @import("tree");
const docker_compact = @import("docker_compact");
const ls_compact = @import("ls_compact");
const kubectl_compact = @import("kubectl_compact");
const cargo_test = @import("cargo_test");
const pytest = @import("pytest");
const jest = @import("jest");
const tsc = @import("tsc");
const go_test = @import("go_test");
const npm_install = @import("npm_install");
const setup = @import("setup.zig");

// git_branch is included in Filters because it pipe-matches (branch list output
// is stable and identifiable by leading "  " or "* " prefix). It is positioned
// after git_status and before git_show — the branch output shape is distinct from
// both. git_checkout is NOT in Filters because its matches() always returns false.
const Filters = .{ git_status, git_branch, git_reflog, git_show, GitLogCompact, git_diff, git_commit, git_merge, git_blame, cargo_test, jest, tsc, go_test, pytest, kubectl_compact, docker_compact, npm_install, tree, ls_compact, FindCompactPipe, DuCompactPipe, CurlCompactPipe, GenericCompactPipe };

// rg filter is wrapper-mode only (`smll rg --files src/`). Its output grammar
// overlaps too many non-rg tools in pipe mode (diff stats, generic listings),
// so auto-detection via matches() produces false positives and breaks the
// lossless contract for those other tools.

test {
    _ = pipe_filters;
    _ = pipeline;
    _ = wrapper;
    _ = wrapper_util;
}

const FindCompactPipe = pipe_filters.FindCompactPipe;
const DuCompactPipe = pipe_filters.DuCompactPipe;
const CurlCompactPipe = pipe_filters.CurlCompactPipe;
const GenericCompactPipe = pipe_filters.GenericCompactPipe;
const GitLogCompact = pipe_filters.GitLogCompact;
const envFlagOn = wrapper_util.envFlagOn;

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

    // Fast path: no extra argv → stdin mode. Skip setup check and
    // wrapper-mode arena init entirely. Use a larger output buffer
    // to reduce write syscalls for large passthrough data.
    if (args.len <= 1) {
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

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try stdout_writer.interface.print("smll {s}\n", .{build_options.smll_version});
        try stdout_writer.interface.flush();
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--filters")) {
        try stdout_writer.interface.writeAll(filter_catalog.text);
        try stdout_writer.interface.flush();
        return;
    }

    const home = environ.get("HOME") orelse "";

    if (try maybeRunRewrite(args, &stdout_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        if (code != 0) std.c._exit(code);
        return;
    }

    if (std.mem.eql(u8, args[1], "--explain")) {
        if (args.len < 3) {
            try stderr_writer.interface.writeAll("usage: smll --explain <cmd...>\n");
            try stderr_writer.interface.flush();
            std.c._exit(2);
        }
        const code = try runWrappedAndRecord(
            io,
            environ,
            home,
            args[2..],
            &stdout_writer.interface,
            &stderr_writer.interface,
            true,
        );
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        if (code != 0) std.c._exit(code);
        return;
    }

    if (std.mem.eql(u8, args[1], "--err") or std.mem.eql(u8, args[1], "--test")) {
        if (args.len < 3) {
            try stderr_writer.interface.writeAll("usage: smll --err <cmd...>\n       smll --test <cmd...>\n");
            try stderr_writer.interface.flush();
            std.c._exit(2);
        }
        const code = try runWrappedAndRecord(
            io,
            environ,
            home,
            args[2..],
            &stdout_writer.interface,
            &stderr_writer.interface,
            false,
        );
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        if (code != 0) std.c._exit(code);
        return;
    }

    // Stats display: --stats, --stats --reset
    if (try stats.maybeRun(arena_allocator, io, home, args, &stdout_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        if (code != 0) std.c._exit(code);
        return;
    }

    // Setup check: only needed with args (--setup, --unsetup, etc.)
    if (try setup.maybeRun(arena_allocator, io, environ, args, &stdout_writer.interface, &stderr_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        if (code != 0) std.c._exit(code);
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
        false,
    );
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    if (code != 0) std.c._exit(code);
}

fn maybeRunRewrite(args: []const []const u8, stdout: *std.Io.Writer) !?u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[1], "--rewrite")) return null;
    if (args.len < 3) {
        try stdout.writeAll("usage: smll --rewrite <cmd...>\n");
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

fn runWrappedAndRecord(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    home: []const u8,
    child_argv: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    explain: bool,
) !u8 {
    // Arena over the wrapper lifetime — filter loops allocate per-line and
    // free at scope exit. page_allocator is a syscall per alloc; arena bumps
    // a pointer. Output buffers + per-line ansi.strip buffers both benefit.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    const result = try wrapper.run(
        allocator,
        io,
        environ,
        child_argv,
        stdout,
        stderr,
    );
    const duration_ms = elapsedMs(start, io);

    const recorded = result.record_stats and home.len > 0 and !envFlagOn(environ, "DO_NOT_TRACK");
    if (recorded) {
        stats.record(allocator, io, home, child_argv, result.input_bytes, result.output_bytes, .{
            .exit_code = result.exit_code,
            .filter_name = result.filter_name,
            .duration_ms = duration_ms,
        });
    }

    if (explain) {
        const saved = if (result.input_bytes > result.output_bytes) result.input_bytes - result.output_bytes else 0;
        const pct = if (result.input_bytes > 0) (saved * 100) / result.input_bytes else 0;
        try stderr.print(
            "\n(smll explain: filter={s} raw={d} compact={d} saved={d}% exit={d} history={s})\n",
            .{
                result.filter_name,
                result.input_bytes,
                result.output_bytes,
                pct,
                result.exit_code,
                if (recorded) "recorded" else "not-recorded",
            },
        );
    }

    return result.exit_code;
}

fn elapsedMs(start: std.Io.Clock.Timestamp, io: std.Io) u64 {
    const elapsed = start.untilNow(io);
    const ns: i128 = elapsed.raw.nanoseconds;
    if (ns <= 0) return 0;
    return @intCast(@divTrunc(ns, std.time.ns_per_ms));
}
