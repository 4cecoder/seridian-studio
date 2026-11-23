// Translated to Zig from soundcraft/crates/clap-host/src/ffi/gui.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The CLAP `clap.gui` extension for one instance: open, show, hide, close and
//! destroy the plugin's editor, service its requests from the main thread, hand the
//! parameter edits it made back to the UI, and save its state through the same link.
//!
//! Window choice. On macOS the editor is a floating window the plugin owns
//! (`create(is_floating = true)`), and the host passes no parent. The window API
//! string is "cocoa" there, "x11" on other unix, "win32" on Windows. An embedded
//! editor (the host makes the window and calls `set_parent`) is tried only when the
//! platform hosts one (`hostwin.SUPPORTED`); on the other platforms a plugin that
//! offers only an embedded editor is refused.
//!
//! Threading. Editor calls (`open`, `close`, `idle`, and `kill` when it has an
//! editor to destroy) run on the main thread. `open` and `close` fail or do nothing
//! elsewhere, `idle` returns nothing, and `kill` abandons the window instead of
//! destroying it. The audio thread never touches a `GuiLink`: it does not call it and
//! never takes its lock. The lock guards `GuiInner` and is taken by the main thread
//! (and by the control thread in `attach` and `kill`), never by the audio thread.
//! It is a spin lock because its critical sections are plugin calls on the main
//! thread that the audio thread never waits for.
//!
//! Differences from gui.rs, all deliberate:
//! - `GuiLink` borrows the instance's `HostState` (`*HostState`) instead of owning an
//!   `Arc`. The instance owns the state, and it outlives the link.
//! - `idle` returns parameter edits by filling a caller buffer (bounded, no
//!   allocation) from the SPSC edit ring in `host.zig`. The Rust returned a `Vec`.
//! - Errors are an error set. The Rust `String` messages are kept as doc comments.
//!   The "SoundCraft" wording in the messages becomes "Seridian".
//! - `open` copies the title into a bounded buffer and truncates it to
//!   `abi.MAX_STRING_LEN` bytes. A title with an interior NUL is not passed to
//!   `suggest_title`, which is what `CString::new` refusing it did in the Rust.
//! - Off macOS the editor is created at scale 1.0, and on macOS `set_scale` is never
//!   called, as in the Rust (Cocoa uses logical pixels).

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const log = std.log.scoped(.plughost_gui);

const abi = @import("abi.zig");
const events = @import("events.zig");
const host_mod = @import("host.zig");
const hostwin = @import("hostwin.zig");

// ---- platform -----------------------------------------------------------------------------------

/// The `clap_window_api` strings (CLAP 1.2 `clap/ext/gui.h`).
pub const WINDOW_API_COCOA: [:0]const u8 = "cocoa";
pub const WINDOW_API_WIN32: [:0]const u8 = "win32";
pub const WINDOW_API_X11: [:0]const u8 = "x11";

/// Scale the editor is created and sized at off macOS (Cocoa uses logical pixels, so
/// `set_scale` is not called there).
pub const EDITOR_SCALE: f64 = 1.0;

/// Size an embedded editor starts at when the plugin reports none.
pub const DEFAULT_EDITOR_WIDTH: u32 = 640;
pub const DEFAULT_EDITOR_HEIGHT: u32 = 480;

/// Largest embedded editor size taken from `get_size` or a resize request.
pub const MAX_EDITOR_DIM: u32 = 16_384;

/// Bytes for a NUL-terminated title: `abi.MAX_STRING_LEN` characters and the NUL.
const TITLE_BUF_LEN = abi.MAX_STRING_LEN + 1;

extern "c" fn pthread_main_np() c_int;

/// True on the process's main thread (AppKit requires GUI calls there). Always true
/// off macOS, where no thread rule is checked here.
pub fn onMainThread() bool {
    if (builtin.os.tag == .macos) return pthread_main_np() == 1;
    return true;
}

/// The windowing API string for this platform, or null where CLAP editors are not
/// supported. Matches the Rust `window_api`.
pub fn windowApi() ?[:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => WINDOW_API_COCOA,
        .windows => WINDOW_API_WIN32,
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly => WINDOW_API_X11,
        else => null,
    };
}

