// Translated to Zig from vendor/raven/tools/designer/accessibility.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven IDE - accessibility.c
// View > Accessibility: every accessibility setting of Raven, live, in a
// window of its own. It is also a showcase: what any application built with
// Raven offers its users without writing a line for it.
//
//   text size              Raccessibility_set_text_scale
//   interface size         Rset_ui_scale
//   high contrast          Raccessibility_set_high_contrast
//   color filters          Raccessibility_set_color_filter (corrections and simulations)
//   focus ring             Raccessibility_set_focus_always_visible
//   reduce motion          Raccessibility_set_reduce_motion
//   animation speed        Rset_animation_speed
//   screen readers         Raccessibility_is_screen_reader_active, Raccessibility_announce
//   the system             Raccessibility_get_system_settings, Raccessibility_follow_system
//
// The settings are kept in ide.ini (a11y.*) and applied again at the next
// start. View > Reduce motion switches the one most asked for from the menu.

const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

// <stdlib.h>
extern "c" fn atof(nptr: [*c]const u8) f64;

const g_filters = [_]extern struct { name: [*c]const u8, filter: raven.RColorFilter }{
    .{ .name = "None", .filter = raven.R_COLOR_FILTER_NONE },
    .{ .name = "Protanopia (red is weak)", .filter = raven.R_COLOR_FILTER_PROTANOPIA },
    .{ .name = "Deuteranopia (green is weak)", .filter = raven.R_COLOR_FILTER_DEUTERANOPIA },
    .{ .name = "Tritanopia (blue is weak)", .filter = raven.R_COLOR_FILTER_TRITANOPIA },
    .{ .name = "Grayscale", .filter = raven.R_COLOR_FILTER_GRAYSCALE },
    .{ .name = "Inverted colors", .filter = raven.R_COLOR_FILTER_INVERT },
    .{ .name = "Simulate protanopia", .filter = raven.R_COLOR_FILTER_SIMULATE_PROTANOPIA },
    .{ .name = "Simulate deuteranopia", .filter = raven.R_COLOR_FILTER_SIMULATE_DEUTERANOPIA },
    .{ .name = "Simulate tritanopia", .filter = raven.R_COLOR_FILTER_SIMULATE_TRITANOPIA },
    .{ .name = "Simulate achromatopsia", .filter = raven.R_COLOR_FILTER_SIMULATE_ACHROMATOPSIA },
};
const FILTER_COUNT: c_int = @intCast(g_filters.len);

