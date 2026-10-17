// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The settings window on Linux: a Wayland window (xdg-shell) drawn with
//! Cairo and Pango (`gui_cairo.zig`) into shared-memory buffers.
//!
//! - Title bar: the desktop's own where it offers one (xdg-decoration: KDE,
//!   Sway...); otherwise (GNOME) zmural draws one, with move, resize,
//!   minimize, maximize and close.
//! - Theme: light or dark and the accent colour from the desktop
//!   (org.freedesktop.appearance, through the XDG settings portal), live.
//! - Pickers: the desktop's own file chooser (XDG FileChooser portal).
//!   Menus and yes/no questions are drawn in the window.
//! - Thumbnails: the desktop's thumbnail cache (~/.cache/thumbnails, what
//!   Dolphin and Files show), else the file itself if it's a PNG, else one
//!   zmural makes (`zmural --still-frame`) and keeps in its own cache.
//! - Start at login: the XDG autostart entry (`os/autostart_linux.zig`).
//!
//! It runs on its own thread inside zmural (`window.zig`); zmural's thread
//! reaches it only through `raise` and `requestClose`.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const xdg = zmural.os.xdg;
const wl = zmural.os.wayland;
const dbus = zmural.os.dbus;
const gui = @import("gui.zig");
const app_mod = @import("app.zig");
const app = &app_mod.app;
const Env = @import("env.zig").Env;
const keymap = @import("keymap.zig");
const Rect = gui.Rect;
const key = gui.key;

pub const Client = zmural.sdk.control_client_linux.Client;

pub const autostart_title = "Start at login";
pub const library_hint = "Add a folder of videos or pictures, or put them in Wallpapers in your Videos folder.";

const log = std.log.scoped(.settings);

/// Our own title bar's height (only when the desktop doesn't draw one).
const title_h: f32 = 40;
/// Where a press starts a resize (our own frame only).
const edge_px: f32 = 6;

// Opcodes, from the protocol XML (wayland.xml, xdg-shell, xdg-decoration,
// cursor-shape-v1).
const op = struct {
    const compositor_create_surface = 0;
    const surface_destroy = 0;
    const surface_attach = 1;
    const surface_frame = 3;
    const surface_commit = 6;
    const surface_set_buffer_scale = 8;
    const surface_damage_buffer = 9;
    const surface_ev_preferred_buffer_scale = 2;
    const shm_create_pool = 0;
    const pool_create_buffer = 0;
    const pool_destroy = 1;
    const buffer_destroy = 0;
    const buffer_ev_release = 0;
    const wm_base_get_xdg_surface = 2;
    const wm_base_pong = 3;
    const wm_base_ev_ping = 0;
    const xdg_surface_get_toplevel = 1;
    const xdg_surface_ack_configure = 4;
    const xdg_surface_ev_configure = 0;
    const toplevel_set_title = 2;
    const toplevel_set_app_id = 3;
    const toplevel_move = 5;
    const toplevel_resize = 6;
    const toplevel_set_min_size = 8;
    const toplevel_set_maximized = 9;
    const toplevel_unset_maximized = 10;
    const toplevel_set_minimized = 13;
    const toplevel_ev_configure = 0;
    const toplevel_ev_close = 1;
    const deco_mgr_get = 1;
    const deco_set_mode = 1;
    const deco_ev_configure = 0;
    const seat_get_pointer = 0;
    const seat_get_keyboard = 1;
    const seat_ev_capabilities = 0;
    const keyboard_release = 0;
    const keyboard_ev_keymap = 0;
    const keyboard_ev_leave = 2;
    const keyboard_ev_key = 3;
    const keyboard_ev_modifiers = 4;
    const keyboard_ev_repeat_info = 5;
    const pointer_ev_enter = 0;
    const pointer_ev_leave = 1;
    const pointer_ev_motion = 2;
    const pointer_ev_button = 3;
    const pointer_ev_axis = 4;
    const cursor_mgr_get_pointer = 1;
    const cursor_dev_set_shape = 1;
    const registry_ev_global = 0;
    const display_ev_error = 0;
    const display_ev_delete_id = 1;
    const callback_ev_done = 0;
    const activation_get_token = 1;
    const activation_activate = 2;
    const token_set_app_id = 1;
    const token_set_surface = 2;
    const token_commit = 3;
    const token_destroy = 4;
    const token_ev_done = 0;
};

/// One settings window per user: a second launch hands its activation token
/// to the first over the session bus, and the first raises itself.
const btn_left = 0x110;
const btn_right = 0x111;
const shm_argb8888 = 0;

const Buffer = struct {
    id: wl.ObjectId = 0,
    map: []align(std.heap.page_size_min) u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    busy: bool = false,
};

const Overlay = union(enum) {
    none,
    menu: struct { items: []const []const u8, tile: usize, at: gui.Point },
    confirm: struct { question: []const u8, action: app_mod.Action },
};

const State = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    /// A running `zmural-console import` (`startImport`).
    import_pid: ?linux.pid_t = null,
    /// `xdg-open`s not yet reaped (`open`, `checkOpeners`).
    openers: [4]Opener = @splat(.{}),
    test_pick: ?[]const u8 = null,
    test_controls: ?[]const u8 = null,
    /// What was last written there, so an unchanged frame writes nothing.
    controls_hash: u64 = 0,
    conn: wl.Conn = undefined,
    registry: wl.ObjectId = 0,
    compositor: wl.ObjectId = 0,
    compositor_version: u32 = 0,
    shm: wl.ObjectId = 0,
    wm_base: wl.ObjectId = 0,
    deco_mgr: wl.ObjectId = 0,
    seat: wl.ObjectId = 0,
    pointer: wl.ObjectId = 0,
    keyboard: wl.ObjectId = 0,
    shift: bool = false,
    /// Which code is which key, from the compositor's keymap.
    keys: keymap.Map = .standard(),
    /// The held key that repeats (Tab, an arrow), and when it next does.
    repeat_key: u32 = 0,
    repeat_at_ms: u64 = 0,
    repeat_delay_ms: u32 = 400,
    repeat_every_ms: u32 = 40,
    /// Keys pressed and not yet drawn, oldest first.
    key_queue: [32]gui.Keys = undefined,
    key_queue_len: usize = 0,
    /// The focus before a menu or question opened, given back when it closes.
    return_focus: u64 = 0,
    cursor_mgr: wl.ObjectId = 0,
    cursor_dev: wl.ObjectId = 0,
    /// xdg_activation_v1, and the token we asked it for (to raise ourselves).
    activation: wl.ObjectId = 0,
    token_req: wl.ObjectId = 0,
    surface: wl.ObjectId = 0,
    xdg_surface: wl.ObjectId = 0,
    toplevel: wl.ObjectId = 0,
    decoration: wl.ObjectId = 0,
    sync_cb: wl.ObjectId = 0,
    synced: bool = false,

    /// The desktop draws the title bar.
    server_decorations: bool = false,
    configured: bool = false,
    /// Size in DIPs, from the last configure.
    width: u32 = app_mod.window_w,
    height: u32 = app_mod.window_h,
    pending_w: u32 = 0,
    pending_h: u32 = 0,
    pending_maximized: bool = false,
    maximized: bool = false,
    scale: i32 = 1,
    buffers: [2]Buffer = .{ .{}, .{} },
    need_redraw: bool = true,
    /// The desktop's light/dark or accent changed: re-read on the next loop turn.
    theme_dirty: bool = false,
    animating: bool = false,
    quit: bool = false,
    /// The serial of the last button press (for move/resize/cursor).
    press_serial: u32 = 0,
    enter_serial: u32 = 0,

    bus: ?dbus.Conn = null,
    /// The pending FileChooser request: its handle and what it's for.
    pick_handle: [128]u8 = undefined,
    pick_handle_len: usize = 0,
    pick_kind: app_mod.PickKind = .wallpaper,

    overlay: Overlay = .none,
    /// Thumbnails asked for, made between frames.
    thumb_queue: std.ArrayList([]u8) = .empty,
    /// Thumbnails nobody had: waiting for a `zmural --still-frame`, and those running.
    make_queue: std.ArrayList([]u8) = .empty,
    makers: [max_makers]?Maker = @splat(null),

    runtime_dir: []const u8 = "",
    home: []const u8 = "/",
    config_home: ?[]const u8 = null,
    cache_home: ?[]const u8 = null,
    exe_dir: []const u8 = "",
    force_dark: ?bool = null,
    last_poll_ms: u64 = 0,
};

