const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

/// Recovery sink for the wrapper-mode lossy pipeline.
///
/// When a wrapped command exits non-zero, the compacted output an agent
/// sees may have already collapsed the warnings/stack frames that explain
/// the failure. `maybeRecord` persists the *raw* stdout+stderr to a file
/// under `~/.smll/tee/` and returns the absolute path so the caller can
/// append a one-line breadcrumb to the compacted output. The agent can
/// then read the full bytes if it needs more detail.
///
/// Best-effort: every I/O step is `catch null`-ed and never blocks the
/// pipeline. Disable via `SMLL_TEE=0` or `DO_NOT_TRACK=1` in `main.zig`.
/// Rotation: keep at most `MAX_TEE_FILES`; older logs are deleted oldest-first.
const tee_subdir = ".smll/tee";
const MAX_TEE_FILES: usize = 20;
const MAX_LABEL_LEN: usize = 48;

/// Persist raw output for a failed wrapped command. Returns the absolute
/// path on success so the caller can emit a breadcrumb; returns null when
/// disabled, the command succeeded, nothing was captured, or any I/O step
/// failed.
pub fn maybeRecord(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    argv: []const []const u8,
    exit_code: u8,
    stdout_slice: []const u8,
    stderr_slice: []const u8,
) ?[]const u8 {
    if (home.len == 0) return null;
    if (exit_code == 0) return null;
    if (stdout_slice.len == 0 and stderr_slice.len == 0) return null;
    return recordInner(allocator, io, home, argv, exit_code, stdout_slice, stderr_slice) catch null;
}

fn recordInner(
    allocator: Allocator,
    io: Io,
    home: []const u8,
    argv: []const []const u8,
    exit_code: u8,
    stdout_slice: []const u8,
    stderr_slice: []const u8,
) ![]const u8 {
    const cwd = Io.Dir.cwd();

    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, tee_subdir });
    defer allocator.free(dir_path);
    try cwd.createDirPath(io, dir_path);

    var label_buf: [MAX_LABEL_LEN]u8 = undefined;
    const label = buildLabel(argv, &label_buf);

    // Millisecond precision: keeps filenames readable while ensuring two
    // failures in the same second don't collide.
    const epoch_ns: i128 = Io.Clock.real.now(io).toNanoseconds();
    const epoch_ms: i64 = @intCast(@divTrunc(epoch_ns, std.time.ns_per_ms));
    const file_name = try std.fmt.allocPrint(allocator, "{d}_{s}.log", .{ epoch_ms, label });
    defer allocator.free(file_name);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, file_name });
    errdefer allocator.free(file_path);

    var content = Writer.Allocating.init(allocator);
    defer content.deinit();
    try writeHeader(&content.writer, argv, exit_code);
    if (stdout_slice.len > 0) {
        try content.writer.writeAll("===== stdout =====\n");
        try content.writer.writeAll(stdout_slice);
        if (stdout_slice[stdout_slice.len - 1] != '\n') try content.writer.writeByte('\n');
    }
    if (stderr_slice.len > 0) {
        try content.writer.writeAll("===== stderr =====\n");
        try content.writer.writeAll(stderr_slice);
        if (stderr_slice[stderr_slice.len - 1] != '\n') try content.writer.writeByte('\n');
    }

    try cwd.writeFile(io, .{ .sub_path = file_path, .data = content.written() });

    rotate(allocator, io, dir_path) catch {};

    return file_path;
}

fn writeHeader(w: *Writer, argv: []const []const u8, exit_code: u8) !void {
    try w.writeAll("# smll tee — raw output from failed wrapped command\n");
    try w.writeAll("# argv:");
    for (argv) |a| {
        try w.writeByte(' ');
        try w.writeAll(a);
    }
    try w.writeAll("\n# exit: ");
    try w.printInt(exit_code, 10, .lower, .{});
    try w.writeAll("\n\n");
}

