//! uikit/curve_plot: interactive curve editor for EQ. Draggable points on a grid
//! with a frequency axis (logarithmic, Hz) and a gain axis (linear, dB).
//!
//! Mode: retained widget with an immediate-mode paint. The plot is a Raven
//! custom widget (R_WIDGET_CUSTOM, raven_widget.h). Its surface is drawn by the
//! paint callback set with Rcustom_set_paint_callback, using Rdraw_glass for the
//! frosted fill, Rdraw_line for the grid and the curve, and Rdraw_circle for the
//! points. The paint callback REPAINTS EVERY FRAME: it runs on every frame
//! Raven draws, not only on change, so it must only read state and draw. The
//! widget tree does not own the curve state; the Plot struct does, and the
//! callback reads it through the user_data pointer.
//!
//! Input: the event callback (Rwidget_set_event_callback) handles the pointer.
//!   - left press on a point selects it and starts a drag
//!   - drag moves the point; its position is clamped into the plot
//!   - left double-click on empty plot adds a point there
//!   - right press on a point removes it
//! Points are kept sorted by frequency (Curve), at most max_points.
//!
//! Lifetime: a Plot must not move after attach(). The paint and event callbacks
//! keep a pointer to it, so keep it in a fixed location (a field of a long-lived
//! struct, or a module-level variable).
//!
//! Visual rules (liquid glass, from docs/development/uikit.md):
//!   - translucent layered fills (base fill, grid, curve, points)
//!   - 1 px top highlight, white at 0.18 alpha
//!   - soft shadow: black 0.45, blur 18, offset y 6
//!   - corner radius 10 to 14 (default 12, popup)
//!   - accent (#00F0FF) marks the active state and the selected point
//!   - text never below 12 px. Axis labels are not drawn yet: Rdraw_text needs a
//!     font handle that the editor does not load.
//!
//! The pure logic (axis maths, hit testing, the point list) is in Zig and is
//! tested under `zig test` without linking Raven. The Raven externs are only
//! analysed when the Plot methods that call them are referenced.
const std = @import("std");
const testing = std.testing;
const raven = @import("raven.zig");
const theme = @import("theme.zig");

