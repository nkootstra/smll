const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for Gradle output. Keeps failed tasks, failure causes,
// compiler/test diagnostics, reports, and build summaries. Drops successful
// task progress, UP-TO-DATE chatter, and Gradle rerun suggestions.

pub fn matches(input: []const u8) bool {
    if (std.mem.find(u8, input, "BUILD FAILED") != null) return true;
    if (std.mem.find(u8, input, "BUILD SUCCESSFUL") != null) return true;
    if (std.mem.find(u8, input, "FAILURE: Build failed") != null) return true;
    if (std.mem.find(u8, input, "> Task ") != null) return true;
    if (std.mem.find(u8, input, " tests completed") != null) return true;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var state: ScanState = .{};
    try scan(allocator, stdout, &out, &state);
    try scan(allocator, stderr, &out, &state);

    if (out.items.len == 0) {
        try writer.writeAll("gradle ok\n");
        return;
    }
    try writer.writeAll(out.items);
}

const ScanState = struct {
    in_cause_block: bool = false,
    after_failure_context: usize = 0,
};

fn scan(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), state: *ScanState) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);

    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) {
            state.in_cause_block = false;
            state.after_failure_context = 0;
            continue;
        }

        if (std.mem.startsWith(u8, line, "* Try:")) {
            state.in_cause_block = false;
            state.after_failure_context = 0;
            continue;
        }

        if (shouldKeep(line)) {
            try appendLine(allocator, out, line);
            if (std.mem.eql(u8, line, "* What went wrong:") or
                std.mem.startsWith(u8, line, "Execution failed"))
            {
                state.in_cause_block = true;
            }
            if (isFailureHeader(line) or isExceptionLine(line)) {
                state.after_failure_context = 3;
            }
            continue;
        }

        if (state.in_cause_block and isCauseContext(line)) {
            try appendLine(allocator, out, line);
            continue;
        }

        if (state.after_failure_context > 0 and isFailureContext(line)) {
            try appendLine(allocator, out, line);
            state.after_failure_context -= 1;
            continue;
        }
    }
}

fn shouldKeep(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "> Task ") and std.mem.find(u8, line, "FAILED") != null) return true;
    if (std.mem.startsWith(u8, line, "FAILURE:")) return true;
    if (std.mem.eql(u8, line, "* What went wrong:")) return true;
    if (std.mem.startsWith(u8, line, "Execution failed")) return true;
    if (std.mem.startsWith(u8, line, "> Compilation error")) return true;
    if (std.mem.startsWith(u8, line, "e: ") or std.mem.startsWith(u8, line, "w: ")) return true;
    if (std.mem.startsWith(u8, line, "Note: ")) return true;
    if (isFailureHeader(line)) return true;
    if (isExceptionLine(line)) return true;
    if (std.mem.find(u8, line, " tests completed") != null) return true;
    if (std.mem.startsWith(u8, line, "There were failing tests.")) return true;
    if (std.mem.startsWith(u8, line, "BUILD FAILED") or std.mem.startsWith(u8, line, "BUILD SUCCESSFUL")) return true;
    // B13: `N actionable tasks: N executed` is pure bookkeeping — the BUILD
    // verdict above already conveys the outcome, so it's dropped.
    if (std.mem.startsWith(u8, line, "See the report at:")) return true;
    if (std.mem.startsWith(u8, line, "file://")) return true;
    return false;
}

fn isCauseContext(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "> ")) return true;
    if (std.mem.startsWith(u8, line, "e: ") or std.mem.startsWith(u8, line, "w: ")) return true;
    if (std.mem.find(u8, line, " error") != null or std.mem.find(u8, line, "Error") != null) return true;
    return false;
}

fn isFailureHeader(line: []const u8) bool {
    return std.mem.find(u8, line, " FAILED") != null or
        std.mem.startsWith(u8, line, "FAILED ");
}

fn isExceptionLine(line: []const u8) bool {
    return std.mem.find(u8, line, "Exception") != null or
        std.mem.find(u8, line, "AssertionError") != null or
        std.mem.find(u8, line, "Error:") != null;
}

fn isFailureContext(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "at ") and
        (std.mem.find(u8, line, ".kt:") != null or
            std.mem.find(u8, line, ".java:") != null or
            std.mem.find(u8, line, ".groovy:") != null or
            std.mem.find(u8, line, ".scala:") != null))
    {
        return true;
    }
    if (std.mem.startsWith(u8, line, "Caused by:")) return true;
    if (std.mem.find(u8, line, "expected:<") != null) return true;
    return false;
}

fn appendLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

test "gradle build failure keeps cause and compiler diagnostics" {
    const input =
        \\> Configure project :app
        \\> Task :app:preBuild UP-TO-DATE
        \\> Task :app:compileDebugKotlin FAILED
        \\
        \\FAILURE: Build failed with an exception.
        \\
        \\* What went wrong:
        \\Execution failed for task ':app:compileDebugKotlin'.
        \\> Compilation error. See log for more details
        \\
        \\e: /app/MainActivity.kt: (42, 5): Unresolved reference: MyService
        \\
        \\* Try:
        \\> Run with --stacktrace option to get the stack trace.
        \\
        \\BUILD FAILED in 12s
        \\2 actionable tasks: 2 executed
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, ":compileDebugKotlin FAILED") != null);
    try std.testing.expect(std.mem.find(u8, got, "Compilation error") != null);
    try std.testing.expect(std.mem.find(u8, got, "Unresolved reference") != null);
    try std.testing.expect(std.mem.find(u8, got, "BUILD FAILED") != null);
    try std.testing.expect(std.mem.find(u8, got, "UP-TO-DATE") == null);
    try std.testing.expect(std.mem.find(u8, got, "--stacktrace") == null);
    // B13: actionable-task bookkeeping is dropped.
    try std.testing.expect(std.mem.find(u8, got, "actionable task") == null);
}

test "gradle test failure drops passed tests but keeps failing test signal" {
    const input =
        \\> Task :app:testDebugUnitTest
        \\com.example.CalculatorTest > testAddition PASSED
        \\com.example.CalculatorTest > testSubtraction FAILED
        \\    java.lang.AssertionError: expected:<3> but was:<-1>
        \\        at com.example.CalculatorTest.testSubtraction(CalculatorTest.kt:25)
        \\com.example.MainViewModelTest > loadDataSuccess PASSED
        \\
        \\5 tests completed, 2 failed
        \\There were failing tests. See the report at: file:///tmp/index.html
        \\BUILD FAILED in 22s
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "testSubtraction FAILED") != null);
    try std.testing.expect(std.mem.find(u8, got, "AssertionError") != null);
    try std.testing.expect(std.mem.find(u8, got, "CalculatorTest.kt:25") != null);
    try std.testing.expect(std.mem.find(u8, got, "5 tests completed, 2 failed") != null);
    try std.testing.expect(std.mem.find(u8, got, "testAddition PASSED") == null);
}

test "gradle keeps javac Note lines" {
    const input =
        \\> Task :app:compileJava
        \\Note: /app/src/main/java/Foo.java uses unchecked or unsafe operations.
        \\Note: Recompile with -Xlint:unchecked for details.
        \\BUILD SUCCESSFUL in 3s
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Note: /app/src/main/java/Foo.java uses unchecked") != null);
    try std.testing.expect(std.mem.find(u8, got, "Note: Recompile with -Xlint:unchecked") != null);
    try std.testing.expect(std.mem.find(u8, got, "BUILD SUCCESSFUL") != null);
}