var st: State = .{};

/// `zmural --still-frame` processes making thumbnails at once: a few, so a
/// folder of videos fills in quickly without taking every core.
const max_makers = 3;

const Maker = struct {
    pid: linux.pid_t,
    /// The tile's key (owned).
    path: []u8,
    /// Where the thumbnail is written (owned).
    out: [:0]u8,
};

/// Wakes the window's loop from zmural's thread: an eventfd, made once.
var wake_fd: linux.fd_t = -1;
/// What the wake is for. `raise_token` is written only while `want_raise`
/// is clear, and read before it is cleared.
var pending: std.atomic.Value(u8) = .init(0);
const want_raise: u8 = 1;
const want_close: u8 = 2;
var raise_token: [256]u8 = undefined;
var raise_token_len: usize = 0;

/// Before `run`, on zmural's thread.
pub fn prepare() !void {
    if (wake_fd < 0) {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.NoEventFd;
        wake_fd = @intCast(rc);
    }
    // Nothing left over from the last window.
    pending.store(0, .release);
    var count: [8]u8 = undefined;
    _ = linux.read(wake_fd, &count, count.len);
}

fn wake() void {
    const one: u64 = 1;
    _ = linux.write(wake_fd, std.mem.asBytes(&one), 8);
}

/// Brings the open window to the front. From zmural's thread.
pub fn raise(token: []const u8) void {
    if (pending.load(.acquire) & want_raise == 0) {
        raise_token_len = @min(token.len, raise_token.len);
        @memcpy(raise_token[0..raise_token_len], token[0..raise_token_len]);
        _ = pending.fetchOr(want_raise, .release);
    }
    wake();
}

/// Asks the window to close. From zmural's thread.
pub fn requestClose() void {
    _ = pending.fetchOr(want_close, .release);
    wake();
}

/// The window's thread, woken.
fn onWake() void {
    var count: [8]u8 = undefined;
    _ = linux.read(wake_fd, &count, count.len);
    const what = pending.load(.acquire);
    if (what & want_raise != 0) {
        var token_buf: [256]u8 = undefined;
        const token = token_buf[0..raise_token_len];
        @memcpy(token, raise_token[0..raise_token_len]);
        _ = pending.fetchAnd(~want_raise, .release);
        raiseNow(token) catch |err| log.warn("can't raise the window: {s}", .{@errorName(err)});
    }
    if (what & want_close != 0) st.quit = true;
}

/// The window, from open to close, on its own thread inside zmural.
/// `token`: an activation token (xdg-activation) from whoever asked for the
/// window (the tray host, an app launcher), or empty.
pub fn run(env: Env, token: []const u8) !void {
    st = .{};
    const gpa = env.gpa;
    st.gpa = gpa;
    st.io = env.io;
    st.test_pick = env.test_pick;
    st.test_controls = env.test_controls;
    gui.names_on = env.test_controls != null;
    st.runtime_dir = env.runtime_dir;
    st.home = env.home;
    st.config_home = env.config_home;
    st.cache_home = env.cache_home;
    st.exe_dir = env.exe_dir;
    st.force_dark = env.force_dark;

    app_mod.init(gpa);
    defer app_mod.deinit();
    app.autostart = autostartOn();
    app.log_path = env.log_path;
    app.open_on_welcome = env.welcome;

    // The session bus: file pickers and the desktop's theme, through portals.
    st.bus = dbus.Conn.session(env.dbus_address, st.runtime_dir) catch null;
    if (st.bus) |*b| {
        b.hook = .{ .ctx = &st, .func = onBusMessage };
        b.addMatch("type='signal',interface='org.freedesktop.portal.Request',member='Response'") catch {}; // zsnag:ok — without it pickers never answer, which the user sees
        b.addMatch("type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'") catch {}; // zsnag:ok — theme changes then need a restart
    }
    defer if (st.bus) |*b| b.close();

    st.conn = wl.Conn.connect(gpa, st.runtime_dir, env.wayland_display) catch |err| {
        log.err("can't reach the Wayland compositor: {s}", .{@errorName(err)});
        return error.NoCompositor;
    };
    defer st.conn.close();
    defer {
        for (&st.buffers) |*buf| dropBuffer(buf);
        for (st.thumb_queue.items) |p| gpa.free(p);
        st.thumb_queue.deinit(gpa);
        stopMakers();
    }
    try setUpWindow();
    if (token.len > 0) activate(token) catch |err| log.warn("can't take focus: {s}", .{@errorName(err)});

    const backend = gui.Backend.init(st.runtime_dir) catch |err| {
        log.err("can't load Cairo/Pango: {s}", .{@errorName(err)});
        return error.NoCairo;
    };
    app.ui = .init(gpa, backend, theme());
    defer app.ui.deinit();
    // Defers run last-first: the thumbnails are Cairo surfaces and must go
    // before the backend unloads Cairo (`app_mod.deinit` above runs after it).
    defer app_mod.dropThumbs();

    app_mod.connect();
    st.last_poll_ms = now();
    log.info("window: open", .{});
    try loop();
}

// ---- the window ------------------------------------------------------------------------

fn setUpWindow() !void {
    const c = &st.conn;
    st.registry = try c.getRegistry();
    try roundtrip();
    if (st.compositor == 0 or st.shm == 0 or st.wm_base == 0) {
        log.err("the compositor lacks wl_compositor, wl_shm or xdg_wm_base", .{});
        return error.Unsupported;
    }
    st.surface = c.newId();
    try c.request(st.compositor, op.compositor_create_surface, &.{.{ .new_id = st.surface }});
    st.xdg_surface = c.newId();
    try c.request(st.wm_base, op.wm_base_get_xdg_surface, &.{ .{ .new_id = st.xdg_surface }, .{ .object = st.surface } });
    st.toplevel = c.newId();
    try c.request(st.xdg_surface, op.xdg_surface_get_toplevel, &.{.{ .new_id = st.toplevel }});
    try c.request(st.toplevel, op.toplevel_set_title, &.{.{ .string = "zmural" }});
    // Matches org.zmural.Settings.desktop, for the icon and the task bar.
    try c.request(st.toplevel, op.toplevel_set_app_id, &.{.{ .string = "org.zmural.Settings" }});
    try c.request(st.toplevel, op.toplevel_set_min_size, &.{ .{ .int = app_mod.min_w }, .{ .int = app_mod.min_h } });
    if (st.deco_mgr != 0) {
        st.decoration = c.newId();
        try c.request(st.deco_mgr, op.deco_mgr_get, &.{ .{ .new_id = st.decoration }, .{ .object = st.toplevel } });
        try c.request(st.decoration, op.deco_set_mode, &.{.{ .uint = 2 }}); // server side
    }
    try c.request(st.surface, op.surface_commit, &.{});
    while (!st.configured) try dispatchBlocking();
}

fn roundtrip() !void {
    st.synced = false;
    st.sync_cb = try st.conn.sync();
    try st.conn.flush();
    while (!st.synced) try dispatchBlocking();
}

fn dispatchBlocking() !void {
    try st.conn.flush();
    try st.conn.fill();
    try dispatch();
}

fn dispatch() !void {
    while (try st.conn.next()) |ev| {
        var e = ev;
        try handle(&e);
    }
}

