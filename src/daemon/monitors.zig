// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Which wallpaper each monitor shows. There is one main wallpaper; a monitor
//! can be given its own, and keeps it until it is told to follow the main one
//! again or a wallpaper is applied to every monitor. A monitor that is
//! unplugged keeps its entry, so it shows the same thing when it comes back.
//!
//! Shared by both runtimes; nothing here touches an OS.

const std = @import("std");
const zmural = @import("zmural");
const MonitorId = zmural.monitor.Id;
const MonitorWallpaper = @import("settings.zig").MonitorWallpaper;
const MonitorFill = @import("settings.zig").MonitorFill;
const FillMode = zmural.layout.FillMode;

/// More than this many monitors with a wallpaper of their own are refused.
pub const max = 16;

pub const Own = struct {
    items: [max]Item = undefined,
    len: usize = 0,

    const Item = struct {
        monitor: MonitorId,
        /// Owned.
        path: []u8,
    };

    pub fn deinit(o: *Own, gpa: std.mem.Allocator) void {
        o.clear(gpa);
    }

    /// The wallpaper `monitor` shows: its own, else `main`.
    pub fn wallpaperFor(o: *const Own, monitor: MonitorId, main: ?[]const u8) ?[]const u8 {
        return o.get(monitor) orelse main;
    }

    /// A monitor whose own wallpaper is `path`, if any.
    pub fn showing(o: *const Own, path: []const u8) ?MonitorId {
        for (o.items[0..o.len]) |it| if (std.mem.eql(u8, it.path, path)) return it.monitor;
        return null;
    }

    pub fn get(o: *const Own, monitor: MonitorId) ?[]const u8 {
        for (o.items[0..o.len]) |it| if (std.mem.eql(u8, &it.monitor, &monitor)) return it.path;
        return null;
    }

    /// Gives `monitor` its own wallpaper. The old path, if any, is freed:
    /// nothing may still be using it.
    pub fn set(o: *Own, gpa: std.mem.Allocator, monitor: MonitorId, path: []const u8) error{ OutOfMemory, TooMany }!void {
        const copy = try gpa.dupe(u8, path);
        for (o.items[0..o.len]) |*it| if (std.mem.eql(u8, &it.monitor, &monitor)) {
            gpa.free(it.path);
            it.path = copy;
            return;
        };
        if (o.len == max) {
            gpa.free(copy);
            return error.TooMany;
        }
        o.items[o.len] = .{ .monitor = monitor, .path = copy };
        o.len += 1;
    }

    /// `monitor` follows the main wallpaper again. False if it already did.
    pub fn remove(o: *Own, gpa: std.mem.Allocator, monitor: MonitorId) bool {
        for (o.items[0..o.len], 0..) |it, i| if (std.mem.eql(u8, &it.monitor, &monitor)) {
            gpa.free(it.path);
            o.len -= 1;
            o.items[i] = o.items[o.len];
            return true;
        };
        return false;
    }

    pub fn clear(o: *Own, gpa: std.mem.Allocator) void {
        for (o.items[0..o.len]) |it| gpa.free(it.path);
        o.len = 0;
    }

    /// Replaces everything with what settings.toml lists. Entries that aren't
    /// monitor IDs, or have no path, are skipped.
    pub fn load(o: *Own, gpa: std.mem.Allocator, from: []const MonitorWallpaper) void {
        o.clear(gpa);
        for (from) |mw| {
            const id = parseId(mw.monitor) orelse continue;
            if (mw.wallpaper.len == 0) continue;
            o.set(gpa, id, mw.wallpaper) catch return;
        }
    }

    /// For saving: `out` borrows this list until the next change.
    pub fn view(o: *const Own, out: *[max]MonitorWallpaper) []const MonitorWallpaper {
        for (o.items[0..o.len], 0..) |*it, i| out[i] = .{ .monitor = &it.monitor, .wallpaper = it.path };
        return out[0..o.len];
    }
};

