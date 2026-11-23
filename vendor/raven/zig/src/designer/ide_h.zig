// Translated to Zig from vendor/raven/tools/designer/ide.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - ide.h
// What the parts of the designer share. main.c is the visual editor of an
// interface; the other files make it an IDE around a CMake project:
//
//   os.c        folders, files and programs (CMake, the compiler, the program)
//   project.c   the project: its folder, New project (with a Raven interface, or native), settings
//   editors.c   code editors (C, CMake, any text, the interfaces too) in tabs, and completion
//   xmlc.c      .xmlc files: their <script> blocks and their interface
//   build.c     configure, build, run, the Output panel and the build problems
//   strings.c   the Translations panel (CSV tables) and the language of the preview
//   welcome.c   the start page (recent projects) and the preferences of the IDE
//   island.c    the island at the top: the state of the build, and the preview of the interface being typed
//   drawer.c    the content drawer (Ctrl+Space); a right click on an interface: Preview (the visual editor)
//
// The header unit of the designer (zig/src/designer): types and `pub extern` declarations, exports nothing.

const raven = @import("raven");

// ---- os.c ----
pub const ide_entry_t = extern struct {
    name: [256]u8,
    is_dir: c_int,
};
/// The entries of a folder, folders first then by name; free with free(). Returns the count, -1 when it cannot be read.
pub extern fn ide_list_dir(path: [*c]const u8, entries: [*c][*c]ide_entry_t) c_int;
pub extern fn ide_is_dir(path: [*c]const u8) c_int;
pub extern fn ide_file_exists(path: [*c]const u8) c_int;
/// Makes a folder and the folders above it.
pub extern fn ide_make_dirs(path: [*c]const u8) c_int;
/// Seconds since 1970 of the last change of a file, 0 when missing.
pub extern fn ide_file_time(path: [*c]const u8) f64;
/// The folder of the program itself, with no slash at the end.
pub extern fn ide_exe_dir() [*c]const u8;
/// "a/b" + "c" -> "a/b/c" (malloc).
pub extern fn ide_join(a: [*c]const u8, b: [*c]const u8) [*c]u8;
/// The part after the last slash.
pub extern fn ide_basename(path: [*c]const u8) [*c]const u8;
/// The extension, lowercase, without the dot ("" when none).
pub extern fn ide_extension(path: [*c]const u8) [*c]const u8;
/// Same file names, whatever the slashes (and the case on Windows).
pub extern fn ide_same_path(a: [*c]const u8, b: [*c]const u8) c_int;
/// A copy with forward slashes.
pub extern fn ide_normalize(path: [*c]const u8) [*c]u8;
/// Defined by os.c (one structure per OS).
pub const ide_process_t = opaque {};
/// Starts a program, its standard output and errors merged in one pipe. NULL when it cannot start.
pub extern fn ide_process_start(argv: [*c]const [*c]const u8, directory: [*c]const u8) ?*ide_process_t;
/// What the program wrote since the last call (never waits). Returns the bytes read, 0 when nothing, -1 at the end.
pub extern fn ide_process_read(process: ?*ide_process_t, buffer: [*c]u8, size: c_int) c_int;
/// R_TRUE once the program has ended; its exit code then.
pub extern fn ide_process_done(process: ?*ide_process_t, exit_code: [*c]c_int) c_int;
pub extern fn ide_process_kill(process: ?*ide_process_t) void;
pub extern fn ide_process_free(process: ?*ide_process_t) void;
/// Puts a folder first in the PATH of the programs started from now on.
pub extern fn ide_prepend_path(folder: [*c]const u8) void;
/// R_TRUE when a program of that name is found in the PATH.
pub extern fn ide_find_program(name: [*c]const u8, out: [*c]u8, size: usize) c_int;
/// The folder of the user (forward slashes).
pub extern fn ide_home_dir() [*c]const u8;
/// Where the IDE keeps its preferences and its recent projects (made when missing).
pub extern fn ide_config_dir() [*c]const u8;
/// Where New project proposes to put projects the first time: Documents/Raven Projects.
pub extern fn ide_default_projects_dir() [*c]const u8;
/// A path for the eyes: the folder of the user becomes "~".
pub extern fn ide_pretty_path(path: [*c]const u8, out: [*c]u8, size: usize) void;
pub extern fn ide_remove_file(path: [*c]const u8) c_int;

