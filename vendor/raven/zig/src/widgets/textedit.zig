// Translated to Zig from vendor/raven/src/widgets/textedit.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/textedit.c
// Single-line text editing model: buffer, caret, selection, clipboard and
// painting. TextInput and SpinBox embed one.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const thread_h = @import("../core/thread_h.zig");
const libc = @import("../sys/libc.zig");
const widget_h = @import("../widget/widget_h.zig");
const font_h = @import("../render/font_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common = @import("common_h.zig");

// #define RVN_BULLET "\xE2\x80\xA2" /* U+2022, shown instead of password characters */
const RVN_BULLET = "\xE2\x80\xA2";

export fn rvn_textedit_init(edit: [*c]common.rvn_textedit_t) void {
    _ = libc.memset(edit, 0, @sizeOf(common.rvn_textedit_t));
    edit.*.cap = 32;
    edit.*.text = @ptrCast(base.rvn_alloc(@as(usize, @intCast(edit.*.cap))));
    edit.*.text[0] = '\x00';
    edit.*.blink_timer = raven.R_INVALID_ID;
}

export fn rvn_textedit_free(edit: [*c]common.rvn_textedit_t) void {
    if (edit.*.blink_timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(edit.*.blink_timer) != 0) raven.Rtimer_destroy(edit.*.blink_timer);
    base.rvn_free(edit.*.text);
    _ = libc.memset(edit, 0, @sizeOf(common.rvn_textedit_t));
    edit.*.blink_timer = raven.R_INVALID_ID;
}

// ---------------------------------------------------------------------------
//  Buffer
// ---------------------------------------------------------------------------

fn rvn_te_min(edit: [*c]const common.rvn_textedit_t) c_int {
    return base.rvn_mini(edit.*.caret, edit.*.anchor);
}
fn rvn_te_max(edit: [*c]const common.rvn_textedit_t) c_int {
    return base.rvn_maxi(edit.*.caret, edit.*.anchor);
}
fn rvn_te_has_selection(edit: [*c]const common.rvn_textedit_t) c_int {
    return @intFromBool(edit.*.caret != edit.*.anchor);
}

fn rvn_te_delete(edit: [*c]common.rvn_textedit_t, from: c_int, to: c_int) void {
    if (to <= from) return;
    _ = libc.memmove(edit.*.text + @as(usize, @intCast(from)), edit.*.text + @as(usize, @intCast(to)), @as(usize, @intCast(edit.*.length - to)) + 1);
    edit.*.length -= to - from;
    edit.*.caret = from;
    edit.*.anchor = from;
}

// Inserts at the caret, replacing the selection. Returns R_TRUE when something was inserted.
fn rvn_te_insert(edit: [*c]common.rvn_textedit_t, text: [*c]const u8, length_in: c_int) c_int {
    var length = length_in;
    if (rvn_te_has_selection(edit) != 0) rvn_te_delete(edit, rvn_te_min(edit), rvn_te_max(edit));
    if (edit.*.max_chars > 0) {
        // cut the insertion at a character boundary
        var room = edit.*.max_chars - base.rvn_utf8_count(edit.*.text, edit.*.length);
        var fit: c_int = 0;
        while (room > 0 and fit < length) {
            fit = base.rvn_utf8_next(text, length, fit);
            room -= 1;
        }
        length = fit;
    }
    if (length <= 0) return raven.R_FALSE;
    if (edit.*.length + length + 1 > edit.*.cap) {
        while (edit.*.length + length + 1 > edit.*.cap) edit.*.cap *= 2;
        edit.*.text = @ptrCast(base.rvn_realloc(edit.*.text, @as(usize, @intCast(edit.*.cap))));
    }
    _ = libc.memmove(edit.*.text + @as(usize, @intCast(edit.*.caret + length)), edit.*.text + @as(usize, @intCast(edit.*.caret)), @as(usize, @intCast(edit.*.length - edit.*.caret)) + 1);
    _ = libc.memcpy(edit.*.text + @as(usize, @intCast(edit.*.caret)), text, @as(usize, @intCast(length)));
    edit.*.length += length;
    edit.*.caret += length;
    edit.*.anchor = edit.*.caret;
    return raven.R_TRUE;
}

export fn rvn_textedit_set_text(edit: [*c]common.rvn_textedit_t, text_in: [*c]const u8) c_int {
    var text = text_in;
    if (text == null) text = "";
    if (libc.strcmp(edit.*.text, text) == 0) return raven.R_FALSE;
    const length: c_int = @intCast(libc.strlen(text));
    if (length + 1 > edit.*.cap) {
        while (length + 1 > edit.*.cap) edit.*.cap *= 2;
        edit.*.text = @ptrCast(base.rvn_realloc(edit.*.text, @as(usize, @intCast(edit.*.cap))));
    }
    _ = libc.memcpy(edit.*.text, text, @as(usize, @intCast(length)) + 1);
    edit.*.length = length;
    edit.*.caret = length;
    edit.*.anchor = length;
    edit.*.scroll = 0.0;
    return raven.R_TRUE;
}

export fn rvn_textedit_select_all(edit: [*c]common.rvn_textedit_t) void {
    edit.*.anchor = 0;
    edit.*.caret = edit.*.length;
}

fn rvn_te_is_space(c: u8) c_int {
    return @intFromBool(c == ' ' or c == '\t');
}

fn rvn_te_word_left(edit: [*c]const common.rvn_textedit_t, offset_in: c_int) c_int {
    var offset = offset_in;
    while (offset > 0 and rvn_te_is_space(edit.*.text[@as(usize, @intCast(offset - 1))]) != 0) offset -= 1;
    while (offset > 0 and rvn_te_is_space(edit.*.text[@as(usize, @intCast(offset - 1))]) == 0) offset -= 1;
    return offset;
}

fn rvn_te_word_right(edit: [*c]const common.rvn_textedit_t, offset_in: c_int) c_int {
    var offset = offset_in;
    while (offset < edit.*.length and rvn_te_is_space(edit.*.text[@as(usize, @intCast(offset))]) == 0) offset += 1;
    while (offset < edit.*.length and rvn_te_is_space(edit.*.text[@as(usize, @intCast(offset))]) != 0) offset += 1;
    return offset;
}

// ---------------------------------------------------------------------------
//  Focus and caret blinking
// ---------------------------------------------------------------------------

fn rvn_te_blink(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const widget = widget_h.rvn_widget_get(@truncate(@intFromPtr(user_data)));
    _ = timer; // RVN_UNUSED(timer)
    if (widget != null) widget_h.rvn_widget_invalidate_paint(widget);
}

export fn rvn_textedit_set_focused(edit: [*c]common.rvn_textedit_t, widget: [*c]widget_h.rvn_widget_t, focused: c_int) void {
    if (focused != 0) {
        edit.*.blink_start = thread_h.rvn_clock_seconds();
        if (edit.*.blink_timer == raven.R_INVALID_ID) {
            edit.*.blink_timer = raven.Rtimer_create(0.5, raven.R_TRUE, &rvn_te_blink, @ptrFromInt(@as(usize, widget.*.id)));
        }
    } else {
        if (edit.*.blink_timer != raven.R_INVALID_ID) {
            if (raven.Rtimer_is_valid(edit.*.blink_timer) != 0) raven.Rtimer_destroy(edit.*.blink_timer);
            edit.*.blink_timer = raven.R_INVALID_ID;
        }
        edit.*.mouse_selecting = raven.R_FALSE;
        edit.*.anchor = edit.*.caret;
        edit.*.scroll = 0.0;
    }
    widget_h.rvn_widget_invalidate_paint(widget);
}

// ---------------------------------------------------------------------------
//  Keyboard
// ---------------------------------------------------------------------------

fn rvn_te_copy(edit: [*c]const common.rvn_textedit_t) void {
    if (edit.*.password != 0 or rvn_te_has_selection(edit) == 0) return;
    const copy = base.rvn_strndup(edit.*.text + @as(usize, @intCast(rvn_te_min(edit))), @as(usize, @intCast(rvn_te_max(edit) - rvn_te_min(edit))));
    raven.Rclipboard_set_text(copy);
    base.rvn_free(copy);
}

fn rvn_te_paste(edit: [*c]common.rvn_textedit_t) c_int {
    const clip = raven.Rclipboard_get_text();
    if (clip == null or clip[0] == 0) return raven.R_FALSE;
    // a single-line editor keeps the first line and turns tabs into spaces
    const length = libc.strcspn(clip, "\r\n");
    const line = base.rvn_strndup(clip, length);
    var i: usize = 0;
    while (i < length) : (i += 1) {
        if (line[i] < 32) line[i] = ' ';
    }
    const changed = rvn_te_insert(edit, line, @intCast(length));
    base.rvn_free(line);
    return changed;
}

export fn rvn_textedit_key(edit: [*c]common.rvn_textedit_t, event: [*c]const raven.REvent) c_int {
    const shift: c_int = @intFromBool((event.*.modifiers & raven.R_MOD_SHIFT) != 0);
    const command: c_int = @intFromBool((event.*.modifiers & (raven.R_MOD_CTRL | raven.R_MOD_SUPER)) != 0);
    const alt: c_int = @intFromBool((event.*.modifiers & raven.R_MOD_ALT) != 0);
    var result: c_int = common.RVN_TEXTEDIT_HANDLED;
    var target: c_int = undefined;
    // `goto printable` in C: set by the cases that type a character, and by default
    var printable = false;

    if (event.*.@"type" != raven.R_EVENT_KEY_DOWN) return 0;

    switch (event.*.key) {
        raven.R_KEY_LEFT => {
            if (shift == 0 and rvn_te_has_selection(edit) != 0) {
                target = rvn_te_min(edit);
            } else {
                target = if (command != 0) rvn_te_word_left(edit, edit.*.caret) else base.rvn_utf8_prev(edit.*.text, edit.*.caret);
            }
            edit.*.caret = target;
            if (shift == 0) edit.*.anchor = target;
        },
        raven.R_KEY_RIGHT => {
            if (shift == 0 and rvn_te_has_selection(edit) != 0) {
                target = rvn_te_max(edit);
            } else {
                target = if (command != 0) rvn_te_word_right(edit, edit.*.caret) else base.rvn_utf8_next(edit.*.text, edit.*.length, edit.*.caret);
            }
            edit.*.caret = target;
            if (shift == 0) edit.*.anchor = target;
        },
        raven.R_KEY_HOME => {
            edit.*.caret = 0;
            if (shift == 0) edit.*.anchor = 0;
        },
        raven.R_KEY_END => {
            edit.*.caret = edit.*.length;
            if (shift == 0) edit.*.anchor = edit.*.length;
        },
        raven.R_KEY_BACKSPACE => {
            if (edit.*.read_only == 0) {
                if (rvn_te_has_selection(edit) != 0) {
                    rvn_te_delete(edit, rvn_te_min(edit), rvn_te_max(edit));
                    result |= common.RVN_TEXTEDIT_CHANGED;
                } else if (edit.*.caret > 0) {
                    rvn_te_delete(edit, if (command != 0) rvn_te_word_left(edit, edit.*.caret) else base.rvn_utf8_prev(edit.*.text, edit.*.caret), edit.*.caret);
                    result |= common.RVN_TEXTEDIT_CHANGED;
                }
            }
        },
        raven.R_KEY_DELETE => {
            if (edit.*.read_only == 0) {
                if (rvn_te_has_selection(edit) != 0) {
                    rvn_te_delete(edit, rvn_te_min(edit), rvn_te_max(edit));
                    result |= common.RVN_TEXTEDIT_CHANGED;
                } else if (edit.*.caret < edit.*.length) {
                    rvn_te_delete(edit, edit.*.caret, if (command != 0) rvn_te_word_right(edit, edit.*.caret) else base.rvn_utf8_next(edit.*.text, edit.*.length, edit.*.caret));
                    result |= common.RVN_TEXTEDIT_CHANGED;
                }
            }
        },
        raven.R_KEY_ENTER, raven.R_KEY_KP_ENTER => {
            result |= common.RVN_TEXTEDIT_COMMITTED;
        },
        raven.R_KEY_A => {
            if (command == 0) {
                printable = true;
            } else {
                rvn_textedit_select_all(edit);
            }
        },
        raven.R_KEY_C => {
            if (command == 0) {
                printable = true;
            } else {
                rvn_te_copy(edit);
            }
        },
        raven.R_KEY_X => {
            if (command == 0) {
                printable = true;
            } else {
                rvn_te_copy(edit);
                if (edit.*.read_only == 0 and edit.*.password == 0 and rvn_te_has_selection(edit) != 0) {
                    rvn_te_delete(edit, rvn_te_min(edit), rvn_te_max(edit));
                    result |= common.RVN_TEXTEDIT_CHANGED;
                }
            }
        },
        raven.R_KEY_V => {
            if (command == 0) {
                printable = true;
            } else {
                if (edit.*.read_only == 0 and rvn_te_paste(edit) != 0) result |= common.RVN_TEXTEDIT_CHANGED;
            }
        },
        else => printable = true,
    }
    if (printable) {
        // keys that type a character are consumed so that they never trigger
        // a window shortcut; the character itself arrives as a text event
        if (command != 0 or alt != 0 or @as(c_int, @bitCast(event.*.key)) >= 256 or event.*.key == raven.R_KEY_UNKNOWN) return 0;
        return common.RVN_TEXTEDIT_HANDLED;
    }
    edit.*.blink_start = thread_h.rvn_clock_seconds();
    return result;
}

export fn rvn_textedit_input(edit: [*c]common.rvn_textedit_t, codepoint: u32) c_int {
    var encoded: [4]u8 = undefined;
    if (edit.*.read_only != 0 or codepoint < 32 or codepoint == 127) return 0;
    const length = base.rvn_utf8_encode(codepoint, &encoded);
    edit.*.blink_start = thread_h.rvn_clock_seconds();
    return if (rvn_te_insert(edit, &encoded, length) != 0) (common.RVN_TEXTEDIT_HANDLED | common.RVN_TEXTEDIT_CHANGED) else common.RVN_TEXTEDIT_HANDLED;
}

// ---------------------------------------------------------------------------
//  Geometry (password mode shows one bullet per character)
// ---------------------------------------------------------------------------

fn rvn_te_offset_to_x(edit: [*c]const common.rvn_textedit_t, font: ?*font_h.rvn_font_t, size: f32, offset: c_int) f32 {
    if (edit.*.password != 0) {
        return font_h.rvn_text_width(font, size, RVN_BULLET, -1) * @as(f32, @floatFromInt(base.rvn_utf8_count(edit.*.text, offset)));
    }
    return font_h.rvn_text_width(font, size, edit.*.text, offset);
}

fn rvn_te_x_to_offset(edit: [*c]const common.rvn_textedit_t, font: ?*font_h.rvn_font_t, size: f32, x: f32) c_int {
    if (edit.*.password != 0) {
        const bullet = font_h.rvn_text_width(font, size, RVN_BULLET, -1);
        const count = base.rvn_utf8_count(edit.*.text, edit.*.length);
        var index: c_int = if (bullet > 0.0) base.rvn_clampi(@as(c_int, @intFromFloat(x / bullet + 0.5)), 0, count) else 0;
        var offset: c_int = 0;
        while (index > 0) {
            index -= 1;
            offset = base.rvn_utf8_next(edit.*.text, edit.*.length, offset);
        }
        return offset;
    }
    return font_h.rvn_text_offset_at(font, size, edit.*.text, edit.*.length, x);
}

export fn rvn_textedit_mouse_down(edit: [*c]common.rvn_textedit_t, widget: [*c]const widget_h.rvn_widget_t, font_id: raven.Rid, size_: f32, x: f32, clicks: c_int, extend: c_int) void {
    const font = font_h.rvn_font_resolve(font_id);
    if (font == null) return;
    const size = common.rvn_widget_font_size(widget, size_);
    const offset = rvn_te_x_to_offset(edit, font, size, x + edit.*.scroll);
    if (clicks >= 3) {
        rvn_textedit_select_all(edit);
    } else if (clicks == 2 and edit.*.password == 0) {
        edit.*.anchor = rvn_te_word_left(edit, base.rvn_mini(offset + 1, edit.*.length));
        edit.*.caret = rvn_te_word_right(edit, edit.*.anchor);
        // a double click selects the word, not the spaces after it
        while (edit.*.caret > edit.*.anchor and rvn_te_is_space(edit.*.text[@as(usize, @intCast(edit.*.caret - 1))]) != 0) edit.*.caret -= 1;
    } else {
        edit.*.caret = offset;
        if (extend == 0) edit.*.anchor = offset;
        edit.*.mouse_selecting = raven.R_TRUE;
    }
    edit.*.blink_start = thread_h.rvn_clock_seconds();
}

export fn rvn_textedit_mouse_drag(edit: [*c]common.rvn_textedit_t, widget: [*c]const widget_h.rvn_widget_t, font_id: raven.Rid, size_: f32, x: f32) void {
    const font = font_h.rvn_font_resolve(font_id);
    if (font == null or edit.*.mouse_selecting == 0) return;
    const size = common.rvn_widget_font_size(widget, size_);
    edit.*.caret = rvn_te_x_to_offset(edit, font, size, x + edit.*.scroll);
}

// ---------------------------------------------------------------------------
//  Paint
// ---------------------------------------------------------------------------

export fn rvn_textedit_paint(edit: [*c]common.rvn_textedit_t, widget: [*c]const widget_h.rvn_widget_t, painter: ?*raven.RPainter, area: base.rvn_rect_t, font_id: raven.Rid, size_: f32, color: base.rvn_color_t, focused: c_int) void {
    const font = font_h.rvn_font_resolve(font_id);
    var metrics: font_h.rvn_font_metrics_t = undefined;

    if (font == null) return;
    const size = common.rvn_widget_font_size(widget, size_);
    font_h.rvn_font_metrics(font, size, &metrics);
    const text_y = area.y + (area.h - metrics.line_height) * 0.5;
    const caret_x = rvn_te_offset_to_x(edit, font, size, edit.*.caret);
    const text_width = rvn_te_offset_to_x(edit, font, size, edit.*.length);

    // scroll horizontally so that the caret stays visible
    if (focused != 0) {
        if (caret_x - edit.*.scroll > area.w - 1.0) edit.*.scroll = caret_x - area.w + 1.0;
        if (caret_x - edit.*.scroll < 0.0) edit.*.scroll = caret_x;
    }
    const max_scroll = base.rvn_maxf(0.0, text_width - area.w + 1.0);
    edit.*.scroll = base.rvn_clampf(edit.*.scroll, 0.0, max_scroll);

    draw_h.rvn_paint_push_clip(@ptrCast(@alignCast(painter)), area);
    if (focused != 0 and rvn_te_has_selection(edit) != 0) {
        const x0 = rvn_te_offset_to_x(edit, font, size, rvn_te_min(edit));
        const x1 = rvn_te_offset_to_x(edit, font, size, rvn_te_max(edit));
        draw_h.rvn_paint_rect(@ptrCast(@alignCast(painter)), base.rvn_rect(area.x + x0 - edit.*.scroll, text_y, x1 - x0, metrics.line_height), widget_h.rvn_widget_color(widget, raven.R_COLOR_SELECTION));
    }
    if (edit.*.password != 0) {
        const count = base.rvn_utf8_count(edit.*.text, edit.*.length);
        var i: c_int = 0;
        const bullets: [*c]u8 = @ptrCast(base.rvn_alloc(@as(usize, @intCast(count)) * 3 + 1));
        while (i < count) : (i += 1) {
            _ = libc.memcpy(bullets + @as(usize, @intCast(i)) * 3, RVN_BULLET, 3);
        }
        bullets[@as(usize, @intCast(count)) * 3] = '\x00';
        draw_h.rvn_paint_text(@ptrCast(@alignCast(painter)), font_id, size, area.x - edit.*.scroll, text_y, bullets, count * 3, color);
        base.rvn_free(bullets);
    } else {
        draw_h.rvn_paint_text(@ptrCast(@alignCast(painter)), font_id, size, area.x - edit.*.scroll, text_y, edit.*.text, edit.*.length, color);
    }
    if (focused != 0 and edit.*.read_only == 0 and libc.fmod(thread_h.rvn_clock_seconds() - edit.*.blink_start, 1.0) < 0.5) {
        draw_h.rvn_paint_rect(@ptrCast(@alignCast(painter)), base.rvn_rect(area.x + caret_x - edit.*.scroll, text_y, 1.0, metrics.line_height), color);
    }
    draw_h.rvn_paint_pop_clip(@ptrCast(@alignCast(painter)));
}
