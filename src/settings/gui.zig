// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Immediate-mode drawing and widgets for the settings window, on every OS.
//! Each frame redraws everything from the app state, and widgets report
//! clicks as they draw. Units are DIPs (1/96 inch).
//!
//! The drawing itself is a backend's: Direct2D and DirectWrite on Windows
//! (`gui_d2d.zig`), Cairo and Pango on Linux (`gui_cairo.zig`). Everything
//! here (colours, the theme, hit testing, animation, the widgets) is shared,
//! so the window looks and behaves the same everywhere.
//!
//! Colours and sizes follow the Windows 11 design (WinUI 3 tokens): cards,
//! 4 px control corners, the accent colour, light and dark themes.

const std = @import("std");
const builtin = @import("builtin");

/// The drawing backend for this OS.
pub const Backend = switch (builtin.os.tag) {
    .windows => @import("gui_d2d.zig").Backend,
    else => @import("gui_cairo.zig").Backend,
};

pub const Point = struct { x: f32, y: f32 };

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn right(r: Rect) f32 {
        return r.x + r.w;
    }
    pub fn bottom(r: Rect) f32 {
        return r.y + r.h;
    }
    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.x < r.right() and p.y >= r.y and p.y < r.bottom();
    }
    pub fn inset(r: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = r.x + dx, .y = r.y + dy, .w = @max(0, r.w - 2 * dx), .h = @max(0, r.h - 2 * dy) };
    }
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        return .{ .x = x, .y = y, .w = @max(0, @min(a.right(), b.right()) - x), .h = @max(0, @min(a.bottom(), b.bottom()) - y) };
    }
};

/// Straight (not premultiplied) RGBA, 0..1. Same layout as Direct2D's ColorF.
pub const Color = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// 0xRRGGBBAA.
pub fn rgba(hex: u32) Color {
    return .{
        .r = @as(f32, @floatFromInt((hex >> 24) & 0xFF)) / 255,
        .g = @as(f32, @floatFromInt((hex >> 16) & 0xFF)) / 255,
        .b = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255,
        .a = @as(f32, @floatFromInt(hex & 0xFF)) / 255,
    };
}

pub fn mix(a: Color, b: Color, t: f32) Color {
    return .{ .r = a.r + (b.r - a.r) * t, .g = a.g + (b.g - a.g) * t, .b = a.b + (b.b - a.b) * t, .a = a.a + (b.a - a.a) * t };
}

pub fn alpha(c: Color, a: f32) Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a * a };
}

/// What the OS says about its look: light or dark, and the accent colour's
/// shades (Windows' AccentPalette: light2, light1, dark1, dark2).
pub const Theme = struct {
    dark: bool = false,
    accent_light2: Color = rgba(0x99EBFFFF),
    accent_light1: Color = rgba(0x60CDFFFF),
    accent_dark1: Color = rgba(0x005FB8FF),
    accent_dark2: Color = rgba(0x004A83FF),

    /// The four shades from one accent colour (for systems that give just one).
    pub fn fromAccent(dark: bool, accent: Color) Theme {
        const white = rgba(0xFFFFFFFF);
        const black = rgba(0x000000FF);
        return .{
            .dark = dark,
            .accent_light2 = mix(accent, white, 0.6),
            .accent_light1 = mix(accent, white, 0.35),
            .accent_dark1 = accent,
            .accent_dark2 = mix(accent, black, 0.2),
        };
    }
};

