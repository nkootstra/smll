const std = @import("std");
const filter_catalog = @import("filter_catalog.zig");
const setup_io = @import("setup_io.zig");
const setup_json = @import("setup_json.zig");

const JObject = setup_json.Object;
const JArray = setup_json.Array;
const JValue = setup_json.Value;

const HookError = error{
    InvalidSettingsJson,
};

pub const Spec = struct {
    target: []const u8,
    config_file: []const u8,
    config_path_suffix: []const u8,
    script_path_suffix: []const u8,
    script: []const u8,
    needs_version: bool = false,
    hook: HookConfig,
};

const HookConfig = union(enum) {
    nested: NestedCommandHook,
    flat: FlatCommandHook,
};

const NestedCommandHook = struct {
    event_field: []const u8,
    matcher: []const u8,
    status_message: ?[]const u8 = null,
};

const FlatCommandHook = struct {
    event_field: []const u8,
    matcher: []const u8,
    ensure_version: bool = false,
};

pub fn claudeSpec() Spec {
    return .{
        .target = "claude",
        .config_file = "settings.json",
        .config_path_suffix = "/.claude/settings.json",
        .script_path_suffix = "/.claude/hooks/smll-pretooluse.sh",
        .script = buildClaudeHookScript(),
        .hook = .{ .nested = .{
            .event_field = "PreToolUse",
            .matcher = "Bash",
        } },
    };
}

pub fn cursorSpec() Spec {
    return .{
        .target = "cursor",
        .config_file = "hooks.json",
        .config_path_suffix = "/.cursor/hooks.json",
        .script_path_suffix = "/.cursor/hooks/smll-pretooluse.sh",
        .script = buildCursorHookScript(),
        .needs_version = true,
        .hook = .{ .flat = .{
            .event_field = "preToolUse",
            .matcher = "Shell",
            .ensure_version = true,
        } },
    };
}

pub fn codexSpec() Spec {
    return .{
        .target = "codex",
        .config_file = "hooks.json",
        .config_path_suffix = "/.codex/hooks.json",
        .script_path_suffix = "/.codex/hooks/smll-pretooluse.sh",
        .script = buildCodexHookScript(),
        .hook = .{ .nested = .{
            .event_field = "PreToolUse",
            .matcher = "Bash",
            .status_message = "Wrapping Bash command with smll",
        } },
    };
}

pub fn setup(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    spec: Spec,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const config_path = try setup_io.concat2(allocator, home, spec.config_path_suffix);
    defer allocator.free(config_path);

    const hook_script_path = try setup_io.concat2(allocator, home, spec.script_path_suffix);
    defer allocator.free(hook_script_path);

    const hook_command = try setup_io.concat2(allocator, "bash ", hook_script_path);
    defer allocator.free(hook_command);

    const existing = try setup_io.readFileOptional(allocator, io, config_path);
    defer if (existing) |buf| allocator.free(buf);

    if (try setup_io.checkConflictingIntegration(existing, spec.target, spec.config_file, stderr)) return 1;

    var config_json = setup_json.loadOrCreateObject(allocator, existing, spec.needs_version) catch {
        try setup_io.writeJsonError(stderr, spec.config_file);
        return 1;
    };
    defer config_json.deinit();

    const pa = config_json.arena.allocator();
    const already_installed = try ensureHook(pa, &config_json.value, spec.hook, hook_command);

    if (!already_installed) {
        try setup_io.writeBackupIfExists(allocator, io, config_path, dry_run);
        try setup_io.writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
    } else {
        try stdout.writeAll("already installed\n");
    }

    const existing_hook = try setup_io.readFileOptional(allocator, io, hook_script_path);
    defer if (existing_hook) |buf| allocator.free(buf);

    const hook_same = if (existing_hook) |buf| std.mem.eql(u8, buf, spec.script) else false;
    if (!hook_same) {
        try setup_io.writeOrReport(allocator, io, hook_script_path, spec.script, dry_run, stdout);
    } else {
        try stdout.writeAll("hook up to date\n");
    }

    if (!dry_run) try stdout.writeAll("ok\n");
    return 0;
}

