// Translated to Zig from vendor/raven/src/core/lfmap.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/lfmap.h
// Hash map (64-bit key -> 16-byte value) whose lookups take no lock.
//
// It is built for caches that are read all the time by several threads and
// written rarely (the glyph caches read by the paint jobs):
//   - rvn_lfmap_find can be called from any thread, concurrently with
//     anything, and never blocks;
//   - writers must be serialized by the caller (one mutex);
//   - entries are never removed or changed, only added;
//   - when the table grows, the old storage is kept alive until
//     rvn_lfmap_collect, which the owner calls at a point where no reader
//     can be in the middle of a lookup.
//
// A reader that races with an insertion may miss the new entry: it then
// takes the writer mutex and looks again, like for any other cache miss.

const thread = @import("thread_h.zig");

pub const rvn_lfmap_slot_t = extern struct {
    /// 0 = empty, 1 = key and value are published.
    state: thread.rvn_atomic_t,
    reserved: u32,
    key: u64,
    value: [2]u64,
};
pub const struct_rvn_lfmap_slot_t = rvn_lfmap_slot_t;

pub const rvn_lfmap_table_t = extern struct {
    cap: u32,
    count: u32,
    retired_next: [*c]rvn_lfmap_table_t,
    slots: [1]rvn_lfmap_slot_t,
};
pub const struct_rvn_lfmap_table_t = rvn_lfmap_table_t;

pub const rvn_lfmap_t = extern struct {
    table: thread.rvn_atomic_ptr_t,
    /// Tables replaced by a larger one, waiting for rvn_lfmap_collect.
    retired: [*c]rvn_lfmap_table_t,
};
pub const struct_rvn_lfmap_t = rvn_lfmap_t;

/// Lock-free. Returns R_TRUE and fills `value` when the key is present.
pub extern fn rvn_lfmap_find(map: [*c]rvn_lfmap_t, key: u64, value: [*c]u64) c_int;
/// Adds a key that is not in the map. The caller holds the writer lock.
pub extern fn rvn_lfmap_insert(map: [*c]rvn_lfmap_t, key: u64, value: [*c]const u64) void;
/// Frees the retired tables. No reader may be inside rvn_lfmap_find.
pub extern fn rvn_lfmap_collect(map: [*c]rvn_lfmap_t) void;
/// Empties the map. No reader may be active.
pub extern fn rvn_lfmap_clear(map: [*c]rvn_lfmap_t) void;
