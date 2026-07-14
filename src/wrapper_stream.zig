const std = @import("std");

const ansi = @import("ansi");
const docker_logs = @import("docker_logs");
const jest = @import("jest");
const tsc = @import("tsc");
const wrapper_io = @import("wrapper_io.zig");
const wrapper_util = @import("wrapper_util.zig");
const exitCode = wrapper_io.exitCode;

const max_line_bytes: usize = 64 * 1024;
const idle_flush_ns = 2 * std.time.ns_per_s;

pub const Result = struct {
    exit_code: u8,
    input_bytes: usize,
    filter_name: []const u8,
};

const LineAssembler = struct {
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *LineAssembler, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    fn feed(
        self: *LineAssembler,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        processor: LineProcessor,
        writer: *std.Io.Writer,
    ) !void {
        var start: usize = 0;
        for (bytes, 0..) |c, i| {
            if (c != '\n') continue;
            try self.buf.appendSlice(allocator, bytes[start..i]);
            try processor.feedLine(self.buf.items, writer);
            self.buf.clearRetainingCapacity();
            start = i + 1;
        }
        if (start < bytes.len) {
            try self.buf.appendSlice(allocator, bytes[start..]);
            if (self.buf.items.len >= max_line_bytes) {
                try processor.feedLine(self.buf.items, writer);
                self.buf.clearRetainingCapacity();
            }
        }
    }

    fn flush(
        self: *LineAssembler,
        processor: LineProcessor,
        writer: *std.Io.Writer,
    ) !void {
        if (self.buf.items.len == 0) return;
        try processor.feedLine(self.buf.items, writer);
        self.buf.clearRetainingCapacity();
    }
};

const LineProcessor = struct {
    ptr: *anyopaque,
    feed_line_fn: *const fn (*anyopaque, []const u8, *std.Io.Writer) anyerror!void,

    fn init(comptime T: type, processor: *T) LineProcessor {
        const Adapter = struct {
            fn feedLine(ptr: *anyopaque, line: []const u8, writer: *std.Io.Writer) !void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                try typed.feedLine(line, writer);
            }
        };
        return .{ .ptr = processor, .feed_line_fn = Adapter.feedLine };
    }

    fn feedLine(self: LineProcessor, line: []const u8, writer: *std.Io.Writer) !void {
        try self.feed_line_fn(self.ptr, line, writer);
    }
};

const StreamSide = struct {
    ptr: *anyopaque,
    feed_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8, *std.Io.Writer) anyerror!void,
    idle_flush_fn: *const fn (*anyopaque, *std.Io.Writer) anyerror!void,
    end_flush_fn: *const fn (*anyopaque, *std.Io.Writer) anyerror!void,

    fn init(comptime T: type, side: *T) StreamSide {
        const Adapter = struct {
            fn feed(ptr: *anyopaque, allocator: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                try typed.feed(allocator, bytes, writer);
            }

            fn idleFlush(ptr: *anyopaque, writer: *std.Io.Writer) !void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                try typed.idleFlush(writer);
            }

            fn endFlush(ptr: *anyopaque, writer: *std.Io.Writer) !void {
                const typed: *T = @ptrCast(@alignCast(ptr));
                try typed.endFlush(writer);
            }
        };
        return .{
            .ptr = side,
            .feed_fn = Adapter.feed,
            .idle_flush_fn = Adapter.idleFlush,
            .end_flush_fn = Adapter.endFlush,
        };
    }

    fn feed(self: StreamSide, allocator: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
        try self.feed_fn(self.ptr, allocator, bytes, writer);
    }

    fn idleFlush(self: StreamSide, writer: *std.Io.Writer) !void {
        try self.idle_flush_fn(self.ptr, writer);
    }

    fn endFlush(self: StreamSide, writer: *std.Io.Writer) !void {
        try self.end_flush_fn(self.ptr, writer);
    }
};

const LogStreamSide = struct {
    assembler: LineAssembler = .{},
    deduper: docker_logs.StreamDeduper,

    fn init(allocator: std.mem.Allocator, mode: docker_logs.Mode) LogStreamSide {
        return .{ .deduper = docker_logs.StreamDeduper.init(allocator, mode) };
    }

    fn deinit(self: *LogStreamSide, allocator: std.mem.Allocator) void {
        self.assembler.deinit(allocator);
        self.deduper.deinit();
    }

    fn feed(self: *LogStreamSide, allocator: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
        try self.assembler.feed(allocator, bytes, LineProcessor.init(LogStreamSide, self), writer);
    }

    fn feedLine(self: *LogStreamSide, raw: []const u8, writer: *std.Io.Writer) !void {
        try self.deduper.feedLine(raw, writer, true);
    }

    fn idleFlush(self: *LogStreamSide, writer: *std.Io.Writer) !void {
        try self.deduper.flush(writer, true);
    }

    fn endFlush(self: *LogStreamSide, writer: *std.Io.Writer) !void {
        try self.assembler.flush(LineProcessor.init(LogStreamSide, self), writer);
        try self.deduper.flush(writer, true);
    }
};

