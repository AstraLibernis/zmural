// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What Sway says about its windows, over its IPC socket (`$SWAYSOCK`, the
//! i3 IPC protocol). The display host's window list (wlr-foreign-toplevel)
//! can't see workspaces or where windows are, so on Sway zmural asks the
//! compositor itself, and gets for each output:
//! - fullscreen: a window on a workspace that is showing is fullscreen (one
//!   on a hidden workspace no longer pauses the wallpaper);
//! - covered: the showing windows cover almost all of the output;
//! - focused: the focused window is on it;
//! and the process in front, for the app rule.
//!
//! One connection is subscribed to window, workspace and output events; each
//! event is answered by reading the whole tree over a second, short one.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const policy = zmural.policy;
const coverage = zmural.coverage;
const Rect = zmural.layout.Rect;

const log = std.log.scoped(.sway);

pub const max_outputs = 16;

/// Per output, by its connector name (as display hosts register it).
pub const Facts = struct {
    names: [max_outputs][64]u8 = undefined,
    name_lens: [max_outputs]usize = @splat(0),
    conditions: [max_outputs]policy.Conditions = @splat(.empty),
    len: usize = 0,
    /// The focused window's process, 0 when nothing has focus.
    front_pid: linux.pid_t = 0,

    pub fn forOutput(f: *const Facts, name: []const u8) ?policy.Conditions {
        for (0..f.len) |i| if (std.mem.eql(u8, f.names[i][0..f.name_lens[i]], name)) return f.conditions[i];
        return null;
    }

    pub fn eql(a: *const Facts, b: *const Facts) bool {
        if (a.len != b.len or a.front_pid != b.front_pid) return false;
        for (0..a.len) |i| {
            if (!std.mem.eql(u8, a.names[i][0..a.name_lens[i]], b.names[i][0..b.name_lens[i]])) return false;
            if (!std.meta.eql(a.conditions[i], b.conditions[i])) return false;
        }
        return true;
    }
};

const JsonRect = struct { x: i32 = 0, y: i32 = 0, width: u32 = 0, height: u32 = 0 };

/// The parts of a tree node zmural reads.
const Node = struct {
    type: []const u8 = "",
    name: ?[]const u8 = null,
    focused: bool = false,
    /// Views only: false when hidden (another workspace, a tab behind).
    visible: ?bool = null,
    /// 0 none, 1 on its output, 2 across every output.
    fullscreen_mode: u8 = 0,
    pid: ?i32 = null,
    /// The window's content, without its title bar.
    rect: JsonRect = .{},
    /// Its title bar (zero high without one), directly above `rect`.
    deco_rect: JsonRect = .{},
    nodes: []const Node = &.{},
    floating_nodes: []const Node = &.{},

    fn isView(n: *const Node) bool {
        return n.pid != null and (std.mem.eql(u8, n.type, "con") or std.mem.eql(u8, n.type, "floating_con"));
    }
};

/// Reads the facts from a GET_TREE reply.
pub fn factsFromTree(gpa: std.mem.Allocator, json: []const u8) !Facts {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = try std.json.parseFromSliceLeaky(Node, arena.allocator(), json, .{ .ignore_unknown_fields = true });

    var f: Facts = .{};
    var everywhere = false; // a window fullscreen across every output
    for (root.nodes) |*output| {
        if (!std.mem.eql(u8, output.type, "output")) continue;
        const name = output.name orelse continue;
        if (std.mem.startsWith(u8, name, "__")) continue; // the scratchpad's
        if (f.len == max_outputs or name.len > f.names[0].len) continue;
        const i = f.len;
        f.len += 1;
        @memcpy(f.names[i][0..name.len], name);
        f.name_lens[i] = name.len;

        var shown: [64]Rect = undefined;
        var n_shown: usize = 0;
        var c: policy.Conditions = .empty;
        var stack: [64]*const Node = undefined;
        var depth: usize = 0;
        for (output.nodes) |*ws| {
            if (depth < stack.len) {
                stack[depth] = ws;
                depth += 1;
            }
        }
        while (depth > 0) {
            depth -= 1;
            const n = stack[depth];
            if (n.isView()) {
                if (n.visible orelse false) {
                    if (n.fullscreen_mode == 1) c.insert(.fullscreen);
                    if (n.fullscreen_mode == 2) everywhere = true;
                    if (n_shown < shown.len and n.rect.width > 0 and n.rect.height > 0) {
                        // The title bar covers the wallpaper as much as the window does.
                        const bar: i32 = @intCast(@min(n.deco_rect.height, 4096));
                        shown[n_shown] = .{ .x = n.rect.x, .y = n.rect.y - bar, .w = n.rect.width, .h = n.rect.height + @as(u32, @intCast(bar)) };
                        n_shown += 1;
                    }
                }
                if (n.focused) {
                    c.insert(.focused);
                    f.front_pid = n.pid.?;
                }
            }
            for (n.nodes) |*child| if (depth < stack.len) {
                stack[depth] = child;
                depth += 1;
            };
            for (n.floating_nodes) |*child| if (depth < stack.len) {
                stack[depth] = child;
                depth += 1;
            };
        }
        const area: Rect = .{ .x = output.rect.x, .y = output.rect.y, .w = output.rect.width, .h = output.rect.height };
        if (n_shown > 0 and coverage.isCovered(area, shown[0..n_shown])) c.insert(.covered);
        f.conditions[i] = c;
    }
    if (everywhere) for (0..f.len) |i| f.conditions[i].insert(.fullscreen);
    return f;
}

