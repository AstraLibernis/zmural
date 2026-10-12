// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The Windows web renderer (`--renderer web`): HTML wallpapers in WebView2.
//!
//! One borderless window per surface, like the other renderers, with a
//! WebView2 controller inside it. All controllers share one WebView2
//! environment (one browser process tree), whose data lives in
//! `%LOCALAPPDATA%\zmural\webview2`.
//!
//! - A local page is served from its own folder under a virtual host,
//!   `https://<hash of the folder>.zmural.example/`, so it can load its own
//!   files (scripts, images, fetch) without `file://` restrictions. Only that
//!   folder (and its subfolders) is visible to it. Each folder is its own
//!   origin, so wallpapers can't read each other's storage.
//! - A web address (`http://` or `https://`) is refused, here and by the
//!   daemon: a wallpaper is a file on this computer.
//! - Paused means suspended: the view is hidden and `TrySuspend` freezes its
//!   timers and rendering (the official API, never a debugger attach).
//! - Web wallpapers are untrusted: no dev tools, context menu, dialogs, new
//!   windows, downloads or permission prompts (camera, microphone, location...).
//! - Every page is offline, and nothing can turn that off: its browser gets
//!   a proxy that doesn't exist (loopback included) and WebRTC may only use
//!   proxied connections, so HTTP, WebSockets and UDP all fail. Its own
//!   files still load (the virtual host never touches the network). It also
//!   can't navigate away from its own origin.
//! - Each wallpaper gets its own browser profile (cookies, storage, cache)
//!   under `%LOCALAPPDATA%\zmural\webview2\<id>`.
//! - Pages get `window.zmural`: their properties, and `property` events
//!   when they change.
//!
//! WebView2 is loaded at runtime from `WebView2Loader.dll` next to the
//! executables (Microsoft, BSD-3-Clause). The WebView2 Runtime itself ships
//! with Windows 11.

const std = @import("std");
const w = @import("../os/win32.zig");
const wv = @import("../os/webview2.zig");
const process = @import("../os/process.zig");
const sdk = @import("renderer.zig");
const proto = @import("../protocol/renderer.zig");
const pipe = @import("../protocol/pipe.zig");
const props_json = @import("../core/properties.zig");

/// Local wallpapers are served from `<16 hex digits>.` + this. `.example` is
/// reserved (RFC 2606), so it can never be a real site.
pub const local_domain = "zmural.example";

const WM_DAEMON = w.WM_APP + 1;
const max_surfaces = 16;
/// COM callbacks can be released from WebView2's threads.
const heap = std.heap.smp_allocator;

const Surface = struct {
    id: proto.SurfaceId,
    hwnd: w.HWND,
    /// Unique for every surface ever created, so a callback that arrives
    /// after its surface was removed finds nothing.
    token: usize,
    controller: ?*wv.ICoreWebView2Controller = null,
    view: ?*wv.ICoreWebView2_8 = null,
    /// The first navigation finished (WebView2 can't suspend before that).
    loaded: bool = false,
};

const State = struct {
    gpa: std.mem.Allocator = undefined,
    session: sdk.Session = undefined,
    instance: ?w.HINSTANCE = null,
    control: ?w.HWND = null,
    surfaces: [max_surfaces]?Surface = @splat(null),
    env: ?*wv.ICoreWebView2Environment = null,
    /// What each view navigates to.
    target: [:0]const u16 = &.{},
    /// The page's folder, mapped to `host`.
    folder: [:0]const u16 = &.{},
    host: [:0]const u16 = &.{},
    /// "https://<host>/": the only place the page may navigate.
    origin: []const u8 = "",
    /// Names this wallpaper's browser profile folder.
    profile: []const u8 = "",
    /// %LOCALAPPDATA%, for the profile folders.
    local_app_data: []const u8 = "",
    /// Property values as JSON literals, by name (owned).
    props: std.array_hash_map.String([]const u8) = .empty,
    playing: bool = false,
    muted: bool = true,
    next_token: usize = 1,
};

var st: State = .{};