/// Paint hook signature (raven_draw.h RPaintCallback). Declared by hand.
pub const PaintCallback = *const fn (widget: raven.Rid, painter: *raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void;

// raven_draw.h: the paint hook and the drawing calls used by the plot.
pub extern fn Rcustom_set_paint_callback(widget: raven.Rid, callback: PaintCallback, user_data: ?*anyopaque) void;
pub extern fn Rcustom_set_measure_callback(widget: raven.Rid, callback: *const fn (widget: raven.Rid, width: *f32, height: *f32, user_data: ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) void;
extern fn Rdraw_glass(painter: *raven.RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rdraw_line(painter: *raven.RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void;
extern fn Rdraw_circle(painter: *raven.RPainter, center_x: f32, center_y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void;

pub const min_corner_radius: f32 = 10.0;
pub const max_corner_radius: f32 = 14.0;
pub const min_text_size: f32 = 12.0;
pub const min_freq_hz: f32 = 1.0;

/// Configuration of the curve editor. `sanitize` repairs out-of-range values.
pub const Config = struct {
    /// Lower end of the frequency axis (log scale). Must be >= min_freq_hz.
    freq_min_hz: f32 = 20.0,
    /// Upper end of the frequency axis. Must be greater than freq_min_hz.
    freq_max_hz: f32 = 20000.0,
    /// Bottom of the gain axis, in dB.
    gain_min_db: f32 = -24.0,
    /// Top of the gain axis, in dB. Must be greater than gain_min_db.
    gain_max_db: f32 = 24.0,
    /// Spacing of horizontal grid lines, in dB. Must be > 0.
    grid_db_step: f32 = 6.0,
    /// Corner radius of the glass panel. Clamped to 10..14.
    corner_radius: f32 = 12.0,
    /// Text size of axis labels, in px. Never below 12.
    text_size: f32 = 12.0,
    /// Radius of a drawn point, in px.
    point_radius: f32 = 6.0,
    /// Pick radius around a point, in px. Never below point_radius.
    hit_radius: f32 = 10.0,
    /// Alpha of the base glass fill, 0..1 (0.55 base, see uikit.md).
    fill_alpha: f32 = 0.55,
    /// Alpha of the 1 px top highlight, 0..1.
    highlight_alpha: f32 = 0.18,
    /// Blur of the soft shadow, in px. Never negative.
    shadow_blur: f32 = 18.0,
    /// Vertical offset of the soft shadow, in px.
    shadow_offset_y: f32 = 6.0,
    /// Active state: the curve and selected point are drawn in the accent colour.
    active: bool = false,
};

/// One editable point of the curve.
pub const Point = struct {
    freq_hz: f32,
    gain_db: f32,
};

/// Returns a copy of `cfg` with every out-of-range value repaired:
///   - freq_min_hz below min_freq_hz (or NaN) becomes min_freq_hz
///   - freq_max_hz not above freq_min_hz becomes freq_min_hz * 2
///   - gain_max_db not above gain_min_db becomes gain_min_db + 1
///   - grid_db_step not finite or <= 0 becomes 6
///   - corner_radius clamped to 10..14
///   - text_size below 12 becomes 12
///   - hit_radius below point_radius becomes point_radius
///   - fill_alpha and highlight_alpha clamped to 0..1
///   - shadow_blur below 0 becomes 0
/// Idempotent: sanitize(sanitize(c)) == sanitize(c).
pub fn sanitize(cfg: Config) Config {
    var out = cfg;
    if (!(out.freq_min_hz >= min_freq_hz)) out.freq_min_hz = min_freq_hz;
    if (!(out.freq_max_hz > out.freq_min_hz)) out.freq_max_hz = out.freq_min_hz * 2.0;
    if (!(out.gain_max_db > out.gain_min_db)) out.gain_max_db = out.gain_min_db + 1.0;
    if (!std.math.isFinite(out.grid_db_step) or out.grid_db_step <= 0.0) out.grid_db_step = 6.0;
    out.corner_radius = clampCornerRadius(out.corner_radius);
    out.text_size = clampTextSize(out.text_size);
    if (!(out.hit_radius >= out.point_radius)) out.hit_radius = out.point_radius;
    out.fill_alpha = clampUnit(out.fill_alpha);
    out.highlight_alpha = clampUnit(out.highlight_alpha);
    if (!(out.shadow_blur >= 0.0)) out.shadow_blur = 0.0;
    return out;
}

/// Clamps an alpha to 0..1. NaN and negatives become 0.
fn clampUnit(v: f32) f32 {
    if (!(v >= 0.0)) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

/// Clamps a corner radius to 10..14. NaN becomes 12.
pub fn clampCornerRadius(radius: f32) f32 {
    if (std.math.isNan(radius)) return 12.0;
    return std.math.clamp(radius, min_corner_radius, max_corner_radius);
}

/// Raises a text size to at least 12 px. NaN becomes 12.
pub fn clampTextSize(size: f32) f32 {
    if (std.math.isNan(size)) return min_text_size;
    if (size < min_text_size) return min_text_size;
    return size;
}

/// Clamps a gain into [cfg.gain_min_db, cfg.gain_max_db]. `cfg` must be sanitized.
pub fn clampGainDb(cfg: Config, db: f32) f32 {
    return std.math.clamp(db, cfg.gain_min_db, cfg.gain_max_db);
}

/// Clamps a frequency into [cfg.freq_min_hz, cfg.freq_max_hz]. `cfg` must be sanitized.
pub fn clampFreqHz(cfg: Config, hz: f32) f32 {
    return std.math.clamp(hz, cfg.freq_min_hz, cfg.freq_max_hz);
}

/// Maps a frequency to an x pixel in 0..width on the logarithmic axis.
/// freq_min_hz maps to 0, freq_max_hz maps to width.
pub fn freqToX(cfg: Config, width: f32, hz: f32) f32 {
    const lo = @log(@as(f64, cfg.freq_min_hz));
    const hi = @log(@as(f64, cfg.freq_max_hz));
    const t = (@log(@as(f64, hz)) - lo) / (hi - lo);
    return @floatCast(@as(f64, width) * t);
}

/// Inverse of freqToX.
pub fn xToFreq(cfg: Config, width: f32, x: f32) f32 {
    const lo = @log(@as(f64, cfg.freq_min_hz));
    const hi = @log(@as(f64, cfg.freq_max_hz));
    const t = @as(f64, x) / @as(f64, width);
    return @floatCast(@exp(lo + t * (hi - lo)));
}

/// Maps a gain to a y pixel in 0..height. gain_max_db maps to 0 (top),
/// gain_min_db maps to height (bottom). Linear.
pub fn gainToY(cfg: Config, height: f32, db: f32) f32 {
    return height * (cfg.gain_max_db - db) / (cfg.gain_max_db - cfg.gain_min_db);
}

/// Inverse of gainToY.
pub fn yToGain(cfg: Config, height: f32, y: f32) f32 {
    return cfg.gain_max_db - (y / height) * (cfg.gain_max_db - cfg.gain_min_db);
}

/// Index of the point nearest to pixel (x, y) within cfg.hit_radius, or null.
/// The distance is measured in pixels from the point's mapped position.
/// Ties go to the lowest index.
pub fn hitTest(cfg: Config, width: f32, height: f32, points: []const Point, x: f32, y: f32) ?usize {
    const c = sanitize(cfg);
    var best: ?usize = null;
    var best_dist: f32 = std.math.inf(f32);
    for (points, 0..) |p, i| {
        const dx = freqToX(c, width, p.freq_hz) - x;
        const dy = gainToY(c, height, p.gain_db) - y;
        const dist = @sqrt(dx * dx + dy * dy);
        // Strict comparison keeps the lowest index on a tie.
        if (dist <= c.hit_radius and dist < best_dist) {
            best = i;
            best_dist = dist;
        }
    }
    return best;
}

/// Next selection index with wrap-around. Null when len is 0.
/// A null current selects 0. The last index wraps to 0.
pub fn nextSelection(len: usize, current: ?usize) ?usize {
    if (len == 0) return null;
    const c = current orelse return 0;
    return (c + 1) % len;
}

/// Previous selection index with wrap-around. Null when len is 0.
/// A null current selects len - 1. Index 0 wraps to len - 1.
pub fn prevSelection(len: usize, current: ?usize) ?usize {
    if (len == 0) return null;
    const c = current orelse return len - 1;
    if (c == 0) return len - 1;
    return @min(c - 1, len - 1);
}

/// Index at which a new point with frequency `freq_hz` is inserted so that
/// `points` (sorted ascending by freq_hz) stays sorted. A new point goes after
/// existing points with the same frequency.
pub fn sortedInsertIndex(points: []const Point, freq_hz: f32) usize {
    for (points, 0..) |p, i| {
        if (p.freq_hz > freq_hz) return i;
    }
    return points.len;
}

/// Index that the point at `index` has after its frequency becomes
/// `new_freq_hz` and the list is re-sorted. The same tie rule as
/// sortedInsertIndex applies. Null when `index` is out of range.
/// Does not modify `points`.
pub fn indexAfterFreqMove(points: []const Point, index: usize, new_freq_hz: f32) ?usize {
    if (index >= points.len) return null;
    // Count the other points that stay at or below the new frequency; the moved
    // point lands after them, which matches the sortedInsertIndex tie rule.
    var before: usize = 0;
    for (points, 0..) |p, j| {
        if (j == index) continue;
        if (p.freq_hz <= new_freq_hz) before += 1;
    }
    return before;
}

/// Largest number of points the curve holds. Curve.add refuses beyond it.
pub const max_points: usize = 16;

/// Clamps a point into the plot: frequency into [freq_min_hz, freq_max_hz],
/// gain into [gain_min_db, gain_max_db]. A NaN frequency takes the low end of
/// the axis and a NaN gain takes 0 dB (or the nearest gain in range).
pub fn clampPoint(cfg_in: Config, p: Point) Point {
    const cfg = sanitize(cfg_in);
    const freq = if (std.math.isNan(p.freq_hz)) cfg.freq_min_hz else clampFreqHz(cfg, p.freq_hz);
    const gain = if (std.math.isNan(p.gain_db)) clampGainDb(cfg, 0.0) else clampGainDb(cfg, p.gain_db);
    return .{ .freq_hz = freq, .gain_db = gain };
}

/// The curve value under local pixel (x, y) of a plot of width x height. The
/// pixel is clamped to the plot first, so a pointer outside it gives an edge value.
pub fn pointAt(cfg_in: Config, width: f32, height: f32, x: f32, y: f32) Point {
    const cfg = sanitize(cfg_in);
    if (!(width > 0.0) or !(height > 0.0)) return clampPoint(cfg, .{ .freq_hz = cfg.freq_min_hz, .gain_db = 0.0 });
    const px = clampPixel(x, width);
    const py = clampPixel(y, height);
    return clampPoint(cfg, .{
        .freq_hz = xToFreq(cfg, width, px),
        .gain_db = yToGain(cfg, height, py),
    });
}

/// Pixel position clamped into [0, span]. NaN gives 0.
fn clampPixel(v: f32, span: f32) f32 {
    if (!(v >= 0.0)) return 0.0;
    if (v > span) return span;
    return v;
}

/// Most horizontal grid lines drawn. A count beyond it is capped, so a tiny grid
/// step or a huge gain range cannot make the count overflow.
pub const max_grid_lines: usize = 256;

/// Number of horizontal grid lines: one per grid_db_step from gain_min_db up to
/// gain_max_db, both ends included, capped at max_grid_lines + 1. Expects a
/// sanitized config.
pub fn gainLineCount(cfg: Config) usize {
    const span = cfg.gain_max_db - cfg.gain_min_db;
    const steps: f32 = @floor(span / cfg.grid_db_step + 1e-4);
    // Checked against the cap before the cast. The negated form also takes NaN.
    if (!(steps < @as(f32, @floatFromInt(max_grid_lines)))) return max_grid_lines + 1;
    return @as(usize, @intFromFloat(steps)) + 1;
}

/// Y pixel of grid line `index` (0 is the bottom edge, gain_min_db) in a plot of
/// `height` px. Expects a sanitized config.
pub fn gainLineY(cfg: Config, height: f32, index: usize) f32 {
    const db = cfg.gain_min_db + @as(f32, @floatFromInt(index)) * cfg.grid_db_step;
    return gainToY(cfg, height, @min(db, cfg.gain_max_db));
}

/// Number of decade frequency lines (10, 100, 1 kHz, ...) inside
/// [freq_min_hz, freq_max_hz]. The grid draws a line at each of them.
pub fn freqLineCount(cfg: Config) usize {
    var n: usize = 0;
    var f: f32 = 10.0;
    while (f <= cfg.freq_max_hz) : (f *= 10.0) {
        if (f >= cfg.freq_min_hz) n += 1;
    }
    return n;
}

/// A list of curve points, sorted by frequency, with fixed capacity.
pub const Curve = struct {
    items: [max_points]Point = undefined,
    len: usize = 0,

    /// The points in frequency order.
    pub fn slice(self: *const Curve) []const Point {
        return self.items[0..self.len];
    }

    /// Adds a point at the clamped position and keeps the list sorted. Returns
    /// its index, or null when the curve is full.
    pub fn add(self: *Curve, cfg: Config, freq_hz: f32, gain_db: f32) ?usize {
        if (self.len >= max_points) return null;
        const p = clampPoint(cfg, .{ .freq_hz = freq_hz, .gain_db = gain_db });
        const at = sortedInsertIndex(self.slice(), p.freq_hz);
        var i = self.len;
        while (i > at) : (i -= 1) self.items[i] = self.items[i - 1];
        self.items[at] = p;
        self.len += 1;
        return at;
    }

    /// Removes the point at index, shifting later points down. False when index is out of range.
    pub fn remove(self: *Curve, index: usize) bool {
        if (index >= self.len) return false;
        var i = index;
        while (i + 1 < self.len) : (i += 1) self.items[i] = self.items[i + 1];
        self.len -= 1;
        return true;
    }

    /// Moves the point at index to a clamped position and re-sorts the list.
    /// Returns the point's new index, or null when index is out of range.
    pub fn move(self: *Curve, cfg: Config, index: usize, freq_hz: f32, gain_db: f32) ?usize {
        if (index >= self.len) return null;
        const p = clampPoint(cfg, .{ .freq_hz = freq_hz, .gain_db = gain_db });
        const new_index = indexAfterFreqMove(self.slice(), index, p.freq_hz) orelse return null;
        var out: [max_points]Point = undefined;
        var k: usize = 0;
        var placed = false;
        for (self.slice(), 0..) |q, j| {
            if (j == index) continue;
            if (!placed and k == new_index) {
                out[k] = p;
                k += 1;
                placed = true;
            }
            out[k] = q;
            k += 1;
        }
        if (!placed) {
            out[k] = p;
        }
        @memcpy(self.items[0..self.len], out[0..self.len]);
        return new_index;
    }
};

/// The curve editor widget. Holds the curve, the selection and the drag state.
/// Create with `init`, then `attach` to a parent. The Plot must stay at the same
/// address after attach (see the file header).
pub const Plot = struct {
    cfg: Config,
    curve: Curve = .{},
    width: f32,
    height: f32,
    widget: raven.Rid = raven.invalid,
    selected: ?usize = null,
    dragging: ?usize = null,

    /// A plot of `width` x `height` px with the given configuration. Sizes below 1 px are raised to 1 px.
    pub fn init(cfg: Config, width: f32, height: f32) Plot {
        return .{
            .cfg = sanitize(cfg),
            .width = if (width >= 1.0) width else 1.0,
            .height = if (height >= 1.0) height else 1.0,
        };
    }

    /// Adds a point from code (not a gesture). Returns its index, or null when full.
    pub fn addPoint(self: *Plot, freq_hz: f32, gain_db: f32) ?usize {
        return self.curve.add(self.cfg, freq_hz, gain_db);
    }

    /// Removes the point at index from code. Clears the selection and the drag.
    pub fn removePoint(self: *Plot, index: usize) bool {
        if (!self.curve.remove(index)) return false;
        self.selected = null;
        self.dragging = null;
        return true;
    }

    /// Creates the custom widget, installs the paint and event callbacks and adds it to `parent`.
    pub fn attach(self: *Plot, parent: raven.Rid) void {
        const w = raven.Rwidget_create(.custom);
        self.widget = w;
        raven.Rwidget_set_size(w, self.width, self.height);
        Rcustom_set_paint_callback(w, paintCallback, self);
        raven.Rwidget_set_event_callback(w, eventCallback, self);
        _ = raven.Rwidget_add_child(parent, w);
    }

    /// Handles one input event. True when the event was used.
    pub fn handleEvent(self: *Plot, e: *const raven.Event) bool {
        switch (e.type) {
            .mouse_down => {
                const hit = hitTest(self.cfg, self.width, self.height, self.curve.slice(), e.local_x, e.local_y);
                if (e.button == raven.mouse_left) {
                    if (hit) |i| {
                        self.selected = i;
                        self.dragging = i;
                        return true;
                    }
                    if (e.clicks >= 2) {
                        const p = pointAt(self.cfg, self.width, self.height, e.local_x, e.local_y);
                        self.selected = self.curve.add(self.cfg, p.freq_hz, p.gain_db);
                    }
                    return true;
                }
                if (e.button == raven.mouse_right) {
                    if (hit) |i| return self.removePoint(i);
                }
                return false;
            },
            .mouse_move => {
                const i = self.dragging orelse return false;
                const p = pointAt(self.cfg, self.width, self.height, e.local_x, e.local_y);
                if (self.curve.move(self.cfg, i, p.freq_hz, p.gain_db)) |n| {
                    self.dragging = n;
                    self.selected = n;
                } else {
                    self.dragging = null;
                }
                return true;
            },
            .mouse_up => {
                if (e.button != raven.mouse_left or self.dragging == null) return false;
                self.dragging = null;
                return true;
            },
            else => return false,
        }
    }

    /// Draws the plot surface. Called by Raven on every frame. Reads state only.
    fn paint(self: *const Plot, painter: *raven.RPainter, w: f32, h: f32) void {
        const c = sanitize(self.cfg);
        const fill = theme.withAlpha(theme.bg_panel, c.fill_alpha);
        Rdraw_glass(painter, 0.0, 0.0, w, h, c.corner_radius, fill.r, fill.g, fill.b, fill.a);

        // 1 px top highlight, kept inside the rounded corners.
        Rdraw_line(painter, c.corner_radius, 0.5, w - c.corner_radius, 0.5, theme.highlight_px, 1.0, 1.0, 1.0, c.highlight_alpha);

        // Grid: one line per gain step, one per decade frequency.
        const grid = theme.text_muted;
        var gi: usize = 0;
        while (gi < gainLineCount(c)) : (gi += 1) {
            const y = gainLineY(c, h, gi);
            Rdraw_line(painter, 0.0, y, w, y, 1.0, grid.r, grid.g, grid.b, 0.25);
        }
        var f: f32 = 10.0;
        while (f <= c.freq_max_hz) : (f *= 10.0) {
            if (f < c.freq_min_hz) continue;
            const x = freqToX(c, w, f);
            Rdraw_line(painter, x, 0.0, x, h, 1.0, grid.r, grid.g, grid.b, 0.25);
        }

        // Curve through the points, then the points themselves.
        const line = if (c.active) theme.accent else theme.text_muted;
        const pts = self.curve.slice();
        var prev: ?Point = null;
        for (pts) |p| {
            if (prev) |q| {
                Rdraw_line(painter, freqToX(c, w, q.freq_hz), gainToY(c, h, q.gain_db), freqToX(c, w, p.freq_hz), gainToY(c, h, p.gain_db), 2.0, line.r, line.g, line.b, 0.9);
            }
            prev = p;
        }
        for (pts, 0..) |p, i| {
            const col = if (self.selected != null and self.selected.? == i) theme.accent else theme.text;
            Rdraw_circle(painter, freqToX(c, w, p.freq_hz), gainToY(c, h, p.gain_db), c.point_radius, col.r, col.g, col.b, 0.85);
        }
    }
};

fn paintCallback(widget: raven.Rid, painter: *raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const ptr = user_data orelse return;
    const plot: *const Plot = @ptrCast(@alignCast(ptr));
    plot.paint(painter, width, height);
}

fn eventCallback(widget: raven.Rid, event: *const raven.Event, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = widget;
    const ptr = user_data orelse return 0;
    const plot: *Plot = @ptrCast(@alignCast(ptr));
    return if (plot.handleEvent(event)) 1 else 0;
}

test "curve_plot configuration: defaults" {
    const cfg = sanitize(.{});
    try testing.expectEqual(@as(f32, 20.0), cfg.freq_min_hz);
    try testing.expectEqual(@as(f32, 20000.0), cfg.freq_max_hz);
    try testing.expectEqual(@as(f32, -24.0), cfg.gain_min_db);
    try testing.expectEqual(@as(f32, 24.0), cfg.gain_max_db);
    try testing.expectEqual(@as(f32, 6.0), cfg.grid_db_step);
    try testing.expectEqual(@as(f32, 12.0), cfg.corner_radius);
    try testing.expectEqual(@as(f32, 12.0), cfg.text_size);
    try testing.expectEqual(@as(f32, 6.0), cfg.point_radius);
    try testing.expectEqual(@as(f32, 10.0), cfg.hit_radius);
    try testing.expectEqual(@as(f32, 0.55), cfg.fill_alpha);
    try testing.expectEqual(@as(f32, 0.18), cfg.highlight_alpha);
    try testing.expectEqual(@as(f32, 18.0), cfg.shadow_blur);
    try testing.expectEqual(@as(f32, 6.0), cfg.shadow_offset_y);
    try testing.expectEqual(false, cfg.active);
}

test "curve_plot configuration: corner radius clamped to 10..14" {
    try testing.expectEqual(@as(f32, 10.0), clampCornerRadius(4.0));
    try testing.expectEqual(@as(f32, 14.0), clampCornerRadius(30.0));
    try testing.expectEqual(@as(f32, 12.0), clampCornerRadius(12.0));
    try testing.expectEqual(@as(f32, 12.0), clampCornerRadius(std.math.nan(f32)));
}

test "curve_plot configuration: text never below 12 px" {
    try testing.expectEqual(@as(f32, 12.0), clampTextSize(8.0));
    try testing.expectEqual(@as(f32, 16.0), clampTextSize(16.0));
    try testing.expectEqual(@as(f32, 12.0), clampTextSize(std.math.nan(f32)));
    const cfg = sanitize(.{ .text_size = 9.0 });
    try testing.expectEqual(@as(f32, 12.0), cfg.text_size);
}

test "curve_plot configuration: frequency range repaired" {
    // Non-positive minimum becomes 1 Hz (log axis needs a positive value).
    const low = sanitize(.{ .freq_min_hz = 0.0 });
    try testing.expectEqual(@as(f32, 1.0), low.freq_min_hz);
    // Inverted or empty range: max becomes min * 2.
    const inverted = sanitize(.{ .freq_min_hz = 100.0, .freq_max_hz = 50.0 });
    try testing.expectEqual(@as(f32, 100.0), inverted.freq_min_hz);
    try testing.expectEqual(@as(f32, 200.0), inverted.freq_max_hz);
}

test "curve_plot configuration: gain range and grid step repaired" {
    const inverted = sanitize(.{ .gain_min_db = 6.0, .gain_max_db = -6.0 });
    try testing.expectEqual(@as(f32, 6.0), inverted.gain_min_db);
    try testing.expectEqual(@as(f32, 7.0), inverted.gain_max_db);
    const flat = sanitize(.{ .grid_db_step = 0.0 });
    try testing.expectEqual(@as(f32, 6.0), flat.grid_db_step);
    const negative = sanitize(.{ .grid_db_step = -3.0 });
    try testing.expectEqual(@as(f32, 6.0), negative.grid_db_step);
}

test "curve_plot configuration: hit radius, alphas and blur clamped" {
    const cfg = sanitize(.{ .point_radius = 8.0, .hit_radius = 4.0, .fill_alpha = 1.5, .highlight_alpha = -0.2, .shadow_blur = -1.0 });
    try testing.expectEqual(@as(f32, 8.0), cfg.hit_radius);
    try testing.expectEqual(@as(f32, 1.0), cfg.fill_alpha);
    try testing.expectEqual(@as(f32, 0.0), cfg.highlight_alpha);
    try testing.expectEqual(@as(f32, 0.0), cfg.shadow_blur);
}

test "curve_plot configuration: sanitize is idempotent" {
    const once = sanitize(.{ .freq_min_hz = 0.0, .freq_max_hz = 0.5, .corner_radius = 99.0, .text_size = 3.0 });
    const twice = sanitize(once);
    try testing.expectEqual(once, twice);
}

test "curve_plot clamping: gain and frequency into range" {
    const cfg = sanitize(.{});
    try testing.expectEqual(@as(f32, 24.0), clampGainDb(cfg, 30.0));
    try testing.expectEqual(@as(f32, -24.0), clampGainDb(cfg, -30.0));
    try testing.expectEqual(@as(f32, 0.0), clampGainDb(cfg, 0.0));
    try testing.expectEqual(@as(f32, 20.0), clampFreqHz(cfg, 5.0));
    try testing.expectEqual(@as(f32, 20000.0), clampFreqHz(cfg, 50000.0));
    try testing.expectEqual(@as(f32, 1000.0), clampFreqHz(cfg, 1000.0));
}

test "curve_plot axis: frequency maps logarithmically" {
    const cfg = sanitize(.{});
    const width: f32 = 300.0;
    try testing.expectApproxEqAbs(@as(f32, 0.0), freqToX(cfg, width, 20.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 300.0), freqToX(cfg, width, 20000.0), 1e-3);
    // The geometric midpoint of 20 Hz and 20 kHz sits at the middle of the axis.
    try testing.expectApproxEqAbs(@as(f32, 150.0), freqToX(cfg, width, @sqrt(@as(f32, 20.0) * 20000.0)), 1e-3);
}

test "curve_plot axis: gain maps linearly with gain max at the top" {
    const cfg = sanitize(.{});
    const height: f32 = 200.0;
    try testing.expectApproxEqAbs(@as(f32, 0.0), gainToY(cfg, height, 24.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 200.0), gainToY(cfg, height, -24.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 100.0), gainToY(cfg, height, 0.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 50.0), gainToY(cfg, height, 12.0), 1e-3);
}

test "curve_plot axis: pixel to value round trip" {
    const cfg = sanitize(.{});
    const width: f32 = 300.0;
    const height: f32 = 200.0;
    try testing.expectApproxEqRel(@as(f32, 1000.0), xToFreq(cfg, width, freqToX(cfg, width, 1000.0)), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -7.5), yToGain(cfg, height, gainToY(cfg, height, -7.5)), 1e-3);
}

test "curve_plot selection: hit radius, nearest point, lowest index on tie" {
    const cfg: Config = .{};
    const width: f32 = 300.0;
    const height: f32 = 200.0;
    // Both points sit on the 0 dB line at the two ends of the axis: (0, 100) and (300, 100).
    const ends = [_]Point{ .{ .freq_hz = 20.0, .gain_db = 0.0 }, .{ .freq_hz = 20000.0, .gain_db = 0.0 } };
    try testing.expectEqual(@as(?usize, 0), hitTest(cfg, width, height, &ends, 3.0, 103.0));
    try testing.expectEqual(@as(?usize, 1), hitTest(cfg, width, height, &ends, 298.0, 100.0));
    try testing.expectEqual(@as(?usize, null), hitTest(cfg, width, height, &ends, 150.0, 100.0));

    // Two points at the same frequency, -2 dB apart: (0, 100) and (0, 108.33).
    // A press at (0, 106) is 6 px from index 0 and 2.33 px from index 1.
    const stacked = [_]Point{ .{ .freq_hz = 20.0, .gain_db = 0.0 }, .{ .freq_hz = 20.0, .gain_db = -2.0 } };
    try testing.expectEqual(@as(?usize, 1), hitTest(cfg, width, height, &stacked, 0.0, 106.0));

    // Exactly equal distance: lowest index wins.
    const twins = [_]Point{ .{ .freq_hz = 20.0, .gain_db = 0.0 }, .{ .freq_hz = 20.0, .gain_db = 0.0 } };
    try testing.expectEqual(@as(?usize, 0), hitTest(cfg, width, height, &twins, 0.0, 100.0));
}

test "curve_plot selection: next and previous wrap around" {
    try testing.expectEqual(@as(?usize, null), nextSelection(0, null));
    try testing.expectEqual(@as(?usize, 0), nextSelection(3, null));
    try testing.expectEqual(@as(?usize, 1), nextSelection(3, 0));
    try testing.expectEqual(@as(?usize, 0), nextSelection(3, 2));

    try testing.expectEqual(@as(?usize, null), prevSelection(0, null));
    try testing.expectEqual(@as(?usize, 2), prevSelection(3, null));
    try testing.expectEqual(@as(?usize, 2), prevSelection(3, 0));
    try testing.expectEqual(@as(?usize, 1), prevSelection(3, 2));
}

test "curve_plot index: sorted insert position" {
    const pts = [_]Point{
        .{ .freq_hz = 20.0, .gain_db = 0.0 },
        .{ .freq_hz = 100.0, .gain_db = 0.0 },
        .{ .freq_hz = 1000.0, .gain_db = 0.0 },
    };
    try testing.expectEqual(@as(usize, 0), sortedInsertIndex(&pts, 5.0));
    try testing.expectEqual(@as(usize, 2), sortedInsertIndex(&pts, 500.0));
    try testing.expectEqual(@as(usize, 3), sortedInsertIndex(&pts, 20000.0));
    // Equal frequency goes after the existing point.
    try testing.expectEqual(@as(usize, 2), sortedInsertIndex(&pts, 100.0));
    try testing.expectEqual(@as(usize, 0), sortedInsertIndex(&[_]Point{}, 440.0));
}

test "curve_plot index: position after moving a point" {
    const pts = [_]Point{
        .{ .freq_hz = 20.0, .gain_db = 0.0 },
        .{ .freq_hz = 100.0, .gain_db = 0.0 },
        .{ .freq_hz = 1000.0, .gain_db = 0.0 },
    };
    // Index 0 dragged to 2000 Hz: others below it are 100 and 1000, so it becomes index 2.
    try testing.expectEqual(@as(?usize, 2), indexAfterFreqMove(&pts, 0, 2000.0));
    // Index 2 dragged to 50 Hz: others at or below it are 20, so it becomes index 1.
    try testing.expectEqual(@as(?usize, 1), indexAfterFreqMove(&pts, 2, 50.0));
    // Index 0 dragged onto 100 Hz: equal frequency goes after the other point, index 1.
    try testing.expectEqual(@as(?usize, 1), indexAfterFreqMove(&pts, 0, 100.0));
    // Out of range index is null.
    try testing.expectEqual(@as(?usize, null), indexAfterFreqMove(&pts, 3, 50.0));
}

test "curve_plot clamping: points pulled into the plot" {
    const cfg = sanitize(.{});
    const low = clampPoint(cfg, .{ .freq_hz = 2.0, .gain_db = -40.0 });
    try testing.expectEqual(@as(f32, 20.0), low.freq_hz);
    try testing.expectEqual(@as(f32, -24.0), low.gain_db);
    const high = clampPoint(cfg, .{ .freq_hz = 90000.0, .gain_db = 50.0 });
    try testing.expectEqual(@as(f32, 20000.0), high.freq_hz);
    try testing.expectEqual(@as(f32, 24.0), high.gain_db);
    // NaN frequency takes the low end of the axis, NaN gain takes 0 dB.
    const nan_p = clampPoint(cfg, .{ .freq_hz = std.math.nan(f32), .gain_db = std.math.nan(f32) });
    try testing.expectEqual(@as(f32, 20.0), nan_p.freq_hz);
    try testing.expectEqual(@as(f32, 0.0), nan_p.gain_db);
}

test "curve_plot pointer: local position maps to a clamped point" {
    const cfg = sanitize(.{});
    const w: f32 = 300.0;
    const h: f32 = 200.0;
    const top_left = pointAt(cfg, w, h, 0.0, 0.0);
    try testing.expectApproxEqRel(@as(f32, 20.0), top_left.freq_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 24.0), top_left.gain_db, 1e-3);
    const bottom_right = pointAt(cfg, w, h, w, h);
    try testing.expectApproxEqRel(@as(f32, 20000.0), bottom_right.freq_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -24.0), bottom_right.gain_db, 1e-3);
    // Pointer outside the widget is clamped to the edge, NaN takes the low end.
    const outside = pointAt(cfg, w, h, -50.0, 900.0);
    try testing.expectApproxEqRel(@as(f32, 20.0), outside.freq_hz, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -24.0), outside.gain_db, 1e-3);
    const nan_x = pointAt(cfg, w, h, std.math.nan(f32), 100.0);
    try testing.expectApproxEqRel(@as(f32, 20.0), nan_x.freq_hz, 1e-4);
}

test "curve_plot curve: add keeps points sorted and clamped" {
    const cfg = sanitize(.{});
    var curve: Curve = .{};
    try testing.expectEqual(@as(usize, 0), curve.len);
    try testing.expectEqual(@as(?usize, 0), curve.add(cfg, 1000.0, 3.0));
    try testing.expectEqual(@as(?usize, 0), curve.add(cfg, 100.0, 0.0));
    try testing.expectEqual(@as(?usize, 2), curve.add(cfg, 5000.0, 0.0));
    try testing.expectEqual(@as(f32, 100.0), curve.slice()[0].freq_hz);
    try testing.expectEqual(@as(f32, 1000.0), curve.slice()[1].freq_hz);
    // Out-of-range input is clamped into the plot before it is stored.
    _ = curve.add(cfg, 1.0, 99.0);
    try testing.expectEqual(@as(f32, 20.0), curve.slice()[0].freq_hz);
    try testing.expectEqual(@as(f32, 24.0), curve.slice()[0].gain_db);
    try testing.expectEqual(@as(usize, 4), curve.len);
}

test "curve_plot curve: add refuses when full" {
    const cfg = sanitize(.{});
    var curve: Curve = .{};
    for (0..max_points) |i| {
        try testing.expect(curve.add(cfg, 20.0 + @as(f32, @floatFromInt(i)), 0.0) != null);
    }
    try testing.expectEqual(@as(?usize, null), curve.add(cfg, 500.0, 0.0));
    try testing.expectEqual(max_points, curve.len);
}

test "curve_plot curve: remove shifts later points down" {
    const cfg = sanitize(.{});
    var curve: Curve = .{};
    _ = curve.add(cfg, 100.0, 1.0);
    _ = curve.add(cfg, 200.0, 2.0);
    _ = curve.add(cfg, 300.0, 3.0);
    try testing.expect(curve.remove(1));
    try testing.expectEqual(@as(usize, 2), curve.len);
    try testing.expectEqual(@as(f32, 3.0), curve.slice()[1].gain_db);
    try testing.expect(!curve.remove(5));
    try testing.expectEqual(@as(usize, 2), curve.len);
}

test "curve_plot curve: move re-sorts and clamps" {
    const cfg = sanitize(.{});
    var curve: Curve = .{};
    _ = curve.add(cfg, 100.0, 0.0);
    _ = curve.add(cfg, 1000.0, 0.0);
    _ = curve.add(cfg, 5000.0, 0.0);
    // Index 0 dragged past the others lands at index 2.
    try testing.expectEqual(@as(?usize, 2), curve.move(cfg, 0, 9000.0, 6.0));
    try testing.expectEqual(@as(f32, 1000.0), curve.slice()[0].freq_hz);
    try testing.expectEqual(@as(f32, 5000.0), curve.slice()[1].freq_hz);
    try testing.expectEqual(@as(f32, 9000.0), curve.slice()[2].freq_hz);
    try testing.expectEqual(@as(f32, 6.0), curve.slice()[2].gain_db);
    // Index 2 dragged below everything lands at 0; gain is clamped to the top.
    try testing.expectEqual(@as(?usize, 0), curve.move(cfg, 2, 1.0, 40.0));
    try testing.expectEqual(@as(f32, 20.0), curve.slice()[0].freq_hz);
    try testing.expectEqual(@as(f32, 24.0), curve.slice()[0].gain_db);
    try testing.expectEqual(@as(?usize, null), curve.move(cfg, 9, 100.0, 0.0));
}

test "curve_plot grid: decade frequency lines and dB steps inside the plot" {
    const cfg = sanitize(.{});
    // Gain steps every 6 dB from -24 to 24 give 9 lines. Line 0 is the bottom
    // edge (-24 dB), the last line is the top edge (+24 dB).
    try testing.expectEqual(@as(usize, 9), gainLineCount(cfg));
    try testing.expectApproxEqAbs(@as(f32, 200.0), gainLineY(cfg, 200.0, 0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.0), gainLineY(cfg, 200.0, 8), 1e-3);
    // Frequency lines at 100, 1 kHz and 10 kHz are the decade marks inside 20 Hz..20 kHz.
    try testing.expectEqual(@as(usize, 3), freqLineCount(cfg));
}

test "curve_plot grid: tiny grid step cannot overflow the line count" {
    // A 1e-30 dB step would ask for ~5e31 lines. The count is capped instead of cast unchecked.
    const cfg = sanitize(.{ .grid_db_step = 1.0e-30 });
    try testing.expectEqual(max_grid_lines + 1, gainLineCount(cfg));
    const huge = sanitize(.{ .gain_min_db = -1.0e38, .gain_max_db = 1.0e38, .grid_db_step = 1.0 });
    try testing.expectEqual(max_grid_lines + 1, gainLineCount(huge));
}
