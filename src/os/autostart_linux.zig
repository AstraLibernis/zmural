// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Start at login (Linux): an XDG autostart entry,
//! `$XDG_CONFIG_HOME/autostart/zmural.desktop` (`~/.config/autostart/...`),
//! which KDE, GNOME, XFCE, Cinnamon and most other desktops run at login.
//!
//! The file is also the setting. The XDG way to switch an entry off is
//! `Hidden=true` in it, and that's what the desktops' own Autostart settings
//! write too, so zmural's switch and theirs can't disagree:
//! - no file: never decided; zmural turns it on (the default) on first run
//! - `Hidden=true`, or `X-GNOME-Autostart-enabled=false`: off, left alone
//! - otherwise: on

const std = @import("std");

pub const file_name = "zmural.desktop";

pub const State = enum { unset, on, off };

/// `<config home>/autostart/zmural.desktop`.
pub fn path(gpa: std.mem.Allocator, xdg_config_home: ?[]const u8, home: []const u8) ![]u8 {
    if (xdg_config_home) |c| if (c.len > 0) return std.fs.path.join(gpa, &.{ c, "autostart", file_name });
    return std.fs.path.join(gpa, &.{ home, ".config", "autostart", file_name });
}

pub fn state(io: std.Io, entry_path: []const u8) State {
    var buf: [4096]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, entry_path, &buf) catch return .unset;
    return parse(text);
}

/// On or off, from an entry's text.
pub fn parse(text: []const u8) State {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_entry = false;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry) continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (std.mem.eql(u8, key, "Hidden") and std.mem.eql(u8, value, "true")) return .off;
        if (std.mem.eql(u8, key, "X-GNOME-Autostart-enabled") and std.mem.eql(u8, value, "false")) return .off;
    }
    return .on;
}

/// `exe` as the program in a desktop entry's `Exec=` line: quoted, with the
/// characters the Desktop Entry spec reserves escaped twice over (once for
/// the quoted argument, once for the file's string value) and `%` doubled,
/// so a folder named `a$b "c" 50%` still runs. Into `buf`.
///
/// A `%` in the program's own path goes through `env`: GLib looks the
/// program up before it turns `%%` back into `%`, and finds no such file.
pub fn execQuoted(buf: []u8, exe: []const u8) error{NoSpaceLeft}![]u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (std.mem.findScalar(u8, exe, '%') != null) w.writeAll("env ") catch return error.NoSpaceLeft;
    w.writeByte('"') catch return error.NoSpaceLeft;
    for (exe) |c| {
        const out: []const u8 = switch (c) {
            '"' => "\\\\\"",
            '`' => "\\\\`",
            '$' => "\\\\$",
            '\\' => "\\\\\\\\",
            '%' => "%%",
            '\n' => "\\n",
            '\t' => "\\t",
            '\r' => "\\r",
            else => &.{c},
        };
        w.writeAll(out) catch return error.NoSpaceLeft;
    }
    w.writeByte('"') catch return error.NoSpaceLeft;
    return w.buffered();
}

/// The entry for `exe` (an absolute path to zmural), on or off.
pub fn entry(buf: []u8, exe: []const u8, enabled: bool) error{NoSpaceLeft}![]u8 {
    var q: [3 * std.Io.Dir.max_path_bytes]u8 = undefined;
    return std.fmt.bufPrint(buf,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=zmural
        \\Comment=Live wallpapers
        \\Exec={s}
        \\Icon=org.zmural.Settings
        \\Terminal=false
        \\NoDisplay=true
        \\X-GNOME-Autostart-enabled={s}
        \\Hidden={s}
        \\
    , .{ try execQuoted(&q, exe), if (enabled) "true" else "false", if (enabled) "false" else "true" });
}

/// Writes the entry (creating the autostart folder), atomically.
pub fn write(io: std.Io, entry_path: []const u8, exe: []const u8, enabled: bool) !void {
    var buf: [3 * std.Io.Dir.max_path_bytes + 512]u8 = undefined;
    const text = try entry(&buf, exe, enabled);
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(entry_path)) |dir| try cwd.createDirPath(io, dir);
    var tmp_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{entry_path});
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = text });
    try cwd.rename(tmp, cwd, entry_path, io);
}

