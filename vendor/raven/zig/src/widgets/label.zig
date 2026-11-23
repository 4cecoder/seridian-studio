// Translated to Zig from vendor/raven/src/widgets/label.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/label.c
// Label (Slate STextBlock): one or several lines of text, optionally
// wrapped on the width it receives; or, with Markdown turned on, formatted
// text (widgets/markdown.c).

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const font_h = @import("../render/font_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const rvn_label_t = extern struct {
    base: widget_h.rvn_widget_t,
    text: [*c]u8,
    font: raven.Rid,
    size: f32,
    @"align": raven.RTextAlign,
    wrap: c_int,
    /// R_TRUE once the application chose whether to wrap: Markdown then stops deciding.
    wrap_chosen: c_int,
    /// Width received at the last arrange, used to wrap; 0 before the first one.
    wrap_width: f32,

    markdown: c_int,
    /// The text, parsed and laid out; made when first measured, forgotten when the text changes.
    md: ?*common.rvn_md_t,
    /// Link under the pointer, link the button went down on; -1 = none.
    hot_link: c_int,
    pressed_link: c_int,
    link_callback: raven.RLabelLinkCallback,
    link_user: ?*anyopaque,
    /// Result of Rlabel_get_plain_text.
    plain: [*c]u8,
};

fn rvn_label_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    label.*.font = raven.R_INVALID_ID;
    label.*.@"align" = raven.R_TEXT_ALIGN_LEFT;
    label.*.hot_link = -1;
    label.*.pressed_link = -1;
}

fn rvn_label_forget(label: [*c]rvn_label_t) void {
    common.rvn_md_free(label.*.md);
    label.*.md = null;
    label.*.hot_link = -1;
    label.*.pressed_link = -1;
    label.*.base.cursor = @as(raven.RCursor, 0);
}

fn rvn_label_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    common.rvn_md_free(label.*.md);
    base.rvn_free(label.*.text);
    base.rvn_free(label.*.plain);
}

fn rvn_label_wraps(label: [*c]const rvn_label_t) c_int {
    // formatted text is made of paragraphs: it wraps unless told not to
    return if (label.*.wrap_chosen != 0) label.*.wrap else @intFromBool(label.*.wrap != 0 or label.*.markdown != 0);
}

fn rvn_label_md(label: [*c]rvn_label_t) ?*common.rvn_md_t {
    if (label.*.md == null) {
        label.*.md = common.rvn_md_parse(label.*.text);
        // a label does not take the mouse, unless it has links to click
        if (common.rvn_md_link_count(label.*.md) > 0) label.*.base.flags &= ~widget_h.RVN_WF_NO_HIT else label.*.base.flags |= widget_h.RVN_WF_NO_HIT;
    }
    return label.*.md;
}

const rvn_label_line_fn = ?*const fn ([*c]const u8, c_int, f32, c_int, ?*anyopaque) callconv(.c) void;

/// Splits the text into lines (explicit '\n' and, when `wrap_width` is
/// positive, word wrapping) and calls `visit` for each. Returns the number of
/// lines and the width of the widest one.
fn rvn_label_lines(label: [*c]const rvn_label_t, font: ?*font_h.rvn_font_t, size: f32, wrap_width: f32, max_width: [*c]f32, visit: rvn_label_line_fn, context: ?*anyopaque) c_int {
    var text: [*c]const u8 = if (label.*.text != null) label.*.text else "";
    var remaining: c_int = @intCast(libc.strlen(text));
    var count: c_int = 0;
    var widest: f32 = 0.0;

    while (true) {
        var width: f32 = 0.0;
        const consumed = ext.rvn_text_wrap(font, size, text, remaining, wrap_width, &width);
        var length = consumed;
        // the line itself excludes the newline and the spaces it was cut on
        while (length > 0 and (text[@as(usize, @intCast(length - 1))] == '\n' or text[@as(usize, @intCast(length - 1))] == ' ' or text[@as(usize, @intCast(length - 1))] == '\t')) length -= 1;
        if (visit) |f| f(text, length, width, count, context);
        widest = base.rvn_maxf(widest, width);
        count += 1;
        // a text ending with '\n' has one more, empty, line
        if (consumed == remaining and consumed > 0 and text[@as(usize, @intCast(consumed - 1))] == '\n') {
            if (visit) |f| f(text + @as(usize, @intCast(consumed)), 0, 0.0, count, context);
            count += 1;
        }
        text += @as(usize, @intCast(consumed));
        remaining -= consumed;
        if (!(remaining > 0)) break;
    }

    if (max_width != null) max_width.* = widest;
    return count;
}

