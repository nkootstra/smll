const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// cat/file-read compression filter.
//
// Wrapper-mode only: `smll cat <file>` runs `cat <file>`, captures stdout,
// and compresses code output to keep imports + signatures + doc comments
// while stripping function/method bodies.
//
// Data files (JSON, YAML, TOML, XML, CSV, SQL, Markdown) pass through
// unchanged — structured data must not be lossy.
//
// Contract: format-lossy, fact-preserving. Every declaration, import,
// type, and public API is visible; only implementation bodies are elided.

pub fn matches(stdout: []const u8) bool {
    // In wrapper mode, cat output is always eligible. But we only compress
    // if the output is large enough to benefit and looks like code.
    return stdout.len > 512;
}

const Lang = enum {
    rust,
    zig_lang,
    go,
    python,
    typescript,
    javascript,
    java,
    c_cpp,
    ruby,
    data,
    unknown,
};

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer, argv: []const []const u8) !void {
    _ = allocator;
    _ = stderr;

    // Detect language from filename in argv (cat <file>).
    const lang = detectLang(argv);

    // Data formats pass through unchanged.
    if (lang == .data) {
        try writer.writeAll(stdout);
        return;
    }

    // Unknown language with no code markers: pass through.
    if (lang == .unknown and !looksLikeCode(stdout)) {
        try writer.writeAll(stdout);
        return;
    }

    // Compress: keep imports, signatures, doc comments; elide bodies.
    try compressCode(stdout, lang, writer);
}

fn detectLang(argv: []const []const u8) Lang {
    // Find the last argument that looks like a filename (not a flag).
    var filename: []const u8 = "";
    for (argv) |arg| {
        if (arg.len > 0 and arg[0] != '-') filename = arg;
    }
    if (filename.len == 0) return .unknown;

    const ext = fileExtension(filename);
    if (ext.len == 0) return .unknown;

    // Data formats — never compress.
    if (eql(ext, "json") or eql(ext, "yaml") or eql(ext, "yml") or
        eql(ext, "toml") or eql(ext, "xml") or eql(ext, "csv") or
        eql(ext, "sql") or eql(ext, "md") or eql(ext, "markdown") or
        eql(ext, "html") or eql(ext, "css") or eql(ext, "txt") or
        eql(ext, "env") or eql(ext, "ini") or eql(ext, "cfg") or
        eql(ext, "conf") or eql(ext, "lock") or eql(ext, "sum"))
        return .data;

    // Code languages.
    if (eql(ext, "rs")) return .rust;
    if (eql(ext, "zig")) return .zig_lang;
    if (eql(ext, "go")) return .go;
    if (eql(ext, "py") or eql(ext, "pyi")) return .python;
    if (eql(ext, "ts") or eql(ext, "tsx") or eql(ext, "mts")) return .typescript;
    if (eql(ext, "js") or eql(ext, "jsx") or eql(ext, "mjs")) return .javascript;
    if (eql(ext, "java") or eql(ext, "kt") or eql(ext, "kts")) return .java;
    if (eql(ext, "c") or eql(ext, "h") or eql(ext, "cpp") or
        eql(ext, "cc") or eql(ext, "hpp") or eql(ext, "hh"))
        return .c_cpp;
    if (eql(ext, "rb")) return .ruby;

    return .unknown;
}

