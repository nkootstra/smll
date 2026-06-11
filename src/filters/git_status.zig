const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.4 grammar for `git status`:
//
//   # <branch>                — branch name (always first line)
//   # <branch> +<n>           — branch ahead by n commits
//   # <branch> -<n>           — branch behind by n commits
//   # <branch> +<a> -<b>      — ahead a, behind b
//   S <path>                  — staged modified    (Changes to be committed: modified:)
//   A <path>                  — staged new file    (Changes to be committed: new file:)
//   D <path>                  — staged deleted     (Changes to be committed: deleted:)
//   R <old> -> <new>          — staged renamed     (Changes to be committed: renamed:)
//   M <path>                  — unstaged modified  (Changes not staged: modified:)
//   d <path>                  — unstaged deleted   (Changes not staged: deleted:)
//   ? <path>                  — untracked          (Untracked files:)
//   UU <path>                 — unmerged both modified
//   AU <path>                 — unmerged added by us
//   UA <path>                 — unmerged added by them
//   DU <path>                 — unmerged deleted by us
//   UD <path>                 — unmerged deleted by them
//
// All section headers ("Changes to be committed:", etc.), hint lines
// ("  (use "git add ...""), and the trailing summary line are dropped.
// Branch name and ahead/behind counts are preserved. Every ordinary path is
// preserved verbatim; long sequential numeric runs in one directory are
// summarized as an explicit first..last range.

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return std.mem.startsWith(u8, line, "On branch ") or
            std.mem.startsWith(u8, line, "HEAD detached ") or
            std.mem.startsWith(u8, line, "interactive rebase in progress");
    }
    return false;
}

const Section = enum {
    none,
    staged,
    unstaged,
    untracked,
    unmerged,
};

const StatusEntry = struct {
    code: []const u8,
    path: []const u8,
};

const StatusPrefix = struct {
    prefix: []const u8,
    code: []const u8,
    trim_path_start: bool = false,
};

const staged_prefixes = [_]StatusPrefix{
    .{ .prefix = "modified:   ", .code = "S" },
    .{ .prefix = "new file:   ", .code = "A" },
    .{ .prefix = "deleted:    ", .code = "D" },
    .{ .prefix = "renamed:    ", .code = "R" },
};

const unstaged_prefixes = [_]StatusPrefix{
    .{ .prefix = "modified:   ", .code = "M" },
    .{ .prefix = "deleted:    ", .code = "d" },
};

const unmerged_prefixes = [_]StatusPrefix{
    .{ .prefix = "both modified:   ", .code = "UU" },
    .{ .prefix = "added by us:    ", .code = "AU" },
    .{ .prefix = "added by them:  ", .code = "UA" },
    .{ .prefix = "deleted by us:  ", .code = "DU" },
    .{ .prefix = "deleted by them:", .code = "UD", .trim_path_start = true },
};

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    try applyStreaming(stdout, writer);
}

const DIR_GROUP_THRESHOLD: usize = 3;
const NUMERIC_RANGE_THRESHOLD: usize = 6;

