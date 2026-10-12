// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The settings window's drawing on Windows: Direct2D and DirectWrite into
//! the window (over the Mica backdrop), Segoe UI Variable text and Segoe
//! Fluent Icons. The widgets on top are shared (`gui.zig`).

const std = @import("std");
const w = @import("zmural").os.win32;
const sys = @import("sys.zig");
const gui = @import("gui.zig");
const Object = sys.Object;
const Target = sys.Target;
const Rect = gui.Rect;
const Point = gui.Point;
const Color = gui.Color;
const Font = gui.Font;
const Align = gui.Align;
const Icon = gui.Icon;

/// The theme as Windows apps are set, and the user's accent colour.
/// `force_dark` overrides the Windows setting (for trying both themes).
pub fn systemTheme(force_dark: ?bool) gui.Theme {
    const light_apps = readDword(w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), w.L("AppsUseLightTheme")) orelse 1;
    var t: gui.Theme = .{ .dark = force_dark orelse (light_apps == 0) };
    // AccentPalette: 8 RGBA entries, light3 .. dark3 (index 3 is the accent itself).
    var shades: [32]u8 = undefined;
    if (readBinary(w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent"), w.L("AccentPalette"), &shades)) {
        const shade = struct {
            fn get(s: *const [32]u8, i: usize) Color {
                return .{ .r = @as(f32, @floatFromInt(s[i * 4])) / 255, .g = @as(f32, @floatFromInt(s[i * 4 + 1])) / 255, .b = @as(f32, @floatFromInt(s[i * 4 + 2])) / 255, .a = 1 };
            }
        }.get;
        t.accent_light2 = shade(&shades, 1);
        t.accent_light1 = shade(&shades, 2);
        t.accent_dark1 = shade(&shades, 4);
        t.accent_dark2 = shade(&shades, 5);
    }
    return t;
}

fn readDword(sub_key: [*:0]const u16, name: [*:0]const u16) ?u32 {
    var v: u32 = 0;
    var size: w.DWORD = @sizeOf(u32);
    if (RegGetValueW(w.HKEY_CURRENT_USER, sub_key, name, 0x10, null, &v, &size) != 0) return null; // RRF_RT_REG_DWORD
    return v;
}

fn readBinary(sub_key: [*:0]const u16, name: [*:0]const u16, out: []u8) bool {
    var size: w.DWORD = @intCast(out.len); // zsnag:ok — 32 bytes
    return RegGetValueW(w.HKEY_CURRENT_USER, sub_key, name, 0x08, null, out.ptr, &size) == 0 and size == out.len; // RRF_RT_REG_BINARY
}

extern "advapi32" fn RegGetValueW(key: w.HKEY, sub_key: [*:0]const u16, value: [*:0]const u16, flags: w.DWORD, kind: ?*w.DWORD, data: ?*anyopaque, size: ?*w.DWORD) callconv(.winapi) i32;

// Separate declarations: each UTF-16 literal gets its own comptime budget.
const family_text = w.L("Segoe UI Variable Text");
const family_small = w.L("Segoe UI Variable Small");
const family_display = w.L("Segoe UI Variable Display");
const family_icons = w.L("Segoe Fluent Icons");

const FontSpec = struct { family: [*:0]const u16, weight: u32, size: f32 };

fn fontSpec(f: Font) FontSpec {
    return switch (f) {
        .body => .{ .family = family_text, .weight = sys.FONT_WEIGHT_NORMAL, .size = 14 },
        .body_strong => .{ .family = family_text, .weight = sys.FONT_WEIGHT_SEMIBOLD, .size = 14 },
        .caption => .{ .family = family_small, .weight = sys.FONT_WEIGHT_NORMAL, .size = 12 },
        .subtitle => .{ .family = family_display, .weight = sys.FONT_WEIGHT_SEMIBOLD, .size = 20 },
        .title => .{ .family = family_display, .weight = sys.FONT_WEIGHT_SEMIBOLD, .size = 28 },
        .icon => .{ .family = family_icons, .weight = sys.FONT_WEIGHT_NORMAL, .size = 16 },
        .icon_large => .{ .family = family_icons, .weight = sys.FONT_WEIGHT_NORMAL, .size = 40 },
    };
}

