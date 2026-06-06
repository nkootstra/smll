const std = @import("std");

pub const auto_wrap_shell_case =
    "git|rg|tree|find|docker|kubectl|gh|ps|ls|df|du|curl|make|cargo|zig|go|" ++
    "pytest|jest|vitest|tsc|eslint|biome|next|npm|pnpm|yarn|bun|cat|" ++
    "composer|gradle|gradlew|mvn|mvnw|pre-commit|terraform|tofu|aws|jq|" ++
    "psql|systemctl|lsof|brew";

pub const auto_wrap_js_array =
    "\"git\",\"rg\",\"tree\",\"find\",\"docker\",\"kubectl\",\"gh\",\"ps\",\"ls\",\"df\",\"du\"," ++
    "\"curl\",\"make\",\"cargo\",\"zig\",\"go\",\"pytest\",\"jest\",\"vitest\",\"tsc\"," ++
    "\"eslint\",\"biome\",\"next\",\"npm\",\"pnpm\",\"yarn\",\"bun\",\"cat\",\"composer\"," ++
    "\"gradle\",\"gradlew\",\"mvn\",\"mvnw\",\"pre-commit\",\"terraform\",\"tofu\",\"aws\"," ++
    "\"jq\",\"psql\",\"systemctl\",\"lsof\",\"brew\"";

pub fn shouldAutoWrap(command: []const u8) bool {
    var commands = std.mem.splitScalar(u8, auto_wrap_shell_case, '|');
    while (commands.next()) |candidate| {
        if (std.mem.eql(u8, command, candidate)) return true;
    }
    return false;
}

pub fn write(stdout: *std.Io.Writer) !void {
    try stdout.writeAll("smll filters\n\nAuto-wrap: ");
    try stdout.writeAll(auto_wrap_shell_case);
    try stdout.writeAll("\n\nDedicated: next build eslint terraform plan aws gradle pre-commit\n");
}

test "catalog names high-value filters" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer);
    const rendered = out.written();

    try std.testing.expect(std.mem.find(u8, auto_wrap_shell_case, "terraform") != null);
    try std.testing.expect(std.mem.find(u8, auto_wrap_js_array, "\"aws\"") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "next build") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "terraform plan") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "eslint") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "aws") != null);
}

test "auto-wrap lookup uses the hook command catalog" {
    try std.testing.expect(shouldAutoWrap("git"));
    try std.testing.expect(shouldAutoWrap("pre-commit"));
    try std.testing.expect(!shouldAutoWrap("python"));
}

test "auto-wrap shell and js catalogs stay in sync" {
    var shell_commands = std.mem.splitScalar(u8, auto_wrap_shell_case, '|');
    while (shell_commands.next()) |command| {
        var quoted_buf: [64]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{command});
        try std.testing.expect(std.mem.find(u8, auto_wrap_js_array, quoted) != null);
    }

    var js_commands = std.mem.splitScalar(u8, auto_wrap_js_array, ',');
    while (js_commands.next()) |quoted| {
        try std.testing.expect(quoted.len >= 2);
        try std.testing.expect(quoted[0] == '"' and quoted[quoted.len - 1] == '"');
        try std.testing.expect(shouldAutoWrap(quoted[1 .. quoted.len - 1]));
    }
}
