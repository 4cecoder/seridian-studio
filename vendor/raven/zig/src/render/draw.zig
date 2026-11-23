// Translated to Zig from vendor/raven/src/render/draw.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/draw.c
// Draw list storage and painter primitives.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const context_h = @import("../core/context_h.zig");
const draw_h = @import("draw_h.zig");
const font_h = @import("font_h.zig");
const renderer_h = @import("renderer_h.zig");
const libc = @import("../sys/libc.zig");

// raven.zig types the enumerators as C `int` / `unsigned` (c_int / c_uint). The fields they are
// compared with and stored in are `c_uint` (`type`) or `u32` (`flags`, `color`). Same values.
const R_DRAW_INSTANCES: c_uint = @intCast(raven.R_DRAW_INSTANCES);
const R_DRAW_CALLBACK: c_uint = @intCast(raven.R_DRAW_CALLBACK);
const R_DRAW_BACKDROP: c_uint = @intCast(raven.R_DRAW_BACKDROP);
const R_DRAW_ERASE: c_uint = @intCast(raven.R_DRAW_ERASE);
const R_DRAW_SHADER: c_uint = @intCast(raven.R_DRAW_SHADER);

const R_PRIM_MASK: u32 = @intCast(raven.R_PRIM_MASK);
const R_PRIM_RECT: u32 = @intCast(raven.R_PRIM_RECT);
const R_PRIM_SHADOW: u32 = @intCast(raven.R_PRIM_SHADOW);
const R_PRIM_LINE: u32 = @intCast(raven.R_PRIM_LINE);
const R_PRIM_TRIANGLE: u32 = @intCast(raven.R_PRIM_TRIANGLE);
const R_PRIM_GLASS: u32 = @intCast(raven.R_PRIM_GLASS);
const R_PRIM_BLUR: u32 = @intCast(raven.R_PRIM_BLUR);
const R_PRIM_CURVE: u32 = @intCast(raven.R_PRIM_CURVE);
const R_INSTANCE_TEXTURED: u32 = @intCast(raven.R_INSTANCE_TEXTURED);

const RVN_ICON_CHEVRON_RIGHT: c_uint = @intCast(draw_h.RVN_ICON_CHEVRON_RIGHT);
const RVN_ICON_CHEVRON_DOWN: c_uint = @intCast(draw_h.RVN_ICON_CHEVRON_DOWN);
const RVN_ICON_CHEVRON_UP: c_uint = @intCast(draw_h.RVN_ICON_CHEVRON_UP);
const RVN_ICON_CHEVRON_LEFT: c_uint = @intCast(draw_h.RVN_ICON_CHEVRON_LEFT);
const RVN_ICON_CHECK: c_uint = @intCast(draw_h.RVN_ICON_CHECK);
const RVN_ICON_CROSS: c_uint = @intCast(draw_h.RVN_ICON_CROSS);

// ---------------------------------------------------------------------------
//  Draw list
// ---------------------------------------------------------------------------

export fn rvn_drawlist_init(list: [*c]draw_h.rvn_drawlist_t) void {
    list.* = std.mem.zeroes(draw_h.rvn_drawlist_t);
}

export fn rvn_drawlist_free(list: [*c]draw_h.rvn_drawlist_t) void {
    base.rvn_free(list.*.instances);
    base.rvn_free(list.*.commands);
    list.* = std.mem.zeroes(draw_h.rvn_drawlist_t);
}

export fn rvn_drawlist_reset(list: [*c]draw_h.rvn_drawlist_t) void {
    list.*.instance_count = 0;
    list.*.command_count = 0;
}

fn rvn_drawlist_new_command(list: [*c]draw_h.rvn_drawlist_t, texture: raven.Rid) [*c]raven.RDrawCommand {
    base.RVN_ARRAY_RESERVE(&list.*.commands, &list.*.command_cap, list.*.command_count + 1);
    const command = &list.*.commands[list.*.command_count];
    list.*.command_count += 1;
    command.* = std.mem.zeroes(raven.RDrawCommand);
    command.*.type = R_DRAW_INSTANCES;
    command.*.texture = texture;
    command.*.viewport = raven.R_INVALID_ID;
    command.*.shader = raven.R_INVALID_ID;
    command.*.first_instance = list.*.instance_count;
    return command;
}

export fn rvn_drawlist_add(list: [*c]draw_h.rvn_drawlist_t, texture: raven.Rid) [*c]raven.RDrawInstance {
    var command: [*c]raven.RDrawCommand = if (list.*.command_count != 0) &list.*.commands[list.*.command_count - 1] else null;

    if (command == null or command.*.type != R_DRAW_INSTANCES) {
        command = rvn_drawlist_new_command(list, texture);
    } else if (texture != raven.R_INVALID_ID and command.*.texture != texture) {
        // a batch that only holds untextured instances can adopt the texture
        if (command.*.texture == raven.R_INVALID_ID) {
            command.*.texture = texture;
        } else {
            command = rvn_drawlist_new_command(list, texture);
        }
    }
    base.RVN_ARRAY_RESERVE(&list.*.instances, &list.*.instance_cap, list.*.instance_count + 1);
    command.*.instance_count += 1;
    const instance = &list.*.instances[list.*.instance_count];
    list.*.instance_count += 1;
    return instance;
}

export fn rvn_drawlist_add_erase(list: [*c]draw_h.rvn_drawlist_t) [*c]raven.RDrawInstance {
    // a command of its own: it is drawn with another blending
    const command = rvn_drawlist_new_command(list, raven.R_INVALID_ID);
    command.*.type = R_DRAW_ERASE;
    base.RVN_ARRAY_RESERVE(&list.*.instances, &list.*.instance_cap, list.*.instance_count + 1);
    command.*.instance_count = 1;
    const instance = &list.*.instances[list.*.instance_count];
    list.*.instance_count += 1;
    return instance;
}

export fn rvn_drawlist_add_shader(list: [*c]draw_h.rvn_drawlist_t, shader: raven.Rid, texture: raven.Rid) [*c]raven.RDrawInstance {
    var command: [*c]raven.RDrawCommand = if (list.*.command_count != 0) &list.*.commands[list.*.command_count - 1] else null;
    // the effects that follow one another with the same shader and texture are one draw
    if (command == null or command.*.type != R_DRAW_SHADER or command.*.shader != shader or command.*.texture != texture) {
        command = rvn_drawlist_new_command(list, texture);
        command.*.type = R_DRAW_SHADER;
        command.*.shader = shader;
    }
    base.RVN_ARRAY_RESERVE(&list.*.instances, &list.*.instance_cap, list.*.instance_count + 1);
    command.*.instance_count += 1;
    const instance = &list.*.instances[list.*.instance_count];
    list.*.instance_count += 1;
    return instance;
}

