// Translated to Zig from vendor/raven/web/src/web_browser.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Web - web_browser.c
// The browser process and the conversation with it.
//
// The DevTools protocol over a pipe: JSON messages, each ended by a zero
// byte. Commands carry a number ("id") that their answer repeats; events
// come unasked ("method"). Both name the page they are about ("sessionId").
//
// A thread reads. The pictures of the pages (Page.screencastFrame) are
// decoded there, away from the UI thread, and acknowledged at once so that
// the next one can come; everything else is handed over as text. The UI
// thread is woken with Rtask_post and gives each thing to the views.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const web = @import("web_internal_h.zig");
const libc = @import("../sys/libc.zig");

const rw_incoming_t = web.rw_incoming_t;
const rw_text_t = web.rw_text_t;
const rw_json_document_t = web.rw_json_document_t;
const rw_json_t = web.rw_json_t;

extern "c" fn strcpy(dst: [*c]u8, src: [*c]const u8) [*c]u8;

export var g_rw_browser_path: [*c]u8 = null;
export var g_rw_profile_folder: [*c]u8 = null;
export var g_rw_arguments: [*c]u8 = null;

const rw_state_t = extern struct {
    process: ?*web.rw_process_t,
    reader: ?*web.rw_thread_t,
    /// Guards the writes to the pipe, the numbers of the commands, and the list below.
    mutex: ?*web.rw_mutex_t,
    first: [*c]rw_incoming_t,
    last: [*c]rw_incoming_t,
    /// A task is on its way to the UI thread.
    posted: c_int,
    next_id: c_int,
    profile: [*c]u8,
    profile_temporary: c_int,
    @"error": [256]u8,
};

var g_rw: rw_state_t = std.mem.zeroes(rw_state_t);

// ---------------------------------------------------------------------------
//  From the reading thread to the UI thread
// ---------------------------------------------------------------------------

fn rw_incoming_free(incoming: [*c]rw_incoming_t) void {
    web.rw_free(incoming.*.message);
    web.rw_free(incoming.*.session);
    if (incoming.*.pixels != null) raven.Rpixels_free(incoming.*.pixels);
    web.rw_free(incoming);
}

/// UI thread: gives the views what the browser said since the last time.
fn rw_drain(unused: ?*anyopaque) callconv(.c) void {
    _ = unused;
    // (stopped since the task was posted)
    if (g_rw.mutex == null) return;
    web.rw_mutex_lock(g_rw.mutex);
    var list = g_rw.first;
    g_rw.first = null;
    g_rw.last = null;
    g_rw.posted = 0;
    web.rw_mutex_unlock(g_rw.mutex);
    while (list != null) {
        const next = list.*.next;
        // (a view may stop the browser from here: the rest is then only released)
        if (g_rw.mutex != null) web.rw_views_incoming(list);
        rw_incoming_free(list);
        list = next;
    }
}

/// Reading thread.
fn rw_hand_over(incoming: [*c]rw_incoming_t) void {
    web.rw_mutex_lock(g_rw.mutex);
    if (incoming.*.pixels != null) {
        // a picture the UI thread has not taken yet is replaced: only the last one matters
        var waiting = g_rw.first;
        while (waiting != null) : (waiting = waiting.*.next) {
            if (waiting.*.pixels != null and libc.strcmp(waiting.*.session, incoming.*.session) == 0) {
                const old = waiting.*.pixels;
                waiting.*.pixels = incoming.*.pixels;
                waiting.*.width = incoming.*.width;
                waiting.*.height = incoming.*.height;
                incoming.*.pixels = old;
                web.rw_mutex_unlock(g_rw.mutex);
                rw_incoming_free(incoming);
                return;
            }
        }
    }
    incoming.*.next = null;
    if (g_rw.last != null) {
        g_rw.last.*.next = incoming;
    } else {
        g_rw.first = incoming;
    }
    g_rw.last = incoming;
    const post = g_rw.posted == 0;
    g_rw.posted = 1;
    web.rw_mutex_unlock(g_rw.mutex);
    if (post) raven.Rtask_post(&rw_drain, null);
}

const frame = "\"method\":\"Page.screencastFrame\"";

