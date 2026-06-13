const std = @import("std");

const docker_logs = @import("docker_logs");
const jest = @import("jest");
const tsc = @import("tsc");
const wrapper_util = @import("wrapper_util.zig");

const max_line_bytes: usize = 64 * 1024;
const idle_flush_timeout: std.Io.Timeout = .{ .duration = .{
    .raw = .fromSeconds(2),
    .clock = .awake,
} };

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
        processor: anytype,
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
        processor: anytype,
        writer: *std.Io.Writer,
    ) !void {
        if (self.buf.items.len == 0) return;
        try processor.feedLine(self.buf.items, writer);
        self.buf.clearRetainingCapacity();
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
        try self.assembler.feed(allocator, bytes, self, writer);
    }

    fn feedLine(self: *LogStreamSide, raw: []const u8, writer: *std.Io.Writer) !void {
        try self.deduper.feedLine(raw, writer, true);
    }

    fn idleFlush(self: *LogStreamSide, writer: *std.Io.Writer) !void {
        try self.deduper.flush(writer, true);
    }

    fn endFlush(self: *LogStreamSide, writer: *std.Io.Writer) !void {
        try self.assembler.flush(self, writer);
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
        try self.assembler.feed(allocator, bytes, self, writer);
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
        try self.assembler.flush(self, writer);
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
        try self.assembler.feed(allocator, bytes, self, writer);
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
        try self.assembler.flush(self, writer);
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

pub fn runStreamFilter(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
) !Result {
    const cmd = commandBasename(argv) orelse "";
    if (wrapper_util.isTscWatch(cmd, argv)) {
        return runTscWatch(allocator, io, argv, writer);
    }
    if (wrapper_util.isJsTestWatch(cmd, argv)) {
        return runJestWatch(allocator, io, argv, writer);
    }
    return runFollowLogs(allocator, io, argv, writer);
}

pub fn runFollowLogs(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
) !Result {
    const mode: docker_logs.Mode = if (isComposeInvocation(argv)) .compose else .plain;
    var stdout_side = LogStreamSide.init(allocator, mode);
    defer stdout_side.deinit(allocator);
    var stderr_side = LogStreamSide.init(allocator, mode);
    defer stderr_side.deinit(allocator);
    return runPipedStream(allocator, io, argv, writer, &stdout_side, &stderr_side, if (isDockerInvocation(argv)) "stream:docker_logs" else "stream:logs");
}

fn runTscWatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
) !Result {
    var stdout_side = TscWatchSide.init(allocator);
    defer stdout_side.deinit(allocator);
    var stderr_side = TscWatchSide.init(allocator);
    defer stderr_side.deinit(allocator);
    return runPipedStream(allocator, io, argv, writer, &stdout_side, &stderr_side, "stream:tsc_watch");
}

fn runJestWatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
) !Result {
    var stdout_side = JestWatchSide.init(allocator);
    defer stdout_side.deinit(allocator);
    var stderr_side = JestWatchSide.init(allocator);
    defer stderr_side.deinit(allocator);
    return runPipedStream(allocator, io, argv, writer, &stdout_side, &stderr_side, "stream:js_test_watch");
}

fn runPipedStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stdout_side: anytype,
    stderr_side: anytype,
    filter_name: []const u8,
) !Result {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return err;
    defer child.kill(io);

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
    while (true) {
        multi_reader.fill(64, idle_flush_timeout) catch |err| switch (err) {
            error.Timeout => {
                try stdout_side.idleFlush(writer);
                try stderr_side.idleFlush(writer);
                try writer.flush();
                continue;
            },
            error.EndOfStream => break,
            else => |e| return e,
        };
        input_bytes += try drainAvailable(&multi_reader, 0, stdout_side, allocator, writer);
        input_bytes += try drainAvailable(&multi_reader, 1, stderr_side, allocator, writer);
        try writer.flush();
    }
    try multi_reader.checkAnyError();

    input_bytes += try drainAvailable(&multi_reader, 0, stdout_side, allocator, writer);
    input_bytes += try drainAvailable(&multi_reader, 1, stderr_side, allocator, writer);
    try stdout_side.endFlush(writer);
    try stderr_side.endFlush(writer);
    try writer.flush();

    const term = try child.wait(io);
    return .{
        .exit_code = switch (term) {
            .exited => |c| c,
            .signal, .stopped, .unknown => 1,
        },
        .input_bytes = input_bytes,
        .filter_name = filter_name,
    };
}

fn drainAvailable(
    multi_reader: *std.Io.File.MultiReader,
    index: usize,
    side: anytype,
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
