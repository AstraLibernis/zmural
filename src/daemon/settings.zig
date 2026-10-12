// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! User settings, their defaults, and `settings.toml`.
//!
//! Where: `%APPDATA%\zmural\settings.toml` on Windows,
//! `$XDG_CONFIG_HOME/zmural/settings.toml` (`~/.config/zmural`) on Linux, or
//! `$ZMURAL_CONFIG_DIR` on both. The file explains itself: every key is
//! written with a comment and its allowed values, worded for the OS it is
//! written on (`comments`); the keys are the same on both.
//! Unknown keys are ignored, so an older zmural can read a newer file. A file
//! that fails to parse is never overwritten: zmural runs on defaults (or, if
//! the file broke while it ran, on what it had) and says where the problem is.
//! Hand edits made while zmural runs are picked up live (`checkFile` in each
//! runtime).
//!
//! `[monitors]` lists the monitors that show a wallpaper of their own, by
//! their ID (`daemon/monitors.zig`). Planned: a span/duplicate arrangement.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");
const toml = zmural.toml;
const policy = zmural.policy;

/// A monitor (by ID, "m-0123456789abcdef") with a wallpaper of its own.
pub const MonitorWallpaper = struct { monitor: []const u8, wallpaper: []const u8 };
/// A monitor (by ID) with a fill mode of its own.
pub const MonitorFill = struct { monitor: []const u8, fill: zmural.layout.FillMode };

pub const Settings = struct {
    /// What to show at startup (an absolute path, or empty).
    wallpaper: []const u8 = "",
    /// Monitors that show something else than `wallpaper`.
    monitor_wallpapers: []const MonitorWallpaper = &.{},
    /// Monitors that fill the screen another way than `fill`.
    monitor_fills: []const MonitorFill = &.{},
    fill: zmural.layout.FillMode = .crop,
    fps_cap: u16 = 30,
    volume: u8 = 50,
    /// Wallpapers start silent; sound is opt-in.
    muted: bool = true,
    /// Paused by the user (CLI or tray), on top of the automatic pause policy.
    paused: bool = false,
    /// Reuse one renderer for every monitor showing the same wallpaper.
    share_renderers: bool = true,
    policy: policy.Policy = policy.Policy.default(),
    /// How long a situation must be over before a paused wallpaper resumes.
    resume_after_ms: u32 = 400,
    /// Executable names (e.g. "eldenring.exe") that pause wallpapers while in the foreground.
    app_rules: []const []const u8 = &.{},
    /// Extra folders for the library, besides Videos\Wallpapers and Pictures\Wallpapers.
    library_dirs: []const []const u8 = &.{},
    /// Change the wallpaper after this many minutes of playing; 0 means never.
    rotate_minutes: u16 = 0,
    /// The order timed changes and Next/Previous follow.
    order: Order = .sequential,
};

pub const Order = zmural.protocol.control.Order;

pub const file_name = "settings.toml";

/// The pause rules the settings window shows: the ones this OS detects.
/// (The file keeps every rule on every OS, so nothing is lost moving it.)
const detected = if (builtin.os.tag == .windows) &[_]policy.Condition{
    .fullscreen, .maximized, .covered, .focused, .app_rule, .on_battery, .power_saver, .session_locked, .remote_session,
} else &[_]policy.Condition{
    // Window facts from the display hosts (or the desktop's plugin); the
    // rest over D-Bus (`facts_linux.zig`).
    .fullscreen, .maximized, .focused, .on_battery, .power_saver, .session_locked, .session_inactive, .remote_session, .game_mode,
};

const windows = builtin.os.tag == .windows;

/// The pause rules the file lists, in order, with what each one means.
/// Other-app audio isn't detected yet, so it isn't offered. The file keeps
/// the rules this OS can't detect too, so moving it between OSes loses nothing.
const pause_rules = [_]struct { policy.Condition, []const u8 }{
    .{ .fullscreen, "a game or app fills a whole monitor (affects every monitor)" },
    .{ .maximized, "a maximized window (affects that monitor)" },
    .{ .covered, if (windows) "windows cover almost all of a monitor (affects that monitor)" else "windows cover almost all of a monitor (affects that monitor; Sway only so far)" },
    .{ .focused, "any window has focus on the monitor" },
    .{ .app_rule, if (windows) "one of the apps listed below is in the foreground" else "one of the apps listed below is in front (KDE Plasma, Sway and Niri so far)" },
    .{ .on_battery, "the PC is running on battery" },
    .{ .power_saver, if (windows) "Windows battery saver is on" else "the power profile is Power Saver" },
    .{ .session_locked, "the screen is locked" },
    .{ .session_inactive, if (windows) "(not detected on Windows)" else "another user or a text console is in front" },
    .{ .remote_session, if (windows) "you're connected over Remote Desktop" else "you're signed in remotely" },
    .{ .game_mode, if (windows) "(not detected on Windows)" else "a game asked for Feral GameMode" },
};

