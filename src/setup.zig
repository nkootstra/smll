const std = @import("std");

// --- Minimal JSON value types (replaces std.json.Value to shrink binary) ---

const JKV = struct { key: []const u8, val: JValue };

const JObject = struct {
    items: std.ArrayList(JKV),

    const empty: JObject = .{ .items = .empty };

    fn get(self: JObject, key: []const u8) ?JValue {
        for (self.items.items) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.val;
        return null;
    }
    fn getPtr(self: *JObject, key: []const u8) ?*JValue {
        for (self.items.items) |*kv| if (std.mem.eql(u8, kv.key, key)) return &kv.val;
        return null;
    }
    fn put(self: *JObject, pa: std.mem.Allocator, key: []const u8, val: JValue) !void {
        for (self.items.items) |*kv| {
            if (std.mem.eql(u8, kv.key, key)) { kv.val = val; return; }
        }
        try self.items.append(pa, .{ .key = key, .val = val });
    }
    fn contains(self: JObject, key: []const u8) bool {
        return self.get(key) != null;
    }
    fn iterator(self: *const JObject) Iterator {
        return .{ .items = self.items.items, .pos = 0 };
    }
    const Iterator = struct {
        items: []const JKV,
        pos: usize,
        fn next(self: *Iterator) ?struct { key_ptr: *const []const u8, value_ptr: *const JValue } {
            if (self.pos >= self.items.len) return null;
            const kv = &self.items[self.pos];
            self.pos += 1;
            return .{ .key_ptr = &kv.key, .value_ptr = &kv.val };
        }
    };
};

const JArray = struct {
    items: []JValue = &.{},
    list: std.ArrayList(JValue) = .empty,
    pa: std.mem.Allocator = undefined,

    fn init(pa: std.mem.Allocator) JArray {
        return .{ .pa = pa };
    }
    fn append(self: *JArray, val: JValue) !void {
        try self.list.append(self.pa, val);
        self.items = self.list.items;
    }
    fn swapRemove(self: *JArray, idx: usize) JValue {
        const val = self.list.items[idx];
        _ = self.list.swapRemove(idx);
        self.items = self.list.items;
        return val;
    }
};

const JValue = union(enum) {
    null,
    bool: bool,
    integer: i64,
    string: []const u8,
    array: JArray,
    object: JObject,
};

const JParsed = struct {
    arena: *std.heap.ArenaAllocator,
    value: JValue,

    fn deinit(self: JParsed) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

/// Concatenate two byte slices into allocator-owned memory.
fn concat2(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, a.len + b.len);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..], b);
    return buf;
}

const Target = enum {
    claude,
    opencode,
    cursor,
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
    if (std.mem.eql(u8, s, "cursor")) return .cursor;
    return null;
}

