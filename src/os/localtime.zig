// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Local time on Linux without libc, for log timestamps: the UTC offset from
//! the system's zone file (`/etc/localtime`, or `$TZ`), the way libc's
//! `localtime` finds it.
//!
//! A zone file (TZif) lists its transitions up to some year and ends with a
//! POSIX TZ rule ("EST5EDT,M3.2.0,M11.1.0") for every time after the last
//! one; `std.tz` parses the file, and this evaluates both. `$TZ` may also be
//! such a rule itself. Anything unreadable falls back to UTC.

const std = @import("std");
const linux = std.os.linux;
const tz = std.tz;

const max_transitions = 2048;

pub const Zone = struct {
    ts: [max_transitions]i64 = undefined,
    offsets: [max_transitions]i32 = undefined,
    len: usize = 0,
    /// Before the first transition.
    initial: i32 = 0,
    /// After the last one (or the whole zone, for a `$TZ` rule).
    rule: ?Rule = null,

    pub const utc: Zone = .{};

    /// Seconds east of UTC at `t` (Unix seconds).
    pub fn offsetAt(z: *const Zone, t: i64) i32 {
        if (z.len > 0 and t >= z.ts[0]) {
            if (t >= z.ts[z.len - 1]) if (z.rule) |r| return r.offsetAt(t);
            // The last transition at or before t.
            var lo: usize = 0;
            var hi: usize = z.len;
            while (hi - lo > 1) {
                const mid = (lo + hi) / 2;
                if (z.ts[mid] <= t) lo = mid else hi = mid;
            }
            return z.offsets[lo];
        }
        if (z.len == 0) if (z.rule) |r| return r.offsetAt(t);
        return z.initial;
    }

    /// Reads a TZif file's contents. Null if it isn't one.
    pub fn fromTzif(out: *Zone, data: []const u8) ?void {
        var scratch: [256 * 1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&scratch);
        var reader: std.Io.Reader = .fixed(data);
        const parsed = tz.Tz.parse(fba.allocator(), &reader) catch return null;
        out.* = .{};
        if (parsed.timetypes.len > 0) {
            // As RFC 8536 says: before the first transition, the first standard-time type.
            out.initial = parsed.timetypes[0].offset;
            for (parsed.timetypes) |tt| if (!tt.isDst()) {
                out.initial = tt.offset;
                break;
            };
        }
        for (parsed.transitions) |tr| {
            if (out.len == max_transitions) break;
            out.ts[out.len] = tr.ts;
            out.offsets[out.len] = tr.timetype.offset;
            out.len += 1;
        }
        if (parsed.footer) |f| out.rule = Rule.parse(f) catch null;
        // A file with no transitions is one fixed offset.
        if (out.len == 0 and out.rule == null and parsed.timetypes.len > 0) out.initial = parsed.timetypes[0].offset;
    }
};

/// Loads the system's zone: `$TZ` (`tz_env`) if set, else /etc/localtime.
/// UTC when neither can be read.
pub fn load(out: *Zone, tz_env: ?[]const u8) void {
    out.* = .utc;
    var path_buf: [512]u8 = undefined;
    var path: []const u8 = "/etc/localtime";
    if (tz_env) |raw| {
        // An empty $TZ is UTC, as in glibc.
        if (raw.len == 0) return;
        const v = if (raw[0] == ':') raw[1..] else raw;
        if (v.len > 0 and v[0] == '/') {
            path = v;
        } else if (v.len > 0 and std.mem.find(u8, v, "..") == null) {
            // A zone name ("Europe/Berlin"), else a POSIX rule ("CET-1CEST,...").
            path = std.fmt.bufPrint(&path_buf, "/usr/share/zoneinfo/{s}", .{v}) catch return;
            if (!readZone(out, path)) {
                if (Rule.parse(v)) |r| out.rule = r else |_| {}
            }
            return;
        } else return;
    }
    _ = readZone(out, path);
}

