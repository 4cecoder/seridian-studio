// Translated to Zig from vendor/raven/examples/memory/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - memory
// Where the memory of the library comes from, and how to watch it.
//
// Raven never calls malloc: it has its own allocator (regions of 4 MB from
// the system, handed out by a TLSF heap). An application can give its own
// instead with Rset_allocator, before Rinit: an engine that tracks every
// block, a memory budget, a debugging tool. This example gives one that
// counts, and shows next to it what the library reports about itself
// (Rmemory_get_stats).
//
//   raven_memory            the counting allocator of this file
//   raven_memory --raven    the allocator of Raven

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const example = @import("example");

pub const panic = example.panic;

// ---------------------------------------------------------------------------
//  An allocator of the application: malloc, counted
//
//  The functions are called from several threads (the render thread, the
//  worker threads): the counters are only touched under a lock. Each block
//  remembers its size in a header of 16 bytes, which also keeps the
//  alignment the library asks for.
// -------------------------------------------------------------------------

const counter_t = extern struct {
    blocks: usize,
    bytes: usize,
    calls: usize,
    lock: c_int,
};

var g_counter: counter_t = std.mem.zeroes(counter_t);

// #if defined(_MSC_VER): _InterlockedExchange (a full barrier); otherwise __sync_lock_test_and_set
// (an acquire barrier) and __sync_lock_release (a release barrier).
inline fn LOCK(counter: [*c]counter_t) void {
    if (builtin.abi == .msvc) {
        while (@atomicRmw(c_int, &counter.*.lock, .Xchg, 1, .seq_cst) != 0) {}
    } else {
        while (@atomicRmw(c_int, &counter.*.lock, .Xchg, 1, .acquire) != 0) {}
    }
}
inline fn UNLOCK(counter: [*c]counter_t) void {
    if (builtin.abi == .msvc) {
        _ = @atomicRmw(c_int, &counter.*.lock, .Xchg, 0, .seq_cst);
    } else {
        @atomicStore(c_int, &counter.*.lock, 0, .release);
    }
}

const HEADER = 16;

fn counted_alloc(size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const counter: [*c]counter_t = @ptrCast(@alignCast(user_data));
    const block: [*c]usize = @ptrCast(@alignCast(example.malloc(size + HEADER)));
    if (block == null) return null;
    block[0] = size;
    LOCK(counter);
    counter.*.blocks += 1;
    counter.*.bytes += size;
    counter.*.calls += 1;
    UNLOCK(counter);
    return @as([*c]u8, @ptrCast(block)) + HEADER;
}

fn counted_free(ptr: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const counter: [*c]counter_t = @ptrCast(@alignCast(user_data));
    var block: [*c]usize = undefined;
    if (ptr == null) return;
    block = @ptrCast(@alignCast(@as([*c]u8, @ptrCast(ptr)) - HEADER));
    LOCK(counter);
    counter.*.blocks -= 1;
    counter.*.bytes -= block[0];
    UNLOCK(counter);
    example.free(block);
}

fn counted_realloc(ptr: ?*anyopaque, size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    const counter: [*c]counter_t = @ptrCast(@alignCast(user_data));
    var block: [*c]usize = undefined;
    var old_size: usize = undefined;
    if (ptr == null) return counted_alloc(size, user_data);
    block = @ptrCast(@alignCast(@as([*c]u8, @ptrCast(ptr)) - HEADER));
    old_size = block[0];
    block = @ptrCast(@alignCast(example.realloc(block, size + HEADER)));
    if (block == null) return null;
    block[0] = size;
    LOCK(counter);
    counter.*.bytes += size;
    counter.*.bytes -= old_size;
    counter.*.calls += 1;
    UNLOCK(counter);
    return @as([*c]u8, @ptrCast(block)) + HEADER;
}

// ---------------------------------------------------------------------------
//  The window
// -------------------------------------------------------------------------

var app = std.mem.zeroes(struct {
    window: raven.Rid,
    grid: raven.Rid,
    ours: raven.Rid,
    theirs: raven.Rid,
    check: raven.Rid,
    custom: c_int,
});

