// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The Wayland side of the layer-shell host (`zmural --layer-shell`): one background layer surface per
//! output, and the buffers shown on it.
//!
//! Each output gets two surfaces. The layer surface itself shows a single
//! pixel of the clear colour, stretched over the whole output (letterbox
//! bars). The wallpaper is a subsurface on top of it: a wp_viewport crops the
//! buffer to the composition's source rect and scales it to the destination
//! rect, so the compositor does all the scaling and the buffers go straight
//! from the renderer to the screen (zero copies).
//!
//! Frames are shown newest-first: while the compositor hasn't asked for the
//! next frame (wl_surface.frame), a newer frame replaces a waiting one, and
//! the replaced one is released at once.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const wl = zmural.os.wayland;
const p = @import("protocols.zig");
const monitor = zmural.monitor;
const layout = zmural.layout;

const log = std.log.scoped(.host);

pub const max_slots = 4;

/// Everything the host binds from the registry. 0 means not offered.
pub const Globals = struct {
    compositor: wl.ObjectId = 0,
    subcompositor: wl.ObjectId = 0,
    layer_shell: wl.ObjectId = 0,
    shm: wl.ObjectId = 0,
    dmabuf: wl.ObjectId = 0,
    viewporter: wl.ObjectId = 0,
    /// Optional: without it the background colour is a 1x1 wl_shm buffer.
    single_pixel: wl.ObjectId = 0,
    /// Optional: without it, no window-state facts (no auto-pause).
    toplevels: wl.ObjectId = 0,
    /// A global that was offered at a version too old to use, to name in the
    /// error when it was one the host needs.
    too_old: ?struct { name: []const u8, have: u32, need: u32 } = null,

    /// What `zmural-layer-shell` can't run without.
    pub fn missing(g: Globals) ?[]const u8 {
        if (g.compositor == 0) return p.wl_compositor.name;
        if (g.subcompositor == 0) return p.wl_subcompositor.name;
        if (g.layer_shell == 0) return p.zwlr_layer_shell_v1.name;
        if (g.viewporter == 0) return p.wp_viewporter.name;
        // Wallpapers arrive as DMA-BUFs; without them nothing but the
        // background colour could show.
        if (g.dmabuf == 0) return p.zwp_linux_dmabuf_v1.name;
        // Every compositor has wl_shm; it backs the background colour when
        // single-pixel buffers are missing (Niri).
        if (g.shm == 0) return p.wl_shm.name;
        return null;
    }
};

/// A buffer the compositor may be reading. `wl_buffer.release` frees it.
pub const Slot = struct {
    buffer: wl.ObjectId = 0,
    /// Attached (or waiting to be) and not yet released by the compositor.
    busy: bool = false,
};

/// What to draw, in output pixels. The default fills the output with the
/// whole buffer.
pub const Composition = struct {
    src: layout.Rect,
    dst: layout.Rect,
    clear_rgba: u32 = 0x000000ff,
};

pub const Output = struct {
    global: u32,
    wl_output: wl.ObjectId,
    /// The connector ("DP-1"), from wl_output.name.
    name: [64]u8 = @splat(0),
    name_len: usize = 0,
    /// Current mode, in pixels.
    width: u32 = 0,
    height: u32 = 0,
    refresh_mhz: u32 = 0,
    scale: u32 = 1,
    /// wl_output.done seen at least once: the facts above are complete.
    ready: bool = false,

    // Surfaces, created once the output is ready.
    surface: wl.ObjectId = 0,
    layer_surface: wl.ObjectId = 0,
    background_viewport: wl.ObjectId = 0,
    background_buffer: wl.ObjectId = 0,
    content: wl.ObjectId = 0,
    subsurface: wl.ObjectId = 0,
    content_viewport: wl.ObjectId = 0,
    /// Logical size from the layer surface's configure (0 until configured).
    logical_w: u32 = 0,
    logical_h: u32 = 0,

    slots: [max_slots]Slot = @splat(.{}),
    buffer_w: u32 = 0,
    buffer_h: u32 = 0,
    composition: ?Composition = null,
    clear_rgba: u32 = 0x000000ff,
    /// The slot on screen, and one waiting for the next frame callback.
    shown: ?u8 = null,
    pending: ?u8 = null,
    frame_callback: wl.ObjectId = 0,
    /// Last window state reported for this output.
    window_state: WindowState = .{},

    pub fn connector(o: *const Output) []const u8 {
        return o.name[0..o.name_len];
    }

    pub fn configured(o: *const Output) bool {
        return o.logical_w != 0 and o.logical_h != 0;
    }
};

