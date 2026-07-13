const std = @import("std");
const filter_catalog = @import("filter_catalog.zig");
const setup_io = @import("setup_io.zig");
const setup_json = @import("setup_json.zig");

const Adapter = enum { claude, cursor, codex, opencode };
const Quote = enum { unquoted, single, double };

pub fn maybeRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[1], "--hook-eval")) return null;
    if (args.len != 3) return 0;
    const adapter = std.meta.stringToEnum(Adapter, args[2]) orelse return 0;

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(allocator);
    var buf: [4096]u8 = undefined;
    var stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, &buf);
    stdin_reader.interface.appendRemaining(allocator, &input, .limited(64 * 1024)) catch return 0;

    var parsed = setup_json.parse(allocator, input.items) catch return 0;
    defer parsed.deinit();
    const command = eventCommand(parsed.value) orelse return 0;
    if (!isEligible(command)) return 0;

    const guidance = try std.fmt.allocPrint(allocator, "rerun through smll: smll {s}", .{command});
    defer allocator.free(guidance);
    return switch (adapter) {
        .claude => blk: {
            try stderr.writeAll("smll hook: wrap noisy command with smll (example: smll ");
            try stderr.writeAll(command);
            try stderr.writeAll(")\n");
            break :blk 2;
        },
        .cursor => blk: {
            try stdout.writeAll("{\"permission\":\"deny\",\"user_message\":");
            const user_message = try std.fmt.allocPrint(allocator, "wrap with smll: smll {s}", .{command});
            defer allocator.free(user_message);
            try setup_json.writeValue(stdout, .{ .string = user_message });
            try stdout.writeAll(",\"agent_message\":");
            try setup_json.writeValue(stdout, .{ .string = guidance });
            try stdout.writeAll("}\n");
            break :blk 0;
        },
        .codex => blk: {
            try stdout.writeAll("{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":");
            try setup_json.writeValue(stdout, .{ .string = guidance });
            try stdout.writeAll("}}\n");
            break :blk 0;
        },
        .opencode => blk: {
            const executable = try setup_io.shellEscapeAlloc(allocator, args[0]);
            defer allocator.free(executable);
            try stdout.writeAll(executable);
            try stdout.writeByte(' ');
            try stdout.writeAll(command);
            try stdout.writeByte('\n');
            break :blk 0;
        },
    };
}

test "opencode executable paths are shell escaped" {
    const allocator = std.testing.allocator;
    const escaped = try setup_io.shellEscapeAlloc(allocator, "/opt/Niel's smll");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("'/opt/Niel'\\''s smll'", escaped);
}

fn eventCommand(value: setup_json.Value) ?[]const u8 {
    if (value != .object) return null;
    const tool_input = value.object.get("tool_input") orelse return null;
    if (tool_input != .object) return null;
    const command = tool_input.object.get("command") orelse return null;
    if (command != .string) return null;
    return command.string;
}

fn isEligible(command: []const u8) bool {
    var token: [256]u8 = undefined;
    var token_len: usize = 0;
    var quote: Quote = .unquoted;
    var started = false;
    var finished = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        if (c == '\n' or c == '\r') return false;
        switch (quote) {
            .single => {
                if (c == '\'') {
                    quote = .unquoted;
                } else if (!finished) {
                    if (token_len == token.len) return false;
                    token[token_len] = c;
                    token_len += 1;
                }
            },
            .double => {
                if (c == '"') {
                    quote = .unquoted;
                } else if (c == '`' or c == '$') {
                    return false;
                } else if (c == '\\') {
                    i += 1;
                    if (i >= command.len or command[i] == '\n' or command[i] == '\r') return false;
                    if (!finished) {
                        if (token_len == token.len) return false;
                        token[token_len] = command[i];
                        token_len += 1;
                    }
                } else if (!finished) {
                    if (token_len == token.len) return false;
                    token[token_len] = c;
                    token_len += 1;
                }
            },
            .unquoted => {
                if (std.ascii.isWhitespace(c)) {
                    if (started) finished = true;
                    continue;
                }
                if (c == ';' or c == '|' or c == '&' or c == '<' or c == '>' or
                    c == '`' or c == '(' or c == ')') return false;
                if (c == '$') return false;
                if (c == '\'') {
                    if (!finished) started = true;
                    quote = .single;
                    continue;
                }
                if (c == '"') {
                    if (!finished) started = true;
                    quote = .double;
                    continue;
                }
                if (c == '\\') {
                    i += 1;
                    if (i >= command.len or command[i] == '\n' or command[i] == '\r') return false;
                    if (!finished) {
                        started = true;
                        if (token_len == token.len) return false;
                        token[token_len] = command[i];
                        token_len += 1;
                    }
                    continue;
                }
                if (!finished) {
                    started = true;
                    if (token_len == token.len) return false;
                    token[token_len] = c;
                    token_len += 1;
                }
            },
        }
    }
    if (quote != .unquoted or token_len == 0) return false;
    const first = token[0..token_len];
    const basename = if (std.mem.findScalarLast(u8, first, '/')) |slash| first[slash + 1 ..] else first;
    return filter_catalog.shouldAutoWrap(basename);
}
