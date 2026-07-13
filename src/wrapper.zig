const std = @import("std");
const builtin = @import("builtin");

const tee = @import("tee.zig");
const wrapper_git = @import("wrapper_git.zig");
const wrapper_io = @import("wrapper_io.zig");
const wrapper_stream = @import("wrapper_stream.zig");
const wrapper_util = @import("wrapper_util.zig");
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
const acli_compact = @import("acli_compact");
const gh_compact = @import("gh_compact");
const curl_compact = @import("curl_compact");
const kubectl_compact = @import("kubectl_compact");
const cargo_test = @import("cargo_test");
const pytest = @import("pytest");
const jest = @import("jest");
const js_test = @import("js_test");
const tsc = @import("tsc");
const go_test = @import("go_test");
const docker_logs = @import("docker_logs");
const npm_install = @import("npm_install");
const build_output = @import("build_output");
const build_compact = @import("build_compact");
const gradle_compact = @import("gradle_compact");
const maven_compact = @import("maven_compact");
const precommit_compact = @import("precommit_compact");
const lint_compact = @import("lint_compact");
const plan_compact = @import("plan_compact");
const json_compact = @import("json_compact");
const package_tree = @import("package_tree");
const generic_compact = @import("generic_compact");
const cat_compact = @import("cat_compact");
const pipeline = @import("pipeline.zig");
const pipe_filters = @import("pipe_filters.zig");

const CountingWriter = wrapper_io.CountingWriter;
const applyFilter = wrapper_io.applyFilter;
const drainChildOutput = wrapper_io.drainChildOutput;
const passthrough = wrapper_io.passthrough;
const envFlagOn = wrapper_util.envFlagOn;
const teeEnabled = wrapper_util.teeEnabled;
const hasArg = wrapper_util.hasArg;
const isEnvListingInvocation = wrapper_util.isEnvListingInvocation;
const curlBodyLooksBinary = wrapper_util.curlBodyLooksBinary;
const eqAny = wrapper_util.eqAny;
const isStreamingCommand = wrapper_util.isStreamingCommand;

const AcliFilterFn = *const fn (std.mem.Allocator, []const u8, []const u8, *std.Io.Writer) anyerror!void;

// Maximum bytes captured per child stream before failing closed. Large unknown
// text output is still eligible for generic compaction, so keep this high
// enough for real-world tool dumps while bounding memory use. Verbose curl gets
// a larger cap because stdout is the response body and may be sizeable JSON.
const MAX_OUTPUT_BYTES: usize = 16 * 1024 * 1024;
const MAX_CURL_OUTPUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_OUTPUT_LABEL = "16M+\n";
const MAX_CURL_OUTPUT_LABEL = "64M+\n";

pub const Result = struct {
    exit_code: u8,
    input_bytes: usize,
    output_bytes: usize,
    filter_name: []const u8,
    record_stats: bool,
};

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

fn isSyntheticSuccess(output: []const u8) bool {
    const trimmed = std.mem.trim(u8, output, " \t\r\n");
    return eqAny(trimmed, &.{
        "all tests passed",
        "all hooks passed",
        "no type errors",
        "lint ok",
        "build complete",
        "up to date",
        "plan ok",
        "gradle ok",
        "maven ok",
        "ok",
    });
}

test "all synthesized success sentinels are recognized" {
    inline for (.{
        "all tests passed",
        "all hooks passed",
        "no type errors",
        "lint ok",
        "build complete",
        "up to date",
        "plan ok",
        "gradle ok",
        "maven ok",
        "ok",
    }) |sentinel| {
        try std.testing.expect(isSyntheticSuccess(sentinel));
    }
}

fn applyAcliFilter(
    comptime apply: AcliFilterFn,
    allocator: std.mem.Allocator,
    stdout_slice: []const u8,
    stderr_slice: []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) bool {
    return applyFilter(apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer);
}

fn findHasTypeFile(argv: []const []const u8) bool {
    var i: usize = 0;
    while (i + 1 < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-type") and std.mem.eql(u8, argv[i + 1], "f")) return true;
    }
    return false;
}

fn lsRequestsExactOutput(argv: []const []const u8) bool {
    var parse_options = true;
    for (argv[1..]) |arg| {
        if (!parse_options) continue;
        if (std.mem.eql(u8, arg, "--")) {
            parse_options = false;
            continue;
        }
        if (arg.len < 2 or arg[0] != '-') continue;
        if (arg[1] == '-') {
            if (eqAny(arg, &.{ "--all", "--almost-all", "--directory", "--recursive", "--classify" }) or
                std.mem.startsWith(u8, arg, "--classify=") or
                std.mem.startsWith(u8, arg, "--indicator-style=") or
                isHumanLsFormat(arg)) continue;
            return true;
        }
        for (arg[1..]) |flag| switch (flag) {
            '1', 'A', 'C', 'F', 'R', 'a', 'd', 'm', 'p', 'x' => {},
            else => return true,
        };
    }
    return false;
}

