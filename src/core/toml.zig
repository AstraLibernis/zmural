// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The TOML subset zmural's own files use (settings; manifests later), read
//! and written.
//!
//! Supported: `key = value` lines, `[table]` headers (the name is kept as
//! written, e.g. `monitor."m-0123"`), `#` comments, and values that are
//! strings (`"basic"` with `\\ \" \n \t \r` escapes, or `'literal'`), integers,
//! floats, booleans, and single-line arrays of strings.
//! Not supported: multi-line strings or arrays, inline tables, dates.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    strings: []const []const u8,
};

pub const Entry = struct {
    /// "" before the first table header.
    table: []const u8,
    key: []const u8,
    value: Value,
    line: usize,
};

pub const Error = error{ OutOfMemory, SyntaxError, BadValue };

/// Set by `parse` to the line where parsing stopped.
pub const Diagnostic = struct { line: usize = 0 };

/// Strings in the result borrow `src` unless they needed unescaping; allocate
/// in an arena and free it all at once.
pub fn parse(arena: std.mem.Allocator, src_in: []const u8, diag: ?*Diagnostic) Error![]Entry {
    // Windows tools (Notepad, PowerShell 5.1's `-Encoding utf8`) often start files with a UTF-8 BOM.
    const bom = "\xEF\xBB\xBF";
    const src = if (std.mem.startsWith(u8, src_in, bom)) src_in[bom.len..] else src_in;
    var entries: std.ArrayList(Entry) = .empty;
    var table: []const u8 = "";
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        if (diag) |d| d.line = line_no;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            const close = std.mem.findScalarLast(u8, line, ']') orelse return error.SyntaxError;
            table = std.mem.trim(u8, line[1..close], " \t");
            continue;
        }
        const eq = std.mem.findScalar(u8, line, '=') orelse return error.SyntaxError;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) return error.SyntaxError;
        var cur: Cursor = .{ .s = line[eq + 1 ..] };
        const value = try cur.value(arena);
        try cur.end();
        try entries.append(arena, .{ .table = table, .key = key, .value = value, .line = line_no });
    }
    if (diag) |d| d.line = 0;
    return entries.items;
}

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSpace(c: *Cursor) void {
        while (c.i < c.s.len and (c.s[c.i] == ' ' or c.s[c.i] == '\t')) c.i += 1;
    }

    /// Only whitespace or a comment may follow a value.
    fn end(c: *Cursor) Error!void {
        c.skipSpace();
        if (c.i < c.s.len and c.s[c.i] != '#' and c.s[c.i] != '\r') return error.SyntaxError;
    }

    fn value(c: *Cursor, arena: std.mem.Allocator) Error!Value {
        c.skipSpace();
        if (c.i >= c.s.len) return error.BadValue;
        switch (c.s[c.i]) {
            '"', '\'' => return .{ .string = try c.string(arena) },
            '[' => return .{ .strings = try c.array(arena) },
            else => {},
        }
        const start = c.i;
        while (c.i < c.s.len and c.s[c.i] != ' ' and c.s[c.i] != '\t' and c.s[c.i] != '#' and c.s[c.i] != '\r') c.i += 1;
        const bare = c.s[start..c.i];
        if (std.mem.eql(u8, bare, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, bare, "false")) return .{ .boolean = false };
        if (std.fmt.parseInt(i64, bare, 10)) |i| return .{ .int = i } else |_| {}
        if (std.fmt.parseFloat(f64, bare)) |f| return .{ .float = f } else |_| {}
        return error.BadValue;
    }

    fn string(c: *Cursor, arena: std.mem.Allocator) Error![]const u8 {
        const quote = c.s[c.i];
        c.i += 1;
        const start = c.i;
        if (quote == '\'') {
            const close = std.mem.findScalarPos(u8, c.s, start, '\'') orelse return error.SyntaxError;
            c.i = close + 1;
            return c.s[start..close];
        }
        var escaped = false;
        while (c.i < c.s.len and c.s[c.i] != '"') : (c.i += 1) {
            if (c.s[c.i] == '\\') {
                escaped = true;
                c.i += 1;
                if (c.i == c.s.len) return error.SyntaxError;
            }
        }
        if (c.i == c.s.len) return error.SyntaxError;
        const raw = c.s[start..c.i];
        c.i += 1;
        if (!escaped) return raw;
        var out: std.ArrayList(u8) = try .initCapacity(arena, raw.len);
        var j: usize = 0;
        while (j < raw.len) : (j += 1) {
            if (raw[j] != '\\') {
                out.appendAssumeCapacity(raw[j]);
                continue;
            }
            j += 1;
            out.appendAssumeCapacity(switch (raw[j]) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => return error.BadValue,
            });
        }
        return out.items;
    }

    fn array(c: *Cursor, arena: std.mem.Allocator) Error![]const []const u8 {
        c.i += 1; // '['
        var items: std.ArrayList([]const u8) = .empty;
        while (true) {
            c.skipSpace();
            if (c.i >= c.s.len) return error.SyntaxError;
            if (c.s[c.i] == ']') break;
            if (c.s[c.i] != '"' and c.s[c.i] != '\'') return error.BadValue;
            try items.append(arena, try c.string(arena));
            c.skipSpace();
            if (c.i < c.s.len and c.s[c.i] == ',') c.i += 1;
        }
        c.i += 1; // ']'
        return items.items;
    }
};

