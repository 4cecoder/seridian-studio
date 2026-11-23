// Translated to Zig from vendor/raven/web/src/web_view.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Web - web_view.c
// The web view: a custom widget of Raven that shows the pictures of a page
// of the browser and sends it what the user does.
//
// A view is a "target" of the browser (a tab). It is created, then attached
// to (which gives the session all later commands name), and from then on it
// is ready. Commands asked before that wait in a list.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const web = @import("web_internal_h.zig");
const rweb = @import("raven_web_h.zig");
const libc = @import("../sys/libc.zig");

extern "c" fn fprintf(stream: ?*libc.FILE, format: [*c]const u8, ...) c_int;
extern "c" fn atof(s: [*c]const u8) f64;

const rw_state_t = c_uint;
/// Asked the browser for a page.
const RW_STATE_CREATING: c_int = 0;
/// Asked to be attached to it.
const RW_STATE_ATTACHING: c_int = 1;
const RW_STATE_READY: c_int = 2;
const RW_STATE_FAILED: c_int = 3;

const rw_kind_t = c_uint;
const RW_KIND_NONE: c_int = 0;
const RW_KIND_CREATE: c_int = 1;
const RW_KIND_ATTACH: c_int = 2;
/// A script of the application: its callback wants the result.
const RW_KIND_SCRIPT: c_int = 3;
const RW_KIND_HISTORY: c_int = 4;
/// The selection of the page, for the clipboard.
const RW_KIND_COPY: c_int = 5;
/// The title of the page, asked when it has loaded.
const RW_KIND_TITLE: c_int = 6;

/// A command whose answer is awaited.
const rw_request_t = extern struct {
    next: [*c]rw_request_t,
    id: c_int,
    kind: rw_kind_t,
    callback: rweb.RWebResultCallback,
    user: ?*anyopaque,
};

/// A command asked before the view was ready.
const rw_pending_t = extern struct {
    next: [*c]rw_pending_t,
    method: [*c]u8,
    params: [*c]u8,
    kind: rw_kind_t,
    callback: rweb.RWebResultCallback,
    user: ?*anyopaque,
};

const rw_view_t = extern struct {
    next: [*c]rw_view_t,
    widget: raven.Rid,
    state: rw_state_t,
    target: [*c]u8,
    session: [*c]u8,
    texture: raven.Rid,
    url: [*c]u8,
    title: [*c]u8,
    loading: c_int,
    /// Entries of the history to go back and forward to, or -1.
    back_entry: c_int,
    forward_entry: c_int,
    /// What the browser was last told about the size of the page.
    sent_width: f32,
    sent_height: f32,
    sent_scale: f32,
    sent_zoom: f32,
    zoom: f32,
    frames: rweb.RWebFrames,
    quality: c_int,
    requests: [*c]rw_request_t,
    pending: [*c]rw_pending_t,
    pending_last: [*c]rw_pending_t,
    message_callback: rweb.RWebMessageCallback,
    message_user: ?*anyopaque,
    event_callback: rweb.RWebEventCallback,
    event_user: ?*anyopaque,
    /// Mouse buttons held, as the protocol counts them.
    buttons: c_int,
    @"error": [256]u8,
};

var g_rw_views: [*c]rw_view_t = null;

/// What every page gets before its own scripts run: window.raven.postMessage.
const g_rw_bridge: [*c]const u8 =
    "(function(){ if (window.raven) return;" ++
    " window.raven = { postMessage: function(message) {" ++
    " window.ravenPostMessage(typeof message === 'string' ? message : JSON.stringify(message)); } }; })();";

// ---------------------------------------------------------------------------
//  Lists
// ---------------------------------------------------------------------------

fn rw_view_of(widget: raven.Rid) [*c]rw_view_t {
    var view: [*c]rw_view_t = g_rw_views;
    while (view != null) : (view = view.*.next) {
        if (view.*.widget == widget) return view;
    }
    return null;
}

// The view of a public function, which reports the mistake itself.
fn rw_view_checked(widget: raven.Rid, function: [*c]const u8) [*c]rw_view_t {
    const view = rw_view_of(widget);
    if (view == null or raven.Rwidget_is_valid(widget) == 0) {
        _ = fprintf(libc.stderrFile(), "[raven_web] %s: not a web view\n", function);
        return null;
    }
    return view;
}

fn rw_view_alive(wanted: [*c]const rw_view_t) c_int {
    var view: [*c]const rw_view_t = g_rw_views;
    while (view != null) : (view = view.*.next) {
        if (view == wanted) return 1;
    }
    return 0;
}

fn rw_view_set(field: [*c][*c]u8, value: [*c]const u8) void {
    web.rw_free(field.*);
    field.* = web.rw_strdup(if (value != null) value else "");
}

fn rw_view_notify(view: [*c]rw_view_t, event: rweb.RWebEvent) void {
    const widget = view.*.widget;
    if (view.*.event_callback) |event_callback| event_callback(widget, event, view.*.event_user);
    if (raven.Rwidget_is_valid(widget) != 0) raven.Rwidget_invalidate(widget);
}

fn rw_view_fail(view: [*c]rw_view_t, reason: [*c]const u8) void {
    var request: [*c]rw_request_t = undefined;
    var pending: [*c]rw_pending_t = undefined;
    if (view.*.state == RW_STATE_FAILED) return;
    view.*.state = RW_STATE_FAILED;
    view.*.loading = 0;
    _ = libc.snprintf(&view.*.@"error", @sizeOf(@TypeOf(view.*.@"error")), "%s", if (reason != null) reason else @as([*c]const u8, ""));
    // the scripts that were waiting learn that no answer will come
    request = view.*.requests;
    view.*.requests = null;
    pending = view.*.pending;
    view.*.pending_last = null;
    view.*.pending = view.*.pending_last;
    while (request != null) {
        const next = request.*.next;
        if (request.*.kind == RW_KIND_SCRIPT and request.*.callback != null and rw_view_alive(view) != 0) request.*.callback.?(view.*.widget, null, &view.*.@"error", request.*.user);
        web.rw_free(request);
        request = next;
    }
    while (pending != null) {
        const next = pending.*.next;
        if (pending.*.kind == RW_KIND_SCRIPT and pending.*.callback != null and rw_view_alive(view) != 0) pending.*.callback.?(view.*.widget, null, &view.*.@"error", pending.*.user);
        web.rw_free(pending.*.method);
        web.rw_free(pending.*.params);
        web.rw_free(pending);
        pending = next;
    }
    if (rw_view_alive(view) != 0) rw_view_notify(view, rweb.R_WEB_EVENT_FAILED);
}

// ---------------------------------------------------------------------------
//  Commands
// ---------------------------------------------------------------------------

fn rw_view_expect(view: [*c]rw_view_t, id: c_int, kind: rw_kind_t, callback: rweb.RWebResultCallback, user: ?*anyopaque) void {
    var request: [*c]rw_request_t = undefined;
    if (kind == RW_KIND_NONE) return;
    if (id == 0) {
        if (kind == RW_KIND_SCRIPT and callback != null) callback.?(view.*.widget, null, "the browser stopped", user);
        return;
    }
    request = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_request_t))));
    if (request == null) return;
    request.*.id = id;
    request.*.kind = kind;
    request.*.callback = callback;
    request.*.user = user;
    request.*.next = view.*.requests;
    view.*.requests = request;
}

