// Translated to Zig from vendor/raven/examples/editor/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - editor
// A small scene editor. It shows the features an editor needs:
//
//   - the whole window is described in editor.xml,
//   - widgets are found by name and driven through named actions,
//   - a viewport shows a scene rendered by the application into a texture
//     (here a software renderer running on the Raven job system),
//   - a custom widget draws a frame-time graph with the Rdraw_ functions,
//   - a virtual list shows a log of any length without storing rows in Raven.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// #include <math.h>: floorf, sinf, sqrtf are @floor, @sin, @sqrt.
// #include <stdarg.h>: va_list is std.builtin.VaList (@cVaStart / @cVaEnd); on non-Windows vsnprintf takes a pointer to it.
const va_list = if (builtin.os.tag == .windows) [*c]u8 else std.builtin.VaList;
extern "c" fn vsnprintf(buf: [*c]u8, size: usize, format: [*c]const u8, args: if (builtin.os.tag == .windows) va_list else *va_list) c_int;

// #ifndef RAVEN_EXAMPLE_DIR / #define RAVEN_EXAMPLE_DIR "." / #endif:
// example.RAVEN_EXAMPLE_DIR is always defined (by the generated module example_config).

// ---------------------------------------------------------------------------
//  Scene
// -------------------------------------------------------------------------

const MAX_OBJECTS = 64;

const Object = extern struct {
    name: [48]u8,
    x: f32,
    y: f32,
    radius: f32,
    speed: f32,
    phase: f32,
    color: c_int,
    visible: c_int,
    // handle of the row in the outliner
    item: raven.Rid,
};

const g_palette = [4][3]f32{
    .{ 1.00, 0.55, 0.15 }, .{ 0.25, 0.55, 1.00 }, .{ 0.30, 0.85, 0.45 }, .{ 1.00, 0.40, 0.70 },
};

var g_objects: [MAX_OBJECTS]Object = std.mem.zeroes([MAX_OBJECTS]Object);
var g_object_count: c_int = 0;
var g_selected: c_int = -1;
var g_playing: c_int = 1;
var g_time: f64 = 0;
var g_created: c_int = 0;

// ---------------------------------------------------------------------------
//  User interface
// -------------------------------------------------------------------------

var ui = std.mem.zeroes(extern struct {
    window: raven.Rid,
    outliner: raven.Rid,
    scene: raven.Rid,
    graph: raven.Rid,
    log: raven.Rid,
    stats: raven.Rid,
    play: raven.Rid,
    render_info: raven.Rid,
    name: raven.Rid,
    radius: raven.Rid,
    speed: raven.Rid,
    color: raven.Rid,
    visible: raven.Rid,
    texture: raven.Rid,
    // set while the property widgets are filled from code, to ignore their callbacks
    updating: c_int,
});

// ---- log: only the strings live here, the list asks for the rows it draws ----

const LOG_CAPACITY = 2000;
var g_log: [LOG_CAPACITY][96]u8 = std.mem.zeroes([LOG_CAPACITY][96]u8);
var g_log_count: c_int = 0;

fn log_row(list: raven.Rid, index: c_int, user_data: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = list;
    _ = user_data;
    return &g_log[@intCast(index)];
}

fn log_add(format: [*c]const u8, ...) callconv(.c) void {
    var arguments: va_list = undefined;
    if (g_log_count == LOG_CAPACITY) return;
    arguments = @cVaStart();
    _ = vsnprintf(&g_log[@intCast(g_log_count)], @sizeOf(@TypeOf(g_log[0])), format, &arguments);
    @cVaEnd(&arguments);
    g_log_count += 1;
    raven.Rlist_view_set_virtual_items(ui.log, g_log_count, log_row, null);
    raven.Rlist_view_scroll_to_item(ui.log, g_log_count - 1);
}

// ---- properties ----

fn properties_refresh() void {
    const object: [*c]const Object = if (g_selected >= 0) &g_objects[@intCast(g_selected)] else null;
    const enabled: c_int = @intFromBool(object != null);

    ui.updating = 1;
    raven.Rtext_input_set_text(ui.name, if (object != null) @as([*c]const u8, &object.*.name) else "");
    raven.Rslider_set_value(ui.radius, if (object != null) object.*.radius else 0.0);
    raven.Rspin_box_set_value(ui.speed, if (object != null) @as(f64, object.*.speed) else 0.0);
    raven.Rcombo_box_set_selected(ui.color, if (object != null) object.*.color else 0);
    raven.Rcheckbox_set_checked(ui.visible, if (object != null) object.*.visible else 0);
    ui.updating = 0;

    raven.Rwidget_set_enabled(ui.name, enabled);
    raven.Rwidget_set_enabled(ui.radius, enabled);
    raven.Rwidget_set_enabled(ui.speed, enabled);
    raven.Rwidget_set_enabled(ui.color, enabled);
    raven.Rwidget_set_enabled(ui.visible, enabled);
}