/// The file's comments where the two OSes differ (paths, what is detected).
/// Everything else, including editing the file while zmural runs, is the same.
const comments = if (windows) struct {
    const folders =
        \\# Videos\Wallpapers and Pictures\Wallpapers are always scanned.
        \\# Example: folders = ['D:\Wallpapers', 'E:\Anime']
    ;
    const apps =
        \\# Apps that count as "app_rule" while in the foreground (their .exe names).
        \\# Example: apps = ["eldenring.exe", "obs64.exe"]
    ;
} else struct {
    const folders =
        \\# The Wallpapers folders in your Videos and Pictures folders are always scanned
        \\# (~/Videos/Wallpapers and ~/Pictures/Wallpapers, unless your desktop renamed them).
        \\# Example: folders = ["/mnt/media/Wallpapers", "/home/you/Anime"]
    ;
    const apps =
        \\# Apps that count as "app_rule" while in front: program names as the
        \\# process list shows them. Example: apps = ["steam", "eldenring.exe"]
    ;
};

pub const ParseError = toml.Error || error{UnknownValue};

/// Strings in the result live in `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: ?*toml.Diagnostic) ParseError!Settings {
    var s: Settings = .{};
    var monitors: std.ArrayList(MonitorWallpaper) = .empty;
    var fills: std.ArrayList(MonitorFill) = .empty;
    for (try toml.parse(arena, text, diag)) |e| {
        if (diag) |d| d.line = e.line;
        const t = e.table;
        const k = e.key;
        if (t.len == 0) {
            if (eql(k, "wallpaper")) s.wallpaper = try string(e.value);
        } else if (eql(t, "monitors")) {
            // Every key is a monitor ID; which ones are real is the runtime's call.
            try monitors.append(arena, .{ .monitor = k, .wallpaper = try string(e.value) });
        } else if (eql(t, "monitor_fill")) {
            try fills.append(arena, .{ .monitor = k, .fill = try enumValue(zmural.layout.FillMode, e.value) });
        } else if (eql(t, "playback")) {
            if (eql(k, "fill")) {
                s.fill = try enumValue(zmural.layout.FillMode, e.value);
            } else if (eql(k, "volume")) {
                s.volume = try int(u8, e.value);
                if (s.volume > 100) return error.BadValue;
            } else if (eql(k, "muted")) {
                s.muted = try boolean(e.value);
            } else if (eql(k, "paused")) {
                s.paused = try boolean(e.value);
            }
        } else if (eql(t, "rotation")) {
            if (eql(k, "every_minutes")) {
                s.rotate_minutes = try int(u16, e.value);
                if (s.rotate_minutes > zmural.protocol.control.max_rotate_minutes) return error.BadValue;
            } else if (eql(k, "order")) {
                s.order = try enumValue(Order, e.value);
            }
        } else if (eql(t, "library")) {
            if (eql(k, "folders")) s.library_dirs = try strings(e.value);
        } else if (eql(t, "pause")) {
            if (eql(k, "apps")) {
                s.app_rules = try strings(e.value);
            } else if (eql(k, "resume_after_ms")) {
                s.resume_after_ms = try int(u32, e.value);
            } else if (exposedRule(k)) |condition| {
                var rule = s.policy.rules.get(condition);
                rule.action = try enumValue(policy.Action, e.value);
                s.policy.rules.set(condition, rule);
            }
        }
        // Anything else: a newer zmural's key, left alone.
    }
    if (diag) |d| d.line = 0;
    s.monitor_wallpapers = monitors.items;
    s.monitor_fills = fills.items;
    return s;
}

