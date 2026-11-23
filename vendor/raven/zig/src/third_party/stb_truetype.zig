// Translated to Zig from vendor/raven/third_party/stb/stb_truetype.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// stb_truetype.h - v1.26 - public domain
// authored from 2009-2021 by Sean Barrett / RAD Game Tools
//
// =======================================================================
//
//    NO SECURITY GUARANTEE -- DO NOT USE THIS ON UNTRUSTED FONT FILES
//
// This library does no range checking of the offsets found in the file,
// meaning an attacker can use it to read arbitrary memory.
//
// =======================================================================
//
// Only the part Raven calls is translated (src/render/font_raster.c): font directory and
// table lookup, cmap lookup, glyph metrics and bounding boxes, glyph outlines (TrueType
// glyf and CFF Type 2 charstrings), curve flattening, the scanline rasterizer (rasterizer
// version 2, the default of the header) and the bitmap entry points. The STBTT_DEF
// functions are exported with the C signatures of the header; static helpers stay plain
// `fn`. The C macros STBTT_malloc / STBTT_free are rvn_alloc / rvn_free (as font_raster.c
// defines them), STBTT_assert is dropped, as in the C Release build (NDEBUG defined).

const std = @import("std");
const libc = @import("../sys/libc.zig");
const base = @import("../core/base_h.zig");

// ---- types of the header (typedefs of stb_truetype.h) ----

const stbtt_uint8 = u8;
const stbtt_uint16 = c_ushort;
const stbtt_int16 = c_short;
const stbtt_uint32 = c_uint;
const stbtt_int32 = c_int;

/// stbtt__buf: a view of a byte range (data, cursor, size). Private to the header.
const stbtt__buf = extern struct {
    data: [*c]u8,
    cursor: c_int,
    size: c_int,
};

/// struct stbtt_fontinfo: defined publicly so callers can declare one; treat it as opaque.
pub const stbtt_fontinfo = extern struct {
    userdata: ?*anyopaque,
    data: [*c]u8, // pointer to .ttf file
    fontstart: c_int, // offset of start of font

    numGlyphs: c_int, // number of glyphs, needed for range checking

    loca: c_int,
    head: c_int,
    glyf: c_int,
    hhea: c_int,
    hmtx: c_int,
    kern: c_int,
    gpos: c_int,
    svg: c_int, // table locations as offset from start of .ttf
    index_map: c_int, // a cmap mapping for our chosen character encoding
    indexToLocFormat: c_int, // format needed to map from glyph index to glyph

    cff: stbtt__buf, // cff font data
    charstrings: stbtt__buf, // the charstring index
    gsubrs: stbtt__buf, // global charstring subroutines index
    subrs: stbtt__buf, // private charstring subroutines index
    fontdicts: stbtt__buf, // array of font dicts
    fdselect: stbtt__buf, // map from glyph to fontdict
};

/// stbtt_vertex (the header's default: short coordinates).
pub const stbtt_vertex = extern struct {
    x: c_short,
    y: c_short,
    cx: c_short,
    cy: c_short,
    cx1: c_short,
    cy1: c_short,
    type: u8,
    padding: u8,
};

// enum { STBTT_vmove=1, STBTT_vline, STBTT_vcurve, STBTT_vcubic };
const STBTT_vmove: u8 = 1;
const STBTT_vline: u8 = 2;
const STBTT_vcurve: u8 = 3;
const STBTT_vcubic: u8 = 4;

/// stbtt__bitmap: the target of stbtt_Rasterize (1-channel bitmap).
pub const stbtt__bitmap = extern struct {
    w: c_int,
    h: c_int,
    stride: c_int,
    pixels: [*c]u8,
};

// enum { STBTT_PLATFORM_ID_UNICODE=0, STBTT_PLATFORM_ID_MAC=1, STBTT_PLATFORM_ID_ISO=2, STBTT_PLATFORM_ID_MICROSOFT=3 };
const STBTT_PLATFORM_ID_UNICODE: c_ushort = 0;
const STBTT_PLATFORM_ID_MICROSOFT: c_ushort = 3;
// enum { STBTT_UNICODE_EID_... } (encodingID for STBTT_PLATFORM_ID_UNICODE: any value is accepted)
// enum { STBTT_MS_EID_SYMBOL=0, STBTT_MS_EID_UNICODE_BMP=1, STBTT_MS_EID_SHIFTJIS=2, STBTT_MS_EID_UNICODE_FULL=10 };
const STBTT_MS_EID_UNICODE_BMP: c_ushort = 1;
const STBTT_MS_EID_UNICODE_FULL: c_ushort = 10;

// Pointer arithmetic on a C byte pointer: `data + off` in the C source.
inline fn ptrAt(p: [*c]u8, off: anytype) [*c]u8 {
    return p + @as(usize, @intCast(off));
}

// C casts of an int to a narrower type: keep the low bits (implementation-defined in C, two's complement here).
inline fn wrap16(x: c_int) c_short {
    return @bitCast(@as(c_ushort, @truncate(@as(c_uint, @bitCast(x)))));
}

inline fn wrapU8(x: c_int) u8 {
    return @truncate(@as(c_uint, @bitCast(x)));
}

// ---- stbtt__buf helpers to parse data from file ----

fn stbtt__buf_get8(b: *stbtt__buf) stbtt_uint8 {
    if (b.cursor >= b.size)
        return 0;
    const v = b.data[@intCast(b.cursor)];
    b.cursor += 1;
    return v;
}

fn stbtt__buf_peek8(b: *stbtt__buf) stbtt_uint8 {
    if (b.cursor >= b.size)
        return 0;
    return b.data[@intCast(b.cursor)];
}

fn stbtt__buf_seek(b: *stbtt__buf, o: c_int) void {
    b.cursor = if (o > b.size or o < 0) b.size else o;
}

fn stbtt__buf_skip(b: *stbtt__buf, o: c_int) void {
    stbtt__buf_seek(b, b.cursor + o);
}

fn stbtt__buf_get(b: *stbtt__buf, n: c_int) stbtt_uint32 {
    var v: stbtt_uint32 = 0;
    var i: c_int = 0;
    while (i < n) : (i += 1)
        v = (v << 8) | stbtt__buf_get8(b);
    return v;
}

fn stbtt__new_buf(p: ?*const anyopaque, size: usize) stbtt__buf {
    var r: stbtt__buf = undefined;
    r.data = @ptrCast(@constCast(p));
    r.size = @intCast(size);
    r.cursor = 0;
    return r;
}

fn stbtt__buf_get16(b: *stbtt__buf) stbtt_uint32 {
    return stbtt__buf_get(b, 2);
}

fn stbtt__buf_get32(b: *stbtt__buf) stbtt_uint32 {
    return stbtt__buf_get(b, 4);
}

fn stbtt__buf_range(b: *const stbtt__buf, o: c_int, s: c_int) stbtt__buf {
    var r = stbtt__new_buf(null, 0);
    if (o < 0 or s < 0 or o > b.size or s > b.size - o) return r;
    r.data = ptrAt(b.data, o);
    r.size = s;
    return r;
}

fn stbtt__cff_get_index(b: *stbtt__buf) stbtt__buf {
    var count: c_int = undefined;
    var offsize: c_int = undefined;
    const start: c_int = b.cursor;
    count = @bitCast(stbtt__buf_get16(b));
    if (count != 0) {
        offsize = stbtt__buf_get8(b);
        stbtt__buf_skip(b, offsize * count);
        stbtt__buf_skip(b, @as(c_int, @bitCast(stbtt__buf_get(b, offsize))) - 1);
    }
    return stbtt__buf_range(b, start, b.cursor - start);
}

fn stbtt__cff_int(b: *stbtt__buf) stbtt_uint32 {
    const b0: c_int = stbtt__buf_get8(b);
    if (b0 >= 32 and b0 <= 246) return @bitCast(b0 - 139);
    if (b0 >= 247 and b0 <= 250) return @bitCast((b0 - 247) * 256 + @as(c_int, stbtt__buf_get8(b)) + 108);
    if (b0 >= 251 and b0 <= 254) return @bitCast(-(b0 - 251) * 256 - @as(c_int, stbtt__buf_get8(b)) - 108);
    if (b0 == 28) return stbtt__buf_get16(b);
    if (b0 == 29) return stbtt__buf_get32(b);
    return 0;
}

fn stbtt__cff_skip_operand(b: *stbtt__buf) void {
    const b0: c_int = stbtt__buf_peek8(b);
    if (b0 == 30) {
        stbtt__buf_skip(b, 1);
        while (b.cursor < b.size) {
            const v: c_int = stbtt__buf_get8(b);
            if ((v & 0xF) == 0xF or (v >> 4) == 0xF)
                break;
        }
    } else {
        _ = stbtt__cff_int(b);
    }
}

fn stbtt__dict_get(b: *stbtt__buf, key: c_int) stbtt__buf {
    stbtt__buf_seek(b, 0);
    while (b.cursor < b.size) {
        const start: c_int = b.cursor;
        var op: c_int = undefined;
        while (@as(c_int, stbtt__buf_peek8(b)) >= 28)
            stbtt__cff_skip_operand(b);
        const end: c_int = b.cursor;
        op = stbtt__buf_get8(b);
        if (op == 12) op = @as(c_int, stbtt__buf_get8(b)) | 0x100;
        if (op == key) return stbtt__buf_range(b, start, end - start);
    }
    return stbtt__buf_range(b, 0, 0);
}

fn stbtt__dict_get_ints(b: *stbtt__buf, key: c_int, outcount: c_int, out: [*c]stbtt_uint32) void {
    var i: c_int = undefined;
    var operands = stbtt__dict_get(b, key);
    i = 0;
    while (i < outcount and operands.cursor < operands.size) : (i += 1) {
        out[@intCast(i)] = stbtt__cff_int(&operands);
    }
}

fn stbtt__cff_index_get(b_in: stbtt__buf, i: c_int) stbtt__buf {
    var b = b_in;
    var count: c_int = undefined;
    var offsize: c_int = undefined;
    var start: c_int = undefined;
    var end: c_int = undefined;
    stbtt__buf_seek(&b, 0);
    count = @bitCast(stbtt__buf_get16(&b));
    offsize = stbtt__buf_get8(&b);
    stbtt__buf_skip(&b, i * offsize);
    start = @bitCast(stbtt__buf_get(&b, offsize));
    end = @bitCast(stbtt__buf_get(&b, offsize));
    return stbtt__buf_range(&b, 2 + (count + 1) * offsize + start, end - start);
}

// ---- accessors to parse data from file (big endian) ----

fn ttBYTE(p: [*c]u8) u8 {
    return p.*;
}

fn ttUSHORT(p: [*c]u8) stbtt_uint16 {
    return @as(stbtt_uint16, p[0]) * 256 + p[1];
}

fn ttSHORT(p: [*c]u8) stbtt_int16 {
    return @bitCast(ttUSHORT(p));
}

fn ttULONG(p: [*c]u8) stbtt_uint32 {
    return (@as(stbtt_uint32, p[0]) << 24) + (@as(stbtt_uint32, p[1]) << 16) + (@as(stbtt_uint32, p[2]) << 8) + p[3];
}

fn ttLONG(p: [*c]u8) stbtt_int32 {
    return @bitCast(ttULONG(p));
}

fn stbtt_tag4(p: [*c]const u8, c0: u8, c1: u8, c2: u8, c3: u8) bool {
    return p[0] == c0 and p[1] == c1 and p[2] == c2 and p[3] == c3;
}

fn stbtt_tag(p: [*c]const u8, str: [*c]const u8) bool {
    return stbtt_tag4(p, str[0], str[1], str[2], str[3]);
}

fn stbtt__isfont(font: [*c]stbtt_uint8) c_int {
    // check the version number
    if (stbtt_tag4(font, '1', 0, 0, 0)) return 1; // TrueType 1
    if (stbtt_tag(font, "typ1")) return 1; // TrueType with type 1 font -- we don't support this!
    if (stbtt_tag(font, "OTTO")) return 1; // OpenType with CFF
    if (stbtt_tag4(font, 0, 1, 0, 0)) return 1; // OpenType 1.0
    if (stbtt_tag(font, "true")) return 1; // Apple specification for TrueType fonts
    return 0;
}

