//! Translated to Zig from src/ui/raven_app.c lines 507-1011: widget helpers, meters, clock, timeline and clip panel. Seridian Studio window, 1:1 translation.

const std = @import("std");
const raven = @import("raven");
const st = @import("state.zig");
const ext = @import("externs.zig");
const libc = @import("libc.zig");
const fns = @import("fns.zig");
const palette = @import("../palette.zig");
const ui_math = @import("../ui_math.zig");
const piano_math = @import("../piano_math.zig");
const ui_state = @import("../ui_state.zig");
const window_input = @import("../window_input.zig");

const app = &st.app;

pub fn track_color(track: c_int) [*c]const palette.SeridianTrackColor {
    return palette.palette_track_color_at(app.track_color_index[@intCast(track)]);
}

/// Display name of a track: the project name where the project stores one, otherwise "Audio N".
pub fn track_display_name(track: c_int, fallback: [*c]u8, capacity: usize) [*c]const u8 {
    if (track >= 0 and track < st.SERIDIAN_PROJECT_TRACKS and track < st.SERIDIAN_TRACK_COUNT) {
        const name = ext.project_get_track_name(track);
        if (name != null and name[0] != 0) return name;
    }
    _ = libc.snprintf(fallback, capacity, "Audio %d", track + 1);
    return fallback;
}

pub fn make_row(spacing: f32) raven.Rid {
    const row = raven.Rwidget_create(raven.R_WIDGET_HBOX);
    raven.Rpanel_set_spacing(row, spacing);
    return row;
}

pub fn make_column(spacing: f32) raven.Rid {
    const column = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    raven.Rpanel_set_spacing(column, spacing);
    return column;
}

pub fn make_panel(child: raven.Rid, padding: f32) raven.Rid {
    const panel = raven.Rwidget_create(raven.R_WIDGET_BORDER);
    raven.Rborder_set_background(panel, 0.063, 0.071, 0.165, 1.0);
    raven.Rborder_set_outline(panel, 1.0, 0.15, 0.17, 0.20, 0.95);
    raven.Rborder_set_corner_radius(panel, 8.0, 8.0, 8.0, 8.0);
    raven.Rborder_set_padding(panel, padding, padding, padding, padding);
    _ = raven.Rwidget_add_child(panel, child);
    return panel;
}

pub fn make_label(text: [*c]const u8, size: f32, color: [*c]const f32) raven.Rid {
    const label = raven.Rlabel_create(text);
    raven.Rlabel_set_text_size(label, size);
    if (color != null) raven.Rlabel_set_color(label, color[0], color[1], color[2], 1.0);
    return label;
}

pub fn make_wrapped_label(text: [*c]const u8, size: f32, color: [*c]const f32) raven.Rid {
    const label = make_label(text, size, color);
    raven.Rlabel_set_wrap(label, raven.R_TRUE);
    return label;
}

pub fn add_button(parent: raven.Rid, text: [*c]const u8, callback: raven.RButtonClickedCallback, data: ?*anyopaque, style: raven.RButtonStyle) raven.Rid {
    const button = raven.Rbutton_create(text);
    raven.Rbutton_set_style(button, style);
    raven.Rbutton_set_clicked_callback(button, callback, data);
    _ = raven.Rwidget_add_child(parent, button);
    return button;
}

pub fn make_slider(minimum: f32, maximum: f32, value: f32, step: f32, callback: raven.RSliderChangedCallback, data: ?*anyopaque, width: f32) raven.Rid {
    const slider = raven.Rwidget_create(raven.R_WIDGET_SLIDER);
    raven.Rslider_set_range(slider, minimum, maximum);
    raven.Rslider_set_step(slider, step);
    raven.Rslider_set_value(slider, value);
    if (callback != null) raven.Rslider_set_changed_callback(slider, callback, data);
    raven.Rwidget_set_size(slider, width, 24.0);
    return slider;
}

