// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What a desktop needs for zmural to show live wallpapers on it (Linux),
//! and what to tell the user when it falls short.
//!
//! These are requirements, not a list of systems: each number is the lowest
//! one the part that needs it runs on, taken from that part.
//! - A Wayland session: every display path zmural has is a Wayland one.
//! - KDE Plasma: zmural's wallpaper plugin is a Plasma 6 plugin (as
//!   waywallen-display, which it comes from, declares), and it is built
//!   against Qt 6.8 (inside a Debian 13 root: tools/plugin-root.sh), so it
//!   loads on Qt 6.8 or newer.
//! - GNOME: the Shell versions zmural's extension lists in its metadata.json
//!   (from waywallen-display; GNOME refuses an extension on a version it
//!   doesn't list).
//! A version that can't be found out is no reason to stop: only a known
//! shortfall is reported.

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32 = 0,

    pub fn atLeast(v: Version, min: Version) bool {
        return v.major > min.major or (v.major == min.major and v.minor >= min.minor);
    }
};

/// The GNOME Shell versions the extension declares (a test keeps this the
/// same as its metadata.json).
pub const gnome_shell_versions = [_]u32{ 48, 49, 50, 51 };
pub const kde_min_plasma: u32 = 6;
pub const kde_min_qt: Version = .{ .major = 6, .minor = 8 };

pub const Shortfall = union(enum) {
    /// No Wayland session (X11, or none).
    x11,
    /// Plasma older than 6.
    plasma: Version,
    /// Qt older than the plugin was built against.
    qt: Version,
    /// A GNOME Shell version the extension doesn't list; null when the
    /// desktop says GNOME but runs no GNOME Shell (Budgie, Flashback).
    gnome: ?u32,

    /// For `notices`: the same situation is told once.
    pub fn key(s: Shortfall, buf: []u8) []const u8 {
        return switch (s) {
            .x11 => "needs wayland",
            .plasma => |v| std.fmt.bufPrint(buf, "needs plasma {d}: {d}.{d}", .{ kde_min_plasma, v.major, v.minor }) catch "needs plasma",
            .qt => |v| std.fmt.bufPrint(buf, "needs qt {d}.{d}: {d}.{d}", .{ kde_min_qt.major, kde_min_qt.minor, v.major, v.minor }) catch "needs qt",
            .gnome => |v| if (v) |n| std.fmt.bufPrint(buf, "needs gnome: {d}", .{n}) catch "needs gnome" else "needs gnome shell",
        };
    }

    pub fn summary(s: Shortfall, buf: []u8) []const u8 {
        return switch (s) {
            .x11 => "zmural needs a Wayland session",
            .plasma => std.fmt.bufPrint(buf, "zmural's KDE plugin needs Plasma {d}", .{kde_min_plasma}) catch "",
            .qt => std.fmt.bufPrint(buf, "zmural's KDE plugin needs Qt {d}.{d} or newer", .{ kde_min_qt.major, kde_min_qt.minor }) catch "",
            .gnome => gnomeList(buf, "zmural's GNOME extension needs GNOME "),
        };
    }

    pub fn body(s: Shortfall, buf: []u8) []const u8 {
        const tail = "so zmural can't show live wallpapers here. zmural's log has the details.";
        return switch (s) {
            .x11 => "zmural shows live wallpapers on Wayland desktops, and this session uses X11. Choose a Wayland session when you log in, if your desktop offers one.",
            .plasma => |v| std.fmt.bufPrint(buf, "zmural's wallpaper plugin runs on KDE Plasma {d} with Qt {d}.{d} or newer. This desktop has Plasma {d}.{d}, {s}", .{ kde_min_plasma, kde_min_qt.major, kde_min_qt.minor, v.major, v.minor, tail }) catch "",
            .qt => |v| std.fmt.bufPrint(buf, "zmural's wallpaper plugin runs on Qt {d}.{d} or newer. This system has Qt {d}.{d}, which comes with your distribution's Plasma, {s}", .{ kde_min_qt.major, kde_min_qt.minor, v.major, v.minor, tail }) catch "",
            .gnome => |v| if (v) |n|
                std.fmt.bufPrint(buf, "The extension runs on the GNOME versions it was made and tested for. This desktop has GNOME {d}, {s}", .{ n, tail }) catch ""
            else
                std.fmt.bufPrint(buf, "This desktop calls itself GNOME, but GNOME Shell isn't running it, {s}", .{tail}) catch "",
        };
    }
};

/// "<prefix>48, 49, 50 or 51".
fn gnomeList(buf: []u8, prefix: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(prefix) catch return prefix;
    for (gnome_shell_versions, 0..) |v, i| {
        const sep: []const u8 = if (i == 0) "" else if (i + 1 == gnome_shell_versions.len) " or " else ", ";
        w.print("{s}{d}", .{ sep, v }) catch return prefix;
    }
    return w.buffered();
}

pub fn gnomeSupported(major: u32) bool {
    return std.mem.findScalar(u32, &gnome_shell_versions, major) != null;
}

