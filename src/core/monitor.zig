// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Canonical monitor identity, identical on every OS and desktop:
//! "m-" + 16 hex digits of FNV-1a-64 over the EDID manufacturer, product
//! code, serial number and serial string (`fromEdid`, for when the hosts read
//! EDIDs, from M6; Windows uses connector names for now), or over the connector / device name (`fromConnector`). Never the
//! resolution: a game switching display modes is still the same monitor.
//!
//! The ID must never change for a given monitor: per-monitor settings are keyed on it.

const std = @import("std");

pub const Id = [18]u8;

pub const Edid = struct {
    manufacturer: [3]u8,
    product: u16,
    serial: u32,
    /// From the 0xFF display descriptor; borrows the EDID blob. May be empty.
    serial_text: []const u8,
};

/// Parses the fields zmural needs from an EDID 1.x base block.
pub fn parseEdid(blob: []const u8) ?Edid {
    const magic = [_]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    if (blob.len < 128 or !std.mem.eql(u8, blob[0..8], &magic)) return null;

    const m = (@as(u16, blob[8]) << 8) | blob[9];
    var e: Edid = .{
        .manufacturer = .{ letter(m >> 10), letter(m >> 5), letter(m) },
        .product = std.mem.readInt(u16, blob[10..12], .little),
        .serial = std.mem.readInt(u32, blob[12..16], .little),
        .serial_text = "",
    };
    // Four 18-byte descriptors; tag 0xFF is the serial number string.
    var off: usize = 54;
    while (off + 18 <= 126) : (off += 18) {
        const d = blob[off..][0..18];
        if (d[0] == 0 and d[1] == 0 and d[3] == 0xFF) {
            const text = d[5..18];
            const end = std.mem.findScalar(u8, text, '\n') orelse text.len;
            e.serial_text = std.mem.trim(u8, text[0..end], " ");
        }
    }
    return e;
}

fn letter(bits: u16) u8 {
    return 'A' - 1 + @as(u8, @intCast(bits & 0x1f));
}

pub fn fromEdid(e: Edid) Id {
    var h = std.hash.Fnv1a_64.init();
    h.update("edid\x00");
    h.update(&e.manufacturer);
    var nums: [6]u8 = undefined;
    std.mem.writeInt(u16, nums[0..2], e.product, .little);
    std.mem.writeInt(u32, nums[2..6], e.serial, .little);
    h.update(&nums);
    h.update(e.serial_text);
    return fromHash(h.final());
}

/// By connector or device name (e.g. `\\.\DISPLAY1`, "DP-1").
pub fn fromConnector(connector: []const u8) Id {
    var h = std.hash.Fnv1a_64.init();
    h.update("conn\x00");
    h.update(connector);
    return fromHash(h.final());
}

fn fromHash(hash: u64) Id {
    const digits = "0123456789abcdef";
    var id: Id = undefined;
    id[0] = 'm';
    id[1] = '-';
    var v = hash;
    var i: usize = id.len;
    while (i > 2) {
        i -= 1;
        id[i] = digits[@intCast(v & 0xf)];
        v >>= 4;
    }
    return id;
}

fn testEdid() [128]u8 {
    var b: [128]u8 = @splat(0);
    b[0..8].* = .{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    b[8] = 0x10; // "DEL" = 4,5,12 packed as 5-bit letters
    b[9] = 0xAC;
    b[10] = 0xB1; // product 0xA0B1
    b[11] = 0xA0;
    b[12] = 0xD2; // serial 1234
    b[13] = 0x04;
    b[54 + 3] = 0xFF;
    @memcpy(b[54 + 5 ..][0..8], "ABC123\n ");
    return b;
}

test parseEdid {
    const blob = testEdid();
    const e = parseEdid(&blob).?;
    try std.testing.expectEqualStrings("DEL", &e.manufacturer);
    try std.testing.expectEqual(@as(u16, 0xA0B1), e.product);
    try std.testing.expectEqual(@as(u32, 1234), e.serial);
    try std.testing.expectEqualStrings("ABC123", e.serial_text);

    try std.testing.expect(parseEdid(blob[0..100]) == null);
    var bad = blob;
    bad[0] = 1;
    try std.testing.expect(parseEdid(&bad) == null);
}

test "ids are stable and distinct" {
    const blob = testEdid();
    const a = fromEdid(parseEdid(&blob).?);
    try std.testing.expectEqualStrings("m-", a[0..2]);
    try std.testing.expectEqualSlices(u8, &a, &fromEdid(parseEdid(&blob).?));

    var other = blob;
    other[12] = 0xD3;
    try std.testing.expect(!std.mem.eql(u8, &a, &fromEdid(parseEdid(&other).?)));
    try std.testing.expect(!std.mem.eql(u8, &fromConnector("DP-1"), &fromConnector("DP-2")));
    try std.testing.expectEqualSlices(u8, &fromConnector("DP-1"), &fromConnector("DP-1"));
}
