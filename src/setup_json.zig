const std = @import("std");

pub const KV = struct { key: []const u8, val: Value };

pub const Object = struct {
    items: std.ArrayList(KV),

    pub const empty: Object = .{ .items = .empty };

    pub fn get(self: Object, key: []const u8) ?Value {
        for (self.items.items) |kv| if (std.mem.eql(u8, kv.key, key)) return kv.val;
        return null;
    }

    pub fn getPtr(self: *Object, key: []const u8) ?*Value {
        for (self.items.items) |*kv| if (std.mem.eql(u8, kv.key, key)) return &kv.val;
        return null;
    }

    pub fn put(self: *Object, pa: std.mem.Allocator, key: []const u8, val: Value) !void {
        for (self.items.items) |*kv| {
            if (std.mem.eql(u8, kv.key, key)) {
                kv.val = val;
                return;
            }
        }
        try self.items.append(pa, .{ .key = key, .val = val });
    }

    pub fn contains(self: Object, key: []const u8) bool {
        return self.get(key) != null;
    }

    pub fn iterator(self: *const Object) Iterator {
        return .{ .items = self.items.items, .pos = 0 };
    }

    pub const Iterator = struct {
        items: []const KV,
        pos: usize,

        pub fn next(self: *Iterator) ?struct { key_ptr: *const []const u8, value_ptr: *const Value } {
            if (self.pos >= self.items.len) return null;
            const kv = &self.items[self.pos];
            self.pos += 1;
            return .{ .key_ptr = &kv.key, .value_ptr = &kv.val };
        }
    };
};

pub const Array = struct {
    items: []Value = &.{},
    list: std.ArrayList(Value) = .empty,
    pa: std.mem.Allocator = undefined,

    pub fn init(pa: std.mem.Allocator) Array {
        return .{ .pa = pa };
    }

    pub fn append(self: *Array, val: Value) !void {
        try self.list.append(self.pa, val);
        self.items = self.list.items;
    }

    pub fn swapRemove(self: *Array, idx: usize) Value {
        const val = self.list.items[idx];
        _ = self.list.swapRemove(idx);
        self.items = self.list.items;
        return val;
    }
};

pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    string: []const u8,
    array: Array,
    object: Object,
};

pub const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    value: Value,

    pub fn deinit(self: Parsed) void {
        const alloc = self.arena.child_allocator;
        self.arena.deinit();
        alloc.destroy(self.arena);
    }
};

pub fn loadOrCreateObject(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    needs_version: bool,
) !Parsed {
    const input = blk: {
        if (existing) |buf| {
            if (std.mem.trim(u8, buf, " \t\r\n").len == 0) break :blk if (needs_version) "{\"version\":1}" else "{}";
            break :blk buf;
        }
        break :blk if (needs_version) "{\"version\":1}" else "{}";
    };
    return try parseObjectPrefix(allocator, input);
}