/// "plasmashell 6.3.6" (`plasmashell --version`).
pub fn parsePlasma(out: []const u8) ?Version {
    return parseAfter(out, "plasmashell ");
}

/// "GNOME Shell 48.4" (`gnome-shell --version`): the major version.
pub fn parseGnomeShell(out: []const u8) ?u32 {
    return (parseAfter(out, "GNOME Shell ") orelse return null).major;
}

/// "libQt6Core.so.6.8.2", the file `libQt6Core.so.6` links to.
pub fn parseQtLib(name: []const u8) ?Version {
    return parseAfter(std.fs.path.basename(name), "libQt6Core.so.");
}

/// The "major.minor" right after `prefix`, at the start of a line.
fn parseAfter(out: []const u8, prefix: []const u8) ?Version {
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \r\t");
        if (!std.mem.startsWith(u8, t, prefix)) continue;
        var parts = std.mem.splitScalar(u8, t[prefix.len..], '.');
        const major = std.fmt.parseInt(u32, parts.first(), 10) catch return null;
        const minor_text = parts.next() orelse return .{ .major = major };
        const end = std.mem.findNone(u8, minor_text, "0123456789") orelse minor_text.len;
        const minor = std.fmt.parseInt(u32, minor_text[0..end], 10) catch 0;
        return .{ .major = major, .minor = minor };
    }
    return null;
}

test "versions are read from what the desktop's programs print" {
    try std.testing.expectEqual(Version{ .major = 6, .minor = 3 }, parsePlasma("plasmashell 6.3.6\n").?);
    try std.testing.expectEqual(Version{ .major = 5, .minor = 27 }, parsePlasma("plasmashell 5.27.11\n").?);
    try std.testing.expectEqual(@as(?u32, 48), parseGnomeShell("GNOME Shell 48.4\n"));
    try std.testing.expectEqual(@as(?u32, 51), parseGnomeShell("GNOME Shell 51.beta\n"));
    try std.testing.expectEqual(Version{ .major = 6, .minor = 8 }, parseQtLib("libQt6Core.so.6.8.2").?);
    try std.testing.expectEqual(Version{ .major = 6, .minor = 11 }, parseQtLib("/usr/lib64/libQt6Core.so.6.11.2").?);
    try std.testing.expectEqual(@as(?Version, null), parsePlasma("something else"));
    try std.testing.expectEqual(@as(?Version, null), parseQtLib("libQt6Core.so.x"));
}

test "a version at the floor or above passes, one below doesn't" {
    try std.testing.expect((Version{ .major = 6, .minor = 8 }).atLeast(kde_min_qt));
    try std.testing.expect((Version{ .major = 6, .minor = 11 }).atLeast(kde_min_qt));
    try std.testing.expect((Version{ .major = 7 }).atLeast(kde_min_qt));
    try std.testing.expect(!(Version{ .major = 6, .minor = 7 }).atLeast(kde_min_qt));
    try std.testing.expect(!(Version{ .major = 5, .minor = 15 }).atLeast(kde_min_qt));
    try std.testing.expect(gnomeSupported(48) and gnomeSupported(51));
    try std.testing.expect(!gnomeSupported(46) and !gnomeSupported(52));
}

test "the messages say what is needed and what is here" {
    var a: [256]u8 = undefined;
    var b: [512]u8 = undefined;
    const qt: Shortfall = .{ .qt = .{ .major = 6, .minor = 7 } };
    try std.testing.expectEqualStrings("zmural's KDE plugin needs Qt 6.8 or newer", qt.summary(&a));
    try std.testing.expect(std.mem.find(u8, qt.body(&b), "This system has Qt 6.7") != null);
    const gnome: Shortfall = .{ .gnome = 46 };
    try std.testing.expectEqualStrings("zmural's GNOME extension needs GNOME 48, 49, 50 or 51", gnome.summary(&a));
    try std.testing.expect(std.mem.find(u8, gnome.body(&b), "This desktop has GNOME 46") != null);
    try std.testing.expectEqualStrings("needs gnome: 46", gnome.key(&a));
    const plasma: Shortfall = .{ .plasma = .{ .major = 5, .minor = 27 } };
    try std.testing.expect(std.mem.find(u8, plasma.body(&b), "This desktop has Plasma 5.27") != null);
}

test "the GNOME versions are the ones the extension declares" {
    const io = std.testing.io;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "third_party/waywallen-display/extensions/gnome/extension/metadata.json.in", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(text);
    const start = std.mem.find(u8, text, "\"shell-version\"").?;
    const list = text[start..][0..std.mem.findScalar(u8, text[start..], ']').?];
    var declared: std.ArrayList(u32) = .empty;
    defer declared.deinit(std.testing.allocator);
    var it = std.mem.tokenizeAny(u8, list["\"shell-version\"".len..], " \n\t\":[,");
    while (it.next()) |v| try declared.append(std.testing.allocator, try std.fmt.parseInt(u32, v, 10));
    try std.testing.expectEqualSlices(u32, declared.items, &gnome_shell_versions);
}
