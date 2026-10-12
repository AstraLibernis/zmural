// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Opcodes for the Wayland interfaces the layer-shell host uses, copied from
//! the protocol XML (request and event numbers are their order there):
//! wayland.xml 1.24, wlr-layer-shell-unstable-v1, linux-dmabuf-v1,
//! viewporter, single-pixel-buffer-v1.
//!
//! `version` is the highest version zmural binds; it only uses requests and
//! events that exist at that version.

pub const wl_display = struct {
    pub const event = enum(u16) { @"error" = 0, delete_id = 1 };
};

pub const wl_registry = struct {
    pub const event = enum(u16) { global = 0, global_remove = 1 };
};

pub const wl_callback = struct {
    pub const event = enum(u16) { done = 0 };
};

pub const wl_compositor = struct {
    pub const name = "wl_compositor";
    pub const version = 4;
    pub const request = enum(u16) { create_surface = 0, create_region = 1 };
};

pub const wl_subcompositor = struct {
    pub const name = "wl_subcompositor";
    pub const version = 1;
    pub const request = enum(u16) { destroy = 0, get_subsurface = 1 };
};

pub const wl_surface = struct {
    pub const request = enum(u16) {
        destroy = 0,
        attach = 1,
        damage = 2,
        frame = 3,
        set_opaque_region = 4,
        set_input_region = 5,
        commit = 6,
        set_buffer_transform = 7,
        set_buffer_scale = 8,
        damage_buffer = 9,
    };
};

pub const wl_subsurface = struct {
    pub const request = enum(u16) { destroy = 0, set_position = 1, place_above = 2, place_below = 3, set_sync = 4, set_desync = 5 };
};

pub const wl_region = struct {
    pub const request = enum(u16) { destroy = 0, add = 1, subtract = 2 };
};

pub const wl_output = struct {
    pub const name = "wl_output";
    /// v4 adds `name` (the connector, "DP-1") and `description`.
    pub const version = 4;
    pub const request = enum(u16) { release = 0 };
    pub const event = enum(u16) { geometry = 0, mode = 1, done = 2, scale = 3, name = 4, description = 5 };
    /// `mode` flags.
    pub const mode_current: u32 = 1;
};

pub const wl_shm = struct {
    pub const name = "wl_shm";
    pub const version = 1;
    pub const request = enum(u16) { create_pool = 0 };
    pub const format_xrgb8888: u32 = 1;
};

pub const wl_shm_pool = struct {
    pub const request = enum(u16) { create_buffer = 0, destroy = 1, resize = 2 };
};

pub const wl_buffer = struct {
    pub const request = enum(u16) { destroy = 0 };
    pub const event = enum(u16) { release = 0 };
};

pub const zwlr_layer_shell_v1 = struct {
    pub const name = "zwlr_layer_shell_v1";
    /// v3 adds `destroy`; nothing newer is needed.
    pub const version = 3;
    pub const request = enum(u16) { get_layer_surface = 0, destroy = 1 };
    pub const layer_background: u32 = 0;
};

pub const zwlr_layer_surface_v1 = struct {
    pub const request = enum(u16) {
        set_size = 0,
        set_anchor = 1,
        set_exclusive_zone = 2,
        set_margin = 3,
        set_keyboard_interactivity = 4,
        get_popup = 5,
        ack_configure = 6,
        destroy = 7,
    };
    pub const event = enum(u16) { configure = 0, closed = 1 };
    /// top | bottom | left | right
    pub const anchor_all: u32 = 1 | 2 | 4 | 8;
};

pub const zwp_linux_dmabuf_v1 = struct {
    pub const name = "zwp_linux_dmabuf_v1";
    /// v4: feedback objects (main device, format table, tranches).
    pub const version = 4;
    pub const request = enum(u16) { destroy = 0, create_params = 1, get_default_feedback = 2, get_surface_feedback = 3 };
};

pub const zwp_linux_buffer_params_v1 = struct {
    pub const request = enum(u16) { destroy = 0, add = 1, create = 2, create_immed = 3 };
    pub const event = enum(u16) { created = 0, failed = 1 };
};

pub const zwp_linux_dmabuf_feedback_v1 = struct {
    pub const request = enum(u16) { destroy = 0 };
    pub const event = enum(u16) {
        done = 0,
        format_table = 1,
        main_device = 2,
        tranche_done = 3,
        tranche_target_device = 4,
        tranche_formats = 5,
        tranche_flags = 6,
    };
};

pub const wp_viewporter = struct {
    pub const name = "wp_viewporter";
    pub const version = 1;
    pub const request = enum(u16) { destroy = 0, get_viewport = 1 };
};

pub const wp_viewport = struct {
    pub const request = enum(u16) { destroy = 0, set_source = 1, set_destination = 2 };
};

pub const wp_single_pixel_buffer_manager_v1 = struct {
    pub const name = "wp_single_pixel_buffer_manager_v1";
    pub const version = 1;
    pub const request = enum(u16) { destroy = 0, create_u32_rgba_buffer = 1 };
};

/// DRM fourcc codes (drm_fourcc.h).
pub const fourcc = struct {
    pub const xrgb8888: u32 = 0x34325258; // 'XR24'
    pub const argb8888: u32 = 0x34325241; // 'AR24'
};
pub const modifier_linear: u64 = 0;
pub const modifier_invalid: u64 = 0x00ffffffffffffff;

pub const zwlr_foreign_toplevel_manager_v1 = struct {
    pub const name = "zwlr_foreign_toplevel_manager_v1";
    /// v2 adds fullscreen state; v3 only adds `parent`, which we ignore.
    pub const version = 2;
    pub const request = enum(u16) { stop = 0 };
    pub const event = enum(u16) { toplevel = 0, finished = 1 };
};

pub const zwlr_foreign_toplevel_handle_v1 = struct {
    pub const request = enum(u16) { destroy = 7 };
    pub const event = enum(u16) { title = 0, app_id = 1, output_enter = 2, output_leave = 3, state = 4, done = 5, closed = 6, parent = 7 };
    /// Values in the `state` array.
    pub const state = struct {
        pub const maximized: u32 = 0;
        pub const minimized: u32 = 1;
        pub const activated: u32 = 2;
        pub const fullscreen: u32 = 3;
    };
};