const A11Y_XML = "<Window Title=\"Accessibility\" Width=\"520\" Height=\"640\" MinWidth=\"420\" MinHeight=\"360\">" ++
    "<ScrollBox>" ++
    "  <VBox Spacing=\"14\" Slot.Padding=\"22\">" ++
    "    <Label Text=\"Accessibility\" TextSize=\"22\" AccessibleRole=\"Heading\"/>" ++
    "    <Label Text=\"What every application made with Raven offers its users, with nothing to write: the settings apply at once, to every window. The IDE keeps them for the next time.\" Wrap=\"true\" Opacity=\"0.65\"/>" ++
    "    <Label Text=\"Sight\" TextSize=\"16\" AccessibleRole=\"Heading\"/>" ++
    "    <Grid Columns=\"0,1\" Spacing=\"12\">" ++
    "      <Label Width=\"150\" Name=\"text.label\" Text=\"Text size\" Slot.VAlign=\"Center\"/>" ++
    "      <HBox Spacing=\"10\" Slot.Column=\"1\"><Slider Name=\"text\" Min=\"0.75\" Max=\"2\" Step=\"0.05\" Slot.Fill=\"1\" AccessibleName=\"Text size\"/><Label Name=\"text.value\" Width=\"52\" Slot.VAlign=\"Center\"/></HBox>" ++
    "      <Label Width=\"150\" Text=\"Interface size\" Slot.Row=\"1\" Slot.VAlign=\"Center\" Tooltip=\"Everything grows: texts, controls, spaces\"/>" ++
    "      <HBox Spacing=\"10\" Slot.Row=\"1\" Slot.Column=\"1\"><Slider Name=\"ui\" Min=\"0.75\" Max=\"2\" Step=\"0.05\" Slot.Fill=\"1\" AccessibleName=\"Interface size\"/><Label Name=\"ui.value\" Width=\"52\" Slot.VAlign=\"Center\"/></HBox>" ++
    "      <Label Width=\"150\" Text=\"High contrast\" Slot.Row=\"2\" Slot.VAlign=\"Center\" Tooltip=\"Black and white, a yellow focus, thick borders\"/>" ++
    "      <Checkbox Name=\"contrast\" Style=\"Switch\" Slot.Row=\"2\" Slot.Column=\"1\" AccessibleName=\"High contrast\"/>" ++
    "      <Label Width=\"150\" Text=\"Colors\" Slot.Row=\"3\" Slot.VAlign=\"Center\" Tooltip=\"Corrections move the colors that cannot be told apart; simulations show the interface as the color blind see it\"/>" ++
    "      <ComboBox Name=\"filter\" Slot.Row=\"3\" Slot.Column=\"1\" AccessibleName=\"Color filter\"/>" ++
    "      <Label Width=\"150\" Text=\"Focus ring\" Slot.Row=\"4\" Slot.VAlign=\"Center\" Tooltip=\"Always shown and thicker, not only after the keyboard was used\"/>" ++
    "      <Checkbox Name=\"focus\" Text=\"Always visible\" Style=\"Switch\" Slot.Row=\"4\" Slot.Column=\"1\"/>" ++
    "    </Grid>" ++
    "    <Label Text=\"Motion\" TextSize=\"16\" AccessibleRole=\"Heading\"/>" ++
    "    <Grid Columns=\"0,1\" Spacing=\"12\">" ++
    "      <Label Width=\"150\" Text=\"Reduce motion\" Slot.VAlign=\"Center\" Tooltip=\"Nothing moves by itself: no spring, no slide, no bounce, and the effects stand still\"/>" ++
    "      <Checkbox Name=\"motion\" Style=\"Switch\" Slot.Column=\"1\" AccessibleName=\"Reduce motion\"/>" ++
    "      <Label Width=\"150\" Text=\"Animation speed\" Slot.Row=\"1\" Slot.VAlign=\"Center\"/>" ++
    "      <HBox Spacing=\"10\" Slot.Row=\"1\" Slot.Column=\"1\"><Slider Name=\"speed\" Min=\"0.25\" Max=\"3\" Step=\"0.05\" Slot.Fill=\"1\" AccessibleName=\"Animation speed\"/><Label Name=\"speed.value\" Width=\"52\" Slot.VAlign=\"Center\"/></HBox>" ++
    "    </Grid>" ++
    "    <Border Name=\"motion.demo\" Effect=\"aurora\" CornerRadius=\"14\" Height=\"64\" Tooltip=\"An effect: it stands still with reduced motion, and still follows the pointer\">" ++
    "      <Label Text=\"Move the pointer here\" Slot.Padding=\"14\" Slot.VAlign=\"Center\" AccessibleHidden=\"true\"/>" ++
    "    </Border>" ++
    "    <Label Text=\"Screen readers\" TextSize=\"16\" AccessibleRole=\"Heading\"/>" ++
    "    <Label Name=\"reader\" Wrap=\"true\" Opacity=\"0.8\"/>" ++
    "    <HBox Spacing=\"8\"><Button Name=\"announce\" Text=\"Read a message\" Tooltip=\"Raccessibility_announce: what a screen reader says when something happens\"/></HBox>" ++
    "    <Label Text=\"The system\" TextSize=\"16\" AccessibleRole=\"Heading\"/>" ++
    "    <Label Name=\"system\" Wrap=\"true\" Opacity=\"0.8\"/>" ++
    "    <HBox Spacing=\"8\">" ++
    "      <Button Name=\"follow\" Text=\"Follow the system\" Tooltip=\"Text size, contrast and motion as the system asks\"/>" ++
    "      <Button Name=\"reset\" Text=\"Reset\"/>" ++
    "      <Spacer Slot.Fill=\"1\"/>" ++
    "      <Button Name=\"close\" Text=\"Close\" Style=\"Primary\"/>" ++
    "    </HBox>" ++
    "  </VBox>" ++
    "</ScrollBox>" ++
    "</Window>";

