const std = @import("std");

pub fn envFlagOn(environ_map: *const std.process.Environ.Map, name: []const u8) bool {
    const v = environ_map.get(name) orelse return false;
    return v.len > 0 and v[0] == '1';
}

/// Tee recovery is on by default; users opt out with `SMLL_TEE=0` or
/// with the conventional `DO_NOT_TRACK=1`.
pub fn teeEnabled(environ_map: *const std.process.Environ.Map) bool {
    if (envFlagOn(environ_map, "DO_NOT_TRACK")) return false;
    const v = environ_map.get("SMLL_TEE") orelse return true;
    if (v.len > 0 and v[0] == '0') return false;
    return true;
}

pub fn hasArg(argv: []const []const u8, arg: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, arg)) return true;
    return false;
}

fn isEnvAssignment(arg: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return false;
    return eq > 0;
}

pub fn isEnvListingInvocation(argv: []const []const u8) bool {
    for (argv[1..]) |arg| {
        if (arg.len == 0) continue;
        if (arg[0] == '-') continue;
        if (isEnvAssignment(arg)) continue;
        return false;
    }
    return true;
}

pub fn hasFormatOrPrettyArg(argv: []const []const u8) bool {
    for (argv) |a| {
        if (std.mem.startsWith(u8, a, "--format=") or
            std.mem.startsWith(u8, a, "--pretty=") or
            std.mem.eql(u8, a, "--format") or
            std.mem.eql(u8, a, "--pretty")) return true;
    }
    return false;
}

pub const PassthroughReason = enum {
    query,
    machine_output,
    ambiguous_runner,
};

pub const Invocation = struct {
    /// Borrowed view used only for classification and filter dispatch. The
    /// caller must still spawn and record the original argv.
    logical_argv: []const []const u8,
    passthrough_reason: ?PassthroughReason = null,
};

pub fn classifyInvocation(argv: []const []const u8) Invocation {
    if (argv.len == 0) return .{ .logical_argv = argv };
    const cmd = pathBasename(argv[0]);
    var logical = argv;
    var ambiguous_runner = false;

    if (std.mem.eql(u8, cmd, "uv") and argv.len >= 2 and std.mem.eql(u8, argv[1], "run")) {
        logical = unwrapDirectRunner(argv, 2, uvValueOptions(), uvBooleanOptions(), &.{}) orelse blk: {
            ambiguous_runner = true;
            break :blk argv;
        };
    } else if (std.mem.eql(u8, cmd, "uvx")) {
        logical = unwrapDirectRunner(argv, 1, uvxValueOptions(), uvBooleanOptions(), &.{}) orelse blk: {
            ambiguous_runner = true;
            break :blk argv;
        };
    } else if (std.mem.eql(u8, cmd, "poetry")) {
        logical = unwrapSubcommandRunner(
            argv,
            1,
            "run",
            &.{ "-C", "--directory", "-P", "--project" },
            &.{ "--no-interaction", "--no-ansi", "-q", "--quiet" },
        ) orelse blk: {
            ambiguous_runner = true;
            break :blk argv;
        };
    } else if (std.mem.eql(u8, cmd, "pnpm") and argv.len >= 2 and
        (containsArgBeforeSeparator(argv, "exec") or (argv[1].len > 0 and argv[1][0] == '-')))
    {
        logical = unwrapSubcommandRunner(
            argv,
            1,
            "exec",
            &.{ "-C", "--dir", "-F", "--filter", "--workspace-concurrency" },
            &.{ "-r", "--recursive", "-w", "--workspace-root", "--parallel", "--stream", "--aggregate-output", "--use-stderr" },
        ) orelse blk: {
            ambiguous_runner = true;
            break :blk argv;
        };
    } else if (std.mem.eql(u8, cmd, "npx")) {
        logical = unwrapDirectRunner(
            argv,
            1,
            &.{ "-p", "--package", "-w", "--workspace", "--allow-scripts" },
            &.{ "-y", "--yes", "--no", "--workspaces", "--include-workspace-root", "--strict-allow-scripts", "--dangerously-allow-all-scripts" },
            &.{ "-c", "--call" },
        ) orelse blk: {
            ambiguous_runner = true;
            break :blk argv;
        };
    }

    if (ambiguous_runner) {
        return .{
            .logical_argv = logical,
            .passthrough_reason = exactOutputReason(cmd, argv) orelse .ambiguous_runner,
        };
    }
    const logical_cmd = pathBasename(logical[0]);
    return .{
        .logical_argv = logical,
        .passthrough_reason = exactOutputReason(logical_cmd, logical),
    };
}

