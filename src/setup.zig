const std = @import("std");
const filter_catalog = @import("filter_catalog.zig");
const setup_hooks = @import("setup_hooks.zig");
const setup_io = @import("setup_io.zig");
const setup_json = @import("setup_json.zig");

const JObject = setup_json.Object;
const JValue = setup_json.Value;

const Target = enum {
    claude,
    opencode,
    cursor,
    codex,
};

const Action = enum {
    setup,
    unsetup,
};

const CliOptions = struct {
    action: Action,
    target: Target,
    dry_run: bool = false,
};

const SetupError = error{
    InvalidConfigJson,
};

pub fn maybeRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?u8 {
    if (args.len < 2) return null;

    const first = args[1];
    const is_setup = std.mem.startsWith(u8, first, "--setup");
    const is_unsetup = std.mem.startsWith(u8, first, "--unsetup");
    if (!is_setup and !is_unsetup) return null;

    const opts = parseCliArgs(args[1..]) catch {
        try printUsage(stderr);
        return 2;
    };

    const home = environ.get("HOME") orelse {
        try stderr.writeAll("smll agent setup: HOME is not set\n");
        return 1;
    };

    return try runAction(allocator, io, home, opts, stdout, stderr);
}

fn parseCliArgs(args: []const []const u8) !CliOptions {
    // Accepted forms:
    //   smll --setup claude
    //   smll --setup=claude --dry-run
    //   smll --unsetup opencode
    if (args.len == 0) return error.InvalidArgs;

    const parsed = parseActionToken(args[0]) orelse return error.InvalidArgs;
    const has_inline_target = parsed.inline_target != null;
    const target_arg = parsed.inline_target orelse blk: {
        if (args.len < 2) return error.InvalidArgs;
        break :blk args[1];
    };
    const option_args = if (has_inline_target) args[1..] else args[2..];

    return .{
        .action = parsed.action,
        .target = parseTarget(target_arg) orelse return error.InvalidArgs,
        .dry_run = try parseDryRunArgs(option_args),
    };
}

fn parseDryRunArgs(args: []const []const u8) !bool {
    var dry_run = false;
    for (args) |arg| {
        if (!std.mem.eql(u8, arg, "--dry-run")) return error.InvalidArgs;
        dry_run = true;
    }
    return dry_run;
}

const ParsedActionToken = struct {
    action: Action,
    inline_target: ?[]const u8,
};

fn parseActionToken(token: []const u8) ?ParsedActionToken {
    if (std.mem.eql(u8, token, "--setup")) return .{ .action = .setup, .inline_target = null };
    if (std.mem.startsWith(u8, token, "--setup=")) return .{ .action = .setup, .inline_target = token[8..] };

    if (std.mem.eql(u8, token, "--unsetup")) return .{ .action = .unsetup, .inline_target = null };
    if (std.mem.startsWith(u8, token, "--unsetup=")) return .{ .action = .unsetup, .inline_target = token[10..] };

    return null;
}

fn parseTarget(s: []const u8) ?Target {
    if (std.mem.eql(u8, s, "claude")) return .claude;
    if (std.mem.eql(u8, s, "opencode")) return .opencode;
    if (std.mem.eql(u8, s, "cursor")) return .cursor;
    if (std.mem.eql(u8, s, "codex")) return .codex;
    return null;
}

fn printUsage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll("Usage: smll --[un]setup[=]<claude|opencode|cursor|codex> [--dry-run]\n");
}

fn runAction(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    opts: CliOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    return switch (opts.action) {
        .setup => switch (opts.target) {
            .claude => try setup_hooks.setup(allocator, io, home, setup_hooks.claudeSpec(), opts.dry_run, stdout, stderr),
            .opencode => try setupOpencode(allocator, io, home, opts.dry_run, stdout, stderr),
            .cursor => try setup_hooks.setup(allocator, io, home, setup_hooks.cursorSpec(), opts.dry_run, stdout, stderr),
            .codex => try setup_hooks.setup(allocator, io, home, setup_hooks.codexSpec(), opts.dry_run, stdout, stderr),
        },
        .unsetup => switch (opts.target) {
            .claude => try setup_hooks.unsetup(allocator, io, home, setup_hooks.claudeSpec(), opts.dry_run, stdout, stderr),
            .opencode => try unsetupOpencode(allocator, io, home, opts.dry_run, stdout, stderr),
            .cursor => try setup_hooks.unsetup(allocator, io, home, setup_hooks.cursorSpec(), opts.dry_run, stdout, stderr),
            .codex => try setup_hooks.unsetup(allocator, io, home, setup_hooks.codexSpec(), opts.dry_run, stdout, stderr),
        },
    };
}

