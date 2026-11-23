//! uikit/value: value widgets for the liquid-glass kit.
//!
//! Four widgets, all built from Raven widgets:
//!   - Slider: Rslider (R_WIDGET_SLIDER) in an HBox with a value readout Rlabel.
//!   - Stepper: HBox of two flat Rbutton ("-", "+") around a value Rlabel.
//!   - Progress: Rprogress_bar (R_WIDGET_PROGRESSBAR) on a glass Border track.
//!   - Segmented: glass Border around an HBox of Rbutton, one per segment; the
//!     selected segment uses R_BUTTON_PRIMARY (accent), the rest R_BUTTON_FLAT.
//!
//! Mode: retained for all four. Each widget is created with Rwidget_create (or
//! an Rxxx_create shortcut) and placed in the tree; nothing here repaints per
//! frame, so this file has no immediate-mode code.
//!
//! Ownership: each widget is a struct the caller keeps at a stable address and
//! passes to `init`. The struct is the callbacks' user_data, so `init` must not
//! be given a temporary. Raven calls back into Zig only through those callbacks.
//!
//! Configuration logic (sanitize, increment, clamp) is pure and separate from
//! the Raven calls, so `zig test` on this file does not link Raven.
//! Raven calls are declared in raven.zig. Transitions use Raven's springs; the
//! 120 ms target is theme.transition_ms (see docs/development/uikit.md).
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const style = @import("style.zig");
const raven = @import("raven.zig");

const Rid = raven.Rid;

pub const Error = error{
    /// Raven returned R_INVALID_ID for a widget or child that was requested.
    RavenCreateFailed,
    /// Segmented was given more labels than max_segments.
    TooManySegments,
};

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn created(id: Rid) Error!Rid {
    if (id == raven.invalid) return error.RavenCreateFailed;
    return id;
}

fn addChild(parent: Rid, child: Rid) Error!void {
    if (raven.Rwidget_add_child(parent, child) == raven.invalid) return error.RavenCreateFailed;
}

fn setEnabled(widget: Rid, enabled: bool) void {
    raven.Rwidget_set_enabled(widget, @intFromBool(enabled));
}

fn finiteOr(v: f32, fallback: f32) f32 {
    return if (std.math.isFinite(v)) v else fallback;
}

// ---------------------------------------------------------------------------
// Slider (Rslider) with a value readout
// ---------------------------------------------------------------------------

pub const Slider = struct {
    pub const Config = struct {
        min: f32 = 0.0,
        max: f32 = 1.0,
        value: f32 = 0.0,
        step: f32 = 0.0,
        vertical: bool = false,
    };

    /// Repairs a Config: finite range with max > min (inverted or empty ranges
    /// become min..min+1), value clamped into [min, max] (NaN gives min), and
    /// a step that is not positive becomes 0 (continuous).
    pub fn sanitize(cfg: Config) Config {
        var out = cfg;
        out.min = finiteOr(out.min, 0.0);
        out.max = finiteOr(out.max, out.min + 1.0);
        if (!(out.max > out.min)) out.max = out.min + 1.0;
        out.value = std.math.clamp(finiteOr(out.value, out.min), out.min, out.max);
        out.step = if (out.step > 0.0 and std.math.isFinite(out.step)) out.step else 0.0;
        return out;
    }

    /// Called after the user changes the value (or the caller sets it).
    pub const ChangedFn = *const fn (slider: *Slider, value: f32) void;

    cfg: Config = .{},
    root: Rid = raven.invalid,
    slider: Rid = raven.invalid,
    readout: Rid = raven.invalid,
    readout_buf: [32:0]u8 = std.mem.zeroes([32:0]u8),
    on_changed: ?ChangedFn = null,

    pub fn init(self: *Slider, cfg: Config) Error!void {
        self.cfg = sanitize(cfg);
        self.root = try created(raven.Rwidget_create(.hbox));
        self.slider = try created(raven.Rwidget_create(.slider));
        self.readout = try created(raven.Rlabel_create(""));

        raven.Rslider_set_orientation(self.slider, if (self.cfg.vertical) .vertical else .horizontal);
        raven.Rslider_set_range(self.slider, self.cfg.min, self.cfg.max);
        raven.Rslider_set_step(self.slider, self.cfg.step);
        raven.Rslider_set_value(self.slider, self.cfg.value);
        raven.Rslider_set_changed_callback(self.slider, onSliderChanged, self);
        // Glass track and accent fill come from the theme; the handle is a
        // translucent glass knob with the accent on hover.
        style.setColor(self.slider, .track, theme.withAlpha(theme.bg_panel, theme.glassAlpha(.base)));
        style.setColor(self.slider, .accent, theme.accent);
        style.setColor(self.slider, .handle, theme.withAlpha(theme.text, 0.9));
        style.setColor(self.slider, .handle_hovered, theme.accent);
        raven.Rwidget_set_metric(self.slider, .slider_handle_size, 14.0);

        style.styleLabel(self.readout, theme.font_body_px);
        raven.Rslot_set_fill(self.slider, 1.0);

        try addChild(self.root, self.slider);
        try addChild(self.root, self.readout);
        self.refreshReadout();
    }

    /// Current value (matches what the slider shows).
    pub fn value(self: *const Slider) f32 {
        return self.cfg.value;
    }

    /// Sets the value from the program: clamped, no changed callback.
    pub fn setValue(self: *Slider, v: f32) void {
        self.cfg.value = std.math.clamp(finiteOr(v, self.cfg.min), self.cfg.min, self.cfg.max);
        raven.Rslider_set_value(self.slider, self.cfg.value);
        self.refreshReadout();
    }

    fn refreshReadout(self: *Slider) void {
        const text = std.mem.printSentinel(&self.readout_buf, "{d:.2}", .{self.cfg.value}, 0) catch |err| {
            std.log.warn("slider readout not updated: {}", .{err});
            return;
        };
        raven.Rlabel_set_text(self.readout, text.ptr);
    }

    fn onSliderChanged(slider: Rid, v: f32, user_data: ?*anyopaque) callconv(.c) void {
        _ = slider;
        const self: *Slider = @ptrCast(@alignCast(user_data orelse return));
        self.cfg.value = std.math.clamp(finiteOr(v, self.cfg.min), self.cfg.min, self.cfg.max);
        self.refreshReadout();
        if (self.on_changed) |cb| cb(self, self.cfg.value);
    }
};

