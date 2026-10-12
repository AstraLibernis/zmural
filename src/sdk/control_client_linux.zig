// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! A control-protocol client (Linux), over `$XDG_RUNTIME_DIR/zmural/control.sock`:
//! connect, check the server is this user's, say hello, then one reply per
//! request. Used by the CLI, and by a second zmural checking on the first.

const std = @import("std");
const linux = std.os.linux;
const unix = @import("../protocol/unix.zig");
const control = @import("../protocol/control.zig");
const transport = @import("../protocol/transport.zig");

pub const Error = error{
    DaemonNotRunning,
    /// Something run by another user answers on our socket.
    ForeignServer,
    UnexpectedReply,
    NoRuntimeDir,
    OutOfMemory,
} || unix.Error;

pub fn address(buf: []u8, xdg_runtime_dir: ?[]const u8) Error![]u8 {
    return transport.address(buf, .linux, .control, xdg_runtime_dir orelse return error.NoRuntimeDir) catch error.NoRuntimeDir;
}

/// A path as the daemon must see it: absolute (it doesn't share our cwd).
pub fn absolutePath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "test-pattern") or std.fs.path.isAbsolute(path)) return path;
    if (std.ascii.startsWithIgnoreCase(path, "https://") or std.ascii.startsWithIgnoreCase(path, "http://")) return path;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    if (linux.errno(rc) != .SUCCESS) return path;
    return std.fs.path.resolve(arena, &.{ std.mem.sliceTo(&buf, 0), path });
}

pub const Client = struct {
    conn: unix.Conn,
    /// The server's pid (from the kernel, not from what it says).
    pid: linux.pid_t,
    /// What `welcome` said.
    daemon_version: [32]u8 = undefined,
    daemon_version_len: usize = 0,
    /// Replies are decoded in place; their strings live here until the next request.
    buf: [unix.max_frame]u8 = undefined,

    /// Connects and says hello. Replies must come within `timeout_ms`
    /// (`error.Timeout` otherwise: the daemon is stuck).
    /// Connects and says hello. zmural turns a connection away when it is
    /// serving as many as it takes; that is tried again for a while.
    pub fn connect(gpa: std.mem.Allocator, path: []const u8, client: []const u8, timeout_ms: u32) Error!*Client {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            return connectOnce(gpa, path, client, timeout_ms) catch |err| {
                if (err != error.Disconnected or tries >= busy_tries) return err;
                const ts: linux.timespec = .{ .sec = 0, .nsec = busy_wait_ms * std.time.ns_per_ms };
                _ = linux.nanosleep(&ts, null);
                continue;
            };
        }
    }

    const busy_tries = 30;
    const busy_wait_ms = 100;

    fn connectOnce(gpa: std.mem.Allocator, path: []const u8, client: []const u8, timeout_ms: u32) Error!*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.conn = unix.connect(path) catch |err| return switch (err) {
            error.NotFound => error.DaemonNotRunning,
            else => err,
        };
        errdefer c.conn.close();
        const cred = try c.conn.peer();
        // Never send anything (wallpaper paths included) to someone else's process.
        if (cred.uid != linux.getuid()) return error.ForeignServer;
        c.pid = cred.pid;
        try c.conn.setSendTimeout(timeout_ms);
        const tv: linux.timeval = .{ .sec = @intCast(timeout_ms / 1000), .usec = @intCast((timeout_ms % 1000) * 1000) };
        _ = linux.setsockopt(c.conn.fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        switch (try c.request(.{ .hello = .{ .version = control.version, .client = client } })) {
            .welcome => |w| {
                c.daemon_version_len = @min(w.daemon_version.len, c.daemon_version.len);
                @memcpy(c.daemon_version[0..c.daemon_version_len], w.daemon_version[0..c.daemon_version_len]);
            },
            else => return error.UnexpectedReply,
        }
        return c;
    }

    pub fn daemonVersion(c: *const Client) []const u8 {
        return c.daemon_version[0..c.daemon_version_len];
    }

    pub fn request(c: *Client, req: control.Request) Error!control.Event {
        try c.conn.send(control.Request, req, &.{});
        var fds: [unix.max_fds]linux.fd_t = undefined;
        const f = try c.conn.recv(&c.buf, &fds);
        f.closeFds();
        return f.decode(control.Event);
    }

    pub fn close(c: *Client, gpa: std.mem.Allocator) void {
        c.conn.close();
        gpa.destroy(c);
    }
};
