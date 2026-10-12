// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Unix-socket transport (Linux).
//!
//! Every connection is `SOCK_SEQPACKET`: one `sendmsg` is one wire frame, the
//! kernel keeps the boundaries, and the fds of a frame (DMA-BUFs, sync fds)
//! ride on that exact frame through SCM_RIGHTS. So there is no reassembly and
//! no way for an fd to arrive attached to the wrong message.
//!
//! Two ways to get a connection:
//! - `pair`: an anonymous socketpair. The daemon keeps one end and hands the
//!   other to a child it spawns (renderers, the layer-shell host), so nothing
//!   else can reach that channel.
//! - `listen` / `connect`: a named socket in `$XDG_RUNTIME_DIR/zmural/`, a
//!   0700 directory. `accept` also checks the peer's uid (SO_PEERCRED), so a
//!   loosened directory mode still doesn't let another user in.
//!
//! Sockets are blocking and single-threaded: callers `poll` the fd and call
//! `recv` when it's readable. Writes give up after `send_timeout_ms`, so a peer
//! that stops reading can't freeze the sender.

const std = @import("std");
const linux = std.os.linux;
const wire = @import("wire.zig");

pub const Error = error{
    SocketFailed,
    /// Someone is already listening on this path.
    InUse,
    /// Nobody is listening on this path.
    NotFound,
    ConnectFailed,
    PathTooLong,
    /// The runtime directory isn't a private directory we own.
    UnsafeDirectory,
    /// The peer is another user.
    WrongUser,
    Timeout,
    Disconnected,
    /// A frame or its fds didn't fit (MSG_TRUNC / MSG_CTRUNC).
    Truncated,
    TooManyFds,
} || wire.Error;

pub const max_frame = wire.header_len + wire.max_body_len;
/// Most fds any one frame carries (a DMA-BUF plane or two plus sync fds).
pub const max_fds = 4;

pub const Frame = struct {
    opcode: u16,
    body: []const u8,
    /// Received fds, owned by the caller: close them (or keep them).
    fds: []const linux.fd_t,

    /// String fields in the result borrow `body`.
    pub fn decode(f: Frame, comptime M: type) wire.Error!M {
        return wire.decodeMessage(M, f.opcode, f.body);
    }

    pub fn closeFds(f: Frame) void {
        for (f.fds) |fd| _ = linux.close(fd);
    }
};

pub const Cred = extern struct { pid: i32, uid: u32, gid: u32 };

pub const Conn = struct {
    fd: linux.fd_t,

    pub fn close(c: *Conn) void {
        if (c.fd >= 0) _ = linux.close(c.fd);
        c.fd = -1;
    }

    /// Makes both directions fail at once (the peer sees end of stream).
    pub fn shutdown(c: *Conn) void {
        _ = linux.shutdown(c.fd, linux.SHUT.RDWR);
    }

    /// Writes to a peer that stops reading fail after this long (0: never).
    pub fn setSendTimeout(c: *Conn, ms: u32) Error!void {
        const tv: linux.timeval = .{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
        if (linux.errno(linux.setsockopt(c.fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval))) != .SUCCESS)
            return error.SocketFailed;
    }

    /// The peer process, as the kernel saw it when the connection was made.
    pub fn peer(c: *const Conn) Error!Cred {
        var cred: Cred = undefined;
        var len: linux.socklen_t = @sizeOf(Cred);
        if (linux.errno(linux.getsockopt(c.fd, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred), &len)) != .SUCCESS)
            return error.SocketFailed;
        return cred;
    }

    /// Sends one message as one frame, with `fds` attached. The fds stay
    /// owned by the caller (the peer gets duplicates).
    pub fn send(c: *Conn, comptime M: type, msg: M, fds: []const linux.fd_t) Error!void {
        var buf: [max_frame]u8 = undefined;
        return c.sendFrame(try wire.encodeMessage(M, msg, &buf), fds);
    }

    pub fn sendFrame(c: *Conn, frame: []const u8, fds: []const linux.fd_t) Error!void {
        if (fds.len > max_fds) return error.TooManyFds;
        var control: Control = undefined;
        const iov = [_]std.posix.iovec_const{.{ .base = frame.ptr, .len = frame.len }};
        var msg: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        if (fds.len > 0) {
            control.put(fds);
            msg.control = &control;
            msg.controllen = Control.space(fds.len);
        }
        while (true) {
            const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => return if (rc == frame.len) {} else error.Truncated,
                .INTR => continue,
                .AGAIN => return error.Timeout,
                .PIPE, .CONNRESET, .NOTCONN => return error.Disconnected,
                else => return error.SocketFailed,
            }
        }
    }

    /// Receives one frame into `buf`, and its fds into `fds` (see `Frame.fds`).
    /// Blocks until a frame arrives; `error.Disconnected` at end of stream.
    pub fn recv(c: *Conn, buf: *[max_frame]u8, fds: *[max_fds]linux.fd_t) Error!Frame {
        var control: Control = undefined;
        var iov = [_]std.posix.iovec{.{ .base = buf, .len = buf.len }};
        var msg: linux.msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &iov,
            .iovlen = 1,
            .control = &control,
            .controllen = @sizeOf(Control),
            .flags = 0,
        };
        const n = while (true) {
            const rc = linux.recvmsg(c.fd, &msg, linux.MSG.CMSG_CLOEXEC);
            switch (linux.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => continue,
                .AGAIN => return error.Timeout,
                .CONNRESET => return error.Disconnected,
                else => return error.SocketFailed,
            }
        };
        const got = control.take(msg.controllen, fds);
        errdefer for (fds[0..got]) |fd| {
            _ = linux.close(fd);
        };
        if (msg.flags & (linux.MSG.TRUNC | linux.MSG.CTRUNC) != 0) return error.Truncated;
        if (n == 0) return error.Disconnected;
        if (n < wire.header_len) return error.Truncated;
        const header: wire.Header = .read(buf[0..wire.header_len]);
        if (n != wire.header_len + @as(usize, header.body_len)) return error.Truncated;
        return .{ .opcode = header.opcode, .body = buf[wire.header_len..n], .fds = fds[0..got] };
    }
};

