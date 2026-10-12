// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zmural: the app, a daemon that stays running. The only process with opinions: it owns the
//! library, settings, playlists, pause policy, per-monitor layout, and which
//! renderer feeds which monitor. It routes frames and never touches pixels.
//!
//! The same program is also everything the daemon starts beside itself, each
//! as its own process in a mode named by the first argument:
//! - `--renderer video|image|web ...`: shows one wallpaper. A crash, or a
//!   decoder a bad file got the better of, stays out of the daemon.
//! - `--watchdog --parent <pid>` (Windows): repaints the desktop if the
//!   daemon dies.
//! - `--layer-shell` (Linux): the display host for wlr-layer-shell desktops.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");
const Daemon = @import("daemon.zig").Daemon;
const Kind = @import("kind.zig").Kind;
const starter = @import("starter.zig");

/// zmural usually has no console (Windows) or only the journal (Linux): log
/// to a file as well.
pub const std_options: std.Options = .{
    .logFn = switch (builtin.os.tag) {
        .windows => zmural.os.logfile.logFn,
        .linux => zmural.os.logfile_linux.logFn,
        else => std.log.defaultLog,
    },
};

const usage =
    \\usage: zmural [options]
    \\
    \\  --apply <path>  show a wallpaper (a video, picture, GIF or package; web
    \\                  pages on Windows) on every monitor
    \\                  (`--apply test-pattern` draws a test pattern)
    \\  --settings      open the settings window (in the running zmural, if
    \\                  there is one)
    \\  --uninstall     remove zmural's settings, menu entry, start at login and
    \\                  desktop plugin (your wallpapers stay); asks nothing, so
    \\                  `zmural-console uninstall` is the friendlier way
    \\  --paused        start paused, for this run only (testing aid)
    \\  --version       print the version and exit
    \\  --help          show this help
    \\
++ (if (builtin.os.tag == .linux)
    \\  --layer-shell   be the display host for Sway, labwc, Wayfire, Niri and
    \\                  COSMIC (zmural starts it itself; `--layer-shell --help`
    \\                  for its options)
    \\
else
    "");

/// Crashes go to the log file too (`os/crashlog.zig`), then to stderr as usual.
pub const panic = std.debug.FullPanic(onPanic);

fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    zmural.os.crashlog.write("panic", msg, first_trace_addr orelse @returnAddress(), null);
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// Faults (a bad pointer, an illegal instruction) too: std calls this.
pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
        var buf: [64]u8 = undefined;
        const msg = if (addr) |a| std.fmt.bufPrint(&buf, "at address 0x{x}", .{a}) catch "" else "";
        zmural.os.crashlog.write(name, msg, null, ctx);
        std.debug.defaultHandleSegfault(addr, name, ctx);
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    setUpCrashLog(init, if (argv.len > 1) argv[1] else "", if (argv.len > 2) argv[2] else "");
    if (argv.len > 1) if (try runMode(init, argv[1], argv[2..])) return;
    testCrash(init, "zmural");

    var apply: ?[]const u8 = null;
    var paused = false;
    var settings = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--paused")) {
            paused = true;
        } else if (std.mem.eql(u8, a, "--settings")) {
            settings = true;
        } else if (std.mem.eql(u8, a, "--apply")) {
            i += 1;
            if (i == argv.len) fail("--apply needs a path");
            apply = argv[i];
        } else if (std.mem.eql(u8, a, "--version")) {
            return say(init, "zmural " ++ zmural.version ++ "\n");
        } else if (std.mem.eql(u8, a, "--help")) {
            return say(init, usage);
        } else {
            std.log.err("unknown option '{s}'", .{a});
            fail("see --help");
        }
    }

    if (builtin.os.tag == .windows) return runWindows(init, apply, paused, settings);
    if (builtin.os.tag == .linux) return runLinux(init, apply, paused, settings);

    var daemon = Daemon.init(arena);
    defer daemon.deinit();
    try daemon.run();
}

