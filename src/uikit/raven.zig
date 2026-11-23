//! Raven C API for src/uikit: the only place Raven names, enum values and
//! externs are declared. Written by hand from vendor/raven/include/raven/*.h
//! (no @cImport). Enum values were checked against the headers with a C probe
//! (`cc -I vendor/raven/include`). Keep them in sync when Raven changes.
//!
//! Only the uikit modules call these functions. A `zig test` of a module that
//! never calls an extern does not link Raven, so the pure helpers stay testable.
const std = @import("std");

/// Opaque Raven handle (uint32_t). `invalid` is R_INVALID_ID.
pub const Rid = u32;
pub const invalid: Rid = 0xFFFF_FFFF;

// ---------------------------------------------------------------------------
// Enums (raven_widget.h, raven_style.h, raven_layout.h, raven_controls.h).
// Non-exhaustive, so a value Raven adds later does not break the Zig side.
// ---------------------------------------------------------------------------

/// R_WIDGET_* kinds used by uikit.
pub const WidgetType = enum(c_int) {
    vbox = 0x0200,
    hbox = 0x0201,
    border = 0x0205,
    scroll_box = 0x0208,
    tab_view = 0x020D,
    expander = 0x020E,
    label = 0x020F,
    button = 0x0210,
    checkbox = 0x0211,
    slider = 0x0212,
    progressbar = 0x0213,
    text_input = 0x0215,
    spin_box = 0x0216,
    combo_box = 0x0217,
    separator = 0x0218,
    /// R_WIDGET_CUSTOM: painted by an application callback.
    custom = 0x021F,
    background_blur = 0x0225,
    _,
};

/// R_HORIZONTAL / R_VERTICAL.
pub const Orientation = enum(c_int) {
    horizontal = 0x0270,
    vertical = 0x0271,
    _,
};

/// R_VISIBLE / R_HIDDEN / R_COLLAPSED.
pub const Visibility = enum(c_int) {
    visible = 0x0260,
    hidden = 0x0261,
    collapsed = 0x0262,
    _,
};

/// R_BUTTON_DEFAULT / R_BUTTON_PRIMARY / R_BUTTON_FLAT.
pub const ButtonStyle = enum(c_int) {
    default = 0x0290,
    primary = 0x0291,
    flat = 0x0292,
    _,
};

/// R_CHECKBOX_CHECK / R_CHECKBOX_RADIO / R_CHECKBOX_SWITCH.
pub const CheckboxStyle = enum(c_int) {
    check = 0x02A0,
    radio = 0x02A1,
    @"switch" = 0x02A2,
    _,
};

/// R_TEXT_ALIGN_LEFT / R_TEXT_ALIGN_CENTER / R_TEXT_ALIGN_RIGHT (raven_controls.h).
pub const TextAlign = enum(c_int) {
    left = 0x0280,
    center = 0x0281,
    right = 0x0282,
    _,
};

/// R_MATERIAL_* (raven_style.h).
pub const Material = enum(c_int) {
    solid = 0x02E0,
    glass = 0x02E1,
    frosted_glass = 0x02E2,
    tinted_glass = 0x02E3,
    default = 0x02E4,
    _,
};

/// R_THEME_* (raven_style.h). Only the glass themes are used.
pub const Theme = enum(c_int) {
    dark = 0x00E0,
    light = 0x00E1,
    glass_dark = 0x00E2,
    glass_light = 0x00E3,
    _,
};

/// R_BLUR_* (raven_layout.h).
pub const BlurStyle = enum(c_int) {
    plain = 0x0440,
    frosted = 0x0441,
    glass = 0x0442,
    native = 0x0443,
    _,
};

/// R_COLOR_* roles, in header order from R_COLOR_WINDOW = 0x0100.
pub const ColorRole = enum(c_int) {
    window = 0x0100,
    panel = 0x0101,
    border = 0x0102,
    text = 0x0103,
    text_disabled = 0x0104,
    text_placeholder = 0x0105,
    accent = 0x0106,
    accent_hovered = 0x0107,
    accent_pressed = 0x0108,
    accent_text = 0x0109,
    control = 0x010A,
    control_hovered = 0x010B,
    control_pressed = 0x010C,
    control_border = 0x010D,
    input = 0x010E,
    focus = 0x010F,
    selection = 0x0110,
    row_hovered = 0x0111,
    track = 0x0112,
    handle = 0x0113,
    handle_hovered = 0x0114,
    separator = 0x0115,
    header = 0x0116,
    header_hovered = 0x0117,
    tab_active = 0x0118,
    popup = 0x0119,
    popup_border = 0x011A,
    shadow = 0x011B,
    tooltip = 0x011C,
    tooltip_text = 0x011D,
    @"switch" = 0x011E,
    success = 0x011F,
    warning = 0x0120,
    danger = 0x0121,
    link = 0x0122,
    code = 0x0123,
    _,
};

