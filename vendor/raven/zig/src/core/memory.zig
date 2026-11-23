// Translated to Zig from vendor/raven/src/core/memory.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/memory.c
// Choice of the allocator, dynamic arrays, arena, strings and hashing.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("base_h.zig");
const heap_h = @import("heap_h.zig");
const thread_h = @import("thread_h.zig");
const libc = @import("../sys/libc.zig");

// ---------------------------------------------------------------------------
//  Allocator
//
//  Every allocation of the library goes through rvn_alloc / rvn_realloc /
//  rvn_free, including the ones of the bundled decoders. By default they use
//  the heap of Raven (heap.c); the application can give its own functions
//  instead (Rset_allocator).
// ---------------------------------------------------------------------------

const rvn_memory_mode_t = c_int;
const RVN_MEMORY_UNDECIDED: c_int = 0;
const RVN_MEMORY_HEAP: c_int = 1;
const RVN_MEMORY_USER: c_int = 2;

var g_allocator: raven.RAllocator = std.mem.zeroes(raven.RAllocator);
var g_memory_mode: thread_h.rvn_atomic_t = std.mem.zeroes(thread_h.rvn_atomic_t);
// allocations made through the functions of the application: only counted
var g_user_live: thread_h.rvn_atomic_t = std.mem.zeroes(thread_h.rvn_atomic_t);
var g_user_total: thread_h.rvn_atomic_t = std.mem.zeroes(thread_h.rvn_atomic_t);

fn rvn_system_alloc(size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = user_data;
    return libc.malloc(size);
}

fn rvn_system_realloc(ptr: ?*anyopaque, size: usize, user_data: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = user_data;
    return libc.realloc(ptr, size);
}

fn rvn_system_free(ptr: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    libc.free(ptr);
}

const g_system_allocator: raven.RAllocator = .{
    .alloc = &rvn_system_alloc,
    .realloc = &rvn_system_realloc,
    .free = &rvn_system_free,
    .user_data = null,
};

export fn Rallocator_get_system() [*c]const raven.RAllocator {
    return &g_system_allocator;
}

// Address sanitizers follow malloc, not a private heap: with them, the C
// runtime is the default, so that they keep seeing every block of the library.
// (The C preprocessor test of __SANITIZE_ADDRESS__ / __has_feature has no
// counterpart here: the Zig build does not define RVN_MEMORY_PREFER_SYSTEM.)
const RVN_MEMORY_PREFER_SYSTEM = false;

/// Chooses the allocator at the first allocation.
fn rvn_memory_mode() c_int {
    var mode = thread_h.rvn_atomic_load(&g_memory_mode);
    if (mode == RVN_MEMORY_UNDECIDED) {
        // RAVEN_ALLOCATOR=system|raven overrides the default, to debug with external tools
        const choice = libc.getenv("RAVEN_ALLOCATOR");
        var system: c_int = raven.R_FALSE;
        if (RVN_MEMORY_PREFER_SYSTEM) system = raven.R_TRUE;
        if (choice != null and rvn_stricmp(choice, "system") == 0) system = raven.R_TRUE;
        if (choice != null and rvn_stricmp(choice, "raven") == 0) system = raven.R_FALSE;
        if (g_allocator.alloc != null) {
            mode = RVN_MEMORY_USER;
        } else if (system != raven.R_FALSE) {
            g_allocator = g_system_allocator;
            mode = RVN_MEMORY_USER;
        } else {
            mode = RVN_MEMORY_HEAP;
        }
        thread_h.rvn_atomic_store(&g_memory_mode, mode);
    }
    return mode;
}

export fn Rset_allocator(allocator: [*c]const raven.RAllocator) void {
    var stats: raven.RMemoryStats = undefined;
    Rmemory_get_stats(&stats);
    if (raven.Ris_initialized() != 0 or stats.allocation_count != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rset_allocator must be called before Rinit, while the library holds no memory");
        return;
    }
    if (allocator != null and !(allocator.*.alloc != null and allocator.*.realloc != null and allocator.*.free != null)) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rset_allocator: the three functions are required");
        return;
    }
    heap_h.rvn_heap_trim();
    if (allocator != null) {
        g_allocator = allocator.*;
        thread_h.rvn_atomic_store(&g_memory_mode, RVN_MEMORY_USER);
    } else {
        g_allocator = std.mem.zeroes(raven.RAllocator);
        thread_h.rvn_atomic_store(&g_memory_mode, RVN_MEMORY_HEAP);
    }
}

