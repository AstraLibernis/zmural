// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! A small D-Bus client (Linux), speaking the wire protocol directly (no
//! libdbus, no GLib): enough for zmural to own `org.zmural.Daemon`, emit
//! its `Ready` signal, show desktop notifications and call a desktop's
//! scripting interface.
//!
//! Messages are little-endian. Arguments are written with `Writer` in the
//! order of the method's signature; replies are returned raw, to be read
//! with `Reader`. Calls block (with a timeout): they happen at startup and
//! on rare events, never per frame.

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{
    NoBus,
    ConnectFailed,
    AuthFailed,
    Disconnected,
    Timeout,
    /// The other side replied with a D-Bus error (see `Conn.last_error`).
    CallFailed,
    Protocol,
    TooLarge,
    /// `call` from inside a hook run by another `call`: the inner one would
    /// read, and drop, the outer one's reply.
    Reentered,
};

const msg_method_call = 1;
const msg_method_return = 2;
const msg_error = 3;
const msg_signal = 4;
const flag_no_reply = 0x1;

// ---- marshalling ------------------------------------------------------------------

/// Builds a message body (or header) with D-Bus alignment rules.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn bytes(w: *Writer, b: []const u8) Error!void {
        if (w.len + b.len > w.buf.len) return error.TooLarge;
        @memcpy(w.buf[w.len..][0..b.len], b);
        w.len += b.len;
    }

    /// Bytes as they are (an `ay`'s contents, after its length).
    pub fn bytesRaw(w: *Writer, b: []const u8) Error!void {
        try w.bytes(b);
    }

    pub fn pad(w: *Writer, alignment: usize) Error!void {
        while (w.len % alignment != 0) try w.bytes(&.{0});
    }

    pub fn byte(w: *Writer, v: u8) Error!void {
        try w.bytes(&.{v});
    }

    pub fn u32_(w: *Writer, v: u32) Error!void {
        try w.pad(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try w.bytes(&b);
    }

    pub fn i32_(w: *Writer, v: i32) Error!void {
        try w.u32_(@bitCast(v));
    }

    /// Also for object paths (`o`). The bus drops the whole connection over
    /// a string that isn't valid UTF-8, and text from a Linux file name can
    /// be any bytes, so a bad byte goes out as U+FFFD (as the settings window
    /// draws it).
    pub fn string(w: *Writer, s: []const u8) Error!void {
        if (std.unicode.utf8ValidateSlice(s)) {
            try w.u32_(@intCast(s.len));
            try w.bytes(s);
            return w.byte(0);
        }
        try w.u32_(0);
        const start = w.len;
        var i: usize = 0;
        while (i < s.len) {
            const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
            if (l > 0 and i + l <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..l])) {
                try w.bytes(s[i..][0..l]);
                i += l;
            } else {
                try w.bytes(&std.unicode.replacement_character_utf8);
                i += 1;
            }
        }
        std.mem.writeInt(u32, w.buf[start - 4 ..][0..4], @intCast(w.len - start), .little);
        try w.byte(0);
    }

    pub fn signature(w: *Writer, s: []const u8) Error!void {
        try w.byte(@intCast(s.len));
        try w.bytes(s);
        try w.byte(0);
    }

    /// Starts an array whose elements align to `elem_align`; returns the
    /// position of its length, for `endArray`.
    pub fn beginArray(w: *Writer, elem_align: usize) Error!struct { usize, usize } {
        try w.u32_(0);
        const at = w.len - 4;
        try w.pad(elem_align);
        return .{ at, w.len };
    }

    pub fn endArray(w: *Writer, a: struct { usize, usize }) void {
        std.mem.writeInt(u32, w.buf[a[0]..][0..4], @intCast(w.len - a[1]), .little);
    }

    pub fn written(w: *const Writer) []const u8 {
        return w.buf[0..w.len];
    }
};

