// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Start with Windows: a value named "zmural" under the current user's
//! `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` key. No admin rights,
//! and it only affects this user. On from the first run, as on Linux.
//!
//! Off keeps the Run value and marks it disabled under `...\Explorer\
//! StartupApproved\Run`, Windows' own record of startup apps the user turned
//! off (Task Manager's Startup apps and Settings > Apps > Startup write the
//! same). So "off" is remembered, like Linux's `Hidden=true`, and a switch
//! made in Windows' own settings is what zmural reads too. Only the
//! uninstaller removes both values.

const std = @import("std");
const w = @import("win32.zig");

const run_key = w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const approved_key = w.L("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run");
const value_name = w.L("zmural");

pub const State = enum {
    /// No Run value: never set up (or uninstalled).
    unset,
    on,
    /// The Run value is there, and Windows' StartupApproved says disabled.
    off,
};

pub const Error = error{ RegistryFailed, PathTooLong, InvalidUtf8 };

/// Writes the Run value: `exe` (an absolute path), quoted.
fn writeRun(exe: []const u8) Error!void {
    var cmd: [600:0]u16 = undefined;
    // Quoted, so a path with spaces still works.
    const quoted_len = std.unicode.calcUtf16LeLen(exe) catch return error.InvalidUtf8;
    if (quoted_len + 3 > cmd.len) return error.PathTooLong;
    cmd[0] = '"';
    const n = std.unicode.utf8ToUtf16Le(cmd[1..], exe) catch return error.InvalidUtf8;
    cmd[1 + n] = '"';
    cmd[2 + n] = 0;
    const key = try openRun(w.KEY_SET_VALUE);
    defer _ = w.RegCloseKey(key);
    const bytes: w.DWORD = @intCast((n + 3) * 2); // zsnag:ok — bounded by cmd.len
    if (w.RegSetValueExW(key, value_name, 0, w.REG_SZ, @ptrCast(&cmd), bytes) != 0) return error.RegistryFailed; // zsnag:ok — REG_SZ data is the UTF-16 buffer as bytes
}

/// Registers `exe` and clears a "disabled" mark Windows may hold for it.
pub fn enable(exe: []const u8) Error!void {
    try writeRun(exe);
    try deleteApproved();
}

/// Off, remembered: the Run value stays (so a later start doesn't take it for
/// a first one) and is marked disabled, as Windows marks it.
pub fn disable() Error!void {
    var key: w.HKEY = undefined;
    if (w.RegCreateKeyExW(w.HKEY_CURRENT_USER, approved_key, 0, null, 0, w.KEY_SET_VALUE, null, &key, null) != 0) return error.RegistryFailed;
    defer _ = w.RegCloseKey(key);
    var ft: w.FILETIME = undefined;
    w.GetSystemTimeAsFileTime(&ft);
    const data = disabledRecord(ft.value());
    if (w.RegSetValueExW(key, value_name, 0, w.REG_BINARY, &data, data.len) != 0) return error.RegistryFailed;
}

/// Removes both values (the uninstaller). True if there was a Run value.
pub fn remove() Error!bool {
    try deleteApproved();
    const key = try openRun(w.KEY_SET_VALUE);
    defer _ = w.RegCloseKey(key);
    const rc = w.RegDeleteValueW(key, value_name);
    if (rc == w.ERROR_FILE_NOT_FOUND) return false;
    if (rc != 0) return error.RegistryFailed;
    return true;
}

pub fn state() State {
    var buf: [2048]u8 = undefined;
    if (command(&buf) == null) return .unset;
    return if (approvedDisabled()) .off else .on;
}

/// The registered command line, if zmural starts with Windows.
pub fn status(buf: []u8) ?[]const u8 {
    const cmd = command(buf) orelse return null;
    return if (approvedDisabled()) null else cmd;
}

/// The Run value's command line, whether or not it is disabled.
pub fn command(buf: []u8) ?[]const u8 {
    const key = openRun(w.KEY_QUERY_VALUE) catch return null;
    defer _ = w.RegCloseKey(key);
    var data: [600]u16 = undefined;
    var size: w.DWORD = @sizeOf(@TypeOf(data));
    var kind: w.DWORD = 0;
    if (w.RegQueryValueExW(key, value_name, null, &kind, @ptrCast(&data), &size) != 0 or kind != w.REG_SZ) return null; // zsnag:ok — reads UTF-16 as bytes
    var len = size / 2;
    while (len > 0 and data[len - 1] == 0) len -= 1;
    const n = std.unicode.utf16LeToUtf8(buf, data[0..len]) catch return null;
    return buf[0..n];
}

fn approvedDisabled() bool {
    var key: w.HKEY = undefined;
    if (w.RegOpenKeyExW(w.HKEY_CURRENT_USER, approved_key, 0, w.KEY_QUERY_VALUE, &key) != 0) return false;
    defer _ = w.RegCloseKey(key);
    var data: [64]u8 = undefined;
    var size: w.DWORD = data.len;
    var kind: w.DWORD = 0;
    if (w.RegQueryValueExW(key, value_name, null, &kind, &data, &size) != 0 or kind != w.REG_BINARY) return false;
    return isDisabled(data[0..@min(size, data.len)]);
}

fn deleteApproved() Error!void {
    var key: w.HKEY = undefined;
    if (w.RegOpenKeyExW(w.HKEY_CURRENT_USER, approved_key, 0, w.KEY_SET_VALUE, &key) != 0) return; // no key: nothing marked
    defer _ = w.RegCloseKey(key);
    const rc = w.RegDeleteValueW(key, value_name);
    if (rc != 0 and rc != w.ERROR_FILE_NOT_FOUND) return error.RegistryFailed;
}

/// A StartupApproved record: its first byte is even (2, or 6) while enabled
/// and odd (3, or 7) once the user turned it off; a 12-byte record also holds
/// when, as a FILETIME.
fn isDisabled(record: []const u8) bool {
    return record.len > 0 and record[0] & 1 == 1;
}

fn disabledRecord(filetime: u64) [12]u8 {
    var r: [12]u8 = @splat(0);
    r[0] = 3;
    std.mem.writeInt(u64, r[4..12], filetime, .little);
    return r;
}

fn openRun(access: w.DWORD) Error!w.HKEY {
    var key: w.HKEY = undefined;
    if (w.RegOpenKeyExW(w.HKEY_CURRENT_USER, run_key, 0, access, &key) != 0) return error.RegistryFailed;
    return key;
}

test "StartupApproved records: odd is off, even is on" {
    try std.testing.expect(!isDisabled(&.{}));
    try std.testing.expect(!isDisabled(&.{ 2, 0, 0, 0 }));
    try std.testing.expect(!isDisabled(&.{ 6, 0, 0, 0 }));
    try std.testing.expect(isDisabled(&.{ 3, 0, 0, 0 }));
    try std.testing.expect(isDisabled(&.{ 7, 0, 0, 0 }));
    const r = disabledRecord(0x01DC_1234_5678_9ABC);
    try std.testing.expect(isDisabled(&r));
    try std.testing.expectEqual(@as(u64, 0x01DC_1234_5678_9ABC), std.mem.readInt(u64, r[4..12], .little));
}
