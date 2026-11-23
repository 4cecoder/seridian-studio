// Translated to Zig from vendor/raven/src/widgets/timeline.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/timeline.c
// Timeline: a sequencer. A ruler of time, a playhead, tracks of clips and
// keys, markers.
//
// Layout of the widget:
//
//   +-----------+--------------------------------------------+
//   |           |  ruler: ticks, markers, head of playhead   |
//   +-----------+--------------------------------------------+---+
//   | header of |  the track: clips and keys                 | s |
//   | the track |                                            | c |
//   +-----------+--------------------------------------------+ r |
//   |    ...    |  ...                                       | . |
//   +-----------+--------------------------------------------+---+
//   |           |  scrollbar of time                         |
//   +-----------+--------------------------------------------+
//
// Times are doubles, in seconds. What is shown is `view_start` and
// `view_span`; what is drawn glides to them (`shown_start`, `shown_span`), so
// that zooming is seen happening. Positions asked by the mouse use what is
// drawn.
//
// One gesture at a time (rvn_tl_drag_t): scrubbing the playhead, moving the
// selected items, stretching a clip by one end, a selection rectangle, or
// panning. Moves remember where every selected item started, so that they
// can snap as a whole and be undone with Escape.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const thread_h = @import("../core/thread_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const draw_h = @import("../render/draw_h.zig");
const font_h = @import("../render/font_h.zig");
const xml_h = @import("../xml/xml_h.zig");
const libc = @import("../sys/libc.zig");

const RVN_TL_RULER: f32 = 30.0;
const RVN_TL_TRACK: f32 = 38.0;
const RVN_TL_EDGE: f32 = 7.0;
const RVN_TL_SNAP_PIXELS: f32 = 8.0;
const RVN_TL_KEY: f32 = 11.0;

const rvn_tl_drag_t = c_uint;
const RVN_TL_DRAG_NONE: c_int = 0;
const RVN_TL_DRAG_SCRUB: c_int = 1;
const RVN_TL_DRAG_MOVE: c_int = 2;
const RVN_TL_DRAG_LEFT: c_int = 3;
const RVN_TL_DRAG_RIGHT: c_int = 4;
const RVN_TL_DRAG_BOX: c_int = 5;
const RVN_TL_DRAG_PAN: c_int = 6;

const RVN_TL_PART_NONE: c_int = 0;
const RVN_TL_PART_BODY: c_int = 1;
const RVN_TL_PART_LEFT: c_int = 2;
const RVN_TL_PART_RIGHT: c_int = 3;

const rvn_tl_track_t = extern struct {
    id: c_int,
    name: [*c]u8,
    color: base.rvn_color_t,
    has_color: c_int,
    height: f32,
    locked: c_int,
    muted: c_int,
};

const rvn_tl_item_t = extern struct {
    id: c_int,
    @"type": raven.RTimelineItem,
    /// Id of its track; 0 for a marker.
    track: c_int,
    start: f64,
    length: f64,
    label: [*c]u8,
    color: base.rvn_color_t,
    has_color: c_int,
    selected: c_int,
    /// where it was when the gesture started
    from_start: f64,
    from_length: f64,
    from_track: c_int,
    /// How much it stands out: under the pointer, selected, held.
    lift: raven.RSpring,
};

const rvn_timeline_t = extern struct {
    base: widget_h.rvn_widget_t,
    duration: f64,
    time: f64,
    fps: f64,
    no_snapping: c_int,
    playing: c_int,
    loop: c_int,
    view_start: f64,
    view_span: f64,
    shown_start: raven.RSpring,
    shown_span: raven.RSpring,
    /// What the last paint drew: the mouse works with this.
    draw_start: f64,
    draw_span: f64,
    header_width: f32,
    track_height: f32,
    tracks: [*c]rvn_tl_track_t,
    track_count: u32,
    track_cap: u32,
    items: [*c]rvn_tl_item_t,
    item_count: u32,
    item_cap: u32,
    next_id: c_int,
    time_bar: common.rvn_scrollbar_t,
    track_bar: common.rvn_scrollbar_t,
    drag: rvn_tl_drag_t,
    drag_item: c_int,
    drag_moved: c_int,
    press_x: f32,
    press_y: f32,
    press_time: f64,
    /// Track under the pointer when the gesture started (index).
    press_row: c_int,
    pan_start: f64,
    pan_scroll: f32,
    /// Selection rectangle, in the widget.
    box: base.rvn_rect_t,
    /// Where the move snapped, to show it; negative = nowhere.
    guide: f64,
    hot_item: c_int,
    hot_part: c_int,
    /// Toggle of a track header under the pointer: track index * 2 + (0 mute, 1 lock), or -1.
    hot_toggle: c_int,
    /// Something changed during the gesture: the action fires when it ends.
    gesture_changed: c_int,
    play_timer: raven.Rid,
    play_clock: f64,
    playhead_shown: raven.RSpring,
    time_callback: raven.RTimelineTimeCallback,
    time_user: ?*anyopaque,
    changed_callback: raven.RTimelineItemCallback,
    changed_user: ?*anyopaque,
    selection_callback: raven.RTimelineItemCallback,
    selection_user: ?*anyopaque,
    activated_callback: raven.RTimelineItemCallback,
    activated_user: ?*anyopaque,
    removed_callback: raven.RTimelineItemCallback,
    removed_user: ?*anyopaque,
};

const rvn_tl_layout_t = extern struct {
    /// The tracks, without their headers: where time runs.
    lanes: base.rvn_rect_t,
    ruler: base.rvn_rect_t,
    headers: base.rvn_rect_t,
    time_track: base.rvn_rect_t,
    track_track: base.rvn_rect_t,
    bar: f32,
};

const g_tl_palette = [_]u32{ 0x0A84FF, 0xFF9F0A, 0x30D158, 0xBF5AF2, 0xFF375F, 0x64D2FF, 0xFFD60A, 0xAC8E68 };

// ---------------------------------------------------------------------------
//  Model
// ---------------------------------------------------------------------------

fn rvn_tl_track_index(tl: [*c]const rvn_timeline_t, id: c_int) c_int {
    var i: u32 = 0;
    while (i < tl.*.track_count) : (i += 1) {
        if (tl.*.tracks[i].id == id) return @intCast(i);
    }
    return -1;
}

fn rvn_tl_track(tl: [*c]rvn_timeline_t, id: c_int) [*c]rvn_tl_track_t {
    const index: c_int = if (id > 0) rvn_tl_track_index(tl, id) else -1;
    return if (index >= 0) &tl.*.tracks[@intCast(index)] else null;
}

fn rvn_tl_item(tl: [*c]rvn_timeline_t, id: c_int) [*c]rvn_tl_item_t {
    if (id <= 0) return null;
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) {
        if (tl.*.items[i].id == id) return &tl.*.items[i];
    }
    return null;
}

fn rvn_tl_add_item(tl: [*c]rvn_timeline_t, type_: raven.RTimelineItem, track: c_int, start: f64, length: f64, label: [*c]const u8) [*c]rvn_tl_item_t {
    base.RVN_ARRAY_RESERVE(&tl.*.items, &tl.*.item_cap, tl.*.item_count + 1);
    const index = tl.*.item_count;
    tl.*.item_count += 1;
    const item: [*c]rvn_tl_item_t = &tl.*.items[index];
    item.* = std.mem.zeroes(rvn_tl_item_t);
    item.*.id = tl.*.next_id;
    tl.*.next_id += 1;
    item.*.@"type" = type_;
    item.*.track = track;
    item.*.start = if (start < 0.0) 0.0 else start;
    item.*.length = if (length < 0.0) 0.0 else length;
    item.*.label = if (label != null and label[0] != 0) base.rvn_strdup(label) else null;
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
    return item;
}

fn rvn_tl_remove_item_at(tl: [*c]rvn_timeline_t, index: u32) void {
    if (tl.*.hot_item == tl.*.items[index].id) tl.*.hot_item = 0;
    if (tl.*.drag_item == tl.*.items[index].id) tl.*.drag_item = 0;
    base.rvn_free(tl.*.items[index].label);
    _ = libc.memmove(&tl.*.items[index], &tl.*.items[index + 1], @sizeOf(rvn_tl_item_t) * @as(usize, tl.*.item_count - index - 1));
    tl.*.item_count -= 1;
}

fn rvn_tl_track_height(tl: [*c]const rvn_timeline_t, track: [*c]const rvn_tl_track_t) f32 {
    return if (track.*.height > 0.0) track.*.height else tl.*.track_height;
}

fn rvn_tl_tracks_height(tl: [*c]const rvn_timeline_t) f32 {
    var height: f32 = 0.0;
    var i: u32 = 0;
    while (i < tl.*.track_count) : (i += 1) height += rvn_tl_track_height(tl, &tl.*.tracks[i]);
    return height;
}

fn rvn_tl_track_color(tl: [*c]const rvn_timeline_t, index: c_int) base.rvn_color_t {
    if (index >= 0 and tl.*.tracks[@intCast(index)].has_color != 0) return tl.*.tracks[@intCast(index)].color;
    const n: u32 = @intCast(if (index < 0) 0 else index);
    return base.rvn_hex(g_tl_palette[@as(usize, n) % g_tl_palette.len], 255);
}

fn rvn_tl_item_color(tl: [*c]const rvn_timeline_t, item: [*c]const rvn_tl_item_t) base.rvn_color_t {
    if (item.*.has_color != 0) return item.*.color;
    if (item.*.@"type" == raven.R_TIMELINE_MARKER) return widget_h.rvn_widget_color(&tl.*.base, raven.R_COLOR_WARNING);
    return rvn_tl_track_color(tl, rvn_tl_track_index(tl, item.*.track));
}

// ---------------------------------------------------------------------------
//  Geometry
// ---------------------------------------------------------------------------

fn rvn_tl_layout(tl: [*c]const rvn_timeline_t, layout: [*c]rvn_tl_layout_t) void {
    const widget: [*c]const widget_h.rvn_widget_t = &tl.*.base;
    const bar = widget_h.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE);
    var header = tl.*.header_width;
    if (header <= 0.0) {
        // as wide as the longest name asks, within reason
        const font = font_h.rvn_font_resolve(raven.R_INVALID_ID);
        const size = common.rvn_widget_font_size(widget, 0.0);
        header = 96.0;
        var i: u32 = 0;
        while (i < tl.*.track_count) : (i += 1) {
            if (tl.*.tracks[i].name != null) header = base.rvn_maxf(header, font_h.rvn_text_width(font, size, tl.*.tracks[i].name, -1) + 26.0 + 62.0);
        }
        header = @ceil(base.rvn_minf(header, 240.0));
    }
    header = base.rvn_minf(header, widget.*.rect.w * 0.5);
    const lanes_height = base.rvn_maxf(0.0, widget.*.rect.h - RVN_TL_RULER - bar);
    const scroll = rvn_tl_tracks_height(tl) > lanes_height + 0.5;
    const lanes_width = base.rvn_maxf(1.0, widget.*.rect.w - header - (if (scroll) bar else 0.0));
    layout.*.bar = bar;
    layout.*.ruler = base.rvn_rect(header, 0.0, lanes_width, RVN_TL_RULER);
    layout.*.lanes = base.rvn_rect(header, RVN_TL_RULER, lanes_width, lanes_height);
    layout.*.headers = base.rvn_rect(0.0, RVN_TL_RULER, header, lanes_height);
    layout.*.time_track = base.rvn_rect(header, widget.*.rect.h - bar, lanes_width, bar);
    layout.*.track_track = base.rvn_rect(widget.*.rect.w - bar, RVN_TL_RULER, bar, lanes_height);
}

fn rvn_tl_span(tl: [*c]const rvn_timeline_t) f64 {
    if (tl.*.draw_span > 1e-9) return tl.*.draw_span;
    return if (tl.*.view_span > 1e-9) tl.*.view_span else 1.0;
}

fn rvn_tl_x(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, time: f64) f32 {
    return layout.*.lanes.x + @as(f32, @floatCast((time - tl.*.draw_start) / rvn_tl_span(tl))) * layout.*.lanes.w;
}

fn rvn_tl_time_at(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, x: f32) f64 {
    return tl.*.draw_start + @as(f64, @floatCast((x - layout.*.lanes.x) / layout.*.lanes.w)) * rvn_tl_span(tl);
}

fn rvn_tl_per_pixel(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t) f64 {
    return rvn_tl_span(tl) / @as(f64, layout.*.lanes.w);
}

/// Top of a track in the widget, and its height.
fn rvn_tl_track_y(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, index: c_int, height: [*c]f32) f32 {
    var y = layout.*.lanes.y - tl.*.track_bar.offset;
    var i: c_int = 0;
    while (i < index and i < @as(c_int, @intCast(tl.*.track_count))) : (i += 1) {
        y += rvn_tl_track_height(tl, &tl.*.tracks[@intCast(i)]);
    }
    if (height != null) {
        height.* = if (index >= 0 and index < @as(c_int, @intCast(tl.*.track_count))) rvn_tl_track_height(tl, &tl.*.tracks[@intCast(index)]) else tl.*.track_height;
    }
    return y;
}