/// The `Exec` program in an entry, if it names one, undoing `execQuoted`
/// (into `buf`).
pub fn execPath(buf: []u8, text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "Exec=")) continue;
        var v = line["Exec=".len..];
        if (std.mem.startsWith(u8, v, "env \"")) v = v["env ".len..];
        if (v.len == 0 or v[0] != '"') return v[0 .. std.mem.findScalar(u8, v, ' ') orelse v.len];
        // 1. The file's string escapes: \\ \n \t \r \s.
        var value: [3 * std.Io.Dir.max_path_bytes]u8 = undefined;
        var vn: usize = 0;
        var i: usize = 0;
        while (i < v.len) : (vn += 1) {
            if (vn == value.len) return null;
            if (v[i] == '\\' and i + 1 < v.len) {
                value[vn] = switch (v[i + 1]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    's' => ' ',
                    else => |e| e,
                };
                i += 2;
            } else {
                value[vn] = v[i];
                i += 1;
            }
        }
        // 2. The quoted argument: a backslash makes the next character
        //    plain; the closing quote ends it. 3. %% is %.
        var n: usize = 0;
        i = 1;
        while (i < vn) {
            var c = value[i];
            if (c == '"') return buf[0..n];
            if (c == '\\' and i + 1 < vn) {
                c = value[i + 1];
                i += 2;
            } else if (c == '%' and i + 1 < vn and value[i + 1] == '%') {
                i += 2;
            } else i += 1;
            if (n == buf.len) return null;
            buf[n] = c;
            n += 1;
        }
        return null;
    }
    return null;
}

test "an entry says on or off, and the Exec path survives" {
    var buf: [2048]u8 = undefined;
    const on = try entry(&buf, "/opt/zmural/bin/zmural", true);
    try std.testing.expectEqual(State.on, parse(on));
    var pb: [512]u8 = undefined;
    try std.testing.expectEqualStrings("/opt/zmural/bin/zmural", execPath(&pb, on).?);
    const off = try entry(&buf, "/opt/zmural/bin/zmural", false);
    try std.testing.expectEqual(State.off, parse(off));
}

test "the desktops' own ways of switching an entry off are honoured" {
    try std.testing.expectEqual(State.off, parse("[Desktop Entry]\nExec=zmural\nHidden=true\n"));
    try std.testing.expectEqual(State.off, parse("[Desktop Entry]\nExec=zmural\nX-GNOME-Autostart-enabled=false\n"));
    try std.testing.expectEqual(State.on, parse("[Desktop Entry]\nExec=zmural\nX-GNOME-Autostart-enabled=true\n"));
    // Keys outside [Desktop Entry] don't count.
    try std.testing.expectEqual(State.on, parse("[Desktop Entry]\nExec=zmural\n[Desktop Action x]\nHidden=true\n"));
    var pb: [512]u8 = undefined;
    try std.testing.expectEqualStrings("/usr/bin/zmural", execPath(&pb, "[Desktop Entry]\nExec=/usr/bin/zmural --x\n").?);
}

test "a folder with characters desktop entries reserve still runs, and reads back" {
    const exe = "/home/me/my $apps/\"x\" `y` 50% a\\b/bin/zmural";
    var buf: [1024]u8 = undefined;
    const q = try execQuoted(&buf, exe);
    // As the Desktop Entry spec has it: \\$ for $, \\\\\\\\ for a backslash, %% for %.
    try std.testing.expectEqualStrings("env \"/home/me/my \\\\$apps/\\\\\"x\\\\\" \\\\`y\\\\` 50%% a\\\\\\\\b/bin/zmural\"", q);
    var e: [2048]u8 = undefined;
    const text = try entry(&e, exe, true);
    var pb: [512]u8 = undefined;
    try std.testing.expectEqualStrings(exe, execPath(&pb, text).?);
}
