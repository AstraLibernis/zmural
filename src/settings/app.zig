// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The settings window's content, on every OS: a sidebar (Welcome,
//! Wallpapers, Playback, Pausing, General), a "now playing" card, and the pages. It holds
//! no settings of its own: it asks zmural over the control socket/pipe, and
//! every change is sent (and saved by zmural) straight away.
//!
//! What differs per OS (the window, pickers, menus, thumbnails, the
//! connection, start at login) is the platform's (`platform_windows.zig`,
//! `platform_linux.zig`); the drawing is `gui.zig` over a backend.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");
const control = zmural.protocol.control;
const props = zmural.properties;
const policy = zmural.policy;
const FillMode = zmural.layout.FillMode;
const gui = @import("gui.zig");
const Ui = gui.Ui;
const Rect = gui.Rect;
const Icon = gui.Icon;
const key = gui.key;

pub const platform = switch (builtin.os.tag) {
    .windows => @import("platform_windows.zig"),
    else => @import("platform_linux.zig"),
};
const Client = platform.Client;

pub const poll_ms = 1000;
pub const sidebar_w: f32 = 272;
const content_max_w: f32 = 1000;
/// Longest side of a thumbnail, in pixels.
pub const thumb_px = 400;
/// The window's size at 96 DPI, and the smallest it may get.
pub const window_w = 1000;
pub const window_h = 680;
pub const min_w = 760;
pub const min_h = 520;

const Page = enum { welcome, wallpapers, playback, pausing, general };

/// Something a click asked for. Done after the frame is drawn, so dialogs and
/// requests never run in the middle of drawing.
pub const Action = union(enum) {
    apply: usize,
    /// Open one of the standard library folders (by its place in the list).
    open_folder: usize,
    show_page: Page,
    apply_file,
    tile_menu: usize,
    next,
    previous,
    toggle_paused,
    toggle_muted,
    set_fill: FillMode,
    set_volume: u8,
    set_rule: control.SetRule,
    set_resume: u32,
    set_rotate: u16,
    set_order: control.Order,
    /// One of the wallpaper's own properties: which, and its new value as text.
    set_prop: PropEdit,
    reset_props,
    rescan,
    add_folder,
    remove_folder: usize,
    add_app,
    remove_app: usize,
    toggle_autostart,
    open_log,
    reset,
    reset_confirmed,
    start_daemon,
    uninstall,
    uninstall_confirmed,
};

pub const PropEdit = struct {
    index: usize,
    text: [32]u8 = undefined,
    len: usize = 0,
};

/// What a file/folder picker was for. Pickers may answer later (the Linux
/// portal does), so the result comes back through `picked`.
pub const PickKind = enum { wallpaper, folder, app };

const Thumb = struct {
    /// null while it's being made, or when there is none.
    img: ?*gui.Backend.Image = null,
    width: f32 = 0,
    height: f32 = 0,
    done: bool = false,
};

/// What zmural told us last, copied out of the reply buffer.
const Known = struct {
    info: ?control.SettingsInfo = null,
    wallpaper: []const u8 = "",
    paused: bool = false,
    muted: bool = true,
    /// From `status`, so a change from the tray or CLI shows within a second.
    rotate_minutes: u16 = 0,
    order: control.Order = .sequential,
    next_change_s: u32 = 0,
    /// The line to report for this run's last crash ("" when none).
    crash: []const u8 = "",
    library: []const []const u8 = &.{},
    library_total: u32 = 0,
    /// The connected monitors, in zmural's order.
    monitors: []const Monitor = &.{},
    /// The main wallpaper's own properties (brightness, speed, a package's...).
    props: []const props.Item = &.{},
    props_title: []const u8 = "",
};

const Monitor = struct {
    id: []const u8,
    name: []const u8,
    /// Its own wallpaper, or empty when it shows the main one.
    wallpaper: []const u8,
};

/// A tile's menu lists at most this many monitors.
const max_menu_monitors = 8;

pub const App = struct {
    gpa: std.mem.Allocator,
    ui: Ui = undefined,
    log_path: []const u8 = "",
    client: ?*Client = null,
    last_connect_ms: u64 = 0,
    /// Polls left that reload the wallpaper list after a rescan: the scan runs
    /// in the background, and a rename keeps the count the same.
    library_reloads: u8 = 0,
    page: Page = .wallpapers,
    /// The page was picked when the window first reached zmural: Welcome if
    /// nothing is showing, else Wallpapers. Later reconnects leave it be.
    page_chosen: bool = false,
    /// zmural's first run: open on Welcome even though its own wallpaper shows.
    open_on_welcome: bool = false,
    /// When the Welcome page last asked for a rescan (see `onPoll`).
    last_welcome_rescan_ms: u64 = 0,
    scroll: std.enums.EnumArray(Page, f32) = .initFill(0),
    content_h: f32 = 0,
    known: Known = .{},
    info_arena: std.heap.ArenaAllocator,
    status_arena: std.heap.ArenaAllocator,
    library_arena: std.heap.ArenaAllocator,
    monitors_arena: std.heap.ArenaAllocator,
    props_arena: std.heap.ArenaAllocator,
    /// While a property's slider is dragged: which, and where (0..1).
    prop_drag: ?struct { index: usize, t: f32 } = null,
    last_prop_send_ms: u64 = 0,
    /// The open tile menu's lines (they must outlive the call that opens it).
    menu_items: [max_menu_monitors + 2][]const u8 = undefined,
    menu_text: [max_menu_monitors][80]u8 = undefined,
    /// How many of those lines name a monitor.
    menu_monitors: usize = 0,
    thumbs: std.StringHashMapUnmanaged(Thumb) = .empty,
    pending: ?Action = null,
    /// While a slider is dragged, its live value (the daemon gets it on release).
    volume_drag: ?f32 = null,
    resume_drag: ?f32 = null,
    last_volume_send_ms: u64 = 0,
    autostart: bool = false,
    toast: [160]u8 = undefined,
    /// An import running (`startImport`), and where it writes how it went.
    importing: bool = false,
    import_report: [1024]u8 = undefined,
    import_report_len: usize = 0,
    toast_len: usize = 0,
    toast_until_ms: u64 = 0,
};

pub var app: App = undefined;

/// Set by the window's Uninstall on Linux: zmural removes itself as it exits
/// (`window.uninstallRequested`). Read by the daemon after the window's
/// thread has ended.
pub var uninstall_on_exit: std.atomic.Value(bool) = .init(false);

pub fn init(gpa: std.mem.Allocator) void {
    app = .{
        .gpa = gpa,
        .info_arena = .init(gpa),
        .status_arena = .init(gpa),
        .library_arena = .init(gpa),
        .monitors_arena = .init(gpa),
        .props_arena = .init(gpa),
    };
}

pub fn deinit() void {
    if (app.client) |c| c.close(app.gpa);
    app.client = null;
    dropThumbs();
    app.info_arena.deinit();
    app.status_arena.deinit();
    app.library_arena.deinit();
    app.monitors_arena.deinit();
    app.props_arena.deinit();
}

// ---- talking to zmural ------------------------------------------------------------

pub fn connect() void {
    if (app.client != null) return;
    app.last_connect_ms = platform.now();
    app.client = platform.connect() orelse return;
    refreshSettings();
    refreshStatus();
    refreshLibrary();
    if (!app.page_chosen) {
        app.page_chosen = true;
        if (app.open_on_welcome or nothingShowing()) {
            app.page = .welcome;
            std.log.scoped(.settings).info("window: {s}, so it opens on Welcome", .{if (app.open_on_welcome) "first run" else "nothing showing"});
        }
    }
}

/// No wallpaper anywhere: neither the main one nor a monitor's own.
fn nothingShowing() bool {
    if (app.known.wallpaper.len > 0) return false;
    for (app.known.monitors) |m| if (m.wallpaper.len > 0) return false;
    return true;
}

fn disconnect() void {
    if (app.client) |c| c.close(app.gpa);
    app.client = null;
}

/// Sends a request; on a `failed` reply shows its message. Null if zmural is gone.
fn call(req: control.Request) ?control.Event {
    const c = app.client orelse return null;
    const ev = c.request(req) catch {
        disconnect();
        return null;
    };
    if (ev == .failed) showToast(ev.failed.message);
    return ev;
}

fn refreshSettings() void {
    const ev = call(.get_settings) orelse return;
    if (ev != .settings) return;
    _ = app.info_arena.reset(.retain_capacity);
    const a = app.info_arena.allocator();
    var s = ev.settings;
    s.app_rules = a.dupe(u8, s.app_rules) catch "";
    s.library_dirs = a.dupe(u8, s.library_dirs) catch "";
    s.default_dirs = a.dupe(u8, s.default_dirs) catch "";
    s.file = a.dupe(u8, s.file) catch "";
    app.known.info = s;
}

