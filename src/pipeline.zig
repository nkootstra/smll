const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const Passthrough = struct {
    pub fn matches(input: []const u8) bool {
        _ = input;
        return false;
    }

    pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
        _ = allocator;
        _ = stdout;
        _ = stderr;
        _ = writer;
        unreachable;
    }
};

pub fn run(
    allocator: Allocator,
    reader: *Reader,
    writer: *Writer,
    comptime Filters: anytype,
) !void {
    var stack_buf: [32 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < stack_buf.len) {
        const got = reader.readSliceShort(stack_buf[total..]) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (got == 0) break;
        total += got;
    }

    if (total < stack_buf.len) {
        return dispatch(allocator, stack_buf[0..total], writer, Filters);
    }

    // Large input: allocate combined buffer, copy stack prefix, read rest directly.
    // Pre-allocate generously to avoid a second alloc+copy in most cases.
    const init_cap = 256 * 1024; // 256 KB covers most real-world outputs
    var buf = try allocator.alloc(u8, init_cap);
    defer allocator.free(buf);
    @memcpy(buf[0..total], stack_buf[0..total]);

    // Read remaining data directly into the buffer.
    while (true) {
        if (total >= buf.len) {
            // Grow buffer (double).
            const new_cap = buf.len * 2;
            const new_buf = try allocator.alloc(u8, new_cap);
            @memcpy(new_buf[0..total], buf[0..total]);
            allocator.free(buf);
            buf = new_buf;
        }
        const got = reader.readSliceShort(buf[total..]) catch |err| switch (err) {
            error.ReadFailed => return err,
        };
        if (got == 0) break;
        total += got;
    }
    return dispatch(allocator, buf[0..total], writer, Filters);
}

pub fn dispatch(
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    comptime Filters: anytype,
) !void {
    inline for (Filters) |Filter| {
        if (Filter.matches(input)) {
            // Pipe-mode: no separate stderr stream; pass empty slice.
            try Filter.apply(allocator, input, &.{}, writer);
            return;
        }
    }
    try writer.writeAll(input);
}

test "empty input produces empty output" {
    const allocator = std.testing.allocator;
    var empty: [0]u8 = undefined;
    var reader = Reader.fixed(&empty);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{Passthrough});
    try std.testing.expectEqualStrings("", out.written());
}

test "1KB arbitrary bytes pass through byte-identically" {
    const allocator = std.testing.allocator;
    var input: [1024]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i % 256);

    var reader = Reader.fixed(&input);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{Passthrough});
    try std.testing.expectEqualSlices(u8, &input, out.written());
}

test "100KB input passes through correctly" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(input);
    for (input, 0..) |*b, i| b.* = @intCast(i % 256);

    var reader = Reader.fixed(input);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{Passthrough});
    try std.testing.expectEqualSlices(u8, input, out.written());
}

test "filter match routes through apply" {
    const allocator = std.testing.allocator;
    const Upper = struct {
        pub fn matches(input: []const u8) bool {
            return std.mem.startsWith(u8, input, "UP:");
        }
        pub fn apply(alloc: Allocator, input: []const u8, stderr: []const u8, w: *Writer) !void {
            _ = alloc;
            _ = stderr;
            for (input[3..]) |c| try w.writeByte(std.ascii.toUpper(c));
        }
    };

    var buf = "UP:hello".*;
    var reader = Reader.fixed(&buf);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{Upper});
    try std.testing.expectEqualStrings("HELLO", out.written());
}

const UpperFilter = struct {
    pub fn matches(input: []const u8) bool {
        return std.mem.startsWith(u8, input, "UP:");
    }
    pub fn apply(alloc: Allocator, input: []const u8, stderr: []const u8, w: *Writer) !void {
        _ = alloc;
        _ = stderr;
        for (input[3..]) |c| try w.writeByte(std.ascii.toUpper(c));
    }
};

const LowerFilter = struct {
    pub fn matches(input: []const u8) bool {
        return std.mem.startsWith(u8, input, "LO:");
    }
    pub fn apply(alloc: Allocator, input: []const u8, stderr: []const u8, w: *Writer) !void {
        _ = alloc;
        _ = stderr;
        for (input[3..]) |c| try w.writeByte(std.ascii.toLower(c));
    }
};

const NeverMatches = struct {
    pub fn matches(input: []const u8) bool {
        _ = input;
        return false;
    }
    pub fn apply(alloc: Allocator, input: []const u8, stderr: []const u8, w: *Writer) !void {
        _ = alloc;
        _ = input;
        _ = stderr;
        _ = w;
        unreachable;
    }
};

const AlwaysMatchesMarkerA = struct {
    pub fn matches(input: []const u8) bool {
        _ = input;
        return true;
    }
    pub fn apply(alloc: Allocator, input: []const u8, stderr: []const u8, w: *Writer) !void {
        _ = alloc;
        _ = input;
        _ = stderr;
        try w.writeAll("A");
    }
};

const AlwaysMatchesMarkerB = struct {
    pub fn matches(input: []const u8) bool {
        _ = input;
        return true;
    }
    pub fn apply(alloc: Allocator, input: []const u8, stderr: []const u8, w: *Writer) !void {
        _ = alloc;
        _ = input;
        _ = stderr;
        try w.writeAll("B");
    }
};

test "tuple with two filters routes to second when first declines" {
    const allocator = std.testing.allocator;
    var buf = "LO:HELLO".*;
    var reader = Reader.fixed(&buf);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{ UpperFilter, LowerFilter });
    try std.testing.expectEqualStrings("hello", out.written());
}

test "tuple: no filter matches falls through to passthrough" {
    const allocator = std.testing.allocator;
    var buf = "plain text no prefix".*;
    var reader = Reader.fixed(&buf);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{ UpperFilter, LowerFilter });
    try std.testing.expectEqualStrings("plain text no prefix", out.written());
}

test "tuple: highest-priority match wins when multiple would match" {
    const allocator = std.testing.allocator;
    var buf = "anything".*;
    var reader = Reader.fixed(&buf);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{ AlwaysMatchesMarkerA, AlwaysMatchesMarkerB });
    try std.testing.expectEqualStrings("A", out.written());
}

test "tuple: non-matching filter before matching filter routes correctly" {
    const allocator = std.testing.allocator;
    var buf = "UP:hi".*;
    var reader = Reader.fixed(&buf);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{ NeverMatches, LowerFilter, UpperFilter });
    try std.testing.expectEqualStrings("HI", out.written());
}

test "tuple: empty input with multiple filters passes through empty" {
    const allocator = std.testing.allocator;
    var empty: [0]u8 = undefined;
    var reader = Reader.fixed(&empty);
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();

    try run(allocator, &reader, &out.writer, .{ UpperFilter, LowerFilter });
    try std.testing.expectEqualStrings("", out.written());
}
