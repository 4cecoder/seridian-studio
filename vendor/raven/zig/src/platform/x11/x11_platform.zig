// Translated to Zig from vendor/raven/src/platform/x11/x11_platform.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/x11/x11_platform.c
// Xlib implementation of the platform interface (Linux, BSD; also works
// through XWayland). Only libX11 is needed.
//
//   - UTF-8 text input through an X input context,
//   - CLIPBOARD selection (UTF-8),
//   - scale factor from the Xft.dpi resource,
//   - child windows for native viewports,
//   - windows without decoration that the application moves and resizes
//     (custom header): through the window manager when it knows
//     _NET_WM_MOVERESIZE, by hand otherwise,
//   - files and text dropped from other applications (XDND, version 5),
//   - a self-pipe so that other threads can wake the event loop.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const libc = @import("../../sys/libc.zig");
const platform_h = @import("../platform_h.zig");
const atspi = @import("../atspi_h.zig");
const x11_internal = @import("x11_internal_h.zig");

const rvn_pevent_t = platform_h.rvn_pevent_t;
const rvn_pevent_handler_t = platform_h.rvn_pevent_handler_t;
const rvn_pregion_t = platform_h.rvn_pregion_t;
const rvn_pregion_handler_t = platform_h.rvn_pregion_handler_t;
const rvn_pwindow_state_t = platform_h.rvn_pwindow_state_t;

const RVN_X11_CURSOR_COUNT = 10;
const RVN_X11_CLIPBOARD_TIMEOUT_MS = 500;

/// (R_KEY_COUNT + 7) / 8 bytes: one bit per key.
const KEY_BYTES: usize = (@as(usize, @intCast(raven.R_KEY_COUNT)) + 7) / 8;

// Window flags, as the bit masks of desc->flags (uint32_t).
const WIN_NO_RESIZE: u32 = @intCast(raven.R_WINDOW_NO_RESIZE);
const WIN_BORDERLESS: u32 = @intCast(raven.R_WINDOW_BORDERLESS);
const WIN_MAXIMIZED: u32 = @intCast(raven.R_WINDOW_MAXIMIZED);
const WIN_CUSTOM_HEADER: u32 = @intCast(raven.R_WINDOW_CUSTOM_HEADER);
const WIN_TRANSPARENT: u32 = @intCast(raven.R_WINDOW_TRANSPARENT);

// ---------------------------------------------------------------------------
//  Xlib, declared by hand (no X11 headers are needed to compile this file).
//  Layouts are those of LP64 (Linux x86_64, BSD): long and pointers are 8 bytes.
//  The Xlib macros used by the C file are expanded to the functions or the
//  structure fields they read; see the comments at each use.
// ---------------------------------------------------------------------------

const Display = opaque {};
const Visual = opaque {};
const XICRec = opaque {};
const XIMRec = opaque {};
const XrmHashBucketRec = opaque {};
const XIC = ?*XICRec;
const XIM = ?*XIMRec;
const XrmDatabase = ?*XrmHashBucketRec;

const Window = c_ulong;
const Atom = c_ulong;
const Colormap = c_ulong;
const Cursor = c_ulong;
const Pixmap = c_ulong;
const Time = c_ulong;
const VisualID = c_ulong;
const KeyCode = u8;
const KeySym = x11_internal.KeySym;
const XContext = c_int;
const Status = c_int;
const Bool = c_int;

const False: Bool = 0;
const True: Bool = 1;
const None: c_ulong = 0;
const Success: c_int = 0;
const CurrentTime: Time = 0;
const NoSymbol: KeySym = 0;
const AnyPropertyType: Atom = 0;
const CopyFromParent: c_int = 0;
const InputOutput: c_uint = 1;
const InputOnly: c_uint = 2;
const TrueColor: c_int = 4;
const AllocNone: c_int = 0;
const NorthWestGravity: c_int = 1;
const PropModeReplace: c_int = 0;
const PMinSize: c_long = 1 << 4;
const PMaxSize: c_long = 1 << 5;
const XIMPreeditNothing: c_long = 0x0008;
const XIMStatusNothing: c_long = 0x0400;
const XNInputStyle = "inputStyle";
const XNClientWindow = "clientWindow";
const XNFocusWindow = "focusWindow";
const XLookupChars: Status = 2;
const XLookupBoth: Status = 4;
const XA_ATOM: Atom = 4;
const XA_CARDINAL: Atom = 6;
const XA_STRING: Atom = 31;

// events (X.h)
const KeyPress = 2;
const KeyRelease = 3;
const ButtonPress = 4;
const ButtonRelease = 5;
const MotionNotify = 6;
const EnterNotify = 7;
const LeaveNotify = 8;
const FocusIn = 9;
const FocusOut = 10;
const Expose = 12;
const ConfigureNotify = 22;
const PropertyNotify = 28;
const SelectionRequest = 30;
const SelectionNotify = 31;
const ClientMessage = 33;
const MappingNotify = 34;

// event masks (X.h)
const NoEventMask: c_long = 0;
const KeyPressMask: c_long = 1 << 0;
const KeyReleaseMask: c_long = 1 << 1;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const EnterWindowMask: c_long = 1 << 4;
const LeaveWindowMask: c_long = 1 << 5;
const PointerMotionMask: c_long = 1 << 6;
const ExposureMask: c_long = 1 << 15;
const StructureNotifyMask: c_long = 1 << 17;
const SubstructureNotifyMask: c_long = 1 << 19;
const SubstructureRedirectMask: c_long = 1 << 20;
const FocusChangeMask: c_long = 1 << 21;
const PropertyChangeMask: c_long = 1 << 22;

// window attribute masks (Xlib.h)
const CWBackPixmap: c_ulong = 1 << 0;
const CWBackPixel: c_ulong = 1 << 1;
const CWBorderPixel: c_ulong = 1 << 3;
const CWBitGravity: c_ulong = 1 << 4;
const CWEventMask: c_ulong = 1 << 11;
const CWColormap: c_ulong = 1 << 13;

// modifiers (X.h)
const ShiftMask: c_uint = 1 << 0;
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3;

// buttons (X.h)
const Button1 = 1;
const Button2 = 2;
const Button3 = 3;

const NotifyNormal = 0;
const QueuedAlready = 0;

// cursor font (cursorfont.h)
const XC_left_ptr = 68;
const XC_xterm = 152;
const XC_hand2 = 60;
const XC_crosshair = 34;
const XC_sb_h_double_arrow = 108;
const XC_sb_v_double_arrow = 116;
const XC_bottom_right_corner = 14;
const XC_bottom_left_corner = 12;
const XC_fleur = 52;
const XC_X_cursor = 0;

// POSIX / libc values (fcntl.h, poll.h, errno.h, locale.h), taken from std.c per target: the values differ between
// Linux, the BSDs and macOS (O_NONBLOCK is 0x800 on Linux and 4 on FreeBSD; LC_CTYPE is 0 on Linux and 2 on FreeBSD).
const F_SETFD: c_int = std.c.F.SETFD;
const F_GETFL: c_int = std.c.F.GETFL;
const F_SETFL: c_int = std.c.F.SETFL;
const FD_CLOEXEC: c_int = std.c.FD_CLOEXEC;
const O_NONBLOCK: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
const POLLIN = std.c.POLL.IN;
const EINTR: c_int = @intFromEnum(std.c.E.INTR);
// std.c.LC does not analyse on every target (duplicate .serenity switch arm in this Zig dev build), so the category
// number is chosen here: 0 on glibc/musl, 2 on the BSDs, macOS and Serenity (the C header values).
const LC_CTYPE: c_int = switch (builtin.os.tag) {
    .linux => 0,
    else => 2,
};

/// Screen (Xlib.h; public structure, the ScreenOfDisplay macros read its fields).
const Screen = extern struct {
    ext_data: ?*anyopaque,
    display: ?*Display,
    root: Window,
    width: c_int,
    height: c_int,
    mwidth: c_int,
    mheight: c_int,
    ndepths: c_int,
    depths: ?*anyopaque,
    root_depth: c_int,
    root_visual: ?*Visual,
    default_gc: ?*anyopaque,
    cmap: Colormap,
    white_pixel: c_ulong,
    black_pixel: c_ulong,
    max_maps: c_int,
    min_maps: c_int,
    backing_store: c_int,
    save_unders: Bool,
    root_input_mask: c_long,
};

const XAnyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
};

const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: Bool,
};

const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: Bool,
};

const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: Bool,
};

const XCrossingEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: Time,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    mode: c_int,
    detail: c_int,
    same_screen: Bool,
    focus: Bool,
    state: c_uint,
};

const XExposeEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    count: c_int,
};

const XConfigureEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: Bool,
};

const XPropertyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    atom: Atom,
    time: Time,
    state: c_int,
};

const XSelectionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: Time,
};

const XSelectionRequestEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    owner: Window,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: Time,
};

const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union {
        b: [20]u8,
        s: [10]c_short,
        l: [5]c_long,
    },
};

const XMappingEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    request: c_int,
    first_keycode: c_int,
    count: c_int,
};

/// XEvent: a union of the event structures, 24 longs (192 bytes on LP64, 96 on ILP32).
const XEvent = extern union {
    type: c_int,
    xany: XAnyEvent,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xcrossing: XCrossingEvent,
    xexpose: XExposeEvent,
    xconfigure: XConfigureEvent,
    xproperty: XPropertyEvent,
    xselection: XSelectionEvent,
    xselectionrequest: XSelectionRequestEvent,
    xclient: XClientMessageEvent,
    xmapping: XMappingEvent,
    pad: [24]c_long,
};

comptime {
    if (@sizeOf(XEvent) != 24 * @sizeOf(c_long)) @compileError("XEvent must be 24 longs");
}

const XSetWindowAttributes = extern struct {
    background_pixmap: Pixmap,
    background_pixel: c_ulong,
    border_pixmap: Pixmap,
    border_pixel: c_ulong,
    bit_gravity: c_int,
    win_gravity: c_int,
    backing_store: c_int,
    backing_planes: c_ulong,
    backing_pixel: c_ulong,
    save_under: Bool,
    event_mask: c_long,
    do_not_propagate_mask: c_long,
    override_redirect: Bool,
    colormap: Colormap,
    cursor: Cursor,
};

const XWindowAttributes = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    depth: c_int,
    visual: ?*Visual,
    root: Window,
    class: c_int,
    bit_gravity: c_int,
    win_gravity: c_int,
    backing_store: c_int,
    backing_planes: c_ulong,
    backing_pixel: c_ulong,
    save_under: Bool,
    colormap: Colormap,
    map_installed: Bool,
    map_state: c_int,
    all_event_masks: c_long,
    your_event_mask: c_long,
    do_not_propagate_mask: c_long,
    override_redirect: Bool,
    screen: [*c]Screen,
};

const XVisualInfo = extern struct {
    visual: ?*Visual,
    visualid: VisualID,
    screen: c_int,
    depth: c_int,
    class: c_int,
    red_mask: c_ulong,
    green_mask: c_ulong,
    blue_mask: c_ulong,
    colormap_size: c_int,
    bits_per_rgb: c_int,
};

