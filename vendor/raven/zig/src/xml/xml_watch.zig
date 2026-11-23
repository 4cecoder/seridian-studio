// Translated to Zig from vendor/raven/src/xml/xml_watch.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - xml/xml_watch.c
// Live reload: the interfaces built from files follow their files.
//
// Watched files use native OS notifications (ReadDirectoryChangesW on Windows,
// kqueue on macOS and inotify on Linux). File stamps are checked only after a
// notification, with a short retry timer if an editor is temporarily writing
// or replacing the file. When one changed, it is read again and compared with the document the interface was
// built from:
//
//   - an element that is still there keeps its widget: the handles the
//     application holds stay valid, and so do the callbacks, what the user
//     typed, the scroll positions. Only the attributes that changed are set.
//   - elements are matched by Name when they have one, else by tag and order.
//   - a new element gets a new widget; a removed one loses its widget.
//   - when an attribute was removed, or the tag changed, the widget is built
//     again from the new element (and what is inside it with it).
//
// A file that cannot be read or parsed leaves the interface as it is.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const fs_h = @import("../core/fs_h.zig");
const fs_watch_h = @import("../core/fs_watch_h.zig");
const xml_h = @import("xml_h.zig");
const watch_h = @import("xml_watch_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common_h = @import("../widgets/common_h.zig");
const libc = @import("../sys/libc.zig");

// xml_h.zig declares the functions that take a widget or a window with the placeholder types of externs.zig.
// The C symbols are the same: these helpers only convert the Zig type of the pointer (the widget is the one of widget_h.zig).

/// Retry interval only while a changed file is temporarily unreadable.
const RVN_WATCH_RETRY_INTERVAL = 0.2;
/// A file that could not be used is tried again this many times before the error is reported.
const RVN_WATCH_RETRIES: c_int = 2;

const rvn_watch_t = extern struct {
    path: [*c]u8,
    /// Canonical absolute path used by the OS directory watcher.
    native_path: [*c]u8,
    modified: u64,
    size: u64,
    exists: c_int,
    retries: c_int,
    callback: watch_h.rvn_watch_callback_t,
    user: ?*anyopaque,
};

/// What was built from one file.
const rvn_live_t = extern struct {
    path: [*c]u8,
    is_window: c_int,
    target: raven.Rid,
    document: xml_h.rvn_xml_document_t,
    files: [*c][*c]u8,
    file_count: u32,
};

const live_state_t = extern struct {
    watches: [*c]rvn_watch_t,
    watch_count: u32,
    watch_cap: u32,
    lives: [*c][*c]rvn_live_t,
    live_count: u32,
    live_cap: u32,
    timer: raven.Rid,
    configured: c_int,
    disabled: c_int,
    callback: raven.RXmlReloadCallback,
    callback_user: ?*anyopaque,
    // files read by the document being loaded
    recording: c_int,
    files: [*c][*c]u8,
    file_count: u32,
    file_cap: u32,
    /// Set while a file is tried again: parse errors are kept quiet until the last try.
    quiet: c_int,
    native_started: c_int,
    /// Used only on platforms where no native notification mechanism exists or setup fails.
    polling_fallback: c_int,
};

var g_live: live_state_t = std.mem.zeroes(live_state_t);

/// base_h.RVN_ARRAY_RESERVE for an array of pointers: it passes `data.*` (a `[*c][*c]T`) to rvn_array_grow_
/// without a cast, which Zig rejects. Same logic, with the cast written out.
inline fn arrayReserve(data: anytype, cap: [*c]u32, needed: anytype) void {
    const Item = @typeInfo(@typeInfo(@TypeOf(data)).pointer.child).pointer.child;
    const n: u32 = @intCast(needed);
    if (n > cap.*) data.* = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(data.*), cap, n, @sizeOf(Item))));
}

// ---------------------------------------------------------------------------
//  Watched files
// ---------------------------------------------------------------------------

fn rvn_live_configure() void {
    if (g_live.configured != 0) return;
    g_live.configured = raven.R_TRUE;
    g_live.timer = raven.R_INVALID_ID;
    const env = libc.getenv("RAVEN_LIVE_RELOAD");
    if (env != null and (env[0] == '0' or env[0] == 'n' or env[0] == 'N' or env[0] == 'f' or env[0] == 'F')) g_live.disabled = raven.R_TRUE;
}

fn rvn_watch_retry_schedule() void {
    if (g_live.disabled != 0 or (g_live.timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g_live.timer) != 0)) return;
    g_live.timer = raven.Rtimer_create(RVN_WATCH_RETRY_INTERVAL, raven.R_FALSE, &rvn_watch_retry_timer, null);
}

