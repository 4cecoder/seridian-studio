// Translated to Zig from vendor/raven/src/xml/xml_attributes.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_attributes.c
// Text to value conversions, and the attributes every widget understands
// (name, visibility, size, slot, style overrides, action).
//
// Number parsing does not depend on the C locale: "1.5" is always valid,
// whatever setlocale() the application called.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const xml = @import("xml_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common_h = @import("../widgets/common_h.zig");
const libc = @import("../sys/libc.zig");

// pow is not in sys/libc.zig: declared here with the prototype of math.h.
extern "c" fn pow(x: f64, y: f64) f64;

/// RVN_ATTR(literal) of widgets/common.h: case-insensitive comparison of the attribute name.
inline fn RVN_ATTR(name: [*c]const u8, literal: [*c]const u8) bool {
    return base.rvn_stricmp(name, literal) == 0;
}

// ---------------------------------------------------------------------------
//  Values
// ---------------------------------------------------------------------------

fn rvn_skip_spaces(text: [*c]const u8) [*c]const u8 {
    var text_ = text;
    while (text_[0] == ' ' or text_[0] == '\t' or text_[0] == '\n' or text_[0] == '\r') text_ += 1;
    return text_;
}

/// Reads a number at *cursor and advances it. Returns R_FALSE when there is none.
fn rvn_read_number(cursor: [*c][*c]const u8, value: [*c]f32) c_int {
    var p: [*c]const u8 = rvn_skip_spaces(cursor.*);
    var result: f64 = 0.0;
    var scale: f64 = 1.0;
    var negative: c_int = 0;
    var digits: c_int = 0;

    if (p[0] == '-' or p[0] == '+') {
        negative = @intFromBool(p[0] == '-');
        p += 1;
    }
    while (p[0] >= '0' and p[0] <= '9') {
        result = result * 10.0 + @as(f64, @floatFromInt(p[0] - '0'));
        digits += 1;
        p += 1;
    }
    if (p[0] == '.') {
        p += 1;
        while (p[0] >= '0' and p[0] <= '9') {
            scale *= 0.1;
            result += @as(f64, @floatFromInt(p[0] - '0')) * scale;
            digits += 1;
            p += 1;
        }
    }
    if (digits == 0) return raven.R_FALSE;
    if (p[0] == 'e' or p[0] == 'E') {
        var e: [*c]const u8 = p + 1;
        var exponent: c_int = 0;
        var exponent_negative: c_int = 0;
        var exponent_digits: c_int = 0;
        if (e[0] == '-' or e[0] == '+') {
            exponent_negative = @intFromBool(e[0] == '-');
            e += 1;
        }
        while (e[0] >= '0' and e[0] <= '9' and exponent < 100) {
            exponent = exponent * 10 + @as(c_int, e[0] - '0');
            exponent_digits += 1;
            e += 1;
        }
        if (exponent_digits > 0) {
            result *= pow(10.0, @floatFromInt(if (exponent_negative != 0) -exponent else exponent));
            p = e;
        }
    }
    value.* = @floatCast(if (negative != 0) -result else result);
    cursor.* = p;
    return raven.R_TRUE;
}

export fn rvn_parse_float(text: [*c]const u8, value: [*c]f32) c_int {
    var number: f32 = undefined;
    var text_ = text;
    if (text == null or rvn_read_number(&text_, &number) == 0) return raven.R_FALSE;
    if (rvn_skip_spaces(text_)[0] != 0) return raven.R_FALSE;
    value.* = number;
    return raven.R_TRUE;
}

export fn rvn_parse_int(text: [*c]const u8, value: [*c]c_int) c_int {
    var number: f32 = undefined;
    if (rvn_parse_float(text, &number) == 0) return raven.R_FALSE;
    value.* = @intFromFloat(if (number < 0.0) number - 0.5 else number + 0.5);
    return raven.R_TRUE;
}

