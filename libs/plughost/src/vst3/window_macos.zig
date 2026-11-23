// Translated to Zig from soundcraft/crates/vst3-host/src/ffi/window/macos.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! An `NSWindow` hosting a VST3 plugin editor (`kPlatformTypeNSView`).
//!
//! Zig has no Objective-C, so the runtime is declared by hand. `plughost` is not linked
//! against libobjc or AppKit by the build, so both are `dlopen`ed on first use and
//! `objc_msgSend` is cast to one function type per call signature. Every call here takes
//! and returns only integers, pointers, bools and `f64` structs by value (no struct
//! returns), so plain `objc_msgSend` is correct on both arm64 and x86_64.
//!
//! Main thread only (UI thread, never the audio thread).

const std = @import("std");

/// The IPlugView platform type string (`kPlatformTypeNSView`).
pub const platform_type: ?[*:0]const u8 = "NSView";

extern "c" fn pthread_main_np() c_int;
extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

const RTLD_NOW: c_int = 2;

const Id = ?*anyopaque;
const Sel = ?*anyopaque;
const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { width: f64, height: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

const style_titled: usize = 1 << 0;
const style_closable: usize = 1 << 1;
const backing_buffered: usize = 2;
const floating_window_level: isize = 3;
const behavior_transient: usize = 1 << 3;
const behavior_ignores_cycle: usize = 1 << 6;

const GetClassFn = *const fn ([*:0]const u8) callconv(.c) Id;
const RegisterNameFn = *const fn ([*:0]const u8) callconv(.c) Sel;

/// The dlopen'ed runtime entry points.
const Runtime = struct {
    get_class: GetClassFn,
    sel: RegisterNameFn,
    msg: *const anyopaque,
};

var runtime_state: enum { unloaded, ready, failed } = .unloaded;
var runtime: Runtime = undefined;

/// Loads libobjc and AppKit once. Main thread only, so no synchronisation is needed.
fn loadRuntime() ?*const Runtime {
    switch (runtime_state) {
        .ready => return &runtime,
        .failed => return null,
        .unloaded => {},
    }
    runtime_state = .failed;
    const objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_NOW) orelse return null;
    _ = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_NOW) orelse return null;
    const gc = dlsym(objc, "objc_getClass") orelse return null;
    const sr = dlsym(objc, "sel_registerName") orelse return null;
    const mm = dlsym(objc, "objc_msgSend") orelse return null;
    runtime = .{ .get_class = @ptrCast(@alignCast(gc)), .sel = @ptrCast(@alignCast(sr)), .msg = mm };
    runtime_state = .ready;
    return &runtime;
}

// One typed cast of objc_msgSend per call signature.
fn msgId(rt: *const Runtime, recv: Id, sel: [*:0]const u8) Id {
    const f: *const fn (Id, Sel) callconv(.c) Id = @ptrCast(@alignCast(rt.msg));
    return f(recv, rt.sel(sel));
}
fn msgVoid(rt: *const Runtime, recv: Id, sel: [*:0]const u8) void {
    const f: *const fn (Id, Sel) callconv(.c) void = @ptrCast(@alignCast(rt.msg));
    f(recv, rt.sel(sel));
}
fn msgVoidId(rt: *const Runtime, recv: Id, sel: [*:0]const u8, a: Id) void {
    const f: *const fn (Id, Sel, Id) callconv(.c) void = @ptrCast(@alignCast(rt.msg));
    f(recv, rt.sel(sel), a);
}
fn msgVoidBool(rt: *const Runtime, recv: Id, sel: [*:0]const u8, a: bool) void {
    const f: *const fn (Id, Sel, bool) callconv(.c) void = @ptrCast(@alignCast(rt.msg));
    f(recv, rt.sel(sel), a);
}
fn msgVoidInt(rt: *const Runtime, recv: Id, sel: [*:0]const u8, a: isize) void {
    const f: *const fn (Id, Sel, isize) callconv(.c) void = @ptrCast(@alignCast(rt.msg));
    f(recv, rt.sel(sel), a);
}
fn msgVoidUint(rt: *const Runtime, recv: Id, sel: [*:0]const u8, a: usize) void {
    const f: *const fn (Id, Sel, usize) callconv(.c) void = @ptrCast(@alignCast(rt.msg));
    f(recv, rt.sel(sel), a);
}
fn msgVoidSize(rt: *const Runtime, recv: Id, sel: [*:0]const u8, a: NSSize) void {
    const f: *const fn (Id, Sel, NSSize) callconv(.c) void = @ptrCast(@alignCast(rt.msg));
    f(recv, rt.sel(sel), a);
}
fn msgBool(rt: *const Runtime, recv: Id, sel: [*:0]const u8) bool {
    // BOOL is `bool` on arm64 and `signed char` on x86_64; read the low byte either way.
    const f: *const fn (Id, Sel) callconv(.c) u8 = @ptrCast(@alignCast(rt.msg));
    return f(recv, rt.sel(sel)) != 0;
}
fn msgInitWindow(rt: *const Runtime, recv: Id, rect: NSRect, style: usize, backing: usize, defer_: bool) Id {
    const f: *const fn (Id, Sel, NSRect, usize, usize, bool) callconv(.c) Id = @ptrCast(@alignCast(rt.msg));
    return f(recv, rt.sel("initWithContentRect:styleMask:backing:defer:"), rect, style, backing, defer_);
}
fn msgStringFromUtf8(rt: *const Runtime, cls: Id, s: [*:0]const u8) Id {
    const f: *const fn (Id, Sel, [*:0]const u8) callconv(.c) Id = @ptrCast(@alignCast(rt.msg));
    return f(cls, rt.sel("stringWithUTF8String:"), s);
}

