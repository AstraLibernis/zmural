// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! System-wide facts for the pause rules on Linux, read over D-Bus:
//!
//! - `on_battery`: UPower's `OnBattery` (system bus).
//! - `power_saver`: the power profile is "power-saver" (power-profiles-daemon
//!   or tuned-ppd, under either of its bus names).
//! - `session_locked`: logind's `LockedHint` for our session, or the
//!   desktop's org.freedesktop.ScreenSaver (KDE) saying the locker is up.
//! - `session_inactive`: logind says our session isn't the active one
//!   (another user or a text console is in front).
//! - `remote_session`: logind says our session is remote.
//! - `game_mode`: Feral GameMode has at least one game registered.
//!
//! A watcher thread polls them every `poll_ms` on its own bus connections
//! and publishes the result in an atomic, so a slow or hung service never
//! stalls the main loop (which forwards every wallpaper frame). Services
//! that aren't running count as "no": nothing here starts one.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const dbus = zmural.os.dbus;
const policy = zmural.policy;

const log = std.log.scoped(.facts);

/// How often the facts are read. Lock and GameMode changes show up within this.
pub const poll_ms = 1000;

/// The conditions this watcher reports (the settings window offers these).
pub const reported = [_]policy.Condition{ .on_battery, .power_saver, .session_locked, .session_inactive, .remote_session, .game_mode };

/// One reading. Null: the service didn't answer (not installed, not running).
pub const Sample = struct {
    on_battery: ?bool = null,
    /// The power profile is "power-saver".
    power_saver: ?bool = null,
    locked_hint: ?bool = null,
    screensaver_active: ?bool = null,
    session_active: ?bool = null,
    session_remote: ?bool = null,
    game_mode_clients: ?u32 = null,
};

pub fn conditionsFrom(s: Sample) policy.Conditions {
    var c: policy.Conditions = .initEmpty();
    if (s.on_battery orelse false) c.insert(.on_battery);
    if (s.power_saver orelse false) c.insert(.power_saver);
    if ((s.locked_hint orelse false) or (s.screensaver_active orelse false)) c.insert(.session_locked);
    // Unknown counts as active: without logind there's no one else to be.
    if (!(s.session_active orelse true)) c.insert(.session_inactive);
    if (s.session_remote orelse false) c.insert(.remote_session);
    // An `i` property: a negative count (never sent, but) isn't a game.
    if (s.game_mode_clients) |n| if (n > 0 and n < 0x8000_0000) c.insert(.game_mode);
    return c;
}