/// Monitors that fill their screen another way than the main fill mode.
pub const Fills = struct {
    items: [max]MonitorFill = undefined,
    ids: [max]MonitorId = undefined,
    len: usize = 0,

    /// How `monitor` fills its screen: its own way, else `main`.
    pub fn fillFor(f: *const Fills, monitor: MonitorId, main: FillMode) FillMode {
        return f.get(monitor) orelse main;
    }

    pub fn get(f: *const Fills, monitor: MonitorId) ?FillMode {
        for (f.ids[0..f.len], f.items[0..f.len]) |id, it| if (std.mem.eql(u8, &id, &monitor)) return it.fill;
        return null;
    }

    /// False when the list is full.
    pub fn set(f: *Fills, monitor: MonitorId, fill: FillMode) bool {
        for (f.ids[0..f.len], f.items[0..f.len]) |id, *it| if (std.mem.eql(u8, &id, &monitor)) {
            it.fill = fill;
            return true;
        };
        if (f.len == max) return false;
        f.ids[f.len] = monitor;
        f.items[f.len] = .{ .monitor = "", .fill = fill };
        f.len += 1;
        return true;
    }

    /// `monitor` uses the main fill mode again. False if it already did.
    pub fn remove(f: *Fills, monitor: MonitorId) bool {
        for (f.ids[0..f.len], 0..) |id, i| if (std.mem.eql(u8, &id, &monitor)) {
            f.len -= 1;
            f.ids[i] = f.ids[f.len];
            f.items[i] = f.items[f.len];
            return true;
        };
        return false;
    }

    /// Replaces everything with what settings.toml lists.
    pub fn load(f: *Fills, from: []const MonitorFill) void {
        f.len = 0;
        for (from) |mf| _ = f.set(parseId(mf.monitor) orelse continue, mf.fill);
    }

    /// For saving and comparing: valid until the next change.
    pub fn view(f: *Fills) []const MonitorFill {
        for (f.ids[0..f.len], f.items[0..f.len]) |*id, *it| it.monitor = id;
        return f.items[0..f.len];
    }

    pub fn same(f: *Fills, other: []const MonitorFill) bool {
        const mine = f.view();
        if (mine.len != other.len) return false;
        for (mine, other) |a, b| if (a.fill != b.fill or !std.mem.eql(u8, a.monitor, b.monitor)) return false;
        return true;
    }
};

/// "m-" and 16 lowercase hex digits.
pub fn parseId(text: []const u8) ?MonitorId {
    if (text.len != @typeInfo(MonitorId).array.len or !std.mem.startsWith(u8, text, "m-")) return null;
    for (text[2..]) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return null;
    return text[0..@typeInfo(MonitorId).array.len].*;
}

/// A connected monitor, as `zmural-console status` lists it.
pub const Known = struct {
    id: MonitorId,
    /// The connector or device name ("DP-1"), for people.
    name: []const u8,
    width: u32 = 0,
    height: u32 = 0,
};

/// The monitor a person means by `text`: its number in the list (from 1),
/// its name ("DP-1", any case), or its ID. Null if it isn't connected.
pub fn resolve(text: []const u8, known: []const Known) ?MonitorId {
    if (std.fmt.parseInt(usize, text, 10)) |n| {
        if (n >= 1 and n <= known.len) return known[n - 1].id;
        return null;
    } else |_| {}
    for (known) |k| {
        if (std.mem.eql(u8, &k.id, text) or (k.name.len > 0 and std.ascii.eqlIgnoreCase(k.name, text))) return k.id;
    }
    return null;
}

/// One line per monitor for the control protocol:
/// `id <tab> name <tab> WIDTHxHEIGHT <tab> its own wallpaper, or empty
/// <tab> its own fill mode, or empty`. Stops at the monitor that doesn't fit.
pub fn format(buf: []u8, known: []const Known, own: *const Own, fills: *const Fills) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (known) |k| {
        const before = w.buffered().len;
        const fill = if (fills.get(k.id)) |f| @tagName(f) else "";
        w.print("{s}\t{s}\t{d}x{d}\t{s}\t{s}\n", .{ &k.id, k.name, k.width, k.height, own.get(k.id) orelse "", fill }) catch {
            return std.mem.trimEnd(u8, buf[0..before], "\n");
        };
    }
    return std.mem.trimEnd(u8, w.buffered(), "\n");
}

/// One line of `format`, taken apart (the protocol owns the layout).
pub const parseLine = zmural.protocol.control.parseMonitorLine;

test "a monitor shows its own wallpaper, else the main one; removing it follows the main one again" {
    const gpa = std.testing.allocator;
    const a = zmural.monitor.fromConnector("DP-1");
    const b = zmural.monitor.fromConnector("HDMI-A-1");
    var own: Own = .{};
    defer own.deinit(gpa);

    try std.testing.expectEqualStrings("main.mp4", own.wallpaperFor(a, "main.mp4").?);
    try std.testing.expectEqual(@as(?[]const u8, null), own.wallpaperFor(a, null));

    try own.set(gpa, b, "city.mp4");
    try std.testing.expectEqualStrings("main.mp4", own.wallpaperFor(a, "main.mp4").?);
    try std.testing.expectEqualStrings("city.mp4", own.wallpaperFor(b, "main.mp4").?);
    // Its own wallpaper doesn't need a main one.
    try std.testing.expectEqualStrings("city.mp4", own.wallpaperFor(b, null).?);

    // Which monitor has a file as its own (a broken one goes back to the main).
    try std.testing.expect(std.mem.eql(u8, &b, &own.showing("city.mp4").?));
    try std.testing.expect(own.showing("main.mp4") == null);

    try own.set(gpa, b, "rain.mp4");
    try std.testing.expectEqual(@as(usize, 1), own.len);
    try std.testing.expectEqualStrings("rain.mp4", own.get(b).?);

    try std.testing.expect(own.remove(gpa, b));
    try std.testing.expect(!own.remove(gpa, b));
    try std.testing.expectEqualStrings("main.mp4", own.wallpaperFor(b, "main.mp4").?);
}

