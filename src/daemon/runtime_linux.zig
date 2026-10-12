// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The daemon on Linux: display hosts, renderers, and the frames between them.
//!
//! - Display hosts (`zmural-layer-shell`, the KDE Plasma plugin, the GNOME
//!   extension) connect to `$XDG_RUNTIME_DIR/zmural/display.sock`, one
//!   connection per monitor, and speak waywallen-display-v1 v9
//!   (`display_session.zig`). Each registered monitor is routed to a renderer
//!   (`router.zig`); monitors showing the same wallpaper share one.
//! - Renderers are spawned with one end of a socketpair (`--ipc fd:N`), so
//!   only the daemon can talk to them. `lifecycle.zig` decides restarts and
//!   pause/stop, exactly as on Windows.
//! - Frames: a renderer announces each monitor's pool of DMA-BUFs once
//!   (`buffers`), then names a slot per frame. The daemon forwards both to
//!   that monitor's host with the fds attached, plus an acquire fence and a
//!   release syncobj per frame; a slot goes back to the renderer once the
//!   host's release fence signals. It never touches pixels.
//!
//! Single-threaded: one poll loop over every socket and each renderer's
//! pidfd (so a crash is noticed at once, and reaped).
//!
//! System facts (battery, lock, GameMode) come from `facts_linux.zig`.
//! Not yet (M6): spawning the display host itself.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const unix = zmural.protocol.unix;
const ww = zmural.protocol.ww_display;
const syncobj = zmural.os.syncobj;
const Session = @import("display_session.zig").Session;
const dbus = zmural.os.dbus;
const desktop = @import("desktop_linux.zig");
const backend = @import("hosts").linux;
const compositor = @import("compositor.zig");
const niri_ipc = @import("compositor_niri.zig");
const control = zmural.protocol.control;
const autostart = zmural.os.autostart_linux;
const notices = @import("notices.zig");
const foreground = @import("foreground_linux.zig");
const monitors = @import("monitors.zig");
const adjust = @import("adjust.zig");
const Fallback = @import("fallback.zig").Fallback;
const starter = @import("starter.zig");
const props = zmural.properties;
const SettingsStore = @import("settings.zig").Store;
const settings_file = @import("settings.zig");
const Library = @import("library.zig").Library;
const lists = @import("lists.zig");
const Tray = @import("tray_linux.zig").Tray;
const proto = zmural.protocol.renderer;
const transport = zmural.protocol.transport;
const policy = zmural.policy;
const MonitorId = zmural.monitor.Id;
const Router = @import("router.zig").Router;
const RendererId = @import("router.zig").RendererId;
const lifecycle = @import("lifecycle.zig");
const desire = @import("desire.zig");
const kind_mod = @import("kind.zig");
const settings_window = @import("settings");
const Kind = kind_mod.Kind;
const Settings = @import("settings.zig").Settings;
const Rotation = @import("rotation.zig").Rotation;
const facts = @import("facts_linux.zig");

const log = std.log.scoped(.daemon);

const max_displays = 16;
const tick_ms = 250;
const stop_grace_ms = 1_000;
/// A peer that stops reading for this long is dropped rather than waited on.
const send_timeout_ms = 2_000;

/// A display connection and the renderer routed to it (surface id = its id).
const Display = struct {
    s: Session,
    renderer: ?RendererId = null,
};

const Renderer = struct {
    id: RendererId,
    kind: Kind,
    /// The wallpaper it shows (owned): monitors can show different ones.
    path: []u8,
    /// How it fills the screen: monitors can differ in that too.
    fill: zmural.layout.FillMode,
    /// It shows the main wallpaper, whose properties are the ones a client sets.
    main: bool,
    sup: lifecycle.Supervisor = .{},
    conn: ?unix.Conn = null,
    pid: ?linux.pid_t = null,
    pidfd: linux.fd_t = -1,
    ready: bool = false,
    /// When a deliberate stop was asked for (kill after `stop_grace_ms`).
    stop_at: ?u64 = null,
};

pub const Options = struct {
    wallpaper: ?[]const u8,
    start_paused: bool,
    xdg_runtime_dir: []const u8,
    /// This program's folder (the settings window and the plugin zips are
    /// found from it), and its own path: what it starts again as a renderer.
    exe_dir: []const u8,
    exe_path: []const u8,
    dbus_address: ?[]const u8 = null,
    /// `DBUS_SYSTEM_BUS_ADDRESS`, if set.
    dbus_system_address: ?[]const u8 = null,
    desktop: desktop.Env,
    /// Where settings are saved (the wallpaper, paused, muted).
    store: ?*SettingsStore = null,
    /// `$XDG_CONFIG_HOME`, for the autostart entry and `user-dirs.dirs`.
    xdg_config_home: ?[]const u8 = null,
    /// `$SWAYSOCK`: running on Sway, whose IPC says more about windows.
    swaysock: ?[]const u8 = null,
    /// `$HYPRLAND_INSTANCE_SIGNATURE` and `$WAYFIRE_SOCKET` (`compositor.zig`).
    hyprland_signature: ?[]const u8 = null,
    wayfire_socket: ?[]const u8 = null,
    /// `$NIRI_SOCKET`: running on Niri, whose IPC says what is in front.
    niri_socket: ?[]const u8 = null,
    /// `$XDG_VIDEOS_DIR` and `$XDG_PICTURES_DIR`, if set.
    videos_dir_env: ?[]const u8 = null,
    pictures_dir_env: ?[]const u8 = null,
    /// The version `welcome` reports (tests set another to check upgrades).
    report_version: []const u8 = zmural.version,
    /// Where zmural keeps what it has already told the user (next to the log).
    state_dir: ?[]const u8 = null,
    /// What the settings window needs when it is opened.
    settings_env: settings_window.Env,
    /// Open the settings window once zmural is up (`zmural --settings`).
    open_settings: bool = false,
    settings_token: []const u8 = "",
    /// The folder of the wallpaper zmural ships with (`starter.zig`), scanned
    /// after the user's own; null when it isn't there.
    starter_dir: ?[]const u8 = null,
};

/// Clients served at once (each `apply` stays until its wallpaper shows);
/// one more is turned away, and its client tries again (`control_client_linux`).
const max_control_clients = 32;

const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    settings: Settings,
    opts: Options,
    router: Router = .{},
    displays: std.ArrayList(*Display) = .empty,
    renderers: std.ArrayList(*Renderer) = .empty,
    listener: unix.Listener = undefined,
    /// `control.sock`: the CLI, and a second zmural checking on us.
    control_listener: ?unix.Listener = null,
    clients: std.ArrayList(unix.Conn) = .empty,
    /// The wallpaper showing (owned), from `--apply`, `apply` or settings.
    current: ?[]u8 = null,
    library: Library = undefined,
    /// Timed changes, and the order Next/Previous follow.
    rotation: Rotation = .{},
    /// Battery, lock, GameMode...: read on a thread of its own.
    facts: facts.Watcher = .{ .session_address = null, .system_address = null, .xdg_runtime_dir = null },
    /// The facts as `evaluate` last saw them, to log changes.
    system: policy.Conditions = .initEmpty(),
    /// Every condition `evaluate` last saw, system-wide and per monitor, for `status`.
    active: policy.Conditions = .initEmpty(),
    /// The standard folders: Wallpapers in the user's Videos and Pictures folders.
    default_dirs: []const []const u8 = &.{},
    /// Lists set through the settings window, owned here once changed.
    app_rules: lists.Owned = .{},
    user_dirs: lists.Owned = .{},
    /// A render node, for the release syncobjs and acquire fences.
    drm: linux.fd_t = -1,
    /// The session bus, where zmural owns `org.zmural.Daemon` (display
    /// plugins reconnect as soon as it appears).
    bus: ?dbus.Conn = null,
    tray: Tray = .{},
    /// Settings windows we started and haven't collected yet.
    /// Monitors showing a wallpaper of their own instead of `current`.
    own: monitors.Own = .{},
    /// Monitors filling their screen another way than `settings.fill`.
    fills: monitors.Fills = .{},
    /// The main wallpaper's properties (brightness, speed...), if it has any.
    props: ?adjust.Set = null,
    /// When the main wallpaper is a package: the file it shows, and as what
    /// (`entry` lives in `props`' arena). Null when it isn't one, or didn't load.
    pkg: ?struct { entry: []const u8, kind: Kind } = null,
    /// The program in front, where the desktop tells us (`foreground_linux.zig`).
    front: foreground.Front = .{},
    /// Something reports the program in front, so the app rule can fire.
    front_watched: bool = false,
    /// The app rule as `evaluate` last saw it, to log changes.
    app_in_front: bool = false,
    /// settings.toml as we last read or wrote it, to notice an outside edit.
    file_stamp: ?FileStamp = null,
    last_file_check_ms: u64 = 0,
    /// The layer-shell display host zmural runs for itself.
    host: HostChild = .{},
    /// The compositor's IPC, where zmural runs on Sway, Hyprland or Wayfire
    /// (`compositor.zig`): window facts per output and the process in front,
    /// instead of the display host's window list.
    compositor: ?compositor.Watch = null,
    compositor_facts: compositor.Facts = .{},
    /// No live host can show anything on this desktop: the showing picture is
    /// set as the desktop's own, still wallpaper instead.
    still: struct {
        on: bool = false,
        set_for: ?[]u8 = null,
        told: bool = false,
        /// A `zmural --still-frame` making a picture of a video (`stillPicture`).
        frame_pid: ?linux.pid_t = null,
        /// The video it is for, or the last one it couldn't do (owned).
        frame_for: ?[]u8 = null,
    } = .{},
    /// Niri's IPC, where zmural runs on Niri: the process in front.
    niri: ?niri_ipc.Watch = null,
    /// Owns the settings' strings once settings.toml has been reloaded.
    file_arena: ?std.heap.ArenaAllocator = null,
    next_display: u16 = 1,
    quit: bool = false,
    /// The last crash's line (`tellCrash`), and whether a notice went out this run.
    crash_buf: [256]u8 = undefined,
    crash_len: usize = 0,
    crash_told: bool = false,
    /// What to go back to when a wallpaper can't be played (`goBackFromBroken`).
    fallback: Fallback = .{},
    /// The library's size as last logged: the settings window's Welcome page
    /// rescans every few seconds, and the log says only what changed.
    logged_count: ?usize = null,
};

var rt: Runtime = undefined;