fn refresh(timer: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    var stats: raven.RMemoryStats = undefined;
    var text: [256]u8 = undefined;
    _ = timer;
    _ = user_data;
    if (raven.Rwidget_is_valid(app.theirs) == 0) return;
    raven.Rmemory_get_stats(&stats);
    _ = example.snprintf(&text, text.len, "Rmemory_get_stats: %u blocks, %.1f KB in use, peak %.1f KB, %.1f MB taken from the system", //
        @as(c_uint, @truncate(stats.allocation_count)), @as(f64, @floatFromInt(stats.used_bytes)) / 1024.0, @as(f64, @floatFromInt(stats.peak_bytes)) / 1024.0, //
        @as(f64, @floatFromInt(stats.reserved_bytes)) / (1024.0 * 1024.0));
    raven.Rlabel_set_text(app.theirs, &text);
    if (app.custom != 0) {
        var blocks: usize = undefined;
        var bytes: usize = undefined;
        var calls: usize = undefined;
        LOCK(&g_counter);
        blocks = g_counter.blocks;
        bytes = g_counter.bytes;
        calls = g_counter.calls;
        UNLOCK(&g_counter);
        _ = example.snprintf(&text, text.len, "Our allocator: %u blocks, %.1f KB, %u allocations so far", //
            @as(c_uint, @truncate(blocks)), @as(f64, @floatFromInt(bytes)) / 1024.0, @as(c_uint, @truncate(calls)));
    } else {
        _ = example.snprintf(&text, text.len, "The allocator of Raven is in use (started with --raven).");
    }
    raven.Rlabel_set_text(app.ours, &text);
}

fn on_add(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    var i: c_int = undefined;
    _ = button;
    _ = user_data;
    i = 0;
    while (i < 200) : (i += 1) {
        var text: [16]u8 = undefined;
        _ = example.snprintf(&text, text.len, "%d", raven.Rwidget_get_child_count(app.grid) + 1);
        _ = raven.Rwidget_add_child(app.grid, raven.Rbutton_create(&text));
    }
    refresh(raven.R_INVALID_ID, null);
}

fn on_clear(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    raven.Rwidget_clear_children(app.grid);
    // gives back to the system the regions that are now empty
    raven.Rmemory_trim();
    refresh(raven.R_INVALID_ID, null);
}

fn on_check(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    _ = user_data;
    // walks the heap of Raven and verifies every block; with another allocator there is nothing to walk
    raven.Rlabel_set_text(app.check, @as([*c]const u8, if (raven.Rmemory_check() != 0) "Rmemory_check: the heap is consistent." else "Rmemory_check: the heap is damaged!"));
}

export fn main(argc: c_int, argv: [*c][*c]u8) c_int {
    var allocator: raven.RAllocator = undefined;
    var box: raven.Rid = undefined;
    var row: raven.Rid = undefined;
    var scroll: raven.Rid = undefined;
    var button: raven.Rid = undefined;

    app.custom = @intFromBool(!(argc > 1 and example.strcmp(argv[1], "--raven") == 0));
    if (app.custom != 0) {
        // before Rinit, and before anything else of the library that allocates
        allocator.alloc = counted_alloc;
        allocator.realloc = counted_realloc;
        allocator.free = counted_free;
        allocator.user_data = &g_counter;
        raven.Rset_allocator(&allocator);
    }
    if (example.example_init("memory") == 0) return 1;

    app.window = raven.Rwindow_create("Raven - memory", 720, 460, raven.R_WINDOW_DEFAULT);
    box = raven.Rwidget_create(raven.R_WIDGET_VBOX);
    raven.Rpanel_set_spacing(box, 10.0);
    raven.Rwindow_set_content(app.window, box);
    raven.Rslot_set_padding(box, 16.0, 16.0, 16.0, 16.0);

    app.ours = raven.Rwidget_add_child(box, raven.Rlabel_create(""));
    app.theirs = raven.Rwidget_add_child(box, raven.Rlabel_create(""));
    app.check = raven.Rwidget_add_child(box, raven.Rlabel_create(""));
    raven.Rwidget_set_opacity(app.check, 0.7);

    row = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_HBOX));
    raven.Rpanel_set_spacing(row, 8.0);
    button = raven.Rwidget_add_child(row, raven.Rbutton_create("Add 200 buttons"));
    raven.Rbutton_set_style(button, raven.R_BUTTON_PRIMARY);
    raven.Rbutton_set_clicked_callback(button, on_add, null);
    raven.Rbutton_set_clicked_callback(raven.Rwidget_add_child(row, raven.Rbutton_create("Remove them")), on_clear, null);
    raven.Rbutton_set_clicked_callback(raven.Rwidget_add_child(row, raven.Rbutton_create("Check the heap")), on_check, null);

    scroll = raven.Rwidget_add_child(box, raven.Rwidget_create(raven.R_WIDGET_SCROLL_BOX));
    raven.Rslot_set_fill(scroll, 1.0);
    app.grid = raven.Rwidget_add_child(scroll, raven.Rwidget_create(raven.R_WIDGET_WRAP_BOX));
    raven.Rpanel_set_spacing(app.grid, 4.0);

    on_add(raven.R_INVALID_ID, null);
    _ = raven.Rtimer_create(0.5, raven.R_TRUE, refresh, null);

    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }
    raven.Rshutdown();
    if (app.custom != 0) {
        // what an application checks at exit: everything the library took, it gave back
        _ = example.printf("blocks still allocated after Rshutdown: %u\n", @as(c_uint, @truncate(g_counter.blocks)));
        return if (g_counter.blocks == 0) 0 else 1;
    }
    return 0;
}