fn pathBasename(path: []const u8) []const u8 {
    return if (std.mem.findScalarLast(u8, path, '/')) |idx| path[idx + 1 ..] else path;
}

fn uvValueOptions() []const []const u8 {
    return &.{ "--project", "--directory", "--python", "--package", "--with", "--with-editable", "--with-requirements", "--env-file", "--group", "--extra" };
}

fn uvxValueOptions() []const []const u8 {
    return &.{ "--project", "--directory", "--python", "--package", "--with", "--with-editable", "--with-requirements", "--env-file", "--group", "--extra", "--from" };
}

fn uvBooleanOptions() []const []const u8 {
    return &.{ "--isolated", "--active", "--no-sync", "--locked", "--frozen", "--no-project", "--all-extras", "--no-dev", "--no-progress", "--offline" };
}

fn unwrapDirectRunner(
    argv: []const []const u8,
    start_index: usize,
    value_options: []const []const u8,
    boolean_options: []const []const u8,
    opaque_options: []const []const u8,
) ?[]const []const u8 {
    const tool_index = scanRunnerOptions(argv, start_index, value_options, boolean_options, opaque_options, null) orelse return null;
    return toolSlice(argv, tool_index);
}

fn unwrapSubcommandRunner(
    argv: []const []const u8,
    start_index: usize,
    subcommand: []const u8,
    value_options: []const []const u8,
    boolean_options: []const []const u8,
) ?[]const []const u8 {
    const subcommand_index = scanRunnerOptions(argv, start_index, value_options, boolean_options, &.{}, subcommand) orelse return null;
    if (subcommand_index >= argv.len or !std.mem.eql(u8, argv[subcommand_index], subcommand)) return null;
    return toolSlice(argv, subcommand_index + 1);
}

fn scanRunnerOptions(
    argv: []const []const u8,
    start_index: usize,
    value_options: []const []const u8,
    boolean_options: []const []const u8,
    opaque_options: []const []const u8,
    stop_at: ?[]const u8,
) ?usize {
    var index = start_index;
    while (index < argv.len) {
        const arg = argv[index];
        if (stop_at) |stop| if (std.mem.eql(u8, arg, stop)) return index;
        if (std.mem.eql(u8, arg, "--")) return if (stop_at == null) index + 1 else null;
        if (arg.len == 0 or arg[0] != '-') return if (stop_at == null) index else null;
        if (optionMatches(arg, opaque_options) != .none) return null;
        if (matchesBooleanOption(arg, boolean_options)) {
            index += 1;
            continue;
        }
        switch (optionMatches(arg, value_options)) {
            .inline_value => index += 1,
            .separate => {
                if (index + 1 >= argv.len) return null;
                index += 2;
            },
            .none => return null,
        }
    }
    return null;
}

fn toolSlice(argv: []const []const u8, raw_index: usize) ?[]const []const u8 {
    var index = raw_index;
    if (index < argv.len and std.mem.eql(u8, argv[index], "--")) index += 1;
    if (index >= argv.len or argv[index].len == 0 or argv[index][0] == '-') return null;
    return argv[index..];
}

const OptionMatch = enum { none, separate, inline_value };

fn matchesBooleanOption(arg: []const u8, options: []const []const u8) bool {
    switch (optionMatches(arg, options)) {
        .none => return false,
        .separate => return true,
        .inline_value => {},
    }

    if (arg.len <= 2 or arg[0] != '-' or arg[1] == '-') return false;
    for (arg[1..]) |flag| {
        var known = false;
        for (options) |option| {
            if (option.len == 2 and option[0] == '-' and option[1] == flag) {
                known = true;
                break;
            }
        }
        if (!known) return false;
    }
    return true;
}

