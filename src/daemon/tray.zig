// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Tray menu items, platform-neutral. Every item that changes playback maps
//! onto a control request, so the tray and the CLI share one code path.
//!
//! Windows: `tray_windows.zig`. Linux (M6): StatusNotifierItem + dbusmenu.

const control = @import("zmural").protocol.control;

pub const Item = enum(usize) {
    // IDs start at 1: 0 means "menu dismissed".
    toggle_pause = 1,
    toggle_mute,
    next,
    previous,
    toggle_shuffle,
    rescan,
    open_settings,
    open_log,
    start_with_windows,
    quit,

    /// What the toggles flip from.
    pub const State = struct { paused: bool = false, muted: bool = false, shuffled: bool = false };

    /// The control request this item stands for, if any.
    pub fn request(item: Item, s: State) ?control.Request {
        return switch (item) {
            .toggle_pause => if (s.paused) .{ .play = .{} } else .{ .pause = .{} },
            .toggle_mute => .{ .set_muted = .{ .muted = !s.muted } },
            // Random counts as shuffled; switching off goes back to by name.
            .toggle_shuffle => .{ .set_rotation = .{ .order = if (s.shuffled) .sequential else .shuffle } },
            .next => .{ .next = .{} },
            .previous => .{ .previous = .{} },
            .rescan => .rescan,
            .quit => .quit,
            .open_settings, .open_log, .start_with_windows => null,
        };
    }
};

test "toggles flip the current state" {
    const std = @import("std");
    try std.testing.expect(Item.toggle_pause.request(.{}).? == .pause);
    try std.testing.expect(Item.toggle_pause.request(.{ .paused = true }).? == .play);
    try std.testing.expect(Item.toggle_mute.request(.{ .muted = true }).?.set_muted.muted == false);
    try std.testing.expect(Item.toggle_shuffle.request(.{}).?.set_rotation.order.? == .shuffle);
    try std.testing.expect(Item.toggle_shuffle.request(.{ .shuffled = true }).?.set_rotation.order.? == .sequential);
    try std.testing.expect(Item.toggle_shuffle.request(.{}).?.set_rotation.minutes == null);
    try std.testing.expect(Item.open_settings.request(.{}) == null);
}
