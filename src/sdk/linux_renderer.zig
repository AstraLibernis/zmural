// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The Linux renderer runtime shared by `zmural --renderer image` and `--renderer video`.
//!
//! Each surface (one per monitor showing this wallpaper) owns a pool of
//! DMA-BUF render targets on the compositor's GPU (`os/gpu.zig`). The pool
//! is announced once (`buffers`, fds attached); after that every frame is
//! just `frame_ready` naming a slot, and the daemon hands slots back with
//! `release` once the compositor is done with them. Nothing is copied.
//!
//! What's drawn:
//! - libmpv through its render API, for real videos, images and GIFs. One
//!   player feeds every surface: one decoder, however many monitors.
//! - the test pattern (GL clears), when the path is `test-pattern`.
//!
//! Single-threaded: one poll loop over the daemon socket, mpv's wakeups
//! (an eventfd its threads write to) and, for the test pattern, a timerfd.
//! While mpv plays, the loop also wakes once a second to see that it still
//! does (`stall.zig`): a player stuck for good ends this renderer, and the
//! daemon starts it again.

const std = @import("std");
const linux = std.os.linux;
const gpu = @import("../os/gpu.zig");
const mpv = @import("../os/libmpv.zig");
const sdk = @import("renderer.zig");
const proto = @import("../protocol/renderer.zig");
const unix = @import("../protocol/unix.zig");
const testpattern = @import("testpattern.zig");
const mpv_options = @import("mpv_options.zig");
const stall = @import("stall.zig");
const FillMode = @import("../core/layout.zig").FillMode;

pub const Kind = enum { image, video };

pub const test_pattern_path = "test-pattern";

const max_surfaces = 16;
/// Three: one on screen, one queued, one being drawn.
const slots_per_surface = 3;
const max_modifiers = 64;
/// DRM_FORMAT_XRGB8888.
const fourcc_xrgb8888: u32 = 0x34325258;

const Surface = struct {
    id: proto.SurfaceId,
    width: u32,
    height: u32,
    generation: u32,
    targets: [slots_per_surface]gpu.Target,
    /// Held by the display side (sent in `frame_ready`, not yet released).
    busy: [slots_per_surface]bool = @splat(false),
    started: bool = false,

    fn freeSlot(s: *const Surface) ?u8 {
        for (s.busy, 0..) |b, i| if (!b) return @intCast(i);
        return null;
    }
};

const State = struct {
    gpa: std.mem.Allocator = undefined,
    conn: unix.Conn = undefined,
    device: ?gpu.Device = null,
    surfaces: [max_surfaces]?Surface = @splat(null),
    next_generation: u32 = 1,
    path: [:0]const u8 = "",
    fill: FillMode = .crop,
    fps: u16 = 30,
    volume: u8 = 50,
    muted: bool = true,
    playing: bool = false,
    frame: u32 = 0,
    content_token: u64 = 0,
    // mpv
    api: ?mpv.Api = null,
    render_api: ?mpv.RenderApi = null,
    player: ?*mpv.Handle = null,
    render_ctx: ?*mpv.RenderContext = null,
    /// Written by mpv's threads (wakeup and render-update callbacks).
    wake_fd: linux.fd_t = -1,
    /// Brightness, speed...: as the daemon last sent them.
    adjust: mpv_options.Adjustments = .{},
    /// What decodes the video, as last logged ("" before the first report).
    decoder: [24]u8 = undefined,
    decoder_len: usize = 0,
    /// Test pattern frame clock.
    timer_fd: linux.fd_t = -1,
    stall: stall.Stall = .{},
    last_stall_check_ms: u64 = 0,
    quit: bool = false,
};

var st: State = .{};