pub fn run(gpa: std.mem.Allocator, io: std.Io, settings: Settings, opts: Options) !void {
    rt = .{ .gpa = gpa, .io = io, .settings = settings, .opts = opts };
    rt.router.share = settings.share_renderers;
    if (opts.start_paused) rt.settings.paused = true;

    var dir_buf: [256]u8 = undefined;
    _ = try unix.runtimeDir(&dir_buf, opts.xdg_runtime_dir);
    var addr_buf: [256]u8 = undefined;
    const path = try transport.address(&addr_buf, .linux, .display, opts.xdg_runtime_dir);
    // Nothing to tear down until these two exist: `shutdown` closes both.
    const drm = syncobj.openRenderNode() orelse return error.NoRenderNode;
    const listener = unix.listenKind(path, .stream) catch |err| {
        _ = linux.close(drm);
        return if (err == error.InUse) error.AlreadyRunning else err;
    };
    rt.drm = drm;
    rt.listener = listener;
    rt.library = .init(gpa);
    defer shutdown();
    log.info("zmural {s}: display hosts connect to {s}", .{ zmural.version, path });
    if (opts.wallpaper orelse (if (settings.wallpaper.len > 0) settings.wallpaper else null)) |w| rt.current = try gpa.dupe(u8, w);
    // `--apply` is for every monitor; otherwise monitors keep their own.
    if (opts.wallpaper == null) rt.own.load(gpa, settings.monitor_wallpapers);
    rt.fills.load(settings.monitor_fills);
    loadProperties();
    // The Wallpapers folders in the user's Videos and Pictures folders, by
    // whatever names the desktop gave those (xdg-user-dirs).
    const defaults = try gpa.alloc([]const u8, 2);
    {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const xdg = zmural.os.xdg;
        const home = opts.desktop.home;
        const videos = xdg.userDir(arena.allocator(), io, .videos, home, opts.xdg_config_home, opts.videos_dir_env) catch try std.fs.path.join(arena.allocator(), &.{ home, "Videos" });
        const pictures = xdg.userDir(arena.allocator(), io, .pictures, home, opts.xdg_config_home, opts.pictures_dir_env) catch try std.fs.path.join(arena.allocator(), &.{ home, "Pictures" });
        defaults[0] = try std.fs.path.join(gpa, &.{ videos, "Wallpapers" });
        defaults[1] = try std.fs.path.join(gpa, &.{ pictures, "Wallpapers" });
    }
    rt.default_dirs = defaults;
    log.info("library: always scanning {s} and {s}", .{ defaults[0], defaults[1] });
    rescan();
    if (opts.store) |store| rt.file_stamp = stampOf(store);
    if (opts.wallpaper != null) save();
    // Before the bus: a tray click handled during startBus already evaluates.
    rt.facts = .{ .session_address = opts.dbus_address, .system_address = opts.dbus_system_address, .xdg_runtime_dir = opts.xdg_runtime_dir };
    rt.facts.start();
    startBus();
    const setup = desktop.setUp(rt.gpa, rt.io, opts.desktop, if (rt.bus) |*b| b else null);
    if (setup.short) |short| tellShortfall(short);
    if (setup.still) {
        rt.still.on = true;
        // Said already: what's missing, or that GNOME starts the extension at the next login.
        rt.still.told = true;
    }
    if (rt.bus) |*b| {
        if (desktop.isKde(opts.desktop)) rt.front_watched = foreground.startKde(b, opts.xdg_runtime_dir);
    }
    setUpAutostart();
    tellCrash(.last_run);
    // Last, so a second zmural starting meanwhile never mistakes our
    // startup work for a hang.
    var control_buf: [256]u8 = undefined;
    const control_path = try transport.address(&control_buf, .linux, .control, opts.xdg_runtime_dir);
    rt.control_listener = unix.listen(control_path) catch |err| blk: {
        log.warn("no control socket ({s}): zmural-console can't reach this zmural", .{@errorName(err)});
        break :blk null;
    };
    if (wallpaper() == null) log.warn("no wallpaper set: use --apply <path>", .{});

    try loop();
}

/// Owns `org.zmural.Daemon` and announces `Ready`. Without a session bus
/// zmural still works; display plugins then reconnect on their own timer.
fn startBus() void {
    var b = dbus.Conn.session(rt.opts.dbus_address, rt.opts.xdg_runtime_dir) catch |err| {
        log.info("no session bus ({s}): display plugins will find zmural by retrying", .{@errorName(err)});
        return;
    };
    const owned = b.requestName("org.zmural.Daemon") catch false;
    if (!owned) log.warn("org.zmural.Daemon is taken on the session bus", .{});
    b.signal("/org/zmural/Daemon", "org.zmural.Daemon1", "Ready", "", "") catch |err|
        log.warn("Ready signal not sent: {s}", .{@errorName(err)});
    rt.bus = b;
    const bus = &rt.bus.?;
    bus.hook = .{ .ctx = &rt, .func = onBusMessage };
    rt.tray.start(bus);
}

/// Calls to our D-Bus objects (the tray) and signals we asked for.
fn onBusMessage(_: *anyopaque, c: *dbus.Conn, m: dbus.Message) void {
    if (foreground.onMessage(c, m)) |pid| {
        rt.front = .of(pid);
        return evaluate();
    }
    const action = rt.tray.onMessage(c, m, trayState()) orelse return;
    switch (action) {
        // The tray host's activation token lets the window take focus.
        .open_settings => openSettings(rt.tray.takeToken() orelse ""),
        .toggle_paused => {
            rt.settings.paused = !rt.settings.paused;
            save();
            evaluate();
        },
        .toggle_muted => {
            rt.settings.muted = !rt.settings.muted;
            save();
            pushVolume();
        },
        .next, .previous => if (stepWallpaper(action == .next)) |path| {
            setWallpaper(path) catch |err| log.warn("tray: {s}", .{@errorName(err)});
        },
        .toggle_shuffle => {
            rt.settings.order = if (rt.settings.order == .sequential) .shuffle else .sequential;
            save();
        },
        .rescan => rescan(),
        .toggle_autostart => {
            const entry = autostart.path(rt.gpa, rt.opts.xdg_config_home, rt.opts.desktop.home) catch return;
            defer rt.gpa.free(entry);
            const exe = std.fs.path.join(rt.gpa, &.{ rt.opts.exe_dir, "zmural" }) catch return;
            defer rt.gpa.free(exe);
            autostart.write(rt.io, entry, exe, autostart.state(rt.io, entry) != .on) catch |err| log.warn("tray: autostart: {s}", .{@errorName(err)});
        },
        .quit => {
            log.info("quit from the tray", .{});
            rt.quit = true;
        },
    }
    trayChanged();
}

fn trayState() @import("tray_linux.zig").State {
    var on = false;
    if (autostart.path(rt.gpa, rt.opts.xdg_config_home, rt.opts.desktop.home)) |entry| {
        defer rt.gpa.free(entry);
        on = autostart.state(rt.io, entry) == .on;
    } else |_| {}
    return .{ .wallpaper = rt.current orelse "", .paused = rt.settings.paused, .muted = rt.settings.muted, .shuffled = rt.settings.order != .sequential, .autostart = on };
}

/// Something the tray shows changed.
fn trayChanged() void {
    if (rt.bus) |*b| rt.tray.changed(b);
}

/// The settings window: a thread of this process (`settings.window`). An
/// open one is brought to the front. `token` is the desktop's activation
/// token, which lets the window take focus.
fn openSettings(token: []const u8) void {
    settings_window.open(rt.opts.settings_env, token);
    // Welcome is for the first opening only.
    rt.opts.settings_env.welcome = false;
}

fn wallpaper() ?[]const u8 {
    return rt.current;
}

fn save() void {
    const store = rt.opts.store orelse return;
    rt.settings.wallpaper = rt.current orelse "";
    var view: [monitors.max]settings_file.MonitorWallpaper = undefined;
    rt.settings.monitor_wallpapers = rt.own.view(&view);
    rt.settings.monitor_fills = rt.fills.view();
    store.save(rt.gpa, &rt.settings);
    // The views die here; `rt.own` and `rt.fills` are the truth.
    rt.settings.monitor_wallpapers = &.{};
    rt.settings.monitor_fills = &.{};
    rt.file_stamp = stampOf(store);
}

// ---- settings.toml edits ---------------------------------------------------------

const file_check_ms = 1_000;

/// Enough to notice that someone else wrote the file.
const FileStamp = struct {
    mtime_ns: i96,
    size: u64,
};

fn stampOf(store: *const SettingsStore) ?FileStamp {
    const st = std.Io.Dir.cwd().statFile(store.io, store.path, .{}) catch return null;
    return .{ .mtime_ns = st.mtime.nanoseconds, .size = st.size };
}

/// Picks up hand edits to settings.toml while zmural runs, so the next save
/// doesn't overwrite them (as `runtime_windows.zig` does).
fn checkFile() void {
    const store = rt.opts.store orelse return;
    var buf: [600]u8 = undefined;
    if (store.unreadableNotice(&buf)) |n| {
        if (desktop.shown(if (rt.bus) |*b| b else null, n.title, n.body)) store.told = true;
    }
    const stamp = stampOf(store) orelse return; // deleted: the next save recreates it
    if (rt.file_stamp) |old| if (std.meta.eql(old, stamp)) return;
    rt.file_stamp = stamp;
    reloadFile(store);
}

fn reloadFile(store: *SettingsStore) void {
    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    const was_read_only = store.read_only;
    store.read_only = false;
    const loaded = store.load(arena.allocator());
    if (store.read_only) {
        // It doesn't parse (maybe half-saved): keep running as we are, and
        // don't overwrite it. The next change to the file is tried again.
        arena.deinit();
        return;
    }
    if (was_read_only) log.info("settings: {s} reads fine again", .{store.path});

    const old = rt.settings;
    var s = loaded;
    // Not in the file: keep the running values.
    s.share_renderers = old.share_renderers;
    s.fps_cap = old.fps_cap;
    const library_changed = !sameList(old.library_dirs, s.library_dirs);

    // The file now owns every string: drop the old owners.
    rt.settings = s;
    rt.app_rules.deinit(rt.gpa);
    rt.app_rules = .{};
    rt.user_dirs.deinit(rt.gpa);
    rt.user_dirs = .{};
    if (rt.file_arena) |*a| a.deinit();
    rt.file_arena = arena;
    log.info("settings: reloaded {s} after an outside edit", .{store.path});

    if (old.rotate_minutes != s.rotate_minutes) rt.rotation.restart();
    if (library_changed) rescan();
    // Which monitor shows what, as the file has it now. Every monitor lets go
    // first: the paths the router borrows are about to be replaced.
    const showing = rt.current orelse "";
    const main_changed = s.wallpaper.len > 0 and !std.mem.eql(u8, s.wallpaper, showing);
    var view: [monitors.max]settings_file.MonitorWallpaper = undefined;
    const own_changed = !sameOwn(rt.own.view(&view), s.monitor_wallpapers);
    const fills_changed = !rt.fills.same(s.monitor_fills);
    if (main_changed or own_changed or fills_changed or old.fill != s.fill) {
        for (rt.displays.items) |d| unroute(d);
        if (own_changed) rt.own.load(rt.gpa, s.monitor_wallpapers);
        if (fills_changed) rt.fills.load(s.monitor_fills);
        if (main_changed) {
            if (checkPath(s.wallpaper)) |_| {
                if (rt.gpa.dupe(u8, s.wallpaper)) |copy| {
                    if (rt.current) |cur| rt.gpa.free(cur);
                    rt.current = copy;
                    loadProperties();
                    rt.rotation.restart();
                    log.info("wallpaper: {s}", .{copy});
                } else |_| {}
            } else |_| log.warn("settings: not showing '{s}': {s}", .{ s.wallpaper, whyNoFile(s.wallpaper) });
        }
        for (rt.displays.items) |d| if (d.s.state == .registered) route(d);
    } else pushVolume();
    // The file's lists are in `rt.own` and `rt.fills` now.
    rt.settings.monitor_wallpapers = &.{};
    rt.settings.monitor_fills = &.{};
    evaluate();
    trayChanged();
}

