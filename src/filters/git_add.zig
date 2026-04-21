const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.4 grammar for `git add` error/warning output:
//
//   ! <path>   — pathspec error, ignored-file warning, or CRLF warning
//
// `git add` success produces no output (empty stdout + empty stderr).
// Errors/warnings come via stderr; CRLF warnings may appear on stdout.
// `matches` always returns false: git_add is argv-dispatched only;
// empty add output must pass through, and error text has no stable
// prefix that uniquely identifies it in pipe mode.
//
// Note: there is no large fixture for git_add (success is empty;
// large-fixture generation is skipped per Unit 4 plan).

/// matches always returns false — argv-only dispatch.
pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

/// apply processes the combined stdout+stderr of a failed `git add`.
/// Empty input produces empty output (silent success passthrough).
/// Compresses:
///   - `fatal: pathspec '<path>' did not match any files`  → `! <path>`
///   - `warning: CRLF will be replaced by LF in <path>.`   → `! <path>`
///   - `The file will have its original line endings ...`   → (dropped)
///   - `The following paths are ignored ...` block          → `! <path>` per path
pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;

    // Merge stderr into stdout for processing (errors arrive on stderr).
    // Process stdout first, then stderr.
    try processStream(stdout, writer);
    try processStream(stderr, writer);
}

fn processStream(input: []const u8, writer: *Writer) !void {
    if (input.len == 0) return;

    var lines = std.mem.splitScalar(u8, input, '\n');
    var in_ignored_block = false;

    while (lines.next()) |line| {
        if (line.len == 0) {
            in_ignored_block = false;
            continue;
        }

        // "The following paths are ignored by one of your .gitignore files:"
        if (std.mem.startsWith(u8, line, "The following paths are ignored")) {
            in_ignored_block = true;
            continue;
        }

        // Hint lines inside ignored block: "  (use -f if you really want to add them)"
        if (in_ignored_block and std.mem.startsWith(u8, line, "  (")) {
            continue;
        }

        // Paths listed in the ignored block are indented with a tab.
        if (in_ignored_block and std.mem.startsWith(u8, line, "\t")) {
            try writer.writeAll("! ");
            try writer.writeAll(line[1..]); // strip leading tab
            try writer.writeByte('\n');
            continue;
        }

        // "fatal: pathspec 'foo' did not match any files"
        if (std.mem.startsWith(u8, line, "fatal: pathspec '")) {
            const rest = line["fatal: pathspec '".len..];
            // Find closing single-quote.
            if (std.mem.findScalar(u8, rest, '\'')) |end| {
                try writer.writeAll("! ");
                try writer.writeAll(rest[0..end]);
                try writer.writeByte('\n');
            } else {
                // Malformed — pass through.
                try writer.writeAll(line);
                try writer.writeByte('\n');
            }
            continue;
        }

        // "warning: CRLF will be replaced by LF in <path>."
        if (std.mem.startsWith(u8, line, "warning: CRLF will be replaced by LF in ")) {
            const rest = line["warning: CRLF will be replaced by LF in ".len..];
            // Strip trailing period.
            const path = if (std.mem.endsWith(u8, rest, ".")) rest[0 .. rest.len - 1] else rest;
            try writer.writeAll("! ");
            try writer.writeAll(path);
            try writer.writeByte('\n');
            continue;
        }

        // "The file will have its original line endings in your working directory"
        // — informational follow-up to CRLF warning, drop it.
        if (std.mem.startsWith(u8, line, "The file will have its original line endings")) {
            continue;
        }

        // Any other non-empty line — pass through unchanged.
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

// ---------------------------------------------------------------------------
// Fixtures (embedded at compile time).
// ---------------------------------------------------------------------------

const fixture_error_stderr = @embedFile("fixture_git_add_error_stderr");
const fixture_error_stdout = @embedFile("fixture_git_add_error_stdout");

fn applyToString(allocator: Allocator, stdout_in: []const u8, stderr_in: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, stdout_in, stderr_in, &out.writer);
    return allocator.dupe(u8, out.written());
}

// ---------------------------------------------------------------------------
// Unit tests.
// ---------------------------------------------------------------------------

test "matches: always returns false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("fatal: pathspec 'foo' did not match any files\n"));
    try std.testing.expect(!matches("warning: CRLF will be replaced by LF in foo.txt.\n"));
}

test "apply: empty stdout and stderr produces empty output" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, "", "");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "apply: fatal pathspec error produces ! sigil" {
    const allocator = std.testing.allocator;
    const input = "fatal: pathspec 'foo/bar.zig' did not match any files\n";
    const out = try applyToString(allocator, "", input);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("! foo/bar.zig\n", out);
}

test "apply: three CRLF warnings produce three ! rows, all paths preserved" {
    const allocator = std.testing.allocator;
    const input =
        "warning: CRLF will be replaced by LF in src/a.zig.\n" ++
        "The file will have its original line endings in your working directory\n" ++
        "warning: CRLF will be replaced by LF in src/b.zig.\n" ++
        "The file will have its original line endings in your working directory\n" ++
        "warning: CRLF will be replaced by LF in src/c.zig.\n" ++
        "The file will have its original line endings in your working directory\n";
    const out = try applyToString(allocator, input, "");
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "! src/a.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "! src/b.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "! src/c.zig\n") != null);
    // Informational follow-up lines are dropped.
    try std.testing.expect(std.mem.find(u8, out, "The file will have") == null);
    // Exactly 3 lines.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "apply: ignored paths block compresses each path to ! sigil" {
    const allocator = std.testing.allocator;
    const input =
        "The following paths are ignored by one of your .gitignore files:\n" ++
        "  (use -f if you really want to add them)\n" ++
        "\tbuild/output.bin\n" ++
        "\tdist/bundle.js\n";
    const out = try applyToString(allocator, "", input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "! build/output.bin\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "! dist/bundle.js\n") != null);
    // Header line is dropped.
    try std.testing.expect(std.mem.find(u8, out, "The following paths") == null);
}

test "apply: fixture error (stderr) produces ! sigil for nonexistent-path" {
    const allocator = std.testing.allocator;
    // fixture_error_stdout is empty; fixture_error_stderr has the fatal line.
    const out = try applyToString(allocator, fixture_error_stdout, fixture_error_stderr);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("! nonexistent-path\n", out);
}
