// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What to show when a wallpaper can't be played or shown (not a video at
//! all, a format nothing here reads): the last one that did play, or else
//! zmural's own (`starter.zig`). Never the broken one again, and never a
//! loop: if zmural's own can't play either, nothing changes.
//!
//! The runtimes note each wallpaper that reaches the screen (`played`) and
//! each one a renderer gives up on (`failed`); on their next tick, outside the
//! renderer's message handler, they take `pending` and switch.

const std = @import("std");

pub const Fallback = struct {
    /// The last wallpaper that reached the screen (owned).
    last_good: ?[]u8 = null,
    /// A wallpaper that just failed, waiting for the runtime's next tick (owned).
    failed_path: ?[]u8 = null,
    /// What its renderer said about it, cut to fit.
    message_buf: [300]u8 = undefined,
    message_len: usize = 0,
    /// The last wallpaper that failed, kept after `take` for `status` (owned).
    last_broken: ?[]u8 = null,
    /// The wallpapers the user was told about this run (owned): the same
    /// one failing again is logged, not notified again.
    told: std.ArrayList([]u8) = .empty,

    pub fn deinit(f: *Fallback, gpa: std.mem.Allocator) void {
        if (f.last_good) |p| gpa.free(p);
        if (f.failed_path) |p| gpa.free(p);
        if (f.last_broken) |p| gpa.free(p);
        for (f.told.items) |p| gpa.free(p);
        f.told.deinit(gpa);
        f.* = .{};
    }

    /// `path` was shown: it is the one to go back to from now on.
    pub fn played(f: *Fallback, gpa: std.mem.Allocator, path: []const u8) void {
        if (f.last_good) |p| if (std.mem.eql(u8, p, path)) return;
        const copy = gpa.dupe(u8, path) catch return; // keeps the older one
        if (f.last_good) |p| gpa.free(p);
        f.last_good = copy;
    }

    /// A renderer couldn't play `path`, and said `said`. Only the first
    /// failure before the next tick counts: several monitors share one file.
    pub fn failed(f: *Fallback, gpa: std.mem.Allocator, path: []const u8, said: []const u8) void {
        if (f.failed_path != null) return;
        f.failed_path = gpa.dupe(u8, path) catch null;
        f.message_len = @min(said.len, f.message_buf.len);
        @memcpy(f.message_buf[0..f.message_len], said[0..f.message_len]);
        if (gpa.dupe(u8, path)) |copy| {
            if (f.last_broken) |p| gpa.free(p);
            f.last_broken = copy;
        } else |_| {}
        // It can't be the one to go back to.
        if (f.last_good) |p| if (std.mem.eql(u8, p, path)) {
            gpa.free(p);
            f.last_good = null;
        };
    }

    /// `path` is being tried again (applied anew): an old failure of it no
    /// longer stands, so `status` doesn't report it before the new try ends.
    pub fn retrying(f: *Fallback, gpa: std.mem.Allocator, path: []const u8) void {
        const p = f.last_broken orelse return;
        if (!std.mem.eql(u8, p, path)) return;
        gpa.free(p);
        f.last_broken = null;
    }

    /// True the first time `path` fails this run as the main wallpaper (or,
    /// `main` false, as a monitor's own): tell the user then. The same again
    /// is news to nobody.
    pub fn firstTime(f: *Fallback, gpa: std.mem.Allocator, path: []const u8, main: bool) bool {
        const where: u8 = if (main) 'm' else 'o';
        for (f.told.items) |p| if (p[0] == where and std.mem.eql(u8, p[1..], path)) return false;
        if (f.told.items.len >= max_told) return false; // a run of hundreds of broken files: enough said
        const copy = std.mem.concat(gpa, u8, &.{ &.{where}, path }) catch return true;
        f.told.append(gpa, copy) catch {
            gpa.free(copy);
            return true;
        };
        return true;
    }

    const max_told = 64;

    /// What the renderer said about the last failure.
    pub fn message(f: *const Fallback) []const u8 {
        return f.message_buf[0..f.message_len];
    }

    /// The failure waiting to be dealt with, if any; the caller frees it.
    pub fn take(f: *Fallback) ?[]u8 {
        defer f.failed_path = null;
        return f.failed_path;
    }

    /// What to show instead of `broken`: the last wallpaper that played, else
    /// zmural's own (`starter`, null when it isn't installed). Null when
    /// there is nothing else: `broken` is zmural's own, or nothing played yet
    /// and zmural's own is missing.
    pub fn instead(f: *const Fallback, broken: []const u8, starter: ?[]const u8) ?[]const u8 {
        if (f.last_good) |p| if (!std.mem.eql(u8, p, broken)) return p;
        if (starter) |s| if (!std.mem.eql(u8, s, broken)) return s;
        return null;
    }
};

test "back to the last wallpaper that played, else zmural's own, never the broken one" {
    const gpa = std.testing.allocator;
    var f: Fallback = .{};
    defer f.deinit(gpa);
    const prism = "/opt/zmural/share/zmural/wallpapers/Prism.webm";

    // Nothing played yet: zmural's own.
    f.failed(gpa, "/v/broken.mp4", "cannot play: unrecognized file format");
    const first = f.take().?;
    defer gpa.free(first);
    try std.testing.expectEqualStrings(prism, f.instead(first, prism).?);
    try std.testing.expectEqualStrings("cannot play: unrecognized file format", f.message());
    try std.testing.expect(f.take() == null);

    // Something played: back to it, not to zmural's own.
    f.played(gpa, "/v/rain.mp4");
    f.played(gpa, "/v/sea.mp4");
    try std.testing.expectEqualStrings("/v/sea.mp4", f.instead("/v/broken.mp4", prism).?);

    // Several monitors report the same broken file: one switch.
    f.failed(gpa, "/v/broken.mp4", "cannot play: unrecognized file format");
    f.failed(gpa, "/v/other.mp4", "cannot play: unrecognized file format");
    const once = f.take().?;
    defer gpa.free(once);
    try std.testing.expectEqualStrings("/v/broken.mp4", once);

    // A file that played before and now can't (changed on disk): it is no
    // longer the one to go back to.
    f.failed(gpa, "/v/sea.mp4", "cannot play: unrecognized file format");
    gpa.free(f.take().?);
    try std.testing.expectEqualStrings(prism, f.instead("/v/sea.mp4", prism).?);

    // zmural's own can't play either (no decoder for it): nothing else, no loop.
    try std.testing.expect(f.instead(prism, prism) == null);
    // And with zmural's own missing, nothing either.
    try std.testing.expect(f.instead("/v/broken.mp4", null) == null);

    // Asked directly about the one that played last: never itself.
    f.played(gpa, "/v/sea.mp4");
    try std.testing.expectEqualStrings(prism, f.instead("/v/sea.mp4", prism).?);
}

test "the user is told once per broken file in a run" {
    const gpa = std.testing.allocator;
    var f: Fallback = .{};
    defer f.deinit(gpa);
    try std.testing.expect(f.firstTime(gpa, "/w/a.mp4", true));
    try std.testing.expect(!f.firstTime(gpa, "/w/a.mp4", true));
    try std.testing.expect(f.firstTime(gpa, "/w/a.mp4", false)); // on one monitor: another thing to say
    try std.testing.expect(!f.firstTime(gpa, "/w/a.mp4", false));
    try std.testing.expect(f.firstTime(gpa, "/w/b.mp4", true));
}