fn printUsage(stderr: *std.Io.Writer) !void {
    try stderr.writeAll("Usage: smll --[un]setup[=]<claude|opencode|cursor> [--dry-run]\n");
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
            .cursor => try setupCursor(allocator, io, home, opts.dry_run, stdout, stderr),
        },
        .unsetup => switch (opts.target) {
            .claude => try unsetupClaude(allocator, io, home, opts.dry_run, stdout, stderr),
            .opencode => try unsetupOpencode(allocator, io, home, opts.dry_run, stdout, stderr),
            .cursor => try unsetupCursor(allocator, io, home, opts.dry_run, stdout, stderr),
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
    const settings_path = try concat2(allocator, home, "/.claude/settings.json");
    defer allocator.free(settings_path);

    const hook_script_path = try concat2(allocator, home, "/.claude/hooks/smll-pretooluse.sh");
    defer allocator.free(hook_script_path);

    const hook_command = try concat2(allocator, "bash ", hook_script_path);
    defer allocator.free(hook_command);

    const existing_settings = try readFileOptional(allocator, io, settings_path);
    defer if (existing_settings) |buf| allocator.free(buf);

    if (try checkRtkConflict(existing_settings, "claude", "settings.json", stderr)) return 1;

    var settings_json = loadOrCreateJsonObject(allocator, existing_settings, false) catch {
        try writeJsonError(stderr, "settings.json");
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
        try writeOrReport(allocator, io, hook_script_path, hook_script, dry_run, stdout);
    } else {
        try stdout.writeAll("hook up to date\n");
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
    const plugin_dir = try concat2(allocator, home, "/.config/opencode/plugins/smll-proxy");
    defer allocator.free(plugin_dir);
    const index_path = try concat2(allocator, plugin_dir, "/index.ts");
    defer allocator.free(index_path);
    const pkg_path = try concat2(allocator, plugin_dir, "/package.json");
    defer allocator.free(pkg_path);
    const config_path = try concat2(allocator, home, "/.config/opencode/opencode.json");
    defer allocator.free(config_path);

    // Check for RTK conflict.
    const existing_config = try readFileOptional(allocator, io, config_path);
    defer if (existing_config) |buf| allocator.free(buf);
    if (try checkRtkConflict(existing_config, "opencode", "opencode.json", stderr)) return 1;

    // Write plugin package (index.ts + package.json).
    const plugin_script = buildOpencodePluginScript();
    const pkg_json = "{\"name\":\"smll-proxy\",\"version\":\"1.0.0\",\"type\":\"module\",\"main\":\"index.ts\"}\n";

    const existing_index = try readFileOptional(allocator, io, index_path);
    defer if (existing_index) |buf| allocator.free(buf);
    const index_same = if (existing_index) |buf| std.mem.eql(u8, buf, plugin_script) else false;

    if (!index_same) {
        try writeOrReport(allocator, io, index_path, plugin_script, dry_run, stdout);
        try writeOrReport(allocator, io, pkg_path, pkg_json, dry_run, stdout);
    } else {
        try stdout.writeAll("plugin up to date\n");
    }

    // Register plugin in opencode.json plugin array.
    var config_json = loadOrCreateJsonObject(allocator, existing_config, false) catch {
        try writeJsonError(stderr, "opencode.json");
        return 1;
    };
    defer config_json.deinit();

    const pa = config_json.arena.allocator();
    const already_registered = try ensureOpencodePluginEnabled(pa, &config_json.value, plugin_dir);

    if (!already_registered) {
        try writeBackupIfExists(allocator, io, config_path, dry_run);
        try writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
    } else {
        try stdout.writeAll("opencode config already has smll plugin\n");
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
    const settings_path = try concat2(allocator, home, "/.claude/settings.json");
    defer allocator.free(settings_path);

    const hook_script_path = try concat2(allocator, home, "/.claude/hooks/smll-pretooluse.sh");
    defer allocator.free(hook_script_path);

    const hook_command = try concat2(allocator, "bash ", hook_script_path);
    defer allocator.free(hook_command);

    var changed_settings = false;
    const existing_settings = try readFileOptional(allocator, io, settings_path);
    defer if (existing_settings) |buf| allocator.free(buf);

    if (existing_settings) |_| {
        var settings_json = loadOrCreateJsonObject(allocator, existing_settings, false) catch {
            try writeJsonError(stderr, "settings.json");
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
        try deleteOrReport(allocator, io, hook_script_path, dry_run, stdout);
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
    _ = stderr;
    const index_path = try concat2(allocator, home, "/.config/opencode/plugins/smll-proxy/index.ts");
    defer allocator.free(index_path);
    const pkg_path = try concat2(allocator, home, "/.config/opencode/plugins/smll-proxy/package.json");
    defer allocator.free(pkg_path);
    // Also clean up legacy single-file plugin if present.
    const legacy_path = try concat2(allocator, home, "/.config/opencode/plugins/smll-proxy.ts");
    defer allocator.free(legacy_path);

    var deleted_any = false;
    for ([_][]const u8{ index_path, pkg_path, legacy_path }) |path| {
        const existing = try readFileOptional(allocator, io, path);
        defer if (existing) |buf| allocator.free(buf);
        if (existing != null) {
            try deleteOrReport(allocator, io, path, dry_run, stdout);
            deleted_any = true;
        }
    }

    if (!dry_run) try stdout.writeAll("done: opencode unsetup complete\n");
    return 0;
}

fn setupCursor(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const hooks_json_path = try concat2(allocator, home, "/.cursor/hooks.json");
    defer allocator.free(hooks_json_path);

    const hook_script_path = try concat2(allocator, home, "/.cursor/hooks/smll-pretooluse.sh");
    defer allocator.free(hook_script_path);

    const hook_command = try concat2(allocator, "bash ", hook_script_path);
    defer allocator.free(hook_command);

    const existing = try readFileOptional(allocator, io, hooks_json_path);
    defer if (existing) |buf| allocator.free(buf);

    if (try checkRtkConflict(existing, "cursor", "hooks.json", stderr)) return 1;

    var hooks_json = loadOrCreateJsonObject(allocator, existing, true) catch {
        try writeJsonError(stderr, "hooks.json");
        return 1;
    };
    defer hooks_json.deinit();

    const pa = hooks_json.arena.allocator();
    const already_installed = try ensureCursorPreToolHook(pa, &hooks_json.value, hook_command);

    if (!already_installed) {
        try writeBackupIfExists(allocator, io, hooks_json_path, dry_run);
        try writeJsonValueToPath(allocator, io, hooks_json_path, hooks_json.value, dry_run, stdout);
    } else {
        try stdout.writeAll("cursor hooks.json already contains smll hook\n");
    }

    const hook_script = buildCursorHookScript();
    const existing_hook = try readFileOptional(allocator, io, hook_script_path);
    defer if (existing_hook) |buf| allocator.free(buf);

    const hook_same = if (existing_hook) |buf| std.mem.eql(u8, buf, hook_script) else false;
    if (!hook_same) {
        try writeOrReport(allocator, io, hook_script_path, hook_script, dry_run, stdout);
    } else {
        try stdout.writeAll("hook up to date\n");
    }

    if (!dry_run) try stdout.writeAll("done: cursor setup installed\n");
    return 0;
}

fn unsetupCursor(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const hooks_json_path = try concat2(allocator, home, "/.cursor/hooks.json");
    defer allocator.free(hooks_json_path);

    const hook_script_path = try concat2(allocator, home, "/.cursor/hooks/smll-pretooluse.sh");
    defer allocator.free(hook_script_path);

    const hook_command = try concat2(allocator, "bash ", hook_script_path);
    defer allocator.free(hook_command);

    var changed = false;
    const existing = try readFileOptional(allocator, io, hooks_json_path);
    defer if (existing) |buf| allocator.free(buf);

    if (existing) |_| {
        var hooks_json = loadOrCreateJsonObject(allocator, existing, true) catch {
            try writeJsonError(stderr, "hooks.json");
            return 1;
        };
        defer hooks_json.deinit();

        changed = try removeCursorPreToolHook(&hooks_json.value, hook_command);
        if (changed) {
            try writeBackupIfExists(allocator, io, hooks_json_path, dry_run);
            try writeJsonValueToPath(allocator, io, hooks_json_path, hooks_json.value, dry_run, stdout);
        } else {
            try stdout.writeAll("cursor hooks.json: no smll hook entry found\n");
        }
    } else {
        try stdout.writeAll("cursor hooks.json: file not found, nothing to remove\n");
    }

    const existing_hook = try readFileOptional(allocator, io, hook_script_path);
    defer if (existing_hook) |buf| allocator.free(buf);
    if (existing_hook != null) {
        try deleteOrReport(allocator, io, hook_script_path, dry_run, stdout);
    }

    if (!dry_run) try stdout.writeAll("done: cursor unsetup complete\n");
    return 0;
}


fn ensureCursorPreToolHook(pa: std.mem.Allocator, root: *JValue, hook_command: []const u8) !bool {
    if (root.* != .object) return SetupError.InvalidSettingsJson;
    const root_obj = &root.object;

    // Ensure version field
    if (!root_obj.contains("version")) {
        try root_obj.put(pa, "version", .{ .integer = 1 });
    }

    const hooks_val = try ensureObjectField(pa, root_obj, "hooks");
    if (hooks_val.* != .object) return SetupError.InvalidSettingsJson;
    const hooks_obj = &hooks_val.object;

    const pre_tool_use_val = try ensureArrayField(pa, hooks_obj, "preToolUse");
    if (pre_tool_use_val.* != .array) return SetupError.InvalidSettingsJson;

    // Check if already installed
    for (pre_tool_use_val.array.items) |entry| {
        if (entry != .object) continue;
        const cmd = entry.object.get("command") orelse continue;
        if (cmd != .string) continue;
        if (std.mem.eql(u8, cmd.string, hook_command)) return true;
    }

    // Add new entry: { "command": "bash ~/.cursor/hooks/smll-pretooluse.sh", "matcher": "Shell" }
    var entry_obj: JObject = .empty;
    try entry_obj.put(pa, "command", .{ .string = try pa.dupe(u8, hook_command) });
    try entry_obj.put(pa, "matcher", .{ .string = try pa.dupe(u8, "Shell") });
    try pre_tool_use_val.array.append(.{ .object = entry_obj });
    return false;
}

fn removeCursorPreToolHook(root: *JValue, hook_command: []const u8) !bool {
    if (root.* != .object) return SetupError.InvalidSettingsJson;
    const hooks_val = root.object.getPtr("hooks") orelse return false;
    if (hooks_val.* != .object) return SetupError.InvalidSettingsJson;
    const pre_val = hooks_val.object.getPtr("preToolUse") orelse return false;
    if (pre_val.* != .array) return SetupError.InvalidSettingsJson;

    var removed = false;
    var i: usize = 0;
    while (i < pre_val.array.items.len) {
        const entry = pre_val.array.items[i];
        if (entry != .object) { i += 1; continue; }
        const cmd = entry.object.get("command") orelse { i += 1; continue; };
        if (cmd != .string) { i += 1; continue; }
        if (std.mem.eql(u8, cmd.string, hook_command)) {
            _ = pre_val.array.swapRemove(i);
            removed = true;
            continue;
        }
        i += 1;
    }
    return removed;
}

const hook_prefix =
    \\#!/usr/bin/env bash
    \\set -euo pipefail
    \\command -v jq>/dev/null 2>&1||exit 0
    \\p="$(cat)";c="$(printf '%s' "$p"|jq -r '.tool_input.command // ""')"
    \\[ -z "$c" ]&&exit 0;[[ "$c" =~ ^[[:space:]]*smll([[:space:]]|$) ]]&&exit 0
    \\t="${c#"${c%%[![:space:]]*}"}";f="${t%%[[:space:]]*}"
    \\case "$f" in git|rg|tree|find|docker|kubectl|gh|ps|ls|du|curl|make|cargo|pytest|jest|vitest|go|tsc|npm|pnpm|yarn|bun|cat)
;

fn buildCursorHookScript() []const u8 {
    return hook_prefix ++
    \\printf '{"decision":"block","reason":"wrap with smll: smll %s"}' "$c";exit 0;;*)exit 0;;esac
    ;
}

fn loadOrCreateJsonObject(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    needs_version: bool,
) !JParsed {
    const input = blk: {
        if (existing) |buf| {
            if (std.mem.trim(u8, buf, " \t\r\n").len == 0) break :blk if (needs_version) "{\"version\":1}" else "{}";
            break :blk buf;
        }
        break :blk if (needs_version) "{\"version\":1}" else "{}";
    };
    return try miniJsonParse(allocator, input);
}

fn ensureClaudePreToolHook(pa: std.mem.Allocator, root: *JValue, hook_command: []const u8) !bool {
    if (root.* != .object) return SetupError.InvalidSettingsJson;
    const root_obj = &root.object;

    const hooks_val = try ensureObjectField(pa, root_obj, "hooks");
    if (hooks_val.* != .object) return SetupError.InvalidSettingsJson;
    const hooks_obj = &hooks_val.object;

    const pre_tool_use_val = try ensureArrayField(pa, hooks_obj, "PreToolUse");
    if (pre_tool_use_val.* != .array) return SetupError.InvalidSettingsJson;

    if (claudePreToolHookExists(pre_tool_use_val.array.items, hook_command)) return true;

    var cmd_obj: JObject = .empty;
    try cmd_obj.put(pa, "type", .{ .string = try pa.dupe(u8, "command") });
    try cmd_obj.put(pa, "command", .{ .string = try pa.dupe(u8, hook_command) });
    try cmd_obj.put(pa, "timeout", .{ .integer = 10 });

    var hook_handlers = JArray.init(pa);
    try hook_handlers.append(.{ .object = cmd_obj });

    var matcher_obj: JObject = .empty;
    try matcher_obj.put(pa, "matcher", .{ .string = try pa.dupe(u8, "Bash") });
    try matcher_obj.put(pa, "hooks", .{ .array = hook_handlers });

    try pre_tool_use_val.array.append(.{ .object = matcher_obj });
    return false;
}

fn removeClaudePreToolHook(root: *JValue, hook_command: []const u8) !bool {
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

fn isClaudeHookEntryForCommand(entry: JValue, hook_command: []const u8) bool {
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

fn claudePreToolHookExists(entries: []const JValue, hook_command: []const u8) bool {
    for (entries) |entry| {
        if (isClaudeHookEntryForCommand(entry, hook_command)) return true;
    }
    return false;
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

fn ensureObjectField(pa: std.mem.Allocator, obj: *JObject, key: []const u8) !*JValue {
    if (obj.getPtr(key)) |v| return v;
    try obj.put(pa, key, .{ .object = .empty });
    return obj.getPtr(key).?;
}

fn ensureArrayField(pa: std.mem.Allocator, obj: *JObject, key: []const u8) !*JValue {
    if (obj.getPtr(key)) |v| return v;
    const arr = JArray.init(pa);
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

    const backup_path = try concat2(allocator, path, ".bak.smll");
    defer allocator.free(backup_path);
    try writeFileEnsuringParent(io, backup_path, existing.?);
}

fn writeFileEnsuringParent(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.mem.findScalarLast(u8, path, '/')) |idx| {
        try std.Io.Dir.cwd().createDirPath(io, path[0..idx]);
    }
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    });
}

/// Write or dry-run a file, with backup and status output.
fn writeOrReport(allocator: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8, dry_run: bool, stdout: *std.Io.Writer) !void {
    try writeBackupIfExists(allocator, io, path, dry_run);
    if (dry_run) {
        try stdout.writeAll("[dry-run] would write "); try stdout.writeAll(path); try stdout.writeByte('\n');
    } else {
        try writeFileEnsuringParent(io, path, data);
        try stdout.writeAll("wrote "); try stdout.writeAll(path); try stdout.writeByte('\n');
    }
}

/// Delete or dry-run a file, with backup and status output.
fn deleteOrReport(allocator: std.mem.Allocator, io: std.Io, path: []const u8, dry_run: bool, stdout: *std.Io.Writer) !void {
    try writeBackupIfExists(allocator, io, path, dry_run);
    if (dry_run) {
        try stdout.writeAll("[dry-run] would delete "); try stdout.writeAll(path); try stdout.writeByte('\n');
    } else {
        try deleteFileIfExists(io, path);
        try stdout.writeAll("deleted "); try stdout.writeAll(path); try stdout.writeByte('\n');
    }
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

/// Minimal JSON serializer for JValue — avoids pulling in std.json.Stringify.
fn writeJsonValue(w: *std.Io.Writer, val: JValue, depth: usize) !void {
    switch (val) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| {
            if (i < 0) {
                try w.writeByte('-');
                var n: u64 = @intCast(-i);
                var buf: [20]u8 = undefined;
                var pos: usize = buf.len;
                if (n == 0) { pos -= 1; buf[pos] = '0'; } else while (n > 0) { pos -= 1; buf[pos] = @intCast('0' + n % 10); n /= 10; }
                try w.writeAll(buf[pos..]);
            } else {
                var n: u64 = @intCast(i);
                var buf: [20]u8 = undefined;
                var pos: usize = buf.len;
                if (n == 0) { pos -= 1; buf[pos] = '0'; } else while (n > 0) { pos -= 1; buf[pos] = @intCast('0' + n % 10); n /= 10; }
                try w.writeAll(buf[pos..]);
            }
        },
        .string => |s| {
            try w.writeByte('"');
            for (s) |c| {
                switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(c),
                }
            }
            try w.writeByte('"');
        },
        .array => |arr| {
            try w.writeAll("[\n");
            for (arr.items, 0..) |item, idx| {
                try writeIndent(w, depth + 1);
                try writeJsonValue(w, item, depth + 1);
                if (idx + 1 < arr.items.len) try w.writeByte(',');
                try w.writeByte('\n');
            }
            try writeIndent(w, depth);
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeAll("{\n");
            var it = obj.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try w.writeAll(",\n");
                first = false;
                try writeIndent(w, depth + 1);
                try w.writeByte('"');
                try w.writeAll(kv.key_ptr.*);
                try w.writeAll("\": ");
                try writeJsonValue(w, kv.value_ptr.*, depth + 1);
            }
            if (!first) try w.writeByte('\n');
            try writeIndent(w, depth);
            try w.writeByte('}');
        },
    }
}

