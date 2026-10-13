// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zmural-console: the command line. A remote control for the running zmural. Every command becomes one
//! `protocol.control` request.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");
const words = @import("words.zig");
const control = zmural.protocol.control;
const Request = control.Request;

const usage =
    \\usage: zmural-console <command> [options]
    \\
    \\commands:
    \\  status                          show what's playing, and on which monitors
    \\  apply <path>                    show a wallpaper on every monitor
    \\  apply <path> --monitor M        give one monitor a wallpaper of its own
    \\  follow --monitor M              that monitor shows the main wallpaper again
    \\  next | previous [--monitor M]   step through the library
    \\  fill crop|fit|stretch|center [--monitor M]   how the wallpaper fills the screen
    \\  fill default --monitor M        that monitor uses the main fill mode again
    \\  pause | play                    pause or resume playback
    \\  rotate <minutes> | off          change the wallpaper by itself that often
    \\  order sequential|shuffle|random the order for rotation and next/previous
    \\  shuffle on|off                  the same as order shuffle / order sequential
    \\  mute | unmute                   toggle wallpaper audio
    \\  rescan                          rescan the library folders
    \\  import <file.zip> [--to <folder>] [--apply]
    \\                                  unpack a wallpaper package or a zip of videos
    \\                                  and pictures into a library folder (checked first)
    \\  export <wallpaper> [<file.zip>]  pack a wallpaper (its path, or its name in the
    \\                                  library), a package or a folder of them
    \\                                  into a zip that imports anywhere
    \\  props                           list the wallpaper's properties
    \\  prop <name> <value>             change one (e.g. prop brightness -20; speed is for videos)
    \\  prop --reset                    put them all back to their defaults
    \\  quit                            stop zmural
    \\  autostart on|off|status         start zmural when you log in
    \\  uninstall [--yes]               remove zmural's settings, menu entry, start at
    \\                                  login and desktop plugin (your wallpapers stay)
    \\  version | help
    \\
    \\M is a monitor's number, name or ID, as `zmural-console status` lists them.
    \\
;

pub const ParseError = error{ MissingCommand, UnknownCommand, MissingArgument, UnexpectedArgument, BadValue };

/// Parses the arguments after argv[0] into a control request.
pub fn parse(args: []const []const u8) ParseError!Request {
    if (args.len == 0) return error.MissingCommand;
    const cmd = args[0];
    const rest = args[1..];
    // `version` alone is answered before parsing; with more after it, it lands here.
    if (eql(cmd, "version") or eql(cmd, "--version")) return error.UnexpectedArgument;

    if (eql(cmd, "status")) return noArgs(rest, .status);
    if (eql(cmd, "rescan")) return noArgs(rest, .rescan);
    if (eql(cmd, "quit")) return noArgs(rest, .quit);
    if (eql(cmd, "mute")) return noArgs(rest, .{ .set_muted = .{ .muted = true } });
    if (eql(cmd, "unmute")) return noArgs(rest, .{ .set_muted = .{ .muted = false } });
    if (eql(cmd, "pause")) return .{ .pause = try target(rest) };
    if (eql(cmd, "play")) return .{ .play = try target(rest) };
    if (eql(cmd, "next")) return .{ .next = try target(rest) };
    if (eql(cmd, "previous")) return .{ .previous = try target(rest) };
    if (eql(cmd, "props")) return noArgs(rest, .get_properties);
    if (eql(cmd, "rotate")) {
        const arg = try oneArg(rest);
        if (eql(arg, "off")) return .{ .set_rotation = .{ .minutes = 0 } };
        const m = std.fmt.parseUnsigned(u16, arg, 10) catch return error.BadValue;
        if (m > control.max_rotate_minutes) return error.BadValue;
        return .{ .set_rotation = .{ .minutes = m } };
    }
    if (eql(cmd, "order")) {
        const o = std.meta.stringToEnum(control.Order, try oneArg(rest)) orelse return error.BadValue;
        return .{ .set_rotation = .{ .order = o } };
    }
    if (eql(cmd, "shuffle")) {
        const arg = try oneArg(rest);
        if (eql(arg, "on")) return .{ .set_rotation = .{ .order = .shuffle } };
        if (eql(arg, "off")) return .{ .set_rotation = .{ .order = .sequential } };
        return error.BadValue;
    }
    if (eql(cmd, "prop")) {
        if (rest.len == 1 and eql(rest[0], "--reset")) return .reset_properties;
        if (rest.len < 2) return error.MissingArgument;
        if (rest.len > 2) return error.UnexpectedArgument;
        return .{ .set_property = .{ .name = rest[0], .value = rest[1] } };
    }
    if (eql(cmd, "apply")) {
        const m = try withMonitor(rest);
        if (m.arg.len == 0) return error.MissingArgument;
        return .{ .apply = .{ .path = m.arg, .monitor = m.monitor } };
    }
    if (eql(cmd, "fill")) {
        const m = try withMonitor(rest);
        if (m.arg.len == 0) return error.MissingArgument;
        const t: control.Target = .{ .monitor = m.monitor };
        if (eql(m.arg, "default")) {
            if (t.monitor.len == 0) return error.MissingArgument;
            return .{ .set_fill = .{ .fill = .crop, .monitor = t.monitor, .main = true } };
        }
        const mode = std.meta.stringToEnum(@FieldType(control.SetFill, "fill"), m.arg) orelse return error.BadValue;
        return .{ .set_fill = .{ .fill = mode, .monitor = t.monitor } };
    }
    if (eql(cmd, "follow")) {
        // An apply with no path: the monitor goes back to the main wallpaper.
        const t = try target(rest);
        if (t.monitor.len == 0) return error.MissingArgument;
        return .{ .apply = .{ .path = "", .monitor = t.monitor } };
    }
    return error.UnknownCommand;
}

