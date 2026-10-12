// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The settings window's drawing on Linux: Cairo for shapes and images,
//! Pango for text, into a buffer the platform hands over each frame (a
//! wl_shm buffer). The widgets on top are shared (`gui.zig`).
//!
//! libcairo, libpango, libpangocairo, libgobject and libfontconfig are
//! loaded at runtime (every Linux desktop has them; zmural needs no
//! development files to build). Icons come from a subset of Microsoft's
//! Fluent UI System Icons (MIT, `assets/fonts/`), embedded in the program:
//! the same design family as Windows 11's Segoe Fluent Icons.

const std = @import("std");
const linux = std.os.linux;
const gui = @import("gui.zig");
const Rect = gui.Rect;
const Point = gui.Point;
const Color = gui.Color;
const Font = gui.Font;
const Align = gui.Align;
const Icon = gui.Icon;

const icon_font = @embedFile("icons.ttf");
const icon_family = "FluentSystemIcons-Regular";

/// Fluent UI System Icons code points (20 px regular set).
fn codepoint(i: Icon) u21 {
    return switch (i) {
        .pictures => 0xE725, // image_multiple
        .play => 0xF605,
        .pause => 0xF5A1,
        .previous => 0xF628,
        .next => 0xF569,
        .volume => 0xEB42, // speaker_2
        .mute => 0xEB4A, // speaker_mute
        .settings => 0xF6A9,
        .pausing => 0xED88, // timer
        .add => 0xF109,
        .folder => 0xF418,
        .open_file => 0xF42E, // folder_open
        .close => 0xF369, // dismiss
        .check => 0xF294, // checkmark
        .fit => 0xE0CD, // arrow_fit
        .power => 0xF60E,
        .app => 0xF8B5, // window
        .document => 0xF378,
        .info => 0xF4A3,
        .warning => 0xF869,
        .reset => 0xF19F, // arrow_reset
        .rescan => 0xF19F, // arrow_reset: the subset has no arrow_sync
        .star => 0xF70F,
        .video => 0xF84C,
        .image => 0xF488,
        .lock => 0xE78F, // lock_closed
        .battery => 0xF1C7, // battery_6
        .remote => 0xF359, // desktop
        .fullscreen => 0xE684, // full_screen_maximize
        .log => 0xE557, // document_text
        .minimize => 0xEBD0, // subtract
        .maximize => 0xEB75, // square
    };
}

const Surface = opaque {};
const Cr = opaque {};
const Pattern = opaque {};
const Layout = opaque {};
const FontDesc = opaque {};

const pango_scale = 1024;

const CairoApi = struct {
    image_surface_create: *const fn (c_int, c_int, c_int) callconv(.c) ?*Surface,
    image_surface_create_for_data: *const fn ([*]u8, c_int, c_int, c_int, c_int) callconv(.c) ?*Surface,
    image_surface_get_data: *const fn (*Surface) callconv(.c) ?[*]u8,
    image_surface_get_stride: *const fn (*Surface) callconv(.c) c_int,
    surface_flush: *const fn (*Surface) callconv(.c) void,
    surface_mark_dirty: *const fn (*Surface) callconv(.c) void,
    surface_destroy: *const fn (*Surface) callconv(.c) void,
    surface_status: *const fn (*Surface) callconv(.c) c_int,
    image_surface_create_from_png: *const fn ([*:0]const u8) callconv(.c) ?*Surface,
    image_surface_get_width: *const fn (*Surface) callconv(.c) c_int,
    image_surface_get_height: *const fn (*Surface) callconv(.c) c_int,
    create: *const fn (*Surface) callconv(.c) ?*Cr,
    destroy: *const fn (*Cr) callconv(.c) void,
    save: *const fn (*Cr) callconv(.c) void,
    restore: *const fn (*Cr) callconv(.c) void,
    scale: *const fn (*Cr, f64, f64) callconv(.c) void,
    translate: *const fn (*Cr, f64, f64) callconv(.c) void,
    set_operator: *const fn (*Cr, c_int) callconv(.c) void,
    set_source_rgba: *const fn (*Cr, f64, f64, f64, f64) callconv(.c) void,
    set_source: *const fn (*Cr, *Pattern) callconv(.c) void,
    set_source_surface: *const fn (*Cr, *Surface, f64, f64) callconv(.c) void,
    set_line_width: *const fn (*Cr, f64) callconv(.c) void,
    new_path: *const fn (*Cr) callconv(.c) void,
    new_sub_path: *const fn (*Cr) callconv(.c) void,
    close_path: *const fn (*Cr) callconv(.c) void,
    rectangle: *const fn (*Cr, f64, f64, f64, f64) callconv(.c) void,
    arc: *const fn (*Cr, f64, f64, f64, f64, f64) callconv(.c) void,
    move_to: *const fn (*Cr, f64, f64) callconv(.c) void,
    line_to: *const fn (*Cr, f64, f64) callconv(.c) void,
    fill: *const fn (*Cr) callconv(.c) void,
    stroke: *const fn (*Cr) callconv(.c) void,
    clip: *const fn (*Cr) callconv(.c) void,
    paint: *const fn (*Cr) callconv(.c) void,
    pattern_create_linear: *const fn (f64, f64, f64, f64) callconv(.c) ?*Pattern,
    pattern_add_color_stop_rgba: *const fn (*Pattern, f64, f64, f64, f64, f64) callconv(.c) void,
    pattern_destroy: *const fn (*Pattern) callconv(.c) void,
};

