// Translated to Zig from soundcraft/crates/vst3-host/src/ffi/editor.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The VST3 editor: the host `IPlugFrame`, the `IPlugView` lifecycle (create, attach to a host
//! window, resize, remove) and `EditorLink`, the object that ties an instance to its editor and
//! state handles.
//!
//! Threading (kept from the Rust code). The instance may process on the audio thread while the
//! editor (the edit controller's `IPlugView`) is driven and the state is read from the main
//! thread, which is VST3's own threading model. Every such call happens under the link's lock,
//! and the instance closes the view and drops the component and controller references under the
//! same lock before it terminates (`EditorLink.kill`), so a handle never calls into a dead plugin.
//! `EditorLink` is reference counted: the instance holds one reference and every UI-side handle
//! holds another, so a handle outlives the instance and every call after the instance is gone is
//! a no-op (`kill` cleared the plugin pointers; the calls then return null / do nothing).
//!
//! The lock is a tiny spin lock and is taken only on control and UI threads. Nothing in this
//! file runs on the audio thread, and the audio thread never touches the link.
//!
//! Window calls are main-thread only. The platform window is the comptime-selected `Window`:
//! `window_macos.zig` on macOS (an `NSWindow`; `attached` gets its `NSView`), `window_other.zig`
//! elsewhere (a stub whose `Window.new` fails, `platform_type` null).
//!
//! Differences from the Rust code, all deliberate:
//! * `Arc<EditorLink>` is an explicit reference count (`retain` / `release`).
//! * `Mutex<EditorInner>` is a spin lock plus a plain struct (no `std.Io` is available inside a
//!   COM callback, and the lock is never contended for long).
//! * Errors are an error set instead of strings; `describe` gives the human-readable text.
//! * The state container is written by `saveState` with the allocator the caller passes.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const host = @import("host.zig");
const process_mod = @import("process.zig");

const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const vlog = std.log.scoped(.vst3);

/// The platform editor window, selected at comptime: `window_macos.zig` or `window_other.zig`.
pub const window = if (builtin.os.tag == .macos) @import("window_macos.zig") else @import("window_other.zig");
/// The host window type (`Window.new`, `raw`, `parent`, `raise`, `isVisible`, `close`).
pub const Window = window.Window;

/// Most pixels one side of an editor window may have.
pub const MAX_EDITOR_SIDE: i32 = 16_384;
/// Size the editor window starts with when the view reports none.
const DEFAULT_WIDTH: i32 = 400;
const DEFAULT_HEIGHT: i32 = 300;

pub const EditorError = error{
    /// The instance was destroyed (its controller is gone).
    PluginGone,
    /// The controller has no `"editor"` view.
    NoEditor,
    /// Window calls must run on the main thread.
    NotMainThread,
    /// This platform does not host VST3 editors.
    Unsupported,
    /// The view does not support this platform's window type.
    PlatformNotSupported,
    /// The view reports no size.
    NoSize,
    /// The host window could not be created.
    WindowFailed,
    /// The view refused to attach to its window.
    AttachFailed,
    OutOfMemory,
};

/// A human-readable text for an `EditorError` (the strings of the Rust code).
pub fn describe(e: EditorError) []const u8 {
    return switch (e) {
        error.PluginGone => "the plugin is gone",
        error.NoEditor => "this plugin has no editor",
        error.NotMainThread => "plugin editors must be opened on the main thread",
        error.Unsupported => "VST3 editors are not hosted on this platform yet",
        error.PlatformNotSupported => "the editor does not support this platform's windows",
        error.NoSize => "the editor reports no size",
        error.WindowFailed => "the editor window could not be created",
        error.AttachFailed => "the editor could not attach to its window",
        error.OutOfMemory => "out of memory",
    };
}

// ---- plain helpers -----------------------------------------------------------------------------

/// A view's size in pixels, as reported by `EditorLink.probe` and `Vst3Plugin.editorSize`.
pub const EditorSize = struct { w: u32, h: u32 };

