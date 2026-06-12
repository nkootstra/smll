const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `ls -l` / `ls -la` — on by default (v0.6).
// Set SMLL_LOSSLESS=1 to bypass.
//
// Drops: permissions, link count, owner, group, size, date/time, the
// leading "total N" line.
// Keeps: filenames only, one per line, in original order. Directory vs file
// distinction is marked with a trailing "/" on dirs, matching ls -F behavior.
//
// Safety: if stdout contains non-empty content lines but the parser extracts
// zero filenames (e.g. eza/exa/lsd date format, non-English locale), returns
// `error.ParsedNothing` so the caller can fall back to raw passthrough.
// This prevents silently returning "(empty)" for non-empty directories.
//
// Contract:
//   • Lossy — permissions, ownership, size, timestamps gone.
//   • Filename list is preserved in order.
//   • Byte reduction typically ~80-85% on ls -la output.
//
// Detection (matches):
//   • First non-empty line starts with "total "; OR
//   • First non-empty line matches [dl-cb][rwx-]{9} (mode bits).

pub fn matches(input: []const u8) bool {
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (isTotalLine(line)) return true;
        return isLsLongLine(line);
    }
    return false;
}

fn isTotalLine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "total ")) return false;
    const rest = line["total ".len..];
    if (rest.len == 0) return false;
    for (rest) |b| {
        if (b < '0' or b > '9') return false;
    }
    return true;
}

fn isLsLongLine(line: []const u8) bool {
    if (line.len < 10) return false;
    const c0 = line[0];
    if (c0 != 'd' and c0 != '-' and c0 != 'l' and c0 != 'c' and c0 != 'b' and c0 != 'p' and c0 != 's') return false;
    for (line[1..10]) |b| {
        switch (b) {
            'r', 'w', 'x', '-', 's', 'S', 't', 'T' => {},
            else => return false,
        }
    }
    return true;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var first = true;
    var had_content_lines = false;
    var parsed_any = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (isTotalLine(line)) {
            had_content_lines = true;
            continue;
        }
        if (!isLsLongLine(line)) continue;
        had_content_lines = true;

        const name = extractName(line) orelse continue;
        if (name.len == 0) continue;
        parsed_any = true;
        // `.` and `..` always denote the current/parent directory — zero
        // information for an agent reading a listing. Drop them.
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!first) try writer.writeByte('\n');
        first = false;
        try writer.writeAll(name);
        if (line[0] == 'd') try writer.writeByte('/');
    }
    // Safety net: if we saw content lines (total or mode-prefixed) but
    // extracted zero filenames, the parser likely failed on an unexpected
    // format (eza/exa/lsd, non-English locale). Signal the caller to fall
    // back to raw passthrough instead of returning empty output. A directory
    // whose only entries are `.`/`..` parses fine (parsed_any) and correctly
    // yields empty output — that is not a parse failure.
    if (!parsed_any and had_content_lines) return error.ParsedNothing;
    if (!first) try writer.writeByte('\n');
}

/// Skip 8 whitespace-separated fields (mode, links, owner, group, size, mon, day, time/year).
/// Return the rest of the line (filename, which may contain spaces).
/// macOS ls -l may emit ACL markers ("@", "+") after mode — tokenizer ignores them
/// because the "@" sticks to the mode token.
fn extractName(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    var fields_consumed: usize = 0;
    while (i < line.len and fields_consumed < 8) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) return null;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
        fields_consumed += 1;
    }
    if (fields_consumed < 8) return null;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len) return null;
    return std.mem.trimEnd(u8, line[i..], " \t\r");
}

// ---------------------------------------------------------------------------
// Plain `ls` (no `-l`) — argv-gated normalizer, on by default (D-ls).
//
// Through smll's capture pipe `ls` writes to a non-TTY, so a single-directory
// listing is already one name per line. The value here is:
//   • `-C`/`-x`/`-m` columnar/comma layouts → split back to one name per line;
//   • multi-directory output (`ls a b`, `ls -R`) → collapse big sub-listings to
//     `dir/ (N entries: a, b, c)` while keeping the structure.
// `.`/`..` are dropped (zero information). A flat single-directory listing is
// never collapsed — a directory the caller asked to see is shown in full. The
// plain (non-`-C`/`-x`/`-m`) path is lossless apart from the explicit
// multi-directory collapse; column reflow is heuristic and a pathological name
// (≥2 interior spaces, or a literal ", ") can mis-split.
// ---------------------------------------------------------------------------

