const std = @import("std");
const pipeline = @import("pipeline.zig");
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
const git_stash = @import("git_stash");
const git_blame = @import("git_blame");
const detect = @import("detect");
const validator = @import("validator");
const rg = @import("rg");
const tree = @import("tree");
const ws_rle = @import("ws_rle");
const columnar = @import("columnar");
const docker_compact = @import("docker_compact");
const ls_compact = @import("ls_compact");
const kubectl_compact = @import("kubectl_compact");
const cargo_test = @import("cargo_test");
const pytest = @import("pytest");
const jest = @import("jest");
const tsc = @import("tsc");
const go_test = @import("go_test");
const docker_logs = @import("docker_logs");
const npm_install = @import("npm_install");

// git_branch is included in Filters because it pipe-matches (branch list output
// is stable and identifiable by leading "  " or "* " prefix). It is positioned
// after git_status and before git_show — the branch output shape is distinct from
// both. git_checkout is NOT in Filters because its matches() always returns false.
const Filters = .{ git_status, git_branch, git_show, git_log, git_diff, git_commit };

// rg filter is wrapper-mode only (`smll rg --files src/`). Its output grammar
// overlaps too many non-rg tools in pipe mode (diff stats, generic listings),
// so auto-detection via matches() produces false positives and breaks the
// lossless contract for those other tools.

test {
    _ = pipeline;
}

pub fn main() !void {
    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&out_buf);

    // Fast path: no extra argv → stdin mode. Skip the page_allocator,
    // argsWithAllocator iterator, and ArrayList entirely. std.os.argv is
    // already populated by the runtime; len 1 = program name only.
    if (std.os.argv.len <= 1) {
        // v0.6 prototype: SMLL_DETECT=1 enables the tool-agnostic detect filter
        // (ANSI strip + whitespace collapse + prefix RLE) instead of the git filter
        // tuple. Used for measurement only.
        const detect_env = std.posix.getenv("SMLL_DETECT") orelse "";
        if (detect_env.len > 0 and detect_env[0] == '1') {
            const allocator = std.heap.page_allocator;
            const input = try readAllStdin(allocator);
            defer allocator.free(input);
            try detect.apply(allocator, input, &.{}, &stdout_writer.interface);
            try stdout_writer.interface.flush();
            return;
        }
        const validate_env = std.posix.getenv("SMLL_VALIDATE") orelse "";
        if (validate_env.len > 0 and validate_env[0] == '1') {
            const allocator = std.heap.page_allocator;
            const input = try readAllStdin(allocator);
            defer allocator.free(input);
            try validator.apply(allocator, input, &stdout_writer.interface);
            try stdout_writer.interface.flush();
            return;
        }
        var in_buf: [4096]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&in_buf);
        try pipeline.run(
            std.heap.page_allocator,
            &stdin_reader.interface,
            &stdout_writer.interface,
            Filters,
        );
        try stdout_writer.interface.flush();
        return;
    }

    // Wrapper mode: forward extra args as a child-process invocation.
    // Build the slice from std.os.argv on the stack — no ArrayList growth
    // and no iterator allocation. 32 args is well above any realistic
    // `git <subcmd> <args...>` invocation.
    var argv_buf: [32][]const u8 = undefined;
    const argv_count = std.os.argv.len - 1;
    if (argv_count > argv_buf.len) return error.TooManyArgs;
    for (std.os.argv[1..], 0..) |arg, i| {
        argv_buf[i] = std.mem.span(arg);
    }

    // Arena over the wrapper lifetime — filter loops allocate per-line and
    // free at scope exit. page_allocator is a syscall per alloc; arena bumps
    // a pointer. Output buffers + per-line ansi.strip buffers both benefit.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try runWrapper(allocator, argv_buf[0..argv_count], &stdout_writer.interface);
    try stdout_writer.interface.flush();
    if (code != 0) std.process.exit(code);
}

fn readAllStdin(allocator: std.mem.Allocator) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    const stdin = std.fs.File.stdin();
    while (true) {
        const n = try stdin.read(&chunk);
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..n]);
    }
    return list.toOwnedSlice(allocator);
}

// Maximum bytes captured from child stdout + stderr combined.
// 2 MiB matches the integration test cap and accommodates large git outputs.
const MAX_OUTPUT_BYTES: usize = 2 * 1024 * 1024;

// All 15 R4 git subcommands.  Phase 2 fills in the remaining 11; for now
// only the 4 v0.3 filters (status, diff, log, show) are wired — the other
// 11 arms fall through to passthrough.
const KnownSubcommand = enum {
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
    branch,
    blame,
    unknown,
};

