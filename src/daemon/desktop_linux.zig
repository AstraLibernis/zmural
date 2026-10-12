// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Making the user's desktop show zmural (Linux), at daemon startup.
//!
//! - wlr-layer-shell compositors (Sway, Hyprland, Niri...): the
//!   layer-shell host (`zmural --layer-shell`) does it; nothing to install.
//! - KDE Plasma: zmural ships its own Plasma wallpaper plugin (built from the
//!   vendored waywallen-display, `org.zmural.kde`). zmural installs it for
//!   the user when it's missing or out of date, switches the desktops to it,
//!   and says so in a notification.
//! - GNOME: the same with zmural's GNOME Shell extension
//!   (`org.zmural.gnome@zmural`, also from waywallen-display). GNOME loads a
//!   newly installed extension at the next login, so the notification says
//!   whether it's running already or needs a log out and back in.
//!
//! Everything here is best effort: a failure is logged and zmural runs on.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const dbus = zmural.os.dbus;
const backend = @import("hosts").linux;
const req = @import("requirements_linux.zig");

const log = std.log.scoped(.desktop);

pub const kde_plugin_id = "org.zmural.kde";
pub const gnome_uuid = "org.zmural.gnome@zmural";
const kde_zip_name = "zmural-kde.zip";
const gnome_zip_name = "zmural-gnome.zip";
const app_name = "zmural";

pub const Env = struct {
    xdg_current_desktop: []const u8,
    home: []const u8,
    xdg_data_home: ?[]const u8,
    /// Where zmural runs from; the plugin zip is next to it or in ../share/zmural.
    exe_dir: []const u8,
    /// The session is known to be X11 (`$XDG_SESSION_TYPE`, or `$DISPLAY`
    /// without `$WAYLAND_DISPLAY`).
    x11: bool = false,
};

/// Sets `path` as the desktop's own, still wallpaper through the XDG
/// wallpaper portal: what zmural falls back to where no live host can show
/// anything. Pictures only; the desktop may ask the user to confirm.
pub fn setStill(bus: *dbus.Conn, path: []const u8) !void {
    var uri_buf: [4096]u8 = undefined;
    const uri = zmural.os.xdg.fileUri(&uri_buf, path) orelse return error.PathTooLong;
    var buf: [4608]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    try w.string(""); // no parent window
    try w.string(uri);
    const options = try w.beginArray(8);
    try w.pad(8);
    try w.string("set-on");
    try w.signature("s");
    try w.string("background");
    try w.pad(8);
    try w.string("show-preview");
    try w.signature("b");
    try w.u32_(0);
    w.endArray(options);
    _ = try bus.call("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Wallpaper", "SetWallpaperURI", "ssa{sv}", w.written());
}

/// Sets the desktop up for zmural. `bus` may be null (no session bus).
pub fn isKde(env: Env) bool {
    return backend.pick(env.xdg_current_desktop, true) == .kde_plasma;
}

/// What `setUp` found.
pub const Setup = struct {
    /// What this desktop is known to lack for live wallpapers (nothing is
    /// installed for it then), for the caller to tell the user once.
    short: ?req.Shortfall = null,
    /// Nothing live shows here for now: the desktop lacks something
    /// (`short`), or zmural's GNOME extension waits for the next login. The
    /// showing wallpaper is set as the desktop's own, still, meanwhile
    /// (zmural's plugin or extension draws over it once it runs).
    still: bool = false,
};

pub fn setUp(gpa: std.mem.Allocator, io: std.Io, env: Env, bus: ?*dbus.Conn) Setup {
    installLauncher(gpa, io, env) catch |err| log.warn("can't install the settings launcher: {s}", .{@errorName(err)});
    if (check(io, env)) |short| {
        var a: [256]u8 = undefined;
        var b: [512]u8 = undefined;
        log.warn("{s}: {s}", .{ short.summary(&a), short.body(&b) });
        // Only where zmural's own plugin or extension can't run: a still set
        // through the portal would switch Plasma away from zmural's plugin.
        return .{ .short = short, .still = backend.pick(env.xdg_current_desktop, true) != .layer_shell };
    }
    switch (backend.pick(env.xdg_current_desktop, true)) {
        .kde_plasma => setUpKde(gpa, io, env, bus),
        .gnome_shell => if (setUpGnome(gpa, io, env, bus)) return .{ .still = true },
        .layer_shell, .portal_static => {},
    }
    return .{};
}

