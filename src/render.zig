//! Determinate progress bar rendering.
//! Pure logic: takes state + terminal caps, writes into caller-provided buffer.

const std = @import("std");
const core = @import("core.zig");
const terminal = @import("terminal.zig");
const format = @import("format.zig");

// Unicode bar characters: full block + sub-character precision (7/8 down to 1/8)
// Index 0 = full block, index 7 = 1/8 block
const partial_blocks = [8][]const u8{
    "\xe2\x96\x88", // █ FULL BLOCK (U+2588)
    "\xe2\x96\x89", // ▉ LEFT SEVEN EIGHTHS BLOCK (U+2589)
    "\xe2\x96\x8a", // ▊ LEFT THREE QUARTERS BLOCK (U+258A)
    "\xe2\x96\x8b", // ▋ LEFT FIVE EIGHTHS BLOCK (U+258B)
    "\xe2\x96\x8c", // ▌ LEFT HALF BLOCK (U+258C)
    "\xe2\x96\x8d", // ▍ LEFT THREE EIGHTHS BLOCK (U+258D)
    "\xe2\x96\x8e", // ▎ LEFT ONE QUARTER BLOCK (U+258E)
    "\xe2\x96\x8f", // ▏ LEFT ONE EIGHTH BLOCK (U+258F)
};

const full_block = "\xe2\x96\x88"; // █
const empty_block = "\xe2\x96\x91"; // ░ LIGHT SHADE (U+2591)
const bar_left_cap = "\xe2\x96\x90"; // ▐ RIGHT HALF BLOCK (U+2590)
const bar_right_cap = "\xe2\x96\x8c"; // ▌ LEFT HALF BLOCK (U+258C)

const min_bar_width: usize = 10;

