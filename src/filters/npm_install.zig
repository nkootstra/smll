const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `npm install` / `npm ci` — on by default
// (v0.6). Set SMLL_LOSSLESS=1 to bypass.
//
// Keeps: WARN/ERR!/error/deprecated lines, the install summary (added/removed/
//        changed/up to date/audited), vulnerabilities lines.
// Drops: "npm notice" upgrade prompts, "packages are looking for funding",
//        "run `...`" instruction lines, blank padding.
//
// If no keep lines captured, emits "up to date\n".
//
// Detection: "added " + "packages" OR "up to date" OR "audited " OR "npm error"
//            OR "npm WARN".

const KEEP_PREFIXES = [_][]const u8{
    "npm WARN",
    "npm ERR!",
    "npm error",
    "npm err!",
    "added ",
    "removed ",
    "changed ",
    "up to date",
    "up-to-date",
    "audited ",
    "found 0 vulnerabilities",
    "found ",
};

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "added ") != null and
        std.mem.find(u8, input, "packages") != null) return true;
    // "up to date" must appear on the same line as "audited" or "packages"
    // to avoid false positives on generic text containing both words across lines.
    if (std.mem.find(u8, input, "up to date") != null) {
        var it = std.mem.splitScalar(u8, input, '\n');
        while (it.next()) |line| {
            if (std.mem.find(u8, line, "up to date") != null and
                (std.mem.find(u8, line, "audited") != null or
                std.mem.find(u8, line, "packages") != null)) return true;
        }
    }
    if (std.mem.find(u8, input, "audited ") != null and
        std.mem.find(u8, input, "packages") != null) return true;
    if (std.mem.find(u8, input, "npm error") != null) return true;
    if (std.mem.find(u8, input, "npm ERR!") != null) return true;
    if (std.mem.find(u8, input, "npm WARN") != null) return true;
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
        try writer.writeAll("up to date\n");
        return;
    }
    try writer.writeAll(scratch.items);
}

fn scanAndKeep(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), kept: *usize) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    const head_cap: usize = 60;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    while (lines.next()) |raw| {
        if (kept.* >= head_cap) break;
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!shouldKeep(trimmed)) continue;
        try writeLine(allocator, trimmed, out);
        kept.* += 1;
    }
}

fn writeLine(allocator: Allocator, line: []const u8, out: *std.ArrayList(u8)) !void {
    // Keep original kept lines verbatim (after ANSI stripping in caller).
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn numberAfter(line: []const u8, marker: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, line, marker) orelse return null;
    var j = i + marker.len;
    const start = j;
    while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
    if (j == start) return null;
    return line[start..j];
}

fn firstToken(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r");
    var i: usize = 0;
    while (i < t.len and t[i] != ' ' and t[i] != '\t') : (i += 1) {}
    return t[0..i];
}

fn shouldKeep(line: []const u8) bool {
    // Explicit drops take priority.
    if (std.mem.startsWith(u8, line, "npm notice")) return false;
    if (std.mem.find(u8, line, "packages are looking for funding") != null) return false;
    if (std.mem.startsWith(u8, line, "run `npm ")) return false;
    for (KEEP_PREFIXES) |p| {
        if (std.mem.startsWith(u8, line, p)) return true;
    }
    return false;
}

test "matches: added packages" {
    try std.testing.expect(matches("added 42 packages in 3s\n"));
}

test "matches: up to date" {
    try std.testing.expect(matches("up to date, audited 42 packages in 1s\n"));
}

test "matches: npm WARN alone" {
    try std.testing.expect(matches("npm WARN deprecated foo@1.0.0\n"));
}

test "matches: rejects non-npm" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello\n"));
}

test "apply: fixture keeps WARN + summary, drops notice + funding noise" {
    const input = @embedFile("fixture_npm_install");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    try std.testing.expect(std.mem.find(u8, got, "npm WARN deprecated lodash.isequal@4.5.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "added 847 packages") != null);
    try std.testing.expect(std.mem.find(u8, got, "found 2 vulnerabilities") != null);
    // Dropped noise.
    try std.testing.expect(std.mem.find(u8, got, "npm notice") == null);
    try std.testing.expect(std.mem.find(u8, got, "packages are looking for funding") == null);
    try std.testing.expect(std.mem.find(u8, got, "run `npm fund`") == null);
}

test "apply: silent run emits 'up to date'" {
    const input = "\n\n\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("up to date\n", out.written());
}

test "apply: strips ANSI" {
    const input = "\x1b[32madded 5 packages\x1b[0m in 1s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "added 5 packages") != null);
}
