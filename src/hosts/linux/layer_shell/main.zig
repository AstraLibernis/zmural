// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! `zmural --layer-shell`: Linux display host for wlr-layer-shell compositors
//! (Sway, Hyprland, Niri, River, COSMIC, Wayfire, labwc...).
//!
//! - one background layer surface per wl_output (`host.zig`)
//! - one connection per output to zmural's display socket, showing the
//!   renderers' DMA-BUFs as the daemon routes them (`link.zig`)
//! - `--test-pattern`: draw the test pattern from shared memory, with no
//!   daemon (checks the compositor side on its own)
//!
//! Still to come (M6): `covered` (it needs window geometry), and the app in
//! front (the display protocol has no field for it).

const std = @import("std");
const linux = std.os.linux;
const zmural = @import("zmural");
const wl = zmural.os.wayland;
const backend = @import("../backend.zig");
const host_mod = @import("host.zig");
const Host = host_mod.Host;
const Output = host_mod.Output;
const Links = @import("link.zig").Links;

const usage =
    \\usage: zmural --layer-shell [options]
    \\
    \\  (no options)    show the wallpapers zmural sends, on every output
    \\  --test-pattern  draw the test pattern on every output (no daemon)
    \\
    \\zmural starts this itself on desktops that need it; run it by hand only to
    \\test. A second one on the same display exits at once.
    \\  --version       print the version and exit
    \\  --help          show this help
    \\
;

/// `args`: what follows `--layer-shell` on the command line.
pub fn start(init: std.process.Init, args: []const []const u8) !void {
    const gpa = init.gpa;
    var test_pattern = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--test-pattern")) {
            test_pattern = true;
        } else if (std.mem.eql(u8, a, "--parent")) {
            // Started by zmural: live exactly as long as it does, so
            // quitting zmural (or its death) takes the wallpaper away.
            i += 1;
            const parent = if (i < args.len) std.fmt.parseInt(linux.pid_t, args[i], 10) catch 0 else 0;
            _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.TERM), 0, 0, 0);
            // It may have died before the line above ran.
            if (linux.getppid() != parent) return;
        } else if (std.mem.eql(u8, a, "--version")) {
            std.debug.print("zmural --layer-shell {s}\n", .{zmural.version}); // zsnag:ok — CLI output
            return;
        } else if (std.mem.eql(u8, a, "--help")) {
            std.debug.print("{s}", .{usage}); // zsnag:ok — CLI output
            return;
        } else {
            std.log.err("unknown option '{s}'; see --help", .{a});
            std.process.exit(2);
        }
    }

    const env = init.environ_map;
    const conn = wl.Conn.connect(gpa, zmural.os.xdg.dir(env.get("XDG_RUNTIME_DIR")), env.get("WAYLAND_DISPLAY")) catch |err| {
        std.log.err("can't reach the Wayland compositor: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
    var host: Host = .init(gpa, conn);
    defer host.deinit();

    var pattern: Pattern = .{ .host = &host };
    defer pattern.deinit();
    var links: ?Links = null;
    defer if (links) |*l| l.deinit();

    if (test_pattern) {
        host.listener = .{ .ctx = &pattern, .output_ready = Pattern.onReady, .output_gone = Pattern.onGone, .released = Pattern.onReleased };
    } else {
        const xdg = zmural.os.xdg.dir(env.get("XDG_RUNTIME_DIR")) orelse "";
        var dir_buf: [256]u8 = undefined;
        const zmural_dir = zmural.protocol.unix.runtimeDir(&dir_buf, xdg) catch |err| {
            std.log.err("no private runtime directory ($XDG_RUNTIME_DIR/zmural): {s}", .{@errorName(err)});
            std.process.exit(1);
        };
        // One host per Wayland display: a second would draw a second background.
        var lock_buf: [300]u8 = undefined;
        if (backend.lockPath(&lock_buf, zmural_dir, env.get("WAYLAND_DISPLAY"))) |lock| {
            _ = backend.takeLock(lock) catch |err| switch (err) {
                error.Held => {
                    std.log.info("another zmural layer-shell host already shows on this display; leaving it to it", .{});
                    std.process.exit(backend.exit_already_running);
                },
                error.CannotLock => std.log.warn("can't lock {s}: a second host could start on this display", .{lock}),
            };
        }
        var addr_buf: [256]u8 = undefined;
        const socket_path = try zmural.protocol.transport.address(&addr_buf, .linux, .display, xdg);
        const drm = zmural.os.syncobj.openRenderNode() orelse {
            // No GPU (a VM without one): starting again can't help.
            std.log.err("no DRM render node: zmural's display host needs a GPU, for frame sync with zmural", .{});
            std.process.exit(backend.exit_unsupported);
        };
        links = .{ .gpa = gpa, .io = init.io, .host = &host, .socket_path = try init.arena.allocator().dupe(u8, socket_path), .drm = drm };
        host.listener = links.?.listener();
    }

    host.start() catch |err| switch (err) {
        // Said by `host.start`; the daemon reads the exit code and stops trying.
        error.Unsupported => std.process.exit(backend.exit_unsupported),
        else => return err,
    };
    for (host.outputs.items) |o| {
        const id = host_mod.monitorId(init.io, o.connector());
        std.log.info("output {s}: {d}x{d} @ {d} mHz, scale {d}, monitor {s}", .{ o.connector(), o.width, o.height, o.refresh_mhz, o.scale, &id });
    }
    std.log.info("dmabuf: device 0x{x}, {d} XRGB8888 modifiers", .{ host.feedback.device, host.feedback.count });
    try run(&host, &pattern, if (links) |*l| l else null);
}

fn run(host: *Host, pattern: *Pattern, links: ?*Links) !void {
    while (true) {
        if (pattern.failed) |err| return err;
        try host.conn.flush();
        var fds: [1 + 32]linux.pollfd = undefined;
        fds[0] = .{ .fd = host.conn.fd, .events = linux.POLL.IN, .revents = 0 };
        const n = 1 + if (links) |l| l.pollFds(fds[1..]) else 0;
        const timeout = if (links) |l| l.timeoutMs() else -1;
        const rc = linux.poll(&fds, n, timeout);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }
        if (fds[0].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0 and fds[0].revents & linux.POLL.IN == 0)
            return error.CompositorGone;
        if (fds[0].revents != 0) {
            try host.conn.fill();
            try host.dispatch();
        }
        if (links) |l| {
            for (fds[1..n]) |f| if (f.revents != 0) try l.readable(f.fd);
            l.tick();
        }
    }
}