// Sends a command to the page of a view, now or when the view is ready.
fn rw_view_send(view: [*c]rw_view_t, method: [*c]const u8, params: [*c]const u8, kind: rw_kind_t, callback: rweb.RWebResultCallback, user: ?*anyopaque) void {
    if (view.*.state == RW_STATE_FAILED) {
        if (kind == RW_KIND_SCRIPT and callback != null) callback.?(view.*.widget, null, &view.*.@"error", user);
        return;
    }
    if (view.*.state != RW_STATE_READY) {
        const pending: [*c]rw_pending_t = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_pending_t))));
        if (pending == null) return;
        pending.* = std.mem.zeroes(rw_pending_t);
        pending.*.method = web.rw_strdup(method);
        pending.*.params = web.rw_strdup(params);
        pending.*.kind = kind;
        pending.*.callback = callback;
        pending.*.user = user;
        if (view.*.pending_last != null) view.*.pending_last.*.next = pending else view.*.pending = pending;
        view.*.pending_last = pending;
        return;
    }
    rw_view_expect(view, web.rw_browser_send(view.*.session, method, params), kind, callback, user);
}

fn rw_view_script(view: [*c]rw_view_t, script: [*c]const u8, kind: rw_kind_t, callback: rweb.RWebResultCallback, user: ?*anyopaque) void {
    var params: web.rw_text_t = std.mem.zeroes(web.rw_text_t);
    web.rw_text_puts(&params, "{\"expression\":");
    web.rw_text_json(&params, script);
    web.rw_text_puts(&params, ",\"returnByValue\":true,\"awaitPromise\":true,\"userGesture\":true}");
    rw_view_send(view, "Runtime.evaluate", params.data, kind, callback, user);
    web.rw_text_free(&params);
}

// Tells the browser how large the page is shown.
fn rw_view_metrics(view: [*c]rw_view_t, width: f32, height: f32, scale: f32) void {
    var params: [200]u8 = undefined;
    const zoom: f32 = if (view.*.zoom > 0.0) view.*.zoom else 1.0;
    var w: c_int = toInt(@floor(width / zoom + 0.5), 1);
    var h: c_int = toInt(@floor(height / zoom + 0.5), 1);
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    view.*.sent_width = width;
    view.*.sent_height = height;
    view.*.sent_scale = scale;
    view.*.sent_zoom = zoom;
    _ = libc.snprintf(&params, params.len, "{\"width\":%d,\"height\":%d,\"deviceScaleFactor\":%.4f,\"mobile\":false}", w, h, @as(f64, scale * zoom));
    rw_view_send(view, "Emulation.setDeviceMetricsOverride", &params, RW_KIND_NONE, null, null);
}

fn rw_view_cast(view: [*c]rw_view_t) void {
    var params: [120]u8 = undefined;
    if (view.*.frames == rweb.R_WEB_FRAMES_JPEG) _ = libc.snprintf(&params, params.len, "{\"format\":\"jpeg\",\"quality\":%d,\"everyNthFrame\":1}", view.*.quality) else _ = libc.snprintf(&params, params.len, "{\"format\":\"png\",\"everyNthFrame\":1}");
    rw_view_send(view, "Page.startScreencast", &params, RW_KIND_NONE, null, null);
}

// The session exists: the page is set up, and what was asked meanwhile is sent.
fn rw_view_ready(view: [*c]rw_view_t) void {
    var pending: [*c]rw_pending_t = view.*.pending;
    var params: web.rw_text_t = undefined;
    view.*.pending_last = null;
    view.*.pending = view.*.pending_last;
    view.*.state = RW_STATE_READY;

    rw_view_send(view, "Page.enable", null, RW_KIND_NONE, null, null);
    rw_view_send(view, "Runtime.enable", null, RW_KIND_NONE, null, null);
    rw_view_send(view, "Runtime.addBinding", "{\"name\":\"ravenPostMessage\"}", RW_KIND_NONE, null, null);
    params = std.mem.zeroes(web.rw_text_t);
    web.rw_text_puts(&params, "{\"source\":");
    web.rw_text_json(&params, g_rw_bridge);
    web.rw_text_puts(&params, "}");
    rw_view_send(view, "Page.addScriptToEvaluateOnNewDocument", params.data, RW_KIND_NONE, null, null);
    web.rw_text_free(&params);
    // the page believes it has the focus: carets blink, :focus applies
    rw_view_send(view, "Emulation.setFocusEmulationEnabled", "{\"enabled\":true}", RW_KIND_NONE, null, null);
    if (view.*.sent_width > 0.0) rw_view_metrics(view, view.*.sent_width, view.*.sent_height, view.*.sent_scale);
    rw_view_cast(view);

    while (pending != null) {
        const next = pending.*.next;
        if (rw_view_alive(view) != 0 and view.*.state == RW_STATE_READY) {
            rw_view_expect(view, web.rw_browser_send(view.*.session, pending.*.method, pending.*.params), pending.*.kind, pending.*.callback, pending.*.user);
        }
        web.rw_free(pending.*.method);
        web.rw_free(pending.*.params);
        web.rw_free(pending);
        pending = next;
    }
    if (rw_view_alive(view) != 0 and raven.Rwidget_is_valid(view.*.widget) != 0) raven.Rwidget_invalidate(view.*.widget);
}

fn rw_view_open(view: [*c]rw_view_t) void {
    if (web.rw_browser_start() == 0) {
        rw_view_fail(view, web.rw_browser_error());
        return;
    }
    view.*.state = RW_STATE_CREATING;
    rw_view_expect(view, web.rw_browser_send(null, "Target.createTarget", "{\"url\":\"about:blank\"}"), RW_KIND_CREATE, null, null);
}

// ---------------------------------------------------------------------------
//  What the browser says
// ---------------------------------------------------------------------------

fn rw_view_by_session(session: [*c]const u8) [*c]rw_view_t {
    var view: [*c]rw_view_t = undefined;
    if (session == null) return null;
    view = g_rw_views;
    while (view != null) : (view = view.*.next) {
        if (view.*.session != null and libc.strcmp(view.*.session, session) == 0) return view;
    }
    return null;
}

fn rw_view_by_target(target: [*c]const u8) [*c]rw_view_t {
    var view: [*c]rw_view_t = undefined;
    if (target == null) return null;
    view = g_rw_views;
    while (view != null) : (view = view.*.next) {
        if (view.*.target != null and libc.strcmp(view.*.target, target) == 0) return view;
    }
    return null;
}

fn rw_view_navigated(view: [*c]rw_view_t, url: [*c]const u8) void {
    const widget = view.*.widget;
    if (url == null or (view.*.url != null and libc.strcmp(view.*.url, url) == 0)) return;
    rw_view_set(&view.*.url, url);
    rw_view_send(view, "Page.getNavigationHistory", null, RW_KIND_HISTORY, null, null);
    rw_view_notify(view, rweb.R_WEB_EVENT_NAVIGATED);
    // the action of the widget: what OnChanged names in XML
    if (rw_view_alive(view) != 0 and raven.Rwidget_is_valid(widget) != 0) {
        const action = raven.Rwidget_get_action(widget);
        if (action != null and action[0] != 0) raven.Raction_fire(action, widget);
    }
}

