// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Property values: checking what the user sets against the manifest, the
//! per-wallpaper values file, and the forms values travel in (JSON for web
//! pages, a flat list for the control pipe). Pure, so it's tested here.
//!
//! A value is always checked against its property before it is stored or
//! sent anywhere: sliders stay in range, colours are "#rrggbb", dropdowns
//! pick one of their options, and text has no control characters.

const std = @import("std");
const manifest = @import("manifest.zig");
const toml = @import("toml.zig");
const Property = manifest.Property;
const Value = manifest.Value;

pub const Error = error{ BadValue, OutOfMemory };

/// Turns user input (CLI, settings window, values file) into a checked value.
pub fn coerce(p: Property, input: []const u8) Error!Value {
    const t = std.mem.trim(u8, input, " \t\r\n");
    switch (p.kind) {
        .slider => {
            const f = std.fmt.parseFloat(f64, t) catch return error.BadValue;
            if (!std.math.isFinite(f) or f < p.min or f > p.max) return error.BadValue;
            return .{ .number = f };
        },
        .checkbox => {
            for ([_][]const u8{ "true", "on", "yes", "1" }) |y| if (std.ascii.eqlIgnoreCase(t, y)) return .{ .boolean = true };
            for ([_][]const u8{ "false", "off", "no", "0" }) |n| if (std.ascii.eqlIgnoreCase(t, n)) return .{ .boolean = false };
            return error.BadValue;
        },
        .color => return if (manifest.validColor(t)) .{ .text = t } else error.BadValue,
        .dropdown => {
            for (p.options) |o| if (std.mem.eql(u8, o, t)) return .{ .text = o };
            return error.BadValue;
        },
        .text => {
            if (input.len > manifest.max_text_len) return error.BadValue;
            for (input) |c| if (c < 0x20 or c == 0x7f) return error.BadValue;
            return .{ .text = input };
        },
    }
}

/// The value as the user would type it back.
pub fn writeText(out: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v) {
        .number => |f| try out.print("{d}", .{f}),
        .boolean => |b| try out.writeAll(if (b) "true" else "false"),
        .text => |s| try out.writeAll(s),
    }
}

/// The value as a JSON literal, for web pages.
pub fn writeJson(out: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v) {
        .number => |f| try out.print("{d}", .{f}),
        .boolean => |b| try out.writeAll(if (b) "true" else "false"),
        .text => |s| try writeJsonString(out, s),
    }
}

pub fn writeJsonString(out: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try out.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        // `<` too, so a value can never close a <script> it's embedded in.
        0...0x1f, 0x7f, '<', '>', '&' => try out.print("\\u{x:0>4}", .{c}),
        else => try out.writeByte(c),
    };
    try out.writeByte('"');
}

/// The current value of every property: stored ones where they're still
/// valid, defaults for the rest. `out` has one slot per property.
pub fn current(m: manifest.Manifest, stored: []const Stored, out: []Value) void {
    for (m.properties, out) |p, *o| {
        o.* = p.default;
        for (stored) |s| if (std.mem.eql(u8, s.name, p.name)) {
            o.* = s.value;
        };
    }
}

pub const Stored = struct { name: []const u8, value: Value };

/// Reads a values file (`name = value` lines), keeping only values that are
/// still valid for `m`: a package update may have changed its properties.
pub fn parseStored(arena: std.mem.Allocator, m: manifest.Manifest, text: []const u8) Error![]Stored {
    const entries = toml.parse(arena, text, null) catch return error.BadValue;
    var out: std.ArrayList(Stored) = .empty;
    for (entries) |e| {
        if (e.table.len != 0) continue;
        const p = m.property(e.key) orelse continue;
        var buf: [64]u8 = undefined;
        const input: []const u8 = switch (e.value) {
            .string => |s| s,
            .boolean => |b| if (b) "true" else "false",
            .int => |i| std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue,
            .float => |f| std.fmt.bufPrint(&buf, "{d}", .{f}) catch continue,
            .strings => continue,
        };
        var v = coerce(p, input) catch continue;
        // `input` may live in `buf` (`caption = 5`): text must be copied out.
        if (v == .text) v = .{ .text = try arena.dupe(u8, v.text) };
        try out.append(arena, .{ .name = p.name, .value = v });
    }
    return out.items;
}

