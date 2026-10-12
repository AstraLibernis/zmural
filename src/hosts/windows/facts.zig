// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What's on screen right now (Windows): the facts the pause policy decides on.
//!
//! Per monitor: fullscreen, maximized, covered, focused. System-wide: battery,
//! battery saver, remote session, app rules (the foreground app) and, passed
//! in by the caller, session lock. The shell's own "a fullscreen D3D app or
//! presentation is running" state also counts as fullscreen, which catches
//! exclusive-fullscreen games.
//!
//! Only windows that actually hide the desktop count. Minimised, cloaked
//! (other virtual desktops, suspended UWP), click-through overlays (game and
//! GPU overlays), floating tool windows and the shell's own windows are
//! skipped. Window bounds come from DWM, so invisible resize borders don't
//! count as coverage.

const std = @import("std");
const zmural = @import("zmural");
const w = zmural.os.win32;
const Rect = zmural.layout.Rect;
const coverage = zmural.coverage;
const Conditions = zmural.policy.Conditions;
const monitors = @import("monitors.zig");

pub const max_windows = 256;

/// A top-level window that hides the desktop.
pub const Window = struct {
    rect: Rect,
    maximized: bool,
    foreground: bool,
};

pub const Snapshot = struct {
    system: Conditions = Conditions.initEmpty(),
    monitors: [monitors.max]Conditions = @splat(Conditions.initEmpty()),
    count: usize = 0,
    /// The foreground app's executable name (WTF-8), for logs and app rules.
    foreground_exe: [max_exe_name]u8 = undefined,
    foreground_exe_len: usize = 0,

    pub fn foregroundExe(s: *const Snapshot) []const u8 {
        return s.foreground_exe[0..s.foreground_exe_len];
    }

    pub fn eql(a: *const Snapshot, b: *const Snapshot) bool {
        if (a.count != b.count or !a.system.eql(b.system)) return false;
        for (a.monitors[0..a.count], b.monitors[0..b.count]) |x, y| if (!x.eql(y)) return false;
        return true;
    }
};

/// Window attributes that decide whether it hides the desktop.
pub const Attrs = struct {
    visible: bool,
    minimized: bool,
    cloaked: bool,
    own_process: bool,
    ex_style: w.DWORD,
    class: []const u8,
    width: u32,
    height: u32,
};

const shell_classes = [_][]const u8{ "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow" };

pub fn hidesDesktop(a: Attrs) bool {
    if (!a.visible or a.minimized or a.cloaked or a.own_process) return false;
    if (a.width == 0 or a.height == 0) return false;
    // Click-through overlays (Steam, Discord, GPU performance overlays).
    if (a.ex_style & w.WS_EX_TRANSPARENT != 0) return false;
    // Floating palettes and toasts; a tool window that opts into the taskbar still counts.
    if (a.ex_style & w.WS_EX_TOOLWINDOW != 0 and a.ex_style & w.WS_EX_APPWINDOW == 0) return false;
    for (shell_classes) |c| if (std.mem.eql(u8, a.class, c)) return false;
    return true;
}

/// Per-monitor conditions from the windows that hide the desktop.
pub fn deriveMonitor(monitor: Rect, windows: []const Window) Conditions {
    var set = Conditions.initEmpty();
    var on_monitor: [max_windows]Rect = undefined;
    var n: usize = 0;
    for (windows) |win| {
        if (!overlaps(win.rect, monitor)) continue;
        if (contains(win.rect, monitor)) set.insert(.fullscreen);
        if (centerIn(win.rect, monitor)) {
            if (win.maximized) set.insert(.maximized);
            if (win.foreground) set.insert(.focused);
        }
        on_monitor[n] = win.rect;
        n += 1;
    }
    if (set.contains(.fullscreen) or set.contains(.maximized) or coverage.isCovered(monitor, on_monitor[0..n]))
        set.insert(.covered);
    return set;
}

