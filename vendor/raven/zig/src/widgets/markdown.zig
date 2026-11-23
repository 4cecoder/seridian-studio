// Translated to Zig from vendor/raven/src/widgets/markdown.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/markdown.c
// Formatted text: reads Markdown, lays it out on a width and paints it. Used
// by the labels that have Markdown turned on.
//
// What is understood:
//   blocks   paragraphs, # titles (1 to 6), lists (-, *, +, 1.) and lists in
//            lists, task lists (- [ ] and - [x]), > quotes, ``` code ``` with
//            the colors of its language, --- rules, | tables | with the
//            alignment of their columns, images alone on their line
//   inline   **strong**, *emphasis*, ***both***, `code`, ~~struck~~,
//            [links](url), <url>, bare http(s) addresses, \escapes, two
//            spaces or a backslash at the end of a line for a line break,
//            the usual &entities;
//
// Three steps, each kept by the next: the text is parsed once into blocks
// and spans; the blocks are laid out when the width changes, into runs of
// text and boxes placed in the label; painting draws those.
//
// Translation notes: private booleans (C int holding R_TRUE / R_FALSE) are
// Zig `bool`; the exported functions keep the C types of common.h. The
// `rvn_md_t` of common.h is opaque there; this file defines its fields.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const font_h = @import("../render/font_h.zig");
const draw_h = @import("../render/draw_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const RVN_MD_BOLD = 1 << 0;
const RVN_MD_ITALIC = 1 << 1;
const RVN_MD_CODE = 1 << 2;
const RVN_MD_STRIKE = 1 << 3;
/// The line ends after this span.
const RVN_MD_BREAK = 1 << 4;

const RVN_MD_PARAGRAPH = 0;
const RVN_MD_HEADING = 1;
const RVN_MD_CODE_BLOCK = 2;
const RVN_MD_RULE = 3;
const RVN_MD_TABLE = 4;
const RVN_MD_IMAGE = 5;

const RVN_MD_NO_MARKER = 0;
const RVN_MD_BULLET = 1;
const RVN_MD_NUMBER = 2;
const RVN_MD_TASK = 3;
const RVN_MD_TASK_DONE = 4;

/// A piece of text with one look. `start` and `length` are in rvn_md_t::text.
const rvn_md_span_t = extern struct {
    start: u32,
    length: u32,
    flags: u16,
    /// Index in rvn_md_t::links, or -1.
    link: i16,
};

const rvn_md_block_t = extern struct {
    @"type": u8,
    /// Title: 1 to 6.
    level: u8,
    /// How many quotes it is in.
    quote: u8,
    /// How many lists it is in.
    list: u8,
    /// What is drawn before it when it starts a list item.
    marker: u8,
    number: c_int,
    /// Text of a paragraph or of a title; alternative text of an image.
    first_span: u32,
    span_count: u32,
    /// Code: its lines, in rvn_md_t::text, and the name of its language (0 length = none).
    code_start: u32,
    code_length: u32,
    language_start: u32,
    language_length: u32,
    /// Table: its cells, row after row, in rvn_md_t::cells; the first row is the header.
    first_cell: u32,
    columns: u16,
    rows: u16,
    /// Image: its address, in rvn_md_t::links.
    link: i16,
};

const rvn_md_cell_t = extern struct {
    first_span: u32,
    span_count: u32,
    /// 0 left, 1 center, 2 right.
    @"align": u8,
};

/// A kind of color of a run: text, link, quote, or RVN_MD_COLOR_TOKEN + rvn_token_t.
const RVN_MD_COLOR_TEXT = 0;
const RVN_MD_COLOR_LINK = 1;
const RVN_MD_COLOR_QUOTE = 2;
/// A kind of token of the code: RVN_MD_COLOR_TOKEN + rvn_token_t.
const RVN_MD_COLOR_TOKEN = 3;

/// Text placed by the layout: a part of a line with one font.
const rvn_md_run_t = extern struct {
    x: f32,
    y: f32,
    w: f32,
    /// The line it is on: where a click is on it.
    line_y: f32,
    line_h: f32,
    start: u32,
    length: u32,
    font: raven.Rid,
    size: f32,
    color: u8,
    flags: u8,
    link: i16,
    /// Code: nothing is drawn past this x (0 = no limit).
    clip_right: f32,
};

const RVN_MD_BOX_CODE = 0;
const RVN_MD_BOX_INLINE_CODE = 1;
const RVN_MD_BOX_QUOTE = 2;
const RVN_MD_BOX_RULE = 3;
const RVN_MD_BOX_BULLET = 4;
const RVN_MD_BOX_TASK = 5;
const RVN_MD_BOX_TASK_DONE = 6;
const RVN_MD_BOX_TABLE_HEADER = 7;
const RVN_MD_BOX_TABLE_LINE = 8;
const RVN_MD_BOX_IMAGE = 9;

const rvn_md_box_t = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    kind: u8,
    texture: raven.Rid,
};

pub const rvn_md_t = extern struct {
    /// Every character shown, escapes resolved. Spans and runs point into it.
    text: base.rvn_text_t,
    /// Its length after parsing: the layout adds the numbers of the lists after it.
    parsed_length: usize,
    spans: [*c]rvn_md_span_t,
    span_count: u32,
    span_cap: u32,
    blocks: [*c]rvn_md_block_t,
    block_count: u32,
    block_cap: u32,
    cells: [*c]rvn_md_cell_t,
    cell_count: u32,
    cell_cap: u32,
    links: [*c][*c]u8,
    link_count: u32,
    link_cap: u32,

    // layout
    runs: [*c]rvn_md_run_t,
    run_count: u32,
    run_cap: u32,
    boxes: [*c]rvn_md_box_t,
    box_count: u32,
    box_cap: u32,
    laid_width: f32,
    laid_size: f32,
    laid_font: raven.Rid,
    laid_generation: u32,
    laid: bool,
    size: base.rvn_vec2_t,
};

// ---------------------------------------------------------------------------
//  Parsing: inline
// ---------------------------------------------------------------------------

const rvn_md_inline_t = extern struct {
    md: [*c]rvn_md_t,
    flags: u32,
    link: c_int,
    /// Start, in md->text, of the span being filled.
    span_start: u32,
    /// Nothing was written on the line yet: white space does not start it.
    fresh: bool,
};

fn rvn_md_add_link(md: [*c]rvn_md_t, url: [*c]const u8, length: usize) c_int {
    if (md.*.link_count >= 32000) return -1;
    if (md.*.link_count + 1 > md.*.link_cap) md.*.links = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(md.*.links), &md.*.link_cap, md.*.link_count + 1, @sizeOf([*c]u8))));
    md.*.links[md.*.link_count] = base.rvn_strndup(url, length);
    const index = md.*.link_count;
    md.*.link_count += 1;
    return @intCast(index);
}

// Closes the span being filled, if it holds anything.
fn rvn_md_flush(in: [*c]rvn_md_inline_t, extra_flags: u32) void {
    const md = in.*.md;
    const end: u32 = @truncate(md.*.text.length);
    if (end > in.*.span_start or (extra_flags & RVN_MD_BREAK) != 0) {
        base.RVN_ARRAY_RESERVE(&md.*.spans, &md.*.span_cap, md.*.span_count + 1);
        const span = &md.*.spans[md.*.span_count];
        md.*.span_count += 1;
        span.start = in.*.span_start;
        span.length = end - in.*.span_start;
        span.flags = @truncate(in.*.flags | extra_flags);
        span.link = @intCast(in.*.link);
    }
    in.*.span_start = end;
}

fn rvn_md_put(in: [*c]rvn_md_inline_t, bytes: [*c]const u8, length: usize) void {
    base.rvn_text_append(&in.*.md.*.text, bytes, length);
    if (length != 0) in.*.fresh = false;
}

fn rvn_md_is_space(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn rvn_md_is_punct(c: u8) bool {
    return (c >= '!' and c <= '/') or (c >= ':' and c <= '@') or (c >= '[' and c <= '`') or (c >= '{' and c <= '~');
}

fn rvn_md_is_word(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c & 0x80) != 0;
}

// Is there, after `from`, the same run of `count` marks that could close what one opens here?
fn rvn_md_has_closer(from: [*c]const u8, end: [*c]const u8, mark: u8, count: usize) bool {
    var p = from;
    while (p < end) {
        if (p[0] == '\\' and p + 1 < end) {
            p += 2;
            continue;
        }
        if (p[0] == '`') {
            // marks inside code do not count
            var ticks: usize = 0;
            while (p + ticks < end and p[ticks] == '`') ticks += 1;
            var close = p + ticks;
            while (close < end) {
                var run: usize = 0;
                while (close + run < end and close[run] == '`') run += 1;
                if (run == ticks) break;
                close += if (run != 0) run else 1;
            }
            p = if (close < end) close + ticks else p + ticks;
            continue;
        }
        if (p[0] == mark) {
            var run: usize = 0;
            while (p + run < end and p[run] == mark) run += 1;
            if (run >= count and p > from and !rvn_md_is_space((p - 1)[0])) return true;
            p += run;
            continue;
        }
        p += 1;
    }
    return false;
}

