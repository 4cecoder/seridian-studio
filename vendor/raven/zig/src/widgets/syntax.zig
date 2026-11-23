// Translated to Zig from vendor/raven/src/widgets/syntax.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/syntax.c
// Languages of the text editor: what the editor knows about the text it
// holds, to color it, to complete words and to indent.
//
// A language is a description (RLanguageDesc): its words, how its comments
// and its texts are written, a few traits. Three lexers read these
// descriptions:
//
//   code     C, C++, C#, Java, JavaScript, Python, Rust, JSON, GLSL... and
//            any language declared by the application
//   markup   XML and HTML (which holds JavaScript and CSS between its tags)
//   styles   CSS
//
// A lexer reads one line and cuts it into spans, each with a kind of token.
// What a line starts in (the middle of a comment, of a tag...) is one byte
// handed from each line to the next, so a line is colored without reading
// the lines before it again.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const context_h = @import("../core/context_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

const RVN_LANGUAGE_MAX_MULTILINE = 8;

// struct rvn_language_t: the header unit declares it opaque; this file owns its fields.
const rvn_language_t = extern struct {
    /// The description given to Rlanguage_register; its strings are owned by `strings`.
    desc: raven.RLanguageDesc,
    strings: base.rvn_arena_t,
    /// keywords, types, constants: sorted, for searching.
    words: [3][*c][*c]const u8,
    word_count: [3]u32,
    /// Texts that span lines: what opens each kind, and what closes it.
    multiline: [RVN_LANGUAGE_MAX_MULTILINE][*c]const u8,
    multiline_close: [RVN_LANGUAGE_MAX_MULTILINE][*c]const u8,
    multiline_count: c_int,
};

const languages_t = extern struct {
    items: [*c][*c]rvn_language_t,
    count: u32,
    cap: u32,
    /// Languages that were replaced: editors may still point to them until they look again.
    retired: [*c][*c]rvn_language_t,
    retired_count: u32,
    retired_cap: u32,
    generation: u32,
    built_in: c_int,
};

var g_languages: languages_t = std.mem.zeroes(languages_t);

const rvn_lexer_t = extern struct {
    text: [*c]const u8,
    length: c_int,
    spans: [*c]common.rvn_span_t,
    max: c_int,
    count: c_int,
};

fn rvn_lex_emit(lexer: [*c]rvn_lexer_t, start: c_int, end: c_int, token: common.rvn_token_t) void {
    if (end <= start or lexer.*.spans == null or lexer.*.count >= lexer.*.max) return;
    lexer.*.spans[@intCast(lexer.*.count)].start = start;
    lexer.*.spans[@intCast(lexer.*.count)].end = end;
    lexer.*.spans[@intCast(lexer.*.count)].token = @truncate(token);
    lexer.*.count += 1;
}

fn rvn_lex_starts(lexer: [*c]const rvn_lexer_t, at: c_int, to: c_int, word: [*c]const u8) bool {
    const length: c_int = @intCast(libc.strlen(word));
    return length > 0 and at + length <= to and libc.memcmp(lexer.*.text + @as(usize, @intCast(at)), word, @intCast(length)) == 0;
}

/// First position of `word` in [at, to), or -1.
fn rvn_lex_find(lexer: [*c]const rvn_lexer_t, at_in: c_int, to: c_int, word: [*c]const u8) c_int {
    var at = at_in;
    const length: c_int = @intCast(libc.strlen(word));
    if (length == 0) return -1;
    while (at + length <= to) : (at += 1) {
        if (libc.memcmp(lexer.*.text + @as(usize, @intCast(at)), word, @intCast(length)) == 0) return at;
    }
    return -1;
}

fn rvn_lex_find_nocase(lexer: [*c]const rvn_lexer_t, at_in: c_int, to: c_int, word: [*c]const u8) c_int {
    var at = at_in;
    const length: c_int = @intCast(libc.strlen(word));
    while (at + length <= to) : (at += 1) {
        if (base.rvn_strnicmp(lexer.*.text + @as(usize, @intCast(at)), word, @intCast(length)) == 0) return at;
    }
    return -1;
}

