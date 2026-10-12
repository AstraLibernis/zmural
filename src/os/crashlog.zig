// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Crashes into the log file. A crash is otherwise printed only on stderr,
//! which for a zmural started at login goes nowhere anyone looks. Every mode
//! of the program (zmural itself, its renderers, the display host, the
//! watchdog) names the log at startup; a panic or a fault then appends what
//! happened, where, and the return addresses, before the usual stderr report.
//!
//! In a released (stripped) build the addresses are the only "where": they
//! turn into functions and lines with that release's kept debug files
//! (docs/RELEASING.md). No allocation here: the process may be in any state.
//!
//! Each report ends in a one-line crash code, for a user to paste somewhere:
//! `zmural 0.1.0 linux crash: 1215256 10fa504`, only the addresses inside
//! zmural's own program (Linux: as they are, it isn't position-independent;
//! Windows: from the program's base). The code also goes to `crash-code` next
//! to the log, for zmural to show at its next start or after a renderer dies
//! (`takeCode`). `tools/crashcode.zig` turns a code back into lines.

const std = @import("std");
const builtin = @import("builtin");
const version = @import("build_options").version;
const localtime = @import("localtime.zig");

var path_buf: [600]u8 = undefined;
var path_len: usize = 0;
var who_buf: [48]u8 = undefined;
var who_len: usize = 0;
var code_path_buf: [620]u8 = undefined;
var code_path_len: usize = 0;
/// Where zmural's own program is in memory: addresses in here go in the code.
var own_lo: usize = 0;
var own_hi: usize = 0;
pub const code_file = "crash-code";
/// Linux: the local zone, read up front since a crash can't read files.
var zone: localtime.Zone = .utc;

/// Where crashes go (the log file's path), which part of zmural this
/// process is ("zmural", "renderer video", "display host"...) and `$TZ`.
pub fn setUp(log_path: []const u8, who: []const u8, tz: ?[]const u8) void {
    if (builtin.os.tag == .linux) localtime.load(&zone, tz);
    path_len = @min(log_path.len, path_buf.len);
    @memcpy(path_buf[0..path_len], log_path[0..path_len]);
    who_len = @min(who.len, who_buf.len);
    @memcpy(who_buf[0..who_len], who[0..who_len]);
    const dir = std.fs.path.dirname(log_path) orelse ".";
    const cp = std.fmt.bufPrint(&code_path_buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, code_file }) catch "";
    code_path_len = cp.len;
    own_lo, own_hi = ownRange();
}

/// The span of zmural's own program in memory (0, 0 when unknown).
fn ownRange() struct { usize, usize } {
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var exe: [512]u8 = undefined;
            const n = linux.readlink("/proc/self/exe", &exe, exe.len);
            if (linux.errno(n) != .SUCCESS or n == 0 or n >= exe.len) return .{ 0, 0 };
            const rc = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
            if (linux.errno(rc) != .SUCCESS) return .{ 0, 0 };
            const fd: linux.fd_t = @intCast(rc); // zsnag:ok — checked above
            defer _ = linux.close(fd);
            var maps: [64 * 1024]u8 = undefined;
            var len: usize = 0;
            while (len < maps.len) {
                const got = linux.read(fd, maps[len..].ptr, maps.len - len);
                if (linux.errno(got) != .SUCCESS or got == 0) break;
                len += got;
            }
            return rangeIn(maps[0..len], exe[0..n]);
        },
        .windows => {
            const w = @import("win32.zig");
            const base = @intFromPtr(w.GetModuleHandleW(null) orelse return .{ 0, 0 });
            // PE: e_lfanew at 0x3C; SizeOfImage 80 bytes into the PE header (signature, file header, optional header).
            const pe: usize = std.mem.readInt(u32, @as(*const [4]u8, @ptrFromInt(base + 0x3C)), .little);
            const size: usize = std.mem.readInt(u32, @as(*const [4]u8, @ptrFromInt(base + pe + 80)), .little);
            return .{ base, base + size };
        },
        else => return .{ 0, 0 },
    }
}

/// From /proc/self/maps text: the lowest start and highest end of the lines
/// mapping `exe` (" (deleted)" after it counts: a program replaced while it runs).
fn rangeIn(maps: []const u8, exe: []const u8) struct { usize, usize } {
    var lo: usize = std.math.maxInt(usize);
    var hi: usize = 0;
    var lines = std.mem.splitScalar(u8, maps, '\n');
    while (lines.next()) |l| {
        const slash = std.mem.findScalar(u8, l, '/') orelse continue;
        const path = l[slash..];
        if (!std.mem.startsWith(u8, path, exe)) continue;
        if (path.len != exe.len and !std.mem.eql(u8, path[exe.len..], " (deleted)")) continue;
        const dash = std.mem.findScalar(u8, l, '-') orelse continue;
        const space = std.mem.findScalar(u8, l, ' ') orelse continue;
        if (space < dash) continue;
        const a = std.fmt.parseInt(usize, l[0..dash], 16) catch continue;
        const b = std.fmt.parseInt(usize, l[dash + 1 .. space], 16) catch continue;
        lo = @min(lo, a);
        hi = @max(hi, b);
    }
    return if (hi == 0) .{ 0, 0 } else .{ lo, hi };
}

