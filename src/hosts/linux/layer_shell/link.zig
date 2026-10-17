// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The daemon side of the layer-shell host (`zmural --layer-shell`): one connection to zmural's
//! display socket per output, speaking waywallen-display-v1 v9
//! (`protocol/ww_display.zig`), the same protocol the KDE and GNOME clients
//! speak.
//!
//! The host is passive. It registers each output (monitor ID, size, what the
//! compositor imports, which windows are up), then shows whatever buffers
//! and frames the daemon sends. Each frame comes with an acquire fence
//! (shown once it signals) and a release syncobj, which the host signals
//! when the compositor lets go of the buffer. When the daemon goes away the
//! outputs keep their background colour, and the host reconnects with a
//! growing delay until it's back.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const unix = zmural.protocol.unix;
const ww = zmural.protocol.ww_display;
const syncobj = zmural.os.syncobj;
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const Output = host_mod.Output;
const p = @import("protocols.zig");

const log = std.log.scoped(.link);

const first_retry_ms = 250;
const max_retry_ms = 5_000;
const max_slots = host_mod.max_slots;

pub const Link = struct {
    output: *Output,
    stream: ?ww.Stream = null,
    registered: bool = false,
    /// The pool on screen (0: none).
    generation: u64 = 0,
    /// Per slot: the release syncobj of its latest frame, and that frame's seq.
    release_fd: [max_slots]linux.fd_t = @splat(-1),
    seq: [max_slots]u64 = @splat(0),
    /// A frame whose acquire fence hasn't signaled yet (shown when it does).
    pending_acquire: linux.fd_t = -1,
    pending_slot: u8 = 0,
    retry_ms: i64 = first_retry_ms,
    retry_at: i64 = 0,

    fn closeReleases(l: *Link) void {
        for (&l.release_fd) |*fd| {
            if (fd.* >= 0) _ = linux.close(fd.*);
            fd.* = -1;
        }
        if (l.pending_acquire >= 0) _ = linux.close(l.pending_acquire);
        l.pending_acquire = -1;
    }
};

