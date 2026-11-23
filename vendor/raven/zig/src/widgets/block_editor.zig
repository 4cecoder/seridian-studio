// Translated to Zig from vendor/raven/src/widgets/block_editor.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/block_editor.c
// Block editor: programs made of blocks that snap into each other, in the
// style of Scratch. A palette of kinds of blocks on the left, the canvas on
// the right (it pans and zooms).
//
//   Statement   a step: it snaps under another one (a notch on top, a tab under)
//   Hat         starts a script: nothing above it
//   Cap         ends a script: nothing under it
//   C           wraps one or more stacks in its mouths: "repeat %n{10}", "if %b then|else"
//   Reporter    a rounded value that goes into a slot: "x position", "%n + %n"
//   Boolean     a hexagonal condition: "touching %s ?", "%b and %b"
//
// Labels: words, and slots: %n number, %s text, %b boolean, %r any value,
// %m a choice in a menu (Rblock_editor_set_slot_options); {text} right after
// a slot is its default value; | separates the sections of a C block (each
// section is followed by a mouth).
//
// Dragging a statement takes it and everything under it. While it is carried,
// the place it would go opens (the blocks below glide away) and a shadow of
// it waits there; a value slot that would take a reporter lights up. Dropped
// on the palette, it is deleted. Everything moves with springs.
//
// Mouse: left click selects (Ctrl / Shift: adds), left drag on the canvas
// draws a selection rectangle, dragging a block of a selection moves the
// whole selection; right drag (or middle, or Alt + left) pans, a right click
// opens the context menu; Ctrl + wheel zooms.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const libc = @import("../sys/libc.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const xml_h = @import("../xml/xml_h.zig");
const ctx_h = @import("../core/context_h.zig");

const R_TRUE: c_int = raven.R_TRUE;
const R_FALSE: c_int = raven.R_FALSE;

const RVN_BE_MAX_SLOTS = 12;
const RVN_BE_MAX_MOUTHS = 6;
const RVN_BE_PALETTE_W: f32 = 210.0;
const RVN_BE_SNAP: f32 = 34.0;
const RVN_BE_ARM: f32 = 18.0;
const RVN_BE_BOTTOM: f32 = 18.0;
const RVN_BE_MOUTH_MIN: f32 = 26.0;
const RVN_BE_NOTCH_X: f32 = 14.0;
const RVN_BE_NOTCH_W: f32 = 18.0;
const RVN_BE_NOTCH_D: f32 = 5.0;
const RVN_BE_RADIUS: f32 = 5.0;
const RVN_BE_GRID: f32 = 24.0;

/// C int boolean from a Zig bool.
inline fn boolInt(v: bool) c_int {
    return if (v) R_TRUE else R_FALSE;
}

/// Index from a C int (or any integer) for an array subscript.
inline fn idx(i: anytype) usize {
    return @intCast(i);
}

/// `(Rid)(uintptr_t)user` style conversions for the callbacks that carry an editor id.
fn idPtr(id: raven.Rid) ?*anyopaque {
    return @ptrFromInt(id);
}

/// A string that may be NULL, read as "" when it is.
fn rvn_be_or_empty(s: [*c]const u8) [*c]const u8 {
    return if (s != null) s else "";
}

/// RVN_BLOCK_EDITOR(e, id, result): the editor of a widget id, NULL when it is not one.
fn rvn_be_check(id: raven.Rid, function: [*c]const u8) [*c]rvn_block_editor_t {
    return @ptrCast(@alignCast(ext.rvn_widget_check(id, raven.R_WIDGET_BLOCK_EDITOR, function)));
}

// ---------------------------------------------------------------------------
//  Data
// ---------------------------------------------------------------------------

const rvn_be_token_t = extern struct {
    section: c_int,
    /// Index of the slot, or -1 for a word.
    slot: c_int,
    text: [*c]u8,
};

const rvn_be_kind_t = extern struct {
    name: [*c]u8,
    label: [*c]u8,
    category: [*c]u8,
    shape: raven.RBlockShape,
    tokens: [*c]rvn_be_token_t,
    token_count: u32,
    sections: c_int,
    slot_count: c_int,
    slot_types: [RVN_BE_MAX_SLOTS]u8,
    defaults: [RVN_BE_MAX_SLOTS][*c]u8,
    /// %m slots: the choices, separated by '\n'.
    options: [RVN_BE_MAX_SLOTS][*c]u8,
    /// Not in the palette (the blocks of that kind stay).
    hidden: c_int,
};

const rvn_be_category_t = extern struct {
    name: [*c]u8,
    color: base.rvn_color_t,
    has_color: c_int,
};

const rvn_be_block_t = extern struct {
    id: c_int,
    kind: c_int,
    palette: c_int,
    /// Where it is attached: 0 = a script of its own (at x, y).
    parent: c_int,
    place: raven.RBlockPlace,
    index: c_int,
    next: c_int,
    body: [RVN_BE_MAX_MOUTHS]c_int,
    input: [RVN_BE_MAX_SLOTS]c_int,
    value: [RVN_BE_MAX_SLOTS][*c]u8,
    x: f32,
    y: f32,

    // ---- layout (canvas units; palette blocks : palette units) ----
    lx: f32,
    ly: f32,
    w: f32,
    h: f32,
    row_y: [RVN_BE_MAX_MOUTHS + 1]f32,
    row_h: [RVN_BE_MAX_MOUTHS + 1]f32,
    mouth_y: [RVN_BE_MAX_MOUTHS]f32,
    mouth_h: [RVN_BE_MAX_MOUTHS]f32,
    slot_x: [RVN_BE_MAX_SLOTS]f32,
    slot_y: [RVN_BE_MAX_SLOTS]f32,
    slot_w: [RVN_BE_MAX_SLOTS]f32,
    slot_h: [RVN_BE_MAX_SLOTS]f32,

    // ---- what is shown ----
    sx: raven.RSpring,
    sy: raven.RSpring,
    appear: raven.RSpring,
    hover: raven.RSpring,
    glow_shown: raven.RSpring,
    fade: raven.RSpring,
    glow: c_int,
    dying: c_int,
    placed: c_int,
    /// Selected; sel_base : selected before the rectangle started.
    sel: c_int,
    sel_base: c_int,
    /// Cannot be deleted by the user (the entry of a function...).
    locked: c_int,
};

// Gesture states (C enum rvn_be_drag_t). Untyped so they coerce to the field type.
const rvn_be_drag_t = c_uint;
const RVN_BE_NONE = 0;
const RVN_BE_PRESS = 1; // button down on a block, not moved yet
const RVN_BE_PRESS_SLOT = 2; // on a value slot: opens its editor if not moved
const RVN_BE_PRESS_PALETTE = 3;
const RVN_BE_BLOCKS = 4; // carrying a stack
const RVN_BE_PAN = 5;
const RVN_BE_PRESS_RIGHT = 6; // right button down : a pan if it moves, else the context menu
const RVN_BE_MARQUEE = 7; // a selection rectangle
const RVN_BE_GROUP = 8; // moving the selection

const rvn_block_editor_t = extern struct {
    base: widget_h.rvn_widget_t,

    kinds: [*c]rvn_be_kind_t,
    kind_count: u32,
    kind_cap: u32,
    categories: [*c]rvn_be_category_t,
    category_count: u32,
    category_cap: u32,
    blocks: [*c]rvn_be_block_t,
    block_count: u32,
    block_cap: u32,
    next_id: c_int,
    /// Scripts in drawing order (top blocks).
    order: [*c]c_int,
    order_count: u32,
    order_cap: u32,
    /// Blocks in drawing order, filled by the layout (hit tests go the other way).
    drawn: [*c]c_int,
    drawn_count: u32,
    drawn_cap: u32,

    pan_x: f32,
    pan_y: f32,
    zoom: f32,
    shown_zoom: raven.RSpring,
    palette_scroll: f32,
    palette_height: f32,
    palette_hidden: c_int,
    layout_dirty: c_int,
    painted: c_int,

    // ---- gesture ----
    drag: rvn_be_drag_t,
    press_block: c_int,
    press_slot: c_int,
    press_x: f32,
    press_y: f32,
    grab_x: f32, // pointer - top left of the carried block (canvas units)
    grab_y: f32,
    pointer_x: f32, // in the widget
    pointer_y: f32,
    pan_from_x: f32,
    pan_from_y: f32,
    carried: c_int, // top block of the carried stack
    carried_h: f32,
    // where it would go
    target: c_int,
    target_place: raven.RBlockPlace,
    target_index: c_int,
    target_top: c_int, // above a script: that script
    ghost_x: f32,
    ghost_y: f32,
    ghost_shown: raven.RSpring,
    trash: raven.RSpring,
    hot_block: c_int,
    selected: c_int,

    // ---- the editor of a value slot ----
    field: [*c]widget_h.rvn_widget_t,
    edit_block: c_int,
    edit_slot: c_int,
    // ---- the menu of a %m slot ----
    menu: raven.Rid,
    menu_block: c_int,
    menu_slot: c_int,
    // ---- selection rectangle / moving the selection (canvas units) ----
    marquee_x0: f32,
    marquee_y0: f32,
    marquee_x1: f32,
    marquee_y1: f32,
    group_x: f32,
    group_y: f32,
    group: [*c]c_int,
    group_count: u32,
    group_cap: u32,

    changed_callback: raven.RBlockEditorCallback,
    changed_user: ?*anyopaque,
    clicked_callback: raven.RBlockEditorCallback,
    clicked_user: ?*anyopaque,
    context_callback: raven.RBlockEditorContextCallback,
    context_user: ?*anyopaque,

    saved: base.rvn_text_t,
};

const g_be_palette = [_]u32{
    0x4C97FF, 0x9966FF, 0xCF63CF, 0xFFBF00, 0xFFAB19, 0x5CB1D6, 0x59C059, 0xFF8C1A, 0xFF6680, 0x0FBD8C,
};

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

fn rvn_be_block(e: [*c]rvn_block_editor_t, id: c_int) [*c]rvn_be_block_t {
    if (id <= 0) return null;
    var i: u32 = 0;
    while (i < e.*.block_count) : (i += 1) {
        if (e.*.blocks[i].id == id) return &e.*.blocks[i];
    }
    return null;
}

fn rvn_be_kind_of(e: [*c]rvn_block_editor_t, b: [*c]const rvn_be_block_t) [*c]rvn_be_kind_t {
    if (b != null and b.*.kind >= 0 and @as(u32, @intCast(b.*.kind)) < e.*.kind_count) return &e.*.kinds[idx(b.*.kind)];
    return null;
}

fn rvn_be_find_kind(e: [*c]rvn_block_editor_t, name: [*c]const u8) c_int {
    if (name == null) return -1;
    var i: u32 = 0;
    while (i < e.*.kind_count) : (i += 1) {
        if (libc.strcmp(e.*.kinds[i].name, name) == 0) return @intCast(i);
    }
    return -1;
}

fn rvn_be_is_value(shape: raven.RBlockShape) bool {
    return shape == raven.R_BLOCK_REPORTER or shape == raven.R_BLOCK_BOOLEAN;
}
fn rvn_be_has_next(shape: raven.RBlockShape) bool {
    return shape == raven.R_BLOCK_STATEMENT or shape == raven.R_BLOCK_HAT or shape == raven.R_BLOCK_C;
}
fn rvn_be_has_top(shape: raven.RBlockShape) bool {
    return shape == raven.R_BLOCK_STATEMENT or shape == raven.R_BLOCK_CAP or shape == raven.R_BLOCK_C;
}

fn rvn_be_changed(e: [*c]rvn_block_editor_t) void {
    e.*.layout_dirty = R_TRUE;
    ext.rvn_widget_invalidate_paint(&e.*.base);
}

fn rvn_be_notify(e: [*c]rvn_block_editor_t, block: c_int) void {
    if (e.*.changed_callback) |cb| {
        if (common.rvn_widget_alive(&e.*.base) != 0) cb(e.*.base.id, block, e.*.changed_user);
    }
    if (common.rvn_widget_alive(&e.*.base) != 0) ext.rvn_widget_fire_action(&e.*.base);
}

fn rvn_be_category_color(e: [*c]rvn_block_editor_t, category: [*c]const u8) base.rvn_color_t {
    const cat: [*c]const u8 = rvn_be_or_empty(category);
    var i: u32 = 0;
    while (i < e.*.category_count) : (i += 1) {
        if (libc.strcmp(e.*.categories[i].name, cat) == 0 and e.*.categories[i].has_color != 0) return e.*.categories[i].color;
    }
    return base.rvn_hex(g_be_palette[base.rvn_hash_str(cat) % g_be_palette.len], 255);
}

fn rvn_be_light(color: base.rvn_color_t) bool {
    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    var a: f32 = 0;
    base.rvn_color_to_floats(color, &r, &g, &b, &a);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.66;
}

fn rvn_be_dark_theme(widget: [*c]const widget_h.rvn_widget_t) bool {
    return rvn_be_light(ext.rvn_widget_color(widget, raven.R_COLOR_TEXT));
}

/// The top block of the script a block is in.
fn rvn_be_top_of(e: [*c]rvn_block_editor_t, b_: [*c]rvn_be_block_t) [*c]rvn_be_block_t {
    var b = b_;
    var guard: c_int = 0;
    while (b != null and b.*.parent != 0 and guard < 100000) : (guard += 1) {
        b = rvn_be_block(e, b.*.parent);
    }
    return b;
}

/// R_TRUE when `inner` is `outer` or hangs under it (next, mouths, inputs).
fn rvn_be_inside(e: [*c]rvn_block_editor_t, inner: c_int, outer: c_int) bool {
    var b = rvn_be_block(e, inner);
    var guard: c_int = 0;
    while (b != null and guard < 100000) : (guard += 1) {
        if (b.*.id == outer) return true;
        b = rvn_be_block(e, b.*.parent);
    }
    return false;
}

fn rvn_be_last_of_chain(e: [*c]rvn_block_editor_t, b_: [*c]rvn_be_block_t) [*c]rvn_be_block_t {
    var b = b_;
    var guard: c_int = 0;
    while (b != null and b.*.next != 0 and guard < 100000) : (guard += 1) {
        b = rvn_be_block(e, b.*.next);
    }
    return b;
}

fn rvn_be_order_add(e: [*c]rvn_block_editor_t, id: c_int) void {
    base.RVN_ARRAY_RESERVE(&e.*.order, &e.*.order_cap, e.*.order_count + 1);
    e.*.order[e.*.order_count] = id;
    e.*.order_count += 1;
}

fn rvn_be_order_remove(e: [*c]rvn_block_editor_t, id: c_int) void {
    var i: u32 = 0;
    while (i < e.*.order_count) : (i += 1) {
        if (e.*.order[i] != id) continue;
        _ = libc.memmove(&e.*.order[i], &e.*.order[i + 1], (e.*.order_count - i - 1) * @sizeOf(c_int));
        e.*.order_count -= 1;
        return;
    }
}

fn rvn_be_order_raise(e: [*c]rvn_block_editor_t, id: c_int) void {
    rvn_be_order_remove(e, id);
    rvn_be_order_add(e, id);
}

// ---------------------------------------------------------------------------
//  Kinds : the label is cut into words and slots
// ---------------------------------------------------------------------------

fn rvn_be_add_token(k: [*c]rvn_be_kind_t, section: c_int, slot: c_int, text: [*c]const u8, length: usize, cap: [*c]u32) void {
    if (slot < 0 and length == 0) return;
    base.RVN_ARRAY_RESERVE(&k.*.tokens, cap, k.*.token_count + 1);
    const t: [*c]rvn_be_token_t = &k.*.tokens[k.*.token_count];
    k.*.token_count += 1;
    t.*.section = section;
    t.*.slot = slot;
    t.*.text = if (slot < 0) base.rvn_strndup(text, length) else null;
}

fn rvn_be_parse_label(k: [*c]rvn_be_kind_t) void {
    var c: [*c]const u8 = rvn_be_or_empty(k.*.label);
    var word: [*c]const u8 = c;
    var cap: u32 = 0;
    var section: c_int = 0;
    k.*.sections = 1;
    while (c[0] != 0) {
        if (c[0] == '|') {
            rvn_be_add_token(k, section, -1, word, @intFromPtr(c) - @intFromPtr(word), &cap);
            section += 1;
            k.*.sections = section + 1;
            c += 1;
            word = c;
            continue;
        }
        if (c[0] == '%' and (c[1] == 'n' or c[1] == 's' or c[1] == 'b' or c[1] == 'r' or c[1] == 'm') and k.*.slot_count < RVN_BE_MAX_SLOTS) {
            const slot = k.*.slot_count;
            k.*.slot_count += 1;
            rvn_be_add_token(k, section, -1, word, @intFromPtr(c) - @intFromPtr(word), &cap);
            k.*.slot_types[idx(slot)] = c[1];
            c += 2;
            if (c[0] == '{') {
                const end = libc.strchr(c, '}');
                if (end != null) {
                    k.*.defaults[idx(slot)] = base.rvn_strndup(c + 1, @intFromPtr(end) - @intFromPtr(c) - 1);
                    c = end + 1;
                }
            }
            if (k.*.defaults[idx(slot)] == null) {
                const dflt: [*c]const u8 = if (k.*.slot_types[idx(slot)] == 'n') "0" else "";
                k.*.defaults[idx(slot)] = base.rvn_strdup(dflt);
            }
            rvn_be_add_token(k, section, slot, null, 0, &cap);
            word = c;
            continue;
        }
        c += 1;
    }
    rvn_be_add_token(k, section, -1, word, @intFromPtr(c) - @intFromPtr(word), &cap);
    if (k.*.shape != raven.R_BLOCK_C) k.*.sections = 1;
}