// ---- lock -----------------------------------------------------------------------------------------

/// A spin lock for `GuiInner`. Held for one plugin call on the main thread at most;
/// the audio thread never takes it (see the module docs).
const UiLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    fn lock(self: *UiLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *UiLock) void {
        self.locked.store(false, .release);
    }
};

// ---- state ----------------------------------------------------------------------------------------

/// Why an editor call failed.
pub const GuiError = error{
    /// Editor calls must run on the main thread.
    NotOnMainThread,
    /// The plugin has no `clap.gui` extension, or the instance is gone.
    NoEditor,
    /// This platform has no windowing API for CLAP editors.
    NoWindowApi,
    /// The plugin's `clap.gui` lacks a function this host needs.
    IncompleteExtension,
    /// The plugin offers only an embedded editor, which this platform does not host.
    EmbeddedNotSupported,
    /// The plugin refused to create its editor.
    CreateFailed,
    /// The plugin refused to show its editor. The editor is destroyed again.
    ShowFailed,
    /// The plugin refused to attach to the host window. The window is closed again.
    AttachFailed,
} || hostwin.HostWindowError;

/// The editor state. Guarded by `GuiLink.lock`; main thread only.
pub const GuiInner = struct {
    /// The plugin. Valid while `alive`.
    plugin: ?*const abi.ClapPlugin = null,
    /// The plugin's `clap.gui` table, or null when it has none. Valid while `alive`.
    gui: ?*const abi.ClapPluginGui = null,
    /// The plugin's `clap.state` table, or null when it has none. Valid while `alive`.
    state: ?*const abi.ClapPluginState = null,
    /// The plugin instance exists. Cleared by `kill` before the instance destroys it.
    alive: bool = false,
    /// The plugin's editor is created (and not yet destroyed).
    created: bool = false,
    /// The editor was last shown (or re-shown) and not hidden since.
    visible: bool = false,
    /// The host window of an embedded editor. Null for a floating editor.
    window: ?hostwin.HostWindow = null,
};

/// The plugin and its `clap.gui` table, while the instance is alive and has an editor.
const LiveGui = struct {
    plugin: *const abi.ClapPlugin,
    gui: *const abi.ClapPluginGui,
};

/// The plugin and its `clap.gui` table while the instance is alive and has an editor.
/// Null otherwise (the Rust `GuiLink::vt`).
fn liveGui(g: *const GuiInner) ?LiveGui {
    if (!g.alive) return null;
    return .{
        .plugin = g.plugin orelse return null,
        .gui = g.gui orelse return null,
    };
}