fn rvn_label_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    const font = ext.rvn_font_resolve(label.*.font);
    const size = common.rvn_widget_font_size(widget, label.*.size);
    var metrics: font_h.rvn_font_metrics_t = undefined;
    var width: f32 = 0.0;
    const wraps = rvn_label_wraps(label);

    if (font == null) return base.rvn_vec2(0.0, 0.0);
    if (label.*.markdown != 0) return common.rvn_md_layout(rvn_label_md(label), widget, label.*.font, size, if (wraps != 0) label.*.wrap_width else 0.0);
    ext.rvn_font_metrics(font, size, &metrics);
    const lines = rvn_label_lines(label, font, size, if (wraps != 0) label.*.wrap_width else 0.0, &width, null, null);
    // a wrapped label keeps the width it was given, or it would be re-wrapped
    // narrower and narrower by a parent that sizes it to its content
    if (wraps != 0 and label.*.wrap_width > 0.0 and lines > 1) width = base.rvn_maxf(width, label.*.wrap_width);
    return base.rvn_vec2(@ceil(width), @ceil(metrics.line_height * @as(f32, @floatFromInt(lines))));
}

fn rvn_label_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    if (rvn_label_wraps(label) != 0 and @abs(label.*.wrap_width - widget.*.rect.w) > 0.01) {
        label.*.wrap_width = widget.*.rect.w;
        // the height we announced was computed for another width
        ext.rvn_widget_invalidate_layout(widget);
    }
}

const rvn_label_paint_t = extern struct {
    label: [*c]rvn_label_t,
    painter: ?*raven.RPainter,
    size: f32,
    line_height: f32,
    @"align": f32,
    color: base.rvn_color_t,
};

fn rvn_label_paint_line(line: [*c]const u8, length: c_int, width: f32, index: c_int, context: ?*anyopaque) callconv(.c) void {
    const paint: [*c]rvn_label_paint_t = @ptrCast(@alignCast(context));
    const x = (paint.*.label.*.base.rect.w - width) * paint.*.@"align";
    if (length <= 0) return;
    ext.rvn_paint_text(paint.*.painter, paint.*.label.*.font, paint.*.size, x, paint.*.line_height * @as(f32, @floatFromInt(index)), line, length, paint.*.color);
}

// Where formatted text starts across, when it is narrower than the label.
fn rvn_label_md_x(label: [*c]const rvn_label_t) f32 {
    const align_: f32 = if (label.*.@"align" == raven.R_TEXT_ALIGN_CENTER) 0.5 else if (label.*.@"align" == raven.R_TEXT_ALIGN_RIGHT) 1.0 else 0.0;
    return @floor(base.rvn_maxf(0.0, label.*.base.rect.w - label.*.base.desired.x) * align_);
}

fn rvn_label_paint(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter) callconv(.c) void {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    const font = ext.rvn_font_resolve(label.*.font);
    var metrics: font_h.rvn_font_metrics_t = undefined;
    var paint: rvn_label_paint_t = undefined;

    if (font == null or label.*.text == null or label.*.text[0] == 0) return;
    // text larger than the space it received is cut at the bounds of the label
    const clipped = widget.*.desired.x > widget.*.rect.w + 0.5 or widget.*.desired.y > widget.*.rect.h + 0.5;
    if (label.*.markdown != 0) {
        // (laid out when it was measured)
        if (label.*.md == null) return;
        const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
        if (clipped) ext.rvn_paint_push_clip(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h));
        common.rvn_md_paint(label.*.md, widget, painter, if (dp.rtl != 0) base.rvn_maxf(0.0, widget.*.rect.w - widget.*.desired.x) - rvn_label_md_x(label) else rvn_label_md_x(label), 0.0, ext.rvn_widget_text_color(widget, painter), if (dp.enabled != 0) label.*.hot_link else -1);
        if (clipped) ext.rvn_paint_pop_clip(painter);
        return;
    }
    paint.label = label;
    paint.painter = painter;
    paint.size = common.rvn_widget_font_size(widget, label.*.size);
    ext.rvn_font_metrics(font, paint.size, &metrics);
    paint.line_height = metrics.line_height;
    paint.@"align" = if (label.*.@"align" == raven.R_TEXT_ALIGN_CENTER) 0.5 else if (label.*.@"align" == raven.R_TEXT_ALIGN_RIGHT) 1.0 else 0.0;
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    if (dp.rtl != 0) paint.@"align" = 1.0 - paint.@"align";
    paint.color = ext.rvn_widget_text_color(widget, painter);

    if (clipped) ext.rvn_paint_push_clip(painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h));
    _ = rvn_label_lines(label, font, paint.size, if (rvn_label_wraps(label) != 0) widget.*.rect.w else 0.0, null, &rvn_label_paint_line, &paint);
    if (clipped) ext.rvn_paint_pop_clip(painter);
}