fn refreshStatus() void {
    const ev = call(.status) orelse return;
    if (ev != .status) return;
    const st = ev.status;
    if (!std.mem.eql(u8, st.wallpaper, app.known.wallpaper) or !std.mem.eql(u8, st.crash, app.known.crash)) {
        _ = app.status_arena.reset(.retain_capacity);
        app.known.wallpaper = app.status_arena.allocator().dupe(u8, st.wallpaper) catch "";
        app.known.crash = app.status_arena.allocator().dupe(u8, st.crash) catch "";
    }
    app.known.paused = st.paused;
    app.known.muted = st.muted;
    app.known.rotate_minutes = st.rotate_minutes;
    app.known.order = st.order;
    app.known.next_change_s = st.next_change_s;
    if (st.wallpapers != app.known.library_total) refreshLibrary();
    refreshMonitors();
    // Not while one is being dragged: the list would move under the pointer.
    if (app.prop_drag == null) refreshProperties();
}

/// The main wallpaper's properties and their values. An older zmural, or a
/// wallpaper without any, gives none.
fn refreshProperties() void {
    const c = app.client orelse return;
    const ev = c.request(.get_properties) catch return disconnect();
    _ = app.props_arena.reset(.retain_capacity);
    app.known.props = &.{};
    app.known.props_title = "";
    if (ev != .properties) return;
    const a = app.props_arena.allocator();
    const text = a.dupe(u8, ev.properties.list) catch return;
    app.known.props = props.parseList(a, text) catch return;
    app.known.props_title = a.dupe(u8, ev.properties.title) catch "";
}

/// Which monitors are connected and what each shows. An older zmural
/// doesn't know the request: then there are none to choose from.
fn refreshMonitors() void {
    const c = app.client orelse return;
    const ev = c.request(.monitors) catch return disconnect();
    _ = app.monitors_arena.reset(.retain_capacity);
    app.known.monitors = &.{};
    if (ev != .monitors) return;
    const a = app.monitors_arena.allocator();
    var list: std.ArrayList(Monitor) = .empty;
    var it = std.mem.splitScalar(u8, ev.monitors.list, control.list_sep);
    while (it.next()) |line| {
        const m = control.parseMonitorLine(line) orelse continue;
        list.append(a, .{
            .id = a.dupe(u8, m.id) catch return,
            .name = a.dupe(u8, m.name) catch return,
            .wallpaper = a.dupe(u8, m.wallpaper) catch return,
        }) catch return;
    }
    app.known.monitors = list.items;
}

/// A tile's menu. With one monitor: show it, or show its file. With more,
/// a line per monitor in between, so a wallpaper can go on just one.
fn tileMenu() []const []const u8 {
    const mons = app.known.monitors;
    app.menu_monitors = if (mons.len > 1) @min(mons.len, max_menu_monitors) else 0;
    var n: usize = 0;
    app.menu_items[n] = if (app.menu_monitors > 0) "Show on every monitor" else "Show on desktop";
    n += 1;
    for (mons[0..app.menu_monitors], 0..) |m, i| {
        app.menu_items[n] = std.fmt.bufPrint(&app.menu_text[i], "Show on monitor {d} ({s})", .{ i + 1, m.name }) catch "Show on this monitor";
        n += 1;
    }
    app.menu_items[n] = "Show in folder";
    return app.menu_items[0 .. n + 1];
}

fn refreshLibrary() void {
    _ = app.library_arena.reset(.retain_capacity);
    const a = app.library_arena.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    var offset: u32 = 0;
    var total: u32 = 0;
    while (true) {
        const ev = call(.{ .library = .{ .offset = offset } }) orelse break;
        if (ev != .library) break;
        total = ev.library.total;
        var it = std.mem.splitScalar(u8, ev.library.paths, control.list_sep);
        var got: u32 = 0;
        while (it.next()) |p| {
            if (p.len == 0) continue;
            paths.append(a, a.dupe(u8, p) catch break) catch break;
            got += 1;
        }
        offset += got;
        if (got == 0 or offset >= total) break;
    }
    app.known.library = paths.items;
    app.known.library_total = total;
}

/// Once a second: reconnect, or refresh what's showing.
pub fn onPoll() void {
    if (app.client == null) {
        if (platform.now() -| app.last_connect_ms >= 2 * poll_ms) connect();
    } else {
        refreshStatus();
        // On Welcome, files dropped into a folder show up by themselves. Only
        // there: a rescan restarts a shuffle round, and a big library takes
        // a moment to read.
        if (app.page == .welcome and platform.now() -| app.last_welcome_rescan_ms >= 3 * poll_ms) {
            app.last_welcome_rescan_ms = platform.now();
            _ = call(.rescan);
        }
        if (app.library_reloads > 0) {
            app.library_reloads -= 1;
            refreshLibrary();
        }
    }
    importPoll();
    app.autostart = platform.autostartOn();
    platform.redraw();
}

// ---- actions ------------------------------------------------------------------------

fn perform(action: Action) void {
    const k = &app.known;
    switch (action) {
        .apply => |i| if (i < k.library.len) {
            _ = call(.{ .apply = .{ .path = k.library[i] } });
        },
        .apply_file => return platform.pick(.wallpaper),
        .open_folder => |i| {
            const info = k.info orelse return;
            var it = std.mem.splitScalar(u8, info.default_dirs, control.list_sep);
            var n: usize = 0;
            while (it.next()) |dir| {
                if (dir.len == 0) continue;
                if (n == i) return platform.openFolder(dir);
                n += 1;
            }
            return;
        },
        .show_page => |pg| {
            app.page = pg;
            return;
        },
        .tile_menu => |i| if (i < k.library.len) return platform.menu(tileMenu(), i),
        .next => _ = call(.{ .next = .{} }),
        .previous => _ = call(.{ .previous = .{} }),
        .toggle_paused => _ = call(if (k.paused) .{ .play = .{} } else .{ .pause = .{} }),
        .toggle_muted => _ = call(.{ .set_muted = .{ .muted = !k.muted } }),
        .set_fill => |f| _ = call(.{ .set_fill = .{ .fill = f } }),
        .set_volume => |v| _ = call(.{ .set_volume = .{ .volume = v } }),
        .set_rule => |r| _ = call(.{ .set_rule = r }),
        .set_resume => |ms| _ = call(.{ .set_resume_after = .{ .ms = ms } }),
        .set_rotate => |m| _ = call(.{ .set_rotation = .{ .minutes = m } }),
        .set_order => |o| _ = call(.{ .set_rotation = .{ .order = o } }),
        .set_prop => |e| sendProp(e),
        .reset_props => _ = call(.reset_properties),
        .rescan => {
            _ = call(.rescan);
            app.library_reloads = 3;
        },
        .add_folder => return platform.pick(.folder),
        .remove_folder => |i| editList(.library_dirs, null, i),
        .add_app => return platform.pick(.app),
        .remove_app => |i| editList(.app_rules, null, i),
        .toggle_autostart => {
            platform.setAutostart(!app.autostart) catch showToast(if (app.autostart) "couldn't turn off starting at login" else "couldn't turn on starting at login");
            app.autostart = platform.autostartOn();
        },
        .open_log => platform.openFile(app.log_path),
        .reset => return platform.confirm("Put playback and pausing back to their defaults?\n\nYour wallpapers and folders stay as they are.", .reset_confirmed),
        .reset_confirmed => _ = call(.reset_settings),
        .uninstall => return platform.confirm(if (builtin.os.tag == .windows)
            "Remove zmural from this computer?\n\nIt stops, and its settings, Start menu entry and start at login go. Your wallpapers and their folders stay."
        else
            "Remove zmural from this computer?\n\nIt stops, and its settings, menu entry, start at login and desktop plugin go. Your wallpapers and their folders stay.", .uninstall_confirmed),
        // zmural removes itself, which quits this zmural, and this window
        // with it. On Linux it does so on its way out (`startUninstall` only
        // marks it), so ask it to quit here.
        .uninstall_confirmed => {
            platform.startUninstall() catch return showToast("can't find zmural next to this program");
            if (builtin.os.tag == .linux) _ = call(.quit);
        },
        .start_daemon => {
            platform.startDaemon() catch return showToast("can't find zmural next to this program");
            // Connect as soon as it's up (the poll keeps trying).
            app.last_connect_ms = 0;
            return;
        },
    }
    refreshSettings();
    refreshStatus();
}