fn sameOwn(a: []const settings_file.MonitorWallpaper, b: []const settings_file.MonitorWallpaper) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.monitor, y.monitor) or !std.mem.eql(u8, x.wallpaper, y.wallpaper)) return false;
    return true;
}

fn sameList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// Start at login is on by default: the first run writes the autostart
/// entry. A user who switched it off (here, or in the desktop's Autostart
/// settings) is left alone; an entry pointing at a moved zmural is fixed.
fn setUpAutostart() void {
    const entry_path = autostart.path(rt.gpa, rt.opts.xdg_config_home, rt.opts.desktop.home) catch return;
    defer rt.gpa.free(entry_path);
    const exe = std.fs.path.join(rt.gpa, &.{ rt.opts.exe_dir, "zmural" }) catch return;
    defer rt.gpa.free(exe);
    switch (autostart.state(rt.io, entry_path)) {
        .off => log.info("start at login is off ({s})", .{entry_path}),
        .on => {
            var buf: [4096]u8 = undefined;
            const text = std.Io.Dir.cwd().readFile(rt.io, entry_path, &buf) catch return;
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (autostart.execPath(&path_buf, text)) |old| if (std.mem.eql(u8, old, exe)) return;
            autostart.write(rt.io, entry_path, exe, true) catch |err| return log.warn("autostart entry not updated: {s}", .{@errorName(err)});
            log.info("start at login now runs {s}", .{exe});
        },
        .unset => {
            autostart.write(rt.io, entry_path, exe, true) catch |err| return log.warn("autostart entry not written: {s}", .{@errorName(err)});
            log.info("start at login is on ({s})", .{entry_path});
            desktop.notify(if (rt.bus) |*b| b else null, "zmural will start when you log in", "To turn that off: `zmural-console autostart off`, or your desktop's Autostart settings.");
        },
    }
}

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

// ---- the loop ------------------------------------------------------------------------

const Source = union(enum) {
    listener,
    bus,
    compositor,
    niri,
    control_listener,
    client: usize,
    display: *Display,
    renderer: *Renderer,
    reaper: *Renderer,
    /// A display's release fence for a slot.
    release: struct { d: *Display, slot: u8 },
};

fn loop() !void {
    var fds: [3 + max_control_clients + max_displays * 5 + 64]linux.pollfd = undefined;
    var srcs: [fds.len]Source = undefined;
    if (rt.opts.open_settings) openSettings(rt.opts.settings_token);
    rt.host.wanted = hostWanted();
    superviseHost(now());
    startCompositor();
    startNiri();
    while (!rt.quit) {
        var n: usize = 0;
        fds[n] = .{ .fd = rt.listener.fd, .events = linux.POLL.IN, .revents = 0 };
        srcs[n] = .listener;
        n += 1;
        if (rt.bus) |b| {
            fds[n] = .{ .fd = b.fd, .events = linux.POLL.IN, .revents = 0 };
            srcs[n] = .bus;
            n += 1;
        }
        if (rt.control_listener) |l| {
            fds[n] = .{ .fd = l.fd, .events = linux.POLL.IN, .revents = 0 };
            srcs[n] = .control_listener;
            n += 1;
        }
        if (rt.compositor) |*w| {
            fds[n] = .{ .fd = w.events(), .events = linux.POLL.IN, .revents = 0 };
            srcs[n] = .compositor;
            n += 1;
        }
        if (rt.niri) |w| {
            fds[n] = .{ .fd = w.events, .events = linux.POLL.IN, .revents = 0 };
            srcs[n] = .niri;
            n += 1;
        }
        for (rt.clients.items, 0..) |c, i| {
            fds[n] = .{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 };
            srcs[n] = .{ .client = i };
            n += 1;
        }
        for (rt.displays.items) |d| {
            fds[n] = .{ .fd = d.s.stream.fd, .events = linux.POLL.IN, .revents = 0 };
            srcs[n] = .{ .display = d };
            n += 1;
            for (d.s.waiting, 0..) |w, slot| if (w >= 0) {
                fds[n] = .{ .fd = w, .events = linux.POLL.IN, .revents = 0 };
                srcs[n] = .{ .release = .{ .d = d, .slot = @intCast(slot) } };
                n += 1;
            };
        }
        for (rt.renderers.items) |r| {
            if (n + 2 > fds.len) break;
            if (r.conn) |c| {
                fds[n] = .{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 };
                srcs[n] = .{ .renderer = r };
                n += 1;
            }
            if (r.pidfd >= 0) {
                fds[n] = .{ .fd = r.pidfd, .events = linux.POLL.IN, .revents = 0 };
                srcs[n] = .{ .reaper = r };
                n += 1;
            }
        }
        const rc = linux.poll(&fds, n, tick_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }
        // Handlers may add or remove displays and renderers: act on a copy of
        // what fired, and re-check each source still exists.
        var fired: [fds.len]Source = undefined;
        var nf: usize = 0;
        for (fds[0..n], srcs[0..n]) |f, s| if (f.revents != 0) {
            fired[nf] = s;
            nf += 1;
        };
        for (fired[0..nf]) |s| switch (s) {
            .listener => accept(),
            .control_listener => acceptClient(),
            // Clients only ever go away from the end of the list (`onClient`
            // removes in place and the rest of this batch waits a round).
            .client => |i| if (i < rt.clients.items.len) {
                if (!onClient(i)) break;
            },
            .bus => if (rt.bus) |*b| b.drain() catch {
                // The bus went away (the session is ending); carry on without it.
                b.close();
                rt.bus = null;
            },
            .compositor => onCompositorEvents(),
            .niri => onNiriEvents(),
            .display => |d| if (liveDisplay(d)) onDisplayReadable(d),
            .renderer => |r| if (liveRenderer(r)) onRendererReadable(r),
            .reaper => |r| if (liveRenderer(r)) reap(r),
            .release => |rl| if (liveDisplay(rl.d)) released(rl.d, rl.slot),
        };
        tick();
    }
}

fn liveDisplay(d: *Display) bool {
    return std.mem.findScalar(*Display, rt.displays.items, d) != null;
}

fn liveRenderer(r: *Renderer) bool {
    return std.mem.findScalar(*Renderer, rt.renderers.items, r) != null;
}

/// The layer-shell display host, as zmural's own child: desktops without a
/// plugin of ours (Sway, Hyprland, labwc, Wayfire, Niri, COSMIC...) need it,
/// and the user shouldn't have to start a second program. It lives as long
/// as zmural does (`--parent`), and is started again if it dies.
const HostChild = struct {
    /// This desktop is one the host is for, and there is a Wayland display.
    wanted: bool = false,
    pid: ?linux.pid_t = null,
    started_ms: u64 = 0,
    next_try_ms: u64 = 0,
    /// Runs that ended quickly, in a row: they space out the next start.
    quick_ends: u8 = 0,
    /// The compositor can't take it (no wlr-layer-shell or DMA-BUF): stop trying.
    unsupported: bool = false,
    /// Said once that another host holds the display.
    told_other: bool = false,

    /// 1 s, 2 s, 4 s ... 30 s.
    fn backoffMs(quick_ends: u8) u64 {
        return @min(30_000, @as(u64, 1000) << @min(quick_ends, 5));
    }
};

fn hostWanted() bool {
    if (backend.pick(rt.opts.desktop.xdg_current_desktop, true) != .layer_shell) return false;
    var buf: [300]u8 = undefined;
    const no_wayland = if (backend.waylandSocket(&buf, rt.opts.xdg_runtime_dir, rt.opts.settings_env.wayland_display)) |socket|
        if (std.Io.Dir.cwd().access(rt.io, socket, .{})) |_| false else |_| true
    else
        true;
    if (no_wayland) {
        // An X11 session, or none: no host of ours can show anything.
        log.warn("no Wayland display: zmural can't show live wallpapers here", .{});
        rt.still.on = true;
        return false;
    }
    return true;
}

/// Tells the user once (per situation) what this desktop lacks for live
/// wallpapers. It replaces the still picture's own notice.
fn tellShortfall(short: @import("requirements_linux.zig").Shortfall) void {
    rt.still.told = true;
    const dir = rt.opts.state_dir orelse return;
    var key_buf: [64]u8 = undefined;
    const key = short.key(&key_buf);
    if (notices.seen(rt.io, rt.gpa, dir, key)) return;
    var a: [256]u8 = undefined;
    var b: [512]u8 = undefined;
    if (desktop.shown(if (rt.bus) |*bus| bus else null, short.summary(&a), short.body(&b))) notices.remember(rt.io, rt.gpa, dir, key);
}

/// Where nothing live can show, the showing wallpaper becomes the desktop's
/// own, still, each time it changes: a picture as it is, a video as one of
/// its frames (`stillPicture`).
fn updateStill() void {
    if (!rt.still.on) return;
    const cur = rt.current orelse return;
    if (rt.still.set_for) |done| if (std.mem.eql(u8, done, cur)) return;
    // A package's picture or video is the file it names.
    const file = if (rt.pkg) |p| (if (p.kind == .image or p.kind == .video) p.entry else cur) else cur;
    var frame_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const picture: ?[]const u8 = if (std.mem.eql(u8, cur, "test-pattern") or adjust.isPackage(file))
        null
    else switch (Kind.forPath(file)) {
        .image => file,
        // Not made yet: tried again when the frame is ready (`checkStillFrame`).
        .video => stillPicture(file, &frame_buf) orelse if (rt.still.frame_pid != null) return else null,
        else => null,
    };
    if (rt.still.set_for) |old| rt.gpa.free(old);
    rt.still.set_for = rt.gpa.dupe(u8, cur) catch null;
    const still = picture orelse return log.info("still: {s} can't be set as this desktop's own wallpaper", .{cur});
    const bus = if (rt.bus) |*b| b else return log.warn("still: no session bus, so no wallpaper portal to set {s} through", .{cur});
    // GNOME: the user's own background is kept first, for uninstall.
    if (backend.pick(rt.opts.desktop.xdg_current_desktop, true) == .gnome_shell) if (rt.opts.state_dir) |dir| desktop.saveGnomeBackground(rt.gpa, rt.io, dir);
    desktop.setStill(bus, still) catch |err| return log.warn("still: the wallpaper portal didn't take {s}: {s} {s}", .{ still, @errorName(err), bus.lastError() });
    log.info("still: set {s} as the desktop's own wallpaper (wallpaper portal)", .{still});
    if (!rt.still.told) {
        rt.still.told = true;
        desktop.notify(bus, "zmural can't show live wallpapers here", "zmural shows live wallpapers through the compositor's wlr-layer-shell, DMA-BUF and output names, and this desktop lacks one of them (zmural's log says which). Your wallpaper is set as a still picture instead; videos can't be shown.");
    }
}