/// True when argv requests a multi-column / comma layout: a short flag `-C`,
/// `-x`, or `-m` (possibly in a cluster like `-xF`), or the long form
/// `--format=across|commas|horizontal|vertical`. Plain `ls` through a pipe is
/// already one-per-line, so without one of these we never see columns;
/// long-format output (`-l`, `--format=long`/`verbose`) is routed by `matches`
/// (content), not here. Other `--long` options take the non-columnar path.
pub fn wantsColumns(argv: []const []const u8) bool {
    for (argv) |a| {
        if (std.mem.startsWith(u8, a, "--format=")) {
            const v = a["--format=".len..];
            if (std.mem.eql(u8, v, "across") or std.mem.eql(u8, v, "commas") or
                std.mem.eql(u8, v, "horizontal") or std.mem.eql(u8, v, "vertical"))
                return true;
            continue;
        }
        if (a.len < 2 or a[0] != '-' or a[1] == '-') continue;
        for (a[1..]) |c| switch (c) {
            'C', 'x', 'm' => return true,
            else => {},
        };
    }
    return false;
}

fn isDotEntry(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

/// A listing is "blocked" (multiple directories) when a `header:` line appears
/// at the top or after a blank line AND the output contains an *interior* blank
/// line (content on both sides) — the shape `ls a b` and `ls -R` produce. A
/// flat single-directory listing has no interior blanks (filenames are
/// non-empty), so even a file named `backup:` at the top of a plain listing
/// stays in the flat path. The trailing newline every listing ends with is not
/// an interior blank, so it does not trip this.
fn looksLikeBlocks(stdout: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    var prev_blank = true;
    var saw_header = false;
    var saw_content = false;
    var pending_blank = false;
    var saw_interior_blank = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            prev_blank = true;
            if (saw_content) pending_blank = true;
            continue;
        }
        if (pending_blank) saw_interior_blank = true;
        pending_blank = false;
        // Require ≥1 char before the colon: a lone ":" is a (pathological)
        // filename, not a `dir:` header.
        if (prev_blank and line.len >= 2 and std.mem.endsWith(u8, line, ":")) saw_header = true;
        prev_blank = false;
        saw_content = true;
    }
    return saw_header and saw_interior_blank;
}

/// Split one columnar/comma row into names. Separators: tab, a run of ≥2
/// spaces (GNU `-C`/`-x` padding), or ", "/trailing "," (GNU `-m`). A single
/// space is kept inside a name (`hello world`) and a comma with no following
/// space stays in the name (`RCS,v`), so only genuine column/list gaps split.
/// Empty tokens dropped. Pathological names (≥2 interior spaces, or ", ") can
/// still mis-split — column reflow is heuristic, not lossless.
fn tokenizeInto(allocator: Allocator, line: []const u8, list: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    var start: ?usize = null;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ') {
            var j = i;
            while (j < line.len and line[j] == ' ') j += 1;
            if (j - i >= 2) {
                if (start) |s| {
                    try appendToken(allocator, list, line[s..i]);
                    start = null;
                }
            }
            // A single space inside a token is left attached; between tokens it
            // is skipped. Either way advance past the run.
            i = j;
            continue;
        }
        if (c == '\t') {
            if (start) |s| {
                try appendToken(allocator, list, line[s..i]);
                start = null;
            }
            i += 1;
            continue;
        }
        if (c == ',') {
            // `ls -m` joins names with ", " and, at a wrap, ends a line with a
            // bare ",". A comma NOT followed by a space (and not line-final) is
            // part of the filename (`RCS,v`, `a,b`) — leave it attached.
            const is_sep = (i + 1 == line.len) or line[i + 1] == ' ';
            if (is_sep) {
                if (start) |s| {
                    try appendToken(allocator, list, line[s..i]);
                    start = null;
                }
                i += 1;
                continue;
            }
        }
        if (start == null) start = i;
        i += 1;
    }
    if (start) |s| try appendToken(allocator, list, line[s..]);
}

