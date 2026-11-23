# xml module: exported symbols and externs

Every `.c` file of `src/xml` and the symbols it must export (checked by `check_unit.sh`). The C signature is the exact one of the definition; the Zig line is the `export fn` to write (parameter names may follow the C ones; types may not change). No `.c` file of the module defines a non-static global variable. `static` helpers are plain `fn`.

Types: `src/xml/xml_h.zig` (xml.h), `src/xml/xml_watch_h.zig` (xml_watch.h). Other modules: `src/xml/externs.zig` (see the end). In a translation: `const xml = @import("xml_h.zig"); const watch = @import("xml_watch_h.zig"); const ext = @import("externs.zig");` and `ext.base`, `ext.context` (`g_rvn`, `rvn_api_check`, `rvn_dispatch_begin/end`, `RVN_API_GUARD` = `if (ext.context.rvn_api_check("Rfn") == 0) return result;` with the literal function name), `ext.handle` (pools), `ext.fs`, `ext.fs_watch`.

In the Zig lines below `xml.rvn_xml_document_t` etc. is spelled without the module prefix for brevity; `Rid` is `raven.Rid`. The typedef callbacks (`RXmlTagCreateCallback`, ...) are in `raven`.


## src/xml/xml_components.c  ->  src/xml/xml_components.zig  (8 exports)

- `void rvn_xml_components_shutdown(void)`
  - Zig: `export fn rvn_xml_components_shutdown() void`
- `int rvn_xml_expand(rvn_xml_document_t* document, int* registered)`
  - Zig: `export fn rvn_xml_expand(document: [*c]rvn_xml_document_t, registered: [*c]c_int) c_int`
- `int Rxml_register_widgets(const char* xml, size_t size)`
  - Zig: `export fn Rxml_register_widgets(xml: [*c]const u8, size: usize) c_int`
- `int rvn_xml_component_parameter(const char* name, int index, const char** parameter, const char** default_value)`
  - Zig: `export fn rvn_xml_component_parameter(component: [*c]const u8, index: c_int, name: [*c][*c]const u8, default_value: [*c][*c]const u8) c_int`
- `void Rxml_unregister_widget(const char* name)`
  - Zig: `export fn Rxml_unregister_widget(name: [*c]const u8) void`
- `int Rxml_is_widget_registered(const char* name)`
  - Zig: `export fn Rxml_is_widget_registered(name: [*c]const u8) c_int`
- `int Rxml_get_registered_widget_count(void)`
  - Zig: `export fn Rxml_get_registered_widget_count() c_int`
- `const char* Rxml_get_registered_widget_name(int index)`
  - Zig: `export fn Rxml_get_registered_widget_name(index: c_int) [*c]const u8`

## src/xml/xml_dom.c  ->  src/xml/xml_dom.zig  (37 exports)

- `void rvn_xml_dom_shutdown(void)`
  - Zig: `export fn rvn_xml_dom_shutdown() void`
- `Rid Rxml_document_create(const char* root_tag)`
  - Zig: `export fn Rxml_document_create(root_tag: [*c]const u8) Rid`
- `Rid Rxml_document_parse(const char* xml, size_t size, RXmlError* error)`
  - Zig: `export fn Rxml_document_parse(xml: [*c]const u8, size: usize, @"error": [*c]RXmlError) Rid`
- `Rid Rxml_document_load(const char* path)`
  - Zig: `export fn Rxml_document_load(path: [*c]const u8) Rid`
- `void Rxml_document_destroy(Rid id)`
  - Zig: `export fn Rxml_document_destroy(document: Rid) void`
- `int Rxml_document_is_valid(Rid id)`
  - Zig: `export fn Rxml_document_is_valid(document: Rid) c_int`
- `Rid Rxml_document_get_root(Rid id)`
  - Zig: `export fn Rxml_document_get_root(document: Rid) Rid`
- `const char* Rxml_document_to_string(Rid id)`
  - Zig: `export fn Rxml_document_to_string(document: Rid) [*c]const u8`
