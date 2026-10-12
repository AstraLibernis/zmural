// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! A small Wayland client, speaking the wire protocol directly (no
//! libwayland, no scanner).
//!
//! Messages are `[u32 object][u16 opcode][u16 size]` then 32-bit aligned
//! arguments. fds travel beside the bytes through SCM_RIGHTS, in argument
//! order, so outgoing fds are queued with the bytes they belong to and
//! incoming ones are handed out as events are read.
//!
//! Only what zmural's display host uses is here: typed requests go through
//! `request`, events come back raw (`next`), and the caller reads their
//! arguments in the order the protocol XML lists them (`Args`). Opcodes live
//! with the caller, next to the interfaces it binds (`protocols.zig`).

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    NoDisplay,
    PathTooLong,
    ConnectFailed,
    Disconnected,
    SocketFailed,
    /// The compositor sent something that doesn't parse.
    Protocol,
    MessageTooLarge,
    TooManyFds,
    OutOfMemory,
};

pub const ObjectId = u32;
pub const display_id: ObjectId = 1;

/// 24.8 fixed point, as `wl_fixed_t`.
pub fn fixed(v: f64) i32 {
    return @intFromFloat(std.math.clamp(v * 256.0, -2147483648.0, 2147483647.0));
}

pub const Arg = union(enum) {
    uint: u32,
    int: i32,
    /// Already in 24.8 (`fixed()`).
    fixed: i32,
    /// `null` is a null string (length 0 on the wire).
    string: ?[]const u8,
    /// 0 is the null object.
    object: ObjectId,
    new_id: ObjectId,
    fd: linux.fd_t,
    array: []const u8,
};

const max_message = 4096;
/// libwayland's per-sendmsg fd limit; the compositor accepts no more at once.
const max_fds_out = 28;
const max_fds_in = 64;

