# Module `render` - translation manifest

Source: `vendor/raven/src/render` (19 C files, 7139 lines; no Objective-C). Target: `vendor/raven/zig/src/render`.
Read `zig/PORTING.md` first. This file lists, per C file, the symbols its Zig file must `export` (check_unit.sh compares
them with `tools/c_exports.py`), the exact C signature and the Zig signature to use.

## 1. What is already written (header units, all `UNIT OK` for host, `x86_64-linux-gnu`, `x86_64-windows-gnu`)

| C header | Zig header unit | content |
|---|---|---|
| `render/draw.h` | `render/draw_h.zig` | `rvn_drawlist_t`, `RPainter` (full struct), `rvn_glass_t`, `rvn_blur_t`, `rvn_curve_t`, `rvn_icon_t` + `RVN_ICON_*`, `RVN_PAINTER_CLIP_STACK`, every `rvn_drawlist_*` / `rvn_paint_*` / `rvn_spring_*` prototype, `rvn_window_pointer` |
| `render/font.h` | `render/font_h.zig` | `rvn_font_t` / `rvn_ttf_t` (opaque), `rvn_font_metrics_t`, `RVN_FONT_BOLD/ITALIC`, all `rvn_font*`, `rvn_text_*`, `rvn_ttf_*`, `rvn_font_system_*`, `rvn_a11y_text_scale`, `rvn_default_font_data/size`, `rvn_mono_font_data/size` |
| `render/renderer.h` | `render/renderer_h.zig` | `rvn_texture_t`, `rvn_shader_t`, `rvn_frame_t`, `rvn_render_fn`, all `rvn_renderer_*`, `rvn_texture_*`, `rvn_shader*`, `rvn_image_decode`, `rvn_backend_null/vulkan` |
| `render/bidi.h` | `render/bidi_h.zig` | `rvn_bidi_*` |
| `render/vulkan/vk_loader.h` | `render/vulkan/vk_loader_h.zig` | `rvn_vk_functions_t` (85 `PFN_vk*` fields in the order of the X-macro lists), the three `RVN_VK_*_FUNCTIONS` lists as comptime `[_][]const u8` arrays (the `X(name)` order), `rvn_vk_create_surface_fn`, `rvn_vk_get_memory_handle_fn`, `rvn_vk`, `rvn_vk_load_*`, `rvn_vk_library_*`, `rvn_vk_result_name`; re-exports `vk` = `vulkan_h.zig` |
| `render/vulkan/vk_backend.h` | `render/vulkan/vk_backend_h.zig` | all `rvn_vk_*_t` structs, `rvn_vk_state_t`, `rvn_vk_config_t`, `g_vk`, `g_vk_config`, `RVN_VK_*` constants, all prototypes; re-exports `renderer`, `loader`, `vk` |

Layout (sizeof, alignof, every offsetof, constants; 337 values) of every struct above is compared with the C compiler
by `zig/layout/check_render.sh` (`LAYOUT-RENDER OK: 337 values identical`). It is NOT part of `check.sh` yet (check.sh step 3 only
runs the generated public `layout.c`): the integrator should call `layout/check_render.sh` from `check.sh`
(it needs `vulkan/vulkan.h`: it looks in `$RAVEN_VULKAN_INCLUDE_DIR`, `/opt/homebrew/include`, `/usr/local/include`, `/usr/include`).
`layout/gen_render.py` regenerates `layout_render.c` / `layout_render.zig`.

Notes on the header units:

* **`RPainter`**: `raven.RPainter` is an opaque handle. `draw_h.RPainter` is the real struct (draw.h defines `struct RPainter`).
  All `rvn_paint_*` take `[*c]draw.RPainter`; the public `Rdraw_*` functions (draw.c) take `?*raven.RPainter` and must
  `@ptrCast` it (`const p: [*c]draw.RPainter = @ptrCast(painter);`). The same applies to the callbacks of `raven.zig`.
* `struct rvn_window_t` (widget module) is not visible to render: `RPainter.window` is `?*anyopaque`, `rvn_window_pointer`
  takes `?*const anyopaque`. When `widget/window_h.zig` exists, cast.
* `rvn_font_t`, `rvn_ttf_t` are `opaque {}` in the header unit and pointers are `?*rvn_font_t` / `?*rvn_ttf_t` (a `[*c]` pointer
  cannot point to an opaque type). font.c / font_raster.c define their own `extern struct` for the body and `@ptrCast` at the boundary.
* `rvn_default_font_data` and friends are `pub extern const ...: [0]u8` (C declares `[]`): use `&font.rvn_default_font_data`.
  They are defined by `resources/default_font.zig` (done).
* `rvn_backend_vulkan` is declared unconditionally (C: `#if RAVEN_BACKEND_VULKAN_ENABLED`); vk_backend.zig must define it only
  `if (config.backend_vulkan)` (see section 4).
* Enums (`rvn_icon_t`) are `c_uint` + `c_int` constants, like `raven.zig`.
* Names in the Zig signature columns below that have no prefix (`Rid`, `Ruint`, `RFontStyle`, `RTextureDesc`...) come from
  `@import("raven")`: write `raven.Rid`. `base.` = `core/base_h.zig`, `draw.` / `font.` = the header units above.
  An `export var` needs an initializer: `export var g_vk: rvn_vk_state_t = std.mem.zeroes(rvn_vk_state_t);`.
  A parameter name may differ from the C one (header-unit names were used); only types matter.

## 2. Cross-module dependencies

All other Raven modules the render files use are covered by header units that already exist, so no `extern fn` of another module has
to be hand-written in render files:

| needs | from |
|---|---|
| `rvn_alloc/rvn_calloc/rvn_realloc/rvn_free`, `RVN_ARRAY_RESERVE`, `rvn_stricmp`, `rvn_error`, utf8, geometry, colors | `core/base_h.zig` |
| `g_rvn`, `RVN_API_GUARD(_VOID)`, `RVN_THEME_METRIC`, `rvn_invalidate_all_windows`, `rvn_repaint_all_windows`, `rvn_wake` | `core/context_h.zig` (used by draw.c, font.c, renderer.c, shader.c, texture.c, vk_public.c) |
| mutex / cond / thread / atomics / `rvn_clock_seconds` / `rvn_sleep_ms` | `core/thread_h.zig` (renderer.c, font.c, texture.c) |
| `rvn_handle_*`, `rvn_pool_*` | `core/handle_h.zig` (shader.c, texture.c, font.c) |
| `rvn_lfmap_*` | `core/lfmap_h.zig` (font.c) |
| `rvn_jobs_submit` | `core/jobs_h.zig` (texture.c) |
| `rvn_fs_download_url`, `rvn_is_http_url` | `core/fs_h.zig` (texture.c) |
| `rvn_a11y_text_scale` (defined in `core/accessibility.c`) | `render/font_h.zig` |
| `rvn_window_pointer` (defined in `widget/window.c`) | `render/draw_h.zig` |
| C library, `dlopen/dlsym/dlclose`, `std.c.dirent/stat` | `sys/libc.zig`, `std.c` |
| `ceilf/floorf/fabsf` | `@ceil/@floor/@abs` |
| SPIR-V words (`rvn_ui_vert_spv`, `rvn_effect_*_spv`...) | `render/vulkan/generated/*_spv.zig` (already there) |
| Win32 `LoadLibraryA/FreeLibrary/GetProcAddress/GetWindowsDirectoryA`, `S_ISDIR` | `render/externs.zig` (`ext.win.*`, `ext.S_ISDIR`) |

