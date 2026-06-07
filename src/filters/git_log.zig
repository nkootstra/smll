const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ansi = @import("ansi");
const util = @import("util");

// v0.5 grammar for `git log`:
//
//   c <sha7> <YYYY-MM-DD> <author>   — full commit header (first, or author changed)
//   c <sha7> <YYYY-MM-DD>            — author inherited from last-emitted c header
//   c <sha7>                         — date + author both inherited
//   p <sha7> <sha7>...               — parent SHAs for merge commits (from Merge: line)
//   : <subject/body line>            — every subject and body line (4-space indent stripped)
//
// RLE elision (v0.5): consecutive commits from the same author share ink by
// dropping <author> and, if also same date, <date> from subsequent c headers.
// Parser inherits forward from the most recent c header that carried the field.
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

/// Default pipe-mode and wrapper-mode apply: verbose format with bodies.
pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    try applyInner(stdout, writer);
}

/// v0.6 default for wrapper mode: emit `<sha7> <subject>` one line per commit.
/// Drops date, author, merge parents, and prose body lines. The hash remains
/// actionable (`git show <sha7>`), while important trailers such as `Refs:` and
/// `Fixes:` are kept inline because agents often use them to connect commits to
/// issues/tasks.
pub fn applyCompact(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var current: CompactCommit = .{};
    var first_out = true;

    while (lines.next()) |line| {
        if (isCommitLine(line)) {
            try flushCompactCommit(writer, &current, &first_out);
            current = .{};
            current.sha7 = util.sha7(line["commit ".len..][0..40]);
            current.has_sha = true;
            continue;
        }

        if (!current.has_sha or !std.mem.startsWith(u8, line, "    ")) continue;
        const body_line = std.mem.trim(u8, line[4..], " \t\r");
        if (body_line.len == 0) continue;
        if (current.subject_len == 0) {
            current.copySubject(body_line);
        } else if (isImportantCompactBodyLine(body_line)) {
            current.appendImportant(body_line);
        }
    }
    try flushCompactCommit(writer, &current, &first_out);
    if (!first_out) try writer.writeByte('\n');
}

/// Compact header format for commands such as `git show`, where commit body
/// text is adjacent to a diff and can be important review context.
pub fn applyCompactWithBody(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var sha7: [7]u8 = undefined;
    var sha7_valid = false;
    var subject_emitted = false;
    var in_body = false;
    var first_out = true;

    while (lines.next()) |line| {
        if (isCommitLine(line)) {
            sha7 = util.sha7(line["commit ".len..][0..40]);
            sha7_valid = true;
            subject_emitted = false;
            in_body = false;
            continue;
        }
        if (!sha7_valid) continue;
        if (!subject_emitted) {
            if (!std.mem.startsWith(u8, line, "    ")) continue;
            const subject = std.mem.trim(u8, line[4..], " \t\r");
            if (subject.len == 0) continue;
            if (!first_out) try writer.writeByte('\n');
            try writer.writeAll(&sha7);
            try writer.writeByte(' ');
            try writer.writeAll(subject);
            first_out = false;
            subject_emitted = true;
            in_body = true;
            continue;
        }
        if (in_body and std.mem.startsWith(u8, line, "    ")) {
            const body_line = std.mem.trim(u8, line[4..], " \t\r");
            if (body_line.len > 0) {
                try writer.writeByte('\n');
                try writer.writeAll("  ");
                try writer.writeAll(body_line);
            }
        } else if (line.len == 0 and in_body) {
            // Blank line between subject and body — skip.
        } else {
            in_body = false;
        }
    }
    if (!first_out) try writer.writeByte('\n');
}

