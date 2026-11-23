// Translated to Zig from vendor/raven/src/core/heap.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/heap.c
// The allocator of the library.
//
// Memory comes from the OS in regions of 4 MB (mmap / VirtualAlloc) and is
// handed out by a TLSF heap ("two-level segregated fit", Masmano et al.):
//
//   - every block has a 16-byte header: the block before it in the region
//     and its size. Two neighbours that are free are always merged, so the
//     heap does not crumble into small pieces over time;
//   - free blocks are sorted by size into 23 x 32 lists (powers of two, each
//     divided in 32 steps). Two bitmaps tell which lists are not empty, so
//     finding a block of a given size is two bit scans: allocating and
//     freeing take a constant time whatever the state of the heap;
//   - a request is rounded up by 3 % at most to find its list.
//
// Requests of 1 MB and more (pixel buffers, large draw lists) go straight
// to the OS and return to it when they are freed. A region that becomes
// empty returns to the OS as well, except one that is kept for the next
// allocations.
//
// One lock protects the heap. It is a spin lock: the UI thread makes nearly
// all the allocations, and the critical sections are a few dozen instructions.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("base_h.zig");
const thread = @import("thread_h.zig");
const libc = @import("../sys/libc.zig");

// ---------------------------------------------------------------------------
//  OS interface (#if defined(_WIN32) / #elif defined(__unix__) || defined(__APPLE__))
// ---------------------------------------------------------------------------

// Windows: VirtualAlloc / VirtualFree, declared by hand (windows.h is not included).
const MEM_RESERVE: u32 = 0x00002000;
const MEM_COMMIT: u32 = 0x00001000;
const MEM_RELEASE: u32 = 0x00008000;
const PAGE_READWRITE: u32 = 0x04;
extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, allocation_type: u32, protect: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualFree(addr: ?*anyopaque, size: usize, free_type: u32) callconv(.winapi) c_int;

// Unix: mmap / munmap. The constants are the ones of the OS the library is built for.
const RVN_HEAP_MMAP = builtin.os.tag != .windows and builtin.os.tag != .wasi and builtin.os.tag != .freestanding;
const PROT_READ: c_int = 0x1;
const PROT_WRITE: c_int = 0x2;
const MAP_PRIVATE: c_int = 0x02;
const MAP_ANONYMOUS: c_int = switch (builtin.os.tag) {
    .linux => 0x20,
    .illumos => 0x100,
    else => 0x1000,
};
/// (void*)-1
const MAP_FAILED: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

// ---------------------------------------------------------------------------
//  Layout
// ---------------------------------------------------------------------------

const RVN_HEAP_ALIGN: usize = 16;
/// Bytes between the start of a block and its payload.
const RVN_HEAP_HEADER: usize = 16;
/// A free block keeps its two list links in its payload.
const RVN_HEAP_MIN_PAYLOAD: usize = 16;

const RVN_SL_LOG2 = 5;
const RVN_SL_COUNT = 1 << RVN_SL_LOG2;
/// Below 2^9 = 512 bytes, the lists are 16 bytes apart.
const RVN_FL_SHIFT = RVN_SL_LOG2 + 4;
const RVN_SMALL_SIZE: usize = 1 << RVN_FL_SHIFT;
/// Blocks are smaller than 2^31 bytes.
const RVN_FL_MAX = 31;
const RVN_FL_COUNT = RVN_FL_MAX - RVN_FL_SHIFT + 1;

/// Larger requests are refused: they could not be rounded up without overflowing.
const RVN_HEAP_MAX_REQUEST: usize = std.math.maxInt(usize) / 2;

const RVN_REGION_SIZE: usize = 4 << 20;
const RVN_HUGE_SIZE: usize = 1 << 20;

const RVN_BLOCK_FREE: usize = 1;
const RVN_BLOCK_HUGE: usize = 2;
const RVN_BLOCK_FLAGS: usize = 15;

const rvn_block_t = extern struct {
    /// The block before this one in its region, NULL for the first. For a huge block: bytes taken from the OS.
    u: extern union {
        prev_phys: [*c]rvn_block_t,
        os_size: usize,
        /// keeps the payload on 16 bytes where pointers are 4 bytes
        align_: [8]u8,
    },
    /// Bytes of payload, a multiple of 16, with the flags in the low bits.
    s: extern union {
        size: usize,
        align_: [8]u8,
    },
    /// the payload starts here; while the block is free it holds the links of its list
    next_free: [*c]rvn_block_t,
    prev_free: [*c]rvn_block_t,
};

