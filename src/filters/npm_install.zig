const std = @import("std");
const ansi = @import("ansi");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for package manager installs — npm, pnpm, bun,
// yarn (JS) and composer (PHP). On by default (v0.6). Set SMLL_LOSSLESS=1
// to bypass.
//
// Keeps: warnings/errors (any manager), the install summary line
//        (added/removed/changed/up to date/audited for npm,
//        Packages: +X for pnpm, X packages installed for bun,
//        success Saved/Done in for yarn,
//        Package/Lock file operations / Nothing to install / vulnerability
//        advisories for composer), vulnerabilities.
// Drops: "npm notice" upgrade prompts, "packages are looking for funding",
//        "run `...`" instruction lines, dependency trees, per-package add
//        listings (covered by the count summary), progress visualizations,
//        manager banners (`bun add vX.Y.Z`), composer scaffolding
//        ("Loading composer repositories", "Writing lock file", "Generating
//        ... autoload files", "Discovered Package: ..."), blank padding.
//        Composer's "Using version <constraint> for <pkg>" is kept — it's
//        the resolved version of a `composer require` call.
//
// If no keep lines captured, emits "up to date\n".

const KEEP_PREFIXES = [_][]const u8{
    "npm WARN", // npm
    "npm ERR!", // npm
    "npm error", // npm
    "npm err!", // npm
    "WARN ", // pnpm (and any tool using that shape)
    "ERROR ", // pnpm
    "warn:", // bun
    "error:", // bun
    "warning ", // yarn
    "error ", // yarn
    "added ", // npm summary
    "removed ", // npm summary
    "changed ", // npm summary
    "up to date", // npm/pnpm
    "up-to-date", // npm legacy
    "Already up to date", // pnpm idempotent
    "audited ", // npm
    "found 0 vulnerabilities", // npm
    "found ", // npm
    "Packages: ", // pnpm summary
    "Done in ", // pnpm / yarn summary
    "success ", // yarn (Saved / lockfile)
    "Package operations:", // composer summary
    "Lock file operations:", // composer summary
    "Nothing to install", // composer idempotent (full: "Nothing to install, update or remove")
    "No security vulnerability", // composer advisory
    "Your requirements could not be resolved", // composer error opener
};

pub fn matches(input: []const u8) bool {
    // npm summary signals
    if (std.mem.find(u8, input, "added ") != null and
        std.mem.find(u8, input, "packages") != null) return true;
    // "up to date" must appear on the same line as "audited" or "packages"
    // to avoid false positives on generic text containing both words across lines.
    if (std.mem.find(u8, input, "up to date") != null) {
        var it = std.mem.splitScalar(u8, input, '\n');
        while (it.next()) |line| {
            if (std.mem.find(u8, line, "up to date") != null and
                (std.mem.find(u8, line, "audited") != null or
                    std.mem.find(u8, line, "packages") != null)) return true;
        }
    }
    if (std.mem.find(u8, input, "audited ") != null and
        std.mem.find(u8, input, "packages") != null) return true;
    if (std.mem.find(u8, input, "npm error") != null) return true;
    if (std.mem.find(u8, input, "npm ERR!") != null) return true;
    if (std.mem.find(u8, input, "npm WARN") != null) return true;
    // pnpm signals
    if (std.mem.find(u8, input, "Packages: +") != null) return true;
    if (std.mem.find(u8, input, "Packages: -") != null) return true;
    if (std.mem.find(u8, input, "Already up to date") != null) return true;
    // bun signals — "<n> packages installed [<time>]"
    if (std.mem.find(u8, input, " packages installed [") != null) return true;
    // yarn signals
    if (std.mem.find(u8, input, "success Saved ") != null) return true;
    if (std.mem.find(u8, input, "Done in ") != null and
        std.mem.find(u8, input, "s.") != null) return true;
    // composer signals
    if (std.mem.find(u8, input, "Package operations:") != null) return true;
    if (std.mem.find(u8, input, "Lock file operations:") != null) return true;
    if (std.mem.find(u8, input, "Nothing to install") != null) return true;
    if (std.mem.find(u8, input, "No security vulnerability") != null) return true;
    if (std.mem.find(u8, input, "Your requirements could not be resolved") != null) return true;
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    if (stdout.len == 0 and stderr.len == 0) return;

    if (looksLikePnpm(stdout) or looksLikePnpm(stderr)) {
        var summary = PnpmSummary.init();
        defer summary.deinit(allocator);
        try scanPnpm(allocator, stdout, &summary);
        try scanPnpm(allocator, stderr, &summary);
        if (try summary.write(writer)) return;
    }

    if (looksLikeNpm(stdout) or looksLikeNpm(stderr)) {
        var summary = NpmSummary.init();
        defer summary.deinit(allocator);
        try scanNpm(allocator, stdout, &summary);
        try scanNpm(allocator, stderr, &summary);
        if (try summary.write(writer)) return;
    }

    if (looksLikeBunYarn(stdout) or looksLikeBunYarn(stderr)) {
        var summary = JsInstallSummary.init();
        defer summary.deinit(allocator);
        try scanBunYarn(allocator, stdout, &summary);
        try scanBunYarn(allocator, stderr, &summary);
        if (try summary.write(writer)) return;
    }

    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);

    var kept_lines: usize = 0;
    try scanAndKeep(allocator, stdout, &scratch, &kept_lines);
    try scanAndKeep(allocator, stderr, &scratch, &kept_lines);

    if (kept_lines == 0) {
        try writer.writeAll("up to date\n");
        return;
    }
    try writer.writeAll(scratch.items);
}