// @OPTIMIZE: binary search
fn stbtt__find_table(data: [*c]stbtt_uint8, fontstart: stbtt_uint32, tag: [*c]const u8) stbtt_uint32 {
    const num_tables: stbtt_int32 = ttUSHORT(ptrAt(data, fontstart + 4));
    const tabledir: stbtt_uint32 = fontstart + 12;
    var i: stbtt_int32 = 0;
    while (i < num_tables) : (i += 1) {
        const loc: stbtt_uint32 = tabledir + 16 * @as(stbtt_uint32, @intCast(i));
        if (stbtt_tag(ptrAt(data, loc + 0), tag))
            return ttULONG(ptrAt(data, loc + 8));
    }
    return 0;
}

fn stbtt_GetFontOffsetForIndex_internal(font_collection: [*c]u8, index: c_int) c_int {
    // if it's just a font, there's only one valid index
    if (stbtt__isfont(font_collection) != 0)
        return if (index == 0) 0 else -1;

    // check if it's a TTC
    if (stbtt_tag(font_collection, "ttcf")) {
        // version 1?
        if (ttULONG(ptrAt(font_collection, 4)) == 0x00010000 or ttULONG(ptrAt(font_collection, 4)) == 0x00020000) {
            const n: stbtt_int32 = ttLONG(ptrAt(font_collection, 8));
            if (index >= n)
                return -1;
            return @bitCast(ttULONG(ptrAt(font_collection, 12 + @as(c_uint, @intCast(index)) * 4)));
        }
    }
    return -1;
}

fn stbtt__get_subrs(cff: stbtt__buf, fontdict: stbtt__buf) stbtt__buf {
    var subrsoff: stbtt_uint32 = 0;
    var private_loc: [2]stbtt_uint32 = .{ 0, 0 };
    var cf = cff;
    var fd = fontdict;
    var pdict: stbtt__buf = undefined;
    stbtt__dict_get_ints(&fd, 18, 2, &private_loc);
    if (private_loc[1] == 0 or private_loc[0] == 0) return stbtt__new_buf(null, 0);
    pdict = stbtt__buf_range(&cf, @bitCast(private_loc[1]), @bitCast(private_loc[0]));
    stbtt__dict_get_ints(&pdict, 19, 1, &subrsoff);
    if (subrsoff == 0) return stbtt__new_buf(null, 0);
    stbtt__buf_seek(&cf, @bitCast(private_loc[1] + subrsoff));
    return stbtt__cff_get_index(&cf);
}

fn stbtt_InitFont_internal(info: [*c]stbtt_fontinfo, data: [*c]u8, fontstart: c_int) c_int {
    var cmap: stbtt_uint32 = undefined;
    var t: stbtt_uint32 = undefined;
    var i: stbtt_int32 = undefined;
    var numTables: stbtt_int32 = undefined;
    const fs: stbtt_uint32 = @bitCast(fontstart);

    info.*.data = data;
    info.*.fontstart = fontstart;
    info.*.cff = stbtt__new_buf(null, 0);

    cmap = stbtt__find_table(data, fs, "cmap"); // required
    info.*.loca = @bitCast(stbtt__find_table(data, fs, "loca")); // required
    info.*.head = @bitCast(stbtt__find_table(data, fs, "head")); // required
    info.*.glyf = @bitCast(stbtt__find_table(data, fs, "glyf")); // required
    info.*.hhea = @bitCast(stbtt__find_table(data, fs, "hhea")); // required
    info.*.hmtx = @bitCast(stbtt__find_table(data, fs, "hmtx")); // required
    info.*.kern = @bitCast(stbtt__find_table(data, fs, "kern")); // not required
    info.*.gpos = @bitCast(stbtt__find_table(data, fs, "GPOS")); // not required

    if (cmap == 0 or info.*.head == 0 or info.*.hhea == 0 or info.*.hmtx == 0)
        return 0;
    if (info.*.glyf != 0) {
        // required for truetype
        if (info.*.loca == 0) return 0;
    } else {
        // initialization for CFF / Type2 fonts (OTF)
        var b: stbtt__buf = undefined;
        var topdict: stbtt__buf = undefined;
        var topdictidx: stbtt__buf = undefined;
        var cstype: stbtt_uint32 = 2;
        var charstrings: stbtt_uint32 = 0;
        var fdarrayoff: stbtt_uint32 = 0;
        var fdselectoff: stbtt_uint32 = 0;
        var cff: stbtt_uint32 = undefined;

        cff = stbtt__find_table(data, fs, "CFF ");
        if (cff == 0) return 0;

        info.*.fontdicts = stbtt__new_buf(null, 0);
        info.*.fdselect = stbtt__new_buf(null, 0);

        // @TODO this should use size from table (not 512MB)
        info.*.cff = stbtt__new_buf(ptrAt(data, cff), 512 * 1024 * 1024);
        b = info.*.cff;

        // read the header
        stbtt__buf_skip(&b, 2);
        stbtt__buf_seek(&b, stbtt__buf_get8(&b)); // hdrsize

        // @TODO the name INDEX could list multiple fonts,
        // but we just use the first one.
        _ = stbtt__cff_get_index(&b); // name INDEX
        topdictidx = stbtt__cff_get_index(&b);
        topdict = stbtt__cff_index_get(topdictidx, 0);
        _ = stbtt__cff_get_index(&b); // string INDEX
        info.*.gsubrs = stbtt__cff_get_index(&b);

        stbtt__dict_get_ints(&topdict, 17, 1, &charstrings);
        stbtt__dict_get_ints(&topdict, 0x100 | 6, 1, &cstype);
        stbtt__dict_get_ints(&topdict, 0x100 | 36, 1, &fdarrayoff);
        stbtt__dict_get_ints(&topdict, 0x100 | 37, 1, &fdselectoff);
        info.*.subrs = stbtt__get_subrs(b, topdict);

        // we only support Type 2 charstrings
        if (cstype != 2) return 0;
        if (charstrings == 0) return 0;

        if (fdarrayoff != 0) {
            // looks like a CID font
            if (fdselectoff == 0) return 0;
            stbtt__buf_seek(&b, @bitCast(fdarrayoff));
            info.*.fontdicts = stbtt__cff_get_index(&b);
            info.*.fdselect = stbtt__buf_range(&b, @bitCast(fdselectoff), b.size - @as(c_int, @bitCast(fdselectoff)));
        }

        stbtt__buf_seek(&b, @bitCast(charstrings));
        info.*.charstrings = stbtt__cff_get_index(&b);
    }

    t = stbtt__find_table(data, fs, "maxp");
    if (t != 0)
        info.*.numGlyphs = @bitCast(@as(stbtt_uint32, ttUSHORT(ptrAt(data, t + 4))))
    else
        info.*.numGlyphs = 0xffff;

    info.*.svg = -1;

    // find a cmap encoding table we understand *now* to avoid searching
    // later. (todo: could make this installable)
    // the same regardless of glyph.
    numTables = ttUSHORT(ptrAt(data, cmap + 2));
    info.*.index_map = 0;
    i = 0;
    while (i < numTables) : (i += 1) {
        const encoding_record: stbtt_uint32 = cmap + 4 + 8 * @as(stbtt_uint32, @intCast(i));
        // find an encoding we understand:
        switch (ttUSHORT(ptrAt(data, encoding_record))) {
            STBTT_PLATFORM_ID_MICROSOFT => switch (ttUSHORT(ptrAt(data, encoding_record + 2))) {
                STBTT_MS_EID_UNICODE_BMP, STBTT_MS_EID_UNICODE_FULL => {
                    // MS/Unicode
                    info.*.index_map = @bitCast(cmap + ttULONG(ptrAt(data, encoding_record + 4)));
                },
                else => {},
            },
            STBTT_PLATFORM_ID_UNICODE => {
                // Mac/iOS has these
                // all the encodingIDs are unicode, so we don't bother to check it
                info.*.index_map = @bitCast(cmap + ttULONG(ptrAt(data, encoding_record + 4)));
            },
            else => {},
        }
    }
    if (info.*.index_map == 0)
        return 0;

    info.*.indexToLocFormat = @bitCast(@as(stbtt_uint32, ttUSHORT(ptrAt(data, @as(stbtt_uint32, @bitCast(info.*.head)) + 50))));
    return 1;
}

pub fn stbtt_GetFontOffsetForIndex(data: [*c]const u8, index: c_int) c_int {
    return stbtt_GetFontOffsetForIndex_internal(@constCast(data), index);
}

pub fn stbtt_InitFont(info: [*c]stbtt_fontinfo, data: [*c]const u8, offset: c_int) c_int {
    return stbtt_InitFont_internal(info, @constCast(data), offset);
}

pub fn stbtt_FindGlyphIndex(info: [*c]const stbtt_fontinfo, unicode_codepoint: c_int) c_int {
    const data: [*c]u8 = info.*.data;
    const index_map: stbtt_uint32 = @bitCast(info.*.index_map);

    const format: stbtt_uint16 = ttUSHORT(ptrAt(data, index_map + 0));
    if (format == 0) { // apple byte encoding
        const bytes: stbtt_int32 = ttUSHORT(ptrAt(data, index_map + 2));
        if (unicode_codepoint < bytes - 6)
            return ttBYTE(ptrAt(data, @as(c_int, @bitCast(index_map)) + 6 + unicode_codepoint));
        return 0;
    } else if (format == 6) {
        const first: stbtt_uint32 = ttUSHORT(ptrAt(data, index_map + 6));
        const count: stbtt_uint32 = ttUSHORT(ptrAt(data, index_map + 8));
        const ucp: stbtt_uint32 = @bitCast(unicode_codepoint);
        if (ucp >= first and ucp < first + count)
            return @bitCast(@as(stbtt_uint32, ttUSHORT(ptrAt(data, index_map + 10 + (ucp - first) * 2))));
        return 0;
    } else if (format == 2) {
        // @TODO: high-byte mapping for japanese/chinese/korean
        return 0;
    } else if (format == 4) { // standard mapping for windows fonts: binary search collection of ranges
        const segcount: stbtt_uint16 = ttUSHORT(ptrAt(data, index_map + 6)) >> 1;
        var searchRange: stbtt_uint16 = ttUSHORT(ptrAt(data, index_map + 8)) >> 1;
        var entrySelector: stbtt_uint16 = ttUSHORT(ptrAt(data, index_map + 10));
        const rangeShift: stbtt_uint16 = ttUSHORT(ptrAt(data, index_map + 12)) >> 1;

        // do a binary search of the segments
        const endCount: stbtt_uint32 = index_map + 14;
        var search: stbtt_uint32 = endCount;

        if (unicode_codepoint > 0xffff)
            return 0;

        // they lie from endCount .. endCount + segCount
        // but searchRange is the nearest power of two, so...
        if (unicode_codepoint >= @as(stbtt_int32, ttUSHORT(ptrAt(data, search + @as(stbtt_uint32, rangeShift) * 2))))
            search += @as(stbtt_uint32, rangeShift) * 2;

        // now decrement to bias correctly to find smallest
        search -= 2;
        while (entrySelector != 0) {
            var end: stbtt_uint16 = undefined;
            searchRange >>= 1;
            end = ttUSHORT(ptrAt(data, search + @as(stbtt_uint32, searchRange) * 2));
            if (unicode_codepoint > @as(stbtt_int32, end))
                search += @as(stbtt_uint32, searchRange) * 2;
            entrySelector -= 1;
        }
        search += 2;

        {
            var offset: stbtt_uint16 = undefined;
            var start: stbtt_uint16 = undefined;
            var last: stbtt_uint16 = undefined;
            const item: stbtt_uint16 = @truncate((search - endCount) >> 1);

            start = ttUSHORT(ptrAt(data, index_map + 14 + @as(stbtt_uint32, segcount) * 2 + 2 + 2 * @as(stbtt_uint32, item)));
            last = ttUSHORT(ptrAt(data, endCount + 2 * @as(stbtt_uint32, item)));
            if (unicode_codepoint < @as(stbtt_int32, start) or unicode_codepoint > @as(stbtt_int32, last))
                return 0;

            offset = ttUSHORT(ptrAt(data, index_map + 14 + @as(stbtt_uint32, segcount) * 6 + 2 + 2 * @as(stbtt_uint32, item)));
            if (offset == 0)
                return @as(stbtt_int32, @as(c_ushort, @truncate(@as(c_uint, @bitCast(unicode_codepoint + ttSHORT(ptrAt(data, index_map + 14 + @as(stbtt_uint32, segcount) * 4 + 2 + 2 * @as(stbtt_uint32, item))))))));

            return @as(stbtt_int32, ttUSHORT(ptrAt(data, @as(stbtt_uint32, offset) + @as(stbtt_uint32, @intCast(unicode_codepoint - @as(stbtt_int32, start))) * 2 + index_map + 14 + @as(stbtt_uint32, segcount) * 6 + 2 + 2 * @as(stbtt_uint32, item))));
        }
    } else if (format == 12 or format == 13) {
        const ngroups: stbtt_uint32 = ttULONG(ptrAt(data, index_map + 12));
        var low: stbtt_int32 = undefined;
        var high: stbtt_int32 = undefined;
        low = 0;
        high = @bitCast(ngroups);
        // Binary search the right group.
        while (low < high) {
            const mid: stbtt_int32 = low + ((high - low) >> 1); // rounds down, so low <= mid < high
            const mid_u: stbtt_uint32 = @bitCast(mid);
            const start_char: stbtt_uint32 = ttULONG(ptrAt(data, index_map + 16 + mid_u * 12));
            const end_char: stbtt_uint32 = ttULONG(ptrAt(data, index_map + 16 + mid_u * 12 + 4));
            const ucp: stbtt_uint32 = @bitCast(unicode_codepoint);
            if (ucp < start_char) {
                high = mid;
            } else if (ucp > end_char) {
                low = mid + 1;
            } else {
                const start_glyph: stbtt_uint32 = ttULONG(ptrAt(data, index_map + 16 + mid_u * 12 + 8));
                if (format == 12)
                    return @bitCast(start_glyph + ucp - start_char)
                else // format == 13
                    return @bitCast(start_glyph);
            }
        }
        return 0; // not found
    }
    // @TODO
    return 0;
}