/// The link between an instance and its editor and state. Create it with `init`, then
/// `attach` the plugin before any editor call. The instance owns `host_state` and
/// keeps it alive for the link's lifetime.
pub const GuiLink = struct {
    /// Guards `inner`. Taken on the main thread only (see the module docs).
    lock: UiLock = .{},
    inner: GuiInner = .{},
    /// The flags and the parameter edit ring the plugin's host callbacks write to.
    host_state: *host_mod.HostState,
    /// Main-thread check. Production uses `onMainThread`; tests replace it.
    is_main_thread: *const fn () bool = onMainThread,

    /// Makes a link with no plugin attached. Nothing can be opened until `attach`.
    pub fn init(host_state: *host_mod.HostState) GuiLink {
        return .{ .host_state = host_state };
    }

    /// Control thread. Hands the link the plugin and its `clap.gui` and `clap.state`
    /// tables (either may be null) and marks the plugin alive. Calling it again
    /// replaces the previous attachment without destroying an editor.
    pub fn attach(self: *GuiLink, plugin: *const abi.ClapPlugin, gui: ?*const abi.ClapPluginGui, state: ?*const abi.ClapPluginState) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.inner = .{ .plugin = plugin, .gui = gui, .state = state, .alive = true };
    }

    /// The flags and parameter edits of this instance, for the owner.
    pub fn host(self: *const GuiLink) *host_mod.HostState {
        return self.host_state;
    }

    /// True while the plugin is alive and has a `clap.gui` table.
    pub fn available(self: *GuiLink) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return liveGui(&self.inner) != null;
    }

    /// Main thread. Opens the plugin's floating editor: creates it, titles it, and
    /// shows it. An editor that already exists is shown again. `title` is copied and
    /// truncated to `abi.MAX_STRING_LEN` bytes.
    pub fn open(self: *GuiLink, title: []const u8) GuiError!void {
        if (!self.is_main_thread()) return error.NotOnMainThread;
        self.lock.lock();
        defer self.lock.unlock();
        const g = &self.inner;
        const live = liveGui(g) orelse return error.NoEditor;

        if (g.created) {
            if (live.gui.show) |show| _ = show(live.plugin);
            if (g.window) |win| win.raise();
            g.visible = true;
            return;
        }

        const api = windowApi() orelse return error.NoWindowApi;
        const supported = live.gui.is_api_supported orelse return error.IncompleteExtension;
        const create = live.gui.create orelse return error.IncompleteExtension;

        if (!supported(live.plugin, api.ptr, true)) {
            // Only an embedded editor: hosted here only where this platform supports it.
            if (hostwin.SUPPORTED and supported(live.plugin, api.ptr, false)) {
                return self.openEmbedded(g, live, api, title);
            }
            return error.EmbeddedNotSupported;
        }

        self.host_state.gui_closed.store(false, .monotonic);
        self.host_state.gui_destroyed.store(false, .monotonic);
        if (!create(live.plugin, api.ptr, true)) return error.CreateFailed;
        g.created = true;

        if (builtin.os.tag != .macos) {
            if (live.gui.set_scale) |set_scale| _ = set_scale(live.plugin, EDITOR_SCALE);
        }
        if (live.gui.suggest_title) |suggest| {
            var buf: [TITLE_BUF_LEN]u8 = undefined;
            if (titleZ(&buf, title)) |t| suggest(live.plugin, t);
        }

        const shown = if (live.gui.show) |show| show(live.plugin) else false;
        if (!shown) {
            destroyGui(g);
            return error.ShowFailed;
        }
        g.visible = true;
    }

    /// Embeds the editor in a host window (plugins that offer no floating editor). Only
    /// reached when `hostwin.SUPPORTED`. The caller holds `self.lock`.
    fn openEmbedded(self: *GuiLink, g: *GuiInner, live: LiveGui, api: [:0]const u8, title: []const u8) GuiError!void {
        const create = live.gui.create orelse return error.IncompleteExtension;
        const set_parent = live.gui.set_parent orelse return error.IncompleteExtension;

        self.host_state.gui_closed.store(false, .monotonic);
        self.host_state.gui_destroyed.store(false, .monotonic);
        self.host_state.gui_resize.store(0, .monotonic);
        if (!create(live.plugin, api.ptr, false)) return error.CreateFailed;
        g.created = true;

        if (live.gui.set_scale) |set_scale| _ = set_scale(live.plugin, EDITOR_SCALE);

        var w: u32 = DEFAULT_EDITOR_WIDTH;
        var h: u32 = DEFAULT_EDITOR_HEIGHT;
        if (live.gui.get_size) |get_size| {
            var a: u32 = 0;
            var b: u32 = 0;
            if (get_size(live.plugin, &a, &b) and a > 0 and b > 0) {
                w = @min(a, MAX_EDITOR_DIM);
                h = @min(b, MAX_EDITOR_DIM);
            }
        }

        const win = hostwin.HostWindow.new(title, @floatFromInt(w), @floatFromInt(h)) catch |err| {
            destroyGui(g);
            return err;
        };
        const parent: abi.ClapWindow = .{
            .api = api.ptr,
            .handle = .{ .win32 = win.parent() },
        };
        if (!set_parent(live.plugin, &parent)) {
            win.close();
            destroyGui(g);
            return error.AttachFailed;
        }
        g.window = win;

        const shown = if (live.gui.show) |show| show(live.plugin) else true;
        if (!shown) {
            destroyGui(g);
            return error.ShowFailed;
        }
        if (g.window) |w_now| w_now.raise();
        g.visible = true;
    }

    /// Destroys the editor. The caller holds the lock. The plugin's `destroy` runs only
    /// while the plugin is alive and a GUI exists. The host window goes last, after
    /// the plugin's child window is gone.
    fn destroyGui(g: *GuiInner) void {
        if (g.created) {
            if (liveGui(g)) |live| {
                if (live.gui.destroy) |destroy| destroy(live.plugin);
            }
        }
        g.created = false;
        g.visible = false;
        if (g.window) |win| {
            win.close();
            g.window = null;
        }
    }

    /// Control thread or main thread. The plugin's state as bytes, in a new slice that
    /// the caller frees with `gpa`. Null without `clap.state`, when the plugin refuses
    /// to save, or once the plugin is gone.
    pub fn saveState(self: *GuiLink, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
        self.lock.lock();
        defer self.lock.unlock();
        const g = &self.inner;
        if (!g.alive) return null;
        const plugin = g.plugin orelse return null;
        const save = (g.state orelse return null).save orelse return null;

        var sink: events.WriteSink = .{ .gpa = gpa };
        errdefer sink.deinit();
        const stream = sink.stream();
        if (!save(plugin, &stream)) {
            sink.deinit();
            return null;
        }
        return try sink.bytes.toOwnedSlice(gpa);
    }

    /// Main thread. Destroys the editor. Does nothing off the main thread or when no
    /// editor is open.
    pub fn close(self: *GuiLink) void {
        if (!self.is_main_thread()) return;
        self.lock.lock();
        defer self.lock.unlock();
        destroyGui(&self.inner);
    }

    /// True while the editor exists, is shown, and its host window (if it has one) is
    /// on screen.
    pub fn isOpen(self: *GuiLink) bool {
        self.lock.lock();
        defer self.lock.unlock();
        const g = &self.inner;
        if (!g.alive or !g.created or !g.visible) return false;
        if (g.window) |win| return win.isVisible();
        return true;
    }

    /// Main thread, called by the UI on each frame. Runs a requested `on_main_thread`,
    /// applies the editor's resize, show, hide and closed requests, and moves the
    /// parameter edits the plugin reported into `out`. Returns how many were moved.
    /// Edits that do not fit stay queued for the next call. Returns 0 off the main
    /// thread, and once the plugin is gone (in which case nothing is consumed).
    pub fn idle(self: *GuiLink, out: []events.ClapParamEdit) usize {
        if (!self.is_main_thread()) return 0;
        self.lock.lock();
        defer self.lock.unlock();
        const g = &self.inner;
        if (!g.alive) return 0;
        const plugin = g.plugin orelse return 0;

        if (self.host_state.callback.swap(false, .monotonic)) {
            if (plugin.on_main_thread) |on_main| on_main(plugin);
        }
        if (g.created) self.serviceEditor(g);
        return self.host_state.drainEdits(out);
    }

    /// The editor requests a host window the plugin asked for. The caller holds the
    /// lock, the editor exists, and the plugin is alive.
    fn serviceEditor(self: *GuiLink, g: *GuiInner) void {
        const resize = self.host_state.gui_resize.swap(0, .monotonic);
        if (resize != 0) {
            if (g.window) |win| {
                const w: u32 = @truncate(resize >> 32);
                const h: u32 = @truncate(resize);
                hostwin.resize(win.raw(), @floatFromInt(w), @floatFromInt(h));
                if (liveGui(g)) |live| {
                    if (live.gui.set_size) |set_size| _ = set_size(live.plugin, w, h);
                }
            }
        }

        const window_closed = if (g.window) |win| !win.isVisible() else false;
        if (window_closed) {
            // The user closed the embedded editor's host window: free the editor.
            destroyGui(g);
        } else if (self.host_state.gui_closed.swap(false, .monotonic)) {
            // The user closed a floating window, or the plugin lost its GUI: free it.
            self.host_state.gui_destroyed.store(false, .monotonic);
            destroyGui(g);
        } else if (liveGui(g)) |live| {
            if (self.host_state.gui_show.swap(false, .monotonic)) {
                if (live.gui.show) |show| g.visible = show(live.plugin);
            }
            if (self.host_state.gui_hide.swap(false, .monotonic)) {
                if (live.gui.hide) |hide| {
                    _ = hide(live.plugin);
                    g.visible = false;
                }
            }
        }
    }

    /// Called by the instance before it destroys the plugin. On the main thread an open
    /// editor is destroyed first. Elsewhere it is abandoned: its host window is dropped
    /// without a call, because window calls are main-thread only. Either way the link
    /// is dead afterwards, and no later call reaches the plugin.
    pub fn kill(self: *GuiLink) void {
        self.lock.lock();
        defer self.lock.unlock();
        const g = &self.inner;
        if (g.created) {
            if (self.is_main_thread()) {
                destroyGui(g);
            } else {
                log.warn("clap: editor still open while its plugin is destroyed off the main thread", .{});
                g.created = false;
                g.window = null;
            }
        }
        g.alive = false;
    }
};

