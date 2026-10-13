// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The renderer lifecycle, as a pure state machine: no Win32, no clocks of
//! its own. The runtime feeds it events (a start attempt, "ready", the
//! connection ending, what the pause policy wants, timer ticks) with the
//! current time, and executes the `Command`s it returns.
//!
//! States:
//!   starting        a process was spawned (or is being spawned), not yet ready
//!   running         connected and obeying play/pause
//!   waiting_restart it crashed; `tick` asks for a respawn at `restart_at_ms`
//!   failed          it kept crashing soon after starting; nothing restarts it
//!   policy_stopped  stopped on purpose by a pause rule set to "stop";
//!                   relaxing that rule respawns it
//!
//! Rules that matter:
//! - A deliberate stop is never a crash: the connection ending afterwards is expected.
//! - Crash accounting measures from the *attempt*, so a renderer that never
//!   manages to start still reaches the give-up limit.
//! - It gives up after `give_up_after` short-lived runs in a row. A run that
//!   lasted longer than `stable_after_ms` resets the count, so only a renderer
//!   that never manages to stay up gives up, however slowly it crashes.
//! - Stronger pause actions apply at once; weaker ones wait `relax_ms`.
//! - A running renderer is pinged every `ping_every_ms`; one that hasn't
//!   answered within `answer_within_ms` is killed (stopped, or hung), and its
//!   end counts like any other crash.

const std = @import("std");
const Action = @import("zmural").policy.Action;

pub const State = enum { starting, running, waiting_restart, failed, policy_stopped };

pub const Config = struct {
    restart_base_ms: u64 = 2_000,
    restart_max_ms: u64 = 10_000,
    give_up_after: u32 = 5,
    stable_after_ms: u64 = 30_000,
    ping_every_ms: u64 = 5_000,
    answer_within_ms: u64 = 10_000,
};

/// What the runtime must do.
pub const Command = union(enum) {
    /// Start (or restart) the renderer process.
    spawn,
    /// Stop it on purpose: ask it to stop, then reap it.
    terminate,
    /// Play, muted or not (the user's own mute setting applies on top).
    play: struct { muted: bool },
    pause,
    /// Ask it to answer (`pong`).
    ping,
    /// It hasn't answered a ping in time: kill it. Its end follows as a crash.
    kill,
};

/// What happened when a connection ended, for the log.
pub const Outcome = union(enum) {
    /// Expected (a deliberate stop, or a duplicate notice): nothing to do.
    expected,
    restart_in_ms: u64,
    gave_up: u32,
};