fn object_of_item(item: raven.Rid) c_int {
    var i: c_int = 0;
    while (i < g_object_count) : (i += 1) {
        if (g_objects[@intCast(i)].item == item) return i;
    }
    return -1;
}

// ---- scene edition ----

fn scene_add(name: [*c]const u8) void {
    var object: [*c]Object = undefined;
    if (g_object_count == MAX_OBJECTS) {
        log_add("The scene is full (%d objects)", @as(c_int, MAX_OBJECTS));
        return;
    }
    object = &g_objects[@intCast(g_object_count)];
    object.* = std.mem.zeroes(Object);
    g_created += 1;
    if (name != null) {
        _ = example.snprintf(&object.*.name, @sizeOf(@TypeOf(object.*.name)), "%s", name);
    } else {
        _ = example.snprintf(&object.*.name, @sizeOf(@TypeOf(object.*.name)), "Object %d", g_created);
    }
    object.*.x = 0.2 + 0.6 * @as(f32, @floatFromInt(@rem(g_created * 37, 100))) / 100.0;
    object.*.y = 0.25 + 0.5 * @as(f32, @floatFromInt(@rem(g_created * 61, 100))) / 100.0;
    object.*.radius = 0.08 + 0.02 * @as(f32, @floatFromInt(@rem(g_created, 4)));
    object.*.speed = 1.0 + 0.25 * @as(f32, @floatFromInt(@rem(g_created, 5)));
    object.*.phase = @as(f32, @floatFromInt(g_created)) * 1.7;
    object.*.color = @rem(g_created - 1, 4);
    object.*.visible = 1;
    object.*.item = raven.Rtree_view_add_item(ui.outliner, raven.R_INVALID_ID, &object.*.name);
    g_selected = g_object_count;
    g_object_count += 1;
    raven.Rtree_view_set_selected_item(ui.outliner, object.*.item);
    properties_refresh();
    log_add("Added \"%s\"", @as([*c]const u8, &object.*.name));
}

fn scene_delete_selected() void {
    var i: c_int = undefined;
    if (g_selected < 0) return;
    log_add("Deleted \"%s\"", @as([*c]const u8, &g_objects[@intCast(g_selected)].name));
    raven.Rtree_item_destroy(g_objects[@intCast(g_selected)].item);
    i = g_selected;
    while (i + 1 < g_object_count) : (i += 1) g_objects[@intCast(i)] = g_objects[@intCast(i + 1)];
    g_object_count -= 1;
    g_selected = -1;
    properties_refresh();
}

// ---------------------------------------------------------------------------
//  Software renderer: fills an RGBA image, one band of rows per job
// -------------------------------------------------------------------------

var g_render = std.mem.zeroes(extern struct {
    pixels: [*c]u8,
    width: c_int,
    height: c_int,
    // viewport size in pixels, and the divisor chosen in the combo box
    viewport_width: c_int,
    viewport_height: c_int,
    render_ms: f64,
});

