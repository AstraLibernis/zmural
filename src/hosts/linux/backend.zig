// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Picks the Linux display host for the current desktop.

const std = @import("std");
const linux = std.os.linux;

pub const Backend = enum {
    /// Plasma loads our wallpaper plugin itself; the daemon just waits for it.
    kde_plasma,
    /// GNOME Shell extension (later).
    gnome_shell,
    /// zmural in its `--layer-shell` mode, started and supervised by the
    /// daemon (Hyprland, Sway, Niri, River, COSMIC, Wayfire, labwc...).
    layer_shell,
    /// No live host: set a still frame through the XDG wallpaper portal.
    portal_static,
};

/// `xdg_current_desktop` is `$XDG_CURRENT_DESKTOP` (colon-separated, e.g.
/// "ubuntu:GNOME"). `has_layer_shell` is whether the compositor advertises
/// zwlr_layer_shell_v1 and linux-dmabuf.
pub fn pick(xdg_current_desktop: []const u8, has_layer_shell: bool) Backend {
    var it = std.mem.splitScalar(u8, xdg_current_desktop, ':');
    while (it.next()) |raw| {
        const de = std.mem.trim(u8, raw, " ");
        if (std.ascii.eqlIgnoreCase(de, "KDE")) return .kde_plasma;
        if (std.ascii.eqlIgnoreCase(de, "GNOME")) return .gnome_shell;
    }
    return if (has_layer_shell) .layer_shell else .portal_static;
}

/// How the layer-shell host tells the daemon why it ended (its exit code).
/// The compositor has no wlr-layer-shell or no DMA-BUF: starting it again
/// can't help.
pub const exit_unsupported: u8 = 3;
/// Another host already shows on this Wayland display.
pub const exit_already_running: u8 = 4;

/// The Wayland socket a client would connect to, or null when there is
/// none to name (`wayland_display` is `$WAYLAND_DISPLAY`).
pub fn waylandSocket(buf: []u8, runtime_dir: []const u8, wayland_display: ?[]const u8) ?[:0]const u8 {
    const name = if (wayland_display) |n| (if (n.len > 0) n else "wayland-0") else "wayland-0";
    if (name[0] == '/') return std.fmt.bufPrintSentinel(buf, "{s}", .{name}, 0) catch null;
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ runtime_dir, name }, 0) catch null;
}

/// One layer-shell host per Wayland display: the host holds this file's
/// lock (flock) for as long as it runs. `zmural_dir` is zmural's private
/// runtime directory.
pub fn lockPath(buf: []u8, zmural_dir: []const u8, wayland_display: ?[]const u8) ?[:0]const u8 {
    const name = if (wayland_display) |n| (if (n.len > 0) n else "wayland-0") else "wayland-0";
    const path = std.fmt.bufPrintSentinel(buf, "{s}/layer-shell.{s}.lock", .{ zmural_dir, name }, 0) catch return null;
    // A display named by a path: keep the lock file inside our directory.
    for (path[zmural_dir.len + 1 ..]) |*c| {
        if (c.* == '/') c.* = '_';
    }
    return path;
}

pub const LockError = error{ Held, CannotLock };

/// Takes the lock. The descriptor is kept open for the life of the process;
/// the kernel drops the lock when it ends, however it ends.
pub fn takeLock(path: [:0]const u8) LockError!linux.fd_t {
    const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.CannotLock;
    const fd: linux.fd_t = @intCast(rc);
    switch (linux.errno(linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
        .SUCCESS => return fd,
        .AGAIN => {
            _ = linux.close(fd);
            return error.Held;
        },
        else => {
            _ = linux.close(fd);
            return error.CannotLock;
        },
    }
}

/// Is a host running on that display? (Asked by the daemon before it starts one.)
pub fn lockHeld(path: [:0]const u8) bool {
    const fd = takeLock(path) catch |err| return err == error.Held;
    _ = linux.close(fd);
    return false;
}

test "one host per display: the lock" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "/tmp/zmural-lock-test-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdir(dir, 0o700);
    defer _ = linux.rmdir(dir);
    var buf: [128]u8 = undefined;
    const path = lockPath(&buf, dir, "wayland-7").?;
    defer _ = linux.unlink(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/layer-shell.wayland-7.lock"));
    try std.testing.expect(!lockHeld(path));
    const fd = try takeLock(path);
    try std.testing.expect(lockHeld(path));
    try std.testing.expectError(error.Held, takeLock(path));
    _ = linux.close(fd);
    try std.testing.expect(!lockHeld(path));

    // A display named by a path stays one file in our directory; none named means wayland-0.
    var buf2: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/run/u/zmural/layer-shell._tmp_w.lock", lockPath(&buf2, "/run/u/zmural", "/tmp/w").?);
    try std.testing.expectEqualStrings("/run/u/zmural/layer-shell.wayland-0.lock", lockPath(&buf2, "/run/u/zmural", null).?);
    try std.testing.expectEqualStrings("/run/u/wayland-0", waylandSocket(&buf2, "/run/u", null).?);
    try std.testing.expectEqualStrings("/tmp/w", waylandSocket(&buf2, "/run/u", "/tmp/w").?);
}

test pick {
    try std.testing.expectEqual(Backend.kde_plasma, pick("KDE", true));
    try std.testing.expectEqual(Backend.gnome_shell, pick("ubuntu:GNOME", true));
    try std.testing.expectEqual(Backend.layer_shell, pick("Hyprland", true));
    try std.testing.expectEqual(Backend.portal_static, pick("", false));
}
