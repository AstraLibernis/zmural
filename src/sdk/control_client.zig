// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! A control-protocol client (Windows): connect, check the server really is
//! this user's zmural, say hello, then one reply per request. Used by the
//! CLI, and by a second zmural handing its request to the one already
//! running.

const std = @import("std");
const pipe = @import("../protocol/pipe.zig");
const control = @import("../protocol/control.zig");
const transport = @import("../protocol/transport.zig");
const identity = @import("../os/identity.zig");

pub const Error = error{
    DaemonNotRunning,
    /// Something owned by another account answers on our pipe name.
    ForeignServer,
    UnexpectedReply,
    NoIdentity,
} || pipe.Error;

/// Resolves `path` against the current directory, since the daemon runs
/// elsewhere. `test-pattern` passes through unchanged. Windows paths are
/// WTF-8 (they may hold unpaired surrogates), so they're converted as such.
pub fn absolutePath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "test-pattern")) return path;
    if (std.ascii.startsWithIgnoreCase(path, "https://") or std.ascii.startsWithIgnoreCase(path, "http://")) return path;
    const w = @import("../os/win32.zig");
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(arena, path);
    const needed = w.GetFullPathNameW(path_w, 0, @ptrCast(path_w.ptr), null); // zsnag:ok — length query, buffer unused
    if (needed == 0) return path;
    const buf = try arena.alloc(u16, needed);
    const n = w.GetFullPathNameW(path_w, needed, buf.ptr, null);
    if (n == 0 or n >= needed) return path;
    return std.unicode.wtf16LeToWtf8Alloc(arena, buf[0..n]);
}

/// `\\.\pipe\zmural-<SID>-s<session>-control`: unique per user and session.
pub fn address(buf: []u8) Error![]u8 {
    var scope_buf: [256]u8 = undefined;
    const scope = identity.scope(&scope_buf) orelse return error.NoIdentity;
    return transport.address(buf, .windows, .control, scope) catch error.NoIdentity;
}

/// How long a reply may take before the request fails with `error.Timeout`.
pub const reply_timeout_ms = 10_000;

pub const Client = struct {
    conn: pipe.Conn,
    /// Replies are decoded in place; their strings live here until the next request.
    buf: [pipe.max_frame]u8,

    /// Heap-allocated: the frame buffer is 64 KiB.
    pub fn connect(gpa: std.mem.Allocator, name: []const u8, client: []const u8) Error!*Client {
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.conn = pipe.connect(gpa, name, 2000) catch |err| return switch (err) {
            error.NotFound => error.DaemonNotRunning,
            else => err,
        };
        errdefer c.conn.close();
        // Never send anything (wallpaper paths included) to a server run by someone else.
        const server = c.conn.peerProcessId() orelse return error.ForeignServer;
        if (!identity.isOurs(server)) return error.ForeignServer;
        c.conn.write_timeout_ms = 5000;
        // A daemon that's stuck (or not really zmural) can't hang us: the
        // slowest real request (switching wallpapers) takes about 2 s.
        c.conn.read_timeout_ms = reply_timeout_ms;
        switch (try c.request(.{ .hello = .{ .version = control.version, .client = client } })) {
            .welcome => {},
            else => return error.UnexpectedReply,
        }
        return c;
    }

    pub fn request(c: *Client, req: control.Request) Error!control.Event {
        try c.conn.send(control.Request, req);
        return (try c.conn.recv(&c.buf)).decode(control.Event);
    }

    pub fn close(c: *Client, gpa: std.mem.Allocator) void {
        c.conn.close();
        gpa.destroy(c);
    }
};

test absolutePath {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const abs = try absolutePath(a, "some\\file.mp4");
    try std.testing.expect(std.fs.path.isAbsolute(abs));
    try std.testing.expect(std.mem.endsWith(u8, abs, "some\\file.mp4"));
    // Longer than the old fixed 1024-unit buffer.
    const long = try std.fmt.allocPrint(a, "C:\\{s}\\x.mp4", .{"d" ** 1500});
    try std.testing.expectEqualStrings(long, try absolutePath(a, long));
    // An unpaired surrogate (valid WTF-8, invalid UTF-8) survives the round trip.
    const odd = "C:\\w\\a\xED\xA0\x80b.mp4";
    try std.testing.expectEqualStrings(odd, try absolutePath(a, odd));
    try std.testing.expectEqualStrings("test-pattern", try absolutePath(a, "test-pattern"));
}