// ---------------------------------------------------------------------------
// Stepper: "-" value "+"
// ---------------------------------------------------------------------------

pub const Stepper = struct {
    pub const Config = struct {
        min: i32 = 0,
        max: i32 = 100,
        value: i32 = 0,
        step: i32 = 1,
        wrap: bool = false,
    };

    /// Repairs a Config: an inverted range becomes min..min, a step that is not
    /// positive becomes 1, and value is clamped into [min, max].
    pub fn sanitize(cfg: Config) Config {
        var out = cfg;
        if (out.max < out.min) out.max = out.min;
        if (out.step <= 0) out.step = 1;
        out.value = std.math.clamp(out.value, out.min, out.max);
        return out;
    }

    /// The value after one "+" press. At max it stays at max, or wraps to min
    /// when cfg.wrap is set.
    pub fn increment(cfg: Config, current: i32) i32 {
        const v = std.math.clamp(current, cfg.min, cfg.max);
        const next = @as(i64, v) + cfg.step;
        if (next <= cfg.max) return @intCast(next);
        return if (cfg.wrap) cfg.min else cfg.max;
    }

    /// The value after one "-" press. At min it stays at min, or wraps to max
    /// when cfg.wrap is set.
    pub fn decrement(cfg: Config, current: i32) i32 {
        const v = std.math.clamp(current, cfg.min, cfg.max);
        const next = @as(i64, v) - cfg.step;
        if (next >= cfg.min) return @intCast(next);
        return if (cfg.wrap) cfg.max else cfg.min;
    }

    /// Called after the value changes by a button press.
    pub const ChangedFn = *const fn (stepper: *Stepper, value: i32) void;

    cfg: Config = .{},
    root: Rid = raven.invalid,
    minus: Rid = raven.invalid,
    plus: Rid = raven.invalid,
    readout: Rid = raven.invalid,
    readout_buf: [24:0]u8 = std.mem.zeroes([24:0]u8),
    on_changed: ?ChangedFn = null,

    pub fn init(self: *Stepper, cfg: Config) Error!void {
        self.cfg = sanitize(cfg);
        self.root = try created(raven.Rwidget_create(.hbox));
        self.minus = try created(raven.Rbutton_create("-"));
        self.readout = try created(raven.Rlabel_create(""));
        self.plus = try created(raven.Rbutton_create("+"));

        for ([_]Rid{ self.minus, self.plus }) |b| {
            raven.Rbutton_set_style(b, .flat);
            raven.Rbutton_set_clicked_callback(b, onButtonClicked, self);
            raven.Rwidget_set_metric(b, .corner_radius, theme.clampRadius(theme.radius_control));
            raven.Rwidget_set_metric(b, .font_size, theme.clampFontSize(theme.font_title_px));
            style.setColor(b, .accent_text, theme.text_on_accent);
            style.setColor(b, .text, theme.text);
        }
        style.styleLabel(self.readout, theme.font_title_px);
        raven.Rlabel_set_text_align(self.readout, .center);

        try addChild(self.root, self.minus);
        try addChild(self.root, self.readout);
        try addChild(self.root, self.plus);
        self.refresh();
    }

    /// Current value.
    pub fn value(self: *const Stepper) i32 {
        return self.cfg.value;
    }

    /// Sets the value from the program: clamped, no changed callback.
    pub fn setValue(self: *Stepper, v: i32) void {
        self.cfg.value = std.math.clamp(v, self.cfg.min, self.cfg.max);
        self.refresh();
    }

    fn refresh(self: *Stepper) void {
        const text = std.mem.printSentinel(&self.readout_buf, "{d}", .{self.cfg.value}, 0) catch |err| {
            std.log.warn("stepper readout not updated: {}", .{err});
            return;
        };
        raven.Rlabel_set_text(self.readout, text.ptr);
        // Without wrap, a button at its end of the range is disabled.
        setEnabled(self.minus, self.cfg.wrap or self.cfg.value > self.cfg.min);
        setEnabled(self.plus, self.cfg.wrap or self.cfg.value < self.cfg.max);
    }

    fn onButtonClicked(button: Rid, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Stepper = @ptrCast(@alignCast(user_data orelse return));
        const before = self.cfg.value;
        self.cfg.value = if (button == self.plus)
            increment(self.cfg, before)
        else
            decrement(self.cfg, before);
        if (self.cfg.value == before) return;
        self.refresh();
        if (self.on_changed) |cb| cb(self, self.cfg.value);
    }
};