pub fn onMainThread() bool {
    return pthread_main_np() != 0;
}

pub const Error = error{ NotMainThread, RuntimeUnavailable, WindowCreateFailed };

/// An `NSWindow` (titled, closable, floating above the app's windows) whose content view is
/// the plugin view's parent. Holds one retain of the window; main thread only.
pub const Window = struct {
    window: Id,

    fn get(self: *const Window) ?*const Runtime {
        if (!onMainThread()) return null;
        if (self.window == null) return null;
        return loadRuntime();
    }

    pub fn new(title: []const u8, w: f64, h: f64) Error!Window {
        if (!onMainThread()) return error.NotMainThread;
        const rt = loadRuntime() orelse return error.RuntimeUnavailable;
        const app_class = rt.get_class("NSApplication");
        const win_class = rt.get_class("NSWindow");
        const str_class = rt.get_class("NSString");
        if (app_class == null or win_class == null or str_class == null) return error.RuntimeUnavailable;
        _ = msgId(rt, app_class, "sharedApplication");
        const rect = NSRect{ .origin = .{ .x = 200, .y = 200 }, .size = .{ .width = w, .height = h } };
        // Plugin editors are transient windows. In particular they must not be
        // minimizable: minimized NSWindows become persistent thumbnails in the macOS Dock,
        // which made every editor visited in a session look like another running app.
        const style = style_titled | style_closable;
        const alloc = msgId(rt, win_class, "alloc");
        const win = msgInitWindow(rt, alloc, rect, style, backing_buffered, false);
        if (win == null) return error.WindowCreateFailed;
        // We keep our own retain and release it in `close`, so AppKit must not release
        // the window when the user closes it.
        msgVoidBool(rt, win, "setReleasedWhenClosed:", false);
        var buf: [256:0]u8 = undefined;
        const n = @min(title.len, buf.len);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        const ns_title = msgStringFromUtf8(rt, str_class, &buf);
        msgVoidId(rt, win, "setTitle:", ns_title);
        msgVoidInt(rt, win, "setLevel:", floating_window_level);
        msgVoidBool(rt, win, "setHidesOnDeactivate:", true);
        msgVoidBool(rt, win, "setExcludedFromWindowsMenu:", true);
        msgVoidUint(rt, win, "setCollectionBehavior:", behavior_transient | behavior_ignores_cycle);
        msgVoid(rt, win, "center");
        return .{ .window = win };
    }

    /// The raw window pointer (for the plug frame's resizes).
    pub fn raw(self: *const Window) ?*anyopaque {
        return self.window;
    }

    /// The content view (`NSView*`) the plugin view attaches to; null when unavailable.
    pub fn parent(self: *const Window) ?*anyopaque {
        const rt = self.get() orelse return null;
        return msgId(rt, self.window, "contentView");
    }

    pub fn raise(self: *const Window) void {
        const rt = self.get() orelse return;
        msgVoidId(rt, self.window, "makeKeyAndOrderFront:", null);
    }

    pub fn isVisible(self: *const Window) bool {
        const rt = self.get() orelse return false;
        return msgBool(rt, self.window, "isVisible");
    }

    /// Hides, closes and releases the window; the handle is unusable afterwards.
    pub fn close(self: *Window) void {
        if (self.get()) |rt| {
            msgVoidId(rt, self.window, "orderOut:", null);
            msgVoid(rt, self.window, "close");
            // Balances the retain taken in `new`; nothing uses the pointer after this.
            msgVoid(rt, self.window, "release");
        }
        self.window = null;
    }
};

/// Resizes a host window's content (`window` from `Window.raw`); main thread only.
pub fn resize(window: ?*anyopaque, w: f64, h: f64) void {
    if (!onMainThread()) return;
    if (window == null) return;
    const rt = loadRuntime() orelse return;
    msgVoidSize(rt, window, "setContentSize:", .{ .width = w, .height = h });
}

// The Rust file has no tests; these cover the main-thread guards, which need no WindowServer.
test "window_macos: off the main thread, new fails and calls are inert" {
    const T = struct {
        fn run(out: *bool) void {
            const e = Window.new("t", 10, 10);
            var ok = std.meta.isError(e) and !onMainThread();
            var dead = Window{ .window = @ptrFromInt(0x10) };
            ok = ok and dead.parent() == null and !dead.isVisible();
            dead.raise();
            resize(@ptrFromInt(0x10), 1, 1);
            out.* = ok;
        }
    };
    var ok = false;
    const th = try std.Thread.spawn(.{}, T.run, .{&ok});
    th.join();
    try std.testing.expect(ok);
}

test "window_macos: close of an empty handle is a no-op" {
    var w = Window{ .window = null };
    w.close();
    try std.testing.expect(w.raw() == null);
    resize(null, 1, 1);
}

test "window_macos: platform type is NSView" {
    try std.testing.expectEqualStrings("NSView", std.mem.span(platform_type.?));
}