/// Names the log file every mode's crash goes to, and which part of zmural
/// this process is. The same file the daemon logs to, on both OSes.
fn setUpCrashLog(init: std.process.Init, flag: []const u8, arg: []const u8) void {
    var who_buf: [48]u8 = undefined;
    const who = if (std.mem.eql(u8, flag, Kind.mode_flag))
        std.fmt.bufPrint(&who_buf, "renderer {s}", .{arg}) catch "renderer"
    else if (std.mem.eql(u8, flag, "--watchdog"))
        "watchdog"
    else if (std.mem.eql(u8, flag, "--layer-shell"))
        "display host"
    else
        "zmural";
    const env = init.environ_map;
    var dir_buf: [512]u8 = undefined;
    var path_buf: [600]u8 = undefined;
    const path = switch (builtin.os.tag) {
        .linux => blk: {
            const dir = zmural.os.logfile_linux.dir(&dir_buf, env) orelse return;
            break :blk std.fmt.bufPrint(&path_buf, "{s}/zmural.log", .{dir}) catch return;
        },
        .windows => if (env.get("ZMURAL_CONFIG_DIR")) |dir|
            std.fmt.bufPrint(&path_buf, "{s}\\zmural.log", .{dir}) catch return
        else if (env.get("LOCALAPPDATA")) |base|
            std.fmt.bufPrint(&path_buf, "{s}\\zmural\\zmural.log", .{base}) catch return
        else
            return,
        else => return,
    };
    zmural.os.crashlog.setUp(path, who, env.get("TZ"));
}

/// Testing aid: `ZMURAL_TEST_CRASH=<part>:<panic|fault>` crashes that part of
/// zmural ("zmural", "renderer", "host") on purpose, to check crash reports.
fn testCrash(init: std.process.Init, part: []const u8) void {
    const v = init.environ_map.get("ZMURAL_TEST_CRASH") orelse return;
    const colon = std.mem.findScalar(u8, v, ':') orelse return;
    if (!std.mem.eql(u8, v[0..colon], part)) return;
    if (std.mem.eql(u8, v[colon + 1 ..], "fault")) {
        const p: *volatile u8 = @ptrFromInt(8); // zsnag:ok — a deliberate bad pointer, for the test
        p.* = 1;
    }
    @panic("a test crash (ZMURAL_TEST_CRASH)");
}

/// Runs the mode `flag` names and returns true, or returns false when `flag`
/// is an ordinary daemon option.
fn runMode(init: std.process.Init, flag: []const u8, rest: []const []const u8) !bool {
    if (std.mem.eql(u8, flag, Kind.mode_flag)) {
        const kind = (if (rest.len > 0) std.meta.stringToEnum(Kind, rest[0]) else null) orelse
            fail("--renderer needs video, image or web");
        testCrash(init, "renderer");
        try runRenderer(init, kind, rest[1..]);
    } else if (std.mem.eql(u8, flag, "--uninstall")) {
        const from_window = rest.len > 0 and std.mem.eql(u8, rest[0], "--from-window");
        std.process.exit(try @import("uninstall.zig").run(init, .{ .from_window = from_window }));
    } else if (std.mem.eql(u8, flag, "--watchdog")) {
        try @import("watchdog.zig").run(rest);
    } else if (builtin.os.tag == .linux and std.mem.eql(u8, flag, "--still-frame")) {
        std.process.exit(@import("still_frame.zig").run(init, rest));
    } else if (builtin.os.tag == .linux and std.mem.eql(u8, flag, "--layer-shell")) {
        testCrash(init, "host");
        try @import("hosts").layer_shell.start(init, rest);
    } else return false;
    return true;
}

fn runRenderer(init: std.process.Init, kind: Kind, args: []const []const u8) !void {
    const sdk = zmural.sdk;
    switch (builtin.os.tag) {
        .windows => switch (kind) {
            .video => try sdk.windows_renderer.run(init, .video, args),
            .image => try sdk.windows_renderer.run(init, .image, args),
            .web => try sdk.web_renderer.run(init, args),
        },
        .linux => switch (kind) {
            .video => try sdk.linux_renderer.run(init, .video, args),
            .image => try sdk.linux_renderer.run(init, .image, args),
            .web => try sdk.renderer.stub("web", args),
        },
        else => try sdk.renderer.stub(@tagName(kind), args),
    }
}

