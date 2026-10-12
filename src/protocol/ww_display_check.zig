// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Cross-check: zmural's Zig codec (`ww_display.zig`) against waywallen's
//! generated C codec (`src/generated/ww_proto.c` in waywallen-display), byte
//! for byte, in both directions. Run with
//! `zig build ww-codec-check -Dwaywallen-display=<path to a checkout>`.

const std = @import("std");
const ww = @import("ww_display.zig");
const c = @cImport(@cInclude("ww_proto.h"));
const testing = std.testing;

const hdr = ww.header_len;

fn cBytes(buf: *c.ww_buf_t) []const u8 {
    return if (buf.data) |d| d[0..buf.len] else &.{};
}

fn cstr(s: [:0]const u8) [*c]u8 {
    return @constCast(s.ptr);
}

test "welcome" {
    var zb: [256]u8 = undefined;
    const z = try ww.encodeWelcome(&zb, "zmural 0.1.0");
    var b: c.ww_buf_t = undefined;
    c.ww_buf_init(&b);
    defer c.ww_buf_free(&b);
    const m: c.ww_evt_welcome_t = .{ .server_version = cstr("zmural 0.1.0") };
    try testing.expectEqual(@as(c_int, 0), c.ww_evt_welcome_encode(&m, &b));
    try testing.expectEqualSlices(u8, cBytes(&b), z[hdr..]);
}

test "display_accepted" {
    var zb: [256]u8 = undefined;
    const z = try ww.encodeDisplayAccepted(&zb, 7, .{ .config_generation = 3, .state_generation = 5, .paused = true });
    var b: c.ww_buf_t = undefined;
    c.ww_buf_init(&b);
    defer c.ww_buf_free(&b);
    var m: c.ww_evt_display_accepted_t = std.mem.zeroes(c.ww_evt_display_accepted_t);
    m.display_id = 7;
    m.presentation.config.generation = 3;
    m.presentation.config.pause_effect.blur.radius = 30;
    m.presentation.config.transition.duration_ms = 500;
    m.presentation.config.transition.origin_x = 0.5;
    m.presentation.config.transition.origin_y = 0.5;
    m.presentation.state.generation = 5;
    m.presentation.state.config_generation = 3;
    m.presentation.state.pause_effect.active = true;
    try testing.expectEqual(@as(c_int, 0), c.ww_evt_display_accepted_encode(&m, &b));
    try testing.expectEqualSlices(u8, cBytes(&b), z[hdr..]);
}

test "bind_buffers" {
    var zb: [1024]u8 = undefined;
    const z = try ww.encodeBindBuffers(&zb, .{
        .buffer_generation = 2,
        .count = 3,
        .width = 1920,
        .height = 1080,
        .fourcc = 0x34325258,
        .modifier = 0x200000000401b03,
        .stride = 7680,
        .offset = 64,
        .size = 8294400,
        .initial_config = .{
            .generation = 1,
            .buffer_generation = 2,
            .source_rect = .{ .x = 10, .y = 20, .w = 1900, .h = 1060 },
            .dest_rect = .{ .w = 2560, .h = 1440 },
            .transform = 0,
            .clear_color = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1 },
        },
        .content_token = 99,
        .presentation_config_generation = 4,
    });
    var strides = [_]u32{ 7680, 7680, 7680 };
    var offsets = [_]u32{ 64, 64, 64 };
    var sizes = [_]u64{ 8294400, 8294400, 8294400 };
    const m: c.ww_evt_bind_buffers_t = .{
        .buffer_generation = 2,
        .count = 3,
        .width = 1920,
        .height = 1080,
        .fourcc = 0x34325258,
        .modifier = 0x200000000401b03,
        .planes_per_buffer = 1,
        .stride = .{ .count = 3, .data = &strides },
        .plane_offset = .{ .count = 3, .data = &offsets },
        .size = .{ .count = 3, .data = &sizes },
        .initial_config = .{
            .generation = 1,
            .buffer_generation = 2,
            .source_rect = .{ .x = 10, .y = 20, .w = 1900, .h = 1060 },
            .dest_rect = .{ .x = 0, .y = 0, .w = 2560, .h = 1440 },
            .transform = 0,
            .clear_color = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1 },
        },
        .content_token = 99,
        .presentation_config_generation = 4,
    };
    var b: c.ww_buf_t = undefined;
    c.ww_buf_init(&b);
    defer c.ww_buf_free(&b);
    try testing.expectEqual(@as(c_int, 0), c.ww_evt_bind_buffers_encode(&m, &b));
    try testing.expectEqualSlices(u8, cBytes(&b), z[hdr..]);
}

