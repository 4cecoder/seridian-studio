// Translated to Zig from vendor/raven/src/core/context.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/context.h
// Global state of the library. Like HRL, Raven has one implicit context.
//
// Not translated: RVN_API_GUARD / RVN_API_GUARD_VOID (they use __func__): write
//     if (ctx.rvn_api_check("Rfunction_name") == 0) return result;
// with the literal name of the function being translated.
// `platform` is typed ?*const anyopaque because platform/platform_h.zig (rvn_platform_t) belongs to the platform
// module; cast it there with @ptrCast(@alignCast(...)).

const raven = @import("raven");
const thread = @import("thread_h.zig");
const handle = @import("handle_h.zig");
const base = @import("base_h.zig");

/// Values that replace the ones of the theme: for one widget, or for the widgets a style is made for.
pub const rvn_style_t = extern struct {
    color_mask: u64,
    metric_mask: u32,
    colors: [raven.R_COLOR_COUNT]base.rvn_color_t,
    metrics: [raven.R_METRIC_COUNT]f32,
};
pub const struct_rvn_style_t = rvn_style_t;

/// A style of a theme: values for the widgets of a type and / or of a class.
pub const rvn_style_rule_t = extern struct {
    /// RWidgetType, or 0 for every type.
    type: c_int,
    /// One class, or NULL for the widgets of the type whatever their classes.
    cls: [*c]u8,
    style: rvn_style_t,
    /// 0 = not given.
    material: raven.RMaterial,
};
pub const struct_rvn_style_rule_t = rvn_style_rule_t;

/// What the styles of a theme give, all together, to the widgets of one type with one set of classes.
pub const rvn_style_match_t = extern struct {
    type: c_int,
    classes: [*c]u8,
    style: rvn_style_t,
    material: raven.RMaterial,
};
pub const struct_rvn_style_match_t = rvn_style_match_t;

/// Number of kinds of token of the text editor (rvn_token_t in widgets/common.h).
pub const RVN_THEME_TOKENS = 16;

pub const rvn_theme_t = extern struct {
    /// Name of a named theme; NULL for the theme in use (its name is g_rvn.theme_name).
    name: [*c]u8,
    /// File a named theme was read from, or NULL.
    path: [*c]u8,
    colors: [raven.R_COLOR_COUNT]base.rvn_color_t,
    metrics: [raven.R_METRIC_COUNT]f32,
    font: raven.Rid,
    /// Material of the widgets that have none of their own.
    material: raven.RMaterial,
    /// R_TRUE when that material is a glass.
    glass: c_int,
    /// Dark theme: glass is tinted accordingly.
    dark: c_int,
    /// Background drawn behind the content of windows, or R_INVALID_ID.
    wallpaper: raven.Rid,
    /// Colors of the code, for the kinds of token of `token_mask`; the others follow `dark`.
    tokens: [RVN_THEME_TOKENS]base.rvn_color_t,
    token_mask: u32,
    rules: [*c]rvn_style_rule_t,
    rule_count: u32,
    rule_cap: u32,
    /// Cache: what the rules give to each (type, classes) met so far. Emptied when a style changes.
    matches: [*c][*c]rvn_style_match_t,
    match_count: u32,
    match_cap: u32,
};
pub const struct_rvn_theme_t = rvn_theme_t;

pub const rvn_task_t = extern struct {
    function: raven.RTaskCallback,
    user_data: ?*anyopaque,
};
pub const struct_rvn_task_t = rvn_task_t;

pub const rvn_timer_t = extern struct {
    id: raven.Rid,
    interval: f64,
    deadline: f64,
    repeat: c_int,
    callback: raven.RTimerCallback,
    user_data: ?*anyopaque,
};
pub const struct_rvn_timer_t = rvn_timer_t;

pub const rvn_action_t = extern struct {
    name: [*c]u8,
    callback: raven.RActionCallback,
    user_data: ?*anyopaque,
};
pub const struct_rvn_action_t = rvn_action_t;

// struct rvn_window_t and struct rvn_widget_t are defined in the widget module: only pointers to them are held here,
// as ?*anyopaque ([*c] cannot point to an opaque type); cast with @ptrCast(@alignCast(...)).

