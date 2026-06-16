const std = @import("std");

/// A fixture file embedded into a module via `addAnonymousImport`.
const Fixture = struct {
    /// `@import("<name>")` key used from the filter / test source file.
    name: []const u8,
    /// Repo-relative path.
    path: []const u8,
};

/// Declarative description of every Zig module the build assembles. One
/// row replaces the createModule / addImport(util) / addImport(ansi) /
/// addAnonymousImport / exe_mod.addImport / release_mod.addImport /
/// addTest / test_step.dependOn boilerplate previously duplicated ~9
/// times per filter.
const ModuleEntry = struct {
    /// Module identifier. Also the `@import("<name>")` key from the
    /// dependent source files.
    name: []const u8,
    /// Source path. Defaults to `src/filters/<name>.zig` when null.
    path: ?[]const u8 = null,
    /// Add `addImport("util", util_mod)`.
    needs_util: bool = false,
    /// Add `addImport("ansi", ansi_mod)` (wired in a second pass).
    needs_ansi: bool = false,
    /// Names of other entries this module imports (e.g. git_show needs
    /// git_log + git_diff; validator needs sigil_rle).
    extra_deps: []const []const u8 = &.{},
    /// Anonymous fixture imports.
    fixtures: []const Fixture = &.{},
    /// Wire the module into the default `exe` executable.
    in_exe: bool = true,
    /// Wire the module into the stripped release executable.
    in_release: bool = true,
};