const NameList = struct {
    count: usize = 0,
    items: std.ArrayList(u8) = .empty,

    fn deinit(self: *NameList, allocator: Allocator) void {
        self.items.deinit(allocator);
    }

    fn add(self: *NameList, allocator: Allocator, name: []const u8) !void {
        self.count += 1;
        if (self.count > 8) return;
        if (self.items.items.len > 0) try self.items.appendSlice(allocator, ", ");
        try self.items.appendSlice(allocator, name);
    }

    fn writeSummary(self: *const NameList, writer: *Writer, label: []const u8) !bool {
        if (self.count == 0) return false;
        try writer.writeAll(label);
        try writer.writeAll(" x");
        try ansi.writeDecimal(writer, self.count);
        if (self.items.items.len > 0) {
            try writer.writeAll(": ");
            try writer.writeAll(self.items.items);
            if (self.count > 8) try writer.writeAll(", ...");
        }
        try writer.writeByte('\n');
        return true;
    }

    fn writeAddedSummary(self: *const NameList, writer: *Writer, label: []const u8) !bool {
        if (self.count == 0) return false;
        try writer.writeAll(label);
        try writer.writeAll(" +");
        try ansi.writeDecimal(writer, self.count);
        if (self.items.items.len > 0) {
            try writer.writeAll(": ");
            try writer.writeAll(self.items.items);
            if (self.count > 8) try writer.writeAll(", ...");
        }
        try writer.writeByte('\n');
        return true;
    }
};

const NpmSummary = struct {
    deprecations: NameList = .{},
    lines: std.ArrayList(u8) = .empty,

    fn init() NpmSummary {
        return .{};
    }

    fn deinit(self: *NpmSummary, allocator: Allocator) void {
        self.deprecations.deinit(allocator);
        self.lines.deinit(allocator);
    }

    fn write(self: *const NpmSummary, writer: *Writer) !bool {
        var wrote = false;
        if (try self.deprecations.writeSummary(writer, "deprecated")) wrote = true;
        if (self.lines.items.len > 0) {
            try writer.writeAll(self.lines.items);
            wrote = true;
        }
        return wrote;
    }
};

const PnpmSummary = struct {
    head: std.ArrayList(u8) = .empty,
    deprecations: NameList = .{},
    deps: NameList = .{},
    dev_deps: NameList = .{},
    tail: std.ArrayList(u8) = .empty,

    fn init() PnpmSummary {
        return .{};
    }

    fn deinit(self: *PnpmSummary, allocator: Allocator) void {
        self.head.deinit(allocator);
        self.deprecations.deinit(allocator);
        self.deps.deinit(allocator);
        self.dev_deps.deinit(allocator);
        self.tail.deinit(allocator);
    }

    fn write(self: *const PnpmSummary, writer: *Writer) !bool {
        var wrote = false;
        if (self.head.items.len > 0) {
            try writer.writeAll(self.head.items);
            wrote = true;
        }
        if (try self.deprecations.writeSummary(writer, "deprecated")) wrote = true;
        if (try self.deps.writeAddedSummary(writer, "deps")) wrote = true;
        if (try self.dev_deps.writeAddedSummary(writer, "dev")) wrote = true;
        if (self.tail.items.len > 0) {
            try writer.writeAll(self.tail.items);
            wrote = true;
        }
        return wrote;
    }
};

