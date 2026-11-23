// Translated to Zig from vendor/raven/src/render/draw.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/draw.h
// Draw lists (flat arrays of instances + commands) and the painter used by
// widgets to fill them.
//
// Widgets draw in logical units relative to their own top-left corner; the
// painter converts to pixels, snaps to the pixel grid, applies clipping and
// opacity, and appends instances.
//
// Notes for translators:
//  - `struct rvn_window_t` (widget/window.h) is only forward declared by draw.h; the window pointers are
//    `?*anyopaque` (const: `?*const anyopaque`) here. Cast them to the window type in the widget module.
//  - The full `struct RPainter` is defined here (raven.RPainter is an opaque handle). Use `draw.RPainter`
//    in translated bodies; pass `@ptrCast(p)` to the public `raven.Rdraw_*` functions that take `?*raven.RPainter`.

const raven = @import("raven");
const base = @import("../core/base_h.zig");

// ---------------------------------------------------------------------------
//  Draw list
// ---------------------------------------------------------------------------

pub const rvn_drawlist_t = extern struct {
    instances: [*c]raven.RDrawInstance,
    instance_count: u32,
    instance_cap: u32,
    commands: [*c]raven.RDrawCommand,
    command_count: u32,
    command_cap: u32,
};
pub const struct_rvn_drawlist_t = rvn_drawlist_t;

pub extern fn rvn_drawlist_init(list: [*c]rvn_drawlist_t) void;
pub extern fn rvn_drawlist_free(list: [*c]rvn_drawlist_t) void;
pub extern fn rvn_drawlist_reset(list: [*c]rvn_drawlist_t) void;

/// Appends one instance and returns it for the caller to fill.
/// `texture`: Texture sampled by the instance, or R_INVALID_ID when it is not textured. Untextured
/// instances never break a batch.
pub extern fn rvn_drawlist_add(list: [*c]rvn_drawlist_t, texture: raven.Rid) [*c]raven.RDrawInstance;

/// Appends one instance that removes what was drawn under it (R_DRAW_ERASE) and returns it for the caller to fill.
pub extern fn rvn_drawlist_add_erase(list: [*c]rvn_drawlist_t) [*c]raven.RDrawInstance;

/// Appends one instance drawn by a fragment shader (R_DRAW_SHADER) and returns it for the caller to fill.
pub extern fn rvn_drawlist_add_shader(list: [*c]rvn_drawlist_t, shader: raven.Rid, texture: raven.Rid) [*c]raven.RDrawInstance;

/// Appends a viewport callback command.
pub extern fn rvn_drawlist_add_callback(list: [*c]rvn_drawlist_t, command: [*c]const raven.RDrawCommand) void;

/// Asks for the backdrop to be captured before the glass about to be drawn over `area` (pixels).
pub extern fn rvn_drawlist_add_backdrop(list: [*c]rvn_drawlist_t, area: base.rvn_box_t) void;

/// Resolves the backdrop requests of a finished list. A capture is only useful
/// where glass covers something drawn since that place was last captured: the
/// other requests are removed, and the ones that stay are given the area to
/// capture. `frame` is the whole frame, in pixels. Keeps at most `max`
/// captures; returns their number.
pub extern fn rvn_drawlist_resolve_backdrops(list: [*c]rvn_drawlist_t, frame: base.rvn_box_t, max: u32) u32;

/// Appends the content of `source`, merging compatible commands.
pub extern fn rvn_drawlist_append(list: [*c]rvn_drawlist_t, source: [*c]const rvn_drawlist_t) void;
/// Appends only the commands of `source`, whose instances were already copied
/// into `list` starting at index `base`.
pub extern fn rvn_drawlist_append_commands(list: [*c]rvn_drawlist_t, source: [*c]const rvn_drawlist_t, base_: u32) void;

// ---------------------------------------------------------------------------
//  Painter
// ---------------------------------------------------------------------------

pub const RVN_PAINTER_CLIP_STACK = 8;

/// Where the pointer is in a window (logical units) and its buttons; R_FALSE when it is not over the window (widget/window.c).
/// `window` is a `const struct rvn_window_t*`.
pub extern fn rvn_window_pointer(window: ?*const anyopaque, x: [*c]f32, y: [*c]f32, buttons: [*c]u32) c_int;

pub const RPainter = extern struct {
    list: [*c]rvn_drawlist_t,
    /// `struct rvn_window_t*`
    window: ?*anyopaque,
    /// Pixels per logical unit.
    scale: f32,
    /// Origin of the widget being painted, in logical units from the window corner.
    ox: f32,
    oy: f32,
    /// Current clip rectangle, in pixels.
    clip: base.rvn_box_t,
    /// Opacity accumulated from the ancestors.
    opacity: f32,
    /// Text color inherited from the ancestors.
    text_color: base.rvn_color_t,
    /// R_FALSE when the widget or one of its ancestors is disabled.
    enabled: c_int,
    clip_stack: [RVN_PAINTER_CLIP_STACK]base.rvn_box_t,
    clip_depth: c_int,
    /// Seconds since the previous frame of the window, for animations (see rvn_paint_spring).
    dt: f32,
    /// R_TRUE in a right-to-left part of the window: texts that start on the left start on the right.
    rtl: c_int,
};
pub const struct_RPainter = RPainter;