var g_a: extern struct {
    window: raven.Rid,
    syncing: c_int,
} = .{ .window = 0, .syncing = 0 };

// ---------------------------------------------------------------------------
//  Keeping the settings
// -------------------------------------------------------------------------

fn save_float(key: [*c]const u8, value: f32) void {
    var text: [32]u8 = undefined;
    _ = libc.snprintf(&text, text.len, "%.2f", @as(f64, value));
    ide.prefs_set(key, &text);
}

fn save_all() void {
    var text: [16]u8 = undefined;
    save_float("a11y.text_scale", raven.Raccessibility_get_text_scale());
    save_float("a11y.ui_scale", raven.Rget_ui_scale());
    ide.prefs_set("a11y.high_contrast", if (raven.Raccessibility_get_high_contrast() != 0) "1" else "0");
    _ = libc.snprintf(&text, text.len, "%d", @as(c_int, @bitCast(raven.Raccessibility_get_color_filter())));
    ide.prefs_set("a11y.color_filter", &text);
    ide.prefs_set("a11y.focus_visible", if (raven.Raccessibility_get_focus_always_visible() != 0) "1" else "0");
    ide.prefs_set("a11y.reduce_motion", if (raven.Raccessibility_get_reduce_motion() != 0) "1" else "0");
    save_float("a11y.animation_speed", raven.Rget_animation_speed());
}

export fn accessibility_apply_saved() void {
    var value: [*c]const u8 = undefined;
    value = ide.prefs_get("a11y.text_scale");
    if (value[0] != 0 and atof(value) > 0.0) raven.Raccessibility_set_text_scale(@floatCast(atof(value)));
    value = ide.prefs_get("a11y.ui_scale");
    if (value[0] != 0 and atof(value) > 0.0) raven.Rset_ui_scale(@floatCast(atof(value)));
    value = ide.prefs_get("a11y.high_contrast");
    if (value[0] != 0) raven.Raccessibility_set_high_contrast(@intFromBool(libc.atoi(value) != 0));
    value = ide.prefs_get("a11y.color_filter");
    if (value[0] != 0) {
        const filter: c_int = libc.atoi(value);
        var i: c_int = 0;
        while (i < FILTER_COUNT) : (i += 1) {
            if (@as(c_int, @bitCast(g_filters[@intCast(i)].filter)) == filter) raven.Raccessibility_set_color_filter(g_filters[@intCast(i)].filter);
        }
    }
    value = ide.prefs_get("a11y.focus_visible");
    if (value[0] != 0) raven.Raccessibility_set_focus_always_visible(@intFromBool(libc.atoi(value) != 0));
    value = ide.prefs_get("a11y.reduce_motion");
    if (value[0] != 0) raven.Raccessibility_set_reduce_motion(@intFromBool(libc.atoi(value) != 0));
    value = ide.prefs_get("a11y.animation_speed");
    if (value[0] != 0 and atof(value) > 0.0) raven.Rset_animation_speed(@floatCast(atof(value)));
    accessibility_sync_menu();
}

// ---------------------------------------------------------------------------
//  The window
// -------------------------------------------------------------------------

fn find(name: [*c]const u8) raven.Rid {
    return raven.Rwidget_find(g_a.window, name);
}

fn show_percent(name: [*c]const u8, value: f32) void {
    var text: [16]u8 = undefined;
    _ = libc.snprintf(&text, text.len, "%d %%", @as(c_int, @intFromFloat(value * 100.0 + 0.5)));
    raven.Rlabel_set_text(find(name), &text);
}