fn sendProp(e: PropEdit) void {
    if (e.index >= app.known.props.len) return;
    _ = call(.{ .set_property = .{ .name = app.known.props[e.index].name, .value = e.text[0..e.len] } });
}

/// A slider position (0..1) as the property's value, on its step, as text.
fn propValue(it: props.Item, t: f32) PropEdit {
    var v = it.min + @as(f64, t) * (it.max - it.min);
    if (it.step > 0) v = it.min + @round((v - it.min) / it.step) * it.step;
    v = std.math.clamp(v, it.min, it.max);
    var e: PropEdit = .{ .index = 0 };
    // Two decimals are enough for any step a slider is drawn with, and keep
    // 0.1 + 0.2 from being sent as 0.30000000000000004.
    const text = std.fmt.bufPrint(&e.text, "{d}", .{@round(v * 100) / 100}) catch "";
    e.len = text.len;
    return e;
}

/// A picker's answer: `path` belongs to the caller.
pub fn picked(kind: PickKind, path: []const u8) void {
    switch (kind) {
        .wallpaper => if (std.ascii.endsWithIgnoreCase(path, ".zip")) startImport(path) else {
            _ = call(.{ .apply = .{ .path = path } });
        },
        .folder => editList(.library_dirs, path, null),
        .app => editList(.app_rules, std.fs.path.basename(path), null),
    }
    refreshSettings();
    refreshStatus();
    platform.redraw();
}

/// A tile's menu (`tileMenu`): the first line shows it everywhere, the last
/// shows its file, and the ones between put it on one monitor.
pub fn menuChosen(tile: usize, choice: usize) void {
    if (tile >= app.known.library.len) return;
    const path = app.known.library[tile];
    if (choice == 0) {
        _ = call(.{ .apply = .{ .path = path } });
    } else if (choice <= app.menu_monitors) {
        // By ID: the list may have changed since the menu opened.
        if (choice - 1 < app.known.monitors.len) _ = call(.{ .apply = .{ .path = path, .monitor = app.known.monitors[choice - 1].id } });
    } else if (choice == app.menu_monitors + 1) {
        platform.showInFolder(path);
    }
    refreshStatus();
    platform.redraw();
}

/// A confirmation was answered yes: do `action`.
pub fn confirmed(action: Action) void {
    app.pending = action;
    platform.redraw();
}

/// Sends a list with one item added or removed.
fn editList(which: control.ListKind, add: ?[]const u8, remove: ?usize) void {
    const info = app.known.info orelse return;
    const current = switch (which) {
        .app_rules => info.app_rules,
        .library_dirs => info.library_dirs,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    var it = std.mem.splitScalar(u8, current, control.list_sep);
    var i: usize = 0;
    while (it.next()) |item| : (i += 1) {
        if (item.len == 0 or remove == i) continue;
        if (out.items.len > 0) out.append(app.gpa, control.list_sep) catch return;
        out.appendSlice(app.gpa, item) catch return;
    }
    if (add) |item| {
        if (out.items.len > 0) out.append(app.gpa, control.list_sep) catch return;
        out.appendSlice(app.gpa, item) catch return;
    }
    _ = call(.{ .set_list = .{ .list = which, .items = out.items } });
}

/// A `.zip` picked in Open file: `zmural-console import <zip> --apply` runs as
/// its own process (a zip comes from anywhere, and a bug in reading one must
/// not take zmural down with this window), and says how it went in a file
/// that `onPoll` reads once it has finished.
fn startImport(zip_path: []const u8) void {
    if (app.importing) return showToast("an import is still running");
    const dir = std.fs.path.dirname(app.log_path) orelse return showToast("can't import: zmural has no folder of its own here");
    const rep = std.fmt.bufPrint(&app.import_report, "{s}{c}import-report.txt", .{ dir, std.fs.path.sep }) catch return showToast("can't import: path too long");
    app.import_report_len = rep.len;
    platform.startImport(zip_path, rep) catch |err| {
        var buf: [96]u8 = undefined;
        return showToast(std.fmt.bufPrint(&buf, "can't start the import ({s})", .{@errorName(err)}) catch "can't start the import");
    };
    app.importing = true;
    showToast("importing...");
}

fn importPoll() void {
    if (!app.importing or !platform.importFinished()) return;
    app.importing = false;
    var buf: [1024]u8 = undefined;
    const line = std.mem.trim(u8, platform.readSmall(app.import_report[0..app.import_report_len], &buf) orelse "", " \r\n");
    var msg: [160]u8 = undefined;
    if (std.mem.startsWith(u8, line, "ok ")) {
        showToast(std.fmt.bufPrint(&msg, "imported {s}", .{zmural.media.displayName(line[3..])}) catch "imported");
        app.library_reloads = 3;
    } else if (std.mem.startsWith(u8, line, "error ")) {
        showToast(line[6..]);
    } else showToast("the import ended without saying how it went (see zmural-console import)");
}

pub fn showToast(msg: []const u8) void {
    // Logged too: what the user was told is in the log they report, and the
    // rigs read it there.
    std.log.scoped(.settings).info("told: {s}", .{msg});
    const n = @min(msg.len, app.toast.len);
    @memcpy(app.toast[0..n], msg[0..n]);
    app.toast_len = n;
    app.toast_until_ms = platform.now() + 4000;
}

// ---- thumbnails ---------------------------------------------------------------------

fn thumbFor(path: []const u8) ?*Thumb {
    if (app.thumbs.getPtr(path)) |t| return t;
    const owned = app.gpa.dupe(u8, path) catch return null;
    app.thumbs.put(app.gpa, owned, .{}) catch {
        app.gpa.free(owned);
        return null;
    };
    platform.requestThumb(path);
    return app.thumbs.getPtr(path);
}

/// A thumbnail arrived: premultiplied BGRA, top-down, `width * 4` per row
/// (empty if there's none).
pub fn thumbReady(path: []const u8, pixels: []const u8, width: u32, height: u32) void {
    const t = app.thumbs.getPtr(path) orelse return;
    t.done = true;
    if (pixels.len == 0) return;
    t.img = app.ui.b.createImage(pixels, width, height) orelse return;
    t.width = @floatFromInt(width);
    t.height = @floatFromInt(height);
    platform.redraw();
}

/// A thumbnail the platform made itself (already an image of the backend's).
pub fn thumbImage(path: []const u8, img: ?*gui.Backend.Image, width: u32, height: u32) void {
    const t = app.thumbs.getPtr(path) orelse {
        if (img) |i| app.ui.b.destroyImage(i);
        return;
    };
    t.done = true;
    t.img = img orelse return;
    t.width = @floatFromInt(width);
    t.height = @floatFromInt(height);
    platform.redraw();
}

/// Images belong to the backend; when it loses its device, they go, and are made again.
pub fn dropThumbs() void {
    var it = app.thumbs.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.img) |img| app.ui.b.destroyImage(img);
        app.gpa.free(e.key_ptr.*);
    }
    app.thumbs.clearAndFree(app.gpa);
}

// ---- a frame ------------------------------------------------------------------------

/// Draws the window, then does whatever a click asked for.
pub fn frame() void {
    const ui = &app.ui;
    if (!ui.begin(platform.now())) return;
    // Under an open menu or dialog (Linux draws them in the window), the
    // pages see no pointer.
    const modal = platform.modal();
    const saved = .{ ui.mouse, ui.pressed, ui.released, ui.right_released, ui.wheel, ui.keys };
    if (modal) {
        ui.mouse = .{ .x = -1, .y = -1 };
        ui.pressed = false;
        ui.released = false;
        ui.right_released = false;
        ui.wheel = 0;
        ui.keys = .{};
    }
    platform.drawChrome();
    drawSidebar();
    drawPage();
    drawToast();
    if (modal) {
        ui.mouse, ui.pressed, ui.released, ui.right_released, ui.wheel, ui.keys = saved;
        // The menu or dialog has the keyboard; Tab stays inside it.
        ui.restartFocusOrder();
    }
    // Escape closes the window, unless it was for an open menu or question.
    const close = !modal and ui.keys.escape;
    platform.drawOverlay();
    if (!ui.end()) dropThumbs(); // device lost: images are remade on the next frame
    // Keep drawing while something animates (a hover fade, a toast, a knob).
    platform.wantAnimation(ui.animating or app.toast_until_ms > platform.now());
    if (app.pending) |action| {
        app.pending = null;
        perform(action);
        platform.redraw();
    }
    if (close) platform.requestClose();
}

// ---- drawing: sidebar -------------------------------------------------------------------

const pages = [_]struct { Page, []const u8, Icon }{
    .{ .welcome, "Welcome", .star },
    .{ .wallpapers, "Wallpapers", .pictures },
    .{ .playback, "Playback", .play },
    .{ .pausing, "Pausing", .pausing },
    .{ .general, "General", .settings },
};

