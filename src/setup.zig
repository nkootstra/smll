const std = @import("std");

const Target = enum {
    claude,
    opencode,
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
    InvalidSettingsJson,
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

    var target: ?Target = null;
    var dry_run = false;

    if (parsed.inline_target) |inline_target| {
        target = parseTarget(inline_target) orelse return error.InvalidArgs;
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else {
                return error.InvalidArgs;
            }
        }
    } else {
        if (args.len < 2) return error.InvalidArgs;
        target = parseTarget(args[1]) orelse return error.InvalidArgs;
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--dry-run")) {
                dry_run = true;
            } else {
                return error.InvalidArgs;
            }
        }
    }

    return .{
        .action = parsed.action,
        .target = target.?,
        .dry_run = dry_run,
    };
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
    return null;
}

fn printUsage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll(
        \\Usage:
        \\  smll --setup <claude|opencode> [--dry-run]
        \\  smll --setup=<claude|opencode> [--dry-run]
        \\  smll --unsetup <claude|opencode> [--dry-run]
        \\  smll --unsetup=<claude|opencode> [--dry-run]
        \\
    );
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
            .claude => try setupClaude(allocator, io, home, opts.dry_run, stdout, stderr),
            .opencode => try setupOpencode(allocator, io, home, opts.dry_run, stdout, stderr),
        },
        .unsetup => switch (opts.target) {
            .claude => try unsetupClaude(allocator, io, home, opts.dry_run, stdout, stderr),
            .opencode => try unsetupOpencode(allocator, io, home, opts.dry_run, stdout, stderr),
        },
    };
}

fn setupClaude(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/.claude/settings.json", .{home});
    defer allocator.free(settings_path);

    const hook_script_path = try std.fmt.allocPrint(allocator, "{s}/.claude/hooks/smll-pretooluse.sh", .{home});
    defer allocator.free(hook_script_path);

    const hook_command = try std.fmt.allocPrint(allocator, "bash {s}", .{hook_script_path});
    defer allocator.free(hook_command);

    const existing_settings = try readFileOptional(allocator, io, settings_path);
    defer if (existing_settings) |buf| allocator.free(buf);

    if (existing_settings) |buf| {
        if (containsRtkIntegration(buf)) {
            try stderr.writeAll("smll setup (claude): detected existing RTK integration in ~/.claude/settings.json\n");
            try stderr.writeAll("Please remove RTK hooks first, then run smll --setup claude again.\n");
            return 1;
        }
    }

    var settings_json = loadOrCreateJsonObject(allocator, existing_settings) catch {
        try stderr.writeAll("smll setup (claude): settings.json is not valid JSON\n");
        return 1;
    };
    defer settings_json.deinit();

    const pa = settings_json.arena.allocator();
    const already_installed = try ensureClaudePreToolHook(pa, &settings_json.value, hook_command);

    if (!already_installed) {
        try writeBackupIfExists(allocator, io, settings_path, dry_run);
        try writeJsonValueToPath(allocator, io, settings_path, settings_json.value, dry_run, stdout);
    } else {
        try stdout.writeAll("claude settings already contain smll hook\n");
    }

    const hook_script = buildClaudeHookScript();
    const existing_hook = try readFileOptional(allocator, io, hook_script_path);
    defer if (existing_hook) |buf| allocator.free(buf);

    const hook_same = if (existing_hook) |buf| std.mem.eql(u8, buf, hook_script) else false;
    if (!hook_same) {
        try writeBackupIfExists(allocator, io, hook_script_path, dry_run);
        if (dry_run) {
            try stdout.print("[dry-run] would write {s}\n", .{hook_script_path});
        } else {
            try writeFileEnsuringParent(io, hook_script_path, hook_script);
            try stdout.print("wrote {s}\n", .{hook_script_path});
        }
    } else {
        try stdout.writeAll("claude hook script already up to date\n");
    }

    if (!dry_run) try stdout.writeAll("done: claude setup installed\n");
    return 0;
}