/// Single-pass streaming apply: parses input lines, formats sigil output,
/// and groups consecutive same-dir entries on the fly without buffering.
fn applyStreaming(input: []const u8, writer: *Writer) !void {
    if (input.len == 0) return;

    var lines = std.mem.splitScalar(u8, input, '\n');
    var section: Section = .none;
    var branch_written = false;
    var branch_buf: [256]u8 = undefined;
    var branch_len: usize = 0;
    var ahead: ?[]const u8 = null;
    var behind: ?[]const u8 = null;
    var upstream: ?[]const u8 = null;

    // Streaming directory grouping state.
    var run_key: []const u8 = "";
    var run_dir: []const u8 = "";
    // Store original content lines and sections; formatting is re-derived from
    // the status-entry table when the run flushes.
    var run_sections: [64]Section = undefined;
    var run_contents: [64][]const u8 = undefined;
    var run_len: usize = 0;

    while (lines.next()) |line| {
        // Branch detection
        if (!branch_written) {
            if (line.len >= 10 and line[0] == 'O' and std.mem.startsWith(u8, line, "On branch ")) {
                const b = line["On branch ".len..];
                const copy_len = @min(b.len, branch_buf.len);
                @memcpy(branch_buf[0..copy_len], b[0..copy_len]);
                branch_len = copy_len;
                continue;
            } else if (line.len >= 17 and line[0] == 'H' and std.mem.startsWith(u8, line, "HEAD detached at ")) {
                const ref = line["HEAD detached at ".len..];
                const prefix = "HEAD:";
                const copy_len = @min(prefix.len + ref.len, branch_buf.len);
                @memcpy(branch_buf[0..prefix.len], prefix);
                @memcpy(branch_buf[prefix.len..copy_len], ref[0 .. copy_len - prefix.len]);
                branch_len = copy_len;
                continue;
            } else if (line.len >= 30 and line[0] == 'i' and std.mem.startsWith(u8, line, "interactive rebase in progress")) {
                const b = "rebase-in-progress";
                @memcpy(branch_buf[0..b.len], b);
                branch_len = b.len;
                continue;
            } else if (line.len > 0 and line[0] == 'Y') {
                if (std.mem.startsWith(u8, line, "Your branch is ahead")) {
                    if (findAheadBehindCount(line, "by ")) |count| ahead = count;
                    continue;
                } else if (std.mem.startsWith(u8, line, "Your branch is behind")) {
                    if (findAheadBehindCount(line, "by ")) |count| behind = count;
                    continue;
                } else if (std.mem.startsWith(u8, line, "Your branch is up to date with '")) {
                    const after = line["Your branch is up to date with '".len..];
                    if (std.mem.findScalar(u8, after, '\'')) |q| upstream = after[0..q];
                    continue;
                } else if (std.mem.startsWith(u8, line, "Your branch and")) {
                    if (findDivergedCounts(line)) |counts| {
                        ahead = counts[0];
                        behind = counts[1];
                    }
                    continue;
                }
            }
        }

        // Section headers - first byte dispatch
        if (line.len > 0) switch (line[0]) {
            'C' => {
                if (std.mem.eql(u8, line, "Changes to be committed:")) {
                    section = .staged;
                    continue;
                } else if (std.mem.eql(u8, line, "Changes not staged for commit:")) {
                    section = .unstaged;
                    continue;
                }
            },
            'U' => {
                if (std.mem.eql(u8, line, "Untracked files:")) {
                    section = .untracked;
                    continue;
                } else if (std.mem.eql(u8, line, "Unmerged paths:")) {
                    section = .unmerged;
                    continue;
                }
            },
            else => {},
        };

        if (isHintLine(line)) continue;
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        if (line.len > 0) switch (line[0]) {
            'n' => if (std.mem.startsWith(u8, line, "no changes added to commit") or
                std.mem.startsWith(u8, line, "nothing to commit") or
                std.mem.startsWith(u8, line, "nothing added to commit")) continue,
            'Y' => if (std.mem.startsWith(u8, line, "You have unmerged paths")) continue,
            'A' => if (std.mem.startsWith(u8, line, "All conflicts fixed")) continue,
            else => {},
        };

        // Tab-indented content lines
        if (line.len > 0 and line[0] == '\t') {
            if (!branch_written) {
                try writeBranchLine(writer, branch_buf[0..branch_len], ahead, behind, upstream);
                branch_written = true;
            }

            const content = line[1..];
            const entry = entryFor(section, content);

            if (entry) |e| {
                if (e.path.len == 0) {
                    try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_dir);
                    run_len = 0;
                    run_key = "";
                    writeSectionEntry(writer, section, content) catch {
                        try writer.writeAll(line);
                        try writer.writeByte('\n');
                    };
                    continue;
                }

                const dir = parentDir(e.path);
                const key = groupKey(section, e.code);
                if (dir.len > 0 and run_len > 0 and std.mem.eql(u8, key, run_key) and
                    std.mem.eql(u8, dir, run_dir))
                {
                    // Extend current run
                    if (run_len < run_sections.len) {
                        run_sections[run_len] = section;
                        run_contents[run_len] = content;
                        run_len += 1;
                    } else {
                        try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_dir);
                        run_sections[0] = section;
                        run_contents[0] = content;
                        run_len = 1;
                    }
                } else {
                    // Flush previous run, start new one
                    try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_dir);
                    run_sections[0] = section;
                    run_contents[0] = content;
                    run_len = 1;
                    run_key = key;
                    run_dir = if (dir.len > 0) dir else "";
                }
            } else {
                try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_dir);
                run_len = 0;
                run_key = "";
                writeSectionEntry(writer, section, content) catch {
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                };
            }
            continue;
        }

        if (branch_written) {
            try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_dir);
            run_len = 0;
            run_key = "";
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }

    try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_dir);

    if (!branch_written and branch_len > 0) {
        try writeBranchLine(writer, branch_buf[0..branch_len], ahead, behind, upstream);
    }
}

