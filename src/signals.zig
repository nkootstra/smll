//! Single-pass pipe-mode pre-classifier.
//!
//! The pipe dispatcher (`pipeline.dispatch`) runs each filter's `matches()` in
//! order until one claims the input. For the runner/test/package filters that
//! probe several substrings, `matches()` over a large unrelated stream (a
//! 500 KiB `journalctl` dump, say) does many full `std.mem.find` scans before
//! falling through to the generic compactor. This module collapses all of those
//! probes into ONE pass: it scans the whole input once, recording which of a
//! fixed set of needles are present, and exposes a cheap `Signals` bitset that
//! each expensive filter can gate on before its `matches()` is even called.
//!
//! Safety invariant (superset by construction): every needle here is a
//! NECESSARY substring of at least one match-path of its filter — i.e. if that
//! path returns true, the needle is guaranteed present. A filter's gate is the
//! OR of its needles' presence bits, so `matches(input) ⟹ gate(input)`. The
//! dispatcher only SKIPS a filter when its gate is false, and a false gate means
//! every match-path's necessary needle is absent, so `matches()` could not have
//! returned true. Selection is therefore identical to the ungated dispatcher.
//!
//! Crucially the scan covers the ENTIRE input, not a fixed prefix: a test
//! summary that appears only after megabytes of preamble is still detected. A
//! windowed classifier would silently misroute such output, violating smll's
//! fact-preserving contract. The superset invariant is pinned against real
//! captured fixtures by the property tests in src/main.zig.

const std = @import("std");

/// Bit position of each needle. Named so the gate accessors are self-documenting
/// and a reorder of `needles` without updating its gate fails to compile.
const Bit = enum(u5) {
    // cargo_test
    cargo_test,
    // jest
    jest_test,
    // tsc
    tsc_error_ts,
    tsc_found,
    // go_test
    go_run_fuzz, // "=== " (=== RUN / === FUZZ)
    go_result, // "--- " (--- FAIL: / --- PASS:)
    go_benchmark,
    go_ok, // "ok  \t" package summary
    go_fail, // "FAIL\t" package summary
    // pytest
    pytest_session,
    pytest_collected,
    pytest_passed_in,
    pytest_failed_in,
    // npm_install (npm / pnpm / bun / yarn / composer)
    npm_added,
    npm_up_to_date,
    npm_audited,
    npm_prefix, // "npm " (error/ERR!/WARN)
    npm_packages_colon, // "Packages: " (pnpm +/-)
    npm_pkgs_installed, // " packages installed [" (bun)
    npm_success_saved, // yarn
    npm_done_in, // yarn
    npm_pkg_ops, // composer
    npm_lock_ops, // composer
    npm_nothing, // composer
    npm_no_vuln, // composer
    npm_unresolved, // composer
};

/// Needle table, indexed by `Bit`. Each entry is a necessary substring of a
/// match-path; see the per-bit comments on `Bit` and the filter `matches()`.
const needles = blk: {
    var table: [std.meta.fields(Bit).len][]const u8 = undefined;
    table[@intFromEnum(Bit.cargo_test)] = "test";
    table[@intFromEnum(Bit.jest_test)] = "Test";
    table[@intFromEnum(Bit.tsc_error_ts)] = "error TS";
    table[@intFromEnum(Bit.tsc_found)] = "Found ";
    table[@intFromEnum(Bit.go_run_fuzz)] = "=== ";
    table[@intFromEnum(Bit.go_result)] = "--- ";
    table[@intFromEnum(Bit.go_benchmark)] = "Benchmark";
    table[@intFromEnum(Bit.go_ok)] = "ok  \t"; // ok + two spaces + tab
    table[@intFromEnum(Bit.go_fail)] = "FAIL\t";
    table[@intFromEnum(Bit.pytest_session)] = "test session starts";
    table[@intFromEnum(Bit.pytest_collected)] = "collected ";
    table[@intFromEnum(Bit.pytest_passed_in)] = "passed in ";
    table[@intFromEnum(Bit.pytest_failed_in)] = "failed in ";
    table[@intFromEnum(Bit.npm_added)] = "added ";
    table[@intFromEnum(Bit.npm_up_to_date)] = "up to date";
    table[@intFromEnum(Bit.npm_audited)] = "audited ";
    table[@intFromEnum(Bit.npm_prefix)] = "npm ";
    table[@intFromEnum(Bit.npm_packages_colon)] = "Packages: ";
    table[@intFromEnum(Bit.npm_pkgs_installed)] = "packages installed";
    table[@intFromEnum(Bit.npm_success_saved)] = "success Saved ";
    table[@intFromEnum(Bit.npm_done_in)] = "Done in ";
    table[@intFromEnum(Bit.npm_pkg_ops)] = "Package operations:";
    table[@intFromEnum(Bit.npm_lock_ops)] = "Lock file operations:";
    table[@intFromEnum(Bit.npm_nothing)] = "Nothing to install";
    table[@intFromEnum(Bit.npm_no_vuln)] = "No security vulnerability";
    table[@intFromEnum(Bit.npm_unresolved)] = "Your requirements could not be resolved";
    break :blk table;
};