/// `args`: what follows `--renderer web` on the command line.
pub fn run(init: std.process.Init, args_in: []const []const u8) !void {
    const arena = init.arena.allocator();
    const args = sdk.parseArgs(args_in) catch |err| {
        std.log.err("renderer web: {s}; usage: --renderer web --ipc <address> --path <wallpaper>", .{@errorName(err)});
        std.process.exit(2);
    };
    st.gpa = init.gpa;

    _ = w.SetProcessDpiAwarenessContext(w.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // WebView2 needs a single-threaded apartment with a message loop.
    if (!w.succeeded(w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED))) return error.ComInitFailed;
    st.instance = w.GetModuleHandleW(null);
    const control_class = w.L("zmural.renderer");
    const surface_class = w.L("zmural.surface");
    if (w.RegisterClassExW(&.{ .lpfnWndProc = controlProc, .hInstance = st.instance, .lpszClassName = control_class }) == 0 or
        // Black behind the page, and while it's hidden for pausing.
        w.RegisterClassExW(&.{ .lpfnWndProc = surfaceProc, .hInstance = st.instance, .lpszClassName = surface_class, .hbrBackground = w.CreateSolidBrush(0) }) == 0)
        return error.RegisterClassFailed;
    st.control = w.CreateWindowExW(0, control_class, null, 0, 0, 0, 0, 0, w.HWND_MESSAGE, null, st.instance, null) orelse
        return error.CreateWindowFailed;

    st.session = sdk.Session.open(st.gpa, args, "surfaces pause mute properties") catch |err| {
        std.log.err("renderer web: cannot reach the daemon at {s}: {s}", .{ args.ipc, @errorName(err) });
        std.process.exit(1);
    };

    const target = navigationTarget(arena, args.path) catch |err| {
        fail("cannot show '{s}': {s}", .{ args.path, @errorName(err) });
        std.process.exit(1);
    };
    st.target = target.url;
    st.folder = target.folder;
    st.host = target.host;
    st.origin = target.origin;
    st.profile = target.profile;
    st.local_app_data = init.environ_map.get("LOCALAPPDATA") orelse {
        fail("LOCALAPPDATA is not set; can't place the browser profile", .{});
        std.process.exit(1);
    };
    // The browser environment starts with `init`: its options depend on it.
    _ = w.CloseHandle(try st.session.startReader(st.control.?, WM_DAEMON));
    st.session.log(.info, "web renderer for '{s}'", .{args.path});

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    // Exiting ends the browser processes too (they're in the daemon's job).
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch "renderer failure (message too long)";
    st.session.send(.{ .failed = .{ .message = text } }) catch {}; // zsnag:ok — best-effort report
}

// ---- what to show ------------------------------------------------------------------

pub const Target = struct {
    url: [:0]const u16,
    folder: [:0]const u16,
    /// The virtual host `folder` is mapped to.
    host: [:0]const u16,
    /// "https://<host>/".
    origin: []const u8,
    /// 16 hex digits naming the browser profile: one per folder.
    profile: []const u8,
};

pub fn isUrl(path: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(path, "https://") or std.ascii.startsWithIgnoreCase(path, "http://");
}

/// A page as `https://<folder hash>.zmural.example/<its name>`, with its
/// folder to be mapped to that host. A web address is refused: the daemon
/// never sends one, and this renderer wouldn't open it if it did.
pub fn navigationTarget(arena: std.mem.Allocator, path: []const u8) !Target {
    if (isUrl(path)) return error.WebAddress;
    const folder = std.fs.path.dirname(path) orelse return error.NotAFullPath;
    // Windows paths ignore case: one folder, one origin.
    var hasher = std.hash.Wyhash.init(0);
    for (folder) |c| hasher.update(&.{std.ascii.toLower(c)});
    const id = try std.fmt.allocPrint(arena, "{x:0>16}", .{hasher.final()});
    const host = try std.fmt.allocPrint(arena, "{s}.{s}", .{ id, local_domain });
    const origin = try std.fmt.allocPrint(arena, "https://{s}/", .{host});
    var url: std.ArrayList(u8) = .empty;
    try url.appendSlice(arena, origin);
    try percentEncode(arena, &url, std.fs.path.basename(path));
    return .{
        .url = try std.unicode.wtf8ToWtf16LeAllocZ(arena, url.items),
        .folder = try std.unicode.wtf8ToWtf16LeAllocZ(arena, folder),
        .host = try std.unicode.wtf8ToWtf16LeAllocZ(arena, host),
        .origin = origin,
        .profile = id,
    };
}