export fn rvn_drawlist_add_callback(list: [*c]draw_h.rvn_drawlist_t, callback: [*c]const raven.RDrawCommand) void {
    base.RVN_ARRAY_RESERVE(&list.*.commands, &list.*.command_cap, list.*.command_count + 1);
    const command = &list.*.commands[list.*.command_count];
    list.*.command_count += 1;
    command.* = callback.*;
    command.*.type = R_DRAW_CALLBACK;
    command.*.first_instance = list.*.instance_count;
    command.*.instance_count = 0;
}

export fn rvn_drawlist_add_backdrop(list: [*c]draw_h.rvn_drawlist_t, area: base.rvn_box_t) void {
    base.RVN_ARRAY_RESERVE(&list.*.commands, &list.*.command_cap, list.*.command_count + 1);
    const command = &list.*.commands[list.*.command_count];
    list.*.command_count += 1;
    command.* = std.mem.zeroes(raven.RDrawCommand);
    command.*.type = R_DRAW_BACKDROP;
    command.*.texture = raven.R_INVALID_ID;
    command.*.viewport = raven.R_INVALID_ID;
    command.*.first_instance = list.*.instance_count;
    command.*.rect[0] = @intFromFloat(@floor(area.x0));
    command.*.rect[1] = @intFromFloat(@floor(area.y0));
    command.*.rect[2] = @intFromFloat(@ceil(area.x1 - area.x0));
    command.*.rect[3] = @intFromFloat(@ceil(area.y1 - area.y0));
}

export fn rvn_drawlist_append(list: [*c]draw_h.rvn_drawlist_t, source: [*c]const draw_h.rvn_drawlist_t) void {
    const base_ = list.*.instance_count;
    if (source.*.instance_count != 0) {
        base.RVN_ARRAY_RESERVE(&list.*.instances, &list.*.instance_cap, list.*.instance_count + source.*.instance_count);
        const count: usize = source.*.instance_count;
        const start: usize = list.*.instance_count;
        @memcpy((list.*.instances + start)[0..count], source.*.instances[0..count]);
        list.*.instance_count += source.*.instance_count;
    }
    rvn_drawlist_append_commands(list, source, base_);
}

export fn rvn_drawlist_append_commands(list: [*c]draw_h.rvn_drawlist_t, source: [*c]const draw_h.rvn_drawlist_t, base_: u32) void {
    var i: u32 = 0;
    while (i < source.*.command_count) : (i += 1) {
        const in: [*c]const raven.RDrawCommand = &source.*.commands[i];
        const last: [*c]raven.RDrawCommand = if (list.*.command_count != 0) &list.*.commands[list.*.command_count - 1] else null;
        if (in.*.type == R_DRAW_INSTANCES and in.*.instance_count == 0) continue;
        if (in.*.type == R_DRAW_INSTANCES and last != null and last.*.type == R_DRAW_INSTANCES and
            last.*.first_instance + last.*.instance_count == base_ + in.*.first_instance and
            (last.*.texture == in.*.texture or last.*.texture == raven.R_INVALID_ID or in.*.texture == raven.R_INVALID_ID))
        {
            if (last.*.texture == raven.R_INVALID_ID) last.*.texture = in.*.texture;
            last.*.instance_count += in.*.instance_count;
            continue;
        }
        base.RVN_ARRAY_RESERVE(&list.*.commands, &list.*.command_cap, list.*.command_count + 1);
        list.*.commands[list.*.command_count] = in.*;
        list.*.commands[list.*.command_count].first_instance = base_ + in.*.first_instance;
        list.*.command_count += 1;
    }
}

// ---------------------------------------------------------------------------
//  Backdrop captures
// ---------------------------------------------------------------------------

//
// Where the frame differs from its captured copy: what was drawn since the
// last capture of that place, as a few rectangles. Exactness does not
// matter: a rectangle that is too large only costs a capture that could have
// been avoided, or one that is larger than needed.
//
const RVN_DIRTY_MAX = 16;
const RVN_DIRTY_NEAR: f32 = 8.0;

const rvn_dirty_t = extern struct {
    boxes: [RVN_DIRTY_MAX]base.rvn_box_t,
    count: c_int,
    // box that received the previous rectangle: runs of glyphs and rows extend it
    last: c_int,
};

fn rvn_box_union(a: base.rvn_box_t, b: base.rvn_box_t) base.rvn_box_t {
    return base.rvn_box(base.rvn_minf(a.x0, b.x0), base.rvn_minf(a.y0, b.y0), base.rvn_maxf(a.x1, b.x1), base.rvn_maxf(a.y1, b.y1));
}

fn rvn_box_area(box: base.rvn_box_t) f32 {
    return (box.x1 - box.x0) * (box.y1 - box.y0);
}

fn rvn_dirty_add(dirty: [*c]rvn_dirty_t, box: base.rvn_box_t) void {
    var i: c_int = 0;
    var best: c_int = 0;
    var best_growth: f32 = 0.0;

    if (base.rvn_box_empty(box) != 0) return;
    if (dirty.*.last >= 0 and dirty.*.last < dirty.*.count) {
        const last = &dirty.*.boxes[@intCast(dirty.*.last)];
        if (box.x0 <= last.x1 + RVN_DIRTY_NEAR and box.x1 >= last.x0 - RVN_DIRTY_NEAR and
            box.y0 <= last.y1 + RVN_DIRTY_NEAR and box.y1 >= last.y0 - RVN_DIRTY_NEAR)
        {
            last.* = rvn_box_union(last.*, box);
            return;
        }
    }
    while (i < dirty.*.count) : (i += 1) {
        const other = &dirty.*.boxes[@intCast(i)];
        if (box.x0 >= other.x0 and box.y0 >= other.y0 and box.x1 <= other.x1 and box.y1 <= other.y1) {
            dirty.*.last = i;
            return;
        }
    }
    if (dirty.*.count < RVN_DIRTY_MAX) {
        dirty.*.last = dirty.*.count;
        dirty.*.boxes[@intCast(dirty.*.count)] = box;
        dirty.*.count += 1;
        return;
    }
    // full: grow the rectangle that grows the least
    i = 0;
    while (i < dirty.*.count) : (i += 1) {
        const growth = rvn_box_area(rvn_box_union(dirty.*.boxes[@intCast(i)], box)) - rvn_box_area(dirty.*.boxes[@intCast(i)]);
        if (i == 0 or growth < best_growth) {
            best = i;
            best_growth = growth;
        }
    }
    const bi: usize = @intCast(best);
    dirty.*.boxes[bi] = rvn_box_union(dirty.*.boxes[bi], box);
    dirty.*.last = best;
}

