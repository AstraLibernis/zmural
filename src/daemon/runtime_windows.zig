// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zmural on Windows: shows one wallpaper on every monitor through
//! out-of-process renderers.
//!
//! - Renderers run in a kill-on-close Job Object, so the kernel reaps them if
//!   the daemon dies. The watchdog then repaints the static wallpaper.
//! - Each renderer gets its own single-instance, owner-only named pipe. A
//!   reader thread per renderer posts frames to the hidden control window, so
//!   all protocol handling happens on this one thread. The daemon checks that
//!   the process on the other end, and the windows it reports, are the
//!   renderer it spawned.
//! - Monitors showing the same wallpaper share one renderer (`Router`), which
//!   draws one surface per monitor.
//! - Each renderer's start / crash / restart / pause-policy state lives in a
//!   pure `lifecycle.Supervisor`; this file only carries out its commands.
//! - Explorer restarts and desktop-layer teardown re-attach every surface.
//! - Smart pausing: window, power and session events trigger a coalesced
//!   re-check of what's on screen (`facts.zig`); the pause policy turns that
//!   into play / mute / pause / stop per renderer.

const std = @import("std");
const zmural = @import("zmural");
const hosts = @import("hosts");
const w = zmural.os.win32;
const process = zmural.os.process;
const pipe = zmural.protocol.pipe;
const proto = zmural.protocol.renderer;
const control = zmural.protocol.control;
const Host = hosts.windows.Host;
const monitors = hosts.windows.monitors;
/// Which monitor shows which wallpaper (shared with the Linux runtime).
const per_monitor = @import("monitors.zig");
const adjust = @import("adjust.zig");
const Fallback = @import("fallback.zig").Fallback;
const starter = @import("starter.zig");
const facts = hosts.windows.facts;
const MonitorId = zmural.monitor.Id;
const Action = zmural.policy.Action;
const Conditions = zmural.policy.Conditions;
const Router = @import("router.zig").Router;
const RendererId = @import("router.zig").RendererId;
const ControlServer = @import("control_windows.zig").Server;
const Settings = @import("settings.zig").Settings;
const Rotation = @import("rotation.zig").Rotation;
const SettingsStore = @import("settings.zig").Store;
const Library = @import("library.zig").Library;
const Tray = @import("tray_windows.zig").Tray;
const lifecycle = @import("lifecycle.zig");
const desire = @import("desire.zig");
const lists = @import("lists.zig");
const web_renderer = zmural.sdk.web_renderer;
const manifest = zmural.manifest;
const props = zmural.properties;
const settings_file = @import("settings.zig");

const WM_RENDERER = w.WM_APP + 1;
const WM_LAYER_GONE = w.WM_APP + 2;
const WM_CONTROL = w.WM_APP + 3;
const WM_TRAY = w.WM_APP + 4;
/// A background library scan finished (LPARAM = *ScanJob).
const WM_SCANNED = w.WM_APP + 5;
const timer_tick: usize = 1;
const timer_reattach: usize = 2;
const timer_facts: usize = 3;
/// Bursts of window events collapse into one re-check this long after the first.
const facts_coalesce_ms = 100;
/// Backstop: re-check at least this often even without events (in ticks).
const facts_backstop_ticks = 8;
const tick_ms = 250;
const reattach_delay_ms = 500;
const connect_timeout_ms = 10_000;
/// How long a renderer asked to stop gets before it is killed.
const stop_grace_ms = 1_000;
/// Writes to a renderer give up after this long; it is then killed.
const renderer_write_timeout_ms = 2_000;
/// How often settings.toml is checked for hand edits (in ticks).
const file_check_ticks = 4;
/// How often a startup wallpaper that couldn't be shown is tried again (in ticks).
const startup_retry_ticks = 20;
/// UI limits for web renderers: none. Any UI limit on the parent job makes
/// Chromium's sandboxed page process exit at once (each one tested alone,
/// 2026-09-27). The untrusted page runs in that sandbox instead, which is
/// stricter than these limits: a restricted token, its own job and desktop.
const web_ui_limits: w.DWORD = 0;
/// Library scans run on worker threads; this heap is thread-safe.
const scan_alloc = std.heap.smp_allocator;

const kind_mod = @import("kind.zig");
const settings_window = @import("settings");
pub const Kind = kind_mod.Kind;

const Renderer = struct {
    id: RendererId,
    kind: Kind,
    /// The wallpaper it shows (owned): monitors can show different ones.
    path: []u8,
    /// It shows the main wallpaper, so the package (if any) is its own.
    main: bool,
    /// How it fills the screen: monitors can differ in that too.
    fill: zmural.layout.FillMode,
    sup: lifecycle.Supervisor = .{},
    child: ?process.Child = null,
    conn: ?pipe.Conn = null,
    reader: ?w.HANDLE = null,
    /// The pipe client has been checked to be `child`.
    verified: bool = false,
    /// Its attached window per monitor index, so a successor can go beneath it.
    windows: [per_monitor.max]?w.HWND = @splat(null),
};

/// A renderer the router no longer uses, kept on screen until what replaces
/// it shows its first frame, so the desktop never shows through a switch.
const Outgoing = struct {
    id: RendererId,
    /// Monitor indices it was showing on, as bits.
    mask: u32,
    /// Retired by then even if nothing reported a first frame.
    deadline: u64,
};

/// How long an outgoing wallpaper waits for its replacement's first frame.
const outgoing_wait_ms = 4000;

/// A wallpaper package that is showing: its manifest, the file renderers
/// open, and the user's property values.
const Package = struct {
    arena: std.heap.ArenaAllocator,
    m: manifest.Manifest,
    /// The entry file, as a full path.
    entry: []const u8,
    /// One per `m.properties`, always valid for it.
    values: []manifest.Value,
    /// Where the values are kept (`<config>\properties\<id>.toml`).
    values_file: []const u8,

    fn deinit(pkg: *Package) void {
        pkg.arena.deinit();
    }
};

const Runtime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    settings: Settings,
    store: ?SettingsStore = null,
    /// The startup wallpaper settings.toml names. It is kept while it can't be
    /// shown (say, on a USB drive that isn't plugged in yet): saving writes it
    /// back instead of erasing it, and the tick keeps trying to show it.
    startup_wallpaper: []const u8 = "",
    /// While `--paused` overrides it for this run: what the file says.
    paused_on_disk: ?bool = null,
    /// Owns the settings' strings once settings.toml has been reloaded.
    file_arena: ?std.heap.ArenaAllocator = null,
    /// settings.toml as zmural last read or wrote it (null: no file).
    file_stamp: ?FileStamp = null,
    /// Bumped per library scan; only the newest scan's result is used.
    scan_gen: u32 = 0,
    library: Library = undefined,
    /// Timed changes, and the order Next/Previous follow.
    rotation: Rotation = .{},
    /// Always scanned: Videos\Wallpapers and Pictures\Wallpapers.
    default_dirs: []const []const u8 = &.{},
    /// `default_dirs`, then the user's folders (owned).
    library_dirs: []const []const u8 = &.{},
    /// The user's lists once the settings window replaces them; until then
    /// `settings` points at the loaded ones.
    app_rules: lists.Owned = .{},
    user_dirs: lists.Owned = .{},
    /// What every monitor shows (owned); null until something is applied.
    /// For a package, its `zmural.toml`.
    wallpaper: ?[]u8 = null,
    /// The package behind `wallpaper`, when it is one.
    package: ?Package = null,
    server: ?ControlServer = null,
    tray: ?Tray = null,
    instance: ?w.HINSTANCE = null,
    control: ?w.HWND = null,
    host: ?Host = null,
    hook: ?w.HWINEVENTHOOK = null,
    taskbar_created: w.UINT = 0,
    main_thread: w.DWORD = 0,
    job: ?process.Job = null,
    /// Web renderers' job: WebView2's own sandbox needs some of what the
    /// mpv renderers' job forbids.
    web_job: ?process.Job = null,
    watchdog: ?process.Child = null,
    screens: monitors.List = .{},
    screen_ids: [monitors.max]MonitorId = undefined,
    /// Each monitor's device name without the `\\.\` ("DISPLAY1"), for people.
    screen_names: [monitors.max][32]u8 = undefined,
    screen_name_lens: [monitors.max]usize = @splat(0),
    /// Monitors showing a wallpaper of their own instead of `wallpaper`.
    own: per_monitor.Own = .{},
    /// Monitors filling their screen another way than `settings.fill`.
    fills: per_monitor.Fills = .{},
    router: Router = .{},
    renderers: std.ArrayList(*Renderer) = .empty,
    outgoing: std.ArrayList(Outgoing) = .empty,
    quitting: bool = false,
    /// The last crash's line (`tellCrash`), and whether a notice went out this run.
    crash_buf: [256]u8 = undefined,
    crash_len: usize = 0,
    crash_told: bool = false,
    /// What to go back to when a wallpaper can't be played (`goBackFromBroken`).
    fallback: Fallback = .{},
    shut_down: bool = false,
    watcher: facts.Watcher = .{},
    facts_pending: bool = false,
    locked: bool = false,
    snapshot: facts.Snapshot = .{},
    ticks: u32 = 0,
};

var rt: Runtime = undefined;

/// Runs the daemon. `error.AlreadyRunning`: something already owns the control
/// pipe (the caller checks whether it's really our zmural). `start_paused`
/// pauses this run only; the file keeps its own `paused` value.
/// What the settings window needs when it is opened; set before `run`.
pub var settings_env: settings_window.Env = undefined;
/// Open the settings window once zmural is up (`zmural --settings`).
pub var open_settings_at_start = false;
/// The folder of the wallpaper zmural ships with (`starter.zig`), scanned
/// after the user's own; null when it isn't there.
pub var starter_dir: ?[]const u8 = null;
/// Where to list zmural as an app once it owns the control pipe (null in tests).
pub var app_entry: ?struct { appdata: []const u8, app: zmural.os.apps_windows.App } = null;