/// Index of the track at a height of the widget; -1 above the first, track_count below the last.
fn rvn_tl_row_at(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, y: f32) c_int {
    var top = layout.*.lanes.y - tl.*.track_bar.offset;
    if (y < top) return -1;
    var i: u32 = 0;
    while (i < tl.*.track_count) : (i += 1) {
        top += rvn_tl_track_height(tl, &tl.*.tracks[i]);
        if (y < top) return @intCast(i);
    }
    return @intCast(tl.*.track_count);
}

fn rvn_tl_clamp_view(tl: [*c]rvn_timeline_t) void {
    var minimum: f64 = if (tl.*.fps > 0.0) 4.0 / tl.*.fps else 0.05;
    if (tl.*.duration < minimum) minimum = if (tl.*.duration > 0.0) tl.*.duration else 1.0;
    if (tl.*.view_span > tl.*.duration) tl.*.view_span = tl.*.duration;
    if (tl.*.view_span < minimum) tl.*.view_span = minimum;
    if (tl.*.view_start + tl.*.view_span > tl.*.duration) tl.*.view_start = tl.*.duration - tl.*.view_span;
    if (tl.*.view_start < 0.0) tl.*.view_start = 0.0;
}

/// The scrollbars follow the view and the tracks.
fn rvn_tl_sync_bars(tl: [*c]rvn_timeline_t) void {
    var layout: rvn_tl_layout_t = undefined;
    rvn_tl_layout(tl, &layout);
    const per_pixel = tl.*.view_span / @as(f64, layout.lanes.w);
    tl.*.time_bar.viewport = layout.lanes.w;
    tl.*.time_bar.content = @floatCast(tl.*.duration / per_pixel);
    tl.*.time_bar.offset = @floatCast(tl.*.view_start / per_pixel);
    tl.*.track_bar.viewport = layout.lanes.h;
    tl.*.track_bar.content = rvn_tl_tracks_height(tl);
    _ = common.rvn_scrollbar_clamp(&tl.*.track_bar);
}

fn rvn_tl_set_view(tl: [*c]rvn_timeline_t, start: f64, span: f64, animate: c_int) void {
    tl.*.view_start = start;
    tl.*.view_span = span;
    rvn_tl_clamp_view(tl);
    if (animate == 0) {
        draw_h.rvn_spring_set(&tl.*.shown_start, @floatCast(tl.*.view_start));
        draw_h.rvn_spring_set(&tl.*.shown_span, @floatCast(tl.*.view_span));
        tl.*.shown_start.started = raven.R_TRUE;
        tl.*.shown_span.started = raven.R_TRUE;
        tl.*.draw_start = tl.*.view_start;
        tl.*.draw_span = tl.*.view_span;
    }
    rvn_tl_sync_bars(tl);
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

// ---------------------------------------------------------------------------
//  The ruler
// ---------------------------------------------------------------------------

/// The step between two labelled marks of the ruler, and how many small marks it is cut into.
fn rvn_tl_major_step(tl: [*c]const rvn_timeline_t, per_pixel: f64, minor: [*c]c_int) f64 {
    const seconds = [_]f64{ 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0, 1800.0, 3600.0, 7200.0, 21600.0 };
    const seconds_minor = [_]c_int{ 5, 2, 5, 5, 2, 5, 5, 2, 5, 5, 2, 5, 5, 3, 3, 6, 2, 5, 5, 6, 6, 4, 6 };
    const frames = [_]c_int{ 1, 2, 5, 10 };
    const frames_minor = [_]c_int{ 1, 2, 5, 5 };
    const wanted = per_pixel * 84.0;
    if (tl.*.fps > 0.0) {
        var i: usize = 0;
        while (i < frames.len) : (i += 1) {
            const step = @as(f64, @floatFromInt(frames[i])) / tl.*.fps;
            if (step >= wanted and @as(f64, @floatFromInt(frames[i])) < tl.*.fps) {
                minor.* = frames_minor[i];
                return step;
            }
        }
    }
    var i: usize = 0;
    while (i < seconds.len) : (i += 1) {
        // (with frames, nothing finer than a second is left here)
        if (tl.*.fps > 0.0 and seconds[i] < 1.0) continue;
        if (seconds[i] >= wanted) {
            minor.* = seconds_minor[i];
            if (tl.*.fps > 0.0 and seconds[i] == 1.0) {
                minor.* = if (tl.*.fps <= 30.0)
                    @as(c_int, @intFromFloat(tl.*.fps + 0.5))
                else if (tl.*.fps <= 60.0)
                    @as(c_int, @intFromFloat(tl.*.fps / 2.0 + 0.5))
                else
                    10;
            }
            // small marks too close to tell apart are not drawn
            while (minor.* > 1 and seconds[i] / @as(f64, @floatFromInt(minor.*)) < per_pixel * 5.0) {
                minor.* = if (@rem(minor.*, 2) == 0) @divTrunc(minor.*, 2) else 1;
            }
            return seconds[i];
        }
    }
    minor.* = 6;
    return seconds[seconds.len - 1];
}

fn rvn_tl_format_time(tl: [*c]const rvn_timeline_t, time_: f64, step: f64, buffer: [*c]u8, size: usize) void {
    var time = time_;
    if (time < 0.0) time = 0.0;
    if (tl.*.fps > 0.0) {
        const frame: c_long = @intFromFloat(@floor(time * tl.*.fps + 0.5));
        const per_second: c_long = @intFromFloat(tl.*.fps + 0.5);
        const whole: c_long = if (per_second > 0) @divTrunc(frame, per_second) else 0;
        const rest: c_long = if (per_second > 0) @rem(frame, per_second) else 0;
        if (whole >= 3600) {
            _ = libc.snprintf(buffer, size, "%ld:%02ld:%02ld:%02ld", @divTrunc(whole, 3600), @rem(@divTrunc(whole, 60), 60), @rem(whole, 60), rest);
        } else if (whole >= 60) {
            _ = libc.snprintf(buffer, size, "%ld:%02ld:%02ld", @divTrunc(whole, 60), @rem(whole, 60), rest);
        } else {
            _ = libc.snprintf(buffer, size, "%ld:%02ld", whole, rest);
        }
    } else if (step < 1.0) {
        const decimals: c_int = if (step < 0.01) 3 else if (step < 0.1) 2 else 1;
        if (time >= 60.0) {
            _ = libc.snprintf(buffer, size, "%d:%0*.*f", @as(c_int, @intFromFloat(time / 60.0)), decimals + 3, decimals, libc.fmod(time, 60.0));
        } else {
            _ = libc.snprintf(buffer, size, "%.*fs", decimals, time);
        }
    } else {
        const whole: c_long = @intFromFloat(@floor(time + 0.5));
        if (whole >= 3600) {
            _ = libc.snprintf(buffer, size, "%ld:%02ld:%02ld", @divTrunc(whole, 3600), @rem(@divTrunc(whole, 60), 60), @rem(whole, 60));
        } else if (whole >= 60) {
            _ = libc.snprintf(buffer, size, "%ld:%02ld", @divTrunc(whole, 60), @rem(whole, 60));
        } else {
            _ = libc.snprintf(buffer, size, "%lds", whole);
        }
    }
}

// ---------------------------------------------------------------------------
//  Snapping
// ---------------------------------------------------------------------------

fn rvn_tl_quantize(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, time: f64) f64 {
    if (tl.*.fps > 0.0) return @floor(time * tl.*.fps + 0.5) / tl.*.fps;
    var minor: c_int = 1;
    const step = rvn_tl_major_step(tl, rvn_tl_per_pixel(tl, layout), &minor) / @as(f64, @floatFromInt(base.rvn_maxi(minor, 1)));
    return @floor(time / step + 0.5) * step;
}

/// Expansion of RVN_TL_TRY: keeps the candidate when it is the nearest one so far.
inline fn RVN_TL_TRY(candidate: f64, time: f64, best: *f64, found: [*c]f64, any: *c_int) void {
    const distance = @abs(candidate - time);
    if (distance < best.*) {
        best.* = distance;
        found.* = candidate;
        any.* = raven.R_TRUE;
    }
}

/// What a time is drawn to: the playhead, a marker, an end of a clip that is
/// not moving, the ends of the sequence. Returns R_TRUE and the time when one
/// is within reach.
fn rvn_tl_magnet(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, time: f64, with_playhead: c_int, found: [*c]f64) c_int {
    const reach = rvn_tl_per_pixel(tl, layout) * @as(f64, RVN_TL_SNAP_PIXELS);
    var best = reach;
    var any: c_int = raven.R_FALSE;
    RVN_TL_TRY(0.0, time, &best, found, &any);
    RVN_TL_TRY(tl.*.duration, time, &best, found, &any);
    if (with_playhead != 0) RVN_TL_TRY(tl.*.time, time, &best, found, &any);
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) {
        const item = &tl.*.items[i];
        // (what moves with the gesture is not something to snap to)
        if (item.*.selected != 0 and tl.*.drag != RVN_TL_DRAG_SCRUB) continue;
        RVN_TL_TRY(item.*.start, time, &best, found, &any);
        if (item.*.@"type" == raven.R_TIMELINE_CLIP) RVN_TL_TRY(item.*.start + item.*.length, time, &best, found, &any);
    }
    return any;
}

// ---------------------------------------------------------------------------
//  Notifications
// ---------------------------------------------------------------------------

fn rvn_tl_notify_time(widget: [*c]widget_h.rvn_widget_t) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    if (tl.*.time_callback) |callback| callback(widget.*.id, tl.*.time, tl.*.time_user);
}

fn rvn_tl_notify_item(widget: [*c]widget_h.rvn_widget_t, callback: raven.RTimelineItemCallback, user: ?*anyopaque, item: c_int) void {
    if (callback) |cb| {
        if (common.rvn_widget_alive(widget) != 0) cb(widget.*.id, item, user);
    }
}

fn rvn_tl_set_time(widget: [*c]widget_h.rvn_widget_t, time_: f64, notify: c_int) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    var time = time_;
    if (time < 0.0) time = 0.0;
    if (time > tl.*.duration) time = tl.*.duration;
    if (time == tl.*.time) return;
    tl.*.time = time;
    widget_h.rvn_widget_invalidate_paint(widget);
    if (notify != 0) rvn_tl_notify_time(widget);
}

fn rvn_tl_select_only(tl: [*c]rvn_timeline_t, id: c_int) void {
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) tl.*.items[i].selected = @intFromBool(tl.*.items[i].id == id);
}

// ---------------------------------------------------------------------------
//  Playing
// ---------------------------------------------------------------------------

fn rvn_tl_stop_timer(tl: [*c]rvn_timeline_t) void {
    if (tl.*.play_timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(tl.*.play_timer) != 0) raven.Rtimer_destroy(tl.*.play_timer);
    tl.*.play_timer = raven.R_INVALID_ID;
}

fn rvn_tl_play_tick(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const widget: [*c]widget_h.rvn_widget_t = widget_h.rvn_widget_get(@truncate(@intFromPtr(user_data)));
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    const now = thread_h.rvn_clock_seconds();
    _ = timer;
    if (widget == null or widget.*.cls.*.@"type" != raven.R_WIDGET_TIMELINE) return;
    var time = tl.*.time + (now - tl.*.play_clock);
    tl.*.play_clock = now;
    if (time >= tl.*.duration) {
        if (tl.*.loop != 0 and tl.*.duration > 0.0) {
            time = @rem(time, tl.*.duration);
        } else {
            time = tl.*.duration;
            tl.*.playing = raven.R_FALSE;
            rvn_tl_stop_timer(tl);
        }
    }
    // the view follows the playhead: a page at a time
    if (time < tl.*.view_start or time > tl.*.view_start + tl.*.view_span) {
        rvn_tl_set_view(tl, if (time < tl.*.view_start) time else time - tl.*.view_span * 0.05, tl.*.view_span, raven.R_TRUE);
    }
    rvn_tl_set_time(widget, time, raven.R_TRUE);
}

fn rvn_tl_set_playing(widget: [*c]widget_h.rvn_widget_t, playing_: c_int) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    const playing: c_int = @intFromBool(playing_ != 0);
    if (tl.*.playing == playing) return;
    tl.*.playing = playing;
    rvn_tl_stop_timer(tl);
    if (playing != 0) {
        if (tl.*.time >= tl.*.duration) tl.*.time = 0.0;
        tl.*.play_clock = thread_h.rvn_clock_seconds();
        tl.*.play_timer = raven.Rtimer_create(1.0 / 60.0, raven.R_TRUE, &rvn_tl_play_tick, @ptrFromInt(@as(usize, widget.*.id)));
    }
    widget_h.rvn_widget_invalidate_paint(widget);
}

// ---------------------------------------------------------------------------
//  Widget
// ---------------------------------------------------------------------------

