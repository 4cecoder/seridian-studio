// Translated to Zig from vendor/raven/src/platform/atspi.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/atspi.c
// The windows of Raven for the screen readers of Linux and the BSDs (Orca):
// AT-SPI 2, spoken over D-Bus.
//
// libdbus is loaded when it is needed (dlopen "libdbus-1.so.3", present on
// every desktop): Raven links with nothing more. The bridge connects to the
// accessibility bus only when the desktop says that assistive technologies
// are on (org.a11y.Status IsEnabled / ScreenReaderEnabled), or when
// AT_SPI_BUS_ADDRESS is set; otherwise it costs nothing.
//
// Every node of core/accessibility.h is an object:
//     /org/a11y/atspi/accessible/root        the application (children: the windows)
//     /org/a11y/atspi/accessible/<hex id>    a window, a widget, an item
// with the interfaces Accessible, Component, Action, Value, Text and
// EditableText where they apply. The focus, the changes of value and of
// structure, and the announcements are sent as AT-SPI events.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const platform = @import("platform_h.zig");
const a11y = @import("../core/accessibility_h.zig");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const handle_h = @import("../core/handle_h.zig");
const libc = @import("../sys/libc.zig");

// `#if !defined(_WIN32) && !defined(__APPLE__)`: the C file defines nothing on Windows and macOS,
// so the exports below are only made on the other systems.
const compiled = builtin.os.tag != .windows and !builtin.os.tag.isDarwin();

const rvn_a11y_id_t = a11y.rvn_a11y_id_t;
const rvn_a11y_node_t = a11y.rvn_a11y_node_t;

// Declared here, not in libc.zig (which does not have them yet).
extern "c" fn atof(s: [*c]const u8) f64;
extern "c" fn strtoull(s: [*c]const u8, end: [*c][*c]u8, base_: c_int) c_ulonglong;
const RTLD_LOCAL = 0; // glibc and musl (the systems of this file)

// ---------------------------------------------------------------------------
//  The part of libdbus that is used (its ABI is stable since 1.0)
// ---------------------------------------------------------------------------

const DBusConnection = opaque {};
const DBusMessage = opaque {};
const dbus_bool_t = u32;
const DBusError = extern struct {
    name: [*c]const u8,
    message: [*c]const u8,
    dummy: c_uint,
    padding1: ?*anyopaque,
};
// (larger than the real one, which libdbus fills)
const DBusMessageIter = extern struct {
    dummy: [16]?*anyopaque,
};
const DBusHandleMessageFunction = ?*const fn (?*DBusConnection, ?*DBusMessage, ?*anyopaque) callconv(.c) c_int;
const DBusObjectPathVTable = extern struct {
    unregister_function: ?*const fn (?*DBusConnection, ?*anyopaque) callconv(.c) void,
    message_function: DBusHandleMessageFunction,
    pad1: ?*const fn (?*anyopaque) callconv(.c) void,
    pad2: ?*const fn (?*anyopaque) callconv(.c) void,
    pad3: ?*const fn (?*anyopaque) callconv(.c) void,
    pad4: ?*const fn (?*anyopaque) callconv(.c) void,
};

const DBUS_BUS_SESSION = 0;
const DBUS_HANDLER_RESULT_HANDLED = 0;
const DBUS_HANDLER_RESULT_NOT_YET_HANDLED = 1;
const DBUS_DISPATCH_DATA_REMAINS = 0;
const DBUS_MESSAGE_TYPE_METHOD_CALL = 1;
const T_INVALID = 0;
const T_BYTE = 'y';
const T_BOOLEAN = 'b';
const T_INT16 = 'n';
const T_INT32 = 'i';
const T_UINT32 = 'u';
const T_DOUBLE = 'd';
const T_STRING = 's';
const T_OBJECT_PATH = 'o';
const T_ARRAY = 'a';
const T_VARIANT = 'v';
const T_STRUCT = 'r';
const T_DICT_ENTRY = 'e';

const AtspiState = extern struct {
    library: ?*anyopaque,
    error_init: ?*const fn ([*c]DBusError) callconv(.c) void,
    error_free: ?*const fn ([*c]DBusError) callconv(.c) void,
    error_is_set: ?*const fn ([*c]const DBusError) callconv(.c) dbus_bool_t,
    bus_get_private: ?*const fn (c_int, [*c]DBusError) callconv(.c) ?*DBusConnection,
    connection_open_private: ?*const fn ([*c]const u8, [*c]DBusError) callconv(.c) ?*DBusConnection,
    bus_register: ?*const fn (?*DBusConnection, [*c]DBusError) callconv(.c) dbus_bool_t,
    bus_get_unique_name: ?*const fn (?*DBusConnection) callconv(.c) [*c]const u8,
    connection_set_exit_on_disconnect: ?*const fn (?*DBusConnection, dbus_bool_t) callconv(.c) void,
    connection_close: ?*const fn (?*DBusConnection) callconv(.c) void,
    connection_unref: ?*const fn (?*DBusConnection) callconv(.c) void,
    connection_register_fallback: ?*const fn (?*DBusConnection, [*c]const u8, [*c]const DBusObjectPathVTable, ?*anyopaque) callconv(.c) dbus_bool_t,
    connection_read_write: ?*const fn (?*DBusConnection, c_int) callconv(.c) dbus_bool_t,
    connection_dispatch: ?*const fn (?*DBusConnection) callconv(.c) c_int,
    connection_send: ?*const fn (?*DBusConnection, ?*DBusMessage, [*c]u32) callconv(.c) dbus_bool_t,
    connection_flush: ?*const fn (?*DBusConnection) callconv(.c) void,
    connection_send_with_reply_and_block: ?*const fn (?*DBusConnection, ?*DBusMessage, c_int, [*c]DBusError) callconv(.c) ?*DBusMessage,
    connection_get_unix_fd: ?*const fn (?*DBusConnection, [*c]c_int) callconv(.c) dbus_bool_t,
    message_new_method_call: ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8, [*c]const u8) callconv(.c) ?*DBusMessage,
    message_new_method_return: ?*const fn (?*DBusMessage) callconv(.c) ?*DBusMessage,
    message_new_error: ?*const fn (?*DBusMessage, [*c]const u8, [*c]const u8) callconv(.c) ?*DBusMessage,
    message_new_signal: ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8) callconv(.c) ?*DBusMessage,
    message_unref: ?*const fn (?*DBusMessage) callconv(.c) void,
    message_get_type: ?*const fn (?*DBusMessage) callconv(.c) c_int,
    message_get_interface: ?*const fn (?*DBusMessage) callconv(.c) [*c]const u8,
    message_get_member: ?*const fn (?*DBusMessage) callconv(.c) [*c]const u8,
    message_get_path: ?*const fn (?*DBusMessage) callconv(.c) [*c]const u8,
    iter_init: ?*const fn (?*DBusMessage, [*c]DBusMessageIter) callconv(.c) dbus_bool_t,
    iter_init_append: ?*const fn (?*DBusMessage, [*c]DBusMessageIter) callconv(.c) void,
    iter_append_basic: ?*const fn ([*c]DBusMessageIter, c_int, ?*const anyopaque) callconv(.c) dbus_bool_t,
    iter_open_container: ?*const fn ([*c]DBusMessageIter, c_int, [*c]const u8, [*c]DBusMessageIter) callconv(.c) dbus_bool_t,
    iter_close_container: ?*const fn ([*c]DBusMessageIter, [*c]DBusMessageIter) callconv(.c) dbus_bool_t,
    iter_get_arg_type: ?*const fn ([*c]DBusMessageIter) callconv(.c) c_int,
    iter_get_basic: ?*const fn ([*c]DBusMessageIter, ?*anyopaque) callconv(.c) void,
    iter_next: ?*const fn ([*c]DBusMessageIter) callconv(.c) dbus_bool_t,
    iter_recurse: ?*const fn ([*c]DBusMessageIter, [*c]DBusMessageIter) callconv(.c) void,

    bus: ?*DBusConnection,
    unique: [128]u8,
    parent_name: [128]u8,
    parent_path: [256]u8,
    app_id: c_int,
    enabled: c_int,
    failed: c_int,
};
var g_atspi: AtspiState = std.mem.zeroes(AtspiState);