fn stbtt_setvertex(v: [*c]stbtt_vertex, type_: stbtt_uint8, x: stbtt_int32, y: stbtt_int32, cx: stbtt_int32, cy: stbtt_int32) void {
    v.*.type = type_;
    v.*.x = wrap16(x);
    v.*.y = wrap16(y);
    v.*.cx = wrap16(cx);
    v.*.cy = wrap16(cy);
}

fn stbtt__GetGlyfOffset(info: [*c]const stbtt_fontinfo, glyph_index: c_int) c_int {
    var g1: c_int = undefined;
    var g2: c_int = undefined;


    if (glyph_index >= info.*.numGlyphs) return -1; // glyph index out of range
    if (info.*.indexToLocFormat >= 2) return -1; // unknown index->glyph map format

    if (info.*.indexToLocFormat == 0) {
        g1 = info.*.glyf + @as(c_int, @bitCast(@as(stbtt_uint32, ttUSHORT(ptrAt(info.*.data, info.*.loca + glyph_index * 2))))) * 2;
        g2 = info.*.glyf + @as(c_int, @bitCast(@as(stbtt_uint32, ttUSHORT(ptrAt(info.*.data, info.*.loca + glyph_index * 2 + 2))))) * 2;
    } else {
        g1 = @bitCast(@as(stbtt_uint32, @bitCast(info.*.glyf)) +% ttULONG(ptrAt(info.*.data, info.*.loca + glyph_index * 4)));
        g2 = @bitCast(@as(stbtt_uint32, @bitCast(info.*.glyf)) +% ttULONG(ptrAt(info.*.data, info.*.loca + glyph_index * 4 + 4)));
    }

    return if (g1 == g2) -1 else g1; // if length is 0, return -1
}

pub fn stbtt_GetGlyphBox(info: [*c]const stbtt_fontinfo, glyph_index: c_int, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) c_int {
    if (info.*.cff.size != 0) {
        _ = stbtt__GetGlyphInfoT2(info, glyph_index, x0, y0, x1, y1);
    } else {
        const g: c_int = stbtt__GetGlyfOffset(info, glyph_index);
        if (g < 0) return 0;

        if (x0 != null) x0.* = ttSHORT(ptrAt(info.*.data, g + 2));
        if (y0 != null) y0.* = ttSHORT(ptrAt(info.*.data, g + 4));
        if (x1 != null) x1.* = ttSHORT(ptrAt(info.*.data, g + 6));
        if (y1 != null) y1.* = ttSHORT(ptrAt(info.*.data, g + 8));
    }
    return 1;
}

fn stbtt__close_shape(vertices: [*c]stbtt_vertex, num_vertices_in: c_int, was_off: c_int, start_off: c_int, sx: stbtt_int32, sy: stbtt_int32, scx: stbtt_int32, scy: stbtt_int32, cx: stbtt_int32, cy: stbtt_int32) c_int {
    var num_vertices = num_vertices_in;
    if (start_off != 0) {
        if (was_off != 0) {
            stbtt_setvertex(&vertices[@intCast(num_vertices)], STBTT_vcurve, (cx + scx) >> 1, (cy + scy) >> 1, cx, cy);
            num_vertices += 1;
        }
        stbtt_setvertex(&vertices[@intCast(num_vertices)], STBTT_vcurve, sx, sy, scx, scy);
        num_vertices += 1;
    } else {
        if (was_off != 0) {
            stbtt_setvertex(&vertices[@intCast(num_vertices)], STBTT_vcurve, sx, sy, cx, cy);
            num_vertices += 1;
        } else {
            stbtt_setvertex(&vertices[@intCast(num_vertices)], STBTT_vline, sx, sy, 0, 0);
            num_vertices += 1;
        }
    }
    return num_vertices;
}

fn ttCHAR(p: [*c]u8) i8 {
    return @bitCast(p.*);
}

fn stbtt__GetGlyphShapeTT(info: [*c]const stbtt_fontinfo, glyph_index: c_int, pvertices: [*c][*c]stbtt_vertex) c_int {
    var numberOfContours: stbtt_int16 = undefined;
    var endPtsOfContours: [*c]stbtt_uint8 = undefined;
    const data: [*c]stbtt_uint8 = info.*.data;
    var vertices: [*c]stbtt_vertex = null;
    var num_vertices: c_int = 0;
    const g: c_int = stbtt__GetGlyfOffset(info, glyph_index);

    pvertices.* = null;

    if (g < 0) return 0;

    numberOfContours = ttSHORT(ptrAt(data, g));

    if (numberOfContours > 0) {
        var flags: stbtt_uint8 = 0;
        var flagcount: stbtt_uint8 = undefined;
        var ins: c_int = undefined;
        var i: c_int = undefined;
        var j: c_int = 0;
        var m: c_int = undefined;
        var n: c_int = undefined;
        var next_move: c_int = undefined;
        var was_off: c_int = 0;
        var off: c_int = undefined;
        var start_off: c_int = 0;
        var x: c_int = undefined;
        var y: c_int = undefined;
        var cx: c_int = undefined;
        var cy: c_int = undefined;
        var sx: c_int = undefined;
        var sy: c_int = undefined;
        var scx: c_int = undefined;
        var scy: c_int = undefined;
        var points: [*c]stbtt_uint8 = undefined;
        endPtsOfContours = ptrAt(data, g + 10);
        ins = ttUSHORT(ptrAt(data, g + 10 + @as(c_int, numberOfContours) * 2));
        points = ptrAt(data, g + 10 + @as(c_int, numberOfContours) * 2 + 2 + ins);

        n = 1 + @as(c_int, ttUSHORT(ptrAt(endPtsOfContours, @as(c_int, numberOfContours) * 2 - 2)));

        m = n + 2 * @as(c_int, numberOfContours); // a loose bound on how many vertices we might need
        vertices = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(m)) * @sizeOf(stbtt_vertex))));
        if (vertices == null)
            return 0;

        next_move = 0;
        flagcount = 0;

        // in first pass, we load uninterpreted data into the allocated array
        // above, shifted to the end of the array so we won't overwrite it when
        // we create our final data starting from the front

        off = m - n; // starting offset for uninterpreted data, regardless of how m ends up being calculated

        // first load flags

        i = 0;
        while (i < n) : (i += 1) {
            if (flagcount == 0) {
                flags = points[0];
                points += 1;
                if ((flags & 8) != 0) {
                    flagcount = points[0];
                    points += 1;
                }
            } else {
                flagcount -= 1;
            }
            vertices[@intCast(off + i)].type = flags;
        }

        // now load x coordinates
        x = 0;
        i = 0;
        while (i < n) : (i += 1) {
            flags = vertices[@intCast(off + i)].type;
            if ((flags & 2) != 0) {
                const dx: stbtt_int16 = points[0];
                points += 1;
                x += if ((flags & 16) != 0) @as(c_int, dx) else -@as(c_int, dx); // ???
            } else {
                if ((flags & 16) == 0) {
                    x = x + @as(c_int, ttSHORT(points));
                    points += 2;
                }
            }
            vertices[@intCast(off + i)].x = wrap16(x);
        }

        // now load y coordinates
        y = 0;
        i = 0;
        while (i < n) : (i += 1) {
            flags = vertices[@intCast(off + i)].type;
            if ((flags & 4) != 0) {
                const dy: stbtt_int16 = points[0];
                points += 1;
                y += if ((flags & 32) != 0) @as(c_int, dy) else -@as(c_int, dy); // ???
            } else {
                if ((flags & 32) == 0) {
                    y = y + @as(c_int, ttSHORT(points));
                    points += 2;
                }
            }
            vertices[@intCast(off + i)].y = wrap16(y);
        }

        // now convert them to our format
        num_vertices = 0;
        sx = 0;
        sy = 0;
        cx = 0;
        cy = 0;
        scx = 0;
        scy = 0;
        i = 0;
        while (i < n) : (i += 1) {
            flags = vertices[@intCast(off + i)].type;
            x = vertices[@intCast(off + i)].x;
            y = vertices[@intCast(off + i)].y;

            if (next_move == i) {
                if (i != 0)
                    num_vertices = stbtt__close_shape(vertices, num_vertices, was_off, start_off, sx, sy, scx, scy, cx, cy);

                // now start the new one
                start_off = if ((flags & 1) == 0) 1 else 0;
                if (start_off != 0) {
                    // if we start off with an off-curve point, then when we need to find a point on the curve
                    // where we can start, and we need to save some state for when we wraparound.
                    scx = x;
                    scy = y;
                    if ((vertices[@intCast(off + i + 1)].type & 1) == 0) {
                        // next point is also a curve point, so interpolate an on-point curve
                        sx = (x + @as(c_int, vertices[@intCast(off + i + 1)].x)) >> 1;
                        sy = (y + @as(c_int, vertices[@intCast(off + i + 1)].y)) >> 1;
                    } else {
                        // otherwise just use the next point as our start point
                        sx = @as(c_int, vertices[@intCast(off + i + 1)].x);
                        sy = @as(c_int, vertices[@intCast(off + i + 1)].y);
                        i += 1; // we're using point i+1 as the starting point, so skip it
                    }
                } else {
                    sx = x;
                    sy = y;
                }
                stbtt_setvertex(&vertices[@intCast(num_vertices)], STBTT_vmove, sx, sy, 0, 0);
                num_vertices += 1;
                was_off = 0;
                next_move = 1 + @as(c_int, ttUSHORT(ptrAt(endPtsOfContours, j * 2)));
                j += 1;
            } else {
                if ((flags & 1) == 0) { // if it's a curve
                    if (was_off != 0) { // two off-curve control points in a row means interpolate an on-curve midpoint
                        stbtt_setvertex(&vertices[@intCast(num_vertices)], STBTT_vcurve, (cx + x) >> 1, (cy + y) >> 1, cx, cy);
                        num_vertices += 1;
                    }
                    cx = x;
                    cy = y;
                    was_off = 1;
                } else {
                    if (was_off != 0) {
                        stbtt_setvertex(&vertices[@intCast(num_vertices)], STBTT_vcurve, x, y, cx, cy);
                    } else {
                        stbtt_setvertex(&vertices[@intCast(num_vertices)], STBTT_vline, x, y, 0, 0);
                    }
                    num_vertices += 1;
                    was_off = 0;
                }
            }
        }
        num_vertices = stbtt__close_shape(vertices, num_vertices, was_off, start_off, sx, sy, scx, scy, cx, cy);
    } else if (numberOfContours < 0) {
        // Compound shapes.
        var more: bool = true;
        var comp: [*c]stbtt_uint8 = ptrAt(data, g + 10);
        num_vertices = 0;
        vertices = null;
        while (more) {
            var flags: stbtt_uint16 = undefined;
            var gidx: stbtt_uint16 = undefined;
            var comp_num_verts: c_int = 0;
            var i: c_int = undefined;
            var comp_verts: [*c]stbtt_vertex = null;
            var tmp: [*c]stbtt_vertex = null;
            var mtx: [6]f32 = .{ 1, 0, 0, 1, 0, 0 };
            var m: f32 = undefined;
            var n: f32 = undefined;

            flags = @bitCast(ttSHORT(comp));
            comp += 2;
            gidx = @bitCast(ttSHORT(comp));
            comp += 2;

            if ((flags & 2) != 0) { // XY values
                if ((flags & 1) != 0) { // shorts
                    mtx[4] = @floatFromInt(ttSHORT(comp));
                    comp += 2;
                    mtx[5] = @floatFromInt(ttSHORT(comp));
                    comp += 2;
                } else {
                    mtx[4] = @floatFromInt(ttCHAR(comp));
                    comp += 1;
                    mtx[5] = @floatFromInt(ttCHAR(comp));
                    comp += 1;
                }
            } else {
                // @TODO handle matching point
            }
            if ((flags & (1 << 3)) != 0) { // WE_HAVE_A_SCALE
                mtx[0] = @as(f32, @floatFromInt(ttSHORT(comp))) / 16384.0;
                mtx[3] = mtx[0];
                comp += 2;
                mtx[1] = 0;
                mtx[2] = 0;
            } else if ((flags & (1 << 6)) != 0) { // WE_HAVE_AN_X_AND_YSCALE
                mtx[0] = @as(f32, @floatFromInt(ttSHORT(comp))) / 16384.0;
                comp += 2;
                mtx[1] = 0;
                mtx[2] = 0;
                mtx[3] = @as(f32, @floatFromInt(ttSHORT(comp))) / 16384.0;
                comp += 2;
            } else if ((flags & (1 << 7)) != 0) { // WE_HAVE_A_TWO_BY_TWO
                mtx[0] = @as(f32, @floatFromInt(ttSHORT(comp))) / 16384.0;
                comp += 2;
                mtx[1] = @as(f32, @floatFromInt(ttSHORT(comp))) / 16384.0;
                comp += 2;
                mtx[2] = @as(f32, @floatFromInt(ttSHORT(comp))) / 16384.0;
                comp += 2;
                mtx[3] = @as(f32, @floatFromInt(ttSHORT(comp))) / 16384.0;
                comp += 2;
            }

            // Find transformation scales.
            m = @floatCast(@sqrt(@as(f64, mtx[0] * mtx[0] + mtx[1] * mtx[1])));
            n = @floatCast(@sqrt(@as(f64, mtx[2] * mtx[2] + mtx[3] * mtx[3])));

            // Get indexed glyph.
            comp_num_verts = stbtt_GetGlyphShape(info, @as(c_int, gidx), &comp_verts);
            if (comp_num_verts > 0) {
                // Transform vertices.
                i = 0;
                while (i < comp_num_verts) : (i += 1) {
                    const v: [*c]stbtt_vertex = &comp_verts[@intCast(i)];
                    var xs: c_short = v.*.x;
                    var ys: c_short = v.*.y;
                    v.*.x = @intFromFloat(m * (mtx[0] * @as(f32, @floatFromInt(xs)) + mtx[2] * @as(f32, @floatFromInt(ys)) + mtx[4]));
                    v.*.y = @intFromFloat(n * (mtx[1] * @as(f32, @floatFromInt(xs)) + mtx[3] * @as(f32, @floatFromInt(ys)) + mtx[5]));
                    xs = v.*.cx;
                    ys = v.*.cy;
                    v.*.cx = @intFromFloat(m * (mtx[0] * @as(f32, @floatFromInt(xs)) + mtx[2] * @as(f32, @floatFromInt(ys)) + mtx[4]));
                    v.*.cy = @intFromFloat(n * (mtx[1] * @as(f32, @floatFromInt(xs)) + mtx[3] * @as(f32, @floatFromInt(ys)) + mtx[5]));
                }
                // Append vertices.
                tmp = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(num_vertices + comp_num_verts)) * @sizeOf(stbtt_vertex))));
                if (tmp == null) {
                    if (vertices != null) base.rvn_free(vertices);
                    if (comp_verts != null) base.rvn_free(comp_verts);
                    return 0;
                }
                if (num_vertices > 0 and vertices != null)
                    _ = libc.memcpy(tmp, vertices, @as(usize, @intCast(num_vertices)) * @sizeOf(stbtt_vertex));
                _ = libc.memcpy(tmp + @as(usize, @intCast(num_vertices)), comp_verts, @as(usize, @intCast(comp_num_verts)) * @sizeOf(stbtt_vertex));
                if (vertices != null) base.rvn_free(vertices);
                vertices = tmp;
                base.rvn_free(comp_verts);
                num_vertices += comp_num_verts;
            }
            // More components ?
            more = (flags & (1 << 5)) != 0;
        }
    } else {
        // numberOfCounters == 0, do nothing
    }

    pvertices.* = vertices;
    return num_vertices;
}

