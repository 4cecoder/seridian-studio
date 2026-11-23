// Translated to Zig from vendor/raven/src/render/font.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/font.c
// Font objects, code point map, glyph raster cache, atlas packing and the
// text measuring / drawing loops.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const context = @import("../core/context_h.zig");
const lfmap = @import("../core/lfmap_h.zig");
const thread = @import("../core/thread_h.zig");
const handle = @import("../core/handle_h.zig");
const libc = @import("../sys/libc.zig");
const font_h = @import("font_h.zig");
const draw = @import("draw_h.zig");
const bidi = @import("bidi_h.zig");
const renderer = @import("renderer_h.zig");

const RVN_ATLAS_SIZE = 1024;
const RVN_ATLAS_MAX_PAGES = 64;
const RVN_TAB_SPACES = 4;

// ---------------------------------------------------------------------------
//  Data
//
//  Two caches are read on every character drawn, possibly by several paint
//  jobs at once, and written only when a new character or size shows up:
//    - per font, code point -> glyph (which font of the fallback chain has
//      it, and its advance);
//    - globally, (font, glyph, pixel size) -> rectangle in the atlas.
//  Both are lock-free maps (core/lfmap.h): reading never takes a lock, so
//  text does not serialize the paint jobs. Misses go through one mutex.
// ---------------------------------------------------------------------------

/// Result of resolving a code point for one font, fallbacks included.
const rvn_cmap_entry_t = extern struct {
    /// Glyph index, or -1 for characters that draw nothing.
    glyph: c_int,
    /// Font providing the glyph: the font itself or one of its fallbacks.
    font: [*c]rvn_font_t,
    /// Advance as a fraction of the em size.
    advance: f32,
};

/// One rasterized glyph in the atlas.
const rvn_glyph_t = extern struct {
    page: u16,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    offset_x: i16,
    offset_y: i16,
};

const rvn_shelf_t = extern struct {
    y: u16,
    height: u16,
    x: u16,
};

const rvn_atlas_page_t = extern struct {
    pixels: [*c]u8,
    shelves: [*c]rvn_shelf_t,
    shelf_count: u32,
    shelf_cap: u32,
    next_y: u32,
    dirty: c_int,
    dirty_x0: c_int,
    dirty_y0: c_int,
    dirty_x1: c_int,
    dirty_y1: c_int,
    /// GPU texture, created by rvn_fonts_flush.
    texture: raven.Rid,
};

const rvn_font_t = extern struct {
    id: raven.Rid,
    data: [*c]u8,
    owns_data: c_int,
    ttf: ?*font_h.rvn_ttf_t,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    fallback: raven.Rid,
    /// Unique for the life of the process: part of the glyph cache key.
    serial: u32,
    /// A styled view of another font: the same glyphs drawn thicker and / or
    /// slanted, with the same advances. NULL for a font of its own. A view
    /// shares the TrueType data, the serial and the code point map of its font.
    base: [*c]rvn_font_t,
    /// RVN_FONT_BOLD | RVN_FONT_ITALIC, for a styled view.
    style: u32,
    /// The fonts used for the bold, italic and bold italic of this one: given by the application, or views made on first use.
    variants: [3]raven.Rid,
    variant_owned: [3]u8,
    /// Direct table for ASCII, built with the font.
    ascii: [128]rvn_cmap_entry_t,
    /// Every other code point, resolved on first use.
    cmap: lfmap.rvn_lfmap_t,
};

const rvn_font_system_slot_t = extern struct {
    path: [*c]const u8,
    font: [*c]rvn_font_t,
    failed: c_int,
};

const FontsState = extern struct {
    /// Serializes the writers of the maps and of the atlas.
    mutex: thread.rvn_mutex_t,
    glyphs: lfmap.rvn_lfmap_t,
    pages: [RVN_ATLAS_MAX_PAGES]rvn_atlas_page_t,
    /// Read by the paint jobs to size nothing: only written under the mutex.
    page_count: u32,
    next_serial: u32,
    initialized: c_int,
    // fonts of the system, opened when a character needs them (render/font_system.c)
    system: [64]rvn_font_system_slot_t,
    system_count: c_int,
};

var g_fonts: FontsState = std.mem.zeroes(FontsState);

// ---------------------------------------------------------------------------
//  Typed views of the handle pool and of the allocator (font structs are
//  8-aligned; the pool and the allocator return untyped memory).
// ---------------------------------------------------------------------------

fn poolFont(id: raven.Rid) [*c]rvn_font_t {
    return @ptrCast(@alignCast(handle.rvn_pool_get(&context.g_rvn.fonts, id)));
}

fn poolFontAt(index: u32) [*c]rvn_font_t {
    return @ptrCast(@alignCast(handle.rvn_pool_at(&context.g_rvn.fonts, index)));
}

fn allocFont() [*c]rvn_font_t {
    return @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_font_t))));
}

/// (uint16_t)v for a C int: keeps the low 16 bits, like the C cast.
inline fn u16FromInt(v: c_int) u16 {
    return @truncate(@as(u32, @bitCast(v)));
}

// ---------------------------------------------------------------------------
//  Atlas (caller holds the mutex)
// ---------------------------------------------------------------------------

fn rvn_atlas_add_page() [*c]rvn_atlas_page_t {
    if (g_fonts.page_count >= RVN_ATLAS_MAX_PAGES) return null;
    const page = &g_fonts.pages[g_fonts.page_count];
    g_fonts.page_count += 1;
    page.* = std.mem.zeroes(rvn_atlas_page_t);
    page.pixels = @ptrCast(base.rvn_calloc(@as(usize, RVN_ATLAS_SIZE) * RVN_ATLAS_SIZE));
    page.next_y = 1;
    page.texture = raven.R_INVALID_ID;
    return page;
}

fn rvn_atlas_place(page: [*c]rvn_atlas_page_t, w: c_int, h: c_int, out_x: [*c]u16, out_y: [*c]u16) c_int {
    var i: u32 = 0;
    var best: [*c]rvn_shelf_t = null;
    // one pixel of spacing between glyphs avoids bleeding when filtered
    const pw = w + 1;
    const ph = h + 1;

    while (i < page.*.shelf_count) : (i += 1) {
        const shelf = &page.*.shelves[i];
        if (@as(c_int, shelf.height) < ph or @as(c_int, shelf.x) + pw > RVN_ATLAS_SIZE) continue;
        // accept a shelf only if little height is wasted
        if (@as(c_int, shelf.height) > ph + @divTrunc(ph, 4) + 2) continue;
        if (best == null or @as(c_int, shelf.height) < @as(c_int, best.*.height)) best = shelf;
    }
    if (best == null) {
        if (page.*.next_y + @as(u32, @intCast(ph)) > RVN_ATLAS_SIZE) return raven.R_FALSE;
        base.RVN_ARRAY_RESERVE(&page.*.shelves, &page.*.shelf_cap, page.*.shelf_count + 1);
        const index = page.*.shelf_count;
        page.*.shelf_count += 1;
        best = &page.*.shelves[index];
        best.*.y = @truncate(page.*.next_y);
        best.*.height = u16FromInt(ph);
        best.*.x = 1;
        page.*.next_y += @as(u32, @intCast(ph));
    }
    out_x.* = best.*.x;
    out_y.* = best.*.y;
    best.*.x = u16FromInt(@as(c_int, best.*.x) + pw);
    return raven.R_TRUE;
}

