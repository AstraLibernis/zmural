// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! GPU render targets that are DMA-BUFs (Linux): GBM allocates them on the
//! compositor's device, EGL wraps each as an image, and GLES renders into it
//! through a framebuffer object. The DMA-BUF fd goes to the display host,
//! which hands it to the compositor, so frames are never copied.
//!
//! libgbm, libEGL and libGLESv2 are loaded at runtime (dlopen), like libmpv:
//! zmural has no build-time dependency on them. Declarations follow gbm.h,
//! eglext.h and gl2ext.h: only what we call.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    LibraryNotFound,
    SymbolMissing,
    DeviceFailed,
    EglFailed,
    /// The driver lacks an EGL extension zmural needs.
    MissingExtension,
    AllocationFailed,
    /// GBM gave back a multi-plane buffer; zmural passes single-plane only.
    MultiPlane,
    FramebufferIncomplete,
};

pub const Gbm = struct {
    pub const Handle = opaque {};
    pub const Bo = opaque {};
    /// gbm.h: GBM_BO_USE_RENDERING, GBM_BO_USE_LINEAR.
    pub const use_rendering: u32 = 1 << 2;
    pub const use_linear: u32 = 1 << 4;

    create_device: *const fn (fd: c_int) callconv(.c) ?*Handle,
    device_destroy: *const fn (*Handle) callconv(.c) void,
    bo_create: *const fn (*Handle, u32, u32, u32, u32) callconv(.c) ?*Bo,
    bo_create_with_modifiers2: *const fn (*Handle, u32, u32, u32, [*]const u64, c_uint, u32) callconv(.c) ?*Bo,
    bo_destroy: *const fn (*Bo) callconv(.c) void,
    bo_get_fd: *const fn (*Bo) callconv(.c) c_int,
    bo_get_stride: *const fn (*Bo) callconv(.c) u32,
    bo_get_offset: *const fn (*Bo, c_int) callconv(.c) u32,
    bo_get_modifier: *const fn (*Bo) callconv(.c) u64,
    bo_get_plane_count: *const fn (*Bo) callconv(.c) c_int,
};

pub const Egl = struct {
    pub const Display = *anyopaque;
    pub const Context = *anyopaque;
    pub const Image = *anyopaque;
    pub const Attrib = isize;

    pub const platform_gbm: u32 = 0x31D7;
    pub const opengl_es_api: u32 = 0x30A0;
    pub const context_major_version: i32 = 0x3098;
    pub const none: i32 = 0x3038;
    pub const extensions: i32 = 0x3055;
    pub const width: i32 = 0x3057;
    pub const height: i32 = 0x3056;
    pub const linux_dma_buf: u32 = 0x3270;
    pub const linux_drm_fourcc: i32 = 0x3271;
    pub const dma_buf_plane0_fd: i32 = 0x3272;
    pub const dma_buf_plane0_offset: i32 = 0x3273;
    pub const dma_buf_plane0_pitch: i32 = 0x3274;
    pub const dma_buf_plane0_modifier_lo: i32 = 0x3443;
    pub const dma_buf_plane0_modifier_hi: i32 = 0x3444;

    GetProcAddress: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    GetPlatformDisplay: *const fn (u32, ?*anyopaque, ?[*]const Attrib) callconv(.c) ?Display,
    Initialize: *const fn (Display, ?*i32, ?*i32) callconv(.c) u32,
    Terminate: *const fn (Display) callconv(.c) u32,
    BindAPI: *const fn (u32) callconv(.c) u32,
    CreateContext: *const fn (Display, ?*anyopaque, ?Context, [*]const i32) callconv(.c) ?Context,
    DestroyContext: *const fn (Display, Context) callconv(.c) u32,
    MakeCurrent: *const fn (Display, ?*anyopaque, ?*anyopaque, ?Context) callconv(.c) u32,
    QueryString: *const fn (Display, i32) callconv(.c) ?[*:0]const u8,
    GetError: *const fn () callconv(.c) i32,
    CreateImage: *const fn (Display, ?Context, u32, ?*anyopaque, [*]const Attrib) callconv(.c) ?Image,
    DestroyImage: *const fn (Display, Image) callconv(.c) u32,
};