const JsInstallSummary = struct {
    head: std.ArrayList(u8) = .empty,
    deps: NameList = .{},
    tail: std.ArrayList(u8) = .empty,

    fn init() JsInstallSummary {
        return .{};
    }

    fn deinit(self: *JsInstallSummary, allocator: Allocator) void {
        self.head.deinit(allocator);
        self.deps.deinit(allocator);
        self.tail.deinit(allocator);
    }

    fn write(self: *const JsInstallSummary, writer: *Writer) !bool {
        var wrote = false;
        if (self.head.items.len > 0) {
            try writer.writeAll(self.head.items);
            wrote = true;
        }
        if (try self.deps.writeAddedSummary(writer, "deps")) wrote = true;
        if (self.tail.items.len > 0) {
            try writer.writeAll(self.tail.items);
            wrote = true;
        }
        return wrote;
    }
};

fn looksLikeNpm(input: []const u8) bool {
    return std.mem.find(u8, input, "npm WARN") != null or
        std.mem.find(u8, input, "npm notice") != null or
        std.mem.find(u8, input, "audited ") != null or
        std.mem.find(u8, input, "run `npm audit`") != null;
}

fn looksLikePnpm(input: []const u8) bool {
    return std.mem.find(u8, input, "Packages: +") != null or
        std.mem.find(u8, input, "Packages: -") != null or
        std.mem.find(u8, input, "Progress: ") != null or
        std.mem.find(u8, input, "Lockfile is up to date") != null or
        std.mem.find(u8, input, "\ndependencies:\n") != null or
        std.mem.find(u8, input, "\ndevDependencies:\n") != null;
}

fn looksLikeBunYarn(input: []const u8) bool {
    return std.mem.find(u8, input, "bun add v") != null or
        std.mem.find(u8, input, "bun install v") != null or
        std.mem.find(u8, input, " packages installed [") != null or
        std.mem.find(u8, input, "yarn add v") != null or
        std.mem.find(u8, input, "success Saved ") != null or
        std.mem.find(u8, input, "info Direct dependencies") != null;
}

fn scanNpm(allocator: Allocator, input: []const u8, summary: *NpmSummary) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    while (lines.next()) |raw| {
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "npm WARN deprecated ")) {
            const rest = trimmed["npm WARN deprecated ".len..];
            try summary.deprecations.add(allocator, deprecatedPackageName(rest));
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "npm WARN") or
            std.mem.startsWith(u8, trimmed, "npm ERR!") or
            std.mem.startsWith(u8, trimmed, "npm error") or
            std.mem.startsWith(u8, trimmed, "npm err!"))
        {
            try appendLine(allocator, &summary.lines, trimmed);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "added ") or
            std.mem.startsWith(u8, trimmed, "removed ") or
            std.mem.startsWith(u8, trimmed, "changed ") or
            std.mem.startsWith(u8, trimmed, "up to date") or
            std.mem.startsWith(u8, trimmed, "up-to-date") or
            std.mem.startsWith(u8, trimmed, "audited ") or
            std.mem.startsWith(u8, trimmed, "found "))
        {
            try appendLine(allocator, &summary.lines, trimmed);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "run `npm audit`")) {
            try appendLine(allocator, &summary.lines, trimmed);
        }
    }
}

