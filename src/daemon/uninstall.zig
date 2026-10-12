// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! `zmural --uninstall`: takes zmural off this computer, politely. It stops
//! a running zmural (which gives the desktop its own wallpaper back), then
//! removes what zmural added: start at login, its app-menu entry and icons,
//! its KDE Plasma plugin or GNOME Shell extension (switching the desktop back
//! to its own wallpaper first), and its settings, logs and state.
//!
//! What it never touches: the user's wallpapers (videos, pictures, pages),
//! their library folders, or anything else outside zmural's own folders. The
//! program's own folder is left for the user to delete, since the program is
//! running from it.
//!
//! `zmural-console uninstall` asks first, then runs this; the settings
//! window's Uninstall button does too.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");

pub const Options = struct {
    /// Started from the settings window: no terminal, so the result is shown
    /// as a notification (Linux) or a message box (Windows) instead.
    from_window: bool = false,
    /// Run by zmural itself after it stopped (the window's Uninstall on
    /// Linux): nothing to stop.
    already_stopped: bool = false,
};

const Report = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
    failed: bool = false,

    pub fn line(r: *Report, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(r.buf[r.len..], fmt ++ "\n", args) catch return;
        r.len += out.len;
    }
    fn text(r: *const Report) []const u8 {
        return r.buf[0..r.len];
    }
};

/// Exit code: 0 done, 1 something couldn't be removed (the report says what).
pub fn run(init: std.process.Init, opts: Options) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var r: Report = .{};

    if (opts.already_stopped) r.line("stopped zmural", .{}) else stopRunning(gpa, env, &r);
    // Testing aid: `ZMURAL_TEST_SLOW_UNINSTALL=<ms>` waits before removing
    // anything, as switching a real Plasma back over D-Bus takes a while, so
    // the rig can check nothing is cut short when zmural's processes die
    // with it (tools/uninstall-test.sh).
    if (env.get("ZMURAL_TEST_SLOW_UNINSTALL")) |v| sleepMs(std.fmt.parseUnsigned(u32, v, 10) catch 0);
    switch (builtin.os.tag) {
        .linux => try removeLinux(gpa, arena, io, env, &r),
        .windows => try removeWindows(arena, io, env, &r),
        else => r.line("nothing to do on this OS", .{}),
    }
    const exe_dir = std.process.executableDirPathAlloc(io, arena) catch "the folder zmural is in";
    r.line("", .{});
    r.line("Not touched: your wallpapers and the folders they are in.", .{});
    r.line("To finish, delete zmural's own folder: {s}", .{programFolder(arena, io, exe_dir)});
    if (r.failed) r.line("Some things couldn't be removed (above); delete them by hand if you like.", .{});
    show(gpa, io, env, opts, r.text());
    return if (r.failed) 1 else 0;
}

/// The folder to tell the user to delete: on Linux the tarball's top folder
/// (`bin` and `share/zmural` side by side), else the one zmural runs from.
fn programFolder(arena: std.mem.Allocator, io: std.Io, exe_dir: []const u8) []const u8 {
    if (!std.mem.eql(u8, std.fs.path.basename(exe_dir), "bin")) return exe_dir;
    const top = std.fs.path.dirname(exe_dir) orelse return exe_dir;
    const share = std.fs.path.join(arena, &.{ top, "share", "zmural" }) catch return exe_dir;
    std.Io.Dir.cwd().access(io, share, .{}) catch return exe_dir;
    return top;
}

