// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What zmural hands the settings window when it opens it. Every slice must
//! live as long as the process: the window runs on its own thread.

const std = @import("std");

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// zmural's log file, for the General page's row.
    log_path: []const u8 = "",
    /// `ZMURAL_THEME=dark|light` overrides the desktop's theme.
    force_dark: ?bool = null,
    /// Open on the Welcome page: zmural's first run. zmural clears it once
    /// the window has opened.
    welcome: bool = false,

    // Linux only.
    runtime_dir: []const u8 = "",
    home: []const u8 = "/",
    config_home: ?[]const u8 = null,
    cache_home: ?[]const u8 = null,
    exe_dir: []const u8 = "",
    dbus_address: ?[]const u8 = null,
    wayland_display: ?[]const u8 = null,
    /// Testing aid: `ZMURAL_TEST_PICK=<path>` answers every file picker with
    /// that path (a picker is the desktop's own window, which the headless
    /// test rigs can't drive); `@<file>` with what that file holds then.
    test_pick: ?[]const u8 = null,
    /// Testing aid: `ZMURAL_TEST_CONTROLS=<path>` keeps that file listing
    /// where each control is (`gui.writeDrawn`), for rigs that click them.
    test_controls: ?[]const u8 = null,
};