/// Copies `title` into `buf` as a NUL-terminated string, truncated to the buffer's
/// text. Null when `title` has an interior NUL, which `CString::new` refused in Rust.
fn titleZ(buf: *[TITLE_BUF_LEN]u8, title: []const u8) ?[*:0]const u8 {
    if (std.mem.indexOfScalar(u8, title, 0) != null) return null;
    const n = @min(title.len, abi.MAX_STRING_LEN);
    @memcpy(buf[0..n], title[0..n]);
    buf[n] = 0;
    return @ptrCast(buf);
}

// ---- tests ----------------------------------------------------------------------------------------
// gui.rs has no inline tests. These pin the behaviour the Rust code defines, against a
// fake plugin whose `clap.gui` and `clap.state` tables count the calls they receive.

/// Counters and switches of the fake plugin. The plugin's `plugin_data` points here.
const Fake = struct {
    floating: bool = true,
    embedded: bool = false,
    create_ok: bool = true,
    show_ok: bool = true,
    /// Editor size from `get_size`; zero means the plugin reports none.
    width: u32 = 0,
    height: u32 = 0,
    state: []const u8 = "",
    state_ok: bool = true,
    creates: u32 = 0,
    destroys: u32 = 0,
    shows: u32 = 0,
    hides: u32 = 0,
    scales: u32 = 0,
    titles: u32 = 0,
    sizes: u32 = 0,
    main_calls: u32 = 0,
};