fn setupOpencode(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const plugin_dir = try setup_io.concat2(allocator, home, "/.config/opencode/plugins/smll-proxy");
    defer allocator.free(plugin_dir);
    const index_path = try setup_io.concat2(allocator, plugin_dir, "/index.ts");
    defer allocator.free(index_path);
    const pkg_path = try setup_io.concat2(allocator, plugin_dir, "/package.json");
    defer allocator.free(pkg_path);
    const config_path = try setup_io.concat2(allocator, home, "/.config/opencode/opencode.json");
    defer allocator.free(config_path);

    // Check for conflicting command-wrapper integrations.
    const existing_config = try setup_io.readFileOptional(allocator, io, config_path);
    defer if (existing_config) |buf| allocator.free(buf);
    if (try setup_io.checkConflictingIntegration(existing_config, "opencode", "opencode.json", stderr)) return 1;

    // Write plugin package (index.ts + package.json).
    const plugin_script = buildOpencodePluginScript();
    const pkg_json = "{\"name\":\"smll-proxy\",\"version\":\"1.0.0\",\"type\":\"module\",\"main\":\"index.ts\"}\n";

    const existing_index = try setup_io.readFileOptional(allocator, io, index_path);
    defer if (existing_index) |buf| allocator.free(buf);
    const index_same = if (existing_index) |buf| std.mem.eql(u8, buf, plugin_script) else false;

    if (!index_same) {
        try setup_io.writeOrReport(allocator, io, index_path, plugin_script, dry_run, stdout);
        try setup_io.writeOrReport(allocator, io, pkg_path, pkg_json, dry_run, stdout);
    } else {
        try stdout.writeAll("plugin up to date\n");
    }

    // Register plugin in opencode.json plugin array.
    var config_json = setup_json.loadOrCreateObject(allocator, existing_config, false) catch {
        try setup_io.writeJsonError(stderr, "opencode.json");
        return 1;
    };
    defer config_json.deinit();

    const pa = config_json.arena.allocator();
    const already_registered = try ensureOpencodePluginEnabled(pa, &config_json.value, plugin_dir);

    if (!already_registered) {
        try setup_io.writeBackupIfExists(allocator, io, config_path, dry_run);
        try setup_io.writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
    } else {
        try stdout.writeAll("already installed\n");
    }

    if (!dry_run) try stdout.writeAll("ok\n");
    return 0;
}

fn unsetupOpencode(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const plugin_dir = try setup_io.concat2(allocator, home, "/.config/opencode/plugins/smll-proxy");
    defer allocator.free(plugin_dir);
    const index_path = try setup_io.concat2(allocator, plugin_dir, "/index.ts");
    defer allocator.free(index_path);
    const pkg_path = try setup_io.concat2(allocator, plugin_dir, "/package.json");
    defer allocator.free(pkg_path);
    // Also clean up legacy single-file plugin if present.
    const legacy_path = try setup_io.concat2(allocator, home, "/.config/opencode/plugins/smll-proxy.ts");
    defer allocator.free(legacy_path);
    const config_path = try setup_io.concat2(allocator, home, "/.config/opencode/opencode.json");
    defer allocator.free(config_path);

    // Unregister the plugin entry from opencode.json (symmetric to setupOpencode).
    const existing_config = try setup_io.readFileOptional(allocator, io, config_path);
    defer if (existing_config) |buf| allocator.free(buf);

    if (existing_config) |_| {
        var config_json = setup_json.loadOrCreateObject(allocator, existing_config, false) catch {
            try setup_io.writeJsonError(stderr, "opencode.json");
            return 1;
        };
        defer config_json.deinit();

        const changed = try removeOpencodePluginEntry(&config_json.value, plugin_dir);
        if (changed) {
            try setup_io.writeBackupIfExists(allocator, io, config_path, dry_run);
            try setup_io.writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
        } else {
            try stdout.writeAll("no plugin entry found\n");
        }
    }

    for ([_][]const u8{ index_path, pkg_path, legacy_path }) |path| {
        const existing = try setup_io.readFileOptional(allocator, io, path);
        defer if (existing) |buf| allocator.free(buf);
        if (existing != null) {
            try setup_io.deleteOrReport(allocator, io, path, dry_run, stdout);
        }
    }

    if (!dry_run) try stdout.writeAll("ok\n");
    return 0;
}

fn ensureOpencodePluginEnabled(pa: std.mem.Allocator, root: *JValue, plugin_path: []const u8) !bool {
    if (root.* != .object) return SetupError.InvalidConfigJson;
    const root_obj = &root.object;
    const plugin_val = try ensureArrayField(pa, root_obj, "plugin");
    if (plugin_val.* != .array) return SetupError.InvalidConfigJson;

    for (plugin_val.array.items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, plugin_path)) return true;
    }

    try plugin_val.array.append(.{ .string = try pa.dupe(u8, plugin_path) });
    return false;
}

