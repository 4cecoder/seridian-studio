// Translated to Zig from vendor/raven/tests/test_markdown.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - formatted text: Markdown in labels and in the text editor,
// and the styles of the fonts they use.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

var g_links: c_int = 0;
var g_link: [256]u8 = std.mem.zeroes([256]u8);
var g_actions: c_int = 0;
var g_action: [64]u8 = std.mem.zeroes([64]u8);

fn on_link(label: raven.Rid, url: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = label;
    _ = user_data;
    g_links += 1;
    _ = t.snprintf(&g_link, g_link.len, "%s", url);
}

fn on_action(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    g_actions += 1;
    _ = t.snprintf(&g_action, g_action.len, "%s", action);
}

var g_window: raven.Rid = 0;

// A Markdown label alone in a window 400 wide, laid out.
fn markdown_label(text: [*c]const u8) raven.Rid {
    const label = raven.Rlabel_create(text);
    const box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    raven.Rlabel_set_markdown(label, raven.R_TRUE);
    raven.Rslot_set_valign(label, raven.R_VALIGN_TOP);
    _ = raven.Rwidget_add_child(box, label);
    raven.Rwindow_set_content(g_window, box);
    _ = raven.Rdraw_frame();
    return label;
}

fn plain(text: [*c]const u8) [*c]const u8 {
    return raven.Rlabel_get_plain_text(markdown_label(text));
}

fn height_of(widget: raven.Rid) f32 {
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;
    raven.Rwidget_get_rect(widget, &x, &y, &w, &h);
    return h;
}

fn test_inline() void {
    t.CHECK_STR(@src(), plain("Hello **strong** and *soft* text"), "Hello strong and soft text", "plain(\"Hello **strong** and *soft* text\")");
    t.CHECK_STR(@src(), plain("__strong__ _soft_ ***both*** ~~gone~~"), "strong soft both gone", "plain(\"__strong__ _soft_ ***both*** ~~gone~~\")");
    t.CHECK_STR(@src(), plain("a `code *not soft*` b"), "a code *not soft* b", "plain(\"a `code *not soft*` b\")");
    t.CHECK_STR(@src(), plain("``a ` tick``"), "a ` tick", "plain(\"``a ` tick``\")");
    // marks that open nothing are text
    t.CHECK_STR(@src(), plain("2 * 3 * 4 and snake_case_name and a * alone"), "2 * 3 * 4 and snake_case_name and a * alone", "plain(\"2 * 3 * 4 and snake_case_name and a * alone\")");
    t.CHECK_STR(@src(), plain("**never closed"), "**never closed", "plain(\"**never closed\")");
    t.CHECK_STR(@src(), plain("escaped \\*stars\\* and \\_bars\\_"), "escaped *stars* and _bars_", "plain(\"escaped \\\\*stars\\\\* and \\\\_bars\\\\_\")");
    t.CHECK_STR(@src(), plain("AT&amp;T &lt;tag&gt; &#65;&#x42; &copy; &unknown;"), "AT&T <tag> AB \xC2\xA9 &unknown;", "plain(\"AT&amp;T &lt;tag&gt; &#65;&#x42; &copy; &unknown;\")");
    // lines of a paragraph are one line; two spaces or a backslash break it
    t.CHECK_STR(@src(), plain("one\ntwo\n   three"), "one two three", "plain(\"one\\ntwo\\n   three\")");
    t.CHECK_STR(@src(), plain("one  \ntwo\\\nthree"), "one\ntwo\nthree", "plain(\"one  \\ntwo\\\\\\nthree\")");
    t.CHECK_STR(@src(), plain("a [link](https://example.com/a_b) b"), "a link b", "plain(\"a [link](https://example.com/a_b) b\")");
    t.CHECK_STR(@src(), plain("see <https://example.com> or https://example.org/x."), "see https://example.com or https://example.org/x.", "plain(\"see <https://example.com> or https://example.org/x.\")");
    t.CHECK_STR(@src(), plain("![picture of a bird](missing.png) in a line"), "picture of a bird in a line", "plain(\"![picture of a bird](missing.png) in a line\")");
    t.CHECK_STR(@src(), plain(""), "", "plain(\"\")");
    // not Markdown: the text as it is
    {
        const label = raven.Rlabel_create("**as is**");
        t.CHECK(@src(), raven.Rlabel_get_markdown(label) == 0, "!Rlabel_get_markdown(label)");
        t.CHECK_STR(@src(), raven.Rlabel_get_plain_text(label), "**as is**", "Rlabel_get_plain_text(label)");
        raven.Rwidget_destroy(label);
    }
}

