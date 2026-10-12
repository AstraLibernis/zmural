// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! waywallen-display-v1, protocol version 9: the Linux display protocol.
//!
//! zmural speaks the protocol of the waywallen project
//! (github.com/waywallen/waywallen, `protocol/waywallen_display_v1.xml`,
//! MIT, Copyright (c) 2026 hypengw), so the KDE Plasma plugin and GNOME
//! Shell extension from waywallen-display work against zmural (see
//! `third_party/waywallen-display`). This file is an independent Zig
//! implementation of that wire format; it is checked byte for byte against
//! waywallen's generated C codec (`tools/ww-codec-check`).
//!
//! Wire format:
//! - a frame is `[u16 opcode][u16 total length]`, little-endian, then the body
//! - the socket is SOCK_STREAM; fds ride SCM_RIGHTS with a frame's first bytes
//! - bodies are positional: u32/i32/bool/enum/f32 are 4 bytes, u64 is 8;
//!   a string is a u32 length (with its NUL), the bytes, a NUL, then zero
//!   padding to 4; an array is a u32 count then its elements; a rect is four
//!   f32 (x, y, w, h)
//! - `encoding="tagged"` bodies (revision 1): u32 revision, u32 payload bytes,
//!   then fields of u32 tag, u32 wire type, u32 value bytes, value
//!
//! Only what zmural needs is here: the server (zmural) decodes requests and
//! encodes events; the layer-shell host (a client) does the reverse.

const std = @import("std");
const linux = std.os.linux;

pub const version: u32 = 9;
pub const header_len = 4;
pub const max_frame = std.math.maxInt(u16);
pub const max_body = max_frame - header_len;
/// Fds any one frame may carry (a pool: slots x planes).
pub const max_fds = 64;

pub const Request = enum(u16) {
    hello = 1,
    register_display = 2,
    set_display_metrics = 3,
    // 4, 5 and 6 are reserved.
    buffer_import_failed = 7,
    pointer_motion = 8,
    pointer_button = 9,
    pointer_axis = 10,
    ack_unbind = 11,
    set_window_state = 12,
    frame_release_armed = 13,
    client_capabilities = 14,
    set_window_observation_state = 15,
    _,
};

pub const Event = enum(u16) {
    welcome = 1,
    display_accepted = 2,
    bind_buffers = 3,
    set_composition_config = 4,
    frame_ready = 5,
    unbind = 6,
    @"error" = 7,
    set_presentation_snapshot = 8,
    set_presentation_state = 9,
    set_window_observation_config = 10,
    _,
};

/// `set_window_state` / `register_display.window_state_flags`.
pub const window = struct {
    pub const has_non_minimized: u32 = 1 << 0;
    pub const has_active: u32 = 1 << 1;
    pub const has_maximized: u32 = 1 << 2;
    pub const has_fullscreen: u32 = 1 << 3;
};

/// `consumer_capabilities.sync_caps`.
pub const sync = struct {
    pub const implicit: u32 = 1 << 0;
    pub const syncobj_binary: u32 = 1 << 1;
    pub const syncobj_timeline: u32 = 1 << 2;
};

pub const ErrorCode = enum(u32) { protocol_violation = 1, version_unsupported = 2, negotiation_failed = 3, internal = 4 };
pub const ImportFailure = enum(u32) { unsupported = 0, resource_exhausted = 1, backend_failure = 2, _ };

pub const Rect = struct { x: f32 = 0, y: f32 = 0, w: f32, h: f32 };
pub const Rgba = struct { r: f32 = 0, g: f32 = 0, b: f32 = 0, a: f32 = 1 };
pub const Metrics = struct { width: u32, height: u32, refresh_mhz: u32 = 0 };

pub const CompositionConfig = struct {
    generation: u64,
    buffer_generation: u64,
    source_rect: Rect,
    dest_rect: Rect,
    transform: u32 = 0,
    clear_color: Rgba = .{},
};

/// The presentation defaults zmural publishes: no pause effect, no
/// transition. Every field still carries a valid value: waywallen's client
/// rejects a snapshot whose blur radius is outside 1..64 or whose transition
/// duration is outside 100..10000 ms, even when the effect is off.
pub const Presentation = struct {
    config_generation: u64 = 1,
    state_generation: u64 = 1,
    /// Blur while paused (only for clients that declared the capability).
    blur: bool = false,
    blur_radius: u32 = 30,
    paused: bool = false,
};

pub const Error = error{ Truncated, TrailingBytes, TooLarge, BadString, BadArray };

// ---- writing --------------------------------------------------------------------------

