// Translated to Zig from vendor/raven/tests/test_memory.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven tests - the allocator of the library (core/heap.c) and the
// replacement of it by the functions of the application.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const t = @import("test.zig");

pub const panic = t.panic;

// <stdlib.h>
extern "c" fn setenv(name: [*c]const u8, value: [*c]const u8, overwrite: c_int) c_int;
extern "c" fn _putenv(envstring: [*c]const u8) c_int;

// The heap is tested for itself here, even in a build where the C runtime is
// the default (AddressSanitizer).
fn use_raven_heap() void {
    if (builtin.os.tag == .windows) {
        _ = _putenv("RAVEN_ALLOCATOR=raven");
    } else {
        _ = setenv("RAVEN_ALLOCATOR", "raven", 1);
    }
}

// ---------------------------------------------------------------------------
//  Random allocations
// -------------------------------------------------------------------------

var g_seed: u32 = 0x2545F491;

fn next_random() u32 {
    g_seed ^= g_seed << 13;
    g_seed ^= g_seed >> 17;
    g_seed ^= g_seed << 5;
    return g_seed;
}

/// Mostly small blocks, some of a few kilobytes, a few of several megabytes.
fn random_size() usize {
    const kind: u32 = next_random() % 1000;
    if (kind < 700) return 1 + next_random() % 256;
    if (kind < 930) return 1 + next_random() % 4096;
    if (kind < 996) return 1 + next_random() % (128 * 1024);
    if (kind < 999) return 512 * 1024 + next_random() % (1024 * 1024);
    return 1024 * 1024 + next_random() % (3 * 1024 * 1024);
}

const Slot = extern struct {
    data: [*c]u8,
    size: usize,
    pattern: u8,
};

fn fill(slot: [*c]Slot) void {
    @memset(slot.*.data[0..slot.*.size], slot.*.pattern);
}

/// The content of a block is intact: no other block was laid over it.
fn intact(slot: [*c]const Slot, size: usize) c_int {
    var i: usize = undefined;
    i = 0;
    while (i < size) : (i += 1) {
        if (slot.*.data[i] != slot.*.pattern) return 0;
    }
    return 1;
}

const SLOT_COUNT = 3000;
var g_slots: [SLOT_COUNT]Slot = std.mem.zeroes([SLOT_COUNT]Slot);

