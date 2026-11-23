// Translated to Zig from vendor/raven/src/render/font_raster.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/font_raster.c
// The only file that includes stb_truetype. The implementation is compiled
// as static functions so that it never clashes with another copy of stb
// linked into the application (HRL embeds one too).
//
// The stbtt_* functions are the ported stb_truetype (src/third_party/stb_truetype.zig), imported as a
// module: no extern declarations. stbtt__find_table is private to the stb header and is kept here as
// the same function, as in the C file.

const base = @import("../core/base_h.zig");
const stb = @import("../third_party/stb_truetype.zig");

// static inline uint16_t rvn_ttf_u16(const uint8_t* p)  (big-endian, as the TrueType tables are)
fn rvn_ttf_u16(p: [*c]const u8) u16 {
    return (@as(u16, p[0]) << 8) | @as(u16, p[1]);
}
// static inline uint32_t rvn_ttf_u32(const uint8_t* p)
fn rvn_ttf_u32(p: [*c]const u8) u32 {
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | @as(u32, p[3]);
}

// stb_truetype.h: static stbtt_uint32 stbtt__find_table(stbtt_uint8 *data, stbtt_uint32 fontstart, const char *tag)
// (stb's ttUSHORT / ttULONG are the same big-endian reads as rvn_ttf_u16 / rvn_ttf_u32)
fn stbtt_tag(p: [*c]const u8, tag: [*c]const u8) bool {
    return p[0] == tag[0] and p[1] == tag[1] and p[2] == tag[2] and p[3] == tag[3];
}

fn stbtt__find_table(data: [*c]u8, fontstart: u32, tag: [*c]const u8) u32 {
    const num_tables: c_int = @intCast(rvn_ttf_u16(data + @as(usize, fontstart) + 4));
    const tabledir: u32 = fontstart +% 12;
    var i: c_int = 0;
    while (i < num_tables) : (i += 1) {
        const loc: u32 = tabledir +% 16 *% @as(u32, @intCast(i));
        if (stbtt_tag(data + @as(usize, loc) + 0, tag)) {
            return rvn_ttf_u32(data + @as(usize, loc) + 8);
        }
    }
    return 0;
}

// struct rvn_ttf_t
const rvn_ttf_t = extern struct {
    info: stb.stbtt_fontinfo,
    units_per_em: f32,
    // color glyphs (COLR / CPAL version 0): offsets in the data, 0 when the font has none
    colr: u32,
    cpal: u32,
};

export fn rvn_ttf_has_color(ttf: [*c]rvn_ttf_t) c_int {
    return @intFromBool(ttf.*.colr != 0 and ttf.*.cpal != 0);
}

// The layers of a color glyph (an emoji of Segoe UI Emoji, of Noto's COLR
// fonts...): each is an ordinary outline glyph of the font, drawn in a color
// of the first palette, the first layer at the bottom. A color of 0 means
// "the color of the text". Returns the number of layers, 0 for a plain glyph.
export fn rvn_ttf_color_layers(ttf: [*c]rvn_ttf_t, glyph: c_int, glyphs: [*c]c_int, colors: [*c]u32, max: c_int) c_int {
    const data: [*c]const u8 = ttf.*.info.data;
    if (ttf.*.colr == 0 or ttf.*.cpal == 0) return 0;
    const colr: [*c]const u8 = data + @as(usize, ttf.*.colr);
    const cpal: [*c]const u8 = data + @as(usize, ttf.*.cpal);
    if (rvn_ttf_u16(colr) != 0 and rvn_ttf_u16(colr) != 1) return 0;
    const base_count = rvn_ttf_u16(colr + 2);
    const base_offset = rvn_ttf_u32(colr + 4);
    const layer_offset = rvn_ttf_u32(colr + 8);
    const entries = rvn_ttf_u16(cpal + 2);
    const color_offset = rvn_ttf_u32(cpal + 8);
    const first_index = rvn_ttf_u16(cpal + 12);
    // the base glyph records are sorted by glyph
    var lo: c_int = 0;
    var hi: c_int = @as(c_int, base_count) - 1;
    while (lo <= hi) {
        const mid: c_int = @divTrunc(lo + hi, 2);
        const record: [*c]const u8 = colr + @as(usize, base_offset) + @as(usize, @intCast(mid)) * 6;
        const id: c_int = @as(c_int, rvn_ttf_u16(record));
        if (id < glyph) {
            lo = mid + 1;
        } else if (id > glyph) {
            hi = mid - 1;
        } else {
            const first: c_int = @as(c_int, rvn_ttf_u16(record + 2));
            var count: c_int = @as(c_int, rvn_ttf_u16(record + 4));
            var i: c_int = 0;
            if (count > max) count = max;
            while (i < count) : (i += 1) {
                const k: usize = @intCast(i);
                const layer: [*c]const u8 = colr + @as(usize, layer_offset) + @as(usize, @intCast(first + i)) * 4;
                const palette_index: u16 = rvn_ttf_u16(layer + 2);
                glyphs[k] = @as(c_int, rvn_ttf_u16(layer));
                if (palette_index == 0xFFFF or palette_index >= entries) {
                    colors[k] = 0;
                } else {
                    // CPAL colors are B, G, R, A
                    const c: [*c]const u8 = cpal + @as(usize, color_offset) + (@as(usize, first_index) + @as(usize, palette_index)) * 4;
                    colors[k] = @as(u32, c[2]) | (@as(u32, c[1]) << 8) | (@as(u32, c[0]) << 16) | (@as(u32, c[3]) << 24);
                    if (colors[k] == 0) colors[k] = 1; // (transparent black is not "the text color")
                }
            }
            return count;
        }
    }
    return 0;
}