/// Asks a running zmural to quit and waits for it (it restores the desktop's
/// own wallpaper as it goes).
fn stopRunning(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, r: *Report) void {
    const control = zmural.protocol.control;
    var addr_buf: [256]u8 = undefined;
    switch (builtin.os.tag) {
        .linux => {
            const client = zmural.sdk.control_client_linux;
            const addr = client.address(&addr_buf, zmural.os.xdg.dir(env.get("XDG_RUNTIME_DIR"))) catch return;
            const c = client.Client.connect(gpa, addr, "zmural-uninstall", 3000) catch return; // not running
            _ = c.request(control.Request.quit) catch {}; // zsnag:ok — it may quit before it answers; the wait below tells
            c.close(gpa);
            for (0..100) |_| {
                const again = client.Client.connect(gpa, addr, "zmural-uninstall", 500) catch break;
                again.close(gpa);
                sleepMs(100);
            }
        },
        .windows => {
            const client = zmural.sdk.control_client;
            const addr = client.address(&addr_buf) catch return;
            const c = client.Client.connect(gpa, addr, "zmural-uninstall") catch return;
            // The pipe closes before zmural is done: it still saves its settings
            // and holds its log open, which Windows won't delete. So wait for the
            // process itself.
            const w = zmural.os.win32;
            const proc = if (c.conn.peerProcessId()) |pid| w.OpenProcess(w.SYNCHRONIZE, 0, pid) else null;
            _ = c.request(control.Request.quit) catch {}; // zsnag:ok — it may quit before it answers; the wait below tells
            c.close(gpa);
            if (proc) |h| {
                defer _ = w.CloseHandle(h);
                if (w.WaitForSingleObject(h, 10_000) == 0) { // WAIT_OBJECT_0
                    r.line("stopped zmural", .{});
                    return;
                }
            }
            for (0..100) |_| {
                const again = client.Client.connect(gpa, addr, "zmural-uninstall") catch break;
                again.close(gpa);
                sleepMs(100);
            }
        },
        else => return,
    }
    r.line("stopped zmural", .{});
}

fn sleepMs(ms: u64) void {
    switch (builtin.os.tag) {
        .windows => zmural.os.win32.Sleep(@intCast(ms)),
        else => {
            // nanosleep refuses a nsec of a second or more.
            const ts: std.os.linux.timespec = .{ .sec = @intCast(ms / std.time.ms_per_s), .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms) };
            _ = std.os.linux.nanosleep(&ts, null);
        },
    }
}

fn removeLinux(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, r: *Report) !void {
    const xdg = zmural.os.xdg;
    const home = env.get("HOME") orelse "/";
    const data = if (xdg.dir(env.get("XDG_DATA_HOME"))) |d| d else try std.fs.path.join(arena, &.{ home, ".local", "share" });
    const config_home = xdg.dir(env.get("XDG_CONFIG_HOME"));

    // The desktop's plugin or extension, the desktop switched back first.
    @import("desktop_linux.zig").removeFromDesktop(gpa, io, .{
        .xdg_current_desktop = env.get("XDG_CURRENT_DESKTOP") orelse "",
        .home = home,
        .xdg_data_home = xdg.dir(env.get("XDG_DATA_HOME")),
        .exe_dir = "",
    }, env.get("DBUS_SESSION_BUS_ADDRESS"), xdg.dir(env.get("XDG_RUNTIME_DIR")), r);
    // A still picture zmural set on GNOME replaced the user's background: back it goes.
    var saved_buf: [512]u8 = undefined;
    if (zmural.os.logfile_linux.dir(&saved_buf, env)) |state| @import("desktop_linux.zig").restoreGnomeBackground(gpa, io, state, r);

    // Start at login.
    const entry = try zmural.os.autostart_linux.path(arena, config_home, home);
    removeFile(io, entry, "start at login", r);

    // The app-menu entry and its icons.
    removeFile(io, try std.fs.path.join(arena, &.{ data, "applications", "org.zmural.Settings.desktop" }), "the app-menu entry", r);
    var icons: usize = 0;
    for ([_]u32{ 16, 24, 32, 48, 64, 128, 256 }) |px| {
        const p = try std.fmt.allocPrint(arena, "{s}/icons/hicolor/{d}x{d}/apps/org.zmural.Settings.png", .{ data, px, px });
        std.Io.Dir.cwd().deleteFile(io, p) catch continue;
        icons += 1;
    }
    if (icons > 0) r.line("removed the app-menu icons", .{});

    // zmural's own folders: what it keeps about the plugins, its settings,
    // its log and state, and its sockets.
    removeTree(io, try std.fs.path.join(arena, &.{ data, "zmural" }), "zmural's data", r);
    // Still pictures and thumbnails made from videos and pictures (`still_frame.zig`).
    const cache = if (xdg.dir(env.get("XDG_CACHE_HOME"))) |c| try std.fs.path.join(arena, &.{ c, "zmural" }) else try std.fs.path.join(arena, &.{ home, ".cache", "zmural" });
    removeTree(io, cache, "its still pictures and thumbnails", r);
    const config = if (env.get("ZMURAL_CONFIG_DIR")) |d|
        d
    else if (config_home) |c|
        try std.fs.path.join(arena, &.{ c, "zmural" })
    else
        try std.fs.path.join(arena, &.{ home, ".config", "zmural" });
    removeTree(io, config, "its settings", r);
    var state_buf: [512]u8 = undefined;
    if (zmural.os.logfile_linux.dir(&state_buf, env)) |state| {
        if (!std.mem.eql(u8, state, config)) removeTree(io, state, "its log and state", r);
    }
    if (xdg.dir(env.get("XDG_RUNTIME_DIR"))) |run_dir| {
        removeTree(io, try std.fs.path.join(arena, &.{ run_dir, "zmural" }), "its sockets", r);
        // The settings window's icon font (`settings/gui_cairo.zig`).
        const font = try std.fmt.allocPrint(arena, "{s}/zmural-icons-{d}.ttf", .{ run_dir, std.os.linux.getuid() });
        std.Io.Dir.cwd().deleteFile(io, font) catch {}; // zsnag:ok — not there, or gone at logout anyway
    }
}

