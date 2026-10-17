// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Control protocol: UI / CLI / tray <-> zmural.
//!
//! A client sends `hello` first and gets `welcome` (or `failed`) back. After
//! that every request gets exactly one reply (`ok`, `failed`, `status`,
//! `settings` or `library`). The daemon never sends anything unasked.
//!
//! Lists (folders, app names, the library, monitors) travel as one string
//! with the items separated by `list_sep`.

const FillMode = @import("../core/layout.zig").FillMode;
const policy = @import("../core/policy.zig");

pub const version: u16 = 1;

/// Space-separated capability list sent in `welcome`.
pub const capabilities = "control.v1 apply playback mute rescan settings library properties rotation monitors";

/// The separator inside list strings: NUL, the one byte no path, file
/// name or app name can hold (a newline can be in a file name, and split it
/// in two).
pub const list_sep = 0;

/// One action per `policy.Condition`, indexed by its tag value.
pub const RuleActions = [@typeInfo(policy.Condition).@"enum".field_names.len]policy.Action;

/// An empty monitor ID means "all monitors".
pub const Target = struct { monitor: []const u8 = "" };

pub const Hello = struct { version: u16, client: []const u8 };
pub const Apply = struct { monitor: []const u8 = "", path: []const u8 };
pub const SetMuted = struct { muted: bool };
/// Asks for the library paths from `offset` on; the reply holds as many as fit.
pub const LibraryPage = struct { offset: u32 };
/// An empty monitor: the main fill mode. With a monitor: that monitor's own,
/// or (`main` true) it goes back to the main one.
pub const SetFill = struct { fill: FillMode, monitor: []const u8 = "", main: bool = false };
pub const SetVolume = struct { volume: u8 };
pub const SetRule = struct { condition: policy.Condition, action: policy.Action };
pub const SetResumeAfter = struct { ms: u32 };
pub const ListKind = enum(u8) {
    /// Executable names that pause wallpapers while in the foreground.
    app_rules,
    /// Extra library folders (the standard ones are always included).
    library_dirs,
};
pub const SetList = struct { list: ListKind, items: []const u8 };
/// The order timed changes and Next/Previous go through the library in.
pub const Order = enum(u8) {
    /// By name, wrapping around.
    sequential,
    /// Every wallpaper once per round, in a random order.
    shuffle,
    /// Any other wallpaper, each time.
    random,
};
/// The longest rotation interval: a week.
pub const max_rotate_minutes: u16 = 7 * 24 * 60;
/// Null leaves that part as it is.
pub const SetRotation = struct { minutes: ?u16 = null, order: ?Order = null };
/// `value` as the user would type it ("0.5", "true", "#ff8800", a choice, text).
pub const SetProperty = struct { name: []const u8, value: []const u8 };

pub const RequestOp = enum(u16) {
    hello = 1,
    status = 2,
    apply = 3,
    pause = 4,
    play = 5,
    set_muted = 6,
    next = 7,
    previous = 8,
    rescan = 9,
    quit = 10,
    get_settings = 11,
    library = 12,
    set_fill = 13,
    set_volume = 14,
    set_rule = 15,
    set_resume_after = 16,
    set_list = 17,
    reset_settings = 18,
    get_properties = 19,
    set_property = 20,
    reset_properties = 21,
    set_rotation = 22,
    /// The connected monitors, and which show a wallpaper of their own.
    monitors = 23,
    /// Open the settings window, or bring the open one to the front.
    open_settings = 24,
};

pub const Request = union(RequestOp) {
    hello: Hello,
    status: void,
    apply: Apply,
    pause: Target,
    play: Target,
    set_muted: SetMuted,
    next: Target,
    previous: Target,
    rescan: void,
    quit: void,
    get_settings: void,
    library: LibraryPage,
    set_fill: SetFill,
    set_volume: SetVolume,
    set_rule: SetRule,
    set_resume_after: SetResumeAfter,
    set_list: SetList,
    /// Everything back to defaults, except the wallpaper that's showing.
    reset_settings: void,
    /// The showing wallpaper's properties (empty unless it's a package).
    get_properties: void,
    set_property: SetProperty,
    /// The showing wallpaper's properties back to their defaults.
    reset_properties: void,
    /// How often the wallpaper changes by itself, and in what order.
    set_rotation: SetRotation,
    monitors: void,
    open_settings: OpenSettings,
};