const XSizeHints = extern struct {
    flags: c_long,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    min_width: c_int,
    min_height: c_int,
    max_width: c_int,
    max_height: c_int,
    width_inc: c_int,
    height_inc: c_int,
    min_aspect: extern struct { x: c_int, y: c_int },
    max_aspect: extern struct { x: c_int, y: c_int },
    base_width: c_int,
    base_height: c_int,
    win_gravity: c_int,
};

const XClassHint = extern struct {
    res_name: [*c]u8,
    res_class: [*c]u8,
};

const XrmValue = extern struct {
    size: c_uint,
    addr: [*c]u8,
};

extern "c" fn XInitThreads() Status;
extern "c" fn XrmInitialize() void;
extern "c" fn XOpenDisplay(name: [*c]const u8) ?*Display;
extern "c" fn XCloseDisplay(dpy: ?*Display) c_int;
extern "c" fn XDefaultScreenOfDisplay(dpy: ?*Display) [*c]Screen;
extern "c" fn XScreenOfDisplay(dpy: ?*Display, screen: c_int) [*c]Screen;
extern "c" fn XScreenNumberOfScreen(screen: [*c]Screen) c_int;
extern "c" fn XRootWindow(dpy: ?*Display, screen: c_int) Window;
extern "c" fn XrmUniqueQuark() c_int;
extern "c" fn XSaveContext(dpy: ?*Display, rid: Window, context: XContext, data: [*c]const u8) c_int;
extern "c" fn XFindContext(dpy: ?*Display, rid: Window, context: XContext, data_return: [*c][*c]u8) c_int;
extern "c" fn XDeleteContext(dpy: ?*Display, rid: Window, context: XContext) c_int;
extern "c" fn XFree(data: ?*anyopaque) c_int;
extern "c" fn XFlush(dpy: ?*Display) c_int;
extern "c" fn XInternAtom(dpy: ?*Display, name: [*c]const u8, only_if_exists: Bool) Atom;
extern "c" fn XSupportsLocale() Bool;
extern "c" fn XSetLocaleModifiers(modifiers: [*c]const u8) [*c]u8;
extern "c" fn XOpenIM(dpy: ?*Display, rdb: ?*anyopaque, res_name: [*c]u8, res_class: [*c]u8) XIM;
extern "c" fn XCloseIM(im: XIM) Status;
extern "c" fn XkbSetDetectableAutoRepeat(dpy: ?*Display, detectable: Bool, supported_return: [*c]Bool) Bool;
extern "c" fn XkbKeycodeToKeysym(dpy: ?*Display, keycode: KeyCode, group: c_int, level: c_int) KeySym;
extern "c" fn XCreateFontCursor(dpy: ?*Display, shape: c_uint) Cursor;
extern "c" fn XFreeCursor(dpy: ?*Display, cursor: Cursor) c_int;
extern "c" fn XDefineCursor(dpy: ?*Display, w: Window, cursor: Cursor) c_int;
extern "c" fn XCreateWindow(dpy: ?*Display, parent: Window, x: c_int, y: c_int, width: c_uint, height: c_uint, border_width: c_uint, depth: c_int, class_: c_uint, visual: ?*Visual, valuemask: c_ulong, attributes: [*c]XSetWindowAttributes) Window;
extern "c" fn XDestroyWindow(dpy: ?*Display, w: Window) c_int;
extern "c" fn XMapWindow(dpy: ?*Display, w: Window) c_int;
extern "c" fn XMapRaised(dpy: ?*Display, w: Window) c_int;
extern "c" fn XUnmapWindow(dpy: ?*Display, w: Window) c_int;
extern "c" fn XWithdrawWindow(dpy: ?*Display, w: Window, screen: c_int) Status;
extern "c" fn XIconifyWindow(dpy: ?*Display, w: Window, screen: c_int) Status;
extern "c" fn XMoveWindow(dpy: ?*Display, w: Window, x: c_int, y: c_int) c_int;
extern "c" fn XResizeWindow(dpy: ?*Display, w: Window, width: c_uint, height: c_uint) c_int;
extern "c" fn XMoveResizeWindow(dpy: ?*Display, w: Window, x: c_int, y: c_int, width: c_uint, height: c_uint) c_int;
extern "c" fn XGetWindowAttributes(dpy: ?*Display, w: Window, attributes: [*c]XWindowAttributes) Status;
extern "c" fn XTranslateCoordinates(dpy: ?*Display, src_w: Window, dest_w: Window, src_x: c_int, src_y: c_int, dest_x_return: [*c]c_int, dest_y_return: [*c]c_int, child_return: [*c]Window) Bool;
extern "c" fn XQueryPointer(dpy: ?*Display, w: Window, root_return: [*c]Window, child_return: [*c]Window, root_x_return: [*c]c_int, root_y_return: [*c]c_int, win_x_return: [*c]c_int, win_y_return: [*c]c_int, mask_return: [*c]c_uint) Bool;
extern "c" fn XUngrabPointer(dpy: ?*Display, time: Time) c_int;
extern "c" fn XStoreName(dpy: ?*Display, w: Window, name: [*c]const u8) c_int;
extern "c" fn XChangeProperty(dpy: ?*Display, w: Window, property: Atom, type_: Atom, format: c_int, mode: c_int, data: [*c]const u8, nelements: c_int) c_int;
extern "c" fn XDeleteProperty(dpy: ?*Display, w: Window, property: Atom) c_int;
extern "c" fn XGetWindowProperty(dpy: ?*Display, w: Window, property: Atom, long_offset: c_long, long_length: c_long, delete: Bool, req_type: Atom, actual_type_return: [*c]Atom, actual_format_return: [*c]c_int, nitems_return: [*c]c_ulong, bytes_after_return: [*c]c_ulong, prop_return: [*c][*c]u8) c_int;
extern "c" fn XAllocSizeHints() [*c]XSizeHints;
extern "c" fn XSetWMNormalHints(dpy: ?*Display, w: Window, hints: [*c]XSizeHints) void;
extern "c" fn XSetWMProtocols(dpy: ?*Display, w: Window, protocols: [*c]Atom, count: c_int) Status;
extern "c" fn XAllocClassHint() [*c]XClassHint;
extern "c" fn XSetClassHint(dpy: ?*Display, w: Window, hints: [*c]XClassHint) c_int;
extern "c" fn XCreateColormap(dpy: ?*Display, w: Window, visual: ?*Visual, alloc: c_int) Colormap;
extern "c" fn XFreeColormap(dpy: ?*Display, colormap: Colormap) c_int;
extern "c" fn XMatchVisualInfo(dpy: ?*Display, screen: c_int, depth: c_int, class: c_int, info_return: [*c]XVisualInfo) Status;
extern "c" fn XVisualIDFromVisual(visual: ?*Visual) VisualID;
extern "c" fn XSendEvent(dpy: ?*Display, w: Window, propagate: Bool, event_mask: c_long, event_send: [*c]XEvent) Status;
extern "c" fn XGetSelectionOwner(dpy: ?*Display, selection: Atom) Window;
extern "c" fn XSetSelectionOwner(dpy: ?*Display, selection: Atom, owner: Window, time: Time) c_int;
extern "c" fn XConvertSelection(dpy: ?*Display, selection: Atom, target: Atom, property: Atom, requestor: Window, time: Time) c_int;
extern "c" fn XCheckTypedWindowEvent(dpy: ?*Display, w: Window, event_type: c_int, event_return: [*c]XEvent) Bool;
extern "c" fn XPending(dpy: ?*Display) c_int;
extern "c" fn XEventsQueued(dpy: ?*Display, mode: c_int) c_int;
extern "c" fn XNextEvent(dpy: ?*Display, event_return: [*c]XEvent) c_int;
extern "c" fn XPeekEvent(dpy: ?*Display, event_return: [*c]XEvent) c_int;
extern "c" fn XFilterEvent(event: [*c]XEvent, w: Window) Bool;
extern "c" fn XRefreshKeyboardMapping(event_map: [*c]XMappingEvent) c_int;
extern "c" fn XLookupString(event: [*c]XKeyEvent, buffer_return: [*c]u8, bytes_buffer: c_int, keysym_return: [*c]KeySym, status_in_out: ?*anyopaque) c_int;
extern "c" fn Xutf8LookupString(ic: XIC, event: [*c]XKeyEvent, buffer_return: [*c]u8, bytes_buffer: c_int, keysym_return: [*c]KeySym, status_return: [*c]Status) c_int;
extern "c" fn XCreateIC(im: XIM, ...) XIC;
extern "c" fn XDestroyIC(ic: XIC) void;
extern "c" fn XSetICFocus(ic: XIC) void;
extern "c" fn XUnsetICFocus(ic: XIC) void;
extern "c" fn XResourceManagerString(dpy: ?*Display) [*c]u8;
extern "c" fn XrmGetStringDatabase(data: [*c]const u8) XrmDatabase;
extern "c" fn XrmGetResource(db: XrmDatabase, str_name: [*c]const u8, str_class: [*c]const u8, str_type_return: [*c][*c]u8, value_return: [*c]XrmValue) Bool;
extern "c" fn XrmDestroyDatabase(db: XrmDatabase) void;
extern "c" fn atof(s: [*c]const u8) f64;
extern "c" fn setlocale(category: c_int, locale: [*c]const u8) [*c]u8;

/// XUniqueContext() is a macro of Xutil.h: ((XContext) XrmUniqueQuark()). There is no function of that name in libX11.
fn XUniqueContext() XContext {
    return XrmUniqueQuark();
}

/// ConnectionNumber(dpy) is a macro of Xlib.h that reads the `fd` field of the private Display structure
/// (Xlibint.h), which follows the two pointers `ext_data` and `free_funcs`.
fn connectionNumber(dpy: ?*Display) c_int {
    const fd_field: [*c]c_int = @ptrFromInt(@intFromPtr(dpy) + 2 * @sizeOf(?*anyopaque));
    return fd_field.*;
}

/// The platform state of the window structure (C: struct rvn_pwindow_t, the platform's own window).
const rvn_pwindow_t = extern struct {
    handle: Window,
    user: ?*anyopaque,
    input_context: XIC,
    width: c_int,
    height: c_int,
    is_child: c_int,
    flags: u32,
    min_width: c_int,
    min_height: c_int,
    /// without a window manager, maximizing is done here: what to restore
    maximized: c_int,
    restore_x: c_int,
    restore_y: c_int,
    restore_width: c_int,
    restore_height: c_int,
    /// a window that can be seen through: its 32-bit visual and the colormap made for it
    visual: ?*Visual,
    colormap: Colormap,
    transparent: c_int,
};

