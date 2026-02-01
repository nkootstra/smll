const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// v0.4 grammar for `git log`:
//
//   c <sha7> <YYYY-MM-DD> <author>   — commit header (SHA truncated to 7, ISO date, name only)
//   p <sha7> <sha7>...               — parent SHAs for merge commits (from Merge: line)
//   : <subject/body line>            — every subject and body line (4-space indent stripped)
//
// Dropped:
//   "commit " prefix + full SHA      (replaced by c <sha7>)
//   "Author: " label                 (name+date in c line)
//   "Author: " email domain          (email noise — only name kept in c line)
//   "Date: " label + verbose format  (replaced by YYYY-MM-DD in c line)
//   "Merge: " label                  (replaced by p sigil)
//   blank lines between commits      (c header provides the separation)
//   blank line between header and body (structural scaffolding)
//
// Preserved:
//   full 7-char SHA prefix, YYYY-MM-DD date, author name (R2)
//   every subject line, every body line verbatim (R2)
//   blank lines within commit body (emitted as ":" to preserve paragraph structure)
//   parent SHAs for merge commits (R2)

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return isCommitLine(line);
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    try applyInner(stdout, writer);
}

fn applyInner(input: []const u8, writer: *Writer) !void {
    if (input.len == 0) return;

    const had_trailing_newline = input[input.len - 1] == '\n';
    const content = if (had_trailing_newline) input[0 .. input.len - 1] else input;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first_out = true;

    // Per-commit buffered header fields.
    // We collect all header fields before emitting the c line, because
    // Author and Date follow the commit SHA line, and Merge: may appear
    // between them. We flush (emit c + optional p) on the first body line
    // or on the blank line that transitions header→body.
    var sha7: [7]u8 = undefined;
    var sha7_valid = false;
    var date_buf: [10]u8 = undefined; // YYYY-MM-DD
    var date_valid = false;
    var author_buf: [128]u8 = undefined;
    var author_len: usize = 0;
    var merge_parents: [128]u8 = undefined; // "sha7 sha7 ..." from Merge: line
    var merge_parents_len: usize = 0;
    var c_line_emitted = false;
    var in_body = false;

    while (lines.next()) |line| {
        if (isCommitLine(line)) {
            // New commit: reset all per-commit state.
            sha7_valid = false;
            date_valid = false;
            author_len = 0;
            merge_parents_len = 0;
            c_line_emitted = false;
            in_body = false;

            const sha_start = "commit ".len;
            const sha_all = line[sha_start..][0..40];
            sha7 = util.sha7(sha_all);
            sha7_valid = true;
            continue;
        }

        if (std.mem.startsWith(u8, line, "Merge: ")) {
            // Buffer merge parents — emit after c line
            const parents = line["Merge: ".len..];
            merge_parents_len = @min(parents.len, merge_parents.len);
            @memcpy(merge_parents[0..merge_parents_len], parents[0..merge_parents_len]);
            continue;
        }

        if (std.mem.startsWith(u8, line, "Author: ")) {
            const author_rest = line["Author: ".len..];
            const email_start = std.mem.indexOf(u8, author_rest, " <") orelse author_rest.len;
            const name = author_rest[0..email_start];
            author_len = @min(name.len, author_buf.len);
            @memcpy(author_buf[0..author_len], name[0..author_len]);
            continue;
        }

        if (std.mem.startsWith(u8, line, "Date:")) {
            date_valid = parseDate(line, &date_buf);
            continue;
        }

        // Blank line handling
        if (std.mem.trim(u8, line, " \t").len == 0) {
            if (!in_body) {
                // Blank line after header fields: flush c + p, transition to body.
                if (!c_line_emitted and sha7_valid) {
                    if (!first_out) try writer.writeByte('\n');
                    try writeCLine(writer, &sha7, &date_buf, date_valid, author_buf[0..author_len]);
                    first_out = false;
                    c_line_emitted = true;
                    if (merge_parents_len > 0) {
                        try writer.writeByte('\n');
                        try writer.writeAll("p ");
                        try writer.writeAll(merge_parents[0..merge_parents_len]);
                    }
                }
                in_body = true;
                // Drop the header-to-body blank line
            }
            // Body blank lines: drop (inter-commit blanks and intra-body paragraph blanks
            // are dropped; the c sigil of the next commit provides separation).
            continue;
        }

        // Body lines: prefixed with 4 spaces in git log output
        if (std.mem.startsWith(u8, line, "    ")) {
            // Flush c + p if not yet emitted (handles case with no blank separator)
            if (!c_line_emitted and sha7_valid) {
                if (!first_out) try writer.writeByte('\n');
                try writeCLine(writer, &sha7, &date_buf, date_valid, author_buf[0..author_len]);
                first_out = false;
                c_line_emitted = true;
                if (merge_parents_len > 0) {
                    try writer.writeByte('\n');
                    try writer.writeAll("p ");
                    try writer.writeAll(merge_parents[0..merge_parents_len]);
                }
            }
            in_body = true;
            if (!first_out) try writer.writeByte('\n');
            try writer.writeAll(": ");
            try writer.writeAll(line[4..]); // strip 4-space indent
            first_out = false;
            continue;
        }

        // Unknown line in header section: drop
        if (!in_body) continue;

        // Unknown line in body: pass through
        if (!first_out) try writer.writeByte('\n');
        try writer.writeAll(line);
        first_out = false;
    }

    if (had_trailing_newline and !first_out) try writer.writeByte('\n');
}

fn writeCLine(writer: *Writer, sha7: *const [7]u8, date_buf: *const [10]u8, date_valid: bool, author: []const u8) !void {
    try writer.writeAll("c ");
    try writer.writeAll(sha7);
    try writer.writeByte(' ');
    if (date_valid) {
        try writer.writeAll(date_buf);
    } else {
        try writer.writeAll("0000-00-00");
    }
    try writer.writeByte(' ');
    try writer.writeAll(author);
}

