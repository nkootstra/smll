const std = @import("std");
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
    backing_allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const plugin_dir = try setup_io.concat2(allocator, home, "/.config/opencode/plugins/smll-proxy");
    const index_path = try setup_io.concat2(allocator, plugin_dir, "/index.ts");
    const pkg_path = try setup_io.concat2(allocator, plugin_dir, "/package.json");
    const config_path = try setup_io.concat2(allocator, home, "/.config/opencode/opencode.json");

    const existing_config = try setup_io.readFileOptional(allocator, io, config_path);
    if (try setup_io.checkConflictingIntegration(existing_config, "opencode", "opencode.json", stderr)) return 1;

    // Validate every input before changing the plugin package or its config.
    var config_json = setup_json.loadOrCreateObject(allocator, existing_config, false) catch {
        try setup_io.writeJsonError(stderr, "opencode.json");
        return 1;
    };
    defer config_json.deinit();

    const executable_path = try std.process.executablePathAlloc(io, allocator);
    if (!try setup_io.validateHookEvaluator(allocator, io, executable_path, "opencode", stderr)) return 1;
    const plugin_script = try buildOpencodePluginScript(allocator, executable_path);
    const pkg_json = "{\"name\":\"smll-proxy\",\"version\":\"1.0.0\",\"type\":\"module\",\"main\":\"index.ts\"}\n";

    const existing_index = try setup_io.readFileOptional(allocator, io, index_path);
    const existing_pkg = try setup_io.readFileOptional(allocator, io, pkg_path);
    const index_same = if (existing_index) |buf| std.mem.eql(u8, buf, plugin_script) else false;
    const pkg_same = if (existing_pkg) |buf| std.mem.eql(u8, buf, pkg_json) else false;

    var ownership = setup_io.readOwnership(allocator, io, home, "opencode") catch setup_io.Ownership.missing;
    const owned_digests = if (ownership.validPayload()) |payload| parsePluginOwnership(payload) else null;
    if (ownership == .modified or ownership.validPayload() != null and owned_digests == null) {
        try stderr.writeAll("smll opencode ownership record was modified; setup left files untouched\n");
        return 1;
    }
    if (!index_same and existing_index != null and !matchesOwnedDigest(existing_index.?, if (owned_digests) |d| d.index else null)) {
        try stderr.writeAll("opencode smll-proxy/index.ts was modified; setup left it untouched\n");
        return 1;
    }
    if (!pkg_same and existing_pkg != null and !matchesOwnedDigest(existing_pkg.?, if (owned_digests) |d| d.package else null)) {
        try stderr.writeAll("opencode smll-proxy/package.json was modified; setup left it untouched\n");
        return 1;
    }

    const pa = config_json.arena.allocator();
    const already_registered = try ensureOpencodePluginEnabled(pa, &config_json.value, plugin_dir);

    if (dry_run) {
        if (!index_same) try setup_io.writeOrReport(allocator, io, index_path, plugin_script, true, stdout);
        if (!pkg_same) try setup_io.writeOrReport(allocator, io, pkg_path, pkg_json, true, stdout);
        if (index_same and pkg_same) try stdout.writeAll("plugin up to date\n");
        if (!already_registered) {
            try setup_io.writeJsonValueToPath(allocator, io, config_path, config_json.value, true, stdout);
        } else {
            try stdout.writeAll("already installed\n");
        }
        try stdout.writeAll("[dry-run] would record smll plugin ownership\n");
        return 0;
    }

    var index_written = false;
    var pkg_written = false;
    var config_written = false;
    if (!index_same) {
        setup_io.writeOrReport(allocator, io, index_path, plugin_script, false, stdout) catch |err| return err;
        index_written = true;
    }
    if (!pkg_same) {
        setup_io.writeOrReport(allocator, io, pkg_path, pkg_json, false, stdout) catch |err| {
            if (index_written) setup_io.restoreOptional(io, index_path, existing_index) catch {};
            return err;
        };
        pkg_written = true;
    }
    if (index_same and pkg_same) try stdout.writeAll("plugin up to date\n");

    if (!already_registered) {
        setup_io.writeBackupIfExists(allocator, io, config_path, false) catch |err| {
            rollbackPluginWrites(io, index_path, existing_index, index_written, pkg_path, existing_pkg, pkg_written);
            return err;
        };
        setup_io.writeJsonValueToPath(allocator, io, config_path, config_json.value, false, stdout) catch |err| {
            rollbackPluginWrites(io, index_path, existing_index, index_written, pkg_path, existing_pkg, pkg_written);
            return err;
        };
        config_written = true;
    } else try stdout.writeAll("already installed\n");

    const owned_payload = try buildPluginOwnership(allocator, plugin_script, pkg_json);
    setup_io.writeOwnership(allocator, io, home, "opencode", owned_payload) catch |err| {
        if (config_written) {
            setup_io.restoreOptional(io, config_path, existing_config) catch {};
            setup_io.removeBackupIfExists(allocator, io, config_path) catch {};
        }
        rollbackPluginWrites(io, index_path, existing_index, index_written, pkg_path, existing_pkg, pkg_written);
        return err;
    };

    try stdout.writeAll("ok\n");
    return 0;
}

