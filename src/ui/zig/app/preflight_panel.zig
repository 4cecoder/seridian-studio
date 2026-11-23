//! System check: a header indicator that summarises the engine's realtime-audio preflight (`daw_preflight_*`, the
//! same report as `seridian doctor`) and a dialog listing every check with its hint and, where the engine offers
//! one, an automatic fix.
//!
//! The preflight spawns tools and reads /proc, so it runs on a worker thread (preflight_report.Runner, which copies the engine settings on the UI thread first); the main
//! loop calls preflight_poll once per frame to pick up a finished report. Not part of the C translation: added
//! after it, in the same style as the rest of the window.

const std = @import("std");
const raven = @import("raven");
const st = @import("state.zig");
const ext = @import("externs.zig");
const fns = @import("fns.zig");
const report_mod = @import("../preflight_report.zig");

const app = &st.app;
const log = std.log.scoped(.preflight_ui);

const Rid = raven.Rid;

/// Width of the dialog, and height of its scrolling list of checks.
const DIALOG_WIDTH: f32 = 620.0;
const LIST_HEIGHT: f32 = 440.0;
const MESSAGE_CAPACITY = 192;

/// Process-global, UI thread only. `runner` is null when it could not be created (the indicator then says so);
/// it owns its reports (std.heap.c_allocator) until preflight_shutdown.
var runner: ?report_mod.Runner = null;
var indicator: Rid = raven.R_INVALID_ID;
/// Widgets of the open dialog; R_INVALID_ID while it is closed (Raven deletes the content on close).
var dialog_list: Rid = raven.R_INVALID_ID;
var dialog_subtitle: Rid = raven.R_INVALID_ID;
var dialog_message: Rid = raven.R_INVALID_ID;

fn runSnapshot(out: *report_mod.CReport, snap: ?*const report_mod.CEngineSnapshot) callconv(.c) void {
    ext.daw_preflight_run_snapshot(out, snap);
}

fn takeSnapshot(engine: ?*anyopaque, out: *report_mod.CEngineSnapshot) callconv(.c) void {
    ext.daw_preflight_snapshot(engine, out);
}

/// Adds the "System check" indicator to the header row. Clicking it opens the report.
pub fn build_preflight_indicator(row: Rid) void {
    indicator = fns.add_button(row, "Checking system…", &on_open_preflight, null, raven.R_BUTTON_FLAT);
    raven.Rwidget_set_tooltip(indicator, "Realtime audio system check (the same report as `seridian doctor`)");
}

/// Creates the runner and starts the first check. Fails soft: the indicator explains what went wrong.
pub fn preflight_init() void {
    runner = report_mod.Runner.init(std.heap.c_allocator, runSnapshot, takeSnapshot, app.engine) catch |err| {
        log.warn("system check unavailable: {s}", .{@errorName(err)});
        set_indicator_text("System check unavailable");
        return;
    };
    preflight_start();
}

/// Joins a check still running and frees the reports. Call before Rshutdown.
pub fn preflight_shutdown() void {
    if (runner) |*r| r.deinit();
    runner = null;
}

/// Starts a new check unless one is running.
pub fn preflight_start() void {
    const r = if (runner) |*value| value else return;
    r.start() catch |err| switch (err) {
        error.Busy => return,
        else => {
            log.warn("could not start the system check: {s}", .{@errorName(err)});
            set_indicator_text("System check unavailable");
            return;
        },
    };
    set_message("Checking…");
}

/// Once per frame: shows a report that has just arrived.
pub fn preflight_poll() void {
    const r = if (runner) |*value| value else return;
    const report = r.poll() orelse return;
    update_indicator(report);
    if (dialog_list != raven.R_INVALID_ID) fill_dialog(report);
    set_message("");
}

fn set_indicator_text(text: [*:0]const u8) void {
    if (indicator == raven.R_INVALID_ID) return;
    raven.Rbutton_set_text(indicator, text);
}

fn set_message(text: [*:0]const u8) void {
    if (dialog_message == raven.R_INVALID_ID) return;
    raven.Rlabel_set_text(dialog_message, text);
}

fn update_indicator(report: *const report_mod.CReport) void {
    if (indicator == raven.R_INVALID_ID) return;
    const summary = report_mod.summarize(report);
    var buffer: [64]u8 = undefined;
    const text = report_mod.indicatorText(summary, &buffer) catch "System check";
    raven.Rbutton_set_text(indicator, text.ptr);
    switch (summary.worst) {
        report_mod.status_ok, report_mod.status_info => {
            raven.Rbutton_set_style(indicator, raven.R_BUTTON_FLAT);
            raven.Rwidget_set_tooltip(indicator, "Realtime audio system check: everything passed");
        },
        else => {
            const color = report_mod.statusColor(summary.worst);
            fns.style_fill_button(indicator, &color, &st.color_ink);
            raven.Rwidget_set_tooltip(indicator, "Realtime audio system check: click for details and fixes");
        },
    }
}

/// A neon pill with the status word ("PASS", "WARN"...), tinted by status.
fn make_status_pill(status: u32) Rid {
    const color = report_mod.statusColor(status);
    const label = fns.make_label(report_mod.statusLabel(status).ptr, 11.0, &color);
    const pill = raven.Rwidget_create(raven.R_WIDGET_BORDER);
    raven.Rborder_set_background(pill, color[0], color[1], color[2], 0.14);
    raven.Rborder_set_outline(pill, 1.0, color[0], color[1], color[2], 0.9);
    raven.Rborder_set_corner_radius(pill, 6.0, 6.0, 6.0, 6.0);
    raven.Rborder_set_padding(pill, 7.0, 2.0, 7.0, 2.0);
    _ = raven.Rwidget_add_child(pill, label);
    raven.Rslot_set_valign(pill, raven.R_VALIGN_CENTER);
    return pill;
}

