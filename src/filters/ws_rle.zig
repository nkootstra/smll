const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// Experimental whitespace RLE — NOT wired into default dispatch.
//
// Lossless encoding of space runs for columnar output (docker ps, kubectl get,
// ls -la).  Measured on cl100k_base tokens: this filter yields byte savings
// (~25-30% on docker ps) but TOKEN REGRESSION (-3 to -8%).  Root cause: the
// tokenizer encodes runs of up to ~128 spaces as a single token, while the
// \x01+len sigil form costs 2 tokens.  Kept in-tree as a reference for future
// lossless-and-token-aware columnar compression experiments.
//
// Encoding:
//   runs of N spaces where N ≥ 3 → SIGIL (0x01) + byte(N)
//   literal SIGIL byte in input  → SIGIL + 0x00  (escape)
//   everything else              → verbatim
//
// Decoding:
//   SIGIL + 0x00     → emit one SIGIL byte
//   SIGIL + N (N≥3)  → emit N space bytes
//   (length bytes 1 and 2 are reserved/unused — decoder treats them as errors)
//
// Byte-exact lossless.  Collision-safe: only SIGIL is reserved; when it appears
// naturally in input it is escaped.
//
// Threshold rationale: runs of 1-2 spaces are left verbatim because the sigil
// form (2 bytes) would not shrink them; runs of exactly 3 spaces are a break-
// even but the decoder benefits from a consistent rule.  Runs up to 255 are
// encoded in a single pair; longer runs are split into chunks of 255.

pub const SIGIL: u8 = 0x01;
// Threshold derivation: cl100k_base (GPT/Claude tokenizer) encodes runs of up
// to ~16 spaces as a single token.  The \x01+len escape form costs 2 tokens
// (control char + length byte).  Only runs of ≥17 produce a net token win, so
// that's our minimum.  Runs shorter than that pass through verbatim — they
// cost the same or fewer tokens as raw spaces.
const MIN_RUN: usize = 17;
const MAX_RUN: u8 = 255;

pub fn matches(input: []const u8) bool {
    if (input.len == 0) return false;
    // Heuristic: any of the first ~1 KB must contain a run of MIN_RUN spaces.
    // Most per-line columnar formatters hit this on every data row.
    const scan = input[0..@min(input.len, 1024)];
    var run: usize = 0;
    for (scan) |c| {
        if (c == ' ') {
            run += 1;
            if (run >= MIN_RUN) return true;
        } else {
            run = 0;
        }
    }
    return false;
}

pub fn apply(allocator: Allocator, stdout: []const u8, stderr: []const u8, writer: *Writer) !void {
    _ = allocator;
    _ = stderr;
    if (stdout.len == 0) return;

    var i: usize = 0;
    while (i < stdout.len) {
        const c = stdout[i];
        if (c == SIGIL) {
            // Escape literal sigil.
            try writer.writeByte(SIGIL);
            try writer.writeByte(0x00);
            i += 1;
        } else if (c == ' ') {
            // Measure run length.
            var j = i;
            while (j < stdout.len and stdout[j] == ' ') j += 1;
            var run = j - i;
            if (run < MIN_RUN) {
                // Pass through verbatim — cheaper than encoded form.
                while (i < j) : (i += 1) try writer.writeByte(' ');
            } else {
                // Emit SIGIL+len chunks. Split at MAX_RUN.
                while (run > 0) {
                    const chunk = @min(run, @as(usize, MAX_RUN));
                    if (chunk < MIN_RUN) {
                        // Trailing tail too short — emit verbatim.
                        var k: usize = 0;
                        while (k < chunk) : (k += 1) try writer.writeByte(' ');
                    } else {
                        try writer.writeByte(SIGIL);
                        try writer.writeByte(@intCast(chunk));
                    }
                    run -= chunk;
                }
                i = j;
            }
        } else {
            try writer.writeByte(c);
            i += 1;
        }
    }
}