fn rvn_be_free_kind(k: [*c]rvn_be_kind_t) void {
    var i: u32 = 0;
    while (i < k.*.token_count) : (i += 1) base.rvn_free(k.*.tokens[i].text);
    base.rvn_free(k.*.tokens);
    var s: usize = 0;
    while (s < RVN_BE_MAX_SLOTS) : (s += 1) base.rvn_free(k.*.defaults[s]);
    base.rvn_free(k.*.name);
    base.rvn_free(k.*.label);
    base.rvn_free(k.*.category);
    s = 0;
    while (s < RVN_BE_MAX_SLOTS) : (s += 1) base.rvn_free(k.*.options[s]);
}

// ---------------------------------------------------------------------------
//  Blocks
// ---------------------------------------------------------------------------

fn rvn_be_new_block(e: [*c]rvn_block_editor_t, kind: c_int, palette: c_int) [*c]rvn_be_block_t {
    const k: [*c]const rvn_be_kind_t = &e.*.kinds[idx(kind)];
    base.RVN_ARRAY_RESERVE(&e.*.blocks, &e.*.block_cap, e.*.block_count + 1);
    const b: [*c]rvn_be_block_t = &e.*.blocks[e.*.block_count];
    e.*.block_count += 1;
    b.* = std.mem.zeroes(rvn_be_block_t);
    b.*.id = e.*.next_id;
    e.*.next_id += 1;
    b.*.kind = kind;
    b.*.palette = palette;
    b.*.place = raven.R_BLOCK_NEXT;
    var s: c_int = 0;
    while (s < k.*.slot_count) : (s += 1) {
        b.*.value[idx(s)] = base.rvn_strdup(rvn_be_or_empty(k.*.defaults[idx(s)]));
    }
    ext.rvn_spring_set(&b.*.fade, 1.0);
    if (e.*.painted == 0 or palette != 0) ext.rvn_spring_set(&b.*.appear, 1.0);
    return b;
}

/// Takes a block out of where it is attached (with what hangs under it).
fn rvn_be_detach(e: [*c]rvn_block_editor_t, b: [*c]rvn_be_block_t) void {
    if (b == null) return;
    if (b.*.parent == 0) {
        rvn_be_order_remove(e, b.*.id);
        return;
    }
    const p = rvn_be_block(e, b.*.parent);
    if (p != null) {
        if (b.*.place == raven.R_BLOCK_NEXT and p.*.next == b.*.id) {
            p.*.next = 0;
        } else if (b.*.place == raven.R_BLOCK_BODY and b.*.index < RVN_BE_MAX_MOUTHS and p.*.body[idx(b.*.index)] == b.*.id) {
            p.*.body[idx(b.*.index)] = 0;
        } else if (b.*.place == raven.R_BLOCK_INPUT and b.*.index < RVN_BE_MAX_SLOTS and p.*.input[idx(b.*.index)] == b.*.id) {
            p.*.input[idx(b.*.index)] = 0;
        }
    }
    b.*.parent = 0;
    b.*.place = raven.R_BLOCK_NEXT;
    b.*.index = 0;
}

fn rvn_be_make_top(e: [*c]rvn_block_editor_t, b: [*c]rvn_be_block_t, x: f32, y: f32) void {
    rvn_be_detach(e, b);
    b.*.x = x;
    b.*.y = y;
    rvn_be_order_add(e, b.*.id);
}

/// Puts a block (a script of its own) at a place. Returns R_FALSE when it cannot go there.
fn rvn_be_attach(e: [*c]rvn_block_editor_t, b_in: [*c]rvn_be_block_t, target_in: [*c]rvn_be_block_t, place: raven.RBlockPlace, index: c_int) c_int {
    var b = b_in;
    var target = target_in;
    const kb = rvn_be_kind_of(e, b);
    const kt = rvn_be_kind_of(e, target);
    const id: c_int = if (b != null) b.*.id else 0;
    if (b == null or target == null or kb == null or kt == null or target.*.palette != 0 or b.*.palette != 0 or rvn_be_inside(e, target.*.id, b.*.id)) return R_FALSE;
    if (place == raven.R_BLOCK_INPUT) {
        if (!rvn_be_is_value(kb.*.shape) or index < 0 or index >= kt.*.slot_count) return R_FALSE;
        const typ = kt.*.slot_types[idx(index)];
        if (typ == 'm') return R_FALSE;
        if (typ == 'b' and kb.*.shape != raven.R_BLOCK_BOOLEAN) return R_FALSE;
        if ((typ == 'n' or typ == 's') and kb.*.shape != raven.R_BLOCK_REPORTER) return R_FALSE;
        rvn_be_detach(e, b);
        b = rvn_be_block(e, id);
        target = rvn_be_block(e, target.*.id);
        if (target.*.input[idx(index)] != 0) {
            // the value that was there jumps out, beside
            const old = rvn_be_block(e, target.*.input[idx(index)]);
            if (old != null) rvn_be_make_top(e, old, target.*.lx + target.*.w + 20.0, target.*.ly);
        }
        target.*.input[idx(index)] = id;
    } else {
        if (rvn_be_is_value(kb.*.shape) or kb.*.shape == raven.R_BLOCK_HAT or rvn_be_is_value(kt.*.shape)) return R_FALSE;
        if (place == raven.R_BLOCK_NEXT and !rvn_be_has_next(kt.*.shape)) return R_FALSE;
        if (place == raven.R_BLOCK_BODY and (kt.*.shape != raven.R_BLOCK_C or index < 0 or index >= kt.*.sections)) return R_FALSE;
        rvn_be_detach(e, b);
        b = rvn_be_block(e, id);
        target = rvn_be_block(e, target.*.id);
        const after: c_int = if (place == raven.R_BLOCK_NEXT) target.*.next else target.*.body[idx(index)];
        const last = rvn_be_last_of_chain(e, b);
        if (after != 0) {
            const rest = rvn_be_block(e, after);
            const kl = rvn_be_kind_of(e, last);
            if (rest != null and kl != null and kl.*.shape == raven.R_BLOCK_C and last == b and b.*.body[0] == 0) {
                // a lone C block wraps what was under it (Scratch)
                b.*.body[0] = after;
                rest.*.parent = b.*.id;
                rest.*.place = raven.R_BLOCK_BODY;
                rest.*.index = 0;
            } else if (rest != null and kl != null and rvn_be_has_next(kl.*.shape)) {
                last.*.next = after;
                rest.*.parent = last.*.id;
                rest.*.place = raven.R_BLOCK_NEXT;
                rest.*.index = 0;
            } else if (rest != null) {
                // (a cap block ends the stack : what was under goes beside)
                rest.*.parent = 0;
                rest.*.x = target.*.lx + target.*.w + 30.0;
                rest.*.y = target.*.ly + target.*.h;
                rvn_be_order_add(e, rest.*.id);
            }
        }
        if (place == raven.R_BLOCK_NEXT) {
            target.*.next = id;
        } else {
            target.*.body[idx(index)] = id;
        }
    }
    b.*.parent = target.*.id;
    b.*.place = place;
    b.*.index = index;
    rvn_be_changed(e);
    return R_TRUE;
}

fn rvn_be_free_block_data(b: [*c]rvn_be_block_t) void {
    var s: usize = 0;
    while (s < RVN_BE_MAX_SLOTS) : (s += 1) base.rvn_free(b.*.value[s]);
}

fn rvn_be_remove_index(e: [*c]rvn_block_editor_t, index: u32) void {
    rvn_be_free_block_data(&e.*.blocks[index]);
    _ = libc.memmove(&e.*.blocks[index], &e.*.blocks[index + 1], (e.*.block_count - index - 1) * @sizeOf(rvn_be_block_t));
    e.*.block_count -= 1;
}

/// Marks a block and what hangs under it as going away (they fade out).
fn rvn_be_kill(e: [*c]rvn_block_editor_t, id: c_int, animate: c_int) void {
    const b = rvn_be_block(e, id);
    if (b == null) return;
    const next = b.*.next;
    const body = b.*.body;
    const input = b.*.input;
    b.*.dying = R_TRUE;
    b.*.sel = R_FALSE;
    b.*.sel_base = R_FALSE;
    if (animate == 0) ext.rvn_spring_set(&b.*.fade, 0.0);
    if (e.*.selected == id) e.*.selected = 0;
    if (e.*.edit_block == id) e.*.edit_block = 0;
    if (next != 0) rvn_be_kill(e, next, animate);
    var s: usize = 0;
    while (s < RVN_BE_MAX_MOUTHS) : (s += 1) {
        if (body[s] != 0) rvn_be_kill(e, body[s], animate);
    }
    s = 0;
    while (s < RVN_BE_MAX_SLOTS) : (s += 1) {
        if (input[s] != 0) rvn_be_kill(e, input[s], animate);
    }
}

fn rvn_be_delete_script(e: [*c]rvn_block_editor_t, id: c_int, animate: c_int) void {
    const b = rvn_be_block(e, id);
    if (b == null) return;
    rvn_be_detach(e, b);
    rvn_be_kill(e, id, animate);
    rvn_be_changed(e);
}

fn rvn_be_purge(e: [*c]rvn_block_editor_t, all: c_int) void {
    var i: u32 = e.*.block_count;
    while (i > 0) : (i -= 1) {
        const b = &e.*.blocks[i - 1];
        if ((b.*.dying != 0 and (all != 0 or b.*.fade.value < 0.01)) or (all != 0 and b.*.palette == 0)) rvn_be_remove_index(e, i - 1);
    }
}


// ---------------------------------------------------------------------------
//  Layout
// ---------------------------------------------------------------------------

const rvn_be_metrics_t = extern struct {
    font: f32,
    /// Height of a row of a statement.
    row: f32,
    /// Height of a value slot.
    slot: f32,
    pad: f32,
};

fn rvn_be_metrics(widget: [*c]const widget_h.rvn_widget_t) rvn_be_metrics_t {
    var m: rvn_be_metrics_t = undefined;
    m.font = common.rvn_widget_font_size(widget, 0.0);
    m.slot = @floor(m.font + 10.0);
    m.row = base.rvn_maxf(36.0, m.slot + 12.0);
    m.pad = 10.0;
    return m;
}

/// Width and height of a chain of statements (a mouth, a script).
fn rvn_be_measure_chain(e: [*c]rvn_block_editor_t, first: c_int, m: [*c]const rvn_be_metrics_t, w: [*c]f32, h: [*c]f32) void {
    var b = rvn_be_block(e, first);
    var guard: c_int = 0;
    w.* = 0.0;
    h.* = 0.0;
    while (b != null and guard < 100000) {
        guard += 1;
        rvn_be_measure_block(e, b, m);
        w.* = base.rvn_maxf(w.*, b.*.w);
        h.* += b.*.h;
        if (e.*.drag == RVN_BE_BLOCKS and e.*.target == b.*.id and e.*.target_place == raven.R_BLOCK_NEXT) h.* += e.*.carried_h;
        b = rvn_be_block(e, b.*.next);
    }
}

fn rvn_be_slot_extent(e: [*c]rvn_block_editor_t, b: [*c]rvn_be_block_t, k: [*c]const rvn_be_kind_t, slot: c_int, m: [*c]const rvn_be_metrics_t, height: [*c]f32) f32 {
    const input = rvn_be_block(e, b.*.input[idx(slot)]);
    if (input != null and input.*.dying == 0) {
        rvn_be_measure_block(e, input, m);
        height.* = input.*.h;
        return input.*.w;
    }
    height.* = m.*.slot;
    if (k.*.slot_types[idx(slot)] == 'b') return 40.0;
    return base.rvn_maxf(m.*.slot + 4.0, common.rvn_widget_text_width(&e.*.base, raven.R_INVALID_ID, m.*.font, rvn_be_or_empty(b.*.value[idx(slot)])) +
        (if (k.*.slot_types[idx(slot)] == 'm') @as(f32, 30.0) else @as(f32, 16.0)));
}

fn rvn_be_measure_block(e: [*c]rvn_block_editor_t, b: [*c]rvn_be_block_t, m: [*c]const rvn_be_metrics_t) void {
    const k = rvn_be_kind_of(e, b);
    const value = k != null and rvn_be_is_value(k.*.shape);
    var width: f32 = 0.0;
    var y: f32 = 0.0;
    if (k == null) return;
    var s: c_int = 0;
    while (s < k.*.sections) : (s += 1) {
        var x: f32 = if (value) (if (k.*.shape == raven.R_BLOCK_BOOLEAN) m.*.slot * 0.55 + 6.0 else m.*.pad + 2.0) else m.*.pad;
        var row: f32 = if (value) m.*.slot else m.*.row;
        var t: u32 = 0;
        while (t < k.*.token_count) : (t += 1) {
            const tok = &k.*.tokens[t];
            if (tok.*.section != s) continue;
            if (tok.*.slot < 0) {
                x += common.rvn_widget_text_width(&e.*.base, raven.R_INVALID_ID, m.*.font, tok.*.text) + 4.0;
            } else {
                var sh: f32 = 0.0;
                const sw = rvn_be_slot_extent(e, b, k, tok.*.slot, m, &sh);
                b.*.slot_x[idx(tok.*.slot)] = x;
                b.*.slot_w[idx(tok.*.slot)] = sw;
                b.*.slot_h[idx(tok.*.slot)] = sh;
                row = base.rvn_maxf(row, sh + (if (value) @as(f32, 6.0) else @as(f32, 10.0)));
                x += sw + 5.0;
            }
        }
        if (k.*.shape == raven.R_BLOCK_HAT and s == 0) row += 14.0;
        x += if (value) (if (k.*.shape == raven.R_BLOCK_BOOLEAN) m.*.slot * 0.55 + 2.0 else m.*.pad - 2.0) else m.*.pad;
        width = base.rvn_maxf(width, x);
        b.*.row_y[idx(s)] = y;
        b.*.row_h[idx(s)] = row;
        // the slots of the row are centered on it
        t = 0;
        while (t < k.*.token_count) : (t += 1) {
            const tok = &k.*.tokens[t];
            if (tok.*.section == s and tok.*.slot >= 0)
                b.*.slot_y[idx(tok.*.slot)] = y + (if (k.*.shape == raven.R_BLOCK_HAT and s == 0) @as(f32, 14.0) else 0.0) +
                    ((row - (if (k.*.shape == raven.R_BLOCK_HAT and s == 0) @as(f32, 14.0) else 0.0)) - b.*.slot_h[idx(tok.*.slot)]) * 0.5;
        }
        y += row;
        if (k.*.shape == raven.R_BLOCK_C) {
            var mw: f32 = 0.0;
            var mh: f32 = 0.0;
            rvn_be_measure_chain(e, b.*.body[idx(s)], m, &mw, &mh);
            if (e.*.drag == RVN_BE_BLOCKS and e.*.target == b.*.id and e.*.target_place == raven.R_BLOCK_BODY and e.*.target_index == s) mh += e.*.carried_h;
            b.*.mouth_y[idx(s)] = y;
            b.*.mouth_h[idx(s)] = base.rvn_maxf(RVN_BE_MOUTH_MIN, mh);
            y += b.*.mouth_h[idx(s)];
            width = base.rvn_maxf(width, RVN_BE_ARM + 60.0);
            // C: (void)mw
        }
    }
    if (k.*.shape == raven.R_BLOCK_C) y += RVN_BE_BOTTOM;
    b.*.w = base.rvn_maxf(width, if (value) m.*.slot else 64.0);
    b.*.h = y;
}

/// The chain under a place; a block before which the carried stack would open a gap.
fn rvn_be_place_chain(e: [*c]rvn_block_editor_t, first: c_int, x: f32, y_in: f32, m: [*c]const rvn_be_metrics_t) void {
    var b = rvn_be_block(e, first);
    var guard: c_int = 0;
    var y = y_in;
    while (b != null and guard < 100000) {
        guard += 1;
        rvn_be_place_block(e, b, x, y, m);
        y += b.*.h;
        if (e.*.drag == RVN_BE_BLOCKS and e.*.target == b.*.id and e.*.target_place == raven.R_BLOCK_NEXT) {
            e.*.ghost_x = x;
            e.*.ghost_y = y;
            y += e.*.carried_h;
        }
        b = rvn_be_block(e, b.*.next);
    }
}

fn rvn_be_place_block(e: [*c]rvn_block_editor_t, b: [*c]rvn_be_block_t, x: f32, y: f32, m: [*c]const rvn_be_metrics_t) void {
    const k = rvn_be_kind_of(e, b);
    if (k == null) return;
    b.*.lx = x;
    b.*.ly = y;
    base.RVN_ARRAY_RESERVE(&e.*.drawn, &e.*.drawn_cap, e.*.drawn_count + 1);
    e.*.drawn[idx(e.*.drawn_count)] = b.*.id;
    e.*.drawn_count += 1;
    var s: c_int = 0;
    while (s < k.*.slot_count) : (s += 1) {
        const input = rvn_be_block(e, b.*.input[idx(s)]);
        if (input != null and input.*.dying == 0) rvn_be_place_block(e, input, x + b.*.slot_x[idx(s)], y + b.*.slot_y[idx(s)], m);
    }
    if (k.*.shape == raven.R_BLOCK_C) {
        s = 0;
        while (s < k.*.sections) : (s += 1) {
            var my = y + b.*.mouth_y[idx(s)];
            if (e.*.drag == RVN_BE_BLOCKS and e.*.target == b.*.id and e.*.target_place == raven.R_BLOCK_BODY and e.*.target_index == s) {
                e.*.ghost_x = x + RVN_BE_ARM;
                e.*.ghost_y = my;
                my += e.*.carried_h;
            }
            rvn_be_place_chain(e, b.*.body[idx(s)], x + RVN_BE_ARM, my, m);
        }
    }
}