/// `args`: what follows `--renderer <kind>` on the command line.
pub fn run(init: std.process.Init, kind: Kind, args_in: []const []const u8) !void {
    const name = @tagName(kind);
    const args = sdk.parseArgs(args_in) catch |err| {
        std.log.err("renderer {s}: {s}; usage: --renderer {s} --ipc fd:<n> --path <wallpaper>", .{ name, @errorName(err), name });
        std.process.exit(2);
    };
    st.gpa = init.gpa;
    st.path = try init.arena.allocator().dupeSentinel(u8, args.path, 0);
    // Hash the path: the content token only changes when the wallpaper does.
    st.content_token = std.hash.Wyhash.hash(0, args.path);

    const fd = unix.parseFdAddress(args.ipc) orelse {
        std.log.err("zmural-{s}: --ipc must be fd:<n> on Linux (the daemon passes a socket)", .{name});
        std.process.exit(2);
    };
    st.conn = unix.adopt(fd) catch |err| {
        std.log.err("zmural-{s}: bad --ipc fd: {s}", .{ name, @errorName(err) });
        std.process.exit(1);
    };
    try st.conn.setSendTimeout(2000);
    try send(.{ .ready = .{ .version = proto.version, .capabilities = "surfaces pause volume dmabuf" } });

    const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(efd) != .SUCCESS) return error.EventfdFailed;
    st.wake_fd = @intCast(efd);
    const tfd = linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (linux.errno(tfd) != .SUCCESS) return error.TimerfdFailed;
    st.timer_fd = @intCast(tfd);

    if (usesMpv()) {
        const loaded = mpv.Api.loadSystem() catch |err| {
            fail("libmpv.so.2 could not be loaded ({s}); install mpv's library (mpv-libs / libmpv2)", .{@errorName(err)});
            std.process.exit(1);
        };
        st.api = loaded[0];
        st.render_api = loaded[1];
    }
    log(.info, "{s} renderer for '{s}' ({s})", .{ name, args.path, if (usesMpv()) "libmpv render API" else "test pattern" });

    loop() catch |err| {
        fail("renderer stopped: {s}", .{@errorName(err)});
        return err;
    };
    shutdown();
}

fn usesMpv() bool {
    return !std.mem.eql(u8, st.path, test_pattern_path);
}

fn loop() !void {
    var buf: [unix.max_frame]u8 = undefined;
    var fds: [unix.max_fds]linux.fd_t = undefined;
    while (!st.quit) {
        var pfd = [_]linux.pollfd{
            .{ .fd = st.conn.fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = st.wake_fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = st.timer_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        // Asleep until something happens, unless a playing player is to be checked.
        const timeout: i32 = if (watchingPlayer()) stall.check_every_ms else -1;
        const rc = linux.poll(&pfd, pfd.len, timeout);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }
        if (pfd[0].revents != 0) {
            // The daemon's end closed: a renderer never outlives its daemon.
            const f = st.conn.recv(&buf, &fds) catch |err| switch (err) {
                error.Disconnected => return,
                else => return err,
            };
            // Commands carry no fds; drop any a confused peer attached.
            f.closeFds();
            const cmd = f.decode(proto.ToRenderer) catch |err| {
                log(.warn, "unreadable command (opcode {d}): {s}", .{ f.opcode, @errorName(err) });
                continue;
            };
            handle(cmd);
        }
        if (pfd[1].revents != 0) {
            var n: u64 = 0;
            _ = linux.read(st.wake_fd, std.mem.asBytes(&n), 8);
            drainMpvEvents();
            renderMpvIfDue();
        }
        if (pfd[2].revents != 0) {
            var n: u64 = 0;
            _ = linux.read(st.timer_fd, std.mem.asBytes(&n), 8);
            st.frame +%= 1;
            for (&st.surfaces) |*slot| if (slot.*) |*s| drawPattern(s);
        }
        checkStall();
    }
}

fn watchingPlayer() bool {
    return st.playing and st.player != null;
}

fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms; // zsnag:ok — CLOCK_MONOTONIC is never negative
}

/// Once a second while playing: a player idle for `stall.limit_ms` while
/// meant to play has stopped for good. Say so and end; the daemon starts
/// this renderer again, and a file that can't be played any more then fails
/// to load and is reported as such.
fn checkStall() void {
    const now = nowMs();
    if (now -| st.last_stall_check_ms < stall.check_every_ms) return;
    st.last_stall_check_ms = now;
    const api = if (st.api) |*a| a else return;
    const h = st.player orelse return;
    const stuck = st.playing and stall.coreIdle(api, h);
    if (!st.stall.check(now, stuck)) return;
    fail("stopped playing '{s}': no new frame for {d} s; starting it again", .{ st.path, stall.limit_ms / std.time.ms_per_s });
    st.quit = true;
}

fn send(msg: proto.FromRenderer) unix.Error!void {
    return st.conn.send(proto.FromRenderer, msg, &.{});
}

/// Forwards a log line to the daemon, which prints it. Best effort.
fn log(level: proto.LogLevel, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "(log line too long)";
    // A lost log line is not worth failing over; a dead socket surfaces on the next real send.
    send(.{ .log = .{ .level = level, .text = text } }) catch {}; // zsnag:ok — best-effort logging
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "renderer failure (message too long)";
    send(.{ .failed = .{ .message = text } }) catch {}; // zsnag:ok — best-effort report
}

