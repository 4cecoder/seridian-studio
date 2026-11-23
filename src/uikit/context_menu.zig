//! uikit/context_menu: right-click menu attached to a widget (Rmenu_* and Rwidget_set_context_menu).
//!
//! Mode: retained. The menu is a Raven MENU with no parent (so it opens as a
//! context menu) and is attached to the widget with Rwidget_set_context_menu.
//! Nothing here repaints per frame: Raven draws the popup when it opens, and
//! Rwidget_invalidate is only called when the configuration changes.
//! Raven externs (declared by hand in this file, no @cImport):
//! Rmenu_add_item, Rmenu_add_separator, Rmenu_item_set_shortcut,
//! Rmenu_item_set_checkable, Rmenu_item_set_checked, Rmenu_open,
//! Rwindow_close_popups. Rwidget_set_context_menu and the widget and style
//! calls live in raven.zig. `attach` reaches Raven through a backend type
//! (RavenBackend in production, a recorder in the tests), so the wiring is
//! tested under `zig test` without linking Raven.
//! Liquid glass: translucent layered fill (theme.glassAlpha(.overlay)), 1 px top
//! highlight, soft shadow, radius in [10, 14], accent (theme.accent) for the
//! active row, text never below theme.min_font_px.
//!
//! Status: the pure logic (normalisation, selection, geometry, toggling) is
//! implemented; `attach` and `open` build and show the retained Raven menu.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const raven = @import("raven.zig");

// raven_controls.h (menus). Rid, Ruint and the enum types come from raven.zig.
pub extern fn Rmenu_add_item(menu: raven.Rid, text: [*:0]const u8) raven.Rid;
pub extern fn Rmenu_add_separator(menu: raven.Rid) raven.Rid;
pub extern fn Rmenu_item_set_shortcut(item: raven.Rid, key: u32, modifiers: u32) void;
pub extern fn Rmenu_item_set_checkable(item: raven.Rid, checkable: c_int) void;
pub extern fn Rmenu_item_set_checked(item: raven.Rid, checked: c_int) void;
pub extern fn Rmenu_open(menu: raven.Rid, window: raven.Rid, x: f32, y: f32) void;
pub extern fn Rwindow_close_popups(window: raven.Rid) void;

/// Row heights and paddings in logical px. Separators are thinner than rows.
pub const row_px: f32 = 24.0;
pub const separator_px: f32 = 9.0;
pub const padding_px: f32 = 4.0;

/// Keyboard shortcut shown next to an item. `key` is an RKey value and
/// `modifiers` a bit set of RModifier values (raven_window.h).
pub const Shortcut = struct {
    key: u32,
    modifiers: u32 = 0,
};

pub const ItemKind = enum {
    /// Plain action: clicking it runs the callback.
    action,
    /// Action with a check mark that toggles on each click.
    checkable,
    /// Thin rule between groups of items. Never selectable.
    separator,
};

pub const Item = struct {
    kind: ItemKind = .action,
    text: [:0]const u8 = "",
    shortcut: ?Shortcut = null,
    checked: bool = false,
    enabled: bool = true,
};

pub const Config = struct {
    items: []const Item = &.{},
    /// Row highlighted by the keyboard, or -1 for none.
    selected: i32 = -1,
    font_px: f32 = theme.font_body_px,
    radius: f32 = theme.radius_popup,
    min_width_px: f32 = 180.0,
};

/// A position in logical window px (top left corner of the menu).
pub const Point = struct {
    x: f32,
    y: f32,
};

/// Returns the configuration with font_px raised to theme.min_font_px,
/// radius clamped into [theme.radius_min, theme.radius_max] and min_width_px
/// floored at 0. NaN values take the floor (see theme.clampFontSize and theme.clampRadius).
pub fn normalized(cfg: Config) Config {
    var out = cfg;
    out.font_px = theme.clampFontSize(cfg.font_px);
    out.radius = theme.clampRadius(cfg.radius);
    // Negated comparison so that NaN also takes the floor.
    out.min_width_px = if (cfg.min_width_px >= 0.0) cfg.min_width_px else 0.0;
    return out;
}