/// The colours every widget draws with.
pub const Palette = struct {
    dark: bool,
    /// Solid window colour (under Mica, where the backdrop isn't available).
    background: Color,
    text: Color,
    text2: Color,
    text3: Color,
    card: Color,
    card_stroke: Color,
    control: Color,
    control_hover: Color,
    control_pressed: Color,
    control_stroke: Color,
    subtle_hover: Color,
    subtle_pressed: Color,
    accent: Color,
    accent_hover: Color,
    on_accent: Color,
    divider: Color,
    caution: Color,

    pub fn build(t: Theme) Palette {
        if (t.dark) return .{
            .dark = true,
            .background = rgba(0x202020FF),
            .text = rgba(0xFFFFFFFF),
            .text2 = rgba(0xFFFFFFC8),
            .text3 = rgba(0xFFFFFF8B),
            .card = rgba(0xFFFFFF0D),
            .card_stroke = rgba(0x0000001A),
            .control = rgba(0xFFFFFF0F),
            .control_hover = rgba(0xFFFFFF15),
            .control_pressed = rgba(0xFFFFFF08),
            .control_stroke = rgba(0xFFFFFF12),
            .subtle_hover = rgba(0xFFFFFF0F),
            .subtle_pressed = rgba(0xFFFFFF0A),
            .accent = t.accent_light1,
            .accent_hover = mix(t.accent_light1, t.accent_light2, 0.5),
            .on_accent = rgba(0x000000FF),
            .divider = rgba(0xFFFFFF14),
            .caution = rgba(0xFCE100FF),
        };
        return .{
            .dark = false,
            .background = rgba(0xF3F3F3FF),
            .text = rgba(0x000000E4),
            .text2 = rgba(0x0000009E),
            .text3 = rgba(0x00000072),
            .card = rgba(0xFFFFFFB3),
            .card_stroke = rgba(0x0000000F),
            .control = rgba(0xFFFFFFB3),
            .control_hover = rgba(0xF9F9F980),
            .control_pressed = rgba(0xF9F9F94D),
            .control_stroke = rgba(0x0000001A),
            .subtle_hover = rgba(0x00000009),
            .subtle_pressed = rgba(0x00000006),
            .accent = t.accent_dark1,
            .accent_hover = mix(t.accent_dark1, t.accent_dark2, 0.4),
            .on_accent = rgba(0xFFFFFFFF),
            .divider = rgba(0x0000000F),
            .caution = rgba(0x9D5D00FF),
        };
    }
};

pub const Font = enum {
    body,
    body_strong,
    caption,
    subtitle,
    title,
    /// The icon font at body size.
    icon,
    icon_large,
};

pub const Align = enum(u2) { left, center, right };

/// Icons by meaning; each backend maps them onto its OS's icon font
/// (Segoe Fluent Icons on Windows, Fluent UI System Icons on Linux).
pub const Icon = enum {
    pictures,
    play,
    pause,
    previous,
    next,
    volume,
    mute,
    settings,
    pausing,
    add,
    folder,
    open_file,
    close,
    check,
    fit,
    power,
    app,
    document,
    info,
    warning,
    reset,
    rescan,
    star,
    video,
    image,
    lock,
    battery,
    remote,
    fullscreen,
    log,
    minimize,
    maximize,
};

pub const Kind = enum { standard, accent, subtle };

/// The keys the window pressed this frame (the platform sets them; they
/// last one frame, like `pressed`).
pub const Keys = struct {
    tab: bool = false,
    shift_tab: bool = false,
    /// Enter or Space.
    activate: bool = false,
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    home: bool = false,
    end: bool = false,
    escape: bool = false,
    /// The Menu key, or Shift+F10: the focused widget's right-click menu.
    menu: bool = false,

    pub fn any(k: Keys) bool {
        return !std.meta.eql(k, Keys{});
    }
};

pub const max_focusable = 1024;
pub const max_groups = 16;

