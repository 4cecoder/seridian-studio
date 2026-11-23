// Translated to Zig from vendor/raven/src/widget/theme.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/theme.c
// Named themes, styles (values for a type of widget and / or a class), themes
// given to a part of the widget tree, and theme files.
//
// The theme in use is g_rvn.theme. Named themes live in g_rvn.themes, at
// addresses that never change: a widget given a theme of its own points to
// one of them, and so does everything inside it.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const thread_h = @import("../core/thread_h.zig");
const handle_h = @import("../core/handle_h.zig");
const widget_h = @import("widget_h.zig");
const common_h = @import("../widgets/common_h.zig");
const xml_h = @import("../xml/xml_h.zig");
const xml_watch_h = @import("../xml/xml_watch_h.zig");
const renderer_h = @import("../render/renderer_h.zig");
const libc = @import("../sys/libc.zig");

inline fn RVN_COLOR_INDEX(role: anytype) c_int {
    return @as(c_int, @intCast(role)) - raven.R_COLOR_WINDOW;
}

inline fn RVN_METRIC_INDEX(metric: anytype) c_int {
    return @as(c_int, @intCast(metric)) - raven.R_METRIC_FONT_SIZE;
}

// RVN_ARRAY_RESERVE(data, cap, needed) of core/base.h. The inline version of base_h.zig cannot take
// a C array of pointers (T**: its rvn_array_grow_ call needs a void*), so the macro is expanded here.
inline fn rvn_array_reserve(data: anytype, cap: [*c]u32, needed: u32) void {
    const Item = @typeInfo(@typeInfo(@TypeOf(data)).pointer.child).pointer.child;
    if (needed > cap.*) data.* = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(data.*), cap, needed, @sizeOf(Item))));
}

const BuiltinTheme = struct { name: [*c]const u8, theme: raven.RTheme };

const g_builtin_themes = [_]BuiltinTheme{
    .{ .name = "Dark", .theme = raven.R_THEME_DARK },
    .{ .name = "Light", .theme = raven.R_THEME_LIGHT },
    .{ .name = "GlassDark", .theme = raven.R_THEME_GLASS_DARK },
    .{ .name = "GlassLight", .theme = raven.R_THEME_GLASS_LIGHT },
    .{ .name = "HighContrastDark", .theme = raven.R_THEME_HIGH_CONTRAST_DARK },
    .{ .name = "HighContrastLight", .theme = raven.R_THEME_HIGH_CONTRAST_LIGHT },
};

/// See rvn_theme_dark_twin.
var g_dark_twin: ctx_h.rvn_theme_t = std.mem.zeroes(ctx_h.rvn_theme_t);

// ---------------------------------------------------------------------------
//  Life of a theme
// ---------------------------------------------------------------------------

fn rvn_theme_free_matches(theme: [*c]ctx_h.rvn_theme_t) void {
    var i: u32 = 0;
    while (i < theme.*.match_count) : (i += 1) {
        base.rvn_free(theme.*.matches[i].*.classes);
        base.rvn_free(theme.*.matches[i]);
    }
    base.rvn_free(@ptrCast(theme.*.matches));
    theme.*.matches = null;
    theme.*.match_count = 0;
    theme.*.match_cap = 0;
}

fn rvn_theme_free_rules(theme: [*c]ctx_h.rvn_theme_t) void {
    var i: u32 = 0;
    while (i < theme.*.rule_count) : (i += 1) base.rvn_free(theme.*.rules[i].cls);
    base.rvn_free(theme.*.rules);
    theme.*.rules = null;
    theme.*.rule_count = 0;
    theme.*.rule_cap = 0;
}

export fn rvn_theme_clear(theme: [*c]ctx_h.rvn_theme_t) void {
    rvn_theme_free_matches(theme);
    rvn_theme_free_rules(theme);
    base.rvn_free(theme.*.name);
    base.rvn_free(theme.*.path);
    theme.* = std.mem.zeroes(ctx_h.rvn_theme_t);
}

export fn rvn_theme_copy(destination: [*c]ctx_h.rvn_theme_t, source: [*c]const ctx_h.rvn_theme_t) void {
    const name = destination.*.name;
    const path = destination.*.path;
    if (destination == source) return;
    rvn_theme_free_matches(destination);
    rvn_theme_free_rules(destination);
    destination.* = source.*;
    destination.*.name = name;
    destination.*.path = path;
    destination.*.matches = null;
    destination.*.match_count = 0;
    destination.*.match_cap = 0;
    destination.*.rules = null;
    destination.*.rule_cap = 0;
    if (source.*.rule_count != 0) {
        destination.*.rules = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(ctx_h.rvn_style_rule_t) * @as(usize, source.*.rule_count))));
        destination.*.rule_cap = source.*.rule_count;
        var i: u32 = 0;
        while (i < source.*.rule_count) : (i += 1) {
            destination.*.rules[i] = source.*.rules[i];
            destination.*.rules[i].cls = base.rvn_strdup(source.*.rules[i].cls);
        }
    }
}

export fn rvn_themes_init() void {
    thread_h.rvn_mutex_init(&ctx_h.g_rvn.style_mutex);
    ctx_h.g_rvn.style_generation = 1;
    g_dark_twin = std.mem.zeroes(ctx_h.rvn_theme_t);
}

export fn rvn_themes_shutdown() void {
    var i: u32 = 0;
    while (i < ctx_h.g_rvn.theme_count) : (i += 1) {
        rvn_theme_clear(ctx_h.g_rvn.themes[i]);
        base.rvn_free(ctx_h.g_rvn.themes[i]);
    }
    base.rvn_free(@ptrCast(ctx_h.g_rvn.themes));
    ctx_h.g_rvn.themes = null;
    ctx_h.g_rvn.theme_count = 0;
    ctx_h.g_rvn.theme_cap = 0;
    rvn_theme_clear(&ctx_h.g_rvn.theme);
    rvn_theme_clear(&g_dark_twin);
    base.rvn_free(ctx_h.g_rvn.theme_name);
    ctx_h.g_rvn.theme_name = null;
    thread_h.rvn_mutex_destroy(&ctx_h.g_rvn.style_mutex);
}

fn rvn_theme_add(name: [*c]const u8) [*c]ctx_h.rvn_theme_t {
    const theme: [*c]ctx_h.rvn_theme_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(ctx_h.rvn_theme_t))));
    theme.*.name = base.rvn_strdup(name);
    rvn_array_reserve(&ctx_h.g_rvn.themes, &ctx_h.g_rvn.theme_cap, ctx_h.g_rvn.theme_count + 1);
    ctx_h.g_rvn.themes[ctx_h.g_rvn.theme_count] = theme;
    ctx_h.g_rvn.theme_count += 1;
    return theme;
}

export fn rvn_theme_find(name: [*c]const u8) [*c]ctx_h.rvn_theme_t {
    var i: u32 = 0;
    var k: usize = 0;
    if (name == null or name[0] == 0) return null;
    while (i < ctx_h.g_rvn.theme_count) : (i += 1) {
        if (base.rvn_stricmp(ctx_h.g_rvn.themes[i].*.name, name) == 0) return ctx_h.g_rvn.themes[i];
    }
    // the built-in ones are made when first asked for
    while (k < g_builtin_themes.len) : (k += 1) {
        if (base.rvn_stricmp(g_builtin_themes[k].name, name) == 0) {
            const theme = rvn_theme_add(g_builtin_themes[k].name);
            widget_h.rvn_theme_build(theme, g_builtin_themes[k].theme);
            return theme;
        }
    }
    return null;
}

fn rvn_theme_builtins() void {
    var k: usize = 0;
    while (k < g_builtin_themes.len) : (k += 1) _ = rvn_theme_find(g_builtin_themes[k].name);
}