fn test_blocks() void {
    var label: raven.Rid = undefined;

    t.CHECK_STR(@src(), plain("# Title\n\nText under it.\n\n## Second ##\nMore"), "Title\nText under it.\nSecond\nMore", "plain(\"# Title\\n\\nText under it.\\n\\n## Second ##\\nMore\")");
    t.CHECK_STR(@src(), plain("Title\n=====\n\nSub\n---\ntext"), "Title\nSub\ntext", "plain(\"Title\\n=====\\n\\nSub\\n---\\ntext\")");
    t.CHECK_STR(@src(), plain("- one\n- two\n  - inner\n- [x] done\n- [ ] todo\n\n1. first\n2. second"), "one\ntwo\ninner\ndone\ntodo\nfirst\nsecond", "plain(\"- one\\n- two\\n  - inner\\n- [x] done\\n- [ ] todo\\n\\n1. first\\n2. second\")");
    t.CHECK_STR(@src(), plain("> quoted *text*\n> on two lines\n\nafter"), "quoted text on two lines\nafter", "plain(\"> quoted *text*\\n> on two lines\\n\\nafter\")");
    t.CHECK_STR(@src(), plain("```c\nint a = 1;\n  indented();\n```\nafter"), "int a = 1;\n  indented();\nafter", "plain(\"```c\\nint a = 1;\\n  indented();\\n```\\nafter\")");
    t.CHECK_STR(@src(), plain("~~~\n``` not a fence\n~~~"), "``` not a fence", "plain(\"~~~\\n``` not a fence\\n~~~\")");
    t.CHECK_STR(@src(), plain("a\n\n---\n\nb"), "a\n\nb", "plain(\"a\\n\\n---\\n\\nb\")");
    t.CHECK_STR(@src(), plain("| A | B |\n|---|:-:|\n| 1 | **2** |\n| 3 | 4 |\n\nend"), "A\tB\n1\t2\n3\t4\nend", "plain(\"| A | B |\\n|---|:-:|\\n| 1 | **2** |\\n| 3 | 4 |\\n\\nend\")");
    // indented with the XML element it is written in
    t.CHECK_STR(@src(), plain("\n\t\t# Title\n\n\t\t- item\n\t\t  - inner\n\t"), "Title\nitem\ninner", "plain(\"\\n\\t\\t# Title\\n\\n\\t\\t- item\\n\\t\\t  - inner\\n\\t\")");

    // sizes: a title is taller than a line, a paragraph wraps on the width of the label
    label = markdown_label("one line");
    const one_line = height_of(label);
    t.CHECK(@src(), one_line > 10.0 and one_line < 30.0, "one_line > 10.0f && one_line < 30.0f");
    label = markdown_label("# Title");
    t.CHECK(@src(), height_of(label) > one_line * 1.4, "height_of(label) > one_line * 1.4f");
    label = markdown_label("word word word word word word word word word word word word word word word word word word word word word word word word word word word word");
    const h = height_of(label);
    t.CHECK(@src(), h > one_line * 1.8, "h > one_line * 1.8f");
    {
        var x: f32 = undefined;
        var y: f32 = undefined;
        var w: f32 = undefined;
        var hh: f32 = undefined;
        raven.Rwidget_get_rect(label, &x, &y, &w, &hh);
        t.CHECK(@src(), w <= 400.5, "w <= 400.5f");
    }
    // ... unless it was told not to
    raven.Rlabel_set_wrap(label, raven.R_FALSE);
    _ = raven.Rdraw_frame();
    t.CHECK_NEAR(@src(), height_of(label), one_line, "height_of(label)");
    label = markdown_label("a\n\nb\n\nc");
    t.CHECK(@src(), height_of(label) > one_line * 3.0, "height_of(label) > one_line * 3.0f");
    label = markdown_label("```\n1\n2\n3\n4\n```");
    t.CHECK(@src(), height_of(label) > one_line * 4.0, "height_of(label) > one_line * 4.0f");
    // the text changes: so does the layout
    raven.Rlabel_set_text(label, "short");
    _ = raven.Rdraw_frame();
    t.CHECK_NEAR(@src(), height_of(label), one_line, "height_of(label)");
    t.CHECK_STR(@src(), raven.Rlabel_get_plain_text(label), "short", "Rlabel_get_plain_text(label)");
    // turned off: the marks show again
    raven.Rlabel_set_text(label, "# T");
    raven.Rlabel_set_markdown(label, raven.R_FALSE);
    _ = raven.Rdraw_frame();
    t.CHECK_STR(@src(), raven.Rlabel_get_plain_text(label), "# T", "Rlabel_get_plain_text(label)");
    _ = raven.Rwidget_set_attribute(label, "Markdown", "true");
    t.CHECK(@src(), raven.Rlabel_get_markdown(label) != 0, "Rlabel_get_markdown(label)");
    t.CHECK_STR(@src(), raven.Rlabel_get_plain_text(label), "T", "Rlabel_get_plain_text(label)");

    // a long document, and odd ones, in every theme
    {
        const documents = [_][*c]const u8{
            "# T\n\n> - a\n> - b\n>\n> ```\n> code\n> ```\n\n| a |\n|---|\n\n1. x\n   continued\n\n   new paragraph\n2. y",
            "***\n___\n- \n-\n#\n####### seven\n|\n||\n|-|\n```",
            "[a](b) [c] (d) [e]() ![](x) <> < > <a@b.c> &; & &#; &#xZZ; \\",
            "* * *\n*a\n_\n__\n** **\n*** x ***\n`\n``\n~~~",
            "| a | b | c |\n|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 | 5 |",
            "deep\n- 1\n  - 2\n    - 3\n      - 4\n        - 5\n          - 6\n            - 7\n              - 8\n                - 9\n                  - 10",
            "> 1\n>> 2\n>>> 3\n>>>> 4\n>>>>> 5\n>>>>>> 6\n>>>>>>> 7\n>>>>>>>> 8\n>>>>>>>>> 9\n>>>>>>>>>> 10",
        };
        const themes = [_]raven.RTheme{ raven.R_THEME_DARK, raven.R_THEME_LIGHT, raven.R_THEME_GLASS_DARK, raven.R_THEME_GLASS_LIGHT };
        var d: usize = undefined;
        // (the C loop variable `t` is `t_`: in Zig it would shadow the harness import `t`)
        var t_: usize = undefined;
        t_ = 0;
        while (t_ < themes.len) : (t_ += 1) {
            raven.Rtheme_apply(themes[t_]);
            d = 0;
            while (d < documents.len) : (d += 1) {
                label = markdown_label(documents[d]);
                t.CHECK(@src(), height_of(label) > 0.0, "height_of(label) > 0.0f");
                raven.Rwindow_set_size(g_window, 120, 300);
                _ = raven.Rdraw_frame();
                raven.Rwindow_set_size(g_window, 400, 300);
                _ = raven.Rdraw_frame();
            }
        }
        raven.Rtheme_apply(raven.R_THEME_DARK);
    }
}

