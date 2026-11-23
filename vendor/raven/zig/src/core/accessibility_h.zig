// Translated to Zig from vendor/raven/src/core/accessibility.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/accessibility.h
// The tree that screen readers see, for the platforms (UI Automation,
// NSAccessibility, AT-SPI). Implemented in core/accessibility.c. UI thread.
//
// A node is a window, a widget, or an item of a widget (a row of a list):
//     window    the Rid of the window
//     widget    the Rid of the widget
//     item      the Rid of the widget | (index + 1) << 32
// The widgets that only lay others out are not nodes: their children are
// the children of the nearest node above them.

const raven = @import("raven");

pub const rvn_a11y_id_t = u64;

pub const RVN_A11Y_FOCUSABLE: u32 = 1 << 0;
pub const RVN_A11Y_FOCUSED: u32 = 1 << 1;
pub const RVN_A11Y_DISABLED: u32 = 1 << 2;
pub const RVN_A11Y_CHECKED: u32 = 1 << 3;
pub const RVN_A11Y_CHECKABLE: u32 = 1 << 4;
pub const RVN_A11Y_EXPANDED: u32 = 1 << 5;
pub const RVN_A11Y_EXPANDABLE: u32 = 1 << 6;
pub const RVN_A11Y_SELECTED: u32 = 1 << 7;
pub const RVN_A11Y_SELECTABLE: u32 = 1 << 8;
pub const RVN_A11Y_MULTILINE: u32 = 1 << 9;
pub const RVN_A11Y_READONLY: u32 = 1 << 10;
pub const RVN_A11Y_PASSWORD: u32 = 1 << 11;
/// value, min, max are numbers
pub const RVN_A11Y_HAS_RANGE: u32 = 1 << 12;
/// the value is a text that can be set
pub const RVN_A11Y_EDITABLE: u32 = 1 << 13;
/// it can be pressed
pub const RVN_A11Y_INVOKABLE: u32 = 1 << 14;
pub const RVN_A11Y_OFFSCREEN: u32 = 1 << 15;
pub const RVN_A11Y_MODAL: u32 = 1 << 16;

/// What a node is now. The strings stay valid until the next call to rvn_a11y_describe.
pub const rvn_a11y_node_t = extern struct {
    id: rvn_a11y_id_t,
    role: raven.RAccessibleRole,
    name: [*c]const u8,
    description: [*c]const u8,
    /// Text value (a text field, the selected item of a list), or "".
    value: [*c]const u8,
    number: f64,
    minimum: f64,
    maximum: f64,
    step: f64,
    states: u32,
    /// In the window, logical units.
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};
pub const struct_rvn_a11y_node_t = rvn_a11y_node_t;

pub const rvn_a11y_event_t = c_uint;
pub const enum_rvn_a11y_event_t = rvn_a11y_event_t;
pub const RVN_A11Y_EVENT_FOCUS: c_int = 1;
pub const RVN_A11Y_EVENT_NAME: c_int = 2;
pub const RVN_A11Y_EVENT_VALUE: c_int = 3;
pub const RVN_A11Y_EVENT_STATE: c_int = 4;
pub const RVN_A11Y_EVENT_STRUCTURE: c_int = 5;

pub const rvn_a11y_action_t = c_uint;
pub const enum_rvn_a11y_action_t = rvn_a11y_action_t;
/// button, menu item, link, tab, list item: what a click does
pub const RVN_A11Y_PRESS: c_int = 1;
/// check box
pub const RVN_A11Y_TOGGLE: c_int = 2;
pub const RVN_A11Y_EXPAND: c_int = 3;
pub const RVN_A11Y_COLLAPSE: c_int = 4;
pub const RVN_A11Y_FOCUS: c_int = 5;
pub const RVN_A11Y_SELECT: c_int = 6;

/// The window a platform window shows (its `user`).
pub extern fn rvn_a11y_window_of(platform_user: ?*anyopaque) raven.Rid;

/// R_FALSE when the node is gone.
pub extern fn rvn_a11y_describe(id: rvn_a11y_id_t, node: [*c]rvn_a11y_node_t) c_int;
pub extern fn rvn_a11y_exists(id: rvn_a11y_id_t) c_int;
/// The window of a node.
pub extern fn rvn_a11y_window(id: rvn_a11y_id_t) raven.Rid;
/// 0 for a window.
pub extern fn rvn_a11y_parent(id: rvn_a11y_id_t) rvn_a11y_id_t;
pub extern fn rvn_a11y_child_count(id: rvn_a11y_id_t) c_int;
pub extern fn rvn_a11y_child(id: rvn_a11y_id_t, index: c_int) rvn_a11y_id_t;
/// Index among the children of its parent, -1 for a window.
pub extern fn rvn_a11y_index_in_parent(id: rvn_a11y_id_t) c_int;
/// The deepest node at a point of the window (logical units), or the window.
pub extern fn rvn_a11y_hit(window: raven.Rid, x: f32, y: f32) rvn_a11y_id_t;
/// The node that has the focus in the window, or the window.
pub extern fn rvn_a11y_focus(window: raven.Rid) rvn_a11y_id_t;

pub extern fn rvn_a11y_act(id: rvn_a11y_id_t, action: rvn_a11y_action_t) c_int;
pub extern fn rvn_a11y_set_value(id: rvn_a11y_id_t, text: [*c]const u8) c_int;
pub extern fn rvn_a11y_set_number(id: rvn_a11y_id_t, value: f64) c_int;

/// Where a node is on the screen, in pixels (for the platforms that ask in screen coordinates).
pub extern fn rvn_a11y_screen_rect(id: rvn_a11y_id_t, x: [*c]c_int, y: [*c]c_int, width: [*c]c_int, height: [*c]c_int) void;
/// Pixels per logical unit of the window of a node, and where its client area is on the screen.
pub extern fn rvn_a11y_window_origin(id: rvn_a11y_id_t, x: [*c]c_int, y: [*c]c_int, scale: [*c]f32) void;
/// The language of the application, for the screen reader ("en", "fr-FR").
pub extern fn rvn_a11y_locale() [*c]const u8;

/// Names of the roles, for logs and for the platforms that want one ("push button").
pub extern fn rvn_a11y_role_name(role: raven.RAccessibleRole) [*c]const u8;
