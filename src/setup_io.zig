const std = @import("std");
const builtin = @import("builtin");
const state_io = @import("state_io.zig");
const setup_json = @import("setup_json.zig");

const JValue = setup_json.Value;

/// Concatenate two byte slices into allocator-owned memory.
pub fn concat2(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, a.len + b.len);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..], b);
    return buf;
}

pub fn shellEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var extra: usize = 2;
    for (value) |c| if (c == '\'') {
        extra += 3;
    };
    const out = try allocator.alloc(u8, value.len + extra);
    var pos: usize = 0;
    out[pos] = '\'';
    pos += 1;
    for (value) |c| {
        if (c == '\'') {
            @memcpy(out[pos .. pos + 4], "'\\''");
            pos += 4;
        } else {
            out[pos] = c;
            pos += 1;
        }
    }
    out[pos] = '\'';
    return out;
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
    const source = try std.Io.Dir.cwd().statFile(io, path, .{});
    try writeFileAtomicWithPermissions(io, backup_path, existing.?, source.permissions);
}

fn writeFileAtomicWithPermissions(io: std.Io, path: []const u8, data: []const u8, permissions: std.Io.File.Permissions) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.mem.findScalarLast(u8, path, '/')) |idx| try cwd.createDirPath(io, path[0..idx]);
    var atomic_file = try cwd.createFileAtomic(io, path, .{
        .permissions = permissions,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    if (builtin.os.tag != .windows) try atomic_file.file.setPermissions(io, permissions);
    try atomic_file.file.writePositionalAll(io, data, 0);
    try atomic_file.replace(io);
}

pub fn writeFileAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.mem.findScalarLast(u8, path, '/')) |idx| {
        try cwd.createDirPath(io, path[0..idx]);
    }

    const permissions = if (cwd.statFile(io, path, .{})) |st|
        st.permissions
    else |err| switch (err) {
        error.FileNotFound => std.Io.File.Permissions.default_file,
        else => |e| return e,
    };
    var atomic_file = try cwd.createFileAtomic(io, path, .{
        .permissions = permissions,
        .replace = true,
    });
    defer atomic_file.deinit(io);
    if (builtin.os.tag != .windows) try atomic_file.file.setPermissions(io, permissions);
    try atomic_file.file.writePositionalAll(io, data, 0);
    try atomic_file.replace(io);
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
        try writeFileAtomic(io, path, data);
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
        try writeFileAtomic(io, path, out.written());
        try stdout.writeAll("updated ");
        try stdout.writeAll(path);
        try stdout.writeByte('\n');
    }
}

pub fn restoreOptional(io: std.Io, path: []const u8, previous: ?[]const u8) !void {
    if (previous) |data| return writeFileAtomic(io, path, data);
    try deleteFileIfExists(io, path);
}

const ownership_header = "smll-setup-v1\n";

pub const Ownership = union(enum) {
    missing,
    modified,
    valid: []u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.* == .valid) allocator.free(self.valid);
        self.* = .missing;
    }

    pub fn validPayload(self: @This()) ?[]const u8 {
        return switch (self) {
            .valid => |payload| payload,
            else => null,
        };
    }
};

pub fn ownershipPath(allocator: std.mem.Allocator, home: []const u8, target: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/.smll/setup/{s}.owned", .{ home, target });
}

pub fn writeOwnership(allocator: std.mem.Allocator, io: std.Io, home: []const u8, target: []const u8, payload: []const u8) !void {
    const root = try concat2(allocator, home, "/.smll");
    defer allocator.free(root);
    const dir = try concat2(allocator, home, "/.smll/setup");
    defer allocator.free(dir);
    try state_io.ensurePrivateDir(io, root);
    try state_io.ensurePrivateDir(io, dir);

    const path = try ownershipPath(allocator, home, target);
    defer allocator.free(path);
    var content = std.Io.Writer.Allocating.init(allocator);
    defer content.deinit();
    try content.writer.writeAll(ownership_header);
    var digest_buf: [16]u8 = undefined;
    writeDigestHex(payload, &digest_buf);
    try content.writer.writeAll(&digest_buf);
    try content.writer.writeByte('\n');
    try content.writer.writeAll(payload);
    try state_io.writePrivateFileAtomic(io, path, content.written());
}

pub fn readOwnership(allocator: std.mem.Allocator, io: std.Io, home: []const u8, target: []const u8) !Ownership {
    const path = try ownershipPath(allocator, home, target);
    defer allocator.free(path);
    const data = try readFileOptional(allocator, io, path) orelse return .missing;
    defer allocator.free(data);
    if (!std.mem.startsWith(u8, data, ownership_header)) return .modified;
    const digest_start = ownership_header.len;
    const payload_start = digest_start + 17;
    if (data.len < payload_start or data[digest_start + 16] != '\n') return .modified;
    const payload = data[payload_start..];
    var expected: [16]u8 = undefined;
    writeDigestHex(payload, &expected);
    if (!std.mem.eql(u8, data[digest_start .. digest_start + 16], &expected)) return .modified;
    return .{ .valid = try allocator.dupe(u8, payload) };
}