fn optionMatches(arg: []const u8, options: []const []const u8) OptionMatch {
    for (options) |option| {
        if (std.mem.eql(u8, arg, option)) return .separate;
        if (option.len > 2 and std.mem.startsWith(u8, option, "--") and
            std.mem.startsWith(u8, arg, option) and arg.len > option.len and arg[option.len] == '=') return .inline_value;
        if (option.len == 2 and option[0] == '-' and arg.len > 2 and std.mem.startsWith(u8, arg, option)) return .inline_value;
    }
    return .none;
}

fn exactOutputReason(cmd: []const u8, argv: []const []const u8) ?PassthroughReason {
    if (isQueryInvocation(cmd, argv)) return .query;
    if (wantsMachineOutput(cmd, argv)) return .machine_output;
    return null;
}

/// Commands that describe the tool itself are queries, not human-oriented
/// command output. `-h` is deliberately not universal: ps uses it for
/// headerless output and psql uses it to select a host.
fn isQueryInvocation(cmd: []const u8, argv: []const []const u8) bool {
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (eqAny(arg, &.{ "--help", "--version" })) return true;
        if (std.mem.eql(u8, arg, "-h") and
            eqAny(cmd, &.{ "pytest", "ruff", "mypy", "prettier", "uv", "uvx", "poetry", "pnpm", "npx", "jq" })) return true;
    }
    if (argv.len < 2) return false;
    if (eqAny(argv[1], &.{ "help", "version" })) return true;
    if (hasAnyArg(argv, &.{"-V"}) and
        eqAny(cmd, &.{ "pytest", "ruff", "mypy", "prettier", "uv", "uvx", "poetry", "pnpm", "npx", "jq" })) return true;
    if (std.mem.eql(u8, cmd, "pytest") and
        hasAnyArg(argv, &.{ "--collect-only", "--co", "--fixtures", "--fixtures-per-test", "--markers", "--trace-config" })) return true;
    if (std.mem.eql(u8, cmd, "ruff") and eqAny(argv[1], &.{ "rule", "config", "linter", "help", "version" })) return true;
    if (std.mem.eql(u8, cmd, "prettier") and
        hasAnyArg(argv, &.{ "--support-info", "--find-config-path", "--file-info" })) return true;
    if (std.mem.eql(u8, cmd, "tsc") and hasAnyArg(argv, &.{ "--showConfig", "--listFilesOnly" })) return true;
    return false;
}

