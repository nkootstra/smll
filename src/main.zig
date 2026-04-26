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
const rg = @import("rg");
const tree = @import("tree");
const columnar = @import("columnar");
const docker_compact = @import("docker_compact");
const ls_compact = @import("ls_compact");
const find_compact = @import("find_compact");
const du_compact = @import("du_compact");
const curl_compact = @import("curl_compact");
const kubectl_compact = @import("kubectl_compact");
const cargo_test = @import("cargo_test");
const pytest = @import("pytest");
const jest = @import("jest");
const tsc = @import("tsc");
const go_test = @import("go_test");
const docker_logs = @import("docker_logs");
const npm_install = @import("npm_install");
const build_compact = @import("build_compact");
const generic_compact = @import("generic_compact");
const setup = @import("setup.zig");

// git_branch is included in Filters because it pipe-matches (branch list output
// is stable and identifiable by leading "  " or "* " prefix). It is positioned
// after git_status and before git_show — the branch output shape is distinct from
// both. git_checkout is NOT in Filters because its matches() always returns false.
const Filters = .{ git_status, git_branch, git_show, GitLogCompact, git_diff, git_commit };

/// Pipe-mode wrapper that uses git_log.applyCompact instead of apply.
/// This matches the v0.6 "lossy by default" posture for pipe mode.
const GitLogCompact = struct {
    pub fn matches(input: []const u8) bool {
        return git_log.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        return git_log.applyCompact(allocator, input, stderr, writer);
    }
};

// rg filter is wrapper-mode only (`smll rg --files src/`). Its output grammar
// overlaps too many non-rg tools in pipe mode (diff stats, generic listings),
// so auto-detection via matches() produces false positives and breaks the
// lossless contract for those other tools.

test {
    _ = pipeline;
}

/// Returns true when `name` env var is set and its first byte is '1'.
fn envFlagOn(environ_map: *const std.process.Environ.Map, name: []const u8) bool {
    const v = environ_map.get(name) orelse return false;
    return v.len > 0 and v[0] == '1';
}

/// Returns true when `argv` contains an exact-match token equal to `arg`.
fn hasArg(argv: []const []const u8, arg: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, arg)) return true;
    return false;
}

fn hasFormatOrPrettyArg(argv: []const []const u8) bool {
    for (argv) |a| {
        if (std.mem.startsWith(u8, a, "--format=") or
            std.mem.startsWith(u8, a, "--pretty=") or
            std.mem.eql(u8, a, "--format") or
            std.mem.eql(u8, a, "--pretty")) return true;
    }
    return false;
}

fn hasStatOrNameFlags(argv: []const []const u8) bool {
    return hasArg(argv, "--stat") or
        hasArg(argv, "--shortstat") or
        hasArg(argv, "--name-only") or
        hasArg(argv, "--name-status") or
        hasArg(argv, "--compact-summary");
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const environ = init.environ_map;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &out_buf);

    var err_buf: [1024]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(io, &err_buf);

    // Fast path: no extra argv → stdin mode. Skip setup check and
    // wrapper-mode arena init entirely. Use a larger output buffer
    // to reduce write syscalls for large passthrough data.
    if (args.len <= 1) {
        var pipe_out_buf: [32768]u8 = undefined;
        var pipe_stdout_writer = stdout_file.writer(io, &pipe_out_buf);
        var in_buf: [4096]u8 = undefined;
        var stdin_file = std.Io.File.stdin();
        var stdin_reader = stdin_file.reader(io, &in_buf);
        try pipeline.run(
            std.heap.page_allocator,
            &stdin_reader.interface,
            &pipe_stdout_writer.interface,
            Filters,
        );
        try pipe_stdout_writer.interface.flush();
        return;
    }

    // Setup check: only needed with args (--setup, --unsetup, etc.)
    if (try setup.maybeRun(init.arena.allocator(), io, environ, args, &stdout_writer.interface, &stderr_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        if (code != 0) std.process.exit(code);
        return;
    }

    // Wrapper mode: forward extra args as a child-process invocation.
    // Build the slice from init.minimal.args on the stack — 32 args is well
    // above any realistic `git <subcmd> <args...>` invocation.
    var argv_buf: [32][]const u8 = undefined;
    const argv_count = args.len - 1;
    if (argv_count > argv_buf.len) return error.TooManyArgs;
    for (args[1..], 0..) |arg, i| {
        argv_buf[i] = arg;
    }

    // Arena over the wrapper lifetime — filter loops allocate per-line and
    // free at scope exit. page_allocator is a syscall per alloc; arena bumps
    // a pointer. Output buffers + per-line ansi.strip buffers both benefit.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const code = try runWrapper(
        allocator,
        io,
        environ,
        argv_buf[0..argv_count],
        &stdout_writer.interface,
        &stderr_writer.interface,
    );
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    if (code != 0) std.process.exit(code);
}