/// Build a filesystem-safe `<basename>[_<subcmd>]` label, mirroring
/// stats.zig.buildLabel but stricter on character classes.
fn buildLabel(argv: []const []const u8, buf: *[MAX_LABEL_LEN]u8) []const u8 {
    if (argv.len == 0) return appendSafe("cmd", buf, 0);

    const cmd = argv[0];
    const basename = if (std.mem.findScalarLast(u8, cmd, '/')) |idx| cmd[idx + 1 ..] else cmd;

    var len = copySafe(basename, buf, 0);
    if (argv.len >= 2) {
        const sub = argv[1];
        if (sub.len > 0 and sub[0] != '-' and !isEnvAssignment(sub) and len + 1 < buf.len) {
            buf[len] = '_';
            len += 1;
            len = copySafe(sub, buf, len);
        }
    }
    if (len == 0) return appendSafe("cmd", buf, 0);
    return buf[0..len];
}

fn appendSafe(s: []const u8, buf: *[MAX_LABEL_LEN]u8, start: usize) []const u8 {
    return buf[0..copySafe(s, buf, start)];
}

fn copySafe(src: []const u8, buf: *[MAX_LABEL_LEN]u8, start: usize) usize {
    var i: usize = start;
    for (src) |c| {
        if (i >= buf.len) break;
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') {
            buf[i] = c;
        } else {
            buf[i] = '_';
        }
        i += 1;
    }
    return i;
}

fn isEnvAssignment(arg: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return false;
    return eq > 0;
}

/// Best-effort rotation: when more than `MAX_TEE_FILES` .log files live in
/// `dir_path`, delete the oldest ones (lowest mtime) until the count is back
/// at the cap. Any error short-circuits the rotation; we'd rather skip than
/// risk losing a freshly-written log.
fn rotate(allocator: Allocator, io: Io, dir_path: []const u8) !void {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    const Entry = struct {
        name: []u8,
        mtime_ns: i128,
    };

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.name);
        entries.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".log")) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        const name_dup = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name_dup);
        // `Io.Timestamp.nanoseconds` is the *full* epoch nanoseconds (i96),
        // not the sub-second component of a POSIX timespec — see
        // std/Io.zig: `pub const Timestamp = struct { nanoseconds: i96 }`
        // and the doc on File.Stat.mtime ("relative to UTC 1970-01-01").
        try entries.append(allocator, .{
            .name = name_dup,
            .mtime_ns = @as(i128, st.mtime.nanoseconds),
        });
    }

    if (entries.items.len <= MAX_TEE_FILES) return;

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            return a.mtime_ns < b.mtime_ns;
        }
    }.lt);

    const delete_count = entries.items.len - MAX_TEE_FILES;
    for (entries.items[0..delete_count]) |e| {
        dir.deleteFile(io, e.name) catch {};
    }
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Recursively remove the synthetic test home so we don't leak the
/// three-level `<home>/.smll/tee/` tree under `/tmp` after each test run.
/// Best-effort: any failure is swallowed.
fn cleanupTeeDir(_: Allocator, io: Io, home: []const u8) void {
    Io.Dir.cwd().deleteTree(io, home) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildLabel: plain command basename" {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("cargo", buildLabel(&.{"cargo"}, &buf));
}

test "buildLabel: command + subcommand joined with underscore" {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("git_status", buildLabel(&.{ "git", "status" }, &buf));
    try std.testing.expectEqualStrings("cargo_test", buildLabel(&.{ "cargo", "test" }, &buf));
}

test "buildLabel: path stripped from argv[0]" {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("git_log", buildLabel(&.{ "/usr/bin/git", "log" }, &buf));
}

test "buildLabel: flag subcommand is not appended" {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("rg", buildLabel(&.{ "rg", "--files" }, &buf));
}

test "buildLabel: env assignment is not appended as subcommand" {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("env", buildLabel(&.{ "env", "FOO=bar", "ls" }, &buf));
}

test "buildLabel: unsafe characters get replaced with underscore" {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("my_cmd", buildLabel(&.{"my cmd"}, &buf));
    // path separators strip to basename
    try std.testing.expectEqualStrings("c", buildLabel(&.{"a/b/c"}, &buf));
    // unsafe chars within basename get sanitized
    try std.testing.expectEqualStrings("foo_bar", buildLabel(&.{"foo:bar"}, &buf));
}