// ---- main.c (the visual editor) ----
pub extern var g_ide_window: raven.Rid;
pub extern var g_ide_dock: raven.Rid;
/// The content of the dialog the IDE runs now (the scripts of the tests look in it), or R_INVALID_ID.
pub extern var g_ide_dialog: raven.Rid;
/// The dock panel the code editors share tabs with.
pub extern var g_ide_center: raven.Rid;
pub extern fn ide_status(format: [*c]const u8, ...) void;
/// Opens an interface in the visual editor: the text of a .xml, or of the interface part of a .xmlc.
pub extern fn designer_load_interface(text: [*c]const u8, path: [*c]const u8, is_xmlc: c_int) void;
/// The text the visual editor holds now (what is written in its XML panel).
pub extern fn designer_get_interface_text() [*c]const u8;
/// The file the visual editor shows, or NULL.
pub extern fn designer_get_path() [*c]const u8;
pub extern fn designer_is_modified() c_int;
pub extern fn designer_set_modified(modified: c_int) void;
/// The Name attributes of the interface (for ui.<name> in the scripts).
pub extern fn designer_get_names(names: [*c][*c]const u8, max: c_int) c_int;
/// Opens a .xml file in the visual editor; goes to a line of its XML panel.
pub extern fn designer_open_file(path: [*c]const u8) void;
pub extern fn designer_go_to_line(line: c_int) void;
/// A mark of the compiler on a line of the XML panel (an .xmlc: a line of the file).
pub extern fn designer_add_marker(line: c_int, column: c_int, @"error": c_int, message: [*c]const u8) void;
/// Builds the preview again (after the translations or the language changed).
pub extern fn designer_refresh_preview() void;
/// The frame of the preview: the strings panel sets its direction.
pub extern fn designer_get_frame() raven.Rid;
/// Saves what the visual editor holds into its file (for .xmlc: with its scripts).
pub extern fn designer_save() c_int;
/// The title of the window, after what it names changed (the project, the page).
pub extern fn designer_update_title() void;
/// No interface is shown any more: the visual editor says how to open one.
pub extern fn designer_close() void;
/// R_TRUE when the visual editor shows an interface.
pub extern fn designer_has_document() c_int;
/// The problems of the interface (the Problems panel).
pub extern fn designer_problem_count() c_int;
/// Closes the visual editor (its panels go): its file goes back to a code editor, unsaved changes included. R_FALSE when the user cancels.
pub extern fn designer_close_preview() c_int;

// ---- island.c: the island at the top of the window (project, file, build, problems) ----
pub extern fn island_init() void;
pub extern fn island_shutdown() void;
/// Shows what changed now (else it follows four times a second).
pub extern fn island_refresh() void;
/// The preview of the island is built again (the translations or the language of the preview changed).
pub extern fn island_preview_changed() void;
/// An interface was opened as code: the island unfolds a moment on its preview.
pub extern fn island_show_preview() void;
/// What the preview of the island shows (scripts of the tests), or R_INVALID_ID.
pub extern fn island_preview_widget() raven.Rid;

// ---- drawer.c: the content drawer (Ctrl+Space), the files of the project as tiles ----
/// Puts the drawer in `host` (an Overlay over the pages of the IDE).
pub extern fn drawer_init(host: raven.Rid) void;
pub extern fn drawer_shutdown() void;
pub extern fn drawer_open() void;
pub extern fn drawer_close() void;
pub extern fn drawer_toggle() void;
pub extern fn drawer_is_open() c_int;

// ---- project.c ----
pub const ide_settings_t = extern struct {
    /// Debug, Release...
    build_type: [32]u8,
    /// where find_package(raven) looks: the Raven package
    raven_prefix: [1024]u8,
    /// "" : the default of CMake
    generator: [128]u8,
    run_arguments: [512]u8,
};
/// NULL when no project is open
pub extern var g_project_dir: [*c]u8;
pub extern var g_settings: ide_settings_t;
pub extern fn project_init() void;
pub extern fn project_shutdown() void;
pub extern fn project_open(folder: [*c]const u8) c_int;
/// Creates a project in a language ("C", "C++", "Rust", "Python", "Go", "C#", "Zig", "Lua") and opens it.
/// with_interface: R_TRUE, an interface with its code (main.xmlc, main.xmlrs...) and strings.csv;
/// R_FALSE, a native project: the language alone and a classic Hello world.
pub extern fn project_create(parent_folder: [*c]const u8, name: [*c]const u8, language: [*c]const u8, with_interface: c_int) c_int;
pub extern fn project_refresh_explorer() void;
pub extern fn project_save_settings() void;
/// Opens any file of the project where it belongs: a code editor (an interface too: the island is its
/// preview; the visual editor when it already shows it) or the Translations panel.
pub extern fn ide_open_file(path: [*c]const u8, line: c_int) void;
/// Opens an interface (.xml, .xmlc...) in the visual editor: the Preview of the content drawer.
pub extern fn ide_preview_file(path: [*c]const u8) void;
/// The name of the first add_executable of the CMakeLists.txt of the project.
pub extern fn project_target_name(out: [*c]u8, size: usize) c_int;
pub extern fn project_new() void;
pub extern fn project_settings_dialog() void;
/// Closes the project (asks about unsaved changes first): R_FALSE when the user cancels.
pub extern fn project_close() c_int;
/// Unsaved changes anywhere: asks to save them. R_FALSE when the user cancels.
pub extern fn ide_confirm_unsaved(why: [*c]const u8) c_int;

