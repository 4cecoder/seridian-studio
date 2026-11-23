//! Raven glue for the rotary knob. Mirrors src/ui/knob.c: a CUSTOM widget that
//! paints itself and turns mouse input into value changes. The value, angle and
//! drag rules live in knob_math.zig; this file only talks to Raven.
//!
//! C callers reach it through seridian_knob_create, declared for the window in app/externs.zig.
//!
//! The Raven API is declared by hand because @cImport is gone in this toolchain.
//! Signatures come from vendor/raven/include/raven/*.h. Enum values and the
//! REvent layout were checked against those headers with a C probe (sizeof 68,
//! type at 0, window at 4, x at 12, button at 44, clicks at 48, modifiers at 56).

const std = @import("std");
const math = @import("knob_math.zig");

// ---- Raven types and constants (raven_core.h, raven_widget.h, raven_window.h) ----

pub const Rid = u32;
const r_invalid_id: Rid = std.math.maxInt(Rid);
const r_true: c_int = 1;
const r_false: c_int = 0;

/// RWidgetType value of R_WIDGET_CUSTOM.
const r_widget_custom: c_int = 543;
/// REventType values.
const r_event_mouse_move: c_int = 193;
const r_event_mouse_down: c_int = 194;
const r_event_mouse_up: c_int = 195;
/// RMouseButton value of R_MOUSE_LEFT.
const r_mouse_left: c_int = 0;
/// RModifier value of R_MOD_SHIFT (a bit in REvent.modifiers).
const r_mod_shift: u32 = 1;

/// Opaque painter handle (`typedef struct RPainter RPainter;`).
pub const RPainter = opaque {};

