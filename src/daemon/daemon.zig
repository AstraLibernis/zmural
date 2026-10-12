// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The daemon's top-level state and (eventually) its event loop.
//!
//! Status: only the non-Windows entry point uses this; it is a placeholder
//! until the Linux MVP (M6). Windows runs `runtime_windows.zig`.
//!
//! Planned startup order:
//! 1. single-instance check: if a daemon is already running, hand off to it
//! 2. load settings + library
//! 3. start the watchdog (kills orphaned renderers if we die)
//! 4. open the control endpoint (`protocol.transport`)
//! 5. start the platform display host (Windows: WorkerW; Linux: spawn or wait
//!    for a display host)
//! 6. start the pause-fact probes (window events, power, session, GameMode)
//! 7. restore each monitor's last wallpaper

const std = @import("std");
const zmural = @import("zmural");
const hosts = @import("hosts");
const Settings = @import("settings.zig").Settings;
const Library = @import("library.zig").Library;
const Router = @import("router.zig").Router;

pub const Daemon = struct {
    gpa: std.mem.Allocator,
    settings: Settings = .{},
    library: Library,
    router: Router = .{},

    pub fn init(gpa: std.mem.Allocator) Daemon {
        return .{ .gpa = gpa, .library = .init(gpa) };
    }

    pub fn deinit(d: *Daemon) void {
        d.router.deinit(d.gpa);
        d.library.deinit();
    }

    pub fn run(d: *Daemon) !void {
        d.router.share = d.settings.share_renderers;
        std.debug.print(
            \\zmural {s} (scaffold)
            \\  display host : {s}
            \\  fps cap      : {d}
            \\The event loop is not implemented yet.
            \\
        , .{ zmural.version, hosts.native_name, d.settings.fps_cap });
    }
};