/// Minimal JSON serializer for Value. Keeps setup builds small by avoiding
/// std.json.Stringify.
pub fn writeValue(w: *std.Io.Writer, val: Value) !void {
    switch (val) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| {
            var n: u64 = if (i < 0) @intCast(-i) else @intCast(i);
            if (i < 0) try w.writeByte('-');
            var buf: [20]u8 = undefined;
            var pos: usize = buf.len;
            if (n == 0) {
                pos -= 1;
                buf[pos] = '0';
            } else while (n > 0) {
                pos -= 1;
                buf[pos] = @intCast('0' + n % 10);
                n /= 10;
            }
            try w.writeAll(buf[pos..]);
        },
        .string => |s| {
            try w.writeByte('"');
            for (s) |c| switch (c) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => try w.writeByte(c),
            };
            try w.writeByte('"');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try w.writeByte(',');
                try writeValue(w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |kv| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeByte('"');
                try w.writeAll(kv.key_ptr.*);
                try w.writeAll("\":");
                try writeValue(w, kv.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

/// Minimal JSON parser producing Value. Handles objects, arrays, strings,
/// integers, booleans, and null; sufficient for agent settings/hooks JSON.
pub fn parse(child_allocator: std.mem.Allocator, input: []const u8) !Parsed {
    return parseInternal(child_allocator, input, true);
}

fn parseObjectPrefix(child_allocator: std.mem.Allocator, input: []const u8) !Parsed {
    const parsed = try parseInternal(child_allocator, input, false);
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSyntax;
    return parsed;
}

fn parseInternal(child_allocator: std.mem.Allocator, input: []const u8, require_full_input: bool) !Parsed {
    const arena = try child_allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(child_allocator);
    errdefer {
        arena.deinit();
        child_allocator.destroy(arena);
    }
    const pa = arena.allocator();
    var pos: usize = 0;
    const value = try parseValue(pa, input, &pos);
    skipWs(input, &pos);
    if (require_full_input and pos != input.len) return error.InvalidSyntax;
    return .{ .arena = arena, .value = value };
}

fn skipWs(input: []const u8, pos: *usize) void {
    while (pos.* < input.len and (input[pos.*] == ' ' or input[pos.*] == '\t' or input[pos.*] == '\n' or input[pos.*] == '\r')) pos.* += 1;
}

const ParseError = error{ UnexpectedEndOfInput, InvalidSyntax, OutOfMemory };

fn parseValue(pa: std.mem.Allocator, input: []const u8, pos: *usize) ParseError!Value {
    skipWs(input, pos);
    if (pos.* >= input.len) return error.UnexpectedEndOfInput;
    return switch (input[pos.*]) {
        '{' => try parseObject(pa, input, pos),
        '[' => try parseArray(pa, input, pos),
        '"' => .{ .string = try parseString(pa, input, pos) },
        't' => blk: {
            try consumeLiteral(input, pos, "true");
            break :blk .{ .bool = true };
        },
        'f' => blk: {
            try consumeLiteral(input, pos, "false");
            break :blk .{ .bool = false };
        },
        'n' => blk: {
            try consumeLiteral(input, pos, "null");
            break :blk .null;
        },
        '-', '0'...'9' => try parseNumber(input, pos),
        else => error.InvalidSyntax,
    };
}

fn consumeLiteral(input: []const u8, pos: *usize, literal: []const u8) ParseError!void {
    if (pos.* + literal.len > input.len) return error.UnexpectedEndOfInput;
    if (!std.mem.eql(u8, input[pos.* .. pos.* + literal.len], literal)) return error.InvalidSyntax;
    pos.* += literal.len;
}

fn parseObject(pa: std.mem.Allocator, input: []const u8, pos: *usize) ParseError!Value {
    pos.* += 1;
    var obj: Object = .empty;
    skipWs(input, pos);
    if (pos.* < input.len and input[pos.*] == '}') {
        pos.* += 1;
        return .{ .object = obj };
    }
    while (pos.* < input.len) {
        skipWs(input, pos);
        const key = try parseString(pa, input, pos);
        skipWs(input, pos);
        if (pos.* >= input.len) return error.UnexpectedEndOfInput;
        if (input[pos.*] != ':') return error.InvalidSyntax;
        pos.* += 1;
        const val = try parseValue(pa, input, pos);
        try obj.put(pa, key, val);
        skipWs(input, pos);
        if (pos.* < input.len and input[pos.*] == ',') {
            pos.* += 1;
            continue;
        }
        if (pos.* < input.len and input[pos.*] == '}') {
            pos.* += 1;
            return .{ .object = obj };
        }
        return if (pos.* >= input.len) error.UnexpectedEndOfInput else error.InvalidSyntax;
    }
    return error.UnexpectedEndOfInput;
}

fn parseArray(pa: std.mem.Allocator, input: []const u8, pos: *usize) ParseError!Value {
    pos.* += 1;
    var arr = Array.init(pa);
    skipWs(input, pos);
    if (pos.* < input.len and input[pos.*] == ']') {
        pos.* += 1;
        return .{ .array = arr };
    }
    while (pos.* < input.len) {
        const val = try parseValue(pa, input, pos);
        try arr.append(val);
        skipWs(input, pos);
        if (pos.* < input.len and input[pos.*] == ',') {
            pos.* += 1;
            continue;
        }
        if (pos.* < input.len and input[pos.*] == ']') {
            pos.* += 1;
            return .{ .array = arr };
        }
        return if (pos.* >= input.len) error.UnexpectedEndOfInput else error.InvalidSyntax;
    }
    return error.UnexpectedEndOfInput;
}

fn parseString(pa: std.mem.Allocator, input: []const u8, pos: *usize) ParseError![]const u8 {
    if (pos.* >= input.len or input[pos.*] != '"') return error.UnexpectedEndOfInput;
    pos.* += 1;
    const start = pos.*;
    var has_escape = false;
    while (pos.* < input.len and input[pos.*] != '"') {
        if (input[pos.*] == '\\') {
            if (pos.* + 1 >= input.len) return error.UnexpectedEndOfInput;
            has_escape = true;
            pos.* += 2;
        } else pos.* += 1;
    }
    const raw = input[start..pos.*];
    if (pos.* >= input.len) return error.UnexpectedEndOfInput;
    pos.* += 1;
    if (!has_escape) return raw;

    var buf = try pa.alloc(u8, raw.len);
    var i: usize = 0;
    var o: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            buf[o] = switch (raw[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => raw[i],
            };
            o += 1;
            i += 1;
        } else {
            buf[o] = raw[i];
            o += 1;
            i += 1;
        }
    }
    return buf[0..o];
}

fn parseNumber(input: []const u8, pos: *usize) ParseError!Value {
    const start = pos.*;
    if (input[pos.*] == '-') pos.* += 1;
    if (pos.* >= input.len or input[pos.*] < '0' or input[pos.*] > '9') return error.InvalidSyntax;
    while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') pos.* += 1;
    if (pos.* < input.len and (input[pos.*] == '.' or input[pos.*] == 'e' or input[pos.*] == 'E')) return error.InvalidSyntax;
    const num_str = input[start..pos.*];

    var neg = false;
    var idx: usize = 0;
    if (num_str[0] == '-') {
        neg = true;
        idx = 1;
    }
    var val: i64 = 0;
    while (idx < num_str.len and num_str[idx] >= '0' and num_str[idx] <= '9') {
        val = val *| 10 +| (num_str[idx] - '0');
        idx += 1;
    }
    return .{ .integer = if (neg) -val else val };
}

fn expectParseFails(input: []const u8) !void {
    const allocator = std.testing.allocator;
    var parsed = parse(allocator, input) catch return;
    defer parsed.deinit();
    return error.ExpectedParseError;
}

test "parse rejects malformed JSON" {
    try expectParseFails("{");
    try expectParseFails("t");
    try expectParseFails("{\"plugin\" [\"missing colon\"]}");
    try expectParseFails("{\"plugin\":[]} trailing");
}

test "loadOrCreateObject preserves historical trailing-content tolerance" {
    const allocator = std.testing.allocator;
    var parsed = try loadOrCreateObject(allocator, "{\"plugin\":[]} trailing", false);
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.contains("plugin"));
}