fn stbtt__cff_index_count(b: *stbtt__buf) c_int {
    stbtt__buf_seek(b, 0);
    return @bitCast(stbtt__buf_get16(b));
}

// ---- CFF / Type 2 charstrings ----

const stbtt__csctx = struct {
    bounds: c_int,
    started: c_int,
    first_x: f32,
    first_y: f32,
    x: f32,
    y: f32,
    min_x: stbtt_int32,
    max_x: stbtt_int32,
    min_y: stbtt_int32,
    max_y: stbtt_int32,

    pvertices: [*c]stbtt_vertex,
    num_vertices: c_int,
};

// #define STBTT__CSCTX_INIT(bounds) {bounds,0, 0,0, 0,0, 0,0,0,0, NULL, 0}
fn stbtt__CSCTX_INIT(bounds: c_int) stbtt__csctx {
    return .{
        .bounds = bounds,
        .started = 0,
        .first_x = 0,
        .first_y = 0,
        .x = 0,
        .y = 0,
        .min_x = 0,
        .max_x = 0,
        .min_y = 0,
        .max_y = 0,
        .pvertices = null,
        .num_vertices = 0,
    };
}

fn stbtt__track_vertex(c: *stbtt__csctx, x: stbtt_int32, y: stbtt_int32) void {
    if (x > c.max_x or c.started == 0) c.max_x = x;
    if (y > c.max_y or c.started == 0) c.max_y = y;
    if (x < c.min_x or c.started == 0) c.min_x = x;
    if (y < c.min_y or c.started == 0) c.min_y = y;
    c.started = 1;
}

fn stbtt__csctx_v(c: *stbtt__csctx, type_: stbtt_uint8, x: stbtt_int32, y: stbtt_int32, cx: stbtt_int32, cy: stbtt_int32, cx1: stbtt_int32, cy1: stbtt_int32) void {
    if (c.bounds != 0) {
        stbtt__track_vertex(c, x, y);
        if (type_ == STBTT_vcubic) {
            stbtt__track_vertex(c, cx, cy);
            stbtt__track_vertex(c, cx1, cy1);
        }
    } else {
        const idx: usize = @intCast(c.num_vertices);
        stbtt_setvertex(&c.pvertices[idx], type_, x, y, cx, cy);
        c.pvertices[idx].cx1 = wrap16(cx1);
        c.pvertices[idx].cy1 = wrap16(cy1);
    }
    c.num_vertices += 1;
}

fn stbtt__csctx_close_shape(ctx: *stbtt__csctx) void {
    if (ctx.first_x != ctx.x or ctx.first_y != ctx.y)
        stbtt__csctx_v(ctx, STBTT_vline, @intFromFloat(ctx.first_x), @intFromFloat(ctx.first_y), 0, 0, 0, 0);
}

fn stbtt__csctx_rmove_to(ctx: *stbtt__csctx, dx: f32, dy: f32) void {
    stbtt__csctx_close_shape(ctx);
    ctx.x = ctx.x + dx;
    ctx.first_x = ctx.x;
    ctx.y = ctx.y + dy;
    ctx.first_y = ctx.y;
    stbtt__csctx_v(ctx, STBTT_vmove, @intFromFloat(ctx.x), @intFromFloat(ctx.y), 0, 0, 0, 0);
}

fn stbtt__csctx_rline_to(ctx: *stbtt__csctx, dx: f32, dy: f32) void {
    ctx.x += dx;
    ctx.y += dy;
    stbtt__csctx_v(ctx, STBTT_vline, @intFromFloat(ctx.x), @intFromFloat(ctx.y), 0, 0, 0, 0);
}

fn stbtt__csctx_rccurve_to(ctx: *stbtt__csctx, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) void {
    const cx1: f32 = ctx.x + dx1;
    const cy1: f32 = ctx.y + dy1;
    const cx2: f32 = cx1 + dx2;
    const cy2: f32 = cy1 + dy2;
    ctx.x = cx2 + dx3;
    ctx.y = cy2 + dy3;
    stbtt__csctx_v(ctx, STBTT_vcubic, @intFromFloat(ctx.x), @intFromFloat(ctx.y), @intFromFloat(cx1), @intFromFloat(cy1), @intFromFloat(cx2), @intFromFloat(cy2));
}

fn stbtt__get_subr(idx: stbtt__buf, n: c_int) stbtt__buf {
    var ix = idx;
    const count: c_int = stbtt__cff_index_count(&ix);
    var bias: c_int = 107;
    var nn = n;
    if (count >= 33900)
        bias = 32768
    else if (count >= 1240)
        bias = 1131;
    nn += bias;
    if (nn < 0 or nn >= count)
        return stbtt__new_buf(null, 0);
    return stbtt__cff_index_get(idx, nn);
}

fn stbtt__cid_get_glyph_subrs(info: [*c]const stbtt_fontinfo, glyph_index: c_int) stbtt__buf {
    var fdselect: stbtt__buf = info.*.fdselect;
    var nranges: c_int = undefined;
    var start: c_int = undefined;
    var end: c_int = undefined;
    var v: c_int = undefined;
    var fmt: c_int = undefined;
    var fdselector: c_int = -1;
    var i: c_int = undefined;

    stbtt__buf_seek(&fdselect, 0);
    fmt = stbtt__buf_get8(&fdselect);
    if (fmt == 0) {
        // untested
        stbtt__buf_skip(&fdselect, glyph_index);
        fdselector = stbtt__buf_get8(&fdselect);
    } else if (fmt == 3) {
        nranges = @bitCast(stbtt__buf_get16(&fdselect));
        start = @bitCast(stbtt__buf_get16(&fdselect));
        i = 0;
        while (i < nranges) : (i += 1) {
            v = stbtt__buf_get8(&fdselect);
            end = @bitCast(stbtt__buf_get16(&fdselect));
            if (glyph_index >= start and glyph_index < end) {
                fdselector = v;
                break;
            }
            start = end;
        }
    }
    if (fdselector == -1) _ = stbtt__new_buf(null, 0);
    return stbtt__get_subrs(info.*.cff, stbtt__cff_index_get(info.*.fontdicts, fdselector));
}

