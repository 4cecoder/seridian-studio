// Translated to Zig from vendor/raven/src/render/bidi.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/bidi.c
// Text written from right to left: the order in which a line is drawn, and
// the shapes of the Arabic letters.
//
// A line is kept in its logical order (the order it is typed in) everywhere
// in Raven; only drawing and measuring see it in visual order:
//
//   1. Arabic letters take their joined shape (isolated, initial, medial,
//      final, from the presentation forms of Unicode) and lam + alef become
//      one ligature: Arabic is readable with any font that has those forms.
//   2. The bidirectional algorithm of Unicode (UAX #9) gives each character a
//      level, from the strong characters around it: a paragraph that starts
//      with Arabic or Hebrew is right to left, English inside it stays left to
//      right, numbers stay in their order, the punctuation between two runs
//      takes the direction of the paragraph. This is the implicit part of the
//      algorithm (rules W1-W7, N1-N2, I1-I2, L2, L4), without the explicit
//      embeddings (U+202A..U+202E and the isolates are ignored and not drawn).
//   3. The runs of odd level are reversed, and the brackets in them mirrored.

const raven = @import("raven");
const base = @import("../core/base_h.zig");

/// typedef enum rvn_bidi_class_t { ... } rvn_bidi_class_t;
const rvn_bidi_class_t = c_uint;
const RVN_BIDI_L: rvn_bidi_class_t = 0; // strong left to right
const RVN_BIDI_R: rvn_bidi_class_t = 1; // strong right to left (Hebrew, Arabic letters)
const RVN_BIDI_EN: rvn_bidi_class_t = 2; // European digit
const RVN_BIDI_AN: rvn_bidi_class_t = 3; // Arabic digit
const RVN_BIDI_ES: rvn_bidi_class_t = 4; // + -
const RVN_BIDI_CS: rvn_bidi_class_t = 5; // , . : /
const RVN_BIDI_ET: rvn_bidi_class_t = 6; // # $ % ° currency
const RVN_BIDI_NSM: rvn_bidi_class_t = 7; // combining mark: the class of what it is on
const RVN_BIDI_WS: rvn_bidi_class_t = 8; // space
const RVN_BIDI_ON: rvn_bidi_class_t = 9; // other neutral
const RVN_BIDI_AL: rvn_bidi_class_t = 10; // Arabic letter (strong right to left, makes digits Arabic)

fn rvn_bidi_is_rtl_codepoint(c: u32) c_int {
    return if ((c >= 0x0590 and c <= 0x08FF) or (c >= 0xFB1D and c <= 0xFDFF) or (c >= 0xFE70 and c <= 0xFEFE) or
        (c >= 0x10800 and c <= 0x10FFF) or (c >= 0x1E800 and c <= 0x1EFFF)) raven.R_TRUE else raven.R_FALSE;
}

