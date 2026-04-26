const std = @import("std");
const build_options = @import("build_options");
const git_status = @import("git_status");
const git_diff = @import("git_diff");
const git_log = @import("git_log");
const git_show = @import("git_show");
const git_commit = @import("git_commit");
const git_branch = @import("git_branch");

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
// git_commit fixtures (pipe-matching)
const commit_simple_fixture = @embedFile("fixture_git_commit_simple");
const commit_multifile_fixture = @embedFile("fixture_git_commit_multifile");
const commit_large_fixture = @embedFile("fixture_git_commit_large");
// git_branch fixtures (pipe-matching)
const branch_list_fixture = @embedFile("fixture_git_branch_list");
// git_add fixtures (argv-only)
const add_error_stdout_fixture = @embedFile("fixture_git_add_error_stdout");
const add_error_stderr_fixture = @embedFile("fixture_git_add_error_stderr");
// git_push fixtures (argv-only)
const push_simple_stdout_fixture = @embedFile("fixture_git_push_simple_stdout");
const push_simple_stderr_fixture = @embedFile("fixture_git_push_simple_stderr");
const push_large_stdout_fixture = @embedFile("fixture_git_push_large_stdout");
const push_large_stderr_fixture = @embedFile("fixture_git_push_large_stderr");
// git_pull fixtures (argv-only)
const pull_ff_stdout_fixture = @embedFile("fixture_git_pull_ff_stdout");
const pull_ff_stderr_fixture = @embedFile("fixture_git_pull_ff_stderr");
const pull_uptodate_stdout_fixture = @embedFile("fixture_git_pull_uptodate_stdout");
const pull_uptodate_stderr_fixture = @embedFile("fixture_git_pull_uptodate_stderr");
// git_fetch fixtures (argv-only)
const fetch_simple_stdout_fixture = @embedFile("fixture_git_fetch_simple_stdout");
const fetch_simple_stderr_fixture = @embedFile("fixture_git_fetch_simple_stderr");
// git_merge fixtures (argv-only)
const merge_ff_fixture = @embedFile("fixture_git_merge_ff");
const merge_commit_fixture = @embedFile("fixture_git_merge_commit");
const merge_conflict_stdout_fixture = @embedFile("fixture_git_merge_conflict_stdout");
const merge_conflict_stderr_fixture = @embedFile("fixture_git_merge_conflict_stderr");
const merge_large_fixture = @embedFile("fixture_git_merge_large");
// git_rebase fixtures (argv-only)
const rebase_simple_fixture = @embedFile("fixture_git_rebase_simple");
const rebase_large_fixture = @embedFile("fixture_git_rebase_large");
// git_checkout fixtures (argv-only)
const checkout_switch_stdout_fixture = @embedFile("fixture_git_checkout_switch_stdout");
const checkout_switch_stderr_fixture = @embedFile("fixture_git_checkout_switch_stderr");
// git_stash fixtures (argv-only)
const stash_save_fixture = @embedFile("fixture_git_stash_save");
const stash_list_fixture = @embedFile("fixture_git_stash_list");
// git_blame fixtures (argv-only)
const blame_simple_fixture = @embedFile("fixture_git_blame_simple");
const blame_large_fixture = @embedFile("fixture_git_blame_large");
// columnar fixtures (default-lossy dispatch; SMLL_LOSSLESS=1 opts out)
const docker_ps_fixture = @embedFile("fixture_docker_ps");
const kubectl_pods_fixture = @embedFile("fixture_kubectl_pods");
const gh_pr_list_fixture = @embedFile("fixture_gh_pr_list");
// v0.9 smoke-test fixtures
const jest_failing_fixture = @embedFile("fixture_jest_failing");
const tsc_errors_fixture = @embedFile("fixture_tsc_errors");
const go_test_v_fixture = @embedFile("fixture_go_test_v");
const docker_logs_fixture = @embedFile("fixture_docker_logs");
const npm_install_fixture = @embedFile("fixture_npm_install");

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
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{exe_path},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    if (input.len > 0) {
        try child.stdin.?.writeStreamingAll(io, input);
    }
    child.stdin.?.close(io);
    child.stdin = null;

    return try drainChild(allocator, io, &child);
}

/// Concurrently drain stdout + stderr from a running child, wait on it,
/// and return owned slices. Mirrors what std.process.run does internally so
/// we don't deadlock when both pipes fill.
fn drainChild(allocator: std.mem.Allocator, io: std.Io, child: *std.process.Child) !RunResult {
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(
        allocator,
        io,
        multi_reader_buffer.toStreams(),
        &.{ child.stdout.?, child.stderr.? },
    );
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, .none)) |_| {
        if (stdout_reader.buffered().len > 2 * 1024 * 1024) return error.StreamTooLong;
        if (stderr_reader.buffered().len > 2 * 1024 * 1024) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);

    return .{ .stdout = stdout_slice, .stderr = stderr_slice, .term = term };
}

