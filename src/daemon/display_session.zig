// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! One display connection on the daemon side (Linux), speaking
//! waywallen-display-v1 v9 (`protocol/ww_display.zig`): the handshake, the
//! display's facts, its buffer pool and the release sync of every frame.
//! Routing (which renderer feeds it) stays in `runtime_linux.zig`.
//!
//! Frames: each `frame_ready` carries an acquire sync_file and one of this
//! display's release syncobjs (one per slot, reset before reuse). When the
//! consumer reports `frame_release_armed`, the syncobj's fence is exported
//! as a sync_file and polled (`waiting`); once it's readable the slot goes
//! back to the renderer.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const ww = zmural.protocol.ww_display;
const syncobj = zmural.os.syncobj;
const monitor = zmural.monitor;
const policy = zmural.policy;

const log = std.log.scoped(.display);

pub const max_slots = 4;
pub const max_modifiers = 64;
const xrgb8888: u32 = 0x34325258;
/// The one window-observation config zmural sends (no exclusions yet).
const observation_generation: u64 = 0;

pub const State = enum { hello, welcomed, registered };

/// What a frame from the display meant, for the runtime.
pub const Happening = union(enum) {
    none,
    /// Registered: it can be routed now.
    registered,
    /// Its size changed: the renderer surface must be rebuilt.
    resized,
    window_state,
    /// A slot's release fence is now being polled (`waiting`).
    armed,
};