fn scanPnpm(allocator: Allocator, input: []const u8, summary: *PnpmSummary) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var section: enum { none, deps, dev_deps } = .none;
    while (lines.next()) |raw| {
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "dependencies:")) {
            section = .deps;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "devDependencies:")) {
            section = .dev_deps;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "+ ")) {
            const entry = pnpmDepEntry(trimmed[2..]);
            switch (section) {
                .deps => try summary.deps.add(allocator, entry),
                .dev_deps => try summary.dev_deps.add(allocator, entry),
                .none => {},
            }
            continue;
        }
        section = .none;

        // pnpm reports packages whose install/postinstall scripts were blocked.
        // This is an actionable fact (native deps may be unbuilt until the agent
        // runs `pnpm rebuild` / `pnpm approve-builds`), so keep the header line.
        if (std.mem.startsWith(u8, trimmed, "The following dependencies have build scripts that were ignored")) {
            try appendLine(allocator, &summary.head, trimmed);
            continue;
        }

        if (std.mem.find(u8, trimmed, "deprecated ") != null and
            std.mem.startsWith(u8, trimmed, "WARN"))
        {
            const idx = std.mem.indexOf(u8, trimmed, "deprecated ") orelse unreachable;
            try summary.deprecations.add(allocator, deprecatedPackageName(trimmed[idx + "deprecated ".len ..]));
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "Already up to date")) {
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "WARN ") or
            std.mem.startsWith(u8, trimmed, "ERROR "))
        {
            try appendLine(allocator, &summary.head, trimmed);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "Packages: ") or
            std.mem.startsWith(u8, trimmed, "Done in "))
        {
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "added ") or
            std.mem.startsWith(u8, trimmed, "removed ") or
            std.mem.startsWith(u8, trimmed, "changed ") or
            std.mem.startsWith(u8, trimmed, "audited ") or
            std.mem.startsWith(u8, trimmed, "found "))
        {
            try appendLine(allocator, &summary.tail, trimmed);
            continue;
        }
    }
}

fn scanBunYarn(allocator: Allocator, input: []const u8, summary: *JsInstallSummary) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    var in_yarn_direct_deps = false;
    while (lines.next()) |raw| {
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "warn:") or
            std.mem.startsWith(u8, trimmed, "error:") or
            std.mem.startsWith(u8, trimmed, "warning ") or
            std.mem.startsWith(u8, trimmed, "error "))
        {
            try appendLine(allocator, &summary.head, trimmed);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "installed ")) {
            const pkg = firstToken(trimmed["installed ".len..]);
            if (pkg.len > 0) try summary.deps.add(allocator, pkg);
            continue;
        }

        if (std.mem.eql(u8, trimmed, "info Direct dependencies")) {
            in_yarn_direct_deps = true;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "info All dependencies")) {
            in_yarn_direct_deps = false;
            continue;
        }
        if (in_yarn_direct_deps) {
            if (yarnTreePackage(trimmed)) |pkg| {
                try summary.deps.add(allocator, pkg);
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "success Saved ") and
            std.mem.find(u8, trimmed, "lockfile") == null)
        {
            try appendLine(allocator, &summary.tail, trimmed);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "Done in ") or
            std.mem.find(u8, trimmed, " packages installed [") != null)
        {
            try appendLine(allocator, &summary.tail, trimmed);
            continue;
        }
    }
}

// A pnpm `+ <name> <version>` entry may carry trailing hints like
// "(19.2.7 is available)" or "already in devDependencies, ...". Keep only the
// "<name> <version>" pair so the deps/dev summary stays clean and factual.
fn pnpmDepEntry(rest: []const u8) []const u8 {
    var i: usize = 0;
    while (i < rest.len and rest[i] != ' ' and rest[i] != '\t') : (i += 1) {} // name
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\t')) : (i += 1) {} // gap
    while (i < rest.len and rest[i] != ' ' and rest[i] != '\t') : (i += 1) {} // version
    return std.mem.trimEnd(u8, rest[0..i], " \t");
}