const TscWatchSide = struct {
    allocator: std.mem.Allocator,
    assembler: LineAssembler = .{},
    strip_buf: std.ArrayList(u8) = .empty,
    clean_emitted: bool = false,

    fn init(allocator: std.mem.Allocator) TscWatchSide {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TscWatchSide, allocator: std.mem.Allocator) void {
        self.assembler.deinit(allocator);
        self.strip_buf.deinit(allocator);
    }

    fn feed(self: *TscWatchSide, allocator: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
        try self.assembler.feed(allocator, bytes, LineProcessor.init(TscWatchSide, self), writer);
    }

    fn feedLine(self: *TscWatchSide, raw: []const u8, writer: *std.Io.Writer) !void {
        switch (try tsc.writeWatchLine(&self.strip_buf, self.allocator, raw, writer)) {
            .ignored => {},
            .emitted => self.clean_emitted = false,
            .clean => {
                if (!self.clean_emitted) {
                    try writer.writeAll("clean (0 errors)\n");
                    self.clean_emitted = true;
                }
            },
        }
    }

    fn idleFlush(_: *TscWatchSide, _: *std.Io.Writer) !void {}

    fn endFlush(self: *TscWatchSide, writer: *std.Io.Writer) !void {
        try self.assembler.flush(LineProcessor.init(TscWatchSide, self), writer);
    }
};

const JestWatchSide = struct {
    allocator: std.mem.Allocator,
    assembler: LineAssembler = .{},
    frame: std.ArrayList(u8) = .empty,
    last_emitted: std.ArrayList(u8) = .empty,

    fn init(allocator: std.mem.Allocator) JestWatchSide {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *JestWatchSide, allocator: std.mem.Allocator) void {
        self.assembler.deinit(allocator);
        self.frame.deinit(allocator);
        self.last_emitted.deinit(allocator);
    }

    fn feed(self: *JestWatchSide, allocator: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
        try self.assembler.feed(allocator, bytes, LineProcessor.init(JestWatchSide, self), writer);
    }

    fn feedLine(self: *JestWatchSide, raw: []const u8, writer: *std.Io.Writer) !void {
        const line = if (clearFrameIndex(raw)) |idx| blk: {
            try self.flushFrame(writer);
            break :blk raw[idx..];
        } else raw;

        try self.frame.appendSlice(self.allocator, line);
        try self.frame.append(self.allocator, '\n');
    }

    fn idleFlush(self: *JestWatchSide, writer: *std.Io.Writer) !void {
        try self.flushFrame(writer);
    }

    fn endFlush(self: *JestWatchSide, writer: *std.Io.Writer) !void {
        try self.assembler.flush(LineProcessor.init(JestWatchSide, self), writer);
        try self.flushFrame(writer);
    }

    fn flushFrame(self: *JestWatchSide, writer: *std.Io.Writer) !void {
        if (self.frame.items.len == 0) return;
        defer self.frame.clearRetainingCapacity();
        if (!jest.matches(self.frame.items)) return;

        var compact = std.Io.Writer.Allocating.init(self.allocator);
        defer compact.deinit();
        try jest.apply(self.allocator, self.frame.items, &.{}, &compact.writer);
        const rendered = compact.written();
        if (rendered.len == 0 or std.mem.eql(u8, rendered, self.last_emitted.items)) return;

        try writer.writeAll(rendered);
        self.last_emitted.clearRetainingCapacity();
        try self.last_emitted.appendSlice(self.allocator, rendered);
    }
};

const JobWatchState = enum {
    queued,
    running,
    passed,
    failed,
    skipped,

    fn label(self: JobWatchState) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .passed => "passed",
            .failed => "failed",
            .skipped => "skipped",
        };
    }
};

const JobState = struct {
    name: []u8,
    state: JobWatchState,
};

const ParsedJob = struct {
    name: []const u8,
    state: JobWatchState,
};