pub const rvn_context_t = extern struct {
    initialized: c_int,
    ui_thread: u64,
    start_time: f64,
    ui_scale: f32,
    vsync: c_int,
    backend: raven.RBackend,
    platform: ?*const anyopaque, // const rvn_platform_t*

    windows: handle.rvn_pool_t,
    widgets: handle.rvn_pool_t,
    fonts: handle.rvn_pool_t,
    textures: handle.rvn_pool_t,
    shaders: handle.rvn_pool_t,
    timers: handle.rvn_pool_t,
    tree_items: handle.rvn_pool_t,
    xml_documents: handle.rvn_pool_t,
    xml_nodes: handle.rvn_pool_t,

    // main loop
    quit_requested: thread.rvn_atomic_t,
    exit_code: thread.rvn_atomic_t,
    /// Set by Rwindow_request_redraw when called from another thread.
    redraw_all: thread.rvn_atomic_t,
    had_window: c_int,
    in_update: c_int,
    /// While positive, the windows ignore the mouse and the keyboard (a dialog of the OS is open).
    input_blocked: c_int,
    last_update_time: f64,
    /// Seconds between the last two frames.
    delta_time: f64,
    frame_callback: raven.RFrameCallback,
    frame_user: ?*anyopaque,

    // tasks posted from other threads
    task_mutex: thread.rvn_mutex_t,
    tasks: [*c]rvn_task_t,
    task_count: u32,
    task_cap: u32,

    // actions
    actions: [*c]rvn_action_t,
    action_count: u32,
    action_cap: u32,
    default_action: raven.RActionCallback,
    default_action_user: ?*anyopaque,

    // Deferred destruction. While events are being dispatched, deleted
    // widgets and windows lose their handle at once but their memory is
    // released only when the dispatch is over, so the code that called the
    // application back can finish safely.
    dispatch_depth: c_int,
    dead_widgets: [*c]?*anyopaque, // struct rvn_widget_t**
    dead_widget_count: u32,
    dead_widget_cap: u32,
    dead_windows: [*c]?*anyopaque, // struct rvn_window_t**
    dead_window_count: u32,
    dead_window_cap: u32,

    // animations (widget/anim.c)
    animations_disabled: c_int,
    /// Multiplies the time of the animations; 0 = 1.
    animation_speed: f32,
    /// When positive, every frame advances the animations by this many seconds, whatever the clock says.
    animation_time_step: f64,

    /// The theme in use. Widgets given a theme of their own point to one of `themes` instead.
    theme: rvn_theme_t,
    theme_name: [*c]u8,
    /// Named themes (widget/theme.c). Their addresses never change.
    themes: [*c][*c]rvn_theme_t,
    theme_count: u32,
    theme_cap: u32,
    /// Changes each time a theme, a style or the classes of a widget may have
    /// changed what a widget reads: each widget then looks again for the
    /// styles that apply to it (rvn_widget_restyle).
    style_generation: u32,
    style_mutex: thread.rvn_mutex_t,
    /// The built-in wallpapers, created on first use: dark, light.
    wallpapers: [2]raven.Rid,
    default_font: raven.Rid,
    mono_font: raven.Rid,
    clipboard: [*c]u8,
    xml_base_path: [*c]u8,
};
pub const struct_rvn_context_t = rvn_context_t;

/// Defined by core/context.c (`export var g_rvn`).
pub extern var g_rvn: rvn_context_t;

pub inline fn RVN_THEME_COLOR(role: anytype) base.rvn_color_t {
    return g_rvn.theme.colors[@intCast(@as(c_int, @intCast(role)) - @as(c_int, raven.R_COLOR_WINDOW))];
}
pub inline fn RVN_THEME_METRIC(metric: anytype) f32 {
    return g_rvn.theme.metrics[@intCast(@as(c_int, @intCast(metric)) - @as(c_int, raven.R_METRIC_FONT_SIZE))];
}

/// Checks that the library is initialized and that the caller is the UI
/// thread; reports an error naming `function` otherwise.
pub extern fn rvn_api_check(function: [*c]const u8) c_int;

/// Calls the function bound to an action name (or the default handler).
pub extern fn rvn_fire_action(sender: raven.Rid, action: [*c]const u8) void;

/// Seconds until the next timer fires, or a negative value when there is none.
pub extern fn rvn_timers_next_delay() f64;

/// Brackets code that calls application callbacks (see dispatch_depth).
pub extern fn rvn_dispatch_begin() void;
pub extern fn rvn_dispatch_end() void;

/// Tasks, timers, frame callback, then layout and paint of the windows that changed (one frame).
pub extern fn rvn_update() void;

/// Wakes the event loop so that a frame is produced soon. Thread-safe.
pub extern fn rvn_wake() void;

/// Marks every widget for a new layout and every window for a new paint
/// (theme, font or texture size change). Implemented in widget/window.c.
pub extern fn rvn_invalidate_all_windows() void;
/// The theme changed from dark to light or back: the windows that are seen through tell the window system.
pub extern fn rvn_windows_theme_changed() void;
/// Marks every window for a new paint, keeping the layout. Implemented in widget/window.c.
pub extern fn rvn_repaint_all_windows() void;