// Pixels an instance can touch.
fn rvn_instance_bounds(instance: [*c]const raven.RDrawInstance) base.rvn_box_t {
    var box = base.rvn_box(instance.*.rect[0], instance.*.rect[1], instance.*.rect[2], instance.*.rect[3]);
    var grow: f32 = 1.0;
    switch (instance.*.flags & R_PRIM_MASK) {
        R_PRIM_SHADOW => {
            grow = instance.*.border_width + 1.0;
        },
        R_PRIM_LINE => {
            box = base.rvn_box(base.rvn_minf(instance.*.rect[0], instance.*.rect[2]), base.rvn_minf(instance.*.rect[1], instance.*.rect[3]), base.rvn_maxf(instance.*.rect[0], instance.*.rect[2]), base.rvn_maxf(instance.*.rect[1], instance.*.rect[3]));
            grow = instance.*.radii[0] * 0.5 + 1.0;
        },
        R_PRIM_TRIANGLE => {
            box = base.rvn_box(base.rvn_minf(base.rvn_minf(instance.*.rect[0], instance.*.rect[2]), instance.*.radii[0]), base.rvn_minf(base.rvn_minf(instance.*.rect[1], instance.*.rect[3]), instance.*.radii[1]), base.rvn_maxf(base.rvn_maxf(instance.*.rect[0], instance.*.rect[2]), instance.*.radii[0]), base.rvn_maxf(base.rvn_maxf(instance.*.rect[1], instance.*.rect[3]), instance.*.radii[1]));
        },
        R_PRIM_CURVE => {
            box = base.rvn_box(base.rvn_minf(base.rvn_minf(instance.*.rect[0], instance.*.rect[2]), base.rvn_minf(instance.*.radii[0], instance.*.radii[2])), base.rvn_minf(base.rvn_minf(instance.*.rect[1], instance.*.rect[3]), base.rvn_minf(instance.*.radii[1], instance.*.radii[3])), base.rvn_maxf(base.rvn_maxf(instance.*.rect[0], instance.*.rect[2]), base.rvn_maxf(instance.*.radii[0], instance.*.radii[2])), base.rvn_maxf(base.rvn_maxf(instance.*.rect[1], instance.*.rect[3]), base.rvn_maxf(instance.*.radii[1], instance.*.radii[3])));
            grow = instance.*.border_width * 0.5 + instance.*.uv[0] + 1.0;
        },
        else => {},
    }
    box = base.rvn_box(box.x0 - grow, box.y0 - grow, box.x1 + grow, box.y1 + grow);
    return base.rvn_box_intersect(box, base.rvn_box(instance.*.clip[0], instance.*.clip[1], instance.*.clip[2], instance.*.clip[3]));
}

//
// A capture is needed where glass covers something that is not in the copy
// yet. It then takes the whole of those rectangles, not only the part under
// the glass: the ten buttons of a glass bar cost one capture of the bar, not
// ten. Returns R_FALSE when the copy is already up to date under `area`.
//
fn rvn_dirty_take(dirty: [*c]rvn_dirty_t, area: base.rvn_box_t, region: [*c]base.rvn_box_t) c_int {
    var i: c_int = 0;
    var found: c_int = raven.R_FALSE;
    region.* = area;
    while (i < dirty.*.count) {
        if (base.rvn_box_overlaps(dirty.*.boxes[@intCast(i)], area) != 0) {
            region.* = rvn_box_union(region.*, dirty.*.boxes[@intCast(i)]);
            dirty.*.count -= 1;
            dirty.*.boxes[@intCast(i)] = dirty.*.boxes[@intCast(dirty.*.count)];
            found = raven.R_TRUE;
        } else {
            i += 1;
        }
    }
    if (found != 0) dirty.*.last = -1;
    return found;
}

export fn rvn_drawlist_resolve_backdrops(list: [*c]draw_h.rvn_drawlist_t, frame: base.rvn_box_t, max: u32) u32 {
    var dirty: rvn_dirty_t = undefined;
    var captures: u32 = 0;
    var kept: u32 = 0;
    var i: u32 = 0;
    var k: u32 = 0;
    var has_backdrop: c_int = raven.R_FALSE;

    while (i < list.*.command_count and has_backdrop == 0) : (i += 1) {
        has_backdrop = if (list.*.commands[i].type == R_DRAW_BACKDROP) raven.R_TRUE else raven.R_FALSE;
    }
    if (has_backdrop == 0) return 0;

    // nothing of the frame is in the copy yet: the first capture takes it all
    dirty.boxes[0] = frame;
    dirty.count = 1;
    dirty.last = 0;
    i = 0;
    while (i < list.*.command_count) : (i += 1) {
        var command = list.*.commands[i];
        const previous: [*c]raven.RDrawCommand = if (kept != 0) &list.*.commands[kept - 1] else null;

        if (command.type == R_DRAW_BACKDROP) {
            const area = base.rvn_box(@floatFromInt(command.rect[0]), @floatFromInt(command.rect[1]), @floatFromInt(command.rect[0] + command.rect[2]), @floatFromInt(command.rect[1] + command.rect[3]));
            var region: base.rvn_box_t = undefined;
            if (captures >= max or rvn_dirty_take(&dirty, area, &region) == 0) continue;
            region = base.rvn_box_intersect(region, frame);
            command.rect[0] = @intFromFloat(@floor(region.x0));
            command.rect[1] = @intFromFloat(@floor(region.y0));
            command.rect[2] = @as(c_int, @intFromFloat(@ceil(region.x1))) - command.rect[0];
            command.rect[3] = @as(c_int, @intFromFloat(@ceil(region.y1))) - command.rect[1];
            captures += 1;
        } else if (command.type == R_DRAW_CALLBACK) {
            rvn_dirty_add(&dirty, base.rvn_box(@floatFromInt(command.clip[0]), @floatFromInt(command.clip[1]), @floatFromInt(command.clip[0] + command.clip[2]), @floatFromInt(command.clip[1] + command.clip[3])));
        } else {
            k = 0;
            while (k < command.instance_count) : (k += 1) {
                rvn_dirty_add(&dirty, rvn_instance_bounds(&list.*.instances[command.first_instance + k]));
            }
            // two batches that were only separated by a removed capture become one again
            if (command.type == R_DRAW_INSTANCES and previous != null and previous.*.type == R_DRAW_INSTANCES and
                previous.*.first_instance + previous.*.instance_count == command.first_instance and
                (previous.*.texture == command.texture or previous.*.texture == raven.R_INVALID_ID or command.texture == raven.R_INVALID_ID))
            {
                if (previous.*.texture == raven.R_INVALID_ID) previous.*.texture = command.texture;
                previous.*.instance_count += command.instance_count;
                continue;
            }
        }
        list.*.commands[kept] = command;
        kept += 1;
    }
    list.*.command_count = kept;
    return captures;
}