export fn Rmemory_get_stats(stats: [*c]raven.RMemoryStats) void {
    if (stats == null) return;
    heap_h.rvn_heap_get_stats(stats);
    if (thread_h.rvn_atomic_load(&g_memory_mode) == RVN_MEMORY_USER) {
        // sizes are only known to the allocator of the application
        stats.*.allocation_count = @as(usize, @bitCast(@as(isize, thread_h.rvn_atomic_load(&g_user_live))));
        stats.*.total_allocations = @as(u64, @as(u32, @bitCast(thread_h.rvn_atomic_load(&g_user_total))));
    }
}

export fn Rmemory_check() c_int {
    return heap_h.rvn_heap_check();
}

export fn Rmemory_trim() void {
    heap_h.rvn_heap_trim();
}

// Debug builds fill new memory with 0xCD and freed memory with 0xDD: code that
// reads a block before writing it, or after freeing it, fails at once instead
// of working by luck. (C: #if !defined(NDEBUG) && !defined(RVN_MEMORY_NO_FILL).
// The reference build is CMAKE_BUILD_TYPE=Release, which defines NDEBUG.)
const RVN_MEMORY_FILL = builtin.mode == .debug;

export fn Rmemory_alloc(size: usize) ?*anyopaque {
    return rvn_alloc(size);
}

export fn Rmemory_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque {
    return rvn_realloc(ptr, size);
}

export fn Rmemory_free(ptr: ?*anyopaque) void {
    rvn_free(ptr);
}

fn rvn_out_of_memory(size: usize) void {
    base.rvn_error(raven.R_ERROR_OUT_OF_MEMORY, raven.R_SEVERITY_FATAL, "allocation of %zu bytes failed", size);
    libc.abort();
}

export fn rvn_alloc(size_: usize) ?*anyopaque {
    var size = size_;
    var ptr: ?*anyopaque = undefined;
    if (size == 0) size = 1;
    if (rvn_memory_mode() == RVN_MEMORY_HEAP) {
        ptr = heap_h.rvn_heap_alloc(size);
        if (RVN_MEMORY_FILL) {
            if (ptr != null) _ = libc.memset(ptr, 0xCD, heap_h.rvn_heap_size(ptr));
        }
    } else {
        ptr = g_allocator.alloc.?(size, g_allocator.user_data);
        _ = thread_h.rvn_atomic_add(&g_user_live, 1);
        _ = thread_h.rvn_atomic_add(&g_user_total, 1);
    }
    if (ptr == null) rvn_out_of_memory(size);
    return ptr;
}

export fn rvn_calloc(size: usize) ?*anyopaque {
    const ptr = rvn_alloc(size);
    _ = libc.memset(ptr, 0, size);
    return ptr;
}

export fn rvn_realloc(ptr: ?*anyopaque, size_: usize) ?*anyopaque {
    var size = size_;
    var out: ?*anyopaque = undefined;
    if (ptr == null) return rvn_alloc(size_);
    if (size == 0) size = 1;
    if (rvn_memory_mode() == RVN_MEMORY_HEAP) {
        if (RVN_MEMORY_FILL) {
            const old_size = heap_h.rvn_heap_size(ptr);
            out = heap_h.rvn_heap_realloc(ptr, size);
            if (out != null and heap_h.rvn_heap_size(out) > old_size) {
                _ = libc.memset(@as([*c]u8, @ptrCast(out)) + old_size, 0xCD, heap_h.rvn_heap_size(out) - old_size);
            }
        } else {
            out = heap_h.rvn_heap_realloc(ptr, size);
        }
    } else {
        out = g_allocator.realloc.?(ptr, size, g_allocator.user_data);
    }
    if (out == null) rvn_out_of_memory(size);
    return out;
}

export fn rvn_free(ptr: ?*anyopaque) void {
    if (ptr == null) return;
    if (rvn_memory_mode() == RVN_MEMORY_HEAP) {
        if (RVN_MEMORY_FILL) _ = libc.memset(ptr, 0xDD, heap_h.rvn_heap_size(ptr));
        heap_h.rvn_heap_free(ptr);
    } else {
        g_allocator.free.?(ptr, g_allocator.user_data);
        _ = thread_h.rvn_atomic_add(&g_user_live, -1);
    }
}

