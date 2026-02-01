const std = @import("std");
const build_options = @import("build_options");
const git_status = @import("git_status");
const git_diff = @import("git_diff");
const git_log = @import("git_log");
const git_show = @import("git_show");

const exe_path: []const u8 = build_options.smll_exe_path;

const dirty_fixture = @embedFile("fixture_git_status_dirty");
const clean_fixture = @embedFile("fixture_git_status_clean");
const conflict_fixture = @embedFile("fixture_git_status_conflict");
const diff_simple_fixture = @embedFile("fixture_git_diff_simple");
const diff_multi_fixture = @embedFile("fixture_git_diff_multi");
const diff_rename_modify_fixture = @embedFile("fixture_git_diff_rename_modify");
const log_linear_fixture = @embedFile("fixture_git_log_linear");
const log_merge_fixture = @embedFile("fixture_git_log_merge");
const show_simple_fixture = @embedFile("fixture_git_show_simple");
const show_body_fixture = @embedFile("fixture_git_show_body");
const status_large_fixture = @embedFile("fixture_git_status_large");
const diff_large_fixture = @embedFile("fixture_git_diff_large");
const log_large_fixture = @embedFile("fixture_git_log_large");
const show_large_fixture = @embedFile("fixture_git_show_large");

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runSmll(allocator: std.mem.Allocator, input: []const u8) !RunResult {
    var child = std.process.Child.init(&.{exe_path}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    if (input.len > 0) {
        try child.stdin.?.writeAll(input);
    }
    child.stdin.?.close();
    child.stdin = null;

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    try child.collectOutput(allocator, &stdout, &stderr, 2 * 1024 * 1024);

    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = try child.wait(),
    };
}

test "echo hello passes through" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, "hello\n");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "empty stdin produces empty stdout, exit 0" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, "");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "1KB arbitrary bytes pass through byte-identically (fail-open)" {
    const allocator = std.testing.allocator;
    var input: [1024]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i % 256);
    var result = try runSmll(allocator, &input);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &input, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "100KB input passes through correctly (buffer growth)" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(input);
    for (input, 0..) |*b, i| b.* = @intCast(i % 256);
    var result = try runSmll(allocator, input);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, input, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "buffer_size + 1 bytes pass through correctly (writer flush fires)" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 4097);
    defer allocator.free(input);
    for (input, 0..) |*b, i| b.* = @intCast(i % 256);
    var result = try runSmll(allocator, input);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, input, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

fn expectedFilterOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try git_status.apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "dirty fixture: smll output == GitStatusFilter.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedFilterOutput(allocator, dirty_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, dirty_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "clean fixture: smll output == GitStatusFilter.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedFilterOutput(allocator, clean_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, clean_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "conflict fixture: smll output == GitStatusFilter.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedFilterOutput(allocator, conflict_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, conflict_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "non-git input passes through unchanged (fail-open)" {
    const allocator = std.testing.allocator;
    const ls_like = "total 48\ndrwxr-xr-x  10 user  staff  320 Apr 18 07:00 .\n-rw-r--r--   1 user  staff  512 Apr 18 07:00 README\n";
    var result = try runSmll(allocator, ls_like);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(ls_like, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "dirty fixture: smll output is strictly smaller than input" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, dirty_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(result.stdout.len < dirty_fixture.len);
}

// v0.4 format assertions for status fixtures.
test "dirty fixture: v0.4 format — branch sigil, path sigils, no headers" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, dirty_fixture);
    defer result.deinit(allocator);
    // Branch line
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "# main\n"));
    // Unstaged modified paths
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "M src/main.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "M src/pipeline.zig\n") != null);
    // Untracked paths
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "? src/filters/git_status.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "? tests/fixtures/git_status_dirty.txt\n") != null);
    // No section headers
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Changes not staged") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Untracked files:") == null);
    // No hint lines
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "(use \"git") == null);
}

test "clean fixture: v0.4 format — branch line only" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, clean_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("# main\n", result.stdout);
}

test "conflict fixture: v0.4 format — S sigil staged, UU sigil unmerged" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, conflict_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "# main\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "S src/pipeline.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "UU src/filters/git_status.zig\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "? tests/fixtures/git_status_conflict.txt\n") != null);
}