pub fn unsetup(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    spec: Spec,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const config_path = try setup_io.concat2(allocator, home, spec.config_path_suffix);
    defer allocator.free(config_path);

    const hook_script_path = try setup_io.concat2(allocator, home, spec.script_path_suffix);
    defer allocator.free(hook_script_path);

    const hook_command = try setup_io.concat2(allocator, "bash ", hook_script_path);
    defer allocator.free(hook_command);

    const existing = try setup_io.readFileOptional(allocator, io, config_path);
    defer if (existing) |buf| allocator.free(buf);

    if (existing) |_| {
        var config_json = setup_json.loadOrCreateObject(allocator, existing, spec.needs_version) catch {
            try setup_io.writeJsonError(stderr, spec.config_file);
            return 1;
        };
        defer config_json.deinit();

        const changed = try removeHook(&config_json.value, spec.hook, hook_command);
        if (changed) {
            try setup_io.writeBackupIfExists(allocator, io, config_path, dry_run);
            try setup_io.writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
        } else {
            try stdout.writeAll("no hook found\n");
        }
    } else {
        try stdout.writeAll("not found\n");
    }

    const existing_hook = try setup_io.readFileOptional(allocator, io, hook_script_path);
    defer if (existing_hook) |buf| allocator.free(buf);
    if (existing_hook != null) {
        try setup_io.deleteOrReport(allocator, io, hook_script_path, dry_run, stdout);
    }

    if (!dry_run) try stdout.writeAll("ok\n");
    return 0;
}

fn ensureHook(pa: std.mem.Allocator, root: *JValue, hook: HookConfig, hook_command: []const u8) !bool {
    return switch (hook) {
        .nested => |cfg| ensureNestedCommandHook(pa, root, cfg, hook_command),
        .flat => |cfg| ensureFlatCommandHook(pa, root, cfg, hook_command),
    };
}

fn removeHook(root: *JValue, hook: HookConfig, hook_command: []const u8) !bool {
    return switch (hook) {
        .nested => |cfg| removeNestedCommandHook(root, cfg, hook_command),
        .flat => |cfg| removeFlatCommandHook(root, cfg, hook_command),
    };
}

fn ensureNestedCommandHook(pa: std.mem.Allocator, root: *JValue, cfg: NestedCommandHook, hook_command: []const u8) !bool {
    if (root.* != .object) return HookError.InvalidSettingsJson;
    const root_obj = &root.object;

    const hooks_val = try ensureObjectField(pa, root_obj, "hooks");
    if (hooks_val.* != .object) return HookError.InvalidSettingsJson;
    const hooks_obj = &hooks_val.object;

    const event_val = try ensureArrayField(pa, hooks_obj, cfg.event_field);
    if (event_val.* != .array) return HookError.InvalidSettingsJson;

    if (nestedCommandHookExists(event_val.array.items, hook_command)) return true;

    var cmd_obj: JObject = .empty;
    try cmd_obj.put(pa, "type", .{ .string = try pa.dupe(u8, "command") });
    try cmd_obj.put(pa, "command", .{ .string = try pa.dupe(u8, hook_command) });
    try cmd_obj.put(pa, "timeout", .{ .integer = 10 });
    if (cfg.status_message) |status_message| {
        try cmd_obj.put(pa, "statusMessage", .{ .string = try pa.dupe(u8, status_message) });
    }

    var hook_handlers = JArray.init(pa);
    try hook_handlers.append(.{ .object = cmd_obj });

    var matcher_obj: JObject = .empty;
    try matcher_obj.put(pa, "matcher", .{ .string = try pa.dupe(u8, cfg.matcher) });
    try matcher_obj.put(pa, "hooks", .{ .array = hook_handlers });

    try event_val.array.append(.{ .object = matcher_obj });
    return false;
}