/// Gathers a snapshot. `app_rules` are executable names (e.g. "eldenring.exe"),
/// matched case-insensitively against the foreground app.
pub fn collect(screens: []const Rect, own_pid: w.DWORD, locked: bool, app_rules: []const []const u8) Snapshot {
    var snap: Snapshot = .{ .count = @min(screens.len, monitors.max) };

    var ctx: Enum = .{ .own_pid = own_pid, .foreground = w.GetForegroundWindow() };
    _ = w.EnumWindows(onWindow, w.toLparam(&ctx));
    for (screens[0..snap.count], 0..) |m, i| snap.monitors[i] = deriveMonitor(m, ctx.windows[0..ctx.len]);

    // Exclusive-fullscreen games and presentations, as the shell sees them:
    // attribute them to the monitor the foreground window is on.
    var quns: c_int = 0;
    if (w.SHQueryUserNotificationState(&quns) == 0 and
        (quns == w.QUNS_RUNNING_D3D_FULL_SCREEN or quns == w.QUNS_BUSY or quns == w.QUNS_PRESENTATION_MODE))
    {
        const i = foregroundMonitor(&snap, screens, ctx.foreground) orelse 0;
        if (i < snap.count) {
            snap.monitors[i].insert(.fullscreen);
            snap.monitors[i].insert(.covered);
        }
    }

    var power: w.SYSTEM_POWER_STATUS = undefined;
    if (w.GetSystemPowerStatus(&power) != 0) {
        if (power.ACLineStatus == 0) snap.system.insert(.on_battery);
        if (power.SystemStatusFlag == 1) snap.system.insert(.power_saver);
    }
    if (w.GetSystemMetrics(w.SM_REMOTESESSION) != 0) snap.system.insert(.remote_session);
    if (locked) snap.system.insert(.session_locked);

    if (ctx.foreground) |fg| {
        snap.foreground_exe_len = exeName(fg, &snap.foreground_exe);
        for (app_rules) |rule| {
            if (std.ascii.eqlIgnoreCase(rule, snap.foregroundExe())) snap.system.insert(.app_rule);
        }
    }
    return snap;
}

const Enum = struct {
    own_pid: w.DWORD,
    foreground: ?w.HWND,
    windows: [max_windows]Window = undefined,
    len: usize = 0,
};

fn onWindow(hwnd: w.HWND, l: w.LPARAM) callconv(.winapi) w.BOOL {
    const ctx = w.fromLparam(Enum, l);
    if (ctx.len == max_windows) return 0;

    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    var cloaked: w.DWORD = 0;
    _ = w.DwmGetWindowAttribute(hwnd, w.DWMWA_CLOAKED, &cloaked, @sizeOf(w.DWORD));
    const rect = frameBounds(hwnd);
    var class_w: [64]u16 = undefined;
    var class: [64]u8 = undefined;
    const class_len: usize = @intCast(@max(0, w.GetClassNameW(hwnd, &class_w, class_w.len))); // zsnag:ok — clamped to >= 0, <= 64
    for (class_w[0..class_len], class[0..class_len]) |c, *o| o.* = if (c < 0x80) @intCast(c) else '?'; // zsnag:ok — checked < 0x80

    const attrs: Attrs = .{
        .visible = w.IsWindowVisible(hwnd) != 0,
        .minimized = w.IsIconic(hwnd) != 0,
        .cloaked = cloaked != 0,
        .own_process = pid == ctx.own_pid,
        .ex_style = w.getStyle(hwnd, w.GWL_EXSTYLE),
        .class = class[0..class_len],
        .width = rect.w,
        .height = rect.h,
    };
    if (!hidesDesktop(attrs)) return 1;
    ctx.windows[ctx.len] = .{
        .rect = rect,
        .maximized = w.IsZoomed(hwnd) != 0,
        .foreground = ctx.foreground == hwnd,
    };
    ctx.len += 1;
    return 1;
}

/// The visible frame (DWM), without the invisible resize borders.
fn frameBounds(hwnd: w.HWND) Rect {
    var r: w.RECT = undefined;
    if (w.DwmGetWindowAttribute(hwnd, w.DWMWA_EXTENDED_FRAME_BOUNDS, &r, @sizeOf(w.RECT)) != 0 and w.GetWindowRect(hwnd, &r) == 0)
        return .{ .w = 0, .h = 0 };
    if (r.right <= r.left or r.bottom <= r.top) return .{ .w = 0, .h = 0 };
    return monitors.toRect(r);
}

