// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Tests for the Windows named-pipe transport, run over real pipes in-process.

const std = @import("std");
const builtin = @import("builtin");
const w = @import("../os/win32.zig");
const pipe = @import("pipe.zig");
const control = @import("control.zig");

const testing = std.testing;
const gpa = testing.allocator;

var counter: u32 = 0;

fn uniqueName(buf: []u8) []const u8 {
    counter += 1;
    return std.fmt.bufPrint(buf, "\\\\.\\pipe\\zmural-test-{d}-{d}", .{ w.GetCurrentProcessId(), counter }) catch unreachable; // zsnag:ok — buffer is large enough
}

fn skipUnlessWindows() !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
}

test "frames travel both ways, and each end knows the other's pid" {
    try skipUnlessWindows();
    var name_buf: [96]u8 = undefined;
    const name = uniqueName(&name_buf);
    var server = try pipe.listen(gpa, name, .{});
    defer server.close();
    var client = try pipe.connect(gpa, name, 1000);
    defer client.close();
    try server.waitForClient(1000, null); // already connected: returns at once

    try client.send(control.Request, .{ .apply = .{ .path = "C:\\wp\\rain.mp4" } });
    var buf: [pipe.max_frame]u8 = undefined;
    const got = try (try server.recv(&buf)).decode(control.Request);
    try testing.expectEqualStrings("C:\\wp\\rain.mp4", got.apply.path);

    try server.send(control.Event, .ok);
    try testing.expect((try (try client.recv(&buf)).decode(control.Event)) == .ok);

    try testing.expectEqual(w.GetCurrentProcessId(), server.peerProcessId().?);
    try testing.expectEqual(w.GetCurrentProcessId(), client.peerProcessId().?);
}

test "a name that's already taken reports InUse; a missing one NotFound" {
    try skipUnlessWindows();
    var name_buf: [96]u8 = undefined;
    const name = uniqueName(&name_buf);
    var first = try pipe.listen(gpa, name, .{});
    defer first.close();
    try testing.expectError(error.InUse, pipe.listen(gpa, name, .{}));
    try testing.expectError(error.NotFound, pipe.connect(gpa, "\\\\.\\pipe\\zmural-test-nobody-home", 100));
}

test "waitForClient gives up when nobody connects" {
    try skipUnlessWindows();
    var name_buf: [96]u8 = undefined;
    var server = try pipe.listen(gpa, uniqueName(&name_buf), .{});
    defer server.close();
    try testing.expectError(error.Timeout, server.waitForClient(100, null));
}

test "a write to a peer that stops reading times out instead of hanging (audit L6)" {
    try skipUnlessWindows();
    var name_buf: [96]u8 = undefined;
    const name = uniqueName(&name_buf);
    var server = try pipe.listen(gpa, name, .{});
    defer server.close();
    var client = try pipe.connect(gpa, name, 1000);
    defer client.close();
    server.write_timeout_ms = 200;
    const chunk: [16384]u8 = @splat(0x55);
    var err: ?pipe.Error = null;
    // The pipe buffers 64 KiB; far more than that can never be written while nobody reads.
    for (0..64) |_| server.writeAll(&chunk) catch |e| {
        err = e;
        break;
    };
    try testing.expectEqual(@as(?pipe.Error, error.Timeout), err);
}

test "a read from a silent peer times out" {
    try skipUnlessWindows();
    var name_buf: [96]u8 = undefined;
    const name = uniqueName(&name_buf);
    var server = try pipe.listen(gpa, name, .{});
    defer server.close();
    var client = try pipe.connect(gpa, name, 1000);
    defer client.close();
    client.read_timeout_ms = 100;
    var buf: [pipe.max_frame]u8 = undefined;
    try testing.expectError(error.Timeout, client.recv(&buf));
}

test "a message near the frame limit goes through whole" {
    try skipUnlessWindows();
    var name_buf: [96]u8 = undefined;
    const name = uniqueName(&name_buf);
    var server = try pipe.listen(gpa, name, .{});
    defer server.close();
    var client = try pipe.connect(gpa, name, 1000);
    defer client.close();
    const big = try gpa.alloc(u8, 60 * 1024);
    defer gpa.free(big);
    @memset(big, 'x');
    const Reader = struct {
        fn run(conn: *pipe.Conn, out: *usize) void {
            var buf: [pipe.max_frame]u8 = undefined;
            const f = conn.recv(&buf) catch return;
            const ev = f.decode(control.Event) catch return;
            out.* = ev.library.paths.len;
        }
    };
    var got: usize = 0;
    const t = try std.Thread.spawn(.{}, Reader.run, .{ &client, &got });
    try server.send(control.Event, .{ .library = .{ .total = 1, .offset = 0, .paths = big } });
    t.join();
    try testing.expectEqual(big.len, got);
}

test "after shutdown, reads and writes fail at once" {
    try skipUnlessWindows();
    var name_buf: [96]u8 = undefined;
    const name = uniqueName(&name_buf);
    var server = try pipe.listen(gpa, name, .{});
    defer server.close();
    var client = try pipe.connect(gpa, name, 1000);
    defer client.close();
    server.shutdown();
    var buf: [4]u8 = undefined;
    try testing.expectError(error.Disconnected, server.readExact(&buf));
    try testing.expectError(error.Disconnected, server.writeAll("x"));
    // The client sees the server end go away.
    try testing.expectError(error.Disconnected, client.readExact(&buf));
}

// ---- reader threads -----------------------------------------------------------------

const WM_TEST = w.WM_APP + 77;
var frames_seen: u32 = 0;
var ended_seen: u32 = 0;

fn testProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (msg != WM_TEST) return w.DefWindowProcW(hwnd, msg, wp, lp);
    switch (pipe.Notice.fromLparam(lp)) {
        .frame => |f| {
            frames_seen += 1;
            f.destroy();
        },
        .ended => ended_seen += 1,
        .connected => {},
    }
    return 0;
}

fn messageWindow() !w.HWND {
    const class = w.L("zmural.test.pipe");
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = testProc, .hInstance = w.GetModuleHandleW(null), .lpszClassName = class });
    return w.CreateWindowExW(0, class, null, 0, 0, 0, 0, 0, w.HWND_MESSAGE, null, w.GetModuleHandleW(null), null) orelse error.NoWindow;
}

fn pump() void {
    var msg: w.MSG = undefined;
    while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) _ = w.DispatchMessageW(&msg);
}

test "stopReader always returns, however the timing falls (audit L8)" {
    try skipUnlessWindows();
    const hwnd = try messageWindow();
    defer _ = w.DestroyWindow(hwnd);
    var prng = std.Random.DefaultPrng.init(0x5eed);
    for (0..30) |round| {
        var name_buf: [96]u8 = undefined;
        const name = uniqueName(&name_buf);
        var server = try pipe.listen(gpa, name, .{});
        var client = try pipe.connect(gpa, name, 1000);
        frames_seen = 0;
        ended_seen = 0;
        const reader = try pipe.startReader(.{ .conn = &server, .hwnd = hwnd, .msg = WM_TEST, .accept_timeout_ms = 1000 });
        // A few frames, then stop the reader at an arbitrary moment.
        const frames = prng.random().uintLessThan(u32, 4);
        for (0..frames) |_| try client.send(control.Request, .status);
        w.Sleep(prng.random().uintLessThan(u32, 3));
        pipe.stopReader(&server, reader);
        pump();
        try testing.expectEqual(@as(u32, 1), ended_seen);
        try testing.expect(frames_seen <= frames);
        client.close();
        server.close();
        _ = round;
    }
}