// ---- daemon commands ----------------------------------------------------------------

fn handle(cmd: proto.ToRenderer) void {
    switch (cmd) {
        .init => |i| {
            st.fill = i.fill;
            st.fps = if (i.fps_cap == 0) 30 else i.fps_cap;
            st.volume = i.volume;
            st.muted = i.muted;
        },
        .add_surface => |s| addSurface(s) catch |err| fail("surface {d}: {s}", .{ s.surface, @errorName(err) }),
        .remove_surface => |s| removeSurface(s.surface),
        .play => setPlaying(true),
        .pause => setPlaying(false),
        .set_volume => |v| {
            st.volume = v.volume;
            st.muted = v.muted;
            applyVolume();
        },
        // Only the adjustments on mpv_options' list; the rest is ignored.
        .set_property => |p| if (st.adjust.put(p.name, p.json)) |i| applyAdjustment(i),
        .release => |r| if (findSurface(r.surface)) |s| {
            if (r.generation == s.generation and r.slot < slots_per_surface) {
                s.busy[r.slot] = false;
                // An mpv frame may have been waiting for a free slot. (The
                // test pattern draws on its own timer: drawing on every
                // release would spin as fast as the display hands slots back.)
                if (usesMpv()) renderMpvIfDue();
            }
        },
        .stop => st.quit = true,
        .ping => send(.pong) catch {}, // zsnag:ok — a dead socket ends the loop on its next read
    }
}

fn findSurface(id: proto.SurfaceId) ?*Surface {
    for (&st.surfaces) |*slot| if (slot.*) |*s| if (s.id == id) return s;
    return null;
}

fn openDevice(dev: u64) !*gpu.Device {
    if (st.device) |*d| return d;
    var path_buf: [64]u8 = undefined;
    const path: [:0]const u8 = if (dev != 0)
        gpu.renderNode(&path_buf, dev) orelse return error.NoRenderNode
    else
        "/dev/dri/renderD128";
    st.device = try gpu.Device.open(path);
    log(.info, "rendering on {s}; {s}", .{ path, if (st.device.?.fence != null) "each frame carries its GPU fence (explicit sync)" else "no native fences: each frame waits for the GPU (glFinish)" });
    if (usesMpv()) try startPlayer(&st.device.?);
    return &st.device.?;
}

fn addSurface(a: proto.AddSurface) !void {
    removeSurface(a.surface);
    const slot = for (&st.surfaces) |*slot| {
        if (slot.* == null) break slot;
    } else return error.TooManySurfaces;
    const d = try openDevice(a.device);

    var mods: [max_modifiers]u64 = undefined;
    const n_mods = @min(a.modifiers.len / 8, max_modifiers);
    for (0..n_mods) |i| mods[i] = std.mem.readInt(u64, a.modifiers[i * 8 ..][0..8], .little);

    var s: Surface = .{
        .id = a.surface,
        .width = a.width,
        .height = a.height,
        .generation = st.next_generation,
        .targets = undefined,
    };
    st.next_generation +%= 1;
    var made: usize = 0;
    errdefer for (s.targets[0..made]) |*t| t.destroy(d);
    while (made < slots_per_surface) : (made += 1)
        s.targets[made] = try gpu.Target.create(d, a.width, a.height, fourcc_xrgb8888, mods[0..n_mods]);

    const t0 = s.targets[0];
    var fds: [slots_per_surface]linux.fd_t = undefined;
    for (s.targets, 0..) |t, i| fds[i] = t.fd;
    try st.conn.send(proto.FromRenderer, .{ .buffers = .{
        .surface = s.id,
        .generation = s.generation,
        .count = slots_per_surface,
        .width = a.width,
        .height = a.height,
        .fourcc = t0.fourcc,
        .modifier = t0.modifier,
        .offset = t0.offset,
        .stride = t0.stride,
    } }, &fds);
    log(.info, "surface {d}: {d}x{d}, modifier 0x{x}", .{ s.id, a.width, a.height, t0.modifier });
    slot.* = s;

    if (usesMpv()) renderMpvIfDue() else drawPattern(&slot.*.?);
}

