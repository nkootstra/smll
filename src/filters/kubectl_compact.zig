const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `kubectl get pods` — on by default (v0.6).
// Set SMLL_LOSSLESS=1 to bypass.
//
// Drops: READY, RESTARTS, AGE. Keeps: pod names + state sigil.
// Healthy pod (STATUS=Running, READY a/a): bare name.
// Unhealthy (anything else): name(STATUS) or name(x/y,STATUS) for partial-ready.
//
// Grammar:
//   k <count> <agg>: name1 name2 name3(Pending) name4(CrashLoopBackOff) ...
//
// <agg>: "running" (all healthy) | "mixed" | "none"
//
// Detection: first non-empty line starts with "NAME" AND contains "READY" AND "STATUS".

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "NAME")) return false;
        return std.mem.find(u8, line, "READY") != null and
            std.mem.find(u8, line, "STATUS") != null;
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    const header = lines.next() orelse return;
    const ready_col = std.mem.find(u8, header, "READY") orelse return;
    const status_col = std.mem.find(u8, header, "STATUS") orelse return;

    // Pass 1: count rows + classify.
    var pass1 = lines;
    var count: usize = 0;
    var running_healthy: usize = 0;
    while (pass1.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
        if (isHealthyRunning(line, ready_col, status_col)) running_healthy += 1;
    }

    const agg: []const u8 = blk: {
        if (count == 0) break :blk "none";
        if (running_healthy == count) break :blk "running";
        if (running_healthy == 0) break :blk "none";
        break :blk "mixed";
    };

    try writer.print("k{d}{s}", .{ count, agg });

    // Pass 2: emit names (annotate unhealthy).
    var pass2 = std.mem.splitScalar(u8, stdout, '\n');
    _ = pass2.next(); // skip header
    while (pass2.next()) |line| {
        if (line.len == 0) continue;
        const name = firstField(line);
        if (name.len == 0) continue;
        try writer.writeByte(' ');
        try writer.writeAll(name);
        if (!isHealthyRunning(line, ready_col, status_col)) {
            const status = fieldAt(line, status_col);
            const ready = fieldAt(line, ready_col);
            try writer.writeByte('(');
            if (!readyIsFull(ready)) {
                try writer.writeAll(ready);
                try writer.writeByte(',');
            }
            try writer.writeAll(status);
            try writer.writeByte(')');
        }
    }
    try writer.writeByte('\n');
}

fn isHealthyRunning(line: []const u8, ready_col: usize, status_col: usize) bool {
    const status = fieldAt(line, status_col);
    const ready = fieldAt(line, ready_col);
    return std.mem.eql(u8, status, "Running") and readyIsFull(ready);
}

/// "a/b" where a == b (and non-empty, non-"0/0").
fn readyIsFull(ready: []const u8) bool {
    const slash = std.mem.findScalar(u8, ready, '/') orelse return false;
    const left = ready[0..slash];
    const right = ready[slash + 1 ..];
    if (left.len == 0 or right.len == 0) return false;
    if (std.mem.eql(u8, left, "0")) return false;
    return std.mem.eql(u8, left, right);
}

/// Extract whitespace-delimited field starting at-or-after `col` in `line`.
fn fieldAt(line: []const u8, col: usize) []const u8 {
    if (col >= line.len) return "";
    var i = col;
    // If col lands on space (columns rarely align exactly past first row), advance.
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    // If col lands mid-field, back up to field start.
    if (col > 0 and i == col and line[col] != ' ' and line[col] != '\t') {
        var j = col;
        while (j > 0 and line[j - 1] != ' ' and line[j - 1] != '\t') j -= 1;
        i = j;
    }
    const start = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    return line[start..i];
}

fn firstField(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    const start = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    return line[start..i];
}

test "matches: kubectl header" {
    try std.testing.expect(matches("NAME   READY   STATUS   RESTARTS   AGE\npod1   1/1   Running   0   1d\n"));
}

test "matches: rejects non-kubectl" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("CONTAINER ID   IMAGE\n"));
    try std.testing.expect(!matches("NAME  IMAGE\n")); // missing READY/STATUS
}

test "readyIsFull" {
    try std.testing.expect(readyIsFull("1/1"));
    try std.testing.expect(readyIsFull("3/3"));
    try std.testing.expect(!readyIsFull("0/0"));
    try std.testing.expect(!readyIsFull("0/1"));
    try std.testing.expect(!readyIsFull("1/2"));
    try std.testing.expect(!readyIsFull(""));
    try std.testing.expect(!readyIsFull("1"));
}

test "apply: fixture all-running produces count + names" {
    const fixture = @embedFile("fixture_kubectl_pods");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, fixture, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.startsWith(u8, got, "k9running"));
    try std.testing.expect(std.mem.endsWith(u8, got, "\n"));
    try std.testing.expect(std.mem.find(u8, got, "api-server-6f8b9c4d7-x2k8m") != null);
    try std.testing.expect(std.mem.find(u8, got, "redis-master-0") != null);
    try std.testing.expect(std.mem.find(u8, got, "cert-manager-5dc8f9b-abcde") != null);
    // No status annotations when all healthy.
    try std.testing.expect(std.mem.find(u8, got, "(Running)") == null);
}

test "apply: mixed state annotates unhealthy pods" {
    const input =
        \\NAME        READY   STATUS             RESTARTS   AGE
        \\pod-ok      1/1     Running            0          1d
        \\pod-bad     0/1     CrashLoopBackOff   5          2h
        \\pod-pend    0/1     Pending            0          30s
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.startsWith(u8, got, "k3mixed"));
    try std.testing.expect(std.mem.find(u8, got, "pod-ok ") != null or std.mem.endsWith(u8, got, "pod-ok\n"));
    try std.testing.expect(std.mem.find(u8, got, "pod-bad(0/1,CrashLoopBackOff)") != null);
    try std.testing.expect(std.mem.find(u8, got, "pod-pend(0/1,Pending)") != null);
}

test "apply: zero rows produces k0none:" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "NAME   READY   STATUS   RESTARTS   AGE\n", &.{}, &out.writer);
    try std.testing.expectEqualStrings("k0none\n", out.written());
}

test "apply: empty input produces nothing" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", &.{}, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}