fn make_check_row(check: *const report_mod.CCheck) Rid {
    const column = fns.make_column(4.0);
    const heading = fns.make_row(10.0);
    _ = raven.Rwidget_add_child(heading, make_status_pill(check.status));
    const title = fns.make_label(&check.title, 14.0, &st.color_readout);
    raven.Rslot_set_valign(title, raven.R_VALIGN_CENTER);
    raven.Rslot_set_fill(title, 1.0);
    _ = raven.Rwidget_add_child(heading, title);
    if (check.fix != 0 and report_mod.needsAttention(check)) {
        var label: [96]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&label, "Fix: {s}", .{std.mem.span(ext.daw_preflight_fix_label(check.fix))}, 0) catch "Fix";
        const fix_button = fns.add_button(heading, text.ptr, &on_preflight_fix, @ptrFromInt(@as(usize, check.fix)), raven.R_BUTTON_PRIMARY);
        raven.Rwidget_set_tooltip(fix_button, "Apply this fix (writes only under your home folder)");
    }
    _ = raven.Rwidget_add_child(column, heading);
    if (report_mod.text(&check.detail).len > 0) {
        _ = raven.Rwidget_add_child(column, fns.make_wrapped_label(&check.detail, 12.0, &st.muted_text));
    }
    if (report_mod.needsAttention(check) and report_mod.text(&check.hint).len > 0) {
        const hint_color = report_mod.statusColor(check.status);
        _ = raven.Rwidget_add_child(column, fns.make_wrapped_label(&check.hint, 12.0, &hint_color));
    }
    return column;
}

/// Rebuilds the open dialog's list from `report`: problems first, then warnings, notes and passes.
fn fill_dialog(report: *const report_mod.CReport) void {
    raven.Rwidget_clear_children(dialog_list);
    var subtitle: [128]u8 = undefined;
    const version = report_mod.text(&report.desktop_version);
    const line = std.fmt.bufPrintSentinel(&subtitle, "Realtime audio on {s}{s}{s} ({s})", .{
        report_mod.text(&report.desktop),
        if (version.len > 0) " " else "",
        version,
        report_mod.text(&report.session),
    }, 0) catch "Realtime audio";
    raven.Rlabel_set_text(dialog_subtitle, line.ptr);
    var status = report_mod.status_fail + 1;
    while (status > 0) {
        status -= 1;
        for (report.items()) |*check| {
            if (@min(check.status, report_mod.status_fail) != status) continue;
            _ = raven.Rwidget_add_child(dialog_list, make_check_row(check));
        }
    }
}

pub fn on_open_preflight(button: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    if (raven.Rwindow_has_dialog(app.window) != 0) return;

    const column = fns.make_column(12.0);
    _ = raven.Rwidget_add_child(column, fns.make_label("System check", 15.0, &st.accent_cyan));
    dialog_subtitle = fns.make_label("Realtime audio", 12.0, &st.muted_text);
    _ = raven.Rwidget_add_child(column, dialog_subtitle);

    const scroll = raven.Rwidget_create(raven.R_WIDGET_SCROLL_BOX);
    raven.Rwidget_set_size(scroll, -1.0, LIST_HEIGHT);
    dialog_list = fns.make_column(14.0);
    _ = raven.Rwidget_add_child(scroll, dialog_list);
    _ = raven.Rwidget_add_child(column, scroll);

    dialog_message = fns.make_wrapped_label("", 12.0, &st.accent_cyan);
    _ = raven.Rwidget_add_child(column, dialog_message);

    const buttons = fns.make_row(10.0);
    _ = fns.add_button(buttons, "Run again", &on_preflight_rerun, null, raven.R_BUTTON_FLAT);
    _ = fns.add_button(buttons, "Close", &on_preflight_close, null, raven.R_BUTTON_PRIMARY);
    _ = raven.Rwidget_add_child(column, buttons);

    const panel = fns.make_panel(column, 16.0);
    raven.Rwidget_set_size(panel, DIALOG_WIDTH, -1.0);
    raven.Rdialog_open(app.window, panel, &on_preflight_closed, null);

    const latest = if (runner) |*r| r.latest() else null;
    if (latest) |report| {
        fill_dialog(report);
    } else {
        _ = raven.Rwidget_add_child(dialog_list, fns.make_label(if (runner != null) "Checking the system…" else "The system check could not start.", 13.0, &st.muted_text));
    }
    if (runner) |*r| {
        if (r.isRunning()) set_message("Checking…");
    }
}

pub fn on_preflight_closed(content: Rid, result: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = content;
    _ = result;
    _ = user_data;
    // Raven deletes the content after this callback.
    dialog_list = raven.R_INVALID_ID;
    dialog_subtitle = raven.R_INVALID_ID;
    dialog_message = raven.R_INVALID_ID;
}

pub fn on_preflight_close(button: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    raven.Rdialog_close(button, 0);
}

pub fn on_preflight_rerun(button: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    preflight_start();
}

pub fn on_preflight_fix(button: Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const fix: u32 = @intCast(@intFromPtr(user_data));
    var message: [MESSAGE_CAPACITY]u8 = undefined;
    const result = ext.daw_preflight_apply_fix(fix, app.engine, &message, message.len);
    const text: [*:0]const u8 = @ptrCast(&message);
    fns.set_status(text);
    if (result != 0) {
        log.warn("fix {d} failed: {s}", .{ fix, std.mem.span(text) });
        set_message(text);
        return;
    }
    preflight_start();
    set_message(text);
}