/// What the windows on an output are doing, as the display protocol reports it.
pub const WindowState = struct {
    fullscreen: bool = false,
    maximized: bool = false,
    /// wlr-foreign-toplevel has no geometry: never set from it.
    covered: bool = false,
    focused: bool = false,

    pub fn eql(a: WindowState, b: WindowState) bool {
        return std.meta.eql(a, b);
    }
};

/// Another client's window, from wlr-foreign-toplevel-management.
const Toplevel = struct {
    handle: wl.ObjectId,
    /// wl_output ids it is on (a window can span outputs).
    outputs: [8]wl.ObjectId = @splat(0),
    // Pending until `done`, then current.
    pending: Flags = .{},
    current: Flags = .{},

    const Flags = struct { maximized: bool = false, minimized: bool = false, activated: bool = false, fullscreen: bool = false };

    fn on(t: *const Toplevel, output: wl.ObjectId) bool {
        return std.mem.findScalar(wl.ObjectId, &t.outputs, output) != null;
    }
};

/// Tells the owner of the buffers (the daemon, or the test pattern) what
/// happened. Called from inside `Host.dispatch`.
pub const Listener = struct {
    ctx: *anyopaque,
    /// The output has its facts and a configured surface; frames can follow.
    output_ready: *const fn (ctx: *anyopaque, o: *Output) void,
    output_gone: *const fn (ctx: *anyopaque, o: *Output) void,
    /// The compositor is done with a slot's buffer.
    released: *const fn (ctx: *anyopaque, o: *Output, slot: u8) void,
    /// The windows on the output changed state (optional).
    window_state: ?*const fn (ctx: *anyopaque, o: *Output, ws: WindowState) void = null,
};

const Handler = union(enum) {
    registry,
    output: *Output,
    layer_surface: *Output,
    buffer: struct { output: *Output, slot: u8 },
    frame: *Output,
    feedback,
    toplevel_manager,
    toplevel: *Toplevel,
    /// A roundtrip's wl_display.sync callback.
    sync: *bool,
};