/// A still picture of `video`: the frame made before, in zmural's cache, or
/// null while `zmural --still-frame` makes it (or after it couldn't).
fn stillPicture(video: []const u8, buf: []u8) ?[]const u8 {
    const key = std.hash.Wyhash.hash(0, video);
    const out = (if (rt.opts.settings_env.cache_home) |c|
        std.fmt.bufPrint(buf, "{s}/zmural/stills/{x:0>16}.png", .{ c, key })
    else
        std.fmt.bufPrint(buf, "{s}/.cache/zmural/stills/{x:0>16}.png", .{ rt.opts.desktop.home, key })) catch return null;
    if (std.Io.Dir.cwd().openFile(rt.io, out, .{})) |f| {
        f.close(rt.io);
        return out;
    } else |_| {}
    if (rt.still.frame_for) |v| if (std.mem.eql(u8, v, video)) return null; // being made, or failed
    if (rt.still.frame_pid != null) return null; // one at a time; asked for again after
    std.Io.Dir.cwd().createDirPath(rt.io, std.fs.path.dirname(out) orelse return null) catch return null;
    const child = std.process.spawn(rt.io, .{
        .argv = &.{ rt.opts.exe_path, "--still-frame", video, out },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        log.warn("still: can't start zmural --still-frame: {s}", .{@errorName(err)});
        return null;
    };
    if (rt.still.frame_for) |v| rt.gpa.free(v);
    rt.still.frame_for = rt.gpa.dupe(u8, video) catch null;
    rt.still.frame_pid = child.id;
    log.info("still: making a picture of {s}", .{video});
    return null;
}

/// The still frame's process ended: set it, or say it couldn't be made.
fn checkStillFrame() void {
    const pid = rt.still.frame_pid orelse return;
    var status: u32 = 0;
    const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
    if (linux.errno(rc) == .SUCCESS and rc == 0) return; // still running
    rt.still.frame_pid = null;
    const ok = linux.errno(rc) == .SUCCESS and linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0;
    if (ok) {
        // Found in the cache from now on.
        if (rt.still.frame_for) |v| rt.gpa.free(v);
        rt.still.frame_for = null;
    } else log.warn("still: no picture could be made of {s} (zmural --still-frame failed)", .{rt.still.frame_for orelse "?"});
    // Whatever shows now (it may have changed meanwhile) is set again.
    if (rt.still.set_for) |old| rt.gpa.free(old);
    rt.still.set_for = null;
}

/// Starts the host when it should be running and isn't, and learns why it ended.
fn superviseHost(t: u64) void {
    const h = &rt.host;
    if (!h.wanted or h.unsupported) return;
    if (h.pid) |pid| {
        var status: u32 = 0;
        const rc = linux.wait4(pid, &status, linux.W.NOHANG, null);
        if (linux.errno(rc) == .SUCCESS and rc == 0) return; // still running
        h.pid = null;
        const code: ?u8 = if (linux.errno(rc) == .SUCCESS and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
        if (code == backend.exit_unsupported) {
            h.unsupported = true;
            log.warn("this compositor lacks what zmural's display host needs (wlr-layer-shell v3, linux-dmabuf v4, wl_output v4; the host's line above names it): zmural can't show live wallpapers on it", .{});
            rt.still.on = true;
            return;
        }
        if (code == backend.exit_already_running) {
            h.next_try_ms = t + 5000;
            return;
        }
        h.quick_ends = if (t -| h.started_ms < 30_000) h.quick_ends +| 1 else 0;
        const wait = HostChild.backoffMs(h.quick_ends);
        h.next_try_ms = t + wait;
        if (code) |c| log.warn("the display host ended (exit code {d}); starting it again in {d} s", .{ c, wait / 1000 }) else log.warn("the display host was killed; starting it again in {d} s", .{wait / 1000});
        return;
    }
    if (t < h.next_try_ms) return;
    // Someone else's host (started by hand, or left by a zmural that was
    // killed): it serves this zmural too. Look again in a while.
    var dir_buf: [256]u8 = undefined;
    var lock_buf: [300]u8 = undefined;
    if (unix.runtimeDir(&dir_buf, rt.opts.xdg_runtime_dir)) |dir| {
        if (backend.lockPath(&lock_buf, dir, rt.opts.settings_env.wayland_display)) |lock| if (backend.lockHeld(lock)) {
            if (!h.told_other) log.info("a layer-shell display host is already running on this display; using it", .{});
            h.told_other = true;
            h.next_try_ms = t + 5000;
            return;
        };
    } else |_| {}
    var pid_buf: [16]u8 = undefined;
    const me = std.fmt.bufPrint(&pid_buf, "{d}", .{linux.getpid()}) catch return;
    const child = std.process.spawn(rt.io, .{
        .argv = &.{ rt.opts.exe_path, "--layer-shell", "--parent", me },
        .stdin = .ignore,
    }) catch |err| {
        h.quick_ends +|= 1;
        h.next_try_ms = t + HostChild.backoffMs(h.quick_ends);
        return log.warn("can't start the display host: {s}", .{@errorName(err)});
    };
    h.pid = child.id;
    h.started_ms = t;
    h.told_other = false;
    if (h.pid) |pid| log.info("display host: started (layer-shell, pid {d})", .{pid});
}

fn tick() void {
    const t = now();
    superviseHost(t);
    checkStillFrame();
    updateStill();
    for (rt.renderers.items) |r| {
        if (r.stop_at) |at| if (t >= at) {
            if (r.pid) |pid| _ = linux.kill(pid, linux.SIG.KILL);
            r.stop_at = null;
        };
        const before = r.sup.applied;
        if (r.sup.tick(t)) |cmd| {
            if (r.sup.applied != before) log.info("renderer {d}: {s} -> {s}", .{ r.id, @tagName(before), @tagName(r.sup.applied) });
            execute(r, cmd);
        }
    }
    if (t -| rt.last_file_check_ms >= file_check_ms) {
        rt.last_file_check_ms = t;
        checkFile();
    }
    evaluate();
    goBackFromBroken();
    rotate(t);
}

fn startCompositor() void {
    rt.compositor = compositor.start(rt.gpa, .{
        .runtime_dir = rt.opts.xdg_runtime_dir,
        .swaysock = rt.opts.swaysock,
        .hyprland_signature = rt.opts.hyprland_signature,
        .wayfire_socket = rt.opts.wayfire_socket,
        .current_desktop = rt.opts.desktop.xdg_current_desktop,
    }) orelse return;
    log.info("{s}: window facts and the app in front from its IPC", .{rt.compositor.?.name()});
    rt.front_watched = true;
    refreshCompositor();
}

fn onCompositorEvents() void {
    const w = if (rt.compositor) |*c| c else return;
    if (!w.drain()) {
        log.warn("{s}'s IPC closed; window facts come from the display host only", .{w.name()});
        w.stop();
        rt.compositor = null;
        rt.compositor_facts = .{};
        rt.front_watched = false;
        rt.front = .{};
        return evaluate();
    }
    refreshCompositor();
}

fn refreshCompositor() void {
    const w = if (rt.compositor) |*c| c else return;
    const f = w.query() catch |err| return log.warn("{s}: can't read its windows: {s}", .{ w.name(), @errorName(err) });
    if (f.eql(&rt.compositor_facts)) return;
    for (0..f.len) |i| {
        const name = f.names[i][0..f.name_lens[i]];
        const c = f.conditions[i];
        const before = rt.compositor_facts.forOutput(name);
        if (before == null or !std.meta.eql(before.?, c))
            log.info("{s}: {s}: fullscreen={} maximized={} covered={} focused={}", .{ w.name(), name, c.contains(.fullscreen), c.contains(.maximized), c.contains(.covered), c.contains(.focused) });
    }
    if (f.front_pid != rt.compositor_facts.front_pid) rt.front = .of(f.front_pid);
    rt.compositor_facts = f;
    evaluate();
}

fn startNiri() void {
    const sock = rt.opts.niri_socket orelse return;
    if (sock.len == 0) return;
    rt.niri = niri_ipc.Watch.start(rt.gpa, sock) catch |err| return log.warn("Niri's IPC ({s}) doesn't answer: {s}; the app rule isn't available", .{ sock, @errorName(err) });
    log.info("Niri: the app in front from its IPC", .{});
    rt.front_watched = true;
    refreshNiri();
}

fn onNiriEvents() void {
    const w = if (rt.niri) |*s| s else return;
    var changed = false;
    if (!w.drain(&changed)) {
        log.warn("Niri's IPC closed; the app rule isn't available any more", .{});
        w.stop();
        rt.niri = null;
        rt.front_watched = false;
        rt.front = .{};
        return evaluate();
    }
    if (changed) refreshNiri();
}

fn refreshNiri() void {
    const w = if (rt.niri) |*s| s else return;
    const pid = w.focused() catch |err| return log.warn("Niri: can't read the focused window: {s}", .{@errorName(err)});
    if (pid == rt.front.pid) return;
    rt.front = .of(pid);
    evaluate();
}

/// A display's window facts: the compositor's, where it tells, else the display host's.
fn conditionsOf(d: *const Display) policy.Conditions {
    if (rt.compositor != null) if (rt.compositor_facts.forOutput(d.s.connector())) |c| return c;
    return d.s.conditions;
}

/// Re-applies the pause policy to every renderer.
fn evaluate() void {
    var ids: [max_displays]MonitorId = undefined;
    var conds: [max_displays]policy.Conditions = undefined;
    var n: usize = 0;
    for (rt.displays.items) |d| if (d.s.state == .registered and n < max_displays) {
        ids[n] = d.s.monitor;
        conds[n] = conditionsOf(d);
        n += 1;
    };
    var system = rt.facts.current();
    if (!system.eql(rt.system)) logFacts(rt.system, system);
    rt.system = system;
    const in_front = rt.front.isOneOf(rt.settings.app_rules);
    if (in_front != rt.app_in_front) {
        if (in_front) log.info("app rule: {s} is in front", .{rt.front.name()}) else log.info("app rule: none of your apps is in front any more", .{});
        rt.app_in_front = in_front;
    }
    if (in_front) system.insert(.app_rule);
    rt.active = system;
    for (conds[0..n]) |c| rt.active.setUnion(c);
    const t = now();
    for (rt.renderers.items) |r| {
        const want = desire.forRenderer(&rt.settings.policy, system, ids[0..n], conds[0..n], &rt.router, r.id, rt.settings.paused);
        const before = r.sup.applied;
        if (r.sup.desire(t, want, rt.settings.resume_after_ms)) |cmd| {
            log.info("renderer {d}: {s} -> {s}", .{ r.id, @tagName(before), @tagName(r.sup.applied) });
            execute(r, cmd);
        }
    }
}

fn logFacts(before: policy.Conditions, after: policy.Conditions) void {
    for (facts.reported) |k| {
        if (before.contains(k) != after.contains(k)) log.info("system: {s} {s}", .{ @tagName(k), if (after.contains(k)) "began" else "ended" });
    }
}

// ---- display hosts ----------------------------------------------------------------------

fn accept() void {
    var c = rt.listener.accept() catch |err| {
        if (err == error.WrongUser) log.warn("refused a display host run by another user", .{});
        return;
    };
    if (rt.displays.items.len >= max_displays) {
        log.warn("too many display connections; refusing one", .{});
        c.close();
        return;
    }
    c.setSendTimeout(send_timeout_ms) catch |err| log.warn("display: send timeout not set: {s}", .{@errorName(err)});
    const d = rt.gpa.create(Display) catch {
        c.close();
        return;
    };
    d.* = .{ .s = .{ .stream = .{ .fd = c.fd }, .id = rt.next_display } };
    rt.next_display +%= 1;
    if (rt.next_display == 0) rt.next_display = 1;
    rt.displays.append(rt.gpa, d) catch {
        rt.gpa.destroy(d);
        c.close();
    };
}

fn onDisplayReadable(d: *Display) void {
    d.s.stream.fill() catch {
        dropDisplay(d);
        return;
    };
    while (true) {
        const f = (d.s.stream.next(ww.requestFds) catch {
            dropDisplay(d);
            return;
        }) orelse break;
        const what = d.s.handle(f.opcode, f.body) catch {
            dropDisplay(d);
            return;
        };
        switch (what) {
            .none, .window_state => {},
            .registered => route(d),
            .resized => {
                // A new pool at the new size.
                unroute(d);
                route(d);
            },
            .armed => for (d.s.done_without_fence, 0..) |done, slot| {
                if (done) released(d, @intCast(slot));
            },
        }
    }
}

/// A display is done with a slot: the renderer may draw into it again.
fn released(d: *Display, slot: u8) void {
    d.s.released(slot);
    const rid = d.renderer orelse return;
    const r = findRenderer(rid) orelse return;
    sendRenderer(r, .{ .release = .{ .surface = d.s.id, .generation = d.s.renderer_generation, .slot = slot } }, &.{});
}

fn dropDisplay(d: *Display) void {
    if (d.s.state == .registered) log.info("display {d}: {s} gone", .{ d.s.id, d.s.connector() });
    unroute(d);
    d.s.close();
    if (std.mem.findScalar(*Display, rt.displays.items, d)) |i| _ = rt.displays.swapRemove(i);
    rt.gpa.destroy(d);
}

fn findDisplay(id: u16) ?*Display {
    for (rt.displays.items) |d| if (d.s.id == id) return d;
    return null;
}

// ---- control -------------------------------------------------------------------------------

fn acceptClient() void {
    var l = &(rt.control_listener orelse return);
    var c = l.accept() catch return;
    if (rt.clients.items.len >= max_control_clients) {
        c.close();
        return;
    }
    c.setSendTimeout(send_timeout_ms) catch {}; // zsnag:ok — a stuck client just gets dropped on a failed send
    rt.clients.append(rt.gpa, c) catch c.close();
}

/// Serves one request. False if the client list changed (the caller stops
/// iterating over the fired sources this round).
fn onClient(i: usize) bool {
    var c = &rt.clients.items[i];
    var buf: [unix.max_frame]u8 = undefined;
    var fds: [unix.max_fds]linux.fd_t = undefined;
    const f = c.recv(&buf, &fds) catch {
        c.close();
        _ = rt.clients.orderedRemove(i);
        return false;
    };
    f.closeFds();
    const reply: control.Event = if (f.decode(control.Request)) |req| handleRequest(req) else |_| .{ .failed = .{ .code = .bad_request, .message = "unreadable request" } };
    c.send(control.Event, reply, &.{}) catch {
        c.close();
        _ = rt.clients.orderedRemove(i);
        return false;
    };
    return true;
}

fn failed(code: control.ErrorCode, message: []const u8) control.Event {
    return .{ .failed = .{ .code = code, .message = message } };
}

fn handleRequest(req: control.Request) control.Event {
    switch (req) {
        .hello => |h| {
            if (h.version != control.version) return failed(.incompatible_version, "control protocol version mismatch");
            return .{ .welcome = .{ .version = control.version, .daemon_version = rt.opts.report_version, .capabilities = "control.v1 apply playback mute rotation properties monitors" } };
        },
        .status => {
            var connected: u16 = 0;
            for (rt.displays.items) |d| {
                if (d.s.state == .registered) connected += 1;
            }
            const h = desire.held(&held_buf, &rt.settings.policy, rt.active);
            return .{ .status = .{
                .paused_by = h.paused_by,
                .muted_by = h.muted_by,
                .crash = rt.crash_buf[0..rt.crash_len],
                .shown = rt.fallback.last_good orelse "",
                .broken = rt.fallback.last_broken orelse "",
                .broken_why = if (rt.fallback.last_broken != null) rt.fallback.message() else "",
                .paused = rt.settings.paused,
                .muted = rt.settings.muted,
                .monitors = connected,
                .wallpapers = @intCast(rt.library.count()),
                .wallpaper = wallpaper() orelse "",
                .rotate_minutes = rt.settings.rotate_minutes,
                .order = rt.settings.order,
                .next_change_s = rt.rotation.remainingS(rt.settings.rotate_minutes),
            } };
        },
        .apply => |a| {
            if (a.monitor.len == 0) {
                applyToAll(a.path) catch |err| return switch (err) {
                    error.NoSuchFile => failed(.not_found, whyNoFile(a.path)),
                    error.WebOnly => failed(.unsupported, web_only),
                    error.OutOfMemory => failed(.internal, "out of memory"),
                };
                return .ok;
            }
            // An empty path: that monitor follows the main wallpaper again.
            var known_buf: [max_displays]monitors.Known = undefined;
            const monitor = monitors.resolve(a.monitor, knownMonitors(&known_buf)) orelse monitors.parseId(a.monitor) orelse
                return failed(.not_found, "no such monitor (`zmural-console status` lists them)");
            setOwn(monitor, if (a.path.len > 0) a.path else null) catch |err| return switch (err) {
                error.NoSuchFile => failed(.not_found, whyNoFile(a.path)),
                error.WebOnly => failed(.unsupported, web_only),
                error.OutOfMemory => failed(.internal, "out of memory"),
                error.TooMany => failed(.bad_request, "too many monitors have their own wallpaper"),
                error.MainOnly => failed(.unsupported, "a wallpaper package can only be the main wallpaper for now; leave out --monitor"),
            };
            return .ok;
        },
        .get_properties => {
            const set = if (rt.props) |*p| p else return .{ .properties = .{ .title = "", .list = "" } };
            var out: std.Io.Writer = .fixed(&reply_buf);
            set.list(&out) catch return failed(.internal, "too many properties to send");
            return .{ .properties = .{ .title = set.m.title, .list = out.buffered() } };
        },
        .set_property => |sp| {
            const set = if (rt.props) |*p| p else return failed(.unsupported, "this wallpaper has no properties");
            const i = set.set(sp.name, sp.value) catch |err| return switch (err) {
                error.NoSuchProperty => failed(.not_found, "this wallpaper has no property by that name"),
                error.BadValue => failed(.bad_request, "that value isn't one this property takes"),
                error.OutOfMemory => failed(.internal, "out of memory"),
            };
            set.save(rt.io, rt.gpa);
            for (rt.renderers.items) |r| sendProperty(r, set.m.properties[i].name, set.values[i]);
            return .ok;
        },
        .reset_properties => {
            const set = if (rt.props) |*p| p else return failed(.unsupported, "this wallpaper has no properties");
            set.reset();
            set.save(rt.io, rt.gpa);
            for (rt.renderers.items) |r| sendProperties(r);
            return .ok;
        },
        .monitors => {
            var known_buf: [max_displays]monitors.Known = undefined;
            return .{ .monitors = .{ .list = monitors.format(&reply_buf, knownMonitors(&known_buf), &rt.own, &rt.fills) } };
        },
        .pause, .play => |t| {
            if (t.monitor.len > 0) return failed(.unsupported, "pausing one monitor isn't supported yet; leave out --monitor");
            rt.settings.paused = req == .pause;
            save();
            evaluate();
            trayChanged();
            return .ok;
        },
        .set_muted => |m| {
            rt.settings.muted = m.muted;
            save();
            pushVolume();
            trayChanged();
            return .ok;
        },
        .set_volume => |v| {
            rt.settings.volume = @min(v.volume, 100);
            save();
            pushVolume();
            return .ok;
        },
        .set_fill => |f| {
            // Renderers take the fill mode when they start, so a change reroutes.
            if (f.monitor.len > 0) {
                var known_buf: [max_displays]monitors.Known = undefined;
                const monitor = monitors.resolve(f.monitor, knownMonitors(&known_buf)) orelse monitors.parseId(f.monitor) orelse
                    return failed(.not_found, "no such monitor (`zmural-console status` lists them)");
                if (f.main) {
                    if (!rt.fills.remove(monitor)) return .ok;
                } else if (!rt.fills.set(monitor, f.fill)) return failed(.bad_request, "too many monitors have their own fill mode");
                rerouteAll();
            } else if (rt.settings.fill != f.fill) {
                rt.settings.fill = f.fill;
                rerouteAll();
            }
            save();
            return .ok;
        },
        .set_rule => |r| {
            if (!offered(r.condition)) return failed(.unsupported, "zmural can't detect that situation on this desktop yet");
            var rule = rt.settings.policy.rules.get(r.condition);
            rule.action = r.action;
            rt.settings.policy.rules.set(r.condition, rule);
            evaluate();
            save();
            return .ok;
        },
        .set_resume_after => |r| {
            rt.settings.resume_after_ms = @min(r.ms, 10_000);
            save();
            return .ok;
        },
        .set_list => |l| return setList(l),
        .set_rotation => |r| {
            if (r.minutes) |m| {
                if (m > control.max_rotate_minutes) return failed(.bad_request, "a week (10080 minutes) at most");
                if (m != rt.settings.rotate_minutes) rt.rotation.restart();
                rt.settings.rotate_minutes = m;
            }
            if (r.order) |o| rt.settings.order = o;
            save();
            trayChanged();
            return .ok;
        },
        .get_settings => return settingsInfo(),
        .library => |page| {
            const all = rt.library.paths.items;
            const pg = lists.joinFrom(&reply_buf, all, page.offset);
            if (pg.count == 0 and page.offset < all.len) return failed(.internal, "a library path is too long to send");
            return .{ .library = .{ .total = @intCast(all.len), .offset = page.offset, .paths = pg.text } };
        },
        .rescan => {
            rescan();
            return .ok;
        },
        .next, .previous => |t| {
            const empty = "the library is empty (add wallpapers to the Wallpapers folder in your Videos or Pictures folder)";
            if (t.monitor.len > 0) {
                // That monitor steps on from what it shows, and keeps the result as its own.
                var known_buf: [max_displays]monitors.Known = undefined;
                const monitor = monitors.resolve(t.monitor, knownMonitors(&known_buf)) orelse
                    return failed(.not_found, "no such monitor (`zmural-console status` lists them)");
                var seed: u64 = undefined;
                rt.io.random(std.mem.asBytes(&seed));
                const path = rt.rotation.step(rt.gpa, &rt.library, rt.own.wallpaperFor(monitor, rt.current), rt.settings.order, req == .next, seed) orelse
                    return failed(.not_found, empty);
                setOwn(monitor, path) catch return failed(.internal, "can't show it");
                return .ok;
            }
            const path = stepWallpaper(req == .next) orelse return failed(.not_found, empty);
            setWallpaper(path) catch |err| return switch (err) {
                error.WebOnly => failed(.unsupported, web_only),
                else => failed(.internal, @errorName(err)),
            };
            return .ok;
        },
        .reset_settings => {
            const d: Settings = .{};
            const refill = rt.settings.fill != d.fill;
            rt.settings.fill = d.fill;
            rt.settings.volume = d.volume;
            rt.settings.muted = d.muted;
            rt.settings.paused = d.paused;
            rt.settings.policy = d.policy;
            rt.settings.resume_after_ms = d.resume_after_ms;
            rt.settings.rotate_minutes = d.rotate_minutes;
            rt.settings.order = d.order;
            rt.app_rules.deinit(rt.gpa);
            rt.app_rules = .{};
            rt.settings.app_rules = &.{};
            if (refill) rerouteAll() else pushVolume();
            evaluate();
            save();
            trayChanged();
            log.info("settings: playback and pausing reset to defaults", .{});
            return .ok;
        },
        .open_settings => |o| {
            openSettings(o.token);
            return .ok;
        },
        .quit => {
            log.info("asked to quit", .{});
            rt.quit = true;
            return .ok;
        },
    }
}

/// Reply strings (lists, library pages) live here until the reply is sent.
var reply_buf: [60 * 1024]u8 = undefined;
var held_buf: [512]u8 = undefined;

fn pushVolume() void {
    for (rt.renderers.items) |r| if (r.ready) sendRenderer(r, .{ .set_volume = .{ .volume = rt.settings.volume, .muted = rt.settings.muted } }, &.{});
}

/// Can this rule fire here? The app rule needs a desktop that says which
/// program is in front; the rest are the same on every Linux desktop.
fn offered(c: policy.Condition) bool {
    return settings_file.isExposed(c) or (c == .app_rule and rt.front_watched) or (c == .covered and rt.compositor != null);
}

fn settingsInfo() control.Event {
    var rules: control.RuleActions = undefined;
    var exposed: control.RuleExposed = undefined;
    for (std.enums.values(policy.Condition)) |c| {
        rules[@intFromEnum(c)] = rt.settings.policy.rules.get(c).action;
        exposed[@intFromEnum(c)] = offered(c);
    }
    const third = reply_buf.len / 3;
    return .{ .settings = .{
        .fill = rt.settings.fill,
        .volume = rt.settings.volume,
        .muted = rt.settings.muted,
        .paused = rt.settings.paused,
        .resume_after_ms = rt.settings.resume_after_ms,
        .rotate_minutes = rt.settings.rotate_minutes,
        .order = rt.settings.order,
        .rules = rules,
        .exposed = exposed,
        .app_rules = lists.join(reply_buf[0..third], rt.settings.app_rules),
        .library_dirs = lists.join(reply_buf[third..][0..third], rt.settings.library_dirs),
        .default_dirs = lists.join(reply_buf[2 * third ..], rt.default_dirs),
        .file = if (rt.opts.store) |st| st.path else "",
    } };
}

fn setList(l: control.SetList) control.Event {
    const check: *const fn ([]const u8) bool = switch (l.list) {
        .app_rules => &lists.isAppName,
        .library_dirs => &lists.isAbsoluteDir,
    };
    const owned = lists.Owned.parse(rt.gpa, l.items, check) catch |err| return failed(.bad_request, switch (err) {
        error.TooMany => "too many items (32 at most)",
        error.TooLong => "an item is too long",
        error.OutOfMemory => "out of memory",
        error.BadItem => switch (l.list) {
            .app_rules => "apps are named by their program name, like steam",
            .library_dirs => "folders need a full path, like /home/you/Wallpapers",
        },
    });
    switch (l.list) {
        .app_rules => {
            rt.app_rules.deinit(rt.gpa);
            rt.app_rules = owned;
            rt.settings.app_rules = owned.items;
        },
        .library_dirs => {
            rt.user_dirs.deinit(rt.gpa);
            rt.user_dirs = owned;
            rt.settings.library_dirs = owned.items;
            rescan();
        },
    }
    save();
    return .ok;
}

/// Reads the library folders again (the standard ones, then the user's).
fn rescan() void {
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(rt.gpa);
    dirs.appendSlice(rt.gpa, rt.default_dirs) catch return;
    dirs.appendSlice(rt.gpa, rt.settings.library_dirs) catch return;
    rt.library.scan(rt.io, dirs.items);
    if (rt.opts.starter_dir) |d| rt.library.scanLast(rt.io, d);
    rt.rotation.forget(rt.gpa);
    if (rt.logged_count != rt.library.count()) log.info("library: {d} wallpapers", .{rt.library.count()});
    rt.logged_count = rt.library.count();
}

/// The wallpaper after (or before) the current one, in the order the user chose.
fn stepWallpaper(forward: bool) ?[]const u8 {
    var seed: u64 = undefined;
    rt.io.random(std.mem.asBytes(&seed));
    return rt.rotation.step(rt.gpa, &rt.library, rt.current, rt.settings.order, forward, seed);
}

/// Is any wallpaper playing (the rotation clock only runs then)?
fn playing() bool {
    if (rt.settings.paused) return false;
    for (rt.renderers.items) |r| {
        if (r.ready and @intFromEnum(r.sup.applied) <= @intFromEnum(policy.Action.mute)) return true;
    }
    return false;
}

/// Timed changes.
fn rotate(t: u64) void {
    if (!rt.rotation.due(t, rt.settings.rotate_minutes, playing())) return;
    const path = stepWallpaper(true) orelse return;
    if (rt.current) |cur| if (std.mem.eql(u8, cur, path)) return; // a library of one
    log.info("rotation: {d} minutes are up", .{rt.settings.rotate_minutes});
    setWallpaper(path) catch |err| log.warn("rotation: {s}", .{@errorName(err)});
}

/// Reads the main wallpaper's properties and the values saved for it.
fn loadProperties() void {
    if (rt.props) |*p| p.deinit();
    rt.props = null;
    rt.pkg = null;
    const path = rt.current orelse return;
    if (std.mem.eql(u8, path, "test-pattern")) return; // drawn by the renderer itself: nothing to adjust
    const config = if (rt.opts.store) |st| st.dir else null;
    if (adjust.isPackage(path)) {
        // A package that doesn't load shows nothing (`route`); the log says why.
        const pkg = adjust.loadPackage(rt.gpa, rt.io, config, path) catch return;
        rt.props = pkg.set;
        rt.pkg = .{ .entry = pkg.entry, .kind = pkg.kind };
        log.info("package '{s}' ({s}, {d} properties)", .{ pkg.set.m.title, @tagName(pkg.kind), pkg.set.m.properties.len });
        return;
    }
    rt.props = adjust.load(rt.gpa, rt.io, config, path, Kind.forPath(path)) catch null;
}

/// Sends one property's value to a renderer showing the main wallpaper.
fn sendProperty(r: *Renderer, name: []const u8, v: zmural.manifest.Value) void {
    if (!r.main or !r.ready) return;
    var buf: [1100]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    props.writeJson(&out, v) catch return;
    sendRenderer(r, .{ .set_property = .{ .name = name, .json = out.buffered() } }, &.{});
}

fn sendProperties(r: *Renderer) void {
    const set = if (rt.props) |*p| p else return;
    for (set.m.properties, set.values) |p, v| sendProperty(r, p.name, v);
}

/// Can `path` be shown? Only a file that exists, or the built-in test
/// pattern. A web address is never one; `whyNoFile` says so.
fn checkPath(path: []const u8) error{ NoSuchFile, WebOnly }!void {
    if (std.mem.eql(u8, path, "test-pattern")) return;
    if (kind_mod.isUrl(path)) return error.NoSuchFile;
    // A relative path would be read from zmural's own working folder.
    if (!std.fs.path.isAbsolutePosix(path)) return error.NoSuchFile;
    std.Io.Dir.cwd().access(rt.io, path, .{}) catch return error.NoSuchFile;
    if (Kind.forPath(path) == .web) return error.WebOnly;
    // A package must load, so a broken one is refused before anything changes.
    if (adjust.isPackage(path)) {
        var pkg = adjust.loadPackage(rt.gpa, rt.io, null, path) catch return error.NoSuchFile;
        defer pkg.set.deinit();
        if (pkg.kind == .web) return error.WebOnly;
    }
}

/// Web wallpapers have no renderer on Linux yet (`--renderer web` is a stub).
const web_only = "web wallpapers are Windows-only so far; on Linux zmural shows videos, pictures and GIFs";

/// What to tell the user when `checkPath` refused `path`.
fn whyNoFile(path: []const u8) []const u8 {
    if (kind_mod.isUrl(path)) return kind_mod.no_web_addresses;
    if (!std.fs.path.isAbsolutePosix(path)) return "a wallpaper is given by its full path";
    if (adjust.isPackage(path) and (std.Io.Dir.cwd().access(rt.io, path, .{}) catch null) != null)
        return "not a usable wallpaper package (zmural's log says why)";
    return "no such file";
}

/// The router borrows each wallpaper's path, so a monitor lets go of its
/// renderer before the path it shows is replaced, and is routed again after.
fn followsMain(d: *const Display) bool {
    return rt.own.get(d.s.monitor) == null;
}

/// Changes the main wallpaper: what every monitor without its own shows.
/// Next, Previous and timed rotation go through here.
fn setWallpaper(path: []const u8) error{ NoSuchFile, WebOnly, OutOfMemory }!void {
    try checkPath(path);
    const copy = try rt.gpa.dupe(u8, path);
    rt.fallback.retrying(rt.gpa, path);
    for (rt.displays.items) |d| if (followsMain(d)) unroute(d);
    if (rt.current) |old| rt.gpa.free(old);
    rt.current = copy;
    loadProperties();
    rt.rotation.restart();
    save();
    for (rt.displays.items) |d| if (d.s.state == .registered and followsMain(d)) route(d);
    // Not `path`: it may be the old `rt.current`, freed above.
    log.info("wallpaper: {s}", .{copy});
    trayChanged();
}

/// Shows `path` on every monitor: none keeps a wallpaper of its own.
fn applyToAll(path: []const u8) error{ NoSuchFile, WebOnly, OutOfMemory }!void {
    try checkPath(path);
    for (rt.displays.items) |d| if (!followsMain(d)) unroute(d);
    const had_own = rt.own.len > 0;
    rt.own.clear(rt.gpa);
    if (had_own) log.info("every monitor follows the main wallpaper again", .{});
    // Routes the monitors just released along with the rest.
    try setWallpaper(path);
    for (rt.displays.items) |d| if (d.s.state == .registered and d.renderer == null) route(d);
}

/// Gives one monitor its own wallpaper, or (`path` null) has it follow the
/// main one again. The monitor needn't be connected for the second.
fn setOwn(monitor: MonitorId, path: ?[]const u8) error{ NoSuchFile, WebOnly, OutOfMemory, TooMany, MainOnly }!void {
    if (path) |p| {
        try checkPath(p);
        // Its properties are the main wallpaper's (as on Windows).
        if (adjust.isPackage(p)) return error.MainOnly;
    }
    for (rt.displays.items) |d| if (std.mem.eql(u8, &d.s.monitor, &monitor)) unroute(d);
    if (path) |p| {
        rt.own.set(rt.gpa, monitor, p) catch |err| {
            // Still routed as before.
            for (rt.displays.items) |d| if (d.s.state == .registered and d.renderer == null) route(d);
            return err;
        };
        log.info("monitor {s}: wallpaper: {s}", .{ &monitor, p });
    } else if (rt.own.remove(rt.gpa, monitor)) {
        log.info("monitor {s}: follows the main wallpaper again", .{&monitor});
    }
    save();
    for (rt.displays.items) |d| if (d.s.state == .registered and d.renderer == null) route(d);
}

/// Every monitor lets go and is routed again (a setting renderers take at
/// start changed, or the whole assignment did).
fn rerouteAll() void {
    for (rt.displays.items) |d| unroute(d);
    for (rt.displays.items) |d| if (d.s.state == .registered) route(d);
}

/// The connected monitors, in the order they registered.
fn knownMonitors(out: *[max_displays]monitors.Known) []const monitors.Known {
    var n: usize = 0;
    for (rt.displays.items) |d| if (d.s.state == .registered and n < out.len) {
        out[n] = .{ .id = d.s.monitor, .name = d.s.connector(), .width = d.s.metrics.width, .height = d.s.metrics.height };
        n += 1;
    };
    return out[0..n];
}

// ---- routing -------------------------------------------------------------------------------

/// Gives a registered monitor its renderer: a shared one already showing
/// this wallpaper, or a new process.
fn route(d: *Display) void {
    const path = rt.own.wallpaperFor(d.s.monitor, rt.current) orelse return;
    // A package shows the file it names (only ever as the main wallpaper).
    var file = path;
    var kind = Kind.forPath(path);
    if (adjust.isPackage(path)) {
        const pkg = (if (followsMain(d)) rt.pkg else null) orelse
            return log.warn("monitor {s}: not showing package {s} (see above)", .{ &d.s.monitor, path });
        file = pkg.entry;
        kind = pkg.kind;
    }
    // One saved by an older zmural, or reached by rotation: say so and go
    // back (`goBackFromBroken`), rather than a renderer that can't start.
    if (kind == .web) {
        rt.fallback.failed(rt.gpa, path, web_only);
        return;
    }
    const fill = rt.fills.fillFor(d.s.monitor, rt.settings.fill);
    const a = rt.router.assign(rt.gpa, d.s.monitor, path, @intFromEnum(fill)) catch return;
    d.renderer = a.renderer;
    if (a.stop) |old| stopRenderer(old);
    if (a.spawn) {
        const r = rt.gpa.create(Renderer) catch return;
        r.* = .{ .id = a.renderer, .kind = kind, .fill = fill, .main = followsMain(d), .path = rt.gpa.dupe(u8, file) catch {
            rt.gpa.destroy(r);
            return;
        } };
        rt.renderers.append(rt.gpa, r) catch {
            destroyRenderer(r);
            return;
        };
        const want = desire.forRenderer(&rt.settings.policy, .initEmpty(), &.{d.s.monitor}, &.{conditionsOf(d)}, &rt.router, r.id, rt.settings.paused);
        if (r.sup.begin(want)) start(r);
        return;
    }
    if (findRenderer(a.renderer)) |r| if (r.ready) addSurface(r, d);
}

fn unroute(d: *Display) void {
    const rid = d.renderer orelse return;
    d.renderer = null;
    if (findRenderer(rid)) |r| if (r.ready) sendRenderer(r, .{ .remove_surface = .{ .surface = d.s.id } }, &.{});
    d.s.unbind();
    if (rt.router.release(d.s.monitor)) |unused| stopRenderer(unused);
}

fn addSurface(r: *Renderer, d: *Display) void {
    sendRenderer(r, .{ .add_surface = .{
        .surface = d.s.id,
        .width = d.s.metrics.width,
        .height = d.s.metrics.height,
        .device = d.s.device,
        .modifiers = d.s.modifiers[0..d.s.modifiers_len],
    } }, &.{});
}

// ---- renderers -------------------------------------------------------------------------------

fn findRenderer(id: RendererId) ?*Renderer {
    for (rt.renderers.items) |r| if (r.id == id) return r;
    return null;
}

fn start(r: *Renderer) void {
    r.sup.attempting(now());
    spawn(r) catch |err| {
        log.err("renderer {d}: can't start ({s}): {s}", .{ r.id, r.kind.modeName(), @errorName(err) });
        report(r, r.sup.ended(now()));
    };
}

fn spawn(r: *Renderer) !void {
    var ends = try unix.pair();
    defer ends[1].close(); // the child's copy; it has its own after the spawn
    errdefer ends[0].close();
    try unix.inheritable(ends[1].fd);

    var ipc_buf: [16]u8 = undefined;
    const ipc = try std.fmt.bufPrint(&ipc_buf, "fd:{d}", .{ends[1].fd});
    const child = try std.process.spawn(rt.io, .{
        .argv = &.{ rt.opts.exe_path, Kind.mode_flag, r.kind.modeName(), "--ipc", ipc, "--path", r.path },
        .stdin = .ignore,
    });
    const pid = child.id orelse return error.SpawnFailed;
    const pfd = linux.pidfd_open(pid, 0);
    if (linux.errno(pfd) != .SUCCESS) {
        _ = linux.kill(pid, linux.SIG.KILL);
        return error.PidfdFailed;
    }
    ends[0].setSendTimeout(send_timeout_ms) catch |err| log.warn("renderer {d}: send timeout not set: {s}", .{ r.id, @errorName(err) });
    r.conn = ends[0];
    r.pid = pid;
    r.pidfd = @intCast(pfd);
    r.ready = false;
    log.info("renderer {d}: started ({s}, pid {d})", .{ r.id, r.kind.modeName(), pid });
}

fn onRendererReadable(r: *Renderer) void {
    var buf: [unix.max_frame]u8 = undefined;
    var fds: [unix.max_fds]linux.fd_t = undefined;
    var conn = &(r.conn orelse return);
    const f = conn.recv(&buf, &fds) catch {
        // Its end closed. The pidfd reports the exit itself; stop reading.
        conn.close();
        r.conn = null;
        return;
    };
    defer f.closeFds();
    const msg = f.decode(proto.FromRenderer) catch |err| {
        log.warn("renderer {d}: unreadable message (opcode {d}): {s}", .{ r.id, f.opcode, @errorName(err) });
        return;
    };
    switch (msg) {
        .ready => |ready| {
            if (ready.version != proto.version) {
                log.err("renderer {d}: protocol v{d}, expected v{d}", .{ r.id, ready.version, proto.version });
                if (r.pid) |pid| _ = linux.kill(pid, linux.SIG.KILL);
                return;
            }
            log.info("renderer {d}: ready ({s})", .{ r.id, ready.capabilities });
            r.ready = true;
            sendRenderer(r, .{ .init = .{
                .version = proto.version,
                .path = r.path,
                .fill = r.fill,
                .fps_cap = rt.settings.fps_cap,
                .volume = rt.settings.volume,
                .muted = rt.settings.muted,
            } }, &.{});
            sendProperties(r);
            for (rt.displays.items) |d| if (d.renderer == r.id) addSurface(r, d);
            execute(r, r.sup.ready());
        },
        .buffers => |b| {
            const d = findDisplay(b.surface) orelse return;
            if (d.renderer != r.id) return; // not a monitor this renderer feeds
            if (f.fds.len != b.count) {
                log.warn("renderer {d}: buffers with {d} fds for {d} slots; ignoring", .{ r.id, f.fds.len, b.count });
                return;
            }
            // The same token for the same wallpaper, however often the pool is rebuilt.
            const token = std.hash.Wyhash.hash(0, r.path);
            d.s.bind(rt.drm, b.generation, b.count, b.width, b.height, b.fourcc, b.modifier, b.offset, b.stride, token, f.fds) catch |err|
                log.err("display {d}: can't publish buffers: {s}", .{ d.s.id, @errorName(err) });
        },
        .frame_ready => |fr| {
            const d = findDisplay(fr.surface) orelse return;
            if (d.renderer != r.id) return;
            if (fr.generation != d.s.renderer_generation) {
                // A frame from a pool the display no longer has: straight back.
                sendRenderer(r, .{ .release = .{ .surface = fr.surface, .generation = fr.generation, .slot = fr.slot } }, &.{});
                return;
            }
            // The renderer's fence, when its driver has them; the display
            // waits on it rather than the renderer on its GPU.
            const acquire: linux.fd_t = if (f.fds.len > 0) f.fds[0] else -1;
            d.s.frame(rt.drm, fr.slot, acquire) catch |err|
                log.warn("display {d}: frame for slot {d}: {s}", .{ d.s.id, fr.slot, @errorName(err) });
            // The main wallpaper reached the screen: the one to go back to.
            if (rt.current) |c| if (std.mem.eql(u8, c, r.path)) rt.fallback.played(rt.gpa, r.path);
        },
        .log => |l| log.info("[{s} {d}] {s}: {s}", .{ @tagName(r.kind), r.id, @tagName(l.level), l.text }),
        .failed => |fl| {
            log.err("renderer {d}: {s}", .{ r.id, fl.message });
            // Dealt with on the next tick, outside this renderer's message.
            if (cantShow(fl.message)) rt.fallback.failed(rt.gpa, r.path, fl.message);
        },
        .decoder => |dc| onDecoder(r, dc),
        .shown => {}, // Windows only
        .window => {}, // Windows only
    }
}

/// A video started: say in the log what decodes it, and the first time a
/// codec lands on the CPU, tell the user (once per codec). Nothing is wrong
/// and nothing is installed for them; it is the system's drivers and codecs
/// that decide, and the wallpaper plays either way.
///
/// This is the check, and it runs every time a video starts: mpv asks the
/// system afresh, so codecs or drivers installed since are picked up by the
/// next wallpaper change or restart. The "already told" note is kept for
/// good, as the notice promises: whether the GPU decodes a codec can depend
/// on the file (its profile, its size), so one file of it on the GPU says
/// nothing about the next (the blind test of 0.1.0 was told about VP9 twice).
fn onDecoder(r: *Renderer, d: proto.Decoder) void {
    const codec = if (notices.plain(d.codec)) d.codec else "video";
    var key_buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "cpu-decode {s}", .{codec}) catch return;
    if (d.method.len > 0) {
        const method = if (notices.plain(d.method)) d.method else "hardware";
        log.info("renderer {d}: decoding {s} on the GPU ({s})", .{ r.id, codec, method });
        return;
    }
    // A picture is decoded once, and GPUs don't decode pictures (or GIFs):
    // nothing to tell.
    if (r.kind == .image) return log.info("renderer {d}: decoding {s} on the CPU", .{ r.id, codec });
    log.info("renderer {d}: decoding {s} on the CPU: no GPU decoder for it on this system", .{ r.id, codec });
    const dir = rt.opts.state_dir orelse return;
    if (notices.seen(rt.io, rt.gpa, dir, key)) return;
    var name_buf: [16]u8 = undefined;
    const name = notices.codecName(&name_buf, d.codec);
    var summary_buf: [96]u8 = undefined;
    var body_buf: [400]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "No GPU decoder for {s} found", .{name}) catch return;
    const body = std.fmt.bufPrint(&body_buf, "zmural is playing this wallpaper using the CPU instead of the GPU. It looks the same and uses more power. Which video formats the GPU can decode depends on the drivers and codecs installed on your system. You won't be told about {s} again.", .{name}) catch return;
    // With no desktop to tell (no session bus yet), try again next time.
    if (desktop.shown(if (rt.bus) |*b| b else null, summary, body)) notices.remember(rt.io, rt.gpa, dir, key);
}

