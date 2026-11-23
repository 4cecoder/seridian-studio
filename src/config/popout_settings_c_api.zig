//! C ABI for the Piano Roll popout geometry (`$XDG_CONFIG_HOME/seridian/daw/popouts.conf`).
//! Called from the Raven UI: load once at startup, save when the popout is resized, closed or the app quits.

const std = @import("std");
const popout_settings = @import("popout_settings.zig");
const monitors = @import("monitors.zig");

const log = std.log.scoped(.popout_settings);

/// Reads the saved popout state. Returns 1 and fills the outputs when the popout was open and the
/// saved geometry is valid; returns 0 for a missing, corrupt or closed state (no popout), and -1
/// for a null output pointer or an unusable settings path. `monitor` receives the saved monitor name as a
/// NUL-terminated string (empty when the file holds absolute coordinates only, e.g. an old file) and
/// `dx`/`dy` the offset from that monitor's origin.
pub export fn seridian_popout_load(
    x: ?*c_int,
    y: ?*c_int,
    width: ?*c_int,
    height: ?*c_int,
    monitor: ?[*]u8,
    monitor_capacity: usize,
    dx: ?*c_int,
    dy: ?*c_int,
) callconv(.c) c_int {
    return loadWindow(.piano_roll, x, y, width, height, monitor, monitor_capacity, dx, dy);
}

/// `seridian_popout_load` for the Mixer popout (`mixerpopout.conf`).
pub export fn seridian_mixer_popout_load(
    x: ?*c_int,
    y: ?*c_int,
    width: ?*c_int,
    height: ?*c_int,
    monitor: ?[*]u8,
    monitor_capacity: usize,
    dx: ?*c_int,
    dy: ?*c_int,
) callconv(.c) c_int {
    return loadWindow(.mixer, x, y, width, height, monitor, monitor_capacity, dx, dy);
}

fn loadWindow(
    comptime window: popout_settings.Window,
    x: ?*c_int,
    y: ?*c_int,
    width: ?*c_int,
    height: ?*c_int,
    monitor: ?[*]u8,
    monitor_capacity: usize,
    dx: ?*c_int,
    dy: ?*c_int,
) c_int {
    const out_x = x orelse return -1;
    const out_y = y orelse return -1;
    const out_w = width orelse return -1;
    const out_h = height orelse return -1;
    const out_mon = monitor orelse return -1;
    const out_dx = dx orelse return -1;
    const out_dy = dy orelse return -1;
    if (monitor_capacity == 0) return -1;
    const allocator = std.heap.c_allocator;

    const path = popout_settings.defaultPathFor(allocator, window) catch |err| {
        log.warn("cannot resolve the popout settings path: {}", .{err});
        return -1;
    };
    defer allocator.free(path);

    const settings = popout_settings.loadFromFor(allocator, window, path) catch |err| {
        log.warn("cannot load popout settings from {s}: {}", .{ path, err });
        return 0;
    };
    if (!settings.open) return 0;
    out_x.* = settings.x;
    out_y.* = settings.y;
    out_w.* = settings.width;
    out_h.* = settings.height;
    out_dx.* = settings.dx;
    out_dy.* = settings.dy;
    const name = settings.monitor();
    const n = if (name.len < monitor_capacity) name.len else monitor_capacity - 1;
    @memcpy(out_mon[0..n], name[0..n]);
    out_mon[n] = 0;
    return 1;
}

/// Writes the popout state atomically. `open` is non-zero while the popout window exists. `monitor` is a
/// NUL-terminated monitor name, or null for none (then only the absolute x and y are used on restore);
/// `dx`/`dy` are the offset from that monitor's origin. Returns 0, or -1 for an unusable path, an unusable
/// monitor name, invalid geometry or a failed write.
pub export fn seridian_popout_save(
    open: c_int,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    monitor: ?[*:0]const u8,
    dx: c_int,
    dy: c_int,
) callconv(.c) c_int {
    return saveWindow(.piano_roll, open, x, y, width, height, monitor, dx, dy);
}

/// `seridian_popout_save` for the Mixer popout (`mixerpopout.conf`).
pub export fn seridian_mixer_popout_save(
    open: c_int,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    monitor: ?[*:0]const u8,
    dx: c_int,
    dy: c_int,
) callconv(.c) c_int {
    return saveWindow(.mixer, open, x, y, width, height, monitor, dx, dy);
}

fn saveWindow(
    comptime window: popout_settings.Window,
    open: c_int,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    monitor: ?[*:0]const u8,
    dx: c_int,
    dy: c_int,
) c_int {
    const allocator = std.heap.c_allocator;
    var settings: popout_settings.PopoutSettings = .{ .open = open != 0, .x = x, .y = y, .width = width, .height = height };
    if (monitor) |name| {
        if (!settings.setMonitor(std.mem.span(name))) return -1;
        settings.dx = dx;
        settings.dy = dy;
    }
    if (!settings.isValid()) return -1;

    const path = popout_settings.defaultPathFor(allocator, window) catch |err| {
        log.warn("cannot resolve the popout settings path: {}", .{err});
        return -1;
    };
    defer allocator.free(path);

    popout_settings.saveToFor(allocator, window, path, settings) catch |err| {
        log.warn("cannot save popout settings to {s}: {}", .{ path, err });
        return -1;
    };
    return 0;
}

/// Saves the Mixer popout state, naming the monitor itself: the window centre is looked up with
/// `seridian wm monitors` (the active backend's own list) and the offset is taken from that origin. When the
/// lookup fails nothing monitor-relative is saved, only the absolute x and y. Returns 0, or -1 as
/// `seridian_mixer_popout_save`.
pub export fn seridian_mixer_popout_save_located(open: c_int, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) c_int {
    return saveLocated(.mixer, open, x, y, width, height);
}

