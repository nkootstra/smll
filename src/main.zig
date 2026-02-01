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

fn runWrapper(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    writer: *std.Io.Writer,
) !u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    // Read child stdout into a 16 KiB stack buffer first. Real `git status`,
    // `git diff`, `git log`, and `git show` outputs comfortably fit; only
    // pathological cases overflow into the heap path. Mirrors pipeline.run.
    var stack_buf: [16 * 1024]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    var child_reader = child.stdout.?.reader(&read_buf);
    var total: usize = 0;
    while (total < stack_buf.len) {
        const got = try child_reader.interface.readSliceShort(stack_buf[total..]);
        if (got == 0) break;
        total += got;
    }

    if (total < stack_buf.len) {
        try pipeline.dispatch(allocator, stack_buf[0..total], writer, Filters);
        const term = try child.wait();
        return switch (term) {
            .Exited => |c| c,
            .Signal, .Stopped, .Unknown => 1,
        };
    }

    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();
    try allocating.writer.writeAll(&stack_buf);
    _ = child_reader.interface.streamRemaining(&allocating.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return err,
    };

    const term = try child.wait();
    try pipeline.dispatch(allocator, allocating.written(), writer, Filters);

    return switch (term) {
        .Exited => |c| c,
        .Signal, .Stopped, .Unknown => 1,
    };
}