pub const Conn = struct {
    fd: linux.fd_t,
    out: [max_message * 4]u8 = undefined,
    out_len: usize = 0,
    out_fds: [max_fds_out]linux.fd_t = undefined,
    out_nfds: usize = 0,
    in: [max_message * 4]u8 = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    /// Received fds not yet claimed by an event, oldest first.
    in_fds: [max_fds_in]linux.fd_t = undefined,
    in_nfds: usize = 0,
    next_id: ObjectId = 2,
    /// Ids the compositor has confirmed deleted (`wl_display.delete_id`).
    free_ids: std.ArrayList(ObjectId) = .empty,
    gpa: std.mem.Allocator,

    /// Connects to `$WAYLAND_DISPLAY` (a name under `$XDG_RUNTIME_DIR`, or an
    /// absolute path).
    pub fn connect(gpa: std.mem.Allocator, xdg_runtime_dir: ?[]const u8, wayland_display: ?[]const u8) Error!Conn {
        const name = wayland_display orelse "wayland-0";
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        const path = if (name.len > 0 and name[0] == '/')
            std.fmt.bufPrint(&addr.path, "{s}", .{name})
        else
            std.fmt.bufPrint(&addr.path, "{s}/{s}", .{ xdg_runtime_dir orelse return error.NoDisplay, name });
        const len = (path catch return error.PathTooLong).len;
        if (len >= addr.path.len) return error.PathTooLong;

        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);
        while (true) switch (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un)))) {
            .SUCCESS => break,
            .INTR => continue,
            .NOENT, .CONNREFUSED => return error.NoDisplay,
            else => return error.ConnectFailed,
        };
        return .{ .fd = fd, .gpa = gpa };
    }

    pub fn close(c: *Conn) void {
        for (c.in_fds[0..c.in_nfds]) |fd| _ = linux.close(fd);
        c.in_nfds = 0;
        c.free_ids.deinit(c.gpa);
        _ = linux.close(c.fd);
    }

    /// A fresh object id for a `new_id` argument.
    pub fn newId(c: *Conn) ObjectId {
        if (c.free_ids.pop()) |id| return id;
        defer c.next_id += 1;
        return c.next_id;
    }

    /// Call on `wl_display.delete_id`: the id may be reused.
    pub fn deleteId(c: *Conn, id: ObjectId) void {
        c.free_ids.append(c.gpa, id) catch {}; // zsnag:ok — out of memory only means the id isn't reused
    }

    /// Queues a request. Nothing is sent until `flush` (or the buffer fills).
    /// fds are sent as duplicates; the caller keeps its own.
    pub fn request(c: *Conn, object: ObjectId, opcode: u16, args: []const Arg) Error!void {
        var size: usize = 8;
        var nfds: usize = 0;
        for (args) |a| {
            size += switch (a) {
                .string => |s| if (s) |t| 4 + pad(t.len + 1) else 4,
                .array => |b| 4 + pad(b.len),
                .fd => 0,
                else => 4,
            };
            if (a == .fd) nfds += 1;
        }
        if (size > max_message) return error.MessageTooLarge;
        if (nfds > max_fds_out) return error.TooManyFds;
        if (c.out_len + size > c.out.len or c.out_nfds + nfds > max_fds_out) try c.flush();

        const msg = c.out[c.out_len..][0..size];
        std.mem.writeInt(u32, msg[0..4], object, .native);
        std.mem.writeInt(u32, msg[4..8], (@as(u32, @intCast(size)) << 16) | opcode, .native);
        var pos: usize = 8;
        for (args) |a| switch (a) {
            .uint, .object, .new_id => |v| {
                std.mem.writeInt(u32, msg[pos..][0..4], v, .native);
                pos += 4;
            },
            .int, .fixed => |v| {
                std.mem.writeInt(i32, msg[pos..][0..4], v, .native);
                pos += 4;
            },
            .string => |s| {
                const t = s orelse {
                    std.mem.writeInt(u32, msg[pos..][0..4], 0, .native);
                    pos += 4;
                    continue;
                };
                pos = putBytes(msg, pos, t, true);
            },
            .array => |b| pos = putBytes(msg, pos, b, false),
            .fd => |fd| {
                c.out_fds[c.out_nfds] = fd;
                c.out_nfds += 1;
            },
        };
        std.debug.assert(pos == size);
        c.out_len += size;
        // The fds are sent by value at flush time: flush now so the caller
        // may close its copy as soon as `request` returns.
        if (nfds > 0) try c.flush();
    }

    fn putBytes(msg: []u8, at: usize, bytes: []const u8, nul: bool) usize {
        const n = bytes.len + @intFromBool(nul);
        std.mem.writeInt(u32, msg[at..][0..4], @intCast(n), .native);
        @memcpy(msg[at + 4 ..][0..bytes.len], bytes);
        @memset(msg[at + 4 + bytes.len .. at + 4 + pad(n)], 0);
        return at + 4 + pad(n);
    }

    /// Sends everything queued.
    pub fn flush(c: *Conn) Error!void {
        var sent: usize = 0;
        while (sent < c.out_len) {
            var control: FdControl = undefined;
            const iov = [_]std.posix.iovec_const{.{ .base = c.out[sent..].ptr, .len = c.out_len - sent }};
            var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            if (c.out_nfds > 0) {
                control.header = .{ .len = FdControl.space(c.out_nfds), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
                @memcpy(control.fds[0..c.out_nfds], c.out_fds[0..c.out_nfds]);
                msg.control = &control;
                msg.controllen = FdControl.space(c.out_nfds);
            }
            const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    sent += rc;
                    c.out_nfds = 0; // attached to the first byte sent
                },
                .INTR, .AGAIN => continue,
                .PIPE, .CONNRESET => return error.Disconnected,
                else => return error.SocketFailed,
            }
        }
        c.out_len = 0;
    }

    /// Reads whatever the compositor has sent (blocking until something
    /// arrives). Call when the fd polls readable, then drain with `next`.
    pub fn fill(c: *Conn) Error!void {
        if (c.in_start > 0) {
            std.mem.copyForwards(u8, &c.in, c.in[c.in_start..c.in_end]);
            c.in_end -= c.in_start;
            c.in_start = 0;
        }
        if (c.in_end == c.in.len) return error.Protocol; // a message larger than the buffer
        var control: FdControl = undefined;
        var iov = [_]std.posix.iovec{.{ .base = c.in[c.in_end..].ptr, .len = c.in.len - c.in_end }};
        var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = @sizeOf(FdControl), .flags = 0 };
        const n = while (true) {
            const rc = linux.recvmsg(c.fd, &msg, linux.MSG.CMSG_CLOEXEC);
            switch (linux.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => continue,
                .CONNRESET => return error.Disconnected,
                else => return error.SocketFailed,
            }
        };
        if (msg.controllen >= @sizeOf(linux.cmsghdr) and control.header.level == linux.SOL.SOCKET and control.header.type == linux.SCM.RIGHTS) {
            const len = @min(control.header.len, msg.controllen);
            const got = (len -| @sizeOf(linux.cmsghdr)) / @sizeOf(linux.fd_t);
            for (control.fds[0..@min(got, FdControl.max)]) |fd| {
                if (c.in_nfds == max_fds_in) {
                    _ = linux.close(fd);
                    return error.TooManyFds;
                }
                c.in_fds[c.in_nfds] = fd;
                c.in_nfds += 1;
            }
        }
        if (msg.flags & linux.MSG.CTRUNC != 0) return error.TooManyFds;
        if (n == 0) return error.Disconnected;
        c.in_end += n;
    }

    /// The next complete event, or null when more must be read (`fill`).
    /// The event borrows the connection's buffer until the next `fill`.
    pub fn next(c: *Conn) Error!?Event {
        const avail = c.in[c.in_start..c.in_end];
        if (avail.len < 8) return null;
        const object = std.mem.readInt(u32, avail[0..4], .native);
        const word = std.mem.readInt(u32, avail[4..8], .native);
        const size: usize = word >> 16;
        if (size < 8 or size % 4 != 0) return error.Protocol;
        if (avail.len < size) return null;
        c.in_start += size;
        return .{ .object = object, .opcode = @truncate(word), .args = .{ .conn = c, .body = avail[8..size] } };
    }

    /// The oldest received fd not yet claimed; the caller owns it.
    fn takeFd(c: *Conn) Error!linux.fd_t {
        if (c.in_nfds == 0) return error.Protocol;
        const fd = c.in_fds[0];
        std.mem.copyForwards(linux.fd_t, c.in_fds[0 .. c.in_nfds - 1], c.in_fds[1..c.in_nfds]);
        c.in_nfds -= 1;
        return fd;
    }

    /// `wl_display.sync`: `callback` gets `done` once the compositor has
    /// processed every earlier request.
    pub fn sync(c: *Conn) Error!ObjectId {
        const cb = c.newId();
        try c.request(display_id, 0, &.{.{ .new_id = cb }});
        return cb;
    }

    pub fn getRegistry(c: *Conn) Error!ObjectId {
        const reg = c.newId();
        try c.request(display_id, 1, &.{.{ .new_id = reg }});
        return reg;
    }

    /// `wl_registry.bind` for a global announced as `name`.
    pub fn bind(c: *Conn, registry: ObjectId, name: u32, interface: []const u8, version: u32) Error!ObjectId {
        const id = c.newId();
        try c.request(registry, 0, &.{ .{ .uint = name }, .{ .string = interface }, .{ .uint = version }, .{ .new_id = id } });
        return id;
    }
};