- `int Rxml_document_save(Rid id, const char* path)`
  - Zig: `export fn Rxml_document_save(document: Rid, path: [*c]const u8) c_int`
- `Rid Rxml_document_create_widget(Rid id)`
  - Zig: `export fn Rxml_document_create_widget(document: Rid) Rid`
- `Rid Rxml_document_create_window(Rid id)`
  - Zig: `export fn Rxml_document_create_window(document: Rid) Rid`
- `Rid Rxml_node_get_widget(Rid id)`
  - Zig: `export fn Rxml_node_get_widget(node: Rid) Rid`
- `Rid Rwidget_get_xml_node(Rid id)`
  - Zig: `export fn Rwidget_get_xml_node(widget: Rid) Rid`
- `int Rxml_node_is_valid(Rid id)`
  - Zig: `export fn Rxml_node_is_valid(node: Rid) c_int`
- `Rid Rxml_node_get_document(Rid id)`
  - Zig: `export fn Rxml_node_get_document(node: Rid) Rid`
- `const char* Rxml_node_get_tag(Rid id)`
  - Zig: `export fn Rxml_node_get_tag(node: Rid) [*c]const u8`
- `void Rxml_node_set_tag(Rid id, const char* tag)`
  - Zig: `export fn Rxml_node_set_tag(node: Rid, tag: [*c]const u8) void`
- `int Rxml_node_is_comment(Rid id)`
  - Zig: `export fn Rxml_node_is_comment(node: Rid) c_int`
- `const char* Rxml_node_get_text(Rid id)`
  - Zig: `export fn Rxml_node_get_text(node: Rid) [*c]const u8`
- `void Rxml_node_set_text(Rid id, const char* text)`
  - Zig: `export fn Rxml_node_set_text(node: Rid, text: [*c]const u8) void`
- `Rid Rxml_node_get_parent(Rid id)`
  - Zig: `export fn Rxml_node_get_parent(node: Rid) Rid`
- `int Rxml_node_get_child_count(Rid id)`
  - Zig: `export fn Rxml_node_get_child_count(node: Rid) c_int`
- `Rid Rxml_node_get_child(Rid id, int index)`
  - Zig: `export fn Rxml_node_get_child(node: Rid, index: c_int) Rid`
- `int Rxml_node_get_index(Rid id)`
  - Zig: `export fn Rxml_node_get_index(node: Rid) c_int`
- `Rid Rxml_node_add_child(Rid parent_id, const char* tag, int index)`
  - Zig: `export fn Rxml_node_add_child(parent: Rid, tag: [*c]const u8, index: c_int) Rid`
- `Rid Rxml_node_add_comment(Rid parent_id, const char* text, int index)`
  - Zig: `export fn Rxml_node_add_comment(parent: Rid, text: [*c]const u8, index: c_int) Rid`
- `Rid Rxml_node_add_xml(Rid parent_id, const char* xml, size_t size, int index)`
  - Zig: `export fn Rxml_node_add_xml(parent: Rid, xml: [*c]const u8, size: usize, index: c_int) Rid`
- `void Rxml_node_remove(Rid id)`
  - Zig: `export fn Rxml_node_remove(node: Rid) void`
- `int Rxml_node_move(Rid id, Rid new_parent_id, int index)`
  - Zig: `export fn Rxml_node_move(node: Rid, new_parent: Rid, index: c_int) c_int`
- `Rid Rxml_node_duplicate(Rid id)`
  - Zig: `export fn Rxml_node_duplicate(node: Rid) Rid`
- `const char* Rxml_node_to_string(Rid id)`
  - Zig: `export fn Rxml_node_to_string(node: Rid) [*c]const u8`
- `int Rxml_node_get_attribute_count(Rid id)`
  - Zig: `export fn Rxml_node_get_attribute_count(node: Rid) c_int`
- `const char* Rxml_node_get_attribute_name(Rid id, int index)`
  - Zig: `export fn Rxml_node_get_attribute_name(node: Rid, index: c_int) [*c]const u8`
