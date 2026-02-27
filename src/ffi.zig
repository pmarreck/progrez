//! C FFI boundary layer for progrez.
//! Bridges pure Zig core logic to C consumers via exported functions.
//! Manages the render thread, seqlock-based snapshot passing, and I/O.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const terminal = @import("terminal.zig");
const render = @import("render.zig");

fn ffiAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

/// Opaque context handle exposed to C as `progrez_ctx*`.
/// Contains all state needed for progress tracking and rendering.
const FfiContext = struct {
    state: core.ProgrezState,
    caps: terminal.TerminalCaps,
    interval_ms: u32,
    render_thread: ?std.Thread,
    stop_flag: std.atomic.Value(bool),
    // Seqlock for snapshot passing (writer: caller thread, reader: render thread)
    snapshot: core.ProgrezSnapshot,
    generation: std.atomic.Value(u32),
    // Config
    progress_enabled: bool,
    is_tty: bool,
    // Log mode tracking (non-TTY output)
    last_log_percent: i8, // -1 = no log yet
    last_log_time_ns: i128,
};

// ── Env Var Parsing Helpers ─────────────────────────────────────────────

/// Parse PROGRESS env var: "true"/"1" -> true, "false"/"0" -> false, else null.
fn parseProgressEnv(val: ?[]const u8) ?bool {
    const v = val orelse return null;
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
    return null;
}

/// Parse PROGREZ_INTERVAL env var as u32 milliseconds. Default 1000.
fn parseIntervalEnv(val: ?[]const u8) u32 {
    const v = val orelse return 1000;
    return std.fmt.parseInt(u32, v, 10) catch 1000;
}

/// Read an environment variable. Returns null if not set.
fn getEnvVar(name: [:0]const u8) ?[:0]const u8 {
    return std.posix.getenv(name);
}

// ── Terminal Width Detection ────────────────────────────────────────────

fn getTerminalWidth() u16 {
    if (comptime builtin.os.tag == .windows) {
        // Windows: TODO use kernel32 GetConsoleScreenBufferInfo
        return 80;
    } else {
        // POSIX: ioctl TIOCGWINSZ on stderr (fd 2)
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(2, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0 and ws.col > 0) return ws.col;
        return 80;
    }
}

// ── Render Thread ───────────────────────────────────────────────────────

/// Seqlock read: returns snapshot if consistent, null if write was in progress.
fn readSnapshot(ctx: *FfiContext) ?core.ProgrezSnapshot {
    const gen1 = ctx.generation.load(.acquire);
    if (gen1 & 1 != 0) return null; // Write in progress (odd generation)
    const snap = ctx.snapshot;
    const gen2 = ctx.generation.load(.acquire);
    if (gen1 != gen2) return null; // Changed during read
    return snap;
}

/// Determine whether a log line should be emitted in non-TTY mode.
/// Criteria: every 10 seconds OR every 10% progress milestone.
fn shouldEmitLogLine(ctx: *FfiContext, now_ns: i128) bool {
    // Every 10 seconds
    const elapsed_since_last = now_ns - ctx.last_log_time_ns;
    if (elapsed_since_last >= 10 * std.time.ns_per_s) {
        ctx.last_log_time_ns = now_ns;
        return true;
    }
    // Every 10% progress
    if (ctx.state.percentComplete()) |pct| {
        const pct_int: i8 = @intFromFloat(pct * 10.0); // 0-10 (in 10% increments)
        if (pct_int > ctx.last_log_percent) {
            ctx.last_log_percent = pct_int;
            return true;
        }
    }
    return false;
}

