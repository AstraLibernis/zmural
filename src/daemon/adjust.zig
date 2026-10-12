// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The properties of the main wallpaper when it is a plain video or picture:
//! a fixed set of adjustments (brightness, contrast...), remembered per
//! wallpaper. A wallpaper package brings its own properties instead
//! (`core/manifest.zig`); both go through the same control requests and the
//! same values file, so clients see no difference.
//!
//! The names are mpv's own property names, and `sdk/mpv_options.zig` lists
//! the same ones as the only properties a renderer will set on mpv.
//! Shared by both runtimes.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");
const manifest = zmural.manifest;
const props = zmural.properties;
const Kind = @import("kind.zig").Kind;
const Property = manifest.Property;
const Value = manifest.Value;

fn level(comptime name: []const u8, comptime label: []const u8) Property {
    return .{ .name = name, .kind = .slider, .label = label, .default = .{ .number = 0 }, .min = -100, .max = 100, .step = 1 };
}

/// mpv applies saturation and hue while converting video colours; a picture
/// that is already RGB (a PNG) skips that step, so they would do nothing
/// there (seen on screen, 2026-09-30). Pictures get the three that work.
const picture = [_]Property{
    level("brightness", "Brightness"),
    level("contrast", "Contrast"),
    level("gamma", "Gamma"),
};

const video = [_]Property{
    .{ .name = "speed", .kind = .slider, .label = "Speed", .default = .{ .number = 1 }, .min = 0.25, .max = 4, .step = 0.05 },
    level("brightness", "Brightness"),
    level("contrast", "Contrast"),
    level("saturation", "Saturation"),
    level("gamma", "Gamma"),
    level("hue", "Hue"),
};

/// The adjustments a plain wallpaper of this kind has. Web pages have none.
pub fn properties(kind: Kind) []const Property {
    return switch (kind) {
        .video => &video,
        .image => &picture,
        .web => &.{},
    };
}

/// The properties of one wallpaper and their current values.
pub const Set = struct {
    arena: std.heap.ArenaAllocator,
    m: manifest.Manifest,
    values: []Value,
    /// Where the values are kept; empty when there is nowhere to keep them.
    values_file: []const u8,

    pub fn deinit(s: *Set) void {
        s.arena.deinit();
    }

    /// The list a client gets (`props.parseList` reads it).
    pub fn list(s: *const Set, out: *std.Io.Writer) std.Io.Writer.Error!void {
        return props.writeList(out, s.m, s.values);
    }

    pub const SetError = error{ NoSuchProperty, BadValue, OutOfMemory };

    /// Checks `input` against the property and takes it. Returns its index.
    pub fn set(s: *Set, name: []const u8, input: []const u8) SetError!usize {
        const i = for (s.m.properties, 0..) |p, i| {
            if (std.mem.eql(u8, p.name, name)) break i;
        } else return error.NoSuchProperty;
        var v = try props.coerce(s.m.properties[i], input);
        if (v == .text) v = .{ .text = try s.arena.allocator().dupe(u8, v.text) };
        s.values[i] = v;
        return i;
    }

    pub fn reset(s: *Set) void {
        for (s.m.properties, s.values) |p, *v| v.* = p.default;
    }

    /// Writes the values file (only values that differ from the default).
    pub fn save(s: *const Set, io: std.Io, gpa: std.mem.Allocator) void {
        if (s.values_file.len == 0) return;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        props.writeStored(&out.writer, s.m, s.values) catch return;
        const cwd = std.Io.Dir.cwd();
        const dir = std.fs.path.dirname(s.values_file) orelse return;
        cwd.createDirPath(io, dir) catch |err| return std.log.warn("properties: can't create {s}: {s}", .{ dir, @errorName(err) });
        const tmp = std.fmt.allocPrint(gpa, "{s}.tmp", .{s.values_file}) catch return;
        defer gpa.free(tmp);
        cwd.writeFile(io, .{ .sub_path = tmp, .data = out.written() }) catch |err| return std.log.warn("properties: can't save: {s}", .{@errorName(err)});
        cwd.rename(tmp, cwd, s.values_file, io) catch |err| std.log.warn("properties: can't save: {s}", .{@errorName(err)});
    }
};