const g_md_entities = [_]struct { name: [*c]const u8, text: [*c]const u8 }{
    .{ .name = "amp", .text = "&" },
    .{ .name = "lt", .text = "<" },
    .{ .name = "gt", .text = ">" },
    .{ .name = "quot", .text = "\"" },
    .{ .name = "apos", .text = "'" },
    .{ .name = "nbsp", .text = "\xC2\xA0" },
    .{ .name = "copy", .text = "\xC2\xA9" },
    .{ .name = "reg", .text = "\xC2\xAE" },
    .{ .name = "hellip", .text = "\xE2\x80\xA6" },
    .{ .name = "mdash", .text = "\xE2\x80\x94" },
    .{ .name = "ndash", .text = "\xE2\x80\x93" },
    .{ .name = "rarr", .text = "\xE2\x86\x92" },
    .{ .name = "larr", .text = "\xE2\x86\x90" },
    .{ .name = "times", .text = "\xC3\x97" },
};

// An entity at `p` ("&amp;"): writes what it stands for and returns its length, or 0.
fn rvn_md_entity(in: [*c]rvn_md_inline_t, p: [*c]const u8, end: [*c]const u8) usize {
    var semi = p + 1;
    while (semi < end and semi - p < 10 and semi[0] != ';' and !rvn_md_is_space(semi[0])) semi += 1;
    if (semi >= end or semi[0] != ';') return 0;
    const length: usize = @intCast(semi - p - 1);
    if (length >= 2 and p[1] == '#') {
        var code: u32 = 0;
        var utf8: [4]u8 = undefined;
        var digit = p + 2;
        const hex = digit[0] == 'x' or digit[0] == 'X';
        if (hex) digit += 1;
        if (digit == semi) return 0;
        while (digit < semi) : (digit += 1) {
            const c = digit[0];
            if (c >= '0' and c <= '9') {
                code = code *% @as(u32, if (hex) 16 else 10) +% @as(u32, c - '0');
            } else if (hex and c >= 'a' and c <= 'f') {
                code = code *% 16 +% (@as(u32, c) - 'a' + 10);
            } else if (hex and c >= 'A' and c <= 'F') {
                code = code *% 16 +% (@as(u32, c) - 'A' + 10);
            } else {
                return 0;
            }
        }
        if (code == 0 or code > 0x10FFFF) return 0;
        const written = base.rvn_utf8_encode(code, &utf8);
        rvn_md_put(in, &utf8, @intCast(written));
        return @as(usize, @intCast(semi - p)) + 1;
    }
    var i: usize = 0;
    while (i < g_md_entities.len) : (i += 1) {
        if (libc.strlen(g_md_entities[i].name) == length and libc.memcmp(g_md_entities[i].name, p + 1, length) == 0) {
            rvn_md_put(in, g_md_entities[i].text, libc.strlen(g_md_entities[i].text));
            return length + 2;
        }
    }
    return 0;
}

// The end of an address that starts at `p` (http://...), without the punctuation that ends a sentence.
fn rvn_md_url_end(p: [*c]const u8, end: [*c]const u8) [*c]const u8 {
    var stop = p;
    while (stop < end and !rvn_md_is_space(stop[0]) and stop[0] != '<' and stop[0] != '>' and stop[0] != '"') stop += 1;
    while (stop > p) {
        const last = (stop - 1)[0];
        const trailing = last == '.' or last == ',' or last == ';' or last == ':' or last == '!' or
            last == '?' or last == ')' or last == '\'' or last == '*' or last == '_';
        if (!trailing) break;
        stop -= 1;
    }
    return stop;
}

// "[text](url)" or "![alt](url)" at `p` (on the '['). Returns where it ends,
// or NULL when it is not one. `text_end` is the ']' and `url`, `url_length`
// the address.
fn rvn_md_link_parts(p: [*c]const u8, end: [*c]const u8, text_end: [*c][*c]const u8, url: [*c][*c]const u8, url_length: [*c]usize) [*c]const u8 {
    var close = p + 1;
    var nest: c_int = 1;
    while (close < end) {
        if (close[0] == '\\' and close + 1 < end) {
            close += 2;
            continue;
        }
        if (close[0] == '[') {
            nest += 1;
        } else if (close[0] == ']') {
            nest -= 1;
            if (nest == 0) break;
        }
        close += 1;
    }
    if (close >= end or close + 1 >= end or close[1] != '(') return null;
    var q = close + 2;
    while (q < end and (q[0] == ' ' or q[0] == '\n')) q += 1;
    url.* = q;
    if (q < end and q[0] == '<') {
        q += 1;
        url.* = q;
        while (q < end and q[0] != '>' and q[0] != '\n') q += 1;
        if (q >= end or q[0] != '>') return null;
        url_length.* = @intCast(q - url.*);
        q += 1;
    } else {
        var parens: c_int = 0;
        while (q < end and !rvn_md_is_space(q[0])) {
            if (q[0] == '(') {
                parens += 1;
            } else if (q[0] == ')') {
                const was_zero = parens == 0;
                parens -= 1;
                if (was_zero) break;
            }
            q += 1;
        }
        url_length.* = @intCast(q - url.*);
    }
    // an optional title, ignored: ("title")
    while (q < end and (q[0] == ' ' or q[0] == '\n')) q += 1;
    if (q < end and (q[0] == '"' or q[0] == '\'')) {
        const quote = q[0];
        q += 1;
        while (q < end and q[0] != quote) q += 1;
        if (q < end) q += 1;
        while (q < end and (q[0] == ' ' or q[0] == '\n')) q += 1;
    }
    if (q >= end or q[0] != ')') return null;
    text_end.* = close;
    return q + 1;
}

// Reads inline text into spans, with the looks that are on when it starts.
fn rvn_md_inline(in: [*c]rvn_md_inline_t, p_: [*c]const u8, end: [*c]const u8, depth: c_int) void {
    var p = p_;
    const start = p;
    var space_pending = false;

    while (p < end) {
        const c = p[0];
        const previous: u8 = if (p > start) (p - 1)[0] else ' ';

        // white space, new lines included, is one space; a line that ends with two spaces or a backslash is a line break
        if (rvn_md_is_space(c)) {
            var q = p;
            var newline = false;
            var spaces: c_int = 0;
            while (q < end and rvn_md_is_space(q[0])) {
                if (q[0] == '\n') {
                    if (!newline and spaces >= 2) {
                        rvn_md_flush(in, RVN_MD_BREAK);
                        in.*.fresh = true;
                    }
                    newline = true;
                } else if (!newline) {
                    spaces += 1;
                }
                q += 1;
            }
            space_pending = !in.*.fresh;
            p = q;
            continue;
        }
        if (space_pending) {
            rvn_md_put(in, " ", 1);
            space_pending = false;
        }

        if (c == '\\' and p + 1 < end) {
            if (p[1] == '\n') {
                rvn_md_flush(in, RVN_MD_BREAK);
                in.*.fresh = true;
                p += 2;
                continue;
            }
            if (rvn_md_is_punct(p[1])) {
                rvn_md_put(in, p + 1, 1);
                p += 2;
                continue;
            }
        }

        if (c == '`') {
            var ticks: usize = 0;
            while (p + ticks < end and p[ticks] == '`') ticks += 1;
            var content = p + ticks;
            var close = content;
            while (close < end) {
                var run: usize = 0;
                while (close + run < end and close[run] == '`') run += 1;
                if (run == ticks) break;
                close += if (run != 0) run else 1;
            }
            if (close < end) {
                var length: usize = @intCast(close - content);
                // one space of padding on each side is not part of the code
                if (length >= 2 and content[0] == ' ' and content[length - 1] == ' ') {
                    content += 1;
                    length -= 2;
                }
                rvn_md_flush(in, 0);
                in.*.flags |= RVN_MD_CODE;
                var q = content;
                while (q < content + length) : (q += 1) {
                    const piece: [*c]const u8 = if (q[0] == '\n') " " else q;
                    rvn_md_put(in, piece, 1);
                }
                rvn_md_flush(in, 0);
                in.*.flags &= ~@as(u32, RVN_MD_CODE);
                p = close + ticks;
                continue;
            }
        }

        if (c == '*' or c == '_' or c == '~') {
            var run: usize = 0;
            var used: usize = 0;
            while (p + run < end and p[run] == c) run += 1;
            const next: u8 = if (p + run < end) p[run] else ' ';
            while (used < run) {
                const left = run - used;
                const count: usize = if (c == '~') 2 else (if (left >= 2) 2 else 1);
                const flag: u32 = if (c == '~') RVN_MD_STRIKE else (if (count == 2) RVN_MD_BOLD else RVN_MD_ITALIC);
                const inside_word = c == '_' and rvn_md_is_word(previous) and rvn_md_is_word(next);
                if (left < count) break;
                if ((in.*.flags & flag) != 0) {
                    // closes: what is before must be text
                    if (rvn_md_is_space(previous) or inside_word) break;
                    rvn_md_flush(in, 0);
                    in.*.flags &= ~flag;
                } else {
                    if (rvn_md_is_space(next) or inside_word or !rvn_md_has_closer(p + run, end, c, count)) break;
                    rvn_md_flush(in, 0);
                    in.*.flags |= flag;
                }
                used += count;
            }
            // marks that neither open nor close anything are text
            if (used < run) rvn_md_put(in, p + used, run - used);
            p += run;
            continue;
        }

        if ((c == '[' or (c == '!' and p + 1 < end and p[1] == '[')) and depth < 4) {
            const open = if (c == '!') p + 1 else p;
            var text_end: [*c]const u8 = null;
            var url: [*c]const u8 = null;
            var url_length: usize = 0;
            const after = rvn_md_link_parts(open, end, &text_end, &url, &url_length);
            if (after != null) {
                const outer = in.*.link;
                rvn_md_flush(in, 0);
                in.*.link = rvn_md_add_link(in.*.md, url, url_length);
                // (an image inside a line of text is shown by its alternative text)
                rvn_md_inline(in, open + 1, text_end, depth + 1);
                rvn_md_flush(in, 0);
                in.*.link = outer;
                p = after;
                continue;
            }
        }

        if (c == '<') {
            var close = p + 1;
            while (close < end and close[0] != '>' and !rvn_md_is_space(close[0])) close += 1;
            if (close < end and close[0] == '>' and close - p > 4 and
                (libc.memchr(p + 1, ':', @intCast(close - p - 1)) != null or libc.memchr(p + 1, '@', @intCast(close - p - 1)) != null))
            {
                const outer = in.*.link;
                rvn_md_flush(in, 0);
                in.*.link = rvn_md_add_link(in.*.md, p + 1, @intCast(close - p - 1));
                rvn_md_put(in, p + 1, @intCast(close - p - 1));
                rvn_md_flush(in, 0);
                in.*.link = outer;
                p = close + 1;
                continue;
            }
        }

        if (c == 'h' and in.*.link < 0 and !rvn_md_is_word(previous) and end - p > 8 and
            (libc.memcmp(p, "http://", 7) == 0 or libc.memcmp(p, "https://", 8) == 0))
        {
            const stop = rvn_md_url_end(p, end);
            if (stop - p > 8) {
                rvn_md_flush(in, 0);
                in.*.link = rvn_md_add_link(in.*.md, p, @intCast(stop - p));
                rvn_md_put(in, p, @intCast(stop - p));
                rvn_md_flush(in, 0);
                in.*.link = -1;
                p = stop;
                continue;
            }
        }

        if (c == '&') {
            const used = rvn_md_entity(in, p, end);
            if (used != 0) {
                p += used;
                continue;
            }
        }

        rvn_md_put(in, p, 1);
        p += 1;
    }
}

