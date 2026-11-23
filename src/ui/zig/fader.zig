//! Volume fader for Raven, the Zig counterpart of src/ui/knob.c.
//!
//! Vertical slider over a linear gain value. Drag up or down to change the
//! level (hold shift for fine control), double-click to jump to 0 dB. The
//! gain <-> dB <-> position rules live in fader_math.zig. Raven is reached
//! through hand-declared extern fns because @cImport is gone in this toolchain.
//!
//! C callers include the matching declarations (see seridian_fader_create).
const std = @import("std");
const math = @import("fader_math.zig");

/// Raven object handle (uint32_t in raven_core.h).
const Rid = u32;
const invalid_id: Rid = std.math.maxInt(u32);
const r_false: c_int = 0;
const r_true: c_int = 1;

// Raven enums, values from raven_widget.h / raven_window.h (checked against the header).
const r_widget_custom: c_int = 543;
const r_event_mouse_move: c_int = 193;
const r_event_mouse_down: c_int = 194;
const r_event_mouse_up: c_int = 195;
const r_mouse_left: c_int = 0;
const r_mod_shift: u32 = 1 << 0;

/// Opaque Raven painter (RPainter in raven_draw.h).
const RPainter = opaque {};

/// Mirror of REvent in raven_window.h (68 bytes on LP64, offsets checked with offsetof).
const REvent = extern struct {
    type: c_int,
    window: Rid,
    target: Rid,
    x: f32,
    y: f32,
    local_x: f32,
    local_y: f32,
    delta_x: f32,
    delta_y: f32,
    wheel_x: f32,
    wheel_y: f32,
    button: c_int,
    clicks: c_int,
    key: c_int,
    modifiers: u32,
    repeat: c_int,
    codepoint: u32,
};