/// Single source of truth for every filter / helper module. Adding a
/// filter is one row here plus a source file under `src/filters/`.
const modules = [_]ModuleEntry{
    // Git filters (each has fixtures + util dep).
    .{ .name = "git_status", .needs_util = true, .fixtures = &.{
        .{ .name = "fixture_git_status_dirty", .path = "tests/fixtures/git_status_dirty.txt" },
        .{ .name = "fixture_git_status_clean", .path = "tests/fixtures/git_status_clean.txt" },
        .{ .name = "fixture_git_status_conflict", .path = "tests/fixtures/git_status_conflict.txt" },
        .{ .name = "fixture_git_status_short", .path = "tests/fixtures/git_status_short.txt" },
    } },
    .{ .name = "git_diff", .needs_util = true, .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_git_diff_simple", .path = "tests/fixtures/git_diff_simple.txt" },
        .{ .name = "fixture_git_diff_multi", .path = "tests/fixtures/git_diff_multi.txt" },
        .{ .name = "fixture_git_diff_rename", .path = "tests/fixtures/git_diff_rename.txt" },
        .{ .name = "fixture_git_diff_rename_modify", .path = "tests/fixtures/git_diff_rename_modify.txt" },
        .{ .name = "fixture_git_diff_color", .path = "tests/fixtures/git_diff_color.txt" },
    } },
    .{ .name = "git_log", .needs_util = true, .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_git_log_linear", .path = "tests/fixtures/git_log_linear.txt" },
        .{ .name = "fixture_git_log_merge", .path = "tests/fixtures/git_log_merge.txt" },
        .{ .name = "fixture_git_log_stat", .path = "tests/fixtures/git_log_stat.txt" },
        .{ .name = "fixture_git_log_graph", .path = "tests/fixtures/git_log_graph.txt" },
    } },
    .{ .name = "git_show", .needs_util = true, .extra_deps = &.{ "git_log", "git_diff" }, .fixtures = &.{
        .{ .name = "fixture_git_show_simple", .path = "tests/fixtures/git_show_simple.txt" },
        .{ .name = "fixture_git_show_body", .path = "tests/fixtures/git_show_body.txt" },
        .{ .name = "fixture_git_show_stat", .path = "tests/fixtures/git_show_stat.txt" },
    } },
    .{ .name = "git_add", .needs_util = true, .fixtures = &.{
        .{ .name = "fixture_git_add_error_stdout", .path = "tests/fixtures/git_add_error.stdout.txt" },
        .{ .name = "fixture_git_add_error_stderr", .path = "tests/fixtures/git_add_error.stderr.txt" },
    } },
    .{ .name = "git_commit", .needs_util = true, .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_git_commit_simple", .path = "tests/fixtures/git_commit_simple.txt" },
        .{ .name = "fixture_git_commit_multifile", .path = "tests/fixtures/git_commit_multifile.txt" },
        .{ .name = "fixture_git_commit_large", .path = "tests/fixtures/large/git_commit.txt" },
    } },
    .{ .name = "git_push", .needs_util = true, .fixtures = &.{
        .{ .name = "fixture_git_push_simple_stdout", .path = "tests/fixtures/git_push_simple.stdout.txt" },
        .{ .name = "fixture_git_push_simple_stderr", .path = "tests/fixtures/git_push_simple.stderr.txt" },
        .{ .name = "fixture_git_push_large_stdout", .path = "tests/fixtures/large/git_push.stdout.txt" },
        .{ .name = "fixture_git_push_large_stderr", .path = "tests/fixtures/large/git_push.stderr.txt" },
    } },
    .{ .name = "git_pull", .needs_util = true, .fixtures = &.{
        .{ .name = "fixture_git_pull_ff_stdout", .path = "tests/fixtures/git_pull_ff.stdout.txt" },
        .{ .name = "fixture_git_pull_ff_stderr", .path = "tests/fixtures/git_pull_ff.stderr.txt" },
        .{ .name = "fixture_git_pull_uptodate_stdout", .path = "tests/fixtures/git_pull_uptodate.stdout.txt" },
        .{ .name = "fixture_git_pull_uptodate_stderr", .path = "tests/fixtures/git_pull_uptodate.stderr.txt" },
    } },
    .{ .name = "git_fetch", .needs_util = true, .fixtures = &.{
        .{ .name = "fixture_git_fetch_simple_stdout", .path = "tests/fixtures/git_fetch_simple.stdout.txt" },
        .{ .name = "fixture_git_fetch_simple_stderr", .path = "tests/fixtures/git_fetch_simple.stderr.txt" },
    } },
    .{ .name = "git_merge", .needs_util = true, .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_git_merge_ff", .path = "tests/fixtures/git_merge_ff.txt" },
        .{ .name = "fixture_git_merge_commit", .path = "tests/fixtures/git_merge_commit.txt" },
        .{ .name = "fixture_git_merge_conflict_stdout", .path = "tests/fixtures/git_merge_conflict.stdout.txt" },
        .{ .name = "fixture_git_merge_conflict_stderr", .path = "tests/fixtures/git_merge_conflict.stderr.txt" },
        .{ .name = "fixture_git_merge_large", .path = "tests/fixtures/large/git_merge.txt" },
    } },
    .{ .name = "git_rebase", .needs_util = true, .fixtures = &.{
        .{ .name = "fixture_git_rebase_simple", .path = "tests/fixtures/git_rebase_simple.txt" },
        .{ .name = "fixture_git_rebase_large", .path = "tests/fixtures/large/git_rebase.txt" },
    } },
    .{ .name = "git_checkout", .needs_util = true, .fixtures = &.{
        .{ .name = "fixture_git_checkout_switch_stdout", .path = "tests/fixtures/git_checkout_switch.stdout.txt" },
        .{ .name = "fixture_git_checkout_switch_stderr", .path = "tests/fixtures/git_checkout_switch.stderr.txt" },
    } },
    .{ .name = "git_branch", .fixtures = &.{
        .{ .name = "fixture_git_branch_list", .path = "tests/fixtures/git_branch_list.txt" },
    } },
    .{ .name = "git_reflog", .fixtures = &.{
        .{ .name = "fixture_git_reflog", .path = "tests/fixtures/git_reflog.txt" },
    } },
    .{ .name = "git_stash", .needs_util = true, .fixtures = &.{
        .{ .name = "fixture_git_stash_save", .path = "tests/fixtures/git_stash_save.txt" },
        .{ .name = "fixture_git_stash_list", .path = "tests/fixtures/git_stash_list.txt" },
    } },
    .{ .name = "git_blame", .needs_util = true, .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_git_blame_simple", .path = "tests/fixtures/git_blame_simple.txt" },
        .{ .name = "fixture_git_blame_large", .path = "tests/fixtures/large/git_blame.txt" },
    } },

    // Search / listing filters.
    .{ .name = "rg", .fixtures = &.{
        .{ .name = "fixture_rg_files", .path = "tests/fixtures/rg_files.txt" },
    } },
    .{ .name = "tree", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_tree_src", .path = "tests/fixtures/tree_src.txt" },
        .{ .name = "fixture_tree_large", .path = "tests/fixtures/tree_large.txt" },
        .{ .name = "fixture_tree_ascii_large", .path = "tests/fixtures/tree_ascii_large.txt" },
    } },

    // Columnar / generic.
    .{ .name = "columnar", .fixtures = &.{
        .{ .name = "fixture_docker_ps", .path = "tests/fixtures/docker_ps.txt" },
    } },
    .{ .name = "docker_compact", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_docker_ps", .path = "tests/fixtures/docker_ps.txt" },
        .{ .name = "fixture_docker_compose_ps", .path = "tests/fixtures/docker_compose_ps.txt" },
        .{ .name = "fixture_docker_images", .path = "tests/fixtures/docker_images.txt" },
    } },
    .{ .name = "ls_compact", .fixtures = &.{
        .{ .name = "fixture_ls_la", .path = "tests/fixtures/ls_la.txt" },
        .{ .name = "fixture_ls_columns", .path = "tests/fixtures/ls_columns.txt" },
        .{ .name = "fixture_ls_comma", .path = "tests/fixtures/ls_comma.txt" },
        .{ .name = "fixture_ls_multi_dir", .path = "tests/fixtures/ls_multi_dir.txt" },
        .{ .name = "fixture_ls_recursive", .path = "tests/fixtures/ls_recursive.txt" },
    } },
    .{ .name = "find_compact", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_find_ls", .path = "tests/fixtures/find_ls.txt" },
        .{ .name = "fixture_find_plain_many", .path = "tests/fixtures/find_plain_many.txt" },
    } },
    .{ .name = "du_compact", .needs_ansi = true },
    .{ .name = "wc_compact" },
    .{ .name = "env_compact" },
    .{ .name = "mypy_compact", .needs_ansi = true },
    .{ .name = "ruff_compact", .needs_ansi = true },
    .{ .name = "pip_compact", .needs_ansi = true },
    .{ .name = "prettier_compact", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_prettier_write", .path = "tests/fixtures/prettier_write.txt" },
        .{ .name = "fixture_prettier_check_color", .path = "tests/fixtures/prettier_check_color.txt" },
    } },
    .{ .name = "dotnet_compact", .needs_ansi = true },
    .{ .name = "gradle_compact", .needs_ansi = true },
    .{ .name = "maven_compact", .needs_ansi = true },
    .{ .name = "precommit_compact", .needs_ansi = true },
    .{ .name = "lint_compact", .needs_ansi = true },
    .{ .name = "plan_compact", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_tofu_plan_update", .path = "tests/fixtures/tofu_plan_update.txt" },
    } },
    .{ .name = "json_compact" },
    .{ .name = "package_tree", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_npm_ls", .path = "tests/fixtures/npm_ls.txt" },
        .{ .name = "fixture_npm_ls_all", .path = "tests/fixtures/npm_ls_all.txt" },
        .{ .name = "fixture_pnpm_list", .path = "tests/fixtures/pnpm_list.txt" },
        .{ .name = "fixture_pnpm_list_deep", .path = "tests/fixtures/pnpm_list_deep.txt" },
        .{ .name = "fixture_yarn_list", .path = "tests/fixtures/yarn_list.txt" },
    } },
    .{ .name = "tool_compact", .needs_ansi = true },
    .{ .name = "acli_compact", .needs_ansi = true, .extra_deps = &.{"columnar"}, .fixtures = &.{
        .{ .name = "fixture_acli_jira_workitem_search", .path = "tests/fixtures/acli_jira_workitem_search.txt" },
        .{ .name = "fixture_acli_jira_workitem_view", .path = "tests/fixtures/acli_jira_workitem_view.txt" },
        .{ .name = "fixture_acli_jira_workitem_fields", .path = "tests/fixtures/acli_jira_workitem_fields.txt" },
        .{ .name = "fixture_acli_confluence_page_view", .path = "tests/fixtures/acli_confluence_page_view.txt" },
        .{ .name = "fixture_acli_confluence_space_list", .path = "tests/fixtures/acli_confluence_space_list.txt" },
        .{ .name = "fixture_acli_error_stderr", .path = "tests/fixtures/acli_error.stderr.txt" },
    } },
    .{ .name = "gh_compact", .fixtures = &.{
        .{ .name = "fixture_gh_pr_view", .path = "tests/fixtures/gh_pr_view.txt" },
        .{ .name = "fixture_gh_pr_checks", .path = "tests/fixtures/gh_pr_checks.txt" },
        .{ .name = "fixture_gh_pr_checks_pending", .path = "tests/fixtures/gh_pr_checks_pending.txt" },
        .{ .name = "fixture_gh_run_view", .path = "tests/fixtures/gh_run_view.txt" },
        .{ .name = "fixture_gh_run_view_failed", .path = "tests/fixtures/gh_run_view_failed.txt" },
    } },
    .{ .name = "curl_compact", .needs_ansi = true },
    .{ .name = "kubectl_compact", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_kubectl_pods", .path = "tests/fixtures/kubectl_pods.txt" },
    } },

    // Pipe-mode pre-classifier. Shared by every runner/package filter below
    // (via extra_deps) and by the dispatcher in src/pipeline.zig (via the
    // exe/release top-level import). One module instance, compiled once.
    .{ .name = "signals", .path = "src/signals.zig" },

    // Test-runner filters.
    .{ .name = "cargo_test", .needs_ansi = true, .extra_deps = &.{"signals"} },
    .{ .name = "pytest", .needs_ansi = true, .extra_deps = &.{"signals"} },
    .{ .name = "jest", .needs_ansi = true, .extra_deps = &.{"signals"}, .fixtures = &.{
        .{ .name = "fixture_jest_failing", .path = "tests/fixtures/jest_failing.txt" },
    } },
    .{ .name = "js_test", .needs_ansi = true, .extra_deps = &.{"signals"}, .fixtures = &.{
        .{ .name = "fixture_mocha_failing", .path = "tests/fixtures/mocha_failing.txt" },
        .{ .name = "fixture_node_test_failing", .path = "tests/fixtures/node_test_failing.txt" },
    } },
    .{ .name = "tsc", .needs_ansi = true, .extra_deps = &.{"signals"}, .fixtures = &.{
        .{ .name = "fixture_tsc_errors", .path = "tests/fixtures/tsc_errors.txt" },
    } },
    .{ .name = "go_test", .needs_ansi = true, .extra_deps = &.{"signals"}, .fixtures = &.{
        .{ .name = "fixture_go_test_v", .path = "tests/fixtures/go_test_v.txt" },
    } },

    // Logs / packages / builds.
    .{ .name = "docker_logs", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_docker_logs", .path = "tests/fixtures/docker_logs.txt" },
        .{ .name = "fixture_docker_compose_logs", .path = "tests/fixtures/docker_compose_logs.txt" },
    } },
    .{ .name = "npm_install", .needs_ansi = true, .extra_deps = &.{"signals"}, .fixtures = &.{
        .{ .name = "fixture_npm_install", .path = "tests/fixtures/npm_install.txt" },
        .{ .name = "fixture_pnpm_install", .path = "tests/fixtures/pnpm_install.txt" },
        .{ .name = "fixture_pnpm9_install", .path = "tests/fixtures/pnpm9_install.txt" },
        .{ .name = "fixture_bun_install", .path = "tests/fixtures/bun_install.txt" },
        .{ .name = "fixture_yarn_install", .path = "tests/fixtures/yarn_install.txt" },
        .{ .name = "fixture_composer_require", .path = "tests/fixtures/composer_require.txt" },
    } },
    .{ .name = "build_output", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_vite_build", .path = "tests/fixtures/vite_build.txt" },
        .{ .name = "fixture_next_build", .path = "tests/fixtures/next_build.txt" },
        .{ .name = "fixture_nuxt_build", .path = "tests/fixtures/nuxt_build.txt" },
        .{ .name = "fixture_webpack_build", .path = "tests/fixtures/webpack_build.txt" },
    } },
    .{ .name = "build_compact", .needs_ansi = true, .fixtures = &.{
        .{ .name = "fixture_ninja_build", .path = "tests/fixtures/ninja_build.txt" },
    } },

    // Generic / utility filters.
    .{ .name = "generic_compact", .needs_ansi = true },
    .{ .name = "cat_compact", .needs_ansi = true },

    // Helpers (in exe for tests; not in release because nothing in the
    // runtime dispatch references them directly — ansi/sigil_rle are
    // pulled in transitively by the modules that depend on them).
    .{ .name = "detect", .in_release = false },
    .{ .name = "validator", .extra_deps = &.{"sigil_rle"}, .in_release = false },
    .{ .name = "ws_rle", .in_release = false, .fixtures = &.{
        .{ .name = "fixture_docker_ps", .path = "tests/fixtures/docker_ps.txt" },
        .{ .name = "fixture_ls_la", .path = "tests/fixtures/ls_la.txt" },
    } },

    // Pure helper modules that are only built for their own test suite
    // (their consumers wire them transitively via `extra_deps` /
    // `needs_ansi`). Skipping in_exe avoids a redundant top-level edge.
    .{ .name = "ansi", .in_exe = false, .in_release = false },
    .{ .name = "sigil_rle", .in_exe = false, .in_release = false },
};

