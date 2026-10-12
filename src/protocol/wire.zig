// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Message framing shared by every zmural protocol.
//!
//! A frame is a 4-byte header, `[u16 opcode][u16 body_len]` (little-endian),
//! followed by the body. Bodies are encoded at comptime from plain Zig types:
//!
//! - integers: little-endian at their natural width
//! - enums: their tag, rounded up to whole bytes (a 4-value enum is one byte)
//! - bool: one byte (0 or 1)
//! - f32 / f64: IEEE bits, little-endian
//! - `[]const u8`: u16 length then the bytes (decoded slices borrow the input)
//! - `?T`: one presence byte then `T`
//! - `[N]T`: the N elements, one after another (no length: N is fixed)
//! - structs: their fields in declaration order
//!
//! OS handles (Linux fds, Windows HANDLEs) never go in the body. They travel
//! alongside the frame through the transport (SCM_RIGHTS / DuplicateHandle).

const std = @import("std");

pub const Error = error{
    BufferTooSmall,
    BodyTooLarge,
    Truncated,
    TrailingBytes,
    InvalidBool,
    InvalidEnum,
    UnknownOpcode,
};

pub const header_len = 4;
pub const max_body_len = std.math.maxInt(u16);

pub const Header = struct {
    opcode: u16,
    body_len: u16,

    pub fn write(h: Header, out: *[header_len]u8) void {
        std.mem.writeInt(u16, out[0..2], h.opcode, .little);
        std.mem.writeInt(u16, out[2..4], h.body_len, .little);
    }

    pub fn read(in: *const [header_len]u8) Header {
        return .{
            .opcode = std.mem.readInt(u16, in[0..2], .little),
            .body_len = std.mem.readInt(u16, in[2..4], .little),
        };
    }
};

/// Encodes `msg` (a tagged union whose tag values are opcodes) as a complete
/// frame into `out`, returning the used prefix.
pub fn encodeMessage(comptime M: type, msg: M, out: []u8) Error![]const u8 {
    if (out.len < header_len) return error.BufferTooSmall;
    var e: Encoder = .{ .buf = out[header_len..] };
    switch (msg) {
        inline else => |payload| try e.value(@TypeOf(payload), payload),
    }
    if (e.pos > max_body_len) return error.BodyTooLarge;
    const Tag = @typeInfo(M).@"union".tag_type.?;
    const tag: Tag = msg;
    const header: Header = .{ .opcode = @intFromEnum(tag), .body_len = @intCast(e.pos) };
    header.write(out[0..header_len]);
    return out[0 .. header_len + e.pos];
}

/// Decodes the body of a frame with the given opcode. String fields in the
/// result borrow `body`.
pub fn decodeMessage(comptime M: type, opcode: u16, body: []const u8) Error!M {
    const info = @typeInfo(M).@"union";
    inline for (info.fields) |f| {
        if (opcode == @intFromEnum(@field(info.tag_type.?, f.name))) {
            var d: Decoder = .{ .buf = body };
            const payload = try d.value(f.type);
            if (d.pos != body.len) return error.TrailingBytes;
            return @unionInit(M, f.name, payload);
        }
    }
    return error.UnknownOpcode;
}

/// Decodes a complete frame (header + body), as produced by `encodeMessage`.
pub fn decodeFrame(comptime M: type, frame: []const u8) Error!M {
    if (frame.len < header_len) return error.Truncated;
    const h = Header.read(frame[0..header_len]);
    if (frame.len - header_len < h.body_len) return error.Truncated;
    if (frame.len - header_len > h.body_len) return error.TrailingBytes;
    return decodeMessage(M, h.opcode, frame[header_len..]);
}