// Reads the inline text of a block; returns its first span and their number.
fn rvn_md_read_inline(md: [*c]rvn_md_t, text: [*c]const u8, length: usize, first: [*c]u32, count: [*c]u32) void {
    var in: rvn_md_inline_t = undefined;
    in.md = md;
    in.flags = 0;
    in.link = -1;
    in.fresh = true;
    in.span_start = @truncate(md.*.text.length);
    first.* = md.*.span_count;
    rvn_md_inline(&in, text, text + length, 0);
    rvn_md_flush(&in, 0);
    count.* = md.*.span_count - first.*;
}

// ---------------------------------------------------------------------------
//  Parsing: blocks
// ---------------------------------------------------------------------------

const rvn_md_parser_t = extern struct {
    md: [*c]rvn_md_t,
    /// Lines of the paragraph being read, joined by '\n'.
    paragraph: base.rvn_text_t,
    paragraph_open: bool,
    quote: u8,
    list: u8,
    marker: u8,
    number: c_int,
    heading: u8,
    /// The lists that are open: the indentation of their markers.
    indents: [8]c_int,
    depth: c_int,
};

fn rvn_md_add_block(md: [*c]rvn_md_t, type_: c_int) [*c]rvn_md_block_t {
    base.RVN_ARRAY_RESERVE(&md.*.blocks, &md.*.block_cap, md.*.block_count + 1);
    const block = &md.*.blocks[md.*.block_count];
    md.*.block_count += 1;
    block.* = std.mem.zeroes(rvn_md_block_t);
    block.*.@"type" = @intCast(type_);
    block.*.link = -1;
    return block;
}

// Is the paragraph nothing but an image? Gives its parts.
fn rvn_md_lone_image(text_: [*c]const u8, length: usize, alt: [*c][*c]const u8, alt_length: [*c]usize, url: [*c][*c]const u8, url_length: [*c]usize) bool {
    var text = text_;
    var end = text + length;
    var text_end: [*c]const u8 = null;
    while (text < end and rvn_md_is_space(text[0])) text += 1;
    while (end > text and rvn_md_is_space((end - 1)[0])) end -= 1;
    if (end - text < 5 or text[0] != '!' or text[1] != '[') return false;
    const after = rvn_md_link_parts(text + 1, end, &text_end, url, url_length);
    if (after == null or after != end) return false;
    alt.* = text + 2;
    alt_length.* = @intCast(text_end - text - 2);
    return true;
}

fn rvn_md_end_paragraph(parser: [*c]rvn_md_parser_t) void {
    const md = parser.*.md;
    var block: [*c]rvn_md_block_t = undefined;
    var alt: [*c]const u8 = undefined;
    var url: [*c]const u8 = undefined;
    var alt_length: usize = undefined;
    var url_length: usize = undefined;
    if (!parser.*.paragraph_open) return;
    parser.*.paragraph_open = false;

    if (parser.*.heading == 0 and rvn_md_lone_image(parser.*.paragraph.data, parser.*.paragraph.length, &alt, &alt_length, &url, &url_length)) {
        const link = rvn_md_add_link(md, url, url_length);
        block = rvn_md_add_block(md, RVN_MD_IMAGE);
        block.*.link = @intCast(link);
        rvn_md_read_inline(md, alt, alt_length, &block.*.first_span, &block.*.span_count);
    } else {
        block = rvn_md_add_block(md, if (parser.*.heading != 0) RVN_MD_HEADING else RVN_MD_PARAGRAPH);
        block.*.level = parser.*.heading;
        const paragraph_text: [*c]const u8 = if (parser.*.paragraph.data != null) parser.*.paragraph.data else "";
        rvn_md_read_inline(md, paragraph_text, parser.*.paragraph.length, &block.*.first_span, &block.*.span_count);
    }
    block.*.quote = parser.*.quote;
    block.*.list = parser.*.list;
    block.*.marker = parser.*.marker;
    block.*.number = parser.*.number;
    parser.*.marker = RVN_MD_NO_MARKER;
    parser.*.heading = 0;
    parser.*.paragraph.length = 0;
    if (parser.*.paragraph.data != null) parser.*.paragraph.data[0] = 0;
}

fn rvn_md_paragraph_line(parser: [*c]rvn_md_parser_t, line: [*c]const u8, length: usize) void {
    if (parser.*.paragraph_open) base.rvn_text_append(&parser.*.paragraph, "\n", 1);
    base.rvn_text_append(&parser.*.paragraph, line, length);
    parser.*.paragraph_open = true;
}

// "---", "***", "___", with or without spaces: a rule.
fn rvn_md_is_rule(line: [*c]const u8, length: usize) bool {
    var mark: u8 = 0;
    var count: c_int = 0;
    var i: usize = 0;
    while (i < length) : (i += 1) {
        const c = line[i];
        if (c == ' ' or c == '\t') continue;
        if (c != '-' and c != '*' and c != '_') return false;
        if (mark != 0 and c != mark) return false;
        mark = c;
        count += 1;
    }
    return count >= 3;
}

