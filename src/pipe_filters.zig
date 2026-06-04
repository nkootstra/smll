const std = @import("std");

const curl_compact = @import("curl_compact");
const du_compact = @import("du_compact");
const find_compact = @import("find_compact");
const generic_compact = @import("generic_compact");
const git_log = @import("git_log");

/// Pipe-mode wrapper for find_compact — detects `find -ls` tabular output.
pub const FindCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return find_compact.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        return find_compact.apply(allocator, input, stderr, writer);
    }
};

/// Pipe-mode wrapper for du_compact — detects `du` size+path output.
/// Uses sort_desc=true in pipe mode to get top-N + prefix compression.
pub const DuCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return du_compact.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        return du_compact.apply(allocator, input, stderr, writer, true);
    }
};

/// Pipe-mode wrapper for curl_compact — detects curl -v/vvv stderr output.
pub const CurlCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return curl_compact.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        _ = stderr;
        // In pipe mode, the curl -v output arrives as stdin (our `input`).
        // curl_compact expects stdout (body) + stderr (verbose output).
        return curl_compact.apply(allocator, "", input, writer);
    }
};

/// Pipe-mode wrapper for generic_compact — adapts its 3-arg apply() to the
/// 4-arg signature expected by the pipe-mode filter dispatch.
pub const GenericCompactPipe = struct {
    pub fn matches(input: []const u8) bool {
        return generic_compact.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        _ = stderr;
        return generic_compact.apply(allocator, input, writer);
    }
};

/// Pipe-mode wrapper that uses git_log.applyCompact instead of apply.
/// This matches the v0.6 "lossy by default" posture for pipe mode.
pub const GitLogCompact = struct {
    pub fn matches(input: []const u8) bool {
        return git_log.matches(input);
    }
    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        return git_log.applyCompact(allocator, input, stderr, writer);
    }
};