/// True when the item can be highlighted and activated.
fn isSelectable(item: Item) bool {
    return item.kind != .separator and item.enabled;
}

/// Height of one item in the menu layout.
fn itemHeight(item: Item) f32 {
    return if (item.kind == .separator) separator_px else row_px;
}

/// Next selectable index after `current` moving by `step` (+1 or -1). Separators
/// and disabled items are skipped, the search wraps around the ends, and a
/// `current` of -1 starts from the first (step +1) or last (step -1) row.
/// Returns -1 when no item is selectable.
pub fn nextSelectable(items: []const Item, current: i32, step: i32) i32 {
    const n: i64 = @intCast(items.len);
    if (n == 0) return -1;
    const dir: i64 = if (step < 0) -1 else 1;
    // Out-of-range or -1 starts just before the first row (forward) or after the last (backward).
    var pos: i64 = if (current >= 0 and current < n) current else if (dir > 0) -1 else n;
    var k: i64 = 0;
    while (k < n) : (k += 1) {
        pos = @mod(pos + dir, n);
        const idx: usize = @intCast(pos);
        if (isSelectable(items[idx])) return @intCast(pos);
    }
    return -1;
}

/// Total height of the menu: top and bottom padding plus row_px for each
/// action or checkable item and separator_px for each separator.
pub fn menuHeight(items: []const Item) f32 {
    var h: f32 = 2.0 * padding_px;
    for (items) |item| h += itemHeight(item);
    return h;
}

/// Index of the item whose band contains `y` (menu-local px, top of the menu
/// at 0). Returns -1 for the padding, for separators and outside the menu.
pub fn indexAt(items: []const Item, y: f32) i32 {
    var top: f32 = padding_px;
    for (items, 0..) |item, i| {
        const bottom = top + itemHeight(item);
        if (y >= top and y < bottom) {
            return if (item.kind == .separator) -1 else @intCast(i);
        }
        top = bottom;
    }
    return -1;
}

/// Top left corner for a menu of size w x h opened at (x, y) so it stays fully
/// inside a window of win_w x win_h. Negative results are pushed to 0.
pub fn clampToWindow(x: f32, y: f32, w: f32, h: f32, win_w: f32, win_h: f32) Point {
    return .{
        .x = clampAxis(x, w, win_w),
        .y = clampAxis(y, h, win_h),
    };
}

/// Keeps a `size`-long span starting at `pos` inside `[0, window]`. NaN gives 0.
fn clampAxis(pos: f32, size: f32, window: f32) f32 {
    const max_pos = window - size;
    const p = if (pos > max_pos) max_pos else pos;
    if (!(p >= 0.0)) return 0.0;
    return p;
}

/// Checked state after a click: a checkable item flips, any other item keeps its state.
pub fn toggled(item: Item) bool {
    return if (item.kind == .checkable) !item.checked else item.checked;
}

/// Raven menu built from a configuration. The menu has no parent, so Raven
/// opens it as a context menu. The widget does not own it.
pub const Attached = struct {
    menu: raven.Rid,
};