fn render_rows(begin: raven.Ruint, end: raven.Ruint, user_data: ?*anyopaque) callconv(.c) void {
    const width: c_int = g_render.width;
    const height: c_int = g_render.height;
    const aspect: f32 = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    var row: raven.Ruint = undefined;
    _ = user_data;

    row = begin;
    while (row < end) : (row += 1) {
        const out: [*c]u8 = g_render.pixels + @as(usize, row) * @as(usize, @intCast(width)) * 4;
        const v: f32 = (@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(height));
        var column: c_int = undefined;
        var i: c_int = undefined;
        column = 0;
        while (column < width) : (column += 1) {
            const u: f32 = (@as(f32, @floatFromInt(column)) + 0.5) / @as(f32, @floatFromInt(width));
            // background: a slow gradient with a grid
            var r: f32 = 0.07 + 0.05 * v;
            var g: f32 = 0.08 + 0.06 * v;
            var b: f32 = 0.11 + 0.10 * v;
            const grid_u: f32 = u * aspect * 10.0;
            const grid_v: f32 = v * 10.0;
            if (grid_u - @floor(grid_u) < 0.03 or grid_v - @floor(grid_v) < 0.03) {
                r += 0.04;
                g += 0.04;
                b += 0.05;
            }
            i = 0;
            while (i < g_object_count) : (i += 1) {
                const object: [*c]const Object = &g_objects[@intCast(i)];
                var dx: f32 = undefined;
                var dy: f32 = undefined;
                var distance: f32 = undefined;
                var shade: f32 = undefined;
                var edge: f32 = undefined;
                if (object.*.visible == 0) continue;
                dx = (u - object.*.x) * aspect;
                dy = v - (object.*.y + 0.06 * @sin(@as(f32, @floatCast(g_time)) * object.*.speed + object.*.phase));
                distance = @sqrt(dx * dx + dy * dy);
                if (distance > object.*.radius + 0.01) continue;
                // a shaded disc with a soft edge; the selected one gets a ring
                shade = 1.0 - 0.55 * (distance / object.*.radius) * (distance / object.*.radius);
                edge = (object.*.radius - distance) * @as(f32, @floatFromInt(height)) * 0.5;
                edge = if (edge < 0.0) 0.0 else (if (edge > 1.0) 1.0 else edge);
                if (i == g_selected and distance > object.*.radius - 0.012) shade = 1.6;
                r += (g_palette[@intCast(object.*.color)][0] * shade - r) * edge;
                g += (g_palette[@intCast(object.*.color)][1] * shade - g) * edge;
                b += (g_palette[@intCast(object.*.color)][2] * shade - b) * edge;
            }
            out[@intCast(column * 4 + 0)] = @intFromFloat(255.0 * (if (r > 1.0) 1.0 else r));
            out[@intCast(column * 4 + 1)] = @intFromFloat(255.0 * (if (g > 1.0) 1.0 else g));
            out[@intCast(column * 4 + 2)] = @intFromFloat(255.0 * (if (b > 1.0) 1.0 else b));
            out[@intCast(column * 4 + 3)] = 255;
        }
    }
}

fn scene_render() void {
    const divisors = [3]c_int{ 1, 2, 4 };
    const divisor: c_int = divisors[@intCast(@rem(raven.Rcombo_box_get_selected(raven.Rwidget_find(ui.window, "render.scale")), 3))];
    const width: c_int = @divTrunc(g_render.viewport_width, divisor);
    const height: c_int = @divTrunc(g_render.viewport_height, divisor);
    const threaded: c_int = raven.Rcheckbox_is_checked(raven.Rwidget_find(ui.window, "render.threads"));
    var start: f64 = undefined;
    var info: [128]u8 = undefined;

    if (width < 2 or height < 2) return;
    if (width != g_render.width or height != g_render.height) {
        example.free(g_render.pixels);
        g_render.pixels = @ptrCast(example.malloc(@as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4));
        g_render.width = width;
        g_render.height = height;
    }

    start = raven.Rget_time();
    // bands of 8 rows are shared between the worker threads and this thread
    if (threaded != 0) raven.Rparallel_for(@intCast(height), 8, render_rows, null) else render_rows(0, @intCast(height), null);
    g_render.render_ms = (raven.Rget_time() - start) * 1000.0;

    // the pixels are copied: the renderer uploads them on its own thread
    if (ui.texture == raven.R_INVALID_ID) {
        ui.texture = raven.Rtexture_create_from_pixels(g_render.pixels, width, height);
        raven.Rviewport_set_texture(ui.scene, ui.texture);
    } else {
        raven.Rtexture_update(ui.texture, g_render.pixels, width, height);
    }

    _ = example.snprintf(&info, info.len, "%d x %d pixels in %.2f ms on %d thread%s", width, height, g_render.render_ms, //
        if (threaded != 0) raven.Rget_worker_thread_count() + 1 else @as(c_int, 1), //
        @as([*c]const u8, if (threaded != 0 and raven.Rget_worker_thread_count() > 0) "s" else ""));
    raven.Rlabel_set_text(ui.render_info, &info);
}

fn on_scene_resized(viewport: raven.Rid, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = viewport;
    _ = user_data;
    g_render.viewport_width = width;
    g_render.viewport_height = height;
}