fn setupOpencode(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/opencode/opencode.json", .{home});
    defer allocator.free(config_path);

    const plugin_path = try std.fmt.allocPrint(allocator, "{s}/.config/opencode/plugins/smll-proxy.js", .{home});
    defer allocator.free(plugin_path);

    const existing_config = try readFileOptional(allocator, io, config_path);
    defer if (existing_config) |buf| allocator.free(buf);

    if (existing_config) |buf| {
        if (containsRtkIntegration(buf)) {
            try stderr.writeAll("smll setup (opencode): detected existing RTK integration in opencode.json\n");
            try stderr.writeAll("Please remove RTK plugin/hook entries first, then run smll --setup opencode again.\n");
            return 1;
        }
    }

    var config_json = loadOrCreateJsonObject(allocator, existing_config) catch {
        try stderr.writeAll("smll setup (opencode): opencode.json is not valid JSON\n");
        return 1;
    };
    defer config_json.deinit();

    const pa = config_json.arena.allocator();
    const already_enabled = try ensureOpencodePluginEnabled(pa, &config_json.value, plugin_path);

    if (!already_enabled) {
        try writeBackupIfExists(allocator, io, config_path, dry_run);
        try writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
    } else {
        try stdout.writeAll("opencode config already enables smll plugin\n");
    }

    const plugin_script = buildOpencodePluginScript();
    const existing_plugin = try readFileOptional(allocator, io, plugin_path);
    defer if (existing_plugin) |buf| allocator.free(buf);

    const plugin_same = if (existing_plugin) |buf| std.mem.eql(u8, buf, plugin_script) else false;
    if (!plugin_same) {
        try writeBackupIfExists(allocator, io, plugin_path, dry_run);
        if (dry_run) {
            try stdout.print("[dry-run] would write {s}\n", .{plugin_path});
        } else {
            try writeFileEnsuringParent(io, plugin_path, plugin_script);
            try stdout.print("wrote {s}\n", .{plugin_path});
        }
    } else {
        try stdout.writeAll("opencode plugin already up to date\n");
    }

    if (!dry_run) try stdout.writeAll("done: opencode setup installed\n");
    return 0;
}

fn unsetupClaude(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const settings_path = try std.fmt.allocPrint(allocator, "{s}/.claude/settings.json", .{home});
    defer allocator.free(settings_path);

    const hook_script_path = try std.fmt.allocPrint(allocator, "{s}/.claude/hooks/smll-pretooluse.sh", .{home});
    defer allocator.free(hook_script_path);

    const hook_command = try std.fmt.allocPrint(allocator, "bash {s}", .{hook_script_path});
    defer allocator.free(hook_command);

    var changed_settings = false;
    const existing_settings = try readFileOptional(allocator, io, settings_path);
    defer if (existing_settings) |buf| allocator.free(buf);

    if (existing_settings) |_| {
        var settings_json = loadOrCreateJsonObject(allocator, existing_settings) catch {
            try stderr.writeAll("smll unsetup (claude): settings.json is not valid JSON\n");
            return 1;
        };
        defer settings_json.deinit();

        changed_settings = try removeClaudePreToolHook(&settings_json.value, hook_command);
        if (changed_settings) {
            try writeBackupIfExists(allocator, io, settings_path, dry_run);
            try writeJsonValueToPath(allocator, io, settings_path, settings_json.value, dry_run, stdout);
        } else {
            try stdout.writeAll("claude settings: no smll hook entry found\n");
        }
    } else {
        try stdout.writeAll("claude settings: file not found, nothing to remove\n");
    }

    const existing_hook = try readFileOptional(allocator, io, hook_script_path);
    defer if (existing_hook) |buf| allocator.free(buf);
    if (existing_hook != null) {
        try writeBackupIfExists(allocator, io, hook_script_path, dry_run);
        if (dry_run) {
            try stdout.print("[dry-run] would delete {s}\n", .{hook_script_path});
        } else {
            try deleteFileIfExists(io, hook_script_path);
            try stdout.print("deleted {s}\n", .{hook_script_path});
        }
    } else {
        try stdout.writeAll("claude hook script: not found\n");
    }

    if (!dry_run) try stdout.writeAll("done: claude unsetup complete\n");
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
    const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/opencode/opencode.json", .{home});
    defer allocator.free(config_path);

    const plugin_path = try std.fmt.allocPrint(allocator, "{s}/.config/opencode/plugins/smll-proxy.js", .{home});
    defer allocator.free(plugin_path);

    var changed_config = false;
    const existing_config = try readFileOptional(allocator, io, config_path);
    defer if (existing_config) |buf| allocator.free(buf);

    if (existing_config) |_| {
        var config_json = loadOrCreateJsonObject(allocator, existing_config) catch {
            try stderr.writeAll("smll unsetup (opencode): opencode.json is not valid JSON\n");
            return 1;
        };
        defer config_json.deinit();

        changed_config = try removeOpencodePluginEntry(&config_json.value, plugin_path);
        if (changed_config) {
            try writeBackupIfExists(allocator, io, config_path, dry_run);
            try writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
        } else {
            try stdout.writeAll("opencode config: no smll plugin entry found\n");
        }
    } else {
        try stdout.writeAll("opencode config: file not found, nothing to remove\n");
    }

    const existing_plugin = try readFileOptional(allocator, io, plugin_path);
    defer if (existing_plugin) |buf| allocator.free(buf);
    if (existing_plugin != null) {
        try writeBackupIfExists(allocator, io, plugin_path, dry_run);
        if (dry_run) {
            try stdout.print("[dry-run] would delete {s}\n", .{plugin_path});
        } else {
            try deleteFileIfExists(io, plugin_path);
            try stdout.print("deleted {s}\n", .{plugin_path});
        }
    } else {
        try stdout.writeAll("opencode plugin file: not found\n");
    }

    if (!dry_run) try stdout.writeAll("done: opencode unsetup complete\n");
    return 0;
}