`render/externs.zig` holds only what is left (the Win32 kernel32 calls used by vk_loader.c and font_system.c, only analysed when compiling for
Windows, and `S_ISDIR`). The Vulkan entry points are never extern functions: they are the function pointers of the `rvn_vk` table
(`rvn_vk.CreateImage.?(...)` for `rvn_vk.CreateImage(...)`; C calls through NULL are the same crash in Zig when `.?` fails).

## 3. Blockers and traps found while reading the module (report to the integrator)

1. **`font_raster.c` and `image_decode.c` embed third-party code.** font_raster.c compiles `stb/stb_truetype.h` with `STBTT_STATIC`
   (all `stbtt_*` functions are `static` inside that translation unit, ~5k lines); image_decode.c compiles `stb/stb_image.h`
   with `STB_IMAGE_STATIC` (~7k lines, only `stbi_load_from_memory`, behind `config.with_stb_image`). Neither can be reached with an `extern`.
   Options: (a) translate the used subset of stb_truetype / stb_image into `zig/src/third_party/*.zig` (font_raster.c uses
   `stbtt_InitFont`, `GetFontOffsetForIndex`, `FindGlyphIndex`, `GetGlyphHMetrics`, `GetFontVMetrics`, `ScaleForMappingEmToPixels`,
   `GetGlyphBitmapBox(Subpixel)`, `MakeGlyphBitmap(Subpixel)`, `stbtt__find_table` and `stbtt_fontinfo` by value inside `struct rvn_ttf_t`),
   or (b) keep a ~30-line C shim that wraps them (`zig/c/stb_shim.c`, non-static `rvn_stbtt_*` functions) and declare those in the
   translated file; (b) is the only way to stay "C ABI identical" quickly. These two files must be assigned deliberately.
2. `vk_loader.c` expands the `RVN_VK_*_FUNCTIONS` X-macros with `#define`s: use `inline for (loader.RVN_VK_GLOBAL_FUNCTIONS) |name| @field(...)`.
3. `renderer.c` calls the backend through `RBackendVTable` function pointers (`backend->Init(info)`): `.?` on the optional pointer.
4. `vk_surface.c` casts a `dlsym` result to a function pointer with `memcpy`: use `@ptrCast` of the `?*anyopaque`.
5. `vk_backend.c` defines `rvn_backend_vulkan` and `null_backend.c` `rvn_backend_null` (const `RBackendVTable` structs returned by pointer): the
   struct needs a static (file-level) `var`/`const` with function pointers `&fn` of `callconv(.c)` functions.
6. `vk_frame.c`, `vk_glass.c` read `RDrawData` / `RDrawCommand` of the public API (`raven.zig`).
7. `font.c`, `draw.c`, `renderer.c` run on several threads: keep the atomics as `thread_h.rvn_atomic_*` calls (seq_cst), do not use plain loads.
8. Platform code in render: `font_system.c` has Windows / macOS / Linux branches (`builtin.os.tag`); `vk_surface.c` has Win32 / Xlib / XCB / Metal / headless branches.
   Check `font_system.zig` and `vk_*.zig` for `x86_64-linux-gnu` and `x86_64-windows-gnu`.
9. `rvn_vk_functions_t` has `rvn_vk_create_surface_fn` fields typed with an untyped create-info pointer on purpose; do not "improve" it.

## 4. Files

Suggested order: bidi, font_raster*, font_system, image_decode*, null_backend, texture, shader, renderer, font, draw, then vulkan: vk_loader, vk_device,
vk_pipeline, vk_texture, vk_surface, vk_glass, vk_frame, vk_backend, vk_public (`*` = see blocker 1).
Header units each file imports (from its `#include`s; every `.zig` also imports `raven`, usually `base`):

| file | lines | imports |
|---|---|---|
| font.c | 1035 | `font_h` (-> `draw_h`), `bidi_h`, `renderer_h`, `context_h`, `lfmap_h`, `thread_h`, `handle_h`; exports 22 (includes the public `Rfont_*`) |
| draw.c | 919 | `draw_h`, `font_h`, `renderer_h`, `context_h`; exports 42 (includes the public `Rdraw_*`) |
| vulkan/vk_pipeline.c | 616 | `vk_backend_h`, `generated/{ui,blur}_{vert,frag}_spv.zig` |
| vulkan/vk_surface.c | 444 | `vk_backend_h`, `externs` (Win32), `libc` (dlsym) |
| vulkan/vk_texture.c | 442 | `vk_backend_h` |
| vulkan/vk_device.c | 441 | `vk_backend_h` |
| renderer.c | 430 | `renderer_h`, `context_h`, `thread_h` |
| vulkan/vk_frame.c | 411 | `vk_backend_h` |
| bidi.c | 379 | `bidi_h`, `font_h` (it includes font.h) |
| texture.c | 318 | `renderer_h`, `context_h`, `fs_h`, `jobs_h`, `handle_h` |
| font_system.c | 310 | `font_h`, `libc`, `externs` |
| shader.c | 302 | `renderer_h`, `context_h`, `handle_h`, `generated/effect_*_spv.zig` (aurora, shimmer, neon, ripple, plasma, grain, spotlight, mesh) |
| vulkan/vk_glass.c | 293 | `vk_backend_h` |
| vulkan/vk_public.c | 217 | `vk_backend_h`, `context_h`, `handle_h`, `thread_h` |
| vulkan/vk_loader.c | 190 | `vk_backend_h`, `libc` (dlopen), `externs` (Win32) |
| font_raster.c | 183 | `font_h`, stb_truetype (blocker 1) |
| null/null_backend.c | 88 | `renderer_h` |
| image_decode.c | 67 | `renderer_h`, stb_image (blocker 1) |
| vulkan/vk_backend.c | 54 | `vk_backend_h` |

## 5. Exported symbols per file (C signature -> Zig signature)

