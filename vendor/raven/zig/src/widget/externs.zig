// Seridian: what the C files of src/widget use from OTHER modules, and where each of those declarations lives.
//
// Not a translation of a Raven file. Every function, global and constant that widget/*.c takes from another
// module is already declared by a header unit (`pub extern fn` / `pub extern var` / `pub inline fn` / `pub const`);
// translators of widget/*.c import those header units directly (never another translated .c file), e.g.
//     const ctx_h = @import("../core/context_h.zig");     // g_rvn, rvn_api_check, the theme/style structs...
// This file re-exports the header units under the aliases the MANIFEST uses, and its `comptime` block fails the
// build of any file that imports it if a name below disappears from its header unit: it is the checked list of the
// extern declarations the module needs. The widget module's OWN header unit is widget_h.zig.
//
// Needed from the system C library (declare through ../sys/libc.zig): memset, memcpy, strlen, strcmp, strncmp,
// snprintf, floorf/ceilf/sqrtf/fabsf (builtins), powf/fmodf/expf (libm), as each .c file includes <string.h>/<math.h>.
//
// Macros of the C headers with no function behind them (expand by hand in the translation):
//   RVN_API_GUARD(result)    -> if (ctx_h.rvn_api_check("<public fn name>") == 0) return result;   (core/context.h)
//   RVN_API_GUARD_VOID()     -> if (ctx_h.rvn_api_check("<public fn name>") == 0) return;
//   RVN_WINDOW(v, id, r) / RVN_WINDOW_VOID(v, id)       (window.c, local) -> rvn_window_check(id, "<fn>") + return
//   RVN_WIDGET(v, id, type, r) / RVN_WIDGET_VOID(v, id, type)   (widget.h)  -> rvn_widget_check(id, type, "<fn>") + return
//   RVN_COLOR_INDEX(role) / RVN_METRIC_INDEX(metric)    (style.c, theme.c, local) -> @as(c_int, role) - raven.R_COLOR_WINDOW ...
//   RVN_THEME_COLOR(role) / RVN_THEME_METRIC(metric)    (core/context.h) -> ctx_h.g_rvn.theme.colors[...] / .metrics[...]
//   RVN_COUNT_OF(a) -> a.len;  RVN_UNUSED(x) -> `_ = x;`

pub const widget_h = @import("widget_h.zig");

pub const base = @import("../core/base_h.zig");
pub const ctx_h = @import("../core/context_h.zig");
pub const handle_h = @import("../core/handle_h.zig");
pub const jobs_h = @import("../core/jobs_h.zig");
pub const thread_h = @import("../core/thread_h.zig");
pub const plat_h = @import("../platform/platform_h.zig");
pub const draw_h = @import("../render/draw_h.zig");
pub const font_h = @import("../render/font_h.zig");
pub const renderer_h = @import("../render/renderer_h.zig");
pub const common_h = @import("../widgets/common_h.zig");
pub const xml_h = @import("../xml/xml_h.zig");
pub const xml_watch_h = @import("../xml/xml_watch_h.zig");