// ---- the IPC socket -----------------------------------------------------------------

const magic = "i3-ipc";
const header_len = magic.len + 8;
const msg_subscribe: u32 = 2;
const msg_get_tree: u32 = 4;
/// Replies to a subscription have this bit set in their type.
const event_bit: u32 = 0x8000_0000;
const max_reply = 8 << 20;

fn connect(path: []const u8) !linux.fd_t {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.ConnectFailed;
    // Sway answers in milliseconds; this only guards against a hung one.
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

fn send(fd: linux.fd_t, kind: u32, payload: []const u8) !void {
    var head: [header_len]u8 = undefined;
    @memcpy(head[0..magic.len], magic);
    std.mem.writeInt(u32, head[magic.len..][0..4], @intCast(payload.len), .native);
    std.mem.writeInt(u32, head[magic.len + 4 ..][0..4], kind, .native);
    try writeAll(fd, &head);
    try writeAll(fd, payload);
}

/// One message: its type, and its payload (owned by the caller).
fn recv(gpa: std.mem.Allocator, fd: linux.fd_t) !struct { kind: u32, payload: []u8 } {
    var head: [header_len]u8 = undefined;
    try readAll(fd, &head);
    if (!std.mem.eql(u8, head[0..magic.len], magic)) return error.NotSway;
    const len = std.mem.readInt(u32, head[magic.len..][0..4], .native);
    if (len > max_reply) return error.TooLong;
    const payload = try gpa.alloc(u8, len);
    errdefer gpa.free(payload);
    try readAll(fd, payload);
    return .{ .kind = std.mem.readInt(u32, head[magic.len + 4 ..][0..4], .native), .payload = payload };
}

pub const Watch = struct {
    gpa: std.mem.Allocator,
    path: []const u8,
    /// Subscribed: readable whenever something changed.
    events: linux.fd_t,

    pub fn start(gpa: std.mem.Allocator, swaysock: []const u8) !Watch {
        const fd = try connect(swaysock);
        errdefer _ = linux.close(fd);
        try send(fd, msg_subscribe, "[\"window\",\"workspace\",\"output\"]");
        const reply = try recv(gpa, fd);
        defer gpa.free(reply.payload);
        if (std.mem.find(u8, reply.payload, "\"success\": true") == null and std.mem.find(u8, reply.payload, "\"success\":true") == null)
            return error.SubscribeRefused;
        return .{ .gpa = gpa, .path = swaysock, .events = fd };
    }

    pub fn stop(w: *Watch) void {
        _ = linux.close(w.events);
    }

    /// Reads the events that are waiting (the caller then asks for the tree).
    /// False when Sway closed the connection.
    pub fn drain(w: *Watch) bool {
        while (true) {
            var pfd = [1]linux.pollfd{.{ .fd = w.events, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&pfd, 1, 0);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return true;
            if (pfd[0].revents & linux.POLL.IN == 0) return false; // hung up
            const ev = recv(w.gpa, w.events) catch return false;
            w.gpa.free(ev.payload);
        }
    }

    /// The whole tree, read now.
    pub fn query(w: *Watch) !Facts {
        const fd = try connect(w.path);
        defer _ = linux.close(fd);
        try send(fd, msg_get_tree, "");
        const reply = try recv(w.gpa, fd);
        defer w.gpa.free(reply.payload);
        if (reply.kind != msg_get_tree) return error.UnexpectedReply;
        return factsFromTree(w.gpa, reply.payload);
    }
};

// ---- tests ------------------------------------------------------------------------------

/// Trimmed from `swaymsg -t get_tree` on Sway 1.11: two outputs; on the
/// first, workspace 1 shows a tiled window with focus and workspace 3 (not
/// showing) has a fullscreen one; on the second, a fullscreen window.
const two_outputs =
    \\{"type":"root","name":"root","rect":{"x":0,"y":0,"width":2560,"height":720},"nodes":[
    \\ {"type":"output","name":"__i3","rect":{"x":0,"y":0,"width":2560,"height":720},"nodes":[
    \\   {"type":"workspace","name":"__i3_scratch","fullscreen_mode":1,"rect":{"x":0,"y":0,"width":2560,"height":720}}]},
    \\ {"type":"output","name":"HEADLESS-1","current_workspace":"1","rect":{"x":0,"y":0,"width":1280,"height":720},"nodes":[
    \\   {"type":"workspace","name":"1","fullscreen_mode":1,"rect":{"x":0,"y":0,"width":1280,"height":720},"nodes":[
    \\     {"type":"con","name":"foot","focused":true,"visible":true,"fullscreen_mode":0,"pid":350553,"app_id":"testwin","rect":{"x":0,"y":27,"width":1280,"height":693},"deco_rect":{"x":0,"y":0,"width":1280,"height":27}}]},
    \\   {"type":"workspace","name":"3","fullscreen_mode":1,"rect":{"x":0,"y":0,"width":1280,"height":720},"nodes":[
    \\     {"type":"con","name":"game","focused":false,"visible":false,"fullscreen_mode":1,"pid":350700,"rect":{"x":0,"y":0,"width":1280,"height":720}}]}]},
    \\ {"type":"output","name":"HEADLESS-2","current_workspace":"2","rect":{"x":1280,"y":0,"width":1280,"height":720},"nodes":[
    \\   {"type":"workspace","name":"2","fullscreen_mode":1,"rect":{"x":1280,"y":0,"width":1280,"height":720},"nodes":[
    \\     {"type":"con","name":"foot","focused":false,"visible":true,"fullscreen_mode":1,"pid":350596,"app_id":"other","rect":{"x":1280,"y":0,"width":1280,"height":720}}],
    \\    "floating_nodes":[]}]}]}
;

test "a fullscreen window counts only where its workspace is showing" {
    const f = try factsFromTree(std.testing.allocator, two_outputs);
    try std.testing.expectEqual(@as(usize, 2), f.len);
    const one = f.forOutput("HEADLESS-1").?;
    const two = f.forOutput("HEADLESS-2").?;
    try std.testing.expect(!one.contains(.fullscreen)); // workspace 3's game is hidden
    try std.testing.expect(two.contains(.fullscreen));
    try std.testing.expect(one.contains(.focused) and !two.contains(.focused));
    try std.testing.expectEqual(@as(linux.pid_t, 350553), f.front_pid);
    try std.testing.expect(f.forOutput("__i3") == null);
}

test "covered: showing windows over almost all of the output" {
    // The tiled window and its title bar fill the output.
    const f = try factsFromTree(std.testing.allocator, two_outputs);
    try std.testing.expect(f.forOutput("HEADLESS-1").?.contains(.covered));
    const small =
        \\{"type":"root","nodes":[{"type":"output","name":"DP-1","rect":{"x":0,"y":0,"width":1000,"height":1000},"nodes":[
        \\ {"type":"workspace","name":"1","nodes":[],"floating_nodes":[
        \\   {"type":"floating_con","visible":true,"pid":7,"rect":{"x":100,"y":100,"width":300,"height":300}}]}]}]}
    ;
    const g = try factsFromTree(std.testing.allocator, small);
    try std.testing.expect(!g.forOutput("DP-1").?.contains(.covered));
    try std.testing.expectEqual(@as(linux.pid_t, 0), g.front_pid); // nothing has focus
}

test "a window fullscreen across every output pauses them all" {
    const all =
        \\{"type":"root","nodes":[
        \\ {"type":"output","name":"A","rect":{"x":0,"y":0,"width":100,"height":100},"nodes":[{"type":"workspace","nodes":[
        \\   {"type":"con","visible":true,"fullscreen_mode":2,"pid":9,"rect":{"x":0,"y":0,"width":200,"height":100}}]}]},
        \\ {"type":"output","name":"B","rect":{"x":100,"y":0,"width":100,"height":100},"nodes":[{"type":"workspace","nodes":[]}]}]}
    ;
    const f = try factsFromTree(std.testing.allocator, all);
    try std.testing.expect(f.forOutput("A").?.contains(.fullscreen) and f.forOutput("B").?.contains(.fullscreen));
}