/// Reading thread: one message of the browser. The text is ours to change.
fn rw_reader_message(text: [*c]u8, size: usize) void {
    const incoming: [*c]rw_incoming_t = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_incoming_t))));
    const head: usize = if (size < 80) size else 80;
    var is_frame = false;

    if (incoming == null) return;
    incoming.* = std.mem.zeroes(rw_incoming_t);
    var i: usize = 0;
    while (i + frame.len <= head and !is_frame) : (i += 1) is_frame = libc.memcmp(text + i, frame, frame.len) == 0;
    if (is_frame) {
        var document: rw_json_document_t = undefined;
        if (web.rw_json_parse(&document, text, size) != 0) {
            const data = web.rw_json_get(document.root, "params.data");
            const session = web.rw_json_string(document.root, "sessionId", null);
            var params: [64]u8 = undefined;
            // tell the browser at once that this one arrived: it sends the next when the page changes again
            _ = libc.snprintf(&params, params.len, "{\"sessionId\":%d}", @as(c_int, @intFromFloat(web.rw_json_number(document.root, "params.sessionId", 0.0))));
            _ = rw_browser_send(session, "Page.screencastFrameAck", &params);
            if (data != null and data.*.type == web.RW_JSON_STRING and session != null) {
                var bytes: usize = 0;
                const file = web.rw_base64_decode(data.*.string, data.*.length, &bytes);
                if (file != null) {
                    incoming.*.pixels = raven.Rimage_decode(file, bytes, &incoming.*.width, &incoming.*.height);
                    web.rw_free(file);
                }
                if (incoming.*.pixels != null) incoming.*.session = web.rw_strdup(session);
            }
            web.rw_json_free(&document);
        }
        if (incoming.*.pixels == null or incoming.*.session == null) {
            rw_incoming_free(incoming);
            return;
        }
    } else {
        incoming.*.message = @ptrCast(web.rw_alloc(size + 1));
        if (incoming.*.message == null) {
            web.rw_free(incoming);
            return;
        }
        @memcpy(incoming.*.message[0..size], text[0..size]);
        incoming.*.message[size] = 0;
        incoming.*.size = size;
    }
    rw_hand_over(incoming);
}

fn rw_reader_main(unused: ?*anyopaque) callconv(.c) void {
    var buffer: [*c]u8 = null;
    var length: usize = 0;
    var capacity: usize = 0;
    _ = unused;

    while (true) {
        var scanned = length;
        if (capacity - length < 65536) {
            const larger: usize = if (capacity != 0) capacity * 2 else @as(usize, 1) << 18;
            const grown: [*c]u8 = @ptrCast(web.rw_realloc(buffer, larger));
            if (grown == null) break;
            buffer = grown;
            capacity = larger;
        }
        const got = web.rw_process_read(g_rw.process, buffer + length, capacity - length);
        if (got <= 0) break;
        length += @intCast(got);
        // the messages that are complete now
        while (true) {
            const end: [*c]u8 = @ptrCast(libc.memchr(buffer + scanned, 0, length - scanned));
            if (end == null) break;
            const size: usize = @intCast(end - buffer);
            if (size > 0) rw_reader_message(buffer, size);
            _ = libc.memmove(buffer, end + 1, length - size - 1);
            length -= size + 1;
            scanned = 0;
        }
    }
    web.rw_free(buffer);
    const closed: [*c]rw_incoming_t = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_incoming_t))));
    if (closed != null) {
        closed.* = std.mem.zeroes(rw_incoming_t);
        closed.*.closed = 1;
        rw_hand_over(closed);
    }
}

// ---------------------------------------------------------------------------
//  Commands
// ---------------------------------------------------------------------------

export fn rw_browser_send(session: [*c]const u8, method: [*c]const u8, params: [*c]const u8) c_int {
    var text: rw_text_t = undefined;
    if (g_rw.process == null or g_rw.mutex == null) return 0;
    text = std.mem.zeroes(rw_text_t);
    web.rw_mutex_lock(g_rw.mutex);
    g_rw.next_id += 1;
    const id = g_rw.next_id;
    web.rw_text_printf(&text, "{\"id\":%d,\"method\":", id);
    web.rw_text_json(&text, method);
    if (params != null and params[0] != 0) {
        web.rw_text_puts(&text, ",\"params\":");
        web.rw_text_puts(&text, params);
    }
    if (session != null and session[0] != 0) {
        web.rw_text_puts(&text, ",\"sessionId\":");
        web.rw_text_json(&text, session);
    }
    web.rw_text_puts(&text, "}");
    // (the zero that ends the text is the end of the message)
    const sent = text.data != null and web.rw_process_write(g_rw.process, text.data, text.length + 1) != 0;
    web.rw_mutex_unlock(g_rw.mutex);
    web.rw_text_free(&text);
    return if (sent) id else 0;
}

// ---------------------------------------------------------------------------
//  Start and stop
// ---------------------------------------------------------------------------

export fn rw_browser_error() [*c]const u8 {
    return &g_rw.@"error";
}

