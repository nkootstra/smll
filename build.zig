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
        .optimize = .ReleaseSmall,
    });

    const git_status_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_status.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
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
        .optimize = .ReleaseSmall,
    });
    git_branch_mod.addAnonymousImport("fixture_git_branch_list", .{
        .root_source_file = b.path("tests/fixtures/git_branch_list.txt"),
    });

    const git_stash_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_stash.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    git_stash_mod.addImport("util", util_mod);
    git_stash_mod.addAnonymousImport("fixture_git_stash_save", .{
        .root_source_file = b.path("tests/fixtures/git_stash_save.txt"),
    });
    git_stash_mod.addAnonymousImport("fixture_git_stash_list", .{
        .root_source_file = b.path("tests/fixtures/git_stash_list.txt"),
    });

    const git_blame_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/git_blame.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    git_blame_mod.addImport("util", util_mod);
    git_blame_mod.addAnonymousImport("fixture_git_blame_simple", .{
        .root_source_file = b.path("tests/fixtures/git_blame_simple.txt"),
    });
    git_blame_mod.addAnonymousImport("fixture_git_blame_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_blame.txt"),
    });

    const rg_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/rg.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    rg_mod.addAnonymousImport("fixture_rg_files", .{
        .root_source_file = b.path("tests/fixtures/rg_files.txt"),
    });

    const tree_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/tree.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    tree_mod.addAnonymousImport("fixture_tree_src", .{
        .root_source_file = b.path("tests/fixtures/tree_src.txt"),
    });

    const ws_rle_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/ws_rle.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    ws_rle_mod.addAnonymousImport("fixture_docker_ps", .{
        .root_source_file = b.path("tests/fixtures/docker_ps.txt"),
    });
    ws_rle_mod.addAnonymousImport("fixture_ls_la", .{
        .root_source_file = b.path("tests/fixtures/ls_la.txt"),
    });

    const columnar_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/columnar.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    columnar_mod.addAnonymousImport("fixture_docker_ps", .{
        .root_source_file = b.path("tests/fixtures/docker_ps.txt"),
    });

    const docker_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/docker_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    docker_compact_mod.addAnonymousImport("fixture_docker_ps", .{
        .root_source_file = b.path("tests/fixtures/docker_ps.txt"),
    });

    const ls_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/ls_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    ls_compact_mod.addAnonymousImport("fixture_ls_la", .{
        .root_source_file = b.path("tests/fixtures/ls_la.txt"),
    });

    const find_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/find_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    find_compact_mod.addAnonymousImport("fixture_find_ls", .{
        .root_source_file = b.path("tests/fixtures/find_ls.txt"),
    });

    const du_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/du_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const curl_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/curl_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const kubectl_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/kubectl_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    kubectl_compact_mod.addAnonymousImport("fixture_kubectl_pods", .{
        .root_source_file = b.path("tests/fixtures/kubectl_pods.txt"),
    });

    const cargo_test_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/cargo_test.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const pytest_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/pytest.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const jest_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/jest.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    jest_mod.addAnonymousImport("fixture_jest_failing", .{
        .root_source_file = b.path("tests/fixtures/jest_failing.txt"),
    });

    const tsc_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/tsc.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    tsc_mod.addAnonymousImport("fixture_tsc_errors", .{
        .root_source_file = b.path("tests/fixtures/tsc_errors.txt"),
    });

    const go_test_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/go_test.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    go_test_mod.addAnonymousImport("fixture_go_test_v", .{
        .root_source_file = b.path("tests/fixtures/go_test_v.txt"),
    });

    const docker_logs_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/docker_logs.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    docker_logs_mod.addAnonymousImport("fixture_docker_logs", .{
        .root_source_file = b.path("tests/fixtures/docker_logs.txt"),
    });

    const npm_install_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/npm_install.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    npm_install_mod.addAnonymousImport("fixture_npm_install", .{
        .root_source_file = b.path("tests/fixtures/npm_install.txt"),
    });

    const detect_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/detect.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const ansi_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/ansi.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const generic_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/generic_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    cargo_test_mod.addImport("ansi", ansi_mod);
    pytest_mod.addImport("ansi", ansi_mod);
    jest_mod.addImport("ansi", ansi_mod);
    tsc_mod.addImport("ansi", ansi_mod);
    go_test_mod.addImport("ansi", ansi_mod);
    docker_logs_mod.addImport("ansi", ansi_mod);
    npm_install_mod.addImport("ansi", ansi_mod);
    generic_compact_mod.addImport("ansi", ansi_mod);

    const sigil_rle_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/sigil_rle.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const validator_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/validator.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    validator_mod.addImport("sigil_rle", sigil_rle_mod);

    exe_mod.addImport("detect", detect_mod);
    exe_mod.addImport("validator", validator_mod);
    exe_mod.addImport("rg", rg_mod);
    exe_mod.addImport("tree", tree_mod);
    exe_mod.addImport("ws_rle", ws_rle_mod);
    exe_mod.addImport("columnar", columnar_mod);
    exe_mod.addImport("docker_compact", docker_compact_mod);
    exe_mod.addImport("ls_compact", ls_compact_mod);
    exe_mod.addImport("find_compact", find_compact_mod);
    exe_mod.addImport("du_compact", du_compact_mod);
    exe_mod.addImport("curl_compact", curl_compact_mod);
    exe_mod.addImport("kubectl_compact", kubectl_compact_mod);
    exe_mod.addImport("cargo_test", cargo_test_mod);
    exe_mod.addImport("pytest", pytest_mod);
    exe_mod.addImport("jest", jest_mod);
    exe_mod.addImport("tsc", tsc_mod);
    exe_mod.addImport("go_test", go_test_mod);
    exe_mod.addImport("docker_logs", docker_logs_mod);
    exe_mod.addImport("npm_install", npm_install_mod);
    exe_mod.addImport("generic_compact", generic_compact_mod);
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
    exe_mod.addImport("git_stash", git_stash_mod);
    exe_mod.addImport("git_blame", git_blame_mod);

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
        .unwind_tables = .none,
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
    release_mod.addImport("git_stash", git_stash_mod);
    release_mod.addImport("git_blame", git_blame_mod);
    release_mod.addImport("detect", detect_mod);
    release_mod.addImport("validator", validator_mod);
    release_mod.addImport("rg", rg_mod);
    release_mod.addImport("tree", tree_mod);
    release_mod.addImport("ws_rle", ws_rle_mod);
    release_mod.addImport("columnar", columnar_mod);
    release_mod.addImport("docker_compact", docker_compact_mod);
    release_mod.addImport("ls_compact", ls_compact_mod);
    release_mod.addImport("find_compact", find_compact_mod);
    release_mod.addImport("du_compact", du_compact_mod);
    release_mod.addImport("curl_compact", curl_compact_mod);
    release_mod.addImport("kubectl_compact", kubectl_compact_mod);
    release_mod.addImport("cargo_test", cargo_test_mod);
    release_mod.addImport("pytest", pytest_mod);
    release_mod.addImport("jest", jest_mod);
    release_mod.addImport("tsc", tsc_mod);
    release_mod.addImport("go_test", go_test_mod);
    release_mod.addImport("docker_logs", docker_logs_mod);
    release_mod.addImport("npm_install", npm_install_mod);
    release_mod.addImport("generic_compact", generic_compact_mod);

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

    const git_stash_tests = b.addTest(.{ .root_module = git_stash_mod });
    const run_git_stash_tests = b.addRunArtifact(git_stash_tests);

    const git_blame_tests = b.addTest(.{ .root_module = git_blame_mod });
    const run_git_blame_tests = b.addRunArtifact(git_blame_tests);

    const detect_tests = b.addTest(.{ .root_module = detect_mod });
    const run_detect_tests = b.addRunArtifact(detect_tests);

    const rg_tests = b.addTest(.{ .root_module = rg_mod });
    const run_rg_tests = b.addRunArtifact(rg_tests);

    const tree_tests = b.addTest(.{ .root_module = tree_mod });
    const run_tree_tests = b.addRunArtifact(tree_tests);

    const ws_rle_tests = b.addTest(.{ .root_module = ws_rle_mod });
    const run_ws_rle_tests = b.addRunArtifact(ws_rle_tests);

    const columnar_tests = b.addTest(.{ .root_module = columnar_mod });
    const run_columnar_tests = b.addRunArtifact(columnar_tests);

    const docker_compact_tests = b.addTest(.{ .root_module = docker_compact_mod });
    const run_docker_compact_tests = b.addRunArtifact(docker_compact_tests);

    const ls_compact_tests = b.addTest(.{ .root_module = ls_compact_mod });
    const run_ls_compact_tests = b.addRunArtifact(ls_compact_tests);

    const find_compact_tests = b.addTest(.{ .root_module = find_compact_mod });
    const run_find_compact_tests = b.addRunArtifact(find_compact_tests);

    const du_compact_tests = b.addTest(.{ .root_module = du_compact_mod });
    const run_du_compact_tests = b.addRunArtifact(du_compact_tests);

    const curl_compact_tests = b.addTest(.{ .root_module = curl_compact_mod });
    const run_curl_compact_tests = b.addRunArtifact(curl_compact_tests);

    const kubectl_compact_tests = b.addTest(.{ .root_module = kubectl_compact_mod });
    const run_kubectl_compact_tests = b.addRunArtifact(kubectl_compact_tests);

    const cargo_test_tests = b.addTest(.{ .root_module = cargo_test_mod });
    const run_cargo_test_tests = b.addRunArtifact(cargo_test_tests);

    const pytest_tests = b.addTest(.{ .root_module = pytest_mod });
    const run_pytest_tests = b.addRunArtifact(pytest_tests);

    const jest_tests = b.addTest(.{ .root_module = jest_mod });
    const run_jest_tests = b.addRunArtifact(jest_tests);

    const tsc_tests = b.addTest(.{ .root_module = tsc_mod });
    const run_tsc_tests = b.addRunArtifact(tsc_tests);

    const go_test_tests = b.addTest(.{ .root_module = go_test_mod });
    const run_go_test_tests = b.addRunArtifact(go_test_tests);

    const docker_logs_tests = b.addTest(.{ .root_module = docker_logs_mod });
    const run_docker_logs_tests = b.addRunArtifact(docker_logs_tests);

    const npm_install_tests = b.addTest(.{ .root_module = npm_install_mod });
    const run_npm_install_tests = b.addRunArtifact(npm_install_tests);

    const generic_compact_tests = b.addTest(.{ .root_module = generic_compact_mod });
    const run_generic_compact_tests = b.addRunArtifact(generic_compact_tests);

    const ansi_tests = b.addTest(.{ .root_module = ansi_mod });
    const run_ansi_tests = b.addRunArtifact(ansi_tests);

    const sigil_rle_tests = b.addTest(.{ .root_module = sigil_rle_mod });
    const run_sigil_rle_tests = b.addRunArtifact(sigil_rle_tests);

    const validator_tests = b.addTest(.{ .root_module = validator_mod });
    const run_validator_tests = b.addRunArtifact(validator_tests);

    const opts = b.addOptions();
    opts.addOptionPath("smll_exe_path", exe.getEmittedBin());

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    integration_mod.addOptions("build_options", opts);
    integration_mod.addImport("git_status", git_status_mod);
    integration_mod.addImport("git_diff", git_diff_mod);
    integration_mod.addImport("git_log", git_log_mod);
    integration_mod.addImport("git_show", git_show_mod);
    integration_mod.addImport("git_commit", git_commit_mod);
    integration_mod.addImport("git_branch", git_branch_mod);
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
    // git_commit fixtures
    integration_mod.addAnonymousImport("fixture_git_commit_simple", .{
        .root_source_file = b.path("tests/fixtures/git_commit_simple.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_commit_multifile", .{
        .root_source_file = b.path("tests/fixtures/git_commit_multifile.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_commit_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_commit.txt"),
    });
    // git_branch fixtures
    integration_mod.addAnonymousImport("fixture_git_branch_list", .{
        .root_source_file = b.path("tests/fixtures/git_branch_list.txt"),
    });
    // git_add fixtures
    integration_mod.addAnonymousImport("fixture_git_add_error_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_add_error.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_add_error_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_add_error.stderr.txt"),
    });
    // git_push fixtures
    integration_mod.addAnonymousImport("fixture_git_push_simple_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_push_simple.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_push_simple_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_push_simple.stderr.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_push_large_stdout", .{
        .root_source_file = b.path("tests/fixtures/large/git_push.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_push_large_stderr", .{
        .root_source_file = b.path("tests/fixtures/large/git_push.stderr.txt"),
    });
    // git_pull fixtures
    integration_mod.addAnonymousImport("fixture_git_pull_ff_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_pull_ff.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_pull_ff_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_pull_ff.stderr.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_pull_uptodate_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_pull_uptodate.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_pull_uptodate_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_pull_uptodate.stderr.txt"),
    });
    // git_fetch fixtures
    integration_mod.addAnonymousImport("fixture_git_fetch_simple_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_fetch_simple.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_fetch_simple_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_fetch_simple.stderr.txt"),
    });
    // git_merge fixtures
    integration_mod.addAnonymousImport("fixture_git_merge_ff", .{
        .root_source_file = b.path("tests/fixtures/git_merge_ff.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_merge_commit", .{
        .root_source_file = b.path("tests/fixtures/git_merge_commit.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_merge_conflict_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_merge_conflict.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_merge_conflict_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_merge_conflict.stderr.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_merge_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_merge.txt"),
    });
    // git_rebase fixtures
    integration_mod.addAnonymousImport("fixture_git_rebase_simple", .{
        .root_source_file = b.path("tests/fixtures/git_rebase_simple.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_rebase_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_rebase.txt"),
    });
    // git_checkout fixtures
    integration_mod.addAnonymousImport("fixture_git_checkout_switch_stdout", .{
        .root_source_file = b.path("tests/fixtures/git_checkout_switch.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_checkout_switch_stderr", .{
        .root_source_file = b.path("tests/fixtures/git_checkout_switch.stderr.txt"),
    });
    // git_stash fixtures
    integration_mod.addAnonymousImport("fixture_git_stash_save", .{
        .root_source_file = b.path("tests/fixtures/git_stash_save.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_stash_list", .{
        .root_source_file = b.path("tests/fixtures/git_stash_list.txt"),
    });
    // git_blame fixtures
    integration_mod.addAnonymousImport("fixture_git_blame_simple", .{
        .root_source_file = b.path("tests/fixtures/git_blame_simple.txt"),
    });
    integration_mod.addAnonymousImport("fixture_git_blame_large", .{
        .root_source_file = b.path("tests/fixtures/large/git_blame.txt"),
    });
    // columnar fixtures (default-lossy dispatch; SMLL_LOSSLESS=1 opts out)
    integration_mod.addAnonymousImport("fixture_docker_ps", .{
        .root_source_file = b.path("tests/fixtures/docker_ps.txt"),
    });
    integration_mod.addAnonymousImport("fixture_kubectl_pods", .{
        .root_source_file = b.path("tests/fixtures/kubectl_pods.txt"),
    });
    integration_mod.addAnonymousImport("fixture_gh_pr_list", .{
        .root_source_file = b.path("tests/fixtures/gh_pr_list.txt"),
    });

    // v0.9 smoke-test fixtures — end-to-end coverage for new filters.
    integration_mod.addAnonymousImport("fixture_jest_failing", .{
        .root_source_file = b.path("tests/fixtures/jest_failing.txt"),
    });
    integration_mod.addAnonymousImport("fixture_tsc_errors", .{
        .root_source_file = b.path("tests/fixtures/tsc_errors.txt"),
    });
    integration_mod.addAnonymousImport("fixture_go_test_v", .{
        .root_source_file = b.path("tests/fixtures/go_test_v.txt"),
    });
    integration_mod.addAnonymousImport("fixture_docker_logs", .{
        .root_source_file = b.path("tests/fixtures/docker_logs.txt"),
    });
    integration_mod.addAnonymousImport("fixture_npm_install", .{
        .root_source_file = b.path("tests/fixtures/npm_install.txt"),
    });

    // v0.6 curl_compact fixtures — stdout + stderr pairs.
    integration_mod.addAnonymousImport("fixture_curl_v_example_stderr", .{
        .root_source_file = b.path("tests/fixtures/curl_v_example.stderr.txt"),
    });
    integration_mod.addAnonymousImport("fixture_curl_v_example_stdout", .{
        .root_source_file = b.path("tests/fixtures/curl_v_example.stdout.txt"),
    });
    integration_mod.addAnonymousImport("fixture_curl_vvv_example_stderr", .{
        .root_source_file = b.path("tests/fixtures/large/curl_vvv_example.stderr.txt"),
    });
    integration_mod.addAnonymousImport("fixture_curl_vvv_example_stdout", .{
        .root_source_file = b.path("tests/fixtures/large/curl_vvv_example.stdout.txt"),
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
    test_step.dependOn(&run_git_stash_tests.step);
    test_step.dependOn(&run_git_blame_tests.step);
    test_step.dependOn(&run_detect_tests.step);
    test_step.dependOn(&run_rg_tests.step);
    test_step.dependOn(&run_tree_tests.step);
    test_step.dependOn(&run_ws_rle_tests.step);
    test_step.dependOn(&run_columnar_tests.step);
    test_step.dependOn(&run_docker_compact_tests.step);
    test_step.dependOn(&run_ls_compact_tests.step);
    test_step.dependOn(&run_find_compact_tests.step);
    test_step.dependOn(&run_du_compact_tests.step);
    test_step.dependOn(&run_curl_compact_tests.step);
    test_step.dependOn(&run_kubectl_compact_tests.step);
    test_step.dependOn(&run_cargo_test_tests.step);
    test_step.dependOn(&run_pytest_tests.step);
    test_step.dependOn(&run_jest_tests.step);
    test_step.dependOn(&run_tsc_tests.step);
    test_step.dependOn(&run_go_test_tests.step);
    test_step.dependOn(&run_docker_logs_tests.step);
    test_step.dependOn(&run_npm_install_tests.step);
    test_step.dependOn(&run_generic_compact_tests.step);
    test_step.dependOn(&run_ansi_tests.step);
    test_step.dependOn(&run_sigil_rle_tests.step);
    test_step.dependOn(&run_validator_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