// ---------------------------------------------------------------------------
//  Changes
// ---------------------------------------------------------------------------

export fn rvn_styles_changed() void {
    var i: u32 = 0;
    thread_h.rvn_mutex_lock(&ctx_h.g_rvn.style_mutex);
    rvn_theme_free_matches(&ctx_h.g_rvn.theme);
    rvn_theme_free_matches(&g_dark_twin);
    while (i < ctx_h.g_rvn.theme_count) : (i += 1) rvn_theme_free_matches(ctx_h.g_rvn.themes[i]);
    // (0 is the generation of a widget that never looked)
    ctx_h.g_rvn.style_generation +%= 1;
    if (ctx_h.g_rvn.style_generation == 0) ctx_h.g_rvn.style_generation = 1;
    thread_h.rvn_mutex_unlock(&ctx_h.g_rvn.style_mutex);
}

// What must stay dark whatever the theme (the island) uses the dark
// counterpart of the theme in use: its own colors when it is dark, else the
// built-in dark palette with its accent, its sizes, its material and its
// styles.
fn rvn_theme_refresh_twin() void {
    const kept = [_]raven.RColorRole{
        raven.R_COLOR_ACCENT, raven.R_COLOR_ACCENT_HOVERED, raven.R_COLOR_ACCENT_PRESSED, raven.R_COLOR_ACCENT_TEXT, raven.R_COLOR_FOCUS,
    };
    const theme: [*c]const ctx_h.rvn_theme_t = &ctx_h.g_rvn.theme;
    var i: usize = 0;
    if (theme.*.dark != 0) {
        rvn_theme_copy(&g_dark_twin, theme);
        return;
    }
    widget_h.rvn_theme_build(&g_dark_twin, if (theme.*.glass != 0) raven.R_THEME_GLASS_DARK else raven.R_THEME_DARK);
    while (i < kept.len) : (i += 1) {
        g_dark_twin.colors[@intCast(RVN_COLOR_INDEX(kept[i]))] = theme.*.colors[@intCast(RVN_COLOR_INDEX(kept[i]))];
    }
    @memcpy(&g_dark_twin.metrics, &theme.*.metrics);
    g_dark_twin.material = theme.*.material;
    g_dark_twin.glass = theme.*.glass;
    g_dark_twin.font = theme.*.font;
    g_dark_twin.wallpaper = raven.R_INVALID_ID;
}

export fn rvn_theme_dark_twin() [*c]const ctx_h.rvn_theme_t {
    return &g_dark_twin;
}

export fn rvn_theme_changed() void {
    rvn_theme_refresh_twin();
    rvn_styles_changed();
    ctx_h.rvn_windows_theme_changed();
    ctx_h.rvn_invalidate_all_windows();
}

fn rvn_color_luminance(color: base.rvn_color_t) f32 {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    base.rvn_color_to_floats(color, &r, &g, &b, &a);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export fn rvn_theme_set_accent(theme: [*c]ctx_h.rvn_theme_t, accent: base.rvn_color_t) void {
    const colors: [*c]base.rvn_color_t = &theme.*.colors;
    const opaque_: base.rvn_color_t = (accent & 0x00FFFFFF) | 0xFF000000;
    const white: base.rvn_color_t = base.rvn_hex(0xFFFFFF, 255);
    const black: base.rvn_color_t = base.rvn_hex(0x000000, 255);
    const selection_alpha: u32 = base.rvn_color_a(colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_SELECTION))]);
    const focus_alpha: u32 = base.rvn_color_a(colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_FOCUS))]);
    const switch_follows = colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_SWITCH))] == colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_ACCENT))];

    colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_ACCENT))] = opaque_;
    colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_ACCENT_HOVERED))] = base.rvn_color_mix(opaque_, white, 0.18);
    colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_ACCENT_PRESSED))] = base.rvn_color_mix(opaque_, black, 0.18);
    // what is written on it must stay readable
    colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_ACCENT_TEXT))] = if (rvn_color_luminance(opaque_) > 0.62) base.rvn_hex(0x101014, 255) else white;
    colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_FOCUS))] = base.rvn_color_fade(opaque_, @as(f32, @floatFromInt(if (focus_alpha != 0) focus_alpha else 255)) / 255.0);
    if (selection_alpha < 255) {
        colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_SELECTION))] = base.rvn_color_fade(opaque_, @as(f32, @floatFromInt(selection_alpha)) / 255.0);
    } else {
        colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_SELECTION))] = base.rvn_color_mix(colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_WINDOW))], opaque_, if (theme.*.dark != 0) 0.45 else 0.3);
    }
    colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_LINK))] = if (theme.*.dark != 0) base.rvn_color_mix(opaque_, white, 0.3) else base.rvn_color_mix(opaque_, black, 0.15);
    if (switch_follows) colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_SWITCH))] = opaque_;
}

// ---------------------------------------------------------------------------
//  Styles
// ---------------------------------------------------------------------------

fn rvn_classes_have(classes: [*c]const u8, cls: [*c]const u8) c_int {
    var classes_: [*c]const u8 = classes;
    var length: usize = undefined;
    if (classes_ == null or cls == null or cls[0] == 0) return raven.R_FALSE;
    length = libc.strlen(cls);
    while (classes_[0] != 0) {
        while (classes_[0] == ' ' or classes_[0] == '\t' or classes_[0] == ',') classes_ += 1;
        const start = classes_;
        while (classes_[0] != 0 and classes_[0] != ' ' and classes_[0] != '\t' and classes_[0] != ',') classes_ += 1;
        if (@as(usize, @intCast(classes_ - start)) == length and libc.memcmp(start, cls, length) == 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export fn rvn_widget_has_class(widget: [*c]const widget_h.rvn_widget_t, cls: [*c]const u8) c_int {
    return rvn_classes_have(widget.*.classes, cls);
}

fn rvn_style_overlay(match: [*c]ctx_h.rvn_style_match_t, rule: [*c]const ctx_h.rvn_style_rule_t) void {
    var i: c_int = 0;
    while (i < raven.R_COLOR_COUNT) : (i += 1) {
        if ((rule.*.style.color_mask & (@as(u64, 1) << @intCast(i))) != 0) match.*.style.colors[@intCast(i)] = rule.*.style.colors[@intCast(i)];
    }
    i = 0;
    while (i < raven.R_METRIC_COUNT) : (i += 1) {
        if ((rule.*.style.metric_mask & (@as(u32, 1) << @intCast(i))) != 0) match.*.style.metrics[@intCast(i)] = rule.*.style.metrics[@intCast(i)];
    }
    match.*.style.color_mask |= rule.*.style.color_mask;
    match.*.style.metric_mask |= rule.*.style.metric_mask;
    if (rule.*.material != 0) match.*.material = rule.*.material;
}

// What the styles of a theme give to a type of widget with these classes. Called with the style mutex held.
fn rvn_theme_match(theme: [*c]ctx_h.rvn_theme_t, type_: c_int, classes: [*c]const u8) [*c]const ctx_h.rvn_style_match_t {
    var match: [*c]ctx_h.rvn_style_match_t = undefined;
    var i: u32 = 0;
    var pass: c_int = undefined;
    var classes_: [*c]const u8 = classes;

    if (theme.*.rule_count == 0) return null;
    if (classes_ != null and classes_[0] == 0) classes_ = null;
    while (i < theme.*.match_count) : (i += 1) {
        match = theme.*.matches[i];
        if (match.*.type != type_) continue;
        if ((classes_ == null and match.*.classes == null) or (classes_ != null and match.*.classes != null and libc.strcmp(classes_, match.*.classes) == 0)) {
            return if (match.*.style.color_mask != 0 or match.*.style.metric_mask != 0 or match.*.material != 0) match else null;
        }
    }
    match = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(ctx_h.rvn_style_match_t))));
    match.*.type = type_;
    match.*.classes = base.rvn_strdup(classes_);
    // from the least to the most specific: everything, a type, a class, a type and a class
    pass = 0;
    while (pass < 4) : (pass += 1) {
        var j: u32 = 0;
        while (j < theme.*.rule_count) : (j += 1) {
            const rule: [*c]const ctx_h.rvn_style_rule_t = &theme.*.rules[j];
            const specificity: c_int = @as(c_int, @intFromBool(rule.*.type != 0)) + 2 * @as(c_int, @intFromBool(rule.*.cls != null));
            if (specificity != pass) continue;
            if (rule.*.type != 0 and rule.*.type != type_) continue;
            if (rule.*.cls != null and rvn_classes_have(classes_, rule.*.cls) == 0) continue;
            rvn_style_overlay(match, rule);
        }
    }
    rvn_array_reserve(&theme.*.matches, &theme.*.match_cap, theme.*.match_count + 1);
    theme.*.matches[theme.*.match_count] = match;
    theme.*.match_count += 1;
    return if (match.*.style.color_mask != 0 or match.*.style.metric_mask != 0 or match.*.material != 0) match else null;
}