fn rvn_atlas_alloc(w: c_int, h: c_int, out_page: [*c]u16, out_x: [*c]u16, out_y: [*c]u16) c_int {
    var i: u32 = 0;
    if (w + 2 > RVN_ATLAS_SIZE or h + 2 > RVN_ATLAS_SIZE) return raven.R_FALSE;
    while (i < g_fonts.page_count) : (i += 1) {
        if (rvn_atlas_place(&g_fonts.pages[i], w, h, out_x, out_y) != 0) {
            out_page.* = @truncate(i);
            return raven.R_TRUE;
        }
    }
    const page = rvn_atlas_add_page();
    if (page == null or rvn_atlas_place(page, w, h, out_x, out_y) == 0) return raven.R_FALSE;
    out_page.* = @truncate(g_fonts.page_count - 1);
    return raven.R_TRUE;
}

fn rvn_atlas_mark_dirty(page: [*c]rvn_atlas_page_t, x: c_int, y: c_int, w: c_int, h: c_int) void {
    if (page.*.dirty == 0) {
        page.*.dirty = raven.R_TRUE;
        page.*.dirty_x0 = x;
        page.*.dirty_y0 = y;
        page.*.dirty_x1 = x + w;
        page.*.dirty_y1 = y + h;
    } else {
        page.*.dirty_x0 = base.rvn_mini(page.*.dirty_x0, x);
        page.*.dirty_y0 = base.rvn_mini(page.*.dirty_y0, y);
        page.*.dirty_x1 = base.rvn_maxi(page.*.dirty_x1, x + w);
        page.*.dirty_y1 = base.rvn_maxi(page.*.dirty_y1, y + h);
    }
}

// ---------------------------------------------------------------------------
//  Glyph raster cache
// ---------------------------------------------------------------------------

/// font serial (20 bits) | quantized size (16 bits) | style (2 bits) | glyph index (26 bits)
fn rvn_glyph_key(font: [*c]const rvn_font_t, glyph: c_int, size_q: u32, style: u32) u64 {
    return (@as(u64, font.*.serial & 0xFFFFF) << 44) | (@as(u64, size_q & 0xFFFF) << 28) |
        (@as(u64, style & 3) << 26) | (@as(u64, @as(u32, @bitCast(glyph))) & 0x3FFFFFF);
}

fn rvn_glyph_pack(glyph: [*c]const rvn_glyph_t, value: [*c]u64) void {
    value[0] = @as(u64, glyph.*.page) | (@as(u64, glyph.*.x) << 16) | (@as(u64, glyph.*.y) << 32) | (@as(u64, glyph.*.w) << 48);
    value[1] = @as(u64, glyph.*.h) | (@as(u64, @as(u16, @bitCast(glyph.*.offset_x))) << 16) | (@as(u64, @as(u16, @bitCast(glyph.*.offset_y))) << 32);
}

fn rvn_glyph_unpack(value: [*c]const u64, glyph: [*c]rvn_glyph_t) void {
    glyph.*.page = @truncate(value[0]);
    glyph.*.x = @truncate(value[0] >> 16);
    glyph.*.y = @truncate(value[0] >> 32);
    glyph.*.w = @truncate(value[0] >> 48);
    glyph.*.h = @truncate(value[1]);
    glyph.*.offset_x = @bitCast(@as(u16, @truncate(value[1] >> 16)));
    glyph.*.offset_y = @bitCast(@as(u16, @truncate(value[1] >> 32)));
}

/// How far the top of a slanted glyph leans, per pixel of height.
const RVN_ITALIC_SLANT: f32 = 0.2;

/// A glyph of a styled view: the glyph of the font, rasterized as usual, then
/// thickened (the outline drawn twice, a part of a pixel apart) and / or
/// slanted (each row slides sideways by its height above the baseline). `x0`,
/// `y0`: where the plain bitmap goes from the pen. Returns the new bitmap, to release with rvn_free.
fn rvn_glyph_styled(font: [*c]rvn_font_t, glyph_index: c_int, size_px: f32, style: u32, x0: [*c]c_int, y0: c_int,
    width: [*c]c_int, height: c_int) [*c]u8 {
    const h = height;
    // how much thicker the strokes get, in pixels: a part of a pixel at the size of body text
    const strength: f32 = if ((style & font_h.RVN_FONT_BOLD) != 0) base.rvn_maxf(0.5, size_px * 0.05) else 0.0;
    // the bitmap that is slanted: the plain glyph, or the thickened one (wider)
    const w: c_int = width.* + (if ((style & font_h.RVN_FONT_BOLD) != 0) @as(c_int, @intFromFloat(@ceil(strength))) + 1 else 0);
    const plain: [*c]u8 = @ptrCast(base.rvn_calloc(@as(usize, @intCast(w)) * @as(usize, @intCast(h))));

    if ((style & font_h.RVN_FONT_BOLD) != 0) {
        font_h.rvn_ttf_render_bold(font.*.ttf, glyph_index, size_px, strength, plain, w, h, w);
    } else {
        font_h.rvn_ttf_render(font.*.ttf, glyph_index, size_px, plain, w, h, w);
    }
    if ((style & font_h.RVN_FONT_ITALIC) == 0) {
        width.* = w;
        return plain;
    }
    // rows above the baseline (negative y) go right, rows below go left
    const shift_max: f32 = RVN_ITALIC_SLANT * @as(f32, @floatFromInt(-y0));
    const shift_min: f32 = RVN_ITALIC_SLANT * @as(f32, @floatFromInt(-(y0 + h - 1)));
    const lean: c_int = @intFromFloat(@floor(shift_min));
    const out_w: c_int = w + @as(c_int, @intFromFloat(@ceil(shift_max - @as(f32, @floatFromInt(lean))))) + 1;
    const out: [*c]u8 = @ptrCast(base.rvn_calloc(@as(usize, @intCast(out_w)) * @as(usize, @intCast(h))));
    var y: c_int = 0;
    while (y < h) : (y += 1) {
        const yu: usize = @intCast(y);
        const source = plain + yu * @as(usize, @intCast(w));
        const row = out + yu * @as(usize, @intCast(out_w));
        const shift: f32 = RVN_ITALIC_SLANT * @as(f32, @floatFromInt(-(y0 + y))) - @as(f32, @floatFromInt(lean));
        const whole: c_int = @intFromFloat(@floor(shift));
        const part: f32 = shift - @as(f32, @floatFromInt(whole));
        // the row, moved by a fraction of a pixel: each pixel is shared between two
        var x: c_int = 0;
        while (x < w) : (x += 1) {
            const value: f32 = @floatFromInt(source[@as(usize, @intCast(x))]);
            const left: c_int = @intFromFloat(value * (1.0 - part) + 0.5);
            const right: c_int = @intFromFloat(value * part + 0.5);
            const at: usize = @intCast(x + whole);
            row[at] = @intCast(base.rvn_mini(255, @as(c_int, row[at]) + left));
            if (right != 0) row[at + 1] = @intCast(base.rvn_mini(255, @as(c_int, row[at + 1]) + right));
        }
    }
    base.rvn_free(plain);
    x0.* += lean;
    width.* = out_w;
    return out;
}

