const std = @import("std");
const accounting = @import("accounting.zig");
const history = @import("history.zig");
const state_io = @import("state_io.zig");
const util = @import("util");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

/// Cumulative token-savings stats stored in ~/.smll/stats.json.
/// Best-effort: stats failures never block command execution.
const stats_file = ".smll/stats.json";
const stats_lock_file = ".smll/stats.lock";
const history_lock_file = ".smll/history.lock";
const tee_dir = ".smll/tee";
const MAX_TRACKED_CMDS = 32;
const MAX_JSON_SIZE = 32 * 1024;
const STATS_SCHEMA_VERSION = 3;

pub const RecordOptions = history.RecordOptions;
pub const Bytes = accounting.Bytes;

pub const CmdStats = struct {
    n: u64 = 0,
    raw_bytes: u64 = 0,
    displayed_bytes: u64 = 0,
    omitted_bytes: u64 = 0,
    diagnostic_bytes: u64 = 0,
    formatting_saved_bytes: u64 = 0,
};

pub const Stats = struct {
    schema_version: u64 = STATS_SCHEMA_VERSION,
    commands: u64 = 0,
    raw_bytes: u64 = 0,
    displayed_bytes: u64 = 0,
    omitted_bytes: u64 = 0,
    diagnostic_bytes: u64 = 0,
    formatting_saved_bytes: u64 = 0,
    by_cmd: [MAX_TRACKED_CMDS]CmdEntry = undefined,
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

const writeU64 = util.writeDecimal;
const joinPath = util.joinPath;

/// Record a completed command's byte counts. Best-effort.
pub fn record(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    argv: []const []const u8,
    bytes: Bytes,
    options: RecordOptions,
) bool {
    const state_lock = state_io.openStateLock(allocator, io, home) catch return false;
    defer if (state_lock) |file| file.close(io);
    return recordUnderStateLock(allocator, io, home, argv, bytes, options);
}

/// Record while the caller owns `.smll/state.lock`. Best-effort, matching
/// `record`, but without reacquiring the shared command-finalization lock.
pub fn recordUnderStateLock(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    argv: []const []const u8,
    bytes: Bytes,
    options: RecordOptions,
) bool {
    recordInner(allocator, io, home, argv, bytes, options) catch return false;
    return true;
}

fn recordInner(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    argv: []const []const u8,
    bytes: Bytes,
    options: RecordOptions,
) !void {
    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);

    var label_buf: [64]u8 = undefined;
    const label = buildLabel(argv, &label_buf);

    {
        var s = load(allocator, io, path);
        s.schema_version = STATS_SCHEMA_VERSION;
        s.commands += 1;
        addBytes(&s.raw_bytes, bytes.raw_bytes);
        addBytes(&s.displayed_bytes, bytes.displayed_bytes);
        addBytes(&s.omitted_bytes, bytes.omitted_bytes);
        addBytes(&s.diagnostic_bytes, bytes.diagnostic_bytes);
        addBytes(&s.formatting_saved_bytes, bytes.formatting_saved_bytes);

        var found: ?*CmdEntry = null;
        for (s.by_cmd[0..s.cmd_count]) |*entry| {
            if (std.mem.eql(u8, entry.nameSlice(), label)) {
                found = entry;
                break;
            }
        }
        if (found == null and s.cmd_count < MAX_TRACKED_CMDS) {
            const entry = &s.by_cmd[s.cmd_count];
            entry.* = .{};
            const copy_len = @min(label.len, entry.name.len);
            @memcpy(entry.name[0..copy_len], label[0..copy_len]);
            entry.name_len = copy_len;
            s.cmd_count += 1;
            found = entry;
        }
        if (found) |entry| {
            entry.stats.n += 1;
            addBytes(&entry.stats.raw_bytes, bytes.raw_bytes);
            addBytes(&entry.stats.displayed_bytes, bytes.displayed_bytes);
            addBytes(&entry.stats.omitted_bytes, bytes.omitted_bytes);
            addBytes(&entry.stats.diagnostic_bytes, bytes.diagnostic_bytes);
            addBytes(&entry.stats.formatting_saved_bytes, bytes.formatting_saved_bytes);
        }

        try saveJson(allocator, io, path, s);
    }

    try history.appendUnderStateLock(allocator, io, home, label, bytes, options);
}

