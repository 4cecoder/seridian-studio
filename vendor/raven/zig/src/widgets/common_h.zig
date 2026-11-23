// Translated to Zig from vendor/raven/src/widgets/common.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/common.h
// Shared by the widget implementations: class declarations and helpers for
// text, scrollbars and single-line text editing.
//
// Header unit: `const common = @import("common_h.zig");`. Exports nothing.
// Depends on the header units of widget/widget.h (widget_h.zig), render/draw.h (draw_h.zig) and core/context.h
// (context_h.zig); render/font.h declares nothing this header uses.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const draw_h = @import("../render/draw_h.zig");
const context_h = @import("../core/context_h.zig");

pub const rvn_widget_t = widget_h.rvn_widget_t;
pub const rvn_widget_class_t = widget_h.rvn_widget_class_t;
pub const rvn_window_t = widget_h.rvn_window_t;
pub const rvn_glass_t = draw_h.rvn_glass_t;
pub const rvn_theme_t = context_h.rvn_theme_t;

// ---------------------------------------------------------------------------
//  Classes (one per file of this folder)
// ---------------------------------------------------------------------------

pub extern const rvn_class_vbox: widget_h.rvn_widget_class_t;
pub extern const rvn_class_hbox: widget_h.rvn_widget_class_t;
pub extern const rvn_class_grid: widget_h.rvn_widget_class_t;
pub extern const rvn_class_uniform_grid: widget_h.rvn_widget_class_t;
pub extern const rvn_class_overlay: widget_h.rvn_widget_class_t;
pub extern const rvn_class_border: widget_h.rvn_widget_class_t;
pub extern const rvn_class_size_box: widget_h.rvn_widget_class_t;
pub extern const rvn_class_spacer: widget_h.rvn_widget_class_t;
pub extern const rvn_class_scroll_box: widget_h.rvn_widget_class_t;
pub extern const rvn_class_splitter: widget_h.rvn_widget_class_t;
pub extern const rvn_class_wrap_box: widget_h.rvn_widget_class_t;
pub extern const rvn_class_canvas: widget_h.rvn_widget_class_t;
pub extern const rvn_class_switcher: widget_h.rvn_widget_class_t;
pub extern const rvn_class_tab_view: widget_h.rvn_widget_class_t;
pub extern const rvn_class_expander: widget_h.rvn_widget_class_t;
pub extern const rvn_class_label: widget_h.rvn_widget_class_t;
pub extern const rvn_class_button: widget_h.rvn_widget_class_t;
pub extern const rvn_class_checkbox: widget_h.rvn_widget_class_t;
pub extern const rvn_class_slider: widget_h.rvn_widget_class_t;
pub extern const rvn_class_progress_bar: widget_h.rvn_widget_class_t;
pub extern const rvn_class_image: widget_h.rvn_widget_class_t;
pub extern const rvn_class_text_input: widget_h.rvn_widget_class_t;
pub extern const rvn_class_spin_box: widget_h.rvn_widget_class_t;
pub extern const rvn_class_combo_box: widget_h.rvn_widget_class_t;
pub extern const rvn_class_separator: widget_h.rvn_widget_class_t;
pub extern const rvn_class_list_view: widget_h.rvn_widget_class_t;
pub extern const rvn_class_tree_view: widget_h.rvn_widget_class_t;
pub extern const rvn_class_tile_view: widget_h.rvn_widget_class_t;
pub extern const rvn_class_menu_bar: widget_h.rvn_widget_class_t;
pub extern const rvn_class_menu: widget_h.rvn_widget_class_t;
pub extern const rvn_class_menu_item: widget_h.rvn_widget_class_t;
pub extern const rvn_class_viewport: widget_h.rvn_widget_class_t;
pub extern const rvn_class_custom: widget_h.rvn_widget_class_t;
pub extern const rvn_class_text_editor: widget_h.rvn_widget_class_t;
pub extern const rvn_class_header_bar: widget_h.rvn_widget_class_t;
pub extern const rvn_class_file_browser: widget_h.rvn_widget_class_t;
pub extern const rvn_class_dock_area: widget_h.rvn_widget_class_t;
pub extern const rvn_class_island: widget_h.rvn_widget_class_t;
pub extern const rvn_class_background_blur: widget_h.rvn_widget_class_t;
pub extern const rvn_class_color_picker: widget_h.rvn_widget_class_t;
pub extern const rvn_class_timeline: widget_h.rvn_widget_class_t;
pub extern const rvn_class_node_graph: widget_h.rvn_widget_class_t;
pub extern const rvn_class_block_editor: widget_h.rvn_widget_class_t;

