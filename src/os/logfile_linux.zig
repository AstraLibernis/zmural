// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Logging on Linux: every line goes to stderr the way `std.log` writes it
//! (a terminal or the journal, which stamps lines itself) and is appended to
//! a log file with a local timestamp. Each line is formatted first and then
//! written with one write call, so lines from different threads never
//! interleave.
//!
//! The log is capped like the Windows one (`logfile.zig`): whenever it passes
//! `max_bytes` (at startup or while running) it moves to `<name>.old.log` and
//! a fresh one starts.
//!
//! Use it as `pub const std_options: std.Options = .{ .logFn = logfile_linux.logFn };`
//! and call `open` early in `main`. No libc: zmural doesn't link it.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const localtime = @import("localtime.zig");
const xdg = @import("xdg.zig");

pub const max_bytes = 1 << 20;

var file: ?linux.fd_t = null;
var path_z: [512:0]u8 = undefined;
var old_z: [512:0]u8 = undefined;
var path_len: usize = 0;
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
/// The zone timestamps are written in; UTC until `open` has read it.
var zone: localtime.Zone = .utc;

/// Where the logs go: `$ZMURAL_CONFIG_DIR` (tests), else
/// `$XDG_STATE_HOME/zmural`, else `~/.local/state/zmural`. Null without a
/// usable directory.
pub fn dir(buf: []u8, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (environ.get("ZMURAL_CONFIG_DIR")) |d| return if (d.len > 0) d else null;
    if (xdg.dir(environ.get("XDG_STATE_HOME"))) |s| return std.fmt.bufPrint(buf, "{s}/zmural", .{s}) catch null;
    const home = xdg.dir(environ.get("HOME")) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/zmural", .{home}) catch null;
}

/// Opens (and if needed rotates) `<dir>/<name>.log`, making `dir` if it is
/// missing. `tz` is `$TZ`. Without a log file, logging still goes to stderr.
pub fn open(log_dir: []const u8, name: []const u8, tz: ?[]const u8) void {
    openLimited(log_dir, name, tz, max_bytes);
}

/// `open`, with a custom size limit (tests).
pub fn openLimited(log_dir: []const u8, name: []const u8, tz: ?[]const u8, bytes: u64) void {
    limit = bytes;
    localtime.load(&zone, tz);
    const log_path = std.fmt.bufPrintSentinel(&path_z, "{s}/{s}.log", .{ log_dir, name }, 0) catch return;
    path_len = log_path.len;
    _ = std.fmt.bufPrintSentinel(&old_z, "{s}/{s}.old.log", .{ log_dir, name }, 0) catch return;
    makePath(log_dir);

    const fd = createAppend() orelse return;
    const size = linux.lseek(fd, 0, linux.SEEK.END);
    file = fd;
    written.store(if (linux.errno(size) == .SUCCESS) size else 0, .release);
    if (written.load(.acquire) > limit) {
        acquire();
        defer lock.unlock();
        rotate();
    }
}

/// Moves the log aside and starts a new one. With `lock` held.
fn rotate() void {
    if (file) |fd| _ = linux.close(fd);
    file = null;
    _ = linux.rename(&path_z, &old_z);
    file = createAppend();
    written.store(0, .release);
}

pub fn close() void {
    acquire();
    defer lock.unlock();
    if (file) |fd| _ = linux.close(fd);
    file = null;
}

/// The log file's path (empty until `open` succeeds).
pub fn path() []const u8 {
    return if (file != null) path_z[0..path_len] else "";
}

/// Only the user reads it: wallpaper paths and app names end up in here.
fn createAppend() ?linux.fd_t {
    const rc = linux.open(&path_z, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc); // zsnag:ok — a successful open returns a small non-negative fd
}

/// `mkdir -p`. Errors (it exists, or can't be made) show up when the file is opened.
fn makePath(p: []const u8) void {
    var z: [512:0]u8 = undefined;
    if (p.len >= z.len) return;
    var i: usize = 1;
    while (i <= p.len) : (i += 1) {
        if (i < p.len and p[i] != '/') continue;
        @memcpy(z[0..i], p[0..i]);
        z[i] = 0;
        _ = linux.mkdir(&z, 0o700);
    }
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        switch (linux.errno(rc)) {
            .SUCCESS => done += rc,
            .INTR => {},
            else => return,
        }
    }
}

/// "2026-09-30 06:10:00.042 " for `secs` (Unix) shown `offset` seconds east of UTC.
fn writeStamp(out: *std.Io.Writer, secs: i64, ms: u32, offset: i32) void {
    const local = secs + offset;
    const day = localtime.civilFromDays(@divFloor(local, 86400));
    const s: u32 = @intCast(@mod(local, 86400)); // zsnag:ok — 0..86399
    out.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} ", .{
        @as(u32, @intCast(@max(day.year, 0))), day.month, day.day, s / 3600, s / 60 % 60, s % 60, ms, // zsnag:ok — clamped to >= 0
    }) catch {}; // zsnag:ok — a line that doesn't fit is truncated, never dropped
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    line(true, level, scope, format, args);
}

