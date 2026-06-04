const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    return looksLikeInstall(input);
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (looksLikeInstall(stdout) or looksLikeInstall(stderr)) {
        try applyInstall(allocator, stdout, stderr, writer);
        return;
    }

    if (stdout.len == 0) {
        try writer.writeAll(stderr);
        return;
    }

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or isSeparator(line) or isHeader(line)) continue;
        try writeCollapsed(line, writer);
        try writer.writeByte('\n');
    }
    try writer.writeAll(stderr);
}

const SampleList = struct {
    total: usize = 0,
    items: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *SampleList, allocator: Allocator) void {
        self.items.deinit(allocator);
    }

    fn add(self: *SampleList, allocator: Allocator, item: []const u8) !void {
        if (item.len == 0) return;
        self.total += 1;
        if (self.items.items.len < 8) {
            try self.items.append(allocator, item);
        }
    }

    fn addCountedSample(self: *SampleList, allocator: Allocator, item: []const u8) !void {
        if (item.len == 0) return;
        self.total += 1;
        if (self.items.items.len >= 8) return;
        for (self.items.items) |existing| {
            if (std.mem.eql(u8, existing, item)) return;
        }
        try self.items.append(allocator, item);
    }
};

fn looksLikeInstall(input: []const u8) bool {
    return std.mem.find(u8, input, "Collecting ") != null or
        std.mem.find(u8, input, "Downloading ") != null or
        std.mem.find(u8, input, "Installing collected packages:") != null or
        std.mem.find(u8, input, "Successfully installed ") != null or
        std.mem.find(u8, input, "Requirement already satisfied:") != null;
}

fn applyInstall(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var collected: SampleList = .{};
    defer collected.deinit(allocator);
    var satisfied: SampleList = .{};
    defer satisfied.deinit(allocator);
    var installing: SampleList = .{};
    defer installing.deinit(allocator);
    var downloads: usize = 0;
    var progress: usize = 0;

    var important: std.ArrayList([]const u8) = .empty;
    defer important.deinit(allocator);

    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    try scanInstallStream(allocator, stdout, &strip_buf, &collected, &satisfied, &installing, &downloads, &progress, &important);
    try scanInstallStream(allocator, stderr, &strip_buf, &collected, &satisfied, &installing, &downloads, &progress, &important);

    try writeSample(writer, "Collecting", &collected);
    if (downloads > 0) {
        try writer.writeAll("Downloaded ");
        try ansi.writeDecimal(writer, downloads);
        try writer.writeAll(" files\n");
    }
    try writeSample(writer, "Satisfied", &satisfied);
    try writeSample(writer, "Installing", &installing);
    if (progress > 0) {
        try writer.writeAll("Progress lines ");
        try ansi.writeDecimal(writer, progress);
        try writer.writeByte('\n');
    }
    for (important.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

fn scanInstallStream(
    allocator: Allocator,
    input: []const u8,
    strip_buf: *std.ArrayList(u8),
    collected: *SampleList,
    satisfied: *SampleList,
    installing: *SampleList,
    downloads: *usize,
    progress: *usize,
    important: *std.ArrayList([]const u8),
) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const stripped = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, stripped, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "Collecting ")) {
            try collected.add(allocator, firstToken(line["Collecting ".len..]));
        } else if (std.mem.startsWith(u8, line, "Downloading ")) {
            downloads.* += 1;
        } else if (std.mem.startsWith(u8, line, "Requirement already satisfied: ")) {
            try satisfied.addCountedSample(allocator, satisfiedName(line["Requirement already satisfied: ".len..]));
        } else if (std.mem.startsWith(u8, line, "Installing collected packages:")) {
            try scanInstallingPackages(allocator, line["Installing collected packages:".len..], installing);
        } else if (isProgressLine(line)) {
            progress.* += 1;
        } else {
            try important.append(allocator, line);
        }
    }
}

fn firstToken(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r");
    if (trimmed.len == 0) return trimmed;
    return trimmed[0 .. std.mem.indexOfAny(u8, trimmed, " \t\r") orelse trimmed.len];
}

fn satisfiedName(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r");
    if (trimmed.len == 0) return trimmed;
    if (std.mem.indexOf(u8, trimmed, " in ")) |idx| return std.mem.trim(u8, trimmed[0..idx], " \t\r");
    if (std.mem.indexOf(u8, trimmed, " (from ")) |idx| return std.mem.trim(u8, trimmed[0..idx], " \t\r");
    return firstToken(trimmed);
}

fn scanInstallingPackages(allocator: Allocator, input: []const u8, installing: *SampleList) !void {
    var it = std.mem.splitScalar(u8, input, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r,");
        try installing.add(allocator, name);
    }
}

fn isProgressLine(line: []const u8) bool {
    return std.mem.find(u8, line, " eta ") != null or
        std.mem.find(u8, line, "/s") != null;
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

fn isSeparator(line: []const u8) bool {
    var saw_dash = false;
    for (line) |c| {
        if (c == '-') {
            saw_dash = true;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return saw_dash;
}

fn isHeader(line: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(line, "Package ") or std.ascii.eqlIgnoreCase(line, "Package Version");
}

fn writeCollapsed(line: []const u8, writer: *Writer) !void {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var first = true;
    while (it.next()) |tok| {
        if (!first) try writer.writeByte(' ');
        first = false;
        try writer.writeAll(tok);
    }
}

test "pip list table collapses padding" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "Package    Version\n" ++
        "---------- -------\n" ++
        "requests   2.31.0\n" ++
        "urllib3    2.0.7\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings("requests 2.31.0\nurllib3 2.0.7\n", out.written());
}

test "pip list empty leaves no package rows" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "Package Version\n------- -------\n", "", &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "pip outdated table keeps latest and type" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "Package Version Latest Type\n" ++
        "------- ------- ------ -----\n" ++
        "pip     23.0    24.0   wheel\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings("pip 23.0 24.0 wheel\n", out.written());
}

test "matches: pip install output" {
    try std.testing.expect(matches("Collecting requests==2.31.0\n"));
    try std.testing.expect(matches("Successfully installed requests-2.31.0\n"));
}

test "apply: pip install summarizes progress and keeps result" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "Collecting requests==2.31.0\n" ++
        "  Downloading requests-2.31.0-py3-none-any.whl (62 kB)\n" ++
        "     ---- 62.0/62.0 kB 3.2 MB/s eta 0:00:00\n" ++
        "Requirement already satisfied: urllib3<3,>=1.21.1 in /usr/lib/python3/dist-packages (from requests) (2.0.7)\n" ++
        "Installing collected packages: requests, urllib3\n" ++
        "Successfully installed requests-2.31.0 urllib3-2.0.7\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Collecting 1: requests==2.31.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "Downloaded 1 files") != null);
    try std.testing.expect(std.mem.find(u8, got, "Satisfied 1: urllib3<3,>=1.21.1") != null);
    try std.testing.expect(std.mem.find(u8, got, "Installing 2: requests, urllib3") != null);
    try std.testing.expect(std.mem.find(u8, got, "Successfully installed requests-2.31.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "eta 0:00:00") == null);
}

test "stderr is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "ERROR: no such option\n", &out.writer);
    try std.testing.expectEqualStrings("ERROR: no such option\n", out.written());
}
