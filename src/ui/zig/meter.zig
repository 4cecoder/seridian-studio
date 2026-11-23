//! Stereo peak meter widget for Raven. Glue between meter_math.zig (dB, hold
//! and clip rules) and the Raven widget API. Mirrors the knob widget in
//! src/ui/knob.c: the widget owns its state, frees it on destroy, and handles
//! its own mouse events. Colours come from src/ui/zig/palette.zig.
//!
//! C ABI (C callers declare these themselves, matching the layout below):
//!
//!   typedef struct SeridianMeterConfig {
//!       float width;
//!       float height;
//!       float hold_decay_db_per_s;   /* peak hold fall rate; <= 0 holds forever */
//!   } SeridianMeterConfig;
//!   typedef struct SeridianMeter SeridianMeter;   /* opaque */
//!
//!   Rid seridian_meter_create(const SeridianMeterConfig *config,
//!                             SeridianMeter **out_meter);
//!   int  seridian_meter_set_levels(SeridianMeter *meter, float left_linear,
//!                                  float right_linear, float dt_s);
//!   void seridian_meter_clear_clip(SeridianMeter *meter);
//!
//! Levels are linear peak amplitudes for the block that lasted dt_s seconds.
//! The meter is freed by Rwidget_destroy on the returned widget; after that the
//! SeridianMeter pointer is dangling and must not be used.

const std = @import("std");
const math = @import("meter_math.zig");

// ---- Raven API, hand-declared (no @cImport). Matches vendor/raven/include/raven/. ----

/// Rid in raven_core.h (uint32_t). R_INVALID_ID is (Rid)-1.
pub const Rid = u32;
const r_invalid_id: Rid = std.math.maxInt(Rid);
const r_false: c_int = 0;
const r_true: c_int = 1;
/// R_WIDGET_CUSTOM in raven_widget.h: 0x0200 (R_WIDGET_VBOX) + 31.
const r_widget_custom: c_int = 0x021F;
/// R_EVENT_MOUSE_DOWN in raven_window.h: 0x00C0 (R_EVENT_NONE) + 2.
const r_event_mouse_down: c_int = 0x00C2;
/// R_MOUSE_LEFT in raven_window.h.
const r_mouse_left: c_int = 0;

/// Opaque painter, RPainter in raven_draw.h.
const RPainter = opaque {};