/// What zmural needs here and this desktop is known not to have
/// (`requirements_linux.zig`). A version that can't be read is no reason
/// to stop.
fn check(io: std.Io, env: Env) ?req.Shortfall {
    if (env.x11) return .x11;
    var buf: [256]u8 = undefined;
    switch (backend.pick(env.xdg_current_desktop, true)) {
        .kde_plasma => {
            if (captureInto(io, &.{ "plasmashell", "--version" }, &buf)) |out| if (req.parsePlasma(out)) |v| {
                if (v.major < req.kde_min_plasma) return .{ .plasma = v };
            };
            if (qtVersion(io)) |v| if (!v.atLeast(req.kde_min_qt)) return .{ .qt = v };
        },
        .gnome_shell => {
            const out = captureInto(io, &.{ "gnome-shell", "--version" }, &buf) orelse return .{ .gnome = null };
            const v = req.parseGnomeShell(out) orelse return null;
            if (!req.gnomeSupported(v)) return .{ .gnome = v };
        },
        .layer_shell, .portal_static => {},
    }
    return null;
}

/// The system's Qt 6, from the file its libQt6Core.so.6 links to
/// ("libQt6Core.so.6.8.2"), where distributions put it.
fn qtVersion(io: std.Io) ?req.Version {
    var buf: [256]u8 = undefined;
    for ([_][]const u8{ "/usr/lib64/libQt6Core.so.6", "/usr/lib/x86_64-linux-gnu/libQt6Core.so.6", "/usr/lib/libQt6Core.so.6" }) |lib| {
        const n = std.Io.Dir.cwd().readLink(io, lib, &buf) catch continue;
        if (req.parseQtLib(buf[0..n])) |v| return v;
    }
    return null;
}

fn setUpKde(gpa: std.mem.Allocator, io: std.Io, env: Env, bus: ?*dbus.Conn) void {
    const zip = findBundle(gpa, io, env.exe_dir, kde_zip_name) orelse {
        log.warn("KDE Plasma: zmural's plugin ({s}) isn't next to zmural; build it with `zig build kde-plugin`", .{kde_zip_name});
        notify(bus, "zmural needs its KDE Plasma plugin", "Plasma shows its own wallpaper over other programs, so zmural uses a Plasma wallpaper plugin. It wasn't found next to zmural; reinstall zmural.");
        return;
    };
    defer gpa.free(zip);

    const done = installKdePlugin(gpa, io, env, zip) catch |err| {
        log.err("KDE Plasma: can't install zmural's plugin: {s}", .{@errorName(err)});
        notify(bus, "zmural couldn't install its KDE Plasma plugin", "Plasma needs zmural's wallpaper plugin to show live wallpapers, and installing it failed. See zmural's log.");
        return;
    };
    const switched = activateKde(bus);
    // An upgrade is quiet: the user already chose zmural's wallpaper.
    if (done == .installed) {
        notify(bus, "Installed the zmural plugin for KDE Plasma", if (switched)
            "Your desktop now shows zmural's wallpaper. To go back: right-click the desktop, Desktop and Wallpaper, and pick another wallpaper type."
        else
            "To show zmural's wallpaper: right-click the desktop, Desktop and Wallpaper, and set Wallpaper type to zmural.");
    }
}