test "echo hello passes through" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, "hello\n");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "empty stdin produces empty stdout, exit 0" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, "");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "1KB arbitrary bytes pass through byte-identically (fail-open)" {
    const allocator = std.testing.allocator;
    var input: [1024]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i % 256);
    var result = try runSmll(allocator, &input);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &input, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "100KB input passes through correctly (buffer growth)" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(input);
    for (input, 0..) |*b, i| b.* = @intCast(i % 256);
    var result = try runSmll(allocator, input);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, input, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "buffer_size + 1 bytes pass through correctly (writer flush fires)" {
    const allocator = std.testing.allocator;
    const input = try allocator.alloc(u8, 4097);
    defer allocator.free(input);
    for (input, 0..) |*b, i| b.* = @intCast(i % 256);
    var result = try runSmll(allocator, input);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, input, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
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
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "clean fixture: smll output == GitStatusFilter.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedFilterOutput(allocator, clean_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, clean_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "conflict fixture: smll output == GitStatusFilter.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedFilterOutput(allocator, conflict_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, conflict_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "non-git input: ls-like output gets compressed by ls_compact" {
    const allocator = std.testing.allocator;
    const ls_like = "total 48\ndrwxr-xr-x  10 user  staff  320 Apr 18 07:00 .\n-rw-r--r--   1 user  staff  512 Apr 18 07:00 README\n";
    var result = try runSmll(allocator, ls_like);
    defer result.deinit(allocator);

    // ls_compact now matches in pipe mode and extracts filenames.
    try std.testing.expect(result.stdout.len <= ls_like.len);
    try std.testing.expect(std.mem.find(u8, result.stdout, "README") != null);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
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
    try std.testing.expect(std.mem.find(u8, result.stdout, "M src/main.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "M src/pipeline.zig\n") != null);
    // Untracked paths
    try std.testing.expect(std.mem.find(u8, result.stdout, "? src/filters/git_status.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "? tests/fixtures/git_status_dirty.txt\n") != null);
    // No section headers
    try std.testing.expect(std.mem.find(u8, result.stdout, "Changes not staged") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Untracked files:") == null);
    // No hint lines
    try std.testing.expect(std.mem.find(u8, result.stdout, "(use \"git") == null);
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
    try std.testing.expect(std.mem.find(u8, result.stdout, "S src/pipeline.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "UU src/filters/git_status.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "? tests/fixtures/git_status_conflict.txt\n") != null);
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
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, second.term);
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
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "diff multi fixture: smll output == git_diff.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedDiffOutput(allocator, diff_multi_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, diff_multi_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "diff rename+modify fixture: smll output == git_diff.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedDiffOutput(allocator, diff_rename_modify_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, diff_rename_modify_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
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
    try git_log.applyCompact(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "log linear fixture: smll output == git_log.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedLogOutput(allocator, log_linear_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, log_linear_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "log merge fixture: smll output == git_log.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedLogOutput(allocator, log_merge_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, log_merge_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
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
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "show body fixture: smll output == git_show.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedShowOutput(allocator, show_body_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, show_body_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
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
    const io = std.testing.io;
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var result = try runSmll(allocator, dirty_fixture);
    defer result.deinit(allocator);
    const elapsed = start.untilNow(io);
    const elapsed_ns: i128 = elapsed.raw.nanoseconds;
    const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
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

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = full.items,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
    });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

test "wrapper: `smll cat <fixture>` passes through unfiltered (non-git outer cmd)" {
    // v0.4 argv guard: the outer command is "cat", not "git", so the formatter
    // switch is bypassed and stdout passes through verbatim (no filtering).
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dirty.txt", .data = dirty_fixture });
    const tmp_path = try tmp.dir.realPathFileAlloc(std.testing.io, "dirty.txt", allocator);
    defer allocator.free(tmp_path);

    var result = try runSmllWrapper(allocator, &.{ "/bin/cat", tmp_path });
    defer result.deinit(allocator);

    // Passthrough: raw fixture bytes must come through unchanged.
    try std.testing.expectEqualSlices(u8, dirty_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "wrapper: child exit code propagates (exit 42)" {
    const allocator = std.testing.allocator;
    var result = try runSmllWrapper(allocator, &.{ "/bin/sh", "-c", "exit 42" });
    defer result.deinit(allocator);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 42 }, result.term);
}

test "wrapper: child stderr flows through to smll's stderr" {
    const allocator = std.testing.allocator;
    var result = try runSmllWrapper(
        allocator,
        &.{ "/bin/sh", "-c", "printf 'child-err\\n' 1>&2; printf ''" },
    );
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("child-err\n", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "wrapper: non-zero exit still emits filtered stdout" {
    const allocator = std.testing.allocator;
    // Child prints a git-status-like single-line header then exits 1.
    // smll should still filter/emit stdout and propagate exit code 1.
    const script = "printf 'On branch main\\nnothing to commit, working tree clean\\n'; exit 1";
    var result = try runSmllWrapper(allocator, &.{ "/bin/sh", "-c", script });
    defer result.deinit(allocator);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expect(result.stdout.len > 0);
    try std.testing.expect(std.mem.find(u8, result.stdout, "On branch main") != null);
}

test "large status fixture: smll output == git_status.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedFilterOutput(allocator, status_large_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, status_large_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "large status fixture: v0.4 format — branch sigil, grouped directory entries" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, status_large_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "# main\n"));
    try std.testing.expect(std.mem.find(u8, result.stdout, "A src/components/") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "M src/") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Changes to be committed:") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Changes not staged") == null);
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
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "large log fixture: smll output == git_log.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedLogOutput(allocator, log_large_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, log_large_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "large show fixture: smll output == git_show.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedShowOutput(allocator, show_large_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, show_large_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

// ---------------------------------------------------------------------------
// v0.4 format assertions for diff fixtures.
// ---------------------------------------------------------------------------

test "diff simple fixture: v0.4 format — d sigil, @ sigil, no diff --git" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, diff_simple_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, result.stdout, "d simple.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "@1\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "+line two") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "diff --git") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "index ") == null);
}

test "diff rename+modify fixture: v0.4 format — d rename sigil, @ sigil" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, diff_rename_modify_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, result.stdout, "d old.txt -> new.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "@1\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "rename from") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "similarity index") == null);
}

// ---------------------------------------------------------------------------
// v0.4 format assertions for log fixtures.
// ---------------------------------------------------------------------------

test "log linear fixture: compact format — sha7 + subject, no body/date/author" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, log_linear_fixture);
    defer result.deinit(allocator);
    // Compact format: <sha7> <subject>
    try std.testing.expect(std.mem.find(u8, result.stdout, "f0ad49e ") != null);
    // No body lines, no author/date labels
    try std.testing.expect(std.mem.find(u8, result.stdout, "commit ") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Author:") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Date:") == null);
}

test "log merge fixture: compact format — sha7 + subject" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, log_merge_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, result.stdout, "012aa35 ") != null);
    // No merge parent sigils in compact mode
    try std.testing.expect(std.mem.find(u8, result.stdout, "Merge:") == null);
}

// ---------------------------------------------------------------------------
// v0.4 format assertions for show fixtures.
// ---------------------------------------------------------------------------

test "show simple fixture: compact header + d sigil, no diff --git or Author/Date" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, show_simple_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, result.stdout, "95cbeda feat: add a.txt with one line\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "d a.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "@0\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "+line1") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "diff --git") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Author:") == null);
}

// ---------------------------------------------------------------------------
// R3 gate: diff/log/show fixtures ≤ 80% of raw bytes.
// ---------------------------------------------------------------------------

