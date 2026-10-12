// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Which key is which, from the keymap the compositor sends (Linux). Wayland
//! reports keys as codes whose meaning the keymap gives; for a real keyboard
//! the keys the settings window uses (Tab, Enter, Space, Escape, the arrows,
//! Home, End, Menu, F10) sit at the same codes on every layout, but a virtual
//! keyboard (an on-screen one, remote desktop, a test tool) may put them
//! anywhere. So the keymap is read, just enough: the key names and codes
//! (`xkb_keycodes`), and each key's first symbol (`xkb_symbols`). Anything
//! it can't read falls back to the standard codes.

const std = @import("std");

pub const Key = enum(u8) {
    none,
    tab,
    /// ISO_Left_Tab: Tab with Shift, on keymaps that give it its own key.
    back_tab,
    activate,
    escape,
    left,
    right,
    up,
    down,
    home,
    end,
    menu,
    f10,
    shift,
};

/// By Linux input code (what `wl_keyboard.key` carries: the keymap's code
/// minus 8).
pub const Map = struct {
    keys: [256]Key = @splat(.none),

    pub fn get(m: *const Map, code: u32) Key {
        return if (code < m.keys.len) m.keys[code] else .none;
    }

    /// The codes of a standard keyboard (evdev).
    pub fn standard() Map {
        var m: Map = .{};
        const pairs = [_]struct { u8, Key }{
            .{ 1, .escape },    .{ 15, .tab },    .{ 28, .activate }, .{ 42, .shift }, .{ 54, .shift },
            .{ 57, .activate }, .{ 68, .f10 },    .{ 96, .activate }, .{ 102, .home }, .{ 103, .up },
            .{ 105, .left },    .{ 106, .right }, .{ 107, .end },     .{ 108, .down }, .{ 127, .menu },
        };
        for (pairs) |p| m.keys[p[0]] = p[1];
        return m;
    }

    /// From the text of an XKB keymap; the standard codes if it names none
    /// of the keys the window uses.
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) Map {
        return parseInner(gpa, text) catch standard();
    }
};

fn parseInner(gpa: std.mem.Allocator, text: []const u8) !Map {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const kc_at = std.mem.find(u8, text, "xkb_keycodes") orelse return error.NoKeycodes;
    const sym_at = std.mem.find(u8, text, "xkb_symbols") orelse return error.NoSymbols;
    const kc_end = std.mem.findPos(u8, text, kc_at, "\n};") orelse text.len;

    // Key names to codes, aliases resolved after.
    var codes: std.StringHashMapUnmanaged(u32) = .empty;
    var aliases: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text[kc_at..kc_end], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "alias")) {
            const n1 = angled(line, 0) orelse continue;
            const n2 = angled(line, n1.end) orelse continue;
            try aliases.put(a, n1.name, n2.name);
        } else if (line.len > 0 and line[0] == '<') {
            const n = angled(line, 0) orelse continue;
            const eq = std.mem.findScalarPos(u8, line, n.end, '=') orelse continue;
            const num = std.mem.trim(u8, line[eq + 1 ..], " \t;");
            try codes.put(a, n.name, std.fmt.parseInt(u32, num, 10) catch continue);
        }
    }
    var ai = aliases.iterator();
    while (ai.next()) |e| if (codes.get(e.value_ptr.*)) |c| try codes.put(a, e.key_ptr.*, c);

    var m: Map = .{};
    var found = false;
    var pos = sym_at;
    while (std.mem.findPos(u8, text, pos, "key <")) |at| {
        pos = at + 4;
        const n = angled(text, at) orelse continue;
        const code = codes.get(n.name) orelse continue;
        const open = std.mem.findScalarPos(u8, text, n.end, '{') orelse break;
        const close = std.mem.findPos(u8, text, open, "}") orelse break;
        const sym = firstSymbol(text[open..close]) orelse continue;
        const k = keyFor(sym);
        if (k == .none or code < 8 or code - 8 >= m.keys.len) continue;
        m.keys[code - 8] = k;
        found = true;
    }
    return if (found) m else error.NothingUseful;
}

const Angled = struct { name: []const u8, end: usize };

/// The next `<name>` at or after `from`.
fn angled(s: []const u8, from: usize) ?Angled {
    const lt = std.mem.findScalarPos(u8, s, from, '<') orelse return null;
    const gt = std.mem.findScalarPos(u8, s, lt, '>') orelse return null;
    return .{ .name = s[lt + 1 .. gt], .end = gt + 1 };
}

/// A key block's first symbol: `{ [ Tab, ISO_Left_Tab ] }`, or with a type,
/// `{ type= "X", symbols[Group1]= [ F10, ... ] }`.
fn firstSymbol(block: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.findScalarPos(u8, block, from, '[')) |lb| {
        const rb = std.mem.findScalarPos(u8, block, lb, ']') orelse return null;
        from = rb + 1;
        const inside = block[lb + 1 .. rb];
        if (std.mem.startsWith(u8, std.mem.trim(u8, inside, " \t"), "Group")) continue; // symbols[Group1]
        var items = std.mem.splitScalar(u8, inside, ',');
        return std.mem.trim(u8, items.first(), " \t\r\n");
    }
    return null;
}

