// Translated to Zig from vendor/raven/tests/test_locale.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - tests/test_locale.c
// Translations from CSV tables, plurals, @keys in XML, right to left layouts
// and the accessibility settings (text scale, high contrast, colour filters,
// names and roles for the screen readers).

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

const g_csv =
    "\xEF\xBB\xBFkey,en,fr,ar\n" ++
    "# a comment\n" ++
    "menu.file,File,Fichier,\xD9\x85\xD9\x84\xD9\x81\n" ++
    "greeting,\"Hello, {0}!\",\"Bonjour, {0} !\",\n" ++
    "quote,\"Say \"\"hi\"\"\",\"Dis \"\"salut\"\"\",\n" ++
    "files.one,{n} file,{n} fichier,\n" ++
    "files.other,{n} files,{n} fichiers,\n" ++
    "only.en,English only,,\n";

var g_changes: c_int = 0;
fn on_changed(language: [*c]const u8, user: ?*anyopaque) callconv(.c) void {
    _ = language;
    _ = user;
    g_changes += 1;
}

fn test_tables() void {
    var args = [1][*c]const u8{"Ada"};
    // sizeof(g_csv) - 1: the length of the text without its terminating zero
    t.CHECK(@src(), raven.Rlocale_load_csv_from_memory(g_csv, g_csv.len) == 6, "Rlocale_load_csv_from_memory(g_csv, sizeof(g_csv) - 1) == 6");
    t.CHECK(@src(), raven.Rlocale_get_language_count() == 3, "Rlocale_get_language_count() == 3");
    t.CHECK_STR(@src(), raven.Rlocale_get_language_at(1), "fr", "Rlocale_get_language_at(1)");
    raven.Rlocale_set_changed_callback(on_changed, null);

    t.CHECK(@src(), raven.Rlocale_set_language("en") != 0, "Rlocale_set_language(\"en\")");
    t.CHECK_STR(@src(), raven.Rtr("menu.file"), "File", "Rtr(\"menu.file\")");
    t.CHECK_STR(@src(), raven.Rtr_format("greeting", &args, 1), "Hello, Ada!", "Rtr_format(\"greeting\", args, 1)");
    t.CHECK_STR(@src(), raven.Rtr("quote"), "Say \"hi\"", "Rtr(\"quote\")");
    t.CHECK_STR(@src(), raven.Rtr_plural("files", 1), "1 file", "Rtr_plural(\"files\", 1)");
    t.CHECK_STR(@src(), raven.Rtr_plural("files", 3), "3 files", "Rtr_plural(\"files\", 3)");
    t.CHECK_STR(@src(), raven.Rtr("missing.key"), "missing.key", "Rtr(\"missing.key\")");
    t.CHECK(@src(), raven.Rtr_exists("missing.key") == 0, "!Rtr_exists(\"missing.key\")");

    t.CHECK(@src(), raven.Rlocale_set_language("fr") != 0, "Rlocale_set_language(\"fr\")");
    t.CHECK(@src(), g_changes >= 2, "g_changes >= 2");
    t.CHECK_STR(@src(), raven.Rtr("menu.file"), "Fichier", "Rtr(\"menu.file\")");
    t.CHECK_STR(@src(), raven.Rtr_format("greeting", &args, 1), "Bonjour, Ada !", "Rtr_format(\"greeting\", args, 1)");
    // French: 0 and 1 are singular
    t.CHECK_STR(@src(), raven.Rtr_plural("files", 0), "0 fichier", "Rtr_plural(\"files\", 0)");
    t.CHECK_STR(@src(), raven.Rtr_plural("files", 2), "2 fichiers", "Rtr_plural(\"files\", 2)");
    // falls back to the first column
    t.CHECK_STR(@src(), raven.Rtr("only.en"), "English only", "Rtr(\"only.en\")");
    t.CHECK(@src(), raven.Rlocale_is_rtl() == 0, "!Rlocale_is_rtl()");

    t.CHECK(@src(), raven.Rlocale_set_language("ar") != 0, "Rlocale_set_language(\"ar\")");
    t.CHECK(@src(), raven.Rlocale_is_rtl() != 0, "Rlocale_is_rtl()");
    t.CHECK_STR(@src(), raven.Rtr("menu.file"), "\xD9\x85\xD9\x84\xD9\x81", "Rtr(\"menu.file\")");
    _ = raven.Rlocale_set_language("en");
    raven.Rlocale_set_changed_callback(null, null);
}

fn test_xml_keys() void {
    const xml: [*c]const u8 =
        "<Window Title=\"@menu.file\" Width=\"300\" Height=\"100\"><HBox>" ++
        "<Button Name=\"b\" Text=\"@menu.file\"/><Label Name=\"l\" Text=\"@@home\"/>" ++
        "</HBox></Window>";
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    const button = raven.Rwidget_find(window, "b");
    t.CHECK_STR(@src(), raven.Rwidget_get_accessible_name(button), "File", "Rwidget_get_accessible_name(button)");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(raven.Rwidget_find(window, "l")), "@home", "Rlabel_get_text(Rwidget_find(window, \"l\"))");
    _ = raven.Rlocale_set_language("fr");
    t.CHECK_STR(@src(), raven.Rwidget_get_accessible_name(button), "Fichier", "Rwidget_get_accessible_name(button)");
    raven.Rwidget_set_text_key(button, "Text", "only.en");
    t.CHECK_STR(@src(), raven.Rwidget_get_accessible_name(button), "English only", "Rwidget_get_accessible_name(button)");
    _ = raven.Rlocale_set_language("en");
    raven.Rwindow_destroy(window);
}