// "|---|:-:|--:|": the line under the header of a table. Counts its columns.
fn rvn_md_is_table_rule(line: [*c]const u8, length: usize, columns: [*c]c_int) bool {
    var i: usize = 0;
    var count: c_int = 0;
    var dashes: usize = 0;
    var any_pipe = false;
    while (i < length and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i < length and line[i] == '|') {
        any_pipe = true;
        i += 1;
    }
    while (true) {
        dashes = 0;
        while (i < length and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i < length and line[i] == ':') i += 1;
        while (i < length and line[i] == '-') {
            dashes += 1;
            i += 1;
        }
        if (i < length and line[i] == ':') i += 1;
        while (i < length and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (dashes == 0) break;
        count += 1;
        if (i < length and line[i] == '|') {
            any_pipe = true;
            i += 1;
            continue;
        }
        break;
    }
    while (i < length and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i != length or count == 0 or !any_pipe) return false;
    columns.* = count;
    return true;
}

// Cuts a row of a table into cells; calls back for each, at most `max`. Returns their number.
fn rvn_md_split_row(line: [*c]const u8, length: usize, starts: [*c][*c]const u8, lengths: [*c]usize, max: c_int) c_int {
    var i: usize = 0;
    var count: c_int = 0;
    while (i < length and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i < length and line[i] == '|') i += 1;
    var cell_start = i;
    while (i <= length) : (i += 1) {
        const at_end = i == length;
        if (!at_end and line[i] == '\\' and i + 1 < length) {
            i += 1;
            continue;
        }
        if (at_end or line[i] == '|') {
            var a = cell_start;
            var b = i;
            while (a < b and (line[a] == ' ' or line[a] == '\t')) a += 1;
            while (b > a and (line[b - 1] == ' ' or line[b - 1] == '\t')) b -= 1;
            // (the pipe that closes the row is not followed by a cell)
            if (at_end and a == b and count > 0) break;
            if (count < max) {
                starts[@intCast(count)] = line + a;
                lengths[@intCast(count)] = b - a;
            }
            count += 1;
            cell_start = i + 1;
        }
    }
    return count;
}

fn rvn_md_cell_align(rule: [*c]const u8, length: usize, column: c_int, align_: [*c]u8) void {
    var starts: [64][*c]const u8 = undefined;
    var lengths: [64]usize = undefined;
    const count = rvn_md_split_row(rule, length, &starts, &lengths, 64);
    align_.* = 0;
    if (column < count and column < 64 and lengths[@intCast(column)] > 0) {
        const left = starts[@intCast(column)][0] == ':';
        const right = starts[@intCast(column)][lengths[@intCast(column)] - 1] == ':';
        align_.* = if (left and right) 1 else if (right) 2 else 0;
    }
}

const RVN_MD_MAX_COLUMNS = 32;

// Text written inside an XML element is indented with the element. Returns
// the text without the indentation its lines share (tabs count as one), to
// release with rvn_free; NULL when there is none to remove.
fn rvn_md_dedent(source: [*c]const u8) [*c]u8 {
    var p = source;
    var common_: usize = std.math.maxInt(usize);
    var out: base.rvn_text_t = std.mem.zeroes(base.rvn_text_t);
    while (p[0] != 0) {
        var line_end: [*c]const u8 = libc.strchr(p, '\n');
        var indent: usize = 0;
        if (line_end == null) line_end = p + libc.strlen(p);
        while (p + indent < line_end and (p[indent] == ' ' or p[indent] == '\t')) indent += 1;
        // (blank lines say nothing about the indentation; neither does the first line, which follows the tag)
        if (p + indent < line_end and p != source and indent < common_) common_ = indent;
        p = if (line_end[0] != 0) line_end + 1 else line_end;
    }
    if (common_ == std.math.maxInt(usize) or common_ == 0) return null;
    p = source;
    while (p[0] != 0) {
        var line_end: [*c]const u8 = libc.strchr(p, '\n');
        var indent: usize = 0;
        if (line_end == null) line_end = p + libc.strlen(p);
        while (indent < common_ and p + indent < line_end and (p[indent] == ' ' or p[indent] == '\t')) indent += 1;
        const piece_length: usize = @intCast(line_end - (p + indent));
        base.rvn_text_append(&out, p + indent, piece_length);
        if (line_end[0] != 0) base.rvn_text_append(&out, "\n", 1);
        p = if (line_end[0] != 0) line_end + 1 else line_end;
    }
    return out.data;
}

export fn rvn_md_parse(source: [*c]const u8) [*c]rvn_md_t {
    const md: [*c]rvn_md_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_md_t))));
    var parser: rvn_md_parser_t = std.mem.zeroes(rvn_md_parser_t);
    const dedented: [*c]u8 = if (source != null) rvn_md_dedent(source) else null;
    var p: [*c]const u8 = if (dedented != null) dedented else if (source != null) source else "";
    const end: [*c]const u8 = p + libc.strlen(p);
    // code between fences
    var in_code = false;
    var fence_length: c_int = 0;
    var fence_indent: c_int = 0;
    var fence_mark: u8 = 0;
    var code: [*c]rvn_md_block_t = null;
    var blank_before = true;

    parser.md = md;
    // (offset 0 of the text is never the start of a span that matters: keeps "0 length = none" simple)
    base.rvn_text_append(&md.*.text, " ", 1);

    while (p < end) {
        var line = p;
        var line_end: [*c]const u8 = @ptrCast(libc.memchr(p, '\n', @intCast(end - p)));
        const next: [*c]const u8 = if (line_end != null) line_end + 1 else end;
        var indent: c_int = 0;
        var quote: c_int = 0;
        var columns: c_int = 0;

        if (line_end == null) line_end = end;
        if (line_end > line and (line_end - 1)[0] == '\r') line_end -= 1;
        p = next;

        // the quotes the line is in
        var q: [*c]const u8 = line;
        while (true) {
            var mark = q;
            var spaces: c_int = 0;
            while (mark < line_end and mark[0] == ' ' and spaces < 3) {
                mark += 1;
                spaces += 1;
            }
            if (mark < line_end and mark[0] == '>' and !in_code) {
                quote += 1;
                q = mark + 1;
                if (q < line_end and q[0] == ' ') q += 1;
                continue;
            }
            break;
        }
        line = q;
        while (q < line_end and (q[0] == ' ' or q[0] == '\t')) {
            indent += if (q[0] == '\t') 4 else 1;
            q += 1;
        }
        const length: usize = @intCast(line_end - q);

        if (in_code) {
            var run: usize = 0;
            while (run < length and q[run] == fence_mark) run += 1;
            var rest: usize = run;
            while (rest < length and (q[rest] == ' ' or q[rest] == '\t')) rest += 1;
            // the fence that closes: at least as long as the one that opened, alone on its line
            if (run >= @as(usize, @intCast(fence_length)) and rest == length) {
                in_code = false;
            } else {
                // the line as written, less the indentation of the fence
                var raw = line;
                var skip = fence_indent;
                while (skip > 0 and raw < line_end and raw[0] == ' ') {
                    raw += 1;
                    skip -= 1;
                }
                if (code.*.code_length > 0) base.rvn_text_append(&md.*.text, "\n", 1);
                base.rvn_text_append(&md.*.text, raw, @intCast(line_end - raw));
                code.*.code_length = @as(u32, @truncate(md.*.text.length)) - code.*.code_start;
            }
            if (!in_code) {
                // (an empty block still shows as one empty line)
                blank_before = false;
            }
            continue;
        }

        if (length == 0) {
            rvn_md_end_paragraph(&parser);
            blank_before = true;
            continue;
        }
        if (quote != parser.quote) {
            rvn_md_end_paragraph(&parser);
            // (a quote starts over: the lists that were open are not its lists)
            if (blank_before or quote > parser.quote) {
                parser.depth = 0;
                parser.list = 0;
            }
            parser.quote = @intCast(base.rvn_mini(quote, 8));
        }

        // fenced code
        if ((q[0] == '`' or q[0] == '~') and length >= 3) {
            var run: usize = 0;
            while (run < length and q[run] == q[0]) run += 1;
            if (run >= 3 and (q[0] == '~' or libc.memchr(q + run, '`', length - run) == null)) {
                var info = q + run;
                rvn_md_end_paragraph(&parser);
                while (info < line_end and (info[0] == ' ' or info[0] == '\t')) info += 1;
                var info_end = info;
                while (info_end < line_end and !rvn_md_is_space(info_end[0]) and info_end[0] != '{' and info_end[0] != ',') info_end += 1;
                code = rvn_md_add_block(md, RVN_MD_CODE_BLOCK);
                code.*.quote = parser.quote;
                code.*.list = if (indent >= 2 and parser.depth > 0) parser.list else 0;
                code.*.language_start = @truncate(md.*.text.length);
                code.*.language_length = @intCast(info_end - info);
                base.rvn_text_append(&md.*.text, info, @intCast(info_end - info));
                base.rvn_text_append(&md.*.text, "\n", 1);
                code.*.code_start = @truncate(md.*.text.length);
                in_code = true;
                fence_mark = q[0];
                fence_length = @intCast(run);
                fence_indent = indent;
                blank_before = false;
                continue;
            }
        }

        // a title
        if (q[0] == '#') {
            var level: usize = 0;
            while (level < length and q[level] == '#') level += 1;
            if (level <= 6 and (level == length or q[level] == ' ' or q[level] == '\t')) {
                var text = q + level;
                var text_end = line_end;
                while (text < text_end and (text[0] == ' ' or text[0] == '\t')) text += 1;
                // closing marks: "## Title ##"
                while (text_end > text and ((text_end - 1)[0] == ' ' or (text_end - 1)[0] == '\t')) text_end -= 1;
                {
                    var hashes = text_end;
                    while (hashes > text and (hashes - 1)[0] == '#') hashes -= 1;
                    if (hashes < text_end and (hashes == text or (hashes - 1)[0] == ' ')) text_end = hashes;
                }
                while (text_end > text and ((text_end - 1)[0] == ' ' or (text_end - 1)[0] == '\t')) text_end -= 1;
                rvn_md_end_paragraph(&parser);
                parser.depth = 0;
                parser.list = 0;
                parser.heading = @intCast(level);
                rvn_md_paragraph_line(&parser, text, @intCast(text_end - text));
                rvn_md_end_paragraph(&parser);
                blank_before = false;
                continue;
            }
        }

        // a rule (a line of dashes right under a paragraph makes it a title instead)
        if (rvn_md_is_rule(q, length)) {
            if (parser.paragraph_open and q[0] == '-' and libc.memchr(q, ' ', length) == null) {
                parser.heading = 2;
                rvn_md_end_paragraph(&parser);
            } else {
                rvn_md_end_paragraph(&parser);
                parser.depth = 0;
                parser.list = 0;
                const rule = rvn_md_add_block(md, RVN_MD_RULE);
                rule.*.quote = parser.quote;
            }
            blank_before = false;
            continue;
        }
        if (parser.paragraph_open and length >= 2 and q[0] == '=' and libc.strspn(q, "= \t") >= length) {
            parser.heading = 1;
            rvn_md_end_paragraph(&parser);
            blank_before = false;
            continue;
        }

        // a table: a row, then the line of dashes
        if (!parser.paragraph_open and libc.memchr(q, '|', length) != null and next < end) {
            const rule = next;
            var rule_end: [*c]const u8 = @ptrCast(libc.memchr(rule, '\n', @intCast(end - rule)));
            var rule_quote: c_int = 0;
            if (rule_end == null) rule_end = end;
            if (rule_end > rule and (rule_end - 1)[0] == '\r') rule_end -= 1;
            // (inside a quote, the rule line has its marks too)
            var rule_text = rule;
            while (rule_quote < quote and rule_text < rule_end) {
                while (rule_text < rule_end and rule_text[0] == ' ') rule_text += 1;
                if (rule_text < rule_end and rule_text[0] == '>') {
                    rule_text += 1;
                    rule_quote += 1;
                } else {
                    break;
                }
            }
            if (rule_quote == quote and rvn_md_is_table_rule(rule_text, @intCast(rule_end - rule_text), &columns)) {
                var starts: [RVN_MD_MAX_COLUMNS][*c]const u8 = undefined;
                var lengths: [RVN_MD_MAX_COLUMNS]usize = undefined;
                var row = q;
                var row_length: usize = length;
                var c: c_int = 0;
                var rows: c_int = 0;
                if (columns > RVN_MD_MAX_COLUMNS) columns = RVN_MD_MAX_COLUMNS;
                const table = rvn_md_add_block(md, RVN_MD_TABLE);
                const table_index = md.*.block_count - 1;
                table.*.quote = parser.quote;
                table.*.columns = @intCast(columns);
                table.*.first_cell = md.*.cell_count;
                p = if (rule_end < end) rule_end + 1 else end;
                while (true) {
                    const found = rvn_md_split_row(row, row_length, &starts, &lengths, RVN_MD_MAX_COLUMNS);
                    base.RVN_ARRAY_RESERVE(&md.*.cells, &md.*.cell_cap, md.*.cell_count + @as(u32, @intCast(columns)));
                    c = 0;
                    while (c < columns) : (c += 1) {
                        const cell = &md.*.cells[md.*.cell_count];
                        md.*.cell_count += 1;
                        cell.* = std.mem.zeroes(rvn_md_cell_t);
                        rvn_md_cell_align(rule_text, @intCast(rule_end - rule_text), c, &cell.*.@"align");
                        if (c < found) rvn_md_read_inline(md, starts[@intCast(c)], lengths[@intCast(c)], &cell.*.first_span, &cell.*.span_count);
                    }
                    rows += 1;
                    // the next row, as long as there is one
                    if (p >= end) break;
                    {
                        var row_end: [*c]const u8 = @ptrCast(libc.memchr(p, '\n', @intCast(end - p)));
                        var text = p;
                        var row_quote: c_int = 0;
                        if (row_end == null) row_end = end;
                        while (row_quote < quote and text < row_end) {
                            while (text < row_end and text[0] == ' ') text += 1;
                            if (text < row_end and text[0] == '>') {
                                text += 1;
                                row_quote += 1;
                            } else {
                                break;
                            }
                        }
                        while (text < row_end and (text[0] == ' ' or text[0] == '\t')) text += 1;
                        row_length = @intCast(row_end - text);
                        if (row_length > 0 and text[row_length - 1] == '\r') row_length -= 1;
                        if (row_quote != quote or row_length == 0 or libc.memchr(text, '|', row_length) == null) break;
                        row = text;
                        p = if (row_end < end) row_end + 1 else end;
                    }
                }
                md.*.blocks[table_index].rows = @intCast(rows);
                blank_before = false;
                continue;
            }
        }

        // a list item
        {
            var text: [*c]const u8 = null;
            var marker: c_int = RVN_MD_NO_MARKER;
            var number: c_int = 0;
            if ((q[0] == '-' or q[0] == '*' or q[0] == '+') and length >= 2 and (q[1] == ' ' or q[1] == '\t')) {
                marker = RVN_MD_BULLET;
                text = q + 2;
            } else if (q[0] >= '0' and q[0] <= '9') {
                var digit = q;
                while (digit < line_end and digit[0] >= '0' and digit[0] <= '9' and digit - q < 9) {
                    number = number * 10 + (@as(c_int, digit[0]) - '0');
                    digit += 1;
                }
                if (digit + 1 < line_end and (digit[0] == '.' or digit[0] == ')') and (digit[1] == ' ' or digit[1] == '\t')) {
                    marker = RVN_MD_NUMBER;
                    text = digit + 2;
                }
            }
            // (a number in the middle of a paragraph does not start a list unless it is 1)
            if (marker == RVN_MD_NUMBER and parser.paragraph_open and parser.depth == 0 and number != 1) marker = RVN_MD_NO_MARKER;
            if (marker != RVN_MD_NO_MARKER) {
                rvn_md_end_paragraph(&parser);
                while (parser.depth > 0 and parser.indents[@intCast(parser.depth - 1)] > indent) parser.depth -= 1;
                if (parser.depth == 0 or indent >= parser.indents[@intCast(parser.depth - 1)] + 2) {
                    if (parser.depth < 8) {
                        parser.indents[@intCast(parser.depth)] = indent;
                        parser.depth += 1;
                    }
                }
                parser.list = @intCast(parser.depth);
                while (text < line_end and (text[0] == ' ' or text[0] == '\t')) text += 1;
                if (marker == RVN_MD_BULLET and line_end - text >= 3 and text[0] == '[' and text[2] == ']' and
                    (text[1] == ' ' or text[1] == 'x' or text[1] == 'X') and (line_end - text == 3 or text[3] == ' '))
                {
                    marker = if (text[1] == ' ') RVN_MD_TASK else RVN_MD_TASK_DONE;
                    text += 3;
                    while (text < line_end and (text[0] == ' ' or text[0] == '\t')) text += 1;
                }
                parser.marker = @intCast(marker);
                parser.number = number;
                rvn_md_paragraph_line(&parser, text, @intCast(line_end - text));
                blank_before = false;
                continue;
            }
        }

        // text: more of the paragraph, or a new one
        if (!parser.paragraph_open) {
            if (parser.depth > 0 and blank_before and indent < 2) {
                // not indented after a blank line: the lists are over
                parser.depth = 0;
                parser.list = 0;
            }
            parser.marker = RVN_MD_NO_MARKER;
        }
        // (with the spaces at its end: two of them ask for a line break)
        rvn_md_paragraph_line(&parser, q, length);
        blank_before = false;
    }
    rvn_md_end_paragraph(&parser);
    base.rvn_free(parser.paragraph.data);
    base.rvn_free(dedented);
    md.*.parsed_length = md.*.text.length;
    return md;
}