/// Fixtures used only by the integration test module (typically large
/// variants and cross-tool combinations that no single filter module
/// owns).
const integration_extra_fixtures = [_]Fixture{
    .{ .name = "fixture_git_status_large", .path = "tests/fixtures/large/git_status.txt" },
    .{ .name = "fixture_git_diff_large", .path = "tests/fixtures/large/git_diff.txt" },
    .{ .name = "fixture_git_log_large", .path = "tests/fixtures/large/git_log.txt" },
    .{ .name = "fixture_git_show_large", .path = "tests/fixtures/large/git_show.txt" },
    .{ .name = "fixture_gh_pr_list", .path = "tests/fixtures/gh_pr_list.txt" },
    .{ .name = "fixture_gh_run_list", .path = "tests/fixtures/gh_run_list.txt" },
    .{ .name = "fixture_pup_skills_json", .path = "tests/fixtures/pup_skills_json.txt" },
    .{ .name = "fixture_pup_skills_table", .path = "tests/fixtures/pup_skills_table.txt" },
    .{ .name = "fixture_ls_la", .path = "tests/fixtures/ls_la.txt" },
    .{ .name = "fixture_ls_columns", .path = "tests/fixtures/ls_columns.txt" },
    .{ .name = "fixture_cargo_build", .path = "tests/fixtures/cargo_build.txt" },
    .{ .name = "fixture_make_build", .path = "tests/fixtures/make_build.txt" },
    .{ .name = "fixture_go_build", .path = "tests/fixtures/go_build.txt" },
    .{ .name = "fixture_cargo_build_large", .path = "tests/fixtures/large/cargo_build.txt" },
    .{ .name = "fixture_make_build_large", .path = "tests/fixtures/large/make_build.txt" },
    .{ .name = "fixture_go_build_large", .path = "tests/fixtures/large/go_build.txt" },
    .{ .name = "fixture_curl_v_example_stderr", .path = "tests/fixtures/curl_v_example.stderr.txt" },
    .{ .name = "fixture_curl_v_example_stdout", .path = "tests/fixtures/curl_v_example.stdout.txt" },
    .{ .name = "fixture_curl_vvv_example_stderr", .path = "tests/fixtures/large/curl_vvv_example.stderr.txt" },
    .{ .name = "fixture_curl_vvv_example_stdout", .path = "tests/fixtures/large/curl_vvv_example.stdout.txt" },
};