test "diff simple fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, diff_simple_fixture);
    defer result.deinit(allocator);
    const target = (diff_simple_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "diff multi fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, diff_multi_fixture);
    defer result.deinit(allocator);
    const target = (diff_multi_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "diff rename+modify fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, diff_rename_modify_fixture);
    defer result.deinit(allocator);
    const target = (diff_rename_modify_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "log linear fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, log_linear_fixture);
    defer result.deinit(allocator);
    const target = (log_linear_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "log merge fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, log_merge_fixture);
    defer result.deinit(allocator);
    const target = (log_merge_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "show simple fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, show_simple_fixture);
    defer result.deinit(allocator);
    const target = (show_simple_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "show body fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, show_body_fixture);
    defer result.deinit(allocator);
    const target = (show_body_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "large diff fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, diff_large_fixture);
    defer result.deinit(allocator);
    const target = (diff_large_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "large log fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, log_large_fixture);
    defer result.deinit(allocator);
    const target = (log_large_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

test "large show fixture: R3 gate — smll ≤ 80% of raw bytes" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, show_large_fixture);
    defer result.deinit(allocator);
    const target = (show_large_fixture.len * 80) / 100;
    try std.testing.expect(result.stdout.len <= target);
}

// ---------------------------------------------------------------------------
// Pipe-mode idempotence: v0.4 diff/log/show output piped again is unchanged.
// ---------------------------------------------------------------------------

test "pipe-mode idempotence: v0.4 diff output piped into smll is unchanged" {
    // v0.4 diff output starts with "d <path>" — does NOT match git_diff.matches
    // ("diff --git a/" required). So smll passes it through unchanged.
    const allocator = std.testing.allocator;

    var first = try runSmll(allocator, diff_simple_fixture);
    defer first.deinit(allocator);

    var second = try runSmll(allocator, first.stdout);
    defer second.deinit(allocator);

    try std.testing.expectEqualSlices(u8, first.stdout, second.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, second.term);
}

test "pipe-mode idempotence: v0.4 log output piped into smll is unchanged" {
    // v0.4 log output starts with "c <sha7> ..." — does NOT match git_log.matches
    // ("commit " + 40 hex chars required). So smll passes it through unchanged.
    const allocator = std.testing.allocator;

    var first = try runSmll(allocator, log_linear_fixture);
    defer first.deinit(allocator);

    var second = try runSmll(allocator, first.stdout);
    defer second.deinit(allocator);

    try std.testing.expectEqualSlices(u8, first.stdout, second.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, second.term);
}

test "pipe-mode idempotence: v0.4 show output piped into smll is unchanged" {
    // v0.4 show output starts with "c <sha7> ..." — does NOT match git_show.matches.
    const allocator = std.testing.allocator;

    var first = try runSmll(allocator, show_simple_fixture);
    defer first.deinit(allocator);

    var second = try runSmll(allocator, first.stdout);
    defer second.deinit(allocator);

    try std.testing.expectEqualSlices(u8, first.stdout, second.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, second.term);
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
    var env = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer env.deinit();
    const old_path = env.get("PATH") orelse "";
    const new_path = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ bin_dir, old_path });
    defer allocator.free(new_path);
    try env.put("PATH", new_path);

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = full.items,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
        .environ_map = &env,
    });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

// Write a shell script to dir/name that is executable.
fn writeFakeScript(dir: std.Io.Dir, name: []const u8, body: []const u8) !void {
    const io = std.testing.io;
    try dir.writeFile(io, .{ .sub_path = name, .data = body });
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    try file.setPermissions(io, .fromMode(0o755));
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
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
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

// ---------------------------------------------------------------------------
// Unit 9: git_commit byte-equivalence tests (pipe-matching filter).
// ---------------------------------------------------------------------------

fn expectedCommitOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try git_commit.apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "git_commit simple fixture: smll output == git_commit.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedCommitOutput(allocator, commit_simple_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, commit_simple_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_commit multifile fixture: smll output == git_commit.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedCommitOutput(allocator, commit_multifile_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, commit_multifile_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_commit large fixture: smll output == git_commit.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedCommitOutput(allocator, commit_large_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, commit_large_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

// ---------------------------------------------------------------------------
// Unit 9: git_branch byte-equivalence tests (pipe-matching filter).
// ---------------------------------------------------------------------------

fn expectedBranchOutput(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try git_branch.apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "git_branch list fixture: smll output == git_branch.apply byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = try expectedBranchOutput(allocator, branch_list_fixture);
    defer allocator.free(expected);

    var result = try runSmll(allocator, branch_list_fixture);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(expected, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

// ---------------------------------------------------------------------------
// Unit 9: argv-only filter pipe-mode passthrough tests.
// These filters have matches() == false, so piping their fixture content into
// smll hits fail-open passthrough — output equals input byte-for-byte.
// ---------------------------------------------------------------------------

test "git_add small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    // Use stderr fixture (non-empty) as representative content.
    var result = try runSmll(allocator, add_error_stderr_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, add_error_stderr_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_push small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, push_simple_stdout_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, push_simple_stdout_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_push large fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, push_large_stdout_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, push_large_stdout_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_pull small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, pull_ff_stdout_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, pull_ff_stdout_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_pull uptodate fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, pull_uptodate_stdout_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, pull_uptodate_stdout_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_fetch small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    // fetch stdout is empty; use stderr as representative non-empty content.
    var result = try runSmll(allocator, fetch_simple_stderr_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, fetch_simple_stderr_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_merge small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, merge_ff_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, merge_ff_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_merge large fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, merge_large_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, merge_large_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_rebase small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, rebase_simple_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, rebase_simple_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_rebase large fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, rebase_large_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, rebase_large_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_checkout small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    // checkout stdout is empty; use stderr as representative non-empty content.
    var result = try runSmll(allocator, checkout_switch_stderr_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, checkout_switch_stderr_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_stash small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, stash_save_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, stash_save_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_stash list fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, stash_list_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, stash_list_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_blame small fixture: pipe-mode compresses blame output" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, blame_simple_fixture);
    defer result.deinit(allocator);
    // Blame filter now matches in pipe mode and compresses output.
    try std.testing.expect(result.stdout.len < blame_simple_fixture.len);
    try std.testing.expect(std.mem.find(u8, result.stdout, "b ") != null);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_blame large fixture: pipe-mode compresses blame output" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, blame_large_fixture);
    defer result.deinit(allocator);
    // Blame filter now matches in pipe mode and compresses output.
    // Output should be smaller than input.
    try std.testing.expect(result.stdout.len < blame_large_fixture.len);
    // Should contain the compact blame format markers ("b " prefix lines).
    try std.testing.expect(std.mem.find(u8, result.stdout, "b ") != null);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

// ---------------------------------------------------------------------------
// Unit 9: fail-open regression — non-git outer command passes through unchanged.
// Use `smll /bin/echo hello` as a deterministic non-git wrapper test.
// argv[1] = "/bin/echo" != "git" so the argv guard forces passthrough.
// ---------------------------------------------------------------------------

test "fail-open regression: non-git outer command (echo) passes through unchanged" {
    const allocator = std.testing.allocator;
    var result = try runSmllWrapper(allocator, &.{ "/bin/echo", "hello" });
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "broken pipe mid-stream returns non-zero exit without panic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{
        .argv = &.{exe_path},
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    child.stdout.?.close(io);
    child.stdout = null;

    const input = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(input);
    @memset(input, 'x');
    child.stdin.?.writeStreamingAll(io, input) catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    var stderr: std.ArrayList(u8) = .empty;
    defer stderr.deinit(allocator);
    var stderr_reader_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &stderr_reader_buf);
    stderr_reader.interface.appendRemainingUnlimited(allocator, &stderr) catch {};

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try std.testing.expect(code != 0),
        .signal => {},
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Columnar filter dispatch (default-lossy; SMLL_LOSSLESS=1 opts out)
// ---------------------------------------------------------------------------

fn runSmllWrapperEnv(
    allocator: std.mem.Allocator,
    bin_dir: []const u8,
    inner_argv: []const []const u8,
    extra_env: []const [2][]const u8,
) !RunResult {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(allocator);
    try full.append(allocator, exe_path);
    for (inner_argv) |a| try full.append(allocator, a);

    var env = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer env.deinit();
    const old_path = env.get("PATH") orelse "";
    const new_path = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ bin_dir, old_path });
    defer allocator.free(new_path);
    try env.put("PATH", new_path);
    for (extra_env) |kv| try env.put(kv[0], kv[1]);

    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = full.items,
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
        .environ_map = &env,
    });
    return .{ .stdout = result.stdout, .stderr = result.stderr, .term = result.term };
}

fn setupFakeTool(
    allocator: std.mem.Allocator,
    tmp_dir: std.Io.Dir,
    tool_name: []const u8,
    fixture: []const u8,
) ![]u8 {
    const io = std.testing.io;
    // Write fixture to file, then create a shim script that cats it.
    const fixture_name = try std.fmt.allocPrint(allocator, "{s}_fixture.txt", .{tool_name});
    defer allocator.free(fixture_name);
    try tmp_dir.writeFile(io, .{ .sub_path = fixture_name, .data = fixture });
    const fixture_path = try tmp_dir.realPathFileAlloc(io, fixture_name, allocator);
    defer allocator.free(fixture_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\nexec /bin/cat {s}\n",
        .{fixture_path},
    );
    defer allocator.free(script);
    try writeFakeScript(tmp_dir, tool_name, script);

    return try tmp_dir.realPathFileAlloc(io, ".", allocator);
}

test "columnar: kubectl compresses by default" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "kubectl", kubectl_pods_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"kubectl"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // v0.8+: kubectl_compact dispatches to compact pod-name summary filter.
    // Emits single line with k<count><state> prefix and pod names.
    try std.testing.expect(result.stdout.len < kubectl_pods_fixture.len);
    const savings_pct = (kubectl_pods_fixture.len - result.stdout.len) * 100 / kubectl_pods_fixture.len;
    try std.testing.expect(savings_pct >= 40);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "k"));
    try std.testing.expect(std.mem.find(u8, result.stdout, "api-server-6f8b9c4d7-x2k8m") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "redis-master-0") != null);
}

test "columnar: kubectl with SMLL_LOSSLESS=1 passes through unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "kubectl", kubectl_pods_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"kubectl"},
        &.{.{ "SMLL_LOSSLESS", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualSlices(u8, kubectl_pods_fixture, result.stdout);
}

test "columnar: gh pr list preserves preamble by default" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "gh", gh_pr_list_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"gh"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // First line is the banner — must appear verbatim.
    try std.testing.expect(std.mem.startsWith(
        u8,
        result.stdout,
        "Showing 8 of 8 open pull requests in example/repo\n",
    ));
    // Still smaller overall (padding collapse in the table region).
    try std.testing.expect(result.stdout.len < gh_pr_list_fixture.len);
}

test "columnar: docker with SMLL_COMPACT=0 is silently ignored (still compacts)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "docker", docker_ps_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"docker"},
        &.{.{ "SMLL_COMPACT", "0" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // v0.6: SMLL_COMPACT is silently ignored — default-lossy behavior stands.
    // Output must be smaller than fixture (columnar compression ran).
    try std.testing.expect(result.stdout.len < docker_ps_fixture.len);
}

test "columnar: docker with SMLL_COMPACT=1 is silently ignored (still compacts)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "docker", docker_ps_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"docker"},
        &.{.{ "SMLL_COMPACT", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // v0.6: SMLL_COMPACT=1 legacy opt-in is silently ignored — same default-lossy result.
    try std.testing.expect(result.stdout.len < docker_ps_fixture.len);
}

test "columnar: docker with SMLL_LOSSLESS=0 treated as unset (still compacts)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "docker", docker_ps_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"docker"},
        &.{.{ "SMLL_LOSSLESS", "0" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // SMLL_LOSSLESS=0 must behave as if unset (envFlagOn returns false) — default compacts.
    try std.testing.expect(result.stdout.len < docker_ps_fixture.len);
}

// ---------------------------------------------------------------------------
// v0.9 new filters — end-to-end smoke tests (default-lossy; SMLL_LOSSLESS=1 opts out).
// Each drives a fake tool shim on PATH, asserts the compressed output retains
// the actionable payload (failure markers / error codes / dedup counts /
// migration warnings).
// ---------------------------------------------------------------------------

test "smoke: jest keeps FAIL + ● titles, drops PASS (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "jest", jest_failing_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"jest"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len < jest_failing_fixture.len);
    // FAIL + failure title markers survive.
    try std.testing.expect(std.mem.find(u8, result.stdout, "FAIL  src/components/Button.test.tsx") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "● Button component › renders with uppercase label") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Test Suites:") != null);
    // Passing-file lines are dropped.
    try std.testing.expect(std.mem.find(u8, result.stdout, "PASS  src/utils/format.test.ts") == null);
}

test "smoke: tsc compresses errors to path:L:C TSnnnn (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "tsc", tsc_errors_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"tsc"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len < tsc_errors_fixture.len);
    // Locations-only transform: path:L:C TSnnnn survives; message text + carets drop.
    try std.testing.expect(std.mem.find(u8, result.stdout, "src/api/client.ts:42:5 TS2322") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "src/components/Button.tsx:15:7 TS2345") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Found 5 errors") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, " - error TS") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "~~~~~~") == null);
}

test "smoke: go test -v keeps --- FAIL + evidence, drops PASS (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "go", go_test_v_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "go", "test", "-v" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len < go_test_v_fixture.len);
    // Failure markers + their Errorf evidence survive.
    try std.testing.expect(std.mem.find(u8, result.stdout, "--- FAIL: TestDivide") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "--- FAIL: TestSqrt") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "divide(10, 0) panic expected") != null);
    // Passing run + per-test PASS lines are dropped.
    try std.testing.expect(std.mem.find(u8, result.stdout, "--- PASS: TestAdd") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "=== RUN   TestAdd") == null);
}