export fn rvn_widget_restyle(widget: [*c]widget_h.rvn_widget_t) void {
    // (widgets are painted on several threads at once: the caches of the themes are shared)
    thread_h.rvn_mutex_lock(&ctx_h.g_rvn.style_mutex);
    widget.*.match = rvn_theme_match(@constCast(widget_h.rvn_widget_theme(widget)), @as(c_int, @bitCast(widget.*.cls.*.type)), widget.*.classes);
    widget.*.style_generation = ctx_h.g_rvn.style_generation;
    thread_h.rvn_mutex_unlock(&ctx_h.g_rvn.style_mutex);
}

// The rule of a theme for a type and a class, created when missing. `widget` and `cls` may be NULL.
fn rvn_theme_rule(theme: [*c]ctx_h.rvn_theme_t, widget: [*c]const u8, cls: [*c]const u8, function: [*c]const u8) [*c]ctx_h.rvn_style_rule_t {
    var type_: c_int = 0;
    var i: u32 = 0;
    var rule: [*c]ctx_h.rvn_style_rule_t = undefined;
    var widget_: [*c]const u8 = widget;
    var cls_: [*c]const u8 = cls;
    if (widget_ != null and widget_[0] == 0) widget_ = null;
    if (cls_ != null and cls_[0] == 0) cls_ = null;
    if (widget_ != null) {
        const widget_class = widget_h.rvn_widget_class_by_name(widget_);
        if (widget_class == null) {
            base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: no widget is called '%s'", function, widget_);
            return null;
        }
        type_ = @as(c_int, @bitCast(widget_class.*.type));
    }
    while (i < theme.*.rule_count) : (i += 1) {
        rule = &theme.*.rules[i];
        if (rule.*.type != type_) continue;
        if ((cls_ == null and rule.*.cls == null) or (cls_ != null and rule.*.cls != null and libc.strcmp(cls_, rule.*.cls) == 0)) return rule;
    }
    rvn_array_reserve(&theme.*.rules, &theme.*.rule_cap, theme.*.rule_count + 1);
    rule = &theme.*.rules[theme.*.rule_count];
    theme.*.rule_count += 1;
    rule.* = std.mem.zeroes(ctx_h.rvn_style_rule_t);
    rule.*.type = type_;
    rule.*.cls = base.rvn_strdup(cls_);
    return rule;
}

// ---------------------------------------------------------------------------
//  Themes of parts of the tree
// ---------------------------------------------------------------------------

fn rvn_theme_spread(widget: [*c]widget_h.rvn_widget_t, theme: [*c]const ctx_h.rvn_theme_t) void {
    var i: u32 = 0;
    widget.*.theme = theme;
    widget.*.style_generation = 0;
    widget.*.flags |= widget_h.RVN_WF_LAYOUT_DIRTY;
    while (i < widget.*.child_count) : (i += 1) {
        if (widget.*.children[i].*.theme_own == 0) rvn_theme_spread(widget.*.children[i], theme);
    }
}

export fn rvn_widget_set_theme(widget: [*c]widget_h.rvn_widget_t, theme: [*c]const ctx_h.rvn_theme_t, own: c_int) void {
    var theme_: [*c]const ctx_h.rvn_theme_t = theme;
    widget.*.theme_own = @intFromBool(own != 0);
    if (own == 0) theme_ = if (widget.*.parent != null) widget.*.parent.*.theme else null;
    rvn_theme_spread(widget, theme_);
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn rvn_widget_inherit_theme(widget: [*c]widget_h.rvn_widget_t, theme: [*c]const ctx_h.rvn_theme_t) void {
    if (widget.*.theme_own != 0 or widget.*.theme == theme) return;
    rvn_theme_spread(widget, theme);
}

// ---------------------------------------------------------------------------
//  Theme files
// ---------------------------------------------------------------------------

const TokenName = struct { name: [*c]const u8, token: common_h.rvn_token_t };

const g_token_names = [_]TokenName{
    .{ .name = "Comment", .token = common_h.RVN_TOKEN_COMMENT },
    .{ .name = "String", .token = common_h.RVN_TOKEN_STRING },
    .{ .name = "Number", .token = common_h.RVN_TOKEN_NUMBER },
    .{ .name = "Keyword", .token = common_h.RVN_TOKEN_KEYWORD },
    .{ .name = "Tag", .token = common_h.RVN_TOKEN_TAG },
    .{ .name = "Attribute", .token = common_h.RVN_TOKEN_ATTRIBUTE },
    .{ .name = "Punctuation", .token = common_h.RVN_TOKEN_PUNCTUATION },
    .{ .name = "Directive", .token = common_h.RVN_TOKEN_PREPROCESSOR },
    .{ .name = "Type", .token = common_h.RVN_TOKEN_TYPE },
    .{ .name = "Function", .token = common_h.RVN_TOKEN_FUNCTION },
    .{ .name = "Heading", .token = common_h.RVN_TOKEN_HEADING },
    .{ .name = "Strong", .token = common_h.RVN_TOKEN_STRONG },
    .{ .name = "Emphasis", .token = common_h.RVN_TOKEN_EMPHASIS },
    .{ .name = "Link", .token = common_h.RVN_TOKEN_LINK },
};

fn rvn_token_by_name(name_in: [*c]const u8, token: [*c]common_h.rvn_token_t) c_int {
    var name: [*c]const u8 = name_in;
    var i: usize = 0;
    if (base.rvn_stricmp(name, "Preprocessor") == 0) name = "Directive";
    while (i < g_token_names.len) : (i += 1) {
        if (base.rvn_stricmp(g_token_names[i].name, name) == 0) {
            token.* = g_token_names[i].token;
            return raven.R_TRUE;
        }
    }
    return raven.R_FALSE;
}

const rvn_theme_reader_t = extern struct {
    theme: [*c]ctx_h.rvn_theme_t,
    source: [*c]const u8,
    problems: c_int,
};

fn rvn_theme_problem(reader: [*c]rvn_theme_reader_t, node: [*c]const xml_h.rvn_xml_node_t, format: [*c]const u8, a: [*c]const u8, b: [*c]const u8) void {
    var message: [200]u8 = undefined;
    const a_text: [*c]const u8 = if (a != null) a else "";
    const b_text: [*c]const u8 = if (b != null) b else "";
    _ = libc.snprintf(&message, message.len, format, a_text, b_text);
    base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "theme %s:%d: %s", reader.*.source, node.*.line, @as([*c]const u8, &message));
    reader.*.problems += 1;
}