// ---- editors.c ----
pub extern fn editors_init() void;
pub extern fn editors_shutdown() void;
/// Opens a file in a code editor tab (or shows it), and goes to a line (1-based, 0: stays).
pub extern fn editors_open(path: [*c]const u8, line: c_int) raven.Rid;
/// Opens a file in a code editor with a text of its own (what the visual editor held), marked modified or not.
pub extern fn editors_open_text(path: [*c]const u8, text: [*c]const u8, modified: c_int) raven.Rid;
/// Closes the code editor of a file, without asking.
pub extern fn editors_close_file(path: [*c]const u8) void;
pub extern fn editors_is_modified(editor: raven.Rid) c_int;
/// The file of the code editor in front (the keyboard is in it, or it was last), or NULL.
pub extern fn editors_current_path() [*c]const u8;
/// The same when it is an interface (.xml, .xmlc...): its text now, and a number that changes with it.
pub extern fn editors_current_interface(path: [*c][*c]const u8, text: [*c][*c]const u8, revision: [*c]c_uint) c_int;
/// Where a new code editor goes (an editor, the preview), or R_INVALID_ID: above the Output.
pub extern fn editors_anchor() raven.Rid;
/// The code editors go back together, in the tabs of the preview (after the panels were reset).
pub extern fn editors_regroup() void;
/// An editor follows the zoom of the IDE (Ctrl + wheel in one zooms them all; kept in ide.ini). The code editors do by themselves.
pub extern fn editors_zoom_attach(editor: raven.Rid) void;
/// Every editor back to 100 %.
pub extern fn editors_reset_zoom() void;
/// Opens a piece of text with a name (a script of a .xmlc), written back through `save`.
pub const ide_save_callback = ?*const fn (editor: raven.Rid, user_data: ?*anyopaque) callconv(.c) c_int;
pub extern fn editors_open_virtual(title: [*c]const u8, key: [*c]const u8, text: [*c]const u8, language: [*c]const u8, save: ide_save_callback, user_data: ?*anyopaque) raven.Rid;
pub extern fn editors_find(key: [*c]const u8) raven.Rid;
/// A tab whose title contains `text` (scripts of the tests).
pub extern fn editors_find_title(text: [*c]const u8) raven.Rid;
pub extern fn editors_save_all() c_int;
/// Closes every code editor (without asking: ask before).
pub extern fn editors_close_all() void;
/// An editor was closed by its dock area without asking: forget it.
pub extern fn editors_forget_closed() void;
/// Saves the editor the keyboard is in: R_TRUE / R_FALSE, -1 when it is not in a code editor.
pub extern fn editors_save_focused() c_int;
pub extern fn editors_any_modified() c_int;
/// Puts the build problems on the editors that show their files.
pub extern fn editors_clear_markers() void;
pub extern fn editors_add_marker(path: [*c]const u8, line: c_int, column: c_int, @"error": c_int, message: [*c]const u8) void;
pub extern fn editors_set_modified(editor: raven.Rid, modified: c_int) void;
/// Completion shared with the XML panel of the visual editor.
pub extern fn completion_attach(editor: raven.Rid, xml: c_int) void;
pub extern fn completion_load_raven_api() void;

// ---- xmlc.c ----
/// Opens a .xmlc (or .xmlrs, .xmlpy...) whole in the XML panel; the visual editor shows its interface element.
pub extern fn xmlc_open(path: [*c]const u8) c_int;
/// The same with a text instead of the file (NULL: the file).
pub extern fn xmlc_open_text(path: [*c]const u8, text: [*c]const u8) c_int;
/// Writes the .xmlc back: the text of the XML panel, scripts and interface together.
pub extern fn xmlc_save() c_int;
/// Where the interface element of the text of an .xmlc is (offsets, and its first line): 1, 0 when there is none, -1 when an element is not closed.
pub extern fn xmlc_find_interface(text: [*c]const u8, start: [*c]usize, end: [*c]usize, line: [*c]c_int) c_int;
pub extern fn xmlc_is_open() c_int;
pub extern fn xmlc_path() [*c]const u8;
pub extern fn xmlc_close() void;
/// The line of the interface element in the file.
pub extern fn xmlc_interface_line() c_int;

