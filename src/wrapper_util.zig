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

/// Detect streaming/interactive commands that produce continuous output and
/// must not be buffered in wrapper mode.
pub fn isStreamingCommand(cmd_basename: []const u8, argv: []const []const u8) bool {
    if (hasArg(argv, "--watch") or hasArg(argv, "--watchAll")) return true;
    if (hasArg(argv, "-w") and allowsShortWatchFlag(cmd_basename)) return true;

    if (hasArg(argv, "--follow") or hasArg(argv, "-f")) {
        if (eqAny(cmd_basename, &.{ "docker", "kubectl", "tail", "journalctl" })) return true;
    }

    if (argv.len >= 2) {
        const sub = argv[1];
        if (std.mem.eql(u8, sub, "watch")) return true;
        if (std.mem.eql(u8, cmd_basename, "go") and std.mem.eql(u8, sub, "run")) return true;
        if (eqAny(sub, &.{ "dev", "serve", "start" })) return true;
    }

    if (argv.len >= 3) {
        const sub = argv[1];
        const arg2 = argv[2];
        if (eqAny(sub, &.{ "run", "exec" })) {
            if (eqAny(arg2, &.{ "dev", "serve", "start", "watch" })) return true;
        }
        if (std.mem.eql(u8, cmd_basename, "gh") and std.mem.eql(u8, sub, "run") and std.mem.eql(u8, arg2, "watch")) return true;
    }

    return eqAny(cmd_basename, &.{ "nodemon", "watchman" });
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
