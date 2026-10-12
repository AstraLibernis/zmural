// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What Wayfire says about its windows, over its IPC socket
//! (`$WAYFIRE_SOCKET`, set when Wayfire's `ipc` plugin runs; the methods
//! below come from its `ipc-rules` plugin, so both must be on). Messages are
//! a little-endian u32 length, then JSON. One connection watches window
//! events; each event is answered by listing the windows over a second,
//! short one. For each output:
//! - fullscreen and maximized (all four edges tiled): a window on the
//!   workspace that is showing. Wayfire places windows in the output's own
//!   coordinates, relative to the workspace showing, so one on another
//!   workspace lies outside the output (as waywallen-display's watcher,
//!   MIT, tells them apart);
//! - covered: the showing windows cover almost all of the output;
//! - focused: the focused window is on it;
//! and the process in front, for the app rule.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const policy = zmural.policy;
const coverage = zmural.coverage;
const Rect = zmural.layout.Rect;
const Facts = @import("compositor_sway.zig").Facts;
const max_outputs = @import("compositor_sway.zig").max_outputs;

const log = std.log.scoped(.wayfire);

const max_reply = 8 << 20;

const Box = struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };

const View = struct {
    id: u32 = 0,
    pid: i32 = 0,
    type: []const u8 = "",
    mapped: bool = false,
    minimized: bool = false,
    fullscreen: bool = false,
    activated: bool = false,
    @"output-id": i64 = -1,
    @"output-name": []const u8 = "",
    /// A bit per edge; all four: maximized.
    @"tiled-edges": u32 = 0,
    /// In the output's coordinates, relative to the workspace showing.
    bbox: Box = .{},
};

const OutputInfo = struct { geometry: Box = .{} };

const all_edges: u32 = 15;

/// An output's size, from `window-rules/output-info`.
pub const OutputSize = struct { id: i64, w: f64, h: f64 };

/// A coordinate as a whole number, within what any screen has.
fn px(v: f64) i32 {
    return @intFromFloat(std.math.clamp(v, -1e6, 1e6));
}

fn extent(v: f64) u32 {
    return @intFromFloat(std.math.clamp(v, 0, 1e6));
}

/// Reads the facts from `window-rules/list-views` and, per output id, the
/// size `window-rules/output-info` gave.
pub fn factsFrom(gpa: std.mem.Allocator, views_json: []const u8, sizes: []const OutputSize) !Facts {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const views = try std.json.parseFromSliceLeaky([]const View, arena.allocator(), views_json, .{ .ignore_unknown_fields = true });

    var f: Facts = .{};
    var shown: [max_outputs][64]Rect = undefined;
    var n_shown: [max_outputs]usize = @splat(0);
    var areas: [max_outputs]Rect = undefined;
    for (views) |*v| {
        if (!std.mem.eql(u8, v.type, "toplevel") or v.@"output-name".len == 0) continue;
        const size = for (sizes) |s| {
            if (s.id == v.@"output-id") break s;
        } else continue;
        // Every output with a window gets facts, so a hidden fullscreen one
        // there counts as nothing rather than as the display host says.
        const name = v.@"output-name";
        const i = for (0..f.len) |j| {
            if (std.mem.eql(u8, f.names[j][0..f.name_lens[j]], name)) break j;
        } else blk: {
            if (f.len == max_outputs or name.len > f.names[0].len) continue;
            const j = f.len;
            f.len += 1;
            @memcpy(f.names[j][0..name.len], name);
            f.name_lens[j] = name.len;
            areas[j] = .{ .x = 0, .y = 0, .w = extent(size.w), .h = extent(size.h) };
            break :blk j;
        };
        if (!v.mapped or v.minimized) continue;
        const b = v.bbox;
        const showing = b.x + b.width > 0 and b.x < size.w and b.y + b.height > 0 and b.y < size.h;
        if (!showing) continue;
        if (v.fullscreen) f.conditions[i].insert(.fullscreen);
        if (v.@"tiled-edges" & all_edges == all_edges) f.conditions[i].insert(.maximized);
        if (v.activated) {
            f.conditions[i].insert(.focused);
            f.front_pid = v.pid;
        }
        if (n_shown[i] < shown[i].len and b.width > 0 and b.height > 0) {
            shown[i][n_shown[i]] = .{ .x = px(b.x), .y = px(b.y), .w = extent(b.width), .h = extent(b.height) };
            n_shown[i] += 1;
        }
    }
    for (0..f.len) |i| if (n_shown[i] > 0 and coverage.isCovered(areas[i], shown[i][0..n_shown[i]])) f.conditions[i].insert(.covered);
    return f;
}

