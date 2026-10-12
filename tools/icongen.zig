// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Generates zmural's icon: a night sky with a four-pointed star and a
//! comet trail sweeping up into it. The idea is freedom among the stars: a
//! path taken freely across the sky.
//!
//! Everything is drawn from code (signed-distance shapes, 4x4 supersampling
//! per pixel) at each size Windows asks for, so every size is sharp rather
//! than downscaled. Small sizes get a thicker trail, a bigger star and no
//! background stars.
//!
//!   zig build icon    writes assets/zmural.ico and zig-out/icon-preview.png
//!
//! Output: .ico with 16, 20, 24, 32, 40, 48, 64 (32-bit BMP) and 256 (PNG).
//! The PNG writer uses stored (uncompressed) deflate blocks, so it needs no
//! compressor.
//!
//! zsnag:allow R007 — every cast here is bounded by the fixed icon sizes (<= 256) and preview canvas.

const std = @import("std");

const Rgb = struct {
    r: f32,
    g: f32,
    b: f32,

    fn hex(v: u24) Rgb {
        return .{
            .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255,
            .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255,
            .b = @as(f32, @floatFromInt(v & 0xff)) / 255,
        };
    }

    fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
        return .{ .r = a.r + (b.r - a.r) * t, .g = a.g + (b.g - a.g) * t, .b = a.b + (b.b - a.b) * t };
    }

    fn scale(a: Rgb, k: f32) Rgb {
        return .{ .r = a.r * k, .g = a.g * k, .b = a.b * k };
    }

    fn add(a: Rgb, b: Rgb) Rgb {
        return .{ .r = a.r + b.r, .g = a.g + b.g, .b = a.b + b.b };
    }
};

/// Straight (non-premultiplied) colour with coverage.
const Px = struct {
    c: Rgb = .{ .r = 0, .g = 0, .b = 0 },
    a: f32 = 0,

    /// Paints `src` with opacity `alpha` over this pixel.
    fn over(dst: *Px, src: Rgb, alpha: f32) void {
        const a = std.math.clamp(alpha, 0, 1);
        if (a == 0) return;
        const out_a = a + dst.a * (1 - a);
        dst.c = src.scale(a).add(dst.c.scale(dst.a * (1 - a))).scale(1 / out_a);
        dst.a = out_a;
    }

    /// Adds light (for glows), keeping coverage.
    fn glow(dst: *Px, light: Rgb, amount: f32) void {
        dst.c = dst.c.add(light.scale(amount));
    }
};

// ---- palette ----------------------------------------------------------------------
const sky_top = Rgb.hex(0x120E36);
const sky_bottom = Rgb.hex(0x3A1B6B);
const nebula = Rgb.hex(0x8A5CFF);
const trail_tail = Rgb.hex(0x3FD6FF);
const trail_head = Rgb.hex(0xFFF3D1);
const star_core = Rgb.hex(0xFFFFFF);
const star_edge = Rgb.hex(0xFFCF6A);
const white = Rgb.hex(0xFFFFFF);

// ---- geometry (unit square, y down) ------------------------------------------------
const star_c = [2]f32{ 0.675, 0.325 };
const trail_p0 = [2]f32{ 0.13, 0.885 };
const trail_p1 = [2]f32{ 0.27, 0.40 };
const trail_p2 = [2]f32{ 0.625, 0.36 };
const faint_stars = [_][4]f32{
    // x, y, radius, brightness
    .{ 0.27, 0.20, 0.016, 0.9 },
    .{ 0.18, 0.46, 0.010, 0.6 },
    .{ 0.83, 0.62, 0.012, 0.7 },
    .{ 0.52, 0.66, 0.009, 0.5 },
    .{ 0.40, 0.13, 0.008, 0.5 },
    .{ 0.88, 0.16, 0.009, 0.55 },
    .{ 0.70, 0.84, 0.010, 0.45 },
};