/// Compact `git log --stat` / `--shortstat` while keeping the reviewable facts:
/// short commit id, subject, important trailers, representative file/path
/// signal, and the final changed-files summary.
pub fn applyStatCompact(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var current: StatCommit = .{};
    defer current.deinit(allocator);
    var first_out = true;

    while (lines.next()) |line| {
        if (isCommitLine(line)) {
            try flushStatCommit(writer, &current, &first_out);
            current.deinit(allocator);
            current = .{};
            current.header.sha7 = util.sha7(line["commit ".len..][0..40]);
            current.header.has_sha = true;
            continue;
        }

        if (!current.header.has_sha) continue;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (isStatSummaryLine(trimmed)) {
            current.summary = trimmed;
            continue;
        }

        if (parseStatLine(trimmed)) |stat_line| {
            try current.stat_lines.append(allocator, stat_line);
            continue;
        }

        if (std.mem.startsWith(u8, line, "    ")) {
            const body_line = std.mem.trim(u8, line[4..], " \t\r");
            if (body_line.len == 0) continue;
            if (current.header.subject_len == 0) {
                current.header.copySubject(body_line);
            } else if (isImportantCompactBodyLine(body_line)) {
                current.header.appendImportant(body_line);
            }
        }
    }

    try flushStatCommit(writer, &current, &first_out);
    if (!first_out) try writer.writeByte('\n');
}

const CompactCommit = struct {
    has_sha: bool = false,
    sha7: [7]u8 = undefined,
    subject: [512]u8 = undefined,
    subject_len: usize = 0,
    important: [768]u8 = undefined,
    important_len: usize = 0,

    fn copySubject(self: *CompactCommit, subject: []const u8) void {
        self.subject_len = @min(subject.len, self.subject.len);
        @memcpy(self.subject[0..self.subject_len], subject[0..self.subject_len]);
    }

    fn appendImportant(self: *CompactCommit, line: []const u8) void {
        const sep = if (self.important_len == 0) "" else "; ";
        if (self.important_len + sep.len >= self.important.len) return;
        @memcpy(self.important[self.important_len .. self.important_len + sep.len], sep);
        self.important_len += sep.len;

        const room = self.important.len - self.important_len;
        const n = @min(line.len, room);
        @memcpy(self.important[self.important_len .. self.important_len + n], line[0..n]);
        self.important_len += n;
    }
};

const StatLine = struct {
    raw: []const u8,
    parent: []const u8,
    insertions: usize = 0,
    deletions: usize = 0,
    keep_raw: bool = false,
};

const StatCommit = struct {
    header: CompactCommit = .{},
    stat_lines: std.ArrayList(StatLine) = .empty,
    summary: ?[]const u8 = null,

    fn deinit(self: *StatCommit, allocator: Allocator) void {
        self.stat_lines.deinit(allocator);
    }
};

fn flushStatCommit(writer: *Writer, commit: *const StatCommit, first_out: *bool) !void {
    if (!commit.header.has_sha or commit.header.subject_len == 0) return;

    if (!first_out.*) try writer.writeByte('\n');
    try writer.writeAll(&commit.header.sha7);
    try writer.writeByte(' ');
    try writer.writeAll(commit.header.subject[0..commit.header.subject_len]);
    if (commit.header.important_len > 0) {
        try writer.writeAll(" [");
        try writer.writeAll(commit.header.important[0..commit.header.important_len]);
        try writer.writeByte(']');
    }
    first_out.* = false;

    if (commit.stat_lines.items.len <= 5) {
        for (commit.stat_lines.items) |line| try writeIndentedStatLine(writer, first_out, line.raw);
    } else {
        try writeGroupedStatLines(writer, first_out, commit.stat_lines.items);
    }

    if (commit.summary) |summary| {
        try writeIndentedStatLine(writer, first_out, summary);
    }
}

fn flushCompactCommit(writer: *Writer, commit: *const CompactCommit, first_out: *bool) !void {
    if (!commit.has_sha or commit.subject_len == 0) return;
    if (!first_out.*) try writer.writeByte('\n');
    try writer.writeAll(&commit.sha7);
    try writer.writeByte(' ');
    try writer.writeAll(commit.subject[0..commit.subject_len]);
    if (commit.important_len > 0) {
        try writer.writeAll(" [");
        try writer.writeAll(commit.important[0..commit.important_len]);
        try writer.writeByte(']');
    }
    first_out.* = false;
}