// "#101020, #3040C0, #C02080": a base color and up to five blobs.
fn rvn_theme_wallpaper_from_colors(text_in: [*c]const u8) raven.Rid {
    var text: [*c]const u8 = text_in;
    var colors: [6]u32 = undefined;
    var count: c_int = 0;
    while (text[0] != 0 and count < 6) {
        var word: [16]u8 = undefined;
        var length: usize = 0;
        var color: base.rvn_color_t = undefined;
        var r: f32 = undefined;
        var g: f32 = undefined;
        var b: f32 = undefined;
        var a: f32 = undefined;
        while (text[0] == ' ' or text[0] == ',') text += 1;
        while (text[length] != 0 and text[length] != ',' and text[length] != ' ' and length + 1 < word.len) length += 1;
        if (length == 0) break;
        @memcpy(word[0..length], text[0..length]);
        word[length] = 0;
        text += length;
        if (widget_h.rvn_parse_color(&word, &color) == 0) return raven.R_INVALID_ID;
        base.rvn_color_to_floats(color, &r, &g, &b, &a);
        colors[@intCast(count)] = (@as(u32, @intFromFloat(r * 255.0 + 0.5)) << 16) | (@as(u32, @intFromFloat(g * 255.0 + 0.5)) << 8) | @as(u32, @intFromFloat(b * 255.0 + 0.5));
        count += 1;
    }
    if (count == 0) return raven.R_INVALID_ID;
    return widget_h.rvn_wallpaper_create_colors(colors[0], &colors[1], count - 1);
}

// A color or a metric named by an attribute, into a style. R_FALSE when the name is neither.
fn rvn_theme_read_value(reader: [*c]rvn_theme_reader_t, node: [*c]const xml_h.rvn_xml_node_t, style: [*c]ctx_h.rvn_style_t, name: [*c]const u8, value: [*c]const u8, colors: c_int, metrics: c_int) c_int {
    var role: raven.RColorRole = undefined;
    var metric: raven.RMetric = undefined;
    if (colors != 0 and widget_h.rvn_color_role_by_name(name, &role) != 0) {
        var color: base.rvn_color_t = undefined;
        if (widget_h.rvn_parse_color(value, &color) == 0) {
            rvn_theme_problem(reader, node, "'%s' is not a color (%s)", value, name);
            return raven.R_TRUE;
        }
        style.*.colors[@intCast(RVN_COLOR_INDEX(role))] = color;
        style.*.color_mask |= @as(u64, 1) << @intCast(RVN_COLOR_INDEX(role));
        return raven.R_TRUE;
    }
    if (metrics != 0 and widget_h.rvn_metric_by_name(name, &metric) != 0) {
        var number: f32 = undefined;
        if (widget_h.rvn_parse_float(value, &number) == 0) {
            rvn_theme_problem(reader, node, "'%s' is not a number (%s)", value, name);
            return raven.R_TRUE;
        }
        style.*.metrics[@intCast(RVN_METRIC_INDEX(metric))] = number;
        style.*.metric_mask |= @as(u32, 1) << @intCast(RVN_METRIC_INDEX(metric));
        return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

// The values of a style written straight into the theme.
fn rvn_theme_take(theme: [*c]ctx_h.rvn_theme_t, style: [*c]const ctx_h.rvn_style_t) void {
    var i: c_int = 0;
    while (i < raven.R_COLOR_COUNT) : (i += 1) {
        if ((style.*.color_mask & (@as(u64, 1) << @intCast(i))) != 0) theme.*.colors[@intCast(i)] = style.*.colors[@intCast(i)];
    }
    i = 0;
    while (i < raven.R_METRIC_COUNT) : (i += 1) {
        if ((style.*.metric_mask & (@as(u32, 1) << @intCast(i))) != 0) theme.*.metrics[@intCast(i)] = style.*.metrics[@intCast(i)];
    }
}

fn rvn_theme_read_style(reader: [*c]rvn_theme_reader_t, node: [*c]const xml_h.rvn_xml_node_t) void {
    const widget = xml_h.rvn_xml_attribute(node, "Widget");
    const cls = xml_h.rvn_xml_attribute(node, "Class");
    var attribute: [*c]const xml_h.rvn_xml_attribute_t = undefined;
    if (widget != null and widget[0] != 0 and widget_h.rvn_widget_class_by_name(widget) == null) {
        rvn_theme_problem(reader, node, "<Style Widget=\"%s\">: no widget has that name%s", widget, "");
        return;
    }
    const rule = rvn_theme_rule(reader.*.theme, widget, cls, "theme");
    if (rule == null) return;
    attribute = node.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        if (base.rvn_stricmp(attribute.*.name, "Widget") == 0 or base.rvn_stricmp(attribute.*.name, "Class") == 0) continue;
        if (base.rvn_stricmp(attribute.*.name, "Material") == 0) {
            var material: raven.RMaterial = undefined;
            if (widget_h.rvn_parse_material(attribute.*.value, &material) == 0) {
                rvn_theme_problem(reader, node, "'%s' is not a material%s", attribute.*.value, "");
            } else {
                rule.*.material = if (material == raven.R_MATERIAL_DEFAULT) 0 else material;
            }
            continue;
        }
        if (rvn_theme_read_value(reader, node, &rule.*.style, attribute.*.name, attribute.*.value, raven.R_TRUE, raven.R_TRUE) == 0) {
            rvn_theme_problem(reader, node, "<Style>: '%s' is neither a color nor a metric%s", attribute.*.name, "");
        }
    }
}

fn rvn_theme_read_glass(reader: [*c]rvn_theme_reader_t, node: [*c]const xml_h.rvn_xml_node_t) void {
    const names = [_]struct { name: [*c]const u8, metric: raven.RMetric }{
        .{ .name = "Frost", .metric = raven.R_METRIC_GLASS_FROST },
        .{ .name = "Refraction", .metric = raven.R_METRIC_GLASS_REFRACTION },
        .{ .name = "Saturation", .metric = raven.R_METRIC_GLASS_SATURATION },
        .{ .name = "Rim", .metric = raven.R_METRIC_GLASS_RIM },
        .{ .name = "Shadow", .metric = raven.R_METRIC_GLASS_SHADOW },
    };
    var attribute: [*c]const xml_h.rvn_xml_attribute_t = node.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        var i: usize = 0;
        var number: f32 = undefined;
        while (i < names.len) : (i += 1) {
            if (base.rvn_stricmp(names[i].name, attribute.*.name) == 0) break;
        }
        if (i == names.len) {
            rvn_theme_problem(reader, node, "<Glass>: unknown attribute '%s'%s", attribute.*.name, "");
        } else if (widget_h.rvn_parse_float(attribute.*.value, &number) == 0) {
            rvn_theme_problem(reader, node, "'%s' is not a number (%s)", attribute.*.value, attribute.*.name);
        } else {
            reader.*.theme.*.metrics[@intCast(RVN_METRIC_INDEX(names[i].metric))] = number;
        }
    }
}

fn rvn_theme_read_syntax(reader: [*c]rvn_theme_reader_t, node: [*c]const xml_h.rvn_xml_node_t) void {
    var attribute: [*c]const xml_h.rvn_xml_attribute_t = node.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        var token: common_h.rvn_token_t = undefined;
        var color: base.rvn_color_t = undefined;
        if (rvn_token_by_name(attribute.*.name, &token) == 0) {
            rvn_theme_problem(reader, node, "<Syntax>: unknown kind of token '%s'%s", attribute.*.name, "");
        } else if (widget_h.rvn_parse_color(attribute.*.value, &color) == 0) {
            rvn_theme_problem(reader, node, "'%s' is not a color (%s)", attribute.*.value, attribute.*.name);
        } else {
            reader.*.theme.*.tokens[token] = color;
            reader.*.theme.*.token_mask |= @as(u32, 1) << @intCast(token);
        }
    }
}