/// Percent-encodes everything but RFC 3986's unreserved characters.
fn percentEncode(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
}

// ---- COM callbacks ------------------------------------------------------------------

/// A COM callback object (a WebView2 `...Handler`) that calls `func(ctx, a, b)`.
/// Reference-counted: created with one reference, which the creator releases
/// once it has handed the object to WebView2.
fn Callback(comptime iid: w.GUID, comptime A: type, comptime B: type, comptime func: fn (usize, A, B) void) type {
    return extern struct {
        vtbl: *const Vtbl,
        refs: u32,
        ctx: usize,

        const Self = @This();
        const Vtbl = extern struct {
            QueryInterface: *const fn (*Self, *const w.GUID, *?*anyopaque) callconv(.winapi) w.HRESULT,
            AddRef: *const fn (*Self) callconv(.winapi) u32,
            Release: *const fn (*Self) callconv(.winapi) u32,
            Invoke: *const fn (*Self, A, B) callconv(.winapi) w.HRESULT,
        };
        const vtable: Vtbl = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release, .Invoke = invoke };

        fn create(ctx: usize) ?*Self {
            const self = heap.create(Self) catch return null;
            self.* = .{ .vtbl = &vtable, .refs = 1, .ctx = ctx };
            return self;
        }

        fn queryInterface(self: *Self, riid: *const w.GUID, out: *?*anyopaque) callconv(.winapi) w.HRESULT {
            if (w.guidEql(riid, &iid) or w.guidEql(riid, &w.IID_IUnknown)) {
                _ = addRef(self);
                out.* = self;
                return w.S_OK;
            }
            out.* = null;
            return w.E_NOINTERFACE;
        }

        fn addRef(self: *Self) callconv(.winapi) u32 {
            return @atomicRmw(u32, &self.refs, .Add, 1, .monotonic) + 1;
        }

        fn release(self: *Self) callconv(.winapi) u32 {
            const left = @atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel) - 1;
            if (left == 0) heap.destroy(self);
            return left;
        }

        fn invoke(self: *Self, a: A, b: B) callconv(.winapi) w.HRESULT {
            func(self.ctx, a, b);
            return w.S_OK;
        }
    };
}

const iids = wv.handler_iid;
const EnvironmentDone = Callback(iids.CreateCoreWebView2EnvironmentCompletedHandler, w.HRESULT, ?*wv.ICoreWebView2Environment, onEnvironment);
const ControllerDone = Callback(iids.CreateCoreWebView2ControllerCompletedHandler, w.HRESULT, ?*wv.ICoreWebView2Controller, onController);
const NavigationStarting = Callback(iids.NavigationStartingEventHandler, ?*anyopaque, ?*wv.ICoreWebView2NavigationStartingEventArgs, onNavigationStarting);
const Navigated = Callback(iids.NavigationCompletedEventHandler, ?*anyopaque, ?*wv.ICoreWebView2NavigationCompletedEventArgs, onNavigated);
const ProcessFailed = Callback(iids.ProcessFailedEventHandler, ?*anyopaque, ?*wv.ICoreWebView2ProcessFailedEventArgs, onProcessFailed);
const NewWindow = Callback(iids.NewWindowRequestedEventHandler, ?*anyopaque, ?*wv.ICoreWebView2NewWindowRequestedEventArgs, onNewWindow);
const Permission = Callback(iids.PermissionRequestedEventHandler, ?*anyopaque, ?*wv.ICoreWebView2PermissionRequestedEventArgs, onPermission);
const Download = Callback(iids.DownloadStartingEventHandler, ?*anyopaque, ?*wv.ICoreWebView2DownloadStartingEventArgs, onDownload);
const Suspended = Callback(iids.TrySuspendCompletedHandler, w.HRESULT, w.BOOL, onSuspended);

/// Queries `obj` for interface `T` (a new reference, or null).
fn query(comptime T: type, obj: anytype) ?*T {
    var out: ?*anyopaque = null;
    if (!w.succeeded(obj.vtbl.QueryInterface(obj, &T.iid, &out))) return null;
    return @ptrCast(@alignCast(out orelse return null)); // zsnag:ok — QueryInterface returned a T for T.iid
}

fn unref(obj: anytype) void {
    _ = obj.vtbl.Release(obj);
}

