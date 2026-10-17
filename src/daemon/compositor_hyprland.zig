// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! What Hyprland says about its windows, over its two IPC sockets in
//! `$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/`: `.socket2.sock`
//! sends a line per event, and `.socket.sock` answers one request per
//! connection (`j/clients`, `j/monitors`, `j/activewindow`, as JSON). The
//! display host's window list can't see workspaces or where windows are, so
//! on Hyprland zmural asks the compositor itself, and gets for each monitor:
//! - fullscreen and maximized: a window on a workspace that is showing (the
//!   monitor's active one, or its special workspace when that is open);
//! - covered: the showing windows cover almost all of the monitor;
//! - focused: the focused window is on it;
//! and the process in front, for the app rule. After waywallen-display's
//! watcher (MIT), which runs `hyprctl`; zmural reads the socket itself.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const policy = zmural.policy;
const coverage = zmural.coverage;
const Rect = zmural.layout.Rect;
const Facts = @import("compositor_sway.zig").Facts;
const max_outputs = @import("compositor_sway.zig").max_outputs;

const log = std.log.scoped(.hyprland);

const max_reply = 8 << 20;

const Workspace = struct { id: i64 = 0 };

const Client = struct {
    address: []const u8 = "",
    mapped: bool = true,
    /// A window behind others in a group (a tab not showing).
    hidden: bool = false,
    at: [2]i32 = .{ 0, 0 },
    size: [2]i32 = .{ 0, 0 },
    workspace: Workspace = .{},
    monitor: i64 = -1,
    pid: i32 = 0,
    /// 0.42 and later: 0 none, 1 maximized, 2 fullscreen, 3 both. Before:
    /// a bool, with `fullscreenMode` 0 fullscreen, 1 maximized.
    fullscreen: std.json.Value = .{ .integer = 0 },
    fullscreenMode: ?i64 = null,

    fn mode(c: *const Client) struct { fullscreen: bool, maximized: bool } {
        return switch (c.fullscreen) {
            .integer => |n| .{ .fullscreen = n & 2 != 0, .maximized = n & 1 != 0 },
            .bool => |on| if (!on) .{ .fullscreen = false, .maximized = false } else if ((c.fullscreenMode orelse 0) == 1)
                .{ .fullscreen = false, .maximized = true }
            else
                .{ .fullscreen = true, .maximized = false },
            else => .{ .fullscreen = false, .maximized = false },
        };
    }
};

const Monitor = struct {
    id: i64 = -1,
    name: []const u8 = "",
    x: i32 = 0,
    y: i32 = 0,
    /// In pixels; windows are placed in layout coordinates (pixels / scale).
    width: u32 = 0,
    height: u32 = 0,
    scale: f64 = 1,
    activeWorkspace: Workspace = .{},
    /// Its special workspace (a scratchpad) when open over it, else id 0.
    specialWorkspace: Workspace = .{},
};

const Active = struct {
    address: []const u8 = "",
    monitor: i64 = -1,
    pid: i32 = 0,
};

/// Reads the facts from the replies to `j/clients`, `j/monitors` and
/// `j/activewindow` (`{}` when nothing has focus).
pub fn factsFrom(gpa: std.mem.Allocator, clients_json: []const u8, monitors_json: []const u8, active_json: []const u8) !Facts {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const clients = try std.json.parseFromSliceLeaky([]const Client, a, clients_json, opts);
    const mons = try std.json.parseFromSliceLeaky([]const Monitor, a, monitors_json, opts);
    const active = std.json.parseFromSliceLeaky(Active, a, active_json, opts) catch Active{};
    const has_focus = active.address.len > 0;

    var f: Facts = .{};
    for (mons) |m| {
        if (f.len == max_outputs or m.name.len == 0 or m.name.len > f.names[0].len) continue;
        const i = f.len;
        f.len += 1;
        @memcpy(f.names[i][0..m.name.len], m.name);
        f.name_lens[i] = m.name.len;

        var c: policy.Conditions = .empty;
        var shown: [64]Rect = undefined;
        var n_shown: usize = 0;
        for (clients) |*cl| {
            if (!cl.mapped or cl.hidden or cl.monitor != m.id) continue;
            const ws = cl.workspace.id;
            if (ws != m.activeWorkspace.id and (m.specialWorkspace.id == 0 or ws != m.specialWorkspace.id)) continue;
            const md = cl.mode();
            if (md.fullscreen) c.insert(.fullscreen);
            if (md.maximized) c.insert(.maximized);
            if (n_shown < shown.len and cl.size[0] > 0 and cl.size[1] > 0) {
                shown[n_shown] = .{ .x = cl.at[0], .y = cl.at[1], .w = @intCast(cl.size[0]), .h = @intCast(cl.size[1]) };
                n_shown += 1;
            }
        }
        if (has_focus and active.monitor == m.id) {
            c.insert(.focused);
            f.front_pid = active.pid;
        }
        const scale = if (m.scale > 0) m.scale else 1;
        const area: Rect = .{
            .x = m.x,
            .y = m.y,
            .w = @intFromFloat(@round(@as(f64, @floatFromInt(m.width)) / scale)),
            .h = @intFromFloat(@round(@as(f64, @floatFromInt(m.height)) / scale)),
        };
        if (n_shown > 0 and coverage.isCovered(area, shown[0..n_shown])) c.insert(.covered);
        f.conditions[i] = c;
    }
    return f;
}