### `src/render/font.c` -> `zig/src/render/font.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_font_variant` | `Rid rvn_font_variant(Rid id, uint32_t style)` | `export fn rvn_font_variant(font: raven.Rid, style: u32) raven.Rid` |
| `rvn_fonts_init` | `void rvn_fonts_init(void)` | `export fn rvn_fonts_init() void` |
| `rvn_fonts_shutdown` | `void rvn_fonts_shutdown(void)` | `export fn rvn_fonts_shutdown() void` |
| `rvn_font_resolve` | `rvn_font_t* rvn_font_resolve(Rid id)` | `export fn rvn_font_resolve(font: raven.Rid) ?*rvn_font_t` |
| `rvn_font_size_resolve` | `float rvn_font_size_resolve(float size)` | `export fn rvn_font_size_resolve(size: f32) f32` |
| `rvn_font_metrics` | `void rvn_font_metrics(rvn_font_t* font, float size, rvn_font_metrics_t* metrics)` | `export fn rvn_font_metrics(font: ?*rvn_font_t, size: f32, metrics: [*c]rvn_font_metrics_t) void` |
| `rvn_text_width` | `float rvn_text_width(rvn_font_t* font, float size, const char* text, int length)` | `export fn rvn_text_width(font: ?*rvn_font_t, size: f32, text: [*c]const u8, length: c_int) f32` |
| `rvn_text_offset_at` | `int rvn_text_offset_at(rvn_font_t* font, float size, const char* text, int length, float x)` | `export fn rvn_text_offset_at(font: ?*rvn_font_t, size: f32, text: [*c]const u8, length: c_int, x: f32) c_int` |
| `rvn_text_wrap` | `int rvn_text_wrap(rvn_font_t* font, float size, const char* text, int length, float max_width, float* line_width)` | `export fn rvn_text_wrap(font: ?*rvn_font_t, size: f32, text: [*c]const u8, length: c_int, max_width: f32, line_width: [*c]f32) c_int` |
| `rvn_text_draw` | `void rvn_text_draw(rvn_drawlist_t* list, rvn_font_t* font, float size_px, float x, float y, const char* text, int length, rvn_color_t color, rvn_box_t clip)` | `export fn rvn_text_draw(list: [*c]draw.rvn_drawlist_t, font: ?*rvn_font_t, size_px: f32, x: f32, y: f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t, clip: base.rvn_box_t) void` |
| `rvn_fonts_flush` | `void rvn_fonts_flush(void)` | `export fn rvn_fonts_flush() void` |
| `rvn_fonts_resolve_pages` | `void rvn_fonts_resolve_pages(rvn_drawlist_t* list)` | `export fn rvn_fonts_resolve_pages(list: [*c]draw.rvn_drawlist_t) void` |
| `Rfont_create` | `Rid Rfont_create(const char* data, size_t data_size)` | `export fn Rfont_create(data: [*c]const u8, data_size: usize) Rid` |
| `Rfont_create_from_file` | `Rid Rfont_create_from_file(const char* path)` | `export fn Rfont_create_from_file(path: [*c]const u8) Rid` |
| `Rfont_destroy` | `void Rfont_destroy(Rid id)` | `export fn Rfont_destroy(font: Rid) void` |
| `Rfont_set_variant` | `void Rfont_set_variant(Rid id, RFontStyle style, Rid variant)` | `export fn Rfont_set_variant(font: Rid, style: RFontStyle, variant: Rid) void` |
| `Rfont_get_variant` | `Rid Rfont_get_variant(Rid id, RFontStyle style)` | `export fn Rfont_get_variant(font: Rid, style: RFontStyle) Rid` |
| `Rfont_is_valid` | `int Rfont_is_valid(Rid font)` | `export fn Rfont_is_valid(font: Rid) c_int` |
| `Rfont_get_default` | `Rid Rfont_get_default(void)` | `export fn Rfont_get_default() Rid` |
| `Rfont_get_monospace` | `Rid Rfont_get_monospace(void)` | `export fn Rfont_get_monospace() Rid` |
| `Rfont_set_fallback` | `void Rfont_set_fallback(Rid id, Rid fallback)` | `export fn Rfont_set_fallback(font: Rid, fallback: Rid) void` |
| `Rfont_measure_text` | `void Rfont_measure_text(Rid font_id, float size, const char* text, float* width, float* height)` | `export fn Rfont_measure_text(font: Rid, size: f32, text: [*c]const u8, width: [*c]f32, height: [*c]f32) void` |