export fn rw_browser_running() c_int {
    return @intFromBool(g_rw.process != null);
}

/// The program to run: the one that was given, the one of the environment, one that is installed. To release with free.
fn rw_browser_program() [*c]u8 {
    var environment: [*c]const u8 = libc.getenv("RAVEN_WEB_BROWSER");
    var copy: [*c]u8 = undefined;
    if (g_rw_browser_path != null and g_rw_browser_path[0] != 0) environment = g_rw_browser_path;
    if (environment != null and environment[0] != 0) {
        copy = @ptrCast(libc.malloc(libc.strlen(environment) + 1));
        if (copy != null) _ = strcpy(copy, environment);
        return copy;
    }
    const found = web.rw_find_browser();
    if (found == null) return null;
    copy = @ptrCast(libc.malloc(libc.strlen(found) + 1));
    if (copy != null) _ = strcpy(copy, found);
    web.rw_free(found);
    return copy;
}

export fn rw_browser_start() c_int {
    var arguments: [64][*c]const u8 = undefined;
    var extra: [*c]u8 = null;
    var profile: rw_text_t = undefined;
    var count: usize = 0;

    if (g_rw.process != null) return 1;
    g_rw.@"error"[0] = 0;
    const program = rw_browser_program();
    if (program == null or web.rw_is_program(program) == 0) {
        if (program != null) {
            _ = libc.snprintf(&g_rw.@"error", g_rw.@"error".len, "The browser \"%.180s\" was not found.", program);
        } else {
            _ = libc.snprintf(&g_rw.@"error", g_rw.@"error".len, "No browser of the Chromium family (Edge, Chrome, Chromium) was found on this computer.");
        }
        libc.free(program);
        return 0;
    }

    if (g_rw_profile_folder != null and g_rw_profile_folder[0] != 0) {
        g_rw.profile = web.rw_strdup(g_rw_profile_folder);
        g_rw.profile_temporary = 0;
    } else {
        g_rw.profile = web.rw_temp_folder();
        g_rw.profile_temporary = 1;
    }
    if (g_rw.profile == null) {
        _ = libc.snprintf(&g_rw.@"error", g_rw.@"error".len, "No folder could be made for the profile of the browser.");
        libc.free(program);
        return 0;
    }
    profile = std.mem.zeroes(rw_text_t);
    web.rw_text_printf(&profile, "--user-data-dir=%s", g_rw.profile);

    const fixed = [_][*c]const u8{
        program,
        // hidden, driven through the pipe, with a profile that is not the one of the user
        "--headless",
        "--remote-debugging-pipe",
        profile.data,
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-extensions",
        "--disable-component-update",
        "--disable-sync",
        "--disable-default-apps",
        // It only talks to the sites the application shows: no updates, no
        // reports, no account, no messaging service, no lists of dangerous sites,
        // no clock, no warm-up of the search engine. (The services that have no
        // switch are given an address where nobody answers.)
        "--disable-background-networking",
        "--disable-client-side-phishing-detection",
        "--disable-domain-reliability",
        "--disable-breakpad",
        "--metrics-recording-only",
        "--no-pings",
        "--no-service-autorun",
        "--disable-features=Translate,MediaRouter,OptimizationHints,PreconnectToSearch,NetworkTimeServiceQuerying,LensOverlay," ++
            "AimServerEligibilityEnabled,AimServerRequestOnStartupEnabled,AutofillServerCommunication,CertificateTransparencyComponentUpdater",
        "--gaia-url=http://127.0.0.1:9",
        "--google-apis-url=http://127.0.0.1:9",
        "--lso-url=http://127.0.0.1:9",
        "--oauth-account-manager-url=http://127.0.0.1:9",
        "--gcm-checkin-url=http://127.0.0.1:9/",
        "--gcm-mcs-endpoint=127.0.0.1:9",
        "--gcm-registration-url=http://127.0.0.1:9/",
        "--password-store=basic",
        "--use-mock-keychain",
        "--window-size=1280,800",
    };
    for (fixed) |argument| {
        arguments[count] = argument;
        count += 1;
    }
    if (builtin.os.tag != .windows) {
        // containers give little shared memory
        arguments[count] = "--disable-dev-shm-usage";
        count += 1;
    }
    if (web.rw_needs_no_sandbox() != 0 or libc.getenv("RAVEN_WEB_NO_SANDBOX") != null) {
        arguments[count] = "--no-sandbox";
        count += 1;
    }
    if ((g_rw_arguments != null and g_rw_arguments[0] != 0) or libc.getenv("RAVEN_WEB_ARGUMENTS") != null) {
        // what the application adds (or, without it, the environment), cut at the spaces
        extra = web.rw_strdup(if (g_rw_arguments != null and g_rw_arguments[0] != 0) g_rw_arguments else libc.getenv("RAVEN_WEB_ARGUMENTS"));
        var cursor = extra;
        while (cursor != null and cursor.* != 0 and count < 60) {
            while (cursor.* == ' ') cursor += 1;
            if (cursor.* == 0) break;
            arguments[count] = cursor;
            count += 1;
            while (cursor.* != 0 and cursor.* != ' ') cursor += 1;
            if (cursor.* != 0) {
                cursor.* = 0;
                cursor += 1;
            }
        }
    }
    arguments[count] = "about:blank";
    count += 1;
    arguments[count] = null;

    g_rw.mutex = web.rw_mutex_create();
    g_rw.process = if (g_rw.mutex != null) web.rw_process_start(&arguments) else null;
    if (g_rw.process != null) g_rw.reader = web.rw_thread_start(&rw_reader_main, null);
    web.rw_text_free(&profile);
    web.rw_free(extra);
    if (g_rw.process == null or g_rw.reader == null) {
        _ = libc.snprintf(&g_rw.@"error", g_rw.@"error".len, "The browser \"%.180s\" could not be started.", program);
        libc.free(program);
        rw_browser_stop();
        return 0;
    }
    libc.free(program);
    g_rw.next_id = 0;
    // to hear about the titles of the pages, and about the windows they open
    _ = rw_browser_send(null, "Target.setDiscoverTargets", "{\"discover\":true}");
    return 1;
}