fn removeOpencodePluginEntry(root: *JValue, plugin_path: []const u8) !bool {
    if (root.* != .object) return SetupError.InvalidConfigJson;
    const plugin_val = root.object.getPtr("plugin") orelse return false;
    if (plugin_val.* != .array) return SetupError.InvalidConfigJson;

    var changed = false;
    var i: usize = 0;
    while (i < plugin_val.array.items.len) {
        const item = plugin_val.array.items[i];
        if (item == .string and std.mem.eql(u8, item.string, plugin_path)) {
            _ = plugin_val.array.swapRemove(i);
            changed = true;
            continue;
        }
        i += 1;
    }

    return changed;
}

fn ensureArrayField(pa: std.mem.Allocator, obj: *JObject, key: []const u8) !*JValue {
    if (obj.getPtr(key)) |v| return v;
    const arr = setup_json.Array.init(pa);
    try obj.put(pa, key, .{ .array = arr });
    return obj.getPtr(key).?;
}

fn buildOpencodePluginScript() []const u8 {
    return "const W=new Set([" ++ filter_catalog.auto_wrap_js_array ++ "]);\n" ++
        \\export const SmllProxyPlugin=async({$})=>({"tool.execute.before":async(i,o)=>{const t=String(i?.tool??"").toLowerCase();if(t!=="bash"&&t!=="shell")return;const a=o?.args;if(!a||typeof a!=="object")return;const c=(a.command??"").trim();if(!c||/^smll(\\s|$)/.test(c))return;const f=c.split(/\\s+/)[0];if(W.has(f))a.command=`smll ${c}`}});
    ;
}

test "opencode plugin auto-wrap list includes expanded filters" {
    const script = buildOpencodePluginScript();
    try std.testing.expect(std.mem.find(u8, script, "\"eslint\"") != null);
    try std.testing.expect(std.mem.find(u8, script, "\"terraform\"") != null);
    try std.testing.expect(std.mem.find(u8, script, "\"aws\"") != null);
}

test "parseCliArgs supports --setup target" {
    const opts = try parseCliArgs(&.{ "--setup", "claude" });
    try std.testing.expectEqual(Action.setup, opts.action);
    try std.testing.expectEqual(Target.claude, opts.target);
    try std.testing.expect(!opts.dry_run);
}

test "parseCliArgs supports --setup=target and --dry-run" {
    const opts = try parseCliArgs(&.{ "--setup=opencode", "--dry-run" });
    try std.testing.expectEqual(Action.setup, opts.action);
    try std.testing.expectEqual(Target.opencode, opts.target);
    try std.testing.expect(opts.dry_run);
}

test "parseCliArgs supports codex setup target" {
    const opts = try parseCliArgs(&.{ "--setup", "codex" });
    try std.testing.expectEqual(Action.setup, opts.action);
    try std.testing.expectEqual(Target.codex, opts.target);
}

test "parseCliArgs supports --unsetup target" {
    const opts = try parseCliArgs(&.{ "--unsetup", "claude" });
    try std.testing.expectEqual(Action.unsetup, opts.action);
    try std.testing.expectEqual(Target.claude, opts.target);
}

test "removeOpencodePluginEntry: removes matching plugin path from array" {
    const allocator = std.testing.allocator;
    var parsed = try setup_json.parse(allocator,
        \\{"plugin":["other-plugin","/home/u/.config/opencode/plugins/smll-proxy"]}
    );
    defer parsed.deinit();

    const changed = try removeOpencodePluginEntry(&parsed.value, "/home/u/.config/opencode/plugins/smll-proxy");
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.getPtr("plugin").?.array.items.len);
    try std.testing.expectEqualStrings("other-plugin", parsed.value.object.getPtr("plugin").?.array.items[0].string);
}

test "removeOpencodePluginEntry: returns false when entry not present" {
    const allocator = std.testing.allocator;
    var parsed = try setup_json.parse(allocator,
        \\{"plugin":["other-plugin"]}
    );
    defer parsed.deinit();

    const changed = try removeOpencodePluginEntry(&parsed.value, "/missing/path");
    try std.testing.expect(!changed);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.getPtr("plugin").?.array.items.len);
}

test "removeOpencodePluginEntry: missing plugin field is a no-op" {
    const allocator = std.testing.allocator;
    var parsed = try setup_json.parse(allocator,
        \\{"other":42}
    );
    defer parsed.deinit();

    const changed = try removeOpencodePluginEntry(&parsed.value, "/anything");
    try std.testing.expect(!changed);
}