fn foregroundMonitor(snap: *const Snapshot, screens: []const Rect, fg: ?w.HWND) ?usize {
    const hwnd = fg orelse return null;
    const r = frameBounds(hwnd);
    for (screens[0..snap.count], 0..) |m, i| if (centerIn(r, m)) return i;
    return null;
}

/// Writes the process's executable file name (e.g. "notepad.exe") into `out`.
/// Room for any file name: at most 255 UTF-16 units, 3 bytes each in WTF-8.
pub const max_exe_name = 255 * 3;

/// The executable name of the window's process, as WTF-8 (non-ASCII names
/// included). App rules compare it ignoring ASCII case only; non-ASCII
/// letters must match exactly. Returns 0 when it can't be read.
fn exeName(hwnd: w.HWND, out: *[max_exe_name]u8) usize {
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(hwnd, &pid);
    const process = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return 0;
    defer _ = w.CloseHandle(process);
    var path: [512]u16 = undefined;
    var len: w.DWORD = path.len;
    if (w.QueryFullProcessImageNameW(process, 0, &path, &len) == 0) return 0;
    const full = path[0..len];
    const start = if (std.mem.findScalarLast(u16, full, '\\')) |i| i + 1 else 0;
    const name = full[start..];
    if (name.len > 255) return 0;
    return std.unicode.wtf16LeToWtf8(out, name);
}

fn overlaps(a: Rect, b: Rect) bool {
    return @as(i64, a.x) < @as(i64, b.x) + b.w and @as(i64, b.x) < @as(i64, a.x) + a.w and
        @as(i64, a.y) < @as(i64, b.y) + b.h and @as(i64, b.y) < @as(i64, a.y) + a.h;
}

fn contains(outer: Rect, inner: Rect) bool {
    return outer.x <= inner.x and outer.y <= inner.y and
        @as(i64, outer.x) + outer.w >= @as(i64, inner.x) + inner.w and
        @as(i64, outer.y) + outer.h >= @as(i64, inner.y) + inner.h;
}

fn centerIn(r: Rect, m: Rect) bool {
    const cx = @as(i64, r.x) + r.w / 2;
    const cy = @as(i64, r.y) + r.h / 2;
    return cx >= m.x and cy >= m.y and cx < @as(i64, m.x) + m.w and cy < @as(i64, m.y) + m.h;
}

// ---- event watching --------------------------------------------------------------

const watched = [_][2]w.DWORD{
    .{ w.EVENT_SYSTEM_FOREGROUND, w.EVENT_SYSTEM_FOREGROUND },
    .{ w.EVENT_SYSTEM_MOVESIZEEND, w.EVENT_SYSTEM_MOVESIZEEND },
    .{ w.EVENT_SYSTEM_MINIMIZESTART, w.EVENT_SYSTEM_MINIMIZEEND },
    .{ w.EVENT_OBJECT_SHOW, w.EVENT_OBJECT_HIDE },
    .{ w.EVENT_OBJECT_LOCATIONCHANGE, w.EVENT_OBJECT_LOCATIONCHANGE },
    .{ w.EVENT_OBJECT_CLOAKED, w.EVENT_OBJECT_UNCLOAKED },
};

/// Out-of-context WinEvent hooks on every process; callbacks run on the
/// installing thread's message loop.
pub const Watcher = struct {
    hooks: [watched.len]?w.HWINEVENTHOOK = @splat(null),

    pub fn install(cb: w.WINEVENTPROC) Watcher {
        var watcher: Watcher = .{};
        for (watched, &watcher.hooks) |range, *h| {
            h.* = w.SetWinEventHook(range[0], range[1], null, cb, 0, 0, w.WINEVENT_OUTOFCONTEXT | w.WINEVENT_SKIPOWNPROCESS);
        }
        return watcher;
    }

    pub fn uninstall(watcher: *Watcher) void {
        for (&watcher.hooks) |*h| {
            if (h.*) |hook| _ = w.UnhookWinEvent(hook);
            h.* = null;
        }
    }
};