// ---------------------------------------------------------------------------
//  Transform of a range
// ---------------------------------------------------------------------------

export fn rvn_drawlist_transform(list: [*c]draw_h.rvn_drawlist_t, first_instance: u32, first_command: u32, sx: f32, sy: f32, pivot_x: f32, pivot_y: f32, dx: f32, dy: f32, limit: base.rvn_box_t) void {
    // lengths without a direction (corner radii, line widths, blur) follow the smaller scale
    const s = base.rvn_minf(@abs(sx), @abs(sy));
    const tx = pivot_x - pivot_x * sx + dx;
    const ty = pivot_y - pivot_y * sy + dy;
    var i: u32 = first_instance;

    if (sx == 1.0 and sy == 1.0 and dx == 0.0 and dy == 0.0) return;
    while (i < list.*.instance_count) : (i += 1) {
        const instance = &list.*.instances[i];
        const kind: u32 = instance.*.flags & R_PRIM_MASK;

        instance.*.rect[0] = instance.*.rect[0] * sx + tx;
        instance.*.rect[1] = instance.*.rect[1] * sy + ty;
        instance.*.rect[2] = instance.*.rect[2] * sx + tx;
        instance.*.rect[3] = instance.*.rect[3] * sy + ty;
        switch (kind) {
            R_PRIM_LINE => {
                // two points and a width
                instance.*.radii[0] *= s;
            },
            R_PRIM_TRIANGLE => {
                // the third point is in the radii
                instance.*.radii[0] = instance.*.radii[0] * sx + tx;
                instance.*.radii[1] = instance.*.radii[1] * sy + ty;
            },
            R_PRIM_CURVE => {
                // the control points are in the radii
                instance.*.radii[0] = instance.*.radii[0] * sx + tx;
                instance.*.radii[1] = instance.*.radii[1] * sy + ty;
                instance.*.radii[2] = instance.*.radii[2] * sx + tx;
                instance.*.radii[3] = instance.*.radii[3] * sy + ty;
                instance.*.border_width *= s;
                instance.*.uv[0] *= s;
            },
            R_PRIM_BLUR => {
                instance.*.uv[0] *= s;
                instance.*.radii[0] *= s;
                instance.*.radii[1] *= s;
                instance.*.radii[2] *= s;
                instance.*.radii[3] *= s;
                instance.*.border_width *= s;
            },
            R_PRIM_GLASS => {
                instance.*.uv[1] *= s;
                // fall through to the default body (C has no break here)
                instance.*.radii[0] *= s;
                instance.*.radii[1] *= s;
                instance.*.radii[2] *= s;
                instance.*.radii[3] *= s;
                instance.*.border_width *= s;
            },
            else => {
                instance.*.radii[0] *= s;
                instance.*.radii[1] *= s;
                instance.*.radii[2] *= s;
                instance.*.radii[3] *= s;
                instance.*.border_width *= s;
            },
        }
        var clip = base.rvn_box(instance.*.clip[0] * sx + tx, instance.*.clip[1] * sy + ty, instance.*.clip[2] * sx + tx, instance.*.clip[3] * sy + ty);
        clip = base.rvn_box_intersect(clip, limit);
        instance.*.clip[0] = clip.x0;
        instance.*.clip[1] = clip.y0;
        instance.*.clip[2] = clip.x1;
        instance.*.clip[3] = clip.y1;
    }
    i = first_command;
    while (i < list.*.command_count) : (i += 1) {
        const command = &list.*.commands[i];
        // (viewport callbacks draw by themselves and stay where they are)
        if (command.*.type == R_DRAW_BACKDROP) {
            const x0: f32 = @as(f32, @floatFromInt(command.*.rect[0])) * sx + tx;
            const y0: f32 = @as(f32, @floatFromInt(command.*.rect[1])) * sy + ty;
            const x1: f32 = @as(f32, @floatFromInt(command.*.rect[0] + command.*.rect[2])) * sx + tx;
            const y1: f32 = @as(f32, @floatFromInt(command.*.rect[1] + command.*.rect[3])) * sy + ty;
            command.*.rect[0] = @intFromFloat(@floor(x0));
            command.*.rect[1] = @intFromFloat(@floor(y0));
            command.*.rect[2] = @as(c_int, @intFromFloat(@ceil(x1))) - command.*.rect[0];
            command.*.rect[3] = @as(c_int, @intFromFloat(@ceil(y1))) - command.*.rect[1];
        }
    }
}

// ---------------------------------------------------------------------------
//  Painter helpers
// ---------------------------------------------------------------------------

export fn rvn_paint_snap(painter: [*c]const draw_h.RPainter, rect: base.rvn_rect_t) base.rvn_box_t {
    var box: base.rvn_box_t = undefined;
    box.x0 = @floor((painter.*.ox + rect.x) * painter.*.scale + 0.5);
    box.y0 = @floor((painter.*.oy + rect.y) * painter.*.scale + 0.5);
    box.x1 = @floor((painter.*.ox + rect.x + rect.w) * painter.*.scale + 0.5);
    box.y1 = @floor((painter.*.oy + rect.y + rect.h) * painter.*.scale + 0.5);
    return box;
}

// Thickness in pixels of a logical line width: never thinner than one pixel.
fn rvn_paint_stroke(painter: [*c]const draw_h.RPainter, width: f32) f32 {
    if (width <= 0.0) return 0.0;
    const pixels = @floor(width * painter.*.scale + 0.5);
    return if (pixels < 1.0) 1.0 else pixels;
}

fn rvn_paint_color(painter: [*c]const draw_h.RPainter, color: base.rvn_color_t) base.rvn_color_t {
    return if (painter.*.opacity < 0.999) base.rvn_color_fade(color, painter.*.opacity) else color;
}

fn rvn_instance_clip(instance: [*c]raven.RDrawInstance, painter: [*c]const draw_h.RPainter) void {
    instance.*.clip[0] = painter.*.clip.x0;
    instance.*.clip[1] = painter.*.clip.y0;
    instance.*.clip[2] = painter.*.clip.x1;
    instance.*.clip[3] = painter.*.clip.y1;
}

// Appends an instance unless `bounds` is entirely clipped.
fn rvn_paint_emit(painter: [*c]draw_h.RPainter, bounds: base.rvn_box_t, texture: raven.Rid) [*c]raven.RDrawInstance {
    if (base.rvn_box_overlaps(bounds, painter.*.clip) == 0) return null;
    const instance = rvn_drawlist_add(painter.*.list, texture);
    instance.* = std.mem.zeroes(raven.RDrawInstance);
    rvn_instance_clip(instance, painter);
    return instance;
}

