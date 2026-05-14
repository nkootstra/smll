const std = @import("std");
const build_options = @import("build_options");
pub const panic = std.debug.simple_panic;
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};
const pipeline = @import("pipeline.zig");
const stats = @import("stats.zig");
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
const build_output = @import("build_output");
const git_stash = @import("git_stash");
const git_blame = @import("git_blame");
const rg = @import("rg");
const tree = @import("tree");
const columnar = @import("columnar");
const docker_compact = @import("docker_compact");
const ls_compact = @import("ls_compact");
const find_compact = @import("find_compact");
const du_compact = @import("du_compact");
const wc_compact = @import("wc_compact");
const env_compact = @import("env_compact");
const mypy_compact = @import("mypy_compact");
const ruff_compact = @import("ruff_compact");
const pip_compact = @import("pip_compact");
const prettier_compact = @import("prettier_compact");
const dotnet_compact = @import("dotnet_compact");
const tool_compact = @import("tool_compact");
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
const cat_compact = @import("cat_compact");

// git_branch is included in Filters because it pipe-matches (branch list output
// is stable and identifiable by leading "  " or "* " prefix). It is positioned
// after git_status and before git_show — the branch output shape is distinct from
// both. git_checkout is NOT in Filters because its matches() always returns false.
const Filters = .{ git_status, git_branch, git_reflog, git_show, GitLogCompact, git_diff, git_commit, git_merge, git_blame, cargo_test, jest, tsc, go_test, pytest, kubectl_compact, docker_compact, npm_install, tree, ls_compact, FindCompactPipe, DuCompactPipe, CurlCompactPipe, GenericCompactPipe };

/// Pipe-mode wrapper for find_compact — detects `find -ls` tabular output.
const FindCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return find_compact.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        return find_compact.apply(allocator, input, stderr, writer);
    }
};

/// Pipe-mode wrapper for du_compact — detects `du` size+path output.
/// Uses sort_desc=true in pipe mode to get top-N + prefix compression.
const DuCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return du_compact.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        return du_compact.apply(allocator, input, stderr, writer, true);
    }
};

/// Pipe-mode wrapper for curl_compact — detects curl -v/vvv stderr output
/// (lines starting with *, >, <). In pipe mode the verbose output comes as
/// stdin, so we pass it as stderr to the filter.
const CurlCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return curl_compact.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        _ = stderr;
        // In pipe mode, the curl -v output arrives as stdin (our `input`).
        // curl_compact expects stdout (body) + stderr (verbose output).
        // Pass empty stdout and the input as stderr.
        return curl_compact.apply(allocator, "", input, writer);
    }
};

/// Pipe-mode wrapper for build_compact — detects build progress chatter.
const BuildCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return build_compact.matches(input, "");
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        return build_compact.apply(allocator, input, stderr, writer);
    }
};

/// Pipe-mode wrapper for generic_compact — adapts its 3-arg apply() to the
/// 4-arg signature expected by the pipe-mode filter dispatch.
const GenericCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return generic_compact.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        _ = stderr;
        return generic_compact.apply(allocator, input, writer);
    }
};

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

fn isEnvAssignment(arg: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return false;
    return eq > 0;
}

fn isEnvListingInvocation(argv: []const []const u8) bool {
    for (argv[1..]) |arg| {
        if (arg.len == 0) continue;
        if (arg[0] == '-') continue;
        if (isEnvAssignment(arg)) continue;
        return false;
    }
    return true;
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

fn isLikelyBinary(input: []const u8) bool {
    if (hasBinaryMagic(input)) return true;
    const sample = input[0..@min(input.len, 1024)];
    var control: usize = 0;
    var high: usize = 0;
    for (sample) |c| {
        if (c == 0) return true;
        if (c >= 0x80) high += 1;
        if (c < 0x20 and c != '\n' and c != '\r' and c != '\t' and c != 0x1b) control += 1;
    }
    if (sample.len == 0) return false;
    if (control * 10 > sample.len) return true;
    // Invalid UTF-8 with high-bit bytes is a strong binary signal (JPEG,
    // compressed data). Pure ASCII logs skip this check.
    if (high > 0 and !std.unicode.utf8ValidateSlice(sample)) return true;
    return false;
}

fn hasBinaryMagic(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "\x89PNG\r\n\x1a\n") or
        std.mem.startsWith(u8, input, "\xff\xd8\xff") or
        std.mem.startsWith(u8, input, "GIF87a") or
        std.mem.startsWith(u8, input, "GIF89a") or
        std.mem.startsWith(u8, input, "%PDF-") or
        std.mem.startsWith(u8, input, "PK\x03\x04") or
        std.mem.startsWith(u8, input, "\x1f\x8b");
}

