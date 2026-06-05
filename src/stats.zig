const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

/// Cumulative token-savings stats stored in ~/.smll/stats.json.
/// Best-effort: stats failures never block command execution.
const stats_dir = ".smll";
const stats_file = ".smll/stats.json";
const history_file = ".smll/history.jsonl";
const MAX_TRACKED_CMDS = 32;
const MAX_JSON_SIZE = 32 * 1024;
const MAX_HISTORY_SIZE = 16 * 1024 * 1024;
const HISTORY_SCHEMA_VERSION = 1;

pub const RecordOptions = struct {
    exit_code: u8 = 0,
    filter_name: []const u8 = "unknown",
    duration_ms: u64 = 0,
};

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
pub fn record(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    argv: []const []const u8,
    input_bytes: usize,
    output_bytes: usize,
    options: RecordOptions,
) void {
    recordInner(allocator, io, home, argv, input_bytes, output_bytes, options) catch {};
}

fn recordInner(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    argv: []const []const u8,
    input_bytes: usize,
    output_bytes: usize,
    options: RecordOptions,
) !void {
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
    try appendHistory(allocator, io, home, dir_path, label, input_bytes, output_bytes, options);
}

pub fn buildLabel(argv: []const []const u8, buf: *[64]u8) []const u8 {
    if (argv.len == 0) return "unknown";
    const cmd = argv[0];
    const basename = pathBasename(cmd);

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
    return findJsonU64Opt(data, key) orelse 0;
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

fn appendHistory(
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

    const cwd_path = std.process.currentPathAlloc(io, allocator) catch try allocator.dupeZ(u8, "");
    defer allocator.free(cwd_path);
    const project_key = projectKey(allocator, io, cwd_path) catch try allocator.dupe(u8, cwd_path);
    defer allocator.free(project_key);

    const epoch_ns: i128 = Io.Clock.real.now(io).toNanoseconds();
    const epoch_ms: i64 = @intCast(@divTrunc(epoch_ns, std.time.ns_per_ms));

    var line = Writer.Allocating.init(allocator);
    defer line.deinit();
    const w = &line.writer;
    try w.writeAll("{\"v\":");
    try writeU64(w, HISTORY_SCHEMA_VERSION);
    try w.writeAll(",\"ts_ms\":");
    try writeI64(w, epoch_ms);
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

    var file = cwd.openFile(io, history_path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try cwd.createFile(io, history_path, .{ .read = true, .truncate = false }),
        else => |e| return e,
    };
    defer file.close(io);
    const st = try file.stat(io);
    try file.writePositionalAll(io, line.written(), st.size);
}

fn writeI64(w: *Writer, val: i64) !void {
    if (val < 0) {
        try w.writeByte('-');
        try writeU64(w, @intCast(-val));
    } else {
        try writeU64(w, @intCast(val));
    }
}

fn writeJsonString(w: *Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (c < 0x20) {
                try w.writeAll("\\u00");
                try writeHexByte(w, c);
            } else {
                try w.writeByte(c);
            }
        },
    };
    try w.writeByte('"');
}

fn writeHexByte(w: *Writer, value: u8) !void {
    const hex = "0123456789abcdef";
    try w.writeByte(hex[value >> 4]);
    try w.writeByte(hex[value & 0xf]);
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
        {
            return try allocator.dupe(u8, current);
        }
    }
    return try allocator.dupe(u8, cwd_path);
}

fn pathBasename(path: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, path, '/')) |idx| path[idx + 1 ..] else path;
}

fn dirnameSlice(path: []const u8) ?[]const u8 {
    const idx = std.mem.findScalarLast(u8, path, '/') orelse return null;
    if (idx == 0) return path[0..1];
    return path[0..idx];
}

const QueryMode = enum { stats, discover };

const QueryOptions = struct {
    verbose: bool = false,
    by_command: bool = false,
    project_only: bool = false,
    reset: bool = false,
    since_ms: ?i64 = null,
};

