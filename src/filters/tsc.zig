const std = @import("std");
const ansi = @import("ansi");
const signals = @import("signals");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for TypeScript compiler (`tsc`) — on by default
// (v0.6). Set SMLL_LOSSLESS=1 to bypass.
//
// Per-error compression: each error reduces to `path:L:C TSnnnn: <message>` —
// the " - error " boilerplate is dropped but code + location + message remain.
//
// Code folding: when >=3 errors share the same TS code AND the same message
// (a systematic-error/migration sweep), they collapse to one header line plus
// one representative message:
//   TS2322 x7: src/a.ts:42:5, src/b.ts:15:7, src/c.ts:8:3, ... (4 more)
//   Type 'string' is not assignable to type 'number'.
// Codes appearing <=2 times keep full per-error lines. Same-code errors whose
// messages differ (first 40 chars) are NOT folded — a single representative
// message would lose signal — so they keep full per-error lines too.
//
// Keeps: transformed/folded error lines, the "Found N errors" summary.
// Drops: blank-line padding, code-context/caret lines, per-file count tables,
//        and (in folds) locations past the first 3 + duplicate messages.
//
// If no "error TS" lines present, emits "no type errors\n".
//
// Detection: input contains "error TS" OR ends with "Found " + "error" summary.

/// Superset gate for the pipe dispatcher: every match-path needs "error TS" or
/// "Found ", so a false gate guarantees `matches()` is false. See
/// src/signals.zig.
pub fn sigGate(s: signals.Signals) bool {
    return s.tsc();
}

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "error TS") != null) return true;
    if (std.mem.find(u8, input, "Found 0 errors") != null) return true;
    // Multi-error summary
    if (std.mem.find(u8, input, " errors in ") != null and
        std.mem.find(u8, input, "Found ") != null) return true;
    return false;
}

/// A parsed `path:L:C - error TSnnnn: <message>` diagnostic. All slices point
/// into an arena-owned stable copy of the line (the per-line strip buffer is
/// reused, so we cannot hold slices into it directly).
const Diag = struct {
    loc: []const u8, // "path:L:C"
    rest: []const u8, // "TSnnnn: <message>" (verbatim, for per-error output)
    code: []const u8, // "TSnnnn" (slice of rest)
    msg: []const u8, // trimmed message (slice of rest)
};

/// Number of example locations shown before collapsing the rest into "(N more)".
const fold_examples: usize = 3;
/// Messages are compared on their first `msg_key_len` bytes to decide whether a
/// same-code group is homogeneous enough to fold.
const msg_key_len: usize = 40;

