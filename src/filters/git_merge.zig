const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.4 grammar for `git merge`:
//   @ ff <sha7>..<sha7>           fast-forward header
//   @ merge <strategy>            merge-commit header
//   <path> |<N>                   stat line (markers stripped)
//   +<ins>/-<del> files=<N>       summary
//   + <path>  / - <path>          create/delete mode
//   ! conflict <path>             conflicted path
//   ! failed                      "Automatic merge failed"
// matches() = false (argv-only dispatch).

pub fn matches(input: []const u8) bool {
    // Detect git merge output by checking first non-empty line for known markers.
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "Merge made by")) return true;
        if (std.mem.startsWith(u8, line, "Updating ") and std.mem.find(u8, line, "..") != null) return true;
        if (std.mem.startsWith(u8, line, "Already up to date")) return true;
        return false;
    }
    return false;
}

pub fn apply(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    // Phase 1: generate standard output
    var buf = Writer.Allocating.init(a);
    defer buf.deinit();
    try applyInner(a, stdout, stderr, &buf.writer);
    // Phase 2: group consecutive stat/create lines by directory
    try groupMergeEntries(buf.written(), w);
}

fn groupMergeEntries(output: []const u8, w: *Writer) !void {
    var all_lines: [4096][]const u8 = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (count >= all_lines.len) break;
        all_lines[count] = line;
        count += 1;
    }
    var i: usize = 0;
    while (i < count) {
        const line = all_lines[i];
        // Detect stat lines: "path |N" or "+/- path"
        const dir = statLineDir(line) orelse createLineDir(line);
        if (dir != null and dir.?.len > 0) {
            const d = dir.?;
            const is_stat = statLineDir(line) != null;
            var run_end = i + 1;
            while (run_end < count) {
                const next_dir = if (is_stat) statLineDir(all_lines[run_end]) else createLineDir(all_lines[run_end]);
                if (next_dir == null or !std.mem.eql(u8, d, next_dir.?)) break;
                run_end += 1;
            }
            if (run_end - i >= 3) {
                if (is_stat) {
                    try w.writeAll(d);
                    try w.writeAll(" ×");
                    try ansi.writeDecimal(w, run_end - i);
                    try w.writeByte('\n');
                } else {
                    // Preserve the sigil (+ or -)
                    try w.writeAll(line[0..2]);
                    try w.writeAll(d);
                    try w.writeAll(" ×");
                    try ansi.writeDecimal(w, run_end - i);
                    try w.writeByte('\n');
                }
                i = run_end;
                continue;
            }
        }
        try w.writeAll(line);
        try w.writeByte('\n');
        i += 1;
    }
}

fn statLineDir(line: []const u8) ?[]const u8 {
    // Matches "path |N" — extract directory from path
    const pipe = std.mem.find(u8, line, " |") orelse return null;
    const path = line[0..pipe];
    if (std.mem.findScalarLast(u8, path, '/')) |idx| return path[0 .. idx + 1];
    return null;
}

fn createLineDir(line: []const u8) ?[]const u8 {
    // Matches "+ path" or "- path"
    if (line.len >= 3 and (line[0] == '+' or line[0] == '-') and line[1] == ' ') {
        const path = line[2..];
        if (std.mem.findScalarLast(u8, path, '/')) |idx| return path[0 .. idx + 1];
    }
    return null;
}

fn applyInner(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    _ = a;
    const src = if (stdout.len > 0) stdout else stderr;
    if (src.len == 0 and stderr.len == 0) return;

    var it = std.mem.splitScalar(u8, src, '\n');
    var first: []const u8 = "";
    while (it.next()) |ln| {
        if (ln.len > 0) {
            first = ln;
            break;
        }
    }

    if (std.mem.startsWith(u8, first, "Updating ")) {
        const r = first["Updating ".len..];
        if (std.mem.find(u8, r, "..")) |d| {
            try w.writeAll("@ ff ");
            try w.writeAll(r[0..@min(d, 7)]);
            try w.writeAll("..");
            const b = r[d + 2 ..];
            var be: usize = 0;
            while (be < b.len and b[be] != ' ') be += 1;
            try w.writeAll(b[0..@min(be, 7)]);
            try w.writeByte('\n');
        }
        // skip "Fast-forward" line
        while (it.next()) |ln| {
            if (std.mem.eql(u8, ln, "Fast-forward")) break;
        }
        try emitBody(&it, w);
    } else if (std.mem.startsWith(u8, first, "Merge made by")) {
        var strat: []const u8 = "ort";
        if (std.mem.find(u8, first, "'")) |q| {
            const s = first[q + 1 ..];
            if (std.mem.find(u8, s, "'")) |e| strat = s[0..e];
        }
        try w.writeAll("@ merge ");
        try w.writeAll(strat);
        try w.writeByte('\n');
        try emitBody(&it, w);
    } else if (std.mem.startsWith(u8, first, "Already up to date")) {
        try w.writeAll("up to date\n");
    } else {
        try emitConflicts(&it, w);
    }
    if (stdout.len > 0 and stderr.len > 0) {
        var si = std.mem.splitScalar(u8, stderr, '\n');
        try emitConflicts(&si, w);
    }
}

