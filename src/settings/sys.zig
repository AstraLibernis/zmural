// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The Win32 surface only the settings window uses, declared by hand like
//! `os/win32.zig`: extra user32/gdi32 calls, DWM (Mica), COM, Direct2D,
//! DirectWrite, the shell file dialog and shell thumbnails.
//!
//! COM interfaces are called through their vtables by index. The indices
//! follow the declaration order in the Windows SDK headers (d2d1.h,
//! dwrite.h, shobjidl_core.h); each one is noted where it's used.

const std = @import("std");
const w = @import("zmural").os.win32;

pub const HRESULT = i32;
pub const HBITMAP = *opaque {};

pub fn ok(hr: HRESULT) bool {
    return hr >= 0;
}

// ---- user32 / gdi32 extras -----------------------------------------------------

pub const WM_SIZE: w.UINT = 0x0005;
pub const WM_ACTIVATE: w.UINT = 0x0006;
pub const WM_SETTINGCHANGE: w.UINT = 0x001A;
pub const WM_SETCURSOR: w.UINT = 0x0020;
pub const WM_GETMINMAXINFO: w.UINT = 0x0024;
pub const WM_KEYDOWN: w.UINT = 0x0100;
pub extern "user32" fn GetKeyState(vk: c_int) callconv(.winapi) i16;
pub const WM_MOUSEMOVE: w.UINT = 0x0200;
pub const WM_LBUTTONDOWN: w.UINT = 0x0201;
pub const WM_LBUTTONUP: w.UINT = 0x0202;
pub const WM_RBUTTONUP: w.UINT = 0x0205;
pub const WM_MOUSEWHEEL: w.UINT = 0x020A;
pub const WM_MOUSELEAVE: w.UINT = 0x02A3;
pub const WM_DPICHANGED: w.UINT = 0x02E0;
pub const WM_CAPTURECHANGED: w.UINT = 0x0215;
pub const WM_THEMECHANGED: w.UINT = 0x031A;

pub const VK_ESCAPE: w.WPARAM = 0x1B;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const WS_OVERLAPPEDWINDOW: w.DWORD = 0x00CF0000;
pub const SW_SHOW: c_int = 5;
pub const SW_RESTORE: c_int = 9;
pub const IDC_ARROW: usize = 32512;
pub const TME_LEAVE: w.DWORD = 0x2;
pub const MF_STRING: w.UINT = 0x0;
pub const TPM_RETURNCMD: w.UINT = 0x0100;
pub const TPM_RIGHTBUTTON: w.UINT = 0x0002;

pub const MINMAXINFO = extern struct {
    ptReserved: w.POINT,
    ptMaxSize: w.POINT,
    ptMaxPosition: w.POINT,
    ptMinTrackSize: w.POINT,
    ptMaxTrackSize: w.POINT,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: w.DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: w.DWORD,
    hwndTrack: w.HWND,
    dwHoverTime: w.DWORD = 0,
};

pub extern "user32" fn GetDpiForWindow(hwnd: w.HWND) callconv(.winapi) w.UINT;
pub extern "user32" fn LoadCursorW(instance: ?w.HINSTANCE, name: usize) callconv(.winapi) ?w.HCURSOR;
pub extern "user32" fn LoadIconW(instance: ?w.HINSTANCE, name: usize) callconv(.winapi) ?w.HICON;
pub extern "user32" fn SetCursor(cursor: ?w.HCURSOR) callconv(.winapi) ?w.HCURSOR;
pub extern "user32" fn SetCapture(hwnd: w.HWND) callconv(.winapi) ?w.HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) w.BOOL;
pub extern "user32" fn TrackMouseEvent(tme: *TRACKMOUSEEVENT) callconv(.winapi) w.BOOL;
pub extern "user32" fn ValidateRect(hwnd: w.HWND, rect: ?*const w.RECT) callconv(.winapi) w.BOOL;
pub extern "user32" fn ClientToScreen(hwnd: w.HWND, point: *w.POINT) callconv(.winapi) w.BOOL;
pub extern "user32" fn GetDC(hwnd: ?w.HWND) callconv(.winapi) ?w.HDC;
pub extern "user32" fn ReleaseDC(hwnd: ?w.HWND, hdc: w.HDC) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowRect(hwnd: w.HWND, rect: *w.RECT) callconv(.winapi) w.BOOL;
pub extern "user32" fn IsIconic(hwnd: w.HWND) callconv(.winapi) w.BOOL;
pub extern "user32" fn CreatePopupMenu() callconv(.winapi) ?w.HMENU;
pub extern "user32" fn AppendMenuW(menu: w.HMENU, flags: w.UINT, id: usize, text: ?[*:0]const u16) callconv(.winapi) w.BOOL;
pub extern "user32" fn DestroyMenu(menu: w.HMENU) callconv(.winapi) w.BOOL;
pub extern "user32" fn TrackPopupMenuEx(menu: w.HMENU, flags: w.UINT, x: c_int, y: c_int, hwnd: w.HWND, params: ?*anyopaque) callconv(.winapi) w.BOOL;