/// What the compositor imports: its main GPU and the XRGB8888 modifiers,
/// preferred tranche first (linux-dmabuf v4 default feedback).
pub const Feedback = struct {
    pub const max_modifiers = 64;
    device: u64 = 0,
    modifiers: [max_modifiers]u64 = undefined,
    count: usize = 0,
    /// A `done` has been seen: the lists above are complete.
    complete: bool = false,

    // While a feedback round is being received:
    table: ?[]align(std.heap.page_size_min) const u8 = null,

    fn add(f: *Feedback, modifier: u64) void {
        for (f.modifiers[0..f.count]) |m| if (m == modifier) return;
        if (f.count == max_modifiers) return;
        f.modifiers[f.count] = modifier;
        f.count += 1;
    }

    /// The modifiers as little-endian bytes, for the display protocol.
    pub fn bytes(f: *const Feedback, out: *[max_modifiers * 8]u8) []const u8 {
        for (f.modifiers[0..f.count], 0..) |m, i| std.mem.writeInt(u64, out[i * 8 ..][0..8], m, .little);
        return out[0 .. f.count * 8];
    }
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    conn: wl.Conn,
    registry: wl.ObjectId = 0,
    globals: Globals = .{},
    feedback: Feedback = .{},
    feedback_object: wl.ObjectId = 0,
    outputs: std.ArrayList(*Output) = .empty,
    handlers: std.AutoHashMapUnmanaged(wl.ObjectId, Handler) = .empty,
    listener: ?Listener = null,
    toplevels: std.ArrayList(*Toplevel) = .empty,

    pub fn init(gpa: std.mem.Allocator, conn: wl.Conn) Host {
        return .{ .gpa = gpa, .conn = conn };
    }

    pub fn deinit(h: *Host) void {
        if (h.feedback.table) |t| _ = linux.munmap(t.ptr, t.len);
        for (h.outputs.items) |o| h.gpa.destroy(o);
        for (h.toplevels.items) |t| h.gpa.destroy(t);
        h.toplevels.deinit(h.gpa);
        h.outputs.deinit(h.gpa);
        h.handlers.deinit(h.gpa);
        h.conn.close();
    }

    /// Binds the globals and learns every output. Fails if the compositor
    /// lacks something the host needs.
    pub fn start(h: *Host) !void {
        h.registry = try h.conn.getRegistry();
        try h.handlers.put(h.gpa, h.registry, .registry);
        try h.roundtrip(); // globals
        if (h.globals.missing()) |name| {
            if (h.globals.too_old) |old| if (std.mem.eql(u8, old.name, name)) {
                log.err("the compositor offers {s} v{d}; zmural's display host needs v{d} or newer", .{ name, old.have, old.need });
                return error.Unsupported;
            };
            log.err("the compositor doesn't offer {s}, which zmural's display host needs", .{name});
            return error.Unsupported;
        }
        if (h.globals.dmabuf != 0) {
            h.feedback_object = h.conn.newId();
            try h.conn.request(h.globals.dmabuf, @backingInt(p.zwp_linux_dmabuf_v1.request.get_default_feedback), &.{.{ .new_id = h.feedback_object }});
            try h.handlers.put(h.gpa, h.feedback_object, .feedback);
        }
        try h.roundtrip(); // the outputs' first events, and the dmabuf feedback
    }

    /// Sends everything queued and waits until the compositor has handled it.
    pub fn roundtrip(h: *Host) !void {
        var done = false;
        const cb = try h.conn.sync();
        try h.handlers.put(h.gpa, cb, .{ .sync = &done });
        try h.conn.flush();
        while (!done) {
            try h.conn.fill();
            try h.dispatch();
        }
    }

    /// Handles every complete event read so far.
    pub fn dispatch(h: *Host) !void {
        while (try h.conn.next()) |ev| {
            var e = ev;
            try h.handle(&e);
        }
    }

    fn handle(h: *Host, e: *wl.Event) !void {
        if (e.object == wl.display_id) return h.onDisplay(e);
        const handler = h.handlers.get(e.object) orelse return; // an object we've let go of
        switch (handler) {
            .registry => try h.onRegistry(e),
            .output => |o| try h.onOutput(o, e),
            .layer_surface => |o| try h.onLayerSurface(o, e),
            .buffer => |b| if (e.opcode == @backingInt(p.wl_buffer.event.release)) {
                b.output.slots[b.slot].busy = false;
                if (h.listener) |l| l.released(l.ctx, b.output, b.slot);
            },
            .frame => |o| {
                _ = h.handlers.remove(e.object);
                o.frame_callback = 0;
                if (o.pending) |slot| {
                    o.pending = null;
                    try h.present(o, slot);
                }
            },
            .feedback => try h.onFeedback(e),
            .toplevel_manager => try h.onToplevelManager(e),
            .toplevel => |t| try h.onToplevel(t, e),
            .sync => |flag| {
                _ = h.handlers.remove(e.object);
                flag.* = true;
            },
        }
    }

    fn onFeedback(h: *Host, e: *wl.Event) !void {
        const f = &h.feedback;
        switch (std.enums.fromInt(p.zwp_linux_dmabuf_feedback_v1.event, e.opcode) orelse return) {
            .format_table => {
                const fd = try e.args.fd();
                defer _ = linux.close(fd);
                const size = try e.args.uint();
                if (f.table) |t| _ = linux.munmap(t.ptr, t.len);
                f.table = null;
                const addr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
                if (linux.errno(addr) != .SUCCESS) return;
                f.table = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(addr))[0..size];
                // A new table starts a new list.
                f.count = 0;
            },
            .main_device => {
                const dev = try e.args.array();
                if (dev.len == 8) f.device = std.mem.readInt(u64, dev[0..8], .native);
            },
            .tranche_formats => {
                const table = f.table orelse return;
                const indices = try e.args.array();
                var i: usize = 0;
                while (i + 2 <= indices.len) : (i += 2) {
                    const idx: usize = std.mem.readInt(u16, indices[i..][0..2], .native);
                    // Each entry: u32 format, u32 padding, u64 modifier.
                    if ((idx + 1) * 16 > table.len) continue;
                    const entry = table[idx * 16 ..][0..16];
                    if (std.mem.readInt(u32, entry[0..4], .native) != p.fourcc.xrgb8888) continue;
                    f.add(std.mem.readInt(u64, entry[8..16], .native));
                }
            },
            .done => f.complete = true,
            .tranche_done, .tranche_target_device, .tranche_flags => {},
        }
    }

    fn onToplevelManager(h: *Host, e: *wl.Event) !void {
        switch (std.enums.fromInt(p.zwlr_foreign_toplevel_manager_v1.event, e.opcode) orelse return) {
            .toplevel => {
                // A server-created object: from now on, its events are ours.
                const t = try h.gpa.create(Toplevel);
                errdefer h.gpa.destroy(t);
                t.* = .{ .handle = try e.args.object() };
                try h.toplevels.append(h.gpa, t);
                try h.handlers.put(h.gpa, t.handle, .{ .toplevel = t });
            },
            .finished => {
                _ = h.handlers.remove(h.globals.toplevels);
                h.globals.toplevels = 0;
            },
        }
    }

    fn onToplevel(h: *Host, t: *Toplevel, e: *wl.Event) !void {
        const T = p.zwlr_foreign_toplevel_handle_v1;
        switch (std.enums.fromInt(T.event, e.opcode) orelse return) {
            .output_enter => {
                const out = try e.args.object();
                if (!t.on(out)) if (std.mem.findScalar(wl.ObjectId, &t.outputs, 0)) |i| {
                    t.outputs[i] = out;
                };
            },
            .output_leave => {
                const out = try e.args.object();
                for (&t.outputs) |*o| if (o.* == out) {
                    o.* = 0;
                };
            },
            .state => {
                const raw = try e.args.array();
                t.pending = .{};
                var i: usize = 0;
                while (i + 4 <= raw.len) : (i += 4) switch (std.mem.readInt(u32, raw[i..][0..4], .native)) {
                    T.state.maximized => t.pending.maximized = true,
                    T.state.minimized => t.pending.minimized = true,
                    T.state.activated => t.pending.activated = true,
                    T.state.fullscreen => t.pending.fullscreen = true,
                    else => {},
                };
            },
            .done => {
                t.current = t.pending;
                h.reportWindowStates();
            },
            .closed => {
                _ = h.handlers.remove(t.handle);
                try h.conn.request(t.handle, @backingInt(T.request.destroy), &.{});
                if (std.mem.findScalar(*Toplevel, h.toplevels.items, t)) |i| _ = h.toplevels.swapRemove(i);
                h.gpa.destroy(t);
                h.reportWindowStates();
            },
            .title, .app_id, .parent => {},
        }
    }

    /// Recomputes every output's window state and reports the ones that
    /// changed. Facts only: the daemon decides what they mean.
    fn reportWindowStates(h: *Host) void {
        for (h.outputs.items) |o| {
            var ws: WindowState = .{};
            for (h.toplevels.items) |t| {
                if (!t.on(o.wl_output) or t.current.minimized) continue;
                ws.fullscreen = ws.fullscreen or t.current.fullscreen;
                ws.maximized = ws.maximized or t.current.maximized;
                ws.focused = ws.focused or t.current.activated;
            }
            if (ws.eql(o.window_state)) continue;
            o.window_state = ws;
            if (h.listener) |l| if (l.window_state) |f| f(l.ctx, o, ws);
        }
    }

    fn onDisplay(h: *Host, e: *wl.Event) !void {
        switch (std.enums.fromInt(p.wl_display.event, e.opcode) orelse return) {
            .@"error" => {
                const object = try e.args.object();
                const code = try e.args.uint();
                const message = try e.args.string() orelse "";
                log.err("compositor: protocol error {d} on object {d}: {s}", .{ code, object, message });
                return error.ProtocolError;
            },
            .delete_id => h.conn.deleteId(try e.args.uint()),
        }
    }

    fn onRegistry(h: *Host, e: *wl.Event) !void {
        switch (std.enums.fromInt(p.wl_registry.event, e.opcode) orelse return) {
            .global => {
                const name = try e.args.uint();
                const interface = try e.args.string() orelse return;
                const version = try e.args.uint();
                try h.onGlobal(name, interface, version);
            },
            .global_remove => {
                const name = try e.args.uint();
                for (h.outputs.items, 0..) |o, i| if (o.global == name) {
                    _ = h.outputs.swapRemove(i);
                    try h.dropOutput(o);
                    break;
                };
            },
        }
    }

    fn onGlobal(h: *Host, name: u32, interface: []const u8, version: u32) !void {
        const g = &h.globals;
        inline for (.{
            .{ &g.compositor, p.wl_compositor },
            .{ &g.subcompositor, p.wl_subcompositor },
            .{ &g.layer_shell, p.zwlr_layer_shell_v1 },
            .{ &g.shm, p.wl_shm },
            .{ &g.dmabuf, p.zwp_linux_dmabuf_v1 },
            .{ &g.viewporter, p.wp_viewporter },
            .{ &g.single_pixel, p.wp_single_pixel_buffer_manager_v1 },
            .{ &g.toplevels, p.zwlr_foreign_toplevel_manager_v1 },
        }) |entry| {
            const I = entry[1];
            if (std.mem.eql(u8, interface, I.name)) {
                if (version < I.version) {
                    log.warn("{s} is v{d}; zmural needs v{d}", .{ I.name, version, I.version });
                    g.too_old = .{ .name = I.name, .have = version, .need = I.version };
                    return;
                }
                entry[0].* = try h.conn.bind(h.registry, name, I.name, I.version);
                if (I == p.zwlr_foreign_toplevel_manager_v1) try h.handlers.put(h.gpa, entry[0].*, .toplevel_manager);
                return;
            }
        }
        if (std.mem.eql(u8, interface, p.wl_output.name)) {
            if (version < p.wl_output.version) {
                // Monitors are told apart by connector name, which needs v4
                // (wlroots 0.16, Sway 1.8): with none usable, nothing could show.
                log.err("the compositor offers wl_output v{d}; zmural's display host needs v{d} or newer (for monitors' connector names)", .{ version, p.wl_output.version });
                return error.Unsupported;
            }
            const o = try h.gpa.create(Output);
            errdefer h.gpa.destroy(o);
            o.* = .{ .global = name, .wl_output = try h.conn.bind(h.registry, name, p.wl_output.name, p.wl_output.version) };
            try h.outputs.append(h.gpa, o);
            try h.handlers.put(h.gpa, o.wl_output, .{ .output = o });
        }
    }

    fn onOutput(h: *Host, o: *Output, e: *wl.Event) !void {
        switch (std.enums.fromInt(p.wl_output.event, e.opcode) orelse return) {
            .mode => {
                const flags = try e.args.uint();
                if (flags & p.wl_output.mode_current == 0) return;
                o.width = @intCast(@max(0, try e.args.int()));
                o.height = @intCast(@max(0, try e.args.int()));
                o.refresh_mhz = @intCast(@max(0, try e.args.int()));
            },
            .scale => o.scale = @intCast(@max(1, try e.args.int())),
            .name => {
                const n = try e.args.string() orelse "";
                o.name_len = @min(n.len, o.name.len);
                @memcpy(o.name[0..o.name_len], n[0..o.name_len]);
            },
            .done => {
                const first = !o.ready;
                o.ready = true;
                if (first) try h.createSurfaces(o);
            },
            .geometry, .description => {},
        }
    }

    fn createSurfaces(h: *Host, o: *Output) !void {
        const c = &h.conn;
        const g = h.globals;
        o.surface = c.newId();
        try c.request(g.compositor, @backingInt(p.wl_compositor.request.create_surface), &.{.{ .new_id = o.surface }});
        o.content = c.newId();
        try c.request(g.compositor, @backingInt(p.wl_compositor.request.create_surface), &.{.{ .new_id = o.content }});

        // The desktop's clicks and keys are not ours: empty input regions.
        const region = c.newId();
        try c.request(g.compositor, @backingInt(p.wl_compositor.request.create_region), &.{.{ .new_id = region }});
        for ([_]wl.ObjectId{ o.surface, o.content }) |s|
            try c.request(s, @backingInt(p.wl_surface.request.set_input_region), &.{.{ .object = region }});
        try c.request(region, @backingInt(p.wl_region.request.destroy), &.{});

        o.subsurface = c.newId();
        try c.request(g.subcompositor, @backingInt(p.wl_subcompositor.request.get_subsurface), &.{
            .{ .new_id = o.subsurface }, .{ .object = o.content }, .{ .object = o.surface },
        });
        // Frames arrive on their own clock, not the parent's commits.
        try c.request(o.subsurface, @backingInt(p.wl_subsurface.request.set_desync), &.{});

        o.background_viewport = c.newId();
        try c.request(g.viewporter, @backingInt(p.wp_viewporter.request.get_viewport), &.{ .{ .new_id = o.background_viewport }, .{ .object = o.surface } });
        o.content_viewport = c.newId();
        try c.request(g.viewporter, @backingInt(p.wp_viewporter.request.get_viewport), &.{ .{ .new_id = o.content_viewport }, .{ .object = o.content } });

        o.layer_surface = c.newId();
        try c.request(g.layer_shell, @backingInt(p.zwlr_layer_shell_v1.request.get_layer_surface), &.{
            .{ .new_id = o.layer_surface },
            .{ .object = o.surface },
            .{ .object = o.wl_output },
            .{ .uint = p.zwlr_layer_shell_v1.layer_background },
            .{ .string = "zmural" },
        });
        try h.handlers.put(h.gpa, o.layer_surface, .{ .layer_surface = o });
        const ls = o.layer_surface;
        try c.request(ls, @backingInt(p.zwlr_layer_surface_v1.request.set_anchor), &.{.{ .uint = p.zwlr_layer_surface_v1.anchor_all }});
        // -1: cover the whole output, panels included.
        try c.request(ls, @backingInt(p.zwlr_layer_surface_v1.request.set_exclusive_zone), &.{.{ .int = -1 }});
        try c.request(ls, @backingInt(p.zwlr_layer_surface_v1.request.set_keyboard_interactivity), &.{.{ .uint = 0 }});
        // The first commit carries no buffer; the compositor answers with configure.
        try c.request(o.surface, @backingInt(p.wl_surface.request.commit), &.{});
    }

    fn onLayerSurface(h: *Host, o: *Output, e: *wl.Event) !void {
        switch (std.enums.fromInt(p.zwlr_layer_surface_v1.event, e.opcode) orelse return) {
            .configure => {
                const serial = try e.args.uint();
                const width = try e.args.uint();
                const height = try e.args.uint();
                try h.conn.request(o.layer_surface, @backingInt(p.zwlr_layer_surface_v1.request.ack_configure), &.{.{ .uint = serial }});
                const first = !o.configured();
                o.logical_w = width;
                o.logical_h = height;
                try h.paintBackground(o);
                if (first) {
                    if (h.listener) |l| l.output_ready(l.ctx, o);
                } else if (o.shown) |slot| {
                    // The output changed size: re-place what's on it.
                    try h.present(o, slot);
                }
            },
            .closed => {
                // The compositor took the surface away (the output is going,
                // usually); `global_remove` follows and cleans up.
                log.info("{s}: layer surface closed", .{o.connector()});
            },
        }
    }

    fn paintBackground(h: *Host, o: *Output) !void {
        const c = &h.conn;
        if (o.background_buffer != 0) try c.request(o.background_buffer, @backingInt(p.wl_buffer.request.destroy), &.{});
        const rgba = o.clear_rgba;
        if (h.globals.single_pixel != 0) {
            o.background_buffer = c.newId();
            // The single-pixel buffer takes each channel as a full 32-bit value.
            const scale = 0x01010101;
            try c.request(h.globals.single_pixel, @backingInt(p.wp_single_pixel_buffer_manager_v1.request.create_u32_rgba_buffer), &.{
                .{ .new_id = o.background_buffer },
                .{ .uint = (rgba >> 24 & 0xff) * scale },
                .{ .uint = (rgba >> 16 & 0xff) * scale },
                .{ .uint = (rgba >> 8 & 0xff) * scale },
                .{ .uint = 0xffffffff }, // the background is always opaque
            });
        } else {
            o.background_buffer = try h.onePixel(rgba >> 8);
        }
        try c.request(o.background_viewport, @backingInt(p.wp_viewport.request.set_destination), &.{ .{ .int = @intCast(o.logical_w) }, .{ .int = @intCast(o.logical_h) } });
        try c.request(o.surface, @backingInt(p.wl_surface.request.attach), &.{ .{ .object = o.background_buffer }, .{ .int = 0 }, .{ .int = 0 } });
        try c.request(o.surface, @backingInt(p.wl_surface.request.damage_buffer), &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = 1 }, .{ .int = 1 } });
        try c.request(o.surface, @backingInt(p.wl_surface.request.commit), &.{});
    }

    /// Makes `slot`'s buffer the output's buffer. Records the buffer ids the
    /// owner created (`addShmBuffer` / `addDmabuf`).
    pub fn setBuffers(h: *Host, o: *Output, width: u32, height: u32, buffers: []const wl.ObjectId) !void {
        h.dropBuffers(o) catch |err| return err;
        for (buffers, 0..) |b, i| {
            o.slots[i] = .{ .buffer = b };
            try h.handlers.put(h.gpa, b, .{ .buffer = .{ .output = o, .slot = @intCast(i) } });
        }
        o.buffer_w = width;
        o.buffer_h = height;
    }

    /// Forgets the output's buffers, destroying them. A buffer the compositor
    /// still reads stays valid until it's done (wl_buffer semantics).
    pub fn dropBuffers(h: *Host, o: *Output) !void {
        for (&o.slots) |*s| if (s.buffer != 0) {
            _ = h.handlers.remove(s.buffer);
            try h.conn.request(s.buffer, @backingInt(p.wl_buffer.request.destroy), &.{});
            s.* = .{};
        };
        o.shown = null;
        o.pending = null;
    }

    pub fn setComposition(h: *Host, o: *Output, comp: Composition) !void {
        o.composition = comp;
        if (comp.clear_rgba != o.clear_rgba) {
            o.clear_rgba = comp.clear_rgba;
            if (o.configured()) try h.paintBackground(o);
        }
        if (o.shown) |slot| try h.present(o, slot);
    }

    /// A new frame is in `slot`. Shown at the next frame callback; a frame
    /// still waiting is replaced (and released).
    pub fn frameReady(h: *Host, o: *Output, slot: u8) !void {
        if (slot >= max_slots or o.slots[slot].buffer == 0) return error.BadSlot;
        o.slots[slot].busy = true;
        if (!o.configured() or o.frame_callback != 0) {
            if (o.pending) |old| if (old != slot) h.releaseUnshown(o, old);
            o.pending = slot;
            return;
        }
        try h.present(o, slot);
    }

    /// A frame that never reached the compositor: give it straight back.
    fn releaseUnshown(h: *Host, o: *Output, slot: u8) void {
        o.slots[slot].busy = false;
        if (h.listener) |l| l.released(l.ctx, o, slot);
    }

    fn present(h: *Host, o: *Output, slot: u8) !void {
        const c = &h.conn;
        const comp = o.composition orelse Composition{
            .src = .{ .w = o.buffer_w, .h = o.buffer_h },
            .dst = .{ .w = o.width, .h = o.height },
        };
        // Output pixels to surface-local (logical) coordinates.
        const sx: f64 = if (o.width == 0) 1 else @as(f64, @floatFromInt(o.logical_w)) / @as(f64, @floatFromInt(o.width));
        const sy: f64 = if (o.height == 0) 1 else @as(f64, @floatFromInt(o.logical_h)) / @as(f64, @floatFromInt(o.height));
        const dx: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(comp.dst.x)) * sx));
        const dy: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(comp.dst.y)) * sy));
        const dw: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(comp.dst.w)) * sx))));
        const dh: i32 = @max(1, @as(i32, @intFromFloat(@round(@as(f64, @floatFromInt(comp.dst.h)) * sy))));

        try c.request(o.subsurface, @backingInt(p.wl_subsurface.request.set_position), &.{ .{ .int = dx }, .{ .int = dy } });
        try c.request(o.content_viewport, @backingInt(p.wp_viewport.request.set_source), &.{
            .{ .fixed = wl.fixed(@floatFromInt(comp.src.x)) },
            .{ .fixed = wl.fixed(@floatFromInt(comp.src.y)) },
            .{ .fixed = wl.fixed(@floatFromInt(comp.src.w)) },
            .{ .fixed = wl.fixed(@floatFromInt(comp.src.h)) },
        });
        try c.request(o.content_viewport, @backingInt(p.wp_viewport.request.set_destination), &.{ .{ .int = dw }, .{ .int = dh } });
        try c.request(o.content, @backingInt(p.wl_surface.request.attach), &.{ .{ .object = o.slots[slot].buffer }, .{ .int = 0 }, .{ .int = 0 } });
        try c.request(o.content, @backingInt(p.wl_surface.request.damage_buffer), &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = std.math.maxInt(i32) }, .{ .int = std.math.maxInt(i32) } });
        o.frame_callback = c.newId();
        try c.request(o.content, @backingInt(p.wl_surface.request.frame), &.{.{ .new_id = o.frame_callback }});
        try h.handlers.put(h.gpa, o.frame_callback, .{ .frame = o });
        try c.request(o.content, @backingInt(p.wl_surface.request.commit), &.{});
        // The parent commits too, so the new subsurface position applies.
        try c.request(o.surface, @backingInt(p.wl_surface.request.commit), &.{});
        // The previous buffer stays busy until the compositor releases it.
        o.shown = slot;
    }

    fn dropOutput(h: *Host, o: *Output) !void {
        if (h.listener) |l| l.output_gone(l.ctx, o);
        const c = &h.conn;
        try h.dropBuffers(o);
        if (o.frame_callback != 0) _ = h.handlers.remove(o.frame_callback);
        _ = h.handlers.remove(o.wl_output);
        if (o.layer_surface != 0) {
            _ = h.handlers.remove(o.layer_surface);
            try c.request(o.layer_surface, @backingInt(p.zwlr_layer_surface_v1.request.destroy), &.{});
            try c.request(o.subsurface, @backingInt(p.wl_subsurface.request.destroy), &.{});
            try c.request(o.content_viewport, @backingInt(p.wp_viewport.request.destroy), &.{});
            try c.request(o.background_viewport, @backingInt(p.wp_viewport.request.destroy), &.{});
            try c.request(o.content, @backingInt(p.wl_surface.request.destroy), &.{});
            try c.request(o.surface, @backingInt(p.wl_surface.request.destroy), &.{});
            if (o.background_buffer != 0) try c.request(o.background_buffer, @backingInt(p.wl_buffer.request.destroy), &.{});
        }
        try c.request(o.wl_output, @backingInt(p.wl_output.request.release), &.{});
        h.gpa.destroy(o);
    }

    // ---- buffers ----

    /// A 1x1 XRGB8888 wl_shm buffer of `xrgb`: the background colour where
    /// wp_single_pixel_buffer_manager_v1 is missing.
    fn onePixel(h: *Host, xrgb: u32) !wl.ObjectId {
        const rc = linux.memfd_create("zmural-background", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.MemfdFailed;
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        const px: u32 = xrgb & 0xffffff;
        if (linux.write(fd, std.mem.asBytes(&px), 4) != 4) return error.MemfdFailed;
        return h.addShmBuffer(fd, 4, 1, 1, 4);
    }

    /// An XRGB8888 wl_shm buffer over `fd` (the test pattern, and fallbacks).
    pub fn addShmBuffer(h: *Host, fd: linux.fd_t, size: u32, width: u32, height: u32, stride: u32) !wl.ObjectId {
        const c = &h.conn;
        const pool = c.newId();
        try c.request(h.globals.shm, @backingInt(p.wl_shm.request.create_pool), &.{ .{ .new_id = pool }, .{ .fd = fd }, .{ .int = @intCast(size) } });
        const buffer = c.newId();
        try c.request(pool, @backingInt(p.wl_shm_pool.request.create_buffer), &.{
            .{ .new_id = buffer },        .{ .int = 0 },                .{ .int = @intCast(width) },
            .{ .int = @intCast(height) }, .{ .int = @intCast(stride) }, .{ .uint = p.wl_shm.format_xrgb8888 },
        });
        try c.request(pool, @backingInt(p.wl_shm_pool.request.destroy), &.{});
        return buffer;
    }

    /// A single-plane DMA-BUF as a wl_buffer (`create_immed`: an import the
    /// compositor rejects is a protocol error on the params object, reported
    /// through `wl_display.error`).
    pub fn addDmabuf(h: *Host, fd: linux.fd_t, width: u32, height: u32, fourcc: u32, modifier: u64, offset: u32, stride: u32) !wl.ObjectId {
        if (h.globals.dmabuf == 0) return error.Unsupported;
        const c = &h.conn;
        const params = c.newId();
        try c.request(h.globals.dmabuf, @backingInt(p.zwp_linux_dmabuf_v1.request.create_params), &.{.{ .new_id = params }});
        try c.request(params, @backingInt(p.zwp_linux_buffer_params_v1.request.add), &.{
            .{ .fd = fd },                          .{ .uint = 0 },                   .{ .uint = offset }, .{ .uint = stride },
            .{ .uint = @truncate(modifier >> 32) }, .{ .uint = @truncate(modifier) },
        });
        const buffer = c.newId();
        try c.request(params, @backingInt(p.zwp_linux_buffer_params_v1.request.create_immed), &.{
            .{ .new_id = buffer }, .{ .int = @intCast(width) }, .{ .int = @intCast(height) }, .{ .uint = fourcc }, .{ .uint = 0 },
        });
        try c.request(params, @backingInt(p.zwp_linux_buffer_params_v1.request.destroy), &.{});
        return buffer;
    }
};