/// What a pointer (or the keyboard) did to a widget this frame.
pub const Interaction = struct {
    hovered: bool,
    held: bool,
    clicked: bool,
    right_clicked: bool,
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    b: Backend,
    pal: Palette,
    /// The drawable area in DIPs.
    size: Point = .{ .x = 0, .y = 0 },

    // Input, fed by the window; `pressed` etc. last one frame.
    mouse: Point = .{ .x = -1, .y = -1 },
    down: bool = false,
    pressed: bool = false,
    released: bool = false,
    right_released: bool = false,
    wheel: f32 = 0,
    /// The widget the left button went down on.
    active: u64 = 0,
    /// Hit tests only count inside this rectangle (the current scroll view).
    clip: Rect = .{ .x = 0, .y = 0, .w = 1e9, .h = 1e9 },

    // Keyboard. One widget has the focus. Focusable widgets come in groups
    // (the sidebar, a card's buttons, a page): Tab moves between groups, the
    // arrows move inside one, in the direction pressed.
    keys: Keys = .{},
    focus: u64 = 0,
    /// The focus ring shows once the keyboard is used, and hides on a click
    /// (as on Windows).
    focus_visible: bool = false,
    /// A widget used this frame's arrow keys (a slider, a choice row), so
    /// they don't also move the focus.
    arrows_used: bool = false,
    order: [max_focusable]u64 = undefined,
    order_rects: [max_focusable]Rect = undefined,
    order_groups: [max_focusable]u8 = undefined,
    order_len: usize = 0,
    /// The group widgets drawn now join (`beginGroup`).
    group: u8 = 0,
    /// The widget each group had the focus on last, for Tab to come back to.
    group_last: [max_groups]u64 = @splat(0),
    /// Where the keyboard moved the focus last frame, for the page to scroll
    /// into view.
    reveal: ?Rect = null,
    /// Where the focused widget was drawn this frame (a menu opened from the
    /// keyboard opens there).
    focus_rect: ?Rect = null,

    anims: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Something is still moving: draw another frame soon.
    animating: bool = false,
    last_ms: u64 = 0,
    dt: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, b: Backend, theme: Theme) Ui {
        return .{ .gpa = gpa, .b = b, .pal = .build(theme) };
    }

    pub fn deinit(ui: *Ui) void {
        ui.b.deinit();
        ui.anims.deinit(ui.gpa);
    }

    /// Starts a frame at `now_ms`. False if drawing isn't possible right now.
    pub fn begin(ui: *Ui, now_ms: u64) bool {
        ui.size = ui.b.begin(ui.pal.background) orelse return false;
        ui.dt = if (ui.last_ms == 0) 0 else @min(0.1, @as(f32, @floatFromInt(now_ms -| ui.last_ms)) / 1000);
        ui.last_ms = now_ms;
        ui.animating = false;
        ui.clip = .{ .x = 0, .y = 0, .w = ui.size.x, .h = ui.size.y };
        ui.order_len = 0;
        ui.group = 0;
        ui.arrows_used = false;
        ui.focus_rect = null;
        return true;
    }

    /// Ends the frame. False when the backend lost its device (images must be made again).
    pub fn end(ui: *Ui) bool {
        const ok = ui.b.end();
        ui.moveFocus();
        ui.keys = .{};
        ui.pressed = false;
        ui.right_released = false;
        ui.wheel = 0;
        if (ui.released) {
            ui.released = false;
            ui.active = 0;
        }
        return ok;
    }

    // ---- drawing -------------------------------------------------------------------

    pub fn fill(ui: *Ui, r: Rect, radius: f32, c: Color) void {
        if (c.a <= 0) return;
        ui.b.fillRect(r, radius, c);
    }

    /// An outline drawn inside `r`.
    pub fn stroke(ui: *Ui, r: Rect, radius: f32, c: Color, width: f32) void {
        if (c.a <= 0) return;
        ui.b.strokeRect(r, radius, c, width);
    }

    pub fn line(ui: *Ui, a: Point, b: Point, c: Color, width: f32) void {
        ui.b.line(a, b, c, width);
    }

    pub fn circle(ui: *Ui, center: Point, radius: f32, c: Color) void {
        ui.b.fillCircle(center, radius, c);
    }

    pub fn ring(ui: *Ui, center: Point, radius: f32, c: Color, width: f32) void {
        ui.b.strokeCircle(center, radius, c, width);
    }

    /// A vertical fade from `top` to `bottom` colour.
    pub fn gradient(ui: *Ui, r: Rect, radius: f32, top: Color, bottom: Color) void {
        ui.b.gradient(r, radius, top, bottom);
    }

    /// Fills `r` with an image, cropped to cover it (like the "crop" fill mode).
    pub fn image(ui: *Ui, r: Rect, radius: f32, img: *Backend.Image, iw: f32, ih: f32) void {
        ui.b.image(r, radius, img, iw, ih);
    }

    pub fn text(ui: *Ui, r: Rect, s: []const u8, font: Font, a: Align, c: Color) void {
        ui.b.text(r, s, font, a, c);
    }

    pub fn glyph(ui: *Ui, r: Rect, g: Icon, font: Font, c: Color) void {
        ui.b.glyph(r, g, font, c);
    }

    pub fn measure(ui: *Ui, s: []const u8, font: Font) f32 {
        return ui.b.measure(s, font);
    }

    pub fn pushClip(ui: *Ui, r: Rect) Rect {
        const saved = ui.clip;
        ui.clip = ui.clip.intersect(r);
        ui.b.pushClip(r);
        return saved;
    }

    pub fn popClip(ui: *Ui, saved: Rect) void {
        ui.b.popClip();
        ui.clip = saved;
    }

    // ---- interaction ---------------------------------------------------------------

    /// A widget's pointer and keyboard interaction: it takes a place in the
    /// focus order, and Enter or Space on it counts as a click.
    pub fn interact(ui: *Ui, id: u64, r: Rect) Interaction {
        const in = ui.pointer(id, r);
        const focused = ui.focusable(id, r);
        return .{
            .hovered = in.hovered,
            .held = in.held,
            .clicked = in.clicked or (focused and ui.keys.activate),
            .right_clicked = in.right_clicked or (focused and ui.keys.menu),
        };
    }

    /// The pointer alone: for parts of a widget that is focused as a whole.
    pub fn pointer(ui: *Ui, id: u64, r: Rect) Interaction {
        const over = ui.clip.contains(ui.mouse) and r.contains(ui.mouse);
        if (over and ui.pressed) {
            ui.active = id;
            // A click moves the focus there too, without the ring.
            ui.focus = id;
            ui.focus_visible = false;
        }
        const mine = ui.active == id;
        return .{
            .hovered = over and (ui.active == 0 or mine),
            .held = mine and ui.down,
            .clicked = mine and ui.released and over,
            .right_clicked = over and ui.right_released,
        };
    }

    /// Puts `id` in this frame's focus order (also for a widget scrolled out
    /// of sight, so Tab still reaches it) and draws the focus ring around it
    /// when it has the focus. True when it has.
    pub fn focusable(ui: *Ui, id: u64, r: Rect) bool {
        if (ui.order_len < max_focusable) {
            ui.order[ui.order_len] = id;
            ui.order_rects[ui.order_len] = r;
            ui.order_groups[ui.order_len] = ui.group;
            ui.order_len += 1;
        }
        const focused = ui.focus == id;
        if (focused) ui.focus_rect = r;
        if (focused and ui.focus_visible) ui.stroke(r.inset(-3, -3), 7, ui.pal.text, 2);
        return focused;
    }

    /// Forgets this frame's focus order so far: an open menu or dialog takes
    /// the keyboard, and Tab stays inside it.
    pub fn restartFocusOrder(ui: *Ui) void {
        ui.order_len = 0;
        ui.beginGroup();
    }

    /// Widgets drawn from here on are a group of their own.
    pub fn beginGroup(ui: *Ui) void {
        if (ui.group + 1 < max_groups) ui.group += 1;
    }

    /// Tab and Shift+Tab: the next or previous group, round the ends, at the
    /// widget it had last (else its first). Arrows no widget used: the nearest
    /// widget that way in the same group (none: the focus stays). Home and
    /// End: the group's first and last.
    fn moveFocus(ui: *Ui) void {
        const k = ui.keys;
        const n = ui.order_len;
        const at: ?usize = for (ui.order[0..n], 0..) |id, i| {
            if (id == ui.focus) break i;
        } else null;
        if (at) |i| ui.group_last[ui.order_groups[i]] = ui.focus;

        const free = !ui.arrows_used;
        const dir: ?Dir = if (!free) null else if (k.left) .left else if (k.right) .right else if (k.up) .up else if (k.down) .down else null;
        const tabbed = k.tab or k.shift_tab;
        const to_start = free and k.home;
        const to_end = free and k.end;
        if (!(tabbed or dir != null or to_start or to_end)) {
            if (k.any()) ui.focus_visible = true;
            return;
        }
        ui.focus_visible = true;
        if (n == 0) return;
        const next: usize = if (at) |i| blk: {
            const g = ui.order_groups[i];
            if (tabbed) break :blk ui.enterGroup(ui.nextGroup(g, k.tab));
            if (to_start or to_end) break :blk ui.groupEnd(g, to_end);
            break :blk nearest(ui.order_rects[0..n], ui.order_groups[0..n], i, dir.?) orelse return;
        } else if (k.shift_tab or to_end) n - 1 else 0;
        ui.focus = ui.order[next];
        ui.reveal = ui.order_rects[next];
        ui.group_last[ui.order_groups[next]] = ui.focus;
    }

    /// The group after (or before) `g` in drawing order, round the ends.
    fn nextGroup(ui: *const Ui, g: u8, forward: bool) u8 {
        const gs = ui.order_groups[0..ui.order_len];
        var best: ?u8 = null;
        var wrap: u8 = g;
        for (gs) |x| {
            if (forward) {
                if (x > g and (best == null or x < best.?)) best = x;
                if (x < wrap) wrap = x;
            } else {
                if (x < g and (best == null or x > best.?)) best = x;
                if (x > wrap) wrap = x;
            }
        }
        return best orelse wrap;
    }

    /// Where Tab lands in group `g`: the widget it had last, if it's still
    /// there, else its first.
    fn enterGroup(ui: *const Ui, g: u8) usize {
        var first: ?usize = null;
        for (ui.order[0..ui.order_len], ui.order_groups[0..ui.order_len], 0..) |id, x, i| {
            if (x != g) continue;
            if (id == ui.group_last[g]) return i;
            if (first == null) first = i;
        }
        return first.?; // `g` came from the order, so it has a widget
    }

    /// The first or last widget of group `g`.
    fn groupEnd(ui: *const Ui, g: u8, last: bool) usize {
        var found: ?usize = null;
        for (ui.order_groups[0..ui.order_len], 0..) |x, i| {
            if (x != g) continue;
            if (!last) return i;
            found = i;
        }
        return found.?;
    }

    /// Eases towards `target` (about 100 ms), for hover fades and sliding knobs.
    pub fn anim(ui: *Ui, id: u64, target: f32) f32 {
        const gop = ui.anims.getOrPut(ui.gpa, id) catch return target;
        if (!gop.found_existing) {
            gop.value_ptr.* = target;
            return target;
        }
        const v = gop.value_ptr;
        const k = 1 - @exp(-ui.dt * 24);
        v.* += (target - v.*) * k;
        if (@abs(target - v.*) < 0.002) v.* = target else ui.animating = true;
        return v.*;
    }

    // ---- widgets -------------------------------------------------------------------

    pub fn button(ui: *Ui, id: u64, r: Rect, label: []const u8, icon: ?Icon, kind: Kind) bool {
        const in = ui.interact(id, r);
        const p = ui.pal;
        const hover = ui.anim(id, if (in.hovered) 1 else 0);
        const fg = switch (kind) {
            .accent => p.on_accent,
            else => if (in.held) p.text2 else p.text,
        };
        switch (kind) {
            .accent => {
                ui.fill(r, 4, if (in.held) alpha(p.accent, 0.85) else mix(p.accent, p.accent_hover, hover));
            },
            .standard => {
                ui.fill(r, 4, if (in.held) p.control_pressed else mix(p.control, p.control_hover, hover));
                ui.stroke(r, 4, p.control_stroke, 1);
            },
            .subtle => ui.fill(r, 4, if (in.held) p.subtle_pressed else alpha(p.subtle_hover, hover)),
        }
        if (label.len == 0) {
            if (icon) |g| ui.glyph(r, g, .icon, fg);
            return in.clicked;
        }
        if (icon) |g| {
            const tw = ui.measure(label, .body);
            const total = 16 + 8 + tw;
            const x0 = r.x + (r.w - total) / 2;
            ui.glyph(.{ .x = x0, .y = r.y, .w = 16, .h = r.h }, g, .icon, fg);
            ui.text(.{ .x = x0 + 24, .y = r.y, .w = tw + 2, .h = r.h }, label, .body, .left, fg);
        } else ui.text(r, label, .body, .center, fg);
        return in.clicked;
    }

    /// A Windows 11 toggle switch (40x20) with On/Off to its left. True when flipped.
    pub fn toggle(ui: *Ui, id: u64, right_edge: f32, center_y: f32, on: bool) bool {
        const p = ui.pal;
        const r: Rect = .{ .x = right_edge - 40, .y = center_y - 10, .w = 40, .h = 20 };
        const hit: Rect = .{ .x = r.x - 48, .y = r.y - 6, .w = r.w + 48, .h = r.h + 12 };
        const in = ui.interact(id, hit);
        const t = ui.anim(id, if (on) 1 else 0);
        const hover = ui.anim(id +% 1, if (in.hovered) 1 else 0);
        ui.text(.{ .x = hit.x, .y = r.y, .w = 40, .h = r.h }, if (on) "On" else "Off", .body, .right, p.text);
        if (t > 0) ui.fill(r, 10, alpha(mix(p.accent, p.accent_hover, hover), t));
        if (t < 1) {
            ui.fill(r, 10, alpha(mix(p.control, p.control_hover, hover), 1 - t));
            ui.stroke(r, 10, alpha(p.text2, 1 - t), 1);
        }
        const knob_r: f32 = @as(f32, if (in.held or in.hovered) 7 else 6) - (1 - t);
        const kx = r.x + 10 + t * 20;
        ui.circle(.{ .x = kx, .y = center_y }, knob_r, mix(p.text2, p.on_accent, t));
        return in.clicked;
    }

    /// A row of equal buttons, one selected (a "segmented" control). Returns the clicked index.
    /// One focus stop: Left and Right (Home, End) pick the neighbour.
    pub fn segmented(ui: *Ui, id: u64, r: Rect, labels: []const []const u8, selected: usize) ?usize {
        const p = ui.pal;
        const focused = ui.focusable(id, r);
        ui.fill(r, 4, p.control);
        ui.stroke(r, 4, p.control_stroke, 1);
        const seg_w = r.w / @as(f32, @floatFromInt(labels.len));
        var clicked: ?usize = null;
        const pos = ui.anim(id, @floatFromInt(selected));
        const pill: Rect = .{ .x = r.x + 2 + pos * seg_w, .y = r.y + 2, .w = seg_w - 4, .h = r.h - 4 };
        ui.fill(pill, 3, if (p.dark) rgba(0xFFFFFF1A) else rgba(0xFFFFFFFF));
        if (!p.dark) ui.stroke(pill, 3, p.control_stroke, 1);
        // The accent underline, like WinUI's selector bar.
        ui.fill(.{ .x = pill.x + pill.w / 2 - 8, .y = pill.bottom() - 3, .w = 16, .h = 3 }, 1.5, p.accent);
        for (labels, 0..) |label, i| {
            const seg: Rect = .{ .x = r.x + seg_w * @as(f32, @floatFromInt(i)), .y = r.y, .w = seg_w, .h = r.h };
            const in = ui.pointer(id +% 1 +% i, seg);
            if (in.clicked) ui.focus = id; // the whole row keeps the focus
            if (i != selected and in.hovered) ui.fill(seg.inset(2, 2), 3, p.subtle_hover);
            ui.text(seg, label, if (i == selected) .body_strong else .body, .center, if (i == selected) p.text else p.text2);
            if (in.clicked and i != selected) clicked = i;
        }
        if (focused) {
            const k = ui.keys;
            const last = labels.len - 1;
            const want: ?usize = if (k.left and selected > 0) selected - 1 else if (k.right and selected < last) selected + 1 else if (k.home) 0 else if (k.end) last else null;
            if (k.left or k.right or k.home or k.end) ui.arrows_used = true;
            if (want) |w| if (w != selected) {
                clicked = w;
            };
        }
        return clicked;
    }

    pub const SliderResult = struct { value: f32, changed: bool, released: bool };

    /// A horizontal slider over 0..1. `changed` while dragging; `released` when let go.
    /// Keyboard: Left and Right step by a twentieth, Home and End go to the ends.
    pub fn slider(ui: *Ui, id: u64, r: Rect, value: f32) SliderResult {
        const p = ui.pal;
        const in = ui.pointer(id, r.inset(-2, -6));
        const focused = ui.focusable(id, r.inset(-2, -6));
        var v = std.math.clamp(value, 0, 1);
        var changed = false;
        var by_key = false;
        if (in.held or in.clicked) {
            const nv = std.math.clamp((ui.mouse.x - r.x) / r.w, 0, 1);
            changed = nv != v;
            v = nv;
        } else if (focused) {
            const k = ui.keys;
            const step: f32 = 0.05;
            const nv: ?f32 = if (k.left) v - step else if (k.right) v + step else if (k.home) 0 else if (k.end) 1 else null;
            if (nv) |x| {
                ui.arrows_used = true;
                by_key = true;
                const c = std.math.clamp(x, 0, 1);
                changed = c != v;
                v = c;
            }
        }
        const cy = r.y + r.h / 2;
        ui.fill(.{ .x = r.x, .y = cy - 2, .w = r.w, .h = 4 }, 2, if (p.dark) rgba(0xFFFFFF8B) else rgba(0x00000072));
        ui.fill(.{ .x = r.x, .y = cy - 2, .w = r.w * v, .h = 4 }, 2, p.accent);
        const kx = r.x + r.w * v;
        ui.circle(.{ .x = kx, .y = cy }, 10, if (p.dark) rgba(0x454545FF) else rgba(0xFFFFFFFF));
        ui.ring(.{ .x = kx, .y = cy }, 10, p.control_stroke, 1);
        const inner = ui.anim(id, if (in.held) 5 else if (in.hovered) 7 else 6);
        ui.circle(.{ .x = kx, .y = cy }, inner, p.accent);
        return .{ .value = v, .changed = changed, .released = in.clicked or (ui.active == id and ui.released) or (by_key and changed) };
    }

    /// A settings card: the rounded, bordered background of a group of rows.
    pub fn card(ui: *Ui, r: Rect) void {
        ui.fill(r, 6, ui.pal.card);
        ui.stroke(r, 6, ui.pal.card_stroke, 1);
    }
};

