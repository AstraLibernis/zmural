// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! `zmural-console import <file.zip> [--to <folder>] [--apply]`: unpacks a
//! wallpaper package (or a zip of videos and pictures) into a library folder,
//! checked first (`core/package_zip.zig`), then has zmural rescan.
//! `zmural-console export <wallpaper> [<file.zip>]` is the other way.
//!
//! It runs here, in the console's own process, not in zmural: a zip comes
//! from anywhere, and a bug in reading one must not take the wallpaper down.

const std = @import("std");
const builtin = @import("builtin");
const zmural = @import("zmural");
const words = @import("words.zig");
const control = zmural.protocol.control;
const pz = zmural.package_zip;

const windows = builtin.os.tag == .windows;
const client = if (windows) zmural.sdk.control_client else zmural.sdk.control_client_linux;

pub const usage = "usage: zmural-console import <file.zip> [--to <folder>] [--apply] [--report <file>]";

/// `--report <file>`: the outcome is also written there, one line ("ok
/// <folder>" or "error <why>"), for the settings window, which runs this
/// as its own process and has no console to read.
var report_io: ?std.Io = null;
var report_path: ?[]const u8 = null;

fn report(comptime fmt: []const u8, args: anytype) void {
    const io = report_io orelse return;
    const path = report_path orelse return;
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = line }) catch {}; // zsnag:ok — the window then says it couldn't tell
}

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var zip_path: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var apply = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--apply")) {
            apply = true;
        } else if (std.mem.eql(u8, a, "--report")) {
            i += 1;
            if (i == args.len) fail(2, usage, .{});
            report_io = io;
            report_path = args[i];
        } else if (std.mem.eql(u8, a, "--to")) {
            i += 1;
            if (i == args.len) fail(2, usage, .{});
            to = args[i];
        } else if (zip_path == null and !std.mem.startsWith(u8, a, "--")) {
            zip_path = a;
        } else fail(2, usage, .{});
    }
    const path = zip_path orelse fail(2, usage, .{});

    const daemon = connect(init);
    defer if (daemon) |c| c.close(init.gpa);

    // Where to: the folder given, else zmural's first standard folder
    // (Videos/Wallpapers), which it always scans.
    const target = if (to) |t| try client.absolutePath(arena, t) else blk: {
        const c = daemon orelse fail(3, "zmural isn't running, so its library folders aren't known: start it, or give --to <folder>", .{});
        const ev = c.request(.get_settings) catch |err| fail(1, "zmural didn't answer ({s})", .{words.of(err)});
        if (ev != .settings) fail(1, "zmural didn't send its folders", .{});
        var dirs = std.mem.splitScalar(u8, ev.settings.default_dirs, control.list_sep);
        const first = dirs.first();
        if (first.len == 0) fail(1, "zmural has no standard library folder", .{});
        break :blk try arena.dupe(u8, first);
    };

    const cwd = std.Io.Dir.cwd();
    const file = cwd.openFile(io, path, .{}) catch |err| fail(1, "can't open {s} ({s})", .{ path, words.of(err) });
    defer file.close(io);
    var read_buf: [64 * 1024]u8 = undefined;
    var fr = file.reader(io, &read_buf);

    var diag: pz.Diagnostic = .{};
    const checked = pz.check(arena, &fr, .{}, &diag) catch |err| refuse(path, err, &diag);

    // A failed import leaves nothing behind, folders it had to make included:
    // the topmost one that wasn't there yet is where removing stops.
    var made_from: ?[]const u8 = null;
    {
        var p: ?[]const u8 = target;
        while (p) |dir| : (p = std.fs.path.dirname(dir)) {
            if (cwd.openDir(io, dir, .{})) |d| {
                d.close(io);
                break;
            } else |_| made_from = dir;
        }
    }
    cwd.createDirPath(io, target) catch |err| fail(1, "can't make {s} ({s})", .{ target, words.of(err) });
    var parent = cwd.openDir(io, target, .{}) catch |err| fail(1, "can't open {s} ({s})", .{ target, words.of(err) });
    defer parent.close(io);
    const name = pz.folderName(path, checked);
    const made = pz.unpack(arena, io, &fr, checked, parent, name, &diag) catch |err| {
        // Closed first (Windows won't remove an open folder); `refuse` exits,
        // so the deferred close never runs.
        parent.close(io);
        if (made_from) |top| {
            var p: ?[]const u8 = target;
            while (p) |dir| : (p = std.fs.path.dirname(dir)) {
                cwd.deleteDir(io, dir) catch break; // zsnag:ok — only an empty folder goes; anything else stays
                if (std.mem.eql(u8, dir, top)) break;
            }
        }
        refuse(path, err, &diag);
    };
    const folder = try std.fs.path.join(arena, &.{ target, made.name });
    if (windows) {
        // Unmarked, the files would lose a warning they should have: undo it.
        const unmarked = markLikeZip(arena, io, path, folder) catch 1;
        if (unmarked > 0) {
            parent.deleteTree(io, made.name) catch |err| fail(1, "{s}: its files couldn't be marked as downloaded, nor the folder removed ({s}): delete {s}", .{ path, words.of(err), folder });
            fail(1, "not imported: {s}: its files couldn't be marked as downloaded, as the zip is", .{path});
        }
    }

    report("ok {s}", .{folder});
    try out.print("imported {s} ({d} file{s}, {Bi:.1}) into {s}\n", .{
        switch (checked.kind) {
            .package => "a wallpaper package",
            .lively => "a Lively wallpaper (converted to a zmural package)",
            .media => "wallpapers",
        },
        checked.files,
        if (checked.files == 1) "" else "s",
        checked.bytes,
        folder,
    });
    if (made.left_out.len > 0) {
        try out.writeAll("left out (no counterpart in zmural):");
        for (made.left_out) |l| try out.print(" {s}", .{l});
        try out.writeByte('\n');
    }
    // What to show it by: a package's manifest, else its first wallpaper.
    const show = if (checked.kind != .media) try std.fs.path.join(arena, &.{ folder, zmural.media.package_manifest }) else firstPlayable(arena, io, folder);

    const c = daemon orelse {
        try out.writeAll("zmural isn't running; it lists the new wallpaper when it starts (if the folder is one of its library folders)\n");
        try out.flush();
        if (apply) fail(3, "can't apply it: zmural isn't running", .{});
        return;
    };
    _ = c.request(.rescan) catch {}; // zsnag:ok — the wallpaper is unpacked either way; a rescan only lists it sooner
    if (apply) if (show) |p| {
        switch (c.request(.{ .apply = .{ .path = p } }) catch |err| fail(1, "zmural didn't answer ({s})", .{words.of(err)})) {
            .ok => try out.print("showing {s}\n", .{p}),
            .failed => |f| fail(1, "zmural didn't show it: {s}", .{f.message}),
            else => {},
        }
    };
    try out.flush();
}