fn drawSidebar() void {
    const ui = &app.ui;
    ui.beginGroup();
    const p = ui.pal;
    const top = platform.chromeHeight();
    var selected_y: f32 = 0;
    for (pages, 0..) |entry, i| {
        const r: Rect = .{ .x = 8, .y = top + 12 + @as(f32, @floatFromInt(i)) * 40, .w = sidebar_w - 16, .h = 36 };
        const in = ui.interact(key("nav", i), r);
        const is_sel = app.page == entry[0];
        if (is_sel) selected_y = r.y;
        const hover = ui.anim(key("nav-hover", i), if (in.hovered) 1 else 0);
        ui.fill(r, 4, if (in.held) p.subtle_pressed else if (is_sel) p.subtle_hover else gui.alpha(p.subtle_hover, hover));
        ui.glyph(.{ .x = r.x + 12, .y = r.y, .w = 20, .h = r.h }, entry[2], .icon, p.text);
        ui.text(.{ .x = r.x + 44, .y = r.y, .w = r.w - 52, .h = r.h }, entry[1], .body, .left, p.text);
        if (in.clicked and !is_sel) app.page = entry[0];
    }
    // The accent pill slides to the selected page.
    const py = ui.anim(key("nav-pill", 0), selected_y);
    ui.fill(.{ .x = 8, .y = py + 10, .w = 3, .h = 16 }, 1.5, p.accent);

    if (ui.size.y > 480 + top) drawNowPlaying();
}

fn drawNowPlaying() void {
    const ui = &app.ui;
    const p = ui.pal;
    const k = &app.known;
    const card_w = sidebar_w - 24;
    const thumb_h = (card_w - 16) * 9 / 16;
    const card: Rect = .{ .x = 12, .y = ui.size.y - thumb_h - 108, .w = card_w, .h = thumb_h + 96 };
    ui.card(card);
    const thumb: Rect = .{ .x = card.x + 8, .y = card.y + 8, .w = card.w - 16, .h = thumb_h };
    const online = app.client != null;
    drawThumb(thumb, if (online) k.wallpaper else "", 4);

    const name = if (!online) "zmural isn't running" else if (k.wallpaper.len == 0) "Nothing showing" else zmural.media.displayName(k.wallpaper);
    ui.text(.{ .x = card.x + 12, .y = thumb.bottom() + 6, .w = card.w - 24, .h = 20 }, name, .body_strong, .left, p.text);
    const state = if (!online) "Press Start zmural to bring it back" else if (k.wallpaper.len == 0) "Click a wallpaper to show it" else if (k.paused) "Paused" else if (k.muted) "Playing, muted" else "Playing";
    ui.text(.{ .x = card.x + 12, .y = thumb.bottom() + 24, .w = card.w - 24, .h = 16 }, state, .caption, .left, p.text2);

    if (!online) return;
    ui.beginGroup();
    const by = thumb.bottom() + 46;
    const bw: f32 = 40;
    const x0 = card.x + (card.w - 4 * bw - 3 * 4) / 2;
    const buttons = [_]struct { Icon, Action }{
        .{ .previous, .previous },
        .{ if (k.paused) .play else .pause, .toggle_paused },
        .{ .next, .next },
        .{ if (k.muted) .mute else .volume, .toggle_muted },
    };
    for (buttons, 0..) |b, i| {
        const r: Rect = .{ .x = x0 + @as(f32, @floatFromInt(i)) * (bw + 4), .y = by, .w = bw, .h = 32 };
        if (ui.button(key("np", i), r, "", b[0], .subtle)) app.pending = b[1];
    }
}

/// A wallpaper's thumbnail, or a quiet placeholder while there's none.
fn drawThumb(r: Rect, path: []const u8, radius: f32) void {
    const ui = &app.ui;
    const p = ui.pal;
    if (path.len > 0) {
        if (thumbFor(path)) |t| if (t.img) |img| return ui.image(r, radius, img, t.width, t.height);
    }
    ui.gradient(r, radius, gui.alpha(p.accent, 0.35), gui.alpha(p.accent, 0.08));
    const g: Icon = if (path.len == 0) .star else if (isVideo(path)) .video else .image;
    ui.glyph(r, g, .icon_large, gui.alpha(p.text, 0.5));
}

