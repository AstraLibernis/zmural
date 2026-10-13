// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Renderer protocol: zmural <-> one renderer process.
//!
//! The daemon spawns `zmural-<kind> --ipc <address> --path <wallpaper>`, the
//! renderer connects back and sends `ready`, and the daemon replies `init`.
//!
//! One renderer can feed several monitors: the daemon adds a **surface** per
//! monitor showing this wallpaper (a shared renderer means one decoder, not N).
//!
//! How a surface reaches the screen depends on the OS:
//! - Windows: the renderer creates a borderless window per surface and reports
//!   it in `window`; the daemon's WorkerW host parents it behind the icons.
//! - Linux: the renderer draws each surface into a pool of DMA-BUFs and
//!   announces frames with `frame_ready`; the sync fds travel via SCM_RIGHTS.

/// 2: `set_property` and `Init.network`.
/// 3: Linux buffers (`buffers`, `release`, `AddSurface.device`/`modifiers`,
/// `FrameReady.generation`).
/// 4: `Init.network` is gone: no wallpaper is given the network.
/// 5: `ping` and `pong`: a renderer that stops answering is restarted.
pub const version: u16 = 5;

/// Surface IDs are chosen by the daemon and unique within one renderer.
pub const SurfaceId = u16;

pub const Init = struct {
    version: u16,
    path: []const u8,
    fill: @import("../core/layout.zig").FillMode,
    fps_cap: u16,
    volume: u8,
    muted: bool,
};
pub const AddSurface = struct {
    surface: SurfaceId,
    width: u32,
    height: u32,
    /// Linux: the GPU (`dev_t`) the surface's compositor reads buffers
    /// from; 0 lets the renderer choose. Unused on Windows.
    device: u64 = 0,
    /// Linux: DRM format modifiers the compositor takes for XRGB8888, as
    /// little-endian u64s. Empty means linear only. Unused on Windows.
    modifiers: []const u8 = "",
};
/// Linux: the display side is done with a slot; the renderer may draw into it again.
pub const Release = struct { surface: SurfaceId, generation: u32, slot: u8 };
pub const RemoveSurface = struct { surface: SurfaceId };
pub const SetVolume = struct { volume: u8, muted: bool };
/// A property value, already checked against the manifest by the daemon.
/// `json` is a JSON literal (number, boolean or string).
pub const SetProperty = struct { name: []const u8, json: []const u8 };

pub const ToRendererOp = enum(u16) {
    init = 1,
    add_surface = 2,
    remove_surface = 3,
    play = 4,
    pause = 5,
    set_volume = 6,
    set_property = 7,
    // 8 and 9 were seek and screenshot: never sent, so removed.
    stop = 10,
    /// Linux only.
    release = 11,
    /// Answer with `pong` at once: the daemon restarts a renderer that doesn't.
    ping = 12,
};

pub const ToRenderer = union(ToRendererOp) {
    init: Init,
    add_surface: AddSurface,
    remove_surface: RemoveSurface,
    play: void,
    pause: void,
    set_volume: SetVolume,
    set_property: SetProperty,
    stop: void,
    release: Release,
    ping: void,
};

pub const LogLevel = enum(u8) { debug, info, warn, err };

pub const Ready = struct { version: u16, capabilities: []const u8 };
/// Windows: a surface's top-level window (an HWND), ready to be parented.
/// Sent again whenever the renderer recreates the window.
pub const Window = struct { surface: SurfaceId, handle: u64 };
/// Linux: a DMA-BUF slot is ready. `content_token` changes only when the
/// user-visible content changes, so a renderer restart never animates a transition.
pub const FrameReady = struct { surface: SurfaceId, generation: u32, slot: u8, content_token: u64 };
/// Linux: a surface's slot pool, `count` single-plane DMA-BUFs whose fds ride
/// on this frame (SCM_RIGHTS), in slot order. A new generation replaces the
/// old pool (after a resize, say); frames name the generation they belong to.
pub const Buffers = struct {
    surface: SurfaceId,
    generation: u32,
    count: u8,
    width: u32,
    height: u32,
    fourcc: u32,
    modifier: u64,
    offset: u32,
    stride: u32,
};
/// Windows: the surface's window shows its first frame, so the wallpaper it
/// replaces can go without the desktop showing through in between.
pub const Shown = struct { surface: SurfaceId };
pub const Log = struct { level: LogLevel, text: []const u8 };
pub const Failed = struct { message: []const u8 };
/// What decodes the video: `codec` is mpv's short name ("h264"), `method` the
/// hardware path in use ("vaapi", "d3d11va"), empty when it is the CPU.
pub const Decoder = struct { codec: []const u8, method: []const u8 };

pub const FromRendererOp = enum(u16) {
    ready = 1,
    window = 2,
    /// Linux only (M6); the Windows daemon never receives it.
    frame_ready = 3,
    // 4 was `loaded`, which nothing used.
    log = 5,
    failed = 6,
    /// Linux only (M6).
    buffers = 7,
    /// Linux only so far: sent when a video starts, and again if it changes.
    decoder = 8,
    /// Windows: a surface shows its first frame.
    shown = 9,
    /// The answer to `ping`.
    pong = 10,
};

pub const FromRenderer = union(FromRendererOp) {
    ready: Ready,
    window: Window,
    frame_ready: FrameReady,
    log: Log,
    failed: Failed,
    buffers: Buffers,
    decoder: Decoder,
    shown: Shown,
    pong: void,
};

test "renderer messages round trip" {
    const std = @import("std");
    const wire = @import("wire.zig");
    var buf: [128]u8 = undefined;
    const msg: ToRenderer = .{ .add_surface = .{ .surface = 3, .width = 2560, .height = 1440 } };
    const back = try wire.decodeFrame(ToRenderer, try wire.encodeMessage(ToRenderer, msg, &buf));
    try std.testing.expectEqualDeep(msg.add_surface, back.add_surface);

    const win: FromRenderer = .{ .window = .{ .surface = 3, .handle = 0x603C8 } };
    const wback = try wire.decodeFrame(FromRenderer, try wire.encodeMessage(FromRenderer, win, &buf));
    try std.testing.expectEqual(win.window, wback.window);

    const dec: FromRenderer = .{ .decoder = .{ .codec = "h264", .method = "" } };
    const dback = try wire.decodeFrame(FromRenderer, try wire.encodeMessage(FromRenderer, dec, &buf));
    try std.testing.expectEqualStrings("h264", dback.decoder.codec);
    try std.testing.expectEqualStrings("", dback.decoder.method);
}
