// Translated to Zig from vendor/raven/src/widget/paint.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widget/paint.c
// Tree traversal that fills the draw list, with parallel painting of large
// subtrees, and hit testing.
//
// Painting only reads the widget tree, so sibling subtrees can be painted at
// the same time: each job fills its own draw list and the lists are appended
// in child order afterwards, which keeps the result identical to a serial
// paint. Widgets whose paint calls application code (RVN_CF_UI_PAINT) are
// always painted on the UI thread.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx_h = @import("../core/context_h.zig");
const jobs_h = @import("../core/jobs_h.zig");
const thread_h = @import("../core/thread_h.zig");
const draw_h = @import("../render/draw_h.zig");
const common_h = @import("../widgets/common_h.zig");
const widget_h = @import("widget_h.zig");

const rvn_widget_t = widget_h.rvn_widget_t;

/// A widget forks when its subtree holds at least this many widgets.
const RVN_PAINT_FORK_MIN = 512;
/// Minimum number of widgets given to one job.
const RVN_PAINT_CHUNK_MIN = 96;
const RVN_PAINT_MAX_CHUNKS = 32;
/// Widgets may draw a little outside their bounds (shadows, focus outlines).
const RVN_PAINT_CULL_MARGIN: f32 = 48.0;
/// Below this many instances, copying them in parallel is not worth a job.
const RVN_PAINT_PARALLEL_COPY_MIN = 8192;

/// RVN_ARRAY_RESERVE (core/base.h) for an array of pointers. The macro is expanded here because
/// base_h.RVN_ARRAY_RESERVE cannot take a pointer to a pointer: its `data.*` (`[*c][*c]T`) does not
/// coerce to the `?*anyopaque` parameter of rvn_array_grow_, so the cast is written out.
fn reserveArrayOfPointers(comptime T: type, data: *[*c]T, cap: [*c]u32, needed: u32) void {
    if (needed > cap.*) data.* = @ptrCast(@alignCast(base.rvn_array_grow_(@ptrCast(data.*), cap, needed, @sizeOf(T))));
}

// ---------------------------------------------------------------------------
//  Scratch draw lists reused by the paint jobs
// ---------------------------------------------------------------------------

const GPaint = extern struct {
    mutex: thread_h.rvn_mutex_t,
    lists: [*c][*c]draw_h.rvn_drawlist_t,
    count: u32,
    cap: u32,
    jobs: thread_h.rvn_atomic_t,
    initialized: c_int,
};

var g_paint: GPaint = std.mem.zeroes(GPaint);

export fn rvn_paint_init() void {
    g_paint = std.mem.zeroes(GPaint);
    thread_h.rvn_mutex_init(&g_paint.mutex);
    g_paint.initialized = raven.R_TRUE;
}

export fn rvn_paint_shutdown() void {
    if (g_paint.initialized == 0) return;
    var i: u32 = 0;
    while (i < g_paint.count) : (i += 1) {
        draw_h.rvn_drawlist_free(g_paint.lists[i]);
        base.rvn_free(g_paint.lists[i]);
    }
    base.rvn_free(@ptrCast(g_paint.lists));
    thread_h.rvn_mutex_destroy(&g_paint.mutex);
    g_paint = std.mem.zeroes(GPaint);
}

/// Number of paint jobs started since the last call.
export fn rvn_paint_take_job_count() c_int {
    return thread_h.rvn_atomic_exchange(&g_paint.jobs, 0);
}

fn rvn_paint_scratch_acquire() [*c]draw_h.rvn_drawlist_t {
    var list: [*c]draw_h.rvn_drawlist_t = null;
    thread_h.rvn_mutex_lock(&g_paint.mutex);
    if (g_paint.count > 0) {
        g_paint.count -= 1;
        list = g_paint.lists[g_paint.count];
    }
    thread_h.rvn_mutex_unlock(&g_paint.mutex);
    if (list == null) {
        list = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(draw_h.rvn_drawlist_t))));
        draw_h.rvn_drawlist_init(list);
    }
    draw_h.rvn_drawlist_reset(list);
    return list;
}

fn rvn_paint_scratch_release(list: [*c]draw_h.rvn_drawlist_t) void {
    thread_h.rvn_mutex_lock(&g_paint.mutex);
    reserveArrayOfPointers([*c]draw_h.rvn_drawlist_t, &g_paint.lists, &g_paint.cap, g_paint.count + 1);
    const index = g_paint.count;
    g_paint.count += 1;
    g_paint.lists[index] = list;
    thread_h.rvn_mutex_unlock(&g_paint.mutex);
}

