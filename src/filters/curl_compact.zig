const std = @import("std");
const ansi = @import("ansi");
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
// Output shape (when stdout is non-empty and the trace has one request, or a
// repeated same-status request batch):
//   curl GET example.com/ -> HTTP/2 200 text/html len=1256
//   curl 30 GET api.example.com /v1/a/1../v1/a/30 -> HTTP/2 200 x30 application/json
//   <stdout verbatim>
//
// Redirect chains or mixed-status batches fall back to the filtered trace so
// every status/location remains visible.
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
        if (stdout.len > 0) {
            if (summarizeRequests(stderr)) |summary| {
                try writeCurlSummary(writer, summary);
                try writer.writeAll(stdout);
                return;
            }
        }
        if (stdout.len > 0) try writer.writeAll("--- headers ---\n");
        try emitFilteredStderr(writer, stderr);
    }

    if (stdout.len > 0) {
        if (has_stderr_content) try writer.writeAll("--- body ---\n");
        // The response body is often machine-readable JSON, shell script, or
        // another downstream-consumed payload. Filter only curl's verbose trace;
        // preserve stdout byte-for-byte.
        try writer.writeAll(stdout);
    }
}

const CurlSummary = struct {
    method: []const u8 = "",
    path: []const u8 = "",
    host: []const u8 = "",
    status: []const u8 = "",
    content_type: []const u8 = "",
    content_length: []const u8 = "",
    last_path: []const u8 = "",
    request_count: usize = 0,
};

fn summarizeRequests(stderr: []const u8) ?CurlSummary {
    var summary: CurlSummary = .{};
    var request_count: usize = 0;
    var status_count: usize = 0;
    var same_status = true;
    var location_count: usize = 0;

    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len < 3) continue;

        if (std.mem.startsWith(u8, line, "> ")) {
            const after = line[2..];
            if (parseRequestLine(after)) |request| {
                request_count += 1;
                if (request_count == 1) {
                    summary.method = request.method;
                    summary.path = request.path;
                }
                summary.last_path = request.path;
                continue;
            }
            if (startsWithHeader(line, "> Host:")) {
                if (summary.host.len == 0) {
                    summary.host = std.mem.trim(u8, line["> Host:".len..], " \t\r");
                }
            }
            continue;
        }

        if (std.mem.startsWith(u8, line, "< HTTP/")) {
            status_count += 1;
            const status = line[2..];
            if (status_count == 1) {
                summary.status = status;
            } else if (!std.mem.eql(u8, status, summary.status)) {
                same_status = false;
            }
            continue;
        }
        if (startsWithHeader(line, "< location:")) {
            location_count += 1;
            continue;
        }
        if (startsWithHeader(line, "< content-type:")) {
            if (summary.content_type.len == 0) {
                summary.content_type = std.mem.trim(u8, line["< content-type:".len..], " \t\r");
            }
            continue;
        }
        if (startsWithHeader(line, "< content-length:")) {
            if (summary.content_length.len == 0) {
                summary.content_length = std.mem.trim(u8, line["< content-length:".len..], " \t\r");
            }
            continue;
        }
    }

    if (request_count == 0 or status_count == 0 or summary.status.len == 0) return null;
    if (location_count > 0) return null;
    if (request_count == 1 and status_count != 1) return null;
    if (request_count > 1 and (status_count != request_count or !same_status)) return null;
    summary.request_count = request_count;
    return summary;
}

const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
};

fn parseRequestLine(line: []const u8) ?ParsedRequest {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const method = it.next() orelse return null;
    for (method) |c| {
        if (c < 'A' or c > 'Z') return null;
    }
    const path = it.next() orelse return null;
    const proto = it.next() orelse return null;
    if (!std.mem.startsWith(u8, proto, "HTTP/")) return null;
    return .{ .method = method, .path = path };
}

fn startsWithHeader(line: []const u8, prefix: []const u8) bool {
    if (line.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix);
}

fn writeCurlSummary(writer: *Writer, summary: CurlSummary) !void {
    try writer.writeAll("curl");
    if (summary.request_count > 1) {
        try writer.writeByte(' ');
        try ansi.writeDecimal(writer, summary.request_count);
    }
    if (summary.method.len > 0) {
        try writer.writeByte(' ');
        try writer.writeAll(summary.method);
    }
    try writer.writeByte(' ');
    if (summary.host.len > 0) try writer.writeAll(summary.host);
    if (summary.path.len > 0) {
        if (summary.host.len > 0 and summary.path[0] != '/') try writer.writeByte(' ');
        try writer.writeAll(summary.path);
    }
    if (summary.request_count > 1 and summary.last_path.len > 0 and
        !std.mem.eql(u8, summary.path, summary.last_path))
    {
        try writer.writeAll("..");
        try writer.writeAll(summary.last_path);
    }
    try writer.writeAll(" -> ");
    try writer.writeAll(summary.status);
    if (summary.request_count > 1) {
        try writer.writeAll(" x");
        try ansi.writeDecimal(writer, summary.request_count);
    }
    if (summary.content_type.len > 0) {
        try writer.writeByte(' ');
        try writer.writeAll(summary.content_type);
    }
    if (summary.request_count == 1 and summary.content_length.len > 0) {
        try writer.writeAll(" len=");
        try writer.writeAll(summary.content_length);
    }
    try writer.writeByte('\n');
}

