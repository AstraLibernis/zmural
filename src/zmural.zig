// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zmural shared library: wire protocols, platform-neutral core logic, OS
//! bindings and the renderer SDK. Every zmural executable imports this as
//! `@import("zmural")`.

const std = @import("std");

/// From build.zig.zon, via the build script.
pub const version = @import("build_options").version;

pub const protocol = @import("protocol/protocol.zig");

pub const layout = @import("core/layout.zig");
pub const coverage = @import("core/coverage.zig");
pub const policy = @import("core/policy.zig");
pub const monitor = @import("core/monitor.zig");
pub const manifest = @import("core/manifest.zig");
pub const properties = @import("core/properties.zig");
pub const toml = @import("core/toml.zig");
pub const media = @import("core/media.zig");
/// Lively Wallpaper packages converted to zmural's own on import.
pub const lively = @import("core/lively.zig");
/// Unpacking a `.zip` wallpaper package, checked first (`zmural-console import`).
pub const package_zip = @import("core/package_zip.zig");

/// OS bindings. Each is only referenced from its own OS's code paths.
pub const os = struct {
    /// Wayland wire client (Linux display host).
    pub const wayland = @import("os/wayland.zig");
    /// GBM/EGL/GLES DMA-BUF render targets (Linux renderers; needs libc).
    pub const gpu = @import("os/gpu.zig");
    /// DRM sync objects (explicit GPU sync on Linux).
    pub const syncobj = @import("os/syncobj.zig");
    /// Minimal D-Bus client (Linux): bus names, signals, notifications.
    pub const dbus = @import("os/dbus.zig");
    pub const win32 = @import("os/win32.zig");
    pub const desktop = @import("os/desktop.zig");
    pub const process = @import("os/process.zig");
    pub const libmpv = @import("os/libmpv.zig");
    pub const logfile = @import("os/logfile.zig");
    /// Crashes into the log file, from every mode of the program.
    pub const crashlog = @import("os/crashlog.zig");
    /// The Linux log file: stderr plus a capped file with local timestamps.
    pub const logfile_linux = @import("os/logfile_linux.zig");
    /// Local time from the zone file, without libc (Linux log timestamps).
    pub const localtime = @import("os/localtime.zig");
    pub const autostart = @import("os/autostart.zig");
    /// The Start menu shortcut and the Settings > Apps entry (Windows).
    pub const apps_windows = @import("os/apps_windows.zig");
    /// Start at login on Linux (an XDG autostart entry).
    pub const autostart_linux = @import("os/autostart_linux.zig");
    pub const identity = @import("os/identity.zig");
    /// XDG base directory variables (empty or relative = unset).
    pub const xdg = @import("os/xdg.zig");
};

pub const sdk = struct {
    pub const renderer = @import("sdk/renderer.zig");
    pub const testpattern = @import("sdk/testpattern.zig");
    /// Windows renderer runtime for video and images (`--renderer video|image`).
    pub const windows_renderer = @import("sdk/windows_renderer.zig");
    pub const web_renderer = @import("sdk/web_renderer.zig");
    /// Linux renderer runtime (DMA-BUF surfaces) for video and images.
    pub const linux_renderer = @import("sdk/linux_renderer.zig");
    pub const mpv_options = @import("sdk/mpv_options.zig");
    /// Windows control-protocol client (CLI, second daemon instance).
    pub const control_client = @import("sdk/control_client.zig");
    /// Linux control-protocol client (CLI, a second zmural).
    pub const control_client_linux = @import("sdk/control_client_linux.zig");
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(sdk);
    std.testing.refAllDecls(os);
}