pub const BITMAP = extern struct {
    bmType: i32,
    bmWidth: i32,
    bmHeight: i32,
    bmWidthBytes: i32,
    bmPlanes: u16,
    bmBitsPixel: u16,
    bmBits: ?*anyopaque,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0, // BI_RGB
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};

pub extern "gdi32" fn GetObjectW(obj: *anyopaque, size: c_int, out: ?*anyopaque) callconv(.winapi) c_int;
pub extern "gdi32" fn GetDIBits(hdc: w.HDC, bitmap: HBITMAP, start: w.UINT, lines: w.UINT, bits: ?*anyopaque, info: *BITMAPINFO, usage: w.UINT) callconv(.winapi) c_int;

// ---- DWM: dark title bar and the Mica backdrop ---------------------------------

pub const DWMWA_USE_IMMERSIVE_DARK_MODE: w.DWORD = 20;
pub const DWMWA_WINDOW_CORNER_PREFERENCE: w.DWORD = 33;
pub const DWMWA_SYSTEMBACKDROP_TYPE: w.DWORD = 38;
pub const DWMSBT_MAINWINDOW: w.DWORD = 2; // Mica

pub const MARGINS = extern struct { left: i32, right: i32, top: i32, bottom: i32 };

pub extern "dwmapi" fn DwmSetWindowAttribute(hwnd: w.HWND, attr: w.DWORD, value: *const anyopaque, size: w.DWORD) callconv(.winapi) HRESULT;
pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(hwnd: w.HWND, margins: *const MARGINS) callconv(.winapi) HRESULT;

// ---- COM -----------------------------------------------------------------------

pub const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,

    pub fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(10_000);
        const hex = struct {
            fn n(comptime t: []const u8) u64 {
                return std.fmt.parseInt(u64, t, 16) catch unreachable; // zsnag:ok — comptime literal
            }
        }.n;
        var d: [8]u8 = undefined;
        d[0] = @intCast(hex(s[19..21]));
        d[1] = @intCast(hex(s[21..23]));
        for (0..6) |i| d[2 + i] = @intCast(hex(s[24 + 2 * i ..][0..2]));
        return .{ .a = @intCast(hex(s[0..8])), .b = @intCast(hex(s[9..13])), .c = @intCast(hex(s[14..18])), .d = d };
    }
};

/// Any COM object: a pointer to its vtable.
pub const Object = extern struct {
    vtbl: [*]const *const anyopaque,
};

/// The vtable entry `index` of `obj`, typed as `F` (whose first parameter is the object).
pub fn method(obj: anytype, comptime index: usize, comptime F: type) *const F {
    return @ptrCast(obj.vtbl[index]);
}

/// IUnknown::Release (2).
pub fn release(obj: anytype) void {
    _ = method(obj, 2, fn (*anyopaque) callconv(.winapi) u32)(obj);
}

pub const COINIT_APARTMENTTHREADED: w.DWORD = 0x2;
pub const COINIT_DISABLE_OLE1DDE: w.DWORD = 0x4;
pub const CLSCTX_INPROC_SERVER: w.DWORD = 0x1;

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: w.DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: w.DWORD, iid: *const GUID, out: *?*Object) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;

// ---- shell: file dialogs and thumbnails ---------------------------------------

