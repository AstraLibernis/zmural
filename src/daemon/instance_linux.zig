// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! One zmural per user session (Linux). A starting zmural checks the
//! control socket first:
//! - nobody there (or a socket left by a crash): carry on
//! - a healthy zmural of the same version: hand it `--apply` (if any) and exit
//! - a healthy zmural of another version (an upgrade): ask it to quit, then
//!   carry on in its place
//! - a zmural that doesn't answer (hung): make sure it really is this
//!   user's zmural, stop it (SIGTERM, then SIGKILL), and carry on
//!
//! What's on the other end is identified by the kernel (SO_PEERCRED and
//! /proc/<pid>/exe), never by what it says, so a stuck process that happens
//! to hold the socket can't be anything but ours when it gets killed.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const unix = zmural.protocol.unix;
const control = zmural.protocol.control;

const log = std.log.scoped(.instance);

/// How long a running zmural gets to answer before it counts as hung.
pub const answer_timeout_ms = 3000;
const exit_wait_ms = 3000;

pub const Outcome = enum {
    /// This zmural should run.
    run,
    /// A healthy zmural is running; this one should exit.
    exit,
};

pub const Error = error{ ForeignServer, CannotStop } || std.mem.Allocator.Error;

/// `settings_token`: non-null when this zmural was started to open the
/// settings window (`--settings`); a running one is asked to open it.
pub fn claim(control_path: []const u8, our_version: []const u8, apply: ?[]const u8, settings_token: ?[]const u8) Error!Outcome {
    var conn = unix.connect(control_path) catch return .run; // nobody (or a stale socket)
    defer conn.close();
    const cred = conn.peer() catch return .run;
    if (cred.uid != linux.getuid()) {
        log.err("the process on zmural's control socket belongs to uid {d}; not touching it", .{cred.uid});
        return error.ForeignServer;
    }
    const pid = cred.pid;

    const tv: linux.timeval = .{ .sec = answer_timeout_ms / 1000, .usec = (answer_timeout_ms % 1000) * 1000 };
    _ = linux.setsockopt(conn.fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    conn.setSendTimeout(answer_timeout_ms) catch {}; // zsnag:ok — a failed send below is treated as hung anyway

    var buf: [unix.max_frame]u8 = undefined;
    var fds: [unix.max_fds]linux.fd_t = undefined;
    const welcome = hello: {
        conn.send(control.Request, .{ .hello = .{ .version = control.version, .client = "zmural" } }, &.{}) catch break :hello null;
        const f = conn.recv(&buf, &fds) catch break :hello null;
        f.closeFds();
        const ev = f.decode(control.Event) catch break :hello null;
        break :hello switch (ev) {
            .welcome => |w| w,
            else => null,
        };
    };

    const w = welcome orelse {
        log.warn("zmural (pid {d}) isn't answering; stopping it and taking over", .{pid});
        try stop(pid);
        return .run;
    };
    if (!std.mem.eql(u8, w.daemon_version, our_version)) {
        log.info("zmural {s} (pid {d}) is running; replacing it with {s}", .{ w.daemon_version, pid, our_version });
        conn.send(control.Request, .quit, &.{}) catch {}; // zsnag:ok — if it can't hear us, stop() below does it
        if (!waitExit(pid, exit_wait_ms)) try stop(pid);
        return .run;
    }
    // A healthy zmural of our version: it keeps running.
    if (apply) |path| {
        conn.send(control.Request, .{ .apply = .{ .path = path } }, &.{}) catch return .exit;
        const f = conn.recv(&buf, &fds) catch return .exit;
        f.closeFds();
        switch (f.decode(control.Event) catch return .exit) {
            .ok => log.info("zmural is already running; handed it '{s}'", .{path}),
            .failed => |fl| log.err("zmural is already running and refused '{s}': {s}", .{ path, fl.message }),
            else => {},
        }
    } else if (settings_token == null) {
        log.info("zmural is already running (pid {d})", .{pid});
    }
    if (settings_token) |token| {
        conn.send(control.Request, .{ .open_settings = .{ .token = token } }, &.{}) catch return .exit;
        const f = conn.recv(&buf, &fds) catch return .exit;
        f.closeFds();
        switch (f.decode(control.Event) catch return .exit) {
            .ok => log.info("zmural is already running; asked it for the settings window", .{}),
            else => log.err("zmural is already running and didn't open the settings window", .{}),
        }
    }
    return .exit;
}

/// Stops `pid` if it is this user's zmural: SIGTERM, then SIGKILL.
fn stop(pid: linux.pid_t) Error!void {
    if (!isZmural(pid)) {
        log.err("pid {d} holds zmural's control socket but isn't zmural; not stopping it", .{pid});
        return error.CannotStop;
    }
    _ = linux.kill(pid, linux.SIG.TERM);
    // A stopped process (SIGSTOP, a debugger) can't act on SIGTERM until it
    // runs again.
    _ = linux.kill(pid, linux.SIG.CONT);
    if (waitExit(pid, exit_wait_ms)) return;
    log.warn("zmural (pid {d}) ignored SIGTERM; killing it", .{pid});
    _ = linux.kill(pid, linux.SIG.KILL);
    if (!waitExit(pid, exit_wait_ms)) return error.CannotStop;
}

/// Is `pid` a zmural executable owned by us? (It may be a deleted file
/// after an upgrade: "/usr/bin/zmural (deleted)".)
fn isZmural(pid: linux.pid_t) bool {
    var path_buf: [64:0]u8 = undefined;
    const link = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/exe", .{pid}, 0) catch return false;
    var target: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rc = linux.readlink(link, &target, target.len);
    if (linux.errno(rc) != .SUCCESS) return false;
    const exe = target[0..rc];
    const base = std.fs.path.basename(exe);
    // "zmurald" was the program's name until 2026-09-30: an upgrade must
    // still be able to replace one that hangs.
    for ([_][]const u8{ "zmural", "zmurald" }) |name| {
        if (std.mem.eql(u8, base, name)) return true;
        if (std.mem.startsWith(u8, base, name) and std.mem.eql(u8, base[name.len..], " (deleted)")) return true;
    }
    return false;
}

/// Waits up to `ms` for `pid` to exit. True once it's gone.
fn waitExit(pid: linux.pid_t, ms: i32) bool {
    const rc = linux.pidfd_open(pid, 0);
    if (linux.errno(rc) == .SRCH) return true;
    if (linux.errno(rc) != .SUCCESS) return false;
    const pfd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(pfd);
    var p = [_]linux.pollfd{.{ .fd = pfd, .events = linux.POLL.IN, .revents = 0 }};
    return linux.poll(&p, 1, ms) == 1;
}

test isZmural {
    // This test binary isn't zmural.
    try std.testing.expect(!isZmural(linux.getpid()));
}
