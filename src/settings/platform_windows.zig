// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The settings window on Windows: a Win32 window over the Mica backdrop,
//! Direct2D drawing (`gui_d2d.zig`), the shell's pickers, menus and
//! thumbnails, the control pipe, and "Start with Windows" (the Run key).
//!
//! Opened from the tray icon (left click) or by `zmural --settings`. It runs
//! on its own thread inside zmural (`window.zig`), with its own message
//! loop; zmural's thread reaches it only through `raise` and `requestClose`.

const std = @import("std");
const zmural = @import("zmural");
const w = zmural.os.win32;
const sys = @import("sys.zig");
const gui = @import("gui.zig");
const thumbs = @import("thumbs.zig");
const app_mod = @import("app.zig");
const app = &app_mod.app;
const Env = @import("env.zig").Env;

pub const Client = zmural.sdk.control_client.Client;

/// No title bar of our own: Windows draws it.
pub fn chromeHeight() f32 {
    return 0;
}
pub const autostart_title = "Start with Windows";
pub const library_hint = "Add a folder of videos or pictures, or put them in Videos\\Wallpapers.";

const class_name = w.L("zmural.settings");
const WM_THUMB = w.WM_APP + 1;
const timer_poll: usize = 1;
const timer_anim: usize = 2;
/// Replies from zmural should take milliseconds; this only guards against a hung daemon.
const reply_timeout_ms = 3000;

const State = struct {
    hwnd: w.HWND = undefined,
    addr: []const u8 = "",
    addr_buf: [256]u8 = undefined,
    worker: ?*thumbs.Worker = null,
    anim_timer: bool = false,
    /// `ZMURAL_THEME=dark|light` overrides Windows' app theme.
    force_dark: ?bool = null,
    io: std.Io = undefined,
    /// A running `zmural-console import` (`startImport`).
    import_child: ?zmural.os.process.Child = null,
};

var st: State = .{};

/// The window class outlives a window: a second window reuses it.
var class_registered = false;

/// Set by `requestClose`, so a close asked for before the window exists (its
/// thread is still starting) isn't lost: `run` reads it once the window can
/// be found. Without it, zmural's quit waited forever on the window's thread.
var close_wanted: std.atomic.Value(bool) = .init(false);

/// Before `run`, on zmural's thread.
pub fn prepare() !void {
    close_wanted.store(false, .seq_cst);
}

/// Brings the open window to the front. From zmural's thread.
pub fn raise(_: []const u8) void {
    const existing = w.FindWindowW(class_name, null) orelse return;
    if (sys.IsIconic(existing) != 0) _ = w.ShowWindow(existing, sys.SW_RESTORE);
    _ = w.SetForegroundWindow(existing);
}

/// Asks the window to close. From zmural's thread.
pub fn requestClose() void {
    // The flag first: either `run` sees it, or this finds the window.
    close_wanted.store(true, .seq_cst);
    const existing = w.FindWindowW(class_name, null) orelse return;
    _ = w.PostMessageW(existing, w.WM_CLOSE, 0, 0);
}