/// The Raven calls `attach` makes. Production uses RavenBackend; tests pass a
/// recorder with the same method names.
pub const RavenBackend = struct {
    pub fn setColor(_: *RavenBackend, widget: raven.Rid, role: raven.ColorRole, r: f32, g: f32, b: f32, a: f32) void {
        raven.Rwidget_set_color(widget, role, r, g, b, a);
    }
    pub fn setMetric(_: *RavenBackend, widget: raven.Rid, metric: raven.Metric, value: f32) void {
        raven.Rwidget_set_metric(widget, metric, value);
    }
    pub fn setMaterial(_: *RavenBackend, widget: raven.Rid, material: raven.Material) void {
        raven.Rwidget_set_material(widget, material);
    }
    pub fn addSeparator(_: *RavenBackend, menu: raven.Rid) void {
        _ = Rmenu_add_separator(menu);
    }
    pub fn addItem(_: *RavenBackend, menu: raven.Rid, text: [:0]const u8) raven.Rid {
        return Rmenu_add_item(menu, text.ptr);
    }
    pub fn setCheckable(_: *RavenBackend, item: raven.Rid, checkable: bool, checked: bool) void {
        Rmenu_item_set_checkable(item, if (checkable) 1 else 0);
        Rmenu_item_set_checked(item, if (checked) 1 else 0);
    }
    pub fn setShortcut(_: *RavenBackend, item: raven.Rid, shortcut: Shortcut) void {
        Rmenu_item_set_shortcut(item, shortcut.key, shortcut.modifiers);
    }
    pub fn setContextMenu(_: *RavenBackend, widget: raven.Rid, menu: raven.Rid) void {
        raven.Rwidget_set_context_menu(widget, menu);
    }
    pub fn invalidate(_: *RavenBackend, widget: raven.Rid) void {
        raven.Rwidget_invalidate(widget);
    }
};

/// Fills a parentless Raven MENU `menu` from `cfg` and attaches it to `widget`
/// with Rwidget_set_context_menu. The caller supplies `menu`: the header declares
/// no constructor for a parentless menu, and Rmenu_add_menu would nest it.
/// Items keep their order; shortcuts and check state are applied per item.
/// Styling is applied to the menu root: glass fill at the overlay layer, popup
/// radius, and the body font size.
pub fn attach(widget: raven.Rid, menu: raven.Rid, cfg_in: Config) Attached {
    var backend: RavenBackend = .{};
    return attachWith(&backend, widget, menu, cfg_in);
}

/// `attach` with the Raven calls routed through `backend` (a pointer to a type
/// with the methods of RavenBackend).
pub fn attachWith(backend: anytype, widget: raven.Rid, menu: raven.Rid, cfg_in: Config) Attached {
    const cfg = normalized(cfg_in);
    if (menu == raven.invalid) return .{ .menu = raven.invalid };

    const fill = theme.withAlpha(theme.bg_panel, theme.glassAlpha(.overlay));
    backend.setColor(menu, .popup, fill.r, fill.g, fill.b, fill.a);
    backend.setMetric(menu, .popup_radius, cfg.radius);
    backend.setMetric(menu, .font_size, cfg.font_px);
    backend.setMaterial(menu, .glass);

    for (cfg.items) |item| {
        switch (item.kind) {
            .separator => backend.addSeparator(menu),
            .action, .checkable => {
                const entry = backend.addItem(menu, item.text);
                if (entry == raven.invalid) continue;
                if (item.kind == .checkable) backend.setCheckable(entry, true, item.checked);
                if (item.shortcut) |sc| backend.setShortcut(entry, sc);
            },
        }
    }

    backend.setContextMenu(widget, menu);
    backend.invalidate(widget);
    return .{ .menu = menu };
}

/// Opens an attached menu at window position (x, y), keeping it inside the
/// window. Existing popups in the window are closed first.
pub fn open(menu: raven.Rid, window: raven.Rid, win_w: f32, win_h: f32, x: f32, y: f32, w: f32, h: f32) void {
    const p = clampToWindow(x, y, w, h, win_w, win_h);
    Rwindow_close_popups(window);
    Rmenu_open(menu, window, p.x, p.y);
}

