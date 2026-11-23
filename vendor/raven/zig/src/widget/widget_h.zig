// Translated to Zig from vendor/raven/src/widget/widget.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/widget.h
// Internal widget and window model shared by the widget core and by every
// widget implementation in src/widgets/.
//
// A widget type is a rvn_widget_class_t (a table of functions) plus a
// structure whose first member is rvn_widget_t. To add a widget type:
//   1. add its value to RWidgetType,
//   2. write src/widgets/<name>.c defining its structure and class,
//   3. list the class in widget/registry.c.
//
// In a translation:   const widget_h = @import("widget_h.zig");   (or "../widget/widget_h.zig" from another folder)
// The types of core/context.h, platform/platform.h, core/thread.h and xml/xml.h that widget.h relies on come from
// their own header units (ctx_h, plat_h, thread_h, xml_h below); they are not re-exported here.
//
// The macros RVN_WIDGET(variable, id, type, result) and RVN_WIDGET_VOID(variable, id, type) have no Zig
// counterpart; expand them by hand (C's __func__ is the name of the public function written as a string):
//     const w = widget_h.rvn_widget_check(id, type_, "Rwidget_xxx");
//     if (w == null) return result;      // RVN_WIDGET_VOID: `return;`

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const thread_h = @import("../core/thread_h.zig");
const plat_h = @import("../platform/platform_h.zig");
const xml_h = @import("../xml/xml_h.zig");

// ---------------------------------------------------------------------------
//  Flags
// ---------------------------------------------------------------------------

// widget state (rvn_widget_t::flags)
/// desired size must be recomputed
pub const RVN_WF_MEASURE_DIRTY: u32 = 1 << 0;
/// children must be placed again
pub const RVN_WF_ARRANGE_DIRTY: u32 = 1 << 1;
pub const RVN_WF_DISABLED: u32 = 1 << 2;
/// the widget itself ignores the mouse (children do not)
pub const RVN_WF_NO_HIT: u32 = 1 << 3;
/// children are clipped to the bounds
pub const RVN_WF_CLIP: u32 = 1 << 4;
pub const RVN_WF_FOCUSABLE: u32 = 1 << 5;
/// the cursor is over the widget or a descendant
pub const RVN_WF_HOVERED: u32 = 1 << 6;
/// set by widgets while a click is in progress
pub const RVN_WF_PRESSED: u32 = 1 << 7;
pub const RVN_WF_FOCUSED: u32 = 1 << 8;
/// deleted, memory released at the end of the dispatch
pub const RVN_WF_DEAD: u32 = 1 << 9;
/// shown as a popup: rect is in window coordinates
pub const RVN_WF_POPUP: u32 = 1 << 10;
/// owned by another widget without being its child
pub const RVN_WF_INTERNAL: u32 = 1 << 11;
/// part of the title bar of a window with a custom header
pub const RVN_WF_WINDOW_DRAG: u32 = 1 << 12;
pub const RVN_WF_LAYOUT_DIRTY: u32 = RVN_WF_MEASURE_DIRTY | RVN_WF_ARRANGE_DIRTY;

// class traits (rvn_widget_class_t::flags)
/// adding a child replaces the previous one
pub const RVN_CF_SINGLE_CHILD: u32 = 1 << 0;
pub const RVN_CF_NO_CHILDREN: u32 = 1 << 1;
/// children may lie outside the bounds (no culling by bounds)
pub const RVN_CF_OVERFLOW: u32 = 1 << 2;
/// paint calls application code: UI thread only
pub const RVN_CF_UI_PAINT: u32 = 1 << 3;
/// instances start with RVN_WF_NO_HIT
pub const RVN_CF_NO_HIT: u32 = 1 << 4;
/// instances start with RVN_WF_FOCUSABLE
pub const RVN_CF_FOCUSABLE: u32 = 1 << 5;
/// instances start with RVN_WF_CLIP
pub const RVN_CF_CLIP: u32 = 1 << 6;
/// draws its own surface, in the material of the widget
pub const RVN_CF_SURFACE: u32 = 1 << 7;
/// paints its children itself, from its paint function
pub const RVN_CF_OWN_CHILDREN: u32 = 1 << 8;
/// a surface of its own: its children are not mirrored in a right-to-left layout
pub const RVN_CF_NO_MIRROR: u32 = 1 << 9;

// ---------------------------------------------------------------------------
//  Widget
// ---------------------------------------------------------------------------

/// Accessibility record of a widget: defined privately by core/accessibility.c.
pub const rvn_a11y_t = opaque {};

/// How a child is placed by its parent (see Rslot_set_... in raven_widget.h).
pub const rvn_slot_t = extern struct {
    padding: base.rvn_margin_t,
    halign: raven.RHAlign,
    valign: raven.RVAlign,
    /// R_TRUE = fill with coefficient `fill`, R_FALSE = auto.
    is_fill: c_int,
    fill: f32,
    max_size: f32,
    column: c_int,
    row: c_int,
    column_span: c_int,
    row_span: c_int,
    /// Canvas: min x, min y, max x, max y.
    anchors: [4]f32,
    position: [2]f32,
    size: [2]f32,
    alignment: [2]f32,
    title: [*c]u8,
    /// Dock area: where the panel goes when it is added (0 = behind the first tabs), next to which panel, taking how much.
    dock: raven.RDockSide,
    dock_to: [*c]u8,
    dock_size: f32,
    /// Dock area: R_TRUE removes the close button of the panel.
    dock_fixed: c_int,
    /// Dock area: icon drawn before the title of the tab (Rdock_area_set_panel_icon).
    has_icon: c_int,
    icon: raven.Rid,
    icon_uv: [4]f32,
    /// R_TRUE: the icon is a mask drawn in the text color of the tab.
    icon_tint: c_int,
};
pub const struct_rvn_slot_t = rvn_slot_t;

