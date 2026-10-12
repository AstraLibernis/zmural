// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Turns a crash code a user posted back into functions and lines:
//!
//!   zig build crashcode -- "zmural 0.1.0 linux crash: 1215256 10fa504"
//!
//! The code names the release; its debug files are looked up in
//! `$ZMURAL_DEBUG_DIR`, else in `zig-out/package/debug/zmural-<version>-<os>-x86_64`
//! (where `zig build package` leaves them; keep one per published release,
//! docs/RELEASING.md). A folder holding a working build's `zmural` (which
//! keeps its debugging info) works too. Linux addresses go to `addr2line`;
//! Windows ones to the system's dbghelp.dll with the release's `zmural.pdb`
//! (no exe needed), so a Windows code is decoded on Windows.

const std = @import("std");
const builtin = @import("builtin");

pub const Code = struct {
    version: []const u8,
    os: []const u8,
    addrs: [8]u64 = undefined,
    len: usize = 0,

    pub fn slice(c: *const Code) []const u64 {
        return c.addrs[0..c.len];
    }
};

/// `zmural <version> <os> crash: <hex> <hex>...`, as `os/crashlog.zig` writes
/// it; text around it (a pasted log line, "it gave error:") is skipped.
pub fn parse(text: []const u8) error{NotACode}!Code {
    var at: usize = 0;
    while (std.mem.findPos(u8, text, at, "zmural ")) |start| : (at = start + 1) {
        return parseAt(text[start + "zmural ".len ..]) catch continue;
    }
    return error.NotACode;
}

fn parseAt(rest: []const u8) error{NotACode}!Code {
    var words = std.mem.tokenizeAny(u8, rest, " \t\r\n");
    var c: Code = .{ .version = words.next() orelse return error.NotACode, .os = words.next() orelse return error.NotACode };
    const crash = words.next() orelse return error.NotACode;
    if (!std.mem.eql(u8, crash, "crash:")) return error.NotACode;
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "none")) break;
        const hex = if (std.mem.startsWith(u8, w, "0x")) w[2..] else w;
        const a = std.fmt.parseInt(u64, hex, 16) catch break;
        if (c.len == c.addrs.len) break;
        c.addrs[c.len] = a;
        c.len += 1;
    }
    return c;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    // argv[1]: the package debug root (from build.zig); the rest: the code.
    if (argv.len < 3) fail("usage: zig build crashcode -- \"zmural 0.1.0 linux crash: 1215256 10fa504\"", .{});
    const text = try std.mem.join(arena, " ", argv[2..]);
    const code = parse(text) catch fail("no crash code in that (it looks like \"zmural 0.1.0 linux crash: 1215256 10fa504\")", .{});
    if (code.len == 0) fail("this crash code holds no addresses in zmural's own code: the crash was inside a library (the log's \"at\" lines may say more)", .{});

    const dir = if (init.environ_map.get("ZMURAL_DEBUG_DIR")) |d|
        d
    else
        try std.fmt.allocPrint(arena, "{s}/zmural-{s}-{s}-x86_64", .{ argv[1], code.version, code.os });
    var addr_args: std.ArrayList([]const u8) = .empty;
    for (code.slice()) |a| try addr_args.append(arena, try std.fmt.allocPrint(arena, "0x{x}", .{a}));

    if (std.mem.eql(u8, code.os, "windows")) {
        if (builtin.os.tag == .windows) return decodeWindows(arena, io, dir, code);
        fail("a Windows crash code is decoded on Windows (with its dbghelp.dll)", .{});
    }
    const debug_file = for ([_][]const u8{ "zmural.debug", "zmural" }) |name| {
        const p = try std.fs.path.join(arena, &.{ dir, name });
        if (std.Io.Dir.cwd().access(io, p, .{})) |_| break p else |_| {}
    } else fail("no debug files for zmural {s} in {s}: keep each release's debug folder (docs/RELEASING.md), or set $ZMURAL_DEBUG_DIR", .{ code.version, dir });

    var cmd: std.ArrayList([]const u8) = .empty;
    try cmd.appendSlice(arena, &.{ "addr2line", "-a", "-f", "-i", "-C", "-p", "-e", debug_file });
    try cmd.appendSlice(arena, addr_args.items);
    std.debug.print("zmural {s} ({s}), from {s}:\n", .{ code.version, code.os, debug_file });
    var child = std.process.spawn(io, .{ .argv = cmd.items, .stdin = .ignore }) catch |err| fail("can't run addr2line (binutils): {s}", .{@errorName(err)});
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) fail("addr2line failed", .{});
}