fn writeIndent(w: *std.Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

fn writeJsonValueToPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    value: JValue,
    dry_run: bool,
    stdout: *std.Io.Writer,
) !void {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeJsonValue(&out.writer, value, 0);
    try out.writer.writeByte('\n');

    if (dry_run) {
        try stdout.writeAll("[dry-run] would update ");  try stdout.writeAll(path); try stdout.writeByte('\n');
    } else {
        try writeFileEnsuringParent(io, path, out.written());
        try stdout.writeAll("updated ");  try stdout.writeAll(path); try stdout.writeByte('\n');
    }
}

fn buildClaudeHookScript() []const u8 {
    return hook_prefix ++
    \\echo "smll hook: wrap noisy command with smll (example: smll $c)">&2;exit 2;;*)exit 0;;esac
    ;
}

fn buildOpencodePluginScript() []const u8 {
    return
    \\const W=new Set(["git","rg","tree","find","docker","kubectl","gh","ps","ls","du","curl","make","cargo","pytest","jest","vitest","go","tsc","npm","pnpm","yarn","bun","cat"]);
    \\export const SmllProxyPlugin=async({$})=>({"tool.execute.before":async(i,o)=>{const t=String(i?.tool??"").toLowerCase();if(t!=="bash"&&t!=="shell")return;const a=o?.args;if(!a||typeof a!=="object")return;const c=(a.command??"").trim();if(!c||/^smll(\\s|$)/.test(c))return;const f=c.split(/\\s+/)[0];if(W.has(f))a.command=`smll ${c}`}});
    ;
}