fn handle(e: *wl.Event) !void {
    const c = &st.conn;
    const o = e.object;
    if (o == wl.display_id) {
        switch (e.opcode) {
            op.display_ev_error => {
                const obj = try e.args.object();
                const code = try e.args.uint();
                log.err("compositor: protocol error {d} on {d}: {s}", .{ code, obj, try e.args.string() orelse "" });
                return error.ProtocolError;
            },
            op.display_ev_delete_id => c.deleteId(try e.args.uint()),
            else => {},
        }
    } else if (o == st.sync_cb and e.opcode == op.callback_ev_done) {
        st.synced = true;
    } else if (o == st.registry and e.opcode == op.registry_ev_global) {
        const name = try e.args.uint();
        const iface = try e.args.string() orelse return;
        const version = try e.args.uint();
        const eql = std.mem.eql;
        if (eql(u8, iface, "wl_compositor")) {
            // v6 tells us the preferred buffer scale directly.
            st.compositor_version = @min(version, 6);
            st.compositor = try c.bind(st.registry, name, iface, st.compositor_version);
        } else if (eql(u8, iface, "wl_shm")) {
            st.shm = try c.bind(st.registry, name, iface, 1);
        } else if (eql(u8, iface, "xdg_wm_base")) {
            st.wm_base = try c.bind(st.registry, name, iface, 1);
        } else if (eql(u8, iface, "zxdg_decoration_manager_v1")) {
            st.deco_mgr = try c.bind(st.registry, name, iface, 1);
        } else if (eql(u8, iface, "wl_seat") and st.seat == 0) {
            st.seat = try c.bind(st.registry, name, iface, @min(version, 5));
        } else if (eql(u8, iface, "wp_cursor_shape_manager_v1")) {
            st.cursor_mgr = try c.bind(st.registry, name, iface, 1);
        } else if (eql(u8, iface, "xdg_activation_v1")) {
            st.activation = try c.bind(st.registry, name, iface, 1);
        }
    } else if (o == st.token_req and o != 0 and e.opcode == op.token_ev_done) {
        const token = try e.args.string() orelse "";
        try activate(token);
        try c.request(st.token_req, op.token_destroy, &.{});
        st.token_req = 0;
    } else if (o == st.wm_base and e.opcode == op.wm_base_ev_ping) {
        try c.request(st.wm_base, op.wm_base_pong, &.{.{ .uint = try e.args.uint() }});
    } else if (o == st.xdg_surface and e.opcode == op.xdg_surface_ev_configure) {
        try c.request(st.xdg_surface, op.xdg_surface_ack_configure, &.{.{ .uint = try e.args.uint() }});
        if (st.pending_w > 0 and st.pending_h > 0) {
            st.width = st.pending_w;
            st.height = st.pending_h;
        }
        st.maximized = st.pending_maximized;
        st.configured = true;
        st.need_redraw = true;
    } else if (o == st.toplevel) {
        switch (e.opcode) {
            op.toplevel_ev_configure => {
                const w_ = try e.args.int();
                const h_ = try e.args.int();
                st.pending_w = @intCast(@max(0, w_));
                st.pending_h = @intCast(@max(0, h_));
                const states = try e.args.array();
                st.pending_maximized = false;
                var i: usize = 0;
                while (i + 4 <= states.len) : (i += 4) {
                    if (std.mem.readInt(u32, states[i..][0..4], .native) == 1) st.pending_maximized = true;
                }
            },
            op.toplevel_ev_close => st.quit = true,
            else => {},
        }
    } else if (o == st.decoration and e.opcode == op.deco_ev_configure) {
        st.server_decorations = (try e.args.uint()) == 2;
        st.need_redraw = true;
    } else if (o == st.surface and e.opcode == op.surface_ev_preferred_buffer_scale) {
        st.scale = @max(1, try e.args.int());
        st.need_redraw = true;
    } else if (o == st.seat and e.opcode == op.seat_ev_capabilities) {
        const caps = try e.args.uint();
        if (caps & 1 == 0 and st.pointer != 0) {
            // The last mouse went away: let go of the pointer, so a new one
            // is made when a mouse comes back (unplugged, or a virtual one).
            if (st.cursor_dev != 0) try c.request(st.cursor_dev, 0, &.{}); // wp_cursor_shape_device_v1.destroy
            try c.request(st.pointer, 1, &.{}); // wl_pointer.release (v3+)
            st.cursor_dev = 0;
            st.pointer = 0;
            app.ui.mouse = .{ .x = -1, .y = -1 };
        }
        if (caps & 2 == 0 and st.keyboard != 0) {
            try c.request(st.keyboard, op.keyboard_release, &.{}); // v3+
            st.keyboard = 0;
            st.repeat_key = 0;
        }
        if (caps & 2 != 0 and st.keyboard == 0) {
            st.keyboard = c.newId();
            try c.request(st.seat, op.seat_get_keyboard, &.{.{ .new_id = st.keyboard }});
        }
        if (caps & 1 != 0 and st.pointer == 0) {
            st.pointer = c.newId();
            try c.request(st.seat, op.seat_get_pointer, &.{.{ .new_id = st.pointer }});
            if (st.cursor_mgr != 0) {
                st.cursor_dev = c.newId();
                try c.request(st.cursor_mgr, op.cursor_mgr_get_pointer, &.{ .{ .new_id = st.cursor_dev }, .{ .object = st.pointer } });
            }
        }
    } else if (o == st.pointer) {
        try onPointer(e);
    } else if (o == st.keyboard and o != 0) {
        try onKeyboard(e);
    } else {
        for (&st.buffers) |*b| if (o == b.id and e.opcode == op.buffer_ev_release) {
            b.busy = false;
        };
    }
}

fn onPointer(e: *wl.Event) !void {
    const ui = &app.ui;
    switch (e.opcode) {
        op.pointer_ev_enter => {
            st.enter_serial = try e.args.uint();
            _ = try e.args.object();
            ui.mouse = .{ .x = fixedToF(try e.args.int()), .y = fixedToF(try e.args.int()) };
            if (st.cursor_dev != 0) try st.conn.request(st.cursor_dev, op.cursor_dev_set_shape, &.{ .{ .uint = st.enter_serial }, .{ .uint = 1 } }); // default
        },
        op.pointer_ev_leave => ui.mouse = .{ .x = -1, .y = -1 },
        op.pointer_ev_motion => {
            _ = try e.args.uint();
            ui.mouse = .{ .x = fixedToF(try e.args.int()), .y = fixedToF(try e.args.int()) };
        },
        op.pointer_ev_button => {
            const serial = try e.args.uint();
            _ = try e.args.uint();
            const button = try e.args.uint();
            const pressed = (try e.args.uint()) == 1;
            if (button == btn_left) {
                if (pressed) {
                    st.press_serial = serial;
                    if (try frameGrab()) return; // a move or resize took the press
                    ui.down = true;
                    ui.pressed = true;
                } else {
                    ui.down = false;
                    ui.released = true;
                }
            } else if (button == btn_right and !pressed) {
                ui.right_released = true;
            }
        },
        op.pointer_ev_axis => {
            _ = try e.args.uint();
            const axis = try e.args.uint();
            // Windows' wheel units: 120 per notch, positive is up. Wayland
            // sends about 10-15 per notch, positive is down.
            if (axis == 0) ui.wheel -= fixedToF(try e.args.int()) * 10;
        },
        else => return,
    }
    st.need_redraw = true;
}

fn onKeyboard(e: *wl.Event) !void {
    switch (e.opcode) {
        // Which code is which key (`keymap.zig`).
        op.keyboard_ev_keymap => {
            _ = try e.args.uint(); // format: xkb v1
            const fd = try e.args.fd();
            defer _ = linux.close(fd);
            const size = try e.args.uint();
            const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
            if (linux.errno(rc) != .SUCCESS) return;
            const text: [*]const u8 = @ptrFromInt(rc); // zsnag:ok — mmap's address
            defer _ = linux.munmap(text, size);
            st.keys = keymap.Map.parse(st.gpa, std.mem.sliceTo(text[0..size], 0));
        },
        op.keyboard_ev_leave => st.repeat_key = 0,
        op.keyboard_ev_key => {
            _ = try e.args.uint();
            _ = try e.args.uint();
            const code = try e.args.uint();
            const down = (try e.args.uint()) == 1;
            const k = st.keys.get(code);
            if (k == .shift) return; // `modifiers` says
            if (!down) {
                if (code == st.repeat_key) st.repeat_key = 0;
                return;
            }
            if (!keyDown(k)) return;
            const repeats = switch (k) {
                .tab, .back_tab, .up, .down, .left, .right => true,
                else => false,
            };
            st.repeat_key = if (repeats) code else 0;
            st.repeat_at_ms = now() + st.repeat_delay_ms;
        },
        op.keyboard_ev_modifiers => {
            _ = try e.args.uint();
            // Shift is the first modifier in every standard keymap.
            st.shift = (try e.args.uint()) & 1 != 0;
        },
        op.keyboard_ev_repeat_info => {
            const rate = try e.args.int();
            const delay = try e.args.int();
            st.repeat_every_ms = if (rate > 0) @intCast(@max(1, @divTrunc(1000, rate))) else 0;
            st.repeat_delay_ms = @intCast(@max(0, delay));
        },
        else => {},
    }
}

