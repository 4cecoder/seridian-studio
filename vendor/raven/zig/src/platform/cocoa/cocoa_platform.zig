// Translated to Zig from vendor/raven/src/platform/cocoa/cocoa_platform.m (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/cocoa/cocoa_platform.m
// Native macOS window system. Cocoa owns the windows and input event queue;
// each content view carries a CAMetalLayer for Vulkan's VK_EXT_metal_surface.
//
// Objective-C has no Zig syntax: the three classes of the C file (RavenCocoaView,
// RavenCocoaDelegate, RavenAccessibilityElement, and the RavenAccessibility
// category of the view) are created at run time with the Objective-C runtime,
// their methods are `callconv(.c)` functions registered with class_addMethod,
// and every message is an objc_msgSend call typed with the exact (non-variadic)
// signature of the method (PORTING.md section 5.1). `[super m]` is
// objc_msgSendSuper2. Blocks and fast enumeration are not used by this file.
//
// Exports: the C file defines `rvn_platform_cocoa` only; it is `export`ed by the
// comptime block at the end of the file, and only when the target is macOS.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const libc = @import("../../sys/libc.zig");
const ext = @import("../externs.zig");
const platform = @import("../platform_h.zig");

// ---------------------------------------------------------------------------
//  Objective-C runtime and Cocoa types
// ---------------------------------------------------------------------------
const id = ?*anyopaque;
const SEL = ?*anyopaque;
const Class = ?*anyopaque;
const CGFloat = f64;
const NSInteger = isize;
const NSUInteger = usize;
const NIL: id = null;

const NSPoint = extern struct { x: CGFloat, y: CGFloat };
const NSSize = extern struct { width: CGFloat, height: CGFloat };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

const NSZeroPoint = NSPoint{ .x = 0, .y = 0 };
const NSZeroRect = NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };

fn NSMakeRect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) NSRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn NSMakePoint(x: CGFloat, y: CGFloat) NSPoint {
    return .{ .x = x, .y = y };
}

const ObjcSuper = extern struct {
    receiver: id,
    super_class: Class,
};

extern "c" fn objc_msgSend() void; // never called as declared: send() casts it
extern "c" fn objc_msgSendSuper2() void; // never called as declared: sendSuper() casts it
extern "c" fn objc_getClass(name: [*:0]const u8) Class;
extern "c" fn sel_registerName(name: [*:0]const u8) SEL;
extern "c" fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
extern "c" fn objc_registerClassPair(cls: Class) void;
extern "c" fn class_addMethod(cls: Class, name: SEL, imp: *const anyopaque, types: [*:0]const u8) bool;
extern "c" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) bool;
extern "c" fn class_addProtocol(cls: Class, protocol: ?*anyopaque) bool;
extern "c" fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) ?*anyopaque;
extern "c" fn ivar_getOffset(ivar: ?*anyopaque) isize;
extern "c" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;

// AppKit, Foundation, QuartzCore and Metal
extern "c" fn NSAccessibilityPostNotification(element: id, notification: id) void;
extern "c" fn NSAccessibilityPostNotificationWithUserInfo(element: id, notification: id, user_info: id) void;
extern "c" fn NSAccessibilityRoleDescription(role: id, subrole: id) id;
extern "c" fn MTLCreateSystemDefaultDevice() id;
extern "c" fn lrint(x: f64) c_long;

extern "c" var NSApp: id;
extern "c" var NSDefaultRunLoopMode: id;
extern "c" var NSPasteboardTypeFileURL: id;
extern "c" var NSPasteboardTypeString: id;
extern "c" var NSPasteboardURLReadingFileURLsOnlyKey: id;
extern "c" var NSAccessibilityAnnouncementKey: id;
extern "c" var NSAccessibilityPriorityKey: id;
extern "c" var NSAccessibilityAnnouncementRequestedNotification: id;
extern "c" var NSAccessibilityFocusedUIElementChangedNotification: id;
extern "c" var NSAccessibilityValueChangedNotification: id;
extern "c" var NSAccessibilityTitleChangedNotification: id;
extern "c" var NSAccessibilityLayoutChangedNotification: id;
extern "c" var NSAccessibilityWindowRole: id;
extern "c" var NSAccessibilityStaticTextRole: id;
extern "c" var NSAccessibilityLinkRole: id;
extern "c" var NSAccessibilityButtonRole: id;
extern "c" var NSAccessibilityCheckBoxRole: id;
extern "c" var NSAccessibilityRadioButtonRole: id;
extern "c" var NSAccessibilitySliderRole: id;
extern "c" var NSAccessibilityProgressIndicatorRole: id;
extern "c" var NSAccessibilityIncrementorRole: id;
extern "c" var NSAccessibilityTextFieldRole: id;
extern "c" var NSAccessibilityTextAreaRole: id;
extern "c" var NSAccessibilityPopUpButtonRole: id;
extern "c" var NSAccessibilityListRole: id;
extern "c" var NSAccessibilityOutlineRole: id;
extern "c" var NSAccessibilityRowRole: id;
extern "c" var NSAccessibilityTableRole: id;
extern "c" var NSAccessibilityMenuBarRole: id;
extern "c" var NSAccessibilityMenuRole: id;
extern "c" var NSAccessibilityMenuItemRole: id;
extern "c" var NSAccessibilityTabGroupRole: id;
extern "c" var NSAccessibilityToolbarRole: id;
extern "c" var NSAccessibilityImageRole: id;
extern "c" var NSAccessibilitySplitterRole: id;
extern "c" var NSAccessibilityScrollBarRole: id;
extern "c" var NSAccessibilitySheetRole: id;
extern "c" var NSAccessibilityGroupRole: id;
extern "c" var NSAccessibilityUnknownRole: id;

// Values of the AppKit / Metal headers (macOS SDK 26): NSTrackingArea options, NSWindowStyleMask,
// NSBackingStoreBuffered, NSApplicationActivationPolicyRegular, NSEventModifierFlag*, NSEventType*,
// NSDragOperation*, NSUTF8StringEncoding, NSAccessibilityPriority*, MTLPixelFormatBGRA8Unorm.
const NSTrackingMouseEnteredAndExited: NSUInteger = 0x01;
const NSTrackingMouseMoved: NSUInteger = 0x02;
const NSTrackingActiveAlways: NSUInteger = 0x80;
const NSWindowStyleMaskBorderless: NSUInteger = 0;
const NSWindowStyleMaskTitled: NSUInteger = 1 << 0;
const NSWindowStyleMaskClosable: NSUInteger = 1 << 1;
const NSWindowStyleMaskMiniaturizable: NSUInteger = 1 << 2;
const NSWindowStyleMaskResizable: NSUInteger = 1 << 3;
const NSBackingStoreBuffered: NSUInteger = 2;
const NSApplicationActivationPolicyRegular: NSInteger = 0;
const NSEventModifierFlagShift: NSUInteger = 1 << 17;
const NSEventModifierFlagControl: NSUInteger = 1 << 18;
const NSEventModifierFlagOption: NSUInteger = 1 << 19;
const NSEventModifierFlagCommand: NSUInteger = 1 << 20;
const NSEventTypeLeftMouseDown: NSUInteger = 1;
const NSEventTypeApplicationDefined: NSUInteger = 15;
const NSEventMaskAny: NSUInteger = std.math.maxInt(NSUInteger);
const NSDragOperationNone: NSUInteger = 0;
const NSDragOperationCopy: NSUInteger = 1;
const NSUTF8StringEncoding: NSUInteger = 4;
const NSAccessibilityPriorityMedium: NSInteger = 50;
const NSAccessibilityPriorityHigh: NSInteger = 90;
const MTLPixelFormatBGRA8Unorm: NSUInteger = 80;

/// [target selector] / [target selector:args...] with the C signature (id, SEL, args...) -> R (up to 4 arguments).
/// The method is looked up at each call (objc_msgSend), so the type of the arguments is the C type of the method.
fn send(comptime R: type, target: id, sel: [*:0]const u8, args: anytype) R {
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const Fn = switch (fields.len) {
        0 => *const fn (id, SEL) callconv(.c) R,
        1 => *const fn (id, SEL, fields[0]) callconv(.c) R,
        2 => *const fn (id, SEL, fields[0], fields[1]) callconv(.c) R,
        3 => *const fn (id, SEL, fields[0], fields[1], fields[2]) callconv(.c) R,
        4 => *const fn (id, SEL, fields[0], fields[1], fields[2], fields[3]) callconv(.c) R,
        else => @compileError("send: add an arm for more arguments"),
    };
    const f: Fn = @ptrCast(&objc_msgSend);
    return @call(.auto, f, .{ target, sel_registerName(sel) } ++ args);
}

/// [super sel:args...] inside a method of class `cls` (objc_msgSendSuper2 starts the lookup above `cls`).
fn sendSuper(comptime R: type, self: id, class_: Class, sel: [*:0]const u8, args: anytype) R {
    const fields = @typeInfo(@TypeOf(args)).@"struct".field_types;
    const Fn = switch (fields.len) {
        0 => *const fn (*const ObjcSuper, SEL) callconv(.c) R,
        1 => *const fn (*const ObjcSuper, SEL, fields[0]) callconv(.c) R,
        2 => *const fn (*const ObjcSuper, SEL, fields[0], fields[1]) callconv(.c) R,
        else => @compileError("sendSuper: add an arm for more arguments"),
    };
    const sup = ObjcSuper{ .receiver = self, .super_class = class_ };
    const f: Fn = @ptrCast(&objc_msgSendSuper2);
    return @call(.auto, f, .{ &sup, sel_registerName(sel) } ++ args);
}

fn cls(name: [*:0]const u8) id {
    return objc_getClass(name);
}

fn nsString(text: [*:0]const u8) id {
    return send(id, cls("NSString"), "stringWithUTF8String:", .{text});
}

/// rvn_cocoa_string: the NSString of a C string, "" for NULL
fn rvn_cocoa_string(text: [*c]const u8) id {
    const string: id = if (text != null) send(id, cls("NSString"), "stringWithUTF8String:", .{text}) else NIL;
    return if (string != null) string else nsString("");
}

/// Adds a method to a class under construction. `comptime imp` is the C function that implements it.
fn addMethod(class: Class, comptime name: [*:0]const u8, comptime imp: anytype, comptime types: [*:0]const u8) void {
    _ = class_addMethod(class, sel_registerName(name), @ptrCast(&imp), types);
}

// ---------------------------------------------------------------------------
//  The window of the C file (struct rvn_pwindow_t of cocoa_platform.m)
// ---------------------------------------------------------------------------
const Window = extern struct {
    handle: id, // NSWindow*
    view: id, // NSView*
    delegate: id,
    user: ?*anyopaque,
    flags: u32,
    is_child: c_int,
    transparent: c_int,
    min_width: c_int,
    min_height: c_int,
    state: platform.rvn_pwindow_state_t,
    cursor: id, // NSCursor*
};

/// The window behind an opaque platform window (never NULL where the C file dereferences it)
fn win(window: ?*platform.rvn_pwindow_t) *Window {
    return @ptrCast(@alignCast(window.?));
}

fn optWin(window: ?*platform.rvn_pwindow_t) ?*Window {
    return @ptrCast(@alignCast(window));
}

/// Reads or writes an instance variable of an Objective-C object at a byte offset.
fn ivarPtr(comptime T: type, obj: id, offset: isize) *T {
    const bytes: [*]u8 = @ptrCast(obj.?);
    return @ptrCast(@alignCast(bytes + @as(usize, @intCast(offset))));
}