const Style = struct {
    margin: f32,
    corner: f32,
    star_r: f32,
    trail_w0: f32,
    trail_w1: f32,
    faint: bool,

    fn forSize(px: u32) Style {
        return if (px <= 24)
            .{ .margin = 0.0, .corner = 0.20, .star_r = 0.25, .trail_w0 = 0.035, .trail_w1 = 0.085, .faint = false }
        else if (px <= 48)
            .{ .margin = 0.02, .corner = 0.21, .star_r = 0.22, .trail_w0 = 0.02, .trail_w1 = 0.065, .faint = true }
        else
            .{ .margin = 0.035, .corner = 0.22, .star_r = 0.20, .trail_w0 = 0.010, .trail_w1 = 0.055, .faint = true };
    }
};

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

fn insideRoundRect(u: f32, v: f32, m: f32, r: f32) bool {
    const lo = m + r;
    const hi = 1 - m - r;
    const dx = @max(@max(lo - u, u - hi), 0);
    const dy = @max(@max(lo - v, v - hi), 0);
    return u >= m and u <= 1 - m and v >= m and v <= 1 - m and dx * dx + dy * dy <= r * r;
}

fn bezier(t: f32) [2]f32 {
    const s = 1 - t;
    return .{
        s * s * trail_p0[0] + 2 * s * t * trail_p1[0] + t * t * trail_p2[0],
        s * s * trail_p0[1] + 2 * s * t * trail_p1[1] + t * t * trail_p2[1],
    };
}

/// Distance to the trail curve and the curve parameter at the closest point.
fn trailDistance(u: f32, v: f32) struct { d: f32, t: f32 } {
    var best: f32 = std.math.inf(f32);
    var best_t: f32 = 0;
    const n = 96;
    var i: u32 = 0;
    while (i <= n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / n;
        const p = bezier(t);
        const d = (u - p[0]) * (u - p[0]) + (v - p[1]) * (v - p[1]);
        if (d < best) {
            best = d;
            best_t = t;
        }
    }
    return .{ .d = @sqrt(best), .t = best_t };
}

/// One supersample of the icon at unit coordinates (u, v).
fn shade(u: f32, v: f32, st: Style) Px {
    var px: Px = .{};
    if (!insideRoundRect(u, v, st.margin, st.corner)) return px;

    // Sky: vertical gradient plus a nebula glow behind the star.
    px.over(sky_top.mix(sky_bottom, v), 1);
    const gx = u - star_c[0];
    const gy = v - star_c[1];
    px.glow(nebula, 0.45 * @exp(-(gx * gx + gy * gy) / 0.06));

    // Faint stars.
    if (st.faint) for (faint_stars) |s| {
        const dx = u - s[0];
        const dy = v - s[1];
        const d = @sqrt(dx * dx + dy * dy);
        px.over(white, s[3] * (1 - smoothstep(s[2] * 0.6, s[2], d)));
    };

    // Comet trail: thin and cool at the tail, thick and warm at the star.
    const tr = trailDistance(u, v);
    const width = st.trail_w0 + (st.trail_w1 - st.trail_w0) * std.math.pow(f32, tr.t, 1.6);
    const fade = smoothstep(0.0, 0.45, tr.t);
    const trail_color = trail_tail.mix(trail_head, std.math.pow(f32, tr.t, 1.4));
    px.glow(trail_color, 0.35 * fade * @exp(-(tr.d * tr.d) / (width * width * 6)));
    if (tr.d < width) px.over(trail_color, fade * (0.55 + 0.45 * tr.t));

    // The star: a four-pointed astroid sparkle with a warm rim and a glow.
    const dx = @abs(u - star_c[0]);
    const dy = @abs(v - star_c[1]);
    const r = @sqrt(dx * dx + dy * dy);
    px.glow(star_edge, 0.55 * @exp(-(r * r) / (st.star_r * st.star_r * 0.35)));
    const astroid = std.math.pow(f32, dx / st.star_r, 2.0 / 3.0) + std.math.pow(f32, dy / st.star_r, 2.0 / 3.0);
    if (astroid <= 1) px.over(star_core.mix(star_edge, smoothstep(0.1, 0.95, astroid)), 1);

    px.c = .{ .r = @min(px.c.r, 1), .g = @min(px.c.g, 1), .b = @min(px.c.b, 1) };
    return px;
}