fn readAllStdin(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var in_buf: [8192]u8 = undefined;
    var stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, &in_buf);
    return try stdin_reader.interface.allocRemaining(allocator, .unlimited);
}

// Maximum bytes captured from child stdout + stderr combined.
// 2 MiB matches the integration test cap and accommodates large git outputs.
const MAX_OUTPUT_BYTES: usize = 2 * 1024 * 1024;

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
    branch,
    blame,
    grep,
};

fn runWrapper(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Spawn + sequential drain (stdout, then stderr). Avoids MultiReader to
    // shave ~10 KB off the release binary. Deadlock risk if stderr exceeds
    // the pipe buffer (~64 KB on Linux) before stdout is drained — acceptable
    // for git/cargo/bun which emit small stderr (errors, progress lines).
    // MAX_OUTPUT_BYTES cap still bounds total capture.
    //
    // For `ls`: force LC_ALL=C + LANG=C so date fields always use the C-locale
    // shape ("Apr 22") regardless of the user's system locale. Without this,
    // non-English locales produce different date formats that shift the field
    // count and cause extractName() to return null for every line.
    const outer_cmd = argv[0];
    const cmd_basename = if (std.mem.findScalarLast(u8, outer_cmd, '/')) |idx|
        outer_cmd[idx + 1 ..]
    else
        outer_cmd;

    var ls_env: std.process.Environ.Map = undefined;
    var ls_env_inited = false;
    defer if (ls_env_inited) ls_env.deinit();
    const spawn_env: ?*const std.process.Environ.Map = blk: {
        if (std.mem.eql(u8, cmd_basename, "ls")) {
            ls_env = try environ.clone(allocator);
            ls_env_inited = true;
            try ls_env.put("LC_ALL", "C");
            break :blk &ls_env;
        }
        break :blk null;
    };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = spawn_env,
    }) catch |err| return err;
    defer child.kill(io);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &stdout_buf);
    const stdout_slice = stdout_reader.interface.allocRemaining(allocator, .limited(MAX_OUTPUT_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            const msg = "2M+\n";
            stderr_writer.writeAll(msg) catch {};
            return 1;
        },
        else => return err,
    };

    var err_drain_buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.reader(io, &err_drain_buf);
    const stderr_slice = stderr_reader.interface.allocRemaining(allocator, .limited(MAX_OUTPUT_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            const msg = "2M+\n";
            stderr_writer.writeAll(msg) catch {};
            return 1;
        },
        else => return err,
    };

    const term = try child.wait(io);
    const exit_code: u8 = switch (term) {
        .exited => |c| c,
        .signal, .stopped, .unknown => 1,
    };

    // Argv guard: only dispatch through the formatter switch when the outer
    // command is literally "git".  Any other outer command (e.g. "cargo")
    // goes straight to passthrough even if the subcommand string matches a
    // KnownSubcommand.
    // Strip any directory prefix: "git", "/usr/bin/git", etc. all match.

    // Hoist SMLL_LOSSLESS lookup — checked in every dispatch branch.
    const lossless = envFlagOn(environ, "SMLL_LOSSLESS");

    const has_arg1 = argv.len >= 2;
    const arg1 = if (has_arg1) argv[1] else "";

    // Path-list wrappers (rg --files, find): path-per-line output, compresses
    // via dirname RLE. `find -ls` goes through find_compact instead
    // (columnar inode/mode/size/path → path-only). SMLL_LOSSLESS=1 bypasses
    // both.
    const is_rg_cmd = std.mem.eql(u8, cmd_basename, "rg");
    const is_find_cmd = std.mem.eql(u8, cmd_basename, "find");
    if (is_rg_cmd or is_find_cmd) {
        const is_find_ls = is_find_cmd and hasArg(argv, "-ls");
        // For rg: only apply --files dirname RLE when the output is confirmed file-list
        // mode. Guards against rg -N (no line numbers) output which is path:content —
        // matchesPattern correctly rejects it, but rg.matches() could accept it and
        // apply wrong dirname compression. --files/-l/--files-with-matches confirm
        // file-list mode; find output (no colons in paths) is also safe.
        const is_rg_files_mode = is_rg_cmd and
            (hasArg(argv, "--files") or
                hasArg(argv, "-l") or
                hasArg(argv, "--files-with-matches"));
        const is_find_plain = is_find_cmd and !is_find_ls;
        if (lossless) {
            try writer.writeAll(stdout_slice);
        } else if (is_find_ls and find_compact.matches(stdout_slice)) {
            find_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else if (rg.matchesPattern(stdout_slice)) {
            rg.applyPattern(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else if ((is_rg_files_mode or is_find_plain) and rg.matches(stdout_slice)) {
            rg.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try stderr_writer.writeAll(stderr_slice);
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
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
            try stderr_writer.writeAll(stderr_slice);
            return exit_code;
        }
        if (std.mem.eql(u8, cmd_basename, "tree")) {
            try writer.writeAll(stdout_slice);
            try stderr_writer.writeAll(stderr_slice);
            return exit_code;
        }
        // bun: fall through to columnar opt-in check below.
    }

    // Test runners + type-checker — LOSSY compaction by default (v0.6).
    // Emits failures + summary only; "all tests passed\n" / "no type errors\n"
    // on clean runs. Set SMLL_LOSSLESS=1 for raw passthrough.
    const is_pytest = std.mem.eql(u8, cmd_basename, "pytest");
    const is_test_subcmd = std.mem.eql(u8, arg1, "test");
    const is_cargo_test = is_test_subcmd and std.mem.eql(u8, cmd_basename, "cargo");
    // jest/vitest: direct invocation OR script runners (npm/pnpm/yarn/bun test)
    // that produce jest-shaped output. Output-shape detection in jest.matches()
    // guards against false positives when other test runners are used.
    const is_jest = switch (cmd_basename[0]) {
        'j' => std.mem.eql(u8, cmd_basename, "jest"),
        'v' => std.mem.eql(u8, cmd_basename, "vitest"),
        'n' => is_test_subcmd and std.mem.eql(u8, cmd_basename, "npm"),
        'p' => is_test_subcmd and std.mem.eql(u8, cmd_basename, "pnpm"),
        'y' => is_test_subcmd and std.mem.eql(u8, cmd_basename, "yarn"),
        'b' => is_test_subcmd and std.mem.eql(u8, cmd_basename, "bun"),
        else => false,
    };
    const is_tsc = std.mem.eql(u8, cmd_basename, "tsc");
    const is_go_test = is_test_subcmd and std.mem.eql(u8, cmd_basename, "go");
    if (is_pytest or is_cargo_test or is_jest or is_tsc or is_go_test) {
        if (!lossless) {
            if (is_pytest and pytest.matches(stdout_slice)) {
                pytest.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_cargo_test and (cargo_test.matches(stdout_slice) or cargo_test.matches(stderr_slice))) {
                cargo_test.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_jest and jest.matches(stdout_slice)) {
                jest.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_tsc and tsc.matches(stdout_slice)) {
                tsc.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_go_test and (go_test.matches(stdout_slice) or go_test.matches(stderr_slice))) {
                go_test.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
                return exit_code;
            }
        }
        try writer.writeAll(stdout_slice);
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // curl -v / -vv / -vvv wrapper — LOSSY compaction by default (v0.6).
    // Drops TLS handshake chatter and cert dumps from stderr; preserves
    // status line, request/response headers, and body. Non-standard filter:
    // matches() inspects STDERR, not stdout. Set SMLL_LOSSLESS=1 to bypass.
    if (std.mem.eql(u8, cmd_basename, "curl") and curl_compact.hasVerboseFlag(argv)) {
        if (!lossless and curl_compact.matches(stderr_slice)) {
            curl_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    // du wrapper — LOSSY compaction (2-sig-fig size rounding) by default (v0.6).
    // When `-s` / `--summarize` is present, sort entries descending by byte size
    // so the largest offenders come first. Set SMLL_LOSSLESS=1 for raw passthrough.
    if (std.mem.eql(u8, cmd_basename, "du")) {
        if (!lossless and du_compact.matches(stdout_slice)) {
            const sort_desc = du_compact.hasSummarizeFlag(argv);
            du_compact.apply(allocator, stdout_slice, stderr_slice, writer, sort_desc) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // ls wrapper — LOSSY compaction (filenames only) by default (v0.6).
    // Set SMLL_LOSSLESS=1 for raw passthrough.
    if (std.mem.eql(u8, cmd_basename, "ls")) {
        if (!lossless and ls_compact.matches(stdout_slice)) {
            ls_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch |err| {
                // ParsedNothing: content was present but parser extracted nothing
                // (e.g. eza/exa/lsd date format, non-English locale). Fall through
                // to raw passthrough instead of returning empty/misleading output.
                if (err == error.ParsedNothing) {
                    try writer.writeAll(stdout_slice);
                } else {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                }
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // Columnar wrappers (docker, kubectl, gh, …) — LOSSY compaction by default (v0.6).
    // docker routes through docker_compact (name-only summary); the rest fall
    // through to the generic columnar RLE filter. Set SMLL_LOSSLESS=1 for raw
    // passthrough.
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
        const is_logs_subcmd = std.mem.eql(u8, arg1, "logs");
        // docker logs <container> — line dedup (before docker ps table dispatch).
        const is_docker_logs = is_logs_subcmd and std.mem.eql(u8, cmd_basename, "docker");
        // kubectl logs <pod> — same grammar, same filter.
        const is_kubectl_logs = is_logs_subcmd and std.mem.eql(u8, cmd_basename, "kubectl");
        // npm install / npm i / npm ci — keep summary + warnings, drop notice/funding.
        const is_npm_install = std.mem.eql(u8, cmd_basename, "npm") and
            (std.mem.eql(u8, arg1, "install") or
                std.mem.eql(u8, arg1, "i") or
                std.mem.eql(u8, arg1, "ci"));
        if (!lossless and (is_docker_logs or is_kubectl_logs)) {
            docker_logs.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else if (!lossless and is_npm_install and npm_install.matches(stdout_slice)) {
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else if (!lossless and is_npm_install and npm_install.matches(stderr_slice)) {
            // npm writes WARN/notice to stderr in many versions; dispatch off stderr
            // when stdout doesn't match but stderr does.
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
            return exit_code;
        } else if (!lossless and std.mem.eql(u8, cmd_basename, "docker") and docker_compact.matches(stdout_slice)) {
            docker_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else if (!lossless and std.mem.eql(u8, cmd_basename, "kubectl") and kubectl_compact.matches(stdout_slice)) {
            kubectl_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else if (!lossless and columnar.matches(stdout_slice)) {
            columnar.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // Build-chatter wrapper: `make`, `cargo build`, `go build` — LOSSY
    // compaction by default (v0.6). Collapses `Compiling X` / `cc -c X.o`
    // / `go build: X` progress lines into a summary count; warnings and
    // errors pass through verbatim. Stream-placement: cargo/go emit
    // progress on stderr, make splits; the filter inspects both. Gate by
    // `!SMLL_LOSSLESS`. `bun` is explicitly excluded.
    const is_make = std.mem.eql(u8, cmd_basename, "make");
    const is_build_subcmd = std.mem.eql(u8, arg1, "build");
    const is_cargo_build = is_build_subcmd and std.mem.eql(u8, cmd_basename, "cargo");
    const is_go_build = is_build_subcmd and std.mem.eql(u8, cmd_basename, "go");
    if (is_make or is_cargo_build or is_go_build) {
        if (!lossless and build_compact.matches(stdout_slice, stderr_slice)) {
            build_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    if (!std.mem.eql(u8, cmd_basename, "git") or argv.len < 2) {
        // Non-git outer command: size-gated generic compactor on stdout
        // when no bespoke arm claimed it AND output exceeds threshold.
        // SMLL_LOSSLESS=1 bypasses. stderr always passes through verbatim.
        if (!lossless and generic_compact.matches(stdout_slice)) {
            generic_compact.apply(allocator, stdout_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return if (exit_code != 0) exit_code else 1;
            };
        } else {
            try writer.writeAll(stdout_slice);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // Global lossless mode: bypass all git filters.
    if (lossless) {
        try writer.writeAll(stdout_slice);
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // argv[1] is the git subcommand (e.g. "status", "diff").
    const subcmd_str = arg1;
    const git_argv = argv[1..];
    const has_stat_or_name_flags = hasStatOrNameFlags(git_argv);
    if (std.meta.stringToEnum(KnownSubcommand, subcmd_str)) |subcmd| switch (subcmd) {
        .status => {
            git_status.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .diff => {
            // --stat / --shortstat / --name-only / --name-status / --summary
            // produce already-compact summary output whose lines all start
            // with a leading space (treated as context and dropped) or a
            // summary line. Passthrough these modes rather than corrupting them.
            const diff_summary_mode =
                has_stat_or_name_flags or
                hasArg(git_argv, "--summary") or
                hasArg(git_argv, "--patch-with-stat"); // stat lines start with space, dropped by filter
            if (diff_summary_mode) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else {
                git_diff.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
            }
        },
        .log => {
            // v0.6: compact is default; SMLL_LOSSLESS=1 opts out to the
            // fuller bespoke formatter (keeps commit bodies).
            // --oneline / --stat / --name-only / --format= / --pretty= use custom
            // output shapes that the filter does not understand. Passthrough raw.
            const log_custom_format =
                hasArg(git_argv, "--oneline") or
                has_stat_or_name_flags or
                hasArg(git_argv, "--no-walk") or
                hasArg(git_argv, "--abbrev-commit") or // shortened SHA breaks isCommitLine
                hasArg(git_argv, "-p") or
                hasArg(git_argv, "--patch") or
                hasArg(git_argv, "-u"); // -u is alias for --patch
            // Detect --format=X and --pretty=X (prefix match only).
            const log_custom_format2 = hasFormatOrPrettyArg(git_argv);
            if (log_custom_format or log_custom_format2) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else {
                git_log.applyCompact(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
            }
        },
        .show => {
            // --stat / --name-only / --name-status produce summary-format output
            // whose file-stat lines all start with a space and would be silently
            // dropped by the diff section of git_show.apply. Passthrough raw.
            const show_summary_mode =
                has_stat_or_name_flags or
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
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else {
                git_show.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
            }
        },
        .add => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_add.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .commit => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_commit.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .push => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_push.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .pull => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_pull.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .fetch => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_fetch.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .merge => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_merge.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .rebase => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_rebase.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .checkout => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_checkout.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .branch => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_branch.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
        },
        .stash => {
            if (lossless) {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else git_stash.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
                return 1;
            };
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
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            } else {
                git_blame.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
            }
        },
        .grep => {
            // `git grep -n` produces path:line:content output — same grammar as
            // rg pattern mode. Compress with path-prefix RLE when the output
            // matches; passthrough otherwise (e.g. git grep without -n).
            if (rg.matchesPattern(stdout_slice)) {
                rg.applyPattern(allocator, stdout_slice, stderr_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                    try stderr_writer.writeAll(stderr_slice);
                    return 1;
                };
            } else {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            }
        },
    } else {
        try writer.writeAll(stdout_slice);
        try stderr_writer.writeAll(stderr_slice);
    }

    return exit_code;
}