pub const Gl = struct {
    pub const framebuffer: u32 = 0x8D40;
    pub const renderbuffer: u32 = 0x8D41;
    pub const color_attachment0: u32 = 0x8CE0;
    pub const framebuffer_complete: u32 = 0x8CD5;
    pub const color_buffer_bit: u32 = 0x4000;
    pub const scissor_test: u32 = 0x0C11;

    GenFramebuffers: *const fn (i32, [*]u32) callconv(.c) void,
    DeleteFramebuffers: *const fn (i32, [*]const u32) callconv(.c) void,
    BindFramebuffer: *const fn (u32, u32) callconv(.c) void,
    GenRenderbuffers: *const fn (i32, [*]u32) callconv(.c) void,
    DeleteRenderbuffers: *const fn (i32, [*]const u32) callconv(.c) void,
    BindRenderbuffer: *const fn (u32, u32) callconv(.c) void,
    FramebufferRenderbuffer: *const fn (u32, u32, u32, u32) callconv(.c) void,
    CheckFramebufferStatus: *const fn (u32) callconv(.c) u32,
    /// GL_OES_EGL_image, looked up through eglGetProcAddress.
    EGLImageTargetRenderbufferStorageOES: *const fn (u32, *anyopaque) callconv(.c) void,
    Viewport: *const fn (i32, i32, i32, i32) callconv(.c) void,
    ClearColor: *const fn (f32, f32, f32, f32) callconv(.c) void,
    Clear: *const fn (u32) callconv(.c) void,
    Enable: *const fn (u32) callconv(.c) void,
    Disable: *const fn (u32) callconv(.c) void,
    Scissor: *const fn (i32, i32, i32, i32) callconv(.c) void,
    Finish: *const fn () callconv(.c) void,
    Flush: *const fn () callconv(.c) void,
};

/// EGL_ANDROID_native_fence_sync (with EGL_KHR_fence_sync): a fence for the
/// GPU work submitted so far, as a sync_file the compositor can wait on.
pub const Fence = struct {
    pub const Sync = *anyopaque;
    const sync_native_fence: u32 = 0x3144;

    CreateSyncKHR: *const fn (Egl.Display, u32, [*]const i32) callconv(.c) ?Sync,
    DestroySyncKHR: *const fn (Egl.Display, Sync) callconv(.c) u32,
    DupNativeFenceFDANDROID: *const fn (Egl.Display, Sync) callconv(.c) i32,
};

/// Loads `T`'s function pointers from `lib`, each as `prefix ++ field name`.
fn loadTable(comptime T: type, lib: *std.DynLib, comptime prefix: []const u8) Error!T {
    var t: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        @field(t, f.name) = lib.lookup(f.type, prefix ++ f.name) orelse return error.SymbolMissing;
    }
    return t;
}

