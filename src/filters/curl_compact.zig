const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

// LOSSY compact filter for `curl -v` / `-vv` / `-vvv` — on by default
// (v0.6). Set SMLL_LOSSLESS=1 to bypass.
//
// Non-standard contract: inspects stderr (not stdout). curl emits its
// protocol trace to stderr; the response body lands on stdout.
//
// Transformations:
//   • Keep lines beginning with `>` (request headers) and `<` (response
//     headers + status line).
//   • Keep meta-events worth knowing: `* Connected to`, `* Trying`,
//     `* Closing`, `* Host:`.
//   • Drop the TLS handshake chatter: `* TLSv1.x`, `* SSL connection`,
//     `*   subject:`, `*   issuer:`, `*   SSL certificate verify`,
//     `*   start date:`, `*   expire date:`, `*   common name:`, and
//     the `* Server certificate:` block.
//   • Drop PEM-encoded certificate blocks (`-----BEGIN CERTIFICATE-----`
//     through `-----END CERTIFICATE-----`, inclusive).
//
// Output shape (when stdout is non-empty):
//   --- headers ---
//   <filtered stderr>
//   --- body ---
//   <stdout verbatim>
//
// When stdout is empty, only the filtered stderr block is emitted (no
// `--- body ---` separator).

const KEEP_META_PREFIXES = [_][]const u8{
    "* Connected to",
    "* Trying",
    "* Closing",
    "* Host:",
    "* Request completely sent",
    "* HTTP/",
    "* Mark bundle",
    "* schannel:",
    "* Rebuilt URL to:",
    "* Re-using existing connection",
};

const DROP_META_PREFIXES = [_][]const u8{
    "* TLSv",
    "* SSL connection",
    "* ALPN",
    "* Server certificate:",
    "*   subject:",
    "*   issuer:",
    "*   SSL certificate verify",
    "*   start date:",
    "*   expire date:",
    "*   common name:",
    "*   subjectAltName:",
    "*   using ",
    "* Server auth using",
    "* Using HTTP",
    "* schannel: encrypted data",
    "* schannel: decrypted data",
    "*  CAfile:",
    "*  CApath:",
};

pub fn matches(stderr: []const u8) bool {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const c = line[0];
        if (c == '*' or c == '>' or c == '<') return true;
    }
    return false;
}

/// `argv` must contain one of `-v`, `-vv`, `-vvv`, or `--verbose`, OR
/// any combined short-flag cluster containing `v`. Mirrors hasSummarizeFlag
/// in du_compact.
pub fn hasVerboseFlag(argv: []const []const u8) bool {
    for (argv) |a| {
        if (std.mem.eql(u8, a, "--verbose")) return true;
        if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            if (std.mem.find(u8, a[1..], "v") != null) return true;
        }
    }
    return false;
}

pub fn apply(
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    writer: *Writer,
) !void {
    _ = allocator;

    const has_stderr_content = stderr.len > 0 and matches(stderr);
    if (has_stderr_content) {
        if (stdout.len > 0) try writer.writeAll("--- headers ---\n");
        try emitFilteredStderr(writer, stderr);
    }

    if (stdout.len > 0) {
        if (has_stderr_content) try writer.writeAll("--- body ---\n");
        try writer.writeAll(stdout);
    }
}

fn emitFilteredStderr(writer: *Writer, stderr: []const u8) !void {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    var in_cert_block = false;
    var in_server_cert_block = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;

        // PEM cert block spans `-----BEGIN CERTIFICATE-----` through
        // `-----END CERTIFICATE-----`. Drop everything inside.
        if (std.mem.find(u8, line, "-----BEGIN CERTIFICATE-----") != null) {
            in_cert_block = true;
            continue;
        }
        if (in_cert_block) {
            if (std.mem.find(u8, line, "-----END CERTIFICATE-----") != null) {
                in_cert_block = false;
            }
            continue;
        }

        // `* Server certificate:` block runs until the next line whose first
        // char is NOT `*` (e.g. `> GET /`).
        if (std.mem.startsWith(u8, line, "* Server certificate:")) {
            in_server_cert_block = true;
            continue;
        }
        if (in_server_cert_block) {
            if (line.len == 0 or line[0] != '*') {
                in_server_cert_block = false;
                // Fall through — the current line is NOT part of the cert
                // block, so re-classify it below.
            } else {
                continue;
            }
        }

        if (line[0] == '>' or line[0] == '<') {
            try writer.writeAll(line);
            try writer.writeByte('\n');
            continue;
        }

        if (line[0] == '*') {
            if (shouldDropMeta(line)) continue;
            if (shouldKeepMeta(line)) {
                try writer.writeAll(line);
                try writer.writeByte('\n');
            }
            continue;
        }

        // Non-verbose lines on stderr — pass through (e.g. error messages
        // curl writes to stderr before entering verbose mode).
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
}