test "buildLabel: empty argv falls back to 'cmd'" {
    var buf: [MAX_LABEL_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("cmd", buildLabel(&.{}, &buf));
}

test "maybeRecord: returns null when exit_code is 0" {
    const allocator = std.testing.allocator;
    const path = maybeRecord(allocator, std.testing.io, "/tmp/smll-tee-test", &.{ "ls", "-l" }, 0, "stdout", "stderr");
    try std.testing.expect(path == null);
}

test "maybeRecord: returns null when home is empty" {
    const allocator = std.testing.allocator;
    const path = maybeRecord(allocator, std.testing.io, "", &.{ "ls", "-l" }, 1, "stdout", "stderr");
    try std.testing.expect(path == null);
}

test "maybeRecord: returns null when both streams are empty" {
    const allocator = std.testing.allocator;
    const path = maybeRecord(allocator, std.testing.io, "/tmp/smll-tee-test", &.{ "ls", "-l" }, 1, "", "");
    try std.testing.expect(path == null);
}

test "maybeRecord: writes file under HOME/.smll/tee and returns absolute path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Build a unique temp HOME for this test, then clean up at teardown.
    var name_buf: [64]u8 = undefined;
    const epoch_ns: i128 = Io.Clock.real.now(io).toNanoseconds();
    const home = try std.fmt.bufPrint(&name_buf, "/tmp/smll-tee-test-{d}", .{epoch_ns});
    defer cleanupTeeDir(allocator, io, home);

    const path = maybeRecord(allocator, io, home, &.{ "cargo", "test" }, 101, "compile error...\n", "thread panicked\n") orelse {
        return error.TestUnexpectedNullPath;
    };
    defer allocator.free(@constCast(path));

    try std.testing.expect(std.mem.startsWith(u8, path, home));
    try std.testing.expect(std.mem.endsWith(u8, path, "_cargo_test.log"));

    const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "compile error...") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "thread panicked") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "# argv: cargo test") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "# exit: 101") != null);
}

test "rotate: keeps newest MAX_TEE_FILES, deletes older" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var name_buf: [64]u8 = undefined;
    const epoch_ns: i128 = Io.Clock.real.now(io).toNanoseconds();
    const home = try std.fmt.bufPrint(&name_buf, "/tmp/smll-tee-rotate-{d}", .{epoch_ns});
    const tee_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, tee_subdir });
    defer allocator.free(tee_dir_path);

    try Io.Dir.cwd().createDirPath(io, tee_dir_path);
    defer cleanupTeeDir(allocator, io, home);

    const total = MAX_TEE_FILES + 5;
    const expected_deleted = total - MAX_TEE_FILES;

    // Write `total` dummy logs sequentially so mtime ordering matches the
    // 4-digit lexical prefix: 0000 is oldest, (total-1) is newest.
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const fp = try std.fmt.allocPrint(allocator, "{s}/{d:0>4}_dummy.log", .{ tee_dir_path, i });
        defer allocator.free(fp);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = fp, .data = "x" });
    }

    try rotate(allocator, io, tee_dir_path);

    var dir = try Io.Dir.cwd().openDir(io, tee_dir_path, .{ .iterate = true });
    defer dir.close(io);

    // Verify *which* files survived: the oldest `expected_deleted` should be
    // gone (0000..0004), the newest `MAX_TEE_FILES` should remain
    // (0005..0024). A sort-order regression — e.g., reversing the
    // comparator — passes the bare count check but fails this one.
    i = 0;
    while (i < total) : (i += 1) {
        const fname = try std.fmt.allocPrint(allocator, "{d:0>4}_dummy.log", .{i});
        defer allocator.free(fname);
        const f = dir.openFile(io, fname, .{}) catch |err| {
            try std.testing.expectEqual(error.FileNotFound, err);
            try std.testing.expect(i < expected_deleted);
            continue;
        };
        f.close(io);
        try std.testing.expect(i >= expected_deleted);
    }
}
