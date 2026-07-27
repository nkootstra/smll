const std = @import("std");
const accounting = @import("accounting.zig");
const state_io = @import("state_io.zig");
const util = @import("util");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const history_file = ".smll/history.jsonl";
const history_lock_file = ".smll/history.lock";
const MAX_TRACKED_CMDS = 32;
const MAX_HISTORY_SIZE = 16 * 1024 * 1024;
const HISTORY_SCHEMA_VERSION = 2;

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
    all: bool = false,
    since_ms: ?i64 = null,
};

const CmdStats = struct {
    n: u64 = 0,
    raw_bytes: u64 = 0,
    displayed_bytes: u64 = 0,
    omitted_bytes: u64 = 0,
    diagnostic_bytes: u64 = 0,
    formatting_saved_bytes: u64 = 0,
};

const Entry = struct {
    ts_ms: i64 = 0,
    raw_bytes: u64 = 0,
    displayed_bytes: u64 = 0,
    omitted_bytes: u64 = 0,
    diagnostic_bytes: u64 = 0,
    formatting_saved_bytes: u64 = 0,
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
    raw_bytes: u64 = 0,
    displayed_bytes: u64 = 0,
    omitted_bytes: u64 = 0,
    diagnostic_bytes: u64 = 0,
    formatting_saved_bytes: u64 = 0,
    by_cmd: [MAX_TRACKED_CMDS]AggEntry = undefined,
    cmd_count: usize = 0,
};

pub fn append(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    dir_path: []const u8,
    label: []const u8,
    bytes: accounting.Bytes,
    options: RecordOptions,
) !void {
    return appendInner(allocator, io, home, dir_path, label, bytes, options, true);
}

pub fn appendUnderStateLock(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    dir_path: []const u8,
    label: []const u8,
    bytes: accounting.Bytes,
    options: RecordOptions,
) !void {
    return appendInner(allocator, io, home, dir_path, label, bytes, options, false);
}

fn appendInner(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    dir_path: []const u8,
    label: []const u8,
    bytes: accounting.Bytes,
    options: RecordOptions,
    acquire_history_lock: bool,
) !void {
    try state_io.ensurePrivateDir(io, dir_path);

    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);

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
    try writeU64(w, bytes.raw_bytes);
    try w.writeAll(",\"displayed\":");
    try writeU64(w, bytes.displayed_bytes);
    try w.writeAll(",\"omitted\":");
    try writeU64(w, bytes.omitted_bytes);
    try w.writeAll(",\"diagnostics\":");
    try writeU64(w, bytes.diagnostic_bytes);
    try w.writeAll(",\"saved\":");
    try writeU64(w, bytes.formatting_saved_bytes);
    try w.writeAll(",\"duration_ms\":");
    try writeU64(w, options.duration_ms);
    try w.writeAll("}\n");

    if (acquire_history_lock) {
        const lock_path = try joinPath(allocator, home, history_lock_file);
        defer allocator.free(lock_path);
        try appendLineBounded(allocator, io, history_path, lock_path, line.written(), MAX_HISTORY_SIZE);
    } else {
        try appendLineBoundedUnlocked(allocator, io, history_path, line.written(), MAX_HISTORY_SIZE);
    }
}

pub fn reset(allocator: Allocator, io: Io, home: []const u8) !void {
    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);
    Io.Dir.cwd().deleteFile(io, history_path) catch {};
}

pub fn aggregate(allocator: Allocator, io: Io, home: []const u8, opts: QueryOptions) !Aggregate {
    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);

    const data = try readHistorySnapshot(allocator, io, home, history_path, MAX_HISTORY_SIZE);
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

    var agg: Aggregate = undefined;
    agg.commands = 0;
    agg.raw_bytes = 0;
    agg.displayed_bytes = 0;
    agg.omitted_bytes = 0;
    agg.diagnostic_bytes = 0;
    agg.formatting_saved_bytes = 0;
    agg.cmd_count = 0;
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

fn readHistorySnapshot(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    history_path: []const u8,
    max_size: usize,
) !HistoryData {
    const state_lock = state_io.openStateLock(allocator, io, home) catch
        return readHistoryTailOrEmpty(allocator, io, history_path, max_size);
    defer if (state_lock) |file| file.close(io);
    return readHistoryTailOrEmpty(allocator, io, history_path, max_size);
}

fn readHistoryTailOrEmpty(allocator: Allocator, io: Io, history_path: []const u8, max_size: usize) !HistoryData {
    return readHistoryTail(allocator, io, history_path, max_size) catch |err| switch (err) {
        error.FileNotFound => emptyHistoryData(allocator),
        else => |e| return e,
    };
}