/// A filled button in a state colour (on or active), with dark or light text on it.
pub fn style_fill_button(button: raven.Rid, fill: [*c]const f32, text: [*c]const f32) void {
    raven.Rbutton_set_style(button, raven.R_BUTTON_PRIMARY);
    raven.Rwidget_set_color(button, raven.R_COLOR_ACCENT, fill[0], fill[1], fill[2], 1.0);
    raven.Rwidget_set_color(button, raven.R_COLOR_ACCENT_HOVERED, fill[0], fill[1], fill[2], 1.0);
    raven.Rwidget_set_color(button, raven.R_COLOR_ACCENT_PRESSED, fill[0], fill[1], fill[2], 1.0);
    raven.Rwidget_set_color(button, raven.R_COLOR_ACCENT_TEXT, text[0], text[1], text[2], 1.0);
}

/// A dark filled button with the theme border: the off state of toggles.
pub fn style_plain_button(button: raven.Rid) void {
    raven.Rbutton_set_style(button, raven.R_BUTTON_DEFAULT);
}

pub fn style_toggle_button(button: raven.Rid, on: c_int, on_color: [*c]const f32) void {
    if (on != 0) {
        style_fill_button(button, on_color, &st.color_ink);
    } else {
        style_plain_button(button);
    }
}

pub fn make_fixed_button(text: [*c]const u8, width: f32, height: f32) raven.Rid {
    const button = raven.Rbutton_create(text);
    raven.Rwidget_set_size(button, width, height);
    return button;
}

/// Vertical fader: value is linear gain, 0 at the bottom and 1 (0 dB) at the top.
pub fn make_vertical_fader(value: f32, callback: raven.RSliderChangedCallback, data: ?*anyopaque) raven.Rid {
    const slider = raven.Rwidget_create(raven.R_WIDGET_SLIDER);
    raven.Rslider_set_orientation(slider, raven.R_VERTICAL);
    raven.Rslider_set_range(slider, 0.0, 1.0);
    raven.Rslider_set_step(slider, 0.01);
    raven.Rslider_set_value(slider, value);
    if (callback != null) raven.Rslider_set_changed_callback(slider, callback, data);
    raven.Rwidget_set_size(slider, st.SERIDIAN_FADER_WIDTH, st.SERIDIAN_FADER_HEIGHT);
    return slider;
}

/// dB scale drawn beside a fader. Gain g sits at height (1 - g) because the fader top is 0 dB.
pub fn db_scale_paint(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = user_data;
    // Labels for 0 to -24 dB only: below -24 the marks sit under 8 px apart and the text would overlap.
    const marks_db = [_]f32{ 0.0, -6.0, -12.0, -24.0, -48.0 };
    const mark_text = [_][*c]const u8{ "0", "-6", "-12", "-24", null };
    const label_x: f32 = 2.0;
    const tick_x0: f32 = width - 8.0;
    const text_size: f32 = 12.0;
    var i: usize = 0;
    while (i < marks_db.len) : (i += 1) {
        const gain: f32 = libc.powf(10.0, marks_db[i] / 20.0);
        const y: f32 = (1.0 - gain) * height;
        const is_unity: c_int = @intFromBool(i == 0);
        const tick: [*c]const f32 = if (is_unity != 0) &st.accent_cyan else &st.muted_text;
        raven.Rdraw_line(painter, tick_x0, y, width, y, if (is_unity != 0) @as(f32, 2.0) else @as(f32, 1.0), tick[0], tick[1], tick[2], 1.0);
        if (mark_text[i] != null) {
            const text_y: f32 = libc.fminf(libc.fmaxf(y - text_size * 0.5, 0.0), height - text_size);
            raven.Rdraw_text(painter, raven.R_INVALID_ID, text_size, label_x, text_y, mark_text[i], tick[0], tick[1], tick[2], 1.0);
        }
    }
    // -inf sits at the bottom edge of the fader; its mark is unlabelled, see the dB readout box.
    raven.Rdraw_line(painter, tick_x0, height - 1.0, width, height - 1.0, 1.0, st.muted_text[0], st.muted_text[1], st.muted_text[2], 1.0);
}

pub fn make_db_scale() raven.Rid {
    const scale = raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
    raven.Rcustom_set_paint_callback(scale, &db_scale_paint, null);
    raven.Rwidget_set_size(scale, 40.0, st.SERIDIAN_FADER_HEIGHT);
    return scale;
}