// ---- environment and views --------------------------------------------------------------

/// Browser options for every web wallpaper.
/// - It may play sound (muted by default) without a click, since nobody
///   clicks a wallpaper.
/// - It is offline: a proxy nobody listens on (port 9, "discard"), used for
///   loopback too, and WebRTC limited to proxied traffic.
const browser_args = "--autoplay-policy=no-user-gesture-required" ++
    " --proxy-server=http://127.0.0.1:9 --proxy-bypass-list=<-loopback> --force-webrtc-ip-handling-policy=disable_non_proxied_udp";

fn startEnvironment() !void {
    const gpa = st.gpa;
    const loader_path = try process.siblingExe(gpa, "WebView2Loader.dll");
    defer gpa.free(loader_path);
    const loader_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, loader_path);
    defer gpa.free(loader_w);
    const loader = w.LoadLibraryW(loader_w) orelse return error.LoaderNotFound;
    const sym = w.GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions") orelse return error.LoaderTooOld;
    const create: wv.CreateEnvironmentFn = @ptrCast(sym); // zsnag:ok — signature from WebView2.h

    _ = w.SetEnvironmentVariableW(w.L("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"), w.L(browser_args));
    const data_path = try std.fs.path.join(gpa, &.{ st.local_app_data, "zmural", "webview2", st.profile });
    defer gpa.free(data_path);
    const data = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, data_path);
    defer gpa.free(data);

    const done = EnvironmentDone.create(0) orelse return error.OutOfMemory;
    defer _ = done.vtbl.Release(done);
    const hr = create(null, data, null, done);
    if (!w.succeeded(hr)) return error.RuntimeNotFound;
}

fn onEnvironment(_: usize, hr: w.HRESULT, env: ?*wv.ICoreWebView2Environment) void {
    const e = env orelse {
        fail("WebView2 could not start (HRESULT 0x{X:0>8}); is the WebView2 Runtime installed?", .{@as(u32, @bitCast(hr))});
        w.PostQuitMessage(0);
        return;
    };
    _ = e.vtbl.AddRef(e);
    st.env = e;
    for (&st.surfaces) |*slot| if (slot.*) |*s| createView(s);
}

fn createView(s: *Surface) void {
    const env = st.env orelse return; // created once the environment is ready
    const done = ControllerDone.create(s.token) orelse return fail("out of memory", .{});
    defer _ = done.vtbl.Release(done);
    const hr = env.vtbl.CreateCoreWebView2Controller(env, s.hwnd, done);
    if (!w.succeeded(hr)) fail("cannot create a web view (HRESULT 0x{X:0>8})", .{@as(u32, @bitCast(hr))});
}

fn onController(token: usize, hr: w.HRESULT, controller: ?*wv.ICoreWebView2Controller) void {
    const c = controller orelse {
        fail("cannot create a web view (HRESULT 0x{X:0>8})", .{@as(u32, @bitCast(hr))});
        return;
    };
    const s = byToken(token) orelse {
        // Its surface went away meanwhile.
        _ = c.vtbl.Close(c);
        return;
    };
    _ = c.vtbl.AddRef(c);
    s.controller = c;
    setUpView(s) catch |err| fail("cannot set up the web view: {s}", .{@errorName(err)});
}

