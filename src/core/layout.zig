// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Placing a wallpaper's frames on a monitor: which part of the source to
//! sample (`src`) and where on the monitor to draw it (`dst`).
//!
//! `Rect` is used everywhere. `place` is for renderers that draw frames
//! themselves (the Linux display host, M6); on Windows mpv does the fitting.

const std = @import("std");

pub const FillMode = enum {
    /// Fill the monitor, trimming the source's overflow (default).
    crop,
    /// Show the whole source, letterboxed.
    fit,
    /// Fill the monitor, ignoring aspect ratio.
    stretch,
    /// Native size, centred, clipped if larger.
    center,
};

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: u32,
    h: u32,
};

pub const Placement = struct { src: Rect, dst: Rect };

pub fn place(mode: FillMode, src_w: u32, src_h: u32, dst: Rect) Placement {
    const full: Rect = .{ .w = src_w, .h = src_h };
    if (src_w == 0 or src_h == 0 or dst.w == 0 or dst.h == 0) return .{ .src = full, .dst = dst };

    const sw: u64 = src_w;
    const sh: u64 = src_h;
    const dw: u64 = dst.w;
    const dh: u64 = dst.h;
    const src_wider = sw * dh > sh * dw;

    switch (mode) {
        .stretch => return .{ .src = full, .dst = dst },
        .crop => {
            if (src_wider) {
                const w: u32 = @intCast(sh * dw / dh);
                return .{ .src = .{ .x = @intCast((src_w - w) / 2), .w = w, .h = src_h }, .dst = dst };
            }
            const h: u32 = @intCast(sw * dh / dw);
            return .{ .src = .{ .y = @intCast((src_h - h) / 2), .w = src_w, .h = h }, .dst = dst };
        },
        .fit => {
            if (src_wider) {
                const h: u32 = @intCast(sh * dw / sw);
                return .{ .src = full, .dst = .{ .x = dst.x, .y = dst.y + half(dst.h - h), .w = dst.w, .h = h } };
            }
            const w: u32 = @intCast(sw * dh / sh);
            return .{ .src = full, .dst = .{ .x = dst.x + half(dst.w - w), .y = dst.y, .w = w, .h = dst.h } };
        },
        .center => {
            const w = @min(src_w, dst.w);
            const h = @min(src_h, dst.h);
            return .{
                .src = .{ .x = half(src_w - w), .y = half(src_h - h), .w = w, .h = h },
                .dst = .{ .x = dst.x + half(dst.w - w), .y = dst.y + half(dst.h - h), .w = w, .h = h },
            };
        },
    }
}

fn half(v: u32) i32 {
    return @intCast(v / 2);
}

test "crop trims the wider side" {
    const p = place(.crop, 1920, 1080, .{ .w = 1080, .h = 1080 });
    try std.testing.expectEqual(Rect{ .x = 420, .y = 0, .w = 1080, .h = 1080 }, p.src);
    const q = place(.crop, 1080, 1920, .{ .w = 1920, .h = 1080 });
    try std.testing.expectEqual(Rect{ .x = 0, .y = 656, .w = 1080, .h = 607 }, q.src);
}

test "fit letterboxes" {
    const p = place(.fit, 1920, 1080, .{ .x = 100, .y = 0, .w = 1000, .h = 1000 });
    try std.testing.expectEqual(Rect{ .x = 100, .y = 219, .w = 1000, .h = 562 }, p.dst);
}

test "center keeps native size" {
    const p = place(.center, 800, 600, .{ .w = 1920, .h = 1080 });
    try std.testing.expectEqual(Rect{ .x = 560, .y = 240, .w = 800, .h = 600 }, p.dst);
    const big = place(.center, 4000, 3000, .{ .w = 1920, .h = 1080 });
    try std.testing.expectEqual(Rect{ .x = 1040, .y = 960, .w = 1920, .h = 1080 }, big.src);
}

test "degenerate sizes pass through" {
    const p = place(.crop, 0, 0, .{ .w = 1920, .h = 1080 });
    try std.testing.expectEqual(@as(u32, 1920), p.dst.w);
}
