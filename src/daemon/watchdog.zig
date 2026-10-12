// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The watchdog: zmural started again by itself as `zmural --watchdog --parent <pid>`.
//!
//! On Windows the kernel already reaps the renderers: they live in a
//! kill-on-close Job Object that dies with the daemon. What's left for the
//! watchdog is the desktop: once the daemon is gone, however it went, repaint
//! the static wallpaper so no frozen frame lingers. The daemon terminates the
//! watchdog itself on a clean exit.
//!
//! TODO (Linux): wait on a pidfd and kill the renderers' process group.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");

/// `args`: what follows `--watchdog` on the command line.
pub fn run(args: []const []const u8) !void {
    const parent = parseParent(args) catch |err| {
        std.log.err("watchdog: {s}; usage: --watchdog --parent <pid>", .{@errorName(err)});
        std.process.exit(2);
    };

    if (builtin.os.tag != .windows) {
        std.log.err("watchdog: not implemented on this OS yet", .{});
        std.process.exit(1);
    }
    const w = zmural.os.win32;
    const handle = w.OpenProcess(w.SYNCHRONIZE | w.PROCESS_QUERY_LIMITED_INFORMATION, 0, parent) orelse {
        std.log.err("watchdog: cannot watch process {d}", .{parent});
        std.process.exit(1);
    };
    defer _ = w.CloseHandle(handle);
    // The daemon started us, so it must be older than we are. If the pid
    // was already reused by a newer process, it isn't our daemon: do nothing.
    if (!startedBefore(handle, w.GetCurrentProcess())) {
        std.log.err("watchdog: process {d} is not the daemon that started us", .{parent});
        std.process.exit(1);
    }
    _ = w.WaitForSingleObject(handle, w.INFINITE);
    zmural.os.desktop.refreshStaticWallpaper();
}

fn startedBefore(a: anytype, b: anytype) bool {
    const w = zmural.os.win32;
    var ca: w.FILETIME = undefined;
    var cb: w.FILETIME = undefined;
    var unused: [3]w.FILETIME = undefined;
    if (w.GetProcessTimes(a, &ca, &unused[0], &unused[1], &unused[2]) == 0) return false;
    if (w.GetProcessTimes(b, &cb, &unused[0], &unused[1], &unused[2]) == 0) return false;
    return ca.value() <= cb.value();
}

fn parseParent(args: []const []const u8) error{ MissingArgument, InvalidCharacter, Overflow }!u32 {
    if (args.len != 2 or !std.mem.eql(u8, args[0], "--parent")) return error.MissingArgument;
    return std.fmt.parseInt(u32, args[1], 10);
}

test parseParent {
    try std.testing.expectEqual(@as(u32, 1234), try parseParent(&.{ "--parent", "1234" }));
    try std.testing.expectError(error.MissingArgument, parseParent(&.{}));
    try std.testing.expectError(error.InvalidCharacter, parseParent(&.{ "--parent", "x" }));
}