fn unsetupOpencode(
    backing_allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const plugin_dir = try setup_io.concat2(allocator, home, "/.config/opencode/plugins/smll-proxy");
    const index_path = try setup_io.concat2(allocator, plugin_dir, "/index.ts");
    const pkg_path = try setup_io.concat2(allocator, plugin_dir, "/package.json");
    // Also clean up legacy single-file plugin if present.
    const legacy_path = try setup_io.concat2(allocator, home, "/.config/opencode/plugins/smll-proxy.ts");
    const config_path = try setup_io.concat2(allocator, home, "/.config/opencode/opencode.json");

    // Unregister the plugin entry from opencode.json (symmetric to setupOpencode).
    const existing_config = try setup_io.readFileOptional(allocator, io, config_path);

    var ownership = setup_io.readOwnership(allocator, io, home, "opencode") catch setup_io.Ownership.missing;
    const owned_digests = if (ownership.validPayload()) |payload| parsePluginOwnership(payload) else null;
    if (ownership == .missing or ownership == .modified or owned_digests == null) {
        try stderr.writeAll("smll opencode ownership record missing or modified; no plugin files or config were removed\n");
        return 0;
    }

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

    var modified_artifact = false;
    const index = try setup_io.readFileOptional(allocator, io, index_path);
    if (index) |data| {
        if (matchesOwnedDigest(data, owned_digests.?.index)) {
            try setup_io.deleteOrReport(allocator, io, index_path, dry_run, stdout);
        } else {
            modified_artifact = true;
            try stderr.writeAll("opencode smll-proxy/index.ts was modified; file left untouched\n");
        }
    }
    const pkg = try setup_io.readFileOptional(allocator, io, pkg_path);
    if (pkg) |data| {
        if (matchesOwnedDigest(data, owned_digests.?.package)) {
            try setup_io.deleteOrReport(allocator, io, pkg_path, dry_run, stdout);
        } else {
            modified_artifact = true;
            try stderr.writeAll("opencode smll-proxy/package.json was modified; file left untouched\n");
        }
    }

    const legacy = try setup_io.readFileOptional(allocator, io, legacy_path);
    if (legacy != null) try stderr.writeAll("legacy opencode plugin left untouched because its ownership is unknown\n");
    if (!dry_run and !modified_artifact) {
        try setup_io.deleteOwnership(allocator, io, home, "opencode");
        try stdout.writeAll("ok\n");
    }
    return 0;
}

const PluginOwnership = struct {
    index: []const u8,
    package: []const u8,
};

fn buildPluginOwnership(allocator: std.mem.Allocator, index: []const u8, package: []const u8) ![]u8 {
    const payload = try allocator.alloc(u8, 33);
    setup_io.digestHex(index, payload[0..16]);
    payload[16] = '\n';
    setup_io.digestHex(package, payload[17..33]);
    return payload;
}

fn parsePluginOwnership(payload: []const u8) ?PluginOwnership {
    if (payload.len != 33 or payload[16] != '\n') return null;
    return .{ .index = payload[0..16], .package = payload[17..33] };
}

fn matchesOwnedDigest(data: []const u8, expected: ?[]const u8) bool {
    const digest = expected orelse return false;
    var actual: [16]u8 = undefined;
    setup_io.digestHex(data, &actual);
    return std.mem.eql(u8, digest, &actual);
}

