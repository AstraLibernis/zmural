// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The Windows renderer runtime shared by zmural-image and zmural-video.
//!
//! One borderless window per surface. Inside it, either:
//! - libmpv (`--wid`), for real videos, images and animated GIFs; or
//! - the GDI test pattern, when the path is `test-pattern`.
//!
//! Paused means paused: mpv's `pause` property, or no timer for the test
//! pattern, so no frames and ~0 CPU/GPU.
//!
//! mpv teardown runs on a worker thread. `mpv_terminate_destroy` blocks, and
//! while it tears down its child window mpv's threads may send messages to
//! our window, which would deadlock if our message loop were the one waiting.

const std = @import("std");
const w = @import("../os/win32.zig");
const mpv = @import("../os/libmpv.zig");
const process = @import("../os/process.zig");
const sdk = @import("renderer.zig");
const proto = @import("../protocol/renderer.zig");
const pipe = @import("../protocol/pipe.zig");
const testpattern = @import("testpattern.zig");
const mpv_options = @import("mpv_options.zig");
const FillMode = @import("../core/layout.zig").FillMode;

pub const Kind = enum { image, video };

pub const test_pattern_path = "test-pattern";

const WM_DAEMON = w.WM_APP + 1;
const WM_MPV = w.WM_APP + 2;
const WM_PLAYER_GONE = w.WM_APP + 3;
const timer_frame: usize = 1;
const max_surfaces = 16;

const Surface = struct {
    id: proto.SurfaceId,
    hwnd: w.HWND,
    player: ?*mpv.Handle = null,
    /// The first frame has been shown (and logged).
    started: bool = false,
    /// mpv is being torn down on a worker thread; destroy the window after.
    closing: bool = false,
};

/// At most this many mpv log lines per second go to the daemon.
const log_lines_per_second = 20;

const State = struct {
    gpa: std.mem.Allocator = undefined,
    session: sdk.Session = undefined,
    instance: ?w.HINSTANCE = null,
    control: ?w.HWND = null,
    surfaces: [max_surfaces]?Surface = @splat(null),
    /// Brightness, speed...: as the daemon last sent them.
    adjust: mpv_options.Adjustments = .{},
    api: ?mpv.Api = null,
    path: [:0]const u8 = "",
    fill: FillMode = .crop,
    fps: u16 = 30,
    volume: u8 = 50,
    muted: bool = true,
    playing: bool = false,
    frame: u32 = 0,
    log_window_start: u64 = 0,
    log_lines: u32 = 0,
    log_suppressed: u32 = 0,
};

var st: State = .{};

/// `args`: what follows `--renderer <kind>` on the command line.
pub fn run(init: std.process.Init, kind: Kind, args_in: []const []const u8) !void {
    const name = @tagName(kind);
    const args = sdk.parseArgs(args_in) catch |err| {
        std.log.err("renderer {s}: {s}; usage: --renderer {s} --ipc <address> --path <wallpaper>", .{ name, @errorName(err), name });
        std.process.exit(2);
    };
    st.gpa = init.gpa;
    st.path = try init.arena.allocator().dupeZ(u8, args.path);

    _ = w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    st.instance = w.GetModuleHandleW(null);
    const control_class = w.L("zmural.renderer");
    const surface_class = w.L("zmural.surface");
    if (w.RegisterClassExW(&.{ .lpfnWndProc = controlProc, .hInstance = st.instance, .lpszClassName = control_class }) == 0 or
        w.RegisterClassExW(&.{ .lpfnWndProc = surfaceProc, .hInstance = st.instance, .lpszClassName = surface_class }) == 0)
        return error.RegisterClassFailed;
    st.control = w.CreateWindowExW(0, control_class, null, 0, 0, 0, 0, 0, w.HWND_MESSAGE, null, st.instance, null) orelse
        return error.CreateWindowFailed;

    st.session = sdk.Session.open(st.gpa, args, "surfaces pause volume") catch |err| {
        std.log.err("zmural-{s}: cannot reach the daemon at {s}: {s}", .{ name, args.ipc, @errorName(err) });
        std.process.exit(1);
    };

    if (usesMpv()) {
        loadMpv() catch |err| {
            fail("libmpv-2.dll could not be loaded ({s}); it belongs next to the zmural executables", .{@errorName(err)});
            std.process.exit(1);
        };
    }
    _ = w.CloseHandle(try st.session.startReader(st.control.?, WM_DAEMON));
    st.session.log(.info, "{s} renderer for '{s}' ({s})", .{ name, args.path, if (usesMpv()) "libmpv" else "test pattern" });

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    // Exiting the process ends mpv's threads too; the daemon only stops us when it's done with us.
}

fn usesMpv() bool {
    return !std.mem.eql(u8, st.path, test_pattern_path);
}

