// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Test tool: drives one virtual mouse (wlr-virtual-pointer-unstable-v1, on
//! Sway and other wlroots compositors) through a script, keeping the device
//! alive throughout so windows see it enter, move and click like a real one.
//!
//!   zmural-test-input <width> <height> <step>...
//!   steps: move:X,Y  click  rclick  scroll:N  wait:MS
//!
//! Positions are absolute, in the output's `width` x `height` pixels.

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const wl = zmural.os.wayland;

const btn_left = 0x110;
const btn_right = 0x111;

pub fn main(init: std.process.Init) !void {
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len < 3) {
        std.log.err("usage: zmural-test-input <width> <height> move:X,Y|click|rclick|scroll:N|wait:MS...", .{});
        std.process.exit(2);
    }
    const width = try std.fmt.parseInt(u32, argv[1], 10);
    const height = try std.fmt.parseInt(u32, argv[2], 10);
    const env = init.environ_map;
    var c = try wl.Conn.connect(init.gpa, env.get("XDG_RUNTIME_DIR"), env.get("WAYLAND_DISPLAY"));
    defer c.close();

    const registry = try c.getRegistry();
    var manager: wl.ObjectId = 0;
    var seat: wl.ObjectId = 0;
    const cb = try c.sync();
    try c.flush();
    var done = false;
    while (!done) {
        try c.fill();
        while (try c.next()) |ev| {
            var e = ev;
            if (e.object == registry and e.opcode == 0) {
                const name = try e.args.uint();
                const iface = try e.args.string() orelse continue;
                if (std.mem.eql(u8, iface, "zwlr_virtual_pointer_manager_v1")) manager = try c.bind(registry, name, iface, 1);
                if (std.mem.eql(u8, iface, "wl_seat") and seat == 0) seat = try c.bind(registry, name, iface, 1);
            } else if (e.object == cb) done = true;
        }
    }
    if (manager == 0) return error.NoVirtualPointer;
    const vp = c.newId();
    try c.request(manager, 0, &.{ .{ .object = seat }, .{ .new_id = vp } });

    var t: u32 = 0;
    for (argv[3..]) |step| {
        t += 10;
        if (std.mem.startsWith(u8, step, "move:")) {
            var it = std.mem.splitScalar(u8, step[5..], ',');
            const x = try std.fmt.parseInt(u32, it.next() orelse return error.BadStep, 10);
            const y = try std.fmt.parseInt(u32, it.next() orelse return error.BadStep, 10);
            try c.request(vp, 1, &.{ .{ .uint = t }, .{ .uint = x }, .{ .uint = y }, .{ .uint = width }, .{ .uint = height } });
            try c.request(vp, 4, &.{});
        } else if (std.mem.eql(u8, step, "click") or std.mem.eql(u8, step, "rclick")) {
            const b: u32 = if (step[0] == 'r') btn_right else btn_left;
            try c.request(vp, 2, &.{ .{ .uint = t }, .{ .uint = b }, .{ .uint = 1 } });
            try c.request(vp, 4, &.{});
            try c.flush();
            sleep(60);
            try c.request(vp, 2, &.{ .{ .uint = t + 60 }, .{ .uint = b }, .{ .uint = 0 } });
            try c.request(vp, 4, &.{});
        } else if (std.mem.startsWith(u8, step, "scroll:")) {
            const n = try std.fmt.parseInt(i32, step[7..], 10);
            try c.request(vp, 3, &.{ .{ .uint = t }, .{ .uint = 0 }, .{ .fixed = wl.fixed(@floatFromInt(n * 15)) } });
            try c.request(vp, 4, &.{});
        } else if (std.mem.startsWith(u8, step, "wait:")) {
            try c.flush();
            sleep(try std.fmt.parseInt(u32, step[5..], 10));
        } else return error.BadStep;
        try c.flush();
        sleep(30);
    }
    try c.request(vp, 8, &.{});
    try c.flush();
}

fn sleep(ms: u32) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}