fn rvn_bidi_class(c: u32) rvn_bidi_class_t {
    if (c >= '0' and c <= '9') return RVN_BIDI_EN;
    if (c == ' ' or c == '\t' or c == 0x00A0 or c == 0x2007 or c == 0x202F or (c >= 0x2000 and c <= 0x200A) or c == 0x3000) return RVN_BIDI_WS;
    if (c == '+' or c == '-' or c == 0x2212) return RVN_BIDI_ES;
    if (c == ',' or c == '.' or c == ':' or c == '/' or c == 0x060C or c == 0x00A0) return RVN_BIDI_CS;
    if (c == '#' or c == '$' or c == '%' or c == 0x00B0 or c == 0x00A2 or c == 0x00A3 or c == 0x00A5 or c == 0x20AC or (c >= 0x20A0 and c <= 0x20CF) or c == 0x066A)
        return RVN_BIDI_ET;
    if ((c >= 0x0300 and c <= 0x036F) or (c >= 0x0591 and c <= 0x05BD) or c == 0x05BF or c == 0x05C1 or c == 0x05C2 or c == 0x05C4 or c == 0x05C5 or c == 0x05C7 or
        (c >= 0x0610 and c <= 0x061A) or (c >= 0x064B and c <= 0x065F) or c == 0x0670 or (c >= 0x06D6 and c <= 0x06DC) or (c >= 0x06DF and c <= 0x06E4) or
        c == 0x06E7 or c == 0x06E8 or (c >= 0x06EA and c <= 0x06ED) or (c >= 0xFE00 and c <= 0xFE0F) or (c >= 0x20D0 and c <= 0x20FF))
        return RVN_BIDI_NSM;
    if ((c >= 0x0660 and c <= 0x0669) or c == 0x066B or c == 0x066C) return RVN_BIDI_AN;
    if (c >= 0x06F0 and c <= 0x06F9) return RVN_BIDI_EN;
    if ((c >= 0x0600 and c <= 0x07BF) or (c >= 0x0860 and c <= 0x08FF) or (c >= 0xFB50 and c <= 0xFDFF) or (c >= 0xFE70 and c <= 0xFEFE)) return RVN_BIDI_AL;
    if (rvn_bidi_is_rtl_codepoint(c) != 0) return RVN_BIDI_R;
    if (c < 0x80) {
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) return RVN_BIDI_L;
        return RVN_BIDI_ON;
    }
    // general punctuation, symbols, arrows, box drawing, emoji: neutral
    if ((c >= 0x2010 and c <= 0x2BFF) or (c >= 0x3001 and c <= 0x3003) or (c >= 0xFE10 and c <= 0xFE6F) or (c >= 0x1F000 and c <= 0x1FAFF) or
        c == 0x00AB or c == 0x00BB or c == 0x00A1 or c == 0x00BF or c == 0x00A7 or c == 0x00B7 or c == 0x00D7 or c == 0x00F7)
        return RVN_BIDI_ON;
    return RVN_BIDI_L;
}

// Explicit formatting characters: not drawn (their effect is not applied).
fn rvn_bidi_is_format(c: u32) c_int {
    return if (c == 0x200E or c == 0x200F or c == 0x061C or (c >= 0x202A and c <= 0x202E) or (c >= 0x2066 and c <= 0x2069)) raven.R_TRUE else raven.R_FALSE;
}