/// The built-in adjustments for the plain wallpaper at `path`, with the
/// values saved for it under `config_dir` (null: nothing is read or kept).
/// Null when that kind of wallpaper has none.
pub fn load(gpa: std.mem.Allocator, io: std.Io, config_dir: ?[]const u8, path: []const u8, kind: Kind) error{OutOfMemory}!?Set {
    const list = properties(kind);
    if (list.len == 0) return null;
    var s: Set = .{ .arena = .init(gpa), .m = undefined, .values = &.{}, .values_file = "" };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    s.m = .{
        .title = try a.dupe(u8, std.fs.path.basename(path)),
        .kind = switch (kind) {
            .video => .video,
            .image => .image,
            .web => .web,
        },
        .entry = "",
        .properties = list,
    };
    s.values = try a.alloc(Value, list.len);
    var stored: []const props.Stored = &.{};
    if (config_dir) |dir| {
        s.values_file = try valuesFile(a, dir, path);
        if (std.Io.Dir.cwd().readFileAlloc(io, s.values_file, a, .limited(256 * 1024))) |saved| {
            stored = props.parseStored(a, s.m, saved) catch &.{};
        } else |_| {}
    }
    props.current(s.m, stored, s.values);
    return s;
}

/// A wallpaper package (`<folder>/zmural.toml`): its own properties, the file
/// it shows and as what. `entry` lives in `set`'s arena.
pub const Package = struct {
    set: Set,
    entry: []const u8,
    kind: Kind,
};

pub fn isPackage(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.basename(path), manifest.file_name);
}

/// Reads the package at `path` (its `zmural.toml`) and the values saved for
/// it under `config_dir`. Packages come from anywhere: every problem is
/// logged with its reason and refused.
pub fn loadPackage(gpa: std.mem.Allocator, io: std.Io, config_dir: ?[]const u8, path: []const u8) error{ OutOfMemory, BadPackage }!Package {
    var s: Set = .{ .arena = .init(gpa), .m = undefined, .values = &.{}, .values_file = "" };
    errdefer s.arena.deinit();
    const a = s.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const text = cwd.readFileAlloc(io, path, a, .limited(256 * 1024)) catch |err| {
        std.log.warn("package {s}: can't read it: {s}", .{ path, @errorName(err) });
        return error.BadPackage;
    };
    var diag: manifest.Diagnostic = .{};
    s.m = manifest.parse(a, text, &diag) catch |err| {
        std.log.warn("package {s}: line {d}: {s}", .{ path, diag.line, @errorName(err) });
        return error.BadPackage;
    };
    const folder = std.fs.path.dirname(path) orelse return error.BadPackage;
    const entry = try manifest.entryPath(a, folder, s.m.entry);
    cwd.access(io, entry, .{}) catch {
        std.log.warn("package {s}: the file it names isn't there: {s}", .{ path, s.m.entry });
        return error.BadPackage;
    };
    const kind: Kind = switch (s.m.kind) {
        .video => .video,
        .image => .image,
        .web => .web,
    };
    if ((Kind.forPath(entry) == .web) != (kind == .web)) {
        std.log.warn("package {s}: type = \"{s}\" doesn't match its entry '{s}'", .{ path, @tagName(s.m.kind), s.m.entry });
        return error.BadPackage;
    }
    s.values = try a.alloc(Value, s.m.properties.len);
    var stored: []const props.Stored = &.{};
    if (config_dir) |dir| {
        s.values_file = try valuesFile(a, dir, path);
        if (cwd.readFileAlloc(io, s.values_file, a, .limited(256 * 1024))) |saved| {
            stored = props.parseStored(a, s.m, saved) catch &.{};
        } else |_| {}
    }
    props.current(s.m, stored, s.values);
    if (s.m.asks_network) std.log.warn("package {s}: `network = true` is ignored; web wallpapers are always offline", .{path});
    return .{ .set = s, .entry = entry, .kind = kind };
}

/// `<config>/properties/<hash of the wallpaper's path>.toml`. Windows paths
/// don't differ by case, so there the hash ignores it.
pub fn valuesFile(a: std.mem.Allocator, config_dir: []const u8, path: []const u8) error{OutOfMemory}![]const u8 {
    var hasher = std.hash.Wyhash.init(0);
    if (builtin.os.tag == .windows) {
        for (path) |c| hasher.update(&.{std.ascii.toLower(c)});
    } else hasher.update(path);
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{x:0>16}.toml", .{hasher.final()}) catch unreachable; // zsnag:ok — 21 bytes into 32
    return std.fs.path.join(a, &.{ config_dir, "properties", name });
}