/// Reads a message body in signature order.
pub const Reader = struct {
    body: []const u8,
    pos: usize = 0,

    fn align_(r: *Reader, n: usize) Error!void {
        const p = (r.pos + n - 1) / n * n;
        if (p > r.body.len) return error.Protocol;
        r.pos = p;
    }

    pub fn u32_(r: *Reader) Error!u32 {
        try r.align_(4);
        if (r.body.len - r.pos < 4) return error.Protocol;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.body[r.pos..][0..4], .little);
    }

    pub fn string(r: *Reader) Error![]const u8 {
        const n = try r.u32_();
        if (r.body.len - r.pos < @as(usize, n) + 1) return error.Protocol;
        defer r.pos += n + 1;
        return r.body[r.pos..][0..n];
    }

    pub fn boolean(r: *Reader) Error!bool {
        return (try r.u32_()) != 0;
    }

    pub fn byte(r: *Reader) Error!u8 {
        if (r.pos >= r.body.len) return error.Protocol;
        defer r.pos += 1;
        return r.body[r.pos];
    }

    pub fn f64_(r: *Reader) Error!f64 {
        try r.align_(8);
        if (r.body.len - r.pos < 8) return error.Protocol;
        defer r.pos += 8;
        return @bitCast(std.mem.readInt(u64, r.body[r.pos..][0..8], .little));
    }

    /// A signature (`g`), as in a variant's header.
    pub fn signature(r: *Reader) Error![]const u8 {
        const n = try r.byte();
        if (r.body.len - r.pos < @as(usize, n) + 1) return error.Protocol;
        defer r.pos += n + 1;
        return r.body[r.pos..][0..n];
    }

    /// Starts an array: returns where it ends (read elements while `pos < end`).
    pub fn arrayEnd(r: *Reader, elem_align: usize) Error!usize {
        const n = try r.u32_();
        try r.align_(elem_align);
        if (n > r.body.len - r.pos) return error.Protocol;
        return r.pos + n;
    }

    pub fn alignStruct(r: *Reader) Error!void {
        try r.align_(8);
    }

    /// Skips one complete value of type `sig` (a single complete type).
    pub fn skip(r: *Reader, sig: []const u8) Error!void {
        var i: usize = 0;
        try r.skipOne(sig, &i);
    }

    fn skipOne(r: *Reader, sig: []const u8, i: *usize) Error!void {
        if (i.* >= sig.len) return error.Protocol;
        const c = sig[i.*];
        i.* += 1;
        switch (c) {
            'y' => _ = try r.byte(),
            'b', 'u', 'i', 'h' => _ = try r.u32_(),
            'n', 'q' => {
                try r.align_(2);
                r.pos += 2;
            },
            'x', 't', 'd' => {
                try r.align_(8);
                r.pos += 8;
            },
            's', 'o' => _ = try r.string(),
            'g' => _ = try r.signature(),
            'v' => {
                const inner = try r.signature();
                try r.skip(inner);
            },
            'a' => {
                const elem_start = i.*;
                // Find the element type's end without reading anything.
                try skipSig(sig, i);
                const elem = sig[elem_start..i.*];
                const end = try r.arrayEnd(alignOf(elem[0]));
                while (r.pos < end) try r.skip(elem);
                r.pos = end;
            },
            '(', '{' => {
                try r.align_(8);
                const close: u8 = if (c == '(') ')' else '}';
                while (i.* < sig.len and sig[i.*] != close) try r.skipOne(sig, i);
                i.* += 1;
            },
            else => return error.Protocol,
        }
        if (r.pos > r.body.len) return error.Protocol;
    }
};

fn alignOf(c: u8) usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'x', 't', 'd', '(', '{' => 8,
        else => 4,
    };
}

/// Advances `i` past one complete type in `sig`.
fn skipSig(sig: []const u8, i: *usize) Error!void {
    if (i.* >= sig.len) return error.Protocol;
    const c = sig[i.*];
    i.* += 1;
    switch (c) {
        'a' => try skipSig(sig, i),
        '(', '{' => {
            const close: u8 = if (c == '(') ')' else '}';
            while (i.* < sig.len and sig[i.*] != close) try skipSig(sig, i);
            if (i.* >= sig.len) return error.Protocol;
            i.* += 1;
        },
        else => {},
    }
}