fn fakeOf(plugin: *const abi.ClapPlugin) *Fake {
    return @ptrCast(@alignCast(plugin.plugin_data.?));
}

fn fakeIsApiSupported(plugin: *const abi.ClapPlugin, api: [*:0]const u8, is_floating: bool) callconv(.c) bool {
    _ = api;
    const f = fakeOf(plugin);
    return if (is_floating) f.floating else f.embedded;
}

fn fakeCreate(plugin: *const abi.ClapPlugin, api: [*:0]const u8, is_floating: bool) callconv(.c) bool {
    _ = api;
    _ = is_floating;
    const f = fakeOf(plugin);
    f.creates += 1;
    return f.create_ok;
}

fn fakeDestroy(plugin: *const abi.ClapPlugin) callconv(.c) void {
    fakeOf(plugin).destroys += 1;
}

fn fakeSetScale(plugin: *const abi.ClapPlugin, scale: f64) callconv(.c) bool {
    _ = scale;
    fakeOf(plugin).scales += 1;
    return true;
}

fn fakeGetSize(plugin: *const abi.ClapPlugin, width: *u32, height: *u32) callconv(.c) bool {
    const f = fakeOf(plugin);
    if (f.width == 0) return false;
    width.* = f.width;
    height.* = f.height;
    return true;
}

fn fakeSetSize(plugin: *const abi.ClapPlugin, width: u32, height: u32) callconv(.c) bool {
    _ = width;
    _ = height;
    fakeOf(plugin).sizes += 1;
    return true;
}

fn fakeSetParent(plugin: *const abi.ClapPlugin, window: *const abi.ClapWindow) callconv(.c) bool {
    _ = plugin;
    _ = window;
    return false;
}

fn fakeSuggestTitle(plugin: *const abi.ClapPlugin, title: [*:0]const u8) callconv(.c) void {
    _ = title;
    fakeOf(plugin).titles += 1;
}