/// Ancillary data for up to `max_fds` descriptors, aligned like a cmsghdr.
const Control = extern struct {
    header: linux.cmsghdr,
    fds: [max_fds]linux.fd_t,

    fn space(n: usize) usize {
        return @sizeOf(linux.cmsghdr) + n * @sizeOf(linux.fd_t);
    }

    fn put(c: *Control, fds: []const linux.fd_t) void {
        c.header = .{ .len = space(fds.len), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
        @memcpy(c.fds[0..fds.len], fds);
    }

    /// Copies the received fds out and returns how many there were. Only one
    /// SCM_RIGHTS header fits in the buffer, so there is nothing to walk.
    fn take(c: *const Control, controllen: usize, out: *[max_fds]linux.fd_t) usize {
        if (controllen < @sizeOf(linux.cmsghdr)) return 0;
        if (c.header.level != linux.SOL.SOCKET or c.header.type != linux.SCM.RIGHTS) return 0;
        const len = @min(c.header.len, controllen);
        if (len < @sizeOf(linux.cmsghdr)) return 0;
        const n = @min((len - @sizeOf(linux.cmsghdr)) / @sizeOf(linux.fd_t), max_fds);
        @memcpy(out[0..n], c.fds[0..n]);
        return n;
    }
};

/// An anonymous connected pair. Both ends are close-on-exec; clear it on the
/// end a child should inherit (`inheritable`).
pub fn pair() Error![2]Conn {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0, &fds)) != .SUCCESS)
        return error.SocketFailed;
    return .{ .{ .fd = fds[0] }, .{ .fd = fds[1] } };
}

/// Lets a child started with exec keep this fd.
pub fn inheritable(fd: linux.fd_t) Error!void {
    if (linux.errno(linux.fcntl(fd, linux.F.SETFD, 0)) != .SUCCESS) return error.SocketFailed;
}

/// Adopts an fd inherited from the parent (`--ipc fd:N`), making it
/// close-on-exec again so it doesn't leak into our own children.
pub fn adopt(fd: linux.fd_t) Error!Conn {
    if (linux.errno(linux.fcntl(fd, linux.F.SETFD, linux.FD_CLOEXEC)) != .SUCCESS) return error.SocketFailed;
    return .{ .fd = fd };
}

/// Parses `fd:N`, the `--ipc` form for an inherited socket.
pub fn parseFdAddress(address: []const u8) ?linux.fd_t {
    if (!std.mem.startsWith(u8, address, "fd:")) return null;
    const n = std.fmt.parseInt(u31, address[3..], 10) catch return null;
    return n;
}

fn sockaddr(path: []const u8) Error!linux.sockaddr.un {
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// SOCK_SEQPACKET for zmural's own protocols; SOCK_STREAM for the display
/// protocol, which waywallen's clients speak over a stream.
pub const Kind = enum { seqpacket, stream };

fn newSocket(kind: Kind) Error!linux.fd_t {
    const t: u32 = switch (kind) {
        .seqpacket => linux.SOCK.SEQPACKET,
        .stream => linux.SOCK.STREAM,
    };
    const rc = linux.socket(linux.AF.UNIX, t | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    return @intCast(rc);
}

pub fn connect(path: []const u8) Error!Conn {
    return connectKind(path, .seqpacket);
}

pub fn connectKind(path: []const u8, kind: Kind) Error!Conn {
    const addr = try sockaddr(path);
    const fd = try newSocket(kind);
    errdefer _ = linux.close(fd);
    while (true) switch (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un)))) {
        .SUCCESS => return .{ .fd = fd },
        .INTR => continue,
        .NOENT, .CONNREFUSED => return error.NotFound,
        else => return error.ConnectFailed,
    };
}