/// Writes a string value, as a literal string when possible (Windows paths
/// stay readable), else as an escaped basic string.
pub fn writeString(out: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (std.mem.findAny(u8, s, "'\n\r") == null) return out.print("'{s}'", .{s});
    try out.writeByte('"');
    for (s) |ch| switch (ch) {
        '\\' => try out.writeAll("\\\\"),
        '"' => try out.writeAll("\\\""),
        '\n' => try out.writeAll("\\n"),
        '\t' => try out.writeAll("\\t"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(ch),
    };
    try out.writeByte('"');
}

pub fn writeStrings(out: *std.Io.Writer, items: []const []const u8) std.Io.Writer.Error!void {
    try out.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.writeAll(", ");
        try writeString(out, item);
    }
    try out.writeByte(']');
}

test "parses every supported value kind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# settings
        \\wallpaper = 'C:\Users\me\Videos\rain.mp4'
        \\title = "say \"hi\"\tnow" # trailing comment
        \\fps = 30
        \\scale = 1.5
        \\muted = true
        \\rules = ["a.exe", 'b.exe', ]
        \\empty = []
        \\
        \\[monitor."m-0123"]
        \\fill = "crop"
    ;
    const e = try parse(arena.allocator(), src, null);
    try std.testing.expectEqual(@as(usize, 8), e.len);
    try std.testing.expectEqualStrings("C:\\Users\\me\\Videos\\rain.mp4", e[0].value.string);
    try std.testing.expectEqualStrings("say \"hi\"\tnow", e[1].value.string);
    try std.testing.expectEqual(@as(i64, 30), e[2].value.int);
    try std.testing.expectEqual(@as(f64, 1.5), e[3].value.float);
    try std.testing.expect(e[4].value.boolean);
    try std.testing.expectEqual(@as(usize, 2), e[5].value.strings.len);
    try std.testing.expectEqualStrings("b.exe", e[5].value.strings[1]);
    try std.testing.expectEqual(@as(usize, 0), e[6].value.strings.len);
    try std.testing.expectEqualStrings("monitor.\"m-0123\"", e[7].table);
}

test "a leading UTF-8 byte-order mark is ignored" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const e = try parse(arena.allocator(), "\xEF\xBB\xBFkey = 'value'\n", null);
    try std.testing.expectEqualStrings("key", e[0].key);
}

test "rejects malformed input with its line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.SyntaxError, parse(arena.allocator(), "a = 1\nb = \"open", &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expectError(error.BadValue, parse(arena.allocator(), "a = nope", null));
    try std.testing.expectError(error.BadValue, parse(arena.allocator(), "a = \"\\q\"", null));
    try std.testing.expectError(error.SyntaxError, parse(arena.allocator(), "a = 1 2", null));
}

test "written strings read back unchanged" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_][]const u8{ "C:\\plain\\path.mp4", "it's got a quote", "two\nlines", "" };
    for (cases) |case| {
        var buf: [128]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        try out.writeAll("k = ");
        try writeString(&out, case);
        const e = try parse(arena.allocator(), out.buffered(), null);
        try std.testing.expectEqualStrings(case, e[0].value.string);
    }
}
