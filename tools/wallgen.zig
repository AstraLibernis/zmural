// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Generates Prism, the wallpaper zmural ships with: three glowing triangles
//! turning against each other on a deep violet ground. It shows on a first
//! run and whenever no wallpaper is set, so the desktop is never left empty.
//!
//! Everything is drawn from code (a signed-distance triangle, a soft glow
//! and a tone curve): no outside artwork. The triangle's distance function
//! follows Inigo Quilez's (credited in THIRD_PARTY_NOTICES.md). Every motion is
//! periodic in the loop: a triangle looks the same every third of a turn and
//! each layer turns a whole number of thirds, so the last frame leads into
//! the first without a seam.
//!
//!   zig build starter-wallpaper    writes assets/wallpapers/Prism.webm (needs ffmpeg with libvpx-vp9)
//!   wallgen frames                 every frame as raw RGB24 on stdout
//!   wallgen still <t> <out.ppm>    one frame, t in 0..1 of the loop
//!
//! zsnag:allow R007 — every cast is a pixel index or a channel already clamped to 0..255.

const std = @import("std");

pub const width = 1920;
pub const height = 1080;
pub const fps = 30;
pub const seconds = 12;
pub const frames = fps * seconds;

const tau = 2 * std.math.pi;

const Rgb = [3]f32;

const Layer = struct { size: f32, turns: f32, color: Rgb };

const layers = [_]Layer{
    .{ .size = 0.66, .turns = 1, .color = .{ 0.35, 0.65, 1.0 } },
    .{ .size = 0.46, .turns = -1, .color = .{ 0.85, 0.40, 1.0 } },
    .{ .size = 0.27, .turns = 2, .color = .{ 1.0, 0.55, 0.65 } },
};

/// Signed distance from (px, py) to an equilateral triangle of "radius" r
/// centred on the origin, pointing up (after Inigo Quilez). Negative inside.
pub fn triangle(px_in: f32, py_in: f32, r: f32) f32 {
    const k: f32 = @sqrt(3.0);
    var px = @abs(px_in) - r;
    var py = py_in + r / k;
    if (px + k * py > 0) {
        const nx = (px - k * py) / 2;
        const ny = (-k * px - py) / 2;
        px = nx;
        py = ny;
    }
    px -= std.math.clamp(px, -2 * r, 0);
    return -@sqrt(px * px + py * py) * std.math.sign(py);
}

/// Where each layer is at loop time t (0..1): its rotation and its size.
const Pose = struct { cos: f32, sin: f32, r: f32 };

fn poses(t: f32) [layers.len]Pose {
    var out: [layers.len]Pose = undefined;
    for (layers, &out) |l, *p| {
        const a = l.turns * (tau / 3.0) * t + 0.3 * @sin(tau * t);
        p.* = .{ .cos = @cos(a), .sin = @sin(a), .r = l.size * (1 + 0.04 * @sin(tau * t + l.size * 7)) };
    }
    return out;
}

/// One pixel of the frame at loop time t, as 8-bit RGB.
pub fn pixel(x: u32, y: u32, ps: *const [layers.len]Pose) [3]u8 {
    const half_h: f32 = height / 2;
    const u = (@as(f32, @floatFromInt(x)) - width / 2) / half_h;
    const v = (@as(f32, @floatFromInt(y)) - height / 2) / half_h;
    // The ground: violet top to darker plum, darkening towards the corners.
    const top: Rgb = .{ 0.03, 0.03, 0.09 };
    const bottom: Rgb = .{ 0.09, 0.02, 0.12 };
    const fy = @as(f32, @floatFromInt(y)) / height;
    const rad = @min(@sqrt(u * u + v * v) / 2.2, 1);
    const vignette = 1 - 0.55 * rad * rad;
    var c: Rgb = undefined;
    for (&c, top, bottom) |*ch, a, b| ch.* = (a * (1 - fy) + b * fy) * vignette;

    for (layers, ps) |l, p| {
        const pu = p.cos * u - p.sin * v;
        const pv = p.sin * u + p.cos * v;
        const d = triangle(pu, pv, p.r) - 0.03;
        const line = @exp(-(d / 0.010) * (d / 0.010)) + 0.35 * @exp(-@abs(d) / 0.07);
        const fill: f32 = if (d < 0) 0.06 else 0;
        for (&c, l.color) |*ch, k| ch.* += (line + fill) * k;
    }
    var out: [3]u8 = undefined;
    for (&out, c) |*o, ch| {
        const mapped = std.math.clamp(1 - @exp(-ch * 1.4), 0, 1);
        o.* = @intFromFloat(std.math.pow(f32, mapped, 1.0 / 1.1) * 255 + 0.5);
    }
    return out;
}

/// The whole frame at loop time t into `buf` (width * height * 3 bytes).
pub fn frame(buf: []u8, t: f32) void {
    std.debug.assert(buf.len == width * height * 3);
    const ps = poses(t);
    var i: usize = 0;
    for (0..height) |y| for (0..width) |x| {
        const px = pixel(@intCast(x), @intCast(y), &ps);
        @memcpy(buf[i..][0..3], &px);
        i += 3;
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const usage = "usage: wallgen frames | wallgen still <t 0..1> <out.ppm>";
    if (argv.len < 2) return fail(usage);
    const buf = try gpa.alloc(u8, width * height * 3);
    defer gpa.free(buf);

    if (std.mem.eql(u8, argv[1], "frames")) {
        var out_buf: [32 * 1024]u8 = undefined;
        var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
        for (0..frames) |i| {
            frame(buf, @as(f32, @floatFromInt(i)) / frames);
            try out.interface.writeAll(buf);
        }
        try out.interface.flush();
    } else if (std.mem.eql(u8, argv[1], "still") and argv.len == 4) {
        const t = std.fmt.parseFloat(f32, argv[2]) catch return fail(usage);
        frame(buf, t);
        var header_buf: [32]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "P6 {d} {d} 255\n", .{ width, height });
        const ppm = try std.mem.concat(gpa, u8, &.{ header, buf });
        defer gpa.free(ppm);
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = argv[3], .data = ppm });
    } else return fail(usage);
}

fn fail(msg: []const u8) error{Usage} {
    std.log.err("{s}", .{msg});
    return error.Usage;
}

test "the loop has no seam: the frame after the last is the first" {
    const a = poses(0);
    const b = poses(1);
    // Each layer turns whole thirds of a turn, and a triangle looks the
    // same every third, so compare what is drawn, not the angles.
    for ([_][2]u32{ .{ 0, 0 }, .{ 960, 540 }, .{ 700, 300 }, .{ 1300, 800 }, .{ 1919, 1079 }, .{ 1100, 420 } }) |xy| {
        const pa = pixel(xy[0], xy[1], &a);
        const pb = pixel(xy[0], xy[1], &b);
        for (pa, pb) |ca, cb| try std.testing.expect(@abs(@as(i16, ca) - @as(i16, cb)) <= 1);
    }
}

test triangle {
    // The centre is inside, far away is outside, and a corner sits on the edge.
    try std.testing.expect(triangle(0, 0, 0.5) < 0);
    try std.testing.expect(triangle(3, 3, 0.5) > 0);
    const k: f32 = @sqrt(3.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), triangle(0.5, -0.5 / k, 0.5), 1e-5);
}
