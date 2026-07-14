const std = @import("std");
const ansi = @import("ansi");
const util = @import("util");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for package dependency trees.
// Handles the box-drawing variants emitted by `bun pm ls`, `npm ls`/`npm list`,
// `yarn list` (v1, two-char connectors), and pnpm's flat `dependencies:` list.
// Keeps the root context, direct dependency names/versions, and a transitive
// count. Drops the full nested dependency tree by default. Dispatch is
// argv-gated in the wrapper, so `matches` only needs a cheap shape check.

// 3-char box connectors used by npm / bun / pnpm subtrees: "├── └── ├─┬ └─┬ ".
const p_mid3 = "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ";
const p_end3 = "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 ";
const p_midt = "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\xac ";
const p_endt = "\xe2\x94\x94\xe2\x94\x80\xe2\x94\xac ";
// 2-char box connectors used by yarn v1: "├─ └─ ".
const p_mid2 = "\xe2\x94\x9c\xe2\x94\x80 ";
const p_end2 = "\xe2\x94\x94\xe2\x94\x80 ";

// No 2-char needle is a substring of any 3-char needle (the byte after "├─"/
// "└─" is 0x20 for yarn vs. 0xe2 — a third box glyph — for npm), so neither
// `startsWith` in directPackage nor `find` in containsTreePackageMarker ever
// cross-matches a yarn connector against an npm one. A `│  └─ ` continuation
// line still contains `└─ ` as an interior match — that is intended: it marks a
// transitive row.
const all_prefixes = [_][]const u8{ p_mid3, p_end3, p_midt, p_endt, p_mid2, p_end2 };

pub fn matches(input: []const u8) bool {
    return containsTreePackageMarker(input) or isPnpmList(input);
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var name_buf: std.ArrayList(u8) = .empty;
    defer name_buf.deinit(allocator);

    var deps: NameList = .{};
    defer deps.deinit(allocator);

    var root: ?[]u8 = null;
    defer if (root) |r| allocator.free(r);
    var nested_rows: usize = 0;

    // pnpm prints direct deps as a flat `name version` list under a
    // `dependencies:` header and ALL box-drawn rows are transitive. npm / yarn /
    // bun instead mark direct deps with a column-0 box connector.
    //
    // Single-root by design: workspace/`--recursive` output repeats the root +
    // section blocks per package. We keep the first root and aggregate every
    // section's direct deps under it (a blank line ends a section, not the
    // listing), which is a faithful superset count rather than per-package
    // attribution. That is acceptable for the "how many deps" signal this
    // filter provides; `SMLL_LOSSLESS=1` yields the full per-package tree.
    const pnpm = isPnpmList(stdout);
    var in_section = false;

    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        // Trim trailing only: leading whitespace distinguishes a column-0 direct
        // dependency from an indented (transitive) one.
        const line = std.mem.trimEnd(u8, clean, " \t\r");
        if (line.len == 0) {
            in_section = false;
            continue;
        }

        if (pnpm) {
            if (std.mem.startsWith(u8, line, "Legend:")) continue;
            // Any pnpm section header: dependencies / devDependencies /
            // optionalDependencies / peerDependencies all share this suffix.
            // A flat dep row is `name version` (a space, no trailing colon), so
            // the suffix never collides with a real dependency line.
            if (std.mem.endsWith(u8, line, "ependencies:")) {
                in_section = true;
                continue;
            }
            if (containsTreePackageMarker(line)) {
                nested_rows += 1;
                continue;
            }
            if (in_section) {
                if (try flatDep(allocator, &name_buf, line)) |pkg| {
                    try deps.add(allocator, pkg);
                    continue;
                }
            }
            if (root == null and !startsWithTreePrefix(line)) {
                root = try allocator.dupe(u8, line);
            }
            continue;
        }

        // npm / yarn / bun box tree.
        if (root == null and !startsWithTreePrefix(line)) {
            root = try allocator.dupe(u8, line);
            continue;
        }
        if (directPackage(line)) |pkg| {
            try deps.add(allocator, pkg);
        } else if (containsTreePackageMarker(line)) {
            nested_rows += 1;
        }
    }

    if (root) |r| {
        try writer.writeAll(r);
        try writer.writeByte('\n');
    }
    if (deps.count > 0) {
        try deps.write(writer, "deps");
    }
    if (nested_rows > 0) {
        try writer.writeAll("nested rows x");
        try writeDecimal(writer, nested_rows);
        try writer.writeByte('\n');
    }
    if (stderr.len > 0) try writer.writeAll(stderr);
}

const NameList = struct {
    count: usize = 0,
    items: std.ArrayList(u8) = .empty,

    fn deinit(self: *NameList, allocator: Allocator) void {
        self.items.deinit(allocator);
    }

    fn add(self: *NameList, allocator: Allocator, name: []const u8) !void {
        self.count += 1;
        if (self.count > 12) return;
        if (self.items.items.len > 0) try self.items.appendSlice(allocator, ", ");
        try self.items.appendSlice(allocator, name);
    }

    fn write(self: *const NameList, writer: *Writer, label: []const u8) !void {
        try writer.writeAll(label);
        try writer.writeAll(" +");
        try writeDecimal(writer, self.count);
        if (self.items.items.len > 0) {
            try writer.writeAll(": ");
            try writer.writeAll(self.items.items);
            if (self.count > 12) try writer.writeAll(", ...");
        }
        try writer.writeByte('\n');
    }
};

/// A column-0 box connector marks a direct dependency in npm / yarn / bun trees.
/// Returns the trimmed `name@version` payload, or null if the line is indented
/// (transitive) or not a tree row.
fn directPackage(line: []const u8) ?[]const u8 {
    for (all_prefixes) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) {
            return std.mem.trim(u8, line[prefix.len..], " \t\r");
        }
    }
    return null;
}

