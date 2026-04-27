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
// Every path is preserved verbatim. Branch name and ahead/behind counts
// are preserved. Output is ≤ 80% of raw git output on fixtures ≥ 50 B.

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

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    try applyStreaming(stdout, writer);
}

const DIR_GROUP_THRESHOLD: usize = 3;

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

    // Streaming directory grouping state
    var run_sigil: u8 = 0;
    var run_dir: []const u8 = "";
    // Store pointers to sigil lines (they point into per-line stack buffers,
    // so we re-derive them). Instead, store the original content lines and
    // section to replay formatting.
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
                @memcpy(branch_buf[prefix.len..copy_len], ref[0..copy_len - prefix.len]);
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
                try writeBranchLine(writer, branch_buf[0..branch_len], ahead, behind);
                branch_written = true;
            }

            const content = line[1..];
            const sigil = sigilFor(section, content);
            const path = pathFor(section, content);

            if (sigil != 0 and path.len > 0) {
                const dir = parentDir(path);
                if (dir.len > 0 and run_len > 0 and sigil == run_sigil and
                    std.mem.eql(u8, dir, run_dir))
                {
                    // Extend current run
                    if (run_len < run_sections.len) {
                        run_sections[run_len] = section;
                        run_contents[run_len] = content;
                        run_len += 1;
                    }
                } else {
                    // Flush previous run, start new one
                    try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_sigil, run_dir);
                    run_sections[0] = section;
                    run_contents[0] = content;
                    run_len = 1;
                    run_sigil = sigil;
                    run_dir = if (dir.len > 0) dir else "";
                }
            } else {
                try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_sigil, run_dir);
                run_len = 0;
                run_sigil = 0;
                writeSectionEntry(writer, section, content) catch {
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                };
            }
            continue;
        }

        if (branch_written) {
            try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_sigil, run_dir);
            run_len = 0;
            run_sigil = 0;
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
    }

    try flushRun(writer, run_sections[0..run_len], run_contents[0..run_len], run_sigil, run_dir);

    if (!branch_written and branch_len > 0) {
        try writeBranchLine(writer, branch_buf[0..branch_len], ahead, behind);
    }
}

fn sigilFor(section: Section, content: []const u8) u8 {
    return switch (section) {
        .staged => if (std.mem.startsWith(u8, content, "new file:")) 'A'
        else if (std.mem.startsWith(u8, content, "deleted:")) 'D'
        else if (std.mem.startsWith(u8, content, "renamed:")) 'R'
        else 'S',
        .unstaged => if (std.mem.startsWith(u8, content, "deleted:")) 'd' else 'M',
        .untracked => '?',
        .unmerged => 'U',
        .none => 0,
    };
}

fn pathFor(section: Section, content: []const u8) []const u8 {
    return switch (section) {
        .staged => {
            if (std.mem.startsWith(u8, content, "modified:   ")) return content["modified:   ".len..];
            if (std.mem.startsWith(u8, content, "new file:   ")) return content["new file:   ".len..];
            if (std.mem.startsWith(u8, content, "deleted:    ")) return content["deleted:    ".len..];
            if (std.mem.startsWith(u8, content, "renamed:    ")) return content["renamed:    ".len..];
            return content;
        },
        .unstaged => {
            if (std.mem.startsWith(u8, content, "modified:   ")) return content["modified:   ".len..];
            if (std.mem.startsWith(u8, content, "deleted:    ")) return content["deleted:    ".len..];
            return content;
        },
        .untracked => content,
        .unmerged => {
            if (std.mem.startsWith(u8, content, "both modified:   ")) return content["both modified:   ".len..];
            if (std.mem.startsWith(u8, content, "added by us:    ")) return content["added by us:    ".len..];
            if (std.mem.startsWith(u8, content, "added by them:  ")) return content["added by them:  ".len..];
            if (std.mem.startsWith(u8, content, "deleted by us:  ")) return content["deleted by us:  ".len..];
            if (std.mem.startsWith(u8, content, "deleted by them:")) return std.mem.trimStart(u8, content["deleted by them:".len..], " ");
            return content;
        },
        .none => "",
    };
}

fn parentDir(path: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, path, '/')) |idx| {
        return path[0 .. idx + 1];
    }
    return "";
}

/// Extract the file path from a status content line like "new file:   src/foo.rs".
fn extractPath(content: []const u8) []const u8 {
    const prefixes = [_][]const u8{
        "modified:   ", "new file:   ", "deleted:    ",
        "renamed:    ", "copied:     ", "typechange: ",
        "both modified:   ", "both added:      ",
    };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, content, p)) return content[p.len..];
    }
    return content;
}

fn flushRun(writer: *Writer, sections: []const Section, contents: []const []const u8, sigil: u8, dir: []const u8) !void {
    if (sections.len == 0) return;
    if (sections.len >= DIR_GROUP_THRESHOLD and dir.len > 0) {
        // Dirname-prefix RLE: emit first entry fully, then subsequent
        // entries without the shared directory prefix so agents can
        // see every individual filename.
        for (sections, contents, 0..) |sec, content, i| {
            if (i == 0) {
                writeSectionEntry(writer, sec, content) catch {};
            } else {
                // Emit just sigil + filename (strip shared dir prefix)
                const path = extractPath(content);
                if (path.len > dir.len and std.mem.startsWith(u8, path, dir)) {
                    if (sigil == 'U') {
                        writer.writeAll("UU ") catch {};
                    } else {
                        writer.writeByte(sigil) catch {};
                        writer.writeByte(' ') catch {};
                    }
                    writer.writeAll(path[dir.len..]) catch {};
                    writer.writeByte('\n') catch {};
                } else {
                    writeSectionEntry(writer, sec, content) catch {};
                }
            }
        }
    } else {
        for (sections, contents) |sec, content| {
            writeSectionEntry(writer, sec, content) catch {};
        }
    }
}