/// A render node, a GBM device on it, and a surfaceless GLES context.
pub const Device = struct {
    fd: linux.fd_t,
    gbm_lib: std.DynLib,
    egl_lib: std.DynLib,
    gbm: Gbm,
    egl: Egl,
    gl: Gl,
    gbm_device: *Gbm.Handle,
    display: Egl.Display,
    context: Egl.Context,
    /// Null when the driver has no native fences: frames then wait for the
    /// GPU with `glFinish`.
    fence: ?Fence,

    /// Opens `path` (a /dev/dri/renderD* node) and makes a GLES context current.
    pub fn open(path: [:0]const u8) Error!Device {
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.DeviceFailed;
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);

        var gbm_lib = std.DynLib.open("libgbm.so.1") catch return error.LibraryNotFound;
        errdefer gbm_lib.close();
        var egl_lib = std.DynLib.open("libEGL.so.1") catch return error.LibraryNotFound;
        errdefer egl_lib.close();
        const gbm = try loadTable(Gbm, &gbm_lib, "gbm_");
        const egl = try loadTable(Egl, &egl_lib, "egl");

        const gbm_device = gbm.create_device(fd) orelse return error.DeviceFailed;
        errdefer gbm.device_destroy(gbm_device);
        const display = egl.GetPlatformDisplay(Egl.platform_gbm, gbm_device, null) orelse return error.EglFailed;
        if (egl.Initialize(display, null, null) == 0) return error.EglFailed;
        errdefer _ = egl.Terminate(display);

        const exts = std.mem.span(egl.QueryString(display, Egl.extensions) orelse return error.EglFailed);
        for ([_][]const u8{ "EGL_KHR_surfaceless_context", "EGL_KHR_no_config_context", "EGL_EXT_image_dma_buf_import", "EGL_EXT_image_dma_buf_import_modifiers" }) |ext| {
            if (!hasExtension(exts, ext)) {
                std.log.err("EGL lacks {s}", .{ext});
                return error.MissingExtension;
            }
        }
        if (egl.BindAPI(Egl.opengl_es_api) == 0) return error.EglFailed;
        const attrs = [_]i32{ Egl.context_major_version, 3, Egl.none };
        const context = egl.CreateContext(display, null, null, &attrs) orelse return error.EglFailed;
        errdefer _ = egl.DestroyContext(display, context);
        if (egl.MakeCurrent(display, null, null, context) == 0) return error.EglFailed;

        var gl: Gl = undefined;
        inline for (@typeInfo(Gl).@"struct".fields) |f| {
            const sym = egl.GetProcAddress("gl" ++ f.name) orelse return error.SymbolMissing;
            @field(gl, f.name) = @ptrCast(@alignCast(sym)); // zsnag:ok — signature declared from gl2.h / gl2ext.h; function addresses are aligned
        }
        var fence: ?Fence = null;
        if (hasExtension(exts, "EGL_ANDROID_native_fence_sync") and hasExtension(exts, "EGL_KHR_fence_sync")) {
            var f: Fence = undefined;
            var complete = true;
            inline for (@typeInfo(Fence).@"struct".fields) |field| {
                if (egl.GetProcAddress("egl" ++ field.name)) |sym| {
                    @field(f, field.name) = @ptrCast(@alignCast(sym)); // zsnag:ok — signature from eglext.h; function addresses are aligned
                } else complete = false;
            }
            if (complete) fence = f;
        }
        return .{
            .fence = fence,
            .fd = fd,
            .gbm_lib = gbm_lib,
            .egl_lib = egl_lib,
            .gbm = gbm,
            .egl = egl,
            .gl = gl,
            .gbm_device = gbm_device,
            .display = display,
            .context = context,
        };
    }

    pub fn close(d: *Device) void {
        _ = d.egl.MakeCurrent(d.display, null, null, null);
        _ = d.egl.DestroyContext(d.display, d.context);
        _ = d.egl.Terminate(d.display);
        d.gbm.device_destroy(d.gbm_device);
        d.egl_lib.close();
        d.gbm_lib.close();
        _ = linux.close(d.fd);
    }

    /// Ends a frame's GPU work: the frame's fence as a sync_file (the
    /// caller's to close) once the work is submitted, or null after waiting
    /// for the work to finish, where the driver has no native fences.
    pub fn endFrame(d: *Device) ?linux.fd_t {
        if (d.fence) |f| {
            const attrs = [_]i32{Egl.none};
            if (f.CreateSyncKHR(d.display, Fence.sync_native_fence, &attrs)) |sync| {
                defer _ = f.DestroySyncKHR(d.display, sync);
                // The fence only gets its fd once the work is flushed to the GPU.
                d.gl.Flush();
                const fd = f.DupNativeFenceFDANDROID(d.display, sync);
                if (fd >= 0) return fd;
            }
        }
        d.gl.Finish();
        return null;
    }

    /// For libmpv's OpenGL renderer (`mpv_opengl_init_params.get_proc_address`).
    pub fn procAddress(d: *Device, name: [*:0]const u8) ?*anyopaque {
        return d.egl.GetProcAddress(name);
    }
};