// ---------------------------------------------------------------------------
//  Animation (widget/anim.c)
//
//  Animations are driven by painting. A widget keeps a spring for each value
//  that moves (a RSpring: position, velocity) and, each time it is painted,
//  asks where the spring is now. While a spring is moving, the window keeps
//  producing frames; when everything is at rest, it goes back to sleep.
// ---------------------------------------------------------------------------

/// Moves a spring toward `target` by the time of the frame and returns its
/// value. The first call puts the spring on its target: a state that was
/// already there when the widget appeared is not animated.
pub extern fn rvn_paint_spring(painter: [*c]RPainter, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) f32;
/// Same, starting from where the spring is even on the first call (appearances).
pub extern fn rvn_paint_spring_from(painter: [*c]RPainter, spring: [*c]raven.RSpring, target: f32, motion: raven.RMotion) f32;
/// Gives the spring a push, in units per second: it leaves its target and comes back.
pub extern fn rvn_spring_kick(spring: [*c]raven.RSpring, velocity: f32) void;
/// Puts the spring at rest on a value.
pub extern fn rvn_spring_set(spring: [*c]raven.RSpring, value: f32) void;
/// R_TRUE while the spring has not reached `target`.
pub extern fn rvn_spring_moving(spring: [*c]const raven.RSpring, target: f32) c_int;
/// Tells the window being painted that something is still moving: another frame is needed.
pub extern fn rvn_paint_keep_animating(painter: [*c]RPainter) void;

/// Scales and moves everything that was added to a list from `first_instance`
/// and `first_command` on: sizes are multiplied by (sx, sy) around the pivot,
/// then moved by (dx, dy), all in pixels. Clip rectangles follow, but never
/// grow past `limit`. This is how a widget and its subtree are squashed,
/// popped or flown in after being painted in place.
pub extern fn rvn_drawlist_transform(list: [*c]rvn_drawlist_t, first_instance: u32, first_command: u32, sx: f32, sy: f32, pivot_x: f32, pivot_y: f32, dx: f32, dy: f32, limit: base.rvn_box_t) void;

/// Look of a glass surface. Lengths are in logical units.
pub const rvn_glass_t = extern struct {
    /// Color laid over what is seen through the glass; its alpha is the strength.
    tint: base.rvn_color_t,
    /// Light caught by the rim; its alpha is the intensity.
    rim: base.rvn_color_t,
    /// 0 = clear glass .. 1 = frosted.
    frost: f32,
    /// How far the rim bends what is behind.
    refraction: f32,
    /// Width of the curved rim; 0 = chosen from the size of the shape.
    bevel: f32,
    /// Saturation of what is seen through, 1 = unchanged.
    saturation: f32,
    /// Brightness added to the whole surface (pressed, highlighted).
    glow: f32,
    /// Blur radius of the shadow dropped under the glass, 0 = none.
    shadow: f32,
    shadow_color: base.rvn_color_t,
};
pub const struct_rvn_glass_t = rvn_glass_t;

/// Rounded rectangle of glass (radii: top-left, top-right, bottom-right, bottom-left).
pub extern fn rvn_paint_glass(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, glass: [*c]const rvn_glass_t) void;

/// Look of a blurred surface. Lengths are in logical units.
pub const rvn_blur_t = extern struct {
    /// How far what is behind goes out of focus.
    radius: f32,
    /// Color laid over it; its alpha is the strength.
    tint: base.rvn_color_t,
    /// 0 = smooth .. 1 = the fine grain of frosted glass.
    grain: f32,
    /// Saturation of what is seen through, 1 = unchanged.
    saturation: f32,
    /// Brightness added to the whole surface (negative: taken away).
    light: f32,
    /// Outline, 0 width = none.
    border_width: f32,
    border: base.rvn_color_t,
    /// Blur radius of the shadow dropped under it, 0 = none.
    shadow: f32,
    shadow_color: base.rvn_color_t,
};
pub const struct_rvn_blur_t = rvn_blur_t;

/// Rounded rectangle that shows what is behind it out of focus (radii: top-left, top-right, bottom-right, bottom-left).
pub extern fn rvn_paint_blur(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, blur: [*c]const rvn_blur_t) void;
/// Removes what was drawn in a rounded rectangle, by `amount` (0..1): in a
/// window that can be seen through, the screen shows there.
pub extern fn rvn_paint_erase(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, amount: f32) void;