pub const Listener = struct {
    fd: linux.fd_t,
    path: [108:0]u8,

    /// Accepts one pending client. Clients running as another user are
    /// dropped (`error.WrongUser`); the caller just keeps listening.
    pub fn accept(l: *Listener) Error!Conn {
        const rc = while (true) {
            const rc = linux.accept4(l.fd, null, null, linux.SOCK.CLOEXEC);
            switch (linux.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => continue,
                .AGAIN => return error.Timeout,
                else => return error.SocketFailed,
            }
        };
        var conn: Conn = .{ .fd = @intCast(rc) };
        errdefer conn.close();
        const cred = try conn.peer();
        if (cred.uid != linux.getuid()) return error.WrongUser;
        return conn;
    }

    /// Closes the socket and removes its path.
    pub fn close(l: *Listener) void {
        _ = linux.unlink(&l.path);
        _ = linux.close(l.fd);
    }
};

/// Listens on `path`. A socket file left by a dead daemon is replaced; a live
/// one is `error.InUse`.
pub fn listen(path: []const u8) Error!Listener {
    return listenKind(path, .seqpacket);
}

pub fn listenKind(path: []const u8, kind: Kind) Error!Listener {
    const addr = try sockaddr(path);
    var l: Listener = .{ .fd = try newSocket(kind), .path = @splat(0) };
    errdefer _ = linux.close(l.fd);
    @memcpy(l.path[0..path.len], path);

    if (connectKind(path, kind)) |c| {
        var live = c;
        live.close();
        return error.InUse;
    } else |err| switch (err) {
        error.NotFound => _ = linux.unlink(&l.path),
        else => {},
    }
    if (linux.errno(linux.bind(l.fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS)
        return error.SocketFailed;
    // Owner only, whatever the umask; the directory is 0700 as well.
    _ = linux.chmod(&l.path, 0o600);
    if (linux.errno(linux.listen(l.fd, 16)) != .SUCCESS) {
        _ = linux.unlink(&l.path);
        return error.SocketFailed;
    }
    return l;
}

/// Creates (if needed) and checks `<xdg_runtime_dir>/zmural`: it must be a
/// real directory, owned by us, with no group or other access. Returns the
/// path, in `buf`.
pub fn runtimeDir(buf: []u8, xdg_runtime_dir: []const u8) Error![:0]const u8 {
    if (xdg_runtime_dir.len == 0 or xdg_runtime_dir[0] != '/') return error.UnsafeDirectory;
    const dir = std.fmt.bufPrintSentinel(buf, "{s}/zmural", .{xdg_runtime_dir}, 0) catch return error.PathTooLong;
    switch (linux.errno(linux.mkdir(dir, 0o700))) {
        .SUCCESS, .EXIST => {},
        else => return error.UnsafeDirectory,
    }
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(linux.AT.FDCWD, dir, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &st)) != .SUCCESS)
        return error.UnsafeDirectory;
    if (st.mode & linux.S.IFMT != linux.S.IFDIR) return error.UnsafeDirectory;
    if (st.uid != linux.getuid()) return error.UnsafeDirectory;
    if (st.mode & 0o077 != 0) return error.UnsafeDirectory;
    return dir;
}

// Tests run on Linux only; Windows uses `pipe.zig`.

const testing = std.testing;
const builtin = @import("builtin");
const Msg = @import("renderer.zig").FromRenderer;

/// A throwaway `$XDG_RUNTIME_DIR` under /tmp: short enough for sun_path.
const TestRuntime = struct {
    buf: [64:0]u8,
    len: usize,

    fn init(name: []const u8) !TestRuntime {
        var t: TestRuntime = .{ .buf = @splat(0), .len = 0 };
        t.len = (try std.fmt.bufPrint(&t.buf, "/tmp/zmural-test-{d}-{s}", .{ linux.getpid(), name })).len;
        if (linux.errno(linux.mkdir(&t.buf, 0o700)) != .SUCCESS) return error.SkipZigTest;
        return t;
    }

    fn xdg(t: *const TestRuntime) []const u8 {
        return t.buf[0..t.len];
    }

    fn deinit(t: *TestRuntime) void {
        var b: [96:0]u8 = @splat(0);
        const sock = std.fmt.bufPrintSentinel(&b, "{s}/zmural/control.sock", .{t.xdg()}, 0) catch return;
        _ = linux.unlink(sock);
        const dir = std.fmt.bufPrintSentinel(&b, "{s}/zmural", .{t.xdg()}, 0) catch return;
        _ = linux.rmdir(dir);
        _ = linux.rmdir(&t.buf);
    }
};