/// R_METRIC_* (raven_style.h).
pub const Metric = enum(c_int) {
    font_size = 0x0140,
    corner_radius = 0x0141,
    border_width = 0x0142,
    control_height = 0x0143,
    padding_x = 0x0144,
    padding_y = 0x0145,
    spacing = 0x0146,
    scrollbar_size = 0x0147,
    row_height = 0x0148,
    indent = 0x0149,
    splitter_size = 0x014A,
    check_size = 0x014B,
    slider_handle_size = 0x014C,
    popup_radius = 0x014D,
    glass_frost = 0x014E,
    glass_rim = 0x0151,
    glass_shadow = 0x0152,
    blur_radius = 0x0153,
    _,
};

/// Input event of a widget (raven_window.h). Layout must match the C struct.
pub const EventType = enum(c_int) {
    none = 0x00C0,
    mouse_move = 0x00C1,
    mouse_down = 0x00C2,
    mouse_up = 0x00C3,
    mouse_wheel = 0x00C4,
    mouse_enter = 0x00C5,
    mouse_leave = 0x00C6,
    key_down = 0x00C7,
    key_up = 0x00C8,
    text = 0x00C9,
    focus_gained = 0x00CA,
    focus_lost = 0x00CB,
    _,
};

/// RMouseButton values (raven_window.h).
pub const mouse_left: c_int = 0;
pub const mouse_right: c_int = 1;

pub const Event = extern struct {
    type: EventType,
    window: Rid,
    target: Rid,
    x: f32,
    y: f32,
    local_x: f32,
    local_y: f32,
    delta_x: f32,
    delta_y: f32,
    wheel_x: f32,
    wheel_y: f32,
    button: c_int,
    clicks: c_int,
    key: c_int,
    modifiers: c_uint,
    repeat: c_int,
    codepoint: c_uint,
};

// ---------------------------------------------------------------------------
// Callback shapes (ABI-compatible with the typedefs in the headers).
// ---------------------------------------------------------------------------