fn setUpView(s: *Surface) !void {
    const c = s.controller.?;
    if (query(wv.ICoreWebView2Controller2, c)) |c2| {
        defer unref(c2);
        // Black until the page draws, instead of a white flash.
        _ = c2.vtbl.put_DefaultBackgroundColor(c2, .{ .A = 255, .R = 0, .G = 0, .B = 0 });
    }
    fitToWindow(s);

    var core: ?*wv.ICoreWebView2 = null;
    if (!w.succeeded(c.vtbl.get_CoreWebView2(c, &core))) return error.NoCoreWebView2;
    const base = core orelse return error.NoCoreWebView2;
    defer unref(base);
    // _8 brings muting; its bases bring suspend (_3) and download blocking (_4).
    const view = query(wv.ICoreWebView2_8, base) orelse return error.RuntimeTooOld;
    s.view = view;

    var settings: ?*wv.ICoreWebView2Settings = null;
    if (w.succeeded(view.vtbl.get_Settings(view, &settings))) if (settings) |set| {
        defer unref(set);
        _ = set.vtbl.put_AreDevToolsEnabled(set, 0);
        _ = set.vtbl.put_AreDefaultContextMenusEnabled(set, 0);
        _ = set.vtbl.put_AreDefaultScriptDialogsEnabled(set, 0);
        _ = set.vtbl.put_IsStatusBarEnabled(set, 0);
        _ = set.vtbl.put_IsZoomControlEnabled(set, 0);
        _ = set.vtbl.put_AreHostObjectsAllowed(set, 0);
    };

    var token: i64 = 0;
    // The page stays on its own origin, and gets the zmural API. Without the
    // handler it could navigate anywhere, so no handler means no page.
    const stay = NavigationStarting.create(s.token) orelse return error.OutOfMemory;
    defer _ = stay.vtbl.Release(stay);
    if (!w.succeeded(view.vtbl.add_NavigationStarting(view, stay, &token))) return error.NavigationLockFailed;
    const script = try apiScript(st.gpa);
    defer st.gpa.free(script);
    _ = view.vtbl.AddScriptToExecuteOnDocumentCreated(view, script, null);
    if (Navigated.create(s.token)) |h| {
        defer _ = h.vtbl.Release(h);
        _ = view.vtbl.add_NavigationCompleted(view, h, &token);
    }
    if (ProcessFailed.create(s.token)) |h| {
        defer _ = h.vtbl.Release(h);
        _ = view.vtbl.add_ProcessFailed(view, h, &token);
    }
    if (NewWindow.create(s.token)) |h| {
        defer _ = h.vtbl.Release(h);
        _ = view.vtbl.add_NewWindowRequested(view, h, &token);
    }
    if (Permission.create(s.token)) |h| {
        defer _ = h.vtbl.Release(h);
        _ = view.vtbl.add_PermissionRequested(view, h, &token);
    }
    if (Download.create(s.token)) |h| {
        defer _ = h.vtbl.Release(h);
        _ = view.vtbl.add_DownloadStarting(view, h, &token);
    }

    _ = view.vtbl.put_IsMuted(view, @intFromBool(st.muted));
    const hr = view.vtbl.SetVirtualHostNameToFolderMapping(view, st.host, st.folder, host_access_deny_cors);
    if (!w.succeeded(hr)) return error.FolderMappingFailed;
    if (!w.succeeded(view.vtbl.Navigate(view, st.target))) return error.NavigateFailed;
    applyPlaying(s);
}

/// COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS: the folder is visible to
/// pages on its own host only.
const host_access_deny_cors = 2;
/// COREWEBVIEW2_PERMISSION_STATE_DENY.
const permission_deny = 2;
/// COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED.
const web_error_operation_canceled = 14;

fn closeView(s: *Surface) void {
    if (s.view) |v| unref(v);
    s.view = null;
    if (s.controller) |c| {
        _ = c.vtbl.Close(c);
        unref(c);
    }
    s.controller = null;
}

fn fitToWindow(s: *Surface) void {
    const c = s.controller orelse return;
    var r: w.RECT = undefined;
    if (w.GetClientRect(s.hwnd, &r) != 0) _ = c.vtbl.put_Bounds(c, r);
}

/// Playing: resumed and visible. Paused: hidden, then suspended (WebView2
/// only suspends a hidden view).
fn applyPlaying(s: *Surface) void {
    const c = s.controller orelse return;
    const v = s.view orelse return;
    if (st.playing) {
        _ = v.vtbl.Resume(v);
        _ = c.vtbl.put_IsVisible(c, 1);
        return;
    }
    _ = c.vtbl.put_IsVisible(c, 0);
    if (!s.loaded) return; // suspended once it has loaded (onNavigated)
    const done = Suspended.create(s.token) orelse return;
    defer _ = done.vtbl.Release(done);
    _ = v.vtbl.TrySuspend(v, done);
}

fn onSuspended(token: usize, hr: w.HRESULT, ok: w.BOOL) void {
    const s = byToken(token) orelse return;
    if (!w.succeeded(hr) or ok == 0) st.session.log(.warn, "surface {d}: the page could not be suspended; it is hidden instead", .{s.id});
}

