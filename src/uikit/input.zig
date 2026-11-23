//! uikit/input: text field, search field, combo box (glass dropdown) and tab bar.
//!
//! Mode: retained. Every widget here is a Raven widget made with Rwidget_create
//! (or Rtab_view_add_tab for the tab bar) and placed in the tree. Nothing in this
//! file repaints per frame, so there is no immediate-mode code here. The debounce
//! of the search field uses a one-shot Raven timer (Rtimer_create), not a per-frame
//! poll.
//!
//! Raven calls are declared in raven.zig (no @cImport).
//!
//! Style: the glass surfaces are Borders with R_MATERIAL_GLASS, a translucent
//! fill at theme.glass_alpha_min/max, rounded corners (theme radius 10..14), a
//! soft shadow (theme.shadow_blur_px, shadow_offset_y_px), and the 1 px top rim
//! through R_METRIC_GLASS_RIM. The accent colour marks focus and the active tab.
//! State transitions use Raven's springs; theme.transition_ms (120 ms) is the target
//! feel, closest preset R_MOTION_SNAPPY (known gap, see docs/development/uikit.md).
//!
//! Spec: the Config tests of text_input.zig, search_field.zig and combo_box.zig,
//! and the tab bar config below, follow the same rules. Those files are not
//! changed by this file.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const style = @import("style.zig");
const raven = @import("raven.zig");

// ---------------------------------------------------------------------------
// Raven types and callbacks (declared in raven.zig).
// ---------------------------------------------------------------------------

const Rid = raven.Rid;
const invalid = raven.invalid;
const WidgetKind = raven.WidgetType;
const Visibility = raven.Visibility;
const ColorRole = raven.ColorRole;
const Metric = raven.Metric;
const Material = raven.Material;
const ButtonStyle = raven.ButtonStyle;
const TextAlign = raven.TextAlign;
const ClickedFn = raven.ClickedCallback;
const TextChangedFn = raven.TextChangedCallback;
const ComboChangedFn = raven.ComboBoxChangedCallback;
const TabChangedFn = raven.TabChangedCallback;
const TimerFn = raven.TimerCallback;

// ---------------------------------------------------------------------------
// Errors and public callback types.
// ---------------------------------------------------------------------------

pub const BuildError = std.mem.Allocator.Error || error{
    WidgetCreateFailed,
    WidgetAddFailed,
    ItemAddFailed,
    TabAddFailed,
};