fn rvn_watch_sync_timer() void {
    var i: u32 = 0;
    var pending: c_int = g_live.polling_fallback;
    while (i < g_live.watch_count) : (i += 1) {
        if (g_live.watches[i].retries > 0) {
            pending = raven.R_TRUE;
            break;
        }
    }
    if (pending == 0 and g_live.timer != raven.R_INVALID_ID and raven.Rtimer_is_valid(g_live.timer) != 0) {
        raven.Rtimer_destroy(g_live.timer);
        g_live.timer = raven.R_INVALID_ID;
    } else if (pending != 0) {
        rvn_watch_retry_schedule();
    }
}

// Native callbacks run on a filesystem thread. All reload work must be marshalled to the UI thread.
fn rvn_watch_native_callback(path: [*c]const u8, user: ?*anyopaque) callconv(.c) void {
    _ = user; // RVN_UNUSED(user)
    if (path == null or g_live.native_started == 0 or g_live.disabled != 0) return;
    const copy = base.rvn_strdup(path);
    raven.Rtask_post(&rvn_watch_on_native_event, copy);
}

export fn rvn_watch_add(path: [*c]const u8, callback: watch_h.rvn_watch_callback_t, user: ?*anyopaque) void {
    var watch: [*c]rvn_watch_t = undefined;
    var i: u32 = 0;
    rvn_live_configure();
    if (path == null or path[0] == 0) return;
    // a file held in memory never changes on disk
    if (base.rvn_memory_file_exists(path) != 0) return;
    while (i < g_live.watch_count) : (i += 1) {
        watch = &g_live.watches[i];
        if (watch.*.callback == callback and watch.*.user == user and libc.strcmp(watch.*.path, path) == 0) return;
    }
    base.RVN_ARRAY_RESERVE(&g_live.watches, &g_live.watch_cap, g_live.watch_count + 1);
    watch = &g_live.watches[g_live.watch_count];
    g_live.watch_count += 1;
    _ = libc.memset(watch, 0, @sizeOf(rvn_watch_t));
    watch.*.path = base.rvn_strdup(path);
    watch.*.native_path = fs_h.rvn_path_absolute(path);
    watch.*.callback = callback;
    watch.*.user = user;
    watch.*.exists = fs_h.rvn_file_stamp(path, &watch.*.modified, &watch.*.size);
    if (g_live.native_started == 0) {
        g_live.native_started = fs_watch_h.rvn_fs_watch_start(&rvn_watch_native_callback, null);
        if (g_live.native_started == 0) g_live.polling_fallback = raven.R_TRUE;
    }
    if (g_live.native_started != 0 and watch.*.native_path != null and fs_watch_h.rvn_fs_watch_add(watch.*.native_path) == 0) {
        g_live.polling_fallback = raven.R_TRUE;
    }
    if (g_live.polling_fallback != 0) rvn_watch_sync_timer();
}

export fn rvn_watch_quiet() c_int {
    return g_live.quiet;
}

fn rvn_watch_check_index(i: u32) c_int {
    var watch: [*c]rvn_watch_t = undefined;
    var modified: u64 = 0;
    var size: u64 = 0;
    var exists: c_int = undefined;
    var differs: bool = undefined;
    var ok: c_int = undefined;
    var callback: watch_h.rvn_watch_callback_t = undefined;
    var user: ?*anyopaque = undefined;
    var path: [*c]u8 = undefined;
    var retries: c_int = undefined;

    if (i >= g_live.watch_count) return 0;
    watch = &g_live.watches[i];
    exists = fs_h.rvn_file_stamp(watch.*.path, &modified, &size);
    differs = exists != watch.*.exists or (exists != 0 and (modified != watch.*.modified or size != watch.*.size));
    if (!differs and watch.*.retries == 0) return 0;
    // Editors often replace a file atomically: a temporary absence is not a completed change.
    if (exists == 0) {
        watch.*.exists = raven.R_FALSE;
        return 0;
    }
    if (differs) watch.*.retries = 0;
    watch.*.exists = exists;
    watch.*.modified = modified;
    watch.*.size = size;
    callback = watch.*.callback;
    user = watch.*.user;
    path = base.rvn_strdup(watch.*.path);
    retries = watch.*.retries;
    g_live.quiet = @intFromBool(retries < RVN_WATCH_RETRIES);
    ok = callback.?(path, user);
    base.rvn_free(path);
    g_live.quiet = raven.R_FALSE;
    // A reload callback may add another dependency, reallocating the watch array.
    if (i < g_live.watch_count) {
        watch = &g_live.watches[i];
        if (ok != 0) {
            watch.*.retries = 0;
        } else if (watch.*.retries < RVN_WATCH_RETRIES) {
            watch.*.retries += 1;
        } else {
            watch.*.retries = 0;
        }
    }
    return 1;
}