pub fn decode(allocator: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == SIGIL) {
            if (i + 1 >= input.len) return error.TruncatedSigil;
            const n = input[i + 1];
            if (n == 0x00) {
                try out.append(allocator, SIGIL);
            } else if (n >= MIN_RUN) {
                var k: u8 = 0;
                while (k < n) : (k += 1) try out.append(allocator, ' ');
            } else {
                return error.InvalidRunLength;
            }
            i += 2;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture_docker_ps = @embedFile("fixture_docker_ps");
const fixture_ls_la = @embedFile("fixture_ls_la");

fn applyToString(a: Allocator, input: []const u8) ![]u8 {
    var out = Writer.Allocating.init(a);
    defer out.deinit();
    try apply(a, input, &.{}, &out.writer);
    return a.dupe(u8, out.written());
}

fn roundTrip(a: Allocator, input: []const u8) !void {
    const encoded = try applyToString(a, input);
    defer a.free(encoded);
    const decoded = try decode(a, encoded);
    defer a.free(decoded);
    try std.testing.expectEqualStrings(input, decoded);
}

test "matches: wide columnar input accepted" {
    // 17+ space run required.
    var buf: [50]u8 = undefined;
    buf[0] = 'a';
    @memset(buf[1..20], ' ');
    buf[20] = 'b';
    buf[21] = '\n';
    try std.testing.expect(matches(buf[0..22]));
    try std.testing.expect(matches(fixture_docker_ps));
}

test "matches: short runs rejected" {
    try std.testing.expect(!matches("a b c\n"));
    try std.testing.expect(!matches("a  b  c\n")); // 2 spaces
    try std.testing.expect(!matches("a   b   c\n")); // 3 spaces
    try std.testing.expect(!matches("a                b\n")); // 16 spaces
}

test "matches: empty rejected" {
    try std.testing.expect(!matches(""));
}

test "round-trip: empty" {
    try roundTrip(std.testing.allocator, "");
}

test "round-trip: short run passes through" {
    try roundTrip(std.testing.allocator, "a   b\n");
}

test "round-trip: long run compressed" {
    try roundTrip(std.testing.allocator, "a                     b\n"); // 21 spaces
}

test "round-trip: run at line start" {
    try roundTrip(std.testing.allocator, "                     abc\n");
}

test "round-trip: run at EOF no newline" {
    try roundTrip(std.testing.allocator, "abc                     ");
}

test "round-trip: literal sigil escape" {
    // Contains a literal 0x01 in input — must round-trip.
    try roundTrip(std.testing.allocator, "a\x01b\n");
}

test "round-trip: mixed short runs and long run" {
    try roundTrip(std.testing.allocator, "a b  c   d                     e\n");
}

test "round-trip: run longer than 255" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.append(a, 'x');
    var i: usize = 0;
    while (i < 300) : (i += 1) try buf.append(a, ' ');
    try buf.append(a, 'y');
    try roundTrip(a, buf.items);
}

test "round-trip: docker ps fixture" {
    try roundTrip(std.testing.allocator, fixture_docker_ps);
}

test "round-trip: ls -la fixture" {
    try roundTrip(std.testing.allocator, fixture_ls_la);
}

test "compression: docker ps shrinks on wide padding" {
    const a = std.testing.allocator;
    const out = try applyToString(a, fixture_docker_ps);
    defer a.free(out);
    // docker ps pads IMAGE and PORTS columns with ~30-50 space runs; those
    // produce real byte + token savings.  Narrower 3-4 space gaps pass through.
    try std.testing.expect(out.len < fixture_docker_ps.len);
}

test "compression: ls -la passes through unchanged" {
    const a = std.testing.allocator;
    const out = try applyToString(a, fixture_ls_la);
    defer a.free(out);
    // ls -la columns use 1-4 space gaps — all below the 17-byte threshold.
    try std.testing.expectEqualStrings(fixture_ls_la, out);
}