/// Builds one frame in a caller-provided buffer.
pub const Writer = struct {
    buf: []u8,
    len: usize = header_len,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    fn bytes(w: *Writer, b: []const u8) Error!void {
        if (w.len + b.len > w.buf.len or w.len + b.len > max_frame) return error.TooLarge;
        @memcpy(w.buf[w.len..][0..b.len], b);
        w.len += b.len;
    }

    pub fn u32_(w: *Writer, v: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.bytes(&b);
    }

    pub fn u64_(w: *Writer, v: u64) Error!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try w.bytes(&b);
    }

    pub fn f32_(w: *Writer, v: f32) Error!void {
        try w.u32_(@bitCast(v));
    }

    pub fn boolean(w: *Writer, v: bool) Error!void {
        try w.u32_(@intFromBool(v));
    }

    fn pad4(w: *Writer) Error!void {
        const zeros = [_]u8{ 0, 0, 0 };
        try w.bytes(zeros[0 .. (4 - (w.len & 3)) & 3]);
    }

    pub fn string(w: *Writer, s: []const u8) Error!void {
        if (std.mem.findScalar(u8, s, 0) != null) return error.BadString;
        try w.u32_(@intCast(s.len + 1));
        try w.bytes(s);
        try w.bytes(&.{0});
        try w.pad4();
    }

    pub fn rect(w: *Writer, r: Rect) Error!void {
        inline for (.{ r.x, r.y, r.w, r.h }) |v| try w.f32_(v);
    }

    pub fn arrayU32(w: *Writer, items: []const u32) Error!void {
        try w.u32_(@intCast(items.len));
        for (items) |v| try w.u32_(v);
    }

    pub fn arrayU64(w: *Writer, items: []const u64) Error!void {
        try w.u32_(@intCast(items.len));
        for (items) |v| try w.u64_(v);
    }

    /// Reserves a u32 to patch later with the byte count written after it
    /// (tagged encoding). Returns its position.
    fn lengthSlot(w: *Writer) Error!usize {
        const at = w.len;
        try w.u32_(0);
        return at;
    }

    fn patchLength(w: *Writer, at: usize) void {
        std.mem.writeInt(u32, w.buf[at..][0..4], @intCast(w.len - at - 4), .little);
    }

    /// Writes the header and returns the finished frame.
    pub fn finish(w: *Writer, opcode: u16) []const u8 {
        std.mem.writeInt(u16, w.buf[0..2], opcode, .little);
        std.mem.writeInt(u16, w.buf[2..4], @intCast(w.len), .little);
        return w.buf[0..w.len];
    }
};

// ---- reading --------------------------------------------------------------------------

pub const Reader = struct {
    body: []const u8,
    pos: usize = 0,

    pub fn u32_(r: *Reader) Error!u32 {
        if (r.body.len - r.pos < 4) return error.Truncated;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.body[r.pos..][0..4], .little);
    }

    pub fn u64_(r: *Reader) Error!u64 {
        if (r.body.len - r.pos < 8) return error.Truncated;
        defer r.pos += 8;
        return std.mem.readInt(u64, r.body[r.pos..][0..8], .little);
    }

    pub fn f32_(r: *Reader) Error!f32 {
        return @bitCast(try r.u32_());
    }

    pub fn boolean(r: *Reader) Error!bool {
        return switch (try r.u32_()) {
            0 => false,
            1 => true,
            else => error.BadString,
        };
    }

    /// Without its NUL; borrows the body.
    pub fn string(r: *Reader) Error![]const u8 {
        const n = try r.u32_();
        if (n == 0) return error.BadString;
        const padded = (@as(usize, n) + 3) & ~@as(usize, 3);
        if (r.body.len - r.pos < padded) return error.Truncated;
        const s = r.body[r.pos..][0..n];
        r.pos += padded;
        if (s[n - 1] != 0) return error.BadString;
        return s[0 .. n - 1];
    }

    pub fn rect(r: *Reader) Error!Rect {
        return .{ .x = try r.f32_(), .y = try r.f32_(), .w = try r.f32_(), .h = try r.f32_() };
    }

    /// A u32 array as its raw little-endian bytes (read items with `item`).
    pub fn arrayU32(r: *Reader) Error![]const u8 {
        return r.array(4);
    }

    pub fn arrayU64(r: *Reader) Error![]const u8 {
        return r.array(8);
    }

    fn array(r: *Reader, size: usize) Error![]const u8 {
        const n = try r.u32_();
        if (n > (r.body.len - r.pos) / size) return error.BadArray;
        defer r.pos += n * size;
        return r.body[r.pos..][0 .. n * size];
    }

    pub fn done(r: *const Reader) Error!void {
        if (r.pos != r.body.len) return error.TrailingBytes;
    }
};

/// Item `i` of an array read with `Reader.arrayU32` / `arrayU64`.
pub fn item(comptime T: type, raw: []const u8, i: usize) T {
    return std.mem.readInt(T, raw[i * @sizeOf(T) ..][0..@sizeOf(T)], .little);
}

pub fn count(comptime T: type, raw: []const u8) usize {
    return raw.len / @sizeOf(T);
}

// ---- requests (client -> zmural) -----------------------------------------------------

pub const Hello = struct { client_name: []const u8, client_version: []const u8, protocol_version: u32 };

