const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

/// Cumulative token-savings stats stored in ~/.smll/stats.json.
/// Best-effort: stats failures never block command execution.
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

// --- helpers to avoid std.fmt ---

fn writeU64(w: *Writer, val: u64) !void {
    var buf: [20]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    if (n == 0) {
        try w.writeByte('0');
        return;
    }
    while (n > 0) {
        i -= 1;
        buf[i] = @intCast('0' + n % 10);
        n /= 10;
    }
    try w.writeAll(buf[i..]);
}

fn joinPath(allocator: Allocator, a: []const u8, b: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, a.len + 1 + b.len);
    @memcpy(buf[0..a.len], a);
    buf[a.len] = '/';
    @memcpy(buf[a.len + 1 ..], b);
    return buf;
}

/// Record a completed command's byte counts. Best-effort.
pub fn record(allocator: Allocator, io: Io, home: []const u8, argv: []const []const u8, input_bytes: usize, output_bytes: usize) void {
    recordInner(allocator, io, home, argv, input_bytes, output_bytes) catch {};
}

fn recordInner(allocator: Allocator, io: Io, home: []const u8, argv: []const []const u8, input_bytes: usize, output_bytes: usize) !void {
    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);
    const dir_path = try joinPath(allocator, home, stats_dir);
    defer allocator.free(dir_path);

    var s = load(allocator, io, path);
    s.commands += 1;
    s.input_bytes += input_bytes;
    s.output_bytes += output_bytes;

    var label_buf: [64]u8 = undefined;
    const label = buildLabel(argv, &label_buf);

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
                if (basename.len + 1 + sub.len <= buf.len) {
                    @memcpy(buf[0..basename.len], basename);
                    buf[basename.len] = ' ';
                    @memcpy(buf[basename.len + 1 ..][0..sub.len], sub);
                    return buf[0 .. basename.len + 1 + sub.len];
                }
                return basename;
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
    // Hand-rolled parser for the fixed stats JSON schema.
    s.commands = findJsonU64(data, "\"commands\":");
    s.input_bytes = findJsonU64(data, "\"input_bytes\":");
    s.output_bytes = findJsonU64(data, "\"output_bytes\":");
    const by_cmd_marker = "\"by_cmd\":{";
    const by_cmd_start = std.mem.find(u8, data, by_cmd_marker) orelse return s;
    var pos = by_cmd_start + by_cmd_marker.len;
    while (pos < data.len and s.cmd_count < MAX_TRACKED_CMDS) {
        while (pos < data.len and (data[pos] == ' ' or data[pos] == ',' or data[pos] == '\n' or data[pos] == '\r' or data[pos] == '\t')) pos += 1;
        if (pos >= data.len or data[pos] == '}') break;
        if (data[pos] != '"') break;
        pos += 1;
        const key_start = pos;
        while (pos < data.len and data[pos] != '"') pos += 1;
        const key = data[key_start..pos];
        if (pos < data.len) pos += 1;
        while (pos < data.len and data[pos] != '{') pos += 1;
        if (pos >= data.len) break;
        const obj_start = pos;
        var depth: usize = 0;
        while (pos < data.len) : (pos += 1) {
            if (data[pos] == '{') {
                depth += 1;
            } else if (data[pos] == '}') {
                depth -= 1;
                if (depth == 0) {
                    pos += 1;
                    break;
                }
            }
        }
        const obj_slice = data[obj_start..pos];
        var entry = &s.by_cmd[s.cmd_count];
        const copy_len = @min(key.len, entry.name.len);
        @memcpy(entry.name[0..copy_len], key[0..copy_len]);
        entry.name_len = copy_len;
        entry.stats.n = findJsonU64(obj_slice, "\"n\":");
        entry.stats.in_bytes = findJsonU64(obj_slice, "\"in\":");
        entry.stats.out_bytes = findJsonU64(obj_slice, "\"out\":");
        s.cmd_count += 1;
    }
    return s;
}

fn findJsonU64(data: []const u8, key: []const u8) u64 {
    const idx = std.mem.find(u8, data, key) orelse return 0;
    var pos = idx + key.len;
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
    var val: u64 = 0;
    while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') {
        val = val *| 10 +| (data[pos] - '0');
        pos += 1;
    }
    return val;
}

fn saveJson(allocator: Allocator, io: Io, dir_path: []const u8, path: []const u8, s: Stats) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);

    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"commands\":");
    try writeU64(w, s.commands);
    try w.writeAll(",\"input_bytes\":");
    try writeU64(w, s.input_bytes);
    try w.writeAll(",\"output_bytes\":");
    try writeU64(w, s.output_bytes);
    if (s.cmd_count > 0) {
        try w.writeAll(",\"by_cmd\":{");
        for (s.by_cmd[0..s.cmd_count], 0..) |entry, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('"');
            try w.writeAll(entry.nameSlice());
            try w.writeAll("\":{\"n\":");
            try writeU64(w, entry.stats.n);
            try w.writeAll(",\"in\":");
            try writeU64(w, entry.stats.in_bytes);
            try w.writeAll(",\"out\":");
            try writeU64(w, entry.stats.out_bytes);
            try w.writeByte('}');
        }
        try w.writeByte('}');
    }
    try w.writeAll("}\n");

    // Atomic write: stage to <path>.tmp then rename. Avoids leaving a
    // half-written stats file if the process is interrupted, and gives
    // last-writer-wins semantics under concurrent invocations rather than
    // arbitrary interleavings of two partial writes.
    const tmp_path = try allocator.alloc(u8, path.len + 4);
    defer allocator.free(tmp_path);
    @memcpy(tmp_path[0..path.len], path);
    @memcpy(tmp_path[path.len..], ".tmp");

    try cwd.writeFile(io, .{ .sub_path = tmp_path, .data = out.written() });
    cwd.rename(tmp_path, cwd, path, io) catch |err| {
        cwd.deleteFile(io, tmp_path) catch {};
        return err;
    };
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
            try reset(allocator, io, home);
            try stdout.writeAll("stats reset\n");
            return 0;
        }
    }

    try display(allocator, io, home, stdout);
    return 0;
}

