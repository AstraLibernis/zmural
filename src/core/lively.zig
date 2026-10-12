// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Lively Wallpaper packages, turned into zmural's own (`zmural.toml`) when
//! they are imported. Lively's files stay as they are beside it.
//!
//! The formats, from Lively's source (github.com/rocksdanister/lively,
//! 25a0a5f, 2026-09-29): `LivelyInfo.json` is `Lively.Models/LivelyInfoModel.cs`
//! (Title, Author, License, Type, FileName, IsAbsolutePath...), its `Type` a
//! `WallpaperType` written as a number by Newtonsoft (`app` 0 ... `picture`
//! 11) or, by hand, as its name; `LivelyProperties.json` follows
//! `schemas/livelyPropertiesSchema.json` (a map from name to a control).
//!
//! What zmural shows is only ever a video, a picture or an offline page, so
//! Lively's programs (app, unity, godot, bizhawk), web addresses (url) and
//! streams are refused. Of the controls, button, label and folderDropdown
//! have no counterpart and are left out (and named, for the user).

const std = @import("std");
const toml = @import("toml.zig");
const manifest = @import("manifest.zig");

pub const info_file = "LivelyInfo.json";
pub const properties_file = "LivelyProperties.json";

pub const Error = error{ LivelyBadInfo, LivelyBadProperties, LivelyProgram, LivelyWebAddress, LivelyStream, LivelyOutside, OutOfMemory };

pub const Converted = struct {
    /// The new `zmural.toml`.
    toml: []const u8,
    /// Settings left out, as "name (type)".
    left_out: []const []const u8,
};

/// `WallpaperType`, in Lively's order.
const types = [_][]const u8{ "app", "web", "webaudio", "url", "bizhawk", "unity", "godot", "video", "gif", "unityaudio", "videostream", "picture" };

/// `info` is LivelyInfo.json's text, `props` LivelyProperties.json's (or
/// null); `fallback_title` names it when Lively's file doesn't.
pub fn convert(arena: std.mem.Allocator, info: []const u8, props: ?[]const u8, fallback_title: []const u8) Error!Converted {
    const root = parseObject(arena, info) orelse return error.LivelyBadInfo;
    const type_name = typeName(root.get("Type") orelse return error.LivelyBadInfo) orelse return error.LivelyBadInfo;
    const kind: []const u8, const audio = if (eql(type_name, "video"))
        .{ "video", false }
    else if (eql(type_name, "gif") or eql(type_name, "picture"))
        .{ "image", false }
    else if (eql(type_name, "web"))
        .{ "web", false }
    else if (eql(type_name, "webaudio"))
        .{ "web", true }
    else if (eql(type_name, "url"))
        return error.LivelyWebAddress
    else if (eql(type_name, "videostream"))
        return error.LivelyStream
    else
        return error.LivelyProgram;
    if (boolField(root, "IsAbsolutePath")) return error.LivelyOutside;
    const entry_raw = stringField(root, "FileName") orelse return error.LivelyBadInfo;
    // Lively packages are made on Windows: its separators are backslashes.
    const entry = try arena.dupe(u8, entry_raw);
    std.mem.replaceScalar(u8, entry, '\\', '/');
    if (!manifest.safeEntry(entry)) return error.LivelyOutside;

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var left_out: std.ArrayList([]const u8) = .empty;
    writeHead(w, root, fallback_title, kind, entry, audio) catch return error.OutOfMemory;
    if (props) |text| {
        const obj = parseObject(arena, text) orelse return error.LivelyBadProperties;
        var it = obj.iterator();
        var n: usize = 0;
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            const ctl = switch (e.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            const ctype = stringField(ctl, "type") orelse "?";
            const ok = manifest.validName(name) and n < manifest.max_properties and
                (writeProperty(w, name, ctype, ctl) catch return error.OutOfMemory);
            if (ok) n += 1 else try left_out.append(arena, try std.fmt.allocPrint(arena, "{s} ({s})", .{ name, ctype }));
        }
    }
    return .{ .toml = out.written(), .left_out = left_out.items };
}

fn writeHead(w: *std.Io.Writer, root: std.json.ObjectMap, fallback_title: []const u8, kind: []const u8, entry: []const u8, audio: bool) !void {
    try w.writeAll("# Converted from a Lively Wallpaper package (LivelyInfo.json) when it was imported.\n");
    try w.writeAll("title = ");
    const title = stringField(root, "Title") orelse "";
    try toml.writeString(w, clean(if (title.len > 0) title else fallback_title));
    try w.writeByte('\n');
    for ([_][2][]const u8{ .{ "author", "Author" }, .{ "license", "License" } }) |f| {
        const v = stringField(root, f[1]) orelse continue;
        if (v.len == 0) continue;
        try w.print("{s} = ", .{f[0]});
        try toml.writeString(w, clean(v));
        try w.writeByte('\n');
    }
    try w.print("type = \"{s}\"\nentry = ", .{kind});
    try toml.writeString(w, entry);
    try w.writeByte('\n');
    if (audio) try w.writeAll("audio = true\n");
}

