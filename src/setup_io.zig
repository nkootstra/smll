const std = @import("std");
const setup_json = @import("setup_json.zig");

const JValue = setup_json.Value;

/// Concatenate two byte slices into allocator-owned memory.
pub fn concat2(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, a.len + b.len);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..], b);
    return buf;
}

pub fn readFileOptional(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return data;
}

pub fn writeBackupIfExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8, dry_run: bool) !void {
    const existing = try readFileOptional(allocator, io, path);
    defer if (existing) |buf| allocator.free(buf);
    if (existing == null or dry_run) return;

    const backup_path = try concat2(allocator, path, ".bak.smll");
    defer allocator.free(backup_path);
    try writeFileEnsuringParent(io, backup_path, existing.?);
}

fn writeFileEnsuringParent(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.mem.findScalarLast(u8, path, '/')) |idx| {
        try std.Io.Dir.cwd().createDirPath(io, path[0..idx]);
    }
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    });
}

/// Write or dry-run a file, with backup and status output.
pub fn writeOrReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    data: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
) !void {
    try writeBackupIfExists(allocator, io, path, dry_run);
    if (dry_run) {
        try stdout.writeAll("[dry-run] would write ");
        try stdout.writeAll(path);
        try stdout.writeByte('\n');
    } else {
        try writeFileEnsuringParent(io, path, data);
        try stdout.writeAll("wrote ");
        try stdout.writeAll(path);
        try stdout.writeByte('\n');
    }
}

/// Delete or dry-run a file, with backup and status output.
pub fn deleteOrReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
) !void {
    try writeBackupIfExists(allocator, io, path, dry_run);
    if (dry_run) {
        try stdout.writeAll("[dry-run] would delete ");
        try stdout.writeAll(path);
        try stdout.writeByte('\n');
    } else {
        try deleteFileIfExists(io, path);
        try stdout.writeAll("deleted ");
        try stdout.writeAll(path);
        try stdout.writeByte('\n');
    }
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

pub fn writeJsonValueToPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    value: JValue,
    dry_run: bool,
    stdout: *std.Io.Writer,
) !void {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try setup_json.writeValue(&out.writer, value);
    try out.writer.writeByte('\n');

    if (dry_run) {
        try stdout.writeAll("[dry-run] would update ");
        try stdout.writeAll(path);
        try stdout.writeByte('\n');
    } else {
        try writeFileEnsuringParent(io, path, out.written());
        try stdout.writeAll("updated ");
        try stdout.writeAll(path);
        try stdout.writeByte('\n');
    }
}

pub fn writeJsonError(stderr: *std.Io.Writer, file: []const u8) !void {
    try stderr.writeAll(file);
    try stderr.writeAll(": invalid JSON\n");
}

pub fn checkConflictingIntegration(data: ?[]const u8, target: []const u8, file: []const u8, stderr: *std.Io.Writer) !bool {
    const buf = data orelse return false;
    if (!containsConflictingIntegration(buf)) return false;
    try stderr.writeAll("Conflicting command-wrapper integration detected in ");
    try stderr.writeAll(file);
    try stderr.writeAll(". Remove it first, then run smll --setup ");
    try stderr.writeAll(target);
    try stderr.writeAll(" again.\n");
    return true;
}

fn containsConflictingIntegration(s: []const u8) bool {
    return containsIgnoreCase(s, "run-toolkit") or
        containsIgnoreCase(s, "run toolkit") or
        containsIgnoreCase(s, "\"rtk\"") or
        containsIgnoreCase(s, " rtk") or
        containsIgnoreCase(s, "/rtk") or
        containsIgnoreCase(s, "rtk-") or
        containsIgnoreCase(s, "-rtk");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

test "conflicting integration detection covers legacy markers" {
    try std.testing.expect(containsConflictingIntegration("plugin: run-toolkit"));
    try std.testing.expect(containsConflictingIntegration("Run Toolkit"));
    try std.testing.expect(containsConflictingIntegration("{\"name\":\"rtk\"}"));
    try std.testing.expect(containsConflictingIntegration("/opt/tools/rtk/plugin"));
    try std.testing.expect(containsConflictingIntegration("rtk-pretooluse.sh"));
    try std.testing.expect(containsConflictingIntegration("agent-rtk-hook"));
    try std.testing.expect(!containsConflictingIntegration("plugin: smll-proxy"));
}
