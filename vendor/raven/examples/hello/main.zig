// Translated to Zig from vendor/raven/examples/hello/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - hello
// The smallest program: a window built with the C API, a label and a button.
//
// Every object is an opaque handle (Rid). Layout follows Slate: a panel
// arranges its children, and each child carries a *slot* that tells the panel
// how to place it (padding, alignment, auto or fill size).

const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

var g_label: raven.Rid = 0;
var g_clicks: c_int = 0;

fn on_clicked(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    var text: [64]u8 = undefined;
    _ = button;
    _ = user_data;
    g_clicks += 1;
    _ = example.snprintf(&text, text.len, "Clicked %d time%s", g_clicks, @as([*c]const u8, if (g_clicks > 1) "s" else ""));
    raven.Rlabel_set_text(g_label, &text);
}

fn on_quit(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    raven.Rquit(0);
}

export fn main() c_int {
    var window: raven.Rid = undefined;
    var box: raven.Rid = undefined;
    var title: raven.Rid = undefined;
    var row: raven.Rid = undefined;
    var button: raven.Rid = undefined;
    var quit: raven.Rid = undefined;

    if (example.example_init("hello") == 0) return 1;

    window = raven.Rwindow_create("Hello Raven", 420, 220, raven.R_WINDOW_DEFAULT);

    // a vertical box centered in the window
    box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    raven.Rpanel_set_spacing(box, 12.0);
    raven.Rslot_set_halign(box, raven.R_HALIGN_CENTER);
    raven.Rslot_set_valign(box, raven.R_VALIGN_CENTER);
    raven.Rwindow_set_content(window, box);

    title = raven.Rwidget_add_child(box, raven.Rlabel_create("Hello from Raven"));
    raven.Rlabel_set_text_size(title, 24.0);
    raven.Rslot_set_halign(title, raven.R_HALIGN_CENTER);

    g_label = raven.Rwidget_add_child(box, raven.Rlabel_create("Press the button"));
    raven.Rslot_set_halign(g_label, raven.R_HALIGN_CENTER);

    row = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_HBOX));
    raven.Rpanel_set_spacing(row, 8.0);
    raven.Rslot_set_halign(row, raven.R_HALIGN_CENTER);

    button = raven.Rwidget_add_child(row, raven.Rbutton_create("Click me"));
    raven.Rbutton_set_style(button, raven.R_BUTTON_PRIMARY);
    raven.Rbutton_set_clicked_callback(button, on_clicked, null);
    raven.Rwidget_set_tooltip(button, "Counts the clicks");

    quit = raven.Rwidget_add_child(row, raven.Rbutton_create("Quit"));
    raven.Rbutton_set_clicked_callback(quit, on_quit, null);

    // the loop belongs to the application: Raven draws one frame per call,
    // and Rwait_frame sleeps until there is something to draw
    if (example.example_automated(window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }

    // releases every window, widget and resource that is still alive
    raven.Rshutdown();
    return 0;
}
