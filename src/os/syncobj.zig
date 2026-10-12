// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! DRM sync objects (Linux), through the kernel's ioctls directly (no
//! libdrm). The display protocol hands a consumer one binary syncobj per
//! frame; the consumer puts its "done reading" fence in it (or signals it)
//! and says so, and the daemon exports that fence as a sync_file, which
//! polls readable once the GPU is finished. So waiting fits a poll loop.
//!
//! A syncobj lives on a DRM device fd, but its exported fd works with any.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ IoctlFailed, NoFence };

const Create = extern struct { handle: u32 = 0, flags: u32 = 0 };
const Destroy = extern struct { handle: u32, pad: u32 = 0 };
/// The pre-6.x layout (no `point`); the kernel zero-extends it.
const Handle = extern struct { handle: u32 = 0, flags: u32 = 0, fd: i32 = -1, pad: u32 = 0 };
const Array = extern struct { handles: u64, count_handles: u32, pad: u32 = 0 };

const create_signaled: u32 = 1 << 0;
const export_sync_file: u32 = 1 << 0;
const import_sync_file: u32 = 1 << 0;

fn iowr(nr: u8, comptime T: type) u32 {
    // _IOWR('d', nr, T): read|write, size, type 'd', number.
    return (3 << 30) | (@as(u32, @sizeOf(T)) << 16) | (@as(u32, 'd') << 8) | nr;
}

const ioctl_create = iowr(0xBF, Create);
const ioctl_destroy = iowr(0xC0, Destroy);
const ioctl_handle_to_fd = iowr(0xC1, Handle);
const ioctl_fd_to_handle = iowr(0xC2, Handle);
const ioctl_reset = iowr(0xC4, Array);
const ioctl_signal = iowr(0xC5, Array);

fn ioctl(fd: linux.fd_t, req: u32, arg: *anyopaque) Error!void {
    while (true) switch (linux.errno(linux.ioctl(fd, req, @intFromPtr(arg)))) {
        .SUCCESS => return,
        .INTR, .AGAIN => continue,
        .INVAL => return error.NoFence, // e.g. exporting a syncobj with no fence yet
        else => return error.IoctlFailed,
    };
}

/// A syncobj on `dev` (a DRM device fd), with its shareable fd.
pub const SyncObj = struct {
    dev: linux.fd_t,
    handle: u32,
    /// The syncobj itself as an fd (what the display protocol sends).
    fd: linux.fd_t,

    pub fn create(dev: linux.fd_t, signaled: bool) Error!SyncObj {
        var c: Create = .{ .flags = if (signaled) create_signaled else 0 };
        try ioctl(dev, ioctl_create, &c);
        errdefer destroyHandle(dev, c.handle);
        var h: Handle = .{ .handle = c.handle };
        try ioctl(dev, ioctl_handle_to_fd, &h);
        return .{ .dev = dev, .handle = c.handle, .fd = h.fd };
    }

    /// Adopts a syncobj fd received from someone else.
    pub fn import(dev: linux.fd_t, fd: linux.fd_t) Error!SyncObj {
        var h: Handle = .{ .fd = fd };
        try ioctl(dev, ioctl_fd_to_handle, &h);
        return .{ .dev = dev, .handle = h.handle, .fd = fd };
    }

    pub fn destroy(s: *SyncObj) void {
        destroyHandle(s.dev, s.handle);
        if (s.fd >= 0) _ = linux.close(s.fd);
        s.fd = -1;
    }

    /// Unsignals it (drops its fence), ready for the next frame.
    pub fn reset(s: *SyncObj) Error!void {
        var h = s.handle;
        var a: Array = .{ .handles = @intFromPtr(&h), .count_handles = 1 };
        try ioctl(s.dev, ioctl_reset, &a);
    }

    /// Signals it now (a consumer that's done without GPU work).
    pub fn signal(s: *SyncObj) Error!void {
        var h = s.handle;
        var a: Array = .{ .handles = @intFromPtr(&h), .count_handles = 1 };
        try ioctl(s.dev, ioctl_signal, &a);
    }

    /// Its current fence as a sync_file: pollable, readable once signaled.
    /// `error.NoFence` if nothing was put in it yet.
    pub fn exportSyncFile(s: *const SyncObj) Error!linux.fd_t {
        var h: Handle = .{ .handle = s.handle, .flags = export_sync_file };
        try ioctl(s.dev, ioctl_handle_to_fd, &h);
        return h.fd;
    }

    /// Replaces its fence with the one in `sync_file` (which stays the caller's).
    pub fn importSyncFile(s: *SyncObj, sync_file: linux.fd_t) Error!void {
        var h: Handle = .{ .handle = s.handle, .flags = import_sync_file, .fd = sync_file };
        try ioctl(s.dev, ioctl_fd_to_handle, &h);
    }
};

fn destroyHandle(dev: linux.fd_t, handle: u32) void {
    var d: Destroy = .{ .handle = handle };
    ioctl(dev, ioctl_destroy, &d) catch {}; // zsnag:ok — nothing to do if the kernel already dropped it
}

/// An already-signaled sync_file: the acquire fence for a frame whose GPU
/// work is known complete.
pub fn signaledSyncFile(dev: linux.fd_t) Error!linux.fd_t {
    var s = try SyncObj.create(dev, true);
    defer s.destroy();
    return s.exportSyncFile();
}

/// Is this sync_file signaled yet? (It polls readable when it is.)
pub fn isSignaled(sync_file: linux.fd_t) bool {
    var p = [_]linux.pollfd{.{ .fd = sync_file, .events = linux.POLL.IN, .revents = 0 }};
    return linux.poll(&p, 1, 0) == 1 and p[0].revents & linux.POLL.IN != 0;
}

/// The first render node, for daemon-side syncobjs (any device will do).
pub fn openRenderNode() ?linux.fd_t {
    var buf: [32:0]u8 = undefined;
    var minor: u32 = 128;
    while (minor < 192) : (minor += 1) {
        const path = std.fmt.bufPrintSentinel(&buf, "/dev/dri/renderD{d}", .{minor}, 0) catch return null;
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(rc) == .SUCCESS) return @intCast(rc);
    }
    return null;
}

test "a syncobj round trips through signal, export and reset" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const dev = openRenderNode() orelse return error.SkipZigTest;
    defer _ = linux.close(dev);

    var s = try SyncObj.create(dev, false);
    defer s.destroy();
    // No fence yet: nothing to export.
    try std.testing.expectError(error.NoFence, s.exportSyncFile());
    try s.signal();
    const f = try s.exportSyncFile();
    defer _ = linux.close(f);
    try std.testing.expect(isSignaled(f));

    // Another holder of the fd sees the same object.
    var other = try SyncObj.import(dev, s.fd);
    try other.reset();
    try std.testing.expectError(error.NoFence, s.exportSyncFile());
    other.fd = -1; // shared with `s`; only its handle is ours
    other.destroy();

    const pre = try signaledSyncFile(dev);
    defer _ = linux.close(pre);
    try std.testing.expect(isSignaled(pre));
    // Importing a signaled sync_file signals the syncobj.
    try s.importSyncFile(pre);
    const g = try s.exportSyncFile();
    defer _ = linux.close(g);
    try std.testing.expect(isSignaled(g));
}