// Looks at every file on explicit Rxml_check_files calls; normal updates are event-driven.
fn rvn_watch_poll() c_int {
    var i: u32 = 0;
    var changed: c_int = 0;
    while (i < g_live.watch_count) : (i += 1) changed += rvn_watch_check_index(i);
    rvn_watch_sync_timer();
    return changed;
}

fn rvn_watch_on_native_event(user: ?*anyopaque) callconv(.c) void {
    const path: [*c]const u8 = @ptrCast(user);
    var i: u32 = 0;
    if (path != null and g_live.disabled == 0) {
        // Several logical watches can share the same path but have different callbacks.
        while (i < g_live.watch_count) : (i += 1) {
            if (g_live.watches[i].native_path != null and libc.strcmp(g_live.watches[i].native_path, path) == 0) {
                _ = rvn_watch_check_index(i);
            }
        }
        rvn_watch_sync_timer();
    }
    base.rvn_free(user);
}

fn rvn_watch_retry_timer(timer: raven.Rid, user: ?*anyopaque) callconv(.c) void {
    var i: u32 = 0;
    _ = user; // RVN_UNUSED(user)
    if (g_live.timer == timer) g_live.timer = raven.R_INVALID_ID;
    if (g_live.disabled != 0) return;
    if (g_live.polling_fallback != 0) {
        _ = rvn_watch_poll();
        return;
    }
    while (i < g_live.watch_count) : (i += 1) {
        if (g_live.watches[i].retries > 0) _ = rvn_watch_check_index(i);
    }
    rvn_watch_sync_timer();
}

// ---------------------------------------------------------------------------
//  Files read by a document
// ---------------------------------------------------------------------------

export fn rvn_live_begin() void {
    const first = g_live.recording == 0;
    g_live.recording += 1;
    if (first) g_live.file_count = 0;
}

export fn rvn_live_end() void {
    var i: u32 = 0;
    g_live.recording -= 1;
    if (g_live.recording > 0) return;
    while (i < g_live.file_count) : (i += 1) base.rvn_free(g_live.files[i]);
    g_live.file_count = 0;
}

export fn rvn_live_dependency(path: [*c]const u8) void {
    var i: u32 = 0;
    if (g_live.recording <= 0 or path == null) return;
    while (i < g_live.file_count) : (i += 1) {
        if (libc.strcmp(g_live.files[i], path) == 0) return;
    }
    arrayReserve(&g_live.files, &g_live.file_cap, g_live.file_count + 1);
    g_live.files[g_live.file_count] = base.rvn_strdup(path);
    g_live.file_count += 1;
}

// ---------------------------------------------------------------------------
//  Comparing two documents
// ---------------------------------------------------------------------------

fn rvn_live_same_attributes(a: [*c]const xml_h.rvn_xml_node_t, b: [*c]const xml_h.rvn_xml_node_t) c_int {
    var attribute: [*c]const xml_h.rvn_xml_attribute_t = a.*.attributes;
    var count_a: c_int = 0;
    var count_b: c_int = 0;
    while (attribute != null) : (attribute = attribute.*.next) {
        const other = xml_h.rvn_xml_attribute(b, attribute.*.name);
        if (other == null or libc.strcmp(other, attribute.*.value) != 0) return raven.R_FALSE;
        count_a += 1;
    }
    attribute = b.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) count_b += 1;
    return @intFromBool(count_a == count_b);
}

fn rvn_live_same_tree(a: [*c]const xml_h.rvn_xml_node_t, b: [*c]const xml_h.rvn_xml_node_t) c_int {
    if (libc.strcmp(a.*.name, b.*.name) != 0 or libc.strcmp(a.*.text, b.*.text) != 0 or rvn_live_same_attributes(a, b) == 0) return raven.R_FALSE;
    var child_a: [*c]const xml_h.rvn_xml_node_t = a.*.first_child;
    var child_b: [*c]const xml_h.rvn_xml_node_t = b.*.first_child;
    while (child_a != null and child_b != null) : ({
        child_a = child_a.*.next;
        child_b = child_b.*.next;
    }) {
        if (rvn_live_same_tree(child_a, child_b) == 0) return raven.R_FALSE;
    }
    return @intFromBool(child_a == null and child_b == null);
}

fn rvn_live_same_children(a: [*c]const xml_h.rvn_xml_node_t, b: [*c]const xml_h.rvn_xml_node_t) c_int {
    var child_a: [*c]const xml_h.rvn_xml_node_t = a.*.first_child;
    var child_b: [*c]const xml_h.rvn_xml_node_t = b.*.first_child;
    while (child_a != null and child_b != null) : ({
        child_a = child_a.*.next;
        child_b = child_b.*.next;
    }) {
        if (rvn_live_same_tree(child_a, child_b) == 0) return raven.R_FALSE;
    }
    return @intFromBool(child_a == null and child_b == null);
}