export fn rvn_md_free(md: [*c]rvn_md_t) void {
    if (md == null) return;
    var i: u32 = 0;
    while (i < md.*.link_count) : (i += 1) base.rvn_free(md.*.links[i]);
    base.rvn_free(@ptrCast(md.*.links));
    base.rvn_free(md.*.text.data);
    base.rvn_free(md.*.spans);
    base.rvn_free(md.*.blocks);
    base.rvn_free(md.*.cells);
    base.rvn_free(md.*.runs);
    base.rvn_free(md.*.boxes);
    base.rvn_free(md);
}

// ---------------------------------------------------------------------------
//  Layout
// ---------------------------------------------------------------------------

const RVN_MD_LINE_RUNS = 256;

const rvn_md_font_t = extern struct {
    id: raven.Rid,
    font: ?*font_h.rvn_font_t,
    /// From the top of its line box to its baseline, and the height of that box.
    base: f32,
    height: f32,
    size: f32,
};

const rvn_md_layout_t = extern struct {
    md: [*c]rvn_md_t,
    widget: [*c]const widget_h.rvn_widget_t,
    font: raven.Rid,
    mono: raven.Rid,
    size: f32,
    /// Width of the widest thing placed so far.
    widest: f32,
};

fn rvn_md_font(out: [*c]rvn_md_font_t, id: raven.Rid, size: f32) void {
    var metrics: font_h.rvn_font_metrics_t = undefined;
    out.*.id = id;
    out.*.font = ext.rvn_font_resolve(id);
    out.*.size = size;
    ext.rvn_font_metrics(out.*.font, size, &metrics);
    out.*.height = metrics.line_height;
    out.*.base = metrics.ascent + (metrics.line_height - metrics.ascent - metrics.descent) * 0.5;
}

fn rvn_md_add_box(md: [*c]rvn_md_t, kind: c_int, x: f32, y: f32, w: f32, h: f32) [*c]rvn_md_box_t {
    base.RVN_ARRAY_RESERVE(&md.*.boxes, &md.*.box_cap, md.*.box_count + 1);
    const box = &md.*.boxes[md.*.box_count];
    md.*.box_count += 1;
    box.*.kind = @intCast(kind);
    box.*.x = x;
    box.*.y = y;
    box.*.w = w;
    box.*.h = h;
    box.*.texture = raven.R_INVALID_ID;
    return box;
}

fn rvn_md_add_run(md: [*c]rvn_md_t) [*c]rvn_md_run_t {
    base.RVN_ARRAY_RESERVE(&md.*.runs, &md.*.run_cap, md.*.run_count + 1);
    const run = &md.*.runs[md.*.run_count];
    md.*.run_count += 1;
    run.* = std.mem.zeroes(rvn_md_run_t);
    run.*.link = -1;
    return run;
}

// Ends a line of a flow: gives the runs since `first` their height and their place across.
fn rvn_md_end_line(layout: [*c]rvn_md_layout_t, first: u32, x0: f32, y: f32, width: f32, pen: f32, align_: c_int,
    min_height: f32, min_base: f32, bases: [*c]const f32, heights: [*c]const f32) f32 {
    const md = layout.*.md;
    var height = min_height;
    var base_ = min_base;
    var shift: f32 = 0.0;
    var i: u32 = first;
    while (i < md.*.run_count) : (i += 1) {
        base_ = base.rvn_maxf(base_, bases[i - first]);
        height = base.rvn_maxf(height, heights[i - first]);
    }
    // air between the lines
    const leading = @floor(height * 0.26 + 0.5);
    height = @ceil(height) + leading;
    if (width > 0.0 and align_ != 0) shift = base.rvn_maxf(0.0, (width - pen) * (if (align_ == 1) @as(f32, 0.5) else 1.0));
    i = first;
    while (i < md.*.run_count) : (i += 1) {
        const run = &md.*.runs[i];
        run.*.x += shift;
        run.*.y = y + leading * 0.5 + (base_ - bases[i - first]);
        run.*.line_y = y;
        run.*.line_h = height;
        if ((run.*.flags & RVN_MD_CODE) != 0) {
            // the tile behind a piece of code
            _ = rvn_md_add_box(md, RVN_MD_BOX_INLINE_CODE, run.*.x - 3.0, y + leading * 0.5 - 1.0, run.*.w + 6.0, height - leading + 2.0);
        }
    }
    layout.*.widest = base.rvn_maxf(layout.*.widest, x0 + pen + shift);
    return height;
}

