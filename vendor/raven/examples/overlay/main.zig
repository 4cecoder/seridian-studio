// Translated to Zig from vendor/raven/examples/overlay/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - overlay
// A window that is seen through, and the ways to blur what is behind.
//
//   <Window Transparent="true" Backdrop="Blur">   or R_WINDOW_TRANSPARENT + Rwindow_set_backdrop
//   Rwindow_set_opacity                           the whole window fades
//   <BackgroundBlur Style="Native|Plain|Frosted|Glass">
//
// Whether the desktop shows, and blurred or not, is up to the window
// system: Windows 10 and 11 do it (Mica and Acrylic need Windows 11), X11
// needs a compositor (and KWin for the blur). Rwindow_get_backdrop tells
// what was obtained; the example shows it.

const std = @import("std");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// #ifndef RAVEN_EXAMPLE_DIR / #define RAVEN_EXAMPLE_DIR "." / #endif:
// example.RAVEN_EXAMPLE_DIR is always defined (by the generated module example_config).

var app = std.mem.zeroes(extern struct {
    window: raven.Rid,
    result: raven.Rid,
    what: raven.Rid,
});

fn backdrop_name(backdrop: raven.RBackdrop) [*c]const u8 {
    switch (backdrop) {
        raven.R_BACKDROP_TRANSPARENT => return "the desktop, as it is",
        raven.R_BACKDROP_BLUR => return "the desktop, blurred",
        raven.R_BACKDROP_ACRYLIC => return "acrylic",
        raven.R_BACKDROP_MICA => return "mica",
        else => return "nothing (not available here)",
    }
}

fn show_result() void {
    var text: [200]u8 = undefined;
    var native: raven.RNativeWindow = undefined;
    _ = example.snprintf(&text, text.len, "obtained: %s", backdrop_name(raven.Rwindow_get_backdrop(app.window)));
    raven.Rlabel_set_text(app.result, &text);
    native = std.mem.zeroes(raven.RNativeWindow);
    _ = raven.Rwindow_get_native_handle(app.window, &native);
    raven.Rlabel_set_text(app.what, @as([*c]const u8, if (native.transparent != 0)
        "Where this window draws nothing, what is behind it shows. Drag the panel to move the window."
    else
        "This window system did not give a window that can be seen through: the same interface, on a plain background."));
}

fn action_backdrop(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const backdrops = [_]raven.RBackdrop{ raven.R_BACKDROP_TRANSPARENT, raven.R_BACKDROP_BLUR, raven.R_BACKDROP_ACRYLIC, raven.R_BACKDROP_MICA };
    const index: c_int = raven.Rcombo_box_get_selected(sender);
    _ = action;
    _ = user_data;
    // (when the system cannot do what is asked, the window stays as it was)
    if (index >= 0 and index < 4) _ = raven.Rwindow_set_backdrop(app.window, backdrops[@intCast(index)]);
    show_result();
}

fn action_opacity(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = action;
    _ = user_data;
    _ = raven.Rwindow_set_opacity(app.window, raven.Rslider_get_value(sender));
}

fn action_close(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = action;
    _ = user_data;
    raven.Rquit(0);
}

export fn main() c_int {
    var stripes: raven.Rid = undefined;
    var i: c_int = undefined;
    if (example.example_init("Raven overlay") == 0) return 1;
    raven.Rtheme_apply(raven.R_THEME_DARK);

    raven.Raction_bind("overlay.backdrop", action_backdrop, null);
    raven.Raction_bind("overlay.opacity", action_opacity, null);
    raven.Raction_bind("overlay.close", action_close, null);

    app.window = raven.Rwindow_create_from_xml_file(example.RAVEN_EXAMPLE_DIR ++ "/overlay.xml");
    if (app.window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }
    app.result = raven.Rwidget_find(app.window, "backdrop.result");
    app.what = raven.Rwidget_find(app.window, "what");
    // something sharp to blur: stripes of color
    stripes = raven.Rwidget_find(app.window, "stripes");
    i = 0;
    while (i < 40) : (i += 1) {
        const colors = [4][3]f32{ .{ 1.0, 0.27, 0.23 }, .{ 1.0, 0.84, 0.04 }, .{ 0.19, 0.82, 0.35 }, .{ 0.04, 0.52, 1.0 } };
        const stripe: raven.Rid = raven.Rwidget_add_child(stripes, raven.Rwidget_create(raven.R_WIDGET_BORDER));
        raven.Rwidget_set_size(stripe, 16.0, -1.0);
        raven.Rborder_set_background(stripe, colors[@intCast(@rem(i, 4))][0], colors[@intCast(@rem(i, 4))][1], colors[@intCast(@rem(i, 4))][2], 1.0);
    }
    show_result();
    raven.Rwindow_show(app.window);

    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }
    raven.Rshutdown();
    return raven.Rget_exit_code();
}