fn rw_answer(view: [*c]rw_view_t, request: [*c]rw_request_t, message: [*c]const web.rw_json_t) void {
    const @"error" = web.rw_json_get(message, "error");
    const result = web.rw_json_get(message, "result");
    switch (request.*.kind) {
        RW_KIND_CREATE => {
            const target = web.rw_json_string(result, "targetId", null);
            var params: [200]u8 = undefined;
            if (target == null) {
                rw_view_fail(view, web.rw_json_string(@"error", "message", "The browser could not open a page."));
                return;
            }
            rw_view_set(&view.*.target, target);
            view.*.state = RW_STATE_ATTACHING;
            _ = libc.snprintf(&params, params.len, "{\"targetId\":\"%.120s\",\"flatten\":true}", target);
            rw_view_expect(view, web.rw_browser_send(null, "Target.attachToTarget", &params), RW_KIND_ATTACH, null, null);
        },
        RW_KIND_ATTACH => {
            const session = web.rw_json_string(result, "sessionId", null);
            if (session == null) {
                rw_view_fail(view, web.rw_json_string(@"error", "message", "The browser could not open a page."));
                return;
            }
            rw_view_set(&view.*.session, session);
            rw_view_ready(view);
        },
        RW_KIND_SCRIPT => {
            const exception = web.rw_json_get(result, "exceptionDetails");
            var text: web.rw_text_t = undefined;
            if (request.*.callback == null) return;
            text = std.mem.zeroes(web.rw_text_t);
            if (@"error" != null or exception != null) {
                const reason = if (@"error" != null) web.rw_json_string(@"error", "message", "the script could not be run") else web.rw_json_string(exception, "exception.description", web.rw_json_string(exception, "text", "the script failed"));
                request.*.callback.?(view.*.widget, null, reason, request.*.user);
                return;
            }
            // (a script that gives nothing, or something that cannot be written as JSON, gives null)
            web.rw_json_write(&text, web.rw_json_get(result, "result.value"));
            request.*.callback.?(view.*.widget, if (text.data != null) text.data else @as([*c]const u8, "null"), null, request.*.user);
            web.rw_text_free(&text);
        },
        RW_KIND_HISTORY => {
            const entries = web.rw_json_get(result, "entries");
            var entry: [*c]const web.rw_json_t = undefined;
            const current: c_int = toInt(web.rw_json_number(result, "currentIndex", -1.0), -1);
            var index: c_int = 0;
            var back: c_int = -1;
            var forward: c_int = -1;
            entry = if (entries != null) entries.*.first else null;
            while (entry != null) : ({
                entry = entry.*.next;
                index += 1;
            }) {
                // (the empty page every view starts on is not somewhere to go back to)
                if (index == current - 1 and !(index == 0 and libc.strcmp(web.rw_json_string(entry, "url", ""), "about:blank") == 0)) back = toInt(web.rw_json_number(entry, "id", -1.0), -1);
                if (index == current + 1) forward = toInt(web.rw_json_number(entry, "id", -1.0), -1);
            }
            if (back != view.*.back_entry or forward != view.*.forward_entry) {
                view.*.back_entry = back;
                view.*.forward_entry = forward;
                // (the buttons of the application follow)
                rw_view_notify(view, rweb.R_WEB_EVENT_NAVIGATED);
            }
        },
        RW_KIND_COPY => {
            const text = web.rw_json_string(result, "result.value", null);
            if (text != null and text[0] != 0) raven.Rclipboard_set_text(text);
        },
        RW_KIND_TITLE => {
            const title = web.rw_json_string(result, "result.value", null);
            if (title != null and (view.*.title == null or libc.strcmp(view.*.title, title) != 0)) {
                rw_view_set(&view.*.title, title);
                rw_view_notify(view, rweb.R_WEB_EVENT_TITLE);
            }
        },
        else => {},
    }
}

fn rw_event(view: [*c]rw_view_t, method: [*c]const u8, params: [*c]const web.rw_json_t) void {
    if (libc.strcmp(method, "Page.frameStartedLoading") == 0) {
        if (view.*.target != null and libc.strcmp(web.rw_json_string(params, "frameId", ""), view.*.target) == 0 and view.*.loading == 0) {
            view.*.loading = 1;
            rw_view_notify(view, rweb.R_WEB_EVENT_LOADING);
        }
    } else if (libc.strcmp(method, "Page.frameStoppedLoading") == 0) {
        if (view.*.target != null and libc.strcmp(web.rw_json_string(params, "frameId", ""), view.*.target) == 0 and view.*.loading != 0) {
            view.*.loading = 0;
            rw_view_send(view, "Page.getNavigationHistory", null, RW_KIND_HISTORY, null, null);
            rw_view_notify(view, rweb.R_WEB_EVENT_LOADED);
        }
    } else if (libc.strcmp(method, "Page.frameNavigated") == 0) {
        // the page itself, not a frame inside it
        if (web.rw_json_get(params, "frame.parentId") == null) rw_view_navigated(view, web.rw_json_string(params, "frame.url", null));
    } else if (libc.strcmp(method, "Page.navigatedWithinDocument") == 0) {
        if (view.*.target != null and libc.strcmp(web.rw_json_string(params, "frameId", ""), view.*.target) == 0) rw_view_navigated(view, web.rw_json_string(params, "url", null));
    } else if (libc.strcmp(method, "Page.domContentEventFired") == 0 or libc.strcmp(method, "Page.loadEventFired") == 0) {
        // (the browser only tells the titles of the pages it loaded itself, not of those written into the view)
        rw_view_script(view, "document.title || location.href", RW_KIND_TITLE, null, null);
        // (asked again here: when the page has only just been reached, the history may not hold it yet)
        rw_view_send(view, "Page.getNavigationHistory", null, RW_KIND_HISTORY, null, null);
    } else if (libc.strcmp(method, "Page.javascriptDialogOpening") == 0) {
        // alert, confirm, prompt: nobody can see them; they are accepted so that the page goes on
        rw_view_send(view, "Page.handleJavaScriptDialog", "{\"accept\":true}", RW_KIND_NONE, null, null);
    } else if (libc.strcmp(method, "Page.windowOpen") == 0) {
        // a link that asks for a new window opens here
        const url = web.rw_json_string(params, "url", null);
        if (url != null and url[0] != 0) Rweb_view_load_url(view.*.widget, url);
    } else if (libc.strcmp(method, "Runtime.bindingCalled") == 0) {
        if (libc.strcmp(web.rw_json_string(params, "name", ""), "ravenPostMessage") == 0 and view.*.message_callback != null) {
            view.*.message_callback.?(view.*.widget, web.rw_json_string(params, "payload", ""), view.*.message_user);
        }
    } else if (libc.strcmp(method, "Inspector.targetCrashed") == 0) {
        rw_view_fail(view, "The page stopped working.");
    }
}

