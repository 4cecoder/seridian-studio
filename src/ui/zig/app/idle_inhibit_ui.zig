//! Keeps the screen awake and blocks suspend while the transport plays or records (idle_inhibit.zig decides,
//! idle_inhibit_linux.zig talks to logind, the session's screensaver service and X11). Every backend fails soft
//! with one logged warning. Not part of the C translation: added after it.

const std = @import("std");
const ext = @import("externs.zig");
const fns = @import("fns.zig");
const st = @import("state.zig");
const inhibit = @import("../idle_inhibit.zig");
const linux = @import("../idle_inhibit_linux.zig");

const app = &st.app;
const log = std.log.scoped(.idle_inhibit);

/// Process-global, UI thread only. `backends` stays at this address while `inhibitor` borrows its list.
var backends: linux.Backends = .{};
var inhibitor: ?inhibit.Inhibitor = null;

/// Loads the backends (X11 only with a window system) and starts watching the transport.
pub fn idle_inhibit_init() void {
    backends.init(!@import("ui_options").headless);
    inhibitor = inhibit.Inhibitor.init(backends.slice()) catch |err| {
        log.warn("idle inhibit disabled: {s}", .{@errorName(err)});
        backends.deinit();
        return;
    };
}

/// Once per frame: playing or recording takes the inhibitors, stopping drops them after a grace period.
pub fn idle_inhibit_tick() void {
    const active = if (inhibitor) |*value| value else return;
    const playing = ext.audio_engine_is_playing(app.engine) != 0;
    const recording = playing and fns.any_track_armed() != 0;
    active.update(.{ .playing = playing, .recording = recording }, fns.monotonic_seconds());
}

/// Drops every inhibitor and unloads the libraries. Call before Rshutdown.
pub fn idle_inhibit_shutdown() void {
    if (inhibitor) |*active| active.releaseAll();
    inhibitor = null;
    backends.deinit();
}
