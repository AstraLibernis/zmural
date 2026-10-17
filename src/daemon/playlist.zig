// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Playlist cursor: which item plays next. Items are indices into whatever
//! list the caller keeps. Rotation timing lives in the daemon.
//!
//! Used by `rotation.zig` for shuffle and random; sequential goes by the
//! library's own order.

const std = @import("std");

pub const Mode = enum {
    /// In order, wrapping around.
    sequential,
    /// Every item once per cycle, in a random order. A new cycle never starts
    /// with the item that just played.
    shuffle,
    /// Any item except the current one.
    random,
};

pub const Playlist = struct {
    len: usize,
    mode: Mode,
    /// Play order for sequential/shuffle.
    order: []usize,
    /// Index into `order` (sequential/shuffle) or the item itself (random).
    pos: ?usize = null,
    prng: std.Random.DefaultPrng,

    pub fn init(gpa: std.mem.Allocator, len: usize, mode: Mode, seed: u64) !Playlist {
        const order = try gpa.alloc(usize, len);
        for (order, 0..) |*o, i| o.* = i;
        var p: Playlist = .{ .len = len, .mode = mode, .order = order, .prng = .init(seed) };
        if (mode == .shuffle) p.prng.random().shuffle(usize, p.order);
        return p;
    }

    pub fn deinit(p: *Playlist, gpa: std.mem.Allocator) void {
        gpa.free(p.order);
    }

    pub fn current(p: *const Playlist) ?usize {
        const i = p.pos orelse return null;
        return if (p.mode == .random) i else p.order[i];
    }

    pub fn next(p: *Playlist) ?usize {
        if (p.len == 0) return null;
        switch (p.mode) {
            .sequential => p.pos = if (p.pos) |i| (i + 1) % p.len else 0,
            .shuffle => {
                const i = if (p.pos) |i| i + 1 else 0;
                if (i == p.len) {
                    p.reshuffle(p.order[p.len - 1]);
                    p.pos = 0;
                } else p.pos = i;
            },
            .random => p.pos = p.pickOther(),
        }
        return p.current();
    }

    pub fn previous(p: *Playlist) ?usize {
        if (p.len == 0) return null;
        switch (p.mode) {
            .sequential, .shuffle => p.pos = if (p.pos) |i| (if (i == 0) p.len - 1 else i - 1) else 0,
            .random => p.pos = p.pickOther(),
        }
        return p.current();
    }

    fn pickOther(p: *Playlist) usize {
        const r = p.prng.random();
        const cur = p.pos orelse return r.uintLessThan(usize, p.len);
        if (p.len == 1) return 0;
        const j = r.uintLessThan(usize, p.len - 1);
        return if (j >= cur) j + 1 else j;
    }

    fn reshuffle(p: *Playlist, last_played: usize) void {
        p.prng.random().shuffle(usize, p.order);
        if (p.len > 1 and p.order[0] == last_played) std.mem.swap(usize, &p.order[0], &p.order[p.len - 1]);
    }
};

test "sequential wraps both ways" {
    const gpa = std.testing.allocator;
    var p = try Playlist.init(gpa, 3, .sequential, 1);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(?usize, 0), p.next());
    try std.testing.expectEqual(@as(?usize, 1), p.next());
    try std.testing.expectEqual(@as(?usize, 2), p.next());
    try std.testing.expectEqual(@as(?usize, 0), p.next());
    try std.testing.expectEqual(@as(?usize, 2), p.previous());
}

test "shuffle plays each item once per cycle" {
    const gpa = std.testing.allocator;
    var p = try Playlist.init(gpa, 8, .shuffle, 42);
    defer p.deinit(gpa);
    var last: ?usize = null;
    for (0..4) |_| {
        var seen: [8]bool = @splat(false);
        for (0..8) |k| {
            const i = p.next().?;
            try std.testing.expect(!seen[i]);
            if (k == 0) try std.testing.expect(last != i);
            seen[i] = true;
            last = i;
        }
    }
}

test "random never repeats back to back" {
    const gpa = std.testing.allocator;
    var p = try Playlist.init(gpa, 3, .random, 7);
    defer p.deinit(gpa);
    var prev = p.next().?;
    for (0..200) |_| {
        const i = p.next().?;
        try std.testing.expect(i != prev and i < 3);
        prev = i;
    }
}

test "empty playlist yields nothing" {
    const gpa = std.testing.allocator;
    var p = try Playlist.init(gpa, 0, .shuffle, 0);
    defer p.deinit(gpa);
    try std.testing.expectEqual(@as(?usize, null), p.next());
}