/// The window, from open to close, on its own thread inside zmural.
pub fn run(env: Env, _: []const u8) !void {
    st = .{};
    st.io = env.io;
    const gpa = env.gpa;
    _ = sys.CoInitializeEx(null, sys.COINIT_APARTMENTTHREADED | sys.COINIT_DISABLE_OLE1DDE);
    defer sys.CoUninitialize();

    app_mod.init(gpa);
    defer app_mod.deinit();
    st.addr = try zmural.sdk.control_client.address(&st.addr_buf);
    app.log_path = env.log_path;
    app.open_on_welcome = env.welcome;
    app.autostart = autostartOn();
    st.force_dark = env.force_dark;

    const instance = w.GetModuleHandleW(null);
    if (!class_registered) {
        if (w.RegisterClassExW(&.{
            .lpfnWndProc = wndProc,
            .hInstance = instance,
            .lpszClassName = class_name,
            .hCursor = sys.LoadCursorW(null, sys.IDC_ARROW),
            .hIcon = sys.LoadIconW(instance, 1),
        }) == 0) return error.RegisterClassFailed;
        class_registered = true;
    }
    st.hwnd = w.CreateWindowExW(0, class_name, w.L("zmural"), sys.WS_OVERLAPPEDWINDOW, sys.CW_USEDEFAULT, sys.CW_USEDEFAULT, app_mod.window_w, app_mod.window_h, null, null, instance, null) orelse
        return error.CreateWindowFailed;
    // Any error from here on must not leave a dead window behind.
    errdefer _ = w.DestroyWindow(st.hwnd);
    // `requestClose` came before the window could be found: close it the
    // usual way, once the loop below starts.
    if (close_wanted.load(.seq_cst)) _ = w.PostMessageW(st.hwnd, w.WM_CLOSE, 0, 0);
    app.ui = .init(gpa, try gui.Backend.init(st.hwnd), @import("gui_d2d.zig").systemTheme(st.force_dark));
    defer app.ui.deinit();
    // Defers run last-first: the thumbnails are Direct2D bitmaps and go
    // before the backend (`app_mod.deinit` above runs after it).
    defer app_mod.dropThumbs();
    applyTheme();
    fitToDpi();

    st.worker = thumbs.Worker.start(gpa, st.hwnd, WM_THUMB, app_mod.thumb_px) catch null;
    defer if (st.worker) |wk| wk.stop();

    app_mod.connect();
    _ = w.SetTimer(st.hwnd, timer_poll, app_mod.poll_ms, null);
    _ = w.ShowWindow(st.hwnd, sys.SW_SHOW);
    std.log.scoped(.settings).info("window: open", .{});

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
}

/// Mica and a dark title bar when Windows apps are dark.
fn applyTheme() void {
    app.ui.pal = .build(@import("gui_d2d.zig").systemTheme(st.force_dark));
    const dark: w.BOOL = @intFromBool(app.ui.pal.dark);
    _ = sys.DwmSetWindowAttribute(st.hwnd, sys.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(w.BOOL));
    const backdrop: w.DWORD = sys.DWMSBT_MAINWINDOW;
    app.ui.b.mica = sys.ok(sys.DwmSetWindowAttribute(st.hwnd, sys.DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, @sizeOf(w.DWORD)));
    if (app.ui.b.mica) _ = sys.DwmExtendFrameIntoClientArea(st.hwnd, &.{ .left = -1, .right = -1, .top = -1, .bottom = -1 });
}

/// The window was created at 96-DPI pixel sizes; scale it to its monitor.
fn fitToDpi() void {
    const scale = app.ui.b.dpi / 96;
    var rc: w.RECT = undefined;
    _ = sys.GetWindowRect(st.hwnd, &rc);
    _ = w.SetWindowPos(st.hwnd, null, rc.left, rc.top, @intFromFloat(app_mod.window_w * scale), @intFromFloat(app_mod.window_h * scale), w.SWP_NOZORDER | w.SWP_NOACTIVATE);
}

// ---- what the app asks of the platform ------------------------------------------------

pub fn now() u64 {
    return w.GetTickCount64();
}

pub fn redraw() void {
    _ = w.InvalidateRect(st.hwnd, null, 0);
}

/// Windows draws the title bar.
pub fn drawChrome() void {}

pub fn wantAnimation(on: bool) void {
    if (on == st.anim_timer) return;
    st.anim_timer = on;
    if (on) _ = w.SetTimer(st.hwnd, timer_anim, 16, null) else _ = w.KillTimer(st.hwnd, timer_anim);
}

pub fn connect() ?*Client {
    const c = Client.connect(app.gpa, st.addr, "settings") catch return null;
    c.conn.read_timeout_ms = reply_timeout_ms;
    return c;
}

/// Asks for a path; the answer goes to `app.picked` (at once: the shell's
/// picker is modal).
pub fn pick(kind: app_mod.PickKind) void {
    const path = pickPath(kind) orelse return;
    defer app.gpa.free(path);
    app_mod.picked(kind, path);
}

fn pickPath(kind: app_mod.PickKind) ?[]u8 {
    @setEvalBranchQuota(10_000); // the UTF-16 string literals below are converted at comptime
    return switch (kind) {
        .wallpaper => sys.pickPath(app.gpa, st.hwnd, w.L("Show a video, picture or web page, or import a zip"), false, &[_]sys.FilterSpec{
            .{ .name = w.L("Videos, pictures, web pages and zips"), .spec = w.L("*.mp4;*.mkv;*.webm;*.mov;*.avi;*.wmv;*.m4v;*.png;*.jpg;*.jpeg;*.webp;*.bmp;*.gif;*.avif;*.html;*.htm;*.zip") },
            .{ .name = w.L("All files"), .spec = w.L("*.*") },
        }),
        .folder => sys.pickPath(app.gpa, st.hwnd, w.L("Add a wallpaper folder"), true, &.{}),
        .app => sys.pickPath(app.gpa, st.hwnd, w.L("Pause wallpapers while this app is in front"), false, &[_]sys.FilterSpec{.{ .name = w.L("Programs"), .spec = w.L("*.exe") }}),
    };
}