pub const Dir = enum { left, right, up, down };

/// The widget nearest to `rects[from]` in direction `dir` among those in
/// its group: its centre must lie that way, and the distance across counts
/// double, so a grid moves along its rows and columns. Left and Right stay
/// on the row (the widget must share some height with it); Up and Down may
/// land on a shorter last row. Null when none qualifies.
pub fn nearest(rects: []const Rect, groups: []const u8, from: usize, dir: Dir) ?usize {
    std.debug.assert(rects.len == groups.len and from < rects.len);
    const a = rects[from];
    const ax = a.x + a.w / 2;
    const ay = a.y + a.h / 2;
    var best: ?usize = null;
    var best_score: f32 = std.math.inf(f32);
    for (rects, groups, 0..) |r, g, i| {
        if (i == from or g != groups[from]) continue;
        const dx = r.x + r.w / 2 - ax;
        const dy = r.y + r.h / 2 - ay;
        const along, const across = switch (dir) {
            .left => .{ -dx, dy },
            .right => .{ dx, dy },
            .up => .{ -dy, dx },
            .down => .{ dy, dx },
        };
        if (along < 1) continue;
        const same_row = r.y < a.bottom() and r.bottom() > a.y;
        if ((dir == .left or dir == .right) and !same_row) continue;
        const score = along + 2 * @abs(across);
        if (score < best_score) {
            best_score = score;
            best = i;
        }
    }
    return best;
}