/// Rasterizes a glyph into the atlas and publishes it. Caller holds the mutex.
fn rvn_glyph_create(font: [*c]rvn_font_t, glyph_index: c_int, size_q: u32, style: u32, key: u64, glyph: [*c]rvn_glyph_t) void {
    var value: [2]u64 = undefined;
    var x0: c_int = 0;
    var y0: c_int = 0;
    var x1: c_int = 0;
    var y1: c_int = 0;
    var w: c_int = undefined;
    var h: c_int = undefined;
    const size_px: f32 = @as(f32, @floatFromInt(size_q)) * 0.25;
    var styled: [*c]u8 = null;

    glyph.* = std.mem.zeroes(rvn_glyph_t);
    font_h.rvn_ttf_glyph_box(font.*.ttf, glyph_index, size_px, &x0, &y0, &x1, &y1);
    w = x1 - x0;
    h = y1 - y0;
    if (style != 0 and w > 0 and h > 0) styled = rvn_glyph_styled(font, glyph_index, size_px, style, &x0, y0, &w, h);
    if (w > 0 and h > 0 and rvn_atlas_alloc(w, h, &glyph.*.page, &glyph.*.x, &glyph.*.y) != 0) {
        const page = &g_fonts.pages[glyph.*.page];
        const target: [*c]u8 = page.pixels + @as(usize, glyph.*.y) * RVN_ATLAS_SIZE + @as(usize, glyph.*.x);
        const wu: usize = @intCast(w);
        if (styled != null) {
            var row: c_int = 0;
            while (row < h) : (row += 1) {
                const ru: usize = @intCast(row);
                @memcpy((target + ru * RVN_ATLAS_SIZE)[0..wu], (styled + ru * wu)[0..wu]);
            }
        } else {
            font_h.rvn_ttf_render(font.*.ttf, glyph_index, size_px, target, w, h, RVN_ATLAS_SIZE);
        }
        rvn_atlas_mark_dirty(page, @as(c_int, glyph.*.x), @as(c_int, glyph.*.y), w, h);
        glyph.*.w = u16FromInt(w);
        glyph.*.h = u16FromInt(h);
        glyph.*.offset_x = @bitCast(u16FromInt(x0));
        glyph.*.offset_y = @bitCast(u16FromInt(y0));
    }
    base.rvn_free(styled);
    // empty glyphs (space) and glyphs too large for a page are cached with w = 0
    rvn_glyph_pack(glyph, &value);
    lfmap.rvn_lfmap_insert(&g_fonts.glyphs, key, &value);
}

/// Lock-free when the glyph is cached; rasterizes it under the mutex otherwise.
fn rvn_glyph_get(font: [*c]rvn_font_t, glyph_index: c_int, size_q: u32, style: u32, glyph: [*c]rvn_glyph_t) void {
    const key = rvn_glyph_key(font, glyph_index, size_q, style);
    var value: [2]u64 = undefined;
    if (lfmap.rvn_lfmap_find(&g_fonts.glyphs, key, &value) != 0) {
        rvn_glyph_unpack(&value, glyph);
        return;
    }
    thread.rvn_mutex_lock(&g_fonts.mutex);
    // another thread may have created it while we were waiting
    if (lfmap.rvn_lfmap_find(&g_fonts.glyphs, key, &value) != 0) {
        rvn_glyph_unpack(&value, glyph);
    } else {
        rvn_glyph_create(font, glyph_index, size_q, style, key, glyph);
    }
    thread.rvn_mutex_unlock(&g_fonts.mutex);
}

// ---------------------------------------------------------------------------
//  Code point map
// ---------------------------------------------------------------------------