/// The window shows the settings as they are (they may change from the menu, or by following the system).
fn refresh() void {
    var system: raven.RAccessibilitySettings = undefined;
    var text: [300]u8 = undefined;
    var i: c_int = undefined;
    if (g_a.window == raven.R_INVALID_ID) return;
    g_a.syncing += 1;
    raven.Rslider_set_value(find("text"), raven.Raccessibility_get_text_scale());
    show_percent("text.value", raven.Raccessibility_get_text_scale());
    raven.Rslider_set_value(find("ui"), raven.Rget_ui_scale());
    show_percent("ui.value", raven.Rget_ui_scale());
    raven.Rcheckbox_set_checked(find("contrast"), raven.Raccessibility_get_high_contrast());
    i = 0;
    while (i < FILTER_COUNT) : (i += 1) {
        if (g_filters[@intCast(i)].filter == raven.Raccessibility_get_color_filter()) raven.Rcombo_box_set_selected(find("filter"), i);
    }
    raven.Rcheckbox_set_checked(find("focus"), raven.Raccessibility_get_focus_always_visible());
    raven.Rcheckbox_set_checked(find("motion"), raven.Raccessibility_get_reduce_motion());
    raven.Rslider_set_value(find("speed"), raven.Rget_animation_speed());
    show_percent("speed.value", raven.Rget_animation_speed());
    // (no speed to choose when nothing moves)
    raven.Rwidget_set_enabled(find("speed"), @intFromBool(raven.Raccessibility_get_reduce_motion() == 0));
    g_a.syncing -= 1;

    raven.Rlabel_set_text(find("reader"), if (raven.Raccessibility_is_screen_reader_active() != 0)
        "A screen reader is running: it reads the controls of every window (their names, roles, values and states)."
    else
        "No screen reader is running. Raven speaks to them (UI Automation on Windows, AT-SPI on Linux): start Narrator or NVDA, and every control is read.");
    raven.Raccessibility_get_system_settings(&system);
    _ = libc.snprintf(&text, text.len, "The system asks for: text at %d %%, %s, %s%s.", @as(c_int, @intFromFloat(system.text_scale * 100.0 + 0.5)), @as([*c]const u8, if (system.high_contrast != 0) "high contrast" else "normal contrast"), @as([*c]const u8, if (system.reduce_motion != 0) "reduced motion" else "animations"), @as([*c]const u8, if (system.screen_reader != 0) ", a screen reader" else ""));
    raven.Rlabel_set_text(find("system"), &text);
}

fn changed() void {
    save_all();
    accessibility_sync_menu();
    refresh();
}

fn on_slider(slider: raven.Rid, value: f32, user_data: ?*anyopaque) callconv(.c) void {
    const which: [*c]const u8 = @ptrCast(user_data);
    if (g_a.syncing != 0) return;
    _ = slider;
    if (libc.strcmp(which, "text") == 0) {
        raven.Raccessibility_set_text_scale(value);
    } else if (libc.strcmp(which, "ui") == 0) {
        raven.Rset_ui_scale(value);
    } else if (libc.strcmp(which, "speed") == 0) raven.Rset_animation_speed(value);
    changed();
}

fn on_switch(checkbox: raven.Rid, checked: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const which: [*c]const u8 = @ptrCast(user_data);
    if (g_a.syncing != 0) return;
    _ = checkbox;
    if (libc.strcmp(which, "contrast") == 0) {
        raven.Raccessibility_set_high_contrast(checked);
    } else if (libc.strcmp(which, "focus") == 0) {
        raven.Raccessibility_set_focus_always_visible(checked);
    } else if (libc.strcmp(which, "motion") == 0) raven.Raccessibility_set_reduce_motion(checked);
    changed();
}

fn on_filter(combo_box: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = combo_box;
    _ = user_data;
    if (g_a.syncing != 0 or index < 0 or index >= FILTER_COUNT) return;
    raven.Raccessibility_set_color_filter(g_filters[@intCast(index)].filter);
    changed();
}