pub const ClickedCallback = *const fn (button: Rid, user_data: ?*anyopaque) callconv(.c) void;
pub const CheckboxChangedCallback = *const fn (checkbox: Rid, checked: c_int, user_data: ?*anyopaque) callconv(.c) void;
pub const SliderChangedCallback = *const fn (slider: Rid, value: f32, user_data: ?*anyopaque) callconv(.c) void;
pub const SpinBoxChangedCallback = *const fn (spin_box: Rid, value: f64, user_data: ?*anyopaque) callconv(.c) void;
pub const ComboBoxChangedCallback = *const fn (combo_box: Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void;
pub const TextChangedCallback = *const fn (text_input: Rid, text: [*:0]const u8, user_data: ?*anyopaque) callconv(.c) void;
pub const TabChangedCallback = *const fn (tab_view: Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void;
pub const ExpanderChangedCallback = *const fn (expander: Rid, expanded: c_int, user_data: ?*anyopaque) callconv(.c) void;
pub const TimerCallback = *const fn (timer: Rid, user_data: ?*anyopaque) callconv(.c) void;
/// Event callback: return 1 to consume the event, 0 to let it continue.
pub const EventCallback = *const fn (widget: Rid, event: *const Event, user_data: ?*anyopaque) callconv(.c) c_int;
pub const DialogClosedCallback = *const fn (content: Rid, result: c_int, user_data: ?*anyopaque) callconv(.c) void;

// ---------------------------------------------------------------------------
// raven_widget.h
// ---------------------------------------------------------------------------

pub extern fn Rwidget_create(kind: WidgetType) Rid;
pub extern fn Rwidget_destroy(widget: Rid) void;
pub extern fn Rwidget_add_child(parent: Rid, child: Rid) Rid;
pub extern fn Rwidget_get_child_count(widget: Rid) c_int;
pub extern fn Rwidget_get_child(widget: Rid, index: c_int) Rid;
pub extern fn Rwidget_set_enabled(widget: Rid, enabled: c_int) void;
pub extern fn Rwidget_set_visibility(widget: Rid, visibility: Visibility) void;
pub extern fn Rwidget_set_tooltip(widget: Rid, text: [*:0]const u8) void;
/// Attaches a parentless MENU as the context menu of `widget`.
pub extern fn Rwidget_set_context_menu(widget: Rid, menu: Rid) void;
pub extern fn Rwidget_set_event_callback(widget: Rid, callback: ?EventCallback, user_data: ?*anyopaque) void;
pub extern fn Rwidget_set_size(widget: Rid, width: f32, height: f32) void;
pub extern fn Rwidget_set_min_size(widget: Rid, width: f32, height: f32) void;
pub extern fn Rwidget_set_color(widget: Rid, role: ColorRole, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rwidget_set_metric(widget: Rid, metric: Metric, value: f32) void;
pub extern fn Rwidget_set_material(widget: Rid, material: Material) void;
pub extern fn Rwidget_set_focusable(widget: Rid, focusable: c_int) void;
pub extern fn Rwidget_set_user_handle(widget: Rid, handle: ?*anyopaque) void;
pub extern fn Rwidget_get_user_handle(widget: Rid) ?*anyopaque;
pub extern fn Rwidget_invalidate(widget: Rid) void;
pub extern fn Rslot_set_padding(child: Rid, left: f32, top: f32, right: f32, bottom: f32) void;
pub extern fn Rslot_set_fill(child: Rid, coefficient: f32) void;

// ---------------------------------------------------------------------------
// raven_layout.h
// ---------------------------------------------------------------------------

pub extern fn Rborder_set_padding(border: Rid, left: f32, top: f32, right: f32, bottom: f32) void;
pub extern fn Rborder_set_background(border: Rid, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rborder_set_outline(border: Rid, width: f32, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rborder_set_corner_radius(border: Rid, tl: f32, tr: f32, br: f32, bl: f32) void;
pub extern fn Rborder_set_shadow(border: Rid, blur: f32, offset_x: f32, offset_y: f32) void;
pub extern fn Rborder_set_material(border: Rid, material: Material) void;

pub extern fn Rbackground_blur_create() Rid;
pub extern fn Rbackground_blur_set_style(blur: Rid, style: BlurStyle) void;
pub extern fn Rbackground_blur_set_radius(blur: Rid, radius: f32) void;
pub extern fn Rbackground_blur_set_tint(blur: Rid, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rbackground_blur_set_shadow(blur: Rid, shadow_blur: f32) void;
pub extern fn Rbackground_blur_set_corner_radius(blur: Rid, tl: f32, tr: f32, br: f32, bl: f32) void;

pub extern fn Rpanel_set_spacing(panel: Rid, spacing: f32) void;
pub extern fn Rscroll_box_set_orientation(scroll_box: Rid, orientation: Orientation) void;
pub extern fn Rscroll_box_set_scroll_both(scroll_box: Rid, enabled: c_int) void;

pub extern fn Rtab_view_add_tab(tab_view: Rid, title: [*:0]const u8, content: Rid) c_int;
pub extern fn Rtab_view_set_active(tab_view: Rid, index: c_int) void;
pub extern fn Rtab_view_set_changed_callback(tab_view: Rid, callback: ?TabChangedCallback, user_data: ?*anyopaque) void;

// ---------------------------------------------------------------------------
// raven_controls.h
// ---------------------------------------------------------------------------

pub extern fn Rlabel_create(text: [*:0]const u8) Rid;
pub extern fn Rlabel_set_text(label: Rid, text: [*:0]const u8) void;
pub extern fn Rlabel_set_text_size(label: Rid, size: f32) void;
pub extern fn Rlabel_set_text_align(label: Rid, alignment: TextAlign) void;
pub extern fn Rlabel_set_color(label: Rid, r: f32, g: f32, b: f32, a: f32) void;

pub extern fn Rbutton_create(text: [*:0]const u8) Rid;
pub extern fn Rbutton_set_text(button: Rid, text: [*:0]const u8) void;
pub extern fn Rbutton_set_style(button: Rid, style: ButtonStyle) void;
pub extern fn Rbutton_set_clicked_callback(button: Rid, cb: ?ClickedCallback, user_data: ?*anyopaque) void;

pub extern fn Rcheckbox_create(text: [*:0]const u8) Rid;
pub extern fn Rcheckbox_set_text(checkbox: Rid, text: [*:0]const u8) void;
pub extern fn Rcheckbox_set_checked(checkbox: Rid, checked: c_int) void;
pub extern fn Rcheckbox_is_checked(checkbox: Rid) c_int;
pub extern fn Rcheckbox_set_style(checkbox: Rid, style: CheckboxStyle) void;
pub extern fn Rcheckbox_set_changed_callback(checkbox: Rid, cb: ?CheckboxChangedCallback, user_data: ?*anyopaque) void;

pub extern fn Rslider_set_range(slider: Rid, minimum: f32, maximum: f32) void;
pub extern fn Rslider_set_value(slider: Rid, value: f32) void;
pub extern fn Rslider_get_value(slider: Rid) f32;
pub extern fn Rslider_set_step(slider: Rid, step: f32) void;
pub extern fn Rslider_set_orientation(slider: Rid, orientation: Orientation) void;
pub extern fn Rslider_set_changed_callback(slider: Rid, cb: ?SliderChangedCallback, user_data: ?*anyopaque) void;

pub extern fn Rprogress_bar_set_value(progress_bar: Rid, value: f32) void;
pub extern fn Rprogress_bar_get_value(progress_bar: Rid) f32;

pub extern fn Rtext_input_set_text(text_input: Rid, text: [*:0]const u8) void;
pub extern fn Rtext_input_get_text(text_input: Rid) [*:0]const u8;
pub extern fn Rtext_input_set_placeholder(text_input: Rid, text: [*:0]const u8) void;
pub extern fn Rtext_input_set_max_length(text_input: Rid, max_length: c_int) void;
pub extern fn Rtext_input_set_changed_callback(text_input: Rid, cb: ?TextChangedCallback, user_data: ?*anyopaque) void;
pub extern fn Rtext_input_set_committed_callback(text_input: Rid, cb: ?TextChangedCallback, user_data: ?*anyopaque) void;

pub extern fn Rspin_box_set_range(spin_box: Rid, minimum: f64, maximum: f64) void;
pub extern fn Rspin_box_set_value(spin_box: Rid, value: f64) void;
pub extern fn Rspin_box_get_value(spin_box: Rid) f64;
pub extern fn Rspin_box_set_step(spin_box: Rid, step: f64) void;
pub extern fn Rspin_box_set_decimals(spin_box: Rid, decimals: c_int) void;
pub extern fn Rspin_box_set_changed_callback(spin_box: Rid, cb: ?SpinBoxChangedCallback, user_data: ?*anyopaque) void;

pub extern fn Rcombo_box_add_item(combo_box: Rid, text: [*:0]const u8) c_int;
pub extern fn Rcombo_box_clear_items(combo_box: Rid) void;
pub extern fn Rcombo_box_set_selected(combo_box: Rid, index: c_int) void;
pub extern fn Rcombo_box_get_selected(combo_box: Rid) c_int;
pub extern fn Rcombo_box_set_changed_callback(combo_box: Rid, cb: ?ComboBoxChangedCallback, user_data: ?*anyopaque) void;

pub extern fn Rseparator_set_orientation(separator: Rid, orientation: Orientation) void;

pub extern fn Rexpander_set_title(expander: Rid, title: [*:0]const u8) void;
pub extern fn Rexpander_set_expanded(expander: Rid, expanded: c_int) void;
pub extern fn Rexpander_is_expanded(expander: Rid) c_int;
pub extern fn Rexpander_set_changed_callback(expander: Rid, cb: ?ExpanderChangedCallback, user_data: ?*anyopaque) void;

pub extern fn Rdialog_open(window: Rid, content: Rid, closed: ?DialogClosedCallback, user_data: ?*anyopaque) void;
pub extern fn Rdialog_close(widget: Rid, result: c_int) void;
pub extern fn Rdialog_run(window: Rid, content: Rid) c_int;
pub extern fn Rwindow_has_dialog(window: Rid) c_int;

// ---------------------------------------------------------------------------
// raven_core.h (timers) and raven_style.h (theme).
// ---------------------------------------------------------------------------

pub extern fn Rtimer_create(interval_seconds: f64, repeat: c_int, callback: TimerCallback, user_data: ?*anyopaque) Rid;
pub extern fn Rtimer_destroy(timer: Rid) void;
pub extern fn Rtimer_is_valid(timer: Rid) c_int;

pub extern fn Rtheme_apply(theme_id: Theme) void;
pub extern fn Rtheme_set_color(role: ColorRole, r: f32, g: f32, b: f32, a: f32) void;

// ---------------------------------------------------------------------------
// Application and window (raven_core.h, raven_window.h).
// ---------------------------------------------------------------------------

// raven_core.h: RBackend and RInitDesc (the app entry points used by the demo).
pub const backend_vulkan: c_int = 0x0001;
pub const InitDesc = extern struct {
    backend: c_int = 0,
    app_name: ?[*:0]const u8 = null,
    worker_threads: c_int = 0,
    disable_render_thread: c_int = 0,
    disable_vsync: c_int = 0,
    enable_validation: c_int = 0,
    headless: c_int = 0,
    ui_scale: f32 = 0,
};
pub extern fn Rinit_ex(desc: *const InitDesc) c_int;
pub extern fn Rshutdown() void;
pub extern fn Rwait_frame(timeout_seconds: f64) c_int;
// raven_window.h
pub extern fn Rwindow_create(title: [*:0]const u8, width: c_int, height: c_int, flags: c_uint) Rid;
pub extern fn Rwindow_set_content(window: Rid, widget: Rid) void;
pub extern fn Rwindow_set_clear_color(window: Rid, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rwindow_show(window: Rid) void;
