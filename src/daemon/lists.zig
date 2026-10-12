// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! List settings (app names, library folders) as they cross the control pipe:
//! one string, items separated by `control.list_sep`. Pure, so it's tested here.

const std = @import("std");
const builtin = @import("builtin");
const sep = @import("zmural").protocol.control.list_sep;

/// Most items a list setting may hold.
pub const max_items = 32;
/// Longest item: a long Windows path in WTF-8.
pub const max_item_len = 600;
/// A full list, separators included, always fits in this much reply space,
/// so `get_settings` never has to cut one short.
pub const max_joined_len = max_items * (max_item_len + 1);

pub const Error = error{ TooMany, TooLong, BadItem, OutOfMemory };

/// A list the runtime owns, so the settings window can replace it at any time.
pub const Owned = struct {
    text: []u8 = &.{},
    items: [][]const u8 = &.{},

    /// Splits `joined`, dropping blank items, surrounding spaces and repeats.
    /// Each item must pass `check`.
    pub fn parse(gpa: std.mem.Allocator, joined: []const u8, check: *const fn ([]const u8) bool) Error!Owned {
        const text = try gpa.dupe(u8, joined);
        errdefer gpa.free(text);
        var items: std.ArrayList([]const u8) = .empty;
        errdefer items.deinit(gpa);
        var it = std.mem.splitScalar(u8, text, sep);
        while (it.next()) |raw| {
            const item = std.mem.trim(u8, raw, " \t\r");
            if (item.len == 0) continue;
            if (item.len > max_item_len) return error.TooLong;
            if (!check(item)) return error.BadItem;
            if (contains(items.items, item)) continue;
            if (items.items.len == max_items) return error.TooMany;
            try items.append(gpa, item);
        }
        return .{ .text = text, .items = try items.toOwnedSlice(gpa) };
    }

    pub fn deinit(l: *Owned, gpa: std.mem.Allocator) void {
        gpa.free(l.items);
        gpa.free(l.text);
        l.* = .{};
    }
};

/// Case-insensitive, like Windows paths and executable names.
fn contains(items: []const []const u8, item: []const u8) bool {
    for (items) |x| if (std.ascii.eqlIgnoreCase(x, item)) return true;
    return false;
}

/// This OS's rules for list items.
pub const isAppName = if (builtin.os.tag == .windows) isAppNameWindows else isAppNameLinux;
pub const isAbsoluteDir = if (builtin.os.tag == .windows) isAbsoluteDirWindows else isAbsoluteDirLinux;

/// An app rule is a bare executable name: "eldenring.exe", not a path.
pub fn isAppNameWindows(item: []const u8) bool {
    if (std.mem.findAny(u8, item, "\\/:*?\"<>|") != null) return false;
    return std.ascii.endsWithIgnoreCase(item, ".exe") and item.len > ".exe".len;
}

/// Linux: a program's name, as the process list shows it ("steam",
/// "eldenring.exe" under Proton), not a path.
pub fn isAppNameLinux(item: []const u8) bool {
    return item.len > 0 and item.len <= 255 and std.mem.findScalar(u8, item, '/') == null and std.mem.findScalar(u8, item, 0) == null;
}

/// Linux: an absolute path.
pub fn isAbsoluteDirLinux(item: []const u8) bool {
    return item.len > 1 and item[0] == '/' and std.mem.findScalar(u8, item, 0) == null;
}

/// A library folder must be absolute: "D:\Wallpapers" or "\\server\share\x".
pub fn isAbsoluteDirWindows(item: []const u8) bool {
    if (std.mem.findAny(u8, item, "*?\"<>|") != null) return false;
    const drive = item.len >= 3 and std.ascii.isAlphabetic(item[0]) and item[1] == ':' and (item[2] == '\\' or item[2] == '/');
    const unc = item.len >= 5 and std.mem.startsWith(u8, item, "\\\\") and item[2] != '?' and item[2] != '.';
    return drive or unc;
}