fn writeJsonError(stderr: *std.Io.Writer, file: []const u8) !void {
    try stderr.writeAll(file);
    try stderr.writeAll(": invalid JSON\n");
}

fn checkRtkConflict(data: ?[]const u8, target: []const u8, file: []const u8, stderr: *std.Io.Writer) !bool {
    const buf = data orelse return false;
    if (!containsRtkIntegration(buf)) return false;
    try stderr.writeAll("RTK detected in ");
    try stderr.writeAll(file);
    try stderr.writeAll(". Remove RTK first, then run smll --setup ");
    try stderr.writeAll(target);
    try stderr.writeAll(" again.\n");
    return true;
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

/// Minimal JSON parser producing JValue. Handles objects, arrays,
/// strings, integers, booleans, and null — sufficient for settings/hooks JSON.
/// Replaces std.json.parseFromSlice to avoid pulling in the full std.json parser.
fn miniJsonParse(child_allocator: std.mem.Allocator, input: []const u8) !JParsed {
    const arena = try child_allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(child_allocator);
    errdefer {
        arena.deinit();
        child_allocator.destroy(arena);
    }
    const pa = arena.allocator();
    var pos: usize = 0;
    const value = try parseValue(pa, input, &pos);
    return .{ .arena = arena, .value = value };
}

fn skipWs(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and (input[pos.*] == ' ' or input[pos.*] == '\t' or input[pos.*] == '\n' or input[pos.*] == '\r')) pos.* += 1;
}