fn loadMpv() !void {
    const path = try process.siblingExe(st.gpa, "libmpv-2.dll");
    defer st.gpa.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(st.gpa, path);
    defer st.gpa.free(path_w);
    st.api = try mpv.Api.load(path_w);
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "renderer failure (message too long)";
    // Best effort: if the daemon is gone there is nobody left to tell.
    st.session.send(.{ .failed = .{ .message = text } }) catch {}; // zsnag:ok — best-effort report
}

// ---- daemon commands ------------------------------------------------------------

fn handle(cmd: proto.ToRenderer) void {
    switch (cmd) {
        .init => |i| {
            st.fill = i.fill;
            st.fps = if (i.fps_cap == 0) 30 else i.fps_cap;
            st.volume = i.volume;
            st.muted = i.muted;
        },
        .add_surface => |s| addSurface(s),
        .remove_surface => |s| removeSurface(s.surface),
        .play => setPlaying(true),
        .pause => setPlaying(false),
        .set_volume => |v| {
            st.volume = v.volume;
            st.muted = v.muted;
            for (st.surfaces) |slot| if (slot) |s| if (s.player) |h| applyVolume(h);
        },
        // Only the adjustments on mpv_options' list; the rest is ignored.
        .set_property => |p| if (st.adjust.put(p.name, p.json)) |i| {
            const api = if (st.api) |*a| a else return;
            const v = st.adjust.value(i) orelse return;
            for (st.surfaces) |slot| if (slot) |s| if (s.player) |h| {
                _ = api.set_property_string(h, mpv_options.adjustments[i], v);
            };
        },
        .stop => w.PostQuitMessage(0),
        .release => {}, // Linux only
    }
}

fn addSurface(s: proto.AddSurface) void {
    removeSurface(s.surface);
    const slot = for (&st.surfaces) |*slot| {
        if (slot.* == null) break slot;
    } else {
        st.session.log(.warn, "too many surfaces; ignoring surface {d}", .{s.surface});
        return;
    };
    const hwnd = w.CreateWindowExW(
        w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE,
        w.L("zmural.surface"),
        w.L("zmural wallpaper"),
        w.WS_POPUP,
        -32000,
        -32000,
        @intCast(s.width), // zsnag:ok — monitor sizes fit c_int
        @intCast(s.height), // zsnag:ok — monitor sizes fit c_int
        null,
        null,
        st.instance,
        null,
    ) orelse {
        st.session.log(.err, "cannot create a window for surface {d} (win32 error {d})", .{ s.surface, w.GetLastError() });
        return;
    };
    slot.* = .{ .id = s.surface, .hwnd = hwnd };
    st.session.send(.{ .window = .{ .surface = s.surface, .handle = @intFromPtr(hwnd) } }) catch {
        w.PostQuitMessage(0);
        return;
    };
    if (usesMpv()) startPlayer(&slot.*.?) catch |err| fail("cannot start playback: {s}", .{@errorName(err)});
}

fn removeSurface(id: proto.SurfaceId) void {
    for (&st.surfaces) |*slot| {
        const s = if (slot.*) |*s| s else continue;
        if (s.id != id or s.closing) continue;
        if (s.player) |h| {
            // The window is destroyed once mpv has let go of it (WM_PLAYER_GONE).
            s.closing = true;
            s.player = null;
            teardownAsync(h, slotIndex(slot));
        } else {
            const hwnd = s.hwnd;
            slot.* = null;
            if (w.IsWindow(hwnd) != 0) _ = w.DestroyWindow(hwnd);
        }
    }
}

fn setPlaying(playing: bool) void {
    if (playing == st.playing) return;
    st.playing = playing;
    if (usesMpv()) {
        setOnPlayers("pause", if (playing) "no" else "yes");
    } else if (playing) {
        _ = w.SetTimer(st.control, timer_frame, 1000 / @as(w.UINT, st.fps), null);
    } else {
        _ = w.KillTimer(st.control, timer_frame);
    }
}

// ---- mpv ------------------------------------------------------------------------

fn startPlayer(s: *Surface) !void {
    const api = if (st.api) |*a| a else return error.LibmpvNotLoaded;
    const h = api.create() orelse return error.MpvCreateFailed;
    errdefer api.terminate_destroy(h);

    var wid_buf: [24]u8 = undefined;
    const wid = try std.fmt.bufPrintSentinel(&wid_buf, "{d}", .{@intFromPtr(s.hwnd)}, 0);
    const own = [_]mpv_options.Option{
        .{ "wid", wid },
        .{ "force-window", "yes" },
        mpv_options.pause(st.playing),
        mpv_options.fill(st.fill),
    };
    for (own ++ mpv_options.common) |o| setOption(api, h, o[0], o[1]);
    // Adjustments that arrived before the player did.
    for (mpv_options.adjustments, 0..) |name, i| if (st.adjust.value(i)) |v| setOption(api, h, name, v);
    _ = api.request_log_messages(h, "warn");
    api.set_wakeup_callback(h, onWakeup, @ptrFromInt(@as(usize, s.id) + 1));

    const rc = api.initialize(h);
    if (rc < 0) {
        st.session.log(.err, "mpv_initialize: {s}", .{std.mem.span(api.error_string(rc))});
        return error.MpvInitFailed;
    }
    applyVolume(h);
    const load = [_]?[*:0]const u8{ "loadfile", st.path.ptr, null };
    if (api.command(h, &load) < 0) return error.MpvLoadFailed;
    s.player = h;
}