// static struct { ... } g_cocoa;
const CocoaState = struct {
    handler: platform.rvn_pevent_handler_t,
    regions: platform.rvn_pregion_handler_t,
    pool: id, // NSAutoreleasePool*
    initialized: c_int,
    resize_window: ?*Window,
    resize_region: platform.rvn_pregion_t,
    resize_start: NSPoint,
    resize_frame: NSRect,
};

var g_cocoa: CocoaState = std.mem.zeroes(CocoaState);

// The class and the ivars of the three classes, made by createClasses()
var g_view_class: Class = null;
var g_delegate_class: Class = null;
var g_element_class: Class = null;
var g_view_window_offset: isize = 0;
var g_view_tracking_offset: isize = 0;
var g_delegate_window_offset: isize = 0;
var g_element_node_offset: isize = 0;
var g_element_window_offset: isize = 0;
var g_classes_ready: bool = false;

/// static NSMutableDictionary* g_cocoa_elements;
var g_cocoa_elements: id = null;

fn viewWindow(self: id) ?*Window {
    return ivarPtr(?*Window, self, g_view_window_offset).*;
}

fn delegateWindow(self: id) ?*Window {
    return ivarPtr(?*Window, self, g_delegate_window_offset).*;
}

fn elementNode(self: id) u64 {
    return ivarPtr(u64, self, g_element_node_offset).*;
}

fn elementWindow(self: id) ?*Window {
    return ivarPtr(?*Window, self, g_element_window_offset).*;
}

// ---------------------------------------------------------------------------
//  Scale, events, modifiers and keys
// ---------------------------------------------------------------------------

fn rvn_cocoa_scale(window: ?*Window) f32 {
    const screen: id = if (window != null and window.?.handle != null)
        send(id, window.?.handle, "screen", .{})
    else
        send(id, cls("NSScreen"), "mainScreen", .{});
    const scale: CGFloat = if (screen != null) send(CGFloat, screen, "backingScaleFactor", .{}) else 1.0;
    return if (scale > 0.0) @floatCast(scale) else 1.0;
}

/// (int)lrint(x) of the C file
fn lrintInt(x: f64) c_int {
    return @truncate(lrint(x));
}

fn rvn_cocoa_emit(window: ?*Window, event: *platform.rvn_pevent_t) void {
    const w = window orelse return;
    const handler = g_cocoa.handler orelse return;
    event.user = w.user;
    if (event.scale == 0.0) event.scale = rvn_cocoa_scale(w);
    handler(event);
}

fn rvn_cocoa_modifiers(flags: NSUInteger) u32 {
    var result: u32 = 0;
    if ((flags & NSEventModifierFlagShift) != 0) result |= @as(u32, @intCast(raven.R_MOD_SHIFT));
    if ((flags & NSEventModifierFlagControl) != 0) result |= @as(u32, @intCast(raven.R_MOD_CTRL));
    if ((flags & NSEventModifierFlagOption) != 0) result |= @as(u32, @intCast(raven.R_MOD_ALT));
    if ((flags & NSEventModifierFlagCommand) != 0) result |= @as(u32, @intCast(raven.R_MOD_SUPER));
    return result;
}

fn rvn_cocoa_key(code: c_ushort, characters: id) raven.RKey {
    switch (code) {
        36, 76 => return raven.R_KEY_ENTER,
        48 => return raven.R_KEY_TAB,
        51 => return raven.R_KEY_BACKSPACE,
        117 => return raven.R_KEY_DELETE,
        53 => return raven.R_KEY_ESCAPE,
        114 => return raven.R_KEY_INSERT,
        115 => return raven.R_KEY_HOME,
        119 => return raven.R_KEY_END,
        116 => return raven.R_KEY_PAGE_UP,
        121 => return raven.R_KEY_PAGE_DOWN,
        123 => return raven.R_KEY_LEFT,
        124 => return raven.R_KEY_RIGHT,
        125 => return raven.R_KEY_DOWN,
        126 => return raven.R_KEY_UP,
        57 => return raven.R_KEY_CAPS_LOCK,
        105 => return raven.R_KEY_F1, // non-US keyboard fallback; corrected by characters below when printable
        122 => return raven.R_KEY_F1,
        120 => return raven.R_KEY_F2,
        99 => return raven.R_KEY_F3,
        118 => return raven.R_KEY_F4,
        96 => return raven.R_KEY_F5,
        97 => return raven.R_KEY_F6,
        98 => return raven.R_KEY_F7,
        100 => return raven.R_KEY_F8,
        101 => return raven.R_KEY_F9,
        109 => return raven.R_KEY_F10,
        103 => return raven.R_KEY_F11,
        111 => return raven.R_KEY_F12,
        56 => return raven.R_KEY_LEFT_SHIFT,
        60 => return raven.R_KEY_RIGHT_SHIFT,
        59 => return raven.R_KEY_LEFT_CTRL,
        62 => return raven.R_KEY_RIGHT_CTRL,
        58 => return raven.R_KEY_LEFT_ALT,
        61 => return raven.R_KEY_RIGHT_ALT,
        55 => return raven.R_KEY_LEFT_SUPER,
        54 => return raven.R_KEY_RIGHT_SUPER,
        49 => return raven.R_KEY_SPACE,
        0 => return raven.R_KEY_A,
        1 => return raven.R_KEY_S,
        2 => return raven.R_KEY_D,
        3 => return raven.R_KEY_F,
        4 => return raven.R_KEY_H,
        5 => return raven.R_KEY_G,
        6 => return raven.R_KEY_Z,
        7 => return raven.R_KEY_X,
        8 => return raven.R_KEY_C,
        9 => return raven.R_KEY_V,
        11 => return raven.R_KEY_B,
        12 => return raven.R_KEY_Q,
        13 => return raven.R_KEY_W,
        14 => return raven.R_KEY_E,
        15 => return raven.R_KEY_R,
        16 => return raven.R_KEY_Y,
        17 => return raven.R_KEY_T,
        31 => return raven.R_KEY_O,
        32 => return raven.R_KEY_U,
        34 => return raven.R_KEY_I,
        35 => return raven.R_KEY_P,
        37 => return raven.R_KEY_L,
        38 => return raven.R_KEY_J,
        40 => return raven.R_KEY_K,
        45 => return raven.R_KEY_N,
        46 => return raven.R_KEY_M,
        18 => return raven.R_KEY_1,
        19 => return raven.R_KEY_2,
        20 => return raven.R_KEY_3,
        21 => return raven.R_KEY_4,
        23 => return raven.R_KEY_5,
        22 => return raven.R_KEY_6,
        26 => return raven.R_KEY_7,
        28 => return raven.R_KEY_8,
        25 => return raven.R_KEY_9,
        29 => return raven.R_KEY_0,
        27 => return raven.R_KEY_MINUS,
        24 => return raven.R_KEY_EQUAL,
        33 => return raven.R_KEY_LEFT_BRACKET,
        30 => return raven.R_KEY_RIGHT_BRACKET,
        42 => return raven.R_KEY_BACKSLASH,
        41 => return raven.R_KEY_SEMICOLON,
        39 => return raven.R_KEY_APOSTROPHE,
        43 => return raven.R_KEY_COMMA,
        47 => return raven.R_KEY_PERIOD,
        44 => return raven.R_KEY_SLASH,
        50 => return raven.R_KEY_GRAVE,
        else => {},
    }
    if (send(NSUInteger, characters, "length", .{}) != 0) {
        const upper = send(id, characters, "uppercaseString", .{});
        const ch: u16 = send(u16, upper, "characterAtIndex:", .{@as(NSUInteger, 0)});
        if (ch >= 'A' and ch <= 'Z') return @as(raven.RKey, ch);
        if (ch >= '0' and ch <= '9') return @as(raven.RKey, ch);
    }
    return raven.R_KEY_UNKNOWN;
}

fn rvn_cocoa_emit_text(window: ?*Window, value: id, modifiers: u32) void {
    if (value == null or send(NSUInteger, value, "length", .{}) == 0 or (modifiers & @as(u32, @intCast(raven.R_MOD_CTRL | raven.R_MOD_ALT | raven.R_MOD_SUPER))) != 0) return;
    const n = send(NSUInteger, value, "length", .{});
    var i: NSUInteger = 0;
    while (i < n) : (i += 1) {
        var codepoint: u32 = send(u16, value, "characterAtIndex:", .{i});
        if (codepoint >= 0xD800 and codepoint <= 0xDBFF and i + 1 < n) {
            const low: u32 = send(u16, value, "characterAtIndex:", .{i + 1});
            if (low >= 0xDC00 and low <= 0xDFFF) {
                codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
                i += 1;
            }
        }
        var event = std.mem.zeroes(platform.rvn_pevent_t);
        event.type = platform.RVN_PEVENT_TEXT;
        event.codepoint = codepoint;
        event.modifiers = modifiers;
        rvn_cocoa_emit(window, &event);
    }
}

fn rvn_cocoa_resize_drag(window: ?*Window) void {
    const w = window orelse return;
    if (g_cocoa.resize_window != w) return;
    const point = send(NSPoint, cls("NSEvent"), "mouseLocation", .{});
    const dx = point.x - g_cocoa.resize_start.x;
    const dy = point.y - g_cocoa.resize_start.y;
    var frame = g_cocoa.resize_frame;
    const edge = g_cocoa.resize_region;
    const left = edge == platform.RVN_PREGION_LEFT or edge == platform.RVN_PREGION_TOP_LEFT or edge == platform.RVN_PREGION_BOTTOM_LEFT;
    const right = edge == platform.RVN_PREGION_RIGHT or edge == platform.RVN_PREGION_TOP_RIGHT or edge == platform.RVN_PREGION_BOTTOM_RIGHT;
    const top = edge == platform.RVN_PREGION_TOP or edge == platform.RVN_PREGION_TOP_LEFT or edge == platform.RVN_PREGION_TOP_RIGHT;
    const bottom = edge == platform.RVN_PREGION_BOTTOM or edge == platform.RVN_PREGION_BOTTOM_LEFT or edge == platform.RVN_PREGION_BOTTOM_RIGHT;
    const scale: CGFloat = rvn_cocoa_scale(w);
    const min_w: CGFloat = if (w.min_width > 0) @as(CGFloat, @floatFromInt(w.min_width)) / scale else 64;
    const min_h: CGFloat = if (w.min_height > 0) @as(CGFloat, @floatFromInt(w.min_height)) / scale else 48;
    if (left) {
        const nw = @max(min_w, g_cocoa.resize_frame.size.width - dx);
        frame.origin.x += g_cocoa.resize_frame.size.width - nw;
        frame.size.width = nw;
    }
    if (right) frame.size.width = @max(min_w, g_cocoa.resize_frame.size.width + dx);
    if (top) frame.size.height = @max(min_h, g_cocoa.resize_frame.size.height + dy);
    if (bottom) {
        const nh = @max(min_h, g_cocoa.resize_frame.size.height - dy);
        frame.origin.y += g_cocoa.resize_frame.size.height - nh;
        frame.size.height = nh;
    }
    send(void, w.handle, "setFrame:display:", .{ frame, true });
}

// ---------------------------------------------------------------------------
//  RavenCocoaView (an NSView: flipped, Metal layer, mouse, keys, dragging)
// ---------------------------------------------------------------------------

fn viewIsFlipped(self: id, _cmd: SEL) callconv(.c) bool {
    _ = self;
    _ = _cmd;
    return true;
}

