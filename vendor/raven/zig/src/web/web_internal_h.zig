// Translated to Zig from vendor/raven/web/src/web_internal.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Web - web_internal.h
// What the files of the library share: the little that depends on the
// system (a child process with two pipes, a thread, a lock, folders), JSON,
// and the connection to the browser.
//
// Prefix: rw_.
//
// The `#include "../include/raven_web.h"` is `@import("raven_web_h.zig")`, not re-exported here.

// ---------------------------------------------------------------------------
//  System (web_posix.c, web_win32.c)
// ---------------------------------------------------------------------------

/// Defined by web_posix.zig / web_win32.zig (each its own structure).
pub const rw_process_t = opaque {};
pub const struct_rw_process_t = rw_process_t;

/// Starts a program with the two pipes of the DevTools protocol: the child
/// reads what rw_process_write sends, rw_process_read receives what it
/// writes. `arguments` ends with NULL and starts with the program. On Unix
/// the child finds the pipes as descriptors 3 and 4; on Windows it is told
/// their handles by an argument added here. NULL when it cannot be started.
pub extern fn rw_process_start(arguments: [*c]const [*c]const u8) ?*rw_process_t;
/// Sends all the bytes. R_FALSE when the child is gone.
pub extern fn rw_process_write(process: ?*rw_process_t, data: ?*const anyopaque, size: usize) c_int;
/// Waits for bytes. Returns how many were read; 0 when the child closed its side or rw_process_hang_up was called.
pub extern fn rw_process_read(process: ?*rw_process_t, buffer: ?*anyopaque, size: usize) c_int;
/// Makes a rw_process_read that is waiting (in another thread) return 0, and the child see the end of its input.
pub extern fn rw_process_hang_up(process: ?*rw_process_t) void;
/// Waits a little for the child to leave by itself, kills it otherwise, and releases everything.
pub extern fn rw_process_stop(process: ?*rw_process_t) void;

pub const rw_thread_t = opaque {};
pub const struct_rw_thread_t = rw_thread_t;
pub extern fn rw_thread_start(function: ?*const fn (?*anyopaque) callconv(.c) void, argument: ?*anyopaque) ?*rw_thread_t;
pub extern fn rw_thread_join(thread: ?*rw_thread_t) void;

pub const rw_mutex_t = opaque {};
pub const struct_rw_mutex_t = rw_mutex_t;
pub extern fn rw_mutex_create() ?*rw_mutex_t;
pub extern fn rw_mutex_destroy(mutex: ?*rw_mutex_t) void;
pub extern fn rw_mutex_lock(mutex: ?*rw_mutex_t) void;
pub extern fn rw_mutex_unlock(mutex: ?*rw_mutex_t) void;

/// A browser of the Chromium family found on this computer (to release with rw_free), or NULL.
pub extern fn rw_find_browser() [*c]u8;
/// R_TRUE when the file exists and can be run.
pub extern fn rw_is_program(path: [*c]const u8) c_int;
/// Makes a new, empty folder for a temporary profile and returns its path (rw_free), or NULL.
pub extern fn rw_temp_folder() [*c]u8;
/// Deletes a folder and all it contains.
pub extern fn rw_remove_folder(path: [*c]const u8) void;
/// The "file://" address of a file (rw_free).
pub extern fn rw_file_url(path: [*c]const u8) [*c]u8;
/// R_TRUE when the browser must be told to run without its sandbox (root on Unix: it refuses to start otherwise).
pub extern fn rw_needs_no_sandbox() c_int;

// ---------------------------------------------------------------------------
//  Memory and text (web_json.c)
// ---------------------------------------------------------------------------

pub extern fn rw_alloc(size: usize) ?*anyopaque;
pub extern fn rw_realloc(pointer: ?*anyopaque, size: usize) ?*anyopaque;
pub extern fn rw_free(pointer: ?*anyopaque) void;
pub extern fn rw_strdup(text: [*c]const u8) [*c]u8;

/// A text that grows.
pub const rw_text_t = extern struct {
    data: [*c]u8,
    length: usize,
    capacity: usize,
};
pub const struct_rw_text_t = rw_text_t;

pub extern fn rw_text_add(text: [*c]rw_text_t, data: [*c]const u8, size: usize) void;
pub extern fn rw_text_puts(text: [*c]rw_text_t, string: [*c]const u8) void;
pub extern fn rw_text_printf(text: [*c]rw_text_t, format: [*c]const u8, ...) void;
/// Appends a string as JSON writes it, quotes included.
pub extern fn rw_text_json(text: [*c]rw_text_t, string: [*c]const u8) void;
pub extern fn rw_text_free(text: [*c]rw_text_t) void;