/// A message as received: header fields plus its body (valid until the next read).
pub const Message = struct {
    kind: u8,
    serial: u32,
    reply_serial: u32 = 0,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    sender: []const u8 = "",
    signature: []const u8 = "",
    body: []const u8,

    pub fn isSignal(m: Message, iface: []const u8, member: []const u8) bool {
        return m.kind == msg_signal and std.mem.eql(u8, m.interface, iface) and std.mem.eql(u8, m.member, member);
    }
};

pub const Kind = struct {
    pub const method_call: u8 = msg_method_call;
    pub const method_return: u8 = msg_method_return;
    pub const err: u8 = msg_error;
    pub const signal: u8 = msg_signal;
};

/// Called with every message that isn't the reply being waited for:
/// signals, and method calls to objects we export.
pub const Hook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, c: *Conn, m: Message) void,
};

// ---- the connection -----------------------------------------------------------------

pub const Conn = struct {
    fd: linux.fd_t,
    serial: u32 = 1,
    /// Our unique name on the bus (":1.42").
    unique: [64]u8 = undefined,
    unique_len: usize = 0,
    /// The error name of the last failed call.
    last_error: [128]u8 = undefined,
    last_error_len: usize = 0,
    in: [1 << 16]u8 = undefined,
    hook: ?Hook = null,
    /// A `call` is waiting for its reply.
    calling: bool = false,

    /// Connects to the session bus (`DBUS_SESSION_BUS_ADDRESS`, a
    /// `unix:path=` address; else `$XDG_RUNTIME_DIR/bus`) and says hello.
    pub fn session(address: ?[]const u8, xdg_runtime_dir: ?[]const u8) Error!Conn {
        var path_buf: [256]u8 = undefined;
        const path = if (address) |a| unixPath(a) orelse return error.NoBus else std.fmt.bufPrint(&path_buf, "{s}/bus", .{xdg_runtime_dir orelse return error.NoBus}) catch return error.NoBus;
        return connectPath(path);
    }

    /// Connects to the system bus (`DBUS_SYSTEM_BUS_ADDRESS`, a `unix:path=`
    /// address; else the standard socket) and says hello.
    pub fn system(address: ?[]const u8) Error!Conn {
        const path = if (address) |a| unixPath(a) orelse return error.NoBus else "/run/dbus/system_bus_socket";
        return connectPath(path);
    }

    fn connectPath(path: []const u8) Error!Conn {
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) return error.NoBus;
        @memcpy(addr.path[0..path.len], path);
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.ConnectFailed;
        var c: Conn = .{ .fd = @intCast(rc) };
        errdefer c.close();
        if (linux.errno(linux.connect(c.fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.ConnectFailed;
        // 2 s for any single call; the bus is local.
        const tv: linux.timeval = .{ .sec = 2, .usec = 0 };
        _ = linux.setsockopt(c.fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        _ = linux.setsockopt(c.fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
        try c.auth();
        const answer = try c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", "");
        var r: Reader = .{ .body = answer };
        const name = try r.string();
        c.unique_len = @min(name.len, c.unique.len);
        @memcpy(c.unique[0..c.unique_len], name[0..c.unique_len]);
        return c;
    }

    pub fn close(c: *Conn) void {
        _ = linux.close(c.fd);
    }

    fn auth(c: *Conn) Error!void {
        // AUTH EXTERNAL with our uid as hex-encoded ASCII.
        var uid_buf: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&uid_buf, "{d}", .{linux.getuid()}) catch return error.AuthFailed;
        var hex_buf: [32]u8 = undefined;
        const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{uid}) catch return error.AuthFailed;
        var line_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "\x00AUTH EXTERNAL {s}\r\n", .{hex}) catch return error.AuthFailed;
        try c.writeAll(line);
        var resp: [128]u8 = undefined;
        const n = try c.readLine(&resp);
        if (!std.mem.startsWith(u8, resp[0..n], "OK ")) return error.AuthFailed;
        try c.writeAll("BEGIN\r\n");
    }

    fn readLine(c: *Conn, buf: []u8) Error!usize {
        var n: usize = 0;
        while (n < buf.len) {
            const rc = linux.read(c.fd, buf[n..].ptr, 1);
            switch (linux.errno(rc)) {
                .SUCCESS => if (rc == 0) return error.Disconnected,
                .INTR => continue,
                .AGAIN => return error.Timeout,
                else => return error.Disconnected,
            }
            n += 1;
            if (n >= 2 and buf[n - 2] == '\r' and buf[n - 1] == '\n') return n;
        }
        return error.Protocol;
    }

    fn writeAll(c: *Conn, b: []const u8) Error!void {
        var sent: usize = 0;
        while (sent < b.len) {
            const rc = linux.write(c.fd, b[sent..].ptr, b.len - sent);
            switch (linux.errno(rc)) {
                .SUCCESS => sent += rc,
                .INTR => continue,
                .AGAIN => return error.Timeout,
                else => return error.Disconnected,
            }
        }
    }

    fn readExact(c: *Conn, b: []u8) Error!void {
        var got: usize = 0;
        while (got < b.len) {
            const rc = linux.read(c.fd, b[got..].ptr, b.len - got);
            switch (linux.errno(rc)) {
                .SUCCESS => if (rc == 0) return error.Disconnected else {
                    got += rc;
                },
                .INTR => continue,
                .AGAIN => return error.Timeout,
                else => return error.Disconnected,
            }
        }
    }

    /// Sends one message. `body` must match `sig`.
    fn send(c: *Conn, kind: u8, flags: u8, dest: ?[]const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) Error!u32 {
        var hbuf: [1024]u8 = undefined;
        var h: Writer = .{ .buf = &hbuf };
        try h.byte('l');
        try h.byte(kind);
        try h.byte(flags);
        try h.byte(1); // protocol version
        try h.u32_(@intCast(body.len));
        const serial = c.serial;
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        try h.u32_(serial);
        const fields = try h.beginArray(8);
        const Field = struct { code: u8, sig: []const u8, value: []const u8 };
        const all = [_]?Field{
            .{ .code = 1, .sig = "o", .value = path },
            .{ .code = 2, .sig = "s", .value = iface },
            .{ .code = 3, .sig = "s", .value = member },
            if (dest) |d| .{ .code = 6, .sig = "s", .value = d } else null,
            if (sig.len > 0) .{ .code = 8, .sig = "g", .value = sig } else null,
        };
        for (all) |maybe| if (maybe) |f| {
            try h.pad(8);
            try h.byte(f.code);
            try h.signature(f.sig);
            if (f.sig[0] == 'g') try h.signature(f.value) else try h.string(f.value);
        };
        h.endArray(fields);
        try h.pad(8);
        try c.writeAll(h.written());
        try c.writeAll(body);
        return serial;
    }

    /// Reads one whole message into `c.in`.
    pub fn receive(c: *Conn) Error!Message {
        var fixed: [16]u8 = undefined;
        try c.readExact(&fixed);
        if (fixed[0] != 'l') return error.Protocol; // zmural only talks to little-endian buses
        const body_len = std.mem.readInt(u32, fixed[4..8], .little);
        const fields_len = std.mem.readInt(u32, fixed[12..16], .little);
        const header_end = (16 + @as(usize, fields_len) + 7) / 8 * 8;
        const total = header_end + body_len;
        if (total > c.in.len) return error.TooLarge;
        @memcpy(c.in[0..16], &fixed);
        try c.readExact(c.in[16..total]);
        var m: Message = .{ .kind = fixed[1], .serial = std.mem.readInt(u32, fixed[8..12], .little), .body = c.in[header_end..total] };
        var r: Reader = .{ .body = c.in[0 .. 16 + fields_len], .pos = 16 };
        while (r.pos < r.body.len) {
            try r.align_(8);
            if (r.pos >= r.body.len) break;
            const code = try r.byte();
            const fsig = try r.signature();
            if (fsig.len != 1) return error.Protocol;
            switch (fsig[0]) {
                'u' => {
                    const v = try r.u32_();
                    if (code == 5) m.reply_serial = v;
                },
                's', 'o' => {
                    const v = try r.string();
                    switch (code) {
                        1 => m.path = v,
                        2 => m.interface = v,
                        3 => m.member = v,
                        4 => m.error_name = v,
                        7 => m.sender = v,
                        else => {},
                    }
                },
                'g' => {
                    const v = try r.signature();
                    if (code == 8) m.signature = v;
                },
                else => return error.Protocol,
            }
        }
        return m;
    }

    /// Calls a method and waits for its reply body (valid until the next call).
    pub fn call(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) Error![]const u8 {
        if (c.calling) {
            std.log.warn("dbus: refused {s}.{s} from inside another call's wait", .{ iface, member });
            return error.Reentered;
        }
        c.calling = true;
        defer c.calling = false;
        const serial = try c.send(msg_method_call, 0, dest, path, iface, member, sig, body);
        while (true) {
            const in = try c.receive();
            if (in.reply_serial != serial) {
                // Signals and calls to us arriving meanwhile still count.
                if (c.hook) |h| h.func(h.ctx, c, in);
                continue;
            }
            switch (in.kind) {
                msg_method_return => return in.body,
                msg_error => {
                    c.last_error_len = @min(in.error_name.len, c.last_error.len);
                    @memcpy(c.last_error[0..c.last_error_len], in.error_name[0..c.last_error_len]);
                    return error.CallFailed;
                },
                else => continue,
            }
        }
    }

    pub fn lastError(c: *const Conn) []const u8 {
        return c.last_error[0..c.last_error_len];
    }

    /// Emits a signal from `path`.
    pub fn signal(c: *Conn, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) Error!void {
        _ = try c.send(msg_signal, flag_no_reply, null, path, iface, member, sig, body);
    }

    /// Takes a well-known name. False if someone else has it.
    pub fn requestName(c: *Conn, name: []const u8) Error!bool {
        var buf: [256]u8 = undefined;
        var w: Writer = .{ .buf = &buf };
        try w.string(name);
        try w.u32_(4); // DBUS_NAME_FLAG_DO_NOT_QUEUE
        const answer = try c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", w.written());
        var r: Reader = .{ .body = answer };
        const result = try r.u32_();
        return result == 1 or result == 4; // primary owner, or already owner
    }

    /// Is `name` owned by anyone?
    pub fn nameHasOwner(c: *Conn, name: []const u8) Error!bool {
        var buf: [256]u8 = undefined;
        var w: Writer = .{ .buf = &buf };
        try w.string(name);
        const answer = try c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner", "s", w.written());
        var r: Reader = .{ .body = answer };
        return r.boolean();
    }

    /// Reads one property (org.freedesktop.DBus.Properties.Get). Booleans,
    /// strings and 32-bit integers come back as such; other types as `.other`.
    pub fn getProperty(c: *Conn, dest: []const u8, path: []const u8, iface: []const u8, name: []const u8) Error!Value {
        var buf: [512]u8 = undefined;
        var w: Writer = .{ .buf = &buf };
        try w.string(iface);
        try w.string(name);
        const answer = try c.call(dest, path, "org.freedesktop.DBus.Properties", "Get", "ss", w.written());
        var r: Reader = .{ .body = answer };
        return readVariant(&r);
    }

    /// A desktop notification (org.freedesktop.Notifications). Returns its id.
    pub fn notify(c: *Conn, app: []const u8, icon: []const u8, summary: []const u8, text: []const u8) Error!u32 {
        var buf: [4096]u8 = undefined;
        var w: Writer = .{ .buf = &buf };
        try w.string(app);
        try w.u32_(0); // replaces_id
        try w.string(icon);
        try w.string(summary);
        try w.string(text);
        w.endArray(try w.beginArray(4)); // actions: none
        w.endArray(try w.beginArray(8)); // hints: none
        try w.i32_(-1); // default expiry
        const answer = try c.call("org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", "susssasa{sv}i", w.written());
        var r: Reader = .{ .body = answer };
        return r.u32_();
    }

    /// Reads one message the bus sent unasked and hands it to the hook (or
    /// drops it: NameAcquired and the like). Call when the fd polls readable.
    pub fn drain(c: *Conn) Error!void {
        const m = try c.receive();
        if (c.hook) |h| h.func(h.ctx, c, m);
    }

    /// Asks the bus to deliver signals matching `rule` (match-rule syntax).
    pub fn addMatch(c: *Conn, rule: []const u8) Error!void {
        var buf: [512]u8 = undefined;
        var w: Writer = .{ .buf = &buf };
        try w.string(rule);
        _ = try c.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", "s", w.written());
    }

    /// Replies to a method call we received.
    pub fn reply(c: *Conn, to: Message, sig: []const u8, body: []const u8) Error!void {
        _ = try c.sendReply(msg_method_return, to, null, sig, body);
    }

    /// Replies to a method call with a D-Bus error.
    pub fn replyError(c: *Conn, to: Message, name: []const u8, text: []const u8) Error!void {
        var buf: [512]u8 = undefined;
        var w: Writer = .{ .buf = &buf };
        try w.string(text);
        _ = try c.sendReply(msg_error, to, name, "s", w.written());
    }

    fn sendReply(c: *Conn, kind: u8, to: Message, error_name: ?[]const u8, sig: []const u8, body: []const u8) Error!u32 {
        var hbuf: [1024]u8 = undefined;
        var h: Writer = .{ .buf = &hbuf };
        try h.byte('l');
        try h.byte(kind);
        try h.byte(flag_no_reply);
        try h.byte(1);
        try h.u32_(@intCast(body.len));
        const serial = c.serial;
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        try h.u32_(serial);
        const fields = try h.beginArray(8);
        try h.pad(8);
        try h.byte(5); // REPLY_SERIAL
        try h.signature("u");
        try h.u32_(to.serial);
        if (to.sender.len > 0) {
            try h.pad(8);
            try h.byte(6); // DESTINATION
            try h.signature("s");
            try h.string(to.sender);
        }
        if (error_name) |e| {
            try h.pad(8);
            try h.byte(4); // ERROR_NAME
            try h.signature("s");
            try h.string(e);
        }
        if (sig.len > 0) {
            try h.pad(8);
            try h.byte(8); // SIGNATURE
            try h.signature("g");
            try h.signature(sig);
        }
        h.endArray(fields);
        try h.pad(8);
        try c.writeAll(h.written());
        try c.writeAll(body);
        return serial;
    }
};

/// The socket path of a `unix:path=...` address (the first one listed).
/// A property's value, as `Conn.getProperty` returns it.
pub const Value = union(enum) {
    boolean: bool,
    /// Also object paths.
    string: []const u8,
    /// `i` and `u` (an `i` keeps its bits: -1 is 0xffffffff).
    int: u32,
    other,
};

fn readVariant(r: *Reader) Error!Value {
    const sig = try r.signature();
    if (sig.len != 1) return .other;
    return switch (sig[0]) {
        'b' => .{ .boolean = try r.boolean() },
        's', 'o' => .{ .string = try r.string() },
        'i', 'u' => .{ .int = try r.u32_() },
        else => .other,
    };
}

fn unixPath(address: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, address, ';');
    while (it.next()) |a| {
        if (!std.mem.startsWith(u8, a, "unix:")) continue;
        var kv = std.mem.splitScalar(u8, a["unix:".len..], ',');
        while (kv.next()) |pair| if (std.mem.startsWith(u8, pair, "path=")) return pair["path=".len..];
    }
    return null;
}