fn sendRenderer(r: *Renderer, msg: proto.ToRenderer, fds: []const linux.fd_t) void {
    var c = &(r.conn orelse return);
    c.send(proto.ToRenderer, msg, fds) catch |err| {
        log.warn("renderer {d}: send failed ({s})", .{ r.id, @errorName(err) });
        c.shutdown();
    };
}

fn execute(r: *Renderer, cmd: lifecycle.Command) void {
    switch (cmd) {
        .spawn => start(r),
        .terminate => {
            log.info("renderer {d}: stopped by a pause rule", .{r.id});
            sendRenderer(r, .stop, &.{});
            r.stop_at = now() + stop_grace_ms;
        },
        .play => |p| {
            sendRenderer(r, .{ .set_volume = .{ .volume = rt.settings.volume, .muted = rt.settings.muted or p.muted } }, &.{});
            sendRenderer(r, .play, &.{});
        },
        .pause => sendRenderer(r, .pause, &.{}),
    }
}

/// The renderer process exited: reap it, clear its monitors, and let the
/// supervisor decide about a restart.
fn reap(r: *Renderer) void {
    var status: u32 = 0;
    if (r.pid) |pid| _ = linux.wait4(pid, &status, 0, null);
    if (r.pidfd >= 0) _ = linux.close(r.pidfd);
    r.pidfd = -1;
    r.pid = null;
    r.stop_at = null;
    r.ready = false;
    if (r.conn) |*c| c.close();
    r.conn = null;
    for (rt.displays.items) |d| if (d.renderer == r.id) d.s.unbind();

    if (rt.router.get(r.id) == null) {
        // Nothing uses it any more (a deliberate stop): forget it.
        log.info("renderer {d}: exited", .{r.id});
        if (std.mem.findScalar(*Renderer, rt.renderers.items, r)) |i| _ = rt.renderers.swapRemove(i);
        destroyRenderer(r);
        return;
    }
    log.info("renderer {d}: exited with status 0x{x}", .{ r.id, status });
    report(r, r.sup.ended(now()));
    tellCrash(.renderer);
}

