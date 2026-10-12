// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zmural's wire protocols. All three share one framing (`wire.zig`); each
//! message set is a tagged union whose tag values are the opcodes.
//!
//! | protocol | between                        |
//! |----------|--------------------------------|
//! | control  | UI / CLI / tray <-> zmural    |
//! | renderer | zmural <-> renderer process   |
//! | ww_display | zmural <-> Linux display host (waywallen-display-v1 v9; its own framing) |
//!
//! Every hello/welcome carries a version plus a capability list, and clients
//! check capabilities instead of comparing version strings.

const std = @import("std");
const builtin = @import("builtin");

pub const wire = @import("wire.zig");
pub const transport = @import("transport.zig");
/// Windows named-pipe transport.
pub const pipe = @import("pipe.zig");
/// Unix-socket transport with fd passing (Linux).
pub const unix = @import("unix.zig");
pub const control = @import("control.zig");
pub const renderer = @import("renderer.zig");
/// waywallen-display-v1 (v9): the Linux display protocol, shared with waywallen's KDE/GNOME clients.
pub const ww_display = @import("ww_display.zig");

test {
    std.testing.refAllDecls(@This());
    if (builtin.os.tag == .windows) _ = @import("pipe_test.zig");
}
