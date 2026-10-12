// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Wallpaper thumbnails from the Windows shell (the same ones Explorer shows),
//! made on a worker thread so a slow file never stalls the window.
//!
//! The window asks with `request(path)`; the worker keeps each finished
//! `*Result` in its own list and posts `msg` to say there are some. The window
//! takes them with `take` and frees them with `destroy`. The results never
//! ride in the message itself: Windows drops a closing window's queued
//! messages, and anything in them was lost.

const std = @import("std");
const w = @import("zmural").os.win32;
const sys = @import("sys.zig");

pub const Result = struct {
    path: []u8,
    width: u32,
    height: u32,
    /// Premultiplied BGRA, top-down, `width * 4` per row. Empty if there's no thumbnail.
    pixels: []u8,

    pub fn destroy(r: *Result, gpa: std.mem.Allocator) void {
        gpa.free(r.pixels);
        gpa.free(r.path);
        gpa.destroy(r);
    }
};

const SRWLOCK = extern struct { ptr: ?*anyopaque = null };
extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn SetEvent(event: w.HANDLE) callconv(.winapi) w.BOOL;

pub const Worker = struct {
    gpa: std.mem.Allocator,
    hwnd: w.HWND,
    msg: w.UINT,
    /// Longest side of a thumbnail, in pixels.
    size_px: i32,
    lock: SRWLOCK = .{},
    wake: w.HANDLE,
    queue: std.ArrayList([]u8) = .empty,
    /// Finished, not yet taken by the window.
    done: std.ArrayList(*Result) = .empty,
    quit: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Heap-allocated: the thread keeps a pointer to it.
    pub fn start(gpa: std.mem.Allocator, hwnd: w.HWND, msg: w.UINT, size_px: i32) !*Worker {
        const wk = try gpa.create(Worker);
        errdefer gpa.destroy(wk);
        const wake = w.CreateEventW(null, 0, 0, null) orelse return error.NoEvent;
        wk.* = .{ .gpa = gpa, .hwnd = hwnd, .msg = msg, .size_px = size_px, .wake = wake };
        wk.thread = std.Thread.spawn(.{}, run, .{wk}) catch |err| {
            _ = w.CloseHandle(wake);
            return err;
        };
        return wk;
    }

    /// Stops the worker and frees what the window never took.
    pub fn stop(wk: *Worker) void {
        wk.quit.store(true, .release);
        _ = SetEvent(wk.wake);
        if (wk.thread) |t| t.join();
        for (wk.queue.items) |p| wk.gpa.free(p);
        wk.queue.deinit(wk.gpa);
        for (wk.done.items) |r| r.destroy(wk.gpa);
        wk.done.deinit(wk.gpa);
        _ = w.CloseHandle(wk.wake);
        wk.gpa.destroy(wk);
    }

    /// Newest requests go first: the tiles on screen now matter most.
    pub fn request(wk: *Worker, path: []const u8) void {
        const owned = wk.gpa.dupe(u8, path) catch return;
        AcquireSRWLockExclusive(&wk.lock);
        wk.queue.append(wk.gpa, owned) catch wk.gpa.free(owned);
        ReleaseSRWLockExclusive(&wk.lock);
        _ = SetEvent(wk.wake);
    }

    /// A finished thumbnail, or null when there are none left. The caller owns it.
    pub fn take(wk: *Worker) ?*Result {
        AcquireSRWLockExclusive(&wk.lock);
        defer ReleaseSRWLockExclusive(&wk.lock);
        return wk.done.pop();
    }

    fn next(wk: *Worker) ?[]u8 {
        AcquireSRWLockExclusive(&wk.lock);
        defer ReleaseSRWLockExclusive(&wk.lock);
        return wk.queue.pop();
    }

    fn run(wk: *Worker) void {
        _ = sys.CoInitializeEx(null, sys.COINIT_APARTMENTTHREADED | sys.COINIT_DISABLE_OLE1DDE);
        defer sys.CoUninitialize();
        while (!wk.quit.load(.acquire)) {
            const path = wk.next() orelse {
                _ = w.WaitForSingleObject(wk.wake, w.INFINITE);
                continue;
            };
            const r = wk.gpa.create(Result) catch {
                wk.gpa.free(path);
                continue;
            };
            r.* = .{ .path = path, .width = 0, .height = 0, .pixels = &.{} };
            thumbnail(wk.gpa, path, wk.size_px, r);
            AcquireSRWLockExclusive(&wk.lock);
            const kept = if (wk.done.append(wk.gpa, r)) true else |_| false;
            ReleaseSRWLockExclusive(&wk.lock);
            if (!kept) {
                r.destroy(wk.gpa);
                continue;
            }
            // Only a nudge: a lost one (the window closing) loses nothing.
            _ = w.PostMessageW(wk.hwnd, wk.msg, 0, 0);
        }
    }
};

