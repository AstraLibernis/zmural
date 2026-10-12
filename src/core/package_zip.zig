// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Importing a wallpaper from a `.zip`: a zmural package (`zmural.toml` and
//! the files it names) or plain videos and pictures.
//!
//! What a package shows is the user's call, as with any file they download
//! (owner, 2026-10-02). Unpacking it safely is ours. A zip comes from
//! anywhere, so `check` reads only its directory and refuses it before
//! anything is written when:
//! - a name could land outside the new folder, or be read differently by
//!   Windows or Linux: absolute, a drive (`C:`), `..`, a stream (`a:b`), a
//!   reserved device name (`CON`), a trailing dot or space, control bytes;
//! - an entry is a link, or encrypted, or compressed in a way we can't read;
//! - there are too many files, or they add up to more than any live
//!   wallpaper needs, or they unpack to many times the zip's own size, as a
//!   zip bomb does (and no entry is written beyond the size it declares);
//! - it holds nothing that can be a wallpaper.
//! `unpack` then writes into a hidden folder beside the target, checks each
//! file against its CRC, checks a package's manifest, and only then renames
//! the folder into place. A failed import leaves nothing behind.

const std = @import("std");
const zip = std.zip;
const Io = std.Io;
const manifest = @import("manifest.zig");
const media = @import("media.zig");
const lively = @import("lively.zig");

/// Sized from what live wallpapers are, plus room to spare: a long 4K video
/// loop is a GiB or two, and a web wallpaper is a few thousand files at most.
pub const Limits = struct {
    /// Files and folders, each.
    max_files: u32 = 10_000,
    /// What the files may add up to, unpacked. Also the most `export` can
    /// write (a zip without zip64 stops at 4 GiB).
    max_bytes: u64 = 4 << 30,
    /// Videos and pictures are compressed already and barely shrink in a zip;
    /// a page's text shrinks a few times. A zip that unpacks to more than
    /// this many times its packed size is a bomb...
    max_ratio: u64 = 20,
    /// ...unless it unpacks to no more than this (a few uncompressed pictures
    /// or sounds can shrink a lot without being a danger).
    ratio_floor: u64 = 256 << 20,
};

pub const Error = error{
    NotAZip,
    Encrypted,
    UnsupportedCompression,
    BadName,
    NameEncoding,
    SameName,
    Link,
    TooManyFiles,
    TooLarge,
    Overlap,
    Inflated,
    Empty,
    LivelyBadInfo,
    LivelyBadProperties,
    LivelyProgram,
    LivelyWebAddress,
    LivelyStream,
    LivelyOutside,
    NothingPlayable,
    BadManifest,
    MissingEntry,
    Corrupt,
    Changed,
    CantWrite,
    OutputExists,
    NotAWallpaper,
    OutOfMemory,
};

/// The entry a refusal is about, when there is one.
pub const Diagnostic = struct {
    name_buf: [512]u8 = undefined,
    name_len: usize = 0,
    /// From the OS or the parser, when the error came from one.
    cause: ?anyerror = null,

    pub fn name(d: *const Diagnostic) []const u8 {
        return d.name_buf[0..d.name_len];
    }

    fn set(d: *Diagnostic, n: []const u8) void {
        d.name_len = @min(n.len, d.name_buf.len);
        @memcpy(d.name_buf[0..d.name_len], n[0..d.name_len]);
    }
};

/// `lively`: a Lively Wallpaper package, given a `zmural.toml` as it is unpacked.
pub const Kind = enum { package, lively, media };

/// What `check` found.
pub const Checked = struct {
    /// The one top folder every entry is in ("" when there isn't one); it is
    /// left out when unpacking, so the zip's own folder doesn't nest.
    root: []const u8,
    kind: Kind,
    files: u32,
    bytes: u64,
};

/// One line for the user per refusal.
pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.NotAZip => "it isn't a zip file zmural can read",
        error.Encrypted => "it is password-protected",
        error.UnsupportedCompression => "it uses a compression zmural can't read (only stored and deflate)",
        error.BadName => "a name in it could land outside its folder or means something else on another system",
        error.NameEncoding => "a file name in it isn't UTF-8 (an older zip tool made it); zip the files again with a newer one",
        error.SameName => "two files in it would get the same name here (they differ only in upper and lower case)",
        error.Link => "it holds a link, and links aren't unpacked",
        error.TooManyFiles => "it holds too many files and folders",
        error.TooLarge => "its files add up to too much",
        error.Overlap => "its files overlap inside it, a trick that makes a small zip unpack into a huge one",
        error.Inflated => "it would unpack to many times its own size, as a zip bomb does",
        error.Empty => "it is empty",
        error.LivelyBadInfo => "its LivelyInfo.json can't be read",
        error.LivelyBadProperties => "its LivelyProperties.json can't be read",
        error.LivelyProgram => "it is a Lively wallpaper that runs a program, and zmural never runs programs as wallpapers",
        error.LivelyWebAddress => "it is a Lively wallpaper of a web address; zmural shows only pages saved on this computer",
        error.LivelyStream => "it is a Lively video stream; zmural shows only files on this computer",
        error.LivelyOutside => "its LivelyInfo.json names a file outside the package",
        error.NothingPlayable => "it holds no zmural.toml and no video, picture or page at its top",
        error.BadManifest => "its zmural.toml is not valid",
        error.MissingEntry => "its zmural.toml names a file that isn't in it",
        error.Corrupt => "it is damaged (a file is cut short or fails its checksum)",
        error.Changed => "a file changed while it was being packed; try again once nothing is writing to it",
        error.CantWrite => "a file or folder can't be read or written",
        error.OutputExists => "that zip already exists; give another name",
        error.NotAWallpaper => "that isn't a wallpaper file, a package or a folder of them",
        error.OutOfMemory => "out of memory",
    };
}