/// Vertical level meter: green to yellow to red, dim when idle, with a peak-hold tick.
pub fn meter_paint(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const meter: [*c]const st.MeterView = @ptrCast(@alignCast(user_data));
    const idle: c_int = @intFromBool(meter.*.level < 0.001);
    const lit: f32 = if (idle != 0) 0.25 else 1.0;
    raven.Rdraw_rect(painter, 0.0, 0.0, width, height, 2.0, st.color_fader_track[0], st.color_fader_track[1], st.color_fader_track[2], 1.0);
    const bands = [3][3]f32{
        .{ 0.000, 0.700, 0.180 }, // green: lower 70 percent of the meter
        .{ 0.700, 0.900, 0.950 }, // yellow: 70 to 90 percent
        .{ 0.900, 1.000, 1.000 }, // red: top 10 percent
    };
    const colors = [3][3]f32{
        .{ 0.180, 0.800, 0.443 },
        .{ 1.000, 0.820, 0.200 },
        .{ 1.000, 0.250, 0.250 },
    };
    const level: f32 = libc.fminf(libc.fmaxf(meter.*.level, 0.0), 1.0);
    var band: c_int = 0;
    while (band < 3) : (band += 1) {
        const top: f32 = libc.fminf(level, bands[@intCast(band)][1]);
        if (top <= bands[@intCast(band)][0]) continue;
        const y0: f32 = height * (1.0 - top);
        const y1: f32 = height * (1.0 - bands[@intCast(band)][0]);
        raven.Rdraw_rect(painter, 1.0, y0, width - 2.0, y1 - y0, 0.0, colors[@intCast(band)][0], colors[@intCast(band)][1], colors[@intCast(band)][2], lit);
    }
    if (meter.*.peak > 0.001) {
        const y: f32 = height * (1.0 - libc.fminf(meter.*.peak, 1.0));
        raven.Rdraw_rect(painter, 0.0, y - 1.0, width, 2.0, 0.0, 1.0, 1.0, 1.0, if (idle != 0) @as(f32, 0.35) else @as(f32, 0.95));
    }
    raven.Rdraw_rect_outline(painter, 0.0, 0.0, width, height, 2.0, 1.0, 0.19, 0.22, 0.25, 1.0);
}

pub fn make_meter(view_index: c_int) raven.Rid {
    const meter = raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
    raven.Rcustom_set_paint_callback(meter, &meter_paint, &st.meter_views[@intCast(view_index)]);
    raven.Rwidget_set_size(meter, st.SERIDIAN_METER_WIDTH, st.SERIDIAN_FADER_HEIGHT);
    return meter;
}

pub fn set_status(message: [*c]const u8) void {
    if (app.status_label != raven.R_INVALID_ID) raven.Rlabel_set_text(app.status_label, message);
}

pub fn session_has_content() c_int {
    if (ext.project_has_save_location() != 0) return 1;
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        if (ext.track_get_clip_count(app.engine, track) > 0) return 1;
    }
    return 0;
}

pub fn update_position(seconds: f64) void {
    var bar: c_int = 0;
    var beat: c_int = 0;
    ui_math.ui_bar_beat(seconds, ext.audio_engine_get_tempo(app.engine), ext.project_get_time_sig_num(), &bar, &beat);
    if (bar == 0) return;
    var text: [48]u8 = undefined;
    _ = libc.snprintf(&text, text.len, "Bar %d · Beat %d", bar, beat);
    raven.Rlabel_set_text(app.position_label, &text);
}

/// `seconds_` is the C parameter `seconds`, which the C body reassigns; `seconds` is its mutable copy.
pub fn update_clock(seconds_: f64) void {
    var seconds = seconds_;
    var text: [32]u8 = undefined;
    if (seconds < 0.0) seconds = 0.0;
    const whole_seconds: c_int = @intFromFloat(seconds);
    const millis: c_int = @intFromFloat((seconds - @as(f64, @floatFromInt(whole_seconds))) * 1000.0);
    _ = libc.snprintf(&text, text.len, "%02d:%02d.%03d", @divTrunc(whole_seconds, 60), @rem(whole_seconds, 60), millis);
    raven.Rlabel_set_text(app.clock_label, &text);
    update_position(seconds);
}