fn keyFor(sym: []const u8) Key {
    const named = [_]struct { []const u8, u32, Key }{
        .{ "Tab", 0xff09, .tab },           .{ "ISO_Left_Tab", 0xfe20, .back_tab }, .{ "Return", 0xff0d, .activate },
        .{ "KP_Enter", 0xff8d, .activate }, .{ "space", 0x20, .activate },          .{ "Escape", 0xff1b, .escape },
        .{ "Home", 0xff50, .home },         .{ "Left", 0xff51, .left },             .{ "Up", 0xff52, .up },
        .{ "Right", 0xff53, .right },       .{ "Down", 0xff54, .down },             .{ "End", 0xff57, .end },
        .{ "Menu", 0xff67, .menu },         .{ "F10", 0xffc7, .f10 },               .{ "Shift_L", 0xffe1, .shift },
        .{ "Shift_R", 0xffe2, .shift },
    };
    const value: ?u32 = if (std.mem.startsWith(u8, sym, "0x")) std.fmt.parseInt(u32, sym[2..], 16) catch null else null;
    for (named) |n| {
        if (value) |v| {
            if (v == n[1]) return n[2];
        } else if (std.mem.eql(u8, sym, n[0])) return n[2];
    }
    return .none;
}

test "a keymap as xkbcommon writes it: names, aliases, typed keys" {
    const text =
        \\xkb_keymap {
        \\xkb_keycodes "evdev_aliases(qwerty)" {
        \\    minimum = 8;
        \\    maximum = 708;
        \\    <ESC>                = 9;
        \\    <TAB>                = 23;
        \\    <RTRN>               = 36;
        \\    <LFSH>               = 50;
        \\    <SPCE>               = 65;
        \\    <FK10>               = 76;
        \\    <KPEN>               = 104;
        \\    <HOME>               = 110;
        \\    <UP>                 = 111;
        \\    <LEFT>               = 113;
        \\    <RGHT>               = 114;
        \\    <END>                = 115;
        \\    <DOWN>               = 116;
        \\    <COMP>               = 135;
        \\    alias <MENU>         = <COMP>;
        \\    indicator 1 = "Caps Lock";
        \\};
        \\xkb_symbols "pc_us_inet(evdev)" {
        \\    name[Group1]="English (US)";
        \\    key <ESC>                {    [          Escape ] };
        \\    key <TAB>                {    [             Tab,    ISO_Left_Tab ] };
        \\    key <RTRN>               {    [          Return ] };
        \\    key <LFSH>               {    [         Shift_L ] };
        \\    key <SPCE>               {    [           space ] };
        \\    key <FK10>               {
        \\        type= "CTRL+ALT",
        \\        symbols[Group1]= [             F10,             F10,  XF86Switch_VT_10 ]
        \\    };
        \\    key <KPEN>               {    [        KP_Enter ] };
        \\    key <HOME>               {    [            Home ] };
        \\    key <UP>                 {    [              Up ] };
        \\    key <LEFT>               {    [            Left ] };
        \\    key <RGHT>               {    [           Right ] };
        \\    key <END>                {    [             End ] };
        \\    key <DOWN>               {    [            Down ] };
        \\    key <MENU>               {    [            Menu ] };
        \\};
        \\};
    ;
    const m = Map.parse(std.testing.allocator, text);
    const std_map = Map.standard();
    // A real keyboard's keymap gives the standard codes (this sample leaves
    // out the right Shift).
    for (0..256) |c| {
        if (c == 54) continue;
        try std.testing.expectEqual(std_map.get(@intCast(c)), m.get(@intCast(c)));
    }
}

test "a virtual keyboard's keymap (wtype's): one key, its symbol as a number" {
    const text =
        \\xkb_keymap {
        \\xkb_keycodes "(unnamed)" {
        \\    minimum = 8;
        \\    maximum = 255;
        \\    <K1> = 9;
        \\    <K2> = 10;
        \\    indicator 1 = "Caps Lock";
        \\};
        \\xkb_types "(unnamed)" { type "ONE_LEVEL" { modifiers= none; }; };
        \\xkb_symbols "(unnamed)" {
        \\    key <K1> {    [ 0xff09 ] };
        \\    key <K2> {    [ 0xff0d ] };
        \\};
        \\};
    ;
    const m = Map.parse(std.testing.allocator, text);
    try std.testing.expectEqual(Key.tab, m.get(1)); // code 9 - 8: what was Escape on a real keyboard
    try std.testing.expectEqual(Key.activate, m.get(2));
    try std.testing.expectEqual(Key.none, m.get(15));
}

test "an unreadable keymap falls back to the standard codes" {
    const m = Map.parse(std.testing.allocator, "not a keymap");
    try std.testing.expectEqual(Key.tab, m.get(15));
    try std.testing.expectEqual(Key.menu, m.get(127));
}