/// Start of the memory taken from the OS; the first block follows.
const rvn_region_t = extern struct {
    next: [*c]rvn_region_t,
    prev: [*c]rvn_region_t,
    os_size: usize,
    align_: [32 - 2 * @sizeOf(?*anyopaque) - @sizeOf(usize)]u8,
};

// the layout above is what the code below relies on
comptime {
    if (@offsetOf(rvn_block_t, "next_free") != 16) @compileError("heap: rvn_block_t next_free must be at offset 16");
    if (@sizeOf(rvn_region_t) != 32) @compileError("heap: rvn_region_t must be 32 bytes");
}

const HeapState = extern struct {
    lock: thread.rvn_atomic_t,
    fl_bitmap: u32,
    sl_bitmap: [RVN_FL_COUNT]u32,
    lists: [RVN_FL_COUNT][RVN_SL_COUNT][*c]rvn_block_t,
    regions: [*c]rvn_region_t,
    /// Regions that hold no allocation (at most one is kept).
    empty_regions: c_int,
    stats: raven.RMemoryStats,
};

var g_heap: HeapState = std.mem.zeroes(HeapState);

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

fn rvn_heap_lock() void {
    var spins: c_int = 0;
    while (thread.rvn_atomic_exchange(&g_heap.lock, 1) != 0) {
        // the owner is a few instructions from the end: only yield when it was preempted
        spins += 1;
        if (spins > 200) {
            thread.rvn_sleep_ms(0);
            spins = 0;
        }
    }
}

fn rvn_heap_unlock() void {
    thread.rvn_atomic_store(&g_heap.lock, 0);
}

/// Index of the highest bit set; `value` is not 0.
fn rvn_fls(value: usize) c_int {
    return @as(c_int, 63) - @as(c_int, @clz(@as(u64, @intCast(value))));
}

/// Index of the lowest bit set; `value` is not 0.
fn rvn_ffs(value: u32) c_int {
    return @as(c_int, @ctz(value));
}

fn rvn_block_size(block: [*c]const rvn_block_t) usize {
    return block.*.s.size & ~RVN_BLOCK_FLAGS;
}

fn rvn_block_is_free(block: [*c]const rvn_block_t) bool {
    return (block.*.s.size & RVN_BLOCK_FREE) != 0;
}

fn rvn_block_payload(block: [*c]rvn_block_t) ?*anyopaque {
    const bytes: [*c]u8 = @ptrCast(block);
    return bytes + RVN_HEAP_HEADER;
}

fn rvn_block_of(ptr: ?*const anyopaque) [*c]rvn_block_t {
    const bytes: [*c]const u8 = @ptrCast(ptr);
    return @ptrCast(@alignCast(@constCast(bytes - RVN_HEAP_HEADER)));
}

/// The block after `block` in its region. The last block of a region is a used block of size 0.
fn rvn_block_next(block: [*c]const rvn_block_t) [*c]rvn_block_t {
    const bytes: [*c]const u8 = @ptrCast(block);
    return @ptrCast(@alignCast(@constCast(bytes + RVN_HEAP_HEADER + rvn_block_size(block))));
}

/// true when the block is the only one of its region: the region holds no allocation.
fn rvn_block_is_whole_region(block: [*c]const rvn_block_t) bool {
    return block.*.u.prev_phys == null and rvn_block_size(rvn_block_next(block)) == 0;
}

fn rvn_heap_round(size_: usize) usize {
    var size = size_;
    if (size < RVN_HEAP_MIN_PAYLOAD) size = RVN_HEAP_MIN_PAYLOAD;
    return (size + RVN_HEAP_ALIGN - 1) & ~(RVN_HEAP_ALIGN - 1);
}