// ---------------------------------------------------------------------------
//  Primitives
// ---------------------------------------------------------------------------

export fn rvn_paint_box4(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, fill: base.rvn_color_t, border_width: f32, border_color: base.rvn_color_t) void {
    const fill_ = rvn_paint_color(painter, fill);
    var border_color_ = rvn_paint_color(painter, border_color);
    var border_width_ = border_width;
    if (border_width_ <= 0.0 or base.rvn_color_a(border_color_) == 0) {
        border_width_ = 0.0;
        border_color_ = 0;
    }
    if (base.rvn_color_a(fill_) == 0 and border_width_ <= 0.0) return;

    const box = rvn_paint_snap(painter, rect);
    if (box.x1 <= box.x0 or box.y1 <= box.y0) return;
    const instance = rvn_paint_emit(painter, box, raven.R_INVALID_ID);
    if (instance == null) return;

    const limit = base.rvn_minf(box.x1 - box.x0, box.y1 - box.y0) * 0.5;
    instance.*.rect[0] = box.x0;
    instance.*.rect[1] = box.y0;
    instance.*.rect[2] = box.x1;
    instance.*.rect[3] = box.y1;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        instance.*.radii[i] = if (radii != null) base.rvn_clampf(radii[i] * painter.*.scale, 0.0, limit) else 0.0;
    }
    instance.*.color = fill_;
    instance.*.border_color = border_color_;
    instance.*.border_width = rvn_paint_stroke(painter, border_width_);
    instance.*.flags = R_PRIM_RECT;
}

export fn rvn_paint_box(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t, radius: f32, fill: base.rvn_color_t, border_width: f32, border_color: base.rvn_color_t) void {
    const radii: [4]f32 = .{ radius, radius, radius, radius };
    rvn_paint_box4(painter, rect, &radii, fill, border_width, border_color);
}

export fn rvn_paint_rect(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t, color: base.rvn_color_t) void {
    rvn_paint_box4(painter, rect, null, color, 0.0, 0);
}

export fn rvn_paint_shadow(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t, radius: f32, blur: f32, color: base.rvn_color_t) void {
    const color_ = rvn_paint_color(painter, color);
    const blur_px = blur * painter.*.scale;
    if (base.rvn_color_a(color_) == 0 or blur_px <= 0.0) return;
    const box = rvn_paint_snap(painter, rect);
    const bounds = base.rvn_box(box.x0 - blur_px, box.y0 - blur_px, box.x1 + blur_px, box.y1 + blur_px);
    const instance = rvn_paint_emit(painter, bounds, raven.R_INVALID_ID);
    if (instance == null) return;
    const limit = base.rvn_minf(box.x1 - box.x0, box.y1 - box.y0) * 0.5;
    instance.*.rect[0] = box.x0;
    instance.*.rect[1] = box.y0;
    instance.*.rect[2] = box.x1;
    instance.*.rect[3] = box.y1;
    const r = base.rvn_clampf(radius * painter.*.scale, 0.0, limit);
    instance.*.radii[0] = r;
    instance.*.radii[1] = r;
    instance.*.radii[2] = r;
    instance.*.radii[3] = r;
    instance.*.color = color_;
    instance.*.border_width = blur_px;
    instance.*.flags = R_PRIM_SHADOW;
}

export fn rvn_paint_glass(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, glass: [*c]const draw_h.rvn_glass_t) void {
    const box = rvn_paint_snap(painter, rect);

    if (box.x1 <= box.x0 or box.y1 <= box.y0 or painter.*.opacity <= 0.0) return;
    if (base.rvn_box_overlaps(box, painter.*.clip) == 0) return;

    const half = base.rvn_minf(box.x1 - box.x0, box.y1 - box.y0) * 0.5;
    var bevel = if (glass.*.bevel > 0.0) glass.*.bevel else base.rvn_clampf(base.rvn_minf(rect.w, rect.h) * 0.42, 3.0, 14.0);
    bevel = base.rvn_minf(bevel * painter.*.scale, half * 0.95);
    const refraction = glass.*.refraction * painter.*.scale;

    // the backdrop is taken before the shadow, so that the glass does not see its own shadow
    // (what the shader reads around the slab: the bent rim, and the reflection on it)
    const margin = base.rvn_maxf(refraction, bevel * 1.5 + 6.0) + 2.0;
    rvn_drawlist_add_backdrop(painter.*.list, base.rvn_box_intersect(painter.*.clip, base.rvn_box(box.x0 - margin, box.y0 - margin, box.x1 + margin, box.y1 + margin)));
    if (glass.*.shadow > 0.0) {
        rvn_paint_shadow(painter, base.rvn_rect(rect.x, rect.y + glass.*.shadow * 0.25, rect.w, rect.h), if (radii != null) radii[0] else 0.0, glass.*.shadow, glass.*.shadow_color);
    }

    const instance = rvn_paint_emit(painter, box, raven.R_INVALID_ID);
    if (instance == null) return;
    instance.*.rect[0] = box.x0;
    instance.*.rect[1] = box.y0;
    instance.*.rect[2] = box.x1;
    instance.*.rect[3] = box.y1;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        instance.*.radii[i] = if (radii != null) base.rvn_clampf(radii[i] * painter.*.scale, 0.0, half) else 0.0;
    }
    instance.*.uv[0] = base.rvn_clampf(glass.*.frost, 0.0, 1.0);
    instance.*.uv[1] = refraction;
    instance.*.uv[2] = glass.*.saturation;
    instance.*.uv[3] = glass.*.glow;
    instance.*.color = glass.*.tint;
    instance.*.border_color = glass.*.rim;
    instance.*.border_width = bevel;
    instance.*.flags = R_PRIM_GLASS | (@as(u32, @intFromFloat(base.rvn_clampf(painter.*.opacity, 0.0, 1.0) * 255.0 + 0.5)) << 8);
}