/// Segoe Fluent Icons code points.
fn codepoint(i: Icon) u16 {
    return switch (i) {
        .pictures => 0xE8B9,
        .play => 0xE768,
        .pause => 0xE769,
        .previous => 0xE892,
        .next => 0xE893,
        .volume => 0xE767,
        .mute => 0xE74F,
        .settings => 0xE713,
        .pausing => 0xE916, // stopwatch
        .add => 0xE710,
        .folder => 0xE8B7,
        .open_file => 0xE8E5,
        .close => 0xE711,
        .check => 0xE73E,
        .fit => 0xE9A6, // fit page
        .power => 0xE7E8,
        .app => 0xE737, // window
        .document => 0xE8A5,
        .info => 0xE946,
        .warning => 0xE7BA,
        .reset => 0xE777, // refresh
        .rescan => 0xE72C, // Refresh
        .star => 0xE734,
        .video => 0xE714,
        .image => 0xEB9F,
        .lock => 0xE72E,
        .battery => 0xE83F,
        .remote => 0xE7F4, // monitor
        .fullscreen => 0xE740,
        .log => 0xE9F9,
        .minimize => 0xE921,
        .maximize => 0xE922,
    };
}

fn d2d(r: Rect) sys.RectF {
    return .{ .left = r.x, .top = r.y, .right = r.right(), .bottom = r.bottom() };
}

fn colorF(c: Color) sys.ColorF {
    return @bitCast(c);
}

