// Translated to Zig from vendor/raven/src/core/handle.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/handle.h
// Generational handle pools: Rid <-> object pointer.
//
// Handle layout (32 bits):   [ type : 4 | generation : 8 | index : 20 ]
//
// The type tag makes a font handle invalid where a widget is expected, the
// generation makes a deleted handle invalid even after its slot is reused.
// Type 0 and type 15 are never used, so 0 and R_INVALID_ID never resolve.

const raven = @import("raven");

pub const rvn_handle_type_t = c_uint;
pub const enum_rvn_handle_type_t = rvn_handle_type_t;
pub const RVN_HANDLE_WINDOW: c_int = 1;
pub const RVN_HANDLE_WIDGET: c_int = 2;
pub const RVN_HANDLE_FONT: c_int = 3;
pub const RVN_HANDLE_TEXTURE: c_int = 4;
pub const RVN_HANDLE_TIMER: c_int = 5;
pub const RVN_HANDLE_TREE_ITEM: c_int = 6;
pub const RVN_HANDLE_XML_DOCUMENT: c_int = 7;
pub const RVN_HANDLE_XML_NODE: c_int = 8;
/// Pseudo-handle naming a glyph atlas page inside draw lists (never in a pool).
pub const RVN_HANDLE_ATLAS_PAGE: c_int = 9;
/// A fragment shader of the application or a built-in effect (raven_shader.h).
pub const RVN_HANDLE_SHADER: c_int = 10;

pub const RVN_HANDLE_INDEX_BITS: u32 = 20;
pub const RVN_HANDLE_INDEX_MASK: u32 = 0xFFFFF;
pub const RVN_HANDLE_MAX_INDEX: u32 = RVN_HANDLE_INDEX_MASK;

pub inline fn rvn_handle_index(id: raven.Rid) u32 {
    return id & RVN_HANDLE_INDEX_MASK;
}
pub inline fn rvn_handle_generation(id: raven.Rid) u32 {
    return (id >> RVN_HANDLE_INDEX_BITS) & 0xFF;
}
pub inline fn rvn_handle_type(id: raven.Rid) u32 {
    return id >> 28;
}
pub inline fn rvn_handle_make(type_: u32, generation: u32, index: u32) raven.Rid {
    return (type_ << 28) | ((generation & 0xFF) << RVN_HANDLE_INDEX_BITS) | (index & RVN_HANDLE_INDEX_MASK);
}

pub const rvn_pool_t = extern struct {
    items: [*c]?*anyopaque,
    generations: [*c]u8,
    free_list: [*c]u32,
    cap: u32,
    /// Number of slots ever used (high-water mark).
    used: u32,
    free_count: u32,
    free_cap: u32,
    live: u32,
    type: u32,
};
pub const struct_rvn_pool_t = rvn_pool_t;

pub extern fn rvn_pool_init(pool: [*c]rvn_pool_t, type_: rvn_handle_type_t) void;
pub extern fn rvn_pool_free(pool: [*c]rvn_pool_t) void;
/// Registers an object and returns its handle (R_INVALID_ID when the pool is full).
pub extern fn rvn_pool_add(pool: [*c]rvn_pool_t, object: ?*anyopaque) raven.Rid;
/// Returns the object, or NULL when the handle is stale, deleted or of another type.
pub extern fn rvn_pool_get(pool: [*c]const rvn_pool_t, id: raven.Rid) ?*anyopaque;
pub extern fn rvn_pool_remove(pool: [*c]rvn_pool_t, id: raven.Rid) void;
/// Iteration over live objects: returns the object at slot `index` or NULL.
pub extern fn rvn_pool_at(pool: [*c]const rvn_pool_t, index: u32) ?*anyopaque;
