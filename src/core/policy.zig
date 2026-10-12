// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Pause policy: each condition maps to an action (none / mute / pause / stop)
//! and a scope (this monitor, or all monitors). The strongest action wins.
//!
//! This module is pure. The daemon collects the facts (display hosts report
//! per-monitor window state; OS probes report battery, lock, GameMode...),
//! calls `decide`, and applies resume delays when an action relaxes.

const std = @import("std");

pub const Condition = enum {
    // Reported per monitor.
    fullscreen,
    maximized,
    covered,
    focused,
    // System-wide.
    app_rule,
    on_battery,
    power_saver,
    session_locked,
    session_inactive,
    remote_session,
    game_mode,
    other_audio,
};

/// Ordered weakest to strongest.
pub const Action = enum(u8) {
    none,
    mute,
    pause,
    /// Kill the renderer. The only honest option for app/game wallpapers,
    /// which can't be paused safely.
    stop,

    pub fn max(a: Action, b: Action) Action {
        return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
    }
};

pub const Scope = enum { monitor, all };

pub const Rule = struct {
    action: Action = .none,
    scope: Scope = .monitor,
};

pub const Conditions = std.EnumSet(Condition);

pub const Policy = struct {
    rules: std.EnumArray(Condition, Rule),

    /// Game-first defaults: a fullscreen app anywhere pauses every monitor.
    pub fn default() Policy {
        var r = std.EnumArray(Condition, Rule).initFill(.{});
        r.set(.fullscreen, .{ .action = .pause, .scope = .all });
        r.set(.maximized, .{ .action = .pause });
        r.set(.covered, .{ .action = .pause });
        r.set(.app_rule, .{ .action = .pause, .scope = .all });
        r.set(.on_battery, .{ .action = .pause, .scope = .all });
        r.set(.power_saver, .{ .action = .pause, .scope = .all });
        r.set(.session_locked, .{ .action = .pause, .scope = .all });
        r.set(.session_inactive, .{ .action = .pause, .scope = .all });
        r.set(.remote_session, .{ .action = .pause, .scope = .all });
        r.set(.game_mode, .{ .action = .pause, .scope = .all });
        r.set(.other_audio, .{ .action = .mute, .scope = .all });
        return .{ .rules = r };
    }

    /// `system` holds the active system-wide conditions and `monitors[i]` the
    /// active conditions reported for monitor i. Writes one action per monitor.
    pub fn decide(p: *const Policy, system: Conditions, monitors: []const Conditions, out: []Action) void {
        std.debug.assert(out.len == monitors.len);

        var everywhere: Action = .none;
        var sys = system.iterator();
        while (sys.next()) |c| everywhere = everywhere.max(p.rules.get(c).action);
        for (monitors) |m| {
            var it = m.iterator();
            while (it.next()) |c| {
                const r = p.rules.get(c);
                if (r.scope == .all) everywhere = everywhere.max(r.action);
            }
        }

        for (monitors, out) |m, *o| {
            var a = everywhere;
            var it = m.iterator();
            while (it.next()) |c| {
                const r = p.rules.get(c);
                if (r.scope == .monitor) a = a.max(r.action);
            }
            o.* = a;
        }
    }

    /// Of the `active` conditions, those whose rule is one of `actions`: what
    /// is holding the wallpaper back, for `status`.
    pub fn ruledBy(p: *const Policy, active: Conditions, actions: []const Action) Conditions {
        var out = Conditions.initEmpty();
        var it = active.iterator();
        while (it.next()) |c| {
            if (std.mem.findScalar(Action, actions, p.rules.get(c).action) != null) out.insert(c);
        }
        return out;
    }
};

fn set(cs: []const Condition) Conditions {
    var s = Conditions.initEmpty();
    for (cs) |c| s.insert(c);
    return s;
}

test "nothing active means play everywhere" {
    const p = Policy.default();
    var out: [2]Action = undefined;
    p.decide(set(&.{}), &.{ set(&.{}), set(&.{}) }, &out);
    try std.testing.expectEqualSlices(Action, &.{ .none, .none }, &out);
}

test "covered pauses only that monitor" {
    const p = Policy.default();
    var out: [2]Action = undefined;
    p.decide(set(&.{}), &.{ set(&.{.covered}), set(&.{}) }, &out);
    try std.testing.expectEqualSlices(Action, &.{ .pause, .none }, &out);
}

test "fullscreen game pauses every monitor" {
    const p = Policy.default();
    var out: [3]Action = undefined;
    p.decide(set(&.{}), &.{ set(&.{}), set(&.{.fullscreen}), set(&.{}) }, &out);
    try std.testing.expectEqualSlices(Action, &.{ .pause, .pause, .pause }, &out);
}

test "status names the rules that pause or mute, not the ones set to nothing" {
    const p = Policy.default();
    const active = set(&.{ .fullscreen, .focused, .other_audio, .game_mode });
    const pausing = p.ruledBy(active, &.{ .pause, .stop });
    try std.testing.expect(pausing.eql(set(&.{ .fullscreen, .game_mode })));
    try std.testing.expect(p.ruledBy(active, &.{.mute}).eql(set(&.{.other_audio})));
}

test "strongest action wins" {
    var p = Policy.default();
    p.rules.set(.maximized, .{ .action = .stop });
    var out: [2]Action = undefined;
    p.decide(set(&.{.other_audio}), &.{ set(&.{.maximized}), set(&.{}) }, &out);
    try std.testing.expectEqualSlices(Action, &.{ .stop, .mute }, &out);
}
