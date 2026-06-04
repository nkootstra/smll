const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for Maven output. Keeps warnings/errors and build
// result lines, while dropping download/progress scaffolding.

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "[ERROR]") != null) return true;
    if (std.mem.find(u8, input, "[WARNING]") != null) return true;
    if (std.mem.find(u8, input, "BUILD FAILURE") != null) return true;
    if (std.mem.find(u8, input, "BUILD SUCCESS") != null) return true;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var state: ScanState = .{};
    try scan(allocator, stdout, &out, &state);
    try scan(allocator, stderr, &out, &state);
    if (out.items.len == 0) {
        try writer.writeAll("maven ok\n");
        return;
    }
    try writer.writeAll(out.items);
}

const ScanState = struct {
    error_context: usize = 0,
};

fn scan(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), state: *ScanState) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) {
            state.error_context = 0;
            continue;
        }

        if (shouldKeep(line)) {
            try appendLine(allocator, out, line);
            state.error_context = if (std.mem.startsWith(u8, line, "[ERROR]")) 4 else 0;
            continue;
        }

        if (state.error_context > 0 and isErrorContinuation(line)) {
            try appendLine(allocator, out, line);
            state.error_context -= 1;
            continue;
        }
    }
}

fn shouldKeep(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "[ERROR]")) return true;
    if (std.mem.startsWith(u8, line, "[WARNING]")) return true;
    if (std.mem.eql(u8, line, "[INFO] BUILD FAILURE") or
        std.mem.eql(u8, line, "[INFO] BUILD SUCCESS"))
    {
        return true;
    }
    if (std.mem.startsWith(u8, line, "[INFO] Total time:")) return true;
    return false;
}

fn isErrorContinuation(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "[")) return false;
    if (std.mem.startsWith(u8, line, "symbol:")) return true;
    if (std.mem.startsWith(u8, line, "location:")) return true;
    if (std.mem.startsWith(u8, line, "required:")) return true;
    if (std.mem.startsWith(u8, line, "found:")) return true;
    if (std.mem.startsWith(u8, line, "reason:")) return true;
    if (std.mem.find(u8, line, "cannot find symbol") != null) return true;
    return false;
}

fn appendLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

test "maven failure keeps error and summary" {
    const input =
        \\[INFO] Building myapp 1.0-SNAPSHOT
        \\[INFO] Downloading org.apache.maven.plugins:maven-compiler-plugin:3.11.0
        \\[INFO] Downloaded org.apache.maven.plugins:maven-compiler-plugin:3.11.0
        \\[ERROR] /src/main/java/Main.java:[10,5] cannot find symbol
        \\  symbol: method foo()
        \\[INFO] BUILD FAILURE
        \\[INFO] Total time: 2.543 s
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "cannot find symbol") != null);
    try std.testing.expect(std.mem.find(u8, got, "symbol: method foo") != null);
    try std.testing.expect(std.mem.find(u8, got, "BUILD FAILURE") != null);
    try std.testing.expect(std.mem.find(u8, got, "Downloading") == null);
}