/// A pressed key, queued for a frame of its own (keys can arrive faster
/// than frames are drawn, and two Tabs in one frame would count once).
/// False if zmural doesn't use it.
fn keyDown(k: keymap.Key) bool {
    var one: gui.Keys = .{};
    const keys = &one;
    switch (k) {
        .tab => if (st.shift) {
            keys.shift_tab = true;
        } else {
            keys.tab = true;
        },
        .back_tab => keys.shift_tab = true,
        .activate => keys.activate = true,
        .escape => keys.escape = true,
        .up => keys.up = true,
        .down => keys.down = true,
        .left => keys.left = true,
        .right => keys.right = true,
        .home => keys.home = true,
        .end => keys.end = true,
        .menu => keys.menu = true,
        .f10 => if (st.shift) {
            keys.menu = true;
        } else return false,
        .none, .shift => return false,
    }
    if (st.key_queue_len < st.key_queue.len) {
        st.key_queue[st.key_queue_len] = one;
        st.key_queue_len += 1;
    }
    st.need_redraw = true;
    return true;
}

/// A held Tab or arrow repeats at the rate the desktop sets.
fn repeatKey() void {
    if (st.repeat_key == 0 or st.repeat_every_ms == 0) return;
    const t = now();
    if (t < st.repeat_at_ms) return;
    _ = keyDown(st.keys.get(st.repeat_key));
    st.repeat_at_ms = t + st.repeat_every_ms;
}

fn fixedToF(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 256;
}

/// Our own frame (GNOME): a press on the title bar moves the window, one
/// on the edge resizes it. True if it did.
fn frameGrab() !bool {
    if (st.server_decorations or st.maximized) return false;
    const m = app.ui.mouse;
    const w_: f32 = @floatFromInt(st.width);
    const h_: f32 = @floatFromInt(st.height);
    var edges: u32 = 0;
    if (m.y < edge_px) edges |= 1;
    if (m.y > h_ - edge_px) edges |= 2;
    if (m.x < edge_px) edges |= 4;
    if (m.x > w_ - edge_px) edges |= 8;
    if (edges != 0) {
        try st.conn.request(st.toplevel, op.toplevel_resize, &.{ .{ .object = st.seat }, .{ .uint = st.press_serial }, .{ .uint = edges } });
        return true;
    }
    if (m.y < title_h and m.x < w_ - 3 * 46 and !overChromeButton(m)) {
        try st.conn.request(st.toplevel, op.toplevel_move, &.{ .{ .object = st.seat }, .{ .uint = st.press_serial } });
        return true;
    }
    return false;
}

fn overChromeButton(m: gui.Point) bool {
    return m.y < title_h and m.x >= @as(f32, @floatFromInt(st.width)) - 3 * 46;
}

// ---- the loop --------------------------------------------------------------------------

fn loop() !void {
    while (!st.quit) {
        if (st.need_redraw) try render();
        // One thumbnail per turn, so the window stays responsive.
        if (st.thumb_queue.pop()) |path| {
            makeThumb(path);
            st.gpa.free(path);
        }
        pumpMakers();
        try st.conn.flush();
        var fds: [3]linux.pollfd = undefined;
        fds[0] = .{ .fd = st.conn.fd, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = wake_fd, .events = linux.POLL.IN, .revents = 0 };
        var n: usize = 2;
        if (st.bus) |b| {
            fds[2] = .{ .fd = b.fd, .events = linux.POLL.IN, .revents = 0 };
            n = 3;
        }
        const t = now();
        const until_poll: i32 = @intCast(@min(app_mod.poll_ms, (st.last_poll_ms + app_mod.poll_ms) -| t));
        var timeout: i32 = if (st.animating or st.thumb_queue.items.len > 0) @min(16, until_poll) else until_poll;
        if (makersBusy()) timeout = @min(timeout, 100);
        if (st.repeat_key != 0) timeout = @min(timeout, @as(i32, @intCast(@min(1000, st.repeat_at_ms -| t))));
        const rc = linux.poll(&fds, n, timeout);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }
        if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0 and fds[0].revents & linux.POLL.IN == 0) return;
        if (fds[0].revents != 0) {
            try st.conn.fill();
            try dispatch();
        }
        if (fds[1].revents != 0) onWake();
        if (n == 3 and fds[2].revents != 0) {
            if (st.bus) |*b| b.drain() catch {
                b.close();
                st.bus = null;
            };
        }
        if (now() >= st.last_poll_ms + app_mod.poll_ms) {
            st.last_poll_ms = now();
            app_mod.onPoll();
            checkOpeners();
        }
        repeatKey();
        if (st.theme_dirty) {
            st.theme_dirty = false;
            app.ui.pal = .build(theme());
            redraw();
        }
        if (st.animating) st.need_redraw = true;
    }
}

fn render() !void {
    if (!st.configured) return;
    const scale: u32 = @intCast(st.scale);
    const pw = st.width * scale;
    const ph = st.height * scale;
    const buf = for (&st.buffers) |*b| {
        if (!b.busy) break b;
    } else return; // both on screen still: the next release redraws
    if (buf.width != pw or buf.height != ph) {
        dropBuffer(buf);
        try makeBuffer(buf, pw, ph);
    }
    app.ui.b.setTarget(buf.map.ptr, pw, ph, pw * 4, @floatFromInt(scale));
    st.need_redraw = false;
    // One queued key per frame.
    if (st.key_queue_len > 0) {
        app.ui.keys = st.key_queue[0];
        std.mem.copyForwards(gui.Keys, st.key_queue[0 .. st.key_queue_len - 1], st.key_queue[1..st.key_queue_len]);
        st.key_queue_len -= 1;
        if (st.key_queue_len > 0) st.need_redraw = true;
    }
    app_mod.frame();
    if (st.test_controls) |path| writeControls(path);
    const c = &st.conn;
    try c.request(st.surface, op.surface_attach, &.{ .{ .object = buf.id }, .{ .int = 0 }, .{ .int = 0 } });
    if (st.compositor_version >= 3) try c.request(st.surface, op.surface_set_buffer_scale, &.{.{ .int = st.scale }});
    try c.request(st.surface, op.surface_damage_buffer, &.{ .{ .int = 0 }, .{ .int = 0 }, .{ .int = std.math.maxInt(i32) }, .{ .int = std.math.maxInt(i32) } });
    try c.request(st.surface, op.surface_commit, &.{});
    buf.busy = true;
}

/// Testing aid: where each control is, for a rig to click (`gui.writeDrawn`).
/// Replaced whole (a temp file renamed), so a reader never sees half of it.
fn writeControls(path: []const u8) void {
    var out: std.Io.Writer.Allocating = .init(st.gpa);
    defer out.deinit();
    gui.writeDrawn(&app.ui, &out.writer) catch return;
    const text = out.written();
    const h = std.hash.Wyhash.hash(0, text);
    if (h == st.controls_hash) return;
    st.controls_hash = h;
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;
    const cwd = std.Io.Dir.cwd();
    cwd.writeFile(st.io, .{ .sub_path = tmp, .data = text }) catch return;
    cwd.rename(tmp, cwd, path, st.io) catch {}; // zsnag:ok — testing aid; the next frame tries again
}

fn makeBuffer(buf: *Buffer, width: u32, height: u32) !void {
    const size = width * height * 4;
    const rc = linux.memfd_create("zmural-settings", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return error.MemfdFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, size)) != .SUCCESS) return error.MemfdFailed;
    const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(addr) != .SUCCESS) return error.MmapFailed;
    buf.map = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(addr))[0..size];
    const c = &st.conn;
    const pool = c.newId();
    try c.request(st.shm, op.shm_create_pool, &.{ .{ .new_id = pool }, .{ .fd = fd }, .{ .int = @intCast(size) } });
    buf.id = c.newId();
    try c.request(pool, op.pool_create_buffer, &.{
        .{ .new_id = buf.id },        .{ .int = 0 },                   .{ .int = @intCast(width) },
        .{ .int = @intCast(height) }, .{ .int = @intCast(width * 4) }, .{ .uint = shm_argb8888 },
    });
    try c.request(pool, op.pool_destroy, &.{});
    buf.width = width;
    buf.height = height;
    buf.busy = false;
}