test "context_menu configuration: defaults" {
    // Must check:
    //   - no items, selected -1 (no highlight)
    //   - font 13 (theme.font_body_px), radius 12 (theme.radius_popup), min width 180
    //   - an Item defaults to kind action, enabled, unchecked, no shortcut
    const cfg: Config = .{};
    try testing.expectEqual(@as(usize, 0), cfg.items.len);
    try testing.expectEqual(@as(i32, -1), cfg.selected);
    try testing.expectEqual(theme.font_body_px, cfg.font_px);
    try testing.expectEqual(theme.radius_popup, cfg.radius);
    try testing.expectEqual(@as(f32, 180.0), cfg.min_width_px);

    const item: Item = .{};
    try testing.expectEqual(ItemKind.action, item.kind);
    try testing.expect(item.enabled);
    try testing.expect(!item.checked);
    try testing.expect(item.shortcut == null);
}

test "context_menu configuration: font and radius clamping" {
    // Must check:
    //   - font_px 10 becomes 12 (theme.min_font_px), NaN becomes 12, 16 stays 16
    //   - radius 20 becomes 14, radius 5 becomes 10, radius 12 stays 12
    //   - min_width_px -5 becomes 0
    const small = normalized(.{ .font_px = 10.0 });
    try testing.expectEqual(theme.min_font_px, small.font_px);

    const nan_font = normalized(.{ .font_px = std.math.nan(f32) });
    try testing.expectEqual(theme.min_font_px, nan_font.font_px);

    const big_font = normalized(.{ .font_px = 16.0 });
    try testing.expectEqual(@as(f32, 16.0), big_font.font_px);

    const big_radius = normalized(.{ .radius = 20.0 });
    try testing.expectEqual(theme.radius_max, big_radius.radius);

    const small_radius = normalized(.{ .radius = 5.0 });
    try testing.expectEqual(theme.radius_min, small_radius.radius);

    const ok_radius = normalized(.{ .radius = 12.0 });
    try testing.expectEqual(@as(f32, 12.0), ok_radius.radius);

    const neg_width = normalized(.{ .min_width_px = -5.0 });
    try testing.expectEqual(@as(f32, 0.0), neg_width.min_width_px);
}

test "context_menu selection: skips separators and disabled items and wraps" {
    // Layout: 0 action, 1 separator, 2 disabled action, 3 checkable, 4 action.
    const items = [_]Item{
        .{ .kind = .action, .text = "Cut" },
        .{ .kind = .separator },
        .{ .kind = .action, .text = "Paste", .enabled = false },
        .{ .kind = .checkable, .text = "Snap" },
        .{ .kind = .action, .text = "Delete" },
    };
    try testing.expectEqual(@as(i32, 3), nextSelectable(&items, 0, 1));
    try testing.expectEqual(@as(i32, 4), nextSelectable(&items, 3, 1));
    try testing.expectEqual(@as(i32, 0), nextSelectable(&items, 4, 1));
    try testing.expectEqual(@as(i32, 4), nextSelectable(&items, 0, -1));
    try testing.expectEqual(@as(i32, 3), nextSelectable(&items, 4, -1));
    try testing.expectEqual(@as(i32, 0), nextSelectable(&items, -1, 1));
    try testing.expectEqual(@as(i32, 4), nextSelectable(&items, -1, -1));
}

test "context_menu selection: no selectable item gives -1" {
    const empty: []const Item = &.{};
    try testing.expectEqual(@as(i32, -1), nextSelectable(empty, -1, 1));

    const only_rules = [_]Item{ .{ .kind = .separator }, .{ .kind = .separator } };
    try testing.expectEqual(@as(i32, -1), nextSelectable(&only_rules, 0, 1));

    const all_disabled = [_]Item{.{ .enabled = false }};
    try testing.expectEqual(@as(i32, -1), nextSelectable(&all_disabled, 0, -1));
}

test "context_menu index maths: menu height" {
    // 4 + 24 + 9 + 24 + 4 = 65
    const items = [_]Item{
        .{ .kind = .action },
        .{ .kind = .separator },
        .{ .kind = .checkable },
    };
    try testing.expectApproxEqAbs(@as(f32, 65.0), menuHeight(&items), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 8.0), menuHeight(&.{}), 1e-4);
}

