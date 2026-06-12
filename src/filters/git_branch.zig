const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// v0.4 grammar for `git branch`:
//
//   * <branch>   — current branch (asterisk sigil, same as raw git; leading space stripped)
//     <branch>   — other branch   (two-space indent stripped to single space)
//
// R3 exemption: pure branch-name listings are physically incompressible
// beyond ~7% losslessly, so the 20% reduction floor does not apply here.
// R3 for git_branch relaxes to: smll_bytes ≤ raw_git_bytes (no expansion).
// This is documented in benchmarks/results-v0.4.md under "R3 git_branch exemption".
//
// matches() returns true when the first non-blank line starts with "  " (two
// spaces + name) OR "* " (asterisk + space + name).  Empty input returns false
// so that delete/rename silent output falls through to passthrough.
// Pipe-mode idempotence: compact plain rows either pass through unchanged on a
// second pass or compact to the same bytes again. Verbose rows are also stable.

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Current branch: "* <name>" where name starts with a non-space char.
        // Rejects curl -v output which starts with "*   Trying..." (extra spaces).
        if (line.len >= 3 and line[0] == '*' and line[1] == ' ' and line[2] != ' ') return true;
        // Other branch: "  <name>" (exactly two spaces)
        if (line.len >= 3 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ') return true;
        // Any other first non-blank line → not a branch list.
        return false;
    }
    return false; // empty input → passthrough
}

pub fn apply(a: Allocator, stdout: []const u8, stderr: []const u8, w: *Writer) !void {
    _ = stderr;
    // Branch list lands on stdout.
    const input = stdout;
    if (input.len == 0) return;

    // `git branch -a` lists a local branch and then a `remotes/origin/<same>`
    // tracking copy on a second line — pure duplication. When present, collapse
    // each duplicate onto its local entry with a `=o` marker. This only engages
    // when the input actually contains `remotes/` rows, so plain `git branch`
    // output takes the streaming path below untouched.
    const has_remotes = std.mem.find(u8, input, "remotes/") != null;
    var local_set = std.StringHashMap(void).init(a);
    defer local_set.deinit();
    var origin_set = std.StringHashMap(void).init(a);
    defer origin_set.deinit();
    if (has_remotes) try scanBranchSets(input, &local_set, &origin_set);

    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;

        // Decide the `=o` marker (or drop the line entirely) for `-a` output.
        var marker: []const u8 = "";
        if (has_remotes) {
            if (firstBranchToken(line)) |tok| {
                if (originName(tok)) |rn| {
                    // remotes/origin/X duplicating a local branch → drop this
                    // line; the local entry below carries the `=o` marker.
                    if (!std.mem.eql(u8, rn, "HEAD") and local_set.contains(rn)) continue;
                } else if (!isRemoteToken(tok) and origin_set.contains(tok)) {
                    marker = " =o";
                }
            }
        }

        if (try writeVerboseBranchLine(w, line, marker)) {
            continue;
        } else if (std.mem.startsWith(u8, line, "* ")) {
            // Current branch: strip one leading space to save a byte → "* <name>"
            // (This keeps the '*' sigil but collapses "* main" → "* main"; same width.
            //  We preserve verbatim to stay R2-lossless without any decode step.)
            try w.writeAll("* ");
            try w.writeAll(line[2..]);
            try w.writeAll(marker);
            try w.writeByte('\n');
        } else if (line.len >= 2 and line[0] == ' ' and line[1] == ' ') {
            // Other branch: two-space indent → single space (saves 1 B per branch).
            // Pipe-mode idempotence: single-space prefix ("  " → " ") does NOT
            // start with "  " (two spaces), so re-matching returns false.
            try w.writeByte(' ');
            try w.writeAll(std.mem.trimStart(u8, line, " "));
            try w.writeAll(marker);
            try w.writeByte('\n');
        } else {
            // Unknown line shape — pass through verbatim.
            try w.writeAll(line);
            try w.writeByte('\n');
        }
    }
}

/// `remotes/origin/<name>` → `<name>`; null for any other token.
fn originName(token: []const u8) ?[]const u8 {
    const prefix = "remotes/origin/";
    if (std.mem.startsWith(u8, token, prefix)) return token[prefix.len..];
    return null;
}

/// Any remote-tracking row (`remotes/<remote>/...`), origin or otherwise.
fn isRemoteToken(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "remotes/");
}

/// The branch-name token (first whitespace-delimited field after the sigil or
/// indent). Handles `* name`, `  name`, and the already-compacted ` name`.
fn firstBranchToken(line: []const u8) ?[]const u8 {
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, line, "* ")) {
        rest = line[2..];
    } else if (line.len >= 1 and line[0] == ' ') {
        rest = std.mem.trimStart(u8, line, " ");
    } else {
        return null;
    }
    if (rest.len == 0) return null;
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end];
}