fn wantsMachineOutput(cmd: []const u8, argv: []const []const u8) bool {
    if (std.mem.eql(u8, cmd, "rg")) {
        return hasAnyArg(argv, &.{ "--json", "--vimgrep", "-c", "--count", "--count-matches", "-l", "--files-with-matches", "--files-without-match", "--files", "--type-list", "-0", "--null", "--null-data", "-o", "--only-matching", "--passthru", "--stats" }) or
            hasOption(argv, "--replace", "-r", true);
    }
    if (std.mem.eql(u8, cmd, "kubectl")) {
        return hasOption(argv, "--output", "-o", true) or
            hasOption(argv, "--template", "", false) or
            hasOption(argv, "--label-columns", "-L", true) or
            hasOption(argv, "--sort-by", "", false) or
            hasAnyArg(argv, &.{ "--raw", "--no-headers", "--show-labels", "--output-watch-events", "--timestamps", "--prefix" });
    }
    if (eqAny(cmd, &.{ "docker", "docker-compose" })) {
        if (hasOption(argv, "--format", "", false) or hasAnyArg(argv, &.{ "-q", "--quiet", "--no-trunc" })) return true;
        if (std.mem.eql(u8, cmd, "docker-compose")) return argv.len >= 2 and std.mem.eql(u8, argv[1], "config");
        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "inspect")) return true;
        if (argv.len >= 3 and std.mem.eql(u8, argv[2], "inspect") and
            eqAny(argv[1], &.{ "container", "image", "network", "node", "plugin", "secret", "service", "volume", "manifest", "context" })) return true;
        return argv.len >= 3 and std.mem.eql(u8, argv[1], "compose") and std.mem.eql(u8, argv[2], "config");
    }
    if (std.mem.eql(u8, cmd, "aws")) {
        return hasOption(argv, "--output", "", false) or
            hasOption(argv, "--query", "", false) or
            hasOption(argv, "--cli-binary-format", "", false) or
            hasOption(argv, "--generate-cli-skeleton", "", false);
    }
    if (std.mem.eql(u8, cmd, "jq")) return true;
    if (std.mem.eql(u8, cmd, "ps")) {
        return hasOption(argv, "--format", "-o", true) or
            hasShortOption(argv, "-O") or
            hasOption(argv, "--cols", "", false) or
            hasOption(argv, "--columns", "", false) or
            hasOption(argv, "--width", "", false) or
            hasAnyArg(argv, &.{ "--headers", "--no-headers", "-w", "-ww" });
    }
    if (std.mem.eql(u8, cmd, "psql")) {
        return hasAnyArg(argv, &.{ "-A", "--no-align", "-t", "--tuples-only", "-z", "--field-separator-zero", "-0", "--record-separator-zero", "--csv", "-H", "--html", "-x", "--expanded" }) or
            shortBundleContains(argv, "Atz0Hx") or
            hasOption(argv, "--field-separator", "-F", true) or
            hasOption(argv, "--record-separator", "-R", true) or
            hasOption(argv, "--pset", "-P", true);
    }
    if (std.mem.eql(u8, cmd, "systemctl")) {
        return (argv.len >= 2 and eqAny(argv[1], &.{ "show", "is-active", "is-enabled", "is-failed" })) or
            hasOption(argv, "--property", "-p", true) or
            hasAnyArg(argv, &.{ "--value", "--no-legend", "--plain", "--full", "--show-types" }) or
            hasOption(argv, "--output", "-o", true);
    }
    return false;
}

fn hasAnyArg(argv: []const []const u8, needles: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        for (needles) |needle| {
            if (std.mem.eql(u8, arg, needle)) return true;
        }
    }
    return false;
}

fn containsArgBeforeSeparator(argv: []const []const u8, needle: []const u8) bool {
    return hasAnyArg(argv, &.{needle});
}

fn hasShortOption(argv: []const []const u8, short: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, short) or (arg.len > short.len and std.mem.startsWith(u8, arg, short))) return true;
    }
    return false;
}

fn hasOption(argv: []const []const u8, long: []const u8, short: []const u8, allow_joined_short: bool) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (long.len > 0 and (std.mem.eql(u8, arg, long) or
            (std.mem.startsWith(u8, arg, long) and arg.len > long.len and arg[long.len] == '='))) return true;
        if (short.len > 0 and std.mem.eql(u8, arg, short)) return true;
        if (allow_joined_short and short.len > 0 and arg.len > short.len and std.mem.startsWith(u8, arg, short)) return true;
    }
    return false;
}

fn shortBundleContains(argv: []const []const u8, needles: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (arg.len < 3 or arg[0] != '-' or arg[1] == '-') continue;
        if (std.mem.indexOfAny(u8, arg[1..], needles) != null) return true;
    }
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

pub fn isLikelyBinary(input: []const u8) bool {
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
    return high > 0 and !std.unicode.utf8ValidateSlice(sample);
}

pub fn curlBodyLooksBinary(stdout: []const u8, stderr: []const u8) bool {
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

pub fn eqAny(name: []const u8, options: []const []const u8) bool {
    for (options) |opt| if (std.mem.eql(u8, name, opt)) return true;
    return false;
}

fn allowsShortWatchFlag(cmd_basename: []const u8) bool {
    return eqAny(cmd_basename, &.{ "jest", "vitest", "tsc", "webpack", "nodemon" });
}

pub const StreamDecision = enum {
    capture,
    inherit,
    stream_filter,
};

fn hasFollowArg(argv: []const []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--follow") or
            std.mem.eql(u8, arg, "-f")) return true;
        if (std.mem.startsWith(u8, arg, "--follow=")) {
            const value = arg["--follow=".len..];
            if (!(std.mem.eql(u8, value, "0") or
                std.ascii.eqlIgnoreCase(value, "false") or
                std.ascii.eqlIgnoreCase(value, "no"))) return true;
        }
    }
    return false;
}

