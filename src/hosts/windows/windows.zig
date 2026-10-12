// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Windows display host: runs inside the daemon. DWM composites the
//! wallpaper windows, so there is no frame copy.

pub const win32 = @import("zmural").os.win32;
pub const monitors = @import("monitors.zig");
pub const workerw = @import("workerw.zig");
pub const facts = @import("facts.zig");
pub const Host = workerw.Host;

test {
    @import("std").testing.refAllDecls(@This());
}
