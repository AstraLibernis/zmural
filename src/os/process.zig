// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Child processes (Windows): spawning with a correctly quoted command line,
//! and a kill-on-close Job Object so the kernel reaps every renderer the
//! moment the daemon dies, however it dies.

const std = @import("std");
const w = @import("win32.zig");

pub const Error = error{ SpawnFailed, JobFailed, OutOfMemory, InvalidUtf8 };

pub const Child = struct {
    process: w.HANDLE,
    pid: w.DWORD,

    /// Non-blocking: has it exited?
    pub fn hasExited(c: Child) bool {
        return w.WaitForSingleObject(c.process, 0) == w.WAIT_OBJECT_0;
    }

    pub fn kill(c: Child) void {
        _ = w.TerminateProcess(c.process, 1);
    }

    pub fn close(c: Child) void {
        _ = w.CloseHandle(c.process);
    }
};

pub const Options = struct {
    /// Assign to this job before the child runs a single instruction.
    job: ?Job = null,
};

/// Starts `exe` (an absolute path) with `args`. The child shares our console
/// if we have one; without one it gets none (no console window pops up).
pub fn spawn(gpa: std.mem.Allocator, exe: []const u8, args: []const []const u8, opts: Options) Error!Child {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try appendQuoted(gpa, &line, exe);
    for (args) |a| {
        try line.append(gpa, ' ');
        try appendQuoted(gpa, &line, a);
    }
    // Windows paths are WTF-8 (unpaired surrogates are legal in file names).
    const exe_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, exe) catch |e| return mapUtf(e);
    defer gpa.free(exe_w);
    const line_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, line.items) catch |e| return mapUtf(e);
    defer gpa.free(line_w);

    var si: w.STARTUPINFOW = .{};
    var pi: w.PROCESS_INFORMATION = undefined;
    const flags = w.CREATE_SUSPENDED | w.CREATE_UNICODE_ENVIRONMENT | (if (w.GetConsoleWindow() == null) w.CREATE_NO_WINDOW else 0);
    if (w.CreateProcessW(exe_w, line_w, null, null, 0, flags, null, null, &si, &pi) == 0)
        return error.SpawnFailed;
    defer _ = w.CloseHandle(pi.hThread);

    if (opts.job) |job| {
        if (w.AssignProcessToJobObject(job.handle, pi.hProcess) == 0) {
            _ = w.TerminateProcess(pi.hProcess, 1);
            _ = w.CloseHandle(pi.hProcess);
            return error.JobFailed;
        }
    }
    _ = w.ResumeThread(pi.hThread);
    return .{ .process = pi.hProcess, .pid = pi.dwProcessId };
}

fn mapUtf(e: error{ InvalidWtf8, OutOfMemory }) Error {
    return switch (e) {
        error.InvalidWtf8 => error.InvalidUtf8,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Quotes one argument so the MSVC runtime (and Zig's own argv parser) reads
/// it back verbatim: backslashes are literal except before a double quote.
pub fn appendQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    const needs = arg.len == 0 or std.mem.findAny(u8, arg, " \t\n\x0b\"") != null;
    if (!needs) return out.appendSlice(gpa, arg);
    try out.append(gpa, '"');
    var backslashes: usize = 0;
    for (arg) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        if (c == '"') {
            try out.appendNTimes(gpa, '\\', backslashes * 2 + 1);
        } else {
            try out.appendNTimes(gpa, '\\', backslashes);
        }
        backslashes = 0;
        try out.append(gpa, c);
    }
    try out.appendNTimes(gpa, '\\', backslashes * 2);
    try out.append(gpa, '"');
}

/// A Job Object that kills every process in it when its last handle closes,
/// including when the owning process crashes or is force-killed.
///
/// `ui_limits` can also fence renderers off from the rest of the session:
/// mpv renderers decode untrusted files, so their job forbids the clipboard,
/// system settings and display modes, logging off and switching desktops
/// (`renderer_ui_limits`). Web renderers get none: Chromium's sandbox won't
/// start inside a job with UI limits, and sandboxes pages itself.
pub const Job = struct {
    handle: w.HANDLE,

    /// The UI limits for mpv renderers.
    pub const renderer_ui_limits: w.DWORD = w.JOB_OBJECT_UILIMIT_DESKTOP |
        w.JOB_OBJECT_UILIMIT_DISPLAYSETTINGS | w.JOB_OBJECT_UILIMIT_EXITWINDOWS | w.JOB_OBJECT_UILIMIT_GLOBALATOMS |
        w.JOB_OBJECT_UILIMIT_READCLIPBOARD | w.JOB_OBJECT_UILIMIT_WRITECLIPBOARD | w.JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS;

    pub fn init(ui_limits: w.DWORD) Error!Job {
        const handle = w.CreateJobObjectW(null, null) orelse return error.JobFailed;
        errdefer _ = w.CloseHandle(handle);
        var info: w.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
        info.BasicLimitInformation.LimitFlags = w.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (w.SetInformationJobObject(handle, w.JobObjectExtendedLimitInformation, &info, @sizeOf(@TypeOf(info))) == 0)
            return error.JobFailed;
        var ui: w.JOBOBJECT_BASIC_UI_RESTRICTIONS = .{ .UIRestrictionsClass = ui_limits };
        if (w.SetInformationJobObject(handle, w.JobObjectBasicUIRestrictions, &ui, @sizeOf(@TypeOf(ui))) == 0)
            return error.JobFailed;
        return .{ .handle = handle };
    }

    pub fn killAll(j: Job) void {
        _ = w.TerminateJobObject(j.handle, 1);
    }

    pub fn deinit(j: Job) void {
        _ = w.CloseHandle(j.handle);
    }
};

/// Absolute path of the running program: what it starts again, in another
/// mode, for a renderer or the watchdog.
pub fn selfExe(gpa: std.mem.Allocator) ![]u8 {
    var buf: [1024]u16 = undefined;
    const n = w.GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n == buf.len) return error.SpawnFailed;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..n]);
}

/// Absolute path of a file (e.g. "zmural.exe", "libmpv-2.dll") next
/// to the running binary.
pub fn siblingExe(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const self = try selfExe(gpa);
    defer gpa.free(self);
    const dir = std.fs.path.dirname(self) orelse ".";
    return std.fs.path.join(gpa, &.{ dir, name });
}

test appendQuoted {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "plain", "plain" },
        .{ "has space", "\"has space\"" },
        .{ "C:\\dir with space\\", "\"C:\\dir with space\\\\\"" },
        .{ "say \"hi\"", "\"say \\\"hi\\\"\"" },
        .{ "", "\"\"" },
        .{ "C:\\no\\spaces", "C:\\no\\spaces" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try appendQuoted(gpa, &out, c[0]);
        try std.testing.expectEqualStrings(c[1], out.items);
    }
}
