// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Who is who (Windows): the current user's SID and session, and the user
//! who owns another process. Used to name the control pipe per user and
//! session, and to check that whoever answers on it really is us.

const std = @import("std");
const w = @import("win32.zig");

/// A copy of a SID (at most SECURITY_MAX_SID_SIZE bytes).
pub const Sid = struct {
    bytes: [68]u8 align(4) = undefined,
    len: usize = 0,

    pub fn eql(a: *const Sid, b: *const Sid) bool {
        return a.len == b.len and std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }

    /// "S-1-5-21-…" into `buf`.
    pub fn format(s: *const Sid, buf: []u8) ?[]const u8 {
        var text: ?[*:0]u16 = null;
        if (w.ConvertSidToStringSidW(@ptrCast(@constCast(&s.bytes)), &text) == 0) return null; // zsnag:ok — read-only use of our own buffer
        const t = text orelse return null;
        defer _ = w.LocalFree(t);
        const n = std.unicode.utf16LeToUtf8(buf, std.mem.span(t)) catch return null;
        return buf[0..n];
    }
};

/// The user that owns `process` (a handle with PROCESS_QUERY_LIMITED_INFORMATION).
pub fn processUser(process: w.HANDLE) ?Sid {
    var token: w.HANDLE = undefined;
    if (w.OpenProcessToken(process, w.TOKEN_QUERY, &token) == 0) return null;
    defer _ = w.CloseHandle(token);
    var buf: [256]u8 align(8) = undefined;
    var len: w.DWORD = 0;
    if (w.GetTokenInformation(token, w.TokenUser, &buf, buf.len, &len) == 0) return null;
    const user: *const w.TOKEN_USER = @ptrCast(&buf); // zsnag:ok — TOKEN_USER is what TokenUser returns
    const sid_len = w.GetLengthSid(user.User.Sid);
    var sid: Sid = .{};
    if (sid_len == 0 or sid_len > sid.bytes.len) return null;
    const src: [*]const u8 = @ptrCast(user.User.Sid); // zsnag:ok — GetLengthSid bytes at this address
    @memcpy(sid.bytes[0..sid_len], src[0..sid_len]);
    sid.len = sid_len;
    return sid;
}

pub fn currentUser() ?Sid {
    return processUser(w.GetCurrentProcess());
}

/// The user that owns process `pid`, if we may ask.
pub fn pidUser(pid: w.DWORD) ?Sid {
    const process = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = w.CloseHandle(process);
    return processUser(process);
}

/// Does process `pid` belong to the current user? Unknown counts as no.
pub fn isOurs(pid: w.DWORD) bool {
    const mine = currentUser() orelse return false;
    const theirs = pidUser(pid) orelse return false;
    return mine.eql(&theirs);
}

/// The Terminal Services session we run in (0 for services).
pub fn sessionId() w.DWORD {
    var id: w.DWORD = 0;
    _ = w.ProcessIdToSessionId(w.GetCurrentProcessId(), &id);
    return id;
}

/// "<SID>-s<session>": unique per user and per session, for naming things
/// only this user in this session should find.
pub fn scope(buf: []u8) ?[]const u8 {
    const sid = currentUser() orelse return null;
    var sid_buf: [192]u8 = undefined;
    const text = sid.format(&sid_buf) orelse return null;
    return std.fmt.bufPrint(buf, "{s}-s{d}", .{ text, sessionId() }) catch null;
}

test "the current process is ours; our scope names the user and session" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expect(isOurs(w.GetCurrentProcessId()));
    var buf: [256]u8 = undefined;
    const s = scope(&buf).?;
    try std.testing.expect(std.mem.startsWith(u8, s, "S-1-"));
    try std.testing.expect(std.mem.find(u8, s, "-s") != null);
    // The System process (pid 4) is not ours (or can't be asked, which counts as no).
    try std.testing.expect(!isOurs(4));
}
