const std = @import("std");
const ansi = @import("ansi");
const columnar = @import("columnar");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Shape = enum {
    none,
    table,
    view,
};

/// Return true for recognized Atlassian CLI Jira/Confluence text output.
pub fn matches(input: []const u8) bool {
    return detectShape(input) != .none;
}

/// Compact recognized Atlassian CLI output while preserving actionable fields.
pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    switch (detectShape(stdout)) {
        .table => try columnar.applyGeneric(allocator, stdout, &.{}, writer),
        .view => try applyView(allocator, stdout, writer),
        .none => try writer.writeAll(stdout),
    }
}

fn detectShape(input: []const u8) Shape {
    if (input.len == 0) return .none;
    if (isKnownTable(input)) return .table;
    if (isKnownView(input)) return .view;
    return .none;
}

fn isKnownTable(input: []const u8) bool {
    if (!columnar.matchesGeneric(input)) return false;
    if (hasJiraKey(input) and
        hasIgnore(input, "KEY") and
        hasIgnore(input, "SUMMARY") and
        (hasIgnore(input, "ASSIGNEE") or hasIgnore(input, "STATUS")))
    {
        return true;
    }
    return (hasIgnore(input, "KEY") or hasIgnore(input, "ID")) and
        (hasIgnore(input, "NAME") or hasIgnore(input, "TITLE")) and
        (hasIgnore(input, "SPACE") or hasIgnore(input, "HOMEPAGE") or hasIgnore(input, "STATUS"));
}

fn isKnownView(input: []const u8) bool {
    var actionable_lines: usize = 0;
    var saw_jira = false;
    var saw_confluence = false;

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (hasJiraKey(line) or startsWithAnyIgnore(line, &.{ "Key:", "Work item:", "Issue:" })) saw_jira = true;
        if (startsWithAnyIgnore(line, &.{ "ID:", "Title:", "Space:", "Version:" }) or hasIgnore(line, "/wiki/")) saw_confluence = true;
        if (isActionableViewLine(line)) actionable_lines += 1;
    }

    return actionable_lines >= 4 and (saw_jira or saw_confluence);
}

fn applyView(allocator: Allocator, stdout: []const u8, writer: *Writer) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    var kept: usize = 0;
    var keep_next_body_line = false;
    var in_fields_section = false;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;

        if (isActionableViewLine(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            kept += 1;
            if (startsWithAnyIgnore(line, &.{"Fields:"})) in_fields_section = true;
            if (startsWithAnyIgnore(line, &.{ "Description:", "Body:", "Comments:" })) in_fields_section = false;
            keep_next_body_line = isBodySectionLabel(line);
            continue;
        }

        if ((in_fields_section or isLikelyCustomFieldLine(line)) and looksLikeSectionLabel(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            kept += 1;
            keep_next_body_line = line[line.len - 1] == ':';
            continue;
        }

        if (keep_next_body_line and !looksLikeSectionLabel(line)) {
            try writer.writeAll("  ");
            try writer.writeAll(line);
            try writer.writeByte('\n');
            kept += 1;
            keep_next_body_line = false;
        }
    }

    if (kept == 0) try writer.writeAll(stdout);
}

fn isActionableViewLine(line: []const u8) bool {
    if (hasJiraKey(line)) return true;
    if (hasIgnore(line, "https://")) return true;
    if (hasIgnore(line, "error") or hasIgnore(line, "warning") or hasIgnore(line, "failed")) return true;
    return startsWithAnyIgnore(line, &.{
        "Key:",
        "Work item:",
        "Issue:",
        "Type:",
        "Summary:",
        "Status:",
        "Assignee:",
        "Priority:",
        "Reporter:",
        "Created:",
        "Updated:",
        "URL:",
        "Web URL:",
        "Description:",
        "Comments:",
        "ID:",
        "Title:",
        "Space:",
        "Author:",
        "Created by:",
        "Last updated:",
        "Version:",
        "Labels:",
        "Body:",
        "Fields:",
    });
}

fn isBodySectionLabel(line: []const u8) bool {
    return startsWithAnyIgnore(line, &.{ "Description:", "Body:", "Comments:" }) and line[line.len - 1] == ':';
}