/// Main render loop running on the dedicated render thread.
/// Reads snapshots via seqlock, renders to stderr.
fn renderLoop(ctx: *FfiContext) void {
    var render_buf: [8192]u8 = undefined;

    while (!ctx.stop_flag.load(.acquire)) {
        // Sleep for the configured interval
        std.Thread.sleep(@as(u64, ctx.interval_ms) * std.time.ns_per_ms);

        if (ctx.stop_flag.load(.acquire)) break;

        // Seqlock read
        const snap = readSnapshot(ctx) orelse continue;

        // Apply snapshot to state
        ctx.state.files_processed = snap.files_processed;
        ctx.state.bytes_processed = snap.bytes_processed;
        if (snap.files_total) |ft| ctx.state.files_total = ft;
        if (snap.bytes_total) |bt| ctx.state.bytes_total = bt;
        ctx.state.recordUpdate(snap.bytes_processed, snap.files_processed, snap.timestamp_ns);

        const now_ns = snap.timestamp_ns;

        if (ctx.is_tty) {
            // Get current terminal width (may change if user resizes)
            ctx.caps.width = getTerminalWidth();

            // Advance spinner frame
            ctx.state.spinner_frame +%= 1;

            // Render the progress line
            const line = render.renderLine(&ctx.state, ctx.caps, now_ns, &render_buf);
            if (line.len > 0) {
                const stderr_file: std.fs.File = .{ .handle = 2 };
                // Overwrite previous line with \r
                stderr_file.writeAll("\r") catch {};
                stderr_file.writeAll(line) catch {};
                // Pad with spaces to clear leftover chars from a previously wider line
                const width: usize = @intCast(ctx.caps.width);
                if (line.len < width) {
                    var pad_buf: [256]u8 = undefined;
                    const pad_len = @min(width - line.len, pad_buf.len);
                    @memset(pad_buf[0..pad_len], ' ');
                    stderr_file.writeAll(pad_buf[0..pad_len]) catch {};
                }
            }
        } else {
            // Log mode: emit line every 10s or 10% progress
            if (shouldEmitLogLine(ctx, now_ns)) {
                const line = render.renderLogLine(&ctx.state, now_ns, &render_buf);
                if (line.len > 0) {
                    const stderr_file: std.fs.File = .{ .handle = 2 };
                    stderr_file.writeAll(line) catch {};
                }
            }
        }
    }
}

// ── Exported FFI Functions ──────────────────────────────────────────────

/// Create a new progress context. Returns null on allocation failure.
/// The label defaults to "Progress" if null is passed.
/// Reads env vars: PROGRESS, PROGREZ_INTERVAL, PROGREZ_STYLE, NO_COLOR,
/// COLORTERM, TERM, WT_SESSION.
export fn progrez_create(label: ?[*:0]const u8) ?*FfiContext {
    const alloc = ffiAllocator();
    const ctx = alloc.create(FfiContext) catch return null;

    // Parse label from C string
    const label_slice: []const u8 = if (label) |l| std.mem.span(l) else "Progress";

    // Read env vars
    const progress_env = getEnvVar("PROGRESS");
    const interval_env = getEnvVar("PROGREZ_INTERVAL");
    const style_env = getEnvVar("PROGREZ_STYLE");
    const no_color_env = getEnvVar("NO_COLOR");
    const colorterm_env = getEnvVar("COLORTERM");
    const term_env = getEnvVar("TERM");
    const wt_session_env = getEnvVar("WT_SESSION");

    const interval_ms = parseIntervalEnv(if (interval_env) |e| @as([]const u8, e) else null);

    // Detect TTY on stderr (fd 2)
    const is_tty = std.posix.isatty(2);

    // Determine terminal width
    const width: u16 = if (is_tty) getTerminalWidth() else 80;

    // Detect terminal capabilities
    const caps = terminal.TerminalCaps.detect(.{
        .progrez_style = if (style_env) |e| @as([]const u8, e) else null,
        .no_color = if (no_color_env) |e| @as([]const u8, e) else null,
        .colorterm = if (colorterm_env) |e| @as([]const u8, e) else null,
        .term = if (term_env) |e| @as([]const u8, e) else null,
        .wt_session = if (wt_session_env) |e| @as([]const u8, e) else null,
        .is_tty = is_tty,
        .width = width,
    });

    // Determine if progress is enabled:
    // PROGRESS env var overrides TTY check
    const progress_enabled = parseProgressEnv(if (progress_env) |e| @as([]const u8, e) else null) orelse is_tty;

    const now_ns = std.time.nanoTimestamp();

    // Initialize state
    var state = core.ProgrezState.init(label_slice);
    state.start_time_ns = now_ns;
    state.last_update_ns = now_ns;

    ctx.* = .{
        .state = state,
        .caps = caps,
        .interval_ms = interval_ms,
        .render_thread = null,
        .stop_flag = std.atomic.Value(bool).init(false),
        .snapshot = .{
            .files_processed = 0,
            .files_total = null,
            .bytes_processed = 0,
            .bytes_total = null,
            .timestamp_ns = now_ns,
        },
        .generation = std.atomic.Value(u32).init(0),
        .progress_enabled = progress_enabled,
        .is_tty = is_tty,
        .last_log_percent = -1,
        .last_log_time_ns = now_ns,
    };

    // Spawn render thread if progress is enabled
    if (progress_enabled) {
        ctx.render_thread = std.Thread.spawn(.{}, renderLoop, .{ctx}) catch null;
    }

    return ctx;
}

