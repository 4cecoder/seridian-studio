//! uikit/color_picker: Rcolor_picker (R_WIDGET_COLOR_PICKER, raven_tools.h).
//!
//! Mode: retained. The widget is created with Rcolor_picker_create and placed
//! in the tree with Rwidget_add_child; nothing here repaints per frame. The
//! picker only repaints when its colour changes, so it is not an
//! immediate-mode widget.
//!
//! Visual: a saturation/value square, a hue strip, an opacity strip over a
//! checkerboard, the previous and current colour side by side, a hex code, the
//! RGBA (or HSV) numbers, and a row of swatches. Liquid glass: translucent
//! layered fills (theme.glassAlpha), a 1 px top highlight, a soft shadow,
//! corner radius in [10, 14], the accent colour marks the active state, and no
//! text below 12 px.
//!
//! Raven calls (declared by hand below, no @cImport):
//!   Rcolor_picker_create, Rcolor_picker_set_color, Rcolor_picker_get_color,
//!   Rcolor_picker_set_hsv, Rcolor_picker_get_hsv, Rcolor_picker_set_hex,
//!   Rcolor_picker_get_hex, Rcolor_picker_set_alpha_enabled,
//!   Rcolor_picker_set_previous_color, Rcolor_picker_add_swatch,
//!   Rcolor_picker_clear_swatches, Rcolor_picker_get_swatch_count,
//!   Rcolor_picker_set_popup, Rcolor_picker_set_compact,
//!   Rcolor_picker_set_changed_callback, Rwidget_add_child,
//!   Rwidget_set_color (ACCENT, BORDER, POPUP), Rwidget_set_metric
//!   (CORNER_RADIUS, FONT_SIZE).
//! The pure maths below (hue, saturation/value, hex, swatch index) are written
//! in Zig so they can be tested without Raven.
//!
//! Status: the widget wrapper (Picker) and the pure maths are implemented. The
//! Raven externs are only analysed when Picker methods are referenced, so the
//! pure tests run under `zig test` without linking Raven.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");

// ---------------------------------------------------------------------------
// Raven externs, copied by hand from vendor/raven/include/raven/raven_tools.h
// and raven_widget.h. Enum values are from raven_widget.h.
// ---------------------------------------------------------------------------

/// Opaque Raven handle (uint32_t). `invalid_id` is R_INVALID_ID.
pub const Rid = u32;
const invalid_id: Rid = 0xFFFF_FFFF;

/// RColorRole values used by the picker (raven_widget.h).
const role_border: c_int = 0x0102;
const role_accent: c_int = 0x0106;
const role_popup: c_int = 0x0119;

/// RMetric values used by the picker (raven_widget.h).
const metric_font_size: c_int = 0x0140;
const metric_corner_radius: c_int = 0x0141;

/// RColorChangedCallback: called on every user change, with the new colour.
pub const ChangedCallback = *const fn (picker: Rid, r: f32, g: f32, b: f32, a: f32, user_data: ?*anyopaque) callconv(.c) void;

