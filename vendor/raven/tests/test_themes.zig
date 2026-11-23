// Translated to Zig from vendor/raven/tests/test_themes.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - themes (styles, classes, themes of parts of a window, theme
// files) and live reload of the interfaces and themes read from files.

const std = @import("std");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

// <stdlib.h>
extern "c" fn getenv(name: [*c]const u8) [*c]u8;
// <stdio.h>
extern "c" fn remove(path: [*c]const u8) c_int;

var g_reloads: c_int = 0;
var g_reload_ok: c_int = 0;
var g_reload_path: [512]u8 = std.mem.zeroes([512]u8);

fn on_reload(path: [*c]const u8, ok: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    g_reloads += 1;
    g_reload_ok = ok;
    _ = t.snprintf(&g_reload_path, g_reload_path.len, "%s", path);
}

var g_clicks: c_int = 0;

fn on_click(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    g_clicks += 1;
}

// The color a widget uses for a role, as 0xRRGGBBAA.
fn color_of(widget: raven.Rid, role: raven.RColorRole) c_uint {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    raven.Rwidget_get_color(widget, role, &r, &g, &b, &a);
    return (@as(c_uint, @intFromFloat(r * 255.0 + 0.5)) << 24) | (@as(c_uint, @intFromFloat(g * 255.0 + 0.5)) << 16) | (@as(c_uint, @intFromFloat(b * 255.0 + 0.5)) << 8) | @as(c_uint, @intFromFloat(a * 255.0 + 0.5));
}

fn theme_color(role: raven.RColorRole) c_uint {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    raven.Rtheme_get_color(role, &r, &g, &b, &a);
    return (@as(c_uint, @intFromFloat(r * 255.0 + 0.5)) << 24) | (@as(c_uint, @intFromFloat(g * 255.0 + 0.5)) << 16) | (@as(c_uint, @intFromFloat(b * 255.0 + 0.5)) << 8) | @as(c_uint, @intFromFloat(a * 255.0 + 0.5));
}

fn temp_dir() [*c]const u8 {
    const temp: [*c]const u8 = if (getenv("TMPDIR") != null) getenv("TMPDIR") else (if (getenv("TEMP") != null) getenv("TEMP") else "/tmp");
    return temp;
}

fn write_text(path: [*c]const u8, text: [*c]const u8) void {
    t.CHECK(@src(), raven.Rfile_write(path, text, t.strlen(text)) != 0, "Rfile_write(path, text, strlen(text))");
}

// ---------------------------------------------------------------------------
//  Styles and classes
// -------------------------------------------------------------------------