export fn rw_views_incoming(incoming: [*c]web.rw_incoming_t) void {
    var document: web.rw_json_document_t = undefined;
    var view: [*c]rw_view_t = undefined;

    if (incoming.*.closed != 0) {
        // nothing will come any more
        const reason: [*c]const u8 = if (incoming.*.closed == 2) "The browser was stopped." else "The browser stopped.";
        view = g_rw_views;
        while (view != null) : (view = view.*.next) {
            if (view.*.state != RW_STATE_FAILED) {
                rw_view_fail(view, reason);
                // (a callback may have deleted views: start again)
                view = g_rw_views;
                if (view == null) break;
            }
        }
        if (incoming.*.closed == 1) web.rw_browser_stop();
        return;
    }
    if (incoming.*.pixels != null) {
        view = rw_view_by_session(incoming.*.session);
        if (view == null or raven.Rwidget_is_valid(view.*.widget) == 0) return;
        if (view.*.texture != raven.R_INVALID_ID and raven.Rtexture_is_valid(view.*.texture) != 0) raven.Rtexture_update(view.*.texture, incoming.*.pixels, incoming.*.width, incoming.*.height) else view.*.texture = raven.Rtexture_create_from_pixels(incoming.*.pixels, incoming.*.width, incoming.*.height);
        raven.Rwidget_invalidate(view.*.widget);
        return;
    }
    if (incoming.*.message == null) return;
    // RAVEN_WEB_TRACE=1 shows what the browser says
    if (libc.getenv("RAVEN_WEB_TRACE") != null) _ = fprintf(libc.stderrFile(), "[raven_web] < %.300s\n", incoming.*.message);
    if (web.rw_json_parse(&document, incoming.*.message, incoming.*.size) == 0) return;
    {
        const id = web.rw_json_get(document.root, "id");
        const method = web.rw_json_string(document.root, "method", null);
        if (id != null and id.*.type == web.RW_JSON_NUMBER) {
            // the answer to a command: the view that waits for it
            const number: c_int = toInt(id.*.number, -1);
            view = g_rw_views;
            while (view != null) : (view = view.*.next) {
                var link: [*c][*c]rw_request_t = &view.*.requests;
                while (link.* != null) : (link = &link.*.*.next) {
                    if (link.*.*.id == number) {
                        const request = link.*;
                        link.* = request.*.next;
                        rw_answer(view, request, document.root);
                        web.rw_free(request);
                        web.rw_json_free(&document);
                        return;
                    }
                }
            }
        } else if (method != null) {
            const params = web.rw_json_get(document.root, "params");
            const session = web.rw_json_string(document.root, "sessionId", null);
            if (session != null) {
                view = rw_view_by_session(session);
                if (view != null) rw_event(view, method, params);
            } else if (libc.strcmp(method, "Target.targetInfoChanged") == 0) {
                view = rw_view_by_target(web.rw_json_string(params, "targetInfo.targetId", null));
                if (view != null) {
                    const title = web.rw_json_string(params, "targetInfo.title", "");
                    if (title[0] != 0 and (view.*.title == null or libc.strcmp(view.*.title, title) != 0)) {
                        rw_view_set(&view.*.title, title);
                        rw_view_notify(view, rweb.R_WEB_EVENT_TITLE);
                    }
                }
            } else if (libc.strcmp(method, "Target.targetCreated") == 0) {
                // a window opened by one of our pages: there is nowhere to show it
                const opener = web.rw_json_string(params, "targetInfo.openerId", null);
                const target = web.rw_json_string(params, "targetInfo.targetId", null);
                if (opener != null and target != null and rw_view_by_target(opener) != null) {
                    var close: [200]u8 = undefined;
                    _ = libc.snprintf(&close, close.len, "{\"targetId\":\"%.120s\"}", target);
                    _ = web.rw_browser_send(null, "Target.closeTarget", &close);
                }
            } else if (libc.strcmp(method, "Target.targetCrashed") == 0 or libc.strcmp(method, "Target.targetDestroyed") == 0) {
                view = rw_view_by_target(web.rw_json_string(params, "targetId", null));
                if (view != null) rw_view_fail(view, "The page stopped working.");
            }
        }
    }
    web.rw_json_free(&document);
}

// ---------------------------------------------------------------------------
//  The widget
// ---------------------------------------------------------------------------

fn rw_view_measure(widget: raven.Rid, width: [*c]f32, height: [*c]f32, user_data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    _ = user_data;
    width.* = 480.0;
    height.* = 320.0;
}

fn rw_view_paint(widget: raven.Rid, painter: ?*raven.RPainter, width: f32, height: f32, user_data: ?*anyopaque) callconv(.c) void {
    const view: [*c]rw_view_t = @ptrCast(@alignCast(user_data));
    var scale: f32 = raven.Rwindow_get_scale(raven.Rwidget_get_window(widget));
    var r: f32 = undefined;
    var g: f32 = undefined;
    var b: f32 = undefined;
    var a: f32 = undefined;
    if (scale <= 0.0) scale = 1.0;

    // the page follows the size of the widget
    if (width >= 1.0 and height >= 1.0 and view.*.state != RW_STATE_FAILED and
        (@abs(width - view.*.sent_width) > 0.5 or @abs(height - view.*.sent_height) > 0.5 or scale != view.*.sent_scale or view.*.zoom != view.*.sent_zoom))
    {
        if (view.*.state == RW_STATE_READY) {
            rw_view_metrics(view, width, height, scale);
        } else {
            // (sent when the view is ready)
            view.*.sent_width = width;
            view.*.sent_height = height;
            view.*.sent_scale = scale;
            view.*.sent_zoom = view.*.zoom;
        }
    }

    raven.Rdraw_push_clip_rect(painter, 0.0, 0.0, width, height);
    if (view.*.texture != raven.R_INVALID_ID and raven.Rtexture_is_valid(view.*.texture) != 0) {
        raven.Rdraw_image(painter, view.*.texture, 0.0, 0.0, width, height, 1.0, 1.0, 1.0, 1.0);
    } else {
        raven.Rwidget_get_color(widget, raven.R_COLOR_INPUT, &r, &g, &b, &a);
        raven.Rdraw_rect(painter, 0.0, 0.0, width, height, 0.0, r, g, b, a);
    }
    if (view.*.state == RW_STATE_FAILED or view.*.texture == raven.R_INVALID_ID) {
        // what is going on, where the page would be
        const text: [*c]const u8 = if (view.*.state == RW_STATE_FAILED) &view.*.@"error" else "Starting the browser...";
        var text_width: f32 = 0.0;
        var text_height: f32 = 0.0;
        raven.Rfont_measure_text(raven.R_INVALID_ID, 0.0, text, &text_width, &text_height);
        raven.Rwidget_get_color(widget, raven.R_COLOR_TEXT, &r, &g, &b, &a);
        if (view.*.state == RW_STATE_FAILED and view.*.texture != raven.R_INVALID_ID) {
            // over the last picture of the page: on a band, to be readable
            var pr: f32 = undefined;
            var pg: f32 = undefined;
            var pb: f32 = undefined;
            var pa: f32 = undefined;
            raven.Rwidget_get_color(widget, raven.R_COLOR_POPUP, &pr, &pg, &pb, &pa);
            raven.Rdraw_rect(painter, 0.0, height * 0.5 - text_height, width, text_height * 2.0, 0.0, pr, pg, pb, 0.92);
        }
        raven.Rdraw_text(painter, raven.R_INVALID_ID, 0.0, @floor((width - text_width) * 0.5), @floor((height - text_height) * 0.5), text, r, g, b, a * 0.75);
    }
    if (view.*.loading != 0) {
        // a page is on its way
        raven.Rwidget_get_color(widget, raven.R_COLOR_ACCENT, &r, &g, &b, &a);
        raven.Rdraw_rect(painter, 0.0, 0.0, width, 2.0, 0.0, r, g, b, a);
    }
    raven.Rdraw_pop_clip_rect(painter);
}

// A modifier mask of Raven as the protocol wants it: Alt 1, Ctrl 2, Meta 4, Shift 8.
fn rw_modifiers(modifiers: raven.Ruint) c_int {
    return (if ((modifiers & raven.R_MOD_ALT) != 0) @as(c_int, 1) else 0) | (if ((modifiers & raven.R_MOD_CTRL) != 0) @as(c_int, 2) else 0) | (if ((modifiers & raven.R_MOD_SUPER) != 0) @as(c_int, 4) else 0) | (if ((modifiers & raven.R_MOD_SHIFT) != 0) @as(c_int, 8) else 0);
}

fn rw_view_mouse(view: [*c]rw_view_t, type_: [*c]const u8, event: [*c]const raven.REvent, button: [*c]const u8, clicks: c_int, delta_x: f32, delta_y: f32) void {
    var params: [320]u8 = undefined;
    const zoom: f32 = if (view.*.zoom > 0.0) view.*.zoom else 1.0;
    _ = libc.snprintf(&params, params.len, "{\"type\":\"%s\",\"x\":%.2f,\"y\":%.2f,\"modifiers\":%d,\"button\":\"%s\",\"buttons\":%d,\"clickCount\":%d,\"deltaX\":%.2f,\"deltaY\":%.2f}", type_, @as(f64, event.*.local_x / zoom), @as(f64, event.*.local_y / zoom), rw_modifiers(event.*.modifiers), button, view.*.buttons, clicks, @as(f64, delta_x), @as(f64, delta_y));
    rw_view_send(view, "Input.dispatchMouseEvent", &params, RW_KIND_NONE, null, null);
}