fn shouldKeepMeta(line: []const u8) bool {
    for (KEEP_META_PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

fn shouldDropMeta(line: []const u8) bool {
    for (DROP_META_PREFIXES) |prefix| {
        if (std.mem.startsWith(u8, line, prefix)) return true;
    }
    return false;
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "matches: curl -v stderr" {
    const stderr = "*   Trying 1.2.3.4:443...\n* Connected to example.com (1.2.3.4) port 443\n> GET / HTTP/1.1\n< HTTP/1.1 200 OK\n";
    try std.testing.expect(matches(stderr));
}

test "matches: rejects non-curl stderr" {
    try std.testing.expect(!matches(""));
    try std.testing.expect(!matches("error: something went wrong\n"));
    try std.testing.expect(!matches("warning: foo\nnote: bar\n"));
}

test "hasVerboseFlag: detects short/long/clustered forms" {
    try std.testing.expect(hasVerboseFlag(&.{ "curl", "-v" }));
    try std.testing.expect(hasVerboseFlag(&.{ "curl", "-vv" }));
    try std.testing.expect(hasVerboseFlag(&.{ "curl", "-vvv" }));
    try std.testing.expect(hasVerboseFlag(&.{ "curl", "--verbose" }));
    try std.testing.expect(hasVerboseFlag(&.{ "curl", "-sv" }));
    try std.testing.expect(hasVerboseFlag(&.{ "curl", "-Lv" }));
    try std.testing.expect(!hasVerboseFlag(&.{ "curl", "https://example.com" }));
    try std.testing.expect(!hasVerboseFlag(&.{ "curl", "-s" }));
    try std.testing.expect(!hasVerboseFlag(&.{ "curl", "--foo=vbar" }));
}

test "apply: keeps status line, headers, body; drops TLS chatter" {
    const stderr =
        "*   Trying 1.2.3.4:443...\n" ++
        "* Connected to example.com (1.2.3.4) port 443\n" ++
        "* ALPN: server accepted h2\n" ++
        "* TLSv1.3 (OUT), TLS handshake, Client hello (1):\n" ++
        "* TLSv1.3 (IN), TLS handshake, Server hello (2):\n" ++
        "* Server certificate:\n" ++
        "*   subject: CN=example.com\n" ++
        "*   issuer: O=Let's Encrypt, CN=R3\n" ++
        "*   SSL certificate verify ok.\n" ++
        "> GET / HTTP/2\n" ++
        "> Host: example.com\n" ++
        "> User-Agent: curl/8.0\n" ++
        "< HTTP/2 200\n" ++
        "< content-type: text/html\n" ++
        "< content-length: 1256\n" ++
        "* Connection #0 to host example.com left intact\n";
    const stdout = "<html>body</html>\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, stdout, stderr, &out.writer);
    const got = out.written();
    // Kept
    try std.testing.expect(std.mem.find(u8, got, "* Connected to example.com") != null);
    try std.testing.expect(std.mem.find(u8, got, "> GET / HTTP/2") != null);
    try std.testing.expect(std.mem.find(u8, got, "< HTTP/2 200") != null);
    try std.testing.expect(std.mem.find(u8, got, "< content-type: text/html") != null);
    try std.testing.expect(std.mem.find(u8, got, "<html>body</html>") != null);
    try std.testing.expect(std.mem.find(u8, got, "--- headers ---") != null);
    try std.testing.expect(std.mem.find(u8, got, "--- body ---") != null);
    // Dropped
    try std.testing.expect(std.mem.find(u8, got, "TLSv1.3") == null);
    try std.testing.expect(std.mem.find(u8, got, "subject:") == null);
    try std.testing.expect(std.mem.find(u8, got, "issuer:") == null);
    try std.testing.expect(std.mem.find(u8, got, "ALPN:") == null);
    try std.testing.expect(std.mem.find(u8, got, "SSL certificate verify") == null);
}

test "apply: drops PEM cert block" {
    const stderr =
        "* Connected to example.com (1.2.3.4) port 443\n" ++
        "-----BEGIN CERTIFICATE-----\n" ++
        "MIIFazCCA1OgAwIBAgIUJYJn0qRkWZA5YDEmEHKG5tJX+q4wDQYJKoZIhvcNAQEL\n" ++
        "BQAwRTELMAkGA1UEBhMCVVMxEzARBgNVBAgMCkNhbGlmb3JuaWExETAPBgNVBAoM\n" ++
        "CEV4YW1wbGUxDjAMBgNVBAMMBVJvb3QxMB4XDTI0MDEwMTAwMDAwMFoXDTM0MDEw\n" ++
        "-----END CERTIFICATE-----\n" ++
        "> GET / HTTP/1.1\n" ++
        "< HTTP/1.1 200 OK\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", stderr, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "BEGIN CERTIFICATE") == null);
    try std.testing.expect(std.mem.find(u8, got, "END CERTIFICATE") == null);
    try std.testing.expect(std.mem.find(u8, got, "MIIFaz") == null);
    try std.testing.expect(std.mem.find(u8, got, "> GET") != null);
    try std.testing.expect(std.mem.find(u8, got, "< HTTP/1.1 200") != null);
}

test "apply: redirect chain preserved" {
    const stderr =
        "> GET / HTTP/1.1\n" ++
        "< HTTP/1.1 301 Moved Permanently\n" ++
        "< Location: https://example.com/new\n" ++
        "> GET /new HTTP/1.1\n" ++
        "< HTTP/1.1 302 Found\n" ++
        "< Location: https://example.com/final\n" ++
        "> GET /final HTTP/1.1\n" ++
        "< HTTP/1.1 200 OK\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "body\n", stderr, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "301 Moved Permanently") != null);
    try std.testing.expect(std.mem.find(u8, got, "302 Found") != null);
    try std.testing.expect(std.mem.find(u8, got, "200 OK") != null);
    try std.testing.expect(std.mem.count(u8, got, "< HTTP/1.1") == 3);
}

test "apply: empty stderr with body emits body only" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "hello\n", "", &out.writer);
    try std.testing.expectEqualStrings("hello\n", out.written());
}