/// Transition of a widget: the one it plays when it appears, and the one playing now.
pub const rvn_fx_t = extern struct {
    appear: raven.RTransition,
    appear_delay: f32,
    playing_kind: raven.RTransition,
    playing: c_int,
    /// Seconds left before the transition starts (staggered groups).
    delay: f32,
    /// 0 = where the transition starts, 1 = in place.
    progress: raven.RSpring,
};
pub const struct_rvn_fx_t = rvn_fx_t;

/// Geometry applied to everything a widget and its subtree drew, after the
/// fact (rvn_drawlist_transform). A class sets it from its paint function to
/// squash, stretch or nudge itself; zeroed means "as painted".
pub const rvn_xform_t = extern struct {
    /// Scale minus one, per axis, around the center of the widget.
    grow_x: f32,
    grow_y: f32,
    /// Offset, in logical units.
    dx: f32,
    dy: f32,
};
pub const struct_rvn_xform_t = rvn_xform_t;

/// What a transition does to its widget during one frame (anim.c).
pub const rvn_transition_state_t = extern struct {
    active: c_int,
    opacity: f32,
    sx: f32,
    sy: f32,
    dx: f32,
    dy: f32,
    /// Pivot of the scale, from the center of the widget, in units of its size (-0.5 .. 0.5).
    pivot_x: f32,
    pivot_y: f32,
};
pub const struct_rvn_transition_state_t = rvn_transition_state_t;

