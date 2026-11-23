// Translated to Zig from vendor/raven/src/widgets/grid.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/grid.c
// Grid (Slate SGridPanel): rows and columns sized to their content, with
// spans and fill coefficients, and UniformGrid (SUniformGridPanel) where all
// cells share one size.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const common = @import("common_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

// ===========================================================================
//  Grid
// ===========================================================================

const rvn_grid_t = extern struct {
    base: widget_h.rvn_widget_t,
    spacing: f32,
    /// Fill coefficient per column / row; 0 = sized to content.
    column_fill: [*c]f32,
    column_fill_count: u32,
    column_fill_cap: u32,
    row_fill: [*c]f32,
    row_fill_count: u32,
    row_fill_cap: u32,
    /// Track sizes computed by the last measure, then stretched by arrange.
    column_size: [*c]f32,
    row_size: [*c]f32,
    track_cap: u32,
    columns: u32,
    rows: u32,
};

fn rvn_grid_destroy(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const grid: [*c]rvn_grid_t = @ptrCast(widget);
    base.rvn_free(grid.*.column_fill);
    base.rvn_free(grid.*.row_fill);
    base.rvn_free(grid.*.column_size);
    base.rvn_free(grid.*.row_size);
}

// Makes the tracks covered by a spanning child large enough for it.
fn rvn_grid_fit_span(sizes: [*c]f32, first: u32, span: u32, spacing: f32, needed: f32) void {
    var total: f32 = spacing * @as(f32, @floatFromInt(span - 1));
    var i: u32 = 0;
    while (i < span) : (i += 1) total += sizes[first + i];
    // the missing space goes to the last track of the span
    if (needed > total) sizes[first + span - 1] += needed - total;
}

// Natural size of every column and row, from the desired sizes of the children.
fn rvn_grid_compute_tracks(grid: [*c]rvn_grid_t) void {
    const widget: [*c]widget_h.rvn_widget_t = &grid.*.base;
    var i: u32 = 0;
    var columns: u32 = 0;
    var rows: u32 = 0;

    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        columns = base.rvn_maxu(columns, @as(u32, @bitCast(child.*.slot.column + child.*.slot.column_span)));
        rows = base.rvn_maxu(rows, @as(u32, @bitCast(child.*.slot.row + child.*.slot.row_span)));
    }
    grid.*.columns = columns;
    grid.*.rows = rows;
    const needed = base.rvn_maxu(columns, rows);
    if (needed > grid.*.track_cap) {
        grid.*.column_size = @ptrCast(@alignCast(base.rvn_realloc(grid.*.column_size, @sizeOf(f32) * @as(usize, needed))));
        grid.*.row_size = @ptrCast(@alignCast(base.rvn_realloc(grid.*.row_size, @sizeOf(f32) * @as(usize, needed))));
        grid.*.track_cap = needed;
    }
    i = 0;
    while (i < columns) : (i += 1) grid.*.column_size[i] = 0.0;
    i = 0;
    while (i < rows) : (i += 1) grid.*.row_size[i] = 0.0;

    // cells of one track first, then the spanning cells
    i = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const size = ext.rvn_widget_measure_slot(child);
        if (child.*.slot.column_span == 1) {
            const column: usize = @intCast(child.*.slot.column);
            grid.*.column_size[column] = base.rvn_maxf(grid.*.column_size[column], size.x);
        }
        if (child.*.slot.row_span == 1) {
            const row: usize = @intCast(child.*.slot.row);
            grid.*.row_size[row] = base.rvn_maxf(grid.*.row_size[row], size.y);
        }
    }
    i = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        if (child.*.slot.column_span == 1 and child.*.slot.row_span == 1) continue;
        const size = ext.rvn_widget_measure_slot(child);
        if (child.*.slot.column_span > 1) {
            rvn_grid_fit_span(grid.*.column_size, @as(u32, @bitCast(child.*.slot.column)), @as(u32, @bitCast(child.*.slot.column_span)), grid.*.spacing, size.x);
        }
        if (child.*.slot.row_span > 1) {
            rvn_grid_fit_span(grid.*.row_size, @as(u32, @bitCast(child.*.slot.row)), @as(u32, @bitCast(child.*.slot.row_span)), grid.*.spacing, size.y);
        }
    }
}