fn appendLineBounded(allocator: Allocator, io: Io, history_path: []const u8, lock_path: []const u8, line: []const u8, max_size: usize) !void {
    if (line.len > max_size) return;

    const lock_file = try openLockFile(io, lock_path);
    defer if (lock_file) |file| file.close(io);

    try appendLineBoundedUnlocked(allocator, io, history_path, line, max_size);
}

fn appendLineBoundedUnlocked(allocator: Allocator, io: Io, history_path: []const u8, line: []const u8, max_size: usize) !void {
    if (line.len > max_size) return;

    {
        var file = try state_io.createPrivateFile(io, history_path, .{ .read = true, .truncate = false });
        defer file.close(io);
        const st = try file.stat(io);
        if (st.size + line.len <= max_size) {
            try file.writePositionalAll(io, line, st.size);
            return;
        }
    }

    // Overflow: keep the newest half of history instead of discarding it all.
    // Read the tail (line-aligned), rewrite it, then append the new line.
    // Best-effort: a failed tail read degrades to keeping only the new line.
    //
    // Budget the tail at max_size/2 to amortize compaction, but never more than
    // max_size - line.len so tail_lines + line is strictly bounded by max_size
    // even when a single line exceeds half the cap (line.len <= max_size here).
    const tail_budget = @min(max_size / 2, max_size - line.len);
    const maybe_tail: ?HistoryData = readHistoryTail(allocator, io, history_path, tail_budget) catch null;
    defer if (maybe_tail) |t| allocator.free(t.owned);
    const tail_lines: []const u8 = if (maybe_tail) |t| t.lines else "";

    var file = try state_io.createPrivateFile(io, history_path, .{ .read = true, .truncate = true });
    defer file.close(io);
    try file.writePositionalAll(io, tail_lines, 0);
    try file.writePositionalAll(io, line, tail_lines.len);
}

fn openLockFile(io: Io, lock_path: []const u8) !?Io.File {
    return state_io.openExclusivePrivateLock(io, lock_path);
}

fn emptyHistoryData(allocator: Allocator) !HistoryData {
    const empty = try allocator.alloc(u8, 0);
    return .{ .owned = empty, .lines = empty };
}

fn readHistoryTail(allocator: Allocator, io: Io, history_path: []const u8, max_size: usize) !HistoryData {
    var file = try Io.Dir.cwd().openFile(io, history_path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    const read_len: usize = @intCast(@min(st.size, max_size));
    if (read_len == 0) return emptyHistoryData(allocator);

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
    try stdout.writeAll("\n  Command              Runs    Raw tok  Display tok  Saved tok\n");
    try stdout.writeAll("  -----------------------------------------------------------\n");

    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndices(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count], .saved);

    for (indices[0..agg.cmd_count]) |idx| {
        const entry = &agg.by_cmd[idx];
        const saved = entry.stats.formatting_saved_bytes;
        const pct = percentSaved(entry.stats.raw_bytes, saved);
        try stdout.writeAll("  ");
        try writePaddedRight(stdout, entry.nameSlice(), 20);
        try stdout.writeAll("  ");
        try writeU64PaddedLeft(stdout, entry.stats.n, 4);
        try stdout.writeAll("  ");
        try writeHumanCountPaddedLeft(stdout, entry.stats.raw_bytes / 4, 9);
        try stdout.writeAll("  ");
        try writeHumanCountPaddedLeft(stdout, entry.stats.displayed_bytes / 4, 10);
        try stdout.writeAll("  ");
        try writeHumanCountPaddedLeft(stdout, saved / 4, 9);
        try stdout.writeAll(" (");
        try writeU64(stdout, pct);
        try stdout.writeAll("%)\n");
    }
    try stdout.writeByte('\n');
}

fn parseLine(line: []const u8) ?Entry {
    var entry: Entry = .{};
    const version = util.findJsonU64Opt(line, "\"v\":") orelse 1;
    entry.ts_ms = std.math.cast(i64, util.findJsonU64Opt(line, "\"ts_ms\":") orelse return null) orelse return null;
    entry.raw_bytes = util.findJsonU64Opt(line, "\"raw\":") orelse return null;
    if (version >= 2) {
        entry.displayed_bytes = util.findJsonU64Opt(line, "\"displayed\":") orelse return null;
        entry.omitted_bytes = util.findJsonU64Opt(line, "\"omitted\":") orelse return null;
        entry.diagnostic_bytes = util.findJsonU64Opt(line, "\"diagnostics\":") orelse return null;
        entry.formatting_saved_bytes = util.findJsonU64Opt(line, "\"saved\":") orelse return null;
    } else {
        entry.displayed_bytes = util.findJsonU64Opt(line, "\"compact\":") orelse return null;
        entry.formatting_saved_bytes = 0;
    }
    _ = util.findJsonU64Opt(line, "\"exit\":") orelse return null;
    entry.cmd_len = readJsonStringInto(line, "\"cmd\":", &entry.cmd) orelse return null;
    entry.filter_len = readJsonStringInto(line, "\"filter\":", &entry.filter) orelse return null;
    entry.project_len = readJsonStringInto(line, "\"project\":", &entry.project) orelse return null;
    if (entry.cmd_len == 0) return null;
    return entry;
}

