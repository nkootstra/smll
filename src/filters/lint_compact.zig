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
    try scan(allocator, stdout, writer, &state);
    try scan(allocator, stderr, writer, &state);
    if (!state.emitted_any and (stdout.len > 0 or stderr.len > 0)) {
        try writer.writeAll("lint ok\n");
    }
}

const ScanState = struct {
    pending_file: [1024]u8 = [_]u8{0} ** 1024,
    pending_file_len: usize = 0,
    has_pending_file: bool = false,
    emitted_pending: bool = false,
    emitted_any: bool = false,

    fn pendingFile(self: *const ScanState) []const u8 {
        return self.pending_file[0..self.pending_file_len];
    }
};

fn scan(allocator: Allocator, input: []const u8, writer: *Writer, state: *ScanState) !void {
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
            state.pending_file_len = @min(trimmed.len, state.pending_file.len);
            @memcpy(state.pending_file[0..state.pending_file_len], trimmed[0..state.pending_file_len]);
            state.has_pending_file = true;
            state.emitted_pending = false;
            continue;
        }

        if (looksLikeDiagnostic(trimmed)) {
            if (state.has_pending_file and !state.emitted_pending) {
                try appendLine(writer, state.pendingFile());
                state.emitted_pending = true;
            }
            // B11: ESLint's "stylish" formatter pads columns with runs of
            // spaces for terminal alignment; collapse them to single spaces.
            try appendCollapsed(writer, trimmed);
            state.emitted_any = true;
            continue;
        }

        if (looksLikeSummary(trimmed)) {
            try appendLine(writer, trimmed);
            state.emitted_any = true;
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

fn appendLine(writer: *Writer, line: []const u8) !void {
    try writer.writeAll(line);
    try writer.writeByte('\n');
}

/// Write `line` collapsing every run of two-or-more spaces to a single space,
/// then a trailing newline. Used for ESLint stylish diagnostics whose column
/// alignment padding carries no information.
fn appendCollapsed(writer: *Writer, line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        try writer.writeByte(c);
        if (c == ' ') {
            while (i < line.len and line[i] == ' ') i += 1;
        } else {
            i += 1;
        }
    }
    try writer.writeByte('\n');
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

test "eslint stylish padding collapses to single spaces" {
    const input =
        "/repo/src/app.ts\n" ++
        "  1:7   error    'unused' is assigned a value but never used  no-unused-vars\n" ++
        "\xe2\x9c\x96 1 problem (1 error, 0 warnings)\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    // B11: alignment padding inside the diagnostic is collapsed.
    try std.testing.expect(std.mem.find(u8, got, "1:7 error 'unused' is assigned a value but never used no-unused-vars") != null);
    // No multi-space run survives anywhere in the output.
    try std.testing.expect(std.mem.find(u8, got, "  ") == null);
}

test "compact path diagnostics are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "src/a.ts:1:7: error no-unused-vars\n", "", &out.writer);
    try std.testing.expectEqualStrings("src/a.ts:1:7: error no-unused-vars\n", out.written());
}