test "frame_ready and set_window_observation_config" {
    var zb: [256]u8 = undefined;
    var b: c.ww_buf_t = undefined;
    c.ww_buf_init(&b);
    defer c.ww_buf_free(&b);

    const z = try ww.encodeFrameReady(&zb, .{ .buffer_generation = 5, .buffer_index = 2, .seq = 1234 });
    const fr: c.ww_evt_frame_ready_t = .{ .buffer_generation = 5, .buffer_index = 2, .seq = 1234 };
    try testing.expectEqual(@as(c_int, 0), c.ww_evt_frame_ready_encode(&fr, &b));
    try testing.expectEqualSlices(u8, cBytes(&b), z[hdr..]);

    c.ww_buf_free(&b);
    c.ww_buf_init(&b);
    const zo = try ww.encodeWindowObservationConfig(&zb, 0);
    const wo: c.ww_evt_set_window_observation_config_t = std.mem.zeroes(c.ww_evt_set_window_observation_config_t);
    try testing.expectEqual(@as(c_int, 0), c.ww_evt_set_window_observation_config_encode(&wo, &b));
    try testing.expectEqualSlices(u8, cBytes(&b), zo[hdr..]);
}

test "their register_display decodes with ours" {
    var fourccs = [_]u32{ 0x34325258, 0x34325241 };
    var counts = [_]u32{ 2, 1 };
    var mods = [_]u64{ 0x200000000401b03, 0, 0x100000000000001 };
    var planes = [_]u32{ 1, 1, 2 };
    var uuid = [_]u32{ 1, 2, 3, 4 };
    var m: c.ww_req_register_display_t = std.mem.zeroes(c.ww_req_register_display_t);
    m.name = cstr("DP-1");
    m.instance_id = cstr("kde-abcdef");
    m.metrics = .{ .width = 2560, .height = 1440, .refresh_mhz = 143998 };
    m.consumer_caps.fourccs = .{ .count = 2, .data = &fourccs };
    m.consumer_caps.mod_counts = .{ .count = 2, .data = &counts };
    m.consumer_caps.modifiers = .{ .count = 3, .data = &mods };
    m.consumer_caps.plane_counts = .{ .count = 3, .data = &planes };
    m.consumer_caps.device_uuid = .{ .count = 4, .data = &uuid };
    m.consumer_caps.driver_uuid = .{ .count = 4, .data = &uuid };
    m.consumer_caps.drm_render_major = 226;
    m.consumer_caps.drm_render_minor = 129;
    m.consumer_caps.sync_caps = 6;
    m.window_state_flags = 3;
    var b: c.ww_buf_t = undefined;
    c.ww_buf_init(&b);
    defer c.ww_buf_free(&b);
    try testing.expectEqual(@as(c_int, 0), c.ww_req_register_display_encode(&m, &b));

    const reg = try ww.decodeRegister(cBytes(&b));
    try testing.expectEqualStrings("DP-1", reg.name);
    try testing.expectEqualStrings("kde-abcdef", reg.instance_id);
    try testing.expectEqual(@as(u32, 143998), reg.metrics.refresh_mhz);
    try testing.expectEqual(@as(u32, 3), reg.window_flags);
    try testing.expectEqual(@as(u32, 6), reg.caps.sync_caps);
    var out: [8]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{ 0x200000000401b03, 0 }, out[0..reg.caps.singlePlaneModifiers(0x34325258, &out)]);
    // AR24's only modifier is two-plane: none usable.
    try testing.expectEqual(@as(usize, 0), reg.caps.singlePlaneModifiers(0x34325241, &out));
}

