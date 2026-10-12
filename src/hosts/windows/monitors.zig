// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Monitor enumeration, in physical pixels (the process must be per-monitor
//! DPI aware v2) and virtual-screen coordinates.

const std = @import("std");
const w = @import("zmural").os.win32;
const Rect = @import("zmural").layout.Rect;

pub const max = 16;

pub const Monitor = struct {
    rect: Rect,
    primary: bool,
    /// GDI device name, e.g. `\\.\DISPLAY1` (UTF-16, NUL-terminated).
    device: [32]u16,
};

pub const List = struct {
    items: [max]Monitor = undefined,
    len: usize = 0,

    pub fn slice(l: *const List) []const Monitor {
        return l.items[0..l.len];
    }
};

pub fn enumerate() List {
    var list: List = .{};
    _ = w.EnumDisplayMonitors(null, null, onMonitor, w.toLparam(&list));
    return list;
}

fn onMonitor(handle: w.HMONITOR, _: ?w.HDC, _: *w.RECT, l: w.LPARAM) callconv(.winapi) w.BOOL {
    const list = w.fromLparam(List, l);
    if (list.len == max) return 0;
    var info = std.mem.zeroes(w.MONITORINFOEXW);
    info.cbSize = @sizeOf(w.MONITORINFOEXW);
    if (w.GetMonitorInfoW(handle, &info) == 0) return 1;
    list.items[list.len] = .{
        .rect = toRect(info.rcMonitor),
        .primary = info.dwFlags & w.MONITORINFOF_PRIMARY != 0,
        .device = info.szDevice,
    };
    list.len += 1;
    return 1;
}

pub fn toRect(r: w.RECT) Rect {
    return .{ .x = r.left, .y = r.top, .w = @intCast(r.right - r.left), .h = @intCast(r.bottom - r.top) };
}
