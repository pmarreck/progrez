//! Pure logic core: EMA rate calculation, unit formatting,
//! percentage/ETA computation, bar rendering.
//! No I/O, no threading, no terminal access.

const std = @import("std");

/// Placeholder — will hold all progress state.
pub const ProgrezState = struct {
    dummy: u8 = 0,
};

test "core: state initializes" {
    const state = ProgrezState{};
    try std.testing.expectEqual(@as(u8, 0), state.dummy);
}