/// The list that holds the free blocks of `size` bytes.
fn rvn_heap_mapping(size: usize, fl: [*c]c_int, sl: [*c]c_int) void {
    if (size < RVN_SMALL_SIZE) {
        fl.* = 0;
        sl.* = @as(c_int, @intCast(size >> 4)); // (int)(size >> 4): below 512 >> 4 = 32, it fits
    } else {
        const high: c_int = rvn_fls(size);
        // (int)(size >> (high - RVN_SL_LOG2)): the shifted value is 32..63, it fits
        sl.* = @as(c_int, @intCast(size >> @intCast(high - RVN_SL_LOG2))) ^ RVN_SL_COUNT;
        fl.* = high - (RVN_FL_SHIFT - 1);
    }
}

fn rvn_heap_insert(block: [*c]rvn_block_t) void {
    var fl: c_int = undefined;
    var sl: c_int = undefined;
    rvn_heap_mapping(rvn_block_size(block), &fl, &sl);
    const head = g_heap.lists[@intCast(fl)][@intCast(sl)];
    block.*.s.size |= RVN_BLOCK_FREE;
    block.*.next_free = head;
    block.*.prev_free = null;
    if (head != null) head.*.prev_free = block;
    g_heap.lists[@intCast(fl)][@intCast(sl)] = block;
    g_heap.fl_bitmap |= @as(u32, 1) << @intCast(fl);
    g_heap.sl_bitmap[@intCast(fl)] |= @as(u32, 1) << @intCast(sl);
}

fn rvn_heap_remove(block: [*c]rvn_block_t) void {
    var fl: c_int = undefined;
    var sl: c_int = undefined;
    rvn_heap_mapping(rvn_block_size(block), &fl, &sl);
    if (block.*.prev_free != null) {
        block.*.prev_free.*.next_free = block.*.next_free;
    } else {
        g_heap.lists[@intCast(fl)][@intCast(sl)] = block.*.next_free;
    }
    if (block.*.next_free != null) block.*.next_free.*.prev_free = block.*.prev_free;
    if (g_heap.lists[@intCast(fl)][@intCast(sl)] == null) {
        g_heap.sl_bitmap[@intCast(fl)] &= ~(@as(u32, 1) << @intCast(sl));
        if (g_heap.sl_bitmap[@intCast(fl)] == 0) g_heap.fl_bitmap &= ~(@as(u32, 1) << @intCast(fl));
    }
    block.*.s.size &= ~RVN_BLOCK_FREE;
}

/// A free block of at least `size` bytes, still in its list, or NULL.
fn rvn_heap_find(size_: usize) [*c]rvn_block_t {
    var size = size_;
    var fl: c_int = undefined;
    var sl: c_int = undefined;
    var map: u32 = undefined;
    // round up to the next list: every block of that list is large enough
    if (size >= RVN_SMALL_SIZE) size += (@as(usize, 1) << @intCast(rvn_fls(size) - RVN_SL_LOG2)) - 1;
    rvn_heap_mapping(size, &fl, &sl);
    if (fl >= RVN_FL_COUNT) return null;
    map = g_heap.sl_bitmap[@intCast(fl)] & (~@as(u32, 0) << @intCast(sl));
    if (map == 0) {
        // nothing in this power of two: take the smallest block of the next one that has some
        const fl_map: u32 = if (fl + 1 < 32) g_heap.fl_bitmap & (~@as(u32, 0) << @intCast(fl + 1)) else 0;
        if (fl_map == 0) return null;
        fl = rvn_ffs(fl_map);
        map = g_heap.sl_bitmap[@intCast(fl)];
    }
    return g_heap.lists[@intCast(fl)][@intCast(rvn_ffs(map))];
}

// ---------------------------------------------------------------------------
//  Memory of the OS
// ---------------------------------------------------------------------------

