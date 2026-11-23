// Seridian: extern declarations of the functions of OTHER modules that the core/*.c files call
// (found with nm -u on the C objects, minus the symbols core defines). Not a translation of a Raven file.
//
//   const ext = @import("externs.zig");     // from src/core/*.zig
//   ext.rvn_fonts_init();
//
// Public functions (R...) are in @import("raven"); core's own functions are in the *_h.zig header units;
// libc is in ../sys/libc.zig. Everything here is a private function of the widget / render / platform / xml / widgets
// modules. When one of those modules gets its own header unit (widget_h.zig, renderer_h.zig, platform_h.zig...),
// the declaration there is the same symbol: an extern fn declared twice is fine, both resolve to the one definition.
//
// Types that belong to another module and have no header unit yet are passed as opaque pointers:
//   rvn_widget_t*, rvn_window_t*  -> ?*anyopaque / ?*const anyopaque
//   rvn_platform_t*, rvn_pevent_t* -> ?*const anyopaque
//   rvn_pregion_t (enum)          -> c_uint
// Cast with @ptrCast(@alignCast(p)) once the real struct is known (field access of rvn_widget_t in accessibility.c
// needs widget_h.zig: ask for that header unit).

const raven = @import("raven");
const base = @import("base_h.zig");

// ---- render/renderer.h ----
pub extern fn rvn_backend_null() [*c]const raven.RBackendVTable;
pub extern fn rvn_backend_vulkan() [*c]const raven.RBackendVTable;
pub extern fn rvn_renderer_init(backend: [*c]const raven.RBackendVTable, info: [*c]const raven.RBackendInitInfo, threaded: c_int) c_int;
pub extern fn rvn_renderer_shutdown() void;
pub extern fn rvn_renderer_set_wait_service(service: ?*const fn () callconv(.c) void) void;
pub extern fn rvn_shaders_shutdown() void;
pub extern fn rvn_textures_shutdown() void;

// ---- render/font.h ----
pub extern fn rvn_fonts_init() void;
pub extern fn rvn_fonts_shutdown() void;

// ---- platform/platform.h ----
/// const rvn_platform_t* rvn_platform_select(int headless);
pub extern fn rvn_platform_select(headless: c_int) ?*const anyopaque;

// ---- widget/widget.h ----
pub extern fn rvn_direction_refresh() void;
pub extern fn rvn_paint_init() void;
pub extern fn rvn_paint_shutdown() void;
pub extern fn rvn_parse_bool(text: [*c]const u8, value: [*c]c_int) c_int;
pub extern fn rvn_theme_apply(theme: raven.RTheme) void;
pub extern fn rvn_theme_changed() void;
pub extern fn rvn_themes_init() void;
pub extern fn rvn_themes_shutdown() void;
/// rvn_widget_t* rvn_widget_check(Rid id, RWidgetType type, const char* function);
pub extern fn rvn_widget_check(id: raven.Rid, type_: raven.RWidgetType, function: [*c]const u8) ?*anyopaque;
/// void rvn_widget_destroy(rvn_widget_t* widget);
pub extern fn rvn_widget_destroy(widget: ?*anyopaque) void;
/// void rvn_widget_focus(rvn_widget_t* widget);
pub extern fn rvn_widget_focus(widget: ?*anyopaque) void;
/// rvn_widget_t* rvn_widget_get(Rid id);
pub extern fn rvn_widget_get(id: raven.Rid) ?*anyopaque;
/// rvn_vec2_t rvn_widget_origin(const rvn_widget_t* widget);
pub extern fn rvn_widget_origin(widget: ?*const anyopaque) base.rvn_vec2_t;
/// int rvn_widget_set_attribute(rvn_widget_t* widget, const char* name, const char* value);
pub extern fn rvn_widget_set_attribute(widget: ?*anyopaque, name: [*c]const u8, value: [*c]const u8) c_int;
pub extern fn rvn_widgets_collect() void;
/// void rvn_window_on_platform_event(const rvn_pevent_t* event);
pub extern fn rvn_window_on_platform_event(event: ?*const anyopaque) void;
/// rvn_pregion_t rvn_window_region_at(void* user, int x, int y);   (rvn_pregion_t is an enum: c_uint)
pub extern fn rvn_window_region_at(user: ?*anyopaque, x: c_int, y: c_int) c_uint;
/// rvn_vec2_t rvn_window_size(const rvn_window_t* window);
pub extern fn rvn_window_size(window: ?*const anyopaque) base.rvn_vec2_t;
/// void rvn_window_update(rvn_window_t* window);
pub extern fn rvn_window_update(window: ?*anyopaque) void;
/// int rvn_window_wants_frame(rvn_window_t* window);
pub extern fn rvn_window_wants_frame(window: ?*anyopaque) c_int;
pub extern fn rvn_windows_collect() void;
pub extern fn rvn_windows_destroy_all() void;
pub extern fn rvn_windows_throttle() void;