pub const Supervisor = struct {
    cfg: Config = .{},
    state: State = .starting,
    /// The action the pause policy has in force.
    applied: Action = .none,
    /// A weaker action waiting for `relax_at_ms`.
    pending: ?Action = null,
    relax_at_ms: u64 = 0,
    last_attempt_ms: u64 = 0,
    restart_at_ms: u64 = 0,
    /// Short-lived runs in a row.
    crashes: u32 = 0,
    /// When the next ping goes out; 0 until the first tick after `ready`.
    ping_at_ms: u64 = 0,
    /// A ping not answered yet.
    pinged_at_ms: ?u64 = null,

    /// A new renderer, with the policy's current wish. False: it must not be
    /// spawned yet (the policy says "stop"); relaxing that later spawns it.
    pub fn begin(s: *Supervisor, want: Action) bool {
        s.applied = want;
        if (want == .stop) {
            s.state = .policy_stopped;
            return false;
        }
        return true;
    }

    /// A spawn attempt is starting now (whether or not it will succeed).
    pub fn attempting(s: *Supervisor, now: u64) void {
        s.state = .starting;
        s.last_attempt_ms = now;
        s.ping_at_ms = 0;
        s.pinged_at_ms = null;
    }

    /// It connected and said ready: put it into the policy's current state.
    pub fn ready(s: *Supervisor) Command {
        s.state = .running;
        return s.commandFor(s.applied);
    }

    /// Its connection ended, or the start attempt failed.
    pub fn ended(s: *Supervisor, now: u64) Outcome {
        switch (s.state) {
            .policy_stopped, .failed, .waiting_restart => return .expected,
            .starting, .running => {},
        }
        if (s.applied == .stop) {
            // It was meant to be stopped anyway: no restart, no crash.
            s.state = .policy_stopped;
            return .expected;
        }
        if (now -| s.last_attempt_ms > s.cfg.stable_after_ms) s.crashes = 0;
        s.crashes += 1;
        if (s.crashes >= s.cfg.give_up_after) {
            s.state = .failed;
            return .{ .gave_up = s.crashes };
        }
        const shift: u6 = @intCast(@min(s.crashes - 1, 16)); // zsnag:ok — clamped
        const delay = @min(s.cfg.restart_base_ms << shift, s.cfg.restart_max_ms);
        s.restart_at_ms = now + delay;
        s.state = .waiting_restart;
        return .{ .restart_in_ms = delay };
    }

    /// The pause policy now wants `want`.
    pub fn desire(s: *Supervisor, now: u64, want: Action, relax_ms: u64) ?Command {
        if (want == s.applied) {
            s.pending = null;
            return null;
        }
        if (@intFromEnum(want) > @intFromEnum(s.applied)) {
            s.pending = null;
            return s.apply(want);
        }
        if (s.pending == null or s.pending.? != want) {
            s.pending = want;
            s.relax_at_ms = now + relax_ms;
        }
        return null;
    }

    /// It answered a ping.
    pub fn pong(s: *Supervisor, now: u64) void {
        if (s.pinged_at_ms == null) return; // not one we are waiting for
        s.pinged_at_ms = null;
        s.ping_at_ms = now + s.cfg.ping_every_ms;
    }

    /// Timers: a relax that has come due, a ping, or a restart.
    pub fn tick(s: *Supervisor, now: u64) ?Command {
        if (s.pending) |a| if (now >= s.relax_at_ms) {
            s.pending = null;
            if (s.apply(a)) |c| return c;
        };
        if (s.state == .running) return s.heartbeat(now);
        if (s.state == .waiting_restart and now >= s.restart_at_ms) return .spawn;
        return null;
    }

    fn heartbeat(s: *Supervisor, now: u64) ?Command {
        if (s.pinged_at_ms) |at| {
            if (now -| at < s.cfg.answer_within_ms) return null;
            // No more pings to a process being killed; `attempting` resets this.
            s.pinged_at_ms = null;
            s.ping_at_ms = std.math.maxInt(u64);
            return .kill;
        }
        if (s.ping_at_ms == 0) {
            s.ping_at_ms = now + s.cfg.ping_every_ms;
            return null;
        }
        if (now < s.ping_at_ms) return null;
        s.pinged_at_ms = now;
        return .ping;
    }

    fn apply(s: *Supervisor, a: Action) ?Command {
        s.applied = a;
        switch (s.state) {
            .running => return s.commandFor(a),
            // `ready` applies it; only a stop needs acting on now.
            .starting => {
                if (a != .stop) return null;
                s.state = .policy_stopped;
                return .terminate;
            },
            // Cancel the pending restart if it's now meant to be stopped.
            .waiting_restart => {
                if (a == .stop) s.state = .policy_stopped;
                return null;
            },
            .policy_stopped => return if (a == .stop) null else .spawn,
            .failed => return null,
        }
    }

    fn commandFor(s: *Supervisor, a: Action) Command {
        return switch (a) {
            .none => .{ .play = .{ .muted = false } },
            .mute => .{ .play = .{ .muted = true } },
            .pause => .pause,
            .stop => blk: {
                s.state = .policy_stopped;
                break :blk .terminate;
            },
        };
    }
};

// ---- tests ------------------------------------------------------------------------

const testing = std.testing;

fn running(now: u64) Supervisor {
    var s: Supervisor = .{};
    _ = s.begin(.none);
    s.attempting(now);
    _ = s.ready();
    return s;
}

test "a stop rule terminates once, is never a crash, and resuming respawns (audit H1)" {
    var s = running(0);
    // A fullscreen game starts: the rule says stop.
    try testing.expectEqual(Command.terminate, s.desire(1_000, .stop, 400).?);
    try testing.expectEqual(State.policy_stopped, s.state);
    // The reader thread's final "connection ended" arrives afterwards.
    try testing.expectEqual(Outcome.expected, s.ended(1_010));
    try testing.expectEqual(@as(u32, 0), s.crashes);
    // Nothing restarts it while the game runs, however long.
    var t: u64 = 1_100;
    while (t < 120_000) : (t += 250) try testing.expectEqual(@as(?Command, null), s.tick(t));
    // The game exits: after the relax delay it is spawned again.
    try testing.expectEqual(@as(?Command, null), s.desire(120_000, .none, 400));
    try testing.expectEqual(Command.spawn, s.tick(120_400).?);
    s.attempting(120_400);
    try testing.expectEqual(Command{ .play = .{ .muted = false } }, s.ready());
}