fn curlBodyLooksBinary(stdout: []const u8, stderr: []const u8) bool {
    return isLikelyBinary(stdout) or curlContentTypeLooksBinary(stderr);
}

fn curlContentTypeLooksBinary(stderr: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const value = contentTypeValue(line) orelse continue;
        return !contentTypeLooksText(value);
    }
    return false;
}

fn contentTypeValue(line: []const u8) ?[]const u8 {
    const prefixed = if (std.mem.startsWith(u8, line, "<")) std.mem.trim(u8, line[1..], " \t") else line;
    const name = "content-type:";
    if (!std.ascii.startsWithIgnoreCase(prefixed, name)) return null;
    return std.mem.trim(u8, prefixed[name.len..], " \t");
}

fn contentTypeLooksText(value: []const u8) bool {
    const media = blk: {
        const semi = std.mem.indexOfScalar(u8, value, ';') orelse break :blk value;
        break :blk value[0..semi];
    };
    const t = std.mem.trim(u8, media, " \t");
    return std.ascii.startsWithIgnoreCase(t, "text/") or
        std.ascii.indexOfIgnoreCase(t, "json") != null or
        std.ascii.indexOfIgnoreCase(t, "xml") != null or
        std.ascii.indexOfIgnoreCase(t, "javascript") != null or
        std.ascii.eqlIgnoreCase(t, "application/x-www-form-urlencoded") or
        std.ascii.eqlIgnoreCase(t, "application/graphql");
}

fn allowsShortWatchFlag(cmd_basename: []const u8) bool {
    return std.mem.eql(u8, cmd_basename, "jest") or
        std.mem.eql(u8, cmd_basename, "vitest") or
        std.mem.eql(u8, cmd_basename, "tsc") or
        std.mem.eql(u8, cmd_basename, "webpack") or
        std.mem.eql(u8, cmd_basename, "nodemon");
}

/// Detect streaming/interactive commands that produce continuous output
/// and must not be buffered. Returns true for watch modes, follow flags,
/// dev servers, and other long-running stdout streamers.
///
/// Contract: `argv` is the structured child argv (`argv[0]` command plus
/// tokens), not shell prose. The result only affects wrapper-mode execution
/// before filtered dispatch: matches inherit stdio and skip capture/filtering.
fn isStreamingCommand(cmd_basename: []const u8, argv: []const []const u8) bool {
    // --watch / --watchAll are explicit watch flags. Short -w is overloaded
    // (grep/rg word-regexp, wc/cargo width), so only treat it as watch for
    // tools where -w conventionally means watch.
    if (hasArg(argv, "--watch") or hasArg(argv, "--watchAll")) return true;
    if (hasArg(argv, "-w") and allowsShortWatchFlag(cmd_basename)) return true;

    // --follow / -f flag (docker logs, kubectl logs, tail)
    if (hasArg(argv, "--follow") or hasArg(argv, "-f")) {
        // Exception: find -f is not streaming, rg -f is not streaming.
        // Only follow-capable commands should match.
        if (std.mem.eql(u8, cmd_basename, "docker") or
            std.mem.eql(u8, cmd_basename, "kubectl") or
            std.mem.eql(u8, cmd_basename, "tail") or
            std.mem.eql(u8, cmd_basename, "journalctl")) return true;
    }

    // Subcommand-based: watch, dev, serve, start
    if (argv.len >= 2) {
        const sub = argv[1];
        // "turbo watch", "cargo watch", "gh run watch", "dotnet watch run"
        if (std.mem.eql(u8, sub, "watch")) return true;
        // "go run ." is commonly a long-running dev/server process.
        if (std.mem.eql(u8, cmd_basename, "go") and std.mem.eql(u8, sub, "run")) return true;
        // "npm run dev", "pnpm dev", etc.
        if (std.mem.eql(u8, sub, "dev") or
            std.mem.eql(u8, sub, "serve") or
            std.mem.eql(u8, sub, "start")) return true;
    }

    // "npm run dev" → argv = ["npm", "run", "dev"]
    if (argv.len >= 3) {
        const sub = argv[1];
        const arg2 = argv[2];
        if (std.mem.eql(u8, sub, "run") or std.mem.eql(u8, sub, "exec")) {
            if (std.mem.eql(u8, arg2, "dev") or
                std.mem.eql(u8, arg2, "serve") or
                std.mem.eql(u8, arg2, "start") or
                std.mem.eql(u8, arg2, "watch")) return true;
        }
    }

    // Extra subcommand-based streaming forms.
    if (argv.len >= 3) {
        if (std.mem.eql(u8, cmd_basename, "gh") and std.mem.eql(u8, argv[1], "run") and std.mem.eql(u8, argv[2], "watch")) return true;
    }

    // Inherently streaming commands
    if (std.mem.eql(u8, cmd_basename, "nodemon") or
        std.mem.eql(u8, cmd_basename, "watchman")) return true;

    return false;
}