// Lays spans out from (x0, y), wrapped on `width` (0: on one line). Returns
// the height it took.
fn rvn_md_flow(layout: [*c]rvn_md_layout_t, first_span: u32, span_count: u32, x0: f32, y_: f32, width: f32,
    size: f32, forced: u32, align_: c_int, color: c_int) f32 {
    const md = layout.*.md;
    const text: [*c]const u8 = md.*.text.data;
    var y = y_;
    var fonts: [4]rvn_md_font_t = undefined;
    var mono: rvn_md_font_t = undefined;
    var plain: rvn_md_font_t = undefined;
    var bases: [RVN_MD_LINE_RUNS]f32 = undefined;
    var heights: [RVN_MD_LINE_RUNS]f32 = undefined;
    var line_first = md.*.run_count;
    var pen: f32 = 0.0;
    const top = y;
    var made = [4]bool{ false, false, false, false };
    var s: u32 = 0;

    rvn_md_font(&plain, ext.rvn_font_variant(layout.*.font, forced), size);
    rvn_md_font(&mono, layout.*.mono, size * 0.94);

    while (s < span_count) : (s += 1) {
        const span = &md.*.spans[first_span + s];
        const style: u32 = (if ((span.*.flags & RVN_MD_BOLD) != 0) font_h.RVN_FONT_BOLD else 0) |
            (if ((span.*.flags & RVN_MD_ITALIC) != 0) font_h.RVN_FONT_ITALIC else 0) | forced;
        var font: *rvn_md_font_t = undefined;
        var at: u32 = span.*.start;
        const stop: u32 = span.*.start + span.*.length;
        var run: [*c]rvn_md_run_t = null;

        if ((span.*.flags & RVN_MD_CODE) != 0) {
            font = &mono;
        } else {
            if (!made[style]) {
                rvn_md_font(&fonts[style], ext.rvn_font_variant(layout.*.font, style), size);
                made[style] = true;
            }
            font = &fonts[style];
        }

        while (at < stop) {
            // a word and the spaces after it
            var word_end = at;
            while (word_end < stop and text[word_end] != ' ') word_end += 1;
            var next = word_end;
            while (next < stop and text[next] == ' ') next += 1;
            const word_width = ext.rvn_text_width(font.font, font.size, text + at, @intCast(word_end - at));
            const full_width = word_width + ext.rvn_text_width(font.font, font.size, text + word_end, @intCast(next - word_end));

            if (width > 0.0 and pen > 0.0 and pen + word_width > width + 0.5) {
                y += rvn_md_end_line(layout, line_first, x0, y, width, pen, align_, plain.height, plain.base, &bases, &heights);
                line_first = md.*.run_count;
                pen = 0.0;
                run = null;
                // (the spaces a line was cut on do not start the next one)
                if (word_end == at) {
                    at = next;
                    continue;
                }
            }
            if (run == null or md.*.run_count - line_first >= RVN_MD_LINE_RUNS) {
                if (md.*.run_count - line_first >= RVN_MD_LINE_RUNS) {
                    y += rvn_md_end_line(layout, line_first, x0, y, width, pen, align_, plain.height, plain.base, &bases, &heights);
                    line_first = md.*.run_count;
                    pen = 0.0;
                }
                run = rvn_md_add_run(md);
                run.*.x = x0 + pen;
                run.*.start = at;
                run.*.font = font.id;
                run.*.size = font.size;
                run.*.flags = @truncate(span.*.flags & (RVN_MD_CODE | RVN_MD_STRIKE));
                run.*.link = span.*.link;
                run.*.color = @intCast(if (span.*.link >= 0) RVN_MD_COLOR_LINK else color);
                bases[md.*.run_count - 1 - line_first] = font.base;
                heights[md.*.run_count - 1 - line_first] = font.height;
            }
            run.*.length += next - at;
            run.*.w += full_width;
            pen += full_width;
            at = next;
        }
        if ((span.*.flags & RVN_MD_BREAK) != 0) {
            y += rvn_md_end_line(layout, line_first, x0, y, width, pen, align_, plain.height, plain.base, &bases, &heights);
            line_first = md.*.run_count;
            pen = 0.0;
        }
    }
    if (md.*.run_count > line_first or y == top) {
        y += rvn_md_end_line(layout, line_first, x0, y, width, pen, align_, plain.height, plain.base, &bases, &heights);
    }
    return y - top;
}

// Width spans take on one line.
fn rvn_md_natural_width(layout: [*c]rvn_md_layout_t, first_span: u32, span_count: u32, size: f32, forced: u32) f32 {
    const md = layout.*.md;
    var width: f32 = 0.0;
    var s: u32 = 0;
    while (s < span_count) : (s += 1) {
        const span = &md.*.spans[first_span + s];
        const style: u32 = (if ((span.*.flags & RVN_MD_BOLD) != 0) font_h.RVN_FONT_BOLD else 0) |
            (if ((span.*.flags & RVN_MD_ITALIC) != 0) font_h.RVN_FONT_ITALIC else 0) | forced;
        const is_code = (span.*.flags & RVN_MD_CODE) != 0;
        const font = ext.rvn_font_resolve(if (is_code) layout.*.mono else ext.rvn_font_variant(layout.*.font, style));
        width += ext.rvn_text_width(font, if (is_code) size * 0.94 else size, md.*.text.data + span.*.start, @intCast(span.*.length));
    }
    return width;
}

fn rvn_md_code_block(layout: [*c]rvn_md_layout_t, block: [*c]const rvn_md_block_t, x0: f32, y_: f32, width: f32) f32 {
    const md = layout.*.md;
    const text: [*c]const u8 = md.*.text.data;
    var mono: rvn_md_font_t = undefined;
    var language: ?*const common.rvn_language_t = null;
    var name: [32]u8 = undefined;
    const pad_x = @floor(layout.*.size * 0.8);
    const pad_y = @floor(layout.*.size * 0.6);
    var y = y_;
    const top = y;
    var widest: f32 = 0.0;
    var at: u32 = block.*.code_start;
    const stop: u32 = block.*.code_start + block.*.code_length;
    const box_index = md.*.box_count;
    var state: u8 = 0;

    rvn_md_font(&mono, layout.*.mono, layout.*.size * 0.94);
    const line_height = @ceil(mono.height * 1.18);
    if (block.*.language_length > 0 and block.*.language_length < name.len) {
        const language_length: usize = block.*.language_length;
        @memcpy(name[0..language_length], (text + block.*.language_start)[0..language_length]);
        name[language_length] = 0;
        language = common.rvn_language_find(&name);
    }
    _ = rvn_md_add_box(md, RVN_MD_BOX_CODE, x0, y, 0.0, 0.0);
    y += pad_y;
    while (true) {
        var line_end = at;
        var spans: [96]common.rvn_span_t = undefined;
        var span_count: c_int = 0;
        var cursor: c_int = 0;
        var pen: f32 = 0.0;
        while (line_end < stop and text[line_end] != '\n') line_end += 1;
        const length: c_int = @intCast(line_end - at);
        if (language) |lang| state = common.rvn_syntax_line(lang, text + at, length, state, &spans, 96, &span_count);
        // the line, cut where its color changes
        var i: c_int = 0;
        while (i <= span_count) : (i += 1) {
            const piece_start: c_int = if (i < span_count) spans[@intCast(i)].start else length;
            const piece_end: c_int = if (i < span_count) spans[@intCast(i)].end else length;
            var k: c_int = 0;
            while (k < 2) : (k += 1) {
                const a: c_int = if (k == 0) cursor else piece_start;
                const b: c_int = if (k == 0) piece_start else piece_end;
                if (b <= a) continue;
                const run = rvn_md_add_run(md);
                run.*.x = x0 + pad_x + pen;
                run.*.y = y + (line_height - mono.height) * 0.5;
                run.*.line_y = y;
                run.*.line_h = line_height;
                run.*.start = at + @as(u32, @intCast(a));
                run.*.length = @intCast(b - a);
                run.*.font = mono.id;
                run.*.size = mono.size;
                run.*.w = ext.rvn_text_width(mono.font, mono.size, text + at + @as(usize, @intCast(a)), b - a);
                run.*.color = if (k == 0 or i >= span_count) RVN_MD_COLOR_TEXT else RVN_MD_COLOR_TOKEN + spans[@intCast(i)].token;
                // (set once the width of the block is known)
                run.*.clip_right = -1.0;
                pen += run.*.w;
            }
            cursor = piece_end;
        }
        widest = base.rvn_maxf(widest, pen);
        y += line_height;
        if (line_end >= stop) break;
        at = line_end + 1;
    }
    y += pad_y;
    {
        // as wide as the text around it; without wrapping, as wide as its longest line
        const box_width: f32 = if (width > 0.0) width else widest + pad_x * 2.0;
        md.*.boxes[box_index].w = box_width;
        md.*.boxes[box_index].h = y - top;
        var i: u32 = 0;
        while (i < md.*.run_count) : (i += 1) {
            if (md.*.runs[i].clip_right < 0.0) md.*.runs[i].clip_right = x0 + box_width - pad_x * 0.5;
        }
        layout.*.widest = base.rvn_maxf(layout.*.widest, x0 + box_width);
    }
    return y - top;
}