pub fn decodeHello(body: []const u8) Error!Hello {
    var r: Reader = .{ .body = body };
    const h: Hello = .{ .client_name = try r.string(), .client_version = try r.string(), .protocol_version = try r.u32_() };
    try r.done();
    return h;
}

pub fn encodeHello(buf: []u8, h: Hello) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.string(h.client_name);
    try w.string(h.client_version);
    try w.u32_(h.protocol_version);
    return w.finish(@intFromEnum(Request.hello));
}

/// Consumer DMA-BUF capabilities, flattened: for fourcc `fourccs[i]`,
/// `mod_counts[i]` consecutive entries of `modifiers` / `plane_counts`.
/// Arrays are raw little-endian bytes (see `item`).
pub const Caps = struct {
    fourccs: []const u8 = "",
    mod_counts: []const u8 = "",
    modifiers: []const u8 = "",
    plane_counts: []const u8 = "",
    device_uuid: []const u8 = "",
    driver_uuid: []const u8 = "",
    drm_render_major: u32 = 0,
    drm_render_minor: u32 = 0,
    mem_hints: u32 = 0,
    sync_caps: u32 = 0,
    color_caps: u32 = 0,
    extent_max_w: u32 = 0,
    extent_max_h: u32 = 0,

    fn read(r: *Reader) Error!Caps {
        return .{
            .fourccs = try r.arrayU32(),
            .mod_counts = try r.arrayU32(),
            .modifiers = try r.arrayU64(),
            .plane_counts = try r.arrayU32(),
            .device_uuid = try r.arrayU32(),
            .driver_uuid = try r.arrayU32(),
            .drm_render_major = try r.u32_(),
            .drm_render_minor = try r.u32_(),
            .mem_hints = try r.u32_(),
            .sync_caps = try r.u32_(),
            .color_caps = try r.u32_(),
            .extent_max_w = try r.u32_(),
            .extent_max_h = try r.u32_(),
        };
    }

    /// The single-plane modifiers offered for `fourcc`, in the consumer's
    /// order, into `out`. Returns how many.
    pub fn singlePlaneModifiers(c: Caps, fourcc: u32, out: []u64) usize {
        var base: usize = 0;
        var n: usize = 0;
        for (0..count(u32, c.fourccs)) |i| {
            const k = item(u32, c.mod_counts, i);
            defer base += k;
            if (item(u32, c.fourccs, i) != fourcc) continue;
            for (base..base + k) |j| {
                if (j >= count(u64, c.modifiers) or j >= count(u32, c.plane_counts)) break;
                if (item(u32, c.plane_counts, j) != 1 or n == out.len) continue;
                out[n] = item(u64, c.modifiers, j);
                n += 1;
            }
        }
        return n;
    }

    /// The render node as a `dev_t` (0 when unknown).
    pub fn device(c: Caps) u64 {
        if (c.drm_render_major == 0 and c.drm_render_minor == 0) return 0;
        const ma: u64 = c.drm_render_major;
        const mi: u64 = c.drm_render_minor;
        return ((ma & 0xfffff000) << 32) | ((ma & 0xfff) << 8) | ((mi & 0xffffff00) << 12) | (mi & 0xff);
    }
};

pub const Register = struct {
    name: []const u8,
    instance_id: []const u8,
    metrics: Metrics,
    caps: Caps,
    presentation_flags: u32,
    window_flags: u32,
};

pub fn decodeRegister(body: []const u8) Error!Register {
    var r: Reader = .{ .body = body };
    const reg: Register = .{
        .name = try r.string(),
        .instance_id = try r.string(),
        .metrics = .{ .width = try r.u32_(), .height = try r.u32_(), .refresh_mhz = try r.u32_() },
        .caps = try Caps.read(&r),
        .presentation_flags = try r.u32_(),
        .window_flags = try r.u32_(),
    };
    try r.done();
    return reg;
}

/// For the layer-shell host. `modifiers` are the consumer's single-plane
/// modifiers for `fourcc`.
pub fn encodeRegister(buf: []u8, name: []const u8, instance_id: []const u8, m: Metrics, fourcc: u32, modifiers: []const u64, render_major: u32, render_minor: u32, window_flags: u32) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.string(name);
    try w.string(instance_id);
    try w.u32_(m.width);
    try w.u32_(m.height);
    try w.u32_(m.refresh_mhz);
    try w.arrayU32(&.{fourcc});
    try w.arrayU32(&.{@intCast(modifiers.len)});
    try w.arrayU64(modifiers);
    try w.u32_(@intCast(modifiers.len));
    for (modifiers) |_| try w.u32_(1);
    try w.arrayU32(&.{ 0, 0, 0, 0 }); // device UUID unknown
    try w.arrayU32(&.{ 0, 0, 0, 0 }); // driver UUID unknown
    try w.u32_(render_major);
    try w.u32_(render_minor);
    try w.u32_(0); // mem_hints
    try w.u32_(sync.syncobj_binary);
    try w.u32_(0); // color_caps
    try w.u32_(16384);
    try w.u32_(16384);
    try w.u32_(0); // presentation_caps: none
    try w.u32_(window_flags);
    return w.finish(@intFromEnum(Request.register_display));
}