test "context_menu index maths: hit testing rows" {
    // Bands: padding 0..4, row 0 at 4..28, separator 28..37, row 2 at 37..61, padding 61..65.
    const items = [_]Item{
        .{ .kind = .action },
        .{ .kind = .separator },
        .{ .kind = .action },
    };
    try testing.expectEqual(@as(i32, -1), indexAt(&items, -0.1));
    try testing.expectEqual(@as(i32, -1), indexAt(&items, 2.0));
    try testing.expectEqual(@as(i32, 0), indexAt(&items, 4.5));
    try testing.expectEqual(@as(i32, 0), indexAt(&items, 27.9));
    try testing.expectEqual(@as(i32, -1), indexAt(&items, 30.0));
    try testing.expectEqual(@as(i32, 2), indexAt(&items, 37.5));
    try testing.expectEqual(@as(i32, -1), indexAt(&items, 63.0));
    try testing.expectEqual(@as(i32, -1), indexAt(&items, 70.0));
    try testing.expectEqual(@as(i32, -1), indexAt(&.{}, 2.0));
}

test "context_menu placement: keeps the menu inside the window" {
    // Window 800 x 600, menu 180 x 65.
    const inside = clampToWindow(100.0, 50.0, 180.0, 65.0, 800.0, 600.0);
    try testing.expectApproxEqAbs(@as(f32, 100.0), inside.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 50.0), inside.y, 1e-4);

    const right_edge = clampToWindow(790.0, 10.0, 180.0, 65.0, 800.0, 600.0);
    try testing.expectApproxEqAbs(@as(f32, 620.0), right_edge.x, 1e-4);

    const bottom_edge = clampToWindow(10.0, 590.0, 180.0, 65.0, 800.0, 600.0);
    try testing.expectApproxEqAbs(@as(f32, 535.0), bottom_edge.y, 1e-4);

    const negative = clampToWindow(-20.0, -4.0, 180.0, 65.0, 800.0, 600.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), negative.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.0), negative.y, 1e-4);
}

test "context_menu checkable: click toggles only checkable items" {
    try testing.expect(toggled(.{ .kind = .checkable, .checked = false }));
    try testing.expect(!toggled(.{ .kind = .checkable, .checked = true }));
    try testing.expect(!toggled(.{ .kind = .action, .checked = false }));
    try testing.expect(toggled(.{ .kind = .action, .checked = true }));
}

/// Records what attachWith asks of the backend, for the tests below.
const Recorder = struct {
    const max_items = 8;
    const Entry = struct {
        id: raven.Rid = raven.invalid,
        text: [:0]const u8 = "",
        checkable: bool = false,
        checked: bool = false,
        shortcut: ?Shortcut = null,
    };

    calls: usize = 0,
    colors: usize = 0,
    font_size: f32 = 0.0,
    popup_radius: f32 = 0.0,
    material: ?raven.Material = null,
    separators: usize = 0,
    entries: [max_items]Entry = @splat(.{}),
    entry_count: usize = 0,
    context_widget: raven.Rid = raven.invalid,
    context_menu: raven.Rid = raven.invalid,
    invalidated: usize = 0,

    fn setColor(self: *Recorder, widget: raven.Rid, role: raven.ColorRole, r: f32, g: f32, b: f32, a: f32) void {
        _ = .{ widget, role, r, g, b, a };
        self.calls += 1;
        self.colors += 1;
    }
    fn setMetric(self: *Recorder, widget: raven.Rid, metric: raven.Metric, value: f32) void {
        _ = widget;
        self.calls += 1;
        switch (metric) {
            .font_size => self.font_size = value,
            .popup_radius => self.popup_radius = value,
            else => {},
        }
    }
    fn setMaterial(self: *Recorder, widget: raven.Rid, material: raven.Material) void {
        _ = widget;
        self.calls += 1;
        self.material = material;
    }
    fn addSeparator(self: *Recorder, menu: raven.Rid) void {
        _ = menu;
        self.calls += 1;
        self.separators += 1;
    }
    fn addItem(self: *Recorder, menu: raven.Rid, text: [:0]const u8) raven.Rid {
        _ = menu;
        self.calls += 1;
        if (self.entry_count >= max_items) return raven.invalid;
        const id: raven.Rid = @intCast(100 + self.entry_count);
        self.entries[self.entry_count] = .{ .id = id, .text = text };
        self.entry_count += 1;
        return id;
    }
    fn entryFor(self: *Recorder, item: raven.Rid) ?*Entry {
        for (self.entries[0..self.entry_count]) |*e| {
            if (e.id == item) return e;
        }
        return null;
    }
    fn setCheckable(self: *Recorder, item: raven.Rid, checkable: bool, checked: bool) void {
        self.calls += 1;
        const e = self.entryFor(item) orelse return;
        e.checkable = checkable;
        e.checked = checked;
    }
    fn setShortcut(self: *Recorder, item: raven.Rid, shortcut: Shortcut) void {
        self.calls += 1;
        const e = self.entryFor(item) orelse return;
        e.shortcut = shortcut;
    }
    fn setContextMenu(self: *Recorder, widget: raven.Rid, menu: raven.Rid) void {
        self.calls += 1;
        self.context_widget = widget;
        self.context_menu = menu;
    }
    fn invalidate(self: *Recorder, widget: raven.Rid) void {
        _ = widget;
        self.calls += 1;
        self.invalidated += 1;
    }
};

