const std = @import("std");
const util = @import("util");

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
    number: []const u8,
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
        .number => |number| try w.writeAll(number),
        .string => |s| try writeString(w, s),
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
                try writeString(w, kv.key_ptr.*);
                try w.writeByte(':');
                try writeValue(w, kv.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

pub const writeString = util.writeJsonStringUtf8;
pub const writeStringContent = util.writeJsonStringContentUtf8;

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
        } else {
            if (input[pos.*] < 0x20) return error.InvalidSyntax;
            pos.* += 1;
        }
    }
    const raw = input[start..pos.*];
    if (pos.* >= input.len) return error.UnexpectedEndOfInput;
    pos.* += 1;
    if (!has_escape) return raw;

    var buf = try pa.alloc(u8, raw.len);
    var i: usize = 0;
    var o: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '\\') {
            buf[o] = raw[i];
            o += 1;
            i += 1;
            continue;
        }

        i += 1;
        if (i >= raw.len) return error.UnexpectedEndOfInput;
        switch (raw[i]) {
            '"', '\\', '/' => {
                buf[o] = raw[i];
                o += 1;
                i += 1;
            },
            'b', 'f', 'n', 'r', 't' => {
                buf[o] = switch (raw[i]) {
                    'b' => 0x08,
                    'f' => 0x0c,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => unreachable,
                };
                o += 1;
                i += 1;
            },
            'u' => {
                if (i + 5 > raw.len) return error.UnexpectedEndOfInput;
                var codepoint: u21 = try parseHexCodeUnit(raw[i + 1 .. i + 5]);
                i += 5;

                if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
                    if (i + 6 > raw.len or raw[i] != '\\' or raw[i + 1] != 'u') return error.InvalidSyntax;
                    const low = try parseHexCodeUnit(raw[i + 2 .. i + 6]);
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidSyntax;
                    codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00);
                    i += 6;
                } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) {
                    return error.InvalidSyntax;
                }

                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(codepoint, &encoded) catch return error.InvalidSyntax;
                @memcpy(buf[o .. o + encoded_len], encoded[0..encoded_len]);
                o += encoded_len;
            },
            else => return error.InvalidSyntax,
        }
    }
    return buf[0..o];
}

fn parseHexCodeUnit(hex: []const u8) ParseError!u16 {
    if (hex.len != 4) return error.InvalidSyntax;
    var bytes: [2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidSyntax;
    return std.mem.readInt(u16, &bytes, .big);
}

fn parseNumber(input: []const u8, pos: *usize) ParseError!Value {
    const start = pos.*;
    if (input[pos.*] == '-') pos.* += 1;
    if (pos.* >= input.len or input[pos.*] < '0' or input[pos.*] > '9') return error.InvalidSyntax;
    if (input[pos.*] == '0') {
        pos.* += 1;
        if (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') return error.InvalidSyntax;
    } else {
        while (pos.* < input.len and input[pos.*] >= '0' and input[pos.*] <= '9') pos.* += 1;
    }
    if (pos.* < input.len and (input[pos.*] == '.' or input[pos.*] == 'e' or input[pos.*] == 'E')) return error.InvalidSyntax;
    return .{ .number = input[start..pos.*] };
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
    try expectParseFails("{\"value\":\"invalid \\q escape\"}");
    try expectParseFails("{\"value\":\"line\nbreak\"}");
    try expectParseFails("{\"value\":\"\\uD800\"}");
    try expectParseFails("{\"value\":\"\\uDC00\"}");
    try expectParseFails("{\"value\":\"\\uD800\\u0041\"}");
    try expectParseFails("{\"value\":\"\\uGGGG\"}");
    try expectParseFails("{\"value\":01}");
}

test "loadOrCreateObject preserves historical trailing-content tolerance" {
    const allocator = std.testing.allocator;
    var parsed = try loadOrCreateObject(allocator, "{\"plugin\":[]} trailing", false);
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.contains("plugin"));
}

test "setup JSON preserves UTF-8 string bytes" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try writeString(&output.writer, "caf\xc3\xa9 \xe2\x98\x83");
    try std.testing.expectEqualStrings("\"caf\xc3\xa9 \xe2\x98\x83\"", output.written());
}

test "setup JSON round trip decodes every string escape" {
    const allocator = std.testing.allocator;
    var parsed = try parse(
        allocator,
        "{\"value\":\"quote:\\\" slash:\\\\ solidus:\\/ backspace:\\b formfeed:\\f snowman:\\u2603 emoji:\\uD83D\\uDE03\"}",
    );
    defer parsed.deinit();

    const value = parsed.value.object.get("value") orelse return error.MissingValue;
    try std.testing.expectEqualStrings(
        "quote:\" slash:\\ solidus:/ backspace:\x08 formfeed:\x0c snowman:\xe2\x98\x83 emoji:\xf0\x9f\x98\x83",
        value.string,
    );

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try writeValue(&output.writer, parsed.value);
    try std.testing.expectEqualStrings(
        "{\"value\":\"quote:\\\" slash:\\\\ solidus:/ backspace:\\u0008 formfeed:\\u000c snowman:\xe2\x98\x83 emoji:\xf0\x9f\x98\x83\"}",
        output.written(),
    );
}

test "setup JSON round trip escapes object keys" {
    const allocator = std.testing.allocator;
    var parsed = try parse(allocator, "{\"quote\\\" slash\\\\ snowman\\u2603\":true}");
    defer parsed.deinit();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try writeValue(&output.writer, parsed.value);
    try std.testing.expectEqualStrings(
        "{\"quote\\\" slash\\\\ snowman\xe2\x98\x83\":true}",
        output.written(),
    );
}

test "setup JSON round trip preserves integers outside i64" {
    const allocator = std.testing.allocator;
    const input = "{\"large\":9223372036854775808,\"negative\":-9223372036854775809}";
    var parsed = try parse(allocator, input);
    defer parsed.deinit();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try writeValue(&output.writer, parsed.value);
    try std.testing.expectEqualStrings(input, output.written());
}