test "dirty fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, dirty_fixture);
    defer result.deinit(allocator);
    const target = (dirty_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "conflict fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, conflict_fixture);
    defer result.deinit(allocator);
    const target = (conflict_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "pipe-mode idempotence: v0.4 status output piped into smll again is unchanged" {
    // v0.4 output starts with "# main\n" — does NOT match git_status.matches
    // ("On branch" prefix required). So smll passes it through unchanged.
    const allocator = std.testing.allocator;

    // First pass: dirty_fixture → v0.4 output.
    var first = try runSmll(allocator, dirty_fixture);
    defer first.deinit(allocator);

    // Second pass: v0.4 output → should be identical (passthrough).
    var second = try runSmll(allocator, first.stdout);
    defer second.deinit(allocator);

    try std.testing.expectEqualSlices(u8, first.stdout, second.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, second.term);
}

fn expectedDiffOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try git_diff.apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "diff simple fixture: smll output == git_diff.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedDiffOutput(allocator, diff_simple_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, diff_simple_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "diff multi fixture: smll output == git_diff.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedDiffOutput(allocator, diff_multi_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, diff_multi_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "diff rename+modify fixture: smll output == git_diff.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedDiffOutput(allocator, diff_rename_modify_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, diff_rename_modify_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "diff multi fixture: smll output is strictly smaller than input" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, diff_multi_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(result.stdout.len < diff_multi_fixture.len);
}

fn expectedLogOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try git_log.apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "log linear fixture: smll output == git_log.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedLogOutput(allocator, log_linear_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, log_linear_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "log merge fixture: smll output == git_log.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedLogOutput(allocator, log_merge_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, log_merge_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "log merge fixture: smll output is strictly smaller than input" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, log_merge_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(result.stdout.len < log_merge_fixture.len);
}

fn expectedShowOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try git_show.apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "show simple fixture: smll output == git_show.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedShowOutput(allocator, show_simple_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, show_simple_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "show body fixture: smll output == git_show.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedShowOutput(allocator, show_body_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, show_body_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "show body fixture: smll output is strictly smaller than input" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, show_body_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(result.stdout.len < show_body_fixture.len);
}

test "show: priority over log (show output routes to git_show, not git_log)" {
    const allocator = std.testing.allocator;
    const expected_show = try expectedShowOutput(allocator, show_simple_fixture);
    defer allocator.free(expected_show);
    const expected_log = try expectedLogOutput(allocator, show_simple_fixture);
    defer allocator.free(expected_log);
    try std.testing.expect(!std.mem.eql(u8, expected_show, expected_log));

    var result = try runSmll(allocator, show_simple_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings(expected_show, result.stdout);
}

test "dirty fixture: latency smoke (<100ms loose bound)" {
    const allocator = std.testing.allocator;
    var timer = try std.time.Timer.start();
    var result = try runSmll(allocator, dirty_fixture);
    defer result.deinit(allocator);
    const elapsed_ns = timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    // Loose smoke: full process spawn + IPC dominates. Unit 5 does a real hyperfine benchmark.
    try std.testing.expect(elapsed_ms < 100);
}

fn runSmllWrapper(
    allocator: std.mem.Allocator,
    inner_argv: []const []const u8,
) !RunResult {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(allocator);
    try full.append(allocator, exe_path);
    for (inner_argv) |a| try full.append(allocator, a);

    var child = std.process.Child.init(full.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    try child.collectOutput(allocator, &stdout, &stderr, 2 * 1024 * 1024);

    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = try child.wait(),
    };
}

test "wrapper: `smll cat <fixture>` passes through unfiltered (non-git outer cmd)" {
    // v0.4 argv guard: the outer command is "cat", not "git", so the formatter
    // switch is bypassed and stdout passes through verbatim (no filtering).
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "dirty.txt", .data = dirty_fixture });
    const tmp_path = try tmp.dir.realpathAlloc(allocator, "dirty.txt");
    defer allocator.free(tmp_path);

    var result = try runSmllWrapper(allocator, &.{ "/bin/cat", tmp_path });
    defer result.deinit(allocator);

    // Passthrough: raw fixture bytes must come through unchanged.
    try std.testing.expectEqualSlices(u8, dirty_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "wrapper: child exit code propagates (exit 42)" {
    const allocator = std.testing.allocator;
    var result = try runSmllWrapper(allocator, &.{ "/bin/sh", "-c", "exit 42" });
    defer result.deinit(allocator);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 42 }, result.term);
}

test "wrapper: child stderr flows through to smll's stderr" {
    const allocator = std.testing.allocator;
    var result = try runSmllWrapper(
        allocator,
        &.{ "/bin/sh", "-c", "printf 'child-err\\n' 1>&2; printf ''" },
    );
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("child-err\n", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "wrapper: non-zero exit still emits filtered stdout" {
    const allocator = std.testing.allocator;
    // Child prints a git-status-like single-line header then exits 1.
    // smll should still filter/emit stdout and propagate exit code 1.
    const script = "printf 'On branch main\\nnothing to commit, working tree clean\\n'; exit 1";
    var result = try runSmllWrapper(allocator, &.{ "/bin/sh", "-c", script });
    defer result.deinit(allocator);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 1 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "On branch main") != null);
}

test "large status fixture: smll output == git_status.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedFilterOutput(allocator, status_large_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, status_large_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "large status fixture: v0.4 format — branch sigil, A sigils for staged new files" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, status_large_fixture);
    defer result.deinit(allocator);
    // Branch line
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "# main\n"));
    // Staged new files use A sigil
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "A src/components/comp_01.rs\n") != null);
    // Unstaged modified uses M sigil
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "M src/mod_01.rs\n") != null);
    // No section headers
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Changes to be committed:") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Changes not staged") == null);
}