fn writeGroupedStatLines(writer: *Writer, first_out: *bool, lines: []const StatLine) !void {
    var i: usize = 0;
    while (i < lines.len) {
        if (lines[i].keep_raw) {
            try writeIndentedStatLine(writer, first_out, lines[i].raw);
            i += 1;
            continue;
        }

        const parent = lines[i].parent;
        var end = i + 1;
        var insertions: usize = lines[i].insertions;
        var deletions: usize = lines[i].deletions;
        while (end < lines.len and !lines[end].keep_raw and std.mem.eql(u8, lines[end].parent, parent)) : (end += 1) {
            insertions += lines[end].insertions;
            deletions += lines[end].deletions;
        }

        const count = end - i;
        if (count >= 3) {
            try writeCollapsedStatGroup(writer, first_out, parent, count, insertions, deletions);
        } else {
            for (lines[i..end]) |line| try writeIndentedStatLine(writer, first_out, line.raw);
        }
        i = end;
    }
}

fn writeCollapsedStatGroup(
    writer: *Writer,
    first_out: *bool,
    parent: []const u8,
    count: usize,
    insertions: usize,
    deletions: usize,
) !void {
    if (!first_out.*) try writer.writeByte('\n');
    try writer.writeAll("  ");
    if (std.mem.eql(u8, parent, ".")) {
        try writer.writeAll("./");
    } else {
        try writer.writeAll(parent);
        if (!std.mem.endsWith(u8, parent, "/")) try writer.writeByte('/');
    }
    try writer.writeAll(" (");
    try ansi.writeDecimal(writer, count);
    try writer.writeAll(" files, +");
    try ansi.writeDecimal(writer, insertions);
    try writer.writeAll(" -");
    try ansi.writeDecimal(writer, deletions);
    try writer.writeByte(')');
    first_out.* = false;
}

fn writeIndentedStatLine(writer: *Writer, first_out: *bool, line: []const u8) !void {
    if (!first_out.*) try writer.writeByte('\n');
    try writer.writeAll("  ");
    try writer.writeAll(line);
    first_out.* = false;
}

fn isImportantCompactBodyLine(line: []const u8) bool {
    const prefixes = [_][]const u8{
        "Refs:",
        "Ref:",
        "Fixes:",
        "Closes:",
        "Resolves:",
        "Related:",
        "Issue:",
        "BREAKING CHANGE",
        "Co-authored-by:",
        "Signed-off-by:",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

fn isPerFileStatLine(line: []const u8) bool {
    return parseStatLine(line) != null;
}

fn parseStatLine(line: []const u8) ?StatLine {
    const pipe = std.mem.indexOfScalar(u8, line, '|') orelse return null;
    const path = std.mem.trim(u8, line[0..pipe], " \t");
    const after = std.mem.trim(u8, line[pipe + 1 ..], " \t");
    if (path.len == 0 or after.len == 0) return null;

    if (std.mem.startsWith(u8, after, "Bin ")) {
        return .{
            .raw = line,
            .parent = parentDir(path),
            .keep_raw = true,
        };
    }

    if (!std.ascii.isDigit(after[0])) return null;
    if (parseLeadingUsize(after) == null) return null;

    const keep_raw = hasRenameSyntax(path);
    return .{
        .raw = line,
        .parent = parentDir(path),
        .insertions = countByte(after, '+'),
        .deletions = countByte(after, '-'),
        .keep_raw = keep_raw,
    };
}

fn hasRenameSyntax(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "=>") != null or
        (std.mem.indexOfScalar(u8, path, '{') != null and std.mem.indexOfScalar(u8, path, '}') != null);
}

fn parentDir(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/') {
            if (i == 0) return ".";
            return path[0..i];
        }
    }
    return ".";
}

fn parseLeadingUsize(s: []const u8) ?usize {
    var value: usize = 0;
    var i: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        value = value * 10 + (s[i] - '0');
    }
    return if (i == 0) null else value;
}

fn countByte(s: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (s) |c| {
        if (c == needle) count += 1;
    }
    return count;
}

