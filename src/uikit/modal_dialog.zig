//! uikit/modal_dialog: a modal sheet with title, content and Ok/Cancel, opened on a window.
//!
//! Mode: retained. The sheet is a widget tree (border -> column -> message and
//! button row) handed to Raven with Rdialog_open (asynchronous) or Rdialog_run
//! (blocks until closed). Raven draws the veil over the window and the sheet in
//! the middle; nothing here repaints per frame, so no immediate-mode drawing is used.
//! Raven externs declared in this file: Rdialog_open, Rdialog_close, Rdialog_run.
//! The sheet body uses the Raven widget externs in raven.zig: Rwidget_create,
//! Rbutton_create, Rlabel_create, Rborder_set_* (glass fill, 1 px outline as the
//! top highlight, soft shadow, corner radius), Rwidget_set_color (ACCENT and
//! ACCENT_TEXT for the active button) and Rwidget_set_metric.
//! Escape dismisses the sheet with result 0, which is Cancel.
//!
//! Liquid glass: translucent layered fills (theme.glassAlpha(.overlay)), 1 px top
//! highlight, soft shadow, radius 10..14, accent for the active state, text never
//! below 12 px (theme.min_font_px).
//!
//! Status: implemented. Pure logic (clamping, focus order, results, labels) is
//! tested below; open and run build the retained Raven tree.
const std = @import("std");
const testing = std.testing;
const theme = @import("theme.zig");
const raven = @import("raven.zig");

// raven_dialogs.h. Rid and the callback types come from raven.zig.
pub extern fn Rdialog_open(window: raven.Rid, content: raven.Rid, closed: ?raven.DialogClosedCallback, user_data: ?*anyopaque) void;
pub extern fn Rdialog_close(widget: raven.Rid, result: c_int) void;
pub extern fn Rdialog_run(window: raven.Rid, content: raven.Rid) c_int;

/// Result of the sheet. The values are what Raven hands back: 0 when dismissed
/// (Escape), so Cancel and Escape are the same result.
pub const Result = enum(c_int) {
    cancel = 0,
    ok = 1,
};

/// The two buttons, in visual order from left to right.
pub const Button = enum {
    cancel,
    ok,
};

/// Number of buttons in the sheet (focus cycles over these).
pub const button_count: usize = 2;

/// Sheet width in logical px: default and the allowed range.
pub const default_width: f32 = 420.0;
pub const min_width: f32 = 240.0;
pub const max_width: f32 = 720.0;

/// Padding inside the sheet, logical px.
const padding_px: f32 = 20.0;
/// Gap between rows of the sheet and between buttons, logical px.
const row_gap_px: f32 = 12.0;
const button_gap_px: f32 = 8.0;

pub const Config = struct {
    title: [:0]const u8 = "",
    /// Body text shown under the title. Empty: no message label.
    message: [:0]const u8 = "",
    ok_label: [:0]const u8 = "OK",
    cancel_label: [:0]const u8 = "Cancel",
    width: f32 = default_width,
    radius: f32 = theme.radius_panel,
    font_px: f32 = theme.font_body_px,
    title_px: f32 = theme.font_title_px,
    /// The button that Enter activates.
    default_button: Button = .ok,
};

/// Callback when the sheet closes: `result` is what the user chose.
pub const ClosedCallback = *const fn (result: Result, user_data: ?*anyopaque) void;

/// Clamps a sheet width into [min_width, max_width]. NaN gives min_width.
pub fn clampWidth(width: f32) f32 {
    // Negated comparison so that NaN fails and takes the minimum.
    if (!(width >= min_width)) return min_width;
    if (width > max_width) return max_width;
    return width;
}

/// Returns a copy of `cfg` with every metric made valid: width clamped to
/// min_width..max_width, radius to theme.radius_min..radius_max, and font sizes
/// raised to theme.min_font_px. Labels and the default button are unchanged.
pub fn sanitize(cfg: Config) Config {
    var out = cfg;
    out.width = clampWidth(cfg.width);
    out.radius = theme.clampRadius(cfg.radius);
    out.font_px = theme.clampFontSize(cfg.font_px);
    out.title_px = theme.clampFontSize(cfg.title_px);
    return out;
}