/// `token`: the desktop's activation token (Linux xdg-activation), which
/// lets the window take focus; empty when there is none.
pub const OpenSettings = struct { token: []const u8 = "" };

pub const ErrorCode = enum(u16) {
    bad_request = 1,
    incompatible_version = 2,
    not_found = 3,
    unsupported = 4,
    internal = 5,
};

pub const Welcome = struct { version: u16, daemon_version: []const u8, capabilities: []const u8 };
pub const Failed = struct { code: ErrorCode, message: []const u8 };
pub const Status = struct {
    paused: bool,
    muted: bool,
    monitors: u16,
    wallpapers: u32,
    wallpaper: []const u8,
    /// Minutes between timed changes; 0 means never.
    rotate_minutes: u16 = 0,
    order: Order = .sequential,
    /// Playing time left until the next timed change (0 when rotation is off).
    next_change_s: u32 = 0,
    /// The pause rules acting now, by condition name (", " between): those
    /// that pause or stop the wallpaper, and those that mute it.
    paused_by: []const u8 = "",
    muted_by: []const u8 = "",
    /// The line to report for the last crash zmural told the user about in
    /// this run (its own last run's, or a renderer's); "" when none. A
    /// notice can go unseen (Do Not Disturb), so the window shows it too.
    crash: []const u8 = "",
    /// The last main wallpaper that reached the screen; "" before any did.
    shown: []const u8 = "",
    /// The last wallpaper that couldn't be played or shown in this run, and
    /// why; "" when none. `zmural-console apply` waits for one of the two.
    broken: []const u8 = "",
    broken_why: []const u8 = "",
    /// How the main wallpaper fills the screen; a monitor with its own fill
    /// mode says so in `Monitors`.
    fill: FillMode = .crop,
};
pub const SettingsInfo = struct {
    fill: FillMode,
    volume: u8,
    muted: bool,
    paused: bool,
    resume_after_ms: u32,
    rotate_minutes: u16,
    order: Order,
    rules: RuleActions,
    /// The rules the settings file offers; the others aren't detected yet.
    exposed: RuleExposed,
    app_rules: []const u8,
    library_dirs: []const u8,
    /// Always scanned, whatever `library_dirs` holds.
    default_dirs: []const u8,
    /// The settings file, for "open in an editor".
    file: []const u8,
};
pub const RuleExposed = [@typeInfo(policy.Condition).@"enum".field_names.len]bool;
/// `paths` holds library entries `offset ..` (list-separated); `total` is the library size.
pub const Library = struct { total: u32, offset: u32, paths: []const u8 };
/// `list` is `core/properties.writeList` output; `title` is empty when the
/// showing wallpaper isn't a package (then `list` is empty too).
pub const Properties = struct { title: []const u8, list: []const u8 };
/// One line per connected monitor (`list_sep` between them):
/// `id <tab> name <tab> WIDTHxHEIGHT <tab> its own wallpaper, or empty`
/// (`daemon/monitors.zig` writes and reads them).
pub const Monitors = struct { list: []const u8 };

/// One line of `Monitors.list`, taken apart.
pub const MonitorLine = struct { id: []const u8, name: []const u8, size: []const u8, wallpaper: []const u8, fill: []const u8 = "" };

pub fn parseMonitorLine(line: []const u8) ?MonitorLine {
    const std = @import("std");
    var it = std.mem.splitScalar(u8, line, '\t');
    const id = it.next() orelse return null;
    const name = it.next() orelse return null;
    const size = it.next() orelse return null;
    const wallpaper = it.next() orelse return null;
    return .{ .id = id, .name = name, .size = size, .wallpaper = wallpaper, .fill = it.next() orelse "" };
}

