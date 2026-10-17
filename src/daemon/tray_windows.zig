// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The tray icon and its menu (Windows): Shell_NotifyIconW with
//! NOTIFYICON_VERSION_4 callbacks, and a TrackPopupMenuEx menu that returns
//! the chosen `tray.Item`.

const std = @import("std");
const zmural = @import("zmural");
const w = zmural.os.win32;
const Item = @import("tray.zig").Item;

pub const MenuState = struct {
    /// Shown greyed out at the top (the current wallpaper's file name).
    title: []const u8,
    paused: bool,
    muted: bool,
    shuffled: bool,
    library_count: usize,
    autostart: bool,
};

pub const Tray = struct {
    data: w.NOTIFYICONDATAW,
    shown: bool = false,
    /// A menu is open (TrackPopupMenuEx is modal and pumps messages).
    menu_open: bool = false,

    pub fn init(hwnd: w.HWND, callback_msg: w.UINT) Tray {
        var data: w.NOTIFYICONDATAW = .{
            .hWnd = hwnd,
            .uID = 1,
            .uFlags = w.NIF_MESSAGE | w.NIF_ICON | w.NIF_TIP | w.NIF_SHOWTIP,
            .uCallbackMessage = callback_msg,
            .hIcon = appIcon(),
        };
        data.uVersion = w.NOTIFYICON_VERSION_4;
        return .{ .data = data };
    }

    /// Adds the icon (again, after Explorer restarts).
    pub fn show(t: *Tray) void {
        t.shown = w.Shell_NotifyIconW(w.NIM_ADD, &t.data) != 0;
        if (t.shown) {
            _ = w.Shell_NotifyIconW(w.NIM_SETVERSION, &t.data);
        } else {
            std.log.warn("tray: could not add the icon", .{});
        }
    }

    /// After "TaskbarCreated": a new Explorer has no icon, so add it again; the
    /// same message on a DPI change finds it still there, so modify it.
    pub fn restore(t: *Tray) void {
        if (w.Shell_NotifyIconW(w.NIM_MODIFY, &t.data) != 0) {
            t.shown = true;
            return;
        }
        t.show();
        if (t.shown) std.log.info("tray: icon added again (new taskbar)", .{});
    }

    pub fn setTip(t: *Tray, tip: []const u8) void {
        writeUtf16(&t.data.szTip, tip);
        if (t.shown) _ = w.Shell_NotifyIconW(w.NIM_MODIFY, &t.data);
    }

    /// A balloon (a notification, on Windows 10 and 11) from the icon. Its
    /// text goes in the log too: Do Not Disturb drops balloons unseen.
    pub fn balloon(t: *Tray, title: []const u8, text: []const u8) void {
        if (!t.shown) return;
        std.log.info("notice: {s}: {s}", .{ title, text });
        var d = t.data;
        d.uFlags = w.NIF_INFO;
        writeUtf16(&d.szInfoTitle, title);
        writeUtf16(&d.szInfo, text);
        d.dwInfoFlags = w.NIIF_WARNING;
        if (w.Shell_NotifyIconW(w.NIM_MODIFY, &d) == 0) std.log.warn("tray: could not show a notification", .{});
    }

    pub fn hide(t: *Tray) void {
        if (t.shown) _ = w.Shell_NotifyIconW(w.NIM_DELETE, &t.data);
        t.shown = false;
    }

    /// What a callback message asks for: the settings window (left click,
    /// or Enter on the focused icon), the menu (right click, or the menu key),
    /// or nothing. With NOTIFYICON_VERSION_4 a left click also sends
    /// WM_LBUTTONUP; only NIN_SELECT counts, so one click is one request.
    pub fn wants(lp: w.LPARAM) Wish {
        const event: w.UINT = @truncate(@as(usize, @bitCast(lp)));
        return switch (event & 0xFFFF) {
            w.NIN_SELECT, w.NIN_KEYSELECT => .window,
            w.WM_CONTEXTMENU => .menu,
            else => .nothing,
        };
    }

    pub const Wish = enum { nothing, window, menu };

    /// Shows the menu at the cursor; returns the chosen item, or null.
    pub fn menu(t: *Tray, state: MenuState) ?Item {
        if (t.menu_open) return null;
        t.menu_open = true;
        defer t.menu_open = false;
        const hmenu = w.CreatePopupMenu() orelse return null;
        defer _ = w.DestroyMenu(hmenu);

        var title_buf: [96:0]u16 = undefined;
        writeUtf16(&title_buf, if (state.title.len == 0) "zmural: no wallpaper" else state.title);
        _ = w.AppendMenuW(hmenu, w.MF_STRING | w.MF_GRAYED, 0, &title_buf);
        _ = w.AppendMenuW(hmenu, w.MF_SEPARATOR, 0, null);
        _ = w.AppendMenuW(hmenu, w.MF_STRING | (if (state.paused) w.MF_CHECKED else 0), @backingInt(Item.toggle_pause), w.L("Paused"));
        _ = w.AppendMenuW(hmenu, w.MF_STRING | (if (state.muted) w.MF_CHECKED else 0), @backingInt(Item.toggle_mute), w.L("Muted"));
        const no_library = if (state.library_count == 0) w.MF_GRAYED else 0;
        _ = w.AppendMenuW(hmenu, w.MF_STRING | no_library, @backingInt(Item.next), w.L("> Next"));
        _ = w.AppendMenuW(hmenu, w.MF_STRING | no_library, @backingInt(Item.previous), w.L("< Previous"));
        _ = w.AppendMenuW(hmenu, w.MF_STRING | (if (state.shuffled) w.MF_CHECKED else 0), @backingInt(Item.toggle_shuffle), w.L("Shuffle"));
        _ = w.AppendMenuW(hmenu, w.MF_SEPARATOR, 0, null);
        _ = w.AppendMenuW(hmenu, w.MF_STRING, @backingInt(Item.rescan), w.L("Rescan library"));
        _ = w.AppendMenuW(hmenu, w.MF_STRING | (if (state.autostart) w.MF_CHECKED else 0), @backingInt(Item.start_with_windows), w.L("Start with Windows"));
        _ = w.AppendMenuW(hmenu, w.MF_STRING, @backingInt(Item.open_settings), w.L("Settings..."));
        _ = w.AppendMenuW(hmenu, w.MF_STRING, @backingInt(Item.open_log), w.L("Open log file"));
        _ = w.AppendMenuW(hmenu, w.MF_SEPARATOR, 0, null);
        _ = w.AppendMenuW(hmenu, w.MF_STRING, @backingInt(Item.quit), w.L("Quit zmural"));

        var at: w.POINT = undefined;
        _ = w.GetCursorPos(&at);
        const hwnd = t.data.hWnd.?;
        // Without this the menu won't close when you click elsewhere (a known Win32 quirk).
        _ = w.SetForegroundWindow(hwnd);
        const chosen = w.TrackPopupMenuEx(hmenu, w.TPM_RETURNCMD | w.TPM_RIGHTBUTTON | w.TPM_NONOTIFY, at.x, at.y, hwnd, null);
        _ = w.PostMessageW(hwnd, w.WM_NULL, 0, 0);
        if (chosen <= 0) return null;
        return std.enums.fromInt(Item, @as(usize, @intCast(chosen))); // zsnag:ok — chosen > 0 checked above
    }
};

