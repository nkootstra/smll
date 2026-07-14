const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const util = @import("util");

// Bespoke compaction for `gh pr view` / `gh pr checks` / `gh run view`.
//
// These are LOSSY filters, on by default (SMLL_LOSSLESS=1 bypasses upstream in
// wrapper.zig). The wrapper dispatches by argv — content shape is not guessed —
// and every handler fails safe: on any input that does not match the expected
// non-TTY `gh` grammar it writes the raw stdout through unchanged, so unknown
// `gh` versions or error output are never mangled or dropped.
//
// Why these three shapes:
//   • `gh pr view`  — the generic gh keep-filter destroyed it (dropped title,
//     state, author, number; kept only `##` body headers). Here the metadata
//     block is compacted to a header + non-empty fields and the body is kept
//     verbatim.
//   • `gh pr checks` — a name/state/duration/url table; passing checks collapse
//     to a count, non-passing checks keep their name+duration+url so the agent
//     can click through to the failure.
//   • `gh run view` — keeps the run header + JOBS results (passing jobs collapse
//     to a count, failed jobs keep their failing steps) and de-duplicates the
//     ANNOTATIONS section, where GitHub repeats the same multi-hundred-byte
//     deprecation warning once per job. Identical annotations collapse to one
//     line that keeps the full message and lists every affected job. This
//     applies to errors too: an error is never dropped, but if the identical
//     error text fires in N jobs it collapses to one line listing all N jobs
//     (the message and every location are preserved — only the verbatim
//     repetition is removed).

const Sigil = struct {
    const pass = "✓";
    const fail = "X";
    const warn = "!";
    // "-" (skip) and "*" (running) steps/jobs are kept verbatim by the catch-all
    // non-pass branch, so they don't need named constants in the filter logic.
};

// ── gh pr view ──────────────────────────────────────────────────────────────

pub fn applyPrView(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;

    // The first line must be a `key:\tvalue` metadata field; otherwise this is
    // not the script-mode `gh pr view` shape — pass through untouched.
    if (metadataKey(firstLine(stdout)) == null) {
        try writer.writeAll(stdout);
        return;
    }

    var title: []const u8 = "";
    var state: []const u8 = "";
    var number: []const u8 = "";
    var body_start: ?usize = null;

    // First pass: pull the header fields and find where the body begins.
    var off: usize = 0;
    while (off < stdout.len) {
        const nl = std.mem.indexOfScalarPos(u8, stdout, off, '\n') orelse stdout.len;
        const line = stdout[off..nl];
        if (std.mem.eql(u8, line, "--")) {
            body_start = if (nl < stdout.len) nl + 1 else stdout.len;
            break;
        }
        if (metadataKey(line)) |key| {
            const val = line[key.len + 2 ..]; // skip "key:\t" → key + ':' + '\t'
            if (std.mem.eql(u8, key, "title")) title = val;
            if (std.mem.eql(u8, key, "state")) state = val;
            if (std.mem.eql(u8, key, "number")) number = val;
        }
        off = nl + 1;
    }

    // Real `gh pr view` always emits a `--` separator between the metadata block
    // and the body. Without it (a malformed or future shape), bail to raw rather
    // than risk emitting a header-only or empty result.
    if (body_start == null) {
        try writer.writeAll(stdout);
        return;
    }

    // Header: `#<number> <state> <title>` from whichever parts are present.
    var wrote_header = false;
    if (number.len > 0) {
        try writer.writeByte('#');
        try writer.writeAll(number);
        wrote_header = true;
    }
    if (state.len > 0) {
        if (wrote_header) try writer.writeByte(' ');
        try writer.writeAll(state);
        wrote_header = true;
    }
    if (title.len > 0) {
        if (wrote_header) try writer.writeByte(' ');
        try writer.writeAll(title);
        wrote_header = true;
    }
    if (wrote_header) try writer.writeByte('\n');

    // Second pass: emit every other non-empty metadata field verbatim, dropping
    // the empties (labels/assignees/projects/milestone on most PRs) and the
    // three fields already folded into the header.
    const meta_end = body_start orelse stdout.len;
    off = 0;
    while (off < meta_end) {
        const nl = std.mem.indexOfScalarPos(u8, stdout, off, '\n') orelse meta_end;
        const line = stdout[off..nl];
        if (metadataKey(line)) |key| {
            const val = line[key.len + 2 ..];
            const folded = std.mem.eql(u8, key, "title") or
                std.mem.eql(u8, key, "state") or std.mem.eql(u8, key, "number");
            if (!folded and std.mem.trim(u8, val, " \t\r").len > 0) {
                try writer.writeAll(line);
                try writer.writeByte('\n');
            }
        }
        off = nl + 1;
    }

    // Body: keep verbatim. It is prose the agent asked to read.
    if (body_start) |bs| {
        if (bs < stdout.len) try writer.writeAll(stdout[bs..]);
    }
}