fn fakeShow(plugin: *const abi.ClapPlugin) callconv(.c) bool {
    const f = fakeOf(plugin);
    f.shows += 1;
    return f.show_ok;
}

fn fakeHide(plugin: *const abi.ClapPlugin) callconv(.c) bool {
    fakeOf(plugin).hides += 1;
    return true;
}

fn fakeOnMainThread(plugin: *const abi.ClapPlugin) callconv(.c) void {
    fakeOf(plugin).main_calls += 1;
}

fn fakeStateSave(plugin: *const abi.ClapPlugin, stream: *const abi.ClapOStream) callconv(.c) bool {
    const f = fakeOf(plugin);
    if (!f.state_ok) return false;
    const write = stream.write orelse return false;
    return write(stream, f.state.ptr, f.state.len) == @as(i64, @intCast(f.state.len));
}

fn alwaysMain() bool {
    return true;
}

fn neverMain() bool {
    return false;
}

/// A plugin, its extension tables, a host state and a link, wired together. Must not
/// move after `setup`, because the link and the plugin keep pointers into it.
const Harness = struct {
    fake: Fake = .{},
    plugin: abi.ClapPlugin = std.mem.zeroes(abi.ClapPlugin),
    gui: abi.ClapPluginGui = std.mem.zeroes(abi.ClapPluginGui),
    state_ext: abi.ClapPluginState = std.mem.zeroes(abi.ClapPluginState),
    host_state: host_mod.HostState = .{},
    link: GuiLink = undefined,

    fn setup(self: *Harness) void {
        self.plugin.plugin_data = &self.fake;
        self.plugin.on_main_thread = fakeOnMainThread;
        self.gui = std.mem.zeroes(abi.ClapPluginGui);
        self.gui.is_api_supported = fakeIsApiSupported;
        self.gui.create = fakeCreate;
        self.gui.destroy = fakeDestroy;
        self.gui.set_scale = fakeSetScale;
        self.gui.get_size = fakeGetSize;
        self.gui.set_size = fakeSetSize;
        self.gui.set_parent = fakeSetParent;
        self.gui.suggest_title = fakeSuggestTitle;
        self.gui.show = fakeShow;
        self.gui.hide = fakeHide;
        self.state_ext = .{ .save = fakeStateSave, .load = null };
        self.link = GuiLink.init(&self.host_state);
        self.link.is_main_thread = alwaysMain;
        self.link.attach(&self.plugin, &self.gui, &self.state_ext);
    }
};

test "GUI: the window api is cocoa on macOS, x11 on linux, win32 on Windows, and null elsewhere" {
    const api = windowApi();
    switch (builtin.os.tag) {
        .macos => try testing.expectEqualStrings("cocoa", api.?),
        .windows => try testing.expectEqualStrings("win32", api.?),
        .linux => try testing.expectEqualStrings("x11", api.?),
        else => try testing.expect(api == null),
    }
}

test "GUI: open creates, scales, titles and shows a floating editor, which then reads as open" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("Synth");

    try testing.expectEqual(@as(u32, 1), h.fake.creates);
    // Cocoa uses logical pixels, so set_scale is only called off macOS.
    const want_scales: u32 = if (builtin.os.tag == .macos) 0 else 1;
    try testing.expectEqual(want_scales, h.fake.scales);
    try testing.expectEqual(@as(u32, 1), h.fake.titles);
    try testing.expectEqual(@as(u32, 1), h.fake.shows);
    try testing.expectEqual(@as(u32, 0), h.fake.destroys);
    try testing.expect(h.link.isOpen());
    try testing.expect(h.link.available());
}

test "GUI: open on an open editor shows it again and creates no second editor" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("Synth");
    try h.link.open("Synth");

    try testing.expectEqual(@as(u32, 1), h.fake.creates);
    try testing.expectEqual(@as(u32, 2), h.fake.shows);
    try testing.expect(h.link.isOpen());
}

