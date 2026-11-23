// Translated to Zig from vendor/raven/examples/browser/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - browser
// Web pages inside a Raven interface, with the optional library raven_web.
//
//   Rweb_register_xml()            makes <WebView> a tag of the documents
//   Rweb_view_load_url / _file     shows a page
//   Rweb_view_run_javascript       the application acts on the page
//   window.raven.postMessage(v)    the page talks to the application
//
// raven_web does not contain a browser: it drives one that is installed
// (Edge, Chrome, Chromium...). Without one, the view says so.

const std = @import("std");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// ---- raven_web.h: the declarations this example uses (no @cImport in Zig 0.18; the C ABI of web/include/raven_web.h) ----
const RWebEvent = c_uint;
const RWebResultCallback = ?*const fn (view: raven.Rid, result: [*c]const u8, @"error": [*c]const u8, user_data: ?*anyopaque) callconv(.c) void;
const RWebMessageCallback = ?*const fn (view: raven.Rid, message: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void;
const RWebEventCallback = ?*const fn (view: raven.Rid, event: RWebEvent, user_data: ?*anyopaque) callconv(.c) void;
extern fn Rweb_is_available() c_int;
extern fn Rweb_register_xml() void;
extern fn Rweb_view_load_url(view: raven.Rid, url: [*c]const u8) void;
extern fn Rweb_view_load_file(view: raven.Rid, path: [*c]const u8) void;
extern fn Rweb_view_reload(view: raven.Rid) void;
extern fn Rweb_view_go_back(view: raven.Rid) void;
extern fn Rweb_view_go_forward(view: raven.Rid) void;
extern fn Rweb_view_can_go_back(view: raven.Rid) c_int;
extern fn Rweb_view_can_go_forward(view: raven.Rid) c_int;
extern fn Rweb_view_get_url(view: raven.Rid) [*c]const u8;
extern fn Rweb_view_get_title(view: raven.Rid) [*c]const u8;
extern fn Rweb_view_is_loading(view: raven.Rid) c_int;
extern fn Rweb_view_get_error(view: raven.Rid) [*c]const u8;
extern fn Rweb_view_set_zoom(view: raven.Rid, zoom: f32) void;
extern fn Rweb_view_run_javascript(view: raven.Rid, script: [*c]const u8, callback: RWebResultCallback, user_data: ?*anyopaque) void;
extern fn Rweb_view_set_message_callback(view: raven.Rid, callback: RWebMessageCallback, user_data: ?*anyopaque) void;
extern fn Rweb_view_set_event_callback(view: raven.Rid, callback: RWebEventCallback, user_data: ?*anyopaque) void;

const App = extern struct {
    window: raven.Rid,
    page: raven.Rid,
    address: raven.Rid,
    title: raven.Rid,
    status: raven.Rid,
    log: raven.Rid,
    back: raven.Rid,
    forward: raven.Rid,
    messages: c_int,
};
var app: App = std.mem.zeroes(App);

fn refresh() void {
    const @"error": [*c]const u8 = Rweb_view_get_error(app.page);
    raven.Rtext_input_set_text(app.address, Rweb_view_get_url(app.page));
    raven.Rlabel_set_text(app.title, Rweb_view_get_title(app.page));
    raven.Rlabel_set_text(app.status, if (@"error"[0] != 0) @"error" else (if (Rweb_view_is_loading(app.page) != 0) "Loading..." else "Loaded"));
    raven.Rwidget_set_enabled(app.back, Rweb_view_can_go_back(app.page));
    raven.Rwidget_set_enabled(app.forward, Rweb_view_can_go_forward(app.page));
}

fn on_web_event(view: raven.Rid, event: RWebEvent, user_data: ?*anyopaque) callconv(.c) void {
    _ = view;
    _ = event;
    _ = user_data;
    refresh();
}

/// What the page sent with window.raven.postMessage.
fn on_message(view: raven.Rid, message: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    var text: [700]u8 = undefined;
    _ = view;
    _ = user_data;
    app.messages += 1;
    _ = example.snprintf(&text, text.len, "Message **%d**:\n\n`%.600s`", app.messages, message);
    raven.Rlabel_set_text(app.log, &text);
}

fn action_go(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const text: [*c]const u8 = raven.Rtext_input_get_text(app.address);
    var url: [1024]u8 = undefined;
    _ = sender;
    _ = action;
    _ = user_data;
    if (text == null or text[0] == 0) return;
    // an address without a scheme is a web site
    if (example.strstr(text, "://") != null or example.strncmp(text, "about:", 6) == 0) {
        _ = example.snprintf(&url, url.len, "%s", text);
    } else {
        _ = example.snprintf(&url, url.len, "https://%s", text);
    }
    Rweb_view_load_url(app.page, &url);
    raven.Rwidget_focus(app.page);
}

fn action_nav(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = sender;
    _ = user_data;
    if (example.strcmp(action, "web.back") == 0) {
        Rweb_view_go_back(app.page);
    } else if (example.strcmp(action, "web.forward") == 0) {
        Rweb_view_go_forward(app.page);
    } else if (example.strcmp(action, "web.reload") == 0) {
        Rweb_view_reload(app.page);
    } else if (example.strcmp(action, "web.home") == 0) {
        Rweb_view_load_file(app.page, example.RAVEN_EXAMPLE_DIR ++ "/pages/welcome.html");
    } else if (example.strcmp(action, "web.navigated") == 0) {
        refresh();
    }
}

fn action_zoom(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    _ = action;
    _ = user_data;
    Rweb_view_set_zoom(app.page, raven.Rslider_get_value(sender));
}

/// A widget of Raven changes the page: the color picker sets a CSS variable.
fn action_tint(sender: raven.Rid, action: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    var script: [160]u8 = undefined;
    _ = action;
    _ = user_data;
    _ = example.snprintf(&script, script.len, "document.documentElement.style.setProperty('--accent', '%s')", raven.Rcolor_picker_get_hex(sender));
    Rweb_view_run_javascript(app.page, &script, null, null);
}

export fn main() c_int {
    if (example.example_init("Raven web") == 0) return 1;
    raven.Rtheme_apply(raven.R_THEME_DARK);
    // <WebView> becomes a tag
    Rweb_register_xml();
    if (Rweb_is_available() == 0) {
        _ = example.fprintf(example.c_stderr(), "No browser of the Chromium family was found (Edge, Chrome, Chromium).\n" ++
            "Install one, or set RAVEN_WEB_BROWSER to the path of its program.\n");
    }

    raven.Raction_bind("web.go", action_go, null);
    raven.Raction_bind("web.back", action_nav, null);
    raven.Raction_bind("web.forward", action_nav, null);
    raven.Raction_bind("web.reload", action_nav, null);
    raven.Raction_bind("web.home", action_nav, null);
    raven.Raction_bind("web.navigated", action_nav, null);
    raven.Raction_bind("web.zoom", action_zoom, null);
    raven.Raction_bind("web.tint", action_tint, null);

    app.window = raven.Rwindow_create_from_xml_file(example.RAVEN_EXAMPLE_DIR ++ "/browser.xml");
    if (app.window == raven.R_INVALID_ID) {
        raven.Rshutdown();
        return 1;
    }
    app.page = raven.Rwidget_find(app.window, "page");
    app.address = raven.Rwidget_find(app.window, "address");
    app.title = raven.Rwidget_find(app.window, "title");
    app.status = raven.Rwidget_find(app.window, "status");
    app.log = raven.Rwidget_find(app.window, "log");
    app.back = raven.Rwidget_find(app.window, "back");
    app.forward = raven.Rwidget_find(app.window, "forward");
    Rweb_view_set_event_callback(app.page, on_web_event, null);
    Rweb_view_set_message_callback(app.page, on_message, null);
    refresh();
    raven.Rwindow_show(app.window);

    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }
    raven.Rshutdown();
    return raven.Rget_exit_code();
}