fn appendToken(allocator: Allocator, list: *std.ArrayList([]const u8), raw: []const u8) !void {
    const t = std.mem.trim(u8, raw, " \t");
    if (t.len != 0) try list.append(allocator, t);
}

/// Restore alphabetical (byte) order after column splitting. `ls -C` lays
/// names out column-major, so reading a row at a time scrambles them; sorting
/// reproduces the one-per-line order plain `ls` would have emitted. The
/// wrapper forces `LC_ALL=C` on the child, so ls sorts in byte order too —
/// `std.mem.order` matches it exactly. Only applied when we split columns
/// (`columnar_hint`); a plain listing keeps ls's own order (`-t`, `-S`, `-r`).
fn sortNames(items: [][]const u8) void {
    std.sort.pdq([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
}

/// Plain-`ls` entry point. `columnar_hint` should be `wantsColumns(argv)`.
/// Returns `error.ParsedNothing` when a blocked listing yields no output for
/// non-empty input, so the caller can fall back to raw.
pub fn applyPlain(
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    writer: *Writer,
    columnar_hint: bool,
) !void {
    _ = stderr;
    if (stdout.len == 0) return;
    if (looksLikeBlocks(stdout))
        return applyBlocks(allocator, stdout, writer, columnar_hint);
    return applyFlat(allocator, stdout, writer, columnar_hint);
}

/// Single-directory listing → one name per line, `.`/`..` dropped. Never
/// collapses; with `columnar_hint` each row is split back into its names.
///
/// Unlike `applyBlocks`, this never returns `error.ParsedNothing`: a flat
/// listing has no structured format to misparse, so empty output can only mean
/// every entry was a dropped `.`/`..` (a genuinely empty dir) — the correct
/// result, not a parse failure. (`apply` for `ls -l` treats this case the same.)
fn applyFlat(allocator: Allocator, stdout: []const u8, writer: *Writer, columnar_hint: bool) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (columnar_hint) {
            try tokenizeInto(allocator, line, &names);
        } else {
            // Non-columnar: plain `ls` through the pipe is already one name per
            // line with no padding, so keep the line verbatim — trimming
            // trailing spaces would corrupt a name that legitimately ends in
            // one. (`line` is already stripped of a trailing `\r`.)
            try names.append(allocator, line);
        }
    }

    if (columnar_hint) sortNames(names.items);

    var first = true;
    for (names.items) |name| {
        if (isDotEntry(name)) continue;
        if (!first) try writer.writeByte('\n');
        first = false;
        try writer.writeAll(name);
    }
    if (!first) try writer.writeByte('\n');
}

/// Multi-directory listing (`ls a b`, `ls -R`). Each `header:` opens a
/// segment; a header with ≥3 entries collapses to `header/ (N entries: a, b,
/// c)`, smaller segments emit `header/<entry>` per line, and the headerless
/// top block of `ls -R` is emitted one name per line (we have no label to
/// collapse it under). `.`/`..` dropped throughout.
fn applyBlocks(allocator: Allocator, stdout: []const u8, writer: *Writer, columnar_hint: bool) !void {
    var header: ?[]const u8 = null;
    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);

    var first = true;
    var prev_blank = true;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) {
            prev_blank = true;
            continue;
        }
        if (prev_blank and line.len >= 2 and std.mem.endsWith(u8, line, ":")) {
            if (columnar_hint) sortNames(entries.items);
            try flushSegment(writer, header, entries.items, &first);
            header = line[0 .. line.len - 1];
            entries.clearRetainingCapacity();
            prev_blank = false;
            continue;
        }
        prev_blank = false;
        if (columnar_hint) {
            try tokenizeInto(allocator, line, &entries);
        } else {
            try entries.append(allocator, line); // verbatim; see applyFlat
        }
    }
    if (columnar_hint) sortNames(entries.items);
    try flushSegment(writer, header, entries.items, &first);

    if (first) return error.ParsedNothing;
    try writer.writeByte('\n');
}