fn rvn_os_alloc(size: usize) ?*anyopaque {
    if (builtin.os.tag == .windows) {
        return VirtualAlloc(null, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    } else if (RVN_HEAP_MMAP) {
        const memory = libc.mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        return if (memory == MAP_FAILED) null else memory;
    } else {
        return libc.malloc(size);
    }
}

fn rvn_os_free(memory: ?*anyopaque, size: usize) void {
    // RVN_UNUSED(size): VirtualFree and free take no size (on Windows only; the other OS use it)
    _ = if (builtin.os.tag == .windows) size else 0;
    if (builtin.os.tag == .windows) {
        _ = VirtualFree(memory, 0, MEM_RELEASE);
    } else if (RVN_HEAP_MMAP) {
        _ = libc.munmap(memory, size);
    } else {
        libc.free(memory);
    }
}

/// Takes a region from the OS and puts its single block in the free lists. Called with the lock.
fn rvn_heap_add_region() c_int {
    const region: [*c]rvn_region_t = @ptrCast(@alignCast(rvn_os_alloc(RVN_REGION_SIZE)));
    var block: [*c]rvn_block_t = undefined;
    var last: [*c]rvn_block_t = undefined;
    if (region == null) return raven.R_FALSE;

    region.*.next = g_heap.regions;
    region.*.prev = null;
    region.*.os_size = RVN_REGION_SIZE;
    if (g_heap.regions != null) g_heap.regions.*.prev = region;
    g_heap.regions = region;

    const region_bytes: [*c]u8 = @ptrCast(region);
    block = @ptrCast(@alignCast(region_bytes + @sizeOf(rvn_region_t)));
    block.*.u.prev_phys = null;
    block.*.s.size = RVN_REGION_SIZE - @sizeOf(rvn_region_t) - 2 * RVN_HEAP_HEADER;
    // the end of the region: a used block of no size, so that nothing merges past it
    last = rvn_block_next(block);
    last.*.u.prev_phys = block;
    last.*.s.size = 0;

    rvn_heap_insert(block);
    g_heap.empty_regions += 1;
    g_heap.stats.reserved_bytes += RVN_REGION_SIZE;
    return raven.R_TRUE;
}

/// Returns the region of a block that is alone in it, and out of the free lists, to the OS.
fn rvn_heap_release_region(block: [*c]rvn_block_t) void {
    const block_bytes: [*c]u8 = @ptrCast(block);
    const region: [*c]rvn_region_t = @ptrCast(@alignCast(block_bytes - @sizeOf(rvn_region_t)));
    if (region.*.prev != null) {
        region.*.prev.*.next = region.*.next;
    } else {
        g_heap.regions = region.*.next;
    }
    if (region.*.next != null) region.*.next.*.prev = region.*.prev;
    g_heap.stats.reserved_bytes -= region.*.os_size;
    rvn_os_free(region, region.*.os_size);
}

// ---------------------------------------------------------------------------
//  Blocks
// ---------------------------------------------------------------------------

/// Cuts a used block down to `size` and frees what is left, when it is worth a block.
fn rvn_heap_split(block: [*c]rvn_block_t, size: usize) void {
    const extra = rvn_block_size(block) - size;
    if (extra < RVN_HEAP_HEADER + RVN_HEAP_MIN_PAYLOAD) return;

    block.*.s.size = size | (block.*.s.size & RVN_BLOCK_FLAGS);
    const rest = rvn_block_next(block);
    rest.*.u.prev_phys = block;
    rest.*.s.size = extra - RVN_HEAP_HEADER;
    var next = rvn_block_next(rest);
    if (rvn_block_is_free(next)) {
        // (only when shrinking: a block found in a list never has a free neighbour)
        rvn_heap_remove(next);
        rest.*.s.size += RVN_HEAP_HEADER + rvn_block_size(next);
        next = rvn_block_next(rest);
    }
    next.*.u.prev_phys = rest;
    rvn_heap_insert(rest);
}

fn rvn_heap_count_alloc(size: usize) void {
    g_heap.stats.used_bytes += size;
    if (g_heap.stats.used_bytes > g_heap.stats.peak_bytes) g_heap.stats.peak_bytes = g_heap.stats.used_bytes;
    g_heap.stats.allocation_count += 1;
    g_heap.stats.total_allocations += 1;
}

fn rvn_heap_alloc_huge(size: usize) ?*anyopaque {
    const os_size: usize = (size + RVN_HEAP_HEADER + 4095) & ~@as(usize, 4095);
    const block: [*c]rvn_block_t = @ptrCast(@alignCast(rvn_os_alloc(os_size)));
    if (block == null) return null;
    block.*.u.os_size = os_size;
    block.*.s.size = size | RVN_BLOCK_HUGE;
    rvn_heap_lock();
    g_heap.stats.reserved_bytes += os_size;
    rvn_heap_count_alloc(size);
    rvn_heap_unlock();
    return rvn_block_payload(block);
}

export fn rvn_heap_alloc(size_: usize) ?*anyopaque {
    var size = size_;
    if (size > RVN_HEAP_MAX_REQUEST) return null;
    size = rvn_heap_round(size);
    if (size >= RVN_HUGE_SIZE) return rvn_heap_alloc_huge(size);

    rvn_heap_lock();
    var block = rvn_heap_find(size);
    if (block == null) {
        if (rvn_heap_add_region() == raven.R_FALSE) {
            rvn_heap_unlock();
            return null;
        }
        block = rvn_heap_find(size);
    }
    if (rvn_block_is_whole_region(block)) g_heap.empty_regions -= 1;
    rvn_heap_remove(block);
    rvn_heap_split(block, size);
    rvn_heap_count_alloc(rvn_block_size(block));
    rvn_heap_unlock();
    return rvn_block_payload(block);
}

export fn rvn_heap_free(ptr: ?*anyopaque) void {
    if (ptr == null) return;
    var block = rvn_block_of(ptr);

    if ((block.*.s.size & RVN_BLOCK_HUGE) != 0) {
        const os_size = block.*.u.os_size;
        rvn_heap_lock();
        g_heap.stats.used_bytes -= rvn_block_size(block);
        g_heap.stats.reserved_bytes -= os_size;
        g_heap.stats.allocation_count -= 1;
        rvn_heap_unlock();
        rvn_os_free(block, os_size);
        return;
    }

    rvn_heap_lock();
    if (rvn_block_is_free(block)) {
        rvn_heap_unlock();
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_FATAL, "memory: block %p freed twice", ptr);
        return;
    }
    g_heap.stats.used_bytes -= rvn_block_size(block);
    g_heap.stats.allocation_count -= 1;

    // merge with the neighbours that are free: there are never two free blocks in a row
    var neighbour = rvn_block_next(block);
    if (rvn_block_is_free(neighbour)) {
        rvn_heap_remove(neighbour);
        block.*.s.size += RVN_HEAP_HEADER + rvn_block_size(neighbour);
    }
    neighbour = block.*.u.prev_phys;
    if (neighbour != null and rvn_block_is_free(neighbour)) {
        rvn_heap_remove(neighbour);
        neighbour.*.s.size += RVN_HEAP_HEADER + rvn_block_size(block);
        block = neighbour;
    }
    rvn_block_next(block).*.u.prev_phys = block;

    if (rvn_block_is_whole_region(block) and g_heap.empty_regions >= 1) {
        // one empty region is kept, so that a program that allocates and
        // frees around a region boundary does not call the OS every time
        rvn_heap_release_region(block);
    } else {
        if (rvn_block_is_whole_region(block)) g_heap.empty_regions += 1;
        rvn_heap_insert(block);
    }
    rvn_heap_unlock();
}