// ---------------------------------------------------------------------------
// Progress: Rprogress_bar on a glass track
// ---------------------------------------------------------------------------

pub const Progress = struct {
    pub const Config = struct {
        value: f32 = 0.0,
        height: f32 = 6.0,
    };

    /// Value clamped to [0, 1] (NaN gives 0). Height below 4 becomes 4
    /// (NaN gives 4).
    pub fn sanitize(cfg: Config) Config {
        var out = cfg;
        out.value = if (std.math.isNan(out.value)) 0.0 else std.math.clamp(out.value, 0.0, 1.0);
        out.height = if (std.math.isNan(out.height)) 4.0 else @max(out.height, 4.0);
        return out;
    }

    cfg: Config = .{},
    track: Rid = raven.invalid,
    bar: Rid = raven.invalid,

    pub fn init(self: *Progress, cfg: Config) Error!void {
        self.cfg = sanitize(cfg);
        self.track = try created(raven.Rwidget_create(.border));
        self.bar = try created(raven.Rwidget_create(.progressbar));

        style.styleGlassBorder(self.track, .base, theme.radius_control);
        raven.Rwidget_set_min_size(self.track, 0.0, self.cfg.height);
        // The track is the glass; the bar draws only the fill on top of it.
        style.setColor(self.bar, .track, theme.Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 });
        style.setColor(self.bar, .accent, theme.accent);
        raven.Rprogress_bar_set_value(self.bar, self.cfg.value);

        try addChild(self.track, self.bar);
    }

    /// Sets the fraction from the program (clamped).
    pub fn setValue(self: *Progress, v: f32) void {
        self.cfg.value = if (std.math.isNan(v)) 0.0 else std.math.clamp(v, 0.0, 1.0);
        raven.Rprogress_bar_set_value(self.bar, self.cfg.value);
    }

    pub fn value(self: *const Progress) f32 {
        return raven.Rprogress_bar_get_value(self.bar);
    }
};

// ---------------------------------------------------------------------------
// Segmented control
// ---------------------------------------------------------------------------