/// Renders a size×size RGBA image (straight alpha), 4×4 supersampled.
fn render(gpa: std.mem.Allocator, size: u32) ![]u8 {
    const st = Style.forSize(size);
    const out = try gpa.alloc(u8, size * size * 4);
    const ss = 4;
    const fsize: f32 = @floatFromInt(size);
    for (0..size) |y| for (0..size) |x| {
        var acc: Rgb = .{ .r = 0, .g = 0, .b = 0 };
        var acc_a: f32 = 0;
        for (0..ss) |sy| for (0..ss) |sx| {
            const u = (@as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sx)) + 0.5) / ss) / fsize;
            const v = (@as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sy)) + 0.5) / ss) / fsize;
            const p = shade(u, v, st);
            acc = acc.add(p.c.scale(p.a)); // premultiplied accumulation
            acc_a += p.a;
        };
        const i = (y * size + x) * 4;
        const a = acc_a / (ss * ss);
        const inv = if (acc_a > 0) 1 / acc_a else 0;
        out[i + 0] = to8(acc.r * inv);
        out[i + 1] = to8(acc.g * inv);
        out[i + 2] = to8(acc.b * inv);
        out[i + 3] = to8(a);
    };
    return out;
}

fn to8(f: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(f, 0, 1) * 255));
}

// ---- PNG (stored deflate) ------------------------------------------------------------

fn writePng(gpa: std.mem.Allocator, rgba: []const u8, w: u32, h: u32) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    for (0..h) |y| {
        try raw.append(gpa, 0); // filter: none
        try raw.appendSlice(gpa, rgba[y * w * 4 ..][0 .. w * 4]);
    }
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(gpa);
    try z.appendSlice(gpa, &.{ 0x78, 0x01 });
    var off: usize = 0;
    while (true) {
        const n = @min(raw.items.len - off, 65535);
        const last = off + n == raw.items.len;
        try z.append(gpa, if (last) 1 else 0);
        try appendInt(gpa, &z, u16, @intCast(n), .little);
        try appendInt(gpa, &z, u16, ~@as(u16, @intCast(n)), .little);
        try z.appendSlice(gpa, raw.items[off..][0..n]);
        off += n;
        if (last) break;
    }
    try appendInt(gpa, &z, u32, std.hash.Adler32.hash(raw.items), .big);

    var png: std.ArrayList(u8) = .empty;
    errdefer png.deinit(gpa);
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit RGBA
    try chunk(gpa, &png, "IHDR", &ihdr);
    try chunk(gpa, &png, "IDAT", z.items);
    try chunk(gpa, &png, "IEND", "");
    return png.toOwnedSlice(gpa);
}

fn chunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    try appendInt(gpa, out, u32, @intCast(data.len), .big);
    const start = out.items.len;
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    try appendInt(gpa, out, u32, std.hash.Crc32.hash(out.items[start..]), .big);
}

fn appendInt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), comptime T: type, v: T, endian: std.builtin.Endian) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, endian);
    try out.appendSlice(gpa, &b);
}

// ---- ICO -------------------------------------------------------------------------------

const sizes = [_]u32{ 16, 20, 24, 32, 40, 48, 64, 256 };

