// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The compositor's own account of its windows, where zmural can read it:
//! Sway, Hyprland or Wayfire, each over its IPC socket. It beats the display
//! host's window list (wlr-foreign-toplevel), which can't see workspaces or
//! where windows are: with it, a fullscreen window on a hidden workspace no
//! longer pauses the wallpaper, `covered` works, and so does the app rule.
//! Niri's IPC gives only the app in front (`compositor_niri.zig`).

const std = @import("std");
const linux = std.os.linux;
const sway = @import("compositor_sway.zig");
const hyprland = @import("compositor_hyprland.zig");
const wayfire = @import("compositor_wayfire.zig");

const log = std.log.scoped(.compositor);

pub const Facts = sway.Facts;

/// Where each compositor's socket is, from zmural's environment.
pub const Env = struct {
    runtime_dir: []const u8,
    /// `$SWAYSOCK`.
    swaysock: ?[]const u8 = null,
    /// `$HYPRLAND_INSTANCE_SIGNATURE`.
    hyprland_signature: ?[]const u8 = null,
    /// `$WAYFIRE_SOCKET`, set only while Wayfire's `ipc` plugin runs.
    wayfire_socket: ?[]const u8 = null,
    /// `$XDG_CURRENT_DESKTOP`, to tell Wayfire without its IPC apart.
    current_desktop: []const u8 = "",
};

pub const Watch = union(enum) {
    sway: sway.Watch,
    hyprland: hyprland.Watch,
    wayfire: wayfire.Watch,

    pub fn name(w: *const Watch) []const u8 {
        return switch (w.*) {
            .sway => "Sway",
            .hyprland => "Hyprland",
            .wayfire => "Wayfire",
        };
    }

    /// Readable whenever something changed.
    pub fn events(w: *const Watch) linux.fd_t {
        return switch (w.*) {
            inline else => |s| s.events,
        };
    }

    /// Reads the events that are waiting; false when the compositor closed
    /// the connection.
    pub fn drain(w: *Watch) bool {
        return switch (w.*) {
            inline else => |*s| s.drain(),
        };
    }

    /// The windows, read now.
    pub fn query(w: *Watch) !Facts {
        return switch (w.*) {
            inline else => |*s| s.query(),
        };
    }

    pub fn stop(w: *Watch) void {
        switch (w.*) {
            inline else => |*s| s.stop(),
        }
    }
};

/// The watch for the compositor zmural runs on, or null where none answers
/// (another compositor, or Wayfire without its IPC plugins: the log says
/// which to turn on).
pub fn start(gpa: std.mem.Allocator, env: Env) ?Watch {
    if (nonEmpty(env.swaysock)) |sock| {
        if (sway.Watch.start(gpa, sock)) |w| return .{ .sway = w } else |err| log.warn("Sway's IPC ({s}) doesn't answer: {s}", .{ sock, @errorName(err) });
    }
    if (nonEmpty(env.hyprland_signature)) |sig| {
        if (hyprland.Watch.start(gpa, env.runtime_dir, sig)) |w| return .{ .hyprland = w } else |err| log.warn("Hyprland's IPC ({s}/hypr/{s}) doesn't answer: {s}", .{ env.runtime_dir, sig, @errorName(err) });
    }
    if (nonEmpty(env.wayfire_socket)) |sock| {
        if (wayfire.Watch.start(gpa, sock)) |w| return .{ .wayfire = w } else |err| switch (err) {
            error.NoIpcRules => log.warn("Wayfire's ipc-rules plugin is off: turn it on (plugins = ... ipc ipc-rules in wayfire.ini) for workspace-aware pausing and the app rule", .{}),
            else => log.warn("Wayfire's IPC ({s}) doesn't answer: {s}", .{ sock, @errorName(err) }),
        }
    } else if (std.ascii.findIgnoreCase(env.current_desktop, "wayfire") != null) {
        log.warn("Wayfire's ipc plugin is off: turn on ipc and ipc-rules (plugins in wayfire.ini) for workspace-aware pausing and the app rule", .{});
    }
    return null;
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}
