// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Which program is in front (Linux), for the "one of your apps is in front"
//! pause rule.
//!
//! Wayland tells a client nothing about other clients' windows, so each
//! desktop needs its own source. On KDE Plasma it is a small KWin script,
//! loaded over D-Bus, that calls `org.zmural.Daemon1.Foreground` with the
//! active window's process id whenever it changes. Other desktops have no
//! source yet, and the rule isn't offered there.
//!
//! An app rule names a program the way the process list does ("steam",
//! "eldenring.exe" under Proton), so the process id is turned into its names
//! through /proc and compared with those.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const dbus = zmural.os.dbus;

const log = std.log.scoped(.foreground);

pub const bus_path = "/org/zmural/Daemon";
pub const bus_iface = "org.zmural.Daemon1";
const member = "Foreground";
const plugin_name = "zmural-foreground";
const script_file = "kwin-foreground.js";

/// Strings, because KWin's `callDBus` picks the D-Bus type of a number itself.
const script =
    \\function tell(w) {
    \\    callDBus("org.zmural.Daemon", "/org/zmural/Daemon", "org.zmural.Daemon1", "Foreground",
    \\             w ? String(w.pid) : "0", w ? String(w.resourceClass) : "");
    \\}
    \\workspace.windowActivated.connect(tell);
    \\tell(workspace.activeWindow);
    \\
;

/// The program in front, by every name an app rule might use.
pub const Front = struct {
    pid: linux.pid_t = 0,
    /// The kernel's name for the process (at most 15 bytes).
    comm: [16]u8 = undefined,
    comm_len: usize = 0,
    /// The file name of its executable.
    exe: [256]u8 = undefined,
    exe_len: usize = 0,
    /// The file name it was started as (a Windows game under Wine keeps its
    /// own name here while the executable is Wine's).
    arg0: [256]u8 = undefined,
    arg0_len: usize = 0,

    /// Reads the names of `pid`. A process that is gone has none.
    pub fn of(pid: linux.pid_t) Front {
        var f: Front = .{ .pid = pid };
        if (pid <= 0) return f;
        var path_buf: [48]u8 = undefined;
        var buf: [4096]u8 = undefined;

        if (readProc(&path_buf, &buf, pid, "comm")) |text| {
            const short = std.mem.trimEnd(u8, text, "\n");
            f.comm_len = @min(short.len, f.comm.len);
            @memcpy(f.comm[0..f.comm_len], short[0..f.comm_len]);
        }
        if (readProc(&path_buf, &buf, pid, "cmdline")) |text| {
            // Wine passes Windows paths: "Z:\games\x.exe".
            const first = std.mem.sliceTo(text, 0);
            const base = if (std.mem.findLastAny(u8, first, "/\\")) |i| first[i + 1 ..] else first;
            f.arg0_len = @min(base.len, f.arg0.len);
            @memcpy(f.arg0[0..f.arg0_len], base[0..f.arg0_len]);
        }
        const link = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/exe", .{pid}, 0) catch return f;
        const rc = linux.readlink(link, &buf, buf.len);
        if (linux.errno(rc) == .SUCCESS) {
            const base = std.fs.path.basename(buf[0..rc]);
            f.exe_len = @min(base.len, f.exe.len);
            @memcpy(f.exe[0..f.exe_len], base[0..f.exe_len]);
        }
        return f;
    }

    /// Is this program one of `rules`?
    pub fn isOneOf(f: *const Front, rules: []const []const u8) bool {
        for (rules) |rule| {
            if (named(rule, f.exe[0..f.exe_len]) or named(rule, f.arg0[0..f.arg0_len])) return true;
            // The kernel cuts its name at 15 bytes: a longer rule matches by that much.
            const comm = f.comm[0..f.comm_len];
            if (comm.len == 15 and rule.len > 15) {
                if (std.ascii.eqlIgnoreCase(rule[0..15], comm)) return true;
            } else if (named(rule, comm)) return true;
        }
        return false;
    }

    /// For the log.
    pub fn name(f: *const Front) []const u8 {
        if (f.arg0_len > 0) return f.arg0[0..f.arg0_len];
        if (f.comm_len > 0) return f.comm[0..f.comm_len];
        return "(none)";
    }
};

fn named(rule: []const u8, candidate: []const u8) bool {
    return candidate.len > 0 and std.ascii.eqlIgnoreCase(rule, candidate);
}

fn readProc(path_buf: []u8, buf: []u8, pid: linux.pid_t, file: []const u8) ?[]const u8 {
    const path = std.fmt.bufPrintSentinel(path_buf, "/proc/{d}/{s}", .{ pid, file }, 0) catch return null;
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc); // zsnag:ok — a successful open returns a small non-negative fd
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return buf[0..n];
}