/// A renderer's failure that means the file itself can't be a wallpaper
/// (not a video at all, a format nothing here reads), not a passing problem.
fn cantShow(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "cannot play") or std.mem.startsWith(u8, message, "cannot show");
}

/// A wallpaper couldn't be played or shown (`Fallback`). Monitors that had it
/// as their own follow the main wallpaper again; if it was the main one, the
/// last wallpaper that played comes back (or zmural's own). A notification
/// says so: left alone, the desktop would stay empty.
fn goBackFromBroken() void {
    const broken = rt.fallback.take() orelse return;
    defer rt.gpa.free(broken);
    while (rt.own.showing(broken)) |m| setOwn(m, null) catch break;
    const main = if (rt.current) |c| std.mem.eql(u8, c, broken) else false;
    // "again" only for something that has played; on a first start whose
    // saved wallpaper is broken, zmural's own shows "instead".
    const played_before = if (rt.fallback.last_good) |p| !std.mem.eql(u8, p, broken) else false;
    const said = rt.fallback.message();
    var body: [700]u8 = undefined;
    const text = (if (!main)
        std.fmt.bufPrint(&body, "{s}. That monitor shows the main wallpaper again.", .{said})
    else if (backFrom(broken)) |back|
        std.fmt.bufPrint(&body, "{s}. Showing {s} {s}.", .{ said, zmural.media.displayName(back), if (played_before) "again" else "instead" })
    else
        std.fmt.bufPrint(&body, "{s}. Pick another wallpaper.", .{said})) catch "It can't be played. Pick another wallpaper.";
    var title_buf: [300]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "zmural can't show {s}", .{zmural.media.displayName(broken)}) catch "zmural can't show this wallpaper";
    log.info("{s}: {s}", .{ title, text });
    desktop.notify(if (rt.bus) |*b| b else null, title, text);
}