const X11State = struct {
    display: ?*Display,
    screen: c_int,
    root: Window,
    context: XContext,
    input_method: XIM,
    handler: rvn_pevent_handler_t,
    scale: f32,

    /// a window being moved or resized by hand (no window manager to do it)
    drag_window: [*c]rvn_pwindow_t,
    drag_region: rvn_pregion_t,
    drag_root_x: c_int,
    drag_root_y: c_int,
    drag_x: c_int,
    drag_y: c_int,
    drag_width: c_int,
    drag_height: c_int,

    /// a drag coming from another application (XDND)
    dnd_source: Window,
    dnd_format: Atom,
    dnd_accepted: c_int,
    dnd_x: c_int,
    dnd_y: c_int,
    wake_pipe: [2]c_int,
    cursors: [RVN_X11_CURSOR_COUNT]Cursor,
    /// never mapped: owns the clipboard selection and receives pasted data
    helper: Window,
    clipboard: [*c]u8,
    keys_down: [KEY_BYTES]u8,

    wm_protocols: Atom,
    wm_delete_window: Atom,
    net_wm_name: Atom,
    net_wm_state: Atom,
    net_wm_state_maximized_vert: Atom,
    net_wm_state_maximized_horz: Atom,
    motif_wm_hints: Atom,
    utf8_string: Atom,
    clipboard_atom: Atom,
    targets: Atom,
    incr: Atom,
    paste_property: Atom,
    net_supported: Atom,
    net_supporting_wm_check: Atom,
    net_wm_moveresize: Atom,
    xdnd_aware: Atom,
    xdnd_enter: Atom,
    xdnd_position: Atom,
    xdnd_status: Atom,
    xdnd_leave: Atom,
    xdnd_drop: Atom,
    xdnd_finished: Atom,
    xdnd_selection: Atom,
    xdnd_type_list: Atom,
    xdnd_action_copy: Atom,
    uri_list: Atom,
    text_plain_utf8: Atom,
    text_plain: Atom,
    dnd_property: Atom,
};

var g_x11: X11State = std.mem.zeroes(X11State);

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

fn rvn_x11_find(handle: Window) [*c]rvn_pwindow_t {
    var data: [*c]u8 = null;
    if (XFindContext(g_x11.display, handle, g_x11.context, &data) != 0) return null;
    return @ptrCast(@alignCast(data));
}

fn rvn_x11_emit(window: [*c]rvn_pwindow_t, event: [*c]rvn_pevent_t) void {
    event.*.user = window.*.user;
    g_x11.handler.?(event);
}

/// The desktop scale is published by the settings daemon as the Xft.dpi resource.
fn rvn_x11_read_scale() f32 {
    const resources = XResourceManagerString(g_x11.display);
    var scale: f32 = 1.0;
    if (resources != null) {
        const database = XrmGetStringDatabase(resources);
        if (database != null) {
            var value: XrmValue = undefined;
            var type_: [*c]u8 = null;
            if (XrmGetResource(database, "Xft.dpi", "Xft.Dpi", &type_, &value) != 0 and type_ != null and libc.strcmp(type_, "String") == 0 and value.addr != null) {
                const dpi: f64 = atof(value.addr);
                if (dpi >= 48.0 and dpi <= 960.0) scale = @floatCast(dpi / 96.0);
            }
            XrmDestroyDatabase(database);
        }
    }
    return scale;
}

fn rvn_x11_set_size_hints(window: [*c]rvn_pwindow_t, width: c_int, height: c_int) void {
    const hints = XAllocSizeHints();
    if (hints == null) return;
    if ((window.*.flags & WIN_NO_RESIZE) != 0) {
        hints.*.flags |= PMinSize | PMaxSize;
        hints.*.min_width = width;
        hints.*.max_width = width;
        hints.*.min_height = height;
        hints.*.max_height = height;
    } else if (window.*.min_width > 0 or window.*.min_height > 0) {
        hints.*.flags |= PMinSize;
        hints.*.min_width = window.*.min_width;
        hints.*.min_height = window.*.min_height;
    }
    XSetWMNormalHints(g_x11.display, window.*.handle, hints);
    _ = XFree(hints);
}

/// Asks the window manager to add or remove the maximized state.
fn rvn_x11_send_maximize(window: [*c]rvn_pwindow_t, maximize: c_int) void {
    var event = std.mem.zeroes(XEvent);
    event.xclient.type = ClientMessage;
    event.xclient.window = window.*.handle;
    event.xclient.message_type = g_x11.net_wm_state;
    event.xclient.format = 32;
    event.xclient.data.l[0] = if (maximize != 0) 1 else 0; // _NET_WM_STATE_ADD / _REMOVE
    event.xclient.data.l[1] = @bitCast(g_x11.net_wm_state_maximized_vert);
    event.xclient.data.l[2] = @bitCast(g_x11.net_wm_state_maximized_horz);
    event.xclient.data.l[3] = 1;
    _ = XSendEvent(g_x11.display, g_x11.root, False, SubstructureNotifyMask | SubstructureRedirectMask, &event);
}

/// Reads a whole property of a window. Free with XFree.
fn rvn_x11_property(window: Window, property: Atom, type_: [*c]Atom, format: [*c]c_int, count: [*c]c_ulong, remove: Bool) [*c]u8 {
    var remaining: c_ulong = 0;
    var data: [*c]u8 = null;
    type_.* = None;
    format.* = 0;
    count.* = 0;
    if (XGetWindowProperty(g_x11.display, window, property, 0, 0x1FFFFFFF, remove, AnyPropertyType, type_, format, count, &remaining, &data) != Success) return null;
    return data;
}

/// R_TRUE when a window manager runs and announces a feature in _NET_SUPPORTED.
fn rvn_x11_wm_supports(feature: Atom) c_int {
    var type_: Atom = undefined;
    var format: c_int = undefined;
    var count: c_ulong = undefined;
    var found: c_int = raven.R_FALSE;
    const data = rvn_x11_property(g_x11.root, g_x11.net_supported, &type_, &format, &count, False);
    if (data != null and type_ == XA_ATOM and format == 32) {
        const atoms: [*c]const Atom = @ptrCast(@alignCast(data));
        const n: usize = @intCast(count);
        var i: usize = 0;
        while (i < n and found == raven.R_FALSE) : (i += 1) found = @intFromBool(atoms[i] == feature);
    }
    if (data != null) _ = XFree(data);
    return found;
}

fn rvn_x11_has_window_manager() c_int {
    var type_: Atom = undefined;
    var format: c_int = undefined;
    var count: c_ulong = undefined;
    const data = rvn_x11_property(g_x11.root, g_x11.net_supporting_wm_check, &type_, &format, &count, False);
    const present = data != null and count > 0;
    if (data != null) _ = XFree(data);
    return @intFromBool(present);
}

// ---------------------------------------------------------------------------
//  Lifecycle
// ---------------------------------------------------------------------------

fn rvn_x11_init(handler: rvn_pevent_handler_t, regions: rvn_pregion_handler_t) callconv(.c) c_int {
    const shapes = [RVN_X11_CURSOR_COUNT]c_uint{
        XC_left_ptr,            XC_xterm,              XC_hand2, XC_crosshair, XC_sb_h_double_arrow, XC_sb_v_double_arrow,
        XC_bottom_right_corner, XC_bottom_left_corner, XC_fleur, XC_X_cursor,
    };
    var supported: Bool = False;
    var i: usize = 0;

    // (the regions of custom headers are watched by the core: X11 only moves and resizes when told)
    _ = regions;
    g_x11 = std.mem.zeroes(X11State);
    g_x11.handler = handler;
    g_x11.wake_pipe[0] = -1;
    g_x11.wake_pipe[1] = -1;

    // the render thread talks to the X server too (Vulkan presentation)
    _ = XInitThreads();
    // text input needs the character encoding of the user; do not touch the other categories
    if (libc.strcmp(setlocale(LC_CTYPE, null), "C") == 0) _ = setlocale(LC_CTYPE, "");
    XrmInitialize();

    g_x11.display = XOpenDisplay(null);
    if (g_x11.display == null) {
        base.rvn_error(raven.R_ERROR_PLATFORM, raven.R_SEVERITY_ERROR, "X11: cannot open the display (is DISPLAY set?)");
        return raven.R_FALSE;
    }
    // DefaultScreen(dpy) = XScreenNumberOfScreen(DefaultScreenOfDisplay(dpy))
    g_x11.screen = XScreenNumberOfScreen(XDefaultScreenOfDisplay(g_x11.display));
    g_x11.root = XRootWindow(g_x11.display, g_x11.screen);
    g_x11.context = XUniqueContext();
    g_x11.scale = rvn_x11_read_scale();

    g_x11.wm_protocols = XInternAtom(g_x11.display, "WM_PROTOCOLS", False);
    g_x11.wm_delete_window = XInternAtom(g_x11.display, "WM_DELETE_WINDOW", False);
    g_x11.net_wm_name = XInternAtom(g_x11.display, "_NET_WM_NAME", False);
    g_x11.net_wm_state = XInternAtom(g_x11.display, "_NET_WM_STATE", False);
    g_x11.net_wm_state_maximized_vert = XInternAtom(g_x11.display, "_NET_WM_STATE_MAXIMIZED_VERT", False);
    g_x11.net_wm_state_maximized_horz = XInternAtom(g_x11.display, "_NET_WM_STATE_MAXIMIZED_HORZ", False);
    g_x11.motif_wm_hints = XInternAtom(g_x11.display, "_MOTIF_WM_HINTS", False);
    g_x11.utf8_string = XInternAtom(g_x11.display, "UTF8_STRING", False);
    g_x11.clipboard_atom = XInternAtom(g_x11.display, "CLIPBOARD", False);
    g_x11.targets = XInternAtom(g_x11.display, "TARGETS", False);
    g_x11.incr = XInternAtom(g_x11.display, "INCR", False);
    g_x11.paste_property = XInternAtom(g_x11.display, "RVN_PASTE", False);
    g_x11.net_supported = XInternAtom(g_x11.display, "_NET_SUPPORTED", False);
    g_x11.net_supporting_wm_check = XInternAtom(g_x11.display, "_NET_SUPPORTING_WM_CHECK", False);
    g_x11.net_wm_moveresize = XInternAtom(g_x11.display, "_NET_WM_MOVERESIZE", False);
    g_x11.xdnd_aware = XInternAtom(g_x11.display, "XdndAware", False);
    g_x11.xdnd_enter = XInternAtom(g_x11.display, "XdndEnter", False);
    g_x11.xdnd_position = XInternAtom(g_x11.display, "XdndPosition", False);
    g_x11.xdnd_status = XInternAtom(g_x11.display, "XdndStatus", False);
    g_x11.xdnd_leave = XInternAtom(g_x11.display, "XdndLeave", False);
    g_x11.xdnd_drop = XInternAtom(g_x11.display, "XdndDrop", False);
    g_x11.xdnd_finished = XInternAtom(g_x11.display, "XdndFinished", False);
    g_x11.xdnd_selection = XInternAtom(g_x11.display, "XdndSelection", False);
    g_x11.xdnd_type_list = XInternAtom(g_x11.display, "XdndTypeList", False);
    g_x11.xdnd_action_copy = XInternAtom(g_x11.display, "XdndActionCopy", False);
    g_x11.uri_list = XInternAtom(g_x11.display, "text/uri-list", False);
    g_x11.text_plain_utf8 = XInternAtom(g_x11.display, "text/plain;charset=utf-8", False);
    g_x11.text_plain = XInternAtom(g_x11.display, "text/plain", False);
    g_x11.dnd_property = XInternAtom(g_x11.display, "RVN_DND", False);

    // a held key sends presses only: releases then always mean a real release
    _ = XkbSetDetectableAutoRepeat(g_x11.display, True, &supported);

    if (XSupportsLocale() != 0) {
        _ = XSetLocaleModifiers("");
        g_x11.input_method = XOpenIM(g_x11.display, null, null, null);
    }

    while (i < RVN_X11_CURSOR_COUNT) : (i += 1) g_x11.cursors[i] = XCreateFontCursor(g_x11.display, shapes[i]);

    var attributes = std.mem.zeroes(XSetWindowAttributes);
    attributes.event_mask = PropertyChangeMask;
    g_x11.helper = XCreateWindow(g_x11.display, g_x11.root, -10, -10, 1, 1, 0, 0, InputOnly, null, CWEventMask, &attributes);

    if (libc.pipe(&g_x11.wake_pipe) == 0) {
        i = 0;
        while (i < 2) : (i += 1) {
            const flags = libc.fcntl(g_x11.wake_pipe[i], F_GETFL, @as(c_int, 0));
            _ = libc.fcntl(g_x11.wake_pipe[i], F_SETFL, flags | O_NONBLOCK);
            _ = libc.fcntl(g_x11.wake_pipe[i], F_SETFD, @as(c_int, FD_CLOEXEC));
        }
    } else {
        g_x11.wake_pipe[0] = -1;
        g_x11.wake_pipe[1] = -1;
    }
    return raven.R_TRUE;
}

