// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Which process is in front on Niri, over its IPC socket (`$NIRI_SOCKET`),
//! for the app rule. Niri's IPC is JSON, one message per line: one
//! connection asks for the event stream, and every event about windows or
//! focus is answered by asking for the focused window over a short second
//! connection.
//!
//! Only the app rule comes from here. Niri 26.04 reports no fullscreen state
//! and no reliable on-screen position for a window, so fullscreen, maximized
//! and focused stay the display host's (wlr-foreign-toplevel).

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.niri);

const max_line = 4 << 20;

fn connect(path: []const u8) !linux.fd_t {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.ConnectFailed;
    // Niri answers in milliseconds; this only guards against a hung one.
    const tv: linux.timeval = .{ .sec = 1, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    return fd;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        switch (linux.errno(rc)) {
            .SUCCESS => done += rc,
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

/// Reads one line (without its newline) into `buf`, growing it as needed.
fn readLine(gpa: std.mem.Allocator, fd: linux.fd_t, buf: *std.ArrayList(u8)) ![]const u8 {
    buf.clearRetainingCapacity();
    var byte: [1]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &byte, 1);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) return error.Closed,
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (byte[0] == '\n') return buf.items;
        if (buf.items.len == max_line) return error.TooLong;
        try buf.append(gpa, byte[0]);
    }
}

/// The focused window's process from a `FocusedWindow` reply: 0 when
/// nothing has focus, null when the reply isn't one.
pub fn focusedPid(gpa: std.mem.Allocator, reply: []const u8) ?linux.pid_t {
    const Window = struct { pid: ?i32 = null };
    const Reply = struct { Ok: ?struct { FocusedWindow: ?Window = null } = null };
    const parsed = std.json.parseFromSlice(Reply, gpa, reply, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const ok = parsed.value.Ok orelse return null;
    const w = ok.FocusedWindow orelse return 0;
    return w.pid orelse 0;
}

/// Events after which the focused window may be another one.
fn aboutFocus(event: []const u8) bool {
    inline for (.{ "WindowFocusChanged", "WindowsChanged", "WindowOpenedOrChanged", "WindowClosed", "WorkspaceActivated" }) |name| {
        if (std.mem.startsWith(u8, event, "{\"" ++ name ++ "\"")) return true;
    }
    return false;
}

pub const Watch = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    /// The event stream: readable whenever Niri has news.
    events: linux.fd_t,
    line: std.ArrayList(u8) = .empty,

    pub fn start(gpa: std.mem.Allocator, niri_socket: []const u8) !Watch {
        const fd = try connect(niri_socket);
        errdefer _ = linux.close(fd);
        try writeAll(fd, "\"EventStream\"\n");
        var w: Watch = .{ .gpa = gpa, .path = niri_socket, .events = fd };
        errdefer w.line.deinit(gpa);
        const first = try readLine(gpa, fd, &w.line);
        if (!std.mem.startsWith(u8, first, "{\"Ok\"")) return error.EventStreamRefused;
        return w;
    }

    pub fn stop(w: *Watch) void {
        _ = linux.close(w.events);
        w.line.deinit(w.gpa);
    }

    /// Reads the events that are waiting. `changed` says whether any could
    /// move the focus; false return: Niri closed the stream.
    pub fn drain(w: *Watch, changed: *bool) bool {
        while (true) {
            var pfd = [1]linux.pollfd{.{ .fd = w.events, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&pfd, 1, 0);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return true;
            if (pfd[0].revents & linux.POLL.IN == 0) return false; // hung up
            const ev = readLine(w.gpa, w.events, &w.line) catch return false;
            if (aboutFocus(ev)) changed.* = true;
        }
    }

    /// The focused window's process now (0: nothing has focus).
    pub fn focused(w: *Watch) !linux.pid_t {
        const fd = try connect(w.path);
        defer _ = linux.close(fd);
        try writeAll(fd, "\"FocusedWindow\"\n");
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(w.gpa);
        const reply = try readLine(w.gpa, fd, &buf);
        return focusedPid(w.gpa, reply) orelse error.UnexpectedReply;
    }
};

test focusedPid {
    const gpa = std.testing.allocator;
    // As Niri 26.04 answers (trimmed).
    try std.testing.expectEqual(@as(?linux.pid_t, 387496), focusedPid(gpa,
        \\{"Ok":{"FocusedWindow":{"id":2,"title":"foot","app_id":"nw","pid":387496,"workspace_id":1,"is_focused":true,"layout":{"tile_size":[1276.0,691.0]}}}}
    ));
    try std.testing.expectEqual(@as(?linux.pid_t, 0), focusedPid(gpa, "{\"Ok\":{\"FocusedWindow\":null}}"));
    try std.testing.expectEqual(@as(?linux.pid_t, null), focusedPid(gpa, "{\"Err\":\"nope\"}"));
    try std.testing.expectEqual(@as(?linux.pid_t, null), focusedPid(gpa, "not json"));
}

test aboutFocus {
    try std.testing.expect(aboutFocus("{\"WindowFocusChanged\":{\"id\":null}}"));
    try std.testing.expect(aboutFocus("{\"WindowOpenedOrChanged\":{\"window\":{}}}"));
    try std.testing.expect(!aboutFocus("{\"KeyboardLayoutsChanged\":{}}"));
    // A window title mentioning an event name further in doesn't count.
    try std.testing.expect(!aboutFocus("{\"CastsChanged\":{\"casts\":[{\"title\":\"WindowClosed\"}]}}"));
}