comptime {
    // core/base_h.zig: 37 names
    if (!@hasDecl(base, "rvn_alloc")) @compileError("core/base_h.zig no longer declares rvn_alloc");
    if (!@hasDecl(base, "rvn_box")) @compileError("core/base_h.zig no longer declares rvn_box");
    if (!@hasDecl(base, "rvn_box_empty")) @compileError("core/base_h.zig no longer declares rvn_box_empty");
    if (!@hasDecl(base, "rvn_box_intersect")) @compileError("core/base_h.zig no longer declares rvn_box_intersect");
    if (!@hasDecl(base, "rvn_box_overlaps")) @compileError("core/base_h.zig no longer declares rvn_box_overlaps");
    if (!@hasDecl(base, "rvn_box_t")) @compileError("core/base_h.zig no longer declares rvn_box_t");
    if (!@hasDecl(base, "rvn_calloc")) @compileError("core/base_h.zig no longer declares rvn_calloc");
    if (!@hasDecl(base, "rvn_clampf")) @compileError("core/base_h.zig no longer declares rvn_clampf");
    if (!@hasDecl(base, "rvn_clampi")) @compileError("core/base_h.zig no longer declares rvn_clampi");
    if (!@hasDecl(base, "rvn_color_a")) @compileError("core/base_h.zig no longer declares rvn_color_a");
    if (!@hasDecl(base, "rvn_color_fade")) @compileError("core/base_h.zig no longer declares rvn_color_fade");
    if (!@hasDecl(base, "rvn_color_mix")) @compileError("core/base_h.zig no longer declares rvn_color_mix");
    if (!@hasDecl(base, "rvn_color_t")) @compileError("core/base_h.zig no longer declares rvn_color_t");
    if (!@hasDecl(base, "rvn_color_to_floats")) @compileError("core/base_h.zig no longer declares rvn_color_to_floats");
    if (!@hasDecl(base, "rvn_error")) @compileError("core/base_h.zig no longer declares rvn_error");
    if (!@hasDecl(base, "rvn_free")) @compileError("core/base_h.zig no longer declares rvn_free");
    if (!@hasDecl(base, "rvn_hex")) @compileError("core/base_h.zig no longer declares rvn_hex");
    if (!@hasDecl(base, "rvn_margin")) @compileError("core/base_h.zig no longer declares rvn_margin");
    if (!@hasDecl(base, "rvn_maxf")) @compileError("core/base_h.zig no longer declares rvn_maxf");
    if (!@hasDecl(base, "rvn_maxi")) @compileError("core/base_h.zig no longer declares rvn_maxi");
    if (!@hasDecl(base, "rvn_minf")) @compileError("core/base_h.zig no longer declares rvn_minf");
    if (!@hasDecl(base, "rvn_read_file")) @compileError("core/base_h.zig no longer declares rvn_read_file");
    if (!@hasDecl(base, "rvn_rect")) @compileError("core/base_h.zig no longer declares rvn_rect");
    if (!@hasDecl(base, "rvn_rect_inset")) @compileError("core/base_h.zig no longer declares rvn_rect_inset");
    if (!@hasDecl(base, "rvn_rect_t")) @compileError("core/base_h.zig no longer declares rvn_rect_t");
    if (!@hasDecl(base, "rvn_rgba")) @compileError("core/base_h.zig no longer declares rvn_rgba");
    if (!@hasDecl(base, "rvn_str_set")) @compileError("core/base_h.zig no longer declares rvn_str_set");
    if (!@hasDecl(base, "rvn_strdup")) @compileError("core/base_h.zig no longer declares rvn_strdup");
    if (!@hasDecl(base, "rvn_stricmp")) @compileError("core/base_h.zig no longer declares rvn_stricmp");
    if (!@hasDecl(base, "rvn_strndup")) @compileError("core/base_h.zig no longer declares rvn_strndup");
    if (!@hasDecl(base, "rvn_text_add")) @compileError("core/base_h.zig no longer declares rvn_text_add");
    if (!@hasDecl(base, "rvn_text_append")) @compileError("core/base_h.zig no longer declares rvn_text_append");
    if (!@hasDecl(base, "rvn_text_printf")) @compileError("core/base_h.zig no longer declares rvn_text_printf");
    if (!@hasDecl(base, "rvn_text_t")) @compileError("core/base_h.zig no longer declares rvn_text_t");
    if (!@hasDecl(base, "rvn_utf8_decode")) @compileError("core/base_h.zig no longer declares rvn_utf8_decode");
    if (!@hasDecl(base, "rvn_vec2")) @compileError("core/base_h.zig no longer declares rvn_vec2");
    if (!@hasDecl(base, "rvn_vec2_t")) @compileError("core/base_h.zig no longer declares rvn_vec2_t");
    // core/context_h.zig: 14 names
    if (!@hasDecl(ctx_h, "g_rvn")) @compileError("core/context_h.zig no longer declares g_rvn");
    if (!@hasDecl(ctx_h, "rvn_api_check")) @compileError("core/context_h.zig no longer declares rvn_api_check");
    if (!@hasDecl(ctx_h, "rvn_dispatch_begin")) @compileError("core/context_h.zig no longer declares rvn_dispatch_begin");
    if (!@hasDecl(ctx_h, "rvn_dispatch_end")) @compileError("core/context_h.zig no longer declares rvn_dispatch_end");
    if (!@hasDecl(ctx_h, "rvn_fire_action")) @compileError("core/context_h.zig no longer declares rvn_fire_action");
    if (!@hasDecl(ctx_h, "rvn_invalidate_all_windows")) @compileError("core/context_h.zig no longer declares rvn_invalidate_all_windows");
    if (!@hasDecl(ctx_h, "rvn_repaint_all_windows")) @compileError("core/context_h.zig no longer declares rvn_repaint_all_windows");
    if (!@hasDecl(ctx_h, "rvn_style_match_t")) @compileError("core/context_h.zig no longer declares rvn_style_match_t");
    if (!@hasDecl(ctx_h, "rvn_style_rule_t")) @compileError("core/context_h.zig no longer declares rvn_style_rule_t");
    if (!@hasDecl(ctx_h, "rvn_style_t")) @compileError("core/context_h.zig no longer declares rvn_style_t");
    if (!@hasDecl(ctx_h, "rvn_theme_t")) @compileError("core/context_h.zig no longer declares rvn_theme_t");
    if (!@hasDecl(ctx_h, "rvn_update")) @compileError("core/context_h.zig no longer declares rvn_update");
    if (!@hasDecl(ctx_h, "rvn_wake")) @compileError("core/context_h.zig no longer declares rvn_wake");
    if (!@hasDecl(ctx_h, "rvn_windows_theme_changed")) @compileError("core/context_h.zig no longer declares rvn_windows_theme_changed");
    // core/handle_h.zig: 5 names
    if (!@hasDecl(handle_h, "rvn_handle_type")) @compileError("core/handle_h.zig no longer declares rvn_handle_type");
    if (!@hasDecl(handle_h, "rvn_pool_add")) @compileError("core/handle_h.zig no longer declares rvn_pool_add");
    if (!@hasDecl(handle_h, "rvn_pool_at")) @compileError("core/handle_h.zig no longer declares rvn_pool_at");
    if (!@hasDecl(handle_h, "rvn_pool_get")) @compileError("core/handle_h.zig no longer declares rvn_pool_get");
    if (!@hasDecl(handle_h, "rvn_pool_remove")) @compileError("core/handle_h.zig no longer declares rvn_pool_remove");
    // core/jobs_h.zig: 4 names
    if (!@hasDecl(jobs_h, "rvn_job_group_t")) @compileError("core/jobs_h.zig no longer declares rvn_job_group_t");
    if (!@hasDecl(jobs_h, "rvn_jobs_submit")) @compileError("core/jobs_h.zig no longer declares rvn_jobs_submit");
    if (!@hasDecl(jobs_h, "rvn_jobs_wait")) @compileError("core/jobs_h.zig no longer declares rvn_jobs_wait");
    if (!@hasDecl(jobs_h, "rvn_jobs_worker_count")) @compileError("core/jobs_h.zig no longer declares rvn_jobs_worker_count");
    // core/thread_h.zig: 11 names
    if (!@hasDecl(thread_h, "rvn_atomic_add")) @compileError("core/thread_h.zig no longer declares rvn_atomic_add");
    if (!@hasDecl(thread_h, "rvn_atomic_exchange")) @compileError("core/thread_h.zig no longer declares rvn_atomic_exchange");
    if (!@hasDecl(thread_h, "rvn_atomic_load")) @compileError("core/thread_h.zig no longer declares rvn_atomic_load");
    if (!@hasDecl(thread_h, "rvn_atomic_store")) @compileError("core/thread_h.zig no longer declares rvn_atomic_store");
    if (!@hasDecl(thread_h, "rvn_atomic_t")) @compileError("core/thread_h.zig no longer declares rvn_atomic_t");
    if (!@hasDecl(thread_h, "rvn_clock_seconds")) @compileError("core/thread_h.zig no longer declares rvn_clock_seconds");
    if (!@hasDecl(thread_h, "rvn_mutex_destroy")) @compileError("core/thread_h.zig no longer declares rvn_mutex_destroy");
    if (!@hasDecl(thread_h, "rvn_mutex_init")) @compileError("core/thread_h.zig no longer declares rvn_mutex_init");
    if (!@hasDecl(thread_h, "rvn_mutex_lock")) @compileError("core/thread_h.zig no longer declares rvn_mutex_lock");
    if (!@hasDecl(thread_h, "rvn_mutex_t")) @compileError("core/thread_h.zig no longer declares rvn_mutex_t");
    if (!@hasDecl(thread_h, "rvn_mutex_unlock")) @compileError("core/thread_h.zig no longer declares rvn_mutex_unlock");
    // platform/platform_h.zig: 3 names
    if (!@hasDecl(plat_h, "rvn_pevent_t")) @compileError("platform/platform_h.zig no longer declares rvn_pevent_t");
    if (!@hasDecl(plat_h, "rvn_pregion_t")) @compileError("platform/platform_h.zig no longer declares rvn_pregion_t");
    if (!@hasDecl(plat_h, "rvn_pwindow_desc_t")) @compileError("platform/platform_h.zig no longer declares rvn_pwindow_desc_t");
    // render/draw_h.zig: 19 names
    if (!@hasDecl(draw_h, "rvn_drawlist_append_commands")) @compileError("render/draw_h.zig no longer declares rvn_drawlist_append_commands");
    if (!@hasDecl(draw_h, "rvn_drawlist_free")) @compileError("render/draw_h.zig no longer declares rvn_drawlist_free");
    if (!@hasDecl(draw_h, "rvn_drawlist_init")) @compileError("render/draw_h.zig no longer declares rvn_drawlist_init");
    if (!@hasDecl(draw_h, "rvn_drawlist_reset")) @compileError("render/draw_h.zig no longer declares rvn_drawlist_reset");
    if (!@hasDecl(draw_h, "rvn_drawlist_resolve_backdrops")) @compileError("render/draw_h.zig no longer declares rvn_drawlist_resolve_backdrops");
    if (!@hasDecl(draw_h, "rvn_drawlist_t")) @compileError("render/draw_h.zig no longer declares rvn_drawlist_t");
    if (!@hasDecl(draw_h, "rvn_drawlist_transform")) @compileError("render/draw_h.zig no longer declares rvn_drawlist_transform");
    if (!@hasDecl(draw_h, "rvn_glass_t")) @compileError("render/draw_h.zig no longer declares rvn_glass_t");
    if (!@hasDecl(draw_h, "rvn_paint_box")) @compileError("render/draw_h.zig no longer declares rvn_paint_box");
    if (!@hasDecl(draw_h, "rvn_paint_glass")) @compileError("render/draw_h.zig no longer declares rvn_paint_glass");
    if (!@hasDecl(draw_h, "rvn_paint_image")) @compileError("render/draw_h.zig no longer declares rvn_paint_image");
    if (!@hasDecl(draw_h, "rvn_paint_rect")) @compileError("render/draw_h.zig no longer declares rvn_paint_rect");
    if (!@hasDecl(draw_h, "rvn_paint_shadow")) @compileError("render/draw_h.zig no longer declares rvn_paint_shadow");
    if (!@hasDecl(draw_h, "rvn_paint_snap")) @compileError("render/draw_h.zig no longer declares rvn_paint_snap");
    if (!@hasDecl(draw_h, "rvn_paint_spring_from")) @compileError("render/draw_h.zig no longer declares rvn_paint_spring_from");
    if (!@hasDecl(draw_h, "rvn_paint_text")) @compileError("render/draw_h.zig no longer declares rvn_paint_text");
    if (!@hasDecl(draw_h, "rvn_paint_text_in")) @compileError("render/draw_h.zig no longer declares rvn_paint_text_in");
    if (!@hasDecl(draw_h, "rvn_spring_moving")) @compileError("render/draw_h.zig no longer declares rvn_spring_moving");
    if (!@hasDecl(draw_h, "rvn_spring_set")) @compileError("render/draw_h.zig no longer declares rvn_spring_set");
    // render/font_h.zig: 8 names
    if (!@hasDecl(font_h, "rvn_a11y_text_scale")) @compileError("render/font_h.zig no longer declares rvn_a11y_text_scale");
    if (!@hasDecl(font_h, "rvn_font_metrics")) @compileError("render/font_h.zig no longer declares rvn_font_metrics");
    if (!@hasDecl(font_h, "rvn_font_metrics_t")) @compileError("render/font_h.zig no longer declares rvn_font_metrics_t");
    if (!@hasDecl(font_h, "rvn_font_resolve")) @compileError("render/font_h.zig no longer declares rvn_font_resolve");
    if (!@hasDecl(font_h, "rvn_font_t")) @compileError("render/font_h.zig no longer declares rvn_font_t");
    if (!@hasDecl(font_h, "rvn_fonts_flush")) @compileError("render/font_h.zig no longer declares rvn_fonts_flush");
    if (!@hasDecl(font_h, "rvn_fonts_resolve_pages")) @compileError("render/font_h.zig no longer declares rvn_fonts_resolve_pages");
    if (!@hasDecl(font_h, "rvn_text_width")) @compileError("render/font_h.zig no longer declares rvn_text_width");
    // render/renderer_h.zig: 10 names
    if (!@hasDecl(renderer_h, "rvn_frame_t")) @compileError("render/renderer_h.zig no longer declares rvn_frame_t");
    if (!@hasDecl(renderer_h, "rvn_renderer_acquire_frame")) @compileError("render/renderer_h.zig no longer declares rvn_renderer_acquire_frame");
    if (!@hasDecl(renderer_h, "rvn_renderer_create_surface")) @compileError("render/renderer_h.zig no longer declares rvn_renderer_create_surface");
    if (!@hasDecl(renderer_h, "rvn_renderer_destroy_surface")) @compileError("render/renderer_h.zig no longer declares rvn_renderer_destroy_surface");
    if (!@hasDecl(renderer_h, "rvn_renderer_submit_frame")) @compileError("render/renderer_h.zig no longer declares rvn_renderer_submit_frame");
    if (!@hasDecl(renderer_h, "rvn_renderer_sync")) @compileError("render/renderer_h.zig no longer declares rvn_renderer_sync");
    if (!@hasDecl(renderer_h, "rvn_renderer_throttle")) @compileError("render/renderer_h.zig no longer declares rvn_renderer_throttle");
    if (!@hasDecl(renderer_h, "rvn_texture_create_raw")) @compileError("render/renderer_h.zig no longer declares rvn_texture_create_raw");
    if (!@hasDecl(renderer_h, "rvn_texture_get")) @compileError("render/renderer_h.zig no longer declares rvn_texture_get");
    if (!@hasDecl(renderer_h, "rvn_texture_t")) @compileError("render/renderer_h.zig no longer declares rvn_texture_t");
    // widgets/common_h.zig: 52 names
    if (!@hasDecl(common_h, "rvn_class_background_blur")) @compileError("widgets/common_h.zig no longer declares rvn_class_background_blur");
    if (!@hasDecl(common_h, "rvn_class_block_editor")) @compileError("widgets/common_h.zig no longer declares rvn_class_block_editor");
    if (!@hasDecl(common_h, "rvn_class_border")) @compileError("widgets/common_h.zig no longer declares rvn_class_border");
    if (!@hasDecl(common_h, "rvn_class_button")) @compileError("widgets/common_h.zig no longer declares rvn_class_button");
    if (!@hasDecl(common_h, "rvn_class_canvas")) @compileError("widgets/common_h.zig no longer declares rvn_class_canvas");
    if (!@hasDecl(common_h, "rvn_class_checkbox")) @compileError("widgets/common_h.zig no longer declares rvn_class_checkbox");
    if (!@hasDecl(common_h, "rvn_class_color_picker")) @compileError("widgets/common_h.zig no longer declares rvn_class_color_picker");
    if (!@hasDecl(common_h, "rvn_class_combo_box")) @compileError("widgets/common_h.zig no longer declares rvn_class_combo_box");
    if (!@hasDecl(common_h, "rvn_class_custom")) @compileError("widgets/common_h.zig no longer declares rvn_class_custom");
    if (!@hasDecl(common_h, "rvn_class_dock_area")) @compileError("widgets/common_h.zig no longer declares rvn_class_dock_area");
    if (!@hasDecl(common_h, "rvn_class_expander")) @compileError("widgets/common_h.zig no longer declares rvn_class_expander");
    if (!@hasDecl(common_h, "rvn_class_file_browser")) @compileError("widgets/common_h.zig no longer declares rvn_class_file_browser");
    if (!@hasDecl(common_h, "rvn_class_grid")) @compileError("widgets/common_h.zig no longer declares rvn_class_grid");
    if (!@hasDecl(common_h, "rvn_class_hbox")) @compileError("widgets/common_h.zig no longer declares rvn_class_hbox");
    if (!@hasDecl(common_h, "rvn_class_header_bar")) @compileError("widgets/common_h.zig no longer declares rvn_class_header_bar");
    if (!@hasDecl(common_h, "rvn_class_image")) @compileError("widgets/common_h.zig no longer declares rvn_class_image");
    if (!@hasDecl(common_h, "rvn_class_island")) @compileError("widgets/common_h.zig no longer declares rvn_class_island");
    if (!@hasDecl(common_h, "rvn_class_label")) @compileError("widgets/common_h.zig no longer declares rvn_class_label");
    if (!@hasDecl(common_h, "rvn_class_list_view")) @compileError("widgets/common_h.zig no longer declares rvn_class_list_view");
    if (!@hasDecl(common_h, "rvn_class_menu")) @compileError("widgets/common_h.zig no longer declares rvn_class_menu");
    if (!@hasDecl(common_h, "rvn_class_menu_bar")) @compileError("widgets/common_h.zig no longer declares rvn_class_menu_bar");
    if (!@hasDecl(common_h, "rvn_class_menu_item")) @compileError("widgets/common_h.zig no longer declares rvn_class_menu_item");
    if (!@hasDecl(common_h, "rvn_class_node_graph")) @compileError("widgets/common_h.zig no longer declares rvn_class_node_graph");
    if (!@hasDecl(common_h, "rvn_class_overlay")) @compileError("widgets/common_h.zig no longer declares rvn_class_overlay");
    if (!@hasDecl(common_h, "rvn_class_progress_bar")) @compileError("widgets/common_h.zig no longer declares rvn_class_progress_bar");
    if (!@hasDecl(common_h, "rvn_class_scroll_box")) @compileError("widgets/common_h.zig no longer declares rvn_class_scroll_box");
    if (!@hasDecl(common_h, "rvn_class_separator")) @compileError("widgets/common_h.zig no longer declares rvn_class_separator");
    if (!@hasDecl(common_h, "rvn_class_size_box")) @compileError("widgets/common_h.zig no longer declares rvn_class_size_box");
    if (!@hasDecl(common_h, "rvn_class_slider")) @compileError("widgets/common_h.zig no longer declares rvn_class_slider");
    if (!@hasDecl(common_h, "rvn_class_spacer")) @compileError("widgets/common_h.zig no longer declares rvn_class_spacer");
    if (!@hasDecl(common_h, "rvn_class_spin_box")) @compileError("widgets/common_h.zig no longer declares rvn_class_spin_box");
    if (!@hasDecl(common_h, "rvn_class_splitter")) @compileError("widgets/common_h.zig no longer declares rvn_class_splitter");
    if (!@hasDecl(common_h, "rvn_class_switcher")) @compileError("widgets/common_h.zig no longer declares rvn_class_switcher");
    if (!@hasDecl(common_h, "rvn_class_tab_view")) @compileError("widgets/common_h.zig no longer declares rvn_class_tab_view");
    if (!@hasDecl(common_h, "rvn_class_text_editor")) @compileError("widgets/common_h.zig no longer declares rvn_class_text_editor");
    if (!@hasDecl(common_h, "rvn_class_text_input")) @compileError("widgets/common_h.zig no longer declares rvn_class_text_input");
    if (!@hasDecl(common_h, "rvn_class_tile_view")) @compileError("widgets/common_h.zig no longer declares rvn_class_tile_view");
    if (!@hasDecl(common_h, "rvn_class_timeline")) @compileError("widgets/common_h.zig no longer declares rvn_class_timeline");
    if (!@hasDecl(common_h, "rvn_class_tree_view")) @compileError("widgets/common_h.zig no longer declares rvn_class_tree_view");
    if (!@hasDecl(common_h, "rvn_class_uniform_grid")) @compileError("widgets/common_h.zig no longer declares rvn_class_uniform_grid");
    if (!@hasDecl(common_h, "rvn_class_vbox")) @compileError("widgets/common_h.zig no longer declares rvn_class_vbox");
    if (!@hasDecl(common_h, "rvn_class_viewport")) @compileError("widgets/common_h.zig no longer declares rvn_class_viewport");
    if (!@hasDecl(common_h, "rvn_class_wrap_box")) @compileError("widgets/common_h.zig no longer declares rvn_class_wrap_box");
    if (!@hasDecl(common_h, "rvn_glass_style")) @compileError("widgets/common_h.zig no longer declares rvn_glass_style");
    if (!@hasDecl(common_h, "rvn_islands_pressed")) @compileError("widgets/common_h.zig no longer declares rvn_islands_pressed");
    if (!@hasDecl(common_h, "rvn_paint_surface")) @compileError("widgets/common_h.zig no longer declares rvn_paint_surface");
    if (!@hasDecl(common_h, "rvn_token_t")) @compileError("widgets/common_h.zig no longer declares rvn_token_t");
    if (!@hasDecl(common_h, "rvn_widget_class_t")) @compileError("widgets/common_h.zig no longer declares rvn_widget_class_t");
    if (!@hasDecl(common_h, "rvn_widget_t")) @compileError("widgets/common_h.zig no longer declares rvn_widget_t");
    if (!@hasDecl(common_h, "rvn_window_t")) @compileError("widgets/common_h.zig no longer declares rvn_window_t");
    if (!@hasDecl(common_h, "rvn_xml_font")) @compileError("widgets/common_h.zig no longer declares rvn_xml_font");
    if (!@hasDecl(common_h, "rvn_xml_texture")) @compileError("widgets/common_h.zig no longer declares rvn_xml_texture");
    // xml/xml_h.zig: 9 names
    if (!@hasDecl(xml_h, "rvn_xml_attribute")) @compileError("xml/xml_h.zig no longer declares rvn_xml_attribute");
    if (!@hasDecl(xml_h, "rvn_xml_attribute_t")) @compileError("xml/xml_h.zig no longer declares rvn_xml_attribute_t");
    if (!@hasDecl(xml_h, "rvn_xml_document_t")) @compileError("xml/xml_h.zig no longer declares rvn_xml_document_t");
    if (!@hasDecl(xml_h, "rvn_xml_free")) @compileError("xml/xml_h.zig no longer declares rvn_xml_free");
    if (!@hasDecl(xml_h, "rvn_xml_node_t")) @compileError("xml/xml_h.zig no longer declares rvn_xml_node_t");
    if (!@hasDecl(xml_h, "rvn_xml_parse")) @compileError("xml/xml_h.zig no longer declares rvn_xml_parse");
    if (!@hasDecl(xml_h, "rvn_xml_pop_file_dir")) @compileError("xml/xml_h.zig no longer declares rvn_xml_pop_file_dir");
    if (!@hasDecl(xml_h, "rvn_xml_push_file_dir")) @compileError("xml/xml_h.zig no longer declares rvn_xml_push_file_dir");
    if (!@hasDecl(xml_h, "rvn_xml_resolve_path")) @compileError("xml/xml_h.zig no longer declares rvn_xml_resolve_path");
    // xml/xml_watch_h.zig: 2 names
    if (!@hasDecl(xml_watch_h, "rvn_watch_add")) @compileError("xml/xml_watch_h.zig no longer declares rvn_watch_add");
    if (!@hasDecl(xml_watch_h, "rvn_watch_quiet")) @compileError("xml/xml_watch_h.zig no longer declares rvn_watch_quiet");
}