test "context_menu attach: items, checks, shortcuts and the context menu wiring" {
    var rec: Recorder = .{};
    const items = [_]Item{
        .{ .kind = .action, .text = "Cut", .shortcut = .{ .key = 88, .modifiers = 2 } },
        .{ .kind = .separator },
        .{ .kind = .checkable, .text = "Snap", .checked = true },
    };
    const got = attachWith(&rec, 7, 9, .{ .items = &items, .font_px = 3.0, .radius = 99.0 });
    try testing.expectEqual(@as(raven.Rid, 9), got.menu);

    // The menu is the context menu of widget 7, and the widget is repainted once.
    try testing.expectEqual(@as(raven.Rid, 7), rec.context_widget);
    try testing.expectEqual(@as(raven.Rid, 9), rec.context_menu);
    try testing.expectEqual(@as(usize, 1), rec.invalidated);

    // Items keep their order: an action, a separator, then a checkable item.
    try testing.expectEqual(@as(usize, 1), rec.separators);
    try testing.expectEqual(@as(usize, 2), rec.entry_count);
    try testing.expectEqualStrings("Cut", rec.entries[0].text);
    try testing.expectEqualStrings("Snap", rec.entries[1].text);
    try testing.expect(!rec.entries[0].checkable);
    try testing.expect(rec.entries[1].checkable);
    try testing.expect(rec.entries[1].checked);
    try testing.expectEqual(@as(u32, 88), rec.entries[0].shortcut.?.key);
    try testing.expectEqual(@as(u32, 2), rec.entries[0].shortcut.?.modifiers);
    try testing.expect(rec.entries[1].shortcut == null);

    // Styling uses the normalised values: font raised to the minimum, radius clamped to the maximum.
    try testing.expectEqual(theme.min_font_px, rec.font_size);
    try testing.expectEqual(theme.radius_max, rec.popup_radius);
    try testing.expectEqual(raven.Material.glass, rec.material.?);
    try testing.expectEqual(@as(usize, 1), rec.colors);
}

test "context_menu attach: an invalid menu id attaches nothing" {
    var rec: Recorder = .{};
    const items = [_]Item{.{ .kind = .action, .text = "Cut" }};
    const got = attachWith(&rec, 7, raven.invalid, .{ .items = &items });
    try testing.expectEqual(raven.invalid, got.menu);
    try testing.expectEqual(@as(usize, 0), rec.calls);
    try testing.expectEqual(@as(raven.Rid, raven.invalid), rec.context_widget);
}
