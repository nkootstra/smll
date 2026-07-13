const std = @import("std");
const builtin = @import("builtin");

pub const drain_poll_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromMilliseconds(25),
    .clock = .awake,
} };
const drain_grace_ns = 500 * std.time.ns_per_ms;

pub const incomplete_output_diagnostic = "(smll: output incomplete; descendants kept stdout/stderr open after child exit)\n";

/// Convert the direct child's termination into the shell-compatible status
/// exposed by every smll execution path. Unix shells report signals as
/// 128 + signal; stopped children use the same convention.
pub fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |signal| @intCast(128 + @intFromEnum(signal)),
        .unknown => 1,
    };
}

pub const CapturedOutput = struct {
    stdout: []const u8,
    stderr: []const u8,
    term: std.process.Child.Term,
    incomplete: bool,
    overflowed: bool,
    input_bytes: usize,
};

pub const ProxiedOutput = struct {
    term: std.process.Child.Term,
    incomplete: bool,
    input_bytes: usize,
};

pub const ChildExitWatcher = struct {
    term: ?std.process.Child.Term = null,
    observed_at: ?std.Io.Clock.Timestamp = null,
    reaped: bool = false,

    pub fn poll(self: *ChildExitWatcher, child: *std.process.Child, io: std.Io) !void {
        if (self.term != null) return;
        if (try pollDirectChild(child)) |term| {
            self.term = term;
            self.observed_at = .now(io, .awake);
            self.reaped = true;
        }
    }

    pub fn graceExpired(self: ChildExitWatcher, io: std.Io) bool {
        const observed_at = self.observed_at orelse return false;
        return observed_at.untilNow(io).raw.nanoseconds >= drain_grace_ns;
    }

    pub fn finish(self: ChildExitWatcher, child: *std.process.Child, io: std.Io) !std.process.Child.Term {
        return self.term orelse try child.wait(io);
    }
};

/// Pipe both child output streams through smll without buffering for filters.
/// This preserves exact bytes while still bounding descendant-held pipes.
pub fn proxyChildOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !ProxiedOutput {
    const result = try drainChildOutput(allocator, io, child, 0, stdout, stderr);
    if (!result.overflowed) {
        try stdout.writeAll(result.stdout);
        try stderr.writeAll(result.stderr);
    }
    return .{
        .term = result.term,
        .incomplete = result.incomplete,
        .input_bytes = result.input_bytes,
    };
}

/// Concurrently drain child stdout and stderr. Reading one pipe to EOF before
/// the other can deadlock when the child writes more than the kernel pipe
/// buffer to stderr while stdout stays open.
pub fn drainChildOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    child: *std.process.Child,
    max_output_bytes: usize,
    raw_stdout: *std.Io.Writer,
    raw_stderr: *std.Io.Writer,
) !CapturedOutput {
    var watcher: ChildExitWatcher = .{};
    defer if (watcher.reaped) closeChildPipes(child, io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        allocator,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    var incomplete = false;
    var overflowed = false;
    var input_bytes: usize = 0;
    while (true) {
        multi_reader.fill(64, drain_poll_timeout) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {},
            else => |e| return e,
        };

        if (!overflowed and
            (stdout_reader.buffered().len >= max_output_bytes or
                stderr_reader.buffered().len >= max_output_bytes))
        {
            overflowed = true;
        }
        if (overflowed) {
            input_bytes += try flushBuffered(stdout_reader, raw_stdout);
            input_bytes += try flushBuffered(stderr_reader, raw_stderr);
        }

        try watcher.poll(child, io);
        if (watcher.graceExpired(io)) {
            incomplete = true;
            break;
        }
    }

    if (!incomplete) try multi_reader.checkAnyError();

    if (overflowed) {
        input_bytes += try flushBuffered(stdout_reader, raw_stdout);
        input_bytes += try flushBuffered(stderr_reader, raw_stderr);
    }

    const stdout_slice: []const u8 = if (overflowed)
        &.{}
    else if (incomplete)
        try allocator.dupe(u8, stdout_reader.buffered())
    else
        try multi_reader.toOwnedSlice(0);
    errdefer if (!overflowed) allocator.free(stdout_slice);
    const stderr_slice: []const u8 = if (overflowed)
        &.{}
    else if (incomplete)
        try allocator.dupe(u8, stderr_reader.buffered())
    else
        try multi_reader.toOwnedSlice(1);

    if (!overflowed) input_bytes = stdout_slice.len + stderr_slice.len;

    const direct_term = try watcher.finish(child, io);

    return .{
        .stdout = stdout_slice,
        .stderr = stderr_slice,
        .term = direct_term,
        .incomplete = incomplete,
        .overflowed = overflowed,
        .input_bytes = input_bytes,
    };
}

