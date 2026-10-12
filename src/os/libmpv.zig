// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! libmpv (client API v2), loaded at runtime so zmural has no build-time
//! dependency on it. Declared from mpv's own `client.h`: only what we call.
//!
//! Windows: `libmpv-2.dll` is looked for next to the running executable.
//! Linux: the system's `libmpv.so.2` (dlopen), plus the render API
//! (`render.h`, `render_gl.h`) that draws into zmural's own GPU buffers.

const std = @import("std");
const w = @import("win32.zig");

pub const Handle = opaque {};

pub const Event = extern struct {
    event_id: c_int,
    @"error": c_int,
    reply_userdata: u64,
    data: ?*anyopaque,
};

pub const LogMessage = extern struct {
    prefix: [*:0]const u8,
    level: [*:0]const u8,
    text: [*:0]const u8,
    log_level: c_int,
};

pub const EndFile = extern struct {
    reason: c_int,
    @"error": c_int,
    playlist_entry_id: i64,
    playlist_insert_id: i64,
    playlist_insert_num_entries: c_int,
};

pub const event = struct {
    pub const none: c_int = 0;
    pub const shutdown: c_int = 1;
    pub const log_message: c_int = 2;
    pub const end_file: c_int = 7;
    pub const file_loaded: c_int = 8;
    pub const playback_restart: c_int = 21;
};

pub const end_reason = struct {
    pub const eof: c_int = 0;
    pub const stop: c_int = 2;
    pub const quit: c_int = 3;
    pub const @"error": c_int = 4;
};

pub const WakeupFn = *const fn (?*anyopaque) callconv(.c) void;

pub const Error = error{ LibraryNotFound, SymbolMissing, UnsupportedVersion };

/// Every field is looked up as `mpv_<field name>`.
pub const Api = struct {
    client_api_version: *const fn () callconv(.c) c_ulong,
    error_string: *const fn (c_int) callconv(.c) [*:0]const u8,
    create: *const fn () callconv(.c) ?*Handle,
    initialize: *const fn (*Handle) callconv(.c) c_int,
    terminate_destroy: *const fn (*Handle) callconv(.c) void,
    set_option_string: *const fn (*Handle, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    set_property_string: *const fn (*Handle, [*:0]const u8, [*:0]const u8) callconv(.c) c_int,
    /// The result must be released with `free`.
    get_property_string: *const fn (*Handle, [*:0]const u8) callconv(.c) ?[*:0]u8,
    free: *const fn (?*anyopaque) callconv(.c) void,
    command: *const fn (*Handle, [*]const ?[*:0]const u8) callconv(.c) c_int,
    wait_event: *const fn (*Handle, f64) callconv(.c) *Event,
    set_wakeup_callback: *const fn (*Handle, ?WakeupFn, ?*anyopaque) callconv(.c) void,
    request_log_messages: *const fn (*Handle, [*:0]const u8) callconv(.c) c_int,

    /// Linux: from the system's libmpv. The library stays loaded for the
    /// life of the process.
    pub fn loadSystem() Error!struct { Api, RenderApi } {
        var lib = std.DynLib.open("libmpv.so.2") catch return error.LibraryNotFound;
        errdefer lib.close();
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |f| {
            @field(api, f.name) = lib.lookup(f.type, "mpv_" ++ f.name) orelse return error.SymbolMissing;
        }
        if (api.client_api_version() >> 16 != 2) return error.UnsupportedVersion;
        var render: RenderApi = undefined;
        inline for (@typeInfo(RenderApi).@"struct".fields) |f| {
            @field(render, f.name) = lib.lookup(f.type, "mpv_render_context_" ++ f.name) orelse return error.SymbolMissing;
        }
        return .{ api, render };
    }

    pub fn load(path: [*:0]const u16) Error!Api {
        const lib = w.LoadLibraryW(path) orelse return error.LibraryNotFound;
        errdefer _ = w.FreeLibrary(lib);
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |f| {
            const sym = w.GetProcAddress(lib, "mpv_" ++ f.name) orelse return error.SymbolMissing;
            @field(api, f.name) = @ptrCast(sym); // zsnag:ok — signature declared from mpv's client.h
        }
        // Major version 2 is the stable client API this binding was written against.
        if (api.client_api_version() >> 16 != 2) return error.UnsupportedVersion;
        return api;
    }
};

/// The render API: mpv draws frames into a framebuffer we own.
pub const RenderContext = opaque {};

pub const RenderParam = extern struct {
    type: c_int,
    data: ?*anyopaque,
};

pub const render_param = struct {
    pub const invalid: c_int = 0;
    pub const api_type: c_int = 1;
    pub const opengl_init_params: c_int = 2;
    pub const opengl_fbo: c_int = 3;
    pub const flip_y: c_int = 4;
    pub const block_for_target_time: c_int = 12;
    pub const drm_display_v2: c_int = 16;
};

/// `mpv_opengl_drm_params_v2`. Only `render_fd` matters to us: it tells mpv
/// which GPU a hardware decoder (VA-API) must use so its frames can be shown
/// without a copy. The other fields drive a KMS display, which we don't have.
pub const DrmParamsV2 = extern struct {
    fd: c_int = -1,
    crtc_id: c_int = 0,
    connector_id: c_int = 0,
    atomic_request_ptr: ?*anyopaque = null,
    render_fd: c_int,
};

pub const render_api_type_opengl: [*:0]const u8 = "opengl";
/// `mpv_render_context_update` flag: a new frame should be rendered.
pub const render_update_frame: u64 = 1 << 0;

pub const OpenGlInitParams = extern struct {
    get_proc_address: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
    get_proc_address_ctx: ?*anyopaque,
};

pub const OpenGlFbo = extern struct {
    fbo: c_int,
    w: c_int,
    h: c_int,
    /// 0: mpv picks.
    internal_format: c_int = 0,
};

pub const RenderUpdateFn = *const fn (?*anyopaque) callconv(.c) void;

/// Every field is looked up as `mpv_render_context_<field name>`.
pub const RenderApi = struct {
    create: *const fn (*?*RenderContext, *Handle, [*]const RenderParam) callconv(.c) c_int,
    set_update_callback: *const fn (*RenderContext, ?RenderUpdateFn, ?*anyopaque) callconv(.c) void,
    update: *const fn (*RenderContext) callconv(.c) u64,
    render: *const fn (*RenderContext, [*]const RenderParam) callconv(.c) c_int,
    report_swap: *const fn (*RenderContext) callconv(.c) void,
    free: *const fn (*RenderContext) callconv(.c) void,
};