const HistoryEntry = struct {
    ts_ms: i64 = 0,
    raw_bytes: u64 = 0,
    compact_bytes: u64 = 0,
    exit_code: u8 = 0,
    cmd: [64]u8 = [_]u8{0} ** 64,
    cmd_len: usize = 0,
    filter: [64]u8 = [_]u8{0} ** 64,
    filter_len: usize = 0,
    project: [256]u8 = [_]u8{0} ** 256,
    project_len: usize = 0,

    fn cmdSlice(self: *const HistoryEntry) []const u8 {
        return self.cmd[0..self.cmd_len];
    }

    fn filterSlice(self: *const HistoryEntry) []const u8 {
        return self.filter[0..self.filter_len];
    }

    fn projectSlice(self: *const HistoryEntry) []const u8 {
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

const HistoryAggregate = struct {
    commands: u64 = 0,
    input_bytes: u64 = 0,
    output_bytes: u64 = 0,
    by_cmd: [MAX_TRACKED_CMDS]AggEntry = [_]AggEntry{.{}} ** MAX_TRACKED_CMDS,
    cmd_count: usize = 0,
};

/// Handle `--stats`, `--stats --reset`, and `--discover`.
pub fn maybeRun(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    args: []const []const u8,
    stdout: *Writer,
) !?u8 {
    if (args.len < 2) return null;
    const mode: QueryMode = if (std.mem.eql(u8, args[1], "--stats"))
        .stats
    else if (std.mem.eql(u8, args[1], "--discover"))
        .discover
    else
        return null;

    const opts = parseQueryOptions(args[2..], mode) catch {
        try stdout.writeAll("usage: smll --stats [--reset] [--verbose] [--by-command] [--since <24h|7d|30d>] [--project]\n");
        try stdout.writeAll("       smll --discover [--since <24h|7d|30d>] [--project]\n");
        return 2;
    };

    if (opts.reset) {
        try reset(allocator, io, home);
        try stdout.writeAll("stats reset\n");
        return 0;
    }

    switch (mode) {
        .stats => try displayStats(allocator, io, home, opts, stdout),
        .discover => try displayDiscover(allocator, io, home, opts, stdout),
    }
    return 0;
}

fn parseQueryOptions(args: []const []const u8, mode: QueryMode) !QueryOptions {
    var opts: QueryOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--reset") and mode == .stats) {
            opts.reset = true;
        } else if (std.mem.eql(u8, arg, "--verbose") and mode == .stats) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--by-command") and mode == .stats) {
            opts.by_command = true;
        } else if (std.mem.eql(u8, arg, "--project")) {
            opts.project_only = true;
        } else if (std.mem.eql(u8, arg, "--since")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            opts.since_ms = try parseDurationMs(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--since=")) {
            opts.since_ms = try parseDurationMs(arg["--since=".len..]);
        } else {
            return error.InvalidArgs;
        }
    }
    if (opts.reset and (opts.verbose or opts.by_command or opts.project_only or opts.since_ms != null)) return error.InvalidArgs;
    return opts;
}

fn parseDurationMs(s: []const u8) !i64 {
    if (s.len < 2) return error.InvalidArgs;
    const unit = s[s.len - 1];
    const number = try parseU64(s[0 .. s.len - 1]);
    const ms_per_hour: u64 = 60 * 60 * 1000;
    const mult: u64 = switch (unit) {
        'h' => ms_per_hour,
        'd' => 24 * ms_per_hour,
        else => return error.InvalidArgs,
    };
    return @intCast(number *| mult);
}

fn parseU64(s: []const u8) !u64 {
    if (s.len == 0) return error.InvalidArgs;
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.InvalidArgs;
        n = n *| 10 +| (c - '0');
    }
    return n;
}

fn reset(allocator: Allocator, io: Io, home: []const u8) !void {
    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);
    Io.Dir.cwd().deleteFile(io, history_path) catch {};
}

fn displayStats(allocator: Allocator, io: Io, home: []const u8, opts: QueryOptions, stdout: *Writer) !void {
    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);
    const use_history = opts.since_ms != null or opts.project_only;
    if (use_history) {
        const agg = try aggregateHistory(allocator, io, home, opts);
        try writeAggregateStats(stdout, agg.commands, agg.input_bytes, agg.output_bytes, opts.verbose);
        if (opts.by_command) try writeHistoryByCommand(stdout, agg);
        return;
    }

    const s = load(allocator, io, path);
    if (s.commands == 0) {
        try stdout.writeAll("no commands recorded yet\n");
        return;
    }

    try writeAggregateStats(stdout, s.commands, s.input_bytes, s.output_bytes, opts.verbose);
    if (opts.by_command or s.cmd_count > 0 and opts.verbose) try writeStatsByCommand(stdout, s);
}

pub fn display(allocator: Allocator, io: Io, home: []const u8, stdout: *Writer) !void {
    try displayStats(allocator, io, home, .{}, stdout);
}