pub fn run(gpa: std.mem.Allocator, settings: Settings, store: SettingsStore, default_dirs: []const []const u8, wallpaper: ?[]const u8, start_paused: bool, control_name: []const u8) !void {
    rt = .{
        .gpa = gpa,
        .io = store.io,
        .settings = settings,
        .store = store,
        .startup_wallpaper = settings.wallpaper,
        .library = .init(scan_alloc),
        .default_dirs = default_dirs,
    };
    rt.file_stamp = stampOf(store);
    rt.own.load(gpa, settings.monitor_wallpapers);
    rt.fills.load(settings.monitor_fills);
    if (start_paused) {
        rt.paused_on_disk = settings.paused;
        rt.settings.paused = true;
    }
    errdefer {
        rt.watcher.uninstall();
        if (rt.tray) |*t| t.hide();
        if (rt.server) |*s| s.stop();
        releaseMemory();
    }
    try setLibraryDirs(settings.library_dirs);
    rt.router.share = settings.share_renderers;

    _ = w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    rt.instance = w.GetModuleHandleW(null);
    rt.main_thread = w.GetCurrentThreadId();
    rt.taskbar_created = w.RegisterWindowMessageW(w.L("TaskbarCreated"));
    const class = w.L("zmural.daemon");
    if (w.RegisterClassExW(&.{ .lpfnWndProc = controlProc, .hInstance = rt.instance, .lpszClassName = class }) == 0)
        return error.RegisterClassFailed;
    // A hidden top-level window (not message-only): it must receive broadcasts.
    rt.control = w.CreateWindowExW(w.WS_EX_TOOLWINDOW, class, w.L("zmural"), w.WS_POPUP, 0, 0, 0, 0, null, null, rt.instance, null) orelse
        return error.CreateWindowFailed;
    rt.server = ControlServer.start(gpa, control_name, rt.control.?, WM_CONTROL) catch |err| {
        _ = w.DestroyWindow(rt.control.?);
        return if (err == error.InUse) error.AlreadyRunning else err;
    };
    if (wallpaper) |p| {
        if (playable(p)) |_| {
            rt.package = if (isPackage(p)) loadPackage(p) catch null else builtinProperties(p);
            if (!isPackage(p) or rt.package != null) rt.wallpaper = try gpa.dupe(u8, p);
        } else |why| std.log.warn("not showing '{s}': {s}", .{ p, whyNot(why) });
    }
    _ = w.SetConsoleCtrlHandler(onConsoleCtrl, 1);
    _ = w.WTSRegisterSessionNotification(rt.control.?, w.NOTIFY_FOR_THIS_SESSION);
    rt.watcher = facts.Watcher.install(onWindowEvent);

    rescan();
    rt.tray = Tray.init(rt.control.?, WM_TRAY);
    rt.tray.?.show();
    updateTray();
    tellCrash(.last_run);
    if (app_entry) |e| {
        if (zmural.os.apps_windows.register(gpa, settings_env.io, e.appdata, e.app)) |wrote| {
            if (wrote) std.log.info("listed zmural as an app (Start menu, Settings > Apps) from {s}", .{e.app.dir});
        } else |err| std.log.warn("can't list zmural as an app: {s}", .{@errorName(err)});
    }
    if (app_entry != null) setUpAutostart(); // not in tests either
    rt.job = try process.Job.init(process.Job.renderer_ui_limits);
    rt.web_job = try process.Job.init(web_ui_limits);
    startWatchdog();

    std.log.info("zmural {s}: control pipe {s}; settings {s}; showing '{s}'", .{ zmural.version, control_name, store.path, rt.wallpaper orelse "(nothing yet)" });
    attachHost();
    _ = refreshScreens();
    evaluate(); // know what the policy wants before any renderer starts
    applyWallpaper();
    _ = w.SetTimer(rt.control, timer_tick, tick_ms, null);
    if (open_settings_at_start) openSettings();

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    shutdown();
}

fn now() u64 {
    return w.GetTickCount64();
}

// ---- lifecycle ---------------------------------------------------------------

fn startWatchdog() void {
    const exe = process.selfExe(rt.gpa) catch return warnWatchdog();
    defer rt.gpa.free(exe);
    var pid_buf: [16]u8 = undefined;
    const pid = std.fmt.bufPrint(&pid_buf, "{d}", .{w.GetCurrentProcessId()}) catch unreachable; // zsnag:ok — 16 bytes fit any u32
    // Deliberately NOT in the job: it has to outlive us.
    rt.watchdog = process.spawn(rt.gpa, exe, &.{ "--watchdog", "--parent", pid }, .{}) catch return warnWatchdog();
}

fn warnWatchdog() void {
    std.log.warn("could not start the watchdog; a crash may leave a stale frame (classic layout)", .{});
}

/// Runs once, from the message loop's end or from WM_ENDSESSION.
fn shutdown() void {
    if (rt.shut_down) return;
    rt.shut_down = true;
    rt.quitting = true;
    // The window's thread uses this process's memory: it goes first.
    settings_window.close();
    _ = w.KillTimer(rt.control, timer_tick);
    _ = w.KillTimer(rt.control, timer_facts);
    _ = w.KillTimer(rt.control, timer_reattach);

    // Ask politely, give them a moment, then let the job finish the job.
    for (rt.renderers.items) |r| {
        if (r.conn) |*c| c.send(proto.ToRenderer, .stop) catch {}; // zsnag:ok — it may already be gone; the job kill below covers it
    }
    for (rt.renderers.items) |r| {
        if (r.child) |c| _ = w.WaitForSingleObject(c.process, stop_grace_ms);
    }
    if (rt.job) |j| j.killAll();
    if (rt.web_job) |j| j.killAll();
    for (rt.renderers.items) |r| reap(r, 0);

    if (rt.hook) |h| _ = w.UnhookWinEvent(h);
    rt.watcher.uninstall();
    _ = w.WTSUnRegisterSessionNotification(rt.control.?);
    zmural.os.desktop.refreshStaticWallpaper();
    // A clean exit needs no watchdog; don't let it act on our behalf.
    if (rt.watchdog) |wd| {
        wd.kill();
        wd.close();
    }
    if (rt.server) |*s| s.stop();
    if (rt.tray) |*t| t.hide();
    // A first run that changed nothing leaves no settings.toml, so the next
    // start is a first run again (Welcome, Prism), as on Linux.
    const untouched = if (rt.store) |s| s.fresh and rt.file_stamp == null else false;
    if (!untouched) save();
    if (rt.job) |j| j.deinit();
    if (rt.web_job) |j| j.deinit();
    releaseMemory();
    std.log.info("zmural: stopped, desktop restored", .{});
}

/// Frees everything the runtime allocated. Messages still queued after
/// this are dropped by `controlProc`.
fn releaseMemory() void {
    if (rt.wallpaper) |p| rt.gpa.free(p);
    rt.wallpaper = null;
    if (rt.package) |*pkg| pkg.deinit();
    rt.package = null;
    rt.library.deinit();
    rt.library = .init(scan_alloc);
    rt.rotation.deinit(rt.gpa);
    rt.fallback.deinit(rt.gpa);
    rt.gpa.free(rt.library_dirs);
    rt.library_dirs = &.{};
    rt.app_rules.deinit(rt.gpa);
    rt.user_dirs.deinit(rt.gpa);
    for (rt.renderers.items) |r| destroyRenderer(r);
    rt.renderers.deinit(rt.gpa);
    rt.outgoing.deinit(rt.gpa);
    rt.own.deinit(rt.gpa);
    rt.router.deinit(rt.gpa);
    rt.router = .{};
    // Last: the settings' strings may live here.
    rt.settings = .{};
    rt.startup_wallpaper = "";
    if (rt.file_arena) |*a| a.deinit();
    rt.file_arena = null;
}

fn attachHost() void {
    const host = Host.init() catch |err| {
        // Forget the old layer: it's gone, and nothing may attach to it.
        rt.host = null;
        std.log.warn("desktop layer not ready ({s}); retrying", .{@errorName(err)});
        scheduleReattach();
        return;
    };
    rt.host = host;
    std.log.info("desktop: {s} layout, explorer pid {d}", .{ @tagName(host.layout), host.explorer_pid });
    if (rt.hook) |old| _ = w.UnhookWinEvent(old);
    rt.hook = w.SetWinEventHook(w.EVENT_OBJECT_DESTROY, w.EVENT_OBJECT_DESTROY, null, onWinEvent, host.explorer_pid, 0, w.WINEVENT_OUTOFCONTEXT);
}

/// Returns whether the set of monitors changed. A monitor's identity is its
/// device name, not its resolution: a game switching modes must not look
/// like a different monitor.
fn refreshScreens() bool {
    const before = rt.screens;
    const before_ids = rt.screen_ids;
    rt.screens = monitors.enumerate();
    for (rt.screens.slice(), 0..) |m, i| {
        var name: [32]u8 = undefined;
        var len: usize = 0;
        for (m.device) |c| {
            if (c == 0) break;
            name[len] = if (c < 0x80) @intCast(c) else '?'; // zsnag:ok — checked < 0x80
            len += 1;
        }
        rt.screen_ids[i] = zmural.monitor.fromConnector(name[0..len]);
        const short = if (std.mem.startsWith(u8, name[0..len], "\\\\.\\")) name[4..len] else name[0..len];
        @memcpy(rt.screen_names[i][0..short.len], short);
        rt.screen_name_lens[i] = short.len;
        std.log.info("monitor {d}: {d}x{d} at ({d},{d}){s}", .{ i, m.rect.w, m.rect.h, m.rect.x, m.rect.y, if (m.primary) " primary" else "" });
    }
    if (before.len != rt.screens.len) return true;
    for (0..before.len) |i| {
        if (!std.mem.eql(u8, &before_ids[i], &rt.screen_ids[i])) return true;
    }
    return false;
}

/// Points every monitor at the wallpaper, spawning or stopping renderers as the router says.
fn applyWallpaper() void {
    // Who fed each monitor before, to know where an outgoing renderer showed.
    var before: [per_monitor.max]?RendererId = @splat(null);
    for (rt.screen_ids[0..rt.screens.len], 0..) |id, i| before[i] = rt.router.rendererFor(id);
    for (rt.screen_ids[0..rt.screens.len], 0..) |id, i| {
        const own = rt.own.get(id);
        const wallpaper = own orelse rt.wallpaper orelse continue;
        const fill = rt.fills.fillFor(id, rt.settings.fill);
        const a = rt.router.assign(rt.gpa, id, wallpaper, @intFromEnum(fill)) catch |err| {
            std.log.err("routing failed: {s}", .{@errorName(err)});
            continue;
        };
        if (a.stop) |old| {
            // Replaced by a new renderer: it stays until that one shows.
            // Otherwise (another running renderer took the monitor) it goes now.
            if (a.spawn) keepUntilReplaced(old, &before, i) else retire(old);
        }
        if (a.spawn) {
            const r = rt.gpa.create(Renderer) catch {
                std.log.err("out of memory", .{});
                continue;
            };
            // A monitor's own wallpaper is a plain file or address; only the
            // main one can be a package.
            r.* = .{
                .id = a.renderer,
                .kind = if (own == null) currentKind() else Kind.forPath(wallpaper),
                .main = own == null,
                .fill = fill,
                .path = rt.gpa.dupe(u8, wallpaper) catch {
                    rt.gpa.destroy(r);
                    std.log.err("out of memory", .{});
                    continue;
                },
            };
            rt.renderers.append(rt.gpa, r) catch {
                destroyRenderer(r);
                std.log.err("out of memory", .{});
                continue;
            };
            if (r.sup.begin(desiredFor(r))) {
                start(r);
            } else {
                std.log.info("renderer {d}: not started (a pause rule says stop)", .{r.id});
                // Nothing will show here soon: don't keep the old one waiting.
                retireOutgoing(@as(u32, 1) << @intCast(i), true); // zsnag:ok — i < monitors.max (16)
            }
        }
    }
}