pub const CLSID_FileOpenDialog = GUID.parse("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7");
pub const IID_IFileOpenDialog = GUID.parse("d57c7288-d4ad-4768-be02-9d969532d960");
pub const IID_IShellItemImageFactory = GUID.parse("bcc18b79-ba16-442f-80c4-8a59c30c463b");

pub const FOS_PICKFOLDERS: w.DWORD = 0x20;
pub const FOS_FORCEFILESYSTEM: w.DWORD = 0x40;
pub const FOS_PATHMUSTEXIST: w.DWORD = 0x800;
pub const FOS_FILEMUSTEXIST: w.DWORD = 0x1000;
pub const SIGDN_FILESYSPATH: u32 = 0x80058000;
pub const SIIGBF_BIGGERSIZEOK: u32 = 0x1;
pub const SIIGBF_THUMBNAILONLY: u32 = 0x8;

pub const FilterSpec = extern struct { name: [*:0]const u16, spec: [*:0]const u16 };
pub const SIZE = extern struct { cx: i32, cy: i32 };

pub extern "shell32" fn SHCreateItemFromParsingName(path: [*:0]const u16, ctx: ?*anyopaque, iid: *const GUID, out: *?*Object) callconv(.winapi) HRESULT;

/// Runs a modal Open dialog: a folder (`folders`) or a file matching
/// `filters`. Returns the chosen path in WTF-8, or null if cancelled.
pub fn pickPath(gpa: std.mem.Allocator, owner: w.HWND, title: [*:0]const u16, folders: bool, filters: []const FilterSpec) ?[]u8 {
    var dlg_obj: ?*Object = null;
    if (!ok(CoCreateInstance(&CLSID_FileOpenDialog, null, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, &dlg_obj))) return null;
    const dlg = dlg_obj.?;
    defer release(dlg);
    // IFileDialog: SetOptions (9), GetOptions (10), SetFileTypes (4), SetTitle (17), Show (3), GetResult (20).
    var opts: w.DWORD = 0;
    _ = method(dlg, 10, fn (*Object, *w.DWORD) callconv(.winapi) HRESULT)(dlg, &opts);
    opts |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | (if (folders) FOS_PICKFOLDERS else FOS_FILEMUSTEXIST);
    _ = method(dlg, 9, fn (*Object, w.DWORD) callconv(.winapi) HRESULT)(dlg, opts);
    if (filters.len > 0)
        _ = method(dlg, 4, fn (*Object, w.UINT, [*]const FilterSpec) callconv(.winapi) HRESULT)(dlg, @intCast(filters.len), filters.ptr); // zsnag:ok — a handful of filters
    _ = method(dlg, 17, fn (*Object, [*:0]const u16) callconv(.winapi) HRESULT)(dlg, title);
    if (!ok(method(dlg, 3, fn (*Object, ?w.HWND) callconv(.winapi) HRESULT)(dlg, owner))) return null; // cancelled
    var item_obj: ?*Object = null;
    if (!ok(method(dlg, 20, fn (*Object, *?*Object) callconv(.winapi) HRESULT)(dlg, &item_obj))) return null;
    const item = item_obj.?;
    defer release(item);
    // IShellItem::GetDisplayName (5).
    var name: ?[*:0]u16 = null;
    if (!ok(method(item, 5, fn (*Object, u32, *?[*:0]u16) callconv(.winapi) HRESULT)(item, SIGDN_FILESYSPATH, &name))) return null;
    defer CoTaskMemFree(name);
    return std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(name.?)) catch null;
}

// ---- Direct2D ------------------------------------------------------------------

pub const IID_ID2D1Factory = GUID.parse("06152247-6f50-465a-9245-118bfd3b6007");
pub const D2DERR_RECREATE_TARGET: HRESULT = @bitCast(@as(u32, 0x8899000C));

pub const ColorF = extern struct { r: f32, g: f32, b: f32, a: f32 };
pub const Point2F = extern struct { x: f32, y: f32 };
pub const RectF = extern struct { left: f32, top: f32, right: f32, bottom: f32 };
pub const RoundedRect = extern struct { rect: RectF, rx: f32, ry: f32 };
pub const Ellipse = extern struct { point: Point2F, rx: f32, ry: f32 };
pub const SizeU = extern struct { width: u32, height: u32 };
pub const Matrix = extern struct { m: [6]f32 = .{ 1, 0, 0, 1, 0, 0 } };