pub const Session = struct {
    stream: ww.Stream,
    id: u16,
    state: State = .hello,
    /// The consumer declared window observation: it expects the config event.
    observation: bool = false,

    // Facts from registration.
    monitor: monitor.Id = undefined,
    name: [64]u8 = undefined,
    name_len: usize = 0,
    metrics: ww.Metrics = .{ .width = 0, .height = 0 },
    device: u64 = 0,
    /// Single-plane XRGB8888 modifiers, as little-endian bytes (renderer protocol).
    modifiers: [max_modifiers * 8]u8 = undefined,
    modifiers_len: usize = 0,
    conditions: policy.Conditions = .empty,

    // The bound pool.
    generation: u64 = 0,
    /// The renderer's generation for the same pool (for `release`).
    renderer_generation: u32 = 0,
    slots: u8 = 0,
    composition_generation: u64 = 0,
    seq: u64 = 0,
    releases: [max_slots]?syncobj.SyncObj = @splat(null),
    slot_seq: [max_slots]u64 = @splat(0),
    /// Per slot: the exported release fence being polled, or -1.
    waiting: [max_slots]linux.fd_t = @splat(-1),
    /// Slots whose release came without a fence to poll (already done).
    done_without_fence: [max_slots]bool = @splat(false),

    pub fn connector(s: *const Session) []const u8 {
        return s.name[0..s.name_len];
    }

    pub fn close(s: *Session) void {
        s.dropPool();
        s.stream.close();
    }

    fn send(s: *Session, bytes: []const u8, fds: []const linux.fd_t) void {
        s.stream.send(bytes, fds) catch |err| {
            log.warn("display {d}: send failed ({s}); dropping it", .{ s.id, @errorName(err) });
            // Seen as a hang-up on the next poll.
            _ = linux.shutdown(s.stream.fd, linux.SHUT.RDWR);
        };
    }

    fn refuse(s: *Session, code: ww.ErrorCode, message: []const u8) error{Refused} {
        var buf: [512]u8 = undefined;
        if (ww.encodeError(&buf, code, message)) |f| s.send(f, &.{}) else |_| {}
        log.warn("display {d}: {s}", .{ s.id, message });
        return error.Refused;
    }

    /// Handles one frame from the consumer.
    pub fn handle(s: *Session, opcode: u16, body: []const u8) !Happening {
        var buf: [256]u8 = undefined;
        const op: ww.Request = @fromBackingInt(@intCast(opcode));
        switch (s.state) {
            .hello => {
                if (op != .hello) return s.refuse(.protocol_violation, "hello must be the first request");
                const h = ww.decodeHello(body) catch return s.refuse(.version_unsupported, "undecodable hello; zmural accepts protocol v9 only");
                if (h.protocol_version != ww.version) return s.refuse(.version_unsupported, "zmural accepts protocol v9 only");
                log.info("display {d}: {s} {s}", .{ s.id, h.client_name, h.client_version });
                s.send(try ww.encodeWelcome(&buf, "zmural " ++ zmural.version), &.{});
                s.state = .welcomed;
                return .none;
            },
            .welcomed => switch (op) {
                .client_capabilities => {
                    s.observation = ww.declaresWindowObservation(body);
                    return .none;
                },
                .register_display => return s.register(body),
                else => return s.refuse(.protocol_violation, "register_display must follow welcome"),
            },
            .registered => {},
        }
        switch (op) {
            .set_display_metrics => {
                const m = ww.decodeMetrics(body) catch return s.refuse(.protocol_violation, "bad set_display_metrics");
                const resized = m.width != s.metrics.width or m.height != s.metrics.height;
                s.metrics = m;
                return if (resized) .resized else .none;
            },
            .set_window_state => {
                s.setWindowFlags(ww.decodeU32(body) catch return s.refuse(.protocol_violation, "bad set_window_state"));
                return .window_state;
            },
            .frame_release_armed => {
                const a = ww.decodeReleaseArmed(body) catch return s.refuse(.protocol_violation, "bad frame_release_armed");
                return if (s.arm(a)) .armed else .none;
            },
            .buffer_import_failed => {
                const f = ww.decodeImportFailed(body) catch return s.refuse(.protocol_violation, "bad buffer_import_failed");
                log.err("display {d}: can't import generation {d} ({s}): {s}", .{ s.id, f.buffer_generation, @tagName(f.kind), f.message });
                return .none;
            },
            // What a client sends in place of `set_window_state` once it has our
            // observation config (the KDE plugin does): the same flags.
            .set_window_observation_state => {
                const o = ww.decodeWindowObservationState(body) catch return s.refuse(.protocol_violation, "bad set_window_observation_state");
                // A report made against a config we have since replaced.
                if (o.config_generation != observation_generation) return .none;
                s.setWindowFlags(o.flags);
                return .window_state;
            },
            // Teardown confirmations need no action; pointer input is ignored
            // until wallpapers take input (M7).
            .ack_unbind, .pointer_motion, .pointer_button, .pointer_axis => return .none,
            .hello, .register_display, .client_capabilities => return s.refuse(.protocol_violation, "handshake request after registration"),
            _ => return s.refuse(.protocol_violation, "unknown request"),
        }
    }

    fn register(s: *Session, body: []const u8) !Happening {
        var buf: [256]u8 = undefined;
        const reg = ww.decodeRegister(body) catch return s.refuse(.protocol_violation, "bad register_display");
        s.name_len = @min(reg.name.len, s.name.len);
        @memcpy(s.name[0..s.name_len], reg.name[0..s.name_len]);
        // zmural's own hosts send the canonical ID; others (KDE, GNOME) send
        // their own stable key, which is hashed into one.
        const key = if (reg.instance_id.len > 0) reg.instance_id else reg.name;
        if (key.len == s.monitor.len and std.mem.startsWith(u8, key, "m-")) {
            @memcpy(&s.monitor, key);
        } else {
            s.monitor = monitor.fromConnector(key);
        }
        s.metrics = reg.metrics;
        s.device = reg.caps.device();
        var mods: [max_modifiers]u64 = undefined;
        const n = reg.caps.singlePlaneModifiers(xrgb8888, &mods);
        for (mods[0..n], 0..) |m, i| std.mem.writeInt(u64, s.modifiers[i * 8 ..][0..8], m, .little);
        s.modifiers_len = n * 8;
        s.setWindowFlags(reg.window_flags);
        s.state = .registered;
        log.info("display {d}: {s} ({s}), {d}x{d}, {d} modifiers", .{ s.id, s.connector(), &s.monitor, s.metrics.width, s.metrics.height, n });
        s.send(try ww.encodeDisplayAccepted(&buf, s.id, .{}), &.{});
        if (s.observation) s.send(try ww.encodeWindowObservationConfig(&buf, observation_generation), &.{});
        return .registered;
    }

    fn setWindowFlags(s: *Session, flags: u32) void {
        var c: policy.Conditions = .empty;
        if (flags & ww.window.has_fullscreen != 0) c.insert(.fullscreen);
        if (flags & ww.window.has_maximized != 0) c.insert(.maximized);
        if (flags & ww.window.has_active != 0) c.insert(.focused);
        if (!std.meta.eql(c, s.conditions))
            log.info("display {d}: windows: fullscreen={} maximized={} focused={}", .{ s.id, c.contains(.fullscreen), c.contains(.maximized), c.contains(.focused) });
        s.conditions = c;
    }

    // ---- buffers --------------------------------------------------------------------

    /// Publishes a renderer's new pool (`fds`: one DMA-BUF per slot).
    pub fn bind(s: *Session, dev: linux.fd_t, renderer_generation: u32, count: u8, width: u32, height: u32, fourcc: u32, modifier: u64, offset: u32, stride: u32, content_token: u64, fds: []const linux.fd_t) !void {
        if (count == 0 or count > max_slots) return error.BadPool;
        s.dropPool();
        s.generation += 1;
        s.renderer_generation = renderer_generation;
        s.slots = count;
        for (0..count) |i| s.releases[i] = try syncobj.SyncObj.create(dev, false);
        s.composition_generation += 1;
        const full_src: ww.Rect = .{ .w = @floatFromInt(width), .h = @floatFromInt(height) };
        const full_dst: ww.Rect = .{ .w = @floatFromInt(s.metrics.width), .h = @floatFromInt(s.metrics.height) };
        var buf: [1024]u8 = undefined;
        const msg = try ww.encodeBindBuffers(&buf, .{
            .buffer_generation = s.generation,
            .count = count,
            .width = width,
            .height = height,
            .fourcc = fourcc,
            .modifier = modifier,
            .stride = stride,
            .offset = offset,
            .size = @as(u64, stride) * height,
            .initial_config = .{
                .generation = s.composition_generation,
                .buffer_generation = s.generation,
                .source_rect = full_src,
                .dest_rect = full_dst,
            },
            .content_token = if (content_token == 0) 1 else content_token,
            .presentation_config_generation = 1,
        });
        s.send(msg, fds);
    }

    /// Announces a rendered slot. `acquire` is the renderer's fence
    /// (sync_file), or -1 when its GPU work is already complete.
    pub fn frame(s: *Session, dev: linux.fd_t, slot: u8, acquire: linux.fd_t) !void {
        if (slot >= s.slots) return error.BadSlot;
        const release = if (s.releases[slot]) |*r| r else return error.BadSlot;
        try release.reset();
        const acq = if (acquire >= 0) acquire else try syncobj.signaledSyncFile(dev);
        defer if (acquire < 0) {
            _ = linux.close(acq);
        };
        s.seq += 1;
        s.slot_seq[slot] = s.seq;
        var buf: [64]u8 = undefined;
        s.send(try ww.encodeFrameReady(&buf, .{ .buffer_generation = s.generation, .buffer_index = slot, .seq = s.seq }), &.{ acq, release.fd });
    }

    /// The consumer armed a release: poll its fence. False if it names a
    /// frame we don't know (a stale pool).
    fn arm(s: *Session, a: ww.ReleaseArmed) bool {
        if (a.buffer_generation != s.generation) return false;
        const slot = for (s.slot_seq[0..s.slots], 0..) |q, i| {
            if (q == a.seq) break i;
        } else return false;
        const release = s.releases[slot] orelse return false;
        if (s.waiting[slot] >= 0) _ = linux.close(s.waiting[slot]);
        s.waiting[slot] = release.exportSyncFile() catch |err| {
            log.warn("display {d}: release for slot {d} has no fence ({s}); taking it as done", .{ s.id, slot, @errorName(err) });
            s.waiting[slot] = -1;
            s.done_without_fence[slot] = true;
            return true;
        };
        return true;
    }

    /// Call when `waiting[slot]` polls readable (or is marked done): frees
    /// the slot for the renderer.
    pub fn released(s: *Session, slot: usize) void {
        if (s.waiting[slot] >= 0) _ = linux.close(s.waiting[slot]);
        s.waiting[slot] = -1;
        s.done_without_fence[slot] = false;
    }

    /// Retires the pool (the renderer went away).
    pub fn unbind(s: *Session) void {
        if (s.slots == 0) return;
        var buf: [64]u8 = undefined;
        if (ww.encodeU64(&buf, @backingInt(ww.Event.unbind), s.generation)) |f| s.send(f, &.{}) else |_| {}
        s.dropPool();
    }

    fn dropPool(s: *Session) void {
        for (&s.releases, &s.waiting) |*r, *w| {
            if (r.*) |*o| o.destroy();
            r.* = null;
            if (w.* >= 0) _ = linux.close(w.*);
            w.* = -1;
        }
        s.done_without_fence = @splat(false);
        s.slot_seq = @splat(0);
        s.slots = 0;
    }
};