fn rvn_lex_is_space(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn rvn_lex_is_word(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$' or c >= 0x80;
}

fn rvn_lex_is_digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// ---------------------------------------------------------------------------
//  Words
// ---------------------------------------------------------------------------

fn rvn_language_compare(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const pa: *const [*c]const u8 = @ptrCast(@alignCast(a));
    const pb: *const [*c]const u8 = @ptrCast(@alignCast(b));
    return libc.strcmp(pa.*, pb.*);
}

fn rvn_language_compare_nocase(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const pa: *const [*c]const u8 = @ptrCast(@alignCast(a));
    const pb: *const [*c]const u8 = @ptrCast(@alignCast(b));
    return base.rvn_stricmp(pa.*, pb.*);
}

/// Is text[0..length) one of the words of a list?
fn rvn_language_has_word(language: [*c]const rvn_language_t, list: c_int, text: [*c]const u8, length: c_int) bool {
    const ignore_case = (language.*.desc.flags & raven.R_LANGUAGE_IGNORE_CASE) != 0;
    var low: u32 = 0;
    var high: u32 = language.*.word_count[@intCast(list)];
    while (low < high) {
        const middle: u32 = (low + high) / 2;
        const word = language.*.words[@intCast(list)][middle];
        var order: c_int = if (ignore_case) base.rvn_strnicmp(text, word, @intCast(length)) else libc.strncmp(text, word, @intCast(length));
        // (equal over `length` characters: the word of the list may still be longer)
        if (order == 0 and word[@intCast(length)] != 0) order = -1;
        if (order == 0) return true;
        if (order < 0) {
            high = middle;
        } else {
            low = middle + 1;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
//  Code
//
//  State: 0 in code, 1..15 inside a block comment (the depth, for the
//  languages whose comments nest), 16 + k inside the k-th kind of text that
//  spans lines.
// ---------------------------------------------------------------------------

const RVN_CODE_MULTILINE = 16;

/// End of a quoted text that starts at `at` (on the quote): the position after its closing quote, or `to`.
fn rvn_lex_string_end(lexer: [*c]const rvn_lexer_t, at: c_int, to: c_int, quote: u8) c_int {
    var end = at + 1;
    while (end < to and lexer.*.text[@intCast(end)] != quote) {
        if (lexer.*.text[@intCast(end)] == '\\' and end + 1 < to) end += 1;
        end += 1;
    }
    return if (end < to) end + 1 else to;
}

/// End of the k-th kind of text that spans lines, looked for from `at`: the
/// position after what closes it, or -1 when it does not end on this line.
/// A text closed by what opened it is an ordinary one, where a backslash
/// protects the next character; the others are raw.
fn rvn_lex_multiline_end(lexer: [*c]const rvn_lexer_t, language: [*c]const rvn_language_t, k: c_int, at_in: c_int, to: c_int) c_int {
    var at = at_in;
    const close = language.*.multiline_close[@intCast(k)];
    const length: c_int = @intCast(libc.strlen(close));
    if (close != language.*.multiline[@intCast(k)]) {
        const end = rvn_lex_find(lexer, at, to, close);
        return if (end < 0) -1 else end + length;
    }
    while (at < to) {
        if (lexer.*.text[@intCast(at)] == '\\') {
            at += 2;
        } else if (rvn_lex_starts(lexer, at, to, close)) {
            return at + length;
        } else {
            at += 1;
        }
    }
    return -1;
}

fn rvn_lex_code(lexer: [*c]rvn_lexer_t, language: [*c]const rvn_language_t, state_in: u8, from: c_int, to: c_int) u8 {
    var state = state_in;
    const desc: [*c]const raven.RLanguageDesc = &language.*.desc;
    const text = lexer.*.text;
    const quotes: [*c]const u8 = if (desc.*.string_quotes != null) desc.*.string_quotes else "";
    const has_block = desc.*.block_comment_start != null and desc.*.block_comment_start[0] != 0 and desc.*.block_comment_end != null and desc.*.block_comment_end[0] != 0;
    const nested = (desc.*.flags & raven.R_LANGUAGE_NESTED_COMMENTS) != 0;
    // "--[[" opens a block where "--" would start a line comment: the longer mark is looked for first
    const line_first = desc.*.line_comment != null and (!has_block or libc.strlen(desc.*.line_comment) > libc.strlen(desc.*.block_comment_start));
    var i = from;
    var end: c_int = undefined;
    var first = true;

    while (i < to) {
        const c = text[@intCast(i)];

        if (state >= 1 and state < RVN_CODE_MULTILINE) {
            // inside a block comment: to its end, counting the comments opened inside it when they nest
            const start = i;
            while (i < to and state >= 1) {
                if (rvn_lex_starts(lexer, i, to, desc.*.block_comment_end)) {
                    i += @as(c_int, @intCast(libc.strlen(desc.*.block_comment_end)));
                    state -= 1;
                } else if (nested and state < RVN_CODE_MULTILINE - 1 and rvn_lex_starts(lexer, i, to, desc.*.block_comment_start)) {
                    i += @as(c_int, @intCast(libc.strlen(desc.*.block_comment_start)));
                    state += 1;
                } else {
                    i += 1;
                }
            }
            rvn_lex_emit(lexer, start, i, common.RVN_TOKEN_COMMENT);
            continue;
        }
        if (state >= RVN_CODE_MULTILINE) {
            end = if (@as(c_int, state) - RVN_CODE_MULTILINE < language.*.multiline_count)
                rvn_lex_multiline_end(lexer, language, @as(c_int, state) - RVN_CODE_MULTILINE, i, to)
            else
                i;
            if (end < 0) {
                rvn_lex_emit(lexer, i, to, common.RVN_TOKEN_STRING);
                return state;
            }
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_STRING);
            i = end;
            state = 0;
            continue;
        }
        if (rvn_lex_is_space(c)) {
            i += 1;
            continue;
        }
        if (line_first and rvn_lex_starts(lexer, i, to, desc.*.line_comment)) {
            rvn_lex_emit(lexer, i, to, common.RVN_TOKEN_COMMENT);
            return state;
        }
        if (has_block and rvn_lex_starts(lexer, i, to, desc.*.block_comment_start)) {
            // (the opening is read again as the start of the comment, so that it gets its color)
            const open: c_int = @intCast(libc.strlen(desc.*.block_comment_start));
            const start = i;
            state = 1;
            i += open;
            while (i < to and state >= 1) {
                if (rvn_lex_starts(lexer, i, to, desc.*.block_comment_end)) {
                    i += @as(c_int, @intCast(libc.strlen(desc.*.block_comment_end)));
                    state -= 1;
                } else if (nested and state < RVN_CODE_MULTILINE - 1 and rvn_lex_starts(lexer, i, to, desc.*.block_comment_start)) {
                    i += open;
                    state += 1;
                } else {
                    i += 1;
                }
            }
            rvn_lex_emit(lexer, start, i, common.RVN_TOKEN_COMMENT);
            first = false;
            continue;
        }
        if (!line_first and desc.*.line_comment != null and rvn_lex_starts(lexer, i, to, desc.*.line_comment)) {
            rvn_lex_emit(lexer, i, to, common.RVN_TOKEN_COMMENT);
            return state;
        }
        if (first and desc.*.directive != null and rvn_lex_starts(lexer, i, to, desc.*.directive)) {
            // a line for the preprocessor: #include <file>, #pragma once
            end = i + @as(c_int, @intCast(libc.strlen(desc.*.directive)));
            while (end < to and rvn_lex_is_space(text[@intCast(end)])) end += 1;
            while (end < to and rvn_lex_is_word(text[@intCast(end)])) end += 1;
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_PREPROCESSOR);
            while (end < to and rvn_lex_is_space(text[@intCast(end)])) end += 1;
            if (end < to and text[@intCast(end)] == '<') {
                var close = end;
                while (close < to and text[@intCast(close)] != '>') close += 1;
                if (close < to) {
                    rvn_lex_emit(lexer, end, close + 1, common.RVN_TOKEN_STRING);
                    end = close + 1;
                }
            }
            i = end;
            first = false;
            continue;
        }
        first = false;
        if (desc.*.annotation != null and rvn_lex_starts(lexer, i, to, desc.*.annotation)) {
            const length = libc.strlen(desc.*.annotation);
            end = i + @as(c_int, @intCast(length));
            if (desc.*.annotation[length - 1] == '[') {
                // #[derive(Debug)]: to the bracket that closes it
                var depth: c_int = 1;
                while (end < to and depth > 0) {
                    if (text[@intCast(end)] == '[') {
                        depth += 1;
                    } else if (text[@intCast(end)] == ']') {
                        depth -= 1;
                    }
                    end += 1;
                }
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_PREPROCESSOR);
                i = end;
                continue;
            }
            if (end < to and rvn_lex_is_word(text[@intCast(end)]) and !rvn_lex_is_digit(text[@intCast(end)])) {
                // @Override, @app.route
                while (end < to and (rvn_lex_is_word(text[@intCast(end)]) or text[@intCast(end)] == '.')) end += 1;
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_PREPROCESSOR);
                i = end;
                continue;
            }
        }
        var k: c_int = 0;
        while (k < language.*.multiline_count) : (k += 1) {
            if (rvn_lex_starts(lexer, i, to, language.*.multiline[@intCast(k)])) break;
        }
        if (k < language.*.multiline_count) {
            end = rvn_lex_multiline_end(lexer, language, k, i + @as(c_int, @intCast(libc.strlen(language.*.multiline[@intCast(k)]))), to);
            if (end < 0) {
                rvn_lex_emit(lexer, i, to, common.RVN_TOKEN_STRING);
                return @intCast(RVN_CODE_MULTILINE + k);
            }
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_STRING);
            i = end;
            continue;
        }
        if (c != 0 and libc.strchr(quotes, c) != null) {
            if (c == '\'' and (desc.*.flags & raven.R_LANGUAGE_CHAR_LITERALS) != 0) {
                // one character between the quotes, or it is not a text: a lifetime, an apostrophe
                var close: c_int = i + 1;
                if (close < to and text[@intCast(close)] == '\\') {
                    close += 2;
                    while (close < to and close - i < 12 and text[@intCast(close)] != '\'') close += 1;
                } else if (close < to) {
                    close = base.rvn_utf8_next(text, to, close);
                }
                if (close < to and text[@intCast(close)] == '\'' and close > i + 1) {
                    rvn_lex_emit(lexer, i, close + 1, common.RVN_TOKEN_STRING);
                    i = close + 1;
                } else {
                    i += 1;
                }
                continue;
            }
            end = rvn_lex_string_end(lexer, i, to, c);
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_STRING);
            i = end;
            continue;
        }
        if (rvn_lex_is_digit(c) or (c == '.' and i + 1 < to and rvn_lex_is_digit(text[@intCast(i + 1)]))) {
            end = i + 1;
            while (end < to and (rvn_lex_is_word(text[@intCast(end)]) or text[@intCast(end)] == '.' or
                ((text[@intCast(end)] == '+' or text[@intCast(end)] == '-') and (text[@intCast(end - 1)] == 'e' or text[@intCast(end - 1)] == 'E') and
                    !(text[@intCast(i)] == '0' and i + 1 < to and (text[@intCast(i + 1)] == 'x' or text[@intCast(i + 1)] == 'X'))))) end += 1;
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_NUMBER);
            i = end;
            continue;
        }
        if (rvn_lex_is_word(c)) {
            end = i;
            while (end < to and rvn_lex_is_word(text[@intCast(end)])) end += 1;
            if (rvn_language_has_word(language, 0, text + @as(usize, @intCast(i)), end - i)) {
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_KEYWORD);
            } else if (rvn_language_has_word(language, 1, text + @as(usize, @intCast(i)), end - i)) {
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_TYPE);
            } else if (rvn_language_has_word(language, 2, text + @as(usize, @intCast(i)), end - i)) {
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_NUMBER);
            } else {
                // a name followed by a parenthesis is the name of a function (println! in Rust)
                var after = end;
                if (after < to and text[@intCast(after)] == '!') after += 1;
                while (after < to and rvn_lex_is_space(text[@intCast(after)])) after += 1;
                if (after < to and text[@intCast(after)] == '(') rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_FUNCTION);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    return state;
}

// ---------------------------------------------------------------------------
//  Style sheets (CSS)
//
//  State: bits 0..2 = how many braces are open, bit 3 = inside a comment.
// ---------------------------------------------------------------------------

const RVN_CSS_COMMENT: u8 = 8;

fn rvn_css_is_name(c: u8) bool {
    return rvn_lex_is_word(c) or c == '-';
}

