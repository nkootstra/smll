const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const history_file = ".smll/history.jsonl";
const history_lock_file = ".smll/history.lock";
const MAX_TRACKED_CMDS = 32;
const MAX_HISTORY_SIZE = 16 * 1024 * 1024;
const HISTORY_SCHEMA_VERSION = 1;

pub const RecordOptions = struct {
    exit_code: u8 = 0,
    filter_name: []const u8 = "unknown",
    duration_ms: u64 = 0,
};

pub const QueryOptions = struct {
    verbose: bool = false,
    by_command: bool = false,
    project_only: bool = false,
    reset: bool = false,
    since_ms: ?i64 = null,
};

const CmdStats = struct {
    n: u64 = 0,
    in_bytes: u64 = 0,
    out_bytes: u64 = 0,
};

const Entry = struct {
    ts_ms: i64 = 0,
    raw_bytes: u64 = 0,
    compact_bytes: u64 = 0,
    cmd: [64]u8 = [_]u8{0} ** 64,
    cmd_len: usize = 0,
    filter: [64]u8 = [_]u8{0} ** 64,
    filter_len: usize = 0,
    project: [256]u8 = [_]u8{0} ** 256,
    project_len: usize = 0,

    fn cmdSlice(self: *const Entry) []const u8 {
        return self.cmd[0..self.cmd_len];
    }

    fn filterSlice(self: *const Entry) []const u8 {
        return self.filter[0..self.filter_len];
    }

    fn projectSlice(self: *const Entry) []const u8 {
        return self.project[0..self.project_len];
    }
};

const AggEntry = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    stats: CmdStats = .{},
    passthrough_runs: u64 = 0,

    fn nameSlice(self: *const AggEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Aggregate = struct {
    commands: u64 = 0,
    input_bytes: u64 = 0,
    output_bytes: u64 = 0,
    by_cmd: [MAX_TRACKED_CMDS]AggEntry = [_]AggEntry{.{}} ** MAX_TRACKED_CMDS,
    cmd_count: usize = 0,
};

pub fn append(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    dir_path: []const u8,
    label: []const u8,
    input_bytes: usize,
    output_bytes: usize,
    options: RecordOptions,
) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, dir_path);

    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);
    const lock_path = try joinPath(allocator, home, history_lock_file);
    defer allocator.free(lock_path);

    const cwd_path = std.process.currentPathAlloc(io, allocator) catch try allocator.dupeZ(u8, "");
    defer allocator.free(cwd_path);
    const project_key = projectKey(allocator, io, cwd_path) catch try allocator.dupe(u8, cwd_path);
    defer allocator.free(project_key);

    const epoch_ns: i64 = @intCast(Io.Clock.real.now(io).toNanoseconds());
    const epoch_ms = @divTrunc(epoch_ns, std.time.ns_per_ms);

    var line = Writer.Allocating.init(allocator);
    defer line.deinit();
    const w = &line.writer;
    try w.writeAll("{\"v\":");
    try writeU64(w, HISTORY_SCHEMA_VERSION);
    try w.writeAll(",\"ts_ms\":");
    try writeU64(w, @intCast(epoch_ms));
    try w.writeAll(",\"project\":");
    try writeJsonString(w, project_key);
    try w.writeAll(",\"cwd\":");
    try writeJsonString(w, cwd_path);
    try w.writeAll(",\"cmd\":");
    try writeJsonString(w, label);
    try w.writeAll(",\"filter\":");
    try writeJsonString(w, options.filter_name);
    try w.writeAll(",\"exit\":");
    try writeU64(w, options.exit_code);
    try w.writeAll(",\"raw\":");
    try writeU64(w, input_bytes);
    try w.writeAll(",\"compact\":");
    try writeU64(w, output_bytes);
    try w.writeAll(",\"duration_ms\":");
    try writeU64(w, options.duration_ms);
    try w.writeAll("}\n");

    try appendLineBounded(io, history_path, lock_path, line.written(), MAX_HISTORY_SIZE);
}

pub fn reset(allocator: Allocator, io: Io, home: []const u8) !void {
    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);
    Io.Dir.cwd().deleteFile(io, history_path) catch {};
}