test "smoke: docker logs dedups consecutive identical lines (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "docker", docker_logs_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "docker", "logs", "myapp" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len < docker_logs_fixture.len);
    // Repeat marker appears; first occurrence of each unique payload survives.
    try std.testing.expect(std.mem.find(u8, result.stdout, "×") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "GET /health 200 2ms") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "failed to connect to redis: connection refused") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "shutting down gracefully") != null);
}

test "smoke: npm install keeps WARN + summary, drops notice (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "npm", npm_install_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "npm", "install" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len < npm_install_fixture.len);
    // Deprecation warnings + install summary survive.
    try std.testing.expect(std.mem.find(u8, result.stdout, "npm WARN deprecated lodash.isequal") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "added 847 packages") != null);
    // Upgrade-nag "npm notice" + funding prompts drop.
    try std.testing.expect(std.mem.find(u8, result.stdout, "npm notice") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "looking for funding") == null);
}

// ---------------------------------------------------------------------------
// v0.6 generic compactor — dispatch and threshold behavior.
// Generic compactor fires only when (a) no bespoke arm claimed the command
// and (b) stdout exceeds 64 KiB. Its distinctive marker is ASCII "  (x<N>)"
// appended to RLE-collapsed lines (bespoke docker_logs uses unicode "×").
// ---------------------------------------------------------------------------

