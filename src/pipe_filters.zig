const std = @import("std");

const curl_compact = @import("curl_compact");
const du_compact = @import("du_compact");
const find_compact = @import("find_compact");
const generic_compact = @import("generic_compact");
const git_log = @import("git_log");
const git_status = @import("git_status");
const git_branch = @import("git_branch");
const git_reflog = @import("git_reflog");
const git_show = @import("git_show");
const git_diff = @import("git_diff");
const git_commit = @import("git_commit");
const git_merge = @import("git_merge");
const git_blame = @import("git_blame");
const cargo_test = @import("cargo_test");
const jest = @import("jest");
const js_test = @import("js_test");
const tsc = @import("tsc");
const go_test = @import("go_test");
const pytest = @import("pytest");
const kubectl_compact = @import("kubectl_compact");
const docker_compact = @import("docker_compact");
const npm_install = @import("npm_install");
const tree = @import("tree");
const ls_compact = @import("ls_compact");

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

/// Patch-bearing git output may start with commit metadata (`git log -p` or
/// `git show`) instead of a diff header. Detect the patch boundary anywhere
/// after the dedicated show shape but before log compaction can discard hunks.
pub const GitDiffPipe = struct {
    pub fn matches(input: []const u8) bool {
        return std.mem.startsWith(u8, input, "diff --git a/") or
            std.mem.find(u8, input, "\ndiff --git a/") != null;
    }

    pub fn apply(allocator: std.mem.Allocator, input: []const u8, stderr: []const u8, writer: *std.Io.Writer) !void {
        return git_diff.apply(allocator, input, stderr, writer);
    }
};

// The pipe-mode filter chain: first match wins, falling through to
// GenericCompactPipe (the size-gated catch-all). Shared by stdin pipe mode
// (src/main.zig) and the `sh -c` re-dispatch arm (src/wrapper.zig), which routes
// a captured shell command's stdout through the same content-detection chain.
//
// git_branch is included because branch-list output is stable and identifiable
// by its leading "  " / "* " prefix; it sits after git_status and before
// git_show (the branch shape is distinct from both). git_checkout is NOT here
// because its matches() always returns false (argv-only in wrapper mode).
pub const Filters = .{
    git_status,      git_branch,    git_reflog,      git_show,
    GitDiffPipe,     GitLogCompact, git_commit,      git_merge,
    git_blame,       cargo_test,    jest,            js_test,
    tsc,             go_test,       pytest,          kubectl_compact,
    docker_compact,  npm_install,   tree,            ls_compact,
    FindCompactPipe, DuCompactPipe, CurlCompactPipe, GenericCompactPipe,
};