pub fn aggregate(allocator: Allocator, io: Io, home: []const u8, opts: QueryOptions) !Aggregate {
    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);

    const data = try readHistoryData(allocator, io, history_path, MAX_HISTORY_SIZE);
    defer allocator.free(data.owned);

    const cutoff_ms: ?i64 = if (opts.since_ms) |since_ms| blk: {
        const epoch_ns: i64 = @intCast(Io.Clock.real.now(io).toNanoseconds());
        const now_ms = @divTrunc(epoch_ns, std.time.ns_per_ms);
        break :blk now_ms - since_ms;
    } else null;

    var project_filter: ?[]u8 = null;
    defer if (project_filter) |p| allocator.free(p);
    if (opts.project_only) {
        const cwd_path = std.process.currentPathAlloc(io, allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(cwd_path);
        project_filter = projectKey(allocator, io, cwd_path) catch try allocator.dupe(u8, cwd_path);
    }

    var agg: Aggregate = .{};
    var lines = std.mem.splitScalar(u8, data.lines, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const entry = parseLine(line) orelse continue;
        if (cutoff_ms) |cutoff| {
            if (entry.ts_ms < cutoff) continue;
        }
        if (project_filter) |project| {
            if (!std.mem.eql(u8, entry.projectSlice(), project)) continue;
        }
        addEntry(&agg, entry);
    }
    return agg;
}

const HistoryData = struct {
    owned: []u8,
    lines: []const u8,
};

fn appendLineBounded(io: Io, history_path: []const u8, lock_path: []const u8, line: []const u8, max_size: usize) !void {
    if (line.len > max_size) return;

    const cwd = Io.Dir.cwd();
    const lock_file = try openLockFile(io, lock_path);
    defer if (lock_file) |file| file.close(io);

    {
        var file = try cwd.createFile(io, history_path, .{ .read = true, .truncate = false });
        defer file.close(io);
        const st = try file.stat(io);
        if (st.size + line.len <= max_size) {
            try file.writePositionalAll(io, line, st.size);
            return;
        }
    }

    var file = try cwd.createFile(io, history_path, .{ .read = true, .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, line, 0);
}

fn openLockFile(io: Io, lock_path: []const u8) !?Io.File {
    return Io.Dir.cwd().createFile(io, lock_path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
    }) catch |err| switch (err) {
        error.FileLocksUnsupported => return null,
        else => |e| return e,
    };
}

fn readHistoryData(allocator: Allocator, io: Io, history_path: []const u8, max_size: usize) !HistoryData {
    const data = Io.Dir.cwd().readFileAlloc(io, history_path, allocator, .limited(max_size)) catch |err| switch (err) {
        error.FileNotFound => {
            const empty = try allocator.alloc(u8, 0);
            return .{ .owned = empty, .lines = empty };
        },
        error.StreamTooLong => return readHistoryTail(allocator, io, history_path, max_size),
        else => |e| return e,
    };
    return .{ .owned = data, .lines = data };
}