export fn rvn_bidi_needed(text: [*c]const u8, length: c_int) c_int {
    var cursor: [*c]const u8 = text;
    const end: [*c]const u8 = @ptrFromInt(@intFromPtr(text) +% @as(usize, @bitCast(@as(isize, length))));
    while (cursor < end) {
        // everything below U+0590 is two bytes or less with a lead byte below 0xD6
        if (cursor.* < 0xD6) {
            cursor += 1;
            continue;
        }
        {
            const c = base.rvn_utf8_decode(&cursor, end);
            if (rvn_bidi_is_rtl_codepoint(c) != 0 or rvn_bidi_is_format(c) != 0) return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

// ---------------------------------------------------------------------------
//  Arabic shaping
// ---------------------------------------------------------------------------

// Joining of a letter: 0 none, 1 joins on its right only (to the letter before it), 2 on both sides.
const rvn_arabic_form_t = extern struct {
    letter: u16,
    isolated: u16, // the final form is isolated + 1; initial + 2 and medial + 3 for dual-joining letters
    joining: u8,
};

const g_arabic_forms = [_]rvn_arabic_form_t{
    .{ .letter = 0x0621, .isolated = 0xFE80, .joining = 0 }, .{ .letter = 0x0622, .isolated = 0xFE81, .joining = 1 }, .{ .letter = 0x0623, .isolated = 0xFE83, .joining = 1 }, .{ .letter = 0x0624, .isolated = 0xFE85, .joining = 1 }, .{ .letter = 0x0625, .isolated = 0xFE87, .joining = 1 },
    .{ .letter = 0x0626, .isolated = 0xFE89, .joining = 2 }, .{ .letter = 0x0627, .isolated = 0xFE8D, .joining = 1 }, .{ .letter = 0x0628, .isolated = 0xFE8F, .joining = 2 }, .{ .letter = 0x0629, .isolated = 0xFE93, .joining = 1 }, .{ .letter = 0x062A, .isolated = 0xFE95, .joining = 2 },
    .{ .letter = 0x062B, .isolated = 0xFE99, .joining = 2 }, .{ .letter = 0x062C, .isolated = 0xFE9D, .joining = 2 }, .{ .letter = 0x062D, .isolated = 0xFEA1, .joining = 2 }, .{ .letter = 0x062E, .isolated = 0xFEA5, .joining = 2 }, .{ .letter = 0x062F, .isolated = 0xFEA9, .joining = 1 },
    .{ .letter = 0x0630, .isolated = 0xFEAB, .joining = 1 }, .{ .letter = 0x0631, .isolated = 0xFEAD, .joining = 1 }, .{ .letter = 0x0632, .isolated = 0xFEAF, .joining = 1 }, .{ .letter = 0x0633, .isolated = 0xFEB1, .joining = 2 }, .{ .letter = 0x0634, .isolated = 0xFEB5, .joining = 2 },
    .{ .letter = 0x0635, .isolated = 0xFEB9, .joining = 2 }, .{ .letter = 0x0636, .isolated = 0xFEBD, .joining = 2 }, .{ .letter = 0x0637, .isolated = 0xFEC1, .joining = 2 }, .{ .letter = 0x0638, .isolated = 0xFEC5, .joining = 2 }, .{ .letter = 0x0639, .isolated = 0xFEC9, .joining = 2 },
    .{ .letter = 0x063A, .isolated = 0xFECD, .joining = 2 }, .{ .letter = 0x0641, .isolated = 0xFED1, .joining = 2 }, .{ .letter = 0x0642, .isolated = 0xFED5, .joining = 2 }, .{ .letter = 0x0643, .isolated = 0xFED9, .joining = 2 }, .{ .letter = 0x0644, .isolated = 0xFEDD, .joining = 2 },
    .{ .letter = 0x0645, .isolated = 0xFEE1, .joining = 2 }, .{ .letter = 0x0646, .isolated = 0xFEE5, .joining = 2 }, .{ .letter = 0x0647, .isolated = 0xFEE9, .joining = 2 }, .{ .letter = 0x0648, .isolated = 0xFEED, .joining = 1 }, .{ .letter = 0x0649, .isolated = 0xFEEF, .joining = 1 },
    .{ .letter = 0x064A, .isolated = 0xFEF1, .joining = 2 },
    // Persian and Urdu letters
    .{ .letter = 0x067E, .isolated = 0xFB56, .joining = 2 }, .{ .letter = 0x0686, .isolated = 0xFB7A, .joining = 2 }, .{ .letter = 0x0698, .isolated = 0xFB8A, .joining = 1 }, .{ .letter = 0x06A9, .isolated = 0xFB8E, .joining = 2 }, .{ .letter = 0x06AF, .isolated = 0xFB92, .joining = 2 },
    .{ .letter = 0x06CC, .isolated = 0xFBFC, .joining = 2 }, .{ .letter = 0x0679, .isolated = 0xFB66, .joining = 2 }, .{ .letter = 0x0688, .isolated = 0xFB88, .joining = 1 }, .{ .letter = 0x0691, .isolated = 0xFB8C, .joining = 1 }, .{ .letter = 0x06BA, .isolated = 0xFB9E, .joining = 1 },
    .{ .letter = 0x06BE, .isolated = 0xFBAA, .joining = 2 }, .{ .letter = 0x06C1, .isolated = 0xFBA6, .joining = 2 }, .{ .letter = 0x06D2, .isolated = 0xFBAE, .joining = 1 },
};

fn rvn_arabic_form(c: u32) ?*const rvn_arabic_form_t {
    var lo: usize = 0;
    const hi: usize = g_arabic_forms.len;
    // (sorted in two parts: search both)
    var i: usize = 36;
    if (c >= 0x0621 and c <= 0x064A) {
        while (lo < 36 and g_arabic_forms[lo].letter < c) lo += 1;
        return if (lo < 36 and g_arabic_forms[lo].letter == c) &g_arabic_forms[lo] else null;
    }
    while (i < hi) : (i += 1) {
        if (g_arabic_forms[i].letter == c) return &g_arabic_forms[i];
    }
    return null;
}

// Letters that join to the next one (dual joining) and the tatweel.
fn rvn_arabic_joins_left(c: u32) c_int {
    if (c == 0x0640) return raven.R_TRUE;
    const form = rvn_arabic_form(c);
    if (form) |f| return if (f.joining == 2) raven.R_TRUE else raven.R_FALSE;
    return raven.R_FALSE;
}

fn rvn_arabic_joins_right(c: u32) c_int {
    if (c == 0x0640) return raven.R_TRUE;
    if (rvn_arabic_form(c)) |f| return if (f.joining > 0) raven.R_TRUE else raven.R_FALSE;
    return raven.R_FALSE;
}

fn rvn_arabic_transparent(c: u32) c_int {
    return if (rvn_bidi_class(c) == RVN_BIDI_NSM) raven.R_TRUE else raven.R_FALSE;
}

// Shapes src[0..n) (logical order, unshaped letters) into dst; a lam-alef pair
// leaves out its alef. Returns the number of characters written.
fn rvn_arabic_shape(src: [*c]const u32, dst: [*c]u32, n: c_int) c_int {
    var i: c_int = 0;
    var k: c_int = undefined;
    var out: c_int = 0;
    while (i < n) : (i += 1) {
        const form = rvn_arabic_form(src[@intCast(i)]) orelse {
            // (an alef eaten by the lam before it is marked 0)
            dst[@intCast(i)] = src[@intCast(i)];
            continue;
        };
        var before: u32 = 0;
        var after: u32 = 0;
        k = i - 1;
        while (k >= 0 and rvn_arabic_transparent(src[@intCast(k)]) != 0) : (k -= 1) {}
        if (k >= 0) before = src[@intCast(k)];
        k = i + 1;
        while (k < n and rvn_arabic_transparent(src[@intCast(k)]) != 0) : (k += 1) {}
        const after_index: c_int = k;
        if (k < n) after = src[@intCast(k)];
        const join_before: c_int = if (before != 0 and rvn_arabic_joins_left(before) != 0) raven.R_TRUE else raven.R_FALSE;
        const join_after: c_int = if (after != 0 and form.joining == 2 and rvn_arabic_joins_right(after) != 0) raven.R_TRUE else raven.R_FALSE;

        // lam + alef: one ligature
        if (src[@intCast(i)] == 0x0644 and after_index < n and (after == 0x0622 or after == 0x0623 or after == 0x0625 or after == 0x0627)) {
            const ligature: u32 = if (after == 0x0622) 0xFEF5 else if (after == 0x0623) 0xFEF7 else if (after == 0x0625) 0xFEF9 else 0xFEFB;
            dst[@intCast(i)] = if (join_before != 0) ligature + 1 else ligature;
            // the marks between them stay; the alef goes
            k = i + 1;
            while (k < after_index) : (k += 1) dst[@intCast(k)] = src[@intCast(k)];
            dst[@intCast(after_index)] = 0;
            i = after_index;
            continue;
        }
        const iso: u32 = form.isolated;
        if (form.joining == 0) dst[@intCast(i)] = iso
        else if (form.joining == 1) dst[@intCast(i)] = if (join_before != 0) iso + 1 else iso
        else if (join_before != 0 and join_after != 0) dst[@intCast(i)] = iso + 3
        else if (join_before != 0) dst[@intCast(i)] = iso + 1
        else if (join_after != 0) dst[@intCast(i)] = iso + 2
        else dst[@intCast(i)] = iso;
    }
    i = 0;
    while (i < n) : (i += 1) {
        if (dst[@intCast(i)] != 0) {
            dst[@intCast(out)] = dst[@intCast(i)];
            out += 1;
        }
    }
    return out;
}

// rvn_arabic_joins_left must also know the shaped forms (the letter before is shaped first).
fn rvn_arabic_unshape(c: u32) u32 {
    var i: usize = 0;
    if (c < 0xFB50) return c;
    while (i < g_arabic_forms.len) : (i += 1) {
        const base_: u32 = g_arabic_forms[i].isolated;
        const span: u32 = if (g_arabic_forms[i].joining == 2) 4 else if (g_arabic_forms[i].joining == 1) 2 else 1;
        if (c >= base_ and c < base_ + span) return g_arabic_forms[i].letter;
    }
    if (c >= 0xFEF5 and c <= 0xFEFC) return 0x0627; // a lam-alef joins like an alef: on its right only
    return c;
}

// ---------------------------------------------------------------------------
//  Bidirectional algorithm (implicit levels)
// ---------------------------------------------------------------------------

fn rvn_bidi_mirror(c: u32) u32 {
    return switch (c) {
        '(' => ')',
        ')' => '(',
        '[' => ']',
        ']' => '[',
        '{' => '}',
        '}' => '{',
        '<' => '>',
        '>' => '<',
        0x00AB => 0x00BB,
        0x00BB => 0x00AB,
        0x2039 => 0x203A,
        0x203A => 0x2039,
        0x2264 => 0x2265,
        0x2265 => 0x2264,
        else => c,
    };
}

fn rvn_bidi_strong_rtl(t: rvn_bidi_class_t) c_int {
    return if (t == RVN_BIDI_R or t == RVN_BIDI_AL) raven.R_TRUE else raven.R_FALSE;
}

export fn rvn_bidi_paragraph_rtl(text: [*c]const u8, length: c_int) c_int {
    var cursor: [*c]const u8 = text;
    const end: [*c]const u8 = @ptrFromInt(@intFromPtr(text) +% @as(usize, @bitCast(@as(isize, length))));
    while (cursor < end) {
        const t = rvn_bidi_class(base.rvn_utf8_decode(&cursor, end));
        if (t == RVN_BIDI_L) return raven.R_FALSE;
        if (rvn_bidi_strong_rtl(t) != 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn rvn_bidi_levels(cp: [*c]const u32, n: c_int, base_: c_int, levels: [*c]u8, t: [*c]rvn_bidi_class_t) void {
    var i: c_int = 0;
    var j: c_int = 0;
    const sor: rvn_bidi_class_t = if (base_ != 0) RVN_BIDI_R else RVN_BIDI_L;
    while (i < n) : (i += 1) t[@intCast(i)] = rvn_bidi_class(cp[@intCast(i)]);

    // W1: a mark takes the class of what it is on
    i = 0;
    while (i < n) : (i += 1) {
        if (t[@intCast(i)] == RVN_BIDI_NSM) t[@intCast(i)] = if (i != 0) t[@intCast(i - 1)] else sor;
    }
    // W2: European digits after an Arabic letter are Arabic digits; W3: AL -> R
    {
        var last: rvn_bidi_class_t = sor;
        i = 0;
        while (i < n) : (i += 1) {
            if (t[@intCast(i)] == RVN_BIDI_L or t[@intCast(i)] == RVN_BIDI_R or t[@intCast(i)] == RVN_BIDI_AL) {
                last = t[@intCast(i)];
            } else if (t[@intCast(i)] == RVN_BIDI_EN and last == RVN_BIDI_AL) {
                t[@intCast(i)] = RVN_BIDI_AN;
            }
        }
        i = 0;
        while (i < n) : (i += 1) {
            if (t[@intCast(i)] == RVN_BIDI_AL) t[@intCast(i)] = RVN_BIDI_R;
        }
    }
    // W4: a single separator between two numbers of the same kind joins them
    i = 1;
    while (i + 1 < n) : (i += 1) {
        if (t[@intCast(i)] == RVN_BIDI_ES and t[@intCast(i - 1)] == RVN_BIDI_EN and t[@intCast(i + 1)] == RVN_BIDI_EN) {
            t[@intCast(i)] = RVN_BIDI_EN;
        } else if (t[@intCast(i)] == RVN_BIDI_CS and t[@intCast(i - 1)] == t[@intCast(i + 1)] and
            (t[@intCast(i - 1)] == RVN_BIDI_EN or t[@intCast(i - 1)] == RVN_BIDI_AN))
        {
            t[@intCast(i)] = t[@intCast(i - 1)];
        }
    }
    // W5: terminators next to European digits are European digits
    i = 0;
    while (i < n) : (i += 1) {
        if (t[@intCast(i)] != RVN_BIDI_ET) continue;
        j = i;
        while (j < n and t[@intCast(j)] == RVN_BIDI_ET) : (j += 1) {}
        if ((i > 0 and t[@intCast(i - 1)] == RVN_BIDI_EN) or (j < n and t[@intCast(j)] == RVN_BIDI_EN)) {
            var k: c_int = i;
            while (k < j) : (k += 1) t[@intCast(k)] = RVN_BIDI_EN;
        }
        i = j - 1;
    }
    // W6: the other separators and terminators are neutral
    i = 0;
    while (i < n) : (i += 1) {
        if (t[@intCast(i)] == RVN_BIDI_ES or t[@intCast(i)] == RVN_BIDI_CS or t[@intCast(i)] == RVN_BIDI_ET) t[@intCast(i)] = RVN_BIDI_ON;
    }
    // W7: European digits after a strong L are L
    {
        var last: rvn_bidi_class_t = sor;
        i = 0;
        while (i < n) : (i += 1) {
            if (t[@intCast(i)] == RVN_BIDI_L or t[@intCast(i)] == RVN_BIDI_R) {
                last = t[@intCast(i)];
            } else if (t[@intCast(i)] == RVN_BIDI_EN and last == RVN_BIDI_L) {
                t[@intCast(i)] = RVN_BIDI_L;
            }
        }
    }
    // N1, N2: a run of neutrals between two of the same direction takes it, else the paragraph's
    i = 0;
    while (i < n) : (i += 1) {
        if (t[@intCast(i)] != RVN_BIDI_ON and t[@intCast(i)] != RVN_BIDI_WS) continue;
        j = i;
        while (j < n and (t[@intCast(j)] == RVN_BIDI_ON or t[@intCast(j)] == RVN_BIDI_WS)) : (j += 1) {}
        var before: rvn_bidi_class_t = if (i != 0) t[@intCast(i - 1)] else sor;
        var after: rvn_bidi_class_t = if (j < n) t[@intCast(j)] else sor;
        if (before == RVN_BIDI_EN or before == RVN_BIDI_AN) before = RVN_BIDI_R;
        if (after == RVN_BIDI_EN or after == RVN_BIDI_AN) after = RVN_BIDI_R;
        const side: rvn_bidi_class_t = if (before == after) before else if (base_ != 0) RVN_BIDI_R else RVN_BIDI_L;
        {
            var k: c_int = i;
            while (k < j) : (k += 1) t[@intCast(k)] = side;
        }
        i = j - 1;
    }
    // I1, I2
    i = 0;
    while (i < n) : (i += 1) {
        const ti = t[@intCast(i)];
        if (base_ == 0) {
            levels[@intCast(i)] = if (ti == RVN_BIDI_R) 1 else if (ti == RVN_BIDI_AN or ti == RVN_BIDI_EN) 2 else 0;
        } else {
            levels[@intCast(i)] = if (ti == RVN_BIDI_L or ti == RVN_BIDI_EN or ti == RVN_BIDI_AN) 2 else 1;
        }
    }
    // L1: the spaces at the end of the line go back to the paragraph level
    i = n - 1;
    while (i >= 0 and rvn_bidi_class(cp[@intCast(i)]) == RVN_BIDI_WS) : (i -= 1) {
        levels[@intCast(i)] = @intCast(base_);
    }
}

fn rvn_bidi_reverse(cp: [*c]u32, from_: c_int, to_: c_int) void {
    var from = from_;
    var to = to_;
    while (from < to) {
        const swap = cp[@intCast(from)];
        cp[@intCast(from)] = cp[@intCast(to)];
        from += 1;
        cp[@intCast(to)] = swap;
        to -= 1;
    }
}

fn rvn_bidi_reverse_levels(levels: [*c]u8, from_: c_int, to_: c_int) void {
    var from = from_;
    var to = to_;
    while (from < to) {
        const swap = levels[@intCast(from)];
        levels[@intCast(from)] = levels[@intCast(to)];
        from += 1;
        levels[@intCast(to)] = swap;
        to -= 1;
    }
}

/// The line in the order it is drawn, Arabic shaped, as new UTF-8 (rvn_free).
export fn rvn_bidi_visual(text: [*c]const u8, length: c_int, out_length: [*c]c_int) [*c]u8 {
    var cursor: [*c]const u8 = text;
    const end: [*c]const u8 = @ptrFromInt(@intFromPtr(text) +% @as(usize, @bitCast(@as(isize, length))));
    const length_size: usize = @as(usize, @bitCast(@as(isize, length)));
    const cp: [*c]u32 = @ptrCast(@alignCast(base.rvn_alloc((length_size +% 1) *% @sizeOf(u32))));
    var n: c_int = 0;
    var i: c_int = 0;
    var base_: c_int = 0;
    var highest: c_int = 0;
    var level: c_int = 0;
    var size: c_int = 0;

    while (cursor < end) {
        const c = base.rvn_utf8_decode(&cursor, end);
        if (rvn_bidi_is_format(c) != 0) continue;
        cp[@intCast(n)] = c;
        n += 1;
    }
    const n_size: usize = @as(usize, @intCast(n));
    const original: [*c]u32 = @ptrCast(@alignCast(base.rvn_alloc((n_size + 1) * @sizeOf(u32))));
    @memcpy(original[0..n_size], cp[0..n_size]);

    // the paragraph direction, from the first strong character
    base_ = 0;
    i = 0;
    while (i < n) : (i += 1) {
        const t = rvn_bidi_class(cp[@intCast(i)]);
        if (t == RVN_BIDI_L) break;
        if (rvn_bidi_strong_rtl(t) != 0) {
            base_ = 1;
            break;
        }
    }

    // shaping (logical order), from the base letters (a text may already hold presentation forms)
    i = 0;
    while (i < n) : (i += 1) original[@intCast(i)] = rvn_arabic_unshape(cp[@intCast(i)]);
    n = rvn_arabic_shape(original, cp, n);
    base.rvn_free(original);

    const levels: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(n)) + 1)));
    const classes: [*c]rvn_bidi_class_t = @ptrCast(@alignCast(base.rvn_alloc((@as(usize, @intCast(n)) + 1) * @sizeOf(rvn_bidi_class_t))));
    // (the classes of the shaped forms are the classes of their letters: AL)
    rvn_bidi_levels(cp, n, base_, levels, classes);

    // mirrored brackets in the right-to-left runs
    i = 0;
    while (i < n) : (i += 1) {
        if (@as(c_int, levels[@intCast(i)]) > highest) highest = @as(c_int, levels[@intCast(i)]);
        if ((levels[@intCast(i)] & 1) != 0) cp[@intCast(i)] = rvn_bidi_mirror(cp[@intCast(i)]);
    }
    // L2: from the highest level down to the lowest odd one, reverse every run at or above it
    level = highest;
    while (level >= 1) : (level -= 1) {
        i = 0;
        while (i < n) : (i += 1) {
            if (@as(c_int, levels[@intCast(i)]) < level) continue;
            var j: c_int = i;
            while (j < n and @as(c_int, levels[@intCast(j)]) >= level) : (j += 1) {}
            rvn_bidi_reverse(cp, i, j - 1);
            rvn_bidi_reverse_levels(levels, i, j - 1);
            i = j;
        }
    }

    const out: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(n)) * 4 + 1)));
    i = 0;
    while (i < n) : (i += 1) size += base.rvn_utf8_encode(cp[@intCast(i)], out + @as(usize, @intCast(size)));
    out[@intCast(size)] = 0;
    out_length.* = size;
    base.rvn_free(cp);
    base.rvn_free(levels);
    base.rvn_free(classes);
    return out;
}