fn isVideo(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for (zmural_video_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

const zmural_video_exts = [_][]const u8{ ".mp4", ".mkv", ".webm", ".mov", ".avi", ".wmv", ".m4v" };

// ---- drawing: pages ---------------------------------------------------------------------

/// The content column: page title at the top, a scrolling body below it.
const Layout = struct {
    x: f32,
    w: f32,
    y: f32,
};

fn drawPage() void {
    const ui = &app.ui;
    const p = ui.pal;
    const top = platform.chromeHeight();
    const avail = ui.size.x - sidebar_w - 56;
    const cw = @min(content_max_w, @max(300, avail));
    const x = sidebar_w + 28;
    const title = switch (app.page) {
        .welcome => "Welcome to zmural",
        .wallpapers => "Wallpapers",
        .playback => "Playback",
        .pausing => "Pausing",
        .general => "General",
    };
    ui.text(.{ .x = x, .y = top + 12, .w = cw, .h = 44 }, title, .title, .left, p.text);

    const view: Rect = .{ .x = sidebar_w, .y = top + 64, .w = ui.size.x - sidebar_w, .h = ui.size.y - top - 64 };
    // Wheel scrolling, clamped to the content drawn last frame.
    const scroll = app.scroll.getPtr(app.page);
    if (ui.wheel != 0 and view.contains(ui.mouse)) scroll.* -= ui.wheel * 0.5;
    scroll.* = std.math.clamp(scroll.*, 0, @max(0, app.content_h - view.h + 24));
    // The keyboard moved the focus to something out of sight: scroll to it.
    if (ui.reveal) |r| {
        ui.reveal = null;
        if (r.x >= view.x) {
            if (r.y < view.y) scroll.* -= view.y - r.y + 12;
            if (r.bottom() > view.bottom()) scroll.* += r.bottom() - view.bottom() + 12;
            scroll.* = std.math.clamp(scroll.*, 0, @max(0, app.content_h - view.h + 24));
        }
    }
    const s = ui.anim(key("scroll", @intFromEnum(app.page)), scroll.*);

    if (app.page == .wallpapers and app.client != null) drawWallpaperButtons(x, cw, top);

    const saved = ui.pushClip(view);
    ui.beginGroup();
    var l: Layout = .{ .x = x, .w = cw, .y = view.y + 4 - s };
    const start = l.y;
    if (app.client == null) {
        offlineBanner(&l);
    } else switch (app.page) {
        .welcome => pageWelcome(&l),
        .wallpapers => pageWallpapers(&l),
        .playback => pagePlayback(&l),
        .pausing => pagePausing(&l),
        .general => pageGeneral(&l),
    }
    app.content_h = l.y - start;
    ui.popClip(saved);

    // A thin scroll indicator when the page is taller than the window.
    if (app.content_h > view.h) {
        const frac = view.h / app.content_h;
        const bar_h = @max(32, view.h * frac);
        const bar_y = view.y + (view.h - bar_h) * (s / @max(1, app.content_h - view.h + 24));
        ui.fill(.{ .x = ui.size.x - 6, .y = bar_y, .w = 3, .h = bar_h }, 1.5, p.text3);
    }
}

fn drawWallpaperButtons(x: f32, cw: f32, top: f32) void {
    const ui = &app.ui;
    ui.beginGroup();
    // Labels go, Rescan's first, when the row would run into the page title.
    const room = cw - ui.measure("Wallpapers", .title) - 24;
    const open_label = room >= 120 + 8 + 130 + 8 + 32;
    const rescan_label = room >= 120 + 8 + 130 + 8 + 110;
    const add: Rect = .{ .x = x + cw - 120, .y = top + 18, .w = 120, .h = 32 };
    const open_w: f32 = if (open_label) 130 else 32;
    const open: Rect = .{ .x = add.x - 8 - open_w, .y = top + 18, .w = open_w, .h = 32 };
    const rescan_w: f32 = if (rescan_label) 110 else 32;
    const rescan: Rect = .{ .x = open.x - 8 - rescan_w, .y = top + 18, .w = rescan_w, .h = 32 };
    if (ui.button(key("rescan", 0), rescan, if (rescan_label) "Rescan" else "", .rescan, .standard)) app.pending = .rescan;
    if (ui.button(key("open-file", 0), open, if (open_label) "Open file" else "", .open_file, .standard)) app.pending = .apply_file;
    if (ui.button(key("add-folder", 0), add, "Add folder", .add, .accent)) app.pending = .add_folder;
}

fn offlineBanner(l: *Layout) void {
    const ui = &app.ui;
    const p = ui.pal;
    const r: Rect = .{ .x = l.x, .y = l.y, .w = l.w, .h = 68 };
    ui.card(r);
    ui.fill(.{ .x = r.x, .y = r.y, .w = 4, .h = r.h }, 2, p.caution);
    ui.glyph(.{ .x = r.x + 16, .y = r.y, .w = 24, .h = r.h }, .warning, .icon, p.caution);
    ui.text(.{ .x = r.x + 52, .y = r.y + 14, .w = r.w - 220, .h = 20 }, "zmural isn't running", .body_strong, .left, p.text);
    ui.text(.{ .x = r.x + 52, .y = r.y + 34, .w = r.w - 220, .h = 18 }, "Wallpapers and these settings need it.", .caption, .left, p.text2);
    if (ui.button(key("start-daemon", 0), .{ .x = r.right() - 150, .y = r.y + 18, .w = 134, .h = 32 }, "Start zmural", .play, .accent))
        app.pending = .start_daemon;
    l.y += r.h + 16;
}

fn caption(l: *Layout, s: []const u8) void {
    const ui = &app.ui;
    ui.text(.{ .x = l.x, .y = l.y, .w = l.w, .h = 20 }, s, .body, .left, ui.pal.text2);
    l.y += 32;
}

fn groupHeader(l: *Layout, s: []const u8) void {
    const ui = &app.ui;
    ui.text(.{ .x = l.x + 2, .y = l.y, .w = l.w, .h = 20 }, s, .body_strong, .left, ui.pal.text);
    l.y += 28;
}

/// One settings row inside a card: icon, title and description on the left,
/// `control_w` kept free on the right. Returns the space for the control.
fn row(r: Rect, icon: ?Icon, title: []const u8, desc: []const u8, control_w: f32) Rect {
    const ui = &app.ui;
    const p = ui.pal;
    var tx = r.x + 16;
    if (icon) |g| {
        ui.glyph(.{ .x = r.x + 16, .y = r.y, .w = 20, .h = r.h }, g, .icon, p.text);
        tx = r.x + 52;
    }
    const text_w = @max(40, r.right() - 16 - control_w - 24 - tx);
    if (desc.len == 0) {
        ui.text(.{ .x = tx, .y = r.y, .w = text_w, .h = r.h }, title, .body, .left, p.text);
    } else {
        ui.text(.{ .x = tx, .y = r.y + r.h / 2 - 19, .w = text_w, .h = 20 }, title, .body, .left, p.text);
        ui.text(.{ .x = tx, .y = r.y + r.h / 2 + 1, .w = text_w, .h = 18 }, desc, .caption, .left, p.text2);
    }
    return .{ .x = tx + text_w, .y = r.y, .w = r.right() - 16 - (tx + text_w), .h = r.h };
}

/// A card holding one row.
fn cardRow(l: *Layout, h: f32, icon: ?Icon, title: []const u8, desc: []const u8, control_w: f32) Rect {
    const r: Rect = .{ .x = l.x, .y = l.y, .w = l.w, .h = h };
    app.ui.card(r);
    l.y += h + 4;
    return row(r, icon, title, desc, control_w);
}

/// Lines of text broken between words to fit the column.
fn paragraph(l: *Layout, s: []const u8, font: gui.Font, color: gui.Color) void {
    const ui = &app.ui;
    const line_h: f32 = if (font == .caption) 18 else 22;
    var rest = std.mem.trim(u8, s, " ");
    while (rest.len > 0) {
        // The longest run of whole words that fits; one word too long for the
        // column goes on its own line (and is clipped).
        var end: usize = 0;
        var i: usize = 0;
        while (i <= rest.len) : (i += 1) {
            if (i < rest.len and rest[i] != ' ') continue;
            if (end > 0 and ui.measure(rest[0..i], font) > l.w) break;
            end = i;
            if (i == rest.len) break;
        }
        ui.text(.{ .x = l.x, .y = l.y, .w = l.w, .h = line_h }, rest[0..end], font, .left, color);
        l.y += line_h;
        rest = std.mem.trimStart(u8, rest[end..], " ");
    }
}

/// "MP4, MKV, …" from a list of extensions, for the Welcome page.
fn extNames(comptime exts: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (exts, 0..) |e, i| {
            var up: [e.len - 1]u8 = undefined;
            _ = std.ascii.upperString(&up, e[1..]);
            const name = up;
            out = out ++ (if (i == 0) "" else ", ") ++ &name;
        }
        return out;
    }
}

/// First steps: what zmural is, a few wallpapers to click, where files go,
/// what can be a wallpaper. The window opens here while nothing is showing.
fn pageWelcome(l: *Layout) void {
    const ui = &app.ui;
    const p = ui.pal;
    const lib = app.known.library;
    paragraph(l, "zmural shows videos, pictures and offline web pages as your desktop wallpaper, behind your icons. " ++
        "It keeps running in the background: click its tray icon to come back here, or right-click it to pause, mute or skip.", .body, p.text2);
    l.y += 20;

    groupHeader(l, "Pick a wallpaper");
    if (lib.len == 0) {
        _ = cardRow(l, 68, .pictures, "No wallpapers yet", "Put some in a folder below; they show up here", 0);
    } else {
        const gap: f32 = 12;
        const cols: usize = @intFromFloat(std.math.clamp(@floor((l.w + gap) / (200 + gap)), 1, 4));
        const shown = @min(cols, lib.len);
        const cols_f: f32 = @floatFromInt(cols);
        const tw = (l.w - gap * (cols_f - 1)) / cols_f;
        const th = tw * 9 / 16;
        for (0..shown) |i| {
            const r: Rect = .{ .x = l.x + @as(f32, @floatFromInt(i)) * (tw + gap), .y = l.y, .w = tw, .h = th };
            wallpaperTile("welcome-tile", i, r);
        }
        l.y += th + gap;
        ui.text(.{ .x = l.x, .y = l.y, .w = l.w - 150, .h = 32 }, "Click one to show it.", .body, .left, p.text2);
        if (ui.button(key("welcome-all", 0), .{ .x = l.x + l.w - 140, .y = l.y, .w = 140, .h = 32 }, "Wallpapers", .pictures, .standard))
            app.pending = .{ .show_page = .wallpapers };
        l.y += 44;
    }
    l.y += 16;

    groupHeader(l, "Where to put them");
    if (app.known.info) |info| {
        var it = std.mem.splitScalar(u8, info.default_dirs, control.list_sep);
        var i: usize = 0;
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            defer i += 1;
            const c = cardRow(l, 68, .folder, dir, "zmural looks here by itself", 100);
            if (ui.button(key("welcome-open", i), .{ .x = c.right() - 100, .y = c.y + 18, .w = 100, .h = 32 }, "Open", null, .standard))
                app.pending = .{ .open_folder = i };
        }
    }
    var c = cardRow(l, 68, .add, "A folder of your own", "Wallpapers kept anywhere else", 130);
    if (ui.button(key("welcome-add", 0), .{ .x = c.right() - 130, .y = c.y + 18, .w = 130, .h = 32 }, "Add folder", .add, .standard))
        app.pending = .add_folder;
    c = cardRow(l, 68, .open_file, "One file, or a .zip", "A .zip is unpacked into the first folder", 130);
    if (ui.button(key("welcome-file", 0), .{ .x = c.right() - 130, .y = c.y + 18, .w = 130, .h = 32 }, "Open file", .open_file, .standard))
        app.pending = .apply_file;
    l.y += 20;

    groupHeader(l, "What can be a wallpaper");
    const media = zmural.media;
    _ = cardRow(l, 68, .video, "Videos", comptime extNames(&media.video_exts), 0);
    _ = cardRow(l, 68, .image, "Pictures", comptime extNames(&media.image_exts), 0);
    _ = cardRow(l, 68, .document, "Web pages", "An .html file or a package; always offline", 0);
    _ = cardRow(l, 68, .folder, "Packages in a .zip", "zmural's and Lively Wallpaper's", 0);
    l.y += 20;

    groupHeader(l, "Good to know");
    _ = cardRow(l, 68, .pausing, "Games come first", "The Pausing page sets when wallpapers pause", 0);
    _ = cardRow(l, 68, .next, "A new one now and then", "The Playback page can change it on a timer", 0);
    _ = cardRow(l, 68, .power, if (app.autostart) "Starts when you sign in" else "Doesn't start when you sign in", "Change that on the General page", 0);
    l.y += 8;
}

