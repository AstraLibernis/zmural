// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Logging for a program that may have no console (Windows): every line goes
//! to stderr (if there is one) and is appended to a log file, with a local
//! timestamp. Each line is formatted first and then written with one
//! WriteFile call, so lines from different threads never interleave.
//!
//! The log is capped: whenever it passes `max_bytes` (at startup or while
//! running) it moves to `<name>.old.log` and a fresh one starts.
//!
//! Use it as `pub const std_options: std.Options = .{ .logFn = logfile.logFn };`
//! and call `open` early in `main`.

const std = @import("std");
const w = @import("win32.zig");

pub const max_bytes = 1 << 20;

var file: ?w.HANDLE = null;
var path_buf: [512]u8 = undefined;
var path_len: usize = 0;
var path_w: [512:0]u16 = undefined;
var old_w: [512:0]u16 = undefined;
var limit: u64 = max_bytes;
/// Bytes in the current file; rotation happens when this passes `limit`.
var written: std.atomic.Value(u64) = .init(0);
/// Held while a line is written to the file, and while it rotates: without
/// it a thread could write to a handle another had just closed in `rotate`,
/// which the OS may already have given to something else.
var lock: std.atomic.Mutex = .unlocked;

/// Spins, yielding: the lock is only held for one write.
fn acquire() void {
    while (!lock.tryLock()) std.Thread.yield() catch std.atomic.spinLoopHint();
}

/// Opens (and if needed rotates) `<dir>\<name>.log`, making `dir` and any
/// folder above it that is missing. Without a log file, logging still goes
/// to stderr.
pub fn open(dir: []const u8, name: []const u8) void {
    openLimited(dir, name, max_bytes);
}

/// `open`, with a custom size limit (tests).
pub fn openLimited(dir: []const u8, name: []const u8, bytes: u64) void {
    limit = bytes;
    const log_path = std.fmt.bufPrint(&path_buf, "{s}\\{s}.log", .{ dir, name }) catch return;
    path_len = log_path.len;
    var old_buf: [512]u8 = undefined;
    const old = std.fmt.bufPrint(&old_buf, "{s}\\{s}.old.log", .{ dir, name }) catch return;

    var dir_w: [512:0]u16 = undefined;
    toWide(&dir_w, dir) orelse return;
    toWide(&path_w, log_path) orelse return;
    toWide(&old_w, old) orelse return;
    makePath(&dir_w);

    const h = createAppend(&path_w) orelse return;
    var size: i64 = 0;
    _ = w.GetFileSizeEx(h, &size);
    file = h;
    written.store(@intCast(@max(size, 0)), .release); // zsnag:ok — clamped to >= 0
    if (written.load(.acquire) > limit) {
        acquire();
        defer lock.unlock();
        rotate();
    }
}

/// Makes `dir` and every missing folder above it. Errors (it exists, or can't
/// be made) show up when the file is opened.
fn makePath(dir: [:0]u16) void {
    const len = std.mem.len(dir.ptr);
    // Each prefix ending before a separator, then the whole path. A drive
    // ("C:") or a share's server name fails harmlessly: it isn't a folder.
    for (1..len + 1) |i| {
        if (i < len and dir[i] != '\\' and dir[i] != '/') continue;
        const keep = dir[i];
        dir[i] = 0;
        _ = w.CreateDirectoryW(dir.ptr, null);
        dir[i] = keep;
    }
}

/// Moves the log aside and starts a new one. With `lock` held.
fn rotate() void {
    if (file) |h| _ = w.CloseHandle(h);
    file = null;
    _ = w.MoveFileExW(&path_w, &old_w, w.MOVEFILE_REPLACE_EXISTING);
    file = createAppend(&path_w);
    written.store(0, .release);
}

pub fn close() void {
    acquire();
    defer lock.unlock();
    if (file) |h| _ = w.CloseHandle(h);
    file = null;
}

/// The log file's path (empty until `open` succeeds).
pub fn path() []const u8 {
    return if (file != null) path_buf[0..path_len] else "";
}