export fn rvn_paint_blur(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, blur: [*c]const draw_h.rvn_blur_t) void {
    const box = rvn_paint_snap(painter, rect);

    if (box.x1 <= box.x0 or box.y1 <= box.y0 or painter.*.opacity <= 0.0) return;
    if (base.rvn_box_overlaps(box, painter.*.clip) == 0) return;
    const half = base.rvn_minf(box.x1 - box.x0, box.y1 - box.y0) * 0.5;
    const radius = base.rvn_clampf(blur.*.radius, 0.0, 96.0) * painter.*.scale;

    // (what the shader reads around the shape: as far as the blur reaches)
    const margin = radius + 4.0;
    rvn_drawlist_add_backdrop(painter.*.list, base.rvn_box_intersect(painter.*.clip, base.rvn_box(box.x0 - margin, box.y0 - margin, box.x1 + margin, box.y1 + margin)));
    if (blur.*.shadow > 0.0) {
        rvn_paint_shadow(painter, base.rvn_rect(rect.x, rect.y + blur.*.shadow * 0.25, rect.w, rect.h), if (radii != null) radii[0] else 0.0, blur.*.shadow, blur.*.shadow_color);
    }
    const instance = rvn_paint_emit(painter, box, raven.R_INVALID_ID);
    if (instance == null) return;
    instance.*.rect[0] = box.x0;
    instance.*.rect[1] = box.y0;
    instance.*.rect[2] = box.x1;
    instance.*.rect[3] = box.y1;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        instance.*.radii[i] = if (radii != null) base.rvn_clampf(radii[i] * painter.*.scale, 0.0, half) else 0.0;
    }
    instance.*.uv[0] = radius;
    instance.*.uv[1] = base.rvn_clampf(blur.*.grain, 0.0, 1.0);
    instance.*.uv[2] = blur.*.saturation;
    instance.*.uv[3] = blur.*.light;
    instance.*.color = blur.*.tint;
    instance.*.border_color = blur.*.border;
    instance.*.border_width = if (blur.*.border_width > 0.0) base.rvn_maxf(1.0, @floor(blur.*.border_width * painter.*.scale + 0.5)) else 0.0;
    instance.*.flags = R_PRIM_BLUR | (@as(u32, @intFromFloat(base.rvn_clampf(painter.*.opacity, 0.0, 1.0) * 255.0 + 0.5)) << 8);
}

export fn rvn_paint_erase(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t, radii: [*c]const f32, amount: f32) void {
    const box = rvn_paint_snap(painter, rect);
    const amount_ = base.rvn_clampf(amount * painter.*.opacity, 0.0, 1.0);
    if (box.x1 <= box.x0 or box.y1 <= box.y0 or amount_ <= 0.0) return;
    if (base.rvn_box_overlaps(box, painter.*.clip) == 0) return;
    const half = base.rvn_minf(box.x1 - box.x0, box.y1 - box.y0) * 0.5;
    const instance = rvn_drawlist_add_erase(painter.*.list);
    instance.* = std.mem.zeroes(raven.RDrawInstance);
    instance.*.rect[0] = box.x0;
    instance.*.rect[1] = box.y0;
    instance.*.rect[2] = box.x1;
    instance.*.rect[3] = box.y1;
    instance.*.clip[0] = painter.*.clip.x0;
    instance.*.clip[1] = painter.*.clip.y0;
    instance.*.clip[2] = painter.*.clip.x1;
    instance.*.clip[3] = painter.*.clip.y1;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        instance.*.radii[i] = if (radii != null) base.rvn_clampf(radii[i] * painter.*.scale, 0.0, half) else 0.0;
    }
    // (only its alpha counts: how much of what is there goes)
    instance.*.color = base.rvn_rgba(0.0, 0.0, 0.0, amount_);
    instance.*.flags = R_PRIM_RECT;
}

export fn rvn_paint_line(painter: [*c]draw_h.RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: base.rvn_color_t) void {
    const ax = (painter.*.ox + x0) * painter.*.scale;
    const ay = (painter.*.oy + y0) * painter.*.scale;
    const bx = (painter.*.ox + x1) * painter.*.scale;
    const by = (painter.*.oy + y1) * painter.*.scale;
    const width = base.rvn_maxf(1.0, thickness * painter.*.scale);
    const extent = width * 0.5 + 1.0;

    const color_ = rvn_paint_color(painter, color);
    if (base.rvn_color_a(color_) == 0) return;
    const bounds = base.rvn_box(base.rvn_minf(ax, bx) - extent, base.rvn_minf(ay, by) - extent, base.rvn_maxf(ax, bx) + extent, base.rvn_maxf(ay, by) + extent);
    const instance = rvn_paint_emit(painter, bounds, raven.R_INVALID_ID);
    if (instance == null) return;
    instance.*.rect[0] = ax;
    instance.*.rect[1] = ay;
    instance.*.rect[2] = bx;
    instance.*.rect[3] = by;
    instance.*.radii[0] = width;
    instance.*.color = color_;
    instance.*.flags = R_PRIM_LINE;
}

export fn rvn_curve_point(points: [*c]const f32, t: f32) base.rvn_vec2_t {
    const u = 1.0 - t;
    const a = u * u * u;
    const b = 3.0 * u * u * t;
    const c = 3.0 * u * t * t;
    const d = t * t * t;
    return base.rvn_vec2(a * points[0] + b * points[2] + c * points[4] + d * points[6], a * points[1] + b * points[3] + c * points[5] + d * points[7]);
}

export fn rvn_paint_curve(painter: [*c]draw_h.RPainter, points: [*c]const f32, curve: [*c]const draw_h.rvn_curve_t) void {
    var pixels: [8]f32 = undefined;
    const width = base.rvn_maxf(1.0, curve.*.thickness * painter.*.scale);
    const halo = base.rvn_maxf(curve.*.halo, 0.0) * painter.*.scale;
    const extent = width * 0.5 + halo + 1.0;
    const from = rvn_paint_color(painter, curve.*.from);
    const to = rvn_paint_color(painter, curve.*.to);
    var i: usize = 0;

    if (base.rvn_color_a(from) == 0 and base.rvn_color_a(to) == 0) return;
    while (i < 4) : (i += 1) {
        pixels[i * 2] = (painter.*.ox + points[i * 2]) * painter.*.scale;
        pixels[i * 2 + 1] = (painter.*.oy + points[i * 2 + 1]) * painter.*.scale;
    }
    // a curve stays inside its four points
    var bounds = base.rvn_box(pixels[0], pixels[1], pixels[0], pixels[1]);
    i = 1;
    while (i < 4) : (i += 1) {
        bounds.x0 = base.rvn_minf(bounds.x0, pixels[i * 2]);
        bounds.y0 = base.rvn_minf(bounds.y0, pixels[i * 2 + 1]);
        bounds.x1 = base.rvn_maxf(bounds.x1, pixels[i * 2]);
        bounds.y1 = base.rvn_maxf(bounds.y1, pixels[i * 2 + 1]);
    }
    bounds = base.rvn_box(bounds.x0 - extent, bounds.y0 - extent, bounds.x1 + extent, bounds.y1 + extent);
    const instance = rvn_paint_emit(painter, bounds, raven.R_INVALID_ID);
    if (instance == null) return;
    instance.*.rect[0] = pixels[0];
    instance.*.rect[1] = pixels[1];
    instance.*.rect[2] = pixels[6];
    instance.*.rect[3] = pixels[7];
    instance.*.radii[0] = pixels[2];
    instance.*.radii[1] = pixels[3];
    instance.*.radii[2] = pixels[4];
    instance.*.radii[3] = pixels[5];
    instance.*.border_width = width;
    instance.*.color = from;
    instance.*.border_color = to;
    instance.*.uv[0] = halo;
    instance.*.uv[1] = base.rvn_clampf(curve.*.halo_opacity, 0.0, 1.0);
    instance.*.uv[2] = curve.*.phase - @floor(curve.*.phase);
    instance.*.uv[3] = base.rvn_maxf(curve.*.pulses, 0.0);
    instance.*.flags = R_PRIM_CURVE | (@as(u32, @intFromFloat(base.rvn_clampf(curve.*.pulse_strength, 0.0, 1.0) * 255.0 + 0.5)) << 8);
}