fn pageWallpapers(l: *Layout) void {
    const ui = &app.ui;
    const p = ui.pal;
    const lib = app.known.library;
    var buf: [96]u8 = undefined;
    const summary = if (lib.len == 0) "" else std.fmt.bufPrint(&buf, "{d} wallpaper{s}. Click one to show it; right-click (or the Menu key) for more.", .{ lib.len, if (lib.len == 1) "" else "s" }) catch "";
    if (lib.len == 0) {
        const r: Rect = .{ .x = l.x, .y = l.y + 40, .w = l.w, .h = 200 };
        ui.glyph(.{ .x = r.x, .y = r.y, .w = r.w, .h = 60 }, .pictures, .icon_large, p.text3);
        ui.text(.{ .x = r.x, .y = r.y + 70, .w = r.w, .h = 28 }, "No wallpapers yet", .subtitle, .center, p.text);
        ui.text(.{ .x = r.x, .y = r.y + 104, .w = r.w, .h = 20 }, platform.library_hint, .body, .center, p.text2);
        l.y = r.bottom();
        return;
    }
    caption(l, summary);

    const gap: f32 = 12;
    const cols: usize = @intFromFloat(@max(1, @floor((l.w + gap) / (216 + gap))));
    const cols_f: f32 = @floatFromInt(cols);
    const tw = (l.w - gap * (cols_f - 1)) / cols_f;
    const th = tw * 9 / 16;
    for (0..lib.len) |i| {
        const col: f32 = @floatFromInt(i % cols);
        const rw: f32 = @floatFromInt(i / cols);
        const r: Rect = .{ .x = l.x + col * (tw + gap), .y = l.y + rw * (th + gap), .w = tw, .h = th };
        if (r.bottom() < ui.clip.y or r.y > ui.clip.bottom()) {
            // Off screen: don't even make its thumbnail, but Tab still reaches it.
            _ = ui.focusable(key("tile", i), r);
            continue;
        }
        wallpaperTile("tile", i, r);
    }
    const rows = (lib.len + cols - 1) / cols;
    l.y += @as(f32, @floatFromInt(rows)) * (th + gap) + 12;
}

/// One wallpaper's thumbnail with its name: click shows it, right-click (or
/// the Menu key) opens its menu. `name` keeps each page's tiles apart.
fn wallpaperTile(comptime name: []const u8, i: usize, r: Rect) void {
    const ui = &app.ui;
    const p = ui.pal;
    const path = app.known.library[i];
    const in = ui.interact(key(name, i), r);
    const hover = ui.anim(key(name ++ "-hover", i), if (in.hovered) 1 else 0);
    const lift = hover * 2;
    const tr: Rect = .{ .x = r.x - lift, .y = r.y - lift, .w = r.w + 2 * lift, .h = r.h + 2 * lift };
    drawThumb(tr, path, 6);
    // A dark fade under the name, so it reads on any picture.
    const scrim: Rect = .{ .x = tr.x, .y = tr.y + tr.h * 0.55, .w = tr.w, .h = tr.h * 0.45 };
    ui.gradient(scrim, 6, gui.rgba(0x00000000), gui.rgba(0x000000A6));
    ui.text(.{ .x = tr.x + 10, .y = tr.bottom() - 30, .w = tr.w - 20, .h = 24 }, zmural.media.displayName(path), .body, .left, gui.rgba(0xFFFFFFFF));
    const current = std.ascii.eqlIgnoreCase(path, app.known.wallpaper);
    if (current) {
        ui.stroke(tr.inset(-3, -3), 9, p.accent, 2);
        const c: gui.Point = .{ .x = tr.right() - 16, .y = tr.y + 16 };
        ui.circle(c, 11, p.accent);
        ui.glyph(.{ .x = c.x - 11, .y = c.y - 11, .w = 22, .h = 22 }, .check, .icon, p.on_accent);
    } else if (hover > 0) ui.stroke(tr, 6, gui.alpha(p.text, 0.35 * hover), 1);
    // The focus ring outside the current wallpaper's accent ring, so both show.
    if (ui.focus_visible and ui.focus == key(name, i)) ui.stroke(tr.inset(-7, -7), 12, p.text, 2);
    if (in.clicked and !current) app.pending = .{ .apply = i };
    if (in.right_clicked) app.pending = .{ .tile_menu = i };
}

fn pagePlayback(l: *Layout) void {
    const ui = &app.ui;
    const p = ui.pal;
    const info = app.known.info orelse return;
    caption(l, "Changes apply straight away.");

    const fills = [_]FillMode{ .crop, .fit, .stretch, .center };
    const fill_desc = switch (info.fill) {
        .crop => "Fills the screen, trimming the edges",
        .fit => "Shows all of it, with bars if the shape differs",
        .stretch => "Fills the screen, ignoring the shape",
        .center => "Original size, in the middle",
    };
    var c = cardRow(l, 68, .fit, "Fit", fill_desc, 320);
    const seg: Rect = .{ .x = c.right() - 320, .y = c.y + 18, .w = 320, .h = 32 };
    if (ui.segmented(key("fill", 0), seg, &.{ "Crop", "Fit", "Stretch", "Center" }, @intFromEnum(info.fill))) |i| app.pending = .{ .set_fill = fills[i] };

    c = cardRow(l, 68, .volume, "Volume", "For wallpapers with sound, when they aren't muted", 272);
    const vol = app.volume_drag orelse @as(f32, @floatFromInt(info.volume)) / 100;
    const sr: Rect = .{ .x = c.right() - 260, .y = c.y + 24, .w = 200, .h = 20 };
    const res = ui.slider(key("volume", 0), sr, vol);
    const vol_pct: u8 = @intFromFloat(@round(res.value * 100));
    if (res.changed) {
        app.volume_drag = res.value;
        // Live while dragging, but not on every pixel.
        const now = platform.now();
        if (now -| app.last_volume_send_ms > 80) {
            app.last_volume_send_ms = now;
            _ = call(.{ .set_volume = .{ .volume = vol_pct } });
        }
    }
    if (res.released and app.volume_drag != null) {
        app.volume_drag = null;
        app.pending = .{ .set_volume = vol_pct };
    }
    var vbuf: [8]u8 = undefined;
    ui.text(.{ .x = sr.right() + 12, .y = c.y, .w = 48, .h = c.h }, std.fmt.bufPrint(&vbuf, "{d}%", .{vol_pct}) catch "", .body, .right, p.text);

    c = cardRow(l, 68, .mute, "Mute wallpapers", "Wallpapers start silent; turn this off to hear them", 100);
    if (ui.toggle(key("muted", 0), c.right(), c.y + c.h / 2, app.known.muted)) app.pending = .toggle_muted;

    c = cardRow(l, 68, .pause, "Pause wallpapers", "Hold the current picture until you turn this off", 100);
    if (ui.toggle(key("paused", 0), c.right(), c.y + c.h / 2, app.known.paused)) app.pending = .toggle_paused;

    pageProperties(l);

    l.y += 20;
    groupHeader(l, "Change wallpaper automatically");
    const k = &app.known;
    var desc_buf: [96]u8 = undefined;
    const rotate_desc = rotateDescription(&desc_buf, k.rotate_minutes, k.next_change_s);
    c = cardRow(l, 68, .next, "Change every", rotate_desc, 420);
    const rseg: Rect = .{ .x = c.right() - 420, .y = c.y + 18, .w = 420, .h = 32 };
    if (ui.segmented(key("rotate", 0), rseg, &rotate_labels, nearestPreset(k.rotate_minutes))) |i| {
        if (rotate_presets[i] != k.rotate_minutes) app.pending = .{ .set_rotate = rotate_presets[i] };
    }

    const orders = [_]control.Order{ .sequential, .shuffle, .random };
    const order_desc = switch (k.order) {
        .sequential => "By name, for timed changes and Next / Previous",
        .shuffle => "Every wallpaper once per round, in a random order",
        .random => "Any other wallpaper, each time",
    };
    c = cardRow(l, 68, .pictures, "Order", order_desc, 320);
    const oseg: Rect = .{ .x = c.right() - 320, .y = c.y + 18, .w = 320, .h = 32 };
    if (ui.segmented(key("order", 0), oseg, &.{ "By name", "Shuffle", "Random" }, @intFromEnum(k.order))) |i| {
        if (orders[i] != k.order) app.pending = .{ .set_order = orders[i] };
    }
}