/// The canonical monitor ID for a connector: from its EDID when the kernel
/// exposes one (`/sys/class/drm/card*-<connector>/edid`), else the name.
pub fn monitorId(io: std.Io, connector: []const u8) monitor.Id {
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/drm", .{ .iterate = true }) catch return monitor.fromConnector(connector);
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        // "card1-DP-1": skip the card prefix.
        const dash = std.mem.findScalar(u8, entry.name, '-') orelse continue;
        if (!std.mem.startsWith(u8, entry.name, "card") or !std.mem.eql(u8, entry.name[dash + 1 ..], connector)) continue;
        var buf: [2048]u8 = undefined; // base block plus extensions
        var path_buf: [300]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/edid", .{entry.name}) catch continue;
        const blob = dir.readFile(io, path, &buf) catch continue;
        if (monitor.parseEdid(blob)) |edid| return monitor.fromEdid(edid);
    }
    return monitor.fromConnector(connector);
}

test "the host needs layer-shell, DMA-BUF and the basics; the rest is optional" {
    const all: Globals = .{ .compositor = 1, .subcompositor = 2, .layer_shell = 3, .shm = 4, .dmabuf = 5, .viewporter = 6 };
    try std.testing.expectEqual(@as(?[]const u8, null), all.missing());
    var g = all;
    g.dmabuf = 0;
    try std.testing.expectEqualStrings(p.zwp_linux_dmabuf_v1.name, g.missing().?);
    g = all;
    g.layer_shell = 0;
    try std.testing.expectEqualStrings(p.zwlr_layer_shell_v1.name, g.missing().?);
}
