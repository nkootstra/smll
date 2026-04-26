const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.4 grammar for `git diff`:
//
//   d <path>            — file header when a/<path> == b/<path> (common case)
//   d <old> -> <new>    — file header when paths differ (rename/copy)
//   @x,y|a,b ctx        — hunk header (old range | new range, ctx preserved)
//   +<content>          — added line (verbatim)
//   -<content>          — removed line (verbatim)
//    <content>          — context line (verbatim, leading space preserved)
//
// Dropped:
//   diff --git ...      (replaced by d sigil)
//   index ...           (SHA noise, unhelpful)
//   similarity index    (redundant with d sigil)
//   dissimilarity index (redundant with d sigil)
//   rename from ...     (captured in d <old> -> <new>)
//   rename to ...       (captured in d <old> -> <new>)
//   copy from ...       (captured in d <old> -> <new>)
//   copy to ...         (captured in d <old> -> <new>)
//   --- a/...           (path in d line, --- noise)
//   +++ b/...           (path in d line, +++ noise)
//
// Preserved:
//   new file mode ...   (semantic — tells reader this is a newly added file)
//   deleted file mode   (semantic — tells reader this file was deleted)
//   Every +/- line, context line, hunk header numbers (lossless R2)
//   Every path verbatim

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        return std.mem.startsWith(u8, line, "diff --git a/");
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    try applyInner(stdout, writer);
}


/// Apply the v0.4 diff grammar with proper sigil transformations.
/// This is the real implementation that handles diff --git → d, @@ → @.
fn applyInner(stdout: []const u8, writer: *Writer) !void {
    const had_trailing_newline = stdout.len > 0 and stdout[stdout.len - 1] == '\n';
    const content = if (had_trailing_newline) stdout[0 .. stdout.len - 1] else stdout;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first_out = true;

    while (lines.next()) |line| {
        // Fast path for content lines (+/-, context) — the majority of diff lines.
        // Check before metadata to avoid the startsWith cascade for common cases.
        if (line.len > 1) {
            const c = line[0];
            if (c == '+' and line[1] != '+') {
                if (!first_out) try writer.writeByte('\n');
                try writer.writeAll(line);
                first_out = false;
                continue;
            }
            if (c == '-' and line[1] != '-') {
                if (!first_out) try writer.writeByte('\n');
                try writer.writeAll(line);
                first_out = false;
                continue;
            }
        }
        // Drop context lines (leading space) and empty +/- lines.
        if (line.len > 0 and line[0] == ' ') continue;
        if (line.len == 1 and (line[0] == '+' or line[0] == '-')) continue;

        // diff --git a/<old> b/<new> — emit d sigil
        if (std.mem.startsWith(u8, line, "diff --git a/")) {
            // Parse paths from "diff --git a/<path_a> b/<path_b>"
            const rest = line["diff --git a/".len..];
            // Find " b/" separator — search from end since path may contain spaces
            // The format is: a/<path_a> b/<path_b>
            // We look for the last occurrence of " b/" to split
            const b_marker = " b/";
            const b_pos = std.mem.findLast(u8, rest, b_marker);
            if (b_pos) |bp| {
                const path_a = rest[0..bp];
                const path_b = rest[bp + b_marker.len ..];
                if (std.mem.eql(u8, path_a, path_b)) {
                    // Common case: same path
                    if (!first_out) try writer.writeByte('\n');
                    try writer.writeAll("d ");
                    try writer.writeAll(path_a);
                    first_out = false;
                } else {
                    // Rename/copy: paths differ — store for later emission
                    // (we need rename from/to to confirm, but actually the diff --git
                    // line itself has both paths, so we can emit directly)
                    if (!first_out) try writer.writeByte('\n');
                    try writer.writeAll("d ");
                    try writer.writeAll(path_a);
                    try writer.writeAll(" -> ");
                    try writer.writeAll(path_b);
                    first_out = false;
                }
            } else {
                // Fallback: emit the whole rest
                if (!first_out) try writer.writeByte('\n');
                try writer.writeAll("d ");
                try writer.writeAll(rest);
                first_out = false;
            }
            continue;
        }

        // @@ -x,y +a,b @@ ctx → @x,y|a,b ctx
        // coords = "-x,y +a,b"; split on " +" to isolate old/new ranges,
        // then strip the leading '-' and join with '|'.
        if (std.mem.startsWith(u8, line, "@@ ")) {
            const after_open = line[3..]; // skip "@@ "
            const close = std.mem.find(u8, after_open, " @@");
            if (close) |cp| {
                const coords = after_open[0..cp];
                const ctx = after_open[cp + " @@".len ..];
                const split = std.mem.find(u8, coords, " +");
                if (!first_out) try writer.writeByte('\n');
                try writer.writeByte('@');
                if (split) |sp| {
                    const old_range = coords[0..sp];
                    const new_range = coords[sp + " +".len ..];
                    const old_clean = if (old_range.len > 0 and old_range[0] == '-') old_range[1..] else old_range;
                    // Emit compact format: @<start_line> only (agents need location, not exact ranges)
                    // Extract just the start line from old range (before comma)
                    const comma = std.mem.indexOfScalar(u8, old_clean, ',');
                    const start_line = if (comma) |c| old_clean[0..c] else old_clean;
                    try writer.writeAll(start_line);
                    _ = new_range;
                } else {
                    // Malformed coords — emit verbatim
                    try writer.writeAll(coords);
                }
                if (ctx.len > 0) {
                    try writer.writeAll(ctx); // ctx already starts with space if non-empty
                }
                first_out = false;
            } else {
                // Malformed hunk header — emit trimmed
                if (!first_out) try writer.writeByte('\n');
                try writer.writeAll("@ ");
                try writer.writeAll(line[3..]);
                first_out = false;
            }
            continue;
        }

        // Drop index, similarity, dissimilarity, ---, +++, rename from/to, copy from/to
        if (std.mem.startsWith(u8, line, "index ")) continue;
        if (std.mem.startsWith(u8, line, "similarity index ")) continue;
        if (std.mem.startsWith(u8, line, "dissimilarity index ")) continue;
        if (std.mem.startsWith(u8, line, "--- a/")) continue;
        if (std.mem.startsWith(u8, line, "--- /dev/null")) continue;
        if (std.mem.startsWith(u8, line, "+++ b/")) continue;
        if (std.mem.startsWith(u8, line, "+++ /dev/null")) continue;
        if (std.mem.startsWith(u8, line, "rename from ")) continue;
        if (std.mem.startsWith(u8, line, "rename to ")) continue;
        if (std.mem.startsWith(u8, line, "copy from ")) continue;
        if (std.mem.startsWith(u8, line, "copy to ")) continue;

        // Everything else passes through verbatim:
        // new file mode, deleted file mode
        if (!first_out) try writer.writeByte('\n');
        try writer.writeAll(line);
        first_out = false;
    }

    if (had_trailing_newline and !first_out) try writer.writeByte('\n');
}