fn removeWindows(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, r: *Report) !void {
    const autostart = zmural.os.autostart;
    if (autostart.remove()) |was| {
        if (was) r.line("removed start at login", .{});
    } else |err| {
        r.line("couldn't remove start at login: {s}", .{@errorName(err)});
        r.failed = true;
    }
    if (env.get("ZMURAL_CONFIG_DIR")) |d| return removeTree(io, d, "its settings and log", r);
    if (env.get("APPDATA")) |base| {
        const gone = zmural.os.apps_windows.unregister(arena, base);
        if (gone.shortcut) r.line("removed the Start menu shortcut", .{});
        if (gone.entry) r.line("removed it from Settings > Apps", .{});
    }
    if (env.get("APPDATA")) |base| removeTree(io, try std.fs.path.join(arena, &.{ base, "zmural" }), "its settings", r);
    // The log, and each web wallpaper's browser profile.
    if (env.get("LOCALAPPDATA")) |base| removeTree(io, try std.fs.path.join(arena, &.{ base, "zmural" }), "its log and web wallpaper data", r);
}

fn removeFile(io: std.Io, path: []const u8, what: []const u8, r: *Report) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            r.line("couldn't remove {s} ({s}): {s}", .{ what, path, @errorName(err) });
            r.failed = true;
            return;
        },
    };
    r.line("removed {s}", .{what});
}

fn removeTree(io: std.Io, path: []const u8, what: []const u8, r: *Report) void {
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{}) catch return; // not there
    cwd.deleteTree(io, path) catch |err| {
        r.line("couldn't remove {s} ({s}): {s}", .{ what, path, @errorName(err) });
        r.failed = true;
        return;
    };
    r.line("removed {s} ({s})", .{ what, path });
}

/// The report: on the terminal, or where the settings window's user sees it.
fn show(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options, text: []const u8) void {
    _ = io;
    if (!opts.from_window) return say(text);
    switch (builtin.os.tag) {
        .windows => {
            const w = zmural.os.win32;
            const wide = std.unicode.wtf8ToWtf16LeAllocZ(gpa, text) catch return;
            defer gpa.free(wide);
            _ = w.MessageBoxW(null, wide, w.L("zmural was removed"), 0x40); // MB_ICONINFORMATION
        },
        .linux => {
            var bus = zmural.os.dbus.Conn.session(env.get("DBUS_SESSION_BUS_ADDRESS"), zmural.os.xdg.dir(env.get("XDG_RUNTIME_DIR"))) catch return say(text);
            defer bus.close();
            // The summary only: a notification isn't a place for the whole list.
            const finish = std.mem.find(u8, text, "To finish,") orelse 0;
            const end = std.mem.findScalarPos(u8, text, finish, '\n') orelse text.len;
            _ = bus.notify("zmural", "preferences-desktop-wallpaper", "zmural was removed", text[finish..end]) catch return say(text);
        },
        else => say(text),
    }
}

fn say(text: []const u8) void {
    switch (builtin.os.tag) {
        .windows => zmural.os.logfile.consoleWrite(text),
        else => _ = std.os.linux.write(1, text.ptr, text.len),
    }
}