fn dropBuffer(buf: *Buffer) void {
    if (buf.id != 0) st.conn.request(buf.id, op.buffer_destroy, &.{}) catch {}; // zsnag:ok — the connection is going anyway if this fails
    if (buf.map.len > 0) _ = linux.munmap(buf.map.ptr, buf.map.len);
    buf.* = .{};
}

// ---- what the app asks of the platform ------------------------------------------------

pub fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub fn redraw() void {
    st.need_redraw = true;
}

pub fn wantAnimation(on: bool) void {
    st.animating = on;
}

pub fn chromeHeight() f32 {
    return if (st.server_decorations) 0 else title_h;
}

/// Our own title bar, where the desktop doesn't draw one.
pub fn drawChrome() void {
    if (st.server_decorations) return;
    const ui = &app.ui;
    const p = ui.pal;
    const w_ = ui.size.x;
    ui.text(.{ .x = 16, .y = 0, .w = 200, .h = title_h }, "zmural", .caption, .left, p.text2);
    const buttons = [_]struct { gui.Icon, u8 }{ .{ .minimize, 0 }, .{ if (st.maximized) .fit else .maximize, 1 }, .{ .close, 2 } };
    for (buttons, 0..) |b, i| {
        const r: Rect = .{ .x = w_ - 46 * @as(f32, @floatFromInt(3 - i)), .y = 0, .w = 46, .h = title_h };
        const in = ui.interact(key("chrome", i), r);
        const hover = ui.anim(key("chrome-hover", i), if (in.hovered) 1 else 0);
        const bg = if (b[1] == 2) gui.rgba(0xC42B1CFF) else p.subtle_hover;
        ui.fill(r, 0, gui.alpha(bg, hover));
        ui.glyph(r, b[0], .icon, if (b[1] == 2 and hover > 0.5) gui.rgba(0xFFFFFFFF) else p.text);
        if (in.clicked) switch (b[1]) {
            0 => st.conn.request(st.toplevel, op.toplevel_set_minimized, &.{}) catch {}, // zsnag:ok — a lost request just leaves the window as it is
            1 => st.conn.request(st.toplevel, if (st.maximized) op.toplevel_unset_maximized else op.toplevel_set_maximized, &.{}) catch {}, // zsnag:ok — as above
            else => st.quit = true,
        };
    }
}

pub fn modal() bool {
    return st.overlay != .none;
}

/// The in-window menu or question, over everything else.
pub fn drawOverlay() void {
    const ui = &app.ui;
    const p = ui.pal;
    if (st.overlay != .none and ui.keys.escape) {
        closeOverlay();
        return redraw();
    }
    switch (st.overlay) {
        .none => {},
        .menu => |m| {
            const item_h: f32 = 36;
            var mw: f32 = 160;
            for (m.items) |it| mw = @max(mw, ui.measure(it, .body) + 48);
            const h = item_h * @as(f32, @floatFromInt(m.items.len)) + 8;
            const r: Rect = .{ .x = @min(m.at.x, ui.size.x - mw - 8), .y = @min(m.at.y, ui.size.y - h - 8), .w = mw, .h = h };
            ui.fill(r.inset(-1, -1), 8, gui.rgba(0x00000030));
            ui.fill(r, 8, if (p.dark) gui.rgba(0x2C2C2CFF) else gui.rgba(0xF9F9F9FF));
            ui.stroke(r, 8, p.control_stroke, 1);
            for (m.items, 0..) |it, i| {
                const ir: Rect = .{ .x = r.x + 4, .y = r.y + 4 + item_h * @as(f32, @floatFromInt(i)), .w = r.w - 8, .h = item_h };
                ui.label = it;
                const in = ui.interact(key("menu", i), ir);
                ui.label = "";
                if (in.hovered) ui.fill(ir, 4, p.subtle_hover);
                ui.text(.{ .x = ir.x + 12, .y = ir.y, .w = ir.w - 24, .h = ir.h }, it, .body, .left, p.text);
                if (in.clicked) {
                    closeOverlay();
                    app_mod.menuChosen(m.tile, i);
                    return;
                }
            }
            // A press anywhere else closes it.
            if (ui.pressed and !r.contains(ui.mouse)) closeOverlay();
        },
        .confirm => |cf| {
            ui.fill(.{ .x = 0, .y = 0, .w = ui.size.x, .h = ui.size.y }, 0, gui.rgba(0x00000066));
            const dialog_w: f32 = 440;
            const text_w = dialog_w - 48;
            // The question's paragraphs wrap to the dialog's width, and the
            // dialog grows to fit them.
            const text_h = questionRows(cf.question, text_w, null);
            const h = @max(188, 24 + text_h + 24 + 64);
            const r: Rect = .{ .x = (ui.size.x - dialog_w) / 2, .y = (ui.size.y - h) / 2, .w = dialog_w, .h = h };
            ui.fill(r, 8, if (p.dark) gui.rgba(0x2B2B2BFF) else gui.rgba(0xFFFFFFFF));
            ui.stroke(r, 8, p.control_stroke, 1);
            _ = questionRows(cf.question, text_w, .{ .x = r.x + 24, .y = r.y + 24 });
            const bar: Rect = .{ .x = r.x, .y = r.bottom() - 64, .w = r.w, .h = 64 };
            ui.fill(bar, 8, p.card);
            const yes: Rect = .{ .x = r.x + 24, .y = bar.y + 16, .w = (r.w - 56) / 2, .h = 32 };
            const no: Rect = .{ .x = yes.right() + 8, .y = yes.y, .w = yes.w, .h = 32 };
            // Both drawn before either acts: the frame a press ends on stays
            // on screen until the next, and must not lose a button.
            const yes_pressed = ui.button(key("confirm-yes", 0), yes, "Yes", null, .accent);
            const no_pressed = ui.button(key("confirm-no", 0), no, "No", null, .standard);
            if (yes_pressed) {
                closeOverlay();
                app_mod.confirmed(cf.action);
            } else if (no_pressed) {
                closeOverlay();
            }
        },
    }
    if (st.overlay != .none) redraw();
}

const question_row_h: f32 = 22;
const question_gap: f32 = 10;

/// Lays out a confirm question: paragraphs split by a blank line, the first
/// in bold, each wrapped at spaces to `width`. Draws it at `at` when given;
/// returns its height either way.
fn questionRows(question: []const u8, width: f32, at: ?gui.Point) f32 {
    const ui = &app.ui;
    var paras = std.mem.splitSequence(u8, question, "\n\n");
    var y: f32 = 0;
    var first = true;
    while (paras.next()) |para| {
        if (!first) y += question_gap;
        const font: gui.Font = if (first) .body_strong else .body;
        var rest = para;
        while (rest.len > 0) {
            const end = wrapEnd(rest, width, font);
            if (at) |o| ui.text(.{ .x = o.x, .y = o.y + y, .w = width, .h = question_row_h }, rest[0..end], font, .left, if (first) ui.pal.text else ui.pal.text2);
            y += question_row_h;
            rest = std.mem.trimStart(u8, rest[end..], " ");
        }
        first = false;
    }
    return y;
}

/// Where the first row of `s` ends: after the last whole word that fits in
/// `width`, or after the first word if even that doesn't fit.
fn wrapEnd(s: []const u8, width: f32, font: gui.Font) usize {
    var end: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i < s.len and s[i] != ' ') continue;
        if (end > 0 and app.ui.measure(s[0..i], font) > width) break;
        end = i;
    }
    return if (end == 0) s.len else end;
}

pub fn menu(items: []const []const u8, tile: usize) void {
    const ui = &app.ui;
    // Opened from the keyboard: under the focused tile, its first line focused.
    const by_key = ui.focus_visible and ui.focus_rect != null;
    const at: gui.Point = if (by_key) .{ .x = ui.focus_rect.?.x + 12, .y = ui.focus_rect.?.bottom() - 12 } else ui.mouse;
    st.return_focus = ui.focus;
    if (by_key) ui.focus = key("menu", 0);
    st.overlay = .{ .menu = .{ .items = items, .tile = tile, .at = at } };
    redraw();
}