fn addEntry(agg: *Aggregate, entry: Entry) void {
    agg.commands += 1;
    agg.raw_bytes += entry.raw_bytes;
    agg.displayed_bytes += entry.displayed_bytes;
    agg.omitted_bytes += entry.omitted_bytes;
    agg.diagnostic_bytes += entry.diagnostic_bytes;
    agg.formatting_saved_bytes += entry.formatting_saved_bytes;

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
        item.* = .{};
        const copy_len = @min(name.len, item.name.len);
        @memcpy(item.name[0..copy_len], name[0..copy_len]);
        item.name_len = copy_len;
        agg.cmd_count += 1;
        found = item;
    }
    if (found) |item| {
        item.stats.n += 1;
        item.stats.raw_bytes += entry.raw_bytes;
        item.stats.displayed_bytes += entry.displayed_bytes;
        item.stats.omitted_bytes += entry.omitted_bytes;
        item.stats.diagnostic_bytes += entry.diagnostic_bytes;
        item.stats.formatting_saved_bytes += entry.formatting_saved_bytes;
        if (isPassthroughEntry(entry)) item.passthrough_runs += 1;
    }
}

fn isPassthroughEntry(entry: Entry) bool {
    return std.mem.eql(u8, entry.filterSlice(), "passthrough") or
        std.mem.eql(u8, entry.filterSlice(), "unknown") or
        entry.formatting_saved_bytes == 0;
}

fn writeDiscoverLowSavings(stdout: *Writer, agg: Aggregate) !void {
    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndices(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count], .low_savings);

    var written: usize = 0;
    for (indices[0..agg.cmd_count]) |idx| {
        const entry = &agg.by_cmd[idx];
        if (entry.stats.raw_bytes == 0) continue;
        const pct = percentSaved(entry.stats.raw_bytes, entry.stats.formatting_saved_bytes);
        if (pct >= 30) continue;
        try writeDiscoverRow(stdout, entry, pct, entry.stats.formatting_saved_bytes, null);
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
        const pct = percentSaved(entry.stats.raw_bytes, entry.stats.formatting_saved_bytes);
        try writeDiscoverRow(stdout, entry, pct, entry.stats.formatting_saved_bytes, entry.passthrough_runs);
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
        if (entry.stats.raw_bytes == 0) continue;
        const pct = percentSaved(entry.stats.raw_bytes, entry.stats.formatting_saved_bytes);
        try writeDiscoverRow(stdout, entry, pct, entry.stats.formatting_saved_bytes, null);
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
    try writeHumanDecimal(stdout, entry.stats.raw_bytes);
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
        .saved => items[a].stats.formatting_saved_bytes > items[b].stats.formatting_saved_bytes,
        .raw => items[a].stats.raw_bytes > items[b].stats.raw_bytes,
        .passthrough => if (items[a].passthrough_runs != items[b].passthrough_runs)
            items[a].passthrough_runs > items[b].passthrough_runs
        else
            items[a].stats.raw_bytes > items[b].stats.raw_bytes,
        .low_savings => blk: {
            const pct_a = percentSaved(items[a].stats.raw_bytes, items[a].stats.formatting_saved_bytes);
            const pct_b = percentSaved(items[b].stats.raw_bytes, items[b].stats.formatting_saved_bytes);
            break :blk if (pct_a != pct_b) pct_a < pct_b else items[a].stats.raw_bytes > items[b].stats.raw_bytes;
        },
    };
}

fn readJsonStringInto(data: []const u8, key: []const u8, out: []u8) ?usize {
    const idx = std.mem.find(u8, data, key) orelse return null;
    var pos = idx + key.len;
    return readJsonStringAt(data, &pos, out);
}