export fn rvn_parse_bool(text: [*c]const u8, value: [*c]c_int) c_int {
    if (text == null) return raven.R_FALSE;
    if (base.rvn_stricmp(text, "true") == 0 or base.rvn_stricmp(text, "yes") == 0 or libc.strcmp(text, "1") == 0) {
        value.* = raven.R_TRUE;
    } else if (base.rvn_stricmp(text, "false") == 0 or base.rvn_stricmp(text, "no") == 0 or libc.strcmp(text, "0") == 0) {
        value.* = raven.R_FALSE;
    } else {
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_parse_floats(text_in: [*c]const u8, values: [*c]f32, max: c_int) c_int {
    var count: c_int = 0;
    var text = text_in;
    if (text == null) return 0;
    while (count < max) {
        if (rvn_read_number(&text, &values[@intCast(count)]) == 0) return 0;
        count += 1;
        text = rvn_skip_spaces(text);
        if (text[0] == 0) return count;
        // numbers are separated by a comma or by spaces
        if (text[0] == ',') text += 1;
    }
    return if (rvn_skip_spaces(text)[0] == 0) count else 0;
}

export fn rvn_parse_margin(text: [*c]const u8, margin: [*c]base.rvn_margin_t) c_int {
    var values: [4]f32 = undefined;
    switch (rvn_parse_floats(text, &values, 4)) {
        1 => {
            margin.* = base.rvn_margin(values[0], values[0], values[0], values[0]);
            return raven.R_TRUE;
        },
        2 => {
            margin.* = base.rvn_margin(values[0], values[1], values[0], values[1]);
            return raven.R_TRUE;
        },
        4 => {
            margin.* = base.rvn_margin(values[0], values[1], values[2], values[3]);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_hex_digit(c: u8) c_int {
    if (c >= '0' and c <= '9') return @as(c_int, c - '0');
    if (c >= 'a' and c <= 'f') return @as(c_int, c - 'a') + 10;
    if (c >= 'A' and c <= 'F') return @as(c_int, c - 'A') + 10;
    return -1;
}

export fn rvn_parse_color(text_in: [*c]const u8, color: [*c]base.rvn_color_t) c_int {
    const named = [_]struct { name: [*c]const u8, rgb: u32, alpha: u32 }{
        .{ .name = "transparent", .rgb = 0x000000, .alpha = 0 },
        .{ .name = "white", .rgb = 0xFFFFFF, .alpha = 255 },
        .{ .name = "black", .rgb = 0x000000, .alpha = 255 },
        .{ .name = "red", .rgb = 0xE5484D, .alpha = 255 },
        .{ .name = "green", .rgb = 0x46A758, .alpha = 255 },
        .{ .name = "blue", .rgb = 0x3B82F6, .alpha = 255 },
        .{ .name = "yellow", .rgb = 0xF5D90A, .alpha = 255 },
        .{ .name = "orange", .rgb = 0xF76B15, .alpha = 255 },
        .{ .name = "cyan", .rgb = 0x05A2C2, .alpha = 255 },
        .{ .name = "magenta", .rgb = 0xD6409F, .alpha = 255 },
        .{ .name = "gray", .rgb = 0x808080, .alpha = 255 },
        .{ .name = "grey", .rgb = 0x808080, .alpha = 255 },
    };
    var digits: [8]u32 = undefined;
    var text = text_in;

    if (text == null) return raven.R_FALSE;
    text = rvn_skip_spaces(text);
    if (text[0] != '#') {
        for (0..named.len) |i| {
            if (base.rvn_stricmp(text, named[i].name) == 0) {
                color.* = base.rvn_hex(named[i].rgb, named[i].alpha);
                return raven.R_TRUE;
            }
        }
        return raven.R_FALSE;
    }
    text += 1;
    const length = libc.strlen(text);
    if (length != 3 and length != 4 and length != 6 and length != 8) return raven.R_FALSE;
    for (0..length) |i| {
        const digit = rvn_hex_digit(text[i]);
        if (digit < 0) return raven.R_FALSE;
        digits[i] = @intCast(digit);
    }
    if (length <= 4) {
        // #RGB and #RGBA: each digit is doubled
        color.* = base.rvn_rgba8(digits[0] * 17, digits[1] * 17, digits[2] * 17, if (length == 4) digits[3] * 17 else 255);
    } else {
        color.* = base.rvn_rgba8(digits[0] * 16 + digits[1], digits[2] * 16 + digits[3], digits[4] * 16 + digits[5], if (length == 8) digits[6] * 16 + digits[7] else 255);
    }
    return raven.R_TRUE;
}

export fn rvn_parse_orientation(text: [*c]const u8, orientation: [*c]raven.ROrientation) c_int {
    if (base.rvn_stricmp(text, "Horizontal") == 0) {
        orientation.* = raven.R_HORIZONTAL;
    } else if (base.rvn_stricmp(text, "Vertical") == 0) {
        orientation.* = raven.R_VERTICAL;
    } else {
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Names of the theme values ("Color.Accent", "Metric.FontSize")
// ---------------------------------------------------------------------------

const g_color_names = [_]struct { name: [*c]const u8, role: raven.RColorRole }{
    .{ .name = "Window", .role = raven.R_COLOR_WINDOW },
    .{ .name = "Panel", .role = raven.R_COLOR_PANEL },
    .{ .name = "Border", .role = raven.R_COLOR_BORDER },
    .{ .name = "Text", .role = raven.R_COLOR_TEXT },
    .{ .name = "TextDisabled", .role = raven.R_COLOR_TEXT_DISABLED },
    .{ .name = "TextPlaceholder", .role = raven.R_COLOR_TEXT_PLACEHOLDER },
    .{ .name = "Accent", .role = raven.R_COLOR_ACCENT },
    .{ .name = "AccentHovered", .role = raven.R_COLOR_ACCENT_HOVERED },
    .{ .name = "AccentPressed", .role = raven.R_COLOR_ACCENT_PRESSED },
    .{ .name = "AccentText", .role = raven.R_COLOR_ACCENT_TEXT },
    .{ .name = "Control", .role = raven.R_COLOR_CONTROL },
    .{ .name = "ControlHovered", .role = raven.R_COLOR_CONTROL_HOVERED },
    .{ .name = "ControlPressed", .role = raven.R_COLOR_CONTROL_PRESSED },
    .{ .name = "ControlBorder", .role = raven.R_COLOR_CONTROL_BORDER },
    .{ .name = "Input", .role = raven.R_COLOR_INPUT },
    .{ .name = "Focus", .role = raven.R_COLOR_FOCUS },
    .{ .name = "Selection", .role = raven.R_COLOR_SELECTION },
    .{ .name = "RowHovered", .role = raven.R_COLOR_ROW_HOVERED },
    .{ .name = "Track", .role = raven.R_COLOR_TRACK },
    .{ .name = "Handle", .role = raven.R_COLOR_HANDLE },
    .{ .name = "HandleHovered", .role = raven.R_COLOR_HANDLE_HOVERED },
    .{ .name = "Separator", .role = raven.R_COLOR_SEPARATOR },
    .{ .name = "Header", .role = raven.R_COLOR_HEADER },
    .{ .name = "HeaderHovered", .role = raven.R_COLOR_HEADER_HOVERED },
    .{ .name = "TabActive", .role = raven.R_COLOR_TAB_ACTIVE },
    .{ .name = "Popup", .role = raven.R_COLOR_POPUP },
    .{ .name = "PopupBorder", .role = raven.R_COLOR_POPUP_BORDER },
    .{ .name = "Shadow", .role = raven.R_COLOR_SHADOW },
    .{ .name = "Tooltip", .role = raven.R_COLOR_TOOLTIP },
    .{ .name = "TooltipText", .role = raven.R_COLOR_TOOLTIP_TEXT },
    .{ .name = "Switch", .role = raven.R_COLOR_SWITCH },
    .{ .name = "Success", .role = raven.R_COLOR_SUCCESS },
    .{ .name = "Warning", .role = raven.R_COLOR_WARNING },
    .{ .name = "Danger", .role = raven.R_COLOR_DANGER },
    .{ .name = "Link", .role = raven.R_COLOR_LINK },
    .{ .name = "Code", .role = raven.R_COLOR_CODE },
};

const g_metric_names = [_]struct { name: [*c]const u8, metric: raven.RMetric }{
    .{ .name = "FontSize", .metric = raven.R_METRIC_FONT_SIZE },
    .{ .name = "CornerRadius", .metric = raven.R_METRIC_CORNER_RADIUS },
    .{ .name = "BorderWidth", .metric = raven.R_METRIC_BORDER_WIDTH },
    .{ .name = "ControlHeight", .metric = raven.R_METRIC_CONTROL_HEIGHT },
    .{ .name = "PaddingX", .metric = raven.R_METRIC_PADDING_X },
    .{ .name = "PaddingY", .metric = raven.R_METRIC_PADDING_Y },
    .{ .name = "Spacing", .metric = raven.R_METRIC_SPACING },
    .{ .name = "ScrollbarSize", .metric = raven.R_METRIC_SCROLLBAR_SIZE },
    .{ .name = "RowHeight", .metric = raven.R_METRIC_ROW_HEIGHT },
    .{ .name = "Indent", .metric = raven.R_METRIC_INDENT },
    .{ .name = "SplitterSize", .metric = raven.R_METRIC_SPLITTER_SIZE },
    .{ .name = "CheckSize", .metric = raven.R_METRIC_CHECK_SIZE },
    .{ .name = "SliderHandleSize", .metric = raven.R_METRIC_SLIDER_HANDLE_SIZE },
    .{ .name = "PopupRadius", .metric = raven.R_METRIC_POPUP_RADIUS },
    .{ .name = "GlassFrost", .metric = raven.R_METRIC_GLASS_FROST },
    .{ .name = "GlassRefraction", .metric = raven.R_METRIC_GLASS_REFRACTION },
    .{ .name = "GlassSaturation", .metric = raven.R_METRIC_GLASS_SATURATION },
    .{ .name = "GlassRim", .metric = raven.R_METRIC_GLASS_RIM },
    .{ .name = "GlassShadow", .metric = raven.R_METRIC_GLASS_SHADOW },
    .{ .name = "BlurRadius", .metric = raven.R_METRIC_BLUR_RADIUS },
};

export fn rvn_color_role_by_name(name: [*c]const u8, role: [*c]raven.RColorRole) c_int {
    for (0..g_color_names.len) |i| {
        if (base.rvn_stricmp(g_color_names[i].name, name) == 0) {
            role.* = g_color_names[i].role;
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

export fn rvn_metric_by_name(name: [*c]const u8, metric: [*c]raven.RMetric) c_int {
    for (0..g_metric_names.len) |i| {
        if (base.rvn_stricmp(g_metric_names[i].name, name) == 0) {
            metric.* = g_metric_names[i].metric;
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

export fn rvn_color_role_name(role: raven.RColorRole) [*c]const u8 {
    for (0..g_color_names.len) |i| {
        if (g_color_names[i].role == role) return g_color_names[i].name;
    }
    return null;
}

export fn rvn_metric_name(metric: raven.RMetric) [*c]const u8 {
    for (0..g_metric_names.len) |i| {
        if (g_metric_names[i].metric == metric) return g_metric_names[i].name;
    }
    return null;
}

// ---------------------------------------------------------------------------
//  Attributes shared by all widgets
// ---------------------------------------------------------------------------

fn rvn_parse_cursor(value: [*c]const u8, cursor: [*c]raven.RCursor) c_int {
    const cursors = [_]struct { name: [*c]const u8, cursor: raven.RCursor }{
        .{ .name = "Arrow", .cursor = raven.R_CURSOR_ARROW },
        .{ .name = "IBeam", .cursor = raven.R_CURSOR_IBEAM },
        .{ .name = "Hand", .cursor = raven.R_CURSOR_HAND },
        .{ .name = "Crosshair", .cursor = raven.R_CURSOR_CROSSHAIR },
        .{ .name = "ResizeH", .cursor = raven.R_CURSOR_RESIZE_H },
        .{ .name = "ResizeV", .cursor = raven.R_CURSOR_RESIZE_V },
        .{ .name = "ResizeNWSE", .cursor = raven.R_CURSOR_RESIZE_NWSE },
        .{ .name = "ResizeNESW", .cursor = raven.R_CURSOR_RESIZE_NESW },
        .{ .name = "Move", .cursor = raven.R_CURSOR_MOVE },
        .{ .name = "NotAllowed", .cursor = raven.R_CURSOR_NOT_ALLOWED },
        .{ .name = "None", .cursor = raven.R_CURSOR_NONE },
    };
    for (0..cursors.len) |i| {
        if (base.rvn_stricmp(value, cursors[i].name) == 0) {
            cursor.* = cursors[i].cursor;
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

export fn rvn_parse_material(text: [*c]const u8, material: [*c]raven.RMaterial) c_int {
    const materials = [_]struct { name: [*c]const u8, material: raven.RMaterial }{
        .{ .name = "Solid", .material = raven.R_MATERIAL_SOLID },
        .{ .name = "Glass", .material = raven.R_MATERIAL_GLASS },
        .{ .name = "ClearGlass", .material = raven.R_MATERIAL_GLASS },
        .{ .name = "FrostedGlass", .material = raven.R_MATERIAL_FROSTED_GLASS },
        .{ .name = "Frosted", .material = raven.R_MATERIAL_FROSTED_GLASS },
        .{ .name = "TintedGlass", .material = raven.R_MATERIAL_TINTED_GLASS },
        .{ .name = "Tinted", .material = raven.R_MATERIAL_TINTED_GLASS },
        .{ .name = "Default", .material = raven.R_MATERIAL_DEFAULT },
        .{ .name = "Theme", .material = raven.R_MATERIAL_DEFAULT },
    };
    for (0..materials.len) |i| {
        if (base.rvn_stricmp(text, materials[i].name) == 0) {
            material.* = materials[i].material;
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

/// "Slot.Xxx": how the widget is placed by its parent. `name` is the part after the dot.
fn rvn_widget_set_slot_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int {
    const slot: [*c]widget_h.rvn_slot_t = &widget.*.slot;
    var values: [4]f32 = undefined;
    var flag: c_int = undefined;
    var count: c_int = undefined;

    if (RVN_ATTR(name, "Padding")) {
        if (rvn_parse_margin(value, &slot.*.padding) == 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "HAlign")) {
        if (base.rvn_stricmp(value, "Fill") == 0) {
            slot.*.halign = raven.R_HALIGN_FILL;
        } else if (base.rvn_stricmp(value, "Left") == 0) {
            slot.*.halign = raven.R_HALIGN_LEFT;
        } else if (base.rvn_stricmp(value, "Center") == 0) {
            slot.*.halign = raven.R_HALIGN_CENTER;
        } else if (base.rvn_stricmp(value, "Right") == 0) {
            slot.*.halign = raven.R_HALIGN_RIGHT;
        } else return raven.R_FALSE;
    } else if (RVN_ATTR(name, "VAlign")) {
        if (base.rvn_stricmp(value, "Fill") == 0) {
            slot.*.valign = raven.R_VALIGN_FILL;
        } else if (base.rvn_stricmp(value, "Top") == 0) {
            slot.*.valign = raven.R_VALIGN_TOP;
        } else if (base.rvn_stricmp(value, "Center") == 0) {
            slot.*.valign = raven.R_VALIGN_CENTER;
        } else if (base.rvn_stricmp(value, "Bottom") == 0) {
            slot.*.valign = raven.R_VALIGN_BOTTOM;
        } else return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Fill")) {
        if (rvn_parse_float(value, &values[0]) == 0 or values[0] < 0.0) return raven.R_FALSE;
        slot.*.is_fill = raven.R_TRUE;
        slot.*.fill = values[0];
    } else if (RVN_ATTR(name, "Auto")) {
        if (rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        slot.*.is_fill = @intFromBool(flag == 0);
    } else if (RVN_ATTR(name, "MaxSize")) {
        if (rvn_parse_float(value, &slot.*.max_size) == 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Column")) {
        if (rvn_parse_int(value, &slot.*.column) == 0 or slot.*.column < 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Row")) {
        if (rvn_parse_int(value, &slot.*.row) == 0 or slot.*.row < 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "ColumnSpan")) {
        if (rvn_parse_int(value, &slot.*.column_span) == 0 or slot.*.column_span < 1) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "RowSpan")) {
        if (rvn_parse_int(value, &slot.*.row_span) == 0 or slot.*.row_span < 1) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Anchors")) {
        // "x,y" pins the widget to a point, "minX,minY,maxX,maxY" stretches it
        count = rvn_parse_floats(value, &values, 4);
        if (count == 2) {
            values[2] = values[0];
            values[3] = values[1];
        } else if (count != 4) {
            return raven.R_FALSE;
        }
        @memcpy(&slot.*.anchors, &values);
    } else if (RVN_ATTR(name, "Position")) {
        if (rvn_parse_floats(value, &slot.*.position, 2) != 2) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Size")) {
        if (rvn_parse_floats(value, &slot.*.size, 2) != 2) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Alignment")) {
        if (rvn_parse_floats(value, &slot.*.alignment, 2) != 2) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Title")) {
        _ = base.rvn_str_set(&slot.*.title, value);
    } else if (RVN_ATTR(name, "Dock")) {
        if (base.rvn_stricmp(value, "Left") == 0) {
            slot.*.dock = raven.R_DOCK_LEFT;
        } else if (base.rvn_stricmp(value, "Right") == 0) {
            slot.*.dock = raven.R_DOCK_RIGHT;
        } else if (base.rvn_stricmp(value, "Top") == 0) {
            slot.*.dock = raven.R_DOCK_TOP;
        } else if (base.rvn_stricmp(value, "Bottom") == 0) {
            slot.*.dock = raven.R_DOCK_BOTTOM;
        } else if (base.rvn_stricmp(value, "Tab") == 0 or base.rvn_stricmp(value, "Center") == 0) {
            slot.*.dock = raven.R_DOCK_TAB;
        } else return raven.R_FALSE;
    } else if (RVN_ATTR(name, "DockTo")) {
        _ = base.rvn_str_set(&slot.*.dock_to, if (value[0] != 0) value else null);
    } else if (RVN_ATTR(name, "DockSize")) {
        if (rvn_parse_float(value, &slot.*.dock_size) == 0 or slot.*.dock_size < 0.0 or slot.*.dock_size >= 1.0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Closable")) {
        if (rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        slot.*.dock_fixed = @intFromBool(flag == 0);
    } else {
        return raven.R_FALSE;
    }
    widget_h.rvn_widget_invalidate_layout(if (widget.*.parent != null) widget.*.parent else widget);
    return raven.R_TRUE;
}

export fn rvn_widget_set_base_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int {
    var color: base.rvn_color_t = undefined;
    var role: raven.RColorRole = undefined;
    var metric: raven.RMetric = undefined;
    var number: f32 = undefined;
    var flag: c_int = undefined;

    if (base.rvn_strnicmp(name, "Slot.", 5) == 0) return rvn_widget_set_slot_attribute(widget, name + 5, value);
    if (base.rvn_strnicmp(name, "Accessible", 10) == 0) {
        const handled = widget_h.rvn_a11y_attribute(widget, name, value);
        if (handled >= 0) return handled;
    }

    if (base.rvn_strnicmp(name, "Color.", 6) == 0) {
        if (rvn_color_role_by_name(name + 6, &role) == 0 or rvn_parse_color(value, &color) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_set_color(widget, role, color);
        return raven.R_TRUE;
    }
    if (base.rvn_strnicmp(name, "Metric.", 7) == 0) {
        if (rvn_metric_by_name(name + 7, &metric) == 0 or rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_set_metric(widget, metric, number);
        return raven.R_TRUE;
    }

    if (RVN_ATTR(name, "Name") or RVN_ATTR(name, "Id")) {
        _ = base.rvn_str_set(&widget.*.name, value);
    } else if (RVN_ATTR(name, "Visibility")) {
        var visibility: raven.RVisibility = undefined;
        if (base.rvn_stricmp(value, "Visible") == 0) {
            visibility = raven.R_VISIBLE;
        } else if (base.rvn_stricmp(value, "Hidden") == 0) {
            visibility = raven.R_HIDDEN;
        } else if (base.rvn_stricmp(value, "Collapsed") == 0) {
            visibility = raven.R_COLLAPSED;
        } else return raven.R_FALSE;
        if (visibility != widget.*.visibility) {
            widget.*.visibility = visibility;
            widget_h.rvn_a11y_structure_changed();
            if (visibility != raven.R_VISIBLE and widget.*.window != null) widget_h.rvn_window_forget_widget(widget.*.window, widget);
            widget_h.rvn_widget_invalidate_layout(if (widget.*.parent != null) widget.*.parent else widget);
        }
    } else if (RVN_ATTR(name, "Enabled")) {
        if (rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        if (flag != 0) widget.*.flags &= ~widget_h.RVN_WF_DISABLED else widget.*.flags |= widget_h.RVN_WF_DISABLED;
        widget_h.rvn_widget_invalidate_paint(widget);
    } else if (RVN_ATTR(name, "HitTestable")) {
        if (rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        if (flag != 0) widget.*.flags &= ~widget_h.RVN_WF_NO_HIT else widget.*.flags |= widget_h.RVN_WF_NO_HIT;
    } else if (RVN_ATTR(name, "Material")) {
        var material: raven.RMaterial = undefined;
        if (rvn_parse_material(value, &material) == 0) return raven.R_FALSE;
        widget.*.material = if (material == raven.R_MATERIAL_DEFAULT) 0 else material;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (RVN_ATTR(name, "Class")) {
        if (base.rvn_str_set(&widget.*.classes, if (value[0] != 0) value else null) != 0) {
            widget.*.style_generation = 0;
            widget_h.rvn_widget_invalidate_layout(widget);
        }
    } else if (RVN_ATTR(name, "Theme")) {
        var theme: [*c]const ctx_h.rvn_theme_t = null;
        if (value[0] != 0 and base.rvn_stricmp(value, "Default") != 0 and base.rvn_stricmp(value, "Inherit") != 0) {
            theme = common_h.rvn_xml_theme(value);
            if (theme == null) return raven.R_FALSE;
        }
        widget_h.rvn_widget_set_theme(widget, theme, @intFromBool(theme != null));
    } else if (RVN_ATTR(name, "WindowDrag")) {
        if (rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        if (flag != 0) {
            widget.*.flags |= widget_h.RVN_WF_WINDOW_DRAG;
            widget.*.flags &= ~widget_h.RVN_WF_NO_HIT;
        } else {
            widget.*.flags &= ~widget_h.RVN_WF_WINDOW_DRAG;
        }
    } else if (RVN_ATTR(name, "Focusable")) {
        if (rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        if (flag != 0) widget.*.flags |= widget_h.RVN_WF_FOCUSABLE else widget.*.flags &= ~widget_h.RVN_WF_FOCUSABLE;
    } else if (RVN_ATTR(name, "Clip")) {
        if (rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        if (flag != 0) widget.*.flags |= widget_h.RVN_WF_CLIP else widget.*.flags &= ~widget_h.RVN_WF_CLIP;
        widget_h.rvn_widget_invalidate_paint(widget);
    } else if (RVN_ATTR(name, "Opacity")) {
        if (rvn_parse_float(value, &number) == 0) return raven.R_FALSE;
        widget.*.opacity = base.rvn_clampf(number, 0.0, 1.0);
        widget_h.rvn_widget_invalidate_paint(widget);
    } else if (RVN_ATTR(name, "Appear")) {
        var transition: raven.RTransition = undefined;
        if (widget_h.rvn_parse_transition(value, &transition) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_set_appear(widget, &transition, null);
    } else if (RVN_ATTR(name, "AppearDelay")) {
        if (rvn_parse_float(value, &number) == 0 or number < 0.0) return raven.R_FALSE;
        widget_h.rvn_widget_set_appear(widget, null, &number);
    } else if (RVN_ATTR(name, "Direction")) {
        var direction: raven.RDirection = undefined;
        if (base.rvn_stricmp(value, "RTL") == 0 or base.rvn_stricmp(value, "RightToLeft") == 0) {
            direction = raven.R_DIRECTION_RTL;
        } else if (base.rvn_stricmp(value, "LTR") == 0 or base.rvn_stricmp(value, "LeftToRight") == 0) {
            direction = raven.R_DIRECTION_LTR;
        } else if (base.rvn_stricmp(value, "Inherit") == 0 or value[0] == 0) {
            direction = raven.R_DIRECTION_INHERIT;
        } else return raven.R_FALSE;
        raven.Rwidget_set_direction(widget.*.id, direction);
    } else if (RVN_ATTR(name, "Tooltip")) {
        _ = base.rvn_str_set(&widget.*.tooltip, if (value[0] != 0) value else null);
    } else if (RVN_ATTR(name, "Cursor")) {
        if (rvn_parse_cursor(value, &widget.*.cursor) == 0) return raven.R_FALSE;
    } else if (RVN_ATTR(name, "Width")) {
        if (rvn_parse_float(value, &widget.*.fixed_size.x) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (RVN_ATTR(name, "Height")) {
        if (rvn_parse_float(value, &widget.*.fixed_size.y) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (RVN_ATTR(name, "MinWidth")) {
        if (rvn_parse_float(value, &widget.*.min_size.x) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (RVN_ATTR(name, "MinHeight")) {
        if (rvn_parse_float(value, &widget.*.min_size.y) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (RVN_ATTR(name, "MaxWidth")) {
        if (rvn_parse_float(value, &widget.*.max_size.x) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (RVN_ATTR(name, "MaxHeight")) {
        if (rvn_parse_float(value, &widget.*.max_size.y) == 0) return raven.R_FALSE;
        widget_h.rvn_widget_invalidate_layout(widget);
    } else if (RVN_ATTR(name, "Action") or RVN_ATTR(name, "OnClicked") or RVN_ATTR(name, "OnChanged") or
        RVN_ATTR(name, "OnCommitted") or RVN_ATTR(name, "OnActivated"))
    {
        _ = base.rvn_str_set(&widget.*.action, if (value[0] != 0) value else null);
    } else {
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_widget_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int {
    var localized: c_int = undefined;
    if (name == null or value == null) return raven.R_FALSE;
    // "@key": the translation of the key, following the language (core/locale.c)
    if (widget_h.rvn_locale_attribute(widget, name, value, &localized) != 0) return localized;
    // a widget built for a tag made by code: the code that made it knows its attributes
    if (widget.*.xml_tag != 0 and xml.rvn_xml_tag_attribute(@ptrCast(widget), name, value) != 0) return raven.R_TRUE;
    // the class goes first: "Text", "Spacing"... may mean something specific for it
    if (widget.*.cls.*.set_attribute != null and widget.*.cls.*.set_attribute.?(widget, name, value) != 0) return raven.R_TRUE;
    return rvn_widget_set_base_attribute(widget, name, value);
}

export fn Rwidget_set_attribute(id: raven.Rid, name: [*c]const u8, value: [*c]const u8) c_int {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_attribute");
    if (widget == null) return raven.R_FALSE;
    if (name == null or value == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rwidget_set_attribute: NULL name or value");
        return raven.R_FALSE;
    }
    return rvn_widget_set_attribute(widget, name, value);
}
