const std = @import("std");
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
        .hook = .{ .nested = .{
            .event_field = "PreToolUse",
            .matcher = "Bash",
            .status_message = "Checking smll wrapper eligibility",
        } },
    };
}

pub fn setup(
    backing_allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    spec: Spec,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config_path = try setup_io.concat2(allocator, home, spec.config_path_suffix);

    const hook_script_path = try setup_io.concat2(allocator, home, spec.script_path_suffix);

    const executable_path = try std.process.executablePathAlloc(io, allocator);
    if (!try setup_io.validateHookEvaluator(allocator, io, executable_path, spec.target, stderr)) return 1;
    const escaped_executable = try setup_io.shellEscapeAlloc(allocator, executable_path);
    const eval_suffix = try setup_io.concat2(allocator, " --hook-eval ", spec.target);
    const hook_command = try setup_io.concat2(allocator, escaped_executable, eval_suffix);
    const legacy_hook_command = try setup_io.concat2(allocator, "bash ", hook_script_path);

    var ownership = setup_io.readOwnership(allocator, io, home, spec.target) catch setup_io.Ownership.missing;
    if (ownership == .modified) {
        try stderr.writeAll("smll setup ownership record was modified; configuration left untouched\n");
        return 1;
    }

    const existing = try setup_io.readFileOptional(allocator, io, config_path);

    if (try setup_io.checkConflictingIntegration(existing, spec.target, spec.config_file, stderr)) return 1;

    var config_json = setup_json.loadOrCreateObject(allocator, existing, spec.needs_version) catch {
        try setup_io.writeJsonError(stderr, spec.config_file);
        return 1;
    };
    defer config_json.deinit();

    const pa = config_json.arena.allocator();
    const removed_legacy = try removeHook(&config_json.value, spec.hook, legacy_hook_command);
    const removed_owned = if (ownership.validPayload()) |owned_command|
        if (!std.mem.eql(u8, owned_command, hook_command)) try removeHook(&config_json.value, spec.hook, owned_command) else false
    else
        false;
    const already_installed = try ensureHook(pa, &config_json.value, spec.hook, hook_command);
    const config_changed = !already_installed or removed_legacy or removed_owned;

    if (config_changed) {
        try setup_io.writeBackupIfExists(allocator, io, config_path, dry_run);
        try setup_io.writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
    } else {
        try stdout.writeAll("already installed\n");
    }

    if (dry_run) {
        try stdout.writeAll("[dry-run] would record smll hook ownership\n");
    } else {
        setup_io.writeOwnership(allocator, io, home, spec.target, hook_command) catch |err| {
            if (config_changed) try setup_io.restoreOptional(io, config_path, existing);
            return err;
        };
    }

    const existing_hook = try setup_io.readFileOptional(allocator, io, hook_script_path);
    if (existing_hook != null) try stderr.writeAll("legacy hook script left untouched because its ownership is unknown\n");

    if (!dry_run) try stdout.writeAll("ok\n");
    return 0;
}

pub fn unsetup(
    backing_allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    spec: Spec,
    dry_run: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config_path = try setup_io.concat2(allocator, home, spec.config_path_suffix);

    const hook_script_path = try setup_io.concat2(allocator, home, spec.script_path_suffix);

    var ownership = setup_io.readOwnership(allocator, io, home, spec.target) catch setup_io.Ownership.missing;

    const owned_command = ownership.validPayload();
    if (owned_command == null) {
        try stderr.writeAll(if (ownership == .modified)
            "smll hook ownership record was modified; no hook was removed\n"
        else
            "smll hook ownership record not found; no hook was removed\n");
    }

    const existing = try setup_io.readFileOptional(allocator, io, config_path);

    var removed_owned = false;
    if (existing != null and owned_command != null) {
        var config_json = setup_json.loadOrCreateObject(allocator, existing, spec.needs_version) catch {
            try setup_io.writeJsonError(stderr, spec.config_file);
            return 1;
        };
        defer config_json.deinit();

        removed_owned = try removeHook(&config_json.value, spec.hook, owned_command.?);
        if (removed_owned) {
            try setup_io.writeBackupIfExists(allocator, io, config_path, dry_run);
            try setup_io.writeJsonValueToPath(allocator, io, config_path, config_json.value, dry_run, stdout);
        } else {
            try stderr.writeAll("smll-owned hook entry was modified or removed; configuration left untouched\n");
        }
    } else if (existing == null) {
        try stdout.writeAll("not found\n");
    }

    if (removed_owned and !dry_run) try setup_io.deleteOwnership(allocator, io, home, spec.target);

    const existing_hook = try setup_io.readFileOptional(allocator, io, hook_script_path);
    if (existing_hook != null) try stderr.writeAll("legacy hook script left untouched because its ownership is unknown\n");

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
        var entry = &event_val.array.items[i];
        if (entry.* != .object) {
            i += 1;
            continue;
        }
        const handlers = entry.object.getPtr("hooks") orelse {
            i += 1;
            continue;
        };
        if (handlers.* != .array) {
            i += 1;
            continue;
        }

        var handler_index: usize = 0;
        while (handler_index < handlers.array.items.len) {
            const handler = handlers.array.items[handler_index];
            if (handler != .object) {
                handler_index += 1;
                continue;
            }
            const command = handler.object.get("command") orelse {
                handler_index += 1;
                continue;
            };
            if (command != .string or !std.mem.eql(u8, command.string, hook_command)) {
                handler_index += 1;
                continue;
            }
            _ = handlers.array.swapRemove(handler_index);
            changed = true;
        }
        if (handlers.array.items.len == 0) {
            _ = event_val.array.swapRemove(i);
        } else {
            i += 1;
        }
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

test "setup codex writes direct PreToolUse hook command" {
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
    try std.testing.expect(std.mem.find(u8, hooks_json, "--hook-eval codex") != null);
    try std.testing.expect(std.mem.find(u8, hooks_json, "\"command\":\"'") != null);
    try std.testing.expect(std.mem.find(u8, hooks_json, "smll-pretooluse.sh") == null);
    try std.testing.expect(std.mem.find(u8, hooks_json, "permissionDecision") == null);
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
    try std.testing.expect(std.mem.find(u8, hooks_json, "--hook-eval codex") == null);

    const script_file = tmp.dir.openFile(std.testing.io, ".codex/hooks/smll-pretooluse.sh", .{}) catch |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
        return;
    };
    script_file.close(std.testing.io);
    return error.UnexpectedHookScript;
}

