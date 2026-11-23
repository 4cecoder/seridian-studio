// Translated to Zig from vendor/raven/tools/designer/island.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven IDE - island.c
// The island at the top of the window (raven_shell.h): what is going on,
// at a glance, and what to do about it.
//
// Folded, a capsule hanging from the top edge: a dot (gray: nothing going
// on, blue: building or running, green: the last build went well, orange:
// with warnings, red: it failed), the project and the file, and the state.
// Unfolded (the pointer over it, or a click), the project and its folder,
// the file and whether it has unsaved changes, the build (under way for how
// long, or how the last one ended), Build / Run / Stop, the problems, the
// content drawer, Save all. When a build ends, the island unfolds by itself
// for a few seconds to say how.
//
// When the code editor in front holds an interface (.xml, .xmlc, .xmlpy...),
// the island is its preview: unfolded, it shows the interface built from the
// text being typed (rebuilt as it changes, in the language of the preview),
// and opens it in the visual editor when asked. The visual editor itself is
// only there when asked for (the Preview of the content drawer).

const std = @import("std");
const raven = @import("raven");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

/// The largest the preview of the island grows; a bigger interface scrolls in it.
const PREVIEW_MAX_WIDTH: f32 = 720.0;
const PREVIEW_MAX_HEIGHT: f32 = 440.0;

const ISLAND_XML = "<Island Name=\"island\" Attached=\"true\">" ++
    "  <HBox Spacing=\"8\" Slot.Padding=\"14,5\">" ++
    "    <Border Name=\"island.dot\" Width=\"8\" Height=\"8\" CornerRadius=\"4\" Background=\"#8E8E93\" Slot.VAlign=\"Center\" AccessibleHidden=\"true\"/>" ++
    "    <Label Name=\"island.title\" Text=\"Raven IDE\" Slot.VAlign=\"Center\"/>" ++
    "    <Label Name=\"island.state\" Opacity=\"0.6\" Slot.VAlign=\"Center\" Visibility=\"Collapsed\"/>" ++
    "  </HBox>" ++
    "  <VBox Name=\"island.body\" Spacing=\"10\" Slot.Padding=\"18,14\" Width=\"420\">" ++
    "    <HBox Spacing=\"10\">" ++
    "      <Border Name=\"island.dot.big\" Width=\"10\" Height=\"10\" CornerRadius=\"5\" Background=\"#8E8E93\" Slot.VAlign=\"Center\" AccessibleHidden=\"true\"/>" ++
    "      <VBox Slot.Fill=\"1\" Spacing=\"2\">" ++
    "        <Label Name=\"island.project\" TextSize=\"16\"/>" ++
    "        <Label Name=\"island.where\" Opacity=\"0.55\" TextSize=\"11\"/>" ++
    "      </VBox>" ++
    "    </HBox>" ++
    "    <Label Name=\"island.file\" Opacity=\"0.85\" Wrap=\"true\"/>" ++
    "    <VBox Name=\"island.preview\" Spacing=\"6\" Visibility=\"Collapsed\">" ++
    "      <HBox Spacing=\"6\">" ++
    "        <Label Name=\"island.preview.title\" Text=\"Preview\" Opacity=\"0.6\" Slot.Fill=\"1\" Slot.VAlign=\"Center\"/>" ++
    "        <Button Text=\"Open in the visual editor\" Style=\"Flat\" OnClicked=\"view.preview\" Tooltip=\"Ctrl+Shift+P\"/>" ++
    "      </HBox>" ++
    "      <ScrollBox Name=\"island.preview.scroll\" ScrollBoth=\"true\">" ++
    "        <Border Name=\"island.preview.frame\" CornerRadius=\"8\" BorderWidth=\"1\" Slot.HAlign=\"Center\"/>" ++
    "      </ScrollBox>" ++
    "      <Label Name=\"island.preview.error\" Wrap=\"true\" Opacity=\"0.8\" Visibility=\"Collapsed\"/>" ++
    "    </VBox>" ++
    "    <Separator/>" ++
    "    <Label Name=\"island.build\" Wrap=\"true\"/>" ++
    "    <HBox Spacing=\"6\">" ++
    "      <Button Text=\"Build\" OnClicked=\"build.build\" Tooltip=\"Ctrl+B\"/>" ++
    "      <Button Text=\"Run\" Style=\"Primary\" OnClicked=\"build.run\" Tooltip=\"F5\"/>" ++
    "      <Button Name=\"island.stop\" Text=\"Stop\" OnClicked=\"build.stop\" Tooltip=\"Ctrl+F5\"/>" ++
    "      <Spacer Slot.Fill=\"1\"/>" ++
    "      <Button Name=\"island.problems\" Text=\"No problem\" Style=\"Flat\" OnClicked=\"island.problems\" Tooltip=\"The problems of the interface, then those of the last build\"/>" ++
    "    </HBox>" ++
    "    <HBox Spacing=\"6\">" ++
    "      <Button Text=\"Content drawer  (Ctrl+Space)\" Style=\"Flat\" OnClicked=\"drawer.toggle\" Slot.Fill=\"1\"/>" ++
    "      <Button Text=\"Save all\" Style=\"Flat\" OnClicked=\"file.save_all\" Tooltip=\"Ctrl+Alt+S\"/>" ++
    "    </HBox>" ++
    "  </VBox>" ++
    "</Island>";