/// zmural's own icon (resource 1) at the tray's size, else the stock one.
fn appIcon() ?w.HICON {
    const small = w.LoadImageW(w.GetModuleHandleW(null), 1, w.IMAGE_ICON, w.GetSystemMetrics(w.SM_CXSMICON), w.GetSystemMetrics(w.SM_CYSMICON), 0);
    if (small) |icon| return @ptrCast(icon);
    return w.LoadIconW(null, w.IDI_APPLICATION);
}

/// UTF-8 into a fixed, NUL-terminated UTF-16 buffer, truncating with "..." if needed.
fn writeUtf16(buf: []u16, s: []const u8) void {
    // utf8ToUtf16Le assumes the output fits, so measure first.
    const fits = if (std.unicode.calcUtf16LeLen(s)) |len| len < buf.len else |_| false;
    const n = if (fits) std.unicode.utf8ToUtf16Le(buf, s) catch unreachable else blk: { // zsnag:ok — calcUtf16LeLen already validated s
        // Too long or not UTF-8: a lossy ASCII copy with an ellipsis.
        const keep = @min(s.len, buf.len - 4);
        for (s[0..keep], buf[0..keep]) |c, *o| o.* = if (c < 0x80) c else '?';
        @memcpy(buf[keep..][0..3], &[_]u16{ '.', '.', '.' });
        break :blk keep + 3;
    };
    buf[n] = 0;
}

test "a left click opens the window once; a right click opens the menu (audit L10)" {
    try std.testing.expectEqual(Tray.Wish.window, Tray.wants(w.NIN_SELECT));
    try std.testing.expectEqual(Tray.Wish.window, Tray.wants(w.NIN_KEYSELECT));
    try std.testing.expectEqual(Tray.Wish.menu, Tray.wants(w.WM_CONTEXTMENU));
    try std.testing.expectEqual(Tray.Wish.nothing, Tray.wants(w.WM_LBUTTONUP));
}

test writeUtf16 {
    var buf: [8]u16 = undefined;
    writeUtf16(&buf, "abc");
    try std.testing.expectEqualSlices(u16, &[_]u16{ 'a', 'b', 'c', 0 }, buf[0..4]);
    writeUtf16(&buf, "a much longer title");
    try std.testing.expectEqualSlices(u16, &[_]u16{ 'a', ' ', 'm', 'u', '.', '.', '.', 0 }, &buf);
}