fn viewUpdateTrackingAreas(self: id, _cmd: SEL) callconv(.c) void {
    _ = _cmd;
    const tracking = ivarPtr(id, self, g_view_tracking_offset);
    if (tracking.* != null) {
        send(void, self, "removeTrackingArea:", .{tracking.*});
        send(void, tracking.*, "release", .{});
        tracking.* = NIL;
    }
    const area_alloc = send(id, cls("NSTrackingArea"), "alloc", .{});
    tracking.* = send(id, area_alloc, "initWithRect:options:owner:userInfo:", .{
        send(NSRect, self, "bounds", .{}),
        NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways,
        self,
        NIL,
    });
    send(void, self, "addTrackingArea:", .{tracking.*});
    sendSuper(void, self, g_view_class, "updateTrackingAreas", .{});
}

fn viewDealloc(self: id, _cmd: SEL) callconv(.c) void {
    _ = _cmd;
    const tracking = ivarPtr(id, self, g_view_tracking_offset);
    if (tracking.* != null) send(void, tracking.*, "release", .{});
    sendSuper(void, self, g_view_class, "dealloc", .{});
}

fn viewAcceptsFirstResponder(self: id, _cmd: SEL) callconv(.c) bool {
    _ = self;
    _ = _cmd;
    return true;
}

fn viewWantsUpdateLayer(self: id, _cmd: SEL) callconv(.c) bool {
    _ = self;
    _ = _cmd;
    return true;
}

fn viewDrawRect(self: id, _cmd: SEL, dirty_rect: NSRect) callconv(.c) void {
    _ = _cmd;
    _ = dirty_rect; // (void)dirtyRect;
    var event = std.mem.zeroes(platform.rvn_pevent_t);
    event.type = platform.RVN_PEVENT_EXPOSE;
    rvn_cocoa_emit(viewWindow(self), &event);
}

fn viewUpdateLayer(self: id, _cmd: SEL) callconv(.c) void {
    _ = _cmd;
    var event = std.mem.zeroes(platform.rvn_pevent_t);
    event.type = platform.RVN_PEVENT_EXPOSE;
    rvn_cocoa_emit(viewWindow(self), &event);
}

fn viewMouseMoved(self: id, _cmd: SEL, event_in: id) callconv(.c) void {
    _ = _cmd;
    const p = send(NSPoint, self, "convertPoint:fromView:", .{ send(NSPoint, event_in, "locationInWindow", .{}), NIL });
    const rw = viewWindow(self);
    const s: f64 = rvn_cocoa_scale(rw);
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_MOUSE_MOVE;
    e.x = lrintInt(p.x * s);
    e.y = lrintInt(p.y * s);
    e.modifiers = rvn_cocoa_modifiers(send(NSUInteger, event_in, "modifierFlags", .{}));
    rvn_cocoa_emit(rw, &e);
}

fn viewMouseDragged(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    rvn_cocoa_resize_drag(viewWindow(self));
    send(void, self, "mouseMoved:", .{event});
}

fn viewRightMouseDragged(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    rvn_cocoa_resize_drag(viewWindow(self));
    send(void, self, "mouseMoved:", .{event});
}

fn viewOtherMouseDragged(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    rvn_cocoa_resize_drag(viewWindow(self));
    send(void, self, "mouseMoved:", .{event});
}

fn viewMouseEntered(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = event;
}

fn viewMouseExited(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    _ = event;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_MOUSE_LEAVE;
    rvn_cocoa_emit(viewWindow(self), &e);
}

fn viewRvnMouse(self: id, _cmd: SEL, event: id, button: c_int, pressed: c_int) callconv(.c) void {
    _ = _cmd;
    const p = send(NSPoint, self, "convertPoint:fromView:", .{ send(NSPoint, event, "locationInWindow", .{}), NIL });
    const rw = viewWindow(self);
    const s: f64 = rvn_cocoa_scale(rw);
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_MOUSE_BUTTON;
    e.button = button;
    e.pressed = pressed;
    e.x = lrintInt(p.x * s);
    e.y = lrintInt(p.y * s);
    e.modifiers = rvn_cocoa_modifiers(send(NSUInteger, event, "modifierFlags", .{}));
    rvn_cocoa_emit(rw, &e);
}

fn viewMouseDown(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    send(void, self, "rvnMouse:button:pressed:", .{ event, @as(c_int, 0), @as(c_int, 1) });
}

fn viewMouseUp(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    send(void, self, "rvnMouse:button:pressed:", .{ event, @as(c_int, 0), @as(c_int, 0) });
    const rw = viewWindow(self);
    if (g_cocoa.resize_window == rw) g_cocoa.resize_window = null;
}

fn viewRightMouseDown(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    send(void, self, "rvnMouse:button:pressed:", .{ event, @as(c_int, 1), @as(c_int, 1) });
}

fn viewRightMouseUp(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    send(void, self, "rvnMouse:button:pressed:", .{ event, @as(c_int, 1), @as(c_int, 0) });
    const rw = viewWindow(self);
    if (g_cocoa.resize_window == rw) g_cocoa.resize_window = null;
}

fn viewOtherMouseDown(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    const button: c_int = @truncate(send(NSInteger, event, "buttonNumber", .{}));
    send(void, self, "rvnMouse:button:pressed:", .{ event, button, @as(c_int, 1) });
}

fn viewOtherMouseUp(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    const button: c_int = @truncate(send(NSInteger, event, "buttonNumber", .{}));
    send(void, self, "rvnMouse:button:pressed:", .{ event, button, @as(c_int, 0) });
    const rw = viewWindow(self);
    if (g_cocoa.resize_window == rw) g_cocoa.resize_window = null;
}

fn viewScrollWheel(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_MOUSE_WHEEL;
    e.wheel_x = @floatCast(send(CGFloat, event, "scrollingDeltaX", .{}));
    e.wheel_y = @floatCast(send(CGFloat, event, "scrollingDeltaY", .{}));
    if (!send(bool, event, "hasPreciseScrollingDeltas", .{})) {
        e.wheel_x *= 10.0;
        e.wheel_y *= 10.0;
    }
    e.modifiers = rvn_cocoa_modifiers(send(NSUInteger, event, "modifierFlags", .{}));
    rvn_cocoa_emit(viewWindow(self), &e);
}

fn viewKeyDown(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    const mods = rvn_cocoa_modifiers(send(NSUInteger, event, "modifierFlags", .{}));
    const rw = viewWindow(self);
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_KEY;
    e.key = rvn_cocoa_key(send(c_ushort, event, "keyCode", .{}), send(id, event, "charactersIgnoringModifiers", .{}));
    e.pressed = 1;
    e.repeat = @intFromBool(send(bool, event, "isARepeat", .{}));
    e.modifiers = mods;
    rvn_cocoa_emit(rw, &e);
    if (e.repeat == 0) rvn_cocoa_emit_text(rw, send(id, event, "characters", .{}), mods);
}

fn viewKeyUp(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_KEY;
    e.key = rvn_cocoa_key(send(c_ushort, event, "keyCode", .{}), send(id, event, "charactersIgnoringModifiers", .{}));
    e.pressed = 0;
    e.modifiers = rvn_cocoa_modifiers(send(NSUInteger, event, "modifierFlags", .{}));
    rvn_cocoa_emit(viewWindow(self), &e);
}

fn viewFlagsChanged(self: id, _cmd: SEL, event: id) callconv(.c) void {
    _ = _cmd;
    const key = rvn_cocoa_key(send(c_ushort, event, "keyCode", .{}), send(id, event, "charactersIgnoringModifiers", .{}));
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_KEY;
    e.key = key;
    e.modifiers = rvn_cocoa_modifiers(send(NSUInteger, event, "modifierFlags", .{}));
    const shift = (e.modifiers & @as(u32, @intCast(raven.R_MOD_SHIFT))) != 0;
    const ctrl = (e.modifiers & @as(u32, @intCast(raven.R_MOD_CTRL))) != 0;
    const alt = (e.modifiers & @as(u32, @intCast(raven.R_MOD_ALT))) != 0;
    const super = (e.modifiers & @as(u32, @intCast(raven.R_MOD_SUPER))) != 0;
    e.pressed = if (key == raven.R_KEY_LEFT_SHIFT or key == raven.R_KEY_RIGHT_SHIFT)
        @intFromBool(shift)
    else if (key == raven.R_KEY_LEFT_CTRL or key == raven.R_KEY_RIGHT_CTRL)
        @intFromBool(ctrl)
    else if (key == raven.R_KEY_LEFT_ALT or key == raven.R_KEY_RIGHT_ALT)
        @intFromBool(alt)
    else
        @intFromBool(super);
    rvn_cocoa_emit(viewWindow(self), &e);
}

fn viewRvnDrag(self: id, _cmd: SEL, sender: id, leaving: c_int) callconv(.c) NSUInteger {
    _ = _cmd;
    const p = send(NSPoint, self, "convertPoint:fromView:", .{ send(NSPoint, sender, "draggingLocation", .{}), NIL });
    const rw = viewWindow(self);
    const scale: f64 = rvn_cocoa_scale(rw);
    var accepted: c_int = raven.R_FALSE;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_DRAG;
    e.x = lrintInt(p.x * scale);
    e.y = lrintInt(p.y * scale);
    e.leaving = leaving;
    e.accepted = &accepted;
    rvn_cocoa_emit(rw, &e);
    return if (accepted != 0) NSDragOperationCopy else NSDragOperationNone;
}

fn viewDraggingEntered(self: id, _cmd: SEL, sender: id) callconv(.c) NSUInteger {
    _ = _cmd;
    return send(NSUInteger, self, "rvnDrag:leaving:", .{ sender, @as(c_int, 0) });
}

fn viewDraggingUpdated(self: id, _cmd: SEL, sender: id) callconv(.c) NSUInteger {
    _ = _cmd;
    return send(NSUInteger, self, "rvnDrag:leaving:", .{ sender, @as(c_int, 0) });
}

fn viewDraggingExited(self: id, _cmd: SEL, sender: id) callconv(.c) void {
    _ = _cmd;
    _ = send(NSUInteger, self, "rvnDrag:leaving:", .{ sender, @as(c_int, 1) });
}

fn viewPrepareForDragOperation(self: id, _cmd: SEL, sender: id) callconv(.c) bool {
    _ = self;
    _ = _cmd;
    _ = sender;
    return true;
}

fn viewPerformDragOperation(self: id, _cmd: SEL, sender: id) callconv(.c) bool {
    _ = _cmd;
    const board = send(id, sender, "draggingPasteboard", .{});
    const url_classes = send(id, cls("NSArray"), "arrayWithObject:", .{objc_getClass("NSURL")});
    const url_options = send(id, cls("NSDictionary"), "dictionaryWithObject:forKey:", .{ send(id, cls("NSNumber"), "numberWithBool:", .{true}), NSPasteboardURLReadingFileURLsOnlyKey });
    const urls = send(id, board, "readObjectsForClasses:options:", .{ url_classes, url_options });
    if (urls != null and send(NSUInteger, urls, "count", .{}) != 0) {
        const n = send(NSUInteger, urls, "count", .{});
        const paths: [*c][*c]const u8 = @ptrCast(@alignCast(libc.calloc(n, @sizeOf(?*anyopaque)).?));
        const strings = send(id, cls("NSMutableArray"), "arrayWithCapacity:", .{n});
        var i: NSUInteger = 0;
        while (i < n) : (i += 1) {
            const s = send(id, send(id, urls, "objectAtIndex:", .{i}), "path", .{});
            if (s != null) {
                const utf8 = send(id, s, "dataUsingEncoding:", .{NSUTF8StringEncoding});
                const alloc_string = send(id, cls("NSString"), "alloc", .{});
                const stable = send(id, send(id, alloc_string, "initWithData:encoding:", .{ utf8, NSUTF8StringEncoding }), "autorelease", .{});
                send(void, strings, "addObject:", .{if (stable != null) stable else nsString("")});
                paths[i] = send([*c]const u8, send(id, strings, "objectAtIndex:", .{i}), "UTF8String", .{});
            }
        }
        var e = std.mem.zeroes(platform.rvn_pevent_t);
        e.type = platform.RVN_PEVENT_DROP;
        e.drop_paths = paths;
        e.drop_count = @as(c_int, @intCast(n));
        rvn_cocoa_emit(viewWindow(self), &e);
        libc.free(@ptrCast(paths));
        return true;
    }
    const text = send(id, board, "stringForType:", .{NSPasteboardTypeString});
    if (text != null) {
        var e = std.mem.zeroes(platform.rvn_pevent_t);
        e.type = platform.RVN_PEVENT_DROP;
        e.drop_text = send([*c]const u8, text, "UTF8String", .{});
        rvn_cocoa_emit(viewWindow(self), &e);
        return true;
    }
    return false;
}

