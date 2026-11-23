//! Window-level input dispatch for Raven. Raven allows one event hook per window, so this module installs that
//! single hook and fans events out to every registered handler through an InputDispatcher.
//!
//! Translated from src/ui/window_input.c (and window_input.h). The three functions keep their C ABI exports:
//! the knob and piano roll static libraries call seridian_window_input_add through `extern`.

const std = @import("std");
const raven = @import("raven");
const dispatch = @import("input_dispatch.zig");

/// Handler for window events. `event` is really a `const REvent *`; the handler casts it. Return non-zero to
/// consume the event and stop later handlers from seeing it.
pub const SeridianEventHandler = dispatch.InputHandler;

var window_input_dispatcher: dispatch.InputDispatcher = std.mem.zeroes(dispatch.InputDispatcher);
var window_input_dispatcher_ready: c_int = 0;
var window_input_installed: c_int = 0;

/// Ensures the dispatcher is initialised before first use.
fn window_input_ensure_ready() void {
    if (window_input_dispatcher_ready != 0) return;
    dispatch.input_dispatcher_init(&window_input_dispatcher);
    window_input_dispatcher_ready = 1;
}

fn window_input_hook(window: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    if (event == null) return raven.R_FALSE;
    return if (dispatch.input_dispatch(&window_input_dispatcher, event) != 0) raven.R_TRUE else raven.R_FALSE;
}

/// Installs the Raven window hook that forwards events to the dispatcher. Call exactly once per window. A second
/// call is ignored.
pub export fn seridian_window_input_install(window: raven.Rid) callconv(.c) void {
    if (window_input_installed != 0) return;
    window_input_installed = 1;
    window_input_ensure_ready();
    raven.Rwindow_set_event_hook(window, window_input_hook, null);
}

/// Registers a handler on the process-wide dispatcher. Returns 0 on success, or -1 when the handler is null or the
/// dispatcher is full. The context is borrowed for the life of the process.
pub export fn seridian_window_input_add(handler: SeridianEventHandler, context: ?*anyopaque) callconv(.c) c_int {
    window_input_ensure_ready();
    return dispatch.input_dispatcher_add(&window_input_dispatcher, handler, context);
}

/// Runs `event` (a `const REvent *`) through the registered handlers, as if the main window had received it.
/// For a second window whose pointer drags (the Mixer popout's knobs) must reach the same handlers. Returns
/// non-zero when a handler consumed the event.
pub export fn seridian_window_input_dispatch(event: ?*const anyopaque) callconv(.c) c_int {
    if (event == null) return 0;
    window_input_ensure_ready();
    return if (dispatch.input_dispatch(&window_input_dispatcher, event) != 0) 1 else 0;
}