pub fn readJsonStringAt(data: []const u8, pos_ptr: *usize, out: []u8) ?usize {
    var pos = pos_ptr.*;
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
    if (pos >= data.len or data[pos] != '"') return null;
    pos += 1;
    var len: usize = 0;
    while (pos < data.len) : (pos += 1) {
        const c = data[pos];
        if (c == '"') {
            pos_ptr.* = pos + 1;
            return len;
        }
        const decoded = if (c == '\\') blk: {
            pos += 1;
            if (pos >= data.len) return null;
            break :blk switch (data[pos]) {
                '"', '\\', '/' => data[pos],
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => unicode: {
                    if (pos + 4 >= data.len or data[pos + 1] != '0' or data[pos + 2] != '0') return null;
                    const high = hexValue(data[pos + 3]) orelse return null;
                    const low = hexValue(data[pos + 4]) orelse return null;
                    pos += 4;
                    break :unicode high * 16 + low;
                },
                else => return null,
            };
        } else c;
        if (len < out.len) {
            out[len] = decoded;
            len += 1;
        }
    }
    return null;
}

pub const writeJsonString = util.writeJsonString;

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
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

fn percentSaved(raw_bytes: u64, formatting_saved_bytes: u64) u64 {
    if (raw_bytes == 0) return 0;
    return (formatting_saved_bytes * 100) / raw_bytes;
}

const writeHumanCount = util.writeHumanCount;

fn writeHumanCountPaddedLeft(w: *Writer, n: u64, width: usize) !void {
    var buf: [24]u8 = undefined;
    const text = try formatHumanCount(&buf, n);
    try writePaddedLeft(w, text, width);
}

fn formatHumanCount(buf: []u8, n: u64) ![]const u8 {
    return util.formatHumanCount(buf, n);
}

fn writeU64PaddedLeft(w: *Writer, n: u64, width: usize) !void {
    var buf: [20]u8 = undefined;
    const text = util.formatDecimal(&buf, n);
    try writePaddedLeft(w, text, width);
}

fn writePaddedLeft(w: *Writer, text: []const u8, width: usize) !void {
    if (text.len < width) try writeSpaces(w, width - text.len);
    try w.writeAll(text);
}

fn writePaddedRight(w: *Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    if (text.len < width) try writeSpaces(w, width - text.len);
}

fn writeSpaces(w: *Writer, count: usize) !void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) try w.writeByte(' ');
}

const writeHumanDecimal = util.writeHumanDecimal;

const writeU64 = util.writeDecimal;
const joinPath = util.joinPath;

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
    try std.testing.expectEqual(@as(u64, 200), agg.raw_bytes);
    try std.testing.expectEqual(@as(u64, 40), agg.displayed_bytes);
    try std.testing.expectEqual(@as(u64, 160), agg.formatting_saved_bytes);
    try std.testing.expectEqualStrings("new", agg.by_cmd[0].nameSlice());
}

test "history parser skips oversized timestamps" {
    const line =
        "{\"v\":1,\"ts_ms\":18446744073709551616,\"project\":\"p\",\"cwd\":\"p\"," ++
        "\"cmd\":\"bad\",\"filter\":\"rg\",\"exit\":0,\"raw\":1,\"compact\":0,\"duration_ms\":1}";

    try std.testing.expect(parseLine(line) == null);
}

test "history parser skips oversized byte counts" {
    const line =
        "{\"v\":1,\"ts_ms\":1,\"project\":\"p\",\"cwd\":\"p\"," ++
        "\"cmd\":\"bad\",\"filter\":\"rg\",\"exit\":0,\"raw\":18446744073709551616,\"compact\":0,\"duration_ms\":1}";

    try std.testing.expect(parseLine(line) == null);
}