fn rvn_lex_css(lexer: [*c]rvn_lexer_t, language: [*c]const rvn_language_t, state_in: u8, from: c_int, to: c_int) u8 {
    const text = lexer.*.text;
    var depth: c_int = state_in & 7;
    var i = from;
    var end: c_int = undefined;
    var in_value = false;

    if ((state_in & RVN_CSS_COMMENT) != 0) {
        end = rvn_lex_find(lexer, i, to, "*/");
        if (end < 0) {
            rvn_lex_emit(lexer, i, to, common.RVN_TOKEN_COMMENT);
            return state_in;
        }
        rvn_lex_emit(lexer, i, end + 2, common.RVN_TOKEN_COMMENT);
        i = end + 2;
    }
    while (i < to) {
        const c = text[@intCast(i)];
        // inside braces, what comes before a ':' is a property, unless a '{' comes first (a nested rule)
        var selector = depth == 0;
        if (!selector and !in_value) {
            var look = i;
            while (look < to and text[@intCast(look)] != ';' and text[@intCast(look)] != '{' and text[@intCast(look)] != '}') look += 1;
            if (look < to and text[@intCast(look)] == '{') selector = true;
        }
        if (rvn_lex_is_space(c)) {
            i += 1;
        } else if (rvn_lex_starts(lexer, i, to, "/*")) {
            end = rvn_lex_find(lexer, i + 2, to, "*/");
            if (end < 0) {
                rvn_lex_emit(lexer, i, to, common.RVN_TOKEN_COMMENT);
                return @intCast(depth | RVN_CSS_COMMENT);
            }
            rvn_lex_emit(lexer, i, end + 2, common.RVN_TOKEN_COMMENT);
            i = end + 2;
        } else if (c == '"' or c == '\'') {
            end = rvn_lex_string_end(lexer, i, to, c);
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_STRING);
            i = end;
        } else if (c == '{') {
            if (depth < 7) depth += 1;
            in_value = false;
            i += 1;
        } else if (c == '}') {
            if (depth > 0) depth -= 1;
            in_value = false;
            i += 1;
        } else if (c == ';') {
            in_value = false;
            i += 1;
        } else if (c == '@') {
            end = i + 1;
            while (end < to and rvn_css_is_name(text[@intCast(end)])) end += 1;
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_PREPROCESSOR);
            i = end;
        } else if (selector) {
            if (c == '.' or c == '#') {
                end = i + 1;
                while (end < to and rvn_css_is_name(text[@intCast(end)])) end += 1;
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_ATTRIBUTE);
                i = end;
            } else if (c == ':') {
                end = i + 1;
                while (end < to and (rvn_css_is_name(text[@intCast(end)]) or text[@intCast(end)] == ':')) end += 1;
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_KEYWORD);
                i = end;
            } else if (rvn_css_is_name(c)) {
                end = i;
                while (end < to and rvn_css_is_name(text[@intCast(end)])) end += 1;
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_TAG);
                i = end;
            } else {
                i += 1;
            }
        } else if (!in_value) {
            if (rvn_css_is_name(c)) {
                end = i;
                while (end < to and rvn_css_is_name(text[@intCast(end)])) end += 1;
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_ATTRIBUTE);
                i = end;
            } else {
                if (c == ':') in_value = true;
                i += 1;
            }
        } else if (c == '#' or rvn_lex_is_digit(c) or ((c == '.' or c == '-') and i + 1 < to and rvn_lex_is_digit(text[@intCast(i + 1)]))) {
            // a color, a number with its unit
            end = i + 1;
            while (end < to and (rvn_lex_is_word(text[@intCast(end)]) or text[@intCast(end)] == '.' or text[@intCast(end)] == '%')) end += 1;
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_NUMBER);
            i = end;
        } else if (c == '!') {
            end = i + 1;
            while (end < to and rvn_css_is_name(text[@intCast(end)])) end += 1;
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_KEYWORD);
            i = end;
        } else if (rvn_css_is_name(c)) {
            end = i;
            while (end < to and rvn_css_is_name(text[@intCast(end)])) end += 1;
            if (end < to and text[@intCast(end)] == '(') {
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_FUNCTION);
            } else if (rvn_language_has_word(language, 0, text + @as(usize, @intCast(i)), end - i)) {
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_KEYWORD);
            }
            i = end;
        } else {
            i += 1;
        }
    }
    return @intCast(depth);
}

// ---------------------------------------------------------------------------
//  Markup (XML, HTML)
//
//  State: bits 0..2 = where in the markup, bits 3..4 = the tag being read
//  opens JavaScript (1) or CSS (2); or 0x40 | state of the code lexer inside
//  <script>, or 0x80 | state of the style lexer inside <style>.
// ---------------------------------------------------------------------------

const RVN_XML_CONTENT: c_int = 0;
const RVN_XML_COMMENT: c_int = 1;
const RVN_XML_TAG: c_int = 2;
const RVN_XML_DOUBLE_QUOTED: c_int = 3;
const RVN_XML_SINGLE_QUOTED: c_int = 4;
const RVN_XML_CDATA: c_int = 5;
const RVN_XML_DECLARATION: c_int = 6;

const RVN_XML_SCRIPT: u8 = 0x40;
const RVN_XML_STYLE: u8 = 0x80;

fn rvn_xml_is_name(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
        c == '_' or c == '-' or c == '.' or c == ':' or c >= 0x80;
}

