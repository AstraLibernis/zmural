// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Control server tests over real pipes (Windows): hello gating, a client that
//! says nothing can't lock others out, and it's dropped after the timeout.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");
const w = zmural.os.win32;
const pipe = zmural.protocol.pipe;
const control = zmural.protocol.control;
const client_mod = zmural.sdk.control_client;
const Server = @import("control_windows.zig").Server;

const testing = std.testing;
const gpa = testing.allocator;
const WM_CTL = w.WM_APP + 90;

var server: Server = undefined;
var requests_handled: u32 = 0;

fn handler(req: control.Request) control.Event {
    requests_handled += 1;
    return switch (req) {
        .status => .{ .status = .{ .paused = false, .muted = true, .monitors = 1, .wallpapers = 7, .wallpaper = "test.mp4" } },
        else => .ok,
    };
}

fn proc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (msg == WM_CTL) {
        server.onMessage(w.GetTickCount64(), wp, lp, handler);
        return 0;
    }
    return w.DefWindowProcW(hwnd, msg, wp, lp);
}

/// Pumps messages until `done` or the deadline.
fn pumpUntil(done: *const std.atomic.Value(bool), timeout_ms: u64) void {
    const deadline = w.GetTickCount64() + timeout_ms;
    var msg: w.MSG = undefined;
    while (!done.load(.acquire) and w.GetTickCount64() < deadline) {
        while (w.PeekMessageW(&msg, null, 0, 0, w.PM_REMOVE) != 0) _ = w.DispatchMessageW(&msg);
        w.Sleep(5);
    }
}

fn pumpFor(ms: u64) void {
    var never: std.atomic.Value(bool) = .init(false);
    pumpUntil(&never, ms);
}

const ClientResult = struct {
    done: std.atomic.Value(bool) = .init(false),
    wallpapers: u32 = 0,
    err: ?anyerror = null,
};

fn clientMain(name: []const u8, out: *ClientResult) void {
    defer out.done.store(true, .release);
    const c = client_mod.Client.connect(std.heap.smp_allocator, name, "test") catch |e| {
        out.err = e;
        return;
    };
    defer c.close(std.heap.smp_allocator);
    const ev = c.request(.status) catch |e| {
        out.err = e;
        return;
    };
    out.wallpapers = ev.status.wallpapers;
}

test "an idle client can't lock others out, and is dropped after the hello timeout (audit L6)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const class = w.L("zmural.test.control");
    _ = w.RegisterClassExW(&.{ .lpfnWndProc = proc, .hInstance = w.GetModuleHandleW(null), .lpszClassName = class });
    const hwnd = w.CreateWindowExW(0, class, null, 0, 0, 0, 0, 0, w.HWND_MESSAGE, null, w.GetModuleHandleW(null), null).?;
    defer _ = w.DestroyWindow(hwnd);

    var name_buf: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\zmural-test-control-{d}", .{w.GetCurrentProcessId()});
    server = try Server.start(gpa, name, hwnd, WM_CTL);
    defer server.stop();

    // 1. A client connects and says nothing.
    var idle = try pipe.connect(gpa, name, 1000);
    defer idle.close();
    pumpFor(200);

    // 2. A real client still gets through, and gets its answer.
    var result: ClientResult = .{};
    const t = try std.Thread.spawn(.{}, clientMain, .{ name, &result });
    pumpUntil(&result.done, 5000);
    t.join();
    try testing.expectEqual(@as(?anyerror, null), result.err);
    try testing.expectEqual(@as(u32, 7), result.wallpapers);
    try testing.expectEqual(@as(u32, 1), requests_handled);

    // 3. A request before hello is refused, and never reaches the handler.
    try idle.send(control.Request, .quit);
    pumpFor(100);
    var buf: [pipe.max_frame]u8 = undefined;
    const reply = try (try idle.recv(&buf)).decode(control.Event);
    try testing.expectEqual(control.ErrorCode.bad_request, reply.failed.code);
    try testing.expectEqual(@as(u32, 1), requests_handled);

    // 4. Past the hello timeout it is dropped: its end sees the pipe close.
    server.tick(w.GetTickCount64() + @import("control_windows.zig").hello_timeout_ms + 1000);
    pumpFor(200);
    try testing.expectError(error.Disconnected, idle.recv(&buf));
}
