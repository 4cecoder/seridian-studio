# Manifest of the Raven `widgets` module (C11 -> Zig)

Generated from `src/widgets/*.c` with `zig/tools/c_exports.py` (the same scanner `check_unit.sh` uses) and the definitions
in the C files. For every file: the non-static functions and globals the Zig file must `export` (exact C signature, the
Zig signature to write), and the functions of other modules it calls.

Layout of the work (`zig/src/widgets/`):

- `common_h.zig` (done): translation of `src/widgets/common.h`. Types (`rvn_spaced_panel_t`, `rvn_scrollbar_t`, `rvn_textedit_t`,
  `rvn_span_t`, `rvn_surface_t`, `rvn_token_t` constants), the `rvn_class_*` class objects as `pub extern const`, and
  `pub extern fn` prototypes of every function of the widgets module that other files call (`rvn_scrollbar_*`,
  `rvn_textedit_*`, `rvn_md_*`, `rvn_language_*`, `rvn_widget_font_size`...). `rvn_md_t` and `rvn_language_t` are `opaque {}`
  there: the file that defines them (markdown.zig, syntax.zig) declares its own `extern struct` with the C fields.
  Import as `const common = @import("common_h.zig");`. `RVN_ATTR(literal)` is `base.rvn_stricmp(name, literal) == 0`.
- `externs.zig` (done): `pub extern fn` prototypes of the functions of OTHER modules the widgets call (widget/widget.h, render/draw.h,
  render/font.h, render/renderer.h, core/context.h, core/fs.h, core/handle.h, core/thread.h, xml/xml.h), 128 functions + `g_rvn`,
  typed with the header units of those modules (`../widget/widget_h.zig`, `../render/draw_h.zig`, ...). `core/base.h`
  functions come from `../core/base_h.zig`; the public API from `raven`. `static inline` helpers of those headers
  (`rvn_widget_theme`, `rvn_widget_glass`, `rvn_widget_material`, `rvn_widget_collapsed`, `rvn_path_is_separator`) are `pub inline fn` in
  their own header unit, not in externs.zig.
- Layout test: `zig/layout/widgets_layout.c` and `zig/src/layout_widgets.zig` print sizeof / alignof / offsetof / enum values of the
  types of `common_h.zig`; check.sh-style command (run from `vendor/raven`, identical output expected):
  `cc -DRAVEN_PLATFORM_COCOA -I include -I src zig/layout/widgets_layout.c -o /tmp/wl_c && /tmp/wl_c > /tmp/wl_c.txt` and
  `cd zig && zig run --dep raven -Mroot=src/layout_widgets.zig -Mraven=src/raven/raven.zig > /tmp/wl_z.txt && diff /tmp/wl_c.txt /tmp/wl_z.txt`.
- Types local to one `.c` file (node, track, item, panel structs, `static` helpers) are translated inside that file's `.zig`
  (they are not shared); only what is in `common.h` is shared.
- Public `R...` functions are already declared `pub extern fn` in `raven.zig`; when you export one, copy the signature from there.
- Parameters typed `?*raven.RPainter` (opaque struct): never `[*c]`.
- Function-pointer parameters (callbacks) use the typedef of `raven.zig` (e.g. `raven.RButtonCallback`); marked below as `/*fnptr*/` when the scanner could not resolve them.

Suggested order: `common_h.zig` (done) > the small leaf files (canvas, overlay, switcher, size_box, wrap_box, border, box_panel, progress_bar...) >
the middle ones > the giants (text_editor, node_graph, block_editor, window users: dock_area, timeline). 41 files, about 28.6k lines.

Per-file entries: C line of the definition, `C:` exact signature, `Zig:` signature of the `export fn`.


## widgets/text_editor.c  (2873 lines) -> zig/src/widgets/text_editor.zig

Exports (46):

- `rvn_class_text_editor` global (line 2480)
  - C: `const rvn_widget_class_t rvn_class_text_editor;`
  - Zig: `export const rvn_class_text_editor: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rtext_editor_create()` (line 2516)
  - C: `Rid Rtext_editor_create(const char* text);`
  - Zig: `export fn Rtext_editor_create(text: [*c]const u8) raven.Rid`

- `Rtext_editor_set_text()` (line 2525)
  - C: `void Rtext_editor_set_text(Rid id, const char* text);`
  - Zig: `export fn Rtext_editor_set_text(id: raven.Rid, text: [*c]const u8) void`

- `Rtext_editor_get_text()` (line 2530)
  - C: `const char* Rtext_editor_get_text(Rid id);`
  - Zig: `export fn Rtext_editor_get_text(id: raven.Rid) [*c]const u8`

- `Rtext_editor_get_length()` (line 2540)
  - C: `int Rtext_editor_get_length(Rid id);`
  - Zig: `export fn Rtext_editor_get_length(id: raven.Rid) c_int`

- `Rtext_editor_get_line_count()` (line 2546)
  - C: `int Rtext_editor_get_line_count(Rid id);`
  - Zig: `export fn Rtext_editor_get_line_count(id: raven.Rid) c_int`

- `Rtext_editor_get_line()` (line 2551)
  - C: `const char* Rtext_editor_get_line(Rid id, int line);`
  - Zig: `export fn Rtext_editor_get_line(id: raven.Rid, line: c_int) [*c]const u8`

- `Rtext_editor_insert_text()` (line 2557)
  - C: `void Rtext_editor_insert_text(Rid id, const char* text);`
  - Zig: `export fn Rtext_editor_insert_text(id: raven.Rid, text: [*c]const u8) void`

- `Rtext_editor_set_cursor()` (line 2567)
  - C: `void Rtext_editor_set_cursor(Rid id, int line, int column);`
  - Zig: `export fn Rtext_editor_set_cursor(id: raven.Rid, line: c_int, column: c_int) void`

- `Rtext_editor_get_cursor()` (line 2574)
  - C: `void Rtext_editor_get_cursor(Rid id, int* line, int* column);`
  - Zig: `export fn Rtext_editor_get_cursor(id: raven.Rid, line: [*c]c_int, column: [*c]c_int) void`

- `Rtext_editor_select()` (line 2584)
  - C: `void Rtext_editor_select(Rid id, int from_line, int from_column, int to_line, int to_column);`
  - Zig: `export fn Rtext_editor_select(id: raven.Rid, from_line: c_int, from_column: c_int, to_line: c_int, to_column: c_int) void`

- `Rtext_editor_select_all()` (line 2592)
  - C: `void Rtext_editor_select_all(Rid id);`
  - Zig: `export fn Rtext_editor_select_all(id: raven.Rid) void`

- `Rtext_editor_get_selection()` (line 2600)
  - C: `int Rtext_editor_get_selection(Rid id, int* from_line, int* from_column, int* to_line, int* to_column);`
  - Zig: `export fn Rtext_editor_get_selection(id: raven.Rid, from_line: [*c]c_int, from_column: [*c]c_int, to_line: [*c]c_int, to_column: [*c]c_int) c_int`

- `Rtext_editor_get_selected_text()` (line 2612)
  - C: `const char* Rtext_editor_get_selected_text(Rid id);`
  - Zig: `export fn Rtext_editor_get_selected_text(id: raven.Rid) [*c]const u8`

- `Rtext_editor_scroll_to_line()` (line 2619)
  - C: `void Rtext_editor_scroll_to_line(Rid id, int line);`
  - Zig: `export fn Rtext_editor_scroll_to_line(id: raven.Rid, line: c_int) void`

- `Rtext_editor_undo()` (line 2633)
  - C: `void Rtext_editor_undo(Rid id);`
  - Zig: `export fn Rtext_editor_undo(id: raven.Rid) void`

- `Rtext_editor_redo()` (line 2640)
  - C: `void Rtext_editor_redo(Rid id);`
  - Zig: `export fn Rtext_editor_redo(id: raven.Rid) void`

- `Rtext_editor_can_undo()` (line 2647)
  - C: `int Rtext_editor_can_undo(Rid id);`
  - Zig: `export fn Rtext_editor_can_undo(id: raven.Rid) c_int`

- `Rtext_editor_can_redo()` (line 2652)
  - C: `int Rtext_editor_can_redo(Rid id);`
  - Zig: `export fn Rtext_editor_can_redo(id: raven.Rid) c_int`

- `Rtext_editor_set_read_only()` (line 2657)
  - C: `void Rtext_editor_set_read_only(Rid id, int read_only);`
  - Zig: `export fn Rtext_editor_set_read_only(id: raven.Rid, read_only: c_int) void`

- `Rtext_editor_set_word_wrap()` (line 2663)
  - C: `void Rtext_editor_set_word_wrap(Rid id, int enabled);`
  - Zig: `export fn Rtext_editor_set_word_wrap(id: raven.Rid, enabled: c_int) void`

- `Rtext_editor_set_line_numbers()` (line 2672)
  - C: `void Rtext_editor_set_line_numbers(Rid id, int enabled);`
  - Zig: `export fn Rtext_editor_set_line_numbers(id: raven.Rid, enabled: c_int) void`

- `Rtext_editor_set_tab_size()` (line 2678)
  - C: `void Rtext_editor_set_tab_size(Rid id, int spaces);`
  - Zig: `export fn Rtext_editor_set_tab_size(id: raven.Rid, spaces: c_int) void`

- `Rtext_editor_set_tab_inserts_spaces()` (line 2688)
  - C: `void Rtext_editor_set_tab_inserts_spaces(Rid id, int enabled);`
  - Zig: `export fn Rtext_editor_set_tab_inserts_spaces(id: raven.Rid, enabled: c_int) void`

- `Rtext_editor_set_syntax()` (line 2693)
  - C: `void Rtext_editor_set_syntax(Rid id, RSyntax syntax);`
  - Zig: `export fn Rtext_editor_set_syntax(id: raven.Rid, syntax: raven.RSyntax) void`

- `Rtext_editor_set_language()` (line 2704)
  - C: `void Rtext_editor_set_language(Rid id, const char* name);`
  - Zig: `export fn Rtext_editor_set_language(id: raven.Rid, name: [*c]const u8) void`

- `Rtext_editor_set_markdown()` (line 2713)
  - C: `void Rtext_editor_set_markdown(Rid id, int enabled);`
  - Zig: `export fn Rtext_editor_set_markdown(id: raven.Rid, enabled: c_int) void`

- `Rtext_editor_get_markdown()` (line 2719)
  - C: `int Rtext_editor_get_markdown(Rid id);`
  - Zig: `export fn Rtext_editor_get_markdown(id: raven.Rid) c_int`

- `Rtext_editor_get_language()` (line 2726)
  - C: `const char* Rtext_editor_get_language(Rid id);`
  - Zig: `export fn Rtext_editor_get_language(id: raven.Rid) [*c]const u8`

- `Rtext_editor_get_token()` (line 2731)
  - C: `RToken Rtext_editor_get_token(Rid id, int line, int column);`
  - Zig: `export fn Rtext_editor_get_token(id: raven.Rid, line: c_int, column: c_int) raven.RToken`

- `Rtext_editor_set_completion()` (line 2746)
  - C: `void Rtext_editor_set_completion(Rid id, int enabled);`
  - Zig: `export fn Rtext_editor_set_completion(id: raven.Rid, enabled: c_int) void`

- `Rtext_editor_show_completions()` (line 2752)
  - C: `void Rtext_editor_show_completions(Rid id);`
  - Zig: `export fn Rtext_editor_show_completions(id: raven.Rid) void`

- `Rtext_editor_is_completing()` (line 2759)
  - C: `int Rtext_editor_is_completing(Rid id);`
  - Zig: `export fn Rtext_editor_is_completing(id: raven.Rid) c_int`

- `Rtext_editor_set_completion_callback()` (line 2764)
  - C: `void Rtext_editor_set_completion_callback(Rid id, RCompletionCallback callback, void* user_data);`
  - Zig: `export fn Rtext_editor_set_completion_callback(id: raven.Rid, callback: raven.RCompletionCallback, user_data: ?*anyopaque) void`

- `Rtext_editor_add_completion()` (line 2770)
  - C: `void Rtext_editor_add_completion(Rid id, const char* text, const char* detail);`
  - Zig: `export fn Rtext_editor_add_completion(id: raven.Rid, text: [*c]const u8, detail: [*c]const u8) void`

- `Rtext_editor_set_auto_pairs()` (line 2785)
  - C: `void Rtext_editor_set_auto_pairs(Rid id, int enabled);`
  - Zig: `export fn Rtext_editor_set_auto_pairs(id: raven.Rid, enabled: c_int) void`

- `Rtext_editor_add_marker()` (line 2790)
  - C: `void Rtext_editor_add_marker(Rid id, int line, int from_column, int to_column, RMarkerKind kind, const char* message);`
  - Zig: `export fn Rtext_editor_add_marker(id: raven.Rid, line: c_int, from_column: c_int, to_column: c_int, kind: raven.RMarkerKind, message: [*c]const u8) void`

- `Rtext_editor_clear_markers()` (line 2810)
  - C: `void Rtext_editor_clear_markers(Rid id);`
  - Zig: `export fn Rtext_editor_clear_markers(id: raven.Rid) void`

- `Rtext_editor_get_marker_count()` (line 2823)
  - C: `int Rtext_editor_get_marker_count(Rid id);`
  - Zig: `export fn Rtext_editor_get_marker_count(id: raven.Rid) c_int`

- `Rtext_editor_set_font()` (line 2828)
  - C: `void Rtext_editor_set_font(Rid id, Rid font, float size);`
  - Zig: `export fn Rtext_editor_set_font(id: raven.Rid, font: raven.Rid, size: f32) void`

- `Rtext_editor_set_zoom()` (line 2835)
  - C: `void Rtext_editor_set_zoom(Rid id, float zoom);`
  - Zig: `export fn Rtext_editor_set_zoom(id: raven.Rid, zoom: f32) void`

- `Rtext_editor_get_zoom()` (line 2847)
  - C: `float Rtext_editor_get_zoom(Rid id);`
  - Zig: `export fn Rtext_editor_get_zoom(id: raven.Rid) f32`

- `Rtext_editor_set_zoomable()` (line 2852)
  - C: `void Rtext_editor_set_zoomable(Rid id, int zoomable);`
  - Zig: `export fn Rtext_editor_set_zoomable(id: raven.Rid, zoomable: c_int) void`

- `Rtext_editor_set_zoom_callback()` (line 2857)
  - C: `void Rtext_editor_set_zoom_callback(Rid id, RTextEditorZoomCallback callback, void* user_data);`
  - Zig: `export fn Rtext_editor_set_zoom_callback(id: raven.Rid, callback: raven.RTextEditorZoomCallback, user_data: ?*anyopaque) void`

- `Rtext_editor_set_placeholder()` (line 2863)
  - C: `void Rtext_editor_set_placeholder(Rid id, const char* text);`
  - Zig: `export fn Rtext_editor_set_placeholder(id: raven.Rid, text: [*c]const u8) void`

- `Rtext_editor_set_changed_callback()` (line 2869)
  - C: `void Rtext_editor_set_changed_callback(Rid id, RTextEditorChangedCallback callback, void* user_data);`
  - Zig: `export fn Rtext_editor_set_changed_callback(id: raven.Rid, callback: raven.RTextEditorChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_clock_seconds`, `rvn_font_metrics`, `rvn_font_resolve`, `rvn_font_variant`, `rvn_paint_box`, `rvn_paint_line`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_shadow`, `rvn_paint_spring`, `rvn_paint_text`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_parse_float`, `rvn_spring_moving`, `rvn_text_width`, `rvn_widget_capture_mouse`, `rvn_widget_check`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_create_class`, `rvn_widget_destroy`, `rvn_widget_fire_action`, `rvn_widget_get`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_release_mouse`, `rvn_widget_text_color`, `rvn_window_close_popup`, `rvn_window_layout`, `rvn_window_open_popup`, `rvn_window_rearm_tooltip`

From `core/base_h.zig` (`base.<name>`): `rvn_alloc`, `rvn_clampf`, `rvn_clampi`, `rvn_color_fade`, `rvn_color_mix`, `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_maxi`, `rvn_minf`, `rvn_mini`, `rvn_realloc`, `rvn_rect`, `rvn_rect_contains`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_strndup`, `rvn_strnicmp`, `rvn_utf8_count`, `rvn_utf8_encode`, `rvn_utf8_next`, `rvn_utf8_prev`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_language_desc`, `rvn_language_find`, `rvn_language_generation`, `rvn_language_word`, `rvn_language_word_count`, `rvn_paint_row`, `rvn_paint_surface`, `rvn_scrollbar_clamp`, `rvn_scrollbar_event`, `rvn_scrollbar_needed`, `rvn_scrollbar_paint`, `rvn_scrollbar_set`, `rvn_scrollbar_shown`, `rvn_scrollbar_wheel`, `rvn_syntax_color`, `rvn_syntax_line`, `rvn_token_public`, `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_text_width`, `rvn_xml_font`

Includes: `common.h`


## widgets/node_graph.c  (2581 lines) -> zig/src/widgets/node_graph.zig

Exports (66):

- `rvn_class_node_graph` global (line 1984)
  - C: `const rvn_widget_class_t rvn_class_node_graph;`
  - Zig: `export const rvn_class_node_graph: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rnode_graph_create()` (line 2027)
  - C: `Rid Rnode_graph_create(void);`
  - Zig: `export fn Rnode_graph_create() raven.Rid`

- `Rnode_graph_add_node()` (line 2036)
  - C: `int Rnode_graph_add_node(Rid id, const char* title, float x, float y);`
  - Zig: `export fn Rnode_graph_add_node(id: raven.Rid, title: [*c]const u8, x: f32, y: f32) c_int`

- `Rnode_graph_remove_node()` (line 2052)
  - C: `void Rnode_graph_remove_node(Rid id, int node);`
  - Zig: `export fn Rnode_graph_remove_node(id: raven.Rid, node: c_int) void`

- `Rnode_graph_clear()` (line 2057)
  - C: `void Rnode_graph_clear(Rid id);`
  - Zig: `export fn Rnode_graph_clear(id: raven.Rid) void`

- `Rnode_graph_get_node_count()` (line 2063)
  - C: `int Rnode_graph_get_node_count(Rid id);`
  - Zig: `export fn Rnode_graph_get_node_count(id: raven.Rid) c_int`

- `Rnode_graph_get_node()` (line 2068)
  - C: `int Rnode_graph_get_node(Rid id, int index);`
  - Zig: `export fn Rnode_graph_get_node(id: raven.Rid, index: c_int) c_int`

- `Rnode_graph_set_node_title()` (line 2087)
  - C: `void Rnode_graph_set_node_title(Rid id, int node_id, const char* title);`
  - Zig: `export fn Rnode_graph_set_node_title(id: raven.Rid, node_id: c_int, title: [*c]const u8) void`

- `Rnode_graph_get_node_title()` (line 2097)
  - C: `const char* Rnode_graph_get_node_title(Rid id, int node_id);`
  - Zig: `export fn Rnode_graph_get_node_title(id: raven.Rid, node_id: c_int) [*c]const u8`

- `Rnode_graph_set_node_position()` (line 2104)
  - C: `void Rnode_graph_set_node_position(Rid id, int node_id, float x, float y);`
  - Zig: `export fn Rnode_graph_set_node_position(id: raven.Rid, node_id: c_int, x: f32, y: f32) void`

- `Rnode_graph_get_node_position()` (line 2115)
  - C: `void Rnode_graph_get_node_position(Rid id, int node_id, float* x, float* y);`
  - Zig: `export fn Rnode_graph_get_node_position(id: raven.Rid, node_id: c_int, x: [*c]f32, y: [*c]f32) void`

- `Rnode_graph_get_node_size()` (line 2122)
  - C: `void Rnode_graph_get_node_size(Rid id, int node_id, float* width, float* height);`
  - Zig: `export fn Rnode_graph_get_node_size(id: raven.Rid, node_id: c_int, width: [*c]f32, height: [*c]f32) void`

- `Rnode_graph_set_node_color()` (line 2131)
  - C: `void Rnode_graph_set_node_color(Rid id, int node_id, float r, float g, float b);`
  - Zig: `export fn Rnode_graph_set_node_color(id: raven.Rid, node_id: c_int, r: f32, g: f32, b: f32) void`

- `Rnode_graph_set_node_content()` (line 2141)
  - C: `void Rnode_graph_set_node_content(Rid id, int node_id, Rid content_id);`
  - Zig: `export fn Rnode_graph_set_node_content(id: raven.Rid, node_id: c_int, content_id: raven.Rid) void`

- `Rnode_graph_get_node_content()` (line 2169)
  - C: `Rid Rnode_graph_get_node_content(Rid id, int node_id);`
  - Zig: `export fn Rnode_graph_get_node_content(id: raven.Rid, node_id: c_int) raven.Rid`

- `Rnode_graph_set_node_name()` (line 2176)
  - C: `void Rnode_graph_set_node_name(Rid id, int node_id, const char* name);`
  - Zig: `export fn Rnode_graph_set_node_name(id: raven.Rid, node_id: c_int, name: [*c]const u8) void`

- `Rnode_graph_get_node_name()` (line 2185)
  - C: `const char* Rnode_graph_get_node_name(Rid id, int node_id);`
  - Zig: `export fn Rnode_graph_get_node_name(id: raven.Rid, node_id: c_int) [*c]const u8`

- `Rnode_graph_find_node()` (line 2192)
  - C: `int Rnode_graph_find_node(Rid id, const char* name);`
  - Zig: `export fn Rnode_graph_find_node(id: raven.Rid, name: [*c]const u8) c_int`

- `Rnode_graph_set_node_user_data()` (line 2197)
  - C: `void Rnode_graph_set_node_user_data(Rid id, int node_id, void* user_data);`
  - Zig: `export fn Rnode_graph_set_node_user_data(id: raven.Rid, node_id: c_int, user_data: ?*anyopaque) void`

- `Rnode_graph_get_node_user_data()` (line 2204)
  - C: `void* Rnode_graph_get_node_user_data(Rid id, int node_id);`
  - Zig: `export fn Rnode_graph_get_node_user_data(id: raven.Rid, node_id: c_int) ?*anyopaque`

- `Rnode_graph_add_input()` (line 2229)
  - C: `int Rnode_graph_add_input(Rid id, int node, const char* label, const char* type);`
  - Zig: `export fn Rnode_graph_add_input(id: raven.Rid, node: c_int, label: [*c]const u8, @"type": [*c]const u8) c_int`

- `Rnode_graph_add_output()` (line 2233)
  - C: `int Rnode_graph_add_output(Rid id, int node, const char* label, const char* type);`
  - Zig: `export fn Rnode_graph_add_output(id: raven.Rid, node: c_int, label: [*c]const u8, @"type": [*c]const u8) c_int`

- `Rnode_graph_remove_pin()` (line 2237)
  - C: `void Rnode_graph_remove_pin(Rid id, int pin_id);`
  - Zig: `export fn Rnode_graph_remove_pin(id: raven.Rid, pin_id: c_int) void`

- `Rnode_graph_get_pin_node()` (line 2252)
  - C: `int Rnode_graph_get_pin_node(Rid id, int pin_id);`
  - Zig: `export fn Rnode_graph_get_pin_node(id: raven.Rid, pin_id: c_int) c_int`