fn rvn_label_set_hot(widget: [*c]widget_h.rvn_widget_t, link: c_int) void {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    if (label.*.hot_link == link) return;
    label.*.hot_link = link;
    widget.*.cursor = if (link >= 0) @as(raven.RCursor, raven.R_CURSOR_HAND) else @as(raven.RCursor, 0);
    ext.rvn_widget_invalidate_paint(widget);
}

fn rvn_label_follow(widget: [*c]widget_h.rvn_widget_t, link: c_int) void {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    const address = common.rvn_md_link(label.*.md, link);
    if (address == null) return;
    // (the callback may change the text, and the links with it)
    const url = base.rvn_strdup(address);
    if (label.*.link_callback) |callback| {
        callback(widget.*.id, url, label.*.link_user);
    } else if (base.rvn_strnicmp(url, "action:", 7) == 0) {
        if (url[7] != 0) ext.rvn_fire_action(widget.*.id, url + 7);
    } else if (base.rvn_strnicmp(url, "http://", 7) == 0 or base.rvn_strnicmp(url, "https://", 8) == 0 or base.rvn_strnicmp(url, "mailto:", 7) == 0) {
        _ = raven.Ropen_url(url);
    }
    base.rvn_free(url);
}

fn rvn_label_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    var link: c_int = undefined;
    if (label.*.markdown == 0 or label.*.md == null) return raven.R_FALSE;
    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            rvn_label_set_hot(widget, common.rvn_md_link_at(label.*.md, event.*.local_x - rvn_label_md_x(label), event.*.local_y));
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            rvn_label_set_hot(widget, -1);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            link = common.rvn_md_link_at(label.*.md, event.*.local_x - rvn_label_md_x(label), event.*.local_y);
            label.*.pressed_link = link;
            // (text that is not a link lets the click go to what holds the label)
            return @intFromBool(link >= 0);
        },
        raven.R_EVENT_MOUSE_UP => {
            if (event.*.button != raven.R_MOUSE_LEFT) return raven.R_FALSE;
            link = common.rvn_md_link_at(label.*.md, event.*.local_x - rvn_label_md_x(label), event.*.local_y);
            if (link >= 0 and link == label.*.pressed_link) {
                label.*.pressed_link = -1;
                rvn_label_follow(widget, link);
                return raven.R_TRUE;
            }
            label.*.pressed_link = -1;
            return raven.R_FALSE;
        },
        else => return raven.R_FALSE,
    }
}

fn rvn_label_set_markdown(widget: [*c]widget_h.rvn_widget_t, enabled: c_int) void {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    const enabled_: c_int = @intFromBool(enabled != 0);
    if (label.*.markdown == enabled_) return;
    label.*.markdown = enabled_;
    rvn_label_forget(label);
    if (enabled_ == 0) widget.*.flags |= widget_h.RVN_WF_NO_HIT;
    ext.rvn_widget_invalidate_layout(widget);
}

fn rvn_label_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const label: [*c]rvn_label_t = @ptrCast(widget);
    var color: base.rvn_color_t = undefined;
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Text") == 0) {
        if (base.rvn_str_set(&label.*.text, value) != 0) rvn_label_forget(label);
    } else if (base.rvn_stricmp(name, "Font") == 0) {
        const font = common.rvn_xml_font(value);
        if (font == raven.R_INVALID_ID) return raven.R_FALSE;
        label.*.font = font;
    } else if (base.rvn_stricmp(name, "FontSize") == 0 or base.rvn_stricmp(name, "TextSize") == 0) {
        if (ext.rvn_parse_float(value, &label.*.size) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Align") == 0 or base.rvn_stricmp(name, "TextAlign") == 0) {
        if (base.rvn_stricmp(value, "Left") == 0) label.*.@"align" = raven.R_TEXT_ALIGN_LEFT else if (base.rvn_stricmp(value, "Center") == 0) label.*.@"align" = raven.R_TEXT_ALIGN_CENTER else if (base.rvn_stricmp(value, "Right") == 0) label.*.@"align" = raven.R_TEXT_ALIGN_RIGHT else return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Wrap") == 0) {
        if (ext.rvn_parse_bool(value, &label.*.wrap) == 0) return raven.R_FALSE;
        label.*.wrap_chosen = raven.R_TRUE;
    } else if (base.rvn_stricmp(name, "Markdown") == 0) {
        if (ext.rvn_parse_bool(value, &flag) == 0) return raven.R_FALSE;
        rvn_label_set_markdown(widget, flag);
    } else if (base.rvn_stricmp(name, "Color") == 0) {
        if (ext.rvn_parse_color(value, &color) == 0) return raven.R_FALSE;
        ext.rvn_widget_set_color(widget, raven.R_COLOR_TEXT, color);
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_label: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_LABEL,
    .name = "Label",
    .size = @sizeOf(rvn_label_t),
    .flags = widget_h.RVN_CF_NO_HIT | widget_h.RVN_CF_NO_CHILDREN,
    .init = rvn_label_init,
    .destroy = rvn_label_destroy,
    .measure = rvn_label_measure,
    .arrange = rvn_label_arrange,
    .paint = rvn_label_paint,
    .event = rvn_label_event,
    .set_attribute = rvn_label_set_attribute,
});

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rlabel_create(text: [*c]const u8) raven.Rid {
    if (ext.rvn_api_check("Rlabel_create") == 0) return raven.R_INVALID_ID;
    const widget = ext.rvn_widget_create(raven.R_WIDGET_LABEL);
    if (widget == null) return raven.R_INVALID_ID;
    const label: [*c]rvn_label_t = @ptrCast(widget);
    label.*.text = base.rvn_strdup(text);
    return widget.*.id;
}