fn looksLikeSectionLabel(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    if (colon == 0 or colon > 48) return false;
    for (line[0..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == ' ' or c == '-' or c == '_' or c == '/' or c == '&' or c == '(' or c == ')')) return false;
    }
    return true;
}

fn isLikelyCustomFieldLine(line: []const u8) bool {
    if (!looksLikeSectionLabel(line)) return false;
    if (startsWithAnyIgnore(line, &.{ "http:", "https:" })) return false;
    return true;
}

fn hasJiraKey(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (!std.ascii.isUpper(input[i])) continue;
        const start = i;
        while (i < input.len and (std.ascii.isUpper(input[i]) or std.ascii.isDigit(input[i]))) : (i += 1) {}
        if (i == start or i >= input.len or input[i] != '-') continue;
        if (i - start < 2) continue;
        i += 1;
        const digit_start = i;
        while (i < input.len and std.ascii.isDigit(input[i])) : (i += 1) {}
        if (i > digit_start) return true;
    }
    return false;
}

fn hasIgnore(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn startsWithAnyIgnore(line: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(line, prefix)) return true;
    }
    return false;
}

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches Jira work item search table" {
    const fixture = @embedFile("fixture_acli_jira_workitem_search");
    try std.testing.expect(matches(fixture));
    const got = try applyToString(std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "EXAMPLE-101") != null);
    try std.testing.expect(std.mem.find(u8, got, "In Progress") != null);
    try std.testing.expect(std.mem.find(u8, got, "Anonymized sample work item") != null);
}

test "compacts Jira work item view and limits long text sections" {
    const fixture = @embedFile("fixture_acli_jira_workitem_view");
    try std.testing.expect(matches(fixture));
    const got = try applyToString(std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "Key: EXAMPLE-101") != null);
    try std.testing.expect(std.mem.find(u8, got, "URL: https://example.atlassian.invalid/browse/EXAMPLE-101") != null);
    try std.testing.expect(std.mem.find(u8, got, "Ut enim ad minim veniam") == null);
}

test "preserves Jira custom fields and story points" {
    const fixture = @embedFile("fixture_acli_jira_workitem_fields");
    try std.testing.expect(matches(fixture));
    const got = try applyToString(std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "Story Points: 2") != null);
    try std.testing.expect(std.mem.find(u8, got, "Acceptance Criteria:\n  Add text") != null);
    try std.testing.expect(std.mem.find(u8, got, "Definition Of Done:\n  None") != null);
    try std.testing.expect(std.mem.find(u8, got, "Custom Review Group: Example Reviewers") != null);
    try std.testing.expect(std.mem.find(u8, got, "Customer Impact:\n  Anonymized customer impact text preserves custom field shape.") != null);
    try std.testing.expect(std.mem.find(u8, got, "Additional anonymized description detail") == null);
}

test "compacts Confluence page view and preserves page metadata" {
    const fixture = @embedFile("fixture_acli_confluence_page_view");
    try std.testing.expect(matches(fixture));
    const got = try applyToString(std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "ID: 100000001") != null);
    try std.testing.expect(std.mem.find(u8, got, "Title: Anonymized Planning Notes") != null);
    try std.testing.expect(std.mem.find(u8, got, "Labels: lorem, ipsum, anonymized") != null);
    try std.testing.expect(std.mem.find(u8, got, "Duis aute irure") == null);
}

test "matches Confluence space table" {
    const fixture = @embedFile("fixture_acli_confluence_space_list");
    try std.testing.expect(matches(fixture));
    const got = try applyToString(std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "EXAMPLE Anonymized Space") != null);
    try std.testing.expect(std.mem.find(u8, got, "DOCS Dolor Sit Documentation") != null);
}

test "unknown output passes through unchanged" {
    const raw =
        "Usage: acli jira workitem [command]\n" ++
        "  --help     Show help text\n" ++
        "  --version  Show version\n";
    try std.testing.expect(!matches(raw));
    const got = try applyToString(std.testing.allocator, raw);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(raw, got);
}