test "apply: body passes through verbatim (binary-safe)" {
    const stderr = "> GET /img.png HTTP/1.1\n< HTTP/1.1 200 OK\n< content-type: image/png\n";
    const stdout = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, stdout, stderr, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, stdout) != null);
}

test "apply: empty input → empty output" {
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, "", "", &out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "apply: large synthetic fixture reduces by ≥ 60%" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    // Realistic -vvv shape: per-request, lots of TLS/schannel/ALPN chatter
    // bracketing a handful of request/response header lines. We repeat this
    // 50 times to build a ~100 KB stderr.
    const block =
        "*   Trying 10.0.0.1:443...\n" ++
        "* Connected to api.example.com (10.0.0.1) port 443\n" ++
        "* ALPN: curl offers h2,http/1.1\n" ++
        "* TLSv1.3 (OUT), TLS handshake, Client hello (1):\n" ++
        "* TLSv1.3 (IN), TLS handshake, Server hello (2):\n" ++
        "* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):\n" ++
        "* TLSv1.3 (IN), TLS handshake, Certificate (11):\n" ++
        "* TLSv1.3 (IN), TLS handshake, CERT verify (15):\n" ++
        "* TLSv1.3 (IN), TLS handshake, Finished (20):\n" ++
        "* TLSv1.3 (OUT), TLS handshake, Finished (20):\n" ++
        "* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384\n" ++
        "* ALPN: server accepted h2\n" ++
        "* Server certificate:\n" ++
        "*   subject: CN=api.example.com\n" ++
        "*   start date: Jan  1 00:00:00 2024 GMT\n" ++
        "*   expire date: Apr  1 00:00:00 2024 GMT\n" ++
        "*   subjectAltName: host \"api.example.com\" matched cert's \"api.example.com\"\n" ++
        "*   issuer: C=US; O=Let's Encrypt; CN=R3\n" ++
        "*   SSL certificate verify ok.\n" ++
        "* Using HTTP2, server supports multiplexing\n" ++
        "> GET /v1/resource HTTP/2\n" ++
        "> Host: api.example.com\n" ++
        "> User-Agent: curl/8.0\n" ++
        "> accept: */*\n" ++
        "> \n" ++
        "* Connection state changed (MAX_CONCURRENT_STREAMS == 128)!\n" ++
        "< HTTP/2 200\n" ++
        "< content-type: application/json\n" ++
        "< content-length: 42\n" ++
        "< \n";
    for (0..50) |_| try buf.appendSlice(alloc, block);
    var out = Writer.Allocating.init(alloc);
    defer out.deinit();
    try apply(alloc, "", buf.items, &out.writer);
    const got = out.written();
    const reduction = (buf.items.len - got.len) * 100 / buf.items.len;
    try std.testing.expect(reduction >= 60);
    // Every iteration's status line survives.
    try std.testing.expectEqual(@as(usize, 50), std.mem.count(u8, got, "< HTTP/2 200"));
    // All TLS chatter dropped.
    try std.testing.expect(std.mem.find(u8, got, "TLSv1.3") == null);
    try std.testing.expect(std.mem.find(u8, got, "SSL connection") == null);
    try std.testing.expect(std.mem.find(u8, got, "subject:") == null);
}