pub const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
pub const ALPHA_PREMULTIPLIED: u32 = 1;
pub const PixelFormat = extern struct { format: u32 = DXGI_FORMAT_B8G8R8A8_UNORM, alpha: u32 = ALPHA_PREMULTIPLIED };

pub const RenderTargetProperties = extern struct {
    type: u32 = 0, // default (hardware if available)
    pixel_format: PixelFormat = .{},
    dpi_x: f32 = 0,
    dpi_y: f32 = 0,
    usage: u32 = 0,
    min_level: u32 = 0,
};

pub const HwndRenderTargetProperties = extern struct {
    hwnd: w.HWND,
    size: SizeU,
    present: u32 = 0,
};

pub const BitmapProperties = extern struct { pixel_format: PixelFormat = .{}, dpi_x: f32 = 96, dpi_y: f32 = 96 };
pub const BitmapBrushProperties = extern struct { extend_x: u32 = 0, extend_y: u32 = 0, interpolation: u32 = 1 };
pub const GradientStop = extern struct { position: f32, color: ColorF };
pub const LinearGradientProperties = extern struct { start: Point2F, end: Point2F };

pub extern "d2d1" fn D2D1CreateFactory(kind: u32, iid: *const GUID, options: ?*const anyopaque, out: *?*Object) callconv(.winapi) HRESULT;

/// ID2D1Factory methods.
pub const Factory = struct {
    pub fn createHwndTarget(f: *Object, rt: *const RenderTargetProperties, hw: *const HwndRenderTargetProperties) ?*Object {
        var out: ?*Object = null;
        const hr = method(f, 14, fn (*Object, *const RenderTargetProperties, *const HwndRenderTargetProperties, *?*Object) callconv(.winapi) HRESULT)(f, rt, hw, &out);
        return if (ok(hr)) out else null;
    }
};