/// Index of a button in the focus order: cancel is 0, ok is 1.
pub fn buttonIndex(button: Button) usize {
    return switch (button) {
        .cancel => 0,
        .ok => 1,
    };
}

/// Button at a focus index, or null when the index is out of range.
pub fn buttonFromIndex(index: usize) ?Button {
    return switch (index) {
        0 => .cancel,
        1 => .ok,
        else => null,
    };
}

/// Focus index of the button that Enter activates for this config.
pub fn defaultButtonIndex(cfg: Config) usize {
    return buttonIndex(cfg.default_button);
}

/// Next focus index, cycling over button_count. Forward from the last button
/// wraps to the first; backward from the first wraps to the last.
pub fn focusNext(current: usize, forward: bool) usize {
    if (forward) return (current + 1) % button_count;
    return (current + button_count - 1) % button_count;
}

/// Result returned when `button` is chosen.
pub fn resultFor(button: Button) Result {
    return switch (button) {
        .cancel => .cancel,
        .ok => .ok,
    };
}

/// Result returned when the sheet is dismissed with Escape.
pub fn resultFromEscape() Result {
    return .cancel;
}

/// Label shown on `button`, from the config.
pub fn buttonLabel(cfg: Config, button: Button) [:0]const u8 {
    return switch (button) {
        .cancel => cfg.cancel_label,
        .ok => cfg.ok_label,
    };
}

/// True for the focused button only: it gets the accent (active state).
pub fn isActive(focused: usize, index: usize) bool {
    return focused == index;
}

/// Fill alpha of the sheet: it sits on the overlay glass layer.
pub fn fillAlpha() f32 {
    return theme.glassAlpha(.overlay);
}

/// Converts the raw value Raven hands back. Only 1 is Ok; anything else,
/// including the 0 of a dismissal, is Cancel.
fn resultFromRaw(raw: c_int) Result {
    return if (raw == @backingInt(Result.ok)) .ok else .cancel;
}

// Open sheets that have a close callback. Raven gets a pointer to a slot as
// user_data, so the trampoline can find the Zig callback again. The UI runs on
// one thread, so plain module state is enough; the pool is fixed-size, so no
// allocation happens here.
const max_open_sheets: usize = 8;

const Pending = struct {
    in_use: bool = false,
    on_close: ?ClosedCallback = null,
    user_data: ?*anyopaque = null,
};

var pending: [max_open_sheets]Pending = @splat(.{});

fn claimSlot(on_close: ClosedCallback, user_data: ?*anyopaque) ?*Pending {
    for (&pending) |*slot| {
        if (!slot.in_use) {
            slot.* = .{ .in_use = true, .on_close = on_close, .user_data = user_data };
            return slot;
        }
    }
    return null;
}

fn onSheetClosed(content: raven.Rid, result: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = content;
    const raw = user_data orelse return;
    const slot: *Pending = @ptrCast(@alignCast(raw));
    const callback = slot.on_close;
    const data = slot.user_data;
    slot.* = .{};
    if (callback) |cb| cb(resultFromRaw(result), data);
}

fn onOkClicked(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    Rdialog_close(button, @backingInt(resultFor(.ok)));
}

fn onCancelClicked(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    Rdialog_close(button, @backingInt(resultFor(.cancel)));
}

fn setColor(widget: raven.Rid, role: raven.ColorRole, c: theme.Color) void {
    raven.Rwidget_set_color(widget, role, c.r, c.g, c.b, c.a);
}

fn setTextColor(label: raven.Rid, c: theme.Color) void {
    raven.Rlabel_set_color(label, c.r, c.g, c.b, c.a);
}

/// One button of the sheet. The active (focused) button gets the accent; the
/// clicked callback closes the sheet with that button's result.
fn buildButton(cfg: Config, button: Button, active: bool) raven.Rid {
    const widget = raven.Rbutton_create(buttonLabel(cfg, button).ptr);
    raven.Rwidget_set_focusable(widget, 1);
    raven.Rwidget_set_metric(widget, .font_size, cfg.font_px);
    raven.Rwidget_set_metric(widget, .corner_radius, cfg.radius);
    const style: raven.ButtonStyle = if (button == cfg.default_button) .primary else .default;
    raven.Rbutton_set_style(widget, style);
    if (active) {
        setColor(widget, .accent, theme.accent);
        setColor(widget, .accent_text, theme.text_on_accent);
    }
    const cb: raven.ClickedCallback = if (button == .ok) onOkClicked else onCancelClicked;
    raven.Rbutton_set_clicked_callback(widget, cb, null);
    return widget;
}