pub fn isDockerLogsFollow(cmd_basename: []const u8, argv: []const []const u8) bool {
    if (!hasFollowArg(argv)) return false;
    if (std.mem.eql(u8, cmd_basename, "docker")) {
        if (argv.len >= 2 and std.mem.eql(u8, argv[1], "logs")) return true;
        return argv.len >= 3 and std.mem.eql(u8, argv[1], "compose") and std.mem.eql(u8, argv[2], "logs");
    }
    return std.mem.eql(u8, cmd_basename, "docker-compose") and argv.len >= 2 and std.mem.eql(u8, argv[1], "logs");
}

pub fn isFollowLogsCommand(cmd_basename: []const u8, argv: []const []const u8) bool {
    if (isDockerLogsFollow(cmd_basename, argv)) return true;
    if (!hasFollowArg(argv)) return false;
    if (std.mem.eql(u8, cmd_basename, "kubectl")) {
        return argv.len >= 2 and std.mem.eql(u8, argv[1], "logs");
    }
    return eqAny(cmd_basename, &.{ "tail", "journalctl" });
}

pub fn isTscWatch(cmd_basename: []const u8, argv: []const []const u8) bool {
    return std.mem.eql(u8, cmd_basename, "tsc") and
        (hasArg(argv, "--watch") or hasArg(argv, "-w"));
}

pub fn isJsTestWatch(cmd_basename: []const u8, argv: []const []const u8) bool {
    return eqAny(cmd_basename, &.{ "jest", "vitest" }) and
        (hasArg(argv, "--watch") or hasArg(argv, "--watchAll") or hasArg(argv, "-w"));
}

pub fn isGhRunWatch(cmd_basename: []const u8, argv: []const []const u8) bool {
    return std.mem.eql(u8, cmd_basename, "gh") and argv.len >= 3 and
        std.mem.eql(u8, argv[1], "run") and std.mem.eql(u8, argv[2], "watch");
}

fn isKnownJsRunner(cmd_basename: []const u8) bool {
    return eqAny(cmd_basename, &.{ "npm", "pnpm", "yarn", "bun", "deno" });
}

fn isKnownDevServer(cmd_basename: []const u8) bool {
    return eqAny(cmd_basename, &.{ "vite", "next", "nuxt", "webpack" });
}

/// Classify commands that produce continuous output. `.stream_filter` is the
/// opt-in line-filter allowlist; `.inherit` stays raw to avoid buffering
/// interactive UIs and unsupported watchers.
pub fn classifyStreamCommand(cmd_basename: []const u8, argv: []const []const u8) StreamDecision {
    if (isFollowLogsCommand(cmd_basename, argv)) return .stream_filter;
    if (isTscWatch(cmd_basename, argv)) return .stream_filter;
    if (isJsTestWatch(cmd_basename, argv)) return .stream_filter;
    if (isGhRunWatch(cmd_basename, argv)) return .stream_filter;

    if ((hasArg(argv, "--watch") or hasArg(argv, "--watchAll")) and
        (allowsShortWatchFlag(cmd_basename) or isKnownJsRunner(cmd_basename) or isKnownDevServer(cmd_basename))) return .inherit;
    if (hasArg(argv, "-w") and allowsShortWatchFlag(cmd_basename)) return .inherit;

    if (argv.len >= 2) {
        const sub = argv[1];
        if (std.mem.eql(u8, sub, "watch") and
            (isKnownJsRunner(cmd_basename) or std.mem.eql(u8, cmd_basename, "cargo") or std.mem.eql(u8, cmd_basename, "gh"))) return .inherit;
        if (std.mem.eql(u8, cmd_basename, "go") and std.mem.eql(u8, sub, "run")) return .inherit;
        if (eqAny(sub, &.{ "dev", "serve", "start" }) and (isKnownJsRunner(cmd_basename) or isKnownDevServer(cmd_basename))) return .inherit;
    }

    if (argv.len >= 3) {
        const sub = argv[1];
        const arg2 = argv[2];
        if (isKnownJsRunner(cmd_basename) and eqAny(sub, &.{ "run", "exec", "task" })) {
            if (eqAny(arg2, &.{ "dev", "serve", "start", "watch" })) return .inherit;
        }
    }

    if (eqAny(cmd_basename, &.{ "nodemon", "watchman" })) return .inherit;
    return .capture;
}