test "a string that isn't valid UTF-8 goes out mended, with its mended length" {
    var buf: [64]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.byte(1); // so the length needs padding first
    try w.string("caf\xe9 ok");
    var r: Reader = .{ .body = w.written() };
    _ = try r.byte();
    try std.testing.expectEqualStrings("caf\u{fffd} ok", try r.string());
    try std.testing.expectEqual(w.len, r.pos);
    try std.testing.expect(std.unicode.utf8ValidateSlice(w.written()[8..]));
}

test unixPath {
    try std.testing.expectEqualStrings("/run/user/1000/bus", unixPath("unix:path=/run/user/1000/bus").?);
    try std.testing.expectEqualStrings("/tmp/x", unixPath("unix:guid=abc,path=/tmp/x;tcp:host=h").?);
    try std.testing.expectEqual(@as(?[]const u8, null), unixPath("unix:abstract=/tmp/dbus-XYZ"));
}

test "notify arguments marshal in signature order with D-Bus alignment" {
    var buf: [256]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.string("z"); // 0: len 1, 'z', NUL -> 6 bytes
    try w.u32_(7); // pads to 8
    w.endArray(try w.beginArray(8)); // empty a{sv}: length 0, then pad to 8
    const want = [_]u8{ 1, 0, 0, 0, 'z', 0, 0, 0, 7, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqualSlices(u8, &want, w.written());
}

test "values of any type are skipped, variants included" {
    // a{sv} with {"uris": <["file:///a"]>, "n": <uint32 7>}, then a string.
    var buf: [256]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    const a = try w.beginArray(8);
    try w.pad(8);
    try w.string("uris");
    try w.signature("as");
    const inner = try w.beginArray(4);
    try w.string("file:///a");
    w.endArray(inner);
    try w.pad(8);
    try w.string("n");
    try w.signature("u");
    try w.u32_(7);
    w.endArray(a);
    try w.string("after");
    var r: Reader = .{ .body = w.written() };
    try r.skip("a{sv}");
    try std.testing.expectEqualStrings("after", try r.string());
}

test "property values read back from their variants" {
    var buf: [64]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.signature("b");
    try w.u32_(1);
    var r: Reader = .{ .body = w.written() };
    try std.testing.expectEqual(Value{ .boolean = true }, try readVariant(&r));

    w = .{ .buf = &buf };
    try w.signature("s");
    try w.string("power-saver");
    r = .{ .body = w.written() };
    try std.testing.expectEqualStrings("power-saver", (try readVariant(&r)).string);

    w = .{ .buf = &buf };
    try w.signature("i");
    try w.i32_(2);
    r = .{ .body = w.written() };
    try std.testing.expectEqual(Value{ .int = 2 }, try readVariant(&r));

    w = .{ .buf = &buf };
    try w.signature("ad");
    r = .{ .body = w.written() };
    try std.testing.expectEqual(Value.other, try readVariant(&r));
}

test "a call from a hook during another call is refused, and the outer call gets its reply" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds));
    var us: Conn = .{ .fd = fds[0] };
    defer us.close();
    var bus: Conn = .{ .fd = fds[1] };
    defer bus.close();

    // Queued before the call: a signal (as KDE's portal sends on focus), then the reply to serial 1.
    try bus.signal("/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged", "", "");
    try bus.reply(.{ .kind = msg_method_call, .serial = 1, .body = "" }, "u", &.{ 7, 0, 0, 0 });
    _ = linux.shutdown(fds[1], linux.SHUT.WR); // a lost reply fails the read instead of hanging

    const Probe = struct {
        inner: ?Error = null,
        fn onMessage(ctx: *anyopaque, c: *Conn, _: Message) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = c.call("x.y", "/", "x.y", "Inner", "", "") catch |e| {
                self.inner = e;
            };
        }
    };
    var probe: Probe = .{};
    us.hook = .{ .ctx = &probe, .func = Probe.onMessage };
    const answer = try us.call("x.y", "/", "x.y", "Outer", "", "");
    try std.testing.expectEqual(@as(?Error, error.Reentered), probe.inner);
    var r: Reader = .{ .body = answer };
    try std.testing.expectEqual(@as(u32, 7), try r.u32_());
    try std.testing.expect(!us.calling);
}