fn rvn_timeline_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    tl.*.duration = 10.0;
    tl.*.view_start = 0.0;
    tl.*.view_span = 10.0;
    tl.*.draw_span = 10.0;
    tl.*.track_height = RVN_TL_TRACK;
    tl.*.next_id = 1;
    tl.*.guide = -1.0;
    tl.*.hot_toggle = -1;
    tl.*.play_timer = raven.R_INVALID_ID;
}

fn rvn_tl_clear(tl: [*c]rvn_timeline_t) void {
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) base.rvn_free(tl.*.items[i].label);
    i = 0;
    while (i < tl.*.track_count) : (i += 1) base.rvn_free(tl.*.tracks[i].name);
    tl.*.item_count = 0;
    tl.*.track_count = 0;
    tl.*.hot_item = 0;
    tl.*.drag_item = 0;
}

fn rvn_timeline_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    if (ctx_h.g_rvn.initialized != 0) rvn_tl_stop_timer(tl);
    rvn_tl_clear(tl);
    base.rvn_free(tl.*.items);
    base.rvn_free(tl.*.tracks);
}

fn rvn_timeline_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    const tracks = base.rvn_clampf(rvn_tl_tracks_height(tl), tl.*.track_height * 2.0, tl.*.track_height * 8.0);
    return base.rvn_vec2(480.0, RVN_TL_RULER + tracks + widget_h.rvn_widget_metric(widget, raven.R_METRIC_SCROLLBAR_SIZE));
}

fn rvn_timeline_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    rvn_tl_sync_bars(tl);
}

/// Is a color light enough for dark text on it?
fn rvn_tl_light(color: base.rvn_color_t) c_int {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    base.rvn_color_to_floats(color, &r, &g, &b, &a);
    return @intFromBool(0.2126 * r + 0.7152 * g + 0.0722 * b > 0.62);
}

fn rvn_tl_paint_diamond(painter: [*c]draw_h.RPainter, cx: f32, cy: f32, half: f32, color: base.rvn_color_t) void {
    draw_h.rvn_paint_triangle(painter, cx - half, cy, cx, cy - half, cx + half, cy, color);
    draw_h.rvn_paint_triangle(painter, cx - half, cy, cx, cy + half, cx + half, cy, color);
}

fn rvn_timeline_paint(widget: [*c]widget_h.rvn_widget_t, painter_: ?*raven.RPainter) callconv(.c) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    const painter: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter_));
    var layout: rvn_tl_layout_t = undefined;
    const font = font_h.rvn_font_resolve(raven.R_INVALID_ID);
    const size = common.rvn_widget_font_size(widget, 0.0);
    const small: f32 = @floor(size * 0.86);
    var metrics: font_h.rvn_font_metrics_t = undefined;
    const text = widget_h.rvn_widget_text_color(widget, painter_);
    const dim = base.rvn_color_fade(text, 0.55);
    const line = widget_h.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR);
    const accent = widget_h.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
    const back = widget_h.rvn_widget_color(widget, raven.R_COLOR_INPUT);
    const panel = widget_h.rvn_widget_color(widget, raven.R_COLOR_HEADER);
    const head = widget_h.rvn_widget_color(widget, raven.R_COLOR_DANGER);
    const radius = widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS);
    var first: f64 = undefined;
    var minor: c_int = 1;
    var k: c_int = 0;
    var i: u32 = 0;
    var label: [48]u8 = undefined;

    rvn_tl_layout(tl, &layout);
    // the view glides to where it was asked to go
    tl.*.draw_start = @as(f64, draw_h.rvn_paint_spring(painter, &tl.*.shown_start, @floatCast(tl.*.view_start), raven.R_MOTION_SNAPPY));
    tl.*.draw_span = @as(f64, base.rvn_maxf(draw_h.rvn_paint_spring(painter, &tl.*.shown_span, @floatCast(tl.*.view_span), raven.R_MOTION_SNAPPY), 1e-4));
    const per_pixel = rvn_tl_per_pixel(tl, &layout);
    const major = rvn_tl_major_step(tl, per_pixel, &minor);
    font_h.rvn_font_metrics(font, small, &metrics);

    // the whole widget is one rounded surface
    draw_h.rvn_paint_box(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h), radius, back, 1.0, widget_h.rvn_widget_color(widget, raven.R_COLOR_BORDER));

    // ---- the lanes ----
    draw_h.rvn_paint_push_clip(painter, layout.lanes);
    i = 0;
    while (i < tl.*.track_count) : (i += 1) {
        var height: f32 = undefined;
        const y = rvn_tl_track_y(tl, &layout, @intCast(i), &height);
        if (y > layout.lanes.y + layout.lanes.h or y + height < layout.lanes.y) continue;
        if (i % 2 == 1) draw_h.rvn_paint_rect(painter, base.rvn_rect(layout.lanes.x, y, layout.lanes.w, height), base.rvn_color_fade(text, 0.028));
        draw_h.rvn_paint_rect(painter, base.rvn_rect(layout.lanes.x, y + height - 1.0, layout.lanes.w, 1.0), base.rvn_color_fade(line, 0.6));
    }
    // the marks of the ruler run down the lanes
    first = @floor(tl.*.draw_start / major) * major;
    k = 0;
    while (first + @as(f64, @floatFromInt(k)) * major / @as(f64, @floatFromInt(minor)) <= tl.*.draw_start + tl.*.draw_span) : (k += 1) {
        const time = first + @as(f64, @floatFromInt(k)) * major / @as(f64, @floatFromInt(minor));
        const x = @floor(rvn_tl_x(tl, &layout, time));
        if (x < layout.lanes.x) continue;
        draw_h.rvn_paint_rect(painter, base.rvn_rect(x, layout.lanes.y, 1.0, layout.lanes.h), base.rvn_color_fade(line, if (@rem(k, minor) == 0) 0.75 else 0.3));
    }
    // what is past the end of the sequence
    {
        const end = rvn_tl_x(tl, &layout, tl.*.duration);
        if (end < layout.lanes.x + layout.lanes.w) {
            draw_h.rvn_paint_rect(painter, base.rvn_rect(end, layout.lanes.y, layout.lanes.x + layout.lanes.w - end, layout.lanes.h), base.rvn_rgba(0.0, 0.0, 0.0, 0.25));
        }
    }
    i = 0;
    while (i < tl.*.item_count) : (i += 1) {
        const item = &tl.*.items[i];
        if (item.*.@"type" != raven.R_TIMELINE_MARKER) continue;
        const marker_alpha: f32 = if (item.*.selected != 0) 0.95 else 0.55;
        draw_h.rvn_paint_rect(painter, base.rvn_rect(@floor(rvn_tl_x(tl, &layout, item.*.start)), layout.lanes.y, 1.0, layout.lanes.h), base.rvn_color_fade(rvn_tl_item_color(tl, item), marker_alpha));
    }

    // clips, then keys over them; what is held is drawn last, over the rest
    k = 0;
    while (k < 4) : (k += 1) {
        i = 0;
        while (i < tl.*.item_count) : (i += 1) {
            const item = &tl.*.items[i];
            const sel = item.*.selected != 0;
            const index = rvn_tl_track_index(tl, item.*.track);
            const held = sel and (tl.*.drag == RVN_TL_DRAG_MOVE or tl.*.drag == RVN_TL_DRAG_LEFT or tl.*.drag == RVN_TL_DRAG_RIGHT) and tl.*.drag_moved != 0;
            const hot = tl.*.hot_item == item.*.id and painter.*.enabled != 0 and tl.*.drag == RVN_TL_DRAG_NONE;
            if (item.*.@"type" == raven.R_TIMELINE_MARKER or index < 0) continue;
            if (((item.*.@"type" == raven.R_TIMELINE_KEY) != (@rem(k, 2) == 1)) or (held != (k >= 2))) continue;
            var height: f32 = undefined;
            const y = rvn_tl_track_y(tl, &layout, index, &height);
            if (y > layout.lanes.y + layout.lanes.h or y + height < layout.lanes.y) continue;
            const lift_target: f32 = if (held) 1.0 else if (hot) 0.45 else 0.0;
            const lift = base.rvn_clampf(draw_h.rvn_paint_spring(painter, &item.*.lift, lift_target, raven.R_MOTION_SNAPPY), 0.0, 1.2);
            const color = rvn_tl_item_color(tl, item);
            const muted_alpha: f32 = if (tl.*.tracks[@intCast(index)].muted != 0) 0.38 else 1.0;
            const enabled_alpha: f32 = if (painter.*.enabled != 0) 1.0 else 0.5;
            const opacity = muted_alpha * enabled_alpha;

            if (item.*.@"type" == raven.R_TIMELINE_CLIP) {
                const x0 = rvn_tl_x(tl, &layout, item.*.start);
                const x1 = rvn_tl_x(tl, &layout, item.*.start + item.*.length);
                const rect = base.rvn_rect(x0, y + 4.0 - lift * 1.5, base.rvn_maxf(x1 - x0, 3.0), height - 9.0);
                const clip_radius = base.rvn_minf(7.0, rect.w * 0.5);
                const fill_alpha: f32 = if (sel) 1.0 else 0.86;
                const fill = base.rvn_color_fade(base.rvn_color_mix(color, base.rvn_hex(0x000000, 255), 0.12), opacity * fill_alpha);
                if (x1 < layout.lanes.x or x0 > layout.lanes.x + layout.lanes.w) continue;
                if (lift > 0.02 or sel) {
                    const shadow_color = if (sel) color else base.rvn_hex(0x000000, 255);
                    const shadow_alpha: f32 = if (sel) 0.45 else 0.3;
                    draw_h.rvn_paint_shadow(painter, base.rvn_rect(rect.x, rect.y + 2.0 + lift * 4.0, rect.w, rect.h), clip_radius, 6.0 + lift * 12.0, base.rvn_color_fade(shadow_color, shadow_alpha * opacity));
                }
                const outline_width: f32 = if (sel) 1.5 else 1.0;
                const outline = if (sel)
                    base.rvn_hex(0xFFFFFF, @intFromFloat(235.0 * opacity))
                else
                    base.rvn_color_fade(base.rvn_color_mix(color, base.rvn_hex(0xFFFFFF, 255), 0.35), opacity);
                draw_h.rvn_paint_box(painter, rect, clip_radius, fill, outline_width, outline);
                // a band of light along the top: the clip is a little raised
                if (rect.h > 12.0 and rect.w > 8.0) {
                    draw_h.rvn_paint_box(painter, base.rvn_rect(rect.x + 2.0, rect.y + 2.0, rect.w - 4.0, base.rvn_minf(rect.h * 0.42, 12.0)), base.rvn_maxf(clip_radius - 2.0, 1.0), base.rvn_rgba(1.0, 1.0, 1.0, 0.09 * opacity), 0.0, 0);
                }
                if (item.*.label != null and rect.w > 26.0) {
                    // the name stays in sight while the clip starts before what is shown
                    const left = base.rvn_minf(base.rvn_maxf(rect.x, layout.lanes.x), rect.x + rect.w - 40.0);
                    draw_h.rvn_paint_push_clip(painter, base.rvn_rect(rect.x + 7.0, rect.y, rect.w - 14.0, rect.h));
                    const label_color = if (rvn_tl_light(color) != 0) base.rvn_hex(0x101014, 255) else base.rvn_hex(0xFFFFFF, 255);
                    draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, small, base.rvn_rect(left + 9.0, rect.y, rect.w, rect.h), 0.0, item.*.label, -1, base.rvn_color_fade(label_color, opacity));
                    draw_h.rvn_paint_pop_clip(painter);
                }
                // the ends that stretch it show under the pointer
                if (hot and rect.w > 22.0 and tl.*.tracks[@intCast(index)].locked == 0) {
                    const grip_alpha: f32 = if (tl.*.hot_part == RVN_TL_PART_BODY) 0.35 else 0.9;
                    const grip = base.rvn_rgba(1.0, 1.0, 1.0, grip_alpha);
                    if (tl.*.hot_part != RVN_TL_PART_RIGHT) draw_h.rvn_paint_box(painter, base.rvn_rect(rect.x + 3.0, rect.y + rect.h * 0.28, 2.5, rect.h * 0.44), 1.25, grip, 0.0, 0);
                    if (tl.*.hot_part != RVN_TL_PART_LEFT) draw_h.rvn_paint_box(painter, base.rvn_rect(rect.x + rect.w - 5.5, rect.y + rect.h * 0.28, 2.5, rect.h * 0.44), 1.25, grip, 0.0, 0);
                }
            } else {
                const x = rvn_tl_x(tl, &layout, item.*.start);
                const cy = y + height * 0.5 - lift * 1.5;
                const sel_bump: f32 = if (sel) 1.0 else 0.0;
                const half = RVN_TL_KEY * 0.5 + lift * 2.0 + sel_bump;
                if (x < layout.lanes.x - 12.0 or x > layout.lanes.x + layout.lanes.w + 12.0) continue;
                rvn_tl_paint_diamond(painter, x, cy + 1.5, half + 2.0, base.rvn_rgba(0.0, 0.0, 0.0, 0.3 * opacity));
                const key_fill = if (sel)
                    base.rvn_hex(0xFFFFFF, @intFromFloat(255.0 * opacity))
                else
                    base.rvn_color_fade(base.rvn_color_mix(color, base.rvn_hex(0x000000, 255), 0.45), opacity);
                rvn_tl_paint_diamond(painter, x, cy, half + 1.5, key_fill);
                rvn_tl_paint_diamond(painter, x, cy, half - 0.5, base.rvn_color_fade(color, opacity));
                rvn_tl_paint_diamond(painter, x, cy - half * 0.28, half * 0.34, base.rvn_rgba(1.0, 1.0, 1.0, 0.4 * opacity));
                if (item.*.label != null and item.*.label[0] != 0) {
                    const key_text = if (sel) text else dim;
                    draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, small, base.rvn_rect(x + half + 6.0, y, 200.0, height), 0.0, item.*.label, -1, base.rvn_color_fade(key_text, opacity));
                }
            }
        }
    }

    if (tl.*.drag == RVN_TL_DRAG_BOX and tl.*.drag_moved != 0) {
        draw_h.rvn_paint_box(painter, tl.*.box, 3.0, base.rvn_color_fade(accent, 0.16), 1.0, base.rvn_color_fade(accent, 0.85));
    }
    if (tl.*.guide >= 0.0) {
        draw_h.rvn_paint_rect(painter, base.rvn_rect(@floor(rvn_tl_x(tl, &layout, tl.*.guide)), layout.lanes.y, 1.0, layout.lanes.h), base.rvn_color_fade(accent, 0.9));
    }
    // the playhead
    {
        const x = @floor(rvn_tl_x(tl, &layout, tl.*.time));
        draw_h.rvn_paint_rect(painter, base.rvn_rect(x - 1.0, layout.lanes.y, 3.0, layout.lanes.h), base.rvn_color_fade(head, 0.18));
        draw_h.rvn_paint_rect(painter, base.rvn_rect(x, layout.lanes.y, 1.0, layout.lanes.h), head);
    }
    draw_h.rvn_paint_pop_clip(painter);

    // ---- the headers of the tracks ----
    {
        // the column of the headers goes down to the bottom of the widget
        var corners: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
        corners[3] = base.rvn_maxf(radius - 1.0, 0.0);
        draw_h.rvn_paint_box4(painter, base.rvn_rect(1.0, RVN_TL_RULER, layout.headers.w - 1.0, widget.*.rect.h - RVN_TL_RULER - 1.0), &corners, panel, 0.0, 0);
    }
    draw_h.rvn_paint_push_clip(painter, layout.headers);
    i = 0;
    while (i < tl.*.track_count) : (i += 1) {
        const track = &tl.*.tracks[i];
        var height: f32 = undefined;
        const y = rvn_tl_track_y(tl, &layout, @intCast(i), &height);
        const color = rvn_tl_track_color(tl, @intCast(i));
        const toggle: f32 = 20.0;
        const right = layout.headers.w - 8.0;
        const track_name: [*c]const u8 = if (track.*.name != null) track.*.name else "";
        if (y > layout.headers.y + layout.headers.h or y + height < layout.headers.y) continue;
        draw_h.rvn_paint_box(painter, base.rvn_rect(8.0, y + height * 0.5 - 5.0, 10.0, 10.0), 5.0, base.rvn_color_fade(color, if (track.*.muted != 0) 0.4 else 1.0), 0.0, 0);
        draw_h.rvn_paint_push_clip(painter, base.rvn_rect(24.0, y, base.rvn_maxf(right - toggle * 2.0 - 8.0 - 24.0, 0.0), height));
        draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, size, base.rvn_rect(26.0, y, layout.headers.w, height), 0.0, track_name, -1, if (track.*.muted != 0) dim else text);
        draw_h.rvn_paint_pop_clip(painter);
        // mute and lock: two small toggles
        var t: c_int = 0;
        while (t < 2) : (t += 1) {
            const on = (if (t == 0) track.*.muted else track.*.locked) != 0;
            const hot = tl.*.hot_toggle == @as(c_int, @intCast(i)) * 2 + t and painter.*.enabled != 0;
            const offset: f32 = @as(f32, @floatFromInt(2 - t));
            const rect = base.rvn_rect(right - toggle * offset - (if (t == 0) @as(f32, 3.0) else @as(f32, 0.0)), y + (height - toggle) * 0.5, toggle, toggle);
            const on_color = if (t == 0) widget_h.rvn_widget_color(widget, raven.R_COLOR_WARNING) else accent;
            const off_alpha: f32 = if (hot) 0.16 else 0.07;
            const fill = if (on) on_color else base.rvn_color_fade(text, off_alpha);
            draw_h.rvn_paint_box(painter, rect, 6.0, fill, 0.0, 0);
            const toggle_text: [*c]const u8 = if (t == 0) "M" else "L";
            const toggle_color = if (on) base.rvn_hex(0x101014, 255) else if (hot) text else dim;
            draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, small, rect, 0.5, toggle_text, 1, toggle_color);
        }
        draw_h.rvn_paint_rect(painter, base.rvn_rect(0.0, y + height - 1.0, layout.headers.w, 1.0), base.rvn_color_fade(line, 0.6));
    }
    draw_h.rvn_paint_pop_clip(painter);
    draw_h.rvn_paint_rect(painter, base.rvn_rect(layout.headers.w - 1.0, 0.0, 1.0, widget.*.rect.h), line);

    // ---- the ruler ----
    draw_h.rvn_paint_push_clip(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, RVN_TL_RULER));
    {
        var corners: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 };
        corners[0] = base.rvn_maxf(radius - 1.0, 0.0);
        corners[1] = corners[0];
        draw_h.rvn_paint_box4(painter, base.rvn_rect(1.0, 1.0, widget.*.rect.w - 2.0, RVN_TL_RULER - 1.0), &corners, panel, 0.0, 0);
    }
    draw_h.rvn_paint_rect(painter, base.rvn_rect(0.0, RVN_TL_RULER - 1.0, widget.*.rect.w, 1.0), line);
    // the time of the playhead, where the headers leave room for it
    rvn_tl_format_time(tl, tl.*.time, if (tl.*.fps > 0.0) 1.0 else 0.01, &label, label.len);
    draw_h.rvn_paint_text_in(painter, ctx_h.g_rvn.mono_font, size, base.rvn_rect(10.0, 0.0, layout.headers.w - 16.0, RVN_TL_RULER), 0.0, &label, -1, text);
    draw_h.rvn_paint_pop_clip(painter);

    draw_h.rvn_paint_push_clip(painter, layout.ruler);
    k = 0;
    while (first + @as(f64, @floatFromInt(k)) * major / @as(f64, @floatFromInt(minor)) <= tl.*.draw_start + tl.*.draw_span) : (k += 1) {
        const time = first + @as(f64, @floatFromInt(k)) * major / @as(f64, @floatFromInt(minor));
        const x = @floor(rvn_tl_x(tl, &layout, time));
        const labelled = @rem(k, minor) == 0;
        if (x < layout.ruler.x - 60.0) continue;
        const tick_h: f32 = if (labelled) 11.0 else 5.0;
        const tick_color = if (labelled) dim else base.rvn_color_fade(dim, 0.6);
        draw_h.rvn_paint_rect(painter, base.rvn_rect(x, RVN_TL_RULER - tick_h, 1.0, tick_h), tick_color);
        if (labelled) {
            rvn_tl_format_time(tl, time, major, &label, label.len);
            draw_h.rvn_paint_text(painter, raven.R_INVALID_ID, small, x + 4.0, 4.0, &label, -1, dim);
        }
    }
    i = 0;
    while (i < tl.*.item_count) : (i += 1) {
        const item = &tl.*.items[i];
        if (item.*.@"type" != raven.R_TIMELINE_MARKER) continue;
        const color = rvn_tl_item_color(tl, item);
        const x = @floor(rvn_tl_x(tl, &layout, item.*.start));
        const width: f32 = if (item.*.label != null) font_h.rvn_text_width(font, small, item.*.label, -1) + 12.0 else 10.0;
        // a flag on its pole
        draw_h.rvn_paint_rect(painter, base.rvn_rect(x, 3.0, 1.0, RVN_TL_RULER - 3.0), color);
        const flag_width: f32 = if (item.*.selected != 0) 1.5 else 0.0;
        draw_h.rvn_paint_box(painter, base.rvn_rect(x, 3.0, width, 15.0), 4.0, color, flag_width, base.rvn_hex(0xFFFFFF, 255));
        if (item.*.label != null) {
            const flag_text = if (rvn_tl_light(color) != 0) base.rvn_hex(0x101014, 255) else base.rvn_hex(0xFFFFFF, 255);
            draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, small, base.rvn_rect(x + 6.0, 3.0, width, 15.0), 0.0, item.*.label, -1, flag_text);
        }
    }
    {
        // the head of the playhead: a tab that points down
        const x = @floor(rvn_tl_x(tl, &layout, tl.*.time)) + 0.5;
        const grow: f32 = if (tl.*.drag == RVN_TL_DRAG_SCRUB) 1.5 else 0.0;
        draw_h.rvn_paint_box(painter, base.rvn_rect(x - 6.0 - grow, RVN_TL_RULER - 17.0 - grow, 12.0 + grow * 2.0, 11.0 + grow), 3.0, head, 0.0, 0);
        draw_h.rvn_paint_triangle(painter, x - 6.0 - grow, RVN_TL_RULER - 7.0, x + 6.0 + grow, RVN_TL_RULER - 7.0, x, RVN_TL_RULER - 0.5, head);
    }
    draw_h.rvn_paint_pop_clip(painter);
    // C: RVN_UNUSED(metrics) — a warning silencer, not code.
}

