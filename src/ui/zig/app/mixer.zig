//! Translated to Zig from src/ui/raven_app.c lines 4205-4996: arrangement and mixer views, the Mixer popout window, status bar. Seridian Studio window, 1:1 translation.

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

/// <limits.h> PATH_MAX (Linux).
const PATH_MAX = 4096;

pub fn build_arrangement() raven.Rid {
    const row = fns.make_row(10.0);
    const timeline_panel = fns.make_column(8.0);

    const header = fns.make_row(6.0);
    const label = fns.make_label("ARRANGEMENT  ·  drag clips to move, edges to trim", 12.0, &st.muted_text);
    raven.Rslot_set_fill(label, 1.0);
    raven.Rslot_set_valign(label, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(header, label);
    const zoom_out = fns.add_button(header, "−", &fns.on_zoom_out, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(zoom_out, "Zoom out (-)");
    const zoom_in = fns.add_button(header, "+", &fns.on_zoom_in, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(zoom_in, "Zoom in (=)");
    const zoom_fit = fns.add_button(header, "Fit", &fns.on_zoom_fit, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(zoom_fit, "Show the whole arrangement");
    _ = raven.Rwidget_add_child(timeline_panel, header);

    app.empty_hint = fns.make_wrapped_label(
        "No clips in this session yet. Open a saved session folder to load an arrangement.",
        12.0,
        &st.muted_text,
    );
    _ = raven.Rwidget_add_child(timeline_panel, app.empty_hint);
    app.timeline = raven.Rtimeline_create();
    raven.Rtimeline_set_duration(app.timeline, 180.0);
    raven.Rtimeline_set_view(app.timeline, 0.0, st.SERIDIAN_DEFAULT_VIEW_SECONDS);
    raven.Rtimeline_set_time_callback(app.timeline, &fns.on_timeline_time, null);
    raven.Rtimeline_set_changed_callback(app.timeline, &fns.on_clip_changed, null);
    raven.Rtimeline_set_removed_callback(app.timeline, &fns.on_clip_removed, null);
    raven.Rtimeline_set_selection_callback(app.timeline, &fns.on_timeline_selection, null);
    raven.Rslot_set_fill(app.timeline, 1.0);
    _ = raven.Rwidget_add_child(timeline_panel, app.timeline);
    raven.Rslot_set_fill(timeline_panel, 1.0);
    const timeline_frame = fns.make_panel(timeline_panel, 10.0);
    raven.Rslot_set_fill(timeline_frame, 1.0);
    _ = raven.Rwidget_add_child(row, timeline_frame);
    _ = raven.Rwidget_add_child(row, fns.build_inspector());
    raven.Rslot_set_fill(row, 1.0);
    return row;
}

/// Main area: Arrangement and Piano Roll tabs.
pub fn build_main_tabs() raven.Rid {
    app.main_tab_view = raven.Rwidget_create(raven.R_WIDGET_TAB_VIEW);
    _ = raven.Rtab_view_add_tab(app.main_tab_view, "Arrangement", build_arrangement());
    _ = raven.Rtab_view_add_tab(app.main_tab_view, "Piano Roll", fns.build_piano_roll_tab());
    raven.Rtab_view_set_active(app.main_tab_view, st.SERIDIAN_MAIN_TAB_ARRANGEMENT);
    raven.Rslot_set_fill(app.main_tab_view, 1.0);
    return app.main_tab_view;
}

/// Pan knob for a strip. The knob keeps its own value and has no setter, so a pan change made in the other
/// window replaces the knob (see mixer_sync_view).
pub fn make_pan_knob(view: [*c]st.MixerView, track: c_int, pan: f32) raven.Rid {
    const pan_config = ext.SeridianKnobConfig{
        .minimum = -1.0,
        .maximum = 1.0,
        .value = pan,
        .default_value = 0.0,
        .diameter = st.SERIDIAN_PAN_KNOB_DIAMETER,
        .bipolar = 1,
        .on_change = &fns.on_track_pan_knob,
        .user_data = &view.*.bindings[@intCast(track)],
    };
    const knob = ext.seridian_knob_create(&pan_config);
    if (knob != raven.R_INVALID_ID) raven.Rwidget_set_tooltip(knob, "Pan: drag up or down, shift for fine, double-click to centre");
    return knob;
}

pub fn build_track_strip(view: [*c]st.MixerView, i: c_int) raven.Rid {
    const strip = fns.make_column(6.0);
    var bar_rgb = [3]f32{ st.muted_text[0], st.muted_text[1], st.muted_text[2] };
    const color = fns.track_color(i);
    if (color != null) {
        bar_rgb[0] = color.*.color.r;
        bar_rgb[1] = color.*.color.g;
        bar_rgb[2] = color.*.color.b;
    }
    const color_bar = raven.Rwidget_create(raven.R_WIDGET_BORDER);
    raven.Rborder_set_background(color_bar, bar_rgb[0], bar_rgb[1], bar_rgb[2], 1.0);
    raven.Rborder_set_corner_radius(color_bar, 3.0, 3.0, 3.0, 3.0);
    raven.Rwidget_set_size(color_bar, st.SERIDIAN_STRIP_WIDTH - 16.0, 6.0);
    _ = raven.Rwidget_add_child(strip, color_bar);
    view.*.color_bars[@intCast(i)] = color_bar;

    const shown: *st.MixerShown = &view.*.shown[@intCast(i)];
    var fallback_name: [16]u8 = undefined;
    const name = fns.track_display_name(i, &fallback_name, fallback_name.len);
    _ = libc.snprintf(&shown.name, shown.name.len, "%s", name);
    const name_label = fns.make_label(name, 13.0, &st.color_readout);
    raven.Rwidget_set_size(name_label, st.SERIDIAN_STRIP_WIDTH - 16.0, -1.0);
    raven.Rwidget_set_tooltip(name_label, "Right-click to change this track's color");
    view.*.color_menus[@intCast(i)] = fns.build_track_color_menu(view, i);
    raven.Rwidget_set_context_menu(name_label, view.*.color_menus[@intCast(i)]);
    _ = raven.Rwidget_add_child(strip, name_label);
    view.*.name_labels[@intCast(i)] = name_label;

    view.*.bindings[@intCast(i)].track = i;
    view.*.bindings[@intCast(i)].view = view;
    _ = raven.Rwidget_add_child(strip, fns.build_instrument_picker(view, i));
    shown.instrument = fns.instrument_combo_index(i);

    const toggles = fns.make_row(4.0);
    const armed = ext.audio_engine_get_track_arm(app.engine, i);
    const arm = fns.make_fixed_button("R", 28.0, 24.0);
    fns.style_toggle_button(arm, armed, &st.color_record_red);
    raven.Rbutton_set_clicked_callback(arm, &fns.on_track_arm, &view.*.bindings[@intCast(i)]);
    raven.Rwidget_set_tooltip(arm, if (armed != 0) "Armed for recording — click to disarm" else "Arm this track for recording");
    _ = raven.Rwidget_add_child(toggles, arm);
    view.*.arm_buttons[@intCast(i)] = arm;
    shown.armed = armed;

    const muted = ext.audio_engine_get_track_mute(app.engine, i);
    const mute = fns.make_fixed_button("M", 28.0, 24.0);
    fns.style_toggle_button(mute, muted, &st.color_mute_amber);
    raven.Rbutton_set_clicked_callback(mute, &fns.on_track_mute, &view.*.bindings[@intCast(i)]);
    raven.Rwidget_set_tooltip(mute, if (muted != 0) "Track muted — click to unmute" else "Mute this track");
    _ = raven.Rwidget_add_child(toggles, mute);
    view.*.mute_buttons[@intCast(i)] = mute;
    shown.muted = muted;

    const soloed = ext.audio_engine_get_track_solo(app.engine, i);
    const solo = fns.make_fixed_button("S", 28.0, 24.0);
    fns.style_toggle_button(solo, soloed, &st.color_solo_lime);
    raven.Rbutton_set_clicked_callback(solo, &fns.on_track_solo, &view.*.bindings[@intCast(i)]);
    raven.Rwidget_set_tooltip(solo, if (soloed != 0) "Track soloed — click to unsolo" else "Solo this track");
    _ = raven.Rwidget_add_child(toggles, solo);
    view.*.solo_buttons[@intCast(i)] = solo;
    shown.soloed = soloed;
    _ = raven.Rwidget_add_child(strip, toggles);

    const pan_row = fns.make_row(6.0);
    const pan = ext.audio_engine_get_track_pan(app.engine, i);
    view.*.pan_rows[@intCast(i)] = pan_row;
    view.*.pan_knobs[@intCast(i)] = make_pan_knob(view, i, pan);
    _ = raven.Rwidget_add_child(pan_row, view.*.pan_knobs[@intCast(i)]);
    shown.pan = pan;
    var pan_text: [16]u8 = undefined;
    ui_math.ui_format_pan(pan, &pan_text, pan_text.len);
    view.*.bindings[@intCast(i)].pan_readout = fns.make_label(&pan_text, 12.0, &st.muted_text);
    raven.Rwidget_set_size(view.*.bindings[@intCast(i)].pan_readout, 44.0, -1.0);
    raven.Rslot_set_valign(view.*.bindings[@intCast(i)].pan_readout, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(pan_row, view.*.bindings[@intCast(i)].pan_readout);
    _ = raven.Rwidget_add_child(strip, pan_row);

    const fader_row = fns.make_row(4.0);
    _ = raven.Rwidget_add_child(fader_row, fns.make_db_scale());
    const gain_value = ext.audio_engine_get_track_gain(app.engine, i);
    const gain_fader = fns.make_vertical_fader(gain_value, &fns.on_track_gain, &view.*.bindings[@intCast(i)]);
    raven.Rwidget_set_tooltip(gain_fader, "Track volume");
    _ = raven.Rwidget_add_child(fader_row, gain_fader);
    view.*.gain_faders[@intCast(i)] = gain_fader;
    shown.gain = gain_value;
    view.*.track_meters[@intCast(i)] = fns.make_meter(i);
    raven.Rwidget_set_tooltip(view.*.track_meters[@intCast(i)], "Track output level");
    _ = raven.Rwidget_add_child(fader_row, view.*.track_meters[@intCast(i)]);
    _ = raven.Rwidget_add_child(strip, fader_row);

    var gain_text: [24]u8 = undefined;
    ui_math.ui_format_gain(gain_value, &gain_text, gain_text.len);
    view.*.bindings[@intCast(i)].gain_readout = fns.make_label(&gain_text, 12.0, &st.color_readout);
    raven.Rwidget_set_size(view.*.bindings[@intCast(i)].gain_readout, 64.0, -1.0);
    raven.Rwidget_set_tooltip(view.*.bindings[@intCast(i)].gain_readout, "Track volume in dB");
    _ = raven.Rwidget_add_child(strip, fns.make_panel(view.*.bindings[@intCast(i)].gain_readout, 4.0));
    shown.valid = 1;

    return fns.make_panel(strip, 8.0);
}

pub fn build_master_strip(view: [*c]st.MixerView) raven.Rid {
    const strip = fns.make_column(6.0);
    const master_label = fns.make_label("MASTER", 13.0, &st.accent_magenta);
    _ = raven.Rwidget_add_child(strip, master_label);

    const fader_row = fns.make_row(4.0);
    _ = raven.Rwidget_add_child(fader_row, fns.make_db_scale());
    // The docked mixer is built first, at startup: it sets the engine's master gain. A popout reads it.
    if (view == &app.mixers[st.MIXER_VIEW_DOCK]) ext.audio_engine_set_master_gain(app.engine, app.master_gain);
    view.*.master_fader = fns.make_vertical_fader(app.master_gain, &fns.on_master_gain, view);
    raven.Rwidget_set_tooltip(view.*.master_fader, "Master output volume");
    _ = raven.Rwidget_add_child(fader_row, view.*.master_fader);
    view.*.master_shown = app.master_gain;
    view.*.master_shown_valid = 1;
    view.*.master_meter = fns.make_meter(st.SERIDIAN_TRACK_COUNT);
    raven.Rwidget_set_tooltip(view.*.master_meter, "Master output level");
    _ = raven.Rwidget_add_child(fader_row, view.*.master_meter);
    _ = raven.Rwidget_add_child(strip, fader_row);

    var master_text: [24]u8 = undefined;
    ui_math.ui_format_gain(app.master_gain, &master_text, master_text.len);
    view.*.master_gain_readout = fns.make_label(&master_text, 12.0, &st.color_readout);
    raven.Rwidget_set_size(view.*.master_gain_readout, 64.0, -1.0);
    raven.Rwidget_set_tooltip(view.*.master_gain_readout, "Master volume in dB");
    _ = raven.Rwidget_add_child(strip, fns.make_panel(view.*.master_gain_readout, 4.0));
    return fns.make_panel(strip, 8.0);
}

/// Brings one view's widgets in line with the engine. The engine is the source of truth, so an edit in either
/// window (or from the CLI, MIDI or a loaded session) shows up in both. Only what changed is touched.
pub fn mixer_sync_view(view: [*c]st.MixerView) void {
    if (view.*.root == raven.R_INVALID_ID) return;
    st.mixer_syncing += 1;
    var i: c_int = 0;
    while (i < st.SERIDIAN_TRACK_COUNT) : (i += 1) {
        const shown: *st.MixerShown = &view.*.shown[@intCast(i)];
        if (view.*.name_labels[@intCast(i)] == raven.R_INVALID_ID) continue;

        var fallback_name: [16]u8 = undefined;
        const name = fns.track_display_name(i, &fallback_name, fallback_name.len);
        if (libc.strcmp(&shown.name, name) != 0) {
            _ = libc.snprintf(&shown.name, shown.name.len, "%s", name);
            raven.Rlabel_set_text(view.*.name_labels[@intCast(i)], &shown.name);
        }

        const armed: c_int = if (ext.audio_engine_get_track_arm(app.engine, i) != 0) 1 else 0;
        if (armed != shown.armed) {
            shown.armed = armed;
            fns.style_toggle_button(view.*.arm_buttons[@intCast(i)], armed, &st.color_record_red);
            raven.Rwidget_set_tooltip(view.*.arm_buttons[@intCast(i)], if (armed != 0) "Armed for recording — click to disarm" else "Arm this track for recording");
        }
        const muted: c_int = if (ext.audio_engine_get_track_mute(app.engine, i) != 0) 1 else 0;
        if (muted != shown.muted) {
            shown.muted = muted;
            fns.style_toggle_button(view.*.mute_buttons[@intCast(i)], muted, &st.color_mute_amber);
            raven.Rwidget_set_tooltip(view.*.mute_buttons[@intCast(i)], if (muted != 0) "Track muted — click to unmute" else "Mute this track");
        }
        const soloed: c_int = if (ext.audio_engine_get_track_solo(app.engine, i) != 0) 1 else 0;
        if (soloed != shown.soloed) {
            shown.soloed = soloed;
            fns.style_toggle_button(view.*.solo_buttons[@intCast(i)], soloed, &st.color_solo_lime);
            raven.Rwidget_set_tooltip(view.*.solo_buttons[@intCast(i)], if (soloed != 0) "Track soloed — click to unsolo" else "Solo this track");
        }

        const instrument = fns.instrument_combo_index(i);
        if (instrument != shown.instrument) {
            shown.instrument = instrument;
            raven.Rcombo_box_set_selected(view.*.instrument_combos[@intCast(i)], instrument);
        }

        const gain = ext.audio_engine_get_track_gain(app.engine, i);
        if (gain != shown.gain) {
            shown.gain = gain;
            raven.Rslider_set_value(view.*.gain_faders[@intCast(i)], gain);
            var text: [24]u8 = undefined;
            ui_math.ui_format_gain(gain, &text, text.len);
            raven.Rlabel_set_text(view.*.bindings[@intCast(i)].gain_readout, &text);
        }

        const pan = ext.audio_engine_get_track_pan(app.engine, i);
        if (@abs(pan - shown.pan) > st.MIXER_PAN_EPSILON) {
            shown.pan = pan;
            const knob = make_pan_knob(view, i, pan);
            if (knob != raven.R_INVALID_ID) {
                const old = view.*.pan_knobs[@intCast(i)];
                raven.Rwidget_remove_child(view.*.pan_rows[@intCast(i)], old);
                raven.Rwidget_destroy(old);
                _ = raven.Rwidget_insert_child(view.*.pan_rows[@intCast(i)], knob, 0);
                view.*.pan_knobs[@intCast(i)] = knob;
            }
            var text: [16]u8 = undefined;
            ui_math.ui_format_pan(pan, &text, text.len);
            raven.Rlabel_set_text(view.*.bindings[@intCast(i)].pan_readout, &text);
        }
    }
    if (view.*.master_shown_valid != 0 and app.master_gain != view.*.master_shown) {
        view.*.master_shown = app.master_gain;
        raven.Rslider_set_value(view.*.master_fader, app.master_gain);
        var text: [24]u8 = undefined;
        ui_math.ui_format_gain(app.master_gain, &text, text.len);
        raven.Rlabel_set_text(view.*.master_gain_readout, &text);
    }
    st.mixer_syncing -= 1;
}

pub fn mixer_sync_all() void {
    var view: c_int = 0;
    while (view < st.MIXER_VIEW_COUNT) : (view += 1) mixer_sync_view(&app.mixers[@intCast(view)]);
}

pub fn on_mixer_menu_toggle(item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = item;
    _ = user_data;
    if (app.mixers[st.MIXER_VIEW_POPOUT].window != raven.R_INVALID_ID) {
        app.mixer_dock_requested = 1; // closed by the main loop
    } else mixer_popout_toggle();
}

/// The header button: pops the Mixer out, or docks it back. Inside the Mixer window the close is deferred.
pub fn on_mixer_toggle_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    on_mixer_menu_toggle(raven.R_INVALID_ID, null);
}

/// Header row of a mixer: the title and a menu that pops the Mixer out or docks it back.
pub fn build_mixer_header(view: [*c]st.MixerView) raven.Rid {
    const header = fns.make_row(6.0);
    const title = fns.make_label("MIXER", 12.0, &st.muted_text);
    raven.Rslot_set_fill(title, 1.0);
    raven.Rslot_set_valign(title, raven.R_VALIGN_CENTER);
    _ = raven.Rwidget_add_child(header, title);
    view.*.menu = raven.Rwidget_create(raven.R_WIDGET_MENU);
    view.*.menu_item = raven.Rmenu_add_item(view.*.menu, if (view.*.window == app.window) "Pop out Mixer (Ctrl+Shift+M)" else "Dock Mixer (Ctrl+Shift+M)");
    raven.Rmenu_item_set_clicked_callback(view.*.menu_item, &on_mixer_menu_toggle, null);
    view.*.header_title = title;
    raven.Rwidget_set_context_menu(title, view.*.menu);
    view.*.toggle_button = fns.add_button(header, "Pop out", &on_mixer_toggle_button, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(view.*.toggle_button, "Open the mixer in its own window (Ctrl+Shift+M)");
    popout_buttons_sync();
    return header;
}

/// One mixer: header, the track strips and the master strip. `window` is the window that will show it.
pub fn build_mixer_panel(view: [*c]st.MixerView, window: raven.Rid) raven.Rid {
    const stack = fns.make_column(8.0);
    view.*.window = window;
    _ = raven.Rwidget_add_child(stack, build_mixer_header(view));
    const channels = fns.make_row(8.0);
    var i: c_int = 0;
    while (i < st.SERIDIAN_TRACK_COUNT) : (i += 1) {
        _ = raven.Rwidget_add_child(channels, build_track_strip(view, i));
    }
    _ = raven.Rwidget_add_child(channels, build_master_strip(view));
    _ = raven.Rwidget_add_child(stack, channels);
    const panel = fns.make_panel(stack, 12.0);
    view.*.root = panel;
    return panel;
}

pub fn build_track_mixer() raven.Rid {
    return build_mixer_panel(&app.mixers[st.MIXER_VIEW_DOCK], app.window);
}

// ---- Mixer popout ----------------------------------------------------------

/// Marks every widget of a view as absent (the view is zeroed, then the ids are invalidated).
pub fn mixer_view_init(view: [*c]st.MixerView) void {
    view.* = std.mem.zeroes(st.MixerView);
    view.*.window = raven.R_INVALID_ID;
    view.*.root = raven.R_INVALID_ID;
    view.*.menu = raven.R_INVALID_ID;
    view.*.menu_item = raven.R_INVALID_ID;
    view.*.toggle_button = raven.R_INVALID_ID;
    view.*.header_title = raven.R_INVALID_ID;
    view.*.master_fader = raven.R_INVALID_ID;
    view.*.master_meter = raven.R_INVALID_ID;
    view.*.master_gain_readout = raven.R_INVALID_ID;
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        view.*.color_menus[@intCast(track)] = raven.R_INVALID_ID;
        view.*.pan_rows[@intCast(track)] = raven.R_INVALID_ID;
        view.*.name_labels[@intCast(track)] = raven.R_INVALID_ID;
        view.*.color_bars[@intCast(track)] = raven.R_INVALID_ID;
        view.*.instrument_combos[@intCast(track)] = raven.R_INVALID_ID;
        view.*.arm_buttons[@intCast(track)] = raven.R_INVALID_ID;
        view.*.mute_buttons[@intCast(track)] = raven.R_INVALID_ID;
        view.*.solo_buttons[@intCast(track)] = raven.R_INVALID_ID;
        view.*.pan_knobs[@intCast(track)] = raven.R_INVALID_ID;
        view.*.gain_faders[@intCast(track)] = raven.R_INVALID_ID;
        view.*.track_meters[@intCast(track)] = raven.R_INVALID_ID;
    }
}

pub fn mixer_popout_is_open() c_int {
    return @intFromBool(app.mixers[st.MIXER_VIEW_POPOUT].window != raven.R_INVALID_ID);
}

/// Keeps the "Pop out" / "Dock" labels of the Piano Roll toolbar and of both mixer headers in step with the popouts.
pub fn popout_buttons_sync() void {
    const roll_out: c_int = @intFromBool(app.popout_window != raven.R_INVALID_ID);
    if (app.popout_toggle_button != raven.R_INVALID_ID) raven.Rbutton_set_text(app.popout_toggle_button, if (roll_out != 0) "Dock" else "Pop out");
    const mixer_out = mixer_popout_is_open();
    var i: c_int = 0;
    while (i < st.MIXER_VIEW_COUNT) : (i += 1) {
        const view: *st.MixerView = &app.mixers[@intCast(i)];
        if (view.toggle_button != raven.R_INVALID_ID) raven.Rbutton_set_text(view.toggle_button, if (mixer_out != 0) "Dock" else "Pop out");
        if (view.menu_item != raven.R_INVALID_ID) {
            raven.Rmenu_item_set_text(view.menu_item, if (mixer_out != 0) "Dock Mixer (Ctrl+Shift+M)" else "Pop out Mixer (Ctrl+Shift+M)");
        }
    }
}

pub fn mixer_read_geometry(x: [*c]c_int, y: [*c]c_int, width: [*c]c_int, height: [*c]c_int) void {
    const window = app.mixers[st.MIXER_VIEW_POPOUT].window;
    raven.Rwindow_get_position(window, x, y);
    raven.Rwindow_get_size(window, width, height);
}

/// Appends one line per placement attempt to the same log as the Piano Roll popout.
pub fn mixer_log_place(outcome: [*c]const u8) void {
    const dir: [*c]const u8 = libc.getenv("XDG_RUNTIME_DIR");
    var path: [PATH_MAX]u8 = undefined;
    if (libc.snprintf(&path, path.len, "%s/seridian-popout.log", @as([*c]const u8, if (dir != null and dir[0] != 0) dir else "/tmp")) >= @as(c_int, path.len)) return;
    const log = libc.fopen(&path, "a");
    if (log == null) return;
    _ = libc.fprintf(log.?, "%ld mixer place monitor=\"%s\" argv=[%s] result=%s\n", @as(c_long, libc.time(null)), @as([*c]const u8, &app.mixer_place_monitor), @as([*c]const u8, &app.mixer_place_argv), outcome);
    _ = libc.fclose(log.?);
}

/// Starts `seridian wm size "Mixer" <w> <h> --pid <own pid>` (Hyprland, sway) or `wm place` (X11) detached.
pub fn mixer_spawn_place() c_int {
    var path: [PATH_MAX]u8 = undefined;
    var dx: [16]u8 = undefined;
    var dy: [16]u8 = undefined;
    var width: [16]u8 = undefined;
    var height: [16]u8 = undefined;
    _ = libc.snprintf(&dx, dx.len, "%d", app.mixer_place_dx);
    _ = libc.snprintf(&dy, dy.len, "%d", app.mixer_place_dy);
    _ = libc.snprintf(&width, width.len, "%d", app.mixer_place_w);
    _ = libc.snprintf(&height, height.len, "%d", app.mixer_place_h);
    const size_only = app.mixer_place_size_only;
    if (fns.seridian_helper_path(&path, path.len) == 0) {
        _ = libc.snprintf(&app.mixer_place_argv, app.mixer_place_argv.len, "seridian wm %s (helper not found)", @as([*c]const u8, if (size_only != 0) "size" else "place"));
        mixer_log_place("not started: helper missing");
        return 0;
    }
    // Only this app's own window may match: another instance has a Mixer window with the same title.
    var owner: [16]u8 = undefined;
    _ = libc.snprintf(&owner, owner.len, "%ld", @as(c_long, libc.getpid()));
    const place_argv = [_][*c]u8{
        &path,  @constCast("wm"), @constCast("place"), @constCast(st.MIXER_POPOUT_TITLE), &app.mixer_place_monitor,
        &dx,    &dy,              &width,              &height,                           @constCast("--pid"),
        &owner, null,
    };
    const size_argv = [_][*c]u8{ &path, @constCast("wm"), @constCast("size"), @constCast(st.MIXER_POPOUT_TITLE), &width, &height, @constCast("--pid"), &owner, null };
    const argv: [*c]const [*c]u8 = if (size_only != 0) &size_argv else &place_argv;
    if (size_only != 0) {
        _ = libc.snprintf(&app.mixer_place_argv, app.mixer_place_argv.len, "%s wm size \"%s\" %s %s --pid %s", @as([*c]const u8, &path), @as([*c]const u8, st.MIXER_POPOUT_TITLE), @as([*c]const u8, &width), @as([*c]const u8, &height), @as([*c]const u8, &owner));
    } else {
        _ = libc.snprintf(&app.mixer_place_argv, app.mixer_place_argv.len, "%s wm place \"%s\" \"%s\" %s %s %s %s --pid %s", @as([*c]const u8, &path), @as([*c]const u8, st.MIXER_POPOUT_TITLE), @as([*c]const u8, &app.mixer_place_monitor), @as([*c]const u8, &dx), @as([*c]const u8, &dy), @as([*c]const u8, &width), @as([*c]const u8, &height), @as([*c]const u8, &owner));
    }
    const pid = libc.fork();
    if (pid < 0) {
        mixer_log_place("not started: fork failed");
        return 0;
    }
    if (pid == 0) fns.helper_exec_child(&path, argv, -1);
    app.mixer_place_pid = pid;
    return 1;
}

/// The deferred step: runs when the Mixer window reports focus (it is mapped) or after POPOUT_PLACE_TIMEOUT_FRAMES.
pub fn mixer_place_now() void {
    if (app.mixer_place_pending == 0) return;
    app.mixer_place_pending = 0;
    app.mixer_seen_valid = 0; // re-learn the geometry the window manager settles on
    _ = mixer_spawn_place();
}

pub fn mixer_reap_place() void {
    if (app.mixer_place_pid <= 0) return;
    var status: c_int = 0;
    var reaped: libc.pid_t = undefined;
    while (true) {
        reaped = libc.waitpid(app.mixer_place_pid, &status, libc.WNOHANG);
        if (!(reaped < 0 and libc.errno() == libc.EINTR)) break;
    }
    if (reaped == 0) return;
    app.mixer_place_pid = 0;
    if (reaped < 0) {
        mixer_log_place("lost: waitpid failed");
        return;
    }
    var what: [48]u8 = undefined;
    fns.popout_describe_status(status, &what, what.len);
    mixer_log_place(&what);
}

/// Close and quit: the child must not outlive the window. A child still running is killed, then reaped.
pub fn mixer_reap_place_final() void {
    if (app.mixer_place_pid <= 0) return;
    mixer_reap_place();
    if (app.mixer_place_pid <= 0) return;
    const pid = app.mixer_place_pid;
    _ = libc.kill(pid, libc.SIGKILL);
    var status: c_int = 0;
    var reaped: libc.pid_t = undefined;
    while (true) {
        reaped = libc.waitpid(pid, &status, 0);
        if (!(reaped < 0 and libc.errno() == libc.EINTR)) break;
    }
    app.mixer_place_pid = 0;
    mixer_log_place(if (reaped == pid) "killed: Mixer closed before it finished" else "lost: waitpid failed");
}

/// Writes mixerpopout.conf with the live geometry; `open` says whether the window should return on the next launch.
/// A window still waiting to be placed, or never moved or resized by the user, is not saved.
pub fn mixer_save_state(open: c_int) void {
    if (app.mixer_place_pending != 0 or app.mixer_user_placed == 0) return;
    var x: c_int = 0;
    var y: c_int = 0;
    var width: c_int = st.MIXER_POPOUT_DEFAULT_WIDTH;
    var height: c_int = st.MIXER_POPOUT_DEFAULT_HEIGHT;
    const window = app.mixers[st.MIXER_VIEW_POPOUT].window;
    if (window != raven.R_INVALID_ID and raven.Rwindow_is_valid(window) != 0) mixer_read_geometry(&x, &y, &width, &height);
    var monitor: [st.POPOUT_MONITOR_NAME_CAPACITY]u8 = undefined;
    var origin_x: c_int = 0;
    var origin_y: c_int = 0;
    fns.popout_query_monitors();
    const located: c_int = @intFromBool(app.wm_monitors_len > 0 and
        ext.seridian_popout_locate(&app.wm_monitors, app.wm_monitors_len, x + @divTrunc(width, 2), y + @divTrunc(height, 2), &monitor, monitor.len, &origin_x, &origin_y) == 1);
    if (ext.seridian_mixer_popout_save(open, x, y, width, height, if (located != 0) &monitor else null, x - origin_x, y - origin_y) != 0) {
        fns.set_status("Could not save the Mixer window position");
    }
}

/// Marks the window open or closed in mixerpopout.conf while keeping the stored geometry. With no stored geometry
/// and an open window, the default size is stored so that the window still comes back.
pub fn mixer_save_keep_position(open: c_int) void {
    var x: c_int = 0;
    var y: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    var dx: c_int = 0;
    var dy: c_int = 0;
    var monitor: [st.POPOUT_MONITOR_NAME_CAPACITY]u8 = undefined;
    monitor[0] = 0;
    // No valid stored geometry (absent, or a file saved as docked): keep the file as it is. Writing defaults
    // here would overwrite a real docked position. The popout records its position once the user has placed it.
    if (ext.seridian_mixer_popout_load(&x, &y, &width, &height, &monitor, monitor.len, &dx, &dy) != 1) return;
    if (ext.seridian_mixer_popout_save(open, x, y, width, height, if (monitor[0] != 0) &monitor else null, dx, dy) != 0)
        fns.set_status("Could not save the Mixer window position");
}

pub fn mixer_save_on_leave(open: c_int) void {
    if (app.mixer_user_placed != 0 and app.mixer_place_pending == 0) {
        mixer_save_state(open);
    } else mixer_save_keep_position(open);
}

/// The Mixer window is gone (closed, or destroyed by Raven): drop its widgets and show the docked panel again.
pub fn mixer_release_menus(view: [*c]st.MixerView) void {
    if (view.*.window != raven.R_INVALID_ID and raven.Rwindow_is_valid(view.*.window) != 0) raven.Rwindow_close_popups(view.*.window);
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
        const label = view.*.name_labels[@intCast(track)];
        if (label != raven.R_INVALID_ID and raven.Rwidget_is_valid(label) != 0) raven.Rwidget_set_context_menu(label, raven.R_INVALID_ID);
        const menu = view.*.color_menus[@intCast(track)];
        if (menu != raven.R_INVALID_ID and raven.Rwidget_is_valid(menu) != 0) raven.Rwidget_destroy(menu);
        view.*.color_menus[@intCast(track)] = raven.R_INVALID_ID;
    }
    if (view.*.menu != raven.R_INVALID_ID) {
        if (view.*.header_title != raven.R_INVALID_ID and raven.Rwidget_is_valid(view.*.header_title) != 0)
            raven.Rwidget_set_context_menu(view.*.header_title, raven.R_INVALID_ID);
        if (raven.Rwidget_is_valid(view.*.menu) != 0) raven.Rwidget_destroy(view.*.menu);
        view.*.menu = raven.R_INVALID_ID;
        view.*.menu_item = raven.R_INVALID_ID;
    }
}

pub fn mixer_forget_window() void {
    const popout: *st.MixerView = &app.mixers[st.MIXER_VIEW_POPOUT];
    mixer_release_menus(popout);
    var track: c_int = 0;
    while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) popout.bindings[@intCast(track)].view = null;
    mixer_view_init(&app.mixers[st.MIXER_VIEW_POPOUT]);
    app.mixer_place_pending = 0;
    app.mixer_dock_requested = 0;
    const dock_root = app.mixers[st.MIXER_VIEW_DOCK].root;
    if (dock_root != raven.R_INVALID_ID) raven.Rwidget_set_visibility(dock_root, raven.R_VISIBLE);
    popout_buttons_sync();
}

/// The app is quitting with the Mixer window open: remember it as open, then destroy the window without docking.
pub fn mixer_popout_save_on_quit() void {
    mixer_save_on_leave(1);
    app.mixer_place_pending = 0;
    mixer_reap_place_final();
    const window = app.mixers[st.MIXER_VIEW_POPOUT].window;
    mixer_forget_window();
    if (window != raven.R_INVALID_ID) raven.Rwindow_destroy(window);
}

/// Every frame: keeps the Mixer widgets in line with the engine, forgets a window that is gone, closes it when asked
/// to dock, runs the deferred placement and watches the geometry for a user move or resize.
pub fn mixer_popout_poll() void {
    mixer_sync_all();
    const window = app.mixers[st.MIXER_VIEW_POPOUT].window;
    if (window == raven.R_INVALID_ID) {
        mixer_reap_place_final();
        return;
    }
    mixer_reap_place();
    if (raven.Rwindow_is_valid(window) == 0) {
        mixer_reap_place_final();
        mixer_forget_window();
        return;
    }
    if (app.mixer_dock_requested != 0) {
        app.mixer_dock_requested = 0;
        raven.Rwindow_close(window);
        return;
    }
    if (app.mixer_place_pending != 0) {
        app.mixer_place_frames += 1;
        if (app.mixer_place_frames >= st.POPOUT_PLACE_TIMEOUT_FRAMES) mixer_place_now();
        return;
    }
    var current: [4]c_int = undefined;
    mixer_read_geometry(&current[0], &current[1], &current[2], &current[3]);
    if (app.mixer_place_pid > 0) {
        app.mixer_seen_valid = 0;
        app.mixer_stable_frames = 0;
        return;
    }
    if (libc.memcmp(&app.mixer_seen, &current, @sizeOf(@TypeOf(current))) != 0) {
        if (app.mixer_seen_valid != 0) app.mixer_user_placed = 1;
        @memcpy(&app.mixer_seen, &current);
        app.mixer_stable_frames = 0;
    } else if (app.mixer_seen_valid == 0) {
        // C: `else if (!app.mixer_seen_valid && ++app.mixer_stable_frames >= POPOUT_SAVE_SETTLE_FRAMES)`
        app.mixer_stable_frames += 1;
        if (app.mixer_stable_frames >= st.POPOUT_SAVE_SETTLE_FRAMES) app.mixer_seen_valid = 1;
    }
}

/// A user resize, once the window has settled (not the first map, not the placement helper's own resize).
pub fn mixer_on_resize(window: raven.Rid, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (app.closing != 0 or window != app.mixers[st.MIXER_VIEW_POPOUT].window) return;
    if (app.mixer_place_pending != 0 or app.mixer_place_pid > 0 or app.mixer_seen_valid == 0) return;
    if (width != app.mixer_seen[2] or height != app.mixer_seen[3]) app.mixer_user_placed = 1;
}

/// The user closed the Mixer window: dock the mixer back into the main window. Raven destroys the window.
pub fn mixer_on_close(window: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    if (app.closing != 0) return raven.R_TRUE; // quitting: mixerpopout.conf keeps "open" so it returns next launch
    mixer_save_on_leave(0);
    mixer_reap_place_final();
    mixer_forget_window();
    fns.set_status("Mixer docked");
    return raven.R_TRUE;
}

/// Keyboard and pointer of the Mixer window: its own hook, so the main window's shortcuts never see these events.
pub fn mixer_event_hook(window: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data;
    if (event == null) return raven.R_FALSE;
    switch (event.*.type) {
        raven.R_EVENT_KEY_DOWN => {
            if (raven.Rwindow_wants_text_input(window) != 0) return raven.R_FALSE;
            const action: ext.SeridianAction = ext.seridian_keymap_lookup(@bitCast(event.*.key), event.*.modifiers);
            switch (action) {
                ext.SERIDIAN_ACTION_PLAY_STOP,
                ext.SERIDIAN_ACTION_STOP_AND_REWIND,
                ext.SERIDIAN_ACTION_UNDO,
                ext.SERIDIAN_ACTION_REDO,
                ext.SERIDIAN_ACTION_FILE_SAVE,
                ext.SERIDIAN_ACTION_POPOUT_PIANO_ROLL,
                => {
                    if (event.*.repeat == 0) fns.run_action_for(action, 1);
                    return raven.R_TRUE;
                },
                ext.SERIDIAN_ACTION_POPOUT_MIXER => {
                    app.mixer_dock_requested = 1; // closing the window from inside its own event is deferred
                    return raven.R_TRUE;
                },
                else => return raven.R_FALSE,
            }
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            const view: *const st.MixerView = &app.mixers[st.MIXER_VIEW_POPOUT];
            var track: c_int = 0;
            while (track < st.SERIDIAN_TRACK_COUNT) : (track += 1) {
                if (fns.point_in_widget(view.name_labels[@intCast(track)], event.*.x, event.*.y) != 0 or
                    fns.point_in_widget(view.color_bars[@intCast(track)], event.*.x, event.*.y) != 0)
                {
                    fns.select_track(track);
                    break;
                }
            }
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_MOVE, raven.R_EVENT_MOUSE_UP => {
            // A knob drag started here is followed by the shared window handler (knob.zig); it only
            // listens to the main window's events, so the Mixer window passes its moves and releases on.
            return if (window_input.seridian_window_input_dispatch(@ptrCast(event)) != 0) raven.R_TRUE else raven.R_FALSE;
        },
        raven.R_EVENT_FOCUS_GAINED => {
            mixer_place_now(); // the window is mapped
            return raven.R_FALSE;
        },
        else => return raven.R_FALSE,
    }
}

/// Opens the Mixer window. With `restore`, the saved size (and, on X11, position) is used.
/// (C assigns to x, y, width and height: the parameters carry a trailing `_` and are copied to locals.)
pub fn mixer_popout_open(restore: c_int, x_: c_int, y_: c_int, width_: c_int, height_: c_int, saved_monitor: [*c]const u8, saved_dx: c_int, saved_dy: c_int) void {
    var x = x_;
    var y = y_;
    var width = width_;
    var height = height_;
    if (mixer_popout_is_open() != 0) return;

    fns.popout_query_monitors();
    app.mixer_place_pending = 0;
    app.mixer_place_size_only = 0;
    app.mixer_place_monitor[0] = 0;
    mixer_reap_place_final();
    app.mixer_seen_valid = 0;
    app.mixer_user_placed = 0;
    @memset(&app.mixer_seen, 0);
    app.mixer_stable_frames = 0;
    if (restore != 0) {
        var wx: c_int = 0;
        var wy: c_int = 0;
        var ww: c_int = 0;
        var wh: c_int = 0;
        raven.Rwindow_get_position(app.window, &wx, &wy);
        raven.Rwindow_get_size(app.window, &ww, &wh);
        const main_cx = wx + @divTrunc(ww, 2);
        const main_cy = wy + @divTrunc(wh, 2);
        const saved_x = x;
        const saved_y = y;
        if (ext.seridian_popout_restore(&x, &y, &width, &height, main_cx, main_cy) < 0) {
            width = st.MIXER_POPOUT_DEFAULT_WIDTH;
            height = st.MIXER_POPOUT_DEFAULT_HEIGHT;
        }
        // Hyprland and sway place the window themselves, and the app's coordinates (XWayland) do not match the
        // compositor's monitor list: restore the size only, through `seridian wm size --pid`. A failed detect
        // takes the same path. Only X11 restores the position too.
        var backend: [32]u8 = undefined;
        const detected = fns.popout_detect_backend(&backend, backend.len);
        const size_only: c_int = @intFromBool(detected == 0 or libc.strcmp(&backend, "hyprland") == 0 or libc.strcmp(&backend, "sway") == 0);
        fns.popout_log_restore_path(if (size_only != 0) "size-only" else "position", if (detected != 0) &backend else "detect-failed");
        if (size_only != 0) {
            app.mixer_place_w = width;
            app.mixer_place_h = height;
            app.mixer_place_dx = 0;
            app.mixer_place_dy = 0;
            app.mixer_place_frames = 0;
            app.mixer_place_size_only = 1;
            app.mixer_place_pending = 1;
        } else if (app.wm_monitors_len != 0) {
            var dx = saved_dx;
            var dy = saved_dy;
            const planned = ext.seridian_popout_plan(&app.wm_monitors, app.wm_monitors_len, saved_monitor, saved_x, saved_y, saved_dx, saved_dy, main_cx, main_cy, &app.mixer_place_monitor, app.mixer_place_monitor.len, &dx, &dy, &width, &height);
            if (planned == 1 or planned == 2) {
                app.mixer_place_dx = dx;
                app.mixer_place_dy = dy;
                app.mixer_place_w = width;
                app.mixer_place_h = height;
                app.mixer_place_frames = 0;
                app.mixer_place_pending = 1;
            }
        }
    } else {
        width = st.MIXER_POPOUT_DEFAULT_WIDTH;
        height = st.MIXER_POPOUT_DEFAULT_HEIGHT;
        // No stored size: Hyprland and sway still float and size the window through `seridian wm size`.
        var backend: [32]u8 = undefined;
        const detected = fns.popout_detect_backend(&backend, backend.len);
        if (detected != 0 and (libc.strcmp(&backend, "hyprland") == 0 or libc.strcmp(&backend, "sway") == 0)) {
            fns.popout_log_restore_path("size-only", &backend);
            app.mixer_place_w = width;
            app.mixer_place_h = height;
            app.mixer_place_dx = 0;
            app.mixer_place_dy = 0;
            app.mixer_place_frames = 0;
            app.mixer_place_size_only = 1;
            app.mixer_place_pending = 1;
        }
    }

    const window = raven.Rwindow_create(st.MIXER_POPOUT_TITLE, width, height, raven.R_WINDOW_DEFAULT);
    if (window == raven.R_INVALID_ID) {
        app.mixer_place_pending = 0;
        fns.set_status("Could not open the Mixer window");
        return;
    }
    mixer_view_init(&app.mixers[st.MIXER_VIEW_POPOUT]);
    const panel = build_mixer_panel(&app.mixers[st.MIXER_VIEW_POPOUT], window);
    const column = fns.make_column(10.0);
    raven.Rslot_set_padding(column, 14.0, 12.0, 14.0, 10.0);
    raven.Rslot_set_fill(panel, 1.0);
    _ = raven.Rwidget_add_child(column, panel);
    raven.Rwindow_set_content(window, column);
    raven.Rwindow_set_clear_color(window, 0.020, 0.024, 0.051, 1.0);
    raven.Rwindow_set_min_size(window, st.MIXER_POPOUT_MIN_WIDTH, st.MIXER_POPOUT_MIN_HEIGHT);
    raven.Rwindow_set_close_callback(window, &mixer_on_close, null);
    raven.Rwindow_set_resize_callback(window, &mixer_on_resize, null);
    raven.Rwindow_set_event_hook(window, &mixer_event_hook, null);
    app.mixer_dock_requested = 0;
    raven.Rwindow_show(window);

    // The strips now live in the Mixer window: the docked panel gives its room back to the arrangement.
    const dock_root = app.mixers[st.MIXER_VIEW_DOCK].root;
    if (dock_root != raven.R_INVALID_ID) raven.Rwidget_set_visibility(dock_root, raven.R_COLLAPSED);
    popout_buttons_sync();
    fns.set_status("Mixer popped out");
}

/// Ctrl+Shift+M: pops the Mixer out, or docks it back when it is already out.
pub fn mixer_popout_toggle() void {
    if (mixer_popout_is_open() != 0) {
        raven.Rwindow_close(app.mixers[st.MIXER_VIEW_POPOUT].window);
        return;
    }
    mixer_popout_open(0, 0, 0, 0, 0, null, 0, 0);
}

/// Reopens the Mixer window at startup when mixerpopout.conf says it was open. A missing or invalid file opens nothing.
pub fn mixer_popout_restore() void {
    var x: c_int = 0;
    var y: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    var dx: c_int = 0;
    var dy: c_int = 0;
    var monitor: [st.POPOUT_MONITOR_NAME_CAPACITY]u8 = undefined;
    monitor[0] = 0;
    if (ext.seridian_mixer_popout_load(&x, &y, &width, &height, &monitor, monitor.len, &dx, &dy) != 1) return;
    mixer_popout_open(1, x, y, width, height, &monitor, dx, dy);
}

pub fn build_status_bar() raven.Rid {
    const row = fns.make_row(8.0);
    var hint: [256]u8 = undefined;
    // Rendered from the keymap table, so it cannot drift from the real bindings.
    if (ext.seridian_keymap_hint(&hint, hint.len) < 0) hint[0] = 0;
    app.status_label = fns.make_label(&hint, 12.0, &st.muted_text);
    raven.Rslot_set_fill(app.status_label, 1.0);
    _ = raven.Rwidget_add_child(row, app.status_label);
    const brand = fns.make_label("SERIDIAN.DEV", 12.0, &st.accent_cyan);
    _ = raven.Rwidget_add_child(row, brand);
    return row;
}
