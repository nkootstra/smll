const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    const trimmed = trimBomAndSpace(input);
    if (trimmed.len < 2) return false;
    const first = trimmed[0];
    const last = trimmed[trimmed.len - 1];
    return (first == '{' and last == '}') or (first == '[' and last == ']');
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
    if (hasUnterminatedString(s)) {
        try writer.writeAll(input);
        return;
    }

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

fn hasUnterminatedString(s: []const u8) bool {
    var in_string = false;
    var escaped = false;
    for (s) |c| {
        if (!in_string) {
            if (c == '"') in_string = true;
            continue;
        }
        if (escaped) {
            escaped = false;
        } else if (c == '\\') {
            escaped = true;
        } else if (c == '"') {
            in_string = false;
        }
    }
    return in_string;
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