/// True when the extension is on but not running yet: GNOME starts it at the
/// next login.
fn setUpGnome(gpa: std.mem.Allocator, io: std.Io, env: Env, bus: ?*dbus.Conn) bool {
    const zip = findBundle(gpa, io, env.exe_dir, gnome_zip_name) orelse {
        log.warn("GNOME: zmural's extension ({s}) isn't next to zmural; build it with `zig build gnome-extension`", .{gnome_zip_name});
        notify(bus, "zmural needs its GNOME extension", "GNOME doesn't let programs draw behind the desktop, so zmural uses a GNOME Shell extension. It wasn't found next to zmural; reinstall zmural.");
        return false;
    };
    defer gpa.free(zip);
    const done = installBundle(gpa, io, env, zip, .gnome) catch |err| {
        log.err("GNOME: can't install zmural's extension: {s}", .{@errorName(err)});
        notify(bus, "zmural couldn't install its GNOME extension", "GNOME needs zmural's Shell extension to show live wallpapers, and installing it failed. See zmural's log.");
        return false;
    };
    if (done == .upgraded) {
        // The old version runs until the next login.
        notify(bus, "Updated the zmural extension for GNOME", "GNOME runs the new version after you log out and back in.");
        return false;
    }
    if (done == .up_to_date) {
        if (gnomeActive(io)) return false;
        // Turned off in Extensions: the user's call, so their background stays.
        if (!gnomeEnabled(gpa, io)) {
            log.warn("GNOME: zmural's extension is turned off (Extensions app), so zmural shows nothing here", .{});
            return false;
        }
        log.warn("GNOME: zmural's extension is on but not running yet; GNOME starts it at the next login", .{});
        return true;
    }
    enableGnome(gpa, io);
    if (gnomeActive(io)) {
        notify(bus, "Installed the zmural extension for GNOME", "Your desktop now shows zmural's wallpaper. You can turn the extension off in the Extensions app.");
        return false;
    }
    notify(bus, "Installed the zmural extension for GNOME", "Log out and back in to finish: GNOME starts new extensions at login. Until then your desktop shows a still picture of zmural's wallpaper.");
    return true;
}

/// Is the extension in the list GNOME starts at login?
fn gnomeEnabled(gpa: std.mem.Allocator, io: std.Io) bool {
    const current = capture(gpa, io, &.{ "gsettings", "get", "org.gnome.shell", "enabled-extensions" }) orelse return false;
    defer gpa.free(current);
    return std.mem.find(u8, current, gnome_uuid) != null;
}

/// The GNOME background keys a still picture changes.
const gnome_background_keys = [_][]const u8{ "picture-uri", "picture-uri-dark" };
const gnome_background_file = "gnome-background";

/// Before zmural first sets a still picture on GNOME: keeps the user's own
/// background (both keys) in `state_dir`, for uninstall to put back. Kept
/// once: later stills don't replace it.
pub fn saveGnomeBackground(gpa: std.mem.Allocator, io: std.Io, state_dir: []const u8) void {
    const path = std.fs.path.join(gpa, &.{ state_dir, gnome_background_file }) catch return;
    defer gpa.free(path);
    if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| return f.close(io) else |_| {}
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    for (gnome_background_keys) |key| {
        const value = capture(gpa, io, &.{ "gsettings", "get", "org.gnome.desktop.background", key }) orelse return;
        defer gpa.free(value);
        text.writer.print("{s}={s}\n", .{ key, std.mem.trim(u8, value, " \n") }) catch return;
    }
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.written() }) catch |err|
        return log.warn("GNOME: can't keep your background to put back later: {s}", .{@errorName(err)});
    log.info("GNOME: kept your background ({s}), for uninstall to put back", .{path});
}

/// Uninstall: the user's own GNOME background, as `saveGnomeBackground` kept it.
pub fn restoreGnomeBackground(gpa: std.mem.Allocator, io: std.Io, state_dir: []const u8, r: anytype) void {
    const path = std.fs.path.join(gpa, &.{ state_dir, gnome_background_file }) catch return;
    defer gpa.free(path);
    var buf: [8192]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, path, &buf) catch return; // zmural never set one
    var ok = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        // Only the keys zmural changed, whatever the file says.
        for (gnome_background_keys) |k| if (std.mem.eql(u8, k, key)) {
            if (!run(io, &.{ "gsettings", "set", "org.gnome.desktop.background", key, line[eq + 1 ..] })) ok = false;
        };
    }
    if (ok) r.line("GNOME: your own background is back", .{}) else {
        r.line("couldn't put your GNOME background back (gsettings failed); pick it again in Settings > Appearance", .{});
        r.failed = true;
    }
}

/// Turns the extension on: through the Shell when it already knows the
/// extension, else in the settings the Shell reads at login.
fn enableGnome(gpa: std.mem.Allocator, io: std.Io) void {
    if (run(io, &.{ "gnome-extensions", "enable", gnome_uuid })) return;
    const current = capture(gpa, io, &.{ "gsettings", "get", "org.gnome.shell", "enabled-extensions" }) orelse return;
    defer gpa.free(current);
    if (std.mem.find(u8, current, gnome_uuid) != null) return;
    const list = std.mem.trim(u8, current, " \n");
    // "@as []" (empty) or "['a', 'b']".
    const next = if (std.mem.findScalar(u8, list, '\'') == null)
        std.fmt.allocPrint(gpa, "['{s}']", .{gnome_uuid}) catch return
    else
        std.fmt.allocPrint(gpa, "{s}, '{s}']", .{ list[0 .. std.mem.findScalarLast(u8, list, ']') orelse return], gnome_uuid }) catch return;
    defer gpa.free(next);
    if (!run(io, &.{ "gsettings", "set", "org.gnome.shell", "enabled-extensions", next }))
        log.warn("GNOME: couldn't enable zmural's extension", .{});
}

