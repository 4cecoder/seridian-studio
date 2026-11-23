// Translated to Zig from vendor/raven/src/core/utf8.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/utf8.c
// UTF-8 decoding, encoding and caret movement.

export fn rvn_utf8_decode(text: [*c][*c]const u8, end: [*c]const u8) u32 {
    var s: [*c]const u8 = text.*;
    const e: [*c]const u8 = end;
    var cp: u32 = undefined;
    var extra: c_int = undefined;
    var i: c_int = undefined;

    if (s >= e) return 0;
    const c: u32 = s[0];
    s += 1;
    if (c < 0x80) {
        text.* = s;
        return c;
    }
    if ((c & 0xE0) == 0xC0) {
        cp = c & 0x1F;
        extra = 1;
    } else if ((c & 0xF0) == 0xE0) {
        cp = c & 0x0F;
        extra = 2;
    } else if ((c & 0xF8) == 0xF0) {
        cp = c & 0x07;
        extra = 3;
    } else {
        text.* = s;
        return 0xFFFD;
    }
    i = 0;
    while (i < extra) : (i += 1) {
        if (s >= e or (s[0] & 0xC0) != 0x80) {
            text.* = s;
            return 0xFFFD;
        }
        cp = (cp << 6) | (s[0] & 0x3F);
        s += 1;
    }
    text.* = s;
    // reject overlong forms, surrogates and out-of-range values
    if ((extra == 1 and cp < 0x80) or (extra == 2 and cp < 0x800) or (extra == 3 and cp < 0x10000) or
        (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF)
    {
        return 0xFFFD;
    }
    return cp;
}

export fn rvn_utf8_encode(cp: u32, out: [*c]u8) c_int {
    if (cp < 0x80) {
        out[0] = @truncate(cp);
        return 1;
    }
    if (cp < 0x800) {
        out[0] = @truncate(0xC0 | (cp >> 6));
        out[1] = @truncate(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = @truncate(0xE0 | (cp >> 12));
        out[1] = @truncate(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @truncate(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = @truncate(0xF0 | ((cp >> 18) & 0x07));
    out[1] = @truncate(0x80 | ((cp >> 12) & 0x3F));
    out[2] = @truncate(0x80 | ((cp >> 6) & 0x3F));
    out[3] = @truncate(0x80 | (cp & 0x3F));
    return 4;
}

export fn rvn_utf8_next(text: [*c]const u8, length: c_int, offset_in: c_int) c_int {
    var offset = offset_in;
    if (offset >= length) return length;
    offset += 1;
    // text[offset] in C is pointer arithmetic with a signed offset; the bit cast gives the same address.
    while (offset < length and (text[@as(usize, @bitCast(@as(isize, offset)))] & 0xC0) == 0x80) offset += 1;
    return offset;
}

export fn rvn_utf8_prev(text: [*c]const u8, offset_in: c_int) c_int {
    var offset = offset_in;
    if (offset <= 0) return 0;
    offset -= 1;
    while (offset > 0 and (text[@intCast(offset)] & 0xC0) == 0x80) offset -= 1;
    return offset;
}

export fn rvn_utf8_count(text: [*c]const u8, length: c_int) c_int {
    var i: c_int = 0;
    var count: c_int = 0;
    while (i < length) : (i += 1) {
        if ((text[@intCast(i)] & 0xC0) != 0x80) count += 1;
    }
    return count;
}