/// A popup menu at the pointer for library tile `tile`; the choice goes to
/// `app.menuChosen`.
pub fn menu(items: []const []const u8, tile: usize) void {
    if (popupMenu(items)) |choice| app_mod.menuChosen(tile, choice);
}

fn popupMenu(items: []const []const u8) ?usize {
    const m = sys.CreatePopupMenu() orelse return null;
    defer _ = sys.DestroyMenu(m);
    for (items, 0..) |item, i| {
        const wide = std.unicode.wtf8ToWtf16LeAllocZ(app.gpa, item) catch return null;
        defer app.gpa.free(wide);
        _ = sys.AppendMenuW(m, sys.MF_STRING, i + 1, wide);
    }
    var at: w.POINT = undefined;
    _ = w.GetCursorPos(&at);
    // Opened from the keyboard: under the focused tile, not at the mouse.
    if (app.ui.focus_visible) if (app.ui.focus_rect) |r| {
        const scale = if (app.ui.b.dpi > 0) app.ui.b.dpi / 96 else 1;
        at = .{ .x = @intFromFloat((r.x + 12) * scale), .y = @intFromFloat((r.bottom() - 12) * scale) };
        _ = sys.ClientToScreen(st.hwnd, &at);
    };
    const chosen = sys.TrackPopupMenuEx(m, sys.TPM_RETURNCMD | sys.TPM_RIGHTBUTTON, at.x, at.y, st.hwnd, null);
    return if (chosen > 0) @intCast(chosen - 1) else null;
}

/// A yes/no question; on yes, `action` is done.
pub fn confirm(question: []const u8, action: app_mod.Action) void {
    const wide = std.unicode.wtf8ToWtf16LeAllocZ(app.gpa, question) catch return;
    defer app.gpa.free(wide);
    // No is the default, as on Linux: every question here (reset, uninstall)
    // undoes something, so Enter must never answer it by accident.
    if (MessageBoxW(st.hwnd, wide, w.L("zmural"), 0x4 | 0x20 | 0x100) == 6) app_mod.confirmed(action); // MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2, IDYES
}

/// Menus and dialogs are native windows here: nothing drawn in ours.
pub fn modal() bool {
    return false;
}

pub fn drawOverlay() void {}

extern "user32" fn MessageBoxW(hwnd: ?w.HWND, text: [*:0]const u16, caption: [*:0]const u16, kind: w.UINT) callconv(.winapi) c_int;

pub fn showInFolder(path: []const u8) void {
    const arg = std.fmt.allocPrint(app.gpa, "/select,\"{s}\"", .{path}) catch return;
    defer app.gpa.free(arg);
    const arg_w = std.unicode.wtf8ToWtf16LeAllocZ(app.gpa, arg) catch return;
    defer app.gpa.free(arg_w);
    shell(w.ShellExecuteW(st.hwnd, null, w.L("explorer.exe"), arg_w, null, w.SW_SHOWNORMAL), "Explorer didn't start to show it. It is", path);
}

/// Says so when ShellExecuteW didn't start anything (it returns 32 or less
/// then), instead of a button that does nothing.
fn shell(rc: ?w.HINSTANCE, failed: []const u8, path: []const u8) void {
    if (@intFromPtr(rc) > 32) return;
    var buf: [160]u8 = undefined;
    app_mod.showToast(std.fmt.bufPrint(&buf, "{s} {s}", .{ failed, path }) catch failed);
}

/// Opens a folder in Explorer, making it first if it's not there yet (a
/// standard library folder nobody has used).
pub fn openFolder(path: []const u8) void {
    if (path.len == 0) return;
    std.Io.Dir.cwd().createDirPath(st.io, path) catch return app_mod.showToast("can't make that folder");
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(app.gpa, path) catch return;
    defer app.gpa.free(path_w);
    shell(w.ShellExecuteW(st.hwnd, w.L("open"), path_w, null, null, w.SW_SHOWNORMAL), "Windows didn't open the folder. It is", path);
}