/// ID2D1RenderTarget / ID2D1HwndRenderTarget methods.
pub const Target = struct {
    pub fn createBitmap(t: *Object, size: SizeU, pixels: [*]const u8, pitch: u32) ?*Object {
        var out: ?*Object = null;
        const props: BitmapProperties = .{};
        const hr = method(t, 4, fn (*Object, SizeU, ?*const anyopaque, u32, *const BitmapProperties, *?*Object) callconv(.winapi) HRESULT)(t, size, pixels, pitch, &props, &out);
        return if (ok(hr)) out else null;
    }
    pub fn createBitmapBrush(t: *Object, bitmap: *Object) ?*Object {
        var out: ?*Object = null;
        const props: BitmapBrushProperties = .{};
        const hr = method(t, 7, fn (*Object, *Object, ?*const BitmapBrushProperties, ?*const anyopaque, *?*Object) callconv(.winapi) HRESULT)(t, bitmap, &props, null, &out);
        return if (ok(hr)) out else null;
    }
    pub fn createSolidBrush(t: *Object, color: ColorF) ?*Object {
        var out: ?*Object = null;
        const hr = method(t, 8, fn (*Object, *const ColorF, ?*const anyopaque, *?*Object) callconv(.winapi) HRESULT)(t, &color, null, &out);
        return if (ok(hr)) out else null;
    }
    pub fn createLinearGradient(t: *Object, stops: []const GradientStop, start: Point2F, end: Point2F) ?*Object {
        var coll: ?*Object = null;
        if (!ok(method(t, 9, fn (*Object, [*]const GradientStop, u32, u32, u32, *?*Object) callconv(.winapi) HRESULT)(t, stops.ptr, @intCast(stops.len), 0, 0, &coll))) return null; // zsnag:ok — a few stops
        defer release(coll.?);
        var out: ?*Object = null;
        const props: LinearGradientProperties = .{ .start = start, .end = end };
        const hr = method(t, 10, fn (*Object, *const LinearGradientProperties, ?*const anyopaque, *Object, *?*Object) callconv(.winapi) HRESULT)(t, &props, null, coll.?, &out);
        return if (ok(hr)) out else null;
    }
    pub fn drawLine(t: *Object, a: Point2F, b: Point2F, brush: *Object, width: f32) void {
        method(t, 15, fn (*Object, Point2F, Point2F, *Object, f32, ?*anyopaque) callconv(.winapi) void)(t, a, b, brush, width, null);
    }
    pub fn fillRect(t: *Object, r: RectF, brush: *Object) void {
        method(t, 17, fn (*Object, *const RectF, *Object) callconv(.winapi) void)(t, &r, brush);
    }
    pub fn drawRoundedRect(t: *Object, r: RoundedRect, brush: *Object, width: f32) void {
        method(t, 18, fn (*Object, *const RoundedRect, *Object, f32, ?*anyopaque) callconv(.winapi) void)(t, &r, brush, width, null);
    }
    pub fn fillRoundedRect(t: *Object, r: RoundedRect, brush: *Object) void {
        method(t, 19, fn (*Object, *const RoundedRect, *Object) callconv(.winapi) void)(t, &r, brush);
    }
    pub fn drawEllipse(t: *Object, e: Ellipse, brush: *Object, width: f32) void {
        method(t, 20, fn (*Object, *const Ellipse, *Object, f32, ?*anyopaque) callconv(.winapi) void)(t, &e, brush, width, null);
    }
    pub fn fillEllipse(t: *Object, e: Ellipse, brush: *Object) void {
        method(t, 21, fn (*Object, *const Ellipse, *Object) callconv(.winapi) void)(t, &e, brush);
    }
    pub fn drawText(t: *Object, text: []const u16, format: *Object, r: RectF, brush: *Object) void {
        // D2D1_DRAW_TEXT_OPTIONS_CLIP (2) | ENABLE_COLOR_FONT (4): colour emoji in file names.
        method(t, 27, fn (*Object, [*]const u16, u32, *Object, *const RectF, *Object, u32, u32) callconv(.winapi) void)(t, text.ptr, @intCast(text.len), format, &r, brush, 2 | 4, 0); // zsnag:ok — UI strings are short
    }
    pub fn pushClip(t: *Object, r: RectF) void {
        method(t, 45, fn (*Object, *const RectF, u32) callconv(.winapi) void)(t, &r, 0);
    }
    pub fn popClip(t: *Object) void {
        method(t, 46, fn (*Object) callconv(.winapi) void)(t);
    }
    pub fn clear(t: *Object, color: ColorF) void {
        method(t, 47, fn (*Object, *const ColorF) callconv(.winapi) void)(t, &color);
    }
    pub fn beginDraw(t: *Object) void {
        method(t, 48, fn (*Object) callconv(.winapi) void)(t);
    }
    pub fn endDraw(t: *Object) HRESULT {
        return method(t, 49, fn (*Object, ?*u64, ?*u64) callconv(.winapi) HRESULT)(t, null, null);
    }
    pub fn setDpi(t: *Object, dpi: f32) void {
        method(t, 51, fn (*Object, f32, f32) callconv(.winapi) void)(t, dpi, dpi);
    }
    pub fn setTextAntialias(t: *Object, mode: u32) void {
        method(t, 34, fn (*Object, u32) callconv(.winapi) void)(t, mode);
    }
    pub fn resize(t: *Object, size: SizeU) HRESULT {
        return method(t, 58, fn (*Object, *const SizeU) callconv(.winapi) HRESULT)(t, &size);
    }
};

/// ID2D1Brush / ID2D1SolidColorBrush methods.
pub const Brush = struct {
    pub fn setOpacity(b: *Object, opacity: f32) void {
        method(b, 4, fn (*Object, f32) callconv(.winapi) void)(b, opacity);
    }
    pub fn setTransform(b: *Object, m: Matrix) void {
        method(b, 5, fn (*Object, *const Matrix) callconv(.winapi) void)(b, &m);
    }
    pub fn setColor(b: *Object, c: ColorF) void {
        method(b, 8, fn (*Object, *const ColorF) callconv(.winapi) void)(b, &c);
    }
};

// ---- DirectWrite ---------------------------------------------------------------