// ---- RavenCocoaView (RavenAccessibility): the category of the view ----

/// The window node of a view, or R_INVALID_ID when there is no window
fn viewRid(self: id) raven.Rid {
    const rw = viewWindow(self) orelse return raven.R_INVALID_ID;
    return ext.rvn_a11y_window_of(rw.user);
}

fn viewIsAccessibilityElement(self: id, _cmd: SEL) callconv(.c) bool {
    _ = self;
    _ = _cmd;
    return true;
}

fn viewAccessibilityRole(self: id, _cmd: SEL) callconv(.c) id {
    _ = self;
    _ = _cmd;
    return NSAccessibilityGroupRole;
}

fn viewAccessibilityLabel(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    const window = viewRid(self);
    if (window != 0 and ext.rvn_a11y_describe(@as(ext.rvn_a11y_id_t, window), &node) != 0) return rvn_cocoa_string(node.name);
    return nsString("");
}

fn viewAccessibilityChildren(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    const window = viewRid(self);
    if (window == 0) return send(id, cls("NSArray"), "array", .{});
    return rvn_cocoa_a11y_children(viewWindow(self), @as(ext.rvn_a11y_id_t, window));
}

fn viewAccessibilityHitTest(self: id, _cmd: SEL, point: NSPoint) callconv(.c) id {
    _ = _cmd;
    const window = viewRid(self);
    const rw = viewWindow(self);
    const on_screen = NSMakeRect(point.x, point.y, 0.0, 0.0);
    if (window == 0 or rw == null or rw.?.handle == null) return self;
    const screen_origin = send(NSRect, rw.?.handle, "convertRectFromScreen:", .{on_screen}).origin;
    const in_view = send(NSPoint, self, "convertPoint:fromView:", .{ screen_origin, NIL });
    const hit = rvn_cocoa_a11y_object(rw, ext.rvn_a11y_hit(window, @floatCast(in_view.x), @floatCast(in_view.y)));
    return if (hit != null) hit else self;
}

fn viewAccessibilityFocusedUIElement(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    const window = viewRid(self);
    const focus: id = if (window != 0) rvn_cocoa_a11y_object(viewWindow(self), ext.rvn_a11y_focus(window)) else NIL;
    return if (focus != null) focus else self;
}

// ---------------------------------------------------------------------------
//  RavenCocoaDelegate (an NSObject: the NSWindowDelegate of a window)
// ---------------------------------------------------------------------------

fn delegateWindowShouldClose(self: id, _cmd: SEL, sender: id) callconv(.c) bool {
    _ = _cmd;
    _ = sender;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_CLOSE;
    rvn_cocoa_emit(delegateWindow(self), &e);
    return false;
}

fn delegateWindowDidChangeBackingProperties(self: id, _cmd: SEL, notification: id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    const rw = delegateWindow(self) orelse return;
    if (rw.is_child != 0) return;
    const scale: f32 = rvn_cocoa_scale(rw);
    const layer = send(id, rw.view, "layer", .{});
    send(void, layer, "setContentsScale:", .{@as(CGFloat, scale)});
    send(void, rw.view, "setNeedsDisplay:", .{true});
    const bounds = send(NSRect, rw.view, "bounds", .{});
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_RESIZE;
    e.width = lrintInt(bounds.size.width * scale);
    e.height = lrintInt(bounds.size.height * scale);
    e.scale = scale;
    rvn_cocoa_emit(rw, &e);
}

fn delegateWindowDidResize(self: id, _cmd: SEL, notification: id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    const rw = delegateWindow(self) orelse return;
    if (rw.is_child != 0) return;
    const bounds = send(NSRect, rw.view, "bounds", .{});
    const s: f32 = rvn_cocoa_scale(rw);
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_RESIZE;
    e.width = lrintInt(bounds.size.width * @as(f64, s));
    e.height = lrintInt(bounds.size.height * @as(f64, s));
    e.scale = s;
    rvn_cocoa_emit(rw, &e);
}

fn delegateWindowDidBecomeKey(self: id, _cmd: SEL, notification: id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_FOCUS;
    e.focused = 1;
    rvn_cocoa_emit(delegateWindow(self), &e);
}

fn delegateWindowDidResignKey(self: id, _cmd: SEL, notification: id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_FOCUS;
    e.focused = 0;
    rvn_cocoa_emit(delegateWindow(self), &e);
}

fn delegateWindowDidMiniaturize(self: id, _cmd: SEL, notification: id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    const rw = delegateWindow(self).?;
    rw.state = platform.RVN_PWINDOW_MINIMIZED;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_STATE;
    e.state = rw.state;
    rvn_cocoa_emit(rw, &e);
}

fn delegateWindowDidDeminiaturize(self: id, _cmd: SEL, notification: id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    const rw = delegateWindow(self).?;
    rw.state = platform.RVN_PWINDOW_NORMAL;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_STATE;
    e.state = rw.state;
    rvn_cocoa_emit(rw, &e);
}

fn delegateWindowDidEndLiveResize(self: id, _cmd: SEL, notification: id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    var e = std.mem.zeroes(platform.rvn_pevent_t);
    e.type = platform.RVN_PEVENT_MODAL_TICK;
    rvn_cocoa_emit(delegateWindow(self), &e);
}

// ---------------------------------------------------------------------------
//  Platform: init, windows, input, clipboard
// ---------------------------------------------------------------------------

fn rvn_cocoa_init(handler: platform.rvn_pevent_handler_t, regions: platform.rvn_pregion_handler_t) callconv(.c) c_int {
    g_cocoa.handler = handler;
    g_cocoa.regions = regions;
    g_cocoa.pool = send(id, send(id, cls("NSAutoreleasePool"), "alloc", .{}), "init", .{});
    _ = send(id, cls("NSApplication"), "sharedApplication", .{});
    send(void, NSApp, "setActivationPolicy:", .{NSApplicationActivationPolicyRegular});
    send(void, NSApp, "finishLaunching", .{});
    send(void, NSApp, "activateIgnoringOtherApps:", .{true});
    g_cocoa.initialized = raven.R_TRUE;
    return raven.R_TRUE;
}

fn rvn_cocoa_shutdown() callconv(.c) void {
    g_cocoa.handler = null;
    g_cocoa.regions = null;
    g_cocoa.initialized = raven.R_FALSE;
    send(void, g_cocoa.pool, "drain", .{});
    g_cocoa.pool = NIL;
}

fn rvn_cocoa_native_display() callconv(.c) ?*anyopaque {
    return null;
}

fn rvn_cocoa_install_layer(view: id, scale: f32, transparent: c_int) void {
    send(void, view, "setWantsLayer:", .{true});
    const layer = send(id, cls("CAMetalLayer"), "layer", .{});
    send(void, layer, "setContentsScale:", .{@as(CGFloat, if (scale > 0.0) scale else 1.0)});
    send(void, layer, "setOpaque:", .{transparent == 0});
    send(void, layer, "setPixelFormat:", .{MTLPixelFormatBGRA8Unorm});
    const device = MTLCreateSystemDefaultDevice();
    if (device != null) send(void, layer, "setDevice:", .{device});
    send(void, view, "setLayer:", .{layer});
}

fn rvn_cocoa_window_create(desc: [*c]const platform.rvn_pwindow_desc_t) callconv(.c) ?*platform.rvn_pwindow_t {
    const window: *Window = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(Window))));
    // Window descriptions carry logical units (already multiplied by UI scale).
    // AppKit uses points here; the backing scale turns these into framebuffer pixels.
    const rect = NSMakeRect(100, 100, @floatFromInt(base.rvn_maxi(desc.*.width, 1)), @floatFromInt(base.rvn_maxi(desc.*.height, 1)));
    const flags: u32 = desc.*.flags;
    const no_resize = (flags & @as(u32, @intCast(raven.R_WINDOW_NO_RESIZE))) != 0;
    const borderless = (flags & @as(u32, @intCast(raven.R_WINDOW_BORDERLESS | raven.R_WINDOW_CUSTOM_HEADER))) != 0;
    var style: NSUInteger = undefined;
    if (borderless) {
        style = NSWindowStyleMaskBorderless | (if (no_resize) @as(NSUInteger, 0) else NSWindowStyleMaskResizable);
    } else {
        style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
        if (!no_resize) style |= NSWindowStyleMaskResizable;
    }
    window.flags = flags;
    window.user = desc.*.user;
    window.transparent = @intFromBool((flags & @as(u32, @intCast(raven.R_WINDOW_TRANSPARENT))) != 0);
    window.state = platform.RVN_PWINDOW_NORMAL;
    const window_alloc = send(id, cls("NSWindow"), "alloc", .{});
    window.handle = send(id, window_alloc, "initWithContentRect:styleMask:backing:defer:", .{ rect, style, NSBackingStoreBuffered, false });
    if (window.handle == null) {
        base.rvn_free(window);
        return null;
    }
    send(void, window.handle, "setReleasedWhenClosed:", .{false});
    const title: [*c]const u8 = if (desc.*.title != null) desc.*.title else "Raven";
    send(void, window.handle, "setTitle:", .{rvn_cocoa_string(title)});
    send(void, window.handle, "setAcceptsMouseMovedEvents:", .{true});
    send(void, window.handle, "setHasShadow:", .{true});
    send(void, window.handle, "setMovableByWindowBackground:", .{false});
    send(void, window.handle, "setOpaque:", .{window.transparent == 0});
    if (window.transparent != 0) send(void, window.handle, "setBackgroundColor:", .{send(id, cls("NSColor"), "clearColor", .{})});
    if (no_resize) send(void, window.handle, "setMinSize:", .{rect.size});
    const view_alloc = send(id, cls("RavenCocoaView"), "alloc", .{});
    window.view = send(id, view_alloc, "initWithFrame:", .{NSMakeRect(0, 0, rect.size.width, rect.size.height)});
    ivarPtr(?*Window, window.view, g_view_window_offset).* = window;
    rvn_cocoa_install_layer(window.view, rvn_cocoa_scale(window), window.transparent);
    send(void, window.view, "registerForDraggedTypes:", .{ndArray2(NSPasteboardTypeFileURL, NSPasteboardTypeString)});
    send(void, window.handle, "setContentView:", .{window.view});
    const delegate_alloc = send(id, cls("RavenCocoaDelegate"), "alloc", .{});
    window.delegate = send(id, delegate_alloc, "init", .{});
    ivarPtr(?*Window, window.delegate, g_delegate_window_offset).* = window;
    send(void, window.handle, "setDelegate:", .{window.delegate});
    if ((flags & @as(u32, @intCast(raven.R_WINDOW_HIDDEN))) == 0) send(void, window.handle, "makeKeyAndOrderFront:", .{NIL});
    if ((flags & @as(u32, @intCast(raven.R_WINDOW_MAXIMIZED))) != 0) send(void, window.handle, "zoom:", .{NIL});
    return @ptrCast(window);
}