/// Internal class types, outside of the public enum.
pub const RVN_WIDGET_INTERNAL_COMBO_LIST: raven.RWidgetType = @intCast(raven.R_WIDGET_LAST_ + 1);
pub const RVN_WIDGET_INTERNAL_COMPLETION: raven.RWidgetType = @intCast(raven.R_WIDGET_LAST_ + 2);

/// Panels sharing Rpanel_set_spacing start with this layout.
pub const rvn_spaced_panel_t = extern struct {
    base: widget_h.rvn_widget_t,
    spacing: f32,
};
pub const struct_rvn_spaced_panel_t = rvn_spaced_panel_t;

// RVN_ATTR(literal) is `base.rvn_stricmp(name, literal) == 0`, written inline in each set_attribute function.

// ---------------------------------------------------------------------------
//  Text helpers (widgets/common.c)
// ---------------------------------------------------------------------------

/// Font size of a widget: `size` if positive, else its R_METRIC_FONT_SIZE.
pub extern fn rvn_widget_font_size(widget: [*c]const widget_h.rvn_widget_t, size: f32) f32;
/// Width of a single line of text for a widget.
pub extern fn rvn_widget_text_width(widget: [*c]const widget_h.rvn_widget_t, font: raven.Rid, size: f32, text: [*c]const u8) f32;
/// Height of one line of text for a widget.
pub extern fn rvn_widget_line_height(widget: [*c]const widget_h.rvn_widget_t, font: raven.Rid, size: f32) f32;
/// Calls the typed callback result and then the action of the widget; R_TRUE while the widget is alive.
pub extern fn rvn_widget_alive(widget: [*c]const widget_h.rvn_widget_t) c_int;
/// Draws the keyboard focus outline of a widget when it should be visible.
pub extern fn rvn_paint_focus(widget: [*c]const widget_h.rvn_widget_t, painter: ?*raven.RPainter, radius: f32) void;

// ---------------------------------------------------------------------------
//  Glass themes (widgets/common.c)
//
//  With a glass theme (g_rvn.theme.glass) the widgets draw their surfaces
//  with the helpers below instead of flat boxes. The tint of each kind of
//  surface comes from a color role, so the palette still drives the look.
// ---------------------------------------------------------------------------

pub const rvn_surface_t = c_uint;
/// Buttons, combo boxes: R_COLOR_CONTROL, _HOVERED, _PRESSED.
pub const RVN_SURFACE_CONTROL: c_int = 0;
/// Primary buttons: R_COLOR_ACCENT, _HOVERED, _PRESSED.
pub const RVN_SURFACE_ACCENT: c_int = 1;
/// Text fields: R_COLOR_INPUT.
pub const RVN_SURFACE_INPUT: c_int = 2;
/// Bars across the window: R_COLOR_PANEL.
pub const RVN_SURFACE_BAR: c_int = 3;
/// Panels (Border with the glass material): R_COLOR_PANEL.
pub const RVN_SURFACE_PANEL: c_int = 4;
/// Menus, drop-down lists, tooltips: R_COLOR_POPUP.
pub const RVN_SURFACE_POPUP: c_int = 5;
/// A knob being dragged: almost clear, strongly refracting.
pub const RVN_SURFACE_LENS: c_int = 6;