fn rvn_x11_shutdown() callconv(.c) void {
    var i: usize = 0;
    atspi.rvn_atspi_shutdown();
    if (g_x11.display == null) return;
    while (i < RVN_X11_CURSOR_COUNT) : (i += 1) {
        if (g_x11.cursors[i] != 0) _ = XFreeCursor(g_x11.display, g_x11.cursors[i]);
    }
    if (g_x11.helper != 0) _ = XDestroyWindow(g_x11.display, g_x11.helper);
    if (g_x11.input_method != null) _ = XCloseIM(g_x11.input_method);
    _ = XCloseDisplay(g_x11.display);
    if (g_x11.wake_pipe[0] >= 0) _ = libc.close(g_x11.wake_pipe[0]);
    if (g_x11.wake_pipe[1] >= 0) _ = libc.close(g_x11.wake_pipe[1]);
    base.rvn_free(g_x11.clipboard);
    g_x11 = std.mem.zeroes(X11State);
}

fn rvn_x11_native_display() callconv(.c) ?*anyopaque {
    return @ptrCast(g_x11.display);
}

// ---------------------------------------------------------------------------
//  Windows
// ---------------------------------------------------------------------------

fn rvn_x11_window_set_title(window: [*c]rvn_pwindow_t, title: [*c]const u8) callconv(.c) void {
    _ = XStoreName(g_x11.display, window.*.handle, title);
    _ = XChangeProperty(g_x11.display, window.*.handle, g_x11.net_wm_name, g_x11.utf8_string, 8, PropModeReplace, title, @intCast(libc.strlen(title)));
}

/// Is a compositing manager running? Without one, nothing blends a window with what is behind it.
fn rvn_x11_composited() c_int {
    var name: [32]u8 = undefined;
    const forced = libc.getenv("RAVEN_X11_COMPOSITED");
    if (forced != null and forced[0] != 0) return @intFromBool(forced[0] != '0');
    _ = libc.snprintf(&name, name.len, "_NET_WM_CM_S%d", g_x11.screen);
    return @intFromBool(XGetSelectionOwner(g_x11.display, XInternAtom(g_x11.display, &name, False)) != None);
}

fn rvn_x11_window_create(desc: [*c]const platform_h.rvn_pwindow_desc_t) callconv(.c) ?*platform_h.rvn_pwindow_t {
    const window: [*c]rvn_pwindow_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_pwindow_t))));
    var attributes = std.mem.zeroes(XSetWindowAttributes);
    var class_hint: [*c]XClassHint = undefined;
    var protocols: [1]Atom = undefined;
    var attribute_mask: c_ulong = CWBackPixmap | CWBitGravity | CWEventMask;
    var depth: c_int = CopyFromParent;

    window.*.user = desc.*.user;
    window.*.flags = desc.*.flags;
    window.*.width = base.rvn_maxi(1, @intFromFloat(@as(f32, @floatFromInt(desc.*.width)) * g_x11.scale + 0.5));
    window.*.height = base.rvn_maxi(1, @intFromFloat(@as(f32, @floatFromInt(desc.*.height)) * g_x11.scale + 0.5));

    // no background: the server never paints over our frame, which avoids flicker when resizing
    attributes.background_pixmap = None;
    attributes.bit_gravity = NorthWestGravity;
    attributes.event_mask = StructureNotifyMask | ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask |
        ButtonReleaseMask | PointerMotionMask | EnterWindowMask | LeaveWindowMask | FocusChangeMask | PropertyChangeMask;
    if ((desc.*.flags & WIN_TRANSPARENT) != 0 and rvn_x11_composited() != 0) {
        // a visual with an alpha channel: the compositing manager blends the window with what is behind it
        var info: XVisualInfo = undefined;
        if (XMatchVisualInfo(g_x11.display, g_x11.screen, 32, TrueColor, &info) != 0) {
            window.*.visual = info.visual;
            window.*.colormap = XCreateColormap(g_x11.display, g_x11.root, info.visual, AllocNone);
            window.*.transparent = raven.R_TRUE;
            depth = 32;
            // (a window whose depth is not the one of its parent needs a colormap and a border pixel of its own)
            attributes.colormap = window.*.colormap;
            attributes.border_pixel = 0;
            attribute_mask |= CWColormap | CWBorderPixel;
        }
    }
    // CopyFromParent as the visual is the null visual
    window.*.handle = XCreateWindow(g_x11.display, g_x11.root, 0, 0, @intCast(window.*.width), @intCast(window.*.height), 0, depth, InputOutput, if (window.*.visual != null) window.*.visual else null, attribute_mask, &attributes);
    if (window.*.handle == 0) {
        if (window.*.colormap != 0) _ = XFreeColormap(g_x11.display, window.*.colormap);
        base.rvn_free(window);
        return null;
    }
    _ = XSaveContext(g_x11.display, window.*.handle, g_x11.context, @ptrCast(window));

    protocols[0] = g_x11.wm_delete_window;
    _ = XSetWMProtocols(g_x11.display, window.*.handle, &protocols, 1);
    rvn_x11_window_set_title(window, if (desc.*.title != null) desc.*.title else "");
    rvn_x11_set_size_hints(window, window.*.width, window.*.height);

    class_hint = XAllocClassHint();
    if (class_hint != null) {
        // Seridian: the names given by Rset_window_class ("raven" when none was given)
        var name = [_:0]u8{ 'r', 'a', 'v', 'e', 'n' };
        class_hint.*.res_name = if (desc.*.wm_name != null and desc.*.wm_name[0] != 0) @constCast(desc.*.wm_name) else &name;
        class_hint.*.res_class = if (desc.*.wm_class != null and desc.*.wm_class[0] != 0) @constCast(desc.*.wm_class) else class_hint.*.res_name;
        _ = XSetClassHint(g_x11.display, window.*.handle, class_hint);
        _ = XFree(class_hint);
    }
    {
        // files and text can be dropped on the window (XDND version 5)
        var version: Atom = 5;
        _ = XChangeProperty(g_x11.display, window.*.handle, g_x11.xdnd_aware, XA_ATOM, 32, PropModeReplace, @ptrCast(&version), 1);
    }
    if ((desc.*.flags & (WIN_BORDERLESS | WIN_CUSTOM_HEADER)) != 0) {
        // Motif hints: flags = decorations, decorations = none
        var hints: [5]c_long = .{ 2, 0, 0, 0, 0 };
        _ = XChangeProperty(g_x11.display, window.*.handle, g_x11.motif_wm_hints, g_x11.motif_wm_hints, 32, PropModeReplace, @ptrCast(&hints), 5);
    }
    if ((desc.*.flags & WIN_MAXIMIZED) != 0) {
        // before the window is mapped the state is set directly on the window
        var states: [2]Atom = undefined;
        states[0] = g_x11.net_wm_state_maximized_vert;
        states[1] = g_x11.net_wm_state_maximized_horz;
        _ = XChangeProperty(g_x11.display, window.*.handle, g_x11.net_wm_state, XA_ATOM, 32, PropModeReplace, @ptrCast(&states), 2);
    }
    if (g_x11.input_method != null) {
        window.*.input_context = XCreateIC(g_x11.input_method, XNInputStyle, XIMPreeditNothing | XIMStatusNothing, XNClientWindow, window.*.handle, XNFocusWindow, window.*.handle, @as(?*anyopaque, null));
    }
    _ = XFlush(g_x11.display);
    return @ptrCast(window);
}

fn rvn_x11_window_destroy(window: [*c]rvn_pwindow_t) callconv(.c) void {
    if (g_x11.drag_window == window) g_x11.drag_window = null;
    if (window.*.input_context != null) XDestroyIC(window.*.input_context);
    if (window.*.is_child == 0) _ = XDeleteContext(g_x11.display, window.*.handle, g_x11.context);
    _ = XDestroyWindow(g_x11.display, window.*.handle);
    if (window.*.colormap != 0) _ = XFreeColormap(g_x11.display, window.*.colormap);
    _ = XFlush(g_x11.display);
    base.rvn_free(window);
}

/// What shows behind a window with an alpha channel. X11 itself knows nothing of blur: it is a hint to the compositing manager.
fn rvn_x11_window_set_backdrop(window: [*c]rvn_pwindow_t, backdrop: c_int, dark: c_int) callconv(.c) c_int {
    const blur = XInternAtom(g_x11.display, "_KDE_NET_WM_BLUR_BEHIND_REGION", False);
    var given: c_int = raven.R_BACKDROP_TRANSPARENT;
    _ = dark;
    if (window.*.transparent == 0) return raven.R_BACKDROP_NONE;
    if (backdrop == raven.R_BACKDROP_BLUR or backdrop == raven.R_BACKDROP_ACRYLIC or backdrop == raven.R_BACKDROP_MICA) {
        // an empty region means "behind the whole window" (KWin, and the compositors that took the hint from it)
        const none: c_ulong = 0;
        _ = XChangeProperty(g_x11.display, window.*.handle, blur, XA_CARDINAL, 32, PropModeReplace, @ptrCast(&none), 0);
        if (rvn_x11_wm_supports(blur) != 0) given = raven.R_BACKDROP_BLUR;
    } else {
        _ = XDeleteProperty(g_x11.display, window.*.handle, blur);
        if (backdrop == raven.R_BACKDROP_NONE) given = raven.R_BACKDROP_NONE;
    }
    _ = XFlush(g_x11.display);
    return given;
}

fn rvn_x11_window_set_opacity(window: [*c]rvn_pwindow_t, opacity: f32) callconv(.c) c_int {
    const property = XInternAtom(g_x11.display, "_NET_WM_WINDOW_OPACITY", False);
    if (rvn_x11_composited() == 0) return raven.R_FALSE;
    if (opacity >= 0.999) {
        _ = XDeleteProperty(g_x11.display, window.*.handle, property);
    } else {
        // (format 32 properties are given as longs, whatever the size of a long)
        const value: c_ulong = @intFromFloat(@as(f64, opacity) * 4294967295.0);
        _ = XChangeProperty(g_x11.display, window.*.handle, property, XA_CARDINAL, 32, PropModeReplace, @ptrCast(&value), 1);
    }
    _ = XFlush(g_x11.display);
    return raven.R_TRUE;
}