// The text of an element that stands for its Text attribute (<Label>Hello</Label>), or NULL.
fn rvn_live_text(node: [*c]const xml_h.rvn_xml_node_t) [*c]const u8 {
    if (node.*.text[0] != 0 and xml_h.rvn_xml_attribute(node, "Text") == null and node.*.first_child == null) return node.*.text;
    return null;
}

// Can every element of a document be built? Checked before anything is
// touched, so that a mistake in the file leaves the interface whole.
fn rvn_live_valid(node: [*c]const xml_h.rvn_xml_node_t) c_int {
    const cls = widget_h.rvn_widget_class_by_name(node.*.name);
    var child: [*c]const xml_h.rvn_xml_node_t = undefined;
    if (cls == null) {
        // a tag made by code: what it accepts inside is only known once it is built
        if (xml_h.rvn_xml_tag_find(node.*.name) != 0) {
            child = node.*.first_child;
            while (child != null) : (child = child.*.next) {
                if (rvn_live_valid(child) == 0) return raven.R_FALSE;
            }
            return raven.R_TRUE;
        }
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "XML line %d, column %d: unknown widget <%.60s>", node.*.line, node.*.column, node.*.name);
        return raven.R_FALSE;
    }
    // (what is inside such a widget is its own business: items, separators)
    if (cls.*.xml_child != null) return raven.R_TRUE;
    child = node.*.first_child;
    while (child != null) : (child = child.*.next) {
        if ((cls.*.flags & widget_h.RVN_CF_NO_CHILDREN) != 0) {
            base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "XML line %d, column %d: <%.60s> cannot contain <%.60s>", child.*.line, child.*.column, node.*.name, child.*.name);
            return raven.R_FALSE;
        }
        if (rvn_live_valid(child) == 0) return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

// Makes the children of a widget those of `new_node`, keeping the widgets of the elements that are still there.
fn rvn_live_patch_children(old_node: [*c]xml_h.rvn_xml_node_t, new_node: [*c]xml_h.rvn_xml_node_t, widget: [*c]widget_h.rvn_widget_t) c_int {
    var olds: [*c][*c]xml_h.rvn_xml_node_t = null;
    var pairs: [*c][*c]xml_h.rvn_xml_node_t = null;
    var child: [*c]xml_h.rvn_xml_node_t = undefined;
    var old_count: u32 = 0;
    var new_count: u32 = 0;
    var i: u32 = 0;
    var k: u32 = 0;
    var cursor: u32 = 0;
    var ok: c_int = raven.R_TRUE;

    child = old_node.*.first_child;
    while (child != null) : (child = child.*.next) old_count += 1;
    child = new_node.*.first_child;
    while (child != null) : (child = child.*.next) new_count += 1;
    if (old_count != 0) olds = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, old_count) * @sizeOf([*c]xml_h.rvn_xml_node_t))));
    if (new_count != 0) pairs = @ptrCast(@alignCast(base.rvn_calloc(@as(usize, new_count) * @sizeOf([*c]xml_h.rvn_xml_node_t))));
    child = old_node.*.first_child;
    i = 0;
    while (child != null) : ({
        child = child.*.next;
        i += 1;
    }) {
        const built = widget_h.rvn_widget_get(child.*.widget);
        // (the application may have moved or deleted it since)
        olds[i] = if (built != null and built.*.parent == widget) child else null;
    }

    // pairs: the same Name; else the very same element; else the next one with the same tag
    child = new_node.*.first_child;
    k = 0;
    while (child != null) : ({
        child = child.*.next;
        k += 1;
    }) {
        const name = xml_h.rvn_xml_attribute(child, "Name");
        var found: c_int = -1;
        i = 0;
        while (i < old_count and found < 0) : (i += 1) {
            if (olds[i] == null or libc.strcmp(olds[i].*.name, child.*.name) != 0) continue;
            const old_name = xml_h.rvn_xml_attribute(olds[i], "Name");
            if (name != null) {
                if (old_name != null and libc.strcmp(name, old_name) == 0) found = @intCast(i);
            } else if (old_name == null and rvn_live_same_tree(olds[i], child) != 0) {
                found = @intCast(i);
            }
        }
        i = 0;
        while (i < old_count and found < 0 and name == null) : (i += 1) {
            if (olds[i] != null and libc.strcmp(olds[i].*.name, child.*.name) == 0 and xml_h.rvn_xml_attribute(olds[i], "Name") == null) found = @intCast(i);
        }
        if (found >= 0) {
            pairs[k] = olds[@intCast(found)];
            olds[@intCast(found)] = null;
        }
    }
    // the widgets of the elements that are gone
    i = 0;
    while (i < old_count) : (i += 1) {
        if (olds[i] != null) widget_h.rvn_widget_destroy(widget_h.rvn_widget_get(olds[i].*.widget));
    }

    child = new_node.*.first_child;
    k = 0;
    while (child != null and ok != 0) : ({
        child = child.*.next;
        k += 1;
    }) {
        var built: [*c]widget_h.rvn_widget_t = if (pairs[k] != null) widget_h.rvn_widget_get(pairs[k].*.widget) else null;
        if (built != null and rvn_live_patch(pairs[k], child, built) == 0) {
            widget_h.rvn_widget_destroy(built);
            built = null;
        }
        if (built == null) {
            built = @ptrCast(@alignCast(xml_h.rvn_xml_build_node(child)));
            if (built == null) {
                ok = raven.R_FALSE;
                break;
            }
            widget_h.rvn_widget_add_child(widget, built, @intCast(cursor));
            cursor += 1;
        } else {
            // the order of the file, among the children the application may have added itself
            const index = widget_h.rvn_widget_child_index(widget, built);
            if (index < @as(c_int, @intCast(cursor))) {
                widget_h.rvn_widget_add_child(widget, built, @as(c_int, @intCast(cursor)) - 1);
            } else {
                cursor = @as(u32, @intCast(index)) + 1;
            }
        }
    }
    base.rvn_free(@ptrCast(olds));
    base.rvn_free(@ptrCast(pairs));
    return ok;
}

