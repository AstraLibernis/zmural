// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Which renderer program shows a wallpaper, on every OS.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");

pub const Kind = enum {
    image,
    video,
    web,

    /// A renderer is this program started again as `--renderer <name>`:
    /// its own process, the same file.
    pub const mode_flag = "--renderer";
    pub fn modeName(k: Kind) []const u8 {
        return @tagName(k);
    }

    pub fn forPath(path: []const u8) Kind {
        const ext = std.fs.path.extension(path);
        for ([_][]const u8{ ".mp4", ".mkv", ".webm", ".mov", ".avi", ".wmv", ".m4v" }) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return .video;
        }
        for ([_][]const u8{ ".html", ".htm" }) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return .web;
        }
        return .image;
    }
};

/// Web addresses are never wallpapers (both runtimes refuse them with
/// `no_web_addresses`): a wallpaper is a file on this computer.
pub const isUrl = zmural.sdk.web_renderer.isUrl;
pub const no_web_addresses = "zmural doesn't show web addresses; a web wallpaper is a page saved on this computer, and it runs offline";

test "Kind.forPath" {
    try std.testing.expectEqual(Kind.video, Kind.forPath("C:\\wp\\Rain.MP4"));
    try std.testing.expectEqual(Kind.web, Kind.forPath("site/index.html"));
    try std.testing.expectEqual(Kind.image, Kind.forPath("test-pattern"));
    try std.testing.expectEqual(Kind.image, Kind.forPath("a.webp"));
    try std.testing.expectEqual(Kind.video, Kind.forPath("/home/me/Videos/Wallpapers/rain.webm"));
    try std.testing.expect(isUrl("https://www.shadertoy.com/embed/abc"));
    try std.testing.expect(!isUrl("/home/me/https://odd/index.html"));
}