// ---- the socket -------------------------------------------------------------------------

fn connect(path: []const u8) !linux.fd_t {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.ConnectFailed;
    // Wayfire answers in milliseconds; this only guards against a hung one.
    const tv: linux.timeval = .{ .sec = 1, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    return fd;
}

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const rc = linux.write(fd, bytes[done..].ptr, bytes.len - done);
        switch (linux.errno(rc)) {
            .SUCCESS => done += rc,
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
}

fn readAll(fd: linux.fd_t, buf: []u8) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const rc = linux.read(fd, buf[done..].ptr, buf.len - done);
        switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) return error.Closed else {
                done += rc;
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
}

fn send(fd: linux.fd_t, json: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(json.len), .little);
    try writeAll(fd, &len);
    try writeAll(fd, json);
}

/// One message; caller frees.
fn recv(gpa: std.mem.Allocator, fd: linux.fd_t) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try readAll(fd, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len > max_reply) return error.TooLong;
    const body = try gpa.alloc(u8, len);
    errdefer gpa.free(body);
    try readAll(fd, body);
    return body;
}

/// A reply that says the method isn't there: the `ipc-rules` plugin is off.
fn refused(reply: []const u8) bool {
    return std.mem.find(u8, reply, "\"error\"") != null;
}

pub const Watch = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    /// Watching window events: readable whenever something changed.
    events: linux.fd_t,

    pub fn start(gpa: std.mem.Allocator, socket: []const u8) !Watch {
        const fd = try connect(socket);
        errdefer _ = linux.close(fd);
        try send(fd,
            \\{"method":"window-rules/events/watch","data":{"events":["view-focused","view-fullscreen","view-minimized","view-mapped","view-unmapped","view-tiled","view-geometry-changed","view-set-output","view-workspace-changed","wset-workspace-changed","output-added","output-removed"]}}
        );
        const reply = try recv(gpa, fd);
        defer gpa.free(reply);
        if (refused(reply)) return error.NoIpcRules;
        return .{ .gpa = gpa, .path = socket, .events = fd };
    }

    pub fn stop(w: *Watch) void {
        _ = linux.close(w.events);
    }

    /// Reads the events that are waiting (the caller then lists the windows).
    /// False when Wayfire closed the connection.
    pub fn drain(w: *Watch) bool {
        while (true) {
            var pfd = [1]linux.pollfd{.{ .fd = w.events, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&pfd, 1, 0);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return true;
            if (pfd[0].revents & linux.POLL.IN == 0) return false; // hung up
            const ev = recv(w.gpa, w.events) catch return false;
            w.gpa.free(ev);
        }
    }

    /// The windows, read now, with the size of each output they are on.
    pub fn query(w: *Watch) !Facts {
        const fd = try connect(w.path);
        defer _ = linux.close(fd);
        try send(fd, "{\"method\":\"window-rules/list-views\",\"data\":{}}");
        const views = try recv(w.gpa, fd);
        defer w.gpa.free(views);
        if (refused(views)) return error.NoIpcRules;

        var arena: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = try std.json.parseFromSliceLeaky([]const View, a, views, .{ .ignore_unknown_fields = true });
        var sizes: [max_outputs]OutputSize = undefined;
        var n: usize = 0;
        for (parsed) |v| {
            if (v.@"output-id" < 0 or n == sizes.len) continue;
            const known = for (sizes[0..n]) |s| {
                if (s.id == v.@"output-id") break true;
            } else false;
            if (known) continue;
            var req_buf: [96]u8 = undefined;
            try send(fd, try std.fmt.bufPrint(&req_buf, "{{\"method\":\"window-rules/output-info\",\"data\":{{\"id\":{d}}}}}", .{v.@"output-id"}));
            const info_json = try recv(w.gpa, fd);
            defer w.gpa.free(info_json);
            const info = std.json.parseFromSliceLeaky(OutputInfo, a, info_json, .{ .ignore_unknown_fields = true }) catch continue;
            sizes[n] = .{ .id = v.@"output-id", .w = info.geometry.width, .h = info.geometry.height };
            n += 1;
        }
        return factsFrom(w.gpa, views, sizes[0..n]);
    }
};

