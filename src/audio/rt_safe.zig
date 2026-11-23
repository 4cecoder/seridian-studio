const std = @import("std");
const builtin = @import("builtin");

/// Thread-local flag to identify if the current thread is the audio processing thread.
pub threadlocal var is_audio_thread: bool = false;

/// Panic if we are currently in an audio thread.
/// This should be called before any non-deterministic operation (allocation, I/O, locking).
pub fn assertRealTimeSafe() void {
    if (builtin.mode == .debug or builtin.mode == .safe) {
        if (is_audio_thread) {
            @panic("Real-time safety violation: non-deterministic operation called on audio thread!");
        }
    }
}

/// Global state to allow the allocator to work from any context without pointer stability issues.
var global_parent_allocator: ?std.mem.Allocator = null;

/// A wrapper allocator that panics if used from the audio thread.
/// Uses global state for the parent to ensure stability even if the engine moves.
pub const RealTimeSafeAllocator = struct {
    pub fn allocator() std.mem.Allocator {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(_: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        assertRealTimeSafe();
        if (global_parent_allocator) |pa| {
            return pa.vtable.alloc(pa.ptr, len, ptr_align, ret_addr);
        }
        return null;
    }

    fn resize(_: *anyopaque, buf: []u8, ptr_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        assertRealTimeSafe();
        if (global_parent_allocator) |pa| {
            return pa.vtable.resize(pa.ptr, buf, ptr_align, new_len, ret_addr);
        }
        return false;
    }

    fn remap(_: *anyopaque, buf: []u8, ptr_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        assertRealTimeSafe();
        if (global_parent_allocator) |pa| {
            return pa.vtable.remap(pa.ptr, buf, ptr_align, new_len, ret_addr);
        }
        return null;
    }

    fn free(_: *anyopaque, buf: []u8, ptr_align: std.mem.Alignment, ret_addr: usize) void {
        assertRealTimeSafe();
        if (global_parent_allocator) |pa| {
            pa.vtable.free(pa.ptr, buf, ptr_align, ret_addr);
        }
    }
};

pub fn init(parent: std.mem.Allocator) std.mem.Allocator {
    global_parent_allocator = parent;
    return RealTimeSafeAllocator.allocator();
}