/// Width and height of a view rect, clamped to a sane window size (1 to `MAX_EDITOR_SIDE`).
pub fn rectSize(r: abi.ViewRect) struct { w: f64, h: f64 } {
    const w = std.math.clamp(r.right -| r.left, 1, MAX_EDITOR_SIDE);
    const h = std.math.clamp(r.bottom -| r.top, 1, MAX_EDITOR_SIDE);
    return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

/// `normalizedParamToPlain` (not wrapped by `abi.IEditController`); null for a non-finite answer.
pub fn controllerToPlain(c: *abi.IEditController, id: abi.ParamID, normalized: f64) ?f64 {
    const v = c.vtbl.normalizedParamToPlain(c, id, std.math.clamp(normalized, 0.0, 1.0));
    return if (std.math.isFinite(v)) v else null;
}

/// `plainParamToNormalized`, clamped to 0..1; null for a non-finite input or answer.
pub fn controllerToNormalized(c: *abi.IEditController, id: abi.ParamID, plain: f64) ?f64 {
    if (!std.math.isFinite(plain)) return null;
    const v = c.vtbl.plainParamToNormalized(c, id, plain);
    return if (std.math.isFinite(v)) std.math.clamp(v, 0.0, 1.0) else null;
}

/// `getParamStringByValue` as UTF-8, owned by the caller; null when refused or empty.
pub fn controllerValueText(gpa: Allocator, c: *abi.IEditController, id: abi.ParamID, normalized: f64) Allocator.Error!?[]u8 {
    var s: abi.String128 = @splat(0);
    if (!abi.ok(c.getParamStringByValue(id, std.math.clamp(normalized, 0.0, 1.0), &s))) return null;
    const text = try abi.readC16(gpa, &s);
    if (text.len == 0) {
        gpa.free(text);
        return null;
    }
    return text;
}

/// Writes one object's state (`getState` of the component or controller) into a fresh memory
/// stream and returns the bytes (caller frees), or null when the object refuses. The stream is
/// bounded by `abi.MAX_STATE_BYTES`.
pub fn readState(gpa: Allocator, obj: anytype) Allocator.Error!?[]u8 {
    const stream = try process_mod.MemoryStream.create(gpa, &.{});
    defer stream.release();
    if (!abi.ok(obj.getState(stream.interface()))) return null;
    return try stream.take();
}

/// A tiny test-and-set lock for control and UI threads. Never use it on the audio thread.
const SpinLock = struct {
    locked: Atomic(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

// ---- IPlugFrame --------------------------------------------------------------------------------

/// The `IPlugFrame` handed to a plugin view: `resizeView` resizes our host window.
pub const PlugFrame = struct {
    iface: abi.IPlugFrame,
    refs: host.RefCount = .{},
    gpa: Allocator,
    /// The host window (an `NSWindow*` on macOS), not owned; null when there is none.
    window: Atomic(?*anyopaque) = .init(null),

    const U = host.Unknown(PlugFrame, "iface");

    /// The result has one reference, owned by the caller.
    pub fn create(gpa: Allocator, win: ?*anyopaque) Allocator.Error!*PlugFrame {
        const self = try gpa.create(PlugFrame);
        self.* = .{ .iface = .{ .vtbl = &vtbl }, .gpa = gpa };
        self.window.store(win, .monotonic);
        return self;
    }

    pub fn release(self: *PlugFrame) void {
        _ = U.vtbl.release(@ptrCast(&self.iface));
    }

    pub fn interface(self: *PlugFrame) *abi.IPlugFrame {
        return &self.iface;
    }

    pub fn queryImpl(self: *PlugFrame, id: *const abi.TUID) ?*anyopaque {
        if (std.mem.eql(u8, id, &abi.FUnknown.iid) or std.mem.eql(u8, id, &abi.IPlugFrame.iid)) return &self.iface;
        return null;
    }

    pub fn destroy(self: *PlugFrame) void {
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn resizeView(this: *abi.IPlugFrame, view: *abi.IPlugView, new_size: *abi.ViewRect) callconv(.c) abi.tresult {
        const self: *PlugFrame = @fieldParentPtr("iface", this);
        const wh = rectSize(new_size.*);
        window.resize(self.window.load(.monotonic), wh.w, wh.h);
        _ = view.onSize(new_size);
        return abi.kResultOk;
    }

    const vtbl: abi.IPlugFrame.Vtbl = .{ .unknown = U.vtbl, .resizeView = resizeView };
};

// ---- the link ----------------------------------------------------------------------------------

/// What the lock protects. Every pointer is an owned COM reference (or null once cleared).
pub const EditorInner = struct {
    /// Null once the instance is gone.
    component: ?*abi.IComponent = null,
    /// Null once the instance is gone, or without an edit controller.
    controller: ?*abi.IEditController = null,
    view: ?*abi.IPlugView = null,
    frame: ?*PlugFrame = null,
    window: ?Window = null,
};

/// The link between an instance and its editor and state handles (see the module docs).
pub const EditorLink = struct {
    gpa: Allocator,
    refs: Atomic(usize) = .init(1),
    mutex: SpinLock = .{},
    inner: EditorInner = .{},

    /// An empty link with one reference, owned by the caller. `bind` it to a component.
    pub fn create(gpa: Allocator) Allocator.Error!*EditorLink {
        const self = try gpa.create(EditorLink);
        self.* = .{ .gpa = gpa };
        return self;
    }

    /// Adds a reference (for a UI-side handle).
    pub fn retain(self: *EditorLink) *EditorLink {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    /// Drops a reference; the last one frees the link (and any plugin references it still holds).
    pub fn release(self: *EditorLink) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const g = &self.inner;
        // `kill` normally ran already; a link dropped without it has no open editor.
        std.debug.assert(g.view == null and g.window == null and g.frame == null);
        if (g.controller) |c| _ = abi.comRelease(c);
        if (g.component) |c| _ = abi.comRelease(c);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Gives the link its own references on the component and controller.
    pub fn bind(self: *EditorLink, component: *abi.IComponent, controller: ?*abi.IEditController) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = abi.comAddRef(component);
        if (controller) |c| _ = abi.comAddRef(c);
        self.inner.component = component;
        self.inner.controller = controller;
    }

    pub fn hasController(self: *EditorLink) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.inner.controller != null;
    }

    /// Creates the view of the `"editor"` kind. The result owns one reference.
    fn createView(g: *EditorInner) EditorError!*abi.IPlugView {
        const c = g.controller orelse return error.PluginGone;
        return c.createView("editor") orelse error.NoEditor;
    }

    /// Creates the view, checks it supports this platform's window type and reads its size,
    /// without attaching it anywhere. For diagnostics and tests.
    pub fn probe(self: *EditorLink) EditorError!EditorSize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const view = try createView(&self.inner);
        defer _ = abi.comRelease(view);
        const platform = window.platform_type orelse return error.Unsupported;
        if (view.isPlatformTypeSupported(platform) != abi.kResultTrue) return error.PlatformNotSupported;
        var r: abi.ViewRect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        if (!abi.ok(view.getSize(&r))) return error.NoSize;
        const wh = rectSize(r);
        return .{ .w = @intFromFloat(wh.w), .h = @intFromFloat(wh.h) };
    }

    /// Opens (or raises) the editor in a host window. Main thread only.
    pub fn open(self: *EditorLink, title: []const u8) EditorError!void {
        if (!window.onMainThread()) return error.NotMainThread;
        const platform = window.platform_type orelse return error.Unsupported;
        self.mutex.lock();
        defer self.mutex.unlock();
        const g = &self.inner;
        if (g.window) |*w| {
            if (w.isVisible()) {
                w.raise();
                return;
            }
            // The user closed the window: start over.
            teardown(g);
        }
        const view = try createView(g);
        var kept = false;
        defer if (!kept) {
            _ = abi.comRelease(view);
        };
        if (view.isPlatformTypeSupported(platform) != abi.kResultTrue) return error.PlatformNotSupported;
        var r: abi.ViewRect = .{ .left = 0, .top = 0, .right = DEFAULT_WIDTH, .bottom = DEFAULT_HEIGHT };
        // On failure the default size stays.
        _ = view.getSize(&r);
        const wh = rectSize(r);
        var win = Window.new(title, wh.w, wh.h) catch return error.WindowFailed;
        const frame = PlugFrame.create(self.gpa, win.raw()) catch {
            win.close();
            return error.OutOfMemory;
        };
        // The frame outlives the view's attachment (kept in `g.frame`, detached in `teardown`).
        _ = view.setFrame(frame.interface());
        if (!abi.ok(view.attached(win.parent(), platform))) {
            _ = view.setFrame(null);
            frame.release();
            win.close();
            return error.AttachFailed;
        }
        win.raise();
        g.view = view;
        g.frame = frame;
        g.window = win;
        kept = true;
    }

    /// Detaches and releases the view, the frame and the window. Main thread only; the caller
    /// holds the lock (or has exclusive access).
    fn teardown(g: *EditorInner) void {
        if (g.view) |view| {
            g.view = null;
            // `removed` before the window goes, and the frame is detached before it is released.
            _ = view.removed();
            _ = view.setFrame(null);
            _ = abi.comRelease(view);
        }
        if (g.frame) |f| {
            g.frame = null;
            f.release();
        }
        if (g.window) |*w| {
            w.close();
            g.window = null;
        }
    }

    /// Hands a host-set value to the controller before a state save (`setParamNormalized`, under
    /// the lock like `saveState`). No-op once the instance is gone.
    pub fn syncParam(self: *EditorLink, id: u32, n: f64) void {
        if (!std.math.isFinite(n)) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.inner.controller) |c| _ = c.setParamNormalized(id, std.math.clamp(n, 0.0, 1.0));
    }

    /// The component state plus the controller state, in Seridian's container (see
    /// `abi.STATE_MAGIC`), allocated with `gpa`. Null when the component refuses `getState` or
    /// the instance is gone.
    pub fn saveState(self: *EditorLink, gpa: Allocator) Allocator.Error!?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const g = &self.inner;
        const component = g.component orelse return null;
        const comp = (try readState(gpa, component)) orelse return null;
        defer gpa.free(comp);
        var ctrl: []u8 = &.{};
        if (g.controller) |c| {
            if (try readState(gpa, c)) |s| ctrl = s;
        }
        defer if (ctrl.len > 0) gpa.free(ctrl);
        const comp_len = std.math.cast(u32, comp.len) orelse return null;
        const ctrl_len = std.math.cast(u32, ctrl.len) orelse return null;
        const out = try gpa.alloc(u8, 12 + comp.len + ctrl.len);
        @memcpy(out[0..4], abi.STATE_MAGIC);
        std.mem.writeInt(u32, out[4..8], comp_len, .little);
        @memcpy(out[8..][0..comp.len], comp);
        const at = 8 + comp.len;
        std.mem.writeInt(u32, out[at..][0..4], ctrl_len, .little);
        @memcpy(out[at + 4 ..][0..ctrl.len], ctrl);
        return out;
    }

    /// Closes the editor. Main thread only (no-op elsewhere).
    pub fn close(self: *EditorLink) void {
        if (!window.onMainThread()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        teardown(&self.inner);
    }

    pub fn isOpen(self: *EditorLink) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.inner.window) |*w| {
            return if (window.onMainThread()) w.isVisible() else true;
        }
        return false;
    }

    /// Main-thread housekeeping: tears the view down when the user closed its window.
    pub fn idle(self: *EditorLink) void {
        if (!window.onMainThread()) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.inner.window) |*w| {
            if (!w.isVisible()) teardown(&self.inner);
        }
    }

    /// Normalized to plain through the controller (null once the instance is gone).
    pub fn toPlain(self: *EditorLink, id: u32, n: f64) ?f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const c = self.inner.controller orelse return null;
        return controllerToPlain(c, id, n);
    }

    /// Plain to normalized through the controller.
    pub fn toNormalized(self: *EditorLink, id: u32, plain: f64) ?f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const c = self.inner.controller orelse return null;
        return controllerToNormalized(c, id, plain);
    }

    /// The plugin's own text for a normalized value (`getParamStringByValue`), owned by the
    /// caller. Main thread only (null elsewhere, and once the instance is gone).
    pub fn valueText(self: *EditorLink, gpa: Allocator, id: u32, n: f64) Allocator.Error!?[]u8 {
        if (!window.onMainThread() or !std.math.isFinite(n)) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        const c = self.inner.controller orelse return null;
        return controllerValueText(gpa, c, id, n);
    }

    /// Shows a value change in the editor (`setParamNormalized`, main thread).
    pub fn setNormalized(self: *EditorLink, id: u32, n: f64) void {
        if (!window.onMainThread() or !std.math.isFinite(n)) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.inner.controller) |c| _ = c.setParamNormalized(id, std.math.clamp(n, 0.0, 1.0));
    }

    /// Called by the instance before it terminates: closes the editor and cuts the handles off.
    /// Returns whether plugin objects had to be leaked (then the module must never be exited).
    pub fn kill(self: *EditorLink) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const g = &self.inner;
        var leaked = false;
        if (g.view != null or g.window != null) {
            if (window.onMainThread()) {
                teardown(g);
            } else {
                // Window calls are main-thread only; leak the view and window rather than crash.
                vlog.warn("editor still open while its plugin is destroyed off the main thread", .{});
                if (g.view != null) {
                    g.view = null;
                    leaked = true;
                }
                // `Window` has no destructor of its own: dropping it leaks its retain on purpose.
                g.window = null;
                g.frame = null;
            }
        }
        if (g.component) |c| _ = abi.comRelease(c);
        if (g.controller) |c| _ = abi.comRelease(c);
        g.component = null;
        g.controller = null;
        return leaked;
    }
};