fn removeNestedCommandHook(root: *JValue, cfg: NestedCommandHook, hook_command: []const u8) !bool {
    if (root.* != .object) return HookError.InvalidSettingsJson;
    const hooks_val = root.object.getPtr("hooks") orelse return false;
    if (hooks_val.* != .object) return HookError.InvalidSettingsJson;
    const event_val = hooks_val.object.getPtr(cfg.event_field) orelse return false;
    if (event_val.* != .array) return HookError.InvalidSettingsJson;

    var changed = false;
    var i: usize = 0;
    while (i < event_val.array.items.len) {
        const entry = event_val.array.items[i];
        if (!isNestedCommandHookForCommand(entry, hook_command)) {
            i += 1;
            continue;
        }
        _ = event_val.array.swapRemove(i);
        changed = true;
    }

    return changed;
}

fn ensureFlatCommandHook(pa: std.mem.Allocator, root: *JValue, cfg: FlatCommandHook, hook_command: []const u8) !bool {
    if (root.* != .object) return HookError.InvalidSettingsJson;
    const root_obj = &root.object;

    if (cfg.ensure_version and !root_obj.contains("version")) {
        try root_obj.put(pa, "version", .{ .integer = 1 });
    }

    const hooks_val = try ensureObjectField(pa, root_obj, "hooks");
    if (hooks_val.* != .object) return HookError.InvalidSettingsJson;
    const hooks_obj = &hooks_val.object;

    const event_val = try ensureArrayField(pa, hooks_obj, cfg.event_field);
    if (event_val.* != .array) return HookError.InvalidSettingsJson;

    for (event_val.array.items) |entry| {
        if (entry != .object) continue;
        const cmd = entry.object.get("command") orelse continue;
        if (cmd != .string) continue;
        if (std.mem.eql(u8, cmd.string, hook_command)) return true;
    }

    var entry_obj: JObject = .empty;
    try entry_obj.put(pa, "command", .{ .string = try pa.dupe(u8, hook_command) });
    try entry_obj.put(pa, "matcher", .{ .string = try pa.dupe(u8, cfg.matcher) });
    try event_val.array.append(.{ .object = entry_obj });
    return false;
}

fn removeFlatCommandHook(root: *JValue, cfg: FlatCommandHook, hook_command: []const u8) !bool {
    if (root.* != .object) return HookError.InvalidSettingsJson;
    const hooks_val = root.object.getPtr("hooks") orelse return false;
    if (hooks_val.* != .object) return HookError.InvalidSettingsJson;
    const event_val = hooks_val.object.getPtr(cfg.event_field) orelse return false;
    if (event_val.* != .array) return HookError.InvalidSettingsJson;

    var removed = false;
    var i: usize = 0;
    while (i < event_val.array.items.len) {
        const entry = event_val.array.items[i];
        if (entry != .object) {
            i += 1;
            continue;
        }
        const cmd = entry.object.get("command") orelse {
            i += 1;
            continue;
        };
        if (cmd != .string) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, cmd.string, hook_command)) {
            _ = event_val.array.swapRemove(i);
            removed = true;
            continue;
        }
        i += 1;
    }
    return removed;
}

fn isNestedCommandHookForCommand(entry: JValue, hook_command: []const u8) bool {
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

fn nestedCommandHookExists(entries: []const JValue, hook_command: []const u8) bool {
    for (entries) |entry| {
        if (isNestedCommandHookForCommand(entry, hook_command)) return true;
    }
    return false;
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

const hook_prologue =
    \\#!/usr/bin/env bash
    \\set -euo pipefail
    \\command -v jq>/dev/null 2>&1||exit 0
    \\p="$(cat)";c="$(printf '%s' "$p"|jq -r '.tool_input.command // ""')"
    \\[ -z "$c" ]&&exit 0;[[ "$c" =~ ^[[:space:]]*smll([[:space:]]|$) ]]&&exit 0
    \\t="${c#"${c%%[![:space:]]*}"}";f="${t%%[[:space:]]*}"
;

const hook_prefix = hook_prologue ++ "case \"$f\" in " ++ filter_catalog.auto_wrap_shell_case ++ ")\n";

fn buildClaudeHookScript() []const u8 {
    return hook_prefix ++
        \\echo "smll hook: wrap noisy command with smll (example: smll $c)">&2;exit 2;;*)exit 0;;esac
    ;
}

fn buildCursorHookScript() []const u8 {
    return hook_prefix ++
        \\printf '{"decision":"block","reason":"wrap with smll: smll %s"}' "$c";exit 0;;*)exit 0;;esac
    ;
}