fn test_links() void {
    var label = markdown_label("Go to [the site](https://example.com/page) or [save](action:file.save), or stay.");
    var x: f32 = undefined;
    var y: f32 = undefined;
    var w: f32 = undefined;
    var h: f32 = undefined;

    raven.Rwidget_get_rect(label, &x, &y, &w, &h);
    raven.Rlabel_set_link_callback(label, on_link, null);
    g_links = 0;
    // the first link starts after "Go to ": about 40 units in
    raven.Rwindow_inject_mouse_move(g_window, x + 4.0, y + h * 0.5);
    t.CHECK(@src(), raven.Rwindow_get_hovered_widget(g_window) == label, "Rwindow_get_hovered_widget(g_window) == label");
    t.test_click_at(g_window, x + 4.0, y + h * 0.5);
    t.CHECK(@src(), g_links == 0, "g_links == 0");
    {
        // walks along the line until a click follows a link
        var at: f32 = undefined;
        at = 10.0;
        while (at < 200.0 and g_links == 0) : (at += 6.0) t.test_click_at(g_window, x + at, y + h * 0.5);
        t.CHECK(@src(), g_links == 1, "g_links == 1");
        t.CHECK_STR(@src(), &g_link, "https://example.com/page", "g_link");
        while (at < 380.0 and t.strcmp(&g_link, "action:file.save") != 0) : (at += 6.0) t.test_click_at(g_window, x + at, y + h * 0.5);
        t.CHECK_STR(@src(), &g_link, "action:file.save", "g_link");
        // without a callback, an action link fires its action
        raven.Rlabel_set_link_callback(label, null, null);
        raven.Raction_bind("file.save", on_action, null);
        g_actions = 0;
        t.test_click_at(g_window, x + at - 6.0, y + h * 0.5);
        t.CHECK(@src(), g_actions == 1, "g_actions == 1");
        t.CHECK_STR(@src(), &g_action, "file.save", "g_action");
        raven.Raction_unbind("file.save");
    }
    // a label without links lets the mouse through, as labels do
    label = markdown_label("no link *here*");
    raven.Rwidget_get_rect(label, &x, &y, &w, &h);
    raven.Rwindow_inject_mouse_move(g_window, x + 4.0, y + h * 0.5);
    t.CHECK(@src(), raven.Rwindow_get_hovered_widget(g_window) != label, "Rwindow_get_hovered_widget(g_window) != label");
}

