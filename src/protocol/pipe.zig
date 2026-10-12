// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Named-pipe transport (Windows).
//!
//! Every pipe handle is overlapped, on both ends. A synchronous handle
//! serialises I/O, so a reader thread blocked in ReadFile would stall the UI
//! thread's WriteFile on the same handle.
//!
//! Server pipes are created first-instance (FILE_FLAG_FIRST_PIPE_INSTANCE,
//! so nobody can squat the name first; a failure means someone already owns
//! it: `error.InUse`), reject remote clients, and carry a DACL that only
//! admits the user running the daemon (by SID, elevated or not). Multi-client
//! servers (the control pipe) add further instances with `.first = false`.
//!
//! Frames arrive on a reader thread and are handed to a window's message
//! loop with PostMessage, so all protocol handling stays single-threaded.

const std = @import("std");
const w = @import("../os/win32.zig");
const wire = @import("wire.zig");
const identity = @import("../os/identity.zig");

pub const Error = error{
    PipeFailed,
    /// Another process already owns this pipe name.
    InUse,
    /// Nobody is listening on this name.
    NotFound,
    ConnectFailed,
    Timeout,
    Aborted,
    Disconnected,
    OutOfMemory,
    InvalidUtf8,
} || wire.Error;

pub const max_frame = wire.header_len + wire.max_body_len;

/// Heap used for frames crossing threads (thread-safe).
const cross_thread = std.heap.smp_allocator;

pub const Frame = struct {
    opcode: u16,
    body: []const u8,

    /// String fields in the result borrow `body`.
    pub fn decode(f: Frame, comptime M: type) wire.Error!M {
        return wire.decodeMessage(M, f.opcode, f.body);
    }
};