fn rvn_timeline_paint_overlay(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    var layout: rvn_tl_layout_t = undefined;
    const origin = widget_h.rvn_widget_origin(widget);
    const mouse_x: f32 = if (widget.*.window != null) widget.*.window.*.mouse_x - origin.x else -1.0;
    const mouse_y: f32 = if (widget.*.window != null) widget.*.window.*.mouse_y - origin.y else -1.0;
    rvn_tl_layout(tl, &layout);
    common.rvn_scrollbar_paint(&tl.*.time_bar, widget, painter, layout.time_track, raven.R_FALSE, mouse_x, mouse_y);
    common.rvn_scrollbar_paint(&tl.*.track_bar, widget, painter, layout.track_track, raven.R_TRUE, mouse_x, mouse_y);
    common.rvn_paint_focus(widget, painter, widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS));
}

// ---------------------------------------------------------------------------
//  Pointing
// ---------------------------------------------------------------------------

/// The item at a point of the widget, and which part of it.
fn rvn_tl_hit(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, x: f32, y: f32, part: [*c]c_int) c_int {
    part.* = RVN_TL_PART_NONE;
    if (y < RVN_TL_RULER) {
        const font = font_h.rvn_font_resolve(raven.R_INVALID_ID);
        const small: f32 = @floor(common.rvn_widget_font_size(&tl.*.base, 0.0) * 0.86);
        if (x < layout.*.ruler.x) return 0;
        var i: u32 = tl.*.item_count;
        while (i > 0) : (i -= 1) {
            const item = &tl.*.items[i - 1];
            if (item.*.@"type" != raven.R_TIMELINE_MARKER) continue;
            const mx = rvn_tl_x(tl, layout, item.*.start);
            const width: f32 = if (item.*.label != null) font_h.rvn_text_width(font, small, item.*.label, -1) + 12.0 else 10.0;
            if (x >= mx - 3.0 and x <= mx + width and y >= 2.0 and y <= 19.0) {
                part.* = RVN_TL_PART_BODY;
                return item.*.id;
            }
        }
        return 0;
    }
    if (base.rvn_rect_contains(layout.*.lanes, x, y) == 0) return 0;
    // keys are over the clips, and what was added last is over the rest
    var pass: c_int = 0;
    while (pass < 2) : (pass += 1) {
        var i: u32 = tl.*.item_count;
        while (i > 0) : (i -= 1) {
            const item = &tl.*.items[i - 1];
            const index = rvn_tl_track_index(tl, item.*.track);
            if (index < 0 or item.*.@"type" == raven.R_TIMELINE_MARKER or (item.*.@"type" == raven.R_TIMELINE_KEY) != (pass == 0)) continue;
            var height: f32 = undefined;
            const top = rvn_tl_track_y(tl, layout, index, &height);
            if (y < top or y >= top + height) continue;
            if (item.*.@"type" == raven.R_TIMELINE_KEY) {
                if (@abs(x - rvn_tl_x(tl, layout, item.*.start)) <= RVN_TL_KEY * 0.5 + 3.0) {
                    part.* = RVN_TL_PART_BODY;
                    return item.*.id;
                }
            } else {
                const x0 = rvn_tl_x(tl, layout, item.*.start);
                const x1 = base.rvn_maxf(rvn_tl_x(tl, layout, item.*.start + item.*.length), x0 + 3.0);
                if (x >= x0 and x <= x1) {
                    // a narrow clip is all body: it can always be moved
                    const edge: f32 = if (x1 - x0 > RVN_TL_EDGE * 3.0) RVN_TL_EDGE else 0.0;
                    part.* = if (x < x0 + edge) RVN_TL_PART_LEFT else if (x > x1 - edge) RVN_TL_PART_RIGHT else RVN_TL_PART_BODY;
                    return item.*.id;
                }
            }
        }
    }
    return 0;
}