/// `seridian_mixer_popout_save_located` for the Piano Roll popout.
pub export fn seridian_popout_save_located(open: c_int, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) c_int {
    return saveLocated(.piano_roll, open, x, y, width, height);
}

fn saveLocated(comptime window: popout_settings.Window, open: c_int, x: c_int, y: c_int, width: c_int, height: c_int) c_int {
    const half_w: c_int = @divTrunc(width, 2);
    const half_h: c_int = @divTrunc(height, 2);
    const found = popout_settings.locateFromBackend(std.heap.c_allocator, x +| half_w, y +| half_h) orelse
        return saveWindow(window, open, x, y, width, height, null, 0, 0);
    var name_z: [monitors.max_name + 1]u8 = undefined;
    @memcpy(name_z[0..found.monitor_len], found.monitor());
    name_z[found.monitor_len] = 0;
    const name: [*:0]const u8 = @ptrCast(&name_z);
    return saveWindow(window, open, x, y, width, height, name, x -| found.origin_x, y -| found.origin_y);
}

/// Finds the monitor containing the point (`px`, `py`) in the text printed by `seridian wm monitors`.
/// Returns 1 and fills `name` (NUL-terminated) and the monitor's origin; 0 when no monitor contains the
/// point; -1 for a null pointer or a zero capacity.
pub export fn seridian_popout_locate(
    text: ?[*]const u8,
    text_len: usize,
    px: c_int,
    py: c_int,
    name: ?[*]u8,
    name_capacity: usize,
    origin_x: ?*c_int,
    origin_y: ?*c_int,
) callconv(.c) c_int {
    const t = text orelse return -1;
    const out_name = name orelse return -1;
    const ox = origin_x orelse return -1;
    const oy = origin_y orelse return -1;
    if (name_capacity == 0) return -1;
    const list = monitors.parseWmMonitors(t[0..text_len]);
    const hit = list.containing(px, py) orelse return 0;
    const n = if (hit.name_len < name_capacity) hit.name_len else name_capacity - 1;
    @memcpy(out_name[0..n], hit.name()[0..n]);
    out_name[n] = 0;
    ox.* = hit.rect.x;
    oy.* = hit.rect.y;
    return 1;
}

/// Plans the `seridian wm place` call for a restored popout (see `popout_settings.plan`). `saved_monitor` is
/// the NUL-terminated saved name (may be empty); `saved_x`/`saved_y` the saved absolute position; `width` and
/// `height` the saved size. Outputs the monitor name, offsets and the sanitised size. Returns 1 when the saved
/// monitor was found, 2 when the monitor containing (`main_cx`, `main_cy`) was used instead, 0 when no monitor
/// is usable, and -1 for a null pointer or a zero capacity.
pub export fn seridian_popout_plan(
    text: ?[*]const u8,
    text_len: usize,
    saved_monitor: ?[*:0]const u8,
    saved_x: c_int,
    saved_y: c_int,
    saved_dx: c_int,
    saved_dy: c_int,
    main_cx: c_int,
    main_cy: c_int,
    name: ?[*]u8,
    name_capacity: usize,
    dx: ?*c_int,
    dy: ?*c_int,
    width: ?*c_int,
    height: ?*c_int,
) callconv(.c) c_int {
    const t = text orelse return -1;
    const out_name = name orelse return -1;
    const out_dx = dx orelse return -1;
    const out_dy = dy orelse return -1;
    const out_w = width orelse return -1;
    const out_h = height orelse return -1;
    if (name_capacity == 0) return -1;
    const list = monitors.parseWmMonitors(t[0..text_len]);
    var saved: popout_settings.PopoutSettings = .{ .x = saved_x, .y = saved_y, .width = out_w.*, .height = out_h.*, .dx = saved_dx, .dy = saved_dy };
    if (saved_monitor) |m| {
        const span = std.mem.span(m);
        if (span.len > 0 and !saved.setMonitor(span)) saved.monitor_len = 0;
    }
    const p = popout_settings.plan(&list, &saved, main_cx, main_cy) orelse return 0;
    const n = if (p.monitor_len < name_capacity) p.monitor_len else name_capacity - 1;
    @memcpy(out_name[0..n], p.monitor()[0..n]);
    out_name[n] = 0;
    out_dx.* = p.dx;
    out_dy.* = p.dy;
    out_w.* = p.width;
    out_h.* = p.height;
    return if (p.saved_monitor) 1 else 2;
}

/// Computes the geometry to restore the popout with (see `popout_settings.restoreGeometry`). The monitor is
/// the one containing the point (`center_x`, `center_y`), found with xrandr. Returns 1 when the geometry was
/// clamped to that monitor, 0 when the monitor is unknown (only the size is sanitised: do not move the
/// window), and -1 for a null pointer.
pub export fn seridian_popout_restore(
    x: ?*c_int,
    y: ?*c_int,
    width: ?*c_int,
    height: ?*c_int,
    center_x: c_int,
    center_y: c_int,
) callconv(.c) c_int {
    const px = x orelse return -1;
    const py = y orelse return -1;
    const pw = width orelse return -1;
    const ph = height orelse return -1;
    const monitor = monitors.monitorContaining(std.heap.c_allocator, center_x, center_y);
    const out = popout_settings.restoreGeometry(
        .{ .x = px.*, .y = py.*, .width = pw.*, .height = ph.* },
        monitor,
    );
    px.* = out.rect.x;
    py.* = out.rect.y;
    pw.* = out.rect.width;
    ph.* = out.rect.height;
    return if (out.place) 1 else 0;
}