fn rvn_x11_window_set_topmost(window: [*c]rvn_pwindow_t, topmost: c_int) callconv(.c) c_int {
    var event = std.mem.zeroes(XEvent);
    event.xclient.type = ClientMessage;
    event.xclient.window = window.*.handle;
    event.xclient.message_type = XInternAtom(g_x11.display, "_NET_WM_STATE", False);
    event.xclient.format = 32;
    event.xclient.data.l[0] = if (topmost != 0) 1 else 0;
    event.xclient.data.l[1] = @bitCast(XInternAtom(g_x11.display, "_NET_WM_STATE_ABOVE", False));
    event.xclient.data.l[3] = 1;
    // DefaultRootWindow(dpy) = DefaultScreenOfDisplay(dpy)->root
    _ = XSendEvent(g_x11.display, XDefaultScreenOfDisplay(g_x11.display).*.root, False, SubstructureRedirectMask | SubstructureNotifyMask, &event);
    _ = XFlush(g_x11.display);
    return raven.R_TRUE;
}

fn rvn_x11_window_center(window: [*c]rvn_pwindow_t) callconv(.c) void {
    var attributes: XWindowAttributes = undefined;
    // WidthOfScreen / HeightOfScreen of DefaultScreenOfDisplay (the macros read the Screen fields)
    const screen = XDefaultScreenOfDisplay(g_x11.display);
    if (XGetWindowAttributes(g_x11.display, window.*.handle, &attributes) == 0) return;
    _ = XMoveWindow(g_x11.display, window.*.handle, @divTrunc(screen.*.width - attributes.width, 2), @divTrunc(screen.*.height - attributes.height, 2));
    _ = XFlush(g_x11.display);
}

fn rvn_x11_window_set_size(window: [*c]rvn_pwindow_t, width_arg: c_int, height_arg: c_int) callconv(.c) void {
    const width = base.rvn_maxi(width_arg, 1);
    const height = base.rvn_maxi(height_arg, 1);
    if ((window.*.flags & WIN_NO_RESIZE) != 0) rvn_x11_set_size_hints(window, width, height);
    _ = XResizeWindow(g_x11.display, window.*.handle, @intCast(width), @intCast(height));
    _ = XFlush(g_x11.display);
}

fn rvn_x11_window_get_size(window: [*c]rvn_pwindow_t, width: [*c]c_int, height: [*c]c_int) callconv(.c) void {
    width.* = window.*.width;
    height.* = window.*.height;
}

fn rvn_x11_window_set_min_size(window: [*c]rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void {
    window.*.min_width = width;
    window.*.min_height = height;
    rvn_x11_set_size_hints(window, window.*.width, window.*.height);
}

fn rvn_x11_window_set_position(window: [*c]rvn_pwindow_t, x: c_int, y: c_int) callconv(.c) void {
    _ = XMoveWindow(g_x11.display, window.*.handle, x, y);
    _ = XFlush(g_x11.display);
}

fn rvn_x11_window_get_position(window: [*c]rvn_pwindow_t, x: [*c]c_int, y: [*c]c_int) callconv(.c) void {
    var child: Window = undefined;
    // position of the client area on the screen, whatever the window manager added around it
    _ = XTranslateCoordinates(g_x11.display, window.*.handle, g_x11.root, 0, 0, x, y, &child);
}

fn rvn_x11_window_get_scale(window: [*c]rvn_pwindow_t) callconv(.c) f32 {
    _ = window;
    return g_x11.scale;
}

fn rvn_x11_window_show(window: [*c]rvn_pwindow_t, visible: c_int) callconv(.c) void {
    if (visible != 0) {
        _ = XMapRaised(g_x11.display, window.*.handle);
    } else {
        _ = XWithdrawWindow(g_x11.display, window.*.handle, g_x11.screen);
    }
    _ = XFlush(g_x11.display);
}

fn rvn_x11_emit_state(window: [*c]rvn_pwindow_t, state: rvn_pwindow_state_t) void {
    var event = std.mem.zeroes(rvn_pevent_t);
    event.type = platform_h.RVN_PEVENT_STATE;
    event.state = state;
    rvn_x11_emit(window, &event);
}

/// No window manager: "maximized" is the size of the screen, and we remember what to come back to.
fn rvn_x11_maximize_by_hand(window: [*c]rvn_pwindow_t, maximize: c_int) void {
    if (window.*.maximized == maximize) return;
    if (maximize != 0) {
        var child: Window = undefined;
        _ = XTranslateCoordinates(g_x11.display, window.*.handle, g_x11.root, 0, 0, &window.*.restore_x, &window.*.restore_y, &child);
        window.*.restore_width = window.*.width;
        window.*.restore_height = window.*.height;
        // DisplayWidth / DisplayHeight of the default screen
        const screen = XScreenOfDisplay(g_x11.display, g_x11.screen);
        _ = XMoveResizeWindow(g_x11.display, window.*.handle, 0, 0, @intCast(screen.*.width), @intCast(screen.*.height));
    } else {
        _ = XMoveResizeWindow(g_x11.display, window.*.handle, window.*.restore_x, window.*.restore_y, @intCast(base.rvn_maxi(window.*.restore_width, 1)), @intCast(base.rvn_maxi(window.*.restore_height, 1)));
    }
    window.*.maximized = maximize;
    if (maximize != 0) {
        rvn_x11_emit_state(window, platform_h.RVN_PWINDOW_MAXIMIZED);
    } else {
        rvn_x11_emit_state(window, platform_h.RVN_PWINDOW_NORMAL);
    }
}

fn rvn_x11_window_set_state(window: [*c]rvn_pwindow_t, state: rvn_pwindow_state_t) callconv(.c) void {
    const managed = rvn_x11_has_window_manager();
    switch (state) {
        platform_h.RVN_PWINDOW_MINIMIZED => {
            _ = XIconifyWindow(g_x11.display, window.*.handle, g_x11.screen);
        },
        platform_h.RVN_PWINDOW_MAXIMIZED => {
            _ = XMapRaised(g_x11.display, window.*.handle);
            if (managed != 0) rvn_x11_send_maximize(window, raven.R_TRUE) else rvn_x11_maximize_by_hand(window, raven.R_TRUE);
        },
        platform_h.RVN_PWINDOW_NORMAL => {
            _ = XMapRaised(g_x11.display, window.*.handle);
            if (managed != 0) rvn_x11_send_maximize(window, raven.R_FALSE) else rvn_x11_maximize_by_hand(window, raven.R_FALSE);
        },
        else => {},
    }
    _ = XFlush(g_x11.display);
}

fn rvn_x11_window_get_state(window: [*c]rvn_pwindow_t) callconv(.c) rvn_pwindow_state_t {
    var type_: Atom = undefined;
    var format: c_int = undefined;
    var vertical: c_int = raven.R_FALSE;
    var horizontal: c_int = raven.R_FALSE;
    var count: c_ulong = undefined;
    if (window.*.maximized != 0) return platform_h.RVN_PWINDOW_MAXIMIZED;
    const data = rvn_x11_property(window.*.handle, g_x11.net_wm_state, &type_, &format, &count, False);
    if (data != null and type_ == XA_ATOM and format == 32) {
        const atoms: [*c]const Atom = @ptrCast(@alignCast(data));
        const n: usize = @intCast(count);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (atoms[i] == g_x11.net_wm_state_maximized_vert) vertical = raven.R_TRUE;
            if (atoms[i] == g_x11.net_wm_state_maximized_horz) horizontal = raven.R_TRUE;
        }
    }
    if (data != null) _ = XFree(data);
    if (vertical != 0 and horizontal != 0) return platform_h.RVN_PWINDOW_MAXIMIZED;
    return platform_h.RVN_PWINDOW_NORMAL;
}

/// The user pressed on the caption or on an edge of a window without
/// decoration. A window manager takes over from here (_NET_WM_MOVERESIZE):
/// it snaps and constrains as it does for its own title bars. Without one,
/// the window follows the pointer by hand until the button is released.
fn rvn_x11_begin_drag(window: [*c]rvn_pwindow_t, region: rvn_pregion_t) void {
    // directions of _NET_WM_MOVERESIZE, in the order of rvn_pregion_t from RVN_PREGION_CAPTION
    const directions = [_]c_long{ 8, 7, 3, 1, 5, 0, 2, 6, 4 };
    var root: Window = undefined;
    var child: Window = undefined;
    var root_x: c_int = 0;
    var root_y: c_int = 0;
    var x: c_int = undefined;
    var y: c_int = undefined;
    var mask: c_uint = undefined;

    if (region < platform_h.RVN_PREGION_CAPTION or region > platform_h.RVN_PREGION_BOTTOM_RIGHT) return;
    _ = XQueryPointer(g_x11.display, g_x11.root, &root, &child, &root_x, &root_y, &x, &y, &mask);

    if (rvn_x11_wm_supports(g_x11.net_wm_moveresize) != 0) {
        // the button press grabbed the pointer for us: the window manager needs it
        _ = XUngrabPointer(g_x11.display, CurrentTime);
        var event = std.mem.zeroes(XEvent);
        event.xclient.type = ClientMessage;
        event.xclient.window = window.*.handle;
        event.xclient.message_type = g_x11.net_wm_moveresize;
        event.xclient.format = 32;
        event.xclient.data.l[0] = root_x;
        event.xclient.data.l[1] = root_y;
        event.xclient.data.l[2] = directions[region - platform_h.RVN_PREGION_CAPTION];
        event.xclient.data.l[3] = Button1;
        event.xclient.data.l[4] = 1;
        _ = XSendEvent(g_x11.display, g_x11.root, False, SubstructureNotifyMask | SubstructureRedirectMask, &event);
        _ = XFlush(g_x11.display);
        return;
    }
    if (window.*.maximized != 0) return;
    g_x11.drag_window = window;
    g_x11.drag_region = region;
    g_x11.drag_root_x = root_x;
    g_x11.drag_root_y = root_y;
    _ = XTranslateCoordinates(g_x11.display, window.*.handle, g_x11.root, 0, 0, &g_x11.drag_x, &g_x11.drag_y, &child);
    g_x11.drag_width = window.*.width;
    g_x11.drag_height = window.*.height;
}

fn rvn_x11_window_begin_move(window: [*c]rvn_pwindow_t) callconv(.c) void {
    rvn_x11_begin_drag(window, platform_h.RVN_PREGION_CAPTION);
}

fn rvn_x11_window_begin_resize(window: [*c]rvn_pwindow_t, edge: rvn_pregion_t) callconv(.c) void {
    if (edge != platform_h.RVN_PREGION_CAPTION) rvn_x11_begin_drag(window, edge);
}