const Encoder = struct {
    buf: []u8,
    pos: usize = 0,

    fn bytes(e: *Encoder, b: []const u8) Error!void {
        if (e.buf.len - e.pos < b.len) return error.BufferTooSmall;
        @memcpy(e.buf[e.pos..][0..b.len], b);
        e.pos += b.len;
    }

    fn int(e: *Encoder, comptime I: type, v: I) Error!void {
        var tmp: [@divExact(@typeInfo(I).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(I, &tmp, v, .little);
        try e.bytes(&tmp);
    }

    fn value(e: *Encoder, comptime T: type, v: T) Error!void {
        switch (@typeInfo(T)) {
            .void => {},
            .int => try e.int(T, v),
            .bool => try e.int(u8, @intFromBool(v)),
            .float => try e.int(FloatBits(T), @bitCast(v)),
            .@"enum" => |en| try e.int(ByteInt(en.tag_type), @intFromEnum(v)),
            .pointer => {
                comptime assertString(T);
                if (v.len > max_body_len) return error.BodyTooLarge;
                try e.int(u16, @intCast(v.len));
                try e.bytes(v);
            },
            .optional => |o| if (v) |x| {
                try e.int(u8, 1);
                try e.value(o.child, x);
            } else try e.int(u8, 0),
            .@"struct" => |s| inline for (s.fields) |f| try e.value(f.type, @field(v, f.name)),
            .array => |a| for (v) |x| try e.value(a.child, x),
            else => @compileError("zmural wire: unsupported type " ++ @typeName(T)),
        }
    }
};

const Decoder = struct {
    buf: []const u8,
    pos: usize = 0,

    fn bytes(d: *Decoder, n: usize) Error![]const u8 {
        if (d.buf.len - d.pos < n) return error.Truncated;
        const s = d.buf[d.pos..][0..n];
        d.pos += n;
        return s;
    }

    fn int(d: *Decoder, comptime I: type) Error!I {
        const n = @divExact(@typeInfo(I).int.bits, 8);
        const s = try d.bytes(n);
        return std.mem.readInt(I, s[0..n], .little);
    }

    fn value(d: *Decoder, comptime T: type) Error!T {
        switch (@typeInfo(T)) {
            .void => return {},
            .int => return d.int(T),
            .bool => return switch (try d.int(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidBool,
            },
            .float => return @bitCast(try d.int(FloatBits(T))),
            .@"enum" => |en| {
                const raw = try d.int(ByteInt(en.tag_type));
                inline for (en.fields) |f| {
                    if (raw == f.value) return @field(T, f.name);
                }
                return error.InvalidEnum;
            },
            .pointer => {
                comptime assertString(T);
                const n = try d.int(u16);
                return d.bytes(n);
            },
            .optional => |o| return switch (try d.int(u8)) {
                0 => null,
                1 => try d.value(o.child),
                else => error.InvalidBool,
            },
            .@"struct" => |s| {
                var out: T = undefined;
                inline for (s.fields) |f| @field(out, f.name) = try d.value(f.type);
                return out;
            },
            .array => |a| {
                var out: T = undefined;
                for (&out) |*x| x.* = try d.value(a.child);
                return out;
            },
            else => @compileError("zmural wire: unsupported type " ++ @typeName(T)),
        }
    }
};

/// The integer type an enum tag travels as: its width rounded up to whole bytes.
fn ByteInt(comptime T: type) type {
    const info = @typeInfo(T).int;
    return @Int(info.signedness, (info.bits + 7) / 8 * 8);
}

fn FloatBits(comptime F: type) type {
    return switch (@typeInfo(F).float.bits) {
        32 => u32,
        64 => u64,
        else => @compileError("zmural wire: only f32 and f64 are supported"),
    };
}

fn assertString(comptime T: type) void {
    const p = @typeInfo(T).pointer;
    if (p.size != .slice or p.child != u8 or !p.is_const)
        @compileError("zmural wire: only []const u8 slices are supported, got " ++ @typeName(T));
}

const TestOp = enum(u16) { ping = 7, note = 9, empty = 11, small = 13, many = 15 };
const TestMsg = union(TestOp) {
    ping: struct { seq: u32, ok: bool, ratio: f32 },
    note: struct { text: []const u8, level: enum(u8) { low, high }, extra: ?u64 },
    empty: void,
    /// An enum with a 2-bit tag must still encode (as one byte).
    small: enum { a, b, c, d },
    many: struct { levels: [3]enum(u8) { off, on }, sizes: [2]u16 },
};

test "round trip every field kind" {
    var buf: [128]u8 = undefined;
    const msgs = [_]TestMsg{
        .{ .ping = .{ .seq = 42, .ok = true, .ratio = 0.5 } },
        .{ .note = .{ .text = "hello", .level = .high, .extra = 99 } },
        .{ .note = .{ .text = "", .level = .low, .extra = null } },
        .empty,
        .{ .small = .d },
        .{ .many = .{ .levels = .{ .on, .off, .on }, .sizes = .{ 640, 480 } } },
    };
    for (msgs) |msg| {
        const frame = try encodeMessage(TestMsg, msg, &buf);
        const back = try decodeFrame(TestMsg, frame);
        try std.testing.expectEqual(std.meta.activeTag(msg), std.meta.activeTag(back));
        switch (msg) {
            .ping => |p| try std.testing.expectEqual(p, back.ping),
            .note => |n| {
                try std.testing.expectEqualStrings(n.text, back.note.text);
                try std.testing.expectEqual(n.level, back.note.level);
                try std.testing.expectEqual(n.extra, back.note.extra);
            },
            .empty => {},
            .small => |x| try std.testing.expectEqual(x, back.small),
            .many => |m| try std.testing.expectEqual(m, back.many),
        }
    }
}

test "header carries opcode and length" {
    var buf: [64]u8 = undefined;
    const frame = try encodeMessage(TestMsg, .{ .ping = .{ .seq = 1, .ok = false, .ratio = 1 } }, &buf);
    const h = Header.read(frame[0..header_len]);
    try std.testing.expectEqual(@as(u16, 7), h.opcode);
    try std.testing.expectEqual(@as(u16, 4 + 1 + 4), h.body_len);
}

test "malformed input is rejected" {
    var buf: [64]u8 = undefined;
    const frame = try encodeMessage(TestMsg, .{ .note = .{ .text = "abc", .level = .low, .extra = null } }, &buf);
    try std.testing.expectError(error.Truncated, decodeFrame(TestMsg, frame[0 .. frame.len - 1]));
    try std.testing.expectError(error.UnknownOpcode, decodeMessage(TestMsg, 1234, frame[header_len..]));

    var bad_enum = buf;
    bad_enum[header_len + 2 + 3] = 5; // level byte after the 3-byte string
    try std.testing.expectError(error.InvalidEnum, decodeFrame(TestMsg, bad_enum[0..frame.len]));

    var tiny: [3]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encodeMessage(TestMsg, .empty, &tiny));
}