test "streaming detection: short -w is scoped to watch-capable tools" {
    try std.testing.expect(isStreamingCommand("vitest", &.{ "vitest", "-w" }));
    try std.testing.expect(isStreamingCommand("tsc", &.{ "tsc", "-w" }));
    try std.testing.expect(!isStreamingCommand("cargo", &.{ "cargo", "test", "-w" }));
    try std.testing.expect(!isStreamingCommand("grep", &.{ "grep", "-w", "needle" }));
    try std.testing.expect(!isStreamingCommand("rg", &.{ "rg", "-w", "needle" }));
}

test "streaming detection: explicit and positional watch forms" {
    try std.testing.expect(isStreamingCommand("pnpm", &.{ "pnpm", "test", "--", "--watch" }));
    try std.testing.expect(isStreamingCommand("npm", &.{ "npm", "run", "dev" }));
    try std.testing.expect(isStreamingCommand("go", &.{ "go", "run", "." }));
    try std.testing.expect(!isStreamingCommand("go", &.{ "go", "test", "./..." }));
}

pub fn main(init: std.process.Init.Minimal) !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena_allocator = arena_state.allocator();

    var environ_map = try init.environ.createMap(std.heap.page_allocator);
    defer environ_map.deinit();
    const environ = &environ_map;
    const args = try init.args.toSlice(arena_allocator);

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
        if (envFlagOn(environ, "SMLL_LOSSLESS")) {
            var copy_buf: [32768]u8 = undefined;
            while (true) {
                const got = stdin_reader.interface.readSliceShort(&copy_buf) catch |err| switch (err) {
                    error.ReadFailed => return err,
                };
                if (got == 0) break;
                try pipe_stdout_writer.interface.writeAll(copy_buf[0..got]);
            }
        } else {
            try pipeline.run(
                std.heap.page_allocator,
                &stdin_reader.interface,
                &pipe_stdout_writer.interface,
                Filters,
            );
        }
        try pipe_stdout_writer.interface.flush();
        return;
    }

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        try stdout_writer.interface.print("smll {s}\n", .{build_options.smll_version});
        try stdout_writer.interface.flush();
        return;
    }

    const home = environ.get("HOME") orelse "";

    // Stats display: --stats, --stats --reset
    if (try stats.maybeRun(arena_allocator, io, home, args, &stdout_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        if (code != 0) std.c._exit(code);
        return;
    }

    // Setup check: only needed with args (--setup, --unsetup, etc.)
    if (try setup.maybeRun(arena_allocator, io, environ, args, &stdout_writer.interface, &stderr_writer.interface)) |code| {
        try stdout_writer.interface.flush();
        try stderr_writer.interface.flush();
        if (code != 0) std.c._exit(code);
        return;
    }

    // Wrapper mode: forward extra args as a child-process invocation.
    // Use the arena-owned argument slice directly so commands with many file
    // operands do not fail before the child process gets a chance to run.
    const child_argv = args[1..];

    // Arena over the wrapper lifetime — filter loops allocate per-line and
    // free at scope exit. page_allocator is a syscall per alloc; arena bumps
    // a pointer. Output buffers + per-line ansi.strip buffers both benefit.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try runWrapper(
        allocator,
        io,
        environ,
        child_argv,
        &stdout_writer.interface,
        &stderr_writer.interface,
    );
    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();

    // Record stats (best-effort, never fails the command). Respect the
    // conventional DO_NOT_TRACK opt-out even though stats are local-only.
    if (result.record_stats and home.len > 0 and !envFlagOn(environ, "DO_NOT_TRACK")) {
        stats.record(allocator, io, home, child_argv, result.input_bytes, result.output_bytes);
    }

    if (result.exit_code != 0) std.c._exit(result.exit_code);
}

fn readAllStdin(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var in_buf: [8192]u8 = undefined;
    var stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, &in_buf);
    return try stdin_reader.interface.allocRemaining(allocator, .unlimited);
}