- `Rnode_graph_is_pin_output()` (line 2259)
  - C: `int Rnode_graph_is_pin_output(Rid id, int pin_id);`
  - Zig: `export fn Rnode_graph_is_pin_output(id: raven.Rid, pin_id: c_int) c_int`

- `Rnode_graph_get_pin_label()` (line 2266)
  - C: `const char* Rnode_graph_get_pin_label(Rid id, int pin_id);`
  - Zig: `export fn Rnode_graph_get_pin_label(id: raven.Rid, pin_id: c_int) [*c]const u8`

- `Rnode_graph_get_pin_type()` (line 2273)
  - C: `const char* Rnode_graph_get_pin_type(Rid id, int pin_id);`
  - Zig: `export fn Rnode_graph_get_pin_type(id: raven.Rid, pin_id: c_int) [*c]const u8`

- `Rnode_graph_get_pin_position()` (line 2280)
  - C: `void Rnode_graph_get_pin_position(Rid id, int pin_id, float* x, float* y);`
  - Zig: `export fn Rnode_graph_get_pin_position(id: raven.Rid, pin_id: c_int, x: [*c]f32, y: [*c]f32) void`

- `Rnode_graph_set_pin_name()` (line 2291)
  - C: `void Rnode_graph_set_pin_name(Rid id, int pin_id, const char* name);`
  - Zig: `export fn Rnode_graph_set_pin_name(id: raven.Rid, pin_id: c_int, name: [*c]const u8) void`

- `Rnode_graph_find_pin()` (line 2300)
  - C: `int Rnode_graph_find_pin(Rid id, int node, const char* name);`
  - Zig: `export fn Rnode_graph_find_pin(id: raven.Rid, node: c_int, name: [*c]const u8) c_int`

- `Rnode_graph_get_input()` (line 2316)
  - C: `int Rnode_graph_get_input(Rid id, int node, int index);`
  - Zig: `export fn Rnode_graph_get_input(id: raven.Rid, node: c_int, index: c_int) c_int`

- `Rnode_graph_get_output()` (line 2320)
  - C: `int Rnode_graph_get_output(Rid id, int node, int index);`
  - Zig: `export fn Rnode_graph_get_output(id: raven.Rid, node: c_int, index: c_int) c_int`

- `Rnode_graph_set_type_color()` (line 2324)
  - C: `void Rnode_graph_set_type_color(Rid id, const char* type_name, float r, float g, float b);`
  - Zig: `export fn Rnode_graph_set_type_color(id: raven.Rid, type_name: [*c]const u8, r: f32, g: f32, b: f32) void`

- `Rnode_graph_connect()` (line 2339)
  - C: `int Rnode_graph_connect(Rid id, int output_pin, int input_pin);`
  - Zig: `export fn Rnode_graph_connect(id: raven.Rid, output_pin: c_int, input_pin: c_int) c_int`

- `Rnode_graph_disconnect()` (line 2350)
  - C: `void Rnode_graph_disconnect(Rid id, int link);`
  - Zig: `export fn Rnode_graph_disconnect(id: raven.Rid, link: c_int) void`

- `Rnode_graph_get_link_count()` (line 2355)
  - C: `int Rnode_graph_get_link_count(Rid id);`
  - Zig: `export fn Rnode_graph_get_link_count(id: raven.Rid) c_int`

- `Rnode_graph_get_link()` (line 2360)
  - C: `int Rnode_graph_get_link(Rid id, int index);`
  - Zig: `export fn Rnode_graph_get_link(id: raven.Rid, index: c_int) c_int`

- `Rnode_graph_get_link_output()` (line 2365)
  - C: `int Rnode_graph_get_link_output(Rid id, int link_id);`
  - Zig: `export fn Rnode_graph_get_link_output(id: raven.Rid, link_id: c_int) c_int`

- `Rnode_graph_get_link_input()` (line 2372)
  - C: `int Rnode_graph_get_link_input(Rid id, int link_id);`
  - Zig: `export fn Rnode_graph_get_link_input(id: raven.Rid, link_id: c_int) c_int`

- `Rnode_graph_get_input_link()` (line 2379)
  - C: `int Rnode_graph_get_input_link(Rid id, int input_pin);`
  - Zig: `export fn Rnode_graph_get_input_link(id: raven.Rid, input_pin: c_int) c_int`

- `Rnode_graph_set_view()` (line 2388)
  - C: `void Rnode_graph_set_view(Rid id, float center_x, float center_y, float zoom);`
  - Zig: `export fn Rnode_graph_set_view(id: raven.Rid, center_x: f32, center_y: f32, zoom: f32) void`

- `Rnode_graph_get_view()` (line 2398)
  - C: `void Rnode_graph_get_view(Rid id, float* center_x, float* center_y, float* zoom);`
  - Zig: `export fn Rnode_graph_get_view(id: raven.Rid, center_x: [*c]f32, center_y: [*c]f32, zoom: [*c]f32) void`

- `Rnode_graph_to_canvas()` (line 2407)
  - C: `void Rnode_graph_to_canvas(Rid id, float x, float y, float* canvas_x, float* canvas_y);`
  - Zig: `export fn Rnode_graph_to_canvas(id: raven.Rid, x: f32, y: f32, canvas_x: [*c]f32, canvas_y: [*c]f32) void`

- `Rnode_graph_from_canvas()` (line 2414)
  - C: `void Rnode_graph_from_canvas(Rid id, float canvas_x, float canvas_y, float* x, float* y);`
  - Zig: `export fn Rnode_graph_from_canvas(id: raven.Rid, canvas_x: f32, canvas_y: f32, x: [*c]f32, y: [*c]f32) void`

- `Rnode_graph_frame_all()` (line 2420)
  - C: `void Rnode_graph_frame_all(Rid id);`
  - Zig: `export fn Rnode_graph_frame_all(id: raven.Rid) void`

- `Rnode_graph_set_grid_visible()` (line 2425)
  - C: `void Rnode_graph_set_grid_visible(Rid id, int visible);`
  - Zig: `export fn Rnode_graph_set_grid_visible(id: raven.Rid, visible: c_int) void`

- `Rnode_graph_set_flow_visible()` (line 2431)
  - C: `void Rnode_graph_set_flow_visible(Rid id, int visible);`
  - Zig: `export fn Rnode_graph_set_flow_visible(id: raven.Rid, visible: c_int) void`

- `Rnode_graph_set_read_only()` (line 2437)
  - C: `void Rnode_graph_set_read_only(Rid id, int read_only);`
  - Zig: `export fn Rnode_graph_set_read_only(id: raven.Rid, read_only: c_int) void`

- `Rnode_graph_select_node()` (line 2443)
  - C: `void Rnode_graph_select_node(Rid id, int node_id, int add);`
  - Zig: `export fn Rnode_graph_select_node(id: raven.Rid, node_id: c_int, add: c_int) void`

- `Rnode_graph_clear_selection()` (line 2453)
  - C: `void Rnode_graph_clear_selection(Rid id);`
  - Zig: `export fn Rnode_graph_clear_selection(id: raven.Rid) void`

- `Rnode_graph_is_node_selected()` (line 2458)
  - C: `int Rnode_graph_is_node_selected(Rid id, int node_id);`
  - Zig: `export fn Rnode_graph_is_node_selected(id: raven.Rid, node_id: c_int) c_int`

- `Rnode_graph_get_selection_count()` (line 2465)
  - C: `int Rnode_graph_get_selection_count(Rid id);`
  - Zig: `export fn Rnode_graph_get_selection_count(id: raven.Rid) c_int`

- `Rnode_graph_get_selected_node()` (line 2473)
  - C: `int Rnode_graph_get_selected_node(Rid id, int index);`
  - Zig: `export fn Rnode_graph_get_selected_node(id: raven.Rid, index: c_int) c_int`

- `Rnode_graph_set_connect_callback()` (line 2485)
  - C: `void Rnode_graph_set_connect_callback(Rid id, RNodeGraphConnectCallback callback, void* user_data);`
  - Zig: `export fn Rnode_graph_set_connect_callback(id: raven.Rid, callback: raven.RNodeGraphConnectCallback, user_data: ?*anyopaque) void`

- `Rnode_graph_set_linked_callback()` (line 2491)
  - C: `void Rnode_graph_set_linked_callback(Rid id, RNodeGraphItemCallback callback, void* user_data);`
  - Zig: `export fn Rnode_graph_set_linked_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void`

- `Rnode_graph_set_unlinked_callback()` (line 2497)
  - C: `void Rnode_graph_set_unlinked_callback(Rid id, RNodeGraphItemCallback callback, void* user_data);`
  - Zig: `export fn Rnode_graph_set_unlinked_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void`

- `Rnode_graph_set_moved_callback()` (line 2503)
  - C: `void Rnode_graph_set_moved_callback(Rid id, RNodeGraphItemCallback callback, void* user_data);`
  - Zig: `export fn Rnode_graph_set_moved_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void`

- `Rnode_graph_set_selection_callback()` (line 2509)
  - C: `void Rnode_graph_set_selection_callback(Rid id, RNodeGraphItemCallback callback, void* user_data);`
  - Zig: `export fn Rnode_graph_set_selection_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void`

- `Rnode_graph_set_removed_callback()` (line 2515)
  - C: `void Rnode_graph_set_removed_callback(Rid id, RNodeGraphItemCallback callback, void* user_data);`
  - Zig: `export fn Rnode_graph_set_removed_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void`

- `Rnode_graph_set_activated_callback()` (line 2521)
  - C: `void Rnode_graph_set_activated_callback(Rid id, RNodeGraphItemCallback callback, void* user_data);`
  - Zig: `export fn Rnode_graph_set_activated_callback(id: raven.Rid, callback: raven.RNodeGraphItemCallback, user_data: ?*anyopaque) void`

- `Rnode_graph_set_context_callback()` (line 2527)
  - C: `void Rnode_graph_set_context_callback(Rid id, RNodeGraphContextCallback callback, void* user_data);`
  - Zig: `export fn Rnode_graph_set_context_callback(id: raven.Rid, callback: raven.RNodeGraphContextCallback, user_data: ?*anyopaque) void`

- `Rnode_graph_set_pin_multiple()` (line 2533)
  - C: `void Rnode_graph_set_pin_multiple(Rid id, int pin_id, int multiple);`
  - Zig: `export fn Rnode_graph_set_pin_multiple(id: raven.Rid, pin_id: c_int, multiple: c_int) void`

- `Rnode_graph_set_node_active()` (line 2540)
  - C: `void Rnode_graph_set_node_active(Rid id, int node_id, int active);`
  - Zig: `export fn Rnode_graph_set_node_active(id: raven.Rid, node_id: c_int, active: c_int) void`

- `Rnode_graph_set_node_active_color()` (line 2549)
  - C: `void Rnode_graph_set_node_active_color(Rid id, int node_id, float r, float g, float b);`
  - Zig: `export fn Rnode_graph_set_node_active_color(id: raven.Rid, node_id: c_int, r: f32, g: f32, b: f32) void`

- `Rnode_graph_set_node_deletable()` (line 2559)
  - C: `void Rnode_graph_set_node_deletable(Rid id, int node_id, int deletable);`
  - Zig: `export fn Rnode_graph_set_node_deletable(id: raven.Rid, node_id: c_int, deletable: c_int) void`

- `Rnode_graph_set_node_badge()` (line 2566)
  - C: `void Rnode_graph_set_node_badge(Rid id, int node_id, const char* text);`
  - Zig: `export fn Rnode_graph_set_node_badge(id: raven.Rid, node_id: c_int, text: [*c]const u8) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_clock_seconds`, `rvn_curve_point`, `rvn_drawlist_transform`, `rvn_font_variant`, `rvn_paint_box`, `rvn_paint_box4`, `rvn_paint_curve`, `rvn_paint_glass`, `rvn_paint_keep_animating`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_shadow`, `rvn_paint_snap`, `rvn_paint_spring`, `rvn_paint_spring_from`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_parse_color`, `rvn_parse_float`, `rvn_spring_set`, `rvn_widget_add_child`, `rvn_widget_arrange`, `rvn_widget_capture_mouse`, `rvn_widget_check`, `rvn_widget_child_index`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_destroy`, `rvn_widget_detach`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_is_inside`, `rvn_widget_measure`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_paint`, `rvn_widget_release_mouse`, `rvn_widget_text_color`, `rvn_xml_attribute`, `rvn_xml_build_node`

From `core/base_h.zig` (`base.<name>`): `rvn_box`, `rvn_box_overlaps`, `rvn_clampf`, `rvn_color_fade`, `rvn_color_mix`, `rvn_color_to_floats`, `rvn_error`, `rvn_free`, `rvn_hash_str`, `rvn_hex`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rgba`, `rvn_strdup`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_glass_style`, `rvn_paint_focus`, `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_text_width`

Includes: `common.h`, `../xml/xml.h`


## widgets/block_editor.c  (2565 lines) -> zig/src/widgets/block_editor.zig

Exports (37):

- `rvn_class_block_editor` global (line 1876)
  - C: `const rvn_widget_class_t rvn_class_block_editor;`
  - Zig: `export const rvn_class_block_editor: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rblock_editor_create()` (line 1912)
  - C: `Rid Rblock_editor_create(void);`
  - Zig: `export fn Rblock_editor_create() raven.Rid`

- `Rblock_editor_add_kind()` (line 1919)
  - C: `int Rblock_editor_add_kind(Rid id, const char* name, const char* label, RBlockShape shape, const char* category);`
  - Zig: `export fn Rblock_editor_add_kind(id: raven.Rid, name: [*c]const u8, label: [*c]const u8, shape: raven.RBlockShape, category: [*c]const u8) c_int`

- `Rblock_editor_set_category_color()` (line 1959)
  - C: `void Rblock_editor_set_category_color(Rid id, const char* category, float r, float g, float b);`
  - Zig: `export fn Rblock_editor_set_category_color(id: raven.Rid, category: [*c]const u8, r: f32, g: f32, b: f32) void`

- `Rblock_editor_set_palette_visible()` (line 1975)
  - C: `void Rblock_editor_set_palette_visible(Rid id, int visible);`
  - Zig: `export fn Rblock_editor_set_palette_visible(id: raven.Rid, visible: c_int) void`

- `Rblock_editor_add_block()` (line 1981)
  - C: `int Rblock_editor_add_block(Rid id, const char* kind, float x, float y);`
  - Zig: `export fn Rblock_editor_add_block(id: raven.Rid, kind: [*c]const u8, x: f32, y: f32) c_int`

- `Rblock_editor_remove_block()` (line 1998)
  - C: `void Rblock_editor_remove_block(Rid id, int block);`
  - Zig: `export fn Rblock_editor_remove_block(id: raven.Rid, block: c_int) void`

- `Rblock_editor_clear()` (line 2005)
  - C: `void Rblock_editor_clear(Rid id);`
  - Zig: `export fn Rblock_editor_clear(id: raven.Rid) void`

- `Rblock_editor_attach()` (line 2016)
  - C: `int Rblock_editor_attach(Rid id, int block, int target, RBlockPlace place, int index);`
  - Zig: `export fn Rblock_editor_attach(id: raven.Rid, block: c_int, target: c_int, place: raven.RBlockPlace, index: c_int) c_int`

- `Rblock_editor_detach()` (line 2025)
  - C: `void Rblock_editor_detach(Rid id, int block, float x, float y);`
  - Zig: `export fn Rblock_editor_detach(id: raven.Rid, block: c_int, x: f32, y: f32) void`

- `Rblock_editor_get_script_count()` (line 2034)
  - C: `int Rblock_editor_get_script_count(Rid id);`
  - Zig: `export fn Rblock_editor_get_script_count(id: raven.Rid) c_int`

- `Rblock_editor_get_script()` (line 2039)
  - C: `int Rblock_editor_get_script(Rid id, int index);`
  - Zig: `export fn Rblock_editor_get_script(id: raven.Rid, index: c_int) c_int`

- `Rblock_editor_get_kind()` (line 2044)
  - C: `const char* Rblock_editor_get_kind(Rid id, int block);`
  - Zig: `export fn Rblock_editor_get_kind(id: raven.Rid, block: c_int) [*c]const u8`

- `Rblock_editor_get_next()` (line 2051)
  - C: `int Rblock_editor_get_next(Rid id, int block);`
  - Zig: `export fn Rblock_editor_get_next(id: raven.Rid, block: c_int) c_int`

- `Rblock_editor_get_body()` (line 2058)
  - C: `int Rblock_editor_get_body(Rid id, int block, int mouth);`
  - Zig: `export fn Rblock_editor_get_body(id: raven.Rid, block: c_int, mouth: c_int) c_int`

- `Rblock_editor_get_input()` (line 2065)
  - C: `int Rblock_editor_get_input(Rid id, int block, int slot);`
  - Zig: `export fn Rblock_editor_get_input(id: raven.Rid, block: c_int, slot: c_int) c_int`

- `Rblock_editor_get_slot_count()` (line 2072)
  - C: `int Rblock_editor_get_slot_count(Rid id, int block);`
  - Zig: `export fn Rblock_editor_get_slot_count(id: raven.Rid, block: c_int) c_int`

- `Rblock_editor_get_mouth_count()` (line 2079)
  - C: `int Rblock_editor_get_mouth_count(Rid id, int block);`
  - Zig: `export fn Rblock_editor_get_mouth_count(id: raven.Rid, block: c_int) c_int`

- `Rblock_editor_get_value()` (line 2086)
  - C: `const char* Rblock_editor_get_value(Rid id, int block, int slot);`
  - Zig: `export fn Rblock_editor_get_value(id: raven.Rid, block: c_int, slot: c_int) [*c]const u8`

- `Rblock_editor_set_value()` (line 2093)
  - C: `void Rblock_editor_set_value(Rid id, int block, int slot, const char* value);`
  - Zig: `export fn Rblock_editor_set_value(id: raven.Rid, block: c_int, slot: c_int, value: [*c]const u8) void`

- `Rblock_editor_get_parent()` (line 2102)
  - C: `int Rblock_editor_get_parent(Rid id, int block, RBlockPlace* place, int* index);`
  - Zig: `export fn Rblock_editor_get_parent(id: raven.Rid, block: c_int, place: [*c]raven.RBlockPlace, index: [*c]c_int) c_int`

- `Rblock_editor_get_position()` (line 2112)
  - C: `void Rblock_editor_get_position(Rid id, int block, float* x, float* y);`
  - Zig: `export fn Rblock_editor_get_position(id: raven.Rid, block: c_int, x: [*c]f32, y: [*c]f32) void`

- `Rblock_editor_set_block_glow()` (line 2120)
  - C: `void Rblock_editor_set_block_glow(Rid id, int block, int glow);`
  - Zig: `export fn Rblock_editor_set_block_glow(id: raven.Rid, block: c_int, glow: c_int) void`

- `Rblock_editor_set_changed_callback()` (line 2129)
  - C: `void Rblock_editor_set_changed_callback(Rid id, RBlockEditorCallback callback, void* user_data);`
  - Zig: `export fn Rblock_editor_set_changed_callback(id: raven.Rid, callback: raven.RBlockEditorCallback, user_data: ?*anyopaque) void`

- `Rblock_editor_set_clicked_callback()` (line 2135)
  - C: `void Rblock_editor_set_clicked_callback(Rid id, RBlockEditorCallback callback, void* user_data);`
  - Zig: `export fn Rblock_editor_set_clicked_callback(id: raven.Rid, callback: raven.RBlockEditorCallback, user_data: ?*anyopaque) void`

- `Rblock_editor_set_context_callback()` (line 2141)
  - C: `void Rblock_editor_set_context_callback(Rid id, RBlockEditorContextCallback callback, void* user_data);`
  - Zig: `export fn Rblock_editor_set_context_callback(id: raven.Rid, callback: raven.RBlockEditorContextCallback, user_data: ?*anyopaque) void`

- `Rblock_editor_set_slot_options()` (line 2156)
  - C: `void Rblock_editor_set_slot_options(Rid id, const char* kind, int slot, const char* options);`
  - Zig: `export fn Rblock_editor_set_slot_options(id: raven.Rid, kind: [*c]const u8, slot: c_int, options: [*c]const u8) void`

- `Rblock_editor_set_kind_visible()` (line 2164)
  - C: `void Rblock_editor_set_kind_visible(Rid id, const char* kind, int visible);`
  - Zig: `export fn Rblock_editor_set_kind_visible(id: raven.Rid, kind: [*c]const u8, visible: c_int) void`

- `Rblock_editor_set_kind_label()` (line 2173)
  - C: `int Rblock_editor_set_kind_label(Rid id, const char* kind, const char* label);`
  - Zig: `export fn Rblock_editor_set_kind_label(id: raven.Rid, kind: [*c]const u8, label: [*c]const u8) c_int`

- `Rblock_editor_set_block_deletable()` (line 2217)
  - C: `void Rblock_editor_set_block_deletable(Rid id, int block, int deletable);`
  - Zig: `export fn Rblock_editor_set_block_deletable(id: raven.Rid, block: c_int, deletable: c_int) void`

- `Rblock_editor_get_selection_count()` (line 2224)
  - C: `int Rblock_editor_get_selection_count(Rid id);`
  - Zig: `export fn Rblock_editor_get_selection_count(id: raven.Rid) c_int`

- `Rblock_editor_get_selected()` (line 2229)
  - C: `int Rblock_editor_get_selected(Rid id, int index);`
  - Zig: `export fn Rblock_editor_get_selected(id: raven.Rid, index: c_int) c_int`

- `Rblock_editor_select()` (line 2241)
  - C: `void Rblock_editor_select(Rid id, int block, int add);`
  - Zig: `export fn Rblock_editor_select(id: raven.Rid, block: c_int, add: c_int) void`

- `Rblock_editor_get_view()` (line 2248)
  - C: `void Rblock_editor_get_view(Rid id, float* x, float* y, float* zoom);`
  - Zig: `export fn Rblock_editor_get_view(id: raven.Rid, x: [*c]f32, y: [*c]f32, zoom: [*c]f32) void`

- `Rblock_editor_set_view()` (line 2255)
  - C: `void Rblock_editor_set_view(Rid id, float x, float y, float zoom);`
  - Zig: `export fn Rblock_editor_set_view(id: raven.Rid, x: f32, y: f32, zoom: f32) void`

- `Rblock_editor_save()` (line 2329)
  - C: `const char* Rblock_editor_save(Rid id);`
  - Zig: `export fn Rblock_editor_save(id: raven.Rid) [*c]const u8`

- `Rblock_editor_load()` (line 2479)
  - C: `int Rblock_editor_load(Rid id, const char* text);`
  - Zig: `export fn Rblock_editor_load(id: raven.Rid, text: [*c]const u8) c_int`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_clock_seconds`, `rvn_paint_box`, `rvn_paint_box4`, `rvn_paint_keep_animating`, `rvn_paint_line`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_shadow`, `rvn_paint_spring`, `rvn_paint_spring_from`, `rvn_paint_text_in`, `rvn_paint_triangle`, `rvn_parse_bool`, `rvn_parse_color`, `rvn_parse_float`, `rvn_spring_set`, `rvn_widget_add_child`, `rvn_widget_arrange`, `rvn_widget_capture_mouse`, `rvn_widget_check`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_fire_action`, `rvn_widget_focus`, `rvn_widget_from_virtual`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_release_mouse`, `rvn_xml_attribute`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_fade`, `rvn_color_mix`, `rvn_color_to_floats`, `rvn_error`, `rvn_free`, `rvn_hash_str`, `rvn_hex`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rgba`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_strndup`, `rvn_text_add`, `rvn_text_append`, `rvn_text_printf`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_text_width`

Includes: `common.h`, `../xml/xml.h`


## widgets/dock_area.c  (2143 lines) -> zig/src/widgets/dock_area.zig

Exports (24):

- `rvn_class_dock_area` global (line 1866)
  - C: `const rvn_widget_class_t rvn_class_dock_area;`
  - Zig: `export const rvn_class_dock_area: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rdock_area_create()` (line 1887)
  - C: `Rid Rdock_area_create(void);`
  - Zig: `export fn Rdock_area_create() raven.Rid`

- `Rdock_area_move_panel()` (line 1932)
  - C: `void Rdock_area_move_panel(Rid id, Rid panel_id, RDockSide side, Rid relative_id, float size);`
  - Zig: `export fn Rdock_area_move_panel(id: raven.Rid, panel_id: raven.Rid, side: raven.RDockSide, relative_id: raven.Rid, size: f32) void`

- `Rdock_area_add_panel()` (line 1956)
  - C: `void Rdock_area_add_panel(Rid id, Rid panel_id, const char* title, RDockSide side, Rid relative_id, float size);`
  - Zig: `export fn Rdock_area_add_panel(id: raven.Rid, panel_id: raven.Rid, title: [*c]const u8, side: raven.RDockSide, relative_id: raven.Rid, size: f32) void`

- `Rdock_area_close_panel()` (line 1982)
  - C: `void Rdock_area_close_panel(Rid id, Rid panel_id);`
  - Zig: `export fn Rdock_area_close_panel(id: raven.Rid, panel_id: raven.Rid) void`

- `Rdock_area_set_panel_title()` (line 1989)
  - C: `void Rdock_area_set_panel_title(Rid id, Rid panel_id, const char* title);`
  - Zig: `export fn Rdock_area_set_panel_title(id: raven.Rid, panel_id: raven.Rid, title: [*c]const u8) void`

- `Rdock_area_set_panel_icon()` (line 1996)
  - C: `void Rdock_area_set_panel_icon(Rid id, Rid panel_id, Rid texture, float u0, float v0, float u1, float v1, int tint);`
  - Zig: `export fn Rdock_area_set_panel_icon(id: raven.Rid, panel_id: raven.Rid, texture: raven.Rid, u0: f32, v0: f32, u1: f32, v1: f32, tint: c_int) void`

- `Rdock_area_set_panel_closable()` (line 2011)
  - C: `void Rdock_area_set_panel_closable(Rid id, Rid panel_id, int closable);`
  - Zig: `export fn Rdock_area_set_panel_closable(id: raven.Rid, panel_id: raven.Rid, closable: c_int) void`

- `Rdock_area_show_panel()` (line 2020)
  - C: `void Rdock_area_show_panel(Rid id, Rid panel_id);`
  - Zig: `export fn Rdock_area_show_panel(id: raven.Rid, panel_id: raven.Rid) void`

- `Rdock_area_is_panel_shown()` (line 2031)
  - C: `int Rdock_area_is_panel_shown(Rid id, Rid panel_id);`
  - Zig: `export fn Rdock_area_is_panel_shown(id: raven.Rid, panel_id: raven.Rid) c_int`

- `Rdock_area_set_movable()` (line 2038)
  - C: `void Rdock_area_set_movable(Rid id, int movable);`
  - Zig: `export fn Rdock_area_set_movable(id: raven.Rid, movable: c_int) void`

- `Rdock_area_save_layout()` (line 2043)
  - C: `const char* Rdock_area_save_layout(Rid id);`
  - Zig: `export fn Rdock_area_save_layout(id: raven.Rid) [*c]const u8`

- `Rdock_area_load_layout()` (line 2056)
  - C: `int Rdock_area_load_layout(Rid id, const char* layout);`
  - Zig: `export fn Rdock_area_load_layout(id: raven.Rid, layout: [*c]const u8) c_int`

- `Rdock_area_set_close_callback()` (line 2062)
  - C: `void Rdock_area_set_close_callback(Rid id, RDockCloseCallback callback, void* user_data);`
  - Zig: `export fn Rdock_area_set_close_callback(id: raven.Rid, callback: raven.RDockCloseCallback, user_data: ?*anyopaque) void`

- `Rdock_area_set_changed_callback()` (line 2068)
  - C: `void Rdock_area_set_changed_callback(Rid id, RDockChangedCallback callback, void* user_data);`
  - Zig: `export fn Rdock_area_set_changed_callback(id: raven.Rid, callback: raven.RDockChangedCallback, user_data: ?*anyopaque) void`

- `Rdock_area_hide_panel()` (line 2074)
  - C: `void Rdock_area_hide_panel(Rid id, Rid panel_id);`
  - Zig: `export fn Rdock_area_hide_panel(id: raven.Rid, panel_id: raven.Rid) void`

- `Rdock_area_open_panel()` (line 2081)
  - C: `void Rdock_area_open_panel(Rid id, Rid panel_id);`
  - Zig: `export fn Rdock_area_open_panel(id: raven.Rid, panel_id: raven.Rid) void`

- `Rdock_area_is_panel_open()` (line 2088)
  - C: `int Rdock_area_is_panel_open(Rid id, Rid panel_id);`
  - Zig: `export fn Rdock_area_is_panel_open(id: raven.Rid, panel_id: raven.Rid) c_int`

- `Rdock_area_set_close_hides()` (line 2095)
  - C: `void Rdock_area_set_close_hides(Rid id, int hides);`
  - Zig: `export fn Rdock_area_set_close_hides(id: raven.Rid, hides: c_int) void`

- `Rdock_area_set_tearable()` (line 2104)
  - C: `void Rdock_area_set_tearable(Rid id, int tearable);`
  - Zig: `export fn Rdock_area_set_tearable(id: raven.Rid, tearable: c_int) void`

- `Rdock_area_is_tearable()` (line 2109)
  - C: `int Rdock_area_is_tearable(Rid id);`
  - Zig: `export fn Rdock_area_is_tearable(id: raven.Rid) c_int`

- `Rdock_area_float_panel()` (line 2114)
  - C: `Rid Rdock_area_float_panel(Rid id, Rid panel_id, int x, int y);`
  - Zig: `export fn Rdock_area_float_panel(id: raven.Rid, panel_id: raven.Rid, x: c_int, y: c_int) raven.Rid`

- `Rdock_area_dock_panel()` (line 2130)
  - C: `void Rdock_area_dock_panel(Rid id, Rid panel_id);`
  - Zig: `export fn Rdock_area_dock_panel(id: raven.Rid, panel_id: raven.Rid) void`

- `Rdock_area_get_panel_window()` (line 2137)
  - C: `Rid Rdock_area_get_panel_window(Rid id, Rid panel_id);`
  - Zig: `export fn Rdock_area_get_panel_window(id: raven.Rid, panel_id: raven.Rid) raven.Rid`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_drawlist_transform`, `rvn_paint_box`, `rvn_paint_box4`, `rvn_paint_glass`, `rvn_paint_icon`, `rvn_paint_image`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_shadow`, `rvn_paint_spring`, `rvn_paint_spring_from`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_spring_moving`, `rvn_spring_set`, `rvn_widget_add_child`, `rvn_widget_animate_layout`, `rvn_widget_arrange`, `rvn_widget_arrange_slot`, `rvn_widget_capture_mouse`, `rvn_widget_check`, `rvn_widget_child_index`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_destroy`, `rvn_widget_forget_layout_spring`, `rvn_widget_get`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_is_inside`, `rvn_widget_is_shown`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_play_transition`, `rvn_widget_release_mouse`, `rvn_widget_text_color`, `rvn_window_forget_widget`

From `core/base_h.zig` (`base.<name>`): `rvn_calloc`, `rvn_clampf`, `rvn_color_a`, `rvn_color_fade`, `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rect_contains`, `rvn_rgba`, `rvn_str_set`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_glass_style`, `rvn_paint_surface`, `rvn_widget_font_size`, `rvn_widget_text_width`