/// A 32-bit DIB for an icon entry: BITMAPINFOHEADER (height doubled for the
/// mask), BGRA rows bottom-up, then an all-zero AND mask (alpha does the work).
fn writeDib(gpa: std.mem.Allocator, rgba: []const u8, size: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const mask_row = ((size + 31) / 32) * 4;
    try appendInt(gpa, &out, u32, 40, .little);
    try appendInt(gpa, &out, i32, @intCast(size), .little);
    try appendInt(gpa, &out, i32, @intCast(size * 2), .little);
    try appendInt(gpa, &out, u16, 1, .little);
    try appendInt(gpa, &out, u16, 32, .little);
    try appendInt(gpa, &out, u32, 0, .little); // BI_RGB
    try appendInt(gpa, &out, u32, size * size * 4 + mask_row * size, .little);
    for (0..4) |_| try appendInt(gpa, &out, u32, 0, .little);
    var y = size;
    while (y > 0) {
        y -= 1;
        for (0..size) |x| {
            const i = (y * size + x) * 4;
            try out.appendSlice(gpa, &.{ rgba[i + 2], rgba[i + 1], rgba[i + 0], rgba[i + 3] });
        }
    }
    try out.appendNTimes(gpa, 0, mask_row * size);
    return out.toOwnedSlice(gpa);
}

fn writeIco(gpa: std.mem.Allocator, images: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try appendInt(gpa, &out, u16, 0, .little);
    try appendInt(gpa, &out, u16, 1, .little); // icon
    try appendInt(gpa, &out, u16, @intCast(sizes.len), .little);
    var offset: u32 = 6 + 16 * sizes.len;
    for (sizes, images) |size, img| {
        const dim: u8 = if (size >= 256) 0 else @intCast(size);
        try out.appendSlice(gpa, &.{ dim, dim, 0, 0 });
        try appendInt(gpa, &out, u16, 1, .little); // planes
        try appendInt(gpa, &out, u16, 32, .little); // bits per pixel
        try appendInt(gpa, &out, u32, @intCast(img.len), .little);
        try appendInt(gpa, &out, u32, offset, .little);
        offset += @intCast(img.len);
    }
    for (images) |img| try out.appendSlice(gpa, img);
    return out.toOwnedSlice(gpa);
}

// ---- preview ---------------------------------------------------------------------------

/// Every size at 1:1 on a dark and a light strip, plus 16 and 32 blown up so
/// the individual pixels can be judged.
fn preview(gpa: std.mem.Allocator, rendered: []const []const u8) !struct { []u8, u32, u32 } {
    const w: u32 = 1000;
    const strip: u32 = 300;
    const h = strip * 2;
    const canvas = try gpa.alloc(u8, w * h * 4);
    for ([_]u24{ 0x1F1F1F, 0xF3F3F3 }, 0..) |bg, band| {
        const c = Rgb.hex(bg);
        for (0..strip) |y| for (0..w) |x| {
            const i = ((band * strip + y) * w + x) * 4;
            canvas[i..][0..4].* = .{ to8(c.r), to8(c.g), to8(c.b), 255 };
        };
        const top: u32 = @intCast(band * strip + 22);
        var x: u32 = 22;
        var i = sizes.len;
        while (i > 0) {
            i -= 1;
            blit(canvas, w, rendered[i], sizes[i], x, top + 256 - sizes[i], 1);
            x += sizes[i] + 18;
        }
        blit(canvas, w, rendered[0], 16, x, top + 256 - 16 * 8, 8);
        x += 16 * 8 + 18;
        blit(canvas, w, rendered[3], 32, x, top + 256 - 32 * 4, 4);
    }
    return .{ canvas, w, h };
}