fn rvn_md_table(layout: [*c]rvn_md_layout_t, block: [*c]const rvn_md_block_t, x0: f32, y_: f32, width: f32) f32 {
    const md = layout.*.md;
    var widths: [RVN_MD_MAX_COLUMNS]f32 = undefined;
    const pad_x = @floor(layout.*.size * 0.75);
    const pad_y = @floor(layout.*.size * 0.36);
    var total: f32 = 0.0;
    var y = y_;
    const top = y;
    var x: f32 = undefined;
    const columns: c_int = block.*.columns;
    const rows: c_int = block.*.rows;
    var r: c_int = 0;
    var c: c_int = 0;

    if (columns <= 0 or rows <= 0) return 0.0;
    while (c < columns) : (c += 1) {
        widths[@intCast(c)] = layout.*.size * 2.0;
        r = 0;
        while (r < rows) : (r += 1) {
            const cell = &md.*.cells[block.*.first_cell + @as(u32, @intCast(r * columns + c))];
            const natural = rvn_md_natural_width(layout, cell.*.first_span, cell.*.span_count, layout.*.size, if (r == 0) font_h.RVN_FONT_BOLD else 0);
            widths[@intCast(c)] = base.rvn_maxf(widths[@intCast(c)], natural + 1.0);
        }
        total += widths[@intCast(c)] + pad_x * 2.0;
    }
    // too wide: the columns give up room in proportion, and their text wraps
    if (width > 0.0 and total > width) {
        const room = base.rvn_maxf(width - pad_x * 2.0 * @as(f32, @floatFromInt(columns)), layout.*.size * 2.0 * @as(f32, @floatFromInt(columns)));
        const sum = total - pad_x * 2.0 * @as(f32, @floatFromInt(columns));
        total = 0.0;
        c = 0;
        while (c < columns) : (c += 1) {
            widths[@intCast(c)] = base.rvn_maxf(layout.*.size * 2.0, @floor(widths[@intCast(c)] * room / sum));
            total += widths[@intCast(c)] + pad_x * 2.0;
        }
    }
    r = 0;
    while (r < rows) : (r += 1) {
        var row_height: f32 = 0.0;
        var header_box: u32 = 0;
        if (r == 0) {
            header_box = md.*.box_count;
            _ = rvn_md_add_box(md, RVN_MD_BOX_TABLE_HEADER, x0, y, total, 0.0);
        }
        x = x0;
        c = 0;
        while (c < columns) : (c += 1) {
            const cell = &md.*.cells[block.*.first_cell + @as(u32, @intCast(r * columns + c))];
            const height = rvn_md_flow(layout, cell.*.first_span, cell.*.span_count, x + pad_x, y + pad_y, widths[@intCast(c)], layout.*.size,
                if (r == 0) font_h.RVN_FONT_BOLD else 0, cell.*.@"align", RVN_MD_COLOR_TEXT);
            row_height = base.rvn_maxf(row_height, height);
            x += widths[@intCast(c)] + pad_x * 2.0;
        }
        row_height += pad_y * 2.0;
        if (r == 0) md.*.boxes[header_box].h = row_height;
        y += row_height;
        _ = rvn_md_add_box(md, RVN_MD_BOX_TABLE_LINE, x0, y - 1.0, total, 1.0);
    }
    _ = rvn_md_add_box(md, RVN_MD_BOX_TABLE_LINE, x0, top, total, 1.0);
    // the lines between the columns, and around
    x = x0;
    c = 0;
    while (c <= columns) : (c += 1) {
        _ = rvn_md_add_box(md, RVN_MD_BOX_TABLE_LINE, if (c == columns) x - 1.0 else x, top, 1.0, y - top);
        if (c < columns) x += widths[@intCast(c)] + pad_x * 2.0;
    }
    layout.*.widest = base.rvn_maxf(layout.*.widest, x0 + total);
    return y - top;
}

export fn rvn_md_layout(md: [*c]rvn_md_t, widget: [*c]const widget_h.rvn_widget_t, font: raven.Rid, size: f32, width: f32) base.rvn_vec2_t {
    const heading_scale = [7]f32{ 1.0, 1.9, 1.52, 1.26, 1.1, 1.0, 0.92 };
    var layout: rvn_md_layout_t = undefined;
    var y: f32 = 0.0;
    var gap: f32 = 0.0;
    var open_quote: u8 = 0;
    var quote_top: [9]f32 = undefined;
    const resolved = ext.rvn_font_resolve(font);

    if (resolved == null) return base.rvn_vec2(0.0, 0.0);
    if (md.*.laid and md.*.laid_width == width and md.*.laid_size == size and md.*.laid_font == font and
        md.*.laid_generation == ext.g_rvn.style_generation) return md.*.size;
    md.*.run_count = 0;
    md.*.box_count = 0;
    md.*.text.length = md.*.parsed_length;
    layout.md = md;
    layout.widget = widget;
    layout.font = font;
    layout.mono = ext.g_rvn.mono_font;
    layout.size = size;
    layout.widest = 0.0;
    const quote_indent = @floor(size * 1.15);
    const list_indent = @floor(size * 1.7);

    var b: u32 = 0;
    while (b <= md.*.block_count) : (b += 1) {
        const block: [*c]const rvn_md_block_t = if (b < md.*.block_count) &md.*.blocks[b] else null;
        const quote: u8 = if (block != null) block.*.quote else 0;
        var height: f32 = 0.0;

        // the bars of the quotes that end here
        while (open_quote > quote) {
            const top = quote_top[open_quote];
            _ = rvn_md_add_box(md, RVN_MD_BOX_QUOTE, quote_indent * @as(f32, @floatFromInt(open_quote - 1)), top, 3.0, y - top);
            open_quote -= 1;
        }
        if (block == null) break;

        // the space above: more before a title, less between the items of a list
        var before: f32 = size * 0.72;
        if (block.*.@"type" == RVN_MD_HEADING) {
            before = size * (if (block.*.level <= 2) @as(f32, 1.25) else 1.0);
        } else if (block.*.list > 0 and b > 0 and md.*.blocks[b - 1].list > 0) {
            before = size * (if (block.*.marker != 0) @as(f32, 0.3) else 0.4);
        }
        if (b > 0 and md.*.blocks[b - 1].@"type" == RVN_MD_HEADING) before = size * 0.5;
        if (b == 0) before = 0.0;
        y += base.rvn_maxf(before, gap);
        gap = 0.0;
        while (open_quote < quote) {
            open_quote += 1;
            quote_top[open_quote] = y;
        }

        const x0 = quote_indent * @as(f32, @floatFromInt(quote)) + list_indent * @as(f32, @floatFromInt(block.*.list));
        const room: f32 = if (width > 0.0) base.rvn_maxf(width - x0, size * 4.0) else 0.0;

        switch (block.*.@"type") {
            RVN_MD_HEADING => {
                const heading_size = @floor(size * heading_scale[@intCast(base.rvn_clampi(block.*.level, 1, 6))] + 0.5);
                height = rvn_md_flow(&layout, block.*.first_span, block.*.span_count, x0, y, room, heading_size, font_h.RVN_FONT_BOLD, 0, RVN_MD_COLOR_TEXT);
                // the two largest are underlined across
                if (block.*.level <= 2) {
                    height += @floor(size * 0.3);
                    _ = rvn_md_add_box(md, RVN_MD_BOX_RULE, x0, y + height, if (room > 0.0) room else -1.0, 1.0);
                    height += 1.0;
                }
            },
            RVN_MD_CODE_BLOCK => {
                height = rvn_md_code_block(&layout, block, x0, y, room);
            },
            RVN_MD_RULE => {
                _ = rvn_md_add_box(md, RVN_MD_BOX_RULE, x0, y + @floor(size * 0.3), if (room > 0.0) room else -1.0, 1.0);
                height = @floor(size * 0.6) + 1.0;
            },
            RVN_MD_TABLE => {
                height = rvn_md_table(&layout, block, x0, y, room);
            },
            RVN_MD_IMAGE => {
                const texture: raven.Rid = if (block.*.link >= 0) common.rvn_xml_texture(md.*.links[@intCast(block.*.link)]) else raven.R_INVALID_ID;
                var image_width: c_int = 0;
                var image_height: c_int = 0;
                if (texture != raven.R_INVALID_ID) raven.Rtexture_get_size(texture, &image_width, &image_height);
                if (image_width > 0 and image_height > 0) {
                    var w: f32 = @floatFromInt(image_width);
                    var h: f32 = @floatFromInt(image_height);
                    if (room > 0.0 and w > room) {
                        h = @floor(h * room / w);
                        w = room;
                    }
                    const box = rvn_md_add_box(md, RVN_MD_BOX_IMAGE, x0, y, w, h);
                    box.*.texture = texture;
                    layout.widest = base.rvn_maxf(layout.widest, x0 + w);
                    height = h;
                } else {
                    // an image that cannot be shown is told by its alternative text
                    height = rvn_md_flow(&layout, block.*.first_span, block.*.span_count, x0, y, room, size, font_h.RVN_FONT_ITALIC, 0, RVN_MD_COLOR_QUOTE);
                }
            },
            else => {
                if (block.*.marker != RVN_MD_NO_MARKER) {
                    var regular: rvn_md_font_t = undefined;
                    const marker_x = x0 - list_indent;
                    rvn_md_font(&regular, font, size);
                    if (block.*.marker == RVN_MD_NUMBER) {
                        // the number, right against the text
                        var number: [16]u8 = undefined;
                        const start: u32 = @truncate(md.*.text.length);
                        _ = libc.snprintf(&number, number.len, "%d.", block.*.number);
                        base.rvn_text_add(&md.*.text, &number);
                        const number_width = ext.rvn_text_width(regular.font, size, &number, -1);
                        const run = rvn_md_add_run(md);
                        run.*.x = x0 - number_width - @floor(size * 0.4);
                        run.*.y = y + @floor(regular.height * 0.13 + 0.5);
                        run.*.line_y = y;
                        run.*.line_h = regular.height;
                        run.*.w = number_width;
                        run.*.start = start;
                        run.*.length = @truncate(libc.strlen(&number));
                        run.*.font = regular.id;
                        run.*.size = size;
                        run.*.color = RVN_MD_COLOR_QUOTE;
                    } else {
                        const line = @ceil(regular.height) + @floor(regular.height * 0.26 + 0.5);
                        const side: f32 = if (block.*.marker == RVN_MD_BULLET) @floor(size * 0.36) else @floor(size * 0.95);
                        const kind: c_int = if (block.*.marker == RVN_MD_BULLET)
                            RVN_MD_BOX_BULLET
                        else if (block.*.marker == RVN_MD_TASK)
                            RVN_MD_BOX_TASK
                        else
                            RVN_MD_BOX_TASK_DONE;
                        // (the bullets of lists in lists are smaller rings: see the painting)
                        const box = rvn_md_add_box(md, kind, marker_x + @floor((list_indent - side) * 0.55), y + @floor((line - side) * 0.5), side, side);
                        box.*.texture = @as(raven.Rid, block.*.list);
                    }
                }
                height = rvn_md_flow(&layout, block.*.first_span, block.*.span_count, x0, y, room, size, 0, 0,
                    if (quote > 0) RVN_MD_COLOR_QUOTE else RVN_MD_COLOR_TEXT);
            },
        }
        y += height;
    }

    // rules asked to span the text: now that its width is known
    {
        const full: f32 = if (width > 0.0) width else layout.widest;
        var i: u32 = 0;
        while (i < md.*.box_count) : (i += 1) {
            if (md.*.boxes[i].kind == RVN_MD_BOX_RULE and md.*.boxes[i].w < 0.0) md.*.boxes[i].w = base.rvn_maxf(full - md.*.boxes[i].x, 0.0);
        }
    }
    md.*.size = base.rvn_vec2(@ceil(layout.widest), @ceil(y));
    md.*.laid = true;
    md.*.laid_width = width;
    md.*.laid_size = size;
    md.*.laid_font = font;
    md.*.laid_generation = ext.g_rvn.style_generation;
    return md.*.size;
}

