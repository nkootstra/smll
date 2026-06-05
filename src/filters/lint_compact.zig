const std = @import("std");
const ansi = @import("ansi");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, " problems") != null) return true;
    if (std.mem.find(u8, input, " problem") != null) return true;
    if (std.mem.find(u8, input, "error") != null and std.mem.find(u8, input, "warning") != null) return true;
    if (std.mem.find(u8, input, "lint/") != null) return true;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var state: ScanState = .{};
    defer state.deinit(allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try scan(allocator, stdout, &out, &state);
    try scan(allocator, stderr, &out, &state);
    if (out.items.len == 0 and (stdout.len > 0 or stderr.len > 0)) {
        try writer.writeAll("lint ok\n");
        return;
    }
    try writer.writeAll(out.items);
}

const ScanState = struct {
    pending_file: std.ArrayList(u8) = .empty,
    has_pending_file: bool = false,
    emitted_pending: bool = false,

    fn deinit(self: *ScanState, allocator: Allocator) void {
        self.pending_file.deinit(allocator);
    }
};

fn scan(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), state: *ScanState) !void {
    if (input.len == 0) return;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (looksLikeFileHeader(trimmed)) {
            state.pending_file.clearRetainingCapacity();
            try state.pending_file.appendSlice(allocator, trimmed);
            state.has_pending_file = true;
            state.emitted_pending = false;
            continue;
        }

        if (looksLikeDiagnostic(trimmed)) {
            if (state.has_pending_file and !state.emitted_pending) {
                try appendLine(allocator, out, state.pending_file.items);
                state.emitted_pending = true;
            }
            try appendLine(allocator, out, trimmed);
            continue;
        }

        if (looksLikeSummary(trimmed)) {
            try appendLine(allocator, out, trimmed);
        }
    }
}

fn looksLikeFileHeader(line: []const u8) bool {
    if (line.len == 0 or std.mem.indexOfScalar(u8, line, ' ') != null) return false;
    return std.mem.indexOfScalar(u8, line, '/') != null or
        std.mem.endsWith(u8, line, ".js") or
        std.mem.endsWith(u8, line, ".jsx") or
        std.mem.endsWith(u8, line, ".ts") or
        std.mem.endsWith(u8, line, ".tsx") or
        std.mem.endsWith(u8, line, ".vue") or
        std.mem.endsWith(u8, line, ".svelte");
}

fn looksLikeDiagnostic(line: []const u8) bool {
    if (std.mem.indexOf(u8, line, "error") == null and
        std.mem.indexOf(u8, line, "warning") == null and
        std.mem.indexOf(u8, line, "lint/") == null)
    {
        return false;
    }

    // ESLint stylish: "1:7 error message rule"
    if (lineNumberPrefix(line)) return true;

    // Compact/unix-like forms: "src/app.ts:1:7: error ..."
    const c1 = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    var p = c1 + 1;
    const d1 = p;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    if (p == d1 or p >= line.len or line[p] != ':') return false;
    p += 1;
    const d2 = p;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    return p > d2;
}

fn lineNumberPrefix(line: []const u8) bool {
    var p: usize = 0;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    if (p == 0 or p >= line.len or line[p] != ':') return false;
    p += 1;
    const col_start = p;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    return p > col_start and p < line.len;
}

fn looksLikeSummary(line: []const u8) bool {
    return std.mem.indexOf(u8, line, " problems") != null or
        std.mem.indexOf(u8, line, " problem") != null or
        std.mem.startsWith(u8, line, "Found ") or
        std.mem.startsWith(u8, line, "Checked ") or
        std.mem.startsWith(u8, line, "No lint errors");
}

fn appendLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

test "eslint stylish diagnostics keep file, diagnostics, and summary" {
    const input =
        "ESLint is running\n\n" ++
        "/repo/src/app.ts\n" ++
        "  1:7   error    'unused' is assigned a value but never used  no-unused-vars\n" ++
        "  2:10  warning  Unexpected console statement                no-console\n" ++
        "\n" ++
        "\xe2\x9c\x96 2 problems (1 error, 1 warning)\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "/repo/src/app.ts") != null);
    try std.testing.expect(std.mem.find(u8, got, "no-unused-vars") != null);
    try std.testing.expect(std.mem.find(u8, got, "2 problems") != null);
    try std.testing.expect(std.mem.find(u8, got, "ESLint is running") == null);
}

test "compact path diagnostics are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "src/a.ts:1:7: error no-unused-vars\n", "", &out.writer);
    try std.testing.expectEqualStrings("src/a.ts:1:7: error no-unused-vars\n", out.written());
}