pub const Links = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    host: *Host,
    socket_path: []const u8,
    /// A render node for signalling release syncobjs.
    drm: linux.fd_t,
    list: std.ArrayList(*Link) = .empty,

    pub fn deinit(ls: *Links) void {
        for (ls.list.items) |l| {
            l.closeReleases();
            if (l.stream) |*s| s.close();
            ls.gpa.destroy(l);
        }
        ls.list.deinit(ls.gpa);
        _ = linux.close(ls.drm);
    }

    pub fn listener(ls: *Links) host_mod.Listener {
        return .{ .ctx = ls, .output_ready = onReady, .output_gone = onGone, .released = onReleased, .window_state = onWindowState };
    }

    fn onReady(ctx: *anyopaque, o: *Output) void {
        const ls: *Links = @ptrCast(@alignCast(ctx)); // zsnag:ok — set from a *Links in `listener`
        const l = ls.gpa.create(Link) catch return;
        l.* = .{ .output = o };
        ls.list.append(ls.gpa, l) catch {
            ls.gpa.destroy(l);
            return;
        };
        ls.connect(l);
    }

    fn onGone(ctx: *anyopaque, o: *Output) void {
        const ls: *Links = @ptrCast(@alignCast(ctx)); // zsnag:ok — set from a *Links in `listener`
        for (ls.list.items, 0..) |l, i| if (l.output == o) {
            l.closeReleases();
            if (l.stream) |*s| s.close();
            ls.gpa.destroy(l);
            _ = ls.list.swapRemove(i);
            return;
        };
    }

    /// The compositor let go of a slot's buffer (or a queued frame was
    /// replaced before it showed): signal its release syncobj and say so.
    fn onReleased(ctx: *anyopaque, o: *Output, slot: u8) void {
        const ls: *Links = @ptrCast(@alignCast(ctx)); // zsnag:ok — set from a *Links in `listener`
        const l = ls.find(o) orelse return;
        ls.release(l, slot);
    }

    fn release(ls: *Links, l: *Link, slot: u8) void {
        if (slot >= max_slots or l.release_fd[slot] < 0) return;
        const fd = l.release_fd[slot];
        l.release_fd[slot] = -1;
        signalRelease(ls.drm, fd);
        var buf: [64]u8 = undefined;
        const f = ww.encodeReleaseArmed(&buf, .{ .buffer_generation = l.generation, .seq = l.seq[slot] }) catch return;
        ls.send(l, f, &.{});
    }

    fn onWindowState(ctx: *anyopaque, o: *Output, ws: host_mod.WindowState) void {
        const ls: *Links = @ptrCast(@alignCast(ctx)); // zsnag:ok — set from a *Links in `listener`
        const l = ls.find(o) orelse return;
        if (!l.registered) return;
        var buf: [16]u8 = undefined;
        const f = ww.encodeU32(&buf, @backingInt(ww.Request.set_window_state), windowFlags(ws)) catch return;
        ls.send(l, f, &.{});
    }

    fn find(ls: *Links, o: *Output) ?*Link {
        for (ls.list.items) |l| if (l.output == o) return l;
        return null;
    }

    fn connect(ls: *Links, l: *Link) void {
        var c = unix.connectKind(ls.socket_path, .stream) catch |err| {
            if (l.retry_ms == first_retry_ms) log.info("{s}: daemon not reachable ({s}); retrying", .{ l.output.connector(), @errorName(err) });
            l.retry_at = now() + l.retry_ms;
            l.retry_ms = @min(l.retry_ms * 2, max_retry_ms);
            return;
        };
        c.setSendTimeout(2000) catch |err| log.warn("send timeout not set: {s}", .{@errorName(err)});
        l.stream = .{ .fd = c.fd };
        l.registered = false;
        l.retry_ms = first_retry_ms;
        var buf: [128]u8 = undefined;
        const f = ww.encodeHello(&buf, .{ .client_name = "zmural-layer-shell", .client_version = zmural.version, .protocol_version = ww.version }) catch return;
        ls.send(l, f, &.{});
    }

    fn register(ls: *Links, l: *Link) void {
        const o = l.output;
        const fb = &ls.host.feedback;
        const dev = fb.device;
        const major: u32 = @truncate(((dev >> 32) & 0xfffff000) | ((dev >> 8) & 0xfff));
        const minor: u32 = @truncate(((dev >> 12) & 0xffffff00) | (dev & 0xff));
        const id = host_mod.monitorId(ls.io, o.connector());
        var buf: [2048]u8 = undefined;
        const f = ww.encodeRegister(&buf, o.connector(), &id, .{ .width = o.width, .height = o.height, .refresh_mhz = o.refresh_mhz }, p.fourcc.xrgb8888, fb.modifiers[0..fb.count], major, minor, windowFlags(o.window_state)) catch |err| {
            log.err("{s}: can't encode registration: {s}", .{ o.connector(), @errorName(err) });
            return;
        };
        ls.send(l, f, &.{});
        l.registered = true;
    }

    fn send(ls: *Links, l: *Link, frame: []const u8, fds: []const linux.fd_t) void {
        var s = &(l.stream orelse return);
        s.send(frame, fds) catch |err| {
            log.warn("{s}: daemon link lost ({s})", .{ l.output.connector(), @errorName(err) });
            ls.disconnect(l);
        };
    }

    fn disconnect(ls: *Links, l: *Link) void {
        if (l.stream) |*s| s.close();
        l.stream = null;
        l.registered = false;
        l.generation = 0;
        l.closeReleases();
        ls.host.dropBuffers(l.output) catch {}; // zsnag:ok — the Wayland side reports its own failures on the next flush
        l.retry_at = now() + l.retry_ms;
    }

    /// Adds every daemon connection and pending acquire fence to `fds`.
    pub fn pollFds(ls: *Links, fds: []linux.pollfd) usize {
        var n: usize = 0;
        for (ls.list.items) |l| {
            if (l.stream) |s| if (n < fds.len) {
                fds[n] = .{ .fd = s.fd, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            };
            if (l.pending_acquire >= 0 and n < fds.len) {
                fds[n] = .{ .fd = l.pending_acquire, .events = linux.POLL.IN, .revents = 0 };
                n += 1;
            }
        }
        return n;
    }

    /// How long poll may sleep before a reconnect is due (-1: forever).
    pub fn timeoutMs(ls: *Links) i32 {
        var soonest: ?i64 = null;
        for (ls.list.items) |l| if (l.stream == null) {
            soonest = if (soonest) |s| @min(s, l.retry_at) else l.retry_at;
        };
        const at = soonest orelse return -1;
        return @intCast(std.math.clamp(at - now(), 0, max_retry_ms));
    }

    /// Reconnects links whose retry time has come.
    pub fn tick(ls: *Links) void {
        const t = now();
        for (ls.list.items) |l| if (l.stream == null and t >= l.retry_at) ls.connect(l);
    }

    /// `fd` polled readable: a daemon connection or an acquire fence.
    pub fn readable(ls: *Links, fd: linux.fd_t) !void {
        for (ls.list.items) |l| {
            if (l.pending_acquire == fd) {
                _ = linux.close(fd);
                l.pending_acquire = -1;
                ls.host.frameReady(l.output, l.pending_slot) catch |err|
                    log.warn("{s}: frame for slot {d}: {s}", .{ l.output.connector(), l.pending_slot, @errorName(err) });
                return;
            }
            const s = &(l.stream orelse continue);
            if (s.fd != fd) continue;
            s.fill() catch |err| {
                log.info("{s}: daemon link closed ({s})", .{ l.output.connector(), @errorName(err) });
                ls.disconnect(l);
                return;
            };
            while (l.stream != null) {
                const f = (l.stream.?.next(ww.eventFds) catch |err| {
                    log.warn("{s}: bad frame from the daemon: {s}", .{ l.output.connector(), @errorName(err) });
                    ls.disconnect(l);
                    return;
                }) orelse break;
                const fds = l.stream.?.takeFds();
                ls.handle(l, f.opcode, f.body, fds) catch |err| {
                    log.warn("{s}: unreadable event {d}: {s}", .{ l.output.connector(), f.opcode, @errorName(err) });
                    ls.disconnect(l);
                    return;
                };
            }
            return;
        }
    }

    /// Handles one event. Owns `fds`: every one is closed or kept.
    fn handle(ls: *Links, l: *Link, opcode: u16, body: []const u8, fds: []const linux.fd_t) !void {
        const o = l.output;
        var kept: usize = 0; // fds[0..kept] have been taken over
        defer for (fds[kept..]) |fd| {
            _ = linux.close(fd);
        };
        switch (@as(ww.Event, @fromBackingInt(@intCast(opcode)))) {
            .welcome => {
                log.info("{s}: connected to {s}", .{ o.connector(), ww.decodeWelcome(body) catch "?" });
                ls.register(l);
            },
            .display_accepted => log.info("{s}: registered as display {d}", .{ o.connector(), ww.decodeDisplayId(body) catch 0 }),
            .bind_buffers => {
                const b, const planes = try ww.decodeBindBuffers(body);
                var buf: [256]u8 = undefined;
                if (planes != 1 or b.count == 0 or b.count > max_slots or fds.len != b.count) {
                    log.warn("{s}: pool of {d}x{d} planes with {d} fds; not importable here", .{ o.connector(), b.count, planes, fds.len });
                    ls.send(l, try ww.encodeImportFailed(&buf, .{ .buffer_generation = b.buffer_generation, .kind = .unsupported, .message = "zmural-layer-shell imports single-plane pools of up to 4 buffers" }), &.{});
                    return;
                }
                l.closeReleases();
                var ids: [max_slots]u32 = undefined;
                for (fds, 0..) |fd, i| {
                    ids[i] = ls.host.addDmabuf(fd, b.width, b.height, b.fourcc, b.modifier, b.offset, b.stride) catch |err| {
                        log.err("{s}: can't import buffer: {s}", .{ o.connector(), @errorName(err) });
                        ls.send(l, try ww.encodeImportFailed(&buf, .{ .buffer_generation = b.buffer_generation, .kind = .backend_failure, .message = @errorName(err) }), &.{});
                        return;
                    };
                }
                try ls.host.setBuffers(o, b.width, b.height, ids[0..b.count]);
                l.generation = b.buffer_generation;
                try ls.host.setComposition(o, composition(b.initial_config));
                log.info("{s}: {d} buffers, {d}x{d}, modifier 0x{x}", .{ o.connector(), b.count, b.width, b.height, b.modifier });
            },
            .set_composition_config => {
                const c = try ww.decodeComposition(body);
                if (c.buffer_generation == l.generation) try ls.host.setComposition(o, composition(c));
            },
            .frame_ready => {
                const fr = try ww.decodeFrameReady(body);
                if (fds.len != 2) return error.BadMessage;
                const acquire = fds[0];
                const release_fd = fds[1];
                kept = 2;
                if (fr.buffer_generation != l.generation or fr.buffer_index >= max_slots) {
                    // A frame for a pool we no longer have: release it at once.
                    _ = linux.close(acquire);
                    signalRelease(ls.drm, release_fd);
                    var buf: [64]u8 = undefined;
                    ls.send(l, try ww.encodeReleaseArmed(&buf, .{ .buffer_generation = fr.buffer_generation, .seq = fr.seq }), &.{});
                    return;
                }
                const slot: u8 = @intCast(fr.buffer_index);
                if (l.release_fd[slot] >= 0) _ = linux.close(l.release_fd[slot]);
                l.release_fd[slot] = release_fd;
                l.seq[slot] = fr.seq;
                // A frame still waiting on its fence is superseded: release it.
                if (l.pending_acquire >= 0) {
                    _ = linux.close(l.pending_acquire);
                    l.pending_acquire = -1;
                    if (l.pending_slot != slot) ls.release(l, l.pending_slot);
                }
                if (syncobj.isSignaled(acquire)) {
                    _ = linux.close(acquire);
                    ls.host.frameReady(o, slot) catch |err|
                        log.warn("{s}: frame for slot {d}: {s}", .{ o.connector(), slot, @errorName(err) });
                } else {
                    l.pending_acquire = acquire;
                    l.pending_slot = slot;
                }
            },
            .unbind => {
                const gen = try ww.decodeU64(body);
                if (gen == l.generation) {
                    try ls.host.dropBuffers(o);
                    l.closeReleases();
                    l.generation = 0;
                }
                var buf: [16]u8 = undefined;
                ls.send(l, try ww.encodeU64(&buf, @backingInt(ww.Request.ack_unbind), gen), &.{});
            },
            .@"error" => {
                var r: ww.Reader = .{ .body = body };
                const code = r.u32_() catch 0;
                log.err("{s}: daemon refused us ({d}): {s}", .{ o.connector(), code, r.string() catch "?" });
            },
            // Pause blur and transitions are not offered (no capabilities
            // declared), so these carry nothing to act on yet.
            .set_presentation_snapshot, .set_presentation_state, .set_window_observation_config => {},
            _ => {},
        }
    }
};