fn addBytes(total: *u64, value: usize) void {
    total.* +|= std.math.cast(u64, value) orelse std.math.maxInt(u64);
}

pub noinline fn buildLabel(argv: []const []const u8, buf: *[64]u8) []const u8 {
    if (argv.len == 0) return "unknown";
    const basename = pathBasename(argv[0]);
    const copy_len = @min(basename.len, buf.len);
    @memcpy(buf[0..copy_len], basename[0..copy_len]);
    return buf[0..copy_len];
}

fn load(allocator: Allocator, io: Io, path: []const u8) Stats {
    return loadInner(allocator, io, path) catch emptyStats();
}

fn loadInner(allocator: Allocator, io: Io, path: []const u8) !Stats {
    const cwd = Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(MAX_JSON_SIZE)) catch return emptyStats();
    defer allocator.free(data);
    return parseStats(data);
}

fn parseStats(data: []const u8) Stats {
    var s = emptyStats();
    // Hand-rolled parser for the fixed stats JSON schema. Version 1 had no
    // explicit schema marker and stored only input/output byte totals.
    s.schema_version = util.findJsonU64Opt(data, "\"v\":") orelse 1;
    s.commands = findJsonU64(data, "\"commands\":");
    if (s.schema_version >= 2) {
        s.raw_bytes = findJsonU64(data, "\"raw_bytes\":");
        s.displayed_bytes = findJsonU64(data, "\"displayed_bytes\":");
        s.omitted_bytes = findJsonU64(data, "\"omitted_bytes\":");
        s.diagnostic_bytes = findJsonU64(data, "\"diagnostic_bytes\":");
        s.formatting_saved_bytes = findJsonU64(data, "\"formatting_saved_bytes\":");
    } else {
        s.raw_bytes = findJsonU64(data, "\"input_bytes\":");
        s.displayed_bytes = findJsonU64(data, "\"output_bytes\":");
        s.formatting_saved_bytes = 0;
    }
    const by_cmd_marker = "\"by_cmd\":{";
    const by_cmd_start = std.mem.find(u8, data, by_cmd_marker) orelse return s;
    var pos = by_cmd_start + by_cmd_marker.len;
    while (pos < data.len and s.cmd_count < MAX_TRACKED_CMDS) {
        while (pos < data.len and (data[pos] == ' ' or data[pos] == ',' or data[pos] == '\n' or data[pos] == '\r' or data[pos] == '\t')) pos += 1;
        if (pos >= data.len or data[pos] == '}') break;
        if (data[pos] != '"') break;
        var entry: CmdEntry = .{};
        entry.name_len = history.readJsonStringAt(data, &pos, &entry.name) orelse break;
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
        entry.stats.n = findJsonU64(obj_slice, "\"n\":");
        if (s.schema_version >= 2) {
            entry.stats.raw_bytes = findJsonU64(obj_slice, "\"raw\":");
            entry.stats.displayed_bytes = findJsonU64(obj_slice, "\"displayed\":");
            entry.stats.omitted_bytes = findJsonU64(obj_slice, "\"omitted\":");
            entry.stats.diagnostic_bytes = findJsonU64(obj_slice, "\"diagnostics\":");
            entry.stats.formatting_saved_bytes = findJsonU64(obj_slice, "\"saved\":");
        } else {
            entry.stats.raw_bytes = findJsonU64(obj_slice, "\"in\":");
            entry.stats.displayed_bytes = findJsonU64(obj_slice, "\"out\":");
            entry.stats.formatting_saved_bytes = 0;
        }
        if (s.schema_version < STATS_SCHEMA_VERSION) {
            sanitizeLegacyLabel(&entry);
        }

        var merged = false;
        for (s.by_cmd[0..s.cmd_count]) |*existing| {
            if (!std.mem.eql(u8, existing.nameSlice(), entry.nameSlice())) continue;
            mergeCmdStats(&existing.stats, entry.stats);
            merged = true;
            break;
        }
        if (!merged) {
            s.by_cmd[s.cmd_count] = entry;
            s.cmd_count += 1;
        }
    }
    return s;
}

