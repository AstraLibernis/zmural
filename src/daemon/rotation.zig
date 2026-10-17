// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Timed wallpaper changes, and the order Next/Previous take through the
//! library (sequential, shuffle or random). Shared by both runtimes: they
//! call `due` every tick and `step` to pick what comes next.
//!
//! Only playing time counts. While every wallpaper is paused or stopped (by
//! the user or a pause rule), or no monitor shows one, the clock waits, so a
//! game session doesn't come back to a different wallpaper each time.

const std = @import("std");
const library = @import("library.zig");
const Library = library.Library;
const Playlist = @import("playlist.zig").Playlist;
const Order = @import("zmural").protocol.control.Order;

/// Longer gaps between ticks (a stalled loop, a suspended PC) count as this much.
const max_tick_gap_ms = 5_000;

pub const Rotation = struct {
    /// The play order for shuffle/random, over library indices. Rebuilt when
    /// the library or the order changes.
    playlist: ?Playlist = null,
    /// Playing time since the last change.
    elapsed_ms: u64 = 0,
    last_tick_ms: ?u64 = null,

    pub fn deinit(r: *Rotation, gpa: std.mem.Allocator) void {
        r.forget(gpa);
    }

    /// The library's contents changed: the next shuffle starts a new round.
    pub fn forget(r: *Rotation, gpa: std.mem.Allocator) void {
        if (r.playlist) |*p| p.deinit(gpa);
        r.playlist = null;
    }

    /// The wallpaper to show after (or before) `current`. Null when the
    /// library is empty. `seed` is only used when a new order is drawn.
    pub fn step(r: *Rotation, gpa: std.mem.Allocator, lib: *const Library, current: ?[]const u8, order: Order, forward: bool, seed: u64) ?[]const u8 {
        const items = lib.paths.items;
        if (order == .sequential or items.len < 2) {
            r.forget(gpa);
            return lib.step(current, forward);
        }
        const mode: @import("playlist.zig").Mode = switch (order) {
            .sequential => unreachable, // handled above
            .shuffle => .shuffle,
            .random => .random,
        };
        if (r.playlist) |p| if (p.len != items.len or p.mode != mode) r.forget(gpa);
        if (r.playlist == null) r.playlist = Playlist.init(gpa, items.len, mode, seed) catch return lib.step(current, forward);
        const p = &r.playlist.?;
        // A fresh order may start on what's showing (it was picked by hand, or
        // the round just ended there): skip it. Two draws are always enough,
        // since neither mode repeats an item back to back.
        for (0..2) |_| {
            const i = (if (forward) p.next() else p.previous()) orelse return null;
            if (current == null or !library.samePath(items[i], current.?)) return items[i];
        }
        return lib.step(current, forward);
    }

    /// Call on every wallpaper change, timed or not: the clock starts over.
    pub fn restart(r: *Rotation) void {
        r.elapsed_ms = 0;
    }

    /// Call every tick. True when `minutes` of playing time have passed
    /// since the last change; the clock then starts over.
    pub fn due(r: *Rotation, now_ms: u64, minutes: u16, playing: bool) bool {
        const last = r.last_tick_ms;
        r.last_tick_ms = now_ms;
        if (minutes == 0) {
            r.elapsed_ms = 0;
            return false;
        }
        if (playing) if (last) |l| {
            r.elapsed_ms += @min(now_ms -| l, max_tick_gap_ms);
        };
        if (r.elapsed_ms < intervalMs(minutes)) return false;
        r.elapsed_ms = 0;
        return true;
    }

    /// Playing time left until the next timed change, in seconds (0 when off).
    pub fn remainingS(r: *const Rotation, minutes: u16) u32 {
        if (minutes == 0) return 0;
        const left = intervalMs(minutes) -| r.elapsed_ms;
        return @intCast((left + 999) / 1000); // zsnag:ok — at most a week of seconds
    }
};

fn intervalMs(minutes: u16) u64 {
    return @as(u64, minutes) * std.time.ms_per_min;
}

fn testLibrary(gpa: std.mem.Allocator, names: []const []const u8) !Library {
    var l: Library = .init(gpa);
    errdefer l.deinit();
    for (names) |n| try l.paths.append(l.arena.allocator(), n);
    return l;
}

/// Ticks every 250 ms (as the runtimes do) from `t.*` for `ms`; true if any tick fired.
fn run(r: *Rotation, t: *u64, ms: u64, minutes: u16, playing: bool) bool {
    var fired = false;
    const end = t.* + ms;
    while (t.* < end) {
        t.* += 250;
        if (r.due(t.*, minutes, playing)) fired = true;
    }
    return fired;
}

