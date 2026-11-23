// Translated to Zig from vendor/raven/src/widgets/common.h and the headers the widgets include. Modified by Seridian: C11 -> Zig translation.
//
// Raven - widgets/externs.zig
// Prototypes of the functions of OTHER modules that the files of src/widgets call (widget/widget.h, render/draw.h,
// render/font.h, render/renderer.h, core/context.h, core/fs.h, core/handle.h, core/thread.h, xml/xml.h).
// Generated from `zig translate-c`; each type is qualified by the header unit that owns it. The functions of
// core/base.h are in core/base_h.zig, the public API in raven.zig, libc in sys/libc.zig.
// A widget file may use `const ext = @import("externs.zig");` and call `ext.rvn_widget_create(...)`.
// This unit exports nothing (extern declarations only).
//
// The header units named below belong to the translators of the other modules (src/<m>/<n>_h.zig).
// static inline functions of those headers are NOT here: they live in their header unit.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const context_h = @import("../core/context_h.zig");
const draw_h = @import("../render/draw_h.zig");
const font_h = @import("../render/font_h.zig");
const fs_h = @import("../core/fs_h.zig");
const handle_h = @import("../core/handle_h.zig");
const renderer_h = @import("../render/renderer_h.zig");
const thread_h = @import("../core/thread_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const xml_h = @import("../xml/xml_h.zig");

pub extern var g_rvn: context_h.rvn_context_t;

pub extern fn rvn_a11y_focus_always() c_int;
pub extern fn rvn_a11y_focus_width() f32;
pub extern fn rvn_api_check(function: [*c]const u8) c_int;
pub extern fn rvn_atomic_add(a: [*c]thread_h.rvn_atomic_t, v: c_int) c_int;
pub extern fn rvn_clock_seconds() f64;
pub extern fn rvn_curve_point(points: [*c]const f32, t: f32) base.rvn_vec2_t;
pub extern fn rvn_dir_free(entries: [*c]fs_h.rvn_dir_entry_t, count: u32) void;
pub extern fn rvn_dir_read(path: [*c]const u8, entries: [*c][*c]fs_h.rvn_dir_entry_t, count: [*c]u32) c_int;
pub extern fn rvn_dispatch_begin() void;
pub extern fn rvn_dispatch_end() void;
pub extern fn rvn_drawlist_add_callback(list: [*c]draw_h.rvn_drawlist_t, command: [*c]const raven.RDrawCommand) void;
pub extern fn rvn_drawlist_transform(list: [*c]draw_h.rvn_drawlist_t, first_instance: u32, first_command: u32, sx: f32, sy: f32, pivot_x: f32, pivot_y: f32, dx: f32, dy: f32, limit: base.rvn_box_t) void;
pub extern fn rvn_fire_action(sender: raven.Rid, action: [*c]const u8) void;
pub extern fn rvn_font_metrics(font: ?*font_h.rvn_font_t, size: f32, metrics: [*c]font_h.rvn_font_metrics_t) void;
pub extern fn rvn_font_resolve(font: raven.Rid) ?*font_h.rvn_font_t;
pub extern fn rvn_font_variant(font: raven.Rid, style: u32) raven.Rid;
pub extern fn rvn_fs_places(places: [*c][*c]fs_h.rvn_place_t, count: [*c]u32) void;
pub extern fn rvn_fs_places_free(places: [*c]fs_h.rvn_place_t, count: u32) void;
pub extern fn rvn_paint_blur(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, blur: [*c]const draw_h.rvn_blur_t) void;
pub extern fn rvn_paint_box(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radius: f32, fill: base.rvn_color_t, border_width: f32, border_color: base.rvn_color_t) void;
pub extern fn rvn_paint_box4(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, fill: base.rvn_color_t, border_width: f32, border_color: base.rvn_color_t) void;
pub extern fn rvn_paint_chevron(painter: ?*raven.RPainter, cx: f32, cy: f32, size: f32, angle: f32, color: base.rvn_color_t) void;
pub extern fn rvn_paint_curve(painter: ?*raven.RPainter, points: [*c]const f32, curve: [*c]const draw_h.rvn_curve_t) void;
pub extern fn rvn_paint_erase(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, amount: f32) void;
pub extern fn rvn_paint_glass(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, glass: [*c]const draw_h.rvn_glass_t) void;
pub extern fn rvn_paint_icon(painter: ?*raven.RPainter, icon: draw_h.rvn_icon_t, cx: f32, cy: f32, size: f32, color: base.rvn_color_t) void;
pub extern fn rvn_paint_image(painter: ?*raven.RPainter, rect: base.rvn_rect_t, texture: raven.Rid, uv: [*c]const f32, tint: base.rvn_color_t, radius: f32) void;
pub extern fn rvn_paint_keep_animating(painter: ?*raven.RPainter) void;
pub extern fn rvn_paint_line(painter: ?*raven.RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: base.rvn_color_t) void;
pub extern fn rvn_paint_pop_clip(painter: ?*raven.RPainter) void;
pub extern fn rvn_paint_push_clip(painter: ?*raven.RPainter, rect: base.rvn_rect_t) void;
pub extern fn rvn_paint_rect(painter: ?*raven.RPainter, rect: base.rvn_rect_t, color: base.rvn_color_t) void;
pub extern fn rvn_paint_shader(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, shader: raven.Rid, look: [*c]const raven.RShaderLook) void;
pub extern fn rvn_paint_shadow(painter: ?*raven.RPainter, rect: base.rvn_rect_t, radius: f32, blur: f32, color: base.rvn_color_t) void;
pub extern fn rvn_paint_snap(painter: ?*const raven.RPainter, rect: base.rvn_rect_t) base.rvn_box_t;
pub extern fn rvn_paint_spring(painter: ?*raven.RPainter, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) f32;
pub extern fn rvn_paint_spring_from(painter: ?*raven.RPainter, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) f32;
pub extern fn rvn_paint_text(painter: ?*raven.RPainter, font: raven.Rid, size: f32, x: f32, y: f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t) void;
pub extern fn rvn_paint_text_in(painter: ?*raven.RPainter, font: raven.Rid, size: f32, rect: base.rvn_rect_t, @"align": f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t) void;
pub extern fn rvn_paint_triangle(painter: ?*raven.RPainter, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, color: base.rvn_color_t) void;
pub extern fn rvn_parse_bool(text: [*c]const u8, value: [*c]c_int) c_int;
pub extern fn rvn_parse_color(text: [*c]const u8, color: [*c]base.rvn_color_t) c_int;
pub extern fn rvn_parse_float(text: [*c]const u8, value: [*c]f32) c_int;
pub extern fn rvn_parse_floats(text: [*c]const u8, values: [*c]f32, max: c_int) c_int;
pub extern fn rvn_parse_int(text: [*c]const u8, value: [*c]c_int) c_int;
pub extern fn rvn_parse_margin(text: [*c]const u8, margin: [*c]base.rvn_margin_t) c_int;
pub extern fn rvn_parse_orientation(text: [*c]const u8, orientation: [*c]raven.ROrientation) c_int;
pub extern fn rvn_path_absolute(path: [*c]const u8) [*c]u8;
pub extern fn rvn_path_child(folder: [*c]const u8, name: [*c]const u8) [*c]u8;
pub extern fn rvn_path_exists(path: [*c]const u8) c_int;
pub extern fn rvn_path_home() [*c]u8;
pub extern fn rvn_path_is_dir(path: [*c]const u8) c_int;
pub extern fn rvn_path_name(path: [*c]const u8) [*c]const u8;
pub extern fn rvn_path_parent(path: [*c]const u8) [*c]u8;
pub extern fn rvn_pattern_match(patterns: [*c]const u8, name: [*c]const u8) c_int;
pub extern fn rvn_pool_add(pool: [*c]handle_h.rvn_pool_t, object: ?*anyopaque) raven.Rid;
pub extern fn rvn_pool_at(pool: [*c]const handle_h.rvn_pool_t, index: u32) ?*anyopaque;
pub extern fn rvn_pool_get(pool: [*c]const handle_h.rvn_pool_t, id: raven.Rid) ?*anyopaque;
pub extern fn rvn_pool_remove(pool: [*c]handle_h.rvn_pool_t, id: raven.Rid) void;
pub extern fn rvn_repaint_all_windows() void;
pub extern fn rvn_shader_from_file_cached(path: [*c]const u8, flags: raven.Ruint) raven.Rid;
pub extern fn rvn_spring_kick(spring: [*c]raven.RSpring, velocity: f32) void;
pub extern fn rvn_spring_moving(spring: [*c]const raven.RSpring, target: f32) c_int;
pub extern fn rvn_spring_set(spring: [*c]raven.RSpring, value: f32) void;
pub extern fn rvn_text_offset_at(font: ?*font_h.rvn_font_t, size: f32, text: [*c]const u8, length: c_int, x: f32) c_int;
pub extern fn rvn_text_width(font: ?*font_h.rvn_font_t, size: f32, text: [*c]const u8, length: c_int) f32;
pub extern fn rvn_text_wrap(font: ?*font_h.rvn_font_t, size: f32, text: [*c]const u8, length: c_int, max_width: f32, line_width: [*c]f32) c_int;
pub extern fn rvn_texture_create_raw(width: c_int, height: c_int, format: raven.RTextureFormat, filter: raven.RFilterType, pixels: ?*anyopaque) raven.Rid;
pub extern fn rvn_texture_get(id: raven.Rid) [*c]renderer_h.rvn_texture_t;
pub extern fn rvn_theme_dark_twin() [*c]const context_h.rvn_theme_t;
pub extern fn rvn_update() void;
pub extern fn rvn_widget_add_child(parent: [*c]widget_h.rvn_widget_t, child: [*c]widget_h.rvn_widget_t, index: c_int) void;
pub extern fn rvn_widget_animate_layout(widget: [*c]widget_h.rvn_widget_t, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) void;
pub extern fn rvn_widget_appear(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_arrange(widget: [*c]widget_h.rvn_widget_t, x: f32, y: f32, width: f32, height: f32) void;
pub extern fn rvn_widget_arrange_slot(child: [*c]widget_h.rvn_widget_t, area: base.rvn_rect_t) void;
pub extern fn rvn_widget_capture_mouse(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_check(id: raven.Rid, @"type": raven.RWidgetType, function: [*c]const u8) [*c]widget_h.rvn_widget_t;
pub extern fn rvn_widget_child_index(parent: [*c]const widget_h.rvn_widget_t, child: [*c]const widget_h.rvn_widget_t) c_int;
pub extern fn rvn_widget_color(widget: [*c]const widget_h.rvn_widget_t, role: raven.RColorRole) base.rvn_color_t;
pub extern fn rvn_widget_create(@"type": raven.RWidgetType) [*c]widget_h.rvn_widget_t;
pub extern fn rvn_widget_create_class(cls: [*c]const widget_h.rvn_widget_class_t) [*c]widget_h.rvn_widget_t;
pub extern fn rvn_widget_destroy(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_detach(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_fire_action(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_focus(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_forget_layout_spring(widget: [*c]widget_h.rvn_widget_t, spring: [*c]const raven.RSpring) void;
pub extern fn rvn_widget_from_virtual(widget: [*c]const widget_h.rvn_widget_t, x: [*c]f32, y: [*c]f32) void;
pub extern fn rvn_widget_get(id: raven.Rid) [*c]widget_h.rvn_widget_t;
pub extern fn rvn_widget_has_color(widget: [*c]const widget_h.rvn_widget_t, role: raven.RColorRole) c_int;
pub extern fn rvn_widget_has_metric(widget: [*c]const widget_h.rvn_widget_t, metric: raven.RMetric) c_int;
pub extern fn rvn_widget_invalidate_layout(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_invalidate_paint(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_is_inside(widget: [*c]const widget_h.rvn_widget_t, ancestor: [*c]const widget_h.rvn_widget_t) c_int;
pub extern fn rvn_widget_is_shown(widget: [*c]const widget_h.rvn_widget_t) c_int;
pub extern fn rvn_widget_measure(widget: [*c]widget_h.rvn_widget_t) base.rvn_vec2_t;
pub extern fn rvn_widget_measure_slot(child: [*c]widget_h.rvn_widget_t) base.rvn_vec2_t;
pub extern fn rvn_widget_metric(widget: [*c]const widget_h.rvn_widget_t, metric: raven.RMetric) f32;
pub extern fn rvn_widget_origin(widget: [*c]const widget_h.rvn_widget_t) base.rvn_vec2_t;
pub extern fn rvn_widget_paint(widget: [*c]widget_h.rvn_widget_t, parent: ?*const raven.RPainter) void;
pub extern fn rvn_widget_play_transition(widget: [*c]widget_h.rvn_widget_t, transition: raven.RTransition, delay: f32) void;
pub extern fn rvn_widget_release_mouse(widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_widget_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int;
pub extern fn rvn_widget_set_color(widget: [*c]widget_h.rvn_widget_t, role: raven.RColorRole, color: base.rvn_color_t) void;
pub extern fn rvn_widget_set_theme(widget: [*c]widget_h.rvn_widget_t, theme: [*c]const context_h.rvn_theme_t, own: c_int) void;
pub extern fn rvn_widget_text_color(widget: [*c]const widget_h.rvn_widget_t, painter: ?*const raven.RPainter) base.rvn_color_t;
pub extern fn rvn_window_check(id: raven.Rid, function: [*c]const u8) [*c]widget_h.rvn_window_t;
pub extern fn rvn_window_close_dialog(inside: [*c]widget_h.rvn_widget_t, result: c_int) c_int;
pub extern fn rvn_window_close_popup(window: [*c]widget_h.rvn_window_t, root: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_window_close_popups(window: [*c]widget_h.rvn_window_t) void;
pub extern fn rvn_window_destroy(window: [*c]widget_h.rvn_window_t) void;
pub extern fn rvn_window_forget_widget(window: [*c]widget_h.rvn_window_t, widget: [*c]widget_h.rvn_widget_t) void;
pub extern fn rvn_window_get(id: raven.Rid) [*c]widget_h.rvn_window_t;
pub extern fn rvn_window_layout(window: [*c]widget_h.rvn_window_t) void;
pub extern fn rvn_window_open_dialog(window: [*c]widget_h.rvn_window_t, root: [*c]widget_h.rvn_widget_t, closed: raven.RDialogClosedCallback, user: ?*anyopaque) void;
pub extern fn rvn_window_open_popup(window: [*c]widget_h.rvn_window_t, root: [*c]widget_h.rvn_widget_t, owner: [*c]widget_h.rvn_widget_t, anchor: base.rvn_rect_t, placement: widget_h.rvn_popup_placement_t, min_width: f32) void;
pub extern fn rvn_window_pointer(window: [*c]const widget_h.rvn_window_t, x: [*c]f32, y: [*c]f32, buttons: [*c]u32) c_int;
pub extern fn rvn_window_popup_index(window: [*c]const widget_h.rvn_window_t, root: [*c]const widget_h.rvn_widget_t) c_int;
pub extern fn rvn_window_rearm_tooltip(window: [*c]widget_h.rvn_window_t) void;
pub extern fn rvn_window_request_close(window: [*c]widget_h.rvn_window_t) void;
pub extern fn rvn_window_see_through(window: [*c]const widget_h.rvn_window_t) c_int;
pub extern fn rvn_window_size(window: [*c]const widget_h.rvn_window_t) base.rvn_vec2_t;
pub extern fn rvn_window_toggle_maximized(window: [*c]widget_h.rvn_window_t) void;
pub extern fn rvn_window_top_dialog(window: [*c]const widget_h.rvn_window_t) [*c]widget_h.rvn_widget_t;
pub extern fn rvn_write_file(path: [*c]const u8, data: ?*const anyopaque, size: usize) c_int;
pub extern fn rvn_xml_attribute(node: [*c]const xml_h.rvn_xml_node_t, name: [*c]const u8) [*c]const u8;
pub extern fn rvn_xml_build_node(node: [*c]const xml_h.rvn_xml_node_t) [*c]widget_h.rvn_widget_t;
pub extern fn rvn_xml_resolve_path(path: [*c]const u8) [*c]u8;