/// Render a single-line determinate progress bar into `buf`.
/// Returns a slice of `buf` containing the rendered line.
///
/// Layout: `{label} {bar} {stats}`
///
/// Stats are progressively dropped at narrow widths:
///   pct + files + bytes + eta  (all fit)
///   pct + files + bytes        (drop eta)
///   pct + files                (drop bytes)
///   pct                        (drop files)
///   (empty)                    (drop pct -- extremely narrow)
pub fn renderDeterminate(state: *const core.ProgrezState, caps: terminal.TerminalCaps, now_ns: i128, buf: []u8) []const u8 {
    _ = now_ns;
    const width: usize = @intCast(caps.width);
    if (width == 0 or buf.len == 0) return "";

    // --- 1. Format all stat pieces into small stack buffers ---
    const pct_frac: f64 = state.percentComplete() orelse 0.0;

    var pct_buf: [16]u8 = undefined;
    const pct_str = format.formatPercent(pct_frac, &pct_buf);

    var files_buf: [64]u8 = undefined;
    var files_str: []const u8 = "";
    if (state.files_total) |ft| {
        files_str = std.fmt.bufPrint(&files_buf, "{d}/{d} files", .{ state.files_processed, ft }) catch "";
    }

    var bytes_buf: [64]u8 = undefined;
    var bytes_str: []const u8 = "";
    if (state.bytes_total) |bt| {
        var proc_buf: [32]u8 = undefined;
        var total_buf: [32]u8 = undefined;
        const proc_s = format.formatBytes(state.bytes_processed, &proc_buf);
        const total_s = format.formatBytes(bt, &total_buf);
        bytes_str = std.fmt.bufPrint(&bytes_buf, "{s}/{s}", .{ proc_s, total_s }) catch "";
    }

    var eta_buf: [32]u8 = undefined;
    var eta_str: []const u8 = "";
    if (state.estimateEtaSeconds()) |eta_secs| {
        eta_str = format.formatEta(eta_secs, &eta_buf);
    }

    // --- 2. Build stats string with priority dropping ---
    // Stat pieces in priority order (lowest priority = dropped first):
    //   eta, bytes, files, pct
    // We try fitting all, then progressively drop from the end (lowest priority).

    const label = state.getLabel();
    // Fixed overhead: label + 1 space + 2 spaces around bar = label_len + 3
    // But we need: label + " " + bar + "  " + stats
    // So: overhead = label_len + 1 (space after label) + 2 (spaces before stats)
    // bar_width = width - overhead - stats_display_len
    // We need bar_width >= min_bar_width

    const label_len = label.len;

    // Try all 5 stat levels (4 stats -> 0 stats)
    const StatLevel = enum { all, no_eta, no_bytes, no_files, none };
    const levels = [_]StatLevel{ .all, .no_eta, .no_bytes, .no_files, .none };

    var chosen_stats_buf: [256]u8 = undefined;
    var chosen_stats: []const u8 = "";
    var chosen_bar_width: usize = 0;

    for (levels) |level| {
        // Build stats string for this level
        var stats_parts: [4][]const u8 = undefined;
        var stats_count: usize = 0;

        // Always include pct unless level == .none
        if (level != .none) {
            stats_parts[stats_count] = pct_str;
            stats_count += 1;
        }
        if (level == .all or level == .no_eta or level == .no_bytes) {
            if (files_str.len > 0) {
                stats_parts[stats_count] = files_str;
                stats_count += 1;
            }
        }
        if (level == .all or level == .no_eta) {
            if (bytes_str.len > 0) {
                stats_parts[stats_count] = bytes_str;
                stats_count += 1;
            }
        }
        if (level == .all) {
            if (eta_str.len > 0) {
                stats_parts[stats_count] = eta_str;
                stats_count += 1;
            }
        }

        // Join with "  " (2 spaces)
        var stats_len: usize = 0;
        for (0..stats_count) |i| {
            if (i > 0) {
                @memcpy(chosen_stats_buf[stats_len .. stats_len + 2], "  ");
                stats_len += 2;
            }
            const part = stats_parts[i];
            @memcpy(chosen_stats_buf[stats_len .. stats_len + part.len], part);
            stats_len += part.len;
        }
        chosen_stats = chosen_stats_buf[0..stats_len];

        // Calculate bar width
        // Layout: "{label} {bar}  {stats}" or "{label} {bar}" if no stats
        const overhead = label_len + 1 + (if (stats_len > 0) stats_len + 2 else @as(usize, 0));
        if (overhead >= width) {
            // Not even enough room for label + overhead, try dropping more
            if (level == .none) {
                // Even with no stats, label + space doesn't fit.
                // Give minimum bar
                chosen_bar_width = min_bar_width;
                chosen_stats = "";
                break;
            }
            continue;
        }
        const available = width - overhead;
        if (available >= min_bar_width) {
            chosen_bar_width = available;
            break;
        }
        // Not enough for min_bar_width, try dropping more stats
        if (level == .none) {
            // With no stats and label, bar is width - label_len - 1
            if (width > label_len + 1) {
                chosen_bar_width = width - label_len - 1;
            } else {
                chosen_bar_width = min_bar_width;
            }
            chosen_stats = "";
            break;
        }
    }

    if (chosen_bar_width < min_bar_width) {
        chosen_bar_width = min_bar_width;
    }

    // --- 3. Render the bar ---
    var pos: usize = 0;

    // Write label
    if (label_len > 0 and pos + label_len < buf.len) {
        @memcpy(buf[pos .. pos + label_len], label);
        pos += label_len;
    }

    // Space after label
    if (pos < buf.len) {
        buf[pos] = ' ';
        pos += 1;
    }

    // Render the bar itself
    if (caps.unicode) {
        pos = renderUnicodeBar(buf, pos, chosen_bar_width, pct_frac, caps.truecolor);
    } else {
        pos = renderAsciiBar(buf, pos, chosen_bar_width, pct_frac);
    }

    // Space + stats
    if (chosen_stats.len > 0) {
        if (pos + 2 + chosen_stats.len <= buf.len) {
            buf[pos] = ' ';
            buf[pos + 1] = ' ';
            pos += 2;
            @memcpy(buf[pos .. pos + chosen_stats.len], chosen_stats);
            pos += chosen_stats.len;
        }
    }

    return buf[0..pos];
}

