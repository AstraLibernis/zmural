// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The wallpaper zmural ships with (Prism, made by tools/wallgen.zig and
//! installed by build.zig). It shows whenever no wallpaper is set, so a
//! first run never leaves the desktop empty, and it is in the library like
//! any other. It lives with the programs, never in the user's own folders.

const std = @import("std");

/// The file's name: build.zig's `starter_wallpaper_name`.
pub const name = "Prism.webm";

/// The folder holding it: `wallpapers` beside the programs (Windows), or
/// `share/zmural/wallpapers` beside `bin` (Linux). Null when it isn't there,
/// as with a program copied out on its own. Caller frees.
pub fn dir(gpa: std.mem.Allocator, io: std.Io, exe_dir: []const u8) ?[]const u8 {
    const candidates = [_][]const []const u8{
        &.{ exe_dir, "wallpapers" },
        &.{ exe_dir, "..", "share", "zmural", "wallpapers" },
    };
    for (candidates) |parts| {
        // Resolved, so the library shows no "..".
        const folder = std.fs.path.resolve(gpa, parts) catch return null;
        if (holdsIt(gpa, io, folder)) return folder;
        gpa.free(folder);
    }
    return null;
}

/// Opened rather than `access`ed: Wine's `access` says FileNotFound for
/// files that exist, and the tests run there too.
fn holdsIt(gpa: std.mem.Allocator, io: std.Io, folder: []const u8) bool {
    const file_path = std.fs.path.join(gpa, &.{ folder, name }) catch return false;
    defer gpa.free(file_path);
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch return false;
    file.close(io);
    return true;
}

/// The wallpaper itself, inside `folder` (from `dir`). Caller frees.
pub fn path(gpa: std.mem.Allocator, folder: []const u8) error{OutOfMemory}![]const u8 {
    return std.fs.path.join(gpa, &.{ folder, name });
}

/// A saved wallpaper that was zmural's own from an install that has moved
/// or gone: named like it, inside a `wallpapers` folder, and not there.
pub fn isStale(io: std.Io, saved: []const u8) bool {
    if (!std.mem.eql(u8, std.fs.path.basename(saved), name)) return false;
    const folder = std.fs.path.dirname(saved) orelse return false;
    if (!std.mem.eql(u8, std.fs.path.basename(folder), "wallpapers")) return false;
    const file = std.Io.Dir.cwd().openFile(io, saved, .{}) catch return true;
    file.close(io);
    return false;
}

test isStale {
    const io = std.testing.io;
    try std.testing.expect(isStale(io, "/gone/zmural/share/zmural/wallpapers/" ++ name));
    // The user's own file of another name, or not in a wallpapers folder, is never touched.
    try std.testing.expect(!isStale(io, "/gone/Videos/Wallpapers/rain.mp4"));
    try std.testing.expect(!isStale(io, "/gone/Videos/" ++ name));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "wallpapers");
    try tmp.dir.writeFile(io, .{ .sub_path = "wallpapers/" ++ name, .data = "x" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const there = try std.fs.path.join(std.testing.allocator, &.{ root, "wallpapers", name });
    defer std.testing.allocator.free(there);
    try std.testing.expect(!isStale(io, there));
}

test "found beside the programs, or in share/zmural beside bin, else not at all" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];

    // Linux's layout: bin/ and share/zmural/wallpapers side by side.
    try tmp.dir.createDirPath(io, "linux/bin");
    try tmp.dir.createDirPath(io, "linux/share/zmural/wallpapers");
    try tmp.dir.writeFile(io, .{ .sub_path = "linux/share/zmural/wallpapers/" ++ name, .data = "x" });
    const linux_bin = try std.fs.path.join(gpa, &.{ root, "linux", "bin" });
    defer gpa.free(linux_bin);
    const found = dir(gpa, io, linux_bin) orelse return error.NotFound;
    defer gpa.free(found);
    const want = try std.fs.path.join(gpa, &.{ root, "linux", "share", "zmural", "wallpapers" });
    defer gpa.free(want);
    try std.testing.expectEqualStrings(want, found);

    // Windows' layout: a wallpapers folder beside the programs.
    try tmp.dir.createDirPath(io, "win/wallpapers");
    try tmp.dir.writeFile(io, .{ .sub_path = "win/wallpapers/" ++ name, .data = "x" });
    const win = try std.fs.path.join(gpa, &.{ root, "win" });
    defer gpa.free(win);
    const found_win = dir(gpa, io, win) orelse return error.NotFound;
    defer gpa.free(found_win);
    try std.testing.expect(std.mem.endsWith(u8, found_win, "wallpapers"));

    // A folder without the file doesn't count.
    try tmp.dir.createDirPath(io, "bare/wallpapers");
    const bare = try std.fs.path.join(gpa, &.{ root, "bare" });
    defer gpa.free(bare);
    try std.testing.expect(dir(gpa, io, bare) == null);
}