/// The carried stack opens a gap : the blocks of a place are measured with it.
fn rvn_be_layout(e: [*c]rvn_block_editor_t) void {
    const m = rvn_be_metrics(&e.*.base);
    var py: f32 = 10.0;
    var category: [*c]const u8 = null;

    e.*.drawn_count = 0;
    // sizes first (they include the gap the carried stack opens)
    var i: u32 = 0;
    while (i < e.*.order_count) : (i += 1) {
        const top = rvn_be_block(e, e.*.order[i]);
        var w: f32 = undefined;
        var h: f32 = undefined;
        if (top != null) rvn_be_measure_chain(e, top.*.id, &m, &w, &h);
    }
    // then places
    i = 0;
    while (i < e.*.order_count) : (i += 1) {
        const top = rvn_be_block(e, e.*.order[i]);
        if (top == null or top.*.dying != 0) continue;
        const x = top.*.x;
        var y = top.*.y;
        if (e.*.drag == RVN_BE_BLOCKS and e.*.target_top == top.*.id) {
            e.*.ghost_x = x;
            e.*.ghost_y = y;
            y += e.*.carried_h;
        }
        rvn_be_place_chain(e, top.*.id, x, y, &m);
    }
    // the palette : one of each kind, by category
    i = 0;
    while (i < e.*.block_count) : (i += 1) {
        const b = &e.*.blocks[i];
        if (b.*.palette == 0) continue;
        const k = rvn_be_kind_of(e, b);
        if (k == null or k.*.hidden != 0) {
            b.*.lx = -100000.0;
            b.*.ly = -100000.0;
            continue;
        }
        if (category == null or libc.strcmp(category, if (k.*.category != null) k.*.category else "") != 0) {
            category = if (k.*.category != null) k.*.category else "";
            py += if (category[0] != 0) @as(f32, 30.0) else @as(f32, 6.0);
        }
        rvn_be_measure_block(e, b, &m);
        b.*.lx = 14.0;
        b.*.ly = py;
        py += b.*.h + 10.0;
    }
    e.*.palette_height = py + 20.0;
    e.*.layout_dirty = R_FALSE;
}

// ---------------------------------------------------------------------------
//  View
// ---------------------------------------------------------------------------

fn rvn_be_canvas_left(e: [*c]const rvn_block_editor_t) f32 {
    return if (e.*.palette_hidden != 0) 0.0 else RVN_BE_PALETTE_W;
}

fn rvn_be_to_canvas(e: [*c]const rvn_block_editor_t, x: f32, y: f32, cx: [*c]f32, cy: [*c]f32) void {
    const z: f32 = if (e.*.zoom > 0.0) e.*.zoom else 1.0;
    cx.* = (x - rvn_be_canvas_left(e)) / z + e.*.pan_x;
    cy.* = y / z + e.*.pan_y;
}

fn rvn_be_in_palette(e: [*c]const rvn_block_editor_t, x: f32) c_int {
    return boolInt(e.*.palette_hidden == 0 and x < RVN_BE_PALETTE_W);
}

// ---------------------------------------------------------------------------
//  Hit tests
// ---------------------------------------------------------------------------

/// Is (cx, cy) on the block itself (not in one of its mouths) ? Positions as shown.
fn rvn_be_on_block(e: [*c]rvn_block_editor_t, b: [*c]const rvn_be_block_t, bx: f32, by: f32, cx: f32, cy: f32) c_int {
    const k = rvn_be_kind_of(e, b);
    if (k == null or cx < bx or cy < by or cx > bx + b.*.w or cy > by + b.*.h) return R_FALSE;
    if (k.*.shape == raven.R_BLOCK_C) {
        var s: c_int = 0;
        while (s < k.*.sections) : (s += 1) {
            if (cx > bx + RVN_BE_ARM and cy > by + b.*.mouth_y[idx(s)] and cy < by + b.*.mouth_y[idx(s)] + b.*.mouth_h[idx(s)]) return R_FALSE;
        }
    }
    return R_TRUE;
}

/// The block under the pointer, the deepest first; *slot : a value slot under it, or -1.
fn rvn_be_block_at(e: [*c]rvn_block_editor_t, x: f32, y: f32, slot: [*c]c_int) c_int {
    var cx: f32 = undefined;
    var cy: f32 = undefined;
    slot.* = -1;
    if (rvn_be_in_palette(e, x) != 0) {
        const py = y + e.*.palette_scroll;
        var i: u32 = 0;
        while (i < e.*.block_count) : (i += 1) {
            const b = &e.*.blocks[i];
            const k = rvn_be_kind_of(e, b);
            if (b.*.palette != 0 and k != null and k.*.hidden == 0 and rvn_be_on_block(e, b, b.*.lx, b.*.ly, x, py) != 0) return b.*.id;
        }
        return 0;
    }
    rvn_be_to_canvas(e, x, y, &cx, &cy);
    var i = e.*.drawn_count;
    while (i > 0) : (i -= 1) {
        const b = rvn_be_block(e, e.*.drawn[i - 1]);
        const k = rvn_be_kind_of(e, b);
        if (b == null or b.*.dying != 0 or b.*.id == e.*.carried or rvn_be_inside(e, b.*.id, e.*.carried)) continue;
        if (rvn_be_on_block(e, b, b.*.sx.value, b.*.sy.value, cx, cy) == 0) continue;
        var s: c_int = 0;
        while (k != null and s < k.*.slot_count) : (s += 1) {
            const sx = b.*.sx.value + b.*.slot_x[idx(s)];
            const sy = b.*.sy.value + b.*.slot_y[idx(s)];
            if (b.*.input[idx(s)] == 0 and cx >= sx and cx <= sx + b.*.slot_w[idx(s)] and cy >= sy and cy <= sy + b.*.slot_h[idx(s)]) slot.* = s;
        }
        return b.*.id;
    }
    return 0;
}

/// Where the carried stack would go if released now.
fn rvn_be_find_target(e: [*c]rvn_block_editor_t) void {
    const d = rvn_be_block(e, e.*.carried);
    const kd = rvn_be_kind_of(e, d);
    var best: f32 = RVN_BE_SNAP * RVN_BE_SNAP;
    var target: c_int = 0;
    var index: c_int = 0;
    var top: c_int = 0;
    var place: raven.RBlockPlace = raven.R_BLOCK_NEXT;
    e.*.target = 0;
    e.*.target_top = 0;
    if (d == null or kd == null or rvn_be_in_palette(e, e.*.pointer_x) != 0) return;
    var dx: f32 = undefined;
    var dy: f32 = undefined;
    rvn_be_to_canvas(e, e.*.pointer_x, e.*.pointer_y, &dx, &dy);
    dx -= e.*.grab_x;
    dy -= e.*.grab_y;
    const last = rvn_be_last_of_chain(e, d);
    const kl = rvn_be_kind_of(e, last);

    var i: u32 = 0;
    while (i < e.*.drawn_count) : (i += 1) {
        const t = rvn_be_block(e, e.*.drawn[i]);
        const kt = rvn_be_kind_of(e, t);
        if (t == null or kt == null or t.*.dying != 0 or rvn_be_inside(e, t.*.id, d.*.id)) continue;
        if (rvn_be_is_value(kd.*.shape)) {
            // a value : an empty slot that takes it, the left of the value on the left of the slot
            var s: c_int = 0;
            while (s < kt.*.slot_count) : (s += 1) {
                const slot_type = kt.*.slot_types[idx(s)];
                const sx = t.*.lx + t.*.slot_x[idx(s)];
                const sy = t.*.ly + t.*.slot_y[idx(s)] + t.*.slot_h[idx(s)] * 0.5;
                const ex = dx - sx;
                const ey = dy + d.*.h * 0.5 - sy;
                const dist = ex * ex + ey * ey;
                if (t.*.input[idx(s)] != 0 or slot_type == 'm') continue;
                if (slot_type == 'b' and kd.*.shape != raven.R_BLOCK_BOOLEAN) continue;
                if ((slot_type == 'n' or slot_type == 's') and kd.*.shape != raven.R_BLOCK_REPORTER) continue;
                if (dist < best) {
                    best = dist;
                    target = t.*.id;
                    place = raven.R_BLOCK_INPUT;
                    index = s;
                }
            }
            continue;
        }
        if (kd.*.shape == raven.R_BLOCK_HAT or rvn_be_is_value(kt.*.shape)) continue;
        // under a block
        if (rvn_be_has_next(kt.*.shape) and !(t.*.next != 0 and (kl == null or !rvn_be_has_next(kl.*.shape)))) {
            const ex = dx - t.*.lx;
            const ey = dy - (t.*.ly + t.*.h);
            const dist = ex * ex + ey * ey;
            if (dist < best) {
                best = dist;
                target = t.*.id;
                place = raven.R_BLOCK_NEXT;
                index = 0;
            }
        }
        // in a mouth
        if (kt.*.shape == raven.R_BLOCK_C) {
            var s: c_int = 0;
            while (s < kt.*.sections) : (s += 1) {
                const ex = dx - (t.*.lx + RVN_BE_ARM);
                const ey = dy - (t.*.ly + t.*.mouth_y[idx(s)]);
                const dist = ex * ex + ey * ey;
                if (t.*.body[idx(s)] != 0 and (kl == null or !rvn_be_has_next(kl.*.shape))) continue;
                if (dist < best) {
                    best = dist;
                    target = t.*.id;
                    place = raven.R_BLOCK_BODY;
                    index = s;
                }
            }
        }
    }
    // above a script (its top takes a block over it)
    if (!rvn_be_is_value(kd.*.shape) and kl != null and rvn_be_has_next(kl.*.shape)) {
        i = 0;
        while (i < e.*.order_count) : (i += 1) {
            const t = rvn_be_block(e, e.*.order[i]);
            const kt = rvn_be_kind_of(e, t);
            if (t == null or kt == null or t.*.dying != 0 or t.*.id == d.*.id or rvn_be_has_top(kt.*.shape) == false) continue;
            var h: f32 = 0.0;
            {
                var c = d;
                var guard: c_int = 0;
                while (c != null and guard < 100000) {
                    guard += 1;
                    h += c.*.h;
                    c = rvn_be_block(e, c.*.next);
                }
            }
            const ex = dx - t.*.x;
            const ey = dy + h - t.*.y;
            const dist = ex * ex + ey * ey;
            if (dist < best) {
                best = dist;
                top = t.*.id;
                target = 0;
            }
        }
    }
    e.*.target = if (top != 0) 0 else target;
    e.*.target_place = place;
    e.*.target_index = index;
    e.*.target_top = top;
}

// ---------------------------------------------------------------------------
//  Painting
// ---------------------------------------------------------------------------

const rvn_be_look_t = extern struct {
    m: rvn_be_metrics_t,
    ox: f32,
    oy: f32,
    scale: f32,
    text_dark: base.rvn_color_t,
    text_light: base.rvn_color_t,
    slot_fill: base.rvn_color_t,
    slot_text: base.rvn_color_t,
    slot_line: base.rvn_color_t,
    glow: base.rvn_color_t,
    dark: c_int,
    opacity: f32,
};

inline fn BX(look: [*c]const rvn_be_look_t, v: f32) f32 {
    return look.*.ox + v * look.*.scale;
}
inline fn BY(look: [*c]const rvn_be_look_t, v: f32) f32 {
    return look.*.oy + v * look.*.scale;
}
inline fn BS(look: [*c]const rvn_be_look_t, v: f32) f32 {
    return v * look.*.scale;
}

fn rvn_be_trapezoid(p: [*c]draw_h.RPainter, x0: f32, x1: f32, y0: f32, x2: f32, x3: f32, y1: f32, color: base.rvn_color_t) void {
    // top edge x0..x1 at y0, bottom edge x2..x3 at y1
    draw_h.rvn_paint_triangle(p, x0, y0, x1, y0, x3, y1, color);
    draw_h.rvn_paint_triangle(p, x0, y0, x3, y1, x2, y1, color);
}

/// The silhouette of a statement / hat / cap / C block, filled with `fill`.
fn rvn_be_paint_shape(p: [*c]draw_h.RPainter, e: [*c]rvn_block_editor_t, b: [*c]const rvn_be_block_t, k: [*c]const rvn_be_kind_t, x: f32, y: f32, look: [*c]const rvn_be_look_t, fill: base.rvn_color_t, edge: base.rvn_color_t, notch_top: c_int, behind: base.rvn_color_t) void {
    _ = e;
    const r = BS(look, RVN_BE_RADIUS);
    const w = BS(look, b.*.w);
    const h = BS(look, b.*.h);
    const nx = BS(look, RVN_BE_NOTCH_X);
    const nw = BS(look, RVN_BE_NOTCH_W);
    const nd = BS(look, RVN_BE_NOTCH_D);
    const X = BX(look, x);
    const Y = BY(look, y);
    if (k.*.shape == raven.R_BLOCK_REPORTER) {
        draw_h.rvn_paint_box(p, base.rvn_rect(X, Y, w, h), h * 0.5, fill, BS(look, 1.0), edge);
        return;
    }
    if (k.*.shape == raven.R_BLOCK_BOOLEAN) {
        const tip = base.rvn_minf(h * 0.5, w * 0.3);
        draw_h.rvn_paint_rect(p, base.rvn_rect(X + tip, Y, w - tip * 2.0, h), fill);
        draw_h.rvn_paint_triangle(p, X, Y + h * 0.5, X + tip, Y, X + tip, Y + h, fill);
        draw_h.rvn_paint_triangle(p, X + w, Y + h * 0.5, X + w - tip, Y + h, X + w - tip, Y, fill);
        draw_h.rvn_paint_line(p, X, Y + h * 0.5, X + tip, Y, BS(look, 1.0), edge);
        draw_h.rvn_paint_line(p, X, Y + h * 0.5, X + tip, Y + h, BS(look, 1.0), edge);
        draw_h.rvn_paint_line(p, X + w, Y + h * 0.5, X + w - tip, Y, BS(look, 1.0), edge);
        draw_h.rvn_paint_line(p, X + w, Y + h * 0.5, X + w - tip, Y + h, BS(look, 1.0), edge);
        draw_h.rvn_paint_line(p, X + tip, Y, X + w - tip, Y, BS(look, 1.0), edge);
        draw_h.rvn_paint_line(p, X + tip, Y + h, X + w - tip, Y + h, BS(look, 1.0), edge);
        return;
    }
    if (k.*.shape == raven.R_BLOCK_C) {
        // the rows, the arm on the left, the bottom
        var s: c_int = 0;
        while (s < k.*.sections) : (s += 1) {
            const ry = BY(look, y + b.*.row_y[idx(s)]);
            const rh = BS(look, b.*.row_h[idx(s)]);
            const radii = [_]f32{ if (s == 0) r else 0.0, if (s == 0) r else 0.0, r, 0.0 };
            draw_h.rvn_paint_box4(p, base.rvn_rect(X, ry, w, rh), &radii, fill, 0.0, 0);
            // the tab that enters the mouth
            rvn_be_trapezoid(p, X + BS(look, RVN_BE_ARM) + nx, X + BS(look, RVN_BE_ARM) + nx + nw, ry + rh - 0.5, X + BS(look, RVN_BE_ARM) + nx + nd, X + BS(look, RVN_BE_ARM) + nx + nw - nd, ry + rh + nd, fill);
            draw_h.rvn_paint_rect(p, base.rvn_rect(X, BY(look, y + b.*.mouth_y[idx(s)]) - 0.5, BS(look, RVN_BE_ARM), BS(look, b.*.mouth_h[idx(s)]) + 1.0), fill);
        }
        {
            const by = BY(look, y + b.*.h - RVN_BE_BOTTOM);
            const radii = [_]f32{ 0.0, r, r, r };
            draw_h.rvn_paint_box4(p, base.rvn_rect(X, by, w, BS(look, RVN_BE_BOTTOM)), &radii, fill, 0.0, 0);
            rvn_be_trapezoid(p, X + nx, X + nx + nw, by + BS(look, RVN_BE_BOTTOM) - 0.5, X + nx + nd, X + nx + nw - nd, by + BS(look, RVN_BE_BOTTOM) + nd, fill);
        }
    } else {
        const radii = [_]f32{ r, r, r, r };
        if (k.*.shape == raven.R_BLOCK_HAT) {
            // a round cap on top of the first row
            const cap = BS(look, 14.0);
            draw_h.rvn_paint_box(p, base.rvn_rect(X, Y, base.rvn_minf(w, BS(look, 90.0)), cap * 2.0), cap, fill, 0.0, 0);
            draw_h.rvn_paint_box4(p, base.rvn_rect(X, Y + cap, w, h - cap), &radii, fill, 0.0, 0);
        } else {
            draw_h.rvn_paint_box4(p, base.rvn_rect(X, Y, w, h), &radii, fill, 0.0, 0);
        }
        if (rvn_be_has_next(k.*.shape))
            rvn_be_trapezoid(p, X + nx, X + nx + nw, Y + h - 0.5, X + nx + nd, X + nx + nw - nd, Y + h + nd, fill);
    }
    // the notch on top : what is behind shows through
    if (notch_top != 0 and rvn_be_has_top(k.*.shape))
        rvn_be_trapezoid(p, X + nx, X + nx + nw, Y - 0.5, X + nx + nd, X + nx + nw - nd, Y + nd, behind);
    // C: (void)edge (edge is unused in this translation as in the C)
}

