// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Where zmural processes find each other.
//!
//! - Windows: named pipes per user and session
//!   (`\\.\pipe\zmural-<SID>-s<session>-<endpoint>`), created with an ACL
//!   that only admits the current user (`pipe.zig`).
//! - Linux: Unix sockets in `$XDG_RUNTIME_DIR/zmural/` (a 0700 directory).
//!
//! There is deliberately no TCP listener: other users, and web pages
//! probing localhost, can't reach the daemon.
//!
//! The Windows pipes live in `pipe.zig`. Unix sockets with SCM_RIGHTS fd
//! passing come with the Linux MVP (M6).

const std = @import("std");

pub const Endpoint = enum {
    /// UI / CLI / tray -> daemon.
    control,
    /// Linux display hosts -> daemon.
    display,
};

/// Formats the endpoint address. `scope` is `<SID>-s<session>` on Windows
/// (`identity.scope`) and `$XDG_RUNTIME_DIR` elsewhere.
pub fn address(buf: []u8, os: std.Target.Os.Tag, endpoint: Endpoint, scope: []const u8) error{NoSpaceLeft}![]u8 {
    return switch (os) {
        .windows => std.fmt.bufPrint(buf, "\\\\.\\pipe\\zmural-{s}-{s}", .{ scope, @tagName(endpoint) }),
        else => std.fmt.bufPrint(buf, "{s}/zmural/{s}.sock", .{ scope, @tagName(endpoint) }),
    };
}

test address {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "\\\\.\\pipe\\zmural-alice-control",
        try address(&buf, .windows, .control, "alice"),
    );
    try std.testing.expectEqualStrings(
        "/run/user/1000/zmural/display.sock",
        try address(&buf, .linux, .display, "/run/user/1000"),
    );
}