fn isStatSummaryLine(line: []const u8) bool {
    return std.mem.find(u8, line, " file changed") != null or
        std.mem.find(u8, line, " files changed") != null;
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

    // RLE state across commits: remember last-emitted date and author so subsequent
    // c headers can elide unchanged fields. `first_header` forces the first header
    // to emit both fields even if the parsed values happen to equal the zero-init.
    var rle_state: CRleState = .{};

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
            const email_start = std.mem.find(u8, author_rest, " <") orelse author_rest.len;
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
                    try writeCLine(writer, &sha7, &date_buf, date_valid, author_buf[0..author_len], &rle_state);
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
                try writeCLine(writer, &sha7, &date_buf, date_valid, author_buf[0..author_len], &rle_state);
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

/// State carried across commits in a single apply() call for RLE elision
/// of unchanged <date> and <author> fields on c headers.
const CRleState = struct {
    last_date: [10]u8 = undefined,
    last_date_valid: bool = false,
    last_author: [128]u8 = undefined,
    last_author_len: usize = 0,
    first_header: bool = true,
};

fn writeCLine(
    writer: *Writer,
    sha7: *const [7]u8,
    date_buf: *const [10]u8,
    date_valid: bool,
    author: []const u8,
    rle: *CRleState,
) !void {
    try writer.writeAll("c ");
    try writer.writeAll(sha7);

    // Elide author when unchanged from last-emitted. Elide date when author
    // also elided AND date unchanged. Date is always emitted when author is,
    // so the parser can positionally disambiguate `c <sha>` from `c <sha> <date>`
    // from `c <sha> <date> <author>` by token count.
    const author_changed = !std.mem.eql(u8, author, rle.last_author[0..rle.last_author_len]);
    const date_changed = blk: {
        if (date_valid != rle.last_date_valid) break :blk true;
        if (!date_valid) break :blk false;
        break :blk !std.mem.eql(u8, date_buf, &rle.last_date);
    };
    const emit_author = rle.first_header or author_changed;
    const emit_date = emit_author or date_changed;

    if (emit_date) {
        try writer.writeByte(' ');
        if (date_valid) {
            try writer.writeAll(date_buf);
            @memcpy(&rle.last_date, date_buf);
        } else {
            try writer.writeAll("0000-00-00");
        }
        rle.last_date_valid = date_valid;
    }
    if (emit_author) {
        try writer.writeByte(' ');
        try writer.writeAll(author);
        const n = @min(author.len, rle.last_author.len);
        @memcpy(rle.last_author[0..n], author[0..n]);
        rle.last_author_len = n;
    }
    rle.first_header = false;
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
    const day = parseU8(day_str) orelse return false;
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

fn parseU8(s: []const u8) ?u8 {
    if (s.len == 0 or s.len > 3) return null;
    var v: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return if (v <= 255) @intCast(v) else null;
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
const stat_fixture = @embedFile("fixture_git_log_stat");

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

test "apply: emits c sigil with sha7, date, author on linear (first commit full)" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    // First commit: full header.
    try std.testing.expect(std.mem.find(u8, out, "c f0ad49e 2026-04-18 Alice Anderson\n") != null);
    // Subsequent same-author/same-date commits: v0.5 RLE elides author+date → sha only.
    try std.testing.expect(std.mem.find(u8, out, "c f666a84\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "c 95cbeda\n") != null);
    // No full SHAs
    try std.testing.expect(std.mem.find(u8, out, "f0ad49edaad09b3977b23cc38c5552c76734c2de") == null);
}

test "apply: no commit/Author/Date labels in output" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "commit ") == null);
    try std.testing.expect(std.mem.find(u8, out, "Author:") == null);
    try std.testing.expect(std.mem.find(u8, out, "Date:") == null);
    try std.testing.expect(std.mem.find(u8, out, "@example.com") == null);
}

test "apply: emits : sigil for every body line on linear" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, ": fix: third line\n") != null);
    try std.testing.expect(std.mem.find(u8, out, ": feat: extend a.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out, ": feat: add a.txt with one line\n") != null);
}

test "apply: preserves multi-line commit body verbatim under : sigil" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, linear_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, ": This body explains why we added a second line.\n") != null);
    try std.testing.expect(std.mem.find(u8, out, ": It spans multiple lines and contains punctuation.\n") != null);
}

test "apply: emits p sigil for merge parents on merge fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "p 50c52b3 cb42c80\n") != null);
}

test "apply: emits c sigils for all commits on merge fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, merge_fixture);
    defer allocator.free(out);
    // First commit: full header.
    try std.testing.expect(std.mem.find(u8, out, "c 012aa35 2026-04-18 Alice Anderson\n") != null);
    // Subsequent same-author/same-date commits: v0.5 RLE elides author+date → sha only.
    try std.testing.expect(std.mem.find(u8, out, "c 50c52b3\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "c cb42c80\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "c f0ad49e\n") != null);
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