/// "Customise": the main wallpaper's own properties, one row each. A plain
/// video or picture has the built-in adjustments; a package brings its own.
fn pageProperties(l: *Layout) void {
    const ui = &app.ui;
    const p = ui.pal;
    const items = app.known.props;
    if (items.len == 0) return;
    l.y += 20;
    var title_buf: [120]u8 = undefined;
    groupHeader(l, std.fmt.bufPrint(&title_buf, "Customise {s}", .{app.known.props_title}) catch "Customise this wallpaper");
    for (items, 0..) |it, i| switch (it.kind) {
        .slider => {
            const c = cardRow(l, 56, null, it.label, "", 272);
            const span = it.max - it.min;
            const now_v = std.fmt.parseFloat(f64, it.value) catch it.min;
            var t: f32 = if (span > 0) @floatCast((now_v - it.min) / span) else 0;
            if (app.prop_drag) |d| if (d.index == i) {
                t = d.t;
            };
            const sr: Rect = .{ .x = c.right() - 260, .y = c.y + 18, .w = 200, .h = 20 };
            const res = ui.slider(key("prop", i), sr, t);
            var edit = propValue(it, res.value);
            edit.index = i;
            if (res.changed) {
                app.prop_drag = .{ .index = i, .t = res.value };
                // Live while dragging, but not on every pixel.
                const now = platform.now();
                if (now -| app.last_prop_send_ms > 80) {
                    app.last_prop_send_ms = now;
                    sendProp(edit);
                }
            }
            if (res.released) if (app.prop_drag) |d| if (d.index == i) {
                app.prop_drag = null;
                app.pending = .{ .set_prop = edit };
            };
            ui.text(.{ .x = sr.right() + 12, .y = c.y, .w = 48, .h = c.h }, edit.text[0..edit.len], .body, .right, p.text);
        },
        .checkbox => {
            const c = cardRow(l, 56, null, it.label, "", 100);
            const on = std.mem.eql(u8, it.value, "true");
            if (ui.toggle(key("prop", i), c.right(), c.y + c.h / 2, on)) {
                var e: PropEdit = .{ .index = i };
                const text = if (on) "false" else "true";
                @memcpy(e.text[0..text.len], text);
                e.len = text.len;
                app.pending = .{ .set_prop = e };
            }
        },
        .dropdown => if (it.options.len >= 2 and it.options.len <= 4) {
            const w: f32 = 100 * @as(f32, @floatFromInt(it.options.len));
            const c = cardRow(l, 56, null, it.label, "", w);
            var selected: usize = 0;
            for (it.options, 0..) |o, j| if (std.mem.eql(u8, o, it.value)) {
                selected = j;
            };
            if (ui.segmented(key("prop", i), .{ .x = c.right() - w, .y = c.y + 12, .w = w, .h = 32 }, it.options, selected)) |j| {
                if (j != selected and it.options[j].len <= 32) {
                    var e: PropEdit = .{ .index = i };
                    @memcpy(e.text[0..it.options[j].len], it.options[j]);
                    e.len = it.options[j].len;
                    app.pending = .{ .set_prop = e };
                }
            }
        } else readOnlyProperty(l, it),
        // No colour picker or text box in this window yet: shown, not edited.
        .color, .text => readOnlyProperty(l, it),
    };
    const c = cardRow(l, 56, .reset, "Reset", "Put this wallpaper's settings back as they came", 100);
    if (ui.button(key("prop-reset", 0), .{ .x = c.right() - 100, .y = c.y + 12, .w = 100, .h = 32 }, "Reset", null, .standard)) app.pending = .reset_props;
}

fn readOnlyProperty(l: *Layout, it: props.Item) void {
    const c = cardRow(l, 56, null, it.label, "Change it with `zmural-console prop` in a terminal", 200);
    app.ui.text(.{ .x = c.right() - 200, .y = c.y, .w = 200, .h = c.h }, it.value, .body, .right, app.ui.pal.text);
}

/// The intervals the settings window offers, in minutes (0 = never). The
/// file can hold any other up to a week; the nearest one is then highlighted.
const rotate_presets = [_]u16{ 0, 5, 15, 30, 60, 180 };
const rotate_labels = [_][]const u8{ "Off", "5 min", "15 min", "30 min", "1 h", "3 h" };

fn nearestPreset(minutes: u16) usize {
    var best: usize = 0;
    for (rotate_presets, 0..) |m, i| {
        const d = @max(m, minutes) - @min(m, minutes);
        const bd = @max(rotate_presets[best], minutes) - @min(rotate_presets[best], minutes);
        if (d < bd) best = i;
    }
    // Never highlight "Off" for an interval that is on.
    return if (best == 0 and minutes != 0) 1 else best;
}

fn rotateDescription(buf: []u8, minutes: u16, next_s: u32) []const u8 {
    if (minutes == 0) return "Keep the same wallpaper until you change it";
    const next_min = (next_s + 59) / 60;
    return (if (minutes % 60 == 0)
        std.fmt.bufPrint(buf, "Every {d} h of playing time; next in {d} min", .{ minutes / 60, next_min })
    else
        std.fmt.bufPrint(buf, "Every {d} min of playing time; next in {d} min", .{ minutes, next_min })) catch "";
}

test nearestPreset {
    try std.testing.expectEqual(@as(usize, 0), nearestPreset(0));
    try std.testing.expectEqual(@as(usize, 1), nearestPreset(1));
    try std.testing.expectEqual(@as(usize, 2), nearestPreset(15));
    try std.testing.expectEqual(@as(usize, 3), nearestPreset(40));
    try std.testing.expectEqual(@as(usize, 5), nearestPreset(10080));
}

const windows = builtin.os.tag == .windows;

const RuleRow = struct { policy.Condition, []const u8, []const u8, Icon };
const rule_groups = [_]struct { []const u8, []const RuleRow }{
    .{ "When other windows need the screen", &.{
        .{ .fullscreen, "A game or app is fullscreen", "All monitors", .fullscreen },
        .{ .maximized, "A window is maximized", "That monitor", .app },
        .{ .covered, "Windows cover the screen", "That monitor", .app },
        .{ .focused, "Any window is in focus", "That monitor", .app },
        .{ .app_rule, "One of your apps is in front", "All monitors", .star },
    } },
    .{ "Power", &.{
        .{ .on_battery, "Running on battery", "All monitors", .battery },
        .{ .power_saver, if (windows) "Battery saver is on" else "Power Saver mode is on", "All monitors", .battery },
    } },
    .{ "Session", &.{
        .{ .session_locked, "The screen is locked", "All monitors", .lock },
        .{ .session_inactive, "Someone else is signed in, or a text console is in front", "All monitors", .lock },
        .{ .remote_session, if (windows) "A Remote Desktop session" else "A remote session", "All monitors", .remote },
        .{ .game_mode, if (windows) "Game Mode is on" else "A game turned on GameMode", "All monitors", .star },
        .{ .other_audio, "Another app plays sound", "All monitors", .volume },
    } },
};

fn pagePausing(l: *Layout) void {
    const ui = &app.ui;
    const p = ui.pal;
    const info = app.known.info orelse return;
    caption(l, "What wallpapers do when something else needs the screen.");
    const actions = [_]policy.Action{ .none, .mute, .pause, .stop };
    for (rule_groups) |group| {
        var shown: usize = 0;
        for (group[1]) |r| shown += @intFromBool(info.exposed[@intFromEnum(r[0])]);
        if (shown == 0) continue;
        groupHeader(l, group[0]);
        for (group[1]) |r| {
            const ci = @intFromEnum(r[0]);
            if (!info.exposed[ci]) continue;
            const is_apps = r[0] == .app_rule;
            const apps_h: f32 = if (is_apps) appListHeight() else 0;
            const card: Rect = .{ .x = l.x, .y = l.y, .w = l.w, .h = 64 + apps_h };
            ui.card(card);
            const c = row(.{ .x = card.x, .y = card.y, .w = card.w, .h = 64 }, r[3], r[1], r[2], 300);
            const seg: Rect = .{ .x = c.right() - 300, .y = c.y + 16, .w = 300, .h = 32 };
            const cur = std.mem.findScalar(policy.Action, &actions, info.rules[ci]) orelse 0;
            if (ui.segmented(key("rule", ci), seg, &.{ "Nothing", "Mute", "Pause", "Stop" }, cur)) |i|
                app.pending = .{ .set_rule = .{ .condition = r[0], .action = actions[i] } };
            if (is_apps) drawAppList(.{ .x = card.x, .y = card.y + 64, .w = card.w, .h = apps_h }, info.app_rules);
            l.y += card.h + 4;
        }
        l.y += 20;
    }

    groupHeader(l, "Resuming");
    const c = cardRow(l, 68, .play, "Wait before resuming", "How long a situation must be over before wallpapers play again", 272);
    const max_ms: f32 = 5000;
    const cur = app.resume_drag orelse @as(f32, @floatFromInt(@min(info.resume_after_ms, 5000))) / max_ms;
    const sr: Rect = .{ .x = c.right() - 260, .y = c.y + 24, .w = 200, .h = 20 };
    const res = ui.slider(key("resume", 0), sr, cur);
    const ms: u32 = @intFromFloat(@round(res.value * max_ms / 100) * 100);
    if (res.changed) app.resume_drag = res.value;
    if (res.released and app.resume_drag != null) {
        app.resume_drag = null;
        app.pending = .{ .set_resume = ms };
    }
    var buf: [16]u8 = undefined;
    ui.text(.{ .x = sr.right() + 8, .y = c.y, .w = 52, .h = c.h }, std.fmt.bufPrint(&buf, "{d}.{d} s", .{ ms / 1000, ms % 1000 / 100 }) catch "", .body, .right, p.text);

    l.y += 8;
    ui.text(.{ .x = l.x, .y = l.y, .w = l.w, .h = 18 }, "Mute silences the sound. Pause holds the picture. Stop closes the wallpaper to free memory;", .caption, .left, p.text2);
    ui.text(.{ .x = l.x, .y = l.y + 18, .w = l.w, .h = 18 }, "it starts again when the situation is over.", .caption, .left, p.text2);
    l.y += 48;
}