fn rvn_lex_markup(lexer: [*c]rvn_lexer_t, language: [*c]const rvn_language_t, full_state: u8) u8 {
    const text = lexer.*.text;
    const length = lexer.*.length;
    var i: c_int = 0;
    const embeds = (language.*.desc.flags & raven.R_LANGUAGE_EMBEDS) != 0;
    var state: c_int = full_state & 7;
    var pending: c_int = (full_state >> 3) & 3;

    // inside <script> or <style>: another language, until the closing tag
    if ((full_state & (RVN_XML_SCRIPT | RVN_XML_STYLE)) != 0) {
        const script = (full_state & RVN_XML_SCRIPT) != 0;
        const lang_name: [*c]const u8 = if (script)
            (if (language.*.desc.script_language != null) language.*.desc.script_language else "javascript")
        else
            "css";
        var inner = rvn_language_find(lang_name);
        const close_tag: [*c]const u8 = if (script) "</script" else "</style";
        const close = rvn_lex_find_nocase(lexer, 0, length, close_tag);
        var sub: u8 = full_state & 0x3F;
        const to = if (close < 0) length else close;
        // (a code lexer for the code: a language of markup there would not know what to do with it)
        if (inner != null and script and (inner.*.desc.flags & (raven.R_LANGUAGE_MARKUP | raven.R_LANGUAGE_STYLE_SHEET | raven.R_LANGUAGE_FORMATTED_TEXT)) != 0) inner = null;
        if (inner != null) {
            sub = if (script) rvn_lex_code(lexer, inner, sub, 0, to) else rvn_lex_css(lexer, inner, sub, 0, to);
        }
        if (close < 0) return (if (script) RVN_XML_SCRIPT else RVN_XML_STYLE) | (sub & 0x3F);
        i = close;
        state = RVN_XML_CONTENT;
        pending = 0;
    }

    while (i < length) {
        var end: c_int = undefined;
        switch (state) {
            RVN_XML_COMMENT => {
                end = rvn_lex_find(lexer, i, length, "-->");
                if (end < 0) {
                    rvn_lex_emit(lexer, i, length, common.RVN_TOKEN_COMMENT);
                    return @intCast(state);
                }
                rvn_lex_emit(lexer, i, end + 3, common.RVN_TOKEN_COMMENT);
                i = end + 3;
                state = RVN_XML_CONTENT;
            },
            RVN_XML_CDATA => {
                end = rvn_lex_find(lexer, i, length, "]]>");
                if (end < 0) return @intCast(state);
                rvn_lex_emit(lexer, end, end + 3, common.RVN_TOKEN_PUNCTUATION);
                i = end + 3;
                state = RVN_XML_CONTENT;
            },
            RVN_XML_DECLARATION => {
                end = rvn_lex_find(lexer, i, length, ">");
                if (end < 0) {
                    rvn_lex_emit(lexer, i, length, common.RVN_TOKEN_PREPROCESSOR);
                    return @intCast(state);
                }
                rvn_lex_emit(lexer, i, end + 1, common.RVN_TOKEN_PREPROCESSOR);
                i = end + 1;
                state = RVN_XML_CONTENT;
            },
            RVN_XML_DOUBLE_QUOTED, RVN_XML_SINGLE_QUOTED => {
                const quote_str: [*c]const u8 = if (state == RVN_XML_DOUBLE_QUOTED) "\"" else "'";
                end = rvn_lex_find(lexer, i, length, quote_str);
                if (end < 0) {
                    rvn_lex_emit(lexer, i, length, common.RVN_TOKEN_STRING);
                    return @intCast(state | (pending << 3));
                }
                rvn_lex_emit(lexer, i, end + 1, common.RVN_TOKEN_STRING);
                i = end + 1;
                state = RVN_XML_TAG;
            },
            RVN_XML_TAG => {
                if (rvn_lex_is_space(text[@intCast(i)])) {
                    i += 1;
                } else if (text[@intCast(i)] == '>') {
                    rvn_lex_emit(lexer, i, i + 1, common.RVN_TOKEN_PUNCTUATION);
                    i += 1;
                    if (pending != 0) {
                        // the rest of the line, and the lines after it, are in the other language
                        const rest: u8 = if (pending == 1) RVN_XML_SCRIPT else RVN_XML_STYLE;
                        var tail = lexer.*;
                        tail.text = text + @as(usize, @intCast(i));
                        tail.length = length - i;
                        tail.spans = if (lexer.*.spans != null) lexer.*.spans + @as(usize, @intCast(lexer.*.count)) else null;
                        tail.max = lexer.*.max - lexer.*.count;
                        tail.count = 0;
                        const out = rvn_lex_markup(&tail, language, rest);
                        // (the spans of the tail are counted from where the tail starts)
                        end = 0;
                        while (end < tail.count) : (end += 1) {
                            lexer.*.spans[@intCast(lexer.*.count + end)].start += i;
                            lexer.*.spans[@intCast(lexer.*.count + end)].end += i;
                        }
                        lexer.*.count += tail.count;
                        return out;
                    }
                    state = RVN_XML_CONTENT;
                } else if (rvn_lex_starts(lexer, i, length, "/>")) {
                    rvn_lex_emit(lexer, i, i + 2, common.RVN_TOKEN_PUNCTUATION);
                    i += 2;
                    state = RVN_XML_CONTENT;
                    pending = 0;
                } else if (text[@intCast(i)] == '"' or text[@intCast(i)] == '\'') {
                    var close = i + 1;
                    const quote = text[@intCast(i)];
                    while (close < length and text[@intCast(close)] != quote) close += 1;
                    if (close < length) {
                        rvn_lex_emit(lexer, i, close + 1, common.RVN_TOKEN_STRING);
                        i = close + 1;
                    } else {
                        rvn_lex_emit(lexer, i, length, common.RVN_TOKEN_STRING);
                        return @intCast((if (quote == '"') RVN_XML_DOUBLE_QUOTED else RVN_XML_SINGLE_QUOTED) | (pending << 3));
                    }
                } else if (text[@intCast(i)] == '=') {
                    rvn_lex_emit(lexer, i, i + 1, common.RVN_TOKEN_PUNCTUATION);
                    i += 1;
                } else if (rvn_xml_is_name(text[@intCast(i)])) {
                    end = i;
                    while (end < length and rvn_xml_is_name(text[@intCast(end)])) end += 1;
                    rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_ATTRIBUTE);
                    i = end;
                } else {
                    i += 1;
                }
            },
            // (RVN_XML_CONTENT and the default of the C switch)
            else => {
                if (rvn_lex_starts(lexer, i, length, "<!--")) {
                    state = RVN_XML_COMMENT;
                } else if (rvn_lex_starts(lexer, i, length, "<![CDATA[")) {
                    rvn_lex_emit(lexer, i, i + 9, common.RVN_TOKEN_PUNCTUATION);
                    i += 9;
                    state = RVN_XML_CDATA;
                } else if (rvn_lex_starts(lexer, i, length, "<?") or rvn_lex_starts(lexer, i, length, "<!")) {
                    state = RVN_XML_DECLARATION;
                } else if (text[@intCast(i)] == '<') {
                    var name = i + 1;
                    const closing = name < length and text[@intCast(name)] == '/';
                    if (closing) name += 1;
                    rvn_lex_emit(lexer, i, name, common.RVN_TOKEN_PUNCTUATION);
                    end = name;
                    while (end < length and rvn_xml_is_name(text[@intCast(end)])) end += 1;
                    rvn_lex_emit(lexer, name, end, common.RVN_TOKEN_TAG);
                    pending = 0;
                    if (embeds and !closing) {
                        if (end - name == 6 and base.rvn_strnicmp(text + @as(usize, @intCast(name)), "script", 6) == 0) {
                            pending = 1;
                        } else if (end - name == 5 and base.rvn_strnicmp(text + @as(usize, @intCast(name)), "style", 5) == 0) {
                            pending = 2;
                        }
                    }
                    i = end;
                    state = RVN_XML_TAG;
                } else if (text[@intCast(i)] == '&') {
                    // an entity: &amp; &#x20AC;
                    end = i + 1;
                    while (end < length and end - i < 12 and text[@intCast(end)] != ';' and !rvn_lex_is_space(text[@intCast(end)]) and text[@intCast(end)] != '<') end += 1;
                    if (end < length and text[@intCast(end)] == ';') {
                        rvn_lex_emit(lexer, i, end + 1, common.RVN_TOKEN_NUMBER);
                        i = end + 1;
                    } else {
                        i += 1;
                    }
                } else {
                    i += 1;
                }
            },
        }
    }
    return @intCast(state | (if (state == RVN_XML_TAG) (pending << 3) else 0));
}

// ---------------------------------------------------------------------------
//  Formatted text (Markdown), as it is written
//
//  State of a line: 0, or RVN_MD_IN_CODE between two fences, with the mark
//  of the fence that opened (so that ~~~ inside ``` does not close it).
// ---------------------------------------------------------------------------

const RVN_MD_IN_CODE: u8 = 1;
const RVN_MD_TILDE: u8 = 2;

/// Where the mark that closes what opened before `from` is, or -1.
fn rvn_lex_md_closer(text: [*c]const u8, from: c_int, length: c_int, mark: [*c]const u8, mark_length: c_int) c_int {
    var i = from;
    while (i + mark_length <= length) : (i += 1) {
        if (text[@intCast(i)] == '\\' and i + 1 < length) {
            i += 1;
            continue;
        }
        if (libc.memcmp(text + @as(usize, @intCast(i)), mark, @intCast(mark_length)) == 0 and i > from and text[@intCast(i - 1)] != ' ') return i;
    }
    return -1;
}