// ---------------------------------------------------------------------------
//  Painting and pointing
// ---------------------------------------------------------------------------

export fn rvn_md_paint(md: [*c]const rvn_md_t, widget: [*c]const widget_h.rvn_widget_t, painter: ?*raven.RPainter, ox: f32, oy: f32, color: base.rvn_color_t, hot_link: c_int) void {
    const theme = widget_h.rvn_widget_theme(widget);
    const dp: *const draw_h.RPainter = @ptrCast(@alignCast(painter.?));
    const link: base.rvn_color_t = if (dp.enabled != 0) ext.rvn_widget_color(widget, raven.R_COLOR_LINK) else color;
    const dim = base.rvn_color_fade(color, 0.72);
    const line = ext.rvn_widget_color(widget, raven.R_COLOR_SEPARATOR);
    const code = ext.rvn_widget_color(widget, raven.R_COLOR_CODE);
    const accent = ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT);
    var i: u32 = 0;

    while (i < md.*.box_count) : (i += 1) {
        const box = &md.*.boxes[i];
        const rect = base.rvn_rect(ox + box.*.x, oy + box.*.y, box.*.w, box.*.h);
        switch (box.*.kind) {
            RVN_MD_BOX_CODE => {
                ext.rvn_paint_box(painter, rect, 7.0, code, 1.0, base.rvn_color_fade(line, 0.6));
            },
            RVN_MD_BOX_INLINE_CODE => {
                ext.rvn_paint_box(painter, rect, 4.0, code, 0.0, 0);
            },
            RVN_MD_BOX_QUOTE => {
                ext.rvn_paint_box(painter, rect, 1.5, base.rvn_color_fade(accent, 0.75), 0.0, 0);
            },
            RVN_MD_BOX_RULE, RVN_MD_BOX_TABLE_LINE => {
                ext.rvn_paint_rect(painter, rect, line);
            },
            RVN_MD_BOX_TABLE_HEADER => {
                ext.rvn_paint_rect(painter, rect, base.rvn_color_fade(code, 0.8));
            },
            RVN_MD_BOX_BULLET => {
                // a disc, then rings for the lists inside lists
                if (box.*.texture <= 1) {
                    ext.rvn_paint_box(painter, rect, rect.w * 0.5, dim, 0.0, 0);
                } else {
                    ext.rvn_paint_box(painter, rect, rect.w * 0.5, 0, 1.2, dim);
                }
            },
            RVN_MD_BOX_TASK => {
                ext.rvn_paint_box(painter, rect, 3.5, 0, 1.3, dim);
            },
            RVN_MD_BOX_TASK_DONE => {
                ext.rvn_paint_box(painter, rect, 3.5, accent, 0.0, 0);
                ext.rvn_paint_icon(painter, draw_h.RVN_ICON_CHECK, rect.x + rect.w * 0.5, rect.y + rect.h * 0.5, rect.w * 0.62,
                    ext.rvn_widget_color(widget, raven.R_COLOR_ACCENT_TEXT));
            },
            RVN_MD_BOX_IMAGE => {
                ext.rvn_paint_image(painter, rect, box.*.texture, null, base.rvn_hex(0xFFFFFF, 255), 6.0);
            },
            else => {},
        }
    }

    i = 0;
    while (i < md.*.run_count) : (i += 1) {
        const run = &md.*.runs[i];
        var run_color: base.rvn_color_t = color;
        const clipped = run.*.clip_right > 0.0;
        if (run.*.color == RVN_MD_COLOR_LINK) {
            run_color = link;
        } else if (run.*.color == RVN_MD_COLOR_QUOTE) {
            run_color = dim;
        } else if (run.*.color >= RVN_MD_COLOR_TOKEN) {
            run_color = common.rvn_syntax_color(theme, @intCast(@as(c_int, run.*.color) - RVN_MD_COLOR_TOKEN), color);
        }
        if (clipped) {
            if (run.*.x >= run.*.clip_right) continue;
            ext.rvn_paint_push_clip(painter, base.rvn_rect(ox + run.*.x - 2.0, oy + run.*.line_y, run.*.clip_right - run.*.x + 2.0, run.*.line_h));
        }
        ext.rvn_paint_text(painter, run.*.font, run.*.size, ox + run.*.x, oy + run.*.y, md.*.text.data + run.*.start, @intCast(run.*.length), run_color);
        if (clipped) ext.rvn_paint_pop_clip(painter);
        if ((run.*.flags & RVN_MD_STRIKE) != 0) {
            ext.rvn_paint_rect(painter, base.rvn_rect(ox + run.*.x, oy + run.*.line_y + @floor(run.*.line_h * 0.54), run.*.w, 1.0), run_color);
        }
        // the link under the pointer is underlined
        if (run.*.link >= 0 and run.*.link == hot_link) {
            ext.rvn_paint_rect(painter, base.rvn_rect(ox + run.*.x, oy + run.*.line_y + run.*.line_h - @floor(run.*.line_h * 0.2), run.*.w, 1.0), run_color);
        }
    }
}

export fn rvn_md_link_at(md: [*c]const rvn_md_t, x: f32, y: f32) c_int {
    var i: u32 = 0;
    while (i < md.*.run_count) : (i += 1) {
        const run = &md.*.runs[i];
        if (run.*.link < 0) continue;
        if (x >= run.*.x and x < run.*.x + run.*.w and y >= run.*.line_y and y < run.*.line_y + run.*.line_h) return run.*.link;
    }
    return -1;
}

export fn rvn_md_link(md: [*c]const rvn_md_t, link: c_int) [*c]const u8 {
    return if (link >= 0 and @as(u32, @intCast(link)) < md.*.link_count) md.*.links[@intCast(link)] else null;
}

export fn rvn_md_link_count(md: [*c]const rvn_md_t) c_int {
    return @intCast(md.*.link_count);
}

export fn rvn_md_plain_text(md: [*c]const rvn_md_t, out: [*c]base.rvn_text_t) void {
    var b: u32 = 0;
    var s: u32 = 0;
    while (b < md.*.block_count) : (b += 1) {
        const block = &md.*.blocks[b];
        if (b > 0) base.rvn_text_append(out, "\n", 1);
        if (block.*.@"type" == RVN_MD_CODE_BLOCK) {
            base.rvn_text_append(out, md.*.text.data + block.*.code_start, block.*.code_length);
        } else if (block.*.@"type" == RVN_MD_TABLE) {
            var c: u32 = 0;
            const columns: u32 = @as(u32, block.*.columns);
            const cells: u32 = columns * @as(u32, block.*.rows);
            while (c < cells) : (c += 1) {
                const cell = &md.*.cells[block.*.first_cell + c];
                if (c > 0) base.rvn_text_append(out, if (c % columns != 0) "\t" else "\n", 1);
                s = 0;
                while (s < cell.*.span_count) : (s += 1) {
                    const span = &md.*.spans[cell.*.first_span + s];
                    base.rvn_text_append(out, md.*.text.data + span.*.start, span.*.length);
                }
            }
        } else {
            s = 0;
            while (s < block.*.span_count) : (s += 1) {
                const span = &md.*.spans[block.*.first_span + s];
                base.rvn_text_append(out, md.*.text.data + span.*.start, span.*.length);
                if ((span.*.flags & RVN_MD_BREAK) != 0) base.rvn_text_append(out, "\n", 1);
            }
        }
    }
    if (out.*.data == null) base.rvn_text_append(out, "", 0);
}