fn buildLargeRepeatedPayload(
    allocator: std.mem.Allocator,
    line: []const u8,
    total_bytes: usize,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    while (buf.items.len < total_bytes) {
        try buf.appendSlice(allocator, line);
        try buf.append(allocator, '\n');
    }
    return buf.toOwnedSlice(allocator);
}

test "generic-compact: unknown command over 64 KiB triggers generic compactor (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 100 KiB of identical lines — unknown basename "xxunknownxx" has no
    // bespoke arm, so the generic compactor must fire and RLE them.
    const payload = try buildLargeRepeatedPayload(allocator, "agent-log entry ok", 100 * 1024);
    defer allocator.free(payload);

    const bin_dir = try setupFakeTool(allocator, tmp.dir, "xxunknownxx", payload);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"xxunknownxx"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Generic compactor ran: output is dramatically smaller + carries ×N marker.
    try std.testing.expect(result.stdout.len < payload.len / 10);
    try std.testing.expect(std.mem.find(u8, result.stdout, "\xc3\x97") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "agent-log entry ok") != null);
}

test "generic-compact: unknown command with SMLL_LOSSLESS=1 bypasses compactor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = try buildLargeRepeatedPayload(allocator, "agent-log entry ok", 100 * 1024);
    defer allocator.free(payload);

    const bin_dir = try setupFakeTool(allocator, tmp.dir, "xxunknownxx", payload);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"xxunknownxx"},
        &.{.{ "SMLL_LOSSLESS", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // SMLL_LOSSLESS=1 bypasses: byte-identical passthrough.
    try std.testing.expectEqualSlices(u8, payload, result.stdout);
}

test "generic-compact: unknown command under 8 KiB passes through unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 4 KiB of identical lines — below the 8 KiB threshold, so matches()
    // returns false and the pipeline is skipped even though content is RLE-ready.
    const payload = try buildLargeRepeatedPayload(allocator, "agent-log entry ok", 4 * 1024);
    defer allocator.free(payload);

    const bin_dir = try setupFakeTool(allocator, tmp.dir, "xxunknownxx", payload);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"xxunknownxx"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Below threshold → passthrough, byte-identical.
    try std.testing.expectEqualSlices(u8, payload, result.stdout);
}

test "generic-compact: known bespoke command (jest) does NOT reach generic compactor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 100 KiB of identical lines through a fake "jest" — bespoke arm must
    // claim the command. The key invariant: the generic ASCII (xN) marker
    // must NOT appear, which would mean generic fired. Whether the bespoke
    // filter shrinks this specific payload is not the point (jest.matches()
    // only triggers on Test-Suites banners), but the jest arm still claims
    // the command and returns before the generic compactor block runs.
    const payload = try buildLargeRepeatedPayload(
        allocator,
        "PASS  src/utils/format.test.ts (2.3s)",
        100 * 1024,
    );
    defer allocator.free(payload);

    const bin_dir = try setupFakeTool(allocator, tmp.dir, "jest", payload);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"jest"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Generic marker must not appear — that is the dispatch invariant.
    try std.testing.expect(std.mem.find(u8, result.stdout, "  (x") == null);
}

test "generic-compact: dispatch invariant — bespoke commands never reach generic compactor" {
    const allocator = std.testing.allocator;

    // Every (basename, argv) combination covered by a bespoke v0.4/v0.5/v0.6
    // dispatch arm in src/main.zig. If any of these leaks to the generic
    // compactor on a 100 KiB identical-line fixture, the ASCII (xN) marker
    // would appear (generic compactor's distinctive RLE output). Bare
    // `cargo` and `go` are intentionally NOT bespoke — they only route to
    // bespoke arms when argv[1] == "test", which is why this is keyed on
    // full argv rather than basename alone.
    const Invocation = struct { name: []const u8, argv: []const []const u8 };
    const cases = [_]Invocation{
        .{ .name = "rg", .argv = &.{"rg"} },
        .{ .name = "find", .argv = &.{"find"} },
        .{ .name = "tree", .argv = &.{"tree"} },
        .{ .name = "bun", .argv = &.{"bun"} },
        .{ .name = "pytest", .argv = &.{"pytest"} },
        .{ .name = "jest", .argv = &.{"jest"} },
        .{ .name = "vitest", .argv = &.{"vitest"} },
        .{ .name = "tsc", .argv = &.{"tsc"} },
        .{ .name = "cargo", .argv = &.{ "cargo", "test" } },
        .{ .name = "go", .argv = &.{ "go", "test" } },
        .{ .name = "curl", .argv = &.{ "curl", "-v" } },
        .{ .name = "make", .argv = &.{"make"} },
        .{ .name = "cargo", .argv = &.{ "cargo", "build" } },
        .{ .name = "go", .argv = &.{ "go", "build" } },
        .{ .name = "ls", .argv = &.{"ls"} },
        .{ .name = "du", .argv = &.{"du"} },
        .{ .name = "docker", .argv = &.{"docker"} },
        .{ .name = "kubectl", .argv = &.{"kubectl"} },
        .{ .name = "gh", .argv = &.{"gh"} },
        .{ .name = "ps", .argv = &.{"ps"} },
        .{ .name = "systemctl", .argv = &.{"systemctl"} },
        .{ .name = "lsof", .argv = &.{"lsof"} },
        .{ .name = "npm", .argv = &.{"npm"} },
        .{ .name = "pnpm", .argv = &.{"pnpm"} },
        .{ .name = "yarn", .argv = &.{"yarn"} },
        .{ .name = "brew", .argv = &.{"brew"} },
    };

    // Pick a payload that no bespoke filter will interpret as actionable.
    // 100 KiB of a generic log line, consecutive identical → trivially
    // RLE-collapsible IF generic ran. No "FAIL", no "error TS", no "---".
    const payload = try buildLargeRepeatedPayload(allocator, "log entry ok", 100 * 1024);
    defer allocator.free(payload);

    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const bin_dir = try setupFakeTool(allocator, tmp.dir, case.name, payload);
        defer allocator.free(bin_dir);

        var result = try runSmllWrapperEnv(allocator, bin_dir, case.argv, &.{});
        defer result.deinit(allocator);

        // Generic marker must not appear for any bespoke command.
        std.testing.expect(std.mem.find(u8, result.stdout, "  (x") == null) catch |err| {
            std.debug.print(
                "dispatch invariant violated: command='{s}' reached generic compactor\n",
                .{case.name},
            );
            return err;
        };
    }
}