pub extern fn Rcolor_picker_create() Rid;
pub extern fn Rcolor_picker_set_color(picker: Rid, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rcolor_picker_get_color(picker: Rid, r: *f32, g: *f32, b: *f32, a: *f32) void;
pub extern fn Rcolor_picker_set_hsv(picker: Rid, hue: f32, saturation: f32, value: f32) void;
pub extern fn Rcolor_picker_get_hsv(picker: Rid, hue: *f32, saturation: *f32, value: *f32) void;
pub extern fn Rcolor_picker_set_hex(picker: Rid, text: [*:0]const u8) c_int;
pub extern fn Rcolor_picker_get_hex(picker: Rid) ?[*:0]const u8;
pub extern fn Rcolor_picker_set_alpha_enabled(picker: Rid, enabled: c_int) void;
pub extern fn Rcolor_picker_set_previous_color(picker: Rid, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rcolor_picker_add_swatch(picker: Rid, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rcolor_picker_clear_swatches(picker: Rid) void;
pub extern fn Rcolor_picker_get_swatch_count(picker: Rid) c_int;
pub extern fn Rcolor_picker_set_popup(picker: Rid, popup: c_int) void;
pub extern fn Rcolor_picker_set_compact(picker: Rid, compact: c_int) void;
pub extern fn Rcolor_picker_set_changed_callback(picker: Rid, callback: ChangedCallback, user_data: ?*anyopaque) void;
pub extern fn Rwidget_add_child(parent: Rid, child: Rid) Rid;
pub extern fn Rwidget_set_color(widget: Rid, role: c_int, r: f32, g: f32, b: f32, a: f32) void;
pub extern fn Rwidget_set_metric(widget: Rid, metric: c_int, value: f32) void;

/// Fixed capacity of the swatch row. Raven's own row is unbounded; this one is
/// bounded so the widget never allocates while the UI is live.
pub const max_swatches: usize = 16;

/// Hue in [0, 360), saturation and value in [0, 1].
pub const Hsv = struct {
    h: f32,
    s: f32,
    v: f32,
};

/// Saturation and value, each in [0, 1], read from a point in the square.
pub const SatVal = struct {
    s: f32,
    v: f32,
};

/// Public configuration of the colour picker. Defaults are the accent colour,
/// opaque, the full picker (not a popup, not compact).
pub const Config = struct {
    color: theme.Color = theme.accent,
    alpha_enabled: bool = true,
    popup: bool = false,
    compact: bool = false,
    corner_radius: f32 = theme.radius_control,
    label_px: f32 = theme.font_body_px,
};

/// A colour read from text, and whether the text carried an opacity.
pub const ParsedHex = struct {
    color: theme.Color,
    has_alpha: bool,
};

/// Brings a configuration into the rules of the widget:
///   - each colour channel is clamped into [0, 1] (NaN gives 0)
///   - with alpha_enabled false the opacity is forced to 1
///   - corner_radius is clamped into [radius_min, radius_max] (theme.clampRadius)
///   - label_px is raised to min_font_px (theme.clampFontSize)
pub fn normalise(cfg: Config) Config {
    const c = cfg.color;
    const color = theme.Color{
        .r = clampUnit(c.r),
        .g = clampUnit(c.g),
        .b = clampUnit(c.b),
        .a = if (cfg.alpha_enabled) clampUnit(c.a) else 1.0,
    };
    return .{
        .color = color,
        .alpha_enabled = cfg.alpha_enabled,
        .popup = cfg.popup,
        .compact = cfg.compact,
        .corner_radius = theme.clampRadius(cfg.corner_radius),
        .label_px = theme.clampFontSize(cfg.label_px),
    };
}

test "color_picker configuration: defaults" {
    // Must check:
    //   - default colour is theme.accent, fully opaque
    //   - alpha_enabled true, popup false, compact false
    //   - corner_radius is theme.radius_control (inside [10, 14])
    //   - label_px is theme.font_body_px (13, never below 12)
    const cfg = Config{};
    const normal = normalise(cfg);
    try testing.expectEqual(theme.accent.r, normal.color.r);
    try testing.expectEqual(theme.accent.g, normal.color.g);
    try testing.expectEqual(theme.accent.b, normal.color.b);
    try testing.expectEqual(@as(f32, 1.0), normal.color.a);
    try testing.expect(normal.alpha_enabled);
    try testing.expect(!normal.popup);
    try testing.expect(!normal.compact);
    try testing.expectEqual(theme.radius_control, normal.corner_radius);
    try testing.expectEqual(theme.font_body_px, normal.label_px);
}

test "color_picker configuration: normalise clamps and repairs" {
    // Must check:
    //   - channels above 1 and below 0 are clamped
    //   - corner_radius 4 becomes 10, 30 becomes 14
    //   - label_px 9 becomes 12
    //   - alpha_enabled false forces the opacity to 1
    const raw = Config{
        .color = .{ .r = 1.5, .g = -0.2, .b = 0.5, .a = 0.25 },
        .alpha_enabled = false,
        .corner_radius = 4.0,
        .label_px = 9.0,
    };
    const normal = normalise(raw);
    try testing.expectEqual(@as(f32, 1.0), normal.color.r);
    try testing.expectEqual(@as(f32, 0.0), normal.color.g);
    try testing.expectEqual(@as(f32, 0.5), normal.color.b);
    try testing.expectEqual(@as(f32, 1.0), normal.color.a);
    try testing.expectEqual(theme.radius_min, normal.corner_radius);
    try testing.expectEqual(theme.min_font_px, normal.label_px);

    const big = normalise(Config{ .corner_radius = 30.0 });
    try testing.expectEqual(theme.radius_max, big.corner_radius);
}

test "clampUnit: values land in [0, 1], NaN gives 0" {
    // Must check:
    //   - -1 gives 0, 2 gives 1, 0.5 stays 0.5
    //   - NaN gives 0
    try testing.expectEqual(@as(f32, 0.0), clampUnit(-1.0));
    try testing.expectEqual(@as(f32, 1.0), clampUnit(2.0));
    try testing.expectEqual(@as(f32, 0.5), clampUnit(0.5));
    try testing.expectEqual(@as(f32, 0.0), clampUnit(std.math.nan(f32)));
}

/// Clamps a value into [0, 1]. NaN gives 0.
pub fn clampUnit(v: f32) f32 {
    // Written as a negated >= so that NaN fails the test and takes the floor.
    if (!(v >= 0.0)) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

test "wrapHue: hue wraps into [0, 360)" {
    // Must check:
    //   - -30 gives 330
    //   - 360 gives 0
    //   - 725 gives 5
    //   - NaN gives 0
    try testing.expectEqual(@as(f32, 330.0), wrapHue(-30.0));
    try testing.expectEqual(@as(f32, 0.0), wrapHue(360.0));
    try testing.expectEqual(@as(f32, 5.0), wrapHue(725.0));
    try testing.expectEqual(@as(f32, 0.0), wrapHue(std.math.nan(f32)));
}

/// Wraps a hue into [0, 360). NaN gives 0.
pub fn wrapHue(h: f32) f32 {
    if (!std.math.isFinite(h)) return 0.0;
    const w = @mod(h, 360.0);
    // A tiny negative input can round up to exactly 360; keep the range half-open.
    return if (w >= 360.0) 0.0 else w;
}

test "rgbToHsv and hsvToRgb: primaries and grays" {
    // Must check:
    //   - pure red is hue 0, saturation 1, value 1
    //   - pure blue is hue 240, saturation 1, value 1
    //   - a gray has saturation 0 and keeps its value
    //   - hsvToRgb(rgbToHsv(c)) gives back c within 1e-3, opacity kept
    const red = rgbToHsv(.{ .r = 1.0, .g = 0.0, .b = 0.0 });
    try testing.expectApproxEqAbs(@as(f32, 0.0), red.h, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), red.s, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), red.v, 1e-3);

    const blue = rgbToHsv(.{ .r = 0.0, .g = 0.0, .b = 1.0 });
    try testing.expectApproxEqAbs(@as(f32, 240.0), blue.h, 1e-3);

    const gray = rgbToHsv(.{ .r = 0.4, .g = 0.4, .b = 0.4 });
    try testing.expectApproxEqAbs(@as(f32, 0.0), gray.s, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.4), gray.v, 1e-3);

    const src = theme.Color{ .r = 0.23, .g = 0.51, .b = 0.96, .a = 0.5 };
    const back = hsvToRgb(rgbToHsv(src), src.a);
    try testing.expectApproxEqAbs(src.r, back.r, 1e-3);
    try testing.expectApproxEqAbs(src.g, back.g, 1e-3);
    try testing.expectApproxEqAbs(src.b, back.b, 1e-3);
    try testing.expectApproxEqAbs(src.a, back.a, 1e-3);
}

/// Red, green, blue (0..1, opacity ignored) to hue, saturation, value.
pub fn rgbToHsv(c: theme.Color) Hsv {
    const r = clampUnit(c.r);
    const g = clampUnit(c.g);
    const b = clampUnit(c.b);
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const delta = max_c - min_c;
    const s: f32 = if (max_c > 0.0) delta / max_c else 0.0;
    var h: f32 = 0.0;
    if (delta > 0.0) {
        if (max_c == r) {
            h = 60.0 * @mod((g - b) / delta, 6.0);
        } else if (max_c == g) {
            h = 60.0 * ((b - r) / delta + 2.0);
        } else {
            h = 60.0 * ((r - g) / delta + 4.0);
        }
    }
    return .{ .h = wrapHue(h), .s = s, .v = max_c };
}

/// Hue, saturation, value to a colour with the given opacity (clamped).
pub fn hsvToRgb(hsv: Hsv, alpha: f32) theme.Color {
    const h = wrapHue(hsv.h);
    const s = clampUnit(hsv.s);
    const v = clampUnit(hsv.v);
    const chroma = v * s;
    const sector_f = h / 60.0;
    const x = chroma * (1.0 - @abs(@mod(sector_f, 2.0) - 1.0));
    const m = v - chroma;
    const sector: u8 = @intFromFloat(@min(@floor(sector_f), 5.0));
    const rgb: [3]f32 = switch (sector) {
        0 => .{ chroma, x, 0.0 },
        1 => .{ x, chroma, 0.0 },
        2 => .{ 0.0, chroma, x },
        3 => .{ 0.0, x, chroma },
        4 => .{ x, 0.0, chroma },
        else => .{ chroma, 0.0, x },
    };
    return theme.withAlpha(.{ .r = rgb[0] + m, .g = rgb[1] + m, .b = rgb[2] + m, .a = 1.0 }, alpha);
}

test "formatHex: opacity appears only when shown and not full" {
    // Must check:
    //   - opaque #3B82F6 with show_alpha true gives "#3B82F6" (7 bytes)
    //   - a=0.5 with show_alpha true gives "#3B82F680" (9 bytes)
    //   - a=0.5 with show_alpha false gives "#3B82F6" (7 bytes)
    //   - a=1 with show_alpha true gives "#3B82F6" (7 bytes)
    var buf: [9]u8 = undefined;
    const blue = theme.Color{ .r = (@as(f32, 0x3B) / 255.0), .g = (@as(f32, 0x82) / 255.0), .b = (@as(f32, 0xF6) / 255.0), .a = 1.0 };
    try testing.expectEqualStrings("#3B82F6", formatHex(blue, true, &buf));

    const half = theme.Color{ .r = (@as(f32, 0x3B) / 255.0), .g = (@as(f32, 0x82) / 255.0), .b = (@as(f32, 0xF6) / 255.0), .a = 0.5 };
    try testing.expectEqualStrings("#3B82F680", formatHex(half, true, &buf));
    try testing.expectEqualStrings("#3B82F6", formatHex(half, false, &buf));
}

const hex_digits = "0123456789ABCDEF";

/// A unit channel value to a byte, rounded to the nearest 0..255.
fn byteOf(v: f32) u8 {
    return @intFromFloat(@round(clampUnit(v) * 255.0));
}

fn writeByte(buf: []u8, at: usize, b: u8) void {
    buf[at] = hex_digits[b >> 4];
    buf[at + 1] = hex_digits[b & 0x0F];
}

/// Writes "#RRGGBB" or "#RRGGBBAA" into buf and returns the used slice.
/// Channels are rounded to the nearest 0..255.
pub fn formatHex(c: theme.Color, show_alpha: bool, buf: *[9]u8) []const u8 {
    buf[0] = '#';
    writeByte(buf, 1, byteOf(c.r));
    writeByte(buf, 3, byteOf(c.g));
    writeByte(buf, 5, byteOf(c.b));
    const a = byteOf(c.a);
    if (show_alpha and a != 255) {
        writeByte(buf, 7, a);
        return buf[0..9];
    }
    return buf[0..7];
}

test "parseHex: 3, 6 and 8 digit codes, optional '#', rejects the rest" {
    // Must check:
    //   - "f80" gives #FF8800 (each nibble doubled), no alpha
    //   - "3B82F6" and "#3B82F6" give the same opaque colour
    //   - "#3B82F680" gives a=0x80/255 and has_alpha true
    //   - "#GG0000", "#12345", "" give null
    const short = parseHex("f80") orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 1.0), short.color.r, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, (@as(f32, 0x88) / 255.0)), short.color.g, 1e-3);
    try testing.expectEqual(@as(f32, 0.0), short.color.b);
    try testing.expect(!short.has_alpha);

    const bare = parseHex("3B82F6") orelse return error.TestUnexpectedResult;
    const hashed = parseHex("#3B82F6") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(bare.color.r, hashed.color.r);
    try testing.expectEqual(bare.color.b, hashed.color.b);

    const with_alpha = parseHex("#3B82F680") orelse return error.TestUnexpectedResult;
    try testing.expect(with_alpha.has_alpha);
    try testing.expectApproxEqAbs(@as(f32, (@as(f32, 0x80) / 255.0)), with_alpha.color.a, 1e-3);

    try testing.expect(parseHex("#GG0000") == null);
    try testing.expect(parseHex("#12345") == null);
    try testing.expect(parseHex("") == null);
}