pub fn bind_clip(item: c_int, track: c_int, engine_clip: u64) void {
    if (item == 0 or app.clip_count >= st.SERIDIAN_CLIP_CAPACITY) return;
    app.clips[app.clip_count] = .{
        .timeline_item = item,
        .track = track,
        .engine_clip = engine_clip,
    };
    app.clip_count += 1;
}

pub fn find_clip(item: c_int) [*c]st.ClipBinding {
    var i: usize = 0;
    while (i < app.clip_count) : (i += 1) {
        if (app.clips[i].timeline_item == item) return &app.clips[i];
    }
    return null;
}

pub fn selected_clip_binding() [*c]st.ClipBinding {
    if (app.selected_item < 0) return null;
    return find_clip(app.selected_item);
}

pub fn fx_alloc(track: c_int, slot: c_int, param: c_int) [*c]st.FxBinding {
    if (st.fx_pool_used >= st.SERIDIAN_FX_POOL_CAPACITY) return null;
    const binding: *st.FxBinding = &st.fx_pool[st.fx_pool_used];
    st.fx_pool_used += 1;
    binding.* = .{ .track = track, .slot = slot, .param = param };
    return binding;
}

/// Time span in seconds of the notes on `track`; returns 0 when the track holds none.
pub fn midi_track_span(track: c_int, start_seconds: [*c]f64, length_seconds: [*c]f64) c_int {
    const count = ext.midi_clip_get_note_count(track);
    if (count <= 0) return 0;
    const bpm: f64 = ext.audio_engine_get_tempo(app.engine);
    if (!(bpm > 0.0)) return 0;
    var first: f64 = 0.0;
    var last: f64 = 0.0;
    var seen: c_int = 0;
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        var id: u32 = 0;
        var start: f64 = 0.0;
        var duration: f64 = 0.0;
        var pitch: u8 = 0;
        var velocity: u8 = 0;
        var selected: c_int = 0;
        if (ext.midi_clip_get_note(track, index, &id, &start, &duration, &pitch, &velocity, &selected) != 1) continue;
        if (seen == 0 or start < first) first = start;
        if (seen == 0 or start + duration > last) last = start + duration;
        seen = 1;
    }
    if (seen == 0) return 0;
    start_seconds.* = first * 60.0 / bpm;
    length_seconds.* = (last - first) * 60.0 / bpm;
    if (length_seconds.* < 0.05) length_seconds.* = 0.05;
    return 1;
}

pub fn populate_midi_blocks() void {
    st.midi_block_count = 0;
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        var start: f64 = 0.0;
        var length: f64 = 0.0;
        if (midi_track_span(track, &start, &length) == 0) continue;
        var fallback_name: [16]u8 = undefined;
        const name = track_display_name(track, &fallback_name, fallback_name.len);
        const item = raven.Rtimeline_add_clip(app.timeline, track, start, length, name);
        if (item == 0) continue;
        const color = track_color(track);
        if (color != null) raven.Rtimeline_set_item_color(app.timeline, item, color.*.color.r, color.*.color.g, color.*.color.b);
        st.midi_blocks[@intCast(st.midi_block_count)] = .{ .track = track, .item = item, .timeline_track = track };
        st.midi_block_count += 1;
    }
}

/// Keeps the MIDI blocks in step with the notes. Moves existing blocks in place; rebuilds the timeline (keeping the
/// view) only when a track gained its first note or lost its last one.
pub fn refresh_midi_blocks() void {
    if (app.timeline == raven.R_INVALID_ID) return;
    var wanted: c_int = 0;
    var same: c_int = 1;
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        var start: f64 = 0.0;
        var length: f64 = 0.0;
        if (midi_track_span(track, &start, &length) == 0) continue;
        if (wanted >= st.midi_block_count or st.midi_blocks[@intCast(wanted)].track != track) same = 0;
        wanted += 1;
    }
    if (same == 0 or wanted != st.midi_block_count) {
        var view_start: f64 = 0.0;
        var view_end: f64 = st.SERIDIAN_DEFAULT_VIEW_SECONDS;
        raven.Rtimeline_get_view(app.timeline, &view_start, &view_end);
        populate_timeline();
        raven.Rtimeline_set_view(app.timeline, view_start, view_end);
        return;
    }
    var i: c_int = 0;
    while (i < st.midi_block_count) : (i += 1) {
        var start: f64 = 0.0;
        var length: f64 = 0.0;
        if (midi_track_span(st.midi_blocks[@intCast(i)].track, &start, &length) != 0) {
            raven.Rtimeline_set_item(app.timeline, st.midi_blocks[@intCast(i)].item, st.midi_blocks[@intCast(i)].timeline_track, start, length);
        }
    }
}

