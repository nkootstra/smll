const std = @import("std");
const pipeline = @import("pipeline.zig");
const git_status = @import("git_status");
const git_diff = @import("git_diff");
const git_log = @import("git_log");
const git_show = @import("git_show");

const Filters = .{ git_status, git_show, git_log, git_diff };

test {
    _ = pipeline;
}

pub fn main() !void {
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);

    // Fast path: no extra argv → stdin mode. Skip the page_allocator,
    // argsWithAllocator iterator, and ArrayList entirely. std.os.argv is
    // already populated by the runtime; len 1 = program name only.
    if (std.os.argv.len <= 1) {
        var in_buf: [4096]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&in_buf);
        try pipeline.run(
            std.heap.page_allocator,
            &stdin_reader.interface,
            &stdout_writer.interface,
            Filters,
        );
        try stdout_writer.interface.flush();
        return;
    }

    // Wrapper mode: forward extra args as a child-process invocation.
    // Build the slice from std.os.argv on the stack — no ArrayList growth
    // and no iterator allocation. 32 args is well above any realistic
    // `git <subcmd> <args...>` invocation.
    var argv_buf: [32][]const u8 = undefined;
    const argv_count = std.os.argv.len - 1;
    if (argv_count > argv_buf.len) return error.TooManyArgs;
    for (std.os.argv[1..], 0..) |arg, i| {
        argv_buf[i] = std.mem.span(arg);
    }

    const allocator = std.heap.page_allocator;
    const code = try runWrapper(allocator, argv_buf[0..argv_count], &stdout_writer.interface);
    try stdout_writer.interface.flush();
    if (code != 0) std.process.exit(code);
}

// Maximum bytes captured from child stdout + stderr combined.
// 2 MiB matches the integration test cap and accommodates large git outputs.
const MAX_OUTPUT_BYTES: usize = 2 * 1024 * 1024;

// All 15 R4 git subcommands.  Phase 2 fills in the remaining 11; for now
// only the 4 v0.3 filters (status, diff, log, show) are wired — the other
// 11 arms fall through to passthrough.
const KnownSubcommand = enum {
    status,
    diff,
    log,
    show,
    add,
    commit,
    push,
    pull,
    fetch,
    merge,
    rebase,
    stash,
    checkout,
    branch,
    blame,
    unknown,
};

fn runWrapper(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    writer: *std.Io.Writer,
) !u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Concurrently drain both stdout and stderr into heap-backed ArrayLists.
    // collectOutput uses std.Io.poll so neither pipe can deadlock the other.
    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    child.collectOutput(allocator, &stdout_list, &stderr_list, MAX_OUTPUT_BYTES) catch |err| switch (err) {
        // collectOutput signals cap exceeded via stream-too-long errors.
        error.StdoutStreamTooLong, error.StderrStreamTooLong => {
            _ = child.wait() catch {};
            const msg = "smll: child output exceeded 2 MiB cap\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            return 1;
        },
        else => return err,
    };

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        .Signal, .Stopped, .Unknown => 1,
    };

    const stdout_slice = stdout_list.items;
    const stderr_slice = stderr_list.items;

    // Argv guard: only dispatch through the formatter switch when the outer
    // command is literally "git".  Any other outer command (e.g. "cargo")
    // goes straight to passthrough even if the subcommand string matches a
    // KnownSubcommand.
    const outer_cmd = argv[0];
    // Strip any directory prefix: "git", "/usr/bin/git", etc. all match.
    const cmd_basename = if (std.mem.lastIndexOfScalar(u8, outer_cmd, '/')) |idx|
        outer_cmd[idx + 1 ..]
    else
        outer_cmd;

    if (!std.mem.eql(u8, cmd_basename, "git") or argv.len < 2) {
        // Non-git outer command: passthrough both streams verbatim.
        try writer.writeAll(stdout_slice);
        try std.fs.File.stderr().writeAll(stderr_slice);
        return exit_code;
    }

    // argv[1] is the git subcommand (e.g. "status", "diff").
    const subcmd_str = argv[1];
    const subcmd = std.meta.stringToEnum(KnownSubcommand, subcmd_str) orelse .unknown;

    switch (subcmd) {
        .status => {
            git_status.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                // Formatter-error policy: emit raw stdout as fail-open, exit non-zero.
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .diff => {
            git_diff.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .log => {
            git_log.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .show => {
            git_show.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        // Phase 2 formatters (Units 4-7) will replace these passthrough arms.
        .add, .commit, .push, .pull, .fetch, .merge, .rebase, .stash, .checkout, .branch, .blame, .unknown => {
            try writer.writeAll(stdout_slice);
            try std.fs.File.stderr().writeAll(stderr_slice);
        },
    }

    return exit_code;
}