fn rvn_lex_markdown(lexer: [*c]rvn_lexer_t, state: u8) u8 {
    const text = lexer.*.text;
    const length = lexer.*.length;
    var i: c_int = 0;
    var run: c_int = undefined;

    while (i < length and (text[@intCast(i)] == ' ' or text[@intCast(i)] == '\t')) i += 1;

    if ((state & RVN_MD_IN_CODE) != 0) {
        const mark: u8 = if ((state & RVN_MD_TILDE) != 0) '~' else '`';
        run = 0;
        while (i + run < length and text[@intCast(i + run)] == mark) run += 1;
        if (run >= 3 and i + run == length) {
            rvn_lex_emit(lexer, i, length, common.RVN_TOKEN_PUNCTUATION);
            return 0;
        }
        rvn_lex_emit(lexer, 0, length, common.RVN_TOKEN_STRING);
        return state;
    }

    // quotes
    while (i < length and text[@intCast(i)] == '>') {
        rvn_lex_emit(lexer, i, i + 1, common.RVN_TOKEN_PUNCTUATION);
        i += 1;
        while (i < length and text[@intCast(i)] == ' ') i += 1;
    }
    if (i >= length) return 0;

    // a fence
    if (text[@intCast(i)] == '`' or text[@intCast(i)] == '~') {
        run = 0;
        while (i + run < length and text[@intCast(i + run)] == text[@intCast(i)]) run += 1;
        if (run >= 3 and (text[@intCast(i)] == '~' or libc.memchr(text + @as(usize, @intCast(i + run)), '`', @intCast(length - i - run)) == null)) {
            rvn_lex_emit(lexer, i, i + run, common.RVN_TOKEN_PUNCTUATION);
            rvn_lex_emit(lexer, i + run, length, common.RVN_TOKEN_KEYWORD);
            return RVN_MD_IN_CODE | (if (text[@intCast(i)] == '~') RVN_MD_TILDE else 0);
        }
    }
    // a title
    if (text[@intCast(i)] == '#') {
        run = 0;
        while (i + run < length and text[@intCast(i + run)] == '#') run += 1;
        if (run <= 6 and (i + run == length or text[@intCast(i + run)] == ' ')) {
            rvn_lex_emit(lexer, i, length, common.RVN_TOKEN_HEADING);
            return 0;
        }
    }
    // a rule, or the line under a title
    {
        var k = i;
        var marks: c_int = 0;
        var other: c_int = 0;
        while (k < length) : (k += 1) {
            if (text[@intCast(k)] == '-' or text[@intCast(k)] == '*' or text[@intCast(k)] == '_' or text[@intCast(k)] == '=') {
                marks += @intFromBool(text[@intCast(k)] == text[@intCast(i)]);
            } else if (text[@intCast(k)] != ' ') {
                other += 1;
            }
        }
        if (other == 0 and marks >= 3) {
            rvn_lex_emit(lexer, i, length, common.RVN_TOKEN_PUNCTUATION);
            return 0;
        }
    }
    // the mark of a list item, and the box of a task
    if ((text[@intCast(i)] == '-' or text[@intCast(i)] == '*' or text[@intCast(i)] == '+') and i + 1 < length and text[@intCast(i + 1)] == ' ') {
        rvn_lex_emit(lexer, i, i + 1, common.RVN_TOKEN_KEYWORD);
        i += 2;
        if (i + 2 < length and text[@intCast(i)] == '[' and text[@intCast(i + 2)] == ']' and (text[@intCast(i + 1)] == ' ' or text[@intCast(i + 1)] == 'x' or text[@intCast(i + 1)] == 'X')) {
            rvn_lex_emit(lexer, i, i + 3, common.RVN_TOKEN_KEYWORD);
            i += 3;
        }
    } else if (text[@intCast(i)] >= '0' and text[@intCast(i)] <= '9') {
        var k = i;
        while (k < length and text[@intCast(k)] >= '0' and text[@intCast(k)] <= '9') k += 1;
        if (k + 1 < length and (text[@intCast(k)] == '.' or text[@intCast(k)] == ')') and text[@intCast(k + 1)] == ' ') {
            rvn_lex_emit(lexer, i, k + 1, common.RVN_TOKEN_KEYWORD);
            i = k + 2;
        }
    }

    while (i < length) {
        const c = text[@intCast(i)];
        var end: c_int = undefined;
        if (c == '\\' and i + 1 < length) {
            rvn_lex_emit(lexer, i, i + 1, common.RVN_TOKEN_PUNCTUATION);
            i += 2;
            continue;
        }
        if (c == '`') {
            run = 0;
            while (i + run < length and text[@intCast(i + run)] == '`') run += 1;
            end = i + run;
            while (end < length) {
                var close: c_int = 0;
                while (end + close < length and text[@intCast(end + close)] == '`') close += 1;
                if (close == run) break;
                end += if (close != 0) close else 1;
            }
            if (end < length) {
                rvn_lex_emit(lexer, i, end + run, common.RVN_TOKEN_STRING);
                i = end + run;
                continue;
            }
            i += run;
            continue;
        }
        if ((c == '*' or c == '_') and i + 1 < length) {
            const strong = text[@intCast(i + 1)] == c;
            const mark_length: c_int = if (strong) 2 else 1;
            const inside_word = c == '_' and i > 0 and ((text[@intCast(i - 1)] >= 'a' and text[@intCast(i - 1)] <= 'z') or (text[@intCast(i - 1)] >= 'A' and text[@intCast(i - 1)] <= 'Z') or (text[@intCast(i - 1)] >= '0' and text[@intCast(i - 1)] <= '9'));
            const mark = [_]u8{ c, c };
            if (!inside_word and i + mark_length < length and text[@intCast(i + mark_length)] != ' ') {
                end = rvn_lex_md_closer(text, i + mark_length, length, &mark, mark_length);
                if (end >= 0) {
                    // ("***both***": the third star belongs to what is inside)
                    var stop = end + mark_length;
                    while (stop < length and text[@intCast(stop)] == c and stop - end < 3) stop += 1;
                    rvn_lex_emit(lexer, i, stop, if (strong) common.RVN_TOKEN_STRONG else common.RVN_TOKEN_EMPHASIS);
                    i = stop;
                    continue;
                }
            }
            i += mark_length;
            continue;
        }
        if (c == '~' and i + 1 < length and text[@intCast(i + 1)] == '~') {
            end = rvn_lex_md_closer(text, i + 2, length, "~~", 2);
            if (end >= 0) {
                rvn_lex_emit(lexer, i, end + 2, common.RVN_TOKEN_COMMENT);
                i = end + 2;
                continue;
            }
            i += 2;
            continue;
        }
        if (c == '[' or (c == '!' and i + 1 < length and text[@intCast(i + 1)] == '[')) {
            var close = i + 1;
            var nest: c_int = 0;
            while (close < length) {
                if (text[@intCast(close)] == '[') {
                    nest += 1;
                } else if (text[@intCast(close)] == ']') {
                    nest -= 1;
                    if (nest <= 0) break;
                }
                close += 1;
            }
            if (close + 1 < length and text[@intCast(close + 1)] == '(') {
                end = close + 2;
                while (end < length and text[@intCast(end)] != ')') end += 1;
                if (end < length) {
                    rvn_lex_emit(lexer, i, end + 1, common.RVN_TOKEN_LINK);
                    i = end + 1;
                    continue;
                }
            }
        }
        if (c == '<') {
            if (rvn_lex_starts(lexer, i, length, "<!--")) {
                end = rvn_lex_find(lexer, i + 4, length, "-->");
                end = if (end < 0) length else end + 3;
                rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_COMMENT);
                i = end;
                continue;
            }
            end = i + 1;
            while (end < length and text[@intCast(end)] != '>' and text[@intCast(end)] != ' ') end += 1;
            if (end < length and text[@intCast(end)] == '>' and end > i + 1) {
                const address = libc.memchr(text + @as(usize, @intCast(i)), ':', @intCast(end - i)) != null or libc.memchr(text + @as(usize, @intCast(i)), '@', @intCast(end - i)) != null;
                rvn_lex_emit(lexer, i, end + 1, if (address) common.RVN_TOKEN_LINK else common.RVN_TOKEN_TAG);
                i = end + 1;
                continue;
            }
        }
        if (c == 'h' and (rvn_lex_starts(lexer, i, length, "http://") or rvn_lex_starts(lexer, i, length, "https://"))) {
            end = i;
            while (end < length and text[@intCast(end)] != ' ' and text[@intCast(end)] != '\t' and text[@intCast(end)] != ')' and text[@intCast(end)] != '>') end += 1;
            rvn_lex_emit(lexer, i, end, common.RVN_TOKEN_LINK);
            i = end;
            continue;
        }
        if (c == '|') rvn_lex_emit(lexer, i, i + 1, common.RVN_TOKEN_PUNCTUATION);
        i += 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
//  Entry points of the editor
// ---------------------------------------------------------------------------

export fn rvn_syntax_line(language: [*c]const rvn_language_t, text: [*c]const u8, length: c_int, state_in: u8, spans: [*c]common.rvn_span_t, max: c_int, count: [*c]c_int) u8 {
    var state = state_in;
    var lexer: rvn_lexer_t = undefined;
    lexer.text = text;
    lexer.length = length;
    lexer.spans = spans;
    lexer.max = max;
    lexer.count = 0;
    if (language == null) {
        state = 0;
    } else if ((language.*.desc.flags & raven.R_LANGUAGE_FORMATTED_TEXT) != 0) {
        state = rvn_lex_markdown(&lexer, state);
    } else if ((language.*.desc.flags & raven.R_LANGUAGE_MARKUP) != 0) {
        state = rvn_lex_markup(&lexer, language, state);
    } else if ((language.*.desc.flags & raven.R_LANGUAGE_STYLE_SHEET) != 0) {
        state = rvn_lex_css(&lexer, language, state, 0, length);
    } else {
        state = rvn_lex_code(&lexer, language, state, 0, length);
    }
    if (count != null) count.* = lexer.count;
    return state;
}

export fn rvn_syntax_color(theme: [*c]const context_h.rvn_theme_t, token: common.rvn_token_t, text: base.rvn_color_t) base.rvn_color_t {
    // two palettes, for dark and for light backgrounds; 0 = the color of the text
    const dark = [_]u32{
        0, 0x7F8C98, 0xFC8E6D, 0xD9C97C, 0xFF7AB2, 0x6BDFFF, 0xDABAFF, 0x9AA5B1, 0xFFA14F, 0x67B7A4, 0x5DD8FF,
        0x5DD8FF, 0, 0, 0x6CB6FF,
    };
    const light = [_]u32{
        0, 0x6B7885, 0xC41A16, 0x1C00CF, 0x9B2393, 0x0B4F79, 0x6C36A9, 0x5C6873, 0x78492A, 0x326D74, 0x0F68A0,
        0x0F68A0, 0, 0, 0x0B62D6,
    };
    if (token <= common.RVN_TOKEN_TEXT or token >= common.RVN_TOKEN_COUNT) return text;
    // keeps the opacity of the text (disabled editors)
    if ((theme.*.token_mask & (@as(u32, 1) << @as(u5, @intCast(token)))) != 0) {
        return base.rvn_color_fade(theme.*.tokens[token], @as(f32, @floatFromInt(base.rvn_color_a(text))) / 255.0);
    }
    const rgb: u32 = if (theme.*.dark != 0) dark[token] else light[token];
    return if (rgb != 0) base.rvn_hex(rgb, base.rvn_color_a(text)) else text;
}

/// Public kinds of token, in the order of rvn_token_t.
const g_public_tokens = [_]raven.RToken{
    raven.R_TOKEN_TEXT, raven.R_TOKEN_COMMENT, raven.R_TOKEN_STRING, raven.R_TOKEN_NUMBER, raven.R_TOKEN_KEYWORD, raven.R_TOKEN_TAG, raven.R_TOKEN_ATTRIBUTE,
    raven.R_TOKEN_PUNCTUATION, raven.R_TOKEN_DIRECTIVE, raven.R_TOKEN_TYPE, raven.R_TOKEN_FUNCTION, raven.R_TOKEN_HEADING, raven.R_TOKEN_STRONG,
    raven.R_TOKEN_EMPHASIS, raven.R_TOKEN_LINK,
};

export fn rvn_token_public(token: common.rvn_token_t) raven.RToken {
    return if (token < common.RVN_TOKEN_COUNT) g_public_tokens[token] else raven.R_TOKEN_TEXT;
}

fn rvn_token_internal(token: raven.RToken, internal: [*c]common.rvn_token_t) bool {
    var i: c_int = 1;
    while (i < common.RVN_TOKEN_COUNT) : (i += 1) {
        if (g_public_tokens[@intCast(i)] == token) {
            internal.* = @intCast(i);
            return true;
        }
    }
    return false;
}

export fn Rtheme_set_token_color(token: raven.RToken, r: f32, g: f32, b: f32, a: f32) void {
    var internal: common.rvn_token_t = undefined;
    if (ext.rvn_api_check("Rtheme_set_token_color") == 0) return;
    if (!rvn_token_internal(token, &internal)) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtheme_set_token_color: invalid kind of token");
        return;
    }
    ext.g_rvn.theme.tokens[internal] = base.rvn_rgba(r, g, b, a);
    ext.g_rvn.theme.token_mask |= @as(u32, 1) << @as(u5, @intCast(internal));
    ext.rvn_repaint_all_windows();
}