fn loadOrCreateJsonObject(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
) !std.json.Parsed(std.json.Value) {
    if (existing) |buf| {
        if (std.mem.trim(u8, buf, " \t\r\n").len == 0) {
            return try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
        }
        return try std.json.parseFromSlice(std.json.Value, allocator, buf, .{});
    }
    return try std.json.parseFromSlice(std.json.Value, allocator, "{}", .{});
}

fn ensureClaudePreToolHook(pa: std.mem.Allocator, root: *std.json.Value, hook_command: []const u8) !bool {
    if (root.* != .object) return SetupError.InvalidSettingsJson;
    const root_obj = &root.object;

    const hooks_val = try ensureObjectField(pa, root_obj, "hooks");
    if (hooks_val.* != .object) return SetupError.InvalidSettingsJson;
    const hooks_obj = &hooks_val.object;

    const pre_tool_use_val = try ensureArrayField(pa, hooks_obj, "PreToolUse");
    if (pre_tool_use_val.* != .array) return SetupError.InvalidSettingsJson;

    if (claudePreToolHookExists(pre_tool_use_val.array.items, hook_command)) return true;

    var cmd_obj: std.json.ObjectMap = .empty;
    try cmd_obj.put(pa, "type", .{ .string = try pa.dupe(u8, "command") });
    try cmd_obj.put(pa, "command", .{ .string = try pa.dupe(u8, hook_command) });
    try cmd_obj.put(pa, "timeout", .{ .integer = 10 });

    var hook_handlers = std.json.Array.init(pa);
    try hook_handlers.append(.{ .object = cmd_obj });

    var matcher_obj: std.json.ObjectMap = .empty;
    try matcher_obj.put(pa, "matcher", .{ .string = try pa.dupe(u8, "Bash") });
    try matcher_obj.put(pa, "hooks", .{ .array = hook_handlers });

    try pre_tool_use_val.array.append(.{ .object = matcher_obj });
    return false;
}

fn removeClaudePreToolHook(root: *std.json.Value, hook_command: []const u8) !bool {
    if (root.* != .object) return SetupError.InvalidSettingsJson;
    const hooks_val = root.object.getPtr("hooks") orelse return false;
    if (hooks_val.* != .object) return SetupError.InvalidSettingsJson;
    const pre_val = hooks_val.object.getPtr("PreToolUse") orelse return false;
    if (pre_val.* != .array) return SetupError.InvalidSettingsJson;

    var changed = false;
    var i: usize = 0;
    while (i < pre_val.array.items.len) {
        const entry = pre_val.array.items[i];
        if (!isClaudeHookEntryForCommand(entry, hook_command)) {
            i += 1;
            continue;
        }
        _ = pre_val.array.swapRemove(i);
        changed = true;
    }

    return changed;
}

fn isClaudeHookEntryForCommand(entry: std.json.Value, hook_command: []const u8) bool {
    if (entry != .object) return false;
    const hooks_val = entry.object.get("hooks") orelse return false;
    if (hooks_val != .array) return false;

    for (hooks_val.array.items) |handler| {
        if (handler != .object) continue;
        const command = handler.object.get("command") orelse continue;
        if (command != .string) continue;
        if (std.mem.eql(u8, command.string, hook_command)) return true;
    }

    return false;
}

fn claudePreToolHookExists(entries: []const std.json.Value, hook_command: []const u8) bool {
    for (entries) |entry| {
        if (isClaudeHookEntryForCommand(entry, hook_command)) return true;
    }
    return false;
}