/// Joins `items` into `buf`; stops before an item that wouldn't fit.
pub fn join(buf: []u8, items: []const []const u8) []const u8 {
    return joinFrom(buf, items, 0).text;
}

pub const Page = struct { text: []const u8, count: usize };

/// Joins `items[offset..]` into `buf` until the next one wouldn't fit.
pub fn joinFrom(buf: []u8, items: []const []const u8, offset: usize) Page {
    var n: usize = 0;
    var count: usize = 0;
    for (items[@min(offset, items.len)..]) |item| {
        const extra = item.len + @intFromBool(count > 0);
        if (n + extra > buf.len) break;
        if (count > 0) {
            buf[n] = sep;
            n += 1;
        }
        @memcpy(buf[n..][0..item.len], item);
        n += item.len;
        count += 1;
    }
    return .{ .text = buf[0..n], .count = count };
}

const testing = std.testing;

test "parse trims, skips blanks and repeats, and checks every item" {
    var l = try Owned.parse(testing.allocator, " eldenring.exe \x00\x00\r\x00OBS64.exe\x00obs64.EXE\x00", isAppNameWindows);
    defer l.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), l.items.len);
    try testing.expectEqualStrings("eldenring.exe", l.items[0]);
    try testing.expectEqualStrings("OBS64.exe", l.items[1]);

    try testing.expectError(error.BadItem, Owned.parse(testing.allocator, "C:\\Games\\x.exe", isAppNameWindows));
    try testing.expectError(error.BadItem, Owned.parse(testing.allocator, "notes.txt", isAppNameWindows));
    try testing.expectError(error.BadItem, Owned.parse(testing.allocator, ".exe", isAppNameWindows));
    var empty = try Owned.parse(testing.allocator, "", isAppNameWindows);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.items.len);
}

test "parse limits count and length" {
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(testing.allocator);
    for (0..max_items + 1) |i| try many.print(testing.allocator, "app{d}.exe\x00", .{i});
    try testing.expectError(error.TooMany, Owned.parse(testing.allocator, many.items, isAppNameWindows));

    const long = [_]u8{'a'} ** (max_item_len + 1);
    try testing.expectError(error.TooLong, Owned.parse(testing.allocator, &long, isAppNameWindows));
}

test "library folders must be absolute" {
    try testing.expect(isAbsoluteDirLinux("/home/me/Videos/Wallpapers"));
    try testing.expect(!isAbsoluteDirLinux("Videos"));
    try testing.expect(isAppNameLinux("steam"));
    try testing.expect(!isAppNameLinux("/usr/bin/steam"));
    try testing.expect(isAbsoluteDir("D:\\Wallpapers") == (builtin.os.tag == .windows));
    try testing.expect(isAbsoluteDirWindows("D:\\Wallpapers"));
    try testing.expect(isAbsoluteDirWindows("c:/wp"));
    try testing.expect(isAbsoluteDirWindows("\\\\nas\\media\\wp"));
    try testing.expect(!isAbsoluteDirWindows("Wallpapers"));
    try testing.expect(!isAbsoluteDirWindows("\\\\?\\C:\\wp"));
    try testing.expect(!isAbsoluteDirWindows("\\\\.\\pipe\\x"));
    try testing.expect(!isAbsoluteDirWindows("D:"));
}

test "joinFrom pages through a list without splitting items" {
    const items = [_][]const u8{ "aaa", "bb", "cccc", "d" };
    var buf: [8]u8 = undefined;
    const p1 = joinFrom(&buf, &items, 0);
    try testing.expectEqualStrings("aaa\x00bb", p1.text);
    try testing.expectEqual(@as(usize, 2), p1.count);
    const p2 = joinFrom(&buf, &items, 2);
    try testing.expectEqualStrings("cccc\x00d", p2.text);
    try testing.expectEqual(@as(usize, 2), joinFrom(&buf, &items, 2).count);
    try testing.expectEqual(@as(usize, 0), joinFrom(&buf, &items, 9).count);
    // An item longer than the whole buffer yields an empty page; the caller must notice.
    var tiny: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), joinFrom(&tiny, &items, 0).count);
}