fn removeSurface(id: proto.SurfaceId) void {
    const d = if (st.device) |*d| d else return;
    for (&st.surfaces) |*slot| if (slot.*) |*s| if (s.id == id) {
        for (&s.targets) |*t| t.destroy(d);
        slot.* = null;
    };
}

fn setPlaying(playing: bool) void {
    if (playing == st.playing) return;
    st.playing = playing;
    // Idle while paused is no stall: count afresh from here.
    st.stall = .{};
    if (usesMpv()) {
        const api = if (st.api) |*a| a else return;
        const h = st.player orelse return;
        const o = mpv_options.pause(playing);
        _ = api.set_property_string(h, o[0], o[1]);
        return;
    }
    // Paused means paused: no timer, no frames.
    const period_ns: isize = if (playing) @divTrunc(std.time.ns_per_s, @as(isize, st.fps)) else 0;
    const spec: linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = period_ns },
        .it_value = .{ .sec = 0, .nsec = period_ns },
    };
    _ = linux.timerfd_settime(st.timer_fd, .{}, &spec, null);
}

/// Hands a drawn slot to the daemon, with the fence the compositor waits on
/// before it samples the frame (explicit sync). Without native fences the
/// GPU work is already complete and no fence goes with it.
fn present(d: *gpu.Device, s: *Surface, slot: u8) void {
    s.busy[slot] = true;
    const fence = d.endFrame();
    defer if (fence) |fd| {
        _ = linux.close(fd);
    };
    const msg: proto.FromRenderer = .{ .frame_ready = .{ .surface = s.id, .generation = s.generation, .slot = slot, .content_token = st.content_token } };
    const sent = if (fence) |fd| st.conn.send(proto.FromRenderer, msg, &.{fd}) else send(msg);
    sent catch {
        st.quit = true;
    };
}

// ---- test pattern ----------------------------------------------------------------------

fn drawPattern(s: *Surface) void {
    if (usesMpv()) return;
    const d = if (st.device) |*d| d else return;
    const slot = s.freeSlot() orelse return; // the display side has them all; next tick
    const gl = &d.gl;
    gl.BindFramebuffer(gpu.Gl.framebuffer, s.targets[slot].framebuffer);
    gl.Viewport(0, 0, @intCast(s.width), @intCast(s.height));
    gl.Enable(gpu.Gl.scissor_test);
    const bands = testpattern.bands;
    var i: u32 = 0;
    while (i < bands) : (i += 1) {
        const x0 = @as(u64, s.width) * i / bands;
        const x1 = @as(u64, s.width) * (i + 1) / bands;
        const c = testpattern.bandColor(i, st.frame);
        gl.Scissor(@intCast(x0), 0, @intCast(x1 - x0), @intCast(s.height));
        gl.ClearColor(@as(f32, @floatFromInt(c[0])) / 255, @as(f32, @floatFromInt(c[1])) / 255, @as(f32, @floatFromInt(c[2])) / 255, 1);
        gl.Clear(gpu.Gl.color_buffer_bit);
    }
    gl.Disable(gpu.Gl.scissor_test);
    gl.BindFramebuffer(gpu.Gl.framebuffer, 0);
    present(d, s, slot);
    if (!s.started) {
        s.started = true;
        log(.info, "surface {d}: first frame", .{s.id});
    }
}

// ---- mpv ------------------------------------------------------------------------------------