// ---------------------------------------------------------------------------
//  Children
// ---------------------------------------------------------------------------

const rvn_paint_chunk_t = extern struct {
    parent: [*c]rvn_widget_t,
    first: u32,
    last: u32,
    weight: u32,
    needs_ui_thread: c_int,
    painter: draw_h.RPainter,
    /// Where the instances of the chunk go in the list of the parent.
    destination: [*c]raven.RDrawInstance,
};

fn rvn_paint_range(parent: [*c]rvn_widget_t, first: u32, last: u32, painter: *const draw_h.RPainter) void {
    var i: u32 = first;
    while (i < last) : (i += 1) {
        const child = parent.*.children[i];
        if (parent.*.cls.*.child_active) |child_active| {
            if (child_active(parent, child) == 0) continue;
        }
        rvn_widget_paint(child, @ptrCast(painter));
    }
}

fn rvn_paint_chunk_job(arg: ?*anyopaque) callconv(.c) void {
    const chunk: *rvn_paint_chunk_t = @ptrCast(@alignCast(arg));
    rvn_paint_range(chunk.parent, chunk.first, chunk.last, &chunk.painter);
}

fn rvn_paint_copy_job(arg: ?*anyopaque) callconv(.c) void {
    const chunk: *rvn_paint_chunk_t = @ptrCast(@alignCast(arg));
    const source: [*c]const draw_h.rvn_drawlist_t = chunk.painter.list;
    if (source.*.instance_count != 0) {
        const count: usize = source.*.instance_count;
        @memcpy(chunk.destination[0..count], source.*.instances[0..count]);
    }
}

/// Returns R_FALSE when the children should simply be painted in order.
fn rvn_paint_children_parallel(widget: [*c]rvn_widget_t, painter: *const draw_h.RPainter) c_int {
    var chunks: [RVN_PAINT_MAX_CHUNKS]rvn_paint_chunk_t = undefined;
    var group: jobs_h.rvn_job_group_t = undefined;
    var chunk_count: u32 = 0;
    var target: u32 = undefined;
    var i: u32 = undefined;
    const workers = jobs_h.rvn_jobs_worker_count();

    target = widget.*.subtree_count / @as(u32, @bitCast((workers + 1) * 2));
    if (target < RVN_PAINT_CHUNK_MIN) target = RVN_PAINT_CHUNK_MIN;

    i = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (chunk_count == 0 or (chunks[chunk_count - 1].weight >= target and chunk_count < RVN_PAINT_MAX_CHUNKS)) {
            const made = &chunks[chunk_count];
            chunk_count += 1;
            made.parent = widget;
            made.first = i;
            made.weight = 0;
            made.needs_ui_thread = raven.R_FALSE;
        }
        const chunk = &chunks[chunk_count - 1];
        chunk.last = i + 1;
        chunk.weight +%= child.*.subtree_count;
        if (child.*.ui_paint_count > 0) chunk.needs_ui_thread = raven.R_TRUE;
    }
    if (chunk_count < 2) return raven.R_FALSE;

    group = std.mem.zeroes(jobs_h.rvn_job_group_t);
    i = 0;
    while (i < chunk_count) : (i += 1) {
        chunks[i].painter = painter.*;
        chunks[i].painter.list = rvn_paint_scratch_acquire();
        // the last chunk is kept for this thread, which would otherwise only wait
        if (chunks[i].needs_ui_thread == 0 and i + 1 < chunk_count) {
            jobs_h.rvn_jobs_submit(&group, rvn_paint_chunk_job, &chunks[i]);
            _ = thread_h.rvn_atomic_add(&g_paint.jobs, 1);
        }
    }
    i = 0;
    while (i < chunk_count) : (i += 1) {
        if (chunks[i].needs_ui_thread != 0 or i + 1 == chunk_count) rvn_paint_chunk_job(&chunks[i]);
    }
    jobs_h.rvn_jobs_wait(&group);

    // gather the chunks in child order: the result is the same as a serial paint
    const list = painter.list;
    const base_ = list.*.instance_count;
    var total: u32 = 0;
    i = 0;
    while (i < chunk_count) : (i += 1) total += chunks[i].painter.list.*.instance_count;
    base.RVN_ARRAY_RESERVE(&list.*.instances, &list.*.instance_cap, base_ + total);
    total = 0;
    i = 0;
    while (i < chunk_count) : (i += 1) {
        chunks[i].destination = list.*.instances + @as(usize, base_ + total);
        total += chunks[i].painter.list.*.instance_count;
    }
    // the copy itself is large enough to be shared between the threads
    i = 0;
    while (i < chunk_count) : (i += 1) {
        if (total >= RVN_PAINT_PARALLEL_COPY_MIN and i + 1 < chunk_count) {
            jobs_h.rvn_jobs_submit(&group, rvn_paint_copy_job, &chunks[i]);
        } else {
            rvn_paint_copy_job(&chunks[i]);
        }
    }
    jobs_h.rvn_jobs_wait(&group);
    list.*.instance_count = base_ + total;
    i = 0;
    while (i < chunk_count) : (i += 1) {
        draw_h.rvn_drawlist_append_commands(list, chunks[i].painter.list, @intCast(chunks[i].destination - list.*.instances));
        rvn_paint_scratch_release(chunks[i].painter.list);
    }
    return raven.R_TRUE;
}

