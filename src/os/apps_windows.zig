// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! zmural as an installed app on Windows, for this user only (no admin
//! rights): a Start menu shortcut, so Start and Search list it as an app,
//! and an entry under HKCU's Uninstall key, so Settings > Apps lists it with
//! an Uninstall button. zmural writes both when it starts and rewrites them
//! when it has moved or been upgraded; `--uninstall` removes them. The
//! Windows counterpart of the Linux app-menu entry (`daemon/desktop_linux.zig`).

const std = @import("std");
const w = @import("win32.zig");

const uninstall_key = w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\zmural");
/// Under %APPDATA%.
const shortcut_path = "Microsoft\\Windows\\Start Menu\\Programs\\zmural.lnk";

pub const App = struct {
    /// zmural.exe, absolute.
    exe: []const u8,
    /// The folder it's in.
    dir: []const u8,
    version: []const u8,
};

pub const Error = error{ RegistryFailed, ShortcutFailed, InvalidWtf8, OutOfMemory };

/// Writes the shortcut and the Uninstall entry unless they're already there
/// for this folder and version. Returns true when it wrote them.
pub fn register(gpa: std.mem.Allocator, io: std.Io, appdata: []const u8, app: App) Error!bool {
    const lnk = try std.fs.path.join(gpa, &.{ appdata, shortcut_path });
    defer gpa.free(lnk);
    var buf: [1800]u8 = undefined; // readValue's 600 UTF-16 units, at worst 3 bytes each
    const current = std.mem.eql(u8, readValue(w.L("InstallLocation"), &buf) orelse "", app.dir) and
        std.mem.eql(u8, readValue(w.L("DisplayVersion"), &buf) orelse "", app.version);
    const have_lnk = if (std.Io.Dir.cwd().access(io, lnk, .{})) |_| true else |_| false;
    if (current and have_lnk) return false;

    try writeShortcut(gpa, lnk, app);

    var key: w.HKEY = undefined;
    if (w.RegCreateKeyExW(w.HKEY_CURRENT_USER, uninstall_key, 0, null, 0, w.KEY_SET_VALUE, null, &key, null) != 0) return error.RegistryFailed;
    defer _ = w.RegCloseKey(key);
    var line: [1100]u8 = undefined;
    try setString(gpa, key, w.L("DisplayName"), "zmural");
    try setString(gpa, key, w.L("DisplayVersion"), app.version);
    try setString(gpa, key, w.L("Publisher"), "AstraLibernis");
    try setString(gpa, key, w.L("DisplayIcon"), std.fmt.bufPrint(&line, "{s},0", .{app.exe}) catch return error.OutOfMemory);
    try setString(gpa, key, w.L("InstallLocation"), app.dir);
    // Settings > Apps asks first, so the window's own question isn't needed;
    // `--from-window` shows the result in a message box.
    try setString(gpa, key, w.L("UninstallString"), std.fmt.bufPrint(&line, "\"{s}\" --uninstall --from-window", .{app.exe}) catch return error.OutOfMemory);
    try setDword(key, w.L("NoModify"), 1);
    try setDword(key, w.L("NoRepair"), 1);
    return true;
}

/// Removes both. Returns what was removed, for the uninstaller's report.
pub fn unregister(gpa: std.mem.Allocator, appdata: []const u8) struct { shortcut: bool, entry: bool } {
    const lnk = std.fs.path.join(gpa, &.{ appdata, shortcut_path }) catch return .{ .shortcut = false, .entry = false };
    defer gpa.free(lnk);
    const lnk_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, lnk) catch return .{ .shortcut = false, .entry = false };
    defer gpa.free(lnk_w);
    return .{
        .shortcut = w.DeleteFileW(lnk_w) != 0,
        .entry = w.RegDeleteKeyW(w.HKEY_CURRENT_USER, uninstall_key) == 0,
    };
}

fn readValue(name: [*:0]const u16, out: []u8) ?[]const u8 {
    var key: w.HKEY = undefined;
    if (w.RegOpenKeyExW(w.HKEY_CURRENT_USER, uninstall_key, 0, w.KEY_QUERY_VALUE, &key) != 0) return null;
    defer _ = w.RegCloseKey(key);
    var data: [600]u16 = undefined;
    var size: w.DWORD = @sizeOf(@TypeOf(data));
    var kind: w.DWORD = 0;
    if (w.RegQueryValueExW(key, name, null, &kind, @ptrCast(&data), &size) != 0 or kind != w.REG_SZ) return null; // zsnag:ok — reads UTF-16 as bytes
    var len = size / 2;
    while (len > 0 and data[len - 1] == 0) len -= 1;
    const n = std.unicode.wtf16LeToWtf8(out, data[0..len]);
    return out[0..n];
}

