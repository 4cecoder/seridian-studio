//! Waveform widget glue for Raven. Mirrors src/ui/knob.c: a CUSTOM widget
//! painted by callbacks, whose state the widget owns and frees on destroy.
//! Peak-to-column rules live in waveform_math.zig; this file only talks to Raven.
//!
//! The view is read-only: its event callback consumes nothing. Colours come
//! from src/ui/zig/palette.zig (palette_panel, palette_muted, palette_neon_cyan).
//!
//! Raven is declared by hand (no @cImport in this toolchain). Signatures and
//! enum values were checked against vendor/raven/include/raven/*.h, and the
//! REvent layout was checked with a C probe (sizeof 68, clicks at 48).

const std = @import("std");
const wm = @import("waveform_math.zig");

const allocator = std.heap.c_allocator;

pub const Rid = u32;
const R_INVALID_ID: Rid = std.math.maxInt(Rid);
const R_TRUE: c_int = 1;
const R_FALSE: c_int = 0;

/// RWidgetType value of R_WIDGET_CUSTOM (raven_widget.h).
const R_WIDGET_CUSTOM: c_int = 543;

/// Pixel columns are capped so a huge logical width cannot exhaust memory.
const max_columns: f32 = 16384.0;
/// Empty space above and below the waveform, in logical units (as knob's outer margin).
const vertical_margin: f32 = 3.0;

pub const RPainter = opaque {};