export fn rvn_ttf_open(data: [*c]const u8, size: usize) [*c]rvn_ttf_t {
    if (data == null or size < 12) return null;
    const offset: c_int = stb.stbtt_GetFontOffsetForIndex(data, 0);
    if (offset < 0) return null;
    const ttf: [*c]rvn_ttf_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_ttf_t))));
    if (stb.stbtt_InitFont(&ttf.*.info, data, offset) == 0) {
        base.rvn_free(ttf);
        return null;
    }
    // stbtt_ScaleForMappingEmToPixels(1) is 1 / unitsPerEm
    ttf.*.units_per_em = 1.0 / stb.stbtt_ScaleForMappingEmToPixels(&ttf.*.info, 1.0);
    ttf.*.colr = stbtt__find_table(@constCast(data), @intCast(offset), "COLR");
    ttf.*.cpal = stbtt__find_table(@constCast(data), @intCast(offset), "CPAL");
    if (ttf.*.colr != 0 and (@as(usize, ttf.*.colr) + 14 > size or @as(usize, rvn_ttf_u32(data + @as(usize, ttf.*.colr) + 4)) + @as(usize, ttf.*.colr) > size)) ttf.*.colr = 0;
    if (ttf.*.cpal != 0 and @as(usize, ttf.*.cpal) + 14 > size) ttf.*.cpal = 0;
    return ttf;
}

export fn rvn_ttf_close(ttf: [*c]rvn_ttf_t) void {
    base.rvn_free(ttf);
}

// 0 when the font has no glyph for the code point.
export fn rvn_ttf_glyph_index(ttf: [*c]rvn_ttf_t, codepoint: u32) c_int {
    return stb.stbtt_FindGlyphIndex(&ttf.*.info, @bitCast(codepoint));
}

// Horizontal advance as a fraction of the em size.
export fn rvn_ttf_advance(ttf: [*c]rvn_ttf_t, glyph: c_int) f32 {
    var advance: c_int = 0;
    var bearing: c_int = 0;
    stb.stbtt_GetGlyphHMetrics(&ttf.*.info, glyph, &advance, &bearing);
    return @as(f32, @floatFromInt(advance)) / ttf.*.units_per_em;
}

// Ascent, descent (positive) and line gap as fractions of the em size.
export fn rvn_ttf_vmetrics(ttf: [*c]rvn_ttf_t, ascent: [*c]f32, descent: [*c]f32, line_gap: [*c]f32) void {
    var a: c_int = 0;
    var d: c_int = 0;
    var g: c_int = 0;
    stb.stbtt_GetFontVMetrics(&ttf.*.info, &a, &d, &g);
    ascent.* = @as(f32, @floatFromInt(a)) / ttf.*.units_per_em;
    descent.* = @as(f32, @floatFromInt(-d)) / ttf.*.units_per_em;
    line_gap.* = @as(f32, @floatFromInt(g)) / ttf.*.units_per_em;
}