fn setString(gpa: std.mem.Allocator, key: w.HKEY, name: [*:0]const u16, value: []const u8) Error!void {
    const v = std.unicode.wtf8ToWtf16LeAllocZ(gpa, value) catch |err| return switch (err) {
        error.InvalidWtf8 => error.InvalidWtf8,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer gpa.free(v);
    const bytes: w.DWORD = @intCast((v.len + 1) * 2); // zsnag:ok — a path or a short name
    if (w.RegSetValueExW(key, name, 0, w.REG_SZ, @ptrCast(v.ptr), bytes) != 0) return error.RegistryFailed; // zsnag:ok — REG_SZ data is the UTF-16 buffer as bytes
}

fn setDword(key: w.HKEY, name: [*:0]const u16, value: w.DWORD) Error!void {
    if (w.RegSetValueExW(key, name, 0, w.REG_DWORD, @ptrCast(&value), @sizeOf(w.DWORD)) != 0) return error.RegistryFailed; // zsnag:ok — a DWORD as bytes
}

// ---- the shortcut: IShellLinkW saved through IPersistFile ---------------------

const CLSID_ShellLink: w.GUID = .{ .Data1 = 0x00021401, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IShellLinkW: w.GUID = .{ .Data1 = 0x000214F9, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
const IID_IPersistFile: w.GUID = .{ .Data1 = 0x0000010B, .Data2 = 0, .Data3 = 0, .Data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };

const Object = extern struct { vtbl: [*]const *const anyopaque };

fn method(obj: *Object, comptime index: usize, comptime F: type) *const F {
    return @ptrCast(obj.vtbl[index]);
}

fn release(obj: *Object) void {
    _ = method(obj, 2, fn (*Object) callconv(.winapi) u32)(obj);
}

/// Opens the settings window, starting zmural first if it isn't running.
fn writeShortcut(gpa: std.mem.Allocator, lnk: []const u8, app: App) Error!void {
    const exe = std.unicode.wtf8ToWtf16LeAllocZ(gpa, app.exe) catch return error.InvalidWtf8;
    defer gpa.free(exe);
    const dir = std.unicode.wtf8ToWtf16LeAllocZ(gpa, app.dir) catch return error.InvalidWtf8;
    defer gpa.free(dir);
    const lnk_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, lnk) catch return error.InvalidWtf8;
    defer gpa.free(lnk_w);
    // The Programs folder exists on any account; make sure anyway.
    if (std.fs.path.dirname(lnk)) |parent| {
        const parent_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, parent) catch return error.InvalidWtf8;
        defer gpa.free(parent_w);
        _ = w.CreateDirectoryW(parent_w, null);
    }

    // S_FALSE (already initialised) also needs its CoUninitialize.
    const inited = w.succeeded(w.CoInitializeEx(null, w.COINIT_APARTMENTTHREADED));
    defer if (inited) w.CoUninitialize();
    var link_obj: ?*Object = null;
    if (!w.succeeded(w.CoCreateInstance(&CLSID_ShellLink, null, w.CLSCTX_INPROC_SERVER, &IID_IShellLinkW, @ptrCast(&link_obj)))) return error.ShortcutFailed;
    const link = link_obj.?;
    defer release(link);
    // IShellLinkW: SetDescription (7), SetWorkingDirectory (9), SetArguments (11), SetIconLocation (17), SetPath (20).
    const SetText = fn (*Object, [*:0]const u16) callconv(.winapi) w.HRESULT;
    if (!w.succeeded(method(link, 20, SetText)(link, exe))) return error.ShortcutFailed;
    _ = method(link, 11, SetText)(link, w.L("--settings"));
    _ = method(link, 9, SetText)(link, dir);
    _ = method(link, 7, SetText)(link, w.L("Choose and control your live wallpaper"));
    _ = method(link, 17, fn (*Object, [*:0]const u16, c_int) callconv(.winapi) w.HRESULT)(link, exe, 0);
    // IUnknown::QueryInterface (0), then IPersistFile::Save (6).
    var file_obj: ?*Object = null;
    if (!w.succeeded(method(link, 0, fn (*Object, *const w.GUID, *?*Object) callconv(.winapi) w.HRESULT)(link, &IID_IPersistFile, &file_obj))) return error.ShortcutFailed;
    const file = file_obj.?;
    defer release(file);
    if (!w.succeeded(method(file, 6, fn (*Object, [*:0]const u16, w.BOOL) callconv(.winapi) w.HRESULT)(file, lnk_w, 1))) return error.ShortcutFailed;
}
