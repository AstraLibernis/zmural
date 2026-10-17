// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What the pause policy wants from one renderer, on every OS.

const std = @import("std");
const zmural = @import("zmural");
const policy = zmural.policy;
const Action = policy.Action;
const MonitorId = zmural.monitor.Id;
const Router = @import("router.zig").Router;
const RendererId = @import("router.zig").RendererId;

/// The weakest action any of this renderer's monitors wants: a renderer
/// shared by several monitors keeps playing while any of them can see it.
/// `monitors[i]` are the conditions on the monitor `ids[i]`. The user's own
/// pause applies on top.
pub fn forRenderer(
    p: *const policy.Policy,
    system: policy.Conditions,
    ids: []const MonitorId,
    monitors: []const policy.Conditions,
    router: *const Router,
    renderer: RendererId,
    user_paused: bool,
) Action {
    std.debug.assert(ids.len == monitors.len);
    var decided: [64]Action = undefined;
    const n = @min(ids.len, decided.len);
    p.decide(system, monitors[0..n], decided[0..n]);
    var result: ?Action = null;
    for (ids[0..n], decided[0..n]) |id, a| {
        if (router.rendererFor(id) != renderer) continue;
        result = if (result) |cur| (if (@backingInt(a) < @backingInt(cur)) a else cur) else a;
    }
    var want = result orelse .none;
    if (user_paused) want = want.max(.pause);
    return want;
}

/// What `status` says holds the wallpaper back: the active rules that pause
/// (or stop) it and those that mute it, as condition names joined by ", ".
pub const Held = struct {
    paused_by: []const u8,
    muted_by: []const u8,
};

pub fn held(buf: []u8, p: *const policy.Policy, active: policy.Conditions) Held {
    var w: std.Io.Writer = .fixed(buf);
    const a = names(&w, p.ruledBy(active, &.{ .pause, .stop }));
    const b = names(&w, p.ruledBy(active, &.{.mute}));
    const out = w.buffered();
    return .{ .paused_by = out[0..a], .muted_by = out[a..][0..b] };
}

fn names(w: *std.Io.Writer, set: policy.Conditions) usize {
    const start = w.end;
    var it = set.iterator();
    while (it.next()) |c| {
        if (w.end > start) w.writeAll(", ") catch break;
        w.writeAll(@tagName(c)) catch break;
    }
    return w.end - start;
}

test "status gets the pausing and muting rules by name" {
    var buf: [256]u8 = undefined;
    const p = policy.Policy.default();
    var active: policy.Conditions = .empty;
    active.insert(.fullscreen);
    active.insert(.game_mode);
    active.insert(.other_audio);
    active.insert(.focused);
    const h = held(&buf, &p, active);
    try std.testing.expectEqualStrings("fullscreen, game_mode", h.paused_by);
    try std.testing.expectEqualStrings("other_audio", h.muted_by);
    const none = held(&buf, &p, .empty);
    try std.testing.expectEqualStrings("", none.paused_by);
}

test "a shared renderer plays while any of its monitors can see it" {
    const gpa = std.testing.allocator;
    var r: Router = .{};
    defer r.deinit(gpa);
    const a = zmural.monitor.fromConnector("DP-1");
    const b = zmural.monitor.fromConnector("DP-2");
    const id = (try r.assign(gpa, a, "x.mp4", 0)).renderer;
    _ = try r.assign(gpa, b, "x.mp4", 0);

    const p = policy.Policy.default();
    var covered: policy.Conditions = .empty;
    covered.insert(.maximized);
    const none: policy.Conditions = .empty;

    const want = forRenderer(&p, none, &.{ a, b }, &.{ covered, none }, &r, id, false);
    try std.testing.expectEqual(Action.none, want);
    try std.testing.expectEqual(Action.pause, forRenderer(&p, none, &.{ a, b }, &.{ none, none }, &r, id, true));
}