// Fills `theme` (zeroed) from the text of a theme file. `path` is the file
// it comes from, or NULL. Returns R_FALSE after reporting the error.
fn rvn_theme_read(theme: [*c]ctx_h.rvn_theme_t, text: [*c]const u8, size: usize, path: [*c]const u8) c_int {
    var document: xml_h.rvn_xml_document_t = undefined;
    var reader: rvn_theme_reader_t = undefined;
    var root: [*c]const xml_h.rvn_xml_node_t = undefined;
    var child: [*c]const xml_h.rvn_xml_node_t = undefined;
    var attribute: [*c]const xml_h.rvn_xml_attribute_t = undefined;
    var value: [*c]const u8 = undefined;
    var direct: ctx_h.rvn_style_t = undefined;
    var accent: base.rvn_color_t = undefined;
    var has_accent: c_int = raven.R_FALSE;
    var has_dark: c_int = raven.R_FALSE;
    var flag: c_int = undefined;
    var previous_dir: [*c]u8 = null;

    reader.theme = theme;
    reader.source = if (path != null) path else "(memory)";
    reader.problems = 0;
    if (xml_h.rvn_xml_parse(&document, text, size) == 0) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "theme %s:%d:%d: %s", reader.source, document.error_line, document.error_column, @as([*c]const u8, &document.@"error"));
        xml_h.rvn_xml_free(&document);
        return raven.R_FALSE;
    }
    root = document.root;
    if (root == null or base.rvn_stricmp(root.*.name, "Theme") != 0) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "theme %s: the root element must be <Theme>", reader.source);
        xml_h.rvn_xml_free(&document);
        return raven.R_FALSE;
    }

    // what it starts from
    value = xml_h.rvn_xml_attribute(root, "Base");
    {
        const start_name: [*c]const u8 = if (value != null and value[0] != 0) value else "Dark";
        var base_: [*c]ctx_h.rvn_theme_t = rvn_theme_find(start_name);
        if (base_ == null) {
            rvn_theme_problem(&reader, root, "Base=\"%s\": no theme has that name; starting from Dark%s", value, "");
            base_ = rvn_theme_find("Dark");
        }
        rvn_theme_copy(theme, base_);
        theme.*.font = raven.R_INVALID_ID;
    }

    // (fonts and images named in the file are looked for next to it)
    if (path != null) xml_h.rvn_xml_push_file_dir(path, &previous_dir);
    direct = std.mem.zeroes(ctx_h.rvn_style_t);
    attribute = root.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        const name = attribute.*.name;
        value = attribute.*.value;
        if (base.rvn_stricmp(name, "Name") == 0 or base.rvn_stricmp(name, "Base") == 0) {
            continue;
        } else if (base.rvn_stricmp(name, "Material") == 0) {
            var material: raven.RMaterial = undefined;
            if (widget_h.rvn_parse_material(value, &material) == 0 or material == raven.R_MATERIAL_DEFAULT) {
                rvn_theme_problem(&reader, root, "'%s' is not a material%s", value, "");
            } else {
                theme.*.material = material;
                theme.*.glass = @intFromBool(material != raven.R_MATERIAL_SOLID);
            }
        } else if (base.rvn_stricmp(name, "Dark") == 0) {
            if (widget_h.rvn_parse_bool(value, &flag) == 0) {
                rvn_theme_problem(&reader, root, "Dark=\"%s\": expected true or false%s", value, "");
            } else {
                theme.*.dark = flag;
                has_dark = raven.R_TRUE;
            }
        } else if (base.rvn_stricmp(name, "Accent") == 0) {
            if (widget_h.rvn_parse_color(value, &accent) == 0) {
                rvn_theme_problem(&reader, root, "'%s' is not a color (Accent)%s", value, "");
            } else {
                has_accent = raven.R_TRUE;
            }
        } else if (base.rvn_stricmp(name, "Font") == 0) {
            theme.*.font = common_h.rvn_xml_font(value);
            if (theme.*.font == raven.R_INVALID_ID) rvn_theme_problem(&reader, root, "Font=\"%s\": cannot load this font%s", value, "");
        } else if (base.rvn_stricmp(name, "Wallpaper") == 0) {
            if (base.rvn_stricmp(value, "None") == 0 or value[0] == 0) {
                theme.*.wallpaper = raven.R_INVALID_ID;
            } else if (base.rvn_stricmp(value, "Dark") == 0) {
                theme.*.wallpaper = widget_h.rvn_theme_builtin_wallpaper(raven.R_TRUE);
            } else if (base.rvn_stricmp(value, "Light") == 0) {
                theme.*.wallpaper = widget_h.rvn_theme_builtin_wallpaper(raven.R_FALSE);
            } else if (value[0] == '#') {
                theme.*.wallpaper = rvn_theme_wallpaper_from_colors(value);
                if (theme.*.wallpaper == raven.R_INVALID_ID) rvn_theme_problem(&reader, root, "Wallpaper=\"%s\": expected colors separated by commas%s", value, "");
            } else {
                theme.*.wallpaper = common_h.rvn_xml_texture(value);
                if (theme.*.wallpaper == raven.R_INVALID_ID) rvn_theme_problem(&reader, root, "Wallpaper=\"%s\": cannot load this image%s", value, "");
            }
        } else if (rvn_theme_read_value(&reader, root, &direct, name, value, raven.R_TRUE, raven.R_TRUE) == 0) {
            rvn_theme_problem(&reader, root, "<Theme>: unknown attribute '%s'%s", name, "");
        }
    }
    if (path != null) xml_h.rvn_xml_pop_file_dir(previous_dir);

    // the accent first: a shade given by the file replaces the one worked out from it
    if (has_accent != 0) rvn_theme_set_accent(theme, accent);
    rvn_theme_take(theme, &direct);

    child = root.*.first_child;
    while (child != null) : (child = child.*.next) {
        if (base.rvn_stricmp(child.*.name, "Colors") == 0 or base.rvn_stricmp(child.*.name, "Metrics") == 0) {
            const colors: c_int = @intFromBool(base.rvn_stricmp(child.*.name, "Colors") == 0);
            direct = std.mem.zeroes(ctx_h.rvn_style_t);
            attribute = child.*.attributes;
            while (attribute != null) : (attribute = attribute.*.next) {
                if (rvn_theme_read_value(&reader, child, &direct, attribute.*.name, attribute.*.value, colors, @intFromBool(colors == 0)) == 0) {
                    const format: [*c]const u8 = if (colors != 0) "<Colors>: '%s' is not a color role%s" else "<Metrics>: '%s' is not a metric%s";
                    rvn_theme_problem(&reader, child, format, attribute.*.name, "");
                }
            }
            rvn_theme_take(theme, &direct);
        } else if (base.rvn_stricmp(child.*.name, "Glass") == 0) {
            rvn_theme_read_glass(&reader, child);
        } else if (base.rvn_stricmp(child.*.name, "Syntax") == 0) {
            rvn_theme_read_syntax(&reader, child);
        } else if (base.rvn_stricmp(child.*.name, "Style") == 0) {
            rvn_theme_read_style(&reader, child);
        } else {
            rvn_theme_problem(&reader, child, "unknown element <%s>%s", child.*.name, "");
        }
    }
    // dark or light: said by the file, else read from the color of the text
    if (has_dark == 0 and xml_h.rvn_xml_attribute(root, "Base") == null) {
        theme.*.dark = @intFromBool(rvn_color_luminance(theme.*.colors[@intCast(RVN_COLOR_INDEX(raven.R_COLOR_TEXT))]) > 0.5);
    }

    value = xml_h.rvn_xml_attribute(root, "Name");
    if (value != null and value[0] != 0) {
        _ = base.rvn_str_set(&theme.*.name, value);
    } else if (path != null) {
        // the name of the file without its folder and its extension
        var start: [*c]const u8 = path;
        var walk: [*c]const u8 = path;
        var dot: [*c]const u8 = null;
        while (walk[0] != 0) : (walk += 1) {
            if (walk[0] == '/' or walk[0] == '\\') start = walk + 1;
        }
        walk = start;
        while (walk[0] != 0) : (walk += 1) {
            if (walk[0] == '.') dot = walk;
        }
        base.rvn_free(theme.*.name);
        const length: usize = if (dot != null and dot > start) @intCast(dot - start) else libc.strlen(start);
        theme.*.name = base.rvn_strndup(start, length);
    } else {
        _ = base.rvn_str_set(&theme.*.name, "Theme");
    }
    xml_h.rvn_xml_free(&document);
    return raven.R_TRUE;
}