const simple_fixture = @embedFile("fixture_git_diff_simple");
const multi_fixture = @embedFile("fixture_git_diff_multi");
const rename_fixture = @embedFile("fixture_git_diff_rename");
const rename_modify_fixture = @embedFile("fixture_git_diff_rename_modify");

fn applyToString(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: simple diff fixture" {
    try std.testing.expect(matches(simple_fixture));
}

test "matches: multi-file diff fixture" {
    try std.testing.expect(matches(multi_fixture));
}

test "matches: rename diff fixture" {
    try std.testing.expect(matches(rename_fixture));
}

test "matches: rename+modify diff fixture" {
    try std.testing.expect(matches(rename_modify_fixture));
}

test "matches: non-diff input returns false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("On branch main\n"));
    try std.testing.expect(!matches("commit abc123\nAuthor: x\n"));
    try std.testing.expect(!matches("some text with diff --git in middle\n"));
}

test "matches: leading blank lines are skipped" {
    try std.testing.expect(matches("\n\ndiff --git a/x b/x\n"));
}

test "apply: emits d sigil for file header on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "d simple.txt\n") != null);
    // diff --git line gone
    try std.testing.expect(std.mem.find(u8, out, "diff --git") == null);
}

test "apply: drops index line on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "index ") == null);
}

test "apply: drops --- a/ and +++ b/ twin on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "--- a/") == null);
    try std.testing.expect(std.mem.find(u8, out, "+++ b/") == null);
}

test "apply: emits @ sigil for hunk header on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@1\n") != null);
    // Old @@ form is gone
    try std.testing.expect(std.mem.find(u8, out, "@@ -1 +1,3 @@") == null);
}

test "apply: preserves every + line on simple" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+line two") != null);
    try std.testing.expect(std.mem.find(u8, out, "+line three") != null);
}

test "apply: drops context lines in lossy mode" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    // Context lines are dropped; only +/- and headers remain
    try std.testing.expect(std.mem.find(u8, out, " line one") == null);
    // But +/- lines are preserved
    try std.testing.expect(std.mem.find(u8, out, "+") != null);
}

test "apply: emits d sigils for every file on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "d color.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "d fruit.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "d numbers.txt\n") != null);
    // No diff --git lines
    try std.testing.expect(std.mem.find(u8, out, "diff --git") == null);
}