fn rvn_grid_total(sizes: [*c]const f32, count: u32, spacing: f32) f32 {
    var total: f32 = if (count > 1) spacing * @as(f32, @floatFromInt(count - 1)) else 0.0;
    var i: u32 = 0;
    while (i < count) : (i += 1) total += sizes[i];
    return total;
}

fn rvn_grid_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const grid: [*c]rvn_grid_t = @ptrCast(widget);
    rvn_grid_compute_tracks(grid);
    return base.rvn_vec2(
        rvn_grid_total(grid.*.column_size, grid.*.columns, grid.*.spacing),
        rvn_grid_total(grid.*.row_size, grid.*.rows, grid.*.spacing),
    );
}

// Gives the space left over to the tracks that have a fill coefficient.
fn rvn_grid_stretch(sizes: [*c]f32, count: u32, fill: [*c]const f32, fill_count: u32, spacing: f32, available: f32) void {
    const extra = available - rvn_grid_total(sizes, count, spacing);
    var total: f32 = 0.0;
    var i: u32 = 0;
    while (i < count and i < fill_count) : (i += 1) total += fill[i];
    if (extra <= 0.0 or total <= 0.0) return;
    i = 0;
    while (i < count and i < fill_count) : (i += 1) sizes[i] += extra * fill[i] / total;
}

fn rvn_grid_offset(sizes: [*c]const f32, index: u32, spacing: f32) f32 {
    var offset: f32 = 0.0;
    var i: u32 = 0;
    while (i < index) : (i += 1) offset += sizes[i] + spacing;
    return offset;
}

fn rvn_grid_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const grid: [*c]rvn_grid_t = @ptrCast(widget);
    var i: u32 = 0;

    // start again from the natural sizes: the previous arrange stretched them
    rvn_grid_compute_tracks(grid);
    rvn_grid_stretch(grid.*.column_size, grid.*.columns, grid.*.column_fill, grid.*.column_fill_count, grid.*.spacing, widget.*.rect.w);
    rvn_grid_stretch(grid.*.row_size, grid.*.rows, grid.*.row_fill, grid.*.row_fill_count, grid.*.spacing, widget.*.rect.h);

    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        var cell: base.rvn_rect_t = undefined;
        var span: u32 = undefined;
        var k: u32 = undefined;
        const column: u32 = @as(u32, @bitCast(child.*.slot.column));
        const row: u32 = @as(u32, @bitCast(child.*.slot.row));
        cell.x = rvn_grid_offset(grid.*.column_size, column, grid.*.spacing);
        cell.y = rvn_grid_offset(grid.*.row_size, row, grid.*.spacing);
        span = @as(u32, @bitCast(child.*.slot.column_span));
        cell.w = grid.*.spacing * @as(f32, @floatFromInt(span -% 1));
        k = 0;
        while (k < span) : (k += 1) cell.w += grid.*.column_size[column + k];
        span = @as(u32, @bitCast(child.*.slot.row_span));
        cell.h = grid.*.spacing * @as(f32, @floatFromInt(span -% 1));
        k = 0;
        while (k < span) : (k += 1) cell.h += grid.*.row_size[row + k];
        ext.rvn_widget_arrange_slot(child, cell);
    }
}

fn rvn_grid_set_fill(fill: [*c][*c]f32, count: [*c]u32, cap: [*c]u32, index: c_int, coefficient: f32) void {
    var i: u32 = undefined;
    if (index < 0 or index > 4095) return;
    if (@as(u32, @intCast(index)) >= count.*) {
        base.RVN_ARRAY_RESERVE(fill, cap, @as(u32, @intCast(index)) + 1);
        i = count.*;
        while (i <= @as(u32, @intCast(index))) : (i += 1) fill.*[i] = 0.0;
        count.* = @as(u32, @intCast(index)) + 1;
    }
    fill.*[@as(usize, @intCast(index))] = if (coefficient > 0.0) coefficient else 0.0;
}

// "auto,1,2": one entry per track, "auto" or a fill coefficient.
fn rvn_grid_parse_tracks(fill: [*c][*c]f32, count: [*c]u32, cap: [*c]u32, value: [*c]const u8) void {
    var value_: [*c]const u8 = value;
    var index: c_int = 0;
    count.* = 0;
    while (value_[0] != 0) {
        var token: [32]u8 = undefined;
        const length = libc.strcspn(value_, ",");
        var coefficient: f32 = 0.0;
        const copy: usize = if (length < token.len - 1) length else token.len - 1;
        @memcpy(token[0..copy], value_[0..copy]);
        token[copy] = 0;
        if (ext.rvn_parse_float(&token, &coefficient) == 0) coefficient = 0.0;
        rvn_grid_set_fill(fill, count, cap, index, coefficient);
        index += 1;
        value_ += length;
        if (value_[0] == ',') value_ += 1;
    }
}

