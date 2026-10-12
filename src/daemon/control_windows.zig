// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The control endpoint (Windows): `\\.\pipe\zmural-<SID>-s<session>-control`,
//! where the CLI, the tray and the settings window talk to zmural.
//!
//! - The first instance claims the name, so a second daemon fails to start the
//!   server with `error.InUse`; the caller then checks who owns it.
//! - One instance always waits for the next client. As soon as a client
//!   connects, a fresh instance is opened, so a client that connects and
//!   says nothing can't lock everyone else out.
//! - A client must say `hello` within `hello_timeout_ms`, or it is dropped.
//! - Replies time out (`reply_timeout_ms`): a client that stops reading
//!   can't freeze the daemon.
//! - Each client gets a reader thread that posts to the daemon's window;
//!   requests are answered on the UI thread, one reply per request.

const std = @import("std");
const zmural = @import("zmural");
const w = zmural.os.win32;
const pipe = zmural.protocol.pipe;
const control = zmural.protocol.control;

pub const Handler = *const fn (control.Request) control.Event;

pub const hello_timeout_ms = 3_000;
pub const reply_timeout_ms = 2_000;

const Client = struct {
    id: usize,
    conn: pipe.Conn,
    reader: ?w.HANDLE = null,
    /// When the client connected (0: still waiting for one).
    connected_ms: u64 = 0,
    greeted: bool = false,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    name: []const u8,
    hwnd: w.HWND,
    msg: w.UINT,
    clients: std.ArrayList(*Client) = .empty,
    next_id: usize = 1,

    /// Claims the control pipe. `error.InUse`: someone already owns the name.
    pub fn start(gpa: std.mem.Allocator, name: []const u8, hwnd: w.HWND, msg: w.UINT) pipe.Error!Server {
        var s: Server = .{ .gpa = gpa, .name = name, .hwnd = hwnd, .msg = msg };
        // `listen` reserves a list slot before it can fail (a second zmural
        // finds the pipe name taken): without this that slot leaked.
        errdefer s.clients.deinit(gpa);
        try s.listen(true);
        return s;
    }

    /// Opens one more instance and a reader waiting for its client.
    fn listen(s: *Server, first: bool) pipe.Error!void {
        // Reserve the list slot first: once the reader runs, nothing may fail
        // and free the client under it.
        try s.clients.ensureUnusedCapacity(s.gpa, 1);
        const c = try s.gpa.create(Client);
        errdefer s.gpa.destroy(c);
        c.* = .{ .id = s.next_id, .conn = try pipe.listen(s.gpa, s.name, .{ .first = first, .max_instances = w.PIPE_UNLIMITED_INSTANCES }) };
        errdefer c.conn.close();
        c.conn.write_timeout_ms = reply_timeout_ms;
        s.next_id += 1;
        c.reader = try pipe.startReader(.{
            .conn = &c.conn,
            .hwnd = s.hwnd,
            .msg = s.msg,
            .tag = c.id,
            .accept_timeout_ms = w.INFINITE,
            .notify_connect = true,
        });
        s.clients.appendAssumeCapacity(c);
    }

    /// Handles a posted control message (WPARAM = client id).
    pub fn onMessage(s: *Server, now: u64, wp: w.WPARAM, lp: w.LPARAM, handler: Handler) void {
        const notice = pipe.Notice.fromLparam(lp);
        defer if (notice == .frame) notice.frame.destroy();
        const c, const index = s.find(wp) orelse return;

        switch (notice) {
            .connected => {
                c.connected_ms = now;
                // This instance is taken: open the next one for whoever comes after.
                s.listen(false) catch |err| std.log.err("control: cannot open the next pipe instance: {s}", .{@errorName(err)});
            },
            .ended => {
                const was_waiting = c.connected_ms == 0;
                s.drop(index);
                // Only the waiting instance failing leaves nobody listening.
                if (was_waiting) s.listen(false) catch |err| std.log.err("control: cannot reopen the pipe: {s}", .{@errorName(err)});
            },
            .frame => |in| {
                const req = in.frame().decode(control.Request) catch {
                    s.reply(c, .{ .failed = .{ .code = .bad_request, .message = "unreadable request" } });
                    return;
                };
                if (c.greeted) return s.reply(c, handler(req));
                switch (req) {
                    .hello => |h| {
                        if (h.version != control.version) {
                            s.reply(c, .{ .failed = .{ .code = .incompatible_version, .message = "control protocol version mismatch" } });
                            return;
                        }
                        c.greeted = true;
                        s.reply(c, .{ .welcome = .{ .version = control.version, .daemon_version = zmural.version, .capabilities = control.capabilities } });
                    },
                    else => s.reply(c, .{ .failed = .{ .code = .bad_request, .message = "say hello first" } }),
                }
            },
        }
    }

    /// Drops clients that connected but never said hello.
    pub fn tick(s: *Server, now: u64) void {
        for (s.clients.items) |c| {
            if (c.connected_ms != 0 and !c.greeted and now -| c.connected_ms > hello_timeout_ms) {
                std.log.warn("control: client {d} never said hello; dropping it", .{c.id});
                c.conn.shutdown(); // its reader then reports the end
            }
        }
    }

    fn reply(s: *Server, c: *Client, ev: control.Event) void {
        _ = s;
        c.conn.send(control.Event, ev) catch c.conn.shutdown(); // the reader then reports the end
    }

    fn find(s: *Server, id: usize) ?struct { *Client, usize } {
        for (s.clients.items, 0..) |c, i| if (c.id == id) return .{ c, i };
        return null;
    }

    fn drop(s: *Server, index: usize) void {
        const c = s.clients.swapRemove(index);
        reap(c);
        s.gpa.destroy(c);
    }

    pub fn stop(s: *Server) void {
        for (s.clients.items) |c| {
            reap(c);
            s.gpa.destroy(c);
        }
        s.clients.deinit(s.gpa);
    }
};

fn reap(c: *Client) void {
    if (c.reader) |t| pipe.stopReader(&c.conn, t);
    c.reader = null;
    c.conn.close();
}
