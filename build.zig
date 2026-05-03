const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const smll_version = packageVersion(b);

    const app_opts = b.addOptions();
    app_opts.addOption([]const u8, "smll_version", smll_version);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addOptions("build_options", app_opts);

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

    const wc_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/wc_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const env_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/env_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const mypy_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/mypy_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const ruff_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/ruff_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const pip_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/pip_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const prettier_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/prettier_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const dotnet_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/dotnet_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });

    const tool_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/tool_compact.zig"),
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

    const build_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/build_compact.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
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

    const cat_compact_mod = b.createModule(.{
        .root_source_file = b.path("src/filters/cat_compact.zig"),
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
    build_compact_mod.addImport("ansi", ansi_mod);
    cat_compact_mod.addImport("ansi", ansi_mod);
    mypy_compact_mod.addImport("ansi", ansi_mod);
    ruff_compact_mod.addImport("ansi", ansi_mod);
    dotnet_compact_mod.addImport("ansi", ansi_mod);
    tool_compact_mod.addImport("ansi", ansi_mod);
    curl_compact_mod.addImport("ansi", ansi_mod);
    docker_compact_mod.addImport("ansi", ansi_mod);
    du_compact_mod.addImport("ansi", ansi_mod);
    find_compact_mod.addImport("ansi", ansi_mod);
    git_blame_mod.addImport("ansi", ansi_mod);
    git_commit_mod.addImport("ansi", ansi_mod);
    git_merge_mod.addImport("ansi", ansi_mod);
    kubectl_compact_mod.addImport("ansi", ansi_mod);

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
    exe_mod.addImport("wc_compact", wc_compact_mod);
    exe_mod.addImport("env_compact", env_compact_mod);
    exe_mod.addImport("mypy_compact", mypy_compact_mod);
    exe_mod.addImport("ruff_compact", ruff_compact_mod);
    exe_mod.addImport("pip_compact", pip_compact_mod);
    exe_mod.addImport("prettier_compact", prettier_compact_mod);
    exe_mod.addImport("dotnet_compact", dotnet_compact_mod);
    exe_mod.addImport("tool_compact", tool_compact_mod);
    exe_mod.addImport("curl_compact", curl_compact_mod);
    exe_mod.addImport("kubectl_compact", kubectl_compact_mod);
    exe_mod.addImport("cargo_test", cargo_test_mod);
    exe_mod.addImport("pytest", pytest_mod);
    exe_mod.addImport("jest", jest_mod);
    exe_mod.addImport("tsc", tsc_mod);
    exe_mod.addImport("go_test", go_test_mod);
    exe_mod.addImport("docker_logs", docker_logs_mod);
    exe_mod.addImport("npm_install", npm_install_mod);
    exe_mod.addImport("build_compact", build_compact_mod);
    exe_mod.addImport("generic_compact", generic_compact_mod);
    exe_mod.addImport("cat_compact", cat_compact_mod);
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
        .single_threaded = true,
        .omit_frame_pointer = true,
        .no_builtin = true,
        .link_libc = true,
    });
    release_mod.addOptions("build_options", app_opts);
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
    release_mod.addImport("rg", rg_mod);
    release_mod.addImport("tree", tree_mod);
    release_mod.addImport("columnar", columnar_mod);
    release_mod.addImport("docker_compact", docker_compact_mod);
    release_mod.addImport("ls_compact", ls_compact_mod);
    release_mod.addImport("find_compact", find_compact_mod);
    release_mod.addImport("du_compact", du_compact_mod);
    release_mod.addImport("wc_compact", wc_compact_mod);
    release_mod.addImport("env_compact", env_compact_mod);
    release_mod.addImport("mypy_compact", mypy_compact_mod);
    release_mod.addImport("ruff_compact", ruff_compact_mod);
    release_mod.addImport("pip_compact", pip_compact_mod);
    release_mod.addImport("prettier_compact", prettier_compact_mod);
    release_mod.addImport("dotnet_compact", dotnet_compact_mod);
    release_mod.addImport("tool_compact", tool_compact_mod);
    release_mod.addImport("curl_compact", curl_compact_mod);
    release_mod.addImport("kubectl_compact", kubectl_compact_mod);
    release_mod.addImport("cargo_test", cargo_test_mod);
    release_mod.addImport("pytest", pytest_mod);
    release_mod.addImport("jest", jest_mod);
    release_mod.addImport("tsc", tsc_mod);
    release_mod.addImport("go_test", go_test_mod);
    release_mod.addImport("docker_logs", docker_logs_mod);
    release_mod.addImport("npm_install", npm_install_mod);
    release_mod.addImport("build_compact", build_compact_mod);
    release_mod.addImport("generic_compact", generic_compact_mod);
    release_mod.addImport("cat_compact", cat_compact_mod);

    // On macOS: build object file, then link with system ld -no_data_const to
    // eliminate the __DATA_CONST segment (saves 16KB from page alignment waste).
    // On other platforms: use standard executable linking.
    const is_macos = target.result.os.tag == .macos;
    const release_bin = blk: {
        if (is_macos) {
            const release_obj = b.addObject(.{ .name = "smll", .root_module = release_mod });
            const ld_cmd = b.addSystemCommand(&.{ "ld", "-o" });
            const linked_bin = ld_cmd.addOutputFileArg("smll-linked");
            ld_cmd.addFileArg(release_obj.getEmittedBin());
            ld_cmd.addArgs(&.{ "-lSystem", "-no_data_const", "-dead_strip", "-no_exported_symbols", "-no_function_starts", "-syslibroot" });
            ld_cmd.addDirectoryArg(.{ .cwd_relative = "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" });

            // Strip into a fresh generated file. Stripping the ld output in
            // place is not idempotent in Zig's cache: a second `zig build
            // release` can re-strip the cached output and produce an aborting
            // executable with a bloated code signature.
            const strip_cmd = b.addSystemCommand(&.{ "strip", "-N", "-no_code_signature_warning", "-o" });
            const stripped_bin = strip_cmd.addOutputFileArg("smll");
            strip_cmd.addFileArg(linked_bin);
            break :blk stripped_bin;
        } else {
            const rel_exe = b.addExecutable(.{ .name = "smll", .root_module = release_mod });
            break :blk rel_exe.getEmittedBin();
        }
    };
    const install_release = b.addInstallFile(release_bin, "release/smll");
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

    const wc_compact_tests = b.addTest(.{ .root_module = wc_compact_mod });
    const run_wc_compact_tests = b.addRunArtifact(wc_compact_tests);

    const env_compact_tests = b.addTest(.{ .root_module = env_compact_mod });
    const run_env_compact_tests = b.addRunArtifact(env_compact_tests);

    const mypy_compact_tests = b.addTest(.{ .root_module = mypy_compact_mod });
    const run_mypy_compact_tests = b.addRunArtifact(mypy_compact_tests);

    const ruff_compact_tests = b.addTest(.{ .root_module = ruff_compact_mod });
    const run_ruff_compact_tests = b.addRunArtifact(ruff_compact_tests);

    const pip_compact_tests = b.addTest(.{ .root_module = pip_compact_mod });
    const run_pip_compact_tests = b.addRunArtifact(pip_compact_tests);

    const prettier_compact_tests = b.addTest(.{ .root_module = prettier_compact_mod });
    const run_prettier_compact_tests = b.addRunArtifact(prettier_compact_tests);

    const dotnet_compact_tests = b.addTest(.{ .root_module = dotnet_compact_mod });
    const run_dotnet_compact_tests = b.addRunArtifact(dotnet_compact_tests);

    const tool_compact_tests = b.addTest(.{ .root_module = tool_compact_mod });
    const run_tool_compact_tests = b.addRunArtifact(tool_compact_tests);

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

    const build_compact_tests = b.addTest(.{ .root_module = build_compact_mod });
    const run_build_compact_tests = b.addRunArtifact(build_compact_tests);

    const generic_compact_tests = b.addTest(.{ .root_module = generic_compact_mod });
    const run_generic_compact_tests = b.addRunArtifact(generic_compact_tests);

    const cat_compact_tests = b.addTest(.{ .root_module = cat_compact_mod });
    const run_cat_compact_tests = b.addRunArtifact(cat_compact_tests);

    const ansi_tests = b.addTest(.{ .root_module = ansi_mod });
    const run_ansi_tests = b.addRunArtifact(ansi_tests);

    const sigil_rle_tests = b.addTest(.{ .root_module = sigil_rle_mod });
    const run_sigil_rle_tests = b.addRunArtifact(sigil_rle_tests);

    const validator_tests = b.addTest(.{ .root_module = validator_mod });
    const run_validator_tests = b.addRunArtifact(validator_tests);

    const opts = b.addOptions();
    opts.addOptionPath("smll_exe_path", exe.getEmittedBin());
    opts.addOption([]const u8, "smll_version", smll_version);

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
    integration_mod.addAnonymousImport("fixture_gh_run_list", .{
        .root_source_file = b.path("tests/fixtures/gh_run_list.txt"),
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

    // v0.6 build_compact fixtures — cargo build / make / go build.
    integration_mod.addAnonymousImport("fixture_cargo_build", .{
        .root_source_file = b.path("tests/fixtures/cargo_build.txt"),
    });
    integration_mod.addAnonymousImport("fixture_make_build", .{
        .root_source_file = b.path("tests/fixtures/make_build.txt"),
    });
    integration_mod.addAnonymousImport("fixture_go_build", .{
        .root_source_file = b.path("tests/fixtures/go_build.txt"),
    });
    integration_mod.addAnonymousImport("fixture_cargo_build_large", .{
        .root_source_file = b.path("tests/fixtures/large/cargo_build.txt"),
    });
    integration_mod.addAnonymousImport("fixture_make_build_large", .{
        .root_source_file = b.path("tests/fixtures/large/make_build.txt"),
    });
    integration_mod.addAnonymousImport("fixture_go_build_large", .{
        .root_source_file = b.path("tests/fixtures/large/go_build.txt"),
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
    test_step.dependOn(&run_wc_compact_tests.step);
    test_step.dependOn(&run_env_compact_tests.step);
    test_step.dependOn(&run_mypy_compact_tests.step);
    test_step.dependOn(&run_ruff_compact_tests.step);
    test_step.dependOn(&run_pip_compact_tests.step);
    test_step.dependOn(&run_prettier_compact_tests.step);
    test_step.dependOn(&run_dotnet_compact_tests.step);
    test_step.dependOn(&run_tool_compact_tests.step);
    test_step.dependOn(&run_curl_compact_tests.step);
    test_step.dependOn(&run_kubectl_compact_tests.step);
    test_step.dependOn(&run_cargo_test_tests.step);
    test_step.dependOn(&run_pytest_tests.step);
    test_step.dependOn(&run_jest_tests.step);
    test_step.dependOn(&run_tsc_tests.step);
    test_step.dependOn(&run_go_test_tests.step);
    test_step.dependOn(&run_docker_logs_tests.step);
    test_step.dependOn(&run_npm_install_tests.step);
    test_step.dependOn(&run_build_compact_tests.step);
    test_step.dependOn(&run_generic_compact_tests.step);
    test_step.dependOn(&run_cat_compact_tests.step);
    test_step.dependOn(&run_ansi_tests.step);
    test_step.dependOn(&run_sigil_rle_tests.step);
    test_step.dependOn(&run_validator_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}

fn packageVersion(b: *std.Build) []const u8 {
    const data = b.build_root.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(64 * 1024)) catch |err| {
        std.debug.panic("failed to read build.zig.zon: {s}", .{@errorName(err)});
    };
    const version_key = ".version";
    const key_index = std.mem.indexOf(u8, data, version_key) orelse @panic("build.zig.zon missing .version");
    const after_key = data[key_index + version_key.len ..];
    const open_quote = std.mem.indexOfScalar(u8, after_key, '"') orelse @panic("build.zig.zon .version missing opening quote");
    const after_open = after_key[open_quote + 1 ..];
    const close_quote = std.mem.indexOfScalar(u8, after_open, '"') orelse @panic("build.zig.zon .version missing closing quote");
    return after_open[0..close_quote];
}
