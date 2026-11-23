// Translated to Zig from vendor/raven/examples/workspace/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - workspace
// The frame of a tool: panels that dock, a file browser, materials.
//
//   DockArea       panels arranged by the user (workspace.xml); the
//                  arrangement is a short text to save and load
//                  (Rdock_area_save_layout / load_layout); panels added
//                  and closed from C
//   FileBrowser    the folders and files of the disk, as a widget: a double
//                  click on a file opens it in a new panel
//   materials      Rtheme_set_material for everything, Rwidget_set_material
//                  for one widget and what it contains
//   Island         tells what just happened, then folds back
//   HeaderBar      without background: the bar is the top of the window

const std = @import("std");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

extern "c" fn strcpy(dest: [*c]u8, src: [*c]const u8) [*c]u8;

// #ifndef RAVEN_EXAMPLE_DIR / #define RAVEN_EXAMPLE_DIR "." : example.RAVEN_EXAMPLE_DIR is always defined
// (the module example_config of the build gives it).
const RAVEN_EXAMPLE_DIR = example.RAVEN_EXAMPLE_DIR;

var app = std.mem.zeroes(struct {
    window: raven.Rid,
    dock: raven.Rid,
    welcome: raven.Rid,
    files: raven.Rid,
    log: raven.Rid,
    island: raven.Rid,
    look: raven.Rid,
    saved_layout: [*c]u8,
    notes: c_int,
});

fn say(title: [*c]const u8, detail: [*c]const u8) void {
    var line: [600]u8 = undefined;
    _ = example.snprintf(&line, line.len, "%s: %s", title, detail);
    _ = raven.Rlist_view_add_item(app.log, &line);
    raven.Rlist_view_scroll_to_item(app.log, raven.Rlist_view_get_item_count(app.log) - 1);
    raven.Rlabel_set_text(raven.Rwidget_find(app.window, "island.text"), title);
    raven.Rlabel_set_text(raven.Rwidget_find(app.window, "island.title"), title);
    raven.Rlabel_set_text(raven.Rwidget_find(app.window, "island.detail"), detail);
    raven.Risland_expand_for(app.island, 2.0);
}

// ---------------------------------------------------------------------------
//  Panels
// -------------------------------------------------------------------------

/// A new panel beside the editor, as a tab of the same group.
fn add_editor_panel(title: [*c]const u8, text: [*c]const u8, language: [*c]const u8) raven.Rid {
    const editor: raven.Rid = raven.Rtext_editor_create(text);
    raven.Rtext_editor_set_line_numbers(editor, raven.R_TRUE);
    raven.Rtext_editor_set_language(editor, language);
    // the first panel may have been closed: then the new one takes the middle of the area
    raven.Rdock_area_add_panel(app.dock, editor, title, raven.R_DOCK_TAB, if (raven.Rwidget_is_valid(app.welcome) != 0) app.welcome else raven.R_INVALID_ID, 0.0);
    raven.Rdock_area_show_panel(app.dock, editor);
    return editor;
}

fn on_file_accepted(browser: raven.Rid, path: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    var size: usize = 0;
    const text: [*c]u8 = raven.Rfile_read(path, &size);
    var name: [*c]const u8 = example.strrchr(path, '/');
    const other: [*c]const u8 = example.strrchr(path, '\\');
    _ = browser;
    _ = user_data;
    if (other != null and (name == null or other > name)) name = other;
    name = if (name != null) name + 1 else path;
    if (text == null) {
        say("Cannot open", path);
        return;
    }
    if (size > 2 * 1024 * 1024) {
        say("Too large to show", name);
    } else {
        _ = add_editor_panel(name, text, raven.Rlanguage_for_file(path));
        say("Opened", name);
    }
    raven.Rmemory_free(text);
}

/// Returning R_FALSE would keep the panel open (unsaved changes...).
fn on_panel_close(area: raven.Rid, panel: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = area;
    _ = user_data;
    if (panel == app.welcome) app.welcome = raven.R_INVALID_ID;
    return raven.R_TRUE;
}

fn on_dock_changed(area: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    // what would be written to a settings file
    raven.Rlabel_set_text(raven.Rwidget_find(app.window, "layout.text"), raven.Rdock_area_save_layout(area));
}