pub fn write(out: *std.Io.Writer, s: *const Settings) std.Io.Writer.Error!void {
    try out.writeAll(
        \\# zmural settings
        \\#
        \\# The easy way to change these is the settings window (click the tray icon).
        \\# zmural keeps this file up to date. You can also edit it by hand, even
        \\# while zmural runs: it picks up your saved changes within a second.
        \\#
        \\# Unknown keys are ignored. If the file has a mistake, zmural starts with
        \\# its defaults, tells you the line number in its log, and leaves your file
        \\# untouched so you can fix it.
        \\
        \\# The wallpaper shown at startup: a video, image or animated GIF.
        \\# `zmural-console apply <file>`, Next and Previous change it.
        \\wallpaper
    );
    // Separators are written here: zig fmt strips trailing spaces inside multiline strings.
    try out.writeAll(" = ");
    try toml.writeString(out, s.wallpaper);
    try out.writeAll(
        \\
        \\
        \\[monitors]
        \\# A monitor listed here shows its own wallpaper instead of the one above:
        \\#   <monitor ID> = '<file>'
        \\# `zmural-console status` lists your monitors and their IDs.
        \\# `zmural-console apply <file> --monitor <number, name or ID>` adds a line,
        \\# `zmural-console follow --monitor ...` removes it, and `zmural-console apply <file>`
        \\# without --monitor puts one wallpaper on every monitor again.
        \\
    );
    for (s.monitor_wallpapers) |mw| {
        try out.print("{s} = ", .{mw.monitor});
        try toml.writeString(out, mw.wallpaper);
        try out.writeByte('\n');
    }
    try out.print(
        \\
        \\[playback]
        \\# How the wallpaper fills the screen:
        \\#   "crop"    fill the screen, trimming the edges (default)
        \\#   "fit"     show all of it, with bars if the shape doesn't match
        \\#   "stretch" fill the screen, ignoring the shape
        \\#   "center"  original size, centred
        \\fill = "{s}"
        \\# Wallpaper sound, 0 to 100. Wallpapers start muted; sound is opt-in.
        \\volume = {d}
        \\muted = {}
        \\# Paused by you (tray or `zmural-console pause`), on top of the automatic rules below.
        \\paused = {}
        \\
        \\[rotation]
        \\# Change the wallpaper by itself every this many minutes (0 = never, the
        \\# default; at most {d}, a week). Only playing time counts: while
        \\# wallpapers are paused or stopped, by you or by the rules below, the clock waits.
        \\# Changing the wallpaper yourself (apply, Next, Previous) starts the wait over.
        \\every_minutes = {d}
        \\# The order for these changes and for Next / Previous:
        \\#   "sequential" by name (default)
        \\#   "shuffle"    every wallpaper once per round, in a random order
        \\#   "random"     any other wallpaper, each time
        \\order = "{s}"
        \\
        \\[monitor_fill]
        \\# A monitor listed here fills its screen another way than `fill` above:
        \\#   <monitor ID> = "fit"
        \\# `zmural-console fill <mode> --monitor <number, name or ID>` adds a line and
        \\# `zmural-console fill default --monitor ...` removes it.
        \\
    , .{ @tagName(s.fill), s.volume, s.muted, s.paused, zmural.protocol.control.max_rotate_minutes, s.rotate_minutes, @tagName(s.order) });
    for (s.monitor_fills) |mf| try out.print("{s} = \"{s}\"\n", .{ mf.monitor, @tagName(mf.fill) });
    try out.writeAll(
        \\
        \\[library]
        \\# Extra folders to find wallpapers in (one level of subfolders is included).
        \\
    ++ comments.folders ++ "\n" ++
        \\folders
    );
    try out.writeAll(" = ");
    try toml.writeStrings(out, s.library_dirs);
    try out.writeAll(
        \\
        \\
        \\[pause]
        \\# What wallpapers do when something else needs the screen or the power:
        \\#   "none"   keep playing
        \\#   "mute"   keep playing without sound
        \\#   "pause"  freeze (uses no CPU or GPU)
        \\#   "stop"   close the wallpaper completely (frees its memory too);
        \\#            it starts again when the situation is over
        \\
    );
    for (pause_rules) |r| {
        const condition, const meaning = r;
        var key_buf: [32]u8 = undefined;
        const assign = std.fmt.bufPrint(&key_buf, "{s} = \"{s}\"", .{ @tagName(condition), @tagName(s.policy.rules.get(condition).action) }) catch unreachable; // zsnag:ok — short fixed names
        try out.print("{s:<30} # {s}\n", .{ assign, meaning });
    }
    try out.writeAll("\n" ++ comments.apps ++ "\napps");
    try out.writeAll(" = ");
    try toml.writeStrings(out, s.app_rules);
    try out.print(
        \\
        \\
        \\# How long to wait after the situation ends before playing again
        \\# (milliseconds), so a quick alt-tab doesn't make the wallpaper flicker.
        \\resume_after_ms = {d}
        \\
    , .{s.resume_after_ms});
}