pub const WatchLineResult = enum { ignored, emitted, clean };

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    // Arena holds stable copies of kept lines; deinit frees them all at once.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diags: std.ArrayList(Diag) = .empty;
    defer diags.deinit(allocator);
    var raw_lines: std.ArrayList([]const u8) = .empty;
    defer raw_lines.deinit(allocator);
    var summaries: std.ArrayList([]const u8) = .empty;
    defer summaries.deinit(allocator);

    try collect(allocator, arena, stdout, &diags, &raw_lines, &summaries);
    try collect(allocator, arena, stderr, &diags, &raw_lines, &summaries);

    if (diags.items.len == 0 and raw_lines.items.len == 0 and summaries.items.len == 0) {
        try writer.writeAll("no type errors\n");
        return;
    }

    try emitGrouped(allocator, writer, diags.items);
    for (raw_lines.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
    for (summaries.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

pub fn writeWatchLine(
    strip_buf: *std.ArrayList(u8),
    allocator: Allocator,
    raw: []const u8,
    writer: *Writer,
) !WatchLineResult {
    const line = ansi.stripInto(strip_buf, allocator, raw) catch raw;
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return .ignored;
    if (isFoundZeroSummary(trimmed)) return .clean;
    if (isFoundSummary(trimmed)) {
        try writer.writeAll(trimmed);
        try writer.writeByte('\n');
        return .emitted;
    }

    const marker = " - error TS";
    if (std.mem.find(u8, trimmed, marker)) |idx| {
        const rest = trimmed[idx + " - error ".len ..];
        if (std.mem.findScalar(u8, rest, ':') != null) {
            try writer.writeAll(trimmed[0..idx]);
            try writer.writeByte(' ');
            try writer.writeAll(rest);
            try writer.writeByte('\n');
            return .emitted;
        }
    }
    if (std.mem.find(u8, trimmed, "error TS") != null) {
        try writer.writeAll(trimmed);
        try writer.writeByte('\n');
        return .emitted;
    }
    return .ignored;
}

/// Parse one stream's lines into buffered diagnostics, path-less fallbacks, and
/// "Found N errors" summaries. Caret/context/table lines are dropped.
fn collect(
    allocator: Allocator,
    arena: Allocator,
    input: []const u8,
    diags: *std.ArrayList(Diag),
    raw_lines: *std.ArrayList([]const u8),
    summaries: *std.ArrayList([]const u8),
) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    while (lines.next()) |raw| {
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (isFoundSummary(trimmed)) {
            try summaries.append(allocator, try arena.dupe(u8, trimmed));
            continue;
        }
        const marker = " - error TS";
        if (std.mem.find(u8, trimmed, marker)) |idx| {
            const stable = try arena.dupe(u8, trimmed);
            const loc = stable[0..idx];
            const rest = stable[idx + " - error ".len ..]; // "TSnnnn: <message>"
            if (std.mem.findScalar(u8, rest, ':')) |colon| {
                try diags.append(allocator, .{
                    .loc = loc,
                    .rest = rest,
                    .code = rest[0..colon],
                    .msg = std.mem.trim(u8, rest[colon + 1 ..], " \t"),
                });
                continue;
            }
            // No "TSnnnn:" colon — keep verbatim rather than mis-parse.
            try raw_lines.append(allocator, stable);
            continue;
        }
        // Some tsc modes emit `error TS` without a leading path (rare). Keep
        // verbatim to preserve signal.
        if (std.mem.find(u8, trimmed, "error TS") != null) {
            try raw_lines.append(allocator, try arena.dupe(u8, trimmed));
        }
    }
}

/// Emit diagnostics grouped by TS code in first-appearance order. A group of
/// >=3 with homogeneous messages folds; everything else emits full per-error
/// `path:L:C TSnnnn: <message>` lines (boilerplate dropped).
///
/// The `emitted` skip means the inner rescan runs once per *distinct* code, so
/// the cost is O(U x N) where U is the number of distinct TS codes — bounded by
/// TypeScript's fixed ~few-hundred diagnostic vocabulary regardless of N. That
/// is effectively linear in N for real output; the apparent N^2 worst case (N
/// distinct codes) is unreachable. We keep this index-free form deliberately: a
/// StringHashMap(usize) here is a fresh monomorphization that pushes the
/// ReleaseSmall x86_64 binary over the hard 320 KiB release cap.
fn emitGrouped(allocator: Allocator, writer: *Writer, diags: []const Diag) !void {
    if (diags.len == 0) return;
    const emitted = try allocator.alloc(bool, diags.len);
    defer allocator.free(emitted);
    @memset(emitted, false);

    var group: std.ArrayList(usize) = .empty;
    defer group.deinit(allocator);

    for (diags, 0..) |d, i| {
        if (emitted[i]) continue;
        group.clearRetainingCapacity();
        for (diags, 0..) |e, j| {
            if (std.mem.eql(u8, e.code, d.code)) {
                try group.append(allocator, j);
                emitted[j] = true;
            }
        }
        const items = group.items;
        if (items.len >= 3 and messagesHomogeneous(diags, items)) {
            try writer.writeAll(d.code);
            try writer.writeAll(" x");
            try ansi.writeDecimal(writer, items.len);
            try writer.writeAll(": ");
            for (items[0..@min(fold_examples, items.len)], 0..) |gi, n| {
                if (n > 0) try writer.writeAll(", ");
                try writer.writeAll(diags[gi].loc);
            }
            if (items.len > fold_examples) {
                try writer.writeAll(", ... (");
                try ansi.writeDecimal(writer, items.len - fold_examples);
                try writer.writeAll(" more)");
            }
            try writer.writeByte('\n');
            if (d.msg.len > 0) { // representative = first occurrence
                try writer.writeAll(d.msg);
                try writer.writeByte('\n');
            }
        } else {
            for (items) |gi| {
                const g = diags[gi];
                try writer.writeAll(g.loc);
                try writer.writeByte(' ');
                try writer.writeAll(g.rest);
                try writer.writeByte('\n');
            }
        }
    }
}

/// True when every diagnostic in `group` shares the same message prefix (first
/// `msg_key_len` bytes), i.e. folding to one representative message is safe.
fn messagesHomogeneous(diags: []const Diag, group: []const usize) bool {
    const key = msgKey(diags[group[0]].msg);
    for (group[1..]) |gi| {
        if (!std.mem.eql(u8, msgKey(diags[gi].msg), key)) return false;
    }
    return true;
}

fn msgKey(msg: []const u8) []const u8 {
    return msg[0..@min(msg_key_len, msg.len)];
}

fn isFoundSummary(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "Found ") and
        std.mem.find(u8, line, "error") != null;
}