/// Reads the zip's directory and checks every entry; writes nothing.
pub fn check(arena: std.mem.Allocator, fr: *Io.File.Reader, limits: Limits, diag: *Diagnostic) Error!Checked {
    var it = zip.Iterator.init(fr) catch return error.NotAZip;
    var names: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var bytes: u64 = 0;
    var packed_bytes: u64 = 0;
    var files: u32 = 0;
    // Folders count too: 300,000 empty ones are no wallpaper either.
    var entries: u32 = 0;
    // Where each entry lies in the zip, to refuse entries that share data.
    var spans: std.ArrayList(Span) = .empty;
    while (true) {
        const entry = (it.next() catch |err| return mapIterError(err)) orelse break;
        // Its local header, its name, its data (the extra field is left out:
        // a lower bound is enough to see two entries share bytes).
        const end = std.math.add(u64, entry.file_offset, @sizeOf(zip.LocalFileHeader) + @as(u64, entry.filename_len) + entry.compressed_size) catch return error.NotAZip;
        try spans.append(arena, .{ .start = entry.file_offset, .end = end });
        const info = readCentral(arena, fr, entry) catch return error.NotAZip;
        diag.set(info.name);
        // Names are written as they are: on Windows a name that isn't UTF-8
        // can't be made at all, and elsewhere it would land as raw bytes.
        if (!std.unicode.utf8ValidateSlice(info.name)) return error.NameEncoding;
        if (info.name.len == 0 or !safePath(info.name)) return error.BadName;
        if (info.link) return error.Link;
        switch (entry.compression_method) {
            .store, .deflate => {},
            else => return error.UnsupportedCompression,
        }
        entries += 1;
        if (entries > limits.max_files) return error.TooManyFiles;
        if (!isDir(info.name)) {
            files += 1;
            bytes = std.math.add(u64, bytes, entry.uncompressed_size) catch return error.TooLarge;
            if (bytes > limits.max_bytes) return error.TooLarge;
            packed_bytes +|= entry.compressed_size;
        } else if (entry.uncompressed_size != 0) return error.BadName;
        // Two names that differ only in case are one file on Windows.
        const folded = try std.ascii.allocLowerString(arena, std.mem.trimEnd(u8, info.name, "/"));
        if ((try seen.getOrPut(arena, folded)).found_existing) return error.SameName;
        try names.append(arena, info.name);
    }
    diag.name_len = 0;
    // std.zip reads each entry from where the directory says, so entries
    // pointing at the same bytes would each unpack them in full.
    std.mem.sort(Span, spans.items, {}, Span.lessThan);
    if (files == 0) return error.Empty; // also a zip with no entries at all: nothing below may assume one
    if (bytes > limits.ratio_floor and bytes / limits.max_ratio > packed_bytes) return error.Inflated;
    for (spans.items[0 .. spans.items.len - 1], spans.items[1..]) |a, b| {
        if (b.start < a.end) return error.Overlap;
    }
    const root = commonRoot(names.items);
    const kind = try kindOf(names.items, root);
    return .{ .root = root, .kind = kind, .files = files, .bytes = bytes };
}

pub const Unpacked = struct {
    /// The new folder's name in `parent`.
    name: []const u8,
    /// A Lively package's settings that have no counterpart, as "name (type)".
    left_out: []const []const u8 = &.{},
};

/// Unpacks a checked zip into `parent`, as a new folder named `name` (or
/// `name (2)`... when taken).
pub fn unpack(arena: std.mem.Allocator, io: Io, fr: *Io.File.Reader, checked: Checked, parent: Io.Dir, name: []const u8, diag: *Diagnostic) Error!Unpacked {
    var left_out: []const []const u8 = &.{};
    // Its own name each time: on Windows a folder just deleted (an earlier
    // import's) can linger, pending deletion, and refuse to be reused.
    // Not named after the wallpaper, so a long name can't make it too long.
    var tag: [8]u8 = undefined;
    io.random(&tag);
    const tmp = try std.fmt.allocPrint(arena, ".zmural-import-{x}", .{&tag});
    parent.createDir(io, tmp, .default_dir) catch |err| return cantWrite(diag, err);
    var ok = false;
    defer if (!ok) parent.deleteTree(io, tmp) catch {}; // zsnag:ok — best effort; it is hidden, and the library skips hidden folders
    {
        var dest = parent.openDir(io, tmp, .{}) catch |err| return cantWrite(diag, err);
        defer dest.close(io);
        var it = zip.Iterator.init(fr) catch return error.NotAZip;
        var name_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        while (true) {
            const entry = (it.next() catch |err| return mapIterError(err)) orelse break;
            entry.extract(fr, .{ .allow_backslashes = true }, &name_buf, dest) catch |err| {
                diag.set(name_buf[0..@min(entry.filename_len, name_buf.len)]);
                diag.cause = err;
                return switch (err) {
                    error.ZipDecompressTruncated, error.EndOfStream, error.ReadFailed => error.Corrupt,
                    error.ZipBadFilename, error.ZipFilenameHasBackslash => error.BadName,
                    // Two names `check` couldn't fold together (non-ASCII case
                    // on Windows and macOS) landed on one file.
                    error.PathAlreadyExists => error.SameName,
                    error.UnsupportedCompressionMethod => error.UnsupportedCompression,
                    else => if (std.mem.startsWith(u8, @errorName(err), "Zip")) error.Corrupt else error.CantWrite,
                };
            };
            const path = name_buf[0..entry.filename_len];
            if (isDir(path)) continue;
            diag.set(path);
            if (try crcOf(io, dest, path, diag) != entry.crc32) return error.Corrupt;
        }
        diag.name_len = 0;
        if (checked.kind == .lively) left_out = try fromLively(arena, io, dest, checked.root, name, diag);
        if (checked.kind != .media) try checkManifest(arena, io, dest, checked.root, diag);
    }
    const final = try freeName(arena, io, parent, name);
    const from = if (checked.root.len > 0) try std.fs.path.join(arena, &.{ tmp, checked.root }) else tmp;
    try renamePatiently(io, parent, from, final, diag);
    ok = true;
    if (checked.root.len > 0) parent.deleteTree(io, tmp) catch {}; // zsnag:ok — only the emptied wrapper is left
    return .{ .name = final, .left_out = left_out };
}