/// A UI-thread handle on an instance's editor. It keeps the link alive, not the plugin: after
/// the instance is destroyed every call is a no-op (`open` reports `error.PluginGone`).
pub const EditorHandle = struct {
    link: *EditorLink,

    /// Takes its own reference on `link`.
    pub fn init(link: *EditorLink) EditorHandle {
        return .{ .link = link.retain() };
    }

    pub fn deinit(self: *EditorHandle) void {
        self.link.release();
        self.* = undefined;
    }

    pub fn open(self: EditorHandle, title: []const u8) EditorError!void {
        return self.link.open(title);
    }
    pub fn close(self: EditorHandle) void {
        self.link.close();
    }
    pub fn isOpen(self: EditorHandle) bool {
        return self.link.isOpen();
    }
    pub fn idle(self: EditorHandle) void {
        self.link.idle();
    }
    pub fn setNormalized(self: EditorHandle, id: u32, n: f64) void {
        self.link.setNormalized(id, n);
    }
};

// ---- test fixture: an in-process fake VST3 plugin ------------------------------------------------

/// A scriptable fake plugin used by the tests of this file and of `instance.zig`. It implements
/// the component, audio processor, edit controller and connection point interfaces as real COM
/// objects, records the calls that matter for ordering, and can be a single-component plugin or
/// the component half or controller half of a split one.
pub const fixture = if (builtin.is_test) struct {
    pub const Call = enum {
        initialize,
        terminate,
        set_active_true,
        set_active_false,
        set_processing_true,
        set_processing_false,
        connect,
        disconnect,
        handler_set,
        handler_cleared,
        component_state_set,
        view_removed,
        view_frame_set,
        view_frame_cleared,
        destroyed,
    };

    /// Shared by all objects of one fake plugin.
    pub const Log = struct {
        calls: [128]Call = undefined,
        n: usize = 0,
        /// Tag of the object that made the call, parallel to `calls` (0 component, 1 controller).
        who: [128]u8 = undefined,
        process_calls: u32 = 0,
        last_num_samples: i32 = 0,
        last_num_inputs: i32 = 0,
        last_num_outputs: i32 = 0,
        last_param_count: i32 = 0,
        last_event_count: i32 = 0,
        last_tempo: f64 = 0,
        process_result: abi.tresult = abi.kResultOk,
        views_created: u32 = 0,
        view_attached: u32 = 0,
        view_removed: u32 = 0,
        view_on_size: u32 = 0,
        last_on_size: abi.ViewRect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        frame_set: bool = false,
        param_sets: u32 = 0,
        last_param_set_value: f64 = -1,
        arrangements_set: u32 = 0,

        pub fn add(self: *Log, c: Call, who: u8) void {
            if (self.n < self.calls.len) {
                self.calls[self.n] = c;
                self.who[self.n] = who;
                self.n += 1;
            }
        }

        pub fn count(self: *const Log, c: Call) usize {
            var k: usize = 0;
            for (self.calls[0..self.n]) |x| {
                if (x == c) k += 1;
            }
            return k;
        }

        pub fn indexOf(self: *const Log, c: Call, who: u8) ?usize {
            for (self.calls[0..self.n], 0..) |x, i| {
                if (x == c and self.who[i] == who) return i;
            }
            return null;
        }
    };

    pub const FakeParam = struct {
        id: u32,
        title: []const u8,
        units: []const u8 = "",
        step_count: i32 = 0,
        default: f64 = 0,
        flags: i32 = abi.kCanAutomate,
        /// Plain range: plain = min + normalized * (max - min).
        min: f64 = 0,
        max: f64 = 1,
    };

    pub const Kind = enum { single, component, controller };

    pub const BusSpec = struct { arrangement: u64, accepts_any: bool = true };

    pub const kMono: u64 = 1 << 19;
    pub const kStereo: u64 = 3;

    pub const Config = struct {
        in_buses: []const u64 = &.{kStereo},
        out_buses: []const u64 = &.{kStereo},
        event_in: bool = false,
        /// Refuse `setBusArrangements` when the first input is mono.
        refuse_mono: bool = false,
        /// Refuse every `setBusArrangements`.
        refuse_all: bool = false,
        can_32: bool = true,
        setup_ok: bool = true,
        set_active_ok: bool = true,
        initialize_ok: bool = true,
        /// Whether the controller half of a split plugin initialises.
        controller_initialize_ok: bool = true,
        latency: u32 = 0,
        tail: u32 = 0,
        params: []const FakeParam = &.{},
        has_view: bool = true,
        view_w: i32 = 640,
        view_h: i32 = 480,
        view_supports_platform: bool = true,
        view_attach_ok: bool = true,
        /// State bytes the component writes with `getState`.
        comp_state: []const u8 = "COMP",
        ctrl_state: []const u8 = "CTRL",
        refuse_set_state: bool = false,
        has_midi_mapping: bool = false,
        /// Class ids for a split plugin.
        controller_cid: [16]u8 = @splat(0xC7),
        no_processor: bool = false,
        /// `getBusArrangement` fails; `getBusInfo` reports `info_channels` for every bus.
        no_arrangement: bool = false,
        info_channels: i32 = 2,
    };

    pub const View = struct {
        iface: abi.IPlugView,
        refs: host.RefCount = .{},
        gpa: Allocator,
        cfg: *const Config,
        log: *Log,

        const U = host.Unknown(View, "iface");

        pub fn queryImpl(self: *View, id: *const abi.TUID) ?*anyopaque {
            if (std.mem.eql(u8, id, &abi.FUnknown.iid) or std.mem.eql(u8, id, &abi.IPlugView.iid)) return &self.iface;
            return null;
        }
        pub fn destroy(self: *View) void {
            self.gpa.destroy(self);
        }
        fn s(this: *abi.IPlugView) *View {
            return @fieldParentPtr("iface", this);
        }
        fn isPlatformTypeSupported(this: *abi.IPlugView, _: [*:0]const u8) callconv(.c) abi.tresult {
            return if (s(this).cfg.view_supports_platform) abi.kResultTrue else abi.kResultFalse;
        }
        fn attached(this: *abi.IPlugView, _: ?*anyopaque, _: [*:0]const u8) callconv(.c) abi.tresult {
            const v = s(this);
            v.log.view_attached += 1;
            return if (v.cfg.view_attach_ok) abi.kResultOk else abi.kInternalError;
        }
        fn removed(this: *abi.IPlugView) callconv(.c) abi.tresult {
            const v = s(this);
            v.log.view_removed += 1;
            v.log.add(.view_removed, 1);
            return abi.kResultOk;
        }
        fn onWheel(_: *abi.IPlugView, _: f32) callconv(.c) abi.tresult {
            return abi.kResultFalse;
        }
        fn onKey(_: *abi.IPlugView, _: u16, _: i16, _: i16) callconv(.c) abi.tresult {
            return abi.kResultFalse;
        }
        fn getSize(this: *abi.IPlugView, size: *abi.ViewRect) callconv(.c) abi.tresult {
            const v = s(this);
            if (v.cfg.view_w < 0) return abi.kInternalError;
            size.* = .{ .left = 0, .top = 0, .right = v.cfg.view_w, .bottom = v.cfg.view_h };
            return abi.kResultOk;
        }
        fn onSize(this: *abi.IPlugView, size: *abi.ViewRect) callconv(.c) abi.tresult {
            const v = s(this);
            v.log.view_on_size += 1;
            v.log.last_on_size = size.*;
            return abi.kResultOk;
        }
        fn onFocus(_: *abi.IPlugView, _: abi.TBool) callconv(.c) abi.tresult {
            return abi.kResultOk;
        }
        fn setFrame(this: *abi.IPlugView, frame: ?*abi.IPlugFrame) callconv(.c) abi.tresult {
            const v = s(this);
            v.log.frame_set = frame != null;
            v.log.add(if (frame != null) .view_frame_set else .view_frame_cleared, 1);
            return abi.kResultOk;
        }
        fn canResize(_: *abi.IPlugView) callconv(.c) abi.tresult {
            return abi.kResultTrue;
        }
        fn checkSizeConstraint(_: *abi.IPlugView, _: *abi.ViewRect) callconv(.c) abi.tresult {
            return abi.kResultOk;
        }
        const vtbl: abi.IPlugView.Vtbl = .{
            .unknown = U.vtbl,
            .isPlatformTypeSupported = isPlatformTypeSupported,
            .attached = attached,
            .removed = removed,
            .onWheel = onWheel,
            .onKeyDown = onKey,
            .onKeyUp = onKey,
            .getSize = getSize,
            .onSize = onSize,
            .onFocus = onFocus,
            .setFrame = setFrame,
            .canResize = canResize,
            .checkSizeConstraint = checkSizeConstraint,
        };
    };

    /// One fake plugin object. Which interfaces `queryInterface` hands out depends on `kind`.
    pub const Obj = struct {
        comp: abi.IComponent,
        proc: abi.IAudioProcessor,
        ctrl: abi.IEditController,
        conn: abi.IConnectionPoint,
        midi: abi.IMidiMapping,
        refs: host.RefCount = .{},
        gpa: Allocator,
        kind: Kind,
        cfg: *const Config,
        log: *Log,
        /// Parameter values (normalized), parallel to `cfg.params`.
        values: [16]f64 = @splat(0),
        in_arr: [32]u64 = @splat(0),
        out_arr: [32]u64 = @splat(0),
        peer: ?*abi.IConnectionPoint = null,
        handler: ?*abi.IComponentHandler = null,

        const UC = host.Unknown(Obj, "comp");
        const UP = host.Unknown(Obj, "proc");
        const UE = host.Unknown(Obj, "ctrl");
        const UN = host.Unknown(Obj, "conn");
        const UM = host.Unknown(Obj, "midi");

        fn who(self: *const Obj) u8 {
            return if (self.kind == .controller) 1 else 0;
        }

        pub fn create(gpa: Allocator, kind: Kind, cfg: *const Config, log: *Log) !*Obj {
            const self = try gpa.create(Obj);
            self.* = .{
                .comp = .{ .vtbl = &comp_vtbl },
                .proc = .{ .vtbl = &proc_vtbl },
                .ctrl = .{ .vtbl = &ctrl_vtbl },
                .conn = .{ .vtbl = &conn_vtbl },
                .midi = .{ .vtbl = &midi_vtbl },
                .gpa = gpa,
                .kind = kind,
                .cfg = cfg,
                .log = log,
            };
            for (cfg.in_buses, 0..) |a, i| self.in_arr[i] = a;
            for (cfg.out_buses, 0..) |a, i| self.out_arr[i] = a;
            for (cfg.params, 0..) |p, i| self.values[i] = p.default;
            return self;
        }

        pub fn release(self: *Obj) void {
            _ = UC.vtbl.release(@ptrCast(&self.comp));
        }

        pub fn queryImpl(self: *Obj, id: *const abi.TUID) ?*anyopaque {
            const eq = struct {
                fn f(a: *const abi.TUID, comptime T: type) bool {
                    return std.mem.eql(u8, a, &T.iid);
                }
            }.f;
            const has_comp = self.kind != .controller;
            const has_ctrl = self.kind != .component;
            if (eq(id, abi.FUnknown) or eq(id, abi.IPluginBase)) return if (has_comp) @as(?*anyopaque, &self.comp) else &self.ctrl;
            if (has_comp and eq(id, abi.IComponent)) return &self.comp;
            if (has_comp and !self.cfg.no_processor and eq(id, abi.IAudioProcessor)) return &self.proc;
            if (has_ctrl and eq(id, abi.IEditController)) return &self.ctrl;
            if (self.kind != .single and eq(id, abi.IConnectionPoint)) return &self.conn;
            if (has_ctrl and self.cfg.has_midi_mapping and eq(id, abi.IMidiMapping)) return &self.midi;
            return null;
        }

        pub fn destroy(self: *Obj) void {
            self.log.add(.destroyed, self.who());
            if (self.handler) |h| _ = abi.comRelease(h);
            self.gpa.destroy(self);
        }

        // component
        fn cs(this: *abi.IComponent) *Obj {
            return @fieldParentPtr("comp", this);
        }
        fn initialize(this: *abi.IPluginBase, _: ?*abi.FUnknown) callconv(.c) abi.tresult {
            const self: *Obj = @fieldParentPtr("comp", @as(*abi.IComponent, @ptrCast(this)));
            self.log.add(.initialize, self.who());
            return if (self.cfg.initialize_ok) abi.kResultOk else abi.kInternalError;
        }
        fn terminate(this: *abi.IPluginBase) callconv(.c) abi.tresult {
            const self: *Obj = @fieldParentPtr("comp", @as(*abi.IComponent, @ptrCast(this)));
            self.log.add(.terminate, self.who());
            return abi.kResultOk;
        }
        fn initializeC(this: *abi.IPluginBase, _: ?*abi.FUnknown) callconv(.c) abi.tresult {
            const self: *Obj = @fieldParentPtr("ctrl", @as(*abi.IEditController, @ptrCast(this)));
            self.log.add(.initialize, self.who());
            return if (self.cfg.controller_initialize_ok) abi.kResultOk else abi.kInternalError;
        }
        fn terminateC(this: *abi.IPluginBase) callconv(.c) abi.tresult {
            const self: *Obj = @fieldParentPtr("ctrl", @as(*abi.IEditController, @ptrCast(this)));
            self.log.add(.terminate, self.who());
            return abi.kResultOk;
        }
        fn getControllerClassId(this: *abi.IComponent, out: *abi.TUID) callconv(.c) abi.tresult {
            const self = cs(this);
            if (self.kind == .single) return abi.kNotImplemented;
            out.* = self.cfg.controller_cid;
            return abi.kResultOk;
        }
        fn setIoMode(_: *abi.IComponent, _: abi.IoMode) callconv(.c) abi.tresult {
            return abi.kResultOk;
        }
        fn getBusCount(this: *abi.IComponent, t: abi.MediaType, dir: abi.BusDirection) callconv(.c) i32 {
            const self = cs(this);
            if (t == abi.kEvent) return if (dir == abi.kInput and self.cfg.event_in) 1 else 0;
            return @intCast(if (dir == abi.kInput) self.cfg.in_buses.len else self.cfg.out_buses.len);
        }
        fn getBusInfo(this: *abi.IComponent, _: abi.MediaType, dir: abi.BusDirection, index: i32, bus: *abi.BusInfo) callconv(.c) abi.tresult {
            const self = cs(this);
            const list = if (dir == abi.kInput) self.cfg.in_buses else self.cfg.out_buses;
            const i: usize = @intCast(index);
            if (i >= list.len) return abi.kInvalidArgument;
            bus.channelCount = if (self.cfg.no_arrangement) self.cfg.info_channels else @intCast(@popCount(list[i]));
            return abi.kResultOk;
        }
        fn getRoutingInfo(_: *abi.IComponent, _: *abi.RoutingInfo, _: *abi.RoutingInfo) callconv(.c) abi.tresult {
            return abi.kNotImplemented;
        }
        fn activateBus(_: *abi.IComponent, _: abi.MediaType, _: abi.BusDirection, _: i32, _: abi.TBool) callconv(.c) abi.tresult {
            return abi.kResultOk;
        }
        fn setActive(this: *abi.IComponent, state: abi.TBool) callconv(.c) abi.tresult {
            const self = cs(this);
            self.log.add(if (state != 0) .set_active_true else .set_active_false, self.who());
            return if (state != 0 and !self.cfg.set_active_ok) abi.kInternalError else abi.kResultOk;
        }
        fn setState(this: *abi.IComponent, stream: *abi.IBStream) callconv(.c) abi.tresult {
            const self = cs(this);
            if (self.cfg.refuse_set_state) return abi.kResultFalse;
            var buf: [64]u8 = undefined;
            var got: i32 = 0;
            _ = stream.read(&buf, buf.len, &got);
            self.log.add(.component_state_set, self.who());
            return abi.kResultOk;
        }
        fn writeAll(stream: *abi.IBStream, bytes: []const u8) abi.tresult {
            var put: i32 = 0;
            const r = stream.write(@constCast(bytes.ptr), @intCast(bytes.len), &put);
            return r;
        }
        fn getState(this: *abi.IComponent, stream: *abi.IBStream) callconv(.c) abi.tresult {
            return writeAll(stream, cs(this).cfg.comp_state);
        }

        // processor
        fn ps(this: *abi.IAudioProcessor) *Obj {
            return @fieldParentPtr("proc", this);
        }
        fn setBusArrangements(this: *abi.IAudioProcessor, ins: ?[*]abi.SpeakerArrangement, n_in: i32, outs: ?[*]abi.SpeakerArrangement, n_out: i32) callconv(.c) abi.tresult {
            const self = ps(this);
            self.log.arrangements_set += 1;
            if (self.cfg.refuse_all) return abi.kResultFalse;
            if (n_in > 0 and self.cfg.refuse_mono and ins.?[0] == kMono) return abi.kResultFalse;
            var i: usize = 0;
            while (i < @as(usize, @intCast(n_in))) : (i += 1) self.in_arr[i] = ins.?[i];
            i = 0;
            while (i < @as(usize, @intCast(n_out))) : (i += 1) self.out_arr[i] = outs.?[i];
            return abi.kResultTrue;
        }
        fn getBusArrangement(this: *abi.IAudioProcessor, dir: abi.BusDirection, index: i32, arr: *abi.SpeakerArrangement) callconv(.c) abi.tresult {
            const self = ps(this);
            if (self.cfg.no_arrangement) return abi.kNotImplemented;
            const i: usize = @intCast(index);
            arr.* = if (dir == abi.kInput) self.in_arr[i] else self.out_arr[i];
            return abi.kResultOk;
        }
        fn canProcessSampleSize(this: *abi.IAudioProcessor, size: i32) callconv(.c) abi.tresult {
            return if (size == abi.kSample32 and ps(this).cfg.can_32) abi.kResultTrue else abi.kResultFalse;
        }
        fn getLatencySamples(this: *abi.IAudioProcessor) callconv(.c) u32 {
            return ps(this).cfg.latency;
        }
        fn setupProcessing(this: *abi.IAudioProcessor, _: *abi.ProcessSetup) callconv(.c) abi.tresult {
            return if (ps(this).cfg.setup_ok) abi.kResultOk else abi.kInternalError;
        }
        fn setProcessing(this: *abi.IAudioProcessor, state: abi.TBool) callconv(.c) abi.tresult {
            const self = ps(this);
            self.log.add(if (state != 0) .set_processing_true else .set_processing_false, self.who());
            return abi.kNotImplemented;
        }
        fn process(this: *abi.IAudioProcessor, data: *abi.ProcessData) callconv(.c) abi.tresult {
            const self = ps(this);
            const l = self.log;
            l.process_calls += 1;
            l.last_num_samples = data.numSamples;
            l.last_num_inputs = data.numInputs;
            l.last_num_outputs = data.numOutputs;
            l.last_param_count = if (data.inputParameterChanges) |p| p.getParameterCount() else -1;
            l.last_event_count = if (data.inputEvents) |e| e.getEventCount() else -1;
            l.last_tempo = if (data.processContext) |c| c.tempo else -1;
            // Double the first input channel into the first output channel.
            if (data.numInputs > 0 and data.numOutputs > 0) {
                const in = data.inputs.?[0];
                const out = data.outputs.?[0];
                if (in.channelBuffers.channelBuffers32) |ic| {
                    if (out.channelBuffers.channelBuffers32) |oc| {
                        const n: usize = @intCast(data.numSamples);
                        for (0..n) |k| oc[0].?[k] = ic[0].?[k] * 2.0;
                    }
                }
            }
            return l.process_result;
        }
        fn getTailSamples(this: *abi.IAudioProcessor) callconv(.c) u32 {
            return ps(this).cfg.tail;
        }

        // controller
        fn es(this: *abi.IEditController) *Obj {
            return @fieldParentPtr("ctrl", this);
        }
        fn setComponentState(this: *abi.IEditController, stream: *abi.IBStream) callconv(.c) abi.tresult {
            const self = es(this);
            var buf: [64]u8 = undefined;
            var got: i32 = 0;
            _ = stream.read(&buf, buf.len, &got);
            self.log.add(.component_state_set, 1);
            return abi.kResultOk;
        }
        fn setStateC(_: *abi.IEditController, _: *abi.IBStream) callconv(.c) abi.tresult {
            return abi.kResultOk;
        }
        fn getStateC(this: *abi.IEditController, stream: *abi.IBStream) callconv(.c) abi.tresult {
            return writeAll(stream, es(this).cfg.ctrl_state);
        }
        fn getParameterCount(this: *abi.IEditController) callconv(.c) i32 {
            return @intCast(es(this).cfg.params.len);
        }
        fn getParameterInfo(this: *abi.IEditController, index: i32, info: *abi.ParameterInfo) callconv(.c) abi.tresult {
            const self = es(this);
            const i: usize = @intCast(index);
            if (i >= self.cfg.params.len) return abi.kInvalidArgument;
            const p = self.cfg.params[i];
            info.* = std.mem.zeroes(abi.ParameterInfo);
            info.id = p.id;
            abi.writeC16(p.title, &info.title);
            abi.writeC16(p.units, &info.units);
            info.stepCount = p.step_count;
            info.defaultNormalizedValue = p.default;
            info.flags = p.flags;
            return abi.kResultOk;
        }
        fn paramIndex(self: *Obj, id: u32) ?usize {
            for (self.cfg.params, 0..) |p, i| {
                if (p.id == id) return i;
            }
            return null;
        }
        fn getParamStringByValue(this: *abi.IEditController, id: u32, v: f64, out: *abi.String128) callconv(.c) abi.tresult {
            const self = es(this);
            const i = self.paramIndex(id) orelse return abi.kInvalidArgument;
            const p = self.cfg.params[i];
            if (p.step_count > 1) {
                var buf: [32]u8 = undefined;
                const idx: i32 = @intFromFloat(@round(v * @as(f64, @floatFromInt(p.step_count))));
                const t = std.fmt.bufPrint(&buf, "Choice{d}", .{idx}) catch return abi.kInternalError;
                abi.writeC16(t, out);
                return abi.kResultOk;
            }
            var buf: [32]u8 = undefined;
            const t = std.fmt.bufPrint(&buf, "{d:.1}", .{p.min + v * (p.max - p.min)}) catch return abi.kInternalError;
            abi.writeC16(t, out);
            return abi.kResultOk;
        }
        fn getParamValueByString(_: *abi.IEditController, _: u32, _: [*:0]const u16, _: *f64) callconv(.c) abi.tresult {
            return abi.kNotImplemented;
        }
        fn normalizedParamToPlain(this: *abi.IEditController, id: u32, v: f64) callconv(.c) f64 {
            const self = es(this);
            const i = self.paramIndex(id) orelse return std.math.nan(f64);
            const p = self.cfg.params[i];
            return p.min + v * (p.max - p.min);
        }
        fn plainParamToNormalized(this: *abi.IEditController, id: u32, plain: f64) callconv(.c) f64 {
            const self = es(this);
            const i = self.paramIndex(id) orelse return std.math.nan(f64);
            const p = self.cfg.params[i];
            return (plain - p.min) / (p.max - p.min);
        }
        fn getParamNormalized(this: *abi.IEditController, id: u32) callconv(.c) f64 {
            const self = es(this);
            const i = self.paramIndex(id) orelse return std.math.nan(f64);
            return self.values[i];
        }
        fn setParamNormalized(this: *abi.IEditController, id: u32, v: f64) callconv(.c) abi.tresult {
            const self = es(this);
            const i = self.paramIndex(id) orelse return abi.kInvalidArgument;
            self.values[i] = v;
            self.log.param_sets += 1;
            self.log.last_param_set_value = v;
            return abi.kResultOk;
        }
        fn setComponentHandler(this: *abi.IEditController, h: ?*abi.IComponentHandler) callconv(.c) abi.tresult {
            const self = es(this);
            if (h) |p| _ = abi.comAddRef(p);
            if (self.handler) |old| _ = abi.comRelease(old);
            self.handler = h;
            self.log.add(if (h != null) .handler_set else .handler_cleared, 1);
            return abi.kResultOk;
        }
        fn createView(this: *abi.IEditController, _: [*:0]const u8) callconv(.c) ?*abi.IPlugView {
            const self = es(this);
            if (!self.cfg.has_view) return null;
            const v = self.gpa.create(View) catch return null;
            v.* = .{ .iface = .{ .vtbl = &View.vtbl }, .gpa = self.gpa, .cfg = self.cfg, .log = self.log };
            self.log.views_created += 1;
            return &v.iface;
        }

        // connection point
        fn ns(this: *abi.IConnectionPoint) *Obj {
            return @fieldParentPtr("conn", this);
        }
        fn connect(this: *abi.IConnectionPoint, other: *abi.IConnectionPoint) callconv(.c) abi.tresult {
            const self = ns(this);
            self.peer = other;
            self.log.add(.connect, self.who());
            return abi.kResultOk;
        }
        fn disconnect(this: *abi.IConnectionPoint, _: *abi.IConnectionPoint) callconv(.c) abi.tresult {
            const self = ns(this);
            self.peer = null;
            self.log.add(.disconnect, self.who());
            return abi.kResultOk;
        }
        fn notify(_: *abi.IConnectionPoint, _: ?*abi.IMessage) callconv(.c) abi.tresult {
            return abi.kResultOk;
        }

        // midi mapping: CC 1 drives the second parameter, pitch bend the first
        fn getMidiControllerAssignment(this: *abi.IMidiMapping, _: i32, _: i16, cc: i16, id: *abi.ParamID) callconv(.c) abi.tresult {
            const self: *Obj = @fieldParentPtr("midi", this);
            if (cc == 1 and self.cfg.params.len > 1) {
                id.* = self.cfg.params[1].id;
                return abi.kResultOk;
            }
            if (cc == @as(i16, @intCast(abi.PITCH_BEND)) and self.cfg.params.len > 0) {
                id.* = self.cfg.params[0].id;
                return abi.kResultOk;
            }
            return abi.kResultFalse;
        }

        const comp_vtbl: abi.IComponent.Vtbl = .{
            .base = .{ .unknown = UC.vtbl, .initialize = initialize, .terminate = terminate },
            .getControllerClassId = getControllerClassId,
            .setIoMode = setIoMode,
            .getBusCount = getBusCount,
            .getBusInfo = getBusInfo,
            .getRoutingInfo = getRoutingInfo,
            .activateBus = activateBus,
            .setActive = setActive,
            .setState = setState,
            .getState = getState,
        };
        const proc_vtbl: abi.IAudioProcessor.Vtbl = .{
            .unknown = UP.vtbl,
            .setBusArrangements = setBusArrangements,
            .getBusArrangement = getBusArrangement,
            .canProcessSampleSize = canProcessSampleSize,
            .getLatencySamples = getLatencySamples,
            .setupProcessing = setupProcessing,
            .setProcessing = setProcessing,
            .process = process,
            .getTailSamples = getTailSamples,
        };
        const ctrl_vtbl: abi.IEditController.Vtbl = .{
            .base = .{ .unknown = UE.vtbl, .initialize = initializeC, .terminate = terminateC },
            .setComponentState = setComponentState,
            .setState = setStateC,
            .getState = getStateC,
            .getParameterCount = getParameterCount,
            .getParameterInfo = getParameterInfo,
            .getParamStringByValue = getParamStringByValue,
            .getParamValueByString = getParamValueByString,
            .normalizedParamToPlain = normalizedParamToPlain,
            .plainParamToNormalized = plainParamToNormalized,
            .getParamNormalized = getParamNormalized,
            .setParamNormalized = setParamNormalized,
            .setComponentHandler = setComponentHandler,
            .createView = createView,
        };
        const conn_vtbl: abi.IConnectionPoint.Vtbl = .{ .unknown = UN.vtbl, .connect = connect, .disconnect = disconnect, .notify = notify };
        const midi_vtbl: abi.IMidiMapping.Vtbl = .{ .unknown = UM.vtbl, .getMidiControllerAssignment = getMidiControllerAssignment };
    };

    /// A plugin factory that makes `Obj`s: class id `comp_cid` is the component (single or the
    /// component half), `cfg.controller_cid` the controller half.
    pub const Factory = struct {
        iface: abi.IPluginFactory,
        refs: host.RefCount = .{},
        gpa: Allocator,
        single: bool,
        cfg: *const Config,
        log: *Log,
        created: u32 = 0,

        pub const comp_cid: [16]u8 = @splat(0xA1);
        const U = host.Unknown(Factory, "iface");

        pub fn create(gpa: Allocator, single: bool, cfg: *const Config, log: *Log) !*Factory {
            const self = try gpa.create(Factory);
            self.* = .{ .iface = .{ .vtbl = &vtbl }, .gpa = gpa, .single = single, .cfg = cfg, .log = log };
            return self;
        }
        pub fn queryImpl(self: *Factory, id: *const abi.TUID) ?*anyopaque {
            if (std.mem.eql(u8, id, &abi.FUnknown.iid) or std.mem.eql(u8, id, &abi.IPluginFactory.iid)) return &self.iface;
            return null;
        }
        pub fn destroy(self: *Factory) void {
            self.gpa.destroy(self);
        }
        fn getFactoryInfo(_: *abi.IPluginFactory, _: *abi.PFactoryInfo) callconv(.c) abi.tresult {
            return abi.kNotImplemented;
        }
        fn countClasses(_: *abi.IPluginFactory) callconv(.c) i32 {
            return 0;
        }
        fn getClassInfo(_: *abi.IPluginFactory, _: i32, _: *abi.PClassInfo) callconv(.c) abi.tresult {
            return abi.kNotImplemented;
        }
        fn createInstance(this: *abi.IPluginFactory, cid: *const abi.TUID, iid: *const abi.TUID, obj: *?*anyopaque) callconv(.c) abi.tresult {
            const self: *Factory = @fieldParentPtr("iface", this);
            obj.* = null;
            const kind: Kind = if (std.mem.eql(u8, cid, &comp_cid))
                (if (self.single) .single else .component)
            else if (std.mem.eql(u8, cid, &self.cfg.controller_cid) and !self.single)
                .controller
            else
                return abi.kNoInterface;
            const o = Obj.create(self.gpa, kind, self.cfg, self.log) catch return abi.kOutOfMemory;
            defer o.release();
            const p = o.queryImpl(iid) orelse return abi.kNoInterface;
            _ = o.refs.add();
            obj.* = p;
            self.created += 1;
            return abi.kResultOk;
        }
        const vtbl: abi.IPluginFactory.Vtbl = .{
            .unknown = U.vtbl,
            .getFactoryInfo = getFactoryInfo,
            .countClasses = countClasses,
            .getClassInfo = getClassInfo,
            .createInstance = createInstance,
        };
    };
} else struct {};