fn runLinux(init: std.process.Init, apply: ?[]const u8, paused: bool, open_settings: bool) !void {
    const arena = init.arena.allocator();
    const env = init.environ_map;
    const xdg = zmural.os.xdg.dir(env.get("XDG_RUNTIME_DIR")) orelse fail("$XDG_RUNTIME_DIR is not set (it holds zmural's sockets)");
    const apply_abs = if (apply) |p| try absoluteLinux(arena, p) else null;
    // Tests pretend to be another version to check that an upgrade replaces
    // the running zmural.
    const version = env.get("ZMURAL_REPORT_VERSION") orelse zmural.version;

    // The log: next to the settings when $ZMURAL_CONFIG_DIR is set (tests),
    // else $XDG_STATE_HOME/zmural. A second zmural appends its few lines too.
    var log_dir_buf: [512]u8 = undefined;
    const state_dir = zmural.os.logfile_linux.dir(&log_dir_buf, env);
    if (state_dir) |dir| zmural.os.logfile_linux.open(dir, "zmural", env.get("TZ"));

    // One zmural per session: hand over to a healthy one, replace a hung
    // or outdated one.
    var dir_buf: [256]u8 = undefined;
    _ = zmural.protocol.unix.runtimeDir(&dir_buf, xdg) catch |err| fail(@errorName(err));
    var control_buf: [256]u8 = undefined;
    const control_path = try zmural.protocol.transport.address(&control_buf, .linux, .control, xdg);
    // An app launcher hands over an activation token, which lets the settings
    // window take focus.
    const settings_token: ?[]const u8 = if (open_settings) env.get("XDG_ACTIVATION_TOKEN") orelse "" else null;
    const instance = @import("instance_linux.zig");
    switch (instance.claim(control_path, version, apply_abs, settings_token) catch |err| fail(switch (err) {
        error.ForeignServer => "another user's process holds zmural's control socket; not starting",
        error.CannotStop => "a stuck zmural could not be stopped; not starting",
        error.OutOfMemory => "out of memory",
    })) {
        .exit => return,
        .run => {},
    }

    const settings_mod = @import("settings.zig");
    var store = try settings_mod.Store.open(arena, init.io, env);
    var settings = store.load(arena);
    const welcome = firstRun(&store, apply_abs, env);
    const exe_dir = try std.process.executableDirPathAlloc(init.io, arena);
    const starter_dir = starter.dir(arena, init.io, exe_dir);
    try useStarter(arena, init.io, &settings, apply_abs, starter_dir);
    @import("runtime_linux.zig").run(init.gpa, init.io, settings, .{
        .wallpaper = apply_abs,
        .start_paused = paused,
        .xdg_runtime_dir = xdg,
        .exe_dir = exe_dir,
        .exe_path = try std.process.executablePathAlloc(init.io, arena),
        .dbus_address = env.get("DBUS_SESSION_BUS_ADDRESS"),
        .dbus_system_address = env.get("DBUS_SYSTEM_BUS_ADDRESS"),
        .desktop = .{
            .xdg_current_desktop = env.get("XDG_CURRENT_DESKTOP") orelse "",
            .home = env.get("HOME") orelse "/",
            .xdg_data_home = zmural.os.xdg.dir(env.get("XDG_DATA_HOME")),
            .exe_dir = exe_dir,
            .x11 = knownX11(env.get("XDG_SESSION_TYPE"), env.get("WAYLAND_DISPLAY"), env.get("DISPLAY")),
        },
        .store = &store,
        .xdg_config_home = zmural.os.xdg.dir(env.get("XDG_CONFIG_HOME")),
        .swaysock = env.get("SWAYSOCK"),
        .hyprland_signature = env.get("HYPRLAND_INSTANCE_SIGNATURE"),
        .wayfire_socket = env.get("WAYFIRE_SOCKET"),
        .niri_socket = env.get("NIRI_SOCKET"),
        .videos_dir_env = env.get("XDG_VIDEOS_DIR"),
        .pictures_dir_env = env.get("XDG_PICTURES_DIR"),
        .report_version = version,
        .state_dir = state_dir,
        .settings_env = .{
            .gpa = init.gpa,
            .io = init.io,
            .log_path = if (state_dir) |dir| try std.fs.path.join(arena, &.{ dir, "zmural.log" }) else "",
            .force_dark = if (env.get("ZMURAL_THEME")) |t| std.mem.eql(u8, t, "dark") else null,
            .runtime_dir = xdg,
            .home = env.get("HOME") orelse "/",
            .config_home = zmural.os.xdg.dir(env.get("XDG_CONFIG_HOME")),
            .cache_home = zmural.os.xdg.dir(env.get("XDG_CACHE_HOME")),
            .exe_dir = exe_dir,
            .dbus_address = env.get("DBUS_SESSION_BUS_ADDRESS"),
            .wayland_display = env.get("WAYLAND_DISPLAY"),
            .test_pick = env.get("ZMURAL_TEST_PICK"),
            .test_controls = env.get("ZMURAL_TEST_CONTROLS"),
            .welcome = welcome,
        },
        .open_settings = open_settings or welcome,
        .settings_token = settings_token orelse "",
        .starter_dir = starter_dir,
    }) catch |err| switch (err) {
        // Another zmural won a race for the sockets.
        error.AlreadyRunning => fail("zmural is already running"),
        // A machine with no GPU driver (some VMs and containers).
        error.NoRenderNode => fail("no GPU render node (/dev/dri/renderD*) can be opened; zmural needs one to show wallpapers"),
        else => return err,
    };
    // The settings window's Uninstall: zmural has stopped (the desktop has its
    // wallpaper back) and now removes itself, in this process, so a service
    // manager that ends everything with zmural can't cut the removal short.
    if (@import("settings").uninstallRequested())
        std.process.exit(try @import("uninstall.zig").run(init, .{ .from_window = true, .already_stopped = true }));
}