- `const char* Rxml_node_get_attribute_value(Rid id, int index)`
  - Zig: `export fn Rxml_node_get_attribute_value(node: Rid, index: c_int) [*c]const u8`
- `const char* Rxml_node_get_attribute(Rid id, const char* name)`
  - Zig: `export fn Rxml_node_get_attribute(node: Rid, name: [*c]const u8) [*c]const u8`
- `void Rxml_node_set_attribute(Rid id, const char* name, const char* value)`
  - Zig: `export fn Rxml_node_set_attribute(node: Rid, name: [*c]const u8, value: [*c]const u8) void`
- `int Rxml_node_get_line(Rid id)`
  - Zig: `export fn Rxml_node_get_line(node: Rid) c_int`

## src/xml/xml_watch.c  ->  src/xml/xml_watch.zig  (12 exports)

- `void rvn_watch_add(const char* path, rvn_watch_callback_t callback, void* user)`
  - Zig: `export fn rvn_watch_add(path: [*c]const u8, callback: rvn_watch_callback_t, user: ?*anyopaque) void`
- `int rvn_watch_quiet(void)`
  - Zig: `export fn rvn_watch_quiet() c_int`
- `void rvn_live_begin(void)`
  - Zig: `export fn rvn_live_begin() void`
- `void rvn_live_end(void)`
  - Zig: `export fn rvn_live_end() void`
- `void rvn_live_dependency(const char* path)`
  - Zig: `export fn rvn_live_dependency(path: [*c]const u8) void`
- `void rvn_live_add(const char* path, int is_window, Rid target, rvn_xml_document_t* document)`
  - Zig: `export fn rvn_live_add(path: [*c]const u8, is_window: c_int, target: raven.Rid, document: [*c]xml.rvn_xml_document_t) void`
- `void rvn_live_watch_widgets(const char* path)`
  - Zig: `export fn rvn_live_watch_widgets(path: [*c]const u8) void`
- `void rvn_live_shutdown(void)`
  - Zig: `export fn rvn_live_shutdown() void`
- `void Rxml_set_live_reload(int enabled)`
  - Zig: `export fn Rxml_set_live_reload(enabled: c_int) void`
- `int Rxml_get_live_reload(void)`
  - Zig: `export fn Rxml_get_live_reload() c_int`
- `void Rxml_set_reload_callback(RXmlReloadCallback callback, void* user_data)`
  - Zig: `export fn Rxml_set_reload_callback(callback: RXmlReloadCallback, user_data: ?*anyopaque) void`
- `int Rxml_check_files(void)`
  - Zig: `export fn Rxml_check_files() c_int`

## src/xml/xml_loader.c  ->  src/xml/xml_loader.zig  (27 exports)

- `char* rvn_xml_resolve_path(const char* path)`
  - Zig: `export fn rvn_xml_resolve_path(path: [*c]const u8) [*c]u8`
- `Rid rvn_xml_texture(const char* path)`
  - Zig: `export fn rvn_xml_texture(path: [*c]const u8) raven.Rid`
- `Rid rvn_xml_font(const char* path)`
  - Zig: `export fn rvn_xml_font(path: [*c]const u8) raven.Rid`
- `void rvn_xml_shutdown(void)`
  - Zig: `export fn rvn_xml_shutdown() void`
- `int rvn_xml_tag_find(const char* name)`
  - Zig: `export fn rvn_xml_tag_find(name: [*c]const u8) c_int`
- `int rvn_xml_tag_attribute(rvn_widget_t* widget, const char* name, const char* value)`
  - Zig: `export fn rvn_xml_tag_attribute(widget: [*c]rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int`
- `int Rxml_register_tag(const char* tag, RXmlTagCreateCallback create, RXmlTagAttributeCallback set_attribute, void* user_data)`
  - Zig: `export fn Rxml_register_tag(tag: [*c]const u8, create: RXmlTagCreateCallback, set_attribute: RXmlTagAttributeCallback, user_data: ?*anyopaque) c_int`