fn rvn_be_paint_block(p: [*c]draw_h.RPainter, e: [*c]rvn_block_editor_t, b: [*c]rvn_be_block_t, x: f32, y: f32, look: [*c]const rvn_be_look_t, notch_top: c_int, behind: base.rvn_color_t) void {
    const k = rvn_be_kind_of(e, b);
    if (k == null) return;
    const hover = base.rvn_clampf(draw_h.rvn_paint_spring(p, &b.*.hover, if (e.*.hot_block == b.*.id and e.*.drag == RVN_BE_NONE) 1.0 else 0.0, raven.R_MOTION_SNAPPY), 0.0, 1.0);
    const glow = base.rvn_clampf(draw_h.rvn_paint_spring(p, &b.*.glow_shown, if (b.*.glow != 0) 1.0 else 0.0, raven.R_MOTION_SMOOTH), 0.0, 1.0);
    const saved = p.*.opacity;
    const category_color = rvn_be_category_color(e, k.*.category);
    const fill = base.rvn_color_mix(category_color, base.rvn_rgba(1.0, 1.0, 1.0, 1.0), 0.10 * hover);
    const edge = base.rvn_color_mix(category_color, base.rvn_rgba(0.0, 0.0, 0.0, 1.0), 0.25);
    const text = if (rvn_be_light(category_color)) look.*.text_dark else look.*.text_light;
    p.*.opacity *= base.rvn_clampf(b.*.fade.value, 0.0, 1.0) * look.*.opacity;

    if (glow > 0.01) {
        // running : a breathing halo
        const breath = 0.5 + 0.5 * libc.sinf(@as(f32, @floatCast(ext.rvn_clock_seconds())) * 5.0);
        draw_h.rvn_paint_shadow(p, base.rvn_rect(BX(look, x) - BS(look, 3.0), BY(look, y) - BS(look, 3.0), BS(look, b.*.w + 6.0), BS(look, b.*.h + 6.0)), BS(look, RVN_BE_RADIUS + 3.0), BS(look, 8.0 + 6.0 * breath), base.rvn_color_fade(look.*.glow, (0.55 + 0.35 * breath) * glow));
    }
    rvn_be_paint_shape(p, e, b, k, x, y, look, fill, edge, notch_top, behind);
    if (b.*.sel != 0 and b.*.palette == 0) {
        const sh: f32 = if (rvn_be_is_value(k.*.shape)) b.*.h else (if (k.*.shape == raven.R_BLOCK_C) b.*.h else b.*.row_h[0]);
        draw_h.rvn_paint_box(p, base.rvn_rect(BX(look, x) - 2.0, BY(look, y) - 2.0, BS(look, b.*.w) + 4.0, BS(look, sh) + 4.0), if (k.*.shape == raven.R_BLOCK_REPORTER) BS(look, sh * 0.5) + 2.0 else BS(look, RVN_BE_RADIUS + 1.0), 0, 2.0, ext.rvn_widget_color(&e.*.base, raven.R_COLOR_ACCENT));
    }

    // the words and the empty slots of each row
    var t: u32 = 0;
    while (t < k.*.token_count) : (t += 1) {
        const tok = &k.*.tokens[t];
        const sec = tok.*.section;
        const ry = y + b.*.row_y[idx(sec)] + (if (k.*.shape == raven.R_BLOCK_HAT and sec == 0) @as(f32, 14.0) else 0.0);
        const rh = b.*.row_h[idx(sec)] - (if (k.*.shape == raven.R_BLOCK_HAT and sec == 0) @as(f32, 14.0) else 0.0);
        if (tok.*.slot < 0) {
            // (words are placed between the slots : the x is found again from the tokens)
            var tx: f32 = if (rvn_be_is_value(k.*.shape)) (if (k.*.shape == raven.R_BLOCK_BOOLEAN) look.*.m.slot * 0.55 + 6.0 else look.*.m.pad + 2.0) else look.*.m.pad;
            var u: u32 = 0;
            while (u < t) : (u += 1) {
                const o = &k.*.tokens[u];
                if (o.*.section != sec) continue;
                tx += if (o.*.slot < 0) common.rvn_widget_text_width(&e.*.base, raven.R_INVALID_ID, look.*.m.font, o.*.text) + 4.0 else b.*.slot_w[idx(o.*.slot)] + 5.0;
            }
            draw_h.rvn_paint_text_in(p, raven.R_INVALID_ID, BS(look, look.*.m.font), base.rvn_rect(BX(look, x + tx), BY(look, ry), BS(look, 400.0), BS(look, rh)), 0.0, tok.*.text, -1, text);
        } else if (b.*.input[idx(tok.*.slot)] == 0 or rvn_be_block(e, b.*.input[idx(tok.*.slot)]) == null or rvn_be_block(e, b.*.input[idx(tok.*.slot)]).*.dying != 0) {
            const slot = tok.*.slot;
            const slot_type = k.*.slot_types[idx(slot)];
            const sx = BX(look, x + b.*.slot_x[idx(slot)]);
            const sy = BY(look, y + b.*.slot_y[idx(slot)]);
            const sw = BS(look, b.*.slot_w[idx(slot)]);
            const sh = BS(look, b.*.slot_h[idx(slot)]);
            const hot = e.*.drag == RVN_BE_BLOCKS and e.*.target == b.*.id and e.*.target_place == raven.R_BLOCK_INPUT and e.*.target_index == slot;
            const light = base.rvn_clampf(draw_h.rvn_paint_spring_from(p, &e.*.ghost_shown, 1.0, raven.R_MOTION_SNAPPY), 0.0, 1.0);
            if (slot_type == 'b') {
                const tip = sh * 0.5;
                const c = base.rvn_color_mix(category_color, base.rvn_rgba(0.0, 0.0, 0.0, 1.0), 0.32);
                draw_h.rvn_paint_rect(p, base.rvn_rect(sx + tip, sy, sw - tip * 2.0, sh), c);
                draw_h.rvn_paint_triangle(p, sx, sy + tip, sx + tip, sy, sx + tip, sy + sh, c);
                draw_h.rvn_paint_triangle(p, sx + sw, sy + tip, sx + sw - tip, sy + sh, sx + sw - tip, sy, c);
            } else if (slot_type == 'm') {
                // a choice : darker than the block, an arrow on the right
                const c = base.rvn_color_mix(category_color, base.rvn_rgba(0.0, 0.0, 0.0, 1.0), 0.22);
                const ax = sx + sw - BS(look, 12.0);
                const ay = sy + sh * 0.5;
                const aw = BS(look, 4.0);
                draw_h.rvn_paint_box(p, base.rvn_rect(sx, sy, sw, sh), BS(look, 4.0), c, BS(look, 1.0), base.rvn_color_mix(category_color, base.rvn_rgba(0.0, 0.0, 0.0, 1.0), 0.35));
                draw_h.rvn_paint_text_in(p, raven.R_INVALID_ID, BS(look, look.*.m.font), base.rvn_rect(sx + BS(look, 6.0), sy, sw - BS(look, 22.0), sh), 0.0, rvn_be_or_empty(b.*.value[idx(slot)]), -1, text);
                draw_h.rvn_paint_triangle(p, ax - aw, ay - aw * 0.5, ax + aw, ay - aw * 0.5, ax, ay + aw * 0.7, text);
            } else {
                draw_h.rvn_paint_box(p, base.rvn_rect(sx, sy, sw, sh), if (slot_type == 'n') sh * 0.5 else BS(look, 4.0), look.*.slot_fill, BS(look, 1.0), look.*.slot_line);
                draw_h.rvn_paint_text_in(p, raven.R_INVALID_ID, BS(look, look.*.m.font), base.rvn_rect(sx, sy, sw, sh), 0.5, rvn_be_or_empty(b.*.value[idx(slot)]), -1, look.*.slot_text);
            }
            if (hot) {
                draw_h.rvn_paint_box(p, base.rvn_rect(sx - 2.0, sy - 2.0, sw + 4.0, sh + 4.0), sh * 0.5 + 2.0, 0, 2.5, base.rvn_color_fade(base.rvn_rgba(1.0, 1.0, 1.0, 1.0), 0.9 * light));
            }
        }
    }
    p.*.opacity = saved;
}

/// A block and what hangs under it, at their shown positions. `behind`: the color the notches show.
fn rvn_be_paint_tree(p: [*c]draw_h.RPainter, e: [*c]rvn_block_editor_t, b: [*c]rvn_be_block_t, look: [*c]const rvn_be_look_t, notch_top: c_int, behind: base.rvn_color_t) void {
    const k = rvn_be_kind_of(e, b);
    if (b == null or k == null) return;
    rvn_be_paint_block(p, e, b, b.*.sx.value, b.*.sy.value, look, notch_top, behind);
    var s: c_int = 0;
    while (s < k.*.slot_count) : (s += 1) {
        const input = rvn_be_block(e, b.*.input[idx(s)]);
        if (input != null and input.*.dying == 0) rvn_be_paint_tree(p, e, input, look, R_FALSE, behind);
    }
    if (k.*.shape == raven.R_BLOCK_C) {
        s = 0;
        while (s < k.*.sections) : (s += 1) {
            var c = rvn_be_block(e, b.*.body[idx(s)]);
            var first = R_TRUE;
            var guard: c_int = 0;
            while (c != null and guard < 100000) {
                guard += 1;
                rvn_be_paint_tree(p, e, c, look, first, rvn_be_category_color(e, k.*.category));
                first = R_FALSE;
                c = rvn_be_block(e, c.*.next);
            }
        }
    }
    if (b.*.next != 0) {
        const n = rvn_be_block(e, b.*.next);
        if (n != null and n.*.dying == 0) rvn_be_paint_tree(p, e, n, look, R_FALSE, behind);
    }
}

/// Moves the shown positions of a script toward their layout.
fn rvn_be_animate(p: [*c]draw_h.RPainter, e: [*c]rvn_block_editor_t) void {
    var i: u32 = 0;
    while (i < e.*.block_count) : (i += 1) {
        const b = &e.*.blocks[i];
        if (b.*.palette != 0) {
            draw_h.rvn_spring_set(&b.*.sx, b.*.lx);
            draw_h.rvn_spring_set(&b.*.sy, b.*.ly);
            continue;
        }
        if (b.*.placed == 0) {
            draw_h.rvn_spring_set(&b.*.sx, b.*.lx);
            draw_h.rvn_spring_set(&b.*.sy, b.*.ly);
            b.*.placed = R_TRUE;
        } else if (e.*.drag == RVN_BE_BLOCKS and rvn_be_inside(e, b.*.id, e.*.carried)) {
            // (the carried stack sticks to the pointer)
            draw_h.rvn_spring_set(&b.*.sx, b.*.lx);
            draw_h.rvn_spring_set(&b.*.sy, b.*.ly);
        } else {
            _ = draw_h.rvn_paint_spring(p, &b.*.sx, b.*.lx, raven.R_MOTION_SNAPPY);
            _ = draw_h.rvn_paint_spring(p, &b.*.sy, b.*.ly, raven.R_MOTION_SNAPPY);
        }
        _ = draw_h.rvn_paint_spring(p, &b.*.appear, 1.0, raven.R_MOTION_BOUNCY);
        if (b.*.dying != 0) {
            _ = draw_h.rvn_paint_spring(p, &b.*.fade, 0.0, raven.R_MOTION_SMOOTH);
            draw_h.rvn_paint_keep_animating(p);
        }
        if (b.*.glow != 0) draw_h.rvn_paint_keep_animating(p);
    }
}

fn rvn_block_editor_paint(widget: [*c]widget_h.rvn_widget_t, painter_: ?*raven.RPainter) callconv(.c) void {
    const painter: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter_));
    const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(widget));
    const bounds = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    const canvas = ext.rvn_widget_color(widget, raven.R_COLOR_INPUT);
    var look: rvn_be_look_t = undefined;
    const left = rvn_be_canvas_left(e);

    // the carried stack follows the pointer : its top is laid out there
    if (e.*.drag == RVN_BE_BLOCKS) {
        const d = rvn_be_block(e, e.*.carried);
        if (d != null) {
            var cx: f32 = undefined;
            var cy: f32 = undefined;
            rvn_be_to_canvas(e, e.*.pointer_x, e.*.pointer_y, &cx, &cy);
            d.*.x = cx - e.*.grab_x;
            d.*.y = cy - e.*.grab_y;
        }
        rvn_be_find_target(e);
    }
    rvn_be_layout(e);
    rvn_be_animate(painter, e);
    rvn_be_purge(e, R_FALSE);
    e.*.painted = R_TRUE;

    look = std.mem.zeroes(rvn_be_look_t);
    look.m = rvn_be_metrics(widget);
    look.dark = boolInt(rvn_be_dark_theme(widget));
    look.text_light = base.rvn_rgba(1.0, 1.0, 1.0, 1.0);
    look.text_dark = base.rvn_hex(0x1C1D22, 255);
    look.slot_fill = if (look.dark != 0) base.rvn_color_mix(canvas, base.rvn_rgba(0.0, 0.0, 0.0, 1.0), 0.25) else base.rvn_rgba(1.0, 1.0, 1.0, 1.0);
    look.slot_text = if (look.dark != 0) base.rvn_rgba(0.95, 0.95, 0.97, 1.0) else base.rvn_hex(0x575E75, 255);
    look.slot_line = base.rvn_color_fade(base.rvn_rgba(0.0, 0.0, 0.0, 1.0), 0.18);
    look.glow = ext.rvn_widget_color(widget, raven.R_COLOR_WARNING);
    look.opacity = 1.0;

    // ---- the canvas : the color of a field, a grid of dots ----
    draw_h.rvn_paint_box(painter, bounds, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), canvas, 1.0, ext.rvn_widget_color(widget, raven.R_COLOR_BORDER));
    const zoom = base.rvn_clampf(draw_h.rvn_paint_spring(painter, &e.*.shown_zoom, e.*.zoom, raven.R_MOTION_SNAPPY), 0.2, 4.0);
    draw_h.rvn_paint_push_clip(painter, base.rvn_rect(left + 1.0, 1.0, bounds.w - left - 2.0, bounds.h - 2.0));
    {
        var step = RVN_BE_GRID * zoom;
        const dot = base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_TEXT), 0.10);
        while (step < 12.0) step *= 2.0;
        var fx = left + libc.fmodf(-e.*.pan_x * zoom, step);
        var fy = libc.fmodf(-e.*.pan_y * zoom, step);
        if (fx < left) fx += step;
        if (fy < 0.0) fy += step;
        var y = fy;
        while (y < bounds.h) : (y += step) {
            var x = fx;
            while (x < bounds.w) : (x += step) draw_h.rvn_paint_rect(painter, base.rvn_rect(x - 1.0, y - 1.0, 2.0, 2.0), dot);
        }
    }
    look.ox = left - e.*.pan_x * zoom;
    look.oy = -e.*.pan_y * zoom;
    look.scale = zoom;

    // ---- the scripts ----
    {
        var i: u32 = 0;
        while (i < e.*.order_count) : (i += 1) {
            const top = rvn_be_block(e, e.*.order[i]);
            if (top == null or top.*.id == e.*.carried) continue;
            rvn_be_paint_tree(painter, e, top, &look, R_TRUE, canvas);
        }
    }
    // blocks that go away (dropped on the palette)
    {
        var i: u32 = 0;
        while (i < e.*.block_count) : (i += 1) {
            const b = &e.*.blocks[i];
            if (b.*.dying != 0 and b.*.palette == 0) rvn_be_paint_block(painter, e, b, b.*.sx.value, b.*.sy.value, &look, R_FALSE, canvas);
        }
    }
    // the shadow of the carried stack where it would go
    {
        const d = rvn_be_block(e, e.*.carried);
        const showing = e.*.drag == RVN_BE_BLOCKS and d != null and (e.*.target != 0 or e.*.target_top != 0) and e.*.target_place != raven.R_BLOCK_INPUT;
        const shown = base.rvn_clampf(draw_h.rvn_paint_spring(painter, &e.*.ghost_shown, if (showing) 1.0 else 0.0, raven.R_MOTION_SNAPPY), 0.0, 1.0);
        if (showing and shown > 0.02) {
            const k = rvn_be_kind_of(e, d);
            const shade = base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_TEXT), 0.16 * shown);
            if (k != null) {
                var h: f32 = 0.0;
                var c = d;
                var guard: c_int = 0;
                while (c != null and guard < 100000) {
                    guard += 1;
                    h += c.*.h;
                    c = rvn_be_block(e, c.*.next);
                }
                draw_h.rvn_paint_box(painter, base.rvn_rect(look.ox + e.*.ghost_x * zoom, look.oy + e.*.ghost_y * zoom, d.*.w * zoom, h * zoom * shown), RVN_BE_RADIUS * zoom, shade, 1.0, base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_TEXT), 0.3 * shown));
            }
        }
    }
    // the selection rectangle
    if (e.*.drag == RVN_BE_MARQUEE) {
        const x0 = base.rvn_minf(e.*.marquee_x0, e.*.marquee_x1);
        const x1 = base.rvn_maxf(e.*.marquee_x0, e.*.marquee_x1);
        const y0 = base.rvn_minf(e.*.marquee_y0, e.*.marquee_y1);
        const y1 = base.rvn_maxf(e.*.marquee_y0, e.*.marquee_y1);
        const accent = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
        draw_h.rvn_paint_box(painter, base.rvn_rect(look.ox + x0 * zoom, look.oy + y0 * zoom, (x1 - x0) * zoom, (y1 - y0) * zoom), 2.0, base.rvn_color_fade(accent, 0.12), 1.0, base.rvn_color_fade(accent, 0.8));
    }
    // the carried stack, lifted
    if (e.*.drag == RVN_BE_BLOCKS) {
        const d = rvn_be_block(e, e.*.carried);
        if (d != null) {
            var h: f32 = 0.0;
            var c = d;
            var guard: c_int = 0;
            while (c != null and guard < 100000) {
                guard += 1;
                h += c.*.h;
                c = rvn_be_block(e, c.*.next);
            }
            draw_h.rvn_paint_shadow(painter, base.rvn_rect(look.ox + d.*.sx.value * zoom + 4.0, look.oy + d.*.sy.value * zoom + 8.0, d.*.w * zoom, h * zoom), RVN_BE_RADIUS * zoom, 18.0, base.rvn_rgba(0.0, 0.0, 0.0, 0.35));
            look.opacity = if (rvn_be_in_palette(e, e.*.pointer_x) != 0) 0.5 else 0.96;
            rvn_be_paint_tree(painter, e, d, &look, R_FALSE, canvas);
            look.opacity = 1.0;
        }
    }
    draw_h.rvn_paint_pop_clip(painter);

    // ---- the palette ----
    if (e.*.palette_hidden == 0) {
        var pl = look;
        const trash = base.rvn_clampf(draw_h.rvn_paint_spring(painter, &e.*.trash, if (e.*.drag == RVN_BE_BLOCKS and rvn_be_in_palette(e, e.*.pointer_x) != 0) 1.0 else 0.0, raven.R_MOTION_SNAPPY), 0.0, 1.0);
        var category: [*c]const u8 = null;
        const radii = [_]f32{ ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS), 0.0, 0.0, ext.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS) };
        const panel = base.rvn_color_mix(ext.rvn_widget_color(widget, raven.R_COLOR_PANEL), ext.rvn_widget_color(widget, raven.R_COLOR_DANGER), 0.18 * trash);
        draw_h.rvn_paint_box4(painter, base.rvn_rect(0.0, 0.0, RVN_BE_PALETTE_W, bounds.h), &radii, panel, 0.0, 0);
        draw_h.rvn_paint_rect(painter, base.rvn_rect(RVN_BE_PALETTE_W - 1.0, 0.0, 1.0, bounds.h), ext.rvn_widget_color(widget, raven.R_COLOR_BORDER));
        draw_h.rvn_paint_push_clip(painter, base.rvn_rect(0.0, 1.0, RVN_BE_PALETTE_W - 1.0, bounds.h - 2.0));
        pl.ox = 0.0;
        pl.oy = -e.*.palette_scroll;
        pl.scale = 1.0;
        {
            var i: u32 = 0;
            while (i < e.*.block_count) : (i += 1) {
                const b = &e.*.blocks[i];
                const k = rvn_be_kind_of(e, b);
                if (b.*.palette == 0) continue;
                if (k == null or k.*.hidden != 0) continue;
                if (category == null or libc.strcmp(category, if (k.*.category != null) k.*.category else "") != 0) {
                    category = if (k.*.category != null) k.*.category else "";
                    if (category[0] != 0) {
                        const c = rvn_be_category_color(e, category);
                        const hy = b.*.ly - 24.0 - e.*.palette_scroll;
                        draw_h.rvn_paint_box(painter, base.rvn_rect(14.0, hy + 6.0, 10.0, 10.0), 5.0, c, 0.0, 0);
                        draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, look.m.font, base.rvn_rect(30.0, hy, RVN_BE_PALETTE_W - 40.0, 22.0), 0.0, category, -1, ext.rvn_widget_color(widget, raven.R_COLOR_TEXT));
                    }
                }
                pl.opacity = 1.0 - 0.6 * trash;
                rvn_be_paint_block(painter, e, b, b.*.lx, b.*.ly, &pl, R_TRUE, panel);
            }
        }
        if (trash > 0.02) {
            draw_h.rvn_paint_text_in(painter, raven.R_INVALID_ID, look.m.font * 1.1, base.rvn_rect(0.0, bounds.h * 0.5 - 20.0, RVN_BE_PALETTE_W, 40.0), 0.5, "Drop here to delete", -1, base.rvn_color_fade(ext.rvn_widget_color(widget, raven.R_COLOR_TEXT), trash));
        }
        draw_h.rvn_paint_pop_clip(painter);
    }

    // the editor of a slot follows the block (pan, zoom, layout)
    if (e.*.field != null and e.*.field.*.visibility == raven.R_VISIBLE) ext.rvn_widget_invalidate_layout(widget);
}

