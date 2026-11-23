// Translated to Zig from vendor/raven/src/widget/registry.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/registry.c
// Table of the widget classes. A new widget type is listed here once.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("widget_h.zig");
const common_h = @import("../widgets/common_h.zig");

const g_classes = [_]*const widget_h.rvn_widget_class_t{
    // panels
    &common_h.rvn_class_vbox,
    &common_h.rvn_class_hbox,
    &common_h.rvn_class_grid,
    &common_h.rvn_class_uniform_grid,
    &common_h.rvn_class_overlay,
    &common_h.rvn_class_border,
    &common_h.rvn_class_size_box,
    &common_h.rvn_class_spacer,
    &common_h.rvn_class_scroll_box,
    &common_h.rvn_class_splitter,
    &common_h.rvn_class_wrap_box,
    &common_h.rvn_class_canvas,
    &common_h.rvn_class_switcher,
    &common_h.rvn_class_tab_view,
    &common_h.rvn_class_expander,
    // controls
    &common_h.rvn_class_label,
    &common_h.rvn_class_button,
    &common_h.rvn_class_checkbox,
    &common_h.rvn_class_slider,
    &common_h.rvn_class_progress_bar,
    &common_h.rvn_class_image,
    &common_h.rvn_class_text_input,
    &common_h.rvn_class_spin_box,
    &common_h.rvn_class_combo_box,
    &common_h.rvn_class_separator,
    &common_h.rvn_class_list_view,
    &common_h.rvn_class_tree_view,
    &common_h.rvn_class_menu_bar,
    &common_h.rvn_class_menu,
    &common_h.rvn_class_menu_item,
    &common_h.rvn_class_viewport,
    &common_h.rvn_class_custom,
    &common_h.rvn_class_text_editor,
    &common_h.rvn_class_header_bar,
    &common_h.rvn_class_file_browser,
    &common_h.rvn_class_dock_area,
    &common_h.rvn_class_island,
    &common_h.rvn_class_background_blur,
    &common_h.rvn_class_color_picker,
    &common_h.rvn_class_timeline,
    &common_h.rvn_class_node_graph,
    &common_h.rvn_class_tile_view,
    &common_h.rvn_class_block_editor,
};

/// Other tags accepted in XML, for people coming from Slate / UMG.
const g_aliases = [_]struct { alias: [*c]const u8, type: raven.RWidgetType }{
    .{ .alias = "VerticalBox", .type = @intCast(raven.R_WIDGET_VBOX) },
    .{ .alias = "HorizontalBox", .type = @intCast(raven.R_WIDGET_HBOX) },
    .{ .alias = "GridPanel", .type = @intCast(raven.R_WIDGET_GRID) },
    .{ .alias = "UniformGridPanel", .type = @intCast(raven.R_WIDGET_UNIFORM_GRID) },
    .{ .alias = "Box", .type = @intCast(raven.R_WIDGET_SIZE_BOX) },
    .{ .alias = "CanvasPanel", .type = @intCast(raven.R_WIDGET_CANVAS) },
    .{ .alias = "WidgetSwitcher", .type = @intCast(raven.R_WIDGET_SWITCHER) },
    .{ .alias = "Tabs", .type = @intCast(raven.R_WIDGET_TAB_VIEW) },
    .{ .alias = "ExpandableArea", .type = @intCast(raven.R_WIDGET_EXPANDER) },
    .{ .alias = "Text", .type = @intCast(raven.R_WIDGET_LABEL) },
    .{ .alias = "TextBlock", .type = @intCast(raven.R_WIDGET_LABEL) },
    .{ .alias = "CheckBox", .type = @intCast(raven.R_WIDGET_CHECKBOX) },
    .{ .alias = "EditableText", .type = @intCast(raven.R_WIDGET_TEXT_INPUT) },
    .{ .alias = "TextBox", .type = @intCast(raven.R_WIDGET_TEXT_INPUT) },
    .{ .alias = "TextArea", .type = @intCast(raven.R_WIDGET_TEXT_EDITOR) },
    .{ .alias = "MultiLineEditableText", .type = @intCast(raven.R_WIDGET_TEXT_EDITOR) },
    .{ .alias = "TitleBar", .type = @intCast(raven.R_WIDGET_HEADER_BAR) },
    .{ .alias = "Notch", .type = @intCast(raven.R_WIDGET_ISLAND) },
    .{ .alias = "DynamicIsland", .type = @intCast(raven.R_WIDGET_ISLAND) },
};

export fn rvn_widget_class_by_type(type_: raven.RWidgetType) [*c]const widget_h.rvn_widget_class_t {
    var i: usize = 0;
    while (i < g_classes.len) : (i += 1) {
        if (g_classes[i].type == type_) return g_classes[i];
    }
    return null;
}

export fn rvn_widget_class_by_name(name: [*c]const u8) [*c]const widget_h.rvn_widget_class_t {
    var i: usize = 0;
    if (name == null) return null;
    while (i < g_classes.len) : (i += 1) {
        if (base.rvn_stricmp(g_classes[i].name, name) == 0) return g_classes[i];
    }
    i = 0;
    while (i < g_aliases.len) : (i += 1) {
        if (base.rvn_stricmp(g_aliases[i].alias, name) == 0) return rvn_widget_class_by_type(g_aliases[i].type);
    }
    return null;
}