/// An effect (raven_shader.h) over a rounded rectangle; radii NULL: the radius of the look.
pub extern fn rvn_paint_shader(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, shader: raven.Rid, look: [*c]const raven.RShaderLook) void;

/// Pixel box of a logical rectangle of the current widget, snapped to the pixel grid.
pub extern fn rvn_paint_snap(painter: [*c]const RPainter, rect: base.rvn_rect_t) base.rvn_box_t;

/// Filled rectangle.
pub extern fn rvn_paint_rect(painter: [*c]RPainter, rect: base.rvn_rect_t, color: base.rvn_color_t) void;

/// Rounded rectangle with one radius, optional outline (border_width 0 = none).
pub extern fn rvn_paint_box(painter: [*c]RPainter, rect: base.rvn_rect_t, radius: f32, fill: base.rvn_color_t, border_width: f32, border_color: base.rvn_color_t) void;

/// Rounded rectangle with one radius per corner: top-left, top-right, bottom-right, bottom-left.
pub extern fn rvn_paint_box4(painter: [*c]RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, fill: base.rvn_color_t, border_width: f32, border_color: base.rvn_color_t) void;

/// Soft shadow of a rounded rectangle.
pub extern fn rvn_paint_shadow(painter: [*c]RPainter, rect: base.rvn_rect_t, radius: f32, blur: f32, color: base.rvn_color_t) void;

pub extern fn rvn_paint_line(painter: [*c]RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: base.rvn_color_t) void;
pub extern fn rvn_paint_triangle(painter: [*c]RPainter, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, color: base.rvn_color_t) void;

/// How a curve is drawn (rvn_paint_curve). Lengths in logical units.
pub const rvn_curve_t = extern struct {
    thickness: f32,
    /// Color at the start and at the end: the stroke shades from one to the other.
    from: base.rvn_color_t,
    to: base.rvn_color_t,
    /// Radius and opacity (0..1) of the light around the stroke; 0 = none.
    halo: f32,
    halo_opacity: f32,
    /// Pulses of light running along it: how many, where they are (grows by 1 when each has taken the place of the next), how bright (0..1).
    pulses: f32,
    phase: f32,
    pulse_strength: f32,
};
pub const struct_rvn_curve_t = rvn_curve_t;
/// Cubic Bezier curve: points = start, two control points, end (x, y each).
pub extern fn rvn_paint_curve(painter: [*c]RPainter, points: [*c]const f32, curve: [*c]const rvn_curve_t) void;
/// The point of such a curve at t (0..1).
pub extern fn rvn_curve_point(points: [*c]const f32, t: f32) base.rvn_vec2_t;

/// Textured rectangle. `uv` is u0, v0, u1, v1 or NULL for the whole texture.
pub extern fn rvn_paint_image(painter: [*c]RPainter, rect: base.rvn_rect_t, texture: raven.Rid, uv: [*c]const f32, tint: base.rvn_color_t, radius: f32) void;

/// Single line of text. (x, y) is the top-left corner of the line box.
/// `font`: Font handle; R_INVALID_ID uses the theme font.
/// `size`: Font size in logical units; 0 uses the theme size.
/// `length`: Byte length, or -1 for a null-terminated string.
pub extern fn rvn_paint_text(painter: [*c]RPainter, font: raven.Rid, size: f32, x: f32, y: f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t) void;

/// Text aligned inside a rectangle: horizontal 0 = left, 0.5 = center, 1 = right; vertically centered.
pub extern fn rvn_paint_text_in(painter: [*c]RPainter, font: raven.Rid, size: f32, rect: base.rvn_rect_t, @"align": f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t) void;

/// Small vector icons drawn with lines, centered on (cx, cy).
pub const rvn_icon_t = c_uint;
pub const RVN_ICON_CHEVRON_RIGHT: c_int = 0;
pub const RVN_ICON_CHEVRON_DOWN: c_int = 1;
pub const RVN_ICON_CHEVRON_UP: c_int = 2;
pub const RVN_ICON_CHEVRON_LEFT: c_int = 3;
pub const RVN_ICON_CHECK: c_int = 4;
pub const RVN_ICON_CROSS: c_int = 5;
pub extern fn rvn_paint_icon(painter: [*c]RPainter, icon: rvn_icon_t, cx: f32, cy: f32, size: f32, color: base.rvn_color_t) void;
/// A chevron pointing right, turned clockwise by `angle` radians (a quarter turn points down).
pub extern fn rvn_paint_chevron(painter: [*c]RPainter, cx: f32, cy: f32, size: f32, angle: f32, color: base.rvn_color_t) void;

/// Intersects the clip rectangle with a logical rectangle of the current widget.
pub extern fn rvn_paint_push_clip(painter: [*c]RPainter, rect: base.rvn_rect_t) void;
pub extern fn rvn_paint_pop_clip(painter: [*c]RPainter) void;