fn appendLine(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn deprecatedPackageName(rest: []const u8) []const u8 {
    var token_end: usize = 0;
    while (token_end < rest.len and rest[token_end] != ':' and rest[token_end] != ' ' and rest[token_end] != '\t') : (token_end += 1) {}
    const token = rest[0..token_end];
    if (std.mem.lastIndexOfScalar(u8, token, '@')) |at| {
        if (at > 0) return token[0..at];
    }
    return token;
}

fn scanAndKeep(allocator: Allocator, input: []const u8, out: *std.ArrayList(u8), kept: *usize) !void {
    if (input.len == 0) return;
    var lines = std.mem.splitScalar(u8, input, '\n');
    const head_cap: usize = 60;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    while (lines.next()) |raw| {
        if (kept.* >= head_cap) break;
        const line = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (!shouldKeep(trimmed)) continue;
        try writeLine(allocator, trimmed, out);
        kept.* += 1;
    }
}

fn writeLine(allocator: Allocator, line: []const u8, out: *std.ArrayList(u8)) !void {
    // Keep original kept lines verbatim (after ANSI stripping in caller).
    try out.appendSlice(allocator, line);
    try out.append(allocator, '\n');
}

fn numberAfter(line: []const u8, marker: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, line, marker) orelse return null;
    var j = i + marker.len;
    const start = j;
    while (j < line.len and std.ascii.isDigit(line[j])) : (j += 1) {}
    if (j == start) return null;
    return line[start..j];
}

fn firstToken(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r");
    var i: usize = 0;
    while (i < t.len and t[i] != ' ' and t[i] != '\t') : (i += 1) {}
    return t[0..i];
}

fn yarnTreePackage(line: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < line.len and !isPackageStart(line[start])) : (start += 1) {}
    if (start >= line.len) return null;
    var end = start;
    while (end < line.len and line[end] != ' ' and line[end] != '\t') : (end += 1) {}
    return line[start..end];
}

fn isPackageStart(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '@';
}

fn shouldKeep(line: []const u8) bool {
    // Explicit drops take priority.
    if (std.mem.startsWith(u8, line, "npm notice")) return false;
    if (std.mem.find(u8, line, "packages are looking for funding") != null) return false;
    if (std.mem.startsWith(u8, line, "run `npm ")) return false;
    // pnpm / bun / yarn chatter that survives ANSI strip.
    if (std.mem.startsWith(u8, line, "Progress: ")) return false; // pnpm progress
    if (std.mem.startsWith(u8, line, "Lockfile is up to date")) return false; // pnpm header
    if (std.mem.startsWith(u8, line, "bun add v")) return false; // bun banner
    if (std.mem.startsWith(u8, line, "bun install v")) return false; // bun banner
    if (std.mem.startsWith(u8, line, "bun remove v")) return false; // bun banner
    if (std.mem.startsWith(u8, line, "yarn add v")) return false; // yarn banner
    if (std.mem.startsWith(u8, line, "yarn install v")) return false; // yarn banner
    if (std.mem.startsWith(u8, line, "yarn remove v")) return false; // yarn banner
    if (std.mem.startsWith(u8, line, "[1/4]") or std.mem.startsWith(u8, line, "[2/4]") or
        std.mem.startsWith(u8, line, "[3/4]") or std.mem.startsWith(u8, line, "[4/4]")) return false;
    if (std.mem.startsWith(u8, line, "info ")) return false; // yarn dep tree info
    if (std.mem.startsWith(u8, line, "installed ")) return false; // bun per-pkg line; count summary survives
    // composer scaffolding/chatter — summary lines above cover the actionable
    // signal; per-package "  - Downloading/Installing/Locking" is redundant.
    if (std.mem.startsWith(u8, line, "Loading composer repositories")) return false;
    if (std.mem.startsWith(u8, line, "Updating dependencies")) return false;
    if (std.mem.startsWith(u8, line, "Installing dependencies from lock file")) return false;
    if (std.mem.startsWith(u8, line, "Writing lock file")) return false;
    if (std.mem.startsWith(u8, line, "Generating ")) return false; // "Generating optimized autoload files"
    if (std.mem.startsWith(u8, line, "Verifying lock file")) return false;
    if (std.mem.startsWith(u8, line, "Running composer ")) return false;
    if (std.mem.startsWith(u8, line, "Discovered Package:")) return false;
    // "Using version ^X.Y for foo/bar" is the resolved version of a require —
    // the most actionable signal of a composer require call.
    if (std.mem.startsWith(u8, line, "Using version ")) return true;
    if (std.mem.startsWith(u8, line, "Use the `composer ")) return false;
    if (std.mem.startsWith(u8, line, "./composer.json has been updated")) return false;
    if (std.mem.startsWith(u8, line, "> @")) return false; // composer script hooks (e.g. "> @php artisan ...")
    if (std.mem.startsWith(u8, line, "- Downloading ") or
        std.mem.startsWith(u8, line, "- Installing ") or
        std.mem.startsWith(u8, line, "- Locking ") or
        std.mem.startsWith(u8, line, "- Removing ")) return false; // composer per-pkg
    // "<n> packages you rely on are looking for funding" — composer fund pitch
    if (std.mem.find(u8, line, "packages you rely on are looking for funding") != null) return false;
    // "<n> packages installed [<time>]" — bun summary (no fixed prefix).
    if (std.mem.find(u8, line, " packages installed [") != null) return true;
    for (KEEP_PREFIXES) |p| {
        if (std.mem.startsWith(u8, line, p)) return true;
    }
    return false;
}