/// Returns the field key (without the trailing ':') if `line` is a
/// `key:\t…` metadata field whose key is a lowercase `[a-z][a-z-]*` identifier.
fn metadataKey(line: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (colon == 0 or colon + 1 >= line.len or line[colon + 1] != '\t') return null;
    const key = line[0..colon];
    if (!std.ascii.isAlphabetic(key[0])) return null;
    for (key) |c| {
        if (!std.ascii.isLower(c) and c != '-') return null;
    }
    return key;
}

// ── gh pr checks ────────────────────────────────────────────────────────────

pub fn applyPrChecks(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;

    var detail: std.ArrayList(u8) = .empty;
    defer detail.deinit(allocator);

    // Track distinct states in first-seen order so the summary reads naturally.
    // A growable list (not a fixed array) keeps the per-state counts summing to
    // `total` no matter how many distinct states appear — no silent cap.
    const Tally = struct { state: []const u8, count: usize };
    var tallies: std.ArrayList(Tally) = .empty;
    defer tallies.deinit(allocator);
    var total: usize = 0;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Each check row is name\tstate\t[duration]\t[url]. Anything else means
        // this is not the `gh pr checks` table — bail to a raw passthrough.
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next() orelse {
            try writer.writeAll(stdout);
            return;
        };
        const state = fields.next() orelse {
            try writer.writeAll(stdout);
            return;
        };
        total += 1;

        var found = false;
        for (tallies.items) |*t| {
            if (std.mem.eql(u8, t.state, state)) {
                t.count += 1;
                found = true;
                break;
            }
        }
        if (!found) try tallies.append(allocator, .{ .state = state, .count = 1 });

        // Keep non-passing checks verbatim (name + state + duration + url).
        if (!std.mem.eql(u8, state, "pass")) {
            try detail.appendSlice(allocator, line);
            try detail.append(allocator, '\n');
        }
    }

    if (total == 0) {
        try writer.writeAll(stdout);
        return;
    }

    try util.writeDecimal(writer, total);
    try writer.writeAll(" checks:");
    for (tallies.items, 0..) |t, i| {
        try writer.writeAll(if (i == 0) " " else ", ");
        try util.writeDecimal(writer, t.count);
        try writer.writeByte(' ');
        try writer.writeAll(t.state);
    }
    try writer.writeByte('\n');
    try writer.writeAll(detail.items);
}

// ── gh run view ─────────────────────────────────────────────────────────────

const Group = struct {
    msg: []const u8,
    locs: std.ArrayList([]const u8),
};

pub fn applyRunView(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = stderr;

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| try lines.append(allocator, line);

    // Require a JOBS section — the defining marker of `gh run view`. Without it,
    // pass through raw rather than risk mangling a different gh shape.
    var has_jobs = false;
    for (lines.items) |line| {
        if (std.mem.eql(u8, line, "JOBS")) has_jobs = true;
    }
    if (!has_jobs) {
        try writer.writeAll(stdout);
        return;
    }

    var i: usize = 0;
    const items = lines.items;

    // Header: the run line + "Triggered via …", verbatim. Skip blank padding.
    while (i < items.len and !std.mem.eql(u8, items[i], "JOBS")) : (i += 1) {
        if (items[i].len > 0) {
            try writer.writeAll(items[i]);
            try writer.writeByte('\n');
        }
    }

    if (i < items.len and std.mem.eql(u8, items[i], "JOBS")) {
        try writer.writeAll("JOBS\n");
        i += 1;
        try emitJobs(allocator, items, &i, writer);
    }

    // Remaining sections: ANNOTATIONS (de-duplicated), ARTIFACTS (verbatim),
    // and the footer (drop the generic hint, keep the failure hint + URL).
    while (i < items.len) {
        const line = items[i];
        if (std.mem.eql(u8, line, "ANNOTATIONS")) {
            try writer.writeAll("ANNOTATIONS\n");
            i += 1;
            try emitAnnotations(allocator, items, &i, writer);
            continue;
        }
        if (std.mem.eql(u8, line, "ARTIFACTS")) {
            try writer.writeAll("ARTIFACTS\n");
            i += 1;
            while (i < items.len and !isSectionHeader(items[i]) and !isFooter(items[i])) : (i += 1) {
                if (items[i].len > 0) {
                    try writer.writeAll(items[i]);
                    try writer.writeByte('\n');
                }
            }
            continue;
        }
        if (line.len > 0 and isFooter(line) and !std.mem.startsWith(u8, line, "For more information")) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
        }
        i += 1;
    }
}