fn test_random() void {
    var before: raven.RMemoryStats = undefined;
    var stats: raven.RMemoryStats = undefined;
    var step: c_int = undefined;
    var damaged: c_int = 0;
    var misaligned: c_int = 0;
    var i: usize = undefined;

    raven.Rmemory_get_stats(&before);
    step = 0;
    while (step < 200000) : (step += 1) {
        const slot: [*c]Slot = &g_slots[next_random() % SLOT_COUNT];
        const action: u32 = next_random() % 10;
        if (slot.*.data == null) {
            slot.*.size = random_size();
            slot.*.pattern = @truncate(next_random());
            slot.*.data = @ptrCast(raven.Rmemory_alloc(slot.*.size));
            if ((@intFromPtr(slot.*.data) & 15) != 0) misaligned += 1;
            fill(slot);
        } else if (action < 4) {
            // resize: what fits in both sizes is kept
            const size: usize = random_size();
            if (intact(slot, slot.*.size) == 0) damaged += 1;
            slot.*.data = @ptrCast(raven.Rmemory_realloc(slot.*.data, size));
            if ((@intFromPtr(slot.*.data) & 15) != 0) misaligned += 1;
            if (intact(slot, if (size < slot.*.size) size else slot.*.size) == 0) damaged += 1;
            slot.*.size = size;
            fill(slot);
        } else {
            if (intact(slot, slot.*.size) == 0) damaged += 1;
            raven.Rmemory_free(slot.*.data);
            slot.*.data = null;
        }
        if (@rem(step, 20000) == 0) t.CHECK(@src(), raven.Rmemory_check() != 0, "Rmemory_check()");
    }
    t.CHECK(@src(), damaged == 0, "damaged == 0");
    t.CHECK(@src(), misaligned == 0, "misaligned == 0");
    t.CHECK(@src(), raven.Rmemory_check() != 0, "Rmemory_check()");

    raven.Rmemory_get_stats(&stats);
    t.CHECK(@src(), stats.allocation_count > before.allocation_count, "stats.allocation_count > before.allocation_count");
    t.CHECK(@src(), stats.used_bytes > before.used_bytes and stats.reserved_bytes >= stats.used_bytes, "stats.used_bytes > before.used_bytes && stats.reserved_bytes >= stats.used_bytes");
    t.CHECK(@src(), stats.peak_bytes >= stats.used_bytes, "stats.peak_bytes >= stats.used_bytes");
    _ = t.printf("  %u blocks alive, %.1f MB used, %.1f MB taken from the OS, peak %.1f MB\n", @as(c_uint, @truncate(stats.allocation_count)), //
        @as(f64, @floatFromInt(stats.used_bytes)) / 1048576.0, @as(f64, @floatFromInt(stats.reserved_bytes)) / 1048576.0, @as(f64, @floatFromInt(stats.peak_bytes)) / 1048576.0);

    i = 0;
    while (i < SLOT_COUNT) : (i += 1) {
        if (g_slots[i].data != null and intact(&g_slots[i], g_slots[i].size) == 0) damaged += 1;
        raven.Rmemory_free(g_slots[i].data);
        g_slots[i].data = null;
    }
    t.CHECK(@src(), damaged == 0, "damaged == 0");
    t.CHECK(@src(), raven.Rmemory_check() != 0, "Rmemory_check()");

    // everything was freed: the counters are back, and so is the memory of the OS
    raven.Rmemory_get_stats(&stats);
    t.CHECK(@src(), stats.allocation_count == before.allocation_count, "stats.allocation_count == before.allocation_count");
    t.CHECK(@src(), stats.used_bytes == before.used_bytes, "stats.used_bytes == before.used_bytes");
    raven.Rmemory_trim();
    raven.Rmemory_get_stats(&stats);
    t.CHECK(@src(), stats.reserved_bytes <= before.reserved_bytes, "stats.reserved_bytes <= before.reserved_bytes");
}

fn test_edges() void {
    var a: [*c]u8 = undefined;
    var b: [*c]u8 = undefined;
    var c: [*c]u8 = undefined;
    var i: usize = undefined;

    // a size of zero gives a valid block
    a = @ptrCast(raven.Rmemory_alloc(0));
    t.CHECK(@src(), a != null, "a != NULL");
    raven.Rmemory_free(a);
    raven.Rmemory_free(null);

    // growing in place: the neighbour is free
    a = @ptrCast(raven.Rmemory_alloc(100));
    b = @ptrCast(raven.Rmemory_alloc(100));
    @memset(a[0..100], 'a');
    raven.Rmemory_free(b);
    c = @ptrCast(raven.Rmemory_realloc(a, 180));
    t.CHECK(@src(), c == a, "c == a");
    i = 0;
    while (i < 100) : (i += 1) {
        if (c[i] != 'a') break;
    }
    t.CHECK(@src(), i == 100, "i == 100");
    // shrinking never moves
    a = @ptrCast(raven.Rmemory_realloc(c, 10));
    t.CHECK(@src(), a == c, "a == c");
    t.CHECK(@src(), a[9] == 'a', "a[9] == 'a'");
    // a NULL block is allocated
    b = @ptrCast(raven.Rmemory_realloc(null, 50));
    t.CHECK(@src(), b != null, "b != NULL");
    raven.Rmemory_free(a);
    raven.Rmemory_free(b);

    // a block of several megabytes, grown and shrunk
    a = @ptrCast(raven.Rmemory_alloc(@as(c_uint, 5) << 20));
    @memset(a[0 .. @as(c_uint, 5) << 20], 'x');
    a = @ptrCast(raven.Rmemory_realloc(a, @as(c_uint, 9) << 20));
    t.CHECK(@src(), a[0] == 'x' and a[(@as(c_uint, 5) << 20) - 1] == 'x', "a[0] == 'x' && a[(5u << 20) - 1] == 'x'");
    a[(@as(c_uint, 9) << 20) - 1] = 'y';
    a = @ptrCast(raven.Rmemory_realloc(a, 64));
    t.CHECK(@src(), a[0] == 'x' and a[63] == 'x', "a[0] == 'x' && a[63] == 'x'");
    raven.Rmemory_free(a);
    t.CHECK(@src(), raven.Rmemory_check() != 0, "Rmemory_check()");
}