fn action_layout(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    if (example.strcmp(action, "layout.save") == 0) {
        const layout: [*c]const u8 = raven.Rdock_area_save_layout(app.dock);
        example.free(app.saved_layout);
        app.saved_layout = @ptrCast(example.malloc(example.strlen(layout) + 1));
        _ = strcpy(app.saved_layout, layout);
        say("Layout saved", layout);
    } else if (example.strcmp(action, "layout.restore") == 0) {
        if (app.saved_layout == null) say("Nothing saved yet", "Use \"Save layout\" first.") //
        else if (raven.Rdock_area_load_layout(app.dock, app.saved_layout) != 0) say("Layout restored", "The panels fly back to where they were.");
    } else {
        var title: [32]u8 = undefined;
        app.notes += 1;
        _ = example.snprintf(&title, title.len, "Note %d", app.notes);
        _ = add_editor_panel(&title, "", null);
        say("New panel", &title);
    }
}

// ---------------------------------------------------------------------------
//  Materials
// -------------------------------------------------------------------------

fn action_look(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const themes = [4]raven.RTheme{ raven.R_THEME_DARK, raven.R_THEME_LIGHT, raven.R_THEME_GLASS_DARK, raven.R_THEME_GLASS_LIGHT };
    const materials = [5]raven.RMaterial{ raven.R_MATERIAL_DEFAULT, raven.R_MATERIAL_SOLID, raven.R_MATERIAL_GLASS, raven.R_MATERIAL_FROSTED_GLASS, raven.R_MATERIAL_TINTED_GLASS };
    const index: c_int = raven.Rcombo_box_get_selected(sender);
    _ = user_data;
    if (index < 0) return;
    if (example.strcmp(action, "look.theme") == 0) {
        raven.Rtheme_apply(themes[@intCast(index)]);
        // (a theme comes with its material: the choice below starts over)
        raven.Rcombo_box_set_selected(raven.Rwidget_find(app.window, "material"), 0);
        say("Theme", raven.Rcombo_box_get_item_text(sender, index));
    } else if (example.strcmp(action, "look.material") == 0) {
        // every widget that was not given a material of its own
        if (index == 0) raven.Rtheme_apply(themes[@intCast(raven.Rcombo_box_get_selected(raven.Rwidget_find(app.window, "theme")))]) //
        else raven.Rtheme_set_material(materials[@intCast(index)]);
        say("Material of everything", raven.Rcombo_box_get_item_text(sender, index));
    } else {
        // this panel, and what it contains
        raven.Rwidget_set_material(app.look, materials[@intCast(index)]);
        say("Material of the panel", raven.Rcombo_box_get_item_text(sender, index));
    }
}

export fn main() c_int {
    const WELCOME: [:0]const u8 =
        "/*\n" ++
        " * Drag the tab of a panel:\n" ++
        " *   - onto a tab bar, to put it with the tabs that are there;\n" ++
        " *   - onto the left, right, top or bottom of a panel, to split it;\n" ++
        " *   - onto an edge of the window, to take the whole side.\n" ++
        " * Drag the line between two panels to resize them.\n" ++
        " * Double click a file on the left to open it in a new panel.\n" ++
        " */\n" ++
        "int main(void) {\n" ++
        "\treturn 0;\n" ++
        "}\n";

    if (example.example_init("workspace") == 0) return 1;
    raven.Rtheme_apply(raven.R_THEME_GLASS_DARK);

    raven.Raction_bind("layout.save", action_layout, null);
    raven.Raction_bind("layout.restore", action_layout, null);
    raven.Raction_bind("note.new", action_layout, null);
    raven.Raction_bind("look.theme", action_look, null);
    raven.Raction_bind("look.material", action_look, null);
    raven.Raction_bind("look.panel", action_look, null);

    app.window = raven.Rwindow_create_from_xml_file(RAVEN_EXAMPLE_DIR ++ "/workspace.xml");
    if (app.window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }
    app.dock = raven.Rwidget_find(app.window, "dock");
    app.welcome = raven.Rwidget_find(app.window, "welcome");
    app.files = raven.Rwidget_find(app.window, "files");
    app.log = raven.Rwidget_find(app.window, "log");
    app.island = raven.Rwidget_find(app.window, "island");
    app.look = raven.Rwidget_find(app.window, "look");

    raven.Rtext_editor_set_text(app.welcome, WELCOME);
    _ = raven.Rfile_browser_set_directory(app.files, RAVEN_EXAMPLE_DIR ++ "/..");
    raven.Rfile_browser_set_accepted_callback(app.files, on_file_accepted, null);
    raven.Rdock_area_set_close_callback(app.dock, on_panel_close, null);
    raven.Rdock_area_set_changed_callback(app.dock, on_dock_changed, null);
    on_dock_changed(app.dock, null);
    raven.Rdock_area_show_panel(app.dock, app.log);
    _ = raven.Rlist_view_add_item(app.log, "Ready.");

    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }
    example.free(app.saved_layout);
    raven.Rshutdown();
    return 0;
}