const GhRunWatchSide = struct {
    allocator: std.mem.Allocator,
    assembler: LineAssembler = .{},
    strip_buf: std.ArrayList(u8) = .empty,
    raw_fallback: std.ArrayList(u8) = .empty,
    pending_name: std.ArrayList(u8) = .empty,
    pending_state: ?JobWatchState = null,
    pending_has_steps: bool = false,
    last_states: std.ArrayList(JobState) = .empty,
    saw_jobs: bool = false,
    in_jobs: bool = false,

    fn init(allocator: std.mem.Allocator) GhRunWatchSide {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *GhRunWatchSide, allocator: std.mem.Allocator) void {
        self.assembler.deinit(allocator);
        self.strip_buf.deinit(allocator);
        self.raw_fallback.deinit(allocator);
        self.pending_name.deinit(allocator);
        for (self.last_states.items) |entry| allocator.free(entry.name);
        self.last_states.deinit(allocator);
    }

    fn feed(self: *GhRunWatchSide, allocator: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
        try self.assembler.feed(allocator, bytes, LineProcessor.init(GhRunWatchSide, self), writer);
    }

    fn feedLine(self: *GhRunWatchSide, raw: []const u8, writer: *std.Io.Writer) !void {
        const clean = ansi.stripInto(&self.strip_buf, self.allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, "\r");
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.eql(u8, trimmed, "JOBS")) {
            try self.flushPending(writer);
            self.saw_jobs = true;
            self.in_jobs = true;
            self.raw_fallback.clearRetainingCapacity();
            return;
        }

        if (!self.saw_jobs) {
            try self.appendFallback(line);
            return;
        }

        if (!self.in_jobs) return;

        if (trimmed.len == 0 or isRunWatchSection(trimmed)) {
            try self.flushPending(writer);
            self.in_jobs = false;
            return;
        }

        if (parseRunWatchJob(line)) |job| {
            try self.flushPending(writer);
            self.pending_name.clearRetainingCapacity();
            try self.pending_name.appendSlice(self.allocator, job.name);
            self.pending_state = job.state;
            self.pending_has_steps = false;
            return;
        }

        if (isRunWatchStep(line)) {
            self.pending_has_steps = true;
            return;
        }

        try self.flushPending(writer);
        self.in_jobs = false;
    }

    fn idleFlush(self: *GhRunWatchSide, writer: *std.Io.Writer) !void {
        try self.flushPending(writer);
    }

    fn endFlush(self: *GhRunWatchSide, writer: *std.Io.Writer) !void {
        try self.assembler.flush(LineProcessor.init(GhRunWatchSide, self), writer);
        try self.flushPending(writer);
        if (!self.saw_jobs) try writer.writeAll(self.raw_fallback.items);
    }

    fn appendFallback(self: *GhRunWatchSide, line: []const u8) !void {
        if (line.len == 0 and self.raw_fallback.items.len == 0) return;
        try self.raw_fallback.appendSlice(self.allocator, line);
        try self.raw_fallback.append(self.allocator, '\n');
    }

    fn flushPending(self: *GhRunWatchSide, writer: *std.Io.Writer) !void {
        const pending = self.pending_state orelse return;
        defer {
            self.pending_state = null;
            self.pending_has_steps = false;
            self.pending_name.clearRetainingCapacity();
        }
        const state: JobWatchState = if (pending == .queued and self.pending_has_steps) .running else pending;
        try self.emitTransition(self.pending_name.items, state, writer);
    }

    fn emitTransition(self: *GhRunWatchSide, name: []const u8, state: JobWatchState, writer: *std.Io.Writer) !void {
        for (self.last_states.items) |*entry| {
            if (!std.mem.eql(u8, entry.name, name)) continue;
            if (entry.state == state) return;
            try writer.print("{s}: {s}->{s}\n", .{ name, entry.state.label(), state.label() });
            entry.state = state;
            return;
        }

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.last_states.append(self.allocator, .{ .name = owned_name, .state = state });
        try writer.print("{s}: {s}\n", .{ name, state.label() });
    }
};