/// Asks KWin to report the active window from now on. False when it can't
/// (no KWin on the bus, or it refused): the rule then never fires.
pub fn startKde(bus: *dbus.Conn, runtime_dir: []const u8) bool {
    var path_buf: [300]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/zmural/" ++ script_file, .{runtime_dir}, 0) catch return false;
    if (!writeFile(path, script)) {
        log.warn("can't write {s}", .{path});
        return false;
    }
    // KWin reads the file when it runs the script; nothing needs it after.
    defer _ = linux.unlink(path);
    stopKde(bus); // one left over by a zmural that didn't exit cleanly

    var buf: [512]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    w.string(path) catch return false;
    w.string(plugin_name) catch return false;
    const answer = bus.call("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "loadScript", "ss", w.written()) catch |err| {
        log.info("KWin's scripting isn't reachable ({s} {s}): the app rule won't fire", .{ @errorName(err), bus.lastError() });
        return false;
    };
    var r: dbus.Reader = .{ .body = answer };
    const raw = r.u32_() catch return false;
    const id: i32 = @bitCast(raw);
    if (id < 0) {
        log.warn("KWin didn't load the foreground script", .{});
        return false;
    }
    var obj_buf: [48]u8 = undefined;
    const obj = std.fmt.bufPrint(&obj_buf, "/Scripting/Script{d}", .{id}) catch return false;
    _ = bus.call("org.kde.KWin", obj, "org.kde.kwin.Script", "run", "", "") catch |err| {
        log.warn("KWin didn't run the foreground script ({s} {s})", .{ @errorName(err), bus.lastError() });
        return false;
    };
    log.info("KWin reports the app in front (for the app rule)", .{});
    return true;
}

pub fn stopKde(bus: *dbus.Conn) void {
    var buf: [64]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    w.string(plugin_name) catch return;
    _ = bus.call("org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting", "unloadScript", "s", w.written()) catch {}; // zsnag:ok — not loaded, or KWin is gone: both fine
}

/// A `Foreground` call from the desktop: the process now in front (0: none).
/// Null if `m` is something else.
pub fn onMessage(c: *dbus.Conn, m: dbus.Message) ?linux.pid_t {
    if (m.kind != dbus.Kind.method_call) return null;
    if (!std.mem.eql(u8, m.path, bus_path) or !std.mem.eql(u8, m.interface, bus_iface) or !std.mem.eql(u8, m.member, member)) return null;
    c.reply(m, "", "") catch {}; // zsnag:ok — KWin doesn't wait for this
    return parsePid(m) orelse 0;
}

fn parsePid(m: dbus.Message) ?linux.pid_t {
    if (!std.mem.startsWith(u8, m.signature, "s")) return null;
    var r: dbus.Reader = .{ .body = m.body };
    const text = r.string() catch return null;
    const pid = std.fmt.parseInt(linux.pid_t, text, 10) catch return null;
    return if (pid > 0) pid else null;
}

fn writeFile(path: [:0]const u8, text: []const u8) bool {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc); // zsnag:ok — a successful open returns a small non-negative fd
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < text.len) {
        const n = linux.write(fd, text[done..].ptr, text.len - done);
        if (linux.errno(n) != .SUCCESS) return false;
        done += n;
    }
    return true;
}

test "a rule matches the executable, the name it was started as, or the kernel's short name" {
    var f: Front = .{ .pid = 1 };
    const set = struct {
        fn field(dst: []u8, len: *usize, s: []const u8) void {
            @memcpy(dst[0..s.len], s);
            len.* = s.len;
        }
    };
    set.field(&f.exe, &f.exe_len, "wine64-preloader");
    set.field(&f.arg0, &f.arg0_len, "eldenring.exe");
    set.field(&f.comm, &f.comm_len, "eldenring.exe");
    try std.testing.expect(f.isOneOf(&.{ "steam", "EldenRing.exe" }));
    try std.testing.expect(f.isOneOf(&.{"wine64-preloader"}));
    try std.testing.expect(!f.isOneOf(&.{ "steam", "elden" }));
    try std.testing.expect(!f.isOneOf(&.{}));

    // Only the 15-byte kernel name is known: a longer rule matches on it.
    var g: Front = .{ .pid = 1 };
    set.field(&g.comm, &g.comm_len, "a-very-long-pro");
    try std.testing.expect(g.isOneOf(&.{"a-very-long-program-name"}));
    try std.testing.expect(!g.isOneOf(&.{"b-very-long-program-name"}));
    // A short name is compared whole, not as a prefix.
    var h: Front = .{ .pid = 1 };
    set.field(&h.comm, &h.comm_len, "foot");
    try std.testing.expect(!h.isOneOf(&.{"footclient"}));
    try std.testing.expect(h.isOneOf(&.{"foot"}));

    // Nothing in front matches nothing, not even an empty rule.
    const none: Front = .{};
    try std.testing.expect(!none.isOneOf(&.{ "", "foot" }));
}

test "this process's own names are read from /proc; a missing process has none" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const me = Front.of(linux.getpid());
    try std.testing.expect(me.comm_len > 0 and me.exe_len > 0 and me.arg0_len > 0);
    try std.testing.expect(std.mem.findScalar(u8, me.exe[0..me.exe_len], '/') == null);
    try std.testing.expect(me.isOneOf(&.{me.exe[0..me.exe_len]}));
    const gone = Front.of(0x3ffffffe);
    try std.testing.expectEqual(@as(usize, 0), gone.comm_len + gone.exe_len + gone.arg0_len);
    try std.testing.expectEqualStrings("(none)", gone.name());
}