/// The folder name to suggest: the zip's own top folder, else its file name
/// without `.zip`; "Imported wallpaper" when that wouldn't be a safe name.
pub fn folderName(zip_path: []const u8, checked: Checked) []const u8 {
    var n = if (checked.root.len > 0) checked.root else std.fs.path.basename(zip_path);
    if (checked.root.len == 0 and std.ascii.endsWithIgnoreCase(n, ".zip")) n = n[0 .. n.len - 4];
    return if (n.len > 0 and n[0] != '.' and safeComponent(n)) n else "Imported wallpaper";
}

// ---- checks -------------------------------------------------------------------------------

const Central = struct { name: []const u8, link: bool };

/// The entry's name (backslashes as slashes) and whether it is a link, from
/// its central directory record.
const Span = struct {
    start: u64,
    end: u64,

    fn lessThan(_: void, a: Span, b: Span) bool {
        return a.start < b.start;
    }
};

fn readCentral(arena: std.mem.Allocator, fr: *Io.File.Reader, entry: zip.Iterator.Entry) !Central {
    try fr.seekTo(entry.header_zip_offset);
    const h = try fr.interface.takeStruct(zip.CentralDirectoryFileHeader, .little);
    const name = try arena.alloc(u8, h.filename_len);
    try fr.interface.readSliceAll(name);
    std.mem.replaceScalar(u8, name, '\\', '/');
    // Made on Unix (high byte 3): the top 16 bits are the file's mode.
    const unix = h.version_made_by >> 8 == 3;
    const mode = h.external_file_attributes >> 16;
    return .{ .name = name, .link = unix and mode & 0o170000 == 0o120000 };
}

fn mapIterError(err: anyerror) Error {
    return switch (err) {
        error.ZipEncryptionUnsupported => error.Encrypted,
        else => error.NotAZip,
    };
}

fn cantWrite(diag: *Diagnostic, err: anyerror) Error {
    diag.cause = err;
    return error.CantWrite;
}

fn isDir(name: []const u8) bool {
    return name[name.len - 1] == '/';
}

/// A relative path (slashes only) whose every part is a safe name; a
/// directory's ends in one slash.
pub fn safePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 512 or path[0] == '/') return false;
    const body = if (isDir(path)) path[0 .. path.len - 1] else path;
    var parts = std.mem.splitScalar(u8, body, '/');
    var depth: usize = 0;
    while (parts.next()) |part| {
        if (!safeComponent(part)) return false;
        depth += 1;
        if (depth > 16) return false;
    }
    return true;
}

/// One file or folder name that means the same, and stays put, on Windows
/// and Linux.
pub fn safeComponent(part: []const u8) bool {
    if (part.len == 0 or part.len > 255) return false;
    if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    for (part) |c| if (c < 0x20 or c == 0x7f or std.mem.findScalar(u8, "\\/:*?\"<>|", c) != null) return false;
    // Windows drops trailing dots and spaces: "a." would become "a", and "..." would be "..".
    if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
    // Device names, with any extension ("con.txt" is the console on Windows).
    const stem = part[0 .. std.mem.findScalar(u8, part, '.') orelse part.len];
    const devices = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" };
    for (devices) |d| if (std.ascii.eqlIgnoreCase(stem, d)) return false;
    if (stem.len == 4 and (std.ascii.startsWithIgnoreCase(stem, "COM") or std.ascii.startsWithIgnoreCase(stem, "LPT")) and std.ascii.isDigit(stem[3])) return false;
    return true;
}

/// The single top folder every entry is under, or "".
fn commonRoot(names: []const []const u8) []const u8 {
    const first = names[0];
    const slash = std.mem.findScalar(u8, first, '/') orelse return "";
    const root = first[0..slash];
    for (names) |n| {
        if (n.len <= root.len or n[root.len] != '/' or !std.mem.eql(u8, n[0..root.len], root)) return "";
    }
    // A single folder entry with nothing in it is caught as Empty before this.
    return root;
}

/// A package if `zmural.toml` is at the top (after the root), plain media
/// if something playable is.
fn kindOf(names: []const []const u8, root: []const u8) Error!Kind {
    var playable = false;
    var is_lively = false;
    for (names) |full| {
        const n = if (root.len > 0) full[root.len + 1 ..] else full;
        if (n.len == 0 or std.mem.findScalar(u8, n, '/') != null) continue; // not at the top
        if (std.mem.eql(u8, n, media.package_manifest)) return .package;
        if (std.ascii.eqlIgnoreCase(n, lively.info_file)) is_lively = true;
        if (media.isPlayable(n)) playable = true;
    }
    if (is_lively) return .lively;
    if (!playable) return error.NothingPlayable;
    return .media;
}

/// Adds one file to `z`, which must be the same bytes `size` and `crc` were
/// read from: a file changed in between (written to, grown, cut short) is
/// refused, rather than packed into a zip that later fails its checksum.
fn packFile(io: Io, z: *ZipWriter, dir: Io.Dir, rel: []const u8, name: []const u8, size: u64, crc: u32, bufs: []u8, diag: *Diagnostic) Error!void {
    const in = dir.openFile(io, rel, .{}) catch |err| return cantWrite(diag, err);
    defer in.close(io);
    const half = bufs.len / 2;
    var fr = in.reader(io, bufs[0..half]);
    var hashed = fr.interface.hashed(std.hash.Crc32.init(), bufs[half..]);
    z.add(name, crc, size, &hashed.reader, null) catch |err| return switch (err) {
        error.TooLarge => error.TooLarge,
        error.TooManyFiles => error.TooManyFiles,
        error.EndOfStream => error.Changed,
        else => cantWrite(diag, err),
    };
    if (hashed.hasher.final() != crc) return error.Changed;
    // Grown: more is there than was packed.
    var probe: [1]u8 = undefined;
    if ((hashed.reader.readSliceShort(&probe) catch |err| return cantWrite(diag, err)) != 0) return error.Changed;
}