pub fn decodeMetrics(body: []const u8) Error!Metrics {
    var r: Reader = .{ .body = body };
    const m: Metrics = .{ .width = try r.u32_(), .height = try r.u32_(), .refresh_mhz = try r.u32_() };
    try r.done();
    return m;
}

pub fn encodeMetrics(buf: []u8, m: Metrics) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u32_(m.width);
    try w.u32_(m.height);
    try w.u32_(m.refresh_mhz);
    return w.finish(@intFromEnum(Request.set_display_metrics));
}

pub const ImportFailed = struct { buffer_generation: u64, kind: ImportFailure, message: []const u8 };

pub fn decodeImportFailed(body: []const u8) Error!ImportFailed {
    var r: Reader = .{ .body = body };
    const f: ImportFailed = .{ .buffer_generation = try r.u64_(), .kind = @enumFromInt(try r.u32_()), .message = try r.string() };
    try r.done();
    return f;
}

pub fn encodeImportFailed(buf: []u8, f: ImportFailed) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u64_(f.buffer_generation);
    try w.u32_(@intFromEnum(f.kind));
    try w.string(f.message);
    return w.finish(@intFromEnum(Request.buffer_import_failed));
}

/// `set_window_state`, `ack_unbind`: one scalar.
pub fn decodeU32(body: []const u8) Error!u32 {
    var r: Reader = .{ .body = body };
    const v = try r.u32_();
    try r.done();
    return v;
}

pub fn decodeU64(body: []const u8) Error!u64 {
    var r: Reader = .{ .body = body };
    const v = try r.u64_();
    try r.done();
    return v;
}

pub fn encodeU32(buf: []u8, op: u16, v: u32) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u32_(v);
    return w.finish(op);
}

pub fn encodeU64(buf: []u8, op: u16, v: u64) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u64_(v);
    return w.finish(op);
}

pub const ReleaseArmed = struct { buffer_generation: u64, seq: u64 };

pub fn decodeReleaseArmed(body: []const u8) Error!ReleaseArmed {
    var r: Reader = .{ .body = body };
    const a: ReleaseArmed = .{ .buffer_generation = try r.u64_(), .seq = try r.u64_() };
    try r.done();
    return a;
}

pub fn encodeReleaseArmed(buf: []u8, a: ReleaseArmed) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u64_(a.buffer_generation);
    try w.u64_(a.seq);
    return w.finish(@intFromEnum(Request.frame_release_armed));
}

/// Tagged `client_capabilities`: only whether window observation was declared.
pub fn declaresWindowObservation(body: []const u8) bool {
    var r: Reader = .{ .body = body };
    if ((r.u32_() catch return false) != 1) return false;
    const payload = r.u32_() catch return false;
    if (payload > r.body.len - r.pos) return false;
    const end = r.pos + payload;
    while (r.pos + 12 <= end) {
        const tag = r.u32_() catch return false;
        _ = r.u32_() catch return false;
        const n = r.u32_() catch return false;
        if (tag == 1) return true;
        if (n > end - r.pos) return false;
        r.pos += (n + 3) & ~@as(usize, 3);
    }
    return false;
}

pub const WindowObservationState = struct { config_generation: u64, flags: u32 };

/// Tagged `set_window_observation_state`: the window flags (`window`) a
/// client reports once it has a `set_window_observation_config`, in place of
/// `set_window_state`. Unknown fields are skipped; a missing one is zero.
pub fn decodeWindowObservationState(body: []const u8) Error!WindowObservationState {
    var r: Reader = .{ .body = body };
    _ = try r.u32_(); // revision
    const payload = try r.u32_();
    if (payload != r.body.len - r.pos) return if (payload > r.body.len - r.pos) error.Truncated else error.TrailingBytes;
    var s: WindowObservationState = .{ .config_generation = 0, .flags = 0 };
    while (r.pos < r.body.len) {
        const tag = try r.u32_();
        const wire = try r.u32_();
        const n = try r.u32_();
        const padded = (@as(usize, n) + 3) & ~@as(usize, 3);
        if (padded > r.body.len - r.pos) return error.Truncated;
        const end = r.pos + padded;
        if (tag == 1 and wire == wire_u64 and n == 8) s.config_generation = try r.u64_();
        if (tag == 2 and wire == wire_u32 and n == 4) s.flags = try r.u32_();
        r.pos = end;
    }
    return s;
}

pub fn encodeWindowObservationState(buf: []u8, s: WindowObservationState) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u32_(1); // revision
    const body = try w.lengthSlot();
    try w.u32_(1);
    try w.u32_(wire_u64);
    const g = try w.lengthSlot();
    try w.u64_(s.config_generation);
    w.patchLength(g);
    try w.u32_(2);
    try w.u32_(wire_u32);
    const f = try w.lengthSlot();
    try w.u32_(s.flags);
    w.patchLength(f);
    w.patchLength(body);
    return w.finish(@intFromEnum(Request.set_window_observation_state));
}

