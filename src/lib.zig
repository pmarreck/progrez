//! progrez — unified progress indication library.
//!
//! Architecture: pure Zig core (no I/O), exposed via C FFI.
//! See docs/plans/2026-02-27-progrez-design.md for full design.

pub const core = @import("core.zig");
pub const format = @import("format.zig");
pub const terminal = @import("terminal.zig");

test {
    _ = core;
    _ = format;
    _ = terminal;
}