// ---- tests ------------------------------------------------------------------------------

/// Shaped like Wayfire 0.10's `list-views`: on WL-1 (1280x720) a focused
/// window fills the workspace showing, a fullscreen game sits one workspace
/// to the right (outside the output), and a panel isn't a toplevel; on WL-2,
/// a maximized window that is minimized.
const views_two =
    \\[{"id":1,"pid":11,"type":"toplevel","mapped":true,"minimized":false,"fullscreen":false,"activated":true,"output-id":1,"output-name":"WL-1","tiled-edges":15,"bbox":{"x":0,"y":0,"width":1280,"height":720}},
    \\ {"id":2,"pid":12,"type":"toplevel","mapped":true,"minimized":false,"fullscreen":true,"activated":false,"output-id":1,"output-name":"WL-1","tiled-edges":0,"bbox":{"x":1280,"y":0,"width":1280,"height":720}},
    \\ {"id":3,"pid":13,"type":"panel","mapped":true,"minimized":false,"fullscreen":false,"activated":false,"output-id":1,"output-name":"WL-1","tiled-edges":0,"bbox":{"x":0,"y":0,"width":1280,"height":30}},
    \\ {"id":4,"pid":14,"type":"toplevel","mapped":true,"minimized":true,"fullscreen":false,"activated":false,"output-id":2,"output-name":"WL-2","tiled-edges":15,"bbox":{"x":0,"y":0,"width":800,"height":600}}]
;
const sizes_two = [_]OutputSize{ .{ .id = 1, .w = 1280, .h = 720 }, .{ .id = 2, .w = 800, .h = 600 } };

test "fullscreen counts only on the workspace showing; a minimized window not at all" {
    const f = try factsFrom(std.testing.allocator, views_two, &sizes_two);
    const one = f.forOutput("WL-1").?;
    try std.testing.expect(!one.contains(.fullscreen)); // one workspace over
    try std.testing.expect(one.contains(.maximized) and one.contains(.focused) and one.contains(.covered));
    try std.testing.expectEqual(@as(linux.pid_t, 11), f.front_pid);
    // WL-2 has a window, so it has facts: none, as its only window is minimized.
    const two = f.forOutput("WL-2").?;
    try std.testing.expectEqual(@as(usize, 0), two.count());
}

test "a window showing in part counts; a small one doesn't cover" {
    const views =
        \\[{"id":5,"pid":15,"type":"toplevel","mapped":true,"fullscreen":true,"output-id":1,"output-name":"WL-1","bbox":{"x":1200,"y":0,"width":1280,"height":720}},
        \\ {"id":6,"pid":16,"type":"toplevel","mapped":true,"output-id":1,"output-name":"WL-1","bbox":{"x":10,"y":10,"width":100,"height":100}}]
    ;
    const f = try factsFrom(std.testing.allocator, views, &sizes_two);
    const one = f.forOutput("WL-1").?;
    try std.testing.expect(one.contains(.fullscreen));
    try std.testing.expect(!one.contains(.covered) and !one.contains(.focused));
    try std.testing.expectEqual(@as(linux.pid_t, 0), f.front_pid);
}