fn sanitizeLegacyLabel(entry: *CmdEntry) void {
    const label = entry.nameSlice();
    inline for (.{ "git", "docker", "kubectl", "cargo", "npm", "go", "gh", "bun", "pnpm" }) |command| {
        if (label.len > command.len and
            label[command.len] == ' ' and
            std.mem.eql(u8, label[0..command.len], command))
        {
            entry.name_len = command.len;
            return;
        }
    }
}

fn mergeCmdStats(dst: *CmdStats, src: CmdStats) void {
    dst.n +|= src.n;
    dst.raw_bytes +|= src.raw_bytes;
    dst.displayed_bytes +|= src.displayed_bytes;
    dst.omitted_bytes +|= src.omitted_bytes;
    dst.diagnostic_bytes +|= src.diagnostic_bytes;
    dst.formatting_saved_bytes +|= src.formatting_saved_bytes;
}

fn loadSnapshot(allocator: Allocator, io: Io, home: []const u8, path: []const u8) Stats {
    const data = state_io.copyFileUnderStateLock(allocator, io, home, path, MAX_JSON_SIZE) catch return emptyStats();
    defer allocator.free(data);
    return parseStats(data);
}

fn emptyStats() Stats {
    var s: Stats = undefined;
    s.schema_version = STATS_SCHEMA_VERSION;
    s.commands = 0;
    s.raw_bytes = 0;
    s.displayed_bytes = 0;
    s.omitted_bytes = 0;
    s.diagnostic_bytes = 0;
    s.formatting_saved_bytes = 0;
    s.cmd_count = 0;
    return s;
}

fn findJsonU64(data: []const u8, key: []const u8) u64 {
    return util.findJsonU64Opt(data, key) orelse 0;
}

fn saveJson(allocator: Allocator, io: Io, path: []const u8, s: Stats) !void {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"v\":");
    try writeU64(w, STATS_SCHEMA_VERSION);
    try w.writeAll(",\"commands\":");
    try writeU64(w, s.commands);
    try w.writeAll(",\"raw_bytes\":");
    try writeU64(w, s.raw_bytes);
    try w.writeAll(",\"displayed_bytes\":");
    try writeU64(w, s.displayed_bytes);
    try w.writeAll(",\"omitted_bytes\":");
    try writeU64(w, s.omitted_bytes);
    try w.writeAll(",\"diagnostic_bytes\":");
    try writeU64(w, s.diagnostic_bytes);
    try w.writeAll(",\"formatting_saved_bytes\":");
    try writeU64(w, s.formatting_saved_bytes);
    if (s.cmd_count > 0) {
        try w.writeAll(",\"by_cmd\":{");
        for (s.by_cmd[0..s.cmd_count], 0..) |entry, i| {
            if (i > 0) try w.writeByte(',');
            try history.writeJsonString(w, entry.nameSlice());
            try w.writeAll(":{\"n\":");
            try writeU64(w, entry.stats.n);
            try w.writeAll(",\"raw\":");
            try writeU64(w, entry.stats.raw_bytes);
            try w.writeAll(",\"displayed\":");
            try writeU64(w, entry.stats.displayed_bytes);
            try w.writeAll(",\"omitted\":");
            try writeU64(w, entry.stats.omitted_bytes);
            try w.writeAll(",\"diagnostics\":");
            try writeU64(w, entry.stats.diagnostic_bytes);
            try w.writeAll(",\"saved\":");
            try writeU64(w, entry.stats.formatting_saved_bytes);
            try w.writeByte('}');
        }
        try w.writeByte('}');
    }
    try w.writeAll("}\n");

    try state_io.writePrivateFileAtomic(io, path, out.written());
}

fn pathBasename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[i + 1 ..];
    }
    return path;
}