fn rvn_tl_toggle_at(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, x: f32, y: f32) c_int {
    const toggle: f32 = 20.0;
    const right = layout.*.headers.w - 8.0;
    var height: f32 = undefined;
    if (base.rvn_rect_contains(layout.*.headers, x, y) == 0) return -1;
    const row = rvn_tl_row_at(tl, layout, y);
    if (row < 0 or row >= @as(c_int, @intCast(tl.*.track_count))) return -1;
    const top = rvn_tl_track_y(tl, layout, row, &height);
    if (y < top + (height - toggle) * 0.5 or y > top + (height + toggle) * 0.5) return -1;
    if (x >= right - toggle * 2.0 - 3.0 and x < right - toggle - 3.0) return row * 2;
    if (x >= right - toggle and x < right) return row * 2 + 1;
    return -1;
}

fn rvn_tl_item_locked(tl: [*c]rvn_timeline_t, item: [*c]const rvn_tl_item_t) c_int {
    const track = rvn_tl_track(tl, item.*.track);
    return @intFromBool(track != null and track.*.locked != 0);
}

fn rvn_tl_update_hot(widget: [*c]widget_h.rvn_widget_t, x: f32, y: f32) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    var layout: rvn_tl_layout_t = undefined;
    var part: c_int = RVN_TL_PART_NONE;
    var cursor: raven.RCursor = 0;
    rvn_tl_layout(tl, &layout);
    const item = rvn_tl_hit(tl, &layout, x, y, &part);
    const toggle = rvn_tl_toggle_at(tl, &layout, x, y);
    if (item != 0) {
        const found = rvn_tl_item(tl, item);
        if (found != null and rvn_tl_item_locked(tl, found) == 0 and (part == RVN_TL_PART_LEFT or part == RVN_TL_PART_RIGHT)) cursor = raven.R_CURSOR_RESIZE_H;
    }
    if (toggle >= 0) cursor = raven.R_CURSOR_HAND;
    if (item != tl.*.hot_item or part != tl.*.hot_part or toggle != tl.*.hot_toggle) {
        tl.*.hot_item = item;
        tl.*.hot_part = part;
        tl.*.hot_toggle = toggle;
        widget_h.rvn_widget_invalidate_paint(widget);
    }
    widget.*.cursor = cursor;
}

// ---------------------------------------------------------------------------
//  Gestures
// ---------------------------------------------------------------------------

fn rvn_tl_remember(tl: [*c]rvn_timeline_t) void {
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) {
        tl.*.items[i].from_start = tl.*.items[i].start;
        tl.*.items[i].from_length = tl.*.items[i].length;
        tl.*.items[i].from_track = tl.*.items[i].track;
    }
}

fn rvn_tl_restore(tl: [*c]rvn_timeline_t) void {
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) {
        tl.*.items[i].start = tl.*.items[i].from_start;
        tl.*.items[i].length = tl.*.items[i].from_length;
        tl.*.items[i].track = tl.*.items[i].from_track;
    }
}

fn rvn_tl_minimum_length(tl: [*c]const rvn_timeline_t, layout: [*c]const rvn_tl_layout_t) f64 {
    return if (tl.*.fps > 0.0) 1.0 / tl.*.fps else rvn_tl_per_pixel(tl, layout) * 4.0;
}

/// Moves every selected item by the same time, and the clips and keys by the same number of tracks.
fn rvn_tl_drag_move(widget: [*c]widget_h.rvn_widget_t, layout: [*c]const rvn_tl_layout_t, x: f32, y: f32, free_move: c_int) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    const lead = rvn_tl_item(tl, tl.*.drag_item);
    var delta = rvn_tl_time_at(tl, layout, x) - tl.*.press_time;
    var low: f64 = 0.0;
    var high: f64 = 0.0;
    var rows: c_int = undefined;
    var row_low: c_int = 0;
    var row_high: c_int = 0;
    var first = true;
    var i: u32 = 0;
    if (lead == null) return;

    tl.*.guide = -1.0;
    if (free_move == 0 and tl.*.no_snapping == 0) {
        // the item under the hand decides: by its start, or by its end when that one is closer to something
        const start = lead.*.from_start + delta;
        const end = start + lead.*.from_length;
        var found_start: f64 = 0.0;
        var found_end: f64 = 0.0;
        const at_start = rvn_tl_magnet(tl, layout, start, raven.R_TRUE, &found_start) != 0;
        const at_end = lead.*.@"type" == raven.R_TIMELINE_CLIP and rvn_tl_magnet(tl, layout, end, raven.R_TRUE, &found_end) != 0;
        if (at_start and (!at_end or @abs(found_start - start) <= @abs(found_end - end))) {
            delta += found_start - start;
            tl.*.guide = found_start;
        } else if (at_end) {
            delta += found_end - end;
            tl.*.guide = found_end;
        } else {
            delta = rvn_tl_quantize(tl, layout, start) - lead.*.from_start;
        }
    }
    // nothing leaves the sequence, and nothing changes place with regard to the rest
    rows = rvn_tl_row_at(tl, layout, y) - tl.*.press_row;
    i = 0;
    while (i < tl.*.item_count) : (i += 1) {
        const item = &tl.*.items[i];
        if (item.*.selected == 0) continue;
        const room_before = -item.*.from_start;
        const room_after = tl.*.duration - (item.*.from_start + item.*.from_length);
        if (first or room_before > low) low = room_before;
        if (first or room_after < high) high = room_after;
        if (item.*.@"type" != raven.R_TIMELINE_MARKER) {
            const row = rvn_tl_track_index(tl, item.*.from_track);
            if (first or -row > row_low) row_low = -row;
            const last_row: c_int = @as(c_int, @intCast(tl.*.track_count)) - 1 - row;
            if (first or last_row < row_high) row_high = last_row;
        }
        first = false;
    }
    if (delta < low) delta = low;
    if (delta > high) delta = high;
    if (lead.*.@"type" == raven.R_TIMELINE_MARKER) rows = 0;
    rows = base.rvn_clampi(rows, row_low, base.rvn_maxi(row_low, row_high));

    i = 0;
    while (i < tl.*.item_count) : (i += 1) {
        const item = &tl.*.items[i];
        if (item.*.selected == 0) continue;
        const start = item.*.from_start + delta;
        var track = item.*.from_track;
        if (item.*.@"type" != raven.R_TIMELINE_MARKER and rows != 0) {
            const target = rvn_tl_track_index(tl, item.*.from_track) + rows;
            // (a locked track takes nothing)
            if (target >= 0 and target < @as(c_int, @intCast(tl.*.track_count)) and tl.*.tracks[@intCast(target)].locked == 0) track = tl.*.tracks[@intCast(target)].id;
        }
        if (start != item.*.start or track != item.*.track) {
            item.*.start = start;
            item.*.track = track;
            tl.*.gesture_changed = raven.R_TRUE;
            rvn_tl_notify_item(widget, tl.*.changed_callback, tl.*.changed_user, item.*.id);
            if (common.rvn_widget_alive(widget) == 0) return;
        }
    }
    widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_tl_drag_stretch(widget: [*c]widget_h.rvn_widget_t, layout: [*c]const rvn_tl_layout_t, x: f32, free_move: c_int) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    const item = rvn_tl_item(tl, tl.*.drag_item);
    const minimum = rvn_tl_minimum_length(tl, layout);
    var time = rvn_tl_time_at(tl, layout, x);
    var found: f64 = 0.0;
    if (item == null) return;
    tl.*.guide = -1.0;
    if (free_move == 0 and tl.*.no_snapping == 0) {
        // (its own ends are among the candidates while it is not marked as moving)
        const was = item.*.selected;
        item.*.selected = raven.R_TRUE;
        if (rvn_tl_magnet(tl, layout, time, raven.R_TRUE, &found) != 0) {
            time = found;
            tl.*.guide = found;
        } else {
            time = rvn_tl_quantize(tl, layout, time);
        }
        item.*.selected = was;
    }
    var start = item.*.from_start;
    var length = item.*.from_length;
    if (tl.*.drag == RVN_TL_DRAG_LEFT) {
        const end = item.*.from_start + item.*.from_length;
        if (time < 0.0) time = 0.0;
        if (time > end - minimum) time = end - minimum;
        start = time;
        length = end - time;
    } else {
        if (time > tl.*.duration) time = tl.*.duration;
        if (time < item.*.from_start + minimum) time = item.*.from_start + minimum;
        length = time - item.*.from_start;
    }
    if (start != item.*.start or length != item.*.length) {
        item.*.start = start;
        item.*.length = length;
        tl.*.gesture_changed = raven.R_TRUE;
        rvn_tl_notify_item(widget, tl.*.changed_callback, tl.*.changed_user, item.*.id);
    }
    widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_tl_drag_box(widget: [*c]widget_h.rvn_widget_t, layout: [*c]const rvn_tl_layout_t, x_: f32, y_: f32) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    var changed: c_int = raven.R_FALSE;
    const x = base.rvn_clampf(x_, layout.*.lanes.x, layout.*.lanes.x + layout.*.lanes.w);
    const y = base.rvn_clampf(y_, layout.*.lanes.y, layout.*.lanes.y + layout.*.lanes.h);
    tl.*.box = base.rvn_rect(base.rvn_minf(tl.*.press_x, x), base.rvn_minf(tl.*.press_y, y), @abs(x - tl.*.press_x), @abs(y - tl.*.press_y));
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) {
        const item = &tl.*.items[i];
        const index = rvn_tl_track_index(tl, item.*.track);
        if (index < 0 or item.*.@"type" == raven.R_TIMELINE_MARKER) continue;
        var height: f32 = undefined;
        const top = rvn_tl_track_y(tl, layout, index, &height);
        const x0 = rvn_tl_x(tl, layout, item.*.start);
        const x1 = if (item.*.@"type" == raven.R_TIMELINE_CLIP) rvn_tl_x(tl, layout, item.*.start + item.*.length) else x0;
        var inside = x1 >= tl.*.box.x and x0 <= tl.*.box.x + tl.*.box.w and top + height > tl.*.box.y and top < tl.*.box.y + tl.*.box.h;
        // (from_track doubles as "was selected before the rectangle": Shift adds to it)
        inside = inside or item.*.from_track < 0;
        if (inside != (item.*.selected != 0)) {
            item.*.selected = @intFromBool(inside);
            changed = raven.R_TRUE;
        }
    }
    if (changed != 0) rvn_tl_notify_item(widget, tl.*.selection_callback, tl.*.selection_user, 0);
    widget_h.rvn_widget_invalidate_paint(widget);
}

fn rvn_tl_end_drag(widget: [*c]widget_h.rvn_widget_t, cancel: c_int) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    const changed = tl.*.gesture_changed != 0;
    if (tl.*.drag == RVN_TL_DRAG_NONE) return;
    if (tl.*.drag == RVN_TL_DRAG_BOX) {
        var i: u32 = 0;
        while (i < tl.*.item_count) : (i += 1) tl.*.items[i].from_track = tl.*.items[i].track;
    } else if (cancel != 0 and (tl.*.drag == RVN_TL_DRAG_MOVE or tl.*.drag == RVN_TL_DRAG_LEFT or tl.*.drag == RVN_TL_DRAG_RIGHT)) {
        rvn_tl_restore(tl);
    }
    tl.*.drag = RVN_TL_DRAG_NONE;
    tl.*.drag_item = 0;
    tl.*.guide = -1.0;
    tl.*.gesture_changed = raven.R_FALSE;
    widget_h.rvn_widget_release_mouse(widget);
    widget_h.rvn_widget_invalidate_paint(widget);
    // one action for the whole gesture
    if (changed and common.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
}

fn rvn_tl_zoom(tl: [*c]rvn_timeline_t, layout: [*c]const rvn_tl_layout_t, x: f32, factor: f32) void {
    const anchor = rvn_tl_time_at(tl, layout, x);
    const fraction: f64 = @as(f64, base.rvn_clampf((x - layout.*.lanes.x) / layout.*.lanes.w, 0.0, 1.0));
    const span = tl.*.view_span * @as(f64, factor);
    tl.*.view_span = span;
    rvn_tl_clamp_view(tl);
    rvn_tl_set_view(tl, anchor - fraction * tl.*.view_span, tl.*.view_span, raven.R_TRUE);
}