fn test_styles() void {
    const xml: [*c]const u8 =
        "<Window Width=\"400\" Height=\"300\"><VBox>" ++
        "<Button Name=\"plain\" Text=\"Plain\"/>" ++
        "<Button Name=\"danger\" Class=\"danger\" Text=\"Delete\"/>" ++
        "<Button Name=\"both\" Class=\"large danger\" Text=\"Delete all\"/>" ++
        "<Label Name=\"label\" Class=\"danger\">Careful</Label>" ++
        "<Button Name=\"own\" Class=\"danger\" Color.Accent=\"#00FF00\" Text=\"Mine\"/>" ++
        "</VBox></Window>";
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    const plain = raven.Rwidget_find(window, "plain");
    const danger = raven.Rwidget_find(window, "danger");
    const both = raven.Rwidget_find(window, "both");
    const label = raven.Rwidget_find(window, "label");
    const own = raven.Rwidget_find(window, "own");
    const accent: c_uint = theme_color(raven.R_COLOR_ACCENT);
    var height: f32 = undefined;

    t.CHECK_STR(@src(), raven.Rtheme_get_name(), "Dark", "Rtheme_get_name()");
    t.CHECK_STR(@src(), raven.Rwidget_get_class(danger), "danger", "Rwidget_get_class(danger)");
    t.CHECK_STR(@src(), raven.Rwidget_get_class(plain), "", "Rwidget_get_class(plain)");
    t.CHECK(@src(), raven.Rwidget_has_class(both, "large") != 0 and raven.Rwidget_has_class(both, "danger") != 0 and raven.Rwidget_has_class(both, "dan") == 0, "Rwidget_has_class(both, \"large\") && Rwidget_has_class(both, \"danger\") && !Rwidget_has_class(both, \"dan\")");
    t.CHECK(@src(), color_of(danger, raven.R_COLOR_ACCENT) == accent, "color_of(danger, R_COLOR_ACCENT) == accent");

    // a class
    raven.Rtheme_set_style_color(null, "danger", raven.R_COLOR_ACCENT, 1.0, 0.0, 0.0, 1.0);
    t.CHECK(@src(), color_of(plain, raven.R_COLOR_ACCENT) == accent, "color_of(plain, R_COLOR_ACCENT) == accent");
    t.CHECK(@src(), color_of(danger, raven.R_COLOR_ACCENT) == 0xFF0000FF, "color_of(danger, R_COLOR_ACCENT) == 0xFF0000FFu");
    t.CHECK(@src(), color_of(both, raven.R_COLOR_ACCENT) == 0xFF0000FF, "color_of(both, R_COLOR_ACCENT) == 0xFF0000FFu");
    t.CHECK(@src(), color_of(label, raven.R_COLOR_ACCENT) == 0xFF0000FF, "color_of(label, R_COLOR_ACCENT) == 0xFF0000FFu");
    // the widget itself wins over the styles
    t.CHECK(@src(), color_of(own, raven.R_COLOR_ACCENT) == 0x00FF00FF, "color_of(own, R_COLOR_ACCENT) == 0x00FF00FFu");
    // the theme itself is untouched
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT) == accent, "theme_color(R_COLOR_ACCENT) == accent");

    // a type of widget
    height = raven.Rwidget_get_metric(plain, raven.R_METRIC_CONTROL_HEIGHT);
    raven.Rtheme_set_style_metric("Button", null, raven.R_METRIC_CONTROL_HEIGHT, 40.0);
    _ = raven.Rdraw_frame();
    t.CHECK_NEAR(@src(), raven.Rwidget_get_metric(plain, raven.R_METRIC_CONTROL_HEIGHT), 40.0, "Rwidget_get_metric(plain, R_METRIC_CONTROL_HEIGHT)");
    t.CHECK_NEAR(@src(), raven.Rwidget_get_metric(label, raven.R_METRIC_CONTROL_HEIGHT), height, "Rwidget_get_metric(label, R_METRIC_CONTROL_HEIGHT)");
    {
        var x: f32 = undefined;
        var y: f32 = undefined;
        var w: f32 = undefined;
        var h: f32 = undefined;
        raven.Rwidget_get_rect(plain, &x, &y, &w, &h);
        t.CHECK_NEAR(@src(), h, 40.0, "h");
    }

    // a type and a class together win over each alone, whatever the order they were given in
    raven.Rtheme_set_style_color("Button", "danger", raven.R_COLOR_ACCENT, 0.0, 0.0, 1.0, 1.0);
    raven.Rtheme_set_style_color("Button", null, raven.R_COLOR_ACCENT, 1.0, 1.0, 0.0, 1.0);
    t.CHECK(@src(), color_of(danger, raven.R_COLOR_ACCENT) == 0x0000FFFF, "color_of(danger, R_COLOR_ACCENT) == 0x0000FFFFu");
    t.CHECK(@src(), color_of(plain, raven.R_COLOR_ACCENT) == 0xFFFF00FF, "color_of(plain, R_COLOR_ACCENT) == 0xFFFF00FFu");
    t.CHECK(@src(), color_of(label, raven.R_COLOR_ACCENT) == 0xFF0000FF, "color_of(label, R_COLOR_ACCENT) == 0xFF0000FFu");
    raven.Rtheme_set_style_material(null, "large", raven.R_MATERIAL_GLASS);
    t.CHECK(@src(), raven.Rwidget_get_material(both) == raven.R_MATERIAL_GLASS, "Rwidget_get_material(both) == R_MATERIAL_GLASS");
    t.CHECK(@src(), raven.Rwidget_get_material(plain) == raven.R_MATERIAL_SOLID, "Rwidget_get_material(plain) == R_MATERIAL_SOLID");

    // classes change while the application runs
    raven.Rwidget_add_class(plain, "danger");
    t.CHECK(@src(), color_of(plain, raven.R_COLOR_ACCENT) == 0x0000FFFF, "color_of(plain, R_COLOR_ACCENT) == 0x0000FFFFu");
    raven.Rwidget_add_class(plain, "danger");
    t.CHECK_STR(@src(), raven.Rwidget_get_class(plain), "danger", "Rwidget_get_class(plain)");
    raven.Rwidget_add_class(plain, "wide");
    t.CHECK_STR(@src(), raven.Rwidget_get_class(plain), "danger wide", "Rwidget_get_class(plain)");
    raven.Rwidget_remove_class(plain, "danger");
    t.CHECK_STR(@src(), raven.Rwidget_get_class(plain), "wide", "Rwidget_get_class(plain)");
    t.CHECK(@src(), color_of(plain, raven.R_COLOR_ACCENT) == 0xFFFF00FF, "color_of(plain, R_COLOR_ACCENT) == 0xFFFF00FFu");
    raven.Rwidget_set_class(plain, null);
    t.CHECK_STR(@src(), raven.Rwidget_get_class(plain), "", "Rwidget_get_class(plain)");
    _ = raven.Rwidget_set_attribute(plain, "Class", "danger");
    t.CHECK(@src(), color_of(plain, raven.R_COLOR_ACCENT) == 0x0000FFFF, "color_of(plain, R_COLOR_ACCENT) == 0x0000FFFFu");

    raven.Rtheme_clear_styles();
    t.CHECK(@src(), color_of(danger, raven.R_COLOR_ACCENT) == accent, "color_of(danger, R_COLOR_ACCENT) == accent");
    t.CHECK_NEAR(@src(), raven.Rwidget_get_metric(plain, raven.R_METRIC_CONTROL_HEIGHT), height, "Rwidget_get_metric(plain, R_METRIC_CONTROL_HEIGHT)");
    t.CHECK(@src(), raven.Rwidget_get_material(both) == raven.R_MATERIAL_SOLID, "Rwidget_get_material(both) == R_MATERIAL_SOLID");

    // another theme forgets the styles
    raven.Rtheme_set_style_color(null, "danger", raven.R_COLOR_ACCENT, 1.0, 0.0, 0.0, 1.0);
    raven.Rtheme_apply(raven.R_THEME_LIGHT);
    t.CHECK_STR(@src(), raven.Rtheme_get_name(), "Light", "Rtheme_get_name()");
    t.CHECK(@src(), color_of(danger, raven.R_COLOR_ACCENT) == theme_color(raven.R_COLOR_ACCENT), "color_of(danger, R_COLOR_ACCENT) == theme_color(R_COLOR_ACCENT)");
    raven.Rtheme_apply(raven.R_THEME_DARK);

    t.EXPECT_ERRORS_BEGIN();
    raven.Rtheme_set_style_color("NoSuchWidget", null, raven.R_COLOR_ACCENT, 1.0, 0.0, 0.0, 1.0);
    raven.Rwidget_add_class(plain, "two words");
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  The accent, and the theme of a part of a window
// -------------------------------------------------------------------------

