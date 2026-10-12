// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The wallpaper manifest, `zmural.toml`: metadata plus typed, user-editable
//! properties. A wallpaper package is a folder holding this file and the
//! files it names.
//!
//! ```toml
//! title   = "Neon Rain"
//! author  = "someone"
//! license = "CC-BY-4.0"
//! type    = "web"              # video | image | web
//! entry   = "index.html"       # a file inside the package folder
//! audio   = true               # wants the audio spectrum
//!
//! [properties.speed]
//! kind    = "slider"           # slider | color | dropdown | checkbox | text
//! label   = "Rain speed"
//! default = 1.0
//! min = 0.1
//! max = 3.0
//! step = 0.1
//! ```
//!
//! Packages come from anywhere, so everything is checked: the entry must stay
//! inside the package folder, property names are plain identifiers, and every
//! property has a valid default (one is derived when none is given).
//! Strings in the result live in the arena `parse` is given.

const std = @import("std");
const toml = @import("toml.zig");

pub const file_name = "zmural.toml";

pub const Kind = enum { video, image, web };

pub const PropertyKind = enum { slider, color, dropdown, checkbox, text };

/// A property's value: sliders are numbers, checkboxes booleans, and colours
/// ("#rrggbb"), dropdown choices and text are text.
pub const Value = union(enum) {
    number: f64,
    boolean: bool,
    text: []const u8,

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .number => |x| b == .number and x == b.number,
            .boolean => |x| b == .boolean and x == b.boolean,
            .text => |x| b == .text and std.mem.eql(u8, x, b.text),
        };
    }
};

pub const Property = struct {
    name: []const u8,
    kind: PropertyKind,
    label: []const u8,
    default: Value,
    min: f64 = 0,
    max: f64 = 1,
    step: f64 = 0,
    /// Dropdown choices.
    options: []const []const u8 = &.{},
};