/// Shows what to go back to instead of `broken` and returns it (valid until
/// the next change), or null when there is nothing else to show.
fn backFrom(broken: []const u8) ?[]const u8 {
    const own = if (rt.opts.starter_dir) |d| starter.path(rt.gpa, d) catch null else null;
    defer if (own) |p| rt.gpa.free(p);
    const back = rt.fallback.instead(broken, own) orelse return null;
    setWallpaper(back) catch {
        // Gone since it played: zmural's own, unless that is what failed.
        const p = own orelse return null;
        if (std.mem.eql(u8, p, broken) or std.mem.eql(u8, p, back)) return null;
        setWallpaper(p) catch return null;
    };
    return rt.current;
}

/// A crash left its code (`os/crashlog.zig`): tell the user, with the line to
/// pass on if they want to report it. One notice per run: a renderer crashing
/// over and over until zmural gives up would otherwise send one each time.
/// The latest line stays in `status` (and so the settings window) all run.
fn tellCrash(when: enum { last_run, renderer }) void {
    const dir = rt.opts.state_dir orelse return;
    var buf: [256]u8 = undefined;
    const code = zmural.os.crashlog.takeCode(rt.io, dir, &buf) orelse return;
    rt.crash_len = @min(code.len, rt.crash_buf.len);
    @memcpy(rt.crash_buf[0..rt.crash_len], code[0..rt.crash_len]);
    if (rt.crash_told) return log.warn("another crash this run (not told again): {s}", .{code});
    rt.crash_told = true;
    log.warn("told the user about a crash: {s}", .{code});
    var body: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "{s} To report it, post this line (it is also in zmural's log):\n{s}", .{ switch (when) {
        .last_run => "zmural stopped unexpectedly last time.",
        .renderer => "Part of zmural stopped unexpectedly and was restarted.",
    }, code }) catch return;
    desktop.notify(if (rt.bus) |*b| b else null, "zmural ran into a problem", text);
}

