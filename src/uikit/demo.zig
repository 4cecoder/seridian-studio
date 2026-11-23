//! uikit/demo: one window that shows every uikit widget inside a glass card.
//!
//! Mode: retained. Every widget is a Raven widget created with Rwidget_create
//! (or an Rxxx_create shortcut) and placed in the tree by Rwidget_add_child.
//! Nothing here paints, so there is no immediate-mode code in this file. The
//! only loop is Rwait_frame, which Raven needs to run its own retained tree.
//!
//! Raven calls are declared in raven.zig (no @cImport). The widgets come from
//! basic.zig, value.zig, input.zig and container.zig.
//!
//! Run: DISPLAY=:0 ./zig-out/bin/uikit-demo   (zig build uikit-demo)
const std = @import("std");
const theme = @import("theme.zig");
const style = @import("style.zig");
const raven = @import("raven.zig");
const basic = @import("basic.zig");
const value = @import("value.zig");
const input = @import("input.zig");
const container = @import("container.zig");
const drag_drop = @import("drag_drop.zig");

const Rid = raven.Rid;

// Raven application and window calls (raven.zig).
const backend_vulkan = raven.backend_vulkan;
const InitDesc = raven.InitDesc;

const Error = value.Error || input.BuildError || error{ InitFailed, WindowFailed };

// The window title contains "Seridian Studio" so `seridian screenshot` finds it.
const window_title = "Seridian Studio - UI kit demo";

// Widgets with callbacks need stable addresses.
var slider: value.Slider = .{};
var stepper: value.Stepper = .{};
var progress: value.Progress = .{};
var segmented: value.Segmented = .{};
var status_label: Rid = raven.invalid;
var status_buf: [96:0]u8 = std.mem.zeroes([96:0]u8);

fn say(comptime fmt: []const u8, args: anytype) void {
    const text = std.mem.printSentinel(&status_buf, fmt, args, 0) catch return;
    raven.Rlabel_set_text(status_label, text.ptr);
}

fn onSlider(s: *value.Slider, v: f32) void {
    progress.setValue(v);
    say("slider {d:.2}", .{s.value()});
}
fn onStepper(_: *value.Stepper, v: i32) void {
    say("stepper {d}", .{v});
}
fn onSegment(_: *value.Segmented, index: i32) void {
    say("segment {d}", .{index});
}
fn onClick(_: Rid, _: ?*anyopaque) callconv(.c) void {
    say("button clicked", .{});
}
fn onCheck(_: Rid, checked: c_int, _: ?*anyopaque) callconv(.c) void {
    say("check/toggle/radio -> {d}", .{checked});
}
fn onText(_: Rid, text: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    say("text: {s}", .{text});
}
fn onCombo(_: Rid, index: c_int, _: ?*anyopaque) callconv(.c) void {
    say("combo {d}", .{index});
}

fn add(parent: Rid, child: Rid) Error!void {
    if (raven.Rwidget_add_child(parent, child) == raven.invalid) return error.RavenCreateFailed;
}

fn column(spacing: f32) Error!Rid {
    const id = raven.Rwidget_create(.vbox);
    if (id == raven.invalid) return error.RavenCreateFailed;
    raven.Rwidget_set_metric(id, .spacing, spacing);
    raven.Rpanel_set_spacing(id, spacing);
    return id;
}

fn row(spacing: f32) Error!Rid {
    const id = raven.Rwidget_create(.hbox);
    if (id == raven.invalid) return error.RavenCreateFailed;
    raven.Rwidget_set_metric(id, .spacing, spacing);
    raven.Rpanel_set_spacing(id, spacing);
    return id;
}

fn label(text: [:0]const u8, px: f32, accent: bool) Error!Rid {
    const id = raven.Rlabel_create(text.ptr);
    if (id == raven.invalid) return error.RavenCreateFailed;
    style.styleLabel(id, px);
    if (accent) raven.Rlabel_set_color(id, theme.accent.r, theme.accent.g, theme.accent.b, 1.0);
    return id;
}

fn heading(parent: Rid, text: [:0]const u8) Error!void {
    try add(parent, try label(text, theme.font_body_px, true));
}

// The window can be sized by the window manager (a tiling WM gave 918x492 for
// a 960x860 request), so the layout is three compact columns, not two tall ones.
fn buildButtons() Error!Rid {
    const col = try column(6);
    try heading(col, "BUTTONS");
    const specs = [_]basic.Config{
        .{ .text = "Default" },
        .{ .text = "Primary", .variant = .primary },
        .{ .text = "Flat", .variant = .flat },
        .{ .text = "Disabled", .enabled = false },
    };
    var line: Rid = raven.invalid;
    for (specs, 0..) |spec, i| {
        if (i % 2 == 0) {
            line = try row(6);
            try add(col, line);
        }
        const b = basic.createButton(spec);
        if (b == raven.invalid) return error.RavenCreateFailed;
        basic.setButtonClicked(b, onClick, null);
        try add(line, b);
        if (spec.variant == .primary) container.installTooltip(b, .{ .text = "Accent button with a tooltip" });
    }
    return col;
}

fn buildToggles() Error!Rid {
    const col = try column(4);
    try heading(col, "TOGGLES");
    const toggle = basic.createToggle(.{ .label = "Toggle switch", .on = true });
    basic.setToggleChanged(toggle, onCheck, null);
    try add(col, toggle);
    const check = basic.createCheckbox(.{ .label = "Checkbox", .checked = true });
    basic.setCheckboxChanged(check, onCheck, null);
    try add(col, check);
    return col;
}

