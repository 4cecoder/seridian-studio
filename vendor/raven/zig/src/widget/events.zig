// Translated to Zig from vendor/raven/src/widget/events.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/events.c
// Delivery of input events to widgets (bubbling) and actions.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const widget_h = @import("widget_h.zig");

fn rvn_event_bubbles(type_: raven.REventType) c_int {
    switch (type_) {
        @intCast(raven.R_EVENT_MOUSE_MOVE),
        @intCast(raven.R_EVENT_MOUSE_DOWN),
        @intCast(raven.R_EVENT_MOUSE_UP),
        @intCast(raven.R_EVENT_MOUSE_WHEEL),
        @intCast(raven.R_EVENT_KEY_DOWN),
        @intCast(raven.R_EVENT_KEY_UP),
        @intCast(raven.R_EVENT_TEXT),
        => return raven.R_TRUE,
        else => return raven.R_FALSE,
    }
}

fn rvn_widget_deliver(target: [*c]widget_h.rvn_widget_t, event: [*c]raven.REvent, bubbles: c_int) c_int {
    var widget = target;
    var handled: c_int = raven.R_FALSE;
    const window_x = event.*.x;
    const window_y = event.*.y;

    if (target == null or (target.*.flags & widget_h.RVN_WF_DEAD) != 0) return raven.R_FALSE;
    event.*.target = target.*.id;
    if (target.*.window != null) event.*.window = target.*.window.*.id;

    ctx_h.rvn_dispatch_begin();
    while (widget != null and (widget.*.flags & widget_h.RVN_WF_DEAD) == 0) {
        const origin = widget_h.rvn_widget_origin(widget);
        const is_popup_root = (widget.*.flags & widget_h.RVN_WF_POPUP) != 0;
        // under a canvas that zooms, the point is where it falls in what the widget believes it is
        event.*.x = window_x;
        event.*.y = window_y;
        widget_h.rvn_widget_to_virtual(widget, &event.*.x, &event.*.y);
        event.*.local_x = event.*.x - origin.x;
        event.*.local_y = event.*.y - origin.y;

        // the application sees the event first and may consume it
        if (widget.*.event_callback != null and widget.*.event_callback.?(widget.*.id, event, widget.*.event_user) != 0) {
            handled = raven.R_TRUE;
            break;
        }
        if ((widget.*.flags & widget_h.RVN_WF_DEAD) == 0 and widget.*.cls.*.event != null and widget.*.cls.*.event.?(widget, event) != 0) {
            handled = raven.R_TRUE;
            break;
        }
        // events do not leave a popup, and a deleted widget has no parent any more
        if (bubbles == 0 or is_popup_root or (widget.*.flags & widget_h.RVN_WF_DEAD) != 0) break;
        widget = widget.*.parent;
    }
    ctx_h.rvn_dispatch_end();
    event.*.x = window_x;
    event.*.y = window_y;
    return handled;
}

export fn rvn_widget_dispatch(target: [*c]widget_h.rvn_widget_t, event: [*c]raven.REvent) c_int {
    return rvn_widget_deliver(target, event, rvn_event_bubbles(event.*.type));
}

export fn rvn_widget_send(target: [*c]widget_h.rvn_widget_t, event: [*c]raven.REvent) c_int {
    return rvn_widget_deliver(target, event, raven.R_FALSE);
}

export fn rvn_widget_fire_action(widget: [*c]widget_h.rvn_widget_t) void {
    if (widget.*.action == null) return;
    // the callback may delete the widget or change its action: work on a copy
    const action = base.rvn_strdup(widget.*.action);
    const sender = widget.*.id;
    ctx_h.rvn_dispatch_begin();
    ctx_h.rvn_fire_action(sender, action);
    ctx_h.rvn_dispatch_end();
    base.rvn_free(action);
}

export fn rvn_widget_capture_mouse(widget: [*c]widget_h.rvn_widget_t) void {
    if (widget.*.window != null) widget.*.window.*.capture = widget;
}

export fn rvn_widget_release_mouse(widget: [*c]widget_h.rvn_widget_t) void {
    if (widget.*.window != null and widget.*.window.*.capture == widget) widget.*.window.*.capture = null;
}

export fn rvn_widget_focus(widget: [*c]widget_h.rvn_widget_t) void {
    if (widget.*.window == null) return;
    if ((widget.*.flags & widget_h.RVN_WF_FOCUSABLE) == 0 or widget_h.rvn_widget_is_enabled(widget) == 0 or widget_h.rvn_widget_is_shown(widget) == 0) return;
    widget_h.rvn_window_set_focus(widget.*.window, widget);
}