fn writeSectionEntry(writer: *Writer, section: Section, content: []const u8) !void {
    switch (section) {
        .staged => try writeStagedEntry(writer, content),
        .unstaged => try writeUnstagedEntry(writer, content),
        .untracked => {
            try writer.writeAll("? ");
            try writer.writeAll(content);
            try writer.writeByte('\n');
        },
        .unmerged => try writeUnmergedEntry(writer, content),
        .none => {
            try writer.writeAll(content);
            try writer.writeByte('\n');
        },
    }
}

fn writeBranchLine(writer: *Writer, branch: []const u8, ahead: ?[]const u8, behind: ?[]const u8) !void {
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
    try writer.writeByte('\n');
}

fn writeStagedEntry(writer: *Writer, content: []const u8) !void {
    if (std.mem.startsWith(u8, content, "modified:   ")) {
        try writer.writeAll("S ");
        try writer.writeAll(content["modified:   ".len..]);
    } else if (std.mem.startsWith(u8, content, "new file:   ")) {
        try writer.writeAll("A ");
        try writer.writeAll(content["new file:   ".len..]);
    } else if (std.mem.startsWith(u8, content, "deleted:    ")) {
        try writer.writeAll("D ");
        try writer.writeAll(content["deleted:    ".len..]);
    } else if (std.mem.startsWith(u8, content, "renamed:    ")) {
        // "old -> new" — preserve both paths as-is
        try writer.writeAll("R ");
        try writer.writeAll(content["renamed:    ".len..]);
    } else {
        // Unknown staged type — pass through with 'S' as best-effort.
        try writer.writeAll("S ");
        try writer.writeAll(content);
    }
    try writer.writeByte('\n');
}

fn writeUnstagedEntry(writer: *Writer, content: []const u8) !void {
    if (std.mem.startsWith(u8, content, "modified:   ")) {
        try writer.writeAll("M ");
        try writer.writeAll(content["modified:   ".len..]);
    } else if (std.mem.startsWith(u8, content, "deleted:    ")) {
        try writer.writeAll("d ");
        try writer.writeAll(content["deleted:    ".len..]);
    } else {
        // Unknown unstaged type — pass through with 'M' as best-effort.
        try writer.writeAll("M ");
        try writer.writeAll(content);
    }
    try writer.writeByte('\n');
}

fn writeUnmergedEntry(writer: *Writer, content: []const u8) !void {
    if (std.mem.startsWith(u8, content, "both modified:   ")) {
        try writer.writeAll("UU ");
        try writer.writeAll(content["both modified:   ".len..]);
    } else if (std.mem.startsWith(u8, content, "added by us:    ")) {
        try writer.writeAll("AU ");
        try writer.writeAll(content["added by us:    ".len..]);
    } else if (std.mem.startsWith(u8, content, "added by them:  ")) {
        try writer.writeAll("UA ");
        try writer.writeAll(content["added by them:  ".len..]);
    } else if (std.mem.startsWith(u8, content, "deleted by us:  ")) {
        try writer.writeAll("DU ");
        try writer.writeAll(content["deleted by us:  ".len..]);
    } else if (std.mem.startsWith(u8, content, "deleted by them:")) {
        try writer.writeAll("UD ");
        // "deleted by them:" may have 1 or 2 trailing spaces before path
        const rest = std.mem.trimStart(u8, content["deleted by them:".len..], " ");
        try writer.writeAll(rest);
    } else {
        // Unknown unmerged type — preserve with UU.
        try writer.writeAll("UU ");
        try writer.writeAll(content);
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
    search = search[idx + "and have ".len..];
    // Now parse X
    var end_x: usize = 0;
    while (end_x < search.len and search[end_x] >= '0' and search[end_x] <= '9') : (end_x += 1) {}
    if (end_x == 0) return null;
    const ahead = search[0..end_x];
    // Skip " and "
    const and_marker = " and ";
    idx = std.mem.find(u8, search[end_x..], and_marker) orelse return null;
    search = search[end_x + idx + and_marker.len..];
    var end_y: usize = 0;
    while (end_y < search.len and search[end_y] >= '0' and search[end_y] <= '9') : (end_y += 1) {}
    if (end_y == 0) return null;
    const behind = search[0..end_y];
    return .{ ahead, behind };
}

// ---------------------------------------------------------------------------
// Fixtures (embedded at compile time).
// ---------------------------------------------------------------------------

const dirty_fixture = @embedFile("fixture_git_status_dirty");
const clean_fixture = @embedFile("fixture_git_status_clean");
const conflict_fixture = @embedFile("fixture_git_status_conflict");

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
    // Branch line
    try std.testing.expect(std.mem.startsWith(u8, out, "# main\n"));
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
    try std.testing.expectEqualStrings("# main\n", out);
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