/// Corner radius of a control of the given height: its metric, or half the height (a capsule) with a glass theme.
pub extern fn rvn_control_radius(widget: [*c]const widget_h.rvn_widget_t, height: f32) f32;
/// Look of a kind of surface in the current theme; `hover` and `press` are 0..1.
pub extern fn rvn_glass_style(widget: [*c]const widget_h.rvn_widget_t, kind: rvn_surface_t, hover: f32, press: f32, glass: [*c]draw_h.rvn_glass_t) void;
/// Applies the glass metrics of the theme (R_METRIC_GLASS_...) to a glass made by hand.
pub extern fn rvn_glass_tune(widget: [*c]const widget_h.rvn_widget_t, glass: [*c]draw_h.rvn_glass_t) void;
/// Glass surface with one radius, dimmed when the painter is disabled.
pub extern fn rvn_paint_surface(painter: ?*raven.RPainter, widget: [*c]const widget_h.rvn_widget_t, rect: base.rvn_rect_t, radius: f32, kind: rvn_surface_t, hover: f32, press: f32) void;
/// Background of a hovered or selected row: a plain rectangle, or an inset
/// rounded one with a glass theme.
pub extern fn rvn_paint_row(painter: ?*raven.RPainter, widget: [*c]const widget_h.rvn_widget_t, row: base.rvn_rect_t, color: base.rvn_color_t) void;
/// Eased hover / pressed state of a widget for the glass themes (widget->anim).
pub extern fn rvn_widget_hover(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter, hovered: c_int) f32;
pub extern fn rvn_widget_press(widget: [*c]widget_h.rvn_widget_t, painter: ?*raven.RPainter, pressed: c_int) f32;
/// Squash and stretch: sets the transform of the widget from its press state
/// (rvn_widget_press), `amount` being the part of its height it loses when
/// fully pressed. To call from the paint function, every time.
pub extern fn rvn_widget_squash(widget: [*c]widget_h.rvn_widget_t, press: f32, amount: f32) void;
/// A solid knob with a soft shadow (slider, switch), or a lens of clear glass while `press` is 1.
pub extern fn rvn_paint_knob(painter: ?*raven.RPainter, widget: [*c]const widget_h.rvn_widget_t, rect: base.rvn_rect_t, press: f32) void;

/// Where a source of `size` texels goes in an area, and which part of it shows (widgets/image.c).
pub extern fn rvn_image_fit(stretch: raven.RStretch, size: base.rvn_vec2_t, width: f32, height: f32, uv_in: [*c]const f32, rect: [*c]base.rvn_rect_t, uv_out: [*c]f32) void;
pub extern fn rvn_parse_stretch(value: [*c]const u8, stretch: [*c]raven.RStretch) c_int;
/// Texture / font of a file named in an attribute, loaded once (xml/xml_loader.c).
pub extern fn rvn_xml_texture(path: [*c]const u8) raven.Rid;
pub extern fn rvn_xml_font(path: [*c]const u8) raven.Rid;
/// Theme named in an attribute: the name of a theme, or the path of a theme file (widget/theme.c). NULL after reporting the error.
pub extern fn rvn_xml_theme(value: [*c]const u8) [*c]const context_h.rvn_theme_t;
pub extern fn rvn_xml_shutdown() void;
/// A mouse button was pressed on `hit` (NULL: on nothing): the unfolded islands of the window it is not in fold (widgets/island.c).
pub extern fn rvn_islands_pressed(window: [*c]widget_h.rvn_window_t, hit: [*c]widget_h.rvn_widget_t, on_popup: c_int) void;
pub extern fn rvn_islands_shutdown() void;
/// Releases what the file dialogs remember (widgets/dialogs.c).
pub extern fn rvn_dialogs_shutdown() void;

// ---------------------------------------------------------------------------
//  Formatted text (widgets/markdown.c), used by the labels
// ---------------------------------------------------------------------------

/// A Markdown text, parsed, and laid out for a width. Opaque outside widgets/markdown.c.
pub const rvn_md_t = opaque {};
pub const struct_rvn_md_t = rvn_md_t;

pub extern fn rvn_md_parse(source: [*c]const u8) ?*rvn_md_t;
pub extern fn rvn_md_free(md: ?*rvn_md_t) void;
/// Places the text for a font, a size and a width (0: nothing wraps) and
/// returns the room it takes. Cheap when nothing changed. UI thread only.
pub extern fn rvn_md_layout(md: ?*rvn_md_t, widget: [*c]const widget_h.rvn_widget_t, font: raven.Rid, size: f32, width: f32) base.rvn_vec2_t;
/// Draws what the last layout placed, from (x, y) in the widget. `hot_link`: the link under the pointer, or -1.
pub extern fn rvn_md_paint(md: ?*const rvn_md_t, widget: [*c]const widget_h.rvn_widget_t, painter: ?*raven.RPainter, x: f32, y: f32, color: base.rvn_color_t, hot_link: c_int) void;
/// Link at a point of the laid out text, or -1.
pub extern fn rvn_md_link_at(md: ?*const rvn_md_t, x: f32, y: f32) c_int;
/// Address of a link, or NULL.
pub extern fn rvn_md_link(md: ?*const rvn_md_t, link: c_int) [*c]const u8;
pub extern fn rvn_md_link_count(md: ?*const rvn_md_t) c_int;
/// The text without its marks, appended to `out`.
pub extern fn rvn_md_plain_text(md: ?*const rvn_md_t, out: [*c]base.rvn_text_t) void;