test "large status fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, status_large_fixture);
    defer result.deinit(allocator);
    const target = (status_large_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "large diff fixture: smll output == git_diff.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedDiffOutput(allocator, diff_large_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, diff_large_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "large log fixture: smll output == git_log.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedLogOutput(allocator, log_large_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, log_large_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

test "large show fixture: smll output == git_show.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedShowOutput(allocator, show_large_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, show_large_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, result.term);
}

// ---------------------------------------------------------------------------
// Helper: run smll with a custom PATH prefix (for fake-git tests).
// Creates a modified copy of the current environment with PATH = binDir:$PATH.
// ---------------------------------------------------------------------------
fn runSmllWrapperFakeGit(
    allocator: std.mem.Allocator,
    bin_dir: []const u8,
    inner_argv: []const []const u8,
) !RunResult {
    // Build full argv: [smll_exe, inner_argv...]
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(allocator);
    try full.append(allocator, exe_path);
    for (inner_argv) |a| try full.append(allocator, a);

    // Build env with prepended PATH.
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    const old_path = env.get("PATH") orelse "";
    const new_path = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ bin_dir, old_path });
    defer allocator.free(new_path);
    try env.put("PATH", new_path);

    var child = std.process.Child.init(full.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = &env;
    try child.spawn();

    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(allocator);
    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    try child.collectOutput(allocator, &stdout, &stderr, 2 * 1024 * 1024);

    return .{
        .stdout = try stdout.toOwnedSlice(allocator),
        .stderr = try stderr.toOwnedSlice(allocator),
        .term = try child.wait(),
    };
}

// Write a shell script to dir/name that is executable.
fn writeFakeScript(dir: std.fs.Dir, name: []const u8, body: []const u8) !void {
    try dir.writeFile(.{ .sub_path = name, .data = body });
    const file = try dir.openFile(name, .{});
    defer file.close();
    try file.chmod(0o755);
}

// ---------------------------------------------------------------------------
// Unit-0 characterisation tests — must FAIL before dispatch is implemented.
// ---------------------------------------------------------------------------

// (a) Registered subcommand (status) with stderr noise:
//     After dispatch: filter absorbs stderr — smll's own stderr is EMPTY.
//     Before dispatch: stderr_behavior=.Inherit leaks child stderr into
//     smll's stderr, so result.stderr is non-empty → test fails.
test "dispatch: registered subcommand does not forward child stderr to smll stderr" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(bin_path);

    // Fake `git` that emits clean-fixture-like stdout + a warning on stderr.
    try writeFakeScript(tmp.dir, "git",
        \\#!/bin/sh
        \\printf 'On branch main\nnothing to commit, working tree clean\n'
        \\printf 'warning: test-stderr-noise\n' >&2
    );

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "git", "status" });
    defer result.deinit(allocator);

    // After dispatch: the filter's apply handles both buffers; stderr is NOT
    // re-emitted.  smll's stderr must be empty.
    try std.testing.expectEqualStrings("", result.stderr);
}