// Mouse in the viewport: select the object under the cursor and drag it.
fn on_scene_event(viewport: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const S = struct {
        var dragging: c_int = 0;
    };
    var x: f32 = undefined;
    var y: f32 = undefined;
    var width: f32 = undefined;
    var height: f32 = undefined;
    var u: f32 = undefined;
    var v: f32 = undefined;
    var i: c_int = undefined;
    _ = user_data;

    raven.Rwidget_get_rect(viewport, &x, &y, &width, &height);
    if (width <= 0.0 or height <= 0.0) return raven.R_FALSE;
    u = event.*.local_x / width;
    v = event.*.local_y / height;

    if (event.*.type == raven.R_EVENT_MOUSE_DOWN and event.*.button == raven.R_MOUSE_LEFT) {
        i = g_object_count - 1;
        while (i >= 0) : (i -= 1) {
            const dx: f32 = (u - g_objects[@intCast(i)].x) * width / height;
            const dy: f32 = v - g_objects[@intCast(i)].y;
            if (g_objects[@intCast(i)].visible != 0 and dx * dx + dy * dy < g_objects[@intCast(i)].radius * g_objects[@intCast(i)].radius * 1.5) break;
        }
        g_selected = i;
        raven.Rtree_view_set_selected_item(ui.outliner, if (i >= 0) g_objects[@intCast(i)].item else raven.R_INVALID_ID);
        properties_refresh();
        S.dragging = @intFromBool(i >= 0);
        return raven.R_TRUE;
    }
    if (event.*.type == raven.R_EVENT_MOUSE_MOVE and S.dragging != 0 and g_selected >= 0) {
        g_objects[@intCast(g_selected)].x = if (u < 0.0) 0.0 else (if (u > 1.0) 1.0 else u);
        g_objects[@intCast(g_selected)].y = if (v < 0.0) 0.0 else (if (v > 1.0) 1.0 else v);
        return raven.R_TRUE;
    }
    if (event.*.type == raven.R_EVENT_MOUSE_UP) S.dragging = 0;
    return raven.R_FALSE;
}

// ---------------------------------------------------------------------------
//  Custom widget: frame-time graph
// -------------------------------------------------------------------------

const GRAPH_SAMPLES = 240;
var g_frame_ms: [GRAPH_SAMPLES]f32 = std.mem.zeroes([GRAPH_SAMPLES]f32);
var g_frame_cursor: c_int = 0;

fn graph_paint(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    var text_r: f32 = undefined;
    var text_g: f32 = undefined;
    var text_b: f32 = undefined;
    var text_a: f32 = undefined;
    var peak: f32 = 20.0;
    var scale: f32 = undefined;
    var label: [32]u8 = undefined;
    var i: c_int = undefined;
    _ = widget;
    _ = user_data;

    // theme colors keep the widget readable in both themes
    raven.Rtheme_get_color(raven.R_COLOR_TEXT, &text_r, &text_g, &text_b, &text_a);
    raven.Rdraw_rect(painter, 0.0, 0.0, width, height, 6.0, 0.5, 0.5, 0.5, 0.10);

    i = 0;
    while (i < GRAPH_SAMPLES) : (i += 1) peak = if (g_frame_ms[@intCast(i)] > peak) g_frame_ms[@intCast(i)] else peak;
    scale = (height - 24.0) / peak;

    // the 16.7 ms line: 60 frames per second
    raven.Rdraw_line(painter, 0.0, height - 16.7 * scale, width, height - 16.7 * scale, 1.0, 0.3, 0.8, 0.4, 0.8);
    raven.Rdraw_text(painter, raven.R_INVALID_ID, 11.0, 6.0, height - 16.7 * scale - 16.0, "16.7 ms", text_r, text_g, text_b, 0.6);

    i = 1;
    while (i < GRAPH_SAMPLES) : (i += 1) {
        // oldest sample on the left
        const previous: f32 = g_frame_ms[@intCast(@rem(g_frame_cursor + i - 1, GRAPH_SAMPLES))];
        const current: f32 = g_frame_ms[@intCast(@rem(g_frame_cursor + i, GRAPH_SAMPLES))];
        const x0: f32 = width * @as(f32, @floatFromInt(i - 1)) / @as(f32, @floatFromInt(GRAPH_SAMPLES - 1));
        const x1: f32 = width * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(GRAPH_SAMPLES - 1));
        raven.Rdraw_line(painter, x0, height - previous * scale, x1, height - current * scale, 1.5, 0.25, 0.6, 1.0, 1.0);
    }

    _ = example.snprintf(&label, label.len, "peak %.1f ms", @as(f64, peak));
    raven.Rdraw_text(painter, raven.R_INVALID_ID, 12.0, 8.0, 6.0, &label, text_r, text_g, text_b, text_a);
}