pub const rvn_widget_class_t = extern struct {
    type: raven.RWidgetType,
    /// Tag of the widget in XML.
    name: [*c]const u8,
    /// Size of the instance structure (rvn_widget_t is its first member).
    size: usize,
    flags: u32,

    init: ?*const fn (widget: [*c]rvn_widget_t) callconv(.c) void,
    destroy: ?*const fn (widget: [*c]rvn_widget_t) callconv(.c) void,

    /// Returns the desired size of the content, measuring children with
    /// rvn_widget_measure. NULL: the largest child (slot padding included).
    measure: ?*const fn (widget: [*c]rvn_widget_t) callconv(.c) base.rvn_vec2_t,
    /// Places the children inside widget->rect.w x widget->rect.h with
    /// rvn_widget_arrange. NULL: every child fills the widget (slot applied).
    arrange: ?*const fn (widget: [*c]rvn_widget_t) callconv(.c) void,
    /// Draws the widget itself, below its children.
    paint: ?*const fn (widget: [*c]rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void,
    /// Draws above the children (scrollbars, focus outline).
    paint_overlay: ?*const fn (widget: [*c]rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void,
    /// Handles an input event. Returns R_TRUE to stop the bubbling.
    event: ?*const fn (widget: [*c]rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int,
    /// Sets a property from text (XML attribute). Returns R_FALSE when the name is unknown.
    set_attribute: ?*const fn (widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int,
    /// Tells whether a child takes part in painting and hit testing. NULL: all do.
    child_active: ?*const fn (widget: [*c]rvn_widget_t, child: [*c]rvn_widget_t) callconv(.c) c_int,
    /// Tells whether a point of the widget (from its corner, as shown) can
    /// reach a child: R_FALSE where the class draws something of its own over
    /// that child. NULL: every point can.
    child_at: ?*const fn (widget: [*c]rvn_widget_t, child: [*c]rvn_widget_t, x: f32, y: f32) callconv(.c) c_int,
    /// Called after a child was added or removed.
    children_changed: ?*const fn (widget: [*c]rvn_widget_t) callconv(.c) void,
    /// Handles an XML child element that is not a widget (<Item>, ...). Returns R_FALSE when unknown.
    xml_child: ?*const fn (widget: [*c]rvn_widget_t, node: [*c]const xml_h.rvn_xml_node_t) callconv(.c) c_int,
    /// Called when the widget, shown as a popup, has been closed.
    popup_closed: ?*const fn (widget: [*c]rvn_widget_t) callconv(.c) void,
    /// For a widget that moves its window when dragged (RVN_WF_WINDOW_DRAG):
    /// R_FALSE where it keeps the mouse for itself (the buttons of a header bar).
    /// NULL: the whole widget drags.
    window_drag_at: ?*const fn (widget: [*c]rvn_widget_t, x: f32, y: f32) callconv(.c) c_int,
};
pub const struct_rvn_widget_class_t = rvn_widget_class_t;

pub const rvn_widget_t = extern struct {
    id: raven.Rid,
    cls: [*c]const rvn_widget_class_t,
    parent: [*c]rvn_widget_t,
    /// Window showing the widget, NULL while detached.
    window: [*c]rvn_window_t,
    children: [*c][*c]rvn_widget_t,
    child_count: u32,
    child_cap: u32,

    flags: u32,
    visibility: raven.RVisibility,
    /// RDirection of the widget itself (0: inherit).
    direction: u16,
    /// Accessibility: what a screen reader says of it (core/accessibility.c), or NULL.
    a11y: ?*rvn_a11y_t,
    /// Bounds relative to the parent (to the window for popups and roots), logical units.
    rect: base.rvn_rect_t,
    /// Desired size computed by the last measure pass.
    desired: base.rvn_vec2_t,
    /// Constraints on the desired size; a negative value means "none".
    fixed_size: base.rvn_vec2_t,
    min_size: base.rvn_vec2_t,
    max_size: base.rvn_vec2_t,
    slot: rvn_slot_t,
    opacity: f32,
    /// Overrides of the theme for this widget, allocated on first use.
    style: [*c]ctx_h.rvn_style_t,
    /// Material of its own, or 0 for the one of the theme.
    material: raven.RMaterial,
    /// Classes, separated by spaces, or NULL.
    classes: [*c]u8,
    /// Theme of the widget: its own or the one of an ancestor; NULL = the theme in use.
    theme: [*c]const ctx_h.rvn_theme_t,
    /// R_TRUE when `theme` was given to this widget itself.
    theme_own: u8,
    /// What the styles of the theme give to this widget, or NULL; valid while style_generation is the one of the library.
    match: [*c]const ctx_h.rvn_style_match_t,
    style_generation: u32,

    name: [*c]u8,
    tooltip: [*c]u8,
    /// Node of the public XML document the widget was built from (Rwidget_get_xml_node), or 0.
    xml_node: raven.Rid,
    action: [*c]u8,
    user_handle: ?*anyopaque,
    /// Told when the widget is gone (Rwidget_set_destroy_callback).
    destroy_callback: raven.RWidgetDestroyCallback,
    destroy_user: ?*anyopaque,
    /// The tag made by code the widget was built for (Rxml_register_tag): its index + 1, or 0.
    xml_tag: u8,
    event_callback: raven.RWidgetEventCallback,
    event_user: ?*anyopaque,
    /// 0 = inherit from the parent.
    cursor: raven.RCursor,
    context_menu: raven.Rid,
    /// Takes what is dropped on the widget from other applications, or NULL.
    drop_callback: raven.RDropCallback,
    drop_user: ?*anyopaque,

    /// Eased state of the widget, advanced while painting: under the pointer, and pressed.
    hover: raven.RSpring,
    press: raven.RSpring,
    /// Set by the paint function of the class: see rvn_xform_t.
    xform: rvn_xform_t,
    /// Set by the paint function of the class: offset of the children for this frame (smooth scrolling).
    child_shift: base.rvn_vec2_t,
    /// Size of the children on screen, for a class that draws them larger or
    /// smaller than they are laid out (a canvas that zooms): a child whose
    /// rectangle is at (x, y) shows at (x, y) * child_scale from the corner of
    /// the widget. 0 means 1. The class draws them so itself (it has
    /// RVN_CF_OWN_CHILDREN); the hit tests and the mouse events of the
    /// subtree follow (rvn_widget_to_virtual).
    child_scale: f32,
    /// Transitions, allocated on first use.
    fx: [*c]rvn_fx_t,

    /// Number of widgets in the subtree, this one included.
    subtree_count: u32,
    /// Number of widgets in the subtree whose paint must run on the UI thread.
    ui_paint_count: u32,
};
pub const struct_rvn_widget_t = rvn_widget_t;

// ---------------------------------------------------------------------------
//  Registry (widget/registry.c)
// ---------------------------------------------------------------------------

pub extern fn rvn_widget_class_by_type(@"type": raven.RWidgetType) [*c]const rvn_widget_class_t;
pub extern fn rvn_widget_class_by_name(name: [*c]const u8) [*c]const rvn_widget_class_t;

// ---------------------------------------------------------------------------
//  Tree (widget/widget.c)
// ---------------------------------------------------------------------------

/// Resolves a handle without reporting errors.
pub extern fn rvn_widget_get(id: raven.Rid) [*c]rvn_widget_t;
/// Resolves a handle for a public function: checks the library state, the
/// calling thread, the handle and, when `type` is not 0, the widget type.
/// Reports an error naming `function` and returns NULL on failure.
pub extern fn rvn_widget_check(id: raven.Rid, @"type": raven.RWidgetType, function: [*c]const u8) [*c]rvn_widget_t;

// RVN_WIDGET(variable, id, type, result) / RVN_WIDGET_VOID(variable, id, type): see the top of this file.

pub extern fn rvn_widget_create(@"type": raven.RWidgetType) [*c]rvn_widget_t;
/// Creates a widget of a class that is not in the registry (internal popups).
pub extern fn rvn_widget_create_class(cls: [*c]const rvn_widget_class_t) [*c]rvn_widget_t;
/// Detaches and destroys a widget and its subtree.
pub extern fn rvn_widget_destroy(widget: [*c]rvn_widget_t) void;
/// @param index Position among the children, or -1 to append.
pub extern fn rvn_widget_add_child(parent: [*c]rvn_widget_t, child: [*c]rvn_widget_t, index: c_int) void;
/// Removes the widget from its parent without destroying it.
pub extern fn rvn_widget_detach(widget: [*c]rvn_widget_t) void;
pub extern fn rvn_widget_child_index(parent: [*c]const rvn_widget_t, child: [*c]const rvn_widget_t) c_int;
/// Sets the window of a whole subtree (used for roots and popups).
pub extern fn rvn_widget_set_window(widget: [*c]rvn_widget_t, window: [*c]rvn_window_t) void;
/// R_TRUE when the widget and all its ancestors are visible and active in their parent.
pub extern fn rvn_widget_is_shown(widget: [*c]const rvn_widget_t) c_int;
/// R_TRUE when the widget and all its ancestors are enabled.
pub extern fn rvn_widget_is_enabled(widget: [*c]const rvn_widget_t) c_int;
/// R_TRUE when `ancestor` is `widget` or one of its ancestors.
pub extern fn rvn_widget_is_inside(widget: [*c]const rvn_widget_t, ancestor: [*c]const rvn_widget_t) c_int;
/// Top-left corner of the widget in window coordinates.
pub extern fn rvn_widget_origin(widget: [*c]const rvn_widget_t) base.rvn_vec2_t;
/// Widgets under an ancestor that scales its children (child_scale) live in a
/// space of their own, where rvn_widget_origin and their rectangles are as if
/// nothing was scaled. These convert a point of the window to that space of a
/// widget (what its events carry), and back (to place a popup next to it).
pub extern fn rvn_widget_to_virtual(widget: [*c]const rvn_widget_t, x: [*c]f32, y: [*c]f32) void;
pub extern fn rvn_widget_from_virtual(widget: [*c]const rvn_widget_t, x: [*c]f32, y: [*c]f32) void;
/// Releases the memory of the widgets deleted during the event dispatch.
pub extern fn rvn_widgets_collect() void;

// ---------------------------------------------------------------------------
//  Layout (widget/layout.c)
// ---------------------------------------------------------------------------

/// The widget needs a new measure + arrange + paint.
pub extern fn rvn_widget_invalidate_layout(widget: [*c]rvn_widget_t) void;
/// The widget only needs to be painted again.
pub extern fn rvn_widget_invalidate_paint(widget: [*c]rvn_widget_t) void;

/// Desired size of a widget (cached). (0, 0) when collapsed.
pub extern fn rvn_widget_measure(widget: [*c]rvn_widget_t) base.rvn_vec2_t;
/// Desired size of a child plus its slot padding.
pub extern fn rvn_widget_measure_slot(child: [*c]rvn_widget_t) base.rvn_vec2_t;
/// Gives a widget its final bounds, relative to its parent, and arranges its children.
pub extern fn rvn_widget_arrange(widget: [*c]rvn_widget_t, x: f32, y: f32, width: f32, height: f32) void;
/// Places a child inside `area` according to its slot padding and alignment.
pub extern fn rvn_widget_arrange_slot(child: [*c]rvn_widget_t, area: base.rvn_rect_t) void;
pub inline fn rvn_widget_collapsed(widget: [*c]const rvn_widget_t) c_int {
    return @intFromBool(widget.*.visibility == raven.R_COLLAPSED);
}

// ---------------------------------------------------------------------------
//  Style (widget/style.c)
// ---------------------------------------------------------------------------

/// Theme a widget reads its values from.
pub inline fn rvn_widget_theme(widget: [*c]const rvn_widget_t) [*c]const ctx_h.rvn_theme_t {
    return if (widget.*.theme != null) widget.*.theme else &ctx_h.g_rvn.theme;
}
/// Looks again for the styles that apply to the widget (slow path of the lookups below).
pub extern fn rvn_widget_restyle(widget: [*c]rvn_widget_t) void;
pub inline fn rvn_widget_match(widget: [*c]const rvn_widget_t) [*c]const ctx_h.rvn_style_match_t {
    if (widget.*.style_generation != ctx_h.g_rvn.style_generation) rvn_widget_restyle(@ptrFromInt(@intFromPtr(widget)));
    return widget.*.match;
}
/// Material a widget is drawn with, and whether it is a glass.
pub inline fn rvn_widget_material(widget: [*c]const rvn_widget_t) raven.RMaterial {
    if (widget.*.material != 0) return widget.*.material;
    const match = rvn_widget_match(widget);
    if (match != null and match.*.material != 0) return match.*.material;
    return rvn_widget_theme(widget).*.material;
}
pub inline fn rvn_widget_glass(widget: [*c]const rvn_widget_t) c_int {
    return @intFromBool(rvn_widget_material(widget) != raven.R_MATERIAL_SOLID);
}
pub extern fn rvn_parse_material(text: [*c]const u8, material: [*c]raven.RMaterial) c_int;

pub extern fn rvn_widget_color(widget: [*c]const rvn_widget_t, role: raven.RColorRole) base.rvn_color_t;
pub extern fn rvn_widget_metric(widget: [*c]const rvn_widget_t, metric: raven.RMetric) f32;
pub extern fn rvn_widget_has_color(widget: [*c]const rvn_widget_t, role: raven.RColorRole) c_int;
/// R_TRUE when the widget itself, or a style of the theme for it, gives the metric (not only the theme).
pub extern fn rvn_widget_has_metric(widget: [*c]const rvn_widget_t, metric: raven.RMetric) c_int;
pub extern fn rvn_widget_set_color(widget: [*c]rvn_widget_t, role: raven.RColorRole, color: base.rvn_color_t) void;
pub extern fn rvn_widget_set_metric(widget: [*c]rvn_widget_t, metric: raven.RMetric, value: f32) void;
/// Color of the text of a widget: its override, else the inherited color, dimmed when disabled.
pub extern fn rvn_widget_text_color(widget: [*c]const rvn_widget_t, painter: ?*const raven.RPainter) base.rvn_color_t;
/// Makes a built-in theme the theme in use.
pub extern fn rvn_theme_apply(theme: raven.RTheme) void;
/// Fills a theme with a built-in one (its styles are removed; name and path are kept).
pub extern fn rvn_theme_build(theme: [*c]ctx_h.rvn_theme_t, builtin: raven.RTheme) void;
/// Wallpaper of the built-in glass themes.
pub extern fn rvn_theme_builtin_wallpaper(dark: c_int) raven.Rid;
/// A soft gradient made of a base color and up to five blobs of color (0xRRGGBB).
pub extern fn rvn_wallpaper_create_colors(base_: u32, blobs: [*c]const u32, count: c_int) raven.Rid;

// ---- named themes, styles, theme files (widget/theme.c) ----

/// Named theme, the built-in ones included. NULL when unknown.
pub extern fn rvn_theme_find(name: [*c]const u8) [*c]ctx_h.rvn_theme_t;
/// Releases what a theme owns and zeroes it.
pub extern fn rvn_theme_clear(theme: [*c]ctx_h.rvn_theme_t) void;
/// Deep copy; `name` and `path` of the destination are kept.
pub extern fn rvn_theme_copy(destination: [*c]ctx_h.rvn_theme_t, source: [*c]const ctx_h.rvn_theme_t) void;
/// Something a widget may read from a theme changed: every widget is styled, measured and painted again.
pub extern fn rvn_theme_changed() void;
/// Empties the caches of the styles after a rule or the classes of a widget changed.
pub extern fn rvn_styles_changed() void;
/// The accent color and what follows from it.
pub extern fn rvn_theme_set_accent(theme: [*c]ctx_h.rvn_theme_t, accent: base.rvn_color_t) void;
/// Gives a theme to a widget (`own`) or lets it follow its parent again (theme NULL, own 0), and tells its subtree.
pub extern fn rvn_widget_set_theme(widget: [*c]rvn_widget_t, theme: [*c]const ctx_h.rvn_theme_t, own: c_int) void;
/// The widget has a new parent or a new popup owner: it follows the theme of that one unless it has its own.
pub extern fn rvn_widget_inherit_theme(widget: [*c]rvn_widget_t, theme: [*c]const ctx_h.rvn_theme_t) void;
/// The dark counterpart of the theme in use (itself when it is dark): the island and what must stay dark.
pub extern fn rvn_theme_dark_twin() [*c]const ctx_h.rvn_theme_t;
pub extern fn rvn_widget_has_class(widget: [*c]const rvn_widget_t, cls: [*c]const u8) c_int;
pub extern fn rvn_themes_init() void;
pub extern fn rvn_themes_shutdown() void;
/// A watched theme file changed (xml/xml_watch.c).
pub extern fn rvn_theme_file_changed(path: [*c]const u8) void;
pub extern fn rvn_color_role_by_name(name: [*c]const u8, role: [*c]raven.RColorRole) c_int;
pub extern fn rvn_metric_by_name(name: [*c]const u8, metric: [*c]raven.RMetric) c_int;
pub extern fn rvn_color_role_name(role: raven.RColorRole) [*c]const u8;
pub extern fn rvn_metric_name(metric: raven.RMetric) [*c]const u8;

// ---------------------------------------------------------------------------
//  Painting and hit testing (widget/paint.c)
// ---------------------------------------------------------------------------

/// Paints a widget and its subtree. `parent` describes the space of the parent.
pub extern fn rvn_widget_paint(widget: [*c]rvn_widget_t, parent: ?*const raven.RPainter) void;
/// Deepest widget under a point given in the coordinate space of the parent of `widget`.
pub extern fn rvn_widget_hit_test(widget: [*c]rvn_widget_t, x: f32, y: f32) [*c]rvn_widget_t;
pub extern fn rvn_paint_init() void;
pub extern fn rvn_paint_shutdown() void;
/// Number of paint jobs started since the last call (statistics).
pub extern fn rvn_paint_take_job_count() c_int;

// ---------------------------------------------------------------------------
//  Animation (widget/anim.c)
// ---------------------------------------------------------------------------

/// Time by which the animations of a window advance, `elapsed` seconds after its previous frame.
pub extern fn rvn_animation_dt(elapsed: f64) f32;
/// Starts a transition now.
pub extern fn rvn_widget_play_transition(widget: [*c]rvn_widget_t, transition: raven.RTransition, delay: f32) void;
/// Changes the transition a widget plays when it appears, and / or its delay (NULL = keep).
pub extern fn rvn_widget_set_appear(widget: [*c]rvn_widget_t, transition: [*c]const raven.RTransition, delay: [*c]const f32) void;
/// The widget has just been shown: plays the transition it was given, if any.
pub extern fn rvn_widget_appear(widget: [*c]rvn_widget_t) void;
/// Advances the transition of a widget about to be painted. Returns R_FALSE
/// when the widget is not to be drawn at all this frame (it waits its turn).
pub extern fn rvn_transition_begin(widget: [*c]rvn_widget_t, painter: ?*raven.RPainter, state: [*c]rvn_transition_state_t) c_int;
pub extern fn rvn_parse_transition(text: [*c]const u8, transition: [*c]raven.RTransition) c_int;

// ---------------------------------------------------------------------------
//  Events (widget/events.c)
// ---------------------------------------------------------------------------

/// Sends an event to a widget and bubbles it to the ancestors. Returns R_TRUE when handled.
pub extern fn rvn_widget_dispatch(target: [*c]rvn_widget_t, event: [*c]raven.REvent) c_int;
/// Sends an event to one widget only.
pub extern fn rvn_widget_send(target: [*c]rvn_widget_t, event: [*c]raven.REvent) c_int;
/// Fires the action of the widget (Rwidget_set_action).
pub extern fn rvn_widget_fire_action(widget: [*c]rvn_widget_t) void;
/// Sends all further mouse events to the widget until the capture is released.
pub extern fn rvn_widget_capture_mouse(widget: [*c]rvn_widget_t) void;
pub extern fn rvn_widget_release_mouse(widget: [*c]rvn_widget_t) void;
pub extern fn rvn_widget_focus(widget: [*c]rvn_widget_t) void;

// ---------------------------------------------------------------------------
//  Window (widget/window.c)
// ---------------------------------------------------------------------------

pub const rvn_popup_placement_t = c_uint;
pub const enum_rvn_popup_placement_t = rvn_popup_placement_t;
/// Below the anchor, left edges aligned; above when there is no room.
pub const RVN_POPUP_BELOW: c_int = 0;
/// Right of the anchor, top edges aligned; left when there is no room.
pub const RVN_POPUP_RIGHT: c_int = 1;
/// Top-left corner on the anchor position.
pub const RVN_POPUP_AT: c_int = 2;
/// A dialog: in the middle of the window, above a veil that keeps the rest out of reach.
pub const RVN_POPUP_DIALOG: c_int = 3;

pub const rvn_popup_t = extern struct {
    root: [*c]rvn_widget_t,
    /// Widget that opened the popup; receives the focus back. May be NULL.
    owner: [*c]rvn_widget_t,
    anchor: base.rvn_rect_t,
    placement: rvn_popup_placement_t,
    /// Minimum width (combo box lists match their button).
    min_width: f32,
    /// 0 = just opened .. 1 = fully shown: the popup grows out of its anchor.
    shown: raven.RSpring,
    /// Dialogs: the value given when closing, and who to tell. The window deletes the root of a dialog.
    result: c_int,
    closed: raven.RDialogClosedCallback,
    closed_user: ?*anyopaque,
    /// Dialogs: the widget that had the keyboard before, which gets it back.
    focus_back: raven.Rid,
};
pub const struct_rvn_popup_t = rvn_popup_t;

/// A spring that changes the layout (the height of an expander, the place of
/// a docked panel). Paint functions may run on any thread and cannot ask for
/// a new layout, so these springs are advanced by the window itself, on the UI
/// thread, before each layout.
pub const rvn_layout_spring_t = extern struct {
    widget: [*c]rvn_widget_t,
    spring: [*c]raven.RSpring,
    target: f32,
    motion: raven.RMotion,
};
pub const struct_rvn_layout_spring_t = rvn_layout_spring_t;

/// A popup that was closed and is still shrinking away. It takes no input.
pub const rvn_ghost_t = extern struct {
    root: [*c]rvn_widget_t,
    anchor: base.rvn_rect_t,
    shown: raven.RSpring,
    /// A dialog: drawn with its veil, and deleted once it is gone.
    dialog: c_int,
};
pub const struct_rvn_ghost_t = rvn_ghost_t;

pub const rvn_shortcut_t = extern struct {
    key: raven.RKey,
    modifiers: u32,
    action: [*c]u8,
};
pub const struct_rvn_shortcut_t = rvn_shortcut_t;

pub const rvn_window_t = extern struct {
    id: raven.Rid,
    /// Node of the public XML document the window was built from, or 0.
    xml_node: raven.Rid,
    platform: ?*plat_h.rvn_pwindow_t,
    root: [*c]rvn_widget_t,
    /// A widget floating at the top of the window above the content (Rwindow_set_island), or NULL.
    island: [*c]rvn_widget_t,
    title: [*c]u8,

    /// Size of the client area in pixels and pixels per logical unit.
    width_px: c_int,
    height_px: c_int,
    scale: f32,
    visible: c_int,
    surface_ready: c_int,
    /// RWindowFlags given at creation.
    window_flags: u32,
    state: plat_h.rvn_pwindow_state_t,
    /// R_TRUE while the window is the one the user works in.
    active: c_int,
    /// What the screen reader was last told (core/accessibility.c).
    a11y_focus: u64,
    a11y_hash: u32,
    a11y_generation: u32,

    needs_layout: c_int,
    needs_paint: c_int,
    continuous: c_int,
    /// Set from any thread by Rwindow_request_redraw.
    redraw_requested: thread_h.rvn_atomic_t,
    /// Frames queued or being rendered.
    frames_in_flight: thread_h.rvn_atomic_t,
    render_us: thread_h.rvn_atomic_t,
    /// Realtime viewports seen during the last paint.
    realtime_viewports: thread_h.rvn_atomic_t,
    /// Set while painting by widgets whose animation is not finished: another frame is needed.
    animating: thread_h.rvn_atomic_t,
    /// When the window was last painted, for the pace of the animations.
    paint_time: f64,
    /// Image drawn behind the content (Rwindow_set_background), or R_INVALID_ID.
    background: raven.Rid,

    has_clear_color: c_int,
    clear_color: [4]f32,
    /// R_TRUE when the surface of the window has an alpha the window system uses (R_WINDOW_TRANSPARENT that worked).
    transparent: c_int,
    /// What was asked for behind the window, and what the window system gives (0 = R_BACKDROP_NONE).
    backdrop_wanted: raven.RBackdrop,
    backdrop: raven.RBackdrop,
    /// The theme was dark when the window system was last told about the backdrop.
    backdrop_dark: c_int,
    opacity: f32,

    // input state
    hover: [*c]rvn_widget_t,
    focus: [*c]rvn_widget_t,
    capture: [*c]rvn_widget_t,
    /// R_TRUE when the focus was moved with the keyboard: widgets then draw a focus outline.
    focus_visible: c_int,
    mouse_x: f32,
    mouse_y: f32,
    mouse_inside: c_int,
    modifiers: u32,
    buttons: u32,
    click_time: f64,
    click_x: f32,
    click_y: f32,
    click_count: c_int,
    click_button: c_int,
    cursor: raven.RCursor,
    /// Custom header: the resize edge under the pointer, when the window system does not handle them itself.
    edge: plat_h.rvn_pregion_t,

    // drag and drop from other applications
    drop_callback: raven.RDropCallback,
    drop_user: ?*anyopaque,
    /// What would take a drop at the pointer: a widget, or the window itself (drop_on_window).
    drop_target: [*c]rvn_widget_t,
    drop_on_window: c_int,
    drop_accepted: c_int,
    /// Highlight of the target: where it is and how much of it shows.
    drop_rect: base.rvn_rect_t,
    drop_radius: f32,
    drop_shown: raven.RSpring,

    // popups, bottom to top
    popups: [*c]rvn_popup_t,
    popup_count: u32,
    popup_cap: u32,
    ghosts: [*c]rvn_ghost_t,
    ghost_count: u32,
    ghost_cap: u32,
    /// The subtree that is leaving the window right now (rvn_window_forget_widget), or NULL.
    forgetting: [*c]rvn_widget_t,
    layout_springs: [*c]rvn_layout_spring_t,
    layout_spring_count: u32,
    layout_spring_cap: u32,

    // tooltip
    tooltip_widget: [*c]rvn_widget_t,
    tooltip_timer: raven.Rid,
    tooltip_visible: c_int,
    tooltip_x: f32,
    tooltip_y: f32,
    tooltip_shown: raven.RSpring,

    shortcuts: [*c]rvn_shortcut_t,
    shortcut_count: u32,
    shortcut_cap: u32,

    // viewports of this window that own a native child window
    native_viewports: [*c][*c]rvn_widget_t,
    native_viewport_count: u32,
    native_viewport_cap: u32,

    close_callback: raven.RWindowCloseCallback,
    close_user: ?*anyopaque,
    resize_callback: raven.RWindowResizeCallback,
    resize_user: ?*anyopaque,
    user_handle: ?*anyopaque,

    /// Keys held down (Rwindow_is_key_down), indexed by RKey.
    keys: [raven.R_KEY_COUNT]u8,
    /// R_FALSE: Tab does not move the keyboard focus (Rwindow_set_tab_navigation).
    tab_navigation: c_int,
    /// Drag and drop inside the application (Rdrag_begin).
    drag_active: c_int,
    drag_type: [*c]u8,
    drag_data: [*c]u8,
    drag_label: [*c]u8,
    drag_source: raven.Rid,
    /// Sees every input event of the window before the widgets (Rwindow_set_event_hook).
    event_hook: raven.RWindowEventHook,
    event_hook_user: ?*anyopaque,

    stats: raven.RFrameStats,
    frame_index: u64,
    dead: c_int,
};
pub const struct_rvn_window_t = rvn_window_t;

pub extern fn rvn_window_get(id: raven.Rid) [*c]rvn_window_t;
pub extern fn rvn_window_check(id: raven.Rid, function: [*c]const u8) [*c]rvn_window_t;
/// Entry point of the platform events.
pub extern fn rvn_window_on_platform_event(event: [*c]const plat_h.rvn_pevent_t) void;
/// What a pixel of a window with a custom header is, for the window system (rvn_pregion_handler_t).
pub extern fn rvn_window_region_at(user: ?*anyopaque, x: c_int, y: c_int) plat_h.rvn_pregion_t;
/// Asks to close the window as the user would: the close callback may refuse.
pub extern fn rvn_window_request_close(window: [*c]rvn_window_t) void;
/// Maximizes the window, or restores it when it is maximized.
pub extern fn rvn_window_toggle_maximized(window: [*c]rvn_window_t) void;
/// Lays out and paints the window when something changed.
pub extern fn rvn_window_update(window: [*c]rvn_window_t) void;
/// Runs the layout passes now if the window needs them.
pub extern fn rvn_window_layout(window: [*c]rvn_window_t) void;
/// R_TRUE when the window will produce a frame at the next update.
pub extern fn rvn_window_wants_frame(window: [*c]rvn_window_t) c_int;
/// Waits until the windows that will paint can take a frame (the previous one
/// left for the renderer). Called before the input is read: the frame that
/// follows shows the pointer where it is now, not where it was a frame ago.
pub extern fn rvn_windows_throttle() void;
/// Clears every reference the window holds to a widget about to be destroyed.
pub extern fn rvn_window_forget_widget(window: [*c]rvn_window_t, widget: [*c]rvn_widget_t) void;
pub extern fn rvn_window_set_focus(window: [*c]rvn_window_t, widget: [*c]rvn_widget_t) void;
pub extern fn rvn_window_destroy(window: [*c]rvn_window_t) void;
pub extern fn rvn_windows_destroy_all() void;
pub extern fn rvn_windows_collect() void;
/// Logical size of the client area.
pub extern fn rvn_window_size(window: [*c]const rvn_window_t) base.rvn_vec2_t;
/// R_TRUE when what is behind the window on the screen shows where the window draws nothing.
pub extern fn rvn_window_see_through(window: [*c]const rvn_window_t) c_int;
pub extern fn rvn_window_add_shortcut(window: [*c]rvn_window_t, key: raven.RKey, modifiers: u32, action: [*c]const u8) void;
pub extern fn rvn_window_remove_shortcut(window: [*c]rvn_window_t, key: raven.RKey, modifiers: u32) void;

/// Moves a spring that belongs to `widget` toward `target`, giving the widget
/// a new layout at every step. The spring must live as long as the widget.
/// Without a window, or with the animations off, the value is set at once.
pub extern fn rvn_widget_animate_layout(widget: [*c]rvn_widget_t, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) void;
/// To call before releasing the memory of a spring given to rvn_widget_animate_layout while its widget lives on.
pub extern fn rvn_widget_forget_layout_spring(widget: [*c]rvn_widget_t, spring: [*c]const raven.RSpring) void;

/// Shows a widget tree above the window content. The popup does not own `root`.
pub extern fn rvn_window_open_popup(window: [*c]rvn_window_t, root: [*c]rvn_widget_t, owner: [*c]rvn_widget_t, anchor: base.rvn_rect_t, placement: rvn_popup_placement_t, min_width: f32) void;
/// Closes a popup and all the popups opened above it.
pub extern fn rvn_window_close_popup(window: [*c]rvn_window_t, root: [*c]rvn_widget_t) void;
/// The tooltip text of the widget under the pointer changed: the tooltip starts over.
pub extern fn rvn_window_rearm_tooltip(window: [*c]rvn_window_t) void;
// ---- core/locale.c ----
/// "@key" values of attributes: R_TRUE when handled (the result of the widget in *result).
pub extern fn rvn_locale_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8, result: [*c]c_int) c_int;
/// R_TRUE when the current language is written from right to left.
pub extern fn rvn_locale_rtl() c_int;
pub extern fn rvn_locale_code_is_rtl(code: [*c]const u8) c_int;
pub extern fn rvn_locale_shutdown() void;

// ---- core/accessibility.c ----
pub extern fn rvn_a11y_text_scale() f32;
pub extern fn rvn_a11y_focus_always() c_int;
pub extern fn rvn_a11y_focus_width() f32;
pub extern fn rvn_a11y_structure_changed() void;
pub extern fn rvn_a11y_widget_destroyed(widget: [*c]rvn_widget_t) void;
pub extern fn rvn_a11y_shutdown() void;
pub extern fn rvn_a11y_filter_instances(instances: [*c]raven.RDrawInstance, count: u32) void;
/// After a frame of the window: tells the screen reader what changed.
pub extern fn rvn_a11y_frame(window: [*c]rvn_window_t) void;
/// XML attributes Accessible*: R_TRUE / R_FALSE when the name is one of them, -1 otherwise.
pub extern fn rvn_a11y_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int;

// ---- widget/direction.c ----
/// The direction of the windows follows the language (Rset_layout_direction(R_DIRECTION_AUTO)): lays them out again.
pub extern fn rvn_direction_refresh() void;
/// R_TRUE when the widget is laid out from right to left.
pub extern fn rvn_widget_is_rtl(widget: [*c]const rvn_widget_t) c_int;
/// Direction of the windows when nothing more precise is given.
pub extern fn rvn_direction_global_rtl() c_int;

/// Closes the menus and the lists that are open. Dialogs stay, with what is under them.
pub extern fn rvn_window_close_popups(window: [*c]rvn_window_t) void;
/// Shows a widget as a dialog of the window. The window owns `root` from now
/// on and deletes it when the dialog closes; `closed` is called at that moment.
pub extern fn rvn_window_open_dialog(window: [*c]rvn_window_t, root: [*c]rvn_widget_t, closed: raven.RDialogClosedCallback, user: ?*anyopaque) void;
/// Closes the dialog that contains `inside`, giving `result` to its callback. R_FALSE when there is none.
pub extern fn rvn_window_close_dialog(inside: [*c]rvn_widget_t, result: c_int) c_int;
/// Root of the dialog on top of the others, or NULL.
pub extern fn rvn_window_top_dialog(window: [*c]const rvn_window_t) [*c]rvn_widget_t;
pub extern fn rvn_window_popup_index(window: [*c]const rvn_window_t, root: [*c]const rvn_widget_t) c_int;

/// Triggers a menu item (shortcuts). Implemented in widgets/menu.c.
pub extern fn rvn_menu_item_trigger(item: [*c]rvn_widget_t) void;
/// Destroys the native child windows of the viewports inside a subtree leaving the window.
pub extern fn rvn_window_release_natives(window: [*c]rvn_window_t, subtree: [*c]rvn_widget_t) void;
/// Native viewports (widgets/viewport.c): release the child window / apply its state after a paint.
pub extern fn rvn_viewport_native_release(widget: [*c]rvn_widget_t, window: [*c]rvn_window_t) void;
pub extern fn rvn_viewport_native_sync(widget: [*c]rvn_widget_t, frame: u64) void;

/// Enabled menu item bound to a shortcut anywhere below `root`, or NULL. Implemented in widgets/menu.c.
pub extern fn rvn_menu_find_shortcut(root: [*c]rvn_widget_t, key: raven.RKey, modifiers: u32) [*c]rvn_widget_t;
/// Parses "Ctrl+Shift+S". Implemented in widgets/menu.c.
pub extern fn rvn_parse_shortcut(text: [*c]const u8, key: [*c]raven.RKey, modifiers: [*c]u32) c_int;
/// Opens a menu as a popup at a window position. Implemented in widgets/menu.c.
pub extern fn rvn_menu_popup(menu: [*c]rvn_widget_t, window: [*c]rvn_window_t, x: f32, y: f32) void;

// ---------------------------------------------------------------------------
//  Attribute parsing (xml/xml_attributes.c), shared by all set_attribute functions
// ---------------------------------------------------------------------------

pub extern fn rvn_parse_float(text: [*c]const u8, value: [*c]f32) c_int;
pub extern fn rvn_parse_int(text: [*c]const u8, value: [*c]c_int) c_int;
pub extern fn rvn_parse_bool(text: [*c]const u8, value: [*c]c_int) c_int;
/// "#RGB", "#RRGGBB", "#RRGGBBAA" or a few color names.
pub extern fn rvn_parse_color(text: [*c]const u8, color: [*c]base.rvn_color_t) c_int;
/// "all", "horizontal,vertical" or "left,top,right,bottom".
pub extern fn rvn_parse_margin(text: [*c]const u8, margin: [*c]base.rvn_margin_t) c_int;
/// Up to `max` comma-separated numbers; returns how many were read.
pub extern fn rvn_parse_floats(text: [*c]const u8, values: [*c]f32, max: c_int) c_int;
pub extern fn rvn_parse_orientation(text: [*c]const u8, orientation: [*c]raven.ROrientation) c_int;
/// Sets a base property (name, visibility, slot, size, colors...).
pub extern fn rvn_widget_set_base_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int;
/// Sets any attribute: the ones of the widget class first, then the base ones.
pub extern fn rvn_widget_set_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int;