// ---- tests -------------------------------------------------------------------------------------
//
// editor.rs has no tests of its own. These cover its documented behaviour against the fake
// plugin: view probing, the main-thread rules, teardown ordering, the frame's resize, and a
// handle that outlives the instance.

const testing = std.testing;
const module = @import("module.zig");
const fx = fixture;

/// A bundle with a fake factory, for tests (no binary is loaded).
fn fakeBundle(f: *fx.Factory) module.Bundle {
    return .{
        .gpa = testing.allocator,
        .path = &.{},
        .factory = &f.iface,
        .exit_fn = null,
        .entered_on = .main,
    };
}

/// A bare link bound to a freshly made controller object (no instance involved).
const Rig = struct {
    cfg: fx.Config,
    log: fx.Log = .{},
    obj: *fx.Obj,
    link: *EditorLink,

    fn init(rig: *Rig, cfg: fx.Config) !void {
        rig.* = .{ .cfg = cfg, .obj = undefined, .link = undefined };
        rig.obj = try fx.Obj.create(testing.allocator, .single, &rig.cfg, &rig.log);
        rig.link = try EditorLink.create(testing.allocator);
        rig.link.bind(&rig.obj.comp, &rig.obj.ctrl);
    }

    /// Kills the link, drops the test's references.
    fn deinit(rig: *Rig) void {
        _ = rig.link.kill();
        rig.link.release();
        rig.obj.release();
    }
};

