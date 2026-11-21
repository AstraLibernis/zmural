// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! A file's size and last write time (Windows), so a renderer notices when
//! the file it plays changes under it.
//!
//! A video cut short while mpv plays it can leave mpv spinning on broken
//! packets, busy (several cores) and never idle, which `stall.zig` can't
//! tell from playing. Any change to the file ends the renderer instead; the
//! daemon starts it again, and a file that can no longer be played then
//! fails to load and is reported, while a file replaced by a good one
//! simply plays again.
//!
//! Files on a network share are not watched: a stat there can block for the
//! share's timeout, on the renderer's UI thread.

const std = @import("std");
const w = @import("../os/win32.zig");

pub const Stamp = struct {
    size: u64,
    write_time: u64,
};

/// The file's stamp now, or null if it can't be read (gone, renamed,
/// locked).
pub fn read(path_w: [*:0]const u16) ?Stamp {
    var data: w.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (w.GetFileAttributesExW(path_w, w.GetFileExInfoStandard, &data) == 0) return null;
    return .{
        .size = (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow,
        .write_time = data.ftLastWriteTime.value(),
    };
}

/// Different from `before`, counting a file that became unreadable.
pub fn changed(before: Stamp, path_w: [*:0]const u16) bool {
    const now = read(path_w) orelse return true;
    return now.size != before.size or now.write_time != before.write_time;
}

/// On a network share (`\\server\...`, `\\?\UNC\...` or a mapped drive).
pub fn isRemote(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "\\\\?\\UNC\\")) return true;
    if (std.mem.startsWith(u8, path, "\\\\?\\") and path.len >= 7 and path[5] == ':')
        return driveIsRemote(path[4]);
    if (std.mem.startsWith(u8, path, "\\\\")) return true;
    if (path.len >= 2 and path[1] == ':') return driveIsRemote(path[0]);
    return false;
}

fn driveIsRemote(letter: u8) bool {
    if (!std.ascii.isAlphabetic(letter)) return false;
    const root = [_:0]u16{ letter, ':', '\\' };
    return w.GetDriveTypeW(&root) == w.DRIVE_REMOTE;
}

test "a file cut short, rewritten or removed is a change; an untouched one is not" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content: [8192]u8 = @splat('x');
    try tmp.dir.writeFile(io, .{ .sub_path = "clip.mp4", .data = &content });
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir_path);
    const path = try std.Io.Dir.path.join(std.testing.allocator, &.{ dir_path, "clip.mp4" });
    defer std.testing.allocator.free(path);
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(std.testing.allocator, path);
    defer std.testing.allocator.free(path_w);

    const before = read(path_w).?;
    try std.testing.expectEqual(@as(u64, 8192), before.size);
    try std.testing.expect(!changed(before, path_w));

    // Cut to 4096 bytes, as the 2026-10-14 Windows pass did (check 2b).
    {
        const f = try tmp.dir.openFile(io, "clip.mp4", .{ .mode = .write_only });
        defer f.close(io);
        try f.setLength(io, 4096);
    }
    try std.testing.expect(changed(before, path_w));

    try tmp.dir.deleteFile(io, "clip.mp4");
    try std.testing.expect(changed(before, path_w));
    try std.testing.expect(read(path_w) == null);
}

test isRemote {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(isRemote("\\\\server\\share\\clip.mp4"));
    try std.testing.expect(isRemote("\\\\?\\UNC\\server\\share\\clip.mp4"));
    try std.testing.expect(!isRemote("clip.mp4"));
    try std.testing.expect(!isRemote("C:\\Windows\\clip.mp4")); // C: is a local disk
}