fn onNavigated(token: usize, _: ?*anyopaque, args: ?*wv.ICoreWebView2NavigationCompletedEventArgs) void {
    const s = byToken(token) orelse return;
    const a = args orelse return;
    var ok: w.BOOL = 1;
    _ = a.vtbl.get_IsSuccess(a, &ok);
    if (!s.loaded) {
        s.loaded = true;
        if (!st.playing) applyPlaying(s); // paused before it loaded: suspend it now
    }
    // Values that changed while the page was loading.
    postAllProperties(s);
    if (ok != 0) return st.session.log(.info, "surface {d}: page loaded", .{s.id});
    var status: i32 = 0;
    _ = a.vtbl.get_WebErrorStatus(a, &status);
    if (status == web_error_operation_canceled) return; // we blocked it (onNavigationStarting)
    st.session.log(.warn, "surface {d}: the page failed to load (web error status {d})", .{ s.id, status });
}

fn onProcessFailed(_: usize, _: ?*anyopaque, args: ?*wv.ICoreWebView2ProcessFailedEventArgs) void {
    const a = args orelse return;
    var kind: i32 = 0;
    _ = a.vtbl.get_ProcessFailedKind(a, &kind);
    switch (kind) {
        // The browser or the page's renderer died or hung: exit, and let the
        // daemon restart us (with its crash backoff).
        0, 1, 2 => {
            fail("the web page's browser process failed (kind {d})", .{kind});
            w.PostQuitMessage(1);
        },
        // Helper processes (GPU, utility...) are restarted by WebView2 itself.
        else => st.session.log(.warn, "a WebView2 helper process exited (kind {d}); it restarts by itself", .{kind}),
    }
}

/// A page may only move within its own origin.
fn onNavigationStarting(_: usize, _: ?*anyopaque, args: ?*wv.ICoreWebView2NavigationStartingEventArgs) void {
    const a = args orelse return;
    var uri_w: ?[*:0]u16 = null;
    if (!w.succeeded(a.vtbl.get_Uri(a, &uri_w))) return;
    const raw = uri_w orelse return;
    defer w.CoTaskMemFree(raw);
    var buf: [2048]u8 = undefined;
    const units = std.mem.span(raw);
    const allowed = units.len <= buf.len / 3 and
        std.ascii.startsWithIgnoreCase(buf[0..std.unicode.wtf16LeToWtf8(&buf, units)], st.origin);
    if (!allowed) {
        _ = a.vtbl.put_Cancel(a, 1);
        st.session.log(.warn, "blocked the page from leaving its own folder", .{});
    }
}

fn onNewWindow(_: usize, _: ?*anyopaque, args: ?*wv.ICoreWebView2NewWindowRequestedEventArgs) void {
    const a = args orelse return;
    _ = a.vtbl.put_Handled(a, 1); // handled = no window
}

fn onPermission(_: usize, _: ?*anyopaque, args: ?*wv.ICoreWebView2PermissionRequestedEventArgs) void {
    const a = args orelse return;
    _ = a.vtbl.put_State(a, permission_deny);
}

fn onDownload(_: usize, _: ?*anyopaque, args: ?*wv.ICoreWebView2DownloadStartingEventArgs) void {
    const a = args orelse return;
    _ = a.vtbl.put_Cancel(a, 1);
}

fn byToken(token: usize) ?*Surface {
    for (&st.surfaces) |*slot| if (slot.*) |*s| if (s.token == token) return s;
    return null;
}

// ---- daemon commands ------------------------------------------------------------------

fn handle(cmd: proto.ToRenderer) void {
    switch (cmd) {
        .init => |i| {
            st.muted = i.muted;
            if (st.env == null) startEnvironment() catch |err| {
                fail("WebView2 could not start ({s}); zmural needs WebView2Loader.dll next to its executables and the WebView2 Runtime (part of Windows 11)", .{@errorName(err)});
                w.PostQuitMessage(1);
            };
        },
        .set_property => |p| setProperty(p.name, p.json),
        .add_surface => |s| addSurface(s),
        .remove_surface => |s| removeSurface(s.surface),
        .play => setPlaying(true),
        .pause => setPlaying(false),
        // WebView2 can mute a page but not set its volume.
        .set_volume => |v| {
            st.muted = v.muted;
            for (st.surfaces) |slot| if (slot) |s| if (s.view) |view| {
                _ = view.vtbl.put_IsMuted(view, @intFromBool(st.muted));
            };
        },
        .stop => w.PostQuitMessage(0),
        .release => {}, // Linux only
    }
}