fn hasExtension(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

/// One DMA-BUF render target: a GBM buffer, its EGL image, and a framebuffer
/// that renders into it.
pub const Target = struct {
    bo: *Gbm.Bo,
    /// The DMA-BUF. Owned here; the display side gets duplicates.
    fd: linux.fd_t,
    width: u32,
    height: u32,
    fourcc: u32,
    modifier: u64,
    offset: u32,
    stride: u32,
    image: Egl.Image,
    renderbuffer: u32,
    framebuffer: u32,

    /// Allocates a `width` x `height` buffer. `modifiers` are the ones the
    /// compositor can scan out or sample; empty means linear.
    pub fn create(d: *Device, width: u32, height: u32, fourcc: u32, modifiers: []const u64) Error!Target {
        const bo = try allocate(d, width, height, fourcc, modifiers);
        errdefer d.gbm.bo_destroy(bo);
        const fd = d.gbm.bo_get_fd(bo);
        if (fd < 0) return error.AllocationFailed;
        errdefer _ = linux.close(fd);

        var t: Target = .{
            .bo = bo,
            .fd = fd,
            .width = width,
            .height = height,
            .fourcc = fourcc,
            .modifier = d.gbm.bo_get_modifier(bo),
            .offset = d.gbm.bo_get_offset(bo, 0),
            .stride = d.gbm.bo_get_stride(bo),
            .image = undefined,
            .renderbuffer = 0,
            .framebuffer = 0,
        };
        const attrs = [_]Egl.Attrib{
            Egl.width,                      width,
            Egl.height,                     height,
            Egl.linux_drm_fourcc,           fourcc,
            Egl.dma_buf_plane0_fd,          fd,
            Egl.dma_buf_plane0_offset,      t.offset,
            Egl.dma_buf_plane0_pitch,       t.stride,
            Egl.dma_buf_plane0_modifier_lo, @intCast(t.modifier & 0xffffffff),
            Egl.dma_buf_plane0_modifier_hi, @intCast(t.modifier >> 32),
            Egl.none,
        };
        t.image = d.egl.CreateImage(d.display, null, Egl.linux_dma_buf, null, &attrs) orelse return error.EglFailed;
        errdefer _ = d.egl.DestroyImage(d.display, t.image);

        const gl = &d.gl;
        gl.GenRenderbuffers(1, @ptrCast(&t.renderbuffer));
        gl.BindRenderbuffer(Gl.renderbuffer, t.renderbuffer);
        gl.EGLImageTargetRenderbufferStorageOES(Gl.renderbuffer, t.image);
        gl.GenFramebuffers(1, @ptrCast(&t.framebuffer));
        gl.BindFramebuffer(Gl.framebuffer, t.framebuffer);
        gl.FramebufferRenderbuffer(Gl.framebuffer, Gl.color_attachment0, Gl.renderbuffer, t.renderbuffer);
        if (gl.CheckFramebufferStatus(Gl.framebuffer) != Gl.framebuffer_complete) {
            gl.DeleteFramebuffers(1, @ptrCast(&t.framebuffer));
            gl.DeleteRenderbuffers(1, @ptrCast(&t.renderbuffer));
            return error.FramebufferIncomplete;
        }
        gl.BindFramebuffer(Gl.framebuffer, 0);
        return t;
    }

    /// A single-plane buffer. GBM picks the best of `modifiers`, which is
    /// often a compressed layout with extra planes (AMD DCC); then each
    /// modifier is tried alone, in the compositor's order of preference, and
    /// linear is the last resort.
    fn allocate(d: *Device, width: u32, height: u32, fourcc: u32, modifiers: []const u64) Error!*Gbm.Bo {
        if (modifiers.len > 0) {
            if (d.gbm.bo_create_with_modifiers2(d.gbm_device, width, height, fourcc, modifiers.ptr, @intCast(modifiers.len), Gbm.use_rendering)) |bo| {
                if (d.gbm.bo_get_plane_count(bo) == 1) return bo;
                d.gbm.bo_destroy(bo);
            }
            for (modifiers) |m| {
                const bo = d.gbm.bo_create_with_modifiers2(d.gbm_device, width, height, fourcc, (&m)[0..1].ptr, 1, Gbm.use_rendering) orelse continue;
                if (d.gbm.bo_get_plane_count(bo) == 1) return bo;
                d.gbm.bo_destroy(bo);
            }
        }
        const bo = d.gbm.bo_create(d.gbm_device, width, height, fourcc, Gbm.use_rendering | Gbm.use_linear) orelse return error.AllocationFailed;
        if (d.gbm.bo_get_plane_count(bo) != 1) {
            d.gbm.bo_destroy(bo);
            return error.MultiPlane;
        }
        return bo;
    }

    pub fn destroy(t: *Target, d: *Device) void {
        d.gl.DeleteFramebuffers(1, @ptrCast(&t.framebuffer));
        d.gl.DeleteRenderbuffers(1, @ptrCast(&t.renderbuffer));
        _ = d.egl.DestroyImage(d.display, t.image);
        _ = linux.close(t.fd);
        d.gbm.bo_destroy(t.bo);
    }
};

/// The render node for a DRM device number (`dev_t`, as the compositor's
/// dmabuf feedback reports it). The compositor may name the primary node
/// (card*); rendering needs the render node of the same GPU.
pub fn renderNode(buf: []u8, dev: u64) ?[:0]const u8 {
    const major: u32 = @truncate(((dev >> 32) & 0xfffff000) | ((dev >> 8) & 0xfff));
    const minor: u32 = @truncate(((dev >> 12) & 0xffffff00) | (dev & 0xff));
    // Render nodes are minors 128 and up; a primary node's render node is
    // found through sysfs, next to it.
    if (minor >= 128) return std.fmt.bufPrintSentinel(buf, "/dev/dri/renderD{d}", .{minor}, 0) catch null;
    var dir_buf: [64:0]u8 = undefined;
    const dir_path = std.fmt.bufPrintSentinel(&dir_buf, "/sys/dev/char/{d}:{d}/device/drm", .{ major, minor }, 0) catch return null;
    const rc = linux.open(dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    var ents: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    const n = linux.getdents64(fd, &ents, ents.len);
    if (linux.errno(n) != .SUCCESS) return null;
    var off: usize = 0;
    while (off < n) {
        const ent: *align(1) const linux.dirent64 = @ptrCast(&ents[off]);
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ents[off + @offsetOf(linux.dirent64, "name")])), 0);
        if (std.mem.startsWith(u8, name, "renderD"))
            return std.fmt.bufPrintSentinel(buf, "/dev/dri/{s}", .{name}, 0) catch null;
        off += ent.reclen;
    }
    return null;
}

/// makedev(), as glibc encodes it.
pub fn makedev(major: u32, minor: u32) u64 {
    const ma: u64 = major;
    const mi: u64 = minor;
    return ((ma & 0xfffff000) << 32) | ((ma & 0xfff) << 8) | ((mi & 0xffffff00) << 12) | (mi & 0xff);
}

test renderNode {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/dev/dri/renderD128", renderNode(&buf, makedev(226, 128)).?);
}

test hasExtension {
    try std.testing.expect(hasExtension("EGL_A EGL_B_c EGL_D", "EGL_B_c"));
    try std.testing.expect(!hasExtension("EGL_A EGL_B_cd", "EGL_B_c"));
}
