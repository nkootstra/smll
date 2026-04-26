const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

/// Cumulative token-savings stats stored in ~/.smll/stats.json.
/// Best-effort: stats failures never block command execution.
pub const Stats = struct {
    commands: u64 = 0,
    input_bytes: u64 = 0,
    output_bytes: u64 = 0,
};

const stats_dir = ".smll";
const stats_file = ".smll/stats.json";

/// Record a completed command's byte counts. Best-effort — silently
/// ignores any I/O errors so that stats never block a real command.
pub fn record(allocator: Allocator, io: Io, home: []const u8, input_bytes: usize, output_bytes: usize) void {
    recordInner(allocator, io, home, input_bytes, output_bytes) catch {};
}

fn recordInner(allocator: Allocator, io: Io, home: []const u8, input_bytes: usize, output_bytes: usize) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, stats_file });
    defer allocator.free(path);
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, stats_dir });
    defer allocator.free(dir_path);

    var s = load(allocator, io, path);
    s.commands += 1;
    s.input_bytes += input_bytes;
    s.output_bytes += output_bytes;

    try save(io, dir_path, path, s);
}

fn load(allocator: Allocator, io: Io, path: []const u8) Stats {
    return loadInner(allocator, io, path) catch .{};
}

fn loadInner(allocator: Allocator, io: Io, path: []const u8) !Stats {
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(4096)) catch return .{};
    defer allocator.free(data);

    var s: Stats = .{};
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return s;
    if (parsed.value.object.get("commands")) |v| {
        if (v == .integer) s.commands = @intCast(@max(0, v.integer));
    }
    if (parsed.value.object.get("input_bytes")) |v| {
        if (v == .integer) s.input_bytes = @intCast(@max(0, v.integer));
    }
    if (parsed.value.object.get("output_bytes")) |v| {
        if (v == .integer) s.output_bytes = @intCast(@max(0, v.integer));
    }
    return s;
}

fn save(io: Io, dir_path: []const u8, path: []const u8, s: Stats) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);

    var buf: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf,
        \\{{"commands":{d},"input_bytes":{d},"output_bytes":{d}}}
        \\
    , .{ s.commands, s.input_bytes, s.output_bytes });

    try cwd.writeFile(io, .{ .sub_path = path, .data = json });
}

/// Handle `--stats` and `--stats --reset`. Returns exit code, or null
/// if the args don't match a stats command.
pub fn maybeRun(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    args: []const []const u8,
    stdout: *Writer,
) !?u8 {
    if (args.len < 2) return null;
    if (!std.mem.eql(u8, args[1], "--stats")) return null;

    // --stats --reset
    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--reset")) {
            try reset(io, home);
            try stdout.writeAll("stats reset\n");
            return 0;
        }
    }

    // --stats (display)
    try display(allocator, io, home, stdout);
    return 0;
}

fn reset(io: Io, home: []const u8) !void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ home, stats_file }) catch return;
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn display(allocator: Allocator, io: Io, home: []const u8, stdout: *Writer) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, stats_file });
    defer allocator.free(path);
    const s = load(allocator, io, path);

    if (s.commands == 0) {
        try stdout.writeAll("no commands recorded yet\n");
        return;
    }

    const saved = if (s.input_bytes > s.output_bytes) s.input_bytes - s.output_bytes else 0;
    const pct = if (s.input_bytes > 0) (saved * 100) / s.input_bytes else 0;
    // Rough token estimate: ~4 chars per token (GPT/Claude average for code).
    const tokens_saved = saved / 4;

    try stdout.writeAll("\nsmll stats\n\n");
    try stdout.print("  Commands wrapped:  {}\n", .{s.commands});
    try stdout.writeAll("  Input (raw):       ");
    try writeHumanBytes(stdout, s.input_bytes);
    try stdout.writeByte('\n');
    try stdout.writeAll("  Output (compact):  ");
    try writeHumanBytes(stdout, s.output_bytes);
    try stdout.writeByte('\n');
    try stdout.writeAll("  Saved:             ");
    try writeHumanBytes(stdout, saved);
    try stdout.print(" ({d}%)\n", .{pct});
    try stdout.writeAll("  Est. tokens saved: ~");
    try writeHumanCount(stdout, tokens_saved);
    try stdout.writeByte('\n');
    try stdout.writeByte('\n');
}

fn writeHumanBytes(w: *Writer, bytes: u64) !void {
    if (bytes < 1024) {
        try w.print("{d} B", .{bytes});
    } else if (bytes < 1024 * 1024) {
        try w.print("{d}.{d} KB", .{ bytes / 1024, (bytes % 1024) * 10 / 1024 });
    } else if (bytes < 1024 * 1024 * 1024) {
        const mb = bytes / (1024 * 1024);
        const frac = (bytes % (1024 * 1024)) * 10 / (1024 * 1024);
        try w.print("{d}.{d} MB", .{ mb, frac });
    } else {
        const gb = bytes / (1024 * 1024 * 1024);
        const frac = (bytes % (1024 * 1024 * 1024)) * 10 / (1024 * 1024 * 1024);
        try w.print("{d}.{d} GB", .{ gb, frac });
    }
}

fn writeHumanCount(w: *Writer, n: u64) !void {
    if (n < 1000) {
        try w.print("{d}", .{n});
    } else if (n < 1_000_000) {
        try w.print("{d}.{d}K", .{ n / 1000, (n % 1000) / 100 });
    } else {
        try w.print("{d}.{d}M", .{ n / 1_000_000, (n % 1_000_000) / 100_000 });
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeHumanBytes: bytes" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeHumanBytes(&out.writer, 512);
    try std.testing.expectEqualStrings("512 B", out.written());
}

test "writeHumanBytes: kilobytes" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeHumanBytes(&out.writer, 2560);
    try std.testing.expectEqualStrings("2.5 KB", out.written());
}

test "writeHumanBytes: megabytes" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeHumanBytes(&out.writer, 5 * 1024 * 1024 + 512 * 1024);
    try std.testing.expectEqualStrings("5.5 MB", out.written());
}

test "writeHumanCount: small" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeHumanCount(&out.writer, 42);
    try std.testing.expectEqualStrings("42", out.written());
}

test "writeHumanCount: thousands" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeHumanCount(&out.writer, 12500);
    try std.testing.expectEqualStrings("12.5K", out.written());
}

test "writeHumanCount: millions" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeHumanCount(&out.writer, 2_300_000);
    try std.testing.expectEqualStrings("2.3M", out.written());
}

test "display: no commands" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try display(std.testing.allocator, std.testing.io, "/tmp/smll-test-nonexistent-home", &out.writer);
    try std.testing.expectEqualStrings("no commands recorded yet\n", out.written());
}
