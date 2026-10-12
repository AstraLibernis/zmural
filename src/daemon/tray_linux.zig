// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The tray icon on Linux: a StatusNotifierItem (KDE Plasma shows it
//! natively; GNOME with the AppIndicator extension, which Ubuntu ships) with a
//! com.canonical.dbusmenu menu, the same as the Windows tray: what's
//! showing, Paused, Muted, Next, Previous, Shuffle, Rescan, Start at login,
//! Settings..., Quit. A left click opens the settings window.
//!
//! zmural serves both objects on its session bus connection (`os/dbus.zig`)
//! and registers with the desktop's StatusNotifierWatcher, again whenever
//! the watcher (re)appears: Plasma may start after zmural, or restart.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const dbus = zmural.os.dbus;

const log = std.log.scoped(.tray);

const item_path = "/StatusNotifierItem";
const item_iface = "org.kde.StatusNotifierItem";
const menu_path = "/MenuBar";
const menu_iface = "com.canonical.dbusmenu";
const props_iface = "org.freedesktop.DBus.Properties";
const watcher = "org.kde.StatusNotifierWatcher";

/// The icon at 22, 32, 48 and 64 px (from tools/icongen.zig).
const pixmaps = @embedFile("tray.argb");

/// What the tray shows.
pub const State = struct {
    wallpaper: []const u8 = "",
    paused: bool = false,
    muted: bool = true,
    /// Next/Previous and timed changes go in shuffle (or random) order.
    shuffled: bool = false,
    autostart: bool = false,
};

/// What the user picked.
pub const Action = enum { open_settings, toggle_paused, toggle_muted, next, previous, toggle_shuffle, rescan, toggle_autostart, quit };

const Item = struct { id: i32, label: []const u8 = "", kind: enum { plain, separator, check, disabled } = .plain, action: ?Action = null };