### `src/render/draw.c` -> `zig/src/render/draw.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_drawlist_init` | `void rvn_drawlist_init(rvn_drawlist_t* list)` | `export fn rvn_drawlist_init(list: [*c]rvn_drawlist_t) void` |
| `rvn_drawlist_free` | `void rvn_drawlist_free(rvn_drawlist_t* list)` | `export fn rvn_drawlist_free(list: [*c]rvn_drawlist_t) void` |
| `rvn_drawlist_reset` | `void rvn_drawlist_reset(rvn_drawlist_t* list)` | `export fn rvn_drawlist_reset(list: [*c]rvn_drawlist_t) void` |
| `rvn_drawlist_add` | `RDrawInstance* rvn_drawlist_add(rvn_drawlist_t* list, Rid texture)` | `export fn rvn_drawlist_add(list: [*c]rvn_drawlist_t, texture: raven.Rid) [*c]raven.RDrawInstance` |
| `rvn_drawlist_add_erase` | `RDrawInstance* rvn_drawlist_add_erase(rvn_drawlist_t* list)` | `export fn rvn_drawlist_add_erase(list: [*c]rvn_drawlist_t) [*c]raven.RDrawInstance` |
| `rvn_drawlist_add_shader` | `RDrawInstance* rvn_drawlist_add_shader(rvn_drawlist_t* list, Rid shader, Rid texture)` | `export fn rvn_drawlist_add_shader(list: [*c]rvn_drawlist_t, shader: raven.Rid, texture: raven.Rid) [*c]raven.RDrawInstance` |
| `rvn_drawlist_add_callback` | `void rvn_drawlist_add_callback(rvn_drawlist_t* list, const RDrawCommand* callback)` | `export fn rvn_drawlist_add_callback(list: [*c]rvn_drawlist_t, command: [*c]const raven.RDrawCommand) void` |
| `rvn_drawlist_add_backdrop` | `void rvn_drawlist_add_backdrop(rvn_drawlist_t* list, rvn_box_t area)` | `export fn rvn_drawlist_add_backdrop(list: [*c]rvn_drawlist_t, area: base.rvn_box_t) void` |
| `rvn_drawlist_append` | `void rvn_drawlist_append(rvn_drawlist_t* list, const rvn_drawlist_t* source)` | `export fn rvn_drawlist_append(list: [*c]rvn_drawlist_t, source: [*c]const rvn_drawlist_t) void` |
| `rvn_drawlist_append_commands` | `void rvn_drawlist_append_commands(rvn_drawlist_t* list, const rvn_drawlist_t* source, uint32_t base)` | `export fn rvn_drawlist_append_commands(list: [*c]rvn_drawlist_t, source: [*c]const rvn_drawlist_t, base_: u32) void` |
| `rvn_drawlist_resolve_backdrops` | `uint32_t rvn_drawlist_resolve_backdrops(rvn_drawlist_t* list, rvn_box_t frame, uint32_t max)` | `export fn rvn_drawlist_resolve_backdrops(list: [*c]rvn_drawlist_t, frame: base.rvn_box_t, max: u32) u32` |
| `rvn_drawlist_transform` | `void rvn_drawlist_transform(rvn_drawlist_t* list, uint32_t first_instance, uint32_t first_command, float sx, float sy, float pivot_x, float pivot_y, float dx, float dy, rvn_box_t limit)` | `export fn rvn_drawlist_transform(list: [*c]rvn_drawlist_t, first_instance: u32, first_command: u32, sx: f32, sy: f32, pivot_x: f32, pivot_y: f32, dx: f32, dy: f32, limit: base.rvn_box_t) void` |
| `rvn_paint_snap` | `rvn_box_t rvn_paint_snap(const RPainter* painter, rvn_rect_t rect)` | `export fn rvn_paint_snap(painter: [*c]const RPainter, rect: base.rvn_rect_t) base.rvn_box_t` |
| `rvn_paint_box4` | `void rvn_paint_box4(RPainter* painter, rvn_rect_t rect, const float radii[4], rvn_color_t fill, float border_width, rvn_color_t border_color)` | `export fn rvn_paint_box4(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, fill: base.rvn_color_t, border_width: f32, border_color: base.rvn_color_t) void` |
| `rvn_paint_box` | `void rvn_paint_box(RPainter* painter, rvn_rect_t rect, float radius, rvn_color_t fill, float border_width, rvn_color_t border_color)` | `export fn rvn_paint_box(painter: [*c]RPainter, rect: base.rvn_rect_t, radius: f32, fill: base.rvn_color_t, border_width: f32, border_color: base.rvn_color_t) void` |
| `rvn_paint_rect` | `void rvn_paint_rect(RPainter* painter, rvn_rect_t rect, rvn_color_t color)` | `export fn rvn_paint_rect(painter: [*c]RPainter, rect: base.rvn_rect_t, color: base.rvn_color_t) void` |
| `rvn_paint_shadow` | `void rvn_paint_shadow(RPainter* painter, rvn_rect_t rect, float radius, float blur, rvn_color_t color)` | `export fn rvn_paint_shadow(painter: [*c]RPainter, rect: base.rvn_rect_t, radius: f32, blur: f32, color: base.rvn_color_t) void` |
| `rvn_paint_glass` | `void rvn_paint_glass(RPainter* painter, rvn_rect_t rect, const float radii[4], const rvn_glass_t* glass)` | `export fn rvn_paint_glass(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, glass: [*c]const rvn_glass_t) void` |
| `rvn_paint_blur` | `void rvn_paint_blur(RPainter* painter, rvn_rect_t rect, const float radii[4], const rvn_blur_t* blur)` | `export fn rvn_paint_blur(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, blur: [*c]const rvn_blur_t) void` |
| `rvn_paint_erase` | `void rvn_paint_erase(RPainter* painter, rvn_rect_t rect, const float radii[4], float amount)` | `export fn rvn_paint_erase(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, amount: f32) void` |
| `rvn_paint_line` | `void rvn_paint_line(RPainter* painter, float x0, float y0, float x1, float y1, float thickness, rvn_color_t color)` | `export fn rvn_paint_line(painter: [*c]RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: base.rvn_color_t) void` |
| `rvn_curve_point` | `rvn_vec2_t rvn_curve_point(const float points[8], float t)` | `export fn rvn_curve_point(points: [*c]const f32, t: f32) base.rvn_vec2_t` |
| `rvn_paint_curve` | `void rvn_paint_curve(RPainter* painter, const float points[8], const rvn_curve_t* curve)` | `export fn rvn_paint_curve(painter: [*c]RPainter, points: [*c]const f32, curve: [*c]const rvn_curve_t) void` |
| `rvn_paint_triangle` | `void rvn_paint_triangle(RPainter* painter, float x0, float y0, float x1, float y1, float x2, float y2, rvn_color_t color)` | `export fn rvn_paint_triangle(painter: [*c]RPainter, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, color: base.rvn_color_t) void` |
| `rvn_paint_image` | `void rvn_paint_image(RPainter* painter, rvn_rect_t rect, Rid texture, const float uv[4], rvn_color_t tint, float radius)` | `export fn rvn_paint_image(painter: [*c]RPainter, rect: base.rvn_rect_t, texture: raven.Rid, uv: [*c]const f32, tint: base.rvn_color_t, radius: f32) void` |
| `rvn_paint_text` | `void rvn_paint_text(RPainter* painter, Rid font_id, float size, float x, float y, const char* text, int length, rvn_color_t color)` | `export fn rvn_paint_text(painter: [*c]RPainter, font: raven.Rid, size: f32, x: f32, y: f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t) void` |
| `rvn_paint_text_in` | `void rvn_paint_text_in(RPainter* painter, Rid font_id, float size, rvn_rect_t rect, float align, const char* text, int length, rvn_color_t color)` | `export fn rvn_paint_text_in(painter: [*c]RPainter, font: raven.Rid, size: f32, rect: base.rvn_rect_t, @"align": f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t) void` |
| `rvn_paint_icon` | `void rvn_paint_icon(RPainter* painter, rvn_icon_t icon, float cx, float cy, float size, rvn_color_t color)` | `export fn rvn_paint_icon(painter: [*c]RPainter, icon: rvn_icon_t, cx: f32, cy: f32, size: f32, color: base.rvn_color_t) void` |
| `rvn_paint_chevron` | `void rvn_paint_chevron(RPainter* painter, float cx, float cy, float size, float angle, rvn_color_t color)` | `export fn rvn_paint_chevron(painter: [*c]RPainter, cx: f32, cy: f32, size: f32, angle: f32, color: base.rvn_color_t) void` |
| `rvn_paint_push_clip` | `void rvn_paint_push_clip(RPainter* painter, rvn_rect_t rect)` | `export fn rvn_paint_push_clip(painter: [*c]RPainter, rect: base.rvn_rect_t) void` |
| `rvn_paint_pop_clip` | `void rvn_paint_pop_clip(RPainter* painter)` | `export fn rvn_paint_pop_clip(painter: [*c]RPainter) void` |
| `Rdraw_rect` | `void Rdraw_rect(RPainter* painter, float x, float y, float width, float height, float radius, float r, float g, float b, float a)` | `export fn Rdraw_rect(painter: ?*RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_glass` | `void Rdraw_glass(RPainter* painter, float x, float y, float width, float height, float radius, float r, float g, float b, float a)` | `export fn Rdraw_glass(painter: ?*RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_rect_outline` | `void Rdraw_rect_outline(RPainter* painter, float x, float y, float width, float height, float radius, float thickness, float r, float g, float b, float a)` | `export fn Rdraw_rect_outline(painter: ?*RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_circle` | `void Rdraw_circle(RPainter* painter, float center_x, float center_y, float radius, float r, float g, float b, float a)` | `export fn Rdraw_circle(painter: ?*RPainter, center_x: f32, center_y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_line` | `void Rdraw_line(RPainter* painter, float x0, float y0, float x1, float y1, float thickness, float r, float g, float b, float a)` | `export fn Rdraw_line(painter: ?*RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_curve` | `void Rdraw_curve(RPainter* painter, float x0, float y0, float cx0, float cy0, float cx1, float cy1, float x1, float y1, float thickness, float r, float g, float b, float a)` | `export fn Rdraw_curve(painter: ?*RPainter, x0: f32, y0: f32, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_triangle` | `void Rdraw_triangle(RPainter* painter, float x0, float y0, float x1, float y1, float x2, float y2, float r, float g, float b, float a)` | `export fn Rdraw_triangle(painter: ?*RPainter, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_image` | `void Rdraw_image(RPainter* painter, Rid texture, float x, float y, float width, float height, float r, float g, float b, float a)` | `export fn Rdraw_image(painter: ?*RPainter, texture: Rid, x: f32, y: f32, width: f32, height: f32, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_text` | `void Rdraw_text(RPainter* painter, Rid font, float size, float x, float y, const char* text, float r, float g, float b, float a)` | `export fn Rdraw_text(painter: ?*RPainter, font: Rid, size: f32, x: f32, y: f32, text: [*c]const u8, r: f32, g: f32, b: f32, a: f32) void` |
| `Rdraw_push_clip_rect` | `void Rdraw_push_clip_rect(RPainter* painter, float x, float y, float width, float height)` | `export fn Rdraw_push_clip_rect(painter: ?*RPainter, x: f32, y: f32, width: f32, height: f32) void` |
| `Rdraw_pop_clip_rect` | `void Rdraw_pop_clip_rect(RPainter* painter)` | `export fn Rdraw_pop_clip_rect(painter: ?*RPainter) void` |

### `src/render/vulkan/vk_pipeline.c` -> `zig/src/render/vulkan/vk_pipeline.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_vk_pipeline_init` | `int rvn_vk_pipeline_init(void)` | `export fn rvn_vk_pipeline_init() c_int` |
| `rvn_vk_pipeline_shutdown` | `void rvn_vk_pipeline_shutdown(void)` | `export fn rvn_vk_pipeline_shutdown() void` |
| `rvn_vk_pass_get` | `rvn_vk_pass_t* rvn_vk_pass_get(VkFormat format)` | `export fn rvn_vk_pass_get(format: vk.VkFormat) [*c]rvn_vk_pass_t` |
| `rvn_vk_shader_create` | `int rvn_vk_shader_create(Rid id, const uint32_t* spirv, size_t size)` | `export fn rvn_vk_shader_create(shader: raven.Rid, spirv: [*c]const u32, size: usize) c_int` |
| `rvn_vk_shader_destroy` | `void rvn_vk_shader_destroy(Rid id)` | `export fn rvn_vk_shader_destroy(shader: raven.Rid) void` |
| `rvn_vk_shader_pipeline` | `VkPipeline rvn_vk_shader_pipeline(Rid id, rvn_vk_pass_t* pass)` | `export fn rvn_vk_shader_pipeline(shader: raven.Rid, pass: [*c]rvn_vk_pass_t) vk.VkPipeline` |
| `rvn_vk_set_allocate` | `int rvn_vk_set_allocate(VkDescriptorSet* set, VkDescriptorPool* pool)` | `export fn rvn_vk_set_allocate(set: [*c]vk.VkDescriptorSet, pool: [*c]vk.VkDescriptorPool) c_int` |
| `rvn_vk_set_free` | `void rvn_vk_set_free(VkDescriptorSet set, VkDescriptorPool pool)` | `export fn rvn_vk_set_free(set: vk.VkDescriptorSet, pool: vk.VkDescriptorPool) void` |
| `rvn_vk_set_write` | `void rvn_vk_set_write(VkDescriptorSet set, VkImageView view, VkSampler sampler)` | `export fn rvn_vk_set_write(set: vk.VkDescriptorSet, view: vk.VkImageView, sampler: vk.VkSampler) void` |
| `rvn_vk_backdrop_set_create` | `int rvn_vk_backdrop_set_create(VkDescriptorSet* set, VkImageView sharp, VkImageView blurred)` | `export fn rvn_vk_backdrop_set_create(set: [*c]vk.VkDescriptorSet, sharp: vk.VkImageView, blurred: vk.VkImageView) c_int` |
| `rvn_vk_backdrop_set_destroy` | `void rvn_vk_backdrop_set_destroy(VkDescriptorSet set)` | `export fn rvn_vk_backdrop_set_destroy(set: vk.VkDescriptorSet) void` |

