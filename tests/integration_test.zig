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
// columnar fixtures (opt-in SMLL_COMPACT dispatch)
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

test "non-git input passes through unchanged (fail-open)" {
    const allocator = std.testing.allocator;
    const ls_like = "total 48\ndrwxr-xr-x  10 user  staff  320 Apr 18 07:00 .\n-rw-r--r--   1 user  staff  512 Apr 18 07:00 README\n";
    var result = try runSmll(allocator, ls_like);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings(ls_like, result.stdout);
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

test "large status fixture: v0.4 format — branch sigil, A sigils for staged new files" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, status_large_fixture);
    defer result.deinit(allocator);
    // Branch line
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "# main\n"));
    // Staged new files use A sigil
    try std.testing.expect(std.mem.find(u8, result.stdout, "A src/components/comp_01.rs\n") != null);
    // Unstaged modified uses M sigil
    try std.testing.expect(std.mem.find(u8, result.stdout, "M src/mod_01.rs\n") != null);
    // No section headers
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
    try std.testing.expect(std.mem.find(u8, result.stdout, "@1|1,3\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "+line two") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "diff --git") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "index ") == null);
}

test "diff rename+modify fixture: v0.4 format — d rename sigil, @ sigil" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, diff_rename_modify_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, result.stdout, "d old.txt -> new.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "@1,3|1,4\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "rename from") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "similarity index") == null);
}

// ---------------------------------------------------------------------------
// v0.4 format assertions for log fixtures.
// ---------------------------------------------------------------------------

test "log linear fixture: v0.4 format — c sigil, : sigil, no commit/Author/Date labels" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, log_linear_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, result.stdout, "c f0ad49e 2026-04-18 Alice Anderson\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, ": fix: third line\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "commit ") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Author:") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Date:") == null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "@example.com") == null);
}

test "log merge fixture: v0.4 format — p sigil for merge parents" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, log_merge_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, result.stdout, "c 012aa35 2026-04-18 Alice Anderson\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "p 50c52b3 cb42c80\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "Merge:") == null);
}

// ---------------------------------------------------------------------------
// v0.4 format assertions for show fixtures.
// ---------------------------------------------------------------------------

test "show simple fixture: v0.4 format — c sigil + d sigil, no diff --git or Author/Date" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, show_simple_fixture);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.find(u8, result.stdout, "c 95cbeda 2026-04-18 Alice Anderson\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, ": feat: add a.txt with one line\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "d a.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "@0,0|1\n") != null);
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

test "git_blame small fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, blame_simple_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, blame_simple_fixture, result.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "git_blame large fixture: pipe-mode passes through unchanged (argv-only filter)" {
    const allocator = std.testing.allocator;
    var result = try runSmll(allocator, blame_large_fixture);
    defer result.deinit(allocator);
    try std.testing.expectEqualSlices(u8, blame_large_fixture, result.stdout);
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
// Columnar filter dispatch (SMLL_COMPACT opt-in)
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

test "columnar: kubectl with SMLL_COMPACT=1 compresses" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "kubectl", kubectl_pods_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"kubectl"},
        &.{.{ "SMLL_COMPACT", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    // v0.8: kubectl_compact dispatches to dedicated pod-name summary filter.
    // Emits single line: "[k8s] N running: name1 name2 ...". Pod names preserved.
    try std.testing.expect(result.stdout.len < kubectl_pods_fixture.len);
    const savings_pct = (kubectl_pods_fixture.len - result.stdout.len) * 100 / kubectl_pods_fixture.len;
    try std.testing.expect(savings_pct >= 40);
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "[k8s] "));
    try std.testing.expect(std.mem.find(u8, result.stdout, "api-server-6f8b9c4d7-x2k8m") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "redis-master-0") != null);
}

test "columnar: kubectl without SMLL_COMPACT passes through unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "kubectl", kubectl_pods_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(allocator, bin_dir, &.{"kubectl"}, &.{});
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualSlices(u8, kubectl_pods_fixture, result.stdout);
}

test "columnar: gh pr list with SMLL_COMPACT=1 preserves preamble" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "gh", gh_pr_list_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"gh"},
        &.{.{ "SMLL_COMPACT", "1" }},
    );
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

test "columnar: docker SMLL_COMPACT=0 stays passthrough" {
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
    // SMLL_COMPACT=0 → gate is closed, byte-identical passthrough required.
    try std.testing.expectEqualSlices(u8, docker_ps_fixture, result.stdout);
}

// ---------------------------------------------------------------------------
// v0.9 new filters — end-to-end smoke tests (SMLL_COMPACT=1 wrapper mode).
// Each drives a fake tool shim on PATH, asserts the compressed output retains
// the actionable payload (failure markers / error codes / dedup counts /
// migration warnings), and confirms gate-closed runs fall back to passthrough.
// ---------------------------------------------------------------------------

test "smoke: jest SMLL_COMPACT=1 keeps FAIL + ● titles, drops PASS" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "jest", jest_failing_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"jest"},
        &.{.{ "SMLL_COMPACT", "1" }},
    );
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

test "smoke: tsc SMLL_COMPACT=1 compresses errors to path:L:C TSnnnn" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "tsc", tsc_errors_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{"tsc"},
        &.{.{ "SMLL_COMPACT", "1" }},
    );
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

test "smoke: go test -v SMLL_COMPACT=1 keeps --- FAIL + evidence, drops PASS" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "go", go_test_v_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{ "go", "test", "-v" },
        &.{.{ "SMLL_COMPACT", "1" }},
    );
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

test "smoke: docker logs SMLL_COMPACT=1 dedups consecutive identical lines" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "docker", docker_logs_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{ "docker", "logs", "myapp" },
        &.{.{ "SMLL_COMPACT", "1" }},
    );
    defer result.deinit(allocator);

    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(result.stdout.len < docker_logs_fixture.len);
    // Repeat marker appears; first occurrence of each unique payload survives.
    try std.testing.expect(std.mem.find(u8, result.stdout, "(×") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "GET /health 200 2ms") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "failed to connect to redis: connection refused") != null);
    try std.testing.expect(std.mem.find(u8, result.stdout, "shutting down gracefully") != null);
}

test "smoke: npm install SMLL_COMPACT=1 keeps WARN + summary, drops notice" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bin_dir = try setupFakeTool(allocator, tmp.dir, "npm", npm_install_fixture);
    defer allocator.free(bin_dir);

    var result = try runSmllWrapperEnv(
        allocator,
        bin_dir,
        &.{ "npm", "install" },
        &.{.{ "SMLL_COMPACT", "1" }},
    );
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