pub const Tray = struct {
    /// Our well-known name, org.kde.StatusNotifierItem-<pid>-1.
    name: [64]u8 = undefined,
    name_len: usize = 0,
    revision: u32 = 1,
    /// An xdg-activation token from the tray host (KDE sends one before
    /// Activate), handed to the settings window so it may take focus.
    token: [256]u8 = undefined,
    token_len: usize = 0,

    /// Takes the host's activation token, if it gave one.
    pub fn takeToken(t: *Tray) ?[]const u8 {
        if (t.token_len == 0) return null;
        defer t.token_len = 0;
        return t.token[0..t.token_len];
    }

    /// Takes our item name and registers (if a watcher is up yet).
    pub fn start(t: *Tray, c: *dbus.Conn) void {
        const name = std.fmt.bufPrint(&t.name, "org.kde.StatusNotifierItem-{d}-1", .{linux.getpid()}) catch return;
        t.name_len = name.len;
        _ = c.requestName(name) catch |err| log.warn("tray name not taken: {s}", .{@errorName(err)});
        c.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ watcher ++ "'") catch {}; // zsnag:ok — without it, a Plasma started later won't show the icon until zmural restarts
        t.register(c);
    }

    fn register(t: *Tray, c: *dbus.Conn) void {
        var buf: [128]u8 = undefined;
        var w: dbus.Writer = .{ .buf = &buf };
        w.string(t.name[0..t.name_len]) catch return;
        _ = c.call(watcher, "/StatusNotifierWatcher", watcher, "RegisterStatusNotifierItem", "s", w.written()) catch {
            log.info("no tray host yet (StatusNotifierWatcher); the icon appears when one starts", .{});
            return;
        };
        log.info("tray icon registered", .{});
    }

    /// Handles a bus message meant for the tray. Returns what the user asked for.
    pub fn onMessage(t: *Tray, c: *dbus.Conn, m: dbus.Message, s: State) ?Action {
        if (m.isSignal("org.freedesktop.DBus", "NameOwnerChanged")) {
            var r: dbus.Reader = .{ .body = m.body };
            const name = r.string() catch return null;
            _ = r.string() catch return null;
            const new_owner = r.string() catch return null;
            if (std.mem.eql(u8, name, watcher) and new_owner.len > 0) t.register(c);
            return null;
        }
        if (m.kind != dbus.Kind.method_call) return null;
        const is = std.mem.eql;
        if (is(u8, m.path, item_path)) {
            if (is(u8, m.interface, props_iface)) return t.properties(c, m, s, .item);
            if (is(u8, m.member, "Activate") or is(u8, m.member, "SecondaryActivate")) {
                c.reply(m, "", "") catch {}; // zsnag:ok — the host doesn't wait for this
                return .open_settings;
            }
            if (is(u8, m.member, "ProvideXdgActivationToken")) {
                var r: dbus.Reader = .{ .body = m.body };
                const token = r.string() catch "";
                t.token_len = if (token.len <= t.token.len) token.len else 0;
                @memcpy(t.token[0..t.token_len], token[0..t.token_len]);
                c.reply(m, "", "") catch {}; // zsnag:ok — the host doesn't wait for this
                return null;
            }
            if (is(u8, m.member, "Introspect")) return introspect(c, m, item_xml);
            c.reply(m, "", "") catch {}; // zsnag:ok — ContextMenu, Scroll: nothing to do
            return null;
        }
        if (is(u8, m.path, menu_path)) {
            if (is(u8, m.interface, props_iface)) return t.properties(c, m, s, .menu);
            if (is(u8, m.member, "GetLayout")) {
                t.getLayout(c, m, s);
                return null;
            }
            if (is(u8, m.member, "Event")) {
                var r: dbus.Reader = .{ .body = m.body };
                const id = r.u32_() catch return null;
                const event = r.string() catch return null;
                c.reply(m, "", "") catch {}; // zsnag:ok — as above
                if (!is(u8, event, "clicked")) return null;
                return actionFor(@bitCast(id));
            }
            if (is(u8, m.member, "EventGroup")) return t.eventGroup(c, m);
            if (is(u8, m.member, "AboutToShow")) {
                var buf: [8]u8 = undefined;
                var w: dbus.Writer = .{ .buf = &buf };
                w.u32_(0) catch return null;
                c.reply(m, "b", w.written()) catch {}; // zsnag:ok — as above
                return null;
            }
            if (is(u8, m.member, "AboutToShowGroup")) {
                var buf: [16]u8 = undefined;
                var w: dbus.Writer = .{ .buf = &buf };
                w.endArray(w.beginArray(4) catch return null);
                w.endArray(w.beginArray(4) catch return null);
                c.reply(m, "aiai", w.written()) catch {}; // zsnag:ok — as above
                return null;
            }
            if (is(u8, m.member, "GetGroupProperties")) {
                t.getGroupProperties(c, m, s);
                return null;
            }
            if (is(u8, m.member, "Introspect")) return introspect(c, m, menu_xml);
            c.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", "not supported") catch {}; // zsnag:ok — as above
            return null;
        }
        if (is(u8, m.member, "Introspect") and is(u8, m.path, "/")) return introspect(c, m, root_xml);
        return null;
    }

    /// The menu changed (paused, muted, the wallpaper...): hosts fetch it again.
    pub fn changed(t: *Tray, c: *dbus.Conn) void {
        t.revision +%= 1;
        var buf: [16]u8 = undefined;
        var w: dbus.Writer = .{ .buf = &buf };
        w.u32_(t.revision) catch return;
        w.i32_(0) catch return;
        c.signal(menu_path, menu_iface, "LayoutUpdated", "ui", w.written()) catch {}; // zsnag:ok — the next menu open still shows it
        c.signal(item_path, item_iface, "NewToolTip", "", "") catch {}; // zsnag:ok — as above
    }

    // ---- properties ---------------------------------------------------------------

    const Which = enum { item, menu };

    fn properties(t: *Tray, c: *dbus.Conn, m: dbus.Message, s: State, which: Which) ?Action {
        _ = t;
        var r: dbus.Reader = .{ .body = m.body };
        var buf: [40 * 1024]u8 = undefined;
        var w: dbus.Writer = .{ .buf = &buf };
        if (std.mem.eql(u8, m.member, "GetAll")) {
            const a = w.beginArray(8) catch return null;
            const names: []const []const u8 = switch (which) {
                .item => &.{ "Category", "Id", "Title", "Status", "WindowId", "IconName", "IconPixmap", "OverlayIconName", "AttentionIconName", "ToolTip", "ItemIsMenu", "Menu" },
                .menu => &.{ "Version", "TextDirection", "Status", "IconThemePath" },
            };
            for (names) |n| {
                w.pad(8) catch return null;
                w.string(n) catch return null;
                writeProperty(&w, which, n, s) catch return null;
            }
            w.endArray(a);
            c.reply(m, "a{sv}", w.written()) catch {}; // zsnag:ok — the host asks again
        } else if (std.mem.eql(u8, m.member, "Get")) {
            _ = r.string() catch return null;
            const n = r.string() catch return null;
            writeProperty(&w, which, n, s) catch {
                c.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", "no such property") catch {}; // zsnag:ok — as above
                return null;
            };
            c.reply(m, "v", w.written()) catch {}; // zsnag:ok — as above
        } else {
            c.replyError(m, "org.freedesktop.DBus.Error.PropertyReadOnly", "read only") catch {}; // zsnag:ok — as above
        }
        return null;
    }

    fn writeProperty(w: *dbus.Writer, which: Which, n: []const u8, s: State) !void {
        const eql = std.mem.eql;
        switch (which) {
            .item => {
                if (eql(u8, n, "Category")) return variantString(w, "ApplicationStatus");
                if (eql(u8, n, "Id")) return variantString(w, "zmural");
                if (eql(u8, n, "Title")) return variantString(w, "zmural");
                if (eql(u8, n, "Status")) return variantString(w, "Active");
                if (eql(u8, n, "WindowId")) {
                    try w.signature("i");
                    return w.i32_(0);
                }
                if (eql(u8, n, "IconName") or eql(u8, n, "OverlayIconName") or eql(u8, n, "AttentionIconName")) return variantString(w, "");
                if (eql(u8, n, "IconPixmap")) {
                    try w.signature("a(iiay)");
                    return writePixmaps(w);
                }
                if (eql(u8, n, "ToolTip")) {
                    try w.signature("(sa(iiay)ss)");
                    try w.pad(8);
                    try w.string("");
                    w.endArray(try w.beginArray(8));
                    try w.string("zmural");
                    var buf: [512]u8 = undefined;
                    try w.string(tooltip(&buf, s));
                    return;
                }
                if (eql(u8, n, "ItemIsMenu")) {
                    try w.signature("b");
                    return w.u32_(0);
                }
                if (eql(u8, n, "Menu")) {
                    try w.signature("o");
                    return w.string(menu_path);
                }
            },
            .menu => {
                if (eql(u8, n, "Version")) {
                    try w.signature("u");
                    return w.u32_(3);
                }
                if (eql(u8, n, "TextDirection")) return variantString(w, "ltr");
                if (eql(u8, n, "Status")) return variantString(w, "normal");
                if (eql(u8, n, "IconThemePath")) {
                    try w.signature("as");
                    return w.endArray(try w.beginArray(4));
                }
            },
        }
        return error.NoSuchProperty;
    }

    // ---- the menu -------------------------------------------------------------------

    fn items(s: State, name_buf: []u8) [13]Item {
        const name = if (s.wallpaper.len == 0) "Nothing showing" else std.fmt.bufPrint(name_buf, "Showing: {s}", .{zmural.media.displayName(s.wallpaper)}) catch "Showing a wallpaper";
        return .{
            .{ .id = 1, .label = name, .kind = .disabled },
            .{ .id = 2, .kind = .separator },
            .{ .id = 3, .label = "Paused", .kind = .check, .action = .toggle_paused },
            .{ .id = 4, .label = "Muted", .kind = .check, .action = .toggle_muted },
            .{ .id = 5, .label = "Next wallpaper", .action = .next },
            .{ .id = 6, .label = "Previous wallpaper", .action = .previous },
            // IDs are never reused: a menu host may still hold the old layout.
            .{ .id = 13, .label = "Shuffle", .kind = .check, .action = .toggle_shuffle },
            .{ .id = 7, .kind = .separator },
            .{ .id = 8, .label = "Rescan library", .action = .rescan },
            .{ .id = 9, .label = "Start at login", .kind = .check, .action = .toggle_autostart },
            .{ .id = 10, .label = "Settings...", .action = .open_settings },
            .{ .id = 11, .kind = .separator },
            .{ .id = 12, .label = "Quit zmural", .action = .quit },
        };
    }

    fn checked(id: i32, s: State) bool {
        return switch (id) {
            3 => s.paused,
            4 => s.muted,
            9 => s.autostart,
            13 => s.shuffled,
            else => false,
        };
    }

    fn getLayout(t: *Tray, c: *dbus.Conn, m: dbus.Message, s: State) void {
        var name_buf: [256]u8 = undefined;
        const list = items(s, &name_buf);
        var out: [8 * 1024]u8 = undefined;
        var o: dbus.Writer = .{ .buf = &out };
        layout(&o, t.revision, &list, s) catch return;
        c.reply(m, "u(ia{sv}av)", o.written()) catch {}; // zsnag:ok — the host asks again
    }

    fn getGroupProperties(t: *Tray, c: *dbus.Conn, m: dbus.Message, s: State) void {
        _ = t;
        var r: dbus.Reader = .{ .body = m.body };
        const end = r.arrayEnd(4) catch return;
        var ids: [32]i32 = undefined;
        var n: usize = 0;
        while (r.pos < end and n < ids.len) : (n += 1) ids[n] = @bitCast(r.u32_() catch return);
        var name_buf: [256]u8 = undefined;
        const list = items(s, &name_buf);
        var buf: [8 * 1024]u8 = undefined;
        var w: dbus.Writer = .{ .buf = &buf };
        const a = w.beginArray(8) catch return;
        for (list) |it| {
            if (n > 0 and std.mem.findScalar(i32, ids[0..n], it.id) == null) continue;
            w.pad(8) catch return;
            w.i32_(it.id) catch return;
            itemProps(&w, it, s) catch return;
        }
        w.endArray(a);
        c.reply(m, "a(ia{sv})", w.written()) catch {}; // zsnag:ok — the host asks again
    }

    fn eventGroup(t: *Tray, c: *dbus.Conn, m: dbus.Message) ?Action {
        _ = t;
        var r: dbus.Reader = .{ .body = m.body };
        var picked: ?Action = null;
        if (r.arrayEnd(8)) |end| {
            while (r.pos < end) {
                r.alignStruct() catch break;
                const id: i32 = @bitCast(r.u32_() catch break);
                const event = r.string() catch break;
                const sig = r.signature() catch break;
                r.skip(sig) catch break;
                _ = r.u32_() catch break;
                if (std.mem.eql(u8, event, "clicked")) picked = actionFor(id);
            }
        } else |_| {}
        var buf: [16]u8 = undefined;
        var w: dbus.Writer = .{ .buf = &buf };
        w.endArray(w.beginArray(4) catch return picked);
        c.reply(m, "ai", w.written()) catch {}; // zsnag:ok — as above
        return picked;
    }
};