fn startPlayer(d: *gpu.Device) !void {
    const api = if (st.api) |*a| a else return error.LibmpvNotLoaded;
    const rapi = st.render_api.?;
    const h = api.create() orelse return error.MpvCreateFailed;
    errdefer api.terminate_destroy(h);

    const own = [_]mpv_options.Option{
        // Frames go through the render API, into our buffers.
        .{ "vo", "libmpv" },
        mpv_options.pause(st.playing),
        mpv_options.fill(st.fill),
    };
    for (own ++ mpv_options.common) |o| setOption(api, h, o[0], o[1]);
    // Adjustments that arrived before the player did.
    for (mpv_options.adjustments, 0..) |name, i| if (st.adjust.value(i)) |v| setOption(api, h, name, v);
    _ = api.request_log_messages(h, "warn");
    api.set_wakeup_callback(h, onWakeup, null);
    const rc = api.initialize(h);
    if (rc < 0) {
        log(.err, "mpv_initialize: {s}", .{std.mem.span(api.error_string(rc))});
        return error.MpvInitFailed;
    }

    var gl_init: mpv.OpenGlInitParams = .{ .get_proc_address = getProcAddress, .get_proc_address_ctx = d };
    // Our render node: with it a VA-API decoder on the same GPU hands its
    // frames over as DMA-BUFs, with no copy through the CPU.
    var drm: mpv.DrmParamsV2 = .{ .render_fd = d.fd };
    const params = [_]mpv.RenderParam{
        .{ .type = mpv.render_param.api_type, .data = @constCast(mpv.render_api_type_opengl) },
        .{ .type = mpv.render_param.opengl_init_params, .data = &gl_init },
        .{ .type = mpv.render_param.drm_display_v2, .data = &drm },
        .{ .type = mpv.render_param.invalid, .data = null },
    };
    var ctx: ?*mpv.RenderContext = null;
    const crc = rapi.create(&ctx, h, &params);
    if (crc < 0 or ctx == null) {
        log(.err, "mpv_render_context_create: {s}", .{std.mem.span(api.error_string(crc))});
        return error.MpvRenderFailed;
    }
    rapi.set_update_callback(ctx.?, onWakeup, null);
    st.player = h;
    st.render_ctx = ctx;
    applyVolume();
    const load = [_]?[*:0]const u8{ "loadfile", st.path.ptr, null };
    if (api.command(h, &load) < 0) return error.MpvLoadFailed;
}

fn getProcAddress(ctx: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    const d: *gpu.Device = @ptrCast(@alignCast(ctx orelse return null)); // zsnag:ok — set from a *gpu.Device in startPlayer
    return d.procAddress(name);
}

fn setOption(api: *const mpv.Api, h: *mpv.Handle, name: [:0]const u8, value: [:0]const u8) void {
    const rc = api.set_option_string(h, name, value);
    if (rc < 0) log(.warn, "mpv option {s}={s}: {s}", .{ name, value, std.mem.span(api.error_string(rc)) });
}

/// Sets one adjustment on the running player (none yet: `startPlayer` does it).
fn applyAdjustment(i: usize) void {
    const api = if (st.api) |*a| a else return;
    const h = st.player orelse return;
    const v = st.adjust.value(i) orelse return;
    const rc = api.set_property_string(h, mpv_options.adjustments[i], v);
    if (rc < 0) log(.warn, "mpv {s}={s}: {s}", .{ mpv_options.adjustments[i], v, std.mem.span(api.error_string(rc)) });
}

fn applyVolume() void {
    const api = if (st.api) |*a| a else return;
    const h = st.player orelse return;
    var buf: [8]u8 = undefined;
    const vol = std.fmt.bufPrintSentinel(&buf, "{d}", .{st.volume}, 0) catch return;
    _ = api.set_property_string(h, "volume", vol);
    _ = api.set_property_string(h, "mute", if (st.muted) "yes" else "no");
}

/// Runs on mpv's threads: just wake the loop.
fn onWakeup(_: ?*anyopaque) callconv(.c) void {
    const one: u64 = 1;
    _ = linux.write(st.wake_fd, std.mem.asBytes(&one), 8);
}

/// mpv asked for a frame and not every surface got one yet.
var frame_due = false;

fn renderMpvIfDue() void {
    const rapi = st.render_api orelse return;
    const ctx = st.render_ctx orelse return;
    const d = if (st.device) |*d| d else return;
    if (rapi.update(ctx) & mpv.render_update_frame != 0) frame_due = true;
    if (!frame_due) return;
    // Render the same frame into every surface that has a free slot. With
    // none free anywhere, wait for a release (`handle(.release)` retries).
    var rendered = false;
    for (&st.surfaces) |*sl| if (sl.*) |*s| {
        const slot = s.freeSlot() orelse continue;
        var fbo: mpv.OpenGlFbo = .{ .fbo = @intCast(s.targets[slot].framebuffer), .w = @intCast(s.width), .h = @intCast(s.height) };
        // No flip: mpv then writes the top row first, which is how the
        // compositor reads a DMA-BUF (checked against ffmpeg's own frame).
        var flip: c_int = 0;
        // Don't block the loop until the frame's display time: mpv's own
        // update callback already paces frames.
        var no_block: c_int = 0;
        const params = [_]mpv.RenderParam{
            .{ .type = mpv.render_param.opengl_fbo, .data = &fbo },
            .{ .type = mpv.render_param.flip_y, .data = &flip },
            .{ .type = mpv.render_param.block_for_target_time, .data = &no_block },
            .{ .type = mpv.render_param.invalid, .data = null },
        };
        _ = rapi.render(ctx, &params);
        present(d, s, slot);
        rendered = true;
        if (!s.started) {
            s.started = true;
            log(.info, "surface {d}: first frame", .{s.id});
        }
    };
    if (rendered) {
        rapi.report_swap(ctx);
        frame_due = false;
    }
}