test "rectSize: clamps to a sane window" {
    const a = rectSize(.{ .left = 10, .top = 20, .right = 110, .bottom = 70 });
    try testing.expectEqual(@as(f64, 100), a.w);
    try testing.expectEqual(@as(f64, 50), a.h);
    const empty = rectSize(.{ .left = 5, .top = 5, .right = 5, .bottom = 0 });
    try testing.expectEqual(@as(f64, 1), empty.w);
    try testing.expectEqual(@as(f64, 1), empty.h);
    const huge = rectSize(.{ .left = std.math.minInt(i32), .top = 0, .right = std.math.maxInt(i32), .bottom = 99_999 });
    try testing.expectEqual(@as(f64, 16_384), huge.w);
    try testing.expectEqual(@as(f64, 16_384), huge.h);
}

test "EditorLink.probe: reads the view size without attaching" {
    if (window.platform_type == null) return error.SkipZigTest;
    var rig: Rig = undefined;
    try rig.init(.{ .view_w = 640, .view_h = 480 });
    defer rig.deinit();
    const size = try rig.link.probe();
    try testing.expectEqual(@as(u32, 640), size.w);
    try testing.expectEqual(@as(u32, 480), size.h);
    try testing.expectEqual(@as(u32, 1), rig.log.views_created);
    try testing.expectEqual(@as(u32, 0), rig.log.view_attached);
}