fn setProperty(name: []const u8, json: []const u8) void {
    const gpa = st.gpa;
    const value = gpa.dupe(u8, json) catch return;
    const gop = st.props.getOrPut(gpa, name) catch {
        gpa.free(value);
        return;
    };
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, name) catch {
            _ = st.props.pop();
            gpa.free(value);
            return;
        };
    }
    gop.value_ptr.* = value;
    for (&st.surfaces) |*slot| if (slot.*) |*s| if (s.loaded) postProperty(s, name, value);
}

/// `{"type":"property","name":…,"value":…}` to one page.
fn postProperty(s: *Surface, name: []const u8, json: []const u8) void {
    const v = s.view orelse return;
    var out: std.Io.Writer.Allocating = .init(st.gpa);
    defer out.deinit();
    out.writer.writeAll("{\"type\":\"property\",\"name\":") catch return;
    props_json.writeJsonString(&out.writer, name) catch return;
    out.writer.print(",\"value\":{s}}}", .{json}) catch return;
    sendJson(v, out.written());
}

fn postAllProperties(s: *Surface) void {
    const v = s.view orelse return;
    var out: std.Io.Writer.Allocating = .init(st.gpa);
    defer out.deinit();
    out.writer.writeAll("{\"type\":\"properties\",\"values\":") catch return;
    writeValues(&out.writer) catch return;
    out.writer.writeAll("}") catch return;
    sendJson(v, out.written());
}

fn writeValues(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeByte('{');
    var it = st.props.iterator();
    var first = true;
    while (it.next()) |e| {
        if (!first) try out.writeByte(',');
        first = false;
        try props_json.writeJsonString(out, e.key_ptr.*);
        try out.print(":{s}", .{e.value_ptr.*});
    }
    try out.writeByte('}');
}

fn sendJson(v: *wv.ICoreWebView2_8, json: []const u8) void {
    const text = std.unicode.wtf8ToWtf16LeAllocZ(st.gpa, json) catch return;
    defer st.gpa.free(text);
    _ = v.vtbl.PostWebMessageAsJson(v, text);
}

/// The page-side API, run before any of the page's own scripts. Values live
/// in `window.zmural.properties`; `window.zmural.on("property", fn)` hears
/// about changes as `{ name, value }`.
const api_js_head =
    \\(() => {
    \\  if (window.zmural) return;
    \\  const properties = Object.assign(Object.create(null),
;
const api_js_tail =
    \\);
    \\  const listeners = Object.create(null);
    \\  const emit = (type, detail) => {
    \\    for (const fn of listeners[type] || []) { try { fn(detail); } catch (e) { console.error(e); } }
    \\  };
    \\  const api = Object.freeze({
    \\    version: 1,
    \\    properties,
    \\    on(type, fn) { if (typeof fn === "function") (listeners[type] ||= []).push(fn); },
    \\    off(type, fn) { if (listeners[type]) listeners[type] = listeners[type].filter((f) => f !== fn); },
    \\  });
    \\  Object.defineProperty(window, "zmural", { value: api });
    \\  const set = (name, value) => {
    \\    if (Object.is(properties[name], value)) return;
    \\    properties[name] = value;
    \\    emit("property", { name, value });
    \\  };
    \\  window.chrome?.webview?.addEventListener("message", (e) => {
    \\    const m = e.data;
    \\    if (!m || typeof m !== "object") return;
    \\    if (m.type === "property" && typeof m.name === "string") set(m.name, m.value);
    \\    if (m.type === "properties" && m.values && typeof m.values === "object") {
    \\      for (const [name, value] of Object.entries(m.values)) set(name, value);
    \\    }
    \\  });
    \\})();
;

/// The API script with today's values built in (UTF-16, owned).
fn apiScript(gpa: std.mem.Allocator) ![:0]u16 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll(api_js_head);
    try writeValues(&out.writer);
    try out.writer.writeAll(api_js_tail);
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, out.written());
}

fn setPlaying(playing: bool) void {
    if (playing == st.playing) return;
    st.playing = playing;
    for (&st.surfaces) |*slot| if (slot.*) |*s| applyPlaying(s);
}