pub const Backend = struct {
    /// A thumbnail: a Direct2D bitmap brush.
    pub const Image = Object;

    hwnd: w.HWND,
    d2d: *Object,
    dw: *Object,
    target: ?*Object = null,
    brush: ?*Object = null,
    formats: std.enums.EnumArray(Font, [3]?*Object) = .initFill(.{ null, null, null }),
    /// Mica shows through wherever nothing is drawn.
    mica: bool = false,
    dpi: f32 = 96,
    wide: [4096]u16 = undefined,
    /// A drawing error has been logged (once is enough).
    warned: bool = false,

    pub fn init(hwnd: w.HWND) !Backend {
        var factory: ?*Object = null;
        if (!sys.ok(sys.D2D1CreateFactory(0, &sys.IID_ID2D1Factory, null, &factory))) return error.NoDirect2D;
        errdefer sys.release(factory.?);
        var dw: ?*Object = null;
        if (!sys.ok(sys.DWriteCreateFactory(0, &sys.IID_IDWriteFactory, &dw))) return error.NoDirectWrite;
        var b: Backend = .{ .hwnd = hwnd, .d2d = factory.?, .dw = dw.? };
        b.dpi = @floatFromInt(sys.GetDpiForWindow(hwnd));
        for (std.enums.values(Font)) |f| {
            const spec = fontSpec(f);
            var set: [3]?*Object = undefined;
            for (0..3) |a| set[a] = sys.Write.createFormat(b.dw, spec.family, spec.weight, spec.size, switch (a) {
                0 => sys.TEXT_ALIGN_LEADING,
                1 => sys.TEXT_ALIGN_CENTER,
                else => sys.TEXT_ALIGN_TRAILING,
            });
            b.formats.set(f, set);
        }
        return b;
    }

    pub fn deinit(b: *Backend) void {
        b.dropTarget();
        for (std.enums.values(Font)) |f| for (b.formats.get(f)) |fmt| if (fmt) |x| sys.release(x);
        sys.release(b.dw);
        sys.release(b.d2d);
    }

    /// Device resources are lost with the target; the app then drops its images.
    pub fn dropTarget(b: *Backend) void {
        if (b.brush) |x| sys.release(x);
        if (b.target) |t| sys.release(t);
        b.brush = null;
        b.target = null;
    }

    fn pixelSize(b: *Backend) sys.SizeU {
        var rc: w.RECT = undefined;
        _ = w.GetClientRect(b.hwnd, &rc);
        return .{ .width = @intCast(@max(1, rc.right - rc.left)), .height = @intCast(@max(1, rc.bottom - rc.top)) }; // zsnag:ok — clamped to ≥ 1
    }

    fn ensureTarget(b: *Backend) bool {
        if (b.target != null) return true;
        const px = b.pixelSize();
        const t = sys.Factory.createHwndTarget(b.d2d, &.{}, &.{ .hwnd = b.hwnd, .size = px }) orelse return false;
        Target.setDpi(t, b.dpi);
        Target.setTextAntialias(t, 2); // grayscale: ClearType draws nothing over the transparent (Mica) background
        b.target = t;
        b.brush = Target.createSolidBrush(t, .{ .r = 0, .g = 0, .b = 0, .a = 1 }) orelse {
            b.dropTarget();
            return false;
        };
        return true;
    }

    /// A thumbnail from premultiplied BGRA pixels (top-down, `width * 4`
    /// per row). Null without a render target (it's made on the next frame).
    pub fn createImage(b: *Backend, pixels: []const u8, width: u32, height: u32) ?*Image {
        const target = b.target orelse return null;
        const bmp = Target.createBitmap(target, .{ .width = width, .height = height }, pixels.ptr, width * 4) orelse return null;
        defer sys.release(bmp);
        return Target.createBitmapBrush(target, bmp);
    }

    pub fn destroyImage(_: *Backend, img: *Image) void {
        sys.release(img);
    }

    pub fn resized(b: *Backend) void {
        if (b.target) |t| _ = Target.resize(t, b.pixelSize());
    }

    pub fn setDpi(b: *Backend, dpi: f32) void {
        b.dpi = dpi;
        if (b.target) |t| Target.setDpi(t, dpi);
    }

    /// Starts drawing; returns the client area in DIPs.
    pub fn begin(b: *Backend, background: Color) ?Point {
        if (!b.ensureTarget()) return null;
        const px = b.pixelSize();
        Target.beginDraw(b.target.?);
        Target.clear(b.target.?, if (b.mica) .{ .r = 0, .g = 0, .b = 0, .a = 0 } else colorF(background));
        return .{ .x = @as(f32, @floatFromInt(px.width)) * 96 / b.dpi, .y = @as(f32, @floatFromInt(px.height)) * 96 / b.dpi };
    }

    /// False when the device was lost (the app must drop its images).
    pub fn end(b: *Backend) bool {
        const hr = Target.endDraw(b.target.?);
        if (hr == sys.D2DERR_RECREATE_TARGET) {
            b.dropTarget();
            return false;
        }
        if (!sys.ok(hr) and !b.warned) {
            b.warned = true;
            std.log.warn("draw: EndDraw failed, 0x{X}", .{@as(u32, @bitCast(hr))});
        }
        return true;
    }

    fn paint(b: *Backend, c: Color) *Object {
        const brush = b.brush.?;
        sys.Brush.setColor(brush, colorF(c));
        return brush;
    }

    pub fn fillRect(b: *Backend, r: Rect, radius: f32, c: Color) void {
        if (radius <= 0) return Target.fillRect(b.target.?, d2d(r), b.paint(c));
        Target.fillRoundedRect(b.target.?, .{ .rect = d2d(r), .rx = radius, .ry = radius }, b.paint(c));
    }

    pub fn strokeRect(b: *Backend, r: Rect, radius: f32, c: Color, width: f32) void {
        const half = width / 2;
        Target.drawRoundedRect(b.target.?, .{ .rect = d2d(r.inset(half, half)), .rx = @max(0, radius - half), .ry = @max(0, radius - half) }, b.paint(c), width);
    }

    pub fn line(b: *Backend, p0: Point, p1: Point, c: Color, width: f32) void {
        Target.drawLine(b.target.?, .{ .x = p0.x, .y = p0.y }, .{ .x = p1.x, .y = p1.y }, b.paint(c), width);
    }

    pub fn fillCircle(b: *Backend, center: Point, radius: f32, c: Color) void {
        Target.fillEllipse(b.target.?, .{ .point = .{ .x = center.x, .y = center.y }, .rx = radius, .ry = radius }, b.paint(c));
    }

    pub fn strokeCircle(b: *Backend, center: Point, radius: f32, c: Color, width: f32) void {
        Target.drawEllipse(b.target.?, .{ .point = .{ .x = center.x, .y = center.y }, .rx = radius, .ry = radius }, b.paint(c), width);
    }

    pub fn gradient(b: *Backend, r: Rect, radius: f32, top: Color, bottom: Color) void {
        const stops = [_]sys.GradientStop{ .{ .position = 0, .color = colorF(top) }, .{ .position = 1, .color = colorF(bottom) } };
        const brush = Target.createLinearGradient(b.target.?, &stops, .{ .x = r.x, .y = r.y }, .{ .x = r.x, .y = r.bottom() }) orelse return;
        defer sys.release(brush);
        Target.fillRoundedRect(b.target.?, .{ .rect = d2d(r), .rx = radius, .ry = radius }, brush);
    }

    pub fn image(b: *Backend, r: Rect, radius: f32, bitmap_brush: *Image, bw: f32, bh: f32) void {
        const s = @max(r.w / bw, r.h / bh);
        sys.Brush.setTransform(bitmap_brush, .{ .m = .{ s, 0, 0, s, r.x + (r.w - bw * s) / 2, r.y + (r.h - bh * s) / 2 } });
        Target.fillRoundedRect(b.target.?, .{ .rect = d2d(r), .rx = radius, .ry = radius }, bitmap_brush);
    }

    fn toWide(b: *Backend, s: []const u8) []const u16 {
        return b.wide[0..toUtf16(&b.wide, s)];
    }

    pub fn text(b: *Backend, r: Rect, s: []const u8, font: Font, a: Align, c: Color) void {
        const fmt = b.formats.get(font)[@intFromEnum(a)] orelse return;
        Target.drawText(b.target.?, b.toWide(s), fmt, d2d(r), b.paint(c));
    }

    pub fn glyph(b: *Backend, r: Rect, g: Icon, font: Font, c: Color) void {
        const fmt = b.formats.get(font)[@intFromEnum(Align.center)] orelse return;
        Target.drawText(b.target.?, &.{codepoint(g)}, fmt, d2d(r), b.paint(c));
    }

    pub fn measure(b: *Backend, s: []const u8, font: Font) f32 {
        const fmt = b.formats.get(font)[0] orelse return 0;
        return sys.Write.measure(b.dw, fmt, b.toWide(s));
    }

    pub fn pushClip(b: *Backend, r: Rect) void {
        Target.pushClip(b.target.?, d2d(r));
    }

    pub fn popClip(b: *Backend) void {
        Target.popClip(b.target.?);
    }
};