const rw_key_t = extern struct {
    key: raven.RKey,
    code: c_int,
    physical: [*c]const u8,
    name: [*c]const u8,
};

// The keys that are not characters: their Windows code, their place on the keyboard, their name for the page.
const g_rw_keys = [_]rw_key_t{
    .{ .key = raven.R_KEY_ESCAPE, .code = 27, .physical = "Escape", .name = "Escape" },          .{ .key = raven.R_KEY_ENTER, .code = 13, .physical = "Enter", .name = "Enter" },               .{ .key = raven.R_KEY_KP_ENTER, .code = 13, .physical = "NumpadEnter", .name = "Enter" },
    .{ .key = raven.R_KEY_TAB, .code = 9, .physical = "Tab", .name = "Tab" },                    .{ .key = raven.R_KEY_BACKSPACE, .code = 8, .physical = "Backspace", .name = "Backspace" },    .{ .key = raven.R_KEY_INSERT, .code = 45, .physical = "Insert", .name = "Insert" },
    .{ .key = raven.R_KEY_DELETE, .code = 46, .physical = "Delete", .name = "Delete" },          .{ .key = raven.R_KEY_RIGHT, .code = 39, .physical = "ArrowRight", .name = "ArrowRight" },     .{ .key = raven.R_KEY_LEFT, .code = 37, .physical = "ArrowLeft", .name = "ArrowLeft" },
    .{ .key = raven.R_KEY_DOWN, .code = 40, .physical = "ArrowDown", .name = "ArrowDown" },      .{ .key = raven.R_KEY_UP, .code = 38, .physical = "ArrowUp", .name = "ArrowUp" },              .{ .key = raven.R_KEY_PAGE_UP, .code = 33, .physical = "PageUp", .name = "PageUp" },
    .{ .key = raven.R_KEY_PAGE_DOWN, .code = 34, .physical = "PageDown", .name = "PageDown" },   .{ .key = raven.R_KEY_HOME, .code = 36, .physical = "Home", .name = "Home" },                  .{ .key = raven.R_KEY_END, .code = 35, .physical = "End", .name = "End" },
    .{ .key = raven.R_KEY_SPACE, .code = 32, .physical = "Space", .name = " " },                 .{ .key = raven.R_KEY_LEFT_SHIFT, .code = 16, .physical = "ShiftLeft", .name = "Shift" },      .{ .key = raven.R_KEY_RIGHT_SHIFT, .code = 16, .physical = "ShiftRight", .name = "Shift" },
    .{ .key = raven.R_KEY_LEFT_CTRL, .code = 17, .physical = "ControlLeft", .name = "Control" }, .{ .key = raven.R_KEY_RIGHT_CTRL, .code = 17, .physical = "ControlRight", .name = "Control" }, .{ .key = raven.R_KEY_LEFT_ALT, .code = 18, .physical = "AltLeft", .name = "Alt" },
    .{ .key = raven.R_KEY_RIGHT_ALT, .code = 18, .physical = "AltRight", .name = "Alt" },        .{ .key = raven.R_KEY_LEFT_SUPER, .code = 91, .physical = "MetaLeft", .name = "Meta" },        .{ .key = raven.R_KEY_RIGHT_SUPER, .code = 92, .physical = "MetaRight", .name = "Meta" },
    .{ .key = raven.R_KEY_F1, .code = 112, .physical = "F1", .name = "F1" },                     .{ .key = raven.R_KEY_F2, .code = 113, .physical = "F2", .name = "F2" },                       .{ .key = raven.R_KEY_F3, .code = 114, .physical = "F3", .name = "F3" },
    .{ .key = raven.R_KEY_F4, .code = 115, .physical = "F4", .name = "F4" },                     .{ .key = raven.R_KEY_F5, .code = 116, .physical = "F5", .name = "F5" },                       .{ .key = raven.R_KEY_F6, .code = 117, .physical = "F6", .name = "F6" },
    .{ .key = raven.R_KEY_F7, .code = 118, .physical = "F7", .name = "F7" },                     .{ .key = raven.R_KEY_F8, .code = 119, .physical = "F8", .name = "F8" },                       .{ .key = raven.R_KEY_F9, .code = 120, .physical = "F9", .name = "F9" },
    .{ .key = raven.R_KEY_F10, .code = 121, .physical = "F10", .name = "F10" },                  .{ .key = raven.R_KEY_F11, .code = 122, .physical = "F11", .name = "F11" },                    .{ .key = raven.R_KEY_F12, .code = 123, .physical = "F12", .name = "F12" },
};

fn rw_view_key(view: [*c]rw_view_t, event: [*c]const raven.REvent, down: c_int) void {
    var params: web.rw_text_t = undefined;
    var physical: [16]u8 = undefined;
    var name: [8]u8 = undefined;
    var key_physical: [*c]const u8 = "";
    var key_name: [*c]const u8 = "";
    var command: [*c]const u8 = null;
    var code: c_int = 0;
    var i: usize = 0;

    while (i < g_rw_keys.len) : (i += 1) {
        if (g_rw_keys[i].key == event.*.key) {
            code = g_rw_keys[i].code;
            key_physical = g_rw_keys[i].physical;
            key_name = g_rw_keys[i].name;
            break;
        }
    }
    if (code == 0 and event.*.key >= raven.R_KEY_A and event.*.key <= raven.R_KEY_Z) {
        code = @bitCast(event.*.key);
        _ = libc.snprintf(&physical, physical.len, "Key%c", @as(c_int, @as(u8, @truncate(event.*.key))));
        _ = libc.snprintf(&name, name.len, "%c", @as(c_int, @as(u8, @truncate(if ((event.*.modifiers & raven.R_MOD_SHIFT) != 0) event.*.key else event.*.key +% 32))));
        key_physical = &physical;
        key_name = &name;
    } else if (code == 0 and event.*.key >= raven.R_KEY_0 and event.*.key <= raven.R_KEY_9) {
        code = @bitCast(event.*.key);
        _ = libc.snprintf(&physical, physical.len, "Digit%c", @as(c_int, @as(u8, @truncate(event.*.key))));
        _ = libc.snprintf(&name, name.len, "%c", @as(c_int, @as(u8, @truncate(event.*.key))));
        key_physical = &physical;
        key_name = &name;
    }
    if (code == 0) return;

    if (down != 0 and (event.*.modifiers & raven.R_MOD_CTRL) != 0 and !((event.*.modifiers & raven.R_MOD_ALT) != 0)) {
        // the shortcuts of editing are commands of the browser; its clipboard is not the one of the system, so text is carried over by hand
        switch (event.*.key) {
            raven.R_KEY_A => command = "selectAll",
            raven.R_KEY_Z => command = if ((event.*.modifiers & raven.R_MOD_SHIFT) != 0) "redo" else "undo",
            raven.R_KEY_Y => command = "redo",
            raven.R_KEY_C => {
                rw_view_script(view, "String(window.getSelection())", RW_KIND_COPY, null, null);
            },
            raven.R_KEY_X => {
                rw_view_script(view, "String(window.getSelection())", RW_KIND_COPY, null, null);
                command = "delete";
            },
            raven.R_KEY_V => {
                const text = raven.Rclipboard_get_text();
                if (text != null and text[0] != 0) {
                    params = std.mem.zeroes(web.rw_text_t);
                    web.rw_text_puts(&params, "{\"text\":");
                    web.rw_text_json(&params, text);
                    web.rw_text_puts(&params, "}");
                    rw_view_send(view, "Input.insertText", params.data, RW_KIND_NONE, null, null);
                    web.rw_text_free(&params);
                }
                return;
            },
            else => {},
        }
    }

    if (comptime builtin.os.tag.isDarwin()) {
        // Chrome on macOS takes the editing keys from their commands only (as its own NSResponder would)
        if (down != 0 and command == null and !((event.*.modifiers & (raven.R_MOD_CTRL | raven.R_MOD_ALT)) != 0)) {
            const shift: c_int = @intFromBool((event.*.modifiers & raven.R_MOD_SHIFT) != 0);
            switch (code) {
                8 => command = "deleteBackward",
                46 => command = "deleteForward",
                37 => command = if (shift != 0) "moveLeftAndModifySelection" else "moveLeft",
                39 => command = if (shift != 0) "moveRightAndModifySelection" else "moveRight",
                38 => command = if (shift != 0) "moveUpAndModifySelection" else "moveUp",
                40 => command = if (shift != 0) "moveDownAndModifySelection" else "moveDown",
                36 => command = if (shift != 0) "moveToBeginningOfLineAndModifySelection" else "moveToBeginningOfLine",
                35 => command = if (shift != 0) "moveToEndOfLineAndModifySelection" else "moveToEndOfLine",
                else => {},
            }
        }
    }

    params = std.mem.zeroes(web.rw_text_t);
    // Enter carries its character: that is what validates a form or breaks a line
    if (down != 0 and code == 13) web.rw_text_puts(&params, "{\"type\":\"keyDown\",\"text\":\"\\r\"") else web.rw_text_printf(&params, "{\"type\":\"%s\"", @as([*c]const u8, if (down != 0) "rawKeyDown" else "keyUp"));
    web.rw_text_printf(&params, ",\"modifiers\":%d,\"windowsVirtualKeyCode\":%d,\"code\":", rw_modifiers(event.*.modifiers), code);
    web.rw_text_json(&params, key_physical);
    web.rw_text_puts(&params, ",\"key\":");
    web.rw_text_json(&params, key_name);
    if (down != 0 and event.*.repeat != 0) web.rw_text_puts(&params, ",\"autoRepeat\":true");
    if (command != null) web.rw_text_printf(&params, ",\"commands\":[\"%s\"]", command);
    web.rw_text_puts(&params, "}");
    rw_view_send(view, "Input.dispatchKeyEvent", params.data, RW_KIND_NONE, null, null);
    web.rw_text_free(&params);
}