Includes: `common.h`


## widgets/timeline.c  (1872 lines) -> zig/src/widgets/timeline.zig

Exports (50):

- `rvn_class_timeline` global (line 1464)
  - C: `const rvn_widget_class_t rvn_class_timeline;`
  - Zig: `export const rvn_class_timeline: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rtimeline_create()` (line 1492)
  - C: `Rid Rtimeline_create(void);`
  - Zig: `export fn Rtimeline_create() raven.Rid`

- `Rtimeline_set_duration()` (line 1499)
  - C: `void Rtimeline_set_duration(Rid id, double seconds);`
  - Zig: `export fn Rtimeline_set_duration(id: raven.Rid, seconds: f64) void`

- `Rtimeline_get_duration()` (line 1513)
  - C: `double Rtimeline_get_duration(Rid id);`
  - Zig: `export fn Rtimeline_get_duration(id: raven.Rid) f64`

- `Rtimeline_set_time()` (line 1518)
  - C: `void Rtimeline_set_time(Rid id, double seconds);`
  - Zig: `export fn Rtimeline_set_time(id: raven.Rid, seconds: f64) void`

- `Rtimeline_get_time()` (line 1523)
  - C: `double Rtimeline_get_time(Rid id);`
  - Zig: `export fn Rtimeline_get_time(id: raven.Rid) f64`

- `Rtimeline_set_frame_rate()` (line 1528)
  - C: `void Rtimeline_set_frame_rate(Rid id, double frames_per_second);`
  - Zig: `export fn Rtimeline_set_frame_rate(id: raven.Rid, frames_per_second: f64) void`

- `Rtimeline_get_frame_rate()` (line 1534)
  - C: `double Rtimeline_get_frame_rate(Rid id);`
  - Zig: `export fn Rtimeline_get_frame_rate(id: raven.Rid) f64`

- `Rtimeline_set_snapping()` (line 1539)
  - C: `void Rtimeline_set_snapping(Rid id, int enabled);`
  - Zig: `export fn Rtimeline_set_snapping(id: raven.Rid, enabled: c_int) void`

- `Rtimeline_set_view()` (line 1544)
  - C: `void Rtimeline_set_view(Rid id, double start, double end);`
  - Zig: `export fn Rtimeline_set_view(id: raven.Rid, start: f64, end: f64) void`

- `Rtimeline_get_view()` (line 1553)
  - C: `void Rtimeline_get_view(Rid id, double* start, double* end);`
  - Zig: `export fn Rtimeline_get_view(id: raven.Rid, start: [*c]f64, end: [*c]f64) void`

- `Rtimeline_set_playing()` (line 1559)
  - C: `void Rtimeline_set_playing(Rid id, int playing);`
  - Zig: `export fn Rtimeline_set_playing(id: raven.Rid, playing: c_int) void`

- `Rtimeline_is_playing()` (line 1564)
  - C: `int Rtimeline_is_playing(Rid id);`
  - Zig: `export fn Rtimeline_is_playing(id: raven.Rid) c_int`

- `Rtimeline_set_loop()` (line 1569)
  - C: `void Rtimeline_set_loop(Rid id, int loop);`
  - Zig: `export fn Rtimeline_set_loop(id: raven.Rid, loop: c_int) void`

- `Rtimeline_add_track()` (line 1576)
  - C: `int Rtimeline_add_track(Rid id, const char* name);`
  - Zig: `export fn Rtimeline_add_track(id: raven.Rid, name: [*c]const u8) c_int`

- `Rtimeline_remove_track()` (line 1589)
  - C: `void Rtimeline_remove_track(Rid id, int track_id);`
  - Zig: `export fn Rtimeline_remove_track(id: raven.Rid, track_id: c_int) void`

- `Rtimeline_get_track_count()` (line 1607)
  - C: `int Rtimeline_get_track_count(Rid id);`
  - Zig: `export fn Rtimeline_get_track_count(id: raven.Rid) c_int`

- `Rtimeline_get_track()` (line 1612)
  - C: `int Rtimeline_get_track(Rid id, int index);`
  - Zig: `export fn Rtimeline_get_track(id: raven.Rid, index: c_int) c_int`

- `Rtimeline_set_track_name()` (line 1617)
  - C: `void Rtimeline_set_track_name(Rid id, int track_id, const char* name);`
  - Zig: `export fn Rtimeline_set_track_name(id: raven.Rid, track_id: c_int, name: [*c]const u8) void`

- `Rtimeline_get_track_name()` (line 1624)
  - C: `const char* Rtimeline_get_track_name(Rid id, int track_id);`
  - Zig: `export fn Rtimeline_get_track_name(id: raven.Rid, track_id: c_int) [*c]const u8`

- `Rtimeline_set_track_color()` (line 1631)
  - C: `void Rtimeline_set_track_color(Rid id, int track_id, float r, float g, float b);`
  - Zig: `export fn Rtimeline_set_track_color(id: raven.Rid, track_id: c_int, r: f32, g: f32, b: f32) void`

- `Rtimeline_set_track_height()` (line 1641)
  - C: `void Rtimeline_set_track_height(Rid id, int track_id, float height);`
  - Zig: `export fn Rtimeline_set_track_height(id: raven.Rid, track_id: c_int, height: f32) void`

- `Rtimeline_set_track_locked()` (line 1651)
  - C: `void Rtimeline_set_track_locked(Rid id, int track_id, int locked);`
  - Zig: `export fn Rtimeline_set_track_locked(id: raven.Rid, track_id: c_int, locked: c_int) void`

- `Rtimeline_set_track_muted()` (line 1660)
  - C: `void Rtimeline_set_track_muted(Rid id, int track_id, int muted);`
  - Zig: `export fn Rtimeline_set_track_muted(id: raven.Rid, track_id: c_int, muted: c_int) void`

- `Rtimeline_is_track_muted()` (line 1669)
  - C: `int Rtimeline_is_track_muted(Rid id, int track_id);`
  - Zig: `export fn Rtimeline_is_track_muted(id: raven.Rid, track_id: c_int) c_int`

- `Rtimeline_add_clip()` (line 1678)
  - C: `int Rtimeline_add_clip(Rid id, int track, double start, double length, const char* label);`
  - Zig: `export fn Rtimeline_add_clip(id: raven.Rid, track: c_int, start: f64, length: f64, label: [*c]const u8) c_int`

- `Rtimeline_add_key()` (line 1687)
  - C: `int Rtimeline_add_key(Rid id, int track, double time);`
  - Zig: `export fn Rtimeline_add_key(id: raven.Rid, track: c_int, time: f64) c_int`

- `Rtimeline_add_marker()` (line 1696)
  - C: `int Rtimeline_add_marker(Rid id, double time, const char* label);`
  - Zig: `export fn Rtimeline_add_marker(id: raven.Rid, time: f64, label: [*c]const u8) c_int`

- `Rtimeline_remove_item()` (line 1701)
  - C: `void Rtimeline_remove_item(Rid id, int item_id);`
  - Zig: `export fn Rtimeline_remove_item(id: raven.Rid, item_id: c_int) void`

- `Rtimeline_clear()` (line 1713)
  - C: `void Rtimeline_clear(Rid id);`
  - Zig: `export fn Rtimeline_clear(id: raven.Rid) void`

- `Rtimeline_get_item_type()` (line 1721)
  - C: `RTimelineItem Rtimeline_get_item_type(Rid id, int item_id);`
  - Zig: `export fn Rtimeline_get_item_type(id: raven.Rid, item_id: c_int) raven.RTimelineItem`

- `Rtimeline_get_item_track()` (line 1728)
  - C: `int Rtimeline_get_item_track(Rid id, int item_id);`
  - Zig: `export fn Rtimeline_get_item_track(id: raven.Rid, item_id: c_int) c_int`

- `Rtimeline_get_item_start()` (line 1735)
  - C: `double Rtimeline_get_item_start(Rid id, int item_id);`
  - Zig: `export fn Rtimeline_get_item_start(id: raven.Rid, item_id: c_int) f64`

- `Rtimeline_get_item_length()` (line 1742)
  - C: `double Rtimeline_get_item_length(Rid id, int item_id);`
  - Zig: `export fn Rtimeline_get_item_length(id: raven.Rid, item_id: c_int) f64`

- `Rtimeline_set_item()` (line 1749)
  - C: `void Rtimeline_set_item(Rid id, int item_id, int track, double start, double length);`
  - Zig: `export fn Rtimeline_set_item(id: raven.Rid, item_id: c_int, track: c_int, start: f64, length: f64) void`

- `Rtimeline_set_item_label()` (line 1766)
  - C: `void Rtimeline_set_item_label(Rid id, int item_id, const char* label);`
  - Zig: `export fn Rtimeline_set_item_label(id: raven.Rid, item_id: c_int, label: [*c]const u8) void`

- `Rtimeline_get_item_label()` (line 1773)
  - C: `const char* Rtimeline_get_item_label(Rid id, int item_id);`
  - Zig: `export fn Rtimeline_get_item_label(id: raven.Rid, item_id: c_int) [*c]const u8`

- `Rtimeline_set_item_color()` (line 1780)
  - C: `void Rtimeline_set_item_color(Rid id, int item_id, float r, float g, float b);`
  - Zig: `export fn Rtimeline_set_item_color(id: raven.Rid, item_id: c_int, r: f32, g: f32, b: f32) void`

- `Rtimeline_get_item_count()` (line 1790)
  - C: `int Rtimeline_get_item_count(Rid id);`
  - Zig: `export fn Rtimeline_get_item_count(id: raven.Rid) c_int`

- `Rtimeline_get_item()` (line 1795)
  - C: `int Rtimeline_get_item(Rid id, int index);`
  - Zig: `export fn Rtimeline_get_item(id: raven.Rid, index: c_int) c_int`

- `Rtimeline_select()` (line 1802)
  - C: `void Rtimeline_select(Rid id, int item_id, int add);`
  - Zig: `export fn Rtimeline_select(id: raven.Rid, item_id: c_int, add: c_int) void`

- `Rtimeline_clear_selection()` (line 1812)
  - C: `void Rtimeline_clear_selection(Rid id);`
  - Zig: `export fn Rtimeline_clear_selection(id: raven.Rid) void`

- `Rtimeline_is_selected()` (line 1818)
  - C: `int Rtimeline_is_selected(Rid id, int item_id);`
  - Zig: `export fn Rtimeline_is_selected(id: raven.Rid, item_id: c_int) c_int`

- `Rtimeline_get_selection_count()` (line 1825)
  - C: `int Rtimeline_get_selection_count(Rid id);`
  - Zig: `export fn Rtimeline_get_selection_count(id: raven.Rid) c_int`

- `Rtimeline_get_selected()` (line 1833)
  - C: `int Rtimeline_get_selected(Rid id, int index);`
  - Zig: `export fn Rtimeline_get_selected(id: raven.Rid, index: c_int) c_int`

- `Rtimeline_set_time_callback()` (line 1844)
  - C: `void Rtimeline_set_time_callback(Rid id, RTimelineTimeCallback callback, void* user_data);`
  - Zig: `export fn Rtimeline_set_time_callback(id: raven.Rid, callback: raven.RTimelineTimeCallback, user_data: ?*anyopaque) void`

- `Rtimeline_set_changed_callback()` (line 1850)
  - C: `void Rtimeline_set_changed_callback(Rid id, RTimelineItemCallback callback, void* user_data);`
  - Zig: `export fn Rtimeline_set_changed_callback(id: raven.Rid, callback: raven.RTimelineItemCallback, user_data: ?*anyopaque) void`

- `Rtimeline_set_selection_callback()` (line 1856)
  - C: `void Rtimeline_set_selection_callback(Rid id, RTimelineItemCallback callback, void* user_data);`
  - Zig: `export fn Rtimeline_set_selection_callback(id: raven.Rid, callback: raven.RTimelineItemCallback, user_data: ?*anyopaque) void`

- `Rtimeline_set_activated_callback()` (line 1862)
  - C: `void Rtimeline_set_activated_callback(Rid id, RTimelineItemCallback callback, void* user_data);`
  - Zig: `export fn Rtimeline_set_activated_callback(id: raven.Rid, callback: raven.RTimelineItemCallback, user_data: ?*anyopaque) void`

- `Rtimeline_set_removed_callback()` (line 1868)
  - C: `void Rtimeline_set_removed_callback(Rid id, RTimelineItemCallback callback, void* user_data);`
  - Zig: `export fn Rtimeline_set_removed_callback(id: raven.Rid, callback: raven.RTimelineItemCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_clock_seconds`, `rvn_font_metrics`, `rvn_font_resolve`, `rvn_paint_box`, `rvn_paint_box4`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_shadow`, `rvn_paint_spring`, `rvn_paint_text`, `rvn_paint_text_in`, `rvn_paint_triangle`, `rvn_parse_bool`, `rvn_parse_color`, `rvn_parse_float`, `rvn_spring_set`, `rvn_text_width`, `rvn_widget_capture_mouse`, `rvn_widget_check`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_fire_action`, `rvn_widget_get`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_release_mouse`, `rvn_widget_text_color`, `rvn_xml_attribute`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_clampi`, `rvn_color_fade`, `rvn_color_mix`, `rvn_color_to_floats`, `rvn_error`, `rvn_free`, `rvn_hex`, `rvn_maxf`, `rvn_maxi`, `rvn_minf`, `rvn_rect`, `rvn_rect_contains`, `rvn_rgba`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_focus`, `rvn_scrollbar_clamp`, `rvn_scrollbar_event`, `rvn_scrollbar_needed`, `rvn_scrollbar_paint`, `rvn_scrollbar_set`, `rvn_scrollbar_wheel`, `rvn_widget_alive`, `rvn_widget_font_size`

Includes: `common.h`, `../xml/xml.h`


## widgets/markdown.c  (1648 lines) -> zig/src/widgets/markdown.zig

Exports (8):

- `rvn_md_parse()` (line 728)
  - C: `rvn_md_t* rvn_md_parse(const char* source);`
  - Zig: `export fn rvn_md_parse(source: [*c]const u8) [*c]common.rvn_md_t`

- `rvn_md_free()` (line 1037)
  - C: `void rvn_md_free(rvn_md_t* md);`
  - Zig: `export fn rvn_md_free(md: [*c]common.rvn_md_t) void`

- `rvn_md_layout()` (line 1374)
  - C: `rvn_vec2_t rvn_md_layout(rvn_md_t* md, const rvn_widget_t* widget, Rid font, float size, float width);`
  - Zig: `export fn rvn_md_layout(md: [*c]common.rvn_md_t, widget: [*c]const common.rvn_widget_t, font: raven.Rid, size: f32, width: f32) base.rvn_vec2_t`

- `rvn_md_paint()` (line 1531)
  - C: `void rvn_md_paint(const rvn_md_t* md, const rvn_widget_t* widget, RPainter* painter, float ox, float oy, rvn_color_t color, int hot_link);`
  - Zig: `export fn rvn_md_paint(md: [*c]const common.rvn_md_t, widget: [*c]const common.rvn_widget_t, painter: ?*raven.RPainter, ox: f32, oy: f32, color: base.rvn_color_t, hot_link: c_int) void`

- `rvn_md_link_at()` (line 1604)
  - C: `int rvn_md_link_at(const rvn_md_t* md, float x, float y);`
  - Zig: `export fn rvn_md_link_at(md: [*c]const common.rvn_md_t, x: f32, y: f32) c_int`

- `rvn_md_link()` (line 1614)
  - C: `const char* rvn_md_link(const rvn_md_t* md, int link);`
  - Zig: `export fn rvn_md_link(md: [*c]const common.rvn_md_t, link: c_int) [*c]const u8`

- `rvn_md_link_count()` (line 1618)
  - C: `int rvn_md_link_count(const rvn_md_t* md);`
  - Zig: `export fn rvn_md_link_count(md: [*c]const common.rvn_md_t) c_int`

- `rvn_md_plain_text()` (line 1622)
  - C: `void rvn_md_plain_text(const rvn_md_t* md, rvn_text_t* out);`
  - Zig: `export fn rvn_md_plain_text(md: [*c]const common.rvn_md_t, out: [*c]base.rvn_text_t) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_font_metrics`, `rvn_font_resolve`, `rvn_font_variant`, `rvn_paint_box`, `rvn_paint_icon`, `rvn_paint_image`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_text`, `rvn_text_width`, `rvn_widget_color`