const QueryMode = enum { stats, discover };
const QueryOptions = history.QueryOptions;

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
        try stdout.writeAll("usage: smll --stats [--reset [--all]] [--verbose] [--by-command] [--since <24h|7d|30d>] [--project]\n");
        try stdout.writeAll("       smll --discover [--since <24h|7d|30d>] [--project]\n");
        return 2;
    };

    if (opts.reset) {
        try reset(allocator, io, home, opts.all);
        try stdout.writeAll(if (opts.all) "all local state reset\n" else "stats reset\n");
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
        } else if (std.mem.eql(u8, arg, "--all") and mode == .stats) {
            opts.all = true;
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
    if (opts.all and !opts.reset) return error.InvalidArgs;
    if (opts.reset and (opts.verbose or opts.by_command or opts.project_only or opts.since_ms != null)) return error.InvalidArgs;
    return opts;
}

fn parseDurationMs(s: []const u8) !i64 {
    if (s.len < 2) return error.InvalidArgs;
    const unit = s[s.len - 1];
    const number = util.parseU64(s[0 .. s.len - 1]) orelse return error.InvalidArgs;
    const ms_per_hour: u64 = 60 * 60 * 1000;
    const mult: u64 = switch (unit) {
        'h' => ms_per_hour,
        'd' => 24 * ms_per_hour,
        else => return error.InvalidArgs,
    };
    const ms = number *| mult;
    return std.math.cast(i64, ms) orelse return error.InvalidArgs;
}

fn reset(allocator: Allocator, io: Io, home: []const u8, all: bool) !void {
    const state_lock = try state_io.openStateLock(allocator, io, home);
    defer if (state_lock) |file| file.close(io);

    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
    try history.reset(allocator, io, home);
    if (!all) return;

    const stats_lock_path = try joinPath(allocator, home, stats_lock_file);
    defer allocator.free(stats_lock_path);
    Io.Dir.cwd().deleteFile(io, stats_lock_path) catch {};
    const history_lock_path = try joinPath(allocator, home, history_lock_file);
    defer allocator.free(history_lock_path);
    Io.Dir.cwd().deleteFile(io, history_lock_path) catch {};
    const tee_path = try joinPath(allocator, home, tee_dir);
    defer allocator.free(tee_path);
    Io.Dir.cwd().deleteTree(io, tee_path) catch {};
}

fn displayStats(allocator: Allocator, io: Io, home: []const u8, opts: QueryOptions, stdout: *Writer) !void {
    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);
    const use_history = opts.since_ms != null or opts.project_only;
    if (use_history) {
        const agg = try history.aggregate(allocator, io, home, opts);
        try writeAggregateStats(stdout, agg.commands, agg.raw_bytes, agg.displayed_bytes, agg.omitted_bytes, agg.diagnostic_bytes, agg.formatting_saved_bytes, opts.verbose);
        if (opts.by_command) try history.writeByCommand(stdout, agg);
        return;
    }

    const s = loadSnapshot(allocator, io, home, path);
    if (s.commands == 0) {
        try stdout.writeAll("no commands recorded yet\n");
        return;
    }

    try writeAggregateStats(stdout, s.commands, s.raw_bytes, s.displayed_bytes, s.omitted_bytes, s.diagnostic_bytes, s.formatting_saved_bytes, opts.verbose);
    if (opts.by_command or s.cmd_count > 0 and opts.verbose) try writeStatsByCommand(stdout, s);
}

pub fn display(allocator: Allocator, io: Io, home: []const u8, stdout: *Writer) !void {
    try displayStats(allocator, io, home, .{}, stdout);
}

fn displayDiscover(allocator: Allocator, io: Io, home: []const u8, opts: QueryOptions, stdout: *Writer) !void {
    try history.displayDiscover(allocator, io, home, opts, stdout);
}

