const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const util_mod = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .optimize = optimize,
    });

    const git_status_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_status.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_status_mod.addImport("util", util_mod);
    git_status_mod.addAnonymousImport("fixture_git_status_dirty", .{
        .root_source_file = b.path("tests/fixtures/git_status_dirty.txt"),
    });
    git_status_mod.addAnonymousImport("fixture_git_status_clean", .{
        .root_source_file = b.path("tests/fixtures/git_status_clean.txt"),
    });
    git_status_mod.addAnonymousImport("fixture_git_status_conflict", .{
        .root_source_file = b.path("tests/fixtures/git_status_conflict.txt"),
    });

    const git_diff_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_diff.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_diff_mod.addImport("util", util_mod);
    git_diff_mod.addAnonymousImport("fixture_git_diff_simple", .{
        .root_source_file = b.path("tests/fixtures/git_diff_simple.txt"),
    });
    git_diff_mod.addAnonymousImport("fixture_git_diff_multi", .{
        .root_source_file = b.path("tests/fixtures/git_diff_multi.txt"),
    });
    git_diff_mod.addAnonymousImport("fixture_git_diff_rename", .{
        .root_source_file = b.path("tests/fixtures/git_diff_rename.txt"),
    });
    git_diff_mod.addAnonymousImport("fixture_git_diff_rename_modify", .{
        .root_source_file = b.path("tests/fixtures/git_diff_rename_modify.txt"),
    });

    const git_log_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_log.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_log_mod.addImport("util", util_mod);
    git_log_mod.addAnonymousImport("fixture_git_log_linear", .{
        .root_source_file = b.path("tests/fixtures/git_log_linear.txt"),
    });
    git_log_mod.addAnonymousImport("fixture_git_log_merge", .{
        .root_source_file = b.path("tests/fixtures/git_log_merge.txt"),
    });

    const git_show_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_show.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_show_mod.addImport("util", util_mod);
    git_show_mod.addImport("git_log", git_log_mod);
    git_show_mod.addImport("git_diff", git_diff_mod);
    git_show_mod.addAnonymousImport("fixture_git_show_simple", .{
        .root_source_file = b.path("tests/fixtures/git_show_simple.txt"),
    });
    git_show_mod.addAnonymousImport("fixture_git_show_body", .{
        .root_source_file = b.path("tests/fixtures/git_show_body.txt"),
    });

    const git_add_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_add.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_add_mod.addImport("util", util_mod);
    git_add_mod.addAnonymousImport("fixture_git_add_error_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_add_error.stdout.txt"),
    });
    git_add_mod.addAnonymousImport("fixture_git_add_error_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_add_error.stderr.txt"),
    });

    const git_commit_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_commit.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_commit_mod.addImport("util", util_mod);
    git_commit_mod.addAnonymousImport("fixture_git_commit_simple", .{
        .root_source_file = b.path("tests/fixtures/git_commit_simple.txt"),
    });
    git_commit_mod.addAnonymousImport("fixture_git_commit_multifile", .{
        .root_source_file = b.path("tests/fixtures/git_commit_multifile.txt"),
    });
    git_commit_mod.addAnonymousImport("fixture_git_commit_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_commit.txt"),
    });

    const git_push_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_push.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_push_mod.addImport("util", util_mod);
    git_push_mod.addAnonymousImport("fixture_git_push_simple_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_push_simple.stdout.txt"),
    });
    git_push_mod.addAnonymousImport("fixture_git_push_simple_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_push_simple.stderr.txt"),
    });
    git_push_mod.addAnonymousImport("fixture_git_push_large_stdout", .{
        .root_source_file = b.path("tests/fixtures/large/git_push.stdout.txt"),
    });
    git_push_mod.addAnonymousImport("fixture_git_push_large_stderr", .{
        .root_source_file = b.path("tests/fixtures/large/git_push.stderr.txt"),
    });

    const git_pull_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_pull.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_pull_mod.addImport("util", util_mod);
    git_pull_mod.addAnonymousImport("fixture_git_pull_ff_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_pull_ff.stdout.txt"),
    });
    git_pull_mod.addAnonymousImport("fixture_git_pull_ff_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_pull_ff.stderr.txt"),
    });
    git_pull_mod.addAnonymousImport("fixture_git_pull_uptodate_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_pull_uptodate.stdout.txt"),
    });
    git_pull_mod.addAnonymousImport("fixture_git_pull_uptodate_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_pull_uptodate.stderr.txt"),
    });

    const git_fetch_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_fetch.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_fetch_mod.addImport("util", util_mod);
    git_fetch_mod.addAnonymousImport("fixture_git_fetch_simple_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_fetch_simple.stdout.txt"),
    });
    git_fetch_mod.addAnonymousImport("fixture_git_fetch_simple_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_fetch_simple.stderr.txt"),
    });

    const git_merge_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_merge.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_merge_mod.addImport("util", util_mod);
    git_merge_mod.addAnonymousImport("fixture_git_merge_ff", .{
        .root_source_file = b.path("tests/fixtures/git_merge_ff.txt"),
    });
    git_merge_mod.addAnonymousImport("fixture_git_merge_commit", .{
        .root_source_file = b.path("tests/fixtures/git_merge_commit.txt"),
    });
    git_merge_mod.addAnonymousImport("fixture_git_merge_conflict_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_merge_conflict.stdout.txt"),
    });
    git_merge_mod.addAnonymousImport("fixture_git_merge_conflict_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_merge_conflict.stderr.txt"),
    });
    git_merge_mod.addAnonymousImport("fixture_git_merge_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_merge.txt"),
    });

    const git_rebase_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_rebase.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_rebase_mod.addImport("util", util_mod);
    git_rebase_mod.addAnonymousImport("fixture_git_rebase_simple", .{
        .root_source_file = b.path("tests/fixtures/git_rebase_simple.txt"),
    });
    git_rebase_mod.addAnonymousImport("fixture_git_rebase_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_rebase.txt"),
    });

    const git_checkout_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_checkout.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_checkout_mod.addImport("util", util_mod);
    git_checkout_mod.addAnonymousImport("fixture_git_checkout_switch_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_checkout_switch.stdout.txt"),
    });
    git_checkout_mod.addAnonymousImport("fixture_git_checkout_switch_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_checkout_switch.stderr.txt"),
    });

    const git_branch_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_branch.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_branch_mod.addAnonymousImport("fixture_git_branch_list", .{
        .root_source_file = b.path("tests/fixtures/git_branch_list.txt"),
    });

    exe_mod.addImport("git_status", git_status_mod);
    exe_mod.addImport("git_diff", git_diff_mod);
    exe_mod.addImport("git_log", git_log_mod);
    exe_mod.addImport("git_show", git_show_mod);
    exe_mod.addImport("git_add", git_add_mod);
    exe_mod.addImport("git_commit", git_commit_mod);
    exe_mod.addImport("git_push", git_push_mod);
    exe_mod.addImport("git_pull", git_pull_mod);
    exe_mod.addImport("git_fetch", git_fetch_mod);
    exe_mod.addImport("git_merge", git_merge_mod);
    exe_mod.addImport("git_rebase", git_rebase_mod);
    exe_mod.addImport("git_checkout", git_checkout_mod);
    exe_mod.addImport("git_branch", git_branch_mod);

    const exe = b.addExecutable(.{
        .name = "smll",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run smll");
    run_step.dependOn(&run_cmd.step);

    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    release_mod.addImport("git_status", git_status_mod);
    release_mod.addImport("git_diff", git_diff_mod);
    release_mod.addImport("git_log", git_log_mod);
    release_mod.addImport("git_show", git_show_mod);
    release_mod.addImport("git_add", git_add_mod);
    release_mod.addImport("git_commit", git_commit_mod);
    release_mod.addImport("git_push", git_push_mod);
    release_mod.addImport("git_pull", git_pull_mod);
    release_mod.addImport("git_fetch", git_fetch_mod);
    release_mod.addImport("git_merge", git_merge_mod);
    release_mod.addImport("git_rebase", git_rebase_mod);
    release_mod.addImport("git_checkout", git_checkout_mod);
    release_mod.addImport("git_branch", git_branch_mod);

    const release_exe = b.addExecutable(.{
        .name = "smll",
        .root_module = release_mod,
    });
    const install_release = b.addInstallArtifact(release_exe, .{
        .dest_dir = .{ .override = .{ .custom = "release" } },
    });
    const release_step = b.step("release", "Build stripped ReleaseSmall binary into zig-out/release/");
    release_step.dependOn(&install_release.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const util_tests = b.addTest(.{ .root_module = util_mod });
    const run_util_tests = b.addRunArtifact(util_tests);

    const git_status_tests = b.addTest(.{ .root_module = git_status_mod });
    const run_git_status_tests = b.addRunArtifact(git_status_tests);

    const git_diff_tests = b.addTest(.{ .root_module = git_diff_mod });
    const run_git_diff_tests = b.addRunArtifact(git_diff_tests);

    const git_log_tests = b.addTest(.{ .root_module = git_log_mod });
    const run_git_log_tests = b.addRunArtifact(git_log_tests);

    const git_show_tests = b.addTest(.{ .root_module = git_show_mod });
    const run_git_show_tests = b.addRunArtifact(git_show_tests);

    const git_add_tests = b.addTest(.{ .root_module = git_add_mod });
    const run_git_add_tests = b.addRunArtifact(git_add_tests);

    const git_commit_tests = b.addTest(.{ .root_module = git_commit_mod });
    const run_git_commit_tests = b.addRunArtifact(git_commit_tests);

    const git_push_tests = b.addTest(.{ .root_module = git_push_mod });
    const run_git_push_tests = b.addRunArtifact(git_push_tests);

    const git_pull_tests = b.addTest(.{ .root_module = git_pull_mod });
    const run_git_pull_tests = b.addRunArtifact(git_pull_tests);

    const git_fetch_tests = b.addTest(.{ .root_module = git_fetch_mod });
    const run_git_fetch_tests = b.addRunArtifact(git_fetch_tests);

    const git_merge_tests = b.addTest(.{ .root_module = git_merge_mod });
    const run_git_merge_tests = b.addRunArtifact(git_merge_tests);

    const git_rebase_tests = b.addTest(.{ .root_module = git_rebase_mod });
    const run_git_rebase_tests = b.addRunArtifact(git_rebase_tests);

    const git_checkout_tests = b.addTest(.{ .root_module = git_checkout_mod });
    const run_git_checkout_tests = b.addRunArtifact(git_checkout_tests);

    const git_branch_tests = b.addTest(.{ .root_module = git_branch_mod });
    const run_git_branch_tests = b.addRunArtifact(git_branch_tests);

    const opts = b.addOptions();
    opts.addOptionPath("smll_exe_path", exe.getEmittedBin());

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_mod.addOptions("build_options", opts);
    integration_mod.addImport("git_status", git_status_mod);
    integration_mod.addImport("git_diff", git_diff_mod);
    integration_mod.addImport("git_log", git_log_mod);
    integration_mod.addImport("git_show", git_show_mod);
    integration_mod.addAnonymousImport("fixture_git_status_dirty", .{
        .root_source_file = b.path("tests/fixtures/git_status_dirty.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_status_clean", .{
        .root_source_file = b.path("tests/fixtures/git_status_clean.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_status_conflict", .{
        .root_source_file = b.path("tests/fixtures/git_status_conflict.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_diff_simple", .{
        .root_source_file = b.path("tests/fixtures/git_diff_simple.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_diff_multi", .{
        .root_source_file = b.path("tests/fixtures/git_diff_multi.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_diff_rename", .{
        .root_source_file = b.path("tests/fixtures/git_diff_rename.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_diff_rename_modify", .{
        .root_source_file = b.path("tests/fixtures/git_diff_rename_modify.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_log_linear", .{
        .root_source_file = b.path("tests/fixtures/git_log_linear.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_log_merge", .{
        .root_source_file = b.path("tests/fixtures/git_log_merge.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_show_simple", .{
        .root_source_file = b.path("tests/fixtures/git_show_simple.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_show_body", .{
        .root_source_file = b.path("tests/fixtures/git_show_body.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_status_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_status.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_diff_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_diff.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_log_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_log.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_show_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_show.txt"),
    });

    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(&exe.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_util_tests.step);
    test_step.dependOn(&run_git_status_tests.step);
    test_step.dependOn(&run_git_diff_tests.step);
    test_step.dependOn(&run_git_log_tests.step);
    test_step.dependOn(&run_git_show_tests.step);
    test_step.dependOn(&run_git_add_tests.step);
    test_step.dependOn(&run_git_commit_tests.step);
    test_step.dependOn(&run_git_push_tests.step);
    test_step.dependOn(&run_git_pull_tests.step);
    test_step.dependOn(&run_git_fetch_tests.step);
    test_step.dependOn(&run_git_merge_tests.step);
    test_step.dependOn(&run_git_rebase_tests.step);
    test_step.dependOn(&run_git_checkout_tests.step);
    test_step.dependOn(&run_git_branch_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