fn rvn_grid_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const grid: [*c]rvn_grid_t = @ptrCast(widget);
    if (base.rvn_stricmp(name, "Spacing") == 0) {
        if (ext.rvn_parse_float(value, &grid.*.spacing) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Columns") == 0) {
        rvn_grid_parse_tracks(&grid.*.column_fill, &grid.*.column_fill_count, &grid.*.column_fill_cap, value);
    } else if (base.rvn_stricmp(name, "Rows") == 0) {
        rvn_grid_parse_tracks(&grid.*.row_fill, &grid.*.row_fill_count, &grid.*.row_fill_cap, value);
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_grid: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_GRID,
    .name = "Grid",
    .size = @sizeOf(rvn_grid_t),
    .flags = widget_h.RVN_CF_NO_HIT,
    .destroy = rvn_grid_destroy,
    .measure = rvn_grid_measure,
    .arrange = rvn_grid_arrange,
    .set_attribute = rvn_grid_set_attribute,
});

export fn Rgrid_set_column_fill(id: raven.Rid, column: c_int, coefficient: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_GRID, "Rgrid_set_column_fill");
    if (widget == null) return;
    const grid: [*c]rvn_grid_t = @ptrCast(widget);
    rvn_grid_set_fill(&grid.*.column_fill, &grid.*.column_fill_count, &grid.*.column_fill_cap, column, coefficient);
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Rgrid_set_row_fill(id: raven.Rid, row: c_int, coefficient: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_GRID, "Rgrid_set_row_fill");
    if (widget == null) return;
    const grid: [*c]rvn_grid_t = @ptrCast(widget);
    rvn_grid_set_fill(&grid.*.row_fill, &grid.*.row_fill_count, &grid.*.row_fill_cap, row, coefficient);
    ext.rvn_widget_invalidate_layout(widget);
}

// ===========================================================================
//  UniformGrid
// ===========================================================================

const rvn_uniform_grid_t = extern struct {
    base: widget_h.rvn_widget_t,
    spacing: f32,
    /// > 0: children flow in this many columns; 0: each slot gives its cell.
    flow_columns: c_int,
    min_cell: base.rvn_vec2_t,
    cell: base.rvn_vec2_t,
    columns: u32,
    rows: u32,
};

fn rvn_uniform_grid_cell(grid: [*c]const rvn_uniform_grid_t, visible_index: u32, child: [*c]const widget_h.rvn_widget_t, column: [*c]u32, row: [*c]u32) void {
    if (grid.*.flow_columns > 0) {
        column.* = visible_index % @as(u32, @intCast(grid.*.flow_columns));
        row.* = visible_index / @as(u32, @intCast(grid.*.flow_columns));
    } else {
        column.* = @as(u32, @bitCast(child.*.slot.column));
        row.* = @as(u32, @bitCast(child.*.slot.row));
    }
}

fn rvn_uniform_grid_measure(widget: [*c]widget_h.rvn_widget_t) callconv(.c) base.rvn_vec2_t {
    const grid: [*c]rvn_uniform_grid_t = @ptrCast(widget);
    var i: u32 = 0;
    var visible: u32 = 0;

    grid.*.cell = grid.*.min_cell;
    grid.*.columns = 0;
    grid.*.rows = 0;
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        var column: u32 = undefined;
        var row: u32 = undefined;
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        const size = ext.rvn_widget_measure_slot(child);
        grid.*.cell.x = base.rvn_maxf(grid.*.cell.x, size.x);
        grid.*.cell.y = base.rvn_maxf(grid.*.cell.y, size.y);
        rvn_uniform_grid_cell(grid, visible, child, &column, &row);
        visible += 1;
        grid.*.columns = base.rvn_maxu(grid.*.columns, column +% 1);
        grid.*.rows = base.rvn_maxu(grid.*.rows, row +% 1);
    }
    if (grid.*.columns == 0) return base.rvn_vec2(0.0, 0.0);
    return base.rvn_vec2(
        grid.*.cell.x * @as(f32, @floatFromInt(grid.*.columns)) + grid.*.spacing * @as(f32, @floatFromInt(grid.*.columns - 1)),
        grid.*.cell.y * @as(f32, @floatFromInt(grid.*.rows)) + grid.*.spacing * @as(f32, @floatFromInt(grid.*.rows - 1)),
    );
}