pub const IID_IDWriteFactory = GUID.parse("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");

pub const FONT_WEIGHT_NORMAL: u32 = 400;
pub const FONT_WEIGHT_SEMIBOLD: u32 = 600;
pub const TEXT_ALIGN_LEADING: u32 = 0;
pub const TEXT_ALIGN_TRAILING: u32 = 1;
pub const TEXT_ALIGN_CENTER: u32 = 2;
pub const PARA_ALIGN_CENTER: u32 = 2;
pub const WORD_WRAP_NONE: u32 = 1;

pub const Trimming = extern struct { granularity: u32 = 1, delimiter: u32 = 0, count: u32 = 0 };
pub const TextMetrics = extern struct {
    left: f32,
    top: f32,
    width: f32,
    width_with_trailing: f32,
    height: f32,
    layout_width: f32,
    layout_height: f32,
    max_bidi_depth: u32,
    line_count: u32,
};

pub extern "dwrite" fn DWriteCreateFactory(kind: u32, iid: *const GUID, out: *?*Object) callconv(.winapi) HRESULT;

/// IDWriteFactory / IDWriteTextFormat / IDWriteTextLayout methods.
pub const Write = struct {
    /// One line, vertically centred in its box, cut with "…" when too long.
    pub fn createFormat(f: *Object, family: [*:0]const u16, weight: u32, size: f32, align_x: u32) ?*Object {
        var out: ?*Object = null;
        // IDWriteFactory::CreateTextFormat (15)
        if (!ok(method(f, 15, fn (*Object, [*:0]const u16, ?*anyopaque, u32, u32, u32, f32, [*:0]const u16, *?*Object) callconv(.winapi) HRESULT)(f, family, null, weight, 0, 5, size, w.L("en-us"), &out))) return null;
        const fmt = out.?;
        // IDWriteTextFormat: SetTextAlignment (3), SetParagraphAlignment (4), SetWordWrapping (5), SetTrimming (9)
        _ = method(fmt, 3, fn (*Object, u32) callconv(.winapi) HRESULT)(fmt, align_x);
        _ = method(fmt, 4, fn (*Object, u32) callconv(.winapi) HRESULT)(fmt, PARA_ALIGN_CENTER);
        _ = method(fmt, 5, fn (*Object, u32) callconv(.winapi) HRESULT)(fmt, WORD_WRAP_NONE);
        // IDWriteFactory::CreateEllipsisTrimmingSign (20)
        var sign: ?*Object = null;
        if (ok(method(f, 20, fn (*Object, *Object, *?*Object) callconv(.winapi) HRESULT)(f, fmt, &sign))) {
            const trim: Trimming = .{};
            _ = method(fmt, 9, fn (*Object, *const Trimming, ?*Object) callconv(.winapi) HRESULT)(fmt, &trim, sign);
            release(sign.?);
        }
        return fmt;
    }

    /// The width `text` takes in `format`.
    pub fn measure(f: *Object, format: *Object, text: []const u16) f32 {
        var layout: ?*Object = null;
        // IDWriteFactory::CreateTextLayout (18)
        if (!ok(method(f, 18, fn (*Object, [*]const u16, u32, *Object, f32, f32, *?*Object) callconv(.winapi) HRESULT)(f, text.ptr, @intCast(text.len), format, 1e6, 1e6, &layout))) return 0; // zsnag:ok — UI strings are short
        defer release(layout.?);
        var m: TextMetrics = undefined;
        // IDWriteTextLayout::GetMetrics (60)
        if (!ok(method(layout.?, 60, fn (*Object, *TextMetrics) callconv(.winapi) HRESULT)(layout.?, &m))) return 0;
        return m.width_with_trailing;
    }
};

test "GUIDs parse from their registry form" {
    const g = comptime GUID.parse("06152247-6f50-465a-9245-118bfd3b6007");
    try std.testing.expectEqual(@as(u32, 0x06152247), g.a);
    try std.testing.expectEqual(@as(u16, 0x6f50), g.b);
    try std.testing.expectEqual(@as(u16, 0x465a), g.c);
    try std.testing.expectEqualSlices(u8, &.{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 }, &g.d);
}