const ROOT_PATH = "/org/a11y/atspi/accessible/root";
const NODE_PREFIX = "/org/a11y/atspi/accessible/";
const NULL_PATH = "/org/a11y/atspi/null";

/// `*(void**)(&field) = dlsym(library, symbol); if (!field) goto missing`: false when the symbol is missing.
fn loadSymbol(field: anytype, library: ?*anyopaque, symbol: [*c]const u8) bool {
    field.* = @ptrCast(libc.dlsym(library, symbol));
    return field.* != null;
}

fn loadAllSymbols(library: ?*anyopaque) bool {
    if (!loadSymbol(&g_atspi.error_init, library, "dbus_error_init")) return false;
    if (!loadSymbol(&g_atspi.error_free, library, "dbus_error_free")) return false;
    if (!loadSymbol(&g_atspi.error_is_set, library, "dbus_error_is_set")) return false;
    if (!loadSymbol(&g_atspi.bus_get_private, library, "dbus_bus_get_private")) return false;
    if (!loadSymbol(&g_atspi.connection_open_private, library, "dbus_connection_open_private")) return false;
    if (!loadSymbol(&g_atspi.bus_register, library, "dbus_bus_register")) return false;
    if (!loadSymbol(&g_atspi.bus_get_unique_name, library, "dbus_bus_get_unique_name")) return false;
    if (!loadSymbol(&g_atspi.connection_set_exit_on_disconnect, library, "dbus_connection_set_exit_on_disconnect")) return false;
    if (!loadSymbol(&g_atspi.connection_close, library, "dbus_connection_close")) return false;
    if (!loadSymbol(&g_atspi.connection_unref, library, "dbus_connection_unref")) return false;
    if (!loadSymbol(&g_atspi.connection_register_fallback, library, "dbus_connection_register_fallback")) return false;
    if (!loadSymbol(&g_atspi.connection_read_write, library, "dbus_connection_read_write")) return false;
    if (!loadSymbol(&g_atspi.connection_dispatch, library, "dbus_connection_dispatch")) return false;
    if (!loadSymbol(&g_atspi.connection_send, library, "dbus_connection_send")) return false;
    if (!loadSymbol(&g_atspi.connection_flush, library, "dbus_connection_flush")) return false;
    if (!loadSymbol(&g_atspi.connection_send_with_reply_and_block, library, "dbus_connection_send_with_reply_and_block")) return false;
    if (!loadSymbol(&g_atspi.connection_get_unix_fd, library, "dbus_connection_get_unix_fd")) return false;
    if (!loadSymbol(&g_atspi.message_new_method_call, library, "dbus_message_new_method_call")) return false;
    if (!loadSymbol(&g_atspi.message_new_method_return, library, "dbus_message_new_method_return")) return false;
    if (!loadSymbol(&g_atspi.message_new_error, library, "dbus_message_new_error")) return false;
    if (!loadSymbol(&g_atspi.message_new_signal, library, "dbus_message_new_signal")) return false;
    if (!loadSymbol(&g_atspi.message_unref, library, "dbus_message_unref")) return false;
    if (!loadSymbol(&g_atspi.message_get_type, library, "dbus_message_get_type")) return false;
    if (!loadSymbol(&g_atspi.message_get_interface, library, "dbus_message_get_interface")) return false;
    if (!loadSymbol(&g_atspi.message_get_member, library, "dbus_message_get_member")) return false;
    if (!loadSymbol(&g_atspi.message_get_path, library, "dbus_message_get_path")) return false;
    if (!loadSymbol(&g_atspi.iter_init, library, "dbus_message_iter_init")) return false;
    if (!loadSymbol(&g_atspi.iter_init_append, library, "dbus_message_iter_init_append")) return false;
    if (!loadSymbol(&g_atspi.iter_append_basic, library, "dbus_message_iter_append_basic")) return false;
    if (!loadSymbol(&g_atspi.iter_open_container, library, "dbus_message_iter_open_container")) return false;
    if (!loadSymbol(&g_atspi.iter_close_container, library, "dbus_message_iter_close_container")) return false;
    if (!loadSymbol(&g_atspi.iter_get_arg_type, library, "dbus_message_iter_get_arg_type")) return false;
    if (!loadSymbol(&g_atspi.iter_get_basic, library, "dbus_message_iter_get_basic")) return false;
    if (!loadSymbol(&g_atspi.iter_next, library, "dbus_message_iter_next")) return false;
    if (!loadSymbol(&g_atspi.iter_recurse, library, "dbus_message_iter_recurse")) return false;
    return true;
}

fn rvn_atspi_load() c_int {
    const names = [_][*c]const u8{ "libdbus-1.so.3", "libdbus-1.so" };
    var i: usize = 0;
    if (g_atspi.library != null) return raven.R_TRUE;
    while (i < names.len and g_atspi.library == null) : (i += 1) {
        g_atspi.library = libc.dlopen(names[i], libc.RTLD_NOW | RTLD_LOCAL);
    }
    if (g_atspi.library == null) return raven.R_FALSE;
    if (loadAllSymbols(g_atspi.library)) return raven.R_TRUE;
    // missing:
    _ = libc.dlclose(g_atspi.library);
    g_atspi.library = null;
    return raven.R_FALSE;
}

// ---------------------------------------------------------------------------
//  Writing values
// ---------------------------------------------------------------------------

fn put_string(it: [*c]DBusMessageIter, s: [*c]const u8) void {
    var s_ = s;
    if (s_ == null) s_ = "";
    _ = g_atspi.iter_append_basic.?(it, T_STRING, @ptrCast(&s_));
}

fn put_path(it: [*c]DBusMessageIter, s: [*c]const u8) void {
    _ = g_atspi.iter_append_basic.?(it, T_OBJECT_PATH, @ptrCast(&s));
}

fn put_i32(it: [*c]DBusMessageIter, v: i32) void {
    _ = g_atspi.iter_append_basic.?(it, T_INT32, &v);
}

fn put_u32(it: [*c]DBusMessageIter, v: u32) void {
    _ = g_atspi.iter_append_basic.?(it, T_UINT32, &v);
}

fn put_bool(it: [*c]DBusMessageIter, v: c_int) void {
    var b: dbus_bool_t = if (v != 0) 1 else 0;
    _ = g_atspi.iter_append_basic.?(it, T_BOOLEAN, &b);
}

fn put_double(it: [*c]DBusMessageIter, v: f64) void {
    _ = g_atspi.iter_append_basic.?(it, T_DOUBLE, &v);
}

fn node_path(id: rvn_a11y_id_t, out: [*c]u8, cap: usize) void {
    if (id == 0) {
        _ = libc.snprintf(out, cap, ROOT_PATH);
    } else {
        _ = libc.snprintf(out, cap, NODE_PREFIX ++ "%016llx", @as(c_ulonglong, id));
    }
}

// (so): a reference to an object of ours
fn put_ref(it: [*c]DBusMessageIter, id: rvn_a11y_id_t) void {
    var s: DBusMessageIter = undefined;
    var path: [96]u8 = undefined;
    node_path(id, &path, path.len);
    _ = g_atspi.iter_open_container.?(it, T_STRUCT, null, &s);
    put_string(&s, &g_atspi.unique);
    put_path(&s, &path);
    _ = g_atspi.iter_close_container.?(it, &s);
}

fn put_null_ref(it: [*c]DBusMessageIter) void {
    var s: DBusMessageIter = undefined;
    _ = g_atspi.iter_open_container.?(it, T_STRUCT, null, &s);
    put_string(&s, "");
    put_path(&s, NULL_PATH);
    _ = g_atspi.iter_close_container.?(it, &s);
}

fn put_parent_ref(it: [*c]DBusMessageIter) void {
    var s: DBusMessageIter = undefined;
    const parent_path: [*c]const u8 = if (g_atspi.parent_path[0] != 0) &g_atspi.parent_path else NULL_PATH;
    _ = g_atspi.iter_open_container.?(it, T_STRUCT, null, &s);
    put_string(&s, &g_atspi.parent_name);
    put_path(&s, parent_path);
    _ = g_atspi.iter_close_container.?(it, &s);
}