const JsonParseError = error{ UnexpectedEndOfInput, OutOfMemory };

fn parseValue(pa: std.mem.Allocator, input: []const u8, pos: *usize) JsonParseError!JValue {
    skipWs(input, pos);
    if (pos.* >= input.len) return error.UnexpectedEndOfInput;
    return switch (input[pos.*]) {
        '{' => try parseObject(pa, input, pos),
        '[' => try parseArray(pa, input, pos),
        '"' => .{ .string = try parseString(pa, input, pos) },
        't' => blk: { pos.* += 4; break :blk .{ .bool = true }; },
        'f' => blk: { pos.* += 5; break :blk .{ .bool = false }; },
        'n' => blk: { pos.* += 4; break :blk .null; },
        '-', '0'...'9' => try parseNumber(input, pos),
        else => error.UnexpectedEndOfInput,
    };
}

fn parseObject(pa: std.mem.Allocator, input: []const u8, pos: *usize) JsonParseError!JValue {
    pos.* += 1; // skip {
    var obj: JObject = .empty;
    skipWs(input, pos);
    if (pos.* < input.len and input[pos.*] == '}') { pos.* += 1; return .{ .object = obj }; }
    while (pos.* < input.len) {
        skipWs(input, pos);
        const key = try parseString(pa, input, pos);
        skipWs(input, pos);
        if (pos.* < input.len and input[pos.*] == ':') pos.* += 1;
        const val = try parseValue(pa, input, pos);
        try obj.put(pa, key, val);
        skipWs(input, pos);
        if (pos.* < input.len and input[pos.*] == ',') { pos.* += 1; continue; }
        break;
    }
    skipWs(input, pos);
    if (pos.* < input.len and input[pos.*] == '}') pos.* += 1;
    return .{ .object = obj };
}

