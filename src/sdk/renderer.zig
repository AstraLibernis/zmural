// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Renderer SDK: what every renderer process shares. A renderer is started as
//! `zmural-<kind> --ipc <address> --path <wallpaper>`, connects back to the
//! daemon, and speaks `protocol.renderer`.
//!
//! Lifecycle: connect -> `ready` -> `init` -> `add_surface`... -> `play` /
//! `pause` ... -> `stop`. If the daemon's end of the pipe closes, the renderer
//! exits: it never outlives its daemon.

const std = @import("std");

pub const protocol = @import("../protocol/renderer.zig");
const pipe = @import("../protocol/pipe.zig");
const w = @import("../os/win32.zig");

/// A renderer's connection to the daemon (Windows).
pub const Session = struct {
    conn: pipe.Conn,

    /// Connects to the daemon and announces this renderer's capabilities.
    pub fn open(gpa: std.mem.Allocator, args: Args, capabilities: []const u8) pipe.Error!Session {
        var conn = try pipe.connect(gpa, args.ipc, 2000);
        errdefer conn.close();
        try conn.send(protocol.FromRenderer, .{ .ready = .{ .version = protocol.version, .capabilities = capabilities } });
        return .{ .conn = conn };
    }

    /// Daemon commands arrive at `hwnd` as `msg` (see `pipe.Reader`).
    pub fn startReader(s: *Session, hwnd: w.HWND, msg: w.UINT) pipe.Error!w.HANDLE {
        return pipe.startReader(.{ .conn = &s.conn, .hwnd = hwnd, .msg = msg });
    }

    pub fn send(s: *Session, msg: protocol.FromRenderer) pipe.Error!void {
        return s.conn.send(protocol.FromRenderer, msg);
    }

    /// Forwards a log line to the daemon, which prints it. Best effort.
    pub fn log(s: *Session, level: protocol.LogLevel, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch "(log line too long)";
        // A lost log line is not worth failing over; a dead pipe surfaces on the next real send.
        s.send(.{ .log = .{ .level = level, .text = text } }) catch {}; // zsnag:ok — best-effort logging
    }
};

pub const Args = struct {
    ipc: []const u8,
    path: []const u8,
};

pub const ArgsError = error{ MissingValue, MissingArgument, UnknownArgument };

/// Parses a renderer's command line: what follows `--renderer <kind>`.
pub fn parseArgs(args: []const []const u8) ArgsError!Args {
    var ipc: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const slot = if (std.mem.eql(u8, a, "--ipc"))
            &ipc
        else if (std.mem.eql(u8, a, "--path"))
            &path
        else
            return error.UnknownArgument;
        i += 1;
        if (i == args.len) return error.MissingValue;
        slot.* = args[i];
    }
    return .{
        .ipc = ipc orelse return error.MissingArgument,
        .path = path orelse return error.MissingArgument,
    };
}

/// Shared entry point while renderers are unimplemented: validates the
/// command line, reports what would happen, and exits non-zero.
pub fn stub(kind: []const u8, args_in: []const []const u8) !void {
    const args = parseArgs(args_in) catch |err| {
        std.log.err("renderer {s}: {s}; usage: --renderer {s} --ipc <address> --path <wallpaper>", .{ kind, @errorName(err), kind });
        std.process.exit(2);
    };
    std.log.err("renderer {s}: would render '{s}' (ipc {s}); not implemented yet", .{ kind, args.path, args.ipc });
    std.process.exit(1);
}

test parseArgs {
    const a = try parseArgs(&.{ "--ipc", "\\\\.\\pipe\\x", "--path", "C:\\wp\\a.mp4" });
    try std.testing.expectEqualStrings("C:\\wp\\a.mp4", a.path);
    try std.testing.expectError(error.MissingArgument, parseArgs(&.{ "--ipc", "x" }));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{"--path"}));
    try std.testing.expectError(error.UnknownArgument, parseArgs(&.{"--nope"}));
}