// ---------------------------------------------------------------------------
//  JSON (web_json.c)
// ---------------------------------------------------------------------------

pub const rw_json_type_t = c_uint;
pub const RW_JSON_NULL: c_int = 0;
pub const RW_JSON_BOOL: c_int = 1;
pub const RW_JSON_NUMBER: c_int = 2;
pub const RW_JSON_STRING: c_int = 3;
pub const RW_JSON_ARRAY: c_int = 4;
pub const RW_JSON_OBJECT: c_int = 5;

pub const rw_json_t = extern struct {
    type: rw_json_type_t,
    /// Name of the member, inside an object.
    key: [*c]const u8,
    number: f64,
    /// Text of a string (it stays in the buffer that was parsed), and its length.
    string: [*c]const u8,
    length: usize,
    first: [*c]rw_json_t,
    next: [*c]rw_json_t,
};
pub const struct_rw_json_t = rw_json_t;

pub const rw_json_document_t = extern struct {
    root: [*c]rw_json_t,
    /// Blocks of values, released together.
    blocks: ?*anyopaque,
};
pub const struct_rw_json_document_t = rw_json_document_t;

/// Parses a text IN PLACE: the strings of the values point into `text`, which
/// is modified (escapes resolved, ends marked) and must outlive the document.
/// R_FALSE when the text is not JSON.
pub extern fn rw_json_parse(document: [*c]rw_json_document_t, text: [*c]u8, size: usize) c_int;
pub extern fn rw_json_free(document: [*c]rw_json_document_t) void;
/// The member of an object reached by a path such as "params.frame.url"; NULL when it is not there.
pub extern fn rw_json_get(value: [*c]const rw_json_t, path: [*c]const u8) [*c]const rw_json_t;
pub extern fn rw_json_string(value: [*c]const rw_json_t, path: [*c]const u8, fallback: [*c]const u8) [*c]const u8;
pub extern fn rw_json_number(value: [*c]const rw_json_t, path: [*c]const u8, fallback: f64) f64;
pub extern fn rw_json_bool(value: [*c]const rw_json_t, path: [*c]const u8, fallback: c_int) c_int;
/// Writes a value back as JSON text.
pub extern fn rw_json_write(text: [*c]rw_text_t, value: [*c]const rw_json_t) void;

/// Decodes base64 into a new buffer (rw_free). NULL when the text is not base64.
pub extern fn rw_base64_decode(text: [*c]const u8, length: usize, size: [*c]usize) [*c]u8;

// ---------------------------------------------------------------------------
//  The browser (web_browser.c)
//
//  One process, one thread that reads what it says. What it says is handed
//  to the UI thread (Rtask_post), which is the only one to touch the views.
// ---------------------------------------------------------------------------

/// What the reading thread hands to the UI thread.
pub const rw_incoming_t = extern struct {
    next: [*c]rw_incoming_t,
    /// A message of the browser, as text; or NULL for a picture.
    message: [*c]u8,
    size: usize,
    /// A picture of a page, decoded: the session it is for, its pixels.
    session: [*c]u8,
    pixels: [*c]u8,
    width: c_int,
    height: c_int,
    /// The browser closed the pipe: nothing will come any more.
    closed: c_int,
};
pub const struct_rw_incoming_t = rw_incoming_t;

/// Starts the browser if it is not running. R_FALSE (and rw_browser_error tells why) when it cannot.
pub extern fn rw_browser_start() c_int;
pub extern fn rw_browser_stop() void;
pub extern fn rw_browser_running() c_int;
pub extern fn rw_browser_error() [*c]const u8;
/// Sends a command: `params` is the JSON object of its parameters (or NULL),
/// `session` the page it is for (or NULL for the browser itself). Returns
/// the number that the answer will carry, or 0 when nothing could be sent.
pub extern fn rw_browser_send(session: [*c]const u8, method: [*c]const u8, params: [*c]const u8) c_int;
/// Called on the UI thread for each thing the browser said (web_view.c).
pub extern fn rw_views_incoming(incoming: [*c]rw_incoming_t) void;

// settings (web_browser.c)
pub extern var g_rw_browser_path: [*c]u8;
pub extern var g_rw_profile_folder: [*c]u8;
pub extern var g_rw_arguments: [*c]u8;
