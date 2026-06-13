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
        if (std.mem.eql(u8, cmd_basename, "gh") and std.mem.eql(u8, sub, "run") and std.mem.eql(u8, arg2, "watch")) return .inherit;
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

test "streaming classification: start is scoped to dev runners" {
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("docker", &.{ "docker", "start", "db" }));
    try std.testing.expectEqual(StreamDecision.capture, classifyStreamCommand("systemctl", &.{ "systemctl", "start", "nginx" }));
    try std.testing.expectEqual(StreamDecision.inherit, classifyStreamCommand("npm", &.{ "npm", "run", "dev" }));
    try std.testing.expectEqual(StreamDecision.inherit, classifyStreamCommand("next", &.{ "next", "dev" }));
}