const PaintCallback = *const fn (widget: Rid, painter: *RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void;
const EventCallback = *const fn (widget: Rid, event: *const REvent, user_data: ?*anyopaque) callconv(.c) c_int;
const DestroyCallback = *const fn (widget: Rid, user_data: ?*anyopaque) callconv(.c) void;
const WindowHandler = *const fn (context: ?*anyopaque, event: *const anyopaque) callconv(.c) c_int;

extern fn Rwidget_create(kind: c_int) Rid;
extern fn Rwidget_set_size(widget: Rid, width: f32, height: f32) void;
extern fn Rwidget_invalidate(widget: Rid) void;
extern fn Rcustom_set_paint_callback(widget: Rid, callback: PaintCallback, user_data: ?*anyopaque) void;
extern fn Rwidget_set_event_callback(widget: Rid, callback: EventCallback, user_data: ?*anyopaque) void;
extern fn Rwidget_set_destroy_callback(widget: Rid, callback: DestroyCallback, user_data: ?*anyopaque) void;
extern fn Rdraw_rect(painter: *RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rdraw_line(painter: *RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn seridian_window_input_add(handler: WindowHandler, context: ?*anyopaque) c_int;

// Colours from src/ui/zig/palette.zig (palette_panel, palette_muted, palette_neon_cyan, palette_text).
const Color = struct { r: f32, g: f32, b: f32, a: f32 };
const color_muted = Color{ .r = 0.420, .g = 0.478, .b = 0.600, .a = 1.0 };
const color_neon_cyan = Color{ .r = 0.000, .g = 0.941, .b = 1.000, .a = 1.0 };
const color_text = Color{ .r = 0.902, .g = 0.969, .b = 1.000, .a = 1.0 };

const track_margin: f32 = 6.0;
const track_thickness: f32 = 2.0;
const value_thickness: f32 = 2.5;
const tick_half_width: f32 = 4.0;
const thumb_width: f32 = 14.0;
const thumb_height: f32 = 4.0;
const thumb_radius: f32 = 1.0;

/// Called after the gain changes; `gain` is linear (1.0 = 0 dB).
pub const FaderChanged = *const fn (gain: f32, user_data: ?*anyopaque) callconv(.c) void;

/// Config for seridian_fader_create. Layout matches the C struct SeridianFaderConfig.
pub const FaderConfig = extern struct {
    /// Initial linear gain; values outside [0, 2] are clamped by the dB mapping.
    gain: f32,
    width: f32,
    height: f32,
    on_change: ?FaderChanged,
    user_data: ?*anyopaque,
};

/// Widget state, the Zig counterpart of KnobState in knob.c.
const FaderState = struct {
    gain: f32,
    dragging: bool = false,
    drag_start_y: f32 = 0,
    drag_start_position: f64 = 0,
    on_change: ?FaderChanged,
    user_data: ?*anyopaque,

    fn position(self: *const FaderState) f64 {
        return math.gainToPosition(self.gain);
    }

    fn notify(self: *const FaderState) void {
        if (self.on_change) |callback| callback(self.gain, self.user_data);
    }

    /// Moves the fader to a normalized position, notifying only on a real change.
    fn applyPosition(self: *FaderState, normalized: f64) void {
        const next: f32 = @floatCast(math.positionToGain(normalized));
        if (next == self.gain) return;
        self.gain = next;
        self.notify();
    }
};

/// Fader that receives window-level moves and release while its drag is live.
var active_state: ?*FaderState = null;
var active_widget: Rid = invalid_id;
var window_handler_registered = false;

fn stateOf(user_data: ?*anyopaque) ?*FaderState {
    const raw = user_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn drawLine(painter: *RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: Color) void {
    Rdraw_line(painter, x0, y0, x1, y1, thickness, color.r, color.g, color.b, color.a);
}

fn paint(widget: Rid, painter: *RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const state = stateOf(user_data) orelse return;

    const cx = width * 0.5;
    const top = track_margin;
    const bottom = @max(top, height - track_margin);
    const travel = bottom - top;
    const thumb_y = bottom - travel * @as(f32, @floatCast(state.position()));
    const unity_y = bottom - travel * @as(f32, @floatCast(math.unity_position));

    drawLine(painter, cx, top, cx, bottom, track_thickness, color_muted);
    drawLine(painter, cx, bottom, cx, thumb_y, value_thickness, color_neon_cyan);
    drawLine(painter, cx - tick_half_width, unity_y, cx + tick_half_width, unity_y, track_thickness, color_muted);
    Rdraw_rect(painter, cx - thumb_width * 0.5, thumb_y - thumb_height * 0.5, thumb_width, thumb_height, thumb_radius, color_text.r, color_text.g, color_text.b, color_text.a);
}

fn beginDrag(widget: Rid, state: *FaderState, y: f32) void {
    state.dragging = true;
    state.drag_start_y = y;
    state.drag_start_position = state.position();
    active_state = state;
    active_widget = widget;
}

fn endDrag() void {
    if (active_state) |state| state.dragging = false;
    active_state = null;
    active_widget = invalid_id;
}

fn handleEvent(widget: Rid, event: *const REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const state = stateOf(user_data) orelse return r_false;
    if (event.type != r_event_mouse_down or event.button != r_mouse_left) return r_false;

    if (math.isResetClick(event.clicks)) {
        state.applyPosition(math.resetPosition());
        Rwidget_invalidate(widget);
        return r_true;
    }
    beginDrag(widget, state, event.y);
    return r_true;
}

/// Window-level handler, called through the shared window input dispatcher.
fn windowHandler(context: ?*anyopaque, raw_event: *const anyopaque) callconv(.c) c_int {
    _ = context;
    const event: *const REvent = @ptrCast(@alignCast(raw_event));
    const state = active_state orelse return r_false;

    switch (event.type) {
        r_event_mouse_move => {
            const fine = (event.modifiers & r_mod_shift) != 0;
            const dy: f64 = @floatCast(event.y - state.drag_start_y);
            state.applyPosition(math.dragPosition(state.drag_start_position, dy, fine));
            Rwidget_invalidate(active_widget);
            return r_true;
        },
        r_event_mouse_up => {
            if (event.button != r_mouse_left) return r_false;
            endDrag();
            return r_true;
        },
        else => return r_false,
    }
}

/// Registers windowHandler with the window dispatcher once, on first use.
fn registerWindowHandler() bool {
    if (window_handler_registered) return true;
    if (seridian_window_input_add(windowHandler, null) != 0) return false;
    window_handler_registered = true;
    return true;
}

fn destroy(widget: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const state = stateOf(user_data) orelse return;
    if (active_state == state) endDrag();
    std.heap.c_allocator.destroy(state);
}

/// Creates a fader widget. The widget owns its state and frees it on destroy.
/// Returns R_INVALID_ID (UINT32_MAX) on failure or when config is NULL.
export fn seridian_fader_create(config: ?*const FaderConfig) callconv(.c) Rid {
    const cfg = config orelse return invalid_id;
    if (!registerWindowHandler()) return invalid_id;

    const state = std.heap.c_allocator.create(FaderState) catch return invalid_id;
    state.* = .{
        .gain = cfg.gain,
        .on_change = cfg.on_change,
        .user_data = cfg.user_data,
    };

    const widget = Rwidget_create(r_widget_custom);
    Rwidget_set_size(widget, cfg.width, cfg.height);
    Rcustom_set_paint_callback(widget, paint, state);
    Rwidget_set_event_callback(widget, handleEvent, state);
    Rwidget_set_destroy_callback(widget, destroy, state);
    return widget;
}
