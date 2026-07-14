const std = @import("std");

pub const panic = std.debug.simple_panic;

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try init.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidArguments;

    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, args[1], allocator, .limited(16 * 1024 * 1024));
    const output_len = trimLength(data);
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = data[0..output_len] });

    var output = try cwd.openFile(io, args[2], .{});
    defer output.close(io);
    try output.setPermissions(io, .executable_file);
}

fn trimLength(data: []u8) usize {
    if (data.len < 64 or !std.mem.eql(u8, data[0..4], "\x7fELF")) return data.len;
    if (data[4] != 2 or data[5] != 1) return data.len; // ELF64, little-endian

    const phoff = readU64(data, 32) orelse return data.len;
    const phentsize = readU16(data, 54) orelse return data.len;
    const phnum = readU16(data, 56) orelse return data.len;
    if (phentsize < 56 or phnum == 0) return data.len;

    const table_end = std.math.add(usize, phoff, std.math.mul(usize, phentsize, phnum) catch return data.len) catch return data.len;
    if (table_end > data.len) return data.len;

    var file_end = table_end;
    for (0..phnum) |i| {
        const base = phoff + i * phentsize;
        const offset = readU64(data, base + 8) orelse return data.len;
        const size = readU64(data, base + 32) orelse return data.len;
        const segment_end = std.math.add(usize, offset, size) catch return data.len;
        if (segment_end > data.len) return data.len;
        file_end = @max(file_end, segment_end);
    }
    if (file_end >= data.len) return data.len;

    @memset(data[40..48], 0); // e_shoff
    @memset(data[58..64], 0); // e_shentsize, e_shnum, e_shstrndx
    return file_end;
}

fn readU16(data: []const u8, offset: usize) ?usize {
    if (offset > data.len or data.len - offset < 2) return null;
    return std.mem.readInt(u16, data[offset..][0..2], .little);
}

fn readU64(data: []const u8, offset: usize) ?usize {
    if (offset > data.len or data.len - offset < 8) return null;
    return std.math.cast(usize, std.mem.readInt(u64, data[offset..][0..8], .little));
}

test "trimLength removes only bytes beyond ELF program segments" {
    var data: [256]u8 = @splat(0xaa);
    @memcpy(data[0..4], "\x7fELF");
    data[4] = 2;
    data[5] = 1;
    std.mem.writeInt(u64, data[32..40], 64, .little);
    std.mem.writeInt(u64, data[40..48], 192, .little);
    std.mem.writeInt(u16, data[54..56], 56, .little);
    std.mem.writeInt(u16, data[56..58], 1, .little);
    std.mem.writeInt(u16, data[58..60], 64, .little);
    std.mem.writeInt(u16, data[60..62], 1, .little);
    std.mem.writeInt(u16, data[62..64], 1, .little);
    std.mem.writeInt(u64, data[64 + 8 ..][0..8], 0, .little);
    std.mem.writeInt(u64, data[64 + 32 ..][0..8], 160, .little);

    try std.testing.expectEqual(@as(usize, 160), trimLength(&data));
    try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), data[40..48]);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), data[58..64]);
    try std.testing.expectEqual(@as(u8, 0xaa), data[159]);
}

test "trimLength leaves unsupported and malformed files unchanged" {
    var text = [_]u8{ 'n', 'o', 't', ' ', 'e', 'l', 'f' };
    try std.testing.expectEqual(text.len, trimLength(&text));

    var malformed: [128]u8 = @splat(0);
    @memcpy(malformed[0..4], "\x7fELF");
    malformed[4] = 2;
    malformed[5] = 1;
    std.mem.writeInt(u64, malformed[32..40], 96, .little);
    std.mem.writeInt(u16, malformed[54..56], 56, .little);
    std.mem.writeInt(u16, malformed[56..58], 2, .little);
    try std.testing.expectEqual(malformed.len, trimLength(&malformed));
}
