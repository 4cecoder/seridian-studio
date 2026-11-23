// Seridian: extern declarations the platform module needs from OTHER modules of Raven (core).
// Not a translation of one Raven file: it mirrors core/accessibility.h (no header unit exists for it yet),
// and re-exports the pieces of core/thread.h / core/handle.h the platform files use.
// When core/accessibility_h.zig exists, the platform files should switch to it and this file can shrink.
//
//   const ext = @import("../externs.zig");      // from src/platform/<os>/
//   const ext = @import("externs.zig");         // from src/platform/
//
// Declared elsewhere already (do not repeat):
//   base_h.zig   rvn_alloc, rvn_calloc, rvn_realloc, rvn_free, rvn_strdup, rvn_strndup, rvn_str_set,
//                rvn_utf8_decode, rvn_utf8_encode, rvn_error, rvn_maxi, rvn_clampf
//   raven.zig    Rget_version, Raccessibility_is_screen_reader_active, Rwindow_set_icon, Rwindow_inject_*
// NOT here: g_rvn (core/context.h, used by atspi.c: g_rvn.windows is an rvn_pool_t) needs a core/context_h.zig.

const raven = @import("raven");
pub const thread = @import("../core/thread_h.zig");
pub const handle = @import("../core/handle_h.zig");

// ---------------------------------------------------------------------------
//  core/handle.h (rvn_pool_at is used by atspi.c to walk g_rvn.windows)
// ---------------------------------------------------------------------------
pub const rvn_pool_t = handle.rvn_pool_t;
pub const rvn_pool_at = handle.rvn_pool_at;

// ---------------------------------------------------------------------------
//  core/thread.h (null_platform.c: mutex and condition variable of the injected-event queue)
// ---------------------------------------------------------------------------
pub const rvn_mutex_t = thread.rvn_mutex_t;
pub const rvn_cond_t = thread.rvn_cond_t;
pub const rvn_mutex_init = thread.rvn_mutex_init;
pub const rvn_mutex_destroy = thread.rvn_mutex_destroy;
pub const rvn_mutex_lock = thread.rvn_mutex_lock;
pub const rvn_mutex_unlock = thread.rvn_mutex_unlock;
pub const rvn_cond_init = thread.rvn_cond_init;
pub const rvn_cond_destroy = thread.rvn_cond_destroy;
pub const rvn_cond_wait = thread.rvn_cond_wait;
pub const rvn_cond_wait_timeout = thread.rvn_cond_wait_timeout;
pub const rvn_cond_signal = thread.rvn_cond_signal;

// ---------------------------------------------------------------------------
//  core/accessibility.h
// ---------------------------------------------------------------------------
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
pub const RVN_A11Y_EVENT_FOCUS: c_int = 1;
pub const RVN_A11Y_EVENT_NAME: c_int = 2;
pub const RVN_A11Y_EVENT_VALUE: c_int = 3;
pub const RVN_A11Y_EVENT_STATE: c_int = 4;
pub const RVN_A11Y_EVENT_STRUCTURE: c_int = 5;

pub const rvn_a11y_action_t = c_uint;
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