fn entryFor(section: Section, content: []const u8) ?StatusEntry {
    return switch (section) {
        .staged => entryFromPrefixes(content, staged_prefixes[0..], "S"),
        .unstaged => entryFromPrefixes(content, unstaged_prefixes[0..], "M"),
        .untracked => .{ .code = "?", .path = content },
        .unmerged => entryFromPrefixes(content, unmerged_prefixes[0..], "UU"),
        .none => null,
    };
}

fn entryFromPrefixes(content: []const u8, prefixes: []const StatusPrefix, fallback_code: []const u8) StatusEntry {
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, content, prefix.prefix)) continue;
        const raw_path = content[prefix.prefix.len..];
        return .{
            .code = prefix.code,
            .path = if (prefix.trim_path_start) std.mem.trimStart(u8, raw_path, " ") else raw_path,
        };
    }
    return .{ .code = fallback_code, .path = content };
}

fn groupKey(section: Section, code: []const u8) []const u8 {
    if (section == .unmerged) return "U";
    return code;
}

fn parentDir(path: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, path, '/')) |idx| {
        return path[0 .. idx + 1];
    }
    return "";
}

fn flushRun(writer: *Writer, sections: []const Section, contents: []const []const u8, dir: []const u8) !void {
    if (sections.len == 0) return;
    if (try writeNumericRangeGroup(writer, sections, contents, dir)) return;
    if (sections.len >= DIR_GROUP_THRESHOLD and dir.len > 0) {
        // Dirname-prefix RLE: emit first entry fully, then subsequent
        // entries without the shared directory prefix so agents can
        // see every individual filename.
        for (sections, contents, 0..) |sec, content, i| {
            if (i == 0) {
                try writeSectionEntry(writer, sec, content);
            } else {
                // Emit just sigil + filename (strip shared dir prefix)
                const entry = entryFor(sec, content) orelse {
                    try writeSectionEntry(writer, sec, content);
                    continue;
                };
                if (entry.path.len > dir.len and std.mem.startsWith(u8, entry.path, dir)) {
                    try writeCode(writer, entry.code);
                    try writer.writeAll(entry.path[dir.len..]);
                    try writer.writeByte('\n');
                } else {
                    try writeSectionEntry(writer, sec, content);
                }
            }
        }
    } else {
        for (sections, contents) |sec, content| {
            try writeSectionEntry(writer, sec, content);
        }
    }
}

const NumericBasename = struct {
    basename: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    value: usize,
};