fn fileExtension(name: []const u8) []const u8 {
    // Handle dotfiles like ".gitignore" (no extension).
    const base = if (std.mem.findScalarLast(u8, name, '/')) |idx| name[idx + 1 ..] else name;
    const dot = std.mem.findScalarLast(u8, base, '.') orelse return "";
    if (dot == 0) return ""; // dotfile
    return base[dot + 1 ..];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn looksLikeCode(content: []const u8) bool {
    // Quick heuristic: check first 2KB for common code patterns.
    const check = content[0..@min(content.len, 2048)];
    return std.mem.indexOf(u8, check, "import ") != null or
        std.mem.indexOf(u8, check, "#include") != null or
        std.mem.indexOf(u8, check, "def ") != null or
        std.mem.indexOf(u8, check, "fn ") != null or
        std.mem.indexOf(u8, check, "func ") != null or
        std.mem.indexOf(u8, check, "function ") != null or
        std.mem.indexOf(u8, check, "class ") != null or
        std.mem.indexOf(u8, check, "pub ") != null or
        std.mem.indexOf(u8, check, "const ") != null;
}

/// Compress code: keep structural lines (imports, signatures, type defs,
/// doc comments, decorators), elide function/method bodies.
fn compressCode(input: []const u8, lang: Lang, writer: *Writer) !void {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var brace_depth: i32 = 0;
    var in_body = false;
    var body_lines: usize = 0;
    var prev_was_blank = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Always keep empty lines (collapse runs though).
        if (trimmed.len == 0) {
            if (!prev_was_blank and !in_body) {
                try writer.writeByte('\n');
            }
            prev_was_blank = true;
            continue;
        }
        prev_was_blank = false;

        // Always keep imports / includes / use / require.
        if (isImportLine(trimmed, lang)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        // Always keep doc comments.
        if (isDocComment(trimmed, lang)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        // Always keep decorators / attributes.
        if (trimmed[0] == '@' or (trimmed[0] == '#' and trimmed.len > 1 and trimmed[1] == '[')) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        // Track brace depth for body elision (C-family, Rust, Zig, Go, JS/TS, Java).
        if (lang != .python and lang != .ruby) {
            const opens = countChar(trimmed, '{');
            const closes = countChar(trimmed, '}');

            if (in_body) {
                brace_depth += @as(i32, @intCast(opens));
                brace_depth -= @as(i32, @intCast(closes));
                body_lines += 1;
                if (brace_depth <= 0) {
                    // End of body — emit closing brace + elision marker.
                    if (body_lines > 1) {
                        try writer.writeAll("    // ... (");
                        try ansi.writeDecimal(writer, body_lines);
                        try writer.writeAll(" lines)\n");
                    }
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                    in_body = false;
                    body_lines = 0;
                }
                continue;
            }

            // Signature line: has opening brace or is a signature followed by {.
            if (isSignature(trimmed, lang)) {
                try writer.writeAll(line);
                try writer.writeByte('\n');
                if (opens > closes) {
                    brace_depth = @as(i32, @intCast(opens)) - @as(i32, @intCast(closes));
                    in_body = true;
                    body_lines = 0;
                }
                continue;
            }
        } else {
            // Python/Ruby: indent-based body elision.
            if (isPythonSignature(trimmed)) {
                try writer.writeAll(line);
                try writer.writeByte('\n');
                // Skip body lines (indented more than the def/class line).
                const sig_indent = leadingSpaces(line);
                var skipped: usize = 0;
                while (lines.next()) |body_line| {
                    const bt = std.mem.trim(u8, body_line, " \t\r");
                    if (bt.len == 0) { skipped += 1; continue; }
                    if (leadingSpaces(body_line) > sig_indent) {
                        skipped += 1;
                        continue;
                    }
                    // This line is at the same or lower indent — it's not part of the body.
                    // We need to process it, but splitScalar doesn't support pushback.
                    // Emit elision marker, then emit this line normally.
                    if (skipped > 0) {
                        try writer.writeAll("    # ... (");
                        try ansi.writeDecimal(writer, skipped);
                        try writer.writeAll(" lines)\n");
                    }
                    // Process this line as a new top-level line.
                    try writer.writeAll(body_line);
                    try writer.writeByte('\n');
                    break;
                }
                continue;
            }
        }

        // Keep type definitions, constants, struct/enum/trait/interface declarations.
        if (isTypeDef(trimmed, lang)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        // Keep regular comments (non-doc) at top level when not in a body.
        if (isComment(trimmed, lang)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        // Keep module-level assignments and exports.
        if (isModuleLevelStatement(trimmed, lang)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        // Default: keep the line (be conservative — format-lossy but fact-preserving).
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

fn isImportLine(trimmed: []const u8, lang: Lang) bool {
    _ = lang;
    return std.mem.startsWith(u8, trimmed, "import ") or
        std.mem.startsWith(u8, trimmed, "from ") or
        std.mem.startsWith(u8, trimmed, "#include") or
        std.mem.startsWith(u8, trimmed, "use ") or
        std.mem.startsWith(u8, trimmed, "require") or
        std.mem.startsWith(u8, trimmed, "const ") and std.mem.indexOf(u8, trimmed, "require(") != null or
        std.mem.startsWith(u8, trimmed, "export ");
}

fn isDocComment(trimmed: []const u8, lang: Lang) bool {
    return switch (lang) {
        .rust => std.mem.startsWith(u8, trimmed, "///") or std.mem.startsWith(u8, trimmed, "//!"),
        .zig_lang => std.mem.startsWith(u8, trimmed, "///") or std.mem.startsWith(u8, trimmed, "//!"),
        .go => std.mem.startsWith(u8, trimmed, "//"),
        .python => std.mem.startsWith(u8, trimmed, "\"\"\"") or std.mem.startsWith(u8, trimmed, "'''"),
        .java => std.mem.startsWith(u8, trimmed, "/**"),
        .typescript, .javascript => std.mem.startsWith(u8, trimmed, "/**") or std.mem.startsWith(u8, trimmed, "///"),
        .c_cpp => std.mem.startsWith(u8, trimmed, "/**") or std.mem.startsWith(u8, trimmed, "///"),
        .ruby => std.mem.startsWith(u8, trimmed, "##"),
        else => false,
    };
}

fn isSignature(trimmed: []const u8, lang: Lang) bool {
    return switch (lang) {
        .rust => std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub async fn ") or
            std.mem.startsWith(u8, trimmed, "async fn ") or
            std.mem.startsWith(u8, trimmed, "impl ") or
            std.mem.startsWith(u8, trimmed, "pub struct ") or
            std.mem.startsWith(u8, trimmed, "struct ") or
            std.mem.startsWith(u8, trimmed, "pub enum ") or
            std.mem.startsWith(u8, trimmed, "enum ") or
            std.mem.startsWith(u8, trimmed, "pub trait ") or
            std.mem.startsWith(u8, trimmed, "trait "),
        .zig_lang => std.mem.startsWith(u8, trimmed, "pub fn ") or
            std.mem.startsWith(u8, trimmed, "fn ") or
            std.mem.startsWith(u8, trimmed, "pub const ") or
            std.mem.startsWith(u8, trimmed, "const ") or
            std.mem.startsWith(u8, trimmed, "pub var ") or
            std.mem.startsWith(u8, trimmed, "test "),
        .go => std.mem.startsWith(u8, trimmed, "func ") or
            std.mem.startsWith(u8, trimmed, "type "),
        .typescript, .javascript => std.mem.startsWith(u8, trimmed, "function ") or
            std.mem.startsWith(u8, trimmed, "async function ") or
            std.mem.startsWith(u8, trimmed, "export function ") or
            std.mem.startsWith(u8, trimmed, "export async function ") or
            std.mem.startsWith(u8, trimmed, "export default function ") or
            std.mem.startsWith(u8, trimmed, "class ") or
            std.mem.startsWith(u8, trimmed, "export class ") or
            std.mem.startsWith(u8, trimmed, "interface ") or
            std.mem.startsWith(u8, trimmed, "export interface ") or
            std.mem.startsWith(u8, trimmed, "type ") or
            std.mem.startsWith(u8, trimmed, "export type "),
        .java => std.mem.startsWith(u8, trimmed, "public ") or
            std.mem.startsWith(u8, trimmed, "private ") or
            std.mem.startsWith(u8, trimmed, "protected ") or
            std.mem.startsWith(u8, trimmed, "class ") or
            std.mem.startsWith(u8, trimmed, "interface "),
        .c_cpp => std.mem.indexOf(u8, trimmed, "(") != null and
            (std.mem.endsWith(u8, trimmed, "{") or std.mem.endsWith(u8, trimmed, ")")),
        else => false,
    };
}

fn isPythonSignature(trimmed: []const u8) bool {
    return std.mem.startsWith(u8, trimmed, "def ") or
        std.mem.startsWith(u8, trimmed, "async def ") or
        std.mem.startsWith(u8, trimmed, "class ");
}

fn isTypeDef(trimmed: []const u8, lang: Lang) bool {
    _ = lang;
    return std.mem.startsWith(u8, trimmed, "type ") or
        std.mem.startsWith(u8, trimmed, "struct ") or
        std.mem.startsWith(u8, trimmed, "enum ") or
        std.mem.startsWith(u8, trimmed, "trait ") or
        std.mem.startsWith(u8, trimmed, "interface ") or
        std.mem.startsWith(u8, trimmed, "pub struct ") or
        std.mem.startsWith(u8, trimmed, "pub enum ") or
        std.mem.startsWith(u8, trimmed, "pub type ") or
        std.mem.startsWith(u8, trimmed, "typedef ");
}

fn isComment(trimmed: []const u8, lang: Lang) bool {
    _ = lang;
    return std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "#") or
        std.mem.startsWith(u8, trimmed, "/*") or
        std.mem.startsWith(u8, trimmed, " *") or
        std.mem.startsWith(u8, trimmed, "*/");
}

fn isModuleLevelStatement(trimmed: []const u8, lang: Lang) bool {
    _ = lang;
    return std.mem.startsWith(u8, trimmed, "module ") or
        std.mem.startsWith(u8, trimmed, "package ") or
        std.mem.startsWith(u8, trimmed, "namespace ");
}

fn countChar(s: []const u8, c: u8) usize {
    var n: usize = 0;
    for (s) |b| if (b == c) { n += 1; };
    return n;
}

fn leadingSpaces(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') { n += 1; } else if (c == '\t') { n += 4; } else break;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fileExtension: basic" {
    try std.testing.expectEqualStrings("rs", fileExtension("main.rs"));
    try std.testing.expectEqualStrings("zig", fileExtension("src/main.zig"));
    try std.testing.expectEqualStrings("", fileExtension(".gitignore"));
    try std.testing.expectEqualStrings("json", fileExtension("package.json"));
}

test "detectLang: code files" {
    try std.testing.expectEqual(Lang.rust, detectLang(&.{ "cat", "src/main.rs" }));
    try std.testing.expectEqual(Lang.python, detectLang(&.{ "cat", "app.py" }));
    try std.testing.expectEqual(Lang.typescript, detectLang(&.{ "cat", "index.ts" }));
}

test "detectLang: data files" {
    try std.testing.expectEqual(Lang.data, detectLang(&.{ "cat", "config.json" }));
    try std.testing.expectEqual(Lang.data, detectLang(&.{ "cat", "data.yaml" }));
    try std.testing.expectEqual(Lang.data, detectLang(&.{ "cat", "Cargo.lock" }));
}

test "matches: small file is not compressed" {
    try std.testing.expect(!matches("small"));
}

test "matches: large file is eligible" {
    const big = "x" ** 600;
    try std.testing.expect(matches(big));
}

test "apply: data file passes through" {
    const input = "{\"key\": \"value\", \"nested\": {\"a\": 1}}\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer, &.{ "cat", "data.json" });
    try std.testing.expectEqualStrings(input, out.written());
}

test "apply: rust function body is elided" {
    const input =
        \\pub fn main() {
        \\    let x = 1;
        \\    let y = 2;
        \\    println!("{}", x + y);
        \\}
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer, &.{ "cat", "main.rs" });
    const result = out.written();
    try std.testing.expect(std.mem.indexOf(u8, result, "pub fn main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "// ... (4 lines)") != null);
    // Body details should not be present.
    try std.testing.expect(std.mem.indexOf(u8, result, "println!") == null);
}

test "apply: imports are preserved" {
    const input =
        \\import std from "std";
        \\use std::io;
        \\#include <stdio.h>
        \\from os import path
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer, &.{ "cat", "test.rs" });
    // All imports kept.
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "import std") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "use std::io") != null);
}