/// Parse "Date:   Day Mon DD HH:MM:SS YYYY +ZONE" → "YYYY-MM-DD" into buf[0..10].
/// Returns true on success.
fn parseDate(line: []const u8, buf: *[10]u8) bool {
    var prefix_end: usize = "Date:".len;
    while (prefix_end < line.len and (line[prefix_end] == ' ' or line[prefix_end] == '\t')) {
        prefix_end += 1;
    }
    const rest = line[prefix_end..];
    var it = std.mem.tokenizeAny(u8, rest, " \t");
    _ = it.next() orelse return false; // day-of-week
    const month_abbr = it.next() orelse return false;
    const day_str = it.next() orelse return false;
    _ = it.next() orelse return false; // time HH:MM:SS
    const year_str = it.next() orelse return false;

    const month = monthNumber(month_abbr) orelse return false;
    const day = std.fmt.parseInt(u8, day_str, 10) catch return false;
    if (day < 1 or day > 31) return false;
    if (year_str.len != 4) return false;
    for (year_str) |c| if (!std.ascii.isDigit(c)) return false;

    buf[0] = year_str[0];
    buf[1] = year_str[1];
    buf[2] = year_str[2];
    buf[3] = year_str[3];
    buf[4] = '-';
    buf[5] = '0' + month / 10;
    buf[6] = '0' + month % 10;
    buf[7] = '-';
    buf[8] = '0' + day / 10;
    buf[9] = '0' + day % 10;
    return true;
}

fn monthNumber(abbr: []const u8) ?u8 {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (months, 0..) |m, i| {
        if (std.mem.eql(u8, abbr, m)) return @intCast(i + 1);
    }
    return null;
}

fn isCommitLine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "commit ")) return false;
    if (line.len < 7 + 40) return false;
    if (!util.isHex40(line[7..][0..40])) return false;
    if (line.len > 7 + 40) {
        const c = line[7 + 40];
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

const linear_fixture = @embedFile("fixture_git_log_linear");
const merge_fixture = @embedFile("fixture_git_log_merge");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: linear fixture" {
    try std.testing.expect(matches(linear_fixture));
}

test "matches: merge fixture" {
    try std.testing.expect(matches(merge_fixture));
}

test "matches: leading blank lines are skipped" {
    try std.testing.expect(matches("\n\ncommit abcdef0123456789abcdef0123456789abcdef01\n"));
}

test "matches: non-log input returns false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("On branch main\n"));
    try std.testing.expect(!matches("diff --git a/x b/x\n"));
    try std.testing.expect(!matches("commit short\n"));
    try std.testing.expect(!matches("commit g0ad49edaad09b3977b23cc38c5552c76734c2de\n"));
}

test "apply: emits c sigil with sha7, date, author on linear" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "c f0ad49e 2026-04-18 Alice Anderson\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "c f666a84 2026-04-18 Alice Anderson\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "c 95cbeda 2026-04-18 Alice Anderson\n") != null);
    // No full SHAs
    try std.testing.expect(std.mem.indexOf(u8, out, "f0ad49edaad09b3977b23cc38c5552c76734c2de") == null);
}

test "apply: no commit/Author/Date labels in output" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "commit ") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Author:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Date:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "@example.com") == null);
}

test "apply: emits : sigil for every body line on linear" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ": fix: third line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ": feat: extend a.txt\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ": feat: add a.txt with one line\n") != null);
}

test "apply: preserves multi-line commit body verbatim under : sigil" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, ": This body explains why we added a second line.\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ": It spans multiple lines and contains punctuation.\n") != null);
}

test "apply: emits p sigil for merge parents on merge fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "p 50c52b3 cb42c80\n") != null);
}

test "apply: emits c sigils for all commits on merge fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "c 012aa35 2026-04-18 Alice Anderson\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "c 50c52b3 2026-04-18 Alice Anderson\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "c cb42c80 2026-04-18 Alice Anderson\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "c f0ad49e 2026-04-18 Alice Anderson\n") != null);
}

test "apply: directional compression on linear fixture (byte count)" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < linear_fixture.len);
}

test "apply: directional compression on merge fixture (byte count)" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < merge_fixture.len);
}

test "apply: R3 gate — linear fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    const target = (linear_fixture.len * 80) / 100;
    try std.testing.expect(out.len <= target);
}

test "apply: R3 gate — merge fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    const target = (merge_fixture.len * 80) / 100;
    try std.testing.expect(out.len <= target);
}

test "apply: preserves trailing newline when input has one" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len > 0 and out[out.len - 1] == '\n');
}

test "pipe-mode idempotence: v0.4 log output piped again is unchanged" {
    // v0.4 log output starts with "c <sha7> ..." — does NOT match matches()
    // (which requires "commit " + 40-char hex SHA). So smll passes it through.
    const allocator = std.testing.allocator;
    const first = try applyToString(allocator, linear_fixture);
    defer allocator.free(first);
    try std.testing.expect(!matches(first));
}

test "apply: author without email angle bracket passes through name" {
    const allocator = std.testing.allocator;
    const input = "commit abcdef0123456789abcdef0123456789abcdef01\nAuthor: Just A Name\nDate:   Sat Apr 18 09:00:00 2026 +0000\n\n    subject\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "c abcdef0 2026-04-18 Just A Name\n") != null);
}

test "apply: malformed Date falls back to 0000-00-00" {
    const allocator = std.testing.allocator;
    const input = "commit abcdef0123456789abcdef0123456789abcdef01\nAuthor: n <n@n>\nDate:   garbage\n\n    subject\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "c abcdef0 0000-00-00 n\n") != null);
}