pub fn confirm(question: []const u8, action: app_mod.Action) void {
    // "No" has the focus: Enter never resets anything by accident.
    st.return_focus = app.ui.focus;
    app.ui.focus = key("confirm-no", 0);
    st.overlay = .{ .confirm = .{ .question = question, .action = action } };
    redraw();
}

/// Closes the menu or question, and gives the focus back where it was.
fn closeOverlay() void {
    st.overlay = .none;
    app.ui.focus = st.return_focus;
}

pub fn connect() ?*Client {
    var addr_buf: [256]u8 = undefined;
    const addr = zmural.sdk.control_client_linux.address(&addr_buf, st.runtime_dir) catch return null;
    return Client.connect(st.gpa, addr, "settings", 3000) catch null;
}

pub fn autostartOn() bool {
    const al = zmural.os.autostart_linux;
    const path = al.path(st.gpa, st.config_home, st.home) catch return false;
    defer st.gpa.free(path);
    return al.state(st.io, path) == .on;
}

pub fn setAutostart(on: bool) !void {
    const al = zmural.os.autostart_linux;
    const path = try al.path(st.gpa, st.config_home, st.home);
    defer st.gpa.free(path);
    const exe = try std.fs.path.join(st.gpa, &.{ st.exe_dir, "zmural" });
    defer st.gpa.free(exe);
    try al.write(st.io, path, exe, on);
}

/// The Uninstall button: zmural removes itself once it has stopped, in its
/// own process, and says when it's done in a notification. Not a child
/// process: under a systemd unit that ends with its main process (what
/// `systemd-run` and most hand-written services make), a child dies with
/// zmural before it removes anything.
pub fn startUninstall() !void {
    app_mod.uninstall_on_exit.store(true, .release);
}