/// The pointer moved while a window is moved or resized by hand.
fn rvn_x11_drag_to(root_x: c_int, root_y: c_int) void {
    const window = g_x11.drag_window;
    const dx = root_x - g_x11.drag_root_x;
    const dy = root_y - g_x11.drag_root_y;
    var x = g_x11.drag_x;
    var y = g_x11.drag_y;
    var width = g_x11.drag_width;
    var height = g_x11.drag_height;
    const min_width = base.rvn_maxi(window.*.min_width, 48);
    const min_height = base.rvn_maxi(window.*.min_height, 32);
    const region = g_x11.drag_region;
    const left = region == platform_h.RVN_PREGION_LEFT or region == platform_h.RVN_PREGION_TOP_LEFT or region == platform_h.RVN_PREGION_BOTTOM_LEFT;
    const right = region == platform_h.RVN_PREGION_RIGHT or region == platform_h.RVN_PREGION_TOP_RIGHT or region == platform_h.RVN_PREGION_BOTTOM_RIGHT;
    const top = region == platform_h.RVN_PREGION_TOP or region == platform_h.RVN_PREGION_TOP_LEFT or region == platform_h.RVN_PREGION_TOP_RIGHT;
    const bottom = region == platform_h.RVN_PREGION_BOTTOM or region == platform_h.RVN_PREGION_BOTTOM_LEFT or region == platform_h.RVN_PREGION_BOTTOM_RIGHT;

    if (region == platform_h.RVN_PREGION_CAPTION) {
        _ = XMoveWindow(g_x11.display, window.*.handle, x + dx, y + dy);
        _ = XFlush(g_x11.display);
        return;
    }
    // the opposite edge stays where it is
    if (right) width = base.rvn_maxi(width + dx, min_width);
    if (bottom) height = base.rvn_maxi(height + dy, min_height);
    if (left) {
        const new_width = base.rvn_maxi(width - dx, min_width);
        x += width - new_width;
        width = new_width;
    }
    if (top) {
        const new_height = base.rvn_maxi(height - dy, min_height);
        y += height - new_height;
        height = new_height;
    }
    _ = XMoveResizeWindow(g_x11.display, window.*.handle, x, y, @intCast(width), @intCast(height));
    _ = XFlush(g_x11.display);
}

fn rvn_x11_window_set_cursor(window: [*c]rvn_pwindow_t, cursor: raven.RCursor) callconv(.c) void {
    var index: c_int = @as(c_int, @bitCast(cursor)) - raven.R_CURSOR_ARROW;
    if (index < 0 or index >= RVN_X11_CURSOR_COUNT) index = 0;
    _ = XDefineCursor(g_x11.display, window.*.handle, g_x11.cursors[@intCast(index)]);
    _ = XFlush(g_x11.display);
}

fn rvn_x11_window_get_native(window: [*c]rvn_pwindow_t, native: [*c]raven.RNativeWindow) callconv(.c) void {
    native.*.system = raven.R_WINDOW_SYSTEM_X11;
    native.*.display = @ptrCast(g_x11.display);
    native.*.window = @intCast(window.*.handle);
    // DefaultVisual(dpy, scr) = ScreenOfDisplay(dpy, scr)->root_visual
    const visual = if (window.*.visual != null) window.*.visual else XScreenOfDisplay(g_x11.display, g_x11.screen).*.root_visual;
    native.*.visual = @intCast(XVisualIDFromVisual(visual));
    native.*.transparent = window.*.transparent;
}

// ---------------------------------------------------------------------------
//  Child windows (native viewports)
// ---------------------------------------------------------------------------

fn rvn_x11_child_create(parent: [*c]rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) ?*platform_h.rvn_pwindow_t {
    const child: [*c]rvn_pwindow_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_pwindow_t))));
    var attributes = std.mem.zeroes(XSetWindowAttributes);

    // BlackPixel(dpy, scr) = ScreenOfDisplay(dpy, scr)->black_pixel
    attributes.background_pixel = XScreenOfDisplay(g_x11.display, g_x11.screen).*.black_pixel;
    // No input is selected on the child: pointer events propagate to the
    // parent with coordinates relative to it, so the viewport widget receives
    // them like any other widget.
    attributes.event_mask = 0;
    child.*.user = user;
    child.*.is_child = raven.R_TRUE;
    child.*.width = base.rvn_maxi(width, 1);
    child.*.height = base.rvn_maxi(height, 1);
    child.*.handle = XCreateWindow(g_x11.display, parent.*.handle, x, y, @intCast(child.*.width), @intCast(child.*.height), 0, CopyFromParent, InputOutput, null, CWBackPixel | CWEventMask, &attributes);
    if (child.*.handle == 0) {
        base.rvn_free(child);
        return null;
    }
    _ = XMapWindow(g_x11.display, child.*.handle);
    _ = XFlush(g_x11.display);
    return @ptrCast(child);
}

fn rvn_x11_child_set_rect(child: [*c]rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, visible: c_int) callconv(.c) void {
    if (visible != 0) {
        child.*.width = base.rvn_maxi(width, 1);
        child.*.height = base.rvn_maxi(height, 1);
        _ = XMoveResizeWindow(g_x11.display, child.*.handle, x, y, @intCast(child.*.width), @intCast(child.*.height));
        _ = XMapWindow(g_x11.display, child.*.handle);
    } else {
        _ = XUnmapWindow(g_x11.display, child.*.handle);
    }
    _ = XFlush(g_x11.display);
}

// ---------------------------------------------------------------------------
//  Clipboard
// ---------------------------------------------------------------------------

fn rvn_x11_clipboard_set(text: [*c]const u8) callconv(.c) void {
    _ = base.rvn_str_set(&g_x11.clipboard, text);
    _ = XSetSelectionOwner(g_x11.display, g_x11.clipboard_atom, g_x11.helper, CurrentTime);
    _ = XFlush(g_x11.display);
}

/// Another application asks for the text we own.
fn rvn_x11_selection_request(request: [*c]const XSelectionRequestEvent) void {
    var reply = std.mem.zeroes(XEvent);
    const text: [*c]const u8 = if (g_x11.clipboard != null) g_x11.clipboard else "";

    reply.xselection.type = SelectionNotify;
    reply.xselection.requestor = request.*.requestor;
    reply.xselection.selection = request.*.selection;
    reply.xselection.target = request.*.target;
    reply.xselection.time = request.*.time;
    reply.xselection.property = if (request.*.property != None) request.*.property else request.*.target;

    if (request.*.target == g_x11.targets) {
        var targets: [3]Atom = undefined;
        targets[0] = g_x11.targets;
        targets[1] = g_x11.utf8_string;
        targets[2] = XA_STRING;
        _ = XChangeProperty(g_x11.display, request.*.requestor, reply.xselection.property, XA_ATOM, 32, PropModeReplace, @ptrCast(&targets), 3);
    } else if (request.*.target == g_x11.utf8_string or request.*.target == XA_STRING) {
        _ = XChangeProperty(g_x11.display, request.*.requestor, reply.xselection.property, request.*.target, 8, PropModeReplace, text, @intCast(libc.strlen(text)));
    } else {
        reply.xselection.property = None;
    }
    _ = XSendEvent(g_x11.display, request.*.requestor, False, 0, &reply);
    _ = XFlush(g_x11.display);
}

fn rvn_x11_clipboard_get() callconv(.c) [*c]u8 {
    var event: XEvent = undefined;
    var waited: c_int = 0;

    if (XGetSelectionOwner(g_x11.display, g_x11.clipboard_atom) == g_x11.helper) {
        return base.rvn_strdup(if (g_x11.clipboard != null) g_x11.clipboard else "");
    }
    _ = XConvertSelection(g_x11.display, g_x11.clipboard_atom, g_x11.utf8_string, g_x11.paste_property, g_x11.helper, CurrentTime);
    _ = XFlush(g_x11.display);

    // the owner answers with a SelectionNotify; give it a moment, not forever
    while (XCheckTypedWindowEvent(g_x11.display, g_x11.helper, SelectionNotify, &event) == 0) {
        var fd: std.c.pollfd = undefined;
        if (waited >= RVN_X11_CLIPBOARD_TIMEOUT_MS) return null;
        fd.fd = connectionNumber(g_x11.display);
        fd.events = POLLIN;
        fd.revents = 0;
        _ = libc.poll(&fd, 1, 10);
        waited += 10;
    }
    if (event.xselection.property == None) return null;
    {
        var type_: Atom = None;
        var format: c_int = 0;
        var count: c_ulong = 0;
        var remaining: c_ulong = 0;
        var data: [*c]u8 = null;
        var result: [*c]u8 = null;
        _ = XGetWindowProperty(g_x11.display, g_x11.helper, g_x11.paste_property, 0, 0x1FFFFFFF, True, AnyPropertyType, &type_, &format, &count, &remaining, &data);
        // very large texts use the incremental protocol, which is not supported
        if (data != null and type_ != g_x11.incr and format == 8) result = base.rvn_strndup(data, @intCast(count));
        if (data != null) _ = XFree(data);
        return result;
    }
}

// ---------------------------------------------------------------------------
//  Events
// ---------------------------------------------------------------------------

fn rvn_x11_key_test_and_set(key: raven.RKey, down: c_int) c_int {
    const index: c_int = @bitCast(key);
    if (index <= 0 or index >= raven.R_KEY_COUNT) return raven.R_FALSE;
    const byte: usize = @intCast(@divTrunc(index, 8));
    const bit: u3 = @intCast(@rem(index, 8));
    const was: c_int = @intCast((g_x11.keys_down[byte] >> bit) & 1);
    if (down != 0) {
        g_x11.keys_down[byte] |= @as(u8, 1) << bit;
    } else {
        g_x11.keys_down[byte] &= ~(@as(u8, 1) << bit);
    }
    return was;
}

/// The key as labelled in the active layout: what a shortcut like Ctrl+Z means.
fn rvn_x11_event_key(event: [*c]XKeyEvent) raven.RKey {
    // XkbGroupForCoreState(s) = (((s) >> 13) & 0x3)
    const group: c_uint = (event.*.state >> 13) & 0x3;
    var key = x11_internal.rvn_x11_translate_keysym(XkbKeycodeToKeysym(g_x11.display, @truncate(event.*.keycode), @intCast(group), 0));
    // layouts with digits on the shifted level (AZERTY)
    if (key == raven.R_KEY_UNKNOWN) {
        key = x11_internal.rvn_x11_translate_keysym(XkbKeycodeToKeysym(g_x11.display, @truncate(event.*.keycode), @intCast(group), 1));
    }
    return key;
}

fn rvn_x11_key_press(window: [*c]rvn_pwindow_t, key_event: [*c]XKeyEvent, filtered: c_int) void {
    var event: rvn_pevent_t = undefined;
    var buffer: [64]u8 = undefined;
    var length: c_int = 0;
    var symbol: KeySym = NoSymbol;
    var status: Status = 0;

    // the key itself; an event eaten by the input method (dead key, compose) is text only
    if (filtered == 0) {
        event = std.mem.zeroes(rvn_pevent_t);
        event.type = platform_h.RVN_PEVENT_KEY;
        event.key = rvn_x11_event_key(key_event);
        event.pressed = raven.R_TRUE;
        event.modifiers = x11_internal.rvn_x11_translate_modifiers(key_event.*.state);
        event.repeat = rvn_x11_key_test_and_set(event.key, raven.R_TRUE);
        rvn_x11_emit(window, &event);
    }

    // then the text it produces, if any
    if (window.*.input_context != null) {
        if (filtered != 0) return;
        length = Xutf8LookupString(window.*.input_context, key_event, &buffer, @intCast(buffer.len - 1), &symbol, &status);
        if (status != XLookupChars and status != XLookupBoth) length = 0;
    } else {
        // no input method: Latin-1 only
        var latin: [16]u8 = undefined;
        const count = XLookupString(key_event, &latin, @intCast(latin.len), &symbol, null);
        var i: c_int = 0;
        while (i < count) : (i += 1) {
            length += base.rvn_utf8_encode(latin[@intCast(i)], &buffer[@intCast(length)]);
        }
    }
    if (length > 0 and (key_event.*.state & (ControlMask | Mod1Mask)) == 0) {
        var cursor: [*c]const u8 = &buffer;
        const end: [*c]const u8 = &buffer[@intCast(length)];
        while (cursor < end) {
            const codepoint = base.rvn_utf8_decode(&cursor, end);
            if (codepoint < 32 or codepoint == 127) continue;
            event = std.mem.zeroes(rvn_pevent_t);
            event.type = platform_h.RVN_PEVENT_TEXT;
            event.codepoint = codepoint;
            rvn_x11_emit(window, &event);
        }
    }
}