fn test_fonts() void {
    const font = raven.Rfont_get_default();
    var bold = raven.Rfont_get_variant(font, raven.R_FONT_BOLD);
    const italic = raven.Rfont_get_variant(font, raven.R_FONT_ITALIC);
    const both = raven.Rfont_get_variant(font, raven.R_FONT_BOLD_ITALIC);
    var regular_width: f32 = undefined;
    var bold_width: f32 = undefined;
    var height: f32 = undefined;
    var bold_height: f32 = undefined;

    t.CHECK(@src(), raven.Rfont_get_variant(font, raven.R_FONT_REGULAR) == font, "Rfont_get_variant(font, R_FONT_REGULAR) == font");
    t.CHECK(@src(), raven.Rfont_is_valid(bold) != 0 and raven.Rfont_is_valid(italic) != 0 and raven.Rfont_is_valid(both) != 0, "Rfont_is_valid(bold) && Rfont_is_valid(italic) && Rfont_is_valid(both)");
    t.CHECK(@src(), bold != font and italic != font and both != bold and both != italic, "bold != font && italic != font && both != bold && both != italic");
    // asked again: the same ones; the bold of the italic is the bold italic
    t.CHECK(@src(), raven.Rfont_get_variant(font, raven.R_FONT_BOLD) == bold, "Rfont_get_variant(font, R_FONT_BOLD) == bold");
    t.CHECK(@src(), raven.Rfont_get_variant(italic, raven.R_FONT_BOLD) == both, "Rfont_get_variant(italic, R_FONT_BOLD) == both");
    t.CHECK(@src(), raven.Rfont_get_variant(bold, raven.R_FONT_REGULAR) == bold, "Rfont_get_variant(bold, R_FONT_REGULAR) == bold");
    // the styles Raven derives take the same room: text does not move when its style changes
    raven.Rfont_measure_text(font, 14.0, "The quick brown fox", &regular_width, &height);
    raven.Rfont_measure_text(bold, 14.0, "The quick brown fox", &bold_width, &bold_height);
    t.CHECK_NEAR(@src(), regular_width, bold_width, "regular_width");
    t.CHECK_NEAR(@src(), height, bold_height, "height");

    // a real font for a style
    raven.Rfont_set_variant(font, raven.R_FONT_BOLD, raven.Rfont_get_monospace());
    t.CHECK(@src(), raven.Rfont_get_variant(font, raven.R_FONT_BOLD) == raven.Rfont_get_monospace(), "Rfont_get_variant(font, R_FONT_BOLD) == Rfont_get_monospace()");
    t.CHECK(@src(), raven.Rfont_is_valid(bold) == 0, "!Rfont_is_valid(bold)");
    raven.Rfont_set_variant(font, raven.R_FONT_BOLD, raven.R_INVALID_ID);
    bold = raven.Rfont_get_variant(font, raven.R_FONT_BOLD);
    t.CHECK(@src(), raven.Rfont_is_valid(bold) != 0 and bold != raven.Rfont_get_monospace(), "Rfont_is_valid(bold) && bold != Rfont_get_monospace()");

    t.EXPECT_ERRORS_BEGIN();
    raven.Rfont_destroy(italic);
    raven.Rfont_set_variant(font, raven.R_FONT_REGULAR, bold);
    raven.Rfont_set_variant(font, raven.R_FONT_BOLD, font);
    raven.Rfont_set_variant(italic, raven.R_FONT_BOLD, font);
    t.CHECK(@src(), raven.Rfont_get_variant(font, @as(raven.RFontStyle, 0)) == raven.R_INVALID_ID, "Rfont_get_variant(font, (RFontStyle)0) == R_INVALID_ID");
    t.EXPECT_ERRORS_END(@src(), 5, "g_test_errors >= (5)");
    t.CHECK(@src(), raven.Rfont_is_valid(italic) != 0, "Rfont_is_valid(italic)");
}