fn flushSegment(writer: *Writer, header: ?[]const u8, entries: []const []const u8, first: *bool) !void {
    var real: usize = 0;
    for (entries) |e| {
        if (!isDotEntry(e)) real += 1;
    }
    // Empty segment (an empty subdir under `ls -R`, or a dir with only `.`/`..`)
    // emits nothing. The directory still appears as an entry in its parent's
    // listing, so its existence is not lost — only the redundant empty
    // expansion is dropped. (Emitting a marker here would also require buffering
    // to preserve the "ParsedNothing ⟹ nothing written yet" fallback contract.)
    if (real == 0) return;

    const h = header orelse {
        // Headerless top block (ls -R) — one name per line, never collapse.
        for (entries) |e| {
            if (isDotEntry(e)) continue;
            try newline(writer, first);
            try writer.writeAll(e);
        }
        return;
    };

    if (real >= 3) {
        try newline(writer, first);
        try writer.writeAll(h);
        try writer.writeAll("/ (");
        try writer.print("{d}", .{real});
        try writer.writeAll(" entries: ");
        var shown: usize = 0;
        for (entries) |e| {
            if (isDotEntry(e)) continue;
            if (shown == 3) break;
            if (shown > 0) try writer.writeAll(", ");
            try writer.writeAll(e);
            shown += 1;
        }
        try writer.writeByte(')');
    } else {
        for (entries) |e| {
            if (isDotEntry(e)) continue;
            try newline(writer, first);
            try writer.writeAll(h);
            try writer.writeByte('/');
            try writer.writeAll(e);
        }
    }
}

fn newline(writer: *Writer, first: *bool) !void {
    if (!first.*) try writer.writeByte('\n');
    first.* = false;
}

test "matches: total line" {
    try std.testing.expect(matches("total 24\n-rw-r--r-- 1 a b 1 Apr 1 00:00 x\n"));
}

test "matches: bare mode line" {
    try std.testing.expect(matches("drwxr-xr-x 1 a b 1 Apr 1 00:00 d\n"));
}

test "matches: rejects non-ls" {
    try std.testing.expect(!matches("hello world\n"));
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("total abc\n"));
}