### `src/render/vulkan/vk_surface.c` -> `zig/src/render/vulkan/vk_surface.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_vk_surface_find` | `rvn_vk_surface_t* rvn_vk_surface_find(Rid window)` | `export fn rvn_vk_surface_find(window: raven.Rid) [*c]rvn_vk_surface_t` |
| `rvn_vk_wait_frames` | `void rvn_vk_wait_frames(void)` | `export fn rvn_vk_wait_frames() void` |
| `rvn_vk_swapchain_create` | `int rvn_vk_swapchain_create(rvn_vk_surface_t* surface, uint32_t width, uint32_t height)` | `export fn rvn_vk_swapchain_create(surface: [*c]rvn_vk_surface_t, width: u32, height: u32) c_int` |
| `rvn_vk_surface_create` | `int rvn_vk_surface_create(Rid window, const RNativeWindow* native, Ruint width, Ruint height)` | `export fn rvn_vk_surface_create(window: raven.Rid, native: [*c]const raven.RNativeWindow, width: raven.Ruint, height: raven.Ruint) c_int` |
| `rvn_vk_surface_destroy` | `void rvn_vk_surface_destroy(Rid window)` | `export fn rvn_vk_surface_destroy(window: raven.Rid) void` |
| `rvn_vk_surfaces_shutdown` | `void rvn_vk_surfaces_shutdown(void)` | `export fn rvn_vk_surfaces_shutdown() void` |

### `src/render/vulkan/vk_texture.c` -> `zig/src/render/vulkan/vk_texture.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_vk_uploads_flush` | `void rvn_vk_uploads_flush(void)` | `export fn rvn_vk_uploads_flush() void` |
| `rvn_vk_texture_find` | `rvn_vk_texture_t* rvn_vk_texture_find(Rid texture)` | `export fn rvn_vk_texture_find(texture: raven.Rid) [*c]rvn_vk_texture_t` |
| `rvn_vk_texture_create` | `int rvn_vk_texture_create(Rid id, const RTextureDesc* desc, const void* pixels)` | `export fn rvn_vk_texture_create(texture: raven.Rid, desc: [*c]const raven.RTextureDesc, pixels: ?*const anyopaque) c_int` |
| `rvn_vk_texture_update` | `void rvn_vk_texture_update(Rid id, Ruint x, Ruint y, Ruint width, Ruint height, const void* pixels)` | `export fn rvn_vk_texture_update(texture: raven.Rid, x: raven.Ruint, y: raven.Ruint, width: raven.Ruint, height: raven.Ruint, pixels: ?*const anyopaque) void` |
| `rvn_vk_texture_set_filter` | `void rvn_vk_texture_set_filter(Rid id, RFilterType filter)` | `export fn rvn_vk_texture_set_filter(texture: raven.Rid, filter: raven.RFilterType) void` |
| `rvn_vk_texture_destroy` | `void rvn_vk_texture_destroy(Rid id)` | `export fn rvn_vk_texture_destroy(texture: raven.Rid) void` |
| `rvn_vk_texture_wrap` | `int rvn_vk_texture_wrap(Rid id, VkImageView view, VkSampler sampler, uint32_t width, uint32_t height)` | `export fn rvn_vk_texture_wrap(texture: raven.Rid, view: vk.VkImageView, sampler: vk.VkSampler, width: u32, height: u32) c_int` |
| `rvn_vk_texture_create_shared` | `int rvn_vk_texture_create_shared(Rid id, uint32_t width, uint32_t height)` | `export fn rvn_vk_texture_create_shared(texture: raven.Rid, width: u32, height: u32) c_int` |
| `rvn_vk_texture_export` | `int rvn_vk_texture_export(Rid id, intptr_t* handle, uint64_t* allocation_size)` | `export fn rvn_vk_texture_export(texture: raven.Rid, handle: [*c]isize, allocation_size: [*c]u64) c_int` |
| `rvn_vk_textures_init` | `int rvn_vk_textures_init(void)` | `export fn rvn_vk_textures_init() c_int` |
| `rvn_vk_textures_shutdown` | `void rvn_vk_textures_shutdown(void)` | `export fn rvn_vk_textures_shutdown() void` |

### `src/render/vulkan/vk_device.c` -> `zig/src/render/vulkan/vk_device.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `g_vk` | `rvn_vk_state_t g_vk;` | `export var g_vk: rvn_vk_state_t` |
| `g_vk_config` | `rvn_vk_config_t g_vk_config;` | `export var g_vk_config: rvn_vk_config_t` |
| `rvn_vk_failed` | `int rvn_vk_failed(VkResult result, const char* what)` | `export fn rvn_vk_failed(result: vk.VkResult, what: [*c]const u8) c_int` |
| `rvn_vk_queue_lock` | `void rvn_vk_queue_lock(void)` | `export fn rvn_vk_queue_lock() void` |
| `rvn_vk_queue_unlock` | `void rvn_vk_queue_unlock(void)` | `export fn rvn_vk_queue_unlock() void` |
| `rvn_vk_instance_extensions` | `const char* const* rvn_vk_instance_extensions(uint32_t* count)` | `export fn rvn_vk_instance_extensions(count: [*c]u32) [*c]const [*c]const u8` |
| `rvn_vk_device_extensions` | `const char* const* rvn_vk_device_extensions(uint32_t* count)` | `export fn rvn_vk_device_extensions(count: [*c]u32) [*c]const [*c]const u8` |
| `rvn_vk_device_init` | `int rvn_vk_device_init(void)` | `export fn rvn_vk_device_init() c_int` |
| `rvn_vk_device_shutdown` | `void rvn_vk_device_shutdown(void)` | `export fn rvn_vk_device_shutdown() void` |
| `rvn_vk_find_memory_type` | `uint32_t rvn_vk_find_memory_type(uint32_t type_bits, VkMemoryPropertyFlags flags)` | `export fn rvn_vk_find_memory_type(type_bits: u32, flags: vk.VkMemoryPropertyFlags) u32` |
| `rvn_vk_buffer_create` | `int rvn_vk_buffer_create(rvn_vk_buffer_t* buffer, VkDeviceSize size, VkBufferUsageFlags usage)` | `export fn rvn_vk_buffer_create(buffer: [*c]rvn_vk_buffer_t, size: vk.VkDeviceSize, usage: vk.VkBufferUsageFlags) c_int` |
| `rvn_vk_buffer_destroy` | `void rvn_vk_buffer_destroy(rvn_vk_buffer_t* buffer)` | `export fn rvn_vk_buffer_destroy(buffer: [*c]rvn_vk_buffer_t) void` |