fn writeAggregateStats(
    stdout: *Writer,
    commands: u64,
    raw_bytes: u64,
    displayed_bytes: u64,
    omitted_bytes: u64,
    diagnostic_bytes: u64,
    formatting_saved_bytes: u64,
    verbose: bool,
) !void {
    if (commands == 0) {
        try stdout.writeAll("no commands recorded yet\n");
        return;
    }
    const pct = percentSaved(raw_bytes, formatting_saved_bytes);
    const input_tokens = raw_bytes / 4;
    const output_tokens = displayed_bytes / 4;
    const tokens_saved = formatting_saved_bytes / 4;

    try stdout.writeAll("\n  smll stats\n");
    try stdout.writeAll("  --------------------------------------\n");
    try stdout.writeAll("  Commands:      ");
    try writeU64(stdout, commands);
    try stdout.writeByte('\n');
    try stdout.writeAll("  Raw:           ~");
    try writeHumanCount(stdout, input_tokens);
    try stdout.writeAll(" tokens");
    if (verbose) {
        try stdout.writeAll(" (");
        try writeGroupedU64(stdout, raw_bytes);
        try stdout.writeAll(" bytes)");
    }
    try stdout.writeAll("\n  Displayed:     ~");
    try writeHumanCount(stdout, output_tokens);
    try stdout.writeAll(" tokens");
    if (verbose) {
        try stdout.writeAll(" (");
        try writeGroupedU64(stdout, displayed_bytes);
        try stdout.writeAll(" bytes)");
    }
    try stdout.writeAll("\n  Format saved:  ~");
    try writeHumanCount(stdout, tokens_saved);
    try stdout.writeAll(" tokens (");
    try writeU64(stdout, pct);
    try stdout.writeAll("%)");
    if (verbose) {
        try stdout.writeAll(" (");
        try writeGroupedU64(stdout, formatting_saved_bytes);
        try stdout.writeAll(" bytes)");
    }
    try stdout.writeAll("\n  Formatting bytes saved: ");
    try writeHumanDecimal(stdout, formatting_saved_bytes);
    try stdout.writeAll(" bytes\n");
    if (verbose) {
        try stdout.writeAll("  Declared omitted: ");
        try writeGroupedU64(stdout, omitted_bytes);
        try stdout.writeAll(" bytes\n  Wrapper diagnostics: ");
        try writeGroupedU64(stdout, diagnostic_bytes);
        try stdout.writeAll(" bytes\n  Token estimate: bytes / 4\n");
    }
}

fn writeStatsByCommand(stdout: *Writer, s: Stats) !void {
    if (s.cmd_count > 0) {
        try stdout.writeAll("\n  Command              Runs       Raw  Displayed   Saved\n");
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
            const cmd_pct = if (entry.stats.raw_bytes > 0)
                (entry.stats.formatting_saved_bytes * 100) / entry.stats.raw_bytes
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
            try writeHumanBytes(stdout, entry.stats.raw_bytes);
            try stdout.writeByte('\t');
            try writeHumanBytes(stdout, entry.stats.displayed_bytes);
            try stdout.writeByte('\t');
            try writeU64(stdout, cmd_pct);
            try stdout.writeAll("%\n");
        }
    }
    try stdout.writeByte('\n');
}

fn percentSaved(raw_bytes: u64, formatting_saved_bytes: u64) u64 {
    if (raw_bytes == 0) return 0;
    return (formatting_saved_bytes * 100) / raw_bytes;
}

fn cmpBySaved(entries: []const CmdEntry, a: usize, b: usize) bool {
    return entries[a].stats.formatting_saved_bytes > entries[b].stats.formatting_saved_bytes;
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

const writeHumanCount = util.writeHumanCount;
const writeHumanDecimal = util.writeHumanDecimal;

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

test "buildLabel: command arguments are excluded" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("git", buildLabel(&.{ "git", "status" }, &buf));
    try std.testing.expectEqualStrings("git", buildLabel(&.{ "git", "--version" }, &buf));
}

test "buildLabel: plain command" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("cat", buildLabel(&.{ "cat", "file.txt" }, &buf));
    try std.testing.expectEqualStrings("rg", buildLabel(&.{ "rg", "TODO" }, &buf));
}

test "buildLabel: path stripped" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("git", buildLabel(&.{ "/usr/bin/git", "status" }, &buf));
}

test "buildLabel: Windows path stripped" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("git.exe", buildLabel(&.{"C:\\Program Files\\Git\\cmd\\git.exe"}, &buf));
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

test "parseDurationMs rejects oversized durations" {
    try std.testing.expectError(error.InvalidArgs, parseDurationMs("999999999999999999999999h"));
}