// ---- events (zmural -> client) -------------------------------------------------------

pub fn encodeWelcome(buf: []u8, server_version: []const u8) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.string(server_version);
    return w.finish(@intFromEnum(Event.welcome));
}

pub fn decodeWelcome(body: []const u8) Error![]const u8 {
    var r: Reader = .{ .body = body };
    const s = try r.string();
    try r.done();
    return s;
}

fn writeSnapshot(w: *Writer, p: Presentation) Error!void {
    // presentation_config
    try w.u64_(p.config_generation);
    try w.u32_(@intFromBool(p.blur)); // pause_effect.kind: none or blur
    try w.u32_(std.math.clamp(p.blur_radius, 1, 64));
    try w.u32_(0); // transition.kind: none
    try w.u32_(500); // duration_ms (must be valid even for none)
    try w.u32_(0); // angle
    try w.f32_(0.5);
    try w.f32_(0.5);
    // presentation_state
    try w.u64_(p.state_generation);
    try w.u64_(p.config_generation);
    try w.boolean(p.paused);
}

pub fn encodeDisplayAccepted(buf: []u8, display_id: u64, p: Presentation) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u64_(display_id);
    try writeSnapshot(&w, p);
    return w.finish(@intFromEnum(Event.display_accepted));
}

pub fn decodeDisplayId(body: []const u8) Error!u64 {
    var r: Reader = .{ .body = body };
    return r.u64_();
}

fn writeComposition(w: *Writer, c: CompositionConfig) Error!void {
    try w.u64_(c.generation);
    try w.u64_(c.buffer_generation);
    try w.rect(c.source_rect);
    try w.rect(c.dest_rect);
    try w.u32_(c.transform);
    inline for (.{ c.clear_color.r, c.clear_color.g, c.clear_color.b, c.clear_color.a }) |v| try w.f32_(v);
}

fn readComposition(r: *Reader) Error!CompositionConfig {
    return .{
        .generation = try r.u64_(),
        .buffer_generation = try r.u64_(),
        .source_rect = try r.rect(),
        .dest_rect = try r.rect(),
        .transform = try r.u32_(),
        .clear_color = .{ .r = try r.f32_(), .g = try r.f32_(), .b = try r.f32_(), .a = try r.f32_() },
    };
}

/// A pool of `count` single-plane buffers (fds: one per buffer, in order).
pub const BindBuffers = struct {
    buffer_generation: u64,
    count: u32,
    width: u32,
    height: u32,
    fourcc: u32,
    modifier: u64,
    stride: u32,
    offset: u32,
    size: u64,
    initial_config: CompositionConfig,
    content_token: u64,
    presentation_config_generation: u64,
};

pub fn encodeBindBuffers(buf: []u8, b: BindBuffers) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u64_(b.buffer_generation);
    try w.u32_(b.count);
    try w.u32_(b.width);
    try w.u32_(b.height);
    try w.u32_(b.fourcc);
    try w.u64_(b.modifier);
    try w.u32_(1); // planes_per_buffer
    try w.u32_(b.count);
    for (0..b.count) |_| try w.u32_(b.stride);
    try w.u32_(b.count);
    for (0..b.count) |_| try w.u32_(b.offset);
    try w.u32_(b.count);
    for (0..b.count) |_| try w.u64_(b.size);
    try writeComposition(&w, b.initial_config);
    try w.u64_(b.content_token);
    try w.u64_(b.presentation_config_generation);
    return w.finish(@intFromEnum(Event.bind_buffers));
}

/// As the host reads it: single-plane pools only (the first plane's layout).
pub fn decodeBindBuffers(body: []const u8) Error!struct { BindBuffers, u32 } {
    var r: Reader = .{ .body = body };
    var b: BindBuffers = undefined;
    b.buffer_generation = try r.u64_();
    b.count = try r.u32_();
    b.width = try r.u32_();
    b.height = try r.u32_();
    b.fourcc = try r.u32_();
    b.modifier = try r.u64_();
    const planes = try r.u32_();
    const strides = try r.arrayU32();
    const offsets = try r.arrayU32();
    const sizes = try r.arrayU64();
    b.stride = if (count(u32, strides) > 0) item(u32, strides, 0) else 0;
    b.offset = if (count(u32, offsets) > 0) item(u32, offsets, 0) else 0;
    b.size = if (count(u64, sizes) > 0) item(u64, sizes, 0) else 0;
    b.initial_config = try readComposition(&r);
    b.content_token = try r.u64_();
    b.presentation_config_generation = try r.u64_();
    try r.done();
    return .{ b, planes };
}

pub fn encodeComposition(buf: []u8, c: CompositionConfig) Error![]const u8 {
    var w: Writer = .init(buf);
    try writeComposition(&w, c);
    return w.finish(@intFromEnum(Event.set_composition_config));
}