/// Pre-scan for `-a` collapse: record local branch names and the names that
/// appear as `remotes/origin/<name>` (excluding the `HEAD` pointer row).
fn scanBranchSets(
    input: []const u8,
    local_set: *std.StringHashMap(void),
    origin_set: *std.StringHashMap(void),
) !void {
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const tok = firstBranchToken(line) orelse continue;
        if (originName(tok)) |rn| {
            if (!std.mem.eql(u8, rn, "HEAD")) try origin_set.put(rn, {});
        } else if (!isRemoteToken(tok)) {
            try local_set.put(tok, {});
        }
    }
}

fn writeVerboseBranchLine(w: *Writer, line: []const u8, marker: []const u8) !bool {
    const current = std.mem.startsWith(u8, line, "* ");
    if (!current and !std.mem.startsWith(u8, line, "  ")) return false;

    const rest = std.mem.trimStart(u8, line[2..], " ");
    const sha_start = findShaToken(rest) orelse return false;
    if (sha_start == 0) return false;
    const branch = std.mem.trimEnd(u8, rest[0..sha_start], " ");
    const after_branch = std.mem.trimStart(u8, rest[sha_start..], " ");
    const sha = after_branch[0..7];
    const tail = std.mem.trimStart(u8, after_branch[7..], " ");

    if (current) try w.writeAll("* ");
    try w.writeAll(branch);
    try w.writeByte(' ');
    try w.writeAll(sha);
    if (tail.len > 0) {
        try w.writeByte(' ');
        try writeCompactVerboseTail(w, tail);
    }
    try w.writeAll(marker);
    try w.writeByte('\n');
    return true;
}

fn findShaToken(line: []const u8) ?usize {
    var i: usize = 0;
    while (i + 7 <= line.len) : (i += 1) {
        if (i > 0 and line[i - 1] != ' ') continue;
        if (i + 7 < line.len and line[i + 7] != ' ') continue;
        if (allHex(line[i .. i + 7])) return i;
    }
    return null;
}

fn allHex(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn writeCompactVerboseTail(w: *Writer, tail: []const u8) !void {
    if (!std.mem.startsWith(u8, tail, "[")) {
        try w.writeAll(tail);
        return;
    }

    const end = std.mem.indexOfScalar(u8, tail, ']') orelse {
        try w.writeAll(tail);
        return;
    };
    const upstream = tail[1..end];
    try w.writeByte('@');
    if (std.mem.endsWith(u8, upstream, ": gone")) {
        try w.writeAll(upstream[0 .. upstream.len - ": gone".len]);
        try w.writeAll(" gone");
    } else {
        try w.writeAll(upstream);
    }

    const subject = std.mem.trimStart(u8, tail[end + 1 ..], " ");
    if (subject.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(subject);
    }
}

// ---------------------------------------------------------------------------
// Fixtures + tests.
// ---------------------------------------------------------------------------

const fixture_branch_list = @embedFile("fixture_git_branch_list");

fn str(allocator: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(allocator);
    defer out.deinit();
    try apply(allocator, input, &.{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

test "matches: two-space branch row" {
    try std.testing.expect(matches("  feature\n* main\n"));
}

test "matches: asterisk-first branch row" {
    try std.testing.expect(matches("* main\n  feature\n"));
}

test "matches: empty input returns false" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("\n\n"));
}

test "matches: non-branch input returns false" {
    try std.testing.expect(!matches("some text\n"));
    try std.testing.expect(!matches("Deleted branch feature\n"));
    try std.testing.expect(!matches("^ main\n")); // checkout output
}

test "matches: fixture" {
    try std.testing.expect(matches(fixture_branch_list));
}

test "pipe-mode idempotence: compressed output is NOT re-matched" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_branch_list);
    defer a.free(out);
    // Compressed output uses "* <name>" and " <name>" (single space).
    // The "  " (two-space) pattern won't match single-space output.
    try std.testing.expect(!matches(out));
}

test "apply: current branch emits * sigil" {
    const a = std.testing.allocator;
    const out = try str(a, "* main\n  feature\n");
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "* main\n") != null);
}

test "apply: other branches get single-space indent" {
    const a = std.testing.allocator;
    const out = try str(a, "* main\n  feature\n  dev\n");
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, " feature\n") != null);
    try std.testing.expect(std.mem.find(u8, out, " dev\n") != null);
}

test "apply: verbose branch rows collapse alignment and upstream marker" {
    const a = std.testing.allocator;
    const input =
        "* feat/generic-output-optimization    9ce95e8 docs: document generic table fallback\n" ++
        "  main                                78a9d9e [origin/main] chore: release v1.2.5\n" ++
        "  hardening/tool-output-safety        b9033e1 [origin/hardening/tool-output-safety: gone] Harden wrapper output safety\n";
    const out = try str(a, input);
    defer a.free(out);

    try std.testing.expectEqualStrings(
        "* feat/generic-output-optimization 9ce95e8 docs: document generic table fallback\n" ++
            "main 78a9d9e @origin/main chore: release v1.2.5\n" ++
            "hardening/tool-output-safety b9033e1 @origin/hardening/tool-output-safety gone Harden wrapper output safety\n",
        out,
    );
}