/// @[a, b]: an NSArray of two objects
fn ndArray2(a: id, b: id) id {
    var objects = [_]id{ a, b };
    return send(id, cls("NSArray"), "arrayWithObjects:count:", .{ @as([*c]const id, &objects), @as(NSUInteger, 2) });
}

fn rvn_cocoa_window_destroy(window_opaque: ?*platform.rvn_pwindow_t) callconv(.c) void {
    const window = optWin(window_opaque) orelse return;
    rvn_cocoa_a11y_forget(window);
    if (window.handle != null) {
        send(void, window.handle, "setDelegate:", .{NIL});
        send(void, window.handle, "close", .{});
        send(void, window.handle, "release", .{});
    }
    if (window.delegate != null) send(void, window.delegate, "release", .{});
    if (window.view != null) {
        if (window.is_child != 0) send(void, window.view, "removeFromSuperview", .{});
        send(void, window.view, "release", .{});
    }
    base.rvn_free(window);
}

fn rvn_cocoa_window_set_title(window_opaque: ?*platform.rvn_pwindow_t, title: [*c]const u8) callconv(.c) void {
    const window = win(window_opaque);
    send(void, window.handle, "setTitle:", .{rvn_cocoa_string(title)});
}

fn rvn_cocoa_window_set_size(window_opaque: ?*platform.rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void {
    const window = win(window_opaque);
    const scale: CGFloat = rvn_cocoa_scale(window);
    send(void, window.handle, "setContentSize:", .{NSMakeSize(@as(CGFloat, @floatFromInt(base.rvn_maxi(width, 1))) / scale, @as(CGFloat, @floatFromInt(base.rvn_maxi(height, 1))) / scale)});
}

fn rvn_cocoa_window_get_size(window_opaque: ?*platform.rvn_pwindow_t, width: [*c]c_int, height: [*c]c_int) callconv(.c) void {
    const window = win(window_opaque);
    const bounds = send(NSRect, window.view, "bounds", .{});
    const s: f64 = rvn_cocoa_scale(window);
    width.* = lrintInt(bounds.size.width * s);
    height.* = lrintInt(bounds.size.height * s);
}

fn rvn_cocoa_window_set_min_size(window_opaque: ?*platform.rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void {
    const window = win(window_opaque);
    const scale: CGFloat = rvn_cocoa_scale(window);
    window.min_width = width;
    window.min_height = height;
    send(void, window.handle, "setContentMinSize:", .{NSMakeSize(@as(CGFloat, @floatFromInt(width)) / scale, @as(CGFloat, @floatFromInt(height)) / scale)});
}

fn NSMakeSize(w: CGFloat, h: CGFloat) NSSize {
    return .{ .width = w, .height = h };
}

fn rvn_cocoa_window_set_position(window_opaque: ?*platform.rvn_pwindow_t, x: c_int, y: c_int) callconv(.c) void {
    const window = win(window_opaque);
    var frame = send(NSRect, window.handle, "frame", .{});
    const screen: id = if (send(id, window.handle, "screen", .{}) != null) send(id, window.handle, "screen", .{}) else send(id, cls("NSScreen"), "mainScreen", .{});
    const screen_h: CGFloat = if (screen != null) send(NSRect, screen, "frame", .{}).size.height else frame.size.height;
    frame.origin = NSMakePoint(@floatFromInt(x), screen_h - @as(CGFloat, @floatFromInt(y)) - frame.size.height);
    send(void, window.handle, "setFrameOrigin:", .{frame.origin});
}

fn rvn_cocoa_window_get_position(window_opaque: ?*platform.rvn_pwindow_t, x: [*c]c_int, y: [*c]c_int) callconv(.c) void {
    const window = win(window_opaque);
    const frame = send(NSRect, window.handle, "frame", .{});
    const screen: id = if (send(id, window.handle, "screen", .{}) != null) send(id, window.handle, "screen", .{}) else send(id, cls("NSScreen"), "mainScreen", .{});
    const screen_h: CGFloat = if (screen != null) send(NSRect, screen, "frame", .{}).size.height else frame.size.height;
    x.* = lrintInt(frame.origin.x);
    y.* = lrintInt(screen_h - frame.origin.y - frame.size.height);
}

fn rvn_cocoa_window_get_scale(window_opaque: ?*platform.rvn_pwindow_t) callconv(.c) f32 {
    return rvn_cocoa_scale(optWin(window_opaque));
}

fn rvn_cocoa_window_show(window_opaque: ?*platform.rvn_pwindow_t, visible: c_int) callconv(.c) void {
    const window = win(window_opaque);
    if (visible != 0) {
        send(void, window.handle, "makeKeyAndOrderFront:", .{NIL});
    } else {
        send(void, window.handle, "orderOut:", .{NIL});
    }
}

fn rvn_cocoa_window_set_state(window_opaque: ?*platform.rvn_pwindow_t, state: platform.rvn_pwindow_state_t) callconv(.c) void {
    const window = win(window_opaque);
    if (state == platform.RVN_PWINDOW_MINIMIZED) {
        send(void, window.handle, "miniaturize:", .{NIL});
        window.state = state;
    } else if (state == platform.RVN_PWINDOW_MAXIMIZED) {
        if (!send(bool, window.handle, "isZoomed", .{})) send(void, window.handle, "zoom:", .{NIL});
        window.state = state;
    } else {
        if (send(bool, window.handle, "isMiniaturized", .{})) send(void, window.handle, "deminiaturize:", .{NIL});
        if (send(bool, window.handle, "isZoomed", .{})) send(void, window.handle, "zoom:", .{NIL});
        window.state = state;
    }
}

fn rvn_cocoa_window_get_state(window_opaque: ?*platform.rvn_pwindow_t) callconv(.c) platform.rvn_pwindow_state_t {
    const window = win(window_opaque);
    if (send(bool, window.handle, "isMiniaturized", .{})) return platform.RVN_PWINDOW_MINIMIZED;
    if (send(bool, window.handle, "isZoomed", .{})) return platform.RVN_PWINDOW_MAXIMIZED;
    return platform.RVN_PWINDOW_NORMAL;
}

fn rvn_cocoa_window_begin_move(window_opaque: ?*platform.rvn_pwindow_t) callconv(.c) void {
    const window = win(window_opaque);
    const current = send(id, NSApp, "currentEvent", .{});
    if (current != null and send(NSUInteger, current, "type", .{}) == NSEventTypeLeftMouseDown) {
        send(void, window.handle, "performWindowDragWithEvent:", .{current});
    }
}

fn rvn_cocoa_window_begin_resize(window_opaque: ?*platform.rvn_pwindow_t, edge: platform.rvn_pregion_t) callconv(.c) void {
    const window = optWin(window_opaque) orelse return;
    if (window.handle == null or edge < platform.RVN_PREGION_LEFT or edge > platform.RVN_PREGION_BOTTOM_RIGHT) return;
    g_cocoa.resize_window = window;
    g_cocoa.resize_region = edge;
    g_cocoa.resize_start = send(NSPoint, cls("NSEvent"), "mouseLocation", .{});
    g_cocoa.resize_frame = send(NSRect, window.handle, "frame", .{});
}

fn rvn_cocoa_window_set_backdrop(window_opaque: ?*platform.rvn_pwindow_t, backdrop: c_int, dark: c_int) callconv(.c) c_int {
    _ = dark; // RVN_UNUSED(dark);
    const window = win(window_opaque);
    if (window.transparent == 0) return raven.R_BACKDROP_NONE;
    if (backdrop == raven.R_BACKDROP_NONE) {
        send(void, window.handle, "setBackgroundColor:", .{send(id, cls("NSColor"), "windowBackgroundColor", .{})});
        send(void, window.handle, "setOpaque:", .{true});
        return raven.R_BACKDROP_NONE;
    }
    send(void, window.handle, "setBackgroundColor:", .{send(id, cls("NSColor"), "clearColor", .{})});
    send(void, window.handle, "setOpaque:", .{false});
    return raven.R_BACKDROP_TRANSPARENT;
}

fn rvn_cocoa_window_set_opacity(window_opaque: ?*platform.rvn_pwindow_t, opacity: f32) callconv(.c) c_int {
    const window = win(window_opaque);
    send(void, window.handle, "setAlphaValue:", .{@as(CGFloat, base.rvn_clampf(opacity, 0.0, 1.0))});
    return raven.R_TRUE;
}

fn rvn_cocoa_window_set_cursor(window_opaque: ?*platform.rvn_pwindow_t, cursor: raven.RCursor) callconv(.c) void {
    const window = win(window_opaque);
    var native = send(id, cls("NSCursor"), "arrowCursor", .{});
    switch (cursor) {
        @as(raven.RCursor, @intCast(raven.R_CURSOR_IBEAM)) => native = send(id, cls("NSCursor"), "IBeamCursor", .{}),
        @as(raven.RCursor, @intCast(raven.R_CURSOR_HAND)) => native = send(id, cls("NSCursor"), "pointingHandCursor", .{}),
        @as(raven.RCursor, @intCast(raven.R_CURSOR_CROSSHAIR)) => native = send(id, cls("NSCursor"), "crosshairCursor", .{}),
        @as(raven.RCursor, @intCast(raven.R_CURSOR_RESIZE_H)) => native = send(id, cls("NSCursor"), "resizeLeftRightCursor", .{}),
        @as(raven.RCursor, @intCast(raven.R_CURSOR_RESIZE_V)) => native = send(id, cls("NSCursor"), "resizeUpDownCursor", .{}),
        @as(raven.RCursor, @intCast(raven.R_CURSOR_MOVE)) => native = send(id, cls("NSCursor"), "openHandCursor", .{}),
        @as(raven.RCursor, @intCast(raven.R_CURSOR_NOT_ALLOWED)) => native = send(id, cls("NSCursor"), "operationNotAllowedCursor", .{}),
        else => {},
    }
    window.cursor = native;
    send(void, native, "set", .{});
}

fn rvn_cocoa_window_get_native(window_opaque: ?*platform.rvn_pwindow_t, native: [*c]raven.RNativeWindow) callconv(.c) void {
    const window = win(window_opaque);
    native.* = std.mem.zeroes(raven.RNativeWindow);
    native.*.system = @intCast(raven.R_WINDOW_SYSTEM_COCOA);
    native.*.display = window.handle;
    // VK_EXT_metal_surface requires CAMetalLayer*, not NSWindow*.
    native.*.window = @intFromPtr(send(id, window.view, "layer", .{}));
    native.*.transparent = window.transparent;
}

fn rvn_cocoa_child_create(parent_opaque: ?*platform.rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) ?*platform.rvn_pwindow_t {
    const parent = win(parent_opaque);
    const child: *Window = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(Window))));
    child.user = user;
    child.is_child = raven.R_TRUE;
    child.transparent = parent.transparent;
    const scale: CGFloat = rvn_cocoa_scale(parent);
    const sx: CGFloat = @floatFromInt(x);
    const sy: CGFloat = @floatFromInt(y);
    const frame = NSMakeRect(sx / scale, sy / scale, @as(CGFloat, @floatFromInt(base.rvn_maxi(width, 1))) / scale, @as(CGFloat, @floatFromInt(base.rvn_maxi(height, 1))) / scale);
    const view_alloc = send(id, cls("RavenCocoaView"), "alloc", .{});
    child.view = send(id, view_alloc, "initWithFrame:", .{frame});
    ivarPtr(?*Window, child.view, g_view_window_offset).* = child;
    rvn_cocoa_install_layer(child.view, rvn_cocoa_scale(parent), child.transparent);
    send(void, child.view, "registerForDraggedTypes:", .{ndArray2(NSPasteboardTypeFileURL, NSPasteboardTypeString)});
    send(void, parent.view, "addSubview:", .{child.view});
    return @ptrCast(child);
}