fn isHumanLsFormat(arg: []const u8) bool {
    if (!std.mem.startsWith(u8, arg, "--format=")) return false;
    const format = arg["--format=".len..];
    return eqAny(format, &.{ "across", "commas", "horizontal", "single-column", "vertical" });
}

fn ghWantsDataOutput(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--json") or
            std.mem.eql(u8, arg, "--jq") or
            std.mem.startsWith(u8, arg, "--json=") or
            std.mem.startsWith(u8, arg, "--jq="))
        {
            return true;
        }
    }
    return false;
}

fn hasPackagePrelude(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        inline for (.{ "Installed ", "Resolved ", "Prepared ", "Downloaded " }) |prefix| {
            if (std.mem.startsWith(u8, line, prefix) and std.mem.indexOf(u8, line[prefix.len..], " package") != null) return true;
        }
    }
    return false;
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !Result {
    const invocation = wrapper_util.classifyInvocation(argv);
    if (shouldRunStreamFilter(environ, invocation)) {
        var counted_stdout = CountingWriter.init(writer);
        const stream_result = try wrapper_stream.runStreamFilter(
            allocator,
            io,
            argv,
            invocation.logical_argv,
            &counted_stdout.writer,
        );
        try counted_stdout.writer.flush();
        return .{
            .exit_code = stream_result.exit_code,
            .input_bytes = stream_result.input_bytes,
            .output_bytes = counted_stdout.count,
            .filter_name = stream_result.filter_name,
            .record_stats = true,
        };
    }

    // Capture compacted stdout separately; stderr is forwarded through a
    // counting proxy so stats match the full agent-visible stream.
    var capture = std.Io.Writer.Allocating.init(allocator);
    defer capture.deinit();
    var counted_stderr = CountingWriter.init(stderr_writer);
    last_output_inherited = false;
    last_filter_name = "passthrough";
    last_raw_stdout = &.{};
    last_raw_stderr = &.{};
    const exit_code = try runWrapperInner(allocator, io, environ, argv, &capture.writer, &counted_stderr.writer);
    const output = capture.written();

    var final_stdout = std.Io.Writer.Allocating.init(allocator);
    defer final_stdout.deinit();

    // A child failure is authoritative. If a lossy filter found no diagnostic
    // or emitted one of its success-only summaries, fall open to the raw
    // streams instead of contradicting the process status.
    const failed_filter_output = exit_code != 0 and !last_output_inherited and
        ((output.len == 0 and (last_raw_stdout.len > 0 or last_raw_stderr.len > 0)) or
            isSyntheticSuccess(output));
    if (failed_filter_output) {
        try final_stdout.writer.writeAll(last_raw_stdout);
        if (counted_stderr.count == 0) try counted_stderr.writer.writeAll(last_raw_stderr);
    }

    // When both captured stdout and stderr are empty, emit a contextual hint
    // so agents don't loop retrying the command. Streaming commands inherit
    // stdio directly, so their output bypasses this capture buffer and must
    // not get an extra hint appended.
    if (!failed_filter_output and output.len == 0 and counted_stderr.count == 0 and !last_output_inherited) {
        try writeNoOutputHint(&final_stdout.writer, argv, exit_code);
    } else if (!failed_filter_output) {
        try final_stdout.writer.writeAll(output);
    }

    // Tee recovery: on a failed wrapped command, persist the *raw* (pre-filter)
    // stdout+stderr under `~/.smll/tee/` and append a breadcrumb to stdout so
    // the agent can fetch the unredacted output when the compact summary isn't
    // enough. Streaming/lossless modes inherit stdio directly so there's
    // nothing to record. Best-effort: failures never surface to the user.
    if (exit_code != 0 and !last_output_inherited and teeEnabled(environ)) {
        const home = environ.get("HOME") orelse "";
        if (tee.maybeRecord(allocator, io, home, argv, exit_code, last_raw_stdout, last_raw_stderr)) |path| {
            final_stdout.writer.print("\n(smll: full output saved to {s})\n", .{path}) catch {};
        }
    }

    const final_stdout_bytes = final_stdout.written().len;
    try writer.writeAll(final_stdout.written());

    // Input bytes are raw child stdout+stderr. Output bytes are compacted
    // stdout plus any stderr smll forwarded, matching what an agent sees.
    return .{
        .exit_code = exit_code,
        .input_bytes = last_input_bytes,
        .output_bytes = final_stdout_bytes + counted_stderr.count,
        .filter_name = last_filter_name,
        .record_stats = !last_output_inherited,
    };
}