const PangoApi = struct {
    font_description_new: *const fn () callconv(.c) ?*FontDesc,
    font_description_free: *const fn (*FontDesc) callconv(.c) void,
    font_description_set_family: *const fn (*FontDesc, [*:0]const u8) callconv(.c) void,
    font_description_set_weight: *const fn (*FontDesc, c_int) callconv(.c) void,
    font_description_set_absolute_size: *const fn (*FontDesc, f64) callconv(.c) void,
    layout_set_text: *const fn (*Layout, [*]const u8, c_int) callconv(.c) void,
    layout_set_font_description: *const fn (*Layout, ?*FontDesc) callconv(.c) void,
    layout_set_width: *const fn (*Layout, c_int) callconv(.c) void,
    layout_set_ellipsize: *const fn (*Layout, c_int) callconv(.c) void,
    layout_set_alignment: *const fn (*Layout, c_int) callconv(.c) void,
    layout_set_single_paragraph_mode: *const fn (*Layout, c_int) callconv(.c) void,
    layout_get_pixel_size: *const fn (*Layout, *c_int, *c_int) callconv(.c) void,
};

const PangoCairoApi = struct {
    create_layout: *const fn (*Cr) callconv(.c) ?*Layout,
    update_layout: *const fn (*Cr, *Layout) callconv(.c) void,
    show_layout: *const fn (*Cr, *Layout) callconv(.c) void,
};

const Libs = struct {
    cairo: CairoApi,
    pango: PangoApi,
    pc: PangoCairoApi,
    object_unref: *const fn (*anyopaque) callconv(.c) void,
    handles: [5]std.DynLib,
};

fn loadTable(comptime T: type, lib: *std.DynLib, comptime prefix: []const u8) !T {
    var t: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        @field(t, f.name) = lib.lookup(f.type, prefix ++ f.name) orelse {
            std.log.err("{s}{s} is missing", .{ prefix, f.name });
            return error.SymbolMissing;
        };
    }
    return t;
}

/// Loaded for the first window and kept for the life of the process. They
/// are never unloaded: GLib registers per-thread cleanup that runs when the
/// window's thread ends, and unloading first crashes zmural there.
var loaded: ?Libs = null;