fn appListHeight() f32 {
    const n = countItems(if (app.known.info) |i| i.app_rules else "");
    return 12 + @as(f32, @floatFromInt(n)) * 36 + 44;
}

fn countItems(list: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, list, control.list_sep);
    while (it.next()) |x| n += @intFromBool(x.len > 0);
    return n;
}

/// The app rules under their row: one line per app with a remove button, then "Add app".
fn drawAppList(r: Rect, list: []const u8) void {
    const ui = &app.ui;
    const p = ui.pal;
    ui.line(.{ .x = r.x, .y = r.y }, .{ .x = r.right(), .y = r.y }, p.divider, 1);
    var y = r.y + 8;
    var it = std.mem.splitScalar(u8, list, control.list_sep);
    var i: usize = 0;
    while (it.next()) |name| {
        if (name.len == 0) continue;
        defer i += 1;
        ui.text(.{ .x = r.x + 52, .y = y, .w = r.w - 120, .h = 32 }, name, .body, .left, p.text);
        if (ui.button(key("app-remove", i), .{ .x = r.right() - 56, .y = y, .w = 40, .h = 32 }, "", .close, .subtle))
            app.pending = .{ .remove_app = i };
        y += 36;
    }
    if (ui.button(key("app-add", 0), .{ .x = r.x + 48, .y = y + 2, .w = 130, .h = 32 }, "Add app", .add, .standard))
        app.pending = .add_app;
}

fn pageGeneral(l: *Layout) void {
    const ui = &app.ui;
    const p = ui.pal;
    const info = app.known.info orelse return;

    var c = cardRow(l, 68, .power, platform.autostart_title, "Show your wallpaper as soon as you sign in", 100);
    if (ui.toggle(key("autostart", 0), c.right(), c.y + c.h / 2, app.autostart)) app.pending = .toggle_autostart;
    l.y += 20;

    // Library folders: the standard ones (always scanned), then the user's own.
    groupHeader(l, "Library folders");
    const defaults = countItems(info.default_dirs);
    const user = countItems(info.library_dirs);
    const card: Rect = .{ .x = l.x, .y = l.y, .w = l.w, .h = @as(f32, @floatFromInt(defaults + user)) * 52 + 56 };
    ui.card(card);
    var y = card.y;
    var it = std.mem.splitScalar(u8, info.default_dirs, control.list_sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        _ = row(.{ .x = card.x, .y = y, .w = card.w, .h = 52 }, .folder, dir, "Always included", 0);
        y += 52;
        ui.line(.{ .x = card.x, .y = y }, .{ .x = card.right(), .y = y }, p.divider, 1);
    }
    it = std.mem.splitScalar(u8, info.library_dirs, control.list_sep);
    var i: usize = 0;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        defer i += 1;
        const rc = row(.{ .x = card.x, .y = y, .w = card.w, .h = 52 }, .folder, dir, "", 40);
        if (ui.button(key("dir-remove", i), .{ .x = rc.right() - 40, .y = y + 10, .w = 40, .h = 32 }, "", .close, .subtle))
            app.pending = .{ .remove_folder = i };
        y += 52;
        ui.line(.{ .x = card.x, .y = y }, .{ .x = card.right(), .y = y }, p.divider, 1);
    }
    if (ui.button(key("dir-add", 0), .{ .x = card.x + 48, .y = y + 12, .w = 130, .h = 32 }, "Add folder", .add, .standard))
        app.pending = .add_folder;
    l.y = card.bottom() + 24;

    // Every setting has its control in this window; settings.toml is not
    // offered as a document to edit.
    groupHeader(l, "Troubleshooting");
    // A crash notice can go unseen (Do Not Disturb drops it on Windows), so
    // the line to report stays here until zmural restarts.
    if (app.known.crash.len > 0) _ = cardRow(l, 68, .warning, "zmural ran into a problem", app.known.crash, 0);
    if (app.log_path.len > 0) {
        c = cardRow(l, 68, .log, "Log file", "What zmural has been doing, for troubleshooting", 100);
        if (ui.button(key("open-log", 0), .{ .x = c.right() - 100, .y = c.y + 18, .w = 100, .h = 32 }, "Open", null, .standard)) app.pending = .open_log;
    }
    c = cardRow(l, 68, .reset, "Reset playback and pausing", "Back to the defaults. Wallpapers and folders stay", 100);
    if (ui.button(key("reset", 0), .{ .x = c.right() - 100, .y = c.y + 18, .w = 100, .h = 32 }, "Reset", null, .standard)) app.pending = .reset;
    l.y += 8;
    c = cardRow(l, 68, .close, "Uninstall zmural", "Removes zmural's settings, menu entry and start at login. Your wallpapers stay", 100);
    if (ui.button(key("uninstall", 0), .{ .x = c.right() - 100, .y = c.y + 18, .w = 100, .h = 32 }, "Uninstall", null, .standard)) app.pending = .uninstall;
    l.y += 20;

    groupHeader(l, "About");
    _ = cardRow(l, 68, .star, "zmural " ++ zmural.version, "Free software (GPL-3.0-or-later). Video playback by libmpv (LGPL-2.1)", 0);
}

fn drawToast() void {
    const ui = &app.ui;
    if (app.toast_len == 0 or platform.now() > app.toast_until_ms) return;
    const p = ui.pal;
    const msg = app.toast[0..app.toast_len];
    const tw = @min(ui.size.x - sidebar_w - 80, ui.measure(msg, .body) + 64);
    const r: Rect = .{ .x = sidebar_w + (ui.size.x - sidebar_w - tw) / 2, .y = ui.size.y - 64, .w = tw, .h = 44 };
    ui.fill(r, 8, if (p.dark) gui.rgba(0x2C2C2CF2) else gui.rgba(0xFFFFFFF2));
    ui.stroke(r, 8, p.card_stroke, 1);
    ui.glyph(.{ .x = r.x + 12, .y = r.y, .w = 20, .h = r.h }, .info, .icon, p.caution);
    ui.text(.{ .x = r.x + 44, .y = r.y, .w = r.w - 56, .h = r.h }, msg, .body, .left, p.text);
    ui.animating = true;
}

test "a slider position becomes a value on the property's step, as short text" {
    const speed: props.Item = .{ .name = "speed", .kind = .slider, .label = "", .value = "1", .default = "1", .min = 0.25, .max = 4, .step = 0.05, .options = &.{} };
    const at = struct {
        fn f(it: props.Item, t: f32) []const u8 {
            const S = struct {
                var e: PropEdit = undefined;
            };
            S.e = propValue(it, t);
            return S.e.text[0..S.e.len];
        }
    }.f;
    try std.testing.expectEqualStrings("0.25", at(speed, 0));
    try std.testing.expectEqualStrings("4", at(speed, 1));
    try std.testing.expectEqualStrings("1", at(speed, 0.2));
    try std.testing.expectEqualStrings("2.1", at(speed, 0.4933));
    const level: props.Item = .{ .name = "brightness", .kind = .slider, .label = "", .value = "0", .default = "0", .min = -100, .max = 100, .step = 1, .options = &.{} };
    try std.testing.expectEqualStrings("-100", at(level, 0));
    try std.testing.expectEqualStrings("0", at(level, 0.5));
    try std.testing.expectEqualStrings("37", at(level, 0.6849));
    // Past the ends stays inside the range.
    try std.testing.expectEqualStrings("100", at(level, 1.4));
}