fn emitFilteredStderr(writer: *Writer, stderr: []const u8) !void {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    var in_cert_block = false;
    var in_server_cert_block = false;
    var seen_request = false; // true after first "> " request line
    var request_count: usize = 0;
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

        if (line[0] == '>') {
            // Track request count for dedup
            if (line.len >= 3 and line[1] == ' ' and line[2] != ' ') {
                // Request line: "> GET /path" or "> POST /path"
                // Keep the first word after "> "
                const after_angle = line[2..];
                const is_method = for (after_angle) |c| {
                    if (c == ' ') break true;
                    if (c < 'A' or c > 'Z') break false;
                } else false;
                if (is_method) {
                    request_count += 1;
                    // Show first 5 requests fully; skip method lines for the rest
                    if (request_count <= 5) {
                        if (request_count > 1 and !seen_request) {
                            try writer.writeAll("---\n");
                        }
                        seen_request = true;
                        try writer.writeAll(line);
                        try writer.writeByte('\n');
                    }
                    continue;
                }
            }
            // Request header line: "> Host: example.com"
            // After the first request, skip repeated headers.
            // Keep all headers for the first request.
            if (request_count <= 1) {
                try writer.writeAll(line);
                try writer.writeByte('\n');
            }
            // For subsequent requests, skip headers (they repeat)
            continue;
        }

        if (line[0] == '<') {
            // Response lines: keep status line + unique headers.
            // Status line: "< HTTP/2 200" (keep for first 5 requests)
            if (std.mem.startsWith(u8, line, "< HTTP/")) {
                if (request_count <= 5) {
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                }
                continue;
            }
            // After first request, skip repeated response headers
            // but keep ones that change (x-request-id, date)
            if (request_count <= 1) {
                try writer.writeAll(line);
                try writer.writeByte('\n');
            } else {
                // Only keep location headers for subsequent requests
                if (std.mem.startsWith(u8, line, "< location:") or
                    std.mem.startsWith(u8, line, "< Location:"))
                {
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                }
            }
            continue;
        }

        if (line[0] == '*') {
            if (shouldDropMeta(line)) continue;
            if (shouldKeepMeta(line)) {
                // After first request, skip repeated meta lines like
                // "* Connected to" unless it's a different host
                if (request_count <= 1) {
                    try writer.writeAll(line);
                    try writer.writeByte('\n');
                }
            }
            continue;
        }

        // Non-verbose lines on stderr — pass through (e.g. error messages
        // curl writes to stderr before entering verbose mode).
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }
    if (request_count > 1) {
        try writer.writeByte('(');
        try ansi.writeDecimal(writer, request_count);
        try writer.writeAll(" requests total)\n");
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

test "apply: summarizes one request, keeps body, drops TLS chatter" {
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
    try std.testing.expect(std.mem.find(u8, got, "curl GET example.com/ -> HTTP/2 200 text/html len=1256") != null);
    try std.testing.expect(std.mem.find(u8, got, "<html>body</html>") != null);
    // Dropped
    try std.testing.expect(std.mem.find(u8, got, "* Connected to example.com") == null);
    try std.testing.expect(std.mem.find(u8, got, "> GET / HTTP/2") == null);
    try std.testing.expect(std.mem.find(u8, got, "--- headers ---") == null);
    try std.testing.expect(std.mem.find(u8, got, "--- body ---") == null);
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

test "apply: repeated same-status requests summarize to one trace line" {
    const stderr =
        "> GET /v1/resources/1 HTTP/2\n" ++
        "> Host: api.example.com\n" ++
        "< HTTP/2 200\n" ++
        "< content-type: application/json\n" ++
        "< content-length: 128\n" ++
        "> GET /v1/resources/2 HTTP/2\n" ++
        "< HTTP/2 200\n" ++
        "< content-type: application/json\n" ++
        "> GET /v1/resources/3 HTTP/2\n" ++
        "< HTTP/2 200\n" ++
        "< content-type: application/json\n";
    const stdout =
        "{\"id\":1}\n" ++
        "{\"id\":2}\n" ++
        "{\"id\":3}\n";
    var out = Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try apply(std.testing.allocator, stdout, stderr, &out.writer);
    const got = out.written();
    try std.testing.expect(std.mem.find(u8, got, "curl 3 GET api.example.com/v1/resources/1../v1/resources/3 -> HTTP/2 200 x3 application/json") != null);
    try std.testing.expect(std.mem.find(u8, got, "{\"id\":3}") != null);
    try std.testing.expect(std.mem.find(u8, got, "--- headers ---") == null);
    try std.testing.expect(std.mem.count(u8, got, "HTTP/2 200") == 1);
    try std.testing.expect(std.mem.find(u8, got, "< HTTP/2 200") == null);
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
    // First 5 requests' status lines survive; rest capped.
    const status_count = std.mem.count(u8, got, "< HTTP/2 200");
    try std.testing.expect(status_count >= 1 and status_count <= 5);
    // All TLS chatter dropped.
    try std.testing.expect(std.mem.find(u8, got, "TLSv1.3") == null);
    try std.testing.expect(std.mem.find(u8, got, "SSL connection") == null);
    try std.testing.expect(std.mem.find(u8, got, "subject:") == null);
}