/// A font of the system that has the character (caller holds the mutex). The
/// fonts of the system are not in the pool of handles: the paint jobs read
/// that pool, and these are opened while they run.
fn rvn_font_system_glyph(codepoint: u32, entry: [*c]rvn_cmap_entry_t) c_int {
    var paths: [24][*c]const u8 = undefined;
    const count: c_int = font_h.rvn_font_system_candidates(codepoint, &paths, @intCast(paths.len));
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const pi: usize = @intCast(i);
        var k: c_int = 0;
        while (k < g_fonts.system_count) : (k += 1) {
            if (g_fonts.system[@intCast(k)].path == paths[pi]) break;
        }
        const ks: usize = @intCast(k);
        if (k == g_fonts.system_count) {
            var size: usize = 0;
            if (g_fonts.system_count >= 64) continue;
            g_fonts.system[ks].path = paths[pi];
            g_fonts.system[ks].font = null;
            g_fonts.system[ks].failed = raven.R_TRUE;
            g_fonts.system_count += 1;
            const data: [*c]u8 = base.rvn_read_file(paths[pi], &size);
            const ttf: ?*font_h.rvn_ttf_t = if (data != null) font_h.rvn_ttf_open(data, size) else null;
            if (ttf != null) {
                const made: [*c]rvn_font_t = allocFont();
                made.*.data = data;
                made.*.owns_data = raven.R_TRUE;
                made.*.ttf = ttf;
                made.*.fallback = raven.R_INVALID_ID;
                made.*.id = raven.R_INVALID_ID;
                g_fonts.next_serial +%= 1;
                made.*.serial = g_fonts.next_serial;
                font_h.rvn_ttf_vmetrics(ttf, &made.*.ascent, &made.*.descent, &made.*.line_gap);
                g_fonts.system[ks].font = made;
                g_fonts.system[ks].failed = raven.R_FALSE;
            } else {
                base.rvn_free(data);
            }
        }
        if (g_fonts.system[ks].failed != 0) continue;
        const font = g_fonts.system[ks].font;
        const glyph = font_h.rvn_ttf_glyph_index(font.*.ttf, codepoint);
        if (glyph != 0) {
            entry.*.font = font;
            entry.*.glyph = glyph;
            entry.*.advance = font_h.rvn_ttf_advance(font.*.ttf, glyph);
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

/// Walks the fallback chain. Reads the font pool, which never changes during paint.
fn rvn_cmap_resolve(font: [*c]rvn_font_t, codepoint: u32, entry: [*c]rvn_cmap_entry_t) void {
    var candidate: [*c]rvn_font_t = font;
    var depth: c_int = 0;
    while (candidate != null and depth < 8) : (depth += 1) {
        const glyph = font_h.rvn_ttf_glyph_index(candidate.*.ttf, codepoint);
        if (glyph != 0) {
            entry.*.font = candidate;
            entry.*.glyph = glyph;
            entry.*.advance = font_h.rvn_ttf_advance(candidate.*.ttf, glyph);
            return;
        }
        candidate = poolFont(candidate.*.fallback);
    }
    // then the fonts of the system: other alphabets, CJK, symbols, emoji
    if (codepoint >= 128 and rvn_font_system_glyph(codepoint, entry) != 0) return;
    // nobody has it: use the "missing glyph" box of the font itself
    entry.*.font = font;
    entry.*.glyph = 0;
    entry.*.advance = font_h.rvn_ttf_advance(font.*.ttf, 0);
}

fn rvn_cmap_build_ascii(font: [*c]rvn_font_t) void {
    var c: u32 = 0;
    while (c < 128) : (c += 1) rvn_cmap_resolve(font, c, &font.*.ascii[c]);
    // control characters take no space; a tab is a run of spaces
    c = 0;
    while (c < 32) : (c += 1) {
        font.*.ascii[c].advance = 0.0;
        font.*.ascii[c].glyph = -1;
    }
    font.*.ascii['\t'].advance = font.*.ascii[' '].advance * @as(f32, @floatFromInt(RVN_TAB_SPACES));
    font.*.ascii[127].advance = 0.0;
    font.*.ascii[127].glyph = -1;
}

fn rvn_cmap_pack(entry: [*c]const rvn_cmap_entry_t, value: [*c]u64) void {
    const advance_bits: u32 = @bitCast(entry.*.advance);
    value[0] = @as(u64, @intFromPtr(entry.*.font));
    value[1] = @as(u64, @as(u32, @bitCast(entry.*.glyph))) | (@as(u64, advance_bits) << 32);
}

fn rvn_cmap_unpack(value: [*c]const u64, entry: [*c]rvn_cmap_entry_t) void {
    const advance_bits: u32 = @truncate(value[1] >> 32);
    entry.*.font = @ptrFromInt(@as(usize, @intCast(value[0])));
    entry.*.glyph = @bitCast(@as(u32, @truncate(value[1])));
    entry.*.advance = @bitCast(advance_bits);
}

/// Lock-free for ASCII and for code points already seen.
fn rvn_cmap_get(font_: [*c]rvn_font_t, codepoint: u32) rvn_cmap_entry_t {
    var font = font_;
    var entry: rvn_cmap_entry_t = undefined;
    var value: [2]u64 = undefined;

    // (a styled view has the characters and the advances of its font)
    if (font.*.base != null) font = font.*.base;
    if (codepoint < 128) return font.*.ascii[codepoint];
    if (lfmap.rvn_lfmap_find(&font.*.cmap, codepoint, &value) != 0) {
        rvn_cmap_unpack(&value, &entry);
        return entry;
    }
    thread.rvn_mutex_lock(&g_fonts.mutex);
    if (lfmap.rvn_lfmap_find(&font.*.cmap, codepoint, &value) != 0) {
        rvn_cmap_unpack(&value, &entry);
    } else {
        rvn_cmap_resolve(font, codepoint, &entry);
        // zero-width and formatting characters are not drawn
        if (codepoint == 0x200B or codepoint == 0x200C or codepoint == 0x200D or codepoint == 0xFEFF or
            codepoint == 0xFE0E or codepoint == 0xFE0F or codepoint == 0x200E or codepoint == 0x200F or codepoint == 0x061C or
            (codepoint >= 0x202A and codepoint <= 0x202E) or (codepoint >= 0x2066 and codepoint <= 0x2069))
        {
            entry.advance = 0.0;
            entry.glyph = -1;
        }
        rvn_cmap_pack(&entry, &value);
        lfmap.rvn_lfmap_insert(&font.*.cmap, codepoint, &value);
    }
    thread.rvn_mutex_unlock(&g_fonts.mutex);
    return entry;
}

// ---------------------------------------------------------------------------
//  Lifecycle
// ---------------------------------------------------------------------------

fn rvn_font_create(data: [*c]u8, size: usize, owns_data: c_int) [*c]rvn_font_t {
    const ttf = font_h.rvn_ttf_open(data, size);
    if (ttf == null) {
        if (owns_data != 0) base.rvn_free(data);
        return null;
    }
    const font: [*c]rvn_font_t = allocFont();
    font.*.data = data;
    font.*.owns_data = owns_data;
    font.*.ttf = ttf;
    font.*.fallback = raven.R_INVALID_ID;
    font_h.rvn_ttf_vmetrics(ttf, &font.*.ascent, &font.*.descent, &font.*.line_gap);
    thread.rvn_mutex_lock(&g_fonts.mutex);
    g_fonts.next_serial +%= 1;
    font.*.serial = g_fonts.next_serial;
    thread.rvn_mutex_unlock(&g_fonts.mutex);
    rvn_cmap_build_ascii(font);
    font.*.id = handle.rvn_pool_add(&context.g_rvn.fonts, font);
    return font;
}

fn rvn_font_destroy(font: [*c]rvn_font_t) void {
    var i: usize = 0;
    // the styled views made from it go with it
    while (i < 3) : (i += 1) {
        const view: [*c]rvn_font_t = if (font.*.variant_owned[i] != 0)
            poolFont(font.*.variants[i])
        else
            null;
        if (view != null and view.*.base == font) {
            handle.rvn_pool_remove(&context.g_rvn.fonts, view.*.id);
            base.rvn_free(view);
        }
    }
    handle.rvn_pool_remove(&context.g_rvn.fonts, font.*.id);
    if (font.*.base == null) {
        font_h.rvn_ttf_close(font.*.ttf);
        if (font.*.owns_data != 0) base.rvn_free(font.*.data);
        lfmap.rvn_lfmap_clear(&font.*.cmap);
    }
    base.rvn_free(font);
}

export fn rvn_font_variant(id: raven.Rid, style_: u32) raven.Rid {
    var style = style_;
    var font: [*c]rvn_font_t = rvn_font_resolve(id);
    if (font == null) return raven.R_INVALID_ID;
    // the bold of an italic view is the bold italic of its font
    if (font.*.base != null) {
        style |= font.*.style;
        font = font.*.base;
    }
    style &= font_h.RVN_FONT_BOLD | font_h.RVN_FONT_ITALIC;
    if (style == 0) return font.*.id;
    if (handle.rvn_pool_get(&context.g_rvn.fonts, font.*.variants[style - 1]) != null) return font.*.variants[style - 1];

    const view: [*c]rvn_font_t = allocFont();
    view.*.base = font;
    view.*.style = style;
    view.*.ttf = font.*.ttf;
    view.*.serial = font.*.serial;
    view.*.ascent = font.*.ascent;
    view.*.descent = font.*.descent;
    view.*.line_gap = font.*.line_gap;
    view.*.fallback = raven.R_INVALID_ID;
    view.*.id = handle.rvn_pool_add(&context.g_rvn.fonts, view);
    if (view.*.id == raven.R_INVALID_ID) {
        base.rvn_free(view);
        return font.*.id;
    }
    font.*.variants[style - 1] = view.*.id;
    font.*.variant_owned[style - 1] = 1;
    return view.*.id;
}

export fn rvn_fonts_init() void {
    var font: [*c]rvn_font_t = undefined;
    g_fonts = std.mem.zeroes(FontsState);
    thread.rvn_mutex_init(&g_fonts.mutex);
    g_fonts.initialized = raven.R_TRUE;
    // the embedded font is read in place, never freed
    font = rvn_font_create(@constCast(@as([*c]const u8, &font_h.rvn_default_font_data)), font_h.rvn_default_font_size, raven.R_FALSE);
    context.g_rvn.default_font = if (font != null) font.*.id else raven.R_INVALID_ID;
    if (font == null) {
        base.rvn_error(raven.R_ERROR_INVALID_FILE_FORMAT, raven.R_SEVERITY_FATAL, "the embedded default font is invalid");
    }
    // the fixed-width font of the text editors; characters it lacks come from the default font
    font = rvn_font_create(@constCast(@as([*c]const u8, &font_h.rvn_mono_font_data)), font_h.rvn_mono_font_size, raven.R_FALSE);
    context.g_rvn.mono_font = if (font != null) font.*.id else raven.R_INVALID_ID;
    if (font != null) font.*.fallback = context.g_rvn.default_font;
}

export fn rvn_fonts_shutdown() void {
    var i: u32 = 0;
    if (g_fonts.initialized == 0) return;
    // (a font takes its styled views with it: the fonts of their own are the ones to delete)
    while (i < context.g_rvn.fonts.used) : (i += 1) {
        const font: [*c]rvn_font_t = poolFontAt(i);
        if (font != null and font.*.base == null) rvn_font_destroy(font);
    }
    i = 0;
    while (i < context.g_rvn.fonts.used) : (i += 1) {
        const font: [*c]rvn_font_t = poolFontAt(i);
        if (font != null) rvn_font_destroy(font);
    }
    i = 0;
    while (i < g_fonts.page_count) : (i += 1) {
        base.rvn_free(g_fonts.pages[i].pixels);
        base.rvn_free(g_fonts.pages[i].shelves);
    }
    i = 0;
    while (i < @as(u32, @bitCast(g_fonts.system_count))) : (i += 1) {
        const font = g_fonts.system[i].font;
        if (font == null) continue;
        font_h.rvn_ttf_close(font.*.ttf);
        base.rvn_free(font.*.data);
        base.rvn_free(font);
    }
    font_h.rvn_font_system_shutdown();
    lfmap.rvn_lfmap_clear(&g_fonts.glyphs);
    thread.rvn_mutex_destroy(&g_fonts.mutex);
    g_fonts = std.mem.zeroes(FontsState);
    context.g_rvn.default_font = raven.R_INVALID_ID;
    context.g_rvn.mono_font = raven.R_INVALID_ID;
}

export fn rvn_font_resolve(id: raven.Rid) ?*rvn_font_t {
    var font: [*c]rvn_font_t = poolFont(id);
    if (font == null) font = poolFont(context.g_rvn.theme.font);
    if (font == null) font = poolFont(context.g_rvn.default_font);
    return font;
}

export fn rvn_font_size_resolve(size: f32) f32 {
    if (size > 0.0) return size;
    return context.RVN_THEME_METRIC(raven.R_METRIC_FONT_SIZE);
}

export fn rvn_font_metrics(font_: ?*rvn_font_t, size_: f32, metrics: [*c]font_h.rvn_font_metrics_t) void {
    var size = size_;
    const font: [*c]rvn_font_t = font_;
    // the size of every text (Raccessibility_set_text_scale)
    size *= font_h.rvn_a11y_text_scale();
    metrics.*.ascent = font.*.ascent * size;
    metrics.*.descent = font.*.descent * size;
    metrics.*.line_height = (font.*.ascent + font.*.descent + font.*.line_gap) * size;
}

// ---------------------------------------------------------------------------
//  Measuring
// ---------------------------------------------------------------------------

fn rvn_text_length(text: [*c]const u8, length: c_int) c_int {
    if (text == null) return 0;
    return if (length < 0) @intCast(libc.strlen(text)) else length;
}

export fn rvn_text_width(font_: ?*rvn_font_t, size: f32, text_: [*c]const u8, length_: c_int) f32 {
    var text: [*c]const u8 = text_;
    var length = length_;
    var cursor: [*c]const u8 = undefined;
    var end: [*c]const u8 = undefined;
    var width: f32 = 0.0;
    var visual: [*c]u8 = null;
    var visual_length: c_int = undefined;

    const font: [*c]rvn_font_t = font_;
    if (font == null) return 0.0;
    length = rvn_text_length(text, length);
    // right-to-left text is measured as it is drawn (Arabic ligatures change the width)
    if (bidi.rvn_bidi_needed(text, length) != 0) {
        visual = bidi.rvn_bidi_visual(text, length, &visual_length);
        text = visual;
        cursor = text;
        length = visual_length;
    } else {
        cursor = text;
    }
    end = text + @as(usize, @intCast(length));
    while (cursor < end) {
        const codepoint = base.rvn_utf8_decode(&cursor, end);
        width += rvn_cmap_get(font, codepoint).advance;
    }
    base.rvn_free(visual);
    return width * size * font_h.rvn_a11y_text_scale();
}

export fn rvn_text_offset_at(font_: ?*rvn_font_t, size_: f32, text: [*c]const u8, length_: c_int, x: f32) c_int {
    var size = size_;
    var length = length_;
    var cursor: [*c]const u8 = text;
    var end: [*c]const u8 = undefined;
    var pen: f32 = 0.0;
    var result: c_int = undefined;

    const font: [*c]rvn_font_t = font_;
    if (font == null) return 0;
    size *= font_h.rvn_a11y_text_scale();
    length = rvn_text_length(text, length);
    end = text + @as(usize, @intCast(length));
    result = length;
    while (cursor < end) {
        const start = cursor;
        const codepoint = base.rvn_utf8_decode(&cursor, end);
        const advance = rvn_cmap_get(font, codepoint).advance * size;
        if (x < pen + advance * 0.5) {
            result = @intCast(start - text);
            break;
        }
        pen += advance;
    }
    return result;
}

export fn rvn_text_wrap(font_: ?*rvn_font_t, size_: f32, text: [*c]const u8, length_: c_int, max_width: f32, line_width: [*c]f32) c_int {
    var size = size_;
    var length = length_;
    var cursor: [*c]const u8 = text;
    var end: [*c]const u8 = undefined;
    // position after the last break opportunity, and the width before it
    var break_after: [*c]const u8 = null;
    var break_width: f32 = 0.0;
    var pen: f32 = 0.0;
    var visible_width: f32 = 0.0;

    if (line_width != null) line_width.* = 0.0;
    const font: [*c]rvn_font_t = font_;
    if (font == null) return 0;
    size *= font_h.rvn_a11y_text_scale();
    length = rvn_text_length(text, length);
    end = text + @as(usize, @intCast(length));

    done: {
        while (cursor < end) {
            const start = cursor;
            const codepoint = base.rvn_utf8_decode(&cursor, end);
            if (codepoint == '\n') {
                break_after = cursor;
                break_width = visible_width;
                break :done;
            }
            const advance = rvn_cmap_get(font, codepoint).advance * size;
            if (codepoint == ' ' or codepoint == '\t') {
                // a space is a break opportunity; it does not count if the line ends here
                break_after = cursor;
                break_width = visible_width;
                pen += advance;
                continue;
            }
            if (max_width > 0.0 and pen + advance > max_width + 0.01 and start > text) {
                if (break_after == null) {
                    // a single word wider than the line: break inside it
                    break_after = start;
                    break_width = visible_width;
                }
                break :done;
            }
            pen += advance;
            visible_width = pen;
        }
        break_after = end;
        break_width = visible_width;
    }

    const consumed: c_int = @intCast(break_after - text);
    if (line_width != null) line_width.* = break_width;
    return if (consumed > 0) consumed else length;
}

// ---------------------------------------------------------------------------
//  Drawing
// ---------------------------------------------------------------------------

export fn rvn_text_draw(list: [*c]draw.rvn_drawlist_t, font_: ?*rvn_font_t, size_px_: f32, x: f32, y: f32,
    text_: [*c]const u8, length_: c_int, color: base.rvn_color_t, clip: base.rvn_box_t) void {
    var size_px = size_px_;
    var text: [*c]const u8 = text_;
    var length = length_;
    var cursor: [*c]const u8 = text;
    var end: [*c]const u8 = undefined;
    var size_q: u32 = undefined;
    var pen: f32 = undefined;
    var baseline: f32 = undefined;
    var line_height: f32 = undefined;
    const inv_atlas: f32 = 1.0 / @as(f32, RVN_ATLAS_SIZE);
    var visual: [*c]u8 = null;

    const font: [*c]rvn_font_t = font_;
    if (font == null or text == null or (color >> 24) == 0) return;
    size_px *= font_h.rvn_a11y_text_scale();
    length = rvn_text_length(text, length);
    if (length == 0 or size_px < 1.0) return;
    // right to left: drawn in visual order, Arabic joined (render/bidi.c)
    if (bidi.rvn_bidi_needed(text, length) != 0) {
        var visual_length: c_int = undefined;
        visual = bidi.rvn_bidi_visual(text, length, &visual_length);
        text = visual;
        cursor = text;
        length = visual_length;
    }

    // nothing to do when the whole line is outside the clip rectangle
    line_height = (font.*.ascent + font.*.descent + font.*.line_gap) * size_px;
    if (y + line_height * 1.5 < clip.y0 or y - line_height * 0.5 > clip.y1 or x > clip.x1) {
        base.rvn_free(visual);
        return;
    }

    size_q = @intFromFloat(size_px * 4.0 + 0.5);
    if (size_q > 0xFFFF) size_q = 0xFFFF;
    if (size_q < 4) size_q = 4;

    end = text + @as(usize, @intCast(length));
    pen = x;
    baseline = @floor(y + (font.*.ascent + font.*.line_gap * 0.5) * size_px + 0.5);

    while (cursor < end) {
        const codepoint = base.rvn_utf8_decode(&cursor, end);
        const entry = rvn_cmap_get(font, codepoint);
        const advance = entry.advance * size_px;

        if (entry.glyph >= 0 and codepoint != ' ') {
            const gx = @floor(pen + 0.5);
            var layer_glyphs: [16]c_int = undefined;
            var layer_colors: [16]u32 = undefined;
            var layers: c_int = 0;
            var layer: c_int = undefined;
            if (gx > clip.x1) break;
            // a color glyph (emoji): its layers, each an outline in its own color
            if (font_h.rvn_ttf_has_color(entry.font.*.ttf) != 0) {
                layers = font_h.rvn_ttf_color_layers(entry.font.*.ttf, entry.glyph, &layer_glyphs, &layer_colors, 16);
            }
            if (layers == 0) {
                layer_glyphs[0] = entry.glyph;
                layer_colors[0] = 0;
                layers = 1;
            }
            // cheap horizontal rejection before touching the cache
            if (gx + size_px * 2.0 >= clip.x0) {
                layer = 0;
                while (layer < layers) : (layer += 1) {
                    const li: usize = @intCast(layer);
                    var glyph: rvn_glyph_t = undefined;
                    var layer_color: u32 = color;
                    if (layer_colors[li] != 0) {
                        // the color of the layer, with the opacity of the text
                        const alpha: u32 = ((layer_colors[li] >> 24) * (color >> 24) + 127) / 255;
                        layer_color = (layer_colors[li] & 0x00FFFFFF) | (alpha << 24);
                    }
                    rvn_glyph_get(entry.font, layer_glyphs[li], size_q, font.*.style, &glyph);
                    if (glyph.w > 0) {
                        const x0: f32 = gx + @as(f32, @floatFromInt(glyph.offset_x));
                        const y0: f32 = baseline + @as(f32, @floatFromInt(glyph.offset_y));
                        const x1: f32 = x0 + @as(f32, @floatFromInt(glyph.w));
                        const y1: f32 = y0 + @as(f32, @floatFromInt(glyph.h));
                        if (x1 > clip.x0 and x0 < clip.x1 and y1 > clip.y0 and y0 < clip.y1) {
                            const instance = draw.rvn_drawlist_add(list, handle.rvn_handle_make(handle.RVN_HANDLE_ATLAS_PAGE, 0, glyph.page));
                            instance.*.rect[0] = x0;
                            instance.*.rect[1] = y0;
                            instance.*.rect[2] = x1;
                            instance.*.rect[3] = y1;
                            instance.*.uv[0] = @as(f32, @floatFromInt(glyph.x)) * inv_atlas;
                            instance.*.uv[1] = @as(f32, @floatFromInt(glyph.y)) * inv_atlas;
                            instance.*.uv[2] = @as(f32, @floatFromInt(@as(u32, glyph.x) + glyph.w)) * inv_atlas;
                            instance.*.uv[3] = @as(f32, @floatFromInt(@as(u32, glyph.y) + glyph.h)) * inv_atlas;
                            instance.*.clip[0] = clip.x0;
                            instance.*.clip[1] = clip.y0;
                            instance.*.clip[2] = clip.x1;
                            instance.*.clip[3] = clip.y1;
                            instance.*.radii[0] = 0.0;
                            instance.*.radii[1] = 0.0;
                            instance.*.radii[2] = 0.0;
                            instance.*.radii[3] = 0.0;
                            instance.*.color = layer_color;
                            instance.*.border_color = 0;
                            instance.*.border_width = 0.0;
                            instance.*.flags = raven.R_PRIM_GLYPH | raven.R_INSTANCE_TEXTURED;
                        }
                    }
                }
            }
        }
        pen += advance;
    }
    base.rvn_free(visual);
}

// ---------------------------------------------------------------------------
//  Atlas upload (UI thread)
// ---------------------------------------------------------------------------

export fn rvn_fonts_flush() void {
    var i: u32 = 0;
    thread.rvn_mutex_lock(&g_fonts.mutex);
    // no paint job is running here: the tables replaced during the frame can go
    lfmap.rvn_lfmap_collect(&g_fonts.glyphs);
    while (i < context.g_rvn.fonts.used) : (i += 1) {
        const font: [*c]rvn_font_t = poolFontAt(i);
        if (font != null) lfmap.rvn_lfmap_collect(&font.*.cmap);
    }
    i = 0;
    while (i < g_fonts.page_count) : (i += 1) {
        const page = &g_fonts.pages[i];
        if (page.texture == raven.R_INVALID_ID) {
            const atlas_bytes: usize = @as(usize, RVN_ATLAS_SIZE) * RVN_ATLAS_SIZE;
            const copy: [*c]u8 = @ptrCast(base.rvn_alloc(atlas_bytes));
            @memcpy(copy[0..atlas_bytes], page.pixels[0..atlas_bytes]);
            page.texture = renderer.rvn_texture_create_raw(RVN_ATLAS_SIZE, RVN_ATLAS_SIZE, raven.R_TEXTURE_ALPHA8,
                raven.R_FILTER_LINEAR, copy);
            page.dirty = raven.R_FALSE;
        } else if (page.dirty != 0) {
            const w: c_int = page.dirty_x1 - page.dirty_x0;
            const h: c_int = page.dirty_y1 - page.dirty_y0;
            const wu: usize = @intCast(w);
            const hu: usize = @intCast(h);
            const copy: [*c]u8 = @ptrCast(base.rvn_alloc(wu * hu));
            var row: c_int = 0;
            while (row < h) : (row += 1) {
                const ru: usize = @intCast(row);
                const src_y: usize = @intCast(page.dirty_y0 + row);
                const src_x: usize = @intCast(page.dirty_x0);
                @memcpy((copy + ru * wu)[0..wu], (page.pixels + src_y * RVN_ATLAS_SIZE + src_x)[0..wu]);
            }
            renderer.rvn_renderer_update_texture(page.texture, @bitCast(page.dirty_x0), @bitCast(page.dirty_y0),
                @bitCast(w), @bitCast(h), copy);
            page.dirty = raven.R_FALSE;
        }
    }
    thread.rvn_mutex_unlock(&g_fonts.mutex);
}

export fn rvn_fonts_resolve_pages(list: [*c]draw.rvn_drawlist_t) void {
    var i: u32 = 0;
    while (i < list.*.command_count) : (i += 1) {
        const command = &list.*.commands[i];
        if (handle.rvn_handle_type(command.texture) == handle.RVN_HANDLE_ATLAS_PAGE) {
            const page = handle.rvn_handle_index(command.texture);
            command.texture = if (page < g_fonts.page_count) g_fonts.pages[page].texture else raven.R_INVALID_ID;
        }
    }
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rfont_create(data: [*c]const u8, data_size: usize) raven.Rid {
    if (context.rvn_api_check("Rfont_create") == 0) return raven.R_INVALID_ID;
    if (data == null or data_size == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rfont_create: empty buffer");
        return raven.R_INVALID_ID;
    }
    const copy: [*c]u8 = @ptrCast(base.rvn_alloc(data_size));
    @memcpy(copy[0..data_size], data[0..data_size]);
    const font = rvn_font_create(copy, data_size, raven.R_TRUE);
    if (font == null) {
        base.rvn_error(raven.R_ERROR_INVALID_FILE_FORMAT, raven.R_SEVERITY_ERROR, "Rfont_create: not a TrueType / OpenType font");
        return raven.R_INVALID_ID;
    }
    return font.*.id;
}

export fn Rfont_create_from_file(path: [*c]const u8) raven.Rid {
    if (context.rvn_api_check("Rfont_create_from_file") == 0) return raven.R_INVALID_ID;
    var size: usize = 0;
    const data: [*c]u8 = base.rvn_read_file(path, &size);
    if (data == null) {
        const shown: [*c]const u8 = if (path != null) path else "";
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "Rfont_create_from_file: cannot read '%s'", shown);
        return raven.R_INVALID_ID;
    }
    const font = rvn_font_create(data, size, raven.R_TRUE);
    if (font == null) {
        base.rvn_error(raven.R_ERROR_INVALID_FILE_FORMAT, raven.R_SEVERITY_ERROR, "Rfont_create_from_file: '%s' is not a font", path);
        return raven.R_INVALID_ID;
    }
    return font.*.id;
}

export fn Rfont_destroy(id: raven.Rid) void {
    if (context.rvn_api_check("Rfont_destroy") == 0) return;
    const font: [*c]rvn_font_t = poolFont(id);
    if (font == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rfont_destroy: invalid font");
        return;
    }
    if (id == context.g_rvn.default_font or id == context.g_rvn.mono_font) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_WARNING, "Rfont_destroy: the built-in fonts cannot be deleted");
        return;
    }
    if (font.*.base != null) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_WARNING, "Rfont_destroy: a style derived from a font goes with its font");
        return;
    }
    // other fonts may have cached glyphs of this one as a fallback: forget them
    thread.rvn_mutex_lock(&g_fonts.mutex);
    {
        var i: u32 = 0;
        while (i < context.g_rvn.fonts.used) : (i += 1) {
            const other: [*c]rvn_font_t = poolFontAt(i);
            if (other == null or other == font) continue;
            if (other.*.fallback == id) other.*.fallback = raven.R_INVALID_ID;
            lfmap.rvn_lfmap_clear(&other.*.cmap);
        }
        if (context.g_rvn.theme.font == id) context.g_rvn.theme.font = context.g_rvn.default_font;
        rvn_font_destroy(font);
        i = 0;
        while (i < context.g_rvn.fonts.used) : (i += 1) {
            const other: [*c]rvn_font_t = poolFontAt(i);
            if (other != null) rvn_cmap_build_ascii(other);
        }
    }
    thread.rvn_mutex_unlock(&g_fonts.mutex);
    context.rvn_invalidate_all_windows();
}