fn rw_view_text(view: [*c]rw_view_t, event: [*c]const raven.REvent) void {
    var params: web.rw_text_t = undefined;
    var utf8: [8]u8 = undefined;
    const c: raven.Ruint = event.*.codepoint;
    var length: c_int = 0;
    if (c < 0x20 or c == 0x7F or (event.*.modifiers & raven.R_MOD_CTRL) != 0) return;
    if (c < 0x80) {
        utf8[@intCast(length)] = @truncate(c);
        length += 1;
    } else if (c < 0x800) {
        utf8[@intCast(length)] = @truncate(0xC0 | (c >> 6));
        length += 1;
        utf8[@intCast(length)] = @truncate(0x80 | (c & 0x3F));
        length += 1;
    } else if (c < 0x10000) {
        utf8[@intCast(length)] = @truncate(0xE0 | (c >> 12));
        length += 1;
        utf8[@intCast(length)] = @truncate(0x80 | ((c >> 6) & 0x3F));
        length += 1;
        utf8[@intCast(length)] = @truncate(0x80 | (c & 0x3F));
        length += 1;
    } else {
        utf8[@intCast(length)] = @truncate(0xF0 | (c >> 18));
        length += 1;
        utf8[@intCast(length)] = @truncate(0x80 | ((c >> 12) & 0x3F));
        length += 1;
        utf8[@intCast(length)] = @truncate(0x80 | ((c >> 6) & 0x3F));
        length += 1;
        utf8[@intCast(length)] = @truncate(0x80 | (c & 0x3F));
        length += 1;
    }
    utf8[@intCast(length)] = 0;
    params = std.mem.zeroes(web.rw_text_t);
    if (comptime builtin.os.tag.isDarwin()) {
        // Chrome on macOS drops the "char" key events: the text is inserted as such
        web.rw_text_puts(&params, "{\"text\":");
        web.rw_text_json(&params, &utf8);
        web.rw_text_puts(&params, "}");
        rw_view_send(view, "Input.insertText", params.data, RW_KIND_NONE, null, null);
    } else {
        web.rw_text_puts(&params, "{\"type\":\"char\",\"text\":");
        web.rw_text_json(&params, &utf8);
        web.rw_text_printf(&params, ",\"modifiers\":%d}", rw_modifiers(event.*.modifiers));
        rw_view_send(view, "Input.dispatchKeyEvent", params.data, RW_KIND_NONE, null, null);
    }
    web.rw_text_free(&params);
}

fn rw_button_name(button: raven.RMouseButton, mask: [*c]c_int) [*c]const u8 {
    switch (button) {
        raven.R_MOUSE_LEFT => {
            mask.* = 1;
            return "left";
        },
        raven.R_MOUSE_RIGHT => {
            mask.* = 2;
            return "right";
        },
        raven.R_MOUSE_MIDDLE => {
            mask.* = 4;
            return "middle";
        },
        raven.R_MOUSE_X1 => {
            mask.* = 8;
            return "back";
        },
        raven.R_MOUSE_X2 => {
            mask.* = 16;
            return "forward";
        },
        else => {
            mask.* = 0;
            return "none";
        },
    }
}