/// The very first start, with no wallpaper asked for: the settings window
/// opens by itself on its Welcome page, so the desktop isn't left empty with
/// nothing saying what to do. Not in tests ($ZMURAL_CONFIG_DIR), whose fresh
/// folders would all look like a first run.
fn firstRun(store: *const @import("settings.zig").Store, apply: ?[]const u8, env: *const std.process.Environ.Map) bool {
    if (!store.fresh or apply != null or env.get("ZMURAL_CONFIG_DIR") != null) return false;
    std.log.info("first run: opening the settings window", .{});
    return true;
}

/// With no wallpaper set (a first run, or one that never picked any) and
/// none asked for, the one zmural ships with shows, so the desktop isn't
/// left empty. It is not saved until the user changes something (owner's
/// decision): until then every start is a first run and opens on Welcome.
/// Once saved it is like any wallpaper, so a saved one from an install that
/// has since moved is pointed at this one.
fn useStarter(arena: std.mem.Allocator, io: std.Io, settings: *@import("settings.zig").Settings, apply: ?[]const u8, starter_dir: ?[]const u8) !void {
    if (apply != null or settings.monitor_wallpapers.len > 0) return;
    const stale = settings.wallpaper.len > 0;
    if (stale and !starter.isStale(io, settings.wallpaper)) return;
    const folder = starter_dir orelse return std.log.warn("no wallpaper set, and zmural's own ({s}) isn't next to it", .{starter.name});
    settings.wallpaper = try starter.path(arena, folder);
    if (stale)
        std.log.info("zmural's own wallpaper moved: showing it from {s}", .{settings.wallpaper})
    else
        std.log.info("no wallpaper set: showing zmural's own, {s}", .{starter.name});
}