fn createAppend(p: [*:0]const u16) ?w.HANDLE {
    const h = w.CreateFileW(p, w.FILE_APPEND_DATA, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, null, w.OPEN_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
    return if (h == w.INVALID_HANDLE_VALUE) null else h;
}

fn toWide(out: *[512:0]u16, s: []const u8) ?void {
    // Paths are WTF-8; measure first (the converter assumes the output fits).
    if ((std.unicode.calcWtf16LeLen(s) catch return null) >= out.len) return null;
    const n = std.unicode.wtf8ToWtf16Le(out, s) catch return null;
    out[n] = 0;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var t: w.SYSTEMTIME = undefined;
    w.GetLocalTime(&t);
    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const prefix = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    out.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s}: " ++ prefix, .{
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, level.asText(),
    }) catch {}; // zsnag:ok — a line that doesn't fit is truncated, never dropped
    out.print(format, args) catch {}; // zsnag:ok — as above
    out.writeByte('\n') catch {}; // zsnag:ok — as above
    const line = out.buffered();

    if (w.GetStdHandle(w.STD_ERROR_HANDLE)) |err| {
        if (err != w.INVALID_HANDLE_VALUE) _ = w.WriteFile(err, line.ptr, @intCast(line.len), null, null); // zsnag:ok — at most 4096 bytes
    }
    acquire();
    defer lock.unlock();
    if (file) |h| {
        _ = w.WriteFile(h, line.ptr, @intCast(line.len), null, null); // zsnag:ok — at most 4096 bytes
        if (written.fetchAdd(line.len, .acq_rel) + line.len > limit) rotate();
    }
}

test "the log rotates while running once it passes its limit (audit L5)" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    openLimited(buf[0..n], "t", 2_000);
    defer close();
    for (0..100) |i| logFn(.info, .default, "line {d} padding padding padding padding", .{i});
    const old = try tmp.dir.readFileAlloc(io, "t.old.log", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(old);
    const cur = try tmp.dir.readFileAlloc(io, "t.log", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(cur);
    try std.testing.expect(old.len > 0 and old.len <= 2_200);
    try std.testing.expect(cur.len <= 2_200);
    // The newest line is in the current file.
    try std.testing.expect(std.mem.find(u8, cur, "line 99 ") != null);
}

test "missing folders above the log's folder are made" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var dir_buf: [600]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}\\missing/parent\\cfg", .{buf[0..n]});
    open(dir, "zmural");
    defer close();
    try std.testing.expect(path().len > 0);
    logFn(.info, .default, "hello", .{});
    const text = try tmp.dir.readFileAlloc(io, "missing/parent/cfg/zmural.log", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "hello") != null);
}

fn hammer(id: usize, lines: usize) void {
    for (0..lines) |i| logFn(.info, .default, "t{d} line {d} padding padding", .{ id, i });
}

test "threads logging across rotations write only whole lines, to the log itself" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    for ([_]usize{ 1, 3, 16 }) |threads| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [512]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        openLimited(buf[0..n], "t", 3_000);
        defer close();
        var pool: [16]std.Thread = undefined;
        for (pool[0..threads], 0..) |*t, id| t.* = try std.Thread.spawn(.{}, hammer, .{ id, 300 });
        for (pool[0..threads]) |t| t.join();

        for ([_][]const u8{ "t.log", "t.old.log" }) |name| {
            const text = try tmp.dir.readFileAlloc(io, name, std.testing.allocator, .unlimited);
            defer std.testing.allocator.free(text);
            var it = std.mem.tokenizeScalar(u8, text, '\n');
            while (it.next()) |l| try std.testing.expect(std.mem.endsWith(u8, l, " padding padding"));
            // Rotation happens under the lock, so a file passes its limit by one
            // line at most. The current one can be empty: the last line written
            // may be the one that rotated it.
            try std.testing.expect(text.len < 3_000 + 64);
            if (std.mem.eql(u8, name, "t.old.log")) try std.testing.expect(text.len > 0);
        }
    }
}

/// Prints to the terminal that started us, for a GUI-subsystem program
/// (whose stdout is usually nowhere). Used for --help and --version.
pub fn consoleWrite(text: []const u8) void {
    if (w.GetStdHandle(w.STD_OUTPUT_HANDLE)) |h| {
        if (h != w.INVALID_HANDLE_VALUE and w.WriteFile(h, text.ptr, @intCast(text.len), null, null) != 0) return; // zsnag:ok — short texts
    }
    if (w.AttachConsole(w.ATTACH_PARENT_PROCESS) == 0) return;
    const con = w.CreateFileW(w.L("CONOUT$"), w.GENERIC_WRITE, w.FILE_SHARE_WRITE, null, w.OPEN_EXISTING, 0, null);
    if (con == w.INVALID_HANDLE_VALUE) return;
    defer _ = w.CloseHandle(con);
    _ = w.WriteFile(con, text.ptr, @intCast(text.len), null, null); // zsnag:ok — short texts
}