fn rvn_cocoa_child_set_rect(child_opaque: ?*platform.rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, visible: c_int) callconv(.c) void {
    const child = win(child_opaque);
    if (visible != 0) {
        const scale: CGFloat = rvn_cocoa_scale(child);
        const sx: CGFloat = @floatFromInt(x);
        const sy: CGFloat = @floatFromInt(y);
        send(void, child.view, "setFrame:", .{NSMakeRect(sx / scale, sy / scale, @as(CGFloat, @floatFromInt(base.rvn_maxi(width, 1))) / scale, @as(CGFloat, @floatFromInt(base.rvn_maxi(height, 1))) / scale)});
        const layer = send(id, child.view, "layer", .{});
        send(void, layer, "setContentsScale:", .{scale});
        send(void, child.view, "setHidden:", .{false});
    } else {
        send(void, child.view, "setHidden:", .{true});
    }
}

fn rvn_cocoa_pump(timeout_seconds: f64) callconv(.c) void {
    const limit_initial: id = if (timeout_seconds < 0.0)
        send(id, cls("NSDate"), "distantFuture", .{})
    else if (timeout_seconds == 0.0)
        send(id, cls("NSDate"), "distantPast", .{})
    else
        send(id, cls("NSDate"), "dateWithTimeIntervalSinceNow:", .{timeout_seconds});
    var limit = limit_initial;
    while (true) {
        const event = send(id, NSApp, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ NSEventMaskAny, limit, NSDefaultRunLoopMode, true });
        if (event == null) break;
        if (send(NSUInteger, event, "type", .{}) != NSEventTypeApplicationDefined) {
            send(void, NSApp, "sendEvent:", .{event});
            send(void, NSApp, "updateWindows", .{});
        }
        // A zero timeout drains every event already queued, rather than only
        // the first one. A positive timeout does not extend while processing.
        if (timeout_seconds > 0.0 and send(f64, limit, "timeIntervalSinceNow", .{}) <= 0.0) break;
        // Like the other platforms, wait only for the first event: once
        // something arrived (an input or a wake), drain what is already
        // queued and return, so Raven can update and draw.
        limit = send(id, cls("NSDate"), "distantPast", .{});
    }
    send(void, g_cocoa.pool, "drain", .{});
    g_cocoa.pool = send(id, send(id, cls("NSAutoreleasePool"), "alloc", .{}), "init", .{});
}

fn rvn_cocoa_wake() callconv(.c) void {
    // otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:
    // (nine arguments: the method is typed by hand, as send() takes at most four)
    const OtherEventFn = *const fn (id, SEL, NSUInteger, NSPoint, NSUInteger, f64, NSInteger, id, c_short, NSInteger, NSInteger) callconv(.c) id;
    const f: OtherEventFn = @ptrCast(&objc_msgSend);
    const event = f(cls("NSEvent"), sel_registerName("otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"), NSEventTypeApplicationDefined, NSZeroPoint, 0, 0, 0, NIL, 0, 0, 0);
    send(void, NSApp, "postEvent:atStart:", .{ event, true });
}

fn rvn_cocoa_clipboard_set(text: [*c]const u8) callconv(.c) void {
    const board = send(id, cls("NSPasteboard"), "generalPasteboard", .{});
    send(void, board, "clearContents", .{});
    const value = rvn_cocoa_string(text);
    send(void, board, "setString:forType:", .{ value, NSPasteboardTypeString });
}

fn rvn_cocoa_clipboard_get() callconv(.c) [*c]u8 {
    const value = send(id, send(id, cls("NSPasteboard"), "generalPasteboard", .{}), "stringForType:", .{NSPasteboardTypeString});
    if (value == null) return null;
    const utf8 = send([*c]const u8, value, "UTF8String", .{});
    return if (utf8 != null) base.rvn_strdup(utf8) else null;
}

// ---------------------------------------------------------------------------
//  Accessibility: VoiceOver (NSAccessibility)
//
//  The view of a window stands for the window node; every other node of
//  core/accessibility.h is a RavenAccessibilityElement, made on first use and
//  kept in a table by node. The geometry is in points: the logical units of
//  Raven on macOS (the scale of a window is its backing scale).
// ---------------------------------------------------------------------------

/// Logical units of the window (top-left origin) -> screen (bottom-left origin).
fn rvn_cocoa_a11y_screen_rect(window: ?*Window, node: *const ext.rvn_a11y_node_t) NSRect {
    const rw = window orelse return NSZeroRect;
    if (rw.view == null or rw.handle == null) return NSZeroRect;
    const local = NSMakeRect(node.x, node.y, node.width, node.height);
    const in_window = send(NSRect, rw.view, "convertRect:toView:", .{ local, NIL });
    return send(NSRect, rw.handle, "convertRectToScreen:", .{in_window});
}

fn rvn_cocoa_a11y_role(node: *const ext.rvn_a11y_node_t) id {
    switch (node.role) {
        raven.R_ROLE_WINDOW => return NSAccessibilityWindowRole,
        raven.R_ROLE_TEXT, raven.R_ROLE_HEADING, raven.R_ROLE_ALERT => return NSAccessibilityStaticTextRole,
        raven.R_ROLE_LINK => return NSAccessibilityLinkRole,
        raven.R_ROLE_BUTTON, raven.R_ROLE_TOGGLE_BUTTON => return NSAccessibilityButtonRole,
        raven.R_ROLE_CHECKBOX => return NSAccessibilityCheckBoxRole,
        raven.R_ROLE_RADIO_BUTTON => return NSAccessibilityRadioButtonRole,
        raven.R_ROLE_SLIDER => return NSAccessibilitySliderRole,
        raven.R_ROLE_PROGRESS_BAR => return NSAccessibilityProgressIndicatorRole,
        raven.R_ROLE_SPIN_BUTTON => return NSAccessibilityIncrementorRole,
        raven.R_ROLE_TEXT_FIELD => return NSAccessibilityTextFieldRole,
        raven.R_ROLE_DOCUMENT => return NSAccessibilityTextAreaRole,
        raven.R_ROLE_COMBO_BOX => return NSAccessibilityPopUpButtonRole,
        raven.R_ROLE_LIST => return NSAccessibilityListRole,
        raven.R_ROLE_LIST_ITEM => return NSAccessibilityStaticTextRole,
        raven.R_ROLE_TREE => return NSAccessibilityOutlineRole,
        raven.R_ROLE_TREE_ITEM => return NSAccessibilityRowRole,
        raven.R_ROLE_TABLE => return NSAccessibilityTableRole,
        raven.R_ROLE_MENU_BAR => return NSAccessibilityMenuBarRole,
        raven.R_ROLE_MENU => return NSAccessibilityMenuRole,
        raven.R_ROLE_MENU_ITEM => return NSAccessibilityMenuItemRole,
        raven.R_ROLE_TAB_LIST => return NSAccessibilityTabGroupRole,
        raven.R_ROLE_TAB => return NSAccessibilityRadioButtonRole,
        raven.R_ROLE_TOOLBAR => return NSAccessibilityToolbarRole,
        raven.R_ROLE_IMAGE => return NSAccessibilityImageRole,
        raven.R_ROLE_SEPARATOR => return NSAccessibilitySplitterRole,
        raven.R_ROLE_SCROLL_BAR => return NSAccessibilityScrollBarRole,
        raven.R_ROLE_DIALOG => return NSAccessibilitySheetRole,
        else => return NSAccessibilityGroupRole,
    }
}

fn rvn_cocoa_a11y_children(window: ?*Window, node: ext.rvn_a11y_id_t) id {
    const count = ext.rvn_a11y_child_count(node);
    const children = send(id, cls("NSMutableArray"), "arrayWithCapacity:", .{@as(NSUInteger, @intCast(if (count > 0) count else 0))});
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const child = rvn_cocoa_a11y_object(window, ext.rvn_a11y_child(node, i));
        if (child != null) send(void, children, "addObject:", .{child});
    }
    return children;
}

// ---- RavenAccessibilityElement (an NSAccessibilityElement: one node) ----

fn elemIsAccessibilityElement(self: id, _cmd: SEL) callconv(.c) bool {
    _ = _cmd;
    return ext.rvn_a11y_exists(elementNode(self)) != 0;
}

fn elemAccessibilityRole(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    if (ext.rvn_a11y_describe(elementNode(self), &node) == 0) return NSAccessibilityUnknownRole;
    return rvn_cocoa_a11y_role(&node);
}

fn elemAccessibilityRoleDescription(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    if (ext.rvn_a11y_describe(elementNode(self), &node) == 0) return nsString("");
    if (node.role == raven.R_ROLE_TAB) return nsString("tab");
    if (node.role == raven.R_ROLE_HEADING) return nsString("heading");
    if (node.role == raven.R_ROLE_CANVAS) return nsString("canvas");
    return NSAccessibilityRoleDescription(send(id, self, "accessibilityRole", .{}), NIL);
}

fn elemAccessibilityLabel(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return if (ext.rvn_a11y_describe(elementNode(self), &node) != 0) rvn_cocoa_string(node.name) else nsString("");
}

fn elemAccessibilityHelp(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return if (ext.rvn_a11y_describe(elementNode(self), &node) != 0) rvn_cocoa_string(node.description) else nsString("");
}

fn elemAccessibilityValue(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    if (ext.rvn_a11y_describe(elementNode(self), &node) == 0) return NIL;
    if ((node.states & ext.RVN_A11Y_CHECKABLE) != 0) return send(id, cls("NSNumber"), "numberWithInt:", .{@as(c_int, if ((node.states & ext.RVN_A11Y_CHECKED) != 0) 1 else 0)});
    if ((node.states & ext.RVN_A11Y_HAS_RANGE) != 0) return send(id, cls("NSNumber"), "numberWithDouble:", .{node.number});
    if (node.role == raven.R_ROLE_TAB) return send(id, cls("NSNumber"), "numberWithInt:", .{@as(c_int, if ((node.states & ext.RVN_A11Y_SELECTED) != 0) 1 else 0)});
    return rvn_cocoa_string(node.value);
}

fn elemSetAccessibilityValue(self: id, _cmd: SEL, value: id) callconv(.c) void {
    _ = _cmd;
    if (send(bool, value, "isKindOfClass:", .{cls("NSNumber")})) {
        _ = ext.rvn_a11y_set_number(elementNode(self), send(f64, value, "doubleValue", .{}));
    } else if (send(bool, value, "isKindOfClass:", .{cls("NSString")})) {
        _ = ext.rvn_a11y_set_value(elementNode(self), send([*c]const u8, value, "UTF8String", .{}));
    }
}

fn elemAccessibilityMinValue(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return if (ext.rvn_a11y_describe(elementNode(self), &node) != 0 and (node.states & ext.RVN_A11Y_HAS_RANGE) != 0)
        send(id, cls("NSNumber"), "numberWithDouble:", .{node.minimum})
    else
        NIL;
}