fn rvn_x11_button(window: [*c]rvn_pwindow_t, button: [*c]const XButtonEvent, pressed: c_int) void {
    var event = std.mem.zeroes(rvn_pevent_t);
    event.x = button.*.x;
    event.y = button.*.y;
    event.modifiers = x11_internal.rvn_x11_translate_modifiers(button.*.state);

    // buttons 4 to 7 are the scroll wheel
    if (button.*.button >= 4 and button.*.button <= 7) {
        if (pressed == 0) return;
        event.type = platform_h.RVN_PEVENT_MOUSE_WHEEL;
        if (button.*.button == 4) {
            event.wheel_y = 1.0;
        } else if (button.*.button == 5) {
            event.wheel_y = -1.0;
        } else if (button.*.button == 6) {
            event.wheel_x = 1.0;
        } else {
            event.wheel_x = -1.0;
        }
        rvn_x11_emit(window, &event);
        return;
    }
    event.type = platform_h.RVN_PEVENT_MOUSE_BUTTON;
    event.pressed = pressed;
    switch (button.*.button) {
        Button1 => event.button = raven.R_MOUSE_LEFT,
        Button2 => event.button = raven.R_MOUSE_MIDDLE,
        Button3 => event.button = raven.R_MOUSE_RIGHT,
        8 => event.button = raven.R_MOUSE_X1,
        9 => event.button = raven.R_MOUSE_X2,
        else => return,
    }
    rvn_x11_emit(window, &event);
}

// ---------------------------------------------------------------------------
//  Drag and drop from other applications (XDND)
//
//  The source tells us it entered (with the formats it offers), then where
//  the pointer is; we answer each position with whether we would take a drop
//  there. On a drop we ask for the data as a selection, read it, and tell
//  the source we are done.
// ---------------------------------------------------------------------------

fn rvn_x11_dnd_send(source: Window, target: Window, message: Atom, a: c_long, b: c_long, c: c_long) void {
    var event = std.mem.zeroes(XEvent);
    event.xclient.type = ClientMessage;
    event.xclient.window = source;
    event.xclient.message_type = message;
    event.xclient.format = 32;
    event.xclient.data.l[0] = @bitCast(target);
    event.xclient.data.l[1] = a;
    event.xclient.data.l[2] = b;
    event.xclient.data.l[3] = 0;
    event.xclient.data.l[4] = c;
    _ = XSendEvent(g_x11.display, source, False, NoEventMask, &event);
    _ = XFlush(g_x11.display);
}

/// The format we like best among the ones offered: files, then text.
fn rvn_x11_dnd_pick(formats: [*c]const Atom, count: c_ulong) Atom {
    const wanted = [_]Atom{ g_x11.uri_list, g_x11.text_plain_utf8, g_x11.utf8_string, g_x11.text_plain, XA_STRING };
    const n: usize = @intCast(count);
    var k: usize = 0;
    while (k < wanted.len) : (k += 1) {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (formats[i] == wanted[k]) return wanted[k];
        }
    }
    return None;
}

fn rvn_x11_dnd_enter(message: [*c]const XClientMessageEvent) void {
    g_x11.dnd_source = @bitCast(message.*.data.l[0]);
    g_x11.dnd_accepted = raven.R_FALSE;
    if ((message.*.data.l[1] & 1) != 0) {
        // more than three formats: they are in a property of the source
        var type_: Atom = undefined;
        var format: c_int = undefined;
        var count: c_ulong = undefined;
        const data = rvn_x11_property(g_x11.dnd_source, g_x11.xdnd_type_list, &type_, &format, &count, False);
        if (data != null and type_ == XA_ATOM and format == 32) {
            g_x11.dnd_format = rvn_x11_dnd_pick(@ptrCast(@alignCast(data)), count);
        } else {
            g_x11.dnd_format = None;
        }
        if (data != null) _ = XFree(data);
    } else {
        var formats: [3]Atom = undefined;
        formats[0] = @bitCast(message.*.data.l[2]);
        formats[1] = @bitCast(message.*.data.l[3]);
        formats[2] = @bitCast(message.*.data.l[4]);
        g_x11.dnd_format = rvn_x11_dnd_pick(&formats, 3);
    }
}

fn rvn_x11_dnd_position(window: [*c]rvn_pwindow_t, message: [*c]const XClientMessageEvent) void {
    var event: rvn_pevent_t = undefined;
    var child: Window = undefined;
    var accepted: c_int = raven.R_FALSE;
    const root_x: c_int = @intCast((message.*.data.l[2] >> 16) & 0xFFFF);
    const root_y: c_int = @intCast(message.*.data.l[2] & 0xFFFF);

    g_x11.dnd_source = @bitCast(message.*.data.l[0]);
    _ = XTranslateCoordinates(g_x11.display, g_x11.root, window.*.handle, root_x, root_y, &g_x11.dnd_x, &g_x11.dnd_y, &child);
    if (g_x11.dnd_format != None) {
        event = std.mem.zeroes(rvn_pevent_t);
        event.type = platform_h.RVN_PEVENT_DRAG;
        event.x = g_x11.dnd_x;
        event.y = g_x11.dnd_y;
        event.accepted = &accepted;
        rvn_x11_emit(window, &event);
    }
    g_x11.dnd_accepted = accepted;
    // bit 0: we accept; bit 1: keep sending positions, what is under the pointer changes
    const flags: c_long = @as(c_long, @intFromBool(accepted != 0)) | 2;
    const action: c_long = if (accepted != 0) @bitCast(g_x11.xdnd_action_copy) else 0;
    rvn_x11_dnd_send(g_x11.dnd_source, window.*.handle, g_x11.xdnd_status, flags, 0, action);
}

fn rvn_x11_dnd_leave(window: [*c]rvn_pwindow_t) void {
    var event = std.mem.zeroes(rvn_pevent_t);
    event.type = platform_h.RVN_PEVENT_DRAG;
    event.leaving = raven.R_TRUE;
    rvn_x11_emit(window, &event);
    g_x11.dnd_source = None;
}

fn rvn_x11_hex(c: u8) c_int {
    if (c >= '0' and c <= '9') return @as(c_int, c) - '0';
    if (c >= 'a' and c <= 'f') return @as(c_int, c) - 'a' + 10;
    if (c >= 'A' and c <= 'F') return @as(c_int, c) - 'A' + 10;
    return -1;
}

/// "file://host/some%20path" -> "/some path". NULL when it is not a local file. Free with rvn_free.
fn rvn_x11_uri_to_path(uri: [*c]const u8, length: usize) [*c]u8 {
    var cursor: [*c]const u8 = uri;
    const end: [*c]const u8 = uri + length;
    var write: [*c]u8 = undefined;
    if (length < 7 or libc.memcmp(uri, "file://", 7) != 0) return null;
    cursor += 7;
    // the host name, usually empty
    while (cursor < end and cursor[0] != '/') cursor += 1;
    if (cursor == end) return null;
    const path: [*c]u8 = @ptrCast(base.rvn_alloc(@intCast(end - cursor + 1)));
    write = path;
    while (cursor < end) {
        if (cursor[0] == '%' and cursor + 2 < end and rvn_x11_hex(cursor[1]) >= 0 and rvn_x11_hex(cursor[2]) >= 0) {
            write[0] = @intCast(rvn_x11_hex(cursor[1]) * 16 + rvn_x11_hex(cursor[2]));
            write += 1;
            cursor += 3;
        } else {
            write[0] = cursor[0];
            write += 1;
            cursor += 1;
        }
    }
    write[0] = 0;
    return path;
}

/// The data of a drop arrived as a property of the window.
fn rvn_x11_dnd_receive(window: [*c]rvn_pwindow_t, selection: [*c]const XSelectionEvent) void {
    var event: rvn_pevent_t = undefined;
    var type_: Atom = undefined;
    var format: c_int = undefined;
    var done: c_int = raven.R_FALSE;
    var count: c_ulong = 0;
    const data: [*c]u8 = if (selection.*.property != None)
        rvn_x11_property(window.*.handle, selection.*.property, &type_, &format, &count, True)
    else
        null;
    const source = g_x11.dnd_source;

    event = std.mem.zeroes(rvn_pevent_t);
    event.type = platform_h.RVN_PEVENT_DROP;
    event.x = g_x11.dnd_x;
    event.y = g_x11.dnd_y;
    if (data != null and format == 8 and count > 0) {
        if (selection.*.target == g_x11.uri_list) {
            // one URI per line; lines starting with # are comments
            var paths: [*c][*c]u8 = null;
            var path_count: u32 = 0;
            var path_cap: u32 = 0;
            var cursor: [*c]const u8 = data;
            const end: [*c]const u8 = data + @as(usize, @intCast(count));
            while (cursor < end) {
                var line_end: [*c]const u8 = cursor;
                while (line_end < end and line_end[0] != '\r' and line_end[0] != '\n') line_end += 1;
                const path: [*c]u8 = if (line_end > cursor and cursor[0] != '#')
                    rvn_x11_uri_to_path(cursor, @intCast(line_end - cursor))
                else
                    null;
                if (path != null) {
                    // RVN_ARRAY_RESERVE(paths, path_cap, path_count + 1). The header unit's macro does not accept
                    // a `char**` item array (its rvn_array_grow_ parameter is ?*anyopaque, and [*c][*c]u8 does not coerce
                    // to it), so the same test and the same call are written out here.
                    const needed: u32 = path_count + 1;
                    if (needed > path_cap) {
                        paths = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(paths), &path_cap, needed, @sizeOf([*c]u8))));
                    }
                    paths[path_count] = path;
                    path_count += 1;
                }
                cursor = line_end;
                while (cursor < end and (cursor[0] == '\r' or cursor[0] == '\n')) cursor += 1;
            }
            if (path_count > 0) {
                event.drop_paths = @ptrCast(paths);
                event.drop_count = @intCast(path_count);
                rvn_x11_emit(window, &event);
                done = raven.R_TRUE;
            }
            var i: u32 = 0;
            while (i < path_count) : (i += 1) base.rvn_free(paths[i]);
            base.rvn_free(@ptrCast(paths));
        } else {
            const text = base.rvn_strndup(data, @intCast(count));
            event.drop_text = text;
            rvn_x11_emit(window, &event);
            base.rvn_free(text);
            done = raven.R_TRUE;
        }
    }
    if (data != null) _ = XFree(data);
    if (source != None) {
        const action: c_long = if (done != 0) @bitCast(g_x11.xdnd_action_copy) else 0;
        rvn_x11_dnd_send(source, selection.*.requestor, g_x11.xdnd_finished, if (done != 0) 1 else 0, action, 0);
    }
    g_x11.dnd_source = None;
}