// Puts a theme that was just read among the named ones, in place of the one of the same name.
fn rvn_theme_install(loaded: [*c]ctx_h.rvn_theme_t, path: [*c]const u8) [*c]ctx_h.rvn_theme_t {
    var theme: [*c]ctx_h.rvn_theme_t = null;
    var i: u32 = 0;
    var k: usize = 0;
    while (k < g_builtin_themes.len) : (k += 1) {
        if (base.rvn_stricmp(g_builtin_themes[k].name, loaded.*.name) == 0) {
            base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "theme: '%s' is the name of a built-in theme; give the theme another Name", loaded.*.name);
            rvn_theme_clear(loaded);
            return null;
        }
    }
    while (i < ctx_h.g_rvn.theme_count and theme == null) : (i += 1) {
        if (base.rvn_stricmp(ctx_h.g_rvn.themes[i].*.name, loaded.*.name) == 0) {
            theme = ctx_h.g_rvn.themes[i];
        } else if (path != null and ctx_h.g_rvn.themes[i].*.path != null and libc.strcmp(ctx_h.g_rvn.themes[i].*.path, path) == 0) {
            theme = ctx_h.g_rvn.themes[i];
        }
    }
    if (theme == null) theme = rvn_theme_add(loaded.*.name);
    // (the address stays: widgets may point to it)
    rvn_theme_copy(theme, loaded);
    _ = base.rvn_str_set(&theme.*.name, loaded.*.name);
    _ = base.rvn_str_set(&theme.*.path, path);
    rvn_theme_clear(loaded);

    // the theme in use is a copy of it: it follows
    if (ctx_h.g_rvn.theme_name != null and base.rvn_stricmp(ctx_h.g_rvn.theme_name, theme.*.name) == 0) {
        const font = ctx_h.g_rvn.theme.font;
        rvn_theme_copy(&ctx_h.g_rvn.theme, theme);
        if (ctx_h.g_rvn.theme.font == raven.R_INVALID_ID) ctx_h.g_rvn.theme.font = font;
    }
    rvn_theme_changed();
    return theme;
}

fn rvn_theme_load_file(path: [*c]const u8) [*c]ctx_h.rvn_theme_t {
    var loaded: ctx_h.rvn_theme_t = undefined;
    var size: usize = 0;
    const text = base.rvn_read_file(path, &size);
    if (text == null) {
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "theme: cannot read '%s'", path);
        return null;
    }
    loaded = std.mem.zeroes(ctx_h.rvn_theme_t);
    const ok = rvn_theme_read(&loaded, text, size, path);
    base.rvn_free(text);
    if (ok == 0) {
        rvn_theme_clear(&loaded);
        return null;
    }
    return rvn_theme_install(&loaded, path);
}

fn rvn_theme_watch(path: [*c]const u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = user;
    // a file caught half written: quietly tried again before saying anything
    if (xml_watch_h.rvn_watch_quiet() != 0) {
        var document: xml_h.rvn_xml_document_t = undefined;
        var size: usize = 0;
        const text = base.rvn_read_file(path, &size);
        var parsed: c_int = undefined;
        if (text == null) return raven.R_FALSE;
        parsed = xml_h.rvn_xml_parse(&document, text, size);
        xml_h.rvn_xml_free(&document);
        base.rvn_free(text);
        if (parsed == 0) return raven.R_FALSE;
    }
    _ = rvn_theme_load_file(path);
    return raven.R_TRUE;
}

export fn rvn_xml_theme(value: [*c]const u8) [*c]const ctx_h.rvn_theme_t {
    var theme = rvn_theme_find(value);
    var path: [*c]u8 = undefined;
    var i: u32 = 0;
    if (theme != null) return theme;
    if (libc.strchr(value, '.') == null and libc.strchr(value, '/') == null and libc.strchr(value, '\\') == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Theme=\"%s\": no theme has that name", value);
        return null;
    }
    // a theme file, named from the document that uses it
    path = xml_h.rvn_xml_resolve_path(value);
    while (i < ctx_h.g_rvn.theme_count) : (i += 1) {
        if (ctx_h.g_rvn.themes[i].*.path != null and libc.strcmp(ctx_h.g_rvn.themes[i].*.path, path) == 0) {
            base.rvn_free(path);
            return ctx_h.g_rvn.themes[i];
        }
    }
    theme = rvn_theme_load_file(path);
    if (theme != null) xml_watch_h.rvn_watch_add(path, rvn_theme_watch, null);
    base.rvn_free(path);
    return theme;
}

// ---------------------------------------------------------------------------
//  Writing a theme
// ---------------------------------------------------------------------------

fn rvn_theme_write_color(out: [*c]base.rvn_text_t, name: [*c]const u8, color: base.rvn_color_t) void {
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    base.rvn_color_to_floats(color, &r, &g, &b, &a);
    base.rvn_text_printf(out, " %s=\"#%02X%02X%02X", name, @as(c_uint, @intFromFloat(r * 255.0 + 0.5)), @as(c_uint, @intFromFloat(g * 255.0 + 0.5)), @as(c_uint, @intFromFloat(b * 255.0 + 0.5)));
    if (a < 0.998) base.rvn_text_printf(out, "%02X", @as(c_uint, @intFromFloat(a * 255.0 + 0.5)));
    base.rvn_text_add(out, "\"");
}

fn rvn_theme_write_style(out: [*c]base.rvn_text_t, style: [*c]const ctx_h.rvn_style_t, colors: c_int, metrics: c_int, indent: [*c]const u8) void {
    var i: c_int = 0;
    var column: c_int = 0;
    while (i < raven.R_COLOR_COUNT and colors != 0) : (i += 1) {
        const name = widget_h.rvn_color_role_name(@as(raven.RColorRole, @bitCast(raven.R_COLOR_WINDOW + i)));
        if (name == null or (style.*.color_mask & (@as(u64, 1) << @intCast(i))) == 0) continue;
        if (indent != null) {
            const column_before = column;
            column += 1;
            if (@rem(column_before, 4) == 0) base.rvn_text_printf(out, "\n%s", indent);
        }
        rvn_theme_write_color(out, name, style.*.colors[@intCast(i)]);
    }
    i = 0;
    while (i < raven.R_METRIC_COUNT and metrics != 0) : (i += 1) {
        const name = widget_h.rvn_metric_name(@as(raven.RMetric, @bitCast(raven.R_METRIC_FONT_SIZE + i)));
        if (name == null or (style.*.metric_mask & (@as(u32, 1) << @intCast(i))) == 0) continue;
        if (indent != null) {
            const column_before = column;
            column += 1;
            if (@rem(column_before, 4) == 0) base.rvn_text_printf(out, "\n%s", indent);
        }
        base.rvn_text_printf(out, " %s=\"%g\"", name, @as(f64, style.*.metrics[@intCast(i)]));
    }
}