fn elemAccessibilityMaxValue(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return if (ext.rvn_a11y_describe(elementNode(self), &node) != 0 and (node.states & ext.RVN_A11Y_HAS_RANGE) != 0)
        send(id, cls("NSNumber"), "numberWithDouble:", .{node.maximum})
    else
        NIL;
}

fn elemAccessibilityFrame(self: id, _cmd: SEL) callconv(.c) NSRect {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return if (ext.rvn_a11y_describe(elementNode(self), &node) != 0) rvn_cocoa_a11y_screen_rect(elementWindow(self), &node) else NSZeroRect;
}

fn elemAccessibilityParent(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    const parent = ext.rvn_a11y_parent(elementNode(self));
    return rvn_cocoa_a11y_object(elementWindow(self), parent);
}

fn elemAccessibilityChildren(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    return rvn_cocoa_a11y_children(elementWindow(self), elementNode(self));
}

fn elemAccessibilityWindow(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    const rw = elementWindow(self) orelse return NIL;
    return rw.handle;
}

fn elemAccessibilityTopLevelUIElement(self: id, _cmd: SEL) callconv(.c) id {
    _ = _cmd;
    const rw = elementWindow(self) orelse return NIL;
    return rw.handle;
}

fn elemIsAccessibilityFocused(self: id, _cmd: SEL) callconv(.c) bool {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return ext.rvn_a11y_describe(elementNode(self), &node) != 0 and (node.states & ext.RVN_A11Y_FOCUSED) != 0;
}

fn elemSetAccessibilityFocused(self: id, _cmd: SEL, focused: bool) callconv(.c) void {
    _ = _cmd;
    if (focused) _ = ext.rvn_a11y_act(elementNode(self), ext.RVN_A11Y_FOCUS);
}

fn elemIsAccessibilityEnabled(self: id, _cmd: SEL) callconv(.c) bool {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return ext.rvn_a11y_describe(elementNode(self), &node) != 0 and !((node.states & ext.RVN_A11Y_DISABLED) != 0);
}

fn elemIsAccessibilitySelected(self: id, _cmd: SEL) callconv(.c) bool {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return ext.rvn_a11y_describe(elementNode(self), &node) != 0 and (node.states & ext.RVN_A11Y_SELECTED) != 0;
}

fn elemIsAccessibilityExpanded(self: id, _cmd: SEL) callconv(.c) bool {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    return ext.rvn_a11y_describe(elementNode(self), &node) != 0 and (node.states & ext.RVN_A11Y_EXPANDED) != 0;
}

fn elemSetAccessibilityExpanded(self: id, _cmd: SEL, expanded: bool) callconv(.c) void {
    _ = _cmd;
    _ = ext.rvn_a11y_act(elementNode(self), if (expanded) ext.RVN_A11Y_EXPAND else ext.RVN_A11Y_COLLAPSE);
}

fn elemAccessibilityPerformPress(self: id, _cmd: SEL) callconv(.c) bool {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    if (ext.rvn_a11y_describe(elementNode(self), &node) == 0) return false;
    return ext.rvn_a11y_act(elementNode(self), if ((node.states & ext.RVN_A11Y_CHECKABLE) != 0) ext.RVN_A11Y_TOGGLE else ext.RVN_A11Y_PRESS) != 0;
}

fn elemAccessibilityPerformIncrement(self: id, _cmd: SEL) callconv(.c) bool {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    if (ext.rvn_a11y_describe(elementNode(self), &node) == 0 or (node.states & ext.RVN_A11Y_HAS_RANGE) == 0) return false;
    return ext.rvn_a11y_set_number(elementNode(self), node.number + (if (node.step > 0.0) node.step else 1.0)) != 0;
}

fn elemAccessibilityPerformDecrement(self: id, _cmd: SEL) callconv(.c) bool {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    if (ext.rvn_a11y_describe(elementNode(self), &node) == 0 or (node.states & ext.RVN_A11Y_HAS_RANGE) == 0) return false;
    return ext.rvn_a11y_set_number(elementNode(self), node.number - (if (node.step > 0.0) node.step else 1.0)) != 0;
}

fn elemIsAccessibilitySelectorAllowed(self: id, _cmd: SEL, selector: SEL) callconv(.c) bool {
    _ = _cmd;
    var node: ext.rvn_a11y_node_t = undefined;
    if (ext.rvn_a11y_describe(elementNode(self), &node) == 0) return false;
    if (selector == sel_registerName("accessibilityPerformPress")) return (node.states & (ext.RVN_A11Y_INVOKABLE | ext.RVN_A11Y_CHECKABLE)) != 0;
    if (selector == sel_registerName("accessibilityPerformIncrement") or selector == sel_registerName("accessibilityPerformDecrement"))
        return (node.states & ext.RVN_A11Y_HAS_RANGE) != 0 and !((node.states & ext.RVN_A11Y_READONLY) != 0);
    if (selector == sel_registerName("setAccessibilityValue:")) return (node.states & (ext.RVN_A11Y_EDITABLE | ext.RVN_A11Y_HAS_RANGE)) != 0;
    return sendSuper(bool, self, g_element_class, "isAccessibilitySelectorAllowed:", .{selector});
}

/// The object of a node: the view for the window, an element for the others.
fn rvn_cocoa_a11y_object(window: ?*Window, node: ext.rvn_a11y_id_t) id {
    const rw = window orelse return NIL;
    if (node == 0) return NIL;
    if (node == @as(ext.rvn_a11y_id_t, ext.rvn_a11y_window_of(rw.user))) return rw.view;
    if (g_cocoa_elements == null) g_cocoa_elements = send(id, send(id, cls("NSMutableDictionary"), "alloc", .{}), "init", .{});
    const key = send(id, cls("NSNumber"), "numberWithUnsignedLongLong:", .{@as(c_ulonglong, node)});
    const existing = send(id, g_cocoa_elements, "objectForKey:", .{key});
    if (existing != null) return existing;
    const element = send(id, send(id, g_element_class, "alloc", .{}), "init", .{});
    ivarPtr(u64, element, g_element_node_offset).* = node;
    ivarPtr(?*Window, element, g_element_window_offset).* = rw;
    send(void, g_cocoa_elements, "setObject:forKey:", .{ element, key });
    send(void, element, "release", .{});
    return element;
}

/// Forgets the elements of a window that goes, or else the nodes that are gone.
fn rvn_cocoa_a11y_forget(window: ?*Window) void {
    if (g_cocoa_elements == null) return;
    const keys = send(id, cls("NSMutableArray"), "array", .{});
    const enumerator = send(id, g_cocoa_elements, "keyEnumerator", .{});
    while (true) {
        const key = send(id, enumerator, "nextObject", .{});
        if (key == null) break;
        const element = send(id, g_cocoa_elements, "objectForKey:", .{key});
        const gone = if (window) |w| elementWindow(element) == w else ext.rvn_a11y_exists(elementNode(element)) == 0;
        if (gone) {
            ivarPtr(?*Window, element, g_element_window_offset).* = null;
            send(void, keys, "addObject:", .{key});
        }
    }
    send(void, g_cocoa_elements, "removeObjectsForKeys:", .{keys});
}

fn rvn_cocoa_a11y_event(window_opaque: ?*platform.rvn_pwindow_t, event: c_int, node: u64) callconv(.c) void {
    const window = optWin(window_opaque);
    const object = rvn_cocoa_a11y_object(window, @as(ext.rvn_a11y_id_t, node));
    if (object == null) return;
    switch (event) {
        ext.RVN_A11Y_EVENT_FOCUS => {
            NSAccessibilityPostNotification(object, NSAccessibilityFocusedUIElementChangedNotification);
        },
        ext.RVN_A11Y_EVENT_VALUE, ext.RVN_A11Y_EVENT_STATE => {
            NSAccessibilityPostNotification(object, NSAccessibilityValueChangedNotification);
        },
        ext.RVN_A11Y_EVENT_NAME => {
            NSAccessibilityPostNotification(object, NSAccessibilityTitleChangedNotification);
        },
        ext.RVN_A11Y_EVENT_STRUCTURE => {
            rvn_cocoa_a11y_forget(null);
            const rw = window.?;
            if (rw.view != null) NSAccessibilityPostNotification(rw.view, NSAccessibilityLayoutChangedNotification);
        },
        else => {},
    }
}