pub fn decodeComposition(body: []const u8) Error!CompositionConfig {
    var r: Reader = .{ .body = body };
    const c = try readComposition(&r);
    try r.done();
    return c;
}

/// fds: the acquire sync_file, then the release syncobj.
pub const FrameReady = struct { buffer_generation: u64, buffer_index: u32, seq: u64 };

pub fn encodeFrameReady(buf: []u8, f: FrameReady) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u64_(f.buffer_generation);
    try w.u32_(f.buffer_index);
    try w.u64_(f.seq);
    return w.finish(@intFromEnum(Event.frame_ready));
}

pub fn decodeFrameReady(body: []const u8) Error!FrameReady {
    var r: Reader = .{ .body = body };
    const f: FrameReady = .{ .buffer_generation = try r.u64_(), .buffer_index = try r.u32_(), .seq = try r.u64_() };
    try r.done();
    return f;
}

pub fn encodeError(buf: []u8, code: ErrorCode, message: []const u8) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u32_(@intFromEnum(code));
    try w.string(message);
    return w.finish(@intFromEnum(Event.@"error"));
}

pub fn encodePresentationState(buf: []u8, p: Presentation) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u64_(p.state_generation);
    try w.u64_(p.config_generation);
    try w.boolean(p.paused);
    return w.finish(@intFromEnum(Event.set_presentation_state));
}

/// Tagged wire types used below (waywallen's generator: u64 = 4, nested
/// struct = 11, array of strings = 264).
const wire_u32 = 2;
const wire_u64 = 4;
const wire_struct = 11;
const wire_string_array = 264;

/// `set_window_observation_config` with no exclusions, at `generation`.
pub fn encodeWindowObservationConfig(buf: []u8, generation: u64) Error![]const u8 {
    var w: Writer = .init(buf);
    try w.u32_(1); // revision
    const body = try w.lengthSlot();
    try w.u32_(1); // tag: config
    try w.u32_(wire_struct);
    const field = try w.lengthSlot();
    {
        try w.u32_(1); // nested revision
        const nested = try w.lengthSlot();
        try w.u32_(1);
        try w.u32_(wire_u64);
        const g = try w.lengthSlot();
        try w.u64_(generation);
        w.patchLength(g);
        for ([_]u32{ 2, 3 }) |tag| { // excluded application ids, titles: empty
            try w.u32_(tag);
            try w.u32_(wire_string_array);
            const a = try w.lengthSlot();
            try w.u32_(0);
            w.patchLength(a);
        }
        w.patchLength(nested);
    }
    w.patchLength(field);
    w.patchLength(body);
    return w.finish(@intFromEnum(Event.set_window_observation_config));
}

// ---- stream framing -------------------------------------------------------------------