pub fn deleteOwnership(allocator: std.mem.Allocator, io: std.Io, home: []const u8, target: []const u8) !void {
    const path = try ownershipPath(allocator, home, target);
    defer allocator.free(path);
    try deleteFileIfExists(io, path);
}

pub fn digestHex(data: []const u8, out: *[16]u8) void {
    writeDigestHex(data, out);
}

fn writeDigestHex(data: []const u8, out: *[16]u8) void {
    const hex = "0123456789abcdef";
    var value = std.hash.Wyhash.hash(0, data);
    var i: usize = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = hex[@intCast(value & 0x0f)];
        value >>= 4;
    }
}

pub fn validateHookEvaluator(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable_path: []const u8,
    target: []const u8,
    stderr: *std.Io.Writer,
) !bool {
    if (builtin.is_test) return true;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ executable_path, "--hook-eval", target, "--self-check" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    }) catch {
        try stderr.writeAll("smll hook evaluator self-check failed\n");
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term == .exited and result.term.exited == 0 and result.stdout.len == 0 and result.stderr.len == 0) return true;
    try stderr.writeAll("smll hook evaluator self-check failed\n");
    return false;
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

test "shellEscapeAlloc single-quotes paths for generated hook commands" {
    const allocator = std.testing.allocator;
    const escaped = try shellEscapeAlloc(allocator, "/tmp/smll's build/smll");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("'/tmp/smll'\\''s build/smll'", escaped);
}

test "ownership records round trip and detect modification" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);

    try writeOwnership(allocator, std.testing.io, home, "codex", "'/opt/smll' --hook-eval codex");
    var owned = try readOwnership(allocator, std.testing.io, home, "codex");
    defer owned.deinit(allocator);
    try std.testing.expectEqualStrings("'/opt/smll' --hook-eval codex", owned.validPayload().?);

    const path = try ownershipPath(allocator, home, "codex");
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "modified\n" });
    var modified = try readOwnership(allocator, std.testing.io, home, "codex");
    defer modified.deinit(allocator);
    try std.testing.expect(modified == .modified);
}

test "atomic setup writes preserve existing permissions" {
    if (@import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "config.json", .{ .permissions = .fromMode(0o600) });
    file.close(std.testing.io);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", allocator);
    defer allocator.free(path);

    try writeFileAtomic(std.testing.io, path, "new\n");
    const st = try tmp.dir.statFile(std.testing.io, "config.json", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    const data = try tmp.dir.readFileAlloc(std.testing.io, "config.json", allocator, .limited(64));
    defer allocator.free(data);
    try std.testing.expectEqualStrings("new\n", data);
}

test "atomic setup writes preserve existing permissions under restrictive umask" {
    if (builtin.os.tag == .windows or !builtin.link_libc) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "config.json", .{});
    try file.setPermissions(std.testing.io, .fromMode(0o644));
    file.close(std.testing.io);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", allocator);
    defer allocator.free(path);

    const previous_umask = std.c.umask(0o077);
    defer _ = std.c.umask(previous_umask);
    try writeFileAtomic(std.testing.io, path, "new\n");

    const st = try tmp.dir.statFile(std.testing.io, "config.json", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o644), st.permissions.toMode() & 0o777);
}

test "setup backups never widen source permissions" {
    if (@import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source = try tmp.dir.createFile(std.testing.io, "settings.json", .{ .permissions = .fromMode(0o600) });
    try source.writePositionalAll(std.testing.io, "secret\n", 0);
    source.close(std.testing.io);
    var old_backup = try tmp.dir.createFile(std.testing.io, "settings.json.bak.smll", .{ .permissions = .fromMode(0o644) });
    old_backup.close(std.testing.io);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "settings.json", allocator);
    defer allocator.free(path);

    try writeBackupIfExists(allocator, std.testing.io, path, false);
    const st = try tmp.dir.statFile(std.testing.io, "settings.json.bak.smll", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);

    var second = try tmp.dir.createFile(std.testing.io, "hooks.json", .{ .permissions = .fromMode(0o600) });
    try second.writePositionalAll(std.testing.io, "private\n", 0);
    second.close(std.testing.io);
    const second_path = try tmp.dir.realPathFileAlloc(std.testing.io, "hooks.json", allocator);
    defer allocator.free(second_path);
    try writeBackupIfExists(allocator, std.testing.io, second_path, false);
    const second_st = try tmp.dir.statFile(std.testing.io, "hooks.json.bak.smll", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), second_st.permissions.toMode() & 0o777);
}