fn test_accent_and_scopes() void {
    const xml: [*c]const u8 =
        "<Window Width=\"400\" Height=\"300\"><HBox>" ++
        "<VBox Name=\"side\" Theme=\"Light\"><Button Name=\"in\" Text=\"In\"/><ComboBox Name=\"combo\"><Item>One</Item><Item>Two</Item></ComboBox>" ++
        "<VBox Name=\"back\" Theme=\"Dark\"><Label Name=\"deep\">Deep</Label></VBox></VBox>" ++
        "<Button Name=\"out\" Text=\"Out\"/>" ++
        "</HBox></Window>";
    // Rid window, in, out, deep, moved; (declared where they are assigned: each is assigned once)
    var dark_text: c_uint = undefined;
    var light_text: c_uint = undefined;

    raven.Rtheme_apply(raven.R_THEME_LIGHT);
    light_text = theme_color(raven.R_COLOR_TEXT);
    raven.Rtheme_apply(raven.R_THEME_DARK);
    dark_text = theme_color(raven.R_COLOR_TEXT);
    t.CHECK(@src(), dark_text != light_text, "dark_text != light_text");
    t.CHECK(@src(), raven.Rtheme_is_dark() != 0, "Rtheme_is_dark()");

    // the accent brings its shades along
    raven.Rtheme_set_accent(1.0, 0.5, 0.0);
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT) == 0xFF8000FF, "theme_color(R_COLOR_ACCENT) == 0xFF8000FFu");
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT_HOVERED) != 0xFF8000FF and theme_color(raven.R_COLOR_ACCENT_PRESSED) != 0xFF8000FF, "theme_color(R_COLOR_ACCENT_HOVERED) != 0xFF8000FFu && theme_color(R_COLOR_ACCENT_PRESSED) != 0xFF8000FFu");
    t.CHECK(@src(), theme_color(raven.R_COLOR_FOCUS) == 0xFF8000FF, "theme_color(R_COLOR_FOCUS) == 0xFF8000FFu");
    // (white would not be readable on a pale accent)
    raven.Rtheme_set_accent(1.0, 1.0, 0.4);
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT_TEXT) != 0xFFFFFFFF, "theme_color(R_COLOR_ACCENT_TEXT) != 0xFFFFFFFFu");
    raven.Rtheme_apply(raven.R_THEME_DARK);

    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    const in = raven.Rwidget_find(window, "in");
    const out = raven.Rwidget_find(window, "out");
    const deep = raven.Rwidget_find(window, "deep");
    t.CHECK_STR(@src(), raven.Rwidget_get_theme(out), "Dark", "Rwidget_get_theme(out)");
    t.CHECK_STR(@src(), raven.Rwidget_get_theme(in), "Light", "Rwidget_get_theme(in)");
    t.CHECK_STR(@src(), raven.Rwidget_get_theme(raven.Rwidget_find(window, "side")), "Light", "Rwidget_get_theme(Rwidget_find(window, \"side\"))");
    t.CHECK_STR(@src(), raven.Rwidget_get_theme(deep), "Dark", "Rwidget_get_theme(deep)");
    t.CHECK(@src(), color_of(out, raven.R_COLOR_TEXT) == dark_text, "color_of(out, R_COLOR_TEXT) == dark_text");
    t.CHECK(@src(), color_of(in, raven.R_COLOR_TEXT) == light_text, "color_of(in, R_COLOR_TEXT) == light_text");
    t.CHECK(@src(), color_of(deep, raven.R_COLOR_TEXT) == dark_text, "color_of(deep, R_COLOR_TEXT) == dark_text");

    // changing the theme of the application leaves the parts that have their own alone
    raven.Rtheme_apply(raven.R_THEME_GLASS_LIGHT);
    t.CHECK(@src(), color_of(in, raven.R_COLOR_TEXT) == light_text, "color_of(in, R_COLOR_TEXT) == light_text");
    t.CHECK(@src(), color_of(out, raven.R_COLOR_TEXT) == theme_color(raven.R_COLOR_TEXT), "color_of(out, R_COLOR_TEXT) == theme_color(R_COLOR_TEXT)");
    t.CHECK(@src(), raven.Rwidget_get_material(in) == raven.R_MATERIAL_SOLID, "Rwidget_get_material(in) == R_MATERIAL_SOLID");
    t.CHECK(@src(), raven.Rwidget_get_material(out) == raven.R_MATERIAL_FROSTED_GLASS, "Rwidget_get_material(out) == R_MATERIAL_FROSTED_GLASS");
    raven.Rtheme_apply(raven.R_THEME_DARK);

    // a widget takes the theme of where it is put
    const moved = raven.Rbutton_create("Moved");
    t.CHECK(@src(), color_of(moved, raven.R_COLOR_TEXT) == dark_text, "color_of(moved, R_COLOR_TEXT) == dark_text");
    _ = raven.Rwidget_add_child(raven.Rwidget_find(window, "side"), moved);
    t.CHECK(@src(), color_of(moved, raven.R_COLOR_TEXT) == light_text, "color_of(moved, R_COLOR_TEXT) == light_text");
    _ = raven.Rwidget_add_child(raven.Rwidget_find(window, "back"), moved);
    t.CHECK(@src(), color_of(moved, raven.R_COLOR_TEXT) == dark_text, "color_of(moved, R_COLOR_TEXT) == dark_text");

    // ... and the list of a combo box that of its combo box
    _ = raven.Rdraw_frame();
    t.test_click(window, raven.Rwidget_find(window, "combo"));
    _ = raven.Rdraw_frame();
    raven.Rwindow_close_popups(window);

    t.CHECK(@src(), raven.Rwidget_set_theme(raven.Rwidget_find(window, "side"), "GlassDark") != 0, "Rwidget_set_theme(Rwidget_find(window, \"side\"), \"GlassDark\")");
    t.CHECK_STR(@src(), raven.Rwidget_get_theme(in), "GlassDark", "Rwidget_get_theme(in)");
    t.CHECK_STR(@src(), raven.Rwidget_get_theme(deep), "Dark", "Rwidget_get_theme(deep)");
    t.CHECK(@src(), raven.Rwidget_set_theme(raven.Rwidget_find(window, "side"), null) != 0, "Rwidget_set_theme(Rwidget_find(window, \"side\"), NULL)");
    t.CHECK_STR(@src(), raven.Rwidget_get_theme(in), "Dark", "Rwidget_get_theme(in)");
    t.CHECK(@src(), color_of(in, raven.R_COLOR_TEXT) == dark_text, "color_of(in, R_COLOR_TEXT) == dark_text");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rwidget_set_theme(in, "No such theme") == 0, "!Rwidget_set_theme(in, \"No such theme\")");
    t.CHECK(@src(), raven.Rtheme_use("No such theme") == 0, "!Rtheme_use(\"No such theme\")");
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");
    _ = raven.Rdraw_frame();
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  Theme files
// -------------------------------------------------------------------------

