const std = @import("std");
const ansi = @import("ansi");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    return std.mem.find(u8, input, "Terraform will perform") != null or
        std.mem.find(u8, input, "OpenTofu will perform") != null or
        std.mem.find(u8, input, "Plan: ") != null or
        std.mem.find(u8, input, "No changes.") != null or
        std.mem.find(u8, input, "Error: ") != null;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var emitted = try scan(allocator, stdout, writer);
    emitted = try scan(allocator, stderr, writer) or emitted;
    if (!emitted and (stdout.len > 0 or stderr.len > 0)) {
        try writer.writeAll("plan ok\n");
    }
}

fn scan(allocator: Allocator, input: []const u8, writer: *Writer) !bool {
    if (input.len == 0) return false;
    var emitted = false;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;
        if (shouldKeep(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            emitted = true;
        }
    }
    return emitted;
}

fn shouldKeep(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "Plan: ")) return true;
    if (std.mem.startsWith(u8, line, "No changes.")) return true;
    if (std.mem.startsWith(u8, line, "Error: ")) return true;
    if (std.mem.startsWith(u8, line, "Warning: ")) return true;
    if (std.mem.startsWith(u8, line, "Terraform will perform")) return true;
    if (std.mem.startsWith(u8, line, "OpenTofu will perform")) return true;
    if (std.mem.startsWith(u8, line, "# ") and std.mem.indexOf(u8, line, " will be ") != null) return true;
    if (std.mem.startsWith(u8, line, "+ resource ")) return true;
    if (std.mem.startsWith(u8, line, "- resource ")) return true;
    if (std.mem.startsWith(u8, line, "~ resource ")) return true;
    if (std.mem.startsWith(u8, line, "-/+ resource ")) return true;
    return false;
}

test "terraform plan drops refresh chatter and keeps summary" {
    const input =
        "random_pet.name: Refreshing state... [id=calm-raven]\n" ++
        "Terraform will perform the following actions:\n" ++
        "  # aws_s3_bucket.example will be created\n" ++
        "  + resource \"aws_s3_bucket\" \"example\" {\n" ++
        "Plan: 1 to add, 0 to change, 0 to destroy.\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Refreshing state") == null);
    try std.testing.expect(std.mem.find(u8, got, "# aws_s3_bucket.example") != null);
    try std.testing.expect(std.mem.find(u8, got, "Plan: 1 to add") != null);
}