fn rvn_uniform_grid_arrange(widget: [*c]widget_h.rvn_widget_t) callconv(.c) void {
    const grid: [*c]rvn_uniform_grid_t = @ptrCast(widget);
    var i: u32 = 0;
    var visible: u32 = 0;

    if (grid.*.columns == 0 or grid.*.rows == 0) return;
    // the cells share the whole panel equally
    const cell_w = (widget.*.rect.w - grid.*.spacing * @as(f32, @floatFromInt(grid.*.columns - 1))) / @as(f32, @floatFromInt(grid.*.columns));
    const cell_h = (widget.*.rect.h - grid.*.spacing * @as(f32, @floatFromInt(grid.*.rows - 1))) / @as(f32, @floatFromInt(grid.*.rows));
    while (i < widget.*.child_count) : (i += 1) {
        const child = widget.*.children[i];
        var column: u32 = undefined;
        var row: u32 = undefined;
        if (widget_h.rvn_widget_collapsed(child) != 0) continue;
        rvn_uniform_grid_cell(grid, visible, child, &column, &row);
        visible += 1;
        ext.rvn_widget_arrange_slot(child, base.rvn_rect(
            (cell_w + grid.*.spacing) * @as(f32, @floatFromInt(column)),
            (cell_h + grid.*.spacing) * @as(f32, @floatFromInt(row)),
            base.rvn_maxf(cell_w, 0.0),
            base.rvn_maxf(cell_h, 0.0),
        ));
    }
}

fn rvn_uniform_grid_set_attribute(widget: [*c]widget_h.rvn_widget_t, name: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
    const grid: [*c]rvn_uniform_grid_t = @ptrCast(widget);
    var values: [2]f32 = undefined;
    if (base.rvn_stricmp(name, "Spacing") == 0) {
        if (ext.rvn_parse_float(value, &grid.*.spacing) == 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "Columns") == 0) {
        if (ext.rvn_parse_int(value, &grid.*.flow_columns) == 0 or grid.*.flow_columns < 0) return raven.R_FALSE;
    } else if (base.rvn_stricmp(name, "MinCellSize") == 0) {
        const count = ext.rvn_parse_floats(value, &values, 2);
        if (count < 1) return raven.R_FALSE;
        grid.*.min_cell = base.rvn_vec2(values[0], if (count > 1) values[1] else values[0]);
    } else {
        return raven.R_FALSE;
    }
    ext.rvn_widget_invalidate_layout(widget);
    return raven.R_TRUE;
}

export const rvn_class_uniform_grid: common.rvn_widget_class_t = std.mem.zeroInit(common.rvn_widget_class_t, .{
    .@"type" = raven.R_WIDGET_UNIFORM_GRID,
    .name = "UniformGrid",
    .size = @sizeOf(rvn_uniform_grid_t),
    .flags = widget_h.RVN_CF_NO_HIT,
    .measure = rvn_uniform_grid_measure,
    .arrange = rvn_uniform_grid_arrange,
    .set_attribute = rvn_uniform_grid_set_attribute,
});

export fn Runiform_grid_set_columns(id: raven.Rid, columns: c_int) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_UNIFORM_GRID, "Runiform_grid_set_columns");
    if (widget == null) return;
    const grid: [*c]rvn_uniform_grid_t = @ptrCast(widget);
    grid.*.flow_columns = if (columns > 0) columns else 0;
    ext.rvn_widget_invalidate_layout(widget);
}

export fn Runiform_grid_set_min_cell_size(id: raven.Rid, width: f32, height: f32) void {
    const widget = widget_h.rvn_widget_check(id, raven.R_WIDGET_UNIFORM_GRID, "Runiform_grid_set_min_cell_size");
    if (widget == null) return;
    const grid: [*c]rvn_uniform_grid_t = @ptrCast(widget);
    grid.*.min_cell = base.rvn_vec2(base.rvn_maxf(width, 0.0), base.rvn_maxf(height, 0.0));
    ext.rvn_widget_invalidate_layout(widget);
}