// ---------------------------------------------------------------------------
//  Syntax colors (widgets/syntax.c), used by the text editor
// ---------------------------------------------------------------------------

pub const rvn_token_t = c_uint;
pub const RVN_TOKEN_TEXT: c_int = 0;
pub const RVN_TOKEN_COMMENT: c_int = 1;
pub const RVN_TOKEN_STRING: c_int = 2;
pub const RVN_TOKEN_NUMBER: c_int = 3;
pub const RVN_TOKEN_KEYWORD: c_int = 4;
pub const RVN_TOKEN_TAG: c_int = 5;
pub const RVN_TOKEN_ATTRIBUTE: c_int = 6;
pub const RVN_TOKEN_PUNCTUATION: c_int = 7;
pub const RVN_TOKEN_PREPROCESSOR: c_int = 8;
pub const RVN_TOKEN_TYPE: c_int = 9;
pub const RVN_TOKEN_FUNCTION: c_int = 10;
// formatted text (Markdown)
pub const RVN_TOKEN_HEADING: c_int = 11;
pub const RVN_TOKEN_STRONG: c_int = 12;
pub const RVN_TOKEN_EMPHASIS: c_int = 13;
pub const RVN_TOKEN_LINK: c_int = 14;
pub const RVN_TOKEN_COUNT: c_int = 15;

/// A run of bytes of a line with one kind of token. What no span covers is plain text.
pub const rvn_span_t = extern struct {
    start: c_int,
    end: c_int,
    token: u8,
};
pub const struct_rvn_span_t = rvn_span_t;

/// A language of the text editor (Rlanguage_register), ready to be used by the lexers. Opaque outside widgets/syntax.c.
pub const rvn_language_t = opaque {};
pub const struct_rvn_language_t = rvn_language_t;

/// Language by name, by one of its other names, or by the extension of its files. NULL when unknown.
pub extern fn rvn_language_find(name: [*c]const u8) ?*const rvn_language_t;
pub extern fn rvn_language_desc(language: ?*const rvn_language_t) [*c]const raven.RLanguageDesc;
/// Changes each time a language is declared: what was found before must be looked for again.
pub extern fn rvn_language_generation() u32;
/// The words of a language: list 0 = keywords, 1 = types, 2 = constants.
pub extern fn rvn_language_word_count(language: ?*const rvn_language_t, list: c_int) c_int;
pub extern fn rvn_language_word(language: ?*const rvn_language_t, list: c_int, index: c_int) [*c]const u8;
pub extern fn rvn_languages_shutdown() void;

/// Cuts one line into spans, in order. `state` is what the line starts in (0
/// at the top of the text); the result is the state of the next line.
/// `spans` may be NULL to only compute the state.
pub extern fn rvn_syntax_line(language: ?*const rvn_language_t, text: [*c]const u8, length: c_int, state: u8, spans: [*c]rvn_span_t, max: c_int, count: [*c]c_int) u8;
/// The public name of a kind of token.
pub extern fn rvn_token_public(token: rvn_token_t) raven.RToken;
/// Color of a token in a theme; `text` is the color of plain text.
pub extern fn rvn_syntax_color(theme: [*c]const context_h.rvn_theme_t, token: rvn_token_t, text: base.rvn_color_t) base.rvn_color_t;

// ---------------------------------------------------------------------------
//  Scrollbar (widgets/common.c): state + painting + mouse handling
// ---------------------------------------------------------------------------

pub const rvn_scrollbar_t = extern struct {
    /// Current scroll position, 0 .. content - viewport.
    offset: f32,
    /// Length of the content and of the visible part.
    content: f32,
    viewport: f32,
    dragging: c_int,
    /// Distance between the cursor and the start of the thumb while dragging.
    grab: f32,
    /// The position that is drawn. It glides to `offset`, and a wheel that
    /// pushes against an end sends it past the end for a moment: the content
    /// stretches away and comes back, as on a phone.
    shown: raven.RSpring,
    /// Glass themes: the thumb only shows while the content moves or the pointer is near.
    fade: raven.RSpring,
};
pub const struct_rvn_scrollbar_t = rvn_scrollbar_t;

