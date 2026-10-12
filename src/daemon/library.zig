// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The wallpaper library: playable files found in the library folders
//! (`Videos\Wallpapers`, `Pictures\Wallpapers` and `settings.library_dirs`),
//! scanned to one level of subfolders and sorted by path.
//! A folder holding `zmural.toml` is one entry (a package); `.zip` packages
//! are unpacked into a library folder by `zmural-console import`.

const std = @import("std");
const builtin = @import("builtin");

const media = @import("zmural").media;

pub const video_exts = media.video_exts;
pub const image_exts = media.image_exts;
pub const web_exts = media.web_exts;
pub const package_manifest = media.package_manifest;
pub const isPlayable = media.isPlayable;

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    paths: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Library {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(l: *Library) void {
        l.arena.deinit();
    }

    pub fn count(l: *const Library) usize {
        return l.paths.items.len;
    }

    /// Replaces the contents with what's in `dirs` now. Missing folders are
    /// skipped; a file reached twice (a folder listed twice, or a folder and
    /// its subfolder) appears once.
    pub fn scan(l: *Library, io: std.Io, dirs: []const []const u8) void {
        _ = l.arena.reset(.retain_capacity);
        l.paths = .empty;
        for (dirs) |dir| {
            if (l.addPackage(io, dir)) continue; // a library folder that is itself a package
            l.scanDir(io, dir, 1);
        }
        std.mem.sort([]const u8, l.paths.items, {}, lessThan);
        dedupe(&l.paths);
    }

    /// Adds what's in `dir` after everything `scan` found, sorted among
    /// itself: zmural's own wallpaper goes after the user's. Files already
    /// listed stay where they are.
    pub fn scanLast(l: *Library, io: std.Io, dir: []const u8) void {
        const start = l.paths.items.len;
        if (!l.addPackage(io, dir)) l.scanDir(io, dir, 1);
        const added = l.paths.items[start..];
        std.mem.sort([]const u8, added, {}, lessThan);
        var kept = start;
        for (added) |p| {
            const known = for (l.paths.items[0..kept]) |q| {
                if (samePath(p, q)) break true;
            } else false;
            if (known) continue;
            l.paths.items[kept] = p;
            kept += 1;
        }
        l.paths.shrinkRetainingCapacity(kept);
    }

    fn scanDir(l: *Library, io: std.Io, path: []const u8, depth_left: u8) void {
        const a = l.arena.allocator();
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch return) |entry| {
            switch (entry.kind) {
                .file => if (isPlayable(entry.name) and openable(entry.name)) {
                    const full = std.fs.path.join(a, &.{ path, entry.name }) catch return;
                    l.paths.append(a, full) catch return;
                },
                .directory => {
                    // Hidden folders aren't the user's wallpapers (an import
                    // killed midway leaves a `.zmural-import-...` one).
                    if (entry.name[0] == '.') continue;
                    const sub = std.fs.path.join(a, &.{ path, entry.name }) catch return;
                    // A package is one wallpaper, at any depth we look at: its
                    // own files (videos, pages) aren't listed separately.
                    if (l.addPackage(io, sub)) continue;
                    if (depth_left > 0) l.scanDir(io, sub, depth_left - 1);
                },
                else => {},
            }
        }
    }

    /// If `dir` holds a `zmural.toml`, lists that manifest (the package's
    /// library entry) and returns true.
    fn addPackage(l: *Library, io: std.Io, dir: []const u8) bool {
        const a = l.arena.allocator();
        const manifest_path = std.fs.path.join(a, &.{ dir, package_manifest }) catch return false;
        std.Io.Dir.cwd().access(io, manifest_path, .{}) catch return false;
        if (!openable(manifest_path)) return false;
        l.paths.append(a, manifest_path) catch return false;
        return true;
    }

    /// The wallpaper after (or before) `current`, wrapping around. With no
    /// current wallpaper, or one that isn't in the library, starts at the first.
    pub fn step(l: *const Library, current: ?[]const u8, forward: bool) ?[]const u8 {
        const items = l.paths.items;
        if (items.len == 0) return null;
        const cur = current orelse return items[0];
        const i = for (items, 0..) |p, i| {
            if (samePath(p, cur)) break i;
        } else return items[0];
        return items[if (forward) (i + 1) % items.len else (i + items.len - 1) % items.len];
    }
};

/// Whether mpv can open a file by this name. Windows: only valid UTF-8 (a
/// name with a lone surrogate, kept as WTF-8, can't be passed to it). Linux:
/// any name, as mpv takes paths as bytes; the window shows bad bytes as
/// U+FFFD and D-Bus gets them mended the same way.
fn openable(name: []const u8) bool {
    return builtin.os.tag != .windows or std.unicode.utf8ValidateSlice(name);
}