fn crcOf(io: Io, dir: Io.Dir, path: []const u8, diag: *Diagnostic) Error!u32 {
    const f = dir.openFile(io, path, .{}) catch |err| return cantWrite(diag, err);
    defer f.close(io);
    var crc: std.hash.Crc32 = .init();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = f.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return cantWrite(diag, err),
        };
        if (n == 0) break;
        crc.update(buf[0..n]);
    }
    return crc.final();
}

fn checkManifest(arena: std.mem.Allocator, io: Io, dest: Io.Dir, root: []const u8, diag: *Diagnostic) Error!void {
    const path = if (root.len > 0) try std.fs.path.join(arena, &.{ root, media.package_manifest }) else media.package_manifest;
    diag.set(path);
    const text = dest.readFileAlloc(io, path, arena, .limited(256 * 1024)) catch |err| return cantWrite(diag, err);
    const m = manifest.parse(arena, text, null) catch |err| {
        diag.cause = err;
        return error.BadManifest;
    };
    const entry = try manifest.entryPath(arena, root, m.entry);
    diag.set(entry);
    // Opened, not `access`ed: it must be a file that reads (and Wine's
    // dir-relative access fails on nested paths, which hid the tests there).
    const f = dest.openFile(io, entry, .{}) catch return error.MissingEntry;
    f.close(io);
    diag.name_len = 0;
}

/// Windows refuses to rename a folder while something holds it open, as
/// Defender or the search indexer do for a moment after files are written:
/// try again for up to 2 s before giving up.
fn renamePatiently(io: Io, parent: Io.Dir, from: []const u8, to: []const u8, diag: *Diagnostic) Error!void {
    var tries: u8 = 0;
    while (true) : (tries += 1) {
        parent.rename(from, parent, to, io) catch |err| {
            if (err == error.AccessDenied and tries < 20) {
                io.sleep(.fromMilliseconds(100), .awake) catch {}; // zsnag:ok — cancelled: the next try comes sooner, that's all
                continue;
            }
            return cantWrite(diag, err);
        };
        return;
    }
}

/// Writes a `zmural.toml` for the Lively package unpacked in `dest` (under
/// `root`); returns the settings it left out.
fn fromLively(arena: std.mem.Allocator, io: Io, dest: Io.Dir, root: []const u8, title: []const u8, diag: *Diagnostic) Error![]const []const u8 {
    const info_path = try std.fs.path.join(arena, &.{ root, lively.info_file });
    diag.set(info_path);
    // The zip may spell it "livelyinfo.json": find it as it is spelled.
    const info = readTop(arena, io, dest, root, lively.info_file) catch |err| return cantWrite(diag, err);
    const props = readTop(arena, io, dest, root, lively.properties_file) catch null;
    const c = lively.convert(arena, info, props, title) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => |e| e,
    };
    const out = try std.fs.path.join(arena, &.{ root, media.package_manifest });
    dest.writeFile(io, .{ .sub_path = out, .data = c.toml }) catch |err| return cantWrite(diag, err);
    diag.name_len = 0;
    return c.left_out;
}

/// A file at the top of the package, its name matched ignoring case.
fn readTop(arena: std.mem.Allocator, io: Io, dest: Io.Dir, root: []const u8, name: []const u8) ![]u8 {
    var dir = try dest.openDir(io, if (root.len > 0) root else ".", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.ascii.eqlIgnoreCase(e.name, name))
            return dir.readFileAlloc(io, e.name, arena, .limited(1024 * 1024));
    }
    return error.FileNotFound;
}

/// Whether `name` in `dir` is taken, by a folder or a file. By opening it:
/// under Wine a dir-relative `access` says FileNotFound for what is there.
fn exists(io: Io, dir: Io.Dir, name: []const u8) Error!bool {
    if (dir.openDir(io, name, .{})) |d| {
        d.close(io);
        return true;
    } else |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir => return true,
        else => return error.CantWrite,
    }
}

/// `name`, or `name (2)`, `name (3)`... whichever doesn't exist yet in `parent`.
fn freeName(arena: std.mem.Allocator, io: Io, parent: Io.Dir, name: []const u8) Error![]const u8 {
    var n: u32 = 1;
    while (n < 1000) : (n += 1) {
        const candidate = if (n == 1) name else try std.fmt.allocPrint(arena, "{s} ({d})", .{ name, n });
        if (!try exists(io, parent, candidate)) return candidate;
    }
    return error.CantWrite;
}

// ---- writing ------------------------------------------------------------------------------