fn actionFor(id: i32) ?Action {
    var name_buf: [8]u8 = undefined;
    for (Tray.items(.{}, &name_buf)) |it| if (it.id == id) return it.action;
    return null;
}

/// `u (ia{sv}av)`: the revision, then the root item holding every item.
fn layout(w: *dbus.Writer, revision: u32, list: []const Item, s: State) !void {
    try w.u32_(revision);
    try w.pad(8);
    try w.i32_(0);
    const props = try w.beginArray(8);
    try prop(w, "children-display", "s", .{ .s = "submenu" });
    w.endArray(props);
    const children = try w.beginArray(1);
    for (list) |it| {
        try w.signature("(ia{sv}av)");
        try w.pad(8);
        try w.i32_(it.id);
        try itemProps(w, it, s);
        w.endArray(try w.beginArray(1)); // no children
    }
    w.endArray(children);
}

fn itemProps(w: *dbus.Writer, it: Item, s: State) !void {
    const a = try w.beginArray(8);
    switch (it.kind) {
        .separator => try prop(w, "type", "s", .{ .s = "separator" }),
        .disabled => {
            try prop(w, "label", "s", .{ .s = it.label });
            try prop(w, "enabled", "b", .{ .b = false });
        },
        .check => {
            try prop(w, "label", "s", .{ .s = it.label });
            try prop(w, "toggle-type", "s", .{ .s = "checkmark" });
            try prop(w, "toggle-state", "i", .{ .i = @intFromBool(Tray.checked(it.id, s)) });
        },
        .plain => try prop(w, "label", "s", .{ .s = it.label }),
    }
    w.endArray(a);
}