test "the list survives settings.toml: saved as a view, loaded back, bad entries skipped" {
    const gpa = std.testing.allocator;
    const a = zmural.monitor.fromConnector("DP-1");
    var own: Own = .{};
    defer own.deinit(gpa);
    try own.set(gpa, a, "/wp/rain.mp4");
    var out: [max]MonitorWallpaper = undefined;
    const saved = own.view(&out);
    try std.testing.expectEqualStrings(&a, saved[0].monitor);

    var back: Own = .{};
    defer back.deinit(gpa);
    back.load(gpa, &.{
        .{ .monitor = saved[0].monitor, .wallpaper = saved[0].wallpaper },
        .{ .monitor = "DP-2", .wallpaper = "/wp/x.mp4" }, // a name isn't an ID
        .{ .monitor = "m-0123456789ABCDEF", .wallpaper = "/wp/x.mp4" }, // IDs are lowercase
        .{ .monitor = "m-0123456789abcdef", .wallpaper = "" },
    });
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("/wp/rain.mp4", back.get(a).?);
}

test "no more than the limit, and a full list still lets an existing monitor change" {
    const gpa = std.testing.allocator;
    var own: Own = .{};
    defer own.deinit(gpa);
    var name_buf: [8]u8 = undefined;
    for (0..max) |i| try own.set(gpa, zmural.monitor.fromConnector(try std.fmt.bufPrint(&name_buf, "M{d}", .{i})), "x");
    try std.testing.expectError(error.TooMany, own.set(gpa, zmural.monitor.fromConnector("one-more"), "x"));
    try own.set(gpa, zmural.monitor.fromConnector("M3"), "y");
    try std.testing.expectEqualStrings("y", own.get(zmural.monitor.fromConnector("M3")).?);
}

test "a monitor is named by number, name or ID; the list round-trips" {
    const gpa = std.testing.allocator;
    const known = [_]Known{
        .{ .id = zmural.monitor.fromConnector("DP-1"), .name = "DP-1", .width = 2560, .height = 1440 },
        .{ .id = zmural.monitor.fromConnector("HDMI-A-1"), .name = "HDMI-A-1", .width = 1920, .height = 1080 },
    };
    try std.testing.expectEqual(known[0].id, resolve("1", &known).?);
    try std.testing.expectEqual(known[1].id, resolve("2", &known).?);
    try std.testing.expectEqual(known[1].id, resolve("hdmi-a-1", &known).?);
    try std.testing.expectEqual(known[0].id, resolve(&known[0].id, &known).?);
    try std.testing.expectEqual(@as(?MonitorId, null), resolve("0", &known));
    try std.testing.expectEqual(@as(?MonitorId, null), resolve("3", &known));
    try std.testing.expectEqual(@as(?MonitorId, null), resolve("DP-9", &known));
    try std.testing.expectEqual(@as(?MonitorId, null), resolve("", &known));

    var own: Own = .{};
    defer own.deinit(gpa);
    try own.set(gpa, known[1].id, "/wp/city.mp4");
    var fills: Fills = .{};
    try std.testing.expect(fills.set(known[1].id, .fit));
    var buf: [512]u8 = undefined;
    const text = format(&buf, &known, &own, &fills);
    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = parseLine(lines.next().?).?;
    try std.testing.expectEqualStrings("DP-1", first.name);
    try std.testing.expectEqualStrings("2560x1440", first.size);
    try std.testing.expectEqualStrings("", first.wallpaper);
    try std.testing.expectEqualStrings("", first.fill);
    const second = parseLine(lines.next().?).?;
    try std.testing.expectEqualStrings(&known[1].id, second.id);
    try std.testing.expectEqualStrings("/wp/city.mp4", second.wallpaper);
    try std.testing.expectEqualStrings("fit", second.fill);
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());

    // A buffer too small for the second monitor lists the first only.
    var small: [48]u8 = undefined;
    try std.testing.expect(std.mem.findScalar(u8, format(&small, &known, &own, &fills), '\n') == null);
}

test "a monitor fills its own way, else the main way; the list survives settings.toml" {
    const a = zmural.monitor.fromConnector("DP-1");
    const b = zmural.monitor.fromConnector("HDMI-A-1");
    var f: Fills = .{};
    try std.testing.expectEqual(FillMode.crop, f.fillFor(a, .crop));
    try std.testing.expect(f.set(b, .fit));
    try std.testing.expectEqual(FillMode.crop, f.fillFor(a, .crop));
    try std.testing.expectEqual(FillMode.fit, f.fillFor(b, .crop));
    try std.testing.expect(f.set(b, .stretch));
    try std.testing.expectEqual(@as(usize, 1), f.len);

    var back: Fills = .{};
    back.load(f.view());
    try std.testing.expectEqual(FillMode.stretch, back.get(b).?);
    try std.testing.expect(back.same(f.view()));
    back.load(&.{.{ .monitor = "HDMI-A-1", .fill = .fit }}); // a name isn't an ID
    try std.testing.expectEqual(@as(usize, 0), back.len);
    try std.testing.expect(!back.same(f.view()));

    try std.testing.expect(f.remove(b));
    try std.testing.expect(!f.remove(b));
    try std.testing.expectEqual(FillMode.crop, f.fillFor(b, .crop));
}