### `src/render/renderer.c` -> `zig/src/render/renderer.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_renderer_set_wait_service` | `void rvn_renderer_set_wait_service(void (*service)(void))` | `export fn rvn_renderer_set_wait_service(service: ?*const fn () callconv(.c) void) void` |
| `rvn_renderer_init` | `int rvn_renderer_init(const RBackendVTable* backend, const RBackendInitInfo* info, int threaded)` | `export fn rvn_renderer_init(backend: [*c]const raven.RBackendVTable, info: [*c]const raven.RBackendInitInfo, threaded: c_int) c_int` |
| `rvn_renderer_shutdown` | `void rvn_renderer_shutdown(void)` | `export fn rvn_renderer_shutdown() void` |
| `rvn_renderer_is_threaded` | `int rvn_renderer_is_threaded(void)` | `export fn rvn_renderer_is_threaded() c_int` |
| `rvn_renderer_create_surface` | `int rvn_renderer_create_surface(Rid window, const RNativeWindow* native, uint32_t width, uint32_t height)` | `export fn rvn_renderer_create_surface(window: raven.Rid, native: [*c]const raven.RNativeWindow, width: u32, height: u32) c_int` |
| `rvn_renderer_destroy_surface` | `void rvn_renderer_destroy_surface(Rid window)` | `export fn rvn_renderer_destroy_surface(window: raven.Rid) void` |
| `rvn_renderer_create_texture` | `void rvn_renderer_create_texture(Rid texture, const RTextureDesc* desc, void* pixels)` | `export fn rvn_renderer_create_texture(texture: raven.Rid, desc: [*c]const raven.RTextureDesc, pixels: ?*anyopaque) void` |
| `rvn_renderer_update_texture` | `void rvn_renderer_update_texture(Rid texture, uint32_t x, uint32_t y, uint32_t width, uint32_t height, void* pixels)` | `export fn rvn_renderer_update_texture(texture: raven.Rid, x: u32, y: u32, width: u32, height: u32, pixels: ?*anyopaque) void` |
| `rvn_renderer_set_texture_filter` | `void rvn_renderer_set_texture_filter(Rid texture, RFilterType filter)` | `export fn rvn_renderer_set_texture_filter(texture: raven.Rid, filter: raven.RFilterType) void` |
| `rvn_renderer_destroy_texture` | `void rvn_renderer_destroy_texture(Rid texture)` | `export fn rvn_renderer_destroy_texture(texture: raven.Rid) void` |
| `rvn_renderer_create_shader` | `void rvn_renderer_create_shader(Rid shader, uint32_t* spirv, size_t size)` | `export fn rvn_renderer_create_shader(shader: raven.Rid, spirv: [*c]u32, size: usize) void` |
| `rvn_renderer_destroy_shader` | `void rvn_renderer_destroy_shader(Rid shader)` | `export fn rvn_renderer_destroy_shader(shader: raven.Rid) void` |
| `rvn_renderer_call` | `void rvn_renderer_call(rvn_render_fn function, void* arg, int wait)` | `export fn rvn_renderer_call(function: rvn_render_fn, arg: ?*anyopaque, wait: c_int) void` |
| `rvn_renderer_sync` | `void rvn_renderer_sync(void)` | `export fn rvn_renderer_sync() void` |
| `rvn_renderer_acquire_frame` | `rvn_frame_t* rvn_renderer_acquire_frame(void)` | `export fn rvn_renderer_acquire_frame() [*c]rvn_frame_t` |
| `rvn_renderer_throttle` | `void rvn_renderer_throttle(rvn_atomic_t* frames_in_flight, int max_frames)` | `export fn rvn_renderer_throttle(frames_in_flight: [*c]thread.rvn_atomic_t, max_frames: c_int) void` |
| `rvn_renderer_submit_frame` | `void rvn_renderer_submit_frame(rvn_frame_t* frame)` | `export fn rvn_renderer_submit_frame(frame: [*c]rvn_frame_t) void` |

### `src/render/vulkan/vk_frame.c` -> `zig/src/render/vulkan/vk_frame.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_vk_render_frame` | `void rvn_vk_render_frame(const RDrawData* data, RCapture* capture)` | `export fn rvn_vk_render_frame(data: [*c]const raven.RDrawData, capture: [*c]raven.RCapture) void` |

### `src/render/bidi.c` -> `zig/src/render/bidi.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_bidi_needed` | `int rvn_bidi_needed(const char* text, int length)` | `export fn rvn_bidi_needed(text: [*c]const u8, length: c_int) c_int` |
| `rvn_bidi_paragraph_rtl` | `int rvn_bidi_paragraph_rtl(const char* text, int length)` | `export fn rvn_bidi_paragraph_rtl(text: [*c]const u8, length: c_int) c_int` |
| `rvn_bidi_visual` | `char* rvn_bidi_visual(const char* text, int length, int* out_length)` | `export fn rvn_bidi_visual(text: [*c]const u8, length: c_int, out_length: [*c]c_int) [*c]u8` |

### `src/render/texture.c` -> `zig/src/render/texture.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_texture_get` | `rvn_texture_t* rvn_texture_get(Rid id)` | `export fn rvn_texture_get(id: raven.Rid) [*c]rvn_texture_t` |
| `rvn_texture_register` | `rvn_texture_t* rvn_texture_register(void)` | `export fn rvn_texture_register() [*c]rvn_texture_t` |
| `rvn_texture_create_raw` | `Rid rvn_texture_create_raw(int width, int height, RTextureFormat format, RFilterType filter, void* pixels)` | `export fn rvn_texture_create_raw(width: c_int, height: c_int, format: raven.RTextureFormat, filter: raven.RFilterType, pixels: ?*anyopaque) raven.Rid` |
| `rvn_textures_shutdown` | `void rvn_textures_shutdown(void)` | `export fn rvn_textures_shutdown() void` |
| `Rtexture_create` | `Rid Rtexture_create(const char* data, size_t data_size)` | `export fn Rtexture_create(data: [*c]const u8, data_size: usize) Rid` |
| `Rtexture_create_async` | `Rid Rtexture_create_async(const char* data, size_t data_size)` | `export fn Rtexture_create_async(data: [*c]const u8, data_size: usize) Rid` |
| `rvn_texture_create_from_url_async` | `Rid rvn_texture_create_from_url_async(const char* url)` | `export fn rvn_texture_create_from_url_async(url: [*c]const u8) raven.Rid` |
| `Rtexture_create_from_file` | `Rid Rtexture_create_from_file(const char* path)` | `export fn Rtexture_create_from_file(path: [*c]const u8) Rid` |
| `Rtexture_create_from_file_async` | `Rid Rtexture_create_from_file_async(const char* path)` | `export fn Rtexture_create_from_file_async(path: [*c]const u8) Rid` |
| `Rtexture_create_from_pixels` | `Rid Rtexture_create_from_pixels(const uint8_t* rgba, int width, int height)` | `export fn Rtexture_create_from_pixels(rgba: [*c]const u8, width: c_int, height: c_int) Rid` |
| `Rtexture_update` | `void Rtexture_update(Rid id, const uint8_t* rgba, int width, int height)` | `export fn Rtexture_update(texture: Rid, rgba: [*c]const u8, width: c_int, height: c_int) void` |
| `Rtexture_is_ready` | `int Rtexture_is_ready(Rid id)` | `export fn Rtexture_is_ready(texture: Rid) c_int` |
| `Rtexture_wait` | `void Rtexture_wait(Rid id)` | `export fn Rtexture_wait(texture: Rid) void` |
| `Rtexture_destroy` | `void Rtexture_destroy(Rid id)` | `export fn Rtexture_destroy(texture: Rid) void` |
| `Rtexture_is_valid` | `int Rtexture_is_valid(Rid id)` | `export fn Rtexture_is_valid(texture: Rid) c_int` |
| `Rtexture_get_size` | `void Rtexture_get_size(Rid id, int* width, int* height)` | `export fn Rtexture_get_size(texture: Rid, width: [*c]c_int, height: [*c]c_int) void` |
| `Rtexture_set_filter` | `void Rtexture_set_filter(Rid id, RFilterType filter)` | `export fn Rtexture_set_filter(texture: Rid, filter: RFilterType) void` |
| `Rimage_decode` | `uint8_t* Rimage_decode(const void* data, size_t data_size, int* width, int* height)` | `export fn Rimage_decode(data: ?*const anyopaque, data_size: usize, width: [*c]c_int, height: [*c]c_int) [*c]u8` |