test "GUI: editor calls refuse off the main thread and leave the plugin and the callback alone" {
    var h: Harness = .{};
    h.setup();
    h.link.is_main_thread = neverMain;
    h.host_state.callback.store(true, .monotonic);

    try testing.expectError(error.NotOnMainThread, h.link.open("Synth"));
    h.link.close();
    var out: [4]events.ClapParamEdit = undefined;
    try testing.expectEqual(@as(usize, 0), h.link.idle(&out));

    try testing.expectEqual(@as(u32, 0), h.fake.creates);
    try testing.expectEqual(@as(u32, 0), h.fake.main_calls);
    try testing.expect(h.host_state.callback.load(.monotonic));
    try testing.expect(!h.link.isOpen());
}

test "GUI: a plugin without clap.gui cannot open and is not available" {
    var h: Harness = .{};
    h.setup();
    h.link.attach(&h.plugin, null, null);

    try testing.expectError(error.NoEditor, h.link.open("Synth"));
    try testing.expect(!h.link.available());
    try testing.expect((try h.link.saveState(testing.allocator)) == null);
}

test "GUI: a plugin that refuses to create its editor leaves nothing open" {
    var h: Harness = .{};
    h.setup();
    h.fake.create_ok = false;

    try testing.expectError(error.CreateFailed, h.link.open("Synth"));
    try testing.expectEqual(@as(u32, 1), h.fake.creates);
    try testing.expectEqual(@as(u32, 0), h.fake.destroys);
    try testing.expect(!h.link.isOpen());
}

test "GUI: a plugin that refuses to show its editor has it destroyed again" {
    var h: Harness = .{};
    h.setup();
    h.fake.show_ok = false;

    try testing.expectError(error.ShowFailed, h.link.open("Synth"));
    try testing.expectEqual(@as(u32, 1), h.fake.destroys);
    try testing.expect(!h.link.isOpen());
}

test "GUI: a plugin that offers only an embedded editor is refused where none is hosted" {
    var h: Harness = .{};
    h.setup();
    h.fake.floating = false;
    h.fake.embedded = true;

    try testing.expectError(error.EmbeddedNotSupported, h.link.open("Synth"));
    try testing.expectEqual(@as(u32, 0), h.fake.creates);
    try testing.expect(!h.link.isOpen());
}

test "GUI: an interior NUL in the title is not passed on, and the editor still opens" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("bad\x00title");

    try testing.expectEqual(@as(u32, 0), h.fake.titles);
    try testing.expectEqual(@as(u32, 1), h.fake.shows);
}

test "GUI: a title is copied NUL-terminated and truncated to the string cap" {
    var buf: [TITLE_BUF_LEN]u8 = undefined;
    const short = titleZ(&buf, "Synth").?;
    try testing.expectEqualStrings("Synth", std.mem.span(short));

    var long: [abi.MAX_STRING_LEN + 10]u8 = @splat('x');
    const t = titleZ(&buf, &long).?;
    try testing.expectEqual(abi.MAX_STRING_LEN, std.mem.span(t).len);
    try testing.expect(titleZ(&buf, "a\x00b") == null);
}

test "GUI: idle runs a requested main-thread callback once, and only when asked" {
    var h: Harness = .{};
    h.setup();
    var out: [4]events.ClapParamEdit = undefined;

    _ = h.link.idle(&out);
    try testing.expectEqual(@as(u32, 0), h.fake.main_calls);

    h.host_state.callback.store(true, .monotonic);
    _ = h.link.idle(&out);
    _ = h.link.idle(&out);
    try testing.expectEqual(@as(u32, 1), h.fake.main_calls);
    try testing.expect(!h.host_state.callback.load(.monotonic));
}

test "GUI: idle moves the editor's parameter edits to the caller, bounded by its buffer" {
    var h: Harness = .{};
    h.setup();
    try testing.expect(h.host_state.edits.push(.{ .param_id = 7, .value = 0.25 }));
    try testing.expect(h.host_state.edits.push(.{ .param_id = 8, .value = 0.5 }));
    try testing.expect(h.host_state.edits.push(.{ .param_id = 9, .value = 0.75 }));

    var out: [2]events.ClapParamEdit = undefined;
    try testing.expectEqual(@as(usize, 2), h.link.idle(&out));
    try testing.expectEqual(@as(abi.ClapId, 7), out[0].param_id);
    try testing.expectEqual(@as(f64, 0.25), out[0].value);
    try testing.expectEqual(@as(abi.ClapId, 8), out[1].param_id);

    // The edit that did not fit is still queued, and comes out next.
    try testing.expectEqual(@as(usize, 1), h.link.idle(&out));
    try testing.expectEqual(@as(abi.ClapId, 9), out[0].param_id);
    try testing.expectEqual(@as(usize, 0), h.link.idle(&out));
}