/// Called once the search text has been stable for debounce_ms. `text` is valid for the call only.
pub const SearchFn = *const fn (field: Rid, text: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void;
pub const TextChangedCallback = TextChangedFn;
pub const ComboChangedCallback = ComboChangedFn;
pub const TabChangedCallback = TabChangedFn;

// ---------------------------------------------------------------------------
// Configuration (public, matches the spec tests of the single-widget modules).
// ---------------------------------------------------------------------------

const search_max_length_default: i32 = 128;
const search_debounce_max_ms: u32 = 1000;

/// Text field: text_input (R_WIDGET_TEXT_INPUT) inside a glass Border.
pub const TextFieldConfig = struct {
    text: [:0]const u8 = "",
    placeholder: [:0]const u8 = "",
    /// 0 means no limit.
    max_length: i32 = 0,
    font_px: f32 = theme.font_body_px,

    /// Negative max_length becomes 0. font_px is raised to at least 12 (NaN too).
    pub fn sanitize(self: TextFieldConfig) TextFieldConfig {
        var out = self;
        out.max_length = @max(self.max_length, 0);
        out.font_px = theme.clampFontSize(self.font_px);
        return out;
    }
};

/// Search field: glass Border holding a magnifier glyph, a text_input and a flat clear button.
pub const SearchFieldConfig = struct {
    placeholder: [:0]const u8 = "Search",
    debounce_ms: u32 = 120,
    max_length: i32 = search_max_length_default,

    /// max_length below 1 becomes 128. debounce_ms above 1000 is clamped to 1000.
    pub fn sanitize(self: SearchFieldConfig) SearchFieldConfig {
        var out = self;
        out.max_length = if (self.max_length < 1) search_max_length_default else self.max_length;
        out.debounce_ms = @min(self.debounce_ms, search_debounce_max_ms);
        return out;
    }
};

/// Combo box: Rcombo_box styled as a glass dropdown (popup colours and radius).
pub const ComboBoxConfig = struct {
    items: []const [:0]const u8 = &.{},
    selected: i32 = 0,
    popup_radius: f32 = theme.radius_popup,

    /// selected is clamped into [0, items.len - 1]; it is -1 when there are no items.
    /// popup_radius is clamped into 10..14.
    pub fn sanitize(self: ComboBoxConfig) ComboBoxConfig {
        var out = self;
        out.selected = clampIndex(self.selected, self.items.len);
        out.popup_radius = theme.clampRadius(self.popup_radius);
        return out;
    }
};

/// Tab bar: one R_WIDGET_TAB_VIEW tab per title. Page i is child i of the view.
pub const TabBarConfig = struct {
    tabs: []const [:0]const u8 = &.{},
    active: i32 = 0,
    font_px: f32 = theme.font_body_px,
    radius: f32 = theme.radius_control,

    /// active is clamped into [0, tabs.len - 1], -1 when there are no tabs.
    /// font_px is raised to at least 12. radius is clamped into 10..14.
    pub fn sanitize(self: TabBarConfig) TabBarConfig {
        var out = self;
        out.active = clampIndex(self.active, self.tabs.len);
        out.font_px = theme.clampFontSize(self.font_px);
        out.radius = theme.clampRadius(self.radius);
        return out;
    }
};

// ---------------------------------------------------------------------------
// Pure helpers.
// ---------------------------------------------------------------------------

/// Clamps an index into [0, len - 1]. Returns -1 when len is 0.
fn clampIndex(index: i32, len: usize) i32 {
    if (len == 0) return -1;
    const last = std.math.cast(i32, len - 1) orelse std.math.maxInt(i32);
    return std.math.clamp(index, 0, last);
}

// ---------------------------------------------------------------------------
// Retained-tree construction.
// ---------------------------------------------------------------------------

fn create(kind: WidgetKind) BuildError!Rid {
    const id = raven.Rwidget_create(kind);
    if (id == invalid) return error.WidgetCreateFailed;
    return id;
}

fn attach(parent: Rid, child: Rid) BuildError!void {
    if (raven.Rwidget_add_child(parent, child) == invalid) return error.WidgetAddFailed;
}

fn paint(widget: Rid, role: ColorRole, c: theme.Color, alpha: f32) void {
    raven.Rwidget_set_color(widget, role, c.r, c.g, c.b, alpha);
}

/// Liquid-glass surface on a Border: translucent panel fill at `alpha`, rounded
/// corners, soft shadow, and the 1 px top rim (R_METRIC_GLASS_RIM).
fn styleGlassBorder(border: Rid, radius: f32, alpha: f32) void {
    const r = theme.clampRadius(radius);
    raven.Rborder_set_material(border, .glass);
    raven.Rborder_set_background(border, theme.bg_panel.r, theme.bg_panel.g, theme.bg_panel.b, alpha);
    raven.Rborder_set_corner_radius(border, r, r, r, r);
    raven.Rborder_set_shadow(border, theme.shadow_blur_px, 0, theme.shadow_offset_y_px);
    raven.Rwidget_set_metric(border, .glass_rim, theme.highlight_px);
    paint(border, .shadow, theme.shadow, theme.shadow.a);
}

fn styleTextInput(field: Rid, font_px: f32) void {
    raven.Rwidget_set_metric(field, .font_size, font_px);
    // Transparent: the glass Border behind it is the visible fill.
    paint(field, .input, theme.bg_void, 0.0);
    paint(field, .text, theme.text, 1.0);
    paint(field, .text_placeholder, theme.text_muted, 1.0);
    paint(field, .focus, theme.accent, 1.0);
}

/// Text field: glass Border around a text_input.
/// Returns the root (the Border). The text_input is its only child.
pub fn createTextField(cfg: TextFieldConfig, on_change: ?TextChangedCallback, user_data: ?*anyopaque) BuildError!Rid {
    const c = cfg.sanitize();

    const frame = try create(.border);
    errdefer raven.Rwidget_destroy(frame);
    const field = try create(.text_input);
    try attach(frame, field);

    raven.Rtext_input_set_text(field, c.text.ptr);
    raven.Rtext_input_set_placeholder(field, c.placeholder.ptr);
    // Raven treats a length of 0 as "no limit" only when it is not set, so set it only when it is positive.
    if (c.max_length > 0) raven.Rtext_input_set_max_length(field, c.max_length);
    raven.Rtext_input_set_changed_callback(field, on_change, user_data);
    styleTextInput(field, c.font_px);

    raven.Rborder_set_padding(frame, 10, 6, 10, 6);
    styleGlassBorder(frame, theme.radius_control, theme.glass_alpha_min);
    return frame;
}

/// Per-search-field state. Allocated with c_allocator in createSearchField and freed
/// by destroySearchField. Its address is the user handle of the root Border.
const SearchState = struct {
    field: Rid,
    clear: Rid,
    debounce_ms: u32,
    timer: Rid = invalid,
    on_search: ?SearchFn,
    user_data: ?*anyopaque,
};

fn stateFrom(user_data: ?*anyopaque) ?*SearchState {
    const raw = user_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn cancelTimer(state: *SearchState) void {
    if (state.timer != invalid and raven.Rtimer_is_valid(state.timer) != 0) raven.Rtimer_destroy(state.timer);
    state.timer = invalid;
}

/// (Re)starts the one-shot debounce timer. A timer fires once and deletes itself.
fn scheduleSearch(state: *SearchState) void {
    cancelTimer(state);
    const seconds: f64 = @as(f64, @floatFromInt(state.debounce_ms)) / 1000.0;
    state.timer = raven.Rtimer_create(seconds, 0, searchTimerFired, state);
}

fn searchTimerFired(timer: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    const state = stateFrom(user_data) orelse return;
    // The timer has deleted itself (repeat = false).
    state.timer = invalid;
    const cb = state.on_search orelse return;
    cb(state.field, raven.Rtext_input_get_text(state.field), state.user_data);
}

fn setClearVisible(state: *SearchState, empty: bool) void {
    raven.Rwidget_set_visibility(state.clear, if (empty) .collapsed else .visible);
}

fn searchTextChanged(field: Rid, text: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = field;
    const state = stateFrom(user_data) orelse return;
    setClearVisible(state, text[0] == 0);
    scheduleSearch(state);
}

fn searchClearClicked(button: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const state = stateFrom(user_data) orelse return;
    raven.Rtext_input_set_text(state.field, "");
    setClearVisible(state, true);
    scheduleSearch(state);
}

/// Search field: glass Border > HBox [glyph Label, text_input (fills), flat clear Button].
/// The clear button is collapsed while the text is empty. on_search fires after
/// cfg.debounce_ms of no typing. Free the tree and state with destroySearchField.
pub fn createSearchField(cfg: SearchFieldConfig, on_search: ?SearchFn, user_data: ?*anyopaque) BuildError!Rid {
    const c = cfg.sanitize();

    const state = try std.heap.c_allocator.create(SearchState);
    errdefer std.heap.c_allocator.destroy(state);

    const frame = try create(.border);
    errdefer raven.Rwidget_destroy(frame);
    const row = try create(.hbox);
    try attach(frame, row);

    // U+2315 telephone recorder, used as the magnifier glyph.
    const glyph = raven.Rlabel_create("\u{2315}");
    if (glyph == invalid) return error.WidgetCreateFailed;
    raven.Rlabel_set_text_align(glyph, .center);
    paint(glyph, .text_placeholder, theme.text_muted, 1.0);
    raven.Rwidget_set_metric(glyph, .font_size, theme.font_body_px);
    try attach(row, glyph);

    const field = try create(.text_input);
    raven.Rslot_set_fill(field, 1.0);
    try attach(row, field);

    // U+00D7 multiplication sign, used as the clear glyph.
    const clear = raven.Rbutton_create("\u{00D7}");
    if (clear == invalid) return error.WidgetCreateFailed;
    raven.Rbutton_set_style(clear, .flat);
    raven.Rwidget_set_visibility(clear, .collapsed);
    try attach(row, clear);

    state.* = .{
        .field = field,
        .clear = clear,
        .debounce_ms = c.debounce_ms,
        .on_search = on_search,
        .user_data = user_data,
    };
    raven.Rwidget_set_user_handle(frame, state);

    raven.Rtext_input_set_text(field, "");
    raven.Rtext_input_set_placeholder(field, c.placeholder.ptr);
    raven.Rtext_input_set_max_length(field, c.max_length);
    raven.Rtext_input_set_changed_callback(field, searchTextChanged, state);
    raven.Rbutton_set_clicked_callback(clear, searchClearClicked, state);
    styleTextInput(field, theme.font_body_px);

    raven.Rborder_set_padding(frame, 10, 6, 10, 6);
    styleGlassBorder(frame, theme.radius_control, theme.glass_alpha_min);
    return frame;
}

/// Frees a search field built by createSearchField: cancels its timer, destroys the
/// tree under `root`, and frees the state. `root` is the Border it returned.
pub fn destroySearchField(root: Rid) void {
    const state = stateFrom(raven.Rwidget_get_user_handle(root)) orelse return;
    cancelTimer(state);
    raven.Rwidget_destroy(root);
    std.heap.c_allocator.destroy(state);
}

/// Combo box: Rcombo_box with the glass dropdown colours and popup radius.
pub fn createComboBox(cfg: ComboBoxConfig, on_change: ?ComboChangedCallback, user_data: ?*anyopaque) BuildError!Rid {
    const c = cfg.sanitize();

    const combo = try create(.combo_box);
    errdefer raven.Rwidget_destroy(combo);
    for (c.items) |item| {
        if (raven.Rcombo_box_add_item(combo, item.ptr) < 0) return error.ItemAddFailed;
    }
    raven.Rcombo_box_set_selected(combo, c.selected);
    raven.Rcombo_box_set_changed_callback(combo, on_change, user_data);

    // Closed field: control fill at the base glass alpha.
    paint(combo, .control, theme.bg_panel, theme.glass_alpha_min);
    paint(combo, .text, theme.text, 1.0);
    paint(combo, .focus, theme.accent, 1.0);
    raven.Rwidget_set_metric(combo, .corner_radius, theme.radius_control);

    // Dropdown: overlay glass, rim in the popup border colour, popup radius.
    raven.Rwidget_set_material(combo, .glass);
    paint(combo, .popup, theme.bg_panel, theme.glass_alpha_max);
    paint(combo, .popup_border, theme.highlight, theme.highlight.a);
    raven.Rwidget_set_metric(combo, .popup_radius, c.popup_radius);
    return combo;
}

/// Tab bar: Raven TabView. Each title gets an empty VBox page (child i of the view).
pub fn createTabBar(cfg: TabBarConfig, on_change: ?TabChangedCallback, user_data: ?*anyopaque) BuildError!Rid {
    const c = cfg.sanitize();

    const view = try create(.tab_view);
    errdefer raven.Rwidget_destroy(view);
    for (c.tabs) |title| {
        const page = try create(.vbox);
        if (raven.Rtab_view_add_tab(view, title.ptr, page) < 0) return error.TabAddFailed;
    }
    if (c.active >= 0) raven.Rtab_view_set_active(view, c.active);
    raven.Rtab_view_set_changed_callback(view, on_change, user_data);

    raven.Rwidget_set_material(view, .glass);
    raven.Rwidget_set_metric(view, .font_size, c.font_px);
    raven.Rwidget_set_metric(view, .corner_radius, c.radius);
    raven.Rwidget_set_metric(view, .glass_rim, theme.highlight_px);
    paint(view, .header, theme.bg_panel, theme.glass_alpha_min);
    paint(view, .header_hovered, theme.bg_panel, theme.glass_alpha_max);
    paint(view, .tab_active, theme.accent, 1.0);
    paint(view, .text, theme.text, 1.0);
    return view;
}

// ---------------------------------------------------------------------------
// Tests (configuration only: they do not call Raven).
// ---------------------------------------------------------------------------

fn approx(a: f32, b: f32) !void {
    try testing.expectApproxEqAbs(a, b, 1e-6);
}

test "text_input configuration: defaults and clamping" {
    const d: TextFieldConfig = .{};
    try testing.expectEqualStrings("", d.text);
    try testing.expectEqual(@as(i32, 0), d.max_length);
    try approx(d.font_px, 13.0);

    try testing.expectEqual(@as(i32, 0), (TextFieldConfig{ .max_length = -5 }).sanitize().max_length);
    try testing.expectEqual(@as(i32, 7), (TextFieldConfig{ .max_length = 7 }).sanitize().max_length);
    try approx((TextFieldConfig{ .font_px = 8.0 }).sanitize().font_px, 12.0);
    try approx((TextFieldConfig{ .font_px = std.math.nan(f32) }).sanitize().font_px, 12.0);
    try approx((TextFieldConfig{ .font_px = 20.0 }).sanitize().font_px, 20.0);
}

test "search_field configuration: defaults and clamping" {
    const d: SearchFieldConfig = .{};
    try testing.expectEqualStrings("Search", d.placeholder);
    try testing.expectEqual(@as(u32, 120), d.debounce_ms);
    try testing.expectEqual(@as(i32, 128), d.max_length);

    try testing.expectEqual(@as(i32, 128), (SearchFieldConfig{ .max_length = 0 }).sanitize().max_length);
    try testing.expectEqual(@as(i32, 128), (SearchFieldConfig{ .max_length = -3 }).sanitize().max_length);
    try testing.expectEqual(@as(i32, 40), (SearchFieldConfig{ .max_length = 40 }).sanitize().max_length);
    try testing.expectEqual(@as(u32, 1000), (SearchFieldConfig{ .debounce_ms = 5000 }).sanitize().debounce_ms);
    try testing.expectEqual(@as(u32, 300), (SearchFieldConfig{ .debounce_ms = 300 }).sanitize().debounce_ms);
}

test "combo_box configuration: defaults and clamping" {
    const d: ComboBoxConfig = .{};
    try testing.expectEqual(@as(usize, 0), d.items.len);
    try testing.expectEqual(@as(i32, 0), d.selected);
    try approx(d.popup_radius, 12.0);

    const none = (ComboBoxConfig{ .selected = 3 }).sanitize();
    try testing.expectEqual(@as(i32, -1), none.selected);

    const items = [_][:0]const u8{ "Off", "Low", "High" };
    try testing.expectEqual(@as(i32, 0), (ComboBoxConfig{ .items = &items, .selected = -4 }).sanitize().selected);
    try testing.expectEqual(@as(i32, 2), (ComboBoxConfig{ .items = &items, .selected = 7 }).sanitize().selected);
    try testing.expectEqual(@as(i32, 1), (ComboBoxConfig{ .items = &items, .selected = 1 }).sanitize().selected);

    try approx((ComboBoxConfig{ .popup_radius = 40.0 }).sanitize().popup_radius, 14.0);
    try approx((ComboBoxConfig{ .popup_radius = 0.0 }).sanitize().popup_radius, 10.0);
    try approx((ComboBoxConfig{ .popup_radius = 12.0 }).sanitize().popup_radius, 12.0);
}

test "tab_bar configuration: defaults and clamping" {
    const d: TabBarConfig = .{};
    try testing.expectEqual(@as(usize, 0), d.tabs.len);
    try testing.expectEqual(@as(i32, 0), d.active);
    try approx(d.font_px, 13.0);
    try approx(d.radius, 10.0);

    try testing.expectEqual(@as(i32, -1), (TabBarConfig{ .active = 2 }).sanitize().active);

    const tabs = [_][:0]const u8{ "Mixer", "Piano", "Effects" };
    try testing.expectEqual(@as(i32, 0), (TabBarConfig{ .tabs = &tabs, .active = -2 }).sanitize().active);
    try testing.expectEqual(@as(i32, 2), (TabBarConfig{ .tabs = &tabs, .active = 9 }).sanitize().active);
    try approx((TabBarConfig{ .font_px = 8.0 }).sanitize().font_px, 12.0);
    try approx((TabBarConfig{ .radius = 40.0 }).sanitize().radius, 14.0);
}

test "clampFont and clampRadius stay in range" {
    try approx(theme.clampFontSize(std.math.nan(f32)), 12.0);
    try approx(theme.clampRadius(std.math.nan(f32)), 10.0);
    try approx(theme.clampRadius(12.0), 12.0);
}