- `void Rxml_unregister_tag(const char* tag)`
  - Zig: `export fn Rxml_unregister_tag(tag: [*c]const u8) void`
- `const char* Rxml_resolve_path(const char* path)`
  - Zig: `export fn Rxml_resolve_path(path: [*c]const u8) [*c]const u8`
- `int Rxml_is_tag_registered(const char* tag)`
  - Zig: `export fn Rxml_is_tag_registered(tag: [*c]const u8) c_int`
- `rvn_widget_t* rvn_xml_build_node(const rvn_xml_node_t* node)`
  - Zig: `export fn rvn_xml_build_node(node: [*c]const rvn_xml_node_t) [*c]rvn_widget_t`
- `int rvn_xml_load(rvn_xml_document_t* document, const char* xml, size_t size, const char* function)`
  - Zig: `export fn rvn_xml_load(document: [*c]rvn_xml_document_t, xml: [*c]const u8, size: usize, function: [*c]const u8) c_int`
- `int rvn_xml_window_parts(const rvn_xml_node_t* root, const rvn_xml_node_t** content, const rvn_xml_node_t** island)`
  - Zig: `export fn rvn_xml_window_parts(root: [*c]const rvn_xml_node_t, content: [*c][*c]const rvn_xml_node_t, island: [*c][*c]const rvn_xml_node_t) c_int`
- `Rid rvn_xml_make_widget(rvn_xml_document_t* document, int window_content)`
  - Zig: `export fn rvn_xml_make_widget(document: [*c]rvn_xml_document_t, window_content: c_int) raven.Rid`
- `Rid rvn_xml_build_widget(rvn_xml_document_t* document, int window_content, const char* function)`
  - Zig: `export fn rvn_xml_build_widget(document: [*c]rvn_xml_document_t, window_content: c_int, function: [*c]const u8) raven.Rid`
- `void rvn_xml_window_read(const rvn_xml_node_t* root, rvn_xml_window_t* window, int report)`
  - Zig: `export fn rvn_xml_window_read(root: [*c]const rvn_xml_node_t, description: [*c]rvn_xml_window_t, report: c_int) void`
- `void rvn_xml_window_shortcuts(rvn_window_t* window, const rvn_xml_node_t* root, int add)`
  - Zig: `export fn rvn_xml_window_shortcuts(window: [*c]rvn_window_t, root: [*c]const rvn_xml_node_t, add: c_int) void`
- `Rid rvn_xml_make_window(rvn_xml_document_t* document)`
  - Zig: `export fn rvn_xml_make_window(document: [*c]rvn_xml_document_t) raven.Rid`
- `Rid rvn_xml_build_window(rvn_xml_document_t* document, const char* function)`
  - Zig: `export fn rvn_xml_build_window(document: [*c]rvn_xml_document_t, function: [*c]const u8) raven.Rid`
- `Rid Rwidget_create_from_xml(const char* xml, size_t size)`
  - Zig: `export fn Rwidget_create_from_xml(xml: [*c]const u8, size: usize) Rid`
- `Rid Rwindow_create_from_xml(const char* xml, size_t size)`
  - Zig: `export fn Rwindow_create_from_xml(xml: [*c]const u8, size: usize) Rid`
- `void rvn_xml_push_file_dir(const char* path, char** previous)`
  - Zig: `export fn rvn_xml_push_file_dir(path: [*c]const u8, previous: [*c][*c]u8) void`
- `void rvn_xml_pop_file_dir(char* previous)`
  - Zig: `export fn rvn_xml_pop_file_dir(previous: [*c]u8) void`
- `Rid Rwidget_create_from_xml_file(const char* path)`
  - Zig: `export fn Rwidget_create_from_xml_file(path: [*c]const u8) Rid`
- `Rid Rwindow_create_from_xml_file(const char* path)`
  - Zig: `export fn Rwindow_create_from_xml_file(path: [*c]const u8) Rid`