fn displayDiscover(allocator: Allocator, io: Io, home: []const u8, opts: QueryOptions, stdout: *Writer) !void {
    const agg = try aggregateHistory(allocator, io, home, opts);
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

fn aggregateHistory(allocator: Allocator, io: Io, home: []const u8, opts: QueryOptions) !HistoryAggregate {
    const history_path = try joinPath(allocator, home, history_file);
    defer allocator.free(history_path);

    const data = Io.Dir.cwd().readFileAlloc(io, history_path, allocator, .limited(MAX_HISTORY_SIZE)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => |e| return e,
    };
    defer allocator.free(data);

    const cutoff_ms: ?i64 = if (opts.since_ms) |since_ms| blk: {
        const epoch_ns: i128 = Io.Clock.real.now(io).toNanoseconds();
        const now_ms: i64 = @intCast(@divTrunc(epoch_ns, std.time.ns_per_ms));
        break :blk now_ms - since_ms;
    } else null;

    var project_filter: ?[]u8 = null;
    defer if (project_filter) |p| allocator.free(p);
    if (opts.project_only) {
        const cwd_path = std.process.currentPathAlloc(io, allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(cwd_path);
        project_filter = projectKey(allocator, io, cwd_path) catch try allocator.dupe(u8, cwd_path);
    }

    var agg: HistoryAggregate = .{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const entry = parseHistoryLine(line) orelse continue;
        if (cutoff_ms) |cutoff| {
            if (entry.ts_ms < cutoff) continue;
        }
        if (project_filter) |project| {
            if (!std.mem.eql(u8, entry.projectSlice(), project)) continue;
        }
        addHistoryEntry(&agg, entry);
    }
    return agg;
}

fn parseHistoryLine(line: []const u8) ?HistoryEntry {
    var entry: HistoryEntry = .{};
    entry.ts_ms = findJsonI64(line, "\"ts_ms\":") orelse return null;
    entry.raw_bytes = findJsonU64Opt(line, "\"raw\":") orelse return null;
    entry.compact_bytes = findJsonU64Opt(line, "\"compact\":") orelse return null;
    const exit = findJsonU64Opt(line, "\"exit\":") orelse return null;
    entry.exit_code = @intCast(@min(exit, 255));
    entry.cmd_len = readJsonStringInto(line, "\"cmd\":", &entry.cmd) orelse return null;
    entry.filter_len = readJsonStringInto(line, "\"filter\":", &entry.filter) orelse return null;
    entry.project_len = readJsonStringInto(line, "\"project\":", &entry.project) orelse return null;
    if (entry.cmd_len == 0) return null;
    return entry;
}

fn addHistoryEntry(agg: *HistoryAggregate, entry: HistoryEntry) void {
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

fn isPassthroughEntry(entry: HistoryEntry) bool {
    return std.mem.eql(u8, entry.filterSlice(), "passthrough") or
        std.mem.eql(u8, entry.filterSlice(), "unknown") or
        savedBytes(entry.raw_bytes, entry.compact_bytes) == 0;
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

fn findJsonI64(data: []const u8, key: []const u8) ?i64 {
    const idx = std.mem.find(u8, data, key) orelse return null;
    var pos = idx + key.len;
    while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) pos += 1;
    var negative = false;
    if (pos < data.len and data[pos] == '-') {
        negative = true;
        pos += 1;
    }
    if (pos >= data.len or data[pos] < '0' or data[pos] > '9') return null;
    var val: i64 = 0;
    while (pos < data.len and data[pos] >= '0' and data[pos] <= '9') {
        val = val *| 10 +| @as(i64, data[pos] - '0');
        pos += 1;
    }
    return if (negative) -val else val;
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
                'u' => blk: {
                    if (pos + 4 >= data.len) return null;
                    pos += 4;
                    break :blk '?';
                },
                else => return null,
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

fn writeAggregateStats(stdout: *Writer, commands: u64, input_bytes: u64, output_bytes: u64, verbose: bool) !void {
    if (commands == 0) {
        try stdout.writeAll("no commands recorded yet\n");
        return;
    }
    const saved = savedBytes(input_bytes, output_bytes);
    const pct = percentSaved(input_bytes, output_bytes);
    const input_tokens = input_bytes / 4;
    const output_tokens = output_bytes / 4;
    const tokens_saved = saved / 4;

    try stdout.writeAll("\n  smll stats\n");
    try stdout.writeAll("  --------------------------------------\n");
    try stdout.writeAll("  Commands:      ");
    try writeU64(stdout, commands);
    try stdout.writeByte('\n');
    try stdout.writeAll("  Input:         ~");
    try writeHumanCount(stdout, input_tokens);
    try stdout.writeAll(" tokens");
    if (verbose) {
        try stdout.writeAll(" (");
        try writeGroupedU64(stdout, input_bytes);
        try stdout.writeAll(" bytes)");
    }
    try stdout.writeAll("\n  Output:        ~");
    try writeHumanCount(stdout, output_tokens);
    try stdout.writeAll(" tokens");
    if (verbose) {
        try stdout.writeAll(" (");
        try writeGroupedU64(stdout, output_bytes);
        try stdout.writeAll(" bytes)");
    }
    try stdout.writeAll("\n  Saved:         ~");
    try writeHumanCount(stdout, tokens_saved);
    try stdout.writeAll(" tokens (");
    try writeU64(stdout, pct);
    try stdout.writeAll("%)");
    if (verbose) {
        try stdout.writeAll(" (");
        try writeGroupedU64(stdout, saved);
        try stdout.writeAll(" bytes)");
    }
    try stdout.writeAll("\n  Raw bytes saved: ");
    try writeHumanDecimal(stdout, saved);
    try stdout.writeAll(" bytes\n");
    if (verbose) try stdout.writeAll("  Token estimate: bytes / 4\n");
}

fn writeStatsByCommand(stdout: *Writer, s: Stats) !void {
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

fn writeHistoryByCommand(stdout: *Writer, agg: HistoryAggregate) !void {
    if (agg.cmd_count == 0) return;
    try stdout.writeAll("\n  Command              Runs     Input     Output    Saved\n");
    try stdout.writeAll("  --------------------------------------------------------\n");

    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndicesBySaved(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count]);

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

fn writeDiscoverLowSavings(stdout: *Writer, agg: HistoryAggregate) !void {
    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndicesByLowSavings(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count]);

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

fn writeDiscoverPassthrough(stdout: *Writer, agg: HistoryAggregate) !void {
    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndicesByPassthrough(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count]);

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

fn writeDiscoverTopRaw(stdout: *Writer, agg: HistoryAggregate) !void {
    var indices: [MAX_TRACKED_CMDS]usize = undefined;
    for (0..agg.cmd_count) |i| indices[i] = i;
    sortAggIndicesByRaw(agg.by_cmd[0..agg.cmd_count], indices[0..agg.cmd_count]);

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

fn savedBytes(input_bytes: u64, output_bytes: u64) u64 {
    return if (input_bytes > output_bytes) input_bytes - output_bytes else 0;
}

fn percentSaved(input_bytes: u64, output_bytes: u64) u64 {
    if (input_bytes == 0) return 0;
    return (savedBytes(input_bytes, output_bytes) * 100) / input_bytes;
}

fn sortAggIndicesBySaved(entries: []const AggEntry, indices: []usize) void {
    insertionSortIndices(entries, indices, struct {
        fn lt(items: []const AggEntry, a: usize, b: usize) bool {
            return savedBytes(items[a].stats.in_bytes, items[a].stats.out_bytes) >
                savedBytes(items[b].stats.in_bytes, items[b].stats.out_bytes);
        }
    }.lt);
}

fn sortAggIndicesByRaw(entries: []const AggEntry, indices: []usize) void {
    insertionSortIndices(entries, indices, struct {
        fn lt(items: []const AggEntry, a: usize, b: usize) bool {
            return items[a].stats.in_bytes > items[b].stats.in_bytes;
        }
    }.lt);
}

fn sortAggIndicesByPassthrough(entries: []const AggEntry, indices: []usize) void {
    insertionSortIndices(entries, indices, struct {
        fn lt(items: []const AggEntry, a: usize, b: usize) bool {
            if (items[a].passthrough_runs != items[b].passthrough_runs)
                return items[a].passthrough_runs > items[b].passthrough_runs;
            return items[a].stats.in_bytes > items[b].stats.in_bytes;
        }
    }.lt);
}

fn sortAggIndicesByLowSavings(entries: []const AggEntry, indices: []usize) void {
    insertionSortIndices(entries, indices, struct {
        fn lt(items: []const AggEntry, a: usize, b: usize) bool {
            const pct_a = percentSaved(items[a].stats.in_bytes, items[a].stats.out_bytes);
            const pct_b = percentSaved(items[b].stats.in_bytes, items[b].stats.out_bytes);
            if (pct_a != pct_b) return pct_a < pct_b;
            return items[a].stats.in_bytes > items[b].stats.in_bytes;
        }
    }.lt);
}

fn insertionSortIndices(
    entries: []const AggEntry,
    indices: []usize,
    comptime lessThan: fn ([]const AggEntry, usize, usize) bool,
) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        const key = indices[i];
        var j: usize = i;
        while (j > 0 and lessThan(entries, key, indices[j - 1])) : (j -= 1) {
            indices[j] = indices[j - 1];
        }
        indices[j] = key;
    }
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

fn writeGroupedU64(w: *Writer, val: u64) !void {
    var buf: [32]u8 = undefined;
    var n = val;
    var i: usize = buf.len;
    var group: usize = 0;
    if (n == 0) {
        try w.writeByte('0');
        return;
    }
    while (n > 0) {
        if (group == 3) {
            i -= 1;
            buf[i] = ',';
            group = 0;
        }
        i -= 1;
        buf[i] = @intCast('0' + n % 10);
        n /= 10;
        group += 1;
    }
    try w.writeAll(buf[i..]);
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

test "record appends history without full argv" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);

    record(allocator, std.testing.io, home, &.{ "git", "status", "--secret-token=abc123" }, 120, 40, .{
        .exit_code = 7,
        .filter_name = "git_status",
        .duration_ms = 12,
    });

    const history = try tmp.dir.readFileAlloc(std.testing.io, ".smll/history.jsonl", allocator, .limited(4096));
    defer allocator.free(history);
    try std.testing.expect(std.mem.find(u8, history, "\"cmd\":\"git status\"") != null);
    try std.testing.expect(std.mem.find(u8, history, "\"filter\":\"git_status\"") != null);
    try std.testing.expect(std.mem.find(u8, history, "\"exit\":7") != null);
    try std.testing.expect(std.mem.find(u8, history, "\"raw\":120") != null);
    try std.testing.expect(std.mem.find(u8, history, "\"compact\":40") != null);
    try std.testing.expect(std.mem.find(u8, history, "\"duration_ms\":12") != null);
    try std.testing.expect(std.mem.find(u8, history, "secret-token") == null);
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
    try writeHistoryFixtureLine(&content.writer, now_ms - 2 * 24 * 60 * 60 * 1000, project, "old", "passthrough", 100, 100);
    try writeHistoryFixtureLine(&content.writer, now_ms, project, "new", "rg", 200, 40);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/history.jsonl", .data = content.written() });

    const agg = try aggregateHistory(allocator, std.testing.io, home, .{ .since_ms = 24 * 60 * 60 * 1000 });
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
    try writeHistoryFixtureLine(&content.writer, now_ms, "/tmp/other-smll-project", "other", "passthrough", 500, 500);
    try writeHistoryFixtureLine(&content.writer, now_ms, project, "current", "rg", 300, 60);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/history.jsonl", .data = content.written() });

    const agg = try aggregateHistory(allocator, std.testing.io, home, .{ .project_only = true });
    try std.testing.expectEqual(@as(u64, 1), agg.commands);
    try std.testing.expectEqualStrings("current", agg.by_cmd[0].nameSlice());
}

test "reset deletes stats and history" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/stats.json", .data = "{}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/history.jsonl", .data = "{}\n" });

    try reset(allocator, std.testing.io, home);
    try expectMissing(tmp.dir, ".smll/stats.json");
    try expectMissing(tmp.dir, ".smll/history.jsonl");
}

test "stats output is token-first with verbose exact bytes" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeAggregateStats(&out.writer, 760, 145_648_029, 110_199_423, false);
    try std.testing.expect(std.mem.find(u8, out.written(), "Input:         ~36.4M tokens") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Saved:         ~8.8M tokens") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "33.8 MB") == null);

    var verbose = Writer.Allocating.init(std.testing.allocator);
    defer verbose.deinit();
    try writeAggregateStats(&verbose.writer, 760, 145_648_029, 110_199_423, true);
    try std.testing.expect(std.mem.find(u8, verbose.written(), "(145,648,029 bytes)") != null);
    try std.testing.expect(std.mem.find(u8, verbose.written(), "Token estimate: bytes / 4") != null);
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
    try writeHistoryFixtureLine(&content.writer, now_ms, project, "low-save", "generic", 1000, 900);
    try writeHistoryFixtureLine(&content.writer, now_ms, project, "passthrough-cmd", "passthrough", 200, 200);
    try writeHistoryFixtureLine(&content.writer, now_ms, project, "huge-raw", "rg", 5000, 1000);
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

fn currentProjectForTest(allocator: Allocator) ![]u8 {
    const cwd_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd_path);
    return projectKey(allocator, std.testing.io, cwd_path) catch try allocator.dupe(u8, cwd_path);
}

fn writeHistoryFixtureLine(
    w: *Writer,
    ts_ms: i64,
    project: []const u8,
    cmd: []const u8,
    filter: []const u8,
    raw_bytes: u64,
    compact_bytes: u64,
) !void {
    try w.writeAll("{\"v\":1,\"ts_ms\":");
    try writeI64(w, ts_ms);
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

fn expectMissing(dir: Io.Dir, path: []const u8) !void {
    const file = dir.openFile(std.testing.io, path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    file.close(std.testing.io);
    return error.UnexpectedFile;
}