test "GUI: idle applies the plugin's show and hide requests to the open editor" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("Synth");
    var out: [1]events.ClapParamEdit = undefined;

    h.host_state.gui_hide.store(true, .monotonic);
    _ = h.link.idle(&out);
    try testing.expectEqual(@as(u32, 1), h.fake.hides);
    try testing.expect(!h.link.isOpen());

    h.host_state.gui_show.store(true, .monotonic);
    _ = h.link.idle(&out);
    try testing.expectEqual(@as(u32, 2), h.fake.shows);
    try testing.expect(h.link.isOpen());
}

test "GUI: a close request from the plugin destroys the editor on the next idle and clears its flags" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("Synth");
    var out: [1]events.ClapParamEdit = undefined;

    h.host_state.gui_closed.store(true, .monotonic);
    h.host_state.gui_destroyed.store(true, .monotonic);
    _ = h.link.idle(&out);

    try testing.expectEqual(@as(u32, 1), h.fake.destroys);
    try testing.expect(!h.link.isOpen());
    try testing.expect(!h.host_state.gui_closed.load(.monotonic));
    try testing.expect(!h.host_state.gui_destroyed.load(.monotonic));
    // The instance is still alive, so the editor can be opened again.
    try testing.expect(h.link.available());
    try h.link.open("Synth");
    try testing.expectEqual(@as(u32, 2), h.fake.creates);
}

test "GUI: a resize request with no host window is consumed and sends no set_size" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("Synth");
    var out: [1]events.ClapParamEdit = undefined;

    h.host_state.gui_resize.store((@as(u64, 640) << 32) | 480, .monotonic);
    _ = h.link.idle(&out);
    try testing.expectEqual(@as(u64, 0), h.host_state.gui_resize.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), h.fake.sizes);
}

test "GUI: close destroys an open editor once, and is a no-op after" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("Synth");

    h.link.close();
    try testing.expectEqual(@as(u32, 1), h.fake.destroys);
    try testing.expect(!h.link.isOpen());

    h.link.close();
    try testing.expectEqual(@as(u32, 1), h.fake.destroys);
}

test "GUI: saveState returns the plugin's bytes, and null when the plugin refuses or has no state" {
    var h: Harness = .{};
    h.setup();
    h.fake.state = "seridian-state";

    const saved = (try h.link.saveState(testing.allocator)).?;
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("seridian-state", saved);

    h.fake.state_ok = false;
    try testing.expect((try h.link.saveState(testing.allocator)) == null);

    h.fake.state_ok = true;
    h.link.attach(&h.plugin, &h.gui, null);
    try testing.expect((try h.link.saveState(testing.allocator)) == null);
}

test "GUI: kill on the main thread destroys an open editor, then the link answers nothing" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("Synth");
    var out: [1]events.ClapParamEdit = undefined;

    h.link.kill();
    try testing.expectEqual(@as(u32, 1), h.fake.destroys);
    try testing.expect(!h.link.available());
    try testing.expect(!h.link.isOpen());
    try testing.expectEqual(@as(usize, 0), h.link.idle(&out));
    try testing.expect((try h.link.saveState(testing.allocator)) == null);
    try testing.expectError(error.NoEditor, h.link.open("Synth"));
}

test "GUI: kill off the main thread abandons an open editor without calling the plugin" {
    var h: Harness = .{};
    h.setup();
    try h.link.open("Synth");

    h.link.is_main_thread = neverMain;
    h.link.kill();
    try testing.expectEqual(@as(u32, 0), h.fake.destroys);
    try testing.expect(!h.link.available());
    try testing.expect(!h.link.isOpen());
}