- `int Rxml_register_widgets_from_file(const char* path)`
  - Zig: `export fn Rxml_register_widgets_from_file(path: [*c]const u8) c_int`
- `void Rxml_set_base_path(const char* path)`
  - Zig: `export fn Rxml_set_base_path(path: [*c]const u8) void`

## src/xml/xml_schema.c  ->  src/xml/xml_schema.zig  (6 exports)

- `int Rxml_get_tag_count(void)`
  - Zig: `export fn Rxml_get_tag_count() c_int`
- `const char* Rxml_get_tag_name(int index)`
  - Zig: `export fn Rxml_get_tag_name(index: c_int) [*c]const u8`
- `const char* Rxml_get_tag_description(const char* tag)`
  - Zig: `export fn Rxml_get_tag_description(tag: [*c]const u8) [*c]const u8`
- `int Rxml_get_tag_children(const char* tag)`
  - Zig: `export fn Rxml_get_tag_children(tag: [*c]const u8) c_int`
- `int Rxml_get_attribute_count(const char* tag)`
  - Zig: `export fn Rxml_get_attribute_count(tag: [*c]const u8) c_int`
- `int Rxml_get_attribute_info(const char* tag, int index, RXmlAttributeInfo* info)`
  - Zig: `export fn Rxml_get_attribute_info(tag: [*c]const u8, index: c_int, info: [*c]RXmlAttributeInfo) c_int`

## src/xml/xml_attributes.c  ->  src/xml/xml_attributes.zig  (15 exports)

- `int rvn_parse_float(const char* text, float* value)`
  - Zig: `export fn rvn_parse_float(text: [*c]const u8, value: [*c]f32) c_int`
- `int rvn_parse_int(const char* text, int* value)`
  - Zig: `export fn rvn_parse_int(text: [*c]const u8, value: [*c]c_int) c_int`
- `int rvn_parse_bool(const char* text, int* value)`
  - Zig: `export fn rvn_parse_bool(text: [*c]const u8, value: [*c]c_int) c_int`
- `int rvn_parse_floats(const char* text, float* values, int max)`
  - Zig: `export fn rvn_parse_floats(text: [*c]const u8, values: [*c]f32, max: c_int) c_int`
- `int rvn_parse_margin(const char* text, rvn_margin_t* margin)`
  - Zig: `export fn rvn_parse_margin(text: [*c]const u8, margin: [*c]base.rvn_margin_t) c_int`
- `int rvn_parse_color(const char* text, rvn_color_t* color)`
  - Zig: `export fn rvn_parse_color(text: [*c]const u8, color: [*c]base.rvn_color_t) c_int`
- `int rvn_parse_orientation(const char* text, ROrientation* orientation)`
  - Zig: `export fn rvn_parse_orientation(text: [*c]const u8, orientation: [*c]raven.ROrientation) c_int`
- `int rvn_color_role_by_name(const char* name, RColorRole* role)`
  - Zig: `export fn rvn_color_role_by_name(name: [*c]const u8, role: [*c]raven.RColorRole) c_int`
- `int rvn_metric_by_name(const char* name, RMetric* metric)`
  - Zig: `export fn rvn_metric_by_name(name: [*c]const u8, metric: [*c]raven.RMetric) c_int`
- `const char* rvn_color_role_name(RColorRole role)`
  - Zig: `export fn rvn_color_role_name(role: raven.RColorRole) [*c]const u8`
- `const char* rvn_metric_name(RMetric metric)`
  - Zig: `export fn rvn_metric_name(metric: raven.RMetric) [*c]const u8`
- `int rvn_parse_material(const char* text, RMaterial* material)`
  - Zig: `export fn rvn_parse_material(text: [*c]const u8, material: [*c]raven.RMaterial) c_int`
- `int rvn_widget_set_base_attribute(rvn_widget_t* widget, const char* name, const char* value)`
  - Zig: `export fn rvn_widget_set_base_attribute(widget: [*c]ext.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int`