test "history parser migrates v1 and reads v2 accounting" {
    const v1 =
        "{\"v\":1,\"ts_ms\":1,\"project\":\"p\",\"cwd\":\"p\"," ++
        "\"cmd\":\"old\",\"filter\":\"rg\",\"exit\":0,\"raw\":100,\"compact\":40,\"duration_ms\":1}";
    const old = parseLine(v1).?;
    try std.testing.expectEqual(@as(u64, 100), old.raw_bytes);
    try std.testing.expectEqual(@as(u64, 40), old.displayed_bytes);
    try std.testing.expectEqual(@as(u64, 0), old.formatting_saved_bytes);
    try std.testing.expectEqual(@as(u64, 0), old.omitted_bytes);
    try std.testing.expectEqual(@as(u64, 0), old.diagnostic_bytes);

    const v2 =
        "{\"v\":2,\"ts_ms\":1,\"project\":\"p\",\"cwd\":\"p\"," ++
        "\"cmd\":\"new\",\"filter\":\"rg\",\"exit\":0,\"raw\":100," ++
        "\"displayed\":55,\"omitted\":20,\"diagnostics\":5,\"saved\":30,\"duration_ms\":1}";
    const current = parseLine(v2).?;
    try std.testing.expectEqual(@as(u64, 55), current.displayed_bytes);
    try std.testing.expectEqual(@as(u64, 20), current.omitted_bytes);
    try std.testing.expectEqual(@as(u64, 5), current.diagnostic_bytes);
    try std.testing.expectEqual(@as(u64, 30), current.formatting_saved_bytes);
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

test "by-command stats label token estimates and avoid tabs" {
    const allocator = std.testing.allocator;
    var agg: Aggregate = .{
        .commands = 2,
        .raw_bytes = 1000,
        .displayed_bytes = 500,
        .formatting_saved_bytes = 500,
    };
    agg.cmd_count = 2;
    agg.by_cmd[0] = .{};
    agg.by_cmd[1] = .{};

    const status = "git status";
    @memcpy(agg.by_cmd[0].name[0..status.len], status);
    agg.by_cmd[0].name_len = status.len;
    agg.by_cmd[0].stats = .{ .n = 1, .raw_bytes = 400, .displayed_bytes = 100, .formatting_saved_bytes = 300 };

    const logs = "docker logs";
    @memcpy(agg.by_cmd[1].name[0..logs.len], logs);
    agg.by_cmd[1].name_len = logs.len;
    agg.by_cmd[1].stats = .{ .n = 1, .raw_bytes = 600, .displayed_bytes = 400, .formatting_saved_bytes = 200 };

    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeByCommand(&out.writer, agg);

    try std.testing.expect(std.mem.find(u8, out.written(), "Raw tok") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Display tok") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Saved tok") != null);
    try std.testing.expect(std.mem.findScalar(u8, out.written(), '\t') == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "git status") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "docker logs") != null);
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
    try appendLineBounded(allocator, std.testing.io, history_path, lock_path, "new\n", 12);

    const got = try tmp.dir.readFileAlloc(std.testing.io, ".smll/history.jsonl", allocator, .limited(32));
    defer allocator.free(got);
    try std.testing.expectEqualStrings("new\n", got);
}

test "history append keeps newest tail when exceeding size cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");
    // Five 7-byte lines = 35 bytes exactly.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".smll/history.jsonl",
        .data = "aaaa-1\nbbbb-2\ncccc-3\ndddd-4\neeee-5\n",
    });

    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);
    const lock_path = try joinPath(allocator, home, history_lock_file);
    defer allocator.free(lock_path);
    // cap=35: existing history fills the cap, so "ffff-6\n" overflows.
    try appendLineBounded(allocator, std.testing.io, history_path, lock_path, "ffff-6\n", 35);

    const got = try tmp.dir.readFileAlloc(std.testing.io, ".smll/history.jsonl", allocator, .limited(128));
    defer allocator.free(got);
    // Newest entries survive; only the oldest are dropped (not a full wipe).
    try std.testing.expect(std.mem.find(u8, got, "ffff-6\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "eeee-5\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "aaaa-1\n") == null);
    // The compacted file stays within the cap.
    try std.testing.expect(got.len <= 35);
}

test "history append strictly bounds size when the new line exceeds half the cap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".smll/history.jsonl",
        .data = "aaaa-1\nbbbb-2\n",
    });

    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);
    const lock_path = try joinPath(allocator, home, history_lock_file);
    defer allocator.free(lock_path);
    // cap=20; the new 14-byte line is larger than max_size/2 (10). A naive
    // max_size/2 tail (7 bytes) plus the line would reach 21 bytes, breaking
    // the size invariant — the tail budget must shrink to fit.
    const line = "xxxxxxxxxxxxx\n"; // 14 bytes
    try appendLineBounded(allocator, std.testing.io, history_path, lock_path, line, 20);

    const got = try tmp.dir.readFileAlloc(std.testing.io, ".smll/history.jsonl", allocator, .limited(128));
    defer allocator.free(got);
    // Invariant: the post-compaction file never exceeds the cap...
    try std.testing.expect(got.len <= 20);
    // ...and the newest line always survives.
    try std.testing.expect(std.mem.find(u8, got, "xxxxxxxxxxxxx\n") != null);
}

test "history snapshot tails oversized files from a complete line" {
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
    const data = try readHistorySnapshot(allocator, std.testing.io, home, history_path, content.written().len - 8);
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
    try w.writeAll("{\"v\":2,\"ts_ms\":");
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
    try w.writeAll(",\"displayed\":");
    try writeU64(w, compact_bytes);
    try w.writeAll(",\"omitted\":0,\"diagnostics\":0,\"saved\":");
    try writeU64(w, raw_bytes -| compact_bytes);
    try w.writeAll(",\"duration_ms\":1}\n");
}