pub const export_usage = "usage: zmural-console export <wallpaper, package or folder: a path, or a name in the library> [<file.zip>]";

pub fn runExport(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !void {
    if (args.len == 0 or args.len > 2 or std.mem.startsWith(u8, args[0], "--")) fail(2, export_usage, .{});
    const arena = init.arena.allocator();
    const given = std.mem.trimEnd(u8, args[0], "/\\");
    const source = try fromLibrary(init, given) orelse try client.absolutePath(arena, given);
    const dest = if (args.len == 2) args[1] else blk: {
        // Named like the wallpaper, here: "Neon Rain.zip", "rain.zip".
        const name = zmural.media.displayName(source);
        const stem = if (std.mem.findScalarLast(u8, name, '.')) |dot| (if (dot > 0) name[0..dot] else name) else name;
        break :blk try std.fmt.allocPrint(arena, "{s}.zip", .{stem});
    };
    var diag: pz.Diagnostic = .{};
    const res = pz.exportTo(init.gpa, init.io, source, dest, .{}, &diag) catch |err| {
        if (diag.name().len > 0) fail(1, "not exported: {s} ('{s}')", .{ pz.describe(err), diag.name() });
        if (diag.cause) |c| fail(1, "not exported: {s} ({s})", .{ pz.describe(err), words.of(c) });
        fail(1, "not exported: {s}", .{pz.describe(err)});
    };
    try out.print("exported {d} file{s} ({Bi:.1}) to {s}\n", .{ res.files, if (res.files == 1) "" else "s", res.bytes, dest });
    try out.flush();
}

/// A bare name that isn't a file here ("rain.mp4", "Neon Rain"): the
/// wallpaper of that name in zmural's library, as `zmural-console status` and
/// the settings window name them. Null when it is a path, or a file here.
fn fromLibrary(init: std.process.Init, name: []const u8) !?[]const u8 {
    if (std.mem.findAny(u8, name, "/\\") != null) return null;
    if (std.Io.Dir.cwd().statFile(init.io, name, .{})) |_| return null else |_| {}
    const arena = init.arena.allocator();
    const c = connect(init) orelse fail(3, "{s} isn't a file here, and zmural isn't running to look it up in the library: give its path", .{name});
    defer c.close(init.gpa);
    var found: std.ArrayList([]const u8) = .empty;
    var offset: u32 = 0;
    while (true) {
        const ev = c.request(.{ .library = .{ .offset = offset } }) catch |err| fail(1, "zmural didn't answer ({s})", .{words.of(err)});
        if (ev != .library) break;
        var it = std.mem.splitScalar(u8, ev.library.paths, control.list_sep);
        var got: u32 = 0;
        while (it.next()) |p| {
            if (p.len == 0) continue;
            got += 1;
            if (std.mem.eql(u8, zmural.media.displayName(p), name)) try found.append(arena, try arena.dupe(u8, p));
        }
        offset += got;
        if (got == 0 or offset >= ev.library.total) break;
    }
    switch (found.items.len) {
        0 => fail(1, "no file {s} here, and no wallpaper by that name in the library", .{name}),
        1 => {},
        else => fail(1, "{d} wallpapers in the library are named {s}: give the path of the one you mean, e.g. {s}", .{ found.items.len, name, found.items[0] }),
    }
    const p = found.items[0];
    // A package is listed by its manifest; it is exported as its folder.
    return if (std.ascii.eqlIgnoreCase(std.fs.path.basename(p), zmural.media.package_manifest)) std.fs.path.dirname(p) orelse p else p;
}

/// The running zmural, or null when there's none (or the one answering
/// isn't ours: then nothing is sent to it).
fn connect(init: std.process.Init) ?*client.Client {
    var addr_buf: [256]u8 = undefined;
    if (windows) {
        const addr = client.address(&addr_buf) catch return null;
        return client.Client.connect(init.gpa, addr, "zmural-console") catch null;
    }
    const addr = client.address(&addr_buf, zmural.os.xdg.dir(init.environ_map.get("XDG_RUNTIME_DIR"))) catch return null;
    return client.Client.connect(init.gpa, addr, "zmural-console", 10_000) catch null;
}

/// Windows marks a downloaded file (the "Mark of the Web", its
/// `Zone.Identifier` stream), so that opening a program from it warns first.
/// Every file unpacked from a marked zip gets the zip's mark, as Windows' own
/// Extract All does: otherwise a program that came in a package would open
/// from the library folder without a warning. Returns how many files
/// couldn't be marked (none when the zip has no mark).
fn markLikeZip(arena: std.mem.Allocator, io: std.Io, zip_path: []const u8, folder: []const u8) !usize {
    const w = zmural.os.win32;
    const zip_abs = try client.absolutePath(arena, zip_path);
    const mark = readStream(arena, try std.fmt.allocPrint(arena, "{s}:Zone.Identifier", .{zip_abs})) orelse return 0;
    var dir = try std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit();
    var failed: usize = 0;
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        const name = try std.unicode.wtf8ToWtf16LeAllocZ(arena, try std.fmt.allocPrint(arena, "{s}\\{s}:Zone.Identifier", .{ folder, e.path }));
        const h = w.CreateFileW(name, w.GENERIC_WRITE, 0, null, w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
        if (h == w.INVALID_HANDLE_VALUE) {
            failed += 1;
            continue;
        }
        defer _ = w.CloseHandle(h);
        var done: w.DWORD = 0;
        if (w.WriteFile(h, mark.ptr, @intCast(mark.len), &done, null) == 0 or done != mark.len) failed += 1; // zsnag:ok — at most 64 KiB (readStream)
    }
    return failed;
}

/// A file's (or stream's) contents, up to 64 KiB; null if it can't be read.
fn readStream(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const w = zmural.os.win32;
    const name = std.unicode.wtf8ToWtf16LeAllocZ(arena, path) catch return null;
    const h = w.CreateFileW(name, w.GENERIC_READ, w.FILE_SHARE_READ, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
    if (h == w.INVALID_HANDLE_VALUE) return null;
    defer _ = w.CloseHandle(h);
    const buf = arena.alloc(u8, 64 * 1024) catch return null;
    var len: usize = 0;
    while (len < buf.len) {
        var got: w.DWORD = 0;
        if (w.ReadFile(h, buf[len..].ptr, @intCast(buf.len - len), &got, null) == 0) return null; // zsnag:ok — at most 64 KiB
        if (got == 0) break;
        len += got;
    }
    return if (len > 0) buf[0..len] else null;
}

/// The first wallpaper file at the top of `folder`, by name.
fn firstPlayable(arena: std.mem.Allocator, io: std.Io, folder: []const u8) ?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch return best) |e| {
        if (e.kind != .file or !zmural.media.isPlayable(e.name)) continue;
        if (best == null or std.mem.order(u8, e.name, best.?) == .lt) best = arena.dupe(u8, e.name) catch return null;
    }
    return std.fs.path.join(arena, &.{ folder, best orelse return null }) catch null;
}

fn refuse(path: []const u8, err: pz.Error, diag: *const pz.Diagnostic) noreturn {
    // The window shows this in one line: the zip's name and why, not its path.
    report("error {s} wasn't imported: {s}", .{ std.fs.path.basename(path), pz.describe(err) });
    report_path = null;
    if (diag.name().len > 0) {
        if (diag.cause) |c| fail(1, "not imported: {s}: {s} ('{s}', {s})", .{ path, pz.describe(err), diag.name(), words.of(c) });
        fail(1, "not imported: {s}: {s} ('{s}')", .{ path, pz.describe(err), diag.name() });
    }
    if (diag.cause) |c| fail(1, "not imported: {s}: {s} ({s})", .{ path, pz.describe(err), words.of(c) });
    fail(1, "not imported: {s}: {s}", .{ path, pz.describe(err) });
}

/// Exit codes as the rest of the console: 1 refused, 2 bad usage, 3 zmural isn't running.
fn fail(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    report("error " ++ fmt, args);
    std.log.err("zmural-console: " ++ fmt, args);
    std.process.exit(code);
}
