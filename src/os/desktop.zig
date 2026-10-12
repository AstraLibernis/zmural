// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Desktop helpers shared by the daemon's WorkerW host and the watchdog.

const w = @import("win32.zig");

/// Win11 24H2+ "raised desktop": Progman hosts the icon layer and WorkerW as children.
pub fn isRaisedLayout() bool {
    const progman = w.FindWindowW(w.L("Progman"), null) orelse return false;
    return w.getStyle(progman, w.GWL_EXSTYLE) & w.WS_EX_NOREDIRECTIONBITMAP != 0;
}

/// Repaints the static wallpaper so no frame of a closed live wallpaper
/// lingers. It only invalidates the desktop's own windows: re-setting the
/// wallpaper path (what some tools do) would end a slideshow or Spotlight
/// background and cut long paths. Nothing to do in the raised layout, where
/// DWM shows the static wallpaper again by itself.
pub fn refreshStaticWallpaper() void {
    if (isRaisedLayout()) return;
    const progman = w.FindWindowW(w.L("Progman"), null) orelse return;
    _ = w.RedrawWindow(progman, null, null, w.RDW_INVALIDATE | w.RDW_ERASE | w.RDW_ALLCHILDREN | w.RDW_UPDATENOW);
    // The classic layout paints the wallpaper in a top-level WorkerW.
    var workerw: ?w.HWND = null;
    while (true) {
        workerw = w.FindWindowExW(null, workerw, w.L("WorkerW"), null);
        const h = workerw orelse break;
        _ = w.RedrawWindow(h, null, null, w.RDW_INVALIDATE | w.RDW_ERASE | w.RDW_ALLCHILDREN | w.RDW_UPDATENOW);
    }
}