/// UTF-8 (WTF-8, so unpaired surrogates from Windows names survive) to UTF-16
/// in `out`; returns the length. Anything that isn't valid shows as U+FFFD, a
/// byte at a time: text comes from wallpaper packages and hand-edited files,
/// so it must never fail. Stops at the end of `out`.
fn toUtf16(out: []u16, s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (n + 2 > out.len) break;
        var cp: u21 = std.unicode.replacement_character;
        var len: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(s[i])) |l| {
            if (i + l <= s.len) if (std.unicode.wtf8Decode(s[i..][0..l])) |c| {
                cp = c;
                len = l;
            } else |_| {};
        } else |_| {}
        i += len;
        if (cp < 0x10000) {
            out[n] = @intCast(cp); // zsnag:ok — below 0x10000
            n += 1;
        } else {
            const v = cp - 0x10000;
            out[n] = @intCast(0xD800 + (v >> 10)); // zsnag:ok — surrogate range
            out[n + 1] = @intCast(0xDC00 + (v & 0x3FF)); // zsnag:ok — surrogate range
            n += 2;
        }
    }
    return n;
}

test "toUtf16: invalid bytes show as U+FFFD instead of crashing" {
    var out: [32]u16 = undefined;
    const r = std.unicode.replacement_character;
    // Valid text, an astral character as a surrogate pair.
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xE9, 0xD83D, 0xDE00 }, out[0..toUtf16(&out, "a\u{e9}\u{1f600}")]);
    // A stray continuation byte, a Latin-1 é (ANSI-saved file), a cut-off sequence, an overlong.
    try std.testing.expectEqualSlices(u16, &.{ 'x', r, 'y' }, out[0..toUtf16(&out, "x\x80y")]);
    try std.testing.expectEqualSlices(u16, &.{ 'c', 'a', 'f', r }, out[0..toUtf16(&out, "caf\xe9")]);
    try std.testing.expectEqualSlices(u16, &.{ 'z', r, r }, out[0..toUtf16(&out, "z\xe2\x82")]);
    try std.testing.expectEqualSlices(u16, &.{ r, r }, out[0..toUtf16(&out, "\xc0\xaf")]);
    // An unpaired surrogate (WTF-8) is kept, as Windows names can have them.
    try std.testing.expectEqualSlices(u16, &.{0xD800}, out[0..toUtf16(&out, "\xed\xa0\x80")]);
    // Stops at the end of the buffer.
    var small: [3]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), toUtf16(&small, "abcd"));
}
