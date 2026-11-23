// Translated to Zig from vendor/raven/examples/themes/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - themes
// Theme files, styles, classes, Markdown, and files loaded again when they change.
//
//   Rtheme_load(path)          reads a theme file and keeps it under its name
//   Rtheme_use(name)           makes a named theme the theme of the application
//   Rtheme_set_accent(r,g,b)   one color, and the shades that follow from it
//   Rtheme_save(path, name)    writes the theme in use as a theme file
//   Class="danger", Theme="paper.xml"       in the XML
//   Markdown="true"            on a Label (rendered) and on a TextEditor (styled in place)
//
// Every file of this example is watched while it runs: themes.xml, ocean.xml,
// paper.xml and notes.md. Save one and the window follows.

const std = @import("std");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// (#ifndef RAVEN_EXAMPLE_DIR / #define RAVEN_EXAMPLE_DIR ".": the module `example` always defines it.)

var app = std.mem.zeroes(struct {
    window: raven.Rid,
    themes: raven.Rid,
    status: raven.Rid,
    notes: raven.Rid,
    editor: raven.Rid,
    watch: raven.Rid,
    notes_text: [*c]u8,
});

fn fill_themes() void {
    const current: [*c]const u8 = raven.Rtheme_get_name();
    var i: c_int = undefined;
    raven.Rcombo_box_clear_items(app.themes);
    i = 0;
    while (i < raven.Rtheme_get_count()) : (i += 1) {
        const name: [*c]const u8 = raven.Rtheme_get_name_at(i);
        _ = raven.Rcombo_box_add_item(app.themes, name);
        if (current != null and example.strcmp(name, current) == 0) raven.Rcombo_box_set_selected(app.themes, i);
    }
}

// notes.md is not XML: the example reads it itself, again when it changes.
fn load_notes() void {
    var size: usize = 0;
    const text: [*c]u8 = raven.Rfile_read(example.RAVEN_EXAMPLE_DIR ++ "/notes.md", &size);
    if (text == null) return;
    if (app.notes_text == null or example.strcmp(app.notes_text, text) != 0) {
        raven.Rlabel_set_text(app.notes, text);
        if (app.notes_text == null) raven.Rtext_editor_set_text(app.editor, "## Try it\n\nType **bold**, *emphasis*, `code`,\n- a list\n- [a link](https://example.org)\n");
        raven.Rmemory_free(app.notes_text);
        app.notes_text = text;
    } else {
        raven.Rmemory_free(text);
    }
}

fn on_notes_timer(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    _ = user_data;
    load_notes();
}

fn find_widgets() void {
    app.themes = raven.Rwidget_find(app.window, "themes");
    app.status = raven.Rwidget_find(app.window, "status");
    app.notes = raven.Rwidget_find(app.window, "notes");
    app.editor = raven.Rwidget_find(app.window, "editor");
    fill_themes();
}

// A file was loaded again: an interface file may have replaced widgets, a theme file may have a new name.
fn on_reload(path: [*c]const u8, ok: c_int, user_data: ?*anyopaque) callconv(.c) void {
    var text: [300]u8 = undefined;
    _ = user_data;
    _ = example.snprintf(&text, text.len, @as([*:0]const u8, if (ok != 0) "Loaded again: %.200s" else "Not loaded (see the error): %.200s"), path);
    if (ok != 0) find_widgets();
    raven.Rlabel_set_text(app.status, &text);
}

fn action_use(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const index: c_int = raven.Rcombo_box_get_selected(sender);
    _ = action;
    _ = user_data;
    if (index >= 0) _ = raven.Rtheme_use(raven.Rcombo_box_get_item_text(sender, index));
}

fn action_accent(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    _ = action;
    _ = user_data;
    raven.Rcolor_picker_get_color(sender, &r, &g, &b, &a);
    raven.Rtheme_set_accent(r, g, b);
}

fn action_save(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = action;
    _ = user_data;
    raven.Rlabel_set_text(app.status, @as([*c]const u8, if (raven.Rtheme_save("my-theme.xml", "Mine") != 0) "Written: my-theme.xml (in the working folder)" else "Could not write my-theme.xml"));
}

fn action_docs(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = action;
    _ = user_data;
    raven.Rlabel_set_text(app.status, "A link of the Markdown text fired the action \"themes.docs\".");
}

export fn main() c_int {
    const theme: [*c]const u8 = example.getenv("RAVEN_EXAMPLE_THEME");
    if (example.example_init("Raven themes") == 0) return 1;

    // the theme files: each becomes a theme with a name, next to the four built-in ones
    _ = raven.Rtheme_load(example.RAVEN_EXAMPLE_DIR ++ "/ocean.xml");
    _ = raven.Rtheme_load(example.RAVEN_EXAMPLE_DIR ++ "/paper.xml");
    _ = raven.Rtheme_use(if (theme != null) theme else "Ocean");

    raven.Raction_bind("themes.use", action_use, null);
    raven.Raction_bind("themes.accent", action_accent, null);
    raven.Raction_bind("themes.save", action_save, null);
    raven.Raction_bind("themes.docs", action_docs, null);

    app.window = raven.Rwindow_create_from_xml_file(example.RAVEN_EXAMPLE_DIR ++ "/themes.xml");
    if (app.window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }
    find_widgets();
    load_notes();
    raven.Rxml_set_reload_callback(on_reload, null);
    app.watch = raven.Rtimer_create(0.5, raven.R_TRUE, on_notes_timer, null);
    raven.Rwindow_show(app.window);

    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }
    raven.Rmemory_free(app.notes_text);
    raven.Rshutdown();
    return raven.Rget_exit_code();
}