export fn rw_browser_stop() void {
    if (g_rw.process != null) {
        _ = rw_browser_send(null, "Browser.close", null);
        web.rw_process_hang_up(g_rw.process);
    }
    if (g_rw.reader != null) web.rw_thread_join(g_rw.reader);
    g_rw.reader = null;
    if (g_rw.process != null) web.rw_process_stop(g_rw.process);
    g_rw.process = null;
    var list = g_rw.first;
    g_rw.first = null;
    g_rw.last = null;
    g_rw.posted = 0;
    while (list != null) {
        const next = list.*.next;
        rw_incoming_free(list);
        list = next;
    }
    if (g_rw.mutex != null) web.rw_mutex_destroy(g_rw.mutex);
    g_rw.mutex = null;
    if (g_rw.profile != null and g_rw.profile_temporary != 0) web.rw_remove_folder(g_rw.profile);
    web.rw_free(g_rw.profile);
    g_rw.profile = null;
}

// ---------------------------------------------------------------------------
//  Settings
// ---------------------------------------------------------------------------

/// (kept with malloc: they outlive Rshutdown, and are not a leak of the allocator of Raven)
fn rw_setting(setting: *[*c]u8, value: [*c]const u8) void {
    libc.free(setting.*);
    setting.* = null;
    if (value != null and value[0] != 0) {
        setting.* = @ptrCast(libc.malloc(libc.strlen(value) + 1));
        if (setting.* != null) _ = strcpy(setting.*, value);
    }
}

var g_rw_shown_path: [*c]u8 = null;

export fn Rweb_is_available() c_int {
    const program = rw_browser_program();
    const found = program != null and web.rw_is_program(program) != 0;
    libc.free(program);
    return @intFromBool(found);
}

export fn Rweb_set_browser_path(path: [*c]const u8) void {
    rw_setting(&g_rw_browser_path, path);
}

export fn Rweb_get_browser_path() [*c]const u8 {
    const program = rw_browser_program();
    libc.free(g_rw_shown_path);
    g_rw_shown_path = if (program != null and web.rw_is_program(program) != 0) program else null;
    if (g_rw_shown_path == null) libc.free(program);
    return if (g_rw_shown_path != null) g_rw_shown_path else "";
}

export fn Rweb_set_profile_folder(path: [*c]const u8) void {
    rw_setting(&g_rw_profile_folder, path);
}

export fn Rweb_set_browser_arguments(arguments: [*c]const u8) void {
    rw_setting(&g_rw_arguments, arguments);
}

export fn Rweb_shutdown() void {
    var closed: rw_incoming_t = undefined;
    if (g_rw.process != null) {
        // the views learn that nothing will come any more
        closed = std.mem.zeroes(rw_incoming_t);
        closed.closed = 2;
        web.rw_views_incoming(&closed);
    }
    rw_browser_stop();
    rw_setting(&g_rw_browser_path, null);
    rw_setting(&g_rw_profile_folder, null);
    rw_setting(&g_rw_arguments, null);
    libc.free(g_rw_shown_path);
    g_rw_shown_path = null;
}