/// Is the extension running in the Shell right now?
fn gnomeActive(io: std.Io) bool {
    var buf: [4096]u8 = undefined;
    const out = captureInto(io, &.{ "gnome-extensions", "info", gnome_uuid }, &buf) orelse return false;
    return std.mem.find(u8, out, "ACTIVE") != null;
}

/// Runs a command; true if it exited 0.
fn run(io: std.Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}

/// A command's standard output (up to 4 KiB), or null if it failed.
fn capture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?[]u8 {
    var buf: [4096]u8 = undefined;
    const out = captureInto(io, argv, &buf) orelse return null;
    return gpa.dupe(u8, out) catch null;
}

fn captureInto(io: std.Io, argv: []const []const u8, buf: []u8) ?[]const u8 {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .pipe, .stderr = .ignore }) catch return null;
    var n: usize = 0;
    if (child.stdout) |f| {
        while (n < buf.len) {
            const got = f.readStreaming(io, &.{buf[n..]}) catch break;
            if (got == 0) break;
            n += got;
        }
    }
    const term = child.wait(io) catch return null;
    if (term != .exited or term.exited != 0) return null;
    return buf[0..n];
}

/// A bundled plugin or extension zip, as a full path.
fn findBundle(gpa: std.mem.Allocator, io: std.Io, exe_dir: []const u8, name: []const u8) ?[]u8 {
    const candidates = [_][]const []const u8{
        &.{ exe_dir, name },
        &.{ exe_dir, "..", "share", "zmural", name },
    };
    for (candidates) |parts| {
        const path = std.fs.path.join(gpa, parts) catch return null;
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return path else |_| gpa.free(path);
    }
    return null;
}

const icon_sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256 };

/// The settings window's launcher, so it's in the app menu and docks show
/// its icon (the window's app id is `org.zmural.Settings`): a .desktop
/// entry and hicolor icons in the user's data dir. Rewritten when they
/// differ, e.g. after zmural moved or was upgraded.
fn installLauncher(gpa: std.mem.Allocator, io: std.Io, env: Env) !void {
    const data = if (env.xdg_data_home) |d| try gpa.dupe(u8, d) else try std.fs.path.join(gpa, &.{ env.home, ".local", "share" });
    defer gpa.free(data);
    const exe = try std.fs.path.join(gpa, &.{ env.exe_dir, "zmural" });
    defer gpa.free(exe);
    var buf: [3 * std.Io.Dir.max_path_bytes + 512]u8 = undefined;
    var changed = try writeIfChanged(gpa, io, data, "applications/org.zmural.Settings.desktop", try launcherEntry(&buf, exe));
    inline for (icon_sizes) |px| {
        const sub = std.fmt.comptimePrint("icons/hicolor/{d}x{d}/apps/org.zmural.Settings.png", .{ px, px });
        const png = @embedFile(std.fmt.comptimePrint("icon-{d}.png", .{px}));
        changed = try writeIfChanged(gpa, io, data, sub, png) or changed;
    }
    if (changed) log.info("installed the settings launcher and icons in {s}", .{data});
}