/// Detect streaming/interactive commands that produce continuous output and
/// must not be buffered in wrapper mode.
pub fn isStreamingCommand(cmd_basename: []const u8, argv: []const []const u8) bool {
    return classifyStreamCommand(cmd_basename, argv) != .capture;
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
    try std.testing.expect(!isStreamingCommand("grep", &.{ "grep", "--watch", "needle" }));
}

test "streaming classification: docker follow logs are stream-filterable" {
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("docker", &.{ "docker", "logs", "-f", "api" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("docker", &.{ "docker", "compose", "logs", "--follow" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("docker-compose", &.{ "docker-compose", "logs", "-f" }));
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("docker", &.{ "docker", "logs", "--follow=false", "api" }));
}

test "streaming classification: follow-mode logs are stream-filterable" {
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("kubectl", &.{ "kubectl", "logs", "-f", "deploy/api" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("tail", &.{ "tail", "-f", "/var/log/app.log" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("tail", &.{ "tail", "--follow=name", "/var/log/app.log" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("journalctl", &.{ "journalctl", "-f", "-u", "api.service" }));
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("kubectl", &.{ "kubectl", "logs", "--follow=false", "deploy/api" }));
}

test "streaming classification: tsc watch is stream-filterable" {
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("tsc", &.{ "tsc", "--watch" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("tsc", &.{ "tsc", "-w", "--noEmit" }));
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("tsc", &.{ "tsc", "--noEmit" }));
}

test "streaming classification: js test watch is stream-filterable" {
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("jest", &.{ "jest", "--watch" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("jest", &.{ "jest", "--watchAll" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("vitest", &.{ "vitest", "-w" }));
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("jest", &.{"jest"}));
}

test "streaming classification: gh run watch is stream-filterable" {
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("gh", &.{ "gh", "run", "watch" }));
    try std.testing.expectEqual(StreamDecision.stream_filter, classifyStreamCommand("gh", &.{ "gh", "run", "watch", "123" }));
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("gh", &.{ "gh", "run", "view", "123" }));
}

test "streaming classification: start is scoped to dev runners" {
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("docker", &.{ "docker", "start", "db" }));
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("systemctl", &.{ "systemctl", "start", "nginx" }));
    try std.testing.expectEqual(StreamDecision.inherit, classifyStreamCommand("npm", &.{ "npm", "run", "dev" }));
    try std.testing.expectEqual(StreamDecision.inherit, classifyStreamCommand("next", &.{ "next", "dev" }));
}

test "invocation classification: known runner options unwrap to a borrowed inner argv" {
    const Case = struct { original: []const []const u8, logical: []const []const u8 };
    const cases = [_]Case{
        .{
            .original = &.{ "uv", "run", "--project", "repo", "--directory=src", "--python", "3.12", "--package=pkg", "--with", "dep", "--with-editable=edit", "--with-requirements", "req.txt", "--env-file=.env", "--group", "dev", "--extra=cli", "--isolated", "--active", "--no-sync", "--locked", "--frozen", "--no-project", "--all-extras", "--no-dev", "--no-progress", "--offline", "--", "pytest", "--", "-q" },
            .logical = &.{ "pytest", "--", "-q" },
        },
        .{
            .original = &.{ "uvx", "--from", "ruff", "--project=repo", "--directory", "src", "--python=3.12", "--package", "pkg", "--with=dep", "--with-editable", "edit", "--with-requirements=req.txt", "--env-file", ".env", "--group=dev", "--extra", "cli", "--isolated", "ruff", "check" },
            .logical = &.{ "ruff", "check" },
        },
        .{
            .original = &.{ "poetry", "-C", "repo", "--directory=src", "-Pproject", "--project", "workspace", "--no-interaction", "--no-ansi", "-q", "--quiet", "run", "--", "pytest", "-q" },
            .logical = &.{ "pytest", "-q" },
        },
        .{
            .original = &.{ "pnpm", "-Crepo", "--dir", "src", "-Fpkg", "--filter=api", "--workspace-concurrency", "2", "-r", "--recursive", "-w", "--workspace-root", "--parallel", "--stream", "--aggregate-output", "--use-stderr", "exec", "--", "pytest", "-q" },
            .logical = &.{ "pytest", "-q" },
        },
        .{
            .original = &.{ "npx", "-p", "pytest", "--package=plugin", "-wrepo", "--workspace", "api", "--allow-scripts=pytest", "-y", "--yes", "--no", "--workspaces", "--include-workspace-root", "--strict-allow-scripts", "--dangerously-allow-all-scripts", "--", "pytest", "-q" },
            .logical = &.{ "pytest", "-q" },
        },
    };
    for (cases) |case| {
        const invocation = classifyInvocation(case.original);
        try std.testing.expectEqualDeep(case.logical, invocation.logical_argv);
        try std.testing.expectEqual(@as(?PassthroughReason, null), invocation.passthrough_reason);
    }
}

test "invocation classification: stacked short runner booleans unwrap" {
    const cases = [_]struct { original: []const []const u8, logical: []const []const u8 }{
        .{
            .original = &.{ "poetry", "-qq", "run", "pytest", "-q" },
            .logical = &.{ "pytest", "-q" },
        },
        .{
            .original = &.{ "pnpm", "-rw", "exec", "pytest", "-q" },
            .logical = &.{ "pytest", "-q" },
        },
    };
    for (cases) |case| {
        const invocation = classifyInvocation(case.original);
        try std.testing.expectEqualDeep(case.logical, invocation.logical_argv);
        try std.testing.expectEqual(@as(?PassthroughReason, null), invocation.passthrough_reason);
    }
}

test "invocation classification: unknown and opaque runner options stay exact" {
    const cases = [_][]const []const u8{
        &.{ "uv", "run", "--future", "value", "pytest" },
        &.{ "uvx", "--future", "value", "ruff" },
        &.{ "poetry", "--future", "run", "pytest" },
        &.{ "poetry", "-qz", "run", "pytest" },
        &.{ "poetry", "install" },
        &.{ "pnpm", "--future", "exec", "pytest" },
        &.{ "pnpm", "-rz", "exec", "pytest" },
        &.{ "pnpm", "--future", "pytest" },
        &.{ "npx", "--future", "pytest" },
        &.{ "npx", "-c", "pytest -q" },
        &.{ "npx", "--call=pytest -q" },
    };
    for (cases) |argv| {
        const invocation = classifyInvocation(argv);
        try std.testing.expectEqualDeep(argv, invocation.logical_argv);
        try std.testing.expectEqual(PassthroughReason.ambiguous_runner, invocation.passthrough_reason.?);
    }
}

test "invocation classification: query aliases are exact only before logical separator" {
    const universal = .{ "--help", "--version" };
    inline for (universal) |flag| try expectReason(&.{ "docker", "ps", flag }, .query);
    inline for (.{ "help", "version" }) |subcommand| try expectReason(&.{ "ruff", subcommand }, .query);
    inline for (.{ "pytest", "ruff", "mypy", "prettier", "uv", "pnpm", "jq" }) |tool| {
        try expectReason(&.{ tool, "command", "-V" }, .query);
    }
    inline for (.{ "uvx", "poetry", "npx" }) |tool| try expectReason(&.{ tool, "-V" }, .query);
    inline for (.{ "--collect-only", "--co", "--fixtures", "--fixtures-per-test", "--markers", "--trace-config" }) |flag| {
        try expectReason(&.{ "pytest", flag }, .query);
    }
    inline for (.{ "rule", "config", "linter" }) |subcommand| try expectReason(&.{ "ruff", subcommand }, .query);
    inline for (.{ "--support-info", "--find-config-path", "--file-info" }) |flag| try expectReason(&.{ "prettier", flag }, .query);
    inline for (.{ "--showConfig", "--listFilesOnly" }) |flag| try expectReason(&.{ "tsc", flag }, .query);

    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "ps", "-h" }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "psql", "-h", "db.example" }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "du", "-h", "." }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "df", "-h" }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "ls", "-h" }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "pytest", "--", "--version" }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "ruff", "check", "--", "--help" }).passthrough_reason);
}