/// Stable widget IDs: a name plus an index.
pub fn key(comptime name: []const u8, index: usize) u64 {
    return std.hash.Wyhash.hash(index, name);
}

/// One frame's focus order for the tests: widgets as (id, group, rect).
const TestWidget = struct { id: u64, group: u8, r: Rect };

fn testFrame(u: *Ui, list: []const TestWidget) void {
    u.order_len = 0;
    u.arrows_used = false;
    for (list) |w| {
        u.order[u.order_len] = w.id;
        u.order_rects[u.order_len] = w.r;
        u.order_groups[u.order_len] = w.group;
        u.order_len += 1;
    }
    u.moveFocus();
    u.keys = .{};
}

fn cell(id: u64, group: u8, col: f32, row_: f32) TestWidget {
    return .{ .id = id, .group = group, .r = .{ .x = col * 110, .y = row_ * 70, .w = 100, .h = 60 } };
}

// A sidebar of two (group 1) and a grid of 3 x 2 (group 2):
//   11       21 22 23
//   12       24 25
const layout = [_]TestWidget{
    .{ .id = 11, .group = 1, .r = .{ .x = -300, .y = 0, .w = 200, .h = 36 } },
    .{ .id = 12, .group = 1, .r = .{ .x = -300, .y = 40, .w = 200, .h = 36 } },
    cell(21, 2, 0, 0),
    cell(22, 2, 1, 0),
    cell(23, 2, 2, 0),
    cell(24, 2, 0, 1),
    cell(25, 2, 1, 1),
};