fn rvn_x11_dnd_drop(window: [*c]rvn_pwindow_t, message: [*c]const XClientMessageEvent) void {
    g_x11.dnd_source = @bitCast(message.*.data.l[0]);
    if (g_x11.dnd_format != None and g_x11.dnd_accepted != 0) {
        // the answer is a SelectionNotify on the window
        _ = XConvertSelection(g_x11.display, g_x11.xdnd_selection, g_x11.dnd_format, g_x11.dnd_property, window.*.handle, @bitCast(message.*.data.l[2]));
        _ = XFlush(g_x11.display);
    } else {
        var event = std.mem.zeroes(rvn_pevent_t);
        event.type = platform_h.RVN_PEVENT_DRAG;
        event.leaving = raven.R_TRUE;
        rvn_x11_emit(window, &event);
        rvn_x11_dnd_send(g_x11.dnd_source, window.*.handle, g_x11.xdnd_finished, 0, 0, 0);
        g_x11.dnd_source = None;
    }
}

fn rvn_x11_process(xevent: [*c]XEvent) void {
    var event = std.mem.zeroes(rvn_pevent_t);

    // the input method sees every event first (dead keys, compose sequences)
    const filtered = XFilterEvent(xevent, None);

    if (xevent.*.type == SelectionRequest) {
        rvn_x11_selection_request(&xevent.*.xselectionrequest);
        return;
    }
    if (xevent.*.type == MappingNotify) {
        _ = XRefreshKeyboardMapping(&xevent.*.xmapping);
        return;
    }

    const window = rvn_x11_find(xevent.*.xany.window);
    if (window == null) return;

    sw: switch (xevent.*.type) {
        ClientMessage => {
            if (xevent.*.xclient.message_type == g_x11.wm_protocols and
                @as(Atom, @bitCast(xevent.*.xclient.data.l[0])) == g_x11.wm_delete_window)
            {
                event.type = platform_h.RVN_PEVENT_CLOSE;
                rvn_x11_emit(window, &event);
            } else if (xevent.*.xclient.message_type == g_x11.xdnd_enter) {
                rvn_x11_dnd_enter(&xevent.*.xclient);
            } else if (xevent.*.xclient.message_type == g_x11.xdnd_position) {
                rvn_x11_dnd_position(window, &xevent.*.xclient);
            } else if (xevent.*.xclient.message_type == g_x11.xdnd_leave) {
                rvn_x11_dnd_leave(window);
            } else if (xevent.*.xclient.message_type == g_x11.xdnd_drop) {
                rvn_x11_dnd_drop(window, &xevent.*.xclient);
            }
        },
        SelectionNotify => {
            if (xevent.*.xselection.selection == g_x11.xdnd_selection) rvn_x11_dnd_receive(window, &xevent.*.xselection);
        },
        PropertyNotify => {
            // the window manager maximized or restored the window
            if (xevent.*.xproperty.atom == g_x11.net_wm_state) rvn_x11_emit_state(window, rvn_x11_window_get_state(window));
        },
        ConfigureNotify => {
            if (xevent.*.xconfigure.width != window.*.width or xevent.*.xconfigure.height != window.*.height) {
                window.*.width = xevent.*.xconfigure.width;
                window.*.height = xevent.*.xconfigure.height;
                event.type = platform_h.RVN_PEVENT_RESIZE;
                event.width = window.*.width;
                event.height = window.*.height;
                event.scale = g_x11.scale;
                rvn_x11_emit(window, &event);
            }
        },
        Expose => {
            if (xevent.*.xexpose.count == 0) {
                event.type = platform_h.RVN_PEVENT_EXPOSE;
                rvn_x11_emit(window, &event);
            }
        },
        MotionNotify => {
            if (g_x11.drag_window == window) {
                rvn_x11_drag_to(xevent.*.xmotion.x_root, xevent.*.xmotion.y_root);
                break :sw;
            }
            event.type = platform_h.RVN_PEVENT_MOUSE_MOVE;
            event.x = xevent.*.xmotion.x;
            event.y = xevent.*.xmotion.y;
            event.modifiers = x11_internal.rvn_x11_translate_modifiers(xevent.*.xmotion.state);
            rvn_x11_emit(window, &event);
        },
        EnterNotify => {
            event.type = platform_h.RVN_PEVENT_MOUSE_MOVE;
            event.x = xevent.*.xcrossing.x;
            event.y = xevent.*.xcrossing.y;
            event.modifiers = x11_internal.rvn_x11_translate_modifiers(xevent.*.xcrossing.state);
            rvn_x11_emit(window, &event);
        },
        LeaveNotify => {
            // a pointer grab (button held, menu of the window manager) is not a real exit
            if (xevent.*.xcrossing.mode != NotifyNormal) break :sw;
            event.type = platform_h.RVN_PEVENT_MOUSE_LEAVE;
            rvn_x11_emit(window, &event);
        },
        ButtonPress => {
            rvn_x11_button(window, &xevent.*.xbutton, raven.R_TRUE);
        },
        ButtonRelease => {
            if (g_x11.drag_window == window and xevent.*.xbutton.button == Button1) {
                // the end of a move or of a resize: the core was told the button was gone when it began
                g_x11.drag_window = null;
                break :sw;
            }
            rvn_x11_button(window, &xevent.*.xbutton, raven.R_FALSE);
        },
        KeyPress => {
            rvn_x11_key_press(window, &xevent.*.xkey, filtered);
        },
        KeyRelease => {
            event.type = platform_h.RVN_PEVENT_KEY;
            event.key = rvn_x11_event_key(&xevent.*.xkey);
            event.pressed = raven.R_FALSE;
            event.modifiers = x11_internal.rvn_x11_translate_modifiers(xevent.*.xkey.state);
            _ = rvn_x11_key_test_and_set(event.key, raven.R_FALSE);
            rvn_x11_emit(window, &event);
        },
        FocusIn => {
            if (window.*.input_context != null) XSetICFocus(window.*.input_context);
            event.type = platform_h.RVN_PEVENT_FOCUS;
            event.focused = raven.R_TRUE;
            rvn_x11_emit(window, &event);
        },
        FocusOut => {
            if (window.*.input_context != null) XUnsetICFocus(window.*.input_context);
            // key releases will go to another window
            @memset(&g_x11.keys_down, 0);
            event.type = platform_h.RVN_PEVENT_FOCUS;
            event.focused = raven.R_FALSE;
            rvn_x11_emit(window, &event);
        },
        else => {},
    }
}

fn rvn_x11_pump(timeout_seconds: f64) callconv(.c) void {
    _ = XFlush(g_x11.display);

    if (XPending(g_x11.display) == 0 and timeout_seconds != 0.0) {
        var fds: [3]std.c.pollfd = undefined;
        const timeout_ms: c_int = if (timeout_seconds < 0.0) -1 else @intFromFloat(timeout_seconds * 1000.0 + 0.999);
        var count: c_int = undefined;
        const a11y = atspi.rvn_atspi_fd();
        fds[0].fd = connectionNumber(g_x11.display);
        fds[0].events = POLLIN;
        fds[0].revents = 0;
        fds[1].fd = g_x11.wake_pipe[0];
        fds[1].events = POLLIN;
        fds[1].revents = 0;
        count = if (g_x11.wake_pipe[0] >= 0) 2 else 1;
        // the screen reader asks on its own socket
        if (a11y >= 0) {
            const slot: usize = @intCast(count);
            fds[slot].fd = a11y;
            fds[slot].events = POLLIN;
            fds[slot].revents = 0;
            count += 1;
        }
        while (libc.poll(&fds, @intCast(count), timeout_ms) < 0 and std.c._errno().* == EINTR) {}
    }
    atspi.rvn_atspi_dispatch();
    // empty the wake-up pipe, whether we slept or not
    if (g_x11.wake_pipe[0] >= 0) {
        var buffer: [64]u8 = undefined;
        while (libc.read(g_x11.wake_pipe[0], &buffer, buffer.len) > 0) {}
    }

    while (g_x11.display != null and XPending(g_x11.display) != 0) {
        var xevent: XEvent = undefined;
        _ = XNextEvent(g_x11.display, &xevent);
        // only the last position of a burst of mouse moves matters
        if (xevent.type == MotionNotify) {
            while (XEventsQueued(g_x11.display, QueuedAlready) > 0) {
                var next: XEvent = undefined;
                _ = XPeekEvent(g_x11.display, &next);
                if (next.type != MotionNotify or next.xmotion.window != xevent.xmotion.window) break;
                _ = XNextEvent(g_x11.display, &xevent);
            }
        }
        rvn_x11_process(&xevent);
    }
}

fn rvn_x11_wake() callconv(.c) void {
    if (g_x11.wake_pipe[1] >= 0) {
        var byte: u8 = 1;
        // a full pipe already guarantees a wake-up
        if (libc.write(g_x11.wake_pipe[1], &byte, 1) < 0) {}
    }
}

const platform: platform_h.rvn_platform_t = .{
    .name = "X11",
    .system = raven.R_WINDOW_SYSTEM_X11,
    .init = rvn_x11_init,
    .shutdown = rvn_x11_shutdown,
    .native_display = rvn_x11_native_display,
    .window_create = rvn_x11_window_create,
    .window_destroy = @ptrCast(&rvn_x11_window_destroy),
    .window_set_title = @ptrCast(&rvn_x11_window_set_title),
    .window_set_size = @ptrCast(&rvn_x11_window_set_size),
    .window_get_size = @ptrCast(&rvn_x11_window_get_size),
    .window_set_min_size = @ptrCast(&rvn_x11_window_set_min_size),
    .window_set_position = @ptrCast(&rvn_x11_window_set_position),
    .window_get_position = @ptrCast(&rvn_x11_window_get_position),
    .window_get_scale = @ptrCast(&rvn_x11_window_get_scale),
    .window_show = @ptrCast(&rvn_x11_window_show),
    .window_set_state = @ptrCast(&rvn_x11_window_set_state),
    .window_get_state = @ptrCast(&rvn_x11_window_get_state),
    .window_begin_move = @ptrCast(&rvn_x11_window_begin_move),
    .window_begin_resize = @ptrCast(&rvn_x11_window_begin_resize),
    .window_set_backdrop = @ptrCast(&rvn_x11_window_set_backdrop),
    .window_set_opacity = @ptrCast(&rvn_x11_window_set_opacity),
    .window_set_topmost = @ptrCast(&rvn_x11_window_set_topmost),
    .window_center = @ptrCast(&rvn_x11_window_center),
    .window_set_cursor = @ptrCast(&rvn_x11_window_set_cursor),
    .window_get_native = @ptrCast(&rvn_x11_window_get_native),
    // not set by the C initializer: zero / NULL
    .window_set_icon = null,
    .native_regions = 0,
    .child_create = @ptrCast(&rvn_x11_child_create),
    .child_set_rect = @ptrCast(&rvn_x11_child_set_rect),
    .pump = rvn_x11_pump,
    .wake = rvn_x11_wake,
    .wait_service = null,
    .clipboard_set = rvn_x11_clipboard_set,
    .clipboard_get = rvn_x11_clipboard_get,
    .a11y_event = atspi.rvn_atspi_event,
    .a11y_announce = atspi.rvn_atspi_announce,
    .a11y_active = atspi.rvn_atspi_active,
    .a11y_settings = atspi.rvn_atspi_settings,
};

export fn rvn_platform_x11() [*c]const platform_h.rvn_platform_t {
    return &platform;
}
