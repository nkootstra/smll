const std = @import("std");

const docker_logs = @import("docker_logs");

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
        deduper: *docker_logs.StreamDeduper,
        writer: *std.Io.Writer,
    ) !void {
        var start: usize = 0;
        for (bytes, 0..) |c, i| {
            if (c != '\n') continue;
            try self.buf.appendSlice(allocator, bytes[start..i]);
            try deduper.feedLine(self.buf.items, writer, true);
            self.buf.clearRetainingCapacity();
            start = i + 1;
        }
        if (start < bytes.len) {
            try self.buf.appendSlice(allocator, bytes[start..]);
            if (self.buf.items.len >= max_line_bytes) {
                try deduper.feedLine(self.buf.items, writer, true);
                self.buf.clearRetainingCapacity();
            }
        }
    }

    fn flush(
        self: *LineAssembler,
        deduper: *docker_logs.StreamDeduper,
        writer: *std.Io.Writer,
    ) !void {
        if (self.buf.items.len == 0) return;
        try deduper.feedLine(self.buf.items, writer, true);
        self.buf.clearRetainingCapacity();
    }
};

const StreamSide = struct {
    assembler: LineAssembler = .{},
    deduper: docker_logs.StreamDeduper,

    fn init(allocator: std.mem.Allocator, mode: docker_logs.Mode) StreamSide {
        return .{ .deduper = docker_logs.StreamDeduper.init(allocator, mode) };
    }

    fn deinit(self: *StreamSide, allocator: std.mem.Allocator) void {
        self.assembler.deinit(allocator);
        self.deduper.deinit();
    }

    fn feed(self: *StreamSide, allocator: std.mem.Allocator, bytes: []const u8, writer: *std.Io.Writer) !void {
        try self.assembler.feed(allocator, bytes, &self.deduper, writer);
    }

    fn idleFlush(self: *StreamSide, writer: *std.Io.Writer) !void {
        try self.deduper.flush(writer, true);
    }

    fn endFlush(self: *StreamSide, writer: *std.Io.Writer) !void {
        try self.assembler.flush(&self.deduper, writer);
        try self.deduper.flush(writer, true);
    }
};

pub fn runDockerLogs(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    writer: *std.Io.Writer,
) !Result {
    const mode: docker_logs.Mode = if (isComposeInvocation(argv)) .compose else .plain;

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

    var stdout_side = StreamSide.init(allocator, mode);
    defer stdout_side.deinit(allocator);
    var stderr_side = StreamSide.init(allocator, mode);
    defer stderr_side.deinit(allocator);

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
        input_bytes += try drainAvailable(&multi_reader, 0, &stdout_side, allocator, writer);
        input_bytes += try drainAvailable(&multi_reader, 1, &stderr_side, allocator, writer);
        try writer.flush();
    }
    try multi_reader.checkAnyError();

    input_bytes += try drainAvailable(&multi_reader, 0, &stdout_side, allocator, writer);
    input_bytes += try drainAvailable(&multi_reader, 1, &stderr_side, allocator, writer);
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
        .filter_name = "stream:docker_logs",
    };
}

fn drainAvailable(
    multi_reader: *std.Io.File.MultiReader,
    index: usize,
    side: *StreamSide,
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
    if (argv.len == 0) return false;
    const cmd = if (std.mem.findScalarLast(u8, argv[0], '/')) |idx| argv[0][idx + 1 ..] else argv[0];
    if (std.mem.eql(u8, cmd, "docker-compose")) return true;
    return std.mem.eql(u8, cmd, "docker") and argv.len >= 3 and std.mem.eql(u8, argv[1], "compose");
}