fn emitBody(it: *std.mem.SplitIterator(u8, .scalar), w: *Writer) !void {
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const t = std.mem.trimStart(u8, line, " \t");
        if (t.len == 0) continue;
        // Fast dispatch on first char to reduce string comparisons.
        switch (t[0]) {
            'C' => if (std.mem.startsWith(u8, t, "CONFLICT (")) try emitConflictLine(t, w),
            'A' => if (std.mem.startsWith(u8, t, "Automatic merge failed")) try w.writeAll("! failed\n"),
            'c' => if (std.mem.startsWith(u8, t, "create mode ")) {
                try w.writeAll("+ ");
                try w.writeAll(util.skipModeNum(t[12..]));
                try w.writeByte('\n');
            },
            'd' => if (std.mem.startsWith(u8, t, "delete mode ")) {
                try w.writeAll("- ");
                try w.writeAll(util.skipModeNum(t[12..]));
                try w.writeByte('\n');
            },
            else => if (std.mem.find(u8, t, " | ") != null) {
                try util.writeStatLine(t, w);
            } else if (std.mem.find(u8, t, " changed") != null) {
                try util.writeSummary(t, w);
            },
        }
    }
}

fn emitConflicts(it: *std.mem.SplitIterator(u8, .scalar), w: *Writer) !void {
    while (it.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "CONFLICT (")) {
            try emitConflictLine(t, w);
        } else if (std.mem.startsWith(u8, t, "Automatic merge failed")) {
            try w.writeAll("! failed\n");
        }
    }
}

fn emitConflictLine(t: []const u8, w: *Writer) !void {
    const p = util.conflictPath(t);
    if (p.len > 0) {
        try w.writeAll("! conflict ");
        try w.writeAll(p);
        try w.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// Fixtures + tests.
// ---------------------------------------------------------------------------

const fixture_ff = @embedFile("fixture_git_merge_ff");
const fixture_commit = @embedFile("fixture_git_merge_commit");
const fixture_conflict_stdout = @embedFile("fixture_git_merge_conflict_stdout");
const fixture_conflict_stderr = @embedFile("fixture_git_merge_conflict_stderr");
const fixture_large = @embedFile("fixture_git_merge_large");

fn str(allocator: Allocator, so: []const u8, se: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, so, se, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: detects merge output" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(matches("Updating abc..def\nFast-forward\n"));
    try std.testing.expect(!matches("CONFLICT (content): x\n"));
    try std.testing.expect(matches("Merge made by the 'ort' strategy.\n"));
    try std.testing.expect(matches("Already up to date.\n"));
    try std.testing.expect(!matches("random text\n"));
}

test "pipe-mode matches merge fixtures" {
    try std.testing.expect(matches(fixture_ff));
    // conflict stdout starts with conflict markers, not merge header
    try std.testing.expect(!matches(fixture_conflict_stdout));
}

test "ff: header" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_ff, "");
    defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "@ ff 81a7b77..af90dc8\n"));
}

test "ff: summary" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_ff, "");
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+1/-0 files=1\n") != null);
}

test "ff: stat path" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_ff, "");
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "fx.txt") != null);
}

test "ff: create mode" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_ff, "");
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+ fx.txt\n") != null);
}

test "merge-commit: header" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_commit, "");
    defer a.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "@ merge ort\n"));
}

test "merge-commit: summary and path" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_commit, "");
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+1/-0 files=1\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "fy.txt") != null);
}

test "conflict: path and failed" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_conflict_stdout, fixture_conflict_stderr);
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "! conflict conflict.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "! failed\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "Auto-merging") == null);
}

test "large: grouped stat paths and summary" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_large, "");
    defer a.free(out);
    // Stat lines grouped by directory
    try std.testing.expect(std.mem.find(u8, out, "src/") != null);
    try std.testing.expect(std.mem.find(u8, out, "+300/-0 files=60\n") != null);
}

test "R3: ff" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_ff, "");
    defer a.free(out);
    const raw = fixture_ff.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100) else try std.testing.expect(out.len <= raw);
}

test "R3: merge-commit" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_commit, "");
    defer a.free(out);
    const raw = fixture_commit.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100) else try std.testing.expect(out.len <= raw);
}

test "R3: conflict" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_conflict_stdout, fixture_conflict_stderr);
    defer a.free(out);
    const raw = fixture_conflict_stdout.len + fixture_conflict_stderr.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100) else try std.testing.expect(out.len <= raw);
}

test "R3: large" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_large, "");
    defer a.free(out);
    const raw = fixture_large.len;
    if (raw >= 50) try std.testing.expect(out.len <= (raw * 80) / 100) else try std.testing.expect(out.len <= raw);
}

test "empty" {
    const a = std.testing.allocator;
    const out = try str(a, "", "");
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}