test "EditorLink.probe: no editor, unsupported platform type and no size are reported" {
    if (window.platform_type == null) return error.SkipZigTest;
    {
        var rig: Rig = undefined;
        try rig.init(.{ .has_view = false });
        defer rig.deinit();
        try testing.expectError(error.NoEditor, rig.link.probe());
    }
    {
        var rig: Rig = undefined;
        try rig.init(.{ .view_supports_platform = false });
        defer rig.deinit();
        try testing.expectError(error.PlatformNotSupported, rig.link.probe());
        // The probe's view is released again.
        try testing.expectEqual(@as(u32, 0), rig.log.view_attached);
    }
    {
        var rig: Rig = undefined;
        try rig.init(.{ .view_w = -1 });
        defer rig.deinit();
        try testing.expectError(error.NoSize, rig.link.probe());
    }
}

test "EditorLink.open off the main thread is refused" {
    const T = struct {
        fn run(out: *?EditorError) void {
            var rig: Rig = undefined;
            rig.init(.{}) catch return;
            defer rig.deinit();
            if (rig.link.open("x")) |_| {
                out.* = null;
            } else |e| out.* = e;
            // close / idle / setNormalized / valueText are inert off the main thread.
            rig.link.close();
            rig.link.idle();
            rig.link.setNormalized(1, 0.5);
        }
    };
    var res: ?EditorError = null;
    const th = try std.Thread.spawn(.{}, T.run, .{&res});
    th.join();
    try testing.expectEqual(@as(?EditorError, error.NotMainThread), res);
}