fn stbtt__run_charstring(info: [*c]const stbtt_fontinfo, glyph_index: c_int, c: *stbtt__csctx) c_int {
    var in_header: c_int = 1;
    var maskbits: c_int = 0;
    var subr_stack_height: c_int = 0;
    var sp: c_int = 0;
    var v: c_int = undefined;
    var i: c_int = undefined;
    var b0: c_int = undefined;
    var has_subrs: c_int = 0;
    var clear_stack: c_int = undefined;
    var s: [48]f32 = undefined;
    var subr_stack: [10]stbtt__buf = undefined;
    var subrs: stbtt__buf = info.*.subrs;
    var b: stbtt__buf = undefined;
    var f: f32 = undefined;

    // this currently ignores the initial width value, which isn't needed if we have hmtx
    b = stbtt__cff_index_get(info.*.charstrings, glyph_index);
    while (b.cursor < b.size) {
        i = 0;
        clear_stack = 1;
        b0 = stbtt__buf_get8(&b);
        switch (b0) {
            // @TODO implement hinting
            0x13, 0x14 => { // hintmask, cntrmask
                if (in_header != 0)
                    maskbits += @divTrunc(sp, 2); // implicit "vstem"
                in_header = 0;
                stbtt__buf_skip(&b, @divTrunc(maskbits + 7, 8));
            },

            0x01, 0x03, 0x12, 0x17 => { // hstem, vstem, hstemhm, vstemhm
                maskbits += @divTrunc(sp, 2);
            },

            0x15 => { // rmoveto
                in_header = 0;
                if (sp < 2) return 0;
                stbtt__csctx_rmove_to(c, s[@intCast(sp - 2)], s[@intCast(sp - 1)]);
            },
            0x04 => { // vmoveto
                in_header = 0;
                if (sp < 1) return 0;
                stbtt__csctx_rmove_to(c, 0, s[@intCast(sp - 1)]);
            },
            0x16 => { // hmoveto
                in_header = 0;
                if (sp < 1) return 0;
                stbtt__csctx_rmove_to(c, s[@intCast(sp - 1)], 0);
            },

            0x05 => { // rlineto
                if (sp < 2) return 0;
                while (i + 1 < sp) : (i += 2)
                    stbtt__csctx_rline_to(c, s[@intCast(i)], s[@intCast(i + 1)]);
            },

            // hlineto/vlineto and vhcurveto/hvcurveto alternate horizontal and vertical
            // starting from a different place.

            0x07, 0x06 => { // vlineto, hlineto
                if (sp < 1) return 0;
                // `goto vlineto` (case 0x07) enters the loop at its second half.
                var enter_vertical = b0 == 0x07;
                while (true) {
                    if (!enter_vertical) {
                        if (i >= sp) break;
                        stbtt__csctx_rline_to(c, s[@intCast(i)], 0);
                        i += 1;
                    }
                    enter_vertical = false;
                    // vlineto:
                    if (i >= sp) break;
                    stbtt__csctx_rline_to(c, 0, s[@intCast(i)]);
                    i += 1;
                }
            },

            0x1F, 0x1E => { // hvcurveto, vhcurveto
                if (sp < 4) return 0;
                // `goto hvcurveto` (case 0x1F) enters the loop at its second half.
                var enter_hv = b0 == 0x1F;
                while (true) {
                    if (!enter_hv) {
                        if (i + 3 >= sp) break;
                        stbtt__csctx_rccurve_to(c, 0, s[@intCast(i)], s[@intCast(i + 1)], s[@intCast(i + 2)], s[@intCast(i + 3)], if (sp - i == 5) s[@intCast(i + 4)] else 0.0);
                        i += 4;
                    }
                    enter_hv = false;
                    // hvcurveto:
                    if (i + 3 >= sp) break;
                    stbtt__csctx_rccurve_to(c, s[@intCast(i)], 0, s[@intCast(i + 1)], s[@intCast(i + 2)], if (sp - i == 5) s[@intCast(i + 4)] else 0.0, s[@intCast(i + 3)]);
                    i += 4;
                }
            },

            0x08 => { // rrcurveto
                if (sp < 6) return 0;
                while (i + 5 < sp) : (i += 6)
                    stbtt__csctx_rccurve_to(c, s[@intCast(i)], s[@intCast(i + 1)], s[@intCast(i + 2)], s[@intCast(i + 3)], s[@intCast(i + 4)], s[@intCast(i + 5)]);
            },

            0x18 => { // rcurveline
                if (sp < 8) return 0;
                while (i + 5 < sp - 2) : (i += 6)
                    stbtt__csctx_rccurve_to(c, s[@intCast(i)], s[@intCast(i + 1)], s[@intCast(i + 2)], s[@intCast(i + 3)], s[@intCast(i + 4)], s[@intCast(i + 5)]);
                if (i + 1 >= sp) return 0;
                stbtt__csctx_rline_to(c, s[@intCast(i)], s[@intCast(i + 1)]);
            },

            0x19 => { // rlinecurve
                if (sp < 8) return 0;
                while (i + 1 < sp - 6) : (i += 2)
                    stbtt__csctx_rline_to(c, s[@intCast(i)], s[@intCast(i + 1)]);
                if (i + 5 >= sp) return 0;
                stbtt__csctx_rccurve_to(c, s[@intCast(i)], s[@intCast(i + 1)], s[@intCast(i + 2)], s[@intCast(i + 3)], s[@intCast(i + 4)], s[@intCast(i + 5)]);
            },

            0x1A, 0x1B => { // vvcurveto, hhcurveto
                if (sp < 4) return 0;
                f = 0.0;
                if ((sp & 1) != 0) {
                    f = s[@intCast(i)];
                    i += 1;
                }
                while (i + 3 < sp) : (i += 4) {
                    if (b0 == 0x1B)
                        stbtt__csctx_rccurve_to(c, s[@intCast(i)], f, s[@intCast(i + 1)], s[@intCast(i + 2)], s[@intCast(i + 3)], 0.0)
                    else
                        stbtt__csctx_rccurve_to(c, f, s[@intCast(i)], s[@intCast(i + 1)], s[@intCast(i + 2)], 0.0, s[@intCast(i + 3)]);
                    f = 0.0;
                }
            },

            0x0A, 0x1D => { // callsubr, callgsubr
                if (b0 == 0x0A) {
                    if (has_subrs == 0) {
                        if (info.*.fdselect.size != 0)
                            subrs = stbtt__cid_get_glyph_subrs(info, glyph_index);
                        has_subrs = 1;
                    }
                }
                // FALLTHROUGH
                if (sp < 1) return 0;
                sp -= 1;
                v = @intFromFloat(s[@intCast(sp)]);
                if (subr_stack_height >= 10) return 0;
                subr_stack[@intCast(subr_stack_height)] = b;
                subr_stack_height += 1;
                b = stbtt__get_subr(if (b0 == 0x0A) subrs else info.*.gsubrs, v);
                if (b.size == 0) return 0; // subr not found
                b.cursor = 0;
                clear_stack = 0;
            },

            0x0B => { // return
                if (subr_stack_height <= 0) return 0;
                subr_stack_height -= 1;
                b = subr_stack[@intCast(subr_stack_height)];
                clear_stack = 0;
            },

            0x0E => { // endchar
                stbtt__csctx_close_shape(c);
                return 1;
            },

            0x0C => { // two-byte escape
                var dx1: f32 = undefined;
                var dx2: f32 = undefined;
                var dx3: f32 = undefined;
                var dx4: f32 = undefined;
                var dx5: f32 = undefined;
                var dx6: f32 = undefined;
                var dy1: f32 = undefined;
                var dy2: f32 = undefined;
                var dy3: f32 = undefined;
                var dy4: f32 = undefined;
                var dy5: f32 = undefined;
                var dy6: f32 = undefined;
                var dx: f32 = undefined;
                var dy: f32 = undefined;
                const b1: c_int = stbtt__buf_get8(&b);
                switch (b1) {
                    // @TODO These "flex" implementations ignore the flex-depth and resolution,
                    // and always draw beziers.
                    0x22 => { // hflex
                        if (sp < 7) return 0;
                        dx1 = s[0];
                        dx2 = s[1];
                        dy2 = s[2];
                        dx3 = s[3];
                        dx4 = s[4];
                        dx5 = s[5];
                        dx6 = s[6];
                        stbtt__csctx_rccurve_to(c, dx1, 0, dx2, dy2, dx3, 0);
                        stbtt__csctx_rccurve_to(c, dx4, 0, dx5, -dy2, dx6, 0);
                    },

                    0x23 => { // flex
                        if (sp < 13) return 0;
                        dx1 = s[0];
                        dy1 = s[1];
                        dx2 = s[2];
                        dy2 = s[3];
                        dx3 = s[4];
                        dy3 = s[5];
                        dx4 = s[6];
                        dy4 = s[7];
                        dx5 = s[8];
                        dy5 = s[9];
                        dx6 = s[10];
                        dy6 = s[11];
                        // fd is s[12]
                        stbtt__csctx_rccurve_to(c, dx1, dy1, dx2, dy2, dx3, dy3);
                        stbtt__csctx_rccurve_to(c, dx4, dy4, dx5, dy5, dx6, dy6);
                    },

                    0x24 => { // hflex1
                        if (sp < 9) return 0;
                        dx1 = s[0];
                        dy1 = s[1];
                        dx2 = s[2];
                        dy2 = s[3];
                        dx3 = s[4];
                        dx4 = s[5];
                        dx5 = s[6];
                        dy5 = s[7];
                        dx6 = s[8];
                        stbtt__csctx_rccurve_to(c, dx1, dy1, dx2, dy2, dx3, 0);
                        stbtt__csctx_rccurve_to(c, dx4, 0, dx5, dy5, dx6, -(dy1 + dy2 + dy5));
                    },

                    0x25 => { // flex1
                        if (sp < 11) return 0;
                        dx1 = s[0];
                        dy1 = s[1];
                        dx2 = s[2];
                        dy2 = s[3];
                        dx3 = s[4];
                        dy3 = s[5];
                        dx4 = s[6];
                        dy4 = s[7];
                        dx5 = s[8];
                        dy5 = s[9];
                        dx6 = s[10];
                        dy6 = s[10];
                        dx = dx1 + dx2 + dx3 + dx4 + dx5;
                        dy = dy1 + dy2 + dy3 + dy4 + dy5;
                        if (@abs(dx) > @abs(dy))
                            dy6 = -dy
                        else
                            dx6 = -dx;
                        stbtt__csctx_rccurve_to(c, dx1, dy1, dx2, dy2, dx3, dy3);
                        stbtt__csctx_rccurve_to(c, dx4, dy4, dx5, dy5, dx6, dy6);
                    },

                    else => return 0, // unimplemented
                }
            },

            else => {
                if (b0 != 255 and b0 != 28 and b0 < 32)
                    return 0; // reserved operator

                // push immediate
                if (b0 == 255) {
                    f = @as(f32, @floatFromInt(@as(stbtt_int32, @bitCast(stbtt__buf_get32(&b))))) / 0x10000;
                } else {
                    stbtt__buf_skip(&b, -1);
                    f = @floatFromInt(@as(stbtt_int16, @bitCast(@as(stbtt_uint16, @truncate(stbtt__cff_int(&b)))))); // (stbtt_int16)
                }
                if (sp >= 48) return 0; // push stack overflow
                s[@intCast(sp)] = f;
                sp += 1;
                clear_stack = 0;
            },
        }
        if (clear_stack != 0) sp = 0;
    }
    return 0; // no endchar
}

fn stbtt__GetGlyphShapeT2(info: [*c]const stbtt_fontinfo, glyph_index: c_int, pvertices: [*c][*c]stbtt_vertex) c_int {
    // runs the charstring twice, once to count and once to output (to avoid realloc)
    var count_ctx = stbtt__CSCTX_INIT(1);
    var output_ctx = stbtt__CSCTX_INIT(0);
    if (stbtt__run_charstring(info, glyph_index, &count_ctx) != 0) {
        pvertices.* = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(count_ctx.num_vertices)) * @sizeOf(stbtt_vertex))));
        output_ctx.pvertices = pvertices.*;
        if (stbtt__run_charstring(info, glyph_index, &output_ctx) != 0) {
            return output_ctx.num_vertices;
        }
    }
    pvertices.* = null;
    return 0;
}

fn stbtt__GetGlyphInfoT2(info: [*c]const stbtt_fontinfo, glyph_index: c_int, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) c_int {
    var c = stbtt__CSCTX_INIT(1);
    const r: c_int = stbtt__run_charstring(info, glyph_index, &c);
    if (x0 != null) x0.* = if (r != 0) c.min_x else 0;
    if (y0 != null) y0.* = if (r != 0) c.min_y else 0;
    if (x1 != null) x1.* = if (r != 0) c.max_x else 0;
    if (y1 != null) y1.* = if (r != 0) c.max_y else 0;
    return if (r != 0) c.num_vertices else 0;
}

pub fn stbtt_GetGlyphShape(info: [*c]const stbtt_fontinfo, glyph_index: c_int, pvertices: [*c][*c]stbtt_vertex) c_int {
    if (info.*.cff.size == 0)
        return stbtt__GetGlyphShapeTT(info, glyph_index, pvertices)
    else
        return stbtt__GetGlyphShapeT2(info, glyph_index, pvertices);
}