pub fn populate_timeline() void {
    app.clip_count = 0;
    app.selected_item = -1;
    raven.Rtimeline_clear(app.timeline);
    raven.Rtimeline_set_duration(app.timeline, 180.0);
    raven.Rtimeline_set_view(app.timeline, 0.0, st.SERIDIAN_DEFAULT_VIEW_SECONDS);
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        var fallback_name: [16]u8 = undefined;
        const name = track_display_name(track, &fallback_name, fallback_name.len);
        const timeline_track = raven.Rtimeline_add_track(app.timeline, name);
        raven.Rtimeline_set_track_height(app.timeline, timeline_track, st.SERIDIAN_TRACK_HEIGHT);
        const color = track_color(track);
        if (color != null) {
            raven.Rtimeline_set_track_color(app.timeline, timeline_track, color.*.color.r, color.*.color.g, color.*.color.b);
        }

        const count = ext.track_get_clip_count(app.engine, track);
        var clip_index: c_int = 0;
        while (clip_index < count) : (clip_index += 1) {
            const clip_id: u64 = ext.track_get_clip_id(app.engine, track, clip_index);
            const start: f64 = ext.track_get_clip_start(app.engine, track, clip_id);
            const duration: f64 = ext.track_get_clip_duration(app.engine, track, clip_id);
            const clip_name: [*c]const u8 = ext.track_get_clip_name(app.engine, track, clip_id);
            const item = raven.Rtimeline_add_clip(app.timeline, timeline_track, start, duration, if (clip_name != null and clip_name[0] != 0) clip_name else @as([*c]const u8, "Audio clip"));
            bind_clip(item, track, clip_id);
            if (item != 0 and color != null) {
                raven.Rtimeline_set_item_color(app.timeline, item, color.*.color.r, color.*.color.g, color.*.color.b);
            }
        }
    }
    populate_midi_blocks();
    raven.Rtimeline_set_snapping(app.timeline, raven.R_TRUE);

    var total_clips: c_int = 0;
    track = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        total_clips += ext.track_get_clip_count(app.engine, track);
    }
    raven.Rwidget_set_visibility(app.empty_hint, if (total_clips == 0) raven.R_VISIBLE else raven.R_COLLAPSED);
    update_clip_panel();
}

pub fn on_play(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    if (ext.audio_engine_is_playing(app.engine) != 0) {
        ext.audio_engine_stop(app.engine);
        raven.Rbutton_set_text(app.play_button, "▶  Play");
        set_status("Playback paused");
        return;
    }
    if (ext.audio_engine_start(app.engine) == 0) {
        raven.Rbutton_set_text(app.play_button, "Ⅱ  Pause");
        set_status("Audio engine running");
    } else {
        set_status("Could not start audio engine — check the selected device");
    }
}

pub fn on_stop(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    ext.audio_engine_stop(app.engine);
    ext.audio_engine_set_position(app.engine, 0);
    raven.Rtimeline_set_time(app.timeline, 0.0);
    raven.Rbutton_set_text(app.play_button, "▶  Play");
    update_clock(0.0);
    set_status("Stopped at the beginning");
}

pub fn on_bpm_changed(input: raven.Rid, bpm: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = input;
    _ = user_data;
    ext.audio_engine_set_tempo(app.engine, @floatCast(bpm));
    ext.project_set_bpm(@floatCast(bpm));
    update_position(raven.Rtimeline_get_time(app.timeline));
    set_status("Tempo updated");
}

pub fn on_timeline_time(timeline: raven.Rid, seconds: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = timeline;
    _ = user_data;
    const rate: u32 = ext.audio_engine_get_sample_rate(app.engine);
    if (rate > 0) ext.audio_engine_set_position(app.engine, @intFromFloat(seconds * @as(f64, @floatFromInt(rate))));
    update_clock(seconds);
}