fn loadLibs(runtime_dir: []const u8) !Libs {
    if (loaded) |libs| return libs;
    var cairo_lib = std.DynLib.open("libcairo.so.2") catch return error.NoCairo;
    var pango_lib = std.DynLib.open("libpango-1.0.so.0") catch return error.NoPango;
    var pc_lib = std.DynLib.open("libpangocairo-1.0.so.0") catch return error.NoPango;
    var gobject_lib = std.DynLib.open("libgobject-2.0.so.0") catch return error.NoGObject;
    var fc_lib = std.DynLib.open("libfontconfig.so.1") catch return error.NoFontconfig;
    const libs: Libs = .{
        .cairo = try loadTable(CairoApi, &cairo_lib, "cairo_"),
        .pango = try loadTable(PangoApi, &pango_lib, "pango_"),
        .pc = try loadTable(PangoCairoApi, &pc_lib, "pango_cairo_"),
        .object_unref = gobject_lib.lookup(*const fn (*anyopaque) callconv(.c) void, "g_object_unref") orelse return error.SymbolMissing,
        .handles = .{ cairo_lib, pango_lib, pc_lib, gobject_lib, fc_lib },
    };
    // The icon font, from the program itself: written next to zmural's
    // sockets and handed to fontconfig, which Pango asks for fonts.
    const add_font = fc_lib.lookup(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) c_int, "FcConfigAppFontAddFile") orelse return error.SymbolMissing;
    if (iconFontPath(runtime_dir)) |path| {
        if (add_font(null, path) == 0) std.log.warn("icons: fontconfig refused {s}", .{path});
    } else std.log.warn("icons: can't write the icon font; icons won't show", .{});
    loaded = libs;
    return libs;
}

var icon_path_buf: [256:0]u8 = undefined;