/// One hex digit to its value, or null when the byte is not a hex digit.
fn nibble(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

fn byteToUnit(b: u8) f32 {
    return @as(f32, @floatFromInt(b)) / 255.0;
}

/// Parses "#RGB", "#RRGGBB" or "#RRGGBBAA" (the '#' is optional). Null when the
/// text is not a colour.
pub fn parseHex(text: []const u8) ?ParsedHex {
    const digits = if (text.len > 0 and text[0] == '#') text[1..] else text;
    // out[3] is the opacity; it stays 0xFF unless the code carries one.
    var out: [4]u8 = .{ 0, 0, 0, 0xFF };
    var has_alpha = false;
    switch (digits.len) {
        3 => {
            for (0..3) |i| {
                const n = nibble(digits[i]) orelse return null;
                out[i] = n * 17;
            }
        },
        6, 8 => {
            const channels: usize = digits.len / 2;
            for (0..channels) |i| {
                const hi = nibble(digits[2 * i]) orelse return null;
                const lo = nibble(digits[2 * i + 1]) orelse return null;
                out[i] = (hi << 4) | lo;
            }
            has_alpha = digits.len == 8;
        },
        else => return null,
    }
    return .{
        .color = .{
            .r = byteToUnit(out[0]),
            .g = byteToUnit(out[1]),
            .b = byteToUnit(out[2]),
            .a = byteToUnit(out[3]),
        },
        .has_alpha = has_alpha,
    };
}

test "swatch row: add up to max_swatches, then refuse" {
    // Must check:
    //   - a new row is empty, get(0) is null
    //   - adding max_swatches colours succeeds, count is max_swatches
    //   - one more add returns false and leaves count unchanged
    //   - clear sets count to 0
    var row = Swatches{};
    try testing.expectEqual(@as(usize, 0), row.count());
    try testing.expect(row.get(0) == null);

    var i: usize = 0;
    while (i < max_swatches) : (i += 1) {
        try testing.expect(row.add(.{ .r = 0.0, .g = 0.0, .b = 0.0 }));
    }
    try testing.expectEqual(max_swatches, row.count());
    try testing.expect(!row.add(.{ .r = 1.0, .g = 1.0, .b = 1.0 }));
    try testing.expectEqual(max_swatches, row.count());

    row.clear();
    try testing.expectEqual(@as(usize, 0), row.count());
}

/// Fixed-capacity row of swatch colours. Order is insertion order.
pub const Swatches = struct {
    len: usize = 0,
    items: [max_swatches]theme.Color = undefined,

    /// Appends a colour. False when the row is full (nothing changes).
    pub fn add(self: *Swatches, c: theme.Color) bool {
        if (self.len >= max_swatches) return false;
        self.items[self.len] = c;
        self.len += 1;
        return true;
    }

    /// Removes every colour.
    pub fn clear(self: *Swatches) void {
        self.len = 0;
    }

    /// Number of colours in the row.
    pub fn count(self: *const Swatches) usize {
        return self.len;
    }

    /// The colour at index, or null when index >= count().
    pub fn get(self: *const Swatches, index: usize) ?theme.Color {
        if (index >= self.len) return null;
        return self.items[index];
    }
};

test "swatchIndexAt: grid index maths with gaps" {
    // Layout: cell 24, gap 4, 4 columns, 6 swatches. Cells start at
    // x = col * 28 and y = row * 28, and are 24 px square.
    //   - (0, 0) is index 0
    //   - (23, 23) is still index 0
    //   - (24, 0) is in the gap, null
    //   - (28, 0) is index 1
    //   - (29, 29) is row 1 col 1, index 5
    //   - (57, 29) is row 1 col 2, index 6, which is past count, null
    //   - negative or NaN coordinates, and cols 0, give null
    try testing.expectEqual(@as(?usize, 0), swatchIndexAt(0, 0, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, 0), swatchIndexAt(23, 23, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(24, 0, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, 1), swatchIndexAt(28, 0, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, 5), swatchIndexAt(29, 29, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(57, 29, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(-1, 0, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(std.math.nan(f32), 0, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(0, 0, 24, 4, 0, 6));
}

/// Index of the swatch under local point (x, y), or null when the point is in
/// a gap, outside the grid, or past count. Cells are cell px square, separated
/// by gap px, laid out row-major in cols columns.
pub fn swatchIndexAt(x: f32, y: f32, cell: f32, gap: f32, cols: usize, count: usize) ?usize {
    if (cols == 0) return null;
    // Negated comparisons reject NaN; the finite checks reject an infinite pitch,
    // which would put every point in cell 0.
    if (!(x >= 0.0) or !(y >= 0.0)) return null;
    if (!(cell > 0.0) or !(gap >= 0.0)) return null;
    if (!std.math.isFinite(cell) or !std.math.isFinite(gap)) return null;
    const pitch = cell + gap;
    if (!std.math.isFinite(pitch) or !(pitch > 0.0)) return null;
    const col = indexFromFloor(x / pitch, cols) orelse return null;
    const row = indexFromFloor(y / pitch, count) orelse return null;
    const col_f: f32 = @floatFromInt(col);
    const row_f: f32 = @floatFromInt(row);
    // Reject points that land in the gap after a cell.
    if (x - col_f * pitch >= cell) return null;
    if (y - row_f * pitch >= cell) return null;
    const idx = std.math.mul(usize, row, cols) catch return null;
    const total = std.math.add(usize, idx, col) catch return null;
    if (total >= count) return null;
    return total;
}

/// The cell index for a position already divided by the pitch: floor(v), or
/// null when v is NaN, negative, or at or past `limit`. The float is checked
/// against `limit` before it is converted, so the cast never sees an
/// out-of-range value.
fn indexFromFloor(v: f32, limit: usize) ?usize {
    if (!(v >= 0.0)) return null;
    const floored = @floor(v);
    const limit_f: f32 = @floatFromInt(limit);
    if (!(floored < limit_f)) return null;
    const index: usize = @intFromFloat(floored);
    if (index >= limit) return null;
    return index;
}

test "hueFromX and alphaFromX: strips map a position to a value" {
    // Must check:
    //   - hueFromX(0, 100) is 0, (50, 100) is 180, (150, 100) clamps to 360
    //   - a strip of width 0 gives hue 0
    //   - alphaFromX(25, 100) is 0.25, (-5, 100) clamps to 0
    try testing.expectApproxEqAbs(@as(f32, 0.0), hueFromX(0.0, 100.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 180.0), hueFromX(50.0, 100.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 360.0), hueFromX(150.0, 100.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.0), hueFromX(10.0, 0.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.25), alphaFromX(25.0, 100.0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.0), alphaFromX(-5.0, 100.0), 1e-3);
}

/// The position across a strip as a fraction in [0, 1]. A zero width gives 0.
fn unitFromX(x: f32, width: f32) f32 {
    if (!(width > 0.0)) return 0.0;
    return clampUnit(x / width);
}

/// Hue (0..360) at horizontal position x across a strip of width px.
/// Positions outside the strip are clamped. A zero width gives 0.
pub fn hueFromX(x: f32, width: f32) f32 {
    return 360.0 * unitFromX(x, width);
}

/// Opacity (0..1) at horizontal position x across a strip of width px.
pub fn alphaFromX(x: f32, width: f32) f32 {
    return unitFromX(x, width);
}

test "satValFromPoint: square corners map to saturation and value" {
    // Must check:
    //   - top-left (0, 0) is s 0, v 1
    //   - bottom-right (200, 100) is s 1, v 0 on a 200 x 100 square
    //   - top-right is s 1, v 1
    //   - points outside the square are clamped
    const tl = satValFromPoint(0.0, 0.0, 200.0, 100.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), tl.s, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), tl.v, 1e-3);

    const br = satValFromPoint(200.0, 100.0, 200.0, 100.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), br.s, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.0), br.v, 1e-3);

    const tr = satValFromPoint(200.0, 0.0, 200.0, 100.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), tr.s, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 1.0), tr.v, 1e-3);

    const out = satValFromPoint(-50.0, 500.0, 200.0, 100.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out.s, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.0), out.v, 1e-3);
}

