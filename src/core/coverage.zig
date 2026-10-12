// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! "Is this monitor's wallpaper hidden?" A coarse tile grid over the monitor,
//! counting tiles whose centre no window covers. Cheap enough to re-run on
//! every coalesced window event.
//!
//! Callers pass only windows that actually hide the desktop: visible, not
//! minimised, not cloaked, not transparent overlays. A maximised or
//! fullscreen window should short-circuit before this runs.

const std = @import("std");
const Rect = @import("layout.zig").Rect;

pub const default_tile: u32 = 50;
/// A monitor counts as covered when at most this fraction of it is visible.
pub const default_max_uncovered: f32 = 0.05;

/// Fraction (0..1) of the monitor's tiles that no window covers.
pub fn uncoveredFraction(monitor: Rect, windows: []const Rect, tile: u32) f32 {
    std.debug.assert(tile > 0);
    if (monitor.w == 0 or monitor.h == 0) return 0;
    const cols = (monitor.w + tile - 1) / tile;
    const rows = (monitor.h + tile - 1) / tile;

    var open: u32 = 0;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const cy = @as(i64, monitor.y) + @min(row * tile + tile / 2, monitor.h - 1);
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const cx = @as(i64, monitor.x) + @min(col * tile + tile / 2, monitor.w - 1);
            if (!anyContains(windows, cx, cy)) open += 1;
        }
    }
    return @as(f32, @floatFromInt(open)) / @as(f32, @floatFromInt(cols * rows));
}

pub fn isCovered(monitor: Rect, windows: []const Rect) bool {
    return uncoveredFraction(monitor, windows, default_tile) <= default_max_uncovered;
}

fn anyContains(windows: []const Rect, x: i64, y: i64) bool {
    for (windows) |r| {
        if (x >= r.x and y >= r.y and x < @as(i64, r.x) + r.w and y < @as(i64, r.y) + r.h) return true;
    }
    return false;
}

test "no windows means fully visible" {
    try std.testing.expectEqual(@as(f32, 1), uncoveredFraction(.{ .w = 1920, .h = 1080 }, &.{}, default_tile));
}

test "full-screen window covers the monitor" {
    const mon: Rect = .{ .x = 1920, .y = 0, .w = 2560, .h = 1440 };
    try std.testing.expect(isCovered(mon, &.{mon}));
}

test "half-covered monitor is not covered" {
    const mon: Rect = .{ .w = 1000, .h = 1000 };
    const f = uncoveredFraction(mon, &.{.{ .w = 500, .h = 1000 }}, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f, 0.001);
    try std.testing.expect(!isCovered(mon, &.{.{ .w = 500, .h = 1000 }}));
}

test "two windows tiling the monitor cover it" {
    const mon: Rect = .{ .w = 1000, .h = 800 };
    try std.testing.expect(isCovered(mon, &.{ .{ .w = 500, .h = 800 }, .{ .x = 500, .w = 500, .h = 800 } }));
}