/// Windows addresses are from the program's base: load the PDB at a made-up
/// base and look each one up there.
fn decodeWindows(arena: std.mem.Allocator, io: std.Io, dir: []const u8, code: Code) !void {
    const pdb = try std.fs.path.join(arena, &.{ dir, "zmural.pdb" });
    std.Io.Dir.cwd().access(io, pdb, .{}) catch fail("no debug files for zmural {s} in {s}: keep each release's debug folder (docs/RELEASING.md), or set $ZMURAL_DEBUG_DIR", .{ code.version, dir });
    const d = dbghelp;
    const process: *anyopaque = @ptrFromInt(0x5A4D); // any value: no process is read
    const base: u64 = 0x1000_0000;
    _ = d.SymSetOptions(0x2 | 0x10 | 0x40); // SYMOPT_UNDNAME | SYMOPT_LOAD_LINES | SYMOPT_FAIL_CRITICAL_ERRORS
    if (d.SymInitializeW(process, try std.unicode.wtf8ToWtf16LeAllocZ(arena, dir), 0) == 0) fail("dbghelp couldn't start", .{});
    defer _ = d.SymCleanup(process);
    // A PDB alone loads when given a size; the program's is far below this.
    if (d.SymLoadModuleExW(process, null, try std.unicode.wtf8ToWtf16LeAllocZ(arena, pdb), null, base, 0x1000_0000, null, 0) == 0)
        fail("dbghelp couldn't read {s}", .{pdb});
    std.debug.print("zmural {s} (windows), from {s}:\n", .{ code.version, pdb });
    for (code.slice()) |a| {
        var sym: d.SymbolInfo = .{};
        var off: u64 = 0;
        const name = if (d.SymFromAddrW(process, base + a, &off, &sym) != 0)
            try std.unicode.wtf16LeToWtf8Alloc(arena, sym.name[0..@min(sym.name_len, sym.name.len)])
        else
            "??";
        var line: d.LineW64 = .{};
        var line_off: u32 = 0;
        if (d.SymGetLineFromAddrW64(process, base + a, &line_off, &line) != 0) {
            const file = try std.unicode.wtf16LeToWtf8Alloc(arena, std.mem.span(line.file_name.?));
            std.debug.print("0x{x}: {s} at {s}:{d}\n", .{ a, name, file, line.line_number });
        } else std.debug.print("0x{x}: {s}\n", .{ a, name });
    }
}

const dbghelp = struct {
    const SymbolInfo = extern struct {
        size_of_struct: u32 = 88, // SYMBOL_INFOW without its name
        type_index: u32 = 0,
        reserved: [2]u64 = .{ 0, 0 },
        index: u32 = 0,
        size: u32 = 0,
        mod_base: u64 = 0,
        flags: u32 = 0,
        value: u64 = 0,
        address: u64 = 0,
        register: u32 = 0,
        scope: u32 = 0,
        tag: u32 = 0,
        name_len: u32 = 0,
        max_name_len: u32 = 256,
        name: [256]u16 = undefined,
    };
    const LineW64 = extern struct {
        size_of_struct: u32 = @sizeOf(LineW64),
        key: ?*anyopaque = null,
        line_number: u32 = 0,
        file_name: ?[*:0]const u16 = null,
        address: u64 = 0,
    };
    extern "dbghelp" fn SymSetOptions(options: u32) callconv(.winapi) u32;
    extern "dbghelp" fn SymInitializeW(process: *anyopaque, search_path: ?[*:0]const u16, invade: c_int) callconv(.winapi) c_int;
    extern "dbghelp" fn SymCleanup(process: *anyopaque) callconv(.winapi) c_int;
    extern "dbghelp" fn SymLoadModuleExW(process: *anyopaque, file: ?*anyopaque, image: [*:0]const u16, module: ?[*:0]const u16, base: u64, size: u32, data: ?*anyopaque, flags: u32) callconv(.winapi) u64;
    extern "dbghelp" fn SymFromAddrW(process: *anyopaque, address: u64, displacement: ?*u64, symbol: *SymbolInfo) callconv(.winapi) c_int;
    extern "dbghelp" fn SymGetLineFromAddrW64(process: *anyopaque, address: u64, displacement: *u32, line: *LineW64) callconv(.winapi) c_int;
};

test "dbghelp's structs have the sizes and offsets it expects" {
    try std.testing.expectEqual(@as(usize, 84), @offsetOf(dbghelp.SymbolInfo, "name"));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(dbghelp.LineW64));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(dbghelp.LineW64, "line_number"));
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("crashcode: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

test "a crash code is read from whatever was pasted around it" {
    const c = try parse("I crashed, it gave error: zmural 0.1.0 linux crash: 1215256 10fa504 10e8241\n");
    try std.testing.expectEqualStrings("0.1.0", c.version);
    try std.testing.expectEqualStrings("linux", c.os);
    try std.testing.expectEqualSlices(u64, &.{ 0x1215256, 0x10fa504, 0x10e8241 }, c.slice());
    const none = try parse("zmural 0.1.0 windows crash: none");
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try std.testing.expectError(error.NotACode, parse("zmural crashed"));
    const later = try parse("zmural crashed, it said: zmural 0.1.0 linux crash: 12");
    try std.testing.expectEqualSlices(u64, &.{0x12}, later.slice());
    try std.testing.expectError(error.NotACode, parse("nothing here"));
}