/// Public `--raw` execution path. Inherit all three standard streams and pass
/// the caller's environment through unchanged. Deliberately bypasses capture,
/// filtering, tee recovery, and statistics.
pub fn runRaw(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = environ,
    });
    defer child.kill(io);
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped, .unknown => 1,
    };
}

fn shouldRunStreamFilter(environ: *const std.process.Environ.Map, invocation: wrapper_util.Invocation) bool {
    const argv = invocation.logical_argv;
    if (argv.len == 0) return false;
    if (invocation.passthrough_reason != null) return false;
    if (envFlagOn(environ, "SMLL_LOSSLESS")) return false;
    if (!envFlagOn(environ, "SMLL_STREAM")) return false;
    if (stdoutIsTty()) return false;
    const cmd_basename = pathBasename(argv[0]);
    return wrapper_util.classifyStreamCommand(cmd_basename, argv) == .stream_filter;
}

fn stdoutIsTty() bool {
    if (builtin.os.tag == .linux and !builtin.link_libc) {
        var wsz: std.posix.winsize = undefined;
        const rc = std.os.linux.syscall3(.ioctl, 1, std.os.linux.T.IOCGWINSZ, @intFromPtr(&wsz));
        return std.os.linux.errno(rc) == .SUCCESS;
    }
    const rc = std.posix.system.isatty(1);
    return std.posix.errno(rc - 1) == .SUCCESS;
}

fn pathBasename(path: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, path, '/')) |idx| path[idx + 1 ..] else path;
}