// ---------------------------------------------------------------------------
//  Actions (named in editor.xml)
// -------------------------------------------------------------------------

const THEME_COUNT = 4;

// The entries of the View menu that choose a theme.
const g_themes = [THEME_COUNT]extern struct {
    action: [*c]const u8,
    menu_item: [*c]const u8,
    theme: raven.RTheme,
}{
    .{ .action = "view.dark", .menu_item = "menu.dark", .theme = raven.R_THEME_DARK },
    .{ .action = "view.light", .menu_item = "menu.light", .theme = raven.R_THEME_LIGHT },
    .{ .action = "view.glass_dark", .menu_item = "menu.glass_dark", .theme = raven.R_THEME_GLASS_DARK },
    .{ .action = "view.glass_light", .menu_item = "menu.glass_light", .theme = raven.R_THEME_GLASS_LIGHT },
};

fn theme_of_action(action: [*c]const u8, index: [*c]c_int) c_int {
    var i: c_int = 0;
    while (i < THEME_COUNT) : (i += 1) {
        if (example.strcmp(action, g_themes[@intCast(i)].action) == 0) {
            index.* = i;
            return 1;
        }
    }
    return 0;
}

fn on_action(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const object: [*c]Object = if (g_selected >= 0) &g_objects[@intCast(g_selected)] else null;
    var theme_index: c_int = 0;
    _ = user_data;

    if (example.strcmp(action, "app.quit") == 0) {
        raven.Rquit(0);
    } else if (example.strcmp(action, "scene.new") == 0) {
        raven.Rtree_view_clear_items(ui.outliner);
        g_object_count = 0;
        g_selected = -1;
        properties_refresh();
        log_add("New scene");
    } else if (example.strcmp(action, "scene.add") == 0) {
        scene_add(null);
    } else if (example.strcmp(action, "scene.delete") == 0) {
        scene_delete_selected();
    } else if (example.strcmp(action, "scene.play") == 0) {
        g_playing = @intFromBool(g_playing == 0);
        raven.Rbutton_set_text(ui.play, @as([*c]const u8, if (g_playing != 0) "Pause" else "Play"));
        // no animation: the window is only redrawn when something changes
        raven.Rviewport_set_realtime(ui.scene, g_playing);
        log_add(@as([*c]const u8, if (g_playing != 0) "Animation started" else "Animation paused"));
    } else if (theme_of_action(action, &theme_index) != 0) {
        // the two glass themes make every control translucent (see examples/glass)
        var i: c_int = undefined;
        raven.Rtheme_apply(g_themes[@intCast(theme_index)].theme);
        i = 0;
        while (i < THEME_COUNT) : (i += 1) {
            raven.Rmenu_item_set_checked(raven.Rwidget_find(ui.window, g_themes[@intCast(i)].menu_item), @intFromBool(i == theme_index));
        }
    } else if (example.strcmp(action, "view.compact") == 0) {
        raven.Rtheme_set_metric(raven.R_METRIC_FONT_SIZE, 12.0);
        raven.Rtheme_set_metric(raven.R_METRIC_CONTROL_HEIGHT, 22.0);
        raven.Rtheme_set_metric(raven.R_METRIC_ROW_HEIGHT, 20.0);
    } else if (example.strcmp(action, "view.comfortable") == 0) {
        raven.Rtheme_set_metric(raven.R_METRIC_FONT_SIZE, 15.0);
        raven.Rtheme_set_metric(raven.R_METRIC_CONTROL_HEIGHT, 32.0);
        raven.Rtheme_set_metric(raven.R_METRIC_ROW_HEIGHT, 28.0);
    } else if (object != null and ui.updating == 0) {
        // the property widgets edit the selected object
        if (example.strcmp(action, "prop.radius") == 0) {
            object.*.radius = raven.Rslider_get_value(sender);
        } else if (example.strcmp(action, "prop.speed") == 0) {
            object.*.speed = @floatCast(raven.Rspin_box_get_value(sender));
        } else if (example.strcmp(action, "prop.color") == 0) {
            object.*.color = raven.Rcombo_box_get_selected(sender) & 3;
        } else if (example.strcmp(action, "prop.visible") == 0) {
            object.*.visible = raven.Rcheckbox_is_checked(sender);
        }
    }
    // a paused scene is rendered again only when it was edited
    if (g_playing == 0) raven.Rwidget_invalidate(ui.scene);
}

