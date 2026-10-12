// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The settings window, inside zmural's own process (owner's decision,
//! 2026-09-30): it runs on a thread of its own and talks to the daemon over
//! the control protocol like any client, but a crash in it takes zmural down
//! with it. That is on purpose: a window that died alone could leave settings
//! quietly not working.
//!
//! `open`, `close` and `isOpen` are for the daemon's main thread only.

const std = @import("std");
const builtin = @import("builtin");
const app = @import("app.zig");

pub const Env = @import("env.zig").Env;

const log = std.log.scoped(.settings);

var env: Env = undefined;
var thread: ?std.Thread = null;
var running: std.atomic.Value(bool) = .init(false);
var token_buf: [256]u8 = undefined;
var token_len: usize = 0;

/// Opens the window, or brings the open one to the front. `token` is the
/// desktop's activation token (Linux), or empty.
pub fn open(e: Env, token: []const u8) void {
    if (running.load(.acquire)) {
        log.info("window: already open; bringing it to the front", .{});
        return app.platform.raise(token);
    }
    // The last window's thread has ended; collect it.
    if (thread) |t| t.join();
    thread = null;
    env = e;
    token_len = @min(token.len, token_buf.len);
    @memcpy(token_buf[0..token_len], token[0..token_len]);
    app.platform.prepare() catch |err| return log.err("window: can't open: {s}", .{@errorName(err)});
    running.store(true, .release);
    thread = std.Thread.spawn(.{}, threadMain, .{}) catch |err| {
        running.store(false, .release);
        return log.err("window: can't start its thread: {s}", .{@errorName(err)});
    };
}

fn threadMain() void {
    defer running.store(false, .release);
    app.platform.run(env, token_buf[0..token_len]) catch |err|
        return log.err("window: closed by an error: {s}", .{@errorName(err)});
    log.info("window: closed", .{});
}

/// Closes the window and waits for its thread. Before zmural exits.
pub fn close() void {
    const t = thread orelse return;
    if (running.load(.acquire)) app.platform.requestClose();
    t.join();
    thread = null;
}

pub fn isOpen() bool {
    return running.load(.acquire);
}

/// The window's Uninstall was confirmed (Linux): zmural removes itself once
/// it has stopped. After `close`.
pub fn uninstallRequested() bool {
    return app.uninstall_on_exit.load(.acquire);
}

test {
    _ = app;
    _ = @import("gui.zig");
    _ = @import("keymap.zig");
    if (builtin.os.tag == .windows) {
        _ = @import("sys.zig");
        _ = @import("thumbs.zig");
    }
    if (builtin.os.tag == .linux) _ = @import("platform_linux.zig");
}

test "a close asked for while the window is still opening isn't lost (Windows)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // `close` right after `open` reaches the window's thread before its
    // window exists; quitting used to wait on that thread forever.
    for (0..20) |_| {
        open(.{ .gpa = std.testing.allocator, .io = std.testing.io }, "");
        close();
        try std.testing.expect(!isOpen());
    }
}