fn rvn_material_name(material: raven.RMaterial) [*c]const u8 {
    switch (material) {
        raven.R_MATERIAL_GLASS => return "Glass",
        raven.R_MATERIAL_FROSTED_GLASS => return "FrostedGlass",
        raven.R_MATERIAL_TINTED_GLASS => return "TintedGlass",
        else => return "Solid",
    }
}

fn rvn_theme_write(theme: [*c]const ctx_h.rvn_theme_t, name: [*c]const u8, out: [*c]base.rvn_text_t) void {
    var all: ctx_h.rvn_style_t = undefined;
    var i: u32 = 0;
    var k: usize = 0;
    const base_: [*c]const u8 = if (theme.*.glass != 0)
        (if (theme.*.dark != 0) "GlassDark" else "GlassLight")
    else
        (if (theme.*.dark != 0) "Dark" else "Light");
    const dark_text: [*c]const u8 = if (theme.*.dark != 0) "true" else "false";

    base.rvn_text_printf(out, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Theme Name=\"%s\" Base=\"%s\" Material=\"%s\" Dark=\"%s\"", name, base_, rvn_material_name(theme.*.material), dark_text);
    if (theme.*.glass != 0 and theme.*.wallpaper == raven.R_INVALID_ID) base.rvn_text_add(out, " Wallpaper=\"None\"");
    base.rvn_text_add(out, ">\n");

    all = std.mem.zeroes(ctx_h.rvn_style_t);
    @memcpy(&all.colors, &theme.*.colors);
    @memcpy(&all.metrics, &theme.*.metrics);
    all.color_mask = ~@as(u64, 0);
    all.metric_mask = ~@as(u32, 0);
    base.rvn_text_add(out, "\t<Colors");
    rvn_theme_write_style(out, &all, raven.R_TRUE, raven.R_FALSE, "\t\t");
    base.rvn_text_add(out, "/>\n\t<Metrics");
    rvn_theme_write_style(out, &all, raven.R_FALSE, raven.R_TRUE, "\t\t");
    base.rvn_text_add(out, "/>\n");

    if (theme.*.token_mask != 0) {
        base.rvn_text_add(out, "\t<Syntax");
        while (k < g_token_names.len) : (k += 1) {
            if ((theme.*.token_mask & (@as(u32, 1) << @intCast(g_token_names[k].token))) != 0) rvn_theme_write_color(out, g_token_names[k].name, theme.*.tokens[g_token_names[k].token]);
        }
        base.rvn_text_add(out, "/>\n");
    }
    while (i < theme.*.rule_count) : (i += 1) {
        const rule: [*c]const ctx_h.rvn_style_rule_t = &theme.*.rules[i];
        const cls = if (rule.*.type != 0) widget_h.rvn_widget_class_by_type(@as(raven.RWidgetType, @bitCast(rule.*.type))) else null;
        if (rule.*.style.color_mask == 0 and rule.*.style.metric_mask == 0 and rule.*.material == 0) continue;
        base.rvn_text_add(out, "\t<Style");
        if (cls != null) base.rvn_text_printf(out, " Widget=\"%s\"", cls.*.name);
        if (rule.*.cls != null) base.rvn_text_printf(out, " Class=\"%s\"", rule.*.cls);
        if (rule.*.material != 0) base.rvn_text_printf(out, " Material=\"%s\"", rvn_material_name(rule.*.material));
        rvn_theme_write_style(out, &rule.*.style, raven.R_TRUE, raven.R_TRUE, null);
        base.rvn_text_add(out, "/>\n");
    }
    base.rvn_text_add(out, "</Theme>\n");
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rtheme_set_accent(r: f32, g: f32, b: f32) void {
    if (ctx_h.rvn_api_check("Rtheme_set_accent") == 0) return;
    rvn_theme_set_accent(&ctx_h.g_rvn.theme, base.rvn_rgba(r, g, b, 1.0));
    rvn_theme_changed();
}

export fn Rtheme_set_dark(dark: c_int) void {
    if (ctx_h.rvn_api_check("Rtheme_set_dark") == 0) return;
    ctx_h.g_rvn.theme.dark = @intFromBool(dark != 0);
    rvn_theme_changed();
}

export fn Rtheme_is_dark() c_int {
    return if (ctx_h.g_rvn.initialized != 0) ctx_h.g_rvn.theme.dark else raven.R_FALSE;
}

export fn Rtheme_set_wallpaper(texture: raven.Rid) void {
    if (ctx_h.rvn_api_check("Rtheme_set_wallpaper") == 0) return;
    if (texture != raven.R_INVALID_ID and renderer_h.rvn_texture_get(texture) == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rtheme_set_wallpaper: invalid texture");
        return;
    }
    ctx_h.g_rvn.theme.wallpaper = texture;
    ctx_h.rvn_repaint_all_windows();
}

export fn Rtheme_get_wallpaper() raven.Rid {
    return if (ctx_h.g_rvn.initialized != 0) ctx_h.g_rvn.theme.wallpaper else raven.R_INVALID_ID;
}

export fn Rtheme_set_style_color(widget: [*c]const u8, style_class: [*c]const u8, role: raven.RColorRole, r: f32, g: f32, b: f32, a: f32) void {
    if (ctx_h.rvn_api_check("Rtheme_set_style_color") == 0) return;
    if (role < raven.R_COLOR_WINDOW or role >= raven.R_COLOR_LAST_) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtheme_set_style_color: invalid color role");
        return;
    }
    const rule = rvn_theme_rule(&ctx_h.g_rvn.theme, widget, style_class, "Rtheme_set_style_color");
    if (rule == null) return;
    rule.*.style.colors[@intCast(RVN_COLOR_INDEX(role))] = base.rvn_rgba(r, g, b, a);
    rule.*.style.color_mask |= @as(u64, 1) << @intCast(RVN_COLOR_INDEX(role));
    rvn_theme_changed();
}

export fn Rtheme_set_style_metric(widget: [*c]const u8, style_class: [*c]const u8, metric: raven.RMetric, value: f32) void {
    if (ctx_h.rvn_api_check("Rtheme_set_style_metric") == 0) return;
    if (metric < raven.R_METRIC_FONT_SIZE or metric >= raven.R_METRIC_LAST_) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtheme_set_style_metric: invalid metric");
        return;
    }
    const rule = rvn_theme_rule(&ctx_h.g_rvn.theme, widget, style_class, "Rtheme_set_style_metric");
    if (rule == null) return;
    rule.*.style.metrics[@intCast(RVN_METRIC_INDEX(metric))] = value;
    rule.*.style.metric_mask |= @as(u32, 1) << @intCast(RVN_METRIC_INDEX(metric));
    rvn_theme_changed();
}

export fn Rtheme_set_style_material(widget: [*c]const u8, style_class: [*c]const u8, material: raven.RMaterial) void {
    if (ctx_h.rvn_api_check("Rtheme_set_style_material") == 0) return;
    if (material < raven.R_MATERIAL_SOLID or material > raven.R_MATERIAL_DEFAULT) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtheme_set_style_material: invalid material");
        return;
    }
    const rule = rvn_theme_rule(&ctx_h.g_rvn.theme, widget, style_class, "Rtheme_set_style_material");
    if (rule == null) return;
    rule.*.material = if (material == raven.R_MATERIAL_DEFAULT) 0 else material;
    rvn_theme_changed();
}

export fn Rtheme_clear_styles() void {
    if (ctx_h.rvn_api_check("Rtheme_clear_styles") == 0) return;
    thread_h.rvn_mutex_lock(&ctx_h.g_rvn.style_mutex);
    rvn_theme_free_rules(&ctx_h.g_rvn.theme);
    thread_h.rvn_mutex_unlock(&ctx_h.g_rvn.style_mutex);
    rvn_theme_changed();
}