fn writeNumericRangeGroup(writer: *Writer, sections: []const Section, contents: []const []const u8, dir: []const u8) !bool {
    if (contents.len < NUMERIC_RANGE_THRESHOLD or dir.len == 0) return false;

    const first_entry = entryFor(sections[0], contents[0]) orelse return false;
    const code = first_entry.code;
    const first = parseNumericBasename(first_entry.path, dir) orelse return false;
    var last = first;

    for (contents[1..], 1..) |content, i| {
        const entry = entryFor(sections[i], content) orelse return false;
        if (!std.mem.eql(u8, entry.code, code)) return false;
        const parsed = parseNumericBasename(entry.path, dir) orelse return false;
        if (!std.mem.eql(u8, parsed.prefix, first.prefix)) return false;
        if (!std.mem.eql(u8, parsed.suffix, first.suffix)) return false;
        const expected = std.math.add(usize, first.value, i) catch return false;
        if (parsed.value != expected) return false;
        last = parsed;
    }

    try writeCode(writer, code);
    try writer.writeAll(dir);
    try writer.writeAll(first.basename);
    try writer.writeAll("..");
    try writer.writeAll(last.basename);
    try writer.writeByte('\n');
    return true;
}

fn parseNumericBasename(path: []const u8, dir: []const u8) ?NumericBasename {
    if (!std.mem.startsWith(u8, path, dir) or path.len <= dir.len) return null;
    const basename = path[dir.len..];

    var digit_end: ?usize = null;
    var i = basename.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.isDigit(basename[i])) {
            digit_end = i + 1;
            break;
        }
    }
    const end = digit_end orelse return null;

    var start = end;
    while (start > 0 and std.ascii.isDigit(basename[start - 1])) : (start -= 1) {}
    if (start == end) return null;

    const value = std.fmt.parseUnsigned(usize, basename[start..end], 10) catch return null;
    return .{
        .basename = basename,
        .prefix = basename[0..start],
        .suffix = basename[end..],
        .value = value,
    };
}

fn writeCode(writer: *Writer, code: []const u8) !void {
    try writer.writeAll(code);
    try writer.writeByte(' ');
}

fn writeSectionEntry(writer: *Writer, section: Section, content: []const u8) !void {
    if (entryFor(section, content)) |entry| {
        try writeCode(writer, entry.code);
        try writer.writeAll(entry.path);
    } else {
        try writer.writeAll(content);
    }
    try writer.writeByte('\n');
}

fn writeBranchLine(writer: *Writer, branch: []const u8, ahead: ?[]const u8, behind: ?[]const u8, upstream: ?[]const u8) !void {
    try writer.writeAll("# ");
    try writer.writeAll(branch);
    if (ahead) |a| {
        try writer.writeAll(" +");
        try writer.writeAll(a);
    }
    if (behind) |b| {
        try writer.writeAll(" -");
        try writer.writeAll(b);
    }
    // Record the tracking upstream only when the branch is in sync — divergence
    // is already conveyed by the +/- markers above.
    if (ahead == null and behind == null) {
        if (upstream) |u| {
            try writer.writeAll(" =");
            try writer.writeAll(u);
        }
    }
    try writer.writeByte('\n');
}

fn isHintLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "  (") and std.mem.endsWith(u8, line, ")");
}

/// Extract the number following `marker` in `line` (e.g. "by 2 commits." → "2").
/// Returns a slice into `line`.
fn findAheadBehindCount(line: []const u8, marker: []const u8) ?[]const u8 {
    const idx = std.mem.find(u8, line, marker) orelse return null;
    const rest = line[idx + marker.len ..];
    // Digits until non-digit.
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return rest[0..end];
}

/// Parse "have X and Y different commits" from a diverged-branch line.
/// Returns [ahead_slice, behind_slice] into `line`, or null.
fn findDivergedCounts(line: []const u8) ?[2][]const u8 {
    // "have diverged, and have X and Y different commits each."
    var search = line;
    // Find "and have " which precedes the counts
    var idx = std.mem.find(u8, search, "and have ") orelse return null;
    search = search[idx + "and have ".len ..];
    // Now parse X
    var end_x: usize = 0;
    while (end_x < search.len and search[end_x] >= '0' and search[end_x] <= '9') : (end_x += 1) {}
    if (end_x == 0) return null;
    const ahead = search[0..end_x];
    // Skip " and "
    const and_marker = " and ";
    idx = std.mem.find(u8, search[end_x..], and_marker) orelse return null;
    search = search[end_x + idx + and_marker.len ..];
    var end_y: usize = 0;
    while (end_y < search.len and search[end_y] >= '0' and search[end_y] <= '9') : (end_y += 1) {}
    if (end_y == 0) return null;
    const behind = search[0..end_y];
    return .{ ahead, behind };
}