export fn rvn_paint_triangle(painter: [*c]draw_h.RPainter, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, color: base.rvn_color_t) void {
    const ax = (painter.*.ox + x0) * painter.*.scale;
    const ay = (painter.*.oy + y0) * painter.*.scale;
    const bx = (painter.*.ox + x1) * painter.*.scale;
    const by = (painter.*.oy + y1) * painter.*.scale;
    const cx = (painter.*.ox + x2) * painter.*.scale;
    const cy = (painter.*.oy + y2) * painter.*.scale;

    const color_ = rvn_paint_color(painter, color);
    if (base.rvn_color_a(color_) == 0) return;
    const bounds = base.rvn_box(base.rvn_minf(ax, base.rvn_minf(bx, cx)) - 1.0, base.rvn_minf(ay, base.rvn_minf(by, cy)) - 1.0, base.rvn_maxf(ax, base.rvn_maxf(bx, cx)) + 1.0, base.rvn_maxf(ay, base.rvn_maxf(by, cy)) + 1.0);
    const instance = rvn_paint_emit(painter, bounds, raven.R_INVALID_ID);
    if (instance == null) return;
    instance.*.rect[0] = ax;
    instance.*.rect[1] = ay;
    instance.*.rect[2] = bx;
    instance.*.rect[3] = by;
    instance.*.radii[0] = cx;
    instance.*.radii[1] = cy;
    instance.*.color = color_;
    instance.*.flags = R_PRIM_TRIANGLE;
}

export fn rvn_paint_image(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t, texture: raven.Rid, uv: [*c]const f32, tint: base.rvn_color_t, radius: f32) void {
    // a texture still being decoded draws nothing
    const object = renderer_h.rvn_texture_get(texture);
    if (object == null or object.*.created == 0) return;
    const tint_ = rvn_paint_color(painter, tint);
    if (base.rvn_color_a(tint_) == 0) return;
    const box = rvn_paint_snap(painter, rect);
    if (box.x1 <= box.x0 or box.y1 <= box.y0) return;
    const instance = rvn_paint_emit(painter, box, texture);
    if (instance == null) return;
    const limit = base.rvn_minf(box.x1 - box.x0, box.y1 - box.y0) * 0.5;
    const r = base.rvn_clampf(radius * painter.*.scale, 0.0, limit);
    instance.*.rect[0] = box.x0;
    instance.*.rect[1] = box.y0;
    instance.*.rect[2] = box.x1;
    instance.*.rect[3] = box.y1;
    instance.*.uv[0] = if (uv != null) uv[0] else 0.0;
    instance.*.uv[1] = if (uv != null) uv[1] else 0.0;
    instance.*.uv[2] = if (uv != null) uv[2] else 1.0;
    instance.*.uv[3] = if (uv != null) uv[3] else 1.0;
    instance.*.radii[0] = r;
    instance.*.radii[1] = r;
    instance.*.radii[2] = r;
    instance.*.radii[3] = r;
    instance.*.color = tint_;
    instance.*.flags = R_PRIM_RECT | R_INSTANCE_TEXTURED;
}

export fn rvn_paint_text(painter: [*c]draw_h.RPainter, font_id: raven.Rid, size: f32, x: f32, y: f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t) void {
    const font = font_h.rvn_font_resolve(font_id);
    if (font == null or text == null) return;
    const size_ = font_h.rvn_font_size_resolve(size);
    const color_ = rvn_paint_color(painter, color);
    font_h.rvn_text_draw(painter.*.list, font, size_ * painter.*.scale, @floor((painter.*.ox + x) * painter.*.scale + 0.5), @floor((painter.*.oy + y) * painter.*.scale + 0.5), text, length, color_, painter.*.clip);
}

export fn rvn_paint_text_in(painter: [*c]draw_h.RPainter, font_id: raven.Rid, size: f32, rect: base.rvn_rect_t, @"align": f32, text: [*c]const u8, length: c_int, color: base.rvn_color_t) void {
    const font = font_h.rvn_font_resolve(font_id);
    var metrics: font_h.rvn_font_metrics_t = undefined;
    if (font == null or text == null) return;
    var align_ = @"align";
    if (painter.*.rtl != 0) align_ = 1.0 - align_;
    const size_ = font_h.rvn_font_size_resolve(size);
    font_h.rvn_font_metrics(font, size_, &metrics);
    const width: f32 = if (align_ > 0.0) font_h.rvn_text_width(font, size_, text, length) else 0.0;
    rvn_paint_text(painter, font_id, size_, rect.x + (rect.w - width) * align_, rect.y + (rect.h - metrics.line_height) * 0.5, text, length, color);
}

export fn rvn_paint_icon(painter: [*c]draw_h.RPainter, icon: draw_h.rvn_icon_t, cx: f32, cy: f32, size: f32, color: base.rvn_color_t) void {
    const h = size * 0.5;
    const q = size * 0.25;
    const t = base.rvn_maxf(1.25, size * 0.14);
    switch (icon) {
        RVN_ICON_CHEVRON_RIGHT => {
            rvn_paint_line(painter, cx - q, cy - h, cx + q, cy, t, color);
            rvn_paint_line(painter, cx + q, cy, cx - q, cy + h, t, color);
        },
        RVN_ICON_CHEVRON_LEFT => {
            rvn_paint_line(painter, cx + q, cy - h, cx - q, cy, t, color);
            rvn_paint_line(painter, cx - q, cy, cx + q, cy + h, t, color);
        },
        RVN_ICON_CHEVRON_DOWN => {
            rvn_paint_line(painter, cx - h, cy - q, cx, cy + q, t, color);
            rvn_paint_line(painter, cx, cy + q, cx + h, cy - q, t, color);
        },
        RVN_ICON_CHEVRON_UP => {
            rvn_paint_line(painter, cx - h, cy + q, cx, cy - q, t, color);
            rvn_paint_line(painter, cx, cy - q, cx + h, cy + q, t, color);
        },
        RVN_ICON_CHECK => {
            rvn_paint_line(painter, cx - h, cy, cx - h * 0.25, cy + h * 0.7, t, color);
            rvn_paint_line(painter, cx - h * 0.25, cy + h * 0.7, cx + h, cy - h * 0.6, t, color);
        },
        RVN_ICON_CROSS => {
            rvn_paint_line(painter, cx - h, cy - h, cx + h, cy + h, t, color);
            rvn_paint_line(painter, cx - h, cy + h, cx + h, cy - h, t, color);
        },
        else => {},
    }
}