fn addSurface(a: proto.AddSurface) void {
    removeSurface(a.surface);
    const slot = for (&st.surfaces) |*slot| {
        if (slot.* == null) break slot;
    } else {
        st.session.log(.warn, "too many surfaces; ignoring surface {d}", .{a.surface});
        return;
    };
    const hwnd = w.CreateWindowExW(
        w.WS_EX_TOOLWINDOW | w.WS_EX_NOACTIVATE,
        w.L("zmural.surface"),
        w.L("zmural wallpaper"),
        w.WS_POPUP,
        -32000,
        -32000,
        std.math.cast(c_int, a.width) orelse 0,
        std.math.cast(c_int, a.height) orelse 0,
        null,
        null,
        st.instance,
        null,
    ) orelse {
        st.session.log(.err, "cannot create a window for surface {d} (win32 error {d})", .{ a.surface, w.GetLastError() });
        return;
    };
    slot.* = .{ .id = a.surface, .hwnd = hwnd, .token = st.next_token };
    st.next_token += 1;
    st.session.send(.{ .window = .{ .surface = a.surface, .handle = @intFromPtr(hwnd) } }) catch {
        w.PostQuitMessage(0);
        return;
    };
    createView(&slot.*.?);
}

fn removeSurface(id: proto.SurfaceId) void {
    for (&st.surfaces) |*slot| {
        const s = if (slot.*) |*s| s else continue;
        if (s.id != id) continue;
        closeView(s);
        const hwnd = s.hwnd;
        slot.* = null;
        if (w.IsWindow(hwnd) != 0) _ = w.DestroyWindow(hwnd);
    }
}

// ---- window procedures ------------------------------------------------------------------

fn controlProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        WM_DAEMON => {
            // The daemon's end closed: a renderer never outlives its daemon.
            const in = switch (pipe.Notice.fromLparam(lp)) {
                .frame => |f| f,
                .ended => {
                    w.PostQuitMessage(0);
                    return 0;
                },
                .connected => return 0,
            };
            defer in.destroy();
            const cmd = in.frame().decode(proto.ToRenderer) catch |err| {
                st.session.log(.warn, "unreadable command (opcode {d}): {s}", .{ in.opcode, @errorName(err) });
                return 0;
            };
            handle(cmd);
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

fn surfaceProc(hwnd: w.HWND, msg: w.UINT, wp: w.WPARAM, lp: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_SIZE => {
            for (&st.surfaces) |*slot| if (slot.*) |*s| if (s.hwnd == hwnd) fitToWindow(s);
            return 0;
        },
        w.WM_DESTROY => {
            // Destroyed from outside too (Explorer restarting takes its children
            // with it); the daemon will add the surface again.
            for (&st.surfaces) |*slot| if (slot.*) |*s| if (s.hwnd == hwnd) {
                closeView(s);
                slot.* = null;
            };
            return 0;
        },
        else => return w.DefWindowProcW(hwnd, msg, wp, lp),
    }
}

test navigationTarget {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest; // Windows paths
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;

    const local = try navigationTarget(a, "C:\\wp\\my wallpaper\\index #1.html");
    const url_text = buf[0..std.unicode.wtf16LeToWtf8(&buf, local.url)];
    try std.testing.expect(std.mem.startsWith(u8, url_text, "https://"));
    try std.testing.expect(std.mem.endsWith(u8, url_text, ".zmural.example/index%20%231.html"));
    try std.testing.expectEqualStrings("C:\\wp\\my wallpaper", buf[0..std.unicode.wtf16LeToWtf8(&buf, local.folder)]);

    // One origin per folder (ignoring case); different folders never share one.
    const same = try navigationTarget(a, "c:\\WP\\My Wallpaper\\other.html");
    const other = try navigationTarget(a, "C:\\wp\\another\\index.html");
    try std.testing.expectEqualSlices(u16, local.host, same.host);
    try std.testing.expect(!std.mem.eql(u16, local.host, other.host));

    try std.testing.expectError(error.WebAddress, navigationTarget(a, "https://www.shadertoy.com/embed/abc"));
    try std.testing.expectError(error.WebAddress, navigationTarget(a, "HTTP://127.0.0.1/"));
    try std.testing.expect(isUrl("HTTP://x"));
    try std.testing.expect(!isUrl("C:\\http\\a.html"));
}