/// Paths name the same file: ignoring case on Windows, exactly on Linux
/// (where "Rain.mp4" and "rain.mp4" are two files).
pub fn samePath(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

/// Drops neighbours that name the same file (sorted, so duplicates are adjacent).
fn dedupe(paths: *std.ArrayList([]const u8)) void {
    var kept: usize = 0;
    for (paths.items) |p| {
        if (kept > 0 and samePath(paths.items[kept - 1], p)) continue;
        paths.items[kept] = p;
        kept += 1;
    }
    paths.shrinkRetainingCapacity(kept);
}

test "zmural's own wallpaper goes after the user's, whatever the paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "a-own");
    try tmp.dir.createDirPath(io, "z-user");
    for ([_][]const u8{ "a-own/Prism.webm", "a-own/Other.webm", "z-user/b.mp4", "z-user/a.jpg" }) |f|
        try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "x" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const gpa = std.testing.allocator;
    const own = try std.fs.path.join(gpa, &.{ root, "a-own" });
    defer gpa.free(own);
    const user = try std.fs.path.join(gpa, &.{ root, "z-user" });
    defer gpa.free(user);

    var l: Library = .init(gpa);
    defer l.deinit();
    l.scan(io, &.{user});
    l.scanLast(io, own);
    const want = [_][]const u8{ "a.jpg", "b.mp4", "Other.webm", "Prism.webm" };
    try std.testing.expectEqual(want.len, l.count());
    for (want, l.paths.items) |w, p| try std.testing.expectEqualStrings(w, std.fs.path.basename(p));
    // A user who also lists zmural's folder keeps one entry per file, in
    // the user's sorted part.
    l.scan(io, &.{ user, own });
    l.scanLast(io, own);
    try std.testing.expectEqual(@as(usize, 4), l.count());
    try std.testing.expectEqualStrings("Other.webm", std.fs.path.basename(l.paths.items[0]));
}

test isPlayable {
    try std.testing.expect(isPlayable("Rain.MP4"));
    try std.testing.expect(isPlayable("a.webp"));
    try std.testing.expect(isPlayable("index.HTML"));
    try std.testing.expect(!isPlayable("notes.txt"));
    try std.testing.expect(!isPlayable("noext"));
}

test "scan finds playable files one level deep, sorted, without duplicates (audit M4)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest; // the paths below are Windows-style
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "wp/sub/deeper");
    for ([_][]const u8{ "wp/b.mp4", "wp/a.jpg", "wp/notes.txt", "wp/sub/c.gif", "wp/sub/deeper/d.mp4" }) |f|
        try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "x" });

    var root_buf: [1024]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..n];
    const gpa = std.testing.allocator;
    const wp = try std.fs.path.join(gpa, &.{ root, "wp" });
    defer gpa.free(wp);
    const sub = try std.fs.path.join(gpa, &.{ root, "wp", "sub" });
    defer gpa.free(sub);

    var l: Library = .init(gpa);
    defer l.deinit();
    // One folder: its files and its subfolder's, not deeper, not .txt.
    l.scan(io, &.{wp});
    try std.testing.expectEqual(@as(usize, 3), l.count());
    try std.testing.expect(std.mem.endsWith(u8, l.paths.items[0], "a.jpg"));
    try std.testing.expect(std.mem.endsWith(u8, l.paths.items[1], "b.mp4"));
    try std.testing.expect(std.mem.endsWith(u8, l.paths.items[2], "c.gif"));
    // The folder, its subfolder (whose own subfolder is now in reach), and the
    // folder again: every file exactly once (7 entries without de-duplication).
    l.scan(io, &.{ wp, sub, wp });
    try std.testing.expectEqual(@as(usize, 4), l.count());
    try std.testing.expect(std.mem.endsWith(u8, l.paths.items[3], "d.mp4"));
    // Next moves on instead of sticking on a duplicate.
    const first = l.step(null, true).?;
    try std.testing.expect(!std.mem.eql(u8, first, l.step(first, true).?));
    // A package folder is one entry (its manifest), not its files.
    try tmp.dir.createDirPath(io, "wp/pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "wp/pkg/zmural.toml", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "wp/pkg/index.html", .data = "x" });
    l.scan(io, &.{wp});
    try std.testing.expectEqual(@as(usize, 4), l.count());
    try std.testing.expect(std.mem.endsWith(u8, l.paths.items[2], "zmural.toml"));
    // A missing folder is simply skipped.
    l.scan(io, &.{"C:\\definitely\\not\\here"});
    try std.testing.expectEqual(@as(usize, 0), l.count());
}

test "Linux: a file whose name isn't UTF-8 is listed (mpv opens it by its bytes)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "wp");
    for ([_][]const u8{ "wp/caf\xe9.png", "wp/ok.mp4" }) |f|
        try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "x" });
    var root_buf: [1024]u8 = undefined;
    const n = try tmp.dir.realPath(io, &root_buf);
    const gpa = std.testing.allocator;
    const wp = try std.fs.path.join(gpa, &.{ root_buf[0..n], "wp" });
    defer gpa.free(wp);
    var l: Library = .init(gpa);
    defer l.deinit();
    l.scan(io, &.{wp});
    try std.testing.expectEqual(@as(usize, 2), l.count());
    try std.testing.expect(std.mem.endsWith(u8, l.paths.items[0], "caf\xe9.png"));
}

test "step wraps both ways" {
    var l: Library = .init(std.testing.allocator);
    defer l.deinit();
    const a = l.arena.allocator();
    for ([_][]const u8{ "C:\\w\\a.mp4", "C:\\w\\b.jpg", "C:\\w\\c.gif" }) |p| try l.paths.append(a, p);

    try std.testing.expectEqualStrings("C:\\w\\a.mp4", l.step(null, true).?);
    try std.testing.expectEqualStrings("C:\\w\\b.jpg", l.step("C:\\w\\a.mp4", true).?);
    try std.testing.expectEqualStrings("C:\\w\\a.mp4", l.step("C:\\W\\C.GIF", true).?);
    try std.testing.expectEqualStrings("C:\\w\\c.gif", l.step("C:\\w\\a.mp4", false).?);
    try std.testing.expectEqualStrings("C:\\w\\a.mp4", l.step("C:\\elsewhere.mp4", true).?);

    var empty: Library = .init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), empty.step(null, true));
}