// (b) Unregistered subcommand (reflog) whose fake-git stdout looks like a
//     git_status fixture:
//     After dispatch: argv-aware switch detects "reflog" is not a known
//     formatter → passthrough → stdout is the raw unfiltered fixture bytes.
//     Before dispatch: pipeline.dispatch runs git_status.matches on the
//     output → matches → applies the filter → stdout is SMALLER than the
//     raw fixture → test fails.
test "dispatch: unregistered subcommand stdout is not filtered (verbatim passthrough)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(bin_path);

    // Fake `git` that always prints the dirty fixture on stdout regardless of
    // the subcommand — this makes the content match git_status.matches.
    // We invoke it as `git reflog` so the subcommand is unregistered.
    // Use cat+heredoc to avoid printf %s interpretation issues.
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\ncat <<'SMLL_EOF'\n{s}SMLL_EOF\n",
        .{dirty_fixture},
    );
    defer allocator.free(script);
    try writeFakeScript(tmp.dir, "git", script);

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "git", "reflog" });
    defer result.deinit(allocator);

    // Passthrough: stdout must equal the raw dirty_fixture bytes.
    try std.testing.expectEqualSlices(u8, dirty_fixture, result.stdout);
}

// (c) Registered subcommand (status) with BOTH stdout and stderr non-empty:
//     After dispatch: filter receives both buffers; stderr is NOT forwarded.
//     Before dispatch: child stderr leaks through .Inherit → result.stderr
//     is non-empty → test fails.
test "dispatch: registered subcommand with both stdout and stderr — stderr not forwarded" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(bin_path);

    // Fake `git status` with non-trivial stdout and a stderr payload.
    try writeFakeScript(tmp.dir, "git",
        \\#!/bin/sh
        \\printf 'On branch main\nnothing to commit, working tree clean\n'
        \\printf 'hint: use --verbose to see details\n' >&2
    );

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "git", "status" });
    defer result.deinit(allocator);

    // Verify filter ran on stdout (output non-empty) AND stderr is empty.
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expectEqualStrings("", result.stderr);
}

// (d) Non-git outer command (cargo push):
//     argv[1] = "cargo" ≠ "git" → argv guard forces passthrough regardless of
//     argv[2] = "push" being a KnownSubcommand.
//     After dispatch: stdout is unfiltered raw bytes.
//     Before dispatch: pipeline.dispatch runs git_status.matches on the stdout
//     → if it looks like git status output it gets filtered → test fails.
test "dispatch: non-git outer command bypasses formatter (argv guard)" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(bin_path);

    // Fake `cargo` that emits dirty-fixture-like content so pipeline.dispatch
    // would normally route it to git_status.apply.
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\ncat <<'SMLL_EOF'\n{s}SMLL_EOF\n",
        .{dirty_fixture},
    );
    defer allocator.free(script);
    try writeFakeScript(tmp.dir, "cargo", script);

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "cargo", "push" });
    defer result.deinit(allocator);

    // Passthrough: raw dirty_fixture bytes must come through unchanged.
    try std.testing.expectEqualSlices(u8, dirty_fixture, result.stdout);
}

test "broken pipe mid-stream returns non-zero exit without panic" {
    const allocator = std.testing.allocator;
    var child = std.process.Child.init(&.{exe_path}, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    child.stdout.?.close();
    child.stdout = null;

    const input = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(input);
    @memset(input, 'x');
    child.stdin.?.writeAll(input) catch {};
    child.stdin.?.close();
    child.stdin = null;

    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    var stderr_reader_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(&stderr_reader_buf);
    stderr_reader.interface.appendRemainingUnlimited(allocator, &stderr) catch {};

    const term = try child.wait();
    switch (term) {
        .Exited => |code| try std.testing.expect(code != 0),
        .Signal => {},
        else => {},
    }
}