// ---------------------------------------------------------------------------
//  Nodes
// ---------------------------------------------------------------------------

// The root (the application) is 0. Returns R_FALSE for a path of nobody.
fn parse_path(path: [*c]const u8, id: [*c]rvn_a11y_id_t) c_int {
    if (path == null) return raven.R_FALSE;
    if (libc.strcmp(path, ROOT_PATH) == 0) {
        id.* = 0;
        return raven.R_TRUE;
    }
    if (libc.strncmp(path, NODE_PREFIX, libc.strlen(NODE_PREFIX)) != 0) return raven.R_FALSE;
    id.* = @intCast(strtoull(path + libc.strlen(NODE_PREFIX), null, 16));
    return @intFromBool(id.* != 0 and a11y.rvn_a11y_exists(id.*) != 0);
}

fn app_child_count() c_int {
    var i: u32 = 0;
    var count: c_int = 0;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        if (handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i) != null) count += 1;
    }
    return count;
}

fn app_child(index: c_int) rvn_a11y_id_t {
    var i: u32 = 0;
    var index_ = index;
    while (i < ctx_h.g_rvn.windows.used) : (i += 1) {
        const window: [*c]const raven.Rid = @ptrCast(@alignCast(handle_h.rvn_pool_at(&ctx_h.g_rvn.windows, i)));
        if (window == null) continue;
        const old = index_;
        index_ -= 1;
        if (old == 0) return @as(rvn_a11y_id_t, window.*);
    }
    return 0;
}

fn child_count(id: rvn_a11y_id_t) c_int {
    return if (id != 0) a11y.rvn_a11y_child_count(id) else app_child_count();
}

fn child_at(id: rvn_a11y_id_t, index: c_int) rvn_a11y_id_t {
    return if (id != 0) a11y.rvn_a11y_child(id, index) else app_child(index);
}

fn index_in_parent(id: rvn_a11y_id_t) c_int {
    if (id == 0) return -1;
    if (a11y.rvn_a11y_parent(id) == 0) {
        const n = app_child_count();
        var i: c_int = 0;
        while (i < n) : (i += 1) {
            if (app_child(i) == id) return i;
        }
        return -1;
    }
    return a11y.rvn_a11y_index_in_parent(id);
}

fn atspi_role(role: raven.RAccessibleRole, states: u32) u32 {
    switch (role) {
        raven.R_ROLE_WINDOW => return 23, // FRAME
        raven.R_ROLE_GROUP => return 39, // PANEL
        raven.R_ROLE_TEXT => return 29, // LABEL
        raven.R_ROLE_HEADING => return 83,
        raven.R_ROLE_LINK => return 88,
        raven.R_ROLE_BUTTON => return 43, // PUSH_BUTTON
        raven.R_ROLE_TOGGLE_BUTTON => return 62,
        raven.R_ROLE_CHECKBOX => return 7,
        raven.R_ROLE_RADIO_BUTTON => return 44,
        raven.R_ROLE_SLIDER => return 51,
        raven.R_ROLE_PROGRESS_BAR => return 42,
        raven.R_ROLE_SPIN_BUTTON => return 52,
        raven.R_ROLE_TEXT_FIELD => return if ((states & a11y.RVN_A11Y_PASSWORD) != 0) 40 else 79, // PASSWORD_TEXT, ENTRY
        raven.R_ROLE_DOCUMENT => return 94, // DOCUMENT_TEXT
        raven.R_ROLE_COMBO_BOX => return 11,
        raven.R_ROLE_LIST => return 98, // LIST_BOX
        raven.R_ROLE_LIST_ITEM => return 32,
        raven.R_ROLE_TREE => return 65,
        raven.R_ROLE_TREE_ITEM => return 91,
        raven.R_ROLE_TABLE => return 55,
        raven.R_ROLE_MENU_BAR => return 34,
        raven.R_ROLE_MENU => return 33,
        raven.R_ROLE_MENU_ITEM => return if ((states & a11y.RVN_A11Y_CHECKABLE) != 0) 8 else 35,
        raven.R_ROLE_TAB_LIST => return 38,
        raven.R_ROLE_TAB => return 37,
        raven.R_ROLE_TAB_PANEL => return 39,
        raven.R_ROLE_TOOLBAR => return 63,
        raven.R_ROLE_STATUS_BAR => return 54,
        raven.R_ROLE_DIALOG => return 16,
        raven.R_ROLE_ALERT => return 2,
        raven.R_ROLE_IMAGE => return 27,
        raven.R_ROLE_CANVAS => return 6,
        raven.R_ROLE_SEPARATOR => return 50,
        raven.R_ROLE_SCROLL_BAR => return 48,
        raven.R_ROLE_PANE => return 39,
        else => return 67, // UNKNOWN
    }
}

// (`#define S(n) (bits |= (uint64_t)1 << (n))`)
inline fn S(bits: *u64, n: u6) void {
    bits.* |= @as(u64, 1) << n;
}

fn put_states(it: [*c]DBusMessageIter, id: rvn_a11y_id_t, node: [*c]const rvn_a11y_node_t) void {
    var array: DBusMessageIter = undefined;
    var bits: u64 = 0;
    // (the application has no states)
    if (id != 0) {
        const st = node.*.states;
        S(&bits, 30);
        S(&bits, 25); // VISIBLE, SHOWING
        if ((st & a11y.RVN_A11Y_DISABLED) == 0) {
            S(&bits, 8);
            S(&bits, 24); // ENABLED, SENSITIVE
        }
        if ((st & a11y.RVN_A11Y_FOCUSABLE) != 0) S(&bits, 11);
        if ((st & a11y.RVN_A11Y_FOCUSED) != 0) S(&bits, 12);
        if ((st & a11y.RVN_A11Y_CHECKABLE) != 0) S(&bits, 41);
        if ((st & a11y.RVN_A11Y_CHECKED) != 0) S(&bits, 4);
        if ((st & a11y.RVN_A11Y_EXPANDABLE) != 0) {
            S(&bits, 9);
            if ((st & a11y.RVN_A11Y_EXPANDED) != 0) S(&bits, 10) else S(&bits, 5);
        }
        if ((st & a11y.RVN_A11Y_SELECTABLE) != 0) S(&bits, 22);
        if ((st & a11y.RVN_A11Y_SELECTED) != 0) S(&bits, 23);
        if ((st & a11y.RVN_A11Y_EDITABLE) != 0) S(&bits, 7);
        if ((st & a11y.RVN_A11Y_READONLY) != 0) S(&bits, 43);
        if ((st & a11y.RVN_A11Y_MODAL) != 0) S(&bits, 16);
        if ((st & a11y.RVN_A11Y_MULTILINE) != 0) {
            S(&bits, 17);
        } else if (node.*.role == raven.R_ROLE_TEXT_FIELD) {
            S(&bits, 26);
        }
        if (node.*.role == raven.R_ROLE_WINDOW) {
            S(&bits, 1);
            S(&bits, 21); // ACTIVE, RESIZABLE
        }
        if (node.*.role == raven.R_ROLE_TEXT or node.*.role == raven.R_ROLE_DOCUMENT) S(&bits, 38);
    }
    _ = g_atspi.iter_open_container.?(it, T_ARRAY, "u", &array);
    put_u32(&array, @truncate(bits));
    put_u32(&array, @truncate(bits >> 32));
    _ = g_atspi.iter_close_container.?(it, &array);
}

fn has_action(node: [*c]const rvn_a11y_node_t) c_int {
    return @intFromBool((node.*.states & (a11y.RVN_A11Y_INVOKABLE | a11y.RVN_A11Y_CHECKABLE | a11y.RVN_A11Y_EXPANDABLE)) != 0);
}

fn action_name(node: [*c]const rvn_a11y_node_t) [*c]const u8 {
    if (node.*.role == raven.R_ROLE_CHECKBOX) return "toggle";
    if (node.*.role == raven.R_ROLE_TAB or node.*.role == raven.R_ROLE_LIST_ITEM or node.*.role == raven.R_ROLE_TREE_ITEM) return "activate";
    if ((node.*.states & a11y.RVN_A11Y_EXPANDABLE) != 0 and (node.*.states & a11y.RVN_A11Y_INVOKABLE) == 0) return "expand or contract";
    return "click";
}