pub fn stbtt_GetGlyphHMetrics(info: [*c]const stbtt_fontinfo, glyph_index: c_int, advanceWidth: [*c]c_int, leftSideBearing: [*c]c_int) void {
    const numOfLongHorMetrics: c_int = ttUSHORT(ptrAt(info.*.data, info.*.hhea + 34));
    if (glyph_index < numOfLongHorMetrics) {
        if (advanceWidth != null) advanceWidth.* = ttSHORT(ptrAt(info.*.data, info.*.hmtx + 4 * glyph_index));
        if (leftSideBearing != null) leftSideBearing.* = ttSHORT(ptrAt(info.*.data, info.*.hmtx + 4 * glyph_index + 2));
    } else {
        if (advanceWidth != null) advanceWidth.* = ttSHORT(ptrAt(info.*.data, info.*.hmtx + 4 * (numOfLongHorMetrics - 1)));
        if (leftSideBearing != null) leftSideBearing.* = ttSHORT(ptrAt(info.*.data, info.*.hmtx + 4 * numOfLongHorMetrics + 2 * (glyph_index - numOfLongHorMetrics)));
    }
}

pub fn stbtt_GetFontVMetrics(info: [*c]const stbtt_fontinfo, ascent: [*c]c_int, descent: [*c]c_int, lineGap: [*c]c_int) void {
    if (ascent != null) ascent.* = ttSHORT(ptrAt(info.*.data, info.*.hhea + 4));
    if (descent != null) descent.* = ttSHORT(ptrAt(info.*.data, info.*.hhea + 6));
    if (lineGap != null) lineGap.* = ttSHORT(ptrAt(info.*.data, info.*.hhea + 8));
}

pub fn stbtt_ScaleForMappingEmToPixels(info: [*c]const stbtt_fontinfo, pixels: f32) f32 {
    const unitsPerEm: c_int = ttUSHORT(ptrAt(info.*.data, info.*.head + 18));
    return pixels / @as(f32, @floatFromInt(unitsPerEm));
}

fn stbtt_ifloor(x: f32) c_int {
    return @intFromFloat(@floor(x));
}

fn stbtt_iceil(x: f32) c_int {
    return @intFromFloat(@ceil(x));
}