// ---------------------------------------------------------------------------
//  Several threads
// -------------------------------------------------------------------------

fn thread_work(begin: raven.Ruint, end: raven.Ruint, user_data: ?*anyopaque) callconv(.c) void {
    var seed: u32 = 0x9E3779B9 *% (begin +% 1);
    var blocks: [64]?*anyopaque = undefined;
    var sizes: [64]usize = undefined;
    var i: raven.Ruint = undefined;
    var k: c_int = undefined;
    const damaged: [*c]c_int = @ptrCast(@alignCast(user_data));

    @memset(std.mem.asBytes(&blocks), 0);
    i = begin;
    while (i < end) : (i += 1) {
        k = 0;
        while (k < 400) : (k += 1) {
            var slot: u32 = undefined;
            seed = seed *% 1664525 +% 1013904223;
            slot = (seed >> 8) % 64;
            if (blocks[slot] != null) {
                const bytes: [*c]const u8 = @ptrCast(blocks[slot]);
                if (bytes[0] != @as(u8, @truncate(slot)) or bytes[sizes[slot] - 1] != @as(u8, @truncate(slot))) damaged.* = 1;
                raven.Rmemory_free(blocks[slot]);
                blocks[slot] = null;
            } else {
                sizes[slot] = 1 + (seed >> 16) % 3000;
                blocks[slot] = raven.Rmemory_alloc(sizes[slot]);
                // memset(blocks[slot], (int)slot, sizes[slot]): memset stores (unsigned char)slot
                @memset(@as([*c]u8, @ptrCast(blocks[slot]))[0..sizes[slot]], @as(u8, @truncate(slot)));
            }
        }
    }
    k = 0;
    while (k < 64) : (k += 1) raven.Rmemory_free(blocks[@intCast(k)]);
}

fn test_threads() void {
    var damaged: c_int = 0;
    // 64 ranges shared between the worker threads and this one, while the
    // render thread of the library allocates too
    raven.Rparallel_for(64, 1, thread_work, &damaged);
    t.CHECK(@src(), damaged == 0, "!damaged");
    t.CHECK(@src(), raven.Rmemory_check() != 0, "Rmemory_check()");
}

// ---------------------------------------------------------------------------
//  The library on the allocator of the application
// -------------------------------------------------------------------------

// The functions of an allocator are called from several threads (the UI
// thread and the render thread here): the counters are atomic.
// #if defined(_MSC_VER) && !defined(__clang__): `static volatile long` counters and _InterlockedExchangeAdd
// (a sequentially consistent atomic add that returns the old value); otherwise `static int` counters and
// __atomic_add_fetch / __atomic_load_n with __ATOMIC_SEQ_CST. Zig has no _MSC_VER: the MSVC ABI stands for it.
const msvc_counters = builtin.abi == .msvc;
const Counter = if (msvc_counters) c_long else c_int;
var g_my_live: Counter = 0;
var g_my_total: Counter = 0;
// #define COUNT(counter, by)
inline fn COUNT(counter: *Counter, by: Counter) void {
    if (msvc_counters) {
        _ = @atomicRmw(Counter, counter, .Add, by, .seq_cst); // _InterlockedExchangeAdd(&(counter), (by))
    } else {
        _ = @atomicRmw(Counter, counter, .Add, by, .seq_cst) +% by; // __atomic_add_fetch(&(counter), (by), __ATOMIC_SEQ_CST)
    }
}
// #define READ(counter)
inline fn READ(counter: *Counter) c_int {
    if (msvc_counters) {
        return @intCast(@atomicRmw(Counter, counter, .Add, 0, .seq_cst)); // ((int)_InterlockedExchangeAdd(&(counter), 0))
    } else {
        return @atomicLoad(Counter, counter, .seq_cst); // __atomic_load_n(&(counter), __ATOMIC_SEQ_CST)
    }
}

fn my_alloc(size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = user_data;
    COUNT(&g_my_live, 1);
    COUNT(&g_my_total, 1);
    return t.malloc(size);
}

fn my_realloc(ptr: ?*anyopaque, size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = user_data;
    return t.realloc(ptr, size);
}