pub const Manifest = struct {
    title: []const u8,
    author: []const u8 = "",
    license: []const u8 = "",
    kind: Kind,
    /// Relative to the package folder; checked by `safeEntry`.
    entry: []const u8,
    /// Wants the audio spectrum.
    audio: bool = false,
    /// The package has `network = true`. It changes nothing: web wallpapers
    /// are always offline. The key still parses, so a package written when
    /// it meant something loads, and the daemon can say it was ignored.
    asks_network: bool = false,
    properties: []const Property = &.{},

    pub fn property(m: Manifest, name: []const u8) ?Property {
        for (m.properties) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

pub const max_properties = 64;
pub const max_name_len = 64;
pub const max_text_len = 1000;

pub const Error = toml.Error || error{
    UnknownKey,
    UnknownTable,
    MissingField,
    UnsafeEntry,
    InvalidProperty,
    TooManyProperties,
};

/// Set by `parse` to the line where parsing stopped.
pub const Diagnostic = toml.Diagnostic;

pub fn parse(arena: std.mem.Allocator, src: []const u8, diag: ?*Diagnostic) Error!Manifest {
    var title: ?[]const u8 = null;
    var kind: ?Kind = null;
    var entry: ?[]const u8 = null;
    var m: Manifest = .{ .title = "", .kind = .image, .entry = "" };
    var props: std.ArrayList(Partial) = .empty;

    for (try toml.parse(arena, src, diag)) |e| {
        if (diag) |d| d.line = e.line;
        if (e.table.len == 0) {
            const k = e.key;
            if (eql(k, "title")) {
                title = try string(e.value);
            } else if (eql(k, "author")) {
                m.author = try string(e.value);
            } else if (eql(k, "license")) {
                m.license = try string(e.value);
            } else if (eql(k, "type")) {
                kind = std.meta.stringToEnum(Kind, try string(e.value)) orelse return error.BadValue;
            } else if (eql(k, "entry")) {
                entry = try string(e.value);
            } else if (eql(k, "audio")) {
                m.audio = try boolean(e.value);
            } else if (eql(k, "network")) {
                m.asks_network = try boolean(e.value);
            } else return error.UnknownKey;
            continue;
        }
        const prefix = "properties.";
        if (!std.mem.startsWith(u8, e.table, prefix)) return error.UnknownTable;
        const name = e.table[prefix.len..];
        if (!validName(name)) return error.InvalidProperty;
        const p = for (props.items) |*p| {
            if (eql(p.name, name)) break p;
        } else blk: {
            if (props.items.len == max_properties) return error.TooManyProperties;
            try props.append(arena, .{ .name = name });
            break :blk &props.items[props.items.len - 1];
        };
        try p.set(e.key, e.value);
    }
    if (diag) |d| d.line = 0;

    m.title = title orelse return error.MissingField;
    m.kind = kind orelse return error.MissingField;
    m.entry = entry orelse return error.MissingField;
    if (!safeEntry(m.entry)) return error.UnsafeEntry;
    const out = try arena.alloc(Property, props.items.len);
    for (props.items, out) |p, *o| o.* = try p.finish();
    m.properties = out;
    return m;
}

/// A plain relative path that stays inside the package folder: no drive, no
/// leading slash, no `..`, no stream (`:`), nothing empty.
pub fn safeEntry(entry: []const u8) bool {
    if (entry.len == 0 or entry.len > 260) return false;
    if (entry[0] == '/' or entry[0] == '\\') return false;
    if (std.mem.findAny(u8, entry, ":*?\"<>|") != null) return false;
    var it = std.mem.tokenizeAny(u8, entry, "/\\");
    var parts: usize = 0;
    while (it.next()) |part| {
        if (eql(part, "..") or eql(part, ".")) return false;
        // Windows ignores trailing dots and spaces, so "..." or ". " could still mean "..".
        if (std.mem.trimEnd(u8, part, ". ").len == 0) return false;
        parts += 1;
    }
    return parts > 0;
}

/// `entry` (checked by `safeEntry`) as a path under `folder`, with this OS's
/// separators: a package written on Windows may say `media\still.png`, one
/// written on Linux `media/still.png`, and either must open on both.
pub fn entryPath(arena: std.mem.Allocator, folder: []const u8, entry: []const u8) error{OutOfMemory}![]u8 {
    const path = if (folder.len > 0) try std.fs.path.join(arena, &.{ folder, entry }) else try arena.dupe(u8, entry);
    const other: u8 = if (std.fs.path.sep == '/') '\\' else '/';
    std.mem.replaceScalar(u8, path, other, std.fs.path.sep);
    return path;
}

test entryPath {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sep = std.fs.path.sep_str;
    for ([_][]const u8{ "media/still.png", "media\\still.png" }) |e|
        try std.testing.expectEqualStrings("pkg" ++ sep ++ "media" ++ sep ++ "still.png", try entryPath(arena.allocator(), "pkg", e));
    try std.testing.expectEqualStrings("a" ++ sep ++ "b", try entryPath(arena.allocator(), "", "a/b"));
}

/// Property names travel to scripts and files: letters, digits and `_` only.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// "#rrggbb".
pub fn validColor(s: []const u8) bool {
    if (s.len != 7 or s[0] != '#') return false;
    for (s[1..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

const Partial = struct {
    name: []const u8,
    kind: ?PropertyKind = null,
    label: []const u8 = "",
    default: ?toml.Value = null,
    min: ?f64 = null,
    max: ?f64 = null,
    step: ?f64 = null,
    options: []const []const u8 = &.{},

    fn set(p: *Partial, key: []const u8, v: toml.Value) Error!void {
        if (eql(key, "kind")) {
            p.kind = std.meta.stringToEnum(PropertyKind, try string(v)) orelse return error.BadValue;
        } else if (eql(key, "label")) {
            p.label = try string(v);
        } else if (eql(key, "default")) {
            p.default = v;
        } else if (eql(key, "min")) {
            p.min = try number(v);
        } else if (eql(key, "max")) {
            p.max = try number(v);
        } else if (eql(key, "step")) {
            p.step = try number(v);
        } else if (eql(key, "options")) {
            p.options = if (v == .strings) v.strings else return error.BadValue;
        } else return error.UnknownKey;
    }

    fn finish(p: Partial) Error!Property {
        const kind = p.kind orelse return error.InvalidProperty;
        if (p.label.len > 200) return error.InvalidProperty;
        var out: Property = .{ .name = p.name, .kind = kind, .label = if (p.label.len > 0) p.label else p.name, .default = undefined };
        switch (kind) {
            .slider => {
                out.min = p.min orelse return error.InvalidProperty;
                out.max = p.max orelse return error.InvalidProperty;
                out.step = p.step orelse 0;
                if (!(out.min < out.max) or !std.math.isFinite(out.min) or !std.math.isFinite(out.max) or !(out.step >= 0)) return error.InvalidProperty;
                const d = if (p.default) |d| number(d) catch return error.InvalidProperty else out.min;
                if (d < out.min or d > out.max) return error.InvalidProperty;
                out.default = .{ .number = d };
            },
            .color => {
                const d = if (p.default) |d| string(d) catch return error.InvalidProperty else "#ffffff";
                if (!validColor(d)) return error.InvalidProperty;
                out.default = .{ .text = d };
            },
            .checkbox => {
                const d = if (p.default) |d| boolean(d) catch return error.InvalidProperty else false;
                out.default = .{ .boolean = d };
            },
            .dropdown => {
                if (p.options.len == 0 or p.options.len > 32) return error.InvalidProperty;
                for (p.options) |o| if (o.len == 0 or o.len > 200) return error.InvalidProperty;
                const d = if (p.default) |d| string(d) catch return error.InvalidProperty else p.options[0];
                for (p.options) |o| {
                    if (eql(o, d)) break;
                } else return error.InvalidProperty;
                out.options = p.options;
                out.default = .{ .text = d };
            },
            .text => {
                const d = if (p.default) |d| string(d) catch return error.InvalidProperty else "";
                if (d.len > max_text_len) return error.InvalidProperty;
                out.default = .{ .text = d };
            },
        }
        return out;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn string(v: toml.Value) toml.Error![]const u8 {
    return if (v == .string) v.string else error.BadValue;
}

fn boolean(v: toml.Value) toml.Error!bool {
    return if (v == .boolean) v.boolean else error.BadValue;
}

fn number(v: toml.Value) toml.Error!f64 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| if (std.math.isFinite(f)) f else error.BadValue,
        else => error.BadValue,
    };
}

const readme_example =
    \\title   = "Neon Rain"
    \\author  = "someone"
    \\license = "CC-BY-4.0"
    \\type    = "web"              # video | image | web
    \\entry   = "index.html"
    \\audio   = true               # wants the audio spectrum
    \\
    \\[properties.speed]
    \\kind = "slider"
    \\label = "Rain speed"
    \\default = 1.0
    \\min = 0.1
    \\max = 3.0
    \\step = 0.1
    \\
    \\[properties.tint]
    \\kind = "color"
    \\label = "Tint"
    \\default = "#3fa9f5"
    \\
    \\[properties.mood]
    \\kind = "dropdown"
    \\options = ["calm", "storm"]
    \\
    \\[properties.lightning]
    \\kind = "checkbox"
;

test "parses the README example" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), readme_example, null);

    try std.testing.expectEqualStrings("Neon Rain", m.title);
    try std.testing.expectEqual(Kind.web, m.kind);
    try std.testing.expectEqualStrings("index.html", m.entry);
    try std.testing.expect(m.audio);
    try std.testing.expect(!m.asks_network);
    // An older package's `network = true` still loads; nothing acts on it.
    const old = try parse(arena.allocator(), "title = \"t\"\ntype = \"web\"\nentry = \"index.html\"\nnetwork = true\n", null);
    try std.testing.expect(old.asks_network);
    try std.testing.expectEqual(@as(usize, 4), m.properties.len);

    const speed = m.property("speed").?;
    try std.testing.expectEqual(PropertyKind.slider, speed.kind);
    try std.testing.expectEqual(@as(f64, 3.0), speed.max);
    try std.testing.expectEqualStrings("#3fa9f5", m.property("tint").?.default.text);
    // Derived defaults and labels.
    try std.testing.expectEqualStrings("calm", m.property("mood").?.default.text);
    try std.testing.expectEqualStrings("mood", m.property("mood").?.label);
    try std.testing.expect(!m.property("lightning").?.default.boolean);
}

test "reports problems with their line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.UnknownKey, parse(a, "title = \"x\"\ncolour = 1\n", &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);

    try std.testing.expectError(error.MissingField, parse(a, "title = \"x\"\ntype = \"video\"\n", null));
    try std.testing.expectError(error.BadValue, parse(a, "type = \"gif\"\n", null));
    const head = "title = \"x\"\ntype = \"web\"\nentry = \"a.html\"\n";
    try std.testing.expectError(error.InvalidProperty, parse(a, head ++ "[properties.s]\nkind = \"slider\"\nmin = 5\nmax = 1\n", null));
    try std.testing.expectError(error.InvalidProperty, parse(a, head ++ "[properties.c]\nkind = \"color\"\ndefault = \"red\"\n", null));
    try std.testing.expectError(error.InvalidProperty, parse(a, head ++ "[properties.d]\nkind = \"dropdown\"\noptions = [\"a\"]\ndefault = \"b\"\n", null));
    try std.testing.expectError(error.InvalidProperty, parse(a, head ++ "[properties.\"bad name\"]\nkind = \"text\"\n", null));
    try std.testing.expectError(error.UnknownTable, parse(a, head ++ "[other]\nx = 1\n", null));
}

test "the entry must stay inside the package (untrusted packages)" {
    try std.testing.expect(safeEntry("index.html"));
    try std.testing.expect(safeEntry("web/index.html"));
    try std.testing.expect(safeEntry("media\\rain.mp4"));
    for ([_][]const u8{ "", "..\\x.html", "a/../../x", "/etc/passwd", "\\\\server\\s\\x", "C:\\x.mp4", "a.mp4:stream", "... \\x", ".", "a/./b" }) |bad| {
        try std.testing.expect(!safeEntry(bad));
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsafeEntry, parse(arena.allocator(), "title = \"x\"\ntype = \"web\"\nentry = \"../../secret.html\"\n", null));
}
