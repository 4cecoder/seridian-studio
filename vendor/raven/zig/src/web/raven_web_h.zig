// Translated to Zig from vendor/raven/web/include/raven_web.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Web
// raven_web.h : web pages inside a Raven interface.
//
// The public API of Raven Web (the header is not part of include/raven, so it is not in raven.zig): its types,
// its enum values and its functions, declared `pub extern`. Defined by web_browser.zig and web_view.zig.

const raven = @import("raven");

pub const RWebFrames = c_uint;
/// Exact pictures (default): text stays sharp.
pub const R_WEB_FRAMES_PNG: c_int = 0x0480;
/// Lighter pictures, slightly blurred: for pages that move a lot (video, animation).
pub const R_WEB_FRAMES_JPEG: c_int = 0x0481;

pub const RWebEvent = c_uint;
/// The view shows another address (Rweb_view_get_url).
pub const R_WEB_EVENT_NAVIGATED: c_int = 0x04A0;
/// The title of the page changed (Rweb_view_get_title).
pub const R_WEB_EVENT_TITLE: c_int = 0x04A1;
/// A page starts loading.
pub const R_WEB_EVENT_LOADING: c_int = 0x04A2;
/// The page and what it refers to are loaded.
pub const R_WEB_EVENT_LOADED: c_int = 0x04A3;
/// The view cannot show pages any more (Rweb_view_get_error).
pub const R_WEB_EVENT_FAILED: c_int = 0x04A4;

pub const RWebResultCallback = ?*const fn (view: raven.Rid, result: [*c]const u8, @"error": [*c]const u8, user_data: ?*anyopaque) callconv(.c) void;
pub const RWebMessageCallback = ?*const fn (view: raven.Rid, message: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void;
pub const RWebEventCallback = ?*const fn (view: raven.Rid, event: RWebEvent, user_data: ?*anyopaque) callconv(.c) void;

pub extern fn Rweb_is_available() c_int;
pub extern fn Rweb_set_browser_path(path: [*c]const u8) void;
pub extern fn Rweb_get_browser_path() [*c]const u8;
pub extern fn Rweb_set_profile_folder(path: [*c]const u8) void;
pub extern fn Rweb_set_browser_arguments(arguments: [*c]const u8) void;
pub extern fn Rweb_register_xml() void;
pub extern fn Rweb_shutdown() void;

pub extern fn Rweb_view_create() raven.Rid;
pub extern fn Rweb_view_is_valid(view: raven.Rid) c_int;
pub extern fn Rweb_view_load_url(view: raven.Rid, url: [*c]const u8) void;
pub extern fn Rweb_view_load_file(view: raven.Rid, path: [*c]const u8) void;
pub extern fn Rweb_view_load_html(view: raven.Rid, html: [*c]const u8, base_url: [*c]const u8) void;
pub extern fn Rweb_view_reload(view: raven.Rid) void;
pub extern fn Rweb_view_stop(view: raven.Rid) void;
pub extern fn Rweb_view_go_back(view: raven.Rid) void;
pub extern fn Rweb_view_go_forward(view: raven.Rid) void;
pub extern fn Rweb_view_can_go_back(view: raven.Rid) c_int;
pub extern fn Rweb_view_can_go_forward(view: raven.Rid) c_int;
pub extern fn Rweb_view_get_url(view: raven.Rid) [*c]const u8;
pub extern fn Rweb_view_get_title(view: raven.Rid) [*c]const u8;
pub extern fn Rweb_view_is_loading(view: raven.Rid) c_int;
pub extern fn Rweb_view_is_ready(view: raven.Rid) c_int;
pub extern fn Rweb_view_get_error(view: raven.Rid) [*c]const u8;
pub extern fn Rweb_view_get_texture(view: raven.Rid) raven.Rid;
pub extern fn Rweb_view_set_zoom(view: raven.Rid, zoom: f32) void;
pub extern fn Rweb_view_get_zoom(view: raven.Rid) f32;
pub extern fn Rweb_view_set_frames(view: raven.Rid, format: RWebFrames, quality: c_int) void;
pub extern fn Rweb_view_run_javascript(view: raven.Rid, script: [*c]const u8, callback: RWebResultCallback, user_data: ?*anyopaque) void;
pub extern fn Rweb_view_set_message_callback(view: raven.Rid, callback: RWebMessageCallback, user_data: ?*anyopaque) void;
pub extern fn Rweb_view_set_event_callback(view: raven.Rid, callback: RWebEventCallback, user_data: ?*anyopaque) void;