fn iconFontPath(dir: []const u8) ?[*:0]const u8 {
    const path = std.fmt.bufPrintSentinel(&icon_path_buf, "{s}/zmural-icons-{d}.ttf", .{ dir, linux.getuid() }, 0) catch return null;
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var off: usize = 0;
    while (off < icon_font.len) {
        const n = linux.write(fd, icon_font[off..].ptr, icon_font.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return null;
        off += n;
    }
    return path.ptr;
}

pub const Backend = struct {
    /// A thumbnail: a Cairo image surface.
    pub const Image = Surface;

    libs: Libs,
    fonts: std.enums.EnumArray(Font, ?*FontDesc) = .initFill(null),
    /// The frame's target (set by the platform before `begin`).
    target: ?*Surface = null,
    cr: ?*Cr = null,
    layout: ?*Layout = null,
    /// Buffer pixels per DIP.
    scale: f32 = 1,
    width_px: u32 = 0,
    height_px: u32 = 0,
    /// `s` made valid for Pango (`validUtf8`).
    text_buf: [4096]u8 = undefined,

    /// `runtime_dir` is where the icon font is unpacked for fontconfig.
    pub fn init(runtime_dir: []const u8) !Backend {
        var b: Backend = .{ .libs = try loadLibs(runtime_dir) };
        const p = &b.libs.pango;
        for (std.enums.values(Font)) |f| {
            const d = p.font_description_new() orelse return error.NoPango;
            const spec: struct { family: [*:0]const u8, weight: c_int, size: f64 } = switch (f) {
                .body => .{ .family = "sans-serif", .weight = 400, .size = 14 },
                .body_strong => .{ .family = "sans-serif", .weight = 600, .size = 14 },
                .caption => .{ .family = "sans-serif", .weight = 400, .size = 12 },
                .subtitle => .{ .family = "sans-serif", .weight = 600, .size = 20 },
                .title => .{ .family = "sans-serif", .weight = 600, .size = 28 },
                .icon => .{ .family = icon_family, .weight = 400, .size = 16 },
                .icon_large => .{ .family = icon_family, .weight = 400, .size = 40 },
            };
            p.font_description_set_family(d, spec.family);
            p.font_description_set_weight(d, spec.weight);
            p.font_description_set_absolute_size(d, spec.size * pango_scale);
            b.fonts.set(f, d);
        }
        return b;
    }

    pub fn deinit(b: *Backend) void {
        for (std.enums.values(Font)) |f| if (b.fonts.get(f)) |d| b.libs.pango.font_description_free(d);
    }

    /// The buffer the next frame draws into: premultiplied ARGB32 (Cairo's
    /// format, which is also wl_shm's ARGB8888 on little-endian).
    pub fn setTarget(b: *Backend, pixels: [*]u8, width: u32, height: u32, stride: u32, scale: f32) void {
        if (b.target) |t| b.libs.cairo.surface_destroy(t);
        b.target = b.libs.cairo.image_surface_create_for_data(pixels, 0, @intCast(width), @intCast(height), @intCast(stride));
        b.width_px = width;
        b.height_px = height;
        b.scale = scale;
    }

    pub fn begin(b: *Backend, background: Color) ?Point {
        const c = &b.libs.cairo;
        const target = b.target orelse return null;
        const cr = c.create(target) orelse return null;
        b.cr = cr;
        c.set_operator(cr, 1); // SOURCE: replace what was there
        setColor(c, cr, background);
        c.paint(cr);
        c.set_operator(cr, 2); // OVER
        c.scale(cr, b.scale, b.scale);
        b.layout = b.libs.pc.create_layout(cr);
        return .{ .x = @as(f32, @floatFromInt(b.width_px)) / b.scale, .y = @as(f32, @floatFromInt(b.height_px)) / b.scale };
    }

    pub fn end(b: *Backend) bool {
        if (b.layout) |l| b.libs.object_unref(l);
        b.layout = null;
        if (b.cr) |cr| b.libs.cairo.destroy(cr);
        b.cr = null;
        if (b.target) |t| b.libs.cairo.surface_flush(t);
        return true;
    }

    fn setColor(c: *const CairoApi, cr: *Cr, col: Color) void {
        c.set_source_rgba(cr, col.r, col.g, col.b, col.a);
    }

    fn roundedPath(b: *Backend, r: Rect, radius: f32) void {
        const c = &b.libs.cairo;
        const cr = b.cr.?;
        c.new_path(cr);
        const rad = @min(radius, @min(r.w, r.h) / 2);
        if (rad <= 0) {
            c.rectangle(cr, r.x, r.y, r.w, r.h);
            return;
        }
        const pi = std.math.pi;
        c.new_sub_path(cr);
        c.arc(cr, r.right() - rad, r.y + rad, rad, -pi / 2.0, 0);
        c.arc(cr, r.right() - rad, r.bottom() - rad, rad, 0, pi / 2.0);
        c.arc(cr, r.x + rad, r.bottom() - rad, rad, pi / 2.0, pi);
        c.arc(cr, r.x + rad, r.y + rad, rad, pi, 3 * pi / 2.0);
        c.close_path(cr);
    }

    pub fn fillRect(b: *Backend, r: Rect, radius: f32, col: Color) void {
        b.roundedPath(r, radius);
        setColor(&b.libs.cairo, b.cr.?, col);
        b.libs.cairo.fill(b.cr.?);
    }

    pub fn strokeRect(b: *Backend, r: Rect, radius: f32, col: Color, width: f32) void {
        const half = width / 2;
        b.roundedPath(r.inset(half, half), @max(0, radius - half));
        setColor(&b.libs.cairo, b.cr.?, col);
        b.libs.cairo.set_line_width(b.cr.?, width);
        b.libs.cairo.stroke(b.cr.?);
    }

    pub fn line(b: *Backend, p0: Point, p1: Point, col: Color, width: f32) void {
        const c = &b.libs.cairo;
        const cr = b.cr.?;
        c.new_path(cr);
        c.move_to(cr, p0.x, p0.y);
        c.line_to(cr, p1.x, p1.y);
        setColor(c, cr, col);
        c.set_line_width(cr, width);
        c.stroke(cr);
    }

    pub fn fillCircle(b: *Backend, center: Point, radius: f32, col: Color) void {
        const c = &b.libs.cairo;
        const cr = b.cr.?;
        c.new_path(cr);
        c.arc(cr, center.x, center.y, radius, 0, 2 * std.math.pi);
        setColor(c, cr, col);
        c.fill(cr);
    }

    pub fn strokeCircle(b: *Backend, center: Point, radius: f32, col: Color, width: f32) void {
        const c = &b.libs.cairo;
        const cr = b.cr.?;
        c.new_path(cr);
        c.arc(cr, center.x, center.y, radius, 0, 2 * std.math.pi);
        setColor(c, cr, col);
        c.set_line_width(cr, width);
        c.stroke(cr);
    }

    pub fn gradient(b: *Backend, r: Rect, radius: f32, top: Color, bottom: Color) void {
        const c = &b.libs.cairo;
        const pat = c.pattern_create_linear(r.x, r.y, r.x, r.bottom()) orelse return;
        defer c.pattern_destroy(pat);
        c.pattern_add_color_stop_rgba(pat, 0, top.r, top.g, top.b, top.a);
        c.pattern_add_color_stop_rgba(pat, 1, bottom.r, bottom.g, bottom.b, bottom.a);
        b.roundedPath(r, radius);
        c.set_source(b.cr.?, pat);
        c.fill(b.cr.?);
    }

    /// A thumbnail from premultiplied BGRA pixels (top-down, `width * 4` per row).
    pub fn createImage(b: *Backend, pixels: []const u8, width: u32, height: u32) ?*Image {
        const c = &b.libs.cairo;
        const s = c.image_surface_create(0, @intCast(width), @intCast(height)) orelse return null;
        const data = c.image_surface_get_data(s) orelse {
            c.surface_destroy(s);
            return null;
        };
        const stride: usize = @intCast(c.image_surface_get_stride(s));
        for (0..height) |y| @memcpy(data[y * stride ..][0 .. width * 4], pixels[y * width * 4 ..][0 .. width * 4]);
        c.surface_mark_dirty(s);
        return s;
    }

    pub const Loaded = struct { img: *Image, width: u32, height: u32 };

    /// A PNG file as a thumbnail, scaled so its longer side is at most `max_px`.
    pub fn loadThumb(b: *Backend, path: [:0]const u8, max_px: u32) ?Loaded {
        const c = &b.libs.cairo;
        const full = c.image_surface_create_from_png(path) orelse return null;
        defer c.surface_destroy(full);
        if (c.surface_status(full) != 0) return null;
        const fw: f32 = @floatFromInt(c.image_surface_get_width(full));
        const fh: f32 = @floatFromInt(c.image_surface_get_height(full));
        if (fw < 1 or fh < 1) return null;
        const s = @min(1, @as(f32, @floatFromInt(max_px)) / @max(fw, fh));
        const tw: u32 = @intFromFloat(@max(1, @round(fw * s)));
        const th: u32 = @intFromFloat(@max(1, @round(fh * s)));
        const thumb = c.image_surface_create(0, @intCast(tw), @intCast(th)) orelse return null;
        const cr = c.create(thumb) orelse {
            c.surface_destroy(thumb);
            return null;
        };
        defer c.destroy(cr);
        c.scale(cr, s, s);
        c.set_source_surface(cr, full, 0, 0);
        c.paint(cr);
        return .{ .img = thumb, .width = tw, .height = th };
    }

    pub fn destroyImage(b: *Backend, img: *Image) void {
        b.libs.cairo.surface_destroy(img);
    }

    pub fn image(b: *Backend, r: Rect, radius: f32, img: *Image, iw: f32, ih: f32) void {
        const c = &b.libs.cairo;
        const cr = b.cr.?;
        c.save(cr);
        b.roundedPath(r, radius);
        c.clip(cr);
        const s = @max(r.w / iw, r.h / ih);
        c.translate(cr, r.x + (r.w - iw * s) / 2, r.y + (r.h - ih * s) / 2);
        c.scale(cr, s, s);
        c.set_source_surface(cr, img, 0, 0);
        c.paint(cr);
        c.restore(cr);
    }

    /// Lays `s` out in one line, centred vertically in `r`, cut with "…".
    fn drawLayout(b: *Backend, r: Rect, s: []const u8, font: Font, a: Align, col: Color) void {
        const p = &b.libs.pango;
        const c = &b.libs.cairo;
        const cr = b.cr.?;
        const l = b.layout orelse return;
        p.layout_set_font_description(l, b.fonts.get(font));
        p.layout_set_single_paragraph_mode(l, 1);
        const t = validUtf8(&b.text_buf, s);
        p.layout_set_text(l, t.ptr, @intCast(t.len));
        p.layout_set_width(l, @intFromFloat(@max(0, r.w) * pango_scale));
        p.layout_set_ellipsize(l, 3); // PANGO_ELLIPSIZE_END
        p.layout_set_alignment(l, switch (a) {
            .left => 0,
            .center => 1,
            .right => 2,
        });
        var tw: c_int = 0;
        var th: c_int = 0;
        p.layout_get_pixel_size(l, &tw, &th);
        c.save(cr);
        c.rectangle(cr, r.x, r.y, r.w, r.h);
        c.clip(cr);
        c.move_to(cr, r.x, r.y + (r.h - @as(f32, @floatFromInt(th))) / 2);
        setColor(c, cr, col);
        b.libs.pc.show_layout(cr, l);
        c.restore(cr);
    }

    pub fn text(b: *Backend, r: Rect, s: []const u8, font: Font, a: Align, col: Color) void {
        b.drawLayout(r, s, font, a, col);
    }

    pub fn glyph(b: *Backend, r: Rect, g: Icon, font: Font, col: Color) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(codepoint(g), &buf) catch return;
        b.drawLayout(r, buf[0..n], font, .center, col);
    }

    pub fn measure(b: *Backend, s: []const u8, font: Font) f32 {
        const p = &b.libs.pango;
        const l = b.layout orelse return 0;
        p.layout_set_font_description(l, b.fonts.get(font));
        p.layout_set_width(l, -1);
        p.layout_set_ellipsize(l, 0);
        const t = validUtf8(&b.text_buf, s);
        p.layout_set_text(l, t.ptr, @intCast(t.len));
        var tw: c_int = 0;
        var th: c_int = 0;
        p.layout_get_pixel_size(l, &tw, &th);
        return @floatFromInt(tw);
    }

    pub fn pushClip(b: *Backend, r: Rect) void {
        const c = &b.libs.cairo;
        c.save(b.cr.?);
        c.rectangle(b.cr.?, r.x, r.y, r.w, r.h);
        c.clip(b.cr.?);
    }

    pub fn popClip(b: *Backend) void {
        b.libs.cairo.restore(b.cr.?);
    }
};