/// Set by runWrapperInner to communicate raw stdout+stderr bytes to runWrapper.
var last_input_bytes: usize = 0;
var last_output_inherited: bool = false;
/// Coarse dispatch label for `--explain` / `SMLL_DEBUG=1`. Each top-level
/// command-family arm in runWrapperInner sets this before its filter runs;
/// the default "passthrough" stands for head/tail, lossless mode, and any
/// command that no bespoke arm claims. Granularity is intentionally
/// command-family level for v1 — the in/out byte counts in the `--explain`
/// footer already reveal whether compaction actually happened.
var last_filter_name: []const u8 = "passthrough";
/// Raw child streams stashed for the tee-recovery hook in `runWrapper`. The
/// slices remain valid for the wrapper's lifetime (arena-owned) but only the
/// outermost `runWrapper` call reads them, so module-level state is safe.
var last_raw_stdout: []const u8 = &.{};
var last_raw_stderr: []const u8 = &.{};

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
        var compact = std.Io.Writer.Allocating.init(allocator);
        defer compact.deinit();
        generic_compact.apply(allocator, stdout_slice, &compact.writer) catch {
            try writer.writeAll(stdout_slice);
            return;
        };
        try writer.writeAll(compact.written());
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
    original_argv: []const []const u8,
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
    const invocation = wrapper_util.classifyInvocation(original_argv);
    const argv = invocation.logical_argv;
    const outer_cmd = argv[0];
    const cmd_basename = if (std.mem.findScalarLast(u8, outer_cmd, '/')) |idx|
        outer_cmd[idx + 1 ..]
    else
        outer_cmd;
    last_filter_name = cmd_basename;

    const lossless = envFlagOn(environ, "SMLL_LOSSLESS");
    var ls_env_map = std.process.Environ.Map.init(allocator);
    var ls_env_map_active = false;
    defer if (ls_env_map_active) ls_env_map.deinit();
    const spawn_env: ?*const std.process.Environ.Map = blk: {
        if (std.mem.eql(u8, cmd_basename, "ls") and
            !lossless and invocation.passthrough_reason == null and !lsRequestsExactOutput(argv))
        {
            ls_env_map = environ.clone(allocator) catch break :blk null;
            ls_env_map_active = true;
            ls_env_map.put("LC_ALL", "C") catch break :blk null;
            ls_env_map.put("LANG", "C") catch break :blk null;
            break :blk &ls_env_map;
        }
        break :blk null;
    };

    // Detect commands that must not be buffered. These get stdout+stderr
    // inherited directly — no capture, no filtering, no size cap. This includes
    // explicit lossless mode, streaming/interactive commands, and non-verbose
    // curl where stdout may be an API body, archive, or install script.
    const is_raw_curl = std.mem.eql(u8, cmd_basename, "curl") and !curl_compact.hasVerboseFlag(argv);
    const is_streaming = lossless or invocation.passthrough_reason != null or isStreamingCommand(cmd_basename, argv) or is_raw_curl;
    if (is_streaming) {
        last_output_inherited = true;
        last_filter_name = "passthrough";
        last_input_bytes = 0;
        var child = std.process.spawn(io, .{
            .argv = original_argv,
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
        .argv = original_argv,
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
            stderr_writer.writeAll(max_output_label) catch {};
            return 1;
        },
        else => return err,
    };
    const stdout_slice = captured.stdout;
    const stderr_slice = captured.stderr;

    // Record raw stream sizes for stats tracking and empty-output detection.
    last_input_bytes = stdout_slice.len + stderr_slice.len;
    last_raw_stdout = stdout_slice;
    last_raw_stderr = stderr_slice;

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
    const arg2 = if (argv.len >= 3) argv[2] else "";
    const arg3 = if (argv.len >= 4) argv[3] else "";

    // Transparent package runners can emit their own setup prelude before the
    // inner tool starts. In that specific shape, preserve the established
    // package error filter instead of handing runner diagnostics to the inner
    // pytest/ruff/etc. parser. Ordinary inner failures have no package prelude
    // and continue through their dedicated filter.
    const is_transparent_runner = argv.ptr != original_argv.ptr;
    if (!lossless and is_transparent_runner and
        (hasPackagePrelude(stdout_slice) or hasPackagePrelude(stderr_slice)))
    {
        if (!applyFilter(tool_compact.applyPackage, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        return exit_code;
    }

    // Path-list wrappers (rg --files, find): path-per-line output, compresses
    // via dirname RLE. `find -ls` goes through find_compact instead
    // (columnar inode/mode/size/path → path-only). SMLL_LOSSLESS=1 bypasses
    // both.
    const is_rg_cmd = std.mem.eql(u8, cmd_basename, "rg");
    const is_find_cmd = std.mem.eql(u8, cmd_basename, "find");
    if (is_rg_cmd or is_find_cmd) {
        const is_find_ls = is_find_cmd and hasArg(argv, "-ls");
        const is_find_print0 = is_find_cmd and hasArg(argv, "-print0");
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
            if (!applyFilter(find_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (is_find_plain and !is_find_print0 and find_compact.matchesPlain(stdout_slice)) {
            if (findHasTypeFile(argv)) {
                if (!applyFilter(find_compact.applyPlainFiles, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            } else {
                if (!applyFilter(find_compact.applyPlainEntries, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            }
        } else if (rg.matchesPattern(stdout_slice)) {
            if (!applyFilter(rg.applyPattern, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if ((is_rg_files_mode or is_find_plain) and rg.matches(stdout_slice)) {
            if (!applyFilter(rg.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    // Package dependency tree wrappers. `bun pm ls` emits a nested dependency
    // tree; default output keeps direct deps + transitive count so agents get
    // dependency signal without the full nested tree.
    if (std.mem.eql(u8, cmd_basename, "bun") and
        std.mem.eql(u8, arg1, "pm") and
        std.mem.eql(u8, arg2, "ls") and
        !lossless and
        package_tree.matches(stdout_slice))
    {
        if (!applyFilter(package_tree.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        return exit_code;
    }

    // `npm ls`/`npm list`, `pnpm ls`/`pnpm list`, and `yarn list` print the same
    // shape: root context plus a (possibly deep) dependency tree. Route the
    // `ls`/`list` subcommand through the same direct-deps + transitive-count
    // summary. Argv-gated so install/add output is never touched here.
    if (!lossless and
        ((eqAny(cmd_basename, &.{ "npm", "pnpm" }) and eqAny(arg1, &.{ "ls", "list" })) or
            (std.mem.eql(u8, cmd_basename, "yarn") and std.mem.eql(u8, arg1, "list"))) and
        package_tree.matches(stdout_slice))
    {
        if (!applyFilter(package_tree.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        return exit_code;
    }

    // tree wrapper: matches Unicode box-drawing and ASCII `|--` / `` `-- ``
    // tree output. `bun` can emit other tree-shaped output; route it through
    // tree when the package-tree filter above did not match.
    if (std.mem.eql(u8, cmd_basename, "tree") or
        std.mem.eql(u8, cmd_basename, "bun"))
    {
        if (tree.matches(stdout_slice)) {
            if (!applyFilter(tree.applyCompact, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
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
    const is_js_script_test = is_test_subcmd and eqAny(cmd_basename, &.{ "npm", "pnpm", "yarn", "bun" });
    // jest/vitest: direct invocation OR script runners that produce jest-shaped
    // output. Mocha/node:test run after this and only claim their own shapes.
    const is_jest = eqAny(cmd_basename, &.{ "jest", "vitest" }) or is_js_script_test;
    const is_js_test = is_js_script_test or
        std.mem.eql(u8, cmd_basename, "mocha") or
        (std.mem.eql(u8, cmd_basename, "node") and std.mem.eql(u8, arg1, "--test"));
    const is_tsc = std.mem.eql(u8, cmd_basename, "tsc");
    const is_go_test = is_test_subcmd and std.mem.eql(u8, cmd_basename, "go");
    if (is_pytest or is_cargo_test or is_jest or is_js_test or is_tsc or is_go_test) {
        if (!lossless) {
            if (is_pytest and (pytest.matches(stdout_slice) or pytest.matches(stderr_slice))) {
                if (!applyFilter(pytest.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
                return exit_code;
            }
            if (is_cargo_test and (cargo_test.matches(stdout_slice) or cargo_test.matches(stderr_slice))) {
                if (!applyFilter(cargo_test.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
                return exit_code;
            }
            if (is_jest and (jest.matches(stdout_slice) or jest.matches(stderr_slice))) {
                if (!applyFilter(jest.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
                return exit_code;
            }
            if (is_js_test and (js_test.matches(stdout_slice) or js_test.matches(stderr_slice))) {
                if (!applyFilter(js_test.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
                return exit_code;
            }
            if (is_tsc and (tsc.matches(stdout_slice) or tsc.matches(stderr_slice))) {
                if (!applyFilter(tsc.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
                return exit_code;
            }
            if (is_go_test and (go_test.matches(stdout_slice) or go_test.matches(stderr_slice))) {
                if (!applyFilter(go_test.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
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
            if (!applyFilter(mypy_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "ruff")) {
        if (!lossless) {
            if (!applyFilter(ruff_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "head", "tail" })) {
        passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "gh")) {
        // Sub-shape dispatch keyed on argv: `gh pr view`, `gh pr checks`, and
        // `gh run view` get bespoke handlers; everything else keeps the generic
        // table / keep-filter path. `gh pr checks` exits non-zero on a failing
        // check but writes to stdout (empty stderr), so it still compacts.
        const is_pr = std.mem.eql(u8, arg1, "pr");
        const is_run = std.mem.eql(u8, arg1, "run");
        if (exit_code != 0 and stderr_slice.len > 0) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (lossless) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (is_pr and std.mem.eql(u8, arg2, "view")) {
            if (!applyFilter(gh_compact.applyPrView, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            try stderr_writer.writeAll(stderr_slice);
        } else if (is_pr and std.mem.eql(u8, arg2, "checks")) {
            if (!applyFilter(gh_compact.applyPrChecks, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            try stderr_writer.writeAll(stderr_slice);
        } else if (is_run and std.mem.eql(u8, arg2, "view")) {
            if (!applyFilter(gh_compact.applyRunView, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            try stderr_writer.writeAll(stderr_slice);
        } else if (ghWantsDataOutput(argv)) {
            if (stderr_slice.len == 0 and json_compact.matches(stdout_slice)) {
                if (!applyFilter(json_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            } else {
                try writer.writeAll(stdout_slice);
                try stderr_writer.writeAll(stderr_slice);
            }
        } else {
            if (!try writeGenericTableIfUseful(allocator, stdout_slice, writer)) {
                if (!applyFilter(tool_compact.applyGh, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            }
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "pnpm", "yarn", "bun", "uv", "uvx" })) {
        const is_js_pkg_manager = eqAny(cmd_basename, &.{ "pnpm", "yarn", "bun" });
        // For JS-pkg-manager install subcommands, the bespoke npm_install
        // filter drops manager-specific chatter (Progress:, banner, dep trees)
        // that tool_compact.applyPackage's substring keep would let survive.
        const is_js_install_subcmd = is_js_pkg_manager and
            eqAny(arg1, &.{ "install", "i", "add", "remove", "rm" });
        // `<manager> build` or `<manager> run build` — content signature
        // (Vite/Next/Nuxt/webpack banners, shared finalizers) confirms it is a
        // real build pipeline before we compact.
        const is_build_subcmd = is_js_pkg_manager and
            (std.mem.eql(u8, arg1, "build") or
                (std.mem.eql(u8, arg1, "run") and argv.len >= 3 and std.mem.eql(u8, argv[2], "build")));
        if (!lossless and is_build_subcmd and build_output.matches(stdout_slice)) {
            if (!applyFilter(build_output.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            return exit_code;
        } else if (!lossless and is_build_subcmd and build_output.matches(stderr_slice)) {
            if (!applyFilter(build_output.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            return exit_code;
        }
        if (exit_code != 0 and stderr_slice.len > 0 and !isBunScriptEchoOnly(cmd_basename, stderr_slice)) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (!lossless and is_js_install_subcmd and npm_install.matches(stdout_slice)) {
            if (!applyFilter(npm_install.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and is_js_install_subcmd and npm_install.matches(stderr_slice)) {
            if (!applyFilter(npm_install.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless) {
            if (!applyFilter(tool_compact.applyPackage, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "turbo")) {
        if (!lossless and (build_output.matches(stdout_slice) or build_output.matches(stderr_slice))) {
            if (!applyFilter(build_output.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
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
            if (!applyFilter(npm_install.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and is_composer_install_subcmd and npm_install.matches(stderr_slice)) {
            if (!applyFilter(npm_install.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "swift", "xcodebuild" })) {
        if (exit_code != 0 and stderr_slice.len > 0) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (!lossless) {
            if (!applyFilter(tool_compact.applyAppleBuild, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "dotnet")) {
        if (!lossless and eqAny(arg1, &.{ "build", "test", "format", "restore" }) and
            !dotnet_compact.isQueryInvocation(argv))
        {
            if (!applyFilter(dotnet_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "gradle", "gradlew" })) {
        if (!lossless and (gradle_compact.matches(stdout_slice) or gradle_compact.matches(stderr_slice))) {
            if (!applyFilter(gradle_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "mvn", "mvnw" })) {
        if (!lossless and (maven_compact.matches(stdout_slice) or maven_compact.matches(stderr_slice))) {
            if (!applyFilter(maven_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "pre-commit")) {
        if (!lossless and (precommit_compact.matches(stdout_slice) or precommit_compact.matches(stderr_slice))) {
            if (!applyFilter(precommit_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "prettier")) {
        if (!lossless) {
            if (!applyFilter(prettier_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "eslint", "biome" })) {
        if (!lossless and (lint_compact.matches(stdout_slice) or lint_compact.matches(stderr_slice))) {
            if (!applyFilter(lint_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "pip", "pip3" })) {
        const is_pip_table = eqAny(arg1, &.{ "list", "outdated" });
        const is_pip_install = eqAny(arg1, &.{ "install", "download", "wheel" });
        if (!lossless and (is_pip_table or (is_pip_install and (pip_compact.matches(stdout_slice) or pip_compact.matches(stderr_slice))))) {
            if (!applyFilter(pip_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "webpack")) {
        if (!lossless and (build_output.matches(stdout_slice) or build_output.matches(stderr_slice))) {
            if (!applyFilter(build_output.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "next") and std.mem.eql(u8, arg1, "build")) {
        if (!lossless and (build_output.matches(stdout_slice) or build_output.matches(stderr_slice))) {
            if (!applyFilter(build_output.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "terraform", "tofu" }) and std.mem.eql(u8, arg1, "plan")) {
        if (!lossless and (plan_compact.matches(stdout_slice) or plan_compact.matches(stderr_slice))) {
            if (!applyFilter(plan_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    if (eqAny(cmd_basename, &.{ "aws", "jq" })) {
        if (!lossless and stderr_slice.len == 0 and json_compact.matches(stdout_slice)) {
            if (!applyFilter(json_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "pup")) {
        if (lossless or exit_code != 0) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (stderr_slice.len == 0 and json_compact.matches(stdout_slice)) {
            if (!applyFilter(json_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (tool_compact.matchesPupTable(stdout_slice)) {
            if (!applyFilter(tool_compact.applyPupTable, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            try stderr_writer.writeAll(stderr_slice);
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "acli")) {
        const is_jira_workitem = std.mem.eql(u8, arg1, "jira") and std.mem.eql(u8, arg2, "workitem");
        const is_confluence_page = std.mem.eql(u8, arg1, "confluence") and std.mem.eql(u8, arg2, "page");
        const is_confluence_space = std.mem.eql(u8, arg1, "confluence") and std.mem.eql(u8, arg2, "space");
        if (lossless or exit_code != 0) {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        } else if (stderr_slice.len == 0 and json_compact.matches(stdout_slice)) {
            if (!applyFilter(json_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (is_jira_workitem and std.mem.eql(u8, arg3, "search")) {
            if (!applyAcliFilter(acli_compact.applyJiraWorkitemSearch, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            try stderr_writer.writeAll(stderr_slice);
        } else if (is_jira_workitem and std.mem.eql(u8, arg3, "view")) {
            if (!applyAcliFilter(acli_compact.applyJiraWorkitemView, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            try stderr_writer.writeAll(stderr_slice);
        } else if (is_confluence_page and std.mem.eql(u8, arg3, "view")) {
            if (!applyAcliFilter(acli_compact.applyConfluencePageView, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            try stderr_writer.writeAll(stderr_slice);
        } else if (is_confluence_space and std.mem.eql(u8, arg3, "list")) {
            if (!applyAcliFilter(acli_compact.applyConfluenceSpaceList, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            try stderr_writer.writeAll(stderr_slice);
        } else {
            try writeWithFallbackText(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    // env wrapper — mask sensitive variables for environment-listing forms.
    // Do not filter `env FOO=bar command`: that form executes an arbitrary
    // child command and its stdout should keep the command's semantics.
    if (std.mem.eql(u8, cmd_basename, "env") and isEnvListingInvocation(argv)) {
        if (!lossless) {
            if (!applyFilter(env_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
        }
        return exit_code;
    }

    // wc wrapper — collapse padding while preserving counts, filenames, and stderr.
    if (std.mem.eql(u8, cmd_basename, "wc")) {
        if (!lossless) {
            if (!applyFilter(wc_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
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
            if (!applyFilter(curl_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
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
            var compact = std.Io.Writer.Allocating.init(allocator);
            defer compact.deinit();
            du_compact.apply(allocator, stdout_slice, stderr_slice, &compact.writer, sort_desc) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return exit_code;
            };
            try writer.writeAll(compact.written());
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
            // Long format (`ls -l`/`-la`): filenames-only summary.
            var compact = std.Io.Writer.Allocating.init(allocator);
            defer compact.deinit();
            ls_compact.apply(allocator, stdout_slice, stderr_slice, &compact.writer) catch |err| {
                if (err == error.ParsedNothing) {
                    try writeWithFallback(allocator, stdout_slice, writer);
                } else {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return exit_code;
                }
                try stderr_writer.writeAll(stderr_slice);
                return exit_code;
            };
            try writer.writeAll(compact.written());
        } else if (!lossless) {
            // Plain `ls` (no `-l`): one-name-per-line normalization, `.`/`..`
            // dropped, multi-directory listings collapsed per dir. Argv proves
            // the source, so `-C`/`-x`/`-m` column splitting is safe here.
            var compact = std.Io.Writer.Allocating.init(allocator);
            defer compact.deinit();
            ls_compact.applyPlain(allocator, stdout_slice, stderr_slice, &compact.writer, ls_compact.wantsColumns(argv)) catch |err| {
                if (err == error.ParsedNothing) {
                    try writeWithFallback(allocator, stdout_slice, writer);
                } else {
                    passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                    return exit_code;
                }
                try stderr_writer.writeAll(stderr_slice);
                return exit_code;
            };
            try writer.writeAll(compact.written());
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
    if (eqAny(cmd_basename, &.{ "docker", "docker-compose", "kubectl", "gh", "ps", "df", "psql", "systemctl", "lsof", "npm", "pnpm", "yarn", "brew", "bun" })) {
        const is_docker_cmd = std.mem.eql(u8, cmd_basename, "docker");
        const is_docker_compose_v1 = std.mem.eql(u8, cmd_basename, "docker-compose");
        const is_docker_compose_v2 = is_docker_cmd and std.mem.eql(u8, arg1, "compose");
        const docker_subcmd = if (is_docker_compose_v2) arg2 else arg1;
        const is_docker_images = is_docker_cmd and std.mem.eql(u8, arg1, "images");
        const is_logs_subcmd = std.mem.eql(u8, arg1, "logs");
        // docker logs <container> — line dedup (before docker ps table dispatch).
        const is_docker_logs = is_logs_subcmd and is_docker_cmd;
        const is_docker_compose_logs = (is_docker_compose_v1 or is_docker_compose_v2) and std.mem.eql(u8, docker_subcmd, "logs");
        // kubectl logs <pod> — same grammar, same filter.
        const is_kubectl_logs = is_logs_subcmd and std.mem.eql(u8, cmd_basename, "kubectl");
        // JS package manager installs — npm/pnpm/yarn/bun {install,i,ci,add,remove,rm}.
        // Keep summary + warnings, drop banners/progress/dep trees.
        const is_install_subcmd = eqAny(arg1, &.{ "install", "i", "ci", "add", "remove", "rm" });
        const is_js_pkg_manager = eqAny(cmd_basename, &.{ "npm", "pnpm", "yarn", "bun" });
        const is_js_install = is_js_pkg_manager and is_install_subcmd;
        // JS package manager build — npm/pnpm/yarn/bun build (or run build).
        // Content signature confirms we have a real bundler pipeline before
        // routing through build_output.
        const is_js_build = is_js_pkg_manager and
            (std.mem.eql(u8, arg1, "build") or
                (std.mem.eql(u8, arg1, "run") and argv.len >= 3 and std.mem.eql(u8, argv[2], "build")));
        if (!lossless and is_docker_compose_logs) {
            if (!applyFilter(docker_logs.applyCompose, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and (is_docker_logs or is_kubectl_logs)) {
            if (!applyFilter(docker_logs.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and is_docker_images and docker_compact.matchesImages(stdout_slice)) {
            if (!applyFilter(docker_compact.applyImages, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and is_js_build and build_output.matches(stdout_slice)) {
            if (!applyFilter(build_output.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and is_js_build and build_output.matches(stderr_slice)) {
            if (!applyFilter(build_output.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and is_js_install and npm_install.matches(stdout_slice)) {
            if (!applyFilter(npm_install.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and is_js_install and npm_install.matches(stderr_slice)) {
            // Several managers write progress + warnings to stderr (npm classic, yarn,
            // pnpm). Dispatch off stderr when stdout doesn't match but stderr does.
            if (!applyFilter(npm_install.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
            return exit_code;
        } else if (!lossless and (is_docker_cmd or is_docker_compose_v1) and docker_compact.matches(stdout_slice)) {
            if (!applyFilter(docker_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and std.mem.eql(u8, cmd_basename, "kubectl") and kubectl_compact.matches(stdout_slice)) {
            if (!applyFilter(kubectl_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else if (!lossless and columnar.matches(stdout_slice)) {
            if (!applyFilter(columnar.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
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

    // Build-chatter wrapper: `make`, `ninja`, `cargo build`/`check`/`clippy`, `go build` — LOSSY
    // compaction by default (v0.6). Collapses `Compiling X` / `cc -c X.o`
    // / `go build: X` progress lines into a summary count; warnings and
    // errors pass through verbatim. Stream-placement: cargo/go emit
    // progress on stderr, make splits; the filter inspects both. Gate by
    // `!SMLL_LOSSLESS`. `bun` is explicitly excluded.
    const is_make = std.mem.eql(u8, cmd_basename, "make");
    const is_ninja = std.mem.eql(u8, cmd_basename, "ninja");
    const is_build_subcmd = std.mem.eql(u8, arg1, "build");
    const is_cargo_build = eqAny(arg1, &.{ "build", "check", "clippy" }) and std.mem.eql(u8, cmd_basename, "cargo");
    const is_go_build = is_build_subcmd and std.mem.eql(u8, cmd_basename, "go");
    const is_zig_build = is_build_subcmd and std.mem.eql(u8, cmd_basename, "zig");
    if (is_make or is_ninja or is_cargo_build or is_go_build or is_zig_build) {
        if (!lossless and build_compact.matches(stdout_slice, stderr_slice)) {
            if (!applyFilter(build_compact.apply, allocator, stdout_slice, stderr_slice, writer, stderr_writer)) return exit_code;
        } else {
            try writeWithFallback(allocator, stdout_slice, writer);
            try stderr_writer.writeAll(stderr_slice);
        }
        return exit_code;
    }

    // cat wrapper: compress code output, pass through data files.
    if (std.mem.eql(u8, cmd_basename, "cat")) {
        if (!lossless and cat_compact.matches(stdout_slice)) {
            var compact = std.Io.Writer.Allocating.init(allocator);
            defer compact.deinit();
            cat_compact.apply(allocator, stdout_slice, stderr_slice, &compact.writer, argv) catch {
                passthrough(writer, stderr_writer, stdout_slice, stderr_slice);
                return exit_code;
            };
            try writer.writeAll(compact.written());
        } else {
            try writeWithFallback(allocator, stdout_slice, writer);
        }
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

    if (std.mem.eql(u8, cmd_basename, "git") and argv.len >= 2) {
        return wrapper_git.dispatch(
            allocator,
            argv,
            stdout_slice,
            stderr_slice,
            lossless,
            exit_code,
            writer,
            stderr_writer,
        );
    }

    // `sh -c "<cmd>"` (and bash/zsh): agents wrap arbitrary commands in a shell,
    // which erases the outer-argv signal every bespoke arm above relies on. So
    // route the captured stdout through the pipe-mode content-detection chain —
    // the exact first-match-wins dispatcher stdin uses — and let the output's
    // own shape pick a filter. A content filter only fires when the *combined*
    // output still matches its grammar, so `cmd1 && cmd2` mixed output safely
    // falls through to GenericCompactPipe (the chain's size-gated catch-all,
    // identical to the generic fallback below). Interactive/login shells are
    // skipped (both short `-i`/`-l` and the bash/zsh long forms `--interactive`/
    // `--login`): their output is for humans and may mix in prompt, job-control,
    // or profile-script (`~/.bash_profile`, `/etc/zprofile`) noise that could
    // trip a filter. SMLL_LOSSLESS=1 is honored by the `!lossless` guard.
    if (!lossless and
        eqAny(cmd_basename, &.{ "sh", "bash", "zsh" }) and
        hasArg(argv, "-c") and
        !hasArg(argv, "-i") and
        !hasArg(argv, "--interactive") and
        !hasArg(argv, "-l") and
        !hasArg(argv, "--login"))
    {
        // Fail open to raw stdout on any dispatch error — never drop output.
        pipeline.dispatch(allocator, stdout_slice, writer, pipe_filters.Filters) catch {
            try writer.writeAll(stdout_slice);
        };
        try stderr_writer.writeAll(stderr_slice);
        return exit_code;
    }

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

fn isBunScriptEchoOnly(cmd_basename: []const u8, stderr_slice: []const u8) bool {
    if (!std.mem.eql(u8, cmd_basename, "bun")) return false;
    var saw_echo = false;
    var lines = std.mem.splitScalar(u8, stderr_slice, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "$ ")) return false;
        saw_echo = true;
    }
    return saw_echo;
}