pub fn stbtt_GetGlyphBitmapBoxSubpixel(font: [*c]const stbtt_fontinfo, glyph: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void {
    var x0: c_int = 0;
    var y0: c_int = 0;
    var x1: c_int = 0;
    var y1: c_int = 0; // =0 suppresses compiler warning
    if (stbtt_GetGlyphBox(font, glyph, &x0, &y0, &x1, &y1) == 0) {
        // e.g. space character
        if (ix0 != null) ix0.* = 0;
        if (iy0 != null) iy0.* = 0;
        if (ix1 != null) ix1.* = 0;
        if (iy1 != null) iy1.* = 0;
    } else {
        // move to integral bboxes (treating pixels as little squares, what pixels get touched)?
        if (ix0 != null) ix0.* = stbtt_ifloor(@as(f32, @floatFromInt(x0)) * scale_x + shift_x);
        if (iy0 != null) iy0.* = stbtt_ifloor(@as(f32, @floatFromInt(-y1)) * scale_y + shift_y);
        if (ix1 != null) ix1.* = stbtt_iceil(@as(f32, @floatFromInt(x1)) * scale_x + shift_x);
        if (iy1 != null) iy1.* = stbtt_iceil(@as(f32, @floatFromInt(-y0)) * scale_y + shift_y);
    }
}

pub fn stbtt_GetGlyphBitmapBox(font: [*c]const stbtt_fontinfo, glyph: c_int, scale_x: f32, scale_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void {
    stbtt_GetGlyphBitmapBoxSubpixel(font, glyph, scale_x, scale_y, 0.0, 0.0, ix0, iy0, ix1, iy1);
}

// ---- rasterizer (STBTT_RASTERIZER_VERSION 2) ----

const stbtt__hheap_chunk = extern struct {
    next: [*c]stbtt__hheap_chunk,
};

const stbtt__hheap = extern struct {
    head: [*c]stbtt__hheap_chunk,
    first_free: ?*anyopaque,
    num_remaining_in_head_chunk: c_int,
};

fn stbtt__hheap_alloc(hh: [*c]stbtt__hheap, size: usize, userdata: ?*anyopaque) ?*anyopaque {
    _ = userdata; // STBTT_malloc(size, user) ignores user (font_raster.c)
    if (hh.*.first_free) |p| {
        const slot: *?*anyopaque = @ptrCast(@alignCast(p));
        hh.*.first_free = slot.*;
        return p;
    } else {
        if (hh.*.num_remaining_in_head_chunk == 0) {
            const count: c_int = if (size < 32) 2000 else if (size < 128) 800 else 100;
            const raw = base.rvn_alloc(@sizeOf(stbtt__hheap_chunk) + size * @as(usize, @intCast(count)));
            if (raw == null) return null;
            const c: [*c]stbtt__hheap_chunk = @ptrCast(@alignCast(raw));
            c.*.next = hh.*.head;
            hh.*.head = c;
            hh.*.num_remaining_in_head_chunk = count;
        }
        hh.*.num_remaining_in_head_chunk -= 1;
        const base_ptr: [*c]u8 = @ptrCast(hh.*.head);
        return base_ptr + @sizeOf(stbtt__hheap_chunk) + size * @as(usize, @intCast(hh.*.num_remaining_in_head_chunk));
    }
}

fn stbtt__hheap_free(hh: [*c]stbtt__hheap, p: ?*anyopaque) void {
    const slot: *?*anyopaque = @ptrCast(@alignCast(p));
    slot.* = hh.*.first_free;
    hh.*.first_free = p;
}

fn stbtt__hheap_cleanup(hh: [*c]stbtt__hheap, userdata: ?*anyopaque) void {
    _ = userdata;
    var c: [*c]stbtt__hheap_chunk = hh.*.head;
    while (c != null) {
        const n: [*c]stbtt__hheap_chunk = c.*.next;
        base.rvn_free(c);
        c = n;
    }
}

const stbtt__edge = extern struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    invert: c_int,
};

const stbtt__active_edge = extern struct {
    next: [*c]stbtt__active_edge,
    fx: f32,
    fdx: f32,
    fdy: f32,
    direction: f32,
    sy: f32,
    ey: f32,
};

fn stbtt__new_active(hh: [*c]stbtt__hheap, e: [*c]stbtt__edge, off_x: c_int, start_point: f32, userdata: ?*anyopaque) [*c]stbtt__active_edge {
    const z: [*c]stbtt__active_edge = @ptrCast(@alignCast(stbtt__hheap_alloc(hh, @sizeOf(stbtt__active_edge), userdata)));
    const dxdy: f32 = (e.*.x1 - e.*.x0) / (e.*.y1 - e.*.y0);
    //STBTT_assert(e->y0 <= start_point);
    if (z == null) return z;
    z.*.fdx = dxdy;
    z.*.fdy = if (dxdy != 0.0) (1.0 / dxdy) else 0.0;
    z.*.fx = e.*.x0 + dxdy * (start_point - e.*.y0);
    z.*.fx -= @floatFromInt(off_x);
    z.*.direction = if (e.*.invert != 0) 1.0 else -1.0;
    z.*.sy = e.*.y0;
    z.*.ey = e.*.y1;
    z.*.next = null;
    return z;
}

fn stbtt__handle_clipped_edge(scanline: [*c]f32, x: c_int, e: [*c]stbtt__active_edge, x0_in: f32, y0_in: f32, x1_in: f32, y1_in: f32) void {
    var x0 = x0_in;
    var y0 = y0_in;
    var x1 = x1_in;
    var y1 = y1_in;
    const xf: f32 = @floatFromInt(x);
    const idx: usize = @intCast(x);
    if (y0 == y1) return;
    if (y0 > e.*.ey) return;
    if (y1 < e.*.sy) return;
    if (y0 < e.*.sy) {
        x0 += (x1 - x0) * (e.*.sy - y0) / (y1 - y0);
        y0 = e.*.sy;
    }
    if (y1 > e.*.ey) {
        x1 += (x1 - x0) * (e.*.ey - y1) / (y1 - y0);
        y1 = e.*.ey;
    }
    if (x0 <= xf and x1 <= xf) {
        scanline[idx] += e.*.direction * (y1 - y0);
    } else if (x0 >= xf + 1 and x1 >= xf + 1) {
        // nothing
    } else {
        scanline[idx] += e.*.direction * (y1 - y0) * (1 - ((x0 - xf) + (x1 - xf)) / 2); // coverage = 1 - average x position
    }
}

fn stbtt__sized_trapezoid_area(height: f32, top_width: f32, bottom_width: f32) f32 {
    return (top_width + bottom_width) / 2.0 * height;
}

fn stbtt__position_trapezoid_area(height: f32, tx0: f32, tx1: f32, bx0: f32, bx1: f32) f32 {
    return stbtt__sized_trapezoid_area(height, tx1 - tx0, bx1 - bx0);
}

fn stbtt__sized_triangle_area(height: f32, width: f32) f32 {
    return height * width / 2;
}

fn stbtt__fill_active_edges_new(scanline: [*c]f32, scanline_fill: [*c]f32, len: c_int, e_in: [*c]stbtt__active_edge, y_top: f32) void {
    var e = e_in;
    const y_bottom: f32 = y_top + 1;
    const lenf: f32 = @floatFromInt(len);
    while (e != null) {
        // brute force every pixel
        // compute intersection points with top & bottom
        if (e.*.fdx == 0) {
            const x0: f32 = e.*.fx;
            if (x0 < lenf) {
                if (x0 >= 0) {
                    stbtt__handle_clipped_edge(scanline, @intFromFloat(x0), e, x0, y_top, x0, y_bottom);
                    stbtt__handle_clipped_edge(scanline_fill - 1, @as(c_int, @intFromFloat(x0)) + 1, e, x0, y_top, x0, y_bottom);
                } else {
                    stbtt__handle_clipped_edge(scanline_fill - 1, 0, e, x0, y_top, x0, y_bottom);
                }
            }
        } else {
            var x0: f32 = e.*.fx;
            var dx: f32 = e.*.fdx;
            var xb: f32 = x0 + dx;
            var x_top: f32 = undefined;
            var x_bottom: f32 = undefined;
            var sy0: f32 = undefined;
            var sy1: f32 = undefined;
            var dy: f32 = e.*.fdy;
            // compute endpoints of line segment clipped to this scanline (if the
            // line segment starts on this scanline. x0 is the intersection of the
            // line with y_top, but that may be off the line segment.
            if (e.*.sy > y_top) {
                x_top = x0 + dx * (e.*.sy - y_top);
                sy0 = e.*.sy;
            } else {
                x_top = x0;
                sy0 = y_top;
            }
            if (e.*.ey < y_bottom) {
                x_bottom = x0 + dx * (e.*.ey - y_top);
                sy1 = e.*.ey;
            } else {
                x_bottom = xb;
                sy1 = y_bottom;
            }
            if (x_top >= 0 and x_bottom >= 0 and x_top < lenf and x_bottom < lenf) {
                // from here on, we don't have to range check x values
                if (@as(c_int, @intFromFloat(x_top)) == @as(c_int, @intFromFloat(x_bottom))) {
                    var height: f32 = undefined;
                    // simple case, only spans one pixel
                    const x: c_int = @intFromFloat(x_top);
                    const xu: usize = @intCast(x);
                    const xf: f32 = @floatFromInt(x);
                    height = (sy1 - sy0) * e.*.direction;
                    scanline[xu] += stbtt__position_trapezoid_area(height, x_top, xf + 1.0, x_bottom, xf + 1.0);
                    scanline_fill[xu] += height; // everything right of this pixel is filled
                } else {
                    var x: c_int = undefined;
                    var x1: c_int = undefined;
                    var x2: c_int = undefined;
                    var y_crossing: f32 = undefined;
                    var y_final: f32 = undefined;
                    var step: f32 = undefined;
                    var sign: f32 = undefined;
                    var area: f32 = undefined;
                    // covers 2+ pixels
                    if (x_top > x_bottom) {
                        // flip scanline vertically; signed area is the same
                        var t: f32 = undefined;
                        sy0 = y_bottom - (sy0 - y_top);
                        sy1 = y_bottom - (sy1 - y_top);
                        t = sy0;
                        sy0 = sy1;
                        sy1 = t;
                        t = x_bottom;
                        x_bottom = x_top;
                        x_top = t;
                        dx = -dx;
                        dy = -dy;
                        t = x0;
                        x0 = xb;
                        xb = t;
                    }
                    x1 = @intFromFloat(x_top);
                    x2 = @intFromFloat(x_bottom);
                    // compute intersection with y axis at x1+1
                    y_crossing = y_top + dy * (@as(f32, @floatFromInt(x1 + 1)) - x0);
                    // compute intersection with y axis at x2
                    y_final = y_top + dy * (@as(f32, @floatFromInt(x2)) - x0);
                    // if x2 is right at the right edge of x1, y_crossing can blow up, github #1057
                    // @TODO: maybe test against sy1 rather than y_bottom?
                    if (y_crossing > y_bottom)
                        y_crossing = y_bottom;
                    sign = e.*.direction;
                    // area of the rectangle covered from sy0..y_crossing
                    area = sign * (y_crossing - sy0);
                    scanline[@intCast(x1)] += stbtt__sized_triangle_area(area, @as(f32, @floatFromInt(x1 + 1)) - x_top);
                    if (y_final > y_bottom) {
                        y_final = y_bottom;
                        dy = (y_final - y_crossing) / @as(f32, @floatFromInt(x2 - (x1 + 1))); // if denom=0, y_final = y_crossing, so y_final <= y_bottom
                    }
                    step = sign * dy * 1; // dy is dy/dx, change in y for every 1 change in x,
                    x = x1 + 1;
                    while (x < x2) : (x += 1) {
                        scanline[@intCast(x)] += area + step / 2; // area of trapezoid is 1*step/2
                        area += step;
                    }
                    // accumulated error from area += step unless we round step down
                    const x2f: f32 = @floatFromInt(x2);
                    scanline[@intCast(x2)] += area + sign * stbtt__position_trapezoid_area(sy1 - y_final, x2f, x2f + 1.0, x_bottom, x2f + 1.0);
                    scanline_fill[@intCast(x2)] += sign * (sy1 - sy0);
                }
            } else {
                // the segment crosses the scanline outside of the range: test every pixel
                var x: c_int = 0;
                while (x < len) : (x += 1) {
                    const y0: f32 = y_top;
                    const x1: f32 = @floatFromInt(x);
                    const x2: f32 = @floatFromInt(x + 1);
                    const x3: f32 = xb;
                    const y3: f32 = y_bottom;
                    const y1: f32 = (@as(f32, @floatFromInt(x)) - x0) / dx + y_top;
                    const y2: f32 = (@as(f32, @floatFromInt(x + 1)) - x0) / dx + y_top;
                    if (x0 < x1 and x3 > x2) { // three segments descending down-right
                        stbtt__handle_clipped_edge(scanline, x, e, x0, y0, x1, y1);
                        stbtt__handle_clipped_edge(scanline, x, e, x1, y1, x2, y2);
                        stbtt__handle_clipped_edge(scanline, x, e, x2, y2, x3, y3);
                    } else if (x3 < x1 and x0 > x2) { // three segments descending down-left
                        stbtt__handle_clipped_edge(scanline, x, e, x0, y0, x2, y2);
                        stbtt__handle_clipped_edge(scanline, x, e, x2, y2, x1, y1);
                        stbtt__handle_clipped_edge(scanline, x, e, x1, y1, x3, y3);
                    } else if (x0 < x1 and x3 > x1) { // two segments across x, down-right
                        stbtt__handle_clipped_edge(scanline, x, e, x0, y0, x1, y1);
                        stbtt__handle_clipped_edge(scanline, x, e, x1, y1, x3, y3);
                    } else if (x3 < x1 and x0 > x1) { // two segments across x, down-left
                        stbtt__handle_clipped_edge(scanline, x, e, x0, y0, x1, y1);
                        stbtt__handle_clipped_edge(scanline, x, e, x1, y1, x3, y3);
                    } else if (x0 < x2 and x3 > x2) { // two segments across x+1, down-right
                        stbtt__handle_clipped_edge(scanline, x, e, x0, y0, x2, y2);
                        stbtt__handle_clipped_edge(scanline, x, e, x2, y2, x3, y3);
                    } else if (x3 < x2 and x0 > x2) { // two segments across x+1, down-left
                        stbtt__handle_clipped_edge(scanline, x, e, x0, y0, x2, y2);
                        stbtt__handle_clipped_edge(scanline, x, e, x2, y2, x3, y3);
                    } else { // one segment
                        stbtt__handle_clipped_edge(scanline, x, e, x0, y0, x3, y3);
                    }
                }
            }
        }
        e = e.*.next;
    }
}

fn stbtt__rasterize_sorted_edges(result: [*c]stbtt__bitmap, e_in: [*c]stbtt__edge, n: c_int, vsubsample: c_int, off_x: c_int, off_y: c_int, userdata: ?*anyopaque) void {
    var hh: stbtt__hheap = .{ .head = null, .first_free = null, .num_remaining_in_head_chunk = 0 };
    var active: [*c]stbtt__active_edge = null;
    var ee: [*c]stbtt__edge = e_in;
    var y: c_int = off_y;
    var j: c_int = 0;
    var i: c_int = undefined;
    var scanline_data: [129]f32 = undefined;
    var scanline: [*c]f32 = undefined;
    var scanline2: [*c]f32 = undefined;
    _ = vsubsample;
    if (result.*.w > 64)
        scanline = @ptrCast(@alignCast(base.rvn_alloc((@as(usize, @intCast(result.*.w)) * 2 + 1) * @sizeOf(f32))))
    else
        scanline = &scanline_data;
    const scanline_default: [*c]f32 = &scanline_data;
    scanline2 = scanline + @as(usize, @intCast(result.*.w));
    ee[@intCast(n)].y0 = @as(f32, @floatFromInt(off_y + result.*.h)) + 1;
    while (j < result.*.h) {
        // find center of pixel for this scanline
        const scan_y_top: f32 = @floatFromInt(y);
        const scan_y_bottom: f32 = @as(f32, @floatFromInt(y)) + 1.0;
        var step: [*c][*c]stbtt__active_edge = &active;
        _ = libc.memset(scanline, 0, @as(usize, @intCast(result.*.w)) * @sizeOf(f32));
        _ = libc.memset(scanline2, 0, @as(usize, @intCast(result.*.w + 1)) * @sizeOf(f32));
        // update all active edges;
        // remove all active edges that terminate before the top of this scanline
        while (step.* != null) {
            const z: [*c]stbtt__active_edge = step.*;
            if (z.*.ey <= scan_y_top) {
                step.* = z.*.next; // delete from list
                z.*.direction = 0;
                stbtt__hheap_free(&hh, z);
            } else {
                step = &z.*.next; // advance through list
            }
        }
        // insert all edges that start before the bottom of this scanline
        while (ee.*.y0 <= scan_y_bottom) {
            if (ee.*.y0 != ee.*.y1) {
                const z: [*c]stbtt__active_edge = stbtt__new_active(&hh, ee, off_x, scan_y_top, userdata);
                if (z != null) {
                    if (j == 0 and off_y != 0) {
                        if (z.*.ey < scan_y_top) {
                            // this can happen due to subpixel positioning and some kind of fp rounding error i think
                            z.*.ey = scan_y_top;
                        }
                    }
                    // if we get really unlucky a tiny bit of an edge can be out of bounds
                    // insert at front
                    z.*.next = active;
                    active = z;
                }
            }
            ee += 1;
        }
        // now process all active edges
        if (active != null)
            stbtt__fill_active_edges_new(scanline, scanline2 + 1, result.*.w, active, scan_y_top);
        {
            var sum: f32 = 0;
            i = 0;
            while (i < result.*.w) : (i += 1) {
                var k: f32 = undefined;
                var m: c_int = undefined;
                sum += scanline2[@intCast(i)];
                k = scanline[@intCast(i)] + sum;
                k = @abs(k) * 255 + 0.5;
                m = @intFromFloat(k);
                if (m > 255) m = 255;
                result.*.pixels[@intCast(j * result.*.stride + i)] = wrapU8(m);
            }
        }
        // advance all the edges
        step = &active;
        while (step.* != null) {
            const z: [*c]stbtt__active_edge = step.*;
            z.*.fx += z.*.fdx; // advance to position for current scanline
            step = &z.*.next; // advance through list
        }
        y += 1;
        j += 1;
    }
    stbtt__hheap_cleanup(&hh, userdata);
    if (scanline != scanline_default)
        base.rvn_free(scanline);
}

fn ep(p: [*c]stbtt__edge, idx: c_int) [*c]stbtt__edge {
    return &p[@intCast(idx)];
}

// #define STBTT__COMPARE(a,b)  ((a)->y0 < (b)->y0)
fn stbtt__COMPARE(a: [*c]const stbtt__edge, b: [*c]const stbtt__edge) c_int {
    return if (a.*.y0 < b.*.y0) 1 else 0;
}

fn stbtt__sort_edges_ins_sort(p: [*c]stbtt__edge, n: c_int) void {
    var i: c_int = 1;
    while (i < n) : (i += 1) {
        const t: stbtt__edge = p[@intCast(i)];
        var j: c_int = i;
        while (j > 0) {
            const c: c_int = if (t.y0 < p[@intCast(j - 1)].y0) 1 else 0;
            if (c == 0) break;
            p[@intCast(j)] = p[@intCast(j - 1)];
            j -= 1;
        }
        if (i != j)
            p[@intCast(j)] = t;
    }
}

fn stbtt__sort_edges_quicksort(p_in: [*c]stbtt__edge, n_in: c_int) void {
    var p = p_in;
    var n = n_in;
    // threshold for transitioning to insertion sort
    while (n > 12) {
        var t: stbtt__edge = undefined;
        var c01: c_int = undefined;
        var c12: c_int = undefined;
        var c: c_int = undefined;
        var m: c_int = undefined;
        var i: c_int = undefined;
        var j: c_int = undefined;
        // compute median of three
        m = n >> 1;
        c01 = stbtt__COMPARE(ep(p, 0), ep(p, m));
        c12 = stbtt__COMPARE(ep(p, m), ep(p, n - 1));
        // if 0 >= mid >= end, or 0 < mid < end, then use mid
        if (c01 != c12) {
            // otherwise, we'll need to swap something else to middle
            var z: c_int = undefined;
            c = stbtt__COMPARE(ep(p, 0), ep(p, n - 1));
            // 0>mid && mid<n:  0>n => n; 0<n => 0
            // 0<mid && mid>n:  0>n => 0; 0<n => n
            z = if (c == c12) 0 else n - 1;
            t = p[@intCast(z)];
            p[@intCast(z)] = p[@intCast(m)];
            p[@intCast(m)] = t;
        }
        // now p[m] is the median-of-three
        // swap it to the beginning so it won't move around
        t = p[0];
        p[0] = p[@intCast(m)];
        p[@intCast(m)] = t;
        // partition loop
        i = 1;
        j = n - 1;
        while (true) {
            // handling of equality is crucial here
            // for sentinels & efficiency with duplicates
            while (true) {
                if (stbtt__COMPARE(ep(p, i), ep(p, 0)) == 0) break;
                i += 1;
            }
            while (true) {
                if (stbtt__COMPARE(ep(p, 0), ep(p, j)) == 0) break;
                j -= 1;
            }
            // make sure we haven't crossed
            if (i >= j) break;
            t = p[@intCast(i)];
            p[@intCast(i)] = p[@intCast(j)];
            p[@intCast(j)] = t;
            i += 1;
            j -= 1;
        }
        // recurse on smaller side, iterate on larger
        if (j < (n - i)) {
            stbtt__sort_edges_quicksort(p, j);
            p = p + @as(usize, @intCast(i));
            n = n - i;
        } else {
            stbtt__sort_edges_quicksort(p + @as(usize, @intCast(i)), n - i);
            n = j;
        }
    }
}

fn stbtt__sort_edges(p: [*c]stbtt__edge, n: c_int) void {
    stbtt__sort_edges_quicksort(p, n);
    stbtt__sort_edges_ins_sort(p, n);
}

const stbtt__point = extern struct {
    x: f32,
    y: f32,
};

fn stbtt__rasterize(result: [*c]stbtt__bitmap, pts: [*c]stbtt__point, wcount: [*c]c_int, windings: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, off_x: c_int, off_y: c_int, invert: c_int, userdata: ?*anyopaque) void {
    const y_scale_inv: f32 = if (invert != 0) -scale_y else scale_y;
    var e: [*c]stbtt__edge = undefined;
    var n: c_int = undefined;
    var i: c_int = undefined;
    var j: c_int = undefined;
    var k: c_int = undefined;
    var m: c_int = undefined;
    // STBTT_RASTERIZER_VERSION 2
    const vsubsample: c_int = 1;

    // vsubsample should divide 255 evenly; otherwise we won't reach full opacity
    // now we have to blow out the windings into explicit edge lists
    n = 0;
    i = 0;
    while (i < windings) : (i += 1)
        n += wcount[@intCast(i)];
    e = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(stbtt__edge) * @as(usize, @intCast(n + 1))))); // add an extra one as a sentinel
    if (e == null) return;
    n = 0;
    m = 0;
    i = 0;
    while (i < windings) : (i += 1) {
        const p: [*c]stbtt__point = pts + @as(usize, @intCast(m));
        m += wcount[@intCast(i)];
        j = wcount[@intCast(i)] - 1;
        k = 0;
        while (k < wcount[@intCast(i)]) : ({
            j = k;
            k += 1;
        }) {
            var a: c_int = k;
            var b: c_int = j;
            // skip the edge if horizontal
            if (p[@intCast(j)].y == p[@intCast(k)].y)
                continue;
            // add edge from j to k to the list
            e[@intCast(n)].invert = 0;
            if (if (invert != 0) p[@intCast(j)].y > p[@intCast(k)].y else p[@intCast(j)].y < p[@intCast(k)].y) {
                e[@intCast(n)].invert = 1;
                a = j;
                b = k;
            }
            e[@intCast(n)].x0 = p[@intCast(a)].x * scale_x + shift_x;
            e[@intCast(n)].y0 = (p[@intCast(a)].y * y_scale_inv + shift_y) * @as(f32, @floatFromInt(vsubsample));
            e[@intCast(n)].x1 = p[@intCast(b)].x * scale_x + shift_x;
            e[@intCast(n)].y1 = (p[@intCast(b)].y * y_scale_inv + shift_y) * @as(f32, @floatFromInt(vsubsample));
            n += 1;
        }
    }
    // now sort the edges by their highest point (should snap to integer, and then by x)
    //STBTT_sort(e, n, sizeof(e[0]), stbtt__edge_compare);
    stbtt__sort_edges(e, n);
    // now, traverse the scanlines and find the intersections on each scanline, use xor winding rule
    stbtt__rasterize_sorted_edges(result, e, n, vsubsample, off_x, off_y, userdata);
    base.rvn_free(e);
}