fn rvn_tl_remove_selected(widget: [*c]widget_h.rvn_widget_t) void {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    var i: u32 = 0;
    var any = false;
    if (tl.*.removed_callback == null) return;
    while (i < tl.*.item_count) {
        if (tl.*.items[i].selected == 0 or rvn_tl_item_locked(tl, &tl.*.items[i]) != 0) {
            i += 1;
            continue;
        }
        const id = tl.*.items[i].id;
        tl.*.removed_callback.?(widget.*.id, id, tl.*.removed_user);
        if (common.rvn_widget_alive(widget) == 0) return;
        // (the callback may have removed it itself, or others)
        while (i < tl.*.item_count and tl.*.items[i].id != id) : (i += 1) {}
        if (i < tl.*.item_count) rvn_tl_remove_item_at(tl, i);
        any = true;
        i = 0;
    }
    if (any) {
        widget_h.rvn_widget_invalidate_paint(widget);
        rvn_tl_notify_item(widget, tl.*.selection_callback, tl.*.selection_user, 0);
        if (common.rvn_widget_alive(widget) != 0) widget_h.rvn_widget_fire_action(widget);
    }
}

fn rvn_timeline_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    var layout: rvn_tl_layout_t = undefined;
    const x = event.*.local_x;
    const y = event.*.local_y;
    var changed: c_int = raven.R_FALSE;
    var used: c_int = undefined;
    var part: c_int = RVN_TL_PART_NONE;

    rvn_tl_layout(tl, &layout);
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_WHEEL => {
            const amount: f32 = if (event.*.wheel_y != 0.0) event.*.wheel_y else event.*.wheel_x;
            if ((event.*.modifiers & raven.R_MOD_CTRL) != 0) {
                rvn_tl_zoom(tl, &layout, x, libc.powf(0.82, amount));
                return raven.R_TRUE;
            }
            // the wheel scrolls the tracks when there are more than fit, else it moves along the time
            if ((event.*.modifiers & raven.R_MOD_SHIFT) == 0 and event.*.wheel_y != 0.0 and common.rvn_scrollbar_needed(&tl.*.track_bar) != 0) {
                changed = common.rvn_scrollbar_wheel(&tl.*.track_bar, -event.*.wheel_y * 40.0);
                widget_h.rvn_widget_invalidate_paint(widget);
                return changed;
            }
            {
                const before = tl.*.view_start;
                rvn_tl_set_view(tl, tl.*.view_start - @as(f64, amount) * tl.*.view_span * 0.12, tl.*.view_span, raven.R_TRUE);
                return @intFromBool(tl.*.view_start != before);
            }
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (tl.*.drag != RVN_TL_DRAG_NONE) return raven.R_TRUE;
            if (event.*.button == raven.R_MOUSE_LEFT) {
                used = common.rvn_scrollbar_event(&tl.*.time_bar, widget, event, layout.time_track, raven.R_FALSE, &changed);
                if (used == 0) used = common.rvn_scrollbar_event(&tl.*.track_bar, widget, event, layout.track_track, raven.R_TRUE, &changed);
                if (used != 0) {
                    if (changed != 0) rvn_tl_set_view(tl, @as(f64, tl.*.time_bar.offset) * (tl.*.view_span / @as(f64, layout.lanes.w)), tl.*.view_span, raven.R_FALSE);
                    return raven.R_TRUE;
                }
            }
            tl.*.press_x = x;
            tl.*.press_y = y;
            tl.*.press_time = rvn_tl_time_at(tl, &layout, x);
            tl.*.press_row = rvn_tl_row_at(tl, &layout, y);
            tl.*.drag_moved = raven.R_FALSE;
            tl.*.gesture_changed = raven.R_FALSE;
            if (event.*.button == raven.R_MOUSE_MIDDLE) {
                tl.*.drag = @intCast(RVN_TL_DRAG_PAN);
                tl.*.pan_start = tl.*.view_start;
                tl.*.pan_scroll = tl.*.track_bar.offset;
                widget_h.rvn_widget_capture_mouse(widget);
                return raven.R_TRUE;
            }
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            {
                const toggle = rvn_tl_toggle_at(tl, &layout, x, y);
                if (toggle >= 0) {
                    const track = &tl.*.tracks[@intCast(@divTrunc(toggle, 2))];
                    if (@rem(toggle, 2) == 0) {
                        track.*.muted = @intFromBool(track.*.muted == 0);
                    } else {
                        track.*.locked = @intFromBool(track.*.locked == 0);
                    }
                    widget_h.rvn_widget_invalidate_paint(widget);
                    widget_h.rvn_widget_fire_action(widget);
                    return raven.R_TRUE;
                }
            }
            {
                const id = rvn_tl_hit(tl, &layout, x, y, &part);
                var item = rvn_tl_item(tl, id);
                if (item != null) {
                    const add = (event.*.modifiers & (raven.R_MOD_CTRL | raven.R_MOD_SHIFT)) != 0;
                    if (event.*.clicks >= 2) {
                        rvn_tl_notify_item(widget, tl.*.activated_callback, tl.*.activated_user, id);
                        return raven.R_TRUE;
                    }
                    if (add) {
                        item.*.selected = @intFromBool(item.*.selected == 0);
                        rvn_tl_notify_item(widget, tl.*.selection_callback, tl.*.selection_user, id);
                    } else if (item.*.selected == 0) {
                        rvn_tl_select_only(tl, id);
                        rvn_tl_notify_item(widget, tl.*.selection_callback, tl.*.selection_user, id);
                    }
                    if (common.rvn_widget_alive(widget) == 0) return raven.R_TRUE;
                    item = rvn_tl_item(tl, id);
                    widget_h.rvn_widget_invalidate_paint(widget);
                    if (item != null and item.*.selected != 0 and rvn_tl_item_locked(tl, item) == 0) {
                        tl.*.drag = if (part == RVN_TL_PART_LEFT) RVN_TL_DRAG_LEFT else if (part == RVN_TL_PART_RIGHT) RVN_TL_DRAG_RIGHT else RVN_TL_DRAG_MOVE;
                        tl.*.drag_item = id;
                        rvn_tl_remember(tl);
                        widget_h.rvn_widget_capture_mouse(widget);
                    }
                    return raven.R_TRUE;
                }
            }
            if (y < RVN_TL_RULER and x >= layout.ruler.x) {
                // the ruler: the playhead comes under the pointer and follows it
                var time = tl.*.press_time;
                var found: f64 = 0.0;
                tl.*.drag = @intCast(RVN_TL_DRAG_SCRUB);
                widget_h.rvn_widget_capture_mouse(widget);
                if (tl.*.no_snapping == 0 and (event.*.modifiers & raven.R_MOD_ALT) == 0) {
                    if (rvn_tl_magnet(tl, &layout, time, raven.R_FALSE, &found) != 0) {
                        time = found;
                    } else {
                        time = rvn_tl_quantize(tl, &layout, time);
                    }
                }
                rvn_tl_set_time(widget, time, raven.R_TRUE);
                return raven.R_TRUE;
            }
            if (base.rvn_rect_contains(layout.lanes, x, y) != 0) {
                // empty space: a selection rectangle; a simple click only forgets the selection
                const add = (event.*.modifiers & (raven.R_MOD_CTRL | raven.R_MOD_SHIFT)) != 0;
                var had = false;
                var i: u32 = 0;
                while (i < tl.*.item_count) : (i += 1) {
                    had = had or tl.*.items[i].selected != 0;
                    tl.*.items[i].from_track = if (add and tl.*.items[i].selected != 0) -1 else tl.*.items[i].track;
                    if (!add) tl.*.items[i].selected = raven.R_FALSE;
                }
                tl.*.drag = @intCast(RVN_TL_DRAG_BOX);
                tl.*.box = base.rvn_rect(x, y, 0.0, 0.0);
                widget_h.rvn_widget_capture_mouse(widget);
                widget_h.rvn_widget_invalidate_paint(widget);
                if (had and !add) rvn_tl_notify_item(widget, tl.*.selection_callback, tl.*.selection_user, 0);
                return raven.R_TRUE;
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_MOVE => {
            if (tl.*.drag == RVN_TL_DRAG_NONE) {
                used = common.rvn_scrollbar_event(&tl.*.time_bar, widget, event, layout.time_track, raven.R_FALSE, &changed);
                if (used == 0) used = common.rvn_scrollbar_event(&tl.*.track_bar, widget, event, layout.track_track, raven.R_TRUE, &changed);
                if (changed != 0) rvn_tl_set_view(tl, @as(f64, tl.*.time_bar.offset) * (tl.*.view_span / @as(f64, layout.lanes.w)), tl.*.view_span, raven.R_FALSE);
                if (used != 0) {
                    widget_h.rvn_widget_invalidate_paint(widget);
                    return raven.R_TRUE;
                }
                rvn_tl_update_hot(widget, x, y);
                // (the scrollbars show when the pointer comes near them)
                widget_h.rvn_widget_invalidate_paint(widget);
                return raven.R_FALSE;
            }
            if (tl.*.drag_moved == 0 and @abs(x - tl.*.press_x) < 3.0 and @abs(y - tl.*.press_y) < 3.0 and tl.*.drag != RVN_TL_DRAG_SCRUB) return raven.R_TRUE;
            tl.*.drag_moved = raven.R_TRUE;
            const alt = (event.*.modifiers & raven.R_MOD_ALT) != 0;
            switch (tl.*.drag) {
                RVN_TL_DRAG_SCRUB => {
                    var time = rvn_tl_time_at(tl, &layout, x);
                    var found: f64 = 0.0;
                    if (tl.*.no_snapping == 0 and !alt) {
                        if (rvn_tl_magnet(tl, &layout, time, raven.R_FALSE, &found) != 0) {
                            time = found;
                        } else {
                            time = rvn_tl_quantize(tl, &layout, time);
                        }
                    }
                    rvn_tl_set_time(widget, time, raven.R_TRUE);
                },
                RVN_TL_DRAG_MOVE => rvn_tl_drag_move(widget, &layout, x, y, @intFromBool(alt)),
                RVN_TL_DRAG_LEFT, RVN_TL_DRAG_RIGHT => rvn_tl_drag_stretch(widget, &layout, x, @intFromBool(alt)),
                RVN_TL_DRAG_BOX => rvn_tl_drag_box(widget, &layout, x, y),
                RVN_TL_DRAG_PAN => {
                    rvn_tl_set_view(tl, tl.*.pan_start - @as(f64, x - tl.*.press_x) * (tl.*.view_span / @as(f64, layout.lanes.w)), tl.*.view_span, raven.R_FALSE);
                    _ = common.rvn_scrollbar_set(&tl.*.track_bar, tl.*.pan_scroll - (y - tl.*.press_y));
                },
                else => {},
            }
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            if (tl.*.drag == RVN_TL_DRAG_NONE) {
                used = common.rvn_scrollbar_event(&tl.*.time_bar, widget, event, layout.time_track, raven.R_FALSE, &changed);
                if (used == 0) used = common.rvn_scrollbar_event(&tl.*.track_bar, widget, event, layout.track_track, raven.R_TRUE, &changed);
                return used;
            }
            if ((tl.*.drag == RVN_TL_DRAG_PAN) != (event.*.button == raven.R_MOUSE_MIDDLE)) return raven.R_TRUE;
            // a click on one of several selected items, without moving: it becomes the only one
            if (tl.*.drag == RVN_TL_DRAG_MOVE and tl.*.drag_moved == 0 and (event.*.modifiers & (raven.R_MOD_CTRL | raven.R_MOD_SHIFT)) == 0) {
                const id = tl.*.drag_item;
                var count: u32 = 0;
                var i: u32 = 0;
                while (i < tl.*.item_count) : (i += 1) count += if (tl.*.items[i].selected != 0) @as(u32, 1) else @as(u32, 0);
                if (count > 1) {
                    rvn_tl_select_only(tl, id);
                    rvn_tl_notify_item(widget, tl.*.selection_callback, tl.*.selection_user, id);
                    if (common.rvn_widget_alive(widget) == 0) return raven.R_TRUE;
                }
            }
            rvn_tl_end_drag(widget, raven.R_FALSE);
            if (common.rvn_widget_alive(widget) != 0) rvn_tl_update_hot(widget, x, y);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            if (tl.*.hot_item != 0 or tl.*.hot_toggle >= 0) {
                tl.*.hot_item = 0;
                tl.*.hot_toggle = -1;
            }
            widget_h.rvn_widget_invalidate_paint(widget);
            return raven.R_FALSE;
        },
        raven.R_EVENT_KEY_DOWN => {
            var step: f64 = if (tl.*.fps > 0.0) 1.0 / tl.*.fps else rvn_tl_per_pixel(tl, &layout) * 10.0;
            if ((event.*.modifiers & raven.R_MOD_SHIFT) != 0) step *= 10.0;
            switch (event.*.key) {
                raven.R_KEY_ESCAPE => {
                    if (tl.*.drag == RVN_TL_DRAG_NONE) return raven.R_FALSE;
                    rvn_tl_end_drag(widget, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_LEFT => {
                    rvn_tl_set_time(widget, tl.*.time - step, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_RIGHT => {
                    rvn_tl_set_time(widget, tl.*.time + step, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_HOME => {
                    rvn_tl_set_time(widget, 0.0, raven.R_TRUE);
                    if (common.rvn_widget_alive(widget) != 0) rvn_tl_set_view(tl, 0.0, tl.*.view_span, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_END => {
                    rvn_tl_set_time(widget, tl.*.duration, raven.R_TRUE);
                    if (common.rvn_widget_alive(widget) != 0) rvn_tl_set_view(tl, tl.*.duration, tl.*.view_span, raven.R_TRUE);
                    return raven.R_TRUE;
                },
                raven.R_KEY_SPACE => {
                    rvn_tl_set_playing(widget, @intFromBool(tl.*.playing == 0));
                    return raven.R_TRUE;
                },
                raven.R_KEY_DELETE, raven.R_KEY_BACKSPACE => {
                    rvn_tl_remove_selected(widget);
                    return raven.R_TRUE;
                },
                raven.R_KEY_A => {
                    if ((event.*.modifiers & raven.R_MOD_CTRL) != 0) {
                        var i: u32 = 0;
                        while (i < tl.*.item_count) : (i += 1) tl.*.items[i].selected = raven.R_TRUE;
                        widget_h.rvn_widget_invalidate_paint(widget);
                        rvn_tl_notify_item(widget, tl.*.selection_callback, tl.*.selection_user, 0);
                        return raven.R_TRUE;
                    }
                    return raven.R_FALSE;
                },
                else => return raven.R_FALSE,
            }
        },
        else => return raven.R_FALSE,
    }
}

// ---------------------------------------------------------------------------
//  XML
// ---------------------------------------------------------------------------

fn rvn_tl_xml_double(node: [*c]const xml_h.rvn_xml_node_t, name: [*c]const u8, value: [*c]f64) c_int {
    const text = xml_h.rvn_xml_attribute(node, name);
    var parsed: f32 = undefined;
    if (text == null) return raven.R_FALSE;
    if (widget_h.rvn_parse_float(text, &parsed) == 0) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "XML line %d: <%.40s %.40s=\"%.40s\">: not a number", node.*.line, node.*.name, name, text);
        return raven.R_FALSE;
    }
    value.* = @as(f64, parsed);
    return raven.R_TRUE;
}

fn rvn_tl_xml_item(tl: [*c]rvn_timeline_t, node: [*c]const xml_h.rvn_xml_node_t, item: [*c]rvn_tl_item_t) void {
    var text = xml_h.rvn_xml_attribute(node, "Color");
    var flag: c_int = undefined;
    if (text != null and widget_h.rvn_parse_color(text, &item.*.color) != 0) item.*.has_color = raven.R_TRUE;
    text = xml_h.rvn_xml_attribute(node, "Selected");
    if (text != null and widget_h.rvn_parse_bool(text, &flag) != 0) item.*.selected = flag;
    _ = tl;
}

fn rvn_timeline_xml_child(widget: [*c]widget_h.rvn_widget_t, node: [*c]const xml_h.rvn_xml_node_t) callconv(.c) c_int {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    var child: [*c]const xml_h.rvn_xml_node_t = undefined;
    var text: [*c]const u8 = undefined;
    var start: f64 = 0.0;
    var length: f64 = 1.0;
    var end: f64 = 0.0;
    var flag: c_int = undefined;

    if (base.rvn_stricmp(node.*.name, "Marker") == 0) {
        _ = rvn_tl_xml_double(node, "Time", &start);
        text = xml_h.rvn_xml_attribute(node, "Label");
        rvn_tl_xml_item(tl, node, rvn_tl_add_item(tl, raven.R_TIMELINE_MARKER, 0, start, 0.0, if (text != null) text else node.*.text));
        return raven.R_TRUE;
    }
    if (base.rvn_stricmp(node.*.name, "Track") == 0) {
        var track: [*c]rvn_tl_track_t = undefined;
        var height: f32 = undefined;
        var id: c_int = undefined;
        text = xml_h.rvn_xml_attribute(node, "Name");
        id = rvn_timeline_add_track_by_widget(widget, if (text != null) text else "");
        track = rvn_tl_track(tl, id);
        if (track == null) return raven.R_TRUE;
        text = xml_h.rvn_xml_attribute(node, "Color");
        if (text != null and widget_h.rvn_parse_color(text, &track.*.color) != 0) track.*.has_color = raven.R_TRUE;
        text = xml_h.rvn_xml_attribute(node, "Height");
        if (text != null and widget_h.rvn_parse_float(text, &height) != 0) track.*.height = height;
        text = xml_h.rvn_xml_attribute(node, "Locked");
        if (text != null and widget_h.rvn_parse_bool(text, &flag) != 0) track.*.locked = flag;
        text = xml_h.rvn_xml_attribute(node, "Muted");
        if (text != null and widget_h.rvn_parse_bool(text, &flag) != 0) track.*.muted = flag;
        child = node.*.first_child;
        while (child != null) : (child = child.*.next) {
            if (base.rvn_stricmp(child.*.name, "Clip") == 0) {
                start = 0.0;
                length = 1.0;
                _ = rvn_tl_xml_double(child, "Start", &start);
                if (rvn_tl_xml_double(child, "End", &end) != 0) length = end - start;
                _ = rvn_tl_xml_double(child, "Length", &length);
                text = xml_h.rvn_xml_attribute(child, "Label");
                rvn_tl_xml_item(tl, child, rvn_tl_add_item(tl, raven.R_TIMELINE_CLIP, id, start, length, if (text != null) text else child.*.text));
            } else if (base.rvn_stricmp(child.*.name, "Key") == 0) {
                start = 0.0;
                _ = rvn_tl_xml_double(child, "Time", &start);
                text = xml_h.rvn_xml_attribute(child, "Label");
                rvn_tl_xml_item(tl, child, rvn_tl_add_item(tl, raven.R_TIMELINE_KEY, id, start, 0.0, text));
            } else {
                base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "XML line %d: a <Track> holds <Clip> and <Key>, not <%.40s>", child.*.line, child.*.name);
            }
        }
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

/// Rtimeline_add_track for the XML loader: the same as the public call, on the widget itself.
fn rvn_timeline_add_track_by_widget(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8) c_int {
    return Rtimeline_add_track(widget.*.id, name);
}

fn rvn_timeline_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const tl: [*c]rvn_timeline_t = @ptrCast(@alignCast(widget));
    var number: f32 = undefined;
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Duration") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0 or number <= 0.0) return raven.R_FALSE;
        Rtimeline_set_duration(widget.*.id, @as(f64, number));
    } else if (base.rvn_stricmp(name, "Time") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        rvn_tl_set_time(widget, @as(f64, number), raven.R_FALSE);
    } else if (base.rvn_stricmp(name, "FrameRate") == 0 or base.rvn_stricmp(name, "Fps") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0 or number < 0.0) return raven.R_FALSE;
        tl.*.fps = @as(f64, number);
    } else if (base.rvn_stricmp(name, "Snapping") == 0 or base.rvn_stricmp(name, "Snap") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        tl.*.no_snapping = @intFromBool(flag == 0);
    } else if (base.rvn_stricmp(name, "ViewStart") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        rvn_tl_set_view(tl, @as(f64, number), tl.*.view_span, raven.R_FALSE);
    } else if (base.rvn_stricmp(name, "ViewEnd") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        rvn_tl_set_view(tl, tl.*.view_start, @as(f64, number) - tl.*.view_start, raven.R_FALSE);
    } else if (base.rvn_stricmp(name, "Loop") == 0) {
        if (widget_h.rvn_parse_bool(value, &tl.*.loop) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Playing") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        rvn_tl_set_playing(widget, flag);
    } else if (base.rvn_stricmp(name, "HeaderWidth") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0 or number < 0.0) return raven.R_FALSE;
        tl.*.header_width = number;
    } else if (base.rvn_stricmp(name, "TrackHeight") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0 or number <= 0.0) return raven.R_FALSE;
        tl.*.track_height = base.rvn_maxf(number, 16.0);
        widget_h.rvn_widget_invalidate_layout(widget);
    } else {
        return raven.R_FALSE;
    }
    rvn_tl_sync_bars(tl);
    widget_h.rvn_widget_invalidate_paint(widget);
    return raven.R_TRUE;
}

pub export const rvn_class_timeline: widget_h.rvn_widget_class_t = .{
    .@"type" = raven.R_WIDGET_TIMELINE,
    .name = "Timeline",
    .size = @sizeOf(rvn_timeline_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_CLIP | widget_h.RVN_CF_SURFACE | widget_h.RVN_CF_NO_MIRROR,
    .init = &rvn_timeline_init,
    .destroy = &rvn_timeline_destroy,
    .measure = &rvn_timeline_measure,
    .arrange = &rvn_timeline_arrange,
    .paint = &rvn_timeline_paint,
    .paint_overlay = &rvn_timeline_paint_overlay,
    .event = &rvn_timeline_event,
    .set_attribute = &rvn_timeline_set_attribute,
    .child_active = null,
    .child_at = null,
    .children_changed = null,
    .xml_child = &rvn_timeline_xml_child,
    .popup_closed = null,
    .window_drag_at = null,
};

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

/// RVN_TIMELINE(variable, id, result) / RVN_TIMELINE_VOID(variable, id): the callers pass `__func__` as `function`.
inline fn rvn_timeline_check(id: raven.Rid, function: [*c]const u8) [*c]rvn_timeline_t {
    return @ptrCast(@alignCast(widget_h.rvn_widget_check(id, raven.R_WIDGET_TIMELINE, function)));
}

export fn Rtimeline_create() raven.Rid {
    if (ctx_h.rvn_api_check("Rtimeline_create") == 0) return raven.R_INVALID_ID;
    const widget = widget_h.rvn_widget_create(raven.R_WIDGET_TIMELINE);
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

export fn Rtimeline_set_duration(id: raven.Rid, seconds: f64) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_duration");
    if (tl == null) return;
    if (!(seconds > 0.0)) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtimeline_set_duration: the duration must be positive");
        return;
    }
    // (a view that showed everything goes on showing everything)
    const whole = tl.*.view_start <= 0.0 and tl.*.view_span >= tl.*.duration;
    tl.*.duration = seconds;
    if (tl.*.time > seconds) tl.*.time = seconds;
    rvn_tl_set_view(tl, if (whole) 0.0 else tl.*.view_start, if (whole) seconds else tl.*.view_span, raven.R_FALSE);
}

export fn Rtimeline_get_duration(id: raven.Rid) f64 {
    const tl = rvn_timeline_check(id, "Rtimeline_get_duration");
    if (tl == null) return 0.0;
    return tl.*.duration;
}

export fn Rtimeline_set_time(id: raven.Rid, seconds: f64) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_time");
    if (tl == null) return;
    rvn_tl_set_time(&tl.*.base, seconds, raven.R_FALSE);
}

export fn Rtimeline_get_time(id: raven.Rid) f64 {
    const tl = rvn_timeline_check(id, "Rtimeline_get_time");
    if (tl == null) return 0.0;
    return tl.*.time;
}

export fn Rtimeline_set_frame_rate(id: raven.Rid, frames_per_second: f64) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_frame_rate");
    if (tl == null) return;
    tl.*.fps = if (frames_per_second > 0.0) frames_per_second else 0.0;
    rvn_tl_set_view(tl, tl.*.view_start, tl.*.view_span, raven.R_FALSE);
}

export fn Rtimeline_get_frame_rate(id: raven.Rid) f64 {
    const tl = rvn_timeline_check(id, "Rtimeline_get_frame_rate");
    if (tl == null) return 0.0;
    return tl.*.fps;
}

export fn Rtimeline_set_snapping(id: raven.Rid, enabled: c_int) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_snapping");
    if (tl == null) return;
    tl.*.no_snapping = @intFromBool(enabled == 0);
}