test "apply: fixture produces filename list" {
    const fixture = @embedFile("fixture_ls_la");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, fixture, &.{}, &out.writer);
    const got = out.written();

    try std.testing.expect(std.mem.find(u8, got, "main.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "pipeline.zig") != null);
    try std.testing.expect(std.mem.find(u8, got, "filters/") != null);
    // `.` and `..` entries are dropped (zero information).
    try std.testing.expect(std.mem.find(u8, got, "./") == null);
    try std.testing.expect(std.mem.find(u8, got, "../") == null);
    // Ensure metadata stripped
    try std.testing.expect(std.mem.find(u8, got, "nielskootstra") == null);
    try std.testing.expect(std.mem.find(u8, got, "total") == null);
}

test "apply: . and .. entries dropped (zero information)" {
    // `.` and `..` always refer to the current/parent dir — no information for
    // an agent reading a listing. Drop them; keep real entries.
    const input = "total 64\n" ++
        "drwxr-xr-x  6 u s 192 Apr 19 08:25 .\n" ++
        "drwxr-xr-x 13 u s 416 Apr 19 08:19 ..\n" ++
        "drwxr-xr-x 22 u s 704 Apr 19 08:21 filters\n" ++
        "-rw-r--r--  1 u s 132 Apr 19 08:25 main.zig\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("filters/\nmain.zig\n", out.written());
}

test "apply: empty dir (only . and ..) yields empty output, not ParsedNothing" {
    // An empty directory's `ls -la` lists only `.`/`..`. After dropping both,
    // empty output is correct — it must NOT be mistaken for a parse failure.
    const input = "total 0\n" ++
        "drwxr-xr-x 2 u s 64 Apr 1 00:00 .\n" ++
        "drwxr-xr-x 3 u s 96 Apr 1 00:00 ..\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: dir literally named '...' is preserved" {
    // Only exact `.` and `..` are dropped; a dir named "..." is a real entry.
    const input = "drwxr-xr-x 1 u s 0 Apr 1 00:00 ...\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings(".../\n", out.written());
}

test "apply: filename with spaces preserved" {
    const input = "-rw-r--r-- 1 a b 1 Apr 1 00:00 hello world.txt\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("hello world.txt\n", out.written());
}

test "apply: eza day-first date format triggers ParsedNothing" {
    // eza uses day-first dates: "22 Apr 14:30" vs POSIX "Apr 22 14:30".
    // The extra field shifts the name column; extractName returns null for
    // every line → ParsedNothing so caller can fall back.
    const input = "total 8\n" ++
        "drwxr-xr-x  - user 22 Apr 14:30 src\n" ++
        "-rw-r--r--  1 user 22 Apr 14:30 README.md\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const result = apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectError(error.ParsedNothing, result);
}

test "apply: empty stdout produces no output (no ParsedNothing)" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", &.{}, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: all file types handled" {
    // Verify character device, block device, pipe, socket don't get dropped
    const input = "crw-rw-rw- 1 root wheel 0 Apr 23 12:00 /dev/null\n" ++
        "brw-r----- 1 root disk 8 Apr 23 12:00 /dev/sda\n" ++
        "prw-r--r-- 1 user staff 0 Apr 23 12:00 mypipe\n" ++
        "srwxrwxrwx 1 user staff 0 Apr 23 12:00 mysocket\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "/dev/null") != null);
    try std.testing.expect(std.mem.find(u8, got, "/dev/sda") != null);
    try std.testing.expect(std.mem.find(u8, got, "mypipe") != null);
    try std.testing.expect(std.mem.find(u8, got, "mysocket") != null);
}

// --- plain `ls` (no -l) tests ---------------------------------------------

test "wantsColumns: -C/-x/-m (incl. clusters) yes; long/one-col no" {
    try std.testing.expect(wantsColumns(&.{ "ls", "-C", "src" }));
    try std.testing.expect(wantsColumns(&.{ "ls", "-x" }));
    try std.testing.expect(wantsColumns(&.{ "ls", "-m" }));
    try std.testing.expect(wantsColumns(&.{ "ls", "-xF" })); // cluster
    // GNU long-form equivalents of -m/-x/-C.
    try std.testing.expect(wantsColumns(&.{ "ls", "--format=commas" }));
    try std.testing.expect(wantsColumns(&.{ "ls", "--format=across", "src" }));
    try std.testing.expect(wantsColumns(&.{ "ls", "--format=horizontal" }));
    try std.testing.expect(wantsColumns(&.{ "ls", "--format=vertical" }));
    try std.testing.expect(!wantsColumns(&.{ "ls", "-la" }));
    try std.testing.expect(!wantsColumns(&.{ "ls", "-1" }));
    try std.testing.expect(!wantsColumns(&.{ "ls", "src" }));
    try std.testing.expect(!wantsColumns(&.{ "ls", "--color=auto" }));
    try std.testing.expect(!wantsColumns(&.{ "ls", "--format=long" }));
    try std.testing.expect(!wantsColumns(&.{ "ls", "--format=single-column" }));
}

test "applyPlain: -C column-major split → sorted one name per line" {
    const fixture = @embedFile("fixture_ls_columns");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, fixture, &.{}, &out.writer, true);
    // `ls -C` lays names out column-major; the normalizer re-sorts so the
    // result is the same one-per-line list plain `ls` would have printed.
    try std.testing.expectEqualStrings(
        "filter_catalog.zig\nfilters\nhistory.zig\nmain.zig\npipe_filters.zig\n" ++
            "pipeline.zig\nsetup.zig\nsetup_hooks.zig\nsetup_io.zig\nsetup_json.zig\n" ++
            "signals.zig\nstats.zig\ntee.zig\nutil.zig\nwrapper.zig\nwrapper_git.zig\n" ++
            "wrapper_io.zig\nwrapper_util.zig\n",
        out.written(),
    );
}

test "applyPlain: -m comma layout (wrapped) → one name per line" {
    const fixture = @embedFile("fixture_ls_comma");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, fixture, &.{}, &out.writer, true);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, ",") == null);
    try std.testing.expect(std.mem.find(u8, got, "filter_catalog.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "wrapper.zig\n") != null);
    try std.testing.expectEqual(@as(usize, 18), std.mem.count(u8, got, "\n"));
}

test "applyPlain: -m comma inside a filename is not split" {
    // `ls -m` separates with ", "; a comma that is part of a name (RCS `,v`,
    // archives like `a,b`) has no following space and must stay attached.
    const input = "RCS,v, README, a,b\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, input, &.{}, &out.writer, true);
    try std.testing.expectEqualStrings("RCS,v\nREADME\na,b\n", out.written());
}

test "applyPlain: trailing space in a name is preserved (non-columnar)" {
    // Plain `ls` through the pipe emits names verbatim; a name that ends in a
    // space must not be silently trimmed.
    const input = "weird name \nnormal\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, input, &.{}, &out.writer, false);
    try std.testing.expectEqualStrings("weird name \nnormal\n", out.written());
}

test "applyPlain: a lone ':' header is treated as a name, not a block header" {
    // `ls : real` where `:` is a real directory: a lone ":" must not become an
    // empty-named `/ (N entries: ...)` collapse. It stays an ordinary entry;
    // the genuine `real:` header still collapses its (small) segment.
    const input = ":\nfoo\nbar\nbaz\n\nreal:\nqux\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, input, &.{}, &out.writer, false);
    try std.testing.expectEqualStrings(":\nfoo\nbar\nbaz\nreal/qux\n", out.written());
}

test "applyPlain: flat non-columnar passthrough drops . and .." {
    // `ls -a` through the pipe: already one-per-line, hint off. `.`/`..` go,
    // every other name stays verbatim and uncollapsed.
    const input = ".\n..\n.gitignore\nREADME.md\nsrc\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, input, &.{}, &out.writer, false);
    try std.testing.expectEqualStrings(".gitignore\nREADME.md\nsrc\n", out.written());
}

test "applyPlain: tokenizer keeps single-space names (sorted)" {
    // Tabs/≥2-space gaps separate columns; a single space stays inside a name.
    // Output is sorted (column split → alphabetical, like plain `ls`).
    const input = "hello world\tfoo\tbar baz\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, input, &.{}, &out.writer, true);
    try std.testing.expectEqualStrings("bar baz\nfoo\nhello world\n", out.written());
}

test "applyPlain: multi-operand blocks collapse each dir (≥3)" {
    const fixture = @embedFile("fixture_ls_multi_dir");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, fixture, &.{}, &out.writer, false);
    const got = out.written();
    // docs: 9 entries, src: 18 entries — both ≥3 → collapse with 3 examples.
    try std.testing.expectEqualStrings(
        "docs/ (9 entries: audit.md, audits, brainstorms)\n" ++
            "src/ (18 entries: filter_catalog.zig, filters, history.zig)\n",
        got,
    );
}