fn oneArg(rest: []const []const u8) ParseError![]const u8 {
    if (rest.len == 0) return error.MissingArgument;
    if (rest.len > 1) return error.UnexpectedArgument;
    return rest[0];
}

fn noArgs(rest: []const []const u8, req: Request) ParseError!Request {
    if (rest.len != 0) return error.UnexpectedArgument;
    return req;
}

fn target(rest: []const []const u8) ParseError!control.Target {
    if (rest.len == 0) return .{};
    if (!eql(rest[0], "--monitor")) return error.UnexpectedArgument;
    if (rest.len < 2) return error.MissingArgument;
    if (rest.len > 2) return error.UnexpectedArgument;
    return .{ .monitor = rest[1] };
}

/// One argument and an optional `--monitor M`, in either order.
fn withMonitor(rest: []const []const u8) ParseError!struct { arg: []const u8, monitor: []const u8 } {
    var arg: []const u8 = "";
    var monitor: []const u8 = "";
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (eql(rest[i], "--monitor")) {
            if (monitor.len > 0) return error.UnexpectedArgument;
            i += 1;
            if (i == rest.len or rest[i].len == 0) return error.MissingArgument;
            monitor = rest[i];
        } else if (std.mem.startsWith(u8, rest[i], "--") or arg.len > 0) {
            return error.UnexpectedArgument;
        } else arg = rest[i];
    }
    return .{ .arg = arg, .monitor = monitor };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Exit codes: 0 ok, 1 the daemon refused, 2 bad usage, 3 the daemon isn't running.
pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const args = argv[1..];

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &stdout.interface;

    if (args.len > 0 and (eql(args[0], "help") or eql(args[0], "--help"))) {
        try out.writeAll(usage);
        return out.flush();
    }
    if (args.len == 1 and (eql(args[0], "version") or eql(args[0], "--version"))) {
        try out.print("zmural-console {s}\n", .{zmural.version});
        return out.flush();
    }

    if (args.len > 0 and eql(args[0], "autostart")) return autostart(init, out, args[1..]);
    if (args.len > 0 and eql(args[0], "uninstall")) return uninstall(init, out, args[1..]);
    if (args.len > 0 and eql(args[0], "import")) return @import("import.zig").run(init, out, args[1..]);
    if (args.len > 0 and eql(args[0], "export")) return @import("import.zig").runExport(init, out, args[1..]);

    var req = parse(args) catch |err| {
        const hint: []const u8 = if (args.len > 0 and eql(args[0], "rotate") and err == error.BadValue)
            std.fmt.comptimePrint(": minutes from 1 to {d}, or off", .{control.max_rotate_minutes})
        else
            "";
        std.log.err("zmural-console: {s}{s}; see `zmural-console help`", .{ words.of(err), hint });
        std.process.exit(2);
    };
    if (builtin.os.tag == .linux) return runLinux(init, out, req);
    if (builtin.os.tag != .windows) {
        std.log.err("zmural-console: only Windows and Linux are supported", .{});
        std.process.exit(1);
    }
    // The daemon runs elsewhere, so relative paths are resolved here.
    const client = zmural.sdk.control_client;
    if (req == .apply and req.apply.path.len > 0) req.apply.path = try client.absolutePath(arena, req.apply.path);

    var addr_buf: [256]u8 = undefined;
    const addr = try client.address(&addr_buf);
    const c = client.Client.connect(init.gpa, addr, "zmural-console") catch |err| switch (err) {
        error.DaemonNotRunning => {
            std.log.err("zmural-console: zmural is not running", .{});
            std.process.exit(3);
        },
        error.ForeignServer => {
            std.log.err("zmural-console: the process answering on zmural's pipe belongs to another account; refusing to talk to it", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer c.close(init.gpa);

    const reply = c.request(req) catch |err| {
        std.log.err("zmural-console: zmural stopped answering ({s}); try again", .{words.of(err)});
        c.close(init.gpa);
        std.process.exit(1);
    };
    if (!try report(arena, out, reply) or !waitShown(c, req)) {
        // Closed by hand: exit skips the deferred close.
        c.close(init.gpa);
        std.process.exit(1);
    }
    // Status also lists the monitors, where the daemon can say.
    if (req == .status) switch (c.request(.monitors) catch return) {
        // Whoever reads us may have had enough already (`zmural-console status | head -1`).
        .monitors => |m| printMonitors(out, m.list) catch {}, // zsnag:ok — a closed pipe is not an error here
        else => {},
    };
}

fn runLinux(init: std.process.Init, out: *std.Io.Writer, request: Request) !void {
    const arena = init.arena.allocator();
    const client = zmural.sdk.control_client_linux;
    var req = request;
    if (req == .apply and req.apply.path.len > 0) req.apply.path = try client.absolutePath(arena, req.apply.path);
    var addr_buf: [256]u8 = undefined;
    const addr = client.address(&addr_buf, zmural.os.xdg.dir(init.environ_map.get("XDG_RUNTIME_DIR"))) catch {
        std.log.err("zmural-console: $XDG_RUNTIME_DIR is not set", .{});
        std.process.exit(1);
    };
    // The slowest real request (switching wallpapers) takes about 2 s.
    const c = client.Client.connect(init.gpa, addr, "zmural-console", 10_000) catch |err| switch (err) {
        error.DaemonNotRunning => {
            std.log.err("zmural-console: zmural is not running", .{});
            std.process.exit(3);
        },
        error.ForeignServer => {
            std.log.err("zmural-console: the process on zmural's socket belongs to another user; refusing to talk to it", .{});
            std.process.exit(1);
        },
        else => {
            // Turned away for 3 s (zmural serving many commands at once), or gone.
            std.log.err("zmural-console: zmural didn't take the command ({s}); try again", .{words.of(err)});
            std.process.exit(1);
        },
    };
    defer c.close(init.gpa);
    const reply = c.request(req) catch |err| {
        std.log.err("zmural-console: zmural stopped answering ({s}); try again", .{words.of(err)});
        c.close(init.gpa);
        std.process.exit(1);
    };
    if (!try report(arena, out, reply) or !waitShown(c, req)) {
        // Closed by hand: exit skips the deferred close.
        c.close(init.gpa);
        std.process.exit(1);
    }
    // Status also lists the monitors, where the daemon can say.
    if (req == .status) switch (c.request(.monitors) catch return) {
        // Whoever reads us may have had enough already (`zmural-console status | head -1`).
        .monitors => |m| printMonitors(out, m.list) catch {}, // zsnag:ok — a closed pipe is not an error here
        else => {},
    };
}

/// After an accepted `apply` of the main wallpaper: waits until zmural shows
/// it, or says it can't (the renderer finds out only once it tries), so the
/// exit status tells a script what happened. False when it can't be shown.
/// Gives up waiting after a while (a slow first frame, no monitor to show it
/// on) and counts that as shown: nothing said it failed.
fn waitShown(c: anytype, req: Request) bool {
    if (req != .apply or req.apply.monitor.len > 0 or req.apply.path.len == 0) return true;
    const path = req.apply.path;
    for (0..apply_wait_ms / apply_poll_ms) |_| {
        const s = switch (c.request(.status) catch return true) {
            .status => |s| s,
            else => return true,
        };
        if (s.monitors == 0 or eql(s.shown, path)) return true;
        if (eql(s.broken, path)) {
            std.log.err("zmural-console: zmural can't show it: {s}", .{s.broken_why});
            return false;
        }
        sleepMs(apply_poll_ms);
    }
    return true;
}

const apply_wait_ms = 6000;
const apply_poll_ms = 100;

fn sleepMs(ms: u64) void {
    switch (builtin.os.tag) {
        .windows => zmural.os.win32.Sleep(@intCast(ms)),
        else => {
            const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
            _ = std.os.linux.nanosleep(&ts, null);
        },
    }
}

/// One line per monitor: its number, name, size, ID, and what it shows.
fn printMonitors(out: *std.Io.Writer, list: []const u8) !void {
    var lines = std.mem.splitScalar(u8, list, control.list_sep);
    var n: usize = 1;
    while (lines.next()) |line| : (n += 1) {
        const m = control.parseMonitorLine(line) orelse continue;
        try out.print("  {d}  {s:<10} {s:<10} {s}  {s}", .{ n, m.name, m.size, m.id, if (m.wallpaper.len > 0) m.wallpaper else "(the main wallpaper)" });
        if (m.fill.len > 0) try out.print("  [fill: {s}]", .{m.fill});
        try out.writeByte('\n');
    }
    try out.flush();
}

/// Prints the reply; false when it was an error (already said on stderr).
fn report(arena: std.mem.Allocator, out: *std.Io.Writer, reply: control.Event) !bool {
    switch (reply) {
        .ok => {},
        .status => |s| {
            var pb: [600]u8 = undefined;
            var mb: [600]u8 = undefined;
            try out.print(
            \\wallpaper : {s}
            \\paused    : {s}
            \\muted     : {s}
            \\fill      : {s}
            \\monitors  : {d}
            \\library   : {d} wallpapers
            \\order     : {s}
            \\rotation  :
        , .{ if (s.wallpaper.len == 0) "(none)" else s.wallpaper, held(&pb, s.paused, "by you", s.paused_by), held(&mb, s.muted, "the setting", s.muted_by), @tagName(s.fill), s.monitors, s.wallpapers, @tagName(s.order) });
            if (s.rotate_minutes == 0) {
                try out.writeAll(" off\n");
            } else {
                const t = s.next_change_s;
                if (t >= 3600)
                    try out.print(" every {d} min; next in {d}:{d:0>2}:{d:0>2} of playing time\n", .{ s.rotate_minutes, t / 3600, t / 60 % 60, t % 60 })
                else
                    try out.print(" every {d} min; next in {d}:{d:0>2} of playing time\n", .{ s.rotate_minutes, t / 60, t % 60 });
            }
            if (s.crash.len > 0) try out.print("crash     : {s}\n", .{s.crash});
        },
        .properties => |p| try printProperties(arena, out, p),
        .failed => |f| {
            std.log.err("zmural-console: {s} ({s})", .{ f.message, @tagName(f.code) });
            return false;
        },
        else => |ev| {
            std.log.err("zmural-console: unexpected reply '{s}'", .{@tagName(ev)});
            return false;
        },
    }
    try out.flush();
    return true;
}

/// Asks first, then has zmural remove itself (`zmural --uninstall`, which
/// knows every place it put something).
fn uninstall(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !void {
    const yes = args.len == 1 and eql(args[0], "--yes");
    if (args.len > 1 or (args.len == 1 and !yes)) {
        std.log.err("zmural-console: usage: zmural-console uninstall [--yes]", .{});
        std.process.exit(2);
    }
    if (!yes) {
        try out.writeAll(
            \\This stops zmural and removes what it added to this computer: start at
            \\login, its menu entry and icons, its desktop plugin or extension, and
            \\its settings and log. Your wallpapers and their folders are not touched.
            \\
            \\Remove zmural? [y/N] 
        );
        try out.flush();
        var in_buf: [64]u8 = undefined;
        var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
        const answer = stdin.interface.takeDelimiter('\n') catch null orelse "";
        const a = std.mem.trim(u8, answer, " \t\r");
        if (!(eql(a, "y") or eql(a, "Y") or eql(a, "yes"))) {
            try out.writeAll("Nothing was removed.\n");
            return out.flush();
        }
    }
    const arena = init.arena.allocator();
    const exe = try std.fs.path.join(arena, &.{ try std.process.executableDirPathAlloc(init.io, arena), if (builtin.os.tag == .windows) "zmural.exe" else "zmural" });
    var child = std.process.spawn(init.io, .{ .argv = &.{ exe, "--uninstall" } }) catch |err| {
        std.log.err("zmural-console: can't run {s}: {s}", .{ exe, words.of(err) });
        std.process.exit(1);
    };
    const term = try child.wait(init.io);
    std.process.exit(switch (term) {
        .exited => |code| code,
        else => 1,
    });
}

fn autostart(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !void {
    if (builtin.os.tag == .linux) return autostartLinux(init, out, args);
    if (builtin.os.tag != .windows) {
        std.log.err("zmural-console: autostart is for Windows and Linux", .{});
        std.process.exit(1);
    }
    const reg = zmural.os.autostart;
    const what = if (args.len == 1) args[0] else "";
    var buf: [2048]u8 = undefined;
    if (eql(what, "on")) {
        const exe = try zmural.os.process.siblingExe(init.arena.allocator(), "zmural.exe");
        reg.enable(exe) catch |err| {
            std.log.err("zmural-console: could not register autostart: {s}", .{words.of(err)});
            std.process.exit(1);
        };
        try out.print("zmural will start when you log in ({s})\n", .{exe});
    } else if (eql(what, "off")) {
        reg.disable() catch |err| {
            std.log.err("zmural-console: could not remove autostart: {s}", .{words.of(err)});
            std.process.exit(1);
        };
        try out.writeAll("zmural will no longer start when you log in\n");
    } else if (eql(what, "status")) {
        if (reg.status(&buf)) |cmd| {
            try out.print("on: {s}\n", .{cmd});
        } else {
            try out.writeAll("off\n");
        }
    } else {
        std.log.err("zmural-console: usage: zmural-console autostart on|off|status", .{});
        std.process.exit(2);
    }
    try out.flush();
}

/// Linux: the XDG autostart entry is the setting (see `os/autostart_linux.zig`).
/// "off" keeps the file with `Hidden=true`, so zmural remembers the choice.
fn autostartLinux(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const al = zmural.os.autostart_linux;
    const env = init.environ_map;
    const entry = try al.path(arena, zmural.os.xdg.dir(env.get("XDG_CONFIG_HOME")), env.get("HOME") orelse "/");
    const exe = try std.fs.path.join(arena, &.{ try std.process.executableDirPathAlloc(init.io, arena), "zmural" });
    const what = if (args.len == 1) args[0] else "";
    if (eql(what, "on") or eql(what, "off")) {
        const on = eql(what, "on");
        al.write(init.io, entry, exe, on) catch |err| {
            std.log.err("zmural-console: could not write {s}: {s}", .{ entry, words.of(err) });
            std.process.exit(1);
        };
        if (on) {
            try out.print("zmural will start when you log in ({s})\n", .{entry});
        } else {
            try out.writeAll("zmural will no longer start when you log in\n");
        }
    } else if (eql(what, "status")) {
        try out.print("{s} ({s})\n", .{ switch (al.state(init.io, entry)) {
            .on => "on",
            .off => "off",
            .unset => "not set up yet (zmural turns it on when it first runs)",
        }, entry });
    } else {
        std.log.err("zmural-console: usage: zmural-console autostart on|off|status", .{});
        std.process.exit(2);
    }
    try out.flush();
}

fn printProperties(arena: std.mem.Allocator, out: *std.Io.Writer, p: control.Properties) !void {
    if (p.title.len == 0) return out.writeAll("this wallpaper has no properties (only wallpaper packages do)\n");
    try out.print("{s}\n", .{p.title});
    const items = zmural.properties.parseList(arena, p.list) catch {
        std.log.err("zmural-console: unreadable property list", .{});
        std.process.exit(1);
    };
    if (items.len == 0) return out.writeAll("  (no properties)\n");
    for (items) |it| {
        try out.print("  {s} = {s}", .{ it.name, it.value });
        switch (it.kind) {
            .slider => try out.print("   ({d} to {d})", .{ it.min, it.max }),
            .checkbox => try out.writeAll("   (true or false)"),
            .color => try out.writeAll("   (#rrggbb)"),
            .dropdown => {
                try out.writeAll("   (");
                for (it.options, 0..) |o, i| try out.print("{s}{s}", .{ if (i > 0) " | " else "", o });
                try out.writeAll(")");
            },
            .text => {},
        }
        if (!eql(it.label, it.name)) try out.print("   {s}", .{it.label});
        try out.writeByte('\n');
    }
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

/// "no", "yes (by you)", "yes (fullscreen, game_mode)" or both: the rule
/// names are the `[pause]` keys in settings.toml. `user` names the switch
/// itself: "by you" for a pause, but zmural starts muted, so a mute is "the
/// setting" until someone changes it.
fn held(buf: []u8, by_user: bool, user: []const u8, by_rules: []const u8) []const u8 {
    if (!by_user and by_rules.len == 0) return "no";
    return std.fmt.bufPrint(buf, "yes ({s}{s}{s})", .{
        if (by_user) user else "",
        if (by_user and by_rules.len > 0) "; " else "",
        by_rules,
    }) catch "yes";
}

test "status says who paused the wallpaper" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("no", held(&buf, false, "by you", ""));
    try std.testing.expectEqualStrings("yes (by you)", held(&buf, true, "by you", ""));
    try std.testing.expectEqualStrings("yes (fullscreen, game_mode)", held(&buf, false, "by you", "fullscreen, game_mode"));
    try std.testing.expectEqualStrings("yes (by you; session_locked)", held(&buf, true, "by you", "session_locked"));
    try std.testing.expectEqualStrings("yes (the setting; fullscreen)", held(&buf, true, "the setting", "fullscreen"));
}

test "property commands" {
    try std.testing.expectEqual(Request.get_properties, try parse(&.{"props"}));
    try std.testing.expectEqual(Request.reset_properties, try parse(&.{ "prop", "--reset" }));
    const set = try parse(&.{ "prop", "speed", "1.5" });
    try std.testing.expectEqualStrings("speed", set.set_property.name);
    try std.testing.expectEqualStrings("1.5", set.set_property.value);
    try std.testing.expectError(error.MissingArgument, parse(&.{ "prop", "speed" }));
}

test parse {
    const r = try parse(&.{ "apply", "C:\\wp\\rain", "--monitor", "m-00" });
    try std.testing.expectEqualStrings("C:\\wp\\rain", r.apply.path);
    try std.testing.expectEqualStrings("m-00", r.apply.monitor);

    // The monitor may come first too.
    const r2 = try parse(&.{ "apply", "--monitor", "1", "/wp/rain.mp4" });
    try std.testing.expectEqualStrings("/wp/rain.mp4", r2.apply.path);
    try std.testing.expectEqualStrings("1", r2.apply.monitor);
    try std.testing.expectEqualStrings("", (try parse(&.{ "apply", "/wp/rain.mp4" })).apply.monitor);
    try std.testing.expectError(error.MissingArgument, parse(&.{ "apply", "--monitor", "1" }));
    try std.testing.expectError(error.MissingArgument, parse(&.{ "apply", "/wp/rain.mp4", "--monitor" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "apply", "a.mp4", "b.mp4" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "apply", "a.mp4", "--monitor", "1", "--monitor", "2" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "apply", "--paused", "a.mp4" }));
    try std.testing.expect((try parse(&.{ "fill", "--monitor", "2", "fit" })).set_fill.fill == .fit);

    const f = try parse(&.{ "follow", "--monitor", "2" });
    try std.testing.expectEqualStrings("", f.apply.path);
    try std.testing.expectEqualStrings("2", f.apply.monitor);
    try std.testing.expectError(error.MissingArgument, parse(&.{"follow"}));
    const fl = try parse(&.{ "fill", "fit", "--monitor", "2" });
    try std.testing.expect(fl.set_fill.fill == .fit and !fl.set_fill.main);
    try std.testing.expectEqualStrings("2", fl.set_fill.monitor);
    try std.testing.expectEqualStrings("", (try parse(&.{ "fill", "stretch" })).set_fill.monitor);
    try std.testing.expect((try parse(&.{ "fill", "default", "--monitor", "DP-1" })).set_fill.main);
    try std.testing.expectError(error.MissingArgument, parse(&.{ "fill", "default" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "fill", "zoom" }));
    try std.testing.expectEqualStrings("HDMI-A-1", (try parse(&.{ "next", "--monitor", "HDMI-A-1" })).next.monitor);

    try std.testing.expectEqualStrings("", (try parse(&.{"pause"})).pause.monitor);
    try std.testing.expect((try parse(&.{"mute"})).set_muted.muted);
    try std.testing.expectEqual(control.RequestOp.status, std.meta.activeTag(try parse(&.{"status"})));

    try std.testing.expectError(error.MissingCommand, parse(&.{}));
    try std.testing.expectError(error.UnknownCommand, parse(&.{"dance"}));
    try std.testing.expectError(error.MissingArgument, parse(&.{"apply"}));
    try std.testing.expectError(error.MissingArgument, parse(&.{ "next", "--monitor" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "status", "now" }));
}

test "rotation commands" {
    try std.testing.expectEqual(@as(?u16, 15), (try parse(&.{ "rotate", "15" })).set_rotation.minutes);
    try std.testing.expectEqual(@as(?control.Order, null), (try parse(&.{ "rotate", "15" })).set_rotation.order);
    try std.testing.expectEqual(@as(?u16, 0), (try parse(&.{ "rotate", "off" })).set_rotation.minutes);
    try std.testing.expectEqual(@as(?u16, 10080), (try parse(&.{ "rotate", "10080" })).set_rotation.minutes);
    try std.testing.expectError(error.BadValue, parse(&.{ "rotate", "10081" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "rotate", "-5" }));
    try std.testing.expectError(error.BadValue, parse(&.{ "rotate", "soon" }));
    try std.testing.expectError(error.MissingArgument, parse(&.{"rotate"}));
    try std.testing.expectEqual(@as(?control.Order, .random), (try parse(&.{ "order", "random" })).set_rotation.order);
    try std.testing.expectEqual(@as(?u16, null), (try parse(&.{ "order", "random" })).set_rotation.minutes);
    try std.testing.expectError(error.BadValue, parse(&.{ "order", "chaos" }));
    try std.testing.expectEqual(@as(?control.Order, .shuffle), (try parse(&.{ "shuffle", "on" })).set_rotation.order);
    try std.testing.expectEqual(@as(?control.Order, .sequential), (try parse(&.{ "shuffle", "off" })).set_rotation.order);
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "shuffle", "on", "now" }));
}

test {
    _ = @import("words.zig");
}