fn readHistoryTail(allocator: Allocator, io: Io, history_path: []const u8, max_size: usize) !HistoryData {
    var file = try Io.Dir.cwd().openFile(io, history_path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    const read_len: usize = @intCast(@min(st.size, max_size));
    if (read_len == 0) {
        const empty = try allocator.alloc(u8, 0);
        return .{ .owned = empty, .lines = empty };
    }

    const offset = st.size - read_len;
    const buf = try allocator.alloc(u8, read_len);
    errdefer allocator.free(buf);
    const got = try file.readPositionalAll(io, buf, offset);
    const bytes = buf[0..got];

    if (offset == 0) return .{ .owned = buf, .lines = bytes };
    const start = if (std.mem.indexOfScalar(u8, bytes, '\n')) |idx| idx + 1 else bytes.len;
    return .{ .owned = buf, .lines = bytes[start..] };
}

pub fn displayDiscover(allocator: Allocator, io: Io, home: []const u8, opts: QueryOptions, stdout: *Writer) !void {
    const agg = try aggregate(allocator, io, home, opts);
    if (agg.commands == 0) {
        try stdout.writeAll("no commands recorded yet\n");
        return;
    }

    try stdout.writeAll("\n  smll discover\n");
    try stdout.writeAll("  --------------------------------------\n");
    try stdout.writeAll("  History commands: ");
    try writeU64(stdout, agg.commands);
    try stdout.writeAll("\n\n");

    try stdout.writeAll("  Low savings (<30%):\n");
    try writeDiscoverLowSavings(stdout, agg);
    try stdout.writeAll("\n  Passthrough/no-filter:\n");
    try writeDiscoverPassthrough(stdout, agg);
    try stdout.writeAll("\n  Highest raw output:\n");
    try writeDiscoverTopRaw(stdout, agg);
    try stdout.writeByte('\n');
}

pub fn writeByCommand(stdout: *Writer, agg: Aggregate) !void {
    if (agg.cmd_count == 0) return;
    try stdout.writeAll("\n  Command              Runs     Input     Output    Saved\n");
    try stdout.writeAll("  --------------------------------------------------------\n");

    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndices(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count], .saved);

    for (indices[0..agg.cmd_count]) |idx| {
        const entry = &agg.by_cmd[idx];
        const saved = savedBytes(entry.stats.in_bytes, entry.stats.out_bytes);
        const pct = percentSaved(entry.stats.in_bytes, entry.stats.out_bytes);
        try stdout.writeAll("  ");
        try stdout.writeAll(entry.nameSlice());
        if (entry.name_len < 20) {
            var pad: usize = 20 - entry.name_len;
            while (pad > 0) : (pad -= 1) try stdout.writeByte(' ');
        }
        try stdout.writeByte(' ');
        try writeU64(stdout, entry.stats.n);
        try stdout.writeByte('\t');
        try writeHumanCount(stdout, entry.stats.in_bytes / 4);
        try stdout.writeByte('\t');
        try writeHumanCount(stdout, entry.stats.out_bytes / 4);
        try stdout.writeByte('\t');
        try writeHumanCount(stdout, saved / 4);
        try stdout.writeAll(" (");
        try writeU64(stdout, pct);
        try stdout.writeAll("%)\n");
    }
    try stdout.writeByte('\n');
}

fn parseLine(line: []const u8) ?Entry {
    var entry: Entry = .{};
    entry.ts_ms = @intCast(findJsonU64Opt(line, "\"ts_ms\":") orelse return null);
    entry.raw_bytes = findJsonU64Opt(line, "\"raw\":") orelse return null;
    entry.compact_bytes = findJsonU64Opt(line, "\"compact\":") orelse return null;
    _ = findJsonU64Opt(line, "\"exit\":") orelse return null;
    entry.cmd_len = readJsonStringInto(line, "\"cmd\":", &entry.cmd) orelse return null;
    entry.filter_len = readJsonStringInto(line, "\"filter\":", &entry.filter) orelse return null;
    entry.project_len = readJsonStringInto(line, "\"project\":", &entry.project) orelse return null;
    if (entry.cmd_len == 0) return null;
    return entry;
}

fn addEntry(agg: *Aggregate, entry: Entry) void {
    agg.commands += 1;
    agg.input_bytes += entry.raw_bytes;
    agg.output_bytes += entry.compact_bytes;

    const name = entry.cmdSlice();
    var found: ?*AggEntry = null;
    for (agg.by_cmd[0..agg.cmd_count]) |*candidate| {
        if (std.mem.eql(u8, candidate.nameSlice(), name)) {
            found = candidate;
            break;
        }
    }
    if (found == null and agg.cmd_count < MAX_TRACKED_CMDS) {
        const item = &agg.by_cmd[agg.cmd_count];
        const copy_len = @min(name.len, item.name.len);
        @memcpy(item.name[0..copy_len], name[0..copy_len]);
        item.name_len = copy_len;
        agg.cmd_count += 1;
        found = item;
    }
    if (found) |item| {
        item.stats.n += 1;
        item.stats.in_bytes += entry.raw_bytes;
        item.stats.out_bytes += entry.compact_bytes;
        if (isPassthroughEntry(entry)) item.passthrough_runs += 1;
    }
}

fn isPassthroughEntry(entry: Entry) bool {
    return std.mem.eql(u8, entry.filterSlice(), "passthrough") or
        std.mem.eql(u8, entry.filterSlice(), "unknown") or
        savedBytes(entry.raw_bytes, entry.compact_bytes) == 0;
}

