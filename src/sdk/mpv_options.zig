// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The mpv options every zmural player uses, on every OS. Each renderer adds
//! its own output options (`wid` on Windows, the render API on Linux).

const FillMode = @import("../core/layout.zig").FillMode;

pub const Option = [2][:0]const u8;

pub const common = [_]Option{
    // Never touch the user's mpv config, never draw UI, never take input.
    .{ "config", "no" },
    .{ "terminal", "no" },
    .{ "osc", "no" },
    .{ "osd-level", "0" },
    .{ "input-default-bindings", "no" },
    .{ "input-vo-keyboard", "no" },
    .{ "input-cursor", "no" },
    .{ "cursor-autohide", "no" },
    // A wallpaper must never keep the screen awake or block the screensaver.
    .{ "stop-screensaver", "no" },
    .{ "idle", "yes" },
    .{ "keep-open", "yes" },
    .{ "loop-file", "inf" },
    .{ "image-display-duration", "inf" },
    .{ "hwdec", "auto-safe" },
    // Wallpapers are untrusted files: open exactly this one and nothing it points to.
    .{ "ytdl", "no" },
    .{ "load-scripts", "no" },
    .{ "access-references", "no" },
    .{ "sub-auto", "no" },
    .{ "audio-file-auto", "no" },
    .{ "cover-art-auto", "no" },
    .{ "input-ipc-server", "" },
};

/// How mpv fits the video to the surface for each fill mode.
pub fn fill(mode: FillMode) Option {
    return switch (mode) {
        .crop => .{ "panscan", "1.0" },
        .fit => .{ "panscan", "0.0" },
        .stretch => .{ "keepaspect", "no" },
        .center => .{ "video-unscaled", "yes" },
    };
}

pub fn pause(playing: bool) Option {
    return .{ "pause", if (playing) "no" else "yes" };
}

/// The only mpv properties a wallpaper's own properties may set: picture
/// adjustments and speed. Anything else a daemon sends is ignored, so a
/// wallpaper can't reach mpv's scripting, file or output options.
/// (`daemon/adjust.zig` offers exactly these.)
pub const adjustments = [_][:0]const u8{ "speed", "brightness", "contrast", "saturation", "gamma", "hue" };

pub fn isAdjustment(name: []const u8) bool {
    return adjustmentIndex(name) != null;
}

fn adjustmentIndex(name: []const u8) ?usize {
    for (adjustments, 0..) |a, i| if (std.mem.eql(u8, a, name)) return i;
    return null;
}

/// Adjustments as the daemon last sent them. They can arrive before the
/// player exists, so they are kept and applied when it starts as well.
pub const Adjustments = struct {
    text: [adjustments.len][24:0]u8 = undefined,
    set: [adjustments.len]bool = @splat(false),

    /// Takes `name = value` (a JSON number) if it is an adjustment with a
    /// plain finite number. Returns which one, for applying it live.
    pub fn put(a: *Adjustments, name: []const u8, json: []const u8) ?usize {
        const i = adjustmentIndex(name) orelse return null;
        const v = std.fmt.parseFloat(f64, std.mem.trim(u8, json, " \t\r\n")) catch return null;
        if (!std.math.isFinite(v)) return null;
        _ = std.fmt.bufPrintSentinel(&a.text[i], "{d}", .{v}, 0) catch return null;
        a.set[i] = true;
        return i;
    }

    /// The value to give mpv for adjustment `i`, if one was sent.
    pub fn value(a: *const Adjustments, i: usize) ?[:0]const u8 {
        if (!a.set[i]) return null;
        return std.mem.sliceTo(&a.text[i], 0);
    }
};

const std = @import("std");

test "only picture adjustments and speed reach mpv, as plain numbers" {
    var a: Adjustments = .{};
    try std.testing.expectEqual(@as(?usize, 1), a.put("brightness", "-20"));
    try std.testing.expectEqualStrings("-20", a.value(1).?);
    try std.testing.expectEqual(@as(?usize, 0), a.put("speed", " 1.5 "));
    try std.testing.expectEqualStrings("1.5", a.value(0).?);
    try std.testing.expectEqual(@as(?[:0]const u8, null), a.value(2));
    // Not on the list, or not a number: ignored.
    for ([_][2][]const u8{
        .{ "script", "\"/tmp/x.lua\"" }, .{ "stream-record", "\"/tmp/out\"" }, .{ "vo", "\"null\"" },
        .{ "brightness", "\"yes\"" },    .{ "hue", "nan" },                      .{ "gamma", "1e999" },
        .{ "", "1" },
    }) |bad| try std.testing.expectEqual(@as(?usize, null), a.put(bad[0], bad[1]));
    try std.testing.expectEqualStrings("-20", a.value(1).?);
}
