const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `pre-commit run`. Keeps failed hooks and their
// diagnostic block. Drops environment setup chatter and passed hooks.

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "- hook id:") != null) return true;
    if (std.mem.find(u8, input, "Failed") != null) return true;
    if (std.mem.find(u8, input, "Passed") != null) return true;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var state: ScanState = .{};
    try scan(allocator, stdout, &out, &state);
    try scan(allocator, stderr, &out, &state);
    if (out.items.len == 0) {
        try writer.writeAll("all hooks passed\n");
        return;
    }
    try writer.writeAll(out.items);
}

const ScanState = struct {
    in_failed_hook: bool = false,
};

fn scan(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), state: *ScanState) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;

        if (isHookStatus(line)) {
            state.in_failed_hook = std.mem.find(u8, line, "Failed") != null;
            if (state.in_failed_hook) try appendLine(allocator, out, line);
            continue;
        }

        if (state.in_failed_hook and shouldKeepFailureLine(line)) {
            try appendLine(allocator, out, line);
        }
    }
}

fn isHookStatus(line: []const u8) bool {
    return std.mem.find(u8, line, "Passed") != null or
        std.mem.find(u8, line, "Failed") != null or
        std.mem.find(u8, line, "Skipped") != null;
}

fn shouldKeepFailureLine(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "- hook id:")) return true;
    if (std.mem.startsWith(u8, line, "- exit code:")) return true;
    if (std.ascii.indexOfIgnoreCase(line, "error") != null) return true;
    if (std.ascii.indexOfIgnoreCase(line, "failed") != null) return true;
    if (std.mem.indexOf(u8, line, ":") != null and
        (std.mem.indexOf(u8, line, ".py") != null or
            std.mem.indexOf(u8, line, ".yaml") != null or
            std.mem.indexOf(u8, line, ".yml") != null or
            std.mem.indexOf(u8, line, ".toml") != null or
            std.mem.indexOf(u8, line, ".json") != null))
    {
        return true;
    }
    return false;
}

fn appendLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

test "pre-commit failure keeps failed hook only" {
    const input =
        \\[INFO] Installing environment for https://github.com/psf/black.
        \\Trim Trailing Whitespace.................................................Passed
        \\Check Yaml...............................................................Failed
        \\- hook id: check-yaml
        \\- exit code: 1
        \\bad.yaml: could not determine a constructor
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Check Yaml") != null);
    try std.testing.expect(std.mem.find(u8, got, "hook id: check-yaml") != null);
    try std.testing.expect(std.mem.find(u8, got, "bad.yaml") != null);
    try std.testing.expect(std.mem.find(u8, got, "Installing environment") == null);
    try std.testing.expect(std.mem.find(u8, got, "Trim Trailing") == null);
}