/// Apply dirname-prefix RLE to `git status --short` / `-s` porcelain v1 output.
/// Input grammar (one line per entry):
///   XY <path>                — X=index, Y=worktree, X|Y ∈ { ' ', M, A, D, R, C, U, ? }
///   XY <old> -> <new>        — rename (X='R'); both paths preserved verbatim.
///
/// Compaction: consecutive entries with the same XY pair AND the same parent
/// directory share ink — first entry full, subsequent entries emit XY plus the
/// dirname-stripped basename. Untracked (`??`) is grouped the same way.
/// Rename entries are never grouped (the `old -> new` shape breaks dirname
/// equality). Lines that don't match the porcelain v1 grammar pass through
/// verbatim — preserves any unexpected git output (warnings, etc.).
pub fn applyShort(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var prev_xy: [2]u8 = .{ 0, 0 };
    var prev_dir: []const u8 = "";
    var run_len: usize = 0;

    while (lines.next()) |line| {
        if (line.len == 0) {
            // Trailing newline yields a final empty split — skip silently.
            continue;
        }
        if (!isShortStatusLine(line)) {
            // Unknown line shape: passthrough verbatim and reset the run.
            try writer.writeAll(line);
            try writer.writeByte('\n');
            run_len = 0;
            continue;
        }

        const xy: [2]u8 = .{ line[0], line[1] };
        const path = line[3..];
        const is_rename = xy[0] == 'R' or xy[0] == 'C';
        const dir = if (is_rename) "" else parentDir(path);

        const same_run =
            run_len > 0 and
            !is_rename and
            dir.len > 0 and
            xy[0] == prev_xy[0] and xy[1] == prev_xy[1] and
            std.mem.eql(u8, dir, prev_dir);

        if (same_run) {
            try writer.writeAll(&xy);
            try writer.writeByte(' ');
            try writer.writeAll(path[dir.len..]);
            try writer.writeByte('\n');
        } else {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            prev_xy = xy;
            prev_dir = dir;
            run_len = if (is_rename) 0 else 1;
        }
        if (same_run) run_len += 1;
    }
}

/// True when the line matches `git status --short` (porcelain v1) grammar:
/// 2 sigil bytes from a fixed set, a space, then a non-empty path.
fn isShortStatusLine(line: []const u8) bool {
    if (line.len < 4) return false;
    if (line[2] != ' ') return false;
    return isShortSigil(line[0]) and isShortSigil(line[1]);
}

fn isShortSigil(c: u8) bool {
    return c == ' ' or c == 'M' or c == 'A' or c == 'D' or
        c == 'R' or c == 'C' or c == 'U' or c == '?' or c == '!' or c == 'T';
}

// ---------------------------------------------------------------------------
// Fixtures (embedded at compile time).
// ---------------------------------------------------------------------------

const dirty_fixture = @embedFile("fixture_git_status_dirty");
const clean_fixture = @embedFile("fixture_git_status_clean");
const conflict_fixture = @embedFile("fixture_git_status_conflict");
const short_fixture = @embedFile("fixture_git_status_short");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

test "matches: dirty fixture" {
    try std.testing.expect(matches(dirty_fixture));
}

test "matches: clean fixture" {
    try std.testing.expect(matches(clean_fixture));
}

test "matches: conflict fixture" {
    try std.testing.expect(matches(conflict_fixture));
}

test "matches: detached HEAD" {
    try std.testing.expect(matches("HEAD detached at abc123\n"));
}

test "matches: interactive rebase" {
    try std.testing.expect(matches("interactive rebase in progress; onto main\n"));
}