test "our hello and register decode with theirs" {
    var zb: [512]u8 = undefined;
    const h = try ww.encodeHello(&zb, .{ .client_name = "zmural-layer-shell", .client_version = "0.1.0", .protocol_version = 9 });
    var hc: c.ww_req_hello_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.ww_req_hello_decode(h[hdr..].ptr, h.len - hdr, &hc));
    defer c.ww_req_hello_free(&hc);
    try testing.expectEqualStrings("zmural-layer-shell", std.mem.span(hc.client_name));
    try testing.expectEqual(@as(u32, 9), hc.protocol_version);

    const r = try ww.encodeRegister(&zb, "HEADLESS-1", "m-fb118bc805127688", .{ .width = 1280, .height = 720 }, 0x34325258, &.{ 0x200000000401b03, 0 }, 226, 129, 0);
    var rc: c.ww_req_register_display_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.ww_req_register_display_decode(r[hdr..].ptr, r.len - hdr, &rc));
    defer c.ww_req_register_display_free(&rc);
    try testing.expectEqual(@as(u32, 2), rc.consumer_caps.modifiers.count);
    try testing.expectEqual(@as(u32, 129), rc.consumer_caps.drm_render_minor);
}

test "our presentation snapshot passes waywallen's client validation rules" {
    // The rules from waywallen-display's presentation_snapshot_valid()
    // (src/display.c), for a client that declared no effects.
    var zb: [256]u8 = undefined;
    const z = try ww.encodeDisplayAccepted(&zb, 1, .{});
    var m: c.ww_evt_display_accepted_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.ww_evt_display_accepted_decode(z[hdr..].ptr, z.len - hdr, &m));
    defer c.ww_evt_display_accepted_free(&m);
    const cfg = m.presentation.config;
    try testing.expect(cfg.generation != 0 and m.presentation.state.generation != 0);
    try testing.expectEqual(cfg.generation, m.presentation.state.config_generation);
    try testing.expectEqual(@as(c_uint, 0), @as(c_uint, @intCast(cfg.pause_effect.kind)));
    try testing.expect(cfg.pause_effect.blur.radius >= 1 and cfg.pause_effect.blur.radius <= 64);
    try testing.expectEqual(@as(c_uint, 0), @as(c_uint, @intCast(cfg.transition.kind)));
    try testing.expect(cfg.transition.duration_ms >= 100 and cfg.transition.duration_ms <= 10000);
    try testing.expect(cfg.transition.angle < 360);
    try testing.expect(cfg.transition.origin_x >= 0 and cfg.transition.origin_x <= 1);
    try testing.expect(cfg.transition.origin_y >= 0 and cfg.transition.origin_y <= 1);
}

test "set_window_observation_state: the C encoder's bytes decode, and ours match them" {
    const m: c.ww_req_set_window_observation_state_t = .{ .config_generation = 0x1122334455667788, .flags = 0xA };
    var b: c.ww_buf_t = undefined;
    c.ww_buf_init(&b);
    defer c.ww_buf_free(&b);
    try testing.expectEqual(@as(c_int, 0), c.ww_req_set_window_observation_state_encode(&m, &b));
    const s = try ww.decodeWindowObservationState(cBytes(&b));
    try testing.expectEqual(@as(u64, 0x1122334455667788), s.config_generation);
    try testing.expectEqual(@as(u32, 0xA), s.flags);

    var buf: [96]u8 = undefined;
    const ours = try ww.encodeWindowObservationState(&buf, s);
    try testing.expectEqualSlices(u8, cBytes(&b), ours[ww.header_len..]);
    var back: c.ww_req_set_window_observation_state_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.ww_req_set_window_observation_state_decode(ours[ww.header_len..].ptr, ours.len - ww.header_len, &back));
    try testing.expectEqual(m.flags, back.flags);
}