fn rvn_paint_children(widget: [*c]rvn_widget_t, painter: *const draw_h.RPainter) void {
    if (widget.*.subtree_count >= RVN_PAINT_FORK_MIN and widget.*.child_count >= 2 and jobs_h.rvn_jobs_worker_count() > 0) {
        if (rvn_paint_children_parallel(widget, painter) != 0) return;
    }
    rvn_paint_range(widget, 0, widget.*.child_count, painter);
}

// ---------------------------------------------------------------------------
//  Widget
// ---------------------------------------------------------------------------

export fn rvn_widget_paint(widget: [*c]rvn_widget_t, parent: ?*const raven.RPainter) void {
    const parent_: *const draw_h.RPainter = @ptrCast(@alignCast(parent.?));
    var painter: draw_h.RPainter = undefined;
    var bounds: base.rvn_box_t = undefined;
    var transition: widget_h.rvn_transition_state_t = std.mem.zeroes(widget_h.rvn_transition_state_t);
    var first_instance: u32 = undefined;
    var first_command: u32 = undefined;

    if (widget.*.visibility != raven.R_VISIBLE or widget.*.opacity <= 0.0) return;

    painter = parent_.*;
    painter.ox += widget.*.rect.x;
    painter.oy += widget.*.rect.y;
    painter.opacity *= widget.*.opacity;
    painter.clip_depth = 0;
    if (widget.*.direction == raven.R_DIRECTION_RTL) {
        painter.rtl = raven.R_TRUE;
    } else if (widget.*.direction == raven.R_DIRECTION_LTR) {
        painter.rtl = raven.R_FALSE;
    } else if (widget.*.parent == null) {
        painter.rtl = widget_h.rvn_direction_global_rtl();
    }
    if ((widget.*.flags & widget_h.RVN_WF_DISABLED) != 0) painter.enabled = raven.R_FALSE;
    // the text takes the color of the nearest ancestor that has one: a widget, a style, or a theme given to a part of the tree
    if (widget.*.theme_own != 0 or widget_h.rvn_widget_has_color(widget, raven.R_COLOR_TEXT) != 0) {
        painter.text_color = widget_h.rvn_widget_color(widget, raven.R_COLOR_TEXT);
    }

    bounds = draw_h.rvn_paint_snap(&painter, base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h));
    if ((widget.*.cls.*.flags & widget_h.RVN_CF_OVERFLOW) == 0) {
        // nothing of this subtree can be visible: skip it entirely
        const margin = RVN_PAINT_CULL_MARGIN * painter.scale;
        const grown = base.rvn_box(bounds.x0 - margin, bounds.y0 - margin, bounds.x1 + margin, bounds.y1 + margin);
        if (base.rvn_box_overlaps(grown, painter.clip) == 0) return;
    }

    // a widget that is arriving: not shown before its turn, then faded in here and moved below
    transition.active = raven.R_FALSE;
    if (widget.*.fx != null and widget.*.fx.*.playing != 0) {
        if (widget_h.rvn_transition_begin(widget, @ptrCast(&painter), &transition) == 0) return;
        if (transition.active != 0) painter.opacity *= transition.opacity;
    }
    first_instance = painter.list.*.instance_count;
    first_command = painter.list.*.command_count;

    // a widget that draws no surface and was given a material becomes a panel of it
    if (widget.*.material != 0 and (widget.*.cls.*.flags & widget_h.RVN_CF_SURFACE) == 0) {
        const rect = base.rvn_rect(0.0, 0.0, widget.*.rect.w, widget.*.rect.h);
        const radius = widget_h.rvn_widget_metric(widget, raven.R_METRIC_CORNER_RADIUS);
        if (widget.*.material == raven.R_MATERIAL_SOLID) {
            draw_h.rvn_paint_box(&painter, rect, radius, widget_h.rvn_widget_color(widget, raven.R_COLOR_PANEL), 0.0, 0);
        } else {
            var glass: draw_h.rvn_glass_t = undefined;
            var radii: [4]f32 = undefined;
            common_h.rvn_glass_style(widget, common_h.RVN_SURFACE_PANEL, 0.0, 0.0, &glass);
            const radius_all = base.rvn_minf(base.rvn_maxf(radius, 10.0) + 8.0, base.rvn_minf(rect.w, rect.h) * 0.5);
            radii[0] = radius_all;
            radii[1] = radius_all;
            radii[2] = radius_all;
            radii[3] = radius_all;
            draw_h.rvn_paint_glass(&painter, rect, &radii, &glass);
        }
    }
    if (widget.*.cls.*.paint) |paint_fn| paint_fn(widget, @ptrCast(&painter));

    if (widget.*.child_count > 0 and (widget.*.cls.*.flags & widget_h.RVN_CF_OWN_CHILDREN) == 0) {
        var inner = painter;
        inner.clip_depth = 0;
        // (text color and opacity changed by the paint function reach the children)
        inner.ox += widget.*.child_shift.x;
        inner.oy += widget.*.child_shift.y;
        if ((widget.*.flags & widget_h.RVN_WF_CLIP) != 0) inner.clip = base.rvn_box_intersect(inner.clip, bounds);
        if (base.rvn_box_empty(inner.clip) == 0) rvn_paint_children(widget, &inner);
    }

    if (widget.*.cls.*.paint_overlay) |paint_overlay_fn| {
        painter.clip_depth = 0;
        paint_overlay_fn(widget, @ptrCast(&painter));
    }

    // squash, stretch, fly: applied to everything the subtree has just drawn
    if (transition.active != 0 or widget.*.xform.grow_x != 0.0 or widget.*.xform.grow_y != 0.0 or
        widget.*.xform.dx != 0.0 or widget.*.xform.dy != 0.0)
    {
        var sx: f32 = 1.0 + widget.*.xform.grow_x;
        var sy: f32 = 1.0 + widget.*.xform.grow_y;
        var dx: f32 = widget.*.xform.dx;
        var dy: f32 = widget.*.xform.dy;
        var pivot_x: f32 = 0.5;
        var pivot_y: f32 = 0.5;
        if (transition.active != 0) {
            sx *= transition.sx;
            sy *= transition.sy;
            dx += transition.dx;
            dy += transition.dy;
            pivot_x += transition.pivot_x;
            pivot_y += transition.pivot_y;
        }
        draw_h.rvn_drawlist_transform(painter.list, first_instance, first_command, sx, sy, (painter.ox + widget.*.rect.w * pivot_x) * painter.scale, (painter.oy + widget.*.rect.h * pivot_y) * painter.scale, dx * painter.scale, dy * painter.scale, parent_.*.clip);
    }
}