test "matches: leading blank line is skipped" {
    try std.testing.expect(matches("\n\nOn branch main\n"));
}

test "matches: non-git input returns false" {
    try std.testing.expect(!matches("some random text\nnot a git status\n"));
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("error: fatal: not a git repository\n"));
}

test "apply: v0.4 output not re-matched by matches on dirty (idempotent passthrough)" {
    // v0.4 output starts with "# main\n" — NOT recognized by matches() which expects
    // "On branch". Piping v0.4 output through smll again produces passthrough (matches=false).
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    try std.testing.expect(!matches(out));
}

test "apply: self-recognizable on clean" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, clean_fixture);
    defer allocator.free(out);
    // v0.4 output starts with "# main\n" — NOT recognized by matches() which expects
    // "On branch". This is intentional: pipe-mode idempotence means v0.4 output
    // passes through unchanged when piped into smll again (matches=false → passthrough).
    try std.testing.expect(!matches(out));
}

test "apply: output for dirty fixture has correct format" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    // Branch line — dirty fixture tracks origin/main and is in sync.
    try std.testing.expect(std.mem.startsWith(u8, out, "# main =origin/main\n"));
    // Unstaged modified paths
    try std.testing.expect(std.mem.find(u8, out, "M src/main.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "M src/pipeline.zig\n") != null);
    // Untracked paths
    try std.testing.expect(std.mem.find(u8, out, "? src/filters/git_status.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "? tests/fixtures/git_status_dirty.txt\n") != null);
}

test "apply: output for clean fixture is just branch line" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, clean_fixture);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("# main =origin/main\n", out);
}

test "apply: up-to-date branch records upstream" {
    const allocator = std.testing.allocator;
    const input =
        "On branch main\n" ++
        "Your branch is up to date with 'origin/main'.\n" ++
        "\n" ++
        "nothing to commit, working tree clean\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("# main =origin/main\n", out);
}

test "apply: output for conflict fixture has UU sigil" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, conflict_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "# main\n"));
    try std.testing.expect(std.mem.find(u8, out, "S src/pipeline.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "UU src/filters/git_status.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "? tests/fixtures/git_status_conflict.txt\n") != null);
}

test "apply: drops all hint lines on dirty" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "(use \"git add") == null);
    try std.testing.expect(std.mem.find(u8, out, "(use \"git restore") == null);
    try std.testing.expect(std.mem.find(u8, out, "(use \"git commit") == null);
}

test "apply: drops section headers on dirty" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "Changes not staged for commit:") == null);
    try std.testing.expect(std.mem.find(u8, out, "Untracked files:") == null);
}

test "apply: R3 gate — dirty fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    const raw_bytes = dirty_fixture.len;
    const smll_bytes = out.len;
    const target = (raw_bytes * 80) / 100;
    try std.testing.expect(smll_bytes <= target);
}

test "apply: R3 gate — conflict fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, conflict_fixture);
    defer allocator.free(out);
    const raw_bytes = conflict_fixture.len;
    const smll_bytes = out.len;
    const target = (raw_bytes * 80) / 100;
    try std.testing.expect(smll_bytes <= target);
}

test "apply: staged-new-file uses A sigil" {
    const allocator = std.testing.allocator;
    const input =
        "On branch feat\n" ++
        "Changes to be committed:\n" ++
        "  (use \"git restore --staged <file>...\" to unstage)\n" ++
        "\tnew file:   src/new_module.zig\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "A src/new_module.zig\n") != null);
}

test "apply: sequential numeric paths compact to an explicit range" {
    const allocator = std.testing.allocator;
    const input =
        "On branch feat\n" ++
        "Changes to be committed:\n" ++
        "\tnew file:   src/components/comp_01.rs\n" ++
        "\tnew file:   src/components/comp_02.rs\n" ++
        "\tnew file:   src/components/comp_03.rs\n" ++
        "\tnew file:   src/components/comp_04.rs\n" ++
        "\tnew file:   src/components/comp_05.rs\n" ++
        "\tnew file:   src/components/comp_06.rs\n" ++
        "\tnew file:   src/components/comp_07.rs\n" ++
        "\tnew file:   src/components/comp_08.rs\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "# feat\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "A src/components/comp_01.rs..comp_08.rs\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "comp_02.rs\n") == null);
}