test "EditorLink: teardown removes the view before detaching the frame, then releases" {
    var rig: Rig = undefined;
    try rig.init(.{ .has_view = true });
    defer rig.deinit();
    // Install a view by hand (opening needs a real window).
    const view = rig.obj.ctrl.createView("editor").?;
    const frame = try PlugFrame.create(testing.allocator, null);
    _ = view.setFrame(frame.interface());
    rig.link.inner.view = view;
    rig.link.inner.frame = frame;
    try testing.expect(rig.log.frame_set);
    EditorLink.teardown(&rig.link.inner);
    try testing.expect(rig.link.inner.view == null and rig.link.inner.frame == null);
    try testing.expectEqual(@as(u32, 1), rig.log.view_removed);
    try testing.expect(!rig.log.frame_set);
    const removed_at = rig.log.indexOf(.view_removed, 1).?;
    const cleared_at = rig.log.indexOf(.view_frame_cleared, 1).?;
    try testing.expect(removed_at < cleared_at);
}

test "PlugFrame.resizeView clamps the size and forwards onSize to the view" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const view = rig.obj.ctrl.createView("editor").?;
    defer _ = abi.comRelease(view);
    const frame = try PlugFrame.create(testing.allocator, null);
    defer frame.release();
    var r: abi.ViewRect = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
    const f = frame.interface();
    try testing.expectEqual(abi.kResultOk, f.vtbl.resizeView(f, view, &r));
    try testing.expectEqual(@as(u32, 1), rig.log.view_on_size);
    try testing.expectEqual(@as(i32, 800), rig.log.last_on_size.right);
    try testing.expectEqual(@as(i32, 600), rig.log.last_on_size.bottom);
    // The frame answers its own interface and nothing else.
    var out: ?*anyopaque = null;
    try testing.expect(abi.ok(abi.asUnknown(f).queryInterface(&abi.IPlugFrame.iid, &out)));
    _ = abi.comRelease(f);
    try testing.expect(!abi.ok(abi.asUnknown(f).queryInterface(&abi.IEditController.iid, &out)));
}