fn writeDiscoverLowSavings(stdout: *Writer, agg: Aggregate) !void {
    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndices(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count], .low_savings);

    var written: usize = 0;
    for (indices[0..agg.cmd_count]) |idx| {
        const entry = &agg.by_cmd[idx];
        if (entry.stats.in_bytes == 0) continue;
        const pct = percentSaved(entry.stats.in_bytes, entry.stats.out_bytes);
        if (pct >= 30) continue;
        try writeDiscoverRow(stdout, entry, pct, savedBytes(entry.stats.in_bytes, entry.stats.out_bytes), null);
        written += 1;
        if (written == 8) break;
    }
    if (written == 0) try stdout.writeAll("    (none)\n");
}

fn writeDiscoverPassthrough(stdout: *Writer, agg: Aggregate) !void {
    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndices(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count], .passthrough);

    var written: usize = 0;
    for (indices[0..agg.cmd_count]) |idx| {
        const entry = &agg.by_cmd[idx];
        if (entry.passthrough_runs == 0) continue;
        const pct = percentSaved(entry.stats.in_bytes, entry.stats.out_bytes);
        try writeDiscoverRow(stdout, entry, pct, savedBytes(entry.stats.in_bytes, entry.stats.out_bytes), entry.passthrough_runs);
        written += 1;
        if (written == 8) break;
    }
    if (written == 0) try stdout.writeAll("    (none)\n");
}

fn writeDiscoverTopRaw(stdout: *Writer, agg: Aggregate) !void {
    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndices(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count], .raw);

    var written: usize = 0;
    for (indices[0..agg.cmd_count]) |idx| {
        const entry = &agg.by_cmd[idx];
        if (entry.stats.in_bytes == 0) continue;
        const pct = percentSaved(entry.stats.in_bytes, entry.stats.out_bytes);
        try writeDiscoverRow(stdout, entry, pct, savedBytes(entry.stats.in_bytes, entry.stats.out_bytes), null);
        written += 1;
        if (written == 8) break;
    }
    if (written == 0) try stdout.writeAll("    (none)\n");
}

fn writeDiscoverRow(stdout: *Writer, entry: *const AggEntry, pct: u64, saved: u64, passthrough_runs: ?u64) !void {
    try stdout.writeAll("    ");
    try stdout.writeAll(entry.nameSlice());
    try stdout.writeAll("  runs=");
    try writeU64(stdout, entry.stats.n);
    try stdout.writeAll(" raw=");
    try writeHumanDecimal(stdout, entry.stats.in_bytes);
    try stdout.writeAll("B saved=");
    try writeHumanDecimal(stdout, saved);
    try stdout.writeAll("B (");
    try writeU64(stdout, pct);
    try stdout.writeByte('%');
    try stdout.writeByte(')');
    if (passthrough_runs) |runs| {
        try stdout.writeAll(" passthrough=");
        try writeU64(stdout, runs);
    }
    try stdout.writeByte('\n');
}

const AggSort = enum { saved, raw, passthrough, low_savings };

fn sortAggIndices(entries: []const AggEntry, indices: []usize, mode: AggSort) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const key = indices[i];
        var j: usize = i;
        while (j > 0 and aggLess(entries, key, indices[j - 1], mode)) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = key;
    }
}

fn aggLess(items: []const AggEntry, a: usize, b: usize, mode: AggSort) bool {
    return switch (mode) {
        .saved => savedBytes(items[a].stats.in_bytes, items[a].stats.out_bytes) >
            savedBytes(items[b].stats.in_bytes, items[b].stats.out_bytes),
        .raw => items[a].stats.in_bytes > items[b].stats.in_bytes,
        .passthrough => if (items[a].passthrough_runs != items[b].passthrough_runs)
            items[a].passthrough_runs > items[b].passthrough_runs
        else
            items[a].stats.in_bytes > items[b].stats.in_bytes,
        .low_savings => blk: {
            const pct_a = percentSaved(items[a].stats.in_bytes, items[a].stats.out_bytes);
            const pct_b = percentSaved(items[b].stats.in_bytes, items[b].stats.out_bytes);
            break :blk if (pct_a != pct_b) pct_a < pct_b else items[a].stats.in_bytes > items[b].stats.in_bytes;
        },
    };
}