test "apply: unmerged numeric range preserves conflict type" {
    const allocator = std.testing.allocator;
    const input =
        "On branch feat\n" ++
        "You have unmerged paths.\n" ++
        "  (fix conflicts and run \"git commit\")\n" ++
        "\n" ++
        "Unmerged paths:\n" ++
        "\tadded by us:    generated/conflict_01.rs\n" ++
        "\tadded by us:    generated/conflict_02.rs\n" ++
        "\tadded by us:    generated/conflict_03.rs\n" ++
        "\tadded by us:    generated/conflict_04.rs\n" ++
        "\tadded by us:    generated/conflict_05.rs\n" ++
        "\tadded by us:    generated/conflict_06.rs\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "AU generated/conflict_01.rs..conflict_06.rs\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "UU generated/conflict_01.rs..conflict_06.rs\n") == null);
}

test "apply: unmerged dirname grouping preserves conflict type" {
    const allocator = std.testing.allocator;
    const input =
        "On branch feat\n" ++
        "You have unmerged paths.\n" ++
        "\n" ++
        "Unmerged paths:\n" ++
        "\tdeleted by them: generated/alpha.rs\n" ++
        "\tdeleted by them: generated/beta.rs\n" ++
        "\tdeleted by them: generated/gamma.rs\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "UD generated/alpha.rs\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "UD beta.rs\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "UU beta.rs\n") == null);
}

test "apply: numeric range sequence overflow falls back" {
    const allocator = std.testing.allocator;
    const input =
        "On branch feat\n" ++
        "Changes to be committed:\n" ++
        "\tnew file:   generated/file_18446744073709551612.rs\n" ++
        "\tnew file:   generated/file_18446744073709551613.rs\n" ++
        "\tnew file:   generated/file_18446744073709551614.rs\n" ++
        "\tnew file:   generated/file_18446744073709551615.rs\n" ++
        "\tnew file:   generated/file_0.rs\n" ++
        "\tnew file:   generated/file_1.rs\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "generated/file_18446744073709551612.rs..") == null);
    try std.testing.expect(std.mem.find(u8, out, "A generated/file_18446744073709551612.rs\n") != null);
}

test "apply: ahead/behind counts preserved" {
    const allocator = std.testing.allocator;
    const input =
        "On branch main\n" ++
        "Your branch is ahead of 'origin/main' by 3 commits.\n" ++
        "  (use \"git push\" to publish your local commits)\n" ++
        "\n" ++
        "nothing to commit, working tree clean\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("# main +3\n", out);
}

test "apply: behind count preserved" {
    const allocator = std.testing.allocator;
    const input =
        "On branch main\n" ++
        "Your branch is behind 'origin/main' by 2 commits, and can be fast-forwarded.\n" ++
        "  (use \"git pull\" to update your local branch)\n" ++
        "\n" ++
        "nothing to commit, working tree clean\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("# main -2\n", out);
}

test "apply: empty input produces empty output" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "apply: pipe-mode idempotence — v0.4 output is not re-filtered (passthrough)" {
    // v0.4 output starts with "# main\n" which does NOT match git_status.matches.
    // Piping v0.4 output through smll again should produce identical output (passthrough).
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, dirty_fixture);
    defer allocator.free(out);
    // Confirm v0.4 output doesn't match pipe-mode filter.
    try std.testing.expect(!matches(out));
    // A second apply on v0.4 output would be a passthrough — verified by matches=false.
}

// ---------------------------------------------------------------------------
// applyShort (porcelain v1 — `git status --short` / `-s`) tests.
// ---------------------------------------------------------------------------