test "the clock counts playing time only, and restarts after a change" {
    var r: Rotation = .{};
    var t: u64 = 0;
    try std.testing.expect(!r.due(t, 1, true));
    try std.testing.expect(!run(&r, &t, 30_000, 1, true));
    // Paused for an hour: no time counts.
    try std.testing.expect(!run(&r, &t, std.time.ms_per_hour, 1, false));
    try std.testing.expectEqual(@as(u32, 30), r.remainingS(1));
    try std.testing.expect(!run(&r, &t, 29_750, 1, true));
    try std.testing.expect(r.due(t + 250, 1, true));
    t += 250;
    try std.testing.expectEqual(@as(u32, 60), r.remainingS(1));
    // A manual change starts the clock over.
    try std.testing.expect(!run(&r, &t, 50_000, 1, true));
    r.restart();
    try std.testing.expect(!run(&r, &t, 59_750, 1, true));
    try std.testing.expect(run(&r, &t, 250, 1, true));
}

test "off never fires, and a long stall counts as a short gap" {
    var r: Rotation = .{};
    var t: u64 = 0;
    while (t < 10 * std.time.ms_per_hour) : (t += 250) try std.testing.expect(!r.due(t, 0, true));
    try std.testing.expectEqual(@as(u32, 0), r.remainingS(0));
    // Turned on, then the loop stalls for a day.
    try std.testing.expect(!r.due(t, 5, true));
    try std.testing.expect(!r.due(t + std.time.ms_per_day, 5, true));
    try std.testing.expectEqual(@as(u32, 5 * 60 - 5), r.remainingS(5));
}

test "the longest interval fires after exactly a week of playing" {
    var r: Rotation = .{};
    const max = @import("zmural").protocol.control.max_rotate_minutes;
    var t: u64 = 0;
    _ = r.due(t, max, true);
    const week = @as(u64, max) * std.time.ms_per_min;
    while (t + 5_000 < week) {
        t += 5_000;
        try std.testing.expect(!r.due(t, max, true));
    }
    try std.testing.expect(r.due(week, max, true));
}

test "shuffle shows every wallpaper once per round, never the current one twice in a row" {
    const gpa = std.testing.allocator;
    const names = [_][]const u8{ "/w/a", "/w/b", "/w/c", "/w/d", "/w/e" };
    var lib = try testLibrary(gpa, &names);
    defer lib.deinit();
    var r: Rotation = .{};
    defer r.deinit(gpa);
    var cur: []const u8 = "/w/c"; // picked by hand
    for (0..6) |round| {
        var seen: [names.len]bool = @splat(false);
        for (0..names.len) |k| {
            const next = r.step(gpa, &lib, cur, .shuffle, true, 99).?;
            try std.testing.expect(!std.mem.eql(u8, next, cur));
            const i = for (names, 0..) |n, i| {
                if (std.mem.eql(u8, n, next)) break i;
            } else unreachable;
            // The first round may skip the hand-picked one; later rounds are whole.
            if (round > 0) try std.testing.expect(!seen[i]);
            seen[i] = true;
            cur = next;
            _ = k;
        }
    }
}

test "random never repeats; sequential is the library's order" {
    const gpa = std.testing.allocator;
    var lib = try testLibrary(gpa, &.{ "/w/a", "/w/b", "/w/c" });
    defer lib.deinit();
    var r: Rotation = .{};
    defer r.deinit(gpa);
    var cur: []const u8 = "/w/a";
    for (0..300) |_| {
        const next = r.step(gpa, &lib, cur, .random, true, 5).?;
        try std.testing.expect(!std.mem.eql(u8, next, cur));
        cur = next;
    }
    try std.testing.expectEqualStrings("/w/b", r.step(gpa, &lib, "/w/a", .sequential, true, 5).?);
    try std.testing.expectEqualStrings("/w/c", r.step(gpa, &lib, "/w/a", .sequential, false, 5).?);
    try std.testing.expect(r.playlist == null);
}

test "a library that changes size gets a new order; tiny libraries still step" {
    const gpa = std.testing.allocator;
    var lib = try testLibrary(gpa, &.{ "/w/a", "/w/b", "/w/c" });
    defer lib.deinit();
    var r: Rotation = .{};
    defer r.deinit(gpa);
    _ = r.step(gpa, &lib, null, .shuffle, true, 1).?;
    try lib.paths.append(lib.arena.allocator(), "/w/d");
    _ = r.step(gpa, &lib, null, .shuffle, true, 1).?;
    try std.testing.expectEqual(@as(usize, 4), r.playlist.?.len);

    var one = try testLibrary(gpa, &.{"/w/only"});
    defer one.deinit();
    try std.testing.expectEqualStrings("/w/only", r.step(gpa, &one, "/w/only", .shuffle, true, 1).?);
    var none = try testLibrary(gpa, &.{});
    defer none.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), r.step(gpa, &none, null, .random, true, 1));
}
