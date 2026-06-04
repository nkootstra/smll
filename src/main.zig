const std = @import("std");
const build_options = @import("build_options");
pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};
const pipe_filters = @import("pipe_filters.zig");
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

    const home = environ.get("HOME") orelse "";

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

    // Arena over the wrapper lifetime — filter loops allocate per-line and
    // free at scope exit. page_allocator is a syscall per alloc; arena bumps
    // a pointer. Output buffers + per-line ansi.strip buffers both benefit.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try wrapper.run(
        allocator,
        io,
        environ,
        child_argv,
        &stdout_writer.interface,
        &stderr_writer.interface,
    );
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();

    // Record stats (best-effort, never fails the command). Respect the
    // conventional DO_NOT_TRACK opt-out even though stats are local-only.
    if (result.record_stats and home.len > 0 and !envFlagOn(environ, "DO_NOT_TRACK")) {
        stats.record(allocator, io, home, child_argv, result.input_bytes, result.output_bytes);
    }

    if (result.exit_code != 0) std.c._exit(result.exit_code);
}