pub extern fn rvn_scrollbar_max(bar: [*c]const rvn_scrollbar_t) f32;
pub extern fn rvn_scrollbar_needed(bar: [*c]const rvn_scrollbar_t) c_int;
/// Clamps the offset; returns R_TRUE when it changed.
pub extern fn rvn_scrollbar_clamp(bar: [*c]rvn_scrollbar_t) c_int;
pub extern fn rvn_scrollbar_set(bar: [*c]rvn_scrollbar_t, offset: f32) c_int;
/// Scrolls by `delta` logical units (the wheel). Returns R_TRUE when the
/// offset changed; at an end of the range it returns R_FALSE and makes the
/// content bounce, which only needs a repaint.
pub extern fn rvn_scrollbar_wheel(bar: [*c]rvn_scrollbar_t, delta: f32) c_int;
/// While painting: advances the drawn position and returns it. It may lie outside 0 .. max.
pub extern fn rvn_scrollbar_shown(bar: [*c]rvn_scrollbar_t, painter: ?*raven.RPainter) f32;
pub extern fn rvn_scrollbar_paint(bar: [*c]rvn_scrollbar_t, widget: [*c]const widget_h.rvn_widget_t, painter: ?*raven.RPainter, track: base.rvn_rect_t, vertical: c_int, mouse_x: f32, mouse_y: f32) void;
/// Handles mouse down / move / up on the track (given in widget coordinates).
/// Returns R_TRUE when the event was used; *changed is set when the offset moved.
pub extern fn rvn_scrollbar_event(bar: [*c]rvn_scrollbar_t, widget: [*c]widget_h.rvn_widget_t, event: [*c]const raven.REvent, track: base.rvn_rect_t, vertical: c_int, changed: [*c]c_int) c_int;

// ---------------------------------------------------------------------------
//  Single-line text editing (widgets/textedit.c), used by TextInput and SpinBox
// ---------------------------------------------------------------------------

pub const RVN_TEXTEDIT_HANDLED: c_int = 1 << 0;
pub const RVN_TEXTEDIT_CHANGED: c_int = 1 << 1;
pub const RVN_TEXTEDIT_COMMITTED: c_int = 1 << 2;

pub const rvn_textedit_t = extern struct {
    text: [*c]u8,
    length: c_int,
    cap: c_int,
    /// Caret and selection anchor, as byte offsets. The selection is the range between them.
    caret: c_int,
    anchor: c_int,
    scroll: f32,
    max_chars: c_int,
    password: c_int,
    read_only: c_int,
    mouse_selecting: c_int,
    blink_timer: raven.Rid,
    blink_start: f64,
};
pub const struct_rvn_textedit_t = rvn_textedit_t;

pub extern fn rvn_textedit_init(edit: [*c]rvn_textedit_t) void;
pub extern fn rvn_textedit_free(edit: [*c]rvn_textedit_t) void;
/// Returns R_TRUE when the text changed.
pub extern fn rvn_textedit_set_text(edit: [*c]rvn_textedit_t, text: [*c]const u8) c_int;
pub extern fn rvn_textedit_select_all(edit: [*c]rvn_textedit_t) void;
/// Starts or stops the caret blinking of the widget owning the editor.
pub extern fn rvn_textedit_set_focused(edit: [*c]rvn_textedit_t, widget: [*c]widget_h.rvn_widget_t, focused: c_int) void;
/// Key and text events. Returns a combination of RVN_TEXTEDIT_... flags.
pub extern fn rvn_textedit_key(edit: [*c]rvn_textedit_t, event: [*c]const raven.REvent) c_int;
pub extern fn rvn_textedit_input(edit: [*c]rvn_textedit_t, codepoint: u32) c_int;
/// Mouse press / drag at a horizontal position relative to the left of the text area.
pub extern fn rvn_textedit_mouse_down(edit: [*c]rvn_textedit_t, widget: [*c]const widget_h.rvn_widget_t, font: raven.Rid, size: f32, x: f32, clicks: c_int, extend: c_int) void;
pub extern fn rvn_textedit_mouse_drag(edit: [*c]rvn_textedit_t, widget: [*c]const widget_h.rvn_widget_t, font: raven.Rid, size: f32, x: f32) void;
/// Draws selection, text and caret inside `area` (widget coordinates).
pub extern fn rvn_textedit_paint(edit: [*c]rvn_textedit_t, widget: [*c]const widget_h.rvn_widget_t, painter: ?*raven.RPainter, area: base.rvn_rect_t, font: raven.Rid, size: f32, color: base.rvn_color_t, focused: c_int) void;