/// Writes a values file. Only values that differ from the default are kept.
pub fn writeStored(out: *std.Io.Writer, m: manifest.Manifest, values: []const Value) std.Io.Writer.Error!void {
    try out.writeAll("# zmural property values for one wallpaper (the settings window keeps this up to date)\n");
    for (m.properties, values) |p, v| {
        if (v.eql(p.default)) continue;
        try out.print("{s} = ", .{p.name});
        switch (v) {
            .number => |f| try out.print("{d}", .{f}),
            .boolean => |b| try out.writeAll(if (b) "true" else "false"),
            .text => |s| try toml.writeString(out, s),
        }
        try out.writeByte('\n');
    }
}

// ---- the list the control pipe carries ------------------------------------------------

/// Separators in `writeList`: none can appear in a checked name, label or value
/// (labels have them replaced).
const field_sep = 0x1f;
const record_sep = 0x1e;
const option_sep = 0x1d;

/// One property, as a client (settings window, CLI) sees it.
pub const Item = struct {
    name: []const u8,
    kind: manifest.PropertyKind,
    label: []const u8,
    /// The current value and the default, as text (`writeText`).
    value: []const u8,
    default: []const u8,
    min: f64,
    max: f64,
    step: f64,
    options: []const []const u8,
};

pub fn writeList(out: *std.Io.Writer, m: manifest.Manifest, values: []const Value) std.Io.Writer.Error!void {
    for (m.properties, values, 0..) |p, v, i| {
        if (i > 0) try out.writeByte(record_sep);
        try out.print("{s}{c}{s}{c}", .{ p.name, field_sep, @tagName(p.kind), field_sep });
        try writeClean(out, p.label);
        try out.writeByte(field_sep);
        try writeText(out, v);
        try out.writeByte(field_sep);
        try writeText(out, p.default);
        try out.print("{c}{d}{c}{d}{c}{d}{c}", .{ field_sep, p.min, field_sep, p.max, field_sep, p.step, field_sep });
        for (p.options, 0..) |o, j| {
            if (j > 0) try out.writeByte(option_sep);
            try writeClean(out, o);
        }
    }
}

fn writeClean(out: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| try out.writeByte(if (c < 0x20) ' ' else c);
}

/// Parses `writeList`'s output; strings borrow `text`.
pub fn parseList(arena: std.mem.Allocator, text: []const u8) Error![]Item {
    var items: std.ArrayList(Item) = .empty;
    if (text.len == 0) return items.items;
    var records = std.mem.splitScalar(u8, text, record_sep);
    while (records.next()) |r| {
        var f = std.mem.splitScalar(u8, r, field_sep);
        var fields: [9][]const u8 = undefined;
        for (&fields) |*x| x.* = f.next() orelse return error.BadValue;
        var options: std.ArrayList([]const u8) = .empty;
        if (fields[8].len > 0) {
            var o = std.mem.splitScalar(u8, fields[8], option_sep);
            while (o.next()) |x| try options.append(arena, x);
        }
        try items.append(arena, .{
            .name = fields[0],
            .kind = std.meta.stringToEnum(manifest.PropertyKind, fields[1]) orelse return error.BadValue,
            .label = fields[2],
            .value = fields[3],
            .default = fields[4],
            .min = std.fmt.parseFloat(f64, fields[5]) catch return error.BadValue,
            .max = std.fmt.parseFloat(f64, fields[6]) catch return error.BadValue,
            .step = std.fmt.parseFloat(f64, fields[7]) catch return error.BadValue,
            .options = options.items,
        });
    }
    return items.items;
}