/// Destroy a progress context and free its memory.
/// If the render thread is still active, finishes it first.
export fn progrez_destroy(ctx: ?*FfiContext) void {
    const c = ctx orelse return;
    // If render thread is still active, finish first
    if (c.render_thread != null) {
        progrez_finish(ctx);
    }
    ffiAllocator().destroy(c);
}

/// Update progress counters. Uses seqlock for thread-safe snapshot passing.
/// files_processed and bytes_processed are absolute (cumulative) values.
export fn progrez_update(ctx: ?*FfiContext, files_processed: u64, bytes_processed: u64) void {
    const c = ctx orelse return;
    const now_ns = std.time.nanoTimestamp();

    // Seqlock write: odd generation = write in progress
    const gen = c.generation.load(.monotonic);
    c.generation.store(gen +% 1, .release); // odd = writing

    c.snapshot = .{
        .files_processed = files_processed,
        .files_total = c.state.files_total,
        .bytes_processed = bytes_processed,
        .bytes_total = c.state.bytes_total,
        .timestamp_ns = now_ns,
    };

    c.generation.store(gen +% 2, .release); // even = done
}

/// Signal completion: stop the render thread and write a summary to stderr.
export fn progrez_finish(ctx: ?*FfiContext) void {
    const c = ctx orelse return;

    // Signal the render thread to stop
    c.stop_flag.store(true, .release);

    // Join the render thread
    if (c.render_thread) |thread| {
        thread.join();
        c.render_thread = null;
    }

    // Apply final snapshot to state for the summary
    if (readSnapshot(c)) |snap| {
        c.state.files_processed = snap.files_processed;
        c.state.bytes_processed = snap.bytes_processed;
    }

    // Write completion summary to stderr
    if (c.progress_enabled) {
        const now_ns = std.time.nanoTimestamp();
        var summary_buf: [1024]u8 = undefined;
        const summary = render.renderCompletionSummary(&c.state, now_ns, &summary_buf);
        if (summary.len > 0) {
            const stderr_file: std.fs.File = .{ .handle = 2 };
            if (c.is_tty) {
                // Clear the progress line first
                stderr_file.writeAll("\r\x1b[2K") catch {};
            }
            stderr_file.writeAll(summary) catch {};
        }
    }
}

/// Switch to indeterminate mode (spinner, no percentage).
export fn progrez_set_indeterminate(ctx: ?*FfiContext) void {
    const c = ctx orelse return;
    c.state.setIndeterminate();
}

/// Switch to determinate mode with known totals.
/// A total of 0 means "not tracking that dimension".
export fn progrez_set_determinate(ctx: ?*FfiContext, files_total: u64, bytes_total: u64) void {
    const c = ctx orelse return;
    c.state.setDeterminate(files_total, bytes_total);
}

/// Set estimated totals (guesses) for indeterminate mode.
/// A value of 0 means "no guess".
export fn progrez_set_guess(ctx: ?*FfiContext, guess_files: u64, guess_bytes: u64) void {
    const c = ctx orelse return;
    c.state.setGuess(guess_files, guess_bytes);
}

/// Set the caller identity (who is reporting progress and what for).
export fn progrez_set_identity(ctx: ?*FfiContext, caller_name: ?[*:0]const u8, context_name: ?[*:0]const u8) void {
    const c = ctx orelse return;
    const cn: []const u8 = if (caller_name) |n| std.mem.span(n) else "";
    const cxn: []const u8 = if (context_name) |n| std.mem.span(n) else "";
    c.state.setIdentity(cn, cxn);
}