/// Signals a release syncobj (given as its fd, which this closes).
fn signalRelease(drm: linux.fd_t, fd: linux.fd_t) void {
    var so = syncobj.SyncObj.import(drm, fd) catch |err| {
        log.warn("release syncobj unusable: {s}", .{@errorName(err)});
        _ = linux.close(fd);
        return;
    };
    so.signal() catch |err| log.warn("can't signal release: {s}", .{@errorName(err)});
    so.destroy(); // closes fd too
}

fn windowFlags(ws: host_mod.WindowState) u32 {
    var f: u32 = 0;
    if (ws.fullscreen) f |= ww.window.has_fullscreen;
    if (ws.maximized) f |= ww.window.has_maximized;
    if (ws.focused) f |= ww.window.has_active;
    return f;
}

/// A composition from the protocol, in output pixels.
fn composition(c: ww.CompositionConfig) host_mod.Composition {
    const r = c.clear_color;
    return .{
        .src = rect(c.source_rect),
        .dst = rect(c.dest_rect),
        .clear_rgba = (to8(r.r) << 24) | (to8(r.g) << 16) | (to8(r.b) << 8) | to8(r.a),
    };
}

fn to8(v: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn rect(r: ww.Rect) zmural.layout.Rect {
    return .{
        .x = @intFromFloat(std.math.clamp(@round(r.x), -1e6, 1e6)),
        .y = @intFromFloat(std.math.clamp(@round(r.y), -1e6, 1e6)),
        .w = @intFromFloat(std.math.clamp(@round(r.w), 0, 1e6)),
        .h = @intFromFloat(std.math.clamp(@round(r.h), 0, 1e6)),
    };
}

fn now() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}
