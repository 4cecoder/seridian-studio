// Translated to Zig from vendor/raven/src/widget/layout.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/layout.c
// The two layout passes and their invalidation.
//
//   measure  (bottom-up)  every widget computes the size it would like,
//                         from the desired sizes of its children;
//   arrange  (top-down)   every panel gives its children their final bounds.
//
// Both results are cached per widget. A change marks the widget and its
// ancestors dirty, and the next pass only visits the dirty branches:
//   - a clean widget returns its cached desired size without recursion,
//   - a widget whose size did not change and that is not dirty keeps the
//     arrangement of its whole subtree (moving a subtree costs nothing).

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("widget_h.zig");

const rvn_widget_t = widget_h.rvn_widget_t;

export fn rvn_widget_invalidate_layout(widget: [*c]rvn_widget_t) void {
    // Invariant: a dirty widget inside the laid-out tree has dirty ancestors,
    // so the walk can stop at the first widget that is already fully dirty.
    var walk = widget;
    while (walk != null) : (walk = walk.*.parent) {
        if ((walk.*.flags & widget_h.RVN_WF_LAYOUT_DIRTY) == widget_h.RVN_WF_LAYOUT_DIRTY) break;
        walk.*.flags |= widget_h.RVN_WF_LAYOUT_DIRTY;
    }
    if (widget.*.window != null) {
        widget.*.window.*.needs_layout = raven.R_TRUE;
        widget.*.window.*.needs_paint = raven.R_TRUE;
    }
}

export fn rvn_widget_invalidate_paint(widget: [*c]rvn_widget_t) void {
    if (widget.*.window != null) widget.*.window.*.needs_paint = raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Measure
// ---------------------------------------------------------------------------

fn rvn_widget_measure_default(widget: [*c]rvn_widget_t) base.rvn_vec2_t {
    var desired = base.rvn_vec2(0.0, 0.0);
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = rvn_widget_measure_slot(widget.*.children[i]);
        desired.x = base.rvn_maxf(desired.x, child.x);
        desired.y = base.rvn_maxf(desired.y, child.y);
    }
    return desired;
}

export fn rvn_widget_measure(widget: [*c]rvn_widget_t) base.rvn_vec2_t {
    // A collapsed widget is skipped and keeps its dirty state for later.
    if (widget.*.visibility == raven.R_COLLAPSED) return base.rvn_vec2(0.0, 0.0);
    if ((widget.*.flags & widget_h.RVN_WF_MEASURE_DIRTY) == 0) return widget.*.desired;

    // cleared first: an invalidation raised while measuring must survive
    widget.*.flags &= ~widget_h.RVN_WF_MEASURE_DIRTY;
    var desired = if (widget.*.cls.*.measure) |measure_fn| measure_fn(widget) else rvn_widget_measure_default(widget);

    if (widget.*.fixed_size.x >= 0.0) desired.x = widget.*.fixed_size.x;
    if (widget.*.fixed_size.y >= 0.0) desired.y = widget.*.fixed_size.y;
    if (widget.*.min_size.x >= 0.0) desired.x = base.rvn_maxf(desired.x, widget.*.min_size.x);
    if (widget.*.min_size.y >= 0.0) desired.y = base.rvn_maxf(desired.y, widget.*.min_size.y);
    if (widget.*.max_size.x >= 0.0) desired.x = base.rvn_minf(desired.x, widget.*.max_size.x);
    if (widget.*.max_size.y >= 0.0) desired.y = base.rvn_minf(desired.y, widget.*.max_size.y);

    widget.*.desired = desired;
    return desired;
}

export fn rvn_widget_measure_slot(child: [*c]rvn_widget_t) base.rvn_vec2_t {
    if (child.*.visibility == raven.R_COLLAPSED) return base.rvn_vec2(0.0, 0.0);
    var desired = rvn_widget_measure(child);
    desired.x += child.*.slot.padding.l + child.*.slot.padding.r;
    desired.y += child.*.slot.padding.t + child.*.slot.padding.b;
    return desired;
}

// ---------------------------------------------------------------------------
//  Arrange
// ---------------------------------------------------------------------------

fn rvn_widget_arrange_default(widget: [*c]rvn_widget_t) void {
    const area = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
    var i: u32 = 0;
    while (i < widget.*.child_count) : (i += 1) {
        if (widget_h.rvn_widget_collapsed(widget.*.children[i]) == 0) rvn_widget_arrange_slot(widget.*.children[i], area);
    }
}

export fn rvn_widget_arrange(widget: [*c]rvn_widget_t, x_: f32, y: f32, width_: f32, height_: f32) void {
    var x = x_;
    var width = width_;
    var height = height_;
    if (width < 0.0) width = 0.0;
    if (height < 0.0) height = 0.0;
    const resized = widget.*.rect.w != width or widget.*.rect.h != height;
    // right to left: the parent places its children as in a mirror
    if (widget.*.parent != null and (widget.*.flags & (widget_h.RVN_WF_POPUP | widget_h.RVN_WF_INTERNAL)) == 0 and
        (widget.*.parent.*.cls.*.flags & widget_h.RVN_CF_NO_MIRROR) == 0 and widget_h.rvn_widget_is_rtl(widget.*.parent) != 0)
    {
        x = widget.*.parent.*.rect.w - x - width;
    }
    widget.*.rect = base.rvn_rect(x, y, width, height);
    if (resized or (widget.*.flags & widget_h.RVN_WF_ARRANGE_DIRTY) != 0) {
        // cleared first: an invalidation raised while arranging must survive
        widget.*.flags &= ~widget_h.RVN_WF_ARRANGE_DIRTY;
        if (widget.*.cls.*.arrange) |arrange_fn| {
            arrange_fn(widget);
        } else {
            rvn_widget_arrange_default(widget);
        }
    }
}

export fn rvn_widget_arrange_slot(child: [*c]rvn_widget_t, area_: base.rvn_rect_t) void {
    const desired = child.*.desired;
    const area = base.rvn_rect_inset(area_, child.*.slot.padding);
    var x: f32 = undefined;
    var y: f32 = undefined;
    var width: f32 = undefined;
    var height: f32 = undefined;

    switch (child.*.slot.halign) {
        raven.R_HALIGN_LEFT => {
            width = base.rvn_minf(desired.x, area.w);
            x = area.x;
        },
        raven.R_HALIGN_CENTER => {
            width = base.rvn_minf(desired.x, area.w);
            x = area.x + (area.w - width) * 0.5;
        },
        raven.R_HALIGN_RIGHT => {
            width = base.rvn_minf(desired.x, area.w);
            x = area.x + area.w - width;
        },
        // R_HALIGN_FILL and default
        else => {
            width = area.w;
            x = area.x;
        },
    }
    switch (child.*.slot.valign) {
        raven.R_VALIGN_TOP => {
            height = base.rvn_minf(desired.y, area.h);
            y = area.y;
        },
        raven.R_VALIGN_CENTER => {
            height = base.rvn_minf(desired.y, area.h);
            y = area.y + (area.h - height) * 0.5;
        },
        raven.R_VALIGN_BOTTOM => {
            height = base.rvn_minf(desired.y, area.h);
            y = area.y + area.h - height;
        },
        // R_VALIGN_FILL and default
        else => {
            height = area.h;
            y = area.y;
        },
    }
    rvn_widget_arrange(child, x, y, width, height);
}