fn keepUntilReplaced(old: RendererId, before: []const ?RendererId, upto: usize) void {
    var mask: u32 = 0;
    for (before[0 .. upto + 1], 0..) |b, j| {
        if (b == old) mask |= @as(u32, 1) << @intCast(j); // zsnag:ok — j < monitors.max (16)
    }
    rt.outgoing.append(rt.gpa, .{ .id = old, .mask = mask, .deadline = now() + outgoing_wait_ms }) catch retire(old);
}

/// Retires the outgoing renderers on any monitor in `mask` (bits), or only
/// those past their deadline unless `all`.
fn retireOutgoing(mask: u32, all: bool) void {
    const t = now();
    var i: usize = 0;
    while (i < rt.outgoing.items.len) {
        const o = rt.outgoing.items[i];
        if (o.mask & mask != 0 and (all or t >= o.deadline)) {
            _ = rt.outgoing.swapRemove(i);
            retire(o.id);
        } else i += 1;
    }
}

/// The outgoing renderer's window on monitor `index`, if it still has one.
fn outgoingWindow(index: usize) ?w.HWND {
    for (rt.outgoing.items) |o| {
        if (o.mask & (@as(u32, 1) << @intCast(index)) == 0) continue; // zsnag:ok — index < monitors.max (16)
        const r = find(o.id) orelse continue;
        const hwnd = r.windows[index] orelse continue;
        if (w.IsWindow(hwnd) != 0) return hwnd;
    }
    return null;
}

fn start(r: *Renderer) void {
    r.sup.attempting(now());
    r.verified = false;
    // Unguessable, so nobody (another user included) can create the name
    // first: our first-instance claim would fail and the wallpaper never start.
    var nonce: [8]u8 = undefined;
    rt.io.random(&nonce);
    var name_buf: [96]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "\\\\.\\pipe\\zmural-r{d}-{x:0>16}", .{ r.id, std.mem.readInt(u64, &nonce, .little) }) catch unreachable; // zsnag:ok — 96 bytes fit a u32 and 16 hex digits
    r.conn = pipe.listen(rt.gpa, name, .{}) catch |err| return failedToStart(r, "pipe", err);
    r.conn.?.write_timeout_ms = renderer_write_timeout_ms;

    const exe = process.selfExe(rt.gpa) catch |err| return failedToStart(r, "locate", err);
    defer rt.gpa.free(exe);
    r.child = process.spawn(rt.gpa, exe, &.{ Kind.mode_flag, r.kind.modeName(), "--ipc", name, "--path", renderPathFor(r) }, .{ .job = if (r.kind == .web) rt.web_job else rt.job }) catch |err|
        return failedToStart(r, "spawn", err);

    r.reader = pipe.startReader(.{
        .conn = &r.conn.?,
        .hwnd = rt.control.?,
        .msg = WM_RENDERER,
        .tag = r.id,
        .accept_timeout_ms = connect_timeout_ms,
        .accept_abort = r.child.?.process,
    }) catch |err| return failedToStart(r, "reader", err);
    std.log.info("renderer {d}: started ({s}, pid {d})", .{ r.id, r.kind.modeName(), r.child.?.pid });
}

fn failedToStart(r: *Renderer, what: []const u8, err: anyerror) void {
    std.log.err("renderer {d}: {s} failed: {s}", .{ r.id, what, @errorName(err) });
    reap(r, 0);
    report(r, r.sup.ended(now()));
}

fn report(r: *Renderer, outcome: lifecycle.Outcome) void {
    switch (outcome) {
        .expected => {},
        .restart_in_ms => |ms| std.log.warn("renderer {d}: restarting in {d} ms", .{ r.id, ms }),
        .gave_up => |n| std.log.err("renderer {d}: crashed {d} times in a row, each soon after starting; giving up (apply a wallpaper to try again)", .{ r.id, n }),
    }
}

/// A renderer's failure that means the file itself can't be a wallpaper
/// (not a video at all, a format nothing here reads), not a passing problem.
fn cantShow(message: []const u8) bool {
    return std.mem.startsWith(u8, message, "cannot play") or std.mem.startsWith(u8, message, "cannot show");
}

/// A wallpaper couldn't be played or shown (`Fallback`). Monitors that had it
/// as their own follow the main wallpaper again; if it was the main one, the
/// last wallpaper that played comes back (or zmural's own). A notification
/// says so: left alone, the desktop would stay empty. As on Linux.
fn goBackFromBroken() void {
    const broken = rt.fallback.take() orelse return;
    defer rt.gpa.free(broken);
    while (rt.own.showing(broken)) |m| if (setOwn(m, null) != .ok) break;
    const main = if (rt.wallpaper) |c| std.mem.eql(u8, c, broken) else false;
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
    std.log.info("{s}: {s}", .{ title, text });
    if (rt.tray) |*t| t.balloon(title, text);
}

/// Shows what to go back to instead of `broken` and returns it (valid until
/// the next change), or null when there is nothing else to show.
fn backFrom(broken: []const u8) ?[]const u8 {
    const own = if (starter_dir) |d| starter.path(rt.gpa, d) catch null else null;
    defer if (own) |p| rt.gpa.free(p);
    const back = rt.fallback.instead(broken, own) orelse return null;
    switchTo(back) catch {
        // Gone since it played: zmural's own, unless that is what failed.
        const p = own orelse return null;
        if (std.mem.eql(u8, p, broken) or std.mem.eql(u8, p, back)) return null;
        switchTo(p) catch return null;
    };
    return rt.wallpaper;
}

fn switchTo(path: []const u8) !void {
    try playable(path);
    try setWallpaper(path);
    save();
}

/// A crash left its code (`os/crashlog.zig`): tell the user, with the line to
/// pass on if they want to report it. One notice per run: a renderer crashing
/// over and over until zmural gives up would otherwise send one each time.
/// The latest line stays in `status` (and so the settings window) all run.
fn tellCrash(when: enum { last_run, renderer }) void {
    const dir = std.fs.path.dirname(zmural.os.logfile.path()) orelse return;
    var buf: [256]u8 = undefined;
    const code = zmural.os.crashlog.takeCode(rt.io, dir, &buf) orelse return;
    rt.crash_len = @min(code.len, rt.crash_buf.len);
    @memcpy(rt.crash_buf[0..rt.crash_len], code[0..rt.crash_len]);
    if (rt.crash_told) return std.log.warn("another crash this run (not told again): {s}", .{code});
    rt.crash_told = true;
    std.log.warn("told the user about a crash: {s}", .{code});
    var body: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&body, "{s} To report it, post this line (it is also in zmural's log):\n{s}", .{ switch (when) {
        .last_run => "zmural stopped unexpectedly last time.",
        .renderer => "Part of zmural stopped unexpectedly and was restarted.",
    }, code }) catch return;
    if (rt.tray) |*t| t.balloon("zmural ran into a problem", text);
}

/// Releases the process, reader thread and pipe. `grace_ms`: how long a
/// process that was asked to stop gets before it is killed. Safe to call twice.
fn reap(r: *Renderer, grace_ms: w.DWORD) void {
    if (r.child) |c| {
        if (grace_ms > 0) _ = w.WaitForSingleObject(c.process, grace_ms);
        if (!c.hasExited()) c.kill();
    }
    if (r.conn) |*c| {
        if (r.reader) |t| pipe.stopReader(c, t);
        r.reader = null;
        c.close();
    }
    r.conn = null;
    if (r.child) |c| {
        _ = w.WaitForSingleObject(c.process, 1_000);
        c.close();
        r.child = null;
    }
}

/// Stops a renderer the router no longer uses.
fn retire(id: RendererId) void {
    for (rt.renderers.items, 0..) |r, i| {
        if (r.id != id) continue;
        if (r.conn) |*c| c.send(proto.ToRenderer, .stop) catch {}; // zsnag:ok — reap() kills it after the grace period regardless
        reap(r, stop_grace_ms);
        _ = rt.renderers.swapRemove(i);
        destroyRenderer(r);
        return;
    }
}

fn destroyRenderer(r: *Renderer) void {
    rt.gpa.free(r.path);
    rt.gpa.destroy(r);
}

fn find(id: RendererId) ?*Renderer {
    for (rt.renderers.items) |r| if (r.id == id) return r;
    return null;
}

/// Routes the current wallpaper from scratch. What shows now stays until its
/// replacement shows its first frame (`Outgoing`), so a switch never lets the
/// desktop show through.
fn reroute() void {
    for (rt.renderers.items) |r| {
        if (isOutgoing(r.id)) continue;
        var mask: u32 = 0;
        for (rt.screen_ids[0..rt.screens.len], 0..) |id, i| {
            if (rt.router.rendererFor(id) == r.id) mask |= @as(u32, 1) << @intCast(i); // zsnag:ok — i < monitors.max (16)
        }
        // Not on any monitor: goes with the first replacement that shows.
        if (mask == 0) mask = std.math.maxInt(u32);
        rt.outgoing.append(rt.gpa, .{ .id = r.id, .mask = mask, .deadline = now() + outgoing_wait_ms }) catch {}; // zsnag:ok — the deadline sweep can't see it then; rerouteFresh or quit still stops it
    }
    resetRouter();
}

/// Stops every renderer first: for new monitors, where the old windows'
/// places mean nothing.
fn rerouteFresh() void {
    rt.outgoing.clearRetainingCapacity();
    while (rt.renderers.items.len > 0) retire(rt.renderers.items[0].id);
    resetRouter();
}

fn isOutgoing(id: RendererId) bool {
    for (rt.outgoing.items) |o| if (o.id == id) return true;
    return false;
}

fn resetRouter() void {
    rt.router.deinit(rt.gpa);
    // Keep counting: IDs must never repeat, or a retired renderer's last
    // queued message would be taken for its successor's.
    rt.router = .{ .share = rt.settings.share_renderers, .next_id = rt.router.next_id };
    applyWallpaper();
}