fn rw_view_event(widget: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const view: [*c]rw_view_t = @ptrCast(@alignCast(user_data));
    var button: [*c]const u8 = undefined;
    var mask: c_int = 0;
    if (view.*.state == RW_STATE_FAILED) return raven.R_FALSE;
    switch (event.*.type) {
        raven.R_EVENT_MOUSE_MOVE => {
            rw_view_mouse(view, "mouseMoved", event, if ((view.*.buttons & 1) != 0) "left" else "none", 0, 0.0, 0.0);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_LEAVE => {
            // the page stops showing what was under the pointer
            if (view.*.buttons == 0) rw_view_send(view, "Input.dispatchMouseEvent", "{\"type\":\"mouseMoved\",\"x\":-1,\"y\":-1}", RW_KIND_NONE, null, null);
            return raven.R_FALSE;
        },
        raven.R_EVENT_MOUSE_DOWN => {
            button = rw_button_name(event.*.button, &mask);
            view.*.buttons |= mask;
            raven.Rwidget_focus(widget);
            rw_view_mouse(view, "mousePressed", event, button, if (event.*.clicks > 0) event.*.clicks else 1, 0.0, 0.0);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_UP => {
            button = rw_button_name(event.*.button, &mask);
            view.*.buttons &= ~mask;
            rw_view_mouse(view, "mouseReleased", event, button, 1, 0.0, 0.0);
            return raven.R_TRUE;
        },
        raven.R_EVENT_MOUSE_WHEEL => {
            // (the wheel of Raven counts lines, up is positive; the page counts pixels, down is positive)
            rw_view_mouse(view, "mouseWheel", event, "none", 0, -event.*.wheel_x * 100.0, -event.*.wheel_y * 100.0);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_DOWN => {
            rw_view_key(view, event, 1);
            return raven.R_TRUE;
        },
        raven.R_EVENT_KEY_UP => {
            rw_view_key(view, event, 0);
            return raven.R_TRUE;
        },
        raven.R_EVENT_TEXT => {
            rw_view_text(view, event);
            return raven.R_TRUE;
        },
        else => return raven.R_FALSE,
    }
}

fn rw_view_destroyed(widget: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const view: [*c]rw_view_t = @ptrCast(@alignCast(user_data));
    var link: [*c][*c]rw_view_t = undefined;
    var request: [*c]rw_request_t = undefined;
    var pending: [*c]rw_pending_t = undefined;
    _ = widget;
    link = &g_rw_views;
    while (link.* != null) : (link = &link.*.*.next) {
        if (link.* == view) {
            link.* = view.*.next;
            break;
        }
    }
    if (view.*.target != null and web.rw_browser_running() != 0) {
        var params: [200]u8 = undefined;
        _ = libc.snprintf(&params, params.len, "{\"targetId\":\"%.120s\"}", view.*.target);
        _ = web.rw_browser_send(null, "Target.closeTarget", &params);
    }
    if (view.*.texture != raven.R_INVALID_ID and raven.Ris_initialized() != 0 and raven.Rtexture_is_valid(view.*.texture) != 0) raven.Rtexture_destroy(view.*.texture);
    request = view.*.requests;
    while (request != null) {
        const next = request.*.next;
        web.rw_free(request);
        request = next;
    }
    pending = view.*.pending;
    while (pending != null) {
        const next = pending.*.next;
        web.rw_free(pending.*.method);
        web.rw_free(pending.*.params);
        web.rw_free(pending);
        pending = next;
    }
    web.rw_free(view.*.target);
    web.rw_free(view.*.session);
    web.rw_free(view.*.url);
    web.rw_free(view.*.title);
    web.rw_free(view);
    // the browser only runs while there is something to show
    if (g_rw_views == null) web.rw_browser_stop();
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rweb_view_create() raven.Rid {
    var view: [*c]rw_view_t = undefined;
    const widget = raven.Rwidget_create(raven.R_WIDGET_CUSTOM);
    if (widget == raven.R_INVALID_ID) return raven.R_INVALID_ID;
    view = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_view_t))));
    if (view == null) {
        raven.Rwidget_destroy(widget);
        return raven.R_INVALID_ID;
    }
    view.* = std.mem.zeroes(rw_view_t);
    view.*.widget = widget;
    view.*.texture = raven.R_INVALID_ID;
    view.*.zoom = 1.0;
    view.*.frames = rweb.R_WEB_FRAMES_PNG;
    view.*.quality = 85;
    view.*.forward_entry = -1;
    view.*.back_entry = view.*.forward_entry;
    view.*.url = web.rw_strdup("");
    view.*.title = web.rw_strdup("");
    view.*.next = g_rw_views;
    g_rw_views = view;
    raven.Rcustom_set_paint_callback(widget, &rw_view_paint, view);
    raven.Rcustom_set_measure_callback(widget, &rw_view_measure, view);
    raven.Rwidget_set_event_callback(widget, &rw_view_event, view);
    raven.Rwidget_set_destroy_callback(widget, &rw_view_destroyed, view);
    raven.Rwidget_set_focusable(widget, raven.R_TRUE);
    rw_view_open(view);
    return widget;
}

export fn Rweb_view_is_valid(widget: raven.Rid) c_int {
    return @intFromBool(rw_view_of(widget) != null and raven.Rwidget_is_valid(widget) != 0);
}

export fn Rweb_view_load_url(widget: raven.Rid, url: [*c]const u8) void {
    const view = rw_view_checked(widget, "Rweb_view_load_url");
    var params: web.rw_text_t = undefined;
    if (view == null) return;
    params = std.mem.zeroes(web.rw_text_t);
    web.rw_text_puts(&params, "{\"url\":");
    web.rw_text_json(&params, if (url != null and url[0] != 0) url else @as([*c]const u8, "about:blank"));
    web.rw_text_puts(&params, "}");
    rw_view_send(view, "Page.navigate", params.data, RW_KIND_NONE, null, null);
    web.rw_text_free(&params);
}

export fn Rweb_view_load_file(widget: raven.Rid, path: [*c]const u8) void {
    var url: [*c]u8 = undefined;
    if (rw_view_checked(widget, "Rweb_view_load_file") == null) return;
    url = web.rw_file_url(path);
    if (url != null) Rweb_view_load_url(widget, url);
    web.rw_free(url);
}

export fn Rweb_view_load_html(widget: raven.Rid, html: [*c]const u8, base_url: [*c]const u8) void {
    const view = rw_view_checked(widget, "Rweb_view_load_html");
    var page: web.rw_text_t = undefined;
    var script: web.rw_text_t = undefined;
    if (view == null) return;
    page = std.mem.zeroes(web.rw_text_t);
    script = std.mem.zeroes(web.rw_text_t);
    if (base_url != null and base_url[0] != 0) {
        web.rw_text_puts(&page, "<base href=\"");
        web.rw_text_puts(&page, base_url);
        web.rw_text_puts(&page, "\">");
    }
    web.rw_text_puts(&page, if (html != null) html else @as([*c]const u8, ""));
    // an empty page, then the text written into it as a page that loads would be: its scripts run
    rw_view_send(view, "Page.navigate", "{\"url\":\"about:blank\"}", RW_KIND_NONE, null, null);
    web.rw_text_puts(&script, "(function(html){ document.open(); document.write(html); document.close(); })(");
    web.rw_text_json(&script, if (page.data != null) page.data else @as([*c]const u8, ""));
    web.rw_text_puts(&script, ")");
    rw_view_script(view, script.data, RW_KIND_NONE, null, null);
    web.rw_text_free(&page);
    web.rw_text_free(&script);
}

export fn Rweb_view_reload(widget: raven.Rid) void {
    const view = rw_view_checked(widget, "Rweb_view_reload");
    if (view != null) rw_view_send(view, "Page.reload", null, RW_KIND_NONE, null, null);
}

export fn Rweb_view_stop(widget: raven.Rid) void {
    const view = rw_view_checked(widget, "Rweb_view_stop");
    if (view != null) rw_view_send(view, "Page.stopLoading", null, RW_KIND_NONE, null, null);
}

fn rw_view_history(view: [*c]rw_view_t, entry: c_int) void {
    var params: [64]u8 = undefined;
    if (entry < 0) return;
    _ = libc.snprintf(&params, params.len, "{\"entryId\":%d}", entry);
    rw_view_send(view, "Page.navigateToHistoryEntry", &params, RW_KIND_NONE, null, null);
}

export fn Rweb_view_go_back(widget: raven.Rid) void {
    const view = rw_view_checked(widget, "Rweb_view_go_back");
    if (view != null) rw_view_history(view, view.*.back_entry);
}

export fn Rweb_view_go_forward(widget: raven.Rid) void {
    const view = rw_view_checked(widget, "Rweb_view_go_forward");
    if (view != null) rw_view_history(view, view.*.forward_entry);
}

export fn Rweb_view_can_go_back(widget: raven.Rid) c_int {
    const view = rw_view_checked(widget, "Rweb_view_can_go_back");
    return @intFromBool(view != null and view.*.back_entry >= 0);
}

export fn Rweb_view_can_go_forward(widget: raven.Rid) c_int {
    const view = rw_view_checked(widget, "Rweb_view_can_go_forward");
    return @intFromBool(view != null and view.*.forward_entry >= 0);
}

export fn Rweb_view_get_url(widget: raven.Rid) [*c]const u8 {
    const view = rw_view_checked(widget, "Rweb_view_get_url");
    return if (view != null and view.*.url != null) view.*.url else "";
}

export fn Rweb_view_get_title(widget: raven.Rid) [*c]const u8 {
    const view = rw_view_checked(widget, "Rweb_view_get_title");
    return if (view != null and view.*.title != null) view.*.title else "";
}

