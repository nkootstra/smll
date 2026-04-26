const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

/// Cumulative token-savings stats stored in ~/.smll/stats.json.
/// Best-effort: stats failures never block command execution.
///
/// JSON format:
/// {
///   "commands": 142,
///   "input_bytes": 2456789,
///   "output_bytes": 412345,
///   "by_cmd": {
///     "git status": { "n": 30, "in": 45000, "out": 3000 },
///     "git diff":   { "n": 12, "in": 120000, "out": 24000 },
///     ...
///   }
/// }

const stats_dir = ".smll";
const stats_file = ".smll/stats.json";
const MAX_TRACKED_CMDS = 32;
const MAX_JSON_SIZE = 32 * 1024;

pub const CmdStats = struct {
    n: u64 = 0,
    in_bytes: u64 = 0,
    out_bytes: u64 = 0,
};

pub const Stats = struct {
    commands: u64 = 0,
    input_bytes: u64 = 0,
    output_bytes: u64 = 0,
    by_cmd: [MAX_TRACKED_CMDS]CmdEntry = [_]CmdEntry{.{}} ** MAX_TRACKED_CMDS,
    cmd_count: usize = 0,
};

pub const CmdEntry = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    stats: CmdStats = .{},

    fn nameSlice(self: *const CmdEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Build a command label from argv: "git status", "docker ps", "cat", etc.

/// Record a completed command's byte counts. Best-effort.
pub fn record(allocator: Allocator, io: Io, home: []const u8, argv: []const []const u8, input_bytes: usize, output_bytes: usize) void {
    recordInner(allocator, io, home, argv, input_bytes, output_bytes) catch {};
}

fn recordInner(allocator: Allocator, io: Io, home: []const u8, argv: []const []const u8, input_bytes: usize, output_bytes: usize) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, stats_file });
    defer allocator.free(path);
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, stats_dir });
    defer allocator.free(dir_path);

    var s = load(allocator, io, path);
    s.commands += 1;
    s.input_bytes += input_bytes;
    s.output_bytes += output_bytes;

    // Build command label: "git status", "docker ps", "cat", etc.
    var label_buf: [64]u8 = undefined;
    const label = buildLabel(argv, &label_buf);

    // Find or create per-command entry.
    var found: ?*CmdEntry = null;
    for (s.by_cmd[0..s.cmd_count]) |*entry| {
        if (std.mem.eql(u8, entry.nameSlice(), label)) {
            found = entry;
            break;
        }
    }
    if (found == null and s.cmd_count < MAX_TRACKED_CMDS) {
        const entry = &s.by_cmd[s.cmd_count];
        const copy_len = @min(label.len, entry.name.len);
        @memcpy(entry.name[0..copy_len], label[0..copy_len]);
        entry.name_len = copy_len;
        s.cmd_count += 1;
        found = entry;
    }
    if (found) |entry| {
        entry.stats.n += 1;
        entry.stats.in_bytes += input_bytes;
        entry.stats.out_bytes += output_bytes;
    }

    try saveJson(allocator, io, dir_path, path, s);
}

fn buildLabel(argv: []const []const u8, buf: *[64]u8) []const u8 {
    if (argv.len == 0) return "unknown";
    const cmd = argv[0];
    const basename = if (std.mem.findScalarLast(u8, cmd, '/')) |idx| cmd[idx + 1 ..] else cmd;

    // For multi-word commands, include subcommand.
    if (argv.len >= 2) {
        const sub = argv[1];
        if (sub.len > 0 and sub[0] != '-') {
            if (std.mem.eql(u8, basename, "git") or
                std.mem.eql(u8, basename, "docker") or
                std.mem.eql(u8, basename, "kubectl") or
                std.mem.eql(u8, basename, "cargo") or
                std.mem.eql(u8, basename, "npm") or
                std.mem.eql(u8, basename, "go") or
                std.mem.eql(u8, basename, "gh") or
                std.mem.eql(u8, basename, "bun") or
                std.mem.eql(u8, basename, "pnpm"))
            {
                const result = std.fmt.bufPrint(buf, "{s} {s}", .{ basename, sub }) catch return basename;
                return result;
            }
        }
    }
    const copy_len = @min(basename.len, buf.len);
    @memcpy(buf[0..copy_len], basename[0..copy_len]);
    return buf[0..copy_len];
}

fn load(allocator: Allocator, io: Io, path: []const u8) Stats {
    return loadInner(allocator, io, path) catch .{};
}

fn loadInner(allocator: Allocator, io: Io, path: []const u8) !Stats {
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(MAX_JSON_SIZE)) catch return .{};
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
    // Load per-command stats.
    if (parsed.value.object.get("by_cmd")) |by_cmd| {
        if (by_cmd == .object) {
            var it = by_cmd.object.iterator();
            while (it.next()) |kv| {
                if (s.cmd_count >= MAX_TRACKED_CMDS) break;
                const name = kv.key_ptr.*;
                const val = kv.value_ptr.*;
                if (val != .object) continue;
                var entry = &s.by_cmd[s.cmd_count];
                const copy_len = @min(name.len, entry.name.len);
                @memcpy(entry.name[0..copy_len], name[0..copy_len]);
                entry.name_len = copy_len;
                if (val.object.get("n")) |v| {
                    if (v == .integer) entry.stats.n = @intCast(@max(0, v.integer));
                }
                if (val.object.get("in")) |v| {
                    if (v == .integer) entry.stats.in_bytes = @intCast(@max(0, v.integer));
                }
                if (val.object.get("out")) |v| {
                    if (v == .integer) entry.stats.out_bytes = @intCast(@max(0, v.integer));
                }
                s.cmd_count += 1;
            }
        }
    }
    return s;
}