/// One end of a display connection (SOCK_STREAM). Frames are read into an
/// internal buffer; fds are handed out with the frame whose bytes they
/// arrived with.
pub const Stream = struct {
    fd: linux.fd_t,
    in: [max_frame * 2]u8 = undefined,
    in_start: usize = 0,
    in_end: usize = 0,
    fds: [max_fds]linux.fd_t = undefined,
    nfds: usize = 0,
    /// fds belonging to the frame `next` returned; closed on the next call
    /// unless the caller took them (`takeFds`).
    frame_fds: [max_fds]linux.fd_t = undefined,
    frame_nfds: usize = 0,

    pub const Frame = struct { opcode: u16, body: []const u8 };

    pub fn close(s: *Stream) void {
        s.dropFrameFds();
        for (s.fds[0..s.nfds]) |fd| _ = linux.close(fd);
        s.nfds = 0;
        if (s.fd >= 0) _ = linux.close(s.fd);
        s.fd = -1;
    }

    fn dropFrameFds(s: *Stream) void {
        for (s.frame_fds[0..s.frame_nfds]) |fd| _ = linux.close(fd);
        s.frame_nfds = 0;
    }

    /// The fds that came with the last frame; the caller owns them now.
    pub fn takeFds(s: *Stream) []const linux.fd_t {
        defer s.frame_nfds = 0;
        return s.frame_fds[0..s.frame_nfds];
    }

    /// Reads what's available (call when the fd polls readable).
    /// `error.Disconnected` at end of stream.
    pub fn fill(s: *Stream) !void {
        if (s.in_start > 0) {
            std.mem.copyForwards(u8, &s.in, s.in[s.in_start..s.in_end]);
            s.in_end -= s.in_start;
            s.in_start = 0;
        }
        var control: FdControl = undefined;
        var iov = [_]std.posix.iovec{.{ .base = s.in[s.in_end..].ptr, .len = s.in.len - s.in_end }};
        var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = @sizeOf(FdControl), .flags = 0 };
        const n = while (true) {
            const rc = linux.recvmsg(s.fd, &msg, linux.MSG.CMSG_CLOEXEC | linux.MSG.DONTWAIT);
            switch (linux.errno(rc)) {
                .SUCCESS => break rc,
                .INTR => continue,
                .AGAIN => return,
                .CONNRESET => return error.Disconnected,
                else => return error.SocketFailed,
            }
        };
        if (msg.controllen >= @sizeOf(linux.cmsghdr) and control.header.level == linux.SOL.SOCKET and control.header.type == linux.SCM.RIGHTS) {
            const got = (@min(control.header.len, msg.controllen) -| @sizeOf(linux.cmsghdr)) / @sizeOf(linux.fd_t);
            for (control.fds[0..@min(got, FdControl.max)]) |fd| {
                if (s.nfds == max_fds) {
                    _ = linux.close(fd);
                    continue;
                }
                s.fds[s.nfds] = fd;
                s.nfds += 1;
            }
        }
        if (n == 0) return error.Disconnected;
        s.in_end += n;
    }

    /// The next complete frame, or null until more arrives. `fds_per_frame`
    /// says how many queued fds belong to a frame with that opcode.
    pub fn next(s: *Stream, fds_for: *const fn (opcode: u16, body: []const u8) usize) !?Frame {
        s.dropFrameFds();
        const avail = s.in[s.in_start..s.in_end];
        if (avail.len < header_len) return null;
        const opcode = std.mem.readInt(u16, avail[0..2], .little);
        const total = std.mem.readInt(u16, avail[2..4], .little);
        if (total < header_len) return error.Protocol;
        if (avail.len < total) return null;
        s.in_start += total;
        const body = avail[header_len..total];
        const want = fds_for(opcode, body);
        if (want > s.nfds) return error.Protocol;
        @memcpy(s.frame_fds[0..want], s.fds[0..want]);
        s.frame_nfds = want;
        std.mem.copyForwards(linux.fd_t, s.fds[0 .. s.nfds - want], s.fds[want..s.nfds]);
        s.nfds -= want;
        return .{ .opcode = opcode, .body = body };
    }

    /// Sends a whole frame, fds attached to its first bytes. The fds stay
    /// the caller's.
    pub fn send(s: *Stream, frame: []const u8, fds: []const linux.fd_t) !void {
        if (fds.len > FdControl.max) return error.TooManyFds;
        var sent: usize = 0;
        while (sent < frame.len) {
            var control: FdControl = undefined;
            const iov = [_]std.posix.iovec_const{.{ .base = frame[sent..].ptr, .len = frame.len - sent }};
            var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            if (sent == 0 and fds.len > 0) {
                control.header = .{ .len = FdControl.space(fds.len), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
                @memcpy(control.fds[0..fds.len], fds);
                msg.control = &control;
                msg.controllen = FdControl.space(fds.len);
            }
            const rc = linux.sendmsg(s.fd, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => sent += rc,
                .INTR => continue,
                .AGAIN => return error.Timeout,
                .PIPE, .CONNRESET => return error.Disconnected,
                else => return error.SocketFailed,
            }
        }
    }
};

const FdControl = extern struct {
    const max = max_fds;
    header: linux.cmsghdr,
    fds: [max]linux.fd_t,

    fn space(n: usize) usize {
        return @sizeOf(linux.cmsghdr) + n * @sizeOf(linux.fd_t);
    }
};

/// Requests never carry fds.
pub fn requestFds(_: u16, _: []const u8) usize {
    return 0;
}

/// fds per event, as the protocol lists them.
pub fn eventFds(opcode: u16, body: []const u8) usize {
    return switch (@as(Event, @enumFromInt(opcode))) {
        .frame_ready => 2,
        .bind_buffers => blk: {
            // count (at 8) * planes_per_buffer (at 32)
            if (body.len < 36) break :blk 0;
            const n = std.mem.readInt(u32, body[8..12], .little);
            const planes = std.mem.readInt(u32, body[32..36], .little);
            break :blk @min(@as(usize, n) * planes, max_fds);
        },
        else => 0,
    };
}

// ---- tests ----------------------------------------------------------------------------

const testing = std.testing;

test "strings pad to four bytes and keep their NUL" {
    var buf: [64]u8 = undefined;
    const f = try encodeWelcome(&buf, "zmural");
    // header, then len 7 ("zmural" + NUL), 6 bytes, NUL, 1 byte of padding
    try testing.expectEqualSlices(u8, &.{ 1, 0, 16, 0, 7, 0, 0, 0, 'z', 'm', 'u', 'r', 'a', 'l', 0, 0 }, f);
    try testing.expectEqualStrings("zmural", try decodeWelcome(f[header_len..]));
}

test "hello round trips" {
    var buf: [128]u8 = undefined;
    const f = try encodeHello(&buf, .{ .client_name = "layer-shell", .client_version = "0.1", .protocol_version = 9 });
    const h = try decodeHello(f[header_len..]);
    try testing.expectEqualStrings("layer-shell", h.client_name);
    try testing.expectEqual(@as(u32, 9), h.protocol_version);
}