fn runWrapper(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    writer: *std.Io.Writer,
) !u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    // Concurrently drain both stdout and stderr into heap-backed ArrayLists.
    // collectOutput uses std.Io.poll so neither pipe can deadlock the other.
    var stdout_list: std.ArrayList(u8) = .empty;
    defer stdout_list.deinit(allocator);
    var stderr_list: std.ArrayList(u8) = .empty;
    defer stderr_list.deinit(allocator);

    child.collectOutput(allocator, &stdout_list, &stderr_list, MAX_OUTPUT_BYTES) catch |err| switch (err) {
        // collectOutput signals cap exceeded via stream-too-long errors.
        error.StdoutStreamTooLong, error.StderrStreamTooLong => {
            _ = child.wait() catch {};
            const msg = "smll: child output exceeded 2 MiB cap\n";
            std.fs.File.stderr().writeAll(msg) catch {};
            return 1;
        },
        else => return err,
    };

    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        .Signal, .Stopped, .Unknown => 1,
    };

    const stdout_slice = stdout_list.items;
    const stderr_slice = stderr_list.items;

    // Argv guard: only dispatch through the formatter switch when the outer
    // command is literally "git".  Any other outer command (e.g. "cargo")
    // goes straight to passthrough even if the subcommand string matches a
    // KnownSubcommand.
    const outer_cmd = argv[0];
    // Strip any directory prefix: "git", "/usr/bin/git", etc. all match.
    const cmd_basename = if (std.mem.lastIndexOfScalar(u8, outer_cmd, '/')) |idx|
        outer_cmd[idx + 1 ..]
    else
        outer_cmd;

    // Path-list wrappers (rg --files, find): path-per-line output, compresses
    // via dirname RLE.  rg.matches() rejects pattern-mode output.
    if (std.mem.eql(u8, cmd_basename, "rg") or
        std.mem.eql(u8, cmd_basename, "find"))
    {
        if (rg.matches(stdout_slice)) {
            rg.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try std.fs.File.stderr().writeAll(stderr_slice);
        return exit_code;
    }

    // tree wrapper: requires box-drawing chars in the first few lines.
    // `bun` emits tree output for `bun pm ls` — routed through tree first,
    // falls through to columnar opt-in below if tree doesn't match.
    if (std.mem.eql(u8, cmd_basename, "tree") or
        std.mem.eql(u8, cmd_basename, "bun"))
    {
        if (tree.matches(stdout_slice)) {
            tree.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
            try std.fs.File.stderr().writeAll(stderr_slice);
            return exit_code;
        }
        if (std.mem.eql(u8, cmd_basename, "tree")) {
            try writer.writeAll(stdout_slice);
            try std.fs.File.stderr().writeAll(stderr_slice);
            return exit_code;
        }
        // bun: fall through to columnar opt-in check below.
    }

    // Test runners + type-checker — OPT-IN LOSSY compaction under SMLL_COMPACT=1.
    // Emits failures + summary only; "all tests passed\n" / "no type errors\n"
    // on clean runs.
    const is_pytest = std.mem.eql(u8, cmd_basename, "pytest");
    const is_cargo_test = std.mem.eql(u8, cmd_basename, "cargo") and
        argv.len >= 2 and std.mem.eql(u8, argv[1], "test");
    const is_jest = std.mem.eql(u8, cmd_basename, "jest") or
        std.mem.eql(u8, cmd_basename, "vitest");
    const is_tsc = std.mem.eql(u8, cmd_basename, "tsc");
    const is_go_test = std.mem.eql(u8, cmd_basename, "go") and
        argv.len >= 2 and std.mem.eql(u8, argv[1], "test");
    if (is_pytest or is_cargo_test or is_jest or is_tsc or is_go_test) {
        const compact = std.posix.getenv("SMLL_COMPACT") orelse "";
        const enabled = compact.len > 0 and compact[0] == '1';
        if (enabled) {
            if (is_pytest and pytest.matches(stdout_slice)) {
                pytest.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try std.fs.File.stderr().writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_cargo_test and (cargo_test.matches(stdout_slice) or cargo_test.matches(stderr_slice))) {
                cargo_test.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try std.fs.File.stderr().writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_jest and jest.matches(stdout_slice)) {
                jest.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try std.fs.File.stderr().writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_tsc and tsc.matches(stdout_slice)) {
                tsc.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try std.fs.File.stderr().writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_go_test and (go_test.matches(stdout_slice) or go_test.matches(stderr_slice))) {
                go_test.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try std.fs.File.stderr().writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
        }
        try writer.writeAll(stdout_slice);
        try std.fs.File.stderr().writeAll(stderr_slice);
        return exit_code;
    }

    // ls wrapper — OPT-IN LOSSY compaction (filenames only) under SMLL_COMPACT=1.
    if (std.mem.eql(u8, cmd_basename, "ls")) {
        const compact = std.posix.getenv("SMLL_COMPACT") orelse "";
        const enabled = compact.len > 0 and compact[0] == '1';
        if (enabled and ls_compact.matches(stdout_slice)) {
            ls_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try std.fs.File.stderr().writeAll(stderr_slice);
        return exit_code;
    }

    // Columnar wrappers (docker, kubectl, gh) — OPT-IN LOSSY compaction.
    // Default dispatch passes through (lossless R3 contract preserved).
    // Under SMLL_COMPACT=1, docker routes through docker_compact (name-only
    // summary); the rest fall through to the generic columnar RLE filter.
    _ = &ws_rle; // kept in-tree as reference; see ws_rle.zig header comment
    if (std.mem.eql(u8, cmd_basename, "docker") or
        std.mem.eql(u8, cmd_basename, "kubectl") or
        std.mem.eql(u8, cmd_basename, "gh") or
        std.mem.eql(u8, cmd_basename, "ps") or
        std.mem.eql(u8, cmd_basename, "systemctl") or
        std.mem.eql(u8, cmd_basename, "lsof") or
        std.mem.eql(u8, cmd_basename, "npm") or
        std.mem.eql(u8, cmd_basename, "pnpm") or
        std.mem.eql(u8, cmd_basename, "yarn") or
        std.mem.eql(u8, cmd_basename, "brew") or
        std.mem.eql(u8, cmd_basename, "bun"))
    {
        const compact = std.posix.getenv("SMLL_COMPACT") orelse "";
        const enabled = compact.len > 0 and compact[0] == '1';
        // docker logs <container> — line dedup (before docker ps table dispatch).
        const is_docker_logs = std.mem.eql(u8, cmd_basename, "docker") and
            argv.len >= 2 and std.mem.eql(u8, argv[1], "logs");
        // kubectl logs <pod> — same grammar, same filter.
        const is_kubectl_logs = std.mem.eql(u8, cmd_basename, "kubectl") and
            argv.len >= 2 and std.mem.eql(u8, argv[1], "logs");
        // npm install / npm i / npm ci — keep summary + warnings, drop notice/funding.
        const is_npm_install = std.mem.eql(u8, cmd_basename, "npm") and
            argv.len >= 2 and
            (std.mem.eql(u8, argv[1], "install") or
                std.mem.eql(u8, argv[1], "i") or
                std.mem.eql(u8, argv[1], "ci"));
        if (enabled and (is_docker_logs or is_kubectl_logs)) {
            docker_logs.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        } else if (enabled and is_npm_install and npm_install.matches(stdout_slice)) {
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        } else if (enabled and is_npm_install and npm_install.matches(stderr_slice)) {
            // npm writes WARN/notice to stderr in many versions; dispatch off stderr
            // when stdout doesn't match but stderr does.
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
            return exit_code;
        } else if (enabled and std.mem.eql(u8, cmd_basename, "docker") and docker_compact.matches(stdout_slice)) {
            docker_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        } else if (enabled and std.mem.eql(u8, cmd_basename, "kubectl") and kubectl_compact.matches(stdout_slice)) {
            kubectl_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        } else if (enabled and columnar.matches(stdout_slice)) {
            columnar.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try std.fs.File.stderr().writeAll(stderr_slice);
        return exit_code;
    }

    if (!std.mem.eql(u8, cmd_basename, "git") or argv.len < 2) {
        // Non-git outer command: passthrough both streams verbatim.
        try writer.writeAll(stdout_slice);
        try std.fs.File.stderr().writeAll(stderr_slice);
        return exit_code;
    }

    // argv[1] is the git subcommand (e.g. "status", "diff").
    const subcmd_str = argv[1];
    const subcmd = std.meta.stringToEnum(KnownSubcommand, subcmd_str) orelse .unknown;

    switch (subcmd) {
        .status => {
            git_status.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                // Formatter-error policy: emit raw stdout as fail-open, exit non-zero.
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .diff => {
            git_diff.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .log => {
            const compact_env = std.posix.getenv("SMLL_COMPACT") orelse "";
            const compact = compact_env.len > 0 and compact_env[0] == '1';
            const result = if (compact)
                git_log.applyCompact(allocator, stdout_slice, stderr_slice, writer)
            else
                git_log.apply(allocator, stdout_slice, stderr_slice, writer);
            result catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .show => {
            git_show.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .add => {
            git_add.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .commit => {
            git_commit.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .push => {
            git_push.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .pull => {
            git_pull.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .fetch => {
            git_fetch.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .merge => {
            git_merge.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .rebase => {
            git_rebase.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .checkout => {
            git_checkout.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .branch => {
            git_branch.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .stash => {
            git_stash.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .blame => {
            git_blame.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try std.fs.File.stderr().writeAll(stderr_slice);
                return 1;
            };
        },
        .unknown => {
            try writer.writeAll(stdout_slice);
            try std.fs.File.stderr().writeAll(stderr_slice);
        },
    }

    return exit_code;
}