export fn Rlabel_set_text(id: raven.Rid, text: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_set_text");
    if (widget == null) return;
    const label: [*c]rvn_label_t = @ptrCast(widget);
    if (base.rvn_str_set(&label.*.text, text) != 0) {
        rvn_label_forget(label);
        ext.rvn_widget_invalidate_layout(widget);
    }
}

export fn Rlabel_get_text(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_get_text");
    if (widget == null) return "";
    const label: [*c]rvn_label_t = @ptrCast(widget);
    return if (label.*.text != null) label.*.text else "";
}

export fn Rlabel_set_font(id: raven.Rid, font: raven.Rid) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_set_font");
    if (widget == null) return;
    if (font != raven.R_INVALID_ID and raven.Rfont_is_valid(font) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rlabel_set_font: invalid font");
        return;
    }
    const label: [*c]rvn_label_t = @ptrCast(widget);
    label.*.font = font;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rlabel_set_text_size(id: raven.Rid, size: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_set_text_size");
    if (widget == null) return;
    const label: [*c]rvn_label_t = @ptrCast(widget);
    label.*.size = if (size > 0.0) size else 0.0;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rlabel_set_text_align(id: raven.Rid, align_: raven.RTextAlign) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_set_text_align");
    if (widget == null) return;
    if (align_ < raven.R_TEXT_ALIGN_LEFT or align_ > raven.R_TEXT_ALIGN_RIGHT) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rlabel_set_text_align: invalid alignment");
        return;
    }
    const label: [*c]rvn_label_t = @ptrCast(widget);
    label.*.@"align" = align_;
    ext.rvn_widget_invalidate_paint(widget);
}

export fn Rlabel_set_wrap(id: raven.Rid, wrap: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_set_wrap");
    if (widget == null) return;
    const label: [*c]rvn_label_t = @ptrCast(widget);
    label.*.wrap = @intFromBool(wrap != 0);
    label.*.wrap_chosen = raven.R_TRUE;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rlabel_set_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_set_color");
    if (widget == null) return;
    ext.rvn_widget_set_color(widget, raven.R_COLOR_TEXT, base.rvn_rgba(r, g, b, a));
}

export fn Rlabel_set_markdown(id: raven.Rid, enabled: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_set_markdown");
    if (widget == null) return;
    rvn_label_set_markdown(widget, enabled);
}

export fn Rlabel_get_markdown(id: raven.Rid) c_int {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_get_markdown");
    if (widget == null) return raven.R_FALSE;
    const label: [*c]rvn_label_t = @ptrCast(widget);
    return label.*.markdown;
}

export fn Rlabel_set_link_callback(id: raven.Rid, callback: raven.RLabelLinkCallback, user_data: ?*anyopaque) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_set_link_callback");
    if (widget == null) return;
    const label: [*c]rvn_label_t = @ptrCast(widget);
    label.*.link_callback = callback;
    label.*.link_user = user_data;
}

export fn Rlabel_get_plain_text(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_LABEL, "Rlabel_get_plain_text");
    if (widget == null) return "";
    const label: [*c]rvn_label_t = @ptrCast(widget);
    var out: base.rvn_text_t = undefined;
    if (label.*.markdown == 0) return if (label.*.text != null) label.*.text else "";
    @memset(std.mem.asBytes(&out), 0);
    common.rvn_md_plain_text(rvn_label_md(label), &out);
    base.rvn_free(label.*.plain);
    label.*.plain = out.data;
    return if (label.*.plain != null) label.*.plain else "";
}
