const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

// LOSSLESS-ish compaction for `ruff check`: groups diagnostics by file so the
// path prints once as a header instead of repeating on every line.
//
//   src/app.py
//     1:8 F401 `os` imported but unused
//     9:1 E501 line too long
//
// All facts (path, line, col, code, message) are preserved — only the repeated
// `path:` prefix and the `: ` after the column are dropped. Summary lines
// ("Found N errors.", "All checks passed!", reformat counts) pass through and
// reset the active file header.

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    // Stable copy of the file path whose header was last emitted; compared
    // against the next diagnostic's path to decide whether to repeat it.
    var cur_path: std.ArrayList(u8) = .empty;
    defer cur_path.deinit(allocator);
    try scan(allocator, stdout, writer, &strip_buf, &cur_path);
    try scan(allocator, stderr, writer, &strip_buf, &cur_path);
}

fn scan(allocator: Allocator, input: []const u8, writer: *Writer, strip_buf: *std.ArrayList(u8), cur_path: *std.ArrayList(u8)) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const clean = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        if (parseDiagnostic(line)) |d| {
            if (!std.mem.eql(u8, d.path, cur_path.items)) {
                try writer.writeAll(d.path);
                try writer.writeByte('\n');
                cur_path.clearRetainingCapacity();
                try cur_path.appendSlice(allocator, d.path);
            }
            try writer.writeAll("  ");
            try writer.writeAll(d.loc);
            try writer.writeByte(' ');
            try writer.writeAll(d.body);
            try writer.writeByte('\n');
        } else if (isSummary(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            cur_path.clearRetainingCapacity();
        }
    }
}

fn isSummary(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "All checks passed")) return true;
    // Summary counts, e.g. "Found 3 errors." / "Found 1 error." (mirrors mypy).
    if (std.mem.startsWith(u8, line, "Found ")) return true;
    if (std.mem.endsWith(u8, line, "would be reformatted") or std.mem.endsWith(u8, line, "left unchanged")) return true;
    if (std.mem.indexOf(u8, line, " files would be reformatted") != null) return true;
    if (std.mem.indexOf(u8, line, " files left unchanged") != null) return true;
    return false;
}

const Diagnostic = struct {
    path: []const u8, // "src/app.py"
    loc: []const u8, // "line:col"
    body: []const u8, // "CODE message"
};

/// Parse ruff's `path:line:col: CODE message` text form. Returns null when the
/// line doesn't match (path may not contain ':' before the line:col digits).
fn parseDiagnostic(line: []const u8) ?Diagnostic {
    const c1 = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var p = c1 + 1;
    const d1 = p;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    if (p == d1 or p >= line.len or line[p] != ':') return null;
    p += 1;
    const d2 = p;
    while (p < line.len and std.ascii.isDigit(line[p])) p += 1;
    if (p == d2 or p >= line.len or line[p] != ':') return null;
    const c3 = p; // third colon, right after the column digits
    return .{
        .path = line[0..c1],
        .loc = line[c1 + 1 .. c3],
        .body = std.mem.trimStart(u8, line[c3 + 1 ..], " \t"),
    };
}

test "ruff check diagnostics and Found summary are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input = "src/a.py:1:8: F401 `os` imported but unused\nFound 1 error.\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    // Path printed once as a header; violation indented as `L:C CODE msg`.
    try std.testing.expectEqualStrings("src/a.py\n  1:8 F401 `os` imported but unused\nFound 1 error.\n", out.written());
}

test "ruff groups multiple violations under each file path" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "src/app.py:1:8: F401 `os` imported but unused\n" ++
        "src/app.py:9:1: E501 line too long\n" ++
        "src/util.py:3:5: F841 local variable assigned but never used\n" ++
        "Found 3 errors.\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings(
        "src/app.py\n" ++
            "  1:8 F401 `os` imported but unused\n" ++
            "  9:1 E501 line too long\n" ++
            "src/util.py\n" ++
            "  3:5 F841 local variable assigned but never used\n" ++
            "Found 3 errors.\n",
        out.written(),
    );
}

test "ruff no issues summary is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "All checks passed!\n", "", &out.writer);
    try std.testing.expectEqualStrings("All checks passed!\n", out.written());
}

test "ruff format summary is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "1 file would be reformatted, 2 files left unchanged\n", "", &out.writer);
    try std.testing.expectEqualStrings("1 file would be reformatted, 2 files left unchanged\n", out.written());
}

test "ruff stderr diagnostics are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "src/a.py:2:1: E402 module level import not at top of file\n", &out.writer);
    try std.testing.expectEqualStrings("src/a.py\n  2:1 E402 module level import not at top of file\n", out.written());
}

test "ansi is stripped" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "\x1b[31msrc/a.py:1:8: F401 bad\x1b[0m\n", "", &out.writer);
    try std.testing.expectEqualStrings("src/a.py\n  1:8 F401 bad\n", out.written());
}