fn findJsonU64Opt(data: []const u8, key: []const u8) ?u64 {
    const idx = std.mem.find(u8, data, key) orelse return null;
    var pos = idx + key.len;
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
    if (pos >= data.len or data[pos] < '0' or data[pos] > '9') return null;
    var val: u64 = 0;
    while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') {
        val = val *| 10 +| (data[pos] - '0');
        pos += 1;
    }
    return val;
}

fn readJsonStringInto(data: []const u8, key: []const u8, out: []u8) ?usize {
    const idx = std.mem.find(u8, data, key) orelse return null;
    var pos = idx + key.len;
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
    if (pos >= data.len or data[pos] != '"') return null;
    pos += 1;

    var len: usize = 0;
    while (pos < data.len) : (pos += 1) {
        const c = data[pos];
        if (c == '"') return len;
        if (c == '\\') {
            pos += 1;
            if (pos >= data.len) return null;
            const escaped = switch (data[pos]) {
                '"', '\\', '/' => data[pos],
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => data[pos],
            };
            if (len < out.len) {
                out[len] = escaped;
                len += 1;
            }
            continue;
        }
        if (len < out.len) {
            out[len] = c;
            len += 1;
        }
    }
    return null;
}

fn writeJsonString(w: *Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(if (c < 0x20) ' ' else c),
    };
    try w.writeByte('"');
}

fn projectKey(allocator: Allocator, io: Io, cwd_path: []const u8) ![]u8 {
    var current = cwd_path;
    while (current.len > 0) {
        const git_path = try joinPath(allocator, current, ".git");
        defer allocator.free(git_path);
        Io.Dir.cwd().access(io, git_path, .{}) catch {
            current = dirnameSlice(current) orelse break;
            continue;
        };
        return try allocator.dupe(u8, current);
    }
    return try allocator.dupe(u8, cwd_path);
}

fn dirnameSlice(path: []const u8) ?[]const u8 {
    const idx = std.mem.findScalarLast(u8, path, '/') orelse return null;
    if (idx == 0) return path[0..1];
    return path[0..idx];
}

fn savedBytes(input_bytes: u64, output_bytes: u64) u64 {
    return if (input_bytes > output_bytes) input_bytes - output_bytes else 0;
}

fn percentSaved(input_bytes: u64, output_bytes: u64) u64 {
    if (input_bytes == 0) return 0;
    return (savedBytes(input_bytes, output_bytes) * 100) / input_bytes;
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

fn writeHumanDecimal(w: *Writer, n: u64) !void {
    if (n < 1000) {
        try writeU64(w, n);
    } else if (n < 1_000_000) {
        try writeDecimalUnit(w, n, 1000, 'K');
    } else if (n < 1_000_000_000) {
        try writeDecimalUnit(w, n, 1_000_000, 'M');
    } else {
        try writeDecimalUnit(w, n, 1_000_000_000, 'G');
    }
}

fn writeDecimalUnit(w: *Writer, n: u64, unit: u64, suffix: u8) !void {
    try writeU64(w, n / unit);
    try w.writeByte('.');
    try writeU64(w, (n % unit) * 10 / unit);
    try w.writeByte(suffix);
}

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

test "history aggregation skips malformed lines and applies since" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");

    const project = try currentProjectForTest(allocator);
    defer allocator.free(project);
    const now_ns: i128 = Io.Clock.real.now(std.testing.io).toNanoseconds();
    const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));

    var content = Writer.Allocating.init(allocator);
    defer content.deinit();
    try content.writer.writeAll("not-json\n");
    try writeFixtureLine(&content.writer, now_ms - 2 * 24 * 60 * 60 * 1000, project, "old", "passthrough", 100, 100);
    try writeFixtureLine(&content.writer, now_ms, project, "new", "rg", 200, 40);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/history.jsonl", .data = content.written() });

    const agg = try aggregate(allocator, std.testing.io, home, .{ .since_ms = 24 * 60 * 60 * 1000 });
    try std.testing.expectEqual(@as(u64, 1), agg.commands);
    try std.testing.expectEqual(@as(u64, 200), agg.input_bytes);
    try std.testing.expectEqual(@as(u64, 40), agg.output_bytes);
    try std.testing.expectEqualStrings("new", agg.by_cmd[0].nameSlice());
}

