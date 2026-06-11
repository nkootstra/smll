const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

// Capped sample of reformatted file names (same idiom as pip_compact).
const SampleList = struct {
    total: usize = 0,
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *SampleList, allocator: Allocator) void {
        for (self.items.items) |item| allocator.free(item);
        self.items.deinit(allocator);
    }

    fn add(self: *SampleList, allocator: Allocator, item: []const u8) !void {
        if (item.len == 0) return;
        self.total += 1;
        if (self.items.items.len >= 8) return;
        const copy = try allocator.dupe(u8, item);
        errdefer allocator.free(copy);
        try self.items.append(allocator, copy);
    }
};

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var formatted: SampleList = .{};
    defer formatted.deinit(allocator);
    try scan(allocator, stdout, writer, &strip_buf, &formatted);
    try scan(allocator, stderr, writer, &strip_buf, &formatted);
    // --write emits one `<path> <N>ms` line per file and no [warn] lines, so
    // without this summary the agent would see the no-output hint and lose the
    // fact that files were rewritten.
    if (formatted.total > 0) try writeSample(writer, "formatted", &formatted);
}

fn scan(
    allocator: Allocator,
    input: []const u8,
    writer: *Writer,
    strip_buf: *std.ArrayList(u8),
    formatted: *SampleList,
) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        // Prettier colorizes the `[warn]` tag itself (e.g. `[\x1b[33mwarn\x1b[39m]`),
        // which defeats the startsWith checks; strip ANSI before classifying.
        const clean = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        if (line.len == 0) continue;
        if (parseWriteLine(line)) |w| {
            // Unchanged files are noise; only the rewritten ones are facts.
            if (w.changed) try formatted.add(allocator, w.path);
            continue;
        }
        if (shouldKeep(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
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

const WriteLine = struct { path: []const u8, changed: bool };

// `--write` lines look like `src/a.ts 23ms` (rewritten) or
// `src/a.ts 23ms (unchanged)` (already formatted).
fn parseWriteLine(line: []const u8) ?WriteLine {
    // Diagnostic tags are never write paths, even when the message ends in
    // `<N>ms` — keep them out of the formatted sample so shouldKeep preserves them.
    if (std.mem.startsWith(u8, line, "[warn]") or std.mem.startsWith(u8, line, "[error]")) return null;
    var rest = line;
    var changed = true;
    if (std.mem.endsWith(u8, rest, " (unchanged)")) {
        changed = false;
        rest = rest[0 .. rest.len - " (unchanged)".len];
    }
    if (!std.mem.endsWith(u8, rest, "ms")) return null;
    const before_ms = rest[0 .. rest.len - "ms".len];
    const sp = std.mem.lastIndexOfScalar(u8, before_ms, ' ') orelse return null;
    const num = before_ms[sp + 1 ..];
    if (num.len == 0) return null;
    for (num) |c| if (!std.ascii.isDigit(c)) return null;
    const path = before_ms[0..sp];
    if (path.len == 0) return null;
    return .{ .path = path, .changed = changed };
}

fn writeSample(writer: *Writer, label: []const u8, list: *const SampleList) !void {
    if (list.total == 0) return;
    try writer.writeAll(label);
    try writer.writeByte(' ');
    try ansi.writeDecimal(writer, list.total);
    try writer.writeAll(": ");
    for (list.items.items, 0..) |item, idx| {
        if (idx > 0) try writer.writeAll(", ");
        try writer.writeAll(item);
    }
    if (list.total > list.items.items.len) {
        try writer.writeAll(", ... (+");
        try ansi.writeDecimal(writer, list.total - list.items.items.len);
        try writer.writeByte(')');
    }
    try writer.writeByte('\n');
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

test "warn line ending in ms is kept, not consumed as a write line" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    // A diagnostic that happens to end in `<N>ms` must not be misclassified as
    // a `--write` path line and swallowed into the formatted sample.
    try apply(std.testing.allocator, "[warn] parser timed out after 500ms\n", "", &out.writer);
    try std.testing.expectEqualStrings("[warn] parser timed out after 500ms\n", out.written());
}

const write_fixture = @embedFile("fixture_prettier_write");
const check_color_fixture = @embedFile("fixture_prettier_check_color");

test "write mode emits formatted summary with capped sample" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, write_fixture, "", &out.writer);
    const got = out.written();
    // 10 files reformatted; sample capped at 8 with a (+2) overflow.
    try std.testing.expect(std.mem.find(u8, got, "formatted 10: ") != null);
    try std.testing.expect(std.mem.find(u8, got, "f00.ts") != null);
    try std.testing.expect(std.mem.find(u8, got, "f07.ts") != null);
    try std.testing.expect(std.mem.find(u8, got, "(+2)") != null);
    // The raw `<path> <N>ms` lines must not leak through.
    try std.testing.expect(std.mem.find(u8, got, "26ms") == null);
}

test "write mode does not count unchanged files" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "a.ts 25ms (unchanged)\n" ++
        "b.ts 4ms\n" ++
        "c.ts 1ms (unchanged)\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings("formatted 1: b.ts\n", out.written());
}

test "colored check warn lines are recovered and ansi stripped" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    // The colored `[warn]` tag arrives on stderr.
    try apply(std.testing.allocator, "", check_color_fixture, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "[warn] needsfix.ts") != null);
    try std.testing.expect(std.mem.find(u8, got, "Code style issues found") != null);
    // No escape bytes survive.
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
}
