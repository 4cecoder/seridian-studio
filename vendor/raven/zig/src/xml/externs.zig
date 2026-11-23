// Seridian: extern declarations the xml module needs from OTHER modules of Raven (not a translation of a Raven file).
//
//   const ext = @import("externs.zig");     // from src/xml/*.zig
//
// What other modules already provide as header units is RE-EXPORTED here (core/context_h, handle_h, fs_h, fs_watch_h,
// base_h, raven.zig), so a translation of an xml file needs one import for all of it. What has no header unit yet
// (widget/widget.h, widgets/common.h) is declared here with the exact C prototypes; its structs are OPAQUE placeholders.
// The xml files read fields of rvn_widget_t / rvn_window_t / rvn_widget_class_t (widget->flags, window->root...):
// they need widget/widget_h.zig. When it exists, replace the three placeholder structs below by
// `@import("../widget/widget_h.zig").rvn_widget_t` etc. (the pointer types of every prototype follow).

const raven = @import("raven");
pub const base = @import("../core/base_h.zig");
pub const context = @import("../core/context_h.zig");
pub const handle = @import("../core/handle_h.zig");
pub const fs = @import("../core/fs_h.zig");
pub const fs_watch = @import("../core/fs_watch_h.zig");

// ---- placeholders for widget/widget.h ----
pub const rvn_widget_t = extern struct { _placeholder: u8 };
pub const rvn_window_t = extern struct { _placeholder: u8 };
pub const rvn_widget_class_t = extern struct { _placeholder: u8 };
pub const rvn_theme_t = context.rvn_theme_t;

// ---- widget/widget.h ----
pub extern fn rvn_widget_get(id: raven.Rid) [*c]rvn_widget_t;
pub extern fn rvn_widget_check(id: raven.Rid, @"type": raven.RWidgetType, function: [*c]const u8) [*c]rvn_widget_t;
pub extern fn rvn_widget_class_by_name(name: [*c]const u8) [*c]const rvn_widget_class_t;
pub extern fn rvn_widget_create(@"type": raven.RWidgetType) [*c]rvn_widget_t;
pub extern fn rvn_widget_destroy(widget: [*c]rvn_widget_t) void;
pub extern fn rvn_widget_add_child(parent: [*c]rvn_widget_t, child: [*c]rvn_widget_t, index: c_int) void;
pub extern fn rvn_widget_child_index(parent: [*c]const rvn_widget_t, child: [*c]const rvn_widget_t) c_int;
pub extern fn rvn_widget_invalidate_layout(widget: [*c]rvn_widget_t) void;
pub extern fn rvn_widget_invalidate_paint(widget: [*c]rvn_widget_t) void;
pub extern fn rvn_widget_set_appear(widget: [*c]rvn_widget_t, transition: [*c]const raven.RTransition, delay: [*c]const f32) void;
pub extern fn rvn_widget_set_color(widget: [*c]rvn_widget_t, role: raven.RColorRole, color: base.rvn_color_t) void;
pub extern fn rvn_widget_set_metric(widget: [*c]rvn_widget_t, metric: raven.RMetric, value: f32) void;
pub extern fn rvn_widget_set_theme(widget: [*c]rvn_widget_t, theme: [*c]const rvn_theme_t, own: c_int) void;
pub extern fn rvn_window_get(id: raven.Rid) [*c]rvn_window_t;
pub extern fn rvn_window_forget_widget(window: [*c]rvn_window_t, widget: [*c]rvn_widget_t) void;
pub extern fn rvn_window_add_shortcut(window: [*c]rvn_window_t, key: raven.RKey, modifiers: u32, action: [*c]const u8) void;
pub extern fn rvn_window_remove_shortcut(window: [*c]rvn_window_t, key: raven.RKey, modifiers: u32) void;
pub extern fn rvn_a11y_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int;
pub extern fn rvn_a11y_structure_changed() void;
pub extern fn rvn_locale_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8, result: [*c]c_int) c_int;
pub extern fn rvn_parse_shortcut(text: [*c]const u8, key: [*c]raven.RKey, modifiers: [*c]u32) c_int;
pub extern fn rvn_parse_transition(text: [*c]const u8, transition: [*c]raven.RTransition) c_int;

// ---- widgets/common.h ----
pub extern fn rvn_xml_theme(value: [*c]const u8) [*c]const rvn_theme_t;

// ---- widget/widget.h and widgets/common.h declare these, but xml_attributes.c / xml_loader.c DEFINE them
//      (their Zig prototypes are in MANIFEST.md; the other modules call them through the header unit of widget.h / common.h) ----
pub extern fn rvn_xml_texture(path: [*c]const u8) raven.Rid;
pub extern fn rvn_xml_font(path: [*c]const u8) raven.Rid;
pub extern fn rvn_xml_shutdown() void;