/// Writes a zip, every file stored (videos and pictures are compressed
/// already), streamed: `add` takes a file's CRC and size up front, so its
/// bytes can come straight from disk. Classic zip only: the whole stays
/// under 4 GiB (`error.TooLarge` otherwise; zip64 is not written).
pub const ZipWriter = struct {
    out: *Io.Writer,
    gpa: std.mem.Allocator,
    central: std.ArrayList(u8) = .empty,
    count: u16 = 0,
    pos: u64 = 0,

    pub fn deinit(z: *ZipWriter) void {
        z.central.deinit(z.gpa);
    }

    /// One entry. `data` gives exactly `size` bytes; `mode` (Unix type and
    /// permission bits) is only set by tests, to make a link.
    pub fn add(z: *ZipWriter, name: []const u8, crc: u32, size: u64, data: *Io.Reader, mode: ?u32) !void {
        if (z.count == std.math.maxInt(u16) or name.len > std.math.maxInt(u16)) return error.TooManyFiles;
        if (z.pos + 30 + name.len + size > std.math.maxInt(u32)) return error.TooLarge;
        const offset: u32 = @intCast(z.pos);
        const w = z.out;
        try w.writeAll(&zip.local_file_header_sig);
        try header(w, 20, crc, @intCast(size), @intCast(name.len));
        try w.writeInt(u16, 0, .little); // extra
        try w.writeAll(name);
        try data.streamExact64(w, size);
        z.pos += 30 + name.len + size;

        var c: Io.Writer.Allocating = .fromArrayList(z.gpa, &z.central);
        defer z.central = c.toArrayList();
        const cw = &c.writer;
        try cw.writeAll(&zip.central_file_header_sig);
        try cw.writeInt(u16, if (mode != null) 3 << 8 | 20 else 20, .little); // made by (3: Unix)
        try header(cw, 20, crc, @intCast(size), @intCast(name.len));
        try cw.writeInt(u16, 0, .little); // extra
        try cw.writeInt(u16, 0, .little); // comment
        try cw.writeInt(u16, 0, .little); // disk
        try cw.writeInt(u16, 0, .little); // internal attributes
        try cw.writeInt(u32, (mode orelse 0) << 16, .little);
        try cw.writeInt(u32, offset, .little);
        try cw.writeAll(name);
        z.count += 1;
    }

    /// The central directory and the end record.
    pub fn finish(z: *ZipWriter) !void {
        if (z.pos + z.central.items.len > std.math.maxInt(u32)) return error.TooLarge;
        const w = z.out;
        try w.writeAll(z.central.items);
        try w.writeAll(&zip.end_record_sig);
        try w.writeInt(u32, 0, .little); // disk numbers
        try w.writeInt(u16, z.count, .little);
        try w.writeInt(u16, z.count, .little);
        try w.writeInt(u32, @intCast(z.central.items.len), .little);
        try w.writeInt(u32, @intCast(z.pos), .little);
        try w.writeInt(u16, 0, .little); // comment
    }

    /// From "version needed" to the name's length, the same in both records.
    fn header(w: *Io.Writer, version: u16, crc: u32, size: u32, name_len: u16) !void {
        try w.writeInt(u16, version, .little);
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // stored
        try w.writeInt(u32, 0, .little); // time, date
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, size, .little); // compressed
        try w.writeInt(u32, size, .little);
        try w.writeInt(u16, name_len, .little);
    }
};

pub const Exported = struct { files: u32, bytes: u64 };

/// Packs a wallpaper into a new zip at `out_path`, written beside it and
/// renamed when complete: a package (its folder, or its `zmural.toml`) or
/// any folder as one top folder named like it, or a single file on its own.
/// Every name must be one `check` takes, so an export always imports.
pub fn exportTo(gpa: std.mem.Allocator, io: Io, source: []const u8, out_path: []const u8, limits: Limits, diag: *Diagnostic) Error!Exported {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = Io.Dir.cwd();
    if (cwd.access(io, out_path, .{})) |_| return error.OutputExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return cantWrite(diag, err),
    }

    // What to pack, by path relative to `base`, and the names they get in the zip.
    const is_manifest = std.ascii.eqlIgnoreCase(std.fs.path.basename(source), media.package_manifest);
    const folder: ?[]const u8 = if (is_manifest) std.fs.path.dirname(source) orelse return error.NotAWallpaper else blk: {
        const st = cwd.statFile(io, source, .{}) catch |err| return cantWrite(diag, err);
        break :blk if (st.kind == .directory) source else null;
    };
    var files: std.ArrayList(struct { rel: []const u8, name: []const u8, size: u64 }) = .empty;
    if (folder == null and !media.isPlayable(source)) return error.NotAWallpaper;
    var base_dir = cwd.openDir(io, folder orelse std.fs.path.dirname(source) orelse ".", .{ .iterate = folder != null }) catch |err| return cantWrite(diag, err);
    defer base_dir.close(io);
    if (folder) |f| {
        const root = std.fs.path.basename(f);
        var walker = try base_dir.walk(arena);
        defer walker.deinit();
        while (walker.next(io) catch |err| return cantWrite(diag, err)) |e| {
            const rel = try arena.dupe(u8, e.path);
            if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, rel, std.fs.path.sep, '/');
            switch (e.kind) {
                .directory => continue,
                .file => {},
                else => {
                    diag.set(rel);
                    return error.Link;
                },
            }
            const st = e.dir.statFile(io, e.basename, .{}) catch |err| return cantWrite(diag, err);
            try files.append(arena, .{ .rel = rel, .name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel }), .size = st.size });
        }
    } else {
        const st = cwd.statFile(io, source, .{}) catch |err| return cantWrite(diag, err);
        const name = std.fs.path.basename(source);
        try files.append(arena, .{ .rel = name, .name = name, .size = st.size });
    }
    if (files.items.len == 0) return error.Empty;

    // The same rules as `check`, so what is written can be read back.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var bytes: u64 = 0;
    for (files.items) |f| {
        diag.set(f.name);
        if (!safePath(f.name)) return error.BadName;
        if ((try seen.getOrPut(arena, try std.ascii.allocLowerString(arena, f.name))).found_existing) return error.SameName;
        bytes += f.size;
        if (bytes > limits.max_bytes) return error.TooLarge;
    }
    if (files.items.len > limits.max_files) return error.TooManyFiles;
    diag.name_len = 0;
    if (folder) |f| if (!is_manifest) {
        // A folder that isn't a package must hold something that shows.
        var names = try arena.alloc([]const u8, files.items.len);
        for (files.items, 0..) |x, k| names[k] = x.name;
        _ = kindOf(names, std.fs.path.basename(f)) catch |err| switch (err) {
            error.NothingPlayable => return error.NotAWallpaper,
            else => {},
        };
    };

    const tmp = try std.fmt.allocPrint(arena, "{s}.part", .{out_path});
    const out = cwd.createFile(io, tmp, .{ .exclusive = true }) catch |err| return cantWrite(diag, err);
    var done = false;
    defer if (!done) cwd.deleteFile(io, tmp) catch {}; // zsnag:ok — a half-written zip goes; nothing else to do if it won't
    {
        defer out.close(io);
        var out_buf: [64 * 1024]u8 = undefined;
        var fw = out.writer(io, &out_buf);
        var z: ZipWriter = .{ .out = &fw.interface, .gpa = arena };
        const bufs = try arena.alloc(u8, 2 * 64 * 1024);
        for (files.items) |f| {
            diag.set(f.rel);
            const crc = try crcOf(io, base_dir, f.rel, diag);
            try packFile(io, &z, base_dir, f.rel, f.name, f.size, crc, bufs, diag);
        }
        z.finish() catch |err| return if (err == error.TooLarge) error.TooLarge else cantWrite(diag, err);
        fw.interface.flush() catch |err| return cantWrite(diag, err);
    }
    diag.name_len = 0;
    cwd.rename(tmp, cwd, out_path, io) catch |err| return cantWrite(diag, err);
    done = true;
    return .{ .files = @intCast(files.items.len), .bytes = bytes };
}