/// One control as a `[properties.<name>]` table; false when it has no
/// counterpart or its values don't make sense (then nothing is written).
fn writeProperty(w: *std.Io.Writer, name: []const u8, ctype: []const u8, ctl: std.json.ObjectMap) !bool {
    const label = clean(stringField(ctl, "text") orelse name);
    if (eql(ctype, "slider")) {
        const min = numberField(ctl, "min") orelse return false;
        const max = numberField(ctl, "max") orelse return false;
        if (!(min < max)) return false;
        const step = @max(0, numberField(ctl, "step") orelse 0);
        const value = std.math.clamp(numberField(ctl, "value") orelse min, min, max);
        try head(w, name, "slider", label);
        try w.print("default = {d}\nmin = {d}\nmax = {d}\nstep = {d}\n", .{ value, min, max, step });
    } else if (eql(ctype, "checkbox")) {
        try head(w, name, "checkbox", label);
        try w.print("default = {}\n", .{boolField(ctl, "value")});
    } else if (eql(ctype, "color")) {
        const v = stringField(ctl, "value") orelse "#ffffff";
        if (!manifest.validColor(v)) return false;
        try head(w, name, "color", label);
        try w.writeAll("default = ");
        try toml.writeString(w, v);
        try w.writeByte('\n');
    } else if (eql(ctype, "textbox")) {
        const v = stringField(ctl, "value") orelse "";
        try head(w, name, "text", label);
        try w.writeAll("default = ");
        try toml.writeString(w, clean(v[0..@min(v.len, manifest.max_text_len)]));
        try w.writeByte('\n');
    } else if (eql(ctype, "dropdown")) {
        const items = switch (ctl.get("items") orelse return false) {
            .array => |a| a.items,
            else => return false,
        };
        if (items.len == 0) return false;
        for (items) |i| if (i != .string or i.string.len == 0) return false;
        const index: usize = @intFromFloat(std.math.clamp(@floor(numberField(ctl, "value") orelse 0), 0, @as(f64, @floatFromInt(items.len - 1))));
        try head(w, name, "dropdown", label);
        try w.writeAll("default = ");
        try toml.writeString(w, clean(items[index].string));
        try w.writeAll("\noptions = [");
        for (items, 0..) |i, k| {
            if (k > 0) try w.writeAll(", ");
            try toml.writeString(w, clean(i.string));
        }
        try w.writeAll("]\n");
    } else return false; // button, label, folderDropdown, anything newer
    return true;
}

fn head(w: *std.Io.Writer, name: []const u8, kind: []const u8, label: []const u8) !void {
    try w.print("\n[properties.{s}]\nkind = \"{s}\"\nlabel = ", .{ name, kind });
    try toml.writeString(w, label[0..@min(label.len, 200)]);
    try w.writeByte('\n');
}

/// zmural's TOML subset has no multi-line strings: only the first line is kept.
fn clean(s: []const u8) []const u8 {
    return s[0 .. std.mem.findAny(u8, s, "\r\n") orelse s.len];
}

fn parseObject(arena: std.mem.Allocator, text: []const u8) ?std.json.ObjectMap {
    // Windows tools often start a UTF-8 file with a BOM.
    const body = if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, relaxed(arena, body) catch return null, .{}) catch return null;
    return if (v == .object) v.object else null;
}

/// Lively reads its files with Newtonsoft, which takes comments and trailing
/// commas, and Lively's own wallpapers have both (audiorbits'
/// LivelyProperties.json): this drops them, outside strings, for std.json.
fn relaxed(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, text.len);
    var i: usize = 0;
    var in_string = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            out.appendAssumeCapacity(c);
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                out.appendAssumeCapacity(text[i]);
            } else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
            continue;
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i = if (std.mem.findPos(u8, text, i + 2, "*/")) |end| end + 1 else text.len;
            continue;
        } else if (c == '}' or c == ']') {
            // A comma before this closer, with only whitespace between, goes.
            var j = out.items.len;
            while (j > 0 and std.ascii.isWhitespace(out.items[j - 1])) j -= 1;
            if (j > 0 and out.items[j - 1] == ',') out.items[j - 1] = ' ';
        }
        out.appendAssumeCapacity(c);
    }
    return out.items;
}

test relaxed {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\{"a": [1, 2, ], /* a note */ "u": "http://x/*y*/,}", // and one more
        \\ "b": {"c": true,},
        \\}
    ;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, try relaxed(a, text), .{});
    try std.testing.expectEqual(@as(usize, 2), v.object.get("a").?.array.items.len);
    // Inside a string nothing changes.
    try std.testing.expectEqualStrings("http://x/*y*/,}", v.object.get("u").?.string);
    try std.testing.expect(v.object.get("b").?.object.get("c").?.bool);
}

/// A number (Newtonsoft's default) or a name, case-insensitive.
fn typeName(v: std.json.Value) ?[]const u8 {
    switch (v) {
        .integer => |i| return if (i >= 0 and i < types.len) types[@intCast(i)] else null,
        .string => |s| {
            for (types) |t| if (std.ascii.eqlIgnoreCase(s, t)) return t;
            return null;
        },
        else => return null,
    }
}

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn numberField(o: std.json.ObjectMap, key: []const u8) ?f64 {
    const n: f64 = switch (o.get(key) orelse return null) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}