/// Builds the retained sheet tree: glass border, then a column with the title,
/// the message and the button row (cancel left, ok right).
fn buildContent(cfg: Config) raven.Rid {
    const sheet = raven.Rwidget_create(.border);
    const column = raven.Rwidget_create(.vbox);
    _ = raven.Rwidget_add_child(sheet, column);
    raven.Rwidget_set_metric(column, .spacing, row_gap_px);

    // Glass: translucent layered fill, 1 px outline as the top highlight, soft shadow.
    const fill = theme.withAlpha(theme.bg_panel, fillAlpha());
    raven.Rborder_set_background(sheet, fill.r, fill.g, fill.b, fill.a);
    raven.Rborder_set_material(sheet, .frosted_glass);
    const hl = theme.highlight;
    raven.Rborder_set_outline(sheet, theme.highlight_px, hl.r, hl.g, hl.b, hl.a);
    raven.Rborder_set_corner_radius(sheet, cfg.radius, cfg.radius, cfg.radius, cfg.radius);
    raven.Rborder_set_shadow(sheet, theme.shadow_blur_px, 0.0, theme.shadow_offset_y_px);
    raven.Rborder_set_padding(sheet, padding_px, padding_px, padding_px, padding_px);
    setColor(sheet, .shadow, theme.shadow);
    raven.Rwidget_set_min_size(sheet, cfg.width, 0.0);

    if (cfg.title.len > 0) {
        const title = raven.Rlabel_create(cfg.title.ptr);
        raven.Rlabel_set_text_size(title, cfg.title_px);
        setTextColor(title, theme.text);
        _ = raven.Rwidget_add_child(column, title);
    }
    if (cfg.message.len > 0) {
        const message = raven.Rlabel_create(cfg.message.ptr);
        raven.Rlabel_set_text_size(message, cfg.font_px);
        setTextColor(message, theme.text_muted);
        _ = raven.Rwidget_add_child(column, message);
    }

    const row = raven.Rwidget_create(.hbox);
    raven.Rwidget_set_metric(row, .spacing, button_gap_px);
    _ = raven.Rwidget_add_child(column, row);
    const focused = defaultButtonIndex(cfg);
    for ([_]Button{ .cancel, .ok }) |button| {
        _ = raven.Rwidget_add_child(row, buildButton(cfg, button, isActive(focused, buttonIndex(button))));
    }
    return sheet;
}

/// Opens the sheet on `window` and returns the sheet's content widget.
/// Returns at once; `on_close` is called when the sheet closes. Returns
/// raven.invalid, and shows nothing, when all open-sheet slots are in use
/// (the callback could not be delivered).
pub fn open(window: raven.Rid, cfg: Config, on_close: ClosedCallback, user_data: ?*anyopaque) raven.Rid {
    const slot = claimSlot(on_close, user_data) orelse return raven.invalid;
    const content = buildContent(sanitize(cfg));
    Rdialog_open(window, content, onSheetClosed, @ptrCast(slot));
    return content;
}

/// Opens the sheet on `window` and waits until it closes. Returns the result.
pub fn run(window: raven.Rid, cfg: Config) Result {
    const content = buildContent(sanitize(cfg));
    return resultFromRaw(Rdialog_run(window, content));
}

test "modal configuration: defaults" {
    const cfg = Config{};
    try testing.expectEqualStrings("", cfg.title);
    try testing.expectEqualStrings("OK", cfg.ok_label);
    try testing.expectEqualStrings("Cancel", cfg.cancel_label);
    try testing.expectEqual(@as(f32, 420.0), cfg.width);
    try testing.expectEqual(theme.radius_panel, cfg.radius);
    try testing.expectEqual(@as(f32, 13.0), cfg.font_px);
    try testing.expectEqual(@as(f32, 16.0), cfg.title_px);
    try testing.expectEqual(Button.ok, cfg.default_button);
}

