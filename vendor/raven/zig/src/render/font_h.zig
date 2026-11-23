// Translated to Zig from vendor/raven/src/render/font.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/font.h
// Fonts, glyph cache, glyph atlas, text measuring and drawing.
//
// Glyphs are rasterized on demand at the exact pixel size requested (logical
// size x window scale) and packed into R8 atlas pages shared by all fonts.
//
// Threading: measuring and drawing may run on several threads at once (the
// paint jobs). The glyph caches are lock-free for reading (core/lfmap.h); a
// cache miss takes one mutex to rasterize the glyph. Atlas pages reach the
// GPU only in rvn_fonts_flush, on the UI thread.
//
// Note: `rvn_font_t` and `rvn_ttf_t` are opaque here (their structs are defined in font.c / font_raster.c);
// pointers to them are `?*rvn_font_t` / `?*rvn_ttf_t`.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const draw = @import("draw_h.zig");

pub const rvn_font_t = opaque {};
pub const struct_rvn_font_t = rvn_font_t;

/// Vertical metrics of a font at a given size, in the unit of that size.
pub const rvn_font_metrics_t = extern struct {
    ascent: f32,
    /// Positive distance below the baseline.
    descent: f32,
    line_height: f32,
};
pub const struct_rvn_font_metrics_t = rvn_font_metrics_t;

/// The size of every text, 1 = as designed (core/accessibility.c, Raccessibility_set_text_scale).
pub extern fn rvn_a11y_text_scale() f32;

pub extern fn rvn_fonts_init() void;
pub extern fn rvn_fonts_shutdown() void;

/// Resolves a font handle; R_INVALID_ID or a stale handle gives the theme / default font.
pub extern fn rvn_font_resolve(font: raven.Rid) ?*rvn_font_t;
pub const RVN_FONT_BOLD: u32 = 1;
pub const RVN_FONT_ITALIC: u32 = 2;
/// The font used for a style of a font (RVN_FONT_BOLD | RVN_FONT_ITALIC): the
/// one the application gave (Rfont_set_variant), else a view of the font that
/// draws its glyphs thicker and / or slanted, made on first use. UI thread
/// only: to call while measuring, not while painting.
pub extern fn rvn_font_variant(font: raven.Rid, style: u32) raven.Rid;
/// Resolves a size; 0 or less gives the theme font size.
pub extern fn rvn_font_size_resolve(size: f32) f32;

pub extern fn rvn_font_metrics(font: ?*rvn_font_t, size: f32, metrics: [*c]rvn_font_metrics_t) void;

/// Width of a single line of text. Linear in `size`, so it is independent of the window scale.
pub extern fn rvn_text_width(font: ?*rvn_font_t, size: f32, text: [*c]const u8, length: c_int) f32;

/// Byte offset of the character boundary closest to the horizontal position
/// `x` (same unit as `size`), for caret placement.
pub extern fn rvn_text_offset_at(font: ?*rvn_font_t, size: f32, text: [*c]const u8, length: c_int, x: f32) c_int;

/// Number of bytes of `text` that fit in `max_width` when breaking at spaces
/// (at least one character). Stops after a '\n'.
/// `line_width` receives the width of the returned part, without trailing spaces.
pub extern fn rvn_text_wrap(font: ?*rvn_font_t, size: f32, text: [*c]const u8, length: c_int, max_width: f32, line_width: [*c]f32) c_int;

/// Appends the glyphs of one line to a draw list.
/// `size_px`: Font size in pixels. `x`, `y`: Top-left corner of the line box, in pixels.
pub extern fn rvn_text_draw(list: [*c]draw.rvn_drawlist_t, font: ?*rvn_font_t, size_px: f32, x: f32, y: f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t, clip: base.rvn_box_t) void;

/// Creates and updates the GPU textures of the atlas pages changed since the last call. UI thread.
pub extern fn rvn_fonts_flush() void;

/// Replaces the atlas pseudo-handles of a finished draw list by real texture handles. UI thread.
pub extern fn rvn_fonts_resolve_pages(list: [*c]draw.rvn_drawlist_t) void;

// ---------------------------------------------------------------------------
//  TrueType glue (render/font_raster.c, wraps stb_truetype)
// ---------------------------------------------------------------------------

pub const rvn_ttf_t = opaque {};
pub const struct_rvn_ttf_t = rvn_ttf_t;

/// `data` must stay valid for the lifetime of the object. Returns NULL on invalid data.
pub extern fn rvn_ttf_open(data: [*c]const u8, size: usize) ?*rvn_ttf_t;
pub extern fn rvn_ttf_close(ttf: ?*rvn_ttf_t) void;
/// 0 when the font has no glyph for the code point.
pub extern fn rvn_ttf_glyph_index(ttf: ?*rvn_ttf_t, codepoint: u32) c_int;
/// Horizontal advance as a fraction of the em size.
pub extern fn rvn_ttf_advance(ttf: ?*rvn_ttf_t, glyph: c_int) f32;
/// Ascent, descent (positive) and line gap as fractions of the em size.
pub extern fn rvn_ttf_vmetrics(ttf: ?*rvn_ttf_t, ascent: [*c]f32, descent: [*c]f32, line_gap: [*c]f32) void;
/// Bitmap box of a glyph relative to the pen position on the baseline (y down).
pub extern fn rvn_ttf_glyph_box(ttf: ?*rvn_ttf_t, glyph: c_int, size_px: f32, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) void;
/// Rasterizes a glyph as 8-bit coverage into `out` (width x height, `stride` bytes per row).
pub extern fn rvn_ttf_render(ttf: ?*rvn_ttf_t, glyph: c_int, size_px: f32, out: [*c]u8, width: c_int, height: c_int, stride: c_int) void;
// The same glyph with thicker strokes: the glyph and itself moved right by
// `spread` pixels (a part of a pixel is fine), both drawn from the outline so
// that the edges stay sharp. The bitmap must be ceil(spread) + 1 pixels wider
// than the box of the glyph.   (the declaration, rvn_ttf_render_bold, comes below in font.h)
/// R_TRUE when the font has color glyphs (COLR / CPAL).
pub extern fn rvn_ttf_has_color(ttf: ?*rvn_ttf_t) c_int;
/// Layers of a color glyph: glyphs and colors (ABGR, 0 = the text color). 0 for a plain glyph.
pub extern fn rvn_ttf_color_layers(ttf: ?*rvn_ttf_t, glyph: c_int, glyphs: [*c]c_int, colors: [*c]u32, max: c_int) c_int;

// ---------------------------------------------------------------------------
//  Fonts of the system (render/font_system.c): where the characters that the
//  fonts of the application do not have are looked for.
// ---------------------------------------------------------------------------

/// Font files of the system that may have a character, the most likely
/// first: those made for its script, then the broad ones. Returns their count
/// (paths owned by font_system.c, valid until rvn_font_system_shutdown).
pub extern fn rvn_font_system_candidates(codepoint: u32, paths: [*c][*c]const u8, max: c_int) c_int;
pub extern fn rvn_font_system_shutdown() void;

pub extern fn rvn_ttf_render_bold(ttf: ?*rvn_ttf_t, glyph: c_int, size_px: f32, spread: f32, out: [*c]u8, width: c_int, height: c_int, stride: c_int) void;

/// Font embedded in the library (resources/default_font.c). Size is unknown to the header: take `&rvn_default_font_data`.
pub extern const rvn_default_font_data: [0]u8;
pub extern const rvn_default_font_size: usize;
/// Fixed-width font embedded in the library (resources/mono_font.c).
pub extern const rvn_mono_font_data: [0]u8;
pub extern const rvn_mono_font_size: usize;
