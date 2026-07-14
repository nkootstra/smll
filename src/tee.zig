const std = @import("std");
const builtin = @import("builtin");
const state_io = @import("state_io.zig");
const util = @import("util");
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
var file_sequence: std.atomic.Value(u64) = .init(0);

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
    const dir_path = try util.joinPath(allocator, home, tee_subdir);
    defer allocator.free(dir_path);
    const root_path = try util.joinPath(allocator, home, ".smll");
    defer allocator.free(root_path);
    try state_io.ensurePrivateDir(io, root_path);
    try state_io.ensurePrivateDir(io, dir_path);

    var label_buf: [MAX_LABEL_LEN]u8 = undefined;
    const label = buildLabel(argv, &label_buf);

    const epoch_ns: i64 = @intCast(Io.Clock.real.now(io).toNanoseconds());
    const sequence = file_sequence.fetchAdd(1, .monotonic);
    const file_name = try teeFileName(allocator, epoch_ns, processId(), sequence, label);
    defer allocator.free(file_name);

    const file_path = try util.joinPath(allocator, dir_path, file_name);
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

    try state_io.writePrivateFileAtomic(io, file_path, content.written());

    rotate(allocator, io, dir_path) catch {};

    return file_path;
}

fn writeHeader(w: *Writer, argv: []const []const u8, exit_code: u8) !void {
    try w.writeAll("# smll tee — raw output from failed wrapped command\n");
    try w.writeAll("# note: command output is raw and may contain secrets\n");
    try w.writeAll("# argv:");
    var redact_next = false;
    for (argv) |arg| {
        try w.writeByte(' ');
        if (redact_next) {
            try w.writeAll("[REDACTED]");
            redact_next = false;
            continue;
        }
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            const name = arg[0..eq];
            if (isSensitiveName(name) and !isCookieJarFlag(name)) {
                try w.writeAll(arg[0 .. eq + 1]);
                try w.writeAll("[REDACTED]");
                continue;
            }
        }
        try w.writeAll(arg);
        if (arg.len > 0 and arg[0] == '-' and isSensitiveName(arg) and !isVisibleSensitiveFlag(arg)) redact_next = true;
    }
    try w.writeAll("\n# exit: ");
    try util.writeDecimal(w, exit_code);
    try w.writeAll("\n\n");
}

fn isSensitiveName(name: []const u8) bool {
    const needles = [_][]const u8{ "password", "token", "secret", "api-key", "api_key", "apikey", "authorization", "cookie" };
    for (&needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(name, needle) != null) return true;
    }
    return false;
}

fn isVisibleSensitiveFlag(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "--")) return false;
    const flag = name[2..];
    return std.mem.startsWith(u8, flag, "no-") or
        std.mem.startsWith(u8, flag, "disable-") or
        isCookieJarFlag(name);
}

fn isCookieJarFlag(name: []const u8) bool {
    return std.mem.eql(u8, name, "--cookie-jar");
}

fn processId() u64 {
    return switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        .wasi => 0,
        else => @intCast(std.posix.system.getpid()),
    };
}

fn teeFileName(allocator: Allocator, epoch_ns: i64, pid: u64, sequence: u64, label: []const u8) ![]u8 {
    var prefix: [62]u8 = undefined;
    var len: usize = 0;
    len += writeUnsigned(prefix[len..], @intCast(@max(epoch_ns, 0)));
    prefix[len] = '_';
    len += 1;
    len += writeUnsigned(prefix[len..], pid);
    prefix[len] = '_';
    len += 1;
    len += writeUnsigned(prefix[len..], sequence);
    prefix[len] = '_';
    len += 1;

    const name = try allocator.alloc(u8, len + label.len + ".log".len);
    @memcpy(name[0..len], prefix[0..len]);
    @memcpy(name[len .. len + label.len], label);
    @memcpy(name[len + label.len ..], ".log");
    return name;
}

fn writeUnsigned(out: []u8, value: u64) usize {
    var reversed: [20]u8 = undefined;
    var n = value;
    var len: usize = 0;
    while (true) {
        reversed[len] = @intCast('0' + n % 10);
        len += 1;
        n /= 10;
        if (n == 0) break;
    }
    for (0..len) |i| out[i] = reversed[len - i - 1];
    return len;
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
        mtime_ns: i64,
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
            .mtime_ns = @intCast(st.mtime.nanoseconds),
        });
    }

    if (entries.items.len <= MAX_TEE_FILES) return;

    // Primary: mtime ascending. Secondary: name ascending, so that bursts of
    // failures that land in the same filesystem mtime tick (or even the same
    // millisecond, given our `epoch_ms`-prefixed naming) still rotate in a
    // stable, predictable order. Without the tiebreaker, `std.mem.sort` is
    // unstable and the deleted set is filesystem/iterator-order dependent.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.mtime_ns != b.mtime_ns) return a.mtime_ns < b.mtime_ns;
            return std.mem.lessThan(u8, a.name, b.name);
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
    try std.testing.expect(std.mem.indexOf(u8, data, "may contain secrets") != null);
}