/// Saturation and value at local point (x, y) of a width x height square whose
/// top-left is (0, 0). Saturation grows to the right, value grows upward.
/// Points outside the square are clamped.
pub fn satValFromPoint(x: f32, y: f32, width: f32, height: f32) SatVal {
    return .{
        .s = unitFromX(x, width),
        .v = 1.0 - unitFromX(y, height),
    };
}

// ---------------------------------------------------------------------------
// The Raven widget. Retained: Picker wraps one Raven handle that lives in the
// widget tree. Setters forward to Raven; Raven repaints when the colour moves.
// ---------------------------------------------------------------------------

fn boolToC(b: bool) c_int {
    return if (b) 1 else 0;
}

/// A retained colour picker: one Raven widget handle.
pub const Picker = struct {
    id: Rid,

    /// True when Raven gave a usable handle.
    pub fn isValid(self: Picker) bool {
        return self.id != invalid_id;
    }

    /// Creates the widget with a normalised configuration and the liquid-glass
    /// styling. An invalid handle is returned unchanged in the id, not hidden.
    pub fn create(cfg: Config) Picker {
        const n = normalise(cfg);
        const id = Rcolor_picker_create();
        const p = Picker{ .id = id };
        if (!p.isValid()) return p;

        Rcolor_picker_set_alpha_enabled(id, boolToC(n.alpha_enabled));
        Rcolor_picker_set_popup(id, boolToC(n.popup));
        Rcolor_picker_set_compact(id, boolToC(n.compact));

        // Liquid glass: accent marks the active state, the border is the 1 px
        // top-highlight colour, the popup is a translucent raised layer.
        Rwidget_set_color(id, role_accent, theme.accent.r, theme.accent.g, theme.accent.b, 1.0);
        Rwidget_set_color(id, role_border, theme.highlight.r, theme.highlight.g, theme.highlight.b, theme.highlight.a);
        const panel = theme.withAlpha(theme.bg_panel, theme.glassAlpha(.raised));
        Rwidget_set_color(id, role_popup, panel.r, panel.g, panel.b, panel.a);
        Rwidget_set_metric(id, metric_corner_radius, n.corner_radius);
        Rwidget_set_metric(id, metric_font_size, n.label_px);

        p.setColor(n.color);
        return p;
    }

    /// Places the picker under a parent widget (Rwidget_add_child).
    pub fn attach(self: Picker, parent: Rid) bool {
        if (!self.isValid()) return false;
        return Rwidget_add_child(parent, self.id) != invalid_id;
    }

    /// Sets the colour (channels clamped to [0, 1]). The changed callback is
    /// not called.
    pub fn setColor(self: Picker, c: theme.Color) void {
        if (!self.isValid()) return;
        Rcolor_picker_set_color(self.id, clampUnit(c.r), clampUnit(c.g), clampUnit(c.b), clampUnit(c.a));
    }

    /// The current colour, read back from Raven. Zero when the handle is invalid.
    pub fn color(self: Picker) theme.Color {
        if (!self.isValid()) return .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };
        var r: f32 = 0.0;
        var g: f32 = 0.0;
        var b: f32 = 0.0;
        var a: f32 = 0.0;
        Rcolor_picker_get_color(self.id, &r, &g, &b, &a);
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Sets the colour from hue (0..360), saturation and value (0..1).
    pub fn setHsv(self: Picker, value: Hsv) void {
        if (!self.isValid()) return;
        Rcolor_picker_set_hsv(self.id, wrapHue(value.h), clampUnit(value.s), clampUnit(value.v));
    }

    /// The current colour as hue, saturation and value.
    pub fn hsv(self: Picker) Hsv {
        if (!self.isValid()) return .{ .h = 0.0, .s = 0.0, .v = 0.0 };
        var h: f32 = 0.0;
        var s: f32 = 0.0;
        var v: f32 = 0.0;
        Rcolor_picker_get_hsv(self.id, &h, &s, &v);
        return .{ .h = h, .s = s, .v = v };
    }

    /// Sets the colour from text such as "#3B82F6". False when the text is not a
    /// colour (the colour is unchanged).
    pub fn setHex(self: Picker, text: [:0]const u8) bool {
        if (!self.isValid()) return false;
        return Rcolor_picker_set_hex(self.id, text.ptr) != 0;
    }

    /// The hex code shown by the picker. Valid until the colour changes.
    pub fn hexText(self: Picker) []const u8 {
        if (!self.isValid()) return "";
        const p = Rcolor_picker_get_hex(self.id) orelse return "";
        return std.mem.span(p);
    }

    /// Sets the colour shown beside the current one, to compare against.
    pub fn setPreviousColor(self: Picker, c: theme.Color) void {
        if (!self.isValid()) return;
        Rcolor_picker_set_previous_color(self.id, clampUnit(c.r), clampUnit(c.g), clampUnit(c.b), clampUnit(c.a));
    }

    /// Adds a swatch. False when the row is full (at max_swatches) or the handle
    /// is invalid.
    pub fn addSwatch(self: Picker, c: theme.Color) bool {
        if (!self.isValid()) return false;
        const n = Rcolor_picker_get_swatch_count(self.id);
        if (n < 0) return false;
        if (@as(usize, @intCast(n)) >= max_swatches) return false;
        Rcolor_picker_add_swatch(self.id, clampUnit(c.r), clampUnit(c.g), clampUnit(c.b), clampUnit(c.a));
        return true;
    }

    /// Removes every swatch.
    pub fn clearSwatches(self: Picker) void {
        if (!self.isValid()) return;
        Rcolor_picker_clear_swatches(self.id);
    }

    /// Registers a callback called on every user change of the colour.
    pub fn onChanged(self: Picker, callback: ChangedCallback, user_data: ?*anyopaque) void {
        if (!self.isValid()) return;
        Rcolor_picker_set_changed_callback(self.id, callback, user_data);
    }
};

test "swatchIndexAt: out-of-range and non-finite coordinates give null" {
    const big: f32 = 3.0e38;
    // Far past the grid in either axis, and the largest finite float.
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(1.0e30, 0, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(0, 1.0e30, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(big, big, 24, 4, 4, 6));
    // Infinite coordinates are rejected before any float is converted.
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(std.math.inf(f32), 0, 24, 4, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(0, std.math.inf(f32), 24, 4, 4, 6));
    // A huge count with a valid position still lands on the right cell.
    try testing.expectEqual(@as(?usize, 0), swatchIndexAt(0, 0, 24, 4, 4, std.math.maxInt(usize)));
    // Non-finite layout values: an infinite pitch would put every point in cell 0.
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(5, 5, std.math.inf(f32), 0, 4, 6));
    try testing.expectEqual(@as(?usize, null), swatchIndexAt(5, 5, 24, std.math.inf(f32), 4, 6));
}