test "a renderer that never starts gives up instead of retrying forever (audit M1)" {
    var s: Supervisor = .{};
    try testing.expect(s.begin(.none));
    // The machine has been up for hours; every start attempt fails at once.
    var now: u64 = 10 * 60 * 60 * 1000;
    var spawns: u32 = 0;
    var outcome: Outcome = .expected;
    while (spawns < 20) {
        s.attempting(now);
        spawns += 1;
        outcome = s.ended(now);
        if (outcome == .gave_up) break;
        now = s.restart_at_ms;
        try testing.expectEqual(Command.spawn, s.tick(now).?);
    }
    try testing.expectEqual(@as(u32, 5), spawns);
    try testing.expectEqual(State.failed, s.state);
    try testing.expectEqual(@as(?Command, null), s.tick(now + 1_000_000));
}

test "a renderer that crashes 25 s after every start gives up (audit #2 F4)" {
    var s = running(0);
    var now: u64 = 0;
    var outcome: Outcome = .expected;
    var runs: u32 = 0;
    while (runs < 20) {
        now += 25_000; // it runs 25 s, below the 30 s "stable" mark, then crashes
        runs += 1;
        outcome = s.ended(now);
        if (outcome == .gave_up) break;
        now = s.restart_at_ms;
        try testing.expectEqual(Command.spawn, s.tick(now).?);
        s.attempting(now);
        _ = s.ready();
    }
    try testing.expectEqual(@as(u32, 5), runs);
    try testing.expectEqual(State.failed, s.state);
}

test "a burst of crashes long after the first one still gives up (audit #2 F4)" {
    var s = running(0);
    _ = s.ended(1_000); // one early crash...
    var now = s.restart_at_ms;
    s.attempting(now);
    _ = s.ready();
    now += 10 * 60_000; // ...then ten stable minutes...
    var outcome: Outcome = .expected;
    var fast: u32 = 0;
    while (fast < 20) {
        fast += 1;
        outcome = s.ended(now + 500); // ...then it crashes right after each start
        if (outcome == .gave_up) break;
        now = s.restart_at_ms;
        s.attempting(now);
    }
    try testing.expectEqual(@as(u32, 5), fast);
}

test "backoff grows 2, 4, 8, 10 s" {
    var s = running(0);
    var now: u64 = 1_000;
    for ([_]u64{ 2_000, 4_000, 8_000, 10_000 }) |want| {
        const o = s.ended(now);
        try testing.expectEqual(want, o.restart_in_ms);
        now = s.restart_at_ms;
        s.attempting(now);
        _ = s.ready();
    }
}

test "a long, stable run resets the crash count" {
    var s = running(0);
    _ = s.ended(1_000);
    s.attempting(s.restart_at_ms);
    _ = s.ready();
    // It then runs for a minute before crashing again: that's a fresh first crash.
    try testing.expectEqual(@as(u64, 2_000), s.ended(s.last_attempt_ms + 60_000).restart_in_ms);
    try testing.expectEqual(@as(u32, 1), s.crashes);
}

test "weaker actions wait for the relax delay, stronger ones don't" {
    var s = running(0);
    try testing.expectEqual(Command.pause, s.desire(100, .pause, 400).?);
    try testing.expectEqual(@as(?Command, null), s.desire(200, .none, 400));
    try testing.expectEqual(@as(?Command, null), s.tick(500));
    try testing.expectEqual(Command{ .play = .{ .muted = false } }, s.tick(600).?);
    // A flicker back to pause before the delay cancels the pending resume.
    _ = s.desire(1_000, .pause, 400);
    _ = s.desire(1_100, .none, 400);
    try testing.expectEqual(@as(?Command, null), s.desire(1_200, .pause, 400));
    try testing.expectEqual(@as(?Command, null), s.tick(2_000));
    try testing.expectEqual(Action.pause, s.applied);
}

test "mute plays muted" {
    var s = running(0);
    try testing.expectEqual(Command{ .play = .{ .muted = true } }, s.desire(0, .mute, 400).?);
}

test "a stop while starting terminates at once; ready never overrides it" {
    var s: Supervisor = .{};
    _ = s.begin(.none);
    s.attempting(0);
    try testing.expectEqual(Command.terminate, s.desire(10, .stop, 400).?);
    try testing.expectEqual(Outcome.expected, s.ended(20));
    try testing.expectEqual(State.policy_stopped, s.state);
}