test "stats parser rejects overflowing json integers" {
    try std.testing.expect(util.findJsonU64Opt("{\"n\":18446744073709551616}", "\"n\":") == null);
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

    const recorded = record(allocator, std.testing.io, home, &.{ "git", "status", "--secret-token=abc123" }, .{
        .raw_bytes = 120,
        .displayed_bytes = 40,
        .formatting_saved_bytes = 80,
    }, .{
        .exit_code = 7,
        .filter_name = "git_status",
        .duration_ms = 12,
    });
    try std.testing.expect(recorded);

    const history_data = try tmp.dir.readFileAlloc(std.testing.io, ".smll/history.jsonl", allocator, .limited(4096));
    defer allocator.free(history_data);
    try std.testing.expect(std.mem.find(u8, history_data, "\"cmd\":\"git\"") != null);
    try std.testing.expect(std.mem.find(u8, history_data, "\"filter\":\"git_status\"") != null);
    try std.testing.expect(std.mem.find(u8, history_data, "\"exit\":7") != null);
    try std.testing.expect(std.mem.find(u8, history_data, "\"raw\":120") != null);
    try std.testing.expect(std.mem.find(u8, history_data, "\"displayed\":40") != null);
    try std.testing.expect(std.mem.find(u8, history_data, "\"saved\":80") != null);
    try std.testing.expect(std.mem.find(u8, history_data, "\"duration_ms\":12") != null);
    try std.testing.expect(std.mem.find(u8, history_data, "secret-token") == null);
}

test "record excludes command arguments from local state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);

    const secret = "VALIDATION_ONLY_TOKEN";
    const recorded = record(
        allocator,
        std.testing.io,
        home,
        &.{ "npm", "https://user:" ++ secret ++ "@example.invalid/" },
        .{ .raw_bytes = 12, .displayed_bytes = 4, .formatting_saved_bytes = 8 },
        .{},
    );
    try std.testing.expect(recorded);

    inline for (.{ ".smll/stats.json", ".smll/history.jsonl" }) |path| {
        const data = try tmp.dir.readFileAlloc(std.testing.io, path, allocator, .limited(4096));
        defer allocator.free(data);
        try std.testing.expect(std.mem.find(u8, data, secret) == null);
        try std.testing.expect(std.mem.find(u8, data, "\"npm\"") != null);
    }
}

test "record removes arguments from existing stats labels" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");

    const secret = "OLD_VALIDATION_TOKEN";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".smll/stats.json",
        .data = "{\"v\":2,\"commands\":3,\"raw_bytes\":30,\"displayed_bytes\":11,\"omitted_bytes\":5,\"diagnostic_bytes\":7,\"formatting_saved_bytes\":9,\"by_cmd\":{\"npm https://user:" ++ secret ++ "@example.invalid/\":{\"n\":1,\"raw\":10,\"displayed\":4,\"omitted\":1,\"diagnostics\":2,\"saved\":3},\"npm install\":{\"n\":2,\"raw\":20,\"displayed\":7,\"omitted\":4,\"diagnostics\":5,\"saved\":6}}}\n",
    });

    try std.testing.expect(record(
        allocator,
        std.testing.io,
        home,
        &.{ "npm", "install" },
        .{ .raw_bytes = 12, .displayed_bytes = 4, .omitted_bytes = 3, .diagnostic_bytes = 2, .formatting_saved_bytes = 5 },
        .{},
    ));

    const data = try tmp.dir.readFileAlloc(std.testing.io, ".smll/stats.json", allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expect(std.mem.find(u8, data, secret) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, data, "\"npm\":"));
    try std.testing.expect(std.mem.find(u8, data, "\"npm install\"") == null);
    try std.testing.expect(std.mem.find(u8, data, "\"npm\":{\"n\":4,\"raw\":42,\"displayed\":15,\"omitted\":8,\"diagnostics\":9,\"saved\":14}") != null);
}