fn setWallpaper(path: []const u8) error{ OutOfMemory, BadPackage }!void {
    var pkg: ?Package = if (isPackage(path)) try loadPackage(path) else builtinProperties(path);
    errdefer if (pkg) |*k| k.deinit();
    const owned = try rt.gpa.dupe(u8, path);
    rt.fallback.retrying(rt.gpa, path);
    if (rt.wallpaper) |old| rt.gpa.free(old);
    rt.wallpaper = owned;
    if (rt.package) |*old| old.deinit();
    rt.package = pkg;
    rt.rotation.restart();
    std.log.info("wallpaper: {s}", .{owned});
    reroute();
    updateTray();
}

/// Carries out a lifecycle command.
fn execute(r: *Renderer, cmd: lifecycle.Command) void {
    switch (cmd) {
        .spawn => start(r),
        .terminate => {
            std.log.info("renderer {d}: stopped by a pause rule", .{r.id});
            if (r.conn) |*c| c.send(proto.ToRenderer, .stop) catch {}; // zsnag:ok — reap() kills it after the grace period regardless
            reap(r, stop_grace_ms);
        },
        .play => |p| {
            send(r, .{ .set_volume = .{ .volume = rt.settings.volume, .muted = rt.settings.muted or p.muted } });
            send(r, .play);
        },
        .pause => send(r, .pause),
    }
}

// ---- control requests ------------------------------------------------------------

fn handleRequest(req: control.Request) control.Event {
    switch (req) {
        .hello => return .ok, // answered by the server itself
        .status => {
            const h = heldNow();
            return .{
                .status = .{
                    .paused_by = h.paused_by,
                    .muted_by = h.muted_by,
                    .crash = rt.crash_buf[0..rt.crash_len],
                    .shown = rt.fallback.last_good orelse "",
                    .broken = rt.fallback.last_broken orelse "",
                    .broken_why = if (rt.fallback.last_broken != null) rt.fallback.message() else "",
                    .paused = rt.settings.paused,
                    .muted = rt.settings.muted,
                    .monitors = @intCast(rt.screens.len), // zsnag:ok — at most monitors.max
                    .wallpapers = @intCast(rt.library.count()), // zsnag:ok — far below u32 max
                    .wallpaper = rt.wallpaper orelse "",
                    .rotate_minutes = rt.settings.rotate_minutes,
                    .order = rt.settings.order,
                    .next_change_s = rt.rotation.remainingS(rt.settings.rotate_minutes),
                },
            };
        },
        .monitors => {
            var known_buf: [monitors.max]per_monitor.Known = undefined;
            return .{ .monitors = .{ .list = per_monitor.format(&reply_buf, knownMonitors(&known_buf), &rt.own, &rt.fills) } };
        },
        .apply => |a| {
            if (a.monitor.len != 0) {
                // An empty path: that monitor follows the main wallpaper again.
                var known_buf: [monitors.max]per_monitor.Known = undefined;
                const monitor = per_monitor.resolve(a.monitor, knownMonitors(&known_buf)) orelse per_monitor.parseId(a.monitor) orelse
                    return failed(.not_found, "no such monitor (`zmural-console status` lists them)");
                return setOwn(monitor, if (a.path.len > 0) a.path else null);
            }
            playable(a.path) catch |why| return failed(.not_found, whyNot(why));
            // One wallpaper everywhere: no monitor keeps its own.
            rt.own.clear(rt.gpa);
            setWallpaper(a.path) catch |err| return wallpaperFailed(err);
            save();
            return .ok;
        },
        .pause, .play => |t| {
            if (t.monitor.len != 0) return failed(.unsupported, "pausing one monitor isn't supported yet; leave out --monitor");
            rt.settings.paused = req == .pause;
            rt.paused_on_disk = null; // the user decided: that's what gets saved now
            evaluate();
            save();
            updateTray();
            return .ok;
        },
        .set_muted => |m| {
            rt.settings.muted = m.muted;
            pushVolume();
            save();
            updateTray();
            return .ok;
        },
        .next, .previous => |t| {
            const empty = "the library is empty (add wallpapers to Videos\\Wallpapers or Pictures\\Wallpapers)";
            if (t.monitor.len != 0) {
                // That monitor steps on from what it shows, and keeps the result as its own.
                var known_buf: [monitors.max]per_monitor.Known = undefined;
                const monitor = per_monitor.resolve(t.monitor, knownMonitors(&known_buf)) orelse
                    return failed(.not_found, "no such monitor (`zmural-console status` lists them)");
                var seed: u64 = undefined;
                rt.io.random(std.mem.asBytes(&seed));
                const next = rt.rotation.step(rt.gpa, &rt.library, rt.own.wallpaperFor(monitor, rt.wallpaper), rt.settings.order, req == .next, seed) orelse
                    return failed(.not_found, empty);
                return setOwn(monitor, next);
            }
            const path = stepWallpaper(req == .next) orelse
                return failed(.not_found, empty);
            setWallpaper(path) catch |err| return wallpaperFailed(err);
            save();
            return .ok;
        },
        .rescan => {
            rescan();
            return .ok;
        },
        .open_settings => {
            openSettings();
            return .ok;
        },
        .quit => {
            w.PostQuitMessage(0);
            return .ok;
        },
        .get_settings => return settingsInfo(),
        .library => |page| {
            const all = rt.library.paths.items;
            const p = lists.joinFrom(&reply_buf, all, page.offset);
            if (p.count == 0 and page.offset < all.len) return failed(.internal, "a library path is too long to send");
            return .{
                .library = .{
                    .total = @intCast(all.len), // zsnag:ok — a library never nears u32 max
                    .offset = page.offset,
                    .paths = p.text,
                },
            };
        },
        .set_fill => |f| {
            // Renderers take the fill mode at start, so a change reroutes.
            if (f.monitor.len != 0) {
                var known_buf: [monitors.max]per_monitor.Known = undefined;
                const monitor = per_monitor.resolve(f.monitor, knownMonitors(&known_buf)) orelse per_monitor.parseId(f.monitor) orelse
                    return failed(.not_found, "no such monitor (`zmural-console status` lists them)");
                if (f.main) {
                    if (!rt.fills.remove(monitor)) return .ok;
                } else if (!rt.fills.set(monitor, f.fill)) return failed(.bad_request, "too many monitors have their own fill mode");
                reroute();
            } else if (rt.settings.fill != f.fill) {
                rt.settings.fill = f.fill;
                reroute();
            }
            save();
            return .ok;
        },
        .set_volume => |v| {
            rt.settings.volume = @min(v.volume, 100);
            pushVolume();
            save();
            return .ok;
        },
        .set_rule => |s| {
            if (!settings_file.isExposed(s.condition)) return failed(.unsupported, "zmural can't detect that situation yet");
            var rule = rt.settings.policy.rules.get(s.condition);
            rule.action = s.action;
            rt.settings.policy.rules.set(s.condition, rule);
            evaluate();
            save();
            return .ok;
        },
        .set_resume_after => |s| {
            rt.settings.resume_after_ms = @min(s.ms, max_resume_after_ms);
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
            return .ok;
        },
        .get_properties => {
            const pkg = if (rt.package) |*k| k else return .{ .properties = .{ .title = "", .list = "" } };
            var out: std.Io.Writer = .fixed(&reply_buf);
            props.writeList(&out, pkg.m, pkg.values) catch return failed(.internal, "too many properties to send");
            return .{ .properties = .{ .title = pkg.m.title, .list = out.buffered() } };
        },
        .set_property => |sp| return setProperty(sp.name, sp.value),
        .reset_properties => {
            const pkg = if (rt.package) |*k| k else return failed(.unsupported, "this wallpaper has no properties");
            for (pkg.m.properties, pkg.values) |p, *v| v.* = p.default;
            saveValues(pkg);
            for (rt.renderers.items) |r| sendProperties(r);
            return .ok;
        },
        .reset_settings => {
            const d: Settings = .{};
            const refill = rt.settings.fill != d.fill;
            rt.settings.fill = d.fill;
            rt.settings.volume = d.volume;
            rt.settings.muted = d.muted;
            rt.settings.paused = d.paused;
            rt.paused_on_disk = null;
            rt.settings.policy = d.policy;
            rt.settings.resume_after_ms = d.resume_after_ms;
            rt.settings.rotate_minutes = d.rotate_minutes;
            rt.settings.order = d.order;
            rt.app_rules.deinit(rt.gpa);
            rt.settings.app_rules = &.{};
            if (refill) reroute() else pushVolume();
            evaluate();
            save();
            updateTray();
            std.log.info("settings: playback and pausing reset to defaults", .{});
            return .ok;
        },
    }
}

/// The longest resume delay the settings window offers, and the daemon accepts.
const max_resume_after_ms = 10_000;

/// Reply strings (lists, library pages) live here until the server has sent them.
var reply_buf: [60 * 1024]u8 = undefined;

fn settingsInfo() control.Event {
    var rules: control.RuleActions = undefined;
    var exposed: control.RuleExposed = undefined;
    for (std.enums.values(zmural.policy.Condition)) |c| {
        rules[@intFromEnum(c)] = rt.settings.policy.rules.get(c).action;
        exposed[@intFromEnum(c)] = settings_file.isExposed(c);
    }
    const third = reply_buf.len / 3;
    comptime std.debug.assert(third >= lists.max_joined_len); // lists are never cut short
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
        .file = if (rt.store) |s| s.path else "",
    } };
}

fn setList(l: control.SetList) control.Event {
    const check: *const fn ([]const u8) bool = switch (l.list) {
        .app_rules => &lists.isAppName,
        .library_dirs => &lists.isAbsoluteDir,
    };
    var owned = lists.Owned.parse(rt.gpa, l.items, check) catch |err| return failed(.bad_request, switch (err) {
        error.TooMany => "too many items (32 at most)",
        error.TooLong => "an item is too long",
        error.OutOfMemory => "out of memory",
        error.BadItem => switch (l.list) {
            .app_rules => "apps are named by their program file, like game.exe",
            .library_dirs => "folders need a full path, like D:\\Wallpapers",
        },
    });
    switch (l.list) {
        .app_rules => {
            rt.app_rules.deinit(rt.gpa);
            rt.app_rules = owned;
            rt.settings.app_rules = owned.items;
            evaluate();
        },
        .library_dirs => {
            setLibraryDirs(owned.items) catch {
                owned.deinit(rt.gpa);
                return failed(.internal, "out of memory");
            };
            rt.user_dirs.deinit(rt.gpa);
            rt.user_dirs = owned;
            rt.settings.library_dirs = owned.items;
            rescan();
        },
    }
    save();
    return .ok;
}