fn isFoundZeroSummary(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "Found 0 errors");
}

test "matches: error TS line" {
    try std.testing.expect(matches("src/a.ts:4:5 - error TS2322: Type 'x' ...\n"));
}

test "matches: Found 0 errors" {
    try std.testing.expect(matches("Found 0 errors. Watching for file changes.\n"));
}

test "matches: rejects non-tsc" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello\n"));
}

test "apply: fixture compresses errors to locations + codes" {
    const input = @embedFile("fixture_tsc_errors");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // Transformed form: path:L:C TSnnnn: message (boilerplate " - error " removed).
    try std.testing.expect(std.mem.find(u8, got, "src/api/client.ts:42:5 TS2322: Type 'string' is not assignable") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/api/client.ts:58:12 TS2339") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/components/Button.tsx:15:7 TS2345") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/utils/format.ts:8:3 TS7006") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/utils/format.ts:14:10 TS2304") != null);
    try std.testing.expect(std.mem.find(u8, got, "Found 5 errors in 3 files.") != null);
    // Message text is preserved (agents need it for understanding errors).
    try std.testing.expect(std.mem.find(u8, got, "is not assignable") != null);
    // Boilerplate " - error TS" prefix removed.
    try std.testing.expect(std.mem.find(u8, got, "- error TS") == null);
    // Caret and code-context lines dropped.
    try std.testing.expect(std.mem.find(u8, got, "~~~~~~") == null);
    try std.testing.expect(std.mem.find(u8, got, "return response;") == null);
    try std.testing.expect(std.mem.find(u8, got, "Errors  Files") == null);
}

test "apply: no errors emits 'no type errors'" {
    const input = "Found 0 errors. Watching for file changes.\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // "Found 0 errors" is kept as a positive signal rather than collapsed.
    try std.testing.expect(std.mem.find(u8, got, "Found 0 errors") != null);
}

test "apply: strips ANSI" {
    const input = "\x1b[31msrc/a.ts:1:1\x1b[0m - error TS2322: x\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, out.written(), "src/a.ts:1:1 TS2322: x") != null);
}

test "writeWatchLine: compacts diagnostics and reports clean transitions" {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(std.testing.allocator);
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectEqual(WatchLineResult.ignored, try writeWatchLine(
        &strip_buf,
        std.testing.allocator,
        "[12:00:00 AM] Starting compilation in watch mode...",
        &out.writer,
    ));
    try std.testing.expectEqual(WatchLineResult.emitted, try writeWatchLine(
        &strip_buf,
        std.testing.allocator,
        "src/app.ts:1:7 - error TS2322: Type 'string' is not assignable to type 'number'.",
        &out.writer,
    ));
    try std.testing.expectEqual(WatchLineResult.ignored, try writeWatchLine(
        &strip_buf,
        std.testing.allocator,
        "        ~",
        &out.writer,
    ));
    try std.testing.expectEqual(WatchLineResult.clean, try writeWatchLine(
        &strip_buf,
        std.testing.allocator,
        "Found 0 errors. Watching for file changes.",
        &out.writer,
    ));
    try std.testing.expectEqualStrings(
        "src/app.ts:1:7 TS2322: Type 'string' is not assignable to type 'number'.\n",
        out.written(),
    );
}