export fn Rpixels_alloc(size: usize) [*c]u8 {
    return @ptrCast(rvn_alloc(size));
}

export fn Rpixels_free(pixels: [*c]u8) void {
    rvn_free(pixels);
}

// ---------------------------------------------------------------------------
//  Dynamic arrays
// ---------------------------------------------------------------------------

export fn rvn_array_grow_(data_: ?*anyopaque, cap: [*c]u32, needed: u32, item_size: usize) ?*anyopaque {
    var data = data_;
    var new_cap: u32 = if (cap.* != 0) cap.* else 8;
    while (new_cap < needed) {
        new_cap = if (new_cap < 0x40000000) new_cap * 2 else needed;
    }
    data = rvn_realloc(data, @as(usize, new_cap) *% item_size);
    cap.* = new_cap;
    return data;
}

// ---------------------------------------------------------------------------
//  Arena
// ---------------------------------------------------------------------------

export fn rvn_arena_init(arena: [*c]base.rvn_arena_t, block_size: usize) void {
    arena.*.head = null;
    arena.*.current = null;
    arena.*.block_size = if (block_size != 0) block_size else 16384;
}

export fn rvn_arena_alloc(arena: [*c]base.rvn_arena_t, size_: usize) ?*anyopaque {
    var block: [*c]base.rvn_arena_block_t = arena.*.current;
    var size = size_;
    size = (size +% 15) & ~@as(usize, 15);
    if (block == null or block.*.used +% size > block.*.cap) {
        const cap: usize = if (size > arena.*.block_size) size else arena.*.block_size;
        block = @ptrCast(@alignCast(rvn_alloc(@sizeOf(base.rvn_arena_block_t) +% 16 +% cap)));
        block.*.next = null;
        block.*.cap = cap;
        block.*.used = 0;
        if (arena.*.current != null) {
            arena.*.current.*.next = block;
        } else {
            arena.*.head = block;
        }
        arena.*.current = block;
    }
    // the payload starts on a 16-byte boundary after the header
    const ptr: [*c]u8 = @as([*c]u8, @ptrCast(block)) + ((@sizeOf(base.rvn_arena_block_t) + 15) & ~@as(usize, 15)) + block.*.used;
    block.*.used +%= size;
    return ptr;
}

export fn rvn_arena_strndup(arena: [*c]base.rvn_arena_t, text: [*c]const u8, length: usize) [*c]u8 {
    const out: [*c]u8 = @ptrCast(rvn_arena_alloc(arena, length + 1));
    if (length != 0) _ = libc.memcpy(out, text, length);
    out[length] = 0;
    return out;
}

export fn rvn_arena_free(arena: [*c]base.rvn_arena_t) void {
    var block: [*c]base.rvn_arena_block_t = arena.*.head;
    while (block != null) {
        const next = block.*.next;
        rvn_free(block);
        block = next;
    }
    arena.*.head = null;
    arena.*.current = null;
}

// ---------------------------------------------------------------------------
//  Strings
// ---------------------------------------------------------------------------

export fn rvn_strndup(text: [*c]const u8, length: usize) [*c]u8 {
    const out: [*c]u8 = @ptrCast(rvn_alloc(length + 1));
    if (length != 0) _ = libc.memcpy(out, text, length);
    out[length] = 0;
    return out;
}

export fn rvn_strdup(text: [*c]const u8) [*c]u8 {
    return if (text != null) rvn_strndup(text, libc.strlen(text)) else null;
}

export fn rvn_str_set(dst: [*c][*c]u8, src: [*c]const u8) c_int {
    if (dst.* == src) return raven.R_FALSE;
    if (dst.* != null and src != null and libc.strcmp(dst.*, src) == 0) return raven.R_FALSE;
    if (dst.* == null and src == null) return raven.R_FALSE;
    {
        const copy = rvn_strdup(src);
        rvn_free(dst.*);
        dst.* = copy;
    }
    return raven.R_TRUE;
}