test "window flags reach the pause conditions by either request (the KDE plugin uses the observation one)" {
    var sv: [2]i32 = undefined;
    try std.testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv)) == .SUCCESS);
    var peer: ww.Stream = .{ .fd = sv[1] };
    defer peer.close();
    var s: Session = .{ .stream = .{ .fd = sv[0] }, .id = 1, .state = .registered };
    defer s.close();

    var buf: [96]u8 = undefined;
    const fullscreen = try ww.encodeWindowObservationState(&buf, .{ .config_generation = observation_generation, .flags = ww.window.has_fullscreen });
    try std.testing.expectEqual(Happening.window_state, try s.handle(@backingInt(ww.Request.set_window_observation_state), fullscreen[ww.header_len..]));
    try std.testing.expect(s.conditions.contains(.fullscreen));
    try std.testing.expect(!s.conditions.contains(.maximized));

    // A report against another config generation changes nothing.
    const stale = try ww.encodeWindowObservationState(&buf, .{ .config_generation = observation_generation + 1, .flags = 0 });
    try std.testing.expectEqual(Happening.none, try s.handle(@backingInt(ww.Request.set_window_observation_state), stale[ww.header_len..]));
    try std.testing.expect(s.conditions.contains(.fullscreen));

    const cleared = try ww.encodeWindowObservationState(&buf, .{ .config_generation = observation_generation, .flags = ww.window.has_maximized });
    _ = try s.handle(@backingInt(ww.Request.set_window_observation_state), cleared[ww.header_len..]);
    try std.testing.expect(!s.conditions.contains(.fullscreen));
    try std.testing.expect(s.conditions.contains(.maximized));

    // The plain request still works (clients without observation).
    var plain: [4]u8 = undefined;
    std.mem.writeInt(u32, &plain, ww.window.has_fullscreen, .little);
    _ = try s.handle(@backingInt(ww.Request.set_window_state), &plain);
    try std.testing.expect(s.conditions.contains(.fullscreen));

    try std.testing.expectError(error.Refused, s.handle(@backingInt(ww.Request.set_window_observation_state), plain[0..2]));
}