/// Opens a text file (the settings file, the log) in Notepad.
pub fn openFile(path: []const u8) void {
    if (path.len == 0) return;
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(app.gpa, path) catch return;
    defer app.gpa.free(path_w);
    shell(w.ShellExecuteW(st.hwnd, w.L("open"), w.L("notepad.exe"), path_w, null, w.SW_SHOWNORMAL), "Notepad didn't start to show the log. It is", path);
}

/// Runs `zmural --uninstall` for the Uninstall button: it quits this zmural
/// (and so this window) and says when it's done, in a message box.
pub fn startUninstall() !void {
    const exe = try zmural.os.process.selfExe(app.gpa);
    defer app.gpa.free(exe);
    // Outside zmural's jobs: it has to outlive this zmural.
    const child = try zmural.os.process.spawn(app.gpa, exe, &.{ "--uninstall", "--from-window" }, .{});
    child.close();
}

/// `zmural-console import <zip> --apply --report <report>`, without a
/// console window; `importFinished` says when it's done.
pub fn startImport(zip_path: []const u8, report: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(st.io, report) catch {}; // zsnag:ok — usually not there; an old one would only be read if the new import wrote none
    const exe = try zmural.os.process.siblingExe(app.gpa, "zmural-console.exe");
    defer app.gpa.free(exe);
    st.import_child = try zmural.os.process.spawn(app.gpa, exe, &.{ "import", zip_path, "--apply", "--report", report }, .{});
}

pub fn importFinished() bool {
    const c = st.import_child orelse return true;
    if (!c.hasExited()) return false;
    c.close();
    st.import_child = null;
    return true;
}

/// A small file's contents into `buf`, or null.
pub fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFile(st.io, path, buf) catch null;
}

pub fn startDaemon() !void {
    const exe = try zmural.os.process.siblingExe(app.gpa, "zmural.exe");
    defer app.gpa.free(exe);
    const exe_w = try std.unicode.wtf8ToWtf16LeAllocZ(app.gpa, exe);
    defer app.gpa.free(exe_w);
    _ = w.ShellExecuteW(st.hwnd, null, exe_w, null, null, w.SW_SHOWNORMAL);
}

pub fn autostartOn() bool {
    var buf: [2048]u8 = undefined;
    return zmural.os.autostart.status(&buf) != null;
}

pub fn setAutostart(on: bool) !void {
    const reg = zmural.os.autostart;
    if (!on) return reg.disable();
    const exe = try zmural.os.process.siblingExe(app.gpa, "zmural.exe");
    defer app.gpa.free(exe);
    try reg.enable(exe);
}

pub fn requestThumb(path: []const u8) void {
    if (st.worker) |wk| wk.request(path);
}

fn onThumb() void {
    const wk = st.worker orelse return;
    while (wk.take()) |r| {
        defer r.destroy(app.gpa);
        app_mod.thumbReady(r.path, r.pixels, r.width, r.height);
    }
}

// ---- window ---------------------------------------------------------------------------

/// A pressed key, as the UI's keys for this frame. False if zmural doesn't
/// use it (Windows then handles it: Alt+F4, Alt+Space...).
/// `held`: a repeat while the key stays down (bit 30 of WM_KEYDOWN's lParam).
/// As on Linux, only Tab and the arrows repeat; a held Enter or Space presses once.
fn keyDown(vk: w.WPARAM, held: bool) bool {
    const k = &app.ui.keys;
    const shift = sys.GetKeyState(0x10) < 0; // VK_SHIFT
    const repeats = switch (vk) {
        0x09, 0x25...0x28 => true, // VK_TAB, VK_LEFT..VK_DOWN
        else => false,
    };
    if (held and !repeats) return switch (vk) {
        0x0D, 0x20, 0x1B, 0x23, 0x24 => true, // swallowed, as below
        else => false,
    };
    switch (vk) {
        0x09 => if (shift) { // VK_TAB
            k.shift_tab = true;
        } else {
            k.tab = true;
        },
        0x0D, 0x20 => k.activate = true, // VK_RETURN, VK_SPACE
        0x1B => k.escape = true, // VK_ESCAPE
        0x23 => k.end = true, // VK_END
        0x24 => k.home = true, // VK_HOME
        0x25 => k.left = true, // VK_LEFT
        0x26 => k.up = true, // VK_UP
        0x27 => k.right = true, // VK_RIGHT
        0x28 => k.down = true, // VK_DOWN
        else => return false,
    }
    return true;
}