/// A file to store in a zip from memory (tests).
pub const Stored = struct { name: []const u8, data: []const u8, mode: ?u32 = null };

pub fn writeStored(gpa: std.mem.Allocator, w: *Io.Writer, entries: []const Stored) !void {
    var z: ZipWriter = .{ .out = w, .gpa = gpa };
    defer z.deinit();
    for (entries) |e| {
        var r: Io.Reader = .fixed(e.data);
        try z.add(e.name, std.hash.Crc32.hash(e.data), e.data.len, &r, e.mode);
    }
    try z.finish();
}

// ---- tests --------------------------------------------------------------------------------

test safeComponent {
    for ([_][]const u8{ "rain.mp4", "Neon Rain", "a.b.c", "café", "COM10", "console.txt" }) |ok|
        try std.testing.expect(safeComponent(ok));
    for ([_][]const u8{ "", ".", "..", "...", "a.", "a ", "C:", "a:b", "x\\y", "nul", "CON.txt", "com1", "LPT9.log", "CONIN$", "a\x01b", "a*b" }) |bad|
        try std.testing.expect(!safeComponent(bad));
}

test safePath {
    try std.testing.expect(safePath("pkg/zmural.toml"));
    try std.testing.expect(safePath("pkg/"));
    for ([_][]const u8{ "/etc/passwd", "../x", "a/../../x", "a//b", "a/./b", "C:/x", "a/b/", "x" ** 513 }) |bad| {
        if (std.mem.eql(u8, bad, "a/b/")) continue; // a directory: fine
        try std.testing.expect(!safePath(bad));
    }
    try std.testing.expect(!safePath("a/" ** 17 ++ "f"));
}

test commonRoot {
    try std.testing.expectEqualStrings("pkg", commonRoot(&.{ "pkg/", "pkg/zmural.toml", "pkg/a/b.png" }));
    try std.testing.expectEqualStrings("", commonRoot(&.{ "pkg/zmural.toml", "other.png" }));
    try std.testing.expectEqualStrings("", commonRoot(&.{ "pkg", "pkg/x" })); // a file named like the folder
    try std.testing.expectEqualStrings("", commonRoot(&.{"rain.mp4"}));
}

test kindOf {
    try std.testing.expectEqual(Kind.package, try kindOf(&.{ "p/zmural.toml", "p/index.html" }, "p"));
    try std.testing.expectEqual(Kind.media, try kindOf(&.{ "rain.mp4", "notes.txt" }, ""));
    try std.testing.expectEqual(Kind.lively, try kindOf(&.{ "LivelyInfo.json", "index.html" }, ""));
    try std.testing.expectError(error.NothingPlayable, kindOf(&.{ "readme.txt", "deep/rain.mp4" }, ""));
}

/// Writes `entries` as `name` in `dir`, checks it, and unpacks it into `dir`
/// as "out"; returns the result or the refusal.
fn tryImport(arena: std.mem.Allocator, dir: Io.Dir, name: []const u8, entries: []const Stored, limits: Limits) ![]const u8 {
    const io = std.testing.io;
    {
        var buf: [4096]u8 = undefined;
        const f = try dir.createFile(io, name, .{});
        defer f.close(io);
        var fw = f.writer(io, &buf);
        try writeStored(arena, &fw.interface, entries);
        try fw.interface.flush();
    }
    const f = try dir.openFile(io, name, .{});
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var diag: Diagnostic = .{};
    const checked = try check(arena, &fr, limits, &diag);
    return (try unpack(arena, io, &fr, checked, dir, "out", &diag)).name;
}

test "a package unpacks without its top folder, and a second import gets its own name" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pkg = [_]Stored{
        .{ .name = "neon/", .data = "" },
        .{ .name = "neon/zmural.toml", .data = "title = \"Neon\"\ntype = \"video\"\nentry = \"clip/rain.webm\"\n" },
        .{ .name = "neon/clip/rain.webm", .data = "not really a video" },
    };
    try std.testing.expectEqualStrings("out", try tryImport(arena.allocator(), tmp.dir, "a.zip", &pkg, .{}));
    // Opened rather than `access`ed: Wine's dir-relative access fails on nested paths.
    (try tmp.dir.openFile(io, "out/zmural.toml", .{})).close(io);
    (try tmp.dir.openFile(io, "out/clip/rain.webm", .{})).close(io);
    try std.testing.expectEqualStrings("out (2)", try tryImport(arena.allocator(), tmp.dir, "a.zip", &pkg, .{}));
    // Nothing hidden is left behind.
    var it = tmp.dir.iterate();
    while (try it.next(io)) |e| try std.testing.expect(e.name[0] != '.');
}