// Turns the widget built from `old_node` into the one `new_node` describes. R_FALSE: it must be built again.
fn rvn_live_patch(old_node: [*c]xml_h.rvn_xml_node_t, new_node: [*c]xml_h.rvn_xml_node_t, widget: [*c]widget_h.rvn_widget_t) c_int {
    const cls = widget.*.cls;
    var attribute: [*c]const xml_h.rvn_xml_attribute_t = undefined;
    const old_text = rvn_live_text(old_node);
    const new_text = rvn_live_text(new_node);

    if (base.rvn_stricmp(old_node.*.name, new_node.*.name) != 0) return raven.R_FALSE;
    // an attribute that is gone: only a new widget has its default value for sure
    attribute = old_node.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        if (xml_h.rvn_xml_attribute(new_node, attribute.*.name) == null) return raven.R_FALSE;
    }
    if (old_text != null and new_text == null and xml_h.rvn_xml_attribute(new_node, "Text") == null) return raven.R_FALSE;

    if (cls.*.xml_child != null or (cls.*.flags & widget_h.RVN_CF_NO_CHILDREN) != 0) {
        if (rvn_live_same_children(old_node, new_node) == 0) return raven.R_FALSE;
    } else if (rvn_live_patch_children(old_node, new_node, widget) == 0) {
        return raven.R_FALSE;
    }

    if (new_text != null and (old_text == null or libc.strcmp(old_text, new_text) != 0)) _ = widget_h.rvn_widget_set_attribute(widget, "Text", new_text);
    attribute = new_node.*.attributes;
    while (attribute != null) : (attribute = attribute.*.next) {
        const before = xml_h.rvn_xml_attribute(old_node, attribute.*.name);
        if (before != null and libc.strcmp(before, attribute.*.value) == 0) continue;
        if (widget_h.rvn_widget_set_attribute(widget, attribute.*.name, attribute.*.value) == 0) {
            base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "XML line %d, column %d: <%.60s>: unknown attribute or invalid value %.60s=\"%.60s\"", new_node.*.line, new_node.*.column, new_node.*.name, attribute.*.name, attribute.*.value);
        }
    }
    new_node.*.widget = widget.*.id;
    widget.*.xml_node = new_node.*.source;
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Reloading
// ---------------------------------------------------------------------------

fn rvn_live_free(live: [*c]rvn_live_t) void {
    var i: u32 = 0;
    while (i < live.*.file_count) : (i += 1) base.rvn_free(live.*.files[i]);
    base.rvn_free(@ptrCast(live.*.files));
    base.rvn_free(live.*.path);
    xml_h.rvn_xml_free(&live.*.document);
    base.rvn_free(live);
}

// Takes the files noted while the document was loaded, and watches them.
fn rvn_live_take_files(live: [*c]rvn_live_t) void {
    var i: u32 = 0;
    while (i < live.*.file_count) : (i += 1) base.rvn_free(live.*.files[i]);
    base.rvn_free(@ptrCast(live.*.files));
    live.*.files = null;
    live.*.file_count = g_live.file_count;
    if (g_live.file_count != 0) {
        live.*.files = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, g_live.file_count) * @sizeOf([*c]u8))));
        i = 0;
        while (i < g_live.file_count) : (i += 1) {
            live.*.files[i] = base.rvn_strdup(g_live.files[i]);
            rvn_watch_add(live.*.files[i], &rvn_live_file_changed, null);
        }
    }
}