// ---------------------------------------------------------------------------
//  The editor of a value slot (a text field over it)
// ---------------------------------------------------------------------------

fn rvn_be_close_field(e: [*c]rvn_block_editor_t) void {
    if (e.*.field == null) return;
    e.*.edit_block = 0;
    e.*.field.*.visibility = raven.R_COLLAPSED;
    ext.rvn_widget_invalidate_layout(&e.*.base);
}

/// Keeps what was typed in the slot being edited (a number slot keeps a number), and closes the editor.
fn rvn_be_apply_field(e: [*c]rvn_block_editor_t, text_in: [*c]const u8) void {
    const b = rvn_be_block(e, e.*.edit_block);
    const k = rvn_be_kind_of(e, b);
    var value: [*c]const u8 = if (text_in != null) text_in else "";
    var number: [64]u8 = undefined;
    var changed = R_FALSE;
    if (b != null and k != null and e.*.edit_slot >= 0 and e.*.edit_slot < k.*.slot_count) {
        if (k.*.slot_types[idx(e.*.edit_slot)] == 'n') {
            var end: [*c]u8 = null;
            var v = libc.strtod(value, &end);
            if (end == value) v = 0.0;
            _ = libc.snprintf(&number, number.len, "%g", @as(f64, v));
            value = &number;
        }
        if (b.*.value[idx(e.*.edit_slot)] == null or libc.strcmp(b.*.value[idx(e.*.edit_slot)], value) != 0) {
            _ = base.rvn_str_set(&b.*.value[idx(e.*.edit_slot)], value);
            changed = R_TRUE;
        }
    }
    rvn_be_close_field(e);
    if (changed != 0) {
        rvn_be_changed(e);
        rvn_be_notify(e, b.*.id);
    }
}

/// A click elsewhere keeps the edit too (Scratch).
fn rvn_be_finish_field(e: [*c]rvn_block_editor_t) void {
    if (e.*.field == null or e.*.edit_block == 0 or e.*.field.*.visibility != raven.R_VISIBLE) {
        rvn_be_close_field(e);
        return;
    }
    {
        const text = base.rvn_strdup(raven.Rtext_input_get_text(e.*.field.*.id));
        rvn_be_apply_field(e, text);
        base.rvn_free(text);
    }
}

fn rvn_be_field_committed(field: raven.Rid, text: [*c]const u8, user: ?*anyopaque) callconv(.c) void {
    _ = field;
    // (Rid)(uintptr_t)user
    const id: raven.Rid = if (user) |u| @intCast(@intFromPtr(u)) else 0;
    const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(ext.rvn_widget_check(id, raven.R_WIDGET_BLOCK_EDITOR, "block editor")));
    if (e == null or e.*.edit_block == 0) return;
    rvn_be_apply_field(e, text);
}

fn rvn_be_open_field(e: [*c]rvn_block_editor_t, block: c_int, slot: c_int) void {
    const b = rvn_be_block(e, block);
    if (b == null or slot < 0) return;
    if (e.*.field == null) {
        e.*.field = widget_h.rvn_widget_create(raven.R_WIDGET_TEXT_INPUT);
        if (e.*.field == null) return;
        ext.rvn_widget_add_child(&e.*.base, e.*.field, -1);
        raven.Rtext_input_set_committed_callback(e.*.field.*.id, rvn_be_field_committed, idPtr(e.*.base.id));
    }
    e.*.edit_block = block;
    e.*.edit_slot = slot;
    raven.Rtext_input_set_text(e.*.field.*.id, rvn_be_or_empty(b.*.value[idx(slot)]));
    raven.Rtext_input_select_all(e.*.field.*.id);
    e.*.field.*.visibility = raven.R_VISIBLE;
    ext.rvn_widget_invalidate_layout(&e.*.base);
    ext.rvn_widget_focus(e.*.field);
}

// ---------------------------------------------------------------------------
//  Selection
// ---------------------------------------------------------------------------

fn rvn_be_clear_selection(e: [*c]rvn_block_editor_t) void {
    var i: u32 = 0;
    while (i < e.*.block_count) : (i += 1) e.*.blocks[i].sel = R_FALSE;
    e.*.selected = 0;
}

fn rvn_be_select(e: [*c]rvn_block_editor_t, id: c_int, on: c_int) void {
    const b = rvn_be_block(e, id);
    if (b == null or b.*.palette != 0 or b.*.dying != 0) return;
    b.*.sel = on;
    if (on != 0) e.*.selected = id else if (e.*.selected == id) e.*.selected = 0;
}

fn rvn_be_selection_count(e: [*c]const rvn_block_editor_t) c_int {
    var n: c_int = 0;
    var i: u32 = 0;
    while (i < e.*.block_count) : (i += 1) {
        if (e.*.blocks[i].sel != 0 and e.*.blocks[i].palette == 0 and e.*.blocks[i].dying == 0) n += 1;
    }
    return n;
}

/// A selected block none of whose ancestors is selected : it goes with what hangs under it.
fn rvn_be_is_selection_root(e: [*c]rvn_block_editor_t, b: [*c]const rvn_be_block_t) c_int {
    var guard: c_int = 0;
    if (b.*.sel == 0 or b.*.palette != 0 or b.*.dying != 0) return R_FALSE;
    var p = rvn_be_block(e, b.*.parent);
    while (p != null and guard < 100000) {
        guard += 1;
        if (p.*.sel != 0) return R_FALSE;
        p = rvn_be_block(e, p.*.parent);
    }
    return R_TRUE;
}

fn rvn_be_collect_roots(e: [*c]rvn_block_editor_t) void {
    e.*.group_count = 0;
    var i: u32 = 0;
    while (i < e.*.block_count) : (i += 1) {
        const b = &e.*.blocks[i];
        if (rvn_be_is_selection_root(e, b) == 0) continue;
        base.RVN_ARRAY_RESERVE(&e.*.group, &e.*.group_cap, e.*.group_count + 1);
        e.*.group[idx(e.*.group_count)] = b.*.id;
        e.*.group_count += 1;
    }
}

/// The blocks the rectangle touches are selected (with those selected before it, Ctrl / Shift).
fn rvn_be_update_marquee(e: [*c]rvn_block_editor_t) void {
    const x0 = base.rvn_minf(e.*.marquee_x0, e.*.marquee_x1);
    const x1 = base.rvn_maxf(e.*.marquee_x0, e.*.marquee_x1);
    const y0 = base.rvn_minf(e.*.marquee_y0, e.*.marquee_y1);
    const y1 = base.rvn_maxf(e.*.marquee_y0, e.*.marquee_y1);
    e.*.selected = 0;
    var i: u32 = 0;
    while (i < e.*.block_count) : (i += 1) {
        const b = &e.*.blocks[i];
        if (b.*.palette != 0 or b.*.dying != 0) continue;
        const hit = b.*.sx.value < x1 and b.*.sx.value + b.*.w > x0 and b.*.sy.value < y1 and b.*.sy.value + b.*.h > y0;
        b.*.sel = boolInt(b.*.sel_base != 0 or hit);
        if (b.*.sel != 0) e.*.selected = b.*.id;
    }
}

/// Moving the selection : its roots become scripts of their own, they follow the pointer.
fn rvn_be_begin_group(e: [*c]rvn_block_editor_t, x: f32, y: f32) void {
    rvn_be_finish_field(e);
    rvn_be_collect_roots(e);
    var i: u32 = 0;
    while (i < e.*.group_count) : (i += 1) {
        const b = rvn_be_block(e, e.*.group[i]);
        if (b != null and b.*.parent != 0) rvn_be_make_top(e, b, b.*.sx.value, b.*.sy.value);
    }
    rvn_be_to_canvas(e, x, y, &e.*.group_x, &e.*.group_y);
    e.*.drag = RVN_BE_GROUP;
    rvn_be_changed(e);
}

fn rvn_be_move_group(e: [*c]rvn_block_editor_t, x: f32, y: f32) void {
    var cx: f32 = undefined;
    var cy: f32 = undefined;
    rvn_be_to_canvas(e, x, y, &cx, &cy);
    var i: u32 = 0;
    while (i < e.*.group_count) : (i += 1) {
        const b = rvn_be_block(e, e.*.group[i]);
        if (b == null or b.*.parent != 0) continue;
        b.*.x += cx - e.*.group_x;
        b.*.y += cy - e.*.group_y;
    }
    e.*.group_x = cx;
    e.*.group_y = cy;
    rvn_be_changed(e);
}

fn rvn_be_delete_selection(e: [*c]rvn_block_editor_t) void {
    rvn_be_collect_roots(e);
    var i: u32 = 0;
    while (i < e.*.group_count) : (i += 1) {
        const b = rvn_be_block(e, e.*.group[i]);
        if (b == null) continue;
        if (b.*.locked != 0) {
            // it stays; what hangs under it goes if it was selected too
            const n = rvn_be_block(e, b.*.next);
            b.*.sel = R_FALSE;
            if (n != null and n.*.sel != 0) rvn_be_delete_script(e, n.*.id, R_TRUE);
            continue;
        }
        rvn_be_delete_script(e, e.*.group[i], R_TRUE);
    }
    e.*.selected = 0;
}

// ---------------------------------------------------------------------------
//  The menu of a %m slot
// ---------------------------------------------------------------------------

fn rvn_be_menu_clicked(item: raven.Rid, user: ?*anyopaque) callconv(.c) void {
    const id: raven.Rid = if (user) |u| @intCast(@intFromPtr(u)) else 0;
    const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(ext.rvn_widget_check(id, raven.R_WIDGET_BLOCK_EDITOR, "block editor")));
    if (e == null) return;
    const b = rvn_be_block(e, e.*.menu_block);
    const text = raven.Rmenu_item_get_text(item);
    if (b == null or text == null or e.*.menu_slot < 0 or e.*.menu_slot >= RVN_BE_MAX_SLOTS) return;
    if (b.*.value[idx(e.*.menu_slot)] == null or libc.strcmp(b.*.value[idx(e.*.menu_slot)], text) != 0) {
        _ = base.rvn_str_set(&b.*.value[idx(e.*.menu_slot)], text);
        rvn_be_changed(e);
        rvn_be_notify(e, b.*.id);
    }
}

/// The choices of the slot under it ; a slot without choices is typed in.
fn rvn_be_open_menu(e: [*c]rvn_block_editor_t, block: c_int, slot: c_int) void {
    const b = rvn_be_block(e, block);
    const k = rvn_be_kind_of(e, b);
    var items: c_int = 0;
    if (b == null or k == null or slot < 0 or slot >= k.*.slot_count) return;
    if (k.*.options[idx(slot)] == null or k.*.options[idx(slot)][0] == 0) {
        rvn_be_open_field(e, block, slot);
        return;
    }
    if (e.*.menu != raven.R_INVALID_ID and raven.Rwidget_is_valid(e.*.menu) != 0) raven.Rwidget_destroy(e.*.menu);
    e.*.menu = raven.Rwidget_create(raven.R_WIDGET_MENU);
    if (e.*.menu == raven.R_INVALID_ID) return;
    e.*.menu_block = block;
    e.*.menu_slot = slot;
    {
        var c: [*c]const u8 = k.*.options[idx(slot)];
        while (c[0] != 0) {
            const end = libc.strchr(c, '\n');
            const n: usize = if (end != null) @intFromPtr(end) - @intFromPtr(c) else libc.strlen(c);
            if (n > 0) {
                const text = base.rvn_strndup(c, n);
                const item = raven.Rmenu_add_item(e.*.menu, text);
                if (b.*.value[idx(slot)] != null and libc.strcmp(b.*.value[idx(slot)], text) == 0) {
                    raven.Rmenu_item_set_checkable(item, R_TRUE);
                    raven.Rmenu_item_set_checked(item, R_TRUE);
                }
                raven.Rmenu_item_set_clicked_callback(item, rvn_be_menu_clicked, idPtr(e.*.base.id));
                base.rvn_free(text);
                items += 1;
            }
            c += n;
            if (c[0] == '\n') c += 1;
        }
    }
    if (items == 0) return;
    const origin = ext.rvn_widget_origin(&e.*.base);
    const zoom: f32 = if (e.*.shown_zoom.value > 0.0) e.*.shown_zoom.value else 1.0;
    var x = origin.x + rvn_be_canvas_left(e) + (b.*.sx.value + b.*.slot_x[idx(slot)] - e.*.pan_x) * zoom;
    var y = origin.y + (b.*.sy.value + b.*.slot_y[idx(slot)] + b.*.slot_h[idx(slot)] - e.*.pan_y) * zoom + 2.0;
    ext.rvn_widget_from_virtual(&e.*.base, &x, &y);
    raven.Rmenu_open(e.*.menu, raven.Rwidget_get_window(e.*.base.id), x, y);
}

