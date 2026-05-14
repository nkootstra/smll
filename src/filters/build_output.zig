const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for JS bundler/build output — Vite, Next.js, Nuxt
// (and Nuxt's Vite-driven phases). On by default. Set SMLL_LOSSLESS=1 to
// bypass.
//
// Keeps everything by default (errors, warnings, route tables, asset
// sizes, build summaries) and explicitly drops known noise: node
// DeprecationWarnings, Vite progress chatter ("transforming...",
// "rendering chunks", "computing gzip size"), Next.js "Creating an
// optimized production build" prelude, npm-script header lines
// (`> name@version build` and `> tool subcmd`), Nuxt `ℹ`-prefixed Vite
// progress mirrors.

const DROP_PREFIXES = [_][]const u8{
    "(node:", // node deprecation warning header
    "(Use ", // node --trace-deprecation continuation
    "> ", // npm-script invocation lines (`> app@0.1.0 build`, `> vite build`)
    "transforming...",
    "rendering chunks (",
    "computing gzip size (",
    "Creating an optimized production build",
    "info  - Linting",
    "ℹ vite v",
    "ℹ rendering chunks",
    "ℹ computing gzip size",
};

const DROP_CONTAINS = [_][]const u8{
    "DeprecationWarning",
};

pub fn matches(input: []const u8) bool {
    // Vite build banner
    if (std.mem.find(u8, input, "vite v") != null and
        (std.mem.find(u8, input, "building for production") != null or
            std.mem.find(u8, input, "building SSR bundle") != null)) return true;
    // Next.js build banner
    if (std.mem.find(u8, input, "\xe2\x96\xb2 Next.js") != null) return true; // ▲ Next.js
    if (std.mem.find(u8, input, "Creating an optimized production build") != null) return true;
    if (std.mem.find(u8, input, "Compiled successfully") != null) return true;
    // Nuxt build banner
    if (std.mem.find(u8, input, "Nuxt ") != null and
        std.mem.find(u8, input, "with Nitro") != null) return true;
    // Shared finalizers
    if (std.mem.find(u8, input, "modules transformed") != null) return true;
    if (std.mem.find(u8, input, "\xe2\x9c\x93 built in ") != null) return true; // ✓ built in
    if (std.mem.find(u8, input, "\xce\xa3 Total size:") != null) return true; // Σ Total size:
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);

    var kept_lines: usize = 0;
    try scanAndKeep(allocator, stdout, &scratch, &kept_lines);
    try scanAndKeep(allocator, stderr, &scratch, &kept_lines);

    if (kept_lines == 0) {
        try writer.writeAll("build complete\n");
        return;
    }
    try writer.writeAll(scratch.items);
}

fn scanAndKeep(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), kept: *usize) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    // 200 lines is enough for Vite/Next/Nuxt builds in normal projects:
    // ~30 chunks, ~30 routes, warnings, summary. Bound prevents runaway.
    const head_cap: usize = 200;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var prev_blank: bool = false;
    while (lines.next()) |raw| {
        if (kept.* >= head_cap) break;
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trimEnd(u8, line, " \t\r");
        // Collapse consecutive blanks.
        if (trimmed.len == 0) {
            if (!prev_blank and kept.* > 0) {
                try out.append(allocator, '\n');
                prev_blank = true;
            }
            continue;
        }
        const body = std.mem.trimStart(u8, trimmed, " \t");
        if (shouldDrop(body)) continue;
        try out.appendSlice(allocator, trimmed);
        try out.append(allocator, '\n');
        kept.* += 1;
        prev_blank = false;
    }
}

fn shouldDrop(line: []const u8) bool {
    for (DROP_PREFIXES) |p| {
        if (std.mem.startsWith(u8, line, p)) return true;
    }
    for (DROP_CONTAINS) |c| {
        if (std.mem.find(u8, line, c) != null) return true;
    }
    return false;
}

test "matches: vite build banner" {
    try std.testing.expect(matches("vite v5.4.2 building for production...\n"));
}

test "matches: vite SSR bundle" {
    try std.testing.expect(matches("vite v5.4.2 building SSR bundle for production...\n"));
}

test "matches: next build banner" {
    try std.testing.expect(matches("  \xe2\x96\xb2 Next.js 14.2.5\n"));
}

test "matches: next compiled successfully" {
    try std.testing.expect(matches(" \xe2\x9c\x93 Compiled successfully\n"));
}

test "matches: nuxt + nitro banner" {
    try std.testing.expect(matches("Nuxt 3.13.0 with Nitro 2.9.7\n"));
}

test "matches: modules transformed signal" {
    try std.testing.expect(matches("\xe2\x9c\x93 1248 modules transformed.\n"));
}

test "matches: built in summary" {
    try std.testing.expect(matches("\xe2\x9c\x93 built in 12.34s\n"));
}

test "matches: nuxt total size summary" {
    try std.testing.expect(matches("\xce\xa3 Total size: 1.23 MB (1.05 MB gzip)\n"));
}

test "matches: rejects unrelated text" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello world\n"));
    try std.testing.expect(!matches("npm WARN deprecated\n"));
}