fn readZone(out: *Zone, path: []const u8) bool {
    var z: [513]u8 = undefined;
    if (path.len >= z.len) return false;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = linux.open(z[0..path.len :0], .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var data: [128 * 1024]u8 = undefined;
    var n: usize = 0;
    while (n < data.len) {
        const r = linux.read(fd, data[n..].ptr, data.len - n);
        if (linux.errno(r) != .SUCCESS) return false;
        if (r == 0) break;
        n += r;
    }
    return out.fromTzif(data[0..n]) != null;
}

/// A POSIX TZ rule: "std offset [dst [offset] [,start[/time],end[/time]]]".
pub const Rule = struct {
    /// Seconds east of UTC (POSIX writes them west: "EST5" is -5 h).
    std_offset: i32,
    dst: ?Dst = null,

    pub const Dst = struct {
        offset: i32,
        start: Date,
        /// Seconds after local midnight (standard time) that DST starts.
        start_time: i32 = 2 * 3600,
        end: Date,
        /// Seconds after local midnight (daylight time) that it ends.
        end_time: i32 = 2 * 3600,
    };

    pub const Date = union(enum) {
        /// Mm.w.d: day d (0 = Sunday) of week w (5 = last) of month m.
        month_week_day: struct { month: u4, week: u3, day: u3 },
        /// Jn: day 1..365, February 29 never counted.
        julian1: u16,
        /// n: day 0..365, February 29 counted.
        julian0: u16,
    };

    pub const Error = error{BadRule};

    pub fn parse(s: []const u8) Error!Rule {
        var p: Parser = .{ .s = s };
        try p.name();
        var r: Rule = .{ .std_offset = -(try p.offset()) };
        if (p.done()) return r;
        try p.name();
        var dst_off = r.std_offset + 3600;
        if (!p.done() and p.peek() != ',') dst_off = -(try p.offset());
        // No rule: the US rules, as glibc assumes.
        var dst: Dst = .{
            .offset = dst_off,
            .start = .{ .month_week_day = .{ .month = 3, .week = 2, .day = 0 } },
            .end = .{ .month_week_day = .{ .month = 11, .week = 1, .day = 0 } },
        };
        if (!p.done()) {
            try p.expect(',');
            dst.start = try p.date();
            if (p.accept('/')) dst.start_time = try p.time();
            try p.expect(',');
            dst.end = try p.date();
            if (p.accept('/')) dst.end_time = try p.time();
            if (!p.done()) return error.BadRule;
        }
        r.dst = dst;
        return r;
    }

    pub fn offsetAt(r: Rule, t: i64) i32 {
        const d = r.dst orelse return r.std_offset;
        const year = civilFromDays(@divFloor(t + r.std_offset, 86400)).year;
        // Check this year's and the neighbours' switches: near New Year the
        // local year differs from the UTC one.
        var y = year - 1;
        var last_switch: i64 = std.math.minInt(i64);
        var in_dst = false;
        while (y <= year + 1) : (y += 1) {
            const start = dayOf(y, d.start) * 86400 + d.start_time - r.std_offset;
            const end = dayOf(y, d.end) * 86400 + d.end_time - d.offset;
            if (start <= t and start > last_switch) {
                last_switch = start;
                in_dst = true;
            }
            if (end <= t and end > last_switch) {
                last_switch = end;
                in_dst = false;
            }
        }
        return if (in_dst) d.offset else r.std_offset;
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn done(p: *const Parser) bool {
        return p.i >= p.s.len;
    }
    fn peek(p: *const Parser) u8 {
        return p.s[p.i];
    }
    fn accept(p: *Parser, c: u8) bool {
        if (p.done() or p.s[p.i] != c) return false;
        p.i += 1;
        return true;
    }
    fn expect(p: *Parser, c: u8) Rule.Error!void {
        if (!p.accept(c)) return error.BadRule;
    }
    /// "EST", or quoted: "<+0530>".
    fn name(p: *Parser) Rule.Error!void {
        const start = p.i;
        if (p.accept('<')) {
            while (!p.done() and p.peek() != '>') p.i += 1;
            try p.expect('>');
        } else {
            while (!p.done() and std.ascii.isAlphabetic(p.peek())) p.i += 1;
        }
        if (p.i - start < 3) return error.BadRule;
    }
    fn number(p: *Parser) Rule.Error!i32 {
        const start = p.i;
        while (!p.done() and std.ascii.isDigit(p.peek())) p.i += 1;
        if (p.i == start or p.i - start > 3) return error.BadRule;
        return std.fmt.parseInt(i32, p.s[start..p.i], 10) catch error.BadRule;
    }
    /// [+-]hh[:mm[:ss]], in seconds (west of UTC as written).
    fn offset(p: *Parser) Rule.Error!i32 {
        const neg = p.accept('-');
        if (!neg) _ = p.accept('+');
        const v = try p.hms();
        if (v > 24 * 3600) return error.BadRule;
        return if (neg) -v else v;
    }
    /// A switch time: like an offset, but RFC 8536 allows -167..167 hours.
    fn time(p: *Parser) Rule.Error!i32 {
        const neg = p.accept('-');
        if (!neg) _ = p.accept('+');
        const v = try p.hms();
        if (v > 167 * 3600) return error.BadRule;
        return if (neg) -v else v;
    }
    fn hms(p: *Parser) Rule.Error!i32 {
        var v = (try p.number()) * 3600;
        if (p.accept(':')) v += (try p.number()) * 60;
        if (p.accept(':')) v += try p.number();
        return v;
    }
    fn date(p: *Parser) Rule.Error!Rule.Date {
        if (p.accept('M')) {
            const m = try p.number();
            try p.expect('.');
            const w = try p.number();
            try p.expect('.');
            const d = try p.number();
            if (m < 1 or m > 12 or w < 1 or w > 5 or d > 6) return error.BadRule;
            return .{ .month_week_day = .{ .month = @intCast(m), .week = @intCast(w), .day = @intCast(d) } };
        }
        if (p.accept('J')) {
            const n = try p.number();
            if (n < 1 or n > 365) return error.BadRule;
            return .{ .julian1 = @intCast(n) };
        }
        const n = try p.number();
        if (n > 365) return error.BadRule;
        return .{ .julian0 = @intCast(n) };
    }
};

/// Days since 1970-01-01 of a rule date in `year`.
fn dayOf(year: i32, d: Rule.Date) i64 {
    switch (d) {
        .julian1 => |n| {
            // Day n of a 365-day year: after February, skip the leap day.
            const jan1 = daysFromCivil(year, 1, 1);
            const leap_shift: i64 = if (n >= 60 and isLeap(year)) 1 else 0;
            return jan1 + n - 1 + leap_shift;
        },
        .julian0 => |n| return daysFromCivil(year, 1, 1) + n,
        .month_week_day => |mwd| {
            const first = daysFromCivil(year, mwd.month, 1);
            const first_wday = @mod(first + 4, 7); // 1970-01-01 was a Thursday
            var day = first + @mod(@as(i64, mwd.day) - first_wday, 7) + (@as(i64, mwd.week) - 1) * 7;
            // Week 5 means the last one: step back into the month.
            while (day >= first + daysInMonth(year, mwd.month)) day -= 7;
            return day;
        },
    }
}

fn isLeap(y: i32) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn daysInMonth(y: i32, m: u4) i64 {
    const days = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return days[m - 1] + @intFromBool(m == 2 and isLeap(y));
}

/// Howard Hinnant's days_from_civil.
pub fn daysFromCivil(y_in: i32, m: u32, d: u32) i64 {
    const y: i64 = @as(i64, y_in) - @intFromBool(m <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { year: i32, month: u8, day: u8 };

/// Howard Hinnant's civil_from_days.
pub fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @intFromBool(m <= 2);
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

test "civil dates round trip" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 20725), daysFromCivil(2026, 9, 29));
    var day: i64 = -800_000;
    while (day < 800_000) : (day += 997) {
        const c = civilFromDays(day);
        try std.testing.expectEqual(day, daysFromCivil(c.year, c.month, c.day));
    }
}

test "POSIX rules: the US, Europe, the southern hemisphere, fixed and quoted" {
    const ny = try Rule.parse("EST5EDT,M3.2.0,M11.1.0");
    // 2026: DST from 8 March 07:00 UTC to 1 November 06:00 UTC.
    const mar8 = daysFromCivil(2026, 3, 8) * 86400;
    try std.testing.expectEqual(@as(i32, -5 * 3600), ny.offsetAt(mar8 + 7 * 3600 - 1));
    try std.testing.expectEqual(@as(i32, -4 * 3600), ny.offsetAt(mar8 + 7 * 3600));
    const nov1 = daysFromCivil(2026, 11, 1) * 86400;
    try std.testing.expectEqual(@as(i32, -4 * 3600), ny.offsetAt(nov1 + 6 * 3600 - 1));
    try std.testing.expectEqual(@as(i32, -5 * 3600), ny.offsetAt(nov1 + 6 * 3600));

    // Europe: last Sunday of March 01:00 UTC to last Sunday of October 01:00 UTC.
    const berlin = try Rule.parse("CET-1CEST,M3.5.0,M10.5.0/3");
    const mar29 = daysFromCivil(2026, 3, 29) * 86400;
    try std.testing.expectEqual(@as(i32, 3600), berlin.offsetAt(mar29 + 3600 - 1));
    try std.testing.expectEqual(@as(i32, 7200), berlin.offsetAt(mar29 + 3600));
    const oct25 = daysFromCivil(2026, 10, 25) * 86400;
    try std.testing.expectEqual(@as(i32, 7200), berlin.offsetAt(oct25 + 3600 - 1));
    try std.testing.expectEqual(@as(i32, 3600), berlin.offsetAt(oct25 + 3600));

    // Sydney: DST across New Year.
    const syd = try Rule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try std.testing.expectEqual(@as(i32, 11 * 3600), syd.offsetAt(daysFromCivil(2027, 1, 1) * 86400));
    try std.testing.expectEqual(@as(i32, 10 * 3600), syd.offsetAt(daysFromCivil(2026, 7, 1) * 86400));

    try std.testing.expectEqual(@as(i32, 5 * 3600 + 1800), (try Rule.parse("IST-5:30")).offsetAt(0));
    try std.testing.expectEqual(@as(i32, -3 * 3600), (try Rule.parse("<-03>3")).offsetAt(0));
    try std.testing.expectEqual(@as(i32, 0), (try Rule.parse("UTC0")).offsetAt(1_800_000_000));

    try std.testing.expectError(error.BadRule, Rule.parse(""));
    try std.testing.expectError(error.BadRule, Rule.parse("EST"));
    try std.testing.expectError(error.BadRule, Rule.parse("EST5EDT,M13.1.0,M11.1.0"));
    try std.testing.expectError(error.BadRule, Rule.parse("EST5EDT,M3.2.0"));
}

test "a zone with no transitions and no rule is UTC" {
    const z: Zone = .utc;
    try std.testing.expectEqual(@as(i32, 0), z.offsetAt(1_800_000_000));
}

test "$TZ: a rule, empty (UTC), and a zone name" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const t = 1_790_766_600; // 2026-09-30 11:10:00 UTC
    var z: Zone = undefined;
    load(&z, "CST6CDT,M3.2.0,M11.1.0");
    try std.testing.expectEqual(@as(i32, -5 * 3600), z.offsetAt(t));
    load(&z, "");
    try std.testing.expectEqual(@as(i32, 0), z.offsetAt(t));
    load(&z, "../etc/passwd");
    try std.testing.expectEqual(@as(i32, 0), z.offsetAt(t));
    // Only where tzdata is installed.
    if (readZone(&z, "/usr/share/zoneinfo/America/Chicago")) {
        load(&z, ":America/Chicago");
        try std.testing.expectEqual(@as(i32, -5 * 3600), z.offsetAt(t));
        try std.testing.expectEqual(@as(i32, -6 * 3600), z.offsetAt(t + 60 * 86400));
    }
}