// ---------------------------------------------------------------------------
//  Widget class
// ---------------------------------------------------------------------------

fn rvn_block_editor_init(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(widget));
    e.*.next_id = 1;
    e.*.zoom = 1.0;
    draw_h.rvn_spring_set(&e.*.shown_zoom, 1.0);
    e.*.pan_x = -20.0;
    e.*.pan_y = -20.0;
    e.*.layout_dirty = R_TRUE;
    e.*.menu = raven.R_INVALID_ID;
}

fn rvn_block_editor_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(widget));
    var i: u32 = 0;
    while (i < e.*.block_count) : (i += 1) rvn_be_free_block_data(&e.*.blocks[i]);
    i = 0;
    while (i < e.*.kind_count) : (i += 1) rvn_be_free_kind(&e.*.kinds[i]);
    i = 0;
    while (i < e.*.category_count) : (i += 1) base.rvn_free(e.*.categories[i].name);
    base.rvn_free(e.*.blocks);
    base.rvn_free(e.*.kinds);
    base.rvn_free(e.*.categories);
    base.rvn_free(e.*.order);
    base.rvn_free(e.*.drawn);
    base.rvn_free(e.*.group);
    base.rvn_free(e.*.saved.data);
    if (e.*.menu != raven.R_INVALID_ID and raven.Rwidget_is_valid(e.*.menu) != 0) raven.Rwidget_destroy(e.*.menu);
}

fn rvn_block_editor_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    _ = widget;
    return base.rvn_vec2(560.0, 360.0);
}

fn rvn_block_editor_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(widget));
    if (e.*.field == null) return;
    const b = rvn_be_block(e, e.*.edit_block);
    if (b == null or e.*.field.*.visibility != raven.R_VISIBLE) {
        ext.rvn_widget_arrange(e.*.field, 0.0, 0.0, 0.0, 0.0);
        return;
    }
    const zoom: f32 = if (e.*.shown_zoom.value > 0.0) e.*.shown_zoom.value else 1.0;
    const x = rvn_be_canvas_left(e) + (b.*.sx.value + b.*.slot_x[idx(e.*.edit_slot)] - e.*.pan_x) * zoom;
    const y = (b.*.sy.value + b.*.slot_y[idx(e.*.edit_slot)] - e.*.pan_y) * zoom;
    _ = ext.rvn_widget_measure(e.*.field);
    ext.rvn_widget_arrange(e.*.field, x - 2.0, y + (b.*.slot_h[idx(e.*.edit_slot)] * zoom - e.*.field.*.desired.y) * 0.5, base.rvn_maxf(60.0, b.*.slot_w[idx(e.*.edit_slot)] * zoom + 30.0), e.*.field.*.desired.y);
}

/// Starts carrying a block : it leaves its place, with what is under it (statements).
fn rvn_be_begin_carry(e: [*c]rvn_block_editor_t, b_in: [*c]rvn_be_block_t, x: f32, y: f32) void {
    var cx: f32 = undefined;
    var cy: f32 = undefined;
    const id = b_in.*.id;
    rvn_be_to_canvas(e, x, y, &cx, &cy);
    e.*.grab_x = cx - b_in.*.sx.value;
    e.*.grab_y = cy - b_in.*.sy.value;
    rvn_be_make_top(e, b_in, b_in.*.sx.value, b_in.*.sy.value);
    _ = rvn_be_block(e, id);
    rvn_be_order_raise(e, id);
    e.*.carried = id;
    e.*.drag = RVN_BE_BLOCKS;
    rvn_be_clear_selection(e);
    rvn_be_select(e, id, R_TRUE);
    rvn_be_finish_field(e);
    rvn_be_changed(e);
}

fn rvn_be_end_carry(e: [*c]rvn_block_editor_t, cancel: c_int) void {
    const d = rvn_be_block(e, e.*.carried);
    const id = e.*.carried;
    e.*.drag = RVN_BE_NONE;
    e.*.carried = 0;
    if (d == null) return;
    if (cancel == 0 and rvn_be_in_palette(e, e.*.pointer_x) != 0 and d.*.locked != 0) {
        // it cannot be deleted : back on the canvas
        var cx: f32 = undefined;
        var cy: f32 = undefined;
        rvn_be_to_canvas(e, RVN_BE_PALETTE_W + 20.0, e.*.pointer_y, &cx, &cy);
        d.*.x = cx;
        e.*.target = 0;
        e.*.target_top = 0;
        rvn_be_changed(e);
        rvn_be_notify(e, id);
        return;
    }
    if (cancel == 0 and rvn_be_in_palette(e, e.*.pointer_x) != 0) {
        // on the palette : deleted (it fades away)
        rvn_be_delete_script(e, id, R_TRUE);
        e.*.target = 0;
        e.*.target_top = 0;
        rvn_be_notify(e, 0);
        return;
    }
    if (cancel == 0 and e.*.target != 0) {
        _ = rvn_be_attach(e, d, rvn_be_block(e, e.*.target), e.*.target_place, e.*.target_index);
    } else if (cancel == 0 and e.*.target_top != 0) {
        // above a script : the script hangs under the carried stack
        const below = rvn_be_block(e, e.*.target_top);
        const last = rvn_be_last_of_chain(e, d);
        if (below != null and last != null) {
            // (the script stays where it is : the carried stack goes over it)
            d.*.x = below.*.x;
            d.*.y = below.*.y - e.*.carried_h;
            rvn_be_order_remove(e, below.*.id);
            last.*.next = below.*.id;
            below.*.parent = last.*.id;
            below.*.place = raven.R_BLOCK_NEXT;
            below.*.index = 0;
        }
    }
    e.*.target = 0;
    e.*.target_top = 0;
    rvn_be_changed(e);
    rvn_be_notify(e, id);
}

fn rvn_be_stack_height(e: [*c]rvn_block_editor_t, b_in: [*c]rvn_be_block_t) f32 {
    var h: f32 = 0.0;
    var guard: c_int = 0;
    const m = rvn_be_metrics(&e.*.base);
    var b = b_in;
    while (b != null and guard < 100000) {
        guard += 1;
        rvn_be_measure_block(e, b, &m);
        h += b.*.h;
        b = rvn_be_block(e, b.*.next);
    }
    return h;
}

fn rvn_block_editor_event(widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent) callconv(.c) c_int {
    const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(widget));
    const origin = ext.rvn_widget_origin(widget);
    const x = event.*.x - origin.x;
    const y = event.*.y - origin.y;
    var slot: c_int = -1;
    var id: c_int = undefined;
    const add: c_int = boolInt((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_CTRL | raven.R_MOD_SHIFT))) != 0);

    switch (event.*.@"type") {
        raven.R_EVENT_MOUSE_MOVE => {
            const moved = @abs(x - e.*.press_x) + @abs(y - e.*.press_y) > 5.0;
            e.*.pointer_x = x;
            e.*.pointer_y = y;
            if (e.*.drag == RVN_BE_PRESS or e.*.drag == RVN_BE_PRESS_SLOT or e.*.drag == RVN_BE_PRESS_PALETTE) {
                if (moved) {
                    var b = rvn_be_block(e, e.*.press_block);
                    if (b != null and e.*.drag == RVN_BE_PRESS_PALETTE) {
                        // a new block from the palette : a copy, carried from where it shows
                        var n = rvn_be_new_block(e, b.*.kind, R_FALSE);
                        var bx: f32 = undefined;
                        var by: f32 = undefined;
                        const nid = n.*.id;
                        b = rvn_be_block(e, e.*.press_block);
                        rvn_be_to_canvas(e, b.*.lx, b.*.ly - e.*.palette_scroll, &bx, &by);
                        n = rvn_be_block(e, nid);
                        n.*.x = bx;
                        n.*.y = by;
                        draw_h.rvn_spring_set(&n.*.sx, bx);
                        draw_h.rvn_spring_set(&n.*.sy, by);
                        n.*.placed = R_TRUE;
                        rvn_be_order_add(e, nid);
                        e.*.layout_dirty = R_TRUE;
                        rvn_be_layout(e);
                        n = rvn_be_block(e, nid);
                        draw_h.rvn_spring_set(&n.*.sx, bx);
                        draw_h.rvn_spring_set(&n.*.sy, by);
                        rvn_be_begin_carry(e, n, e.*.press_x, e.*.press_y);
                    } else if (b != null and b.*.sel != 0 and rvn_be_selection_count(e) > 1) {
                        // a block of a selection : the whole selection moves
                        rvn_be_begin_group(e, e.*.press_x, e.*.press_y);
                        rvn_be_move_group(e, x, y);
                    } else if (b != null) {
                        rvn_be_begin_carry(e, b, e.*.press_x, e.*.press_y);
                    } else {
                        e.*.drag = RVN_BE_NONE;
                    }
                    if (e.*.drag == RVN_BE_BLOCKS) e.*.carried_h = rvn_be_stack_height(e, rvn_be_block(e, e.*.carried));
                }
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            if (e.*.drag == RVN_BE_BLOCKS) {
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            if (e.*.drag == RVN_BE_GROUP) {
                rvn_be_move_group(e, x, y);
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            if (e.*.drag == RVN_BE_PRESS_RIGHT) {
                if (!moved) return R_TRUE;
                e.*.drag = RVN_BE_PAN;
            }
            if (e.*.drag == RVN_BE_PAN) {
                const zoom: f32 = if (e.*.zoom > 0.0) e.*.zoom else 1.0;
                e.*.pan_x = e.*.pan_from_x - (x - e.*.press_x) / zoom;
                e.*.pan_y = e.*.pan_from_y - (y - e.*.press_y) / zoom;
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            if (e.*.drag == RVN_BE_MARQUEE) {
                rvn_be_to_canvas(e, x, y, &e.*.marquee_x1, &e.*.marquee_y1);
                rvn_be_update_marquee(e);
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            id = rvn_be_block_at(e, x, y, &slot);
            if (id != e.*.hot_block) {
                e.*.hot_block = id;
                ext.rvn_widget_invalidate_paint(widget);
            }
            return R_FALSE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            e.*.hot_block = 0;
            ext.rvn_widget_invalidate_paint(widget);
            return R_FALSE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            if (rvn_be_in_palette(e, x) != 0) {
                const most = base.rvn_maxf(0.0, e.*.palette_height - widget.*.rect.h);
                e.*.palette_scroll = base.rvn_clampf(e.*.palette_scroll - event.*.wheel_y * 48.0, 0.0, most);
            } else if ((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_CTRL))) != 0) {
                // zoom around the pointer
                var before_x: f32 = undefined;
                var before_y: f32 = undefined;
                var after_x: f32 = undefined;
                var after_y: f32 = undefined;
                rvn_be_to_canvas(e, x, y, &before_x, &before_y);
                e.*.zoom = base.rvn_clampf(e.*.zoom * (if (event.*.wheel_y > 0.0) @as(f32, 1.12) else @as(f32, 1.0 / 1.12)), 0.3, 3.0);
                draw_h.rvn_spring_set(&e.*.shown_zoom, e.*.zoom);
                rvn_be_to_canvas(e, x, y, &after_x, &after_y);
                e.*.pan_x += before_x - after_x;
                e.*.pan_y += before_y - after_y;
            } else if ((event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_SHIFT))) != 0 or event.*.wheel_x != 0.0) {
                e.*.pan_x -= (if (event.*.wheel_x != 0.0) event.*.wheel_x else event.*.wheel_y) * 48.0 / e.*.zoom;
            } else {
                e.*.pan_y -= event.*.wheel_y * 48.0 / e.*.zoom;
            }
            ext.rvn_widget_invalidate_paint(widget);
            return R_TRUE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            if (e.*.drag != RVN_BE_NONE) return R_TRUE;
            ext.rvn_widget_focus(widget);
            e.*.pointer_x = x;
            e.*.press_x = x;
            e.*.pointer_y = y;
            e.*.press_y = y;
            if (event.*.button == raven.R_MOUSE_MIDDLE or (event.*.button == raven.R_MOUSE_LEFT and (event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_ALT))) != 0)) {
                e.*.drag = RVN_BE_PAN;
                e.*.pan_from_x = e.*.pan_x;
                e.*.pan_from_y = e.*.pan_y;
                ext.rvn_widget_capture_mouse(widget);
                return R_TRUE;
            }
            if (event.*.button == raven.R_MOUSE_RIGHT) {
                // a pan if it moves, the context menu otherwise (on release)
                if (rvn_be_in_palette(e, x) != 0) return R_TRUE;
                rvn_be_finish_field(e);
                e.*.drag = RVN_BE_PRESS_RIGHT;
                e.*.pan_from_x = e.*.pan_x;
                e.*.pan_from_y = e.*.pan_y;
                ext.rvn_widget_capture_mouse(widget);
                return R_TRUE;
            }
            if (event.*.button != raven.R_MOUSE_LEFT) return R_FALSE;
            id = rvn_be_block_at(e, x, y, &slot);
            const b = rvn_be_block(e, id);
            rvn_be_finish_field(e);
            if (b == null) {
                if (rvn_be_in_palette(e, x) != 0) return R_TRUE;
                // a selection rectangle (Ctrl / Shift : added to the selection)
                if (add == 0) rvn_be_clear_selection(e);
                {
                    var i: u32 = 0;
                    while (i < e.*.block_count) : (i += 1) e.*.blocks[i].sel_base = e.*.blocks[i].sel;
                }
                rvn_be_to_canvas(e, x, y, &e.*.marquee_x0, &e.*.marquee_y0);
                e.*.marquee_x1 = e.*.marquee_x0;
                e.*.marquee_y1 = e.*.marquee_y0;
                e.*.drag = RVN_BE_MARQUEE;
                ext.rvn_widget_capture_mouse(widget);
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            e.*.press_block = id;
            e.*.press_slot = slot;
            e.*.drag = if (b.*.palette != 0) RVN_BE_PRESS_PALETTE else (if (slot >= 0) RVN_BE_PRESS_SLOT else RVN_BE_PRESS);
            ext.rvn_widget_capture_mouse(widget);
            return R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            const drag = e.*.drag;
            if (drag == RVN_BE_NONE) return R_FALSE;
            ext.rvn_widget_release_mouse(widget);
            e.*.pointer_x = x;
            e.*.pointer_y = y;
            if (drag == RVN_BE_BLOCKS) {
                rvn_be_end_carry(e, R_FALSE);
            } else if (drag == RVN_BE_GROUP) {
                e.*.drag = RVN_BE_NONE;
                rvn_be_changed(e);
                rvn_be_notify(e, 0);
            } else if (drag == RVN_BE_MARQUEE) {
                e.*.drag = RVN_BE_NONE;
            } else if (drag == RVN_BE_PRESS_RIGHT) {
                e.*.drag = RVN_BE_NONE;
                id = rvn_be_block_at(e, e.*.press_x, e.*.press_y, &slot);
                var b = rvn_be_block(e, id);
                if (b != null and b.*.palette != 0) {
                    b = null;
                    id = 0;
                }
                if (b != null and b.*.sel == 0) {
                    rvn_be_clear_selection(e);
                    rvn_be_select(e, id, R_TRUE);
                }
                ext.rvn_widget_invalidate_paint(widget);
                if (e.*.context_callback) |cb| cb(widget.*.id, id, e.*.press_x, e.*.press_y, e.*.context_user);
                return R_TRUE;
            } else if (drag == RVN_BE_PRESS_SLOT) {
                const b = rvn_be_block(e, e.*.press_block);
                const k = rvn_be_kind_of(e, b);
                e.*.drag = RVN_BE_NONE;
                if (b != null and b.*.sel == 0 and add == 0) {
                    rvn_be_clear_selection(e);
                    rvn_be_select(e, b.*.id, R_TRUE);
                }
                if (k != null and e.*.press_slot >= 0 and e.*.press_slot < k.*.slot_count and k.*.slot_types[idx(e.*.press_slot)] == 'm')
                    rvn_be_open_menu(e, e.*.press_block, e.*.press_slot)
                else
                    rvn_be_open_field(e, e.*.press_block, e.*.press_slot);
            } else if (drag == RVN_BE_PRESS) {
                // a click : selects (Ctrl / Shift : adds or removes), and the application may run the script (Scratch)
                const b = rvn_be_block(e, e.*.press_block);
                const top = rvn_be_top_of(e, b);
                e.*.drag = RVN_BE_NONE;
                if (b != null and add != 0) {
                    rvn_be_select(e, b.*.id, boolInt(b.*.sel == 0));
                } else if (b != null) {
                    rvn_be_clear_selection(e);
                    rvn_be_select(e, b.*.id, R_TRUE);
                }
                if (top != null) {
                    if (e.*.clicked_callback) |cb| cb(widget.*.id, top.*.id, e.*.clicked_user);
                }
            } else {
                e.*.drag = RVN_BE_NONE;
            }
            ext.rvn_widget_invalidate_paint(widget);
            return R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            if (event.*.target != widget.*.id) return R_FALSE;
            if (event.*.key == raven.R_KEY_ESCAPE) {
                if (e.*.drag == RVN_BE_BLOCKS) {
                    rvn_be_end_carry(e, R_TRUE);
                    return R_TRUE;
                }
                if (rvn_be_selection_count(e) > 0) {
                    rvn_be_clear_selection(e);
                    ext.rvn_widget_invalidate_paint(widget);
                    return R_TRUE;
                }
                return R_FALSE;
            }
            if ((event.*.key == raven.R_KEY_DELETE or event.*.key == raven.R_KEY_BACKSPACE) and e.*.drag == RVN_BE_NONE and rvn_be_selection_count(e) > 0) {
                // the selected blocks and what is under them
                rvn_be_delete_selection(e);
                rvn_be_notify(e, 0);
                return R_TRUE;
            }
            if (event.*.key == raven.R_KEY_A and (event.*.modifiers & @as(raven.Ruint, @intCast(raven.R_MOD_CTRL))) != 0 and e.*.drag == RVN_BE_NONE) {
                var i: u32 = 0;
                while (i < e.*.block_count) : (i += 1) {
                    if (e.*.blocks[i].palette == 0 and e.*.blocks[i].dying == 0) e.*.blocks[i].sel = R_TRUE;
                }
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            if (event.*.key == raven.R_KEY_HOME) {
                e.*.pan_x = -20.0;
                e.*.pan_y = -20.0;
                e.*.zoom = 1.0;
                ext.rvn_widget_invalidate_paint(widget);
                return R_TRUE;
            }
            return R_FALSE;
        },
        else => return R_FALSE,
    }
}