fn rollbackPluginWrites(
    io: std.Io,
    index_path: []const u8,
    existing_index: ?[]const u8,
    index_written: bool,
    pkg_path: []const u8,
    existing_pkg: ?[]const u8,
    pkg_written: bool,
) void {
    if (index_written) setup_io.restoreOptional(io, index_path, existing_index) catch {};
    if (pkg_written) setup_io.restoreOptional(io, pkg_path, existing_pkg) catch {};
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

fn buildOpencodePluginScript(allocator: std.mem.Allocator, executable_path: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.writeAll("const S=");
    try setup_json.writeValue(&out.writer, .{ .string = executable_path });
    try out.writer.writeAll(
        \\;
        \\export const SmllProxyPlugin=async()=>({"tool.execute.before":async(i,o)=>{const t=String(i?.tool??"").toLowerCase();if(t!=="bash"&&t!=="shell")return;const a=o?.args;if(!a||typeof a!=="object")return;const c=String(a.command??"");if(!c)return;const event=new TextEncoder().encode(JSON.stringify({tool_input:{command:c}}));const p=Bun.spawnSync([S,"--hook-eval","opencode"],{stdin:event,stdout:"pipe",stderr:"ignore"});if(p.exitCode!==0)return;const n=new TextDecoder().decode(p.stdout).replace(/\r?\n$/,"");if(n)a.command=n}});
    );
    return allocator.dupe(u8, out.written());
}

test "opencode plugin routes classification through the absolute smll evaluator" {
    const allocator = std.testing.allocator;
    const script = try buildOpencodePluginScript(allocator, "/opt/smll");
    defer allocator.free(script);
    try std.testing.expect(std.mem.find(u8, script, "/opt/smll") != null);
    try std.testing.expect(std.mem.find(u8, script, "--hook-eval") != null);
    try std.testing.expect(std.mem.find(u8, script, "opencode") != null);
    try std.testing.expect(std.mem.find(u8, script, "TextEncoder") != null);
    try std.testing.expect(std.mem.find(u8, script, "new Set") == null);
}

test "opencode setup validates config before writing plugin files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".config/opencode");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".config/opencode/opencode.json", .data = "{invalid" });

    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(@as(u8, 1), try setupOpencode(allocator, std.testing.io, home, false, &stdout.writer, &stderr.writer));
    const index_path = try setup_io.concat2(allocator, home, "/.config/opencode/plugins/smll-proxy/index.ts");
    defer allocator.free(index_path);
    try std.testing.expect((try setup_io.readFileOptional(allocator, std.testing.io, index_path)) == null);
}

test "opencode setup preserves escaped JSON and large integers" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".config/opencode");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".config/opencode/opencode.json",
        .data = "{\"escaped\\\"key\":\"line\\nsnowman \\u2603\",\"large\":9223372036854775808,\"plugin\":[]}\n",
    });

    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(@as(u8, 0), try setupOpencode(allocator, std.testing.io, home, false, &stdout.writer, &stderr.writer));

    const updated = try tmp.dir.readFileAlloc(
        std.testing.io,
        ".config/opencode/opencode.json",
        allocator,
        .limited(64 * 1024),
    );
    defer allocator.free(updated);
    var parsed = try setup_json.parse(allocator, updated);
    defer parsed.deinit();

    const escaped = parsed.value.object.get("escaped\"key") orelse return error.MissingEscapedValue;
    try std.testing.expectEqualStrings("line\nsnowman \xe2\x98\x83", escaped.string);
    const large = parsed.value.object.get("large") orelse return error.MissingLargeValue;
    try std.testing.expectEqualStrings("9223372036854775808", large.number);
    const plugins = parsed.value.object.get("plugin") orelse return error.MissingPluginValue;
    try std.testing.expectEqual(@as(usize, 1), plugins.array.items.len);
}

test "opencode unsetup leaves modified owned plugin files and warns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(@as(u8, 0), try setupOpencode(allocator, std.testing.io, home, false, &stdout.writer, &stderr.writer));
    const index_path = try setup_io.concat2(allocator, home, "/.config/opencode/plugins/smll-proxy/index.ts");
    defer allocator.free(index_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = index_path, .data = "// user modified\n" });

    var unsetup_stdout = std.Io.Writer.Allocating.init(allocator);
    defer unsetup_stdout.deinit();
    try std.testing.expectEqual(@as(u8, 0), try unsetupOpencode(allocator, std.testing.io, home, false, &unsetup_stdout.writer, &stderr.writer));
    const index = try setup_io.readFileOptional(allocator, std.testing.io, index_path);
    defer allocator.free(index.?);
    try std.testing.expectEqualStrings("// user modified\n", index.?);
    try std.testing.expect(std.mem.find(u8, stderr.written(), "index.ts was modified") != null);
    try std.testing.expect(std.mem.find(u8, unsetup_stdout.written(), "ok\n") == null);
}

test "opencode setup rolls back plugin and config when ownership write fails" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home);
    try tmp.dir.createDirPath(std.testing.io, ".config/opencode");
    const original_config = "{\"plugin\":[]}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".config/opencode/opencode.json", .data = original_config });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll", .data = "blocks ownership directory\n" });
    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();

    if (setupOpencode(allocator, std.testing.io, home, false, &stdout.writer, &stderr.writer)) |_| {
        return error.ExpectedSetupFailure;
    } else |_| {}

    inline for (.{
        "/.config/opencode/plugins/smll-proxy/index.ts",
        "/.config/opencode/plugins/smll-proxy/package.json",
    }) |suffix| {
        const path = try setup_io.concat2(allocator, home, suffix);
        defer allocator.free(path);
        try std.testing.expect((try setup_io.readFileOptional(allocator, std.testing.io, path)) == null);
    }
    const config_path = try setup_io.concat2(allocator, home, "/.config/opencode/opencode.json");
    defer allocator.free(config_path);
    const restored = try setup_io.readFileOptional(allocator, std.testing.io, config_path);
    defer allocator.free(restored.?);
    try std.testing.expectEqualStrings(original_config, restored.?);
    const backup_path = try setup_io.concat2(allocator, config_path, ".bak.smll");
    defer allocator.free(backup_path);
    try std.testing.expect((try setup_io.readFileOptional(allocator, std.testing.io, backup_path)) == null);
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