fn test_editor() void {
    const editor = raven.Rwidget_create(raven.R_WIDGET_TEXT_EDITOR);
    raven.Rwindow_set_content(g_window, editor);
    t.CHECK(@src(), raven.Rtext_editor_get_markdown(editor) == 0, "!Rtext_editor_get_markdown(editor)");
    raven.Rtext_editor_set_markdown(editor, raven.R_TRUE);
    t.CHECK(@src(), raven.Rtext_editor_get_markdown(editor) != 0, "Rtext_editor_get_markdown(editor)");
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(editor), "Markdown", "Rtext_editor_get_language(editor)");
    t.CHECK_STR(@src(), raven.Rlanguage_for_file("notes/README.md"), "Markdown", "Rlanguage_for_file(\"notes/README.md\")");
    raven.Rtext_editor_set_text(editor, "# Title\n" ++
        "plain **strong** and *soft* `code` [link](url) ~~gone~~ 2 * 3\n" ++
        "- item\n" ++
        "```c\n" ++
        "int *a = *b;\n" ++
        "```\n" ++
        "after *the* block\n");
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 0, 0) == raven.R_TOKEN_HEADING, "Rtext_editor_get_token(editor, 0, 0) == R_TOKEN_HEADING");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 0, 4) == raven.R_TOKEN_HEADING, "Rtext_editor_get_token(editor, 0, 4) == R_TOKEN_HEADING");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 0) == raven.R_TOKEN_TEXT, "Rtext_editor_get_token(editor, 1, 0) == R_TOKEN_TEXT");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 6) == raven.R_TOKEN_STRONG, "Rtext_editor_get_token(editor, 1, 6) == R_TOKEN_STRONG");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 10) == raven.R_TOKEN_STRONG, "Rtext_editor_get_token(editor, 1, 10) == R_TOKEN_STRONG");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 16) == raven.R_TOKEN_TEXT, "Rtext_editor_get_token(editor, 1, 16) == R_TOKEN_TEXT");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 21) == raven.R_TOKEN_EMPHASIS, "Rtext_editor_get_token(editor, 1, 21) == R_TOKEN_EMPHASIS");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 28) == raven.R_TOKEN_STRING, "Rtext_editor_get_token(editor, 1, 28) == R_TOKEN_STRING");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 35) == raven.R_TOKEN_LINK, "Rtext_editor_get_token(editor, 1, 35) == R_TOKEN_LINK");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 47) == raven.R_TOKEN_COMMENT, "Rtext_editor_get_token(editor, 1, 47) == R_TOKEN_COMMENT");
    // a star alone is a star
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 58) == raven.R_TOKEN_TEXT, "Rtext_editor_get_token(editor, 1, 58) == R_TOKEN_TEXT");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 2, 0) == raven.R_TOKEN_KEYWORD, "Rtext_editor_get_token(editor, 2, 0) == R_TOKEN_KEYWORD");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 2, 3) == raven.R_TOKEN_TEXT, "Rtext_editor_get_token(editor, 2, 3) == R_TOKEN_TEXT");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 3, 0) == raven.R_TOKEN_PUNCTUATION, "Rtext_editor_get_token(editor, 3, 0) == R_TOKEN_PUNCTUATION");
    // inside a block of code nothing is formatted
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 4, 5) == raven.R_TOKEN_STRING, "Rtext_editor_get_token(editor, 4, 5) == R_TOKEN_STRING");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 5, 1) == raven.R_TOKEN_PUNCTUATION, "Rtext_editor_get_token(editor, 5, 1) == R_TOKEN_PUNCTUATION");
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 6, 7) == raven.R_TOKEN_EMPHASIS, "Rtext_editor_get_token(editor, 6, 7) == R_TOKEN_EMPHASIS");
    // typing a fence changes what follows
    raven.Rtext_editor_set_text(editor, "```\n*a*\n");
    _ = raven.Rdraw_frame();
    t.CHECK(@src(), raven.Rtext_editor_get_token(editor, 1, 1) == raven.R_TOKEN_STRING, "Rtext_editor_get_token(editor, 1, 1) == R_TOKEN_STRING");
    raven.Rtext_editor_set_markdown(editor, raven.R_FALSE);
    t.CHECK_STR(@src(), raven.Rtext_editor_get_language(editor), "", "Rtext_editor_get_language(editor)");
    _ = raven.Rwidget_set_attribute(editor, "Markdown", "true");
    t.CHECK(@src(), raven.Rtext_editor_get_markdown(editor) != 0, "Rtext_editor_get_markdown(editor)");
    _ = raven.Rdraw_frame();
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("test_markdown: cannot initialize Raven\n");
        return 1;
    }
    g_window = raven.Rwindow_create("Markdown", 400, 300, raven.R_WINDOW_DEFAULT);
    t.RUN(test_inline, "test_inline");
    t.RUN(test_blocks, "test_blocks");
    t.RUN(test_links, "test_links");
    t.RUN(test_fonts, "test_fonts");
    t.RUN(test_editor, "test_editor");
    raven.Rwindow_destroy(g_window);
    raven.Rshutdown();
    return t.test_report("test_markdown");
}