export fn rvn_heap_realloc(ptr: ?*anyopaque, size_: usize) ?*anyopaque {
    var size = size_;

    if (ptr == null) return rvn_heap_alloc(size);
    if (size > RVN_HEAP_MAX_REQUEST) return null;
    const block = rvn_block_of(ptr);
    const old_size = rvn_block_size(block);
    size = rvn_heap_round(size);

    if ((block.*.s.size & RVN_BLOCK_HUGE) != 0) {
        // a huge block that stays huge and fits where it is does not move
        if (size >= RVN_HUGE_SIZE / 2 and size + RVN_HEAP_HEADER <= block.*.u.os_size) {
            rvn_heap_lock();
            g_heap.stats.used_bytes += size;
            g_heap.stats.used_bytes -= old_size;
            if (g_heap.stats.used_bytes > g_heap.stats.peak_bytes) g_heap.stats.peak_bytes = g_heap.stats.used_bytes;
            rvn_heap_unlock();
            block.*.s.size = size | RVN_BLOCK_HUGE;
            return ptr;
        }
    } else if (size < RVN_HUGE_SIZE) {
        rvn_heap_lock();
        if (size <= old_size) {
            rvn_heap_split(block, size);
            g_heap.stats.used_bytes -= old_size - rvn_block_size(block);
            rvn_heap_unlock();
            return ptr;
        }
        // grow into the next block when it is free and large enough
        const next = rvn_block_next(block);
        if (rvn_block_is_free(next) and old_size + RVN_HEAP_HEADER + rvn_block_size(next) >= size) {
            rvn_heap_remove(next);
            block.*.s.size += RVN_HEAP_HEADER + rvn_block_size(next);
            rvn_block_next(block).*.u.prev_phys = block;
            rvn_heap_split(block, size);
            g_heap.stats.used_bytes += rvn_block_size(block) - old_size;
            if (g_heap.stats.used_bytes > g_heap.stats.peak_bytes) g_heap.stats.peak_bytes = g_heap.stats.used_bytes;
            rvn_heap_unlock();
            return ptr;
        }
        rvn_heap_unlock();
    }

    const copy = rvn_heap_alloc(size);
    if (copy == null) return null;
    _ = libc.memcpy(copy, ptr, if (old_size < size) old_size else size);
    rvn_heap_free(ptr);
    return copy;
}