export fn Rtheme_get_token_color(token: raven.RToken, r: [*c]f32, g: [*c]f32, b: [*c]f32, a: [*c]f32) void {
    var internal: common.rvn_token_t = undefined;
    var color: base.rvn_color_t = 0;
    if (ext.g_rvn.initialized != 0 and rvn_token_internal(token, &internal)) {
        color = rvn_syntax_color(&ext.g_rvn.theme, internal, context_h.RVN_THEME_COLOR(raven.R_COLOR_TEXT));
    }
    base.rvn_color_to_floats(color, r, g, b, a);
}

export fn Rtheme_clear_token_colors() void {
    if (ext.rvn_api_check("Rtheme_clear_token_colors") == 0) return;
    ext.g_rvn.theme.token_mask = 0;
    ext.rvn_repaint_all_windows();
}

export fn rvn_language_desc(language: [*c]const rvn_language_t) [*c]const raven.RLanguageDesc {
    return &language.*.desc;
}

export fn rvn_language_generation() u32 {
    return g_languages.generation;
}

export fn rvn_language_word_count(language: [*c]const rvn_language_t, list: c_int) c_int {
    return @intCast(language.*.word_count[@intCast(list)]);
}

export fn rvn_language_word(language: [*c]const rvn_language_t, list: c_int, index: c_int) [*c]const u8 {
    return language.*.words[@intCast(list)][@intCast(index)];
}

// ---------------------------------------------------------------------------
//  Registry
// ---------------------------------------------------------------------------

fn rvn_language_keep(language: [*c]rvn_language_t, text: [*c]const u8) [*c]const u8 {
    if (text == null) return null;
    return base.rvn_arena_strndup(&language.*.strings, text, libc.strlen(text));
}

/// Cuts a list of words separated by spaces and sorts it.
fn rvn_language_words(language: [*c]rvn_language_t, list: c_int, text: [*c]const u8) void {
    var copy: [*c]u8 = undefined;
    var cursor: [*c]u8 = undefined;
    var count: u32 = 0;
    var index: u32 = 0;
    if (text == null or text[0] == 0) return;
    copy = base.rvn_arena_strndup(&language.*.strings, text, libc.strlen(text));
    cursor = copy;
    while (cursor[0] != 0) {
        while (cursor[0] == ' ' or cursor[0] == '\t' or cursor[0] == '\n' or cursor[0] == ',') cursor += 1;
        if (cursor[0] == 0) break;
        count += 1;
        while (cursor[0] != 0 and cursor[0] != ' ' and cursor[0] != '\t' and cursor[0] != '\n' and cursor[0] != ',') cursor += 1;
    }
    if (count == 0) return;
    language.*.words[@intCast(list)] = @ptrCast(@alignCast(base.rvn_arena_alloc(&language.*.strings, @sizeOf([*c]u8) * count)));
    cursor = copy;
    while (cursor[0] != 0 and index < count) {
        while (cursor[0] == ' ' or cursor[0] == '\t' or cursor[0] == '\n' or cursor[0] == ',') {
            cursor[0] = 0;
            cursor += 1;
        }
        if (cursor[0] == 0) break;
        language.*.words[@intCast(list)][index] = cursor;
        index += 1;
        while (cursor[0] != 0 and cursor[0] != ' ' and cursor[0] != '\t' and cursor[0] != '\n' and cursor[0] != ',') cursor += 1;
    }
    language.*.word_count[@intCast(list)] = index;
    const cmp = if ((language.*.desc.flags & raven.R_LANGUAGE_IGNORE_CASE) != 0) &rvn_language_compare_nocase else &rvn_language_compare;
    libc.qsort(@ptrCast(language.*.words[@intCast(list)]), index, @sizeOf([*c]u8), cmp);
}

fn rvn_language_build(desc: [*c]const raven.RLanguageDesc) [*c]rvn_language_t {
    const language: [*c]rvn_language_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_language_t))));
    base.rvn_arena_init(&language.*.strings, 2048);
    language.*.desc.name = rvn_language_keep(language, desc.*.name);
    language.*.desc.extensions = rvn_language_keep(language, desc.*.extensions);
    language.*.desc.keywords = rvn_language_keep(language, desc.*.keywords);
    language.*.desc.types = rvn_language_keep(language, desc.*.types);
    language.*.desc.constants = rvn_language_keep(language, desc.*.constants);
    language.*.desc.line_comment = rvn_language_keep(language, if (desc.*.line_comment != null and desc.*.line_comment[0] != 0) desc.*.line_comment else null);
    language.*.desc.block_comment_start = rvn_language_keep(language, desc.*.block_comment_start);
    language.*.desc.block_comment_end = rvn_language_keep(language, desc.*.block_comment_end);
    language.*.desc.string_quotes = rvn_language_keep(language, desc.*.string_quotes);
    language.*.desc.multiline_strings = rvn_language_keep(language, desc.*.multiline_strings);
    language.*.desc.directive = rvn_language_keep(language, if (desc.*.directive != null and desc.*.directive[0] != 0) desc.*.directive else null);
    language.*.desc.annotation = rvn_language_keep(language, if (desc.*.annotation != null and desc.*.annotation[0] != 0) desc.*.annotation else null);
    language.*.desc.flags = desc.*.flags;
    language.*.desc.script_language = rvn_language_keep(language, if (desc.*.script_language != null and desc.*.script_language[0] != 0) desc.*.script_language else null);
    rvn_language_words(language, 0, desc.*.keywords);
    rvn_language_words(language, 1, desc.*.types);
    rvn_language_words(language, 2, desc.*.constants);
    if (desc.*.multiline_strings != null) {
        const copy = base.rvn_arena_strndup(&language.*.strings, desc.*.multiline_strings, libc.strlen(desc.*.multiline_strings));
        var cursor = copy;
        while (cursor[0] != 0 and language.*.multiline_count < RVN_LANGUAGE_MAX_MULTILINE) {
            while (cursor[0] == ' ') {
                cursor[0] = 0;
                cursor += 1;
            }
            if (cursor[0] == 0) break;
            const slot: usize = @intCast(language.*.multiline_count);
            language.*.multiline[slot] = cursor;
            language.*.multiline_close[slot] = cursor;
            while (cursor[0] != 0 and cursor[0] != ' ') {
                // R"(...)": what opens it, three dots, what closes it
                if (cursor[0] == '.' and cursor[1] == '.' and cursor[2] == '.' and cursor != language.*.multiline[slot] and
                    cursor[3] != 0 and cursor[3] != ' ')
                {
                    cursor[0] = 0;
                    language.*.multiline_close[slot] = cursor + 3;
                    cursor += 3;
                }
                cursor += 1;
            }
            language.*.multiline_count += 1;
        }
    }
    return language;
}