fn setProperty(name: []const u8, value: []const u8) control.Event {
    const pkg = if (rt.package) |*k| k else return failed(.unsupported, "this wallpaper has no properties");
    const i = for (pkg.m.properties, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) break i;
    } else return failed(.not_found, "this wallpaper has no property by that name");
    const p = pkg.m.properties[i];
    var v = props.coerce(p, value) catch return failed(.bad_request, switch (p.kind) {
        .slider => "that's not a number in this slider's range",
        .checkbox => "use true or false",
        .color => "colours look like #ff8800",
        .dropdown => "that isn't one of this property's choices",
        .text => "text can't have line breaks or be that long",
    });
    if (v == .text) v = .{ .text = pkg.arena.allocator().dupe(u8, v.text) catch return failed(.internal, "out of memory") };
    pkg.values[i] = v;
    saveValues(pkg);
    for (rt.renderers.items) |r| sendProperty(r, p.name, v);
    return .ok;
}

/// The error a client sees when a wallpaper can't be switched to.
fn wallpaperFailed(err: error{ OutOfMemory, BadPackage }) control.Event {
    return switch (err) {
        error.OutOfMemory => failed(.internal, "out of memory"),
        error.BadPackage => failed(.bad_request, "that wallpaper package can't be used; the log says why"),
    };
}

/// `library_dirs` = the standard folders, then `user`.
fn setLibraryDirs(user: []const []const u8) error{OutOfMemory}!void {
    const all = try setLibraryDirsFrom(user);
    rt.gpa.free(rt.library_dirs);
    rt.library_dirs = all;
}

/// The standard folders, then `user`, in a new slice.
fn setLibraryDirsFrom(user: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const all = try rt.gpa.alloc([]const u8, rt.default_dirs.len + user.len);
    @memcpy(all[0..rt.default_dirs.len], rt.default_dirs);
    @memcpy(all[rt.default_dirs.len..], user);
    return all;
}

/// Sends the volume and mute state to every running renderer.
fn pushVolume() void {
    for (rt.renderers.items) |r| {
        if (r.sup.state == .running) send(r, .{ .set_volume = .{ .volume = rt.settings.volume, .muted = rt.settings.muted or r.sup.applied == .mute } });
    }
}

/// A library scan running on a worker thread. It owns copies of everything it
/// reads, so the daemon may change its folders (or quit) meanwhile.
const ScanJob = struct {
    gen: u32,
    io: std.Io,
    hwnd: w.HWND,
    dirs: std.heap.ArenaAllocator,
    dir_list: []const []const u8,
    library: Library,

    fn run(job: *ScanJob) void {
        job.library.scan(job.io, job.dir_list);
        // Set before the daemon starts and never changed: safe to read here.
        if (starter_dir) |d| job.library.scanLast(job.io, d);
        if (w.PostMessageW(job.hwnd, WM_SCANNED, 0, @bitCast(@intFromPtr(job))) == 0) job.destroy();
    }

    fn destroy(job: *ScanJob) void {
        job.library.deinit();
        job.dirs.deinit();
        scan_alloc.destroy(job);
    }
};

/// Rescans the library folders in the background: a folder on an offline
/// network share can take the SMB timeout to fail, and the daemon must keep
/// answering meanwhile. The current library stays in use until it's done.
fn rescan() void {
    rt.scan_gen +%= 1;
    startScan() catch |err| std.log.err("library: cannot start a scan: {s}", .{@errorName(err)});
}

fn startScan() !void {
    const job = try scan_alloc.create(ScanJob);
    job.* = .{ .gen = rt.scan_gen, .io = rt.io, .hwnd = rt.control.?, .dirs = .init(scan_alloc), .dir_list = &.{}, .library = .init(scan_alloc) };
    errdefer job.destroy();
    const a = job.dirs.allocator();
    const list = try a.alloc([]const u8, rt.library_dirs.len);
    for (list, rt.library_dirs) |*d, src| d.* = try a.dupe(u8, src);
    job.dir_list = list;
    const thread = try std.Thread.spawn(.{}, ScanJob.run, .{job});
    thread.detach();
}

fn onScanned(job: *ScanJob) void {
    defer job.destroy();
    if (job.gen != rt.scan_gen) return; // a newer scan is on its way
    std.mem.swap(Library, &rt.library, &job.library);
    rt.rotation.forget(rt.gpa);
    std.log.info("library: {d} wallpapers in {d} folders", .{ rt.library.count(), job.dir_list.len });
}

/// The tray tooltip: what's showing, and whether it's paused or muted.
fn updateTray() void {
    const tray = if (rt.tray) |*t| t else return;
    var buf: [128]u8 = undefined;
    const name = if (rt.wallpaper) |p| zmural.media.displayName(p) else "no wallpaper";
    const tip = std.fmt.bufPrint(&buf, "zmural: {s}{s}{s}", .{
        name,
        if (rt.settings.paused) " (paused)" else "",
        if (rt.settings.muted) " (muted)" else "",
    }) catch "zmural";
    tray.setTip(tip);
}

fn onTray(lp: w.LPARAM) void {
    switch (Tray.wants(lp)) {
        .nothing => return,
        .window => return openSettings(),
        .menu => {},
    }
    const tray = if (rt.tray) |*t| t else return;
    const item = tray.menu(.{
        .title = if (rt.wallpaper) |p| zmural.media.displayName(p) else "",
        .paused = rt.settings.paused,
        .muted = rt.settings.muted,
        .shuffled = rt.settings.order != .sequential,
        .library_count = rt.library.count(),
        .autostart = autostartOn(),
    }) orelse return;
    switch (item) {
        .open_settings => return openSettings(),
        .open_log => return openInNotepad(zmural.os.logfile.path()),
        .start_with_windows => return toggleAutostart(),
        else => {},
    }
    const req = item.request(.{ .paused = rt.settings.paused, .muted = rt.settings.muted, .shuffled = rt.settings.order != .sequential }) orelse return;
    switch (handleRequest(req)) {
        .failed => |f| std.log.warn("tray: {s}", .{f.message}),
        else => {},
    }
    updateTray();
}

/// The settings window: a thread of this process (`settings.window`), with
/// its own message loop. An open one is brought to the front.
fn openSettings() void {
    settings_window.open(settings_env, "");
    // Welcome is for the first opening only.
    settings_env.welcome = false;
}

fn openInNotepad(path: []const u8) void {
    if (path.len == 0) return;
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(rt.gpa, path) catch return;
    defer rt.gpa.free(path_w);
    _ = w.ShellExecuteW(null, w.L("open"), w.L("notepad.exe"), path_w, null, w.SW_SHOWNORMAL);
}

fn autostartOn() bool {
    var buf: [2048]u8 = undefined;
    return zmural.os.autostart.status(&buf) != null;
}

/// Start with Windows is on by default, as on Linux: the first run turns it
/// on. A user who turned it off (here, or in Windows' own Startup apps) is
/// left alone; an entry pointing at a moved zmural is fixed.
fn setUpAutostart() void {
    const reg = zmural.os.autostart;
    const exe = process.siblingExe(rt.gpa, "zmural.exe") catch return;
    defer rt.gpa.free(exe);
    switch (reg.state()) {
        .off => std.log.info("autostart: off", .{}),
        .on => {
            var buf: [2048]u8 = undefined;
            const cmd = reg.command(&buf) orelse return;
            if (cmd.len == exe.len + 2 and std.mem.eql(u8, cmd[1 .. cmd.len - 1], exe)) return;
            reg.enable(exe) catch |err| return std.log.warn("autostart not updated: {s}", .{@errorName(err)});
            std.log.info("autostart now runs {s}", .{exe});
        },
        .unset => {
            reg.enable(exe) catch |err| return std.log.warn("autostart not set up: {s}", .{@errorName(err)});
            std.log.info("autostart: on ({s})", .{exe});
            if (rt.tray) |*t| t.balloon("zmural will start with Windows", "To turn that off: Start with Windows in the tray menu, or zmural-console autostart off.");
        },
    }
}

fn toggleAutostart() void {
    const reg = zmural.os.autostart;
    if (autostartOn()) {
        reg.disable() catch |err| return std.log.warn("autostart: {s}", .{@errorName(err)});
        std.log.info("autostart: off", .{});
        return;
    }
    const exe = process.siblingExe(rt.gpa, "zmural.exe") catch return;
    defer rt.gpa.free(exe);
    reg.enable(exe) catch |err| return std.log.warn("autostart: {s}", .{@errorName(err)});
    std.log.info("autostart: on ({s})", .{exe});
}

/// Persists the settings, with whatever is showing now as the startup wallpaper.
fn save() void {
    const store = rt.store orelse return;
    var s = persistent(rt.settings, rt.wallpaper, rt.startup_wallpaper, rt.paused_on_disk);
    var view: [per_monitor.max]@import("settings.zig").MonitorWallpaper = undefined;
    s.monitor_wallpapers = rt.own.view(&view);
    s.monitor_fills = rt.fills.view();
    store.save(rt.gpa, &s);
    rt.file_stamp = stampOf(store);
}

/// What goes into settings.toml: the live settings, minus what only holds for
/// this run. With nothing showing (the startup wallpaper is missing for now),
/// the startup wallpaper is kept rather than erased.
fn persistent(s: Settings, showing: ?[]const u8, startup: []const u8, paused_on_disk: ?bool) Settings {
    var out = s;
    out.wallpaper = showing orelse startup;
    if (paused_on_disk) |p| out.paused = p;
    return out;
}

// ---- packages -------------------------------------------------------------------

fn isPackage(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.basename(path), manifest.file_name);
}

/// What renderers open: a package's entry file, or the wallpaper itself.
fn renderPath() []const u8 {
    if (rt.package) |pkg| return pkg.entry;
    return rt.wallpaper.?;
}

fn currentKind() Kind {
    if (rt.package) |pkg| return switch (pkg.m.kind) {
        .video => .video,
        .image => .image,
        .web => .web,
    };
    return Kind.forPath(rt.wallpaper.?);
}

/// What this renderer opens.
fn renderPathFor(r: *const Renderer) []const u8 {
    return if (r.main) renderPath() else r.path;
}