test "apply: plain seven-hex branch name stays plain" {
    const a = std.testing.allocator;
    const out = try str(a, "* deadbee\n  feature\n");
    defer a.free(out);

    try std.testing.expectEqualStrings("* deadbee\n feature\n", out);
}

test "pipe-mode idempotence: verbose compact output is stable" {
    const a = std.testing.allocator;
    const input =
        "* feat/generic-output-optimization    9ce95e8 docs: document generic table fallback\n" ++
        "  main                                78a9d9e [origin/main] chore: release v1.2.5\n";
    const once = try str(a, input);
    defer a.free(once);
    const twice = try str(a, once);
    defer a.free(twice);

    try std.testing.expectEqualStrings(once, twice);
}

test "apply: all branch names preserved" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_branch_list);
    defer a.free(out);
    // fixture contains: feature-x, feature-y, main
    try std.testing.expect(std.mem.find(u8, out, "feature-x") != null);
    try std.testing.expect(std.mem.find(u8, out, "feature-y") != null);
    try std.testing.expect(std.mem.find(u8, out, "main") != null);
}

test "apply: current branch marker (* main)" {
    const a = std.testing.allocator;
    const out = try str(a, fixture_branch_list);
    defer a.free(out);
    try std.testing.expect(std.mem.find(u8, out, "* main") != null);
}

test "apply: order preserved" {
    const a = std.testing.allocator;
    const out = try str(a, "* main\n  alpha\n  beta\n");
    defer a.free(out);
    const main_pos = std.mem.find(u8, out, "main").?;
    const alpha_pos = std.mem.find(u8, out, "alpha").?;
    const beta_pos = std.mem.find(u8, out, "beta").?;
    try std.testing.expect(main_pos < alpha_pos);
    try std.testing.expect(alpha_pos < beta_pos);
}

test "apply: single-branch repo passthrough (raw < 50 B → smll ≤ raw)" {
    const a = std.testing.allocator;
    const input = "* main\n"; // 7 B — raw < 50 B, smll ≤ raw required
    const out = try str(a, input);
    defer a.free(out);
    try std.testing.expect(out.len <= input.len);
}

test "apply: -a collapses remotes/origin/X onto local X with =o marker" {
    const a = std.testing.allocator;
    const input =
        "* main\n" ++
        "  feature\n" ++
        "  remotes/origin/main\n" ++
        "  remotes/origin/feature\n" ++
        "  remotes/origin/release-1\n" ++
        "  remotes/origin/HEAD -> origin/main\n";
    const out = try str(a, input);
    defer a.free(out);
    // Local branches that also exist as remotes/origin/X get a `=o` marker and
    // the duplicate remote line is dropped. Remote-only branches and the HEAD
    // pointer are kept (single-space indent).
    try std.testing.expectEqualStrings(
        "* main =o\n" ++
            " feature =o\n" ++
            " remotes/origin/release-1\n" ++
            " remotes/origin/HEAD -> origin/main\n",
        out,
    );
}

test "apply: -a keeps non-origin remotes and does not mark unrelated locals" {
    const a = std.testing.allocator;
    const input =
        "* main\n" ++
        "  dev\n" ++
        "  remotes/origin/main\n" ++
        "  remotes/upstream/main\n";
    const out = try str(a, input);
    defer a.free(out);
    // origin/main collapses onto main (=o). upstream/main is a different remote
    // → kept verbatim. `dev` has no origin twin → no marker.
    try std.testing.expectEqualStrings(
        "* main =o\n" ++
            " dev\n" ++
            " remotes/upstream/main\n",
        out,
    );
}

test "pipe-mode idempotence: -a collapsed output is stable" {
    const a = std.testing.allocator;
    const input =
        "* main\n" ++
        "  feature\n" ++
        "  remotes/origin/main\n" ++
        "  remotes/origin/release-1\n";
    const once = try str(a, input);
    defer a.free(once);
    const twice = try str(a, once);
    defer a.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}

test "apply: empty input produces empty output" {
    const a = std.testing.allocator;
    const out = try str(a, "");
    defer a.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "R3 exemption: smll ≤ raw on fixture (branch list is incompressible beyond ~7%)" {
    // R3 for git_branch is relaxed: no 20% floor, only smll ≤ raw.
    // Pure-name listings cannot be compressed ≥20% losslessly; see plan §Unit 6b.
    const a = std.testing.allocator;
    const out = try str(a, fixture_branch_list);
    defer a.free(out);
    try std.testing.expect(out.len <= fixture_branch_list.len);
}

test "R3 exemption: smll ≤ raw on larger branch list" {
    // Synthetic large-ish list to confirm no expansion.
    const a = std.testing.allocator;
    const input =
        "* main\n" ++
        "  alpha-long-branch\n" ++
        "  beta-long-branch\n" ++
        "  gamma-long-branch\n" ++
        "  delta-long-branch\n" ++
        "  epsilon-long-branch\n";
    const out = try str(a, input);
    defer a.free(out);
    try std.testing.expect(out.len <= input.len);
}