fn rvn_language_free(language: [*c]rvn_language_t) void {
    base.rvn_arena_free(&language.*.strings);
    base.rvn_free(language);
}

fn rvn_language_add(desc: [*c]const raven.RLanguageDesc) void {
    const language = rvn_language_build(desc);
    var i: u32 = 0;
    g_languages.generation += 1;
    while (i < g_languages.count) : (i += 1) {
        if (base.rvn_stricmp(g_languages.items[i].*.desc.name, desc.*.name) != 0) continue;
        // replaced: kept aside, an editor may be painting with it
        // (RVN_ARRAY_RESERVE of base_h.zig, expanded here: its cast of a pointer to pointers is refused)
        if (g_languages.retired_count + 1 > g_languages.retired_cap) {
            g_languages.retired = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(g_languages.retired), &g_languages.retired_cap, g_languages.retired_count + 1, @sizeOf([*c]rvn_language_t))));
        }
        g_languages.retired[g_languages.retired_count] = g_languages.items[i];
        g_languages.retired_count += 1;
        g_languages.items[i] = language;
        return;
    }
    // (RVN_ARRAY_RESERVE expanded, see above)
    if (g_languages.count + 1 > g_languages.cap) {
        g_languages.items = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(g_languages.items), &g_languages.cap, g_languages.count + 1, @sizeOf([*c]rvn_language_t))));
    }
    g_languages.items[g_languages.count] = language;
    g_languages.count += 1;
}

// ---------------------------------------------------------------------------
//  Built-in languages
// ---------------------------------------------------------------------------

const RVN_C_KEYWORDS = "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof " ++
    "static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local";
const RVN_C_TYPES = "void char short int long float double signed unsigned bool _Bool size_t ssize_t ptrdiff_t intptr_t uintptr_t " ++
    "int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t wchar_t FILE va_list";

fn rvn_languages_built_in() void {
    var d: raven.RLanguageDesc = undefined;
    if (g_languages.built_in != 0) return;
    g_languages.built_in = raven.R_TRUE;

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "C";
    d.extensions = "c;h";
    d.keywords = RVN_C_KEYWORDS;
    d.types = RVN_C_TYPES;
    d.constants = "NULL true false";
    d.line_comment = "//";
    d.block_comment_start = "/*";
    d.block_comment_end = "*/";
    d.string_quotes = "\"'";
    d.directive = "#";
    d.flags = raven.R_LANGUAGE_CHAR_LITERALS;
    rvn_language_add(&d);

    d.name = "C++";
    d.extensions = "cpp;cc;cxx;hpp;hh;hxx;inl;ixx";
    d.keywords = RVN_C_KEYWORDS ++ " alignas alignof and and_eq asm bitand bitor catch class co_await co_return co_yield compl concept " ++
        "const_cast consteval constexpr constinit decltype delete dynamic_cast explicit export final friend mutable namespace new " ++
        "noexcept not not_eq operator or or_eq override private protected public reinterpret_cast requires static_assert static_cast " ++
        "template this thread_local throw try typeid typename using virtual xor xor_eq";
    d.types = RVN_C_TYPES ++ " char8_t char16_t char32_t string string_view vector array map unordered_map set unordered_set optional " ++
        "variant tuple pair unique_ptr shared_ptr weak_ptr function span";
    d.constants = "NULL nullptr true false";
    d.multiline_strings = "R\"(...)\"";
    rvn_language_add(&d);

    d.name = "GLSL";
    d.extensions = "glsl;vert;frag;geom;comp;tesc;tese;hlsl";
    d.keywords = "attribute break case const continue default discard do else flat for if in inout invariant layout lowp mediump highp " ++
        "noperspective out precision return smooth struct subroutine switch uniform varying while buffer shared centroid sample patch";
    d.types = "void bool int uint float double vec2 vec3 vec4 ivec2 ivec3 ivec4 uvec2 uvec3 uvec4 bvec2 bvec3 bvec4 dvec2 dvec3 dvec4 " ++
        "mat2 mat3 mat4 mat2x3 mat2x4 mat3x2 mat3x4 mat4x2 mat4x3 sampler1D sampler2D sampler3D samplerCube sampler2DArray " ++
        "sampler2DShadow samplerCubeShadow image2D float2 float3 float4 float4x4 Texture2D SamplerState";
    d.constants = "true false gl_Position gl_FragCoord gl_FragDepth gl_VertexIndex gl_InstanceIndex gl_PointSize";
    rvn_language_add(&d);

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "C#";
    d.extensions = "cs";
    d.keywords = "abstract as async await base break case catch checked class const continue default delegate do else enum event " ++
        "explicit extern finally fixed for foreach get goto if implicit in init interface internal is lock namespace new operator out " ++
        "override params partial private protected public readonly record ref required return sealed set sizeof stackalloc static " ++
        "struct switch this throw try typeof unchecked unsafe using virtual volatile when where while with yield global nameof";
    d.types = "bool byte char decimal double dynamic float int long nint nuint object sbyte short string uint ulong ushort var void " ++
        "String Object Int32 Int64 Double Boolean List Dictionary IEnumerable Task Action Func Span Guid DateTime";
    d.constants = "true false null";
    d.line_comment = "//";
    d.block_comment_start = "/*";
    d.block_comment_end = "*/";
    d.string_quotes = "\"'";
    d.multiline_strings = "\"\"\" @\"...\"";
    d.directive = "#";
    d.flags = raven.R_LANGUAGE_CHAR_LITERALS;
    rvn_language_add(&d);

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "Java";
    d.extensions = "java";
    d.keywords = "abstract assert break case catch class const continue default do else enum exports extends final finally for goto " ++
        "if implements import instanceof interface module native new non-sealed package permits private protected public record " ++
        "requires return sealed static strictfp super switch synchronized this throw throws transient try volatile while yield";
    d.types = "boolean byte char double float int long short var void String Object Integer Long Double Boolean Character List " ++
        "ArrayList Map HashMap Set HashSet Optional Stream";
    d.constants = "true false null";
    d.line_comment = "//";
    d.block_comment_start = "/*";
    d.block_comment_end = "*/";
    d.string_quotes = "\"'";
    d.multiline_strings = "\"\"\"";
    d.annotation = "@";
    d.flags = raven.R_LANGUAGE_CHAR_LITERALS;
    rvn_language_add(&d);

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "JavaScript";
    d.extensions = "js;mjs;cjs;jsx";
    d.keywords = "async await break case catch class const continue debugger default delete do else export extends finally for from " ++
        "function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield";
    d.types = "Array Boolean Date Error Function JSON Map Math Number Object Promise Proxy Reflect RegExp Set String Symbol WeakMap " ++
        "WeakSet BigInt console document window globalThis";
    d.constants = "true false null undefined NaN Infinity";
    d.line_comment = "//";
    d.block_comment_start = "/*";
    d.block_comment_end = "*/";
    d.string_quotes = "\"'";
    d.multiline_strings = "`";
    rvn_language_add(&d);

    d.name = "TypeScript";
    d.extensions = "ts;tsx;mts";
    d.keywords = "abstract as asserts async await break case catch class const continue debugger declare default delete do else enum " ++
        "export extends finally for from function get if implements import in infer instanceof interface is keyof let module namespace " ++
        "new of override private protected public readonly return satisfies set static super switch this throw try type typeof var " ++
        "void while with yield";
    d.types = "any bigint boolean never number object string symbol unknown Array Date Error Map Promise Record Partial Readonly " ++
        "Set Pick Omit console";
    rvn_language_add(&d);

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "Python";
    d.extensions = "py;pyw;pyi";
    d.keywords = "and as assert async await break case class continue def del elif else except finally for from global if import in is " ++
        "lambda match nonlocal not or pass raise return try while with yield";
    d.types = "bool bytearray bytes complex dict float frozenset int list object set str tuple type range print len open super " ++
        "isinstance enumerate zip map filter sorted min max sum abs any all self cls";
    d.constants = "True False None NotImplemented Ellipsis __name__ __main__";
    d.line_comment = "#";
    d.string_quotes = "\"'";
    d.multiline_strings = "\"\"\" '''";
    d.annotation = "@";
    d.flags = raven.R_LANGUAGE_INDENT_ON_COLON;
    rvn_language_add(&d);

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "Rust";
    d.extensions = "rs";
    d.keywords = "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref " ++
        "return self Self static struct super trait type unsafe use where while macro_rules union";
    d.types = "bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize String Vec Option Result Box Rc Arc Cell " ++
        "RefCell HashMap HashSet BTreeMap Path PathBuf";
    d.constants = "true false Some None Ok Err";
    d.line_comment = "//";
    d.block_comment_start = "/*";
    d.block_comment_end = "*/";
    d.string_quotes = "\"'";
    // (an ordinary text may span lines too)
    d.multiline_strings = "r#\"...\"# r\"...\" \"";
    d.annotation = "#[";
    d.flags = raven.R_LANGUAGE_CHAR_LITERALS | raven.R_LANGUAGE_NESTED_COMMENTS;
    rvn_language_add(&d);

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "JSON";
    d.extensions = "json;jsonc";
    d.constants = "true false null";
    d.line_comment = "//";
    d.block_comment_start = "/*";
    d.block_comment_end = "*/";
    d.string_quotes = "\"";
    rvn_language_add(&d);

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "CSS";
    d.extensions = "css;scss;less";
    d.keywords = "inherit initial unset revert auto none normal bold italic solid dashed dotted block inline flex grid absolute " ++
        "relative fixed sticky hidden visible center left right top bottom transparent currentColor";
    d.block_comment_start = "/*";
    d.block_comment_end = "*/";
    d.string_quotes = "\"'";
    d.flags = raven.R_LANGUAGE_STYLE_SHEET;
    rvn_language_add(&d);

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "XML";
    d.extensions = "xml;xaml;svg;ui;xsd;xsl;plist;csproj;vcxproj";
    d.block_comment_start = "<!--";
    d.block_comment_end = "-->";
    d.flags = raven.R_LANGUAGE_MARKUP;
    rvn_language_add(&d);

    d.name = "HTML";
    d.extensions = "html;htm;xhtml;vue";
    d.flags = raven.R_LANGUAGE_MARKUP | raven.R_LANGUAGE_EMBEDS | raven.R_LANGUAGE_IGNORE_CASE;
    rvn_language_add(&d);

    // an interface and its code in one file (ravenc): the code between <script> and </script> in the language of the file
    {
        const xml_code = [_]struct { name: [*c]const u8, extensions: [*c]const u8, script: [*c]const u8 }{
            .{ .name = "XMLC", .extensions = "xmlc", .script = "C" },
            .{ .name = "XMLC++", .extensions = "xmlc++;xmlcpp", .script = "C++" },
            .{ .name = "XMLRS", .extensions = "xmlrs", .script = "Rust" },
            .{ .name = "XMLPY", .extensions = "xmlpy", .script = "Python" },
            .{ .name = "XMLCS", .extensions = "xmlcs", .script = "C#" },
            .{ .name = "XMLGO", .extensions = "xmlgo", .script = "Go" },
            .{ .name = "XMLZIG", .extensions = "xmlzig", .script = "Zig" },
            .{ .name = "XMLLUA", .extensions = "xmllua", .script = "Lua" },
        };
        var k: usize = 0;
        while (k < xml_code.len) : (k += 1) {
            d.name = xml_code[k].name;
            d.extensions = xml_code[k].extensions;
            d.flags = raven.R_LANGUAGE_MARKUP | raven.R_LANGUAGE_EMBEDS;
            d.script_language = xml_code[k].script;
            rvn_language_add(&d);
        }
        d.script_language = null;
    }

    d = std.mem.zeroes(raven.RLanguageDesc);
    d.name = "Markdown";
    d.extensions = "md;markdown;mdown;mkd";
    d.block_comment_start = "<!--";
    d.block_comment_end = "-->";
    d.flags = raven.R_LANGUAGE_FORMATTED_TEXT;
    rvn_language_add(&d);
}