/// REvent in raven_window.h. Field order and C-sized types must match exactly.
const REvent = extern struct {
    kind: c_int,
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

const PaintCallback = *const fn (Rid, *RPainter, f32, f32, ?*anyopaque) callconv(.c) void;
const EventCallback = *const fn (Rid, *const REvent, ?*anyopaque) callconv(.c) c_int;
const DestroyCallback = *const fn (Rid, ?*anyopaque) callconv(.c) void;

extern fn Rwidget_create(widget_type: c_int) callconv(.c) Rid;
extern fn Rwidget_set_size(widget: Rid, width: f32, height: f32) callconv(.c) void;
extern fn Rwidget_invalidate(widget: Rid) callconv(.c) void;
extern fn Rwidget_set_event_callback(widget: Rid, callback: EventCallback, user_data: ?*anyopaque) callconv(.c) void;
extern fn Rwidget_set_destroy_callback(widget: Rid, callback: DestroyCallback, user_data: ?*anyopaque) callconv(.c) void;
extern fn Rcustom_set_paint_callback(widget: Rid, callback: PaintCallback, user_data: ?*anyopaque) callconv(.c) void;
extern fn Rdraw_rect(painter: *RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) callconv(.c) void;
extern fn Rdraw_line(painter: *RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) callconv(.c) void;

// ---- Palette (src/ui/zig/palette.zig). ----

const Rgba = struct { r: f32, g: f32, b: f32, a: f32 };

const palette_panel: Rgba = .{ .r = 0.063, .g = 0.071, .b = 0.165, .a = 1.0 };
const palette_deep: Rgba = .{ .r = 0.039, .g = 0.043, .b = 0.102, .a = 1.0 };
const palette_muted: Rgba = .{ .r = 0.420, .g = 0.478, .b = 0.600, .a = 1.0 };
const palette_neon_cyan: Rgba = .{ .r = 0.000, .g = 0.941, .b = 1.000, .a = 1.0 };
const palette_neon_magenta: Rgba = .{ .r = 1.000, .g = 0.169, .b = 0.839, .a = 1.0 };
const palette_text: Rgba = .{ .r = 0.902, .g = 0.969, .b = 1.000, .a = 1.0 };

// ---- Layout (pixels, logical units). ----

const outer_margin: f32 = 3.0;
const bar_gap: f32 = 3.0;
const clip_cap_height: f32 = 4.0;
const clip_gap: f32 = 2.0;
const hold_thickness: f32 = 2.0;
const channel_count = 2;

/// Creation parameters, SeridianMeterConfig in the C ABI.
pub const SeridianMeterConfig = extern struct {
    width: f32,
    height: f32,
    hold_decay_db_per_s: f32,
};

/// Per-widget state. Pure data plus rules; Raven is only touched by the glue below.
pub const Meter = struct {
    widget: Rid,
    hold_decay_db_per_s: f32,
    /// Current level per channel (left, right) in dB.
    level_db: [channel_count]f32 = .{ math.min_db, math.min_db },
    /// Peak hold per channel in dB.
    hold_db: [channel_count]f32 = .{ math.min_db, math.min_db },
    /// Clip latch per channel; stays set until clearClip.
    clip: [channel_count]bool = .{ false, false },

    /// Feeds one block of linear peak levels that lasted dt_s seconds.
    pub fn update(self: *Meter, left_linear: f32, right_linear: f32, dt_s: f32) void {
        const samples = [channel_count]f32{ left_linear, right_linear };
        for (samples, 0..) |raw_sample, ch| {
            // Non-finite samples read as silence for this frame; clip is not latched by them.
            const sample = math.sanitizeSample(raw_sample);
            const db = math.linearToDb(sample);
            self.level_db[ch] = db;
            self.hold_db[ch] = math.peakHoldDb(self.hold_db[ch], db, dt_s, self.hold_decay_db_per_s);
            self.clip[ch] = math.clipLatch(self.clip[ch], sample);
        }
    }

    /// Releases both clip latches.
    pub fn clearClip(self: *Meter) void {
        self.clip = .{ false, false };
    }
};

fn meterOf(user_data: ?*anyopaque) ?*Meter {
    const raw = user_data orelse return null;
    return @ptrCast(@alignCast(raw));
}

fn fillRect(painter: *RPainter, x: f32, y: f32, w: f32, h: f32, color: Rgba) void {
    Rdraw_rect(painter, x, y, w, h, 0.0, color.r, color.g, color.b, color.a);
}

/// Paints the widget. Each channel is a vertical bar: level fill from the bottom,
/// a peak hold tick, and a clip cap at the top that lights up when latched.
fn paint(widget: Rid, painter: *RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const meter = meterOf(user_data) orelse return;

    fillRect(painter, 0.0, 0.0, width, height, palette_panel);

    const inner_w = @max(width - 2.0 * outer_margin, 0.0);
    const bar_w = @max((inner_w - bar_gap) / channel_count, 0.0);
    const top = outer_margin + clip_cap_height + clip_gap;
    const bottom = height - outer_margin;
    const track_h = @max(bottom - top, 0.0);

    for (0..channel_count) |ch| {
        const x = outer_margin + @as(f32, @floatFromInt(ch)) * (bar_w + bar_gap);
        fillRect(painter, x, top, bar_w, track_h, palette_deep);

        const level_h = math.dbToNormalized(meter.level_db[ch], math.min_db, math.max_db) * track_h;
        if (level_h > 0.0) fillRect(painter, x, bottom - level_h, bar_w, level_h, palette_neon_cyan);

        if (meter.hold_db[ch] > math.min_db) {
            const hold_y = bottom - math.dbToNormalized(meter.hold_db[ch], math.min_db, math.max_db) * track_h;
            Rdraw_line(painter, x, hold_y, x + bar_w, hold_y, hold_thickness, palette_text.r, palette_text.g, palette_text.b, palette_text.a);
        }

        const cap = if (meter.clip[ch]) palette_neon_magenta else palette_muted;
        fillRect(painter, x, outer_margin, bar_w, clip_cap_height, cap);
    }
}

/// A left press clears the clip latches, as on a DAW meter. Other events pass on.
fn handleEvent(widget: Rid, event: *const REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = widget;
    const meter = meterOf(user_data) orelse return r_false;
    if (event.kind != r_event_mouse_down or event.button != r_mouse_left) return r_false;
    meter.clearClip();
    Rwidget_invalidate(meter.widget);
    return r_true;
}

fn destroyCallback(widget: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const meter = meterOf(user_data) orelse return;
    std.heap.c_allocator.destroy(meter);
}

/// Creates the meter widget. On success returns its Rid and stores the state
/// pointer in *out_meter. On failure returns R_INVALID_ID and sets *out_meter to NULL.
export fn seridian_meter_create(config: *const SeridianMeterConfig, out_meter: *?*Meter) callconv(.c) Rid {
    out_meter.* = null;

    const meter = std.heap.c_allocator.create(Meter) catch return r_invalid_id;
    const widget = Rwidget_create(r_widget_custom);
    if (widget == r_invalid_id) {
        std.heap.c_allocator.destroy(meter);
        return r_invalid_id;
    }

    meter.* = .{
        .widget = widget,
        .hold_decay_db_per_s = config.hold_decay_db_per_s,
    };
    Rwidget_set_size(widget, config.width, config.height);
    Rcustom_set_paint_callback(widget, paint, meter);
    Rwidget_set_event_callback(widget, handleEvent, meter);
    Rwidget_set_destroy_callback(widget, destroyCallback, meter);

    out_meter.* = meter;
    return widget;
}

/// Feeds the meter one block of linear peak levels (dt_s seconds long) and
/// repaints it. Returns R_TRUE, or R_FALSE when meter is NULL.
export fn seridian_meter_set_levels(meter: ?*Meter, left_linear: f32, right_linear: f32, dt_s: f32) callconv(.c) c_int {
    const m = meter orelse return r_false;
    m.update(left_linear, right_linear, dt_s);
    Rwidget_invalidate(m.widget);
    return r_true;
}

/// Clears both clip latches and repaints.
export fn seridian_meter_clear_clip(meter: ?*Meter) callconv(.c) void {
    const m = meter orelse return;
    m.clearClip();
    Rwidget_invalidate(m.widget);
}

test "update sets levels and holds the peak" {
    var meter: Meter = .{ .widget = 0, .hold_decay_db_per_s = 20.0 };
    meter.update(1.0, 0.5, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), meter.level_db[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -6.0206), meter.level_db[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), meter.hold_db[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -6.0206), meter.hold_db[1], 1e-4);
}

test "peak hold decays between quiet blocks" {
    var meter: Meter = .{ .widget = 0, .hold_decay_db_per_s = 20.0 };
    meter.update(1.0, 1.0, 0.0);
    meter.update(0.0, 0.0, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, -10.0), meter.hold_db[0], 1e-4);
    try std.testing.expectEqual(math.min_db, meter.level_db[0]);
}

test "clip latches above full scale and clears on request" {
    var meter: Meter = .{ .widget = 0, .hold_decay_db_per_s = 20.0 };
    meter.update(0.9, 1.2, 0.01);
    try std.testing.expect(!meter.clip[0]);
    try std.testing.expect(meter.clip[1]);
    meter.update(0.0, 0.0, 0.01);
    try std.testing.expect(meter.clip[1]);
    meter.clearClip();
    try std.testing.expect(!meter.clip[0]);
    try std.testing.expect(!meter.clip[1]);
}
