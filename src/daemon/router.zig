// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Which renderer feeds which monitor. When sharing is on, monitors showing
//! the same wallpaper share one renderer process. The router only decides;
//! the daemon spawns and stops the processes it reports.

const std = @import("std");
const MonitorId = @import("zmural").monitor.Id;

pub const RendererId = u32;

pub const Router = struct {
    renderers: std.ArrayList(Renderer) = .empty,
    links: std.ArrayList(Link) = .empty,
    next_id: RendererId = 1,
    share: bool = true,

    pub const Renderer = struct {
        id: RendererId,
        /// Borrowed and never read after `assign`: the daemon rebuilds the
        /// router whenever the wallpaper (and so this slice) changes.
        wallpaper: []const u8,
        /// Whatever else a renderer is started with (the fill mode): monitors
        /// share one only when this matches too.
        variant: u8 = 0,
        users: u32,
    };

    pub const Link = struct { monitor: MonitorId, renderer: RendererId };

    pub const Assignment = struct {
        renderer: RendererId,
        /// A new renderer process must be started.
        spawn: bool,
        /// A renderer that nothing uses any more and should be stopped.
        stop: ?RendererId,
    };

    pub fn deinit(r: *Router, gpa: std.mem.Allocator) void {
        r.renderers.deinit(gpa);
        r.links.deinit(gpa);
    }

    pub fn assign(r: *Router, gpa: std.mem.Allocator, monitor: MonitorId, wallpaper: []const u8, variant: u8) !Assignment {
        try r.links.ensureUnusedCapacity(gpa, 1);
        try r.renderers.ensureUnusedCapacity(gpa, 1);

        if (r.rendererFor(monitor)) |id| {
            const cur = r.get(id).?;
            if (cur.variant == variant and std.mem.eql(u8, cur.wallpaper, wallpaper)) return .{ .renderer = id, .spawn = false, .stop = null };
        }
        const stop = r.release(monitor);

        if (r.share) {
            for (r.renderers.items) |*rd| {
                if (rd.variant == variant and std.mem.eql(u8, rd.wallpaper, wallpaper)) {
                    rd.users += 1;
                    r.links.appendAssumeCapacity(.{ .monitor = monitor, .renderer = rd.id });
                    return .{ .renderer = rd.id, .spawn = false, .stop = stop };
                }
            }
        }
        const id = r.next_id;
        r.next_id += 1;
        r.renderers.appendAssumeCapacity(.{ .id = id, .wallpaper = wallpaper, .variant = variant, .users = 1 });
        r.links.appendAssumeCapacity(.{ .monitor = monitor, .renderer = id });
        return .{ .renderer = id, .spawn = true, .stop = stop };
    }

    /// Clears the monitor. Returns a renderer to stop if nothing else uses it.
    pub fn release(r: *Router, monitor: MonitorId) ?RendererId {
        for (r.links.items, 0..) |l, i| {
            if (!std.mem.eql(u8, &l.monitor, &monitor)) continue;
            _ = r.links.swapRemove(i);
            for (r.renderers.items, 0..) |*rd, j| {
                if (rd.id != l.renderer) continue;
                rd.users -= 1;
                if (rd.users == 0) {
                    _ = r.renderers.swapRemove(j);
                    return l.renderer;
                }
                return null;
            }
            unreachable;
        }
        return null;
    }

    pub fn rendererFor(r: *const Router, monitor: MonitorId) ?RendererId {
        for (r.links.items) |l| if (std.mem.eql(u8, &l.monitor, &monitor)) return l.renderer;
        return null;
    }

    pub fn get(r: *const Router, id: RendererId) ?*const Renderer {
        for (r.renderers.items) |*rd| if (rd.id == id) return rd;
        return null;
    }
};

test "monitors share a renderer and stop it when the last one leaves" {
    const monitor = @import("zmural").monitor;
    const gpa = std.testing.allocator;
    const m1 = monitor.fromConnector("DP-1");
    const m2 = monitor.fromConnector("DP-2");

    var r: Router = .{};
    defer r.deinit(gpa);

    const a = try r.assign(gpa, m1, "rain", 0);
    try std.testing.expect(a.spawn);
    const b = try r.assign(gpa, m2, "rain", 0);
    try std.testing.expect(!b.spawn);
    try std.testing.expectEqual(a.renderer, b.renderer);

    // Re-applying the same wallpaper is a no-op.
    const same = try r.assign(gpa, m1, "rain", 0);
    try std.testing.expect(!same.spawn and same.stop == null);

    // m1 moves on; "rain" survives because m2 still shows it.
    const c = try r.assign(gpa, m1, "city", 0);
    try std.testing.expect(c.spawn and c.stop == null);

    // m2 follows; "rain" has no users left and must stop.
    const d = try r.assign(gpa, m2, "city", 0);
    try std.testing.expect(!d.spawn);
    try std.testing.expectEqual(@as(?RendererId, a.renderer), d.stop);
    try std.testing.expectEqual(@as(usize, 1), r.renderers.items.len);
}

test "without sharing every monitor gets its own renderer" {
    const monitor = @import("zmural").monitor;
    const gpa = std.testing.allocator;
    var r: Router = .{ .share = false };
    defer r.deinit(gpa);
    const a = try r.assign(gpa, monitor.fromConnector("A"), "rain", 0);
    const b = try r.assign(gpa, monitor.fromConnector("B"), "rain", 0);
    try std.testing.expect(a.spawn and b.spawn and a.renderer != b.renderer);
}

test "the same wallpaper with another fill mode is another renderer" {
    const monitor = @import("zmural").monitor;
    const gpa = std.testing.allocator;
    var r: Router = .{};
    defer r.deinit(gpa);
    const m1 = monitor.fromConnector("A");
    const m2 = monitor.fromConnector("B");
    const a = try r.assign(gpa, m1, "rain", 0);
    const b = try r.assign(gpa, m2, "rain", 1);
    try std.testing.expect(a.spawn and b.spawn and a.renderer != b.renderer);
    // m2 takes m1's fill: it joins m1's renderer and its own stops.
    const c = try r.assign(gpa, m2, "rain", 0);
    try std.testing.expect(!c.spawn);
    try std.testing.expectEqual(a.renderer, c.renderer);
    try std.testing.expectEqual(@as(?RendererId, b.renderer), c.stop);
    // Asking again for what it has changes nothing.
    const d = try r.assign(gpa, m2, "rain", 0);
    try std.testing.expect(!d.spawn and d.stop == null);
}