fn buildRadios() Error!Rid {
    const col = try column(4);
    try heading(col, "RADIO");
    const radios = basic.createRadioGroup(.{ .options = &.{ "Radio one", "Radio two", "Radio three" }, .selected = 1 });
    if (radios == raven.invalid) return error.RavenCreateFailed;
    basic.setRadioChanged(radios, onCheck, null);
    try add(col, radios);
    return col;
}

fn buildSegmented() Error!Rid {
    const col = try column(4);
    try heading(col, "SEGMENTED");
    try segmented.init(.{ .labels = &.{ "Mono", "Stereo", "Surr." }, .selected = 1 });
    segmented.on_changed = onSegment;
    raven.Rwidget_set_min_size(segmented.root, 0, 0);
    try add(col, segmented.root);
    return col;
}

fn buildValues() Error!Rid {
    const col = try column(6);
    try heading(col, "VALUES");
    try slider.init(.{ .min = 0, .max = 1, .value = 0.4 });
    slider.on_changed = onSlider;
    try add(col, slider.root);
    try stepper.init(.{ .min = 0, .max = 16, .value = 4 });
    stepper.on_changed = onStepper;
    try add(col, stepper.root);
    try progress.init(.{ .value = 0.4, .height = 8 });
    try add(col, progress.track);
    return col;
}

fn buildText() Error!Rid {
    const col = try column(12);
    try heading(col, "TEXT");
    try add(col, try input.createTextField(.{ .placeholder = "Text field" }, onText, null));
    try add(col, try input.createSearchField(.{}, null, null));
    try add(col, try input.createComboBox(.{ .items = &.{ "Sine", "Saw", "Square", "Triangle" }, .selected = 0 }, onCombo, null));
    return col;
}

fn buildTabs() Error!Rid {
    const col = try column(6);
    try heading(col, "TABS");
    const tabs = try input.createTabBar(.{ .tabs = &.{ "Session", "Clip", "FX" }, .active = 0 }, null, null);
    const page = raven.Rwidget_get_child(tabs, 0);
    try add(page, try label("Tab page content", theme.font_body_px, false));
    raven.Rwidget_set_min_size(tabs, 0, 60);
    try add(col, tabs);
    return col;
}

fn buildExpander() Error!Rid {
    const col = try column(4);
    const inner = try column(4);
    try add(inner, try label("Content inside an expander.", theme.font_body_px, false));
    try add(col, container.createExpander(.{ .title = "Details", .expanded = true }, inner));
    return col;
}

// Drag and drop: a source surface and a target surface, stacked. Retained
// widgets only. The demo does not start a drag itself (Rdrag_begin needs a
// pointer-event hook that is not wired here), so this shows the surfaces and
// the target's drop callback, not a live drag.
fn buildDragDrop() Error!Rid {
    const col = try column(10);
    try heading(col, "DRAG AND DROP");
    const src_cfg = drag_drop.Config{ .payload_type = "clip", .label = "Drag source (clip)" };
    const dst_cfg = drag_drop.Config{ .payload_type = "clip", .label = "Drop target (accepts clip)", .glass_layer = .overlay };
    const src = drag_drop.createSurface(src_cfg);
    const dst = drag_drop.createSurface(dst_cfg);
    if (src == raven.invalid or dst == raven.invalid) return error.RavenCreateFailed;
    drag_drop.attachTarget(dst, dst_cfg);
    raven.Rwidget_set_min_size(src, 0, 34);
    raven.Rwidget_set_min_size(dst, 0, 34);
    try add(col, src);
    try add(col, dst);
    return col;
}

fn stack(spacing: f32, parts: []const Rid) Error!Rid {
    const col = try column(spacing);
    raven.Rslot_set_fill(col, 1.0);
    for (parts) |p| try add(col, p);
    return col;
}

fn build(window: Rid) Error!void {
    const root = try column(0);
    raven.Rslot_set_padding(root, 16, 16, 16, 16);

    const card = container.createCard(.{ .layer = .base, .padding = 14 });
    raven.Rslot_set_fill(card.root, 1.0);
    const body = try column(8);
    try add(body, try label("Seridian UI kit - liquid glass", theme.font_title_px, false));

    const cols = try row(32);
    try add(cols, try stack(8, &.{ try buildButtons(), try buildToggles(), try buildRadios(), try buildSegmented() }));
    try add(cols, try stack(8, &.{ try buildValues(), try buildText() }));
    try add(cols, try stack(8, &.{ try buildTabs(), try buildExpander(), try buildDragDrop() }));
    try add(body, cols);

    status_label = try label("ready", theme.font_body_px, false);
    try add(body, status_label);
    try add(card.body, body);
    try add(root, card.root);

    raven.Rwindow_set_content(window, root);
}

pub fn main() !void {
    const desc = InitDesc{
        .backend = backend_vulkan,
        .app_name = "Seridian UI kit demo",
        .worker_threads = 2,
        .ui_scale = 1.0,
    };
    if (raven.Rinit_ex(&desc) == 0) return error.InitFailed;
    defer raven.Rshutdown();

    style.applyGlassTheme();
    const window = raven.Rwindow_create(window_title, 960, 860, 0);
    if (window == raven.invalid) return error.WindowFailed;
    raven.Rwindow_set_clear_color(window, theme.bg_deep.r, theme.bg_deep.g, theme.bg_deep.b, 1.0);
    try build(window);
    raven.Rwindow_show(window);

    while (raven.Rwait_frame(1.0 / 30.0) != 0) {}
}