pub fn runStreamFilter(
    allocator: std.mem.Allocator,
    io: std.Io,
    original_argv: []const []const u8,
    logical_argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !Result {
    const cmd = commandBasename(logical_argv) orelse "";
    if (wrapper_util.isTscWatch(cmd, logical_argv)) {
        return runTscWatch(allocator, io, original_argv, writer, stderr_writer);
    }
    if (wrapper_util.isJsTestWatch(cmd, logical_argv)) {
        return runJestWatch(allocator, io, original_argv, writer, stderr_writer);
    }
    if (wrapper_util.isGhRunWatch(cmd, logical_argv)) {
        return runGhRunWatch(allocator, io, original_argv, writer, stderr_writer);
    }
    return runFollowLogs(allocator, io, original_argv, logical_argv, writer, stderr_writer);
}

pub fn runFollowLogs(
    allocator: std.mem.Allocator,
    io: std.Io,
    original_argv: []const []const u8,
    logical_argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !Result {
    const mode: docker_logs.Mode = if (isComposeInvocation(logical_argv)) .compose else .plain;
    var stdout_side = LogStreamSide.init(allocator, mode);
    defer stdout_side.deinit(allocator);
    var stderr_side = LogStreamSide.init(allocator, mode);
    defer stderr_side.deinit(allocator);
    return runPipedStream(allocator, io, original_argv, writer, stderr_writer, StreamSide.init(LogStreamSide, &stdout_side), StreamSide.init(LogStreamSide, &stderr_side), if (isDockerInvocation(logical_argv)) "stream:docker_logs" else "stream:logs");
}

fn runTscWatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !Result {
    var stdout_side = TscWatchSide.init(allocator);
    defer stdout_side.deinit(allocator);
    var stderr_side = TscWatchSide.init(allocator);
    defer stderr_side.deinit(allocator);
    return runPipedStream(allocator, io, argv, writer, stderr_writer, StreamSide.init(TscWatchSide, &stdout_side), StreamSide.init(TscWatchSide, &stderr_side), "stream:tsc_watch");
}

fn runJestWatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !Result {
    var stdout_side = JestWatchSide.init(allocator);
    defer stdout_side.deinit(allocator);
    var stderr_side = JestWatchSide.init(allocator);
    defer stderr_side.deinit(allocator);
    return runPipedStream(allocator, io, argv, writer, stderr_writer, StreamSide.init(JestWatchSide, &stdout_side), StreamSide.init(JestWatchSide, &stderr_side), "stream:js_test_watch");
}

fn runGhRunWatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !Result {
    var stdout_side = GhRunWatchSide.init(allocator);
    defer stdout_side.deinit(allocator);
    var stderr_side = GhRunWatchSide.init(allocator);
    defer stderr_side.deinit(allocator);
    return runPipedStream(allocator, io, argv, writer, stderr_writer, StreamSide.init(GhRunWatchSide, &stdout_side), StreamSide.init(GhRunWatchSide, &stderr_side), "stream:gh_run_watch");
}

fn runPipedStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    stdout_side: StreamSide,
    stderr_side: StreamSide,
    filter_name: []const u8,
) !Result {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return err;
    defer child.kill(io);

    var watcher: wrapper_io.ChildExitWatcher = .{};
    defer if (watcher.reaped) wrapper_io.closeChildPipes(&child, io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        allocator,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();

    var input_bytes: usize = 0;
    var incomplete = false;
    var last_activity: std.Io.Clock.Timestamp = .now(io, .awake);
    while (true) {
        var received_data = true;
        multi_reader.fill(64, wrapper_io.drain_poll_timeout) catch |err| switch (err) {
            error.Timeout => {
                received_data = false;
            },
            error.EndOfStream => break,
            else => |e| return e,
        };

        if (received_data) {
            input_bytes += try drainAvailable(&multi_reader, 0, stdout_side, allocator, writer);
            input_bytes += try drainAvailable(&multi_reader, 1, stderr_side, allocator, writer);
            try writer.flush();
            last_activity = .now(io, .awake);
        } else if (last_activity.untilNow(io).raw.nanoseconds >= idle_flush_ns) {
            try stdout_side.idleFlush(writer);
            try stderr_side.idleFlush(writer);
            try writer.flush();
            last_activity = .now(io, .awake);
        }

        try watcher.poll(&child, io);
        if (watcher.graceExpired(io)) {
            incomplete = true;
            break;
        }
    }
    if (!incomplete) try multi_reader.checkAnyError();

    input_bytes += try drainAvailable(&multi_reader, 0, stdout_side, allocator, writer);
    input_bytes += try drainAvailable(&multi_reader, 1, stderr_side, allocator, writer);
    try stdout_side.endFlush(writer);
    try stderr_side.endFlush(writer);
    try writer.flush();

    if (incomplete) try stderr_writer.writeAll(wrapper_io.incomplete_output_diagnostic);

    const term = try watcher.finish(&child, io);
    return .{
        .exit_code = exitCode(term),
        .input_bytes = input_bytes,
        .filter_name = filter_name,
    };
}

fn drainAvailable(
    multi_reader: *std.Io.File.MultiReader,
    index: usize,
    side: StreamSide,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
) !usize {
    const reader = multi_reader.reader(index);
    const bytes = reader.buffered();
    if (bytes.len == 0) return 0;
    try side.feed(allocator, bytes, writer);
    reader.tossBuffered();
    return bytes.len;
}

fn isComposeInvocation(argv: []const []const u8) bool {
    const cmd = commandBasename(argv) orelse return false;
    if (std.mem.eql(u8, cmd, "docker-compose")) return true;
    return std.mem.eql(u8, cmd, "docker") and argv.len >= 3 and std.mem.eql(u8, argv[1], "compose");
}

fn isDockerInvocation(argv: []const []const u8) bool {
    const cmd = commandBasename(argv) orelse return false;
    return std.mem.eql(u8, cmd, "docker") or std.mem.eql(u8, cmd, "docker-compose");
}

fn commandBasename(argv: []const []const u8) ?[]const u8 {
    if (argv.len == 0) return null;
    return if (std.mem.findScalarLast(u8, argv[0], '/')) |idx| argv[0][idx + 1 ..] else argv[0];
}

fn clearFrameIndex(line: []const u8) ?usize {
    const clear = std.mem.indexOf(u8, line, "\x1b[2J");
    const home = std.mem.indexOf(u8, line, "\x1b[H");
    if (clear) |c| {
        if (home) |h| return @min(c, h);
        return c;
    }
    return home;
}

fn parseRunWatchJob(line: []const u8) ?ParsedJob {
    const parsed = statusPrefix(line) orelse return null;
    if (parsed.step) return null;
    const rest = std.mem.trimEnd(u8, line[parsed.len..], " \t\r");
    if (!std.mem.endsWith(u8, rest, ")")) return null;
    const id_marker = std.mem.lastIndexOf(u8, rest, " (ID ") orelse return null;
    const id = rest[id_marker + " (ID ".len .. rest.len - 1];
    if (!allDigits(id)) return null;

    var name = std.mem.trim(u8, rest[0..id_marker], " \t");
    if (std.mem.lastIndexOf(u8, name, " in ")) |idx| {
        const maybe_duration = name[idx + " in ".len ..];
        if (looksLikeDuration(maybe_duration)) name = std.mem.trimEnd(u8, name[0..idx], " \t");
    }
    if (name.len == 0) return null;
    return .{ .name = name, .state = parsed.state };
}

fn isRunWatchStep(line: []const u8) bool {
    const parsed = statusPrefix(line) orelse return false;
    return parsed.step;
}

fn isRunWatchSection(line: []const u8) bool {
    return std.mem.eql(u8, line, "ANNOTATIONS") or std.mem.eql(u8, line, "ARTIFACTS");
}

const StatusPrefix = struct {
    len: usize,
    state: JobWatchState,
    step: bool,
};

fn statusPrefix(line: []const u8) ?StatusPrefix {
    const step = std.mem.startsWith(u8, line, "  ");
    const offset: usize = if (step) 2 else 0;
    if (line.len <= offset) return null;
    const rest = line[offset..];
    if (std.mem.startsWith(u8, rest, "✓ ")) return .{ .len = offset + "✓ ".len, .state = .passed, .step = step };
    if (std.mem.startsWith(u8, rest, "X ")) return .{ .len = offset + 2, .state = .failed, .step = step };
    if (std.mem.startsWith(u8, rest, "- ")) return .{ .len = offset + 2, .state = .skipped, .step = step };
    if (std.mem.startsWith(u8, rest, "* ")) return .{ .len = offset + 2, .state = .queued, .step = step };
    return null;
}

fn allDigits(input: []const u8) bool {
    if (input.len == 0) return false;
    for (input) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn looksLikeDuration(input: []const u8) bool {
    if (input.len == 0 or std.mem.indexOfScalar(u8, input, ' ') != null) return false;
    var saw_digit = false;
    var saw_unit = false;
    for (input) |c| {
        if (std.ascii.isDigit(c)) {
            saw_digit = true;
            continue;
        }
        if (c == 'h' or c == 'm' or c == 's' or c == '.' or c == 'u') {
            saw_unit = true;
            continue;
        }
        return false;
    }
    return saw_digit and saw_unit;
}