// ---- build.c ----
pub extern fn build_init() void;
pub extern fn build_shutdown() void;
pub extern fn build_is_running() c_int;
pub const build_summary_t = extern struct {
    /// a build (or the program) is under way
    running: c_int,
    /// what runs is the program itself
    program: c_int,
    /// Rget_time() when it started
    started: f64,
    /// a build ended since the IDE started
    has_result: c_int,
    /// how the last one ended
    ok: c_int,
    finished: f64,
    errors: c_int,
    warnings: c_int,
};
/// What the island shows: the build under way, or how the last one ended.
pub extern fn build_get_summary(summary: [*c]build_summary_t) void;
/// Stops what runs, empties the Output and the Build panel (another project).
pub extern fn build_reset() void;

// ---- strings.c ----
pub extern fn strings_init() void;
pub extern fn strings_shutdown() void;
/// Reads the CSV tables of the project (after it was opened, or a table saved).
pub extern fn strings_reload() void;
/// Opens a table in the Translations panel.
pub extern fn strings_open(path: [*c]const u8) void;
pub extern fn strings_any_modified() c_int;
pub extern fn strings_save() c_int;
/// The language of the preview ("" : the first column).
pub extern fn strings_set_preview_language(code: [*c]const u8) void;
/// Writes a cell (scripts of the tests).
pub extern fn strings_set_cell(key: [*c]const u8, column: c_int, text: [*c]const u8) c_int;
/// The keys of the tables (completion of @keys).
pub extern fn strings_key_count() c_int;
pub extern fn strings_key(index: c_int) [*c]const u8;

// ---- welcome.c ----
pub extern fn welcome_init() void;
pub extern fn welcome_shutdown() void;
/// The start page: New project, Open, the recent projects.
pub extern fn welcome_show() void;
/// The panels of the IDE (a project or a file is open).
pub extern fn welcome_hide() void;
pub extern fn welcome_is_shown() c_int;
/// A project was opened: first in the list of recent projects.
pub extern fn recent_add(folder: [*c]const u8) void;
/// A preference of the IDE (ide.ini in ide_config_dir), "" when not set.
pub extern fn prefs_get(key: [*c]const u8) [*c]const u8;
pub extern fn prefs_set(key: [*c]const u8, value: [*c]const u8) void;

// ---- accessibility.c ----
pub extern fn accessibility_init() void;
pub extern fn accessibility_shutdown() void;
/// The settings kept from the last time (ide.ini, a11y.*), applied at start.
pub extern fn accessibility_apply_saved() void;
/// View > Accessibility: every setting, live.
pub extern fn accessibility_window() void;
/// The menu follows the settings (Reduce motion).
pub extern fn accessibility_sync_menu() void;

// ---- the languages of the interfaces with code (.xmlc, .xmlrs...) ----
pub const ide_language_t = extern struct {
    /// "xmlrs"
    extension: [*c]const u8,
    /// "Rust": what New project shows
    name: [*c]const u8,
    /// the language of the script tabs
    editor: [*c]const u8,
};
/// The language of an interface file with code, or NULL for any other file (a plain .xml included).
pub extern fn ide_interface_language(path: [*c]const u8) [*c]const ide_language_t;
pub extern fn ide_language_at(index: c_int) [*c]const ide_language_t;
pub extern fn ide_language_count() c_int;
/// Sets a variable of the environment of the programs started from now on.
pub extern fn ide_set_env(name: [*c]const u8, value: [*c]const u8) void;

// ---- small things ----
pub extern fn ide_strdup(text: [*c]const u8) [*c]u8;
pub extern fn ide_iequal(a: [*c]const u8, b: [*c]const u8) c_int;
/// Appends to a growing buffer.
pub const ide_buffer_t = extern struct {
    data: [*c]u8,
    size: usize,
    cap: usize,
};
pub extern fn ide_buffer_add(buffer: [*c]ide_buffer_t, text: [*c]const u8, length: usize) void;
pub extern fn ide_buffer_printf(buffer: [*c]ide_buffer_t, format: [*c]const u8, ...) void;
pub extern fn ide_buffer_free(buffer: [*c]ide_buffer_t) void;