fn report(r: *Renderer, outcome: lifecycle.Outcome) void {
    switch (outcome) {
        .expected => {},
        .restart_in_ms => |ms| log.warn("renderer {d}: restarting in {d} ms", .{ r.id, ms }),
        .gave_up => |n| log.err("renderer {d}: gave up after {d} failed starts", .{ r.id, n }),
    }
}

fn destroyRenderer(r: *Renderer) void {
    rt.gpa.free(r.path);
    rt.gpa.destroy(r);
}

/// A renderer nothing uses any more: ask it to stop, kill it if it doesn't.
fn stopRenderer(id: RendererId) void {
    const r = findRenderer(id) orelse return;
    if (r.pid == null) {
        if (std.mem.findScalar(*Renderer, rt.renderers.items, r)) |i| _ = rt.renderers.swapRemove(i);
        destroyRenderer(r);
        return;
    }
    sendRenderer(r, .stop, &.{});
    r.stop_at = now() + stop_grace_ms;
}

fn shutdown() void {
    // The window's thread uses this process's memory: it goes first.
    settings_window.close();
    // Then the bus stops reaching our handlers, before anything they use is
    // freed: a `call` dispatches whatever arrives while it waits, and KWin
    // reports the app now in front (the window just closed) during
    // `unloadScript`.
    if (rt.bus) |*b| {
        b.hook = null;
        if (rt.front_watched) foreground.stopKde(b);
    }
    if (rt.compositor) |*w| w.stop();
    if (rt.niri) |*w| w.stop();
    if (rt.still.set_for) |p| rt.gpa.free(p);
    if (rt.still.frame_for) |p| rt.gpa.free(p);
    // Our display host goes with us: quitting zmural gives the desktop back.
    if (rt.host.pid) |pid| {
        _ = linux.kill(pid, linux.SIG.TERM);
        var status: u32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
        rt.host.pid = null;
    }
    for (rt.renderers.items) |r| {
        sendRenderer(r, .stop, &.{});
        if (r.pid) |pid| {
            _ = linux.kill(pid, linux.SIG.TERM);
            var status: u32 = 0;
            _ = linux.wait4(pid, &status, 0, null);
        }
        if (r.pidfd >= 0) _ = linux.close(r.pidfd);
        if (r.conn) |*c| c.close();
        destroyRenderer(r);
    }
    rt.renderers.deinit(rt.gpa);
    rt.own.deinit(rt.gpa);
    if (rt.props) |*p| p.deinit();
    for (rt.displays.items) |d| {
        d.s.close();
        rt.gpa.destroy(d);
    }
    rt.displays.deinit(rt.gpa);
    rt.router.deinit(rt.gpa);
    rt.listener.close();
    if (rt.drm >= 0) _ = linux.close(rt.drm);
    if (rt.bus) |*b| b.close();
    for (rt.clients.items) |*c| c.close();
    rt.clients.deinit(rt.gpa);
    if (rt.control_listener) |*l| l.close();
    if (rt.current) |w| rt.gpa.free(w);
    rt.rotation.deinit(rt.gpa);
    rt.fallback.deinit(rt.gpa);
    rt.library.deinit();
    for (rt.default_dirs) |d| rt.gpa.free(d);
    rt.gpa.free(rt.default_dirs);
    if (rt.file_arena) |*a| a.deinit();
    rt.app_rules.deinit(rt.gpa);
    rt.user_dirs.deinit(rt.gpa);
}