fn setOption(api: *const mpv.Api, h: *mpv.Handle, name: [:0]const u8, value: [:0]const u8) void {
    const rc = api.set_option_string(h, name, value);
    if (rc < 0) st.session.log(.warn, "mpv option {s}={s}: {s}", .{ name, value, std.mem.span(api.error_string(rc)) });
}

fn applyVolume(h: *mpv.Handle) void {
    const api = if (st.api) |*a| a else return;
    var buf: [8]u8 = undefined;
    const vol = std.fmt.bufPrintSentinel(&buf, "{d}", .{st.volume}, 0) catch return;
    _ = api.set_property_string(h, "volume", vol);
    _ = api.set_property_string(h, "mute", if (st.muted) "yes" else "no");
}

/// Sets an mpv property on every player (e.g. `pause`).
fn setOnPlayers(name: [:0]const u8, value: [:0]const u8) void {
    const api = if (st.api) |*a| a else return;
    for (st.surfaces) |slot| if (slot) |s| if (s.player) |h| {
        const rc = api.set_property_string(h, name, value);
        if (rc < 0) st.session.log(.warn, "mpv property {s}={s}: {s}", .{ name, value, std.mem.span(api.error_string(rc)) });
    };
}

/// Runs on an mpv thread: just wake our loop up.
fn onWakeup(data: ?*anyopaque) callconv(.c) void {
    const id = @intFromPtr(data) - 1;
    _ = w.PostMessageW(st.control, WM_MPV, id, 0);
}

