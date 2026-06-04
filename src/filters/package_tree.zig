const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for package dependency trees such as `bun pm ls`.
// Keeps the root context, direct dependency names/versions, and a transitive
// count. Drops the full nested dependency tree by default.

pub fn matches(input: []const u8) bool {
    return std.mem.find(u8, input, " node_modules") != null and
        (std.mem.find(u8, input, "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ") != null or
            std.mem.find(u8, input, "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 ") != null or
            std.mem.find(u8, input, "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\xac ") != null or
            std.mem.find(u8, input, "\xe2\x94\x94\xe2\x94\x80\xe2\x94\xac ") != null);
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    var deps: NameList = .{};
    defer deps.deinit(allocator);

    var root: ?[]u8 = null;
    defer if (root) |r| allocator.free(r);
    var nested_rows: usize = 0;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;
        if (root == null and !startsWithTreePrefix(line)) {
            root = try allocator.dupe(u8, line);
            continue;
        }
        if (directPackage(line)) |pkg| {
            try deps.add(allocator, pkg);
        } else if (containsTreePackageMarker(line)) {
            nested_rows += 1;
        }
    }

    if (root) |r| {
        try writer.writeAll(r);
        try writer.writeByte('\n');
    }
    if (deps.count > 0) {
        try deps.write(writer, "deps");
    }
    if (nested_rows > 0) {
        try writer.writeAll("nested rows x");
        try writeDecimal(writer, nested_rows);
        try writer.writeByte('\n');
    }
    if (stderr.len > 0) try writer.writeAll(stderr);
}

const NameList = struct {
    count: usize = 0,
    items: std.ArrayList(u8) = .empty,

    fn deinit(self: *NameList, allocator: Allocator) void {
        self.items.deinit(allocator);
    }

    fn add(self: *NameList, allocator: Allocator, name: []const u8) !void {
        self.count += 1;
        if (self.count > 12) return;
        if (self.items.items.len > 0) try self.items.appendSlice(allocator, ", ");
        try self.items.appendSlice(allocator, name);
    }

    fn write(self: *const NameList, writer: *Writer, label: []const u8) !void {
        try writer.writeAll(label);
        try writer.writeAll(" +");
        try writeDecimal(writer, self.count);
        if (self.items.items.len > 0) {
            try writer.writeAll(": ");
            try writer.writeAll(self.items.items);
            if (self.count > 12) try writer.writeAll(", ...");
        }
        try writer.writeByte('\n');
    }
};

fn directPackage(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{
        "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ",
        "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 ",
        "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\xac ",
        "\xe2\x94\x94\xe2\x94\x80\xe2\x94\xac ",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return std.mem.trim(u8, line[prefix.len..], " \t\r");
        }
    }
    return null;
}

fn startsWithTreePrefix(line: []const u8) bool {
    return line.len >= 3 and line[0] == 0xe2 and line[1] == 0x94;
}

fn containsTreePackageMarker(line: []const u8) bool {
    return std.mem.find(u8, line, "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ") != null or
        std.mem.find(u8, line, "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 ") != null or
        std.mem.find(u8, line, "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\xac ") != null or
        std.mem.find(u8, line, "\xe2\x94\x94\xe2\x94\x80\xe2\x94\xac ") != null;
}

fn writeDecimal(writer: *Writer, value: usize) !void {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{value});
    try writer.writeAll(s);
}

test "package tree keeps direct deps and transitive count" {
    const input =
        \\example-app@1.0.0 /repo node_modules (5)
        \\├── react@18.3.1
        \\├─┬ react-dom@18.3.1
        \\│ ├── react@18.3.1
        \\│ └── scheduler@0.23.2
        \\└── zod@3.23.8
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "example-app@1.0.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "deps +3: react@18.3.1, react-dom@18.3.1, zod@3.23.8") != null);
    try std.testing.expect(std.mem.find(u8, got, "nested rows x2") != null);
    try std.testing.expect(std.mem.find(u8, got, "scheduler@0.23.2") == null);
}