test "applyPlain: ls -R headerless top stays full, subdir collapses" {
    const fixture = @embedFile("fixture_ls_recursive");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, fixture, &.{}, &out.writer, false);
    const got = out.written();
    // Top block (no header) shown one-per-line, in full.
    try std.testing.expect(std.mem.find(u8, got, "filter_catalog.zig\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "wrapper.zig\n") != null);
    // Subdir block collapses under its full-path header.
    try std.testing.expect(std.mem.find(u8, got, "src/filters/ (") != null);
    try std.testing.expect(std.mem.find(u8, got, " entries: ansi.zig, ") != null);
    try std.testing.expect(got.len < fixture.len);
}

test "applyPlain: small block (<3 entries) emits paths, not a collapse" {
    const input = "a:\nx\ny\n\nb:\np\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, input, &.{}, &out.writer, false);
    try std.testing.expectEqualStrings("a/x\na/y\nb/p\n", out.written());
}

test "applyPlain: block listing that parses to nothing → ParsedNothing" {
    // Two empty headered blocks (blank-separated) must not silently swallow
    // output — signal the caller so it can fall back to raw.
    const input = "a:\n\nb:\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const result = applyPlain(std.testing.allocator, input, &.{}, &out.writer, false);
    try std.testing.expectError(error.ParsedNothing, result);
}

test "applyPlain: flat listing with a file named 'backup:' is not blocked" {
    // A colon-terminated FIRST name in a flat listing (no blank lines) must
    // stay in the flat path, not be mistaken for a `header:`.
    const input = "backup:\nfoo\nzed\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, input, &.{}, &out.writer, false);
    try std.testing.expectEqualStrings("backup:\nfoo\nzed\n", out.written());
}

test "applyPlain: empty stdout → empty output, no error" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try applyPlain(std.testing.allocator, "", &.{}, &out.writer, false);
    try std.testing.expectEqualStrings("", out.written());
}