From `core/base_h.zig` (`base.<name>`): `rvn_calloc`, `rvn_clampi`, `rvn_color_fade`, `rvn_free`, `rvn_hex`, `rvn_maxf`, `rvn_mini`, `rvn_rect`, `rvn_strndup`, `rvn_text_add`, `rvn_text_append`, `rvn_utf8_encode`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_language_find`, `rvn_syntax_color`, `rvn_syntax_line`, `rvn_xml_texture`

Includes: `common.h`


## widgets/syntax.c  (1375 lines) -> zig/src/widgets/syntax.zig

Exports (17):

- `rvn_syntax_line()` (line 869)
  - C: `uint8_t rvn_syntax_line(const rvn_language_t* language, const char* text, int length, uint8_t state, rvn_span_t* spans, int max, int* count);`
  - Zig: `export fn rvn_syntax_line(language: [*c]const common.rvn_language_t, text: [*c]const u8, length: c_int, state: u8, spans: [*c]common.rvn_span_t, max: c_int, count: [*c]c_int) u8`

- `rvn_syntax_color()` (line 887)
  - C: `rvn_color_t rvn_syntax_color(const rvn_theme_t* theme, rvn_token_t token, rvn_color_t text);`
  - Zig: `export fn rvn_syntax_color(theme: [*c]const common.rvn_theme_t, token: common.rvn_token_t, text: base.rvn_color_t) base.rvn_color_t`

- `rvn_token_public()` (line 912)
  - C: `RToken rvn_token_public(rvn_token_t token);`
  - Zig: `export fn rvn_token_public(token: common.rvn_token_t) raven.RToken`

- `Rtheme_set_token_color()` (line 927)
  - C: `void Rtheme_set_token_color(RToken token, float r, float g, float b, float a);`
  - Zig: `export fn Rtheme_set_token_color(token: raven.RToken, r: f32, g: f32, b: f32, a: f32) void`

- `Rtheme_get_token_color()` (line 939)
  - C: `void Rtheme_get_token_color(RToken token, float* r, float* g, float* b, float* a);`
  - Zig: `export fn Rtheme_get_token_color(token: raven.RToken, r: [*c]f32, g: [*c]f32, b: [*c]f32, a: [*c]f32) void`

- `Rtheme_clear_token_colors()` (line 948)
  - C: `void Rtheme_clear_token_colors(void);`
  - Zig: `export fn Rtheme_clear_token_colors() void`

- `rvn_language_desc()` (line 954)
  - C: `const RLanguageDesc* rvn_language_desc(const rvn_language_t* language);`
  - Zig: `export fn rvn_language_desc(language: [*c]const common.rvn_language_t) [*c]const raven.RLanguageDesc`

- `rvn_language_generation()` (line 958)
  - C: `uint32_t rvn_language_generation(void);`
  - Zig: `export fn rvn_language_generation() u32`

- `rvn_language_word_count()` (line 962)
  - C: `int rvn_language_word_count(const rvn_language_t* language, int list);`
  - Zig: `export fn rvn_language_word_count(language: [*c]const common.rvn_language_t, list: c_int) c_int`

- `rvn_language_word()` (line 966)
  - C: `const char* rvn_language_word(const rvn_language_t* language, int list, int index);`
  - Zig: `export fn rvn_language_word(language: [*c]const common.rvn_language_t, list: c_int, index: c_int) [*c]const u8`

- `rvn_languages_shutdown()` (line 1277)
  - C: `void rvn_languages_shutdown(void);`
  - Zig: `export fn rvn_languages_shutdown() void`

- `rvn_language_find()` (line 1299)
  - C: `const rvn_language_t* rvn_language_find(const char* name);`
  - Zig: `export fn rvn_language_find(name: [*c]const u8) [*c]const common.rvn_language_t`

- `Rlanguage_register()` (line 1324)
  - C: `int Rlanguage_register(const RLanguageDesc* desc);`
  - Zig: `export fn Rlanguage_register(desc: [*c]const raven.RLanguageDesc) c_int`

- `Rlanguage_get()` (line 1336)
  - C: `int Rlanguage_get(const char* name, RLanguageDesc* desc);`
  - Zig: `export fn Rlanguage_get(name: [*c]const u8, desc: [*c]raven.RLanguageDesc) c_int`

- `Rlanguage_get_count()` (line 1346)
  - C: `int Rlanguage_get_count(void);`
  - Zig: `export fn Rlanguage_get_count() c_int`

- `Rlanguage_get_name()` (line 1352)
  - C: `const char* Rlanguage_get_name(int index);`
  - Zig: `export fn Rlanguage_get_name(index: c_int) [*c]const u8`

- `Rlanguage_for_file()` (line 1359)
  - C: `const char* Rlanguage_for_file(const char* path);`
  - Zig: `export fn Rlanguage_for_file(path: [*c]const u8) [*c]const u8`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_repaint_all_windows`

From `core/base_h.zig` (`base.<name>`): `rvn_arena_alloc`, `rvn_arena_free`, `rvn_arena_init`, `rvn_arena_strndup`, `rvn_calloc`, `rvn_color_a`, `rvn_color_fade`, `rvn_color_to_floats`, `rvn_error`, `rvn_free`, `rvn_hex`, `rvn_rgba`, `rvn_stricmp`, `rvn_strnicmp`, `rvn_utf8_next`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/file_browser.c  (1300 lines) -> zig/src/widgets/file_browser.zig

Exports (19):

- `rvn_class_file_browser` global (line 1150)
  - C: `const rvn_widget_class_t rvn_class_file_browser;`
  - Zig: `export const rvn_class_file_browser: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rfile_browser_create()` (line 1169)
  - C: `Rid Rfile_browser_create(void);`
  - Zig: `export fn Rfile_browser_create() raven.Rid`

- `Rfile_browser_set_mode()` (line 1176)
  - C: `void Rfile_browser_set_mode(Rid id, RFileBrowserMode mode);`
  - Zig: `export fn Rfile_browser_set_mode(id: raven.Rid, mode: raven.RFileBrowserMode) void`

- `Rfile_browser_set_directory()` (line 1185)
  - C: `int Rfile_browser_set_directory(Rid id, const char* path);`
  - Zig: `export fn Rfile_browser_set_directory(id: raven.Rid, path: [*c]const u8) c_int`

- `Rfile_browser_get_directory()` (line 1197)
  - C: `const char* Rfile_browser_get_directory(Rid id);`
  - Zig: `export fn Rfile_browser_get_directory(id: raven.Rid) [*c]const u8`

- `Rfile_browser_refresh()` (line 1202)
  - C: `void Rfile_browser_refresh(Rid id);`
  - Zig: `export fn Rfile_browser_refresh(id: raven.Rid) void`

- `Rfile_browser_set_filters()` (line 1207)
  - C: `void Rfile_browser_set_filters(Rid id, const RFileFilter* filters, int count);`
  - Zig: `export fn Rfile_browser_set_filters(id: raven.Rid, filters: [*c]const raven.RFileFilter, count: c_int) void`

- `Rfile_browser_set_show_hidden()` (line 1212)
  - C: `void Rfile_browser_set_show_hidden(Rid id, int show);`
  - Zig: `export fn Rfile_browser_set_show_hidden(id: raven.Rid, show: c_int) void`

- `Rfile_browser_set_multiple()` (line 1218)
  - C: `void Rfile_browser_set_multiple(Rid id, int multiple);`
  - Zig: `export fn Rfile_browser_set_multiple(id: raven.Rid, multiple: c_int) void`

- `Rfile_browser_set_controls_visible()` (line 1223)
  - C: `void Rfile_browser_set_controls_visible(Rid id, int visible);`
  - Zig: `export fn Rfile_browser_set_controls_visible(id: raven.Rid, visible: c_int) void`

- `Rfile_browser_set_places_visible()` (line 1229)
  - C: `void Rfile_browser_set_places_visible(Rid id, int visible);`
  - Zig: `export fn Rfile_browser_set_places_visible(id: raven.Rid, visible: c_int) void`

- `Rfile_browser_set_file_name()` (line 1235)
  - C: `void Rfile_browser_set_file_name(Rid id, const char* name);`
  - Zig: `export fn Rfile_browser_set_file_name(id: raven.Rid, name: [*c]const u8) void`

- `Rfile_browser_set_default_extension()` (line 1240)
  - C: `void Rfile_browser_set_default_extension(Rid id, const char* extension);`
  - Zig: `export fn Rfile_browser_set_default_extension(id: raven.Rid, extension: [*c]const u8) void`

- `Rfile_browser_get_selection_count()` (line 1255)
  - C: `int Rfile_browser_get_selection_count(Rid id);`
  - Zig: `export fn Rfile_browser_get_selection_count(id: raven.Rid) c_int`

- `Rfile_browser_get_selection()` (line 1261)
  - C: `const char* Rfile_browser_get_selection(Rid id, int index);`
  - Zig: `export fn Rfile_browser_get_selection(id: raven.Rid, index: c_int) [*c]const u8`

- `Rfile_browser_select()` (line 1270)
  - C: `void Rfile_browser_select(Rid id, const char* name);`
  - Zig: `export fn Rfile_browser_select(id: raven.Rid, name: [*c]const u8) void`

- `Rfile_browser_set_accepted_callback()` (line 1284)
  - C: `void Rfile_browser_set_accepted_callback(Rid id, RFileBrowserCallback callback, void* user_data);`
  - Zig: `export fn Rfile_browser_set_accepted_callback(id: raven.Rid, callback: raven.RFileBrowserCallback, user_data: ?*anyopaque) void`

- `Rfile_browser_set_cancelled_callback()` (line 1290)
  - C: `void Rfile_browser_set_cancelled_callback(Rid id, RFileBrowserCallback callback, void* user_data);`
  - Zig: `export fn Rfile_browser_set_cancelled_callback(id: raven.Rid, callback: raven.RFileBrowserCallback, user_data: ?*anyopaque) void`