/// Test-pattern mode: one shared-memory buffer per output, drawn once.
const Pattern = struct {
    host: *Host,
    maps: [8]?[]align(std.heap.page_size_min) u8 = @splat(null),
    failed: ?anyerror = null,

    fn deinit(pt: *Pattern) void {
        for (pt.maps) |m| if (m) |bytes| {
            _ = linux.munmap(bytes.ptr, bytes.len);
        };
    }

    fn onReady(ctx: *anyopaque, o: *Output) void {
        const pt: *Pattern = @ptrCast(@alignCast(ctx)); // zsnag:ok — set from a *Pattern in main
        pt.draw(o) catch |err| {
            std.log.err("{s}: test pattern failed: {s}", .{ o.connector(), @errorName(err) });
            pt.failed = err;
        };
    }

    fn draw(pt: *Pattern, o: *Output) !void {
        const width = if (o.width != 0) o.width else o.logical_w;
        const height = if (o.height != 0) o.height else o.logical_h;
        const stride = width * 4;
        const size = stride * height;
        const rc = linux.memfd_create("zmural-test-pattern", linux.MFD.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.MemfdFailed;
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, size)) != .SUCCESS) return error.MemfdFailed;
        const addr = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        if (linux.errno(addr) != .SUCCESS) return error.MmapFailed;
        const bytes: []align(std.heap.page_size_min) u8 = @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(addr))[0..size];
        for (&pt.maps) |*m| if (m.* == null) {
            m.* = bytes;
            break;
        };
        zmural.sdk.testpattern.fill(std.mem.bytesAsSlice(u32, bytes), width, height, width, 0);

        const buffer = try pt.host.addShmBuffer(fd, size, width, height, stride);
        try pt.host.setBuffers(o, width, height, &.{buffer});
        try pt.host.frameReady(o, 0);
    }

    fn onGone(_: *anyopaque, o: *Output) void {
        std.log.info("output {s} gone", .{o.connector()});
    }

    fn onReleased(_: *anyopaque, _: *Output, _: u8) void {}
};

test {
    _ = @import("host.zig");
}