// ---------------------------------------------------------------------------
// v0.6 find_compact — argv-keyed dispatch on `find -ls`.
// ---------------------------------------------------------------------------

const find_ls_fixture =
    "2055938    0 drwxr-xr-x   2 user staff   64 Apr 23 12:34 ./src\n" ++
    "2055939    8 -rw-r--r--   1 user staff  421 Apr 23 12:34 ./src/main.zig\n" ++
    "2055940    8 -rw-r--r--   1 user staff  123 Apr 23 12:34 ./src/filter.zig\n" ++
    "2055941    4 -rw-r--r--   1 user staff   45 Apr 23 12:34 ./README.md\n" ++
    "2055942    0 drwxr-xr-x   2 user staff   64 Apr 23 12:34 ./tests\n";

test "smoke: find -ls drops columnar metadata, keeps paths (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "find", find_ls_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "find", ".", "-ls" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len < find_ls_fixture.len);
    // 3 entries in "." (./src, ./README.md, ./tests) collapse to a count;
    // 2 entries in "./src" (./src/main.zig, ./src/filter.zig) survive individually.
    try std.testing.expect(std.mem.find(u8, result.stdout, "./src/main.zig") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "./src/filter.zig") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "./ (3 entries)") != null);
    // Metadata gone.
    try std.testing.expect(std.mem.find(u8, result.stdout, "user staff") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "drwxr-xr-x") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Apr 23") == null);
}

test "smoke: find without -ls does NOT route through find_compact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Vanilla find output — path-per-line, no metadata columns. Without
    // `-ls` in argv, find_compact is skipped. rg.apply (dirname RLE) may
    // compress the paths with its ':' sigil, but the filenames survive.
    const find_paths_fixture =
        "./src\n./src/main.zig\n./src/filter.zig\n./README.md\n";

    const bin_dir = try setupFakeTool(allocator, tmp.dir, "find", find_paths_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "find", "." }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Filenames survive (whether as full paths or rg-compressed form).
    try std.testing.expect(std.mem.find(u8, result.stdout, "main.zig") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "filter.zig") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "README.md") != null);
    // find_compact's directory marker (trailing `/` on dirs after 10
    // fields) must not appear — there are no 10-field lines here.
    try std.testing.expect(std.mem.find(u8, result.stdout, "user staff") == null);
}

test "smoke: find -ls with SMLL_LOSSLESS=1 passes through unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "find", find_ls_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{ "find", ".", "-ls" },
        &.{.{ "SMLL_LOSSLESS", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualSlices(u8, find_ls_fixture, result.stdout);
}

// ---------------------------------------------------------------------------
// v0.6 du_compact — size rounding + -s sort.
// ---------------------------------------------------------------------------

const du_fixture =
    "234M\t./src\n" ++
    "1.2G\t./vendor\n" ++
    "17K\t./tests\n" ++
    "5G\t./node_modules\n" ++
    "82M\t./build\n";

test "smoke: du rounds sizes to 2 sig figs (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "du", du_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "du", "-h", "." }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // 234M → 230M; paths preserved.
    try std.testing.expect(std.mem.find(u8, result.stdout, "230M\t./src") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "1.2G\t./vendor") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "17K\t./tests") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "82M\t./build") != null);
    // Order preserved without -s.
    const src_idx = std.mem.find(u8, result.stdout, "./src").?;
    const vendor_idx = std.mem.find(u8, result.stdout, "./vendor").?;
    try std.testing.expect(src_idx < vendor_idx);
}

test "smoke: du -sh sorts descending by byte size" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "du", du_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "du", "-sh", "." }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Largest first: 5G node_modules, then 1.2G vendor, then 230M src, 82M build, 17K tests.
    const nm_idx = std.mem.find(u8, result.stdout, "./node_modules").?;
    const vendor_idx = std.mem.find(u8, result.stdout, "./vendor").?;
    const src_idx = std.mem.find(u8, result.stdout, "./src").?;
    const tests_idx = std.mem.find(u8, result.stdout, "./tests").?;
    try std.testing.expect(nm_idx < vendor_idx);
    try std.testing.expect(vendor_idx < src_idx);
    try std.testing.expect(src_idx < tests_idx);
}

test "smoke: du with SMLL_LOSSLESS=1 passes through unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "du", du_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{ "du", "-sh", "." },
        &.{.{ "SMLL_LOSSLESS", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualSlices(u8, du_fixture, result.stdout);
}

// ---------------------------------------------------------------------------
// v0.6 curl_compact — two-stream (stdout+stderr) verbose-flag dispatch.
// ---------------------------------------------------------------------------

const curl_small_stderr = @embedFile("fixture_curl_v_example_stderr");
const curl_small_stdout = @embedFile("fixture_curl_v_example_stdout");
const curl_large_stderr = @embedFile("fixture_curl_vvv_example_stderr");
const curl_large_stdout = @embedFile("fixture_curl_vvv_example_stdout");

/// Fake `curl` that emits stdout_fixture on stdout and stderr_fixture on
/// stderr — mirrors curl's two-stream shape (body on stdout, trace on stderr).
fn setupFakeCurl(
    allocator: std.mem.Allocator,
    tmp_dir: std.Io.Dir,
    stdout_fixture: []const u8,
    stderr_fixture: []const u8,
) ![]u8 {
    const io = std.testing.io;
    try tmp_dir.writeFile(io, .{ .sub_path = "curl_stdout.txt", .data = stdout_fixture });
    try tmp_dir.writeFile(io, .{ .sub_path = "curl_stderr.txt", .data = stderr_fixture });
    const stdout_path = try tmp_dir.realPathFileAlloc(io, "curl_stdout.txt", allocator);
    defer allocator.free(stdout_path);
    const stderr_path = try tmp_dir.realPathFileAlloc(io, "curl_stderr.txt", allocator);
    defer allocator.free(stderr_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n/bin/cat {s}\n/bin/cat {s} >&2\n",
        .{ stdout_path, stderr_path },
    );
    defer allocator.free(script);
    try writeFakeScript(tmp_dir, "curl", script);

    return try tmp_dir.realPathFileAlloc(io, ".", allocator);
}

test "smoke: curl -v drops TLS chatter, keeps headers + body (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeCurl(allocator, tmp.dir, curl_small_stdout, curl_small_stderr);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "curl", "-v", "https://example.com" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Kept
    try std.testing.expect(std.mem.find(u8, result.stdout, "< HTTP/2 200") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "> GET / HTTP/2") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Example Domain") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "--- headers ---") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "--- body ---") != null);
    // Dropped
    try std.testing.expect(std.mem.find(u8, result.stdout, "TLSv1.3") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "subject:") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "issuer:") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "SSL certificate verify") == null);
}