test "history aggregation filters to current project" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");

    const project = try currentProjectForTest(allocator);
    defer allocator.free(project);
    const now_ns: i128 = Io.Clock.real.now(std.testing.io).toNanoseconds();
    const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));

    var content = Writer.Allocating.init(allocator);
    defer content.deinit();
    try writeFixtureLine(&content.writer, now_ms, "/tmp/other-smll-project", "other", "passthrough", 500, 500);
    try writeFixtureLine(&content.writer, now_ms, project, "current", "rg", 300, 60);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/history.jsonl", .data = content.written() });

    const agg = try aggregate(allocator, std.testing.io, home, .{ .project_only = true });
    try std.testing.expectEqual(@as(u64, 1), agg.commands);
    try std.testing.expectEqualStrings("current", agg.by_cmd[0].nameSlice());
}

test "discover reports low savings passthrough and top raw commands" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");

    const project = try currentProjectForTest(allocator);
    defer allocator.free(project);
    const now_ns: i128 = Io.Clock.real.now(std.testing.io).toNanoseconds();
    const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));

    var content = Writer.Allocating.init(allocator);
    defer content.deinit();
    try writeFixtureLine(&content.writer, now_ms, project, "low-save", "generic", 1000, 900);
    try writeFixtureLine(&content.writer, now_ms, project, "passthrough-cmd", "passthrough", 200, 200);
    try writeFixtureLine(&content.writer, now_ms, project, "huge-raw", "rg", 5000, 1000);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/history.jsonl", .data = content.written() });

    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try displayDiscover(allocator, std.testing.io, home, .{}, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "Low savings (<30%)") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "low-save") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Passthrough/no-filter") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "passthrough-cmd") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Highest raw output") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "huge-raw") != null);
}

test "history append truncates before exceeding size cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/history.jsonl", .data = "old-1\nold-2\n" });

    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);
    const lock_path = try joinPath(allocator, home, history_lock_file);
    defer allocator.free(lock_path);
    try appendLineBounded(std.testing.io, history_path, lock_path, "new\n", 12);

    const got = try tmp.dir.readFileAlloc(std.testing.io, ".smll/history.jsonl", allocator, .limited(32));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("new\n", got);
}

test "history reader tails oversized files from a complete line" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");

    const project = try currentProjectForTest(allocator);
    defer allocator.free(project);
    const now_ns: i128 = Io.Clock.real.now(std.testing.io).toNanoseconds();
    const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));

    var content = Writer.Allocating.init(allocator);
    defer content.deinit();
    try content.writer.writeAll("stale-partial-prefix-that-will-be-cut\n");
    try writeFixtureLine(&content.writer, now_ms, project, "keep-a", "rg", 100, 50);
    try writeFixtureLine(&content.writer, now_ms, project, "keep-b", "rg", 200, 80);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/history.jsonl", .data = content.written() });

    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);
    const data = try readHistoryData(allocator, std.testing.io, history_path, content.written().len - 8);
    defer allocator.free(data.owned);

    try std.testing.expect(!std.mem.startsWith(u8, data.lines, "partial-prefix"));
    try std.testing.expect(std.mem.find(u8, data.lines, "\"cmd\":\"keep-a\"") != null);
    try std.testing.expect(std.mem.find(u8, data.lines, "\"cmd\":\"keep-b\"") != null);
}

fn currentProjectForTest(allocator: Allocator) ![]u8 {
    const cwd_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd_path);
    return projectKey(allocator, std.testing.io, cwd_path) catch try allocator.dupe(u8, cwd_path);
}

fn writeFixtureLine(
    w: *Writer,
    ts_ms: i64,
    project: []const u8,
    cmd: []const u8,
    filter: []const u8,
    raw_bytes: u64,
    compact_bytes: u64,
) !void {
    try w.writeAll("{\"v\":1,\"ts_ms\":");
    try writeU64(w, @intCast(ts_ms));
    try w.writeAll(",\"project\":");
    try writeJsonString(w, project);
    try w.writeAll(",\"cwd\":");
    try writeJsonString(w, project);
    try w.writeAll(",\"cmd\":");
    try writeJsonString(w, cmd);
    try w.writeAll(",\"filter\":");
    try writeJsonString(w, filter);
    try w.writeAll(",\"exit\":0,\"raw\":");
    try writeU64(w, raw_bytes);
    try w.writeAll(",\"compact\":");
    try writeU64(w, compact_bytes);
    try w.writeAll(",\"duration_ms\":1}\n");
}