fn launcherEntry(buf: []u8, exe: []const u8) error{NoSpaceLeft}![]u8 {
    var q: [3 * std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.fmt.bufPrint(buf,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=zmural
        \\GenericName=Live wallpaper
        \\Comment=Choose and control your live wallpaper
        \\Exec={s} --settings
        \\Icon=org.zmural.Settings
        \\Terminal=false
        \\Categories=Settings;DesktopSettings;
        \\Keywords=wallpaper;background;video;live;
        \\StartupWMClass=org.zmural.Settings
        \\
    , .{try zmural.os.autostart_linux.execQuoted(&q, exe)});
}

/// Writes `data/sub` unless it already holds exactly `bytes`. True when it wrote.
fn writeIfChanged(gpa: std.mem.Allocator, io: std.Io, data: []const u8, sub: []const u8, bytes: []const u8) !bool {
    const cwd = std.Io.Dir.cwd();
    const path = try std.fs.path.join(gpa, &.{ data, sub });
    defer gpa.free(path);
    if (cwd.readFileAlloc(io, path, gpa, .limited(1 << 20))) |old| {
        defer gpa.free(old);
        if (std.mem.eql(u8, old, bytes)) return false;
    } else |_| {}
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
    return true;
}

test "the launcher entry quotes a folder with characters desktop entries reserve" {
    var buf: [1024]u8 = undefined;
    const e = try launcherEntry(&buf, "/opt/my $zmural 100%/bin/zmural");
    try std.testing.expect(std.mem.find(u8, e, "Exec=env \"/opt/my \\\\$zmural 100%%/bin/zmural\" --settings\n") != null);
}

test "the launcher entry runs the settings window and names its icon" {
    var buf: [1024]u8 = undefined;
    const e = try launcherEntry(&buf, "/opt/zmural/bin/zmural");
    try std.testing.expect(std.mem.find(u8, e, "Exec=\"/opt/zmural/bin/zmural\" --settings\n") != null);
    try std.testing.expect(std.mem.find(u8, e, "Icon=org.zmural.Settings\n") != null);
}

fn installKdePlugin(gpa: std.mem.Allocator, io: std.Io, env: Env, zip: []const u8) !Installed {
    return installBundle(gpa, io, env, zip, .kde);
}

const Bundle = enum { kde, gnome };

const Installed = enum { up_to_date, installed, upgraded };

/// Installs or upgrades a plugin/extension when the bundled zip differs from
/// what was installed last.
fn installBundle(gpa: std.mem.Allocator, io: std.Io, env: Env, zip: []const u8, which: Bundle) !Installed {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, zip, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    var stamp_buf: [32]u8 = undefined;
    const stamp = try std.fmt.bufPrint(&stamp_buf, "{x:0>16}", .{std.hash.Wyhash.hash(0, bytes)});

    const data = if (env.xdg_data_home) |d| try gpa.dupe(u8, d) else try std.fs.path.join(gpa, &.{ env.home, ".local", "share" });
    defer gpa.free(data);
    const stamp_dir = try std.fs.path.join(gpa, &.{ data, "zmural" });
    defer gpa.free(stamp_dir);
    const stamp_path = try std.fs.path.join(gpa, &.{ stamp_dir, switch (which) {
        .kde => "kde-plugin.stamp",
        .gnome => "gnome-extension.stamp",
    } });
    defer gpa.free(stamp_path);
    const installed = try std.fs.path.join(gpa, switch (which) {
        .kde => &.{ data, "plasma", "wallpapers", kde_plugin_id, "metadata.json" },
        .gnome => &.{ data, "gnome-shell", "extensions", gnome_uuid, "metadata.json" },
    });
    defer gpa.free(installed);

    const present = if (cwd.access(io, installed, .{})) |_| true else |_| false;
    if (present) {
        var old: [64]u8 = undefined;
        if (cwd.readFile(io, stamp_path, &old)) |got| {
            if (std.mem.eql(u8, got, stamp)) return .up_to_date;
        } else |_| {}
    }
    const ok = switch (which) {
        // -u upgrades an installed package; -i installs a new one.
        .kde => run(io, &.{ "kpackagetool6", "--type", "Plasma/Wallpaper", if (present) "-u" else "-i", zip }),
        .gnome => run(io, &.{ "gnome-extensions", "install", "--force", zip }),
    };
    if (!ok) return error.InstallFailed;
    try cwd.createDirPath(io, stamp_dir);
    try cwd.writeFile(io, .{ .sub_path = stamp_path, .data = stamp });
    log.info("{s}: {s} zmural's {s}", .{ switch (which) {
        .kde => "KDE Plasma",
        .gnome => "GNOME",
    }, if (present) "upgraded" else "installed", switch (which) {
        .kde => "wallpaper plugin",
        .gnome => "Shell extension",
    } });
    return if (present) .upgraded else .installed;
}

/// For the uninstaller: switches Plasma's desktops back to its own picture
/// wallpaper and removes zmural's plugin, and removes zmural's GNOME Shell
/// extension (GNOME then shows its own background). `r` takes the report
/// (`line`, `failed`).
pub fn removeFromDesktop(gpa: std.mem.Allocator, io: std.Io, env: Env, dbus_address: ?[]const u8, runtime_dir: ?[]const u8, r: anytype) void {
    const cwd = std.Io.Dir.cwd();
    const data = if (env.xdg_data_home) |d| gpa.dupe(u8, d) catch return else std.fs.path.join(gpa, &.{ env.home, ".local", "share" }) catch return;
    defer gpa.free(data);

    const kde_dir = std.fs.path.join(gpa, &.{ data, "plasma", "wallpapers", kde_plugin_id }) catch return;
    defer gpa.free(kde_dir);
    if (cwd.access(io, kde_dir, .{})) |_| {
        // Plasma first, or its desktops are left showing a plugin that's gone.
        if (dbus.Conn.session(dbus_address, runtime_dir)) |b| {
            var bus = b;
            defer bus.close();
            const script =
                \\desktops().forEach(function (d) {
                \\    if (d.wallpaperPlugin === "org.zmural.kde") {
                \\        d.wallpaperPlugin = "org.kde.image";
                \\        d.reloadConfig();
                \\    }
                \\});
            ;
            var buf: [1024]u8 = undefined;
            var w: dbus.Writer = .{ .buf = &buf };
            if (w.string(script)) |_| {
                if (bus.call("org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell", "evaluateScript", "s", w.written())) |_| {
                    r.line("KDE Plasma: desktops back to Plasma's own picture wallpaper", .{});
                } else |_| {}
            } else |_| {}
        } else |_| {}
        if (!run(io, &.{ "kpackagetool6", "--type", "Plasma/Wallpaper", "--remove", kde_plugin_id }))
            cwd.deleteTree(io, kde_dir) catch |err| {
                r.line("couldn't remove the KDE Plasma plugin ({s}): {s}", .{ kde_dir, @errorName(err) });
                r.failed = true;
                return;
            };
        r.line("removed the KDE Plasma plugin", .{});
    } else |_| {}

    const gnome_dir = std.fs.path.join(gpa, &.{ data, "gnome-shell", "extensions", gnome_uuid }) catch return;
    defer gpa.free(gnome_dir);
    if (cwd.access(io, gnome_dir, .{})) |_| {
        if (!run(io, &.{ "gnome-extensions", "uninstall", gnome_uuid }))
            cwd.deleteTree(io, gnome_dir) catch |err| {
                r.line("couldn't remove the GNOME Shell extension ({s}): {s}", .{ gnome_dir, @errorName(err) });
                r.failed = true;
                return;
            };
        r.line("removed the GNOME Shell extension", .{});
    } else |_| {}
}

/// Asks Plasma to show zmural on every desktop. False if Plasma isn't
/// reachable (it's not running yet, or there's no bus).
fn activateKde(bus: ?*dbus.Conn) bool {
    const b = bus orelse return false;
    const script =
        \\desktops().forEach(function (d) {
        \\    if (d.wallpaperPlugin !== "org.zmural.kde") {
        \\        d.wallpaperPlugin = "org.zmural.kde";
        \\        d.reloadConfig();
        \\    }
        \\});
    ;
    var buf: [1024]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    w.string(script) catch return false;
    _ = b.call("org.kde.plasmashell", "/PlasmaShell", "org.kde.PlasmaShell", "evaluateScript", "s", w.written()) catch |err| {
        log.warn("KDE Plasma: can't switch the wallpaper type ({s} {s})", .{ @errorName(err), b.lastError() });
        return false;
    };
    log.info("KDE Plasma: desktops set to zmural", .{});
    return true;
}

pub fn notify(bus: ?*dbus.Conn, summary: []const u8, body: []const u8) void {
    _ = shown(bus, summary, body);
}

/// `notify`, saying whether the desktop took the notification.
pub fn shown(bus: ?*dbus.Conn, summary: []const u8, body: []const u8) bool {
    log.info("{s}: {s}", .{ summary, body });
    const b = bus orelse return false;
    _ = b.notify(app_name, "preferences-desktop-wallpaper", summary, body) catch |err| {
        log.warn("notification not shown: {s} {s}", .{ @errorName(err), b.lastError() });
        return false;
    };
    return true;
}