test "smoke: curl large -vvv fixture reduces by ≥ 60%" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeCurl(allocator, tmp.dir, curl_large_stdout, curl_large_stderr);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "curl", "-vvv", "https://api.example.com" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const raw_total = curl_large_stderr.len + curl_large_stdout.len;
    const reduction = (raw_total - result.stdout.len) * 100 / raw_total;
    try std.testing.expect(reduction >= 60);
    // No cert material survives.
    try std.testing.expect(std.mem.find(u8, result.stdout, "BEGIN CERTIFICATE") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "MIIFaz") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "subject:") == null);
    // First 5 requests show full status; rest are summarized.
    const int_status_count = std.mem.count(u8, result.stdout, "< HTTP/2 200");
    try std.testing.expect(int_status_count >= 1 and int_status_count <= 5);
}

test "smoke: curl without -v passes through (no dispatch)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeCurl(allocator, tmp.dir, curl_small_stdout, curl_small_stderr);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "curl", "https://example.com" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // No headers/body separator — dispatch arm didn't engage.
    try std.testing.expect(std.mem.find(u8, result.stdout, "--- headers ---") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "--- body ---") == null);
    // Body is on stdout verbatim.
    try std.testing.expect(std.mem.find(u8, result.stdout, "Example Domain") != null);
}

test "smoke: curl -v with SMLL_LOSSLESS=1 passes both streams through byte-identical" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeCurl(allocator, tmp.dir, curl_small_stdout, curl_small_stderr);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{ "curl", "-v", "https://example.com" },
        &.{.{ "SMLL_LOSSLESS", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualSlices(u8, curl_small_stdout, result.stdout);
    try std.testing.expectEqualSlices(u8, curl_small_stderr, result.stderr);
}

// ---------------------------------------------------------------------------
// v0.6 build_compact — shared filter for `cargo build`, `make`, `go build`.
// cargo/go emit progress on stderr by convention; make splits across both.
// setupFakeBuild supports routing a fixture to either stream so each tool's
// real shape is preserved.
// ---------------------------------------------------------------------------

const cargo_build_fixture = @embedFile("fixture_cargo_build");
const cargo_build_large = @embedFile("fixture_cargo_build_large");
const make_build_fixture = @embedFile("fixture_make_build");
const make_build_large = @embedFile("fixture_make_build_large");
const go_build_fixture = @embedFile("fixture_go_build");
const go_build_large = @embedFile("fixture_go_build_large");

/// Fake build tool that emits a fixture on the given stream (stdout or stderr).
/// cargo/go usually print progress to stderr; make usually prints to stdout.
fn setupFakeBuild(
    allocator: std.mem.Allocator,
    tmp_dir: std.Io.Dir,
    tool_name: []const u8,
    fixture: []const u8,
    on_stderr: bool,
) ![]u8 {
    const io = std.testing.io;
    const fixture_name = try std.fmt.allocPrint(allocator, "{s}_build_fixture.txt", .{tool_name});
    defer allocator.free(fixture_name);
    try tmp_dir.writeFile(io, .{ .sub_path = fixture_name, .data = fixture });
    const fixture_path = try tmp_dir.realPathFileAlloc(io, fixture_name, allocator);
    defer allocator.free(fixture_path);

    const redirect = if (on_stderr) " >&2" else "";
    const script = try std.fmt.allocPrint(
        allocator,
        "#!/bin/sh\n/bin/cat {s}{s}\n",
        .{ fixture_path, redirect },
    );
    defer allocator.free(script);
    try writeFakeScript(tmp_dir, tool_name, script);

    return try tmp_dir.realPathFileAlloc(io, ".", allocator);
}

test "smoke: cargo build collapses Compiling lines on stderr (default)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeBuild(allocator, tmp.dir, "cargo", cargo_build_fixture, true);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "cargo", "build" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Progress collapsed, summary emitted.
    try std.testing.expect(std.mem.find(u8, result.stdout, "Compiled 7 (cargo)") != null);
    // No raw "   Compiling " lines survive.
    try std.testing.expect(std.mem.find(u8, result.stdout, "   Compiling ") == null);
    // Warning block preserved verbatim.
    try std.testing.expect(std.mem.find(u8, result.stdout, "warning: unused variable: `tmp`") != null);
    // Finished line preserved.
    try std.testing.expect(std.mem.find(u8, result.stdout, "Finished dev") != null);
}

test "smoke: cargo build large fixture reduces by ≥ 60%" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeBuild(allocator, tmp.dir, "cargo", cargo_build_large, true);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "cargo", "build" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const reduction = (cargo_build_large.len - result.stdout.len) * 100 / cargo_build_large.len;
    try std.testing.expect(reduction >= 60);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Compiled 500 (cargo)") != null);
    // Warnings survived.
    try std.testing.expect(std.mem.find(u8, result.stdout, "warning: unused import") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "warning: variable does not need to be mutable") != null);
}

test "smoke: make collapses cc/LINK lines on stdout" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeBuild(allocator, tmp.dir, "make", make_build_fixture, false);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"make"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // 4 cc lines + 1 LINK line = 5 progress.
    try std.testing.expect(std.mem.find(u8, result.stdout, "Compiled 5 (make)") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "cc -c -Wall") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "LINK build/app") == null);
    // Warning survived.
    try std.testing.expect(std.mem.find(u8, result.stdout, "warning: unused variable 'tmp'") != null);
}

test "smoke: make large fixture reduces by ≥ 60%" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeBuild(allocator, tmp.dir, "make", make_build_large, false);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"make"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const reduction = (make_build_large.len - result.stdout.len) * 100 / make_build_large.len;
    try std.testing.expect(reduction >= 60);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Compiled 501 (make)") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "warning: unused variable 'tmp'") != null);
}

test "smoke: go build collapses `go build:` lines on stderr" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeBuild(allocator, tmp.dir, "go", go_build_fixture, true);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "go", "build" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Compiled 6 (go)") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "go build: compiling") == null);
    // The "declared and not used" line has no error:/warning: prefix, so it
    // classifies as .other and passes through verbatim.
    try std.testing.expect(std.mem.find(u8, result.stdout, "declared and not used: claims") != null);
}