// Maximum bytes captured per child stream before failing closed. Large unknown
// text output is still eligible for generic compaction, so keep this high
// enough for real-world tool dumps while bounding memory use. Verbose curl gets
// a larger cap because stdout is the response body and may be sizeable JSON.
const MAX_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_CURL_OUTPUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_OUTPUT_LABEL = "16M+\n";
const MAX_CURL_OUTPUT_LABEL = "64M+\n";

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
    reflog,
};

const WrapperResult = struct {
    exit_code: u8,
    input_bytes: usize,
    output_bytes: usize,
    record_stats: bool,
};

const CapturedOutput = struct {
    stdout: []u8,
    stderr: []u8,
};

/// Concurrently drain child stdout and stderr. Reading one pipe to EOF before
/// the other can deadlock when the child writes more than the kernel pipe
/// buffer to stderr while stdout stays open.
fn drainChildOutput(allocator: std.mem.Allocator, io: std.Io, child: *std.process.Child, max_output_bytes: usize) !CapturedOutput {
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
        if (stdout_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
        if (stderr_reader.buffered().len > max_output_bytes) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }

    try multi_reader.checkAnyError();

    const stdout_slice = try multi_reader.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try multi_reader.toOwnedSlice(1);

    return .{ .stdout = stdout_slice, .stderr = stderr_slice };
}

/// Write stdout + stderr passthrough. Used as error fallback in filter dispatch.
noinline fn passthrough(writer: *std.Io.Writer, stderr_writer: *std.Io.Writer, stdout_slice: []const u8, stderr_slice: []const u8) void {
    writer.writeAll(stdout_slice) catch {};
    stderr_writer.writeAll(stderr_slice) catch {};
}

/// Emit a hint to stdout when the wrapped child produced no stdout AND no
/// stderr. Without a hint, agents commonly retry the command in a loop,
/// mistaking the silence for a tool-side failure. The hint always includes
/// the exit code so the agent can distinguish a successful no-op (e.g.
/// `git status --short` on a clean tree) from a failure that just happened
/// to print nothing.
fn writeNoOutputHint(writer: *std.Io.Writer, argv: []const []const u8, exit_code: u8) !void {
    const cmd_path = if (argv.len > 0) argv[0] else "command";
    const cmd = if (std.mem.findScalarLast(u8, cmd_path, '/')) |idx|
        cmd_path[idx + 1 ..]
    else
        cmd_path;

    // For `git status` and `git diff` on a clean tree, raw git emits nothing
    // and exits 0 — a git-native success signal that means "no changes".
    // Use that phrasing alongside the exit code so agents recognize it.
    if (exit_code == 0 and std.mem.eql(u8, cmd, "git") and argv.len >= 2) {
        const sub = argv[1];
        if (std.mem.eql(u8, sub, "status") or std.mem.eql(u8, sub, "diff")) {
            try writer.writeAll("(smll: no changes; git ");
            try writer.writeAll(sub);
            try writer.writeAll(" exited 0 with no output)\n");
            return;
        }
    }

    try writer.print("(smll: {s} exited {d} with no output)\n", .{ cmd, exit_code });
}