// ---- widgets/common.h ----
pub extern fn rvn_dialogs_shutdown() void;
pub extern fn rvn_islands_shutdown() void;
pub extern fn rvn_languages_shutdown() void;
pub extern fn rvn_xml_shutdown() void;

// ---- xml/xml_watch.h ----
/// typedef int (*rvn_watch_callback_t)(const char* path, void* user);
pub const rvn_watch_callback_t = ?*const fn (path: [*c]const u8, user: ?*anyopaque) callconv(.c) c_int;
pub extern fn rvn_watch_add(path: [*c]const u8, callback: rvn_watch_callback_t, user: ?*anyopaque) void;

// Also called by core but declared in core/context.h (see context_h.zig): rvn_invalidate_all_windows,
// rvn_repaint_all_windows (implemented in widget/window.c).
// Public functions called by core: Rcheckbox_*, Rlist_view_*, Rslider_*, Rtree_view_*, Rtheme_*, Rwidget_get_type, ...
// (accessibility.c), Rxml_get_live_reload (locale.c), Ris_initialized (memory.c): all in @import("raven").

// ---- implemented in core, declared in headers of other modules (widget/widget.h, widgets/common.h, ...) ----
// The same symbols the core files export: declared here so that the other core files can call them.
// core/accessibility.c
/// float rvn_a11y_text_scale(void)
pub extern fn rvn_a11y_text_scale() f32;
/// int rvn_a11y_focus_always(void)
pub extern fn rvn_a11y_focus_always() c_int;
/// float rvn_a11y_focus_width(void)
pub extern fn rvn_a11y_focus_width() f32;
/// void rvn_a11y_structure_changed(void)
pub extern fn rvn_a11y_structure_changed() void;
/// void rvn_a11y_widget_destroyed(rvn_widget_t* widget)
pub extern fn rvn_a11y_widget_destroyed(widget: ?*anyopaque) void;
/// void rvn_a11y_shutdown(void)
pub extern fn rvn_a11y_shutdown() void;
/// void rvn_a11y_filter_instances(RDrawInstance* instances, uint32_t count)
pub extern fn rvn_a11y_filter_instances(instances: [*c]raven.RDrawInstance, count: u32) void;
/// void rvn_a11y_frame(rvn_window_t* window)
pub extern fn rvn_a11y_frame(window: ?*anyopaque) void;
/// int rvn_a11y_attribute(rvn_widget_t* widget, const char* name, const char* value)
pub extern fn rvn_a11y_attribute(widget: ?*anyopaque, name: [*c]const u8, value: [*c]const u8) c_int;
// core/locale.c
/// int rvn_locale_attribute(rvn_widget_t* widget, const char* name, const char* value, int* result)
pub extern fn rvn_locale_attribute(widget: ?*anyopaque, name: [*c]const u8, value: [*c]const u8, result: [*c]c_int) c_int;
/// int rvn_locale_code_is_rtl(const char* code)
pub extern fn rvn_locale_code_is_rtl(code: [*c]const u8) c_int;
/// int rvn_locale_rtl(void)
pub extern fn rvn_locale_rtl() c_int;
/// void rvn_locale_shutdown(void)
pub extern fn rvn_locale_shutdown() void;
// core/context.c (declared by a local prototype at the top of context.c)
/// void rvn_tasks_run(void);
pub extern fn rvn_tasks_run() void;