export fn rvn_text_append(text: [*c]base.rvn_text_t, bytes: [*c]const u8, length: usize) void {
    if (text.*.length + length + 1 > text.*.cap) {
        var cap: usize = if (text.*.cap != 0) text.*.cap * 2 else 256;
        while (cap < text.*.length + length + 1) cap *= 2;
        text.*.data = @ptrCast(rvn_realloc(text.*.data, cap));
        text.*.cap = cap;
    }
    if (length != 0) _ = libc.memcpy(text.*.data + text.*.length, bytes, length);
    text.*.length += length;
    text.*.data[text.*.length] = 0;
}

export fn rvn_text_add(text: [*c]base.rvn_text_t, string: [*c]const u8) void {
    if (string != null) rvn_text_append(text, string, libc.strlen(string));
}

export fn rvn_text_printf(text: [*c]base.rvn_text_t, format: [*c]const u8, ...) callconv(.c) void {
    var local: [512]u8 = undefined;
    var args = @cVaStart(); // va_start(args, format);
    const needed = libc.vsnprintf(&local, local.len, format, &args);
    @cVaEnd(&args); // va_end(args);
    if (needed < 0) return;
    const n: usize = @intCast(needed);
    if (n < local.len) {
        rvn_text_append(text, &local, n);
    } else {
        const large: [*c]u8 = @ptrCast(rvn_alloc(n + 1));
        args = @cVaStart(); // va_start(args, format);
        _ = libc.vsnprintf(large, n + 1, format, &args);
        @cVaEnd(&args); // va_end(args);
        rvn_text_append(text, large, n);
        rvn_free(large);
    }
}

fn rvn_lower(c: c_int) c_int {
    return if (c >= 'A' and c <= 'Z') c + ('a' - 'A') else c;
}

export fn rvn_stricmp(a_: [*c]const u8, b_: [*c]const u8) c_int {
    var a = a_;
    var b = b_;
    if (a == null) a = "";
    if (b == null) b = "";
    while (true) : ({
        a += 1;
        b += 1;
    }) {
        const ca = rvn_lower(a[0]);
        const cb = rvn_lower(b[0]);
        if (ca != cb) return ca - cb;
        if (ca == 0) return 0;
    }
}

export fn rvn_strnicmp(a: [*c]const u8, b: [*c]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = rvn_lower(a[i]);
        const cb = rvn_lower(b[i]);
        if (ca != cb) return ca - cb;
        if (ca == 0) return 0;
    }
    return 0;
}

export fn rvn_hash_bytes(data: ?*const anyopaque, size: usize) u32 {
    // FNV-1a
    const bytes: [*c]const u8 = @ptrCast(data);
    var hash: u32 = 2166136261;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        hash ^= bytes[i];
        hash *%= 16777619;
    }
    return hash;
}

export fn rvn_hash_str(text: [*c]const u8) u32 {
    return rvn_hash_bytes(text, if (text != null) libc.strlen(text) else 0);
}

// ---------------------------------------------------------------------------
//  Paths
// ---------------------------------------------------------------------------

fn rvn_is_separator(c: u8) c_int {
    return @intFromBool(c == '/' or c == '\\');
}

fn rvn_path_is_absolute(path: [*c]const u8) c_int {
    if (rvn_is_separator(path[0]) != 0) return raven.R_TRUE;
    // drive letter: "C:"
    return @intFromBool(path[0] != 0 and path[1] == ':');
}

export fn rvn_path_join(base_: [*c]const u8, path: [*c]const u8) [*c]u8 {
    if (path == null) return null;
    if (base_ == null or base_[0] == 0 or rvn_path_is_absolute(path) != 0) return rvn_strdup(path);
    var base_len: usize = libc.strlen(base_);
    const path_len: usize = libc.strlen(path);
    const out: [*c]u8 = @ptrCast(rvn_alloc(base_len +% path_len +% 2));
    _ = libc.memcpy(out, base_, base_len);
    if (rvn_is_separator(base_[base_len - 1]) == 0) {
        out[base_len] = '/';
        base_len += 1;
    }
    _ = libc.memcpy(out + base_len, path, path_len + 1);
    return out;
}

export fn rvn_path_dir(path: [*c]const u8) [*c]u8 {
    var length: usize = if (path != null) libc.strlen(path) else 0;
    while (length > 0 and rvn_is_separator(path[length - 1]) == 0) length -= 1;
    const text: [*c]const u8 = if (path != null) path else "";
    return rvn_strndup(text, length);
}