/// `zmural-console import <zip> --apply --report <report>`; `importFinished`
/// says when it's done (and reaps it).
pub fn startImport(zip_path: []const u8, report: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(st.io, report) catch {}; // zsnag:ok — usually not there; an old one would only be read if the new import wrote none
    const exe = try std.fs.path.join(st.gpa, &.{ st.exe_dir, "zmural-console" });
    defer st.gpa.free(exe);
    const child = try std.process.spawn(st.io, .{ .argv = &.{ exe, "import", zip_path, "--apply", "--report", report }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    st.import_pid = child.id;
}

pub fn importFinished() bool {
    const pid = st.import_pid orelse return true;
    var status: i32 = 0;
    const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
    if (linux.errno(rc) == .SUCCESS and rc == 0) return false; // still running
    st.import_pid = null;
    return true;
}

/// A small file's contents into `buf`, or null.
pub fn readSmall(path: []const u8, buf: []u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFile(st.io, path, buf) catch null;
}

pub fn startDaemon() !void {
    const exe = try std.fs.path.join(st.gpa, &.{ st.exe_dir, "zmural" });
    defer st.gpa.free(exe);
    std.Io.Dir.cwd().access(st.io, exe, .{}) catch return error.NotFound;
    _ = try std.process.spawn(st.io, .{ .argv = &.{exe}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
}

/// An `xdg-open` started by a button. It exits with an error when the
/// desktop has nothing to open the thing with; the user is told then,
/// instead of a button that does nothing.
const Opener = struct {
    /// Null: a free slot.
    pid: ?linux.pid_t = null,
    started_ms: u64 = 0,
    /// What to say when it fails, before the path: "nothing opened the folder; ...".
    failed: []const u8 = "",
    /// What it was asked to open, kept for that message (the caller's slice may not live).
    path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
};

/// How long a failure is still news. Some openers stay in the foreground
/// as long as the app they started; their exit later says nothing.
const opener_news_ms = 10_000;

/// Opens a text file (the log) in the desktop's editor.
pub fn openFile(path: []const u8) void {
    if (path.len == 0) return;
    open(path, "nothing opened the log; no app here opens text files. It is");
}

/// Opens a folder in the desktop's file manager, making it first if it's
/// not there yet (a standard library folder nobody has used).
pub fn openFolder(path: []const u8) void {
    if (path.len == 0) return;
    std.Io.Dir.cwd().createDirPath(st.io, path) catch return app_mod.showToast("can't make that folder");
    open(path, "nothing opened the folder; no file manager is set up here. It is");
}

fn open(path: []const u8, failed: []const u8) void {
    const slot = for (&st.openers) |*o| {
        if (o.pid == null) break o;
    } else return app_mod.showToast("still opening the last ones; try again in a moment");
    const child = std.process.spawn(st.io, .{ .argv = &.{ "xdg-open", path }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch
        return toastPath("can't open it: xdg-open is missing. It is", path);
    const n = @min(path.len, slot.path.len);
    @memcpy(slot.path[0..n], path[0..n]);
    slot.path_len = n;
    slot.pid = child.id.?;
    slot.started_ms = now();
    slot.failed = failed;
}

/// Reaps the `xdg-open`s that ended, and says so if one failed soon after
/// it started. Called every poll.
fn checkOpeners() void {
    for (&st.openers) |*o| {
        const pid = o.pid orelse continue;
        var status: i32 = 0;
        const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
        if (linux.errno(rc) == .SUCCESS and rc == 0) continue; // still running
        o.pid = null;
        if (linux.errno(rc) != .SUCCESS) continue;
        const ok = linux.W.IFEXITED(@bitCast(status)) and linux.W.EXITSTATUS(@bitCast(status)) == 0;
        if (!ok and now() -| o.started_ms <= opener_news_ms) toastPath(o.failed, o.path[0..o.path_len]);
    }
}

fn toastPath(msg: []const u8, path: []const u8) void {
    var buf: [160]u8 = undefined;
    app_mod.showToast(std.fmt.bufPrint(&buf, "{s} {s}", .{ msg, path }) catch msg);
}

/// Shows the file selected in the desktop's file manager.
pub fn showInFolder(path: []const u8) void {
    const b = if (st.bus) |*x| x else return app_mod.showToast("no session bus: can't reach the file manager");
    var uri_buf: [4096]u8 = undefined;
    const uri = xdg.fileUri(&uri_buf, path) orelse return;
    var buf: [4608]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    const arr = w.beginArray(4) catch return;
    w.string(uri) catch return;
    w.endArray(arr);
    w.string("") catch return;
    _ = b.call("org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1", "ShowItems", "ass", w.written()) catch
        toastPath("no file manager answered to show it. It is", path);
}

// ---- file pickers (the XDG FileChooser portal) ------------------------------------------

pub fn pick(kind: app_mod.PickKind) void {
    if (st.test_pick) |p| {
        // "@<file>": the answer is read from that file now, so a rig can
        // give each picker its own.
        if (p.len == 0 or p[0] != '@') return app_mod.picked(kind, p);
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const got = std.Io.Dir.cwd().readFile(st.io, p[1..], &buf) catch return app_mod.showToast("test pick: can't read its file");
        return app_mod.picked(kind, std.mem.trim(u8, got, " \n"));
    }
    const b = if (st.bus) |*x| x else return app_mod.showToast("no session bus: can't open a file picker");
    var buf: [2048]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    const title = switch (kind) {
        .wallpaper => "Show a video, picture or web page, or import a zip",
        .folder => "Add a wallpaper folder",
        .app => "Pause wallpapers while this app is in front",
    };
    (blk: {
        w.string("") catch break :blk error.TooLarge; // no parent window handle
        w.string(title) catch break :blk error.TooLarge;
        const opts = w.beginArray(8) catch break :blk error.TooLarge;
        if (kind == .folder) {
            w.pad(8) catch break :blk error.TooLarge;
            w.string("directory") catch break :blk error.TooLarge;
            w.signature("b") catch break :blk error.TooLarge;
            w.u32_(1) catch break :blk error.TooLarge;
        }
        if (kind == .wallpaper) {
            // filters: a(sa(us)) — a name and its glob patterns.
            w.pad(8) catch break :blk error.TooLarge;
            w.string("filters") catch break :blk error.TooLarge;
            w.signature("a(sa(us))") catch break :blk error.TooLarge;
            const filters = w.beginArray(8) catch break :blk error.TooLarge;
            const groups = [_]struct { []const u8, []const []const u8 }{
                .{ "Videos, pictures, web pages and zips", &.{ "*.mp4", "*.mkv", "*.webm", "*.mov", "*.avi", "*.wmv", "*.m4v", "*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.gif", "*.avif", "*.html", "*.htm", "*.zip" } },
                .{ "All files", &.{"*"} },
            };
            for (groups) |g| {
                w.pad(8) catch break :blk error.TooLarge;
                w.string(g[0]) catch break :blk error.TooLarge;
                const pats = w.beginArray(8) catch break :blk error.TooLarge;
                for (g[1]) |pat| {
                    w.pad(8) catch break :blk error.TooLarge;
                    w.u32_(0) catch break :blk error.TooLarge; // a glob
                    w.string(pat) catch break :blk error.TooLarge;
                }
                w.endArray(pats);
            }
            w.endArray(filters);
        }
        w.endArray(opts);
        break :blk {};
    }) catch return app_mod.showToast("file picker: request too large");
    const reply = b.call("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.FileChooser", "OpenFile", "ssa{sv}", w.written()) catch
        return app_mod.showToast("no file picker available (xdg-desktop-portal)");
    var r: dbus.Reader = .{ .body = reply };
    const request = r.string() catch return;
    st.pick_handle_len = @min(request.len, st.pick_handle.len);
    @memcpy(st.pick_handle[0..st.pick_handle_len], request[0..st.pick_handle_len]);
    st.pick_kind = kind;
}

fn onBusMessage(_: *anyopaque, _: *dbus.Conn, m: dbus.Message) void {
    if (m.isSignal("org.freedesktop.portal.Request", "Response")) {
        if (st.pick_handle_len == 0 or !std.mem.eql(u8, m.path, st.pick_handle[0..st.pick_handle_len])) return;
        st.pick_handle_len = 0;
        var r: dbus.Reader = .{ .body = m.body };
        const response = r.u32_() catch return;
        if (response != 0) return; // cancelled
        const uri = firstUri(&r) orelse return;
        var path_buf: [4096]u8 = undefined;
        const path = uriPath(&path_buf, uri) orelse return app_mod.showToast("that isn't a local file");
        app_mod.picked(st.pick_kind, path);
    } else if (m.isSignal("org.freedesktop.portal.Settings", "SettingChanged")) {
        // Not re-read here: this may run inside another call's wait (dbus.zig `call`).
        if (isThemeSetting(m.body)) st.theme_dirty = true;
    }
}

/// A `SettingChanged` (namespace, key, value) for one of the settings `theme`
/// reads. KDE sends others on every focus change (org.kde.VirtualKeyboard).
fn isThemeSetting(body: []const u8) bool {
    var r: dbus.Reader = .{ .body = body };
    const namespace = r.string() catch return false;
    const name = r.string() catch return false;
    if (!std.mem.eql(u8, namespace, "org.freedesktop.appearance")) return false;
    return std.mem.eql(u8, name, "color-scheme") or std.mem.eql(u8, name, "accent-color");
}

/// Brings the window to the front: with the launcher's token when there is
/// one, else with one we ask for (compositors may only flash the task bar
/// entry then, which is their call to make).
fn raiseNow(token: []const u8) !void {
    if (token.len > 0) return activate(token);
    if (st.activation == 0 or st.token_req != 0) return;
    const c = &st.conn;
    st.token_req = c.newId();
    try c.request(st.activation, op.activation_get_token, &.{.{ .new_id = st.token_req }});
    try c.request(st.token_req, op.token_set_app_id, &.{.{ .string = "org.zmural.Settings" }});
    try c.request(st.token_req, op.token_set_surface, &.{.{ .object = st.surface }});
    try c.request(st.token_req, op.token_commit, &.{});
}

fn activate(token: []const u8) !void {
    if (st.activation == 0) return;
    try st.conn.request(st.activation, op.activation_activate, &.{ .{ .string = token }, .{ .object = st.surface } });
}

/// `uris` from a portal's `a{sv}` results.
fn firstUri(r: *dbus.Reader) ?[]const u8 {
    const end = r.arrayEnd(8) catch return null;
    while (r.pos < end) {
        r.alignStruct() catch return null;
        const k = r.string() catch return null;
        const sig = r.signature() catch return null;
        if (std.mem.eql(u8, k, "uris") and std.mem.eql(u8, sig, "as")) {
            const aend = r.arrayEnd(4) catch return null;
            if (r.pos < aend) return r.string() catch null;
            return null;
        }
        r.skip(sig) catch return null;
    }
    return null;
}

/// `file:///a%20b` -> `/a b`.
fn uriPath(buf: []u8, uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var n: usize = 0;
    var i: usize = prefix.len;
    while (i < uri.len) : (i += 1) {
        if (n == buf.len) return null;
        if (uri[i] == '%' and i + 2 < uri.len) {
            buf[n] = std.fmt.parseInt(u8, uri[i + 1 .. i + 3], 16) catch return null;
            i += 2;
        } else buf[n] = uri[i];
        n += 1;
    }
    return buf[0..n];
}

/// `/a b` -> `file:///a%20b`, as the thumbnail spec and file managers want it.
// ---- theme ------------------------------------------------------------------------------

/// Light or dark and the accent colour, from the desktop (XDG settings portal).
fn theme() gui.Theme {
    var dark = false;
    var accent: ?gui.Color = null;
    if (st.bus) |*b| {
        if (readSetting(b, "color-scheme")) |v| {
            var r: dbus.Reader = .{ .body = v.body };
            if (std.mem.eql(u8, v.sig, "u")) dark = (r.u32_() catch 0) == 1;
        }
        if (readSetting(b, "accent-color")) |v| {
            var r: dbus.Reader = .{ .body = v.body };
            if (std.mem.eql(u8, v.sig, "(ddd)")) blk: {
                r.alignStruct() catch break :blk;
                const cr = r.f64_() catch break :blk;
                const cg = r.f64_() catch break :blk;
                const cb = r.f64_() catch break :blk;
                // Out of range means "no accent set".
                if (cr >= 0 and cr <= 1 and cg >= 0 and cg <= 1 and cb >= 0 and cb <= 1)
                    accent = .{ .r = @floatCast(cr), .g = @floatCast(cg), .b = @floatCast(cb), .a = 1 };
            }
        }
    }
    if (st.force_dark) |d| dark = d;
    if (accent) |a| return .fromAccent(dark, a);
    return .{ .dark = dark };
}

const Setting = struct { sig: []const u8, body: []const u8 };
var setting_buf: [256]u8 = undefined;

/// org.freedesktop.appearance.<name> as a signature and its value's bytes
/// (copied: the reply buffer is reused).
fn readSetting(b: *dbus.Conn, name: []const u8) ?Setting {
    var buf: [256]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    w.string("org.freedesktop.appearance") catch return null;
    w.string(name) catch return null;
    // ReadOne (portal v2) answers `v`; the older Read answers `v` holding a `v`.
    const reply = b.call("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "ReadOne", "ss", w.written()) catch
        b.call("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "Read", "ss", w.written()) catch return null;
    var r: dbus.Reader = .{ .body = reply };
    var sig = r.signature() catch return null;
    if (std.mem.eql(u8, sig, "v")) sig = r.signature() catch return null;
    // Keep the value's alignment: copy from an 8-aligned offset.
    const start = r.pos - r.pos % 8;
    const off = r.pos - start;
    const len = @min(reply.len - start, setting_buf.len);
    @memcpy(setting_buf[0..len], reply[start..][0..len]);
    const sig_copy = std.fmt.bufPrint(setting_buf[len..], "{s}", .{sig}) catch return null;
    return .{ .sig = sig_copy, .body = setting_buf[off..len] };
}

// ---- thumbnails ---------------------------------------------------------------------------

pub fn requestThumb(path: []const u8) void {
    const copy = st.gpa.dupe(u8, path) catch return;
    st.thumb_queue.append(st.gpa, copy) catch st.gpa.free(copy);
}

/// From the desktop's thumbnail cache (freedesktop spec: the MD5 of the
/// file's URI, as PNG), else the file itself when it's a PNG, else zmural's
/// own cache, else one is made (`pumpMakers`) and arrives later.
fn makeThumb(path: []const u8) void {
    var uri_buf: [4096]u8 = undefined;
    var name_buf: [4096:0]u8 = undefined;
    // A package's tile shows the file it names; the result still goes to its tile.
    var entry_buf: [4096]u8 = undefined;
    const src = packageFile(&entry_buf, path) orelse path;
    const uri = xdg.fileUri(&uri_buf, src) orelse return app_mod.thumbImage(path, null, 0, 0);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(uri, &digest, .{});
    for ([_][]const u8{ "x-large", "large", "normal" }) |size| {
        const p = (if (st.cache_home) |ch|
            std.fmt.bufPrintSentinel(&name_buf, "{s}/thumbnails/{s}/{x}.png", .{ ch, size, &digest }, 0)
        else
            std.fmt.bufPrintSentinel(&name_buf, "{s}/.cache/thumbnails/{s}/{x}.png", .{ st.home, size, &digest }, 0)) catch continue;
        if (app.ui.b.loadThumb(p, app_mod.thumb_px)) |t| return app_mod.thumbImage(path, t.img, t.width, t.height);
    }
    if (std.ascii.endsWithIgnoreCase(src, ".png")) {
        const p = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{src}, 0) catch return app_mod.thumbImage(path, null, 0, 0);
        if (app.ui.b.loadThumb(p, app_mod.thumb_px)) |t| return app_mod.thumbImage(path, t.img, t.width, t.height);
    }
    if (!zmural.media.isVideo(src) and !zmural.media.isImage(src)) return app_mod.thumbImage(path, null, 0, 0);
    const own = ownThumb(&name_buf, &digest) orelse return app_mod.thumbImage(path, null, 0, 0);
    if (newerThan(own, src)) if (app.ui.b.loadThumb(own, app_mod.thumb_px)) |t| return app_mod.thumbImage(path, t.img, t.width, t.height);
    const copy = st.gpa.dupe(u8, path) catch return app_mod.thumbImage(path, null, 0, 0);
    st.make_queue.append(st.gpa, copy) catch {
        st.gpa.free(copy);
        app_mod.thumbImage(path, null, 0, 0);
    };
}

/// zmural's own thumbnail of a file (`digest`: the MD5 of its URI) into
/// `buf`: in its cache, which uninstall removes, not the desktop's.
fn ownThumb(buf: *[4096:0]u8, digest: *const [16]u8) ?[:0]u8 {
    return (if (st.cache_home) |ch|
        std.fmt.bufPrintSentinel(buf, "{s}/zmural/thumbs/{x}.png", .{ ch, digest }, 0)
    else
        std.fmt.bufPrintSentinel(buf, "{s}/.cache/zmural/thumbs/{x}.png", .{ st.home, digest }, 0)) catch null;
}

/// `made` exists and is no older than `src` (a changed file gets a new thumbnail).
fn newerThan(made: []const u8, src: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const m = cwd.statFile(st.io, made, .{}) catch return false;
    const s = cwd.statFile(st.io, src, .{}) catch return false;
    return m.mtime.nanoseconds >= s.mtime.nanoseconds;
}

fn makersBusy() bool {
    for (st.makers) |m| if (m != null) return true;
    return st.make_queue.items.len > 0;
}

/// Collects the thumbnails made, and starts the next while a slot is free.
fn pumpMakers() void {
    for (&st.makers) |*slot| {
        const m = slot.* orelse continue;
        var status: i32 = 0;
        const rc = linux.wait4(m.pid, &status, linux.W.NOHANG, null);
        if (linux.errno(rc) == .SUCCESS and rc == 0) continue; // still running
        slot.* = null;
        defer st.gpa.free(m.path);
        defer st.gpa.free(m.out);
        const ok = linux.errno(rc) == .SUCCESS and linux.W.IFEXITED(@bitCast(status)) and linux.W.EXITSTATUS(@bitCast(status)) == 0;
        if (ok) if (app.ui.b.loadThumb(m.out, app_mod.thumb_px)) |t| {
            app_mod.thumbImage(m.path, t.img, t.width, t.height);
            continue;
        };
        log.info("no thumbnail could be made of {s}", .{m.path});
        app_mod.thumbImage(m.path, null, 0, 0);
    }
    for (&st.makers) |*slot| {
        if (slot.* != null) continue;
        if (st.make_queue.items.len == 0) return;
        const path = st.make_queue.orderedRemove(0);
        slot.* = startMaker(path) catch |err| blk: {
            log.warn("can't make a thumbnail of {s}: {s}", .{ path, @errorName(err) });
            app_mod.thumbImage(path, null, 0, 0);
            st.gpa.free(path);
            break :blk null;
        };
    }
}

/// `zmural --still-frame <file> <own thumbnail> <thumb_px>`; takes `path`.
fn startMaker(path: []u8) !Maker {
    var entry_buf: [4096]u8 = undefined;
    const src = packageFile(&entry_buf, path) orelse path;
    var uri_buf: [4096]u8 = undefined;
    const uri = xdg.fileUri(&uri_buf, src) orelse return error.NameTooLong;
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(uri, &digest, .{});
    var out_buf: [4096:0]u8 = undefined;
    const out_path = ownThumb(&out_buf, &digest) orelse return error.NameTooLong;
    if (st.exe_dir.len == 0) return error.NoExeDir;
    try std.Io.Dir.cwd().createDirPath(st.io, std.fs.path.dirname(out_path).?);
    const exe = try std.fs.path.join(st.gpa, &.{ st.exe_dir, "zmural" });
    defer st.gpa.free(exe);
    const out = try st.gpa.dupeSentinel(u8, out_path, 0);
    errdefer st.gpa.free(out);
    const child = try std.process.spawn(st.io, .{
        .argv = &.{ exe, "--still-frame", src, out, std.fmt.comptimePrint("{d}", .{app_mod.thumb_px}) },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return .{ .pid = child.id.?, .path = path, .out = out };
}

/// The window is closing: the makers still running go with it.
fn stopMakers() void {
    for (&st.makers) |*slot| {
        const m = slot.* orelse continue;
        _ = linux.kill(m.pid, linux.SIG.TERM);
        var status: i32 = 0;
        _ = linux.wait4(m.pid, &status, 0, null);
        st.gpa.free(m.path);
        st.gpa.free(m.out);
        slot.* = null;
    }
    for (st.make_queue.items) |p| st.gpa.free(p);
    st.make_queue.deinit(st.gpa);
}

/// The file a package (`<folder>/zmural.toml`) names, into `buf`; null for
/// anything else, or a package that doesn't read.
fn packageFile(buf: []u8, path: []const u8) ?[]const u8 {
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(path), zmural.manifest.file_name)) return null;
    var arena: std.heap.ArenaAllocator = .init(st.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = std.Io.Dir.cwd().readFileAlloc(st.io, path, a, .limited(256 * 1024)) catch return null;
    const m = zmural.manifest.parse(a, text, null) catch return null;
    const folder = std.fs.path.dirname(path) orelse return null;
    const p = zmural.manifest.entryPath(a, folder, m.entry) catch return null;
    if (p.len > buf.len) return null;
    @memcpy(buf[0..p.len], p);
    return buf[0..p.len];
}

test "only the appearance settings theme reads count as a theme change" {
    var buf: [128]u8 = undefined;
    const cases = [_]struct { ns: []const u8, key: []const u8, want: bool }{
        .{ .ns = "org.freedesktop.appearance", .key = "color-scheme", .want = true },
        .{ .ns = "org.freedesktop.appearance", .key = "accent-color", .want = true },
        .{ .ns = "org.freedesktop.appearance", .key = "contrast", .want = false },
        .{ .ns = "org.kde.VirtualKeyboard", .key = "active", .want = false },
    };
    for (cases) |c| {
        var w: dbus.Writer = .{ .buf = &buf };
        try w.string(c.ns);
        try w.string(c.key);
        try std.testing.expectEqual(c.want, isThemeSetting(w.written()));
    }
    try std.testing.expect(!isThemeSetting(""));
}

test uriPath {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/home/me/a b.mp4", uriPath(&buf, "file:///home/me/a%20b.mp4").?);
    try std.testing.expectEqualStrings("file:///home/me/a%20b.mp4", xdg.fileUri(&buf, "/home/me/a b.mp4").?);
}
