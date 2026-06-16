const std = @import("std");
const ansi = @import("ansi");
const columnar = @import("columnar");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const TableKind = enum {
    jira_workitem_search,
    confluence_space_list,
};

const PendingIndentedLine = enum {
    none,
    body,
    field_value,
};

/// Compact `acli jira workitem search` tables.
pub fn applyJiraWorkitemSearch(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    try applyTable(.jira_workitem_search, allocator, stdout, writer);
}

/// Compact `acli jira workitem view` output.
pub fn applyJiraWorkitemView(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    try applyView(allocator, stdout, writer);
}

/// Compact `acli confluence page view` output.
pub fn applyConfluencePageView(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    try applyView(allocator, stdout, writer);
}

/// Compact `acli confluence space list` tables.
pub fn applyConfluenceSpaceList(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;
    try applyTable(.confluence_space_list, allocator, stdout, writer);
}

fn applyTable(
    kind: TableKind,
    allocator: Allocator,
    stdout: []const u8,
    writer: *Writer,
) !void {
    if (!columnar.matchesGeneric(stdout) or !isKnownTable(kind, stdout)) {
        try writer.writeAll(stdout);
        return;
    }

    try columnar.applyGeneric(allocator, stdout, &.{}, writer);
}

fn applyView(allocator: Allocator, stdout: []const u8, writer: *Writer) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    var kept: usize = 0;
    var pending_indented_line: PendingIndentedLine = .none;
    var in_fields_section = false;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;

        switch (pending_indented_line) {
            .none => {},
            .body => {
                if (!isBodyBoundaryLabel(line)) {
                    try writeIndentedViewLine(writer, line, &kept);
                    pending_indented_line = .none;
                    continue;
                }
                pending_indented_line = .none;
            },
            .field_value => {
                if (!looksLikeSectionLabel(line)) {
                    try writeIndentedViewLine(writer, line, &kept);
                    pending_indented_line = .none;
                    continue;
                }
                pending_indented_line = .none;
            },
        }

        if (isFieldsLabel(line)) {
            in_fields_section = true;
            try writeViewLine(writer, line, &kept);
            pending_indented_line = .none;
            continue;
        }

        if (isBodySectionLabel(line)) {
            in_fields_section = false;
            try writeViewLine(writer, line, &kept);
            pending_indented_line = if (labelHasEmptyValue(line)) .body else .none;
            continue;
        }

        if (in_fields_section and looksLikeSectionLabel(line)) {
            try writeViewLine(writer, line, &kept);
            pending_indented_line = if (line[line.len - 1] == ':') .field_value else .none;
            continue;
        }

        if (isMetadataLine(line)) {
            try writeViewLine(writer, line, &kept);
            continue;
        }
    }

    if (kept == 0) try writer.writeAll(stdout);
}

fn writeViewLine(writer: *Writer, line: []const u8, kept: *usize) !void {
    try writer.writeAll(line);
    try writer.writeByte('\n');
    kept.* += 1;
}

fn writeIndentedViewLine(writer: *Writer, line: []const u8, kept: *usize) !void {
    try writer.writeAll("  ");
    try writer.writeAll(line);
    try writer.writeByte('\n');
    kept.* += 1;
}

fn isMetadataLine(line: []const u8) bool {
    return startsWithAny(line, &.{
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
        "ID:",
        "Title:",
        "Space:",
        "Author:",
        "Created by:",
        "Last updated:",
        "Version:",
        "Labels:",
    });
}

fn isFieldsLabel(line: []const u8) bool {
    return startsWithAny(line, &.{"Fields:"});
}

fn isBodySectionLabel(line: []const u8) bool {
    return startsWithAny(line, &.{ "Description:", "Body:", "Comments:" });
}

fn isBodyBoundaryLabel(line: []const u8) bool {
    return isBodySectionLabel(line) or isFieldsLabel(line);
}

fn labelHasEmptyValue(line: []const u8) bool {
    return line[line.len - 1] == ':';
}

fn looksLikeSectionLabel(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    if (colon == 0 or colon > 48) return false;
    for (line[0..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == ' ' or c == '-' or c == '_' or c == '/' or c == '&' or c == '(' or c == ')')) return false;
    }
    return true;
}

fn isKnownTable(kind: TableKind, input: []const u8) bool {
    const header = firstNonEmptyLine(input);
    return switch (kind) {
        .jira_workitem_search => hasHeaderToken(header, "KEY") and
            hasHeaderToken(header, "SUMMARY") and
            (hasHeaderToken(header, "ASSIGNEE") or hasHeaderToken(header, "STATUS")),
        .confluence_space_list => hasHeaderToken(header, "KEY") and
            hasHeaderToken(header, "NAME") and
            (hasHeaderToken(header, "HOMEPAGE") or hasHeaderToken(header, "STATUS")),
    };
}

fn firstNonEmptyLine(input: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) return line;
    }
    return "";
}

fn hasHeaderToken(header: []const u8, token: []const u8) bool {
    var fields = std.mem.tokenizeAny(u8, header, " \t\r");
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field, token)) return true;
    }
    return false;
}