export fn Rfont_set_variant(id: raven.Rid, style: raven.RFontStyle, variant: raven.Rid) void {
    if (context.rvn_api_check("Rfont_set_variant") == 0) return;
    const font: [*c]rvn_font_t = poolFont(id);
    const other: [*c]rvn_font_t = poolFont(variant);
    const slot: c_int = @as(c_int, @bitCast(style)) - raven.R_FONT_BOLD;
    if (font == null or font.*.base != null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rfont_set_variant: invalid font");
        return;
    }
    if (style < raven.R_FONT_BOLD or style > raven.R_FONT_BOLD_ITALIC) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rfont_set_variant: the style must be bold, italic or bold italic");
        return;
    }
    if (variant != raven.R_INVALID_ID and (other == null or other == font)) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rfont_set_variant: invalid variant");
        return;
    }
    const idx: usize = @intCast(slot);
    // the style Raven derived until now is no longer needed
    if (font.*.variant_owned[idx] != 0) {
        const view: [*c]rvn_font_t = poolFont(font.*.variants[idx]);
        if (view != null and view.*.base == font) {
            handle.rvn_pool_remove(&context.g_rvn.fonts, view.*.id);
            base.rvn_free(view);
        }
    }
    font.*.variants[idx] = variant;
    font.*.variant_owned[idx] = 0;
    context.rvn_invalidate_all_windows();
}