const Value = union(enum) { s: []const u8, b: bool, i: i32 };

/// One `{sv}` dict entry.
fn prop(w: *dbus.Writer, name: []const u8, sig: []const u8, v: Value) !void {
    try w.pad(8);
    try w.string(name);
    try w.signature(sig);
    switch (v) {
        .s => |x| try w.string(x),
        .b => |x| try w.u32_(@intFromBool(x)),
        .i => |x| try w.i32_(x),
    }
}

fn variantString(w: *dbus.Writer, s: []const u8) !void {
    try w.signature("s");
    try w.string(s);
}

/// `a(iiay)` from the embedded pixmaps.
fn writePixmaps(w: *dbus.Writer) !void {
    const a = try w.beginArray(8);
    var off: usize = 0;
    while (off + 8 <= pixmaps.len) {
        const width = std.mem.readInt(u32, pixmaps[off..][0..4], .little);
        const height = std.mem.readInt(u32, pixmaps[off + 4 ..][0..4], .little);
        const n = @as(usize, width) * height * 4;
        off += 8;
        if (off + n > pixmaps.len) break;
        try w.pad(8);
        try w.i32_(@intCast(width));
        try w.i32_(@intCast(height));
        try w.u32_(@intCast(n));
        try w.bytesRaw(pixmaps[off..][0..n]);
        off += n;
    }
    w.endArray(a);
}