export fn rvn_live_add(path: [*c]const u8, is_window: c_int, target: raven.Rid, document: [*c]xml_h.rvn_xml_document_t) void {
    const live: [*c]rvn_live_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_live_t))));
    live.*.path = base.rvn_strdup(path);
    live.*.is_window = is_window;
    live.*.target = target;
    live.*.document = document.*;
    document.* = std.mem.zeroes(xml_h.rvn_xml_document_t);
    rvn_live_take_files(live);
    arrayReserve(&g_live.lives, &g_live.live_cap, g_live.live_count + 1);
    g_live.lives[g_live.live_count] = live;
    g_live.live_count += 1;
    rvn_watch_add(path, &rvn_live_file_changed, null);
}

fn rvn_live_reload_window(live: [*c]rvn_live_t, window: [*c]widget_h.rvn_window_t, document: [*c]xml_h.rvn_xml_document_t) void {
    const old_root = live.*.document.root;
    const new_root = document.*.root;
    var old_content: [*c]const xml_h.rvn_xml_node_t = null;
    var old_island: [*c]const xml_h.rvn_xml_node_t = null;
    var new_content: [*c]const xml_h.rvn_xml_node_t = null;
    var new_island: [*c]const xml_h.rvn_xml_node_t = null;
    var before: xml_h.rvn_xml_window_t = undefined;
    var after: xml_h.rvn_xml_window_t = undefined;
    const id = window.*.id;

    xml_h.rvn_xml_window_read(old_root, &before, raven.R_FALSE);
    xml_h.rvn_xml_window_read(new_root, &after, raven.R_TRUE);
    if (libc.strcmp(before.title, after.title) != 0) raven.Rwindow_set_title(id, after.title);
    if (before.width != after.width or before.height != after.height) raven.Rwindow_set_size(id, after.width, after.height);
    if (before.min_width != after.min_width or before.min_height != after.min_height) raven.Rwindow_set_min_size(id, after.min_width, after.min_height);
    if (after.has_clear != 0 and (before.has_clear == 0 or before.clear != after.clear)) {
        var r: f32 = undefined;
        var g: f32 = undefined;
        var b: f32 = undefined;
        var a: f32 = undefined;
        base.rvn_color_to_floats(after.clear, &r, &g, &b, &a);
        raven.Rwindow_set_clear_color(id, r, g, b, a);
    }
    if (before.background != after.background) raven.Rwindow_set_background(id, after.background);
    if (after.backdrop != 0 and before.backdrop != after.backdrop and (window.*.window_flags & @as(u32, @intCast(raven.R_WINDOW_TRANSPARENT))) != 0) {
        _ = raven.Rwindow_set_backdrop(id, @intCast(after.backdrop));
    }
    if (after.theme != null and after.theme[0] != 0 and (before.theme == null or libc.strcmp(before.theme, after.theme) != 0)) {
        const theme = common_h.rvn_xml_theme(after.theme);
        if (theme != null) _ = raven.Rtheme_use(theme.*.name);
    }
    if (((before.flags ^ after.flags) & ~@as(raven.Ruint, @intCast(raven.R_WINDOW_HIDDEN))) != 0) {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "%s: the frame of a window (Borderless, CustomHeader, Resizable, Transparent...) is chosen when it is created; start the application again to see this change", live.*.path);
    }

    _ = xml_h.rvn_xml_window_parts(old_root, &old_content, &old_island);
    _ = xml_h.rvn_xml_window_parts(new_root, &new_content, &new_island);

    if (new_content != null and old_content != null and window.*.root != null and window.*.root.*.id == old_content.*.widget and
        rvn_live_patch(@constCast(old_content), @constCast(new_content), window.*.root) != 0)
    {
        // (kept)
    } else if (new_content != null) {
        const content: [*c]widget_h.rvn_widget_t = @ptrCast(@alignCast(xml_h.rvn_xml_build_node(new_content)));
        if (content != null) raven.Rwindow_set_content(id, content.*.id);
    } else if (old_content != null and window.*.root != null and window.*.root.*.id == old_content.*.widget) {
        raven.Rwindow_set_content(id, raven.R_INVALID_ID);
    }

    if (new_island != null and old_island != null and window.*.island != null and window.*.island.*.id == old_island.*.widget and
        rvn_live_patch(@constCast(old_island), @constCast(new_island), window.*.island) != 0)
    {
        // (kept)
    } else if (new_island != null) {
        const island: [*c]widget_h.rvn_widget_t = @ptrCast(@alignCast(xml_h.rvn_xml_build_node(new_island)));
        if (island != null) raven.Rwindow_set_island(id, island.*.id);
    } else if (old_island != null and window.*.island != null and window.*.island.*.id == old_island.*.widget) {
        raven.Rwindow_set_island(id, raven.R_INVALID_ID);
    }

    xml_h.rvn_xml_window_shortcuts(@ptrCast(window), old_root, raven.R_FALSE);
    xml_h.rvn_xml_window_shortcuts(@ptrCast(window), new_root, raven.R_TRUE);
    window.*.xml_node = new_root.*.source;
}