fn startsWithAny(line: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

fn applyToString(
    comptime applyFn: fn (Allocator, []const u8, []const u8, *Writer) anyerror!void,
    allocator: Allocator,
    input: []const u8,
) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try applyFn(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches Jira work item search table" {
    const fixture = @embedFile("fixture_acli_jira_workitem_search");
    const got = try applyToString(applyJiraWorkitemSearch, std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "EXAMPLE-101") != null);
    try std.testing.expect(std.mem.find(u8, got, "In Progress") != null);
    try std.testing.expect(std.mem.find(u8, got, "Anonymized sample work item") != null);
}

test "compacts Jira work item view and limits long text sections" {
    const fixture = @embedFile("fixture_acli_jira_workitem_view");
    const got = try applyToString(applyJiraWorkitemView, std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "Key: EXAMPLE-101") != null);
    try std.testing.expect(std.mem.find(u8, got, "URL: https://example.atlassian.invalid/browse/EXAMPLE-101") != null);
    try std.testing.expect(std.mem.find(u8, got, "Ut enim ad minim veniam") == null);
}

test "preserves Jira custom fields and story points" {
    const fixture = @embedFile("fixture_acli_jira_workitem_fields");
    const got = try applyToString(applyJiraWorkitemView, std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "Story Points: 2") != null);
    try std.testing.expect(std.mem.find(u8, got, "Acceptance Criteria:\n  Add text") != null);
    try std.testing.expect(std.mem.find(u8, got, "Definition Of Done:\n  None") != null);
    try std.testing.expect(std.mem.find(u8, got, "Custom Review Group: Example Reviewers") != null);
    try std.testing.expect(std.mem.find(u8, got, "Customer Impact:\n  Anonymized customer impact text preserves custom field shape.") != null);
    try std.testing.expect(std.mem.find(u8, got, "Additional anonymized description detail") == null);
}

test "indents body text that looks like a view field" {
    const fixture =
        "Key: EXAMPLE-106\n" ++
        "Type: Task\n" ++
        "Summary: Anonymized body text edge case\n" ++
        "Status: In Progress\n" ++
        "Assignee: Grace Example\n" ++
        "URL: https://example.atlassian.invalid/browse/EXAMPLE-106\n" ++
        "\n" ++
        "Description:\n" ++
        "Status: anonymized body text should stay inside the description.\n" ++
        "Additional anonymized detail that can be elided.\n";
    const got = try applyToString(applyJiraWorkitemView, std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.find(u8, got, "Status: In Progress") != null);
    try std.testing.expect(std.mem.find(u8, got, "Description:\n  Status: anonymized body text should stay inside the description.") != null);
    try std.testing.expect(std.mem.find(u8, got, "\nStatus: anonymized body text should stay inside the description.") == null);
    try std.testing.expect(std.mem.find(u8, got, "Additional anonymized detail") == null);
}

test "custom field labels are only kept inside Fields section" {
    const fixture =
        "Key: EXAMPLE-107\n" ++
        "Type: Task\n" ++
        "Summary: Anonymized custom field boundary\n" ++
        "Status: To Do\n" ++
        "Assignee: Grace Example\n" ++
        "URL: https://example.atlassian.invalid/browse/EXAMPLE-107\n" ++
        "Release Notes: this label-shaped line is not in Fields\n" ++
        "\n" ++
        "Description:\n" ++
        "Useful description preview.\n" ++
        "Additional anonymized detail that can be elided.\n";
    const got = try applyToString(applyJiraWorkitemView, std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.find(u8, got, "Release Notes:") == null);
    try std.testing.expect(std.mem.find(u8, got, "Description:\n  Useful description preview.") != null);
}

test "compacts ANSI-colored Jira view labels" {
    const fixture =
        "\x1b[1mKey:\x1b[0m EXAMPLE-108\n" ++
        "\x1b[1mType:\x1b[0m Task\n" ++
        "\x1b[1mSummary:\x1b[0m Anonymized colored labels\n" ++
        "\x1b[1mStatus:\x1b[0m In Progress\n" ++
        "\x1b[1mURL:\x1b[0m https://example.atlassian.invalid/browse/EXAMPLE-108\n" ++
        "\x1b[1mDescription:\x1b[0m\n" ++
        "Colored label output still compacts.\n" ++
        "Additional anonymized detail that can be elided.\n";
    const got = try applyToString(applyJiraWorkitemView, std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "Key: EXAMPLE-108") != null);
    try std.testing.expect(std.mem.find(u8, got, "Description:\n  Colored label output still compacts.") != null);
}

test "compacts Confluence page view and preserves page metadata" {
    const fixture = @embedFile("fixture_acli_confluence_page_view");
    const got = try applyToString(applyConfluencePageView, std.testing.allocator, fixture);
    defer std.testing.allocator.free(got);

    try std.testing.expect(got.len < fixture.len);
    try std.testing.expect(std.mem.find(u8, got, "ID: 100000001") != null);
    try std.testing.expect(std.mem.find(u8, got, "Title: Anonymized Planning Notes") != null);
    try std.testing.expect(std.mem.find(u8, got, "Labels: lorem, ipsum, anonymized") != null);
    try std.testing.expect(std.mem.find(u8, got, "Duis aute irure") == null);
}

test "matches Confluence space table" {
    const fixture = @embedFile("fixture_acli_confluence_space_list");
    const got = try applyToString(applyConfluenceSpaceList, std.testing.allocator, fixture);
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
    const got = try applyToString(applyJiraWorkitemView, std.testing.allocator, raw);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(raw, got);
}