fn has_text(node: [*c]const rvn_a11y_node_t) c_int {
    return @intFromBool(node.*.role == raven.R_ROLE_TEXT or node.*.role == raven.R_ROLE_TEXT_FIELD or node.*.role == raven.R_ROLE_DOCUMENT or
        node.*.role == raven.R_ROLE_HEADING or node.*.role == raven.R_ROLE_SPIN_BUTTON or node.*.role == raven.R_ROLE_COMBO_BOX or
        node.*.role == raven.R_ROLE_LINK);
}

// The text of the Text interface: the value of a field, the name of a label.
fn node_text(node: [*c]const rvn_a11y_node_t) [*c]const u8 {
    if (node.*.role == raven.R_ROLE_TEXT_FIELD or node.*.role == raven.R_ROLE_DOCUMENT or node.*.role == raven.R_ROLE_SPIN_BUTTON or node.*.role == raven.R_ROLE_COMBO_BOX)
        return node.*.value;
    return node.*.name;
}

fn utf8_length(s: [*c]const u8) c_int {
    var n: c_int = 0;
    var s_ = s;
    while (s_[0] != 0) : (s_ += 1) {
        if ((s_[0] & 0xC0) != 0x80) n += 1;
    }
    return n;
}

// Byte offset of the character `index` (clamped).
fn utf8_offset(s: [*c]const u8, index: c_int) c_int {
    var i: c_int = 0;
    var n: c_int = 0;
    if (index <= 0) return 0;
    while (s[@as(usize, @intCast(i))] != 0) : (i += 1) {
        if ((s[@as(usize, @intCast(i))] & 0xC0) != 0x80) {
            if (n == index) return i;
            n += 1;
        }
    }
    return i;
}

// ---------------------------------------------------------------------------
//  Properties
// ---------------------------------------------------------------------------

fn variantOpen(it: [*c]DBusMessageIter, sig: [*c]const u8, v: [*c]DBusMessageIter) void {
    _ = g_atspi.iter_open_container.?(it, T_VARIANT, sig, v);
}

fn variantClose(it: [*c]DBusMessageIter, v: [*c]DBusMessageIter) void {
    _ = g_atspi.iter_close_container.?(it, v);
}