/// What mpv says, again and again, about a file with nothing it can decode.
const no_media = "No media data to loop";
/// Said once: the daemon replaces this renderer.
var no_media_told = false;

fn drainMpvEvents() void {
    const api = if (st.api) |*a| a else return;
    const h = st.player orelse return;
    while (true) {
        const e = api.wait_event(h, 0);
        switch (e.event_id) {
            mpv.event.none => return,
            mpv.event.log_message => {
                const m: *const mpv.LogMessage = @ptrCast(@alignCast(e.data orelse continue)); // zsnag:ok — mpv documents the payload type
                // mpv also tries its KMS-overlay path once we name a render node,
                // and says it has no display to drive. It never will: not news.
                if (std.mem.endsWith(u8, std.mem.span(m.prefix), "drmprime-overlay")) continue;
                // A file mpv opened but couldn't decode a single frame from
                // (an empty or damaged picture, one too large to decode): it
                // says this, and retries forever, instead of ending the file.
                if (!no_media_told and std.mem.startsWith(u8, std.mem.span(m.text), no_media)) {
                    no_media_told = true;
                    fail("cannot show '{s}': no picture or video in it could be decoded", .{st.path});
                }
                const level: proto.LogLevel = if (std.mem.eql(u8, std.mem.span(m.level), "warn")) .warn else .err;
                log(level, "mpv {s}: {s}", .{ std.mem.span(m.prefix), std.mem.trimEnd(u8, std.mem.span(m.text), "\r\n") });
            },
            mpv.event.end_file => {
                const ef: *const mpv.EndFile = @ptrCast(@alignCast(e.data orelse continue)); // zsnag:ok — mpv documents the payload type
                if (ef.reason == mpv.end_reason.@"error")
                    fail("cannot play '{s}': {s}", .{ st.path, std.mem.span(api.error_string(ef.@"error")) });
                // Every wallpaper loops forever (`loop-file`, `image-display-
                // duration`), so reaching its end means nothing in it could be
                // shown: an empty or damaged picture mpv opened but found no
                // frame in. Left alone, mpv retries it several times a second.
                if (ef.reason == mpv.end_reason.eof)
                    fail("cannot show '{s}': there is no picture or video in it that can be shown", .{st.path});
            },
            mpv.event.playback_restart => reportDecoder(api, h),
            mpv.event.video_reconfig => if (mpv.tooLarge(api, h)) |sz|
                fail("cannot show '{s}': at {d}x{d} it is larger than a wallpaper can be (50 megapixels at most)", .{ st.path, sz[0], sz[1] }),
            mpv.event.shutdown => return,
            else => {},
        }
    }
}

/// Tells the daemon, once per change, whether the GPU or the CPU decodes the
/// video. mpv has already tried every hardware decoder the system offers.
fn reportDecoder(api: *const mpv.Api, h: *mpv.Handle) void {
    // "h264", "av1"...; absent for a still, which has no decoder worth naming.
    const format = api.get_property_string(h, "video-format") orelse return;
    defer api.free(format);
    const raw = api.get_property_string(h, "hwdec-current") orelse return;
    defer api.free(raw);
    const name = std.mem.span(raw);
    if (name.len == 0 or name.len > st.decoder.len) return;
    if (std.mem.eql(u8, name, st.decoder[0..st.decoder_len])) return;
    @memcpy(st.decoder[0..name.len], name);
    st.decoder_len = name.len;
    send(.{ .decoder = .{ .codec = std.mem.span(format), .method = if (std.mem.eql(u8, name, "no")) "" else name } }) catch {}; // zsnag:ok — informational; a dead socket surfaces on the next real send
}

fn shutdown() void {
    if (st.render_ctx) |ctx| st.render_api.?.free(ctx);
    st.render_ctx = null;
    if (st.player) |h| st.api.?.terminate_destroy(h);
    st.player = null;
    if (st.device) |*d| {
        for (&st.surfaces) |*slot| if (slot.*) |*s| {
            for (&s.targets) |*t| t.destroy(d);
            slot.* = null;
        };
        d.close();
    }
    st.conn.close();
}
