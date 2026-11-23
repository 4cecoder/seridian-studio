// Translated to Zig from vendor/raven/src/core/handle.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/handle.c

const std = @import("std");
const raven = @import("raven");
const base = @import("base_h.zig");
const handle = @import("handle_h.zig");

export fn rvn_pool_init(pool: [*c]handle.rvn_pool_t, type_: handle.rvn_handle_type_t) void {
    pool.* = std.mem.zeroes(handle.rvn_pool_t);
    pool.*.type = @intCast(type_);
}

export fn rvn_pool_free(pool: [*c]handle.rvn_pool_t) void {
    base.rvn_free(@ptrCast(pool.*.items));
    base.rvn_free(pool.*.generations);
    base.rvn_free(pool.*.free_list);
    pool.* = std.mem.zeroes(handle.rvn_pool_t);
}

export fn rvn_pool_add(pool: [*c]handle.rvn_pool_t, object: ?*anyopaque) raven.Rid {
    var index: u32 = undefined;
    if (pool.*.free_count > 0) {
        pool.*.free_count -= 1;
        index = pool.*.free_list[pool.*.free_count];
    } else {
        if (pool.*.used > handle.RVN_HANDLE_MAX_INDEX) {
            base.rvn_error(raven.R_ERROR_OUT_OF_MEMORY, raven.R_SEVERITY_ERROR, "too many live objects of one type");
            return raven.R_INVALID_ID;
        }
        if (pool.*.used == pool.*.cap) {
            const old_cap: u32 = pool.*.cap;
            const new_cap: u32 = if (old_cap != 0) old_cap *% 2 else 64;
            pool.*.items = @ptrCast(@alignCast(base.rvn_realloc(@ptrCast(pool.*.items), @as(usize, new_cap) * @sizeOf(?*anyopaque))));
            pool.*.generations = @ptrCast(base.rvn_realloc(pool.*.generations, new_cap));
            @memset(pool.*.items[old_cap..new_cap], null);
            @memset(pool.*.generations[old_cap..new_cap], 0);
            pool.*.cap = new_cap;
        }
        index = pool.*.used;
        pool.*.used += 1;
    }
    pool.*.items[index] = object;
    pool.*.live += 1;
    return handle.rvn_handle_make(pool.*.type, pool.*.generations[index], index);
}

export fn rvn_pool_get(pool: [*c]const handle.rvn_pool_t, id: raven.Rid) ?*anyopaque {
    const index: u32 = handle.rvn_handle_index(id);
    if (handle.rvn_handle_type(id) != pool.*.type or index >= pool.*.used) return null;
    if (pool.*.generations[index] != handle.rvn_handle_generation(id)) return null;
    return pool.*.items[index];
}

export fn rvn_pool_remove(pool: [*c]handle.rvn_pool_t, id: raven.Rid) void {
    const index: u32 = handle.rvn_handle_index(id);
    if (rvn_pool_get(pool, id) == null) return;
    pool.*.items[index] = null;
    pool.*.generations[index] +%= 1;
    base.RVN_ARRAY_RESERVE(&pool.*.free_list, &pool.*.free_cap, pool.*.free_count + 1);
    pool.*.free_list[pool.*.free_count] = index;
    pool.*.free_count += 1;
    pool.*.live -%= 1;
}

export fn rvn_pool_at(pool: [*c]const handle.rvn_pool_t, index: u32) ?*anyopaque {
    return if (index < pool.*.used) pool.*.items[index] else null;
}