export fn Rfont_get_variant(id: raven.Rid, style: raven.RFontStyle) raven.Rid {
    if (context.rvn_api_check("Rfont_get_variant") == 0) return raven.R_INVALID_ID;
    if (style < raven.R_FONT_REGULAR or style > raven.R_FONT_BOLD_ITALIC) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rfont_get_variant: invalid style");
        return raven.R_INVALID_ID;
    }
    const offset: u32 = @intCast(@as(c_int, @bitCast(style)) - raven.R_FONT_REGULAR);
    return rvn_font_variant(id, offset);
}

export fn Rfont_is_valid(font: raven.Rid) c_int {
    return @intFromBool(context.g_rvn.initialized != 0 and handle.rvn_pool_get(&context.g_rvn.fonts, font) != null);
}

export fn Rfont_get_default() raven.Rid {
    return if (context.g_rvn.initialized != 0) context.g_rvn.default_font else raven.R_INVALID_ID;
}

export fn Rfont_get_monospace() raven.Rid {
    return if (context.g_rvn.initialized != 0) context.g_rvn.mono_font else raven.R_INVALID_ID;
}

export fn Rfont_set_fallback(id: raven.Rid, fallback: raven.Rid) void {
    if (context.rvn_api_check("Rfont_set_fallback") == 0) return;
    const font: [*c]rvn_font_t = poolFont(id);
    if (font == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rfont_set_fallback: invalid font");
        return;
    }
    // refuse cycles
    var walk: [*c]rvn_font_t = poolFont(fallback);
    var depth: c_int = 0;
    while (walk != null and depth < 16) : (depth += 1) {
        if (walk == font) {
            base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rfont_set_fallback: fallback chain loops");
            return;
        }
        walk = poolFont(walk.*.fallback);
    }
    thread.rvn_mutex_lock(&g_fonts.mutex);
    font.*.fallback = fallback;
    lfmap.rvn_lfmap_clear(&font.*.cmap);
    rvn_cmap_build_ascii(font);
    thread.rvn_mutex_unlock(&g_fonts.mutex);
    context.rvn_invalidate_all_windows();
}