const g_theme_xml =
    "<Theme Name=\"Ember\" Base=\"Dark\" Accent=\"#FF6A00\" CornerRadius=\"9\">\n" ++
    "  <Colors Panel=\"#201510\" Text=\"#FFE8D0\" AccentPressed=\"#102030\"/>\n" ++
    "  <Metrics ControlHeight=\"31\" FontSize=\"15\"/>\n" ++
    "  <Glass Frost=\"0.5\" Rim=\"1.5\"/>\n" ++
    "  <Syntax Keyword=\"#FF0000\" String=\"#00FF00\"/>\n" ++
    "  <Style Class=\"danger\" Accent=\"#FF0033\" Material=\"TintedGlass\"/>\n" ++
    "  <Style Widget=\"Button\" ControlHeight=\"36\"/>\n" ++
    "</Theme>\n";

fn test_theme_files() void {
    const xml: [*c]const u8 = "<Window Width=\"400\" Height=\"300\"><VBox><Button Name=\"a\" Text=\"A\"/><Button Name=\"b\" Class=\"danger\" Text=\"B\"/><Label Name=\"l\">L</Label></VBox></Window>";
    const window = raven.Rwindow_create_from_xml(xml, t.strlen(xml));
    const a = raven.Rwidget_find(window, "a");
    const b = raven.Rwidget_find(window, "b");
    const l = raven.Rwidget_find(window, "l");
    var path: [512]u8 = undefined;
    var saved: [512]u8 = undefined;
    var name: [*c]const u8 = undefined;
    const count: c_int = raven.Rtheme_get_count();
    var r: f32 = undefined;
    var g: f32 = undefined;
    var bl: f32 = undefined;
    var al: f32 = undefined;

    // Dark, Light, two more and the two high contrast themes
    t.CHECK(@src(), count == 6, "count == 6");
    t.CHECK_STR(@src(), raven.Rtheme_get_name_at(0), "Dark", "Rtheme_get_name_at(0)");
    t.CHECK(@src(), raven.Rtheme_get_name_at(6) == null, "Rtheme_get_name_at(6) == NULL");

    name = raven.Rtheme_load_from_memory(g_theme_xml, 0);
    t.CHECK_STR(@src(), name, "Ember", "name");
    t.CHECK(@src(), raven.Rtheme_get_count() == 7, "Rtheme_get_count() == 7");
    // loading a theme does not put it on
    t.CHECK_STR(@src(), raven.Rtheme_get_name(), "Dark", "Rtheme_get_name()");
    t.CHECK(@src(), theme_color(raven.R_COLOR_PANEL) != 0x201510FF, "theme_color(R_COLOR_PANEL) != 0x201510FFu");

    t.CHECK(@src(), raven.Rtheme_use("ember") != 0, "Rtheme_use(\"ember\")");
    t.CHECK_STR(@src(), raven.Rtheme_get_name(), "Ember", "Rtheme_get_name()");
    t.CHECK(@src(), theme_color(raven.R_COLOR_PANEL) == 0x201510FF, "theme_color(R_COLOR_PANEL) == 0x201510FFu");
    t.CHECK(@src(), theme_color(raven.R_COLOR_TEXT) == 0xFFE8D0FF, "theme_color(R_COLOR_TEXT) == 0xFFE8D0FFu");
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT) == 0xFF6A00FF, "theme_color(R_COLOR_ACCENT) == 0xFF6A00FFu");
    // a shade given by the file replaces the one worked out from the accent; the others follow the accent
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT_PRESSED) == 0x102030FF, "theme_color(R_COLOR_ACCENT_PRESSED) == 0x102030FFu");
    t.CHECK(@src(), theme_color(raven.R_COLOR_FOCUS) == 0xFF6A00FF, "theme_color(R_COLOR_FOCUS) == 0xFF6A00FFu");
    t.CHECK_NEAR(@src(), raven.Rtheme_get_metric(raven.R_METRIC_CORNER_RADIUS), 9.0, "Rtheme_get_metric(R_METRIC_CORNER_RADIUS)");
    t.CHECK_NEAR(@src(), raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT), 31.0, "Rtheme_get_metric(R_METRIC_CONTROL_HEIGHT)");
    t.CHECK_NEAR(@src(), raven.Rtheme_get_metric(raven.R_METRIC_GLASS_FROST) * 10.0, 5.0, "Rtheme_get_metric(R_METRIC_GLASS_FROST) * 10.0f");
    t.CHECK_NEAR(@src(), raven.Rtheme_get_metric(raven.R_METRIC_GLASS_RIM) * 10.0, 15.0, "Rtheme_get_metric(R_METRIC_GLASS_RIM) * 10.0f");
    t.CHECK(@src(), raven.Rtheme_is_dark() != 0, "Rtheme_is_dark()");
    raven.Rtheme_get_token_color(raven.R_TOKEN_KEYWORD, &r, &g, &bl, &al);
    t.CHECK(@src(), r > 0.99 and g < 0.01 and bl < 0.01, "r > 0.99f && g < 0.01f && bl < 0.01f");
    // its styles
    t.CHECK(@src(), color_of(b, raven.R_COLOR_ACCENT) == 0xFF0033FF, "color_of(b, R_COLOR_ACCENT) == 0xFF0033FFu");
    t.CHECK(@src(), color_of(a, raven.R_COLOR_ACCENT) == 0xFF6A00FF, "color_of(a, R_COLOR_ACCENT) == 0xFF6A00FFu");
    t.CHECK(@src(), raven.Rwidget_get_material(b) == raven.R_MATERIAL_TINTED_GLASS, "Rwidget_get_material(b) == R_MATERIAL_TINTED_GLASS");
    t.CHECK_NEAR(@src(), raven.Rwidget_get_metric(a, raven.R_METRIC_CONTROL_HEIGHT), 36.0, "Rwidget_get_metric(a, R_METRIC_CONTROL_HEIGHT)");
    t.CHECK_NEAR(@src(), raven.Rwidget_get_metric(l, raven.R_METRIC_CONTROL_HEIGHT), 31.0, "Rwidget_get_metric(l, R_METRIC_CONTROL_HEIGHT)");
    _ = raven.Rdraw_frame();

    // written to a file and read back under another name: the same theme
    _ = t.snprintf(&saved, saved.len, "%s/raven_test_saved_theme.xml", temp_dir());
    raven.Rtheme_set_color(raven.R_COLOR_WINDOW, 0.25, 0.5, 0.75, 1.0);
    t.CHECK(@src(), raven.Rtheme_save(&saved, "Saved") != 0, "Rtheme_save(saved, \"Saved\")");
    raven.Rtheme_apply(raven.R_THEME_LIGHT);
    t.CHECK(@src(), color_of(b, raven.R_COLOR_ACCENT) != 0xFF0033FF, "color_of(b, R_COLOR_ACCENT) != 0xFF0033FFu");
    name = raven.Rtheme_load(&saved);
    t.CHECK_STR(@src(), name, "Saved", "name");
    t.CHECK(@src(), raven.Rtheme_use("Saved") != 0, "Rtheme_use(\"Saved\")");
    t.CHECK(@src(), theme_color(raven.R_COLOR_WINDOW) == 0x4080BFFF, "theme_color(R_COLOR_WINDOW) == 0x4080BFFFu");
    t.CHECK(@src(), theme_color(raven.R_COLOR_PANEL) == 0x201510FF, "theme_color(R_COLOR_PANEL) == 0x201510FFu");
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT_PRESSED) == 0x102030FF, "theme_color(R_COLOR_ACCENT_PRESSED) == 0x102030FFu");
    t.CHECK_NEAR(@src(), raven.Rtheme_get_metric(raven.R_METRIC_CONTROL_HEIGHT), 31.0, "Rtheme_get_metric(R_METRIC_CONTROL_HEIGHT)");
    t.CHECK(@src(), color_of(b, raven.R_COLOR_ACCENT) == 0xFF0033FF, "color_of(b, R_COLOR_ACCENT) == 0xFF0033FFu");
    t.CHECK(@src(), raven.Rwidget_get_material(b) == raven.R_MATERIAL_TINTED_GLASS, "Rwidget_get_material(b) == R_MATERIAL_TINTED_GLASS");
    t.CHECK_NEAR(@src(), raven.Rwidget_get_metric(a, raven.R_METRIC_CONTROL_HEIGHT), 36.0, "Rwidget_get_metric(a, R_METRIC_CONTROL_HEIGHT)");
    raven.Rtheme_get_token_color(raven.R_TOKEN_STRING, &r, &g, &bl, &al);
    t.CHECK(@src(), r < 0.01 and g > 0.99, "r < 0.01f && g > 0.99f");
    t.CHECK(@src(), raven.Rtheme_is_dark() != 0, "Rtheme_is_dark()");
    _ = remove(&saved);

    // a theme file is followed like an interface file: saving it changes what uses it
    _ = t.snprintf(&path, path.len, "%s/raven_test_theme.xml", temp_dir());
    write_text(&path, "<Theme Name=\"Live\" Base=\"Light\" Accent=\"#00AA00\"/>");
    t.CHECK_STR(@src(), raven.Rtheme_load(&path), "Live", "Rtheme_load(path)");
    t.CHECK(@src(), raven.Rtheme_use("Live") != 0, "Rtheme_use(\"Live\")");
    t.CHECK(@src(), raven.Rtheme_is_dark() == 0, "!Rtheme_is_dark()");
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT) == 0x00AA00FF, "theme_color(R_COLOR_ACCENT) == 0x00AA00FFu");
    t.CHECK(@src(), raven.Rwidget_set_theme(l, "Ember") != 0, "Rwidget_set_theme(l, \"Ember\")");
    raven.Rxml_set_reload_callback(on_reload, null);
    write_text(&path, "<Theme Name=\"Live\" Base=\"Light\" Accent=\"#AA00AA\"><Style Class=\"danger\" Accent=\"#123456\"/></Theme>");
    t.CHECK(@src(), raven.Rxml_check_files() >= 1, "Rxml_check_files() >= 1");
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT) == 0xAA00AAFF, "theme_color(R_COLOR_ACCENT) == 0xAA00AAFFu");
    t.CHECK(@src(), color_of(a, raven.R_COLOR_ACCENT) == 0xAA00AAFF, "color_of(a, R_COLOR_ACCENT) == 0xAA00AAFFu");
    t.CHECK(@src(), color_of(b, raven.R_COLOR_ACCENT) == 0x123456FF, "color_of(b, R_COLOR_ACCENT) == 0x123456FFu");
    // (the part of the window that has another theme keeps it)
    t.CHECK(@src(), color_of(l, raven.R_COLOR_ACCENT) == 0xFF6A00FF, "color_of(l, R_COLOR_ACCENT) == 0xFF6A00FFu");
    // a file with a mistake changes nothing
    t.EXPECT_ERRORS_BEGIN();
    write_text(&path, "<Theme Name=\"Live\" Base=\"Light\" Accent=\"#00FFFF\"");
    _ = raven.Rxml_check_files();
    _ = raven.Rxml_check_files();
    _ = raven.Rxml_check_files();
    _ = raven.Rxml_check_files();
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    t.CHECK(@src(), theme_color(raven.R_COLOR_ACCENT) == 0xAA00AAFF, "theme_color(R_COLOR_ACCENT) == 0xAA00AAFFu");
    raven.Rxml_set_reload_callback(null, null);
    _ = remove(&path);

    // mistakes are reported and the rest of the file is used
    t.EXPECT_ERRORS_BEGIN();
    name = raven.Rtheme_load_from_memory("<Theme Name=\"Odd\" Base=\"Nope\" Speed=\"3\"><Colors Panel=\"red-ish\" Text=\"#102030\"/><Style Widget=\"Nope\" Accent=\"#fff\"/><Other/></Theme>", 0);
    t.EXPECT_ERRORS_END(@src(), 5, "g_test_errors >= (5)");
    t.CHECK_STR(@src(), name, "Odd", "name");
    t.CHECK(@src(), raven.Rtheme_use("Odd") != 0, "Rtheme_use(\"Odd\")");
    t.CHECK(@src(), theme_color(raven.R_COLOR_TEXT) == 0x102030FF, "theme_color(R_COLOR_TEXT) == 0x102030FFu");
    t.EXPECT_ERRORS_BEGIN();
    t.CHECK(@src(), raven.Rtheme_load_from_memory("<Theme Name=\"Dark\"/>", 0) == null, "Rtheme_load_from_memory(\"<Theme Name=\\\"Dark\\\"/>\", 0) == NULL");
    t.CHECK(@src(), raven.Rtheme_load_from_memory("<NotATheme/>", 0) == null, "Rtheme_load_from_memory(\"<NotATheme/>\", 0) == NULL");
    t.CHECK(@src(), raven.Rtheme_load_from_memory("<Theme", 0) == null, "Rtheme_load_from_memory(\"<Theme\", 0) == NULL");
    t.CHECK(@src(), raven.Rtheme_load("/no/such/folder/theme.xml") == null, "Rtheme_load(\"/no/such/folder/theme.xml\") == NULL");
    t.EXPECT_ERRORS_END(@src(), 4, "g_test_errors >= (4)");

    raven.Rtheme_apply(raven.R_THEME_DARK);
    raven.Rwindow_destroy(window);
}