- `int rvn_widget_set_attribute(rvn_widget_t* widget, const char* name, const char* value)`
  - Zig: `export fn rvn_widget_set_attribute(widget: [*c]ext.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) c_int`
- `int Rwidget_set_attribute(Rid id, const char* name, const char* value)`
  - Zig: `export fn Rwidget_set_attribute(widget: Rid, name: [*c]const u8, value: [*c]const u8) c_int`

## src/xml/xml_parser.c  ->  src/xml/xml_parser.zig  (4 exports)

- `int rvn_xml_parse(rvn_xml_document_t* document, const char* text, size_t size)`
  - Zig: `export fn rvn_xml_parse(document: [*c]rvn_xml_document_t, text: [*c]const u8, size: usize) c_int`
- `int rvn_xml_parse_keeping_comments(rvn_xml_document_t* document, const char* text, size_t size)`
  - Zig: `export fn rvn_xml_parse_keeping_comments(document: [*c]rvn_xml_document_t, text: [*c]const u8, size: usize) c_int`
- `void rvn_xml_free(rvn_xml_document_t* document)`
  - Zig: `export fn rvn_xml_free(document: [*c]rvn_xml_document_t) void`
- `const char* rvn_xml_attribute(const rvn_xml_node_t* node, const char* name)`
  - Zig: `export fn rvn_xml_attribute(node: [*c]const rvn_xml_node_t, name: [*c]const u8) [*c]const u8`

## src/xml/xml_compiled.c  ->  src/xml/xml_compiled.zig  (2 exports)

- `Rid Rwindow_create_from_compiled(const RXmlCompiledNode* nodes, int count, const char* source)`
  - Zig: `export fn Rwindow_create_from_compiled(nodes: [*c]const RXmlCompiledNode, count: c_int, source: [*c]const u8) Rid`
- `Rid Rwidget_create_from_compiled(const RXmlCompiledNode* nodes, int count, const char* source)`
  - Zig: `export fn Rwidget_create_from_compiled(nodes: [*c]const RXmlCompiledNode, count: c_int, source: [*c]const u8) Rid`

## Externs from OTHER modules (`src/xml/externs.zig`)

`externs.zig` re-exports the finished header units and declares the rest. What the xml `.c` files call, and where it comes from:

| symbol(s) | where in Zig |
|---|---|
| `rvn_alloc rvn_calloc rvn_free rvn_strdup rvn_str_set rvn_stricmp rvn_strnicmp rvn_error rvn_arena_init/alloc/strndup/free rvn_read_file rvn_memory_file_exists rvn_path_join rvn_path_dir rvn_utf8_count rvn_utf8_encode rvn_margin rvn_rgba8 rvn_hex rvn_clampf rvn_color_to_floats`, `rvn_arena_t rvn_color_t rvn_margin_t rvn_text_t` | `ext.base` (core/base_h.zig) |
| `g_rvn` (uses: `.initialized`, `.xml_documents`, `.xml_nodes`, `.xml_base_path`, `.mono_font`, `.default_font`), `rvn_api_check rvn_dispatch_begin rvn_dispatch_end`, `rvn_theme_t` | `ext.context` (core/context_h.zig) |
| `rvn_pool_add rvn_pool_get rvn_pool_remove rvn_pool_at rvn_pool_t` | `ext.handle` |
| `rvn_file_stamp rvn_write_file rvn_path_absolute rvn_is_http_url` | `ext.fs` |
| `rvn_fs_watch_start rvn_fs_watch_add rvn_fs_watch_stop` | `ext.fs_watch` |
| `Rtask_post Rtimer_create Rtimer_destroy Rtimer_is_valid Rfont_create_from_file Rfont_is_valid Rtexture_create_from_file Rtheme_use Rlocale_load_csv Rwidget_set_direction Rwindow_create Rwindow_set_* ...` (public API) | `raven.*` |
| `rvn_texture_get rvn_texture_create_from_url_async` | `core`-level `render/renderer_h.zig` (not re-exported; `@import("../render/renderer_h.zig")`) |
| `rvn_widget_get/check/create/destroy/add_child/child_index/class_by_name/invalidate_layout/invalidate_paint/set_appear/set_color/set_metric/set_theme`, `rvn_window_get/forget_widget/add_shortcut/remove_shortcut`, `rvn_a11y_attribute rvn_a11y_structure_changed rvn_locale_attribute rvn_parse_shortcut rvn_parse_transition`, `rvn_xml_theme` | declared in `externs.zig` (widget/widget.h and widgets/common.h have no header unit yet) |