test "arrows move in the direction pressed, along and between rows, and stop at the edge" {
    var ui: Ui = .{ .gpa = std.testing.allocator, .b = undefined, .pal = .build(.{}) };
    ui.focus = 21;
    const steps = [_]struct { k: Keys, want: u64 }{
        .{ .k = .{ .right = true }, .want = 22 },
        .{ .k = .{ .down = true }, .want = 25 },
        .{ .k = .{ .right = true }, .want = 25 }, // nothing to the right: stays
        .{ .k = .{ .left = true }, .want = 24 },
        .{ .k = .{ .up = true }, .want = 21 },
        .{ .k = .{ .left = true }, .want = 21 }, // the sidebar is another group
        .{ .k = .{ .right = true }, .want = 22 },
        .{ .k = .{ .right = true }, .want = 23 },
        .{ .k = .{ .down = true }, .want = 25 }, // no tile below: the nearest one down
        .{ .k = .{ .end = true }, .want = 25 },
        .{ .k = .{ .home = true }, .want = 21 },
    };
    for (steps) |st| {
        ui.keys = st.k;
        testFrame(&ui, &layout);
        try std.testing.expectEqual(st.want, ui.focus);
    }
    try std.testing.expect(ui.focus_visible);
}

test "Tab moves between groups, back to where each one was" {
    var ui: Ui = .{ .gpa = std.testing.allocator, .b = undefined, .pal = .build(.{}) };
    ui.keys.tab = true;
    testFrame(&ui, &layout);
    try std.testing.expectEqual(@as(u64, 11), ui.focus); // nothing had it: the first
    ui.keys.down = true;
    testFrame(&ui, &layout);
    try std.testing.expectEqual(@as(u64, 12), ui.focus); // Down in the sidebar: the next page
    ui.keys.tab = true;
    testFrame(&ui, &layout);
    try std.testing.expectEqual(@as(u64, 21), ui.focus); // into the grid, at its first
    ui.keys.right = true;
    testFrame(&ui, &layout);
    ui.keys.tab = true;
    testFrame(&ui, &layout);
    try std.testing.expectEqual(@as(u64, 12), ui.focus); // round the end, back where it was
    ui.keys.shift_tab = true;
    testFrame(&ui, &layout);
    try std.testing.expectEqual(@as(u64, 22), ui.focus); // and back to the grid's
    try std.testing.expectEqual(@as(f32, 0), ui.reveal.?.y);
}

