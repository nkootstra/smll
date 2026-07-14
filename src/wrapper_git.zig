const std = @import("std");

const wrapper_io = @import("wrapper_io.zig");
const wrapper_util = @import("wrapper_util.zig");
const git_status = @import("git_status");
const git_diff = @import("git_diff");
const git_log = @import("git_log");
const git_show = @import("git_show");
const git_add = @import("git_add");
const git_commit = @import("git_commit");
const git_push = @import("git_push");
const git_pull = @import("git_pull");
const git_fetch = @import("git_fetch");
const git_merge = @import("git_merge");
const git_rebase = @import("git_rebase");
const git_checkout = @import("git_checkout");
const git_branch = @import("git_branch");
const git_reflog = @import("git_reflog");
const git_stash = @import("git_stash");
const git_blame = @import("git_blame");
const rg = @import("rg");
const generic_compact = @import("generic_compact");

const applyFilter = wrapper_io.applyFilter;
const passthrough = wrapper_io.passthrough;
const hasArg = wrapper_util.hasArg;
const hasFormatOrPrettyArg = wrapper_util.hasFormatOrPrettyArg;

// All 15 R4 git subcommands.  Phase 2 fills in the remaining 11; for now
// only the 4 v0.3 filters (status, diff, log, show) are wired — the other
// 11 arms fall through to passthrough.
const KnownSubcommand = enum(u8) {
    status,
    diff,
    log,
    show,
    add,
    commit,
    push,
    pull,
    fetch,
    merge,
    rebase,
    stash,
    checkout,
    @"switch",
    branch,
    blame,
    grep,
    reflog,
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout_slice: []const u8,
    stderr_slice: []const u8,
    lossless: bool,
    exit_code: u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    const arg1 = argv[1];
    // Global lossless mode: bypass all git filters.
    if (lossless) {
        passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        return exit_code;
    }

    // If git failed, preserve its raw diagnostic streams verbatim. Most git
    // filters intentionally consume benign stderr chatter on success, but
    // failed commands need every error line for the agent's next step.
    if (exit_code != 0) {
        try writer.writeAll(stdout_slice);
        try writer.writeAll(stderr_slice);
        return exit_code;
    }

    // argv[1] is the git subcommand (e.g. "status", "diff").
    const subcmd_str = arg1;
    const git_argv = argv[1..];
    const has_stat = hasArg(git_argv, "--stat") or hasArg(git_argv, "--shortstat");
    const has_name_only = hasArg(git_argv, "--name-only");
    const has_name_status = hasArg(git_argv, "--name-status");
    const has_compact_summary = hasArg(git_argv, "--compact-summary");
    if (std.meta.stringToEnum(KnownSubcommand, subcmd_str)) |subcmd| switch (subcmd) {
        .status => {
            // --porcelain / -z are machine-readable contracts consumed by
            // tooling — never modify their bytes. --short / -s are human-
            // (or agent-) facing terse outputs in porcelain v1 shape; apply
            // dirname-prefix RLE to them.
            if (hasArg(git_argv, "--porcelain") or hasArg(git_argv, "-z")) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (hasArg(git_argv, "--short") or hasArg(git_argv, "-s")) {
                if (!applyFilter(git_status.applyShort, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            } else {
                if (!applyFilter(git_status.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            }
        },
        .diff => {
            // --stat / --shortstat / --name-only / --name-status / --summary
            // produce already-compact summary output whose lines all start
            // with a leading space (treated as context and dropped) or a
            // summary line. Passthrough these modes rather than corrupting them.
            const diff_summary_mode =
                has_stat or
                has_name_only or
                has_name_status or
                has_compact_summary or
                hasArg(git_argv, "--summary") or
                hasArg(git_argv, "--patch-with-stat"); // stat lines start with space, dropped by filter
            if (diff_summary_mode) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else {
                if (!applyFilter(git_diff.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            }
        },
        .log => {
            // v0.6: compact is default; SMLL_LOSSLESS=1 opts out to the
            // fuller bespoke formatter (keeps commit bodies).
            // --oneline / --name-only / --format= / --pretty= use custom output
            // shapes that the default log filter does not understand.
            const log_custom_format =
                hasArg(git_argv, "--oneline") or
                has_name_only or
                has_name_status or
                has_compact_summary or
                hasArg(git_argv, "--no-walk") or
                hasArg(git_argv, "--abbrev-commit") or // shortened SHA breaks isCommitLine
                hasArg(git_argv, "--graph") or // gutter glyphs (* | / \) defeat isCommitLine -> empty output
                hasArg(git_argv, "-p") or
                hasArg(git_argv, "--patch") or
                hasArg(git_argv, "-u"); // -u is alias for --patch
            // Detect --format=X and --pretty=X (prefix match only).
            const log_custom_format2 = hasFormatOrPrettyArg(git_argv);
            if (log_custom_format or log_custom_format2) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (has_stat) {
                if (!applyFilter(git_log.applyStatCompact, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            } else {
                if (!applyFilter(git_log.applyCompact, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            }
        },
        .show => {
            // --name-only / --name-status / --raw / blob specs use output shapes
            // that are intentionally passed through until dedicated tests exist.
            const show_summary_mode =
                has_name_only or
                has_name_status or
                has_compact_summary or
                hasArg(git_argv, "--no-patch") or
                hasArg(git_argv, "--raw") or // object-hash format instead of diff
                hasArg(git_argv, "-s");
            // Detect --format=X and --pretty=X (custom output shapes).
            const show_custom_format = hasFormatOrPrettyArg(git_argv);
            // Detect `git show OBJECT:PATH` — file blob output, not a commit.
            // Any non-flag argument containing ':' is a blob specifier.
            const show_blob = blk: {
                for (argv[2..]) |a| { // argv[0]=git, argv[1]=show
                    if (a.len > 0 and a[0] != '-' and std.mem.indexOfScalar(u8, a, ':') != null)
                        break :blk true;
                }
                break :blk false;
            };
            if (show_summary_mode or show_custom_format or show_blob) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (has_stat) {
                if (!applyFilter(git_show.applyStatCompact, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            } else {
                if (!applyFilter(git_show.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            }
        },
        .add => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_add.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .commit => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_commit.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .push => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_push.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .pull => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_pull.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .fetch => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_fetch.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .merge => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_merge.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .rebase => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_rebase.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .checkout => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_checkout.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .@"switch" => {
            // `git switch` confirmation output ("Switched to branch 'x'") is
            // identical to checkout — reuse the checkout filter.
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_checkout.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .branch => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_branch.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .stash => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (!applyFilter(git_stash.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        },
        .blame => {
            // -s suppresses author+timestamp (compact format the filter doesn't parse).
            // --porcelain / --line-porcelain output machine-readable format.
            // -e / --show-email replaces author name with email.
            // All produce output shapes the blame filter can't handle; passthrough.
            const blame_alt_format =
                hasArg(git_argv, "-s") or
                hasArg(git_argv, "--porcelain") or
                hasArg(git_argv, "-p") or
                hasArg(git_argv, "--line-porcelain") or
                hasArg(git_argv, "--incremental") or // machine-readable format
                hasArg(git_argv, "-e") or
                hasArg(git_argv, "--show-email");
            if (blame_alt_format) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else {
                if (!applyFilter(git_blame.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            }
        },
        .grep => {
            // `git grep -n` produces path:line:content output — same grammar as
            // rg pattern mode. Compress with path-prefix RLE when the output
            // matches; passthrough otherwise (e.g. git grep without -n).
            if (rg.matchesPattern(stdout_slice)) {
                if (!applyFilter(rg.applyPattern, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            } else {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            }
        },
        .reflog => {
            // --format= / --pretty= produce custom shapes the filter cannot
            // parse; pass them through. Default `git reflog` format follows the
            // `<sha7> HEAD@{N}: <op>: <subject>` grammar the filter expects.
            if (hasFormatOrPrettyArg(git_argv)) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (git_reflog.matches(stdout_slice)) {
                if (!applyFilter(git_reflog.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            } else {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            }
        },
    } else {
        // Unknown git subcommand: apply generic compactor at the lower
        // text-mode threshold — we know it's git so small outputs still
        // benefit (e.g. git remote -v, short status outputs).
        if (!lossless and generic_compact.matchesText(stdout_slice)) {
            generic_compact.apply(allocator, stdout_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return exit_code;
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try stderr_writer.writeAll(stderr_slice);
    }

    return exit_code;
}

const graph_fixture = @embedFile("fixture_git_log_graph");

// Regression: `git log --graph` prefixes every line with gutter glyphs
// (`* `, `| `), so git_log.isCommitLine never matches and applyCompact
// emits nothing — the agent sees the "no output" hint and loses all six
// commits. The fix routes --graph through the passthrough gate.
test "git log --graph passes through unchanged" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();

    const argv = &[_][]const u8{ "git", "log", "--graph", "-6" };
    _ = try dispatch(allocator, argv, graph_fixture, "", false, 0, &out.writer, &err.writer);

    try std.testing.expect(out.written().len > 0);
    try std.testing.expectEqualStrings(graph_fixture, out.written());
}