fn line(
    to_stderr: bool,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) ts = .{ .sec = 0, .nsec = 0 };
    var buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const ms: u32 = @intCast(@divFloor(std.math.clamp(ts.nsec, 0, std.time.ns_per_s - 1), std.time.ns_per_ms)); // zsnag:ok — clamped to 0..999
    writeStamp(&out, ts.sec, ms, zone.offsetAt(ts.sec));
    const stamp_len = out.buffered().len;
    // As std.log's default writes it: "info: ...", "warn(tray): ...".
    const prefix = comptime level.asText() ++ (if (scope == .default) "" else "(" ++ @tagName(scope) ++ ")") ++ ": ";
    out.print(prefix ++ format, args) catch {}; // zsnag:ok — as above
    out.writeByte('\n') catch {
        buf[buf.len - 1] = '\n'; // a truncated line still ends
    };
    const text = out.buffered();

    if (to_stderr) writeAll(linux.STDERR_FILENO, text[stamp_len..]);
    acquire();
    defer lock.unlock();
    if (file) |fd| {
        writeAll(fd, text);
        if (written.fetchAdd(text.len, .acq_rel) + text.len > limit) rotate();
    }
}

test "a timestamp is local time with milliseconds" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    // 2026-09-30 11:10:00 UTC, five hours west.
    writeStamp(&out, 1_790_766_600, 42, -5 * 3600);
    try std.testing.expectEqualStrings("2026-09-30 06:10:00.042 ", out.buffered());
    // A local day before the UTC one, and before 1970.
    out = .fixed(&buf);
    writeStamp(&out, 3600, 0, -2 * 3600);
    try std.testing.expectEqualStrings("1969-12-31 23:00:00.000 ", out.buffered());
}

test "the log directory: the test override, then XDG state, then ~/.local/state" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var buf: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), dir(&buf, &env));
    try env.put("HOME", "/home/u");
    try std.testing.expectEqualStrings("/home/u/.local/state/zmural", dir(&buf, &env).?);
    // A relative XDG value counts as unset.
    try env.put("XDG_STATE_HOME", "state");
    try std.testing.expectEqualStrings("/home/u/.local/state/zmural", dir(&buf, &env).?);
    try env.put("XDG_STATE_HOME", "/var/state");
    try std.testing.expectEqualStrings("/var/state/zmural", dir(&buf, &env).?);
    try env.put("ZMURAL_CONFIG_DIR", "/tmp/t");
    try std.testing.expectEqualStrings("/tmp/t", dir(&buf, &env).?);
}

test "the log is made with its directory, stamped, private, and rotates past its limit" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var dir_buf: [600]u8 = undefined;
    const nested = try std.fmt.bufPrint(&dir_buf, "{s}/state/zmural", .{buf[0..n]});
    openLimited(nested, "t", "America/Chicago", 2_000);
    defer close();
    try std.testing.expect(std.mem.endsWith(u8, path(), "/state/zmural/t.log"));
    for (0..100) |i| line(false, .info, .tray, "line {d} padding padding padding padding", .{i});

    const old = try tmp.dir.readFileAlloc(io, "state/zmural/t.old.log", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(old);
    const cur = try tmp.dir.readFileAlloc(io, "state/zmural/t.log", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(cur);
    try std.testing.expect(old.len > 0 and old.len <= 2_200);
    try std.testing.expect(cur.len > 0 and cur.len <= 2_200);
    // The newest line is in the current file, after a timestamp.
    const last = std.mem.trimEnd(u8, cur, "\n");
    const start = if (std.mem.findScalarLast(u8, last, '\n')) |nl| nl + 1 else 0;
    const newest = last[start..];
    try std.testing.expect(std.mem.endsWith(u8, newest, " info(tray): line 99 padding padding padding padding"));
    try std.testing.expectEqual(@as(usize, "2026-09-30 06:10:00.042".len), std.mem.find(u8, newest, " info").?);

    const st = try tmp.dir.statFile(io, "state/zmural/t.log", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "a line longer than the buffer is cut, and still ends in a newline" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    openLimited(buf[0..n], "long", null, max_bytes);
    defer close();
    const big: [6000]u8 = @splat('x');
    line(false, .warn, .default, "{s}", .{&big});
    const cur = try tmp.dir.readFileAlloc(io, "long.log", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(cur);
    try std.testing.expectEqual(@as(usize, 4096), cur.len);
    try std.testing.expectEqual(@as(u8, '\n'), cur[cur.len - 1]);
}

fn hammer(id: usize, lines: usize) void {
    for (0..lines) |i| line(false, .info, .default, "t{d} line {d} padding padding", .{ id, i });
}

test "threads logging across rotations write only whole lines, to the log itself" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    for ([_]usize{ 1, 3, 16 }) |threads| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var buf: [512]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        openLimited(buf[0..n], "t", null, 3_000);
        defer close();
        var pool: [16]std.Thread = undefined;
        for (pool[0..threads], 0..) |*t, id| t.* = try std.Thread.spawn(.{}, hammer, .{ id, 300 });
        for (pool[0..threads]) |t| t.join();

        for ([_][]const u8{ "t.log", "t.old.log" }) |name| {
            const text = try tmp.dir.readFileAlloc(io, name, std.testing.allocator, .unlimited);
            defer std.testing.allocator.free(text);
            // Rotation happens under the lock, so a file passes its limit by one
            // line at most. The current one can be empty: the last line written
            // may be the one that rotated it.
            try std.testing.expect(text.len < 3_000 + 64);
            if (std.mem.eql(u8, name, "t.old.log")) try std.testing.expect(text.len > 0);
            var it = std.mem.tokenizeScalar(u8, text, '\n');
            while (it.next()) |l| {
                try std.testing.expect(std.mem.endsWith(u8, l, " padding padding"));
                try std.testing.expect(std.mem.find(u8, l, " info: t") != null);
            }
        }
    }
}