pub const Conn = struct {
    handle: w.HANDLE,
    read_event: w.HANDLE,
    write_event: w.HANDLE,
    /// The server end of a pipe (`listen`), as opposed to a client (`connect`).
    server: bool,
    /// Writes give up after this long (a peer that stops reading must not
    /// freeze the writer). INFINITE by default.
    write_timeout_ms: w.DWORD = w.INFINITE,
    /// Reads give up after this long (INFINITE by default). A timed-out read
    /// can leave half a frame behind, so the connection must be closed after.
    read_timeout_ms: w.DWORD = w.INFINITE,
    /// Set by `shutdown`; the reader checks it before every operation, so a
    /// cancel that lands between two reads isn't lost.
    closing: std.atomic.Value(bool) = .init(false),

    fn init(handle: w.HANDLE, server: bool) Error!Conn {
        const re = w.CreateEventW(null, 1, 0, null) orelse return error.PipeFailed;
        const we = w.CreateEventW(null, 1, 0, null) orelse {
            _ = w.CloseHandle(re);
            return error.PipeFailed;
        };
        return .{ .handle = handle, .read_event = re, .write_event = we, .server = server };
    }

    /// Makes the connection unusable: pending and future I/O fail at once.
    /// Safe from any thread, any number of times.
    pub fn shutdown(c: *Conn) void {
        c.closing.store(true, .release);
        _ = w.CancelIoEx(c.handle, null);
        if (c.server) _ = w.DisconnectNamedPipe(c.handle);
    }

    fn isClosing(c: *Conn) bool {
        return c.closing.load(.acquire);
    }

    /// The process at the other end (server: the client's; client: the server's).
    pub fn peerProcessId(c: *Conn) ?w.DWORD {
        var pid: w.DWORD = 0;
        const ok = if (c.server) w.GetNamedPipeClientProcessId(c.handle, &pid) else w.GetNamedPipeServerProcessId(c.handle, &pid);
        return if (ok != 0 and pid != 0) pid else null;
    }

    /// Only call once no thread is using the connection any more.
    pub fn close(c: *Conn) void {
        _ = w.CloseHandle(c.handle);
        _ = w.CloseHandle(c.read_event);
        _ = w.CloseHandle(c.write_event);
    }

    pub fn writeAll(c: *Conn, bytes: []const u8) Error!void {
        var done: usize = 0;
        while (done < bytes.len) {
            if (c.isClosing()) return error.Disconnected;
            var ov: w.OVERLAPPED = .{ .hEvent = c.write_event };
            const chunk: w.DWORD = @intCast(@min(bytes.len - done, 1 << 20)); // zsnag:ok — bounded by @min
            if (w.WriteFile(c.handle, bytes[done..].ptr, chunk, null, &ov) == 0 and w.GetLastError() != w.ERROR_IO_PENDING)
                return error.Disconnected;
            if (w.WaitForSingleObject(c.write_event, c.write_timeout_ms) == w.WAIT_TIMEOUT) {
                _ = w.CancelIoEx(c.handle, &ov);
                var ignored: w.DWORD = 0;
                _ = w.GetOverlappedResult(c.handle, &ov, &ignored, 1);
                return error.Timeout;
            }
            var n: w.DWORD = 0;
            if (w.GetOverlappedResult(c.handle, &ov, &n, 1) == 0 or n == 0) return error.Disconnected;
            done += n;
        }
    }

    pub fn readExact(c: *Conn, buf: []u8) Error!void {
        var done: usize = 0;
        while (done < buf.len) {
            if (c.isClosing()) return error.Disconnected;
            var ov: w.OVERLAPPED = .{ .hEvent = c.read_event };
            const chunk: w.DWORD = @intCast(@min(buf.len - done, 1 << 20)); // zsnag:ok — bounded by @min
            if (w.ReadFile(c.handle, buf[done..].ptr, chunk, null, &ov) == 0 and w.GetLastError() != w.ERROR_IO_PENDING)
                return error.Disconnected;
            if (w.WaitForSingleObject(c.read_event, c.read_timeout_ms) == w.WAIT_TIMEOUT) {
                _ = w.CancelIoEx(c.handle, &ov);
                var ignored: w.DWORD = 0;
                _ = w.GetOverlappedResult(c.handle, &ov, &ignored, 1);
                return error.Timeout;
            }
            var n: w.DWORD = 0;
            if (w.GetOverlappedResult(c.handle, &ov, &n, 1) == 0 or n == 0) return error.Disconnected;
            done += n;
        }
    }

    /// Any message that fits a frame can be sent (64 KiB of stack).
    pub fn send(c: *Conn, comptime M: type, msg: M) Error!void {
        var buf: [max_frame]u8 = undefined;
        try c.writeAll(try wire.encodeMessage(M, msg, &buf));
    }

    /// Blocks until one whole frame has arrived; its body lives in `buf`.
    pub fn recv(c: *Conn, buf: *[max_frame]u8) Error!Frame {
        try c.readExact(buf[0..wire.header_len]);
        const h = wire.Header.read(buf[0..wire.header_len]);
        const body = buf[wire.header_len..][0..h.body_len];
        try c.readExact(body);
        return .{ .opcode = h.opcode, .body = body };
    }

    /// Server side: waits for the client to connect, giving up after
    /// `timeout_ms` or as soon as `abort` (e.g. the child process) is signalled.
    pub fn waitForClient(c: *Conn, timeout_ms: w.DWORD, abort: ?w.HANDLE) Error!void {
        if (c.isClosing()) return error.Aborted;
        var ov: w.OVERLAPPED = .{ .hEvent = c.read_event };
        if (w.ConnectNamedPipe(c.handle, &ov) != 0) return;
        switch (w.GetLastError()) {
            w.ERROR_PIPE_CONNECTED => return,
            w.ERROR_IO_PENDING => {},
            else => return error.ConnectFailed,
        }
        var handles = [2]w.HANDLE{ c.read_event, c.read_event };
        var count: w.DWORD = 1;
        if (abort) |a| {
            handles[1] = a;
            count = 2;
        }
        const r = w.WaitForMultipleObjects(count, &handles, 0, timeout_ms);
        var n: w.DWORD = 0;
        if (r == w.WAIT_OBJECT_0) {
            if (w.GetOverlappedResult(c.handle, &ov, &n, 0) == 0) return error.ConnectFailed;
            return;
        }
        _ = w.CancelIoEx(c.handle, &ov);
        _ = w.GetOverlappedResult(c.handle, &ov, &n, 1);
        return if (r == w.WAIT_TIMEOUT) error.Timeout else error.Aborted;
    }
};