fn rvn_cocoa_a11y_announce(window_opaque: ?*platform.rvn_pwindow_t, text: [*c]const u8, assertive: c_int) callconv(.c) void {
    const window = optWin(window_opaque);
    const keys = [_]id{ NSAccessibilityAnnouncementKey, NSAccessibilityPriorityKey };
    const priority: NSInteger = if (assertive != 0) NSAccessibilityPriorityHigh else NSAccessibilityPriorityMedium;
    const values = [_]id{ rvn_cocoa_string(text), send(id, cls("NSNumber"), "numberWithInteger:", .{priority}) };
    const info = send(id, cls("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ @as([*c]const id, &values), @as([*c]const id, &keys), @as(NSUInteger, 2) });
    const target: id = if (window != null and window.?.handle != null) window.?.handle else NSApp;
    NSAccessibilityPostNotificationWithUserInfo(target, NSAccessibilityAnnouncementRequestedNotification, info);
}

fn rvn_cocoa_a11y_active() callconv(.c) c_int {
    const workspace = send(id, cls("NSWorkspace"), "sharedWorkspace", .{});
    if (send(bool, workspace, "respondsToSelector:", .{sel_registerName("isVoiceOverEnabled")})) {
        return if (send(bool, workspace, "isVoiceOverEnabled", .{})) raven.R_TRUE else raven.R_FALSE;
    }
    return raven.R_TRUE;
}

fn rvn_cocoa_a11y_settings(settings: [*c]raven.RAccessibilitySettings) callconv(.c) void {
    const workspace = send(id, cls("NSWorkspace"), "sharedWorkspace", .{});
    if (send(bool, workspace, "respondsToSelector:", .{sel_registerName("accessibilityDisplayShouldIncreaseContrast")})) {
        settings.*.high_contrast = if (send(bool, workspace, "accessibilityDisplayShouldIncreaseContrast", .{})) raven.R_TRUE else raven.R_FALSE;
    }
    if (send(bool, workspace, "respondsToSelector:", .{sel_registerName("accessibilityDisplayShouldReduceMotion")})) {
        settings.*.reduce_motion = if (send(bool, workspace, "accessibilityDisplayShouldReduceMotion", .{})) raven.R_TRUE else raven.R_FALSE;
    }
}

// ---------------------------------------------------------------------------
//  Class creation (the @interface / @implementation blocks of the C file)
// ---------------------------------------------------------------------------

fn ivarOffset(class: Class, name: [*:0]const u8) isize {
    return ivar_getOffset(class_getInstanceVariable(class, name));
}

fn createClasses() void {
    // @interface RavenCocoaView : NSView <NSDraggingDestination> { @public rvn_pwindow_t* ravenWindow; NSTrackingArea* trackingArea; }
    g_view_class = objc_allocateClassPair(objc_getClass("NSView"), "RavenCocoaView", 0);
    _ = class_addIvar(g_view_class, "ravenWindow", @sizeOf(?*anyopaque), 3, "^v");
    _ = class_addIvar(g_view_class, "trackingArea", @sizeOf(?*anyopaque), 3, "@");
    _ = class_addProtocol(g_view_class, objc_getProtocol("NSDraggingDestination"));
    addMethod(g_view_class, "isFlipped", viewIsFlipped, "B@:");
    addMethod(g_view_class, "updateTrackingAreas", viewUpdateTrackingAreas, "v@:");
    addMethod(g_view_class, "dealloc", viewDealloc, "v@:");
    addMethod(g_view_class, "acceptsFirstResponder", viewAcceptsFirstResponder, "B@:");
    addMethod(g_view_class, "wantsUpdateLayer", viewWantsUpdateLayer, "B@:");
    addMethod(g_view_class, "drawRect:", viewDrawRect, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
    addMethod(g_view_class, "updateLayer", viewUpdateLayer, "v@:");
    addMethod(g_view_class, "mouseMoved:", viewMouseMoved, "v@:@");
    addMethod(g_view_class, "mouseDragged:", viewMouseDragged, "v@:@");
    addMethod(g_view_class, "rightMouseDragged:", viewRightMouseDragged, "v@:@");
    addMethod(g_view_class, "otherMouseDragged:", viewOtherMouseDragged, "v@:@");
    addMethod(g_view_class, "mouseEntered:", viewMouseEntered, "v@:@");
    addMethod(g_view_class, "mouseExited:", viewMouseExited, "v@:@");
    addMethod(g_view_class, "rvnMouse:button:pressed:", viewRvnMouse, "v@:@ii");
    addMethod(g_view_class, "mouseDown:", viewMouseDown, "v@:@");
    addMethod(g_view_class, "mouseUp:", viewMouseUp, "v@:@");
    addMethod(g_view_class, "rightMouseDown:", viewRightMouseDown, "v@:@");
    addMethod(g_view_class, "rightMouseUp:", viewRightMouseUp, "v@:@");
    addMethod(g_view_class, "otherMouseDown:", viewOtherMouseDown, "v@:@");
    addMethod(g_view_class, "otherMouseUp:", viewOtherMouseUp, "v@:@");
    addMethod(g_view_class, "scrollWheel:", viewScrollWheel, "v@:@");
    addMethod(g_view_class, "keyDown:", viewKeyDown, "v@:@");
    addMethod(g_view_class, "keyUp:", viewKeyUp, "v@:@");
    addMethod(g_view_class, "flagsChanged:", viewFlagsChanged, "v@:@");
    addMethod(g_view_class, "rvnDrag:leaving:", viewRvnDrag, "Q@:@i");
    addMethod(g_view_class, "draggingEntered:", viewDraggingEntered, "Q@:@");
    addMethod(g_view_class, "draggingUpdated:", viewDraggingUpdated, "Q@:@");
    addMethod(g_view_class, "draggingExited:", viewDraggingExited, "v@:@");
    addMethod(g_view_class, "prepareForDragOperation:", viewPrepareForDragOperation, "B@:@");
    addMethod(g_view_class, "performDragOperation:", viewPerformDragOperation, "B@:@");
    // @implementation RavenCocoaView (RavenAccessibility)
    addMethod(g_view_class, "isAccessibilityElement", viewIsAccessibilityElement, "B@:");
    addMethod(g_view_class, "accessibilityRole", viewAccessibilityRole, "@@:");
    addMethod(g_view_class, "accessibilityLabel", viewAccessibilityLabel, "@@:");
    addMethod(g_view_class, "accessibilityChildren", viewAccessibilityChildren, "@@:");
    addMethod(g_view_class, "accessibilityHitTest:", viewAccessibilityHitTest, "@@:{CGPoint=dd}");
    addMethod(g_view_class, "accessibilityFocusedUIElement", viewAccessibilityFocusedUIElement, "@@:");
    objc_registerClassPair(g_view_class);
    g_view_window_offset = ivarOffset(g_view_class, "ravenWindow");
    g_view_tracking_offset = ivarOffset(g_view_class, "trackingArea");

    // @interface RavenCocoaDelegate : NSObject <NSWindowDelegate> { @public rvn_pwindow_t* ravenWindow; }
    g_delegate_class = objc_allocateClassPair(objc_getClass("NSObject"), "RavenCocoaDelegate", 0);
    _ = class_addIvar(g_delegate_class, "ravenWindow", @sizeOf(?*anyopaque), 3, "^v");
    _ = class_addProtocol(g_delegate_class, objc_getProtocol("NSWindowDelegate"));
    addMethod(g_delegate_class, "windowShouldClose:", delegateWindowShouldClose, "B@:@");
    addMethod(g_delegate_class, "windowDidChangeBackingProperties:", delegateWindowDidChangeBackingProperties, "v@:@");
    addMethod(g_delegate_class, "windowDidResize:", delegateWindowDidResize, "v@:@");
    addMethod(g_delegate_class, "windowDidBecomeKey:", delegateWindowDidBecomeKey, "v@:@");
    addMethod(g_delegate_class, "windowDidResignKey:", delegateWindowDidResignKey, "v@:@");
    addMethod(g_delegate_class, "windowDidMiniaturize:", delegateWindowDidMiniaturize, "v@:@");
    addMethod(g_delegate_class, "windowDidDeminiaturize:", delegateWindowDidDeminiaturize, "v@:@");
    addMethod(g_delegate_class, "windowDidEndLiveResize:", delegateWindowDidEndLiveResize, "v@:@");
    objc_registerClassPair(g_delegate_class);
    g_delegate_window_offset = ivarOffset(g_delegate_class, "ravenWindow");

    // @interface RavenAccessibilityElement : NSAccessibilityElement { nodeId; ravenWindow; }
    g_element_class = objc_allocateClassPair(objc_getClass("NSAccessibilityElement"), "RavenAccessibilityElement", 0);
    _ = class_addIvar(g_element_class, "nodeId", @sizeOf(u64), 3, "Q");
    _ = class_addIvar(g_element_class, "ravenWindow", @sizeOf(?*anyopaque), 3, "^v");
    addMethod(g_element_class, "isAccessibilityElement", elemIsAccessibilityElement, "B@:");
    addMethod(g_element_class, "accessibilityRole", elemAccessibilityRole, "@@:");
    addMethod(g_element_class, "accessibilityRoleDescription", elemAccessibilityRoleDescription, "@@:");
    addMethod(g_element_class, "accessibilityLabel", elemAccessibilityLabel, "@@:");
    addMethod(g_element_class, "accessibilityHelp", elemAccessibilityHelp, "@@:");
    addMethod(g_element_class, "accessibilityValue", elemAccessibilityValue, "@@:");
    addMethod(g_element_class, "setAccessibilityValue:", elemSetAccessibilityValue, "v@:@");
    addMethod(g_element_class, "accessibilityMinValue", elemAccessibilityMinValue, "@@:");
    addMethod(g_element_class, "accessibilityMaxValue", elemAccessibilityMaxValue, "@@:");
    addMethod(g_element_class, "accessibilityFrame", elemAccessibilityFrame, "{CGRect={CGPoint=dd}{CGSize=dd}}@:");
    addMethod(g_element_class, "accessibilityParent", elemAccessibilityParent, "@@:");
    addMethod(g_element_class, "accessibilityChildren", elemAccessibilityChildren, "@@:");
    addMethod(g_element_class, "accessibilityWindow", elemAccessibilityWindow, "@@:");
    addMethod(g_element_class, "accessibilityTopLevelUIElement", elemAccessibilityTopLevelUIElement, "@@:");
    addMethod(g_element_class, "isAccessibilityFocused", elemIsAccessibilityFocused, "B@:");
    addMethod(g_element_class, "setAccessibilityFocused:", elemSetAccessibilityFocused, "v@:B");
    addMethod(g_element_class, "isAccessibilityEnabled", elemIsAccessibilityEnabled, "B@:");
    addMethod(g_element_class, "isAccessibilitySelected", elemIsAccessibilitySelected, "B@:");
    addMethod(g_element_class, "isAccessibilityExpanded", elemIsAccessibilityExpanded, "B@:");
    addMethod(g_element_class, "setAccessibilityExpanded:", elemSetAccessibilityExpanded, "v@:B");
    addMethod(g_element_class, "accessibilityPerformPress", elemAccessibilityPerformPress, "B@:");
    addMethod(g_element_class, "accessibilityPerformIncrement", elemAccessibilityPerformIncrement, "B@:");
    addMethod(g_element_class, "accessibilityPerformDecrement", elemAccessibilityPerformDecrement, "B@:");
    addMethod(g_element_class, "isAccessibilitySelectorAllowed:", elemIsAccessibilitySelectorAllowed, "B@::");
    objc_registerClassPair(g_element_class);
    g_element_node_offset = ivarOffset(g_element_class, "nodeId");
    g_element_window_offset = ivarOffset(g_element_class, "ravenWindow");
}

// ---------------------------------------------------------------------------
//  The platform table
// ---------------------------------------------------------------------------

fn rvn_platform_cocoa_table() platform.rvn_platform_t {
    return .{
        .name = "Cocoa",
        .system = @intCast(raven.R_WINDOW_SYSTEM_COCOA),
        .init = &rvn_cocoa_init,
        .shutdown = &rvn_cocoa_shutdown,
        .native_display = &rvn_cocoa_native_display,
        .window_create = &rvn_cocoa_window_create,
        .window_destroy = &rvn_cocoa_window_destroy,
        .window_set_title = &rvn_cocoa_window_set_title,
        .window_set_size = &rvn_cocoa_window_set_size,
        .window_get_size = &rvn_cocoa_window_get_size,
        .window_set_min_size = &rvn_cocoa_window_set_min_size,
        .window_set_position = &rvn_cocoa_window_set_position,
        .window_get_position = &rvn_cocoa_window_get_position,
        .window_get_scale = &rvn_cocoa_window_get_scale,
        .window_show = &rvn_cocoa_window_show,
        .window_set_state = &rvn_cocoa_window_set_state,
        .window_get_state = &rvn_cocoa_window_get_state,
        .window_begin_move = &rvn_cocoa_window_begin_move,
        .window_begin_resize = &rvn_cocoa_window_begin_resize,
        .native_regions = raven.R_FALSE,
        .window_set_backdrop = &rvn_cocoa_window_set_backdrop,
        .window_set_opacity = &rvn_cocoa_window_set_opacity,
        .window_set_cursor = &rvn_cocoa_window_set_cursor,
        .window_get_native = &rvn_cocoa_window_get_native,
        .child_create = &rvn_cocoa_child_create,
        .child_set_rect = &rvn_cocoa_child_set_rect,
        .pump = &rvn_cocoa_pump,
        .wake = &rvn_cocoa_wake,
        .clipboard_set = &rvn_cocoa_clipboard_set,
        .clipboard_get = &rvn_cocoa_clipboard_get,
        .a11y_event = &rvn_cocoa_a11y_event,
        .a11y_announce = &rvn_cocoa_a11y_announce,
        .a11y_active = &rvn_cocoa_a11y_active,
        .a11y_settings = &rvn_cocoa_a11y_settings,
        .window_set_topmost = null,
        .window_center = null,
        .window_set_icon = null,
        .wait_service = null,
    };
}

const cocoa_platform: platform.rvn_platform_t = rvn_platform_cocoa_table();

fn rvn_platform_cocoa() callconv(.c) [*c]const platform.rvn_platform_t {
    if (!g_classes_ready) {
        createClasses();
        g_classes_ready = true;
    }
    return &cocoa_platform;
}

// The export of the C file. Its class creation runs when the platform is taken, as the C file's
// @implementation blocks do when the image is loaded. Exported on macOS only.
comptime {
    if (builtin.os.tag == .macos) {
        @export(&rvn_platform_cocoa, .{ .name = "rvn_platform_cocoa" });
    }
}
