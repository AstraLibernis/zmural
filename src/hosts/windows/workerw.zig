// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Windows desktop host: places windows behind the desktop icons.
//!
//! No code from Lively; its behaviour was studied (see THIRD_PARTY_NOTICES.md).
//!
//! 1. Send Progman the undocumented 0x052C message so Explorer splits a
//!    WorkerW layer off behind the icons.
//! 2. Detect the layout:
//!    - classic (Win10, early Win11): the WorkerW is the top-level sibling
//!      after the window that owns SHELLDLL_DefView. Windows are parented to it.
//!    - raised (Win11 24H2+, Progman has WS_EX_NOREDIRECTIONBITMAP): windows
//!      are parented to Progman as layered children, z-ordered just below
//!      SHELLDLL_DefView, with Progman's WorkerW kept at the bottom.
//! 3. Before parenting, a window is made a borderless, non-activating tool
//!    window, so it never shows in the taskbar, Alt-Tab or Task View.
//!
//! Recovery (Explorer restarts, WorkerW destroyed) is the caller's job:
//! `explorer_pid` and `parent` are exposed so it can watch for both.

const std = @import("std");
const w = @import("zmural").os.win32;
const Rect = @import("zmural").layout.Rect;

pub const Error = error{ ProgmanNotFound, DesktopLayerNotFound, AttachFailed };

pub const Layout = enum { classic, raised };

/// Asks Progman to create the WorkerW behind the icons (undocumented).
const spawn_workerw_msg: w.UINT = 0x052C;

pub const Host = struct {
    progman: w.HWND,
    /// Where wallpaper windows are parented: WorkerW (classic) or Progman (raised).
    parent: w.HWND,
    /// Raised layout: windows sit directly beneath the icon layer
    /// (SHELLDLL_DefView), with Progman's WorkerW kept as the bottom-most
    /// child. Both are looked up each time (`shellView`, `progmanWorkerW`):
    /// Explorer may recreate them, and a kept handle would go stale.
    layout: Layout,
    explorer_pid: w.DWORD,

    pub fn init() Error!Host {
        const progman = w.FindWindowW(w.L("Progman"), null) orelse return error.ProgmanNotFound;
        var pid: w.DWORD = 0;
        _ = w.GetWindowThreadProcessId(progman, &pid);

        var result: usize = 0;
        _ = w.SendMessageTimeoutW(progman, spawn_workerw_msg, 0xD, 0x1, w.SMTO_NORMAL, 1000, &result);

        if (w.getStyle(progman, w.GWL_EXSTYLE) & w.WS_EX_NOREDIRECTIONBITMAP != 0) {
            // Right after an Explorer restart the icon layer may not exist
            // yet; without it a wallpaper would go above the icons. Not
            // ready: the caller tries again.
            if (shellView(progman) == null) return error.DesktopLayerNotFound;
            return .{
                .progman = progman,
                .parent = progman,
                .layout = .raised,
                .explorer_pid = pid,
            };
        }

        // Explorer creates the WorkerW asynchronously; give it up to ~1 s.
        var attempt: u32 = 0;
        while (attempt < 20) : (attempt += 1) {
            var found: ?w.HWND = null;
            _ = w.EnumWindows(findClassicWorkerW, w.toLparam(&found));
            if (found) |workerw| return .{
                .progman = progman,
                .parent = workerw,
                .layout = .classic,
                .explorer_pid = pid,
            };
            w.Sleep(50);
        }
        return error.DesktopLayerNotFound;
    }

    /// Still attached to a live desktop layer?
    pub fn isValid(h: *const Host) bool {
        return w.IsWindow(h.parent) != 0 and w.IsWindow(h.progman) != 0;
    }

    /// Parents `hwnd` onto the desktop, covering `bounds` (virtual-screen coordinates).
    pub fn attach(h: *const Host, hwnd: w.HWND, bounds: Rect) Error!void {
        var style = w.getStyle(hwnd, w.GWL_STYLE);
        style &= ~(w.WS_POPUP | w.WS_OVERLAPPEDWINDOW);
        style |= w.WS_CHILD | w.WS_CLIPSIBLINGS;
        w.setStyle(hwnd, w.GWL_STYLE, style);

        var ex = w.getStyle(hwnd, w.GWL_EXSTYLE);
        ex &= ~w.WS_EX_APPWINDOW;
        ex |= w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE;
        // Raised layout: the layered bit must be set before SetParent.
        if (h.layout == .raised) ex |= w.WS_EX_LAYERED;
        w.setStyle(hwnd, w.GWL_EXSTYLE, ex);
        if (h.layout == .raised) _ = w.SetLayeredWindowAttributes(hwnd, 0, 255, w.LWA_ALPHA);

        _ = w.SetParent(hwnd, h.parent);
        if (w.GetAncestor(hwnd, w.GA_PARENT) != h.parent) return error.AttachFailed;

        try h.place(hwnd, bounds);
        _ = w.ShowWindow(hwnd, w.SW_SHOWNA);

        if (h.layout == .raised) if (w.FindWindowExW(h.progman, null, w.L("WorkerW"), null)) |ww| {
            _ = w.SetWindowPos(ww, w.HWND_BOTTOM, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
        };
    }

    /// Moves an attached window to `bounds` (virtual-screen coordinates).
    pub fn place(h: *const Host, hwnd: w.HWND, bounds: Rect) Error!void {
        var origin = [1]w.POINT{.{ .x = bounds.x, .y = bounds.y }};
        _ = w.MapWindowPoints(null, h.parent, &origin, 1);

        // Raised: directly beneath the icons. If the icon layer is gone
        // (Explorer is recreating it), say so: the caller attaches afresh.
        const view: ?w.HWND = if (h.layout == .raised) shellView(h.progman) orelse return error.DesktopLayerNotFound else null;
        const flags = w.SWP_NOACTIVATE | w.SWP_FRAMECHANGED | (if (view != null) 0 else w.SWP_NOZORDER);
        const after = view;
        if (w.SetWindowPos(hwnd, after, origin[0].x, origin[0].y, @intCast(bounds.w), @intCast(bounds.h), flags) == 0) // zsnag:ok — monitor-sized, far below c_int's range
            return error.AttachFailed;
    }
};

/// Raised layout: the icon layer, a child of Progman.
fn shellView(progman: w.HWND) ?w.HWND {
    return w.FindWindowExW(progman, null, w.L("SHELLDLL_DefView"), null);
}

/// The PID of the process owning the taskbar (Explorer), or 0 if it isn't running.
pub fn explorerPid() w.DWORD {
    const tray = w.FindWindowW(w.L("Shell_TrayWnd"), null) orelse return 0;
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(tray, &pid);
    return pid;
}

fn findClassicWorkerW(hwnd: w.HWND, l: w.LPARAM) callconv(.winapi) w.BOOL {
    if (w.FindWindowExW(hwnd, null, w.L("SHELLDLL_DefView"), null) == null) return 1;
    w.fromLparam(?w.HWND, l).* = w.FindWindowExW(null, hwnd, w.L("WorkerW"), null);
    return 0;
}
