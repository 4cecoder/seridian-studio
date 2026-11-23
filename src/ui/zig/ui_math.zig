//! Pure helpers for the Raven UI: text formatting, timeline zoom, split-point detection, and bar/beat position.
//! No Raven or engine calls, so every rule here is covered by tests (ported from tests/ui/ui_math_test.c).
//!
//! Translated from src/ui/ui_math.h. Text is formatted with the C library's snprintf, exactly as the C did, so
//! number rounding is identical.

const std = @import("std");

extern "c" fn snprintf(buffer: [*c]u8, size: usize, format: [*c]const u8, ...) c_int;
extern "c" fn lroundf(value: f32) c_long;
extern "c" fn log10(value: f64) f64;
extern "c" fn floor(value: f64) f64;

pub const UI_MIN_VIEW_SECONDS: f64 = 2.0;

pub fn ui_clamp_float(value: f32, minimum: f32, maximum: f32) f32 {
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

pub fn ui_clamp_double(value: f64, minimum: f64, maximum: f64) f64 {
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
}

/// "C" for centre, otherwise "L<n>" / "R<n>" with the percentage of travel. Writes a NUL-terminated string of at
/// most `text_size` bytes into `text` (caller-owned).
pub fn ui_format_pan(pan: f32, text: [*c]u8, text_size: usize) void {
    const percent: c_int = @intCast(lroundf(@abs(pan) * 100.0));
    if (percent == 0) {
        _ = snprintf(text, text_size, "C");
    } else {
        _ = snprintf(text, text_size, "%c%d", @as(c_int, if (pan < 0.0) 'L' else 'R'), percent);
    }
}

/// Linear gain to decibels; silence is shown as −∞. Writes into the caller-owned `text`.
pub fn ui_format_gain(gain: f32, text: [*c]u8, text_size: usize) void {
    if (gain <= 0.00003) {
        _ = snprintf(text, text_size, "−∞ dB");
    } else {
        _ = snprintf(text, text_size, "%.1f dB", 20.0 * log10(@as(f64, gain)));
    }
}

/// Zooms the visible range [view_start, view_end] by `factor` (0.5 = zoom in, 2.0 = zoom out) around its centre.
/// The span is clamped to [UI_MIN_VIEW_SECONDS, duration] and the result stays inside [0, duration].
pub fn ui_zoom_view(view_start: f64, view_end: f64, factor: f64, duration: f64, out_start: *f64, out_end: *f64) void {
    var span = (view_end - view_start) * factor;
    span = ui_clamp_double(span, UI_MIN_VIEW_SECONDS, duration);
    const center = view_start + (view_end - view_start) * 0.5;
    var new_start = center - span * 0.5;
    if (new_start < 0.0) new_start = 0.0;
    if (new_start + span > duration) new_start = duration - span;
    out_start.* = new_start;
    out_end.* = new_start + span;
}

/// 1 when `time` is strictly inside a clip starting at `start` with length `duration`, else 0. Edges do not count,
/// so a split on a boundary never produces a zero-length clip.
pub fn ui_time_splits_clip(start: f64, duration: f64, time: f64) c_int {
    if (duration <= 0.0) return 0;
    return if (time > start and time < start + duration) 1 else 0;
}

/// 1-based bar and beat for a playhead position. Writes 0 and 0 for an invalid tempo or time signature instead of
/// dividing by zero.
pub fn ui_bar_beat(seconds: f64, bpm: f32, numerator: c_int, bar: *c_int, beat: *c_int) void {
    if (bpm <= 0.0 or numerator <= 0) {
        bar.* = 0;
        beat.* = 0;
        return;
    }
    const beats = seconds * @as(f64, bpm) / 60.0;
    // (long long)floor(beats): the conversion truncates, as in C.
    const whole_beats: c_longlong = @intFromFloat(floor(beats));
    bar.* = @as(c_int, @intCast(@divTrunc(whole_beats, numerator))) + 1;
    beat.* = @as(c_int, @intCast(@rem(whole_beats, numerator))) + 1;
}
