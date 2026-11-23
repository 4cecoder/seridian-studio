// Translated to Zig from vendor/raven/src/xml/xml_watch.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_watch.h
// Files that are watched, and live reload of the interfaces built from files
// (xml_watch.c).

const raven = @import("raven");
const xml = @import("xml_h.zig");

/// Called when a watched file was written. R_FALSE asks to be called again a
/// moment later (the file was caught half written).
pub const rvn_watch_callback_t = ?*const fn (path: [*c]const u8, user: ?*anyopaque) callconv(.c) c_int;

/// Watches a file. Adding the same file with the same callback and user twice does nothing.
pub extern fn rvn_watch_add(path: [*c]const u8, callback: rvn_watch_callback_t, user: ?*anyopaque) void;

/// R_TRUE while a file that could not be used is tried again: its errors should not be reported yet.
pub extern fn rvn_watch_quiet() c_int;

/// Starts noting the files read by the document being loaded (<Include>). Calls nest.
pub extern fn rvn_live_begin() void;
pub extern fn rvn_live_end() void;
pub extern fn rvn_live_dependency(path: [*c]const u8) void;
/// Remembers what was built from a file: `target` is the window or the
/// widget, `document` the expanded document it was built from, which is taken
/// (the caller must not free it). To call between rvn_live_begin and rvn_live_end.
pub extern fn rvn_live_add(path: [*c]const u8, is_window: c_int, target: raven.Rid, document: [*c]xml.rvn_xml_document_t) void;
/// Watches a file of <Widget> declarations (Rxml_register_widgets_from_file).
pub extern fn rvn_live_watch_widgets(path: [*c]const u8) void;
pub extern fn rvn_live_shutdown() void;