/// Layout of REvent in raven_window.h (68 bytes on the 64-bit targets we build for).
pub const REvent = extern struct {
    event_type: c_int,
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

comptime {
    std.debug.assert(@sizeOf(REvent) == 68);
    std.debug.assert(@offsetOf(REvent, "clicks") == 48);
}

const PaintCallback = *const fn (Rid, *RPainter, f32, f32, ?*anyopaque) callconv(.c) void;
const EventCallback = *const fn (Rid, *const REvent, ?*anyopaque) callconv(.c) c_int;
const DestroyCallback = *const fn (Rid, ?*anyopaque) callconv(.c) void;

extern fn Rwidget_create(kind: c_int) Rid;
extern fn Rwidget_is_valid(widget: Rid) c_int;
extern fn Rwidget_set_size(widget: Rid, width: f32, height: f32) void;
extern fn Rwidget_set_user_handle(widget: Rid, handle: ?*anyopaque) void;
extern fn Rwidget_get_user_handle(widget: Rid) ?*anyopaque;
extern fn Rwidget_set_event_callback(widget: Rid, callback: EventCallback, user_data: ?*anyopaque) void;
extern fn Rwidget_set_destroy_callback(widget: Rid, callback: DestroyCallback, user_data: ?*anyopaque) void;
extern fn Rwidget_invalidate(widget: Rid) void;
extern fn Rcustom_set_paint_callback(widget: Rid, callback: PaintCallback, user_data: ?*anyopaque) void;
extern fn Rdraw_rect(painter: *RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rdraw_line(painter: *RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void;

const Color = struct { r: f32, g: f32, b: f32, a: f32 };

const panel: Color = .{ .r = 0.063, .g = 0.071, .b = 0.165, .a = 1.0 };
const muted: Color = .{ .r = 0.420, .g = 0.478, .b = 0.600, .a = 1.0 };
const neon_cyan: Color = .{ .r = 0.000, .g = 0.941, .b = 1.000, .a = 1.0 };

/// Peak as the C side passes it: min and max in [-1, 1].
pub const CPeak = extern struct {
    min: f32,
    max: f32,
};

/// Config for seridian_waveform_create, the counterpart of SeridianKnobConfig.
/// The peaks are copied, so the caller keeps ownership of its buffer.
pub const SeridianWaveformConfig = extern struct {
    peaks: ?[*]const CPeak,
    peak_count: usize,
    clip_length: f64,
    window_start: f64,
    window_end: f64,
    width: f32,
    height: f32,
};

const State = struct {
    /// Owned copy of the peaks, evenly spaced over clip_length.
    peaks: []wm.Peak = &.{},
    /// Scratch buffer for one paint: one entry per pixel column.
    columns: []wm.Peak = &.{},
    clip_length: f64 = 0.0,
    window: wm.Window = .{ .start = 0.0, .end = 0.0 },
};

fn freePeaks(slice: []wm.Peak) void {
    if (slice.len > 0) allocator.free(slice);
}

fn stateFromUserData(user_data: ?*anyopaque) ?*State {
    const raw = user_data orelse return null;
    const state: *State = @ptrCast(@alignCast(raw));
    return state;
}

/// Looks up the state of a live widget, or null for an invalid or foreign id.
fn stateOf(widget: Rid) ?*State {
    if (Rwidget_is_valid(widget) == R_FALSE) return null;
    return stateFromUserData(Rwidget_get_user_handle(widget));
}

fn fillRect(painter: *RPainter, x: f32, y: f32, width: f32, height: f32, color: Color) void {
    Rdraw_rect(painter, x, y, width, height, 0.0, color.r, color.g, color.b, color.a);
}

fn strokeLine(painter: *RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: Color) void {
    Rdraw_line(painter, x0, y0, x1, y1, thickness, color.r, color.g, color.b, color.a);
}

/// Returns a column buffer of exactly `count` entries, growing it when needed.
fn ensureColumns(state: *State, count: usize) std.mem.Allocator.Error![]wm.Peak {
    if (state.columns.len < count) {
        const grown = try allocator.alloc(wm.Peak, count);
        freePeaks(state.columns);
        state.columns = grown;
    }
    return state.columns[0..count];
}

/// Paints the background, the centre line and one vertical stroke per pixel
/// column. Runs on the UI thread. If the scratch buffer cannot grow, this frame
/// is drawn without the waveform and the next paint tries again.
fn paintWaveform(widget: Rid, painter: *RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const state = stateFromUserData(user_data) orelse return;

    fillRect(painter, 0.0, 0.0, width, height, panel);
    if (!(width >= 1.0) or !(height > 0.0)) return;

    const pixel_count: usize = @intFromFloat(@min(@floor(width), max_columns));
    const columns = ensureColumns(state, pixel_count) catch return;
    wm.peaksToColumns(state.peaks, state.clip_length, state.window, columns);

    const mid = height * 0.5;
    const amplitude = @max(mid - vertical_margin, 0.0);
    strokeLine(painter, 0.0, mid, width, mid, 1.0, muted);

    for (columns, 0..) |column, index| {
        const x = @as(f32, @floatFromInt(index)) + 0.5;
        const top = mid - @min(@max(column.max, -1.0), 1.0) * amplitude;
        const bottom = mid - @min(@max(column.min, -1.0), 1.0) * amplitude;
        strokeLine(painter, x, top, x, bottom, 1.0, neon_cyan);
    }
}

/// The view takes no input, so every event is passed on (R_FALSE).
fn handleEvent(widget: Rid, event: *const REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = widget;
    _ = event;
    _ = user_data;
    return R_FALSE;
}

/// Frees the state the widget owned. Raven calls this once when the widget is gone.
fn destroyWaveform(widget: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const state = stateFromUserData(user_data) orelse return;
    freePeaks(state.peaks);
    freePeaks(state.columns);
    allocator.destroy(state);
}

/// Replaces the owned peak copy. On failure the previous peaks stay in place.
fn replacePeaks(state: *State, source: []const CPeak) std.mem.Allocator.Error!void {
    const copy = try allocator.alloc(wm.Peak, source.len);
    for (source, copy) |src, *dst| dst.* = .{ .min = src.min, .max = src.max };
    freePeaks(state.peaks);
    state.peaks = copy;
}

/// Creates a waveform widget. Returns R_INVALID_ID on failure.
export fn seridian_waveform_create(config: *const SeridianWaveformConfig) callconv(.c) Rid {
    const state = allocator.create(State) catch return R_INVALID_ID;
    state.* = .{};

    const source: []const CPeak = if (config.peak_count == 0)
        &.{}
    else
        (config.peaks orelse {
            allocator.destroy(state);
            return R_INVALID_ID;
        })[0..config.peak_count];
    replacePeaks(state, source) catch {
        allocator.destroy(state);
        return R_INVALID_ID;
    };
    state.clip_length = config.clip_length;
    state.window = wm.clampWindow(config.window_start, config.window_end, config.clip_length);

    const widget = Rwidget_create(R_WIDGET_CUSTOM);
    if (widget == R_INVALID_ID) {
        freePeaks(state.peaks);
        allocator.destroy(state);
        return R_INVALID_ID;
    }

    Rwidget_set_size(widget, config.width, config.height);
    Rwidget_set_user_handle(widget, state);
    Rcustom_set_paint_callback(widget, paintWaveform, state);
    Rwidget_set_event_callback(widget, handleEvent, state);
    Rwidget_set_destroy_callback(widget, destroyWaveform, state);
    return widget;
}

/// Replaces the peaks shown by a waveform widget. The peaks are copied.
/// Returns 0 on success, -1 for an invalid widget, a null pointer with a
/// nonzero count, or an allocation failure.
export fn seridian_waveform_set_peaks(widget: Rid, peaks: ?[*]const CPeak, count: usize) callconv(.c) c_int {
    const state = stateOf(widget) orelse return -1;
    const source: []const CPeak = if (count == 0)
        &.{}
    else
        (peaks orelse return -1)[0..count];
    replacePeaks(state, source) catch return -1;
    Rwidget_invalidate(widget);
    return 0;
}

/// Sets the clip length (seconds) and the visible window. The window is clamped
/// to [0, clip_length]. Returns 0 on success, -1 for an invalid widget.
export fn seridian_waveform_set_window(widget: Rid, clip_length: f64, window_start: f64, window_end: f64) callconv(.c) c_int {
    const state = stateOf(widget) orelse return -1;
    state.clip_length = clip_length;
    state.window = wm.clampWindow(window_start, window_end, clip_length);
    Rwidget_invalidate(widget);
    return 0;
}