pub const Segmented = struct {
    /// Upper bound on segments, so the button ids live in a fixed array.
    pub const max_segments = 16;

    pub const Config = struct {
        labels: []const [:0]const u8 = &.{},
        selected: i32 = 0,
        segment_min_width: f32 = 64.0,
        radius: f32 = theme.radius_control,
    };

    /// Clamps the selection into [0, count - 1]; -1 when there are no segments.
    pub fn clampSelected(count: usize, index: i32) i32 {
        if (count == 0) return -1;
        const last: i32 = @intCast(count - 1);
        return std.math.clamp(index, 0, last);
    }

    /// Minimum width is never negative (NaN gives 0).
    pub fn sanitizeWidth(width: f32) f32 {
        return if (std.math.isNan(width)) 0.0 else @max(width, 0.0);
    }

    /// Called after the selected segment changes by a click.
    pub const ChangedFn = *const fn (segmented: *Segmented, index: i32) void;

    cfg: Config = .{},
    root: Rid = raven.invalid,
    buttons: [max_segments]Rid = @splat(raven.invalid),
    count: usize = 0,
    on_changed: ?ChangedFn = null,

    pub fn init(self: *Segmented, cfg: Config) Error!void {
        if (cfg.labels.len > max_segments) return error.TooManySegments;
        self.cfg = cfg;
        self.cfg.selected = clampSelected(cfg.labels.len, cfg.selected);
        self.cfg.segment_min_width = sanitizeWidth(cfg.segment_min_width);
        self.count = cfg.labels.len;

        self.root = try created(raven.Rwidget_create(.border));
        style.styleGlassBorder(self.root, .raised, self.cfg.radius);
        const row = try created(raven.Rwidget_create(.hbox));

        for (cfg.labels, 0..) |label, i| {
            const b = try created(raven.Rbutton_create(label.ptr));
            self.buttons[i] = b;
            raven.Rbutton_set_clicked_callback(b, onSegmentClicked, self);
            raven.Rwidget_set_min_size(b, self.cfg.segment_min_width, 0.0);
            raven.Rwidget_set_metric(b, .font_size, theme.clampFontSize(theme.font_body_px));
            raven.Rwidget_set_metric(b, .corner_radius, self.cfg.radius);
            // Flat segments are transparent so the glass shows through.
            style.setColor(b, .control, theme.Color{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 });
            style.setColor(b, .text, theme.text);
            style.setColor(b, .accent_text, theme.text_on_accent);
            style.setColor(b, .accent, theme.accent);
            raven.Rslot_set_fill(b, 1.0);
            try addChild(row, b);
        }
        try addChild(self.root, row);
        self.applyStyles();
    }

    /// The selected index, or -1 when there are no segments.
    pub fn selected(self: *const Segmented) i32 {
        return self.cfg.selected;
    }

    /// Selects from the program (clamped), no changed callback.
    pub fn select(self: *Segmented, index: i32) void {
        self.cfg.selected = clampSelected(self.count, index);
        self.applyStyles();
    }

    fn applyStyles(self: *Segmented) void {
        for (self.buttons[0..self.count], 0..) |b, i| {
            const active = @as(i32, @intCast(i)) == self.cfg.selected;
            raven.Rbutton_set_style(b, if (active) .primary else .flat);
        }
    }

    fn onSegmentClicked(button: Rid, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Segmented = @ptrCast(@alignCast(user_data orelse return));
        for (self.buttons[0..self.count], 0..) |b, i| {
            if (b != button) continue;
            const index: i32 = @intCast(i);
            if (index == self.cfg.selected) return;
            self.select(index);
            if (self.on_changed) |cb| cb(self, index);
            return;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests: configuration and pure logic.
// ---------------------------------------------------------------------------

test "slider configuration: defaults and clamping" {
    const d = Slider.Config{};
    try testing.expectEqual(@as(f32, 0.0), d.min);
    try testing.expectEqual(@as(f32, 1.0), d.max);
    try testing.expectEqual(@as(f32, 0.0), d.value);
    try testing.expectEqual(@as(f32, 0.0), d.step);
    try testing.expect(!d.vertical);

    // value clamped into [min, max]
    try testing.expectEqual(@as(f32, 1.0), Slider.sanitize(.{ .value = 3.0 }).value);
    try testing.expectEqual(@as(f32, 0.0), Slider.sanitize(.{ .value = -3.0 }).value);
    try testing.expectEqual(@as(f32, 0.0), Slider.sanitize(.{ .value = std.math.nan(f32) }).value);

    // inverted range repaired to min..min+1
    const inv = Slider.sanitize(.{ .min = 5.0, .max = 2.0, .value = 10.0 });
    try testing.expectEqual(@as(f32, 5.0), inv.min);
    try testing.expectEqual(@as(f32, 6.0), inv.max);
    try testing.expectEqual(@as(f32, 6.0), inv.value);
    const empty = Slider.sanitize(.{ .min = 2.0, .max = 2.0 });
    try testing.expectEqual(@as(f32, 3.0), empty.max);

    // negative step becomes 0
    try testing.expectEqual(@as(f32, 0.0), Slider.sanitize(.{ .step = -0.5 }).step);
    try testing.expectEqual(@as(f32, 0.25), Slider.sanitize(.{ .step = 0.25 }).step);
}

test "stepper configuration: defaults and clamping" {
    const d = Stepper.Config{};
    try testing.expectEqual(@as(i32, 0), d.min);
    try testing.expectEqual(@as(i32, 100), d.max);
    try testing.expectEqual(@as(i32, 1), d.step);
    try testing.expect(!d.wrap);

    // value clamps into range
    try testing.expectEqual(@as(i32, 100), Stepper.sanitize(.{ .value = 250 }).value);
    try testing.expectEqual(@as(i32, 0), Stepper.sanitize(.{ .value = -7 }).value);

    // step <= 0 becomes 1
    try testing.expectEqual(@as(i32, 1), Stepper.sanitize(.{ .step = 0 }).step);
    try testing.expectEqual(@as(i32, 1), Stepper.sanitize(.{ .step = -4 }).step);
    try testing.expectEqual(@as(i32, 5), Stepper.sanitize(.{ .step = 5 }).step);

    // increment at max stays at max, or wraps to min
    const plain = Stepper.Config{ .min = 0, .max = 10, .value = 10 };
    try testing.expectEqual(@as(i32, 10), Stepper.increment(plain, 10));
    try testing.expectEqual(@as(i32, 0), Stepper.decrement(plain, 0));
    const wrapping = Stepper.Config{ .min = 0, .max = 10, .value = 10, .wrap = true };
    try testing.expectEqual(@as(i32, 0), Stepper.increment(wrapping, 10));
    try testing.expectEqual(@as(i32, 10), Stepper.decrement(wrapping, 0));
    try testing.expectEqual(@as(i32, 4), Stepper.increment(plain, 3));
    // a step that would pass max is capped at max
    const big = Stepper.Config{ .min = 0, .max = 10, .step = 4 };
    try testing.expectEqual(@as(i32, 10), Stepper.increment(big, 8));
}

test "progress configuration: defaults and clamping" {
    const d = Progress.Config{};
    try testing.expectEqual(@as(f32, 0.0), d.value);
    try testing.expectEqual(@as(f32, 6.0), d.height);

    try testing.expectEqual(@as(f32, 1.0), Progress.sanitize(.{ .value = 4.0 }).value);
    try testing.expectEqual(@as(f32, 0.0), Progress.sanitize(.{ .value = -1.0 }).value);
    try testing.expectEqual(@as(f32, 0.0), Progress.sanitize(.{ .value = std.math.nan(f32) }).value);
    try testing.expectEqual(@as(f32, 0.5), Progress.sanitize(.{ .value = 0.5 }).value);

    try testing.expectEqual(@as(f32, 4.0), Progress.sanitize(.{ .height = 1.0 }).height);
    try testing.expectEqual(@as(f32, 4.0), Progress.sanitize(.{ .height = 4.0 }).height);
    try testing.expectEqual(@as(f32, 9.0), Progress.sanitize(.{ .height = 9.0 }).height);
}

test "segmented configuration: defaults and clamping" {
    const d = Segmented.Config{};
    try testing.expectEqual(@as(usize, 0), d.labels.len);
    try testing.expectEqual(@as(i32, 0), d.selected);
    try testing.expectEqual(@as(f32, 64.0), d.segment_min_width);
    try testing.expectEqual(@as(f32, 10.0), d.radius);

    // selected clamps into [0, labels.len - 1], -1 when empty
    try testing.expectEqual(@as(i32, -1), Segmented.clampSelected(0, 0));
    try testing.expectEqual(@as(i32, -1), Segmented.clampSelected(0, 5));
    try testing.expectEqual(@as(i32, 2), Segmented.clampSelected(3, 2));
    try testing.expectEqual(@as(i32, 2), Segmented.clampSelected(3, 9));
    try testing.expectEqual(@as(i32, 0), Segmented.clampSelected(3, -4));

    // radius clamped to 10..14 (theme.clampRadius)
    try testing.expectEqual(@as(f32, 10.0), theme.clampRadius(2.0));
    try testing.expectEqual(@as(f32, 14.0), theme.clampRadius(30.0));
    try testing.expectEqual(@as(f32, 12.0), theme.clampRadius(12.0));
}