test "record preserves v3 executable labels containing spaces" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".smll/stats.json",
        .data = "{\"v\":3,\"commands\":1,\"raw_bytes\":10,\"displayed_bytes\":4,\"omitted_bytes\":0,\"diagnostic_bytes\":0,\"formatting_saved_bytes\":6,\"by_cmd\":{\"git helper\":{\"n\":1,\"raw\":10,\"displayed\":4,\"omitted\":0,\"diagnostics\":0,\"saved\":6}}}\n",
    });

    try std.testing.expect(record(
        allocator,
        std.testing.io,
        home,
        &.{"git helper"},
        .{ .raw_bytes = 12, .displayed_bytes = 4, .formatting_saved_bytes = 8 },
        .{},
    ));

    const data = try tmp.dir.readFileAlloc(std.testing.io, ".smll/stats.json", allocator, .limited(4096));
    defer allocator.free(data);
    try std.testing.expect(std.mem.find(u8, data, "\"git helper\":{\"n\":2") != null);
    try std.testing.expect(std.mem.find(u8, data, "\"git\":") == null);
}

test "stats command keys are JSON escaped and round trip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);

    const recorded = record(allocator, std.testing.io, home, &.{"gi\"t\nline\x01\xff"}, .{
        .raw_bytes = 12,
        .displayed_bytes = 4,
        .formatting_saved_bytes = 8,
    }, .{});
    try std.testing.expect(recorded);

    const json = try tmp.dir.readFileAlloc(std.testing.io, ".smll/stats.json", allocator, .limited(4096));
    defer allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, "gi\\\"t\\nline\\u0001\\u00ff") != null);

    const path = try joinPath(allocator, home, stats_file);
    defer allocator.free(path);
    const loaded = load(allocator, std.testing.io, path);
    try std.testing.expectEqual(@as(usize, 1), loaded.cmd_count);
    try std.testing.expectEqualSlices(u8, "gi\"t\nline\x01\xff", loaded.by_cmd[0].nameSlice());
}

test "record creates private state directories and files" {
    if (@import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);

    try std.testing.expect(record(allocator, std.testing.io, home, &.{"git"}, .{
        .raw_bytes = 12,
        .displayed_bytes = 4,
        .formatting_saved_bytes = 8,
    }, .{}));

    var state_dir = try tmp.dir.openDir(std.testing.io, ".smll", .{ .iterate = true });
    defer state_dir.close(std.testing.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try state_dir.stat(std.testing.io)).permissions.toMode() & 0o777);
    inline for (.{ "state.lock", "stats.json", "history.jsonl" }) |name| {
        const st = try state_dir.statFile(std.testing.io, name, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
    }
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

    try reset(allocator, std.testing.io, home, false);
    try expectMissing(tmp.dir, ".smll/stats.json");
    try expectMissing(tmp.dir, ".smll/history.jsonl");
}

test "reset waits for the state writer lock" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(io, ".smll");

    const maybe_lock = try state_io.openStateLock(allocator, io, home);
    if (maybe_lock == null) return;
    const held_lock = maybe_lock.?;

    var started: std.atomic.Value(bool) = .init(false);
    var finished: std.atomic.Value(bool) = .init(false);
    const Context = struct {
        home: []const u8,
        started: *std.atomic.Value(bool),
        finished: *std.atomic.Value(bool),

        fn run(ctx: @This()) void {
            ctx.started.store(true, .release);
            reset(std.heap.page_allocator, std.testing.io, ctx.home, false) catch return;
            ctx.finished.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .home = home,
        .started = &started,
        .finished = &finished,
    }});

    while (!started.load(.acquire)) try std.Thread.yield();
    const deadline = Io.Clock.real.now(io).toNanoseconds() + 50 * std.time.ns_per_ms;
    while (!finished.load(.acquire) and Io.Clock.real.now(io).toNanoseconds() < deadline) {
        try std.Thread.yield();
    }
    const completed_while_locked = finished.load(.acquire);
    held_lock.close(io);
    thread.join();

    try std.testing.expect(!completed_while_locked);
    try std.testing.expect(finished.load(.acquire));
}

