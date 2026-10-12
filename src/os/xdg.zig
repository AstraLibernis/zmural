// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! XDG base directory variables, as the spec reads them: a variable that is
//! empty or holds a relative path is invalid and treated as unset. Taking
//! one as given would make zmural write into whatever directory it was
//! started from.

const std = @import("std");

/// `value` if it is a usable base directory (non-empty and absolute), else null.
pub fn dir(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len > 0 and v[0] == '/') v else null;
}

test "empty and relative values count as unset" {
    try std.testing.expectEqual(@as(?[]const u8, null), dir(null));
    try std.testing.expectEqual(@as(?[]const u8, null), dir(""));
    try std.testing.expectEqual(@as(?[]const u8, null), dir("relative/share"));
    try std.testing.expectEqualStrings("/home/u/.local/share", dir("/home/u/.local/share").?);
}

/// Which of the user's folders (xdg-user-dirs).
pub const UserDir = enum {
    videos,
    pictures,

    fn key(d: UserDir) []const u8 {
        return switch (d) {
            .videos => "XDG_VIDEOS_DIR",
            .pictures => "XDG_PICTURES_DIR",
        };
    }

    fn fallback(d: UserDir) []const u8 {
        return switch (d) {
            .videos => "Videos",
            .pictures => "Pictures",
        };
    }
};

/// The user's Videos or Pictures folder as the desktop names it, which may
/// be renamed or translated (`~/Vidéos`, `~/Bilder`): `$XDG_VIDEOS_DIR` /
/// `$XDG_PICTURES_DIR` when set, else `user-dirs.dirs` in the config
/// directory (written by xdg-user-dirs at login), else `~/Videos` /
/// `~/Pictures`. `config_home` is a checked `$XDG_CONFIG_HOME`, or null.
pub fn userDir(arena: std.mem.Allocator, io: std.Io, which: UserDir, home: []const u8, config_home: ?[]const u8, env_value: ?[]const u8) ![]const u8 {
    if (dir(env_value)) |d| return d;
    const file = if (config_home) |c|
        try std.fs.path.join(arena, &.{ c, "user-dirs.dirs" })
    else
        try std.fs.path.join(arena, &.{ home, ".config", "user-dirs.dirs" });
    if (std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(64 * 1024))) |text| {
        if (try userDirIn(arena, text, which, home)) |d| return d;
    } else |_| {}
    return std.fs.path.join(arena, &.{ home, which.fallback() });
}

/// `which`'s folder from the text of a `user-dirs.dirs` file, or null when
/// it isn't there. The file is shell syntax, but xdg-user-dirs only ever
/// writes `KEY="$HOME/path"` or `KEY="/absolute/path"`; anything else is
/// ignored, as is a folder that is the home directory itself (xdg-user-dirs'
/// way of turning one off).
pub fn userDirIn(arena: std.mem.Allocator, text: []const u8, which: UserDir, home: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var found: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, line[0..eq], which.key())) continue;
        var v = line[eq + 1 ..];
        if (v.len < 2 or v[0] != '"' or v[v.len - 1] != '"') continue;
        v = v[1 .. v.len - 1];
        const path = if (std.mem.startsWith(u8, v, "$HOME"))
            try std.mem.concat(arena, u8, &.{ home, v["$HOME".len..] })
        else if (v.len > 0 and v[0] == '/')
            v
        else
            continue;
        const trimmed = std.mem.trimEnd(u8, path, "/");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, std.mem.trimEnd(u8, home, "/"))) {
            found = null;
            continue;
        }
        found = trimmed; // the last line wins, as in the shell
    }
    return found;
}

test userDirIn {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\# written by xdg-user-dirs-update
        \\XDG_DESKTOP_DIR="$HOME/Bureau"
        \\XDG_VIDEOS_DIR="$HOME/Vidéos"
        \\XDG_PICTURES_DIR="/data/Images/"
        \\
    ;
    try std.testing.expectEqualStrings("/home/me/Vidéos", (try userDirIn(a, text, .videos, "/home/me")).?);
    try std.testing.expectEqualStrings("/data/Images", (try userDirIn(a, text, .pictures, "/home/me")).?);
    // Missing, turned off (the home itself), or not in the form xdg-user-dirs writes.
    try std.testing.expectEqual(@as(?[]const u8, null), try userDirIn(a, "XDG_MUSIC_DIR=\"$HOME/Music\"", .videos, "/home/me"));
    try std.testing.expectEqual(@as(?[]const u8, null), try userDirIn(a, "XDG_VIDEOS_DIR=\"$HOME/\"", .videos, "/home/me"));
    try std.testing.expectEqual(@as(?[]const u8, null), try userDirIn(a, "XDG_VIDEOS_DIR=\"Videos\"", .videos, "/home/me"));
    try std.testing.expectEqual(@as(?[]const u8, null), try userDirIn(a, "XDG_VIDEOS_DIR=$HOME/Videos", .videos, "/home/me"));
}

/// `path` as a `file://` URI, with everything but the safe characters
/// percent-encoded.
pub fn fileUri(buf: []u8, path: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll("file://") catch return null;
    for (path) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or std.mem.findScalar(u8, "/-_.~!$&'()*+,;=:@", ch) != null;
        if (plain) w.writeByte(ch) catch return null else w.print("%{X:0>2}", .{ch}) catch return null;
    }
    return w.buffered();
}

test fileUri {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("file:///home/me/My%20Pictures/r%C3%A9.png", fileUri(&buf, "/home/me/My Pictures/ré.png").?);
}