/// pnpm flat dependency row `name version` → `name@version`. Returns null when
/// the line has no space-separated version (so it is not a dependency row).
fn flatDep(allocator: Allocator, buf: *std.ArrayList(u8), line: []const u8) !?[]const u8 {
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const name = line[0..sp];
    const version = std.mem.trim(u8, line[sp + 1 ..], " \t\r");
    if (name.len == 0 or version.len == 0) return null;
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, '@');
    try buf.appendSlice(allocator, version);
    return buf.items;
}

fn startsWithTreePrefix(line: []const u8) bool {
    return line.len >= 3 and line[0] == 0xe2 and line[1] == 0x94;
}

fn containsTreePackageMarker(line: []const u8) bool {
    for (all_prefixes) |prefix| {
        if (std.mem.find(u8, line, prefix) != null) return true;
    }
    return false;
}

fn isPnpmList(input: []const u8) bool {
    return std.mem.startsWith(u8, input, "Legend:") or
        std.mem.find(u8, input, "\ndependencies:") != null or
        std.mem.find(u8, input, "\ndevDependencies:") != null or
        std.mem.find(u8, input, "\noptionalDependencies:") != null;
}

fn writeDecimal(writer: *Writer, value: usize) !void {
    try util.writeDecimal(writer, value);
}

test "package tree keeps direct deps and transitive count" {
    const input =
        \\example-app@1.0.0 /repo node_modules (5)
        \\├── react@18.3.1
        \\├─┬ react-dom@18.3.1
        \\│ ├── react@18.3.1
        \\│ └── scheduler@0.23.2
        \\└── zod@3.23.8
        \\
    ;
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "example-app@1.0.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "deps +3: react@18.3.1, react-dom@18.3.1, zod@3.23.8") != null);
    try std.testing.expect(std.mem.find(u8, got, "nested rows x2") != null);
    try std.testing.expect(std.mem.find(u8, got, "scheduler@0.23.2") == null);
}

test "npm ls flat: direct deps, no transitive" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, @embedFile("fixture_npm_ls"), "", &out.writer);
    const got = out.written();
    try std.testing.expectEqualStrings(
        "demo-app@1.0.0 /private/repo\ndeps +2: chalk@4.1.2, debug@4.3.4\n",
        got,
    );
}

test "npm ls --all: column-0 connectors are direct, indented are nested" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, @embedFile("fixture_npm_ls_all"), "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "deps +2: chalk@4.1.2, debug@4.3.4") != null);
    // Includes the space-indented last child `  └── ms@2.1.2` as transitive.
    try std.testing.expect(std.mem.find(u8, got, "nested rows x6") != null);
}

test "pnpm list flat: dependencies section, no box rows" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, @embedFile("fixture_pnpm_list"), "", &out.writer);
    const got = out.written();
    try std.testing.expectEqualStrings(
        "demo-app@1.0.0 /private/repo (PRIVATE)\ndeps +2: chalk@4.1.2, debug@4.3.4\n",
        got,
    );
}

test "pnpm list deep: every box row is transitive, flat rows are direct" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, @embedFile("fixture_pnpm_list_deep"), "", &out.writer);
    const got = out.written();
    // chalk/debug are flat (direct); the column-0 `└─┬ supports-color` row is a
    // box connector and must NOT be miscounted as direct.
    try std.testing.expect(std.mem.find(u8, got, "deps +2: chalk@4.1.2, debug@4.3.4") != null);
    try std.testing.expect(std.mem.find(u8, got, "nested rows x6") != null);
    try std.testing.expect(std.mem.find(u8, got, "supports-color") == null);
}

test "yarn list: two-char connectors at column 0 are direct" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, @embedFile("fixture_yarn_list"), "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "yarn list v1.22.22") != null);
    try std.testing.expect(std.mem.find(u8, got, "deps +8: ansi-styles@4.3.0, chalk@4.1.2, color-convert@2.0.1, color-name@1.1.4, debug@4.3.4, has-flag@4.0.0, ms@2.1.2, supports-color@7.2.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "nested rows x6") != null);
}

test "pnpm devDependencies/optionalDependencies sections are kept" {
    // Regression: the section gate must recognize the camelCase headers, not
    // just lowercase `dependencies:`. A dev-only project must not report zero
    // deps. Captured from real `pnpm list` on a devDeps+optionalDeps project.
    const input =
        "Legend: production dependency, optional only, dev only\n" ++
        "\n" ++
        "devonly-app@1.0.0 /repo (PRIVATE)\n" ++
        "\n" ++
        "devDependencies:\n" ++
        "typescript 5.4.5\n" ++
        "\n" ++
        "optionalDependencies:\n" ++
        "fsevents 2.3.3\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expectEqualStrings(
        "devonly-app@1.0.0 /repo (PRIVATE)\ndeps +2: typescript@5.4.5, fsevents@2.3.3\n",
        got,
    );
}

test "matches fires on each ecosystem and ignores plain text" {
    try std.testing.expect(matches(@embedFile("fixture_npm_ls")));
    try std.testing.expect(matches(@embedFile("fixture_npm_ls_all"))); // 3-char connectors
    try std.testing.expect(matches(@embedFile("fixture_pnpm_list"))); // box-less, header only
    try std.testing.expect(matches(@embedFile("fixture_pnpm_list_deep")));
    try std.testing.expect(matches(@embedFile("fixture_yarn_list"))); // 2-char connectors
    try std.testing.expect(!matches("just some text\nwith no tree\n"));
}