Things to know before translating the `.c` files:

1. **`rvn_widget_t`, `rvn_window_t`, `rvn_widget_class_t` are placeholders** (`extern struct { _placeholder: u8 }`) in `externs.zig`. `xml_attributes.c`, `xml_loader.c`, `xml_watch.c`, `xml_dom.c` read and write their fields (`widget->flags`, `->slot`, `->window`, `->root`, `->xml_tag`, `->cls`, ...; `rvn_slot_t`, `RVN_WF_*`), so they need `src/widget/widget_h.zig` (and `widgets/common_h.zig` for `RVN_ATTR`/`rvn_xml_*` prototypes). Stop and report if it does not exist; when it does, change the three placeholder lines in `externs.zig` to re-export it. Nothing in `xml_h.zig` or the exported signatures depends on the layout (pointers only).
2. `RVN_ATTR(literal)` (widgets/common.h) is `rvn_stricmp(name, literal) == 0` with a local called `name`.
3. `RVN_API_GUARD(result)` / `RVN_API_GUARD_VOID()` use `__func__`: pass the exported function's own name as a string literal.
4. `rvn_xml_texture`, `rvn_xml_font`, `rvn_xml_shutdown` (xml_loader.c) and `rvn_parse_*`, `rvn_color_role_*`, `rvn_metric_*`, `rvn_widget_set_*attribute` (xml_attributes.c) are declared in widget/widget.h and widgets/common.h, not in xml.h. Other modules reach them through those header units; `externs.zig` also carries `rvn_xml_texture/font/shutdown` as `pub extern fn` for convenience (an extern and an export of one name coexist in a compilation).
5. Function-pointer typedef `rvn_watch_callback_t` is in `xml_watch_h.zig`; `rvn_fs_watch_callback_t` in `fs_watch_h.zig`.
6. `xml.h` has no enums and no global variables. `RVN_XML_COMMENT` is `pub const RVN_XML_COMMENT = "#comment";` (a Zig string; pass `.ptr` or compare with `rvn_stricmp`/`strcmp` via libc as the C does).

## Layout test

`layout/xml_layout.c` (C: `sizeof/alignof/offsetof` of `rvn_xml_attribute_t`, `rvn_xml_node_t`, `rvn_xml_document_t`, `rvn_xml_window_t`) and `src/xml_layout_check.zig` (the same numbers from `xml_h.zig`) print identical text; verified (42 lines, no diff):

```sh
cd vendor/raven/zig
cc -I ../include -I ../src layout/xml_layout.c -o _build/xl/c && _build/xl/c > _build/xl/c.txt
zig run --dep raven -Mroot=src/xml_layout_check.zig -Mraven=src/raven/raven.zig > _build/xl/z.txt
diff _build/xl/c.txt _build/xl/z.txt
```

The generated `layout/layout.{c,zig}` (public types, rewritten by `tools/gen_public_types.py`) were not touched. `check.sh` does not yet run this pair: add the three commands above as a step (the integrator owns `check.sh`).

## Layout check removed (2026-11-13)

The C-vs-Zig layout check of this module's private types (layout/*_layout.c and its Zig side) was removed: every C file of
the library is translated, so no C code compiles the private headers any more and the header units are the only definition
of these types. `check.sh` step 3 still compares the public types (include/raven) with the C compiler, and step 3b the
system types (pthread, timespec, pollfd, dirent) the Zig code takes from std.c (layout/system_layout.c).