export fn rvn_languages_shutdown() void {
    var i: u32 = 0;
    while (i < g_languages.count) : (i += 1) rvn_language_free(g_languages.items[i]);
    i = 0;
    while (i < g_languages.retired_count) : (i += 1) rvn_language_free(g_languages.retired[i]);
    base.rvn_free(@ptrCast(g_languages.items));
    base.rvn_free(@ptrCast(g_languages.retired));
    g_languages = std.mem.zeroes(languages_t);
}

/// Does a list "c;h;inl" hold an extension?
fn rvn_language_has_extension(list_in: [*c]const u8, extension: [*c]const u8) bool {
    const length = libc.strlen(extension);
    if (list_in == null or length == 0) return false;
    var list = list_in;
    while (list[0] != 0) {
        const item = libc.strcspn(list, ";, ");
        if (item == length and base.rvn_strnicmp(list, extension, length) == 0) return true;
        list += item;
        while (list[0] == ';' or list[0] == ',' or list[0] == ' ') list += 1;
    }
    return false;
}

export fn rvn_language_find(name_in: [*c]const u8) [*c]const rvn_language_t {
    // other names people give to the built-in languages
    const aliases = [_]struct { alias: [*c]const u8, name: [*c]const u8 }{
        .{ .alias = "Cpp", .name = "C++" },
        .{ .alias = "CSharp", .name = "C#" },
        .{ .alias = "JS", .name = "JavaScript" },
        .{ .alias = "TS", .name = "TypeScript" },
        .{ .alias = "Shader", .name = "GLSL" },
        .{ .alias = "HLSL", .name = "GLSL" },
    };
    var name = name_in;
    var i: u32 = 0;
    if (name == null or name[0] == 0 or base.rvn_stricmp(name, "None") == 0) return null;
    rvn_languages_built_in();
    while (i < aliases.len) : (i += 1) {
        if (base.rvn_stricmp(name, aliases[i].alias) == 0) name = aliases[i].name;
    }
    i = 0;
    while (i < g_languages.count) : (i += 1) {
        if (base.rvn_stricmp(g_languages.items[i].*.desc.name, name) == 0) return g_languages.items[i];
    }
    // "py", "rs": the extension of its files names a language too
    i = 0;
    while (i < g_languages.count) : (i += 1) {
        if (rvn_language_has_extension(g_languages.items[i].*.desc.extensions, name)) return g_languages.items[i];
    }
    return null;
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rlanguage_register(desc: [*c]const raven.RLanguageDesc) c_int {
    if (ext.rvn_api_check("Rlanguage_register") == 0) return raven.R_FALSE;
    if (desc == null or desc.*.name == null or desc.*.name[0] == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rlanguage_register: a language needs a name");
        return raven.R_FALSE;
    }
    rvn_languages_built_in();
    rvn_language_add(desc);
    ext.rvn_repaint_all_windows();
    return raven.R_TRUE;
}

export fn Rlanguage_get(name: [*c]const u8, desc: [*c]raven.RLanguageDesc) c_int {
    if (desc != null) desc.* = std.mem.zeroes(raven.RLanguageDesc);
    if (ext.g_rvn.initialized == 0 or desc == null) return raven.R_FALSE;
    const language = rvn_language_find(name);
    if (language == null) return raven.R_FALSE;
    desc.* = language.*.desc;
    return raven.R_TRUE;
}

export fn Rlanguage_get_count() c_int {
    if (ext.g_rvn.initialized == 0) return 0;
    rvn_languages_built_in();
    return @intCast(g_languages.count);
}

export fn Rlanguage_get_name(index: c_int) [*c]const u8 {
    if (ext.g_rvn.initialized == 0) return null;
    rvn_languages_built_in();
    if (index < 0 or index >= @as(c_int, @intCast(g_languages.count))) return null;
    return g_languages.items[@intCast(index)].*.desc.name;
}

export fn Rlanguage_for_file(path: [*c]const u8) [*c]const u8 {
    var dot: [*c]const u8 = undefined;
    var cursor: [*c]const u8 = undefined;
    var i: u32 = 0;
    if (ext.g_rvn.initialized == 0 or path == null) return null;
    rvn_languages_built_in();
    dot = null;
    cursor = path;
    while (cursor[0] != 0) : (cursor += 1) {
        if (cursor[0] == '.') {
            dot = cursor;
        } else if (cursor[0] == '/' or cursor[0] == '\\') {
            dot = null;
        }
    }
    if (dot == null or dot[1] == 0) return null;
    while (i < g_languages.count) : (i += 1) {
        if (rvn_language_has_extension(g_languages.items[i].*.desc.extensions, dot + 1)) return g_languages.items[i].*.desc.name;
    }
    return null;
}