fn saveJson(allocator: Allocator, io: Io, dir_path: []const u8, path: []const u8, s: Stats) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);

    // Build JSON manually — avoids pulling in the stringify machinery.
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("{{\"commands\":{d},\"input_bytes\":{d},\"output_bytes\":{d}", .{
        s.commands, s.input_bytes, s.output_bytes,
    });
    if (s.cmd_count > 0) {
        try w.writeAll(",\"by_cmd\":{");
        for (s.by_cmd[0..s.cmd_count], 0..) |entry, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('"');
            try w.writeAll(entry.nameSlice());
            try w.print("\":{{\"n\":{d},\"in\":{d},\"out\":{d}}}", .{
                entry.stats.n, entry.stats.in_bytes, entry.stats.out_bytes,
            });
        }
        try w.writeByte('}');
    }
    try w.writeAll("}\n");

    try cwd.writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// Handle `--stats` and `--stats --reset`.
pub fn maybeRun(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    args: []const []const u8,
    stdout: *Writer,
) !?u8 {
    if (args.len < 2) return null;
    if (!std.mem.eql(u8, args[1], "--stats")) return null;

    for (args[2..]) |arg| {
        if (std.mem.eql(u8, arg, "--reset")) {
            try reset(io, home);
            try stdout.writeAll("stats reset\n");
            return 0;
        }
    }

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
    const tokens_saved = saved / 4;

    // Header.
    try stdout.writeAll("\n  smll stats\n");
    try stdout.writeAll("  ──────────────────────────────────────\n");
    try stdout.print("  Commands:      {}\n", .{s.commands});
    try stdout.print("  Input:         {} bytes (", .{s.input_bytes});
    try writeHumanBytes(stdout, s.input_bytes);
    try stdout.writeAll(")\n");
    try stdout.print("  Output:        {} bytes (", .{s.output_bytes});
    try writeHumanBytes(stdout, s.output_bytes);
    try stdout.writeAll(")\n");
    try stdout.print("  Saved:         {} bytes (", .{saved});
    try writeHumanBytes(stdout, saved);
    try stdout.print(", {d}%)\n", .{pct});
    try stdout.writeAll("  Tokens saved:  ~");
    try writeHumanCount(stdout, tokens_saved);
    try stdout.print(" (~{})\n", .{tokens_saved});

    // Per-command table sorted by savings descending.
    if (s.cmd_count > 0) {
        try stdout.writeAll("\n  Command              Runs     Input    Output   Saved\n");
        try stdout.writeAll("  ──────────────────────────────────────────────────────\n");

        // Sort by saved bytes descending.
        var indices: [MAX_TRACKED_CMDS]usize = undefined;
        for (0..s.cmd_count) |i| indices[i] = i;
        std.mem.sort(usize, indices[0..s.cmd_count], s.by_cmd[0..s.cmd_count], cmpBySaved);

        for (indices[0..s.cmd_count]) |idx| {
            const entry = &s.by_cmd[idx];
            if (entry.stats.n == 0) continue;
            const cmd_saved = if (entry.stats.in_bytes > entry.stats.out_bytes)
                entry.stats.in_bytes - entry.stats.out_bytes
            else
                0;
            const cmd_pct = if (entry.stats.in_bytes > 0)
                (cmd_saved * 100) / entry.stats.in_bytes
            else
                0;

            // Pad command name to 20 chars.
            const name = entry.nameSlice();
            try stdout.writeAll("  ");
            try stdout.writeAll(name);
            if (name.len < 20) {
                var pad: usize = 20 - name.len;
                while (pad > 0) : (pad -= 1) try stdout.writeByte(' ');
            }
            try stdout.print(" {d: >4}  ", .{entry.stats.n});
            try writeHumanBytesFixed(stdout, entry.stats.in_bytes);
            try stdout.writeAll("  ");
            try writeHumanBytesFixed(stdout, entry.stats.out_bytes);
            try stdout.print("   {d: >2}%\n", .{cmd_pct});
        }
    }
    try stdout.writeByte('\n');
}

fn cmpBySaved(entries: []const CmdEntry, a: usize, b: usize) bool {
    const saved_a = if (entries[a].stats.in_bytes > entries[a].stats.out_bytes)
        entries[a].stats.in_bytes - entries[a].stats.out_bytes
    else
        0;
    const saved_b = if (entries[b].stats.in_bytes > entries[b].stats.out_bytes)
        entries[b].stats.in_bytes - entries[b].stats.out_bytes
    else
        0;
    return saved_a > saved_b;
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

/// Fixed-width human bytes for table columns (8 chars).
fn writeHumanBytesFixed(w: *Writer, bytes: u64) !void {
    if (bytes < 1024) {
        try w.print("{d: >5} B ", .{bytes});
    } else if (bytes < 1024 * 1024) {
        try w.print("{d: >4}.{d} KB", .{ bytes / 1024, (bytes % 1024) * 10 / 1024 });
    } else {
        const mb = bytes / (1024 * 1024);
        const frac = (bytes % (1024 * 1024)) * 10 / (1024 * 1024);
        try w.print("{d: >4}.{d} MB", .{ mb, frac });
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

test "buildLabel: git subcommand" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("git status", buildLabel(&.{ "git", "status" }, &buf));
    try std.testing.expectEqualStrings("git", buildLabel(&.{ "git", "--version" }, &buf));
}

test "buildLabel: plain command" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("cat", buildLabel(&.{ "cat", "file.txt" }, &buf));
    try std.testing.expectEqualStrings("rg", buildLabel(&.{ "rg", "TODO" }, &buf));
}

test "buildLabel: path stripped" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("git status", buildLabel(&.{ "/usr/bin/git", "status" }, &buf));
}

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