/// Modules the integration test source file imports directly (via
/// `@import("<name>")`). Used only to wire those imports into
/// integration_mod.
const integration_module_imports = [_][]const u8{
    "git_status", "git_diff",   "git_log",    "git_show",
    "git_commit", "git_branch", "git_reflog",
};

pub fn build(b: *std.Build) void {
    // Compile-time uniqueness check. Catches duplicate module names at
    // build.zig load time rather than during a later cryptic addImport
    // failure.
    comptime {
        @setEvalBranchQuota(50_000);
        for (modules, 0..) |a, i| {
            for (modules, 0..) |c, j| {
                if (i < j and std.mem.eql(u8, a.name, c.name)) {
                    @compileError("duplicate module name in build.zig: " ++ a.name);
                }
            }
        }
    }

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
    // Fixture embedded only by wrapper_git's unit tests (wrapper-mode argv
    // dispatch). Unreferenced in non-test builds, so it never enters the
    // production binary.
    exe_mod.addAnonymousImport("fixture_git_log_graph", .{
        .root_source_file = b.path("tests/fixtures/git_log_graph.txt"),
    });
    // Real captured fixtures for the signals-gate superset property test in
    // main.zig. Referenced only under `test`, so they enter the exe test binary
    // but never the release build (separate module).
    const signals_property_fixtures = [_]Fixture{
        .{ .name = "sigfix_cargo_test", .path = "tests/fixtures/cargo_test_failing.txt" },
        .{ .name = "sigfix_jest", .path = "tests/fixtures/jest_failing.txt" },
        .{ .name = "sigfix_mocha", .path = "tests/fixtures/mocha_failing.txt" },
        .{ .name = "sigfix_node_test", .path = "tests/fixtures/node_test_failing.txt" },
        .{ .name = "sigfix_tsc", .path = "tests/fixtures/tsc_errors.txt" },
        .{ .name = "sigfix_go_test", .path = "tests/fixtures/go_test_v.txt" },
        .{ .name = "sigfix_pytest", .path = "tests/fixtures/pytest_failing.txt" },
        .{ .name = "sigfix_npm", .path = "tests/fixtures/npm_install.txt" },
        .{ .name = "sigfix_pnpm", .path = "tests/fixtures/pnpm_install.txt" },
        .{ .name = "sigfix_pnpm9", .path = "tests/fixtures/pnpm9_install.txt" },
        .{ .name = "sigfix_bun", .path = "tests/fixtures/bun_install.txt" },
        .{ .name = "sigfix_yarn", .path = "tests/fixtures/yarn_install.txt" },
        .{ .name = "sigfix_composer", .path = "tests/fixtures/composer_require.txt" },
        .{ .name = "sigfix_journalctl", .path = "tests/fixtures/large/generic_journalctl.txt" },
        .{ .name = "sigfix_ps_auxww", .path = "tests/fixtures/large/generic_ps_auxww.txt" },
        .{ .name = "sigfix_pip", .path = "tests/fixtures/large/generic_pip_install.txt" },
        .{ .name = "sigfix_cargo_verbose", .path = "tests/fixtures/large/generic_cargo_build_verbose.txt" },
    };
    for (signals_property_fixtures) |f| {
        exe_mod.addAnonymousImport(f.name, .{ .root_source_file = b.path(f.path) });
    }

    const util_mod = b.createModule(.{
        .root_source_file = b.path("src/util.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const stats_mod = b.createModule(.{
        .root_source_file = b.path("src/stats.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const history_mod = b.createModule(.{
        .root_source_file = b.path("src/history.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    exe_mod.addImport("util", util_mod);
    stats_mod.addImport("util", util_mod);
    history_mod.addImport("util", util_mod);
    const filter_catalog_mod = b.createModule(.{
        .root_source_file = b.path("src/filter_catalog.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const setup_mod = b.createModule(.{
        .root_source_file = b.path("src/setup.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const setup_hooks_mod = b.createModule(.{
        .root_source_file = b.path("src/setup_hooks.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const setup_io_mod = b.createModule(.{
        .root_source_file = b.path("src/setup_io.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const setup_json_mod = b.createModule(.{
        .root_source_file = b.path("src/setup_json.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const wrapper_io_mod = b.createModule(.{
        .root_source_file = b.path("src/wrapper_io.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const wrapper_util_mod = b.createModule(.{
        .root_source_file = b.path("src/wrapper_util.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    // Pass 1: create every module described in `modules`, recording it
    // in a name → module map.
    var registry = std.StringHashMap(*std.Build.Module).init(b.allocator);
    for (modules) |m| {
        const path = m.path orelse b.fmt("src/filters/{s}.zig", .{m.name});
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = .ReleaseSmall,
        });
        if (m.needs_util) mod.addImport("util", util_mod);
        for (m.fixtures) |f| {
            mod.addAnonymousImport(f.name, .{
                .root_source_file = b.path(f.path),
            });
        }
        registry.put(m.name, mod) catch @panic("OOM in build.zig registry");
    }

    // Pass 2: wire `ansi` and inter-filter dependencies. Done after the
    // create pass so any extra_dep entry can reference any module
    // regardless of declaration order.
    const ansi_mod = registry.get("ansi") orelse @panic("ansi module missing");
    exe_mod.addImport("ansi", ansi_mod);
    for (modules) |m| {
        const mod = registry.get(m.name) orelse unreachable;
        if (m.needs_ansi) mod.addImport("ansi", ansi_mod);
        for (m.extra_deps) |dep_name| {
            const dep_mod = registry.get(dep_name) orelse {
                std.debug.panic("module '{s}' lists unknown dep '{s}'", .{ m.name, dep_name });
            };
            mod.addImport(dep_name, dep_mod);
        }
    }

    // Wire dispatched modules into the exe.
    for (modules) |m| {
        if (!m.in_exe) continue;
        const mod = registry.get(m.name) orelse unreachable;
        exe_mod.addImport(m.name, mod);
    }

    const exe = b.addExecutable(.{
        .name = "smll",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run smll");
    run_step.dependOn(&run_cmd.step);

    // Release module: same source tree, but built with ReleaseSmall +
    // strip and a tighter import set. `ansi` is root-imported because
    // wrapper_stream strips watch redraw escapes.
    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .unwind_tables = .none,
        .single_threaded = true,
        .omit_frame_pointer = true,
        .link_libc = false,
    });
    release_mod.addOptions("build_options", app_opts);
    release_mod.addImport("util", util_mod);
    release_mod.addImport("ansi", ansi_mod);
    for (modules) |m| {
        if (!m.in_release) continue;
        const mod = registry.get(m.name) orelse unreachable;
        release_mod.addImport(m.name, mod);
    }

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
            rel_exe.link_function_sections = true;
            rel_exe.link_data_sections = true;
            rel_exe.link_gc_sections = true;
            rel_exe.pie = false;
            break :blk rel_exe.getEmittedBin();
        }
    };
    const install_release = b.addInstallFile(release_bin, "release/smll");
    const release_step = b.step("release", "Build stripped ReleaseSmall binary into zig-out/release/");
    release_step.dependOn(&install_release.step);

    // Per-module tests.
    const test_step = b.step("test", "Run unit tests");

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);

    for ([_]*std.Build.Module{ util_mod, stats_mod, history_mod, filter_catalog_mod, setup_mod, setup_hooks_mod, setup_io_mod, setup_json_mod, wrapper_io_mod, wrapper_util_mod }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    for (modules) |m| {
        const mod = registry.get(m.name) orelse unreachable;
        const t = b.addTest(.{ .root_module = mod });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // Integration test module. Its imports + fixtures live outside the
    // per-filter table because the integration suite exercises the
    // wrapper binary as a black box and therefore owns its own combined
    // fixture set.
    const opts = b.addOptions();
    opts.addOptionPath("smll_exe_path", exe.getEmittedBin());
    opts.addOption([]const u8, "smll_version", smll_version);

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    integration_mod.addOptions("build_options", opts);

    for (integration_module_imports) |name| {
        const mod = registry.get(name) orelse {
            std.debug.panic("integration imports unknown module '{s}'", .{name});
        };
        integration_mod.addImport(name, mod);
    }

    // Per-filter fixtures get imported into integration_mod as well so
    // the integration suite can exercise them against the real binary.
    for (modules) |m| {
        for (m.fixtures) |f| {
            integration_mod.addAnonymousImport(f.name, .{
                .root_source_file = b.path(f.path),
            });
        }
    }
    for (integration_extra_fixtures) |f| {
        integration_mod.addAnonymousImport(f.name, .{
            .root_source_file = b.path(f.path),
        });
    }

    const integration_tests = b.addTest(.{ .root_module = integration_mod });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.step.dependOn(&exe.step);
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