/// `zmural <version> <os> crash: <addr> <addr>...`: the addresses inside
/// `[lo, hi)`, as offsets from `base`, at most eight.
fn writeCode(w: *std.Io.Writer, addrs: []const usize, lo: usize, hi: usize, base: usize) void {
    w.print("zmural {s} {s} crash:", .{ version, @tagName(builtin.os.tag) }) catch return;
    var n: usize = 0;
    for (addrs) |a| {
        if (a < lo or a >= hi or n == 8) continue;
        w.print(" {x}", .{a - base}) catch return;
        n += 1;
    }
    if (n == 0) w.writeAll(" none") catch return;
}

/// Appends a crash report to the log. `kind` is "panic" or the fault's
/// name; `first_address` and `context` are what the panic or fault handler
/// got, to start the trace at the crash rather than in here.
pub fn write(kind: []const u8, msg: []const u8, first_address: ?usize, context: ?std.debug.CpuContextPtr) void {
    if (path_len == 0) return;
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const now = timestamp();
    w.print("{s} CRASH: zmural {s} ({s}, pid {d}): {s}: {s}\n", .{ now.slice(), version, who_buf[0..who_len], pid(), kind, msg }) catch {}; // zsnag:ok — a report that doesn't fit is cut short, never dropped
    var addrs: [32]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{ .first_address = if (context == null) first_address else null, .context = context }, &addrs);
    for (trace.return_addresses) |a| w.print("    at 0x{x}\n", .{a}) catch {}; // zsnag:ok — as above
    if (trace.return_addresses.len == 0) w.writeAll("    (no stack trace could be taken)\n") catch {}; // zsnag:ok — as above
    var code_buf: [256]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&code_buf);
    writeCode(&cw, trace.return_addresses, own_lo, own_hi, if (builtin.os.tag == .windows) own_lo else 0);
    w.print("    code: {s}\n", .{cw.buffered()}) catch {}; // zsnag:ok — as above
    append(path_buf[0..path_len], w.buffered(), false);
    cw.writeByte('\n') catch {}; // zsnag:ok — the file holds the line either way
    append(code_path_buf[0..code_path_len], cw.buffered(), true);
}

/// The crash code a crash left in `dir` (the log's folder), into `buf`, and
/// the file removed so it is shown once. Null when there is none. Not for
/// crash time: it reads with `io`.
pub fn takeCode(io: std.Io, dir: []const u8, buf: []u8) ?[]const u8 {
    var p: [620]u8 = undefined;
    const path = std.fmt.bufPrint(&p, "{s}{c}{s}", .{ dir, std.fs.path.sep, code_file }) catch return null;
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFile(io, path, buf) catch return null;
    cwd.deleteFile(io, path) catch {}; // zsnag:ok — it is shown again next time, which is harmless
    const line = std.mem.trim(u8, text, " \r\n");
    if (!std.mem.startsWith(u8, line, "zmural ")) return null;
    return line;
}

const Stamp = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,
    fn slice(s: *const Stamp) []const u8 {
        return s.buf[0..s.len];
    }
};

/// Local time, to the second, as the rest of the log. The zone is read in
/// `setUp` (Linux); a crash only looks it up. Windows asks the system.
fn timestamp() Stamp {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            if (std.os.linux.errno(std.os.linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) ts = .{ .sec = 0, .nsec = 0 };
            return stampAt(ts.sec, zone.offsetAt(ts.sec));
        },
        .windows => {
            const w = @import("win32.zig");
            var t: w.SYSTEMTIME = undefined;
            w.GetLocalTime(&t);
            return stampOf(t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
        },
        else => return .{},
    }
}

/// `secs` (Unix) shown `offset` seconds east of UTC.
fn stampAt(secs: i64, offset: i32) Stamp {
    const local = secs + offset;
    const day = localtime.civilFromDays(@divFloor(local, 86400));
    const s: u32 = @intCast(@mod(local, 86400)); // zsnag:ok — 0..86399
    return stampOf(@intCast(@max(day.year, 0)), day.month, day.day, s / 3600, s / 60 % 60, s % 60); // zsnag:ok — clamped to >= 0
}

fn stampOf(year: u32, month: u32, day: u32, h: u32, m: u32, sec: u32) Stamp {
    var s: Stamp = .{};
    const out = std.fmt.bufPrint(&s.buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ year, month, day, h, m, sec }) catch return s;
    s.len = out.len;
    return s;
}

fn pid() u64 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()), // zsnag:ok — a pid is positive
        .windows => @import("win32.zig").GetCurrentProcessId(),
        else => 0,
    };
}