// ---------------------------------------------------------------------------
//  Live reload of interface files
// -------------------------------------------------------------------------

fn test_live_reload() void {
    var path: [512]u8 = undefined;
    var part: [512]u8 = undefined;
    var library: [512]u8 = undefined;
    // Rid window, title, input, list, button, extra, added; (declared where they are assigned; list is assigned twice)

    _ = t.snprintf(&path, path.len, "%s/raven_test_live.xml", temp_dir());
    _ = t.snprintf(&part, part.len, "%s/raven_test_live_part.xml", temp_dir());
    _ = t.snprintf(&library, library.len, "%s/raven_test_live_library.xml", temp_dir());

    t.CHECK(@src(), raven.Rxml_get_live_reload() != 0, "Rxml_get_live_reload()");
    write_text(&part, "<Label Name=\"part\">Part 1</Label>");
    write_text(&library, "<Widgets><Widget Name=\"LiveCard\" Title=\"t\"><Border><Label Text=\"card {Title}\"/></Border></Widget></Widgets>");
    t.CHECK(@src(), raven.Rxml_register_widgets_from_file(&library) == 1, "Rxml_register_widgets_from_file(library) == 1");
    write_text(&path, "<Window Title=\"One\" Width=\"400\" Height=\"300\"><VBox Name=\"box\" Spacing=\"4\">" ++
        "<Label Name=\"title\">Hello</Label>" ++
        "<TextInput Name=\"input\" Placeholder=\"Type\"/>" ++
        "<ListView Name=\"list\"><Item>a</Item><Item>b</Item></ListView>" ++
        "<Button Name=\"go\" Text=\"Go\"/>" ++
        "<Label>unnamed 1</Label><Label>unnamed 2</Label>" ++
        "<Include Source=\"raven_test_live_part.xml\"/>" ++
        "<LiveCard Name=\"card\" Title=\"A\"/>" ++
        "</VBox><Shortcut Keys=\"Ctrl+K\" Action=\"k\"/></Window>");
    const window = raven.Rwindow_create_from_xml_file(&path);
    t.CHECK(@src(), window != raven.R_INVALID_ID, "window != R_INVALID_ID");
    const title = raven.Rwidget_find(window, "title");
    const input = raven.Rwidget_find(window, "input");
    var list = raven.Rwidget_find(window, "list");
    const button = raven.Rwidget_find(window, "go");
    raven.Rbutton_set_clicked_callback(button, on_click, null);
    raven.Rtext_input_set_text(input, "typed by the user");
    raven.Rlist_view_set_selected(list, 1);
    // something the application added itself
    const added = raven.Rlabel_create("added by the application");
    _ = raven.Rwidget_add_child(raven.Rwidget_find(window, "box"), added);
    _ = raven.Rdraw_frame();
    raven.Rxml_set_reload_callback(on_reload, null);
    g_reloads = 0;

    // nothing changed: nothing happens
    t.CHECK(@src(), raven.Rxml_check_files() == 0, "Rxml_check_files() == 0");
    t.CHECK(@src(), g_reloads == 0, "g_reloads == 0");

    // attributes change: the widgets stay, with what the application and the user gave them
    write_text(&path, "<Window Title=\"Two\" Width=\"400\" Height=\"300\"><VBox Name=\"box\" Spacing=\"10\">" ++
        "<Label Name=\"title\">Hello, world</Label>" ++
        "<TextInput Name=\"input\" Placeholder=\"Type here\"/>" ++
        "<ListView Name=\"list\"><Item>a</Item><Item>b</Item></ListView>" ++
        "<Button Name=\"go\" Text=\"Go now\" Class=\"primary\"/>" ++
        "<Label>unnamed 1</Label><Label>unnamed 2</Label>" ++
        "<Include Source=\"raven_test_live_part.xml\"/>" ++
        "<LiveCard Name=\"card\" Title=\"A\"/>" ++
        "</VBox><Shortcut Keys=\"Ctrl+J\" Action=\"j\"/></Window>");
    t.CHECK(@src(), raven.Rxml_check_files() == 1, "Rxml_check_files() == 1");
    t.CHECK(@src(), g_reloads == 1 and g_reload_ok != 0, "g_reloads == 1 && g_reload_ok");
    t.CHECK_STR(@src(), &g_reload_path, &path, "g_reload_path");
    t.CHECK_STR(@src(), raven.Rwindow_get_title(window), "Two", "Rwindow_get_title(window)");
    t.CHECK(@src(), raven.Rwidget_find(window, "title") == title, "Rwidget_find(window, \"title\") == title");
    t.CHECK(@src(), raven.Rwidget_find(window, "input") == input, "Rwidget_find(window, \"input\") == input");
    t.CHECK(@src(), raven.Rwidget_find(window, "list") == list, "Rwidget_find(window, \"list\") == list");
    t.CHECK(@src(), raven.Rwidget_find(window, "go") == button, "Rwidget_find(window, \"go\") == button");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(title), "Hello, world", "Rlabel_get_text(title)");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(raven.Rwidget_get_child(button, 0)), "Go now", "Rlabel_get_text(Rwidget_get_child(button, 0))");
    t.CHECK_STR(@src(), raven.Rwidget_get_class(button), "primary", "Rwidget_get_class(button)");
    t.CHECK_STR(@src(), raven.Rtext_input_get_text(input), "typed by the user", "Rtext_input_get_text(input)");
    t.CHECK(@src(), raven.Rlist_view_get_selected(list) == 1, "Rlist_view_get_selected(list) == 1");
    t.CHECK(@src(), raven.Rwidget_is_valid(added) != 0, "Rwidget_is_valid(added)");
    t.CHECK_NEAR(@src(), raven.Rpanel_get_spacing(raven.Rwidget_find(window, "box")), 10.0, "Rpanel_get_spacing(Rwidget_find(window, \"box\"))");
    g_clicks = 0;
    _ = raven.Rdraw_frame();
    t.test_click(window, button);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");

    // elements come, go and move: the others keep their widgets
    write_text(&path, "<Window Title=\"Two\" Width=\"400\" Height=\"300\"><VBox Name=\"box\" Spacing=\"10\">" ++
        "<Button Name=\"go\" Text=\"Go now\" Class=\"primary\"/>" ++
        "<Label Name=\"new\">New</Label>" ++
        "<Label Name=\"title\">Hello, world</Label>" ++
        "<ListView Name=\"list\"><Item>a</Item><Item>b</Item><Item>c</Item></ListView>" ++
        "<Label>unnamed 0</Label><Label>unnamed 1</Label><Label>unnamed 2</Label>" ++
        "<Include Source=\"raven_test_live_part.xml\"/>" ++
        "<LiveCard Name=\"card\" Title=\"A\"/>" ++
        "</VBox></Window>");
    t.CHECK(@src(), raven.Rxml_check_files() == 1, "Rxml_check_files() == 1");
    t.CHECK(@src(), g_reloads == 2 and g_reload_ok != 0, "g_reloads == 2 && g_reload_ok");
    t.CHECK(@src(), raven.Rwidget_find(window, "go") == button, "Rwidget_find(window, \"go\") == button");
    t.CHECK(@src(), raven.Rwidget_find(window, "title") == title, "Rwidget_find(window, \"title\") == title");
    t.CHECK(@src(), raven.Rwidget_is_valid(input) == 0, "!Rwidget_is_valid(input)");
    t.CHECK(@src(), raven.Rwidget_find(window, "new") != raven.R_INVALID_ID, "Rwidget_find(window, \"new\") != R_INVALID_ID");
    // (the list has other items: it had to be built again)
    t.CHECK(@src(), raven.Rwidget_is_valid(list) == 0, "!Rwidget_is_valid(list)");
    list = raven.Rwidget_find(window, "list");
    t.CHECK(@src(), raven.Rlist_view_get_item_count(list) == 3, "Rlist_view_get_item_count(list) == 3");
    {
        const box = raven.Rwidget_find(window, "box");
        t.CHECK(@src(), raven.Rwidget_get_child(box, 0) == button, "Rwidget_get_child(box, 0) == button");
        t.CHECK(@src(), raven.Rwidget_get_child(box, 1) == raven.Rwidget_find(window, "new"), "Rwidget_get_child(box, 1) == Rwidget_find(window, \"new\")");
        t.CHECK(@src(), raven.Rwidget_get_child(box, 2) == title, "Rwidget_get_child(box, 2) == title");
        t.CHECK(@src(), raven.Rwidget_get_child(box, 3) == list, "Rwidget_get_child(box, 3) == list");
        t.CHECK_STR(@src(), raven.Rlabel_get_text(raven.Rwidget_get_child(box, 4)), "unnamed 0", "Rlabel_get_text(Rwidget_get_child(box, 4))");
        t.CHECK_STR(@src(), raven.Rlabel_get_text(raven.Rwidget_get_child(box, 5)), "unnamed 1", "Rlabel_get_text(Rwidget_get_child(box, 5))");
        t.CHECK_STR(@src(), raven.Rlabel_get_text(raven.Rwidget_get_child(box, 6)), "unnamed 2", "Rlabel_get_text(Rwidget_get_child(box, 6))");
        t.CHECK(@src(), raven.Rwidget_is_valid(added) != 0, "Rwidget_is_valid(added)");
        t.CHECK(@src(), raven.Rwidget_get_child_count(box) == 10, "Rwidget_get_child_count(box) == 10");
    }
    g_clicks = 0;
    _ = raven.Rdraw_frame();
    t.test_click(window, button);
    t.CHECK(@src(), g_clicks == 1, "g_clicks == 1");

    // a file it includes changes
    const extra = raven.Rwidget_find(window, "part");
    write_text(&part, "<Label Name=\"part\">Part two</Label>");
    t.CHECK(@src(), raven.Rxml_check_files() == 1, "Rxml_check_files() == 1");
    t.CHECK(@src(), g_reloads == 3, "g_reloads == 3");
    t.CHECK(@src(), raven.Rwidget_find(window, "part") == extra, "Rwidget_find(window, \"part\") == extra");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(extra), "Part two", "Rlabel_get_text(extra)");

    // the file of a widget it uses changes
    write_text(&library, "<Widgets><Widget Name=\"LiveCard\" Title=\"t\"><Border><Label Name=\"inner\" Text=\"new card {Title}\"/></Border></Widget></Widgets>");
    t.CHECK(@src(), raven.Rxml_check_files() == 1, "Rxml_check_files() == 1");
    t.CHECK_STR(@src(), raven.Rlabel_get_text(raven.Rwidget_find(window, "inner")), "new card A", "Rlabel_get_text(Rwidget_find(window, \"inner\"))");
    t.CHECK(@src(), raven.Rwidget_find(window, "go") == button, "Rwidget_find(window, \"go\") == button");

    // a file with a mistake leaves everything as it is
    t.EXPECT_ERRORS_BEGIN();
    write_text(&path, "<Window Title=\"Broken\"><VBox><Label>half");
    _ = raven.Rxml_check_files();
    _ = raven.Rxml_check_files();
    _ = raven.Rxml_check_files();
    _ = raven.Rxml_check_files();
    write_text(&path, "<Window Title=\"Wrong tag\"><VBox><NoSuchWidget/></VBox></Window>");
    _ = raven.Rxml_check_files();
    t.EXPECT_ERRORS_END(@src(), 2, "g_test_errors >= (2)");
    t.CHECK(@src(), g_reload_ok == 0, "!g_reload_ok");
    t.CHECK_STR(@src(), raven.Rwindow_get_title(window), "Two", "Rwindow_get_title(window)");
    t.CHECK(@src(), raven.Rwidget_find(window, "go") == button, "Rwidget_find(window, \"go\") == button");
    t.CHECK(@src(), raven.Rwidget_is_valid(title) != 0, "Rwidget_is_valid(title)");

    // and the next good one is taken
    write_text(&path, "<Window Title=\"Three\" Width=\"400\" Height=\"300\"><HBox Name=\"box\"><Button Name=\"go\" Text=\"Again\"/></HBox></Window>");
    t.CHECK(@src(), raven.Rxml_check_files() == 1, "Rxml_check_files() == 1");
    t.CHECK(@src(), g_reload_ok != 0, "g_reload_ok");
    t.CHECK_STR(@src(), raven.Rwindow_get_title(window), "Three", "Rwindow_get_title(window)");
    t.CHECK(@src(), raven.Rwidget_is_valid(button) == 0, "!Rwidget_is_valid(button)");
    t.CHECK(@src(), raven.Rwidget_is_valid(added) == 0, "!Rwidget_is_valid(added)");
    t.CHECK(@src(), raven.Rwidget_get_type(raven.Rwindow_get_content(window)) == raven.R_WIDGET_HBOX, "Rwidget_get_type(Rwindow_get_content(window)) == R_WIDGET_HBOX");
    _ = raven.Rdraw_frame();

    // turned off: the files are no longer looked at by themselves, but can still be checked by hand
    raven.Rxml_set_live_reload(raven.R_FALSE);
    t.CHECK(@src(), raven.Rxml_get_live_reload() == 0, "!Rxml_get_live_reload()");
    raven.Rxml_set_live_reload(raven.R_TRUE);

    // the window is gone: its file is forgotten
    raven.Rwindow_destroy(window);
    write_text(&path, "<Window Title=\"Four\" Width=\"400\" Height=\"300\"><HBox/></Window>");
    g_reloads = 0;
    _ = raven.Rxml_check_files();
    t.CHECK(@src(), g_reloads == 0, "g_reloads == 0");

    // a widget made from a file follows it too, where it was put
    {
        const host = raven.Rwindow_create("Host", 300, 200, raven.R_WINDOW_DEFAULT);
        const box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
        // Rid piece, label; (declared where they are assigned; piece is assigned twice)
        raven.Rwindow_set_content(host, box);
        write_text(&part, "<HBox Name=\"piece\"><Label Name=\"p\">one</Label></HBox>");
        var piece = raven.Rwidget_create_from_xml_file(&part);
        _ = raven.Rwidget_add_child(box, raven.Rlabel_create("before"));
        _ = raven.Rwidget_add_child(box, piece);
        _ = raven.Rwidget_add_child(box, raven.Rlabel_create("after"));
        const label = raven.Rwidget_find(piece, "p");
        write_text(&part, "<HBox Name=\"piece\" Spacing=\"7\"><Label Name=\"p\">one more</Label><Label>two</Label></HBox>");
        _ = raven.Rxml_check_files();
        t.CHECK(@src(), raven.Rwidget_is_valid(piece) != 0, "Rwidget_is_valid(piece)");
        t.CHECK_STR(@src(), raven.Rlabel_get_text(label), "one more", "Rlabel_get_text(label)");
        t.CHECK(@src(), raven.Rwidget_get_child_count(piece) == 2, "Rwidget_get_child_count(piece) == 2");
        // its root becomes another kind of widget: a new one takes its place
        write_text(&part, "<VBox Name=\"piece\"><Label Name=\"p\">changed</Label></VBox>");
        _ = raven.Rxml_check_files();
        t.CHECK(@src(), raven.Rwidget_is_valid(piece) == 0, "!Rwidget_is_valid(piece)");
        t.CHECK(@src(), raven.Rwidget_get_child_count(box) == 3, "Rwidget_get_child_count(box) == 3");
        piece = raven.Rwidget_get_child(box, 1);
        t.CHECK(@src(), raven.Rwidget_get_type(piece) == raven.R_WIDGET_VBOX, "Rwidget_get_type(piece) == R_WIDGET_VBOX");
        t.CHECK_STR(@src(), raven.Rlabel_get_text(raven.Rwidget_find(piece, "p")), "changed", "Rlabel_get_text(Rwidget_find(piece, \"p\"))");
        raven.Rwindow_destroy(host);
    }

    raven.Rxml_set_reload_callback(null, null);
    raven.Rxml_unregister_widget("LiveCard");
    _ = remove(&path);
    _ = remove(&part);
    _ = remove(&library);
}

export fn main() c_int {
    if (t.test_init(0) == 0) {
        _ = t.printf("test_themes: cannot initialize Raven\n");
        return 1;
    }
    t.RUN(test_styles, "test_styles");
    t.RUN(test_accent_and_scopes, "test_accent_and_scopes");
    t.RUN(test_theme_files, "test_theme_files");
    t.RUN(test_live_reload, "test_live_reload");
    raven.Rshutdown();
    return t.test_report("test_themes");
}