/// Reads and writes `settings.toml` in one directory.
pub const Store = struct {
    io: std.Io,
    dir: []const u8,
    path: []const u8,
    /// The file exists but didn't parse: keep it, never overwrite it.
    read_only: bool = false,
    /// Why it didn't, for the user ("line 7 has a value zmural can't use").
    why_buf: [96]u8 = undefined,
    why_len: usize = 0,
    /// The user was told it doesn't read (`tellUnreadable`); again only after
    /// it has read fine in between.
    told: bool = false,
    /// `load` found no file: zmural's first run (nothing was ever changed).
    fresh: bool = false,

    /// `$ZMURAL_CONFIG_DIR`, else `%APPDATA%\zmural` (Windows) or
    /// `$XDG_CONFIG_HOME/zmural`, `~/.config/zmural` (Linux).
    pub fn open(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) !Store {
        const dir = if (environ.get("ZMURAL_CONFIG_DIR")) |d|
            try arena.dupe(u8, d)
        else if (builtin.os.tag == .windows)
            try std.fs.path.join(arena, &.{ environ.get("APPDATA") orelse ".", "zmural" })
        else if (zmural.os.xdg.dir(environ.get("XDG_CONFIG_HOME"))) |x|
            try std.fs.path.join(arena, &.{ x, "zmural" })
        else
            try std.fs.path.join(arena, &.{ environ.get("HOME") orelse ".", ".config", "zmural" });
        return .{ .io = io, .dir = dir, .path = try std.fs.path.join(arena, &.{ dir, file_name }) };
    }

    /// Defaults when the file doesn't exist yet or can't be parsed. A missing
    /// folder is made, so a hand-written settings.toml has somewhere to go.
    pub fn load(store: *Store, arena: std.mem.Allocator) Settings {
        const text = std.Io.Dir.cwd().readFileAlloc(store.io, store.path, arena, .limited(1 << 20)) catch |err| {
            if (err == error.FileNotFound) {
                store.fresh = true;
                std.Io.Dir.cwd().createDirPath(store.io, store.dir) catch |e|
                    std.log.warn("settings: cannot make {s} ({s})", .{ store.dir, @errorName(e) });
            } else {
                std.log.warn("settings: cannot read {s} ({s}); using defaults and leaving it alone", .{ store.path, @errorName(err) });
                store.read_only = true;
                store.setWhy("it can't be read ({s})", .{@errorName(err)});
            }
            return .{};
        };
        var diag: toml.Diagnostic = .{};
        const s = parse(arena, text, &diag) catch |err| {
            std.log.warn("settings: {s} line {d}: {s}; using defaults and leaving the file alone", .{ store.path, diag.line, @errorName(err) });
            store.read_only = true;
            switch (err) {
                error.BadValue => store.setWhy("line {d} has a value zmural can't use", .{diag.line}),
                error.SyntaxError => store.setWhy("line {d} isn't written the way the file's format needs", .{diag.line}),
                error.OutOfMemory => store.setWhy("it is too large", .{}),
                else => store.setWhy("line {d} has a value zmural doesn't know ({s})", .{ diag.line, @errorName(err) }),
            }
            return .{};
        };
        store.told = false;
        return s;
    }

    fn setWhy(store: *Store, comptime fmt: []const u8, args: anytype) void {
        store.why_len = if (std.fmt.bufPrint(&store.why_buf, fmt, args)) |w| w.len else |_| 0;
    }

    /// What to tell the user once when the file doesn't read; null when it
    /// reads, or they were told. `title`, `body` live in `buf`.
    pub fn unreadableNotice(store: *Store, buf: []u8) ?struct { title: []const u8, body: []const u8 } {
        if (!store.read_only or store.told) return null;
        const title = "zmural can't use settings.toml";
        const body = std.fmt.bufPrint(buf, "{s}: {s}. zmural keeps its current settings and won't change the file until it reads again.", .{ store.path, store.why_buf[0..store.why_len] }) catch return null;
        return .{ .title = title, .body = body };
    }

    /// Writes atomically (temp file, then rename).
    pub fn save(store: *const Store, gpa: std.mem.Allocator, s: *const Settings) void {
        if (store.read_only) return;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        write(&out.writer, s) catch return;
        const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{store.path}) catch return;
        defer gpa.free(tmp);
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(store.io, store.dir) catch |err| return warnSave(store, err);
        cwd.writeFile(store.io, .{ .sub_path = tmp, .data = out.written() }) catch |err| return warnSave(store, err);
        cwd.rename(tmp, cwd, store.path, store.io) catch |err| return warnSave(store, err);
    }
};