fn rvn_live_reload_widget(live: [*c]rvn_live_t, widget: [*c]widget_h.rvn_widget_t, document: [*c]xml_h.rvn_xml_document_t) c_int {
    var built: [*c]widget_h.rvn_widget_t = null;
    const parent = widget.*.parent;
    const window = widget.*.window;

    if (rvn_live_patch(live.*.document.root, document.*.root, widget) != 0) return raven.R_TRUE;
    // the root itself must be built again: the new widget takes the place of the old one
    if (parent != null) {
        const index = widget_h.rvn_widget_child_index(parent, widget);
        built = @ptrCast(@alignCast(xml_h.rvn_xml_build_node(document.*.root)));
        if (built == null) return raven.R_FALSE;
        widget_h.rvn_widget_destroy(widget);
        widget_h.rvn_widget_add_child(parent, built, index);
    } else if (window != null and window.*.root == widget) {
        built = @ptrCast(@alignCast(xml_h.rvn_xml_build_node(document.*.root)));
        if (built == null) return raven.R_FALSE;
        raven.Rwindow_set_content(window.*.id, built.*.id);
    } else if (window != null and window.*.island == widget) {
        built = @ptrCast(@alignCast(xml_h.rvn_xml_build_node(document.*.root)));
        if (built == null) return raven.R_FALSE;
        raven.Rwindow_set_island(window.*.id, built.*.id);
    } else {
        base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_WARNING, "%s: the root element changed in a way that needs a new widget, and the one it built is not shown anywhere: it is left as it was", live.*.path);
        return raven.R_FALSE;
    }
    live.*.target = built.*.id;
    return raven.R_TRUE;
}

// R_TRUE when the file was used (or will never be); R_FALSE to try again.
fn rvn_live_reload(live: [*c]rvn_live_t) c_int {
    var document: xml_h.rvn_xml_document_t = undefined;
    const window: [*c]widget_h.rvn_window_t = if (live.*.is_window != 0) widget_h.rvn_window_get(live.*.target) else null;
    const widget: [*c]widget_h.rvn_widget_t = if (live.*.is_window != 0) null else widget_h.rvn_widget_get(live.*.target);
    var previous_dir: [*c]u8 = undefined;
    var size: usize = 0;
    var ok: c_int = raven.R_FALSE;

    const text = base.rvn_read_file(live.*.path, &size);
    if (text == null) return raven.R_FALSE;
    // a file caught half written: quietly tried again before saying anything
    if (g_live.quiet != 0) {
        const parsed = xml_h.rvn_xml_parse(&document, text, size);
        xml_h.rvn_xml_free(&document);
        if (parsed == 0) {
            base.rvn_free(text);
            return raven.R_FALSE;
        }
    }

    xml_h.rvn_xml_push_file_dir(live.*.path, &previous_dir);
    rvn_live_begin();
    if (xml_h.rvn_xml_load(&document, text, size, live.*.path) != 0) {
        const root_name = document.root.*.name;
        const root_is_window = base.rvn_stricmp(root_name, "Window") == 0;
        var content: [*c]const xml_h.rvn_xml_node_t = null;
        var island: [*c]const xml_h.rvn_xml_node_t = null;
        var valid: c_int = undefined;
        if (live.*.is_window != @intFromBool(root_is_window)) {
            const word: [*c]const u8 = if (live.*.is_window != 0) "be" else "not be";
            base.rvn_error(raven.R_ERROR_XML, raven.R_SEVERITY_ERROR, "%s: the root element must %s <Window>", live.*.path, word);
            valid = raven.R_FALSE;
        } else if (root_is_window) {
            valid = xml_h.rvn_xml_window_parts(document.root, &content, &island);
            if (valid != 0 and content != null) valid = rvn_live_valid(content);
            if (valid != 0 and island != null) valid = rvn_live_valid(island);
        } else {
            valid = rvn_live_valid(document.root);
        }
        if (valid != 0) {
            if (window != null) {
                rvn_live_reload_window(live, window, &document);
                ok = raven.R_TRUE;
            } else {
                ok = rvn_live_reload_widget(live, widget, &document);
            }
        }
        if (ok != 0) {
            xml_h.rvn_xml_free(&live.*.document);
            live.*.document = document;
            rvn_live_take_files(live);
        } else {
            xml_h.rvn_xml_free(&document);
        }
    }
    rvn_live_end();
    xml_h.rvn_xml_pop_file_dir(previous_dir);
    base.rvn_free(text);

    if (g_live.callback != null) {
        const path = base.rvn_strdup(live.*.path);
        ctx_h.rvn_dispatch_begin();
        g_live.callback.?(path, ok, g_live.callback_user);
        ctx_h.rvn_dispatch_end();
        base.rvn_free(path);
    }
    // (an error was reported: the file is left alone until it changes again)
    return raven.R_TRUE;
}