var g_i: extern struct {
    island: raven.Rid,
    timer: raven.Rid,
    was_running: c_int,
    problems_text: [48]u8,
    /// the preview: what it was built from (the file, the change of its text), what it built
    preview: raven.Rid,
    preview_path: [1024]u8,
    preview_revision: c_uint,
    preview_stale: c_int,
} = .{
    .island = raven.R_INVALID_ID,
    .timer = raven.R_INVALID_ID,
    .was_running = 0,
    .problems_text = std.mem.zeroes([48]u8),
    .preview = raven.R_INVALID_ID,
    .preview_path = std.mem.zeroes([1024]u8),
    .preview_revision = 0,
    .preview_stale = 1,
};

fn find(name: [*c]const u8) raven.Rid {
    return raven.Rwidget_find(g_i.island, name);
}

/// (a text is set only when it changes: no layout for nothing, four times a second)
fn set_text(name: [*c]const u8, text: [*c]const u8) void {
    const label: raven.Rid = find(name);
    const now: [*c]const u8 = raven.Rlabel_get_text(label);
    if (now == null or libc.strcmp(now, text) != 0) raven.Rlabel_set_text(label, text);
}

fn set_dot(color: [*c]const u8) void {
    _ = raven.Rwidget_set_attribute(find("island.dot"), "Background", color);
    _ = raven.Rwidget_set_attribute(find("island.dot.big"), "Background", color);
}

// ---------------------------------------------------------------------------
//  The preview of the interface in the code editor in front
// -------------------------------------------------------------------------

/// The paths written in an interface (images, includes) start from its folder.
fn base_path_of(path: [*c]const u8) void {
    const folder: [*c]u8 = ide.ide_strdup(path);
    var slash: [*c]u8 = libc.strrchr(folder, '/');
    const back: [*c]u8 = libc.strrchr(folder, '\\');
    if (back != null and (slash == null or back > slash)) slash = back;
    if (slash != null) {
        slash.* = 0;
        raven.Rxml_set_base_path(folder);
    }
    libc.free(folder);
}

fn drop_preview() void {
    if (g_i.preview != raven.R_INVALID_ID and raven.Rwidget_is_valid(g_i.preview) != 0) raven.Rwidget_destroy(g_i.preview);
    g_i.preview = raven.R_INVALID_ID;
}

fn preview_error(text: [*c]const u8) void {
    const label: raven.Rid = find("island.preview.error");
    raven.Rlabel_set_text(label, if (text != null) text else "");
    raven.Rwidget_set_visibility(label, if (text != null and text[0] != 0) raven.R_VISIBLE else raven.R_COLLAPSED);
    raven.Rwidget_set_visibility(find("island.preview.scroll"), if (text != null and text[0] != 0) raven.R_COLLAPSED else raven.R_VISIBLE);
}