fn pad(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

const FdControl = extern struct {
    const max = 32;
    header: linux.cmsghdr,
    fds: [max]linux.fd_t,

    fn space(n: usize) usize {
        return @sizeOf(linux.cmsghdr) + n * @sizeOf(linux.fd_t);
    }
};

pub const Event = struct {
    object: ObjectId,
    opcode: u16,
    args: Args,
};

/// Reads an event's arguments in declaration order.
pub const Args = struct {
    conn: *Conn,
    body: []const u8,
    pos: usize = 0,

    pub fn uint(a: *Args) Error!u32 {
        if (a.pos + 4 > a.body.len) return error.Protocol;
        defer a.pos += 4;
        return std.mem.readInt(u32, a.body[a.pos..][0..4], .native);
    }

    pub fn int(a: *Args) Error!i32 {
        return @bitCast(try a.uint());
    }

    pub fn object(a: *Args) Error!ObjectId {
        return a.uint();
    }

    /// Without the trailing NUL; null for a null string.
    pub fn string(a: *Args) Error!?[]const u8 {
        const b = try a.array();
        if (b.len == 0) return null;
        if (b[b.len - 1] != 0) return error.Protocol;
        return b[0 .. b.len - 1];
    }

    pub fn array(a: *Args) Error![]const u8 {
        const n = try a.uint();
        if (n > a.body.len - a.pos) return error.Protocol;
        const b = a.body[a.pos..][0..n];
        a.pos += pad(n);
        if (a.pos > a.body.len) return error.Protocol;
        return b;
    }

    /// Claims the event's next fd; the caller owns (and must close) it.
    pub fn fd(a: *Args) Error!linux.fd_t {
        return a.conn.takeFd();
    }
};

test "requests encode like libwayland" {
    var c: Conn = .{ .fd = -1, .gpa = std.testing.allocator };
    defer c.free_ids.deinit(c.gpa);
    try c.request(3, 0, &.{ .{ .uint = 7 }, .{ .string = "wl_compositor" }, .{ .uint = 4 }, .{ .new_id = 5 } });
    const want = [_]u32{
        3, (40 << 16) | 0, // header: object 3, size 40, opcode 0
        7,                                     14, // name, then the string's length with its NUL
        std.mem.readInt(u32, "wl_c", .native), std.mem.readInt(u32, "ompo", .native),
        std.mem.readInt(u32, "sito", .native), std.mem.readInt(u32, "r\x00\x00\x00", .native),
        4,                                     5,
    };
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&want), c.out[0..c.out_len]);
}