fn ensureOpencodePluginEnabled(pa: std.mem.Allocator, root: *std.json.Value, plugin_path: []const u8) !bool {
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

fn removeOpencodePluginEntry(root: *std.json.Value, plugin_path: []const u8) !bool {
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

fn ensureObjectField(pa: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8) !*std.json.Value {
    if (obj.getPtr(key)) |v| return v;
    try obj.put(pa, key, .{ .object = .empty });
    return obj.getPtr(key).?;
}

fn ensureArrayField(pa: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8) !*std.json.Value {
    if (obj.getPtr(key)) |v| return v;
    const arr = std.json.Array.init(pa);
    try obj.put(pa, key, .{ .array = arr });
    return obj.getPtr(key).?;
}

fn readFileOptional(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    const cwd = std.Io.Dir.cwd();
    const data = cwd.readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return data;
}

fn writeBackupIfExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8, dry_run: bool) !void {
    const existing = try readFileOptional(allocator, io, path);
    defer if (existing) |buf| allocator.free(buf);
    if (existing == null or dry_run) return;

    const backup_path = try std.fmt.allocPrint(allocator, "{s}.bak.smll", .{path});
    defer allocator.free(backup_path);
    try writeFileEnsuringParent(io, backup_path, existing.?);
}

fn writeFileEnsuringParent(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    });
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn writeJsonValueToPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    value: std.json.Value,
    dry_run: bool,
    stdout: *std.Io.Writer,
) !void {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');

    if (dry_run) {
        try stdout.print("[dry-run] would update {s}\n", .{path});
    } else {
        try writeFileEnsuringParent(io, path, out.written());
        try stdout.print("updated {s}\n", .{path});
    }
}

fn buildClaudeHookScript() []const u8 {
    return
    \\#!/usr/bin/env bash
    \\set -euo pipefail
    \\
    \\if ! command -v jq >/dev/null 2>&1; then
    \\  exit 0
    \\fi
    \\
    \\payload="$(cat)"
    \\cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
    \\if [[ -z "$cmd" ]]; then
    \\  exit 0
    \\fi
    \\
    \\if [[ "$cmd" =~ ^[[:space:]]*smll([[:space:]]|$) ]]; then
    \\  exit 0
    \\fi
    \\
    \\trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
    \\first="${trimmed%%[[:space:]]*}"
    \\
    \\case "$first" in
    \\  git|rg|tree|find|docker|kubectl|gh|ps|ls|du|curl|make|cargo|pytest|jest|vitest|go|tsc|npm|pnpm|yarn|bun)
    \\    echo "smll hook: wrap noisy command with smll (example: smll $cmd)" >&2
    \\    exit 2
    \\    ;;
    \\  *)
    \\    exit 0
    \\    ;;
    \\esac
    ;
}

fn buildOpencodePluginScript() []const u8 {
    return
    \\const WRAPPED = new Set([
    \\  "git", "rg", "tree", "find", "docker", "kubectl", "gh", "ps", "ls", "du", "curl",
    \\  "make", "cargo", "pytest", "jest", "vitest", "go", "tsc", "npm", "pnpm", "yarn", "bun",
    \\]);
    \\
    \\export const SmllProxyPlugin = async () => {
    \\  return {
    \\    "tool.execute.before": async (input, output) => {
    \\      if (input.tool !== "bash") return;
    \\      const command = (output?.args?.command ?? "").trim();
    \\      if (!command) return;
    \\      if (/^smll(\\s|$)/.test(command)) return;
    \\
    \\      const first = command.split(/\\s+/)[0];
    \\      if (!WRAPPED.has(first)) return;
    \\
    \\      output.args.command = `smll ${command}`;
    \\    },
    \\  };
    \\};
    ;
}

fn containsRtkIntegration(s: []const u8) bool {
    return containsIgnoreCase(s, "run-toolkit") or
        containsIgnoreCase(s, "run toolkit") or
        containsIgnoreCase(s, "\"rtk\"") or
        containsIgnoreCase(s, " rtk") or
        containsIgnoreCase(s, "/rtk") or
        containsIgnoreCase(s, "rtk-") or
        containsIgnoreCase(s, "-rtk");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
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

test "parseCliArgs supports --unsetup target" {
    const opts = try parseCliArgs(&.{ "--unsetup", "claude" });
    try std.testing.expectEqual(Action.unsetup, opts.action);
    try std.testing.expectEqual(Target.claude, opts.target);
}

test "containsRtkIntegration detects common RTK markers" {
    try std.testing.expect(containsRtkIntegration("plugin: run-toolkit"));
    try std.testing.expect(containsRtkIntegration("{\"name\":\"rtk\"}"));
    try std.testing.expect(!containsRtkIntegration("plugin: smll-proxy"));
}