/// A wallpaper path as the renderers must see it: absolute (they don't share our cwd).
fn absoluteLinux(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "test-pattern") or std.fs.path.isAbsolute(path)) return path;
    if (std.ascii.startsWithIgnoreCase(path, "https://") or std.ascii.startsWithIgnoreCase(path, "http://")) return path;
    var buf: [4096]u8 = undefined;
    const rc = std.os.linux.getcwd(&buf, buf.len);
    if (std.os.linux.errno(rc) != .SUCCESS) return path;
    const cwd = std.mem.sliceTo(&buf, 0);
    return std.fs.path.resolve(arena, &.{ cwd, path });
}

/// Prints to the terminal, even from a Windows GUI-subsystem build.
fn say(init: std.process.Init, text: []const u8) !void {
    if (builtin.os.tag == .windows) return zmural.os.logfile.consoleWrite(text);
    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try stdout.interface.writeAll(text);
    try stdout.interface.flush();
}

/// Runs the daemon, or, if one is already running, hands it our `--apply`.
fn runWindows(init: std.process.Init, apply: ?[]const u8, paused: bool, open_settings: bool) !void {
    // Logs go next to the settings when $ZMURAL_CONFIG_DIR is set (tests), else %LOCALAPPDATA%\zmural.
    const arena = init.arena.allocator();
    if (init.environ_map.get("ZMURAL_CONFIG_DIR")) |dir| {
        zmural.os.logfile.open(dir, "zmural");
    } else if (init.environ_map.get("LOCALAPPDATA")) |base| {
        zmural.os.logfile.open(try std.fs.path.join(arena, &.{ base, "zmural" }), "zmural");
    }
    const client = zmural.sdk.control_client;
    var addr_buf: [256]u8 = undefined;
    const addr = try client.address(&addr_buf);
    const apply_abs = if (apply) |p| try client.absolutePath(arena, p) else null;

    const settings_mod = @import("settings.zig");
    var store = try settings_mod.Store.open(arena, init.io, init.environ_map);
    var settings = store.load(arena);
    const welcome = firstRun(&store, apply_abs, init.environ_map);
    const exe_dir = try std.process.executableDirPathAlloc(init.io, arena);
    const starter_dir = starter.dir(arena, init.io, exe_dir);
    try useStarter(arena, init.io, &settings, apply_abs, starter_dir);
    // `--apply` is for every monitor; otherwise monitors keep their own.
    if (apply_abs != null) settings.monitor_wallpapers = &.{};
    // An explicit --apply wins; otherwise restore what was showing last time.
    const wallpaper = apply_abs orelse if (settings.wallpaper.len > 0) settings.wallpaper else null;

    // The standard folders, where Windows says Videos and Pictures are (the
    // user may have moved them); the runtime adds the user's own.
    const w = zmural.os.win32;
    var default_dirs: std.ArrayList([]const u8) = .empty;
    for ([_]struct { *const w.GUID, []const u8 }{ .{ &w.FOLDERID_Videos, "Videos" }, .{ &w.FOLDERID_Pictures, "Pictures" } }) |kf| {
        const base = w.knownFolder(arena, kf[0]) orelse if (init.environ_map.get("USERPROFILE")) |home|
            try std.fs.path.join(arena, &.{ home, kf[1] })
        else
            continue;
        try default_dirs.append(arena, try std.fs.path.join(arena, &.{ base, "Wallpapers" }));
    }

    const runtime = @import("runtime_windows.zig");
    runtime.settings_env = .{
        .gpa = init.gpa,
        .io = init.io,
        .log_path = zmural.os.logfile.path(),
        .force_dark = if (init.environ_map.get("ZMURAL_THEME")) |t| std.mem.eql(u8, t, "dark") else null,
        .welcome = welcome,
    };
    runtime.open_settings_at_start = open_settings or welcome;
    runtime.starter_dir = starter_dir;
    // Listed as an app (Start, Search, Settings > Apps), except in tests.
    if (init.environ_map.get("ZMURAL_CONFIG_DIR") == null) if (init.environ_map.get("APPDATA")) |appdata| {
        runtime.app_entry = .{
            .appdata = appdata,
            .app = .{
                .exe = try std.process.executablePathAlloc(init.io, arena),
                .dir = exe_dir,
                .version = zmural.version,
            },
        };
    };
    runtime.run(init.gpa, settings, store, default_dirs.items, wallpaper, paused, addr) catch |err| switch (err) {
        error.AlreadyRunning => {
            // Someone owns our pipe name. Only talk to it if it's really our zmural.
            const c = client.Client.connect(init.gpa, addr, "zmural") catch |e| switch (e) {
                error.ForeignServer => fail("another account has taken zmural's control pipe name; not starting (check the log)"),
                else => return e,
            };
            defer c.close(init.gpa);
            if (open_settings) switch (try c.request(.{ .open_settings = .{} })) {
                .ok => std.log.info("zmural is already running; asked it for the settings window", .{}),
                else => fail("the running zmural didn't open the settings window"),
            };
            const path = apply_abs orelse {
                if (!open_settings) std.log.info("zmural is already running", .{});
                return;
            };
            switch (try c.request(.{ .apply = .{ .path = path } })) {
                .ok => std.log.info("zmural is already running; handed it '{s}'", .{path}),
                .failed => |f| fail(f.message),
                else => fail("unexpected reply from the running zmural"),
            }
        },
        else => return err,
    };
}