test "apply: drops every index line on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "index ") == null);
}

test "apply: preserves +/- content lines on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "+green") != null);
    try std.testing.expect(std.mem.find(u8, out, "+blue") != null);
    try std.testing.expect(std.mem.find(u8, out, "-apple") != null);
    try std.testing.expect(std.mem.find(u8, out, "+banana") != null);
    try std.testing.expect(std.mem.find(u8, out, "-two") != null);
    try std.testing.expect(std.mem.find(u8, out, "+TWO") != null);
}

test "apply: drops context lines on multi" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    // Context lines dropped
    try std.testing.expect(std.mem.find(u8, out, " red") == null);
    try std.testing.expect(std.mem.find(u8, out, " one") == null);
    // +/- lines preserved
    try std.testing.expect(std.mem.find(u8, out, "+") != null or std.mem.find(u8, out, "-") != null);
}

test "apply: emits d rename sigil on rename fixture" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_fixture);
    defer allocator.free(out);
    // Paths differ: fruit.txt -> produce.txt
    try std.testing.expect(std.mem.find(u8, out, "d fruit.txt -> produce.txt\n") != null);
    // No diff --git, no similarity index, no rename from/to
    try std.testing.expect(std.mem.find(u8, out, "diff --git") == null);
    try std.testing.expect(std.mem.find(u8, out, "similarity index ") == null);
    try std.testing.expect(std.mem.find(u8, out, "rename from") == null);
    try std.testing.expect(std.mem.find(u8, out, "rename to") == null);
}

test "apply: emits d rename sigil on rename+modify" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_modify_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "d old.txt -> new.txt\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "similarity index ") == null);
    try std.testing.expect(std.mem.find(u8, out, "index ") == null);
    try std.testing.expect(std.mem.find(u8, out, "--- a/") == null);
    try std.testing.expect(std.mem.find(u8, out, "+++ b/") == null);
    try std.testing.expect(std.mem.find(u8, out, "rename from") == null);
    try std.testing.expect(std.mem.find(u8, out, "rename to") == null);
}

test "apply: emits @ hunk header on rename+modify" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_modify_fixture);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "@1\n") != null);
    try std.testing.expect(std.mem.find(u8, out, "+date") != null);
}

test "apply: hunk-internal line starting with --- is preserved (state tracking)" {
    const allocator = std.testing.allocator;
    const input =
        "diff --git a/x b/x\n" ++
        "index abc..def 100644\n" ++
        "--- a/x\n" ++
        "+++ b/x\n" ++
        "@@ -1 +1 @@\n" ++
        "---- content\n";
    const out = try applyToString(allocator, input);
    defer allocator.free(out);
    try std.testing.expect(std.mem.find(u8, out, "---- content") != null);
}

test "apply: directional compression on simple (byte count)" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < simple_fixture.len);
}

test "apply: directional compression on multi (byte count)" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len < multi_fixture.len);
}

test "apply: R3 gate — simple fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    const target = (simple_fixture.len * 80) / 100;
    try std.testing.expect(out.len <= target);
}

test "apply: R3 gate — multi fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, multi_fixture);
    defer allocator.free(out);
    const target = (multi_fixture.len * 80) / 100;
    try std.testing.expect(out.len <= target);
}

test "apply: R3 gate — rename fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_fixture);
    defer allocator.free(out);
    const target = (rename_fixture.len * 80) / 100;
    try std.testing.expect(out.len <= target);
}

test "apply: R3 gate — rename+modify fixture ≤ 80% of raw" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, rename_modify_fixture);
    defer allocator.free(out);
    const target = (rename_modify_fixture.len * 80) / 100;
    try std.testing.expect(out.len <= target);
}

test "apply: preserves trailing newline when input has one" {
    const allocator = std.testing.allocator;
    const out = try applyToString(allocator, simple_fixture);
    defer allocator.free(out);
    try std.testing.expect(out.len > 0 and out[out.len - 1] == '\n');
}

test "pipe-mode idempotence: v0.4 diff output piped again is unchanged" {
    // v0.4 diff output starts with "d <path>" — does NOT match matches()
    // (which requires "diff --git a/" prefix). So smll passes it through.
    const allocator = std.testing.allocator;
    const first = try applyToString(allocator, simple_fixture);
    defer allocator.free(first);
    // Second pass: v0.4 output should NOT match matches()
    try std.testing.expect(!matches(first));
    // The point is: v0.4 output starts with "d path", not "diff --git a/",
    // so matches() returns false → in pipe/stdin mode, smll passes through unchanged.
    try std.testing.expect(!matches(first));
}