test "invocation classification: machine output aliases are exact" {
    inline for (.{ "--json", "--vimgrep", "-c", "--count", "--count-matches", "-l", "--files-with-matches", "--files-without-match", "--files", "--type-list", "-0", "--null", "--null-data", "-o", "--only-matching", "--passthru", "--stats", "-rREPL", "--replace=REPL" }) |flag| {
        try expectReason(&.{ "rg", flag, "needle" }, .machine_output);
    }
    inline for (.{ "-o", "-ojson", "--output", "--output=json", "--template", "--template=x", "--raw", "--no-headers", "--show-labels", "-Lapp", "--label-columns=x", "--sort-by=x", "--output-watch-events", "--timestamps", "--prefix" }) |flag| {
        try expectReason(&.{ "kubectl", "get", "pods", flag }, .machine_output);
    }
    inline for (.{ "--format", "--format=x", "-q", "--quiet", "--no-trunc" }) |flag| try expectReason(&.{ "docker", "ps", flag }, .machine_output);
    inline for (.{ "container", "image", "network", "node", "plugin", "secret", "service", "volume", "manifest", "context" }) |object| {
        try expectReason(&.{ "docker", object, "inspect", "x" }, .machine_output);
    }
    try expectReason(&.{ "docker", "inspect", "x" }, .machine_output);
    try expectReason(&.{ "docker", "compose", "config" }, .machine_output);
    try expectReason(&.{ "docker-compose", "config" }, .machine_output);
    inline for (.{ "--output=json", "--query=x", "--generate-cli-skeleton=input", "--cli-binary-format=raw-in-base64-out" }) |flag| {
        try expectReason(&.{ "aws", "sts", "get-caller-identity", flag }, .machine_output);
    }
    try expectReason(&.{ "jq", "." }, .machine_output);
    inline for (.{ "-o", "-opid,comm", "-O", "-Opid", "--format=x", "--no-headers", "--headers", "--cols=120", "--columns=120", "--width=120", "-w", "-ww" }) |flag| {
        try expectReason(&.{ "ps", flag }, .machine_output);
    }
    inline for (.{ "-A", "--no-align", "-t", "--tuples-only", "--csv", "-F", "--field-separator=x", "-R", "--record-separator=x", "-z", "--field-separator-zero", "-0", "--record-separator-zero", "-H", "--html", "-P", "--pset=x", "-x", "--expanded", "-At" }) |flag| {
        try expectReason(&.{ "psql", flag }, .machine_output);
    }
    inline for (.{ "show", "is-active", "is-enabled", "is-failed" }) |subcommand| try expectReason(&.{ "systemctl", subcommand }, .machine_output);
    inline for (.{ "-o", "--output=json", "-p", "--property=ActiveState", "--value", "--no-legend", "--plain", "--full", "--show-types" }) |flag| {
        try expectReason(&.{ "systemctl", "status", flag }, .machine_output);
    }

    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "docker", "ps" }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "kubectl", "get", "pods" }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "ps", "auxww" }).passthrough_reason);
    try std.testing.expectEqual(@as(?PassthroughReason, null), classifyInvocation(&.{ "systemctl", "status" }).passthrough_reason);
}

fn expectReason(argv: []const []const u8, expected: PassthroughReason) !void {
    try std.testing.expectEqual(expected, classifyInvocation(argv).passthrough_reason.?);
}