fn my_free(ptr: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    COUNT(&g_my_live, -1);
    t.free(ptr);
}

fn build_a_window() void {
    const xml =
        "<Window Width=\"400\" Height=\"300\"><VBox>" ++
        "<Label>Text</Label><Button Text=\"Button\"/><TextInput Text=\"abc\"/>" ++
        "<TreeView><Item Text=\"a\"><Item Text=\"b\"/></Item></TreeView>" ++
        "</VBox></Window>";
    // sizeof(xml) - 1: the length of the text without its terminating zero
    const window = raven.Rwindow_create_from_xml(xml, xml.len);
    t.CHECK(@src(), raven.Rwindow_is_valid(window) != 0, "Rwindow_is_valid(window)");
    _ = raven.Rdraw_frame();
}

fn test_library_memory() void {
    var stats: raven.RMemoryStats = undefined;

    // with its own heap: everything is returned at shutdown
    t.CHECK(@src(), t.test_init(2) != 0, "test_init(2)");
    build_a_window();
    raven.Rmemory_get_stats(&stats);
    t.CHECK(@src(), stats.allocation_count > 20 and stats.used_bytes > 10000, "stats.allocation_count > 20 && stats.used_bytes > 10000");
    _ = t.printf("  a small window: %u blocks, %u KB\n", @as(c_uint, @truncate(stats.allocation_count)), @as(c_uint, @truncate(stats.used_bytes / 1024)));
    test_threads();
    // the allocator cannot change under a running library
    t.EXPECT_ERRORS_BEGIN();
    raven.Rset_allocator(raven.Rallocator_get_system());
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");
    raven.Rshutdown();
    raven.Rmemory_get_stats(&stats);
    t.CHECK(@src(), stats.allocation_count == 0, "stats.allocation_count == 0");
    t.CHECK(@src(), stats.used_bytes == 0, "stats.used_bytes == 0");
    t.CHECK(@src(), stats.reserved_bytes == 0, "stats.reserved_bytes == 0");
}

fn test_custom_allocator() void {
    var allocator: raven.RAllocator = undefined;
    var stats: raven.RMemoryStats = undefined;

    allocator.alloc = my_alloc;
    allocator.realloc = my_realloc;
    allocator.free = my_free;
    allocator.user_data = null;
    raven.Rset_allocator(&allocator);

    t.CHECK(@src(), t.test_init(-1) != 0, "test_init(-1)");
    build_a_window();
    t.CHECK(@src(), READ(&g_my_live) > 20, "READ(g_my_live) > 20");
    raven.Rmemory_get_stats(&stats);
    // the heap of Raven is not used at all
    t.CHECK(@src(), stats.reserved_bytes == 0 and stats.used_bytes == 0, "stats.reserved_bytes == 0 && stats.used_bytes == 0");
    t.CHECK(@src(), stats.allocation_count > 20, "stats.allocation_count > 20");
    raven.Rshutdown();
    t.CHECK(@src(), READ(&g_my_live) == 0, "READ(g_my_live) == 0");
    t.CHECK(@src(), READ(&g_my_total) > 20, "READ(g_my_total) > 20");

    // incomplete: refused
    allocator.free = null;
    t.EXPECT_ERRORS_BEGIN();
    raven.Rset_allocator(&allocator);
    t.EXPECT_ERRORS_END(@src(), 1, "g_test_errors >= (1)");

    // the C runtime, then Raven again
    raven.Rset_allocator(raven.Rallocator_get_system());
    t.CHECK(@src(), t.test_init(-1) != 0, "test_init(-1)");
    build_a_window();
    raven.Rshutdown();
    raven.Rset_allocator(null);
    t.CHECK(@src(), t.test_init(-1) != 0, "test_init(-1)");
    build_a_window();
    raven.Rmemory_get_stats(&stats);
    t.CHECK(@src(), stats.used_bytes > 10000, "stats.used_bytes > 10000");
    raven.Rshutdown();
}

export fn main() c_int {
    use_raven_heap();
    raven.Rerror_set_callback(t.test_error_callback);

    t.RUN(test_edges, "test_edges");
    t.RUN(test_random, "test_random");
    t.RUN(test_library_memory, "test_library_memory");
    t.RUN(test_custom_allocator, "test_custom_allocator");

    return t.test_report("test_memory");
}