export fn Rweb_view_is_loading(widget: raven.Rid) c_int {
    const view = rw_view_checked(widget, "Rweb_view_is_loading");
    return @intFromBool(view != null and view.*.loading != 0);
}

export fn Rweb_view_is_ready(widget: raven.Rid) c_int {
    const view = rw_view_checked(widget, "Rweb_view_is_ready");
    return @intFromBool(view != null and view.*.state == RW_STATE_READY);
}

export fn Rweb_view_get_error(widget: raven.Rid) [*c]const u8 {
    const view = rw_view_checked(widget, "Rweb_view_get_error");
    return if (view != null and view.*.state == RW_STATE_FAILED) &view.*.@"error" else "";
}

export fn Rweb_view_get_texture(widget: raven.Rid) raven.Rid {
    const view = rw_view_checked(widget, "Rweb_view_get_texture");
    return if (view != null and view.*.texture != raven.R_INVALID_ID and raven.Rtexture_is_valid(view.*.texture) != 0) view.*.texture else raven.R_INVALID_ID;
}

export fn Rweb_view_set_zoom(widget: raven.Rid, zoom_in: f32) void {
    var zoom = zoom_in;
    const view = rw_view_checked(widget, "Rweb_view_set_zoom");
    if (view == null) return;
    if (!(zoom > 0.0)) zoom = 1.0;
    if (zoom < 0.25) zoom = 0.25;
    if (zoom > 5.0) zoom = 5.0;
    view.*.zoom = zoom;
    // (the next paint tells the browser)
    raven.Rwidget_invalidate(widget);
}

export fn Rweb_view_get_zoom(widget: raven.Rid) f32 {
    const view = rw_view_checked(widget, "Rweb_view_get_zoom");
    return if (view != null) view.*.zoom else 1.0;
}

export fn Rweb_view_set_frames(widget: raven.Rid, format: rweb.RWebFrames, quality_in: c_int) void {
    var quality = quality_in;
    const view = rw_view_checked(widget, "Rweb_view_set_frames");
    if (view == null) return;
    if (quality < 1) quality = 1;
    if (quality > 100) quality = 100;
    if (view.*.frames == format and view.*.quality == quality) return;
    view.*.frames = if (format == rweb.R_WEB_FRAMES_JPEG) @as(rweb.RWebFrames, rweb.R_WEB_FRAMES_JPEG) else rweb.R_WEB_FRAMES_PNG;
    view.*.quality = quality;
    if (view.*.state == RW_STATE_READY) {
        rw_view_send(view, "Page.stopScreencast", null, RW_KIND_NONE, null, null);
        rw_view_cast(view);
    }
}

export fn Rweb_view_run_javascript(widget: raven.Rid, script: [*c]const u8, callback: rweb.RWebResultCallback, user_data: ?*anyopaque) void {
    const view = rw_view_checked(widget, "Rweb_view_run_javascript");
    if (view == null or script == null) return;
    rw_view_script(view, script, if (callback != null) @as(rw_kind_t, RW_KIND_SCRIPT) else RW_KIND_NONE, callback, user_data);
}

export fn Rweb_view_set_message_callback(widget: raven.Rid, callback: rweb.RWebMessageCallback, user_data: ?*anyopaque) void {
    const view = rw_view_checked(widget, "Rweb_view_set_message_callback");
    if (view == null) return;
    view.*.message_callback = callback;
    view.*.message_user = user_data;
}

export fn Rweb_view_set_event_callback(widget: raven.Rid, callback: rweb.RWebEventCallback, user_data: ?*anyopaque) void {
    const view = rw_view_checked(widget, "Rweb_view_set_event_callback");
    if (view == null) return;
    view.*.event_callback = callback;
    view.*.event_user = user_data;
}

// ---------------------------------------------------------------------------
//  XML: <WebView Url="..." Source="page.html" Zoom="1.25" Frames="Jpeg" Quality="80">html</WebView>
// ---------------------------------------------------------------------------

fn rw_same(a_in: [*c]const u8, b_in: [*c]const u8) c_int {
    var a = a_in;
    var b = b_in;
    while (a.* != 0 and b.* != 0) : ({
        a += 1;
        b += 1;
    }) {
        var x: u8 = a.*;
        var y: u8 = b.*;
        if (x >= 'A' and x <= 'Z') x = x + 32;
        if (y >= 'A' and y <= 'Z') y = y + 32;
        if (x != y) return 0;
    }
    return @intFromBool(a.* == b.*);
}

fn rw_xml_create(tag: [*c]const u8, user_data: ?*anyopaque) callconv(.c) raven.Rid {
    _ = tag;
    _ = user_data;
    return Rweb_view_create();
}

fn rw_xml_attribute(widget: raven.Rid, name: [*c]const u8, value: [*c]const u8, user_data: ?*anyopaque) callconv(.c) c_int {
    const view = rw_view_of(widget);
    _ = user_data;
    if (view == null) return raven.R_FALSE;
    if (rw_same(name, "Url") != 0 or rw_same(name, "Src") != 0) {
        Rweb_view_load_url(widget, value);
    } else if (rw_same(name, "Source") != 0 or rw_same(name, "File") != 0) {
        // a file next to the document that names it
        Rweb_view_load_file(widget, raven.Rxml_resolve_path(value));
    } else if (rw_same(name, "Html") != 0 or rw_same(name, "Text") != 0) {
        Rweb_view_load_html(widget, value, null);
    } else if (rw_same(name, "Zoom") != 0) {
        const zoom: f32 = @floatCast(atof(value));
        if (!(zoom > 0.0)) return raven.R_FALSE;
        Rweb_view_set_zoom(widget, zoom);
    } else if (rw_same(name, "Frames") != 0) {
        if (rw_same(value, "Jpeg") != 0 or rw_same(value, "Jpg") != 0) Rweb_view_set_frames(widget, rweb.R_WEB_FRAMES_JPEG, view.*.quality) else if (rw_same(value, "Png") != 0) Rweb_view_set_frames(widget, rweb.R_WEB_FRAMES_PNG, view.*.quality) else return raven.R_FALSE;
    } else if (rw_same(name, "Quality") != 0) {
        const quality = libc.atoi(value);
        if (quality < 1 or quality > 100) return raven.R_FALSE;
        Rweb_view_set_frames(widget, view.*.frames, quality);
    } else {
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn Rweb_register_xml() void {
    _ = raven.Rxml_register_tag("WebView", &rw_xml_create, &rw_xml_attribute, null);
}

/// Seridian fix: the C cast browser-supplied doubles to int unchecked (UB on NaN or out of range, a trap in
/// ReleaseSafe Zig). Truncates like the C cast when representable, else returns `fallback`.
fn toInt(value: anytype, fallback: c_int) c_int {
    const x: f64 = @floatCast(value);
    if (std.math.isNan(x)) return fallback;
    if (x <= @as(f64, std.math.minInt(c_int)) - 1.0 or x >= @as(f64, std.math.maxInt(c_int)) + 1.0) return fallback;
    return @intFromFloat(x);
}

test "toInt rejects NaN and out-of-range values" {
    try std.testing.expectEqual(@as(c_int, 42), toInt(@as(f64, 42.9), -1));
    try std.testing.expectEqual(@as(c_int, -3), toInt(@as(f64, -3.5), 0));
    try std.testing.expectEqual(@as(c_int, -1), toInt(std.math.nan(f64), -1));
    try std.testing.expectEqual(@as(c_int, -1), toInt(@as(f64, 1e300), -1));
    try std.testing.expectEqual(@as(c_int, 1), toInt(@as(f32, std.math.inf(f32)), 1));
}
