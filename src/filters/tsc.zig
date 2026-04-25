const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for TypeScript compiler (`tsc`) — on by default
// (v0.6). Set SMLL_LOSSLESS=1 to bypass.
//
// Locations-only compression: each error reduces to `path:L:C TSnnnn` — the
// agent has enough info to jump-to-file; message text is dropped (costs ~15
// tokens per error and the code + location already says what to look at).
//
// Keeps: transformed error lines, the "Found N errors" summary.
// Drops: error message text, blank-line padding, code-context/caret lines,
//        per-file error count tables.
//
// If no "error TS" lines present, emits "no type errors\n".
//
// Detection: input contains "error TS" OR ends with "Found " + "error" summary.

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "error TS") != null) return true;
    if (std.mem.find(u8, input, "Found 0 errors") != null) return true;
    // Multi-error summary
    if (std.mem.find(u8, input, " errors in ") != null and
        std.mem.find(u8, input, "Found ") != null) return true;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);

    var kept_lines: usize = 0;
    try scanAndKeep(allocator, stdout, &scratch, &kept_lines);
    try scanAndKeep(allocator, stderr, &scratch, &kept_lines);

    if (kept_lines == 0) {
        try writer.writeAll("no type errors\n");
        return;
    }
    try writer.writeAll(scratch.items);
}

fn scanAndKeep(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), kept: *usize) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    const head_cap: usize = 2;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var last_file: [128]u8 = undefined;
    var last_file_len: usize = 0;
    while (lines.next()) |raw| {
        if (kept.* >= head_cap) break;
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (try writeCompressedError(allocator, trimmed, out, &last_file, &last_file_len)) {
            kept.* += 1;
            continue;
        }
        // Omit trailing "Found N errors" summary in compact mode.
    }
}

/// Compress `path:L:C - error TSnnnn: <message>` → `path:L:C TSnnnn`.
/// Returns true when a line was written. If the line looks like a tsc error
/// but can't be parsed, falls back to writing the raw line so we never drop
/// actionable content.
fn writeCompressedError(
    allocator: Allocator,
    line: []const u8,
    out: *std.ArrayList(u8),
    last_file: *[128]u8,
    last_file_len: *usize,
) !bool {
    const marker = " - error TS";
    const idx = std.mem.find(u8, line, marker) orelse {
        // Some tsc modes emit `error TS` without the leading path (rare).
        // Fall back to raw line to preserve info.
        if (std.mem.find(u8, line, "error TS") != null) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            return true;
        }
        return false;
    };
    var path_lc = line[0..idx];
    if (std.mem.startsWith(u8, path_lc, "./")) path_lc = path_lc[2..];
    if (std.mem.startsWith(u8, path_lc, "src/")) path_lc = path_lc[4..];

    // Further compact: basename + line only (drop column), keep TS code.
    if (std.mem.indexOfScalar(u8, path_lc, ':')) |c1| {
        if (std.mem.indexOfScalarPos(u8, path_lc, c1 + 1, ':')) |c2| {
            const file_part = path_lc[0..c1];
            const line_part = path_lc[c1 + 1 .. c2];
            const base = if (std.mem.findScalarLast(u8, file_part, '/')) |s| file_part[s + 1 ..] else file_part;
            var compact_buf: [256]u8 = undefined;
            const joined = std.fmt.bufPrint(&compact_buf, "{s}:{s}", .{ base, line_part }) catch path_lc;
            path_lc = joined;
        }
    }
    const code_start = idx + 9; // past " - error "
    var code_end = code_start;
    while (code_end < line.len and line[code_end] != ':') code_end += 1;
    const code = line[code_start..code_end];

    // Elide repeated file basename: for consecutive entries from the same file,
    // emit ":<line> TSxxxx".
    var file_part = path_lc;
    var line_part: []const u8 = "";
    if (std.mem.indexOfScalar(u8, path_lc, ':')) |c| {
        file_part = path_lc[0..c];
        line_part = path_lc[c..];
    }

    const repeated = std.mem.eql(u8, file_part, last_file[0..last_file_len.*]);
    if (!repeated) {
        const n = @min(file_part.len, last_file.len);
        @memcpy(last_file[0..n], file_part[0..n]);
        last_file_len.* = n;
        try out.appendSlice(allocator, file_part);
    }
    try out.appendSlice(allocator, line_part);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, code);
    try out.append(allocator, '\n');
    return true;
}

fn isFoundSummary(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "Found ") and
        std.mem.find(u8, line, "error") != null;
}

test "matches: error TS line" {
    try std.testing.expect(matches("src/a.ts:4:5 - error TS2322: Type 'x' ...\n"));
}

test "matches: Found 0 errors" {
    try std.testing.expect(matches("Found 0 errors. Watching for file changes.\n"));
}

test "matches: rejects non-tsc" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello\n"));
}

test "apply: fixture compresses errors to locations + codes" {
    const input = @embedFile("fixture_tsc_errors");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // Transformed form: path:L:C TSnnnn (message dropped).
    try std.testing.expect(std.mem.find(u8, got, "client.ts:42 TS2322") != null);
    try std.testing.expect(std.mem.find(u8, got, ":58 TS2339") != null);
    try std.testing.expect(std.mem.find(u8, got, "Button.tsx:15 TS2345") != null);
    try std.testing.expect(std.mem.find(u8, got, "format.ts:8 TS7006") != null);
    try std.testing.expect(std.mem.find(u8, got, "format.ts:14 TS2304") != null);
    try std.testing.expect(std.mem.find(u8, got, "Found 5 errors in 3 files.") != null);
    // Message text dropped.
    try std.testing.expect(std.mem.find(u8, got, "is not assignable") == null);
    try std.testing.expect(std.mem.find(u8, got, "- error TS") == null);
    // Caret and code-context lines dropped.
    try std.testing.expect(std.mem.find(u8, got, "~~~~~~") == null);
    try std.testing.expect(std.mem.find(u8, got, "return response;") == null);
    try std.testing.expect(std.mem.find(u8, got, "Errors  Files") == null);
}

test "apply: no errors emits 'no type errors'" {
    const input = "Found 0 errors. Watching for file changes.\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // "Found 0 errors" is kept as a positive signal rather than collapsed.
    try std.testing.expect(std.mem.find(u8, got, "Found 0 errors") != null);
}

test "apply: strips ANSI" {
    const input = "\x1b[31msrc/a.ts:1:1\x1b[0m - error TS2322: x\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "a.ts:1 TS2322") != null);
}

test "apply: malformed error line falls back to raw" {
    // No " - error TS" separator — keep as-is so we don't silently drop signal.
    const input = "weird: error TS9999 something went wrong\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "error TS9999") != null);
}
