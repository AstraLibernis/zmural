// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The animated test pattern: vertical bands of slowly drifting hues. Drawn
//! by the renderers when the wallpaper path is `test-pattern` (`zmural-console apply
//! test-pattern`), for testing without media files. `paint` draws with GDI
//! (Windows); `fill` writes XRGB8888 pixels (Linux buffers).

const std = @import("std");
const w = @import("../os/win32.zig");

pub const bands = 48;

pub fn paint(hdc: w.HDC, client: w.RECT, frame: u32) void {
    const width = client.right - client.left;
    var i: i32 = 0;
    while (i < bands) : (i += 1) {
        const band: w.RECT = .{
            .left = client.left + @divTrunc(width * i, bands),
            .right = client.left + @divTrunc(width * (i + 1), bands),
            .top = client.top,
            .bottom = client.bottom,
        };
        const hue: u32 = (@as(u32, @intCast(i)) * 360 / (bands * 2) + frame) % 360; // zsnag:ok — i in [0, bands)
        const c = hsv(hue, 0.55, 0.45);
        const brush = w.CreateSolidBrush(w.rgb(c[0], c[1], c[2])) orelse continue;
        _ = w.FillRect(hdc, &band, brush);
        _ = w.DeleteObject(brush);
    }
}

/// Fills `pixels` (XRGB8888, `stride` pixels per row) with the pattern.
pub fn fill(pixels: []u32, width: u32, height: u32, stride: u32, frame: u32) void {
    var i: u32 = 0;
    while (i < bands) : (i += 1) {
        const c = bandColor(i, frame);
        const px = (@as(u32, c[0]) << 16) | (@as(u32, c[1]) << 8) | c[2];
        const x0 = @as(u64, width) * i / bands;
        const x1 = @as(u64, width) * (i + 1) / bands;
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            const row = @as(usize, y) * stride;
            @memset(pixels[row + @as(usize, @intCast(x0)) .. row + @as(usize, @intCast(x1))], px); // zsnag:ok — x0 <= x1 <= width
        }
    }
}

/// Band `i`'s colour at animation frame `frame`, as RGB.
pub fn bandColor(i: u32, frame: u32) [3]u8 {
    return hsv((i * 360 / (bands * 2) + frame) % 360, 0.55, 0.45);
}

fn hsv(hue: u32, s: f32, v: f32) [3]u8 {
    const h = @as(f32, @floatFromInt(hue % 360)) / 60.0;
    const c = v * s;
    const x = c * (1 - @abs(@mod(h, 2) - 1));
    const m = v - c;
    const rgb: [3]f32 = switch (@as(u32, @intFromFloat(h))) {
        0 => .{ c, x, 0 },
        1 => .{ x, c, 0 },
        2 => .{ 0, c, x },
        3 => .{ 0, x, c },
        4 => .{ x, 0, c },
        else => .{ c, 0, x },
    };
    return .{ to8(rgb[0] + m), to8(rgb[1] + m), to8(rgb[2] + m) };
}

fn to8(f: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(f, 0, 1) * 255));
}

test hsv {
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, hsv(0, 1, 1));
    try std.testing.expectEqual([3]u8{ 0, 0, 255 }, hsv(240, 1, 1));
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, hsv(360, 1, 1));
}

test fill {
    var px: [8 * 2]u32 = undefined;
    fill(&px, 8, 2, 8, 0);
    // The first band (hue 0) is a muted red, and every row matches.
    try std.testing.expectEqual(@as(u32, 0x73), px[0] >> 16);
    try std.testing.expectEqualSlices(u32, px[0..8], px[8..16]);
}