fn blit(canvas: []u8, cw: u32, img: []const u8, size: u32, x0: u32, y0: u32, zoom: u32) void {
    for (0..size * zoom) |y| for (0..size * zoom) |x| {
        const s = ((y / zoom) * size + x / zoom) * 4;
        const d = ((y0 + y) * cw + x0 + x) * 4;
        const a = @as(f32, @floatFromInt(img[s + 3])) / 255;
        for (0..3) |k| {
            const src = @as(f32, @floatFromInt(img[s + k]));
            const dst = @as(f32, @floatFromInt(canvas[d + k]));
            canvas[d + k] = @intFromFloat(@round(src * a + dst * (1 - a)));
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 3 and argv.len != 4) {
        std.log.err("usage: icongen <out.ico> <preview.png> [linux-icons-dir]", .{});
        std.process.exit(2);
    }

    var rendered: [sizes.len][]u8 = undefined;
    var encoded: [sizes.len][]u8 = undefined;
    for (sizes, 0..) |size, i| {
        rendered[i] = try render(gpa, size);
        encoded[i] = if (size >= 256) try writePng(gpa, rendered[i], size, size) else try writeDib(gpa, rendered[i], size);
    }
    defer for (rendered, encoded) |r, e| {
        gpa.free(r);
        gpa.free(e);
    };

    const ico = try writeIco(gpa, &encoded);
    defer gpa.free(ico);
    const canvas, const pw, const ph = try preview(gpa, &rendered);
    defer gpa.free(canvas);
    const png = try writePng(gpa, canvas, pw, ph);
    defer gpa.free(png);

    const cwd = std.Io.Dir.cwd();
    for (argv[1..3]) |path| if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(init.io, dir);
    try cwd.writeFile(init.io, .{ .sub_path = argv[1], .data = ico });
    try cwd.writeFile(init.io, .{ .sub_path = argv[2], .data = png });
    std.log.info("wrote {s} ({d} bytes, {d} sizes) and {s}", .{ argv[1], ico.len, sizes.len, argv[2] });
    if (argv.len == 4) try writeLinux(gpa, init.io, argv[3]);
}

/// Linux: the icon theme's PNGs (`hicolor/<n>x<n>/apps/org.zmural.Settings.png`,
/// for the settings app's desktop entry) and `tray.argb`, the tray icon as
/// StatusNotifierItem wants it: for each size, a u32 width and height
/// (little-endian, for us) and the pixels as ARGB32 in network byte order.
fn writeLinux(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    for ([_]u32{ 16, 24, 32, 48, 64, 128, 256 }) |size| {
        const img = try render(gpa, size);
        defer gpa.free(img);
        const png = try writePng(gpa, img, size, size);
        defer gpa.free(png);
        var sub_buf: [128]u8 = undefined;
        const sub = try std.fmt.bufPrint(&sub_buf, "hicolor/{d}x{d}/apps", .{ size, size });
        const path_dir = try std.fs.path.join(gpa, &.{ dir, sub });
        defer gpa.free(path_dir);
        try cwd.createDirPath(io, path_dir);
        const path = try std.fs.path.join(gpa, &.{ path_dir, "org.zmural.Settings.png" });
        defer gpa.free(path);
        try cwd.writeFile(io, .{ .sub_path = path, .data = png });
    }
    var tray: std.ArrayList(u8) = .empty;
    defer tray.deinit(gpa);
    for ([_]u32{ 22, 32, 48, 64 }) |size| {
        const img = try render(gpa, size);
        defer gpa.free(img);
        try appendInt(gpa, &tray, u32, size, .little);
        try appendInt(gpa, &tray, u32, size, .little);
        var i: usize = 0;
        while (i < img.len) : (i += 4) try tray.appendSlice(gpa, &.{ img[i + 3], img[i], img[i + 1], img[i + 2] });
    }
    const tray_path = try std.fs.path.join(gpa, &.{ dir, "tray.argb" });
    defer gpa.free(tray_path);
    try cwd.writeFile(io, .{ .sub_path = tray_path, .data = tray.items });
    std.log.info("wrote the Linux icons into {s}", .{dir});
}

test "a rendered icon is opaque inside and clear at the corner" {
    const img = try render(std.testing.allocator, 32);
    defer std.testing.allocator.free(img);
    try std.testing.expectEqual(@as(u8, 255), img[(16 * 32 + 16) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 0), img[3]);
}