fn buildCodexHookScript() []const u8 {
    return hook_prefix ++
        \\jq -cn --arg command "smll $c" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":$command}}}';exit 0;;*)exit 0;;esac
    ;
}

test "setup codex writes PreToolUse hook and script" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home_path);

    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();

    const code = try setup(allocator, std.testing.io, home_path, codexSpec(), false, &stdout.writer, &stderr.writer);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expectEqualStrings("", stderr.written());

    const hooks_json = try tmp.dir.readFileAlloc(std.testing.io, ".codex/hooks.json", allocator, .limited(4096));
    defer allocator.free(hooks_json);
    try std.testing.expect(std.mem.find(u8, hooks_json, "\"PreToolUse\"") != null);
    try std.testing.expect(std.mem.find(u8, hooks_json, "\"matcher\":\"Bash\"") != null);
    try std.testing.expect(std.mem.find(u8, hooks_json, "\"command\":\"bash ") != null);
    try std.testing.expect(std.mem.find(u8, hooks_json, ".codex/hooks/smll-pretooluse.sh\"") != null);

    const hook_script = try tmp.dir.readFileAlloc(std.testing.io, ".codex/hooks/smll-pretooluse.sh", allocator, .limited(4096));
    defer allocator.free(hook_script);
    try std.testing.expect(std.mem.startsWith(u8, hook_script, "#!/usr/bin/env bash\n"));
    try std.testing.expect(std.mem.find(u8, hook_script, "\"permissionDecision\":\"allow\"") != null);
    try std.testing.expect(std.mem.find(u8, hook_script, "\"updatedInput\"") != null);
    try std.testing.expect(std.mem.find(u8, hook_script, "\"smll $c\"") != null);
    try std.testing.expect(std.mem.find(u8, hook_script, "terraform|tofu|aws|jq") != null);
}

test "unsetup codex removes PreToolUse hook and script" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home_path);

    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(
        @as(u8, 0),
        try setup(allocator, std.testing.io, home_path, codexSpec(), false, &stdout.writer, &stderr.writer),
    );

    try std.testing.expectEqual(
        @as(u8, 0),
        try unsetup(allocator, std.testing.io, home_path, codexSpec(), false, &stdout.writer, &stderr.writer),
    );

    const hooks_json = try tmp.dir.readFileAlloc(std.testing.io, ".codex/hooks.json", allocator, .limited(4096));
    defer allocator.free(hooks_json);
    try std.testing.expect(std.mem.find(u8, hooks_json, "smll-pretooluse.sh") == null);

    const script_file = tmp.dir.openFile(std.testing.io, ".codex/hooks/smll-pretooluse.sh", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    script_file.close(std.testing.io);
    return error.UnexpectedHookScript;
}

test "setup and unsetup cursor preserves flat hook shape" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home_path);

    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(
        @as(u8, 0),
        try setup(allocator, std.testing.io, home_path, cursorSpec(), false, &stdout.writer, &stderr.writer),
    );

    const hooks_json = try tmp.dir.readFileAlloc(std.testing.io, ".cursor/hooks.json", allocator, .limited(4096));
    defer allocator.free(hooks_json);
    try std.testing.expect(std.mem.find(u8, hooks_json, "\"version\":1") != null);
    try std.testing.expect(std.mem.find(u8, hooks_json, "\"preToolUse\"") != null);
    try std.testing.expect(std.mem.find(u8, hooks_json, "\"matcher\":\"Shell\"") != null);
    try std.testing.expect(std.mem.find(u8, hooks_json, ".cursor/hooks/smll-pretooluse.sh\"") != null);

    try std.testing.expectEqual(
        @as(u8, 0),
        try unsetup(allocator, std.testing.io, home_path, cursorSpec(), false, &stdout.writer, &stderr.writer),
    );

    const updated_json = try tmp.dir.readFileAlloc(std.testing.io, ".cursor/hooks.json", allocator, .limited(4096));
    defer allocator.free(updated_json);
    try std.testing.expect(std.mem.find(u8, updated_json, "smll-pretooluse.sh") == null);
}