export fn Rtimeline_set_view(id: raven.Rid, start: f64, end: f64) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_view");
    if (tl == null) return;
    if (!(end > start)) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtimeline_set_view: the end must be after the start");
        return;
    }
    rvn_tl_set_view(tl, start, end - start, raven.R_FALSE);
}

export fn Rtimeline_get_view(id: raven.Rid, start: [*c]f64, end: [*c]f64) void {
    const tl = rvn_timeline_check(id, "Rtimeline_get_view");
    if (start != null) start.* = if (tl != null) tl.*.view_start else 0.0;
    if (end != null) end.* = if (tl != null) tl.*.view_start + tl.*.view_span else 0.0;
}

export fn Rtimeline_set_playing(id: raven.Rid, playing: c_int) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_playing");
    if (tl == null) return;
    rvn_tl_set_playing(&tl.*.base, playing);
}

export fn Rtimeline_is_playing(id: raven.Rid) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_is_playing");
    if (tl == null) return raven.R_FALSE;
    return tl.*.playing;
}

export fn Rtimeline_set_loop(id: raven.Rid, loop: c_int) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_loop");
    if (tl == null) return;
    tl.*.loop = @intFromBool(loop != 0);
}

// ---- tracks ----

export fn Rtimeline_add_track(id: raven.Rid, name: [*c]const u8) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_add_track");
    if (tl == null) return 0;
    base.RVN_ARRAY_RESERVE(&tl.*.tracks, &tl.*.track_cap, tl.*.track_count + 1);
    const index = tl.*.track_count;
    tl.*.track_count += 1;
    const track: [*c]rvn_tl_track_t = &tl.*.tracks[index];
    track.* = std.mem.zeroes(rvn_tl_track_t);
    track.*.id = tl.*.next_id;
    tl.*.next_id += 1;
    const text: [*c]const u8 = if (name != null) name else "";
    track.*.name = base.rvn_strdup(text);
    rvn_tl_sync_bars(tl);
    widget_h.rvn_widget_invalidate_layout(&tl.*.base);
    return track.*.id;
}