pub fn on_timeline_selection(timeline: raven.Rid, item: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = item;
    _ = user_data;
    const count = raven.Rtimeline_get_selection_count(timeline);
    app.selected_item = if (count > 0) raven.Rtimeline_get_selected(timeline, 0) else -1;
    if (selected_clip_binding() != null) {
        raven.Rtab_view_set_active(app.tab_view, st.SERIDIAN_TAB_CLIP);
        set_status("Clip selected — edit gain, fades and mute in the Clip tab");
    }
    update_clip_panel();
}

pub fn on_clip_changed(timeline: raven.Rid, item: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    const binding = find_clip(item);
    if (binding == null) return;
    const start = raven.Rtimeline_get_item_start(timeline, item);
    const length = raven.Rtimeline_get_item_length(timeline, item);
    _ = ext.track_set_clip_position(app.engine, binding.*.track, binding.*.engine_clip, start);
    _ = ext.track_set_clip_duration(app.engine, binding.*.track, binding.*.engine_clip, length);
    update_clip_panel();
    set_status("Clip arrangement changed");
}

pub fn on_clip_removed(timeline: raven.Rid, item: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = timeline;
    _ = user_data;
    const binding = find_clip(item);
    if (binding == null) return;
    if (ext.track_remove_clip(app.engine, binding.*.track, binding.*.engine_clip) != 0) {
        populate_timeline();
        set_status("Clip removed");
    } else {
        set_status("Could not remove clip");
    }
}

pub fn update_clip_panel() void {
    if (app.clip_empty_hint == raven.R_INVALID_ID) return;
    const binding: [*c]const st.ClipBinding = selected_clip_binding();
    if (binding == null) {
        raven.Rwidget_set_visibility(app.clip_controls, raven.R_COLLAPSED);
        raven.Rwidget_set_visibility(app.clip_empty_hint, raven.R_VISIBLE);
        return;
    }

    const start: f64 = ext.track_get_clip_start(app.engine, binding.*.track, binding.*.engine_clip);
    const duration: f64 = ext.track_get_clip_duration(app.engine, binding.*.track, binding.*.engine_clip);
    const name: [*c]const u8 = ext.track_get_clip_name(app.engine, binding.*.track, binding.*.engine_clip);
    const gain: f32 = ext.track_get_clip_gain(app.engine, binding.*.track, binding.*.engine_clip);
    const fade_in: f32 = ext.track_get_clip_fade_in(app.engine, binding.*.track, binding.*.engine_clip);
    const fade_out: f32 = ext.track_get_clip_fade_out(app.engine, binding.*.track, binding.*.engine_clip);
    const muted: c_int = ext.track_get_clip_muted(app.engine, binding.*.track, binding.*.engine_clip);

    var range: [96]u8 = undefined;
    var gain_text: [24]u8 = undefined;
    ui_math.ui_format_gain(gain, &gain_text, gain_text.len);
    _ = libc.snprintf(&range, range.len, "%.2f s → %.2f s  ·  %.2f s long", start, start + duration, duration);

    app.syncing += 1;
    raven.Rwidget_set_visibility(app.clip_empty_hint, raven.R_COLLAPSED);
    raven.Rwidget_set_visibility(app.clip_controls, raven.R_VISIBLE);
    raven.Rlabel_set_text(app.clip_title, if (name != null and name[0] != 0) name else @as([*c]const u8, "Audio clip"));
    raven.Rlabel_set_text(app.clip_range, &range);
    raven.Rslider_set_value(app.clip_gain, gain);
    raven.Rlabel_set_text(app.clip_gain_readout, &gain_text);
    raven.Rspin_box_set_range(app.clip_fade_in, 0.0, duration);
    raven.Rspin_box_set_value(app.clip_fade_in, fade_in);
    raven.Rspin_box_set_range(app.clip_fade_out, 0.0, duration);
    raven.Rspin_box_set_value(app.clip_fade_out, fade_out);
    raven.Rcheckbox_set_checked(app.clip_mute, muted);
    app.syncing -= 1;
}
