//! Pure logic core: EMA rate calculation, unit formatting,
//! percentage/ETA computation, bar rendering.
//! No I/O, no threading, no terminal access.

const std = @import("std");

/// Progress display mode.
pub const Mode = enum {
    idle,
    indeterminate,
    determinate,
};

/// Immutable point-in-time snapshot of progress state.
pub const ProgrezSnapshot = struct {
    files_processed: u64,
    files_total: ?u64,
    bytes_processed: u64,
    bytes_total: ?u64,
    timestamp_ns: i128,
};

/// All mutable progress state. No I/O, no allocations.
pub const ProgrezState = struct {
    mode: Mode,

    // Counters
    files_processed: u64,
    files_total: ?u64,
    bytes_processed: u64,
    bytes_total: ?u64,

    // Timing
    start_time_ns: i128,
    last_update_ns: i128,

    // EMA rate estimation
    ema_bytes_per_sec: f64,
    ema_files_per_sec: f64,
    ema_alpha: f64,
    samples_count: u32,

    // Guesses (for indeterminate mode)
    guess_total_files: ?u64,
    guess_total_bytes: ?u64,

    // Spinner
    spinner_frame: u8,

    // Label (inline buffer, no allocations)
    label_buf: [128]u8,
    label_len: u8,

    // Identity (caller name + context)
    caller_name_buf: [64]u8,
    caller_name_len: u8,
    context_name_buf: [256]u8,
    context_name_len: u16,
    has_identity: bool,

    /// Create a new ProgrezState in idle mode with the given label.
    pub fn init(label: []const u8) ProgrezState {
        var state: ProgrezState = .{
            .mode = .idle,
            .files_processed = 0,
            .files_total = null,
            .bytes_processed = 0,
            .bytes_total = null,
            .start_time_ns = 0,
            .last_update_ns = 0,
            .ema_bytes_per_sec = 0.0,
            .ema_files_per_sec = 0.0,
            .ema_alpha = 0.3,
            .samples_count = 0,
            .guess_total_files = null,
            .guess_total_bytes = null,
            .spinner_frame = 0,
            .label_buf = undefined,
            .label_len = 0,
            .caller_name_buf = undefined,
            .caller_name_len = 0,
            .context_name_buf = undefined,
            .context_name_len = 0,
            .has_identity = false,
        };
        const len: u8 = @intCast(@min(label.len, state.label_buf.len));
        @memcpy(state.label_buf[0..len], label[0..len]);
        state.label_len = len;
        return state;
    }

    /// Return the label as a slice.
    pub fn getLabel(self: *const ProgrezState) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    /// Transition to indeterminate mode (spinner, no percentage).
    pub fn setIndeterminate(self: *ProgrezState) void {
        self.mode = .indeterminate;
    }

    /// Transition to determinate mode with known totals.
    /// A total of 0 means "not tracking that dimension" (stored as null).
    pub fn setDeterminate(self: *ProgrezState, files_total: u64, bytes_total: u64) void {
        self.mode = .determinate;
        self.files_total = if (files_total == 0) null else files_total;
        self.bytes_total = if (bytes_total == 0) null else bytes_total;
    }

    /// Set the caller identity (who is reporting progress and what for).
    pub fn setIdentity(self: *ProgrezState, caller_name: []const u8, context_name: []const u8) void {
        const cn_len: u8 = @intCast(@min(caller_name.len, self.caller_name_buf.len));
        @memcpy(self.caller_name_buf[0..cn_len], caller_name[0..cn_len]);
        self.caller_name_len = cn_len;

        const ctx_len: u16 = @intCast(@min(context_name.len, self.context_name_buf.len));
        @memcpy(self.context_name_buf[0..ctx_len], context_name[0..ctx_len]);
        self.context_name_len = ctx_len;

        self.has_identity = true;
    }

    /// Return the caller name, or null if no identity has been set.
    pub fn getCallerName(self: *const ProgrezState) ?[]const u8 {
        if (!self.has_identity) return null;
        return self.caller_name_buf[0..self.caller_name_len];
    }

    /// Return the context name, or null if no identity has been set.
    pub fn getContextName(self: *const ProgrezState) ?[]const u8 {
        if (!self.has_identity) return null;
        return self.context_name_buf[0..self.context_name_len];
    }

    /// Set estimated totals (guesses) for indeterminate mode.
    /// A value of 0 means "no guess" (stored as null).
    pub fn setGuess(self: *ProgrezState, guess_files: u64, guess_bytes: u64) void {
        self.guess_total_files = if (guess_files == 0) null else guess_files;
        self.guess_total_bytes = if (guess_bytes == 0) null else guess_bytes;
    }

    /// Capture a read-only snapshot of the current progress state.
    pub fn snapshot(self: *const ProgrezState, now_ns: i128) ProgrezSnapshot {
        return .{
            .files_processed = self.files_processed,
            .files_total = self.files_total,
            .bytes_processed = self.bytes_processed,
            .bytes_total = self.bytes_total,
            .timestamp_ns = now_ns,
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "core: state initializes in idle mode" {
    const state = ProgrezState.init("Compressing");
    try std.testing.expectEqual(Mode.idle, state.mode);
    try std.testing.expectEqualStrings("Compressing", state.getLabel());
    try std.testing.expectEqual(@as(?u64, null), state.files_total);
    try std.testing.expectEqual(@as(?u64, null), state.bytes_total);
    try std.testing.expectEqual(@as(u64, 0), state.files_processed);
    try std.testing.expectEqual(@as(u64, 0), state.bytes_processed);
}

test "core: state transitions to indeterminate" {
    var state = ProgrezState.init("Scanning");
    state.setIndeterminate();
    try std.testing.expectEqual(Mode.indeterminate, state.mode);
}

test "core: state transitions to determinate" {
    var state = ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    try std.testing.expectEqual(Mode.determinate, state.mode);
    try std.testing.expectEqual(@as(?u64, 400), state.files_total);
    try std.testing.expectEqual(@as(?u64, 21_000_000), state.bytes_total);
}

test "core: state transitions indeterminate -> determinate" {
    var state = ProgrezState.init("Processing");
    state.setIndeterminate();
    try std.testing.expectEqual(Mode.indeterminate, state.mode);
    state.setDeterminate(100, 5_000_000);
    try std.testing.expectEqual(Mode.determinate, state.mode);
    try std.testing.expectEqual(@as(?u64, 100), state.files_total);
}

test "core: zero total means not tracking" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(0, 1000); // 0 files = not tracking files
    try std.testing.expectEqual(@as(?u64, null), state.files_total);
    try std.testing.expectEqual(@as(?u64, 1000), state.bytes_total);
}

test "core: set identity" {
    var state = ProgrezState.init("Compressing");
    state.setIdentity("bzip2z", "compression of mydir/");
    try std.testing.expectEqualStrings("bzip2z", state.getCallerName().?);
    try std.testing.expectEqualStrings("compression of mydir/", state.getContextName().?);
}

test "core: identity is null by default" {
    const state = ProgrezState.init("Compressing");
    try std.testing.expectEqual(@as(?[]const u8, null), state.getCallerName());
    try std.testing.expectEqual(@as(?[]const u8, null), state.getContextName());
}

test "core: snapshot captures current counters" {
    var state = ProgrezState.init("Test");
    state.setDeterminate(100, 5000);
    state.files_processed = 42;
    state.bytes_processed = 2100;
    const snap = state.snapshot(1_000_000_000);
    try std.testing.expectEqual(@as(u64, 42), snap.files_processed);
    try std.testing.expectEqual(@as(u64, 2100), snap.bytes_processed);
    try std.testing.expectEqual(@as(?u64, 100), snap.files_total);
    try std.testing.expectEqual(@as(?u64, 5000), snap.bytes_total);
    try std.testing.expectEqual(@as(i128, 1_000_000_000), snap.timestamp_ns);
}

test "core: set guess" {
    var state = ProgrezState.init("Scanning");
    state.setIndeterminate();
    state.setGuess(2000, 0);
    try std.testing.expectEqual(@as(?u64, 2000), state.guess_total_files);
    try std.testing.expectEqual(@as(?u64, null), state.guess_total_bytes);
}