/// Appends to `path`, or (`replace`) writes it afresh.
fn append(path: []const u8, bytes: []const u8, replace: bool) void {
    if (path.len == 0) return;
    switch (builtin.os.tag) {
        .linux => {
            const linux = std.os.linux;
            var z: [code_path_buf.len + 1]u8 = undefined;
            if (path.len >= z.len) return;
            @memcpy(z[0..path.len], path);
            z[path.len] = 0;
            const rc = linux.open(z[0..path.len :0], .{ .ACCMODE = .WRONLY, .APPEND = !replace, .TRUNC = replace, .CREAT = true, .CLOEXEC = true }, 0o600);
            if (linux.errno(rc) != .SUCCESS) return;
            const fd: linux.fd_t = @intCast(rc); // zsnag:ok — checked above
            defer _ = linux.close(fd);
            _ = linux.write(fd, bytes.ptr, bytes.len);
        },
        .windows => {
            const w = @import("win32.zig");
            var wide: [code_path_buf.len + 1]u16 = undefined;
            if (path.len >= wide.len) return;
            const n = std.unicode.wtf8ToWtf16Le(&wide, path) catch return;
            wide[n] = 0;
            const create_always: w.DWORD = 2;
            const h = w.CreateFileW(wide[0..n :0], if (replace) w.GENERIC_WRITE else w.FILE_APPEND_DATA, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, if (replace) create_always else w.OPEN_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
            if (h == w.INVALID_HANDLE_VALUE) return;
            defer _ = w.CloseHandle(h);
            var done: w.DWORD = 0;
            _ = w.WriteFile(h, bytes.ptr, @intCast(@min(bytes.len, std.math.maxInt(w.DWORD))), &done, null); // zsnag:ok — clamped
        },
        else => {},
    }
}

test "a crash report lands in the log, with its addresses" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [256]u8 = undefined;
    const dir_len = try tmp.dir.realPath(std.testing.io, &dir_buf);
    var path: [300]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/zmural.log", .{dir_buf[0..dir_len]});
    setUp(p, "renderer video", "UTC0");
    defer path_len = 0;
    write("panic", "index out of bounds: index 6, len 3", @returnAddress(), null);
    const text = try tmp.dir.readFileAlloc(std.testing.io, "zmural.log", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "CRASH: zmural ") != null);
    try std.testing.expect(std.mem.find(u8, text, "(renderer video, pid ") != null);
    try std.testing.expect(std.mem.find(u8, text, "panic: index out of bounds: index 6, len 3\n") != null);
    try std.testing.expect(std.mem.find(u8, text, " UTC ") == null);
    // The code: this test's own frames are in this program, so it names some.
    try std.testing.expect(std.mem.find(u8, text, "    code: zmural ") != null);
    var buf: [256]u8 = undefined;
    const code = takeCode(std.testing.io, dir_buf[0..dir_len], &buf) orelse return error.NoCode;
    try std.testing.expect(std.mem.startsWith(u8, code, "zmural "));
    try std.testing.expect(std.mem.find(u8, code, " linux crash: ") != null);
    try std.testing.expect(std.mem.find(u8, code, "none") == null);
    try std.testing.expect(takeCode(std.testing.io, dir_buf[0..dir_len], &buf) == null); // shown once
}

test "the code keeps only the program's own addresses, at most eight" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const addrs = [_]usize{ 0x7f00_0000_1000, 0x1215256, 0x10fa504, 0x10e8241 };
    writeCode(&w, &addrs, 0x1000000, 0x1300000, 0);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), " crash: 1215256 10fa504 10e8241"));
    var w2: std.Io.Writer = .fixed(&buf);
    writeCode(&w2, &addrs, 0x140000000, 0x140100000, 0x140000000);
    try std.testing.expect(std.mem.endsWith(u8, w2.buffered(), " crash: none"));
    var w3: std.Io.Writer = .fixed(&buf);
    writeCode(&w3, &.{0x140001a2b}, 0x140000000, 0x140100000, 0x140000000);
    try std.testing.expect(std.mem.endsWith(u8, w3.buffered(), " crash: 1a2b"));
}

test "the program's span is read from /proc/self/maps lines" {
    const maps =
        \\01000000-010da000 r--p 00000000 08:20 123 /opt/zmural/bin/zmural
        \\010da000-0121c000 r-xp 000da000 08:20 123 /opt/zmural/bin/zmural
        \\0121c000-01230000 rw-p 0021c000 08:20 123 /opt/zmural/bin/zmural (deleted)
        \\7f0000000000-7f0000021000 r-xp 00000000 08:20 9 /usr/lib64/libc.so.6
        \\7f0000100000-7f0000101000 r--p 00000000 08:20 124 /opt/zmural/bin/zmural-console
        \\7ffd00000000-7ffd00021000 rw-p 00000000 00:00 0 [stack]
    ;
    const lo, const hi = rangeIn(maps, "/opt/zmural/bin/zmural");
    try std.testing.expectEqual(@as(usize, 0x1000000), lo);
    try std.testing.expectEqual(@as(usize, 0x1230000), hi);
    try std.testing.expectEqual(@as(usize, 0), rangeIn(maps, "/nowhere")[1]);
}

test "a crash is stamped in local time, like the log's other lines" {
    // 2026-09-30 11:10:00 UTC, five hours west: the log line 06:10:00.042 has the same clock.
    const s = stampAt(1_790_766_600, -5 * 3600);
    try std.testing.expectEqualStrings("2026-09-30 06:10:00", s.slice());
}