fn stbtt__add_point(points: [*c]stbtt__point, n: c_int, x: f32, y: f32) void {
    if (points == null) return; // during first pass, it's unallocated
    points[@intCast(n)].x = x;
    points[@intCast(n)].y = y;
}

// tessellate until threshold p is happy... @TODO warped to compensate for non-linear stretching
fn stbtt__tesselate_curve(points: [*c]stbtt__point, num_points: [*c]c_int, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, objspace_flatness_squared: f32, n: c_int) c_int {
    // midpoint
    const mx: f32 = (x0 + 2 * x1 + x2) / 4;
    const my: f32 = (y0 + 2 * y1 + y2) / 4;
    // versus directly drawn line
    const dx: f32 = (x0 + x2) / 2 - mx;
    const dy: f32 = (y0 + y2) / 2 - my;
    if (n > 16) // 65536 segments on one curve better be enough!
        return 1;
    if (dx * dx + dy * dy > objspace_flatness_squared) { // half-pixel error allowed... need to be smaller if AA
        _ = stbtt__tesselate_curve(points, num_points, x0, y0, (x0 + x1) / 2.0, (y0 + y1) / 2.0, mx, my, objspace_flatness_squared, n + 1);
        _ = stbtt__tesselate_curve(points, num_points, mx, my, (x1 + x2) / 2.0, (y1 + y2) / 2.0, x2, y2, objspace_flatness_squared, n + 1);
    } else {
        stbtt__add_point(points, num_points.*, x2, y2);
        num_points.* = num_points.* + 1;
    }
    return 1;
}

fn stbtt__tesselate_cubic(points: [*c]stbtt__point, num_points: [*c]c_int, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, x3: f32, y3: f32, objspace_flatness_squared: f32, n: c_int) void {
    // @TODO this "flatness" calculation is just made-up nonsense that seems to work well enough
    const dx0: f32 = x1 - x0;
    const dy0: f32 = y1 - y0;
    const dx1: f32 = x2 - x1;
    const dy1: f32 = y2 - y1;
    const dx2: f32 = x3 - x2;
    const dy2: f32 = y3 - y2;
    const dx: f32 = x3 - x0;
    const dy: f32 = y3 - y0;
    const longlen: f32 = @floatCast(@sqrt(@as(f64, dx0 * dx0 + dy0 * dy0)) + @sqrt(@as(f64, dx1 * dx1 + dy1 * dy1)) + @sqrt(@as(f64, dx2 * dx2 + dy2 * dy2)));
    const shortlen: f32 = @floatCast(@sqrt(@as(f64, dx * dx + dy * dy)));
    const flatness_squared: f32 = longlen * longlen - shortlen * shortlen;
    if (n > 16) // 65536 segments on one curve better be enough!
        return;
    if (flatness_squared > objspace_flatness_squared) {
        const x01: f32 = (x0 + x1) / 2;
        const y01: f32 = (y0 + y1) / 2;
        const x12: f32 = (x1 + x2) / 2;
        const y12: f32 = (y1 + y2) / 2;
        const x23: f32 = (x2 + x3) / 2;
        const y23: f32 = (y2 + y3) / 2;
        const xa: f32 = (x01 + x12) / 2;
        const ya: f32 = (y01 + y12) / 2;
        const xb: f32 = (x12 + x23) / 2;
        const yb: f32 = (y12 + y23) / 2;
        const mx: f32 = (xa + xb) / 2;
        const my: f32 = (ya + yb) / 2;
        stbtt__tesselate_cubic(points, num_points, x0, y0, x01, y01, xa, ya, mx, my, objspace_flatness_squared, n + 1);
        stbtt__tesselate_cubic(points, num_points, mx, my, xb, yb, x23, y23, x3, y3, objspace_flatness_squared, n + 1);
    } else {
        stbtt__add_point(points, num_points.*, x3, y3);
        num_points.* = num_points.* + 1;
    }
}

// returns number of contours
fn stbtt_FlattenCurves(vertices: [*c]stbtt_vertex, num_verts: c_int, objspace_flatness: f32, contour_lengths: [*c][*c]c_int, num_contours: [*c]c_int, userdata: ?*anyopaque) [*c]stbtt__point {
    _ = userdata; // STBTT_malloc / STBTT_free ignore user (font_raster.c)
    var points: [*c]stbtt__point = null;
    var num_points: c_int = 0;
    const objspace_flatness_squared: f32 = objspace_flatness * objspace_flatness;
    var i: c_int = 0;
    var n: c_int = 0;
    var start: c_int = 0;
    var pass: c_int = undefined;

    // count how many "moves" there are to get the contour count
    while (i < num_verts) : (i += 1) {
        if (vertices[@intCast(i)].type == STBTT_vmove)
            n += 1;
    }
    num_contours.* = n;
    if (n == 0) return null;
    contour_lengths.* = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(c_int) * @as(usize, @intCast(n)))));
    if (contour_lengths.* == null) {
        num_contours.* = 0;
        return null;
    }

    // make two passes through the points so we don't need to realloc
    var failed = false;
    pass = 0;
    while (pass < 2) : (pass += 1) {
        var x: f32 = 0;
        var y: f32 = 0;
        if (pass == 1) {
            points = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(num_points)) * @sizeOf(stbtt__point))));
            if (points == null) {
                // goto error
                failed = true;
                break;
            }
        }
        num_points = 0;
        n = -1;
        i = 0;
        while (i < num_verts) : (i += 1) {
            switch (vertices[@intCast(i)].type) {
                STBTT_vmove => {
                    // start the next contour
                    if (n >= 0)
                        contour_lengths.*[@intCast(n)] = num_points - start;
                    n += 1;
                    start = num_points;
                    x = @floatFromInt(vertices[@intCast(i)].x);
                    y = @floatFromInt(vertices[@intCast(i)].y);
                    stbtt__add_point(points, num_points, x, y);
                    num_points += 1;
                },
                STBTT_vline => {
                    x = @floatFromInt(vertices[@intCast(i)].x);
                    y = @floatFromInt(vertices[@intCast(i)].y);
                    stbtt__add_point(points, num_points, x, y);
                    num_points += 1;
                },
                STBTT_vcurve => {
                    _ = stbtt__tesselate_curve(points, &num_points, x, y, @floatFromInt(vertices[@intCast(i)].cx), @floatFromInt(vertices[@intCast(i)].cy), @floatFromInt(vertices[@intCast(i)].x), @floatFromInt(vertices[@intCast(i)].y), objspace_flatness_squared, 0);
                    x = @floatFromInt(vertices[@intCast(i)].x);
                    y = @floatFromInt(vertices[@intCast(i)].y);
                },
                STBTT_vcubic => {
                    stbtt__tesselate_cubic(points, &num_points, x, y, @floatFromInt(vertices[@intCast(i)].cx), @floatFromInt(vertices[@intCast(i)].cy), @floatFromInt(vertices[@intCast(i)].cx1), @floatFromInt(vertices[@intCast(i)].cy1), @floatFromInt(vertices[@intCast(i)].x), @floatFromInt(vertices[@intCast(i)].y), objspace_flatness_squared, 0);
                    x = @floatFromInt(vertices[@intCast(i)].x);
                    y = @floatFromInt(vertices[@intCast(i)].y);
                },
                else => {},
            }
        }
        contour_lengths.*[@intCast(n)] = num_points - start;
    }
    if (failed) {
        base.rvn_free(points);
        base.rvn_free(contour_lengths.*);
        contour_lengths.* = null;
        num_contours.* = 0;
        return null;
    }
    return points;
}

pub fn stbtt_Rasterize(result: [*c]stbtt__bitmap, flatness_in_pixels: f32, vertices: [*c]stbtt_vertex, num_verts: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, x_off: c_int, y_off: c_int, invert: c_int, userdata: ?*anyopaque) void {
    const scale: f32 = if (scale_x > scale_y) scale_y else scale_x;
    var winding_count: c_int = 0;
    var winding_lengths: [*c]c_int = null;
    const windings: [*c]stbtt__point = stbtt_FlattenCurves(vertices, num_verts, flatness_in_pixels / scale, &winding_lengths, &winding_count, userdata);
    if (windings != null) {
        stbtt__rasterize(result, windings, winding_lengths, winding_count, scale_x, scale_y, shift_x, shift_y, x_off, y_off, invert, userdata);
        base.rvn_free(winding_lengths);
        base.rvn_free(windings);
    }
}

pub fn stbtt_MakeGlyphBitmapSubpixel(info: [*c]const stbtt_fontinfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, glyph: c_int) void {
    var ix0: c_int = undefined;
    var iy0: c_int = undefined;
    var vertices: [*c]stbtt_vertex = undefined;
    const num_verts: c_int = stbtt_GetGlyphShape(info, glyph, &vertices);
    var gbm: stbtt__bitmap = undefined;

    stbtt_GetGlyphBitmapBoxSubpixel(info, glyph, scale_x, scale_y, shift_x, shift_y, &ix0, &iy0, null, null);
    gbm.pixels = output;
    gbm.w = out_w;
    gbm.h = out_h;
    gbm.stride = out_stride;

    if (gbm.w != 0 and gbm.h != 0)
        stbtt_Rasterize(&gbm, 0.35, vertices, num_verts, scale_x, scale_y, shift_x, shift_y, ix0, iy0, 1, info.*.userdata);

    base.rvn_free(vertices);
}

pub fn stbtt_MakeGlyphBitmap(info: [*c]const stbtt_fontinfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, glyph: c_int) void {
    stbtt_MakeGlyphBitmapSubpixel(info, output, out_w, out_h, out_stride, scale_x, scale_y, 0.0, 0.0, glyph);
}