export fn Rfont_measure_text(font_id: raven.Rid, size_: f32, text_: [*c]const u8, width: [*c]f32, height: [*c]f32) void {
    var size = size_;
    var text: [*c]const u8 = text_;
    var metrics: font_h.rvn_font_metrics_t = undefined;
    var max_width: f32 = 0.0;
    var lines: c_int = 1;

    if (width != null) width.* = 0.0;
    if (height != null) height.* = 0.0;
    if (context.rvn_api_check("Rfont_measure_text") == 0) return;
    const font: [*c]rvn_font_t = rvn_font_resolve(font_id);
    if (font == null) return;
    size = rvn_font_size_resolve(size);
    rvn_font_metrics(font, size, &metrics);
    if (text == null) text = "";
    var line: [*c]const u8 = text;
    while (true) {
        const newline: [*c]const u8 = libc.strchr(line, '\n');
        const length: c_int = if (newline != null) @intCast(newline - line) else @intCast(libc.strlen(line));
        max_width = base.rvn_maxf(max_width, rvn_text_width(font, size, line, length));
        if (newline == null) break;
        line = newline + 1;
        lines += 1;
    }
    if (width != null) width.* = max_width;
    if (height != null) height.* = metrics.line_height * @as(f32, @floatFromInt(lines));
}