fn rvn_block_editor_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(widget));
    var number: f32 = undefined;
    var flag: c_int = undefined;
    if (base.rvn_stricmp(name, "Zoom") == 0) {
        if (widget_h.rvn_parse_float(value, &number) == 0 or number <= 0.0) return R_FALSE;
        e.*.zoom = base.rvn_clampf(number, 0.3, 3.0);
        draw_h.rvn_spring_set(&e.*.shown_zoom, e.*.zoom);
    } else if (base.rvn_stricmp(name, "Palette") == 0) {
        if (widget_h.rvn_parse_bool(value, &flag) == 0) return R_FALSE;
        e.*.palette_hidden = boolInt(flag == 0);
    } else {
        return R_FALSE;
    }
    ext.rvn_widget_invalidate_paint(widget);
    return R_TRUE;
}

export const rvn_class_block_editor: widget_h.rvn_widget_class_t = .{
    .@"type" = raven.R_WIDGET_BLOCK_EDITOR,
    .name = "BlockEditor",
    .size = @sizeOf(rvn_block_editor_t),
    .flags = widget_h.RVN_CF_NO_CHILDREN | widget_h.RVN_CF_FOCUSABLE | widget_h.RVN_CF_CLIP | widget_h.RVN_CF_NO_MIRROR,
    .init = &rvn_block_editor_init,
    .destroy = &rvn_block_editor_destroy,
    .measure = &rvn_block_editor_measure,
    .arrange = &rvn_block_editor_arrange,
    .paint = &rvn_block_editor_paint,
    .paint_overlay = null,
    .event = &rvn_block_editor_event,
    .set_attribute = &rvn_block_editor_set_attribute,
    .child_active = null,
    .child_at = null,
    .children_changed = null,
    .xml_child = &rvn_block_editor_xml_child,
    .popup_closed = null,
    .window_drag_at = null,
};

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

/// RVN_BLOCK_EDITOR(variable, id, result): the editor of a widget id, NULL when it is not one.
fn rvn_be_block_checked(e: [*c]rvn_block_editor_t, id: c_int, function: [*c]const u8) [*c]rvn_be_block_t {
    const b = rvn_be_block(e, id);
    if (b == null or b.*.palette != 0 or b.*.dying != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: the block editor has no block %d", function, id);
        return null;
    }
    return b;
}

export fn Rblock_editor_create() raven.Rid {
    if (ctx_h.rvn_api_check("Rblock_editor_create") == 0) return raven.R_INVALID_ID;
    const widget = widget_h.rvn_widget_create(raven.R_WIDGET_BLOCK_EDITOR);
    return if (widget != null) widget.*.id else raven.R_INVALID_ID;
}

export fn Rblock_editor_add_kind(id: raven.Rid, name: [*c]const u8, label: [*c]const u8, shape: raven.RBlockShape, category: [*c]const u8) c_int {
    var i: u32 = undefined;
    const e = rvn_be_check(id, "Rblock_editor_add_kind");
    if (e == null) return -1;
    if (name == null or name[0] == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rblock_editor_add_kind: a kind needs a name");
        return -1;
    }
    if (rvn_be_find_kind(e, name) >= 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rblock_editor_add_kind: the kind \"%s\" already exists", name);
        return -1;
    }
    base.RVN_ARRAY_RESERVE(&e.*.kinds, &e.*.kind_cap, e.*.kind_count + 1);
    const index: c_int = @intCast(e.*.kind_count);
    const k = &e.*.kinds[idx(e.*.kind_count)];
    e.*.kind_count += 1;
    k.* = std.mem.zeroes(rvn_be_kind_t);
    k.*.name = base.rvn_strdup(name);
    k.*.label = base.rvn_strdup(if (label != null) label else name);
    k.*.category = base.rvn_strdup(if (category != null) category else "");
    const s: c_int = @intCast(shape);
    k.*.shape = if (s >= raven.R_BLOCK_STATEMENT and s <= raven.R_BLOCK_BOOLEAN) shape else raven.R_BLOCK_STATEMENT;
    rvn_be_parse_label(k);
    // its block in the palette, after the others of its category
    {
        const p = rvn_be_new_block(e, index, R_TRUE);
        const copy = p.*;
        var at = e.*.block_count - 1;
        i = 0;
        while (i + 1 < e.*.block_count) : (i += 1) {
            const o = &e.*.blocks[i];
            if (o.*.palette != 0 and libc.strcmp(e.*.kinds[idx(o.*.kind)].category, k.*.category) == 0) at = i + 1;
        }
        if (at < e.*.block_count - 1) {
            _ = libc.memmove(@ptrCast(&e.*.blocks[idx(at + 1)]), @ptrCast(&e.*.blocks[idx(at)]), @sizeOf(rvn_be_block_t) * (e.*.block_count - 1 - at));
            e.*.blocks[idx(at)] = copy;
        }
    }
    rvn_be_changed(e);
    return index;
}

export fn Rblock_editor_set_category_color(id: raven.Rid, category: [*c]const u8, r: f32, g: f32, b: f32) void {
    const e = rvn_be_check(id, "Rblock_editor_set_category_color");
    if (e == null) return;
    var i: u32 = 0;
    while (i < e.*.category_count) : (i += 1) {
        if (libc.strcmp(e.*.categories[i].name, if (category != null) category else "") == 0) break;
    }
    if (i == e.*.category_count) {
        base.RVN_ARRAY_RESERVE(&e.*.categories, &e.*.category_cap, e.*.category_count + 1);
        e.*.categories[i] = std.mem.zeroes(rvn_be_category_t);
        e.*.categories[i].name = base.rvn_strdup(if (category != null) category else "");
        e.*.category_count += 1;
    }
    e.*.categories[i].color = base.rvn_rgba(r, g, b, 1.0);
    e.*.categories[i].has_color = R_TRUE;
    ext.rvn_widget_invalidate_paint(&e.*.base);
}

export fn Rblock_editor_set_palette_visible(id: raven.Rid, visible: c_int) void {
    const e = rvn_be_check(id, "Rblock_editor_set_palette_visible");
    if (e == null) return;
    e.*.palette_hidden = boolInt(visible == 0);
    rvn_be_changed(e);
}

export fn Rblock_editor_add_block(id: raven.Rid, kind: [*c]const u8, x: f32, y: f32) c_int {
    const e = rvn_be_check(id, "Rblock_editor_add_block");
    if (e == null) return 0;
    const k = rvn_be_find_kind(e, kind);
    if (k < 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rblock_editor_add_block: no kind \"%s\"", if (kind != null) kind else @as([*c]const u8, "(null)"));
        return 0;
    }
    const b = rvn_be_new_block(e, k, R_FALSE);
    b.*.x = x;
    b.*.y = y;
    rvn_be_order_add(e, b.*.id);
    rvn_be_changed(e);
    return b.*.id;
}

export fn Rblock_editor_remove_block(id: raven.Rid, block: c_int) void {
    const e = rvn_be_check(id, "Rblock_editor_remove_block");
    if (e == null) return;
    if (rvn_be_block_checked(e, block, "Rblock_editor_remove_block") == null) return;
    rvn_be_delete_script(e, block, R_FALSE);
    rvn_be_purge(e, R_FALSE);
}

export fn Rblock_editor_clear(id: raven.Rid) void {
    const e = rvn_be_check(id, "Rblock_editor_clear");
    if (e == null) return;
    rvn_be_close_field(e);
    e.*.order_count = 0;
    e.*.drawn_count = 0;
    e.*.drag = RVN_BE_NONE;
    e.*.carried = 0;
    e.*.selected = 0;
    e.*.hot_block = 0;
    rvn_be_purge(e, R_TRUE);
    rvn_be_changed(e);
}

export fn Rblock_editor_attach(id: raven.Rid, block: c_int, target: c_int, place: raven.RBlockPlace, index: c_int) c_int {
    const e = rvn_be_check(id, "Rblock_editor_attach");
    if (e == null) return R_FALSE;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_attach");
    const t = if (b != null) rvn_be_block_checked(e, target, "Rblock_editor_attach") else null;
    if (b == null or t == null) return R_FALSE;
    return rvn_be_attach(e, b, t, place, index);
}

export fn Rblock_editor_detach(id: raven.Rid, block: c_int, x: f32, y: f32) void {
    const e = rvn_be_check(id, "Rblock_editor_detach");
    if (e == null) return;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_detach");
    if (b == null) return;
    rvn_be_make_top(e, b, x, y);
    rvn_be_changed(e);
}

export fn Rblock_editor_get_script_count(id: raven.Rid) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_script_count");
    if (e == null) return 0;
    return @intCast(e.*.order_count);
}

export fn Rblock_editor_get_script(id: raven.Rid, index: c_int) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_script");
    if (e == null) return 0;
    return if (index >= 0 and @as(u32, @intCast(index)) < e.*.order_count) e.*.order[idx(index)] else 0;
}

export fn Rblock_editor_get_kind(id: raven.Rid, block: c_int) [*c]const u8 {
    const e = rvn_be_check(id, "Rblock_editor_get_kind");
    if (e == null) return null;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_kind");
    return if (b != null) e.*.kinds[idx(b.*.kind)].name else null;
}

export fn Rblock_editor_get_next(id: raven.Rid, block: c_int) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_next");
    if (e == null) return 0;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_next");
    return if (b != null) b.*.next else 0;
}

export fn Rblock_editor_get_body(id: raven.Rid, block: c_int, mouth: c_int) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_body");
    if (e == null) return 0;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_body");
    return if (b != null and mouth >= 0 and mouth < RVN_BE_MAX_MOUTHS) b.*.body[idx(mouth)] else 0;
}

export fn Rblock_editor_get_input(id: raven.Rid, block: c_int, slot: c_int) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_input");
    if (e == null) return 0;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_input");
    return if (b != null and slot >= 0 and slot < RVN_BE_MAX_SLOTS) b.*.input[idx(slot)] else 0;
}

export fn Rblock_editor_get_slot_count(id: raven.Rid, block: c_int) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_slot_count");
    if (e == null) return 0;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_slot_count");
    return if (b != null) e.*.kinds[idx(b.*.kind)].slot_count else 0;
}

export fn Rblock_editor_get_mouth_count(id: raven.Rid, block: c_int) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_mouth_count");
    if (e == null) return 0;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_mouth_count");
    return if (b != null and e.*.kinds[idx(b.*.kind)].shape == raven.R_BLOCK_C) e.*.kinds[idx(b.*.kind)].sections else 0;
}

export fn Rblock_editor_get_value(id: raven.Rid, block: c_int, slot: c_int) [*c]const u8 {
    const e = rvn_be_check(id, "Rblock_editor_get_value");
    if (e == null) return null;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_value");
    return if (b != null and slot >= 0 and slot < e.*.kinds[idx(b.*.kind)].slot_count) (if (b.*.value[idx(slot)] != null) b.*.value[idx(slot)] else "") else null;
}

export fn Rblock_editor_set_value(id: raven.Rid, block: c_int, slot: c_int, value: [*c]const u8) void {
    const e = rvn_be_check(id, "Rblock_editor_set_value");
    if (e == null) return;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_set_value");
    if (b == null or slot < 0 or slot >= e.*.kinds[idx(b.*.kind)].slot_count) return;
    _ = base.rvn_str_set(&b.*.value[idx(slot)], if (value != null) value else "");
    rvn_be_changed(e);
}

export fn Rblock_editor_get_parent(id: raven.Rid, block: c_int, place: [*c]raven.RBlockPlace, index: [*c]c_int) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_parent");
    if (e == null) return 0;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_parent");
    if (b == null) return 0;
    if (place != null) place.* = b.*.place;
    if (index != null) index.* = b.*.index;
    return b.*.parent;
}

export fn Rblock_editor_get_position(id: raven.Rid, block: c_int, x: [*c]f32, y: [*c]f32) void {
    const e = rvn_be_check(id, "Rblock_editor_get_position");
    if (e == null) return;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_get_position");
    if (x != null) x.* = if (b != null) (if (b.*.parent != 0) b.*.lx else b.*.x) else 0.0;
    if (y != null) y.* = if (b != null) (if (b.*.parent != 0) b.*.ly else b.*.y) else 0.0;
}

export fn Rblock_editor_set_block_glow(id: raven.Rid, block: c_int, glow: c_int) void {
    const e = rvn_be_check(id, "Rblock_editor_set_block_glow");
    if (e == null) return;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_set_block_glow");
    if (b == null or boolInt(b.*.glow != 0) == boolInt(glow != 0)) return;
    b.*.glow = boolInt(glow != 0);
    ext.rvn_widget_invalidate_paint(&e.*.base);
}

export fn Rblock_editor_set_changed_callback(id: raven.Rid, callback: raven.RBlockEditorCallback, user_data: ?*anyopaque) void {
    const e = rvn_be_check(id, "Rblock_editor_set_changed_callback");
    if (e == null) return;
    e.*.changed_callback = callback;
    e.*.changed_user = user_data;
}

export fn Rblock_editor_set_clicked_callback(id: raven.Rid, callback: raven.RBlockEditorCallback, user_data: ?*anyopaque) void {
    const e = rvn_be_check(id, "Rblock_editor_set_clicked_callback");
    if (e == null) return;
    e.*.clicked_callback = callback;
    e.*.clicked_user = user_data;
}

export fn Rblock_editor_set_context_callback(id: raven.Rid, callback: raven.RBlockEditorContextCallback, user_data: ?*anyopaque) void {
    const e = rvn_be_check(id, "Rblock_editor_set_context_callback");
    if (e == null) return;
    e.*.context_callback = callback;
    e.*.context_user = user_data;
}

fn rvn_be_kind_named(e: [*c]rvn_block_editor_t, name: [*c]const u8, function: [*c]const u8) [*c]rvn_be_kind_t {
    const k = rvn_be_find_kind(e, name);
    if (k < 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: the block editor has no kind \"%s\"", function, if (name != null) name else @as([*c]const u8, ""));
        return null;
    }
    return &e.*.kinds[idx(k)];
}

export fn Rblock_editor_set_slot_options(id: raven.Rid, kind: [*c]const u8, slot: c_int, options: [*c]const u8) void {
    const e = rvn_be_check(id, "Rblock_editor_set_slot_options");
    if (e == null) return;
    const k = rvn_be_kind_named(e, kind, "Rblock_editor_set_slot_options");
    if (k == null or slot < 0 or slot >= RVN_BE_MAX_SLOTS) return;
    _ = base.rvn_str_set(&k.*.options[idx(slot)], if (options != null) options else "");
}

export fn Rblock_editor_set_kind_visible(id: raven.Rid, kind: [*c]const u8, visible: c_int) void {
    const e = rvn_be_check(id, "Rblock_editor_set_kind_visible");
    if (e == null) return;
    const k = rvn_be_kind_named(e, kind, "Rblock_editor_set_kind_visible");
    if (k == null or boolInt(k.*.hidden != 0) == boolInt(visible == 0)) return;
    k.*.hidden = boolInt(visible == 0);
    rvn_be_changed(e);
}

export fn Rblock_editor_set_kind_label(id: raven.Rid, kind: [*c]const u8, label: [*c]const u8) c_int {
    const e = rvn_be_check(id, "Rblock_editor_set_kind_label");
    if (e == null) return R_FALSE;
    const k = rvn_be_kind_named(e, kind, "Rblock_editor_set_kind_label");
    if (k == null) return R_FALSE;
    if (k.*.label != null and label != null and libc.strcmp(k.*.label, label) == 0) return R_TRUE;
    {
        var i: u32 = 0;
        while (i < k.*.token_count) : (i += 1) base.rvn_free(k.*.tokens[i].text);
    }
    base.rvn_free(k.*.tokens);
    k.*.tokens = null;
    k.*.token_count = 0;
    var s: c_int = 0;
    while (s < RVN_BE_MAX_SLOTS) : (s += 1) {
        base.rvn_free(k.*.defaults[idx(s)]);
        k.*.defaults[idx(s)] = null;
    }
    k.*.slot_count = 0;
    k.*.sections = 1;
    _ = base.rvn_str_set(&k.*.label, if (label != null) label else k.*.name);
    rvn_be_parse_label(k);
    const index: c_int = @intCast((@intFromPtr(k) - @intFromPtr(e.*.kinds)) / @sizeOf(rvn_be_kind_t));
    // the blocks of that kind : new slots take their default, the values of the slots gone jump out
    {
        var i: u32 = 0;
        while (i < e.*.block_count) : (i += 1) {
            var b = &e.*.blocks[i];
            if (b.*.kind != index) continue;
            s = 0;
            while (s < RVN_BE_MAX_SLOTS) : (s += 1) {
                if (s < k.*.slot_count) {
                    if (b.*.value[idx(s)] == null or b.*.palette != 0) _ = base.rvn_str_set(&b.*.value[idx(s)], if (k.*.defaults[idx(s)] != null) k.*.defaults[idx(s)] else "");
                } else {
                    base.rvn_free(b.*.value[idx(s)]);
                    b.*.value[idx(s)] = null;
                    if (b.*.input[idx(s)] != 0) {
                        const input = rvn_be_block(e, b.*.input[idx(s)]);
                        if (input != null) rvn_be_make_top(e, input, b.*.lx + b.*.w + 20.0, b.*.ly);
                        b = &e.*.blocks[i];
                        b.*.input[idx(s)] = 0;
                    }
                }
            }
        }
    }
    rvn_be_changed(e);
    return R_TRUE;
}