fn fail(msg: []const u8) noreturn {
    std.log.err("zmural: {s}", .{msg});
    std.process.exit(2);
}

/// Only what the session says for sure: an X11 session type, or an X
/// display and no Wayland one.
fn knownX11(session_type: ?[]const u8, wayland_display: ?[]const u8, display: ?[]const u8) bool {
    if (session_type) |t| {
        if (std.mem.eql(u8, t, "x11")) return true;
        if (std.mem.eql(u8, t, "wayland")) return false;
    }
    const no_wayland = if (wayland_display) |w| w.len == 0 else true;
    const has_x = if (display) |d| d.len > 0 else false;
    return no_wayland and has_x;
}

test knownX11 {
    try std.testing.expect(knownX11("x11", null, ":0"));
    try std.testing.expect(knownX11(null, null, ":0"));
    try std.testing.expect(!knownX11("wayland", null, ":0"));
    try std.testing.expect(!knownX11(null, "wayland-0", ":0")); // Xwayland's DISPLAY
    try std.testing.expect(!knownX11("tty", null, null));
    try std.testing.expect(!knownX11(null, null, null));
}

test {
    _ = @import("daemon.zig");
    _ = @import("settings.zig");
    _ = @import("library.zig");
    _ = @import("playlist.zig");
    _ = @import("rotation.zig");
    if (@import("builtin").os.tag == .linux) _ = @import("facts_linux.zig");
    _ = @import("router.zig");
    _ = @import("lifecycle.zig");
    _ = @import("lists.zig");
    _ = @import("kind.zig");
    _ = @import("tray.zig");
    _ = @import("desire.zig");
    _ = @import("notices.zig");
    _ = @import("monitors.zig");
    _ = @import("adjust.zig");
    _ = @import("watchdog.zig");
    _ = @import("uninstall.zig");
    _ = @import("starter.zig");
    _ = @import("fallback.zig");
    if (builtin.os.tag == .linux) {
        _ = @import("runtime_linux.zig");
        _ = @import("display_session.zig");
        _ = @import("foreground_linux.zig");
        _ = @import("compositor_sway.zig");
        _ = @import("compositor_niri.zig");
        _ = @import("compositor_hyprland.zig");
        _ = @import("compositor_wayfire.zig");
        _ = @import("instance_linux.zig");
        _ = @import("tray_linux.zig");
        _ = @import("requirements_linux.zig");
        _ = @import("desktop_linux.zig");
    }
    if (builtin.os.tag == .windows) {
        _ = @import("runtime_windows.zig");
        _ = @import("tray_windows.zig");
        _ = @import("control_test.zig");
    }
}