fn runWrapper(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !WrapperResult {
    // Capture filter output in a buffer to measure output bytes for stats.
    var capture = std.Io.Writer.Allocating.init(allocator);
    defer capture.deinit();
    last_output_inherited = false;
    const exit_code = try runWrapperInner(allocator, io, environ, argv, &capture.writer, stderr_writer);
    const output = capture.written();

    // When both captured stdout and stderr are empty, emit a contextual hint
    // so agents don't loop retrying the command. Streaming commands inherit
    // stdio directly, so their output bypasses this capture buffer and must
    // not get an extra hint appended.
    if (output.len == 0 and last_stderr_bytes == 0 and !last_output_inherited) {
        try writeNoOutputHint(writer, argv, exit_code);
    } else {
        try writer.writeAll(output);
    }

    // Input bytes = captured child stdout (before filtering). We approximate
    // with the output bytes when the filter expands (rare) or report what we
    // have. The actual input_bytes is stdout_slice.len inside runWrapperInner,
    // but plumbing it out would require changing every return site. Instead,
    // we track it via a module-level var that runWrapperInner sets.
    return .{
        .exit_code = exit_code,
        .input_bytes = last_input_bytes,
        .output_bytes = output.len,
        .record_stats = !last_output_inherited,
    };
}

/// Set by runWrapperInner to communicate input bytes to runWrapper.
var last_input_bytes: usize = 0;
var last_stderr_bytes: usize = 0;
var last_output_inherited: bool = false;

/// Write stdout through safe generic fallbacks: high-confidence table/list
/// compaction first, then size-gated generic text compaction, then raw output.
fn writeWithFallback(allocator: std.mem.Allocator, stdout_slice: []const u8, writer: *std.Io.Writer) !void {
    try writeWithFallbackImpl(allocator, stdout_slice, writer, false);
}

/// Fallback path for commands we already know are text-only (rg, find,
/// tree, kubectl/docker columnar miss, etc.). The lower threshold lets
/// small outputs participate in RLE/whitespace compaction without the
/// binary-detection conservatism inherited from arbitrary stdin.
fn writeWithFallbackText(allocator: std.mem.Allocator, stdout_slice: []const u8, writer: *std.Io.Writer) !void {
    try writeWithFallbackImpl(allocator, stdout_slice, writer, true);
}

fn writeWithFallbackImpl(allocator: std.mem.Allocator, stdout_slice: []const u8, writer: *std.Io.Writer, known_text: bool) !void {
    if (try writeGenericTableIfUseful(allocator, stdout_slice, writer)) return;
    const should_compact = if (known_text) generic_compact.matchesText(stdout_slice) else generic_compact.matches(stdout_slice);
    if (should_compact) {
        generic_compact.apply(allocator, stdout_slice, writer) catch {
            try writer.writeAll(stdout_slice);
            return;
        };
    } else {
        try writer.writeAll(stdout_slice);
    }
}

fn writeGenericTableIfUseful(allocator: std.mem.Allocator, stdout_slice: []const u8, writer: *std.Io.Writer) !bool {
    if (!columnar.matchesGeneric(stdout_slice)) return false;

    var compact = std.Io.Writer.Allocating.init(allocator);
    defer compact.deinit();
    columnar.applyGeneric(allocator, stdout_slice, &.{}, &compact.writer) catch return false;
    const compacted = compact.written();
    if (compacted.len >= stdout_slice.len) return false;

    try writer.writeAll(compacted);
    return true;
}

fn runWrapperInner(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !u8 {
    // Spawn the child and drain stdout + stderr concurrently. Many tools write
    // substantial diagnostics/progress to stderr before closing stdout; draining
    // stdout first can block forever once the stderr pipe fills.
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

    var ls_env_old_lc_all: ?[]const u8 = null;
    var ls_env_modified = false;
    defer if (ls_env_modified) {
        // Restore original LC_ALL (best-effort, single-threaded so safe).
        @constCast(environ).put("LC_ALL", ls_env_old_lc_all orelse "") catch {};
    };
    const spawn_env: ?*const std.process.Environ.Map = blk: {
        if (std.mem.eql(u8, cmd_basename, "ls")) {
            ls_env_old_lc_all = environ.get("LC_ALL");
            @constCast(environ).put("LC_ALL", "C") catch break :blk null;
            ls_env_modified = true;
            break :blk environ;
        }
        break :blk null;
    };

    // Detect commands that must not be buffered. These get stdout+stderr
    // inherited directly — no capture, no filtering, no size cap. This includes
    // explicit lossless mode, streaming/interactive commands, and non-verbose
    // curl where stdout may be an API body, archive, or install script.
    const lossless = envFlagOn(environ, "SMLL_LOSSLESS");
    const is_raw_curl = std.mem.eql(u8, cmd_basename, "curl") and !curl_compact.hasVerboseFlag(argv);
    const is_streaming = lossless or isStreamingCommand(cmd_basename, argv) or is_raw_curl;
    if (is_streaming) {
        last_output_inherited = true;
        last_input_bytes = 0;
        last_stderr_bytes = 0;
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
            .environ_map = spawn_env,
        }) catch |err| return err;
        defer child.kill(io);
        const term = try child.wait(io);
        return switch (term) {
            .exited => |c| c,
            .signal, .stopped, .unknown => 1,
        };
    }

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = spawn_env,
    }) catch |err| return err;
    defer child.kill(io);

    const max_output_bytes: usize = if (std.mem.eql(u8, cmd_basename, "curl") and curl_compact.hasVerboseFlag(argv))
        MAX_CURL_OUTPUT_BYTES
    else
        MAX_OUTPUT_BYTES;
    const max_output_label = if (max_output_bytes == MAX_CURL_OUTPUT_BYTES) MAX_CURL_OUTPUT_LABEL else MAX_OUTPUT_LABEL;
    const captured = drainChildOutput(allocator, io, &child, max_output_bytes) catch |err| switch (err) {
        error.StreamTooLong => {
            last_input_bytes = 0;
            last_stderr_bytes = max_output_label.len;
            stderr_writer.writeAll(max_output_label) catch {};
            return 1;
        },
        else => return err,
    };
    const stdout_slice = captured.stdout;
    const stderr_slice = captured.stderr;

    // Record raw stream sizes for stats tracking and empty-output detection.
    last_input_bytes = stdout_slice.len;
    last_stderr_bytes = stderr_slice.len;

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
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (rg.matchesPattern(stdout_slice)) {
            rg.applyPattern(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if ((is_rg_files_mode or is_find_plain) and rg.matches(stdout_slice)) {
            rg.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
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
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
            try stderr_writer.writeAll(stderr_slice);
            return exit_code;
        }
        if (std.mem.eql(u8, cmd_basename, "tree")) {
            try writeWithFallbackText(allocator, stdout_slice, writer);
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
            if (is_pytest and (pytest.matches(stdout_slice) or pytest.matches(stderr_slice))) {
                pytest.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_cargo_test and (cargo_test.matches(stdout_slice) or cargo_test.matches(stderr_slice))) {
                cargo_test.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_jest and (jest.matches(stdout_slice) or jest.matches(stderr_slice))) {
                jest.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_tsc and (tsc.matches(stdout_slice) or tsc.matches(stderr_slice))) {
                tsc.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
                return exit_code;
            }
            if (is_go_test and (go_test.matches(stdout_slice) or go_test.matches(stderr_slice))) {
                go_test.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
                return exit_code;
            }
        }
        try writeWithFallback(allocator, stdout_slice, writer);
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // Python tooling wrappers — preserve diagnostics while dropping progress
    // chatter/table padding.
    if (std.mem.eql(u8, cmd_basename, "mypy")) {
        if (!lossless) {
            mypy_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "ruff")) {
        if (!lossless) {
            ruff_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "head") or std.mem.eql(u8, cmd_basename, "tail")) {
        passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "gh")) {
        if (exit_code != 0 and stderr_slice.len > 0) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (!lossless) {
            if (!try writeGenericTableIfUseful(allocator, stdout_slice, writer)) {
                tool_compact.applyGh(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
            }
            try stderr_writer.writeAll(stderr_slice);
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "pnpm") or std.mem.eql(u8, cmd_basename, "yarn") or
        std.mem.eql(u8, cmd_basename, "bun") or std.mem.eql(u8, cmd_basename, "uv") or
        std.mem.eql(u8, cmd_basename, "uvx"))
    {
        // For JS-pkg-manager install subcommands, the bespoke npm_install
        // filter drops manager-specific chatter (Progress:, banner, dep trees)
        // that tool_compact.applyPackage's substring keep would let survive.
        const is_js_install_subcmd =
            (std.mem.eql(u8, cmd_basename, "pnpm") or
                std.mem.eql(u8, cmd_basename, "yarn") or
                std.mem.eql(u8, cmd_basename, "bun")) and
            (std.mem.eql(u8, arg1, "install") or
                std.mem.eql(u8, arg1, "i") or
                std.mem.eql(u8, arg1, "add") or
                std.mem.eql(u8, arg1, "remove") or
                std.mem.eql(u8, arg1, "rm"));
        // `<manager> build` or `<manager> run build` — content signature
        // (Vite banner, Next.js banner, "modules transformed") confirms it
        // is a real build pipeline before we compact.
        const is_build_subcmd =
            (std.mem.eql(u8, cmd_basename, "pnpm") or
                std.mem.eql(u8, cmd_basename, "yarn") or
                std.mem.eql(u8, cmd_basename, "bun")) and
            (std.mem.eql(u8, arg1, "build") or
                (std.mem.eql(u8, arg1, "run") and argv.len >= 3 and std.mem.eql(u8, argv[2], "build")));
        if (!lossless and is_build_subcmd and build_output.matches(stdout_slice)) {
            build_output.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
            return exit_code;
        } else if (!lossless and is_build_subcmd and build_output.matches(stderr_slice)) {
            build_output.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
            return exit_code;
        }
        if (exit_code != 0 and stderr_slice.len > 0) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (!lossless and is_js_install_subcmd and npm_install.matches(stdout_slice)) {
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless and is_js_install_subcmd and npm_install.matches(stderr_slice)) {
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless) {
            tool_compact.applyPackage(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    // composer (PHP) install/require/update/remove — same lossy contract as
    // the JS managers: keep summary + warnings/errors, drop scaffolding.
    if (std.mem.eql(u8, cmd_basename, "composer")) {
        const is_composer_install_subcmd =
            std.mem.eql(u8, arg1, "install") or
            std.mem.eql(u8, arg1, "require") or
            std.mem.eql(u8, arg1, "update") or
            std.mem.eql(u8, arg1, "upgrade") or
            std.mem.eql(u8, arg1, "remove") or
            std.mem.eql(u8, arg1, "create-project");
        if (exit_code != 0 and stderr_slice.len > 0 and !npm_install.matches(stderr_slice)) {
            // Genuine failure with no recognized error markers — let the user see it raw.
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (!lossless and is_composer_install_subcmd and npm_install.matches(stdout_slice)) {
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless and is_composer_install_subcmd and npm_install.matches(stderr_slice)) {
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "swift") or std.mem.eql(u8, cmd_basename, "xcodebuild")) {
        if (exit_code != 0 and stderr_slice.len > 0) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (!lossless) {
            tool_compact.applyAppleBuild(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "dotnet")) {
        if (!lossless and (std.mem.eql(u8, arg1, "build") or std.mem.eql(u8, arg1, "test") or std.mem.eql(u8, arg1, "format") or std.mem.eql(u8, arg1, "restore"))) {
            dotnet_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "prettier")) {
        if (!lossless) {
            prettier_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "pip") or std.mem.eql(u8, cmd_basename, "pip3")) {
        if (!lossless and (std.mem.eql(u8, arg1, "list") or std.mem.eql(u8, arg1, "outdated"))) {
            pip_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    // env wrapper — mask sensitive variables for environment-listing forms.
    // Do not filter `env FOO=bar command`: that form executes an arbitrary
    // child command and its stdout should keep the command's semantics.
    if (std.mem.eql(u8, cmd_basename, "env") and isEnvListingInvocation(argv)) {
        if (!lossless) {
            env_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    // wc wrapper — collapse padding while preserving counts, filenames, and stderr.
    if (std.mem.eql(u8, cmd_basename, "wc")) {
        if (!lossless) {
            wc_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    // curl -v / -vv / -vvv wrapper — LOSSY compaction by default (v0.6).
    // Drops TLS handshake chatter and cert dumps from stderr; preserves
    // status line, request/response headers, and body. Non-verbose curl is
    // always passthrough: stdout is often machine-readable JSON, shell scripts,
    // or other data consumed by downstream tools.
    if (std.mem.eql(u8, cmd_basename, "curl")) {
        if (curl_compact.hasVerboseFlag(argv) and !lossless and curl_compact.matches(stderr_slice) and !curlBodyLooksBinary(stdout_slice, stderr_slice)) {
            curl_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
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
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            try writeWithFallback(allocator, stdout_slice, writer);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // ls wrapper — LOSSY compaction (filenames only) by default (v0.6).
    // Set SMLL_LOSSLESS=1 for raw passthrough.
    if (std.mem.eql(u8, cmd_basename, "ls")) {
        if (!lossless and ls_compact.matches(stdout_slice)) {
            ls_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch |err| {
                if (err == error.ParsedNothing) {
                    try writeWithFallback(allocator, stdout_slice, writer);
                } else {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                }
            };
        } else {
            try writeWithFallback(allocator, stdout_slice, writer);
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
        // JS package manager installs — npm/pnpm/yarn/bun {install,i,ci,add,remove,rm}.
        // Keep summary + warnings, drop banners/progress/dep trees.
        const is_install_subcmd =
            std.mem.eql(u8, arg1, "install") or
            std.mem.eql(u8, arg1, "i") or
            std.mem.eql(u8, arg1, "ci") or
            std.mem.eql(u8, arg1, "add") or
            std.mem.eql(u8, arg1, "remove") or
            std.mem.eql(u8, arg1, "rm");
        const is_js_pkg_manager =
            std.mem.eql(u8, cmd_basename, "npm") or
            std.mem.eql(u8, cmd_basename, "pnpm") or
            std.mem.eql(u8, cmd_basename, "yarn") or
            std.mem.eql(u8, cmd_basename, "bun");
        const is_js_install = is_js_pkg_manager and is_install_subcmd;
        // JS package manager build — npm/pnpm/yarn/bun build (or run build).
        // Content signature (vite/next/nuxt banner) confirms we have a real
        // bundler pipeline before routing through build_output.
        const is_js_build = is_js_pkg_manager and
            (std.mem.eql(u8, arg1, "build") or
                (std.mem.eql(u8, arg1, "run") and argv.len >= 3 and std.mem.eql(u8, argv[2], "build")));
        if (!lossless and (is_docker_logs or is_kubectl_logs)) {
            docker_logs.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless and is_js_build and build_output.matches(stdout_slice)) {
            build_output.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless and is_js_build and build_output.matches(stderr_slice)) {
            build_output.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless and is_js_install and npm_install.matches(stdout_slice)) {
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless and is_js_install and npm_install.matches(stderr_slice)) {
            // Several managers write progress + warnings to stderr (npm classic, yarn,
            // pnpm). Dispatch off stderr when stdout doesn't match but stderr does.
            npm_install.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
            return exit_code;
        } else if (!lossless and std.mem.eql(u8, cmd_basename, "docker") and docker_compact.matches(stdout_slice)) {
            docker_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless and std.mem.eql(u8, cmd_basename, "kubectl") and kubectl_compact.matches(stdout_slice)) {
            kubectl_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else if (!lossless and columnar.matches(stdout_slice)) {
            columnar.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            // No bespoke filter matched within the columnar block.
            // Known-text command class (docker/kubectl/etc.) — use the lower gate.
            if (!lossless and generic_compact.matchesText(stdout_slice)) {
                generic_compact.apply(allocator, stdout_slice, writer) catch {
                    try writer.writeAll(stdout_slice);
                };
            } else {
                try writer.writeAll(stdout_slice);
            }
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
    const is_zig_build = is_build_subcmd and std.mem.eql(u8, cmd_basename, "zig");
    if (is_make or is_cargo_build or is_go_build or is_zig_build) {
        if (!lossless and build_compact.matches(stdout_slice, stderr_slice)) {
            build_compact.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            try writeWithFallback(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    // cat wrapper: compress code output, pass through data files.
    if (std.mem.eql(u8, cmd_basename, "cat")) {
        if (!lossless and cat_compact.matches(stdout_slice)) {
            cat_compact.apply(allocator, stdout_slice, stderr_slice, writer, argv) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        } else {
            try writeWithFallback(allocator, stdout_slice, writer);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    if (!std.mem.eql(u8, cmd_basename, "git") or argv.len < 2) {
        // Non-git outer command: size-gated generic compactor on stdout
        // when no bespoke arm claimed it AND output exceeds threshold.
        // SMLL_LOSSLESS=1 bypasses. stderr always passes through verbatim.
        if (!lossless) {
            try writeWithFallback(allocator, stdout_slice, writer);
        } else {
            try writer.writeAll(stdout_slice);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // Global lossless mode: bypass all git filters.
    if (lossless) {
        passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        return exit_code;
    }

    // If git failed, preserve its raw diagnostic streams verbatim. Most git
    // filters intentionally consume benign stderr chatter on success, but
    // failed commands need every error line for the agent's next step.
    if (exit_code != 0 and stderr_slice.len > 0) {
        try writer.writeAll(stdout_slice);
        try writer.writeAll(stderr_slice);
        return exit_code;
    }

    // argv[1] is the git subcommand (e.g. "status", "diff").
    const subcmd_str = arg1;
    const git_argv = argv[1..];
    const has_stat_or_name_flags = hasStatOrNameFlags(git_argv);
    if (std.meta.stringToEnum(KnownSubcommand, subcmd_str)) |subcmd| switch (subcmd) {
        .status => {
            // --porcelain / -z are machine-readable contracts consumed by
            // tooling — never modify their bytes. --short / -s are human-
            // (or agent-) facing terse outputs in porcelain v1 shape; apply
            // dirname-prefix RLE to them.
            if (hasArg(git_argv, "--porcelain") or hasArg(git_argv, "-z")) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else if (hasArg(git_argv, "--short") or hasArg(git_argv, "-s")) {
                git_status.applyShort(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
            } else {
                git_status.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
            }
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
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else {
                git_diff.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
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
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else {
                git_log.applyCompact(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
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
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else {
                git_show.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
            }
        },
        .add => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_add.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .commit => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_commit.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .push => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_push.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .pull => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_pull.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .fetch => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_fetch.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .merge => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_merge.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .rebase => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_rebase.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .checkout => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_checkout.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .branch => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_branch.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return 1;
            };
        },
        .stash => {
            if (lossless) {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else git_stash.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
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
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
            } else {
                git_blame.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
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
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
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
                git_reflog.apply(allocator, stdout_slice, stderr_slice, writer) catch {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return 1;
                };
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