fn parseArray(pa: std.mem.Allocator, input: []const u8, pos: *usize) JsonParseError!JValue {
    pos.* += 1; // skip [
    var arr = JArray.init(pa);
    skipWs(input, pos);
    if (pos.* < input.len and input[pos.*] == ']') { pos.* += 1; return .{ .array = arr }; }
    while (pos.* < input.len) {
        const val = try parseValue(pa, input, pos);
        try arr.append(val);
        skipWs(input, pos);
        if (pos.* < input.len and input[pos.*] == ',') { pos.* += 1; continue; }
        break;
    }
    skipWs(input, pos);
    if (pos.* < input.len and input[pos.*] == ']') pos.* += 1;
    return .{ .array = arr };
}

fn parseString(pa: std.mem.Allocator, input: []const u8, pos: *usize) JsonParseError![]const u8 {
    if (pos.* >= input.len or input[pos.*] != '"') return error.UnexpectedEndOfInput;
    pos.* += 1;
    const start = pos.*;
    var has_escape = false;
    while (pos.* < input.len and input[pos.*] != '"') {
        if (input[pos.*] == '\\') { has_escape = true; pos.* += 2; } else pos.* += 1;
    }
    const raw = input[start..pos.*];
    if (pos.* < input.len) pos.* += 1; // skip closing "
    if (!has_escape) return raw;
    // Unescape
    var buf = try pa.alloc(u8, raw.len);
    var i: usize = 0;
    var o: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            buf[o] = switch (raw[i]) { 'n' => '\n', 'r' => '\r', 't' => '\t', else => raw[i] };
            o += 1; i += 1;
        } else { buf[o] = raw[i]; o += 1; i += 1; }
    }
    return buf[0..o];
}

fn parseNumber(input: []const u8, pos: *usize) JsonParseError!JValue {
    const start = pos.*;
    if (input[pos.*] == '-') pos.* += 1;
    while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') pos.* += 1;
    // Skip fractional / exponent parts (treat as integer if no fraction)
    if (pos.* < input.len and input[pos.*] == '.') {
        pos.* += 1;
        while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') pos.* += 1;
    }
    if (pos.* < input.len and (input[pos.*] == 'e' or input[pos.*] == 'E')) {
        pos.* += 1;
        if (pos.* < input.len and (input[pos.*] == '+' or input[pos.*] == '-')) pos.* += 1;
        while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') pos.* += 1;
    }
    const num_str = input[start..pos.*];
    // Parse as integer
    var neg = false;
    var idx: usize = 0;
    if (num_str[0] == '-') { neg = true; idx = 1; }
    var val: i64 = 0;
    while (idx < num_str.len and num_str[idx] >= '0' and num_str[idx] <= '9') {
        val = val *| 10 +| (num_str[idx] - '0');
        idx += 1;
    }
    return .{ .integer = if (neg) -val else val };
}