export fn rvn_paint_chevron(painter: [*c]draw_h.RPainter, cx: f32, cy: f32, size: f32, angle: f32, color: base.rvn_color_t) void {
    const h = size * 0.5;
    const q = size * 0.25;
    const t = base.rvn_maxf(1.25, size * 0.14);
    const c = @cos(angle);
    const s = @sin(angle);
    // (-q, -h) -> (q, 0) -> (-q, h), rotated
    const ax = cx + (-q) * c - (-h) * s;
    const ay = cy + (-q) * s + (-h) * c;
    const bx = cx + q * c;
    const by = cy + q * s;
    const dx = cx + (-q) * c - h * s;
    const dy = cy + (-q) * s + h * c;
    rvn_paint_line(painter, ax, ay, bx, by, t, color);
    rvn_paint_line(painter, bx, by, dx, dy, t, color);
}

export fn rvn_paint_push_clip(painter: [*c]draw_h.RPainter, rect: base.rvn_rect_t) void {
    if (painter.*.clip_depth < draw_h.RVN_PAINTER_CLIP_STACK) {
        painter.*.clip_stack[@intCast(painter.*.clip_depth)] = painter.*.clip;
    }
    painter.*.clip_depth += 1;
    painter.*.clip = base.rvn_box_intersect(painter.*.clip, rvn_paint_snap(painter, rect));
}

export fn rvn_paint_pop_clip(painter: [*c]draw_h.RPainter) void {
    if (painter.*.clip_depth <= 0) return;
    painter.*.clip_depth -= 1;
    if (painter.*.clip_depth < draw_h.RVN_PAINTER_CLIP_STACK) {
        painter.*.clip = painter.*.clip_stack[@intCast(painter.*.clip_depth)];
    }
}

// ---------------------------------------------------------------------------
//  Public drawing API (custom widgets)
// ---------------------------------------------------------------------------

export fn Rdraw_rect(painter: ?*raven.RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    rvn_paint_box(p, base.rvn_rect(x, y, width, height), radius, base.rvn_rgba(r, g, b, a), 0.0, 0);
}

export fn Rdraw_glass(painter: ?*raven.RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    var glass = std.mem.zeroes(draw_h.rvn_glass_t);
    glass.tint = base.rvn_rgba(r, g, b, a);
    glass.rim = base.rvn_rgba(1.0, 1.0, 1.0, if (context_h.g_rvn.theme.dark != 0) 0.55 else 0.85);
    glass.frost = 1.0;
    glass.refraction = 12.0;
    glass.saturation = 1.5;
    const radii: [4]f32 = .{ radius, radius, radius, radius };
    rvn_paint_glass(p, base.rvn_rect(x, y, width, height), &radii, &glass);
}

export fn Rdraw_rect_outline(painter: ?*raven.RPainter, x: f32, y: f32, width: f32, height: f32, radius: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    rvn_paint_box(p, base.rvn_rect(x, y, width, height), radius, 0, thickness, base.rvn_rgba(r, g, b, a));
}

export fn Rdraw_circle(painter: ?*raven.RPainter, center_x: f32, center_y: f32, radius: f32, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    rvn_paint_box(p, base.rvn_rect(center_x - radius, center_y - radius, radius * 2.0, radius * 2.0), radius, base.rvn_rgba(r, g, b, a), 0.0, 0);
}

export fn Rdraw_line(painter: ?*raven.RPainter, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    rvn_paint_line(p, x0, y0, x1, y1, thickness, base.rvn_rgba(r, g, b, a));
}

export fn Rdraw_curve(painter: ?*raven.RPainter, x0: f32, y0: f32, cx0: f32, cy0: f32, cx1: f32, cy1: f32, x1: f32, y1: f32, thickness: f32, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    var points: [8]f32 = undefined;
    var curve: draw_h.rvn_curve_t = undefined;
    if (p == null) return;
    points[0] = x0;
    points[1] = y0;
    points[2] = cx0;
    points[3] = cy0;
    points[4] = cx1;
    points[5] = cy1;
    points[6] = x1;
    points[7] = y1;
    curve = std.mem.zeroes(draw_h.rvn_curve_t);
    curve.thickness = thickness;
    const color = base.rvn_rgba(r, g, b, a);
    curve.from = color;
    curve.to = color;
    rvn_paint_curve(p, &points, &curve);
}

export fn Rdraw_triangle(painter: ?*raven.RPainter, x0: f32, y0: f32, x1: f32, y1: f32, x2: f32, y2: f32, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    rvn_paint_triangle(p, x0, y0, x1, y1, x2, y2, base.rvn_rgba(r, g, b, a));
}

export fn Rdraw_image(painter: ?*raven.RPainter, texture: raven.Rid, x: f32, y: f32, width: f32, height: f32, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    rvn_paint_image(p, base.rvn_rect(x, y, width, height), texture, null, base.rvn_rgba(r, g, b, a), 0.0);
}

export fn Rdraw_text(painter: ?*raven.RPainter, font: raven.Rid, size: f32, x: f32, y: f32, text: [*c]const u8, r: f32, g: f32, b: f32, a: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    var metrics: font_h.rvn_font_metrics_t = undefined;
    var y_ = y;
    var line: [*c]const u8 = text;
    if (p == null or text == null) return;
    const resolved = font_h.rvn_font_resolve(font);
    if (resolved == null) return;
    const size_ = font_h.rvn_font_size_resolve(size);
    font_h.rvn_font_metrics(resolved, size_, &metrics);
    while (true) {
        const newline: [*c]const u8 = libc.strchr(line, '\n');
        const length: c_int = if (newline != null) @intCast(newline - line) else @intCast(libc.strlen(line));
        rvn_paint_text(p, font, size_, x, y_, line, length, base.rvn_rgba(r, g, b, a));
        if (newline == null) break;
        line = newline + 1;
        y_ += metrics.line_height;
    }
}

export fn Rdraw_push_clip_rect(painter: ?*raven.RPainter, x: f32, y: f32, width: f32, height: f32) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    rvn_paint_push_clip(p, base.rvn_rect(x, y, width, height));
}

export fn Rdraw_pop_clip_rect(painter: ?*raven.RPainter) void {
    const p: [*c]draw_h.RPainter = @ptrCast(@alignCast(painter));
    if (p == null) return;
    rvn_paint_pop_clip(p);
}