- `Rfile_browser_set_selection_changed_callback()` (line 1296)
  - C: `void Rfile_browser_set_selection_changed_callback(Rid id, RFileBrowserCallback callback, void* user_data);`
  - Zig: `export fn Rfile_browser_set_selection_changed_callback(id: raven.Rid, callback: raven.RFileBrowserCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_clock_seconds`, `rvn_dir_free`, `rvn_dir_read`, `rvn_dispatch_begin`, `rvn_dispatch_end`, `rvn_drawlist_transform`, `rvn_fs_places`, `rvn_fs_places_free`, `rvn_paint_box`, `rvn_paint_chevron`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_path_absolute`, `rvn_path_child`, `rvn_path_exists`, `rvn_path_home`, `rvn_path_is_dir`, `rvn_path_name`, `rvn_path_parent`, `rvn_pattern_match`, `rvn_spring_kick`, `rvn_widget_add_child`, `rvn_widget_arrange`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_fire_action`, `rvn_widget_get`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_play_transition`, `rvn_widget_release_mouse`, `rvn_widget_set_attribute`, `rvn_widget_text_color`

From `core/base_h.zig` (`base.<name>`): `rvn_alloc`, `rvn_calloc`, `rvn_clampf`, `rvn_clampi`, `rvn_color_fade`, `rvn_color_mix`, `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_maxi`, `rvn_minf`, `rvn_mini`, `rvn_rect`, `rvn_rect_contains`, `rvn_rgba`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_strnicmp`, `rvn_utf8_encode`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_row`, `rvn_paint_surface`, `rvn_scrollbar_clamp`, `rvn_scrollbar_event`, `rvn_scrollbar_needed`, `rvn_scrollbar_paint`, `rvn_scrollbar_set`, `rvn_scrollbar_shown`, `rvn_scrollbar_wheel`, `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_text_width`

Includes: `common.h`, `../core/fs.h`


## widgets/color_picker.c  (1017 lines) -> zig/src/widgets/color_picker.zig

Exports (18):

- `Rcolor_hsv_to_rgb()` (line 72)
  - C: `void Rcolor_hsv_to_rgb(float hue, float saturation, float value, float* r, float* g, float* b);`
  - Zig: `export fn Rcolor_hsv_to_rgb(hue: f32, saturation: f32, value: f32, r: [*c]f32, g: [*c]f32, b: [*c]f32) void`

- `Rcolor_rgb_to_hsv()` (line 95)
  - C: `void Rcolor_rgb_to_hsv(float r, float g, float b, float* hue, float* saturation, float* value);`
  - Zig: `export fn Rcolor_rgb_to_hsv(r: f32, g: f32, b: f32, hue: [*c]f32, saturation: [*c]f32, value: [*c]f32) void`

- `rvn_class_color_picker` global (line 879)
  - C: `const rvn_widget_class_t rvn_class_color_picker;`
  - Zig: `export const rvn_class_color_picker: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rcolor_picker_create()` (line 906)
  - C: `Rid Rcolor_picker_create(void);`
  - Zig: `export fn Rcolor_picker_create() raven.Rid`

- `Rcolor_picker_set_color()` (line 913)
  - C: `void Rcolor_picker_set_color(Rid id, float r, float g, float b, float a);`
  - Zig: `export fn Rcolor_picker_set_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void`

- `Rcolor_picker_get_color()` (line 920)
  - C: `void Rcolor_picker_get_color(Rid id, float* r, float* g, float* b, float* a);`
  - Zig: `export fn Rcolor_picker_get_color(id: raven.Rid, r: [*c]f32, g: [*c]f32, b: [*c]f32, a: [*c]f32) void`

- `Rcolor_picker_set_hsv()` (line 930)
  - C: `void Rcolor_picker_set_hsv(Rid id, float hue, float saturation, float value);`
  - Zig: `export fn Rcolor_picker_set_hsv(id: raven.Rid, hue: f32, saturation: f32, value: f32) void`

- `Rcolor_picker_get_hsv()` (line 938)
  - C: `void Rcolor_picker_get_hsv(Rid id, float* hue, float* saturation, float* value);`
  - Zig: `export fn Rcolor_picker_get_hsv(id: raven.Rid, hue: [*c]f32, saturation: [*c]f32, value: [*c]f32) void`

- `Rcolor_picker_set_hex()` (line 945)
  - C: `int Rcolor_picker_set_hex(Rid id, const char* text);`
  - Zig: `export fn Rcolor_picker_set_hex(id: raven.Rid, text: [*c]const u8) c_int`

- `Rcolor_picker_get_hex()` (line 964)
  - C: `const char* Rcolor_picker_get_hex(Rid id);`
  - Zig: `export fn Rcolor_picker_get_hex(id: raven.Rid) [*c]const u8`

- `Rcolor_picker_set_alpha_enabled()` (line 969)
  - C: `void Rcolor_picker_set_alpha_enabled(Rid id, int enabled);`
  - Zig: `export fn Rcolor_picker_set_alpha_enabled(id: raven.Rid, enabled: c_int) void`

- `Rcolor_picker_set_previous_color()` (line 976)
  - C: `void Rcolor_picker_set_previous_color(Rid id, float r, float g, float b, float a);`
  - Zig: `export fn Rcolor_picker_set_previous_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void`

- `Rcolor_picker_add_swatch()` (line 985)
  - C: `void Rcolor_picker_add_swatch(Rid id, float r, float g, float b, float a);`
  - Zig: `export fn Rcolor_picker_add_swatch(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void`

- `Rcolor_picker_clear_swatches()` (line 991)
  - C: `void Rcolor_picker_clear_swatches(Rid id);`
  - Zig: `export fn Rcolor_picker_clear_swatches(id: raven.Rid) void`

- `Rcolor_picker_get_swatch_count()` (line 998)
  - C: `int Rcolor_picker_get_swatch_count(Rid id);`
  - Zig: `export fn Rcolor_picker_get_swatch_count(id: raven.Rid) c_int`

- `Rcolor_picker_set_popup()` (line 1003)
  - C: `void Rcolor_picker_set_popup(Rid id, int popup);`
  - Zig: `export fn Rcolor_picker_set_popup(id: raven.Rid, popup: c_int) void`

- `Rcolor_picker_set_compact()` (line 1008)
  - C: `void Rcolor_picker_set_compact(Rid id, int compact);`
  - Zig: `export fn Rcolor_picker_set_compact(id: raven.Rid, compact: c_int) void`

- `Rcolor_picker_set_changed_callback()` (line 1013)
  - C: `void Rcolor_picker_set_changed_callback(Rid id, RColorChangedCallback callback, void* user_data);`
  - Zig: `export fn Rcolor_picker_set_changed_callback(id: raven.Rid, callback: raven.RColorChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_paint_box`, `rvn_paint_box4`, `rvn_paint_image`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_shadow`, `rvn_parse_bool`, `rvn_parse_color`, `rvn_texture_create_raw`, `rvn_texture_get`, `rvn_widget_add_child`, `rvn_widget_arrange`, `rvn_widget_capture_mouse`, `rvn_widget_check`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_destroy`, `rvn_widget_fire_action`, `rvn_widget_get`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_release_mouse`, `rvn_widget_set_attribute`, `rvn_widget_set_color`, `rvn_window_close_popup`, `rvn_window_open_popup`

From `core/base_h.zig` (`base.<name>`): `rvn_alloc`, `rvn_clampf`, `rvn_color_a`, `rvn_color_fade`, `rvn_color_mix`, `rvn_color_to_floats`, `rvn_free`, `rvn_hex`, `rvn_maxf`, `rvn_maxi`, `rvn_minf`, `rvn_rect`, `rvn_rect_contains`, `rvn_rgba`, `rvn_str_set`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_control_radius`, `rvn_paint_focus`, `rvn_paint_surface`, `rvn_widget_alive`, `rvn_widget_hover`, `rvn_widget_press`, `rvn_widget_squash`

Includes: `common.h`, `../render/renderer.h`


## widgets/tree_view.c  (911 lines) -> zig/src/widgets/tree_view.zig

Exports (33):

- `rvn_class_tree_view` global (line 631)
  - C: `const rvn_widget_class_t rvn_class_tree_view;`
  - Zig: `export const rvn_class_tree_view: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rtree_view_add_item()` (line 649)
  - C: `Rid Rtree_view_add_item(Rid id, Rid parent_item, const char* text);`
  - Zig: `export fn Rtree_view_add_item(id: raven.Rid, parent_item: raven.Rid, text: [*c]const u8) raven.Rid`

- `Rtree_item_destroy()` (line 668)
  - C: `void Rtree_item_destroy(Rid id);`
  - Zig: `export fn Rtree_item_destroy(id: raven.Rid) void`

- `Rtree_view_clear_items()` (line 673)
  - C: `void Rtree_view_clear_items(Rid id);`
  - Zig: `export fn Rtree_view_clear_items(id: raven.Rid) void`

- `Rtree_item_is_valid()` (line 686)
  - C: `int Rtree_item_is_valid(Rid item);`
  - Zig: `export fn Rtree_item_is_valid(item: raven.Rid) c_int`

- `Rtree_item_set_text()` (line 690)
  - C: `void Rtree_item_set_text(Rid id, const char* text);`
  - Zig: `export fn Rtree_item_set_text(id: raven.Rid, text: [*c]const u8) void`

- `Rtree_item_get_text()` (line 695)
  - C: `const char* Rtree_item_get_text(Rid id);`
  - Zig: `export fn Rtree_item_get_text(id: raven.Rid) [*c]const u8`

- `Rtree_item_set_expanded()` (line 700)
  - C: `void Rtree_item_set_expanded(Rid id, int expanded);`
  - Zig: `export fn Rtree_item_set_expanded(id: raven.Rid, expanded: c_int) void`

- `Rtree_item_is_expanded()` (line 705)
  - C: `int Rtree_item_is_expanded(Rid id);`
  - Zig: `export fn Rtree_item_is_expanded(id: raven.Rid) c_int`

- `Rtree_item_set_user_handle()` (line 710)
  - C: `void Rtree_item_set_user_handle(Rid id, void* handle);`
  - Zig: `export fn Rtree_item_set_user_handle(id: raven.Rid, handle: ?*anyopaque) void`

- `Rtree_item_get_user_handle()` (line 715)
  - C: `void* Rtree_item_get_user_handle(Rid id);`
  - Zig: `export fn Rtree_item_get_user_handle(id: raven.Rid) ?*anyopaque`

- `Rtree_view_get_item_count()` (line 720)
  - C: `int Rtree_view_get_item_count(Rid id);`
  - Zig: `export fn Rtree_view_get_item_count(id: raven.Rid) c_int`

- `Rtree_view_get_item()` (line 725)
  - C: `Rid Rtree_view_get_item(Rid id, int index);`
  - Zig: `export fn Rtree_view_get_item(id: raven.Rid, index: c_int) raven.Rid`

- `Rtree_item_get_parent()` (line 732)
  - C: `Rid Rtree_item_get_parent(Rid id);`
  - Zig: `export fn Rtree_item_get_parent(id: raven.Rid) raven.Rid`

- `Rtree_item_get_child_count()` (line 738)
  - C: `int Rtree_item_get_child_count(Rid id);`
  - Zig: `export fn Rtree_item_get_child_count(id: raven.Rid) c_int`

- `Rtree_item_get_child()` (line 743)
  - C: `Rid Rtree_item_get_child(Rid id, int index);`
  - Zig: `export fn Rtree_item_get_child(id: raven.Rid, index: c_int) raven.Rid`

- `Rtree_view_set_selected_item()` (line 749)
  - C: `void Rtree_view_set_selected_item(Rid id, Rid item_id);`
  - Zig: `export fn Rtree_view_set_selected_item(id: raven.Rid, item_id: raven.Rid) void`

- `Rtree_view_get_selected_item()` (line 763)
  - C: `Rid Rtree_view_get_selected_item(Rid id);`
  - Zig: `export fn Rtree_view_get_selected_item(id: raven.Rid) raven.Rid`

- `Rtree_view_set_selection_changed_callback()` (line 769)
  - C: `void Rtree_view_set_selection_changed_callback(Rid id, RTreeEventCallback callback, void* user_data);`
  - Zig: `export fn Rtree_view_set_selection_changed_callback(id: raven.Rid, callback: raven.RTreeEventCallback, user_data: ?*anyopaque) void`

- `Rtree_view_set_activated_callback()` (line 775)
  - C: `void Rtree_view_set_activated_callback(Rid id, RTreeEventCallback callback, void* user_data);`
  - Zig: `export fn Rtree_view_set_activated_callback(id: raven.Rid, callback: raven.RTreeEventCallback, user_data: ?*anyopaque) void`

- `Rtree_item_set_icon()` (line 785)
  - C: `void Rtree_item_set_icon(Rid id, Rid texture, float u0, float v0, float u1, float v1);`
  - Zig: `export fn Rtree_item_set_icon(id: raven.Rid, texture: raven.Rid, u0: f32, v0: f32, u1: f32, v1: f32) void`

- `Rtree_item_set_text_color()` (line 796)
  - C: `void Rtree_item_set_text_color(Rid id, float r, float g, float b, float a);`
  - Zig: `export fn Rtree_item_set_text_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void`

- `Rtree_view_set_multi_select()` (line 803)
  - C: `void Rtree_view_set_multi_select(Rid id, int enabled);`
  - Zig: `export fn Rtree_view_set_multi_select(id: raven.Rid, enabled: c_int) void`

- `Rtree_item_set_selected()` (line 812)
  - C: `void Rtree_item_set_selected(Rid id, int selected);`
  - Zig: `export fn Rtree_item_set_selected(id: raven.Rid, selected: c_int) void`

- `Rtree_item_is_selected()` (line 828)
  - C: `int Rtree_item_is_selected(Rid id);`
  - Zig: `export fn Rtree_item_is_selected(id: raven.Rid) c_int`

- `Rtree_view_clear_selection()` (line 834)
  - C: `void Rtree_view_clear_selection(Rid id);`
  - Zig: `export fn Rtree_view_clear_selection(id: raven.Rid) void`

- `Rtree_view_get_selection_count()` (line 843)
  - C: `int Rtree_view_get_selection_count(Rid id);`
  - Zig: `export fn Rtree_view_get_selection_count(id: raven.Rid) c_int`

- `Rtree_view_get_selection()` (line 850)
  - C: `Rid Rtree_view_get_selection(Rid id, int index);`
  - Zig: `export fn Rtree_view_get_selection(id: raven.Rid, index: c_int) raven.Rid`

- `Rtree_view_set_context_callback()` (line 870)
  - C: `void Rtree_view_set_context_callback(Rid id, RTreeContextCallback callback, void* user_data);`
  - Zig: `export fn Rtree_view_set_context_callback(id: raven.Rid, callback: raven.RTreeContextCallback, user_data: ?*anyopaque) void`

- `Rtree_view_set_drag_type()` (line 876)
  - C: `void Rtree_view_set_drag_type(Rid id, const char* type);`
  - Zig: `export fn Rtree_view_set_drag_type(id: raven.Rid, @"type": [*c]const u8) void`

- `Rtree_view_get_item_at()` (line 883)
  - C: `Rid Rtree_view_get_item_at(Rid id, float local_x, float local_y);`
  - Zig: `export fn Rtree_view_get_item_at(id: raven.Rid, local_x: f32, local_y: f32) raven.Rid`

- `Rtree_view_set_drop_highlight()` (line 891)
  - C: `void Rtree_view_set_drop_highlight(Rid id, Rid item_id, int whole_tree);`
  - Zig: `export fn Rtree_view_set_drop_highlight(id: raven.Rid, item_id: raven.Rid, whole_tree: c_int) void`

- `Rtree_view_scroll_to_item()` (line 905)
  - C: `void Rtree_view_scroll_to_item(Rid id, Rid item_id);`
  - Zig: `export fn Rtree_view_scroll_to_item(id: raven.Rid, item_id: raven.Rid) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_api_check`, `rvn_paint_box`, `rvn_paint_icon`, `rvn_paint_image`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_pool_add`, `rvn_pool_get`, `rvn_pool_remove`, `rvn_widget_color`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_text_color`, `rvn_xml_attribute`

From `core/base_h.zig` (`base.<name>`): `rvn_alloc`, `rvn_calloc`, `rvn_clampi`, `rvn_color_a`, `rvn_color_fade`, `rvn_color_mix`, `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_maxi`, `rvn_mini`, `rvn_rect`, `rvn_rgba`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_row`, `rvn_scrollbar_clamp`, `rvn_scrollbar_event`, `rvn_scrollbar_needed`, `rvn_scrollbar_paint`, `rvn_scrollbar_set`, `rvn_scrollbar_shown`, `rvn_scrollbar_wheel`, `rvn_widget_alive`, `rvn_widget_font_size`

Includes: `common.h`, `../xml/xml.h`


## widgets/menu.c  (829 lines) -> zig/src/widgets/menu.zig

Exports (20):

- `rvn_parse_shortcut()` (line 108)
  - C: `int rvn_parse_shortcut(const char* text, RKey* key, uint32_t* modifiers);`
  - Zig: `export fn rvn_parse_shortcut(text: [*c]const u8, key: [*c]raven.RKey, modifiers: [*c]u32) c_int`

- `rvn_menu_item_trigger()` (line 166)
  - C: `void rvn_menu_item_trigger(rvn_widget_t* widget);`
  - Zig: `export fn rvn_menu_item_trigger(widget: [*c]common.rvn_widget_t) void`

- `rvn_class_menu_item` global (line 205)
  - C: `const rvn_widget_class_t rvn_class_menu_item;`
  - Zig: `export const rvn_class_menu_item: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `rvn_menu_popup()` (line 508)
  - C: `void rvn_menu_popup(rvn_widget_t* menu, rvn_window_t* window, float x, float y);`
  - Zig: `export fn rvn_menu_popup(menu: [*c]common.rvn_widget_t, window: [*c]common.rvn_window_t, x: f32, y: f32) void`

- `rvn_class_menu` global (line 542)
  - C: `const rvn_widget_class_t rvn_class_menu;`
  - Zig: `export const rvn_class_menu: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `rvn_menu_find_shortcut()` (line 561)
  - C: `rvn_widget_t* rvn_menu_find_shortcut(rvn_widget_t* root, RKey key, uint32_t modifiers);`
  - Zig: `export fn rvn_menu_find_shortcut(root: [*c]common.rvn_widget_t, key: raven.RKey, modifiers: u32) [*c]common.rvn_widget_t`

- `rvn_class_menu_bar` global (line 718)
  - C: `const rvn_widget_class_t rvn_class_menu_bar;`
  - Zig: `export const rvn_class_menu_bar: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rmenu_add_menu()` (line 735)
  - C: `Rid Rmenu_add_menu(Rid id, const char* title);`
  - Zig: `export fn Rmenu_add_menu(id: raven.Rid, title: [*c]const u8) raven.Rid`

- `Rmenu_set_title()` (line 749)
  - C: `void Rmenu_set_title(Rid id, const char* title);`
  - Zig: `export fn Rmenu_set_title(id: raven.Rid, title: [*c]const u8) void`

- `Rmenu_add_item()` (line 754)
  - C: `Rid Rmenu_add_item(Rid id, const char* text);`
  - Zig: `export fn Rmenu_add_item(id: raven.Rid, text: [*c]const u8) raven.Rid`

- `Rmenu_add_separator()` (line 764)
  - C: `Rid Rmenu_add_separator(Rid id);`
  - Zig: `export fn Rmenu_add_separator(id: raven.Rid) raven.Rid`

- `Rmenu_item_set_text()` (line 771)
  - C: `void Rmenu_item_set_text(Rid id, const char* text);`
  - Zig: `export fn Rmenu_item_set_text(id: raven.Rid, text: [*c]const u8) void`

- `Rmenu_item_get_text()` (line 776)
  - C: `const char* Rmenu_item_get_text(Rid id);`
  - Zig: `export fn Rmenu_item_get_text(id: raven.Rid) [*c]const u8`

- `Rmenu_item_set_shortcut()` (line 781)
  - C: `void Rmenu_item_set_shortcut(Rid id, RKey key, Ruint modifiers);`
  - Zig: `export fn Rmenu_item_set_shortcut(id: raven.Rid, key: raven.RKey, modifiers: raven.Ruint) void`

- `Rmenu_item_set_checkable()` (line 786)
  - C: `void Rmenu_item_set_checkable(Rid id, int checkable);`
  - Zig: `export fn Rmenu_item_set_checkable(id: raven.Rid, checkable: c_int) void`

- `Rmenu_item_set_icon()` (line 791)
  - C: `void Rmenu_item_set_icon(Rid id, Rid texture, float u0, float v0, float u1, float v1, int tint);`
  - Zig: `export fn Rmenu_item_set_icon(id: raven.Rid, texture: raven.Rid, u0: f32, v0: f32, u1: f32, v1: f32, tint: c_int) void`

- `Rmenu_item_set_checked()` (line 805)
  - C: `void Rmenu_item_set_checked(Rid id, int checked);`
  - Zig: `export fn Rmenu_item_set_checked(id: raven.Rid, checked: c_int) void`

- `Rmenu_item_is_checked()` (line 811)
  - C: `int Rmenu_item_is_checked(Rid id);`
  - Zig: `export fn Rmenu_item_is_checked(id: raven.Rid) c_int`

- `Rmenu_item_set_clicked_callback()` (line 816)
  - C: `void Rmenu_item_set_clicked_callback(Rid id, RMenuItemClickedCallback callback, void* user_data);`
  - Zig: `export fn Rmenu_item_set_clicked_callback(id: raven.Rid, callback: raven.RMenuItemClickedCallback, user_data: ?*anyopaque) void`

- `Rmenu_open()` (line 822)
  - C: `void Rmenu_open(Rid id, Rid window_id, float x, float y);`
  - Zig: `export fn Rmenu_open(id: raven.Rid, window_id: raven.Rid, x: f32, y: f32) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_icon`, `rvn_paint_image`, `rvn_paint_rect`, `rvn_paint_shadow`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_widget_add_child`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_text_color`, `rvn_window_check`, `rvn_window_close_popup`, `rvn_window_close_popups`, `rvn_window_open_popup`

From `core/base_h.zig` (`base.<name>`): `rvn_color_mix`, `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_rect`, `rvn_rgba`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_surface`, `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_text_width`

Includes: `common.h`, `../xml/xml.h`


## widgets/dialogs.c  (821 lines) -> zig/src/widgets/dialogs.zig

Exports (13):

- `rvn_dialogs_shutdown()` (line 58)
  - C: `void rvn_dialogs_shutdown(void);`
  - Zig: `export fn rvn_dialogs_shutdown() void`

- `Rdialog_open()` (line 129)
  - C: `void Rdialog_open(Rid window_id, Rid content_id, RDialogClosedCallback closed, void* user_data);`
  - Zig: `export fn Rdialog_open(window_id: raven.Rid, content_id: raven.Rid, closed: raven.RDialogClosedCallback, user_data: ?*anyopaque) void`

- `Rdialog_close()` (line 139)
  - C: `void Rdialog_close(Rid id, int result);`
  - Zig: `export fn Rdialog_close(id: raven.Rid, result: c_int) void`

- `Rdialog_run()` (line 144)
  - C: `int Rdialog_run(Rid window_id, Rid content_id);`
  - Zig: `export fn Rdialog_run(window_id: raven.Rid, content_id: raven.Rid) c_int`

- `Rwindow_has_dialog()` (line 154)
  - C: `int Rwindow_has_dialog(Rid id);`
  - Zig: `export fn Rwindow_has_dialog(id: raven.Rid) c_int`

- `Rmessage_box()` (line 188)
  - C: `RMessageResult Rmessage_box(Rid window_id, const char* title, const char* text, RMessageButtons buttons);`
  - Zig: `export fn Rmessage_box(window_id: raven.Rid, title: [*c]const u8, text: [*c]const u8, buttons: raven.RMessageButtons) raven.RMessageResult`

- `Rfile_dialog_open()` (line 790)
  - C: `const char* Rfile_dialog_open(const RFileDialogDesc* desc);`
  - Zig: `export fn Rfile_dialog_open(desc: [*c]const raven.RFileDialogDesc) [*c]const u8`

- `Rfile_dialog_save()` (line 795)
  - C: `const char* Rfile_dialog_save(const RFileDialogDesc* desc);`
  - Zig: `export fn Rfile_dialog_save(desc: [*c]const raven.RFileDialogDesc) [*c]const u8`

- `Rfile_dialog_select_folder()` (line 800)
  - C: `const char* Rfile_dialog_select_folder(const RFileDialogDesc* desc);`
  - Zig: `export fn Rfile_dialog_select_folder(desc: [*c]const raven.RFileDialogDesc) [*c]const u8`

- `Rfile_dialog_get_result_count()` (line 805)
  - C: `int Rfile_dialog_get_result_count(void);`
  - Zig: `export fn Rfile_dialog_get_result_count() c_int`

- `Rfile_dialog_get_result()` (line 809)
  - C: `const char* Rfile_dialog_get_result(int index);`
  - Zig: `export fn Rfile_dialog_get_result(index: c_int) [*c]const u8`

- `Rfile_read()` (line 814)
  - C: `char* Rfile_read(const char* path, size_t* size);`
  - Zig: `export fn Rfile_read(path: [*c]const u8, size: [*c]usize) [*c]u8`

- `Rfile_write()` (line 818)
  - C: `int Rfile_write(const char* path, const void* data, size_t size);`
  - Zig: `export fn Rfile_write(path: [*c]const u8, data: ?*const anyopaque, size: usize) c_int`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_path_absolute`, `rvn_path_child`, `rvn_path_home`, `rvn_path_is_dir`, `rvn_path_parent`, `rvn_pool_at`, `rvn_update`, `rvn_widget_add_child`, `rvn_widget_check`, `rvn_widget_create`, `rvn_widget_destroy`, `rvn_widget_focus`, `rvn_widget_get`, `rvn_widget_set_attribute`, `rvn_window_check`, `rvn_window_close_dialog`, `rvn_window_destroy`, `rvn_window_get`, `rvn_window_open_dialog`, `rvn_window_popup_index`, `rvn_window_size`, `rvn_window_top_dialog`, `rvn_write_file`

From `core/base_h.zig` (`base.<name>`): `rvn_alloc`, `rvn_calloc`, `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_minf`, `rvn_read_file`, `rvn_realloc`, `rvn_strdup`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`, `../core/fs.h`


## widgets/tile_view.c  (719 lines) -> zig/src/widgets/tile_view.zig

Exports (21):

- `rvn_class_tile_view` global (line 558)
  - C: `const rvn_widget_class_t rvn_class_tile_view;`
  - Zig: `export const rvn_class_tile_view: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rtile_view_set_items()` (line 576)
  - C: `void Rtile_view_set_items(Rid id, int count, RTileItemCallback callback, void* user_data);`
  - Zig: `export fn Rtile_view_set_items(id: raven.Rid, count: c_int, callback: raven.RTileItemCallback, user_data: ?*anyopaque) void`

- `Rtile_view_refresh()` (line 595)
  - C: `void Rtile_view_refresh(Rid id);`
  - Zig: `export fn Rtile_view_refresh(id: raven.Rid) void`

- `Rtile_view_get_count()` (line 600)
  - C: `int Rtile_view_get_count(Rid id);`
  - Zig: `export fn Rtile_view_get_count(id: raven.Rid) c_int`

- `Rtile_view_set_tile_size()` (line 605)
  - C: `void Rtile_view_set_tile_size(Rid id, float width, float height, float icon_size);`
  - Zig: `export fn Rtile_view_set_tile_size(id: raven.Rid, width: f32, height: f32, icon_size: f32) void`

- `Rtile_view_set_empty_text()` (line 614)
  - C: `void Rtile_view_set_empty_text(Rid id, const char* text);`
  - Zig: `export fn Rtile_view_set_empty_text(id: raven.Rid, text: [*c]const u8) void`

- `Rtile_view_set_selected()` (line 620)
  - C: `void Rtile_view_set_selected(Rid id, int index, int selected);`
  - Zig: `export fn Rtile_view_set_selected(id: raven.Rid, index: c_int, selected: c_int) void`

- `Rtile_view_is_selected()` (line 631)
  - C: `int Rtile_view_is_selected(Rid id, int index);`
  - Zig: `export fn Rtile_view_is_selected(id: raven.Rid, index: c_int) c_int`

- `Rtile_view_clear_selection()` (line 638)
  - C: `void Rtile_view_clear_selection(Rid id);`
  - Zig: `export fn Rtile_view_clear_selection(id: raven.Rid) void`

- `Rtile_view_select_only()` (line 643)
  - C: `void Rtile_view_select_only(Rid id, int index);`
  - Zig: `export fn Rtile_view_select_only(id: raven.Rid, index: c_int) void`

- `Rtile_view_get_current()` (line 648)
  - C: `int Rtile_view_get_current(Rid id);`
  - Zig: `export fn Rtile_view_get_current(id: raven.Rid) c_int`

- `Rtile_view_get_selection_count()` (line 653)
  - C: `int Rtile_view_get_selection_count(Rid id);`
  - Zig: `export fn Rtile_view_get_selection_count(id: raven.Rid) c_int`

- `Rtile_view_get_selection()` (line 661)
  - C: `int Rtile_view_get_selection(Rid id, int nth);`
  - Zig: `export fn Rtile_view_get_selection(id: raven.Rid, nth: c_int) c_int`

- `Rtile_view_scroll_to()` (line 672)
  - C: `void Rtile_view_scroll_to(Rid id, int index);`
  - Zig: `export fn Rtile_view_scroll_to(id: raven.Rid, index: c_int) void`

- `Rtile_view_get_item_at()` (line 677)
  - C: `int Rtile_view_get_item_at(Rid id, float local_x, float local_y);`
  - Zig: `export fn Rtile_view_get_item_at(id: raven.Rid, local_x: f32, local_y: f32) c_int`

- `Rtile_view_set_drop_highlight()` (line 682)
  - C: `void Rtile_view_set_drop_highlight(Rid id, int index);`
  - Zig: `export fn Rtile_view_set_drop_highlight(id: raven.Rid, index: c_int) void`

- `Rtile_view_set_drag_type()` (line 690)
  - C: `void Rtile_view_set_drag_type(Rid id, const char* type);`
  - Zig: `export fn Rtile_view_set_drag_type(id: raven.Rid, @"type": [*c]const u8) void`

- `Rtile_view_set_drag_data_callback()` (line 697)
  - C: `void Rtile_view_set_drag_data_callback(Rid id, RTileDragDataCallback callback, void* user_data);`
  - Zig: `export fn Rtile_view_set_drag_data_callback(id: raven.Rid, callback: raven.RTileDragDataCallback, user_data: ?*anyopaque) void`

- `Rtile_view_set_selection_changed_callback()` (line 703)
  - C: `void Rtile_view_set_selection_changed_callback(Rid id, RTileEventCallback callback, void* user_data);`
  - Zig: `export fn Rtile_view_set_selection_changed_callback(id: raven.Rid, callback: raven.RTileEventCallback, user_data: ?*anyopaque) void`

- `Rtile_view_set_activated_callback()` (line 709)
  - C: `void Rtile_view_set_activated_callback(Rid id, RTileEventCallback callback, void* user_data);`
  - Zig: `export fn Rtile_view_set_activated_callback(id: raven.Rid, callback: raven.RTileEventCallback, user_data: ?*anyopaque) void`

- `Rtile_view_set_context_callback()` (line 715)
  - C: `void Rtile_view_set_context_callback(Rid id, RTileContextCallback callback, void* user_data);`
  - Zig: `export fn Rtile_view_set_context_callback(id: raven.Rid, callback: raven.RTileContextCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_font_resolve`, `rvn_paint_box`, `rvn_paint_image`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_text_in`, `rvn_parse_float`, `rvn_text_width`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_release_mouse`, `rvn_widget_text_color`

From `core/base_h.zig` (`base.<name>`): `rvn_alloc`, `rvn_clampf`, `rvn_clampi`, `rvn_color_fade`, `rvn_free`, `rvn_maxf`, `rvn_maxi`, `rvn_minf`, `rvn_mini`, `rvn_realloc`, `rvn_rect`, `rvn_rgba`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_scrollbar_clamp`, `rvn_scrollbar_event`, `rvn_scrollbar_paint`, `rvn_scrollbar_set`, `rvn_scrollbar_shown`, `rvn_scrollbar_wheel`, `rvn_widget_alive`, `rvn_widget_font_size`

Includes: `common.h`, `../render/font.h`


## widgets/header_bar.c  (579 lines) -> zig/src/widgets/header_bar.zig

Exports (8):

- `rvn_class_header_bar` global (line 510)
  - C: `const rvn_widget_class_t rvn_class_header_bar;`
  - Zig: `export const rvn_class_header_bar: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rheader_bar_create()` (line 529)
  - C: `Rid Rheader_bar_create(const char* title);`
  - Zig: `export fn Rheader_bar_create(title: [*c]const u8) raven.Rid`

- `Rheader_bar_set_title()` (line 538)
  - C: `void Rheader_bar_set_title(Rid id, const char* title);`
  - Zig: `export fn Rheader_bar_set_title(id: raven.Rid, title: [*c]const u8) void`

- `Rheader_bar_set_buttons()` (line 543)
  - C: `void Rheader_bar_set_buttons(Rid id, Ruint buttons);`
  - Zig: `export fn Rheader_bar_set_buttons(id: raven.Rid, buttons: raven.Ruint) void`

- `Rheader_bar_set_button_side()` (line 549)
  - C: `void Rheader_bar_set_button_side(Rid id, RHAlign side);`
  - Zig: `export fn Rheader_bar_set_button_side(id: raven.Rid, side: raven.RHAlign) void`

- `Rheader_bar_set_title_align()` (line 559)
  - C: `void Rheader_bar_set_title_align(Rid id, RHAlign align);`
  - Zig: `export fn Rheader_bar_set_title_align(id: raven.Rid, @"align": raven.RHAlign) void`

- `Rheader_bar_set_background()` (line 569)
  - C: `void Rheader_bar_set_background(Rid id, int enabled);`
  - Zig: `export fn Rheader_bar_set_background(id: raven.Rid, enabled: c_int) void`

- `Rheader_bar_set_title_notch()` (line 575)
  - C: `void Rheader_bar_set_title_notch(Rid id, int notch);`
  - Zig: `export fn Rheader_bar_set_title_notch(id: raven.Rid, notch: c_int) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_drawlist_transform`, `rvn_paint_box`, `rvn_paint_box4`, `rvn_paint_line`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_shadow`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_paint_triangle`, `rvn_parse_bool`, `rvn_spring_kick`, `rvn_widget_arrange_slot`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_widget_release_mouse`, `rvn_widget_text_color`, `rvn_window_request_close`, `rvn_window_toggle_maximized`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_fade`, `rvn_color_mix`, `rvn_error`, `rvn_free`, `rvn_hex`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rgba`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_strnicmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_surface`, `rvn_widget_text_width`

Includes: `common.h`


## widgets/island.c  (516 lines) -> zig/src/widgets/island.zig

Exports (11):

- `rvn_islands_pressed()` (line 191)
  - C: `void rvn_islands_pressed(rvn_window_t* window, rvn_widget_t* hit, int on_popup);`
  - Zig: `export fn rvn_islands_pressed(window: [*c]common.rvn_window_t, hit: [*c]common.rvn_widget_t, on_popup: c_int) void`

- `rvn_islands_shutdown()` (line 210)
  - C: `void rvn_islands_shutdown(void);`
  - Zig: `export fn rvn_islands_shutdown() void`

- `rvn_class_island` global (line 443)
  - C: `const rvn_widget_class_t rvn_class_island;`
  - Zig: `export const rvn_class_island: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Risland_create()` (line 462)
  - C: `Rid Risland_create(void);`
  - Zig: `export fn Risland_create() raven.Rid`

- `Risland_set_expanded()` (line 469)
  - C: `void Risland_set_expanded(Rid id, int expanded);`
  - Zig: `export fn Risland_set_expanded(id: raven.Rid, expanded: c_int) void`

- `Risland_is_expanded()` (line 480)
  - C: `int Risland_is_expanded(Rid id);`
  - Zig: `export fn Risland_is_expanded(id: raven.Rid) c_int`

- `Risland_expand_for()` (line 485)
  - C: `void Risland_expand_for(Rid id, double seconds);`
  - Zig: `export fn Risland_expand_for(id: raven.Rid, seconds: f64) void`

- `Risland_set_expand_on_hover()` (line 496)
  - C: `void Risland_set_expand_on_hover(Rid id, int enabled);`
  - Zig: `export fn Risland_set_expand_on_hover(id: raven.Rid, enabled: c_int) void`

- `Risland_set_expand_on_click()` (line 501)
  - C: `void Risland_set_expand_on_click(Rid id, int enabled);`
  - Zig: `export fn Risland_set_expand_on_click(id: raven.Rid, enabled: c_int) void`

- `Risland_set_attached()` (line 506)
  - C: `void Risland_set_attached(Rid id, int attached);`
  - Zig: `export fn Risland_set_attached(id: raven.Rid, attached: c_int) void`

- `Risland_set_changed_callback()` (line 512)
  - C: `void Risland_set_changed_callback(Rid id, RIslandChangedCallback callback, void* user_data);`
  - Zig: `export fn Risland_set_changed_callback(id: raven.Rid, callback: raven.RIslandChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_clock_seconds`, `rvn_drawlist_transform`, `rvn_paint_box4`, `rvn_paint_glass`, `rvn_paint_push_clip`, `rvn_paint_shadow`, `rvn_parse_bool`, `rvn_spring_set`, `rvn_theme_dark_twin`, `rvn_widget_animate_layout`, `rvn_widget_arrange_slot`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_fire_action`, `rvn_widget_get`, `rvn_widget_has_color`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_is_inside`, `rvn_widget_measure_slot`, `rvn_widget_paint`, `rvn_widget_set_theme`, `rvn_window_forget_widget`

From `core/base_h.zig` (`base.<name>`): `rvn_box`, `rvn_box_empty`, `rvn_clampf`, `rvn_color_fade`, `rvn_color_mix`, `rvn_free`, `rvn_hex`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rgba`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_glass_style`, `rvn_glass_tune`, `rvn_widget_alive`, `rvn_widget_hover`, `rvn_xml_theme`

Includes: `common.h`


## widgets/tab_view.c  (504 lines) -> zig/src/widgets/tab_view.zig

Exports (14):

- `rvn_class_tab_view` global (line 380)
  - C: `const rvn_widget_class_t rvn_class_tab_view;`
  - Zig: `export const rvn_class_tab_view: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rtab_view_add_tab()` (line 395)
  - C: `int Rtab_view_add_tab(Rid id, const char* title, Rid content);`
  - Zig: `export fn Rtab_view_add_tab(id: raven.Rid, title: [*c]const u8, content: raven.Rid) c_int`

- `Rtab_view_set_active()` (line 409)
  - C: `void Rtab_view_set_active(Rid id, int index);`
  - Zig: `export fn Rtab_view_set_active(id: raven.Rid, index: c_int) void`

- `Rtab_view_get_active()` (line 414)
  - C: `int Rtab_view_get_active(Rid id);`
  - Zig: `export fn Rtab_view_get_active(id: raven.Rid) c_int`

- `Rtab_view_set_changed_callback()` (line 419)
  - C: `void Rtab_view_set_changed_callback(Rid id, RTabChangedCallback callback, void* user_data);`
  - Zig: `export fn Rtab_view_set_changed_callback(id: raven.Rid, callback: raven.RTabChangedCallback, user_data: ?*anyopaque) void`

- `Rtab_view_set_documents()` (line 435)
  - C: `void Rtab_view_set_documents(Rid id, int documents);`
  - Zig: `export fn Rtab_view_set_documents(id: raven.Rid, documents: c_int) void`

- `Rtab_view_get_tab_count()` (line 441)
  - C: `int Rtab_view_get_tab_count(Rid id);`
  - Zig: `export fn Rtab_view_get_tab_count(id: raven.Rid) c_int`

- `Rtab_view_get_tab()` (line 446)
  - C: `Rid Rtab_view_get_tab(Rid id, int index);`
  - Zig: `export fn Rtab_view_get_tab(id: raven.Rid, index: c_int) raven.Rid`

- `Rtab_view_find_tab()` (line 452)
  - C: `int Rtab_view_find_tab(Rid id, Rid content);`
  - Zig: `export fn Rtab_view_find_tab(id: raven.Rid, content: raven.Rid) c_int`

- `Rtab_view_set_tab_title()` (line 460)
  - C: `void Rtab_view_set_tab_title(Rid id, Rid content, const char* title);`
  - Zig: `export fn Rtab_view_set_tab_title(id: raven.Rid, content: raven.Rid, title: [*c]const u8) void`

- `Rtab_view_set_tab_icon()` (line 469)
  - C: `void Rtab_view_set_tab_icon(Rid id, Rid content, Rid texture, float u0, float v0, float u1, float v1, int tint);`
  - Zig: `export fn Rtab_view_set_tab_icon(id: raven.Rid, content: raven.Rid, texture: raven.Rid, u0: f32, v0: f32, u1: f32, v1: f32, tint: c_int) void`

- `Rtab_view_set_tab_closable()` (line 484)
  - C: `void Rtab_view_set_tab_closable(Rid id, Rid content, int closable);`
  - Zig: `export fn Rtab_view_set_tab_closable(id: raven.Rid, content: raven.Rid, closable: c_int) void`

- `Rtab_view_show_tab()` (line 493)
  - C: `void Rtab_view_show_tab(Rid id, Rid content);`
  - Zig: `export fn Rtab_view_show_tab(id: raven.Rid, content: raven.Rid) void`

- `Rtab_view_set_close_callback()` (line 500)
  - C: `void Rtab_view_set_close_callback(Rid id, RTabCloseCallback callback, void* user_data);`
  - Zig: `export fn Rtab_view_set_close_callback(id: raven.Rid, callback: raven.RTabCloseCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_box4`, `rvn_paint_icon`, `rvn_paint_image`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_parse_int`, `rvn_widget_add_child`, `rvn_widget_appear`, `rvn_widget_arrange`, `rvn_widget_arrange_slot`, `rvn_widget_check`, `rvn_widget_color`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_is_inside`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_widget_play_transition`, `rvn_widget_text_color`, `rvn_window_forget_widget`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_fade`, `rvn_color_mix`, `rvn_error`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rect_contains`, `rvn_rgba`, `rvn_str_set`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_surface`, `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_text_width`

Includes: `common.h`


## widgets/combo_box.c  (450 lines) -> zig/src/widgets/combo_box.zig

Exports (8):

- `rvn_class_combo_box` global (line 400)
  - C: `const rvn_widget_class_t rvn_class_combo_box;`
  - Zig: `export const rvn_class_combo_box: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rcombo_box_add_item()` (line 415)
  - C: `int Rcombo_box_add_item(Rid id, const char* text);`
  - Zig: `export fn Rcombo_box_add_item(id: raven.Rid, text: [*c]const u8) c_int`

- `Rcombo_box_clear_items()` (line 420)
  - C: `void Rcombo_box_clear_items(Rid id);`
  - Zig: `export fn Rcombo_box_clear_items(id: raven.Rid) void`

- `Rcombo_box_get_item_count()` (line 425)
  - C: `int Rcombo_box_get_item_count(Rid id);`
  - Zig: `export fn Rcombo_box_get_item_count(id: raven.Rid) c_int`

- `Rcombo_box_get_item_text()` (line 430)
  - C: `const char* Rcombo_box_get_item_text(Rid id, int index);`
  - Zig: `export fn Rcombo_box_get_item_text(id: raven.Rid, index: c_int) [*c]const u8`

- `Rcombo_box_set_selected()` (line 436)
  - C: `void Rcombo_box_set_selected(Rid id, int index);`
  - Zig: `export fn Rcombo_box_set_selected(id: raven.Rid, index: c_int) void`

- `Rcombo_box_get_selected()` (line 441)
  - C: `int Rcombo_box_get_selected(Rid id);`
  - Zig: `export fn Rcombo_box_get_selected(id: raven.Rid) c_int`

- `Rcombo_box_set_changed_callback()` (line 446)
  - C: `void Rcombo_box_set_changed_callback(Rid id, RComboBoxChangedCallback callback, void* user_data);`
  - Zig: `export fn Rcombo_box_set_changed_callback(id: raven.Rid, callback: raven.RComboBoxChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_icon`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_shadow`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_parse_int`, `rvn_widget_color`, `rvn_widget_create_class`, `rvn_widget_destroy`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_text_color`, `rvn_window_close_popup`, `rvn_window_layout`, `rvn_window_open_popup`, `rvn_xml_attribute`

From `core/base_h.zig` (`base.<name>`): `rvn_color_fade`, `rvn_free`, `rvn_maxf`, `rvn_maxi`, `rvn_maxu`, `rvn_mini`, `rvn_minu`, `rvn_rect`, `rvn_strdup`, `rvn_stricmp`, `rvn_strndup`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_control_radius`, `rvn_paint_focus`, `rvn_paint_row`, `rvn_paint_surface`, `rvn_scrollbar_clamp`, `rvn_scrollbar_event`, `rvn_scrollbar_paint`, `rvn_scrollbar_set`, `rvn_scrollbar_shown`, `rvn_scrollbar_wheel`, `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_hover`, `rvn_widget_press`, `rvn_widget_text_width`

Includes: `common.h`, `../xml/xml.h`


## widgets/list_view.c  (402 lines) -> zig/src/widgets/list_view.zig

Exports (13):

- `rvn_class_list_view` global (line 287)
  - C: `const rvn_widget_class_t rvn_class_list_view;`
  - Zig: `export const rvn_class_list_view: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rlist_view_add_item()` (line 307)
  - C: `int Rlist_view_add_item(Rid id, const char* text);`
  - Zig: `export fn Rlist_view_add_item(id: raven.Rid, text: [*c]const u8) c_int`

- `Rlist_view_set_item_text()` (line 316)
  - C: `void Rlist_view_set_item_text(Rid id, int index, const char* text);`
  - Zig: `export fn Rlist_view_set_item_text(id: raven.Rid, index: c_int, text: [*c]const u8) void`

- `Rlist_view_get_item_text()` (line 326)
  - C: `const char* Rlist_view_get_item_text(Rid id, int index);`
  - Zig: `export fn Rlist_view_get_item_text(id: raven.Rid, index: c_int) [*c]const u8`

- `Rlist_view_remove_item()` (line 331)
  - C: `void Rlist_view_remove_item(Rid id, int index);`
  - Zig: `export fn Rlist_view_remove_item(id: raven.Rid, index: c_int) void`

- `Rlist_view_clear_items()` (line 348)
  - C: `void Rlist_view_clear_items(Rid id);`
  - Zig: `export fn Rlist_view_clear_items(id: raven.Rid) void`

- `Rlist_view_get_item_count()` (line 354)
  - C: `int Rlist_view_get_item_count(Rid id);`
  - Zig: `export fn Rlist_view_get_item_count(id: raven.Rid) c_int`

- `Rlist_view_set_virtual_items()` (line 359)
  - C: `void Rlist_view_set_virtual_items(Rid id, int count, RListItemTextCallback callback, void* user_data);`
  - Zig: `export fn Rlist_view_set_virtual_items(id: raven.Rid, count: c_int, callback: raven.RListItemTextCallback, user_data: ?*anyopaque) void`

- `Rlist_view_set_selected()` (line 375)
  - C: `void Rlist_view_set_selected(Rid id, int index);`
  - Zig: `export fn Rlist_view_set_selected(id: raven.Rid, index: c_int) void`

- `Rlist_view_get_selected()` (line 380)
  - C: `int Rlist_view_get_selected(Rid id);`
  - Zig: `export fn Rlist_view_get_selected(id: raven.Rid) c_int`

- `Rlist_view_scroll_to_item()` (line 385)
  - C: `void Rlist_view_scroll_to_item(Rid id, int index);`
  - Zig: `export fn Rlist_view_scroll_to_item(id: raven.Rid, index: c_int) void`

- `Rlist_view_set_selection_changed_callback()` (line 392)
  - C: `void Rlist_view_set_selection_changed_callback(Rid id, RListEventCallback callback, void* user_data);`
  - Zig: `export fn Rlist_view_set_selection_changed_callback(id: raven.Rid, callback: raven.RListEventCallback, user_data: ?*anyopaque) void`

- `Rlist_view_set_activated_callback()` (line 398)
  - C: `void Rlist_view_set_activated_callback(Rid id, RListEventCallback callback, void* user_data);`
  - Zig: `export fn Rlist_view_set_activated_callback(id: raven.Rid, callback: raven.RListEventCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_parse_int`, `rvn_widget_color`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_text_color`, `rvn_window_layout`, `rvn_xml_attribute`

From `core/base_h.zig` (`base.<name>`): `rvn_clampi`, `rvn_color_mix`, `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_maxi`, `rvn_mini`, `rvn_rect`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_strndup`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_row`, `rvn_scrollbar_clamp`, `rvn_scrollbar_event`, `rvn_scrollbar_needed`, `rvn_scrollbar_paint`, `rvn_scrollbar_set`, `rvn_scrollbar_shown`, `rvn_scrollbar_wheel`, `rvn_widget_alive`, `rvn_widget_font_size`

Includes: `common.h`, `../xml/xml.h`


## widgets/label.c  (397 lines) -> zig/src/widgets/label.zig

Exports (13):

- `rvn_class_label` global (line 292)
  - C: `const rvn_widget_class_t rvn_class_label;`
  - Zig: `export const rvn_class_label: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rlabel_create()` (line 310)
  - C: `Rid Rlabel_create(const char* text);`
  - Zig: `export fn Rlabel_create(text: [*c]const u8) raven.Rid`

- `Rlabel_set_text()` (line 319)
  - C: `void Rlabel_set_text(Rid id, const char* text);`
  - Zig: `export fn Rlabel_set_text(id: raven.Rid, text: [*c]const u8) void`

- `Rlabel_get_text()` (line 327)
  - C: `const char* Rlabel_get_text(Rid id);`
  - Zig: `export fn Rlabel_get_text(id: raven.Rid) [*c]const u8`

- `Rlabel_set_font()` (line 332)
  - C: `void Rlabel_set_font(Rid id, Rid font);`
  - Zig: `export fn Rlabel_set_font(id: raven.Rid, font: raven.Rid) void`

- `Rlabel_set_text_size()` (line 342)
  - C: `void Rlabel_set_text_size(Rid id, float size);`
  - Zig: `export fn Rlabel_set_text_size(id: raven.Rid, size: f32) void`

- `Rlabel_set_text_align()` (line 348)
  - C: `void Rlabel_set_text_align(Rid id, RTextAlign align);`
  - Zig: `export fn Rlabel_set_text_align(id: raven.Rid, @"align": raven.RTextAlign) void`

- `Rlabel_set_wrap()` (line 358)
  - C: `void Rlabel_set_wrap(Rid id, int wrap);`
  - Zig: `export fn Rlabel_set_wrap(id: raven.Rid, wrap: c_int) void`

- `Rlabel_set_color()` (line 365)
  - C: `void Rlabel_set_color(Rid id, float r, float g, float b, float a);`
  - Zig: `export fn Rlabel_set_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void`

- `Rlabel_set_markdown()` (line 370)
  - C: `void Rlabel_set_markdown(Rid id, int enabled);`
  - Zig: `export fn Rlabel_set_markdown(id: raven.Rid, enabled: c_int) void`

- `Rlabel_get_markdown()` (line 375)
  - C: `int Rlabel_get_markdown(Rid id);`
  - Zig: `export fn Rlabel_get_markdown(id: raven.Rid) c_int`

- `Rlabel_set_link_callback()` (line 380)
  - C: `void Rlabel_set_link_callback(Rid id, RLabelLinkCallback callback, void* user_data);`
  - Zig: `export fn Rlabel_set_link_callback(id: raven.Rid, callback: raven.RLabelLinkCallback, user_data: ?*anyopaque) void`

- `Rlabel_get_plain_text()` (line 386)
  - C: `const char* Rlabel_get_plain_text(Rid id);`
  - Zig: `export fn Rlabel_get_plain_text(id: raven.Rid) [*c]const u8`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_fire_action`, `rvn_font_metrics`, `rvn_font_resolve`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_text`, `rvn_parse_bool`, `rvn_parse_color`, `rvn_parse_float`, `rvn_text_wrap`, `rvn_widget_create`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_set_color`, `rvn_widget_text_color`

From `core/base_h.zig` (`base.<name>`): `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_rect`, `rvn_rgba`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_strnicmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_md_free`, `rvn_md_layout`, `rvn_md_link`, `rvn_md_link_at`, `rvn_md_link_count`, `rvn_md_paint`, `rvn_md_parse`, `rvn_md_plain_text`, `rvn_widget_font_size`, `rvn_xml_font`

Includes: `common.h`


## widgets/viewport.c  (362 lines) -> zig/src/widgets/viewport.zig

Exports (15):

- `rvn_viewport_native_release()` (line 44)
  - C: `void rvn_viewport_native_release(rvn_widget_t* widget, rvn_window_t* window);`
  - Zig: `export fn rvn_viewport_native_release(widget: [*c]common.rvn_widget_t, window: [*c]common.rvn_window_t) void`

- `rvn_viewport_native_sync()` (line 60)
  - C: `void rvn_viewport_native_sync(rvn_widget_t* widget, uint64_t frame);`
  - Zig: `export fn rvn_viewport_native_sync(widget: [*c]common.rvn_widget_t, frame: u64) void`

- `rvn_class_viewport` global (line 193)
  - C: `const rvn_widget_class_t rvn_class_viewport;`
  - Zig: `export const rvn_class_viewport: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rviewport_set_texture()` (line 209)
  - C: `void Rviewport_set_texture(Rid id, Rid texture);`
  - Zig: `export fn Rviewport_set_texture(id: raven.Rid, texture: raven.Rid) void`

- `Rviewport_set_stretch()` (line 219)
  - C: `void Rviewport_set_stretch(Rid id, RStretch stretch);`
  - Zig: `export fn Rviewport_set_stretch(id: raven.Rid, stretch: raven.RStretch) void`

- `Rviewport_set_flip_y()` (line 229)
  - C: `void Rviewport_set_flip_y(Rid id, int flip);`
  - Zig: `export fn Rviewport_set_flip_y(id: raven.Rid, flip: c_int) void`

- `Rviewport_set_draw_callback()` (line 235)
  - C: `void Rviewport_set_draw_callback(Rid id, RViewportDrawCallback callback, void* user_data);`
  - Zig: `export fn Rviewport_set_draw_callback(id: raven.Rid, callback: raven.RViewportDrawCallback, user_data: ?*anyopaque) void`

- `Rviewport_set_native()` (line 242)
  - C: `int Rviewport_set_native(Rid id, int enabled);`
  - Zig: `export fn Rviewport_set_native(id: raven.Rid, enabled: c_int) c_int`

- `Rviewport_get_native_handle()` (line 276)
  - C: `int Rviewport_get_native_handle(Rid id, RNativeWindow* native);`
  - Zig: `export fn Rviewport_get_native_handle(id: raven.Rid, native: [*c]raven.RNativeWindow) c_int`

- `Rviewport_get_pixel_size()` (line 285)
  - C: `void Rviewport_get_pixel_size(Rid id, int* width, int* height);`
  - Zig: `export fn Rviewport_get_pixel_size(id: raven.Rid, width: [*c]c_int, height: [*c]c_int) void`

- `Rviewport_set_resize_callback()` (line 296)
  - C: `void Rviewport_set_resize_callback(Rid id, RViewportResizeCallback callback, void* user_data);`
  - Zig: `export fn Rviewport_set_resize_callback(id: raven.Rid, callback: raven.RViewportResizeCallback, user_data: ?*anyopaque) void`

- `Rviewport_set_realtime()` (line 302)
  - C: `void Rviewport_set_realtime(Rid id, int realtime);`
  - Zig: `export fn Rviewport_set_realtime(id: raven.Rid, realtime: c_int) void`

- `rvn_class_custom` global (line 341)
  - C: `const rvn_widget_class_t rvn_class_custom;`
  - Zig: `export const rvn_class_custom: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rcustom_set_paint_callback()` (line 350)
  - C: `void Rcustom_set_paint_callback(Rid id, RPaintCallback callback, void* user_data);`
  - Zig: `export fn Rcustom_set_paint_callback(id: raven.Rid, callback: raven.RPaintCallback, user_data: ?*anyopaque) void`

- `Rcustom_set_measure_callback()` (line 357)
  - C: `void Rcustom_set_measure_callback(Rid id, RMeasureCallback callback, void* user_data);`
  - Zig: `export fn Rcustom_set_measure_callback(id: raven.Rid, callback: raven.RMeasureCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `g_rvn`, `rvn_atomic_add`, `rvn_dispatch_begin`, `rvn_dispatch_end`, `rvn_drawlist_add_callback`, `rvn_paint_image`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_snap`, `rvn_parse_bool`, `rvn_texture_get`, `rvn_widget_capture_mouse`, `rvn_widget_check`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure_slot`, `rvn_widget_origin`, `rvn_window_layout`

From `core/base_h.zig` (`base.<name>`): `rvn_box_empty`, `rvn_box_intersect`, `rvn_error`, `rvn_maxf`, `rvn_maxi`, `rvn_rect`, `rvn_rgba8`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_image_fit`, `rvn_paint_focus`, `rvn_parse_stretch`, `rvn_xml_texture`

Includes: `common.h`, `../render/renderer.h`


## widgets/textedit.c  (354 lines) -> zig/src/widgets/textedit.zig

Exports (10):

- `rvn_textedit_init()` (line 11)
  - C: `void rvn_textedit_init(rvn_textedit_t* edit);`
  - Zig: `export fn rvn_textedit_init(edit: [*c]common.rvn_textedit_t) void`

- `rvn_textedit_free()` (line 19)
  - C: `void rvn_textedit_free(rvn_textedit_t* edit);`
  - Zig: `export fn rvn_textedit_free(edit: [*c]common.rvn_textedit_t) void`

- `rvn_textedit_set_text()` (line 67)
  - C: `int rvn_textedit_set_text(rvn_textedit_t* edit, const char* text);`
  - Zig: `export fn rvn_textedit_set_text(edit: [*c]common.rvn_textedit_t, text: [*c]const u8) c_int`

- `rvn_textedit_select_all()` (line 83)
  - C: `void rvn_textedit_select_all(rvn_textedit_t* edit);`
  - Zig: `export fn rvn_textedit_select_all(edit: [*c]common.rvn_textedit_t) void`

- `rvn_textedit_set_focused()` (line 114)
  - C: `void rvn_textedit_set_focused(rvn_textedit_t* edit, rvn_widget_t* widget, int focused);`
  - Zig: `export fn rvn_textedit_set_focused(edit: [*c]common.rvn_textedit_t, widget: [*c]common.rvn_widget_t, focused: c_int) void`

- `rvn_textedit_key()` (line 161)
  - C: `int rvn_textedit_key(rvn_textedit_t* edit, const REvent* event);`
  - Zig: `export fn rvn_textedit_key(edit: [*c]common.rvn_textedit_t, event: [*c]const raven.REvent) c_int`

- `rvn_textedit_input()` (line 246)
  - C: `int rvn_textedit_input(rvn_textedit_t* edit, uint32_t codepoint);`
  - Zig: `export fn rvn_textedit_input(edit: [*c]common.rvn_textedit_t, codepoint: u32) c_int`

- `rvn_textedit_mouse_down()` (line 278)
  - C: `void rvn_textedit_mouse_down(rvn_textedit_t* edit, const rvn_widget_t* widget, Rid font_id, float size, float x, int clicks, int extend);`
  - Zig: `export fn rvn_textedit_mouse_down(edit: [*c]common.rvn_textedit_t, widget: [*c]const common.rvn_widget_t, font_id: raven.Rid, size: f32, x: f32, clicks: c_int, extend: c_int) void`

- `rvn_textedit_mouse_drag()` (line 300)
  - C: `void rvn_textedit_mouse_drag(rvn_textedit_t* edit, const rvn_widget_t* widget, Rid font_id, float size, float x);`
  - Zig: `export fn rvn_textedit_mouse_drag(edit: [*c]common.rvn_textedit_t, widget: [*c]const common.rvn_widget_t, font_id: raven.Rid, size: f32, x: f32) void`

- `rvn_textedit_paint()` (line 311)
  - C: `void rvn_textedit_paint(rvn_textedit_t* edit, const rvn_widget_t* widget, RPainter* painter, rvn_rect_t area, Rid font_id, float size, rvn_color_t color, int focused);`
  - Zig: `export fn rvn_textedit_paint(edit: [*c]common.rvn_textedit_t, widget: [*c]const common.rvn_widget_t, painter: ?*raven.RPainter, area: base.rvn_rect_t, font_id: raven.Rid, size: f32, color: base.rvn_color_t, focused: c_int) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_clock_seconds`, `rvn_font_metrics`, `rvn_font_resolve`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_text`, `rvn_text_offset_at`, `rvn_text_width`, `rvn_widget_color`, `rvn_widget_get`, `rvn_widget_invalidate_paint`

From `core/base_h.zig` (`base.<name>`): `rvn_alloc`, `rvn_clampf`, `rvn_clampi`, `rvn_free`, `rvn_maxf`, `rvn_maxi`, `rvn_mini`, `rvn_realloc`, `rvn_rect`, `rvn_strndup`, `rvn_utf8_count`, `rvn_utf8_encode`, `rvn_utf8_next`, `rvn_utf8_prev`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_widget_font_size`

Includes: `common.h`


## widgets/common.c  (354 lines) -> zig/src/widgets/common.zig

Exports (22):

- `rvn_widget_font_size()` (line 12)
  - C: `float rvn_widget_font_size(const rvn_widget_t* widget, float size);`
  - Zig: `export fn rvn_widget_font_size(widget: [*c]const common.rvn_widget_t, size: f32) f32`

- `rvn_widget_text_width()` (line 16)
  - C: `float rvn_widget_text_width(const rvn_widget_t* widget, Rid font, float size, const char* text);`
  - Zig: `export fn rvn_widget_text_width(widget: [*c]const common.rvn_widget_t, font: raven.Rid, size: f32, text: [*c]const u8) f32`

- `rvn_widget_line_height()` (line 22)
  - C: `float rvn_widget_line_height(const rvn_widget_t* widget, Rid font, float size);`
  - Zig: `export fn rvn_widget_line_height(widget: [*c]const common.rvn_widget_t, font: raven.Rid, size: f32) f32`

- `rvn_widget_alive()` (line 30)
  - C: `int rvn_widget_alive(const rvn_widget_t* widget);`
  - Zig: `export fn rvn_widget_alive(widget: [*c]const common.rvn_widget_t) c_int`

- `rvn_control_radius()` (line 38)
  - C: `float rvn_control_radius(const rvn_widget_t* widget, float height);`
  - Zig: `export fn rvn_control_radius(widget: [*c]const common.rvn_widget_t, height: f32) f32`

- `rvn_glass_style()` (line 48)
  - C: `void rvn_glass_style(const rvn_widget_t* widget, rvn_surface_t kind, float hover, float press, rvn_glass_t* glass);`
  - Zig: `export fn rvn_glass_style(widget: [*c]const common.rvn_widget_t, kind: common.rvn_surface_t, hover: f32, press: f32, glass: [*c]common.rvn_glass_t) void`

- `rvn_glass_tune()` (line 147)
  - C: `void rvn_glass_tune(const rvn_widget_t* widget, rvn_glass_t* glass);`
  - Zig: `export fn rvn_glass_tune(widget: [*c]const common.rvn_widget_t, glass: [*c]common.rvn_glass_t) void`

- `rvn_paint_surface()` (line 164)
  - C: `void rvn_paint_surface(RPainter* painter, const rvn_widget_t* widget, rvn_rect_t rect, float radius, rvn_surface_t kind, float hover, float press);`
  - Zig: `export fn rvn_paint_surface(painter: ?*raven.RPainter, widget: [*c]const common.rvn_widget_t, rect: base.rvn_rect_t, radius: f32, kind: common.rvn_surface_t, hover: f32, press: f32) void`

- `rvn_paint_row()` (line 180)
  - C: `void rvn_paint_row(RPainter* painter, const rvn_widget_t* widget, rvn_rect_t row, rvn_color_t color);`
  - Zig: `export fn rvn_paint_row(painter: ?*raven.RPainter, widget: [*c]const common.rvn_widget_t, row: base.rvn_rect_t, color: base.rvn_color_t) void`

- `rvn_widget_hover()` (line 188)
  - C: `float rvn_widget_hover(rvn_widget_t* widget, RPainter* painter, int hovered);`
  - Zig: `export fn rvn_widget_hover(widget: [*c]common.rvn_widget_t, painter: ?*raven.RPainter, hovered: c_int) f32`

- `rvn_widget_press()` (line 192)
  - C: `float rvn_widget_press(rvn_widget_t* widget, RPainter* painter, int pressed);`
  - Zig: `export fn rvn_widget_press(widget: [*c]common.rvn_widget_t, painter: ?*raven.RPainter, pressed: c_int) f32`

- `rvn_widget_squash()` (line 197)
  - C: `void rvn_widget_squash(rvn_widget_t* widget, float press, float amount);`
  - Zig: `export fn rvn_widget_squash(widget: [*c]common.rvn_widget_t, press: f32, amount: f32) void`

- `rvn_paint_knob()` (line 203)
  - C: `void rvn_paint_knob(RPainter* painter, const rvn_widget_t* widget, rvn_rect_t rect, float press);`
  - Zig: `export fn rvn_paint_knob(painter: ?*raven.RPainter, widget: [*c]const common.rvn_widget_t, rect: base.rvn_rect_t, press: f32) void`

- `rvn_paint_focus()` (line 221)
  - C: `void rvn_paint_focus(const rvn_widget_t* widget, RPainter* painter, float radius);`
  - Zig: `export fn rvn_paint_focus(widget: [*c]const common.rvn_widget_t, painter: ?*raven.RPainter, radius: f32) void`

- `rvn_scrollbar_max()` (line 233)
  - C: `float rvn_scrollbar_max(const rvn_scrollbar_t* bar);`
  - Zig: `export fn rvn_scrollbar_max(bar: [*c]const common.rvn_scrollbar_t) f32`

- `rvn_scrollbar_needed()` (line 237)
  - C: `int rvn_scrollbar_needed(const rvn_scrollbar_t* bar);`
  - Zig: `export fn rvn_scrollbar_needed(bar: [*c]const common.rvn_scrollbar_t) c_int`

- `rvn_scrollbar_set()` (line 241)
  - C: `int rvn_scrollbar_set(rvn_scrollbar_t* bar, float offset);`
  - Zig: `export fn rvn_scrollbar_set(bar: [*c]common.rvn_scrollbar_t, offset: f32) c_int`

- `rvn_scrollbar_clamp()` (line 251)
  - C: `int rvn_scrollbar_clamp(rvn_scrollbar_t* bar);`
  - Zig: `export fn rvn_scrollbar_clamp(bar: [*c]common.rvn_scrollbar_t) c_int`

- `rvn_scrollbar_wheel()` (line 255)
  - C: `int rvn_scrollbar_wheel(rvn_scrollbar_t* bar, float delta);`
  - Zig: `export fn rvn_scrollbar_wheel(bar: [*c]common.rvn_scrollbar_t, delta: f32) c_int`

- `rvn_scrollbar_shown()` (line 264)
  - C: `float rvn_scrollbar_shown(rvn_scrollbar_t* bar, RPainter* painter);`
  - Zig: `export fn rvn_scrollbar_shown(bar: [*c]common.rvn_scrollbar_t, painter: ?*raven.RPainter) f32`

- `rvn_scrollbar_paint()` (line 277)
  - C: `void rvn_scrollbar_paint(rvn_scrollbar_t* bar, const rvn_widget_t* widget, RPainter* painter, rvn_rect_t track, int vertical, float mouse_x, float mouse_y);`
  - Zig: `export fn rvn_scrollbar_paint(bar: [*c]common.rvn_scrollbar_t, widget: [*c]const common.rvn_widget_t, painter: ?*raven.RPainter, track: base.rvn_rect_t, vertical: c_int, mouse_x: f32, mouse_y: f32) void`

- `rvn_scrollbar_event()` (line 318)
  - C: `int rvn_scrollbar_event(rvn_scrollbar_t* bar, rvn_widget_t* widget, const REvent* event, rvn_rect_t track, int vertical, int* changed);`
  - Zig: `export fn rvn_scrollbar_event(bar: [*c]common.rvn_scrollbar_t, widget: [*c]common.rvn_widget_t, event: [*c]const raven.REvent, track: base.rvn_rect_t, vertical: c_int, changed: [*c]c_int) c_int`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_a11y_focus_always`, `rvn_a11y_focus_width`, `rvn_font_metrics`, `rvn_font_resolve`, `rvn_paint_box`, `rvn_paint_glass`, `rvn_paint_rect`, `rvn_paint_shadow`, `rvn_paint_spring`, `rvn_spring_kick`, `rvn_spring_moving`, `rvn_spring_set`, `rvn_text_width`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_metric`, `rvn_widget_release_mouse`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_a`, `rvn_color_fade`, `rvn_color_mix`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rect_contains`, `rvn_rgba`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/grid.c  (334 lines) -> zig/src/widgets/grid.zig

Exports (6):

- `rvn_class_grid` global (line 202)
  - C: `const rvn_widget_class_t rvn_class_grid;`
  - Zig: `export const rvn_class_grid: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rgrid_set_column_fill()` (line 213)
  - C: `void Rgrid_set_column_fill(Rid id, int column, float coefficient);`
  - Zig: `export fn Rgrid_set_column_fill(id: raven.Rid, column: c_int, coefficient: f32) void`

- `Rgrid_set_row_fill()` (line 220)
  - C: `void Rgrid_set_row_fill(Rid id, int row, float coefficient);`
  - Zig: `export fn Rgrid_set_row_fill(id: raven.Rid, row: c_int, coefficient: f32) void`

- `rvn_class_uniform_grid` global (line 314)
  - C: `const rvn_widget_class_t rvn_class_uniform_grid;`
  - Zig: `export const rvn_class_uniform_grid: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Runiform_grid_set_columns()` (line 324)
  - C: `void Runiform_grid_set_columns(Rid id, int columns);`
  - Zig: `export fn Runiform_grid_set_columns(id: raven.Rid, columns: c_int) void`

- `Runiform_grid_set_min_cell_size()` (line 330)
  - C: `void Runiform_grid_set_min_cell_size(Rid id, float width, float height);`
  - Zig: `export fn Runiform_grid_set_min_cell_size(id: raven.Rid, width: f32, height: f32) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_parse_float`, `rvn_parse_floats`, `rvn_parse_int`, `rvn_widget_arrange_slot`, `rvn_widget_invalidate_layout`, `rvn_widget_measure_slot`

From `core/base_h.zig` (`base.<name>`): `rvn_free`, `rvn_maxf`, `rvn_maxu`, `rvn_realloc`, `rvn_rect`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/spin_box.c  (306 lines) -> zig/src/widgets/spin_box.zig

Exports (8):

- `rvn_class_spin_box` global (line 253)
  - C: `const rvn_widget_class_t rvn_class_spin_box;`
  - Zig: `export const rvn_class_spin_box: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rspin_box_set_range()` (line 266)
  - C: `void Rspin_box_set_range(Rid id, double minimum, double maximum);`
  - Zig: `export fn Rspin_box_set_range(id: raven.Rid, minimum: f64, maximum: f64) void`

- `Rspin_box_set_value()` (line 274)
  - C: `void Rspin_box_set_value(Rid id, double value);`
  - Zig: `export fn Rspin_box_set_value(id: raven.Rid, value: f64) void`

- `Rspin_box_get_value()` (line 279)
  - C: `double Rspin_box_get_value(Rid id);`
  - Zig: `export fn Rspin_box_get_value(id: raven.Rid) f64`

- `Rspin_box_get_range()` (line 284)
  - C: `void Rspin_box_get_range(Rid id, double* minimum, double* maximum, double* step);`
  - Zig: `export fn Rspin_box_get_range(id: raven.Rid, minimum: [*c]f64, maximum: [*c]f64, step: [*c]f64) void`

- `Rspin_box_set_step()` (line 291)
  - C: `void Rspin_box_set_step(Rid id, double step);`
  - Zig: `export fn Rspin_box_set_step(id: raven.Rid, step: f64) void`

- `Rspin_box_set_decimals()` (line 296)
  - C: `void Rspin_box_set_decimals(Rid id, int decimals);`
  - Zig: `export fn Rspin_box_set_decimals(id: raven.Rid, decimals: c_int) void`

- `Rspin_box_set_changed_callback()` (line 302)
  - C: `void Rspin_box_set_changed_callback(Rid id, RSpinBoxChangedCallback callback, void* user_data);`
  - Zig: `export fn Rspin_box_set_changed_callback(id: raven.Rid, callback: raven.RSpinBoxChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_text_in`, `rvn_parse_float`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_fire_action`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_release_mouse`, `rvn_widget_text_color`

From `core/base_h.zig` (`base.<name>`): `rvn_clampi`, `rvn_color_fade`, `rvn_free`, `rvn_maxf`, `rvn_rect`, `rvn_strdup`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_control_radius`, `rvn_paint_surface`, `rvn_textedit_free`, `rvn_textedit_init`, `rvn_textedit_input`, `rvn_textedit_key`, `rvn_textedit_mouse_down`, `rvn_textedit_mouse_drag`, `rvn_textedit_paint`, `rvn_textedit_select_all`, `rvn_textedit_set_focused`, `rvn_textedit_set_text`, `rvn_widget_alive`, `rvn_widget_font_size`

Includes: `common.h`


## widgets/scroll_box.c  (291 lines) -> zig/src/widgets/scroll_box.zig

Exports (7):

- `rvn_class_scroll_box` global (line 196)
  - C: `const rvn_widget_class_t rvn_class_scroll_box;`
  - Zig: `export const rvn_class_scroll_box: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rscroll_box_set_orientation()` (line 219)
  - C: `void Rscroll_box_set_orientation(Rid id, ROrientation orientation);`
  - Zig: `export fn Rscroll_box_set_orientation(id: raven.Rid, orientation: raven.ROrientation) void`

- `Rscroll_box_set_scroll_both()` (line 229)
  - C: `void Rscroll_box_set_scroll_both(Rid id, int enabled);`
  - Zig: `export fn Rscroll_box_set_scroll_both(id: raven.Rid, enabled: c_int) void`

- `Rscroll_box_set_offset()` (line 235)
  - C: `void Rscroll_box_set_offset(Rid id, float x, float y);`
  - Zig: `export fn Rscroll_box_set_offset(id: raven.Rid, x: f32, y: f32) void`

- `Rscroll_box_get_offset()` (line 245)
  - C: `void Rscroll_box_get_offset(Rid id, float* x, float* y);`
  - Zig: `export fn Rscroll_box_get_offset(id: raven.Rid, x: [*c]f32, y: [*c]f32) void`

- `Rscroll_box_scroll_to_end()` (line 259)
  - C: `void Rscroll_box_scroll_to_end(Rid id);`
  - Zig: `export fn Rscroll_box_scroll_to_end(id: raven.Rid) void`

- `Rwidget_scroll_into_view()` (line 267)
  - C: `void Rwidget_scroll_into_view(Rid id);`
  - Zig: `export fn Rwidget_scroll_into_view(id: raven.Rid) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_parse_bool`, `rvn_parse_float`, `rvn_parse_orientation`, `rvn_widget_arrange_slot`, `rvn_widget_check`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_window_layout`

From `core/base_h.zig` (`base.<name>`): `rvn_error`, `rvn_maxf`, `rvn_rect`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_scrollbar_clamp`, `rvn_scrollbar_event`, `rvn_scrollbar_max`, `rvn_scrollbar_needed`, `rvn_scrollbar_paint`, `rvn_scrollbar_set`, `rvn_scrollbar_shown`, `rvn_scrollbar_wheel`

Includes: `common.h`


## widgets/border.c  (283 lines) -> zig/src/widgets/border.zig

Exports (9):

- `rvn_class_border` global (line 216)
  - C: `const rvn_widget_class_t rvn_class_border;`
  - Zig: `export const rvn_class_border: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rborder_set_effect()` (line 229)
  - C: `void Rborder_set_effect(Rid id, Rid shader, const RShaderLook* look);`
  - Zig: `export fn Rborder_set_effect(id: raven.Rid, shader: raven.Rid, look: [*c]const raven.RShaderLook) void`

- `Rborder_get_effect()` (line 239)
  - C: `Rid Rborder_get_effect(Rid id);`
  - Zig: `export fn Rborder_get_effect(id: raven.Rid) raven.Rid`

- `Rborder_set_padding()` (line 244)
  - C: `void Rborder_set_padding(Rid id, float left, float top, float right, float bottom);`
  - Zig: `export fn Rborder_set_padding(id: raven.Rid, left: f32, top: f32, right: f32, bottom: f32) void`

- `Rborder_set_background()` (line 250)
  - C: `void Rborder_set_background(Rid id, float r, float g, float b, float a);`
  - Zig: `export fn Rborder_set_background(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void`

- `Rborder_set_outline()` (line 255)
  - C: `void Rborder_set_outline(Rid id, float width, float r, float g, float b, float a);`
  - Zig: `export fn Rborder_set_outline(id: raven.Rid, width: f32, r: f32, g: f32, b: f32, a: f32) void`

- `Rborder_set_corner_radius()` (line 262)
  - C: `void Rborder_set_corner_radius(Rid id, float top_left, float top_right, float bottom_right, float bottom_left);`
  - Zig: `export fn Rborder_set_corner_radius(id: raven.Rid, top_left: f32, top_right: f32, bottom_right: f32, bottom_left: f32) void`

- `Rborder_set_material()` (line 273)
  - C: `void Rborder_set_material(Rid id, RMaterial material);`
  - Zig: `export fn Rborder_set_material(id: raven.Rid, material: raven.RMaterial) void`

- `Rborder_set_shadow()` (line 278)
  - C: `void Rborder_set_shadow(Rid id, float blur, float offset_x, float offset_y);`
  - Zig: `export fn Rborder_set_shadow(id: raven.Rid, blur: f32, offset_x: f32, offset_y: f32) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box4`, `rvn_paint_glass`, `rvn_paint_shader`, `rvn_paint_shadow`, `rvn_parse_bool`, `rvn_parse_color`, `rvn_parse_float`, `rvn_parse_floats`, `rvn_parse_margin`, `rvn_shader_from_file_cached`, `rvn_widget_arrange_slot`, `rvn_widget_color`, `rvn_widget_has_color`, `rvn_widget_has_metric`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_widget_set_color`, `rvn_window_pointer`, `rvn_xml_resolve_path`

From `core/base_h.zig` (`base.<name>`): `rvn_color_a`, `rvn_color_to_floats`, `rvn_free`, `rvn_margin`, `rvn_rect`, `rvn_rect_inset`, `rvn_rgba`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_glass_style`, `rvn_widget_hover`, `rvn_widget_press`

Includes: `common.h`, `../render/renderer.h`, `../xml/xml.h`


## widgets/checkbox.c  (281 lines) -> zig/src/widgets/checkbox.zig

Exports (8):

- `rvn_class_checkbox` global (line 224)
  - C: `const rvn_widget_class_t rvn_class_checkbox;`
  - Zig: `export const rvn_class_checkbox: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rcheckbox_create()` (line 238)
  - C: `Rid Rcheckbox_create(const char* text);`
  - Zig: `export fn Rcheckbox_create(text: [*c]const u8) raven.Rid`

- `Rcheckbox_set_text()` (line 247)
  - C: `void Rcheckbox_set_text(Rid id, const char* text);`
  - Zig: `export fn Rcheckbox_set_text(id: raven.Rid, text: [*c]const u8) void`

- `Rcheckbox_get_text()` (line 252)
  - C: `const char* Rcheckbox_get_text(Rid id);`
  - Zig: `export fn Rcheckbox_get_text(id: raven.Rid) [*c]const u8`

- `Rcheckbox_set_checked()` (line 257)
  - C: `void Rcheckbox_set_checked(Rid id, int checked);`
  - Zig: `export fn Rcheckbox_set_checked(id: raven.Rid, checked: c_int) void`

- `Rcheckbox_is_checked()` (line 262)
  - C: `int Rcheckbox_is_checked(Rid id);`
  - Zig: `export fn Rcheckbox_is_checked(id: raven.Rid) c_int`

- `Rcheckbox_set_style()` (line 267)
  - C: `void Rcheckbox_set_style(Rid id, RCheckboxStyle style);`
  - Zig: `export fn Rcheckbox_set_style(id: raven.Rid, style: raven.RCheckboxStyle) void`

- `Rcheckbox_set_changed_callback()` (line 277)
  - C: `void Rcheckbox_set_changed_callback(Rid id, RCheckboxChangedCallback callback, void* user_data);`
  - Zig: `export fn Rcheckbox_set_changed_callback(id: raven.Rid, callback: raven.RCheckboxChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_icon`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_release_mouse`, `rvn_widget_text_color`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_fade`, `rvn_color_mix`, `rvn_error`, `rvn_free`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_str_set`, `rvn_strdup`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_focus`, `rvn_paint_knob`, `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_line_height`, `rvn_widget_press`, `rvn_widget_text_width`

Includes: `common.h`


## widgets/background_blur.c  (275 lines) -> zig/src/widgets/background_blur.zig

Exports (13):

- `rvn_class_background_blur` global (line 173)
  - C: `const rvn_widget_class_t rvn_class_background_blur;`
  - Zig: `export const rvn_class_background_blur: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rbackground_blur_create()` (line 197)
  - C: `Rid Rbackground_blur_create(void);`
  - Zig: `export fn Rbackground_blur_create() raven.Rid`

- `Rbackground_blur_set_style()` (line 204)
  - C: `void Rbackground_blur_set_style(Rid id, RBlurStyle style);`
  - Zig: `export fn Rbackground_blur_set_style(id: raven.Rid, style: raven.RBlurStyle) void`

- `Rbackground_blur_get_style()` (line 214)
  - C: `RBlurStyle Rbackground_blur_get_style(Rid id);`
  - Zig: `export fn Rbackground_blur_get_style(id: raven.Rid) raven.RBlurStyle`

- `Rbackground_blur_set_radius()` (line 219)
  - C: `void Rbackground_blur_set_radius(Rid id, float radius);`
  - Zig: `export fn Rbackground_blur_set_radius(id: raven.Rid, radius: f32) void`

- `Rbackground_blur_get_radius()` (line 225)
  - C: `float Rbackground_blur_get_radius(Rid id);`
  - Zig: `export fn Rbackground_blur_get_radius(id: raven.Rid) f32`

- `Rbackground_blur_set_tint()` (line 230)
  - C: `void Rbackground_blur_set_tint(Rid id, float r, float g, float b, float a);`
  - Zig: `export fn Rbackground_blur_set_tint(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void`

- `Rbackground_blur_clear_tint()` (line 237)
  - C: `void Rbackground_blur_clear_tint(Rid id);`
  - Zig: `export fn Rbackground_blur_clear_tint(id: raven.Rid) void`

- `Rbackground_blur_set_saturation()` (line 243)
  - C: `void Rbackground_blur_set_saturation(Rid id, float saturation);`
  - Zig: `export fn Rbackground_blur_set_saturation(id: raven.Rid, saturation: f32) void`

- `Rbackground_blur_set_grain()` (line 249)
  - C: `void Rbackground_blur_set_grain(Rid id, float grain);`
  - Zig: `export fn Rbackground_blur_set_grain(id: raven.Rid, grain: f32) void`

- `Rbackground_blur_set_corner_radius()` (line 255)
  - C: `void Rbackground_blur_set_corner_radius(Rid id, float top_left, float top_right, float bottom_right, float bottom_left);`
  - Zig: `export fn Rbackground_blur_set_corner_radius(id: raven.Rid, top_left: f32, top_right: f32, bottom_right: f32, bottom_left: f32) void`

- `Rbackground_blur_set_padding()` (line 265)
  - C: `void Rbackground_blur_set_padding(Rid id, float left, float top, float right, float bottom);`
  - Zig: `export fn Rbackground_blur_set_padding(id: raven.Rid, left: f32, top: f32, right: f32, bottom: f32) void`

- `Rbackground_blur_set_shadow()` (line 271)
  - C: `void Rbackground_blur_set_shadow(Rid id, float shadow_blur);`
  - Zig: `export fn Rbackground_blur_set_shadow(id: raven.Rid, shadow_blur: f32) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_blur`, `rvn_paint_box4`, `rvn_paint_erase`, `rvn_paint_glass`, `rvn_paint_shadow`, `rvn_parse_color`, `rvn_parse_float`, `rvn_parse_floats`, `rvn_parse_margin`, `rvn_widget_arrange_slot`, `rvn_widget_check`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_window_see_through`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_a`, `rvn_error`, `rvn_margin`, `rvn_minf`, `rvn_rect`, `rvn_rect_inset`, `rvn_rgba`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_glass_style`

Includes: `common.h`


## widgets/splitter.c  (265 lines) -> zig/src/widgets/splitter.zig

Exports (3):

- `rvn_class_splitter` global (line 239)
  - C: `const rvn_widget_class_t rvn_class_splitter;`
  - Zig: `export const rvn_class_splitter: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rsplitter_set_orientation()` (line 252)
  - C: `void Rsplitter_set_orientation(Rid id, ROrientation orientation);`
  - Zig: `export fn Rsplitter_set_orientation(id: raven.Rid, orientation: raven.ROrientation) void`

- `Rsplitter_set_min_pane_size()` (line 262)
  - C: `void Rsplitter_set_min_pane_size(Rid id, float size);`
  - Zig: `export fn Rsplitter_set_min_pane_size(id: raven.Rid, size: f32) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_rect`, `rvn_parse_float`, `rvn_parse_orientation`, `rvn_widget_arrange_slot`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_widget_release_mouse`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_error`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rect_contains`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/slider.c  (264 lines) -> zig/src/widgets/slider.zig

Exports (8):

- `rvn_class_slider` global (line 206)
  - C: `const rvn_widget_class_t rvn_class_slider;`
  - Zig: `export const rvn_class_slider: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rslider_set_range()` (line 219)
  - C: `void Rslider_set_range(Rid id, float minimum, float maximum);`
  - Zig: `export fn Rslider_set_range(id: raven.Rid, minimum: f32, maximum: f32) void`

- `Rslider_set_value()` (line 228)
  - C: `void Rslider_set_value(Rid id, float value);`
  - Zig: `export fn Rslider_set_value(id: raven.Rid, value: f32) void`

- `Rslider_get_value()` (line 233)
  - C: `float Rslider_get_value(Rid id);`
  - Zig: `export fn Rslider_get_value(id: raven.Rid) f32`

- `Rslider_get_range()` (line 238)
  - C: `void Rslider_get_range(Rid id, float* minimum, float* maximum, float* step);`
  - Zig: `export fn Rslider_get_range(id: raven.Rid, minimum: [*c]f32, maximum: [*c]f32, step: [*c]f32) void`

- `Rslider_set_step()` (line 245)
  - C: `void Rslider_set_step(Rid id, float step);`
  - Zig: `export fn Rslider_set_step(id: raven.Rid, step: f32) void`

- `Rslider_set_orientation()` (line 250)
  - C: `void Rslider_set_orientation(Rid id, ROrientation orientation);`
  - Zig: `export fn Rslider_set_orientation(id: raven.Rid, orientation: raven.ROrientation) void`

- `Rslider_set_changed_callback()` (line 260)
  - C: `void Rslider_set_changed_callback(Rid id, RSliderChangedCallback callback, void* user_data);`
  - Zig: `export fn Rslider_set_changed_callback(id: raven.Rid, callback: raven.RSliderChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_spring`, `rvn_parse_float`, `rvn_parse_orientation`, `rvn_spring_set`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_release_mouse`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_fade`, `rvn_error`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_focus`, `rvn_paint_knob`, `rvn_widget_alive`, `rvn_widget_hover`, `rvn_widget_press`

Includes: `common.h`


## widgets/button.c  (234 lines) -> zig/src/widgets/button.zig

Exports (5):

- `rvn_class_button` global (line 192)
  - C: `const rvn_widget_class_t rvn_class_button;`
  - Zig: `export const rvn_class_button: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rbutton_create()` (line 206)
  - C: `Rid Rbutton_create(const char* text);`
  - Zig: `export fn Rbutton_create(text: [*c]const u8) raven.Rid`

- `Rbutton_set_text()` (line 215)
  - C: `void Rbutton_set_text(Rid id, const char* text);`
  - Zig: `export fn Rbutton_set_text(id: raven.Rid, text: [*c]const u8) void`

- `Rbutton_set_style()` (line 220)
  - C: `void Rbutton_set_style(Rid id, RButtonStyle style);`
  - Zig: `export fn Rbutton_set_style(id: raven.Rid, style: raven.RButtonStyle) void`

- `Rbutton_set_clicked_callback()` (line 230)
  - C: `void Rbutton_set_clicked_callback(Rid id, RButtonClickedCallback callback, void* user_data);`
  - Zig: `export fn Rbutton_set_clicked_callback(id: raven.Rid, callback: raven.RButtonClickedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_spring_kick`, `rvn_widget_add_child`, `rvn_widget_arrange_slot`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_create`, `rvn_widget_fire_action`, `rvn_widget_invalidate_paint`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_widget_release_mouse`, `rvn_widget_set_attribute`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_fade`, `rvn_color_mix`, `rvn_error`, `rvn_margin`, `rvn_maxf`, `rvn_rect`, `rvn_rect_inset`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_control_radius`, `rvn_paint_focus`, `rvn_paint_surface`, `rvn_widget_alive`, `rvn_widget_hover`, `rvn_widget_press`, `rvn_widget_squash`

Includes: `common.h`


## widgets/text_input.c  (233 lines) -> zig/src/widgets/text_input.zig

Exports (12):

- `rvn_class_text_input` global (line 162)
  - C: `const rvn_widget_class_t rvn_class_text_input;`
  - Zig: `export const rvn_class_text_input: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rtext_input_set_text()` (line 175)
  - C: `void Rtext_input_set_text(Rid id, const char* text);`
  - Zig: `export fn Rtext_input_set_text(id: raven.Rid, text: [*c]const u8) void`

- `Rtext_input_get_text()` (line 180)
  - C: `const char* Rtext_input_get_text(Rid id);`
  - Zig: `export fn Rtext_input_get_text(id: raven.Rid) [*c]const u8`

- `Rtext_input_set_placeholder()` (line 185)
  - C: `void Rtext_input_set_placeholder(Rid id, const char* text);`
  - Zig: `export fn Rtext_input_set_placeholder(id: raven.Rid, text: [*c]const u8) void`

- `Rtext_input_set_password()` (line 190)
  - C: `void Rtext_input_set_password(Rid id, int password);`
  - Zig: `export fn Rtext_input_set_password(id: raven.Rid, password: c_int) void`

- `Rtext_input_is_password()` (line 196)
  - C: `int Rtext_input_is_password(Rid id);`
  - Zig: `export fn Rtext_input_is_password(id: raven.Rid) c_int`

- `Rtext_input_is_read_only()` (line 201)
  - C: `int Rtext_input_is_read_only(Rid id);`
  - Zig: `export fn Rtext_input_is_read_only(id: raven.Rid) c_int`

- `Rtext_input_set_read_only()` (line 206)
  - C: `void Rtext_input_set_read_only(Rid id, int read_only);`
  - Zig: `export fn Rtext_input_set_read_only(id: raven.Rid, read_only: c_int) void`

- `Rtext_input_set_max_length()` (line 212)
  - C: `void Rtext_input_set_max_length(Rid id, int max_length);`
  - Zig: `export fn Rtext_input_set_max_length(id: raven.Rid, max_length: c_int) void`

- `Rtext_input_select_all()` (line 217)
  - C: `void Rtext_input_select_all(Rid id);`
  - Zig: `export fn Rtext_input_select_all(id: raven.Rid) void`

- `Rtext_input_set_changed_callback()` (line 223)
  - C: `void Rtext_input_set_changed_callback(Rid id, RTextChangedCallback callback, void* user_data);`
  - Zig: `export fn Rtext_input_set_changed_callback(id: raven.Rid, callback: raven.RTextChangedCallback, user_data: ?*anyopaque) void`

- `Rtext_input_set_committed_callback()` (line 229)
  - C: `void Rtext_input_set_committed_callback(Rid id, RTextChangedCallback callback, void* user_data);`
  - Zig: `export fn Rtext_input_set_committed_callback(id: raven.Rid, callback: raven.RTextChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_spring`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_parse_int`, `rvn_widget_capture_mouse`, `rvn_widget_color`, `rvn_widget_fire_action`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`, `rvn_widget_release_mouse`, `rvn_widget_text_color`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_fade`, `rvn_color_mix`, `rvn_free`, `rvn_maxf`, `rvn_rect`, `rvn_str_set`, `rvn_strdup`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_control_radius`, `rvn_paint_surface`, `rvn_textedit_free`, `rvn_textedit_init`, `rvn_textedit_input`, `rvn_textedit_key`, `rvn_textedit_mouse_down`, `rvn_textedit_mouse_drag`, `rvn_textedit_paint`, `rvn_textedit_select_all`, `rvn_textedit_set_focused`, `rvn_textedit_set_text`, `rvn_widget_alive`, `rvn_widget_font_size`

Includes: `common.h`


## widgets/image.c  (195 lines) -> zig/src/widgets/image.zig

Exports (9):

- `rvn_image_fit()` (line 46)
  - C: `void rvn_image_fit(RStretch stretch, rvn_vec2_t size, float width, float height, const float uv_in[4], rvn_rect_t* rect, float uv_out[4]);`
  - Zig: `export fn rvn_image_fit(stretch: raven.RStretch, size: base.rvn_vec2_t, width: f32, height: f32, uv_in: [*c]const f32, rect: [*c]base.rvn_rect_t, uv_out: [*c]f32) void`

- `rvn_parse_stretch()` (line 107)
  - C: `int rvn_parse_stretch(const char* value, RStretch* stretch);`
  - Zig: `export fn rvn_parse_stretch(value: [*c]const u8, stretch: [*c]raven.RStretch) c_int`

- `rvn_class_image` global (line 138)
  - C: `const rvn_widget_class_t rvn_class_image;`
  - Zig: `export const rvn_class_image: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rimage_set_texture()` (line 149)
  - C: `void Rimage_set_texture(Rid id, Rid texture);`
  - Zig: `export fn Rimage_set_texture(id: raven.Rid, texture: raven.Rid) void`

- `Rimage_set_tint_color()` (line 159)
  - C: `void Rimage_set_tint_color(Rid id, float r, float g, float b, float a);`
  - Zig: `export fn Rimage_set_tint_color(id: raven.Rid, r: f32, g: f32, b: f32, a: f32) void`

- `Rimage_set_stretch()` (line 165)
  - C: `void Rimage_set_stretch(Rid id, RStretch stretch);`
  - Zig: `export fn Rimage_set_stretch(id: raven.Rid, stretch: raven.RStretch) void`

- `Rimage_set_region()` (line 175)
  - C: `void Rimage_set_region(Rid id, float min_u, float min_v, float max_u, float max_v);`
  - Zig: `export fn Rimage_set_region(id: raven.Rid, min_u: f32, min_v: f32, max_u: f32, max_v: f32) void`

- `Rimage_set_corner_radius()` (line 185)
  - C: `void Rimage_set_corner_radius(Rid id, float radius);`
  - Zig: `export fn Rimage_set_corner_radius(id: raven.Rid, radius: f32) void`

- `Rimage_set_tint_text()` (line 191)
  - C: `void Rimage_set_tint_text(Rid id, int enabled);`
  - Zig: `export fn Rimage_set_tint_text(id: raven.Rid, enabled: c_int) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_image`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_parse_bool`, `rvn_parse_color`, `rvn_parse_float`, `rvn_parse_floats`, `rvn_texture_get`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_text_color`

From `core/base_h.zig` (`base.<name>`): `rvn_color_a`, `rvn_color_fade`, `rvn_error`, `rvn_maxf`, `rvn_minf`, `rvn_rect`, `rvn_rgba`, `rvn_stricmp`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_xml_texture`

Includes: `common.h`, `../render/renderer.h`


## widgets/expander.c  (186 lines) -> zig/src/widgets/expander.zig

Exports (6):

- `rvn_class_expander` global (line 146)
  - C: `const rvn_widget_class_t rvn_class_expander;`
  - Zig: `export const rvn_class_expander: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rexpander_set_title()` (line 162)
  - C: `void Rexpander_set_title(Rid id, const char* title);`
  - Zig: `export fn Rexpander_set_title(id: raven.Rid, title: [*c]const u8) void`

- `Rexpander_get_title()` (line 167)
  - C: `const char* Rexpander_get_title(Rid id);`
  - Zig: `export fn Rexpander_get_title(id: raven.Rid) [*c]const u8`

- `Rexpander_set_expanded()` (line 172)
  - C: `void Rexpander_set_expanded(Rid id, int expanded);`
  - Zig: `export fn Rexpander_set_expanded(id: raven.Rid, expanded: c_int) void`

- `Rexpander_is_expanded()` (line 177)
  - C: `int Rexpander_is_expanded(Rid id);`
  - Zig: `export fn Rexpander_is_expanded(id: raven.Rid) c_int`

- `Rexpander_set_changed_callback()` (line 182)
  - C: `void Rexpander_set_changed_callback(Rid id, RExpanderChangedCallback callback, void* user_data);`
  - Zig: `export fn Rexpander_set_changed_callback(id: raven.Rid, callback: raven.RExpanderChangedCallback, user_data: ?*anyopaque) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_chevron`, `rvn_paint_text_in`, `rvn_parse_bool`, `rvn_spring_moving`, `rvn_spring_set`, `rvn_widget_animate_layout`, `rvn_widget_arrange_slot`, `rvn_widget_color`, `rvn_widget_fire_action`, `rvn_widget_invalidate_layout`, `rvn_widget_invalidate_paint`, `rvn_widget_measure_slot`, `rvn_widget_metric`, `rvn_widget_origin`, `rvn_widget_text_color`, `rvn_window_forget_widget`

From `core/base_h.zig` (`base.<name>`): `rvn_free`, `rvn_maxf`, `rvn_rect`, `rvn_str_set`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): `rvn_paint_focus`, `rvn_widget_alive`, `rvn_widget_font_size`, `rvn_widget_text_width`

Includes: `common.h`


## widgets/box_panel.c  (153 lines) -> zig/src/widgets/box_panel.zig

Exports (4):

- `rvn_class_vbox` global (line 98)
  - C: `const rvn_widget_class_t rvn_class_vbox;`
  - Zig: `export const rvn_class_vbox: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `rvn_class_hbox` global (line 108)
  - C: `const rvn_widget_class_t rvn_class_hbox;`
  - Zig: `export const rvn_class_hbox: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rpanel_get_spacing()` (line 122)
  - C: `float Rpanel_get_spacing(Rid id);`
  - Zig: `export fn Rpanel_get_spacing(id: raven.Rid) f32`

- `Rpanel_set_spacing()` (line 137)
  - C: `void Rpanel_set_spacing(Rid id, float spacing);`
  - Zig: `export fn Rpanel_set_spacing(id: raven.Rid, spacing: f32) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_parse_float`, `rvn_widget_arrange_slot`, `rvn_widget_invalidate_layout`, `rvn_widget_measure_slot`

From `core/base_h.zig` (`base.<name>`): `rvn_error`, `rvn_maxf`, `rvn_rect`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/progress_bar.c  (132 lines) -> zig/src/widgets/progress_bar.zig

Exports (5):

- `rvn_class_progress_bar` global (line 52)
  - C: `const rvn_widget_class_t rvn_class_progress_bar;`
  - Zig: `export const rvn_class_progress_bar: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rprogress_bar_set_value()` (line 62)
  - C: `void Rprogress_bar_set_value(Rid id, float value);`
  - Zig: `export fn Rprogress_bar_set_value(id: raven.Rid, value: f32) void`

- `Rprogress_bar_get_value()` (line 70)
  - C: `float Rprogress_bar_get_value(Rid id);`
  - Zig: `export fn Rprogress_bar_get_value(id: raven.Rid) f32`

- `rvn_class_separator` global (line 113)
  - C: `const rvn_widget_class_t rvn_class_separator;`
  - Zig: `export const rvn_class_separator: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rseparator_set_orientation()` (line 124)
  - C: `void Rseparator_set_orientation(Rid id, ROrientation orientation);`
  - Zig: `export fn Rseparator_set_orientation(id: raven.Rid, orientation: raven.ROrientation) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_paint_box`, `rvn_paint_pop_clip`, `rvn_paint_push_clip`, `rvn_paint_rect`, `rvn_paint_spring`, `rvn_parse_float`, `rvn_parse_orientation`, `rvn_widget_color`, `rvn_widget_invalidate_paint`, `rvn_widget_metric`

From `core/base_h.zig` (`base.<name>`): `rvn_clampf`, `rvn_color_fade`, `rvn_error`, `rvn_minf`, `rvn_rect`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/wrap_box.c  (81 lines) -> zig/src/widgets/wrap_box.zig

Exports (1):

- `rvn_class_wrap_box` global (line 73)
  - C: `const rvn_widget_class_t rvn_class_wrap_box;`
  - Zig: `export const rvn_class_wrap_box: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_parse_float`, `rvn_widget_arrange_slot`, `rvn_widget_invalidate_layout`, `rvn_widget_measure_slot`

From `core/base_h.zig` (`base.<name>`): `rvn_maxf`, `rvn_rect`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/switcher.c  (75 lines) -> zig/src/widgets/switcher.zig

Exports (3):

- `rvn_class_switcher` global (line 56)
  - C: `const rvn_widget_class_t rvn_class_switcher;`
  - Zig: `export const rvn_class_switcher: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rswitcher_set_index()` (line 67)
  - C: `void Rswitcher_set_index(Rid id, int index);`
  - Zig: `export fn Rswitcher_set_index(id: raven.Rid, index: c_int) void`

- `Rswitcher_get_index()` (line 72)
  - C: `int Rswitcher_get_index(Rid id);`
  - Zig: `export fn Rswitcher_get_index(id: raven.Rid) c_int`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_parse_int`, `rvn_widget_arrange_slot`, `rvn_widget_invalidate_layout`, `rvn_widget_measure_slot`, `rvn_window_forget_widget`

From `core/base_h.zig` (`base.<name>`): `rvn_rect`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/size_box.c  (71 lines) -> zig/src/widgets/size_box.zig

Exports (2):

- `rvn_class_size_box` global (line 58)
  - C: `const rvn_widget_class_t rvn_class_size_box;`
  - Zig: `export const rvn_class_size_box: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rsize_box_set_aspect_ratio()` (line 67)
  - C: `void Rsize_box_set_aspect_ratio(Rid id, float ratio);`
  - Zig: `export fn Rsize_box_set_aspect_ratio(id: raven.Rid, ratio: f32) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_parse_floats`, `rvn_widget_arrange`, `rvn_widget_arrange_slot`, `rvn_widget_invalidate_layout`

From `core/base_h.zig` (`base.<name>`): `rvn_rect`, `rvn_rect_inset`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/canvas.c  (59 lines) -> zig/src/widgets/canvas.zig

Exports (1):

- `rvn_class_canvas` global (line 52)
  - C: `const rvn_widget_class_t rvn_class_canvas;`
  - Zig: `export const rvn_class_canvas: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_widget_arrange`, `rvn_widget_measure`

From `core/base_h.zig` (`base.<name>`): `rvn_maxf`, `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


## widgets/overlay.c  (32 lines) -> zig/src/widgets/overlay.zig

Exports (3):

- `rvn_class_overlay` global (line 13)
  - C: `const rvn_widget_class_t rvn_class_overlay;`
  - Zig: `export const rvn_class_overlay: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `rvn_class_spacer` global (line 21)
  - C: `const rvn_widget_class_t rvn_class_spacer;`
  - Zig: `export const rvn_class_spacer: common.rvn_widget_class_t = <initializer of the C file>;` (declared `pub extern const/var` in common_h.zig / its header unit)

- `Rspacer_set_size()` (line 28)
  - C: `void Rspacer_set_size(Rid id, float width, float height);`
  - Zig: `export fn Rspacer_set_size(id: raven.Rid, width: f32, height: f32) void`

Extern functions of other modules it calls (declared in `externs.zig`, `ext.<name>`): `rvn_widget_invalidate_layout`

From `core/base_h.zig` (`base.<name>`): `rvn_vec2`

Shared helpers of the widgets module (`common_h.zig`, `common.<name>`): none

Includes: `common.h`


Total exported symbols in the module: 599

## Layout check removed (2026-11-13)

The C-vs-Zig layout check of this module's private types (layout/*_layout.c and its Zig side) was removed: every C file of
the library is translated, so no C code compiles the private headers any more and the header units are the only definition
of these types. `check.sh` step 3 still compares the public types (include/raven) with the C compiler, and step 3b the
system types (pthread, timespec, pollfd, dirent) the Zig code takes from std.c (layout/system_layout.c).
