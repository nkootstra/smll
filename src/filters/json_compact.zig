const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const max_json_nesting = 256;

pub fn matches(input: []const u8) bool {
    const trimmed = trimBomAndSpace(input);
    if (trimmed.len < 2) return false;
    return isSingleTopLevelContainer(trimmed);
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    if (stdout.len > 0 and matches(stdout)) {
        try minify(stdout, writer);
        return;
    }
    if (stderr.len > 0 and matches(stderr)) {
        try minify(stderr, writer);
        return;
    }
    try writer.writeAll(stdout);
    try writer.writeAll(stderr);
}

fn minify(input: []const u8, writer: *Writer) !void {
    const s = trimBomAndSpace(input);

    var in_string = false;
    var escaped = false;
    for (s) |c| {
        if (in_string) {
            try writer.writeByte(c);
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        if (c == '"') {
            in_string = true;
            try writer.writeByte(c);
        } else if (!std.ascii.isWhitespace(c)) {
            try writer.writeByte(c);
        }
    }

    try writer.writeByte('\n');
}

fn isSingleTopLevelContainer(s: []const u8) bool {
    var expected_closers: [max_json_nesting]u8 = undefined;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;

    for (s, 0..) |c, idx| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }

        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                if (depth == expected_closers.len) return false;
                expected_closers[depth] = if (c == '{') '}' else ']';
                depth += 1;
            },
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
                if (expected_closers[depth] != c) return false;
                if (depth == 0) return idx + 1 == s.len;
            },
            else => if (depth == 0 and !std.ascii.isWhitespace(c)) return false,
        }
    }

    return false;
}

fn trimBomAndSpace(input: []const u8) []const u8 {
    const trimmed_ws = std.mem.trim(u8, input, " \t\r\n");
    return if (std.mem.startsWith(u8, trimmed_ws, "\xef\xbb\xbf")) trimmed_ws[3..] else trimmed_ws;
}

test "minifies object whitespace outside strings" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "{\n  \"a\": \"x y\",\n  \"b\": [1, 2]\n}\n", "", &out.writer);
    try std.testing.expectEqualStrings("{\"a\":\"x y\",\"b\":[1,2]}\n", out.written());
}

test "unterminated strings fall open" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "{\"a\":\"oops}\n", "", &out.writer);
    try std.testing.expectEqualStrings("{\"a\":\"oops}\n", out.written());
}

test "json lines are not concatenated" {
    const input = "{\"a\":1}\n{\"b\":2}\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(!matches(input));
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}

test "single root container may contain nested objects and braces in strings" {
    const input = "{\n  \"a\": [{\"b\": \"}\"}],\n  \"c\": \"{not structural}\"\n}\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(matches(input));
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings("{\"a\":[{\"b\":\"}\"}],\"c\":\"{not structural}\"}\n", out.written());
}