fn emitJobs(allocator: Allocator, items: []const []const u8, i: *usize, writer: *Writer) !void {
    var detail: std.ArrayList(u8) = .empty;
    defer detail.deinit(allocator);
    var passed: usize = 0;

    // Stop at the next section header *or* the footer: a run with no ANNOTATIONS
    // and no ARTIFACTS goes straight from JOBS to the footer, and those lines
    // must not be mistaken for failed jobs (they belong to the outer loop, which
    // drops the generic per-job hint).
    while (i.* < items.len and !isSectionHeader(items[i.*]) and !isFooter(items[i.*])) : (i.* += 1) {
        const line = items[i.*];
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "  ")) {
            // Stray indented step with no owning failed job — keep verbatim.
            try detail.appendSlice(allocator, line);
            try detail.append(allocator, '\n');
            continue;
        }
        if (std.mem.startsWith(u8, line, Sigil.pass ++ " ")) {
            passed += 1;
            continue;
        }
        // Non-passing top-level job: keep verbatim and fold its step list.
        try detail.appendSlice(allocator, line);
        try detail.append(allocator, '\n');
        try foldSteps(allocator, items, i, &detail);
        // foldSteps left i.* on the last step it consumed; the for-loop's
        // increment then advances past it.
    }

    if (passed > 0) {
        try writer.writeAll(Sigil.pass ++ " ");
        try util.writeDecimal(writer, passed);
        try writer.writeAll(" passed\n");
    }
    try writer.writeAll(detail.items);
}

/// Consume the indented (`  …`) step lines that follow a failed job, collapsing
/// passing steps to a count and keeping every non-passing step verbatim.
fn foldSteps(allocator: Allocator, items: []const []const u8, i: *usize, detail: *std.ArrayList(u8)) !void {
    var step_pass: usize = 0;
    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(allocator);

    while (i.* + 1 < items.len and std.mem.startsWith(u8, items[i.* + 1], "  ")) {
        i.* += 1;
        const step = std.mem.trimStart(u8, items[i.*], " ");
        if (std.mem.startsWith(u8, step, Sigil.pass ++ " ")) {
            step_pass += 1;
        } else {
            try kept.append(allocator, items[i.*]);
        }
    }

    if (step_pass > 0) {
        var buf: [20]u8 = undefined;
        try detail.appendSlice(allocator, "  " ++ Sigil.pass ++ " ");
        try detail.appendSlice(allocator, util.formatDecimal(&buf, step_pass));
        try detail.appendSlice(allocator, " steps passed\n");
    }
    for (kept.items) |step| {
        try detail.appendSlice(allocator, step);
        try detail.append(allocator, '\n');
    }
}

fn emitAnnotations(allocator: Allocator, items: []const []const u8, i: *usize, writer: *Writer) !void {
    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |*g| g.locs.deinit(allocator);
        groups.deinit(allocator);
    }

    while (i.* < items.len and !isSectionHeader(items[i.*]) and !isFooter(items[i.*])) {
        const line = items[i.*];
        if (line.len == 0) {
            i.* += 1;
            continue;
        }
        if (!isAnnotationMsg(line)) {
            // Unexpected free-standing line inside ANNOTATIONS — keep verbatim.
            try writer.writeAll(line);
            try writer.writeByte('\n');
            i.* += 1;
            continue;
        }
        const msg = line;
        i.* += 1;
        // The following non-blank, non-message line is the `job: ref` location.
        var loc: []const u8 = "";
        if (i.* < items.len and items[i.*].len > 0 and !isAnnotationMsg(items[i.*]) and
            !isSectionHeader(items[i.*]) and !isFooter(items[i.*]))
        {
            loc = jobOfLocation(items[i.*]);
            i.* += 1;
        }

        var found = false;
        for (groups.items) |*g| {
            if (std.mem.eql(u8, g.msg, msg)) {
                if (loc.len > 0) try g.locs.append(allocator, loc);
                found = true;
                break;
            }
        }
        if (!found) {
            var locs: std.ArrayList([]const u8) = .empty;
            // Owned by `locs` until `groups.append` succeeds; the groups defer
            // only frees what made it into the list, so guard the gap.
            errdefer locs.deinit(allocator);
            if (loc.len > 0) try locs.append(allocator, loc);
            try groups.append(allocator, .{ .msg = msg, .locs = locs });
        }
    }

    for (groups.items) |g| {
        try writer.writeAll(g.msg);
        if (g.locs.items.len == 1) {
            try writer.writeAll("  [");
            try writer.writeAll(g.locs.items[0]);
            try writer.writeByte(']');
        } else if (g.locs.items.len > 1) {
            try writer.writeAll("  [×");
            try util.writeDecimal(writer, g.locs.items.len);
            try writer.writeAll(": ");
            for (g.locs.items, 0..) |loc, idx| {
                if (idx > 0) try writer.writeAll(", ");
                try writer.writeAll(loc);
            }
            try writer.writeByte(']');
        }
        try writer.writeByte('\n');
    }
}