fn tooltip(buf: []u8, s: State) []const u8 {
    if (s.wallpaper.len == 0) return "Nothing showing";
    const what = zmural.media.displayName(s.wallpaper);
    const how = if (s.paused) "paused" else if (s.muted) "playing, muted" else "playing";
    return std.fmt.bufPrint(buf, "{s} ({s})", .{ what, how }) catch what;
}

fn introspect(c: *dbus.Conn, m: dbus.Message, xml: []const u8) ?Action {
    var buf: [4096]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    w.string(xml) catch return null;
    c.reply(m, "s", w.written()) catch {}; // zsnag:ok — introspection is a courtesy
    return null;
}

const root_xml =
    \\<node><node name="StatusNotifierItem"/><node name="MenuBar"/></node>
;
const item_xml =
    \\<node><interface name="org.kde.StatusNotifierItem">
    \\<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
    \\<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
    \\<property name="WindowId" type="i" access="read"/><property name="IconName" type="s" access="read"/>
    \\<property name="IconPixmap" type="a(iiay)" access="read"/><property name="OverlayIconName" type="s" access="read"/>
    \\<property name="AttentionIconName" type="s" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\<property name="ItemIsMenu" type="b" access="read"/><property name="Menu" type="o" access="read"/>
    \\<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    \\<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    \\<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
    \\<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
    \\<method name="ProvideXdgActivationToken"><arg type="s" direction="in"/></method>
    \\<signal name="NewIcon"/><signal name="NewToolTip"/><signal name="NewStatus"><arg type="s"/></signal>
    \\</interface></node>
;
const menu_xml =
    \\<node><interface name="com.canonical.dbusmenu">
    \\<property name="Version" type="u" access="read"/><property name="TextDirection" type="s" access="read"/>
    \\<property name="Status" type="s" access="read"/><property name="IconThemePath" type="as" access="read"/>
    \\<method name="GetLayout"><arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/><arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/></method>
    \\<method name="GetGroupProperties"><arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/></method>
    \\<method name="Event"><arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/><arg type="u" direction="in"/></method>
    \\<method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
    \\<method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
    \\<method name="AboutToShowGroup"><arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/></method>
    \\<signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
    \\<signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
    \\</interface></node>
;

test "the menu layout round trips through a generic reader" {
    var buf: [8 * 1024]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    var name_buf: [256]u8 = undefined;
    const list = Tray.items(.{ .wallpaper = "/w/rain.mp4", .paused = true }, &name_buf);
    try layout(&w, 7, &list, .{ .paused = true });
    var r: dbus.Reader = .{ .body = w.written() };
    try std.testing.expectEqual(@as(u32, 7), try r.u32_());
    try r.skip("(ia{sv}av)");
    try std.testing.expectEqual(w.written().len, r.pos);
    try std.testing.expectEqual(Action.toggle_paused, actionFor(3).?);
    try std.testing.expectEqual(Action.toggle_shuffle, actionFor(13).?);
    try std.testing.expectEqual(@as(?Action, null), actionFor(1));
}

test "the pixmaps are well formed" {
    var buf: [40 * 1024]u8 = undefined;
    var w: dbus.Writer = .{ .buf = &buf };
    try writePixmaps(&w);
    var r: dbus.Reader = .{ .body = w.written() };
    try r.skip("a(iiay)");
    try std.testing.expectEqual(w.written().len, r.pos);
}