/// Is this one of the rules the settings window offers (this OS detects it)?
pub fn isExposed(c: policy.Condition) bool {
    return std.mem.findScalar(policy.Condition, detected, c) != null;
}

/// A `[pause]` key naming one of the rules the file offers (not internal ones).
fn exposedRule(key: []const u8) ?policy.Condition {
    for (pause_rules) |r| if (eql(key, @tagName(r[0]))) return r[0];
    return null;
}

fn warnSave(store: *const Store, err: anyerror) void {
    std.log.warn("settings: cannot save {s}: {s}", .{ store.path, @errorName(err) });
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn string(v: toml.Value) ParseError![]const u8 {
    return if (v == .string) v.string else error.BadValue;
}

fn boolean(v: toml.Value) ParseError!bool {
    return if (v == .boolean) v.boolean else error.BadValue;
}

fn strings(v: toml.Value) ParseError![]const []const u8 {
    return if (v == .strings) v.strings else error.BadValue;
}

fn int(comptime T: type, v: toml.Value) ParseError!T {
    if (v != .int) return error.BadValue;
    return std.math.cast(T, v.int) orelse error.BadValue;
}

fn enumValue(comptime E: type, v: toml.Value) ParseError!E {
    return std.meta.stringToEnum(E, try string(v)) orelse error.UnknownValue;
}

test "settings survive a write/read round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var original: Settings = .{
        .wallpaper = "C:\\Users\\me\\Videos\\it's rain.mp4",
        .fill = .fit,
        .volume = 30,
        .muted = false,
        .paused = true,
        .resume_after_ms = 1500,
        .rotate_minutes = 45,
        .order = .random,
        .app_rules = &.{ "eldenring.exe", "cs2.exe" },
        .library_dirs = &.{"D:\\Wallpapers"},
    };
    original.policy.rules.set(.on_battery, .{ .action = .stop, .scope = .all });
    original.policy.rules.set(.focused, .{ .action = .mute });

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, &original);
    const back = try parse(arena.allocator(), out.written(), null);
    try std.testing.expectEqualStrings(original.wallpaper, back.wallpaper);
    try std.testing.expectEqual(original.fill, back.fill);
    try std.testing.expectEqual(original.volume, back.volume);
    try std.testing.expectEqual(original.muted, back.muted);
    try std.testing.expectEqual(original.paused, back.paused);
    try std.testing.expectEqual(original.resume_after_ms, back.resume_after_ms);
    try std.testing.expectEqual(original.rotate_minutes, back.rotate_minutes);
    try std.testing.expectEqual(original.order, back.order);
    try std.testing.expectEqualStrings("cs2.exe", back.app_rules[1]);
    try std.testing.expectEqualStrings("D:\\Wallpapers", back.library_dirs[0]);
    try std.testing.expectEqual(policy.Action.stop, back.policy.rules.get(.on_battery).action);
    try std.testing.expectEqual(policy.Action.mute, back.policy.rules.get(.focused).action);
    // Scopes aren't in the file; they keep their defaults.
    try std.testing.expectEqual(policy.Scope.all, back.policy.rules.get(.fullscreen).scope);
}

test "monitors with their own wallpaper survive a write/read round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s: Settings = .{
        .wallpaper = "/wp/main.mp4",
        .monitor_wallpapers = &.{
            .{ .monitor = "m-0123456789abcdef", .wallpaper = "/wp/it's here.mp4" },
            .{ .monitor = "m-fedcba9876543210", .wallpaper = "/wp/b.png" },
        },
        .monitor_fills = &.{.{ .monitor = "m-fedcba9876543210", .fill = .fit }},
    };
    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try write(&out, &s);
    const back = try parse(arena.allocator(), out.buffered(), null);
    try std.testing.expectEqualStrings("/wp/main.mp4", back.wallpaper);
    try std.testing.expectEqual(@as(usize, 2), back.monitor_wallpapers.len);
    try std.testing.expectEqualStrings("m-0123456789abcdef", back.monitor_wallpapers[0].monitor);
    try std.testing.expectEqualStrings("/wp/it's here.mp4", back.monitor_wallpapers[0].wallpaper);
    try std.testing.expectEqualStrings("/wp/b.png", back.monitor_wallpapers[1].wallpaper);
    try std.testing.expectEqual(@as(usize, 1), back.monitor_fills.len);
    try std.testing.expectEqualStrings("m-fedcba9876543210", back.monitor_fills[0].monitor);
    try std.testing.expectEqual(zmural.layout.FillMode.fit, back.monitor_fills[0].fill);
    try std.testing.expectError(error.UnknownValue, parse(arena.allocator(), "[monitor_fill]\nm-0123456789abcdef = \"zoom\"\n", null));
    // The playback table still follows and still parses.
    try std.testing.expectEqual(s.volume, back.volume);

    // None: the table is there, empty.
    out = .fixed(&buf);
    try write(&out, &.{});
    try std.testing.expectEqual(@as(usize, 0), (try parse(arena.allocator(), out.buffered(), null)).monitor_wallpapers.len);
    // A path that isn't a string is a mistake in the file.
    try std.testing.expectError(error.BadValue, parse(arena.allocator(), "[monitors]\nm-0123456789abcdef = 3\n", null));
}