pub const EventOp = enum(u16) {
    welcome = 1,
    ok = 2,
    failed = 3,
    status = 4,
    // 5 and 6 were pushed change notices, never sent; a client would have
    // taken one for the reply to its next request.
    settings = 7,
    library = 8,
    properties = 9,
    monitors = 10,
};

pub const Event = union(EventOp) {
    welcome: Welcome,
    ok: void,
    failed: Failed,
    status: Status,
    settings: SettingsInfo,
    library: Library,
    properties: Properties,
    monitors: Monitors,
};

test "control messages round trip" {
    const std = @import("std");
    const wire = @import("wire.zig");
    var buf: [256]u8 = undefined;

    const req: Request = .{ .apply = .{ .monitor = "m-0123456789abcdef", .path = "C:\\wp\\rain" } };
    const back = try wire.decodeFrame(Request, try wire.encodeMessage(Request, req, &buf));
    try std.testing.expectEqualStrings(req.apply.path, back.apply.path);
    try std.testing.expectEqualStrings(req.apply.monitor, back.apply.monitor);

    const ev: Event = .{ .welcome = .{ .version = version, .daemon_version = "0.0.0", .capabilities = capabilities } };
    const ev_back = try wire.decodeFrame(Event, try wire.encodeMessage(Event, ev, &buf));
    try std.testing.expectEqualStrings(capabilities, ev_back.welcome.capabilities);
}

test "settings travel with every rule and list" {
    const std = @import("std");
    const wire = @import("wire.zig");
    var buf: [512]u8 = undefined;
    var rules: RuleActions = @splat(.none);
    rules[@backingInt(policy.Condition.fullscreen)] = .stop;
    var exposed: RuleExposed = @splat(false);
    exposed[@backingInt(policy.Condition.on_battery)] = true;
    const ev: Event = .{ .settings = .{
        .fill = .fit,
        .volume = 35,
        .muted = false,
        .paused = true,
        .resume_after_ms = 1200,
        .rotate_minutes = 15,
        .order = .shuffle,
        .rules = rules,
        .exposed = exposed,
        .app_rules = "eldenring.exe\nobs64.exe",
        .library_dirs = "D:\\Wallpapers",
        .default_dirs = "C:\\Users\\me\\Videos\\Wallpapers",
        .file = "C:\\Users\\me\\AppData\\Roaming\\zmural\\settings.toml",
    } };
    const back = (try wire.decodeFrame(Event, try wire.encodeMessage(Event, ev, &buf))).settings;
    try std.testing.expectEqual(policy.Action.stop, back.rules[@backingInt(policy.Condition.fullscreen)]);
    try std.testing.expect(back.exposed[@backingInt(policy.Condition.on_battery)]);
    try std.testing.expect(!back.exposed[@backingInt(policy.Condition.fullscreen)]);
    try std.testing.expectEqualStrings(ev.settings.app_rules, back.app_rules);
    try std.testing.expectEqual(@as(u32, 1200), back.resume_after_ms);
    try std.testing.expectEqual(@as(u16, 15), back.rotate_minutes);
    try std.testing.expectEqual(Order.shuffle, back.order);

    const req: Request = .{ .set_rule = .{ .condition = .covered, .action = .mute } };
    const req_back = try wire.decodeFrame(Request, try wire.encodeMessage(Request, req, &buf));
    try std.testing.expectEqual(req.set_rule, req_back.set_rule);
}

test "set_rotation leaves out what it doesn't change" {
    const std = @import("std");
    const wire = @import("wire.zig");
    var buf: [64]u8 = undefined;
    const only_order: Request = .{ .set_rotation = .{ .order = .random } };
    const back = (try wire.decodeFrame(Request, try wire.encodeMessage(Request, only_order, &buf))).set_rotation;
    try std.testing.expectEqual(@as(?u16, null), back.minutes);
    try std.testing.expectEqual(@as(?Order, .random), back.order);
}