/// Mirror of `REvent` from raven_window.h. Field order and types must match the C struct.
pub const RavenEvent = extern struct {
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

pub const RPaintCallback = *const fn (Rid, *RPainter, f32, f32, ?*anyopaque) callconv(.c) void;
pub const RWidgetEventCallback = *const fn (Rid, *const RavenEvent, ?*anyopaque) callconv(.c) c_int;
pub const RWidgetDestroyCallback = *const fn (Rid, ?*anyopaque) callconv(.c) void;
/// `SeridianEventHandler` from window_input.zig. The event pointer is an `REvent *`.
pub const SeridianEventHandler = *const fn (?*anyopaque, ?*const anyopaque) callconv(.c) c_int;

extern fn Rwidget_create(widget_type: c_int) Rid;
extern fn Rwidget_set_size(widget: Rid, width: f32, height: f32) void;
extern fn Rwidget_invalidate(widget: Rid) void;
extern fn Rwidget_set_event_callback(widget: Rid, callback: RWidgetEventCallback, user_data: ?*anyopaque) void;
extern fn Rwidget_set_destroy_callback(widget: Rid, callback: RWidgetDestroyCallback, user_data: ?*anyopaque) void;
extern fn Rcustom_set_paint_callback(widget: Rid, callback: RPaintCallback, user_data: ?*anyopaque) void;
extern fn Rdraw_circle(painter: *RPainter, center_x: f32, center_y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rdraw_line(painter: *RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void;

/// Process-wide window input dispatcher from window_input.c. Returns 0 on success.
extern fn seridian_window_input_add(handler: SeridianEventHandler, context: ?*anyopaque) c_int;

// ---- Public C ABI (mirrored in app/externs.zig) ----

/// Called with the new value after every change. Matches `SeridianKnobChanged`.
pub const SeridianKnobChanged = ?*const fn (f32, ?*anyopaque) callconv(.c) void;

/// Matches `SeridianKnobConfig` in app/externs.zig.
pub const SeridianKnobConfig = extern struct {
    minimum: f32,
    maximum: f32,
    value: f32,
    default_value: f32,
    diameter: f32,
    /// Non-zero for bipolar knobs (pan): the value arc starts at the centre.
    bipolar: c_int,
    on_change: SeridianKnobChanged,
    user_data: ?*anyopaque,
};

// ---- Palette (copied from src/ui/zig/palette.zig, same float values) ----

const Color = struct { r: f32, g: f32, b: f32, a: f32 };

const palette_panel: Color = .{ .r = 0.063, .g = 0.071, .b = 0.165, .a = 1.0 };
const palette_muted: Color = .{ .r = 0.420, .g = 0.478, .b = 0.600, .a = 1.0 };
const palette_neon_cyan: Color = .{ .r = 0.000, .g = 0.941, .b = 1.000, .a = 1.0 };
const palette_text: Color = .{ .r = 0.902, .g = 0.969, .b = 1.000, .a = 1.0 };

// ---- Drawing constants (knob.c) ----

const track_thickness: f32 = 2.0;
const value_thickness: f32 = 2.5;
const indicator_thickness: f32 = 2.0;
const arc_segments: u32 = 36;

// ---- Widget state ----

/// Per-knob state owned by the widget. Freed by the destroy callback.
const State = struct {
    knob: math.Knob,
    on_change: SeridianKnobChanged,
    user_data: ?*anyopaque,
};

/// Knob that currently owns a drag. Moves and release are read by the window hook,
/// because Raven stops sending a widget its moves once the pointer leaves it.
var active_state: ?*State = null;
var active_widget: Rid = r_invalid_id;
var window_handler_registered = false;

fn stateOf(user_data: ?*anyopaque) ?*State {
    const raw = user_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn clearActive() void {
    active_state = null;
    active_widget = r_invalid_id;
}

/// Calls on_change once when the knob's value changed during the last operation.
fn notifyIfChanged(state: *State, changes_before: u32) void {
    if (state.knob.changes == changes_before) return;
    if (state.on_change) |callback| callback(state.knob.value, state.user_data);
}

// ---- Painting ----

fn drawArc(painter: *RPainter, cx: f32, cy: f32, radius: f32, from: f64, to: f64, thickness: f32, color: Color) void {
    const lo = @min(from, to);
    const hi = @max(from, to);
    if (hi <= lo) return;

    var previous = math.pointOnCircle(cx, cy, radius, math.angleDegrees(lo));
    var step: u32 = 1;
    while (step <= arc_segments) : (step += 1) {
        const t = lo + (hi - lo) * @as(f64, @floatFromInt(step)) / @as(f64, arc_segments);
        const next = math.pointOnCircle(cx, cy, radius, math.angleDegrees(t));
        Rdraw_line(painter, previous.x, previous.y, next.x, next.y, thickness, color.r, color.g, color.b, color.a);
        previous = next;
    }
}

fn paintKnob(widget: Rid, painter: *RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const state = stateOf(user_data) orelse return;

    const cx = width * 0.5;
    const cy = height * 0.5;
    const radius = math.paintRadius(width, height);
    const position = state.knob.position();
    const origin = state.knob.arcOrigin();

    Rdraw_circle(painter, cx, cy, radius, palette_panel.r, palette_panel.g, palette_panel.b, palette_panel.a);
    drawArc(painter, cx, cy, radius, 0.0, 1.0, track_thickness, palette_muted);
    drawArc(painter, cx, cy, radius, origin, position, value_thickness, palette_neon_cyan);

    const angle = math.angleDegrees(position);
    const hub = math.pointOnCircle(cx, cy, radius * 0.25, angle);
    const tip = math.pointOnCircle(cx, cy, radius * 0.85, angle);
    Rdraw_line(painter, hub.x, hub.y, tip.x, tip.y, indicator_thickness, palette_text.r, palette_text.g, palette_text.b, palette_text.a);
}

// ---- Events ----

/// Widget-level handler. A left press starts a drag, or resets on a double click.
fn handleWidgetEvent(widget: Rid, event: *const RavenEvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const state = stateOf(user_data) orelse return r_false;
    if (event.type != r_event_mouse_down or event.button != r_mouse_left) return r_false;

    const changes_before = state.knob.changes;
    if (!state.knob.press(true, event.clicks, event.y)) return r_false;
    if (state.knob.dragging) {
        active_state = state;
        active_widget = widget;
    }
    notifyIfChanged(state, changes_before);
    Rwidget_invalidate(widget);
    return r_true;
}

/// Window-level handler, called through the shared window input dispatcher.
fn handleWindowEvent(context: ?*anyopaque, raw_event: ?*const anyopaque) callconv(.c) c_int {
    _ = context;
    const state = active_state orelse return r_false;
    const raw = raw_event orelse return r_false;
    const event: *const RavenEvent = @ptrCast(@alignCast(raw));

    switch (event.type) {
        r_event_mouse_move => {
            const changes_before = state.knob.changes;
            const fine = (event.modifiers & r_mod_shift) != 0;
            if (!state.knob.move(event.y, fine)) return r_false;
            notifyIfChanged(state, changes_before);
            Rwidget_invalidate(active_widget);
            return r_true;
        },
        r_event_mouse_up => {
            if (!state.knob.release(event.button == r_mouse_left)) return r_false;
            clearActive();
            return r_true;
        },
        else => return r_false,
    }
}

/// Registers handleWindowEvent with the window dispatcher once, on first use.
fn registerWindowHandler() bool {
    if (window_handler_registered) return true;
    if (seridian_window_input_add(handleWindowEvent, null) != 0) return false;
    window_handler_registered = true;
    return true;
}

fn destroyKnob(widget: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const state = stateOf(user_data) orelse return;
    if (active_state == state) clearActive();
    std.heap.c_allocator.destroy(state);
}

// ---- Exported C API ----

/// Creates a knob widget. Returns R_INVALID_ID when the config is NULL, the window
/// hook cannot be installed, or Raven fails to create the widget. The widget owns
/// its state and frees it on destroy.
pub export fn seridian_knob_create(config: ?*const SeridianKnobConfig) callconv(.c) Rid {
    const cfg = config orelse return r_invalid_id;
    if (!registerWindowHandler()) return r_invalid_id;

    const state = std.heap.c_allocator.create(State) catch return r_invalid_id;
    state.* = .{
        .knob = .{
            .minimum = cfg.minimum,
            .maximum = cfg.maximum,
            .default_value = cfg.default_value,
            .value = cfg.value,
            .bipolar = cfg.bipolar != 0,
        },
        .on_change = cfg.on_change,
        .user_data = cfg.user_data,
    };

    const widget = Rwidget_create(r_widget_custom);
    if (widget == r_invalid_id) {
        std.heap.c_allocator.destroy(state);
        return r_invalid_id;
    }
    Rwidget_set_size(widget, cfg.diameter, cfg.diameter);
    Rcustom_set_paint_callback(widget, paintKnob, state);
    Rwidget_set_event_callback(widget, handleWidgetEvent, state);
    Rwidget_set_destroy_callback(widget, destroyKnob, state);
    return widget;
}