/// Set the render interval in milliseconds.
export fn progrez_set_interval_ms(ctx: ?*FfiContext, ms: u32) void {
    const c = ctx orelse return;
    c.interval_ms = ms;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "ffi: null ctx safety" {
    progrez_update(null, 0, 0);
    progrez_finish(null);
    progrez_destroy(null);
    progrez_set_indeterminate(null);
    progrez_set_determinate(null, 0, 0);
    progrez_set_guess(null, 0, 0);
    progrez_set_identity(null, null, null);
    progrez_set_interval_ms(null, 0);
}

test "ffi: parse progress env" {
    try std.testing.expectEqual(@as(?bool, true), parseProgressEnv("true"));
    try std.testing.expectEqual(@as(?bool, true), parseProgressEnv("1"));
    try std.testing.expectEqual(@as(?bool, false), parseProgressEnv("false"));
    try std.testing.expectEqual(@as(?bool, false), parseProgressEnv("0"));
    try std.testing.expectEqual(@as(?bool, null), parseProgressEnv(null));
    try std.testing.expectEqual(@as(?bool, null), parseProgressEnv("garbage"));
}

test "ffi: parse interval env" {
    try std.testing.expectEqual(@as(u32, 500), parseIntervalEnv("500"));
    try std.testing.expectEqual(@as(u32, 1000), parseIntervalEnv(null));
    try std.testing.expectEqual(@as(u32, 1000), parseIntervalEnv("garbage"));
}

test "ffi: seqlock read returns null during write" {
    // Simulate a write-in-progress by setting an odd generation
    var ctx: FfiContext = undefined;
    ctx.generation = std.atomic.Value(u32).init(1); // odd = write in progress
    ctx.snapshot = .{
        .files_processed = 0,
        .files_total = null,
        .bytes_processed = 0,
        .bytes_total = null,
        .timestamp_ns = 0,
    };
    try std.testing.expectEqual(@as(?core.ProgrezSnapshot, null), readSnapshot(&ctx));
}

test "ffi: seqlock read returns snapshot when consistent" {
    var ctx: FfiContext = undefined;
    ctx.generation = std.atomic.Value(u32).init(2); // even = consistent
    ctx.snapshot = .{
        .files_processed = 42,
        .files_total = null,
        .bytes_processed = 1000,
        .bytes_total = null,
        .timestamp_ns = 999,
    };
    const snap = readSnapshot(&ctx);
    try std.testing.expect(snap != null);
    try std.testing.expectEqual(@as(u64, 42), snap.?.files_processed);
    try std.testing.expectEqual(@as(u64, 1000), snap.?.bytes_processed);
}

test "ffi: shouldEmitLogLine respects 10s interval" {
    var ctx: FfiContext = undefined;
    ctx.state = core.ProgrezState.init("Test");
    ctx.last_log_time_ns = 0;
    ctx.last_log_percent = -1;

    // At 5 seconds: not yet (no progress either)
    try std.testing.expect(!shouldEmitLogLine(&ctx, 5 * std.time.ns_per_s));

    // At 10 seconds: yes
    try std.testing.expect(shouldEmitLogLine(&ctx, 10 * std.time.ns_per_s));

    // Immediately after: no (timer was reset)
    try std.testing.expect(!shouldEmitLogLine(&ctx, 10 * std.time.ns_per_s + 1));
}

test "ffi: shouldEmitLogLine respects 10% progress milestones" {
    var ctx: FfiContext = undefined;
    ctx.state = core.ProgrezState.init("Test");
    ctx.state.setDeterminate(0, 1000);
    ctx.last_log_time_ns = 0;
    ctx.last_log_percent = -1;

    // 5% progress: triggers because decile 0 > last_log_percent of -1
    // (first progress emission at any percentage)
    ctx.state.bytes_processed = 50;
    try std.testing.expect(shouldEmitLogLine(&ctx, 1 * std.time.ns_per_s));
    // last_log_percent is now 0

    // Still at 5%: no (same decile)
    try std.testing.expect(!shouldEmitLogLine(&ctx, 2 * std.time.ns_per_s));

    // 10% progress: yes (decile 1 > 0)
    ctx.state.bytes_processed = 100;
    try std.testing.expect(shouldEmitLogLine(&ctx, 3 * std.time.ns_per_s));

    // Still at 10%: no
    try std.testing.expect(!shouldEmitLogLine(&ctx, 4 * std.time.ns_per_s));

    // 20% progress: yes (decile 2 > 1)
    ctx.state.bytes_processed = 200;
    try std.testing.expect(shouldEmitLogLine(&ctx, 5 * std.time.ns_per_s));
}
