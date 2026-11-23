// Translated to Zig from vendor/raven/src/core/heap.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/heap.h
// The allocator of the library: a TLSF heap over memory taken from the OS.
// Nothing in Raven calls malloc; see heap.c.

const raven = @import("raven");

/// Returns NULL when the OS has no memory left. The result is aligned on 16 bytes.
pub extern fn rvn_heap_alloc(size: usize) ?*anyopaque;
/// Grows or shrinks a block, in place when it can. NULL when out of memory (the block is kept).
pub extern fn rvn_heap_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
pub extern fn rvn_heap_free(ptr: ?*anyopaque) void;

/// Bytes that can be written at `ptr` (at least the size that was asked for).
pub extern fn rvn_heap_size(ptr: ?*const anyopaque) usize;

/// Gives the regions that hold no allocation back to the OS.
pub extern fn rvn_heap_trim() void;

/// Walks every block and every free list. R_FALSE when the heap is corrupted.
pub extern fn rvn_heap_check() c_int;

pub extern fn rvn_heap_get_stats(stats: [*c]raven.RMemoryStats) void;
