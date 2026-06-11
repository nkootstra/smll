const std = @import("std");
const ansi = @import("ansi");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const terraform_box_prefix = "\xe2\x94\x82 ";

pub fn matches(input: []const u8) bool {
    return std.mem.find(u8, input, "Terraform will perform") != null or
        std.mem.find(u8, input, "OpenTofu will perform") != null or
        std.mem.find(u8, input, "Plan: ") != null or
        std.mem.find(u8, input, "No changes.") != null or
        std.mem.find(u8, input, "Error: ") != null or
        std.mem.find(u8, input, "Warning: ") != null;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    var emitted = try scan(allocator, stdout, writer);
    emitted = try scan(allocator, stderr, writer) or emitted;
    if (!emitted and (stdout.len > 0 or stderr.len > 0)) {
        try writer.writeAll("plan ok\n");
    }
}

fn scan(allocator: Allocator, input: []const u8, writer: *Writer) !bool {
    if (input.len == 0) return false;
    var emitted = false;
    var strip_buf: std.ArrayList(u8) = .empty;
    defer strip_buf.deinit(allocator);
    // The symbol legend ("~ update in-place", "-/+ destroy and then create
    // replacement") precedes the actions block and reuses the same sigils as
    // real diffs. Only treat sigil lines as attribute-level facts once we are
    // inside the actions block.
    var in_actions = false;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const clean = ansi.stripInto(&strip_buf, allocator, raw) catch raw;
        const line = std.mem.trim(u8, clean, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "will perform the following actions") != null) in_actions = true;
        if (shouldKeep(line, in_actions)) {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            emitted = true;
        }
    }
    return emitted;
}

fn shouldKeep(line: []const u8, in_actions: bool) bool {
    if (std.mem.startsWith(u8, line, "Plan: ")) return true;
    if (std.mem.startsWith(u8, line, "No changes.")) return true;
    const diagnostic = withoutTerraformBoxPrefix(line);
    if (std.mem.startsWith(u8, diagnostic, "Error: ")) return true;
    if (std.mem.startsWith(u8, diagnostic, "Warning: ")) return true;
    if (std.mem.startsWith(u8, line, "Terraform will perform")) return true;
    if (std.mem.startsWith(u8, line, "OpenTofu will perform")) return true;
    // Resource-action comment headers: "# X will be created", "# X must be replaced".
    if (std.mem.startsWith(u8, line, "# ") and
        (std.mem.indexOf(u8, line, " will be ") != null or
            std.mem.indexOf(u8, line, " must be ") != null)) return true;
    if (std.mem.startsWith(u8, line, "+ resource ")) return true;
    if (std.mem.startsWith(u8, line, "- resource ")) return true;
    if (std.mem.startsWith(u8, line, "~ resource ")) return true;
    if (std.mem.startsWith(u8, line, "-/+ resource ")) return true;
    // Attribute-level diffs and forced-replacement notes are facts an agent
    // acts on, but only inside the actions block (legend lines share sigils).
    if (in_actions) {
        if (std.mem.indexOf(u8, line, "# forces replacement") != null) return true;
        if (std.mem.startsWith(u8, line, "-/+ ")) return true;
        if (std.mem.startsWith(u8, line, "~ ")) return true;
        if (std.mem.startsWith(u8, line, "+ ")) return true;
        if (std.mem.startsWith(u8, line, "- ")) return true;
    }
    return false;
}

fn withoutTerraformBoxPrefix(line: []const u8) []const u8 {
    if (std.mem.startsWith(u8, line, terraform_box_prefix)) {
        return line[terraform_box_prefix.len..];
    }
    return line;
}

test "terraform plan drops refresh chatter and keeps summary" {
    const input =
        "random_pet.name: Refreshing state... [id=calm-raven]\n" ++
        "Terraform will perform the following actions:\n" ++
        "  # aws_s3_bucket.example will be created\n" ++
        "  + resource \"aws_s3_bucket\" \"example\" {\n" ++
        "Plan: 1 to add, 0 to change, 0 to destroy.\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, input, "", &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "Refreshing state") == null);
    try std.testing.expect(std.mem.find(u8, got, "# aws_s3_bucket.example") != null);
    try std.testing.expect(std.mem.find(u8, got, "Plan: 1 to add") != null);
}

const tofu_plan_update_fixture = @embedFile("fixture_tofu_plan_update");

test "tofu plan keeps attribute-level diffs and forced-replacement notes" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(matches(tofu_plan_update_fixture));
    try apply(std.testing.allocator, tofu_plan_update_fixture, "", &out.writer);
    const got = out.written();

    // Attribute-level changes are the facts an agent decides on.
    try std.testing.expect(std.mem.find(u8, got, "~ input  = \"small\" -> \"large\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "# forces replacement") != null);
    try std.testing.expect(std.mem.find(u8, got, "\"version\" = \"1\" -> \"2\"") != null);
    // Resource headers and the summary survive.
    try std.testing.expect(std.mem.find(u8, got, "-/+ resource \"null_resource\" \"db\"") != null);
    try std.testing.expect(std.mem.find(u8, got, "Plan: 1 to add, 1 to change, 1 to destroy.") != null);
    // Refresh chatter is still dropped.
    try std.testing.expect(std.mem.find(u8, got, "Refreshing state") == null);
    // The symbol legend (before the actions block) is NOT mistaken for a diff.
    try std.testing.expect(std.mem.find(u8, got, "update in-place (current") == null);
    try std.testing.expect(std.mem.find(u8, got, "destroy and then create replacement") == null);
}

test "terraform plan keeps box-drawing diagnostics" {
    const input =
        "\xe2\x95\xb7\n" ++
        "\xe2\x94\x82 Error: Provider configuration not present\n" ++
        "\xe2\x94\x82\n" ++
        "\xe2\x94\x82 Warning: Argument is deprecated\n" ++
        "\xe2\x95\xb5\n";

    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expect(matches(input));
    try apply(std.testing.allocator, "", input, &out.writer);

    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "\xe2\x94\x82 Error: Provider configuration not present") != null);
    try std.testing.expect(std.mem.find(u8, got, "\xe2\x94\x82 Warning: Argument is deprecated") != null);
    try std.testing.expect(std.mem.find(u8, got, "plan ok") == null);
}