test "applyCompact: emits sha7 + subject, drops date/author/prose body" {
    const allocator = std.testing.allocator;
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try applyCompact(allocator, linear_fixture, &.{}, &out.writer);
    const got = out.written();
    // Hash + subject on a single line, no `c ` prefix, no date, no author.
    try std.testing.expect(std.mem.find(u8, got, "f0ad49e fix: third line") != null);
    try std.testing.expect(std.mem.find(u8, got, "f666a84 feat: extend a.txt") != null);
    try std.testing.expect(std.mem.find(u8, got, "95cbeda feat: add a.txt with one line") != null);
    // Date + author stripped
    try std.testing.expect(std.mem.find(u8, got, "2026-04-18") == null);
    try std.testing.expect(std.mem.find(u8, got, "Alice Anderson") == null);
    // Prose body is intentionally dropped in wrapper mode; the hash is the
    // actionable handle for detail (`git show <sha7>`).
    try std.testing.expect(std.mem.find(u8, got, "This body explains") == null);
    // Strictly smaller than default apply
    const lossless = try applyToString(allocator, linear_fixture);
    defer allocator.free(lossless);
    try std.testing.expect(got.len < lossless.len);
}

test "applyCompact: preserves important commit trailers inline" {
    const allocator = std.testing.allocator;
    const input =
        "commit abcdef0123456789abcdef0123456789abcdef01\n" ++
        "Author: Alice <a@example.com>\n" ++
        "Date:   Sat Apr 18 09:00:00 2026 +0000\n" ++
        "\n" ++
        "    feat: group status output\n" ++
        "\n" ++
        "    This paragraph is useful in a release note but noisy in an agent trace.\n" ++
        "    Refs: BENCH-42\n" ++
        "    Fixes: #123\n";
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try applyCompact(allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "abcdef0 feat: group status output [Refs: BENCH-42; Fixes: #123]\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "release note") == null);
}

test "applyStatCompact: keeps stat facts and drops scaffolding" {
    const allocator = std.testing.allocator;
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try applyStatCompact(allocator, stat_fixture, &.{}, &out.writer);
    const got = out.written();

    try std.testing.expect(std.mem.find(u8, got, "abcdef0 round 8 updates") != null);
    try std.testing.expect(std.mem.find(u8, got, "b2c3d4e fix: keep count summaries") != null);
    try std.testing.expect(std.mem.find(u8, got, "docs/guides/release_08.md") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/core/ (6 files, +30 -0)") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/ui/ (6 files, +30 -0)") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/{old_name.zig => name.zig}") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/filters/git_log.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/wrapper_git.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "14 files changed") != null);
    try std.testing.expect(std.mem.find(u8, got, "2 files changed") != null);
    try std.testing.expect(std.mem.find(u8, got, "Refs: SMLL-42") != null);
    try std.testing.expect(std.mem.find(u8, got, "Fixes: #123") != null);
    try std.testing.expect(std.mem.find(u8, got, "BREAKING CHANGE: count lines stay visible") != null);
    try std.testing.expect(std.mem.find(u8, got, "Author:") == null);
    try std.testing.expect(std.mem.find(u8, got, "Date:") == null);
    try std.testing.expect(std.mem.find(u8, got, "abcdef0123456789abcdef0123456789abcdef01") == null);
    try std.testing.expect(std.mem.find(u8, got, "Cache parse trees") == null);
}

test "applyStatCompact: stat fixture is ≤ 45% of raw" {
    const allocator = std.testing.allocator;
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try applyStatCompact(allocator, stat_fixture, &.{}, &out.writer);
    try std.testing.expect(out.written().len <= (stat_fixture.len * 45) / 100);
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
    try std.testing.expect(std.mem.find(u8, out, "c abcdef0 2026-04-18 Just A Name\n") != null);
}

test "apply: malformed Date falls back to 0000-00-00" {
    const allocator = std.testing.allocator;
    const input = "commit abcdef0123456789abcdef0123456789abcdef01\nAuthor: n <n@n>\nDate:   garbage\n\n    subject\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "c abcdef0 0000-00-00 n\n") != null);
}