test "smoke: go build large fixture reduces by ≥ 60%" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeBuild(allocator, tmp.dir, "go", go_build_large, true);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "go", "build" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    const reduction = (go_build_large.len - result.stdout.len) * 100 / go_build_large.len;
    try std.testing.expect(reduction >= 60);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Compiled 500 (go)") != null);
    // Errors survived.
    try std.testing.expect(std.mem.find(u8, result.stdout, "error: declared and not used") != null);
}

test "smoke: cargo build with SMLL_LOSSLESS=1 passes through byte-identical" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeBuild(allocator, tmp.dir, "cargo", cargo_build_fixture, true);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{ "cargo", "build" },
        &.{.{ "SMLL_LOSSLESS", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Fixture was routed to stderr, so stdout is empty in lossless mode.
    try std.testing.expectEqualSlices(u8, "", result.stdout);
    try std.testing.expectEqualSlices(u8, cargo_build_fixture, result.stderr);
}

test "smoke: cargo without build subcommand doesn't dispatch to build_compact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeBuild(allocator, tmp.dir, "cargo", cargo_build_fixture, true);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{ "cargo", "check" }, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // No "Compiled" summary line — build arm didn't engage.
    try std.testing.expect(std.mem.find(u8, result.stdout, "Compiled ") == null);
}

// ---------------------------------------------------------------------------
// git grep integration tests
// ---------------------------------------------------------------------------

test "git grep -n: path-prefix RLE compresses repeated paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(bin_path);

    const fixture =
        "src/main.zig:7:pub fn matches(input: []const u8) bool {\n" ++
        "src/main.zig:12:pub fn apply(allocator: Allocator, stdout: []const u8, writer: *Writer) !void {\n" ++
        "src/main.zig:21:pub fn run(\n" ++
        "src/util.zig:4:pub fn isHex40(s: []const u8) bool {\n" ++
        "src/util.zig:12:pub fn sha7(full: []const u8) [7]u8 {\n";

    try writeFakeScript(tmp.dir, "git",
        \\#!/bin/sh
        \\printf 'src/main.zig:7:pub fn matches(input: []const u8) bool {\nsrc/main.zig:12:pub fn apply(allocator: Allocator, stdout: []const u8, writer: *Writer) !void {\nsrc/main.zig:21:pub fn run(\nsrc/util.zig:4:pub fn isHex40(s: []const u8) bool {\nsrc/util.zig:12:pub fn sha7(full: []const u8) [7]u8 {\n'
    );

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "git", "grep", "-n", "pub fn" });
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Compressed: path appears once per file, rest elided.
    try std.testing.expect(std.mem.count(u8, result.stdout, "src/main.zig") == 1);
    try std.testing.expect(std.mem.count(u8, result.stdout, "src/util.zig") == 1);
    // Line numbers still present.
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, ":7:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, ":12:"));
    // Output is smaller than input.
    try std.testing.expect(result.stdout.len < fixture.len);
}

test "git grep without -n: passthrough (no :line: pattern)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(bin_path);

    // git grep without -n: path:content, no line numbers.
    const fixture = "src/main.zig:pub fn matches\nsrc/util.zig:pub fn sha7\n";
    try writeFakeScript(tmp.dir, "git",
        \\#!/bin/sh
        \\printf 'src/main.zig:pub fn matches\nsrc/util.zig:pub fn sha7\n'
    );

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "git", "grep", "pub fn" });
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // matchesPattern returns false for path:content (no :digit:), passthrough.
    try std.testing.expectEqualSlices(u8, fixture, result.stdout);
}

test "git grep -n SMLL_LOSSLESS=1: passthrough" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(bin_path);

    const fixture = "src/main.zig:7:pub fn matches\nsrc/util.zig:4:pub fn isHex40\n";
    try writeFakeScript(tmp.dir, "git",
        \\#!/bin/sh
        \\printf 'src/main.zig:7:pub fn matches\nsrc/util.zig:4:pub fn isHex40\n'
    );

    var result = try runSmllWrapperEnv(allocator, bin_path, &.{ "git", "grep", "-n", "pub fn" }, &.{.{ "SMLL_LOSSLESS", "1" }});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualSlices(u8, fixture, result.stdout);
}

// ---------------------------------------------------------------------------
// git diff summary-mode passthrough tests
// ---------------------------------------------------------------------------

test "git diff --stat: passes through verbatim (not corrupted)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(bin_path);

    // Real git diff --stat output: all file lines start with a space.
    const fixture =
        " src/main.zig         | 10 +++++-----\n" ++
        " src/filters/rg.zig   |  5 +++++\n" ++
        " 2 files changed, 15 insertions(+), 5 deletions(-)\n";

    try writeFakeScript(tmp.dir, "git",
        \\#!/bin/sh
        \\printf ' src/main.zig         | 10 +++++-----\n src/filters/rg.zig   |  5 +++++\n 2 files changed, 15 insertions(+), 5 deletions(-)\n'
    );

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "git", "diff", "--stat" });
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // All file stat lines must be preserved — the old bug silently dropped them.
    try std.testing.expectEqualSlices(u8, fixture, result.stdout);
}

test "git diff --name-only: passes through verbatim" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(bin_path);

    const fixture = "src/main.zig\nsrc/filters/rg.zig\n";

    try writeFakeScript(tmp.dir, "git",
        \\#!/bin/sh
        \\printf 'src/main.zig\nsrc/filters/rg.zig\n'
    );

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "git", "diff", "--name-only" });
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualSlices(u8, fixture, result.stdout);
}

test "git diff (full): still compressed when no summary flag" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(bin_path);

    const fixture =
        "diff --git a/src/main.zig b/src/main.zig\n" ++
        "index abc1234..def5678 100644\n" ++
        "--- a/src/main.zig\n" ++
        "+++ b/src/main.zig\n" ++
        "@@ -7,4 +7,5 @@ pub fn main() void {\n" ++
        " const x = 1;\n" ++
        "+const y = 2;\n" ++
        " return;\n" ++
        "}\n";
    _ = fixture; // kept for documentation; smll compresses it

    try writeFakeScript(tmp.dir, "git",
        \\#!/bin/sh
        \\printf 'diff --git a/src/main.zig b/src/main.zig\nindex abc1234..def5678 100644\n--- a/src/main.zig\n+++ b/src/main.zig\n@@ -7,4 +7,5 @@ pub fn main() void {\n const x = 1;\n+const y = 2;\n return;\n}\n'
    );

    var result = try runSmllWrapperFakeGit(allocator, bin_path, &.{ "git", "diff" });
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // Compressed: "d src/main.zig" header, "index" line dropped.
    try std.testing.expect(std.mem.find(u8, result.stdout, "d src/main.zig") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "index abc1234") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "+const y = 2;") != null);
}
