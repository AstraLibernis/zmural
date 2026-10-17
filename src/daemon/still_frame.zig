// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! `zmural --still-frame <video> <out.png>` (Linux): one frame of a video,
//! as a picture. Where nothing live can show (a Plasma too old for zmural's
//! plugin, GNOME before its extension runs after a login), the desktop's own
//! wallpaper is set to a still instead, and a video needs one. libmpv, which
//! zmural already uses, decodes it and writes the frame with its image output:
//! no other program is needed.
//!
//! With `max_px` the picture is scaled so its longer side fits: the settings
//! window's thumbnails of videos and pictures the desktop hasn't made one of.
//!
//! A process of its own, like a renderer: a file that crashes the decoder
//! takes only this down, and zmural never waits on it.

const std = @import("std");
const zmural = @import("zmural");
const mpv = zmural.os.libmpv;

const log = std.log.scoped(.still_frame);

/// Exit codes: 0 the picture is written, 1 it couldn't be.
pub fn run(init: std.process.Init, args: []const []const u8) u8 {
    const max_px: ?u16 = if (args.len == 3) std.fmt.parseInt(u16, args[2], 10) catch null else null;
    if (args.len < 2 or args.len > 3 or (args.len == 3 and (max_px == null or max_px == 0))) {
        log.err("usage: zmural --still-frame <video> <out.png> [max_px]", .{});
        return 1;
    }
    write(init, args[0], args[1], max_px) catch |err| {
        log.err("no still frame of {s}: {s}", .{ args[0], @errorName(err) });
        return 1;
    };
    return 0;
}

fn write(init: std.process.Init, video: []const u8, out: []const u8, max_px: ?u16) !void {
    const gpa = init.gpa;
    const io = init.io;
    const api, _ = try mpv.Api.loadSystem();
    // mpv names its frames itself, so they go to a folder of their own next
    // to `out` and the one frame is moved into place.
    const dir = try std.fmt.allocPrint(gpa, "{s}.frame", .{out});
    defer gpa.free(dir);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {}; // zsnag:ok — usually not there; a leftover is replaced
    try cwd.createDirPath(io, dir);
    defer cwd.deleteTree(io, dir) catch {}; // zsnag:ok — best effort: a leftover folder is replaced next time

    const h = api.create() orelse return error.MpvCreate;
    defer api.terminate_destroy(h);
    const dir_z = try gpa.dupeSentinel(u8, dir, 0);
    defer gpa.free(dir_z);
    const options = [_][2][:0]const u8{
        .{ "vo", "image" },
        .{ "vo-image-format", "png" },
        .{ "vo-image-outdir", dir_z },
        // A tenth of the way in: past a fade from black, still near the start.
        .{ "start", "10%" },
        .{ "frames", "1" },
        .{ "audio", "no" },
        .{ "sub", "no" },
        .{ "hwdec", "no" },
        .{ "terminal", "no" },
        .{ "config", "no" },
        .{ "load-scripts", "no" },
        .{ "ytdl", "no" },
    };
    for (options) |o| if (api.set_option_string(h, o[0], o[1]) < 0) return error.MpvOption;
    if (max_px) |px| {
        var vf_buf: [80:0]u8 = undefined;
        const vf = try std.fmt.bufPrintSentinel(&vf_buf, "scale={d}:{d}:force_original_aspect_ratio=decrease", .{ px, px }, 0);
        if (api.set_option_string(h, "vf", vf) < 0) return error.MpvOption;
    }
    if (api.initialize(h) < 0) return error.MpvInit;
    const video_z = try gpa.dupeSentinel(u8, video, 0);
    defer gpa.free(video_z);
    const cmd = [_]?[*:0]const u8{ "loadfile", video_z, null };
    if (api.command(h, &cmd) < 0) return error.MpvLoad;

    // Until the file ends (after its one frame) or fails; at most 20 s.
    var waited: f64 = 0;
    while (waited < 20) : (waited += 0.5) {
        const ev = api.wait_event(h, 0.5);
        switch (ev.event_id) {
            mpv.event.end_file, mpv.event.shutdown => break,
            else => {},
        }
    } else return error.Timeout;

    var frame_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const frame = try std.fmt.bufPrint(&frame_buf, "{s}/00000001.png", .{dir});
    cwd.rename(frame, cwd, out, io) catch return error.NoFrame;
    log.info("still frame of {s}: {s}", .{ video, out });
}