fn test_direction() void {
    const xml: [*c]const u8 =
        "<Window Width=\"300\" Height=\"100\"><HBox>" ++
        "<Button Name=\"a\" Width=\"100\" Text=\"A\"/><Button Name=\"b\" Width=\"100\" Text=\"B\"/>" ++
        "</HBox></Window>";
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    var ax: f32 = undefined;
    var ay: f32 = undefined;
    var aw: f32 = undefined;
    var ah: f32 = undefined;
    var bx: f32 = undefined;
    var by: f32 = undefined;
    var bw: f32 = undefined;
    var bh: f32 = undefined;
    raven.Rset_layout_direction(raven.R_DIRECTION_LTR);
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(raven.Rwidget_find(window, "a"), &ax, &ay, &aw, &ah);
    raven.Rwidget_get_rect(raven.Rwidget_find(window, "b"), &bx, &by, &bw, &bh);
    t.CHECK(@src(), ax < bx, "ax < bx");
    // right to left: the first child is on the right
    raven.Rset_layout_direction(raven.R_DIRECTION_RTL);
    t.CHECK(@src(), raven.Rget_layout_direction() == raven.R_DIRECTION_RTL, "Rget_layout_direction() == R_DIRECTION_RTL");
    _ = raven.Rdraw_frame();
    raven.Rwidget_get_rect(raven.Rwidget_find(window, "a"), &ax, &ay, &aw, &ah);
    raven.Rwidget_get_rect(raven.Rwidget_find(window, "b"), &bx, &by, &bw, &bh);
    t.CHECK(@src(), ax > bx, "ax > bx");
    t.CHECK_NEAR(@src(), ax + aw, 300.0, "ax + aw");
    raven.Rset_layout_direction(raven.R_DIRECTION_AUTO);
    raven.Rwindow_destroy(window);
}

fn test_accessibility() void {
    const xml: [*c]const u8 =
        "<Window Title=\"Login\" Width=\"300\" Height=\"200\"><VBox>" ++
        "<Button Name=\"b\" Text=\"Sign in\"/><Button Name=\"icon\" AccessibleName=\"Close\"/>" ++
        "</VBox></Window>";
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    const button = raven.Rwidget_find(window, "b");
    t.CHECK(@src(), raven.Rwidget_get_accessible_role(button) == raven.R_ROLE_BUTTON, "Rwidget_get_accessible_role(button) == R_ROLE_BUTTON");
    t.CHECK_STR(@src(), raven.Rwidget_get_accessible_name(button), "Sign in", "Rwidget_get_accessible_name(button)");
    t.CHECK_STR(@src(), raven.Rwidget_get_accessible_name(raven.Rwidget_find(window, "icon")), "Close", "Rwidget_get_accessible_name(Rwidget_find(window, \"icon\"))");
    raven.Rwidget_set_accessible_name(button, "Log in");
    t.CHECK_STR(@src(), raven.Rwidget_get_accessible_name(button), "Log in", "Rwidget_get_accessible_name(button)");
    raven.Rwidget_set_accessible_role(button, raven.R_ROLE_LINK);
    t.CHECK(@src(), raven.Rwidget_get_accessible_role(button) == raven.R_ROLE_LINK, "Rwidget_get_accessible_role(button) == R_ROLE_LINK");
    // without a screen reader running, an announcement is harmless
    raven.Raccessibility_announce("Saved", raven.R_FALSE);

    raven.Raccessibility_set_text_scale(1.5);
    t.CHECK_NEAR(@src(), raven.Raccessibility_get_text_scale(), 1.5, "Raccessibility_get_text_scale()");
    _ = raven.Rdraw_frame();
    raven.Raccessibility_set_text_scale(1.0);
    raven.Raccessibility_set_high_contrast(raven.R_TRUE);
    t.CHECK(@src(), raven.Raccessibility_get_high_contrast() != 0, "Raccessibility_get_high_contrast()");
    _ = raven.Rdraw_frame();
    raven.Raccessibility_set_high_contrast(raven.R_FALSE);
    raven.Raccessibility_set_color_filter(raven.R_COLOR_FILTER_DEUTERANOPIA);
    t.CHECK(@src(), raven.Raccessibility_get_color_filter() == raven.R_COLOR_FILTER_DEUTERANOPIA, "Raccessibility_get_color_filter() == R_COLOR_FILTER_DEUTERANOPIA");
    _ = raven.Rdraw_frame();
    raven.Raccessibility_set_color_filter(raven.R_COLOR_FILTER_NONE);
    raven.Rwindow_destroy(window);
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("test_locale: cannot initialize Raven\n");
        return 1;
    }
    t.RUN(test_tables, "test_tables");
    t.RUN(test_xml_keys, "test_xml_keys");
    t.RUN(test_direction, "test_direction");
    t.RUN(test_accessibility, "test_accessibility");
    raven.Rlocale_clear();
    raven.Rshutdown();
    return t.test_report("test_locale");
}
