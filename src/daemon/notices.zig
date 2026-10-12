// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Things zmural tells the user once and never again, and the file that
//! remembers which: `<state dir>/notices`, one key per line.
//!
//! Used for "this video is decoded on the CPU": true at every start for the
//! same wallpaper, worth saying the first time only. Nothing else is cached:
//! what the system can decode is found out afresh every time a video starts.

const std = @import("std");

const file_name = "notices";
const max_bytes = 16 * 1024;

/// The name a person knows a codec by, from mpv's short one ("h264").
/// Anything that isn't a plain short word comes back as "this video's format":
/// the name is a renderer's, shown in a notification.
pub fn codecName(buf: []u8, codec: []const u8) []const u8 {
    const known = [_][2][]const u8{
        .{ "h264", "H.264" },        .{ "hevc", "H.265" }, .{ "av1", "AV1" },
        .{ "vp9", "VP9" },           .{ "vp8", "VP8" },    .{ "mpeg4", "MPEG-4" },
        .{ "mpeg2video", "MPEG-2" }, .{ "vc1", "VC-1" },   .{ "theora", "Theora" },
    };
    for (known) |k| if (std.mem.eql(u8, codec, k[0])) return k[1];
    if (!plain(codec) or codec.len > buf.len) return "this video's format";
    return std.ascii.upperString(buf, codec);
}

/// Safe to put in the notices file and in a message: short, no spaces or
/// control characters.
pub fn plain(word: []const u8) bool {
    if (word.len == 0 or word.len > 16) return false;
    for (word) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

/// Has `key` been told already? False when the file can't be read.
pub fn seen(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, key: []const u8) bool {
    const text = read(io, gpa, dir) orelse return false;
    defer gpa.free(text);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, line, key)) return true;
    return false;
}

/// Records `key`. A failure only means the user is told again next time.
pub fn remember(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, key: []const u8) void {
    const old = read(io, gpa, dir) orelse gpa.dupe(u8, "") catch return;
    defer gpa.free(old);
    const text = std.fmt.allocPrint(gpa, "{s}{s}\n", .{ old, key }) catch return;
    defer gpa.free(text);
    const path = std.fs.path.join(gpa, &.{ dir, file_name }) catch return;
    defer gpa.free(path);
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, dir) catch return;
    cwd.writeFile(io, .{ .sub_path = path, .data = text }) catch |err|
        std.log.warn("can't write {s}: {s}", .{ path, @errorName(err) });
}

fn read(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) ?[]u8 {
    const path = std.fs.path.join(gpa, &.{ dir, file_name }) catch return null;
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch null;
}

test "codec names people know; anything odd is not repeated" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("H.264", codecName(&buf, "h264"));
    try std.testing.expectEqualStrings("H.265", codecName(&buf, "hevc"));
    try std.testing.expectEqualStrings("PRORES", codecName(&buf, "prores"));
    try std.testing.expectEqualStrings("this video's format", codecName(&buf, ""));
    try std.testing.expectEqualStrings("this video's format", codecName(&buf, "h264\nInstall this"));
    try std.testing.expectEqualStrings("this video's format", codecName(&buf, "a-very-long-codec-name"));
}

test "a notice is remembered across reads, per key, in a directory made on demand" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const dir = try std.fs.path.join(gpa, &.{ buf[0..n], "state", "zmural" });
    defer gpa.free(dir);

    try std.testing.expect(!seen(io, gpa, dir, "cpu-decode h264"));
    remember(io, gpa, dir, "cpu-decode h264");
    try std.testing.expect(seen(io, gpa, dir, "cpu-decode h264"));
    // A longer key that starts the same is another notice.
    try std.testing.expect(!seen(io, gpa, dir, "cpu-decode h26"));
    try std.testing.expect(!seen(io, gpa, dir, "cpu-decode hevc"));
    remember(io, gpa, dir, "cpu-decode hevc");
    try std.testing.expect(seen(io, gpa, dir, "cpu-decode h264"));
    try std.testing.expect(seen(io, gpa, dir, "cpu-decode hevc"));

}