fn boolField(o: std.json.ObjectMap, key: []const u8) bool {
    return switch (o.get(key) orelse return false) {
        .bool => |b| b,
        else => false,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "a Lively web wallpaper with every kind of control converts, and the result parses" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const info =
        \\{"AppVersion":"2.1.0.0","Title":"Fluids","Thumbnail":"thumb.jpg","Desc":"Fluid sim","Author":"someone",
        \\ "License":"MIT","Type":2,"FileName":"web\\index.html","Arguments":null,"IsAbsolutePath":false,"Tags":["a"]}
    ;
    const props =
        \\{
        \\ "speed": {"type":"slider","text":"Speed","min":0.1,"max":3,"step":0.1,"value":1.5},
        \\ "tint": {"type":"color","text":"Tint","value":"#C0C0C0"},
        \\ "glow": {"type":"checkbox","text":"Glow","value":true},
        \\ "mode": {"type":"dropdown","text":"Mode","value":1,"items":["Calm","Wild","Storm"]},
        \\ "caption": {"type":"textbox","text":"Caption","value":"hello"},
        \\ "reset": {"type":"button","text":"Reset","value":"Go"},
        \\ "note": {"type":"label","value":"Made with love"},
        \\ "bg": {"type":"folderDropdown","text":"Background","value":"a.jpg","filter":"*.jpg","folder":"img"},
        \\ "bad name": {"type":"checkbox","text":"x","value":false}
        \\}
    ;
    const c = try convert(a, "\xEF\xBB\xBF" ++ info, props, "folder");
    const m = try manifest.parse(a, c.toml, null);
    try std.testing.expectEqualStrings("Fluids", m.title);
    try std.testing.expectEqualStrings("someone", m.author);
    try std.testing.expectEqual(manifest.Kind.web, m.kind);
    try std.testing.expect(m.audio); // webaudio
    try std.testing.expectEqualStrings("web/index.html", m.entry);
    try std.testing.expectEqual(@as(usize, 5), m.properties.len);
    try std.testing.expectEqual(@as(f64, 1.5), m.property("speed").?.default.number);
    try std.testing.expectEqualStrings("#C0C0C0", m.property("tint").?.default.text);
    try std.testing.expect(m.property("glow").?.default.boolean);
    try std.testing.expectEqualStrings("Wild", m.property("mode").?.default.text);
    try std.testing.expectEqual(@as(usize, 3), m.property("mode").?.options.len);
    try std.testing.expectEqualStrings("hello", m.property("caption").?.default.text);
    try std.testing.expectEqual(@as(usize, 4), c.left_out.len);
    try std.testing.expectEqualStrings("reset (button)", c.left_out[0]);
}

test "Lively video and picture types, by number or name; programs, addresses, streams and outside files refused" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const video = try convert(a, "{\"Type\":7,\"FileName\":\"rain.mp4\"}", null, "Rain");
    const m = try manifest.parse(a, video.toml, null);
    try std.testing.expectEqual(manifest.Kind.video, m.kind);
    try std.testing.expectEqualStrings("Rain", m.title); // from the folder: no Title
    try std.testing.expectEqual(manifest.Kind.image, (try manifest.parse(a, (try convert(a, "{\"Type\":\"Picture\",\"FileName\":\"a.png\"}", null, "x")).toml, null)).kind);
    try std.testing.expectEqual(manifest.Kind.image, (try manifest.parse(a, (try convert(a, "{\"Type\":8,\"FileName\":\"a.gif\"}", null, "x")).toml, null)).kind);
    for ([_]u8{ 0, 4, 5, 6, 9 }) |t| {
        const text = try std.fmt.allocPrint(a, "{{\"Type\":{d},\"FileName\":\"x.exe\"}}", .{t});
        try std.testing.expectError(error.LivelyProgram, convert(a, text, null, "x"));
    }
    try std.testing.expectError(error.LivelyWebAddress, convert(a, "{\"Type\":3,\"FileName\":\"https://example.com\"}", null, "x"));
    try std.testing.expectError(error.LivelyStream, convert(a, "{\"Type\":10,\"FileName\":\"x\"}", null, "x"));
    try std.testing.expectError(error.LivelyOutside, convert(a, "{\"Type\":7,\"FileName\":\"C:\\\\Users\\\\me\\\\rain.mp4\",\"IsAbsolutePath\":true}", null, "x"));
    try std.testing.expectError(error.LivelyOutside, convert(a, "{\"Type\":7,\"FileName\":\"..\\\\..\\\\rain.mp4\"}", null, "x"));
    try std.testing.expectError(error.LivelyBadInfo, convert(a, "{\"Type\":99,\"FileName\":\"a.mp4\"}", null, "x"));
    try std.testing.expectError(error.LivelyBadInfo, convert(a, "not json", null, "x"));
}