/// Filters the noisy events (location changes fire for carets and cursors
/// too) down to top-level windows.
pub fn isRelevant(event: w.DWORD, hwnd: ?w.HWND, id_object: i32, id_child: i32) bool {
    switch (event) {
        w.EVENT_SYSTEM_FOREGROUND, w.EVENT_SYSTEM_MOVESIZEEND, w.EVENT_SYSTEM_MINIMIZESTART, w.EVENT_SYSTEM_MINIMIZEEND => return true,
        else => {
            if (id_object != w.OBJID_WINDOW or id_child != w.CHILDID_SELF) return false;
            const h = hwnd orelse return false;
            return w.GetAncestor(h, w.GA_ROOT) == h;
        },
    }
}

// ---- tests ----------------------------------------------------------------------

fn testAttrs(overrides: anytype) Attrs {
    var a: Attrs = .{ .visible = true, .minimized = false, .cloaked = false, .own_process = false, .ex_style = 0, .class = "Notepad", .width = 800, .height = 600 };
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |f| @field(a, f.name) = @field(overrides, f.name);
    return a;
}

test hidesDesktop {
    try std.testing.expect(hidesDesktop(testAttrs(.{})));
    try std.testing.expect(!hidesDesktop(testAttrs(.{ .visible = false })));
    try std.testing.expect(!hidesDesktop(testAttrs(.{ .minimized = true })));
    try std.testing.expect(!hidesDesktop(testAttrs(.{ .cloaked = true })));
    try std.testing.expect(!hidesDesktop(testAttrs(.{ .own_process = true })));
    try std.testing.expect(!hidesDesktop(testAttrs(.{ .ex_style = w.WS_EX_TRANSPARENT | w.WS_EX_LAYERED })));
    try std.testing.expect(!hidesDesktop(testAttrs(.{ .ex_style = w.WS_EX_TOOLWINDOW })));
    try std.testing.expect(hidesDesktop(testAttrs(.{ .ex_style = w.WS_EX_TOOLWINDOW | w.WS_EX_APPWINDOW })));
    try std.testing.expect(!hidesDesktop(testAttrs(.{ .class = "Shell_TrayWnd" })));
    try std.testing.expect(!hidesDesktop(testAttrs(.{ .width = 0 })));
}

test deriveMonitor {
    const mon: Rect = .{ .w = 2560, .h = 1440 };
    const right: Rect = .{ .x = 2560, .w = 1920, .h = 1080 };

    try std.testing.expect(deriveMonitor(mon, &.{}).count() == 0);

    const small: Window = .{ .rect = .{ .x = 100, .y = 100, .w = 800, .h = 600 }, .maximized = false, .foreground = true };
    const s1 = deriveMonitor(mon, &.{small});
    try std.testing.expect(s1.contains(.focused) and !s1.contains(.covered));

    const maxed: Window = .{ .rect = .{ .w = 2560, .h = 1392 }, .maximized = true, .foreground = false };
    const s2 = deriveMonitor(mon, &.{maxed});
    try std.testing.expect(s2.contains(.maximized) and s2.contains(.covered) and !s2.contains(.fullscreen));
    try std.testing.expect(deriveMonitor(right, &.{maxed}).count() == 0);

    const full: Window = .{ .rect = mon, .maximized = false, .foreground = true };
    const s3 = deriveMonitor(mon, &.{full});
    try std.testing.expect(s3.contains(.fullscreen) and s3.contains(.covered));

    const halves = [_]Window{
        .{ .rect = .{ .w = 1280, .h = 1440 }, .maximized = false, .foreground = false },
        .{ .rect = .{ .x = 1280, .w = 1280, .h = 1440 }, .maximized = false, .foreground = false },
    };
    const s4 = deriveMonitor(mon, &halves);
    try std.testing.expect(s4.contains(.covered) and !s4.contains(.fullscreen));
}