test "matches: added packages" {
    try std.testing.expect(matches("added 42 packages in 3s\n"));
}

test "matches: up to date" {
    try std.testing.expect(matches("up to date, audited 42 packages in 1s\n"));
}

test "matches: npm WARN alone" {
    try std.testing.expect(matches("npm WARN deprecated foo@1.0.0\n"));
}

test "matches: rejects non-npm" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("hello\n"));
}

test "apply: fixture keeps WARN + summary, drops notice + funding noise" {
    const input = @embedFile("fixture_npm_install");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    try std.testing.expect(std.mem.find(u8, got, "deprecated x5: lodash.isequal, rimraf, inflight, glob, querystring") != null);
    try std.testing.expect(std.mem.find(u8, got, "added 847 packages") != null);
    try std.testing.expect(std.mem.find(u8, got, "found 2 vulnerabilities") != null);
    try std.testing.expect(std.mem.find(u8, got, "run `npm audit` for details") != null);
    // Dropped noise.
    try std.testing.expect(std.mem.find(u8, got, "npm WARN deprecated") == null);
    try std.testing.expect(std.mem.find(u8, got, "npm notice") == null);
    try std.testing.expect(std.mem.find(u8, got, "packages are looking for funding") == null);
    try std.testing.expect(std.mem.find(u8, got, "run `npm fund`") == null);
}

test "apply: silent run emits 'up to date'" {
    const input = "\n\n\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    try std.testing.expectEqualStrings("up to date\n", out.written());
}

test "apply: strips ANSI" {
    const input = "\x1b[32madded 5 packages\x1b[0m in 1s\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\x1b") == null);
    try std.testing.expect(std.mem.find(u8, got, "added 5 packages") != null);
}

test "matches: pnpm Packages summary" {
    try std.testing.expect(matches("Packages: +3\n+++\nDone in 1.2s\n"));
}

test "matches: bun packages installed" {
    try std.testing.expect(matches(" 3 packages installed [1.23s]\n"));
}

test "matches: yarn success Saved" {
    try std.testing.expect(matches("success Saved 5 new dependencies.\nDone in 5.32s.\n"));
}