test "a frame and its fds arrive together" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ends = try pair();
    defer ends[0].close();
    defer ends[1].close();

    // Pass one end of a second pair across, then prove it works on the far side.
    var extra = try pair();
    defer extra[1].close();
    try ends[0].send(Msg, .{ .frame_ready = .{ .surface = 2, .generation = 1, .slot = 1, .content_token = 99 } }, &.{extra[0].fd});
    extra[0].close();

    var buf: [max_frame]u8 = undefined;
    var fds: [max_fds]linux.fd_t = undefined;
    const f = try ends[1].recv(&buf, &fds);
    defer f.closeFds();
    const m = try f.decode(Msg);
    try testing.expectEqual(@as(u64, 99), m.frame_ready.content_token);
    try testing.expectEqual(@as(usize, 1), f.fds.len);

    var passed: Conn = .{ .fd = f.fds[0] };
    try passed.send(Msg, .{ .log = .{ .level = .info, .text = "through the passed fd" } }, &.{});
    const g = try extra[1].recv(&buf, &fds);
    try testing.expectEqualStrings("through the passed fd", (try g.decode(Msg)).log.text);
    try testing.expectEqual(@as(usize, 0), g.fds.len);
}

test "frames keep their boundaries" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ends = try pair();
    defer ends[0].close();
    defer ends[1].close();
    try ends[0].send(Msg, .{ .failed = .{ .message = "one" } }, &.{});
    try ends[0].send(Msg, .{ .failed = .{ .message = "two" } }, &.{});
    var buf: [max_frame]u8 = undefined;
    var fds: [max_fds]linux.fd_t = undefined;
    try testing.expectEqualStrings("one", (try (try ends[1].recv(&buf, &fds)).decode(Msg)).failed.message);
    try testing.expectEqualStrings("two", (try (try ends[1].recv(&buf, &fds)).decode(Msg)).failed.message);
    ends[0].close();
    try testing.expectError(error.Disconnected, ends[1].recv(&buf, &fds));
}

test "the peer is known" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ends = try pair();
    defer ends[0].close();
    defer ends[1].close();
    const cred = try ends[0].peer();
    try testing.expectEqual(linux.getuid(), cred.uid);
    try testing.expectEqual(linux.getpid(), cred.pid);
}

test "too many fds is refused before sending" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var ends = try pair();
    defer ends[0].close();
    defer ends[1].close();
    const five = [_]linux.fd_t{ 0, 0, 0, 0, 0 };
    try testing.expectError(error.TooManyFds, ends[0].send(Msg, .{ .ready = .{ .version = 1, .capabilities = "" } }, &five));
}

test "listen, connect, accept, and a second listener is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var t: TestRuntime = try .init("listen");
    defer t.deinit();
    var dir_buf: [128]u8 = undefined;
    const dir = try runtimeDir(&dir_buf, t.xdg());
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/control.sock", .{dir});

    var l = try listen(path);
    defer l.close();
    try testing.expectError(error.InUse, listen(path));

    var buf: [max_frame]u8 = undefined;
    var fds: [max_fds]linux.fd_t = undefined;
    // The refused listener's liveness probe is queued first; to the server it
    // is a client that hangs up at once, which accept loops already handle.
    var probe = try l.accept();
    try testing.expectError(error.Disconnected, probe.recv(&buf, &fds));
    probe.close();

    var client = try connect(path);
    defer client.close();
    var server = try l.accept();
    defer server.close();
    try client.send(Msg, .{ .failed = .{ .message = "hello" } }, &.{});
    try testing.expectEqualStrings("hello", (try (try server.recv(&buf, &fds)).decode(Msg)).failed.message);
}

test "a group-readable runtime directory is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var t: TestRuntime = try .init("mode");
    defer t.deinit();
    var dir_buf: [128]u8 = undefined;
    const dir = try runtimeDir(&dir_buf, t.xdg());
    _ = linux.chmod(dir, 0o750);
    try testing.expectError(error.UnsafeDirectory, runtimeDir(&dir_buf, t.xdg()));
    try testing.expectError(error.UnsafeDirectory, runtimeDir(&dir_buf, "relative/path"));
}

test parseFdAddress {
    try testing.expectEqual(@as(?linux.fd_t, 3), parseFdAddress("fd:3"));
    try testing.expectEqual(@as(?linux.fd_t, null), parseFdAddress("/run/user/1000/zmural/control.sock"));
    try testing.expectEqual(@as(?linux.fd_t, null), parseFdAddress("fd:-1"));
}