// Every keystroke in the name field renames the selected object.
fn on_name_changed(input: raven.Rid, text: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = input;
    _ = user_data;
    if (g_selected < 0 or ui.updating != 0) return;
    _ = example.snprintf(&g_objects[@intCast(g_selected)].name, @sizeOf(@TypeOf(g_objects[@intCast(g_selected)].name)), "%s", text);
    raven.Rtree_item_set_text(g_objects[@intCast(g_selected)].item, text);
}

// A row of the outliner was selected, with the mouse or the keyboard.
fn on_outliner_selection(tree: raven.Rid, item: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = tree;
    _ = user_data;
    g_selected = object_of_item(item);
    properties_refresh();
    if (g_playing == 0) raven.Rwidget_invalidate(ui.scene);
}

// ---------------------------------------------------------------------------
//  Frame
// -------------------------------------------------------------------------

// Called once per frame, before the layout.
fn on_frame(delta_seconds: f64, user_data: ?*anyopaque) callconv(.c) void {
    const S = struct {
        var stats_timer: f64 = 0;
    };
    _ = user_data;
    if (raven.Rwindow_is_valid(ui.window) == 0) return;

    if (g_playing != 0) g_time += delta_seconds;
    scene_render();

    g_frame_ms[@intCast(g_frame_cursor)] = @floatCast(delta_seconds * 1000.0);
    g_frame_cursor = @rem(g_frame_cursor + 1, GRAPH_SAMPLES);
    raven.Rwidget_invalidate(ui.graph);

    S.stats_timer += delta_seconds;
    if (S.stats_timer > 0.25) {
        var stats: raven.RFrameStats = undefined;
        var text: [160]u8 = undefined;
        S.stats_timer = 0.0;
        raven.Rwindow_get_frame_stats(ui.window, &stats);
        _ = example.snprintf(&text, text.len, "%u widgets   %u primitives in %u draw call%s   layout %.2f ms   paint %.2f ms   gpu %.2f ms", //
            stats.widget_count, stats.instance_count, stats.draw_call_count, @as([*c]const u8, if (stats.draw_call_count > 1) "s" else ""), //
            stats.layout_ms, stats.paint_ms, stats.render_ms);
        raven.Rlabel_set_text(ui.stats, &text);
    }
}

export fn main() c_int {
    if (example.example_init("editor") == 0) return 1;

    ui.texture = raven.R_INVALID_ID;
    ui.window = raven.Rwindow_create_from_xml_file(example.RAVEN_EXAMPLE_DIR ++ "/editor.xml");
    if (ui.window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }

    // widgets are found by the Name given in the XML
    ui.outliner = raven.Rwidget_find(ui.window, "outliner");
    ui.scene = raven.Rwidget_find(ui.window, "scene");
    ui.graph = raven.Rwidget_find(ui.window, "graph");
    ui.log = raven.Rwidget_find(ui.window, "log");
    ui.stats = raven.Rwidget_find(ui.window, "stats");
    ui.play = raven.Rwidget_find(ui.window, "play");
    ui.render_info = raven.Rwidget_find(ui.window, "render.info");
    ui.name = raven.Rwidget_find(ui.window, "prop.name");
    ui.radius = raven.Rwidget_find(ui.window, "prop.radius");
    ui.speed = raven.Rwidget_find(ui.window, "prop.speed");
    ui.color = raven.Rwidget_find(ui.window, "prop.color");
    ui.visible = raven.Rwidget_find(ui.window, "prop.visible");

    // one handler receives every action that has no function of its own
    raven.Raction_set_default_handler(on_action, null);

    // events without an action name are plain callbacks
    raven.Rtree_view_set_selection_changed_callback(ui.outliner, on_outliner_selection, null);
    raven.Rtext_input_set_changed_callback(ui.name, on_name_changed, null);
    raven.Rcustom_set_paint_callback(ui.graph, graph_paint, null);
    raven.Rviewport_set_resize_callback(ui.scene, on_scene_resized, null);
    raven.Rwidget_set_event_callback(ui.scene, on_scene_event, null);
    raven.Rset_frame_callback(on_frame, null);

    log_add("Raven %s, %d worker thread(s)", raven.Rget_version(), raven.Rget_worker_thread_count());
    scene_add("Sun");
    scene_add("Planet");
    scene_add("Moon");

    // the loop belongs to the application: Raven draws one frame per call,
    // and Rwait_frame sleeps until there is something to draw
    if (example.example_automated(ui.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }

    example.free(g_render.pixels);
    raven.Rshutdown();
    return 0;
}