inline fn mask(comptime bits: []const Bit) u32 {
    comptime var m: u32 = 0;
    inline for (bits) |b| m |= @as(u32, 1) << @intFromEnum(b);
    return m;
}

pub const Signals = struct {
    bits: u32,

    inline fn any(self: Signals, m: u32) bool {
        return (self.bits & m) != 0;
    }

    pub fn cargoTest(self: Signals) bool {
        return self.any(mask(&.{.cargo_test}));
    }
    pub fn jest(self: Signals) bool {
        return self.any(mask(&.{.jest_test}));
    }
    pub fn tsc(self: Signals) bool {
        return self.any(mask(&.{ .tsc_error_ts, .tsc_found }));
    }
    pub fn goTest(self: Signals) bool {
        return self.any(mask(&.{ .go_run_fuzz, .go_result, .go_benchmark, .go_ok, .go_fail }));
    }
    pub fn pytest(self: Signals) bool {
        return self.any(mask(&.{ .pytest_session, .pytest_collected, .pytest_passed_in, .pytest_failed_in }));
    }
    pub fn npmInstall(self: Signals) bool {
        return self.any(mask(&.{
            .npm_added,          .npm_up_to_date,     .npm_audited,       .npm_prefix,
            .npm_packages_colon, .npm_pkgs_installed, .npm_success_saved, .npm_done_in,
            .npm_pkg_ops,        .npm_lock_ops,       .npm_nothing,       .npm_no_vuln,
            .npm_unresolved,
        }));
    }
};

/// first_byte_mask[b] = OR of (1<<i) for every needle i whose first byte is b.
/// Lets the scan skip positions that cannot begin any needle with a single table
/// lookup. ~1 KiB of rodata, built entirely at comptime.
const first_byte_mask = blk: {
    var table = [_]u32{0} ** 256;
    for (needles, 0..) |n, i| {
        table[n[0]] |= @as(u32, 1) << @as(u5, @intCast(i));
    }
    break :blk table;
};

/// Scan `input` once and return which needles are present. Only ever called for
/// inputs that reach the first gated filter in the dispatch order; cheap inputs
/// claimed by an earlier filter never pay for it.
pub fn compute(input: []const u8) Signals {
    var found: u32 = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        // Candidate needles starting at this byte that we have not found yet.
        var cand = first_byte_mask[input[i]] & ~found;
        while (cand != 0) {
            const n: u5 = @intCast(@ctz(cand));
            cand &= cand - 1; // clear lowest set bit
            if (std.mem.startsWith(u8, input[i..], needles[n])) {
                found |= @as(u32, 1) << n;
            }
        }
    }
    return .{ .bits = found };
}

// -- tests --------------------------------------------------------------------

test "compute detects each needle when present in isolation" {
    for (needles, 0..) |n, i| {
        const sig = compute(n);
        try std.testing.expect((sig.bits & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0);
    }
}

test "compute finds a needle regardless of offset (whole-input scan)" {
    var buf: [9000]u8 = undefined;
    @memset(&buf, 'x');
    const tail = "\nok  \tpkg\t0.5s\n";
    @memcpy(buf[buf.len - tail.len ..], tail);
    const sig = compute(&buf);
    try std.testing.expect(sig.goTest()); // needle sits ~9 KiB in, still detected
}

test "compute reports nothing on unrelated text" {
    const sig = compute("the quick brown fox jumped over the lazy dog\n");
    try std.testing.expect(!sig.cargoTest());
    try std.testing.expect(!sig.jest());
    try std.testing.expect(!sig.tsc());
    try std.testing.expect(!sig.goTest());
    try std.testing.expect(!sig.pytest());
    try std.testing.expect(!sig.npmInstall());
}