/// `s` as valid UTF-8 for Pango, in `out` when it needs mending: anything that
/// isn't valid shows as U+FFFD, a byte at a time, as on Windows (`gui_d2d.zig`
/// toUtf16). File names on Linux are bytes, not text; Pango would draw a box
/// for each bad byte and warn on stderr every frame. Stops at the end of `out`.
fn validUtf8(out: []u8, s: []const u8) []const u8 {
    if (s.len <= out.len and std.unicode.utf8ValidateSlice(s)) return s;
    const bad = &std.unicode.replacement_character_utf8;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        var piece: []const u8 = bad;
        var len: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(s[i])) |l| {
            if (i + l <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..l])) {
                piece = s[i..][0..l];
                len = l;
            }
        } else |_| {}
        if (n + piece.len > out.len) break;
        @memcpy(out[n..][0..piece.len], piece);
        n += piece.len;
        i += len;
    }
    return out[0..n];
}

test "validUtf8: invalid bytes show as U+FFFD, valid text passes untouched" {
    var out: [32]u8 = undefined;
    const ok = "a\u{e9}\u{1f600}";
    try std.testing.expectEqual(@as([*]const u8, ok.ptr), validUtf8(&out, ok).ptr);
    // A stray continuation byte, a Latin-1 é, a cut-off sequence, an overlong, a surrogate.
    try std.testing.expectEqualStrings("x\u{fffd}y", validUtf8(&out, "x\x80y"));
    try std.testing.expectEqualStrings("caf\u{fffd}", validUtf8(&out, "caf\xe9"));
    try std.testing.expectEqualStrings("z\u{fffd}\u{fffd}", validUtf8(&out, "z\xe2\x82"));
    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}", validUtf8(&out, "\xc0\xaf"));
    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}\u{fffd}", validUtf8(&out, "\xed\xa0\x80"));
    // Too long for the buffer: cut at a character, still valid.
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("a\u{e9}", validUtf8(&small, "a\u{e9}\u{e9}\u{e9}"));
    try std.testing.expectEqualStrings("\u{fffd}", validUtf8(&small, "\xff\xff"));
}