// ---- the sockets ------------------------------------------------------------------------

fn connect(path: []const u8) !linux.fd_t {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(rc);
    errdefer _ = linux.close(fd);
    var addr: linux.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.PathTooLong;
    @memcpy(addr.path[0..path.len], path);
    if (linux.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.ConnectFailed;
    // Hyprland answers in milliseconds; this only guards against a hung one.
    const tv: linux.timeval = .{ .sec = 1, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
    return fd;
}

/// One request on its own connection; the reply runs to the end of it.
/// Caller frees.
fn request(gpa: std.mem.Allocator, path: []const u8, what: []const u8) ![]u8 {
    const fd = try connect(path);
    defer _ = linux.close(fd);
    var done: usize = 0;
    while (done < what.len) {
        const rc = linux.write(fd, what[done..].ptr, what.len - done);
        switch (linux.errno(rc)) {
            .SUCCESS => done += rc,
            .INTR => {},
            else => return error.WriteFailed,
        }
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                if (out.items.len + rc > max_reply) return error.TooLong;
                try out.appendSlice(gpa, buf[0..rc]);
            },
            .INTR => {},
            else => return error.ReadFailed,
        }
    }
    return out.toOwnedSlice(gpa);
}

pub const Watch = struct {
    gpa: std.mem.Allocator,
    /// `.socket.sock`, for requests (owned).
    requests: []u8,
    /// `.socket2.sock`: a line per event, readable whenever something changed.
    events: linux.fd_t,

    /// `signature` is `$HYPRLAND_INSTANCE_SIGNATURE`.
    pub fn start(gpa: std.mem.Allocator, runtime_dir: []const u8, signature: []const u8) !Watch {
        if (std.mem.findScalar(u8, signature, '/') != null) return error.BadSignature;
        const dir = try std.fs.path.join(gpa, &.{ runtime_dir, "hypr", signature });
        defer gpa.free(dir);
        const ev_path = try std.fs.path.join(gpa, &.{ dir, ".socket2.sock" });
        defer gpa.free(ev_path);
        const req_path = try std.fs.path.join(gpa, &.{ dir, ".socket.sock" });
        errdefer gpa.free(req_path);
        const fd = try connect(ev_path);
        // The event socket is read only when poll says so: no timeout there.
        const none: linux.timeval = .{ .sec = 0, .usec = 0 };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&none), @sizeOf(linux.timeval));
        return .{ .gpa = gpa, .requests = req_path, .events = fd };
    }

    pub fn stop(w: *Watch) void {
        _ = linux.close(w.events);
        w.gpa.free(w.requests);
    }

    /// Reads the events that are waiting (the caller then asks for the
    /// windows). False when Hyprland closed the connection.
    pub fn drain(w: *Watch) bool {
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            var pfd = [1]linux.pollfd{.{ .fd = w.events, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&pfd, 1, 0);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return true;
            if (pfd[0].revents & linux.POLL.IN == 0) return false; // hung up
            const n = linux.read(w.events, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) return false;
        }
    }

    /// The windows, monitors and focus, read now.
    pub fn query(w: *Watch) !Facts {
        const clients = try request(w.gpa, w.requests, "j/clients");
        defer w.gpa.free(clients);
        const mons = try request(w.gpa, w.requests, "j/monitors");
        defer w.gpa.free(mons);
        const active = try request(w.gpa, w.requests, "j/activewindow");
        defer w.gpa.free(active);
        return factsFrom(w.gpa, clients, mons, active);
    }
};

// ---- tests ------------------------------------------------------------------------------

/// Shaped like Hyprland 0.56's replies: two monitors. On DP-1 (workspace 1
/// showing) a tiled window with focus fills it, and workspace 3 (hidden)
/// has a fullscreen game; on HDMI-A-1 (scale 2, workspace 2) a maximized
/// window, and a small floating one on its open special workspace.
const clients_two =
    \\[{"address":"0xa1","mapped":true,"hidden":false,"at":[0,0],"size":[1920,1080],"workspace":{"id":1,"name":"1"},"floating":false,"monitor":0,"class":"foot","pid":101,"fullscreen":0,"fullscreenClient":0},
    \\ {"address":"0xa2","mapped":true,"hidden":false,"at":[0,0],"size":[1920,1080],"workspace":{"id":3,"name":"3"},"floating":false,"monitor":0,"class":"game","pid":102,"fullscreen":2,"fullscreenClient":2},
    \\ {"address":"0xa3","mapped":true,"hidden":false,"at":[1920,0],"size":[1280,720],"workspace":{"id":2,"name":"2"},"floating":false,"monitor":1,"class":"editor","pid":103,"fullscreen":1,"fullscreenClient":0},
    \\ {"address":"0xa4","mapped":true,"hidden":false,"at":[2000,100],"size":[300,200],"workspace":{"id":-98,"name":"special:term"},"floating":true,"monitor":1,"class":"term","pid":104,"fullscreen":0,"fullscreenClient":0},
    \\ {"address":"0xa5","mapped":true,"hidden":true,"at":[0,0],"size":[1920,1080],"workspace":{"id":1,"name":"1"},"floating":false,"monitor":0,"class":"tab","pid":105,"fullscreen":2,"fullscreenClient":0}]