### `src/render/font_system.c` -> `zig/src/render/font_system.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_font_system_candidates` | `int rvn_font_system_candidates(uint32_t codepoint, const char** paths, int max)` | `export fn rvn_font_system_candidates(codepoint: u32, paths: [*c][*c]const u8, max: c_int) c_int` |
| `rvn_font_system_shutdown` | `void rvn_font_system_shutdown(void)` | `export fn rvn_font_system_shutdown() void` |

### `src/render/shader.c` -> `zig/src/render/shader.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_shader_get` | `rvn_shader_t* rvn_shader_get(Rid id)` | `export fn rvn_shader_get(id: raven.Rid) [*c]rvn_shader_t` |
| `Rshader_create` | `Rid Rshader_create(const void* spirv, size_t size, Ruint flags)` | `export fn Rshader_create(spirv: ?*const anyopaque, size: usize, flags: Ruint) Rid` |
| `Rshader_create_from_file` | `Rid Rshader_create_from_file(const char* path, Ruint flags)` | `export fn Rshader_create_from_file(path: [*c]const u8, flags: Ruint) Rid` |
| `rvn_shader_from_file_cached` | `Rid rvn_shader_from_file_cached(const char* path, Ruint flags)` | `export fn rvn_shader_from_file_cached(path: [*c]const u8, flags: raven.Ruint) raven.Rid` |
| `Rshader_destroy` | `void Rshader_destroy(Rid id)` | `export fn Rshader_destroy(shader: Rid) void` |
| `Rshader_is_valid` | `int Rshader_is_valid(Rid id)` | `export fn Rshader_is_valid(shader: Rid) c_int` |
| `Rshader_get_flags` | `Ruint Rshader_get_flags(Rid id)` | `export fn Rshader_get_flags(shader: Rid) Ruint` |
| `rvn_shaders_shutdown` | `void rvn_shaders_shutdown(void)` | `export fn rvn_shaders_shutdown() void` |
| `Reffect_get` | `Rid Reffect_get(REffect effect)` | `export fn Reffect_get(effect: REffect) Rid` |
| `Reffect_find` | `Rid Reffect_find(const char* name)` | `export fn Reffect_find(name: [*c]const u8) Rid` |
| `Reffect_get_name` | `const char* Reffect_get_name(REffect effect)` | `export fn Reffect_get_name(effect: REffect) [*c]const u8` |
| `Rshader_look_init` | `void Rshader_look_init(RShaderLook* look)` | `export fn Rshader_look_init(look: [*c]RShaderLook) void` |
| `Reffect_get_defaults` | `void Reffect_get_defaults(REffect effect, RShaderLook* look)` | `export fn Reffect_get_defaults(effect: REffect, look: [*c]RShaderLook) void` |
| `Rshader_look_defaults` | `void Rshader_look_defaults(Rid id, RShaderLook* look)` | `export fn Rshader_look_defaults(shader: Rid, look: [*c]RShaderLook) void` |
| `rvn_paint_shader` | `void rvn_paint_shader(RPainter* painter, rvn_rect_t rect, const float radii[4], Rid id, const RShaderLook* look)` | `export fn rvn_paint_shader(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, shader: raven.Rid, look: [*c]const raven.RShaderLook) void` |
| `Rdraw_shader` | `void Rdraw_shader(RPainter* painter, Rid shader, float x, float y, float width, float height, const RShaderLook* look)` | `export fn Rdraw_shader(painter: ?*RPainter, shader: Rid, x: f32, y: f32, width: f32, height: f32, look: [*c]const RShaderLook) void` |

### `src/render/vulkan/vk_glass.c` -> `zig/src/render/vulkan/vk_glass.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_vk_glass_release` | `void rvn_vk_glass_release(rvn_vk_surface_t* surface)` | `export fn rvn_vk_glass_release(surface: [*c]rvn_vk_surface_t) void` |
| `rvn_vk_glass_prepare` | `int rvn_vk_glass_prepare(rvn_vk_surface_t* surface)` | `export fn rvn_vk_glass_prepare(surface: [*c]rvn_vk_surface_t) c_int` |
| `rvn_vk_glass_begin_scene` | `void rvn_vk_glass_begin_scene(VkCommandBuffer commands, const rvn_vk_surface_t* surface, const VkClearValue* clear)` | `export fn rvn_vk_glass_begin_scene(commands: vk.VkCommandBuffer, surface: [*c]const rvn_vk_surface_t, clear: [*c]const vk.VkClearValue) void` |
| `rvn_vk_glass_capture` | `void rvn_vk_glass_capture(VkCommandBuffer commands, rvn_vk_surface_t* surface, float scale, const int rect[4])` | `export fn rvn_vk_glass_capture(commands: vk.VkCommandBuffer, surface: [*c]rvn_vk_surface_t, scale: f32, rect: [*c]const c_int) void` |
| `rvn_vk_glass_present_scene` | `void rvn_vk_glass_present_scene(VkCommandBuffer commands, const rvn_vk_surface_t* surface)` | `export fn rvn_vk_glass_present_scene(commands: vk.VkCommandBuffer, surface: [*c]const rvn_vk_surface_t) void` |