test "apply: malformed error line falls back to raw" {
    // No " - error TS" separator — keep as-is so we don't silently drop signal.
    const input = "weird: error TS9999 something went wrong\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expect(std.mem.find(u8, out.written(), "error TS9999") != null);
}

test "apply: >=3 same-code errors with identical messages fold to one line" {
    // Systematic-error run: same TS code repeated across many files with the
    // same message — fold into one header + one representative message.
    const input =
        "src/a.ts:1:1 - error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "src/b.ts:2:2 - error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "src/c.ts:3:3 - error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "src/d.ts:4:4 - error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "src/e.ts:5:5 - error TS2304: Cannot find name 'foo'.\n" ++
        "Found 5 errors in 5 files.\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // Folded header: count + first 3 locations + "(N more)".
    try std.testing.expect(std.mem.find(u8, got, "TS2322 x4: src/a.ts:1:1, src/b.ts:2:2, src/c.ts:3:3, ... (1 more)") != null);
    // Representative message kept once, on its own line.
    try std.testing.expect(std.mem.find(u8, got, "Type 'string' is not assignable to type 'number'.") != null);
    // 4th location is elided into the "(1 more)" count, not emitted as a full line.
    try std.testing.expect(std.mem.find(u8, got, "src/d.ts:4:4") == null);
    // Singleton code keeps its full per-error line.
    try std.testing.expect(std.mem.find(u8, got, "src/e.ts:5:5 TS2304: Cannot find name 'foo'.") != null);
    // Summary preserved.
    try std.testing.expect(std.mem.find(u8, got, "Found 5 errors in 5 files.") != null);
}

test "apply: exactly 2 same-code errors stay unfolded (below the >=3 threshold)" {
    // Boundary guard: a code appearing exactly twice must keep full per-error
    // lines, never fold — protects the `>= 3` threshold from drifting to 2.
    const input =
        "src/a.ts:1:1 - error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "src/b.ts:2:2 - error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "Found 2 errors in 2 files.\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // No fold header at 2 occurrences.
    try std.testing.expect(std.mem.find(u8, got, "TS2322 x2:") == null);
    // Both errors keep their full per-error lines.
    try std.testing.expect(std.mem.find(u8, got, "src/a.ts:1:1 TS2322: Type 'string' is not assignable") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/b.ts:2:2 TS2322: Type 'string' is not assignable") != null);
    try std.testing.expect(std.mem.find(u8, got, "Found 2 errors in 2 files.") != null);
}

test "apply: >=3 same-code errors with differing messages are NOT folded" {
    // Same TS code but each message differs — folding to one representative
    // message would lose signal, so keep full per-error lines instead.
    const input =
        "src/a.ts:1:1 - error TS2322: Type 'string' is not assignable to type 'number'.\n" ++
        "src/b.ts:2:2 - error TS2322: Object is possibly 'undefined' in this branch.\n" ++
        "src/c.ts:3:3 - error TS2322: Property 'widget' does not exist on the model.\n" ++
        "Found 3 errors in 3 files.\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    // No fold header when messages diverge.
    try std.testing.expect(std.mem.find(u8, got, "TS2322 x3:") == null);
    // Every error retains its full per-error line.
    try std.testing.expect(std.mem.find(u8, got, "src/a.ts:1:1 TS2322: Type 'string' is not assignable") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/b.ts:2:2 TS2322: Object is possibly 'undefined'") != null);
    try std.testing.expect(std.mem.find(u8, got, "src/c.ts:3:3 TS2322: Property 'widget' does not exist") != null);
}