export fn Rtimeline_remove_track(id: raven.Rid, track_id: c_int) void {
    const tl = rvn_timeline_check(id, "Rtimeline_remove_track");
    if (tl == null) return;
    const index = rvn_tl_track_index(tl, track_id);
    if (index < 0) return;
    var i: u32 = 0;
    while (i < tl.*.item_count) {
        if (tl.*.items[i].track == track_id) {
            rvn_tl_remove_item_at(tl, i);
        } else {
            i += 1;
        }
    }
    const at: u32 = @intCast(index);
    base.rvn_free(tl.*.tracks[at].name);
    const count: usize = @as(usize, tl.*.track_count - at - 1);
    _ = libc.memmove(&tl.*.tracks[at], &tl.*.tracks[at + 1], @sizeOf(rvn_tl_track_t) * count);
    tl.*.track_count -= 1;
    tl.*.hot_toggle = -1;
    rvn_tl_sync_bars(tl);
    widget_h.rvn_widget_invalidate_layout(&tl.*.base);
}

export fn Rtimeline_get_track_count(id: raven.Rid) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_get_track_count");
    if (tl == null) return 0;
    return @intCast(tl.*.track_count);
}

export fn Rtimeline_get_track(id: raven.Rid, index: c_int) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_get_track");
    if (tl == null) return 0;
    return if (index >= 0 and index < @as(c_int, @intCast(tl.*.track_count))) tl.*.tracks[@intCast(index)].id else 0;
}

export fn Rtimeline_set_track_name(id: raven.Rid, track_id: c_int, name: [*c]const u8) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_track_name");
    if (tl == null) return;
    const track = rvn_tl_track(tl, track_id);
    const text: [*c]const u8 = if (name != null) name else "";
    if (track != null and base.rvn_str_set(&track.*.name, text) != 0) widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_get_track_name(id: raven.Rid, track_id: c_int) [*c]const u8 {
    const tl = rvn_timeline_check(id, "Rtimeline_get_track_name");
    if (tl == null) return "";
    const track = rvn_tl_track(tl, track_id);
    return if (track != null and track.*.name != null) track.*.name else "";
}

export fn Rtimeline_set_track_color(id: raven.Rid, track_id: c_int, r: f32, g: f32, b: f32) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_track_color");
    if (tl == null) return;
    const track = rvn_tl_track(tl, track_id);
    if (track == null) return;
    track.*.color = base.rvn_rgba(r, g, b, 1.0);
    track.*.has_color = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_set_track_height(id: raven.Rid, track_id: c_int, height: f32) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_track_height");
    if (tl == null) return;
    const track = rvn_tl_track(tl, track_id);
    if (track == null) return;
    track.*.height = if (height > 0.0) base.rvn_maxf(height, 16.0) else 0.0;
    rvn_tl_sync_bars(tl);
    widget_h.rvn_widget_invalidate_layout(&tl.*.base);
}

export fn Rtimeline_set_track_locked(id: raven.Rid, track_id: c_int, locked: c_int) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_track_locked");
    if (tl == null) return;
    const track = rvn_tl_track(tl, track_id);
    if (track == null) return;
    track.*.locked = @intFromBool(locked != 0);
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_set_track_muted(id: raven.Rid, track_id: c_int, muted: c_int) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_track_muted");
    if (tl == null) return;
    const track = rvn_tl_track(tl, track_id);
    if (track == null) return;
    track.*.muted = @intFromBool(muted != 0);
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_is_track_muted(id: raven.Rid, track_id: c_int) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_is_track_muted");
    if (tl == null) return raven.R_FALSE;
    const track = rvn_tl_track(tl, track_id);
    return if (track != null) track.*.muted else raven.R_FALSE;
}

// ---- items ----

export fn Rtimeline_add_clip(id: raven.Rid, track: c_int, start: f64, length: f64, label: [*c]const u8) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_add_clip");
    if (tl == null) return 0;
    if (rvn_tl_track(tl, track) == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtimeline_add_clip: no such track");
        return 0;
    }
    return rvn_tl_add_item(tl, raven.R_TIMELINE_CLIP, track, start, length, label).*.id;
}

export fn Rtimeline_add_key(id: raven.Rid, track: c_int, time: f64) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_add_key");
    if (tl == null) return 0;
    if (rvn_tl_track(tl, track) == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtimeline_add_key: no such track");
        return 0;
    }
    return rvn_tl_add_item(tl, raven.R_TIMELINE_KEY, track, time, 0.0, null).*.id;
}

export fn Rtimeline_add_marker(id: raven.Rid, time: f64, label: [*c]const u8) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_add_marker");
    if (tl == null) return 0;
    return rvn_tl_add_item(tl, raven.R_TIMELINE_MARKER, 0, time, 0.0, label).*.id;
}

export fn Rtimeline_remove_item(id: raven.Rid, item_id: c_int) void {
    const tl = rvn_timeline_check(id, "Rtimeline_remove_item");
    if (tl == null) return;
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) {
        if (tl.*.items[i].id == item_id) {
            rvn_tl_remove_item_at(tl, i);
            widget_h.rvn_widget_invalidate_paint(&tl.*.base);
            return;
        }
    }
}

export fn Rtimeline_clear(id: raven.Rid) void {
    const tl = rvn_timeline_check(id, "Rtimeline_clear");
    if (tl == null) return;
    if (tl.*.drag != RVN_TL_DRAG_NONE) rvn_tl_end_drag(&tl.*.base, raven.R_TRUE);
    rvn_tl_clear(tl);
    rvn_tl_sync_bars(tl);
    widget_h.rvn_widget_invalidate_layout(&tl.*.base);
}

export fn Rtimeline_get_item_type(id: raven.Rid, item_id: c_int) raven.RTimelineItem {
    const tl = rvn_timeline_check(id, "Rtimeline_get_item_type");
    if (tl == null) return raven.R_TIMELINE_NONE;
    const item = rvn_tl_item(tl, item_id);
    return if (item != null) item.*.@"type" else raven.R_TIMELINE_NONE;
}

export fn Rtimeline_get_item_track(id: raven.Rid, item_id: c_int) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_get_item_track");
    if (tl == null) return 0;
    const item = rvn_tl_item(tl, item_id);
    return if (item != null) item.*.track else 0;
}

export fn Rtimeline_get_item_start(id: raven.Rid, item_id: c_int) f64 {
    const tl = rvn_timeline_check(id, "Rtimeline_get_item_start");
    if (tl == null) return 0.0;
    const item = rvn_tl_item(tl, item_id);
    return if (item != null) item.*.start else 0.0;
}

export fn Rtimeline_get_item_length(id: raven.Rid, item_id: c_int) f64 {
    const tl = rvn_timeline_check(id, "Rtimeline_get_item_length");
    if (tl == null) return 0.0;
    const item = rvn_tl_item(tl, item_id);
    return if (item != null) item.*.length else 0.0;
}

export fn Rtimeline_set_item(id: raven.Rid, item_id: c_int, track: c_int, start: f64, length: f64) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_item");
    if (tl == null) return;
    const item = rvn_tl_item(tl, item_id);
    if (item == null) return;
    if (track != 0 and item.*.@"type" != raven.R_TIMELINE_MARKER) {
        if (rvn_tl_track(tl, track) == null) {
            base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtimeline_set_item: no such track");
            return;
        }
        item.*.track = track;
    }
    item.*.start = if (start < 0.0) 0.0 else start;
    if (length >= 0.0 and item.*.@"type" == raven.R_TIMELINE_CLIP) item.*.length = length;
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_set_item_label(id: raven.Rid, item_id: c_int, label: [*c]const u8) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_item_label");
    if (tl == null) return;
    const item = rvn_tl_item(tl, item_id);
    const text: [*c]const u8 = if (label != null and label[0] != 0) label else null;
    if (item != null and base.rvn_str_set(&item.*.label, text) != 0) widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_get_item_label(id: raven.Rid, item_id: c_int) [*c]const u8 {
    const tl = rvn_timeline_check(id, "Rtimeline_get_item_label");
    if (tl == null) return "";
    const item = rvn_tl_item(tl, item_id);
    return if (item != null and item.*.label != null) item.*.label else "";
}

export fn Rtimeline_set_item_color(id: raven.Rid, item_id: c_int, r: f32, g: f32, b: f32) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_item_color");
    if (tl == null) return;
    const item = rvn_tl_item(tl, item_id);
    if (item == null) return;
    item.*.color = base.rvn_rgba(r, g, b, 1.0);
    item.*.has_color = raven.R_TRUE;
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_get_item_count(id: raven.Rid) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_get_item_count");
    if (tl == null) return 0;
    return @intCast(tl.*.item_count);
}

export fn Rtimeline_get_item(id: raven.Rid, index: c_int) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_get_item");
    if (tl == null) return 0;
    return if (index >= 0 and index < @as(c_int, @intCast(tl.*.item_count))) tl.*.items[@intCast(index)].id else 0;
}

// ---- selection ----

export fn Rtimeline_select(id: raven.Rid, item_id: c_int, add: c_int) void {
    const tl = rvn_timeline_check(id, "Rtimeline_select");
    if (tl == null) return;
    const item = rvn_tl_item(tl, item_id);
    if (item == null) return;
    if (add != 0) {
        item.*.selected = raven.R_TRUE;
    } else {
        rvn_tl_select_only(tl, item_id);
    }
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_clear_selection(id: raven.Rid) void {
    const tl = rvn_timeline_check(id, "Rtimeline_clear_selection");
    if (tl == null) return;
    rvn_tl_select_only(tl, 0);
    widget_h.rvn_widget_invalidate_paint(&tl.*.base);
}

export fn Rtimeline_is_selected(id: raven.Rid, item_id: c_int) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_is_selected");
    if (tl == null) return raven.R_FALSE;
    const item = rvn_tl_item(tl, item_id);
    return if (item != null) item.*.selected else raven.R_FALSE;
}

export fn Rtimeline_get_selection_count(id: raven.Rid) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_get_selection_count");
    if (tl == null) return 0;
    var count: c_int = 0;
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) count += if (tl.*.items[i].selected != 0) 1 else 0;
    return count;
}

export fn Rtimeline_get_selected(id: raven.Rid, index: c_int) c_int {
    const tl = rvn_timeline_check(id, "Rtimeline_get_selected");
    if (tl == null) return 0;
    var remaining = index;
    var i: u32 = 0;
    while (i < tl.*.item_count) : (i += 1) {
        if (tl.*.items[i].selected != 0) {
            const old = remaining;
            remaining -= 1;
            if (old == 0) return tl.*.items[i].id;
        }
    }
    return 0;
}

// ---- callbacks ----

export fn Rtimeline_set_time_callback(id: raven.Rid, callback: raven.RTimelineTimeCallback, user_data: ?*anyopaque) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_time_callback");
    if (tl == null) return;
    tl.*.time_callback = callback;
    tl.*.time_user = user_data;
}

export fn Rtimeline_set_changed_callback(id: raven.Rid, callback: raven.RTimelineItemCallback, user_data: ?*anyopaque) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_changed_callback");
    if (tl == null) return;
    tl.*.changed_callback = callback;
    tl.*.changed_user = user_data;
}

export fn Rtimeline_set_selection_callback(id: raven.Rid, callback: raven.RTimelineItemCallback, user_data: ?*anyopaque) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_selection_callback");
    if (tl == null) return;
    tl.*.selection_callback = callback;
    tl.*.selection_user = user_data;
}

export fn Rtimeline_set_activated_callback(id: raven.Rid, callback: raven.RTimelineItemCallback, user_data: ?*anyopaque) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_activated_callback");
    if (tl == null) return;
    tl.*.activated_callback = callback;
    tl.*.activated_user = user_data;
}

export fn Rtimeline_set_removed_callback(id: raven.Rid, callback: raven.RTimelineItemCallback, user_data: ?*anyopaque) void {
    const tl = rvn_timeline_check(id, "Rtimeline_set_removed_callback");
    if (tl == null) return;
    tl.*.removed_callback = callback;
    tl.*.removed_user = user_data;
}