test "register round trips, and single-plane modifiers are picked out" {
    var buf: [512]u8 = undefined;
    const mods = [_]u64{ 0, 0x200000000401b03 };
    const f = try encodeRegister(&buf, "DP-1", "m-1234", .{ .width = 2560, .height = 1440, .refresh_mhz = 144000 }, 0x34325258, &mods, 226, 128, window.has_active);
    const reg = try decodeRegister(f[header_len..]);
    try testing.expectEqualStrings("DP-1", reg.name);
    try testing.expectEqual(@as(u32, 1440), reg.metrics.height);
    try testing.expectEqual(window.has_active, reg.window_flags);
    var out: [8]u64 = undefined;
    const n = reg.caps.singlePlaneModifiers(0x34325258, &out);
    try testing.expectEqualSlices(u64, &mods, out[0..n]);
    try testing.expectEqual(@as(usize, 0), reg.caps.singlePlaneModifiers(0x12345678, &out));
    try testing.expectEqual(@as(u64, (226 << 8) | 128), reg.caps.device());
}

test "bind_buffers round trips and names its fd count" {
    var buf: [512]u8 = undefined;
    const b: BindBuffers = .{
        .buffer_generation = 3,
        .count = 3,
        .width = 1920,
        .height = 1080,
        .fourcc = 0x34325258,
        .modifier = 0x200000000401b03,
        .stride = 7680,
        .offset = 0,
        .size = 8294400,
        .initial_config = .{ .generation = 1, .buffer_generation = 3, .source_rect = .{ .w = 1920, .h = 1080 }, .dest_rect = .{ .w = 1920, .h = 1080 } },
        .content_token = 42,
        .presentation_config_generation = 1,
    };
    const f = try encodeBindBuffers(&buf, b);
    try testing.expectEqual(@as(usize, 3), eventFds(@intFromEnum(Event.bind_buffers), f[header_len..]));
    const back, const planes = try decodeBindBuffers(f[header_len..]);
    try testing.expectEqual(@as(u32, 1), planes);
    try testing.expectEqual(b.modifier, back.modifier);
    try testing.expectEqual(b.initial_config.dest_rect.w, back.initial_config.dest_rect.w);
    try testing.expectEqual(b.content_token, back.content_token);
}

test "a client declaring window observation is recognised" {
    // revision 1, payload 16: tag 1, type 11, 4 bytes, value
    var body: [24]u8 = undefined;
    for ([_]u32{ 1, 16, 1, 11, 4, 0 }, 0..) |v, i| std.mem.writeInt(u32, body[i * 4 ..][0..4], v, .little);
    try testing.expect(declaresWindowObservation(&body));
    std.mem.writeInt(u32, body[8..12], 2, .little); // tag 2: pause effect only
    try testing.expect(!declaresWindowObservation(&body));
}

test "set_window_observation_state round-trips, skips unknown fields, rejects a short body" {
    var buf: [96]u8 = undefined;
    const f = try encodeWindowObservationState(&buf, .{ .config_generation = 7, .flags = window.has_fullscreen | window.has_active });
    const s = try decodeWindowObservationState(f[header_len..]);
    try testing.expectEqual(@as(u64, 7), s.config_generation);
    try testing.expectEqual(window.has_fullscreen | window.has_active, s.flags);
    try testing.expectError(error.Truncated, decodeWindowObservationState(f[header_len .. f.len - 4]));

    // A later revision's extra field (tag 9, six bytes padded to eight) between the two.
    var body: [64]u8 = undefined;
    const words = [_]u32{ 1, 56, 1, wire_u64, 8, 3, 0, 9, 99, 6, 0, 0, 2, wire_u32, 4, window.has_maximized };
    try testing.expectEqual(body.len, words.len * 4);
    for (words, 0..) |v, i| std.mem.writeInt(u32, body[i * 4 ..][0..4], v, .little);
    const t = try decodeWindowObservationState(&body);
    try testing.expectEqual(@as(u64, 3), t.config_generation);
    try testing.expectEqual(window.has_maximized, t.flags);
}

test "stream frames split across reads, with their fds" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var sv: [2]i32 = undefined;
    try testing.expect(linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv)) == .SUCCESS);
    var a: Stream = .{ .fd = sv[0] };
    var b: Stream = .{ .fd = sv[1] };
    defer a.close();
    defer b.close();
    var buf: [128]u8 = undefined;
    const fr = try encodeFrameReady(&buf, .{ .buffer_generation = 1, .buffer_index = 2, .seq = 3 });
    const extra = [_]linux.fd_t{ 0, 1 }; // any two fds; the peer gets duplicates
    try a.send(fr, &extra);
    try b.fill();
    const got = (try b.next(eventFds)).?;
    try testing.expectEqual(@intFromEnum(Event.frame_ready), got.opcode);
    try testing.expectEqual(@as(u32, 2), (try decodeFrameReady(got.body)).buffer_index);
    try testing.expectEqual(@as(usize, 2), b.frame_nfds);
    try testing.expectEqual(@as(?Stream.Frame, null), try b.next(eventFds));
}