pub const ListenOptions = struct {
    /// Claim the name: fail with `error.InUse` if the pipe already exists.
    first: bool = true,
    /// 1 for a private per-renderer pipe; more for a multi-client server.
    max_instances: w.DWORD = 1,
};

/// Server end: creates one pipe instance. Pair with `Conn.waitForClient`.
pub fn listen(gpa: std.mem.Allocator, name: []const u8, opts: ListenOptions) Error!Conn {
    const name_w = try toUtf16(gpa, name);
    defer gpa.free(name_w);

    // Protected DACL with a single ACE: GENERIC_ALL for the current user,
    // named by SID. Not "owner rights" (OW): in an elevated process the
    // owner is the Administrators group, which would shut out the user's own
    // non-elevated CLI and settings window.
    const user = identity.currentUser() orelse return error.PipeFailed;
    var sid_buf: [192]u8 = undefined;
    const sid = user.format(&sid_buf) orelse return error.PipeFailed;
    var sddl_buf: [256]u8 = undefined;
    const sddl = std.fmt.bufPrint(&sddl_buf, "D:P(A;;GA;;;{s})", .{sid}) catch return error.PipeFailed;
    const sddl_w = try toUtf16(gpa, sddl);
    defer gpa.free(sddl_w);
    var sd: ?*anyopaque = null;
    if (w.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_w, w.SDDL_REVISION_1, &sd, null) == 0)
        return error.PipeFailed;
    defer _ = w.LocalFree(sd);
    var sa: w.SECURITY_ATTRIBUTES = .{ .lpSecurityDescriptor = sd };

    const handle = w.CreateNamedPipeW(
        name_w,
        w.PIPE_ACCESS_DUPLEX | w.FILE_FLAG_OVERLAPPED | (if (opts.first) w.FILE_FLAG_FIRST_PIPE_INSTANCE else 0),
        w.PIPE_TYPE_BYTE | w.PIPE_READMODE_BYTE | w.PIPE_WAIT | w.PIPE_REJECT_REMOTE_CLIENTS,
        opts.max_instances,
        64 * 1024,
        64 * 1024,
        0,
        &sa,
    );
    if (handle == w.INVALID_HANDLE_VALUE) return switch (w.GetLastError()) {
        // The name exists already: first-instance creation is refused, or
        // (for a single-instance pipe) every instance is taken.
        w.ERROR_ACCESS_DENIED, w.ERROR_PIPE_BUSY => error.InUse,
        else => error.PipeFailed,
    };
    return Conn.init(handle, true) catch |err| {
        _ = w.CloseHandle(handle);
        return err;
    };
}

/// Client end. If every instance is busy, waits up to `busy_timeout_ms` in
/// all for one to free up (another client may grab each freed one first).
pub fn connect(gpa: std.mem.Allocator, name: []const u8, busy_timeout_ms: w.DWORD) Error!Conn {
    const name_w = try toUtf16(gpa, name);
    defer gpa.free(name_w);
    const deadline = w.GetTickCount64() + busy_timeout_ms;
    const handle = while (true) {
        const h = w.CreateFileW(
            name_w,
            w.GENERIC_READ | w.GENERIC_WRITE,
            0,
            null,
            w.OPEN_EXISTING,
            w.FILE_FLAG_OVERLAPPED | w.SECURITY_SQOS_PRESENT | w.SECURITY_IDENTIFICATION,
            null,
        );
        if (h != w.INVALID_HANDLE_VALUE) break h;
        switch (w.GetLastError()) {
            w.ERROR_FILE_NOT_FOUND => return error.NotFound,
            w.ERROR_PIPE_BUSY => {
                const left = deadline -| w.GetTickCount64();
                // WaitNamedPipe treats 0 as "the server's default timeout", so never pass it.
                if (left == 0) return error.Timeout;
                if (w.WaitNamedPipeW(name_w, @intCast(left)) == 0) return error.Timeout; // zsnag:ok — left <= busy_timeout_ms, a DWORD
            },
            else => return error.ConnectFailed,
        }
    };
    return Conn.init(handle, false) catch |err| {
        _ = w.CloseHandle(handle);
        return err;
    };
}