test "unknown keys are ignored, bad values rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try parse(a, "future_key = 1\n[playback]\nvolume = 20\n[someday]\nx = 1\n[pause]\nother_audio = \"stop\"\ngame_mode = \"stop\"\n", null);
    try std.testing.expectEqual(@as(u8, 20), s.volume);
    // Rules zmural detects nowhere yet aren't settable from the file.
    try std.testing.expectEqual(policy.Action.mute, s.policy.rules.get(.other_audio).action);
    try std.testing.expectEqual(policy.Action.stop, s.policy.rules.get(.game_mode).action);
    try std.testing.expectError(error.BadValue, parse(a, "[playback]\nvolume = 300\n", null));
    try std.testing.expectError(error.UnknownValue, parse(a, "[playback]\nfill = \"zoom\"\n", null));
    try std.testing.expectError(error.UnknownValue, parse(a, "[pause]\nfullscreen = \"puase\"\n", null));
    try std.testing.expectError(error.BadValue, parse(a, "[playback]\nmuted = \"yes\"\n", null));
    try std.testing.expectError(error.BadValue, parse(a, "[rotation]\nevery_minutes = 10081\n", null));
    try std.testing.expectError(error.BadValue, parse(a, "[rotation]\nevery_minutes = -1\n", null));
    try std.testing.expectError(error.UnknownValue, parse(a, "[rotation]\norder = \"shufle\"\n", null));
    const edge = try parse(a, "[rotation]\nevery_minutes = 10080\norder = \"shuffle\"\n", null);
    try std.testing.expectEqual(@as(u16, 10080), edge.rotate_minutes);
    try std.testing.expectEqual(Order.shuffle, edge.order);
}

test "the file's comments are worded for this OS" {
    var buf: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try write(&out, &.{});
    const text = out.buffered();
    // The OS-specific lines sit directly under the shared ones.
    try std.testing.expect(std.mem.find(u8, text, "is included).\n" ++ comments.folders ++ "\nfolders = ") != null);
    try std.testing.expect(std.mem.find(u8, text, "\n\n" ++ comments.apps ++ "\napps = ") != null);
    if (windows) {
        try std.testing.expect(std.mem.find(u8, text, "Videos\\Wallpapers") != null);
        try std.testing.expect(std.mem.find(u8, text, "~/") == null);
    } else {
        try std.testing.expect(std.mem.find(u8, text, "~/Videos/Wallpapers") != null);
        // (".exe" does appear: a Windows game under Proton keeps its name.)
        try std.testing.expect(std.mem.find(u8, text, "\\") == null);
    }
    // Still a file that parses back to the defaults.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const back = try parse(arena.allocator(), text, null);
    try std.testing.expectEqual((Settings{}).resume_after_ms, back.resume_after_ms);
}

test "a first start makes the settings folder, so a hand-written file has a place" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var dir_buf: [256]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const a = arena.allocator();
    const dir = try std.fs.path.join(a, &.{ dir_buf[0..dir_len], "config", "zmural" });
    var store: Store = .{ .io = io, .dir = dir, .path = try std.fs.path.join(a, &.{ dir, file_name }) };
    _ = store.load(a);
    try std.testing.expect(!store.read_only);
    try std.testing.expect(store.fresh);
    // Once something was saved, a start is no longer the first.
    store.save(std.testing.allocator, &.{});
    var again: Store = .{ .io = io, .dir = dir, .path = store.path };
    _ = again.load(a);
    try std.testing.expect(!again.fresh);
    // Last: Wine's dir-relative `access` wrongly says FileNotFound.
    try tmp.dir.access(io, "config/zmural", .{});
}
