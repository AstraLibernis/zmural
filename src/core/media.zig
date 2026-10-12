// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Which files can be wallpapers, by extension. Shared by the library scan
//! (zmural) and `zmural-console import`.

const std = @import("std");

pub const video_exts = [_][]const u8{ ".mp4", ".mkv", ".webm", ".mov", ".avi", ".wmv", ".m4v" };
pub const image_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".avif" };
pub const web_exts = [_][]const u8{ ".html", ".htm" };
/// A folder holding this file is a wallpaper package.
pub const package_manifest = "zmural.toml";

pub fn isPlayable(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for (video_exts ++ image_exts ++ web_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

pub fn isVideo(name: []const u8) bool {
    return hasExt(name, &video_exts);
}

pub fn isImage(name: []const u8) bool {
    return hasExt(name, &image_exts);
}

fn hasExt(name: []const u8, exts: []const []const u8) bool {
    const ext = std.fs.path.extension(name);
    for (exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

test "videos and pictures by extension, any case" {
    try std.testing.expect(isVideo("/v/Rain.WebM"));
    try std.testing.expect(!isVideo("/v/rain.png"));
    try std.testing.expect(isImage("/v/rain.JPG"));
    try std.testing.expect(!isImage("/v/page.html"));
}

/// What to call a wallpaper: its file name, or for a package (`<folder>/zmural.toml`) its folder's.
pub fn displayName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (!std.ascii.eqlIgnoreCase(base, package_manifest)) return base;
    const folder = std.fs.path.dirname(path) orelse return base;
    return std.fs.path.basename(folder);
}

test displayName {
    try std.testing.expectEqualStrings("rain.mp4", displayName("/home/me/Videos/Wallpapers/rain.mp4"));
    try std.testing.expectEqualStrings("Neon Rain", displayName("/home/me/Videos/Wallpapers/Neon Rain/zmural.toml"));
    try std.testing.expectEqualStrings("zmural.toml", displayName("zmural.toml"));
}