// Bitmap box of a glyph relative to the pen position on the baseline (y down).
export fn rvn_ttf_glyph_box(ttf: [*c]rvn_ttf_t, glyph: c_int, size_px: f32, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) void {
    const scale = stb.stbtt_ScaleForMappingEmToPixels(&ttf.*.info, size_px);
    stb.stbtt_GetGlyphBitmapBox(&ttf.*.info, glyph, scale, scale, x0, y0, x1, y1);
}

// Rasterizes a glyph as 8-bit coverage into `out` (width x height, `stride` bytes per row).
export fn rvn_ttf_render(ttf: [*c]rvn_ttf_t, glyph: c_int, size_px: f32, out: [*c]u8, width: c_int, height: c_int, stride: c_int) void {
    const scale = stb.stbtt_ScaleForMappingEmToPixels(&ttf.*.info, size_px);
    stb.stbtt_MakeGlyphBitmap(&ttf.*.info, out, width, height, stride, scale, scale, glyph);
}

// The same glyph with thicker strokes: the glyph and itself moved right by
// `spread` pixels (a part of a pixel is fine), both drawn from the outline so
// that the edges stay sharp. The bitmap must be ceil(spread) + 1 pixels wider
// than the box of the glyph.
export fn rvn_ttf_render_bold(ttf: [*c]rvn_ttf_t, glyph: c_int, size_px: f32, spread: f32, out: [*c]u8, width: c_int, height: c_int, stride: c_int) void {
    const scale = stb.stbtt_ScaleForMappingEmToPixels(&ttf.*.info, size_px);
    var ax0: c_int = undefined;
    var ay0: c_int = undefined;
    var ax1: c_int = undefined;
    var ay1: c_int = undefined;
    const copies: c_int = if (spread > 1.0) @intFromFloat(@ceil(spread)) else 1;
    var copy: c_int = 1;
    stb.stbtt_GetGlyphBitmapBox(&ttf.*.info, glyph, scale, scale, &ax0, &ay0, &ax1, &ay1);
    stb.stbtt_MakeGlyphBitmap(&ttf.*.info, out, width, height, stride, scale, scale, glyph);
    // the outline again, moved right by a part of a pixel (by steps of at most one), kept where it is the darker of the two
    while (copy <= copies) : (copy += 1) {
        const shift: f32 = spread * @as(f32, @floatFromInt(copy)) / @as(f32, @floatFromInt(copies));
        const whole: f32 = @floor(shift);
        var bx0: c_int = undefined;
        var by0: c_int = undefined;
        var bx1: c_int = undefined;
        var by1: c_int = undefined;
        stb.stbtt_GetGlyphBitmapBoxSubpixel(&ttf.*.info, glyph, scale, scale, shift - whole, 0.0, &bx0, &by0, &bx1, &by1);
        const w: c_int = bx1 - bx0;
        const h: c_int = by1 - by0;
        if (w <= 0 or h <= 0) continue;
        const moved: [*c]u8 = @ptrCast(base.rvn_calloc(@as(usize, @intCast(w)) * @as(usize, @intCast(h))));
        stb.stbtt_MakeGlyphBitmapSubpixel(&ttf.*.info, moved, w, h, w, scale, scale, shift - whole, 0.0, glyph);
        const dx: c_int = bx0 - ax0 + @as(c_int, @intFromFloat(whole));
        var y: c_int = 0;
        while (y < h) : (y += 1) {
            const oy: c_int = y + by0 - ay0;
            if (oy < 0 or oy >= height) continue;
            var x: c_int = 0;
            while (x < w) : (x += 1) {
                const ox: c_int = x + dx;
                if (ox < 0 or ox >= width) continue;
                const src: usize = @as(usize, @intCast(y)) * @as(usize, @intCast(w)) + @as(usize, @intCast(x));
                const dst: usize = @as(usize, @intCast(oy)) * @as(usize, @intCast(stride)) + @as(usize, @intCast(ox));
                if (moved[src] > out[dst]) {
                    out[dst] = moved[src];
                }
            }
        }
        base.rvn_free(moved);
    }
}