fn drainEvents(s: *Surface) void {
    const api = if (st.api) |*a| a else return;
    const h = s.player orelse return;
    while (true) {
        const e = api.wait_event(h, 0);
        switch (e.event_id) {
            mpv.event.none => return,
            mpv.event.log_message => {
                const m: *const mpv.LogMessage = @ptrCast(@alignCast(e.data orelse continue)); // zsnag:ok — mpv documents the payload type
                // Before the rate limit: it is the sign a file can't be shown.
                if (!no_media_told and std.mem.startsWith(u8, std.mem.span(m.text), no_media)) {
                    no_media_told = true;
                    fail("cannot show '{s}': no picture or video in it could be decoded", .{st.path});
                }
                if (!allowLogLine()) continue;
                const level: proto.LogLevel = if (std.mem.eql(u8, std.mem.span(m.level), "warn")) .warn else .err;
                st.session.log(level, "mpv {s}: {s}", .{ std.mem.span(m.prefix), std.mem.trimEnd(u8, std.mem.span(m.text), "\r\n") });
            },
            mpv.event.playback_restart => if (!s.started) {
                // Only now has mpv picked a decoder, so this is when hwdec-current is meaningful.
                s.started = true;
                logPlayback(api, h);
                st.session.send(.{ .shown = .{ .surface = s.id } }) catch {}; // zsnag:ok — only lets the old wallpaper go sooner; the daemon has a deadline
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
            mpv.event.video_reconfig => if (mpv.tooLarge(api, h)) |sz|
                fail("cannot show '{s}': at {d}x{d} it is larger than a wallpaper can be (50 megapixels at most)", .{ st.path, sz[0], sz[1] }),
            mpv.event.shutdown => return,
            else => {},
        }
    }
}

/// What mpv says, again and again, about a file with nothing it can decode:
/// it never ends the file (every wallpaper loops), so this is the sign.
const no_media = "No media data to loop";
/// Said once: the daemon replaces this renderer.
var no_media_told = false;

/// Rate limit for forwarded mpv log lines; reports how many were dropped.
fn allowLogLine() bool {
    const now = w.GetTickCount64();
    if (now -| st.log_window_start >= 1000) {
        if (st.log_suppressed > 0) st.session.log(.warn, "(suppressed {d} more mpv messages)", .{st.log_suppressed});
        st.log_window_start = now;
        st.log_lines = 0;
        st.log_suppressed = 0;
    }
    if (st.log_lines >= log_lines_per_second) {
        st.log_suppressed += 1;
        return false;
    }
    st.log_lines += 1;
    return true;
}

/// One line per loaded file: what's playing and how it's decoded.
fn logPlayback(api: *const mpv.Api, h: *mpv.Handle) void {
    var props: [4][]const u8 = .{ "?", "?", "?", "?" };
    var raw: [4]?[*:0]u8 = @splat(null);
    defer for (raw) |r| api.free(r);
    for ([_][*:0]const u8{ "width", "height", "hwdec-current", "container-fps" }, 0..) |name, i| {
        raw[i] = api.get_property_string(h, name);
        if (raw[i]) |r| props[i] = std.mem.span(r);
    }
    st.session.log(.info, "playing {s}x{s} @ {s} fps, hwdec={s}", .{ props[0], props[1], props[3], props[2] });
}

/// A teardown is identified by its slot, not its surface id: surface ids are
/// reused at once, and a finished teardown must only ever release its own
/// slot and window (never one whose mpv is still shutting down).
const Teardown = struct { handle: *mpv.Handle, slot: usize };

fn teardownAsync(h: *mpv.Handle, slot: usize) void {
    const job = st.gpa.create(Teardown) catch {
        // No memory for a thread argument: leak the player rather than risk a deadlock.
        _ = w.PostMessageW(st.control, WM_PLAYER_GONE, slot, 0);
        return;
    };
    job.* = .{ .handle = h, .slot = slot };
    const thread = w.CreateThread(null, 0, teardownMain, job, 0, null) orelse {
        st.gpa.destroy(job);
        _ = w.PostMessageW(st.control, WM_PLAYER_GONE, slot, 0);
        return;
    };
    _ = w.CloseHandle(thread);
}

fn teardownMain(param: ?*anyopaque) callconv(.winapi) w.DWORD {
    const job: *Teardown = @ptrCast(@alignCast(param orelse return 1)); // zsnag:ok — we allocated it as *Teardown
    const t = job.*;
    st.gpa.destroy(job);
    st.api.?.terminate_destroy(t.handle);
    _ = w.PostMessageW(st.control, WM_PLAYER_GONE, t.slot, 0);
    return 0;
}

fn slotIndex(slot: *const ?Surface) usize {
    return (@intFromPtr(slot) - @intFromPtr(&st.surfaces)) / @sizeOf(?Surface);
}

fn findSurface(id: usize) ?*Surface {
    for (&st.surfaces) |*slot| {
        if (slot.*) |*s| if (s.id == id and !s.closing) return s;
    }
    return null;
}

// ---- window procedures -------------------------------------------------------------

fn controlProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        WM_DAEMON => {
            // The daemon's end closed: a renderer never outlives its daemon.
            const in = switch (pipe.Notice.fromLparam(lp)) {
                .frame => |f| f,
                .ended => {
                    w.PostQuitMessage(0);
                    return 0;
                },
                .connected => return 0,
            };
            defer in.destroy();
            const cmd = in.frame().decode(proto.ToRenderer) catch |err| {
                st.session.log(.warn, "unreadable command (opcode {d}): {s}", .{ in.opcode, @errorName(err) });
                return 0;
            };
            handle(cmd);
            return 0;
        },
        WM_MPV => {
            if (findSurface(wp)) |s| drainEvents(s);
            return 0;
        },
        WM_PLAYER_GONE => {
            if (wp >= st.surfaces.len) return 0;
            const slot = &st.surfaces[wp];
            const s = slot.* orelse return 0;
            if (!s.closing) return 0;
            slot.* = null;
            if (w.IsWindow(s.hwnd) != 0) _ = w.DestroyWindow(s.hwnd);
            return 0;
        },
        w.WM_TIMER => {
            st.frame +%= 1;
            for (st.surfaces) |slot| if (slot) |s| {
                _ = w.InvalidateRect(s.hwnd, null, 0);
            };
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn surfaceProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_ERASEBKGND => return 1,
        w.WM_PAINT => {
            var ps: w.PAINTSTRUCT = undefined;
            const hdc = w.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w.EndPaint(hwnd, &ps);
            // With mpv, its child window covers ours and draws everything.
            if (!usesMpv()) {
                var client: w.RECT = undefined;
                _ = w.GetClientRect(hwnd, &client);
                testpattern.paint(hdc, client, st.frame);
            }
            return 0;
        },
        w.WM_DESTROY => {
            // Destroyed from outside too (Explorer restarting takes its children
            // with it). Release mpv off-thread; the daemon will add the surface again.
            for (&st.surfaces) |*slot| {
                const s = if (slot.*) |*s| s else continue;
                if (s.hwnd != hwnd) continue;
                if (s.player) |h| {
                    s.player = null;
                    s.closing = true;
                    teardownAsync(h, slotIndex(slot));
                } else if (!s.closing) {
                    slot.* = null;
                }
            }
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
}