fn applyShortToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try applyShort(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "applyShort: basic dirname RLE on consecutive same-XY entries" {
    const allocator = std.testing.allocator;
    const input =
        " M src/main.zig\n" ++
        " M src/pipeline.zig\n" ++
        " M src/util.zig\n";
    const out = try applyShortToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        " M src/main.zig\n" ++
            " M pipeline.zig\n" ++
            " M util.zig\n",
        out,
    );
}

test "applyShort: XY change breaks the run" {
    const allocator = std.testing.allocator;
    const input =
        " M src/a.zig\n" ++
        "M  src/b.zig\n" ++
        " M src/c.zig\n";
    const out = try applyShortToString(allocator, input);
    defer allocator.free(out);
    // ` M src/a.zig` then `M  src/b.zig` (XY changed → full path) then ` M src/c.zig`
    // (XY changed again → full path).
    try std.testing.expectEqualStrings(
        " M src/a.zig\n" ++
            "M  src/b.zig\n" ++
            " M src/c.zig\n",
        out,
    );
}

test "applyShort: dir change breaks the run" {
    const allocator = std.testing.allocator;
    const input =
        " M src/a.zig\n" ++
        " M tests/b.zig\n";
    const out = try applyShortToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        " M src/a.zig\n" ++
            " M tests/b.zig\n",
        out,
    );
}

test "applyShort: rename entries are emitted verbatim and never grouped" {
    const allocator = std.testing.allocator;
    const input =
        "R  src/old.zig -> src/new.zig\n" ++
        " M src/main.zig\n";
    const out = try applyShortToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "R  src/old.zig -> src/new.zig\n" ++
            " M src/main.zig\n",
        out,
    );
}

test "applyShort: untracked entries compress like any other XY" {
    const allocator = std.testing.allocator;
    const input =
        "?? tests/fixtures/a.txt\n" ++
        "?? tests/fixtures/b.txt\n" ++
        "?? tests/fixtures/c.txt\n";
    const out = try applyShortToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(
        "?? tests/fixtures/a.txt\n" ++
            "?? b.txt\n" ++
            "?? c.txt\n",
        out,
    );
}

test "applyShort: unknown line shape passes through verbatim" {
    const allocator = std.testing.allocator;
    const input =
        " M src/a.zig\n" ++
        "warning: some message\n" ++
        " M src/b.zig\n";
    const out = try applyShortToString(allocator, input);
    defer allocator.free(out);
    // The warning resets the run, so src/b.zig emits its full path again.
    try std.testing.expectEqualStrings(
        " M src/a.zig\n" ++
            "warning: some message\n" ++
            " M src/b.zig\n",
        out,
    );
}

test "applyShort: top-level files (no dirname) never group" {
    const allocator = std.testing.allocator;
    const input =
        " M foo.zig\n" ++
        " M bar.zig\n";
    const out = try applyShortToString(allocator, input);
    defer allocator.free(out);
    // No shared dirname → both emit verbatim.
    try std.testing.expectEqualStrings(
        " M foo.zig\n" ++
            " M bar.zig\n",
        out,
    );
}

test "applyShort: empty input produces empty output" {
    const allocator = std.testing.allocator;
    const out = try applyShortToString(allocator, "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "applyShort: fixture round-trip is strictly smaller and preserves every path" {
    const allocator = std.testing.allocator;
    const out = try applyShortToString(allocator, short_fixture);
    defer allocator.free(out);
    // Every basename in the fixture must remain in the output.
    const paths = [_][]const u8{
        "git_status.zig",             "git_log.zig",      "git_diff.zig",
        "main.zig",                   "pipeline.zig",     "git_reflog.zig",
        "git_status_short.txt",       "git_reflog.txt",   "git_tag.txt",
        "src/old.zig -> src/new.zig", "src/conflict.zig",
    };
    for (paths) |p| {
        try std.testing.expect(std.mem.find(u8, out, p) != null);
    }
    try std.testing.expect(out.len < short_fixture.len);
}