### `src/render/vulkan/vk_public.c` -> `zig/src/render/vulkan/vk_public.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `Rvulkan_get_required_instance_extensions` | `const char* const* Rvulkan_get_required_instance_extensions(Ruint* count)` | `export fn Rvulkan_get_required_instance_extensions(count: [*c]Ruint) [*c]const [*c]const u8` |
| `Rvulkan_get_required_device_extensions` | `const char* const* Rvulkan_get_required_device_extensions(Ruint* count)` | `export fn Rvulkan_get_required_device_extensions(count: [*c]Ruint) [*c]const [*c]const u8` |
| `Rvulkan_set_external_device` | `void Rvulkan_set_external_device(void* instance, void* physical_device, void* device, void* queue, Ruint queue_family)` | `export fn Rvulkan_set_external_device(instance: ?*anyopaque, physical_device: ?*anyopaque, device: ?*anyopaque, queue: ?*anyopaque, queue_family: Ruint) void` |
| `Rvulkan_set_queue_lock_callbacks` | `void Rvulkan_set_queue_lock_callbacks(RVulkanQueueLockCallback lock, RVulkanQueueLockCallback unlock, void* user_data)` | `export fn Rvulkan_set_queue_lock_callbacks(lock: RVulkanQueueLockCallback, unlock: RVulkanQueueLockCallback, user_data: ?*anyopaque) void` |
| `Rvulkan_get_instance` | `void* Rvulkan_get_instance(void)` | `export fn Rvulkan_get_instance() ?*anyopaque` |
| `Rvulkan_get_physical_device` | `void* Rvulkan_get_physical_device(void)` | `export fn Rvulkan_get_physical_device() ?*anyopaque` |
| `Rvulkan_get_device` | `void* Rvulkan_get_device(void)` | `export fn Rvulkan_get_device() ?*anyopaque` |
| `Rvulkan_get_graphics_queue` | `void* Rvulkan_get_graphics_queue(void)` | `export fn Rvulkan_get_graphics_queue() ?*anyopaque` |
| `Rvulkan_get_graphics_queue_family` | `Ruint Rvulkan_get_graphics_queue_family(void)` | `export fn Rvulkan_get_graphics_queue_family() Ruint` |
| `Rvulkan_texture_create_from_image_view` | `Rid Rvulkan_texture_create_from_image_view(uint64_t image_view, uint64_t sampler, int width, int height)` | `export fn Rvulkan_texture_create_from_image_view(image_view: u64, sampler: u64, width: c_int, height: c_int) Rid` |
| `Rvulkan_texture_set_image_view` | `void Rvulkan_texture_set_image_view(Rid id, uint64_t image_view, uint64_t sampler, int width, int height)` | `export fn Rvulkan_texture_set_image_view(texture: Rid, image_view: u64, sampler: u64, width: c_int, height: c_int) void` |
| `Rvulkan_texture_create_shared` | `Rid Rvulkan_texture_create_shared(int width, int height)` | `export fn Rvulkan_texture_create_shared(width: c_int, height: c_int) Rid` |
| `Rvulkan_texture_get_shared_info` | `int Rvulkan_texture_get_shared_info(Rid id, RSharedTextureInfo* info)` | `export fn Rvulkan_texture_get_shared_info(texture: Rid, info: [*c]RSharedTextureInfo) c_int` |

### `src/render/vulkan/vk_loader.c` -> `zig/src/render/vulkan/vk_loader.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_vk` | `rvn_vk_functions_t rvn_vk;` | `export var rvn_vk: rvn_vk_functions_t` |
| `rvn_vk_library_open` | `void* rvn_vk_library_open(const char* name)` | `export fn rvn_vk_library_open(name: [*c]const u8) ?*anyopaque` |
| `rvn_vk_library_symbol` | `void* rvn_vk_library_symbol(void* library, const char* name)` | `export fn rvn_vk_library_symbol(library: ?*anyopaque, name: [*c]const u8) ?*anyopaque` |
| `rvn_vk_library_close` | `void rvn_vk_library_close(void* library)` | `export fn rvn_vk_library_close(library: ?*anyopaque) void` |
| `rvn_vk_load_library` | `int rvn_vk_load_library(void)` | `export fn rvn_vk_load_library() c_int` |
| `rvn_vk_unload_library` | `void rvn_vk_unload_library(void)` | `export fn rvn_vk_unload_library() void` |
| `rvn_vk_load_instance` | `int rvn_vk_load_instance(VkInstance instance)` | `export fn rvn_vk_load_instance(instance: vk.VkInstance) c_int` |
| `rvn_vk_load_device` | `int rvn_vk_load_device(VkDevice device)` | `export fn rvn_vk_load_device(device: vk.VkDevice) c_int` |
| `rvn_vk_result_name` | `const char* rvn_vk_result_name(VkResult result)` | `export fn rvn_vk_result_name(result: vk.VkResult) [*c]const u8` |

### `src/render/font_raster.c` -> `zig/src/render/font_raster.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_ttf_has_color` | `int rvn_ttf_has_color(rvn_ttf_t* ttf)` | `export fn rvn_ttf_has_color(ttf: ?*rvn_ttf_t) c_int` |
| `rvn_ttf_color_layers` | `int rvn_ttf_color_layers(rvn_ttf_t* ttf, int glyph, int* glyphs, uint32_t* colors, int max)` | `export fn rvn_ttf_color_layers(ttf: ?*rvn_ttf_t, glyph: c_int, glyphs: [*c]c_int, colors: [*c]u32, max: c_int) c_int` |
| `rvn_ttf_open` | `rvn_ttf_t* rvn_ttf_open(const uint8_t* data, size_t size)` | `export fn rvn_ttf_open(data: [*c]const u8, size: usize) ?*rvn_ttf_t` |
| `rvn_ttf_close` | `void rvn_ttf_close(rvn_ttf_t* ttf)` | `export fn rvn_ttf_close(ttf: ?*rvn_ttf_t) void` |
| `rvn_ttf_glyph_index` | `int rvn_ttf_glyph_index(rvn_ttf_t* ttf, uint32_t codepoint)` | `export fn rvn_ttf_glyph_index(ttf: ?*rvn_ttf_t, codepoint: u32) c_int` |
| `rvn_ttf_advance` | `float rvn_ttf_advance(rvn_ttf_t* ttf, int glyph)` | `export fn rvn_ttf_advance(ttf: ?*rvn_ttf_t, glyph: c_int) f32` |
| `rvn_ttf_vmetrics` | `void rvn_ttf_vmetrics(rvn_ttf_t* ttf, float* ascent, float* descent, float* line_gap)` | `export fn rvn_ttf_vmetrics(ttf: ?*rvn_ttf_t, ascent: [*c]f32, descent: [*c]f32, line_gap: [*c]f32) void` |
| `rvn_ttf_glyph_box` | `void rvn_ttf_glyph_box(rvn_ttf_t* ttf, int glyph, float size_px, int* x0, int* y0, int* x1, int* y1)` | `export fn rvn_ttf_glyph_box(ttf: ?*rvn_ttf_t, glyph: c_int, size_px: f32, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) void` |
| `rvn_ttf_render` | `void rvn_ttf_render(rvn_ttf_t* ttf, int glyph, float size_px, uint8_t* out, int width, int height, int stride)` | `export fn rvn_ttf_render(ttf: ?*rvn_ttf_t, glyph: c_int, size_px: f32, out: [*c]u8, width: c_int, height: c_int, stride: c_int) void` |
| `rvn_ttf_render_bold` | `void rvn_ttf_render_bold(rvn_ttf_t* ttf, int glyph, float size_px, float spread, uint8_t* out, int width, int height, int stride)` | `export fn rvn_ttf_render_bold(ttf: ?*rvn_ttf_t, glyph: c_int, size_px: f32, spread: f32, out: [*c]u8, width: c_int, height: c_int, stride: c_int) void` |

### `src/render/null/null_backend.c` -> `zig/src/render/null/null_backend.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_backend_null` | `const RBackendVTable* rvn_backend_null(void)` | `export fn rvn_backend_null() [*c]const raven.RBackendVTable` |

### `src/render/image_decode.c` -> `zig/src/render/image_decode.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_image_decode` | `uint8_t* rvn_image_decode(const uint8_t* data, size_t size, int* width, int* height)` | `export fn rvn_image_decode(data: [*c]const u8, size: usize, width: [*c]c_int, height: [*c]c_int) [*c]u8` |

### `src/render/vulkan/vk_backend.c` -> `zig/src/render/vulkan/vk_backend.zig`

| symbol | C signature | Zig signature (`export`) |
|---|---|---|
| `rvn_backend_vulkan` | `const RBackendVTable* rvn_backend_vulkan(void)` | `export fn rvn_backend_vulkan() [*c]const raven.RBackendVTable` |


## Layout check removed (2026-11-13)

The C-vs-Zig layout check of this module's private types (layout/*_layout.c and its Zig side) was removed: every C file of
the library is translated, so no C code compiles the private headers any more and the header units are the only definition
of these types. `check.sh` step 3 still compares the public types (include/raven) with the C compiler, and step 3b the
system types (pthread, timespec, pollfd, dirent) the Zig code takes from std.c (layout/system_layout.c).