fn wndProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    const ui = &app.ui;
    switch (msg) {
        w.WM_PAINT => {
            app_mod.frame();
            _ = sys.ValidateRect(hwnd, null);
            return 0;
        },
        w.WM_ERASEBKGND => return 1,
        sys.WM_SIZE => {
            ui.b.resized();
            app_mod.frame();
            return 0;
        },
        sys.WM_DPICHANGED => {
            ui.b.setDpi(@floatFromInt(wp & 0xFFFF));
            const r: *const w.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
            _ = w.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, w.SWP_NOZORDER | w.SWP_NOACTIVATE);
            return 0;
        },
        sys.WM_GETMINMAXINFO => {
            const mm: *sys.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lp)));
            const scale = if (ui.b.dpi > 0) ui.b.dpi / 96 else 1;
            mm.ptMinTrackSize = .{ .x = @intFromFloat(app_mod.min_w * scale), .y = @intFromFloat(app_mod.min_h * scale) };
            return 0;
        },
        sys.WM_MOUSEMOVE => {
            if (ui.mouse.x < 0) {
                var tme: sys.TRACKMOUSEEVENT = .{ .dwFlags = sys.TME_LEAVE, .hwndTrack = hwnd };
                _ = sys.TrackMouseEvent(&tme);
            }
            ui.mouse = mousePoint(lp);
            app_mod.frame();
            return 0;
        },
        sys.WM_MOUSELEAVE => {
            ui.mouse = .{ .x = -1, .y = -1 };
            app_mod.frame();
            return 0;
        },
        sys.WM_LBUTTONDOWN => {
            _ = sys.SetCapture(hwnd);
            ui.mouse = mousePoint(lp);
            ui.down = true;
            ui.pressed = true;
            app_mod.frame();
            return 0;
        },
        sys.WM_LBUTTONUP => {
            ui.mouse = mousePoint(lp);
            ui.down = false;
            ui.released = true;
            _ = sys.ReleaseCapture();
            app_mod.frame();
            return 0;
        },
        sys.WM_CAPTURECHANGED => {
            if (ui.down) {
                ui.down = false;
                ui.active = 0;
                redraw();
            }
            return 0;
        },
        sys.WM_RBUTTONUP => {
            ui.mouse = mousePoint(lp);
            ui.right_released = true;
            app_mod.frame();
            return 0;
        },
        sys.WM_KEYDOWN => if (keyDown(wp, (lp >> 30) & 1 != 0)) {
            app_mod.frame();
            return 0;
        },
        // The Menu key and Shift+F10 arrive as a context menu at (-1, -1); a
        // right click is handled at WM_RBUTTONUP already. On 64-bit Windows
        // that's MAKELPARAM(-1, -1), 0xFFFFFFFF in the low half, not -1.
        w.WM_CONTEXTMENU => {
            if (@as(u32, @truncate(@as(usize, @bitCast(lp)))) == 0xFFFF_FFFF) {
                ui.keys.menu = true;
                app_mod.frame();
            }
            return 0;
        },
        sys.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            ui.wheel += @floatFromInt(delta);
            app_mod.frame();
            return 0;
        },
        sys.WM_SETTINGCHANGE, sys.WM_THEMECHANGED => {
            applyTheme();
            redraw();
        },
        w.WM_TIMER => {
            if (wp == timer_poll) app_mod.onPoll() else app_mod.frame();
            return 0;
        },
        WM_THUMB => {
            onThumb();
            return 0;
        },
        w.WM_DESTROY => {
            w.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

fn mousePoint(lp: w.LPARAM) gui.Point {
    const bits: usize = @bitCast(lp);
    const x: i16 = @bitCast(@as(u16, @truncate(bits)));
    const y: i16 = @bitCast(@as(u16, @truncate(bits >> 16)));
    const s = 96 / app.ui.b.dpi;
    return .{ .x = @as(f32, @floatFromInt(x)) * s, .y = @as(f32, @floatFromInt(y)) * s };
}
