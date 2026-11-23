// Translated to Zig from vendor/raven/src/core/base.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/base.h
// Included by every source file of the library: public API, C runtime,
// small math helpers, memory, strings and UTF-8.
//
// In a translation:   const base = @import("base_h.zig");   (or "../core/base_h.zig" from another folder)
// The C runtime (stddef, stdint, stdlib, string, stdio, math) is not part of this unit: see sys/libc.zig.
// The macros RVN_INLINE (-> pub inline fn), RVN_UNUSED(x) (-> `_ = x;`) and RVN_COUNT_OF(a) (-> `a.len`)
// have no Zig counterpart.

const raven = @import("raven");

pub const RVN_VERSION_STRING = "0.1.0";

// ---------------------------------------------------------------------------
//  Scalars
// ---------------------------------------------------------------------------

pub inline fn rvn_minf(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}
pub inline fn rvn_maxf(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}
pub inline fn rvn_clampf(v: f32, lo: f32, hi: f32) f32 {
    return if (v < lo) lo else (if (v > hi) hi else v);
}
pub inline fn rvn_mini(a: c_int, b: c_int) c_int {
    return if (a < b) a else b;
}
pub inline fn rvn_maxi(a: c_int, b: c_int) c_int {
    return if (a > b) a else b;
}
pub inline fn rvn_clampi(v: c_int, lo: c_int, hi: c_int) c_int {
    return if (v < lo) lo else (if (v > hi) hi else v);
}
pub inline fn rvn_minu(a: u32, b: u32) u32 {
    return if (a < b) a else b;
}
pub inline fn rvn_maxu(a: u32, b: u32) u32 {
    return if (a > b) a else b;
}

// ---------------------------------------------------------------------------
//  Geometry
// ---------------------------------------------------------------------------

pub const rvn_vec2_t = extern struct { x: f32, y: f32 };
pub const struct_rvn_vec2_t = rvn_vec2_t;
/// Position + size, in logical units.
pub const rvn_rect_t = extern struct { x: f32, y: f32, w: f32, h: f32 };
pub const struct_rvn_rect_t = rvn_rect_t;
/// Left, top, right, bottom thickness.
pub const rvn_margin_t = extern struct { l: f32, t: f32, r: f32, b: f32 };
pub const struct_rvn_margin_t = rvn_margin_t;
/// Min / max corners, in pixels.
pub const rvn_box_t = extern struct { x0: f32, y0: f32, x1: f32, y1: f32 };
pub const struct_rvn_box_t = rvn_box_t;