// ---- tests ------------------------------------------------------------------------------

const testing = std.testing;

const example =
    \\title = "t"
    \\type = "web"
    \\entry = "index.html"
    \\[properties.speed]
    \\kind = "slider"
    \\min = 0
    \\max = 10
    \\default = 2
    \\[properties.tint]
    \\kind = "color"
    \\default = "#102030"
    \\[properties.mood]
    \\kind = "dropdown"
    \\options = ["calm", "storm"]
    \\[properties.rain]
    \\kind = "checkbox"
    \\default = true
    \\[properties.caption]
    \\kind = "text"
    \\label = "Caption"
;

test "coerce checks every kind" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try manifest.parse(arena.allocator(), example, null);
    try testing.expectEqual(@as(f64, 7.5), (try coerce(m.property("speed").?, " 7.5 ")).number);
    try testing.expectError(error.BadValue, coerce(m.property("speed").?, "11"));
    try testing.expectError(error.BadValue, coerce(m.property("speed").?, "nan"));
    try testing.expectEqualStrings("#ABCDEF", (try coerce(m.property("tint").?, "#ABCDEF")).text);
    try testing.expectError(error.BadValue, coerce(m.property("tint").?, "red"));
    try testing.expectEqualStrings("storm", (try coerce(m.property("mood").?, "storm")).text);
    try testing.expectError(error.BadValue, coerce(m.property("mood").?, "sunny"));
    try testing.expect(!(try coerce(m.property("rain").?, "off")).boolean);
    try testing.expectError(error.BadValue, coerce(m.property("caption").?, "two\nlines"));
}

test "JSON strings can't break out of a script" {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    try writeJson(&out, .{ .text = "</script><x \"q\" \\ \n" });
    try testing.expectEqualStrings("\"\\u003c/script\\u003e\\u003cx \\\"q\\\" \\\\ \\u000a\"", out.buffered());
}

test "stored values round trip, and stale ones are dropped" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try manifest.parse(a, example, null);
    var values: [5]Value = undefined;
    current(m, &.{}, &values);
    values[0] = .{ .number = 4.25 };
    values[2] = .{ .text = "storm" };
    values[4] = .{ .text = "it's \"quoted\"" };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeStored(&out.writer, m, &values);
    // Defaults aren't written.
    try testing.expect(std.mem.find(u8, out.written(), "tint") == null);

    const text = try std.fmt.allocPrint(a, "{s}old_prop = 1\nspeed_typo = 3\nmood = \"sunny\"\n", .{out.written()});
    // A number where text is expected is taken as text (and copied, not borrowed).
    const numeric = try parseStored(a, m, "caption = 5\n");
    try testing.expectEqualStrings("5", numeric[0].value.text);
    const stored = try parseStored(a, m, text);
    var back: [5]Value = undefined;
    current(m, stored, &back);
    try testing.expectEqual(@as(f64, 4.25), back[0].number);
    // The later, invalid `mood = "sunny"` was dropped; the earlier valid one stands.
    try testing.expectEqualStrings("storm", back[2].text);
    try testing.expectEqualStrings("it's \"quoted\"", back[4].text);
    try testing.expectEqualStrings("#102030", back[1].text);
}

test "the control-pipe list round trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try manifest.parse(a, example, null);
    var values: [5]Value = undefined;
    current(m, &.{}, &values);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeList(&out.writer, m, &values);
    const items = try parseList(a, out.written());
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqualStrings("speed", items[0].name);
    try testing.expectEqualStrings("2", items[0].value);
    try testing.expectEqual(@as(f64, 10), items[0].max);
    try testing.expectEqual(manifest.PropertyKind.dropdown, items[2].kind);
    try testing.expectEqualStrings("storm", items[2].options[1]);
    try testing.expectEqualStrings("Caption", items[4].label);
    try testing.expectEqual(@as(usize, 0), (try parseList(a, "")).len);
}
