const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `pre-commit run`. Keeps failed hooks and their
// diagnostic block, collapsing the dot padding on status lines
// (`Check Yaml....Failed` → `Check Yaml Failed`). Drops environment setup
// chatter and passing hooks, but appends a `passed: N hooks` count so the
// agent keeps the overall picture.

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
    // Surface the passed-hook count so the agent keeps the overall picture even
    // though individual passing hooks are dropped.
    if (state.passed_count > 0) {
        try writer.writeAll("passed: ");
        try ansi.writeDecimal(writer, state.passed_count);
        try writer.writeAll(" hooks\n");
    }
}

const ScanState = struct {
    in_failed_hook: bool = false,
    passed_count: usize = 0,
};

const HookStatus = enum { passed, failed, skipped };

fn scan(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), state: *ScanState) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;

        if (hookStatus(line)) |status| {
            state.in_failed_hook = status == .failed;
            if (status == .passed) state.passed_count += 1;
            if (state.in_failed_hook) try appendDepaddedStatus(allocator, out, line, "Failed");
            continue;
        }

        if (state.in_failed_hook and shouldKeepFailureLine(line)) {
            try appendLine(allocator, out, line);
        }
    }
}

/// Emit a hook status line with its dot padding collapsed to a single space:
/// `Check Yaml...........Failed` → `Check Yaml Failed`.
fn appendDepaddedStatus(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8, status: []const u8) !void {
    const status_start = line.len - status.len;
    var dot_start = status_start;
    while (dot_start > 0 and line[dot_start - 1] == '.') : (dot_start -= 1) {}
    const name = std.mem.trimEnd(u8, line[0..dot_start], " \t");
    try out.appendSlice(allocator, name);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, status);
    try out.append(allocator, '\n');
}

fn hookStatus(line: []const u8) ?HookStatus {
    if (lineEndsWithDotPaddedStatus(line, "Passed")) return .passed;
    if (lineEndsWithDotPaddedStatus(line, "Failed")) return .failed;
    if (lineEndsWithDotPaddedStatus(line, "Skipped")) return .skipped;
    return null;
}

fn lineEndsWithDotPaddedStatus(line: []const u8, status: []const u8) bool {
    if (!std.mem.endsWith(u8, line, status)) return false;
    const status_start = line.len - status.len;
    if (status_start == 0) return false;
    var dot_start = status_start;
    while (dot_start > 0 and line[dot_start - 1] == '.') : (dot_start -= 1) {}
    return status_start - dot_start >= 3;
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
    // Dot padding is stripped from the failed status line.
    try std.testing.expect(std.mem.find(u8, got, "Check Yaml Failed") != null);
    try std.testing.expect(std.mem.find(u8, got, "Check Yaml..") == null);
    // Passed hooks are summarized as a count rather than dropped without trace.
    try std.testing.expect(std.mem.find(u8, got, "passed: 1 hooks") != null);
}

test "pre-commit diagnostic containing status word does not end failure block" {
    const input =
        \\Custom Hook............................................................Failed
        \\- hook id: custom-hook
        \\- exit code: 1
        \\checks.py: Pre-condition checks: Passed
        \\checks.py: final validation failed
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Custom Hook") != null);
    try std.testing.expect(std.mem.find(u8, got, "Pre-condition checks: Passed") != null);
    try std.testing.expect(std.mem.find(u8, got, "final validation failed") != null);
}