test "EditorLink: values go through the controller and are clamped" {
    var rig: Rig = undefined;
    try rig.init(.{ .params = &.{.{ .id = 7, .title = "Gain", .min = -24, .max = 12 }} });
    defer rig.deinit();
    try testing.expectEqual(@as(?f64, -24.0), rig.link.toPlain(7, -3.0));
    try testing.expectEqual(@as(?f64, 12.0), rig.link.toPlain(7, 9.0));
    try testing.expectEqual(@as(?f64, 0.5), rig.link.toNormalized(7, -6.0));
    try testing.expectEqual(@as(?f64, 1.0), rig.link.toNormalized(7, 100.0));
    try testing.expectEqual(@as(?f64, null), rig.link.toNormalized(7, std.math.nan(f64)));
    try testing.expectEqual(@as(?f64, null), rig.link.toPlain(999, 0.5));
    rig.link.syncParam(7, 5.0);
    try testing.expectEqual(@as(f64, 1.0), rig.log.last_param_set_value);
    rig.link.syncParam(7, std.math.nan(f64));
    try testing.expectEqual(@as(u32, 1), rig.log.param_sets);
}

test "EditorLink.valueText is main-thread only" {
    var rig: Rig = undefined;
    try rig.init(.{ .params = &.{.{ .id = 7, .title = "Gain", .min = 0, .max = 10 }} });
    defer rig.deinit();
    if (window.onMainThread()) {
        const t = (try rig.link.valueText(testing.allocator, 7, 0.5)).?;
        defer testing.allocator.free(t);
        try testing.expectEqualStrings("5.0", t);
        rig.link.setNormalized(7, 0.25);
        try testing.expectEqual(@as(f64, 0.25), rig.log.last_param_set_value);
    }
    const T = struct {
        fn run(l: *EditorLink, out: *bool) void {
            const t = l.valueText(testing.allocator, 7, 0.5) catch null;
            const sets = l.inner.controller != null;
            l.setNormalized(7, 0.9);
            out.* = t == null and sets;
        }
    };
    var inert = false;
    const th = try std.Thread.spawn(.{}, T.run, .{ rig.link, &inert });
    th.join();
    try testing.expect(inert);
    try testing.expect(rig.log.last_param_set_value != 0.9);
}

test "EditorLink.saveState: container of component and controller state" {
    var rig: Rig = undefined;
    try rig.init(.{ .comp_state = "abc", .ctrl_state = "xy" });
    defer rig.deinit();
    const blob = (try rig.link.saveState(testing.allocator)).?;
    defer testing.allocator.free(blob);
    var want: std.ArrayList(u8) = .empty;
    defer want.deinit(testing.allocator);
    try want.appendSlice(testing.allocator, "SCV3");
    try want.appendSlice(testing.allocator, &.{ 3, 0, 0, 0 });
    try want.appendSlice(testing.allocator, "abc");
    try want.appendSlice(testing.allocator, &.{ 2, 0, 0, 0 });
    try want.appendSlice(testing.allocator, "xy");
    try testing.expectEqualSlices(u8, want.items, blob);
}

test "a handle outlives the instance: kill clears the plugin and every call is a no-op" {
    var rig: Rig = undefined;
    try rig.init(.{ .params = &.{.{ .id = 7, .title = "Gain" }} });
    var handle = EditorHandle.init(rig.link);
    defer handle.deinit();
    try testing.expect(rig.link.hasController());
    try testing.expect(!rig.link.kill());
    try testing.expect(!rig.link.hasController());
    // Both references the link held on the plugin are gone.
    rig.obj.release();
    try testing.expectEqual(@as(usize, 1), rig.log.count(.destroyed));
    try testing.expectEqual(@as(?f64, null), rig.link.toPlain(7, 0.5));
    try testing.expectEqual(@as(?f64, null), rig.link.toNormalized(7, 0.5));
    try testing.expectEqual(@as(?[]u8, null), try rig.link.saveState(testing.allocator));
    rig.link.syncParam(7, 0.5);
    handle.setNormalized(7, 0.5);
    handle.close();
    handle.idle();
    try testing.expect(!handle.isOpen());
    if (window.platform_type != null and window.onMainThread()) {
        try testing.expectError(error.PluginGone, handle.open("x"));
        try testing.expectError(error.PluginGone, rig.link.probe());
    }
    rig.link.release();
}

test "kill off the main thread with an open view leaks it and reports it" {
    var rig: Rig = undefined;
    try rig.init(.{});
    const view = rig.obj.ctrl.createView("editor").?;
    rig.link.inner.view = view;
    const T = struct {
        fn run(l: *EditorLink, out: *bool) void {
            out.* = l.kill();
        }
    };
    var leaked = false;
    const th = try std.Thread.spawn(.{}, T.run, .{ rig.link, &leaked });
    th.join();
    try testing.expect(leaked);
    try testing.expect(rig.link.inner.view == null);
    // The leaked view is released here so the test itself does not leak.
    _ = abi.comRelease(view);
    rig.link.release();
    rig.obj.release();
}

test "describe covers every error" {
    const all = [_]EditorError{
        error.PluginGone,   error.NoEditor,             error.NotMainThread,
        error.Unsupported,  error.PlatformNotSupported, error.NoSize,
        error.WindowFailed, error.AttachFailed,         error.OutOfMemory,
    };
    for (all) |e| try testing.expect(describe(e).len > 0);
    try testing.expectEqual(@as(usize, 9), all.len);
}

test "Window platform selection matches the OS" {
    if (builtin.os.tag == .macos) {
        try testing.expectEqualStrings("NSView", std.mem.span(window.platform_type.?));
    } else {
        try testing.expect(window.platform_type == null);
    }
}