test "modal width clamps to 240..720" {
    try testing.expectEqual(@as(f32, 240.0), clampWidth(100.0));
    try testing.expectEqual(@as(f32, 240.0), clampWidth(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 420.0), clampWidth(420.0));
    try testing.expectEqual(@as(f32, 720.0), clampWidth(2000.0));
}

test "modal sanitize keeps font sizes at 12 px or more" {
    const cfg = sanitize(.{ .font_px = 8.0, .title_px = 0.0 });
    try testing.expectEqual(@as(f32, 12.0), cfg.font_px);
    try testing.expectEqual(@as(f32, 12.0), cfg.title_px);

    const big = sanitize(.{ .font_px = 15.0, .title_px = 20.0 });
    try testing.expectEqual(@as(f32, 15.0), big.font_px);
    try testing.expectEqual(@as(f32, 20.0), big.title_px);
}

test "modal sanitize clamps the radius to 10..14" {
    try testing.expectEqual(theme.radius_min, sanitize(.{ .radius = 4.0 }).radius);
    try testing.expectEqual(theme.radius_max, sanitize(.{ .radius = 40.0 }).radius);
    try testing.expectEqual(@as(f32, 12.0), sanitize(.{ .radius = 12.0 }).radius);
}

test "modal sanitize keeps labels and default button" {
    const cfg = sanitize(.{ .ok_label = "Save", .cancel_label = "Discard", .default_button = .cancel });
    try testing.expectEqualStrings("Save", cfg.ok_label);
    try testing.expectEqualStrings("Discard", cfg.cancel_label);
    try testing.expectEqual(Button.cancel, cfg.default_button);
}

test "modal button indices: cancel is left (0), ok is right (1)" {
    try testing.expectEqual(@as(usize, 0), buttonIndex(.cancel));
    try testing.expectEqual(@as(usize, 1), buttonIndex(.ok));
    try testing.expectEqual(button_count, 2);
}

test "modal buttonFromIndex round-trips and rejects out of range" {
    try testing.expectEqual(@as(?Button, .cancel), buttonFromIndex(0));
    try testing.expectEqual(@as(?Button, .ok), buttonFromIndex(1));
    try testing.expectEqual(@as(?Button, null), buttonFromIndex(2));
    try testing.expectEqual(@as(?Button, null), buttonFromIndex(99));
}

test "modal default button follows the config" {
    try testing.expectEqual(@as(usize, 1), defaultButtonIndex(.{}));
    try testing.expectEqual(@as(usize, 0), defaultButtonIndex(.{ .default_button = .cancel }));
}

test "modal focusNext cycles forward and backward over both buttons" {
    try testing.expectEqual(@as(usize, 1), focusNext(0, true));
    try testing.expectEqual(@as(usize, 0), focusNext(1, true));
    try testing.expectEqual(@as(usize, 0), focusNext(1, false));
    try testing.expectEqual(@as(usize, 1), focusNext(0, false));
}

test "modal results: ok is 1, cancel and Escape are 0" {
    try testing.expectEqual(Result.ok, resultFor(.ok));
    try testing.expectEqual(Result.cancel, resultFor(.cancel));
    try testing.expectEqual(Result.cancel, resultFromEscape());
    try testing.expectEqual(@as(c_int, 0), @backingInt(resultFromEscape()));
    try testing.expectEqual(@as(c_int, 1), @backingInt(Result.ok));
}

test "modal buttonLabel returns the configured label for each button" {
    const cfg = Config{ .ok_label = "Apply", .cancel_label = "Close" };
    try testing.expectEqualStrings("Apply", buttonLabel(cfg, .ok));
    try testing.expectEqualStrings("Close", buttonLabel(cfg, .cancel));
}

test "modal active state: only the focused button is active" {
    try testing.expect(isActive(1, 1));
    try testing.expect(!isActive(1, 0));
    try testing.expect(isActive(0, 0));
    try testing.expect(!isActive(0, 1));
}

test "modal fill uses the overlay glass layer" {
    try testing.expectApproxEqAbs(theme.glassAlpha(.overlay), fillAlpha(), 1e-3);
}