/// `test (ubuntu-latest): .github#2` → `test (ubuntu-latest)`.
fn jobOfLocation(loc: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, loc, ": ")) |idx| return loc[0..idx];
    return loc;
}

fn isAnnotationMsg(line: []const u8) bool {
    return std.mem.startsWith(u8, line, Sigil.warn ++ " ") or
        std.mem.startsWith(u8, line, Sigil.fail ++ " ");
}

fn isSectionHeader(line: []const u8) bool {
    return std.mem.eql(u8, line, "JOBS") or std.mem.eql(u8, line, "ANNOTATIONS") or
        std.mem.eql(u8, line, "ARTIFACTS");
}

fn isFooter(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "For more information") or
        std.mem.startsWith(u8, line, "To see what failed") or
        std.mem.startsWith(u8, line, "View this run on GitHub");
}

fn firstLine(input: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, input, '\n') orelse return input;
    return input[0..nl];
}

// ── tests ────────────────────────────────────────────────────────────────────
//
// Every fixture is real captured non-TTY output from this repo's own `gh`
// (see tests/fixtures/gh_*.txt), per the AGENTS.md no-synthetic-fixtures rule.

const testing = std.testing;

test "pr view folds number/state/title into a header, keeps non-empty fields and body" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyPrView(testing.allocator, @embedFile("fixture_gh_pr_view"), "", &out.writer);
    const got = out.written();

    // number + state + title collapse to one header line.
    try testing.expect(std.mem.startsWith(u8, got, "#67 MERGED feat(wrapper): re-dispatch"));
    // Non-empty metadata fields survive verbatim.
    try testing.expect(std.mem.indexOf(u8, got, "author:\tnkootstra (Niels Kootstra)\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "url:\thttps://github.com/nkootstra/smll/pull/67\n") != null);
    // Empty fields are dropped.
    try testing.expect(std.mem.indexOf(u8, got, "labels:") == null);
    try testing.expect(std.mem.indexOf(u8, got, "assignees:") == null);
    try testing.expect(std.mem.indexOf(u8, got, "milestone:") == null);
    // The folded fields no longer appear as their own `key:\t` lines.
    try testing.expect(std.mem.indexOf(u8, got, "title:\t") == null);
    try testing.expect(std.mem.indexOf(u8, got, "state:\tMERGED") == null);
    try testing.expect(std.mem.indexOf(u8, got, "number:\t67") == null);
    // Body prose is kept verbatim.
    try testing.expect(std.mem.indexOf(u8, got, "\n## What\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Safe shell streaming detection belongs to the streaming-mode work") != null);
}

test "pr view passes through non-metadata input unchanged" {
    const raw = "this is not gh pr view output\njust some text\n";
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyPrView(testing.allocator, raw, "", &out.writer);
    try testing.expectEqualStrings(raw, out.written());
}

test "pr checks collapses an all-pass table to a one-line aggregate" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyPrChecks(testing.allocator, @embedFile("fixture_gh_pr_checks"), "", &out.writer);
    try testing.expectEqualStrings("8 checks: 8 pass\n", out.written());
}