test "reset all deletes data and subordinate locks while retaining state lock" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".smll/tee");
    inline for (.{ "stats.json", "stats.lock", "history.jsonl", "history.lock", "tee/failure.log" }) |name| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll/" ++ name, .data = "state\n" });
    }

    try reset(allocator, std.testing.io, home, true);
    inline for (.{ ".smll/stats.json", ".smll/stats.lock", ".smll/history.jsonl", ".smll/history.lock" }) |name| {
        try expectMissing(tmp.dir, name);
    }
    const state_lock = try tmp.dir.openFile(std.testing.io, ".smll/state.lock", .{});
    state_lock.close(std.testing.io);
    tmp.dir.access(std.testing.io, ".smll/tee", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    return error.UnexpectedTeeDirectory;
}

test "stats reset all is accepted only with reset" {
    const opts = try parseQueryOptions(&.{ "--reset", "--all" }, .stats);
    try std.testing.expect(opts.reset);
    try std.testing.expect(opts.all);
    try std.testing.expectError(error.InvalidArgs, parseQueryOptions(&.{"--all"}, .stats));
    try std.testing.expectError(error.InvalidArgs, parseQueryOptions(&.{ "--reset", "--all", "--verbose" }, .stats));
}

test "stats output is token-first with verbose exact bytes" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try writeAggregateStats(&out.writer, 760, 145_648_029, 110_199_423, 0, 0, 35_448_606, false);
    try std.testing.expect(std.mem.find(u8, out.written(), "Raw:           ~36.4M tokens") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "Format saved:  ~8.8M tokens") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "33.8 MB") == null);

    var verbose = Writer.Allocating.init(std.testing.allocator);
    defer verbose.deinit();
    try writeAggregateStats(&verbose.writer, 760, 145_648_029, 110_199_423, 4_000, 800, 35_448_606, true);
    try std.testing.expect(std.mem.find(u8, verbose.written(), "(145,648,029 bytes)") != null);
    try std.testing.expect(std.mem.find(u8, verbose.written(), "Declared omitted: 4,000 bytes") != null);
    try std.testing.expect(std.mem.find(u8, verbose.written(), "Wrapper diagnostics: 800 bytes") != null);
    try std.testing.expect(std.mem.find(u8, verbose.written(), "Token estimate: bytes / 4") != null);
}

test "stats schema v3 separates honest byte categories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);

    try std.testing.expect(record(allocator, std.testing.io, home, &.{ "git", "status" }, .{
        .raw_bytes = 1_000,
        .displayed_bytes = 460,
        .omitted_bytes = 300,
        .diagnostic_bytes = 60,
        .formatting_saved_bytes = 300,
    }, .{}));

    const json = try tmp.dir.readFileAlloc(std.testing.io, ".smll/stats.json", allocator, .limited(4096));
    defer allocator.free(json);
    try std.testing.expect(std.mem.find(u8, json, "\"v\":3") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"raw_bytes\":1000") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"displayed_bytes\":460") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"omitted_bytes\":300") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"diagnostic_bytes\":60") != null);
    try std.testing.expect(std.mem.find(u8, json, "\"formatting_saved_bytes\":300") != null);
}

test "stats loader keeps v1 reductions out of verified formatting savings" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "stats-v1.json",
        .data = "{\"commands\":2,\"input_bytes\":1000,\"output_bytes\":400,\"by_cmd\":{\"rg\":{\"n\":2,\"in\":1000,\"out\":400}}}\n",
    });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "stats-v1.json", allocator);
    defer allocator.free(path);

    const loaded = load(allocator, std.testing.io, path);
    try std.testing.expectEqual(@as(u64, 1), loaded.schema_version);
    try std.testing.expectEqual(@as(u64, 1_000), loaded.raw_bytes);
    try std.testing.expectEqual(@as(u64, 400), loaded.displayed_bytes);
    try std.testing.expectEqual(@as(u64, 0), loaded.formatting_saved_bytes);
    try std.testing.expectEqual(@as(u64, 0), loaded.omitted_bytes);
    try std.testing.expectEqual(@as(u64, 0), loaded.diagnostic_bytes);
    try std.testing.expectEqual(@as(u64, 0), loaded.by_cmd[0].stats.formatting_saved_bytes);
}

fn expectMissing(dir: Io.Dir, path: []const u8) !void {
    const file = dir.openFile(std.testing.io, path, .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    file.close(std.testing.io);
    return error.UnexpectedFile;
}