test "a widget that used the arrows keeps the focus" {
    var ui: Ui = .{ .gpa = std.testing.allocator, .b = undefined, .pal = .build(.{}) };
    ui.focus = 21;
    ui.keys.right = true;
    ui.order_len = 0;
    for (layout) |w| {
        ui.order[ui.order_len] = w.id;
        ui.order_rects[ui.order_len] = w.r;
        ui.order_groups[ui.order_len] = w.group;
        ui.order_len += 1;
    }
    ui.arrows_used = true;
    ui.moveFocus();
    try std.testing.expectEqual(@as(u64, 21), ui.focus);
}

test "rect helpers" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 50 };
    try std.testing.expect(r.contains(.{ .x = 10, .y = 10 }));
    try std.testing.expect(!r.contains(.{ .x = 110, .y = 10 }));
    const i = r.intersect(.{ .x = 50, .y = 0, .w = 100, .h = 30 });
    try std.testing.expectEqual(Rect{ .x = 50, .y = 10, .w = 60, .h = 20 }, i);
    try std.testing.expectEqual(@as(f32, 0), r.intersect(.{ .x = 500, .y = 0, .w = 1, .h = 1 }).w);
}

test "rgba unpacks 0xRRGGBBAA" {
    const c = rgba(0xFF800000);
    try std.testing.expectEqual(@as(f32, 1), c.r);
    try std.testing.expectApproxEqAbs(@as(f32, 0.502), c.g, 0.001);
    try std.testing.expectEqual(@as(f32, 0), c.a);
}

test "ids differ by name and index" {
    try std.testing.expect(key("a", 0) != key("a", 1));
    try std.testing.expect(key("a", 0) != key("b", 0));
}

test "a theme from one accent keeps the accent as the light theme's colour" {
    const blue = rgba(0x3584E4FF);
    const t = Theme.fromAccent(false, blue);
    try std.testing.expectEqual(blue, Palette.build(t).accent);
    try std.testing.expect(Palette.build(.{ .dark = true }).dark);
}