test "refused before anything is written: escapes, links, size, and the wrong content" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { Error, []const Stored, Limits }{
        .{ error.BadName, &.{ .{ .name = "rain.mp4", .data = "x" }, .{ .name = "../evil.desktop", .data = "x" } }, .{} },
        .{ error.BadName, &.{.{ .name = "/tmp/evil.mp4", .data = "x" }}, .{} },
        .{ error.BadName, &.{.{ .name = "a\\..\\..\\evil.mp4", .data = "x" }}, .{} },
        .{ error.BadName, &.{.{ .name = "C:/evil.mp4", .data = "x" }}, .{} },
        .{ error.BadName, &.{.{ .name = "rain.mp4:hidden", .data = "x" }}, .{} },
        .{ error.BadName, &.{.{ .name = "CON.mp4", .data = "x" }}, .{} },
        .{ error.SameName, &.{ .{ .name = "Rain.mp4", .data = "x" }, .{ .name = "rain.mp4", .data = "y" } }, .{} },
        .{ error.NameEncoding, &.{.{ .name = "caf\x82.mp4", .data = "x" }}, .{} }, // CP437 é
        .{ error.Link, &.{ .{ .name = "rain.mp4", .data = "x" }, .{ .name = "home", .data = "/home", .mode = 0o120777 } }, .{} },
        .{ error.TooManyFiles, &.{ .{ .name = "a.mp4", .data = "x" }, .{ .name = "b.mp4", .data = "x" } }, .{ .max_files = 1 } },
        .{ error.TooManyFiles, &.{ .{ .name = "a/", .data = "" }, .{ .name = "b/", .data = "" }, .{ .name = "c.mp4", .data = "x" } }, .{ .max_files = 2 } }, // folders count
        .{ error.TooLarge, &.{.{ .name = "a.mp4", .data = "0123456789" }}, .{ .max_bytes = 9 } },
        .{ error.LivelyProgram, &.{ .{ .name = "LivelyInfo.json", .data = "{\"Type\":0,\"FileName\":\"x.exe\"}" }, .{ .name = "x.exe", .data = "MZ" } }, .{} },
        .{ error.NothingPlayable, &.{.{ .name = "readme.txt", .data = "x" }}, .{} },
        .{ error.Empty, &.{.{ .name = "only/", .data = "" }}, .{} },
        .{ error.Empty, &.{}, .{} }, // no entries at all
    };
    for (cases) |c| try std.testing.expectError(c[0], tryImport(a, tmp.dir, "bad.zip", c[1], c[2]));
    // Only the zip itself is there: no folder, no hidden leftover, nothing outside.
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| : (n += 1) try std.testing.expectEqualStrings("bad.zip", e.name);
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "entries that share their data are refused: a small zip can't unpack into a huge one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeStored(arena.allocator(), &w, &.{
        .{ .name = "a.mp4", .data = "the same video" },
        .{ .name = "b.mp4", .data = "the same video" },
    });
    const bytes = w.buffered();
    // Point the second directory entry at the first entry's data.
    const second = std.mem.findLast(u8, bytes, "PK\x01\x02").?;
    std.mem.writeInt(u32, bytes[second + 42 ..][0..4], 0, .little);
    for ([_]bool{ false, true }) |overlap| {
        const zip_bytes = if (overlap) bytes else blk: {
            var ok: Io.Writer = .fixed(buf[bytes.len..]);
            try writeStored(arena.allocator(), &ok, &.{
                .{ .name = "a.mp4", .data = "the same video" },
                .{ .name = "b.mp4", .data = "the same video" },
            });
            break :blk ok.buffered();
        };
        try tmp.dir.writeFile(io, .{ .sub_path = "o.zip", .data = zip_bytes });
        const f = try tmp.dir.openFile(io, "o.zip", .{});
        defer f.close(io);
        var rbuf: [512]u8 = undefined;
        var fr = f.reader(io, &rbuf);
        var diag: Diagnostic = .{};
        const result = check(arena.allocator(), &fr, .{}, &diag);
        if (overlap) try std.testing.expectError(error.Overlap, result) else _ = try result;
    }
}

test "a zip that unpacks to many times its own size is refused, a small one isn't" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const data = "a video of fifty bytes, which barely shrinks at all";
    const limits: Limits = .{ .max_ratio = 20, .ratio_floor = 100 };
    // The directory claims `unpacked` bytes for 51 packed ones: what a
    // deflated run of zeros looks like to `check`, which reads only that.
    const cases = [_]struct { u32, Limits, ?Error }{
        .{ data.len, limits, null }, // as packed: nothing to see
        .{ 20 * data.len, limits, null }, // just at the ratio
        .{ 20 * data.len + 20, limits, error.Inflated }, // just past it
        .{ 1 << 20, limits, error.Inflated }, // a bomb
        .{ 1 << 20, .{ .max_ratio = 20, .ratio_floor = 1 << 20 }, null }, // under the floor
    };
    for (cases) |c| {
        var buf: [512]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        try writeStored(arena.allocator(), &w, &.{.{ .name = "a.mp4", .data = data }});
        const bytes = w.buffered();
        const central = std.mem.findLast(u8, bytes, "PK\x01\x02").?;
        std.mem.writeInt(u32, bytes[central + 24 ..][0..4], c[0], .little);
        try tmp.dir.writeFile(io, .{ .sub_path = "b.zip", .data = bytes });
        const f = try tmp.dir.openFile(io, "b.zip", .{});
        defer f.close(io);
        var rbuf: [512]u8 = undefined;
        var fr = f.reader(io, &rbuf);
        var diag: Diagnostic = .{};
        const result = check(arena.allocator(), &fr, c[1], &diag);
        if (c[2]) |e| try std.testing.expectError(e, result) else try std.testing.expectEqual(@as(u64, c[0]), (try result).bytes);
    }
}