// ---------------------------------------------------------------------------
//  Hit testing
// ---------------------------------------------------------------------------

export fn rvn_widget_hit_test(widget: [*c]rvn_widget_t, x: f32, y: f32) [*c]rvn_widget_t {
    if (widget.*.visibility != raven.R_VISIBLE) return null;
    var local_x = x - widget.*.rect.x;
    var local_y = y - widget.*.rect.y;
    const inside = local_x >= 0.0 and local_y >= 0.0 and local_x < widget.*.rect.w and local_y < widget.*.rect.h;
    // children are inside the bounds unless the class says they may overflow
    if (!inside and ((widget.*.flags & widget_h.RVN_WF_CLIP) != 0 or (widget.*.cls.*.flags & widget_h.RVN_CF_OVERFLOW) == 0)) return null;

    const shown_x = local_x;
    const shown_y = local_y;
    // a class that shows its children larger or smaller than they are laid out
    if (widget.*.child_scale > 0.0 and widget.*.child_scale != 1.0) {
        local_x /= widget.*.child_scale;
        local_y /= widget.*.child_scale;
    }
    // the last child is drawn on top: test it first
    var i: u32 = widget.*.child_count;
    while (i > 0) : (i -= 1) {
        const child = widget.*.children[i - 1];
        if (widget.*.cls.*.child_active) |child_active| {
            if (child_active(widget, child) == 0) continue;
        }
        if (widget.*.cls.*.child_at) |child_at| {
            if (child_at(widget, child, shown_x, shown_y) == 0) continue;
        }
        const hit = rvn_widget_hit_test(child, local_x, local_y);
        if (hit != null) return hit;
    }
    if (inside and (widget.*.flags & widget_h.RVN_WF_NO_HIT) == 0) return widget;
    return null;
}
