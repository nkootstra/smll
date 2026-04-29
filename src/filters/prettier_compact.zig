const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    var kept: usize = 0;
    try scan(stdout, writer, &kept);
    try scan(stderr, writer, &kept);
}

fn scan(input: []const u8, writer: *Writer, kept: *usize) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (shouldKeep(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            kept.* += 1;
        }
    }
}

fn shouldKeep(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "[warn]") or
        std.mem.startsWith(u8, line, "[error]") or
        std.mem.startsWith(u8, line, "All matched files use Prettier") or
        std.mem.indexOf(u8, line, "Code style issues found") != null or
        std.mem.indexOf(u8, line, "No files matching") != null;
}

test "all formatted summary preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "Checking formatting...\nAll matched files use Prettier code style!\n", "", &out.writer);
    try std.testing.expectEqualStrings("All matched files use Prettier code style!\n", out.written());
}

test "files needing formatting preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "Checking formatting...\n" ++
        "[warn] src/a.ts\n" ++
        "[warn] src/b.ts\n" ++
        "[warn] Code style issues found in 2 files. Run Prettier to fix.\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings(
        "[warn] src/a.ts\n[warn] src/b.ts\n[warn] Code style issues found in 2 files. Run Prettier to fix.\n",
        out.written(),
    );
}

test "stderr errors preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "[error] No files matching the pattern were found\n", &out.writer);
    try std.testing.expectEqualStrings("[error] No files matching the pattern were found\n", out.written());
}