test "the limits fit real wallpapers: a 2 GiB video, a 64 MiB web page" {
    const l: Limits = .{};
    try std.testing.expect(2 << 30 <= l.max_bytes);
    // A web page's text packs to about a fifth of its size: far from the ratio.
    try std.testing.expect(64 << 20 <= l.ratio_floor and 5 < l.max_ratio);
}

test "export refuses a file that changed after it was measured" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.bin", .data = "the video bytes" });
    const crc = std.hash.Crc32.hash("the video bytes");
    var out_buf: [1024]u8 = undefined;
    const bufs = try arena.allocator().alloc(u8, 2 * 4096);
    var diag: Diagnostic = .{};
    // size, crc: as measured, rewritten in place, cut short, grown.
    const cases = [_]struct { u64, u32, ?Error }{
        .{ 15, crc, null },
        .{ 15, std.hash.Crc32.hash("the other bytes"), error.Changed },
        .{ 20, crc, error.Changed },
        .{ 9, std.hash.Crc32.hash("the video"), error.Changed },
    };
    for (cases) |c| {
        var w: Io.Writer = .fixed(&out_buf);
        var z: ZipWriter = .{ .out = &w, .gpa = arena.allocator() };
        const r = packFile(io, &z, tmp.dir, "a.bin", "a.bin", c[0], c[1], bufs, &diag);
        if (c[2]) |e| try std.testing.expectError(e, r) else try r;
    }
}

test "a package whose manifest is bad or names a missing file leaves nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingEntry, tryImport(arena.allocator(), tmp.dir, "p.zip", &.{
        .{ .name = "zmural.toml", .data = "title = \"x\"\ntype = \"video\"\nentry = \"gone.webm\"\n" },
    }, .{}));
    try std.testing.expectError(error.BadManifest, tryImport(arena.allocator(), tmp.dir, "p.zip", &.{
        .{ .name = "zmural.toml", .data = "title = \"x\"\ntype = \"video\"\nentry = \"../../etc/passwd\"\n" },
    }, .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out", .{}));
}

test "a damaged file fails its checksum and leaves nothing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeStored(arena.allocator(), &w, &.{.{ .name = "rain.mp4", .data = "the video bytes" }});
    const bytes = w.buffered();
    bytes[30 + "rain.mp4".len] ^= 0xff; // the first byte of the file's data
    try tmp.dir.writeFile(io, .{ .sub_path = "d.zip", .data = bytes });
    const f = try tmp.dir.openFile(io, "d.zip", .{});
    defer f.close(io);
    var rbuf: [512]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var diag: Diagnostic = .{};
    const checked = try check(arena.allocator(), &fr, .{}, &diag);
    try std.testing.expectError(error.Corrupt, unpack(arena.allocator(), io, &fr, checked, tmp.dir, "out", &diag));
    try std.testing.expectEqualStrings("rain.mp4", diag.name());
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "out", .{}));
    var it = tmp.dir.iterate();
    while (try it.next(io)) |e| try std.testing.expect(e.name[0] != '.');
}

test "an exported package imports back the same, and a single file on its own" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root_buf: [1024]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    try tmp.dir.createDirPath(io, "lib/Neon/media");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/Neon/zmural.toml", .data = "title = \"Neon\"\ntype = \"image\"\nentry = \"media/a.png\"\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/Neon/media/a.png", .data = "pixels" ** 1000 });
    var diag: Diagnostic = .{};
    const zip_path = try std.fs.path.join(a, &.{ root, "neon.zip" });
    const res = try exportTo(std.testing.allocator, io, try std.fs.path.join(a, &.{ root, "lib/Neon/zmural.toml" }), zip_path, .{}, &diag);
    try std.testing.expectEqual(@as(u32, 2), res.files);
    try std.testing.expectError(error.OutputExists, exportTo(std.testing.allocator, io, try std.fs.path.join(a, &.{ root, "lib/Neon" }), zip_path, .{}, &diag));

    const f = try tmp.dir.openFile(io, "neon.zip", .{});
    defer f.close(io);
    var rbuf: [4096]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    const checked = try check(a, &fr, .{}, &diag);
    try std.testing.expectEqual(Kind.package, checked.kind);
    try std.testing.expectEqualStrings("Neon", checked.root);
    try tmp.dir.createDirPath(io, "back");
    var back = try tmp.dir.openDir(io, "back", .{});
    defer back.close(io);
    try std.testing.expectEqualStrings("Neon", (try unpack(a, io, &fr, checked, back, "Neon", &diag)).name);
    const copy = try back.readFileAlloc(io, "Neon/media/a.png", a, .unlimited);
    try std.testing.expectEqualStrings("pixels" ** 1000, copy);

    // One file: no top folder; a folder with nothing playable is refused.
    _ = try exportTo(std.testing.allocator, io, try std.fs.path.join(a, &.{ root, "lib/Neon/media/a.png" }), try std.fs.path.join(a, &.{ root, "one.zip" }), .{}, &diag);
    try tmp.dir.createDirPath(io, "notes");
    try tmp.dir.writeFile(io, .{ .sub_path = "notes/readme.txt", .data = "x" });
    try std.testing.expectError(error.NotAWallpaper, exportTo(std.testing.allocator, io, try std.fs.path.join(a, &.{ root, "notes" }), try std.fs.path.join(a, &.{ root, "n.zip" }), .{}, &diag));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "n.zip", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "n.zip.part", .{}));
}