/// Render a Unicode progress bar with sub-character precision.
/// Returns the new position in the buffer.
fn renderUnicodeBar(buf: []u8, start: usize, bar_width: usize, frac: f64, truecolor: bool) usize {
    var pos = start;

    // Bar structure: cap + inner + cap
    // The caps take 1 display column each but are multi-byte UTF-8.
    // Inner width = bar_width - 2 (for the two caps)
    const inner_width = if (bar_width > 2) bar_width - 2 else 1;

    // Left cap: ▐
    if (pos + bar_left_cap.len <= buf.len) {
        @memcpy(buf[pos .. pos + bar_left_cap.len], bar_left_cap);
        pos += bar_left_cap.len;
    }

    // Calculate fill: how many full cells + partial
    // Use 8ths precision
    const fill_eighths: usize = @intFromFloat(@min(frac, 1.0) * @as(f64, @floatFromInt(inner_width)) * 8.0);
    const full_cells = fill_eighths / 8;
    const partial_eighth = fill_eighths % 8;
    const empty_cells = inner_width - full_cells - (if (partial_eighth > 0) @as(usize, 1) else @as(usize, 0));

    // Render filled cells
    for (0..full_cells) |i| {
        if (truecolor) {
            pos = writeColoredBlock(buf, pos, full_block, i, inner_width);
        } else {
            if (pos + full_block.len <= buf.len) {
                @memcpy(buf[pos .. pos + full_block.len], full_block);
                pos += full_block.len;
            }
        }
    }

    // Render partial cell (if any)
    if (partial_eighth > 0) {
        // partial_blocks: index 0 = 8/8 (full), we need (8 - partial_eighth)
        // Actually: partial_eighth=7 means 7/8 filled -> index 1
        // partial_eighth=1 means 1/8 filled -> index 7
        const idx = 8 - partial_eighth;
        const block = partial_blocks[idx];
        if (truecolor) {
            pos = writeColoredBlock(buf, pos, block, full_cells, inner_width);
        } else {
            if (pos + block.len <= buf.len) {
                @memcpy(buf[pos .. pos + block.len], block);
                pos += block.len;
            }
        }
    }

    // Reset color after filled section if truecolor
    if (truecolor and (full_cells > 0 or partial_eighth > 0)) {
        const reset = "\x1b[0m";
        if (pos + reset.len <= buf.len) {
            @memcpy(buf[pos .. pos + reset.len], reset);
            pos += reset.len;
        }
    }

    // Render empty cells
    for (0..empty_cells) |_| {
        if (pos + empty_block.len <= buf.len) {
            @memcpy(buf[pos .. pos + empty_block.len], empty_block);
            pos += empty_block.len;
        }
    }

    // Right cap: ▌
    if (pos + bar_right_cap.len <= buf.len) {
        @memcpy(buf[pos .. pos + bar_right_cap.len], bar_right_cap);
        pos += bar_right_cap.len;
    }

    return pos;
}

/// Render an ASCII progress bar.
fn renderAsciiBar(buf: []u8, start: usize, bar_width: usize, frac: f64) usize {
    var pos = start;

    // Bar structure: [ + inner + ]
    const inner_width = if (bar_width > 2) bar_width - 2 else 1;

    if (pos < buf.len) {
        buf[pos] = '[';
        pos += 1;
    }

    const filled: usize = @intFromFloat(@min(frac, 1.0) * @as(f64, @floatFromInt(inner_width)));

    // Filled: '='
    for (0..filled) |_| {
        if (pos < buf.len) {
            buf[pos] = '=';
            pos += 1;
        }
    }

    // Cursor: '>' (if not at end)
    if (filled < inner_width) {
        if (pos < buf.len) {
            buf[pos] = '>';
            pos += 1;
        }
        // Empty: ' '
        const empty = inner_width - filled - 1;
        for (0..empty) |_| {
            if (pos < buf.len) {
                buf[pos] = ' ';
                pos += 1;
            }
        }
    }

    if (pos < buf.len) {
        buf[pos] = ']';
        pos += 1;
    }

    return pos;
}

