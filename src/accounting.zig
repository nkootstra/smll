const std = @import("std");

/// Byte categories recorded for one wrapped command. `displayed_bytes` is the
/// complete agent-visible stream, including wrapper diagnostics. Formatting
/// savings are stored independently so diagnostics and declared omissions can
/// never be mistaken for compression.
pub const Bytes = struct {
    raw_bytes: usize = 0,
    displayed_bytes: usize = 0,
    omitted_bytes: usize = 0,
    diagnostic_bytes: usize = 0,
    formatting_saved_bytes: usize = 0,
};

/// Derive conservative accounting from a completed wrapper run. When a filter
/// declares an omission, attribute its entire reduction to omission because
/// the compact text alone cannot distinguish omitted bytes from presentation
/// changes. Failed captures receive no formatting-savings credit.
pub fn derive(
    raw_bytes: usize,
    displayed_bytes: usize,
    diagnostic_bytes: usize,
    declared_omission: bool,
    capture_complete: bool,
) Bytes {
    const bounded_diagnostics = @min(diagnostic_bytes, displayed_bytes);
    const child_visible = displayed_bytes - bounded_diagnostics;
    const reduction = raw_bytes -| child_visible;
    const omitted = if (declared_omission) reduction else 0;
    return .{
        .raw_bytes = raw_bytes,
        .displayed_bytes = displayed_bytes,
        .omitted_bytes = omitted,
        .diagnostic_bytes = bounded_diagnostics,
        .formatting_saved_bytes = if (capture_complete) reduction -| omitted else 0,
    };
}

test "diagnostics do not reduce formatting savings" {
    const got = derive(1_000, 460, 60, false, true);
    try std.testing.expectEqual(@as(usize, 600), got.formatting_saved_bytes);
    try std.testing.expectEqual(@as(usize, 60), got.diagnostic_bytes);
}

test "declared omissions receive conservative reduction credit" {
    const got = derive(1_000, 460, 60, true, true);
    try std.testing.expectEqual(@as(usize, 600), got.omitted_bytes);
    try std.testing.expectEqual(@as(usize, 0), got.formatting_saved_bytes);
}

test "failed capture receives no savings credit" {
    const got = derive(1_000, 100, 20, false, false);
    try std.testing.expectEqual(@as(usize, 0), got.formatting_saved_bytes);
}