/// Builds the interface of a text (an .xml, or the interface element of an .xmlc...) into the frame of the island.
fn build_preview(path: [*c]const u8, text: [*c]const u8) void {
    const frame: raven.Rid = find("island.preview.frame");
    const scroll: raven.Rid = find("island.preview.scroll");
    var document: raven.Rid = undefined;
    var root: raven.Rid = undefined;
    var start: usize = 0;
    var end: usize = libc.strlen(text);
    var first_line: c_int = 1;
    var width: f32 = 520.0;
    var height: f32 = 300.0;
    var error_: raven.RXmlError = undefined;
    var message: [400]u8 = undefined;

    drop_preview();
    if (ide.ide_interface_language(path) != null) {
        const found: c_int = ide.xmlc_find_interface(text, &start, &end, &first_line);
        if (found <= 0) {
            preview_error(if (found == 0) "No interface in the file yet: write its element after the <script> blocks." else "An element of the file is not closed.");
            return;
        }
    }
    error_ = std.mem.zeroes(raven.RXmlError);
    document = raven.Rxml_document_parse(text + start, end - start, &error_);
    if (document == raven.R_INVALID_ID) {
        _ = libc.snprintf(&message, message.len, "Line %d: %s", error_.line + first_line - 1, @as([*c]const u8, &error_.message));
        preview_error(&message);
        return;
    }
    // (the paths of the file start from its folder; then those of the visual editor again)
    base_path_of(path);
    root = raven.Rxml_document_get_root(document);
    if (ide.ide_iequal(raven.Rxml_node_get_tag(root), "Window") != 0) {
        const w: [*c]const u8 = raven.Rxml_node_get_attribute(root, "Width");
        const h: [*c]const u8 = raven.Rxml_node_get_attribute(root, "Height");
        width = if (w != null and libc.atoi(w) > 0) @floatFromInt(libc.atoi(w)) else 800.0;
        height = if (h != null and libc.atoi(h) > 0) @floatFromInt(libc.atoi(h)) else 600.0;
        raven.Rwidget_set_size(frame, width, height);
    } else {
        // a piece of interface: the size it asks for
        raven.Rwidget_set_size(frame, -1.0, -1.0);
    }
    raven.Rwidget_set_direction(frame, if (raven.Rlocale_get_language_count() > 0 and raven.Rlocale_is_rtl() != 0) raven.R_DIRECTION_RTL else raven.R_DIRECTION_LTR);
    g_i.preview = raven.Rxml_document_create_widget(document);
    raven.Rxml_document_destroy(document);
    if (ide.designer_get_path() != null) base_path_of(ide.designer_get_path());
    if (g_i.preview == raven.R_INVALID_ID) {
        preview_error("This interface shows nothing (yet).");
        return;
    }
    _ = raven.Rwidget_add_child(frame, g_i.preview);
    preview_error(null);
    // the island grows with the interface, up to a point: past it, the preview scrolls
    width = (if (width < PREVIEW_MAX_WIDTH) width else PREVIEW_MAX_WIDTH) + 2.0;
    height = (if (height < PREVIEW_MAX_HEIGHT) height else PREVIEW_MAX_HEIGHT) + 2.0;
    raven.Rwidget_set_size(scroll, width, height);
    raven.Rwidget_set_size(find("island.body"), if (width > 420.0) width else 420.0, -1.0);
}

/// Shows (and builds when its text changed) the preview of the interface in the code editor in front; `force`: even folded.
fn update_preview(force: c_int) void {
    var path: [*c]const u8 = null;
    var text: [*c]const u8 = null;
    var revision: c_uint = 0;
    var has: c_int = ide.editors_current_interface(&path, &text, &revision);
    var title: [400]u8 = undefined;
    // (the interface the visual editor shows is previewed there)
    if (has != 0 and ide.designer_has_document() != 0 and ide.designer_get_path() != null and ide.ide_same_path(ide.designer_get_path(), path) != 0) has = raven.R_FALSE;
    if (has == 0) {
        if (g_i.preview_path[0] != 0) {
            drop_preview();
            g_i.preview_path[0] = 0;
            raven.Rwidget_set_visibility(find("island.preview"), raven.R_COLLAPSED);
            raven.Rwidget_set_size(find("island.body"), 420.0, -1.0);
        }
        return;
    }
    if (force == 0 and raven.Risland_is_expanded(g_i.island) == 0) return;
    raven.Rwidget_set_visibility(find("island.preview"), raven.R_VISIBLE);
    if (g_i.preview_stale == 0 and libc.strcmp(&g_i.preview_path, path) == 0 and g_i.preview_revision == revision) return;
    _ = libc.snprintf(&g_i.preview_path, g_i.preview_path.len, "%s", path);
    g_i.preview_revision = revision;
    g_i.preview_stale = raven.R_FALSE;
    _ = libc.snprintf(&title, title.len, "Preview  \xC2\xB7  %s", ide.ide_basename(path));
    set_text("island.preview.title", &title);
    build_preview(path, text);
}