fn on_button(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const which: [*c]const u8 = @ptrCast(user_data);
    _ = button;
    if (libc.strcmp(which, "announce") == 0) {
        raven.Raccessibility_announce("This is Raven: the screen reader reads what the application announces.", raven.R_FALSE);
        ide.ide_status("Announced to the screen reader%s.", @as([*c]const u8, if (raven.Raccessibility_is_screen_reader_active() != 0) "" else " (none is running)"));
        return;
    }
    if (libc.strcmp(which, "close") == 0) {
        raven.Rwindow_destroy(g_a.window);
        g_a.window = raven.R_INVALID_ID;
        return;
    }
    if (libc.strcmp(which, "follow") == 0) {
        raven.Raccessibility_follow_system();
    } else if (libc.strcmp(which, "reset") == 0) {
        raven.Raccessibility_set_text_scale(1.0);
        raven.Rset_ui_scale(1.0);
        raven.Raccessibility_set_high_contrast(raven.R_FALSE);
        raven.Raccessibility_set_color_filter(raven.R_COLOR_FILTER_NONE);
        raven.Raccessibility_set_focus_always_visible(raven.R_FALSE);
        raven.Raccessibility_set_reduce_motion(raven.R_FALSE);
        raven.Rset_animation_speed(1.0);
    }
    changed();
}

fn on_close(window: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    _ = user_data;
    g_a.window = raven.R_INVALID_ID;
    return raven.R_TRUE;
}

export fn accessibility_window() void {
    const sliders = [_][*c]const u8{ "text", "ui", "speed" };
    const switches = [_][*c]const u8{ "contrast", "focus", "motion" };
    const buttons = [_][*c]const u8{ "announce", "follow", "reset", "close" };
    var i: usize = undefined;
    if (g_a.window != raven.R_INVALID_ID and raven.Rwindow_is_valid(g_a.window) != 0) {
        raven.Rwindow_show(g_a.window);
        refresh();
        return;
    }
    g_a.window = raven.Rwindow_create_from_xml(A11Y_XML, A11Y_XML.len);
    if (g_a.window == raven.R_INVALID_ID) return;
    i = 0;
    while (i < @as(usize, @intCast(FILTER_COUNT))) : (i += 1) _ = raven.Rcombo_box_add_item(find("filter"), g_filters[i].name);
    i = 0;
    while (i < sliders.len) : (i += 1) raven.Rslider_set_changed_callback(find(sliders[i]), on_slider, @ptrCast(@constCast(sliders[i])));
    i = 0;
    while (i < switches.len) : (i += 1) raven.Rcheckbox_set_changed_callback(find(switches[i]), on_switch, @ptrCast(@constCast(switches[i])));
    i = 0;
    while (i < buttons.len) : (i += 1) raven.Rbutton_set_clicked_callback(find(buttons[i]), on_button, @ptrCast(@constCast(buttons[i])));
    raven.Rcombo_box_set_changed_callback(find("filter"), on_filter, null);
    raven.Rwindow_set_close_callback(g_a.window, on_close, null);
    refresh();
}

// ---------------------------------------------------------------------------
//  The menu
// -------------------------------------------------------------------------

export fn accessibility_sync_menu() void {
    const item: raven.Rid = raven.Rwidget_find(ide.g_ide_window, "menu.reduce_motion");
    if (item != raven.R_INVALID_ID) raven.Rmenu_item_set_checked(item, raven.Raccessibility_get_reduce_motion());
    refresh();
}

fn action_accessibility(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    if (libc.strcmp(action, "view.accessibility") == 0) {
        accessibility_window();
    } else if (libc.strcmp(action, "view.reduce_motion") == 0) {
        raven.Raccessibility_set_reduce_motion(@intFromBool(raven.Raccessibility_get_reduce_motion() == 0));
        save_all();
        accessibility_sync_menu();
        ide.ide_status(if (raven.Raccessibility_get_reduce_motion() != 0) "Reduced motion: nothing moves by itself." else "Animations are back.");
    }
}

export fn accessibility_init() void {
    g_a.window = raven.R_INVALID_ID;
    raven.Raction_bind("view.accessibility", action_accessibility, null);
    raven.Raction_bind("view.reduce_motion", action_accessibility, null);
}

export fn accessibility_shutdown() void {
    if (g_a.window != raven.R_INVALID_ID and raven.Rwindow_is_valid(g_a.window) != 0) raven.Rwindow_destroy(g_a.window);
    g_a.window = raven.R_INVALID_ID;
}
