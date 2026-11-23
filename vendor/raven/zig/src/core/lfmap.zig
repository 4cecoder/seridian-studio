// Translated to Zig from vendor/raven/src/core/lfmap.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/lfmap.c

const raven = @import("raven");
const base = @import("base_h.zig");
const thread = @import("thread_h.zig");
const lfmap = @import("lfmap_h.zig");

fn rvn_lfmap_hash(key: u64) u32 {
    var key_ = key;
    key_ ^= key_ >> 33;
    key_ *%= 0xff51afd7ed558ccd;
    key_ ^= key_ >> 33;
    key_ *%= 0xc4ceb9fe1a85ec53;
    key_ ^= key_ >> 33;
    return @truncate(key_);
}

export fn rvn_lfmap_find(map: [*c]lfmap.rvn_lfmap_t, key: u64, value: [*c]u64) c_int {
    const table: [*c]lfmap.rvn_lfmap_table_t = @ptrCast(@alignCast(thread.rvn_atomic_ptr_load(&map.*.table)));
    if (table == null) return raven.R_FALSE;
    const mask: u32 = table.*.cap -% 1;
    var slot: u32 = rvn_lfmap_hash(key) & mask;
    var probe: u32 = 0;
    while (probe < table.*.cap) : (probe += 1) {
        const slots: [*c]lfmap.rvn_lfmap_slot_t = &table.*.slots;
        const entry = &slots[slot];
        // reading the state first makes the key and value safe to read
        if (thread.rvn_atomic_load(&entry.*.state) == 0) return raven.R_FALSE;
        if (entry.*.key == key) {
            value[0] = entry.*.value[0];
            value[1] = entry.*.value[1];
            return raven.R_TRUE;
        }
        slot = (slot +% 1) & mask;
    }
    return raven.R_FALSE;
}

fn rvn_lfmap_table_new(cap: u32) [*c]lfmap.rvn_lfmap_table_t {
    const size: usize = @sizeOf(lfmap.rvn_lfmap_table_t) + @sizeOf(lfmap.rvn_lfmap_slot_t) * @as(usize, cap -% 1);
    const table: [*c]lfmap.rvn_lfmap_table_t = @ptrCast(@alignCast(base.rvn_calloc(size)));
    table.*.cap = cap;
    return table;
}

fn rvn_lfmap_table_put(table: [*c]lfmap.rvn_lfmap_table_t, key: u64, value: [*c]const u64) void {
    const mask: u32 = table.*.cap -% 1;
    var slot: u32 = rvn_lfmap_hash(key) & mask;
    const slots: [*c]lfmap.rvn_lfmap_slot_t = &table.*.slots;
    while (thread.rvn_atomic_load(&slots[slot].state) != 0) slot = (slot +% 1) & mask;
    const entry = &slots[slot];
    entry.*.key = key;
    entry.*.value[0] = value[0];
    entry.*.value[1] = value[1];
    // publication: from here on, readers may use the slot
    thread.rvn_atomic_store(&entry.*.state, 1);
    table.*.count +%= 1;
}

export fn rvn_lfmap_insert(map: [*c]lfmap.rvn_lfmap_t, key: u64, value: [*c]const u64) void {
    const table: [*c]lfmap.rvn_lfmap_table_t = @ptrCast(@alignCast(thread.rvn_atomic_ptr_load(&map.*.table)));
    if (table == null or (table.*.count +% 1) *% 4 > table.*.cap *% 3) {
        const larger = rvn_lfmap_table_new(if (table != null) table.*.cap *% 2 else 256);
        var i: u32 = 0;
        while (table != null and i < table.*.cap) : (i += 1) {
            const slots: [*c]lfmap.rvn_lfmap_slot_t = &table.*.slots;
            if (thread.rvn_atomic_load(&slots[i].state) != 0) {
                rvn_lfmap_table_put(larger, slots[i].key, &slots[i].value);
            }
        }
        rvn_lfmap_table_put(larger, key, value);
        thread.rvn_atomic_ptr_store(&map.*.table, larger);
        // readers may still be probing the old table
        if (table != null) {
            table.*.retired_next = map.*.retired;
            map.*.retired = table;
        }
        return;
    }
    rvn_lfmap_table_put(table, key, value);
}

export fn rvn_lfmap_collect(map: [*c]lfmap.rvn_lfmap_t) void {
    var table = map.*.retired;
    while (table != null) {
        const next = table.*.retired_next;
        base.rvn_free(table);
        table = next;
    }
    map.*.retired = null;
}

export fn rvn_lfmap_clear(map: [*c]lfmap.rvn_lfmap_t) void {
    rvn_lfmap_collect(map);
    base.rvn_free(thread.rvn_atomic_ptr_load(&map.*.table));
    thread.rvn_atomic_ptr_store(&map.*.table, null);
}
