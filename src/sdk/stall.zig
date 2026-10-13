// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Notices a player that stopped by itself while it was meant to play, so
//! the renderer can end and the daemon start it again.
//!
//! The sign is mpv's `core-idle` while `pause` is off. A video whose file was
//! cut short while it played leaves mpv seeking forever, idle, with no
//! error and no end of file: the wallpaper freezes. Slow content is not idle:
//! a still picture shown forever or a GIF that holds one frame for a long
//! time keeps mpv's core busy, so neither is mistaken for a hang. A short
//! idle (opening the file, the seek back to the start of each loop) is
//! normal; only `limit_ms` of it in a row counts.

const std = @import("std");
const mpv = @import("../os/libmpv.zig");

pub const limit_ms: u64 = 10_000;
/// How often a renderer looks, while it plays.
pub const check_every_ms: u64 = 1_000;

pub const Stall = struct {
    /// When the player was first seen stuck, in this streak.
    since_ms: ?u64 = null,

    /// `stuck`: it is meant to play, and its player is idle. True once that
    /// has lasted `limit_ms`.
    pub fn check(s: *Stall, now: u64, stuck: bool) bool {
        if (!stuck) {
            s.since_ms = null;
            return false;
        }
        const since = s.since_ms orelse {
            s.since_ms = now;
            return false;
        };
        return now -| since >= limit_ms;
    }
};

/// mpv's playback core is idle: paused, or stopped by itself.
pub fn coreIdle(api: *const mpv.Api, h: *mpv.Handle) bool {
    const raw = api.get_property_string(h, "core-idle") orelse return false;
    defer api.free(raw);
    return std.mem.eql(u8, std.mem.span(raw), "yes");
}

const testing = std.testing;

test "idle for 10 s in a row is a stall; less is not" {
    var s: Stall = .{};
    try testing.expect(!s.check(0, true));
    try testing.expect(!s.check(9_999, true));
    try testing.expect(s.check(10_000, true));
}

test "any moment not idle starts the count again" {
    var s: Stall = .{};
    var t: u64 = 0;
    // Idle 6 s, playing a moment (the seek back to the start of a loop
    // ended), idle 6 s again, for a minute: never 10 s in a row.
    while (t < 60_000) : (t += 1_000) {
        const stuck = (t / 1_000) % 7 != 6;
        try testing.expect(!s.check(t, stuck));
    }
}

test "a stall is reported on every check until it ends" {
    var s: Stall = .{};
    _ = s.check(0, true);
    try testing.expect(s.check(10_000, true));
    try testing.expect(s.check(11_000, true));
    try testing.expect(!s.check(12_000, false));
    try testing.expect(!s.check(13_000, true));
}