test "maybeRecord: redacts secret-bearing argv values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var name_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(&name_buf, "/tmp/smll-tee-redact-{d}", .{Io.Clock.real.now(io).toNanoseconds()});
    defer cleanupTeeDir(allocator, io, home);

    const path = maybeRecord(allocator, io, home, &.{
        "curl",
        "--authorization",
        "Bearer abc123",
        "--api-key=key456",
        "PASSWORD=hunter2",
        "--cookie",
        "session789",
        "--verbose",
    }, 1, "failed\n", "") orelse return error.TestUnexpectedNullPath;
    defer allocator.free(@constCast(path));

    const data = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    defer allocator.free(data);
    try std.testing.expect(std.mem.find(u8, data, "Bearer abc123") == null);
    try std.testing.expect(std.mem.find(u8, data, "key456") == null);
    try std.testing.expect(std.mem.find(u8, data, "hunter2") == null);
    try std.testing.expect(std.mem.find(u8, data, "session789") == null);
    try std.testing.expect(std.mem.find(u8, data, "--authorization [REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, data, "--api-key=[REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, data, "PASSWORD=[REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, data, "--verbose") != null);
}

test "writeHeader keeps sensitive-looking toggles and cookie jar paths visible" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try writeHeader(&out.writer, &.{
        "my-cmd",
        "--no-cookie",
        "--output",
        "file.txt",
        "--no-token",
        "next-token-arg",
        "--disable-password",
        "next-password-arg",
        "--cookie-jar",
        "/tmp/cookies.txt",
        "--cookie-jar=/tmp/other-cookies.txt",
    }, 1);

    try std.testing.expect(std.mem.find(u8, out.written(), "# argv: my-cmd --no-cookie --output file.txt --no-token next-token-arg --disable-password next-password-arg --cookie-jar /tmp/cookies.txt --cookie-jar=/tmp/other-cookies.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out.written(), "[REDACTED]") == null);
}

test "writeHeader exceptions do not weaken secret value redaction" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try writeHeader(&out.writer, &.{
        "my-cmd",
        "--password",
        "password-value",
        "--token=token-value",
        "--no-token=token-disabled",
        "--client-secret",
        "secret-value",
        "--authorization",
        "Bearer auth-value",
        "--cookie",
        "cookie-value",
        "API_KEY=key-value",
    }, 1);

    const header = out.written();
    inline for (.{ "password-value", "token-value", "token-disabled", "secret-value", "auth-value", "cookie-value", "key-value" }) |secret| {
        try std.testing.expect(std.mem.find(u8, header, secret) == null);
    }
    try std.testing.expect(std.mem.find(u8, header, "--password [REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, header, "--token=[REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, header, "--no-token=[REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, header, "--client-secret [REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, header, "--authorization [REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, header, "--cookie [REDACTED]") != null);
    try std.testing.expect(std.mem.find(u8, header, "API_KEY=[REDACTED]") != null);
}

test "maybeRecord: uses collision-resistant private tee paths" {
    if (@import("builtin").os.tag == .windows) return;

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var name_buf: [64]u8 = undefined;
    const home = try std.fmt.bufPrint(&name_buf, "/tmp/smll-tee-private-{d}", .{Io.Clock.real.now(io).toNanoseconds()});
    defer cleanupTeeDir(allocator, io, home);

    const first = maybeRecord(allocator, io, home, &.{"cargo"}, 1, "one\n", "") orelse return error.TestUnexpectedNullPath;
    defer allocator.free(@constCast(first));
    const second = maybeRecord(allocator, io, home, &.{"cargo"}, 1, "two\n", "") orelse return error.TestUnexpectedNullPath;
    defer allocator.free(@constCast(second));
    try std.testing.expect(!std.mem.eql(u8, first, second));

    const root_path = try std.fmt.allocPrint(allocator, "{s}/.smll", .{home});
    defer allocator.free(root_path);
    var root = try Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try root.stat(io)).permissions.toMode() & 0o777);

    const tee_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, tee_subdir });
    defer allocator.free(tee_path);
    var tee_dir = try Io.Dir.cwd().openDir(io, tee_path, .{ .iterate = true });
    defer tee_dir.close(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), (try tee_dir.stat(io)).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try Io.Dir.cwd().statFile(io, first, .{})).permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try Io.Dir.cwd().statFile(io, second, .{})).permissions.toMode() & 0o777);
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