export fn rvn_heap_size(ptr: ?*const anyopaque) usize {
    return if (ptr != null) rvn_block_size(rvn_block_of(ptr)) else 0;
}

export fn rvn_heap_trim() void {
    rvn_heap_lock();
    var region: [*c]rvn_region_t = g_heap.regions;
    var next: [*c]rvn_region_t = undefined;
    while (region != null) : (region = next) {
        const region_bytes: [*c]u8 = @ptrCast(region);
        const block: [*c]rvn_block_t = @ptrCast(@alignCast(region_bytes + @sizeOf(rvn_region_t)));
        next = region.*.next;
        if (rvn_block_is_free(block) and rvn_block_is_whole_region(block)) {
            rvn_heap_remove(block);
            rvn_heap_release_region(block);
            g_heap.empty_regions -= 1;
        }
    }
    rvn_heap_unlock();
}

export fn rvn_heap_get_stats(stats: [*c]raven.RMemoryStats) void {
    rvn_heap_lock();
    stats.* = g_heap.stats;
    rvn_heap_unlock();
}

// ---------------------------------------------------------------------------
//  Self-check
// ---------------------------------------------------------------------------

export fn rvn_heap_check() c_int {
    var region: [*c]rvn_region_t = undefined;
    var used: usize = 0;
    var free_blocks: usize = 0;
    var listed: usize = 0;
    var fl: c_int = undefined;
    var sl: c_int = undefined;
    var ok: c_int = raven.R_TRUE;
    var empty: c_int = 0;

    // RVN_HEAP_EXPECT(condition) is written out at each use: if (!(condition)) { ok = R_FALSE; goto done; }
    rvn_heap_lock();
    done: {
        region = g_heap.regions;
        while (region != null) : (region = region.*.next) {
            const region_bytes: [*c]u8 = @ptrCast(region);
            var block: [*c]rvn_block_t = @ptrCast(@alignCast(region_bytes + @sizeOf(rvn_region_t)));
            var previous: [*c]rvn_block_t = null;
            const end: [*c]u8 = region_bytes + region.*.os_size;
            var previous_free: bool = false;
            // RVN_HEAP_EXPECT(!region->next || region->next->prev == region);
            if (!(region.*.next == null or region.*.next.*.prev == region)) {
                ok = raven.R_FALSE;
                break :done;
            }
            while (true) {
                const size = rvn_block_size(block);
                const block_bytes: [*c]u8 = @ptrCast(block);
                // RVN_HEAP_EXPECT((char*)block + RVN_HEAP_HEADER <= end);
                if (!(block_bytes + RVN_HEAP_HEADER <= end)) {
                    ok = raven.R_FALSE;
                    break :done;
                }
                // RVN_HEAP_EXPECT(block->u.prev_phys == previous);
                if (!(block.*.u.prev_phys == previous)) {
                    ok = raven.R_FALSE;
                    break :done;
                }
                // RVN_HEAP_EXPECT(!(block->s.size & RVN_BLOCK_HUGE));
                if (!((block.*.s.size & RVN_BLOCK_HUGE) == 0)) {
                    ok = raven.R_FALSE;
                    break :done;
                }
                if (size == 0) {
                    // the end of the region
                    // RVN_HEAP_EXPECT(!rvn_block_is_free(block));
                    if (!(!rvn_block_is_free(block))) {
                        ok = raven.R_FALSE;
                        break :done;
                    }
                    // RVN_HEAP_EXPECT((char*)block + RVN_HEAP_HEADER == end);
                    if (!(block_bytes + RVN_HEAP_HEADER == end)) {
                        ok = raven.R_FALSE;
                        break :done;
                    }
                    break;
                }
                // RVN_HEAP_EXPECT((size & (RVN_HEAP_ALIGN - 1)) == 0 && size >= RVN_HEAP_MIN_PAYLOAD);
                if (!((size & (RVN_HEAP_ALIGN - 1)) == 0 and size >= RVN_HEAP_MIN_PAYLOAD)) {
                    ok = raven.R_FALSE;
                    break :done;
                }
                if (rvn_block_is_free(block)) {
                    // two free neighbours would have been merged
                    // RVN_HEAP_EXPECT(!previous_free);
                    if (!(!previous_free)) {
                        ok = raven.R_FALSE;
                        break :done;
                    }
                    free_blocks += 1;
                    if (rvn_block_is_whole_region(block)) empty += 1;
                } else {
                    used += size;
                }
                previous_free = rvn_block_is_free(block);
                previous = block;
                block = rvn_block_next(block);
            }
        }
        // RVN_HEAP_EXPECT(empty == g_heap.empty_regions);
        if (!(empty == g_heap.empty_regions)) {
            ok = raven.R_FALSE;
            break :done;
        }

        fl = 0;
        while (fl < RVN_FL_COUNT) : (fl += 1) {
            // RVN_HEAP_EXPECT(((g_heap.fl_bitmap >> fl) & 1u) == (g_heap.sl_bitmap[fl] != 0));
            if (!(((g_heap.fl_bitmap >> @intCast(fl)) & 1) == @intFromBool(g_heap.sl_bitmap[@intCast(fl)] != 0))) {
                ok = raven.R_FALSE;
                break :done;
            }
            sl = 0;
            while (sl < RVN_SL_COUNT) : (sl += 1) {
                var block: [*c]rvn_block_t = g_heap.lists[@intCast(fl)][@intCast(sl)];
                var previous: [*c]rvn_block_t = null;
                // RVN_HEAP_EXPECT(((g_heap.sl_bitmap[fl] >> sl) & 1u) == (block != NULL));
                if (!(((g_heap.sl_bitmap[@intCast(fl)] >> @intCast(sl)) & 1) == @intFromBool(block != null))) {
                    ok = raven.R_FALSE;
                    break :done;
                }
                while (block != null) : (block = block.*.next_free) {
                    var block_fl: c_int = undefined;
                    var block_sl: c_int = undefined;
                    // RVN_HEAP_EXPECT(rvn_block_is_free(block));
                    if (!rvn_block_is_free(block)) {
                        ok = raven.R_FALSE;
                        break :done;
                    }
                    // RVN_HEAP_EXPECT(block->prev_free == previous);
                    if (!(block.*.prev_free == previous)) {
                        ok = raven.R_FALSE;
                        break :done;
                    }
                    rvn_heap_mapping(rvn_block_size(block), &block_fl, &block_sl);
                    // RVN_HEAP_EXPECT(block_fl == fl && block_sl == sl);
                    if (!(block_fl == fl and block_sl == sl)) {
                        ok = raven.R_FALSE;
                        break :done;
                    }
                    listed += 1;
                    previous = block;
                }
            }
        }
        // every free block is in a list, once
        // RVN_HEAP_EXPECT(listed == free_blocks);
        if (!(listed == free_blocks)) {
            ok = raven.R_FALSE;
            break :done;
        }
        // what is not in the regions is in the huge blocks
        // RVN_HEAP_EXPECT(used <= g_heap.stats.used_bytes);
        if (!(used <= g_heap.stats.used_bytes)) {
            ok = raven.R_FALSE;
            break :done;
        }
        const huge = g_heap.stats.used_bytes - used;
        // RVN_HEAP_EXPECT(huge == 0 || huge >= RVN_HUGE_SIZE / 2);
        if (!(huge == 0 or huge >= RVN_HUGE_SIZE / 2)) {
            ok = raven.R_FALSE;
            break :done;
        }
    }
    rvn_heap_unlock();
    return ok;
}