test "a video has six adjustments, a picture the three that work on it, a page none" {
    try std.testing.expectEqualStrings("speed", properties(.video)[0].name);
    try std.testing.expectEqual(@as(usize, 6), properties(.video).len);
    try std.testing.expectEqual(@as(usize, 3), properties(.image).len);
    for (properties(.image)) |p| for ([_][]const u8{ "speed", "saturation", "hue" }) |no| try std.testing.expect(!std.mem.eql(u8, p.name, no));
    try std.testing.expectEqual(@as(usize, 0), properties(.web).len);
    // Every one is a property the renderers are allowed to set on mpv.
    for (properties(.video)) |p| try std.testing.expect(zmural.sdk.mpv_options.isAdjustment(p.name));
}

test "values are checked, kept per wallpaper, and only the changed ones are written" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var buf: [512]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];

    var s = (try load(gpa, io, dir, "/wp/rain.mp4", .video)).?;
    defer s.deinit();
    try std.testing.expectEqualStrings("rain.mp4", s.m.title);
    try std.testing.expectEqual(@as(f64, 1), s.values[0].number);
    try std.testing.expectEqual(@as(usize, 1), try s.set("brightness", "-20"));
    _ = try s.set("speed", "0.5");
    try std.testing.expectError(error.BadValue, s.set("speed", "9"));
    try std.testing.expectError(error.BadValue, s.set("contrast", "loud"));
    try std.testing.expectError(error.NoSuchProperty, s.set("volume", "1"));
    s.save(io, gpa);

    const text = try std.Io.Dir.cwd().readFileAlloc(io, s.values_file, gpa, .limited(4096));
    defer gpa.free(text);
    try std.testing.expect(std.mem.find(u8, text, "brightness = -20") != null);
    try std.testing.expect(std.mem.find(u8, text, "contrast") == null);

    // The same wallpaper again: its values are back. Another one starts clean.
    var again = (try load(gpa, io, dir, "/wp/rain.mp4", .video)).?;
    defer again.deinit();
    try std.testing.expectEqual(@as(f64, -20), again.values[1].number);
    try std.testing.expectEqual(@as(f64, 0.5), again.values[0].number);
    var other = (try load(gpa, io, dir, "/wp/city.mp4", .video)).?;
    defer other.deinit();
    try std.testing.expectEqual(@as(f64, 0), other.values[1].number);

    again.reset();
    again.save(io, gpa);
    var fresh = (try load(gpa, io, dir, "/wp/rain.mp4", .video)).?;
    defer fresh.deinit();
    try std.testing.expectEqual(@as(f64, 0), fresh.values[1].number);

    // Nowhere to keep them: still usable, nothing written.
    var loose = (try load(gpa, io, null, "/wp/rain.mp4", .image)).?;
    defer loose.deinit();
    _ = try loose.set("gamma", "10");
    loose.save(io, gpa);
    try std.testing.expectEqual(@as(?Set, null), try load(gpa, io, dir, "/wp/page/index.html", .web));
}

test "a package names its file and kind, keeps its values, and a bad one is refused" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buf: [1024]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const gpa = std.testing.allocator;
    try tmp.dir.createDirPath(io, "pkg/media");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/media/still.png", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/zmural.toml", .data =
        \\title = "Red"
        \\type = "image"
        \\entry = "media/still.png"
        \\[properties.brightness]
        \\kind = "slider"
        \\label = "Brightness"
        \\default = -20
        \\min = -100
        \\max = 100
        \\
    });
    const path = try std.fs.path.join(gpa, &.{ root, "pkg", "zmural.toml" });
    defer gpa.free(path);
    try std.testing.expect(isPackage(path));
    var pkg = try loadPackage(gpa, io, root, path);
    defer pkg.set.deinit();
    try std.testing.expectEqual(Kind.image, pkg.kind);
    const sep = std.fs.path.sep_str;
    try std.testing.expect(std.mem.endsWith(u8, pkg.entry, "pkg" ++ sep ++ "media" ++ sep ++ "still.png"));
    try std.testing.expectEqual(@as(f64, -20), pkg.set.values[0].number);

    // The file it names is missing; then its type doesn't match the file.
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/zmural.toml", .data = "title = \"x\"\ntype = \"image\"\nentry = \"gone.png\"\n" });
    try std.testing.expectError(error.BadPackage, loadPackage(gpa, io, null, path));
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/zmural.toml", .data = "title = \"x\"\ntype = \"web\"\nentry = \"media/still.png\"\n" });
    try std.testing.expectError(error.BadPackage, loadPackage(gpa, io, null, path));
}