export fn Rtheme_load(path: [*c]const u8) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rtheme_load") == 0) return null;
    if (path == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtheme_load: NULL path");
        return null;
    }
    const theme = rvn_theme_load_file(path);
    if (theme == null) return null;
    xml_watch_h.rvn_watch_add(path, rvn_theme_watch, null);
    return theme.*.name;
}

export fn Rtheme_load_from_memory(xml: [*c]const u8, size: usize) [*c]const u8 {
    var loaded: ctx_h.rvn_theme_t = undefined;
    if (ctx_h.rvn_api_check("Rtheme_load_from_memory") == 0) return null;
    if (xml == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtheme_load_from_memory: NULL text");
        return null;
    }
    loaded = std.mem.zeroes(ctx_h.rvn_theme_t);
    if (rvn_theme_read(&loaded, xml, if (size != 0) size else libc.strlen(xml), null) == 0) {
        rvn_theme_clear(&loaded);
        return null;
    }
    const theme = rvn_theme_install(&loaded, null);
    return if (theme != null) theme.*.name else null;
}

export fn Rtheme_use(name: [*c]const u8) c_int {
    if (ctx_h.rvn_api_check("Rtheme_use") == 0) return raven.R_FALSE;
    const theme = rvn_theme_find(name);
    if (theme == null) {
        const name_text: [*c]const u8 = if (name != null) name else "(null)";
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtheme_use: no theme is called '%s'", name_text);
        return raven.R_FALSE;
    }
    const font = ctx_h.g_rvn.theme.font;
    rvn_theme_copy(&ctx_h.g_rvn.theme, theme);
    // a theme that names no font keeps the one in use
    if (ctx_h.g_rvn.theme.font == raven.R_INVALID_ID or handle_h.rvn_pool_get(&ctx_h.g_rvn.fonts, ctx_h.g_rvn.theme.font) == null) ctx_h.g_rvn.theme.font = font;
    _ = base.rvn_str_set(&ctx_h.g_rvn.theme_name, theme.*.name);
    rvn_theme_changed();
    return raven.R_TRUE;
}

export fn Rtheme_get_name() [*c]const u8 {
    return if (ctx_h.g_rvn.initialized != 0 and ctx_h.g_rvn.theme_name != null) ctx_h.g_rvn.theme_name else "";
}

export fn Rtheme_get_count() c_int {
    if (ctx_h.rvn_api_check("Rtheme_get_count") == 0) return 0;
    rvn_theme_builtins();
    return @as(c_int, @bitCast(ctx_h.g_rvn.theme_count));
}

export fn Rtheme_get_name_at(index: c_int) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rtheme_get_name_at") == 0) return null;
    rvn_theme_builtins();
    if (index < 0 or index >= @as(c_int, @bitCast(ctx_h.g_rvn.theme_count))) return null;
    return ctx_h.g_rvn.themes[@intCast(index)].*.name;
}

export fn Rtheme_save(path: [*c]const u8, name: [*c]const u8) c_int {
    var out: base.rvn_text_t = undefined;
    var ok: c_int = undefined;
    if (ctx_h.rvn_api_check("Rtheme_save") == 0) return raven.R_FALSE;
    if (path == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtheme_save: NULL path");
        return raven.R_FALSE;
    }
    out = std.mem.zeroes(base.rvn_text_t);
    const theme_name: [*c]const u8 = if (ctx_h.g_rvn.theme_name != null) ctx_h.g_rvn.theme_name else "Theme";
    rvn_theme_write(&ctx_h.g_rvn.theme, if (name != null and name[0] != 0) name else theme_name, &out);
    ok = raven.Rfile_write(path, out.data, out.length);
    base.rvn_free(out.data);
    return ok;
}

// ---- widgets ----

fn rvn_widget_classes_changed(widget: [*c]widget_h.rvn_widget_t) void {
    widget.*.style_generation = 0;
    widget_h.rvn_widget_invalidate_layout(widget);
}

export fn Rwidget_set_class(id: raven.Rid, classes: [*c]const u8) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_class");
    if (widget == null) return;
    if (base.rvn_str_set(&widget.*.classes, if (classes != null and classes[0] != 0) classes else null) != 0) rvn_widget_classes_changed(widget);
}

export fn Rwidget_get_class(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_class");
    if (widget == null) return "";
    return if (widget.*.classes != null) widget.*.classes else "";
}

fn rvn_class_name_ok(cls: [*c]const u8, function: [*c]const u8) c_int {
    if (cls == null or cls[0] == 0 or libc.strchr(cls, ' ') != null or libc.strchr(cls, '\t') != null or libc.strchr(cls, ',') != null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "%s: a class is one word", function);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn Rwidget_add_class(id: raven.Rid, style_class: [*c]const u8) void {
    var text: base.rvn_text_t = undefined;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_add_class");
    if (widget == null) return;
    if (rvn_class_name_ok(style_class, "Rwidget_add_class") == 0 or rvn_classes_have(widget.*.classes, style_class) != 0) return;
    text = std.mem.zeroes(base.rvn_text_t);
    if (widget.*.classes != null) {
        base.rvn_text_add(&text, widget.*.classes);
        base.rvn_text_add(&text, " ");
    }
    base.rvn_text_add(&text, style_class);
    base.rvn_free(widget.*.classes);
    widget.*.classes = text.data;
    rvn_widget_classes_changed(widget);
}

export fn Rwidget_remove_class(id: raven.Rid, style_class: [*c]const u8) void {
    var text: base.rvn_text_t = undefined;
    var walk: [*c]const u8 = undefined;
    var length: usize = undefined;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_remove_class");
    if (widget == null) return;
    if (rvn_class_name_ok(style_class, "Rwidget_remove_class") == 0 or rvn_classes_have(widget.*.classes, style_class) == 0) return;
    text = std.mem.zeroes(base.rvn_text_t);
    length = libc.strlen(style_class);
    walk = widget.*.classes;
    while (walk[0] != 0) {
        while (walk[0] == ' ' or walk[0] == '\t' or walk[0] == ',') walk += 1;
        const start = walk;
        while (walk[0] != 0 and walk[0] != ' ' and walk[0] != '\t' and walk[0] != ',') walk += 1;
        if (walk == start) break;
        if (@as(usize, @intCast(walk - start)) == length and libc.memcmp(start, style_class, length) == 0) continue;
        if (text.length != 0) base.rvn_text_add(&text, " ");
        base.rvn_text_append(&text, start, @as(usize, @intCast(walk - start)));
    }
    base.rvn_free(widget.*.classes);
    widget.*.classes = text.data;
    rvn_widget_classes_changed(widget);
}

export fn Rwidget_has_class(id: raven.Rid, style_class: [*c]const u8) c_int {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_has_class");
    if (widget == null) return raven.R_FALSE;
    return rvn_classes_have(widget.*.classes, style_class);
}

export fn Rwidget_set_theme(id: raven.Rid, name: [*c]const u8) c_int {
    var theme: [*c]const ctx_h.rvn_theme_t = null;
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_set_theme");
    if (widget == null) return raven.R_FALSE;
    if (name != null and name[0] != 0) {
        theme = rvn_theme_find(name);
        if (theme == null) {
            base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rwidget_set_theme: no theme is called '%s'", name);
            return raven.R_FALSE;
        }
    }
    rvn_widget_set_theme(widget, theme, @intFromBool(theme != null));
    return raven.R_TRUE;
}

export fn Rwidget_get_theme(id: raven.Rid) [*c]const u8 {
    const widget = widget_h.rvn_widget_check(id, 0, "Rwidget_get_theme");
    if (widget == null) return "";
    if (widget.*.theme != null and widget.*.theme.*.name != null) return widget.*.theme.*.name;
    return if (ctx_h.g_rvn.theme_name != null) ctx_h.g_rvn.theme_name else "";
}