/// Fills `out` with the shell's thumbnail of `path`, or leaves it empty.
fn thumbnail(gpa: std.mem.Allocator, path: []const u8, size_px: i32, out: *Result) void {
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, path) catch return;
    defer gpa.free(path_w);
    var factory: ?*sys.Object = null;
    if (!sys.ok(sys.SHCreateItemFromParsingName(path_w, null, &sys.IID_IShellItemImageFactory, &factory))) return;
    defer sys.release(factory.?);
    // IShellItemImageFactory::GetImage (3). Thumbnails only: no file-type icons.
    var bmp: ?sys.HBITMAP = null;
    const get = sys.method(factory.?, 3, fn (*sys.Object, sys.SIZE, u32, *?sys.HBITMAP) callconv(.winapi) sys.HRESULT);
    if (!sys.ok(get(factory.?, .{ .cx = size_px, .cy = size_px }, sys.SIIGBF_THUMBNAILONLY, &bmp))) return;
    defer _ = w.DeleteObject(bmp.?);
    toPixels(gpa, bmp.?, out) catch {}; // zsnag:ok — no thumbnail: the tile shows its placeholder
}

fn toPixels(gpa: std.mem.Allocator, bmp: sys.HBITMAP, out: *Result) !void {
    var info: sys.BITMAP = undefined;
    if (sys.GetObjectW(bmp, @sizeOf(sys.BITMAP), &info) == 0) return error.NoBitmap;
    if (info.bmWidth <= 0 or info.bmHeight == 0 or info.bmWidth > 4096 or @abs(info.bmHeight) > 4096) return error.BadSize;
    const width: u32 = @intCast(info.bmWidth); // zsnag:ok — checked 1..4096 above
    const height: u32 = @intCast(@abs(info.bmHeight)); // zsnag:ok — checked above
    const pixels = try gpa.alloc(u8, width * height * 4);
    errdefer gpa.free(pixels);
    var bi: sys.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = @intCast(width), .biHeight = -@as(i32, @intCast(height)) } }; // zsnag:ok — ≤ 4096; negative height = top-down
    const dc = sys.GetDC(null) orelse return error.NoDc;
    defer _ = sys.ReleaseDC(null, dc);
    if (sys.GetDIBits(dc, bmp, 0, height, pixels.ptr, &bi, 0) == 0) return error.NoBits;
    fixAlpha(pixels);
    out.width = width;
    out.height = height;
    out.pixels = pixels;
}

/// Shell thumbnails of opaque images often come with alpha 0 everywhere;
/// those are opaque, not invisible.
fn fixAlpha(bgra: []u8) void {
    var i: usize = 3;
    while (i < bgra.len) : (i += 4) if (bgra[i] != 0) return;
    i = 3;
    while (i < bgra.len) : (i += 4) bgra[i] = 255;
}

test "fixAlpha makes all-transparent pixels opaque, and leaves real alpha alone" {
    var a = [_]u8{ 1, 2, 3, 0, 4, 5, 6, 0 };
    fixAlpha(&a);
    try std.testing.expectEqual(@as(u8, 255), a[3]);
    try std.testing.expectEqual(@as(u8, 255), a[7]);
    var b = [_]u8{ 1, 2, 3, 128, 4, 5, 6, 0 };
    fixAlpha(&b);
    try std.testing.expectEqual(@as(u8, 128), b[3]);
    try std.testing.expectEqual(@as(u8, 0), b[7]);
}

test "thumbnails finished when the window closes are freed, not lost with its messages" {
    const gpa = std.testing.allocator;
    // A message-only window nobody pumps: its queued nudges are flushed by
    // DestroyWindow, as when the settings window closes mid-scan.
    const hwnd = w.CreateWindowExW(0, w.L("STATIC"), null, 0, 0, 0, 0, 0, w.HWND_MESSAGE, null, null, null) orelse return error.SkipZigTest;
    const wk = try Worker.start(gpa, hwnd, 0x8000 + 7, 64);
    const n = 12;
    for (0..n) |i| {
        var buf: [64]u8 = undefined;
        wk.request(try std.fmt.bufPrint(&buf, "C:\\zmural-no-such-file-{d}.png", .{i}));
    }
    // Wait until the worker has finished every one (none taken).
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 10) {
        AcquireSRWLockExclusive(&wk.lock);
        const finished = wk.done.items.len;
        ReleaseSRWLockExclusive(&wk.lock);
        if (finished == n) break;
        w.Sleep(10);
    }
    // One taken by the window, the rest left behind when it closes.
    const r = wk.take() orelse return error.TestUnexpectedResult;
    r.destroy(gpa);
    _ = w.DestroyWindow(hwnd);
    wk.stop(); // the testing allocator fails the test if any result leaked
}