test "pr checks keeps non-passing rows verbatim under the aggregate" {
    // Real `gh pr checks` capture from this repo while a PR's CI was mid-run, so
    // the detail path is exercised on genuine pass+pending data.
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyPrChecks(testing.allocator, @embedFile("fixture_gh_pr_checks_pending"), "", &out.writer);
    const got = out.written();
    // pass is seen first, pending second; counts fold per state.
    try testing.expect(std.mem.startsWith(u8, got, "6 checks: 3 pass, 3 pending\n"));
    // Every pending row stays so the agent can click through to the live check.
    try testing.expect(std.mem.indexOf(u8, got, "Greptile Review\tpending\t0\thttps://greptile.com/") != null);
    try testing.expect(std.mem.indexOf(u8, got, "test (macos-latest)\tpending\t0\t") != null);
    try testing.expect(std.mem.indexOf(u8, got, "test (ubuntu-latest)\tpending\t0\t") != null);
    // Passing rows are folded away into the count.
    try testing.expect(std.mem.indexOf(u8, got, "fmt-check\tpass") == null);
    try testing.expect(std.mem.indexOf(u8, got, "Socket Security") == null);
}

test "pr checks passes through non-tabular input unchanged" {
    const raw = "no checks reported on this branch\n";
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyPrChecks(testing.allocator, raw, "", &out.writer);
    try testing.expectEqualStrings(raw, out.written());
}

test "run view collapses passing jobs and de-duplicates repeated annotations" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyRunView(testing.allocator, @embedFile("fixture_gh_run_view"), "", &out.writer);
    const got = out.written();

    // All five passing jobs collapse to a count.
    try testing.expect(std.mem.indexOf(u8, got, "JOBS\n✓ 5 passed\n") != null);
    // The deprecation warning, repeated once per job, de-duplicates to its two
    // distinct texts — one grouped across four jobs, one for size-gate.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, got, "Node.js 20 actions are deprecated"));
    try testing.expect(std.mem.indexOf(u8, got, "[×4: ") != null);
    try testing.expect(std.mem.indexOf(u8, got, "[size-gate]") != null);
    // Artifacts kept; footer keeps the URL, drops the generic per-job hint.
    // (The kept annotation text also contains "For more information see:", so the
    // footer check must target the footer line specifically, not the substring.)
    try testing.expect(std.mem.indexOf(u8, got, "ARTIFACTS\nsmll-linux\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "View this run on GitHub") != null);
    try testing.expect(std.mem.indexOf(u8, got, "For more information about a job") == null);
}

test "run view keeps the failing job, its failing steps, and error annotations" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyRunView(testing.allocator, @embedFile("fixture_gh_run_view_failed"), "", &out.writer);
    const got = out.written();

    // Passing jobs collapse; the failed job stays verbatim with its steps folded.
    try testing.expect(std.mem.indexOf(u8, got, "✓ 3 passed\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "X size-gate in 20s") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  ✓ 7 steps passed\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  X Enforce release size cap\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "  - Upload release artifact\n") != null);
    // The actionable failure signal must survive compaction.
    try testing.expect(std.mem.indexOf(u8, got, "X binary size 328152 exceeds release cap 327680") != null);
    try testing.expect(std.mem.indexOf(u8, got, "To see what failed") != null);
    // The four identical deprecation warnings collapse to a single grouped line.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, got, "Node.js 20 actions are deprecated"));
}

test "run view routes the footer correctly when JOBS is followed straight by it" {
    // A run with no ANNOTATIONS and no ARTIFACTS goes JOBS -> footer directly.
    // The footer lines must not be consumed as failed jobs: the generic per-job
    // hint is dropped and the run URL is kept.
    const input =
        "\n✓ main ci · 1\nTriggered via push about 4 minutes ago\n\n" ++
        "JOBS\n✓ test (ubuntu-latest) in 23s (ID 1)\n✓ fmt-check in 12s (ID 2)\n\n" ++
        "For more information about a job, try: gh run view --job=<job-id>\n" ++
        "View this run on GitHub: https://github.com/nkootstra/smll/actions/runs/1\n";
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyRunView(testing.allocator, input, "", &out.writer);
    const got = out.written();
    try testing.expect(std.mem.indexOf(u8, got, "JOBS\n✓ 2 passed\n") != null);
    try testing.expect(std.mem.indexOf(u8, got, "View this run on GitHub: https://github.com/nkootstra/smll/actions/runs/1") != null);
    // The generic hint is dropped, not emitted as a fake job row.
    try testing.expect(std.mem.indexOf(u8, got, "For more information about a job") == null);
}

test "run view passes through input with no JOBS section unchanged" {
    const raw = "X some other gh subcommand\nwith unexpected output\n";
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try applyRunView(testing.allocator, raw, "", &out.writer);
    try testing.expectEqualStrings(raw, out.written());
}