// Forgets what was built from files and no longer exists.
fn rvn_live_sweep() void {
    var i: u32 = 0;
    while (i < g_live.live_count) {
        const live = g_live.lives[i];
        const alive = if (live.*.is_window != 0) widget_h.rvn_window_get(live.*.target) != null else widget_h.rvn_widget_get(live.*.target) != null;
        if (alive) {
            i += 1;
            continue;
        }
        rvn_live_free(live);
        g_live.live_count -= 1;
        g_live.lives[i] = g_live.lives[g_live.live_count];
    }
}

fn rvn_live_uses(live: [*c]const rvn_live_t, path: [*c]const u8) c_int {
    var i: u32 = 0;
    if (libc.strcmp(live.*.path, path) == 0) return raven.R_TRUE;
    while (i < live.*.file_count) : (i += 1) {
        if (libc.strcmp(live.*.files[i], path) == 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

// Reloads what was built from `path`, or everything when it is NULL.
fn rvn_live_reload_all(path: [*c]const u8) c_int {
    var i: u32 = 0;
    var ok: c_int = raven.R_TRUE;
    rvn_live_sweep();
    // (a reload may build things from files: only what was there is looked at)
    const count = g_live.live_count;
    while (i < count and i < g_live.live_count) : (i += 1) {
        const live = g_live.lives[i];
        if (path != null and rvn_live_uses(live, path) == 0) continue;
        if (rvn_live_reload(live) == 0) ok = raven.R_FALSE;
    }
    return ok;
}

fn rvn_live_file_changed(path: [*c]const u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = user; // RVN_UNUSED(user)
    return rvn_live_reload_all(path);
}

fn rvn_live_widgets_changed(path: [*c]const u8, user: ?*anyopaque) callconv(.c) c_int {
    var size: usize = 0;
    const text = base.rvn_read_file(path, &size);
    var document: xml_h.rvn_xml_document_t = undefined;
    var previous_dir: [*c]u8 = undefined;
    _ = user; // RVN_UNUSED(user)
    if (text == null) return raven.R_FALSE;
    if (g_live.quiet != 0) {
        const parsed = xml_h.rvn_xml_parse(&document, text, size);
        xml_h.rvn_xml_free(&document);
        if (parsed == 0) {
            base.rvn_free(text);
            return raven.R_FALSE;
        }
    }
    xml_h.rvn_xml_push_file_dir(path, &previous_dir);
    _ = raven.Rxml_register_widgets(text, size);
    xml_h.rvn_xml_pop_file_dir(previous_dir);
    base.rvn_free(text);
    // any interface may use the widgets the file declares
    _ = rvn_live_reload_all(null);
    return raven.R_TRUE;
}

export fn rvn_live_watch_widgets(path: [*c]const u8) void {
    rvn_watch_add(path, &rvn_live_widgets_changed, null);
}

export fn rvn_live_shutdown() void {
    var i: u32 = 0;
    while (i < g_live.live_count) : (i += 1) rvn_live_free(g_live.lives[i]);
    fs_watch_h.rvn_fs_watch_stop();
    i = 0;
    while (i < g_live.watch_count) : (i += 1) {
        base.rvn_free(g_live.watches[i].path);
        base.rvn_free(g_live.watches[i].native_path);
    }
    i = 0;
    while (i < g_live.file_count) : (i += 1) base.rvn_free(g_live.files[i]);
    base.rvn_free(@ptrCast(g_live.lives));
    base.rvn_free(g_live.watches);
    base.rvn_free(@ptrCast(g_live.files));
    g_live = std.mem.zeroes(live_state_t);
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rxml_set_live_reload(enabled: c_int) void {
    if (ctx_h.rvn_api_check("Rxml_set_live_reload") == 0) return;
    rvn_live_configure();
    g_live.disabled = @intFromBool(enabled == 0);
    if (enabled != 0) _ = rvn_watch_poll();
    rvn_watch_sync_timer();
}

export fn Rxml_get_live_reload() c_int {
    if (ctx_h.g_rvn.initialized == 0) return raven.R_FALSE;
    rvn_live_configure();
    return @intFromBool(g_live.disabled == 0);
}

export fn Rxml_set_reload_callback(callback: raven.RXmlReloadCallback, user_data: ?*anyopaque) void {
    if (ctx_h.rvn_api_check("Rxml_set_reload_callback") == 0) return;
    g_live.callback = callback;
    g_live.callback_user = user_data;
}

export fn Rxml_check_files() c_int {
    if (ctx_h.rvn_api_check("Rxml_check_files") == 0) return 0;
    rvn_live_configure();
    return rvn_watch_poll();
}