test "apply: pnpm fixture summarizes WARN + deps, drops duplicate progress/count lines" {
    const input = @embedFile("fixture_pnpm_install");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    try std.testing.expect(std.mem.find(u8, got, "deprecated x2: lodash.isequal, rimraf") != null);
    try std.testing.expect(std.mem.find(u8, got, "deps +2: react 18.2.0, react-dom 18.2.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "dev +1: vite 5.0.0") != null);
    // Dropped chatter.
    try std.testing.expect(std.mem.find(u8, got, "Progress: ") == null);
    try std.testing.expect(std.mem.find(u8, got, "Lockfile is up to date") == null);
    try std.testing.expect(std.mem.find(u8, got, "Already up to date") == null);
    try std.testing.expect(std.mem.find(u8, got, "Packages: +3") == null);
    try std.testing.expect(std.mem.find(u8, got, "Done in 1.2s") == null);
    try std.testing.expect(std.mem.find(u8, got, "WARN  deprecated") == null);
}

test "apply: pnpm9 fixture trims version hints and keeps ignored-build-scripts warning" {
    const input = @embedFile("fixture_pnpm9_install");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    // Dep entries are clean "<name> <version>" — the "(x is available)" upgrade
    // hint is dropped, matching the established deps/dev grammar.
    try std.testing.expect(std.mem.find(u8, got, "deps +2: react 18.2.0, react-dom 18.2.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "dev +1: vite 5.0.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "is available") == null);
    // The ignored-build-scripts warning is an actionable fact — keep it.
    try std.testing.expect(std.mem.find(u8, got, "build scripts that were ignored: esbuild") != null);
    // Progress / Packages / Done chatter is still dropped.
    try std.testing.expect(std.mem.find(u8, got, "Progress: ") == null);
    try std.testing.expect(std.mem.find(u8, got, "Packages: +16") == null);
    try std.testing.expect(std.mem.find(u8, got, "Done in ") == null);
}

test "apply: bun fixture keeps warn + dependency summary, drops banner + raw per-pkg" {
    const input = @embedFile("fixture_bun_install");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    try std.testing.expect(std.mem.find(u8, got, "warn: deprecated lodash.isequal") != null);
    try std.testing.expect(std.mem.find(u8, got, "deps +3: react@18.2.0, react-dom@18.2.0, vite@5.0.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "3 packages installed [1.23s]") != null);
    // Dropped banner + per-package adds.
    try std.testing.expect(std.mem.find(u8, got, "bun add v") == null);
    try std.testing.expect(std.mem.find(u8, got, "installed react@18.2.0\n") == null);
}

test "matches: composer Package operations" {
    try std.testing.expect(matches("Package operations: 4 installs, 0 updates, 0 removals\n"));
}

test "matches: composer Nothing to install" {
    try std.testing.expect(matches("Nothing to install, update or remove\n"));
}

test "apply: composer require fixture keeps summary + advisory, drops scaffolding" {
    const input = @embedFile("fixture_composer_require");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    // Kept: summary lines + advisory + resolved version.
    try std.testing.expect(std.mem.find(u8, got, "Lock file operations: 4 installs") != null);
    try std.testing.expect(std.mem.find(u8, got, "Package operations: 4 installs") != null);
    try std.testing.expect(std.mem.find(u8, got, "No security vulnerability advisories found") != null);
    try std.testing.expect(std.mem.find(u8, got, "Using version ^7.8 for guzzlehttp/guzzle") != null);
    // Dropped scaffolding.
    try std.testing.expect(std.mem.find(u8, got, "Loading composer repositories") == null);
    try std.testing.expect(std.mem.find(u8, got, "Writing lock file") == null);
    try std.testing.expect(std.mem.find(u8, got, "Generating ") == null);
    try std.testing.expect(std.mem.find(u8, got, "Discovered Package:") == null);
    try std.testing.expect(std.mem.find(u8, got, "Use the `composer fund`") == null);
    try std.testing.expect(std.mem.find(u8, got, "> @php artisan") == null);
    // Per-package install/download lines dropped (summary covers them).
    try std.testing.expect(std.mem.find(u8, got, "- Downloading guzzlehttp") == null);
    try std.testing.expect(std.mem.find(u8, got, "- Installing guzzlehttp") == null);
}

test "apply: yarn fixture keeps warning + direct dependency summary, drops banner + transitive tree" {
    const input = @embedFile("fixture_yarn_install");
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, &.{}, &out.writer);
    const got = out.written();
    try std.testing.expect(got.len < input.len);
    try std.testing.expect(std.mem.find(u8, got, "warning ") != null);
    try std.testing.expect(std.mem.find(u8, got, "deps +3: react@18.2.0, react-dom@18.2.0, vite@5.0.0") != null);
    try std.testing.expect(std.mem.find(u8, got, "success Saved 3 new dependencies") != null);
    try std.testing.expect(std.mem.find(u8, got, "Done in 5.32s") != null);
    // Dropped banner + progress + dep tree.
    try std.testing.expect(std.mem.find(u8, got, "yarn add v") == null);
    try std.testing.expect(std.mem.find(u8, got, "[1/4]") == null);
    try std.testing.expect(std.mem.find(u8, got, "info Direct") == null);
    try std.testing.expect(std.mem.find(u8, got, "scheduler@0.23.0") == null);
}
