// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Display hosts: what puts wallpaper pixels behind the desktop icons.
//!
//! - Windows: `windows/workerw.zig` runs inside the daemon and parents
//!   renderer windows under Explorer's WorkerW layer. DWM composites them.
//! - Linux: display hosts are separate processes that speak
//!   `protocol.ww_display` (the layer-shell client in `linux/layer_shell/`,
//!   which is zmural in its `--layer-shell` mode; the KDE plugin; the GNOME
//!   extension). `linux/backend.zig` picks one.

const std = @import("std");
const builtin = @import("builtin");

pub const windows = @import("windows/windows.zig");
pub const linux = @import("linux/backend.zig");
/// The layer-shell display host, run as `zmural --layer-shell` (Linux).
pub const layer_shell = if (builtin.os.tag == .linux) @import("linux/layer_shell/main.zig") else struct {};

pub const native_name = switch (builtin.os.tag) {
    .windows => "windows-workerw (in-process)",
    .linux => "linux (external display host)",
    else => "unsupported",
};

test {
    std.testing.refAllDecls(@This());
}