pub inline fn rvn_vec2(x: f32, y: f32) rvn_vec2_t {
    return .{ .x = x, .y = y };
}
pub inline fn rvn_rect(x: f32, y: f32, w: f32, h: f32) rvn_rect_t {
    return .{ .x = x, .y = y, .w = w, .h = h };
}
pub inline fn rvn_margin(l: f32, t: f32, r: f32, b: f32) rvn_margin_t {
    return .{ .l = l, .t = t, .r = r, .b = b };
}
pub inline fn rvn_box(x0: f32, y0: f32, x1: f32, y1: f32) rvn_box_t {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

pub inline fn rvn_rect_contains(r: rvn_rect_t, x: f32, y: f32) c_int {
    return @intFromBool(x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h);
}
pub inline fn rvn_rect_inset(r: rvn_rect_t, m: rvn_margin_t) rvn_rect_t {
    var o: rvn_rect_t = undefined;
    o.x = r.x + m.l;
    o.y = r.y + m.t;
    o.w = rvn_maxf(0.0, r.w - m.l - m.r);
    o.h = rvn_maxf(0.0, r.h - m.t - m.b);
    return o;
}
pub inline fn rvn_rect_intersect(a: rvn_rect_t, b: rvn_rect_t) rvn_rect_t {
    const x0 = rvn_maxf(a.x, b.x);
    const y0 = rvn_maxf(a.y, b.y);
    const x1 = rvn_minf(a.x + a.w, b.x + b.w);
    const y1 = rvn_minf(a.y + a.h, b.y + b.h);
    return rvn_rect(x0, y0, rvn_maxf(0.0, x1 - x0), rvn_maxf(0.0, y1 - y0));
}
pub inline fn rvn_box_intersect(a: rvn_box_t, b: rvn_box_t) rvn_box_t {
    var o: rvn_box_t = undefined;
    o.x0 = rvn_maxf(a.x0, b.x0);
    o.y0 = rvn_maxf(a.y0, b.y0);
    o.x1 = rvn_minf(a.x1, b.x1);
    o.y1 = rvn_minf(a.y1, b.y1);
    if (o.x1 < o.x0) o.x1 = o.x0;
    if (o.y1 < o.y0) o.y1 = o.y0;
    return o;
}
pub inline fn rvn_box_empty(b: rvn_box_t) c_int {
    return @intFromBool(b.x1 <= b.x0 or b.y1 <= b.y0);
}
pub inline fn rvn_box_overlaps(a: rvn_box_t, b: rvn_box_t) c_int {
    return @intFromBool(a.x0 < b.x1 and a.x1 > b.x0 and a.y0 < b.y1 and a.y1 > b.y0);
}

// ---------------------------------------------------------------------------
//  Colors: packed RGBA8, R in the lowest byte (bytes R, G, B, A in memory on
//  little-endian machines, which is what the backend expects).
// ---------------------------------------------------------------------------

pub const rvn_color_t = u32;

pub inline fn rvn_rgba8(r: u32, g: u32, b: u32, a: u32) rvn_color_t {
    return (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | ((a & 0xFF) << 24);
}
pub inline fn rvn_rgba(r: f32, g: f32, b: f32, a: f32) rvn_color_t {
    return rvn_rgba8(@intFromFloat(rvn_clampf(r, 0.0, 1.0) * 255.0 + 0.5), @intFromFloat(rvn_clampf(g, 0.0, 1.0) * 255.0 + 0.5), @intFromFloat(rvn_clampf(b, 0.0, 1.0) * 255.0 + 0.5), @intFromFloat(rvn_clampf(a, 0.0, 1.0) * 255.0 + 0.5));
}
/// 0xRRGGBB + alpha, convenient for palettes written in hexadecimal.
pub inline fn rvn_hex(rgb: u32, a: u32) rvn_color_t {
    return rvn_rgba8((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF, a);
}
pub inline fn rvn_color_a(c: rvn_color_t) u32 {
    return c >> 24;
}
pub inline fn rvn_color_fade(c: rvn_color_t, opacity: f32) rvn_color_t {
    const a: u32 = @intFromFloat(@as(f32, @floatFromInt(c >> 24)) * rvn_clampf(opacity, 0.0, 1.0) + 0.5);
    return (c & 0x00FFFFFF) | (a << 24);
}
pub inline fn rvn_color_mix(a: rvn_color_t, b: rvn_color_t, t_in: f32) rvn_color_t {
    var out: u32 = 0;
    const t = rvn_clampf(t_in, 0.0, 1.0);
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        const shift: u5 = @intCast(i * 8);
        const ca: f32 = @floatFromInt((a >> shift) & 0xFF);
        const cb: f32 = @floatFromInt((b >> shift) & 0xFF);
        const channel: u32 = @intFromFloat(ca + (cb - ca) * t + 0.5);
        out |= (channel & 0xFF) << shift;
    }
    return out;
}
pub inline fn rvn_color_to_floats(c: rvn_color_t, r: [*c]f32, g: [*c]f32, b: [*c]f32, a: [*c]f32) void {
    if (r != null) r.* = @as(f32, @floatFromInt(c & 0xFF)) / 255.0;
    if (g != null) g.* = @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0;
    if (b != null) b.* = @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0;
    if (a != null) a.* = @as(f32, @floatFromInt((c >> 24) & 0xFF)) / 255.0;
}

// ---------------------------------------------------------------------------
//  Memory (core/memory.c)
// ---------------------------------------------------------------------------

pub extern fn rvn_alloc(size: usize) ?*anyopaque;
/// Zero-initialized allocation.
pub extern fn rvn_calloc(size: usize) ?*anyopaque;
pub extern fn rvn_realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
pub extern fn rvn_free(ptr: ?*anyopaque) void;

/// Grows a dynamic array to hold at least `needed` items. Returns the new storage.
pub extern fn rvn_array_grow_(data: ?*anyopaque, cap: [*c]u32, needed: u32, item_size: usize) ?*anyopaque;
/// RVN_ARRAY_RESERVE(data, cap, needed): C assigns to its first argument, so here the first argument
/// is a pointer to the data pointer:  RVN_ARRAY_RESERVE(&list.items, &list.cap, list.count + 1);
pub inline fn RVN_ARRAY_RESERVE(data: anytype, cap: [*c]u32, needed: anytype) void {
    const Item = @typeInfo(@typeInfo(@TypeOf(data)).pointer.child).pointer.child;
    const n: u32 = @intCast(needed);
    if (n > cap.*) data.* = @ptrCast(@alignCast(rvn_array_grow_(data.*, cap, n, @sizeOf(Item))));
}

/// Chunked bump allocator: everything is released at once.
pub const rvn_arena_block_t = extern struct {
    next: [*c]rvn_arena_block_t,
    cap: usize,
    used: usize,
};
pub const struct_rvn_arena_block_t = rvn_arena_block_t;

pub const rvn_arena_t = extern struct {
    head: [*c]rvn_arena_block_t,
    current: [*c]rvn_arena_block_t,
    block_size: usize,
};
pub const struct_rvn_arena_t = rvn_arena_t;

pub extern fn rvn_arena_init(arena: [*c]rvn_arena_t, block_size: usize) void;
pub extern fn rvn_arena_alloc(arena: [*c]rvn_arena_t, size: usize) ?*anyopaque;
pub extern fn rvn_arena_strndup(arena: [*c]rvn_arena_t, text: [*c]const u8, length: usize) [*c]u8;
pub extern fn rvn_arena_free(arena: [*c]rvn_arena_t) void;

// ---------------------------------------------------------------------------
//  Strings (core/memory.c) and UTF-8 (core/utf8.c)
// ---------------------------------------------------------------------------

pub extern fn rvn_strdup(text: [*c]const u8) [*c]u8;
pub extern fn rvn_strndup(text: [*c]const u8, length: usize) [*c]u8;
/// Replaces *dst with a copy of src (NULL clears it). Returns R_TRUE when the text changed.
pub extern fn rvn_str_set(dst: [*c][*c]u8, src: [*c]const u8) c_int;
pub extern fn rvn_stricmp(a: [*c]const u8, b: [*c]const u8) c_int;
pub extern fn rvn_strnicmp(a: [*c]const u8, b: [*c]const u8, n: usize) c_int;
/// A text that grows. `data` is NULL while empty, else always null-terminated. Free with rvn_free(data).
pub const rvn_text_t = extern struct {
    data: [*c]u8,
    length: usize,
    cap: usize,
};
pub const struct_rvn_text_t = rvn_text_t;
pub extern fn rvn_text_append(text: [*c]rvn_text_t, bytes: [*c]const u8, length: usize) void;
pub extern fn rvn_text_add(text: [*c]rvn_text_t, string: [*c]const u8) void;
pub extern fn rvn_text_printf(text: [*c]rvn_text_t, format: [*c]const u8, ...) void;
pub extern fn rvn_hash_bytes(data: ?*const anyopaque, size: usize) u32;
pub extern fn rvn_hash_str(text: [*c]const u8) u32;
/// Reads a whole file. The result has one extra '\0' byte. Free with rvn_free.
pub extern fn rvn_read_file(path: [*c]const u8, size: [*c]usize) [*c]u8;
/// R_TRUE when the path names a file registered with Rfile_register_memory.
pub extern fn rvn_memory_file_exists(path: [*c]const u8) c_int;
/// Forgets every file held in memory (Rshutdown).
pub extern fn rvn_memory_files_shutdown() void;
/// Joins a base folder and a relative path. Free with rvn_free.
pub extern fn rvn_path_join(base: [*c]const u8, path: [*c]const u8) [*c]u8;
/// Folder part of a path, with its trailing separator. Free with rvn_free.
pub extern fn rvn_path_dir(path: [*c]const u8) [*c]u8;

/// Decodes one code point and advances *text. Invalid bytes give U+FFFD.
pub extern fn rvn_utf8_decode(text: [*c][*c]const u8, end: [*c]const u8) u32;
/// Writes 1..4 bytes and returns how many.
pub extern fn rvn_utf8_encode(codepoint: u32, out: [*c]u8) c_int;
/// Byte offset of the character boundary after / before `offset`.
pub extern fn rvn_utf8_next(text: [*c]const u8, length: c_int, offset: c_int) c_int;
pub extern fn rvn_utf8_prev(text: [*c]const u8, offset: c_int) c_int;
pub extern fn rvn_utf8_count(text: [*c]const u8, length: c_int) c_int;

// ---------------------------------------------------------------------------
//  Errors (core/error.c)
// ---------------------------------------------------------------------------

/// Records an error and calls the error callback. Thread-safe, printf-style.
pub extern fn rvn_error(code: raven.RError, severity: raven.RSeverity, format: [*c]const u8, ...) void;