fn refresh() void {
    var build: ide.build_summary_t = undefined;
    // the file: the one of the visual editor, else the one of the code editor in front
    const path: [*c]const u8 = if (ide.designer_has_document() != 0 and ide.designer_get_path() != null) ide.designer_get_path() else ide.editors_current_path();
    const file: [*c]const u8 = if (path != null) ide.ide_basename(path) else null;
    const unsaved: c_int = @intFromBool(ide.designer_is_modified() != 0 or ide.editors_any_modified() != 0);
    const problems: c_int = ide.designer_problem_count();
    const now: f64 = raven.Rget_time();
    var title: [300]u8 = undefined;
    var state: [96]u8 = undefined;
    var text: [400]u8 = undefined;

    ide.build_get_summary(&build);

    // folded: the project and the file
    if (ide.g_project_dir != null and file != null) {
        _ = libc.snprintf(&title, title.len, "%s  \xC2\xB7  %s%s", ide.ide_basename(ide.g_project_dir), file, @as([*c]const u8, if (unsaved != 0) " \xE2\x80\xA2" else ""));
    } else if (ide.g_project_dir != null) {
        _ = libc.snprintf(&title, title.len, "%s", ide.ide_basename(ide.g_project_dir));
    } else if (file != null) {
        _ = libc.snprintf(&title, title.len, "%s%s", file, @as([*c]const u8, if (unsaved != 0) " \xE2\x80\xA2" else ""));
    } else _ = libc.snprintf(&title, title.len, "Raven IDE");
    set_text("island.title", &title);

    // the state, and its color
    state[0] = 0;
    if (build.running != 0 and build.program != 0) {
        _ = libc.snprintf(&state, state.len, "running");
        set_dot("#0A84FF");
    } else if (build.running != 0) {
        _ = libc.snprintf(&state, state.len, "building %.0f s", now - build.started);
        set_dot("#0A84FF");
    } else if (build.has_result != 0 and build.ok == 0) {
        _ = libc.snprintf(&state, state.len, "%d error%s", build.errors, @as([*c]const u8, if (build.errors == 1) "" else "s"));
        set_dot("#FF453A");
    } else if (build.has_result != 0 and build.warnings != 0) {
        _ = libc.snprintf(&state, state.len, "%d warning%s", build.warnings, @as([*c]const u8, if (build.warnings == 1) "" else "s"));
        set_dot("#FF9F0A");
    } else if (build.has_result != 0) {
        _ = libc.snprintf(&state, state.len, "built");
        set_dot("#30D158");
    } else if (problems != 0) {
        _ = libc.snprintf(&state, state.len, "%d problem%s", problems, @as([*c]const u8, if (problems == 1) "" else "s"));
        set_dot("#FF9F0A");
    } else {
        set_dot("#8E8E93");
    }
    set_text("island.state", &state);
    raven.Rwidget_set_visibility(find("island.state"), if (state[0] != 0) raven.R_VISIBLE else raven.R_COLLAPSED);

    // a build just ended: the island says how, for a few seconds
    if (g_i.was_running != 0 and build.running == 0 and build.has_result != 0 and raven.Risland_is_expanded(g_i.island) == 0) raven.Risland_expand_for(g_i.island, 4.0);

    // unfolded
    set_text("island.project", if (ide.g_project_dir != null) ide.ide_basename(ide.g_project_dir) else "No project");
    if (ide.g_project_dir != null) {
        var pretty: [600]u8 = undefined;
        ide.ide_pretty_path(ide.g_project_dir, &pretty, pretty.len);
        set_text("island.where", &pretty);
    } else {
        set_text("island.where", "Project > Open folder, or New project");
    }
    if (file != null) {
        _ = libc.snprintf(&text, text.len, "%s%s", file, @as([*c]const u8, if (unsaved != 0) "  \xC2\xB7  unsaved changes" else "  \xC2\xB7  saved"));
    } else _ = libc.snprintf(&text, text.len, if (unsaved != 0) "Unsaved changes in the code editors" else "No file open");
    set_text("island.file", &text);

    update_preview(raven.R_FALSE);

    // (what follows is only seen unfolded: "12 s ago" does not redraw the window every second for nobody)
    if (raven.Risland_is_expanded(g_i.island) == 0) {
        g_i.was_running = build.running;
        return;
    }
    if (build.running != 0 and build.program != 0) {
        _ = libc.snprintf(&text, text.len, "The program runs (for %.0f s). Stop ends it.", now - build.started);
    } else if (build.running != 0) {
        _ = libc.snprintf(&text, text.len, "Building for %.0f s...", now - build.started);
    } else if (build.has_result != 0) {
        const ago: f64 = now - build.finished;
        var when: [48]u8 = undefined;
        if (ago < 60.0) {
            _ = libc.snprintf(&when, when.len, "%.0f s ago", ago);
        } else if (ago < 3600.0) {
            _ = libc.snprintf(&when, when.len, "%.0f min ago", ago / 60.0);
        } else _ = libc.snprintf(&when, when.len, "%.0f h ago", ago / 3600.0);
        _ = libc.snprintf(&text, text.len, "%s %s: %d error%s, %d warning%s.", @as([*c]const u8, if (build.ok != 0) "Built" else "Failed"), @as([*c]const u8, &when), build.errors, @as([*c]const u8, if (build.errors == 1) "" else "s"), build.warnings, @as([*c]const u8, if (build.warnings == 1) "" else "s"));
    } else {
        _ = libc.snprintf(&text, text.len, if (ide.g_project_dir != null) "Not built yet: Build, or Run." else "Open a project to build it.");
    }
    set_text("island.build", &text);
    raven.Rwidget_set_enabled(find("island.stop"), build.running);

    if (problems != 0 or build.errors != 0 or build.warnings != 0) {
        _ = libc.snprintf(&text, text.len, "Problems (%d)", problems + build.errors + build.warnings);
    } else {
        _ = libc.snprintf(&text, text.len, "No problem");
    }
    if (libc.strcmp(&g_i.problems_text, &text) != 0) {
        _ = libc.snprintf(&g_i.problems_text, g_i.problems_text.len, "%.47s", @as([*c]const u8, &text));
        raven.Rbutton_set_text(find("island.problems"), &text);
    }

    g_i.was_running = build.running;
}