pub const Watcher = struct {
    session_address: ?[]const u8,
    system_address: ?[]const u8,
    xdg_runtime_dir: ?[]const u8,
    /// `policy.Conditions` packed one bit per condition (see `pack`).
    bits: std.atomic.Value(u32) = .init(0),

    /// Starts the thread. It runs until the process exits.
    pub fn start(w: *Watcher) void {
        const t = std.Thread.spawn(.{}, run, .{w}) catch |err| {
            log.warn("no system facts (battery, lock, GameMode): {s}", .{@errorName(err)});
            return;
        };
        t.detach();
    }

    /// The latest facts.
    pub fn current(w: *const Watcher) policy.Conditions {
        return unpack(w.bits.load(.acquire));
    }

    fn run(w: *Watcher) void {
        var system: ?dbus.Conn = null;
        var session: ?dbus.Conn = null;
        var warned_system = false;
        while (true) {
            if (system == null) system = dbus.Conn.system(w.system_address) catch |err| blk: {
                if (!warned_system) log.info("no system bus ({s}): battery, power profile and session state aren't watched", .{@errorName(err)});
                warned_system = true;
                break :blk null;
            };
            if (session == null) session = dbus.Conn.session(w.session_address, w.xdg_runtime_dir) catch null;
            var s: Sample = .{};
            if (system) |*b| if (!readSystem(b, &s)) {
                b.close();
                system = null;
            };
            if (session) |*b| if (!readSession(b, &s)) {
                b.close();
                session = null;
            };
            w.bits.store(pack(conditionsFrom(s)), .release);
            const ts: linux.timespec = .{ .sec = poll_ms / 1000, .nsec = (poll_ms % 1000) * std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
        }
    }
};

/// Fills the system-bus part of `s`. False when the connection broke.
fn readSystem(b: *dbus.Conn, s: *Sample) bool {
    if (running(b, "org.freedesktop.UPower") orelse return false)
        s.on_battery = boolProp(b, "org.freedesktop.UPower", "/org/freedesktop/UPower", "org.freedesktop.UPower", "OnBattery") catch return false;
    // power-profiles-daemon 0.20+ took UPower's name; older ones use hadess's.
    const profiles = [_][3][]const u8{
        .{ "org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles" },
        .{ "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles" },
    };
    for (profiles) |p| {
        if (!(running(b, p[0]) orelse return false)) continue;
        const profile = stringProp(b, p[0], p[1], p[2], "ActiveProfile") catch return false;
        s.power_saver = if (profile) |name| std.mem.eql(u8, name, "power-saver") else null;
        break;
    }
    // "auto": the caller's session, or else the user's graphical one.
    const login = "org.freedesktop.login1";
    const path = "/org/freedesktop/login1/session/auto";
    const iface = "org.freedesktop.login1.Session";
    s.locked_hint = boolProp(b, login, path, iface, "LockedHint") catch |err| if (err == error.CallFailed) null else return false;
    s.session_active = boolProp(b, login, path, iface, "Active") catch |err| if (err == error.CallFailed) null else return false;
    s.session_remote = boolProp(b, login, path, iface, "Remote") catch |err| if (err == error.CallFailed) null else return false;
    return true;
}

/// Fills the session-bus part of `s`. False when the connection broke.
fn readSession(b: *dbus.Conn, s: *Sample) bool {
    if (running(b, "org.freedesktop.ScreenSaver") orelse return false) {
        const answer = b.call("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "GetActive", "", "") catch |err|
            if (err == error.CallFailed) @as(?[]const u8, null) else return false;
        if (answer) |body| {
            var r: dbus.Reader = .{ .body = body };
            s.screensaver_active = r.boolean() catch null;
        }
    }
    if (running(b, "com.feralinteractive.GameMode") orelse return false) {
        const v = b.getProperty("com.feralinteractive.GameMode", "/com/feralinteractive/GameMode", "com.feralinteractive.GameMode", "ClientCount") catch |err|
            if (err == error.CallFailed) dbus.Value.other else return false;
        if (v == .int) s.game_mode_clients = v.int;
    }
    return true;
}

/// Is `name` on the bus? Null when the connection broke. (Asking first
/// keeps D-Bus activation from starting a service just to ask it.)
fn running(b: *dbus.Conn, name: []const u8) ?bool {
    return b.nameHasOwner(name) catch |err| if (err == error.CallFailed) false else null;
}

fn boolProp(b: *dbus.Conn, dest: []const u8, path: []const u8, iface: []const u8, name: []const u8) dbus.Error!?bool {
    const v = try b.getProperty(dest, path, iface, name);
    return if (v == .boolean) v.boolean else null;
}

/// The bytes live in the connection's buffer until its next call: compare,
/// don't keep.
fn stringProp(b: *dbus.Conn, dest: []const u8, path: []const u8, iface: []const u8, name: []const u8) dbus.Error!?[]const u8 {
    const v = try b.getProperty(dest, path, iface, name);
    return if (v == .string) v.string else null;
}

fn pack(c: policy.Conditions) u32 {
    var bits: u32 = 0;
    for (std.enums.values(policy.Condition)) |k| {
        if (c.contains(k)) bits |= @as(u32, 1) << @intFromEnum(k);
    }
    return bits;
}

fn unpack(bits: u32) policy.Conditions {
    var c: policy.Conditions = .initEmpty();
    for (std.enums.values(policy.Condition)) |k| {
        if (bits & (@as(u32, 1) << @intFromEnum(k)) != 0) c.insert(k);
    }
    return c;
}

test conditionsFrom {
    try std.testing.expect(conditionsFrom(.{}).eql(.initEmpty()));
    const all = conditionsFrom(.{
        .on_battery = true,
        .power_saver = true,
        .locked_hint = true,
        .session_active = false,
        .session_remote = true,
        .game_mode_clients = 1,
    });
    for (reported) |k| try std.testing.expect(all.contains(k));
    try std.testing.expectEqual(reported.len, all.count());

    const none = conditionsFrom(.{
        .on_battery = false,
        .power_saver = false,
        .locked_hint = false,
        .screensaver_active = false,
        .session_active = true,
        .session_remote = false,
        .game_mode_clients = 0,
    });
    try std.testing.expectEqual(@as(usize, 0), none.count());
    // KDE's locker alone is enough; so is logind's hint alone.
    try std.testing.expect(conditionsFrom(.{ .screensaver_active = true }).contains(.session_locked));
    try std.testing.expect(conditionsFrom(.{ .locked_hint = true, .screensaver_active = false }).contains(.session_locked));
    try std.testing.expect(!conditionsFrom(.{ .game_mode_clients = 0xffff_ffff }).contains(.game_mode));
}

test "facts pack into the atomic and back" {
    var c: policy.Conditions = .initEmpty();
    try std.testing.expectEqual(@as(u32, 0), pack(c));
    c.insert(.game_mode);
    c.insert(.on_battery);
    try std.testing.expect(unpack(pack(c)).eql(c));
    const full: policy.Conditions = .initFull();
    try std.testing.expect(unpack(pack(full)).eql(full));
}