/// The connected monitors, in the order Windows lists them.
fn knownMonitors(out: *[monitors.max]per_monitor.Known) []const per_monitor.Known {
    for (rt.screens.slice(), 0..) |m, i| {
        out[i] = .{ .id = rt.screen_ids[i], .name = rt.screen_names[i][0..rt.screen_name_lens[i]], .width = m.rect.w, .height = m.rect.h };
    }
    return out[0..rt.screens.len];
}

/// Gives one monitor its own wallpaper, or (`path` null) has it follow the
/// main one again.
fn setOwn(monitor: MonitorId, path: ?[]const u8) control.Event {
    if (path) |p| {
        playable(p) catch |why| return failed(.not_found, whyNot(why));
        if (isPackage(p)) return failed(.unsupported, "a wallpaper package can only be the main wallpaper for now; leave out --monitor");
        rt.own.set(rt.gpa, monitor, p) catch |err| return switch (err) {
            error.OutOfMemory => failed(.internal, "out of memory"),
            error.TooMany => failed(.bad_request, "too many monitors have their own wallpaper"),
        };
        std.log.info("monitor {s}: wallpaper: {s}", .{ &monitor, p });
    } else if (rt.own.remove(rt.gpa, monitor)) {
        std.log.info("monitor {s}: follows the main wallpaper again", .{&monitor});
    } else return .ok;
    reroute();
    save();
    return .ok;
}

/// A plain video or picture gets the built-in adjustments as its properties
/// (`adjust.zig`), in the same shape as a package's. Null for anything else,
/// or when memory runs out: the wallpaper then simply has no properties.
fn builtinProperties(path: []const u8) ?Package {
    // Drawn by the renderer itself: nothing to adjust.
    if (std.mem.eql(u8, path, zmural.sdk.windows_renderer.test_pattern_path)) return null;
    const set = (adjust.load(rt.gpa, rt.io, if (rt.store) |st| st.dir else null, path, Kind.forPath(path)) catch return null) orelse return null;
    var pkg: Package = .{ .arena = set.arena, .m = set.m, .entry = "", .values = set.values, .values_file = set.values_file };
    pkg.entry = pkg.arena.allocator().dupe(u8, path) catch {
        pkg.deinit();
        return null;
    };
    return pkg;
}

/// Reads a package (`<folder>\zmural.toml`) and the user's values for it.
/// Packages come from anywhere: every problem is logged and refused.
fn loadPackage(path: []const u8) error{ OutOfMemory, BadPackage }!Package {
    var pkg: Package = .{ .arena = .init(rt.gpa), .m = undefined, .entry = "", .values = &.{}, .values_file = "" };
    errdefer pkg.arena.deinit();
    const a = pkg.arena.allocator();
    const text = std.Io.Dir.cwd().readFileAlloc(rt.io, path, a, .limited(256 * 1024)) catch |err| {
        std.log.err("package {s}: can't read it: {s}", .{ path, @errorName(err) });
        return error.BadPackage;
    };
    var diag: manifest.Diagnostic = .{};
    pkg.m = manifest.parse(a, text, &diag) catch |err| {
        std.log.err("package {s}: line {d}: {s}", .{ path, diag.line, @errorName(err) });
        return error.BadPackage;
    };
    const folder = std.fs.path.dirname(path) orelse return error.BadPackage;
    pkg.entry = try manifest.entryPath(a, folder, pkg.m.entry);
    playable(pkg.entry) catch |why| {
        std.log.err("package {s}: its entry '{s}': {s}", .{ path, pkg.m.entry, whyNot(why) });
        return error.BadPackage;
    };
    if (Kind.forPath(pkg.entry) == .web and pkg.m.kind != .web) {
        std.log.err("package {s}: a web page entry needs type = \"web\"", .{path});
        return error.BadPackage;
    }

    pkg.values = try a.alloc(manifest.Value, pkg.m.properties.len);
    var stored: []const props.Stored = &.{};
    if (rt.store) |store| {
        var hasher = std.hash.Wyhash.init(0);
        for (path) |c| hasher.update(&.{std.ascii.toLower(c)});
        pkg.values_file = try std.fmt.allocPrint(a, "{s}\\properties\\{x:0>16}.toml", .{ store.dir, hasher.final() });
        if (std.Io.Dir.cwd().readFileAlloc(rt.io, pkg.values_file, a, .limited(256 * 1024))) |saved| {
            stored = props.parseStored(a, pkg.m, saved) catch &.{};
        } else |_| {}
    }
    props.current(pkg.m, stored, pkg.values);
    std.log.info("package '{s}' ({s}, {d} properties)", .{ pkg.m.title, @tagName(pkg.m.kind), pkg.m.properties.len });
    if (pkg.m.asks_network) std.log.warn("package {s}: `network = true` is ignored; web wallpapers are always offline", .{path});
    return pkg;
}

/// Writes the package's values file (only values that differ from the default).
fn saveValues(pkg: *const Package) void {
    if (pkg.values_file.len == 0) return;
    var out: std.Io.Writer.Allocating = .init(rt.gpa);
    defer out.deinit();
    props.writeStored(&out.writer, pkg.m, pkg.values) catch return;
    const cwd = std.Io.Dir.cwd();
    const dir = std.fs.path.dirname(pkg.values_file) orelse return;
    cwd.createDirPath(rt.io, dir) catch |err| return std.log.warn("properties: can't create {s}: {s}", .{ dir, @errorName(err) });
    const tmp = std.fmt.allocPrint(rt.gpa, "{s}.tmp", .{pkg.values_file}) catch return;
    defer rt.gpa.free(tmp);
    cwd.writeFile(rt.io, .{ .sub_path = tmp, .data = out.written() }) catch |err| return std.log.warn("properties: can't save: {s}", .{@errorName(err)});
    cwd.rename(tmp, cwd, pkg.values_file, rt.io) catch |err| std.log.warn("properties: can't save: {s}", .{@errorName(err)});
}

// ---- settings.toml edits ---------------------------------------------------------

/// Enough to notice that someone else wrote the file.
const FileStamp = struct {
    mtime_ns: i96,
    size: u64,
};

fn stampOf(store: SettingsStore) ?FileStamp {
    const st = std.Io.Dir.cwd().statFile(store.io, store.path, .{}) catch return null;
    return .{ .mtime_ns = st.mtime.nanoseconds, .size = st.size };
}

/// Picks up hand edits to settings.toml while zmural runs, so the next save
/// doesn't overwrite them.
fn checkFile() void {
    const store = if (rt.store) |*s| s else return;
    const stamp = stampOf(store.*) orelse return; // deleted: the next save recreates it
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
    if (was_read_only) std.log.info("settings: {s} reads fine again", .{store.path});

    const old = rt.settings;
    var s = loaded;
    // Not in the file: keep the running values.
    s.share_renderers = old.share_renderers;
    s.fps_cap = old.fps_cap;
    const library_changed = !sameList(old.library_dirs, s.library_dirs);
    const new_dirs = setLibraryDirsFrom(s.library_dirs) catch {
        arena.deinit();
        return std.log.err("settings: out of memory reloading {s}", .{store.path});
    };
    rt.gpa.free(rt.library_dirs);
    rt.library_dirs = new_dirs;

    // The file now owns every string: drop the old owners.
    rt.settings = s;
    rt.startup_wallpaper = s.wallpaper;
    rt.paused_on_disk = null;
    rt.app_rules.deinit(rt.gpa);
    rt.user_dirs.deinit(rt.gpa);
    if (rt.file_arena) |*a| a.deinit();
    rt.file_arena = arena;
    std.log.info("settings: reloaded {s} after an outside edit", .{store.path});

    // Which monitors have their own wallpaper, as the file has it now. The
    // router borrows these paths: everything below ends in a reroute if they changed.
    var view: [per_monitor.max]@import("settings.zig").MonitorWallpaper = undefined;
    const old_own = rt.own.view(&view);
    var own_changed = old_own.len != s.monitor_wallpapers.len;
    if (!own_changed) for (old_own, s.monitor_wallpapers) |a, b| {
        if (!std.mem.eql(u8, a.monitor, b.monitor) or !std.ascii.eqlIgnoreCase(a.wallpaper, b.wallpaper)) own_changed = true;
    };
    if (own_changed) rt.own.load(rt.gpa, s.monitor_wallpapers);
    if (!rt.fills.same(s.monitor_fills)) {
        rt.fills.load(s.monitor_fills);
        own_changed = true; // either way: reroute
    }

    const showing = rt.wallpaper orelse "";
    const new_wallpaper = s.wallpaper.len > 0 and !std.ascii.eqlIgnoreCase(s.wallpaper, showing);
    var rerouted = false;
    if (new_wallpaper) {
        if (playable(s.wallpaper)) |_| {
            if (setWallpaper(s.wallpaper)) |_| {
                rerouted = true;
            } else |err| std.log.err("settings: can't show '{s}': {s}", .{ s.wallpaper, @errorName(err) });
        } else |why| std.log.warn("settings: not showing '{s}': {s}", .{ s.wallpaper, whyNot(why) });
    }
    if (!rerouted and (own_changed or old.fill != s.fill)) reroute() else pushVolume();
    if (library_changed) rescan();
    evaluate();
    updateTray();
}

fn sameList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.ascii.eqlIgnoreCase(x, y)) return false;
    return true;
}

fn failed(code: control.ErrorCode, message: []const u8) control.Event {
    return .{ .failed = .{ .code = code, .message = message } };
}

/// Can this path be shown? Returns why not, for the user.
/// - Only regular files (or the built-in test pattern); folders are refused.
/// - Web addresses (`http://`, `https://`) are refused: a wallpaper is a file
///   on this computer, and web pages run offline.
/// - Device and raw NT paths (`\\.\`, `\\?\`, `\??\`) are refused: they can
///   name pipes and devices, not just files.
/// - Network (UNC) paths skip the existence check: an unreachable server
///   would block this thread for the SMB timeout. A missing file then shows
///   up as a renderer failure instead.
fn playable(path: []const u8) Unplayable!void {
    if (std.mem.eql(u8, path, zmural.sdk.windows_renderer.test_pattern_path)) return;
    if (web_renderer.isUrl(path)) return error.WebAddress;
    if (isDevicePath(path)) return error.BadPath;
    if (path.len >= 2 and isSlash(path[0]) and isSlash(path[1])) return;
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(rt.gpa, path) catch return error.BadPath;
    defer rt.gpa.free(path_w);
    const attrs = w.GetFileAttributesW(path_w);
    if (attrs == w.INVALID_FILE_ATTRIBUTES) return error.NoSuchFile;
    if (attrs & w.FILE_ATTRIBUTE_DIRECTORY != 0) return error.IsAFolder;
}

fn isSlash(c: u8) bool {
    return c == '\\' or c == '/';
}