;
const monitors_two =
    \\[{"id":0,"name":"DP-1","x":0,"y":0,"width":1920,"height":1080,"scale":1.00,"activeWorkspace":{"id":1,"name":"1"},"specialWorkspace":{"id":0,"name":""},"focused":true},
    \\ {"id":1,"name":"HDMI-A-1","x":1920,"y":0,"width":2560,"height":1440,"scale":2.00,"activeWorkspace":{"id":2,"name":"2"},"specialWorkspace":{"id":-98,"name":"special:term"},"focused":false}]
;

test "fullscreen and maximized count only where their workspace is showing" {
    const f = try factsFrom(std.testing.allocator, clients_two, monitors_two, "{\"address\":\"0xa1\",\"monitor\":0,\"pid\":101}");
    try std.testing.expectEqual(@as(usize, 2), f.len);
    const dp = f.forOutput("DP-1").?;
    const hdmi = f.forOutput("HDMI-A-1").?;
    // The game on workspace 3 is hidden, and so is the grouped tab behind.
    try std.testing.expect(!dp.contains(.fullscreen));
    try std.testing.expect(hdmi.contains(.maximized) and !hdmi.contains(.fullscreen));
    try std.testing.expect(dp.contains(.focused) and !hdmi.contains(.focused));
    try std.testing.expectEqual(@as(linux.pid_t, 101), f.front_pid);
}

test "covered: in layout coordinates, the monitor's scale taken out" {
    const f = try factsFrom(std.testing.allocator, clients_two, monitors_two, "{}");
    try std.testing.expect(f.forOutput("DP-1").?.contains(.covered));
    // 2560x1440 at scale 2 is 1280x720 of layout: the maximized window covers it.
    try std.testing.expect(f.forOutput("HDMI-A-1").?.contains(.covered));
    // Nothing focused.
    try std.testing.expectEqual(@as(linux.pid_t, 0), f.front_pid);
    try std.testing.expect(!f.forOutput("DP-1").?.contains(.focused));
}

test "the special workspace counts while it is open" {
    const small =
        \\[{"address":"0xb1","at":[100,100],"size":[200,200],"workspace":{"id":-99},"monitor":0,"pid":7,"fullscreen":2}]
    ;
    const open =
        \\[{"id":0,"name":"DP-1","x":0,"y":0,"width":1000,"height":1000,"activeWorkspace":{"id":1},"specialWorkspace":{"id":-99}}]
    ;
    const closed =
        \\[{"id":0,"name":"DP-1","x":0,"y":0,"width":1000,"height":1000,"activeWorkspace":{"id":1},"specialWorkspace":{"id":0}}]
    ;
    const f = try factsFrom(std.testing.allocator, small, open, "{}");
    try std.testing.expect(f.forOutput("DP-1").?.contains(.fullscreen));
    try std.testing.expect(!f.forOutput("DP-1").?.contains(.covered));
    const g = try factsFrom(std.testing.allocator, small, closed, "{}");
    try std.testing.expect(!g.forOutput("DP-1").?.contains(.fullscreen));
}

test "older Hyprland: fullscreen as a bool, fullscreenMode 1 meaning maximized" {
    const old =
        \\[{"address":"0xc1","at":[0,0],"size":[100,100],"workspace":{"id":1},"monitor":0,"pid":8,"fullscreen":true,"fullscreenMode":1},
        \\ {"address":"0xc2","at":[0,0],"size":[100,100],"workspace":{"id":1},"monitor":1,"pid":9,"fullscreen":true,"fullscreenMode":0}]
    ;
    const mons =
        \\[{"id":0,"name":"A","width":100,"height":100,"activeWorkspace":{"id":1}},{"id":1,"name":"B","x":100,"width":100,"height":100,"activeWorkspace":{"id":1}}]
    ;
    const f = try factsFrom(std.testing.allocator, old, mons, "{}");
    try std.testing.expect(f.forOutput("A").?.contains(.maximized) and !f.forOutput("A").?.contains(.fullscreen));
    try std.testing.expect(f.forOutput("B").?.contains(.fullscreen));
}