fn on_timer(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = timer;
    _ = user_data;
    if (g_i.island != raven.R_INVALID_ID and raven.Rwidget_is_valid(g_i.island) != 0) refresh();
}

fn on_changed(island: raven.Rid, expanded: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = island;
    _ = user_data;
    if (expanded != 0) refresh();
}

fn action_island(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const problems: raven.Rid = raven.Rwidget_find(ide.g_ide_window, "problems");
    const build_problems: raven.Rid = raven.Rwidget_find(ide.g_ide_window, "build.problems");
    var build: ide.build_summary_t = undefined;
    _ = sender;
    _ = user_data;
    _ = action;
    ide.build_get_summary(&build);
    // the problems of the interface first; else those of the build
    // (the Problems panel belongs to the visual editor: hidden with it)
    if (ide.designer_has_document() != 0 and (ide.designer_problem_count() != 0 or !(build.errors != 0 or build.warnings != 0))) {
        raven.Rdock_area_open_panel(ide.g_ide_dock, problems);
    } else raven.Rdock_area_open_panel(ide.g_ide_dock, build_problems);
    raven.Risland_set_expanded(g_i.island, raven.R_FALSE);
}

export fn island_init() void {
    g_i.island = raven.Rwidget_create_from_xml(ISLAND_XML, ISLAND_XML.len);
    if (g_i.island == raven.R_INVALID_ID) return;
    raven.Rwindow_set_island(ide.g_ide_window, g_i.island);
    raven.Rwidget_set_clipping(find("island.preview.frame"), raven.R_TRUE);
    raven.Raction_bind("island.problems", action_island, null);
    raven.Risland_set_changed_callback(g_i.island, on_changed, null);
    refresh();
    g_i.timer = raven.Rtimer_create(0.25, raven.R_TRUE, on_timer, null);
}

export fn island_refresh() void {
    if (g_i.island != raven.R_INVALID_ID and raven.Rwidget_is_valid(g_i.island) != 0) refresh();
}

export fn island_preview_changed() void {
    g_i.preview_stale = raven.R_TRUE;
}

export fn island_show_preview() void {
    var path: [*c]const u8 = null;
    if (g_i.island == raven.R_INVALID_ID or raven.Rwidget_is_valid(g_i.island) == 0) return;
    if (ide.editors_current_interface(&path, null, null) == 0) return;
    g_i.preview_stale = raven.R_TRUE;
    // an interface was opened as code: the island shows that it is its preview
    if (raven.Risland_is_expanded(g_i.island) == 0) raven.Risland_expand_for(g_i.island, 3.0);
    update_preview(raven.R_TRUE);
}

export fn island_preview_widget() raven.Rid {
    if (g_i.island == raven.R_INVALID_ID or raven.Rwidget_is_valid(g_i.island) == 0) return raven.R_INVALID_ID;
    update_preview(raven.R_TRUE);
    return if (g_i.preview_path[0] != 0 and g_i.preview != raven.R_INVALID_ID and raven.Rwidget_is_valid(g_i.preview) != 0) g_i.preview else raven.R_INVALID_ID;
}

export fn island_shutdown() void {
    drop_preview();
    if (g_i.timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g_i.timer) != 0) raven.Rtimer_destroy(g_i.timer);
    g_i.timer = raven.R_INVALID_ID;
}