/// `\\.\…` and `\\?\…` (either slash), or the NT object prefix `\??\`.
fn isDevicePath(path: []const u8) bool {
    if (path.len < 4) return false;
    if (isSlash(path[0]) and isSlash(path[1]) and (path[2] == '.' or path[2] == '?') and isSlash(path[3])) return true;
    return path[0] == '\\' and path[1] == '?' and path[2] == '?' and path[3] == '\\';
}

const Unplayable = error{ NoSuchFile, IsAFolder, BadPath, WebAddress };

fn whyNot(err: Unplayable) []const u8 {
    return switch (err) {
        error.NoSuchFile => "no such file",
        error.IsAFolder => "that's a folder; pick a video, image, GIF or web page",
        error.BadPath => "that path can't be used",
        error.WebAddress => kind_mod.no_web_addresses,
    };
}

// ---- protocol ----------------------------------------------------------------

fn onRenderer(r: *Renderer, msg: proto.FromRenderer) void {
    // The first thing on the pipe must come from the process we spawned.
    if (!r.verified) {
        const expected = if (r.child) |c| c.pid else 0;
        const got = if (r.conn) |*c| c.peerProcessId() else null;
        if (got == null or got.? != expected) {
            std.log.err("renderer {d}: pipe client is pid {?d}, expected {d}; dropping it", .{ r.id, got, expected });
            if (r.conn) |*c| c.shutdown();
            return;
        }
        r.verified = true;
    }
    switch (msg) {
        .ready => |ready| {
            if (ready.version != proto.version) {
                std.log.err("renderer {d}: protocol v{d}, expected v{d}", .{ r.id, ready.version, proto.version });
                if (r.child) |c| c.kill();
                return;
            }
            std.log.info("renderer {d}: ready ({s})", .{ r.id, ready.capabilities });
            send(r, .{ .init = .{
                .version = proto.version,
                .path = renderPathFor(r),
                .fill = r.fill,
                .fps_cap = rt.settings.fps_cap,
                .volume = rt.settings.volume,
                .muted = rt.settings.muted,
            } });
            sendProperties(r);
            addSurfaces(r);
            // Start in whatever state the policy wants right now.
            execute(r, r.sup.ready());
        },
        .window => |win| {
            if (win.surface >= rt.screens.len) return;
            // Only onto a monitor this renderer feeds.
            if (rt.router.rendererFor(rt.screen_ids[win.surface]) != r.id) {
                std.log.err("renderer {d}: reported a window for monitor {d}, which it doesn't feed; ignoring it", .{ r.id, win.surface });
                return;
            }
            const raw = std.math.cast(usize, win.handle) orelse 0;
            if (raw == 0) {
                std.log.err("renderer {d}: reported an invalid window handle; ignoring it", .{r.id});
                return;
            }
            const hwnd: w.HWND = @ptrFromInt(raw); // zsnag:ok — non-zero; ownership checked below before use
            // Only ever reparent a window that belongs to this renderer.
            var owner: w.DWORD = 0;
            _ = w.GetWindowThreadProcessId(hwnd, &owner);
            const child_pid = if (r.child) |c| c.pid else 0;
            if (owner == 0 or owner != child_pid) {
                std.log.err("renderer {d}: reported a window owned by pid {d}; ignoring it", .{ r.id, owner });
                return;
            }
            const host = rt.host orelse return;
            host.attach(hwnd, rt.screens.items[win.surface].rect) catch |err| {
                std.log.err("renderer {d}: surface {d}: attach failed: {s}", .{ r.id, win.surface, @errorName(err) });
                return;
            };
            r.windows[win.surface] = hwnd;
            // Beneath the wallpaper it replaces, which stays until this one shows.
            if (outgoingWindow(win.surface)) |above|
                _ = w.SetWindowPos(hwnd, above, 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
        },
        .shown => |s| {
            if (s.surface >= rt.screens.len) return;
            if (rt.router.rendererFor(rt.screen_ids[s.surface]) != r.id) return;
            retireOutgoing(@as(u32, 1) << @intCast(s.surface), true); // zsnag:ok — surface < screens.len <= monitors.max (16)
            // The main wallpaper reached the screen: the one to go back to.
            if (rt.wallpaper) |c| if (std.mem.eql(u8, c, r.path)) rt.fallback.played(rt.gpa, r.path);
        },
        .log => |l| {
            var buf: [max_log_text]u8 = undefined;
            std.log.info("[{s} {d}] {s}: {s}", .{ @tagName(r.kind), r.id, @tagName(l.level), logSafe(&buf, l.text) });
        },
        .failed => |f| {
            var buf: [max_log_text]u8 = undefined;
            std.log.err("renderer {d}: {s}", .{ r.id, logSafe(&buf, f.message) });
            // Dealt with on the next tick, outside this renderer's message.
            if (cantShow(f.message)) rt.fallback.failed(rt.gpa, r.path, logSafe(&buf, f.message));
        },
        .frame_ready, .buffers, .decoder => {}, // Linux only
    }
}

/// Longest renderer text that goes into the log.
const max_log_text = 512;

/// A renderer's text, fit for one log line: control characters (a newline
/// could forge a whole log line) become '?', and it is cut to `buf`'s size.
fn logSafe(buf: []u8, text: []const u8) []const u8 {
    const n = @min(buf.len, text.len);
    for (text[0..n], buf[0..n]) |c, *o| o.* = if (c < 0x20 or c == 0x7f) '?' else c;
    return buf[0..n];
}

fn sendProperties(r: *Renderer) void {
    if (!r.main) return; // the package belongs to the main wallpaper
    const pkg = if (rt.package) |*k| k else return;
    for (pkg.m.properties, pkg.values) |p, v| sendProperty(r, p.name, v);
}

fn sendProperty(r: *Renderer, name: []const u8, v: manifest.Value) void {
    if (r.sup.state != .running and r.sup.state != .starting) return;
    var out: std.Io.Writer.Allocating = .init(rt.gpa);
    defer out.deinit();
    props.writeJson(&out.writer, v) catch return;
    send(r, .{ .set_property = .{ .name = name, .json = out.written() } });
}

/// One surface per monitor this renderer feeds; the surface ID is the monitor index.
fn addSurfaces(r: *Renderer) void {
    for (rt.screen_ids[0..rt.screens.len], 0..) |id, i| {
        if (rt.router.rendererFor(id) != r.id) continue;
        const rect = rt.screens.items[i].rect;
        send(r, .{ .add_surface = .{ .surface = @intCast(i), .width = rect.w, .height = rect.h } }); // zsnag:ok — i < monitors.max
    }
}

fn send(r: *Renderer, msg: proto.ToRenderer) void {
    const c = if (r.conn) |*c| c else return;
    c.send(proto.ToRenderer, msg) catch |err| {
        std.log.warn("renderer {d}: send failed ({s}); killing it", .{ r.id, @errorName(err) });
        if (r.child) |ch| ch.kill();
    };
}

// ---- recovery ----------------------------------------------------------------

fn scheduleReattach() void {
    _ = w.SetTimer(rt.control, timer_reattach, reattach_delay_ms, null);
}

fn reattach() void {
    attachHost();
    if (rt.host == null) return; // attachHost scheduled another try
    if (refreshScreens()) {
        // Different monitors: re-route from scratch.
        std.log.info("monitors changed; re-routing", .{});
        rerouteFresh();
        return;
    }
    // Same monitors: have every running renderer recreate its windows, which
    // Explorer may have destroyed along with the old desktop layer.
    for (rt.renderers.items) |r| {
        if (r.sup.state != .running) continue;
        for (rt.screen_ids[0..rt.screens.len], 0..) |id, i| {
            if (rt.router.rendererFor(id) != r.id) continue;
            send(r, .{ .remove_surface = .{ .surface = @intCast(i) } }); // zsnag:ok — i < monitors.max
        }
        addSurfaces(r);
    }
}

fn tick() void {
    const t = now();
    if (rt.outgoing.items.len > 0) retireOutgoing(std.math.maxInt(u32), false);
    for (rt.renderers.items) |r| {
        const before = r.sup.applied;
        if (r.sup.tick(t)) |cmd| {
            if (r.sup.applied != before) std.log.info("renderer {d}: {s} -> {s}", .{ r.id, @tagName(before), @tagName(r.sup.applied) });
            execute(r, cmd);
        }
    }
    if (rt.server) |*s| s.tick(t);
    rt.ticks +%= 1;
    if (rt.ticks % facts_backstop_ticks == 0) evaluate();
    if (rt.ticks % file_check_ticks == 0) checkFile();
    if (rt.ticks % startup_retry_ticks == 0) retryStartupWallpaper();
    goBackFromBroken();
    rotate(t);
}

/// The wallpaper after (or before) the current one, in the order the user chose.
fn stepWallpaper(forward: bool) ?[]const u8 {
    var seed: u64 = undefined;
    rt.io.random(std.mem.asBytes(&seed));
    return rt.rotation.step(rt.gpa, &rt.library, rt.wallpaper, rt.settings.order, forward, seed);
}

/// Is any wallpaper playing (the rotation clock only runs then)?
fn playing() bool {
    if (rt.settings.paused) return false;
    for (rt.renderers.items) |r| {
        if (r.sup.state == .running and @intFromEnum(r.sup.applied) <= @intFromEnum(zmural.policy.Action.mute)) return true;
    }
    return false;
}

/// Timed changes.
fn rotate(t: u64) void {
    if (!rt.rotation.due(t, rt.settings.rotate_minutes, playing())) return;
    const path = stepWallpaper(true) orelse return;
    if (rt.wallpaper) |cur| if (std.ascii.eqlIgnoreCase(cur, path)) return; // a library of one
    std.log.info("rotation: {d} minutes are up", .{rt.settings.rotate_minutes});
    setWallpaper(path) catch |err| return std.log.warn("rotation: {s}", .{@errorName(err)});
    save();
}

/// Shows the startup wallpaper once it turns up (a drive plugged in late).
fn retryStartupWallpaper() void {
    if (rt.wallpaper != null or rt.startup_wallpaper.len == 0) return;
    playable(rt.startup_wallpaper) catch return;
    std.log.info("startup wallpaper '{s}' is available now", .{rt.startup_wallpaper});
    setWallpaper(rt.startup_wallpaper) catch |err| std.log.err("startup wallpaper: {s}", .{@errorName(err)});
}

// ---- smart pausing -------------------------------------------------------------------

fn scheduleFacts() void {
    if (rt.facts_pending) return;
    rt.facts_pending = true;
    _ = w.SetTimer(rt.control, timer_facts, facts_coalesce_ms, null);
}

/// Re-reads what's on screen and brings every renderer in line with the policy.
fn evaluate() void {
    var screens: [monitors.max]zmural.layout.Rect = undefined;
    for (rt.screens.slice(), 0..) |m, i| screens[i] = m.rect;

    const snap = facts.collect(screens[0..rt.screens.len], w.GetCurrentProcessId(), rt.locked, rt.settings.app_rules);
    const changed = !snap.eql(&rt.snapshot);
    rt.snapshot = snap;
    if (changed) logSnapshot();

    const t = now();
    for (rt.renderers.items) |r| {
        const before = r.sup.applied;
        if (r.sup.desire(t, desiredFor(r), rt.settings.resume_after_ms)) |cmd| {
            std.log.info("renderer {d}: {s} -> {s}", .{ r.id, @tagName(before), @tagName(r.sup.applied) });
            execute(r, cmd);
        }
    }
}

var held_buf: [512]u8 = undefined;

/// The rules acting now, for `status`.
fn heldNow() desire.Held {
    var active = rt.snapshot.system;
    for (rt.snapshot.monitors[0..@min(rt.snapshot.count, rt.screens.len)]) |c| active.setUnion(c);
    return desire.held(&held_buf, &rt.settings.policy, active);
}

/// What the pause policy wants from this renderer (`desire.zig`, shared with Linux).
fn desiredFor(r: *const Renderer) Action {
    const n = @min(rt.snapshot.count, rt.screens.len);
    return desire.forRenderer(&rt.settings.policy, rt.snapshot.system, rt.screen_ids[0..n], rt.snapshot.monitors[0..n], &rt.router, r.id, rt.settings.paused);
}

fn logSnapshot() void {
    const s = &rt.snapshot;
    var buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    writeSnapshot(&out, s) catch {}; // zsnag:ok — a truncated log line is fine
    std.log.info("{s}", .{out.buffered()});
}

fn writeSnapshot(out: *std.Io.Writer, s: *const facts.Snapshot) std.Io.Writer.Error!void {
    try out.writeAll("screen:");
    for (s.monitors[0..s.count], 0..) |m, i| {
        try out.print(" monitor {d} [", .{i});
        try writeConditions(out, m);
        try out.writeAll("]");
    }
    try out.writeAll(" system [");
    try writeConditions(out, s.system);
    try out.print("] foreground {s}", .{s.foregroundExe()});
}

fn writeConditions(out: *std.Io.Writer, set: Conditions) std.Io.Writer.Error!void {
    var it = set.iterator();
    var first = true;
    while (it.next()) |c| {
        try out.print("{s}{s}", .{ if (first) "" else " ", @tagName(c) });
        first = false;
    }
}

fn onWindowEvent(_: w.HWINEVENTHOOK, event: w.DWORD, hwnd: ?w.HWND, id_object: i32, id_child: i32, _: w.DWORD, _: w.DWORD) callconv(.winapi) void {
    if (facts.isRelevant(event, hwnd, id_object, id_child)) scheduleFacts();
}

// ---- window procedures -----------------------------------------------------------

fn onRendererNotice(wp: w.WPARAM, lp: w.LPARAM) void {
    const notice = pipe.Notice.fromLparam(lp);
    defer if (notice == .frame) notice.frame.destroy();
    const r = find(@intCast(wp)) orelse return; // zsnag:ok — we posted a RendererId
    switch (notice) {
        .connected => {},
        .ended => {
            if (rt.quitting) return;
            // The reader thread ended: the renderer exited, crashed, never
            // connected, or was stopped on purpose (which the supervisor expects).
            const live = r.sup.state == .starting or r.sup.state == .running;
            if (live) {
                std.log.warn("renderer {d}: connection ended", .{r.id});
                reap(r, 0);
            }
            report(r, r.sup.ended(now()));
            if (live) tellCrash(.renderer);
        },
        .frame => |in| {
            const m = in.frame().decode(proto.FromRenderer) catch |err| {
                std.log.warn("renderer {d}: unreadable message (opcode {d}): {s}", .{ r.id, in.opcode, @errorName(err) });
                return;
            };
            onRenderer(r, m);
        },
    }
}

fn controlProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    if (rt.shut_down) return afterShutdown(hwnd, msg, wp, lp);
    if (msg == rt.taskbar_created and rt.taskbar_created != 0) {
        // The tray icon, every time: the desktop's own re-attach (on "desktop
        // layer destroyed") usually got here first and already knows the new
        // Explorer, so the check below says nothing about the taskbar.
        if (rt.tray) |*t| {
            t.restore();
            updateTray();
        }
        // Also broadcast on DPI changes; only a new Explorer needs a re-attach.
        const pid = hosts.windows.workerw.explorerPid();
        const current = if (rt.host) |h| h.explorer_pid else 0;
        if (pid != current or rt.host == null or !rt.host.?.isValid()) {
            std.log.info("explorer restarted (pid {d}); re-attaching", .{pid});
            scheduleReattach();
        }
        return 0;
    }
    switch (msg) {
        WM_RENDERER => {
            onRendererNotice(wp, lp);
            return 0;
        },
        WM_CONTROL => {
            if (rt.server) |*s| s.onMessage(now(), wp, lp, handleRequest);
            return 0;
        },
        WM_TRAY => {
            onTray(lp);
            return 0;
        },
        WM_SCANNED => {
            onScanned(@ptrFromInt(@as(usize, @bitCast(lp)))); // zsnag:ok — ScanJob.run posted its own pointer
            return 0;
        },
        WM_LAYER_GONE => {
            std.log.info("desktop layer destroyed; re-attaching", .{});
            scheduleReattach();
            return 0;
        },
        w.WM_TIMER => {
            if (wp == timer_facts) {
                _ = w.KillTimer(hwnd, timer_facts);
                rt.facts_pending = false;
                evaluate();
            } else if (wp == timer_tick) tick() else if (wp == timer_reattach) {
                _ = w.KillTimer(hwnd, timer_reattach);
                reattach();
            }
            return 0;
        },
        w.WM_DISPLAYCHANGE => {
            scheduleReattach();
            return 0;
        },
        w.WM_WTSSESSION_CHANGE => {
            if (wp == w.WTS_SESSION_LOCK) rt.locked = true;
            if (wp == w.WTS_SESSION_UNLOCK) rt.locked = false;
            scheduleFacts();
            return 0;
        },
        w.WM_POWERBROADCAST => {
            scheduleFacts();
            return 1;
        },
        // Logoff or shutdown: a GUI process gets these, not console events.
        // Clean up now; the process may be ended right after WM_ENDSESSION returns.
        w.WM_QUERYENDSESSION => return 1,
        w.WM_ENDSESSION => {
            if (wp != 0) {
                shutdown();
                w.PostQuitMessage(0);
            }
            return 0;
        },
        w.WM_CLOSE => {
            w.PostQuitMessage(0);
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// After `shutdown` (a logoff can run it from WM_ENDSESSION, with the loop
/// still going) everything the handlers use is gone: messages still queued
/// only have their payloads freed.
fn afterShutdown(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) w.LRESULT {
    switch (msg) {
        WM_RENDERER, WM_CONTROL => {
            const notice = pipe.Notice.fromLparam(lp);
            if (notice == .frame) notice.frame.destroy();
            return 0;
        },
        WM_SCANNED => {
            const job: *ScanJob = @ptrFromInt(@as(usize, @bitCast(lp))); // zsnag:ok — ScanJob.run posted its own pointer
            job.destroy();
            return 0;
        },
        WM_TRAY, WM_LAYER_GONE, w.WM_TIMER, w.WM_WTSSESSION_CHANGE, w.WM_DISPLAYCHANGE => return 0,
        w.WM_QUERYENDSESSION, w.WM_POWERBROADCAST => return 1,
        w.WM_CLOSE => {
            w.PostQuitMessage(0);
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn onWinEvent(_: w.HWINEVENTHOOK, _: w.DWORD, hwnd: ?w.HWND, id_object: i32, _: i32, _: w.DWORD, _: w.DWORD) callconv(.winapi) void {
    const host = rt.host orelse return;
    if (id_object != w.OBJID_WINDOW) return;
    const gone = hwnd orelse return;
    if (gone == host.parent or gone == host.progman) _ = w.PostMessageW(rt.control, WM_LAYER_GONE, 0, 0);
}

fn onConsoleCtrl(_: w.DWORD) callconv(.winapi) w.BOOL {
    _ = w.PostThreadMessageW(rt.main_thread, w.WM_QUIT, 0, 0);
    return 1;
}

test "a missing startup wallpaper survives a save (audit #2 F3)" {
    const configured: Settings = .{ .wallpaper = "E:\\usb\\rain.mp4" };
    // Nothing could be shown at startup: the configured wallpaper is written back.
    const s = persistent(configured, null, configured.wallpaper, null);
    try std.testing.expectEqualStrings("E:\\usb\\rain.mp4", s.wallpaper);
    // Once something is showing, that's what's saved.
    try std.testing.expectEqualStrings("C:\\w\\b.jpg", persistent(configured, "C:\\w\\b.jpg", configured.wallpaper, null).wallpaper);
}

test "--paused holds for this run only (audit #2 F6)" {
    var live: Settings = .{};
    live.paused = true; // forced by --paused
    try std.testing.expect(!persistent(live, null, "", false).paused);
    // After the user pauses or plays themselves, the override is dropped (null).
    try std.testing.expect(persistent(live, null, "", null).paused);
}

test "device and raw NT paths are recognised (audit #2 F9)" {
    try std.testing.expect(isDevicePath("\\\\.\\pipe\\x"));
    try std.testing.expect(isDevicePath("//./PhysicalDrive0"));
    try std.testing.expect(isDevicePath("\\\\?\\C:\\wp\\a.mp4"));
    try std.testing.expect(isDevicePath("\\??\\C:\\wp\\a.mp4"));
    try std.testing.expect(!isDevicePath("\\\\nas\\media\\a.mp4"));
    try std.testing.expect(!isDevicePath("C:\\wp\\a.mp4"));
    try std.testing.expect(!isDevicePath("\\\\"));
}

test "renderer log text can't forge log lines (audit #2 F11)" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("ok?fake line", logSafe(&buf, "ok\nfake line"));
    try std.testing.expectEqualStrings("0123456789abcdef", logSafe(&buf, "0123456789abcdefTOO LONG"));
    try std.testing.expectEqualStrings("caf\xc3\xa9", logSafe(&buf, "caf\xc3\xa9")); // UTF-8 kept
}