fn flushBuffered(reader: *std.Io.Reader, writer: *std.Io.Writer) !usize {
    const bytes = reader.buffered();
    if (bytes.len == 0) return 0;
    try writer.writeAll(bytes);
    reader.tossBuffered();
    return bytes.len;
}

fn pollDirectChild(child: *std.process.Child) !?std.process.Child.Term {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return null;
    if (child.id == null) return null;

    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const result = std.posix.system.waitpid(child.id.?, &status, std.posix.W.NOHANG);
        switch (std.posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return null;
                child.id = null;
                return statusToTerm(@bitCast(status));
            },
            .INTR => continue,
            else => return error.UnexpectedWaitFailure,
        }
    }
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}

pub fn closeChildPipes(child: *std.process.Child, io: std.Io) void {
    if (child.stdout) |stdout| {
        stdout.close(io);
        child.stdout = null;
    }
    if (child.stderr) |stderr| {
        stderr.close(io);
        child.stderr = null;
    }
}

/// Write stdout + stderr passthrough. Used as error fallback in filter dispatch.
pub noinline fn passthrough(writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, stdout_slice: []const u8, stderr_slice: []const u8) void {
    writer.writeAll(stdout_slice) catch {};
    stderr_writer.writeAll(stderr_slice) catch {};
}

pub const FilterFn = *const fn (std.mem.Allocator, []const u8, []const u8, *std.Io.Writer) anyerror!void;

pub fn applyFilter(
    apply: FilterFn,
    allocator: std.mem.Allocator,
    stdout_slice: []const u8,
    stderr_slice: []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) bool {
    return applyFilterOwned(apply, .filter, allocator, stdout_slice, stderr_slice, writer, stderr_writer);
}

pub const StderrOwnership = enum {
    /// The filter receives stderr and renders every retained diagnostic.
    filter,
    /// The filter receives no stderr; the wrapper forwards raw stderr once.
    caller,
};

pub fn applyFilterOwned(
    apply: FilterFn,
    stderr_ownership: StderrOwnership,
    allocator: std.mem.Allocator,
    stdout_slice: []const u8,
    stderr_slice: []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) bool {
    var compact = std.Io.Writer.Allocating.init(allocator);
    defer compact.deinit();
    const filter_stderr = if (stderr_ownership == .filter) stderr_slice else &.{};
    apply(allocator, stdout_slice, filter_stderr, &compact.writer) catch {
        passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        return false;
    };
    writer.writeAll(compact.written()) catch return false;
    if (stderr_ownership == .caller) stderr_writer.writeAll(stderr_slice) catch return false;
    return true;
}

pub const CountingWriter = struct {
    out: *std.Io.Writer,
    count: usize = 0,
    writer: std.Io.Writer = .{
        .buffer = &.{},
        .vtable = &.{ .drain = drain, .flush = flush },
    },

    pub fn init(out: *std.Io.Writer) CountingWriter {
        return .{ .out = out };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *CountingWriter = @fieldParentPtr("writer", w);
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.out.writeAll(bytes);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.out.writeAll(pattern);
            written += pattern.len;
        }
        self.count += written;
        w.end = 0;
        return written;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *CountingWriter = @fieldParentPtr("writer", w);
        try self.out.flush();
        w.end = 0;
    }
};

test "applyFilter discards partial compact output and writes raw streams once on failure" {
    const Failing = struct {
        fn apply(_: std.mem.Allocator, _: []const u8, _: []const u8, writer: *std.Io.Writer) !void {
            try writer.writeAll("partial compact\n");
            return error.BadFilter;
        }
    };

    var stdout = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer stderr.deinit();
    try std.testing.expect(!applyFilter(
        Failing.apply,
        std.testing.allocator,
        "raw out\n",
        "raw err\n",
        &stdout.writer,
        &stderr.writer,
    ));
    try std.testing.expectEqualStrings("raw out\n", stdout.written());
    try std.testing.expectEqualStrings("raw err\n", stderr.written());
}

test "exitCode maps Unix signals and stopped children to shell status" {
    try std.testing.expectEqual(@as(u8, 23), exitCode(.{ .exited = 23 }));
    try std.testing.expectEqual(@as(u8, 143), exitCode(.{ .signal = .TERM }));
    const stop_status: u8 = @intCast(128 + @intFromEnum(std.posix.SIG.STOP));
    try std.testing.expectEqual(stop_status, exitCode(.{ .stopped = .STOP }));
}