test "apply: drops node deprecation warnings" {
    const input =
        "vite v5.4.2 building for production...\n" ++
        "(node:84321) [DEP0040] DeprecationWarning: The `punycode` module is deprecated.\n" ++
        "(Use `node --trace-deprecation ...` to show where the warning was created)\n" ++
        "\xe2\x9c\x93 built in 1.23s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "DeprecationWarning") == null);
    try std.testing.expect(std.mem.find(u8, got, "(node:") == null);
    try std.testing.expect(std.mem.find(u8, got, "(Use `node") == null);
    try std.testing.expect(std.mem.find(u8, got, "vite v5.4.2") != null);
    try std.testing.expect(std.mem.find(u8, got, "built in 1.23s") != null);
}

test "apply: drops script-header lines and Vite progress" {
    const input =
        "> my-app@0.1.0 build\n" ++
        "> vite build\n" ++
        "\n" ++
        "vite v5.4.2 building for production...\n" ++
        "transforming...\n" ++
        "rendering chunks (0)...\n" ++
        "computing gzip size (0)...\n" ++
        "\xe2\x9c\x93 5 modules transformed.\n" ++
        "\xe2\x9c\x93 built in 1.2s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "> my-app@") == null);
    try std.testing.expect(std.mem.find(u8, got, "> vite build") == null);
    try std.testing.expect(std.mem.find(u8, got, "transforming...") == null);
    try std.testing.expect(std.mem.find(u8, got, "rendering chunks") == null);
    try std.testing.expect(std.mem.find(u8, got, "computing gzip size") == null);
    try std.testing.expect(std.mem.find(u8, got, "modules transformed") != null);
    try std.testing.expect(std.mem.find(u8, got, "built in 1.2s") != null);
}

test "apply: vite_build fixture compacts but keeps signal" {
    const input = @embedFile("fixture_vite_build");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    // Kept signal
    try std.testing.expect(std.mem.find(u8, got, "vite v5.4.2 building for production") != null);
    try std.testing.expect(std.mem.find(u8, got, "1248 modules transformed") != null);
    try std.testing.expect(std.mem.find(u8, got, "built in 12.34s") != null);
    try std.testing.expect(std.mem.find(u8, got, "vendor-react") != null); // asset sizes kept
    try std.testing.expect(std.mem.find(u8, got, "Some chunks are larger than 500 kB") != null);
    // Dropped noise
    try std.testing.expect(std.mem.find(u8, got, "DeprecationWarning") == null);
    try std.testing.expect(std.mem.find(u8, got, "(node:") == null);
    try std.testing.expect(std.mem.find(u8, got, "transforming...") == null);
    try std.testing.expect(std.mem.find(u8, got, "rendering chunks (0)") == null);
    try std.testing.expect(std.mem.find(u8, got, "computing gzip size") == null);
    try std.testing.expect(std.mem.find(u8, got, "> vite build") == null);
}

test "apply: next_build fixture preserves route table + lint warnings" {
    const input = @embedFile("fixture_next_build");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    // Banners + summary
    try std.testing.expect(std.mem.find(u8, got, "Next.js 14.2.5") != null);
    try std.testing.expect(std.mem.find(u8, got, "Compiled successfully") != null);
    // Route table
    try std.testing.expect(std.mem.find(u8, got, "Route (app)") != null);
    try std.testing.expect(std.mem.find(u8, got, "/dashboard") != null);
    try std.testing.expect(std.mem.find(u8, got, "First Load JS shared by all") != null);
    // Lint warnings + their file headers
    try std.testing.expect(std.mem.find(u8, got, "./app/dashboard/page.tsx") != null);
    try std.testing.expect(std.mem.find(u8, got, "no-unused-vars") != null);
    try std.testing.expect(std.mem.find(u8, got, "exhaustive-deps") != null);
    // Dropped noise
    try std.testing.expect(std.mem.find(u8, got, "(node:") == null);
    try std.testing.expect(std.mem.find(u8, got, "DeprecationWarning") == null);
    try std.testing.expect(std.mem.find(u8, got, "Creating an optimized production build") == null);
    try std.testing.expect(std.mem.find(u8, got, "info  - Linting") == null);
}

test "apply: nuxt_build fixture keeps phase markers + totals, drops vite progress" {
    const input = @embedFile("fixture_nuxt_build");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    // Kept
    try std.testing.expect(std.mem.find(u8, got, "Nuxt 3.13.0 with Nitro 2.9.7") != null);
    try std.testing.expect(std.mem.find(u8, got, "Building client") != null);
    try std.testing.expect(std.mem.find(u8, got, "Building server") != null);
    try std.testing.expect(std.mem.find(u8, got, "Client built in 2345ms") != null);
    try std.testing.expect(std.mem.find(u8, got, "Server built in 1234ms") != null);
    try std.testing.expect(std.mem.find(u8, got, "Total size: 1.23 MB") != null);
    // Dropped Nuxt-mirrored Vite progress
    try std.testing.expect(std.mem.find(u8, got, "\xe2\x84\xb9 vite v5.4.2") == null); // ℹ vite v
    try std.testing.expect(std.mem.find(u8, got, "\xe2\x84\xb9 rendering chunks") == null);
    try std.testing.expect(std.mem.find(u8, got, "\xe2\x84\xb9 computing gzip size") == null);
}

test "apply: empty input is no-op" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", &.{}, &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: silent build emits 'build complete'" {
    const input = "\n\n\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("build complete\n", out.written());
}

test "apply: strips ANSI" {
    const input = "\x1b[32m\xe2\x9c\x93 built in 1.23s\x1b[0m\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "built in 1.23s") != null);
}
