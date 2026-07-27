const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const state_dir = ".smll";
const state_lock_file = ".smll/state.lock";

pub fn privateFilePermissions() Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
}

fn privateDirPermissions() Io.File.Permissions {
    return if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700);
}

pub fn ensurePrivateDir(io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    _ = try cwd.createDirPathStatus(io, path, privateDirPermissions());
    if (builtin.os.tag == .windows) return;

    var dir = try cwd.openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    try dir.setPermissions(io, privateDirPermissions());
}

pub fn createPrivateFile(io: Io, path: []const u8, options: Io.Dir.CreateFileOptions) !Io.File {
    var private_options = options;
    private_options.permissions = privateFilePermissions();
    const file = try Io.Dir.cwd().createFile(io, path, private_options);
    errdefer file.close(io);
    if (builtin.os.tag != .windows) try file.setPermissions(io, privateFilePermissions());
    return file;
}

pub fn openExclusivePrivateLock(io: Io, path: []const u8) !?Io.File {
    return createPrivateFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    }) catch |err| switch (err) {
        error.FileLocksUnsupported => return null,
        else => |e| return e,
    };
}

pub fn openStateLock(allocator: Allocator, io: Io, home: []const u8) !?Io.File {
    const dir_path = try util.joinPath(allocator, home, state_dir);
    defer allocator.free(dir_path);
    try ensurePrivateDir(io, dir_path);

    const lock_path = try util.joinPath(allocator, home, state_lock_file);
    defer allocator.free(lock_path);
    return openExclusivePrivateLock(io, lock_path);
}

pub fn copyFileUnderStateLock(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    path: []const u8,
    max_size: usize,
) ![]u8 {
    const state_lock = openStateLock(allocator, io, home) catch
        return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_size));
    defer if (state_lock) |file| file.close(io);
    return Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_size));
}

pub fn writePrivateFileAtomic(io: Io, path: []const u8, data: []const u8) !void {
    var atomic_file = try Io.Dir.cwd().createFileAtomic(io, path, .{
        .permissions = privateFilePermissions(),
        .replace = true,
    });
    defer atomic_file.deinit(io);
    if (builtin.os.tag != .windows) try atomic_file.file.setPermissions(io, privateFilePermissions());
    try atomic_file.file.writePositionalAll(io, data, 0);
    try atomic_file.replace(io);
}