fn toUtf16(gpa: std.mem.Allocator, s: []const u8) Error![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, s) catch |e| switch (e) {
        error.InvalidWtf8 => error.InvalidUtf8,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// A frame handed from a reader thread to a window's message loop. The
/// receiver owns it and must call `destroy`.
pub const Inbound = struct {
    opcode: u16,
    body: []u8,

    fn create(f: Frame) error{OutOfMemory}!*Inbound {
        const in = try cross_thread.create(Inbound);
        errdefer cross_thread.destroy(in);
        in.* = .{ .opcode = f.opcode, .body = try cross_thread.dupe(u8, f.body) };
        return in;
    }

    pub fn frame(in: *const Inbound) Frame {
        return .{ .opcode = in.opcode, .body = in.body };
    }

    pub fn destroy(in: *Inbound) void {
        cross_thread.free(in.body);
        cross_thread.destroy(in);
    }
};

/// What a reader thread posts. LPARAM 0 means the connection ended, 1 that a
/// client connected (only with `notify_connect`), anything else is a frame.
pub const Notice = union(enum) {
    ended,
    connected,
    frame: *Inbound,

    const connected_lparam: w.LPARAM = 1;

    pub fn fromLparam(l: w.LPARAM) Notice {
        return switch (l) {
            0 => .ended,
            connected_lparam => .connected,
            else => .{ .frame = @ptrFromInt(@as(usize, @bitCast(l))) },
        };
    }
};

pub const Reader = struct {
    conn: *Conn,
    /// Receives `msg` with WPARAM = `tag` and LPARAM = *Inbound, or 0 once
    /// the connection has ended.
    hwnd: w.HWND,
    msg: w.UINT,
    tag: usize = 0,
    /// Server side: wait this long for the client first (0: already connected).
    accept_timeout_ms: w.DWORD = 0,
    accept_abort: ?w.HANDLE = null,
    /// Post `Notice.connected` once a client connects.
    notify_connect: bool = false,
};

/// Starts a reader thread. `r.conn` must outlive it: end it with `stopReader`.
pub fn startReader(r: Reader) Error!w.HANDLE {
    const boxed = try cross_thread.create(Reader);
    boxed.* = r;
    return w.CreateThread(null, 0, readerMain, boxed, 0, null) orelse {
        cross_thread.destroy(boxed);
        return error.PipeFailed;
    };
}

/// Shuts the connection down and waits for its reader thread to exit, then
/// closes the thread handle. Repeats the shutdown until the thread is gone, so
/// a cancel that races the reader's next read can't leave it blocked.
pub fn stopReader(conn: *Conn, thread: w.HANDLE) void {
    while (true) {
        conn.shutdown();
        if (w.WaitForSingleObject(thread, 100) == w.WAIT_OBJECT_0) break;
    }
    _ = w.CloseHandle(thread);
}

fn readerMain(param: ?*anyopaque) callconv(.winapi) w.DWORD {
    const boxed: *Reader = @ptrCast(@alignCast(param orelse return 1)); // zsnag:ok — we allocated it as *Reader
    const r = boxed.*;
    cross_thread.destroy(boxed);

    run: {
        if (r.accept_timeout_ms != 0) {
            r.conn.waitForClient(r.accept_timeout_ms, r.accept_abort) catch break :run;
            if (r.notify_connect) _ = w.PostMessageW(r.hwnd, r.msg, r.tag, Notice.connected_lparam);
        }
        var buf: [max_frame]u8 = undefined;
        while (true) {
            const f = r.conn.recv(&buf) catch break :run;
            const in = Inbound.create(f) catch break :run;
            if (w.PostMessageW(r.hwnd, r.msg, r.tag, @bitCast(@intFromPtr(in))) == 0) {
                in.destroy();
                break :run;
            }
        }
    }
    _ = w.PostMessageW(r.hwnd, r.msg, r.tag, 0);
    return 0;
}