test "unsetup leaves a modified owned hook entry and warns" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home_path);

    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();
    try std.testing.expectEqual(@as(u8, 0), try setup(allocator, std.testing.io, home_path, codexSpec(), false, &stdout.writer, &stderr.writer));

    const config_path = try setup_io.concat2(allocator, home_path, codexSpec().config_path_suffix);
    defer allocator.free(config_path);
    const original = try setup_io.readFileOptional(allocator, std.testing.io, config_path);
    defer allocator.free(original.?);
    const marker = " --hook-eval codex";
    const at = std.mem.find(u8, original.?, marker) orelse return error.MissingHookCommand;
    const modified = try std.mem.concat(allocator, u8, &.{ original.?[0 .. at + marker.len], " --modified", original.?[at + marker.len ..] });
    defer allocator.free(modified);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = config_path, .data = modified });

    try std.testing.expectEqual(@as(u8, 0), try unsetup(allocator, std.testing.io, home_path, codexSpec(), false, &stdout.writer, &stderr.writer));
    const after = try setup_io.readFileOptional(allocator, std.testing.io, config_path);
    defer allocator.free(after.?);
    try std.testing.expect(std.mem.find(u8, after.?, "--hook-eval codex --modified") != null);
    try std.testing.expect(std.mem.find(u8, stderr.written(), "modified") != null);
}

test "setup rolls back config when ownership cannot be recorded" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home_path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(home_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".smll", .data = "blocks ownership directory\n" });

    var stdout = std.Io.Writer.Allocating.init(allocator);
    defer stdout.deinit();
    var stderr = std.Io.Writer.Allocating.init(allocator);
    defer stderr.deinit();
    if (setup(allocator, std.testing.io, home_path, codexSpec(), false, &stdout.writer, &stderr.writer)) |_| {
        return error.ExpectedSetupFailure;
    } else |_| {}

    const config_path = try setup_io.concat2(allocator, home_path, codexSpec().config_path_suffix);
    defer allocator.free(config_path);
    try std.testing.expect((try setup_io.readFileOptional(allocator, std.testing.io, config_path)) == null);
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
    try std.testing.expect(std.mem.find(u8, hooks_json, "--hook-eval cursor") != null);

    try std.testing.expectEqual(
        @as(u8, 0),
        try unsetup(allocator, std.testing.io, home_path, cursorSpec(), false, &stdout.writer, &stderr.writer),
    );

    const updated_json = try tmp.dir.readFileAlloc(std.testing.io, ".cursor/hooks.json", allocator, .limited(4096));
    defer allocator.free(updated_json);
    try std.testing.expect(std.mem.find(u8, updated_json, "--hook-eval cursor") == null);
}

test "nested hook removal preserves unrelated handlers in the same matcher" {
    const allocator = std.testing.allocator;
    var parsed = try setup_json.parse(allocator,
        \\{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"smll-owned"},{"type":"command","command":"keep-me"}]}]}}
    );
    defer parsed.deinit();

    try std.testing.expect(try removeHook(&parsed.value, codexSpec().hook, "smll-owned"));
    var rendered = std.Io.Writer.Allocating.init(allocator);
    defer rendered.deinit();
    try setup_json.writeValue(&rendered.writer, parsed.value);
    try std.testing.expect(std.mem.find(u8, rendered.written(), "smll-owned") == null);
    try std.testing.expect(std.mem.find(u8, rendered.written(), "keep-me") != null);
}