test "events decode, and a partial one waits for more" {
    var c: Conn = .{ .fd = -1, .gpa = std.testing.allocator };
    defer c.free_ids.deinit(c.gpa);
    // wl_registry.global(name 9, "wl_output", version 4), split across two reads.
    const words = [_]u32{
        2,                                              (32 << 16) | 0,
        9,                                              10,
        std.mem.readInt(u32, "wl_o", .native),          std.mem.readInt(u32, "utpu", .native),
        std.mem.readInt(u32, "t\x00\x00\x00", .native), 4,
    };
    const bytes = std.mem.sliceAsBytes(&words);
    @memcpy(c.in[0..20], bytes[0..20]);
    c.in_end = 20;
    try std.testing.expectEqual(@as(?Event, null), try c.next());
    @memcpy(c.in[20..32], bytes[20..32]);
    c.in_end = 32;
    var ev = (try c.next()).?;
    try std.testing.expectEqual(@as(ObjectId, 2), ev.object);
    try std.testing.expectEqual(@as(u32, 9), try ev.args.uint());
    try std.testing.expectEqualStrings("wl_output", (try ev.args.string()).?);
    try std.testing.expectEqual(@as(u32, 4), try ev.args.uint());
    try std.testing.expectError(error.Protocol, ev.args.uint());
}

test "ids are reused after delete_id" {
    var c: Conn = .{ .fd = -1, .gpa = std.testing.allocator };
    defer c.free_ids.deinit(c.gpa);
    const a = c.newId();
    _ = c.newId();
    c.deleteId(a);
    try std.testing.expectEqual(a, c.newId());
    try std.testing.expectEqual(@as(ObjectId, 4), c.newId());
}

test fixed {
    try std.testing.expectEqual(@as(i32, 256), fixed(1.0));
    try std.testing.expectEqual(@as(i32, -128), fixed(-0.5));
}