export fn Rblock_editor_set_block_deletable(id: raven.Rid, block: c_int, deletable: c_int) void {
    const e = rvn_be_check(id, "Rblock_editor_set_block_deletable");
    if (e == null) return;
    const b = rvn_be_block_checked(e, block, "Rblock_editor_set_block_deletable");
    if (b != null) b.*.locked = boolInt(deletable == 0);
}

export fn Rblock_editor_get_selection_count(id: raven.Rid) c_int {
    const e = rvn_be_check(id, "Rblock_editor_get_selection_count");
    if (e == null) return 0;
    return rvn_be_selection_count(e);
}

export fn Rblock_editor_get_selected(id: raven.Rid, index: c_int) c_int {
    var n: c_int = 0;
    const e = rvn_be_check(id, "Rblock_editor_get_selected");
    if (e == null) return 0;
    var i: u32 = 0;
    while (i < e.*.block_count) : (i += 1) {
        const b = &e.*.blocks[i];
        if (b.*.sel == 0 or b.*.palette != 0 or b.*.dying != 0) continue;
        if (n == index) return b.*.id;
        n += 1;
    }
    return 0;
}

export fn Rblock_editor_select(id: raven.Rid, block: c_int, add: c_int) void {
    const e = rvn_be_check(id, "Rblock_editor_select");
    if (e == null) return;
    if (add == 0) rvn_be_clear_selection(e);
    if (block > 0) rvn_be_select(e, block, R_TRUE);
    ext.rvn_widget_invalidate_paint(&e.*.base);
}

export fn Rblock_editor_get_view(id: raven.Rid, x: [*c]f32, y: [*c]f32, zoom: [*c]f32) void {
    const e = rvn_be_check(id, "Rblock_editor_get_view");
    if (e == null) return;
    if (x != null) x.* = e.*.pan_x;
    if (y != null) y.* = e.*.pan_y;
    if (zoom != null) zoom.* = e.*.zoom;
}

export fn Rblock_editor_set_view(id: raven.Rid, x: f32, y: f32, zoom: f32) void {
    const e = rvn_be_check(id, "Rblock_editor_set_view");
    if (e == null) return;
    e.*.pan_x = x;
    e.*.pan_y = y;
    if (zoom > 0.0) {
        e.*.zoom = base.rvn_clampf(zoom, 0.3, 3.0);
        draw_h.rvn_spring_set(&e.*.shown_zoom, e.*.zoom);
    }
    ext.rvn_widget_invalidate_paint(&e.*.base);
}

// ---------------------------------------------------------------------------
//  Save / load : (script X Y (block "kind" ("v0" "v1") (in 0 (block ...)) (body 0 (block ...) (block ...))) (block ...))
// ---------------------------------------------------------------------------

fn rvn_be_quote(out: [*c]base.rvn_text_t, text_in: [*c]const u8) void {
    var c: [*c]const u8 = if (text_in != null) text_in else "";
    base.rvn_text_add(out, "\"");
    while (c[0] != 0) : (c += 1) {
        if (c[0] == '"' or c[0] == '\\') base.rvn_text_append(out, "\\", 1);
        if (c[0] == '\n') {
            base.rvn_text_add(out, "\\n");
            continue;
        }
        base.rvn_text_append(out, c, 1);
    }
    base.rvn_text_add(out, "\"");
}

fn rvn_be_save_chain(e: [*c]rvn_block_editor_t, out: [*c]base.rvn_text_t, first: c_int, depth: c_int) void {
    var b = rvn_be_block(e, first);
    var guard: c_int = 0;
    while (b != null and guard < 100000) {
        guard += 1;
        if (b.*.dying == 0) rvn_be_save_block(e, out, b, depth);
        b = rvn_be_block(e, b.*.next);
    }
}

fn rvn_be_indent(out: [*c]base.rvn_text_t, depth: c_int) void {
    base.rvn_text_add(out, "\n");
    var i: c_int = 0;
    while (i < depth) : (i += 1) base.rvn_text_add(out, "  ");
}

fn rvn_be_save_block(e: [*c]rvn_block_editor_t, out: [*c]base.rvn_text_t, b: [*c]const rvn_be_block_t, depth: c_int) void {
    const k = &e.*.kinds[idx(b.*.kind)];
    rvn_be_indent(out, depth);
    base.rvn_text_add(out, "(block ");
    rvn_be_quote(out, k.*.name);
    base.rvn_text_add(out, " (");
    var s: c_int = 0;
    while (s < k.*.slot_count) : (s += 1) {
        if (s != 0) base.rvn_text_add(out, " ");
        rvn_be_quote(out, b.*.value[idx(s)]);
    }
    base.rvn_text_add(out, ")");
    s = 0;
    while (s < k.*.slot_count) : (s += 1) {
        const input = rvn_be_block(e, b.*.input[idx(s)]);
        if (input == null or input.*.dying != 0) continue;
        rvn_be_indent(out, depth + 1);
        base.rvn_text_printf(out, "(in %d", @as(c_int, s));
        rvn_be_save_block(e, out, input, depth + 2);
        base.rvn_text_add(out, ")");
    }
    if (k.*.shape == raven.R_BLOCK_C) {
        s = 0;
        while (s < k.*.sections) : (s += 1) {
            if (b.*.body[idx(s)] == 0) continue;
            rvn_be_indent(out, depth + 1);
            base.rvn_text_printf(out, "(body %d", @as(c_int, s));
            rvn_be_save_chain(e, out, b.*.body[idx(s)], depth + 2);
            base.rvn_text_add(out, ")");
        }
    }
    base.rvn_text_add(out, ")");
}

export fn Rblock_editor_save(id: raven.Rid) [*c]const u8 {
    const e = rvn_be_check(id, "Rblock_editor_save");
    if (e == null) return "";
    e.*.saved.length = 0;
    if (e.*.saved.data != null) e.*.saved.data[0] = 0;
    var i: u32 = 0;
    while (i < e.*.order_count) : (i += 1) {
        const top = rvn_be_block(e, e.*.order[i]);
        if (top == null or top.*.dying != 0 or top.*.id == e.*.carried) continue;
        base.rvn_text_printf(&e.*.saved, "(script %g %g", @as(f64, top.*.x), @as(f64, top.*.y));
        rvn_be_save_chain(e, &e.*.saved, top.*.id, 1);
        base.rvn_text_add(&e.*.saved, ")\n");
    }
    return if (e.*.saved.data != null) e.*.saved.data else "";
}

const rvn_be_reader_t = extern struct {
    c: [*c]const u8,
    ok: c_int,
};

fn rvn_be_skip(r: [*c]rvn_be_reader_t) void {
    while (r.*.c[0] == ' ' or r.*.c[0] == '\t' or r.*.c[0] == '\n' or r.*.c[0] == '\r') r.*.c += 1;
}

fn rvn_be_expect(r: [*c]rvn_be_reader_t, ch: u8) c_int {
    rvn_be_skip(r);
    if (r.*.c[0] != ch) {
        r.*.ok = R_FALSE;
        return R_FALSE;
    }
    r.*.c += 1;
    return R_TRUE;
}

fn rvn_be_word(r: [*c]rvn_be_reader_t, word: [*c]const u8) c_int {
    const n = libc.strlen(word);
    rvn_be_skip(r);
    if (libc.strncmp(r.*.c, word, n) != 0) return R_FALSE;
    r.*.c += n;
    return R_TRUE;
}

fn rvn_be_string(r: [*c]rvn_be_reader_t) [*c]u8 {
    var t = std.mem.zeroes(base.rvn_text_t);
    rvn_be_skip(r);
    if (r.*.c[0] != '"') {
        r.*.ok = R_FALSE;
        return null;
    }
    r.*.c += 1;
    while (r.*.c[0] != 0 and r.*.c[0] != '"') {
        if (r.*.c[0] == '\\' and r.*.c[1] != 0) {
            r.*.c += 1;
            if (r.*.c[0] == 'n') {
                base.rvn_text_add(&t, "\n");
                r.*.c += 1;
                continue;
            }
        }
        base.rvn_text_append(&t, r.*.c, 1);
        r.*.c += 1;
    }
    if (r.*.c[0] != '"') {
        r.*.ok = R_FALSE;
        base.rvn_free(t.data);
        return null;
    }
    r.*.c += 1;
    return if (t.data != null) t.data else base.rvn_strdup("");
}

fn rvn_be_number(r: [*c]rvn_be_reader_t) f64 {
    var end: [*c]u8 = null;
    rvn_be_skip(r);
    const v = libc.strtod(r.*.c, &end);
    if (end == r.*.c) {
        r.*.ok = R_FALSE;
        return 0.0;
    }
    r.*.c = end;
    return v;
}

/// (block "kind" (values) (in i ...) (body i ...)) : returns the block, 0 on an error.
fn rvn_be_read_block(e: [*c]rvn_block_editor_t, r: [*c]rvn_be_reader_t) c_int {
    var s: c_int = 0;
    if (rvn_be_expect(r, '(') == 0 or rvn_be_word(r, "block") == 0) {
        r.*.ok = R_FALSE;
        return 0;
    }
    const kind_name = rvn_be_string(r);
    if (r.*.ok == 0) return 0;
    const kind = rvn_be_find_kind(e, kind_name);
    if (kind < 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_WARNING, "Rblock_editor_load: no kind \"%s\"", kind_name);
        base.rvn_free(kind_name);
        r.*.ok = R_FALSE;
        return 0;
    }
    base.rvn_free(kind_name);
    var b = rvn_be_new_block(e, kind, R_FALSE);
    const id = b.*.id;
    if (rvn_be_expect(r, '(') == 0) return 0;
    while (true) {
        rvn_be_skip(r);
        if (r.*.c[0] == ')') {
            r.*.c += 1;
            break;
        }
        const value = rvn_be_string(r);
        if (r.*.ok == 0) return 0;
        b = rvn_be_block(e, id);
        if (s < e.*.kinds[idx(kind)].slot_count) {
            base.rvn_free(b.*.value[idx(s)]);
            b.*.value[idx(s)] = value;
        } else {
            base.rvn_free(value);
        }
        s += 1;
    }
    while (true) {
        rvn_be_skip(r);
        if (r.*.c[0] == ')') {
            r.*.c += 1;
            return id;
        }
        if (rvn_be_expect(r, '(') == 0) return 0;
        if (rvn_be_word(r, "in") != 0) {
            const slot: c_int = @intFromFloat(rvn_be_number(r));
            const child: c_int = if (r.*.ok != 0) rvn_be_read_block(e, r) else 0;
            const p = rvn_be_block(e, id);
            const c = rvn_be_block(e, child);
            if (child == 0 or rvn_be_expect(r, ')') == 0) return 0;
            if (p != null and c != null and slot >= 0 and slot < RVN_BE_MAX_SLOTS) {
                p.*.input[idx(slot)] = child;
                c.*.parent = id;
                c.*.place = raven.R_BLOCK_INPUT;
                c.*.index = slot;
            }
        } else if (rvn_be_word(r, "body") != 0) {
            const mouth: c_int = @intFromFloat(rvn_be_number(r));
            var previous: c_int = 0;
            while (true) {
                rvn_be_skip(r);
                if (r.*.c[0] == ')') {
                    r.*.c += 1;
                    break;
                }
                const child = rvn_be_read_block(e, r);
                if (child == 0) return 0;
                if (mouth >= 0 and mouth < RVN_BE_MAX_MOUTHS) {
                    const c = rvn_be_block(e, child);
                    if (previous == 0) {
                        const p = rvn_be_block(e, id);
                        p.*.body[idx(mouth)] = child;
                        c.*.parent = id;
                        c.*.place = raven.R_BLOCK_BODY;
                        c.*.index = mouth;
                    } else {
                        const p = rvn_be_block(e, previous);
                        p.*.next = child;
                        c.*.parent = previous;
                        c.*.place = raven.R_BLOCK_NEXT;
                        c.*.index = 0;
                    }
                }
                previous = child;
            }
        } else {
            r.*.ok = R_FALSE;
            return 0;
        }
    }
}

export fn Rblock_editor_load(id: raven.Rid, text: [*c]const u8) c_int {
    const e = rvn_be_check(id, "Rblock_editor_load");
    if (e == null) return R_FALSE;
    var r: rvn_be_reader_t = undefined;
    _ = Rblock_editor_clear(id);
    r.c = if (text != null) text else "";
    r.ok = R_TRUE;
    while (true) {
        var previous: c_int = 0;
        var x: f32 = undefined;
        var y: f32 = undefined;
        rvn_be_skip(&r);
        if (r.c[0] == 0) break;
        if (rvn_be_expect(&r, '(') == 0 or rvn_be_word(&r, "script") == 0) {
            r.ok = R_FALSE;
            break;
        }
        x = @floatCast(rvn_be_number(&r));
        y = @floatCast(rvn_be_number(&r));
        if (r.ok == 0) break;
        while (true) {
            rvn_be_skip(&r);
            if (r.c[0] == ')') {
                r.c += 1;
                break;
            }
            const block = rvn_be_read_block(e, &r);
            if (block == 0) break;
            if (previous == 0) {
                const b = rvn_be_block(e, block);
                b.*.x = x;
                b.*.y = y;
                rvn_be_order_add(e, block);
            } else {
                const p = rvn_be_block(e, previous);
                const c = rvn_be_block(e, block);
                p.*.next = block;
                c.*.parent = previous;
                c.*.place = raven.R_BLOCK_NEXT;
                c.*.index = 0;
            }
            previous = block;
        }
        if (r.ok == 0) break;
    }
    rvn_be_changed(e);
    if (r.ok == 0) base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_WARNING, "Rblock_editor_load: the text is not a block program (what was read is kept)");
    return r.ok;
}

// ---------------------------------------------------------------------------
//  XML
// ---------------------------------------------------------------------------

fn rvn_be_parse_shape(text: [*c]const u8) raven.RBlockShape {
    if (text == null) return raven.R_BLOCK_STATEMENT;
    if (base.rvn_stricmp(text, "Hat") == 0) return raven.R_BLOCK_HAT;
    if (base.rvn_stricmp(text, "Cap") == 0) return raven.R_BLOCK_CAP;
    if (base.rvn_stricmp(text, "C") == 0 or base.rvn_stricmp(text, "Wrap") == 0) return raven.R_BLOCK_C;
    if (base.rvn_stricmp(text, "Reporter") == 0 or base.rvn_stricmp(text, "Value") == 0) return raven.R_BLOCK_REPORTER;
    if (base.rvn_stricmp(text, "Boolean") == 0 or base.rvn_stricmp(text, "Condition") == 0) return raven.R_BLOCK_BOOLEAN;
    return raven.R_BLOCK_STATEMENT;
}

/// <Kind Name="move" Label="move %n{10} steps" Shape="Statement" Category="Motion"/>, <Category Name="Motion" Color="#4C97FF"/>
fn rvn_block_editor_xml_child(widget: [*c]widget_h.rvn_widget_t, element: [*c]const xml_h.rvn_xml_node_t) callconv(.c) c_int {
    const tag = element.*.name;
    if (base.rvn_stricmp(tag, "Kind") == 0 or base.rvn_stricmp(tag, "Block") == 0) {
        _ = Rblock_editor_add_kind(widget.*.id, xml_h.rvn_xml_attribute(element, "Name"), xml_h.rvn_xml_attribute(element, "Label"), rvn_be_parse_shape(xml_h.rvn_xml_attribute(element, "Shape")), xml_h.rvn_xml_attribute(element, "Category"));
        return R_TRUE;
    }
    if (base.rvn_stricmp(tag, "Category") == 0) {
        var color: base.rvn_color_t = undefined;
        const text = xml_h.rvn_xml_attribute(element, "Color");
        const name = xml_h.rvn_xml_attribute(element, "Name");
        const e: [*c]rvn_block_editor_t = @ptrCast(@alignCast(widget));
        if (text == null or widget_h.rvn_parse_color(text, &color) == 0) return R_TRUE;
        var i: u32 = 0;
        while (i < e.*.category_count) : (i += 1) {
            if (libc.strcmp(e.*.categories[i].name, if (name != null) name else "") == 0) break;
        }
        if (i == e.*.category_count) {
            base.RVN_ARRAY_RESERVE(&e.*.categories, &e.*.category_cap, e.*.category_count + 1);
            e.*.categories[i] = std.mem.zeroes(rvn_be_category_t);
            e.*.categories[i].name = base.rvn_strdup(if (name != null) name else "");
            e.*.category_count += 1;
        }
        e.*.categories[i].color = color;
        e.*.categories[i].has_color = R_TRUE;
        return R_TRUE;
    }
    return R_FALSE;
}