/// Write a single colored block character with truecolor gradient.
/// Gradient: cyan(0,255,255) -> violet(128,0,255) -> magenta(255,0,255)
fn writeColoredBlock(buf: []u8, start: usize, block: []const u8, cell_idx: usize, total_cells: usize) usize {
    var pos = start;

    // Calculate position in gradient [0.0, 1.0]
    const t: f64 = if (total_cells <= 1) 0.0 else @as(f64, @floatFromInt(cell_idx)) / @as(f64, @floatFromInt(total_cells - 1));

    // Interpolate color
    var r: u8 = undefined;
    var g: u8 = undefined;
    var b: u8 = undefined;

    if (t <= 0.5) {
        // cyan(0,255,255) -> violet(128,0,255)
        const t2 = t * 2.0;
        r = @intFromFloat(0.0 + 128.0 * t2);
        g = @intFromFloat(255.0 * (1.0 - t2));
        b = 255;
    } else {
        // violet(128,0,255) -> magenta(255,0,255)
        const t2 = (t - 0.5) * 2.0;
        r = @intFromFloat(128.0 + 127.0 * t2);
        g = 0;
        b = 255;
    }

    // Write ANSI truecolor escape: \x1b[38;2;R;G;Bm
    var esc_buf: [32]u8 = undefined;
    const esc = std.fmt.bufPrint(&esc_buf, "\x1b[38;2;{d};{d};{d}m", .{ r, g, b }) catch "";

    if (pos + esc.len + block.len <= buf.len) {
        @memcpy(buf[pos .. pos + esc.len], esc);
        pos += esc.len;
        @memcpy(buf[pos .. pos + block.len], block);
        pos += block.len;
    }

    return pos;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "render: determinate bar at width 80 (unicode, no color)" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 234;
    state.bytes_processed = 12_300_000;
    state.ema_bytes_per_sec = 500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 12_300_000_000, &buf_arr);

    // Should contain label, percentage, file count
    try std.testing.expect(std.mem.indexOf(u8, line, "Compressing") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "58.") != null); // ~58.6%
    try std.testing.expect(std.mem.indexOf(u8, line, "234/400") != null);
    // Should contain block chars (filled or empty)
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x96\x88") != null or
        std.mem.indexOf(u8, line, "\xe2\x96\x91") != null);
}

test "render: determinate bar ASCII fallback" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 234;
    state.bytes_processed = 12_300_000;
    state.ema_bytes_per_sec = 500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = false,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 12_300_000_000, &buf_arr);

    // Should use ASCII bar chars
    try std.testing.expect(std.mem.indexOf(u8, line, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "=") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "]") != null);
    // Should NOT contain unicode blocks
    try std.testing.expect(std.mem.indexOf(u8, line, "\xe2\x96\x88") == null);
}

test "render: progressive stat dropping at narrow width" {
    var state = core.ProgrezState.init("Compressing");
    state.setDeterminate(400, 21_000_000);
    state.files_processed = 234;
    state.bytes_processed = 12_300_000;
    state.ema_bytes_per_sec = 500_000;
    state.samples_count = 5;
    state.start_time_ns = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 40,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 12_300_000_000, &buf_arr);

    // At width 40, ETA should be dropped but % should still be present
    try std.testing.expect(std.mem.indexOf(u8, line, "%") != null);
    // Bar should still exist
    try std.testing.expect(line.len > 0);
}

test "render: truecolor gradient produces ANSI escape sequences" {
    var state = core.ProgrezState.init("Test");
    state.setDeterminate(0, 1000);
    state.bytes_processed = 500;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = true,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [4096]u8 = undefined;
    const line = renderDeterminate(&state, caps, 0, &buf_arr);

    // Should contain ANSI truecolor escape
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[38;2;") != null);
    // Should contain reset
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b[0m") != null);
}

test "render: 0% progress" {
    var state = core.ProgrezState.init("Starting");
    state.setDeterminate(100, 10_000);
    state.files_processed = 0;
    state.bytes_processed = 0;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 0, &buf_arr);

    try std.testing.expect(std.mem.indexOf(u8, line, "0.0%") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "Starting") != null);
}

test "render: 100% progress" {
    var state = core.ProgrezState.init("Done");
    state.setDeterminate(100, 10_000);
    state.files_processed = 100;
    state.bytes_processed = 10_000;

    const caps = terminal.TerminalCaps{
        .is_tty = true,
        .unicode = true,
        .truecolor = false,
        .color_256 = false,
        .color_16 = false,
        .width = 80,
    };

    var buf_arr: [1024]u8 = undefined;
    const line = renderDeterminate(&state, caps, 5_000_000_000, &buf_arr);

    try std.testing.expect(std.mem.indexOf(u8, line, "100.0%") != null);
}