// Writes the value of a property in a variant; R_FALSE when the property is not known.
fn put_property(it: [*c]DBusMessageIter, id: rvn_a11y_id_t, node: [*c]const rvn_a11y_node_t, iface: [*c]const u8, name: [*c]const u8) c_int {
    var v: DBusMessageIter = undefined;
    if (libc.strcmp(iface, "org.a11y.atspi.Accessible") == 0) {
        if (libc.strcmp(name, "Name") == 0) {
            variantOpen(it, "s", &v);
            put_string(&v, if (id != 0) node.*.name else "Raven application");
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "Description") == 0) {
            variantOpen(it, "s", &v);
            put_string(&v, if (id != 0) node.*.description else "");
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "HelpText") == 0) {
            variantOpen(it, "s", &v);
            put_string(&v, if (id != 0) node.*.description else "");
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "Locale") == 0) {
            variantOpen(it, "s", &v);
            put_string(&v, a11y.rvn_a11y_locale());
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "AccessibleId") == 0) {
            var text: [32]u8 = undefined;
            _ = libc.snprintf(&text, text.len, "%llx", @as(c_ulonglong, id));
            variantOpen(it, "s", &v);
            put_string(&v, &text);
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "ChildCount") == 0) {
            variantOpen(it, "i", &v);
            put_i32(&v, child_count(id));
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "Parent") == 0) {
            if (id == 0) {
                variantOpen(it, "(so)", &v);
                put_parent_ref(&v);
                variantClose(it, &v);
                return raven.R_TRUE;
            }
            variantOpen(it, "(so)", &v);
            put_ref(&v, a11y.rvn_a11y_parent(id));
            variantClose(it, &v);
            return raven.R_TRUE;
        }
    } else if (libc.strcmp(iface, "org.a11y.atspi.Application") == 0) {
        if (libc.strcmp(name, "ToolkitName") == 0) {
            variantOpen(it, "s", &v);
            put_string(&v, "Raven");
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "Version") == 0) {
            variantOpen(it, "s", &v);
            put_string(&v, raven.Rget_version());
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "AtspiVersion") == 0) {
            variantOpen(it, "s", &v);
            put_string(&v, "2.1");
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "Id") == 0) {
            variantOpen(it, "i", &v);
            put_i32(&v, g_atspi.app_id);
            variantClose(it, &v);
            return raven.R_TRUE;
        }
    } else if (libc.strcmp(iface, "org.a11y.atspi.Action") == 0) {
        if (libc.strcmp(name, "NActions") == 0) {
            variantOpen(it, "i", &v);
            put_i32(&v, if (has_action(node) != 0) 1 else 0);
            variantClose(it, &v);
            return raven.R_TRUE;
        }
    } else if (libc.strcmp(iface, "org.a11y.atspi.Value") == 0) {
        if (libc.strcmp(name, "CurrentValue") == 0) {
            variantOpen(it, "d", &v);
            put_double(&v, node.*.number);
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "MinimumValue") == 0) {
            variantOpen(it, "d", &v);
            put_double(&v, node.*.minimum);
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "MaximumValue") == 0) {
            variantOpen(it, "d", &v);
            put_double(&v, node.*.maximum);
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "MinimumIncrement") == 0) {
            variantOpen(it, "d", &v);
            put_double(&v, node.*.step);
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "Text") == 0) {
            variantOpen(it, "s", &v);
            put_string(&v, node.*.value);
            variantClose(it, &v);
            return raven.R_TRUE;
        }
    } else if (libc.strcmp(iface, "org.a11y.atspi.Text") == 0) {
        if (libc.strcmp(name, "CharacterCount") == 0) {
            variantOpen(it, "i", &v);
            put_i32(&v, utf8_length(node_text(node)));
            variantClose(it, &v);
            return raven.R_TRUE;
        }
        if (libc.strcmp(name, "CaretOffset") == 0) {
            variantOpen(it, "i", &v);
            put_i32(&v, utf8_length(node_text(node)));
            variantClose(it, &v);
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

fn pushInterface(out: [*c][*c]const u8, count: [*c]c_int, name: [*c]const u8) void {
    out[@as(usize, @intCast(count.*))] = name;
    count.* += 1;
}

fn interfaces_of(id: rvn_a11y_id_t, node: [*c]const rvn_a11y_node_t, out: [*c][*c]const u8, count: [*c]c_int) void {
    count.* = 0;
    pushInterface(out, count, "org.a11y.atspi.Accessible");
    if (id == 0) {
        pushInterface(out, count, "org.a11y.atspi.Application");
        return;
    }
    pushInterface(out, count, "org.a11y.atspi.Component");
    if (has_action(node) != 0) pushInterface(out, count, "org.a11y.atspi.Action");
    if ((node.*.states & a11y.RVN_A11Y_HAS_RANGE) != 0) pushInterface(out, count, "org.a11y.atspi.Value");
    if (has_text(node) != 0) pushInterface(out, count, "org.a11y.atspi.Text");
    if ((node.*.states & a11y.RVN_A11Y_EDITABLE) != 0) pushInterface(out, count, "org.a11y.atspi.EditableText");
}

// ---------------------------------------------------------------------------
//  Methods
// ---------------------------------------------------------------------------

fn next_i32(it: [*c]DBusMessageIter, value: [*c]i32) c_int {
    if (g_atspi.iter_get_arg_type.?(it) != T_INT32 and g_atspi.iter_get_arg_type.?(it) != T_UINT32) return raven.R_FALSE;
    g_atspi.iter_get_basic.?(it, (value));
    _ = g_atspi.iter_next.?(it);
    return raven.R_TRUE;
}

fn next_string(it: [*c]DBusMessageIter, value: [*c][*c]const u8) c_int {
    if (g_atspi.iter_get_arg_type.?(it) != T_STRING) return raven.R_FALSE;
    g_atspi.iter_get_basic.?(it, @ptrCast(value));
    _ = g_atspi.iter_next.?(it);
    return raven.R_TRUE;
}

fn reply_and_send(reply: ?*DBusMessage) void {
    if (reply == null) return;
    _ = g_atspi.connection_send.?(g_atspi.bus, reply, null);
    g_atspi.message_unref.?(reply);
}

// Screen point -> the deepest node there.
fn node_at_point(id: rvn_a11y_id_t, x: c_int, y: c_int, coords: u32) rvn_a11y_id_t {
    const window = a11y.rvn_a11y_window(id);
    var wx: c_int = 0;
    var wy: c_int = 0;
    var scale: f32 = 1.0;
    var lx: f32 = undefined;
    var ly: f32 = undefined;
    if (window == 0) return 0;
    a11y.rvn_a11y_window_origin(id, &wx, &wy, &scale);
    if (coords == 0) {
        lx = @as(f32, @floatFromInt(x - wx)) / scale;
        ly = @as(f32, @floatFromInt(y - wy)) / scale;
    } else {
        lx = @as(f32, @floatFromInt(x)) / scale;
        ly = @as(f32, @floatFromInt(y)) / scale;
    }
    return a11y.rvn_a11y_hit(window, lx, ly);
}

fn get_extents(id: rvn_a11y_id_t, coords: u32, x: [*c]c_int, y: [*c]c_int, w: [*c]c_int, h: [*c]c_int) void {
    a11y.rvn_a11y_screen_rect(id, x, y, w, h);
    if (coords != 0) {
        // relative to the window
        var wx: c_int = undefined;
        var wy: c_int = undefined;
        var scale: f32 = undefined;
        a11y.rvn_a11y_window_origin(id, &wx, &wy, &scale);
        x.* -= wx;
        y.* -= wy;
    }
}

const Outcome = enum { send, unknown };

fn handle(connection: ?*DBusConnection, message: ?*DBusMessage, user: ?*anyopaque) callconv(.c) c_int {
    const iface = g_atspi.message_get_interface.?(message);
    const member = g_atspi.message_get_member.?(message);
    const path = g_atspi.message_get_path.?(message);
    var id: rvn_a11y_id_t = 0;
    var node: rvn_a11y_node_t = undefined;
    var in_: DBusMessageIter = undefined;
    var out: DBusMessageIter = undefined;
    var sub: DBusMessageIter = undefined;
    var entry: DBusMessageIter = undefined;
    _ = connection;
    _ = user;

    if (g_atspi.message_get_type.?(message) != DBUS_MESSAGE_TYPE_METHOD_CALL or member == null) return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
    if (parse_path(path, &id) == 0) {
        reply_and_send(g_atspi.message_new_error.?(message, "org.freedesktop.DBus.Error.UnknownObject", "This object is gone"));
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    @memset(std.mem.asBytes(&node), 0);
    node.name = "";
    node.value = "";
    node.description = "";
    if (id != 0 and a11y.rvn_a11y_describe(id, &node) == 0) {
        reply_and_send(g_atspi.message_new_error.?(message, "org.freedesktop.DBus.Error.UnknownObject", "This object is gone"));
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    if (id == 0) node.role = raven.R_ROLE_NONE;
    _ = g_atspi.iter_init.?(message, &in_);
    const reply = g_atspi.message_new_method_return.?(message);
    g_atspi.iter_init_append.?(reply, &out);

    const outcome: Outcome = blk: {
        // ---- properties ----
        if (iface != null and libc.strcmp(iface, "org.freedesktop.DBus.Properties") == 0) {
            var piface: [*c]const u8 = "";
            var pname: [*c]const u8 = "";
            if (libc.strcmp(member, "Get") == 0 and next_string(&in_, &piface) != 0 and next_string(&in_, &pname) != 0) {
                if (put_property(&out, id, &node, piface, pname) != 0) break :blk .send;
                g_atspi.message_unref.?(reply);
                reply_and_send(g_atspi.message_new_error.?(message, "org.freedesktop.DBus.Error.UnknownProperty", pname));
                return DBUS_HANDLER_RESULT_HANDLED;
            }
            if (libc.strcmp(member, "GetAll") == 0 and next_string(&in_, &piface) != 0) {
                const names = [_][*c]const u8{ "Name", "Description", "HelpText", "Locale", "AccessibleId", "ChildCount", "Parent", "ToolkitName", "Version", "AtspiVersion", "Id", "NActions", "CurrentValue", "MinimumValue", "MaximumValue", "MinimumIncrement", "Text", "CharacterCount", "CaretOffset" };
                var i: usize = 0;
                _ = g_atspi.iter_open_container.?(&out, T_ARRAY, "{sv}", &sub);
                while (i < names.len) : (i += 1) {
                    var probe: DBusMessageIter = undefined;
                    // (an entry is only opened for the properties of this interface)
                    const scratch = g_atspi.message_new_method_return.?(message);
                    g_atspi.iter_init_append.?(scratch, &probe);
                    if (put_property(&probe, id, &node, piface, names[i]) != 0) {
                        _ = g_atspi.iter_open_container.?(&sub, T_DICT_ENTRY, null, &entry);
                        put_string(&entry, names[i]);
                        _ = put_property(&entry, id, &node, piface, names[i]);
                        _ = g_atspi.iter_close_container.?(&sub, &entry);
                    }
                    g_atspi.message_unref.?(scratch);
                }
                _ = g_atspi.iter_close_container.?(&out, &sub);
                break :blk .send;
            }
            if (libc.strcmp(member, "Set") == 0 and next_string(&in_, &piface) != 0 and next_string(&in_, &pname) != 0) {
                var variant: DBusMessageIter = undefined;
                if (g_atspi.iter_get_arg_type.?(&in_) == T_VARIANT) {
                    g_atspi.iter_recurse.?(&in_, &variant);
                    if (libc.strcmp(pname, "Id") == 0 and g_atspi.iter_get_arg_type.?(&variant) == T_INT32) {
                        g_atspi.iter_get_basic.?(&variant, &g_atspi.app_id);
                    } else if (libc.strcmp(pname, "CurrentValue") == 0 and g_atspi.iter_get_arg_type.?(&variant) == T_DOUBLE) {
                        var value: f64 = undefined;
                        g_atspi.iter_get_basic.?(&variant, &value);
                        _ = a11y.rvn_a11y_set_number(id, value);
                    }
                }
                break :blk .send;
            }
            break :blk .unknown;
        }

        // ---- Accessible ----
        if (iface == null or libc.strcmp(iface, "org.a11y.atspi.Accessible") == 0) {
            if (libc.strcmp(member, "GetChildAtIndex") == 0) {
                var index: i32 = 0;
                _ = next_i32(&in_, &index);
                const child = child_at(id, index);
                if (child != 0) put_ref(&out, child) else put_null_ref(&out);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetChildren") == 0) {
                var i: c_int = 0;
                const n = child_count(id);
                _ = g_atspi.iter_open_container.?(&out, T_ARRAY, "(so)", &sub);
                while (i < n) : (i += 1) put_ref(&sub, child_at(id, i));
                _ = g_atspi.iter_close_container.?(&out, &sub);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetIndexInParent") == 0) {
                put_i32(&out, index_in_parent(id));
                break :blk .send;
            }
            if (libc.strcmp(member, "GetRelationSet") == 0) {
                _ = g_atspi.iter_open_container.?(&out, T_ARRAY, "(ua(so))", &sub);
                _ = g_atspi.iter_close_container.?(&out, &sub);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetRole") == 0) {
                put_u32(&out, if (id != 0) atspi_role(node.role, node.states) else 75);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetRoleName") == 0 or libc.strcmp(member, "GetLocalizedRoleName") == 0) {
                put_string(&out, if (id != 0) a11y.rvn_a11y_role_name(node.role) else "application");
                break :blk .send;
            }
            if (libc.strcmp(member, "GetState") == 0) {
                put_states(&out, id, &node);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetAttributes") == 0) {
                _ = g_atspi.iter_open_container.?(&out, T_ARRAY, "{ss}", &sub);
                _ = g_atspi.iter_open_container.?(&sub, T_DICT_ENTRY, null, &entry);
                put_string(&entry, "toolkit");
                put_string(&entry, "Raven");
                _ = g_atspi.iter_close_container.?(&sub, &entry);
                _ = g_atspi.iter_close_container.?(&out, &sub);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetApplication") == 0) {
                put_ref(&out, 0);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetInterfaces") == 0) {
                var names: [8][*c]const u8 = undefined;
                var i: c_int = 0;
                var n: c_int = 0;
                interfaces_of(id, &node, &names, &n);
                _ = g_atspi.iter_open_container.?(&out, T_ARRAY, "s", &sub);
                while (i < n) : (i += 1) put_string(&sub, names[@as(usize, @intCast(i))]);
                _ = g_atspi.iter_close_container.?(&out, &sub);
                break :blk .send;
            }
            if (iface != null) break :blk .unknown;
        }

        // ---- Application ----
        if (iface != null and libc.strcmp(iface, "org.a11y.atspi.Application") == 0) {
            if (libc.strcmp(member, "GetLocale") == 0) {
                put_string(&out, a11y.rvn_a11y_locale());
                break :blk .send;
            }
            break :blk .unknown;
        }

        // ---- Component ----
        if (iface != null and libc.strcmp(iface, "org.a11y.atspi.Component") == 0 and id != 0) {
            var x: i32 = 0;
            var y: i32 = 0;
            var coords: u32 = 0;
            var ex: c_int = undefined;
            var ey: c_int = undefined;
            var ew: c_int = undefined;
            var eh: c_int = undefined;
            if (libc.strcmp(member, "GetExtents") == 0) {
                _ = next_i32(&in_, @ptrCast(&coords));
                get_extents(id, coords, &ex, &ey, &ew, &eh);
                _ = g_atspi.iter_open_container.?(&out, T_STRUCT, null, &sub);
                put_i32(&sub, ex);
                put_i32(&sub, ey);
                put_i32(&sub, ew);
                put_i32(&sub, eh);
                _ = g_atspi.iter_close_container.?(&out, &sub);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetPosition") == 0) {
                _ = next_i32(&in_, @ptrCast(&coords));
                get_extents(id, coords, &ex, &ey, &ew, &eh);
                put_i32(&out, ex);
                put_i32(&out, ey);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetSize") == 0) {
                get_extents(id, 0, &ex, &ey, &ew, &eh);
                put_i32(&out, ew);
                put_i32(&out, eh);
                break :blk .send;
            }
            if (libc.strcmp(member, "Contains") == 0) {
                _ = next_i32(&in_, &x);
                _ = next_i32(&in_, &y);
                _ = next_i32(&in_, @ptrCast(&coords));
                get_extents(id, coords, &ex, &ey, &ew, &eh);
                put_bool(&out, @intFromBool(x >= ex and y >= ey and x < ex + ew and y < ey + eh));
                break :blk .send;
            }
            if (libc.strcmp(member, "GetAccessibleAtPoint") == 0) {
                _ = next_i32(&in_, &x);
                _ = next_i32(&in_, &y);
                _ = next_i32(&in_, @ptrCast(&coords));
                const hit = node_at_point(id, x, y, coords);
                if (hit != 0) put_ref(&out, hit) else put_null_ref(&out);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetLayer") == 0) {
                put_u32(&out, if (node.role == raven.R_ROLE_WINDOW) 7 else 3);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetMDIZOrder") == 0) {
                var z: i16 = 0;
                _ = g_atspi.iter_append_basic.?(&out, T_INT16, &z);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetAlpha") == 0) {
                put_double(&out, 1.0);
                break :blk .send;
            }
            if (libc.strcmp(member, "GrabFocus") == 0) {
                put_bool(&out, a11y.rvn_a11y_act(id, a11y.RVN_A11Y_FOCUS));
                break :blk .send;
            }
            if (libc.strcmp(member, "ScrollTo") == 0 or libc.strcmp(member, "ScrollToPoint") == 0) {
                put_bool(&out, 0);
                break :blk .send;
            }
            break :blk .unknown;
        }

        // ---- Action ----
        if (iface != null and libc.strcmp(iface, "org.a11y.atspi.Action") == 0 and id != 0) {
            var index: i32 = 0;
            if (libc.strcmp(member, "GetActions") == 0) {
                _ = g_atspi.iter_open_container.?(&out, T_ARRAY, "(sss)", &sub);
                if (has_action(&node) != 0) {
                    var s: DBusMessageIter = undefined;
                    _ = g_atspi.iter_open_container.?(&sub, T_STRUCT, null, &s);
                    put_string(&s, action_name(&node));
                    put_string(&s, "");
                    put_string(&s, "");
                    _ = g_atspi.iter_close_container.?(&sub, &s);
                }
                _ = g_atspi.iter_close_container.?(&out, &sub);
                break :blk .send;
            }
            _ = next_i32(&in_, &index);
            if (libc.strcmp(member, "GetName") == 0 or libc.strcmp(member, "GetLocalizedName") == 0) {
                put_string(&out, if (index == 0) action_name(&node) else "");
                break :blk .send;
            }
            if (libc.strcmp(member, "GetDescription") == 0 or libc.strcmp(member, "GetKeyBinding") == 0) {
                put_string(&out, "");
                break :blk .send;
            }
            if (libc.strcmp(member, "DoAction") == 0) {
                const action: a11y.rvn_a11y_action_t = if (node.role == raven.R_ROLE_CHECKBOX)
                    a11y.RVN_A11Y_TOGGLE
                else if ((node.states & a11y.RVN_A11Y_EXPANDABLE) != 0 and (node.states & a11y.RVN_A11Y_INVOKABLE) == 0)
                    (if ((node.states & a11y.RVN_A11Y_EXPANDED) != 0) a11y.RVN_A11Y_COLLAPSE else a11y.RVN_A11Y_EXPAND)
                else
                    a11y.RVN_A11Y_PRESS;
                put_bool(&out, @intFromBool(index == 0 and a11y.rvn_a11y_act(id, action) != 0));
                break :blk .send;
            }
            break :blk .unknown;
        }

        // ---- Value ----
        if (iface != null and libc.strcmp(iface, "org.a11y.atspi.Value") == 0 and id != 0) {
            if (libc.strcmp(member, "SetCurrentValue") == 0 and g_atspi.iter_get_arg_type.?(&in_) == T_DOUBLE) {
                var value: f64 = undefined;
                g_atspi.iter_get_basic.?(&in_, &value);
                _ = a11y.rvn_a11y_set_number(id, value);
                break :blk .send;
            }
            break :blk .unknown;
        }

        // ---- Text ----
        if (iface != null and libc.strcmp(iface, "org.a11y.atspi.Text") == 0 and id != 0) {
            const text = node_text(&node);
            const length = utf8_length(text);
            var start: i32 = 0;
            var end: i32 = -1;
            if (libc.strcmp(member, "GetText") == 0) {
                var a: c_int = undefined;
                var b: c_int = undefined;
                var part: [*c]u8 = undefined;
                _ = next_i32(&in_, &start);
                _ = next_i32(&in_, &end);
                if (end < 0 or end > length) end = length;
                if (start < 0) start = 0;
                if (start > end) start = end;
                a = utf8_offset(text, start);
                b = utf8_offset(text, end);
                part = base.rvn_strndup(text + @as(usize, @intCast(a)), @as(usize, @intCast(b - a)));
                put_string(&out, part);
                base.rvn_free(part);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetTextAtOffset") == 0 or libc.strcmp(member, "GetStringAtOffset") == 0) {
                // the whole text, whatever the granularity: a line of a control
                put_string(&out, text);
                put_i32(&out, 0);
                put_i32(&out, length);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetCharacterAtOffset") == 0) {
                var a: c_int = undefined;
                var c: u32 = 0;
                var cursor: [*c]const u8 = undefined;
                _ = next_i32(&in_, &start);
                a = utf8_offset(text, start);
                cursor = text + @as(usize, @intCast(a));
                if (cursor[0] != 0) c = base.rvn_utf8_decode(&cursor, text + libc.strlen(text));
                put_i32(&out, @bitCast(c));
                break :blk .send;
            }
            if (libc.strcmp(member, "GetNSelections") == 0) {
                put_i32(&out, 0);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetCaretOffset") == 0) {
                put_i32(&out, length);
                break :blk .send;
            }
            if (libc.strcmp(member, "GetAttributes") == 0 or libc.strcmp(member, "GetDefaultAttributes") == 0) {
                _ = g_atspi.iter_open_container.?(&out, T_ARRAY, "{ss}", &sub);
                _ = g_atspi.iter_close_container.?(&out, &sub);
                if (libc.strcmp(member, "GetAttributes") == 0) {
                    put_i32(&out, 0);
                    put_i32(&out, length);
                }
                break :blk .send;
            }
            break :blk .unknown;
        }

        // ---- EditableText ----
        if (iface != null and libc.strcmp(iface, "org.a11y.atspi.EditableText") == 0 and id != 0) {
            var text: [*c]const u8 = "";
            if (libc.strcmp(member, "SetTextContents") == 0 and next_string(&in_, &text) != 0) {
                put_bool(&out, a11y.rvn_a11y_set_value(id, text));
                break :blk .send;
            }
            break :blk .unknown;
        }

        break :blk .unknown;
    };

    switch (outcome) {
        .send => {
            reply_and_send(reply);
            return DBUS_HANDLER_RESULT_HANDLED;
        },
        .unknown => {
            g_atspi.message_unref.?(reply);
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
        },
    }
}

// ---------------------------------------------------------------------------
//  Connection
// ---------------------------------------------------------------------------

// A property of org.a11y.Status on the session bus (IsEnabled, ScreenReaderEnabled).
fn session_flag(session: ?*DBusConnection, name: [*c]const u8) c_int {
    const call = g_atspi.message_new_method_call.?("org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "Get");
    var it: DBusMessageIter = undefined;
    var variant: DBusMessageIter = undefined;
    var error_: DBusError = undefined;
    const iface: [*c]const u8 = "org.a11y.Status";
    var value: dbus_bool_t = 0;
    if (call == null) return raven.R_FALSE;
    g_atspi.iter_init_append.?(call, &it);
    put_string(&it, iface);
    put_string(&it, name);
    g_atspi.error_init.?(&error_);
    const reply = g_atspi.connection_send_with_reply_and_block.?(session, call, 500, &error_);
    g_atspi.message_unref.?(call);
    if (reply == null) {
        g_atspi.error_free.?(&error_);
        return raven.R_FALSE;
    }
    if (g_atspi.iter_init.?(reply, &it) != 0 and g_atspi.iter_get_arg_type.?(&it) == T_VARIANT) {
        g_atspi.iter_recurse.?(&it, &variant);
        if (g_atspi.iter_get_arg_type.?(&variant) == T_BOOLEAN) g_atspi.iter_get_basic.?(&variant, &value);
    }
    g_atspi.message_unref.?(reply);
    return @intFromBool(value != 0);
}

// The address of the accessibility bus: AT_SPI_BUS_ADDRESS, else org.a11y.Bus GetAddress.
fn bus_address(session: ?*DBusConnection) [*c]u8 {
    const env = libc.getenv("AT_SPI_BUS_ADDRESS");
    var it: DBusMessageIter = undefined;
    var error_: DBusError = undefined;
    var address: [*c]u8 = null;
    if (env != null and env[0] != 0) return base.rvn_strdup(env);
    if (session == null) return null;
    const call = g_atspi.message_new_method_call.?("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress");
    if (call == null) return null;
    g_atspi.error_init.?(&error_);
    const reply = g_atspi.connection_send_with_reply_and_block.?(session, call, 500, &error_);
    g_atspi.message_unref.?(call);
    if (reply == null) {
        g_atspi.error_free.?(&error_);
        return null;
    }
    if (g_atspi.iter_init.?(reply, &it) != 0 and g_atspi.iter_get_arg_type.?(&it) == T_STRING) {
        var text: [*c]const u8 = null;
        g_atspi.iter_get_basic.?(&it, @ptrCast(&text));
        if (text != null) address = base.rvn_strdup(text);
    }
    g_atspi.message_unref.?(reply);
    return address;
}

// Tells the registry that the application is there; it answers with the desktop, our parent.
fn embed() void {
    const call = g_atspi.message_new_method_call.?("org.a11y.atspi.Registry", ROOT_PATH, "org.a11y.atspi.Socket", "Embed");
    var it: DBusMessageIter = undefined;
    var s: DBusMessageIter = undefined;
    var error_: DBusError = undefined;
    if (call == null) return;
    g_atspi.iter_init_append.?(call, &it);
    put_ref(&it, 0);
    g_atspi.error_init.?(&error_);
    const reply = g_atspi.connection_send_with_reply_and_block.?(g_atspi.bus, call, 1000, &error_);
    g_atspi.message_unref.?(call);
    if (reply == null) {
        // no registry (no desktop): the objects are served all the same
        g_atspi.error_free.?(&error_);
        return;
    }
    if (g_atspi.iter_init.?(reply, &it) != 0 and g_atspi.iter_get_arg_type.?(&it) == T_STRUCT) {
        var name: [*c]const u8 = null;
        var path: [*c]const u8 = null;
        g_atspi.iter_recurse.?(&it, &s);
        if (g_atspi.iter_get_arg_type.?(&s) == T_STRING) g_atspi.iter_get_basic.?(&s, @ptrCast(&name));
        _ = g_atspi.iter_next.?(&s);
        if (g_atspi.iter_get_arg_type.?(&s) == T_OBJECT_PATH) g_atspi.iter_get_basic.?(&s, @ptrCast(&path));
        if (name != null) _ = libc.snprintf(&g_atspi.parent_name, g_atspi.parent_name.len, "%s", name);
        if (path != null) _ = libc.snprintf(&g_atspi.parent_path, g_atspi.parent_path.len, "%s", path);
    }
    g_atspi.message_unref.?(reply);
}

// `static const DBusObjectPathVTable vtable` of rvn_atspi_init: static, because libdbus keeps the pointer.
const vtable: DBusObjectPathVTable = .{
    .unregister_function = null,
    .message_function = handle,
    .pad1 = null,
    .pad2 = null,
    .pad3 = null,
    .pad4 = null,
};

fn rvn_atspi_init() callconv(.c) c_int {
    var session: ?*DBusConnection = null;
    var error_: DBusError = undefined;
    if (g_atspi.bus != null) return raven.R_TRUE;
    if (g_atspi.failed != 0 or rvn_atspi_load() == 0) {
        g_atspi.failed = raven.R_TRUE;
        return raven.R_FALSE;
    }
    g_atspi.error_init.?(&error_);
    if (libc.getenv("AT_SPI_BUS_ADDRESS") == null) {
        session = g_atspi.bus_get_private.?(DBUS_BUS_SESSION, &error_);
        if (session == null) {
            g_atspi.error_free.?(&error_);
            g_atspi.failed = raven.R_TRUE;
            return raven.R_FALSE;
        }
        g_atspi.connection_set_exit_on_disconnect.?(session, 0);
        // nobody listens: nothing to do (this is asked again by Raccessibility_is_screen_reader_active)
        if (session_flag(session, "IsEnabled") == 0 and session_flag(session, "ScreenReaderEnabled") == 0 and libc.getenv("RAVEN_ACCESSIBILITY") == null) {
            g_atspi.connection_close.?(session);
            g_atspi.connection_unref.?(session);
            return raven.R_FALSE;
        }
    }
    const address = bus_address(session);
    if (session != null) {
        g_atspi.connection_close.?(session);
        g_atspi.connection_unref.?(session);
    }
    if (address == null) {
        g_atspi.failed = raven.R_TRUE;
        return raven.R_FALSE;
    }
    g_atspi.bus = g_atspi.connection_open_private.?(address, &error_);
    base.rvn_free(address);
    if (g_atspi.bus == null or g_atspi.bus_register.?(g_atspi.bus, &error_) == 0) {
        if (g_atspi.error_is_set.?(&error_) != 0) g_atspi.error_free.?(&error_);
        if (g_atspi.bus != null) {
            g_atspi.connection_close.?(g_atspi.bus);
            g_atspi.connection_unref.?(g_atspi.bus);
        }
        g_atspi.bus = null;
        g_atspi.failed = raven.R_TRUE;
        return raven.R_FALSE;
    }
    g_atspi.connection_set_exit_on_disconnect.?(g_atspi.bus, 0);
    _ = libc.snprintf(&g_atspi.unique, g_atspi.unique.len, "%s", g_atspi.bus_get_unique_name.?(g_atspi.bus));
    _ = g_atspi.connection_register_fallback.?(g_atspi.bus, "/org/a11y/atspi/accessible", &vtable, null);
    embed();
    g_atspi.enabled = raven.R_TRUE;
    return raven.R_TRUE;
}

fn rvn_atspi_shutdown() callconv(.c) void {
    if (g_atspi.bus != null) {
        g_atspi.connection_close.?(g_atspi.bus);
        g_atspi.connection_unref.?(g_atspi.bus);
    }
    g_atspi.bus = null;
    g_atspi.enabled = raven.R_FALSE;
    // (libdbus stays loaded: unloading it while it holds threads is not safe)
}

fn rvn_atspi_fd() callconv(.c) c_int {
    var fd: c_int = -1;
    if (g_atspi.bus == null or g_atspi.connection_get_unix_fd.?(g_atspi.bus, &fd) == 0) return -1;
    return fd;
}

fn rvn_atspi_dispatch() callconv(.c) void {
    var guard: c_int = 0;
    if (g_atspi.bus == null) return;
    _ = g_atspi.connection_read_write.?(g_atspi.bus, 0);
    // while (dispatch == DATA_REMAINS && guard++ < 1000) {}
    while (g_atspi.connection_dispatch.?(g_atspi.bus) == DBUS_DISPATCH_DATA_REMAINS) {
        const old = guard;
        guard += 1;
        if (old >= 1000) break;
    }
    g_atspi.connection_flush.?(g_atspi.bus);
}

// An event: path of the node, interface org.a11y.atspi.Event.<kind>, signature siiva{sv}.
fn signal(id: rvn_a11y_id_t, kind: [*c]const u8, member: [*c]const u8, detail: [*c]const u8, detail1: c_int, detail2: c_int, any_type: u8, any_value: *const anyopaque) void {
    var path: [96]u8 = undefined;
    var iface: [96]u8 = undefined;
    var signature: [1:0]u8 = .{any_type};
    var it: DBusMessageIter = undefined;
    var variant: DBusMessageIter = undefined;
    var dict: DBusMessageIter = undefined;
    node_path(id, &path, path.len);
    _ = libc.snprintf(&iface, iface.len, "org.a11y.atspi.Event.%s", kind);
    const message = g_atspi.message_new_signal.?(&path, &iface, member);
    if (message == null) return;
    g_atspi.iter_init_append.?(message, &it);
    put_string(&it, detail);
    put_i32(&it, detail1);
    put_i32(&it, detail2);
    if (any_type == T_STRUCT) {
        const target: *const rvn_a11y_id_t = @ptrCast(@alignCast(any_value));
        _ = g_atspi.iter_open_container.?(&it, T_VARIANT, "(so)", &variant);
        put_ref(&variant, target.*);
    } else {
        _ = g_atspi.iter_open_container.?(&it, T_VARIANT, &signature, &variant);
        _ = g_atspi.iter_append_basic.?(&variant, any_type, any_value);
    }
    _ = g_atspi.iter_close_container.?(&it, &variant);
    _ = g_atspi.iter_open_container.?(&it, T_ARRAY, "{sv}", &dict);
    _ = g_atspi.iter_close_container.?(&it, &dict);
    _ = g_atspi.connection_send.?(g_atspi.bus, message, null);
    g_atspi.message_unref.?(message);
}

fn rvn_atspi_event(window: ?*platform.rvn_pwindow_t, event: c_int, id: u64) callconv(.c) void {
    var zero: i32 = 0;
    _ = window;
    if (g_atspi.bus == null) return;
    switch (event) {
        a11y.RVN_A11Y_EVENT_FOCUS => {
            signal(id, "Object", "StateChanged", "focused", 1, 0, T_INT32, &zero);
            signal(id, "Focus", "Focus", "", 0, 0, T_INT32, &zero);
        },
        a11y.RVN_A11Y_EVENT_VALUE => {
            var node: rvn_a11y_node_t = undefined;
            if (a11y.rvn_a11y_describe(id, &node) != 0) {
                if ((node.states & a11y.RVN_A11Y_HAS_RANGE) != 0) {
                    signal(id, "Object", "PropertyChange", "accessible-value", 0, 0, T_DOUBLE, &node.number);
                } else {
                    var name: [*c]const u8 = node.name;
                    signal(id, "Object", "PropertyChange", "accessible-name", 0, 0, T_STRING, @ptrCast(&name));
                    if ((node.states & a11y.RVN_A11Y_CHECKABLE) != 0) signal(id, "Object", "StateChanged", "checked", if ((node.states & a11y.RVN_A11Y_CHECKED) != 0) 1 else 0, 0, T_INT32, &zero);
                    if ((node.states & a11y.RVN_A11Y_EXPANDABLE) != 0) signal(id, "Object", "StateChanged", "expanded", if ((node.states & a11y.RVN_A11Y_EXPANDED) != 0) 1 else 0, 0, T_INT32, &zero);
                    if ((node.states & a11y.RVN_A11Y_EDITABLE) != 0) signal(id, "Object", "TextChanged", "insert", 0, 0, T_STRING, @ptrCast(&node.value));
                }
            }
        },
        a11y.RVN_A11Y_EVENT_STRUCTURE => signal(id, "Object", "ChildrenChanged", "add", 0, 0, T_STRUCT, &id),
        else => {},
    }
    g_atspi.connection_flush.?(g_atspi.bus);
}

fn rvn_atspi_announce(window: ?*platform.rvn_pwindow_t, text: [*c]const u8, assertive: c_int) callconv(.c) void {
    _ = window;
    if (g_atspi.bus == null or text == null) return;
    // Object:Announcement (Orca 45+): detail1 is the politeness, 1 polite, 2 assertive
    signal(0, "Object", "Announcement", "", if (assertive != 0) 2 else 1, 0, T_STRING, @ptrCast(&text));
    g_atspi.connection_flush.?(g_atspi.bus);
}

fn rvn_atspi_active() callconv(.c) c_int {
    if (g_atspi.bus == null) _ = rvn_atspi_init();
    return @intFromBool(g_atspi.bus != null);
}

fn rvn_atspi_settings(settings: [*c]raven.RAccessibilitySettings) callconv(.c) void {
    const theme = libc.getenv("GTK_THEME");
    const scale = libc.getenv("GDK_DPI_SCALE");
    if (theme != null and (libc.strstr(theme, "HighContrast") != null or libc.strstr(theme, "highcontrast") != null)) settings.*.high_contrast = raven.R_TRUE;
    if (scale != null and atof(scale) >= 0.5 and atof(scale) <= 4.0) settings.*.text_scale = @floatCast(atof(scale));
}

// The C file's exports. Made only where the C file is compiled (see `compiled`).
comptime {
    if (compiled) {
        @export(&rvn_atspi_init, .{ .name = "rvn_atspi_init" });
        @export(&rvn_atspi_shutdown, .{ .name = "rvn_atspi_shutdown" });
        @export(&rvn_atspi_fd, .{ .name = "rvn_atspi_fd" });
        @export(&rvn_atspi_dispatch, .{ .name = "rvn_atspi_dispatch" });
        @export(&rvn_atspi_event, .{ .name = "rvn_atspi_event" });
        @export(&rvn_atspi_announce, .{ .name = "rvn_atspi_announce" });
        @export(&rvn_atspi_active, .{ .name = "rvn_atspi_active" });
        @export(&rvn_atspi_settings, .{ .name = "rvn_atspi_settings" });
    }
}