test "a stop while waiting to restart cancels the restart" {
    var s = running(0);
    _ = s.ended(1_000);
    try testing.expectEqual(State.waiting_restart, s.state);
    try testing.expectEqual(@as(?Command, null), s.desire(1_100, .stop, 400));
    try testing.expectEqual(@as(?Command, null), s.tick(s.restart_at_ms + 1));
    try testing.expectEqual(State.policy_stopped, s.state);
}

test "created while the policy says stop: not spawned until it relaxes" {
    var s: Supervisor = .{};
    try testing.expect(!s.begin(.stop));
    try testing.expectEqual(@as(?Command, null), s.tick(10_000));
    _ = s.desire(10_000, .none, 400);
    try testing.expectEqual(Command.spawn, s.tick(10_400).?);
}

test "ready applies whatever the policy wanted meanwhile" {
    var s: Supervisor = .{};
    _ = s.begin(.none);
    s.attempting(0);
    try testing.expectEqual(@as(?Command, null), s.desire(10, .pause, 400));
    try testing.expectEqual(Command.pause, s.ready());
}

test "a crash while a stop rule is in force is not counted" {
    var s = running(0);
    s.applied = .stop; // e.g. the stop command raced the crash
    try testing.expectEqual(Outcome.expected, s.ended(100));
    try testing.expectEqual(@as(u32, 0), s.crashes);
    try testing.expectEqual(State.policy_stopped, s.state);
}

test "duplicate end notices are harmless" {
    var s = running(0);
    _ = s.ended(100);
    try testing.expectEqual(Outcome.expected, s.ended(101));
    try testing.expectEqual(@as(u32, 1), s.crashes);
}

test "a renderer that answers its pings is left alone, however long it runs" {
    var s = running(0);
    var t: u64 = 0;
    var pings: u32 = 0;
    while (t < 10 * 60_000) : (t += 250) {
        const c = s.tick(t) orelse continue;
        try testing.expectEqual(Command.ping, c);
        pings += 1;
        s.pong(t + 30);
    }
    // One every 5 s and a bit (the answer's own delay): ten minutes, ~120.
    try testing.expect(pings >= 110 and pings <= 120);
}

test "a renderer that stops answering is killed 10 s after the ping, and that counts as a crash" {
    var s = running(0);
    try testing.expectEqual(@as(?Command, null), s.tick(0));
    try testing.expectEqual(Command.ping, s.tick(5_000).?);
    s.pong(5_010);
    try testing.expectEqual(Command.ping, s.tick(10_010).?);
    // Stopped now (SIGSTOP, a hang): no pong.
    var t: u64 = 10_010;
    while (t < 20_000) : (t += 250) try testing.expectEqual(@as(?Command, null), s.tick(t));
    try testing.expectEqual(Command.kill, s.tick(20_010).?);
    // Killed: no more pings, and no second kill, while it goes.
    try testing.expectEqual(@as(?Command, null), s.tick(60_000));
    try testing.expectEqual(@as(u64, 2_000), s.ended(60_100).restart_in_ms);
    // The new process is pinged afresh.
    s.attempting(s.restart_at_ms);
    _ = s.ready();
    try testing.expectEqual(@as(?Command, null), s.tick(62_200));
    try testing.expectEqual(Command.ping, s.tick(67_200).?);
}

test "a late pong after the kill, or one never asked for, changes nothing" {
    var s = running(0);
    s.pong(100);
    try testing.expectEqual(@as(?Command, null), s.tick(200));
    try testing.expectEqual(Command.ping, s.tick(5_200).?);
    try testing.expectEqual(Command.kill, s.tick(15_200).?);
    s.pong(15_300);
    try testing.expectEqual(@as(?Command, null), s.tick(30_000));
}

test "only a running renderer is pinged" {
    var s: Supervisor = .{};
    _ = s.begin(.none);
    s.attempting(0);
    var t: u64 = 0;
    while (t < 60_000) : (t += 250) try testing.expectEqual(@as(?Command, null), s.tick(t));
    // Stopped by a pause rule: nothing to ping either.
    s = running(0);
    _ = s.desire(100, .stop, 400);
    t = 100;
    while (t < 60_000) : (t += 250) try testing.expectEqual(@as(?Command, null), s.tick(t));
}

test "a paused renderer is still pinged: pausing doesn't stop it answering" {
    var s = running(0);
    try testing.expectEqual(Command.pause, s.desire(0, .pause, 400).?);
    try testing.expectEqual(@as(?Command, null), s.tick(100));
    try testing.expectEqual(Command.ping, s.tick(5_100).?);
}
