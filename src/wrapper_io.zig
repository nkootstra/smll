const std = @import("std");

pub const CapturedOutput = struct {
    stdout: []u8,
    stderr: []u8,
};

/// Concurrently drain child stdout and stderr. Reading one pipe to EOF before
/// the other can deadlock when the child writes more than the kernel pipe
/// buffer to stderr while stdout stays open.
pub fn drainChildOutput(allocator: std.mem.Allocator, io: std.Io, child: *std.process.Child, max_output_bytes: usize) !CapturedOutput {
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

    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
        if (stderr_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);

    return .{ .stdout = stdout_slice, .stderr = stderr_slice };
}

/// Write stdout + stderr passthrough. Used as error fallback in filter dispatch.
pub noinline fn passthrough(writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, stdout_slice: []const u8, stderr_slice: []const u8) void {
    writer.writeAll(stdout_slice) catch {};
    stderr_writer.writeAll(stderr_slice) catch {};
}

pub fn applyFilter(
    comptime apply: anytype,
    allocator: std.mem.Allocator,
    stdout_slice: []const u8,
    stderr_slice: []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) bool {
    apply(allocator, stdout_slice, stderr_slice, writer) catch {
        passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        return false;
    };
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
