const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub fn matches(input: []const u8) bool {
    _ = input;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    var kept: usize = 0;
    try scan(allocator, stdout, writer, &strip_buf, &kept);
    try scan(allocator, stderr, writer, &strip_buf, &kept);
    if (kept == 0 and stdout.len == 0 and stderr.len == 0) return;
}

fn scan(allocator: Allocator, input: []const u8, writer: *Writer, strip_buf: *std.ArrayList(u8), kept: *usize) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var in_diag = false;
    while (lines.next()) |raw| {
        if (raw.len == 0) {
            in_diag = false;
            continue;
        }
        const clean = ansi.stripInto(strip_buf, allocator, raw) catch raw;
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        if (shouldKeep(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            kept.* += 1;
            in_diag = isDiagnostic(line);
            continue;
        }
        // In `--pretty` mode a kept "error:"/"note:" line is followed by the
        // offending source line and a caret/underline line. The source line is
        // dropped, but the caret/underline carries the column span — keep it.
        if (in_diag and isCaretLine(line)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            kept.* += 1;
            // The caret closes the diagnostic block; clear the state so a later
            // stray all-^/~ line isn't carried along by residual in_diag.
            in_diag = false;
        }
    }
}

fn shouldKeep(line: []const u8) bool {
    return isDiagnostic(line) or
        std.mem.startsWith(u8, line, "Found ") or
        std.mem.startsWith(u8, line, "Success: ") or
        std.mem.startsWith(u8, line, "mypy: ");
}

fn isDiagnostic(line: []const u8) bool {
    return std.mem.indexOf(u8, line, ": error:") != null or
        std.mem.indexOf(u8, line, ": note:") != null;
}

/// True when the trimmed line is a non-empty run of `^`/`~` characters —
/// the caret/underline mypy emits under a diagnostic in `--pretty` mode.
fn isCaretLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0) return false;
    for (t) |c| if (c != '^' and c != '~') return false;
    return true;
}

test "mypy errors are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "src/a.py:10: error: Incompatible types [assignment]\n" ++
        "src/b.py:3: note: Revealed type is builtins.str\n" ++
        "Found 1 error in 1 file (checked 2 source files)\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}

test "mypy success summary is preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "Success: no issues found in 12 source files\n", "", &out.writer);
    try std.testing.expectEqualStrings("Success: no issues found in 12 source files\n", out.written());
}

test "mypy stderr diagnostics are preserved" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "mypy: can't read file 'missing.py': No such file or directory\n", &out.writer);
    try std.testing.expectEqualStrings("mypy: can't read file 'missing.py': No such file or directory\n", out.written());
}

test "mypy drops progress chatter" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "LOG:  Processing SCC\nsrc/a.py:1: error: bad [misc]\n", "", &out.writer);
    try std.testing.expectEqualStrings("src/a.py:1: error: bad [misc]\n", out.written());
}

test "ansi is stripped" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "\x1b[31msrc/a.py:1: error: bad [misc]\x1b[0m\n", "", &out.writer);
    try std.testing.expectEqualStrings("src/a.py:1: error: bad [misc]\n", out.written());
}

test "mypy --pretty keeps caret underline after error" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    const input =
        "src/a.py:10:5: error: Incompatible types in assignment  [assignment]\n" ++
        "    x: int = \"foo\"\n" ++
        "             ^~~~~\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    // The error line and its caret/underline context survive; the bare source
    // line in between is dropped.
    try std.testing.expect(std.mem.find(u8, got, ": error: Incompatible types") != null);
    try std.testing.expect(std.mem.find(u8, got, "^~~~~\n") != null);
    try std.testing.expect(std.mem.find(u8, got, "x: int =") == null);
}

test "mypy stray caret-shaped line after the diagnostic block is dropped" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    // One diagnostic + its caret underline, then an unrelated all-tilde line.
    // The caret consumes the in-diagnostic state, so the stray line must not
    // be carried along by residual state.
    const input =
        "src/a.py:1:5: error: bad [misc]\n" ++
        "    x = compute()\n" ++
        "    ^^^^^^^^^^^^^\n" ++
        "~~~~~~~\n";
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "^^^^^^^^^^^^^") != null);
    try std.testing.expect(std.mem.find(u8, got, "~~~~~~~\n") == null);
}