fn reset(allocator: Allocator, io: Io, home: []const u8) !void {
    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn display(allocator: Allocator, io: Io, home: []const u8, stdout: *Writer) !void {
    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);
    const s = load(allocator, io, path);

    if (s.commands == 0) {
        try stdout.writeAll("no commands recorded yet\n");
        return;
    }

    const saved = if (s.input_bytes > s.output_bytes) s.input_bytes - s.output_bytes else 0;
    const pct = if (s.input_bytes > 0) (saved * 100) / s.input_bytes else 0;
    const tokens_saved = saved / 4;

    try stdout.writeAll("\n  smll stats\n");
    try stdout.writeAll("  --------------------------------------\n");
    try stdout.writeAll("  Commands:      ");
    try writeU64(stdout, s.commands);
    try stdout.writeByte('\n');
    try stdout.writeAll("  Input:         ");
    try writeU64(stdout, s.input_bytes);
    try stdout.writeAll(" bytes (");
    try writeHumanBytes(stdout, s.input_bytes);
    try stdout.writeAll(")\n  Output:        ");
    try writeU64(stdout, s.output_bytes);
    try stdout.writeAll(" bytes (");
    try writeHumanBytes(stdout, s.output_bytes);
    try stdout.writeAll(")\n  Saved:         ");
    try writeU64(stdout, saved);
    try stdout.writeAll(" bytes (");
    try writeHumanBytes(stdout, saved);
    try stdout.writeAll(", ");
    try writeU64(stdout, pct);
    try stdout.writeAll("%)\n");
    try stdout.writeAll("  Est. tokens saved: ~");
    try writeHumanCount(stdout, tokens_saved);
    try stdout.writeAll(" (~");
    try writeU64(stdout, tokens_saved);
    try stdout.writeAll(")\n");

    if (s.cmd_count > 0) {
        try stdout.writeAll("\n  Command              Runs     Input    Output   Saved\n");
        try stdout.writeAll("  ------------------------------------------------------\n");

        var indices: [MAX_TRACKED_CMDS]usize = undefined;
        for (0..s.cmd_count) |i| indices[i] = i;
        {
            var si: usize = 1;
            while (si < s.cmd_count) : (si += 1) {
                const key = indices[si];
                var sj: usize = si;
                while (sj > 0 and cmpBySaved(s.by_cmd[0..s.cmd_count], key, indices[sj - 1])) : (sj -= 1) {
                    indices[sj] = indices[sj - 1];
                }
                indices[sj] = key;
            }
        }

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

            const name = entry.nameSlice();
            try stdout.writeAll("  ");
            try stdout.writeAll(name);
            if (name.len < 20) {
                var pad: usize = 20 - name.len;
                while (pad > 0) : (pad -= 1) try stdout.writeByte(' ');
            }
            try stdout.writeByte(' ');
            try writeU64(stdout, entry.stats.n);
            try stdout.writeByte('\t');
            try writeHumanBytes(stdout, entry.stats.in_bytes);
            try stdout.writeByte('\t');
            try writeHumanBytes(stdout, entry.stats.out_bytes);
            try stdout.writeByte('\t');
            try writeU64(stdout, cmd_pct);
            try stdout.writeAll("%\n");
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
        try writeU64(w, bytes);
        try w.writeAll(" B");
    } else if (bytes < 1024 * 1024) {
        try writeU64(w, bytes / 1024);
        try w.writeByte('.');
        try writeU64(w, (bytes % 1024) * 10 / 1024);
        try w.writeAll(" KB");
    } else if (bytes < 1024 * 1024 * 1024) {
        try writeU64(w, bytes / (1024 * 1024));
        try w.writeByte('.');
        try writeU64(w, (bytes % (1024 * 1024)) * 10 / (1024 * 1024));
        try w.writeAll(" MB");
    } else {
        try writeU64(w, bytes / (1024 * 1024 * 1024));
        try w.writeByte('.');
        try writeU64(w, (bytes % (1024 * 1024 * 1024)) * 10 / (1024 * 1024 * 1024));
        try w.writeAll(" GB");
    }
}

fn writeHumanCount(w: *Writer, n: u64) !void {
    if (n < 1000) {
        try writeU64(w, n);
    } else if (n < 1_000_000) {
        try writeU64(w, n / 1000);
        try w.writeByte('.');
        try writeU64(w, (n % 1000) / 100);
        try w.writeByte('K');
    } else {
        try writeU64(w, n / 1_000_000);
        try w.writeByte('.');
        try writeU64(w, (n % 1_000_000) / 100_000);
        try w.writeByte('M');
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
