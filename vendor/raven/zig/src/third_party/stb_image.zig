// Translated to Zig from vendor/raven/third_party/stb/stb_image.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// stb_image - v2.30 - public domain image loader - http://nothings.org/stb
//
// This file is the Zig translation of stb_image.h for the configuration Raven compiles
// (src/render/image_decode.c):
//
//     STBI_NO_STDIO, STBI_NO_HDR, STBI_NO_LINEAR, STBI_NO_FAILURE_STRINGS,
//     STBI_MALLOC = rvn_alloc, STBI_REALLOC = rvn_realloc, STBI_FREE = rvn_free,
//     STB_IMAGE_STATIC (the STBIDEF functions are `static` in C).
//
// The whole implementation is translated: the memory and callback loaders, the
// PNG (zlib inflate, filters, interlace, palette, tRNS, 1..16 bit), JPEG (baseline and
// progressive Huffman, IDCT, upsampling, YCbCr), GIF, PSD, PIC, PNM, BMP and TGA decoders,
// the info / is_16_bit queries of those formats, and the generic load / convert / flip code.
// Only HDR and the stdio / LINEAR variants are left out (disabled by the C configuration).
// The x86 SIMD branches of the C file (STBI_SSE2) are not translated: the scalar code
// of the same functions is used, as with STBI_NO_SIMD.
// STBI_ASSERT is not translated (assert() in the C build; its conditions are internal
// consistency checks).
// Every function is a `fn` or `pub fn`, with no `export`: the C build compiles stb_image with
// STB_IMAGE_STATIC, so the STBIDEF functions are `static` there and the library exports none
// of them. The two entry points used by src/render/image_decode.zig are `pub fn`
// (stbi_load_from_memory, stbi_info_from_memory); they are not `export`ed, so the object
// still exports no symbols, as the C build does.
//
// Recorded deviation (PORTING.md rule 3.5): where the C code relies on signed int arithmetic
// that may overflow on corrupt input (undefined behaviour in C), the Zig code uses the
// wrapping operators `+%`, `-%`, `*%` with two's-complement results, as typical C compilers
// do on the supported targets. This keeps corrupt files from trapping in the ReleaseSafe build.
// The sites are: the JPEG IDCT (stbi__idct_block, fixed-point butterflies and final shifts),
// stbi__f2f / stbi__fsh, the progressive JPEG DC refinement (stbi__jpeg_decode_block_prog_dc),
// the sign-extension bias in stbi__extend_receive, the Huffman
// code-length table construction (stbi__build_huffman), and the PNM digit accumulation
// (stbi__pnm_getinteger). Unsigned wrapping (`+%` on c_uint, e.g. stbi__zexpand) is defined in C
// and needs no note. Output on valid files is unaffected.

const std = @import("std");
const base = @import("../core/base_h.zig");

// ---- types and constants of the header ----

pub const stbi_uc = u8;
pub const stbi_us = c_ushort;

pub const STBI_default: c_int = 0; // only used for desired_channels
pub const STBI_grey: c_int = 1;
pub const STBI_grey_alpha: c_int = 2;
pub const STBI_rgb: c_int = 3;
pub const STBI_rgb_alpha: c_int = 4;

/// typedef struct { int (*read)(void*, char*, int); void (*skip)(void*, int); int (*eof)(void*); } stbi_io_callbacks;
pub const stbi_io_callbacks = extern struct {
    read: ?*const fn (user: ?*anyopaque, data: [*c]u8, size: c_int) callconv(.c) c_int,
    skip: ?*const fn (user: ?*anyopaque, n: c_int) callconv(.c) void,
    eof: ?*const fn (user: ?*anyopaque) callconv(.c) c_int,
};

// ---- implementation types (the STB_IMAGE_IMPLEMENTATION part) ----

pub const stbi__uint16 = u16;
pub const stbi__int16 = i16;
pub const stbi__uint32 = u32;
pub const stbi__int32 = i32;

comptime {
    // typedef unsigned char validate_uint32[sizeof(stbi__uint32)==4 ? 1 : -1];
    std.debug.assert(@sizeOf(stbi__uint32) == 4);
}

const STBI_ORDER_RGB: c_int = 0;
const STBI_ORDER_BGR: c_int = 1;

/// stbi__context: the basic context of every image: IO state plus image information.
pub const stbi__context = extern struct {
    img_x: stbi__uint32,
    img_y: stbi__uint32,
    img_n: c_int,
    img_out_n: c_int,

    io: stbi_io_callbacks,
    io_user_data: ?*anyopaque,

    read_from_callbacks: c_int,
    buflen: c_int,
    buffer_start: [128]stbi_uc,
    callback_already_read: c_int,

    img_buffer: [*c]stbi_uc,
    img_buffer_end: [*c]stbi_uc,
    img_buffer_original: [*c]stbi_uc,
    img_buffer_original_end: [*c]stbi_uc,
};

pub const stbi__result_info = extern struct {
    bits_per_channel: c_int,
    num_channels: c_int,
    channel_order: c_int,
};

// stbi__g_failure_reason: STBI_NO_FAILURE_STRINGS, so it is never set (stbi__err is 0).
threadlocal var stbi__g_failure_reason: [*c]const u8 = null;

/// STBIDEF const char *stbi_failure_reason(void)
fn stbi_failure_reason() [*c]const u8 {
    return stbi__g_failure_reason;
}

// stbi__err(x, y) is the macro `0` under STBI_NO_FAILURE_STRINGS.
inline fn stbi__err(x: anytype, y: anytype) c_int {
    _ = x;
    _ = y;
    return 0;
}

// stbi__errpuc(x, y) is `(unsigned char*)NULL` under STBI_NO_FAILURE_STRINGS.
inline fn stbi__errpuc(x: anytype, y: anytype) [*c]stbi_uc {
    _ = x;
    _ = y;
    return null;
}

// stbi__errpf(x, y) is `(float*)NULL` under STBI_NO_FAILURE_STRINGS.
inline fn stbi__errpf(x: anytype, y: anytype) [*c]f32 {
    _ = x;
    _ = y;
    return null;
}

// initialize a memory-decode context
fn stbi__start_mem(s: [*c]stbi__context, buffer: [*c]const stbi_uc, len: c_int) void {
    s.*.io.read = null;
    s.*.read_from_callbacks = 0;
    s.*.callback_already_read = 0;
    s.*.img_buffer = @constCast(buffer);
    s.*.img_buffer_original = @constCast(buffer);
    s.*.img_buffer_end = @constCast(buffer) + @as(usize, @intCast(len));
    s.*.img_buffer_original_end = s.*.img_buffer_end;
}

// initialize a callback-based context
fn stbi__start_callbacks(s: [*c]stbi__context, clbk: [*c]const stbi_io_callbacks, user: ?*anyopaque) void {
    s.*.io = clbk.*;
    s.*.io_user_data = user;
    s.*.buflen = @sizeOf(@TypeOf(s.*.buffer_start));
    s.*.read_from_callbacks = 1;
    s.*.callback_already_read = 0;
    s.*.img_buffer = &s.*.buffer_start;
    s.*.img_buffer_original = &s.*.buffer_start;
    stbi__refill_buffer(s);
    s.*.img_buffer_original_end = s.*.img_buffer_end;
}

fn stbi__rewind(s: [*c]stbi__context) void {
    // conceptually rewind SHOULD rewind to the beginning of the stream,
    // but we just rewind to the beginning of the initial buffer, because
    // we only use it after doing 'test', which only ever looks at at most 92 bytes
    s.*.img_buffer = s.*.img_buffer_original;
    s.*.img_buffer_end = s.*.img_buffer_original_end;
}

// stb_image uses ints pervasively, including for offset calculations.
// therefore the largest decoded image size we can support with the
// current code, even on 64-bit targets, is INT_MAX. this is not a
// significant limitation for the intended use case.
//
// we do, however, need to make sure our size calculations don't
// overflow. hence a few helper functions for size calculations that
// multiply integers together, making sure that they're non-negative
// and no overflow occurs.

// return 1 if the sum is valid, 0 on overflow.
// negative terms are considered invalid.
fn stbi__addsizes_valid(a: c_int, b: c_int) c_int {
    if (b < 0) return 0;
    // now 0 <= b <= INT_MAX, hence also
    // 0 <= INT_MAX - b <= INTMAX.
    // And "a + b <= INT_MAX" (which might overflow) is the
    // same as a <= INT_MAX - b (no overflow)
    return if (a <= std.math.maxInt(c_int) - b) 1 else 0;
}

// returns 1 if the product is valid, 0 on overflow.
// negative factors are considered invalid.
fn stbi__mul2sizes_valid(a: c_int, b: c_int) c_int {
    if (a < 0 or b < 0) return 0;
    if (b == 0) return 1; // mul-by-0 is always safe
    // portable way to check for no overflows in a*b
    return if (a <= @divTrunc(std.math.maxInt(c_int), b)) 1 else 0;
}

// returns 1 if "a*b + add" has no negative terms/factors and doesn't overflow
fn stbi__mad2sizes_valid(a: c_int, b: c_int, add: c_int) c_int {
    return @intFromBool(stbi__mul2sizes_valid(a, b) != 0 and stbi__addsizes_valid(a * b, add) != 0);
}

// returns 1 if "a*b*c + add" has no negative terms/factors and doesn't overflow
fn stbi__mad3sizes_valid(a: c_int, b: c_int, c: c_int, add: c_int) c_int {
    return @intFromBool(stbi__mul2sizes_valid(a, b) != 0 and stbi__mul2sizes_valid(a * b, c) != 0 and
        stbi__addsizes_valid(a * b * c, add) != 0);
}

// mallocs with size overflow checking
fn stbi__malloc_mad2(a: c_int, b: c_int, add: c_int) ?*anyopaque {
    if (stbi__mad2sizes_valid(a, b, add) == 0) return null;
    return stbi__malloc(@intCast(a * b + add));
}

fn stbi__malloc_mad3(a: c_int, b: c_int, c: c_int, add: c_int) ?*anyopaque {
    if (stbi__mad3sizes_valid(a, b, c, add) == 0) return null;
    return stbi__malloc(@intCast(a * b * c + add));
}

// returns 1 if "a*b*c*d + add" has no negative terms/factors and doesn't overflow
fn stbi__mad4sizes_valid(a: c_int, b: c_int, c: c_int, d: c_int, add: c_int) c_int {
    return @intFromBool(stbi__mul2sizes_valid(a, b) != 0 and stbi__mul2sizes_valid(a * b, c) != 0 and
        stbi__mul2sizes_valid(a * b * c, d) != 0 and stbi__addsizes_valid(a * b * c * d, add) != 0);
}

// C converts a float to an integer with `(T)f`, which is undefined for values outside the
// range of T. The C build (x86-64) converts through a 32-bit int first (cvttss2si), which gives
// INT_MIN for out-of-range values and NaN; this keeps the same result without a safety trap.
fn stbi__float_to_int32(v: f32) c_int {
    if (!(v >= -2147483648.0 and v < 2147483648.0)) return std.math.minInt(c_int);
    return @intFromFloat(v);
}

// mallocs with size overflow checking
fn stbi__malloc_mad4(a: c_int, b: c_int, c: c_int, d: c_int, add: c_int) ?*anyopaque {
    if (stbi__mad4sizes_valid(a, b, c, d, add) == 0) return null;
    return stbi__malloc(@intCast(a * b * c * d + add));
}

fn stbi__malloc(size: usize) ?*anyopaque {
    return base.rvn_alloc(size); // STBI_MALLOC(size)
}

// returns 1 if the sum of two signed ints is valid (between -2^31 and 2^31-1 inclusive), 0 on overflow.
fn stbi__addints_valid(a: c_int, b: c_int) c_int {
    if ((a >= 0) != (b >= 0)) return 1; // a and b have different signs, so no overflow
    if (a < 0 and b < 0) return @intFromBool(a >= std.math.minInt(c_int) - b); // same as a + b >= INT_MIN; INT_MIN - b cannot overflow since b < 0.
    return @intFromBool(a <= std.math.maxInt(c_int) - b);
}

// returns 1 if the product of two ints fits in a signed short, 0 on overflow.
fn stbi__mul2shorts_valid(a: c_int, b: c_int) c_int {
    if (b == 0 or b == -1) return 1; // multiplication by 0 is always 0; check for -1 so SHRT_MIN/b doesn't overflow
    if ((a >= 0) == (b >= 0)) return @intFromBool(a <= @divTrunc(std.math.maxInt(c_short), b)); // product is positive, so similar to mul2sizes_valid
    if (b < 0) return @intFromBool(a <= @divTrunc(std.math.minInt(c_short), b)); // same as a * b >= SHRT_MIN
    return @intFromBool(a >= @divTrunc(std.math.minInt(c_short), b));
}

/// STBIDEF void stbi_image_free(void *retval_from_stbi_load)
fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void {
    base.rvn_free(retval_from_stbi_load); // STBI_FREE(p)
}

var stbi__vertically_flip_on_load_global: c_int = 0;

/// STBIDEF void stbi_set_flip_vertically_on_load(int flag_true_if_should_flip)
fn stbi_set_flip_vertically_on_load(flag_true_if_should_flip: c_int) void {
    stbi__vertically_flip_on_load_global = flag_true_if_should_flip;
}

// STBI_THREAD_LOCAL (_Thread_local) variables: the _thread variant is used.
threadlocal var stbi__vertically_flip_on_load_local: c_int = 0;
threadlocal var stbi__vertically_flip_on_load_set: c_int = 0;

/// STBIDEF void stbi_set_flip_vertically_on_load_thread(int flag_true_if_should_flip)
fn stbi_set_flip_vertically_on_load_thread(flag_true_if_should_flip: c_int) void {
    stbi__vertically_flip_on_load_local = flag_true_if_should_flip;
    stbi__vertically_flip_on_load_set = 1;
}

// #define stbi__vertically_flip_on_load (...the thread-local choice...)
inline fn stbi__vertically_flip_on_load() c_int {
    return if (stbi__vertically_flip_on_load_set != 0)
        stbi__vertically_flip_on_load_local
    else
        stbi__vertically_flip_on_load_global;
}


// ---- byte readers, the generic loader and the postprocessing ----

fn stbi__refill_buffer(s: [*c]stbi__context) void {
    const n: c_int = s.*.io.read.?(s.*.io_user_data, &s.*.buffer_start, s.*.buflen);
    s.*.callback_already_read += @as(c_int, @intCast(s.*.img_buffer - s.*.img_buffer_original));
    if (n == 0) {
        // at end of file, treat same as if from memory, but need to handle case
        // where s->img_buffer isn't pointing to safe memory, e.g. 0-byte file
        s.*.read_from_callbacks = 0;
        const bs: [*c]stbi_uc = &s.*.buffer_start;
        s.*.img_buffer = bs;
        s.*.img_buffer_end = bs + 1;
        s.*.img_buffer[0] = 0;
    } else {
        const bs: [*c]stbi_uc = &s.*.buffer_start;
        s.*.img_buffer = bs;
        s.*.img_buffer_end = bs + @as(usize, @intCast(n));
    }
}

inline fn stbi__get8(s: [*c]stbi__context) stbi_uc {
    if (s.*.img_buffer < s.*.img_buffer_end) {
        const v = s.*.img_buffer[0];
        s.*.img_buffer += 1;
        return v;
    }
    if (s.*.read_from_callbacks != 0) {
        stbi__refill_buffer(s);
        const v = s.*.img_buffer[0];
        s.*.img_buffer += 1;
        return v;
    }
    return 0;
}

inline fn stbi__at_eof(s: [*c]stbi__context) c_int {
    if (s.*.io.read != null) {
        if (s.*.io.eof.?(s.*.io_user_data) == 0) return 0;
        // if feof() is true, check if buffer = end
        // special case: we've only got the special 0 character at the end
        if (s.*.read_from_callbacks == 0) return 1;
    }
    return @intFromBool(s.*.img_buffer >= s.*.img_buffer_end);
}

fn stbi__skip(s: [*c]stbi__context, n: c_int) void {
    if (n == 0) return; // already there!
    if (n < 0) {
        s.*.img_buffer = s.*.img_buffer_end;
        return;
    }
    if (s.*.io.read != null) {
        const blen: c_int = @intCast(s.*.img_buffer_end - s.*.img_buffer);
        if (blen < n) {
            s.*.img_buffer = s.*.img_buffer_end;
            s.*.io.skip.?(s.*.io_user_data, n - blen);
            return;
        }
    }
    s.*.img_buffer += @as(usize, @intCast(n));
}

fn stbi__getn(s: [*c]stbi__context, buffer: [*c]stbi_uc, n: c_int) c_int {
    if (s.*.io.read != null) {
        const blen: c_int = @intCast(s.*.img_buffer_end - s.*.img_buffer);
        if (blen < n) {
            @memcpy(buffer[0..@as(usize, @intCast(blen))], s.*.img_buffer[0..@as(usize, @intCast(blen))]); // memcpy(buffer, s->img_buffer, blen)
            const count: c_int = s.*.io.read.?(s.*.io_user_data, buffer + @as(usize, @intCast(blen)), n - blen);
            const res: c_int = @intFromBool(count == (n - blen));
            s.*.img_buffer = s.*.img_buffer_end;
            return res;
        }
    }
    const un: usize = @intCast(n);
    if (@intFromPtr(s.*.img_buffer) + un <= @intFromPtr(s.*.img_buffer_end)) {
        @memcpy(buffer[0..un], s.*.img_buffer[0..un]);
        s.*.img_buffer += un;
        return 1;
    } else return 0;
}

fn stbi__get16be(s: [*c]stbi__context) c_int {
    const z: c_int = stbi__get8(s);
    return (z << 8) + stbi__get8(s);
}

fn stbi__get32be(s: [*c]stbi__context) stbi__uint32 {
    const z: stbi__uint32 = @intCast(stbi__get16be(s));
    return (z << 16) + @as(stbi__uint32, @intCast(stbi__get16be(s)));
}

fn stbi__get16le(s: [*c]stbi__context) c_int {
    const z: c_int = stbi__get8(s);
    return z + (@as(c_int, stbi__get8(s)) << 8);
}

fn stbi__get32le(s: [*c]stbi__context) stbi__uint32 {
    var z: stbi__uint32 = @intCast(stbi__get16le(s));
    z += @as(stbi__uint32, @intCast(stbi__get16le(s))) << 16;
    return z;
}

inline fn STBI__BYTECAST(x: c_int) stbi_uc {
    return @truncate(@as(c_uint, @bitCast(x)) & 255); // truncate int to byte without warnings
}

fn stbi__compute_y(r: c_int, g: c_int, b: c_int) stbi_uc {
    return @truncate(@as(c_uint, @bitCast((r * 77) + (g * 150) + (29 * b))) >> 8);
}

fn stbi__convert_format(data: [*c]u8, img_n: c_int, req_comp: c_int, x: c_uint, y: c_uint) [*c]u8 {
    var i: c_int = undefined;
    var j: c_int = undefined;
    var good: [*c]u8 = undefined;

    if (req_comp == img_n) return data;
    // STBI_ASSERT(req_comp >= 1 && req_comp <= 4);

    good = @ptrCast(@alignCast(stbi__malloc_mad3(req_comp, @intCast(x), @intCast(y), 0)));
    if (good == null) {
        base.rvn_free(data);
        return stbi__errpuc("outofmem", "Out of memory");
    }

    j = 0;
    while (j < @as(c_int, @intCast(y))) : (j += 1) {
        const ju: usize = @intCast(j);
        var src: [*c]u8 = data + ju * @as(usize, x) * @as(usize, @intCast(img_n));
        var dest: [*c]u8 = good + ju * @as(usize, x) * @as(usize, @intCast(req_comp));
        // convert source image with img_n components to one with req_comp components;
        // avoid switch per pixel, so use switch per scanline
        // STBI__CASE(a,b): for(i=x-1; i >= 0; --i, src += a, dest += b)
        switch (img_n * 8 + req_comp) {
            1 * 8 + 2 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 1;
                    dest += 2;
                }) {
                    dest[0] = src[0];
                    dest[1] = 255;
                }
            },
            1 * 8 + 3 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 1;
                    dest += 3;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[0];
                    dest[2] = src[0];
                }
            },
            1 * 8 + 4 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 1;
                    dest += 4;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[0];
                    dest[2] = src[0];
                    dest[3] = 255;
                }
            },
            2 * 8 + 1 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 2;
                    dest += 1;
                }) {
                    dest[0] = src[0];
                }
            },
            2 * 8 + 3 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 2;
                    dest += 3;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[0];
                    dest[2] = src[0];
                }
            },
            2 * 8 + 4 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 2;
                    dest += 4;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[0];
                    dest[2] = src[0];
                    dest[3] = src[1];
                }
            },
            3 * 8 + 4 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 3;
                    dest += 4;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[1];
                    dest[2] = src[2];
                    dest[3] = 255;
                }
            },
            3 * 8 + 1 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 3;
                    dest += 1;
                }) {
                    dest[0] = stbi__compute_y(src[0], src[1], src[2]);
                }
            },
            3 * 8 + 2 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 3;
                    dest += 2;
                }) {
                    dest[0] = stbi__compute_y(src[0], src[1], src[2]);
                    dest[1] = 255;
                }
            },
            4 * 8 + 1 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 4;
                    dest += 1;
                }) {
                    dest[0] = stbi__compute_y(src[0], src[1], src[2]);
                }
            },
            4 * 8 + 2 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 4;
                    dest += 2;
                }) {
                    dest[0] = stbi__compute_y(src[0], src[1], src[2]);
                    dest[1] = src[3];
                }
            },
            4 * 8 + 3 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 4;
                    dest += 3;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[1];
                    dest[2] = src[2];
                }
            },
            else => {
                // STBI_ASSERT(0); STBI_FREE(data); STBI_FREE(good);
                base.rvn_free(data);
                base.rvn_free(good);
                return stbi__errpuc("unsupported", "Unsupported format conversion");
            },
        }
    }

    base.rvn_free(data);
    return good;
}

fn stbi__compute_y_16(r: c_int, g: c_int, b: c_int) stbi__uint16 {
    return @truncate(@as(c_uint, @bitCast((r * 77) + (g * 150) + (29 * b))) >> 8);
}

fn stbi__convert_format16(data: [*c]stbi__uint16, img_n: c_int, req_comp: c_int, x: c_uint, y: c_uint) [*c]stbi__uint16 {
    var i: c_int = undefined;
    var j: c_int = undefined;
    var good: [*c]stbi__uint16 = undefined;

    if (req_comp == img_n) return data;
    // STBI_ASSERT(req_comp >= 1 && req_comp <= 4);

    good = @ptrCast(@alignCast(stbi__malloc(@as(usize, @intCast(req_comp)) * @as(usize, x) * @as(usize, y) * 2)));
    if (good == null) {
        base.rvn_free(data);
        return null;
    }

    j = 0;
    while (j < @as(c_int, @intCast(y))) : (j += 1) {
        const ju: usize = @intCast(j);
        var src: [*c]stbi__uint16 = data + ju * @as(usize, x) * @as(usize, @intCast(img_n));
        var dest: [*c]stbi__uint16 = good + ju * @as(usize, x) * @as(usize, @intCast(req_comp));
        switch (img_n * 8 + req_comp) {
            1 * 8 + 2 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 1;
                    dest += 2;
                }) {
                    dest[0] = src[0];
                    dest[1] = 0xffff;
                }
            },
            1 * 8 + 3 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 1;
                    dest += 3;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[0];
                    dest[2] = src[0];
                }
            },
            1 * 8 + 4 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 1;
                    dest += 4;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[0];
                    dest[2] = src[0];
                    dest[3] = 0xffff;
                }
            },
            2 * 8 + 1 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 2;
                    dest += 1;
                }) {
                    dest[0] = src[0];
                }
            },
            2 * 8 + 3 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 2;
                    dest += 3;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[0];
                    dest[2] = src[0];
                }
            },
            2 * 8 + 4 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 2;
                    dest += 4;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[0];
                    dest[2] = src[0];
                    dest[3] = src[1];
                }
            },
            3 * 8 + 4 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 3;
                    dest += 4;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[1];
                    dest[2] = src[2];
                    dest[3] = 0xffff;
                }
            },
            3 * 8 + 1 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 3;
                    dest += 1;
                }) {
                    dest[0] = stbi__compute_y_16(src[0], src[1], src[2]);
                }
            },
            3 * 8 + 2 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 3;
                    dest += 2;
                }) {
                    dest[0] = stbi__compute_y_16(src[0], src[1], src[2]);
                    dest[1] = 0xffff;
                }
            },
            4 * 8 + 1 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 4;
                    dest += 1;
                }) {
                    dest[0] = stbi__compute_y_16(src[0], src[1], src[2]);
                }
            },
            4 * 8 + 2 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 4;
                    dest += 2;
                }) {
                    dest[0] = stbi__compute_y_16(src[0], src[1], src[2]);
                    dest[1] = src[3];
                }
            },
            4 * 8 + 3 => {
                i = @as(c_int, @intCast(x)) - 1;
                while (i >= 0) : ({
                    i -= 1;
                    src += 4;
                    dest += 3;
                }) {
                    dest[0] = src[0];
                    dest[1] = src[1];
                    dest[2] = src[2];
                }
            },
            else => {
                base.rvn_free(data);
                base.rvn_free(good);
                return null;
            },
        }
    }

    base.rvn_free(data);
    return good;
}

// ---- flip, format conversion of the whole image, the load entry points ----

fn stbi__convert_16_to_8(orig: [*c]stbi__uint16, w: c_int, h: c_int, channels: c_int) [*c]stbi_uc {
    var i: c_int = 0;
    const img_len: c_int = w * h * channels;

    const reduced: [*c]stbi_uc = @ptrCast(@alignCast(stbi__malloc(@intCast(img_len))));
    if (reduced == null) return stbi__errpuc("outofmem", "Out of memory");

    while (i < img_len) : (i += 1) {
        reduced[@intCast(i)] = @truncate((orig[@intCast(i)] >> 8) & 0xFF); // top half of each byte is sufficient approx of 16->8 bit scaling
    }

    base.rvn_free(orig);
    return reduced;
}

fn stbi__convert_8_to_16(orig: [*c]stbi_uc, w: c_int, h: c_int, channels: c_int) [*c]stbi__uint16 {
    var i: c_int = 0;
    const img_len: c_int = w * h * channels;

    const enlarged: [*c]stbi__uint16 = @ptrCast(@alignCast(stbi__malloc(@intCast(img_len * 2))));
    if (enlarged == null) return null; // (stbi__uint16 *) stbi__errpuc("outofmem", "Out of memory")

    while (i < img_len) : (i += 1) {
        // replicate to high and low byte, maps 0->0, 255->0xffff
        enlarged[@intCast(i)] = @intCast((@as(c_int, orig[@intCast(i)]) << 8) + orig[@intCast(i)]);
    }

    base.rvn_free(orig);
    return enlarged;
}

fn stbi__vertical_flip(image: ?*anyopaque, w: c_int, h: c_int, bytes_per_pixel: c_int) void {
    var row: c_int = 0;
    const bytes_per_row: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(bytes_per_pixel));
    var temp: [2048]stbi_uc = undefined;
    const bytes: [*c]stbi_uc = @ptrCast(@alignCast(image));

    while (row < (h >> 1)) : (row += 1) {
        var row0: [*c]stbi_uc = bytes + @as(usize, @intCast(row)) * bytes_per_row;
        var row1: [*c]stbi_uc = bytes + @as(usize, @intCast(h - row - 1)) * bytes_per_row;
        // swap row0 with row1
        var bytes_left: usize = bytes_per_row;
        while (bytes_left != 0) {
            const bytes_copy: usize = if (bytes_left < temp.len) bytes_left else temp.len;
            @memcpy(temp[0..bytes_copy], row0[0..bytes_copy]);
            @memcpy(row0[0..bytes_copy], row1[0..bytes_copy]);
            @memcpy(row1[0..bytes_copy], temp[0..bytes_copy]);
            row0 += bytes_copy;
            row1 += bytes_copy;
            bytes_left -= bytes_copy;
        }
    }
}

fn stbi__load_main(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info, bpc: c_int) ?*anyopaque {
    ri.* = std.mem.zeroes(stbi__result_info); // make sure it's initialized if we add new fields
    ri.*.bits_per_channel = 8; // default is 8 so most paths don't have to be changed
    ri.*.channel_order = STBI_ORDER_RGB; // all current input & output are this, but this is here so we can add BGR order
    ri.*.num_channels = 0;

    // test the formats with a very explicit header first (at least a FOURCC
    // or distinctive magic number first)
    if (stbi__png_test(s) != 0) return stbi__png_load(s, x, y, comp, req_comp, ri);
    if (stbi__bmp_test(s) != 0) return stbi__bmp_load(s, x, y, comp, req_comp, ri);
    if (stbi__gif_test(s) != 0) return stbi__gif_load(s, x, y, comp, req_comp, ri);
    if (stbi__psd_test(s) != 0) return stbi__psd_load(s, x, y, comp, req_comp, ri, bpc);
    if (stbi__pic_test(s) != 0) return stbi__pic_load(s, x, y, comp, req_comp, ri);

    // then the formats that can end up attempting to load with just 1 or 2
    // bytes matching expectations; these are prone to false positives, so
    // try them later
    if (stbi__jpeg_test(s) != 0) return stbi__jpeg_load(s, x, y, comp, req_comp, ri);
    if (stbi__pnm_test(s) != 0) return stbi__pnm_load(s, x, y, comp, req_comp, ri);

    // test tga last because it's a crappy test!
    if (stbi__tga_test(s) != 0) return stbi__tga_load(s, x, y, comp, req_comp, ri);

    return stbi__errpuc("unknown image type", "Image not of any known type, or corrupt"); // stbi__errpuc: NULL
}

fn stbi__load_and_postprocess_8bit(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int) [*c]stbi_uc {
    var ri: stbi__result_info = undefined;
    var result: ?*anyopaque = stbi__load_main(s, x, y, comp, req_comp, &ri, 8);

    if (result == null) return null;

    // it is the responsibility of the loaders to make sure we get either 8 or 16 bit.
    // STBI_ASSERT(ri.bits_per_channel == 8 || ri.bits_per_channel == 16);

    if (ri.bits_per_channel != 8) {
        const channels: c_int = if (req_comp == 0) comp.* else req_comp;
        result = stbi__convert_16_to_8(@ptrCast(@alignCast(result)), x.*, y.*, channels);
        ri.bits_per_channel = 8;
    }

    // @TODO: move stbi__convert_format to here

    if (stbi__vertically_flip_on_load() != 0) {
        const channels: c_int = if (req_comp != 0) req_comp else comp.*;
        stbi__vertical_flip(result, x.*, y.*, channels * @as(c_int, @sizeOf(stbi_uc)));
    }

    return @ptrCast(@alignCast(result));
}

fn stbi__load_and_postprocess_16bit(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int) [*c]stbi__uint16 {
    var ri: stbi__result_info = undefined;
    var result: ?*anyopaque = stbi__load_main(s, x, y, comp, req_comp, &ri, 16);

    if (result == null) return null;

    // it is the responsibility of the loaders to make sure we get either 8 or 16 bit.
    // STBI_ASSERT(ri.bits_per_channel == 8 || ri.bits_per_channel == 16);

    if (ri.bits_per_channel != 16) {
        const channels: c_int = if (req_comp == 0) comp.* else req_comp;
        result = stbi__convert_8_to_16(@ptrCast(@alignCast(result)), x.*, y.*, channels);
        ri.bits_per_channel = 16;
    }

    // @TODO: move stbi__convert_format16 to here
    // @TODO: special case RGB-to-Y (and RGBA-to-YA) for 8-bit-to-16-bit case to keep more precision

    if (stbi__vertically_flip_on_load() != 0) {
        const channels: c_int = if (req_comp != 0) req_comp else comp.*;
        stbi__vertical_flip(result, x.*, y.*, channels * @as(c_int, @sizeOf(stbi__uint16)));
    }

    return @ptrCast(@alignCast(result));
}

/// STBIDEF stbi_us *stbi_load_16_from_memory(...)
fn stbi_load_16_from_memory(buffer: [*c]const stbi_uc, len: c_int, x: [*c]c_int, y: [*c]c_int, channels_in_file: [*c]c_int, desired_channels: c_int) [*c]stbi_us {
    var s: stbi__context = undefined;
    stbi__start_mem(&s, buffer, len);
    return stbi__load_and_postprocess_16bit(&s, x, y, channels_in_file, desired_channels);
}

/// STBIDEF stbi_us *stbi_load_16_from_callbacks(...)
fn stbi_load_16_from_callbacks(clbk: [*c]const stbi_io_callbacks, user: ?*anyopaque, x: [*c]c_int, y: [*c]c_int, channels_in_file: [*c]c_int, desired_channels: c_int) [*c]stbi_us {
    var s: stbi__context = undefined;
    stbi__start_callbacks(&s, clbk, user);
    return stbi__load_and_postprocess_16bit(&s, x, y, channels_in_file, desired_channels);
}

/// STBIDEF stbi_uc *stbi_load_from_memory(stbi_uc const *buffer, int len, int *x, int *y, int *comp, int req_comp)
pub fn stbi_load_from_memory(buffer:[*c]const stbi_uc, len: c_int, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int) [*c]stbi_uc {
    var s: stbi__context = undefined;
    stbi__start_mem(&s, buffer, len);
    return stbi__load_and_postprocess_8bit(&s, x, y, comp, req_comp);
}

/// STBIDEF stbi_uc *stbi_load_from_callbacks(stbi_io_callbacks const *clbk, void *user, int *x, int *y, int *comp, int req_comp)
fn stbi_load_from_callbacks(clbk: [*c]const stbi_io_callbacks, user: ?*anyopaque, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int) [*c]stbi_uc {
    var s: stbi__context = undefined;
    stbi__start_callbacks(&s, clbk, user);
    return stbi__load_and_postprocess_8bit(&s, x, y, comp, req_comp);
}

// ---- JPEG structures, Huffman tables, bit reader, block decoders ----

// huffman decoding acceleration
const FAST_BITS: c_int = 9; // larger handles more cases; smaller stomps less cache

/// stbi__huffman
pub const stbi__huffman = extern struct {
    fast: [1 << FAST_BITS]stbi_uc,
    // weirdly, repacking this into AoS is a 10% speed loss, instead of a win
    code: [256]stbi__uint16,
    values: [256]stbi_uc,
    size: [257]stbi_uc,
    maxcode: [18]c_uint,
    delta: [17]c_int, // old 'firstsymbol' - old 'firstcode'
};

/// stbi__jpeg
pub const stbi__jpeg = extern struct {
    s: [*c]stbi__context,
    huff_dc: [4]stbi__huffman,
    huff_ac: [4]stbi__huffman,
    dequant: [4][64]stbi__uint16,
    fast_ac: [4][1 << FAST_BITS]stbi__int16,

    // sizes for components, interleaved MCUs
    img_h_max: c_int,
    img_v_max: c_int,
    img_mcu_x: c_int,
    img_mcu_y: c_int,
    img_mcu_w: c_int,
    img_mcu_h: c_int,

    // definition of jpeg image component
    img_comp: [4]extern struct {
        id: c_int,
        h: c_int,
        v: c_int,
        tq: c_int,
        hd: c_int,
        ha: c_int,
        dc_pred: c_int,

        x: c_int,
        y: c_int,
        w2: c_int,
        h2: c_int,
        data: [*c]stbi_uc,
        raw_data: ?*anyopaque,
        raw_coeff: ?*anyopaque,
        linebuf: [*c]stbi_uc,
        coeff: [*c]c_short, // progressive only
        coeff_w: c_int,
        coeff_h: c_int, // number of 8x8 coefficient blocks
    },

    code_buffer: stbi__uint32, // jpeg entropy-coded buffer
    code_bits: c_int, // number of valid bits
    marker: u8, // marker seen while filling entropy buffer
    nomore: c_int, // flag if we saw a marker so must stop

    progressive: c_int,
    spec_start: c_int,
    spec_end: c_int,
    succ_high: c_int,
    succ_low: c_int,
    eob_run: c_int,
    jfif: c_int,
    app14_color_transform: c_int, // Adobe APP14 tag
    rgb: c_int,

    scan_n: c_int,
    order: [4]c_int,
    restart_interval: c_int,
    todo: c_int,

    // kernels
    idct_block_kernel: ?*const fn (out: [*c]stbi_uc, out_stride: c_int, data: [*c]c_short) callconv(.c) void,
    YCbCr_to_RGB_kernel: ?*const fn (out: [*c]stbi_uc, y: [*c]const stbi_uc, pcb: [*c]const stbi_uc, pcr: [*c]const stbi_uc, count: c_int, step: c_int) callconv(.c) void,
    resample_row_hv_2_kernel: ?*const fn (out: [*c]stbi_uc, in_near: [*c]stbi_uc, in_far: [*c]stbi_uc, w: c_int, hs: c_int) callconv(.c) [*c]stbi_uc,
};

fn stbi__build_huffman(h: [*c]stbi__huffman, count: [*c]c_int) c_int {
    var i: c_int = 0;
    var j: c_int = 0;
    var k: c_int = 0;
    var code: c_uint = undefined;
    // build size list for each symbol (from JPEG spec)
    i = 0;
    while (i < 16) : (i += 1) {
        j = 0;
        while (j < count[@intCast(i)]) : (j += 1) {
            h.*.size[@intCast(k)] = @intCast(i + 1);
            k += 1;
            if (k >= 257) return stbi__err("bad size list", "Corrupt JPEG");
        }
    }
    h.*.size[@intCast(k)] = 0;

    // compute actual symbols (from jpeg spec)
    code = 0;
    k = 0;
    j = 1;
    while (j <= 16) : (j += 1) {
        // compute delta to add to code to compute symbol id
        h.*.delta[@intCast(j)] = @bitCast(@as(c_uint, @bitCast(k)) -% code);
        if (h.*.size[@intCast(k)] == j) {
            while (h.*.size[@intCast(k)] == j) {
                h.*.code[@intCast(k)] = @truncate(code);
                k += 1;
                code +%= 1;
            }
            if (code -% 1 >= (@as(c_uint, 1) << @intCast(j))) return stbi__err("bad code lengths", "Corrupt JPEG");
        }
        // compute largest code + 1 for this size, preshifted as needed later
        h.*.maxcode[@intCast(j)] = code << @intCast(16 - j);
        code <<= 1;
    }
    h.*.maxcode[@intCast(j)] = 0xffffffff;

    // build non-spec acceleration table; 255 is flag for not-accelerated
    @memset(h.*.fast[0 .. 1 << FAST_BITS], 255);
    i = 0;
    while (i < k) : (i += 1) {
        const s: c_int = h.*.size[@intCast(i)];
        if (s <= FAST_BITS) {
            const c: c_int = @as(c_int, h.*.code[@intCast(i)]) << @intCast(FAST_BITS - s);
            const m: c_int = @as(c_int, 1) << @intCast(FAST_BITS - s);
            j = 0;
            while (j < m) : (j += 1) {
                h.*.fast[@intCast(c + j)] = @intCast(i);
            }
        }
    }
    return 1;
}

// build a table that decodes both magnitude and value of small ACs in
// one go.
fn stbi__build_fast_ac(fast_ac: [*c]stbi__int16, h: [*c]stbi__huffman) void {
    var i: c_int = 0;
    while (i < (1 << FAST_BITS)) : (i += 1) {
        const fast: stbi_uc = h.*.fast[@intCast(i)];
        fast_ac[@intCast(i)] = 0;
        if (fast < 255) {
            const rs: c_int = h.*.values[fast];
            const run: c_int = (rs >> 4) & 15;
            const magbits: c_int = rs & 15;
            const len: c_int = h.*.size[fast];

            if (magbits != 0 and len + magbits <= FAST_BITS) {
                // magnitude code followed by receive_extend code
                var k: c_int = @bitCast(((@as(c_uint, @bitCast(i)) << @intCast(len)) & 511) >> @intCast(FAST_BITS - magbits));
                const m: c_int = @as(c_int, 1) << @intCast(magbits - 1);
                if (k < m) k = @bitCast(@as(c_uint, @bitCast(k)) +% ((~@as(c_uint, 0) << @intCast(magbits)) +% 1));
                // if the result is small enough, we can fit it in fast_ac table
                if (k >= -128 and k <= 127)
                    fast_ac[@intCast(i)] = @intCast((k * 256) + (run * 16) + (len + magbits));
            }
        }
    }
}

fn stbi__grow_buffer_unsafe(j: [*c]stbi__jpeg) void {
    while (true) {
        const b: c_uint = if (j.*.nomore != 0) 0 else stbi__get8(j.*.s);
        if (b == 0xff) {
            var c: c_int = stbi__get8(j.*.s);
            while (c == 0xff) c = stbi__get8(j.*.s); // consume fill bytes
            if (c != 0) {
                j.*.marker = @intCast(c);
                j.*.nomore = 1;
                return;
            }
        }
        j.*.code_buffer |= b << @intCast(24 - j.*.code_bits);
        j.*.code_bits += 8;
        if (!(j.*.code_bits <= 24)) break;
    }
}

// (1 << n) - 1
const stbi__bmask: [17]stbi__uint32 = .{ 0, 1, 3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535 };

// rotate left (stbi_lrot macro)
inline fn stbi_lrot(x: stbi__uint32, y: c_int) stbi__uint32 {
    return (x << @intCast(y)) | (x >> @intCast((-y) & 31));
}

// decode a jpeg huffman value from the bitstream
inline fn stbi__jpeg_huff_decode(j: [*c]stbi__jpeg, h: [*c]stbi__huffman) c_int {
    var temp: c_uint = undefined;
    var c: c_int = undefined;
    var k: c_int = undefined;

    if (j.*.code_bits < 16) stbi__grow_buffer_unsafe(j);

    // look at the top FAST_BITS and determine what symbol ID it is,
    // if the code is <= FAST_BITS
    c = @intCast((j.*.code_buffer >> (32 - FAST_BITS)) & ((1 << FAST_BITS) - 1));
    k = h.*.fast[@intCast(c)];
    if (k < 255) {
        const s: c_int = h.*.size[@intCast(k)];
        if (s > j.*.code_bits) return -1;
        j.*.code_buffer <<= @intCast(s);
        j.*.code_bits -= s;
        return h.*.values[@intCast(k)];
    }

    // naive test is to shift the code_buffer down so k bits are
    // valid, then test against maxcode. To speed this up, we've
    // preshifted maxcode left so that it has (16-k) 0s at the
    // end; in other words, regardless of the number of bits, it
    // wants to be compared against something shifted to have 16;
    // that way we don't need to shift inside the loop.
    temp = j.*.code_buffer >> 16;
    k = FAST_BITS + 1;
    while (true) : (k += 1) {
        if (temp < h.*.maxcode[@intCast(k)]) break;
    }
    if (k == 17) {
        // error! code not found
        j.*.code_bits -= 16;
        return -1;
    }

    if (k > j.*.code_bits) return -1;

    // convert the huffman code to the symbol id
    c = @as(c_int, @bitCast((j.*.code_buffer >> @intCast(32 - k)) & stbi__bmask[@intCast(k)])) + h.*.delta[@intCast(k)];
    if (c < 0 or c >= 256) // symbol id out of bounds!
        return -1;
    // STBI_ASSERT((((j->code_buffer) >> (32 - h->size[c])) & stbi__bmask[h->size[c]]) == h->code[c]);

    // convert the id to a symbol
    j.*.code_bits -= k;
    j.*.code_buffer <<= @intCast(k);
    return h.*.values[@intCast(c)];
}

// bias[n] = (-1<<n) + 1
const stbi__jbias: [16]c_int = .{ 0, -1, -3, -7, -15, -31, -63, -127, -255, -511, -1023, -2047, -4095, -8191, -16383, -32767 };

// combined JPEG 'receive' and JPEG 'extend', since baseline
// always extends everything it receives.
inline fn stbi__extend_receive(j: [*c]stbi__jpeg, n: c_int) c_int {
    var k: stbi__uint32 = undefined;
    var sgn: c_int = undefined;
    if (j.*.code_bits < n) stbi__grow_buffer_unsafe(j);
    if (j.*.code_bits < n) return 0; // ran out of bits from stream, return 0s intead of continuing

    sgn = @bitCast(j.*.code_buffer >> 31); // sign bit always in MSB; 0 if MSB clear (positive), 1 if MSB set (negative)
    k = stbi_lrot(j.*.code_buffer, n);
    j.*.code_buffer = k & ~stbi__bmask[@intCast(n)];
    k &= stbi__bmask[@intCast(n)];
    j.*.code_bits -= n;
    return @as(c_int, @bitCast(k)) +% (stbi__jbias[@intCast(n)] & (sgn - 1));
}

// get some unsigned bits
inline fn stbi__jpeg_get_bits(j: [*c]stbi__jpeg, n: c_int) c_int {
    var k: stbi__uint32 = undefined;
    if (j.*.code_bits < n) stbi__grow_buffer_unsafe(j);
    if (j.*.code_bits < n) return 0; // ran out of bits from stream, return 0s intead of continuing
    k = stbi_lrot(j.*.code_buffer, n);
    j.*.code_buffer = k & ~stbi__bmask[@intCast(n)];
    k &= stbi__bmask[@intCast(n)];
    j.*.code_bits -= n;
    return @bitCast(k);
}

inline fn stbi__jpeg_get_bit(j: [*c]stbi__jpeg) c_int {
    var k: stbi__uint32 = undefined;
    if (j.*.code_bits < 1) stbi__grow_buffer_unsafe(j);
    if (j.*.code_bits < 1) return 0; // ran out of bits from stream, return 0s intead of continuing
    k = j.*.code_buffer;
    j.*.code_buffer <<= 1;
    j.*.code_bits -= 1;
    return @bitCast(k & 0x80000000);
}

// given a value that's at position X in the zigzag stream,
// where does it appear in the 8x8 matrix coded as row-major?
const stbi__jpeg_dezigzag: [64 + 15]stbi_uc = .{
    0, 1, 8, 16, 9, 2, 3, 10,
    17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
    // let corrupt input sample past end
    63, 63, 63, 63, 63, 63, 63, 63,
    63, 63, 63, 63, 63, 63, 63,
};

// decode one 64-entry block--
fn stbi__jpeg_decode_block(j: [*c]stbi__jpeg, data: [*c]c_short, hdc: [*c]stbi__huffman, hac: [*c]stbi__huffman, fac: [*c]stbi__int16, b: c_int, dequant: [*c]stbi__uint16) c_int {
    var diff: c_int = undefined;
    var dc: c_int = undefined;
    var k: c_int = undefined;
    var t: c_int = undefined;

    if (j.*.code_bits < 16) stbi__grow_buffer_unsafe(j);
    t = stbi__jpeg_huff_decode(j, hdc);
    if (t < 0 or t > 15) return stbi__err("bad huffman code", "Corrupt JPEG");

    // 0 all the ac values now so we can do it 32-bits at a time
    @memset(data[0..64], 0);

    diff = if (t != 0) stbi__extend_receive(j, t) else 0;
    if (stbi__addints_valid(j.*.img_comp[@intCast(b)].dc_pred, diff) == 0) return stbi__err("bad delta", "Corrupt JPEG");
    dc = j.*.img_comp[@intCast(b)].dc_pred + diff;
    j.*.img_comp[@intCast(b)].dc_pred = dc;
    if (stbi__mul2shorts_valid(dc, dequant[0]) == 0) return stbi__err("can't merge dc and ac", "Corrupt JPEG");
    data[0] = @truncate(dc * @as(c_int, dequant[0]));

    // decode AC components, see JPEG spec
    k = 1;
    while (true) {
        var zig: c_uint = undefined;
        var c: c_int = undefined;
        var r: c_int = undefined;
        var s: c_int = undefined;
        if (j.*.code_bits < 16) stbi__grow_buffer_unsafe(j);
        c = @intCast((j.*.code_buffer >> (32 - FAST_BITS)) & ((1 << FAST_BITS) - 1));
        r = fac[@intCast(c)];
        if (r != 0) { // fast-AC path
            k += (r >> 4) & 15; // run
            s = r & 15; // combined length
            if (s > j.*.code_bits) return stbi__err("bad huffman code", "Combined length longer than code bits available");
            j.*.code_buffer <<= @intCast(s);
            j.*.code_bits -= s;
            // decode into unzigzag'd location
            zig = stbi__jpeg_dezigzag[@intCast(k)];
            k += 1;
            data[zig] = @truncate((r >> 8) * @as(c_int, dequant[zig]));
        } else {
            const rs: c_int = stbi__jpeg_huff_decode(j, hac);
            if (rs < 0) return stbi__err("bad huffman code", "Corrupt JPEG");
            s = rs & 15;
            r = rs >> 4;
            if (s == 0) {
                if (rs != 0xf0) break; // end block
                k += 16;
            } else {
                k += r;
                // decode into unzigzag'd location
                zig = stbi__jpeg_dezigzag[@intCast(k)];
                k += 1;
                data[zig] = @truncate(stbi__extend_receive(j, s) * @as(c_int, dequant[zig]));
            }
        }
        if (!(k < 64)) break;
    }
    return 1;
}

fn stbi__jpeg_decode_block_prog_dc(j: [*c]stbi__jpeg, data: [*c]c_short, hdc: [*c]stbi__huffman, b: c_int) c_int {
    var diff: c_int = undefined;
    var dc: c_int = undefined;
    var t: c_int = undefined;
    if (j.*.spec_end != 0) return stbi__err("can't merge dc and ac", "Corrupt JPEG");

    if (j.*.code_bits < 16) stbi__grow_buffer_unsafe(j);

    if (j.*.succ_high == 0) {
        // first scan for DC coefficient, must be first
        @memset(data[0..64], 0); // 0 all the ac values now
        t = stbi__jpeg_huff_decode(j, hdc);
        if (t < 0 or t > 15) return stbi__err("can't merge dc and ac", "Corrupt JPEG");
        diff = if (t != 0) stbi__extend_receive(j, t) else 0;

        if (stbi__addints_valid(j.*.img_comp[@intCast(b)].dc_pred, diff) == 0) return stbi__err("bad delta", "Corrupt JPEG");
        dc = j.*.img_comp[@intCast(b)].dc_pred + diff;
        j.*.img_comp[@intCast(b)].dc_pred = dc;
        if (stbi__mul2shorts_valid(dc, @as(c_int, 1) << @intCast(j.*.succ_low)) == 0) return stbi__err("can't merge dc and ac", "Corrupt JPEG");
        data[0] = @truncate(dc * (@as(c_int, 1) << @intCast(j.*.succ_low)));
    } else {
        // refinement scan for DC coefficient
        if (stbi__jpeg_get_bit(j) != 0)
            data[0] +%= @truncate(@as(c_int, 1) << @intCast(j.*.succ_low));
    }
    return 1;
}

fn stbi__jpeg_decode_block_prog_ac(j: [*c]stbi__jpeg, data: [*c]c_short, hac: [*c]stbi__huffman, fac: [*c]stbi__int16) c_int {
    var k: c_int = undefined;
    if (j.*.spec_start == 0) return stbi__err("can't merge dc and ac", "Corrupt JPEG");

    if (j.*.succ_high == 0) {
        const shift: c_int = j.*.succ_low;

        if (j.*.eob_run != 0) {
            j.*.eob_run -= 1;
            return 1;
        }

        k = j.*.spec_start;
        while (true) {
            var zig: c_uint = undefined;
            var c: c_int = undefined;
            var r: c_int = undefined;
            var s: c_int = undefined;
            if (j.*.code_bits < 16) stbi__grow_buffer_unsafe(j);
            c = @intCast((j.*.code_buffer >> (32 - FAST_BITS)) & ((1 << FAST_BITS) - 1));
            r = fac[@intCast(c)];
            if (r != 0) { // fast-AC path
                k += (r >> 4) & 15; // run
                s = r & 15; // combined length
                if (s > j.*.code_bits) return stbi__err("bad huffman code", "Combined length longer than code bits available");
                j.*.code_buffer <<= @intCast(s);
                j.*.code_bits -= s;
                zig = stbi__jpeg_dezigzag[@intCast(k)];
                k += 1;
                data[zig] = @truncate((r >> 8) * (@as(c_int, 1) << @intCast(shift)));
            } else {
                const rs: c_int = stbi__jpeg_huff_decode(j, hac);
                if (rs < 0) return stbi__err("bad huffman code", "Corrupt JPEG");
                s = rs & 15;
                r = rs >> 4;
                if (s == 0) {
                    if (r < 15) {
                        j.*.eob_run = @as(c_int, 1) << @intCast(r);
                        if (r != 0)
                            j.*.eob_run += stbi__jpeg_get_bits(j, r);
                        j.*.eob_run -= 1;
                        break;
                    }
                    k += 16;
                } else {
                    k += r;
                    zig = stbi__jpeg_dezigzag[@intCast(k)];
                    k += 1;
                    data[zig] = @truncate(stbi__extend_receive(j, s) * (@as(c_int, 1) << @intCast(shift)));
                }
            }
            if (!(k <= j.*.spec_end)) break;
        }
    } else {
        // refinement scan for these AC coefficients

        const bit: c_short = @truncate(@as(c_int, 1) << @intCast(j.*.succ_low));

        if (j.*.eob_run != 0) {
            j.*.eob_run -= 1;
            k = j.*.spec_start;
            while (k <= j.*.spec_end) : (k += 1) {
                const p: [*c]c_short = data + @as(usize, @intCast(stbi__jpeg_dezigzag[@intCast(k)]));
                if (p[0] != 0) {
                    if (stbi__jpeg_get_bit(j) != 0) {
                        if ((p[0] & bit) == 0) {
                            if (p[0] > 0) {
                                p[0] +%= bit;
                            } else {
                                p[0] -%= bit;
                            }
                        }
                    }
                }
            }
        } else {
            k = j.*.spec_start;
            while (true) {
                var r: c_int = undefined;
                var s: c_int = undefined;
                const rs: c_int = stbi__jpeg_huff_decode(j, hac); // @OPTIMIZE see if we can use the fast path here, advance-by-r is so slow, eh
                if (rs < 0) return stbi__err("bad huffman code", "Corrupt JPEG");
                s = rs & 15;
                r = rs >> 4;
                if (s == 0) {
                    if (r < 15) {
                        j.*.eob_run = (@as(c_int, 1) << @intCast(r)) - 1;
                        if (r != 0)
                            j.*.eob_run += stbi__jpeg_get_bits(j, r);
                        r = 64; // force end of block
                    } else {
                        // r=15 s=0 should write 16 0s, so we just do
                        // a run of 15 0s and then write s (which is 0),
                        // so we don't have to do anything special here
                    }
                } else {
                    if (s != 1) return stbi__err("bad huffman code", "Corrupt JPEG");
                    // sign bit
                    if (stbi__jpeg_get_bit(j) != 0) {
                        s = bit;
                    } else {
                        s = -@as(c_int, bit);
                    }
                }

                // advance by r
                while (k <= j.*.spec_end) {
                    const p: [*c]c_short = data + @as(usize, @intCast(stbi__jpeg_dezigzag[@intCast(k)]));
                    k += 1;
                    if (p[0] != 0) {
                        if (stbi__jpeg_get_bit(j) != 0) {
                            if ((p[0] & bit) == 0) {
                                if (p[0] > 0) {
                                    p[0] +%= bit;
                                } else {
                                    p[0] -%= bit;
                                }
                            }
                        }
                    } else {
                        if (r == 0) {
                            p[0] = @truncate(s);
                            break;
                        }
                        r -= 1;
                    }
                }
                if (!(k <= j.*.spec_end)) break;
            }
        }
    }
    return 1;
}

// take a -128..127 value and stbi__clamp it and convert to 0..255
inline fn stbi__clamp(x: c_int) stbi_uc {
    // trick to use a single test to catch both cases
    if (@as(c_uint, @bitCast(x)) > 255) {
        if (x < 0) return 0;
        if (x > 255) return 255;
    }
    return @intCast(x);
}

// stbi__f2f(x) ((int) (((x) * 4096 + 0.5)))  (x is a float constant: the product is float, the sum double)
inline fn stbi__f2f(comptime x: f32) c_int {
    return @intFromFloat(@as(f64, x * 4096.0) + 0.5);
}

// stbi__fsh(x) ((x) * 4096)
inline fn stbi__fsh(x: c_int) c_int {
    return x *% 4096;
}

const Idct1d = struct {
    t0: c_int,
    t1: c_int,
    t2: c_int,
    t3: c_int,
    x0: c_int,
    x1: c_int,
    x2: c_int,
    x3: c_int,
};

// derived from jidctint -- DCT_ISLOW
// STBI__IDCT_1D(s0..s7): the macro body, its results are the locals t0..t3 and x0..x3.
inline fn STBI__IDCT_1D(s0: c_int, s1: c_int, s2: c_int, s3: c_int, s4: c_int, s5: c_int, s6: c_int, s7: c_int) Idct1d {
    var t0: c_int = undefined;
    var t1: c_int = undefined;
    var t2: c_int = undefined;
    var t3: c_int = undefined;
    var p1: c_int = undefined;
    var p2: c_int = undefined;
    var p3: c_int = undefined;
    var p4: c_int = undefined;
    var p5: c_int = undefined;
    var x0: c_int = undefined;
    var x1: c_int = undefined;
    var x2: c_int = undefined;
    var x3: c_int = undefined;
    p2 = s2;
    p3 = s6;
    p1 = (p2 +% p3) *% stbi__f2f(0.5411961);
    t2 = p1 +% p3 *% stbi__f2f(-1.847759065);
    t3 = p1 +% p2 *% stbi__f2f(0.765366865);
    p2 = s0;
    p3 = s4;
    t0 = stbi__fsh(p2 +% p3);
    t1 = stbi__fsh(p2 -% p3);
    x0 = t0 +% t3;
    x3 = t0 -% t3;
    x1 = t1 +% t2;
    x2 = t1 -% t2;
    t0 = s7;
    t1 = s5;
    t2 = s3;
    t3 = s1;
    p3 = t0 +% t2;
    p4 = t1 +% t3;
    p1 = t0 +% t3;
    p2 = t1 +% t2;
    p5 = (p3 +% p4) *% stbi__f2f(1.175875602);
    t0 = t0 *% stbi__f2f(0.298631336);
    t1 = t1 *% stbi__f2f(2.053119869);
    t2 = t2 *% stbi__f2f(3.072711026);
    t3 = t3 *% stbi__f2f(1.501321110);
    p1 = p5 +% p1 *% stbi__f2f(-0.899976223);
    p2 = p5 +% p2 *% stbi__f2f(-2.562915447);
    p3 = p3 *% stbi__f2f(-1.961570560);
    p4 = p4 *% stbi__f2f(-0.390180644);
    t3 +%= p1 +% p4;
    t2 +%= p2 +% p3;
    t1 +%= p2 +% p4;
    t0 +%= p1 +% p3;
    return .{ .t0 = t0, .t1 = t1, .t2 = t2, .t3 = t3, .x0 = x0, .x1 = x1, .x2 = x2, .x3 = x3 };
}

fn stbi__idct_block(out: [*c]stbi_uc, out_stride: c_int, data: [*c]c_short) callconv(.c) void {
    var val: [64]c_int = undefined;
    var i: c_int = undefined;
    var v: [*c]c_int = &val;
    var o: [*c]stbi_uc = undefined;
    var d: [*c]c_short = data;

    // columns
    i = 0;
    while (i < 8) : ({
        i += 1;
        d += 1;
        v += 1;
    }) {
        // if all zeroes, shortcut -- this avoids dequantizing 0s and IDCTing
        if (d[8] == 0 and d[16] == 0 and d[24] == 0 and d[32] == 0 and
            d[40] == 0 and d[48] == 0 and d[56] == 0)
        {
            const dcterm: c_int = @as(c_int, d[0]) * 4;
            v[0] = dcterm;
            v[8] = dcterm;
            v[16] = dcterm;
            v[24] = dcterm;
            v[32] = dcterm;
            v[40] = dcterm;
            v[48] = dcterm;
            v[56] = dcterm;
        } else {
            const r = STBI__IDCT_1D(d[0], d[8], d[16], d[24], d[32], d[40], d[48], d[56]);
            var x0 = r.x0;
            var x1 = r.x1;
            var x2 = r.x2;
            var x3 = r.x3;
            const t0 = r.t0;
            const t1 = r.t1;
            const t2 = r.t2;
            const t3 = r.t3;
            // constants scaled things up by 1<<12; let's bring them back
            // down, but keep 2 extra bits of precision
            x0 +%= 512;
            x1 +%= 512;
            x2 +%= 512;
            x3 +%= 512;
            v[0] = (x0 +% t3) >> 10;
            v[56] = (x0 -% t3) >> 10;
            v[8] = (x1 +% t2) >> 10;
            v[48] = (x1 -% t2) >> 10;
            v[16] = (x2 +% t1) >> 10;
            v[40] = (x2 -% t1) >> 10;
            v[24] = (x3 +% t0) >> 10;
            v[32] = (x3 -% t0) >> 10;
        }
    }

    v = &val;
    o = out;
    i = 0;
    while (i < 8) : ({
        i += 1;
        v += 8;
        o += @as(usize, @intCast(out_stride));
    }) {
        // no fast case since the first 1D IDCT spread components out
        const r = STBI__IDCT_1D(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
        var x0 = r.x0;
        var x1 = r.x1;
        var x2 = r.x2;
        var x3 = r.x3;
        const t0 = r.t0;
        const t1 = r.t1;
        const t2 = r.t2;
        const t3 = r.t3;
        // constants scaled things up by 1<<12, plus we had 1<<2 from first
        // loop, plus horizontal and vertical each scale by sqrt(8) so together
        // we've got an extra 1<<3, so 1<<17 total we need to remove.
        // so we want to round that, which means adding 0.5 * 1<<17,
        // aka 65536. Also, we'll end up with -128 to 127 that we want
        // to encode as 0..255 by adding 128, so we'll add that before the shift
        x0 +%= 65536 + (128 << 17);
        x1 +%= 65536 + (128 << 17);
        x2 +%= 65536 + (128 << 17);
        x3 +%= 65536 + (128 << 17);
        o[0] = stbi__clamp((x0 +% t3) >> 17);
        o[7] = stbi__clamp((x0 -% t3) >> 17);
        o[1] = stbi__clamp((x1 +% t2) >> 17);
        o[6] = stbi__clamp((x1 -% t2) >> 17);
        o[2] = stbi__clamp((x2 +% t1) >> 17);
        o[5] = stbi__clamp((x2 -% t1) >> 17);
        o[3] = stbi__clamp((x3 +% t0) >> 17);
        o[4] = stbi__clamp((x3 -% t0) >> 17);
    }
}

// ---- JPEG entropy-coded data, markers, scan and frame headers ----

const STBI__MARKER_none: u8 = 0xff;

fn stbi__get_marker(j: [*c]stbi__jpeg) stbi_uc {
    var x: stbi_uc = undefined;
    if (j.*.marker != STBI__MARKER_none) {
        x = j.*.marker;
        j.*.marker = STBI__MARKER_none;
        return x;
    }
    x = stbi__get8(j.*.s);
    if (x != 0xff) return STBI__MARKER_none;
    while (x == 0xff) x = stbi__get8(j.*.s); // consume repeated 0xff fill bytes
    return x;
}

// in each scan, we'll have scan_n components, and the order
// of the components is specified by order[]
inline fn STBI__RESTART(x: u8) bool {
    return x >= 0xd0 and x <= 0xd7;
}

// after a restart interval, stbi__jpeg_reset the entropy decoder and
// the dc prediction
fn stbi__jpeg_reset(j: [*c]stbi__jpeg) void {
    j.*.code_bits = 0;
    j.*.code_buffer = 0;
    j.*.nomore = 0;
    j.*.img_comp[0].dc_pred = 0;
    j.*.img_comp[1].dc_pred = 0;
    j.*.img_comp[2].dc_pred = 0;
    j.*.img_comp[3].dc_pred = 0;
    j.*.marker = STBI__MARKER_none;
    j.*.todo = if (j.*.restart_interval != 0) j.*.restart_interval else 0x7fffffff;
    j.*.eob_run = 0;
    // no more than 1<<31 MCUs if no restart_interal? that's plenty safe,
    // since we don't even allow 1<<30 pixels
}

// `if (--z->todo <= 0) { if (code_bits < 24) grow; if (!RESTART(marker)) return 1; reset; }`
// Returns true when the scan must end with success (return 1 in the C code).
fn stbi__count_mcu(z: [*c]stbi__jpeg) bool {
    z.*.todo -= 1;
    if (z.*.todo > 0) return false;
    if (z.*.code_bits < 24) stbi__grow_buffer_unsafe(z);
    // if it's NOT a restart, then just bail, so we get corrupt data
    // rather than no data
    if (!STBI__RESTART(z.*.marker)) return true;
    stbi__jpeg_reset(z);
    return false;
}

fn stbi__parse_entropy_coded_data(z: [*c]stbi__jpeg) c_int {
    stbi__jpeg_reset(z);
    if (z.*.progressive == 0) {
        if (z.*.scan_n == 1) {
            var data: [64]c_short = undefined; // STBI_SIMD_ALIGN(short, data[64]);
            var i: c_int = undefined;
            var j: c_int = undefined;
            const n: c_int = z.*.order[0];
            // non-interleaved data, we just need to process one block at a time,
            // in trivial scanline order
            // number of blocks to do just depends on how many actual "pixels" this
            // component has, independent of interleaved MCU blocking and such
            const w: c_int = (z.*.img_comp[@intCast(n)].x + 7) >> 3;
            const h: c_int = (z.*.img_comp[@intCast(n)].y + 7) >> 3;
            j = 0;
            while (j < h) : (j += 1) {
                i = 0;
                while (i < w) : (i += 1) {
                    const ha: c_int = z.*.img_comp[@intCast(n)].ha;
                    const hd: c_int = z.*.img_comp[@intCast(n)].hd;
                    const tq: c_int = z.*.img_comp[@intCast(n)].tq;
                    if (stbi__jpeg_decode_block(z, &data, &z.*.huff_dc[@intCast(hd)], &z.*.huff_ac[@intCast(ha)], &z.*.fast_ac[@intCast(ha)], n, &z.*.dequant[@intCast(tq)]) == 0) return 0;
                    const stride: c_int = z.*.img_comp[@intCast(n)].w2;
                    const off: usize = @intCast(stride * j * 8 + i * 8);
                    z.*.idct_block_kernel.?(z.*.img_comp[@intCast(n)].data + off, stride, &data);
                    // every data block is an MCU, so countdown the restart interval
                    if (stbi__count_mcu(z)) return 1;
                }
            }
            return 1;
        } else { // interleaved
            var data: [64]c_short = undefined; // STBI_SIMD_ALIGN(short, data[64]);
            var i: c_int = undefined;
            var j: c_int = undefined;
            var k: c_int = undefined;
            var x: c_int = undefined;
            var y: c_int = undefined;
            j = 0;
            while (j < z.*.img_mcu_y) : (j += 1) {
                i = 0;
                while (i < z.*.img_mcu_x) : (i += 1) {
                    // scan an interleaved mcu... process scan_n components in order
                    k = 0;
                    while (k < z.*.scan_n) : (k += 1) {
                        const n: c_int = z.*.order[@intCast(k)];
                        // scan out an mcu's worth of this component; that's just determined
                        // by the basic H and V specified for the component
                        y = 0;
                        while (y < z.*.img_comp[@intCast(n)].v) : (y += 1) {
                            x = 0;
                            while (x < z.*.img_comp[@intCast(n)].h) : (x += 1) {
                                const x2: c_int = (i * z.*.img_comp[@intCast(n)].h + x) * 8;
                                const y2: c_int = (j * z.*.img_comp[@intCast(n)].v + y) * 8;
                                const ha: c_int = z.*.img_comp[@intCast(n)].ha;
                                const hd: c_int = z.*.img_comp[@intCast(n)].hd;
                                const tq: c_int = z.*.img_comp[@intCast(n)].tq;
                                if (stbi__jpeg_decode_block(z, &data, &z.*.huff_dc[@intCast(hd)], &z.*.huff_ac[@intCast(ha)], &z.*.fast_ac[@intCast(ha)], n, &z.*.dequant[@intCast(tq)]) == 0) return 0;
                                const stride: c_int = z.*.img_comp[@intCast(n)].w2;
                                const off: usize = @intCast(stride * y2 + x2);
                                z.*.idct_block_kernel.?(z.*.img_comp[@intCast(n)].data + off, stride, &data);
                            }
                        }
                    }
                    // after all interleaved components, that's an interleaved MCU,
                    // so now count down the restart interval
                    if (stbi__count_mcu(z)) return 1;
                }
            }
            return 1;
        }
    } else {
        if (z.*.scan_n == 1) {
            var i: c_int = undefined;
            var j: c_int = undefined;
            const n: c_int = z.*.order[0];
            // non-interleaved data, we just need to process one block at a time,
            // in trivial scanline order
            // number of blocks to do just depends on how many actual "pixels" this
            // component has, independent of interleaved MCU blocking and such
            const w: c_int = (z.*.img_comp[@intCast(n)].x + 7) >> 3;
            const h: c_int = (z.*.img_comp[@intCast(n)].y + 7) >> 3;
            j = 0;
            while (j < h) : (j += 1) {
                i = 0;
                while (i < w) : (i += 1) {
                    const data: [*c]c_short = z.*.img_comp[@intCast(n)].coeff + @as(usize, @intCast(64 * (i + j * z.*.img_comp[@intCast(n)].coeff_w)));
                    if (z.*.spec_start == 0) {
                        const hd: c_int = z.*.img_comp[@intCast(n)].hd;
                        if (stbi__jpeg_decode_block_prog_dc(z, data, &z.*.huff_dc[@intCast(hd)], n) == 0)
                            return 0;
                    } else {
                        const ha: c_int = z.*.img_comp[@intCast(n)].ha;
                        if (stbi__jpeg_decode_block_prog_ac(z, data, &z.*.huff_ac[@intCast(ha)], &z.*.fast_ac[@intCast(ha)]) == 0)
                            return 0;
                    }
                    // every data block is an MCU, so countdown the restart interval
                    if (stbi__count_mcu(z)) return 1;
                }
            }
            return 1;
        } else { // interleaved
            var i: c_int = undefined;
            var j: c_int = undefined;
            var k: c_int = undefined;
            var x: c_int = undefined;
            var y: c_int = undefined;
            j = 0;
            while (j < z.*.img_mcu_y) : (j += 1) {
                i = 0;
                while (i < z.*.img_mcu_x) : (i += 1) {
                    // scan an interleaved mcu... process scan_n components in order
                    k = 0;
                    while (k < z.*.scan_n) : (k += 1) {
                        const n: c_int = z.*.order[@intCast(k)];
                        // scan out an mcu's worth of this component; that's just determined
                        // by the basic H and V specified for the component
                        y = 0;
                        while (y < z.*.img_comp[@intCast(n)].v) : (y += 1) {
                            x = 0;
                            while (x < z.*.img_comp[@intCast(n)].h) : (x += 1) {
                                const x2: c_int = i * z.*.img_comp[@intCast(n)].h + x;
                                const y2: c_int = j * z.*.img_comp[@intCast(n)].v + y;
                                const data: [*c]c_short = z.*.img_comp[@intCast(n)].coeff + @as(usize, @intCast(64 * (x2 + y2 * z.*.img_comp[@intCast(n)].coeff_w)));
                                const hd: c_int = z.*.img_comp[@intCast(n)].hd;
                                if (stbi__jpeg_decode_block_prog_dc(z, data, &z.*.huff_dc[@intCast(hd)], n) == 0)
                                    return 0;
                            }
                        }
                    }
                    // after all interleaved components, that's an interleaved MCU,
                    // so now count down the restart interval
                    if (stbi__count_mcu(z)) return 1;
                }
            }
            return 1;
        }
    }
}

fn stbi__jpeg_dequantize(data: [*c]c_short, dequant: [*c]stbi__uint16) void {
    var i: c_int = 0;
    while (i < 64) : (i += 1) {
        const u: usize = @intCast(i);
        data[u] = @truncate(@as(c_int, data[u]) * @as(c_int, dequant[u]));
    }
}

fn stbi__jpeg_finish(z: [*c]stbi__jpeg) void {
    if (z.*.progressive != 0) {
        // dequantize and idct the data
        var i: c_int = undefined;
        var j: c_int = undefined;
        var n: c_int = 0;
        while (n < z.*.s.*.img_n) : (n += 1) {
            const w: c_int = (z.*.img_comp[@intCast(n)].x + 7) >> 3;
            const h: c_int = (z.*.img_comp[@intCast(n)].y + 7) >> 3;
            j = 0;
            while (j < h) : (j += 1) {
                i = 0;
                while (i < w) : (i += 1) {
                    const data: [*c]c_short = z.*.img_comp[@intCast(n)].coeff + @as(usize, @intCast(64 * (i + j * z.*.img_comp[@intCast(n)].coeff_w)));
                    const tq: c_int = z.*.img_comp[@intCast(n)].tq;
                    stbi__jpeg_dequantize(data, &z.*.dequant[@intCast(tq)]);
                    const stride: c_int = z.*.img_comp[@intCast(n)].w2;
                    const off: usize = @intCast(stride * j * 8 + i * 8);
                    z.*.idct_block_kernel.?(z.*.img_comp[@intCast(n)].data + off, stride, data);
                }
            }
        }
    }
}

fn stbi__process_marker(z: [*c]stbi__jpeg, m: c_int) c_int {
    var L: c_int = undefined;
    switch (m) {
        0xff => // case STBI__MARKER_none: no marker found
            return stbi__err("expected marker", "Corrupt JPEG"),

        0xDD => { // DRI - specify restart interval
            if (stbi__get16be(z.*.s) != 4) return stbi__err("bad DRI len", "Corrupt JPEG");
            z.*.restart_interval = stbi__get16be(z.*.s);
            return 1;
        },

        0xDB => { // DQT - define quantization table
            L = stbi__get16be(z.*.s) - 2;
            while (L > 0) {
                const q: c_int = stbi__get8(z.*.s);
                const p: c_int = q >> 4;
                const sixteen: c_int = @intFromBool(p != 0);
                const t: c_int = q & 15;
                var i: c_int = undefined;
                if (p != 0 and p != 1) return stbi__err("bad DQT type", "Corrupt JPEG");
                if (t > 3) return stbi__err("bad DQT table", "Corrupt JPEG");

                i = 0;
                while (i < 64) : (i += 1) {
                    const v: c_int = if (sixteen != 0) stbi__get16be(z.*.s) else stbi__get8(z.*.s);
                    z.*.dequant[@intCast(t)][stbi__jpeg_dezigzag[@intCast(i)]] = @truncate(@as(c_uint, @bitCast(v)));
                }
                L -= if (sixteen != 0) 129 else 65;
            }
            return @intFromBool(L == 0);
        },

        0xC4 => { // DHT - define huffman table
            L = stbi__get16be(z.*.s) - 2;
            while (L > 0) {
                var v: [*c]stbi_uc = undefined;
                var sizes: [16]c_int = undefined;
                var i: c_int = undefined;
                var n: c_int = 0;
                const q: c_int = stbi__get8(z.*.s);
                const tc: c_int = q >> 4;
                const th: c_int = q & 15;
                if (tc > 1 or th > 3) return stbi__err("bad DHT header", "Corrupt JPEG");
                i = 0;
                while (i < 16) : (i += 1) {
                    sizes[@intCast(i)] = stbi__get8(z.*.s);
                    n += sizes[@intCast(i)];
                }
                if (n > 256) return stbi__err("bad DHT header", "Corrupt JPEG"); // Loop over i < n would write past end of values!
                L -= 17;
                if (tc == 0) {
                    if (stbi__build_huffman(&z.*.huff_dc[@intCast(th)], &sizes) == 0) return 0;
                    v = &z.*.huff_dc[@intCast(th)].values;
                } else {
                    if (stbi__build_huffman(&z.*.huff_ac[@intCast(th)], &sizes) == 0) return 0;
                    v = &z.*.huff_ac[@intCast(th)].values;
                }
                i = 0;
                while (i < n) : (i += 1)
                    v[@intCast(i)] = stbi__get8(z.*.s);
                if (tc != 0)
                    stbi__build_fast_ac(&z.*.fast_ac[@intCast(th)], &z.*.huff_ac[@intCast(th)]);
                L -= n;
            }
            return @intFromBool(L == 0);
        },

        else => {},
    }

    // check for comment block or APP blocks
    if ((m >= 0xE0 and m <= 0xEF) or m == 0xFE) {
        L = stbi__get16be(z.*.s);
        if (L < 2) {
            if (m == 0xFE)
                return stbi__err("bad COM len", "Corrupt JPEG")
            else
                return stbi__err("bad APP len", "Corrupt JPEG");
        }
        L -= 2;

        if (m == 0xE0 and L >= 5) { // JFIF APP0 segment
            const tag = [5]u8{ 'J', 'F', 'I', 'F', 0 };
            var ok: c_int = 1;
            var i: c_int = 0;
            while (i < 5) : (i += 1) {
                if (stbi__get8(z.*.s) != tag[@intCast(i)]) ok = 0;
            }
            L -= 5;
            if (ok != 0) z.*.jfif = 1;
        } else if (m == 0xEE and L >= 12) { // Adobe APP14 segment
            const tag = [6]u8{ 'A', 'd', 'o', 'b', 'e', 0 };
            var ok: c_int = 1;
            var i: c_int = 0;
            while (i < 6) : (i += 1) {
                if (stbi__get8(z.*.s) != tag[@intCast(i)]) ok = 0;
            }
            L -= 6;
            if (ok != 0) {
                _ = stbi__get8(z.*.s); // version
                _ = stbi__get16be(z.*.s); // flags0
                _ = stbi__get16be(z.*.s); // flags1
                z.*.app14_color_transform = stbi__get8(z.*.s); // color transform
                L -= 6;
            }
        }

        stbi__skip(z.*.s, L);
        return 1;
    }

    return stbi__err("unknown marker", "Corrupt JPEG");
}

// after we see SOS
fn stbi__process_scan_header(z: [*c]stbi__jpeg) c_int {
    var i: c_int = undefined;
    const Ls: c_int = stbi__get16be(z.*.s);
    z.*.scan_n = stbi__get8(z.*.s);
    if (z.*.scan_n < 1 or z.*.scan_n > 4 or z.*.scan_n > z.*.s.*.img_n) return stbi__err("bad SOS component count", "Corrupt JPEG");
    if (Ls != 6 + 2 * z.*.scan_n) return stbi__err("bad SOS len", "Corrupt JPEG");
    i = 0;
    while (i < z.*.scan_n) : (i += 1) {
        const id: c_int = stbi__get8(z.*.s);
        var which: c_int = undefined;
        const q: c_int = stbi__get8(z.*.s);
        which = 0;
        while (which < z.*.s.*.img_n) : (which += 1) {
            if (z.*.img_comp[@intCast(which)].id == id) break;
        }
        if (which == z.*.s.*.img_n) return 0; // no match
        z.*.img_comp[@intCast(which)].hd = q >> 4;
        if (z.*.img_comp[@intCast(which)].hd > 3) return stbi__err("bad DC huff", "Corrupt JPEG");
        z.*.img_comp[@intCast(which)].ha = q & 15;
        if (z.*.img_comp[@intCast(which)].ha > 3) return stbi__err("bad AC huff", "Corrupt JPEG");
        z.*.order[@intCast(i)] = which;
    }

    {
        var aa: c_int = undefined;
        z.*.spec_start = stbi__get8(z.*.s);
        z.*.spec_end = stbi__get8(z.*.s); // should be 63, but might be 0
        aa = stbi__get8(z.*.s);
        z.*.succ_high = (aa >> 4);
        z.*.succ_low = (aa & 15);
        if (z.*.progressive != 0) {
            if (z.*.spec_start > 63 or z.*.spec_end > 63 or z.*.spec_start > z.*.spec_end or z.*.succ_high > 13 or z.*.succ_low > 13)
                return stbi__err("bad SOS", "Corrupt JPEG");
        } else {
            if (z.*.spec_start != 0) return stbi__err("bad SOS", "Corrupt JPEG");
            if (z.*.succ_high != 0 or z.*.succ_low != 0) return stbi__err("bad SOS", "Corrupt JPEG");
            z.*.spec_end = 63;
        }
    }

    return 1;
}

fn stbi__free_jpeg_components(z: [*c]stbi__jpeg, ncomp: c_int, why: c_int) c_int {
    var i: c_int = 0;
    while (i < ncomp) : (i += 1) {
        const c = &z.*.img_comp[@intCast(i)];
        if (c.raw_data != null) {
            base.rvn_free(c.raw_data);
            c.raw_data = null;
            c.data = null;
        }
        if (c.raw_coeff != null) {
            base.rvn_free(c.raw_coeff);
            c.raw_coeff = null;
            c.coeff = null;
        }
        if (c.linebuf != null) {
            base.rvn_free(c.linebuf);
            c.linebuf = null;
        }
    }
    return why;
}

// ---- JPEG frame header, file header, decode driver, resampling, colour ----

const STBI__SCAN_load: c_int = 0;
const STBI__SCAN_type: c_int = 1;
const STBI__SCAN_header: c_int = 2;

const STBI_MAX_DIMENSIONS: c_int = 1 << 24;

fn stbi__process_frame_header(z: [*c]stbi__jpeg, scan: c_int) c_int {
    const s: [*c]stbi__context = z.*.s;
    var Lf: c_int = undefined;
    var p: c_int = undefined;
    var i: c_int = undefined;
    var q: c_int = undefined;
    var h_max: c_int = 1;
    var v_max: c_int = 1;
    var c: c_int = undefined;
    Lf = stbi__get16be(s);
    if (Lf < 11) return stbi__err("bad SOF len", "Corrupt JPEG"); // JPEG
    p = stbi__get8(s);
    if (p != 8) return stbi__err("only 8-bit", "JPEG format not supported: 8-bit only"); // JPEG baseline
    s.*.img_y = @intCast(stbi__get16be(s));
    if (s.*.img_y == 0) return stbi__err("no header height", "JPEG format not supported: delayed height"); // Legal, but we don't handle it--but neither does IJG
    s.*.img_x = @intCast(stbi__get16be(s));
    if (s.*.img_x == 0) return stbi__err("0 width", "Corrupt JPEG"); // JPEG requires
    if (s.*.img_y > STBI_MAX_DIMENSIONS) return stbi__err("too large", "Very large image (corrupt?)");
    if (s.*.img_x > STBI_MAX_DIMENSIONS) return stbi__err("too large", "Very large image (corrupt?)");
    c = stbi__get8(s);
    if (c != 3 and c != 1 and c != 4) return stbi__err("bad component count", "Corrupt JPEG");
    s.*.img_n = c;
    i = 0;
    while (i < c) : (i += 1) {
        z.*.img_comp[@intCast(i)].data = null;
        z.*.img_comp[@intCast(i)].linebuf = null;
    }

    if (Lf != 8 + 3 * s.*.img_n) return stbi__err("bad SOF len", "Corrupt JPEG");

    z.*.rgb = 0;
    i = 0;
    while (i < s.*.img_n) : (i += 1) {
        const rgb = [3]u8{ 'R', 'G', 'B' };
        const u: usize = @intCast(i);
        z.*.img_comp[u].id = stbi__get8(s);
        if (s.*.img_n == 3 and z.*.img_comp[u].id == rgb[u])
            z.*.rgb += 1;
        q = stbi__get8(s);
        z.*.img_comp[u].h = (q >> 4);
        if (z.*.img_comp[u].h == 0 or z.*.img_comp[u].h > 4) return stbi__err("bad H", "Corrupt JPEG");
        z.*.img_comp[u].v = q & 15;
        if (z.*.img_comp[u].v == 0 or z.*.img_comp[u].v > 4) return stbi__err("bad V", "Corrupt JPEG");
        z.*.img_comp[u].tq = stbi__get8(s);
        if (z.*.img_comp[u].tq > 3) return stbi__err("bad TQ", "Corrupt JPEG");
    }

    if (scan != STBI__SCAN_load) return 1;

    if (stbi__mad3sizes_valid(@intCast(s.*.img_x), @intCast(s.*.img_y), s.*.img_n, 0) == 0) return stbi__err("too large", "Image too large to decode");

    i = 0;
    while (i < s.*.img_n) : (i += 1) {
        const u: usize = @intCast(i);
        if (z.*.img_comp[u].h > h_max) h_max = z.*.img_comp[u].h;
        if (z.*.img_comp[u].v > v_max) v_max = z.*.img_comp[u].v;
    }

    // check that plane subsampling factors are integer ratios; our resamplers can't deal with fractional ratios
    // and I've never seen a non-corrupted JPEG file actually use them
    i = 0;
    while (i < s.*.img_n) : (i += 1) {
        const u: usize = @intCast(i);
        if (@rem(h_max, z.*.img_comp[u].h) != 0) return stbi__err("bad H", "Corrupt JPEG");
        if (@rem(v_max, z.*.img_comp[u].v) != 0) return stbi__err("bad V", "Corrupt JPEG");
    }

    // compute interleaved mcu info
    z.*.img_h_max = h_max;
    z.*.img_v_max = v_max;
    z.*.img_mcu_w = h_max * 8;
    z.*.img_mcu_h = v_max * 8;
    // these sizes can't be more than 17 bits
    const img_x: c_int = @intCast(s.*.img_x);
    const img_y: c_int = @intCast(s.*.img_y);
    z.*.img_mcu_x = @divTrunc(img_x + z.*.img_mcu_w - 1, z.*.img_mcu_w);
    z.*.img_mcu_y = @divTrunc(img_y + z.*.img_mcu_h - 1, z.*.img_mcu_h);

    i = 0;
    while (i < s.*.img_n) : (i += 1) {
        const u: usize = @intCast(i);
        const comp = &z.*.img_comp[u];
        // number of effective pixels (e.g. for non-interleaved MCU)
        comp.x = @divTrunc(img_x * comp.h + h_max - 1, h_max);
        comp.y = @divTrunc(img_y * comp.v + v_max - 1, v_max);
        // to simplify generation, we'll allocate enough memory to decode
        // the bogus oversized data from using interleaved MCUs and their
        // big blocks (e.g. a 16x16 iMCU on an image of width 33); we won't
        // discard the extra data until colorspace conversion
        //
        // img_mcu_x, img_mcu_y: <=17 bits; comp[i].h and .v are <=4 (checked earlier)
        // so these muls can't overflow with 32-bit ints (which we require)
        comp.w2 = z.*.img_mcu_x * comp.h * 8;
        comp.h2 = z.*.img_mcu_y * comp.v * 8;
        comp.coeff = null;
        comp.raw_coeff = null;
        comp.linebuf = null;
        comp.raw_data = stbi__malloc_mad2(comp.w2, comp.h2, 15);
        if (comp.raw_data == null)
            return stbi__free_jpeg_components(z, i + 1, stbi__err("outofmem", "Out of memory"));
        // align blocks for idct using mmx/sse
        comp.data = @ptrFromInt((@intFromPtr(comp.raw_data) + 15) & ~@as(usize, 15));
        if (z.*.progressive != 0) {
            // w2, h2 are multiples of 8 (see above)
            comp.coeff_w = @divTrunc(comp.w2, 8);
            comp.coeff_h = @divTrunc(comp.h2, 8);
            comp.raw_coeff = stbi__malloc_mad3(comp.w2, comp.h2, @sizeOf(c_short), 15);
            if (comp.raw_coeff == null)
                return stbi__free_jpeg_components(z, i + 1, stbi__err("outofmem", "Out of memory"));
            comp.coeff = @ptrFromInt((@intFromPtr(comp.raw_coeff) + 15) & ~@as(usize, 15));
        }
    }

    return 1;
}

// use comparisons since in some cases we handle more than one case (e.g. SOF)
inline fn stbi__DNL(x: c_int) bool {
    return x == 0xdc;
}
inline fn stbi__SOI(x: c_int) bool {
    return x == 0xd8;
}
inline fn stbi__EOI(x: c_int) bool {
    return x == 0xd9;
}
inline fn stbi__SOF(x: c_int) bool {
    return x == 0xc0 or x == 0xc1 or x == 0xc2;
}
inline fn stbi__SOS(x: c_int) bool {
    return x == 0xda;
}
inline fn stbi__SOF_progressive(x: c_int) c_int {
    return @intFromBool(x == 0xc2);
}

fn stbi__decode_jpeg_header(z: [*c]stbi__jpeg, scan: c_int) c_int {
    var m: c_int = undefined;
    z.*.jfif = 0;
    z.*.app14_color_transform = -1; // valid values are 0,1,2
    z.*.marker = STBI__MARKER_none; // initialize cached marker to empty
    m = stbi__get_marker(z);
    if (!stbi__SOI(m)) return stbi__err("no SOI", "Corrupt JPEG");
    if (scan == STBI__SCAN_type) return 1;
    m = stbi__get_marker(z);
    while (!stbi__SOF(m)) {
        if (stbi__process_marker(z, m) == 0) return 0;
        m = stbi__get_marker(z);
        while (m == STBI__MARKER_none) {
            // some files have extra padding after their blocks, so ok, we'll scan
            if (stbi__at_eof(z.*.s) != 0) return stbi__err("no SOF", "Corrupt JPEG");
            m = stbi__get_marker(z);
        }
    }
    z.*.progressive = stbi__SOF_progressive(m);
    if (stbi__process_frame_header(z, scan) == 0) return 0;
    return 1;
}

fn stbi__skip_jpeg_junk_at_end(j: [*c]stbi__jpeg) stbi_uc {
    // some JPEGs have junk at end, skip over it but if we find what looks
    // like a valid marker, resume there
    while (stbi__at_eof(j.*.s) == 0) {
        var x: stbi_uc = stbi__get8(j.*.s);
        while (x == 0xff) { // might be a marker
            if (stbi__at_eof(j.*.s) != 0) return STBI__MARKER_none;
            x = stbi__get8(j.*.s);
            if (x != 0x00 and x != 0xff) {
                // not a stuffed zero or lead-in to another marker, looks
                // like an actual marker, return it
                return x;
            }
            // stuffed zero has x=0 now which ends the loop, meaning we go
            // back to regular scan loop.
            // repeated 0xff keeps trying to read the next byte of the marker.
        }
    }
    return STBI__MARKER_none;
}

// decode image to YCbCr format
fn stbi__decode_jpeg_image(j: [*c]stbi__jpeg) c_int {
    var m: c_int = undefined;
    m = 0;
    while (m < 4) : (m += 1) {
        j.*.img_comp[@intCast(m)].raw_data = null;
        j.*.img_comp[@intCast(m)].raw_coeff = null;
    }
    j.*.restart_interval = 0;
    if (stbi__decode_jpeg_header(j, STBI__SCAN_load) == 0) return 0;
    m = stbi__get_marker(j);
    while (!stbi__EOI(m)) {
        if (stbi__SOS(m)) {
            if (stbi__process_scan_header(j) == 0) return 0;
            if (stbi__parse_entropy_coded_data(j) == 0) return 0;
            if (j.*.marker == STBI__MARKER_none) {
                j.*.marker = stbi__skip_jpeg_junk_at_end(j);
                // if we reach eof without hitting a marker, stbi__get_marker() below will fail and we'll eventually return 0
            }
            m = stbi__get_marker(j);
            if (STBI__RESTART(@truncate(@as(c_uint, @bitCast(m)))))
                m = stbi__get_marker(j);
        } else if (stbi__DNL(m)) {
            const Ld: c_int = stbi__get16be(j.*.s);
            const NL: stbi__uint32 = @intCast(stbi__get16be(j.*.s));
            if (Ld != 4) return stbi__err("bad DNL len", "Corrupt JPEG");
            if (NL != j.*.s.*.img_y) return stbi__err("bad DNL height", "Corrupt JPEG");
            m = stbi__get_marker(j);
        } else {
            if (stbi__process_marker(j, m) == 0) return 1;
            m = stbi__get_marker(j);
        }
    }
    if (j.*.progressive != 0)
        stbi__jpeg_finish(j);
    return 1;
}

// static jfif-centered resampling (across block boundaries)

// stbi__div4(x) ((stbi_uc) ((x) >> 2))
inline fn stbi__div4(x: c_int) stbi_uc {
    return @truncate(@as(c_uint, @bitCast(x)) >> 2);
}

// stbi__div16(x) ((stbi_uc) ((x) >> 4))
inline fn stbi__div16(x: c_int) stbi_uc {
    return @truncate(@as(c_uint, @bitCast(x)) >> 4);
}

fn resample_row_1(out: [*c]stbi_uc, in_near: [*c]stbi_uc, in_far: [*c]stbi_uc, w: c_int, hs: c_int) callconv(.c) [*c]stbi_uc {
    _ = out;
    _ = in_far;
    _ = w;
    _ = hs;
    return in_near;
}

fn stbi__resample_row_v_2(out: [*c]stbi_uc, in_near: [*c]stbi_uc, in_far: [*c]stbi_uc, w: c_int, hs: c_int) callconv(.c) [*c]stbi_uc {
    // need to generate two samples vertically for every one in input
    var i: c_int = 0;
    _ = hs;
    while (i < w) : (i += 1) {
        const u: usize = @intCast(i);
        out[u] = stbi__div4(3 * @as(c_int, in_near[u]) + in_far[u] + 2);
    }
    return out;
}

fn stbi__resample_row_h_2(out: [*c]stbi_uc, in_near: [*c]stbi_uc, in_far: [*c]stbi_uc, w: c_int, hs: c_int) callconv(.c) [*c]stbi_uc {
    // need to generate two samples horizontally for every one in input
    var i: c_int = undefined;
    const input: [*c]stbi_uc = in_near;

    if (w == 1) {
        // if only one sample, can't do any interpolation
        out[0] = input[0];
        out[1] = input[0];
        return out;
    }

    out[0] = input[0];
    out[1] = stbi__div4(@as(c_int, input[0]) * 3 + input[1] + 2);
    i = 1;
    while (i < w - 1) : (i += 1) {
        const iu: usize = @intCast(i);
        const n: c_int = 3 * @as(c_int, input[iu]) + 2;
        out[iu * 2 + 0] = stbi__div4(n + input[iu - 1]);
        out[iu * 2 + 1] = stbi__div4(n + input[iu + 1]);
    }
    const wu: usize = @intCast(w);
    const iu: usize = @intCast(i);
    out[iu * 2 + 0] = stbi__div4(@as(c_int, input[wu - 2]) * 3 + input[wu - 1] + 2);
    out[iu * 2 + 1] = input[wu - 1];

    _ = in_far;
    _ = hs;

    return out;
}

fn stbi__resample_row_hv_2(out: [*c]stbi_uc, in_near: [*c]stbi_uc, in_far: [*c]stbi_uc, w: c_int, hs: c_int) callconv(.c) [*c]stbi_uc {
    // need to generate 2x2 samples for every one in input
    var i: c_int = undefined;
    var t0: c_int = undefined;
    var t1: c_int = undefined;
    if (w == 1) {
        out[0] = stbi__div4(3 * @as(c_int, in_near[0]) + in_far[0] + 2);
        out[1] = out[0];
        return out;
    }

    t1 = 3 * @as(c_int, in_near[0]) + in_far[0];
    out[0] = stbi__div4(t1 + 2);
    i = 1;
    while (i < w) : (i += 1) {
        const iu: usize = @intCast(i);
        t0 = t1;
        t1 = 3 * @as(c_int, in_near[iu]) + in_far[iu];
        out[iu * 2 - 1] = stbi__div16(3 * t0 + t1 + 8);
        out[iu * 2] = stbi__div16(3 * t1 + t0 + 8);
    }
    out[@as(usize, @intCast(w)) * 2 - 1] = stbi__div4(t1 + 2);

    _ = hs;

    return out;
}

fn stbi__resample_row_generic(out: [*c]stbi_uc, in_near: [*c]stbi_uc, in_far: [*c]stbi_uc, w: c_int, hs: c_int) callconv(.c) [*c]stbi_uc {
    // resample with nearest-neighbor
    var i: c_int = 0;
    var j: c_int = undefined;
    _ = in_far;
    while (i < w) : (i += 1) {
        j = 0;
        while (j < hs) : (j += 1) {
            out[@intCast(i * hs + j)] = in_near[@intCast(i)];
        }
    }
    return out;
}

// this is a reduced-precision calculation of YCbCr-to-RGB introduced
// to make sure the code produces the same results in both SIMD and scalar
// stbi__float2fixed(x) (((int) ((x) * 4096.0f + 0.5f)) << 8)
inline fn stbi__float2fixed(comptime x: f32) c_int {
    return @as(c_int, @intFromFloat(x * 4096.0 + 0.5)) << 8;
}

fn stbi__YCbCr_to_RGB_row(out_: [*c]stbi_uc, y: [*c]const stbi_uc, pcb: [*c]const stbi_uc, pcr: [*c]const stbi_uc, count: c_int, step: c_int) callconv(.c) void {
    var out = out_;
    var i: c_int = 0;
    while (i < count) : (i += 1) {
        const u: usize = @intCast(i);
        const y_fixed: c_int = (@as(c_int, y[u]) << 20) + (1 << 19); // rounding
        var r: c_int = undefined;
        var g: c_int = undefined;
        var b: c_int = undefined;
        const cr: c_int = @as(c_int, pcr[u]) - 128;
        const cb: c_int = @as(c_int, pcb[u]) - 128;
        r = y_fixed + cr * stbi__float2fixed(1.40200);
        // (cb * -F) & 0xffff0000: the mask is an unsigned constant in C, the bits are the same
        const mask: c_int = @bitCast(@as(c_uint, 0xffff0000));
        g = y_fixed + (cr * -stbi__float2fixed(0.71414)) + ((cb * -stbi__float2fixed(0.34414)) & mask);
        b = y_fixed + cb * stbi__float2fixed(1.77200);
        r >>= 20;
        g >>= 20;
        b >>= 20;
        if (@as(c_uint, @bitCast(r)) > 255) {
            if (r < 0) r = 0 else r = 255;
        }
        if (@as(c_uint, @bitCast(g)) > 255) {
            if (g < 0) g = 0 else g = 255;
        }
        if (@as(c_uint, @bitCast(b)) > 255) {
            if (b < 0) b = 0 else b = 255;
        }
        out[0] = @intCast(r);
        out[1] = @intCast(g);
        out[2] = @intCast(b);
        out[3] = 255;
        out += @as(usize, @intCast(step));
    }
}

// the scalar kernels are the ones the C code uses when no SIMD kernel is selected
fn stbi__setup_jpeg(j: [*c]stbi__jpeg) void {
    j.*.idct_block_kernel = &stbi__idct_block;
    j.*.YCbCr_to_RGB_kernel = &stbi__YCbCr_to_RGB_row;
    j.*.resample_row_hv_2_kernel = &stbi__resample_row_hv_2;
}

// clean up the temporary component buffers
fn stbi__cleanup_jpeg(j: [*c]stbi__jpeg) void {
    _ = stbi__free_jpeg_components(j, j.*.s.*.img_n, 0);
}

const resample_row_func = *const fn (out: [*c]stbi_uc, in0: [*c]stbi_uc, in1: [*c]stbi_uc, w: c_int, hs: c_int) callconv(.c) [*c]stbi_uc;

const stbi__resample = struct {
    resample: ?resample_row_func,
    line0: [*c]stbi_uc,
    line1: [*c]stbi_uc,
    hs: c_int,
    vs: c_int, // expansion factor in each axis
    w_lores: c_int, // horizontal pixels pre-expansion
    ystep: c_int, // how far through vertical expansion we are
    ypos: c_int, // which pre-expansion row we're on
};

// fast 0..255 * 0..255 => 0..255 rounded multiplication
fn stbi__blinn_8x8(x: stbi_uc, y: stbi_uc) stbi_uc {
    const t: c_uint = @as(c_uint, x) * @as(c_uint, y) + 128;
    return @truncate((t + (t >> 8)) >> 8);
}

fn load_jpeg_image(z: [*c]stbi__jpeg, out_x: [*c]c_int, out_y: [*c]c_int, comp: [*c]c_int, req_comp: c_int) [*c]stbi_uc {
    var n: c_int = undefined;
    var decode_n: c_int = undefined;
    var is_rgb: bool = undefined;
    z.*.s.*.img_n = 0; // make stbi__cleanup_jpeg safe

    // validate req_comp
    if (req_comp < 0 or req_comp > 4) return stbi__errpuc("bad req_comp", "Internal error");

    // load a jpeg image from whichever source, but leave in YCbCr format
    if (stbi__decode_jpeg_image(z) == 0) {
        stbi__cleanup_jpeg(z);
        return null;
    }

    // determine actual number of components to generate
    n = if (req_comp != 0) req_comp else if (z.*.s.*.img_n >= 3) 3 else 1;

    is_rgb = z.*.s.*.img_n == 3 and (z.*.rgb == 3 or (z.*.app14_color_transform == 0 and z.*.jfif == 0));

    if (z.*.s.*.img_n == 3 and n < 3 and !is_rgb)
        decode_n = 1
    else
        decode_n = z.*.s.*.img_n;

    // nothing to do if no components requested; check this now to avoid
    // accessing uninitialized coutput[0] later
    if (decode_n <= 0) {
        stbi__cleanup_jpeg(z);
        return null;
    }

    // resample and color-convert
    const img_x: c_int = @intCast(z.*.s.*.img_x);
    const img_y: c_int = @intCast(z.*.s.*.img_y);
    const ux: usize = @intCast(img_x);
    var res_comp: [4]stbi__resample = undefined;
    var coutput: [4][*c]stbi_uc = .{ null, null, null, null };

    var k: c_int = 0;
    while (k < decode_n) : (k += 1) {
        const ku: usize = @intCast(k);
        const r: *stbi__resample = &res_comp[ku];

        // allocate line buffer big enough for upsampling off the edges
        // with upsample factor of 4
        z.*.img_comp[ku].linebuf = @ptrCast(@alignCast(stbi__malloc(@intCast(img_x + 3))));
        if (z.*.img_comp[ku].linebuf == null) {
            stbi__cleanup_jpeg(z);
            return stbi__errpuc("outofmem", "Out of memory");
        }

        r.hs = @divTrunc(z.*.img_h_max, z.*.img_comp[ku].h);
        r.vs = @divTrunc(z.*.img_v_max, z.*.img_comp[ku].v);
        r.ystep = r.vs >> 1;
        r.w_lores = @divTrunc(img_x + r.hs - 1, r.hs);
        r.ypos = 0;
        r.line0 = z.*.img_comp[ku].data;
        r.line1 = z.*.img_comp[ku].data;

        if (r.hs == 1 and r.vs == 1) {
            r.resample = &resample_row_1;
        } else if (r.hs == 1 and r.vs == 2) {
            r.resample = &stbi__resample_row_v_2;
        } else if (r.hs == 2 and r.vs == 1) {
            r.resample = &stbi__resample_row_h_2;
        } else if (r.hs == 2 and r.vs == 2) {
            r.resample = z.*.resample_row_hv_2_kernel;
        } else {
            r.resample = &stbi__resample_row_generic;
        }
    }

    // can't error after this so, this is safe
    const output: [*c]stbi_uc = @ptrCast(@alignCast(stbi__malloc_mad3(n, img_x, img_y, 1)));
    if (output == null) {
        stbi__cleanup_jpeg(z);
        return stbi__errpuc("outofmem", "Out of memory");
    }

    // now go ahead and resample
    var j: c_int = 0;
    while (j < img_y) : (j += 1) {
        var out: [*c]stbi_uc = output + @as(usize, @intCast(n)) * ux * @as(usize, @intCast(j));
        k = 0;
        while (k < decode_n) : (k += 1) {
            const ku: usize = @intCast(k);
            const r: *stbi__resample = &res_comp[ku];
            const y_bot: bool = r.ystep >= (r.vs >> 1);
            const resample = r.resample.?;
            coutput[ku] = resample(z.*.img_comp[ku].linebuf,
                if (y_bot) r.line1 else r.line0,
                if (y_bot) r.line0 else r.line1,
                r.w_lores,
                r.hs);
            r.ystep += 1;
            if (r.ystep >= r.vs) {
                r.ystep = 0;
                r.line0 = r.line1;
                r.ypos += 1;
                if (r.ypos < z.*.img_comp[ku].y)
                    r.line1 += @as(usize, @intCast(z.*.img_comp[ku].w2));
            }
        }
        if (n >= 3) {
            const y: [*c]stbi_uc = coutput[0];
            if (z.*.s.*.img_n == 3) {
                if (is_rgb) {
                    var i: usize = 0;
                    while (i < ux) : (i += 1) {
                        out[0] = y[i];
                        out[1] = coutput[1][i];
                        out[2] = coutput[2][i];
                        out[3] = 255;
                        out += @as(usize, @intCast(n));
                    }
                } else {
                    z.*.YCbCr_to_RGB_kernel.?(out, y, coutput[1], coutput[2], img_x, n);
                }
            } else if (z.*.s.*.img_n == 4) {
                if (z.*.app14_color_transform == 0) { // CMYK
                    var i: usize = 0;
                    while (i < ux) : (i += 1) {
                        const m: stbi_uc = coutput[3][i];
                        out[0] = stbi__blinn_8x8(coutput[0][i], m);
                        out[1] = stbi__blinn_8x8(coutput[1][i], m);
                        out[2] = stbi__blinn_8x8(coutput[2][i], m);
                        out[3] = 255;
                        out += @as(usize, @intCast(n));
                    }
                } else if (z.*.app14_color_transform == 2) { // YCCK
                    z.*.YCbCr_to_RGB_kernel.?(out, y, coutput[1], coutput[2], img_x, n);
                    var i: usize = 0;
                    while (i < ux) : (i += 1) {
                        const m: stbi_uc = coutput[3][i];
                        out[0] = stbi__blinn_8x8(255 - out[0], m);
                        out[1] = stbi__blinn_8x8(255 - out[1], m);
                        out[2] = stbi__blinn_8x8(255 - out[2], m);
                        out += @as(usize, @intCast(n));
                    }
                } else { // YCbCr + alpha?  Ignore the fourth channel for now
                    z.*.YCbCr_to_RGB_kernel.?(out, y, coutput[1], coutput[2], img_x, n);
                }
            } else {
                var i: usize = 0;
                while (i < ux) : (i += 1) {
                    out[0] = y[i];
                    out[1] = y[i];
                    out[2] = y[i];
                    out[3] = 255; // not used if n==3
                    out += @as(usize, @intCast(n));
                }
            }
        } else {
            if (is_rgb) {
                if (n == 1) {
                    var i: usize = 0;
                    while (i < ux) : (i += 1) {
                        out[0] = stbi__compute_y(@intCast(coutput[0][i]), @intCast(coutput[1][i]), @intCast(coutput[2][i]));
                        out += 1;
                    }
                } else {
                    var i: usize = 0;
                    while (i < ux) : ({
                        i += 1;
                        out += 2;
                    }) {
                        out[0] = stbi__compute_y(coutput[0][i], coutput[1][i], coutput[2][i]);
                        out[1] = 255;
                    }
                }
            } else if (z.*.s.*.img_n == 4 and z.*.app14_color_transform == 0) {
                var i: usize = 0;
                while (i < ux) : (i += 1) {
                    const m: stbi_uc = coutput[3][i];
                    const r: stbi_uc = stbi__blinn_8x8(coutput[0][i], m);
                    const g: stbi_uc = stbi__blinn_8x8(coutput[1][i], m);
                    const b: stbi_uc = stbi__blinn_8x8(coutput[2][i], m);
                    out[0] = stbi__compute_y(r, g, b);
                    out[1] = 255;
                    out += @as(usize, @intCast(n));
                }
            } else if (z.*.s.*.img_n == 4 and z.*.app14_color_transform == 2) {
                var i: usize = 0;
                while (i < ux) : (i += 1) {
                    out[0] = stbi__blinn_8x8(255 - coutput[0][i], coutput[3][i]);
                    out[1] = 255;
                    out += @as(usize, @intCast(n));
                }
            } else {
                const y: [*c]stbi_uc = coutput[0];
                if (n == 1) {
                    var i: usize = 0;
                    while (i < ux) : (i += 1) out[i] = y[i];
                } else {
                    var i: usize = 0;
                    while (i < ux) : (i += 1) {
                        out[0] = y[i];
                        out += 1;
                        out[0] = 255;
                        out += 1;
                    }
                }
            }
        }
    }
    stbi__cleanup_jpeg(z);
    out_x.* = img_x;
    out_y.* = img_y;
    if (comp != null) comp.* = if (z.*.s.*.img_n >= 3) 3 else 1; // report original components, not output
    return output;
}

fn stbi__jpeg_load(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info) ?*anyopaque {
    _ = ri; // STBI_NOTUSED(ri)
    const j: [*c]stbi__jpeg = @ptrCast(@alignCast(stbi__malloc(@sizeOf(stbi__jpeg))));
    if (j == null) return null; // stbi__errpuc("outofmem", "Out of memory")
    j.* = std.mem.zeroes(stbi__jpeg); // memset(j, 0, sizeof(stbi__jpeg))
    j.*.s = s;
    stbi__setup_jpeg(j);
    const result: [*c]stbi_uc = load_jpeg_image(j, x, y, comp, req_comp);
    base.rvn_free(j); // STBI_FREE(j)
    return result;
}

fn stbi__jpeg_test(s: [*c]stbi__context) c_int {
    const j: [*c]stbi__jpeg = @ptrCast(@alignCast(stbi__malloc(@sizeOf(stbi__jpeg))));
    if (j == null) return stbi__err("outofmem", "Out of memory");
    j.* = std.mem.zeroes(stbi__jpeg);
    j.*.s = s;
    stbi__setup_jpeg(j);
    const r: c_int = stbi__decode_jpeg_header(j, STBI__SCAN_type);
    stbi__rewind(s);
    base.rvn_free(j);
    return r;
}

fn stbi__jpeg_info_raw(j: [*c]stbi__jpeg, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    if (stbi__decode_jpeg_header(j, STBI__SCAN_header) == 0) {
        stbi__rewind(j.*.s);
        return 0;
    }
    if (x != null) x.* = @bitCast(j.*.s.*.img_x);
    if (y != null) y.* = @bitCast(j.*.s.*.img_y);
    if (comp != null) comp.* = if (j.*.s.*.img_n >= 3) 3 else 1;
    return 1;
}

fn stbi__jpeg_info(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    const j: [*c]stbi__jpeg = @ptrCast(@alignCast(stbi__malloc(@sizeOf(stbi__jpeg))));
    if (j == null) return stbi__err("outofmem", "Out of memory");
    j.* = std.mem.zeroes(stbi__jpeg);
    j.*.s = s;
    const result: c_int = stbi__jpeg_info_raw(j, x, y, comp);
    base.rvn_free(j);
    return result;
}

// ---- zlib (inflate) for PNG ----

const STBI__ZFAST_BITS: c_int = 9; // accelerate all cases in default tables
const STBI__ZFAST_MASK: c_int = (1 << STBI__ZFAST_BITS) - 1;
const STBI__ZNSYMS: c_int = 288; // number of symbols in literal/length alphabet

/// stbi__zhuffman: zlib-style huffman encoding (jpegs packs from left, zlib from right, so can't share code)
pub const stbi__zhuffman = extern struct {
    fast: [1 << STBI__ZFAST_BITS]stbi__uint16,
    firstcode: [16]stbi__uint16,
    maxcode: [17]c_int,
    firstsymbol: [16]stbi__uint16,
    size: [STBI__ZNSYMS]stbi_uc,
    value: [STBI__ZNSYMS]stbi__uint16,
};

/// stbi__zbuf: zlib-from-memory state for PNG reading
pub const stbi__zbuf = extern struct {
    zbuffer: [*c]stbi_uc,
    zbuffer_end: [*c]stbi_uc,
    num_bits: c_int,
    hit_zeof_once: c_int,
    code_buffer: stbi__uint32,

    zout: [*c]u8,
    zout_start: [*c]u8,
    zout_end: [*c]u8,
    z_expandable: c_int,

    z_length: stbi__zhuffman,
    z_distance: stbi__zhuffman,
};

inline fn stbi__bitreverse16(n_: c_int) c_int {
    var n = n_;
    n = ((n & 0xAAAA) >> 1) | ((n & 0x5555) << 1);
    n = ((n & 0xCCCC) >> 2) | ((n & 0x3333) << 2);
    n = ((n & 0xF0F0) >> 4) | ((n & 0x0F0F) << 4);
    n = ((n & 0xFF00) >> 8) | ((n & 0x00FF) << 8);
    return n;
}

inline fn stbi__bit_reverse(v: c_int, bits: c_int) c_int {
    // to bit reverse n bits, reverse 16 and shift
    // e.g. 11 bits, bit reverse and shift away 5
    return stbi__bitreverse16(v) >> @intCast(16 - bits);
}

fn stbi__zbuild_huffman(z: [*c]stbi__zhuffman, sizelist: [*c]const stbi_uc, num: c_int) c_int {
    var i: c_int = 0;
    var k: c_int = 0;
    var code: c_int = undefined;
    var next_code: [16]c_int = undefined;
    var sizes: [17]c_int = undefined;

    // DEFLATE spec for generating codes
    @memset(&sizes, 0);
    @memset(&z.*.fast, 0);
    i = 0;
    while (i < num) : (i += 1) {
        sizes[sizelist[@intCast(i)]] += 1;
    }
    sizes[0] = 0;
    i = 1;
    while (i < 16) : (i += 1) {
        if (sizes[@intCast(i)] > (@as(c_int, 1) << @intCast(i)))
            return stbi__err("bad sizes", "Corrupt PNG");
    }
    code = 0;
    i = 1;
    while (i < 16) : (i += 1) {
        const iu: usize = @intCast(i);
        next_code[iu] = code;
        z.*.firstcode[iu] = @truncate(@as(c_uint, @bitCast(code)));
        z.*.firstsymbol[iu] = @truncate(@as(c_uint, @bitCast(k)));
        code = (code + sizes[iu]);
        if (sizes[iu] != 0) {
            if (code - 1 >= (@as(c_int, 1) << @intCast(i)))
                return stbi__err("bad codelengths", "Corrupt PNG");
        }
        z.*.maxcode[iu] = code << @intCast(16 - i); // preshift for inner loop
        code <<= 1;
        k += sizes[iu];
    }
    z.*.maxcode[16] = 0x10000; // sentinel
    i = 0;
    while (i < num) : (i += 1) {
        const s: c_int = sizelist[@intCast(i)];
        if (s != 0) {
            const su: usize = @intCast(s);
            const c: c_int = next_code[su] - @as(c_int, z.*.firstcode[su]) + @as(c_int, z.*.firstsymbol[su]);
            const fastv: stbi__uint16 = @intCast((s << 9) | i);
            z.*.size[@intCast(c)] = @intCast(s);
            z.*.value[@intCast(c)] = @intCast(i);
            if (s <= STBI__ZFAST_BITS) {
                var j: c_int = stbi__bit_reverse(next_code[su], s);
                while (j < (@as(c_int, 1) << @intCast(STBI__ZFAST_BITS))) {
                    z.*.fast[@intCast(j)] = fastv;
                    j += @as(c_int, 1) << @intCast(s);
                }
            }
            next_code[su] += 1;
        }
    }
    return 1;
}

inline fn stbi__zeof(z: [*c]stbi__zbuf) c_int {
    return @intFromBool(z.*.zbuffer >= z.*.zbuffer_end);
}

inline fn stbi__zget8(z: [*c]stbi__zbuf) stbi_uc {
    if (stbi__zeof(z) != 0) return 0;
    const v = z.*.zbuffer[0];
    z.*.zbuffer += 1;
    return v;
}

fn stbi__fill_bits(z: [*c]stbi__zbuf) void {
    while (true) {
        if (z.*.code_buffer >= (@as(c_uint, 1) << @intCast(z.*.num_bits))) {
            z.*.zbuffer = z.*.zbuffer_end; // treat this as EOF so we fail.
            return;
        }
        z.*.code_buffer |= @as(stbi__uint32, stbi__zget8(z)) << @intCast(z.*.num_bits);
        z.*.num_bits += 8;
        if (!(z.*.num_bits <= 24)) break;
    }
}

inline fn stbi__zreceive(z: [*c]stbi__zbuf, n: c_int) c_uint {
    var k: c_uint = undefined;
    if (z.*.num_bits < n) stbi__fill_bits(z);
    k = @as(c_uint, @truncate(z.*.code_buffer)) & ((@as(c_uint, 1) << @intCast(n)) - 1);
    z.*.code_buffer >>= @intCast(n);
    z.*.num_bits -= n;
    return k;
}

fn stbi__zhuffman_decode_slowpath(a: [*c]stbi__zbuf, z: [*c]stbi__zhuffman) c_int {
    var s: c_int = undefined;
    // not resolved by fast table, so compute it the slow way
    // use jpeg approach, which requires MSbits at top
    const k: c_int = stbi__bit_reverse(@bitCast(a.*.code_buffer), 16);
    s = STBI__ZFAST_BITS + 1;
    while (true) : (s += 1) {
        if (k < z.*.maxcode[@intCast(s)]) break;
    }
    if (s >= 16) return -1; // invalid code!
    // code size is s, so:
    const b: c_int = (k >> @intCast(16 - s)) - @as(c_int, z.*.firstcode[@intCast(s)]) + @as(c_int, z.*.firstsymbol[@intCast(s)]);
    if (b >= STBI__ZNSYMS) return -1; // some data was corrupt somewhere!
    if (z.*.size[@intCast(b)] != s) return -1; // was originally an assert, but report failure instead.
    a.*.code_buffer >>= @intCast(s);
    a.*.num_bits -= s;
    return z.*.value[@intCast(b)];
}

inline fn stbi__zhuffman_decode(a: [*c]stbi__zbuf, z: [*c]stbi__zhuffman) c_int {
    var b: c_int = undefined;
    var s: c_int = undefined;
    if (a.*.num_bits < 16) {
        if (stbi__zeof(a) != 0) {
            if (a.*.hit_zeof_once == 0) {
                // This is the first time we hit eof, insert 16 extra padding btis
                // to allow us to keep going; if we actually consume any of them
                // though, that is invalid data. This is caught later.
                a.*.hit_zeof_once = 1;
                a.*.num_bits += 16; // add 16 implicit zero bits
            } else {
                // We already inserted our extra 16 padding bits and are again
                // out, this stream is actually prematurely terminated.
                return -1;
            }
        } else {
            stbi__fill_bits(a);
        }
    }
    b = z.*.fast[@intCast(a.*.code_buffer & @as(c_uint, @intCast(STBI__ZFAST_MASK)))];
    if (b != 0) {
        s = b >> 9;
        a.*.code_buffer >>= @intCast(s);
        a.*.num_bits -= s;
        return b & 511;
    }
    return stbi__zhuffman_decode_slowpath(a, z);
}

fn stbi__zexpand(z: [*c]stbi__zbuf, zout: [*c]u8, n: c_int) c_int { // need to make room for n bytes
    var q: [*c]u8 = undefined;
    var cur: c_uint = undefined;
    var limit: c_uint = undefined;
    z.*.zout = zout;
    if (z.*.z_expandable == 0) return stbi__err("output buffer limit", "Corrupt PNG");
    cur = @intCast(z.*.zout - z.*.zout_start);
    limit = @intCast(z.*.zout_end - z.*.zout_start);
    if (std.math.maxInt(c_uint) - cur < @as(c_uint, @bitCast(n))) return stbi__err("outofmem", "Out of memory");
    while (cur +% @as(c_uint, @bitCast(n)) > limit) {
        if (limit > std.math.maxInt(c_uint) / 2) return stbi__err("outofmem", "Out of memory");
        limit *= 2;
    }
    q = @ptrCast(@alignCast(base.rvn_realloc(z.*.zout_start, limit))); // STBI_REALLOC_SIZED(p, old, limit)
    if (q == null) return stbi__err("outofmem", "Out of memory");
    z.*.zout_start = q;
    z.*.zout = q + cur;
    z.*.zout_end = q + limit;
    return 1;
}

const stbi__zlength_base: [31]c_int = .{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258, 0, 0 };

const stbi__zlength_extra: [31]c_int = .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0 };

const stbi__zdist_base: [32]c_int = .{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 0, 0 };

const stbi__zdist_extra: [32]c_int = .{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 0, 0 };

fn stbi__parse_huffman_block(a: [*c]stbi__zbuf) c_int {
    var zout: [*c]u8 = a.*.zout;
    while (true) {
        var z: c_int = stbi__zhuffman_decode(a, &a.*.z_length);
        if (z < 256) {
            if (z < 0) return stbi__err("bad huffman code", "Corrupt PNG"); // error in huffman codes
            if (@intFromPtr(zout) >= @intFromPtr(a.*.zout_end)) {
                if (stbi__zexpand(a, zout, 1) == 0) return 0;
                zout = a.*.zout;
            }
            zout[0] = @truncate(@as(c_uint, @bitCast(z))); // (char) z
            zout += 1;
        } else {
            var p: [*c]stbi_uc = undefined;
            var len: c_int = undefined;
            var dist: c_int = undefined;
            if (z == 256) {
                a.*.zout = zout;
                if (a.*.hit_zeof_once != 0 and a.*.num_bits < 16) {
                    // The first time we hit zeof, we inserted 16 extra zero bits into our bit
                    // buffer so the decoder can just do its speculative decoding. But if we
                    // actually consumed any of those bits (which is the case when num_bits < 16),
                    // the stream actually read past the end so it is malformed.
                    return stbi__err("unexpected end", "Corrupt PNG");
                }
                return 1;
            }
            if (z >= 286) return stbi__err("bad huffman code", "Corrupt PNG"); // per DEFLATE, length codes 286 and 287 must not appear in compressed data
            z -= 257;
            len = stbi__zlength_base[@intCast(z)];
            if (stbi__zlength_extra[@intCast(z)] != 0) len += @as(c_int, @bitCast(stbi__zreceive(a, stbi__zlength_extra[@intCast(z)])));
            z = stbi__zhuffman_decode(a, &a.*.z_distance);
            if (z < 0 or z >= 30) return stbi__err("bad huffman code", "Corrupt PNG"); // per DEFLATE, distance codes 30 and 31 must not appear in compressed data
            dist = stbi__zdist_base[@intCast(z)];
            if (stbi__zdist_extra[@intCast(z)] != 0) dist += @as(c_int, @bitCast(stbi__zreceive(a, stbi__zdist_extra[@intCast(z)])));
            if (zout - a.*.zout_start < dist) return stbi__err("bad dist", "Corrupt PNG");
            if (len > a.*.zout_end - zout) {
                if (stbi__zexpand(a, zout, len) == 0) return 0;
                zout = a.*.zout;
            }
            p = zout - @as(usize, @intCast(dist));
            if (dist == 1) { // run of one byte; common in images.
                const v: stbi_uc = p[0];
                if (len != 0) {
                    while (true) {
                        zout[0] = v;
                        zout += 1;
                        len -= 1;
                        if (len == 0) break;
                    }
                }
            } else {
                if (len != 0) {
                    while (true) {
                        zout[0] = p[0];
                        zout += 1;
                        p += 1;
                        len -= 1;
                        if (len == 0) break;
                    }
                }
            }
        }
    }
}

fn stbi__compute_huffman_codes(a: [*c]stbi__zbuf) c_int {
    const length_dezigzag: [19]stbi_uc = .{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var z_codelength: stbi__zhuffman = undefined;
    var lencodes: [286 + 32 + 137]stbi_uc = undefined; // padding for maximum single op
    var codelength_sizes: [19]stbi_uc = undefined;
    var i: c_int = undefined;
    var n: c_int = undefined;

    const hlit: c_int = @as(c_int, @bitCast(stbi__zreceive(a, 5))) + 257;
    const hdist: c_int = @as(c_int, @bitCast(stbi__zreceive(a, 5))) + 1;
    const hclen: c_int = @as(c_int, @bitCast(stbi__zreceive(a, 4))) + 4;
    const ntot: c_int = hlit + hdist;

    @memset(&codelength_sizes, 0);
    i = 0;
    while (i < hclen) : (i += 1) {
        const s: c_int = @bitCast(stbi__zreceive(a, 3));
        codelength_sizes[length_dezigzag[@intCast(i)]] = @intCast(s);
    }
    if (stbi__zbuild_huffman(&z_codelength, &codelength_sizes, 19) == 0) return 0;

    n = 0;
    while (n < ntot) {
        var c: c_int = stbi__zhuffman_decode(a, &z_codelength);
        if (c < 0 or c >= 19) return stbi__err("bad codelengths", "Corrupt PNG");
        if (c < 16) {
            lencodes[@intCast(n)] = @intCast(c);
            n += 1;
        } else {
            var fill: stbi_uc = 0;
            if (c == 16) {
                c = @as(c_int, @bitCast(stbi__zreceive(a, 2))) + 3;
                if (n == 0) return stbi__err("bad codelengths", "Corrupt PNG");
                fill = lencodes[@intCast(n - 1)];
            } else if (c == 17) {
                c = @as(c_int, @bitCast(stbi__zreceive(a, 3))) + 3;
            } else if (c == 18) {
                c = @as(c_int, @bitCast(stbi__zreceive(a, 7))) + 11;
            } else {
                return stbi__err("bad codelengths", "Corrupt PNG");
            }
            if (ntot - n < c) return stbi__err("bad codelengths", "Corrupt PNG");
            @memset(lencodes[@intCast(n)..][0..@intCast(c)], fill);
            n += c;
        }
    }
    if (n != ntot) return stbi__err("bad codelengths", "Corrupt PNG");
    if (stbi__zbuild_huffman(&a.*.z_length, &lencodes, hlit) == 0) return 0;
    if (stbi__zbuild_huffman(&a.*.z_distance, @as([*c]stbi_uc, &lencodes) + @as(usize, @intCast(hlit)), hdist) == 0) return 0;
    return 1;
}

fn stbi__parse_uncompressed_block(a: [*c]stbi__zbuf) c_int {
    var header: [4]stbi_uc = undefined;
    var len: c_int = undefined;
    var nlen: c_int = undefined;
    var k: c_int = undefined;
    if ((a.*.num_bits & 7) != 0)
        _ = stbi__zreceive(a, a.*.num_bits & 7); // discard
    // drain the bit-packed data into header
    k = 0;
    while (a.*.num_bits > 0) {
        header[@intCast(k)] = @truncate(a.*.code_buffer & 255); // suppress MSVC run-time check
        k += 1;
        a.*.code_buffer >>= 8;
        a.*.num_bits -= 8;
    }
    if (a.*.num_bits < 0) return stbi__err("zlib corrupt", "Corrupt PNG");
    // now fill header the normal way
    while (k < 4) : (k += 1)
        header[@intCast(k)] = stbi__zget8(a);
    len = @as(c_int, header[1]) * 256 + header[0];
    nlen = @as(c_int, header[3]) * 256 + header[2];
    if (nlen != (len ^ 0xffff)) return stbi__err("zlib corrupt", "Corrupt PNG");
    const ulen: usize = @intCast(len);
    if (a.*.zbuffer + ulen > a.*.zbuffer_end) return stbi__err("read past buffer", "Corrupt PNG");
    if (a.*.zout + ulen > a.*.zout_end)
        if (stbi__zexpand(a, a.*.zout, len) == 0) return 0;
    @memcpy(a.*.zout[0..ulen], a.*.zbuffer[0..ulen]);
    a.*.zbuffer += ulen;
    a.*.zout += ulen;
    return 1;
}

fn stbi__parse_zlib_header(a: [*c]stbi__zbuf) c_int {
    const cmf: c_int = stbi__zget8(a);
    const cm: c_int = cmf & 15;
    // int cinfo = cmf >> 4;
    const flg: c_int = stbi__zget8(a);
    if (stbi__zeof(a) != 0) return stbi__err("bad zlib header", "Corrupt PNG"); // zlib spec
    if (@rem(cmf * 256 + flg, 31) != 0) return stbi__err("bad zlib header", "Corrupt PNG"); // zlib spec
    if ((flg & 32) != 0) return stbi__err("no preset dict", "Corrupt PNG"); // preset dictionary not allowed in png
    if (cm != 8) return stbi__err("bad compression", "Corrupt PNG"); // DEFLATE required for png
    // window = 1 << (8 + cinfo)... but who cares, we fully buffer output
    return 1;
}

// stbi__zdefault_length: 8 x144, 9 x112, 7 x24, 8 x8 (the Init algorithm of the C comment)
const stbi__zdefault_length: [288]stbi_uc = .{
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
};
const stbi__zdefault_distance: [32]stbi_uc = .{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 };

fn stbi__parse_zlib(a: [*c]stbi__zbuf, parse_header: c_int) c_int {
    var final: c_int = undefined;
    var typ: c_int = undefined;
    if (parse_header != 0)
        if (stbi__parse_zlib_header(a) == 0) return 0;
    a.*.num_bits = 0;
    a.*.code_buffer = 0;
    a.*.hit_zeof_once = 0;
    while (true) {
        final = @bitCast(stbi__zreceive(a, 1));
        typ = @bitCast(stbi__zreceive(a, 2));
        if (typ == 0) {
            if (stbi__parse_uncompressed_block(a) == 0) return 0;
        } else if (typ == 3) {
            return 0;
        } else {
            if (typ == 1) {
                // use fixed code lengths
                if (stbi__zbuild_huffman(&a.*.z_length, &stbi__zdefault_length, STBI__ZNSYMS) == 0) return 0;
                if (stbi__zbuild_huffman(&a.*.z_distance, &stbi__zdefault_distance, 32) == 0) return 0;
            } else {
                if (stbi__compute_huffman_codes(a) == 0) return 0;
            }
            if (stbi__parse_huffman_block(a) == 0) return 0;
        }
        if (final != 0) break;
    }
    return 1;
}

fn stbi__do_zlib(a: [*c]stbi__zbuf, obuf: [*c]u8, olen: c_int, exp: c_int, parse_header: c_int) c_int {
    a.*.zout_start = obuf;
    a.*.zout = obuf;
    a.*.zout_end = obuf + @as(usize, @intCast(olen));
    a.*.z_expandable = exp;

    return stbi__parse_zlib(a, parse_header);
}

/// STBIDEF char *stbi_zlib_decode_malloc_guesssize(const char *buffer, int len, int initial_size, int *outlen)
fn stbi_zlib_decode_malloc_guesssize(buffer: [*c]const u8, len: c_int, initial_size: c_int, outlen: [*c]c_int) [*c]u8 {
    var a: stbi__zbuf = undefined;
    const p: [*c]u8 = @ptrCast(@alignCast(stbi__malloc(@intCast(initial_size))));
    if (p == null) return null;
    a.zbuffer = @constCast(buffer);
    a.zbuffer_end = @constCast(buffer) + @as(usize, @intCast(len));
    if (stbi__do_zlib(&a, p, initial_size, 1, 1) != 0) {
        if (outlen != null) outlen.* = @truncate(@as(isize, @bitCast(a.zout - a.zout_start)));
        return a.zout_start;
    } else {
        base.rvn_free(a.zout_start); // STBI_FREE(a.zout_start)
        return null;
    }
}

/// STBIDEF char *stbi_zlib_decode_malloc(char const *buffer, int len, int *outlen)
fn stbi_zlib_decode_malloc(buffer: [*c]const u8, len: c_int, outlen: [*c]c_int) [*c]u8 {
    return stbi_zlib_decode_malloc_guesssize(buffer, len, 16384, outlen);
}

/// STBIDEF char *stbi_zlib_decode_malloc_guesssize_headerflag(const char *buffer, int len, int initial_size, int *outlen, int parse_header)
fn stbi_zlib_decode_malloc_guesssize_headerflag(buffer: [*c]const u8, len: c_int, initial_size: c_int, outlen: [*c]c_int, parse_header: c_int) [*c]u8 {
    var a: stbi__zbuf = undefined;
    const p: [*c]u8 = @ptrCast(@alignCast(stbi__malloc(@intCast(initial_size))));
    if (p == null) return null;
    a.zbuffer = @constCast(buffer);
    a.zbuffer_end = @constCast(buffer) + @as(usize, @intCast(len));
    if (stbi__do_zlib(&a, p, initial_size, 1, parse_header) != 0) {
        if (outlen != null) outlen.* = @truncate(@as(isize, @bitCast(a.zout - a.zout_start)));
        return a.zout_start;
    } else {
        base.rvn_free(a.zout_start);
        return null;
    }
}

/// STBIDEF int stbi_zlib_decode_buffer(char *obuffer, int olen, char const *ibuffer, int ilen)
fn stbi_zlib_decode_buffer(obuffer: [*c]u8, olen: c_int, ibuffer: [*c]const u8, ilen: c_int) c_int {
    var a: stbi__zbuf = undefined;
    a.zbuffer = @constCast(ibuffer);
    a.zbuffer_end = @constCast(ibuffer) + @as(usize, @intCast(ilen));
    if (stbi__do_zlib(&a, obuffer, olen, 0, 1) != 0)
        return @intCast(a.zout - a.zout_start)
    else
        return -1;
}

/// STBIDEF char *stbi_zlib_decode_noheader_malloc(char const *buffer, int len, int *outlen)
fn stbi_zlib_decode_noheader_malloc(buffer: [*c]const u8, len: c_int, outlen: [*c]c_int) [*c]u8 {
    var a: stbi__zbuf = undefined;
    const p: [*c]u8 = @ptrCast(@alignCast(stbi__malloc(16384)));
    if (p == null) return null;
    a.zbuffer = @constCast(buffer);
    a.zbuffer_end = @constCast(buffer) + @as(usize, @intCast(len));
    if (stbi__do_zlib(&a, p, 16384, 1, 0) != 0) {
        if (outlen != null) outlen.* = @truncate(@as(isize, @bitCast(a.zout - a.zout_start)));
        return a.zout_start;
    } else {
        base.rvn_free(a.zout_start);
        return null;
    }
}

/// STBIDEF int stbi_zlib_decode_noheader_buffer(char *obuffer, int olen, const char *ibuffer, int ilen)
fn stbi_zlib_decode_noheader_buffer(obuffer: [*c]u8, olen: c_int, ibuffer: [*c]const u8, ilen: c_int) c_int {
    var a: stbi__zbuf = undefined;
    a.zbuffer = @constCast(ibuffer);
    a.zbuffer_end = @constCast(ibuffer) + @as(usize, @intCast(ilen));
    if (stbi__do_zlib(&a, obuffer, olen, 0, 0) != 0)
        return @intCast(a.zout - a.zout_start)
    else
        return -1;
}

// ---- PNG (chunks, filters, interlace) ----

const stbi__pngchunk = extern struct {
    length: stbi__uint32,
    type_: stbi__uint32, // C field name is `type`
};

/// stbi__png
pub const stbi__png = extern struct {
    s: [*c]stbi__context,
    idata: [*c]stbi_uc,
    expanded: [*c]stbi_uc,
    out: [*c]stbi_uc,
    depth: c_int,
};

const STBI__F_none: c_int = 0;
const STBI__F_sub: c_int = 1;
const STBI__F_up: c_int = 2;
const STBI__F_avg: c_int = 3;
const STBI__F_paeth: c_int = 4;
// synthetic filter used for first scanline to avoid needing a dummy row of 0s
const STBI__F_avg_first: c_int = 5;

const first_row_filter: [5]c_int = .{ STBI__F_none, STBI__F_sub, STBI__F_none, STBI__F_avg_first, STBI__F_sub }; // Paeth with b=c=0 turns out to be equivalent to sub

inline fn stbi__get_chunk_header(s: [*c]stbi__context) stbi__pngchunk {
    var c: stbi__pngchunk = undefined;
    c.length = stbi__get32be(s);
    c.type_ = stbi__get32be(s);
    return c;
}

fn stbi__check_png_header(s: [*c]stbi__context) c_int {
    const png_sig = [8]stbi_uc{ 137, 80, 78, 71, 13, 10, 26, 10 };
    var i: c_int = 0;
    while (i < 8) : (i += 1) {
        if (stbi__get8(s) != png_sig[@intCast(i)]) return stbi__err("bad png sig", "Not a PNG");
    }
    return 1;
}

fn stbi__paeth(a: c_int, b: c_int, c: c_int) c_int {
    // This formulation looks very different from the reference in the PNG spec, but is
    // actually equivalent and has favorable data dependencies and admits straightforward
    // generation of branch-free code, which helps performance significantly.
    const thresh: c_int = c * 3 - (a + b);
    const lo: c_int = if (a < b) a else b;
    const hi: c_int = if (a < b) b else a;
    const t0: c_int = if (hi <= thresh) lo else c;
    const t1: c_int = if (thresh <= lo) hi else t0;
    return t1;
}

const stbi__depth_scale_table: [9]stbi_uc = .{ 0, 0xff, 0x55, 0, 0x11, 0, 0, 0, 0x01 };

// adds an extra all-255 alpha channel
// dest == src is legal
// img_n must be 1 or 3
fn stbi__create_png_alpha_expand8(dest: [*c]stbi_uc, src: [*c]stbi_uc, x: stbi__uint32, img_n: c_int) void {
    var i: c_int = undefined;
    // must process data backwards since we allow dest==src
    if (img_n == 1) {
        i = @as(c_int, @intCast(x)) - 1;
        while (i >= 0) : (i -= 1) {
            const iu: usize = @intCast(i);
            dest[iu * 2 + 1] = 255;
            dest[iu * 2 + 0] = src[iu];
        }
    } else {
        // STBI_ASSERT(img_n == 3);
        i = @as(c_int, @intCast(x)) - 1;
        while (i >= 0) : (i -= 1) {
            const iu: usize = @intCast(i);
            dest[iu * 4 + 3] = 255;
            dest[iu * 4 + 2] = src[iu * 3 + 2];
            dest[iu * 4 + 1] = src[iu * 3 + 1];
            dest[iu * 4 + 0] = src[iu * 3 + 0];
        }
    }
}

// create the png data from post-deflated data
fn stbi__create_png_image_raw(a: [*c]stbi__png, raw_: [*c]stbi_uc, raw_len: stbi__uint32, out_n: c_int, x: stbi__uint32, y: stbi__uint32, depth: c_int, color: c_int) c_int {
    var raw = raw_;
    const bytes: c_int = if (depth == 16) 2 else 1;
    const s: [*c]stbi__context = a.*.s;
    var i: stbi__uint32 = undefined;
    var j: stbi__uint32 = undefined;
    const stride: stbi__uint32 = x * @as(stbi__uint32, @intCast(out_n)) * @as(stbi__uint32, @intCast(bytes));
    var img_len: stbi__uint32 = undefined;
    var img_width_bytes: stbi__uint32 = undefined;
    var filter_buf: [*c]stbi_uc = undefined;
    var all_ok: c_int = 1;
    var k: c_int = undefined;
    const img_n: c_int = s.*.img_n; // copy it into a local for later

    const output_bytes: c_int = out_n * bytes;
    var filter_bytes: c_int = img_n * bytes;
    var width: c_int = @intCast(x);

    // STBI_ASSERT(out_n == s->img_n || out_n == s->img_n+1);
    a.*.out = @ptrCast(@alignCast(stbi__malloc_mad3(@intCast(x), @intCast(y), output_bytes, 0)));
    if (a.*.out == null) return stbi__err("outofmem", "Out of memory");

    // note: error exits here don't need to clean up a->out individually,
    // stbi__do_png always does on error.
    if (stbi__mad3sizes_valid(img_n, @intCast(x), depth, 7) == 0) return stbi__err("too large", "Corrupt PNG");
    img_width_bytes = @intCast(((img_n * @as(c_int, @intCast(x)) * depth) + 7) >> 3);
    if (stbi__mad2sizes_valid(@intCast(img_width_bytes), @intCast(y), @intCast(img_width_bytes)) == 0) return stbi__err("too large", "Corrupt PNG");
    img_len = (img_width_bytes + 1) * y;

    // we used to check for exact match between raw_len and img_len on non-interlaced PNGs,
    // but issue #276 reported a PNG in the wild that had extra data at the end (all zeros),
    // so just check for raw_len < img_len always.
    if (raw_len < img_len) return stbi__err("not enough pixels", "Corrupt PNG");

    // Allocate two scan lines worth of filter workspace buffer.
    filter_buf = @ptrCast(@alignCast(stbi__malloc_mad2(@intCast(img_width_bytes), 2, 0)));
    if (filter_buf == null) return stbi__err("outofmem", "Out of memory");

    // Filtering for low-bit-depth images
    if (depth < 8) {
        filter_bytes = 1;
        width = @intCast(img_width_bytes);
    }

    j = 0;
    while (j < y) : (j += 1) {
        // cur/prior filter buffers alternate
        const cur: [*c]stbi_uc = filter_buf + @as(usize, @intCast(j & 1)) * img_width_bytes;
        const prior: [*c]stbi_uc = filter_buf + @as(usize, @intCast((~j) & 1)) * img_width_bytes;
        const dest: [*c]stbi_uc = a.*.out + @as(usize, stride) * j;
        const nk: c_int = width * filter_bytes;
        var filter: c_int = raw[0];
        raw += 1;

        // check filter type
        if (filter > 4) {
            all_ok = stbi__err("invalid filter", "Corrupt PNG");
            break;
        }

        // if first row, use special filter that doesn't sample previous row
        if (j == 0) filter = first_row_filter[@intCast(filter)];

        // perform actual filtering
        switch (filter) {
            STBI__F_none => {
                @memcpy(cur[0..@intCast(nk)], raw[0..@intCast(nk)]);
            },
            STBI__F_sub => {
                @memcpy(cur[0..@intCast(filter_bytes)], raw[0..@intCast(filter_bytes)]);
                k = filter_bytes;
                while (k < nk) : (k += 1) {
                    const ku: usize = @intCast(k);
                    cur[ku] = STBI__BYTECAST(@as(c_int, raw[ku]) + cur[ku - @as(usize, @intCast(filter_bytes))]);
                }
            },
            STBI__F_up => {
                k = 0;
                while (k < nk) : (k += 1) {
                    const ku: usize = @intCast(k);
                    cur[ku] = STBI__BYTECAST(@as(c_int, raw[ku]) + prior[ku]);
                }
            },
            STBI__F_avg => {
                k = 0;
                while (k < filter_bytes) : (k += 1) {
                    const ku: usize = @intCast(k);
                    cur[ku] = STBI__BYTECAST(@as(c_int, raw[ku]) + (prior[ku] >> 1));
                }
                k = filter_bytes;
                while (k < nk) : (k += 1) {
                    const ku: usize = @intCast(k);
                    const fb: usize = @intCast(filter_bytes);
                    cur[ku] = STBI__BYTECAST(@as(c_int, raw[ku]) + ((@as(c_int, prior[ku]) + cur[ku - fb]) >> 1));
                }
            },
            STBI__F_paeth => {
                k = 0;
                while (k < filter_bytes) : (k += 1) {
                    const ku: usize = @intCast(k);
                    cur[ku] = STBI__BYTECAST(@as(c_int, raw[ku]) + prior[ku]); // prior[k] == stbi__paeth(0,prior[k],0)
                }
                k = filter_bytes;
                while (k < nk) : (k += 1) {
                    const ku: usize = @intCast(k);
                    const fb: usize = @intCast(filter_bytes);
                    cur[ku] = STBI__BYTECAST(@as(c_int, raw[ku]) + stbi__paeth(cur[ku - fb], prior[ku], prior[ku - fb]));
                }
            },
            STBI__F_avg_first => {
                @memcpy(cur[0..@intCast(filter_bytes)], raw[0..@intCast(filter_bytes)]);
                k = filter_bytes;
                while (k < nk) : (k += 1) {
                    const ku: usize = @intCast(k);
                    cur[ku] = STBI__BYTECAST(@as(c_int, raw[ku]) + (@as(c_int, cur[ku - @as(usize, @intCast(filter_bytes))]) >> 1));
                }
            },
            else => {},
        }

        raw += @as(usize, @intCast(nk));

        // expand decoded bits in cur to dest, also adding an extra alpha channel if desired
        if (depth < 8) {
            const scale: stbi_uc = if (color == 0) stbi__depth_scale_table[@intCast(depth)] else 1; // scale grayscale values to 0..255 range
            var in_: [*c]stbi_uc = cur;
            var out: [*c]stbi_uc = dest;
            var inb: stbi_uc = 0;
            const nsmp: stbi__uint32 = x * @as(stbi__uint32, @intCast(img_n));

            // expand bits to bytes first
            if (depth == 4) {
                i = 0;
                while (i < nsmp) : (i += 1) {
                    if ((i & 1) == 0) {
                        inb = in_[0];
                        in_ += 1;
                    }
                    out[0] = @truncate(@as(c_uint, scale) * (@as(c_uint, inb) >> 4));
                    out += 1;
                    inb <<= 4;
                }
            } else if (depth == 2) {
                i = 0;
                while (i < nsmp) : (i += 1) {
                    if ((i & 3) == 0) {
                        inb = in_[0];
                        in_ += 1;
                    }
                    out[0] = @truncate(@as(c_uint, scale) * (@as(c_uint, inb) >> 6));
                    out += 1;
                    inb <<= 2;
                }
            } else {
                // STBI_ASSERT(depth == 1);
                i = 0;
                while (i < nsmp) : (i += 1) {
                    if ((i & 7) == 0) {
                        inb = in_[0];
                        in_ += 1;
                    }
                    out[0] = @truncate(@as(c_uint, scale) * (@as(c_uint, inb) >> 7));
                    out += 1;
                    inb <<= 1;
                }
            }

            // insert alpha=255 values if desired
            if (img_n != out_n)
                stbi__create_png_alpha_expand8(dest, dest, x, img_n);
        } else if (depth == 8) {
            if (img_n == out_n) {
                @memcpy(dest[0..@as(usize, @intCast(x)) * @as(usize, @intCast(img_n))], cur[0..@as(usize, @intCast(x)) * @as(usize, @intCast(img_n))]);
            } else {
                stbi__create_png_alpha_expand8(dest, cur, x, img_n);
            }
        } else if (depth == 16) {
            // convert the image data from big-endian to platform-native
            var dest16: [*c]stbi__uint16 = @ptrCast(@alignCast(dest));
            var cur_: [*c]stbi_uc = cur;
            const nsmp: stbi__uint32 = x * @as(stbi__uint32, @intCast(img_n));

            if (img_n == out_n) {
                i = 0;
                while (i < nsmp) : (i += 1) {
                    dest16[0] = (@as(stbi__uint16, cur_[0]) << 8) | cur_[1];
                    dest16 += 1;
                    cur_ += 2;
                }
            } else {
                // STBI_ASSERT(img_n+1 == out_n);
                if (img_n == 1) {
                    i = 0;
                    while (i < x) : (i += 1) {
                        dest16[0] = (@as(stbi__uint16, cur_[0]) << 8) | cur_[1];
                        dest16[1] = 0xffff;
                        dest16 += 2;
                        cur_ += 2;
                    }
                } else {
                    // STBI_ASSERT(img_n == 3);
                    i = 0;
                    while (i < x) : (i += 1) {
                        dest16[0] = (@as(stbi__uint16, cur_[0]) << 8) | cur_[1];
                        dest16[1] = (@as(stbi__uint16, cur_[2]) << 8) | cur_[3];
                        dest16[2] = (@as(stbi__uint16, cur_[4]) << 8) | cur_[5];
                        dest16[3] = 0xffff;
                        dest16 += 4;
                        cur_ += 6;
                    }
                }
            }
        }
    }

    base.rvn_free(filter_buf); // STBI_FREE(filter_buf)
    if (all_ok == 0) return 0;

    return 1;
}

fn stbi__create_png_image(a: [*c]stbi__png, image_data_: [*c]stbi_uc, image_data_len_: stbi__uint32, out_n: c_int, depth: c_int, color: c_int, interlaced: c_int) c_int {
    var image_data = image_data_;
    var image_data_len = image_data_len_;
    const bytes: c_int = if (depth == 16) 2 else 1;
    const out_bytes: c_int = out_n * bytes;
    var final: [*c]stbi_uc = undefined;
    var p: c_int = undefined;
    if (interlaced == 0)
        return stbi__create_png_image_raw(a, image_data, image_data_len, out_n, a.*.s.*.img_x, a.*.s.*.img_y, depth, color);

    // de-interlacing
    final = @ptrCast(@alignCast(stbi__malloc_mad3(@intCast(a.*.s.*.img_x), @intCast(a.*.s.*.img_y), out_bytes, 0)));
    if (final == null) return stbi__err("outofmem", "Out of memory");
    p = 0;
    while (p < 7) : (p += 1) {
        const xorig = [7]c_int{ 0, 4, 0, 2, 0, 1, 0 };
        const yorig = [7]c_int{ 0, 0, 4, 0, 2, 0, 1 };
        const xspc = [7]c_int{ 8, 8, 4, 4, 2, 2, 1 };
        const yspc = [7]c_int{ 8, 8, 8, 4, 4, 2, 2 };
        var i: c_int = undefined;
        var j: c_int = undefined;
        var x: c_int = undefined;
        var y: c_int = undefined;
        const pu: usize = @intCast(p);
        // pass1_x[4] = 0, pass1_x[5] = 1, pass1_x[12] = 1
        x = @divTrunc(@as(c_int, @intCast(a.*.s.*.img_x)) - xorig[pu] + xspc[pu] - 1, xspc[pu]);
        y = @divTrunc(@as(c_int, @intCast(a.*.s.*.img_y)) - yorig[pu] + yspc[pu] - 1, yspc[pu]);
        if (x != 0 and y != 0) {
            const img_len: stbi__uint32 = @intCast(((((a.*.s.*.img_n * x * depth) + 7) >> 3) + 1) * y);
            if (stbi__create_png_image_raw(a, image_data, image_data_len, out_n, @intCast(x), @intCast(y), depth, color) == 0) {
                base.rvn_free(final);
                return 0;
            }
            j = 0;
            while (j < y) : (j += 1) {
                i = 0;
                while (i < x) : (i += 1) {
                    const out_y: usize = @intCast(j * yspc[pu] + yorig[pu]);
                    const out_x: usize = @intCast(i * xspc[pu] + xorig[pu]);
                    const dst_off: usize = out_y * @as(usize, @intCast(a.*.s.*.img_x)) * @as(usize, @intCast(out_bytes)) + out_x * @as(usize, @intCast(out_bytes));
                    const src_off: usize = @as(usize, @intCast(j * x + i)) * @as(usize, @intCast(out_bytes));
                    @memcpy((final + dst_off)[0..@intCast(out_bytes)], (a.*.out + src_off)[0..@intCast(out_bytes)]);
                }
            }
            base.rvn_free(a.*.out);
            image_data += @as(usize, @intCast(img_len));
            image_data_len -= img_len;
        }
    }
    a.*.out = final;

    return 1;
}

fn stbi__compute_transparency(z: [*c]stbi__png, tc: *[3]stbi_uc, out_n: c_int) c_int {
    const s: [*c]stbi__context = z.*.s;
    var i: stbi__uint32 = undefined;
    const pixel_count: stbi__uint32 = s.*.img_x * s.*.img_y;
    var p: [*c]stbi_uc = z.*.out;

    // compute color-based transparency, assuming we've
    // already got 255 as the alpha value in the output
    // STBI_ASSERT(out_n == 2 || out_n == 4);

    if (out_n == 2) {
        i = 0;
        while (i < pixel_count) : (i += 1) {
            p[1] = if (p[0] == tc[0]) 0 else 255;
            p += 2;
        }
    } else {
        i = 0;
        while (i < pixel_count) : (i += 1) {
            if (p[0] == tc[0] and p[1] == tc[1] and p[2] == tc[2])
                p[3] = 0;
            p += 4;
        }
    }
    return 1;
}

fn stbi__compute_transparency16(z: [*c]stbi__png, tc: *[3]stbi__uint16, out_n: c_int) c_int {
    const s: [*c]stbi__context = z.*.s;
    var i: stbi__uint32 = undefined;
    const pixel_count: stbi__uint32 = s.*.img_x * s.*.img_y;
    var p: [*c]stbi__uint16 = @ptrCast(@alignCast(z.*.out));

    // compute color-based transparency, assuming we've
    // already got 65535 as the alpha value in the output
    // STBI_ASSERT(out_n == 2 || out_n == 4);

    if (out_n == 2) {
        i = 0;
        while (i < pixel_count) : (i += 1) {
            p[1] = if (p[0] == tc[0]) 0 else 65535;
            p += 2;
        }
    } else {
        i = 0;
        while (i < pixel_count) : (i += 1) {
            if (p[0] == tc[0] and p[1] == tc[1] and p[2] == tc[2])
                p[3] = 0;
            p += 4;
        }
    }
    return 1;
}

fn stbi__expand_png_palette(a: [*c]stbi__png, palette: [*c]stbi_uc, len: c_int, pal_img_n: c_int) c_int {
    var i: stbi__uint32 = undefined;
    const pixel_count: stbi__uint32 = a.*.s.*.img_x * a.*.s.*.img_y;
    var p: [*c]stbi_uc = undefined;
    var temp_out: [*c]stbi_uc = undefined;
    const orig: [*c]stbi_uc = a.*.out;

    p = @ptrCast(@alignCast(stbi__malloc_mad2(@intCast(pixel_count), pal_img_n, 0)));
    if (p == null) return stbi__err("outofmem", "Out of memory");

    // between here and free(out) below, exitting would leak
    temp_out = p;

    if (pal_img_n == 3) {
        i = 0;
        while (i < pixel_count) : (i += 1) {
            const n: usize = @as(usize, orig[i]) * 4;
            p[0] = palette[n];
            p[1] = palette[n + 1];
            p[2] = palette[n + 2];
            p += 3;
        }
    } else {
        i = 0;
        while (i < pixel_count) : (i += 1) {
            const n: usize = @as(usize, orig[i]) * 4;
            p[0] = palette[n];
            p[1] = palette[n + 1];
            p[2] = palette[n + 2];
            p[3] = palette[n + 3];
            p += 4;
        }
    }
    base.rvn_free(a.*.out);
    a.*.out = temp_out;

    _ = len; // STBI_NOTUSED(len)

    return 1;
}

var stbi__unpremultiply_on_load_global: c_int = 0;
var stbi__de_iphone_flag_global: c_int = 0;

/// STBIDEF void stbi_set_unpremultiply_on_load(int flag_true_if_should_unpremultiply)
fn stbi_set_unpremultiply_on_load(flag_true_if_should_unpremultiply: c_int) void {
    stbi__unpremultiply_on_load_global = flag_true_if_should_unpremultiply;
}

/// STBIDEF void stbi_convert_iphone_png_to_rgb(int flag_true_if_should_convert)
fn stbi_convert_iphone_png_to_rgb(flag_true_if_should_convert: c_int) void {
    stbi__de_iphone_flag_global = flag_true_if_should_convert;
}

// STBI_THREAD_LOCAL variants (the _thread functions set the thread's own value)
threadlocal var stbi__unpremultiply_on_load_local: c_int = 0;
threadlocal var stbi__unpremultiply_on_load_set: c_int = 0;
threadlocal var stbi__de_iphone_flag_local: c_int = 0;
threadlocal var stbi__de_iphone_flag_set: c_int = 0;

/// STBIDEF void stbi_set_unpremultiply_on_load_thread(int flag_true_if_should_unpremultiply)
fn stbi_set_unpremultiply_on_load_thread(flag_true_if_should_unpremultiply: c_int) void {
    stbi__unpremultiply_on_load_local = flag_true_if_should_unpremultiply;
    stbi__unpremultiply_on_load_set = 1;
}

/// STBIDEF void stbi_convert_iphone_png_to_rgb_thread(int flag_true_if_should_convert)
fn stbi_convert_iphone_png_to_rgb_thread(flag_true_if_should_convert: c_int) void {
    stbi__de_iphone_flag_local = flag_true_if_should_convert;
    stbi__de_iphone_flag_set = 1;
}

// #define stbi__unpremultiply_on_load (...)
inline fn stbi__unpremultiply_on_load() c_int {
    return if (stbi__unpremultiply_on_load_set != 0)
        stbi__unpremultiply_on_load_local
    else
        stbi__unpremultiply_on_load_global;
}

// #define stbi__de_iphone_flag (...)
inline fn stbi__de_iphone_flag() c_int {
    return if (stbi__de_iphone_flag_set != 0)
        stbi__de_iphone_flag_local
    else
        stbi__de_iphone_flag_global;
}

fn stbi__de_iphone(z: [*c]stbi__png) void {
    const s: [*c]stbi__context = z.*.s;
    var i: stbi__uint32 = undefined;
    const pixel_count: stbi__uint32 = s.*.img_x * s.*.img_y;
    var p: [*c]stbi_uc = z.*.out;

    if (s.*.img_out_n == 3) { // convert bgr to rgb
        i = 0;
        while (i < pixel_count) : (i += 1) {
            const t: stbi_uc = p[0];
            p[0] = p[2];
            p[2] = t;
            p += 3;
        }
    } else {
        // STBI_ASSERT(s->img_out_n == 4);
        if (stbi__unpremultiply_on_load() != 0) {
            // convert bgr to rgb and unpremultiply
            i = 0;
            while (i < pixel_count) : (i += 1) {
                const a: stbi_uc = p[3];
                const t: stbi_uc = p[0];
                if (a != 0) {
                    const half: c_int = @intCast(a / 2);
                    const av: c_int = a;
                    p[0] = @intCast(@divTrunc(@as(c_int, p[2]) * 255 + half, av));
                    p[1] = @intCast(@divTrunc(@as(c_int, p[1]) * 255 + half, av));
                    p[2] = @intCast(@divTrunc(@as(c_int, t) * 255 + half, av));
                } else {
                    p[0] = p[2];
                    p[2] = t;
                }
                p += 4;
            }
        } else {
            // convert bgr to rgb
            i = 0;
            while (i < pixel_count) : (i += 1) {
                const t: stbi_uc = p[0];
                p[0] = p[2];
                p[2] = t;
                p += 4;
            }
        }
    }
}

inline fn STBI__PNG_TYPE(a: u8, b: u8, c: u8, d: u8) stbi__uint32 {
    return (@as(c_uint, a) << 24) + (@as(c_uint, b) << 16) + (@as(c_uint, c) << 8) + @as(c_uint, d);
}

fn stbi__parse_png_file(z: [*c]stbi__png, scan: c_int, req_comp: c_int) c_int {
    const PNG_CgBI = comptime STBI__PNG_TYPE('C', 'g', 'B', 'I');
    const PNG_IHDR = comptime STBI__PNG_TYPE('I', 'H', 'D', 'R');
    const PNG_PLTE = comptime STBI__PNG_TYPE('P', 'L', 'T', 'E');
    const PNG_tRNS = comptime STBI__PNG_TYPE('t', 'R', 'N', 'S');
    const PNG_IDAT = comptime STBI__PNG_TYPE('I', 'D', 'A', 'T');
    const PNG_IEND = comptime STBI__PNG_TYPE('I', 'E', 'N', 'D');

    var palette: [1024]stbi_uc = undefined;
    var pal_img_n: stbi_uc = 0;
    var has_trans: stbi_uc = 0;
    var tc: [3]stbi_uc = .{ 0, 0, 0 };
    var tc16: [3]stbi__uint16 = undefined;
    var ioff: stbi__uint32 = 0;
    var idata_limit: stbi__uint32 = 0;
    var i: stbi__uint32 = undefined;
    var pal_len: stbi__uint32 = 0;
    var first: c_int = 1;
    var k: c_int = undefined;
    var interlace: c_int = 0;
    var color: c_int = 0;
    var is_iphone: c_int = 0;
    const s: [*c]stbi__context = z.*.s;

    z.*.expanded = null;
    z.*.idata = null;
    z.*.out = null;

    if (stbi__check_png_header(s) == 0) return 0;

    if (scan == STBI__SCAN_type) return 1;

    while (true) {
        const c: stbi__pngchunk = stbi__get_chunk_header(s);
        switch (c.type_) {
            PNG_CgBI => {
                is_iphone = 1;
                stbi__skip(s, @bitCast(c.length));
            },
            PNG_IHDR => {
                var comp: c_int = undefined;
                var filter: c_int = undefined;
                if (first == 0) return stbi__err("multiple IHDR", "Corrupt PNG");
                first = 0;
                if (c.length != 13) return stbi__err("bad IHDR len", "Corrupt PNG");
                s.*.img_x = stbi__get32be(s);
                s.*.img_y = stbi__get32be(s);
                if (s.*.img_y > STBI_MAX_DIMENSIONS) return stbi__err("too large", "Very large image (corrupt?)");
                if (s.*.img_x > STBI_MAX_DIMENSIONS) return stbi__err("too large", "Very large image (corrupt?)");
                z.*.depth = stbi__get8(s);
                if (z.*.depth != 1 and z.*.depth != 2 and z.*.depth != 4 and z.*.depth != 8 and z.*.depth != 16) return stbi__err("1/2/4/8/16-bit only", "PNG not supported: 1/2/4/8/16-bit only");
                color = stbi__get8(s);
                if (color > 6) return stbi__err("bad ctype", "Corrupt PNG");
                if (color == 3 and z.*.depth == 16) return stbi__err("bad ctype", "Corrupt PNG");
                if (color == 3) {
                    pal_img_n = 3;
                } else if ((color & 1) != 0) return stbi__err("bad ctype", "Corrupt PNG");
                comp = stbi__get8(s);
                if (comp != 0) return stbi__err("bad comp method", "Corrupt PNG");
                filter = stbi__get8(s);
                if (filter != 0) return stbi__err("bad filter method", "Corrupt PNG");
                interlace = stbi__get8(s);
                if (interlace > 1) return stbi__err("bad interlace method", "Corrupt PNG");
                if (s.*.img_x == 0 or s.*.img_y == 0) return stbi__err("0-pixel image", "Corrupt PNG");
                if (pal_img_n == 0) {
                    s.*.img_n = (if ((color & 2) != 0) @as(c_int, 3) else 1) + (if ((color & 4) != 0) @as(c_int, 1) else 0);
                    if (@divTrunc(@divTrunc(1 << 30, @as(c_int, @intCast(s.*.img_x))), s.*.img_n) < @as(c_int, @intCast(s.*.img_y))) return stbi__err("too large", "Image too large to decode");
                } else {
                    // if paletted, then pal_n is our final components, and
                    // img_n is # components to decompress/filter.
                    s.*.img_n = 1;
                    if (@divTrunc(@divTrunc(1 << 30, @as(c_int, @intCast(s.*.img_x))), 4) < @as(c_int, @intCast(s.*.img_y))) return stbi__err("too large", "Corrupt PNG");
                }
                // even with SCAN_header, have to scan to see if we have a tRNS
            },

            PNG_PLTE => {
                if (first != 0) return stbi__err("first not IHDR", "Corrupt PNG");
                if (c.length > 256 * 3) return stbi__err("invalid PLTE", "Corrupt PNG");
                pal_len = c.length / 3;
                if (pal_len * 3 != c.length) return stbi__err("invalid PLTE", "Corrupt PNG");
                i = 0;
                while (i < pal_len) : (i += 1) {
                    palette[i * 4 + 0] = stbi__get8(s);
                    palette[i * 4 + 1] = stbi__get8(s);
                    palette[i * 4 + 2] = stbi__get8(s);
                    palette[i * 4 + 3] = 255;
                }
            },

            PNG_tRNS => {
                if (first != 0) return stbi__err("first not IHDR", "Corrupt PNG");
                if (z.*.idata != null) return stbi__err("tRNS after IDAT", "Corrupt PNG");
                if (pal_img_n != 0) {
                    if (scan == STBI__SCAN_header) {
                        s.*.img_n = 4;
                        return 1;
                    }
                    if (pal_len == 0) return stbi__err("tRNS before PLTE", "Corrupt PNG");
                    if (c.length > pal_len) return stbi__err("bad tRNS len", "Corrupt PNG");
                    pal_img_n = 4;
                    i = 0;
                    while (i < c.length) : (i += 1) {
                        palette[i * 4 + 3] = stbi__get8(s);
                    }
                } else {
                    if ((s.*.img_n & 1) == 0) return stbi__err("tRNS with alpha", "Corrupt PNG");
                    if (c.length != @as(stbi__uint32, @intCast(s.*.img_n)) * 2) return stbi__err("bad tRNS len", "Corrupt PNG");
                    has_trans = 1;
                    // non-paletted with tRNS = constant alpha. if header-scanning, we can stop now.
                    if (scan == STBI__SCAN_header) {
                        s.*.img_n += 1;
                        return 1;
                    }
                    if (z.*.depth == 16) {
                        k = 0;
                        while (k < s.*.img_n and k < 3) : (k += 1) // extra loop test to suppress false GCC warning
                            tc16[@intCast(k)] = @truncate(@as(c_uint, @bitCast(stbi__get16be(s)))); // copy the values as-is
                    } else {
                        k = 0;
                        while (k < s.*.img_n and k < 3) : (k += 1)
                            tc[@intCast(k)] = @truncate((@as(c_uint, @bitCast(stbi__get16be(s))) & 255) * @as(c_uint, stbi__depth_scale_table[@intCast(z.*.depth)])); // non 8-bit images will be larger
                    }
                }
            },

            PNG_IDAT => {
                if (first != 0) return stbi__err("first not IHDR", "Corrupt PNG");
                if (pal_img_n != 0 and pal_len == 0) return stbi__err("no PLTE", "Corrupt PNG");
                if (scan == STBI__SCAN_header) {
                    // header scan definitely stops at first IDAT
                    if (pal_img_n != 0)
                        s.*.img_n = pal_img_n;
                    return 1;
                }
                if (c.length > (1 << 30)) return stbi__err("IDAT size limit", "IDAT section larger than 2^30 bytes");
                if (@as(c_int, @bitCast(ioff +% c.length)) < @as(c_int, @bitCast(ioff))) return 0;
                if (ioff + c.length > idata_limit) {
                    const idata_limit_old: stbi__uint32 = idata_limit;
                    var p: [*c]stbi_uc = undefined;
                    if (idata_limit == 0) idata_limit = if (c.length > 4096) c.length else 4096;
                    while (ioff + c.length > idata_limit)
                        idata_limit *= 2;
                    p = @ptrCast(@alignCast(base.rvn_realloc(z.*.idata, idata_limit))); // STBI_REALLOC_SIZED(z->idata, old, idata_limit)
                    if (p == null) return stbi__err("outofmem", "Out of memory");
                    _ = idata_limit_old;
                    z.*.idata = p;
                }
                if (stbi__getn(s, z.*.idata + @as(usize, ioff), @bitCast(c.length)) == 0) return stbi__err("outofdata", "Corrupt PNG");
                ioff += c.length;
            },

            PNG_IEND => {
                var raw_len: stbi__uint32 = undefined;
                var outlen: c_int = undefined;
                var bpl: stbi__uint32 = undefined;
                if (first != 0) return stbi__err("first not IHDR", "Corrupt PNG");
                if (scan != STBI__SCAN_load) return 1;
                if (z.*.idata == null) return stbi__err("no IDAT", "Corrupt PNG");
                // initial guess for decoded data size to avoid unnecessary reallocs
                bpl = @divTrunc(s.*.img_x * @as(stbi__uint32, @intCast(z.*.depth)) + 7, 8); // bytes per line, per component
                raw_len = bpl * s.*.img_y * @as(stbi__uint32, @intCast(s.*.img_n)) + s.*.img_y; // pixels, plus the filter mode per row
                z.*.expanded = stbi_zlib_decode_malloc_guesssize_headerflag(z.*.idata, @intCast(ioff), @intCast(raw_len), &outlen, @intFromBool(is_iphone == 0));
                if (z.*.expanded == null) return 0; // zlib should set error
                raw_len = @intCast(outlen); // (int *) &raw_len
                base.rvn_free(z.*.idata);
                z.*.idata = null;
                if ((req_comp == s.*.img_n + 1 and req_comp != 3 and pal_img_n == 0) or has_trans != 0)
                    s.*.img_out_n = s.*.img_n + 1
                else
                    s.*.img_out_n = s.*.img_n;
                if (stbi__create_png_image(z, z.*.expanded, raw_len, s.*.img_out_n, z.*.depth, color, interlace) == 0) return 0;
                if (has_trans != 0) {
                    if (z.*.depth == 16) {
                        if (stbi__compute_transparency16(z, &tc16, s.*.img_out_n) == 0) return 0;
                    } else {
                        if (stbi__compute_transparency(z, &tc, s.*.img_out_n) == 0) return 0;
                    }
                }
                if (is_iphone != 0 and stbi__de_iphone_flag() != 0 and s.*.img_out_n > 2)
                    stbi__de_iphone(z);
                if (pal_img_n != 0) {
                    // pal_img_n == 3 or 4
                    s.*.img_n = pal_img_n; // record the actual colors we had
                    s.*.img_out_n = pal_img_n;
                    if (req_comp >= 3) s.*.img_out_n = req_comp;
                    if (stbi__expand_png_palette(z, &palette, @intCast(pal_len), s.*.img_out_n) == 0)
                        return 0;
                } else if (has_trans != 0) {
                    // non-paletted image with tRNS -> source image has (constant) alpha
                    s.*.img_n += 1;
                }
                base.rvn_free(z.*.expanded);
                z.*.expanded = null;
                // end of PNG chunk, read and skip CRC
                _ = stbi__get32be(s);
                return 1;
            },

            else => {
                // if critical, fail
                if (first != 0) return stbi__err("first not IHDR", "Corrupt PNG");
                if ((c.type_ & (1 << 29)) == 0) {
                    // STBI_NO_FAILURE_STRINGS: stbi__err(invalid_chunk, ...) is 0
                    return stbi__err("", "PNG not supported: unknown PNG chunk type");
                }
                stbi__skip(s, @bitCast(c.length));
            },
        }
        // end of PNG chunk, read and skip CRC
        _ = stbi__get32be(s);
    }
}

fn stbi__do_png(p: [*c]stbi__png, x: [*c]c_int, y: [*c]c_int, n: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info) ?*anyopaque {
    var result: ?*anyopaque = null;
    if (req_comp < 0 or req_comp > 4) return stbi__errpuc("bad req_comp", "Internal error");
    if (stbi__parse_png_file(p, STBI__SCAN_load, req_comp) != 0) {
        if (p.*.depth <= 8)
            ri.*.bits_per_channel = 8
        else if (p.*.depth == 16)
            ri.*.bits_per_channel = 16
        else
            return stbi__errpuc("bad bits_per_channel", "PNG not supported: unsupported color depth");
        result = p.*.out;
        p.*.out = null;
        if (req_comp != 0 and req_comp != p.*.s.*.img_out_n) {
            if (ri.*.bits_per_channel == 8) {
                result = stbi__convert_format(@ptrCast(@alignCast(result)), p.*.s.*.img_out_n, req_comp, p.*.s.*.img_x, p.*.s.*.img_y);
            } else {
                result = stbi__convert_format16(@ptrCast(@alignCast(result)), p.*.s.*.img_out_n, req_comp, p.*.s.*.img_x, p.*.s.*.img_y);
            }
            p.*.s.*.img_out_n = req_comp;
            if (result == null) return result;
        }
        x.* = @bitCast(p.*.s.*.img_x);
        y.* = @bitCast(p.*.s.*.img_y);
        if (n != null) n.* = p.*.s.*.img_n;
    }
    base.rvn_free(p.*.out);
    p.*.out = null;
    base.rvn_free(p.*.expanded);
    p.*.expanded = null;
    base.rvn_free(p.*.idata);
    p.*.idata = null;

    return result;
}

fn stbi__png_load(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info) ?*anyopaque {
    var p: stbi__png = std.mem.zeroes(stbi__png);
    p.s = s;
    return stbi__do_png(&p, x, y, comp, req_comp, ri);
}

fn stbi__png_test(s: [*c]stbi__context) c_int {
    const r: c_int = stbi__check_png_header(s);
    stbi__rewind(s);
    return r;
}

fn stbi__png_info_raw(p: [*c]stbi__png, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    if (stbi__parse_png_file(p, STBI__SCAN_header, 0) == 0) {
        stbi__rewind(p.*.s);
        return 0;
    }
    if (x != null) x.* = @bitCast(p.*.s.*.img_x);
    if (y != null) y.* = @bitCast(p.*.s.*.img_y);
    if (comp != null) comp.* = p.*.s.*.img_n;
    return 1;
}

fn stbi__png_info(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    var p: stbi__png = std.mem.zeroes(stbi__png);
    p.s = s;
    return stbi__png_info_raw(&p, x, y, comp);
}

fn stbi__png_is16(s: [*c]stbi__context) c_int {
    var p: stbi__png = std.mem.zeroes(stbi__png);
    p.s = s;
    if (stbi__png_info_raw(&p, null, null, null) == 0)
        return 0;
    if (p.depth != 16) {
        stbi__rewind(p.s);
        return 0;
    }
    return 1;
}

// ---- BMP ----

/// stbi__bmp_data
pub const stbi__bmp_data = extern struct {
    bpp: c_int,
    offset: c_int,
    hsz: c_int,
    mr: c_uint,
    mg: c_uint,
    mb: c_uint,
    ma: c_uint,
    all_a: c_uint,
    extra_read: c_int,
};

fn stbi__bmp_test_raw(s: [*c]stbi__context) c_int {
    var r: c_int = undefined;
    var sz: c_int = undefined;
    if (stbi__get8(s) != 'B') return 0;
    if (stbi__get8(s) != 'M') return 0;
    _ = stbi__get32le(s); // discard filesize
    _ = stbi__get16le(s); // discard reserved
    _ = stbi__get16le(s); // discard reserved
    _ = stbi__get32le(s); // discard data offset
    sz = @bitCast(stbi__get32le(s));
    r = @intFromBool(sz == 12 or sz == 40 or sz == 56 or sz == 108 or sz == 124);
    return r;
}

fn stbi__bmp_test(s: [*c]stbi__context) c_int {
    const r: c_int = stbi__bmp_test_raw(s);
    stbi__rewind(s);
    return r;
}

// returns 0..31 for the highest set bit
fn stbi__high_bit(z_: c_uint) c_int {
    var z = z_;
    var n: c_int = 0;
    if (z == 0) return -1;
    if (z >= 0x10000) {
        n += 16;
        z >>= 16;
    }
    if (z >= 0x00100) {
        n += 8;
        z >>= 8;
    }
    if (z >= 0x00010) {
        n += 4;
        z >>= 4;
    }
    if (z >= 0x00004) {
        n += 2;
        z >>= 2;
    }
    if (z >= 0x00002) {
        n += 1; // C: >>= 1 is commented out
    }
    return n;
}

fn stbi__bitcount(a_: c_uint) c_int {
    var a = a_;
    a = (a & 0x55555555) + ((a >> 1) & 0x55555555); // max 2
    a = (a & 0x33333333) + ((a >> 2) & 0x33333333); // max 4
    a = (a + (a >> 4)) & 0x0f0f0f0f; // max 8 per 4, now 8 bits
    a = (a + (a >> 8)); // max 16 per 8 bits
    a = (a + (a >> 16)); // max 32 per 8 bits
    return @intCast(a & 0xff);
}

// extract an arbitrarily-aligned N-bit value (N=bits)
// from v, and then make it 8-bits long and fractionally
// extend it to full full range.
fn stbi__shiftsigned(v_: c_uint, shift: c_int, bits: c_int) c_int {
    const mul_table = [9]c_uint{
        0,
        0xff, // 0b11111111
        0x55, // 0b01010101
        0x49, // 0b01001001
        0x11, // 0b00010001
        0x21, // 0b00100001
        0x41, // 0b01000001
        0x81, // 0b10000001
        0x01, // 0b00000001
    };
    const shift_table = [9]c_uint{ 0, 0, 0, 1, 0, 2, 4, 6, 0 };
    var v = v_;
    if (shift < 0) {
        v <<= @intCast(-shift);
    } else {
        v >>= @intCast(shift);
    }
    // STBI_ASSERT(v < 256);
    v >>= @intCast(8 - bits);
    // STBI_ASSERT(bits >= 0 && bits <= 8);
    return @as(c_int, @bitCast((v * mul_table[@intCast(bits)]))) >> @intCast(shift_table[@intCast(bits)]);
}

fn stbi__bmp_set_mask_defaults(info: [*c]stbi__bmp_data, compress: c_int) c_int {
    // BI_BITFIELDS specifies masks explicitly, don't override
    if (compress == 3) return 1;

    if (compress == 0) {
        if (info.*.bpp == 16) {
            info.*.mr = 31 << 10;
            info.*.mg = 31 << 5;
            info.*.mb = 31 << 0;
        } else if (info.*.bpp == 32) {
            info.*.mr = 0xff << 16;
            info.*.mg = 0xff << 8;
            info.*.mb = 0xff << 0;
            info.*.ma = 0xff << 24;
            info.*.all_a = 0; // if all_a is 0 at end, then we loaded alpha channel but it was all 0
        } else {
            // otherwise, use defaults, which is all-0
            info.*.mr = 0;
            info.*.mg = 0;
            info.*.mb = 0;
            info.*.ma = 0;
        }
        return 1;
    }
    return 0; // error
}

// returns 1 on success, 0 where the C code returns NULL (every error of this function
// returns NULL through stbi__errpuc, which is NULL under STBI_NO_FAILURE_STRINGS)
fn stbi__bmp_parse_header(s: [*c]stbi__context, info: [*c]stbi__bmp_data) c_int {
    var hsz: c_int = undefined;
    if (stbi__get8(s) != 'B' or stbi__get8(s) != 'M') return 0; // not BMP
    _ = stbi__get32le(s); // discard filesize
    _ = stbi__get16le(s); // discard reserved
    _ = stbi__get16le(s); // discard reserved
    info.*.offset = @bitCast(stbi__get32le(s));
    hsz = @bitCast(stbi__get32le(s));
    info.*.hsz = hsz;
    info.*.mr = 0;
    info.*.mg = 0;
    info.*.mb = 0;
    info.*.ma = 0;
    info.*.extra_read = 14;

    if (info.*.offset < 0) return 0; // bad BMP

    if (hsz != 12 and hsz != 40 and hsz != 56 and hsz != 108 and hsz != 124) return 0; // unknown BMP
    if (hsz == 12) {
        s.*.img_x = @intCast(stbi__get16le(s));
        s.*.img_y = @intCast(stbi__get16le(s));
    } else {
        s.*.img_x = stbi__get32le(s);
        s.*.img_y = stbi__get32le(s);
    }
    if (stbi__get16le(s) != 1) return 0; // bad BMP
    info.*.bpp = stbi__get16le(s);
    if (hsz != 12) {
        const compress: c_int = @bitCast(stbi__get32le(s));
        if (compress == 1 or compress == 2) return 0; // BMP RLE: not supported
        if (compress >= 4) return 0; // BMP JPEG/PNG: unsupported compression, this includes PNG/JPEG modes
        if (compress == 3 and info.*.bpp != 16 and info.*.bpp != 32) return 0; // bitfields requires 16 or 32 bits/pixel
        _ = stbi__get32le(s); // discard sizeof
        _ = stbi__get32le(s); // discard hres
        _ = stbi__get32le(s); // discard vres
        _ = stbi__get32le(s); // discard colorsused
        _ = stbi__get32le(s); // discard max important
        if (hsz == 40 or hsz == 56) {
            if (hsz == 56) {
                _ = stbi__get32le(s);
                _ = stbi__get32le(s);
                _ = stbi__get32le(s);
                _ = stbi__get32le(s);
            }
            if (info.*.bpp == 16 or info.*.bpp == 32) {
                if (compress == 0) {
                    _ = stbi__bmp_set_mask_defaults(info, compress);
                } else if (compress == 3) {
                    info.*.mr = stbi__get32le(s);
                    info.*.mg = stbi__get32le(s);
                    info.*.mb = stbi__get32le(s);
                    info.*.extra_read += 12;
                    // not documented, but generated by photoshop and handled by mspaint
                    if (info.*.mr == info.*.mg and info.*.mg == info.*.mb) {
                        // ?!?!?
                        return 0; // bad BMP
                    }
                } else return 0; // bad BMP
            }
        } else {
            // V4/V5 header
            var i: c_int = undefined;
            if (hsz != 108 and hsz != 124) return 0; // bad BMP
            info.*.mr = stbi__get32le(s);
            info.*.mg = stbi__get32le(s);
            info.*.mb = stbi__get32le(s);
            info.*.ma = stbi__get32le(s);
            if (compress != 3) // override mr/mg/mb unless in BI_BITFIELDS mode, as per docs
                _ = stbi__bmp_set_mask_defaults(info, compress);
            _ = stbi__get32le(s); // discard color space
            i = 0;
            while (i < 12) : (i += 1)
                _ = stbi__get32le(s); // discard color space parameters
            if (hsz == 124) {
                _ = stbi__get32le(s); // discard rendering intent
                _ = stbi__get32le(s); // discard offset of profile data
                _ = stbi__get32le(s); // discard size of profile data
                _ = stbi__get32le(s); // discard reserved
            }
        }
    }
    return 1;
}

fn stbi__bmp_load(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info) ?*anyopaque {
    var out: [*c]stbi_uc = undefined;
    var mr: c_uint = 0;
    var mg: c_uint = 0;
    var mb: c_uint = 0;
    var ma: c_uint = 0;
    var all_a: c_uint = undefined;
    // stbi_uc pal[256][4] is not initialised in C; entries past the palette are read by corrupt files
    var pal: [256][4]stbi_uc = std.mem.zeroes([256][4]stbi_uc);
    var psize: c_int = 0;
    var i: c_int = undefined;
    var j: c_int = undefined;
    var width: c_int = undefined;
    var flip_vertically: c_int = undefined;
    var pad: c_int = undefined;
    var target: c_int = undefined;
    var info: stbi__bmp_data = undefined;
    _ = ri; // STBI_NOTUSED(ri)

    info.all_a = 255;
    if (stbi__bmp_parse_header(s, &info) == 0)
        return null; // error code already set

    const iy: c_int = @bitCast(s.*.img_y);
    flip_vertically = @intFromBool(iy > 0);
    s.*.img_y = @abs(iy);

    if (s.*.img_y > STBI_MAX_DIMENSIONS) return null; // too large
    if (s.*.img_x > STBI_MAX_DIMENSIONS) return null; // too large

    mr = info.mr;
    mg = info.mg;
    mb = info.mb;
    ma = info.ma;
    all_a = info.all_a;

    if (info.hsz == 12) {
        if (info.bpp < 24)
            psize = @divTrunc(info.offset - info.extra_read - 24, 3);
    } else {
        if (info.bpp < 16)
            psize = (info.offset - info.extra_read - info.hsz) >> 2;
    }
    if (psize == 0) {
        // accept some number of extra bytes after the header, but if the offset points either to before
        // the header ends or implies a large amount of extra data, reject the file as malformed
        const bytes_read_so_far: c_int = s.*.callback_already_read + @as(c_int, @intCast(s.*.img_buffer - s.*.img_buffer_original));
        const header_limit: c_int = 1024; // max we actually read is below 256 bytes currently.
        const extra_data_limit: c_int = 256 * 4; // what ordinarily goes here is a palette; 256 entries*4 bytes is its max size.
        if (bytes_read_so_far <= 0 or bytes_read_so_far > header_limit) {
            return null; // bad header
        }
        // we established that bytes_read_so_far is positive and sensible.
        // the first half of this test rejects offsets that are either too small positives, or
        // negative, and guarantees that info.offset >= bytes_read_so_far > 0. this in turn
        // ensures the number computed in the second half of the test can't overflow.
        if (info.offset < bytes_read_so_far or info.offset - bytes_read_so_far > extra_data_limit) {
            return null; // bad offset
        } else {
            stbi__skip(s, info.offset - bytes_read_so_far);
        }
    }

    if (info.bpp == 24 and ma == 0xff000000) {
        s.*.img_n = 3;
    } else {
        s.*.img_n = if (ma != 0) 4 else 3;
    }
    if (req_comp != 0 and req_comp >= 3) // we can directly decode 3 or 4
        target = req_comp
    else
        target = s.*.img_n; // if they want monochrome, we'll post-convert

    // sanity-check size
    if (stbi__mad3sizes_valid(target, @intCast(s.*.img_x), @intCast(s.*.img_y), 0) == 0)
        return null; // too large

    out = @ptrCast(@alignCast(stbi__malloc_mad3(target, @intCast(s.*.img_x), @intCast(s.*.img_y), 0)));
    if (out == null) return null; // outofmem
    if (info.bpp < 16) {
        var z: c_int = 0;
        if (psize == 0 or psize > 256) {
            base.rvn_free(out);
            return null; // invalid, Corrupt BMP
        }
        i = 0;
        while (i < psize) : (i += 1) {
            const iu: usize = @intCast(i);
            pal[iu][2] = stbi__get8(s);
            pal[iu][1] = stbi__get8(s);
            pal[iu][0] = stbi__get8(s);
            if (info.hsz != 12) _ = stbi__get8(s);
            pal[iu][3] = 255;
        }
        stbi__skip(s, info.offset - info.extra_read - info.hsz - psize * (if (info.hsz == 12) @as(c_int, 3) else 4));
        if (info.bpp == 1) {
            width = @intCast((s.*.img_x + 7) >> 3);
        } else if (info.bpp == 4) {
            width = @intCast((s.*.img_x + 1) >> 1);
        } else if (info.bpp == 8) {
            width = @intCast(s.*.img_x);
        } else {
            base.rvn_free(out);
            return null; // bad bpp, Corrupt BMP
        }
        pad = (-width) & 3;
        if (info.bpp == 1) {
            j = 0;
            while (j < @as(c_int, @intCast(s.*.img_y))) : (j += 1) {
                var bit_offset: c_int = 7;
                var v: c_int = stbi__get8(s);
                i = 0;
                while (i < @as(c_int, @intCast(s.*.img_x))) : (i += 1) {
                    const color: usize = @intCast((v >> @intCast(bit_offset)) & 0x1);
                    out[@intCast(z)] = pal[color][0];
                    z += 1;
                    out[@intCast(z)] = pal[color][1];
                    z += 1;
                    out[@intCast(z)] = pal[color][2];
                    z += 1;
                    if (target == 4) {
                        out[@intCast(z)] = 255;
                        z += 1;
                    }
                    if (i + 1 == @as(c_int, @intCast(s.*.img_x))) break;
                    bit_offset -= 1;
                    if (bit_offset < 0) {
                        bit_offset = 7;
                        v = stbi__get8(s);
                    }
                }
                stbi__skip(s, pad);
            }
        } else {
            j = 0;
            while (j < @as(c_int, @intCast(s.*.img_y))) : (j += 1) {
                i = 0;
                while (i < @as(c_int, @intCast(s.*.img_x))) : (i += 2) {
                    var v: c_int = stbi__get8(s);
                    var v2: c_int = 0;
                    if (info.bpp == 4) {
                        v2 = v & 15;
                        v >>= 4;
                    }
                    out[@intCast(z)] = pal[@intCast(v)][0];
                    z += 1;
                    out[@intCast(z)] = pal[@intCast(v)][1];
                    z += 1;
                    out[@intCast(z)] = pal[@intCast(v)][2];
                    z += 1;
                    if (target == 4) {
                        out[@intCast(z)] = 255;
                        z += 1;
                    }
                    if (i + 1 == @as(c_int, @intCast(s.*.img_x))) break;
                    v = if (info.bpp == 8) stbi__get8(s) else v2;
                    out[@intCast(z)] = pal[@intCast(v)][0];
                    z += 1;
                    out[@intCast(z)] = pal[@intCast(v)][1];
                    z += 1;
                    out[@intCast(z)] = pal[@intCast(v)][2];
                    z += 1;
                    if (target == 4) {
                        out[@intCast(z)] = 255;
                        z += 1;
                    }
                }
                stbi__skip(s, pad);
            }
        }
    } else {
        var rshift: c_int = 0;
        var gshift: c_int = 0;
        var bshift: c_int = 0;
        var ashift: c_int = 0;
        var rcount: c_int = 0;
        var gcount: c_int = 0;
        var bcount: c_int = 0;
        var acount: c_int = 0;
        var z: c_int = 0;
        var easy: c_int = 0;
        stbi__skip(s, info.offset - info.extra_read - info.hsz);
        if (info.bpp == 24) {
            width = 3 * @as(c_int, @intCast(s.*.img_x));
        } else if (info.bpp == 16) {
            width = 2 * @as(c_int, @intCast(s.*.img_x));
        } else { // bpp = 32 and pad = 0
            width = 0;
        }
        pad = (-width) & 3;
        if (info.bpp == 24) {
            easy = 1;
        } else if (info.bpp == 32) {
            if (mb == 0xff and mg == 0xff00 and mr == 0x00ff0000 and ma == 0xff000000)
                easy = 2;
        }
        if (easy == 0) {
            if (mr == 0 or mg == 0 or mb == 0) {
                base.rvn_free(out);
                return null; // bad masks, Corrupt BMP
            }
            // right shift amt to put high bit in position #7
            rshift = stbi__high_bit(mr) - 7;
            rcount = stbi__bitcount(mr);
            gshift = stbi__high_bit(mg) - 7;
            gcount = stbi__bitcount(mg);
            bshift = stbi__high_bit(mb) - 7;
            bcount = stbi__bitcount(mb);
            ashift = stbi__high_bit(ma) - 7;
            acount = stbi__bitcount(ma);
            if (rcount > 8 or gcount > 8 or bcount > 8 or acount > 8) {
                base.rvn_free(out);
                return null; // bad masks, Corrupt BMP
            }
        }
        j = 0;
        while (j < @as(c_int, @intCast(s.*.img_y))) : (j += 1) {
            if (easy != 0) {
                i = 0;
                while (i < @as(c_int, @intCast(s.*.img_x))) : (i += 1) {
                    var a: stbi_uc = undefined;
                    out[@intCast(z + 2)] = stbi__get8(s);
                    out[@intCast(z + 1)] = stbi__get8(s);
                    out[@intCast(z + 0)] = stbi__get8(s);
                    z += 3;
                    a = if (easy == 2) stbi__get8(s) else 255;
                    all_a |= @as(c_uint, a);
                    if (target == 4) {
                        out[@intCast(z)] = a;
                        z += 1;
                    }
                }
            } else {
                const bpp: c_int = info.bpp;
                i = 0;
                while (i < @as(c_int, @intCast(s.*.img_x))) : (i += 1) {
                    const v: stbi__uint32 = if (bpp == 16) @as(stbi__uint32, @intCast(stbi__get16le(s))) else stbi__get32le(s);
                    var a: c_uint = undefined;
                    out[@intCast(z)] = STBI__BYTECAST(stbi__shiftsigned(v & mr, rshift, rcount));
                    z += 1;
                    out[@intCast(z)] = STBI__BYTECAST(stbi__shiftsigned(v & mg, gshift, gcount));
                    z += 1;
                    out[@intCast(z)] = STBI__BYTECAST(stbi__shiftsigned(v & mb, bshift, bcount));
                    z += 1;
                    a = if (ma != 0) @as(c_uint, @bitCast(stbi__shiftsigned(v & ma, ashift, acount))) else 255;
                    all_a |= a;
                    if (target == 4) {
                        out[@intCast(z)] = STBI__BYTECAST(@bitCast(a));
                        z += 1;
                    }
                }
            }
            stbi__skip(s, pad);
        }
    }

    // if alpha channel is all 0s, replace with all 255s
    if (target == 4 and all_a == 0) {
        i = 4 * @as(c_int, @intCast(s.*.img_x)) * @as(c_int, @intCast(s.*.img_y)) - 1;
        while (i >= 0) : (i -= 4)
            out[@intCast(i)] = 255;
    }

    if (flip_vertically != 0) {
        var t: stbi_uc = undefined;
        j = 0;
        while (j < (@as(c_int, @intCast(s.*.img_y)) >> 1)) : (j += 1) {
            const p1: [*c]stbi_uc = out + @as(usize, @intCast(j)) * @as(usize, @intCast(s.*.img_x)) * @as(usize, @intCast(target));
            const p2: [*c]stbi_uc = out + @as(usize, @intCast(@as(c_int, @intCast(s.*.img_y)) - 1 - j)) * @as(usize, @intCast(s.*.img_x)) * @as(usize, @intCast(target));
            i = 0;
            while (i < @as(c_int, @intCast(s.*.img_x)) * target) : (i += 1) {
                const iu: usize = @intCast(i);
                t = p1[iu];
                p1[iu] = p2[iu];
                p2[iu] = t;
            }
        }
    }

    if (req_comp != 0 and req_comp != target) {
        out = stbi__convert_format(out, target, req_comp, s.*.img_x, s.*.img_y);
        if (out == null) return null; // stbi__convert_format frees input on failure
    }

    x.* = @bitCast(s.*.img_x);
    y.* = @bitCast(s.*.img_y);
    if (comp != null) comp.* = s.*.img_n;
    return out;
}


// ---- TGA ----

fn stbi__tga_get_comp(bits_per_pixel: c_int, is_grey: c_int, is_rgb16: [*c]c_int) c_int {
    // only RGB or RGBA (incl. 16bit) or grey allowed
    if (is_rgb16 != null) is_rgb16.* = 0;
    switch (bits_per_pixel) {
        8 => return STBI_grey,
        16 => {
            if (is_grey != 0) return STBI_grey_alpha;
            // fallthrough
            if (is_rgb16 != null) is_rgb16.* = 1;
            return STBI_rgb;
        },
        15 => {
            if (is_rgb16 != null) is_rgb16.* = 1;
            return STBI_rgb;
        },
        24, 32 => return @divTrunc(bits_per_pixel, 8), // 24: fallthrough to 32
        else => return 0,
    }
}

fn stbi__tga_info(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    var tga_w: c_int = undefined;
    var tga_h: c_int = undefined;
    var tga_comp: c_int = undefined;
    var tga_image_type: c_int = undefined;
    var tga_bits_per_pixel: c_int = undefined;
    var tga_colormap_bpp: c_int = undefined;
    var sz: c_int = undefined;
    var tga_colormap_type: c_int = undefined;
    _ = stbi__get8(s); // discard Offset
    tga_colormap_type = stbi__get8(s); // colormap type
    if (tga_colormap_type > 1) {
        stbi__rewind(s);
        return 0; // only RGB or indexed allowed
    }
    tga_image_type = stbi__get8(s); // image type
    if (tga_colormap_type == 1) { // colormapped (paletted) image
        if (tga_image_type != 1 and tga_image_type != 9) {
            stbi__rewind(s);
            return 0;
        }
        stbi__skip(s, 4); // skip index of first colormap entry and number of entries
        sz = stbi__get8(s); //   check bits per palette color entry
        if ((sz != 8) and (sz != 15) and (sz != 16) and (sz != 24) and (sz != 32)) {
            stbi__rewind(s);
            return 0;
        }
        stbi__skip(s, 4); // skip image x and y origin
        tga_colormap_bpp = sz;
    } else { // "normal" image w/o colormap - only RGB or grey allowed, +/- RLE
        if ((tga_image_type != 2) and (tga_image_type != 3) and (tga_image_type != 10) and (tga_image_type != 11)) {
            stbi__rewind(s);
            return 0; // only RGB or grey allowed, +/- RLE
        }
        stbi__skip(s, 9); // skip colormap specification and image x/y origin
        tga_colormap_bpp = 0;
    }
    tga_w = stbi__get16le(s);
    if (tga_w < 1) {
        stbi__rewind(s);
        return 0; // test width
    }
    tga_h = stbi__get16le(s);
    if (tga_h < 1) {
        stbi__rewind(s);
        return 0; // test height
    }
    tga_bits_per_pixel = stbi__get8(s); // bits per pixel
    _ = stbi__get8(s); // ignore alpha bits
    if (tga_colormap_bpp != 0) {
        if ((tga_bits_per_pixel != 8) and (tga_bits_per_pixel != 16)) {
            // when using a colormap, tga_bits_per_pixel is the size of the indexes
            // I don't think anything but 8 or 16bit indexes makes sense
            stbi__rewind(s);
            return 0;
        }
        tga_comp = stbi__tga_get_comp(tga_colormap_bpp, 0, null);
    } else {
        tga_comp = stbi__tga_get_comp(tga_bits_per_pixel, @intFromBool((tga_image_type == 3) or (tga_image_type == 11)), null);
    }
    if (tga_comp == 0) {
        stbi__rewind(s);
        return 0;
    }
    if (x != null) x.* = tga_w;
    if (y != null) y.* = tga_h;
    if (comp != null) comp.* = tga_comp;
    return 1; // seems to have passed everything
}

// the body of stbi__tga_test: every `goto errorEnd` is a `return 0` here
fn stbi__tga_test_core(s: [*c]stbi__context) c_int {
    var sz: c_int = undefined;
    var tga_color_type: c_int = undefined;
    _ = stbi__get8(s); //   discard Offset
    tga_color_type = stbi__get8(s); //   color type
    if (tga_color_type > 1) return 0; //   only RGB or indexed allowed
    sz = stbi__get8(s); //   image type
    if (tga_color_type == 1) { // colormapped (paletted) image
        if (sz != 1 and sz != 9) return 0; // colortype 1 demands image type 1 or 9
        stbi__skip(s, 4); // skip index of first colormap entry and number of entries
        sz = stbi__get8(s); //   check bits per palette color entry
        if ((sz != 8) and (sz != 15) and (sz != 16) and (sz != 24) and (sz != 32)) return 0;
        stbi__skip(s, 4); // skip image x and y origin
    } else { // "normal" image w/o colormap
        if ((sz != 2) and (sz != 3) and (sz != 10) and (sz != 11)) return 0; // only RGB or grey allowed, +/- RLE
        stbi__skip(s, 9); // skip colormap specification and image x/y origin
    }
    if (stbi__get16le(s) < 1) return 0; //   test width
    if (stbi__get16le(s) < 1) return 0; //   test height
    sz = stbi__get8(s); //   bits per pixel
    if ((tga_color_type == 1) and (sz != 8) and (sz != 16)) return 0; // for colormapped images, bpp is size of an index
    if ((sz != 8) and (sz != 15) and (sz != 16) and (sz != 24) and (sz != 32)) return 0;

    return 1; // if we got this far, everything's good and we can return 1 instead of 0
}

fn stbi__tga_test(s: [*c]stbi__context) c_int {
    const res: c_int = stbi__tga_test_core(s);
    stbi__rewind(s); // errorEnd:
    return res;
}

// read 16bit value and convert to 24bit RGB
fn stbi__tga_read_rgb16(s: [*c]stbi__context, out: [*c]stbi_uc) void {
    const px: stbi__uint16 = @truncate(@as(c_uint, @bitCast(stbi__get16le(s))));
    const fiveBitMask: stbi__uint16 = 31;
    // we have 3 channels with 5bits each
    const r: c_int = @as(c_int, (px >> 10) & fiveBitMask);
    const g: c_int = @as(c_int, (px >> 5) & fiveBitMask);
    const b: c_int = @as(c_int, px & fiveBitMask);
    // Note that this saves the data in RGB(A) order, so it doesn't need to be swapped later
    out[0] = @intCast(@divTrunc(r * 255, 31));
    out[1] = @intCast(@divTrunc(g * 255, 31));
    out[2] = @intCast(@divTrunc(b * 255, 31));

    // some people claim that the most significant bit might be used for alpha
    // (possibly if an alpha-bit is set in the "image descriptor byte")
    // but that only made 16bit test images completely translucent..
    // so let's treat all 15 and 16bit TGAs as RGB with no alpha.
}

fn stbi__tga_load(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info) ?*anyopaque {
    //   read in the TGA header stuff
    const tga_offset: c_int = stbi__get8(s);
    const tga_indexed: c_int = stbi__get8(s);
    var tga_image_type: c_int = stbi__get8(s);
    var tga_is_RLE: c_int = 0;
    const tga_palette_start: c_int = stbi__get16le(s);
    const tga_palette_len: c_int = stbi__get16le(s);
    const tga_palette_bits: c_int = stbi__get8(s);
    const tga_x_origin: c_int = stbi__get16le(s);
    const tga_y_origin: c_int = stbi__get16le(s);
    const tga_width: c_int = stbi__get16le(s);
    const tga_height: c_int = stbi__get16le(s);
    const tga_bits_per_pixel: c_int = stbi__get8(s);
    var tga_comp: c_int = undefined;
    var tga_rgb16: c_int = 0;
    var tga_inverted: c_int = stbi__get8(s);
    // int tga_alpha_bits = tga_inverted & 15; // the 4 lowest bits - unused (useless?)
    //   image data
    var tga_data: [*c]u8 = undefined;
    var tga_palette: [*c]u8 = null;
    var i: c_int = undefined;
    var j: c_int = undefined;
    var raw_data: [4]u8 = .{ 0, 0, 0, 0 };
    var RLE_count: c_int = 0;
    var RLE_repeating: c_int = 0;
    var read_next_pixel: c_int = 1;
    _ = ri; // STBI_NOTUSED(ri)
    _ = tga_x_origin; // STBI_NOTUSED(tga_x_origin); // @TODO
    _ = tga_y_origin; // STBI_NOTUSED(tga_y_origin); // @TODO

    if (tga_height > STBI_MAX_DIMENSIONS) return null; // too large
    if (tga_width > STBI_MAX_DIMENSIONS) return null; // too large

    //   do a tiny bit of precessing
    if (tga_image_type >= 8) {
        tga_image_type -= 8;
        tga_is_RLE = 1;
    }
    tga_inverted = 1 - ((tga_inverted >> 5) & 1);

    //   If I'm paletted, then I'll use the number of bits from the palette
    if (tga_indexed != 0) {
        tga_comp = stbi__tga_get_comp(tga_palette_bits, 0, &tga_rgb16);
    } else {
        tga_comp = stbi__tga_get_comp(tga_bits_per_pixel, @intFromBool(tga_image_type == 3), &tga_rgb16);
    }

    if (tga_comp == 0) return null; // bad format, shouldn't really happen, stbi__tga_test() should have ensured basic consistency

    //   tga info
    x.* = tga_width;
    y.* = tga_height;
    if (comp != null) comp.* = tga_comp;

    if (stbi__mad3sizes_valid(tga_width, tga_height, tga_comp, 0) == 0) return null; // too large, Corrupt TGA

    tga_data = @ptrCast(@alignCast(stbi__malloc_mad3(tga_width, tga_height, tga_comp, 0)));
    if (tga_data == null) return null; // outofmem

    // skip to the data's starting position (offset usually = 0)
    stbi__skip(s, tga_offset);

    if (tga_indexed == 0 and tga_is_RLE == 0 and tga_rgb16 == 0) {
        i = 0;
        while (i < tga_height) : (i += 1) {
            const row: c_int = if (tga_inverted != 0) tga_height - i - 1 else i;
            const tga_row: [*c]stbi_uc = tga_data + @as(usize, @intCast(row * tga_width * tga_comp));
            _ = stbi__getn(s, tga_row, tga_width * tga_comp);
        }
    } else {
        //   do I need to load a palette?
        if (tga_indexed != 0) {
            if (tga_palette_len == 0) { // you have to have at least one entry!
                base.rvn_free(tga_data);
                return null; // bad palette, Corrupt TGA
            }

            //   any data to skip? (offset usually = 0)
            stbi__skip(s, tga_palette_start);
            //   load the palette
            tga_palette = @ptrCast(@alignCast(stbi__malloc_mad2(tga_palette_len, tga_comp, 0)));
            if (tga_palette == null) {
                base.rvn_free(tga_data);
                return null; // outofmem
            }
            if (tga_rgb16 != 0) {
                var pal_entry: [*c]stbi_uc = tga_palette;
                // STBI_ASSERT(tga_comp == STBI_rgb);
                i = 0;
                while (i < tga_palette_len) : (i += 1) {
                    stbi__tga_read_rgb16(s, pal_entry);
                    pal_entry += @as(usize, @intCast(tga_comp));
                }
            } else if (stbi__getn(s, tga_palette, tga_palette_len * tga_comp) == 0) {
                base.rvn_free(tga_data);
                base.rvn_free(tga_palette);
                return null; // bad palette, Corrupt TGA
            }
        }
        //   load the data
        i = 0;
        while (i < tga_width * tga_height) : (i += 1) {
            //   if I'm in RLE mode, do I need to get a RLE stbi__pngchunk?
            if (tga_is_RLE != 0) {
                if (RLE_count == 0) {
                    //   yep, get the next byte as a RLE command
                    const RLE_cmd: c_int = stbi__get8(s);
                    RLE_count = 1 + (RLE_cmd & 127);
                    RLE_repeating = RLE_cmd >> 7;
                    read_next_pixel = 1;
                } else if (RLE_repeating == 0) {
                    read_next_pixel = 1;
                }
            } else {
                read_next_pixel = 1;
            }
            //   OK, if I need to read a pixel, do it now
            if (read_next_pixel != 0) {
                //   load however much data we did have
                if (tga_indexed != 0) {
                    // read in index, then perform the lookup
                    var pal_idx: c_int = if (tga_bits_per_pixel == 8) stbi__get8(s) else stbi__get16le(s);
                    if (pal_idx >= tga_palette_len) {
                        // invalid index
                        pal_idx = 0;
                    }
                    pal_idx *= tga_comp;
                    j = 0;
                    while (j < tga_comp) : (j += 1) {
                        raw_data[@intCast(j)] = tga_palette[@intCast(pal_idx + j)];
                    }
                } else if (tga_rgb16 != 0) {
                    // STBI_ASSERT(tga_comp == STBI_rgb);
                    stbi__tga_read_rgb16(s, &raw_data);
                } else {
                    //   read in the data raw
                    j = 0;
                    while (j < tga_comp) : (j += 1) {
                        raw_data[@intCast(j)] = stbi__get8(s);
                    }
                }
                //   clear the reading flag for the next pixel
                read_next_pixel = 0;
            } // end of reading a pixel

            // copy data
            j = 0;
            while (j < tga_comp) : (j += 1) {
                tga_data[@intCast(i * tga_comp + j)] = raw_data[@intCast(j)];
            }

            //   in case we're in RLE mode, keep counting down
            RLE_count -= 1;
        }
        //   do I need to invert the image?
        if (tga_inverted != 0) {
            j = 0;
            while (j * 2 < tga_height) : (j += 1) {
                var index1: c_int = j * tga_width * tga_comp;
                var index2: c_int = (tga_height - 1 - j) * tga_width * tga_comp;
                i = tga_width * tga_comp;
                while (i > 0) : (i -= 1) {
                    const temp: u8 = tga_data[@intCast(index1)];
                    tga_data[@intCast(index1)] = tga_data[@intCast(index2)];
                    tga_data[@intCast(index2)] = temp;
                    index1 += 1;
                    index2 += 1;
                }
            }
        }
        //   clear my palette, if I had one
        if (tga_palette != null) {
            base.rvn_free(tga_palette);
        }
    }

    // swap RGB - if the source data was RGB16, it already is in the right order
    if (tga_comp >= 3 and tga_rgb16 == 0) {
        var tga_pixel: [*c]u8 = tga_data;
        i = 0;
        while (i < tga_width * tga_height) : (i += 1) {
            const temp: u8 = tga_pixel[0];
            tga_pixel[0] = tga_pixel[2];
            tga_pixel[2] = temp;
            tga_pixel += @as(usize, @intCast(tga_comp));
        }
    }

    // convert to target component count
    if (req_comp != 0 and req_comp != tga_comp)
        tga_data = stbi__convert_format(tga_data, tga_comp, req_comp, @intCast(tga_width), @intCast(tga_height));

    //   the things I do to get rid of an error message, and yet keep
    //   Microsoft's C compilers happy... [8^(
    //   OK, done
    return tga_data;
}

// ---- info queries (stbi_info / stbi_is_16_bit for the translated formats) ----

fn stbi__bmp_info(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    var info: stbi__bmp_data = undefined;
    info.all_a = 255;
    if (stbi__bmp_parse_header(s, &info) == 0) {
        stbi__rewind(s);
        return 0;
    }
    if (x != null) x.* = @bitCast(s.*.img_x);
    if (y != null) y.* = @bitCast(s.*.img_y);
    if (comp != null) {
        if (info.bpp == 24 and info.ma == 0xff000000) {
            comp.* = 3;
        } else {
            comp.* = if (info.ma != 0) 4 else 3;
        }
    }
    return 1;
}

// ---- GIF loader (public domain by Jean-Marc Lienher, simplified/shrunk by stb) ----

pub const stbi__gif_lzw = extern struct {
    prefix: stbi__int16,
    first: stbi_uc,
    suffix: stbi_uc,
};

pub const stbi__gif = extern struct {
    w: c_int,
    h: c_int,
    out: [*c]stbi_uc, // output buffer (always 4 components)
    background: [*c]stbi_uc, // The current "background" as far as a gif is concerned
    history: [*c]stbi_uc,
    flags: c_int,
    bgindex: c_int,
    ratio: c_int,
    transparent: c_int,
    eflags: c_int,
    pal: [256][4]stbi_uc,
    lpal: [256][4]stbi_uc,
    codes: [8192]stbi__gif_lzw,
    color_table: [*c]stbi_uc,
    parse: c_int,
    step: c_int,
    lflags: c_int,
    start_x: c_int,
    start_y: c_int,
    max_x: c_int,
    max_y: c_int,
    cur_x: c_int,
    cur_y: c_int,
    line_size: c_int,
    delay: c_int,
};

fn stbi__gif_test_raw(s: [*c]stbi__context) c_int {
    if (stbi__get8(s) != 'G' or stbi__get8(s) != 'I' or stbi__get8(s) != 'F' or stbi__get8(s) != '8') return 0;
    const sz: c_int = stbi__get8(s);
    if (sz != '9' and sz != '7') return 0;
    if (stbi__get8(s) != 'a') return 0;
    return 1;
}

fn stbi__gif_test(s: [*c]stbi__context) c_int {
    const r: c_int = stbi__gif_test_raw(s);
    stbi__rewind(s);
    return r;
}

fn stbi__gif_parse_colortable(s: [*c]stbi__context, pal: *[256][4]stbi_uc, num_entries: c_int, transp: c_int) void {
    var i: c_int = 0;
    while (i < num_entries) : (i += 1) {
        const idx: usize = @intCast(i);
        pal[idx][2] = stbi__get8(s);
        pal[idx][1] = stbi__get8(s);
        pal[idx][0] = stbi__get8(s);
        pal[idx][3] = if (transp == i) 0 else 255;
    }
}

fn stbi__gif_header(s: [*c]stbi__context, g: [*c]stbi__gif, comp: [*c]c_int, is_info: c_int) c_int {
    if (stbi__get8(s) != 'G' or stbi__get8(s) != 'I' or stbi__get8(s) != 'F' or stbi__get8(s) != '8')
        return stbi__err("not GIF", "Corrupt GIF");

    const version: stbi_uc = stbi__get8(s);
    if (version != '7' and version != '9') return stbi__err("not GIF", "Corrupt GIF");
    if (stbi__get8(s) != 'a') return stbi__err("not GIF", "Corrupt GIF");

    stbi__g_failure_reason = "";
    g.*.w = stbi__get16le(s);
    g.*.h = stbi__get16le(s);
    g.*.flags = stbi__get8(s);
    g.*.bgindex = stbi__get8(s);
    g.*.ratio = stbi__get8(s);
    g.*.transparent = -1;

    if (g.*.w > STBI_MAX_DIMENSIONS) return stbi__err("too large", "Very large image (corrupt?)");
    if (g.*.h > STBI_MAX_DIMENSIONS) return stbi__err("too large", "Very large image (corrupt?)");

    if (comp != null) comp.* = 4; // can't actually tell whether it's 3 or 4 until we parse the comments

    if (is_info != 0) return 1;

    if ((g.*.flags & 0x80) != 0)
        stbi__gif_parse_colortable(s, &g.*.pal, @as(c_int, 2) << @as(u5, @intCast(g.*.flags & 7)), -1);

    return 1;
}

fn stbi__gif_info_raw(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    const g: [*c]stbi__gif = @ptrCast(@alignCast(stbi__malloc(@sizeOf(stbi__gif))));
    if (g == null) return stbi__err("outofmem", "Out of memory");
    if (stbi__gif_header(s, g, comp, 1) == 0) {
        base.rvn_free(g);
        stbi__rewind(s);
        return 0;
    }
    if (x != null) x.* = g.*.w;
    if (y != null) y.* = g.*.h;
    base.rvn_free(g);
    return 1;
}

fn stbi__out_gif_code(g: [*c]stbi__gif, code: stbi__uint16) void {
    // recurse to decode the prefixes, since the linked-list is backwards,
    // and working backwards through an interleaved image would be nasty
    if (g.*.codes[code].prefix >= 0) stbi__out_gif_code(g, @intCast(g.*.codes[code].prefix));

    if (g.*.cur_y >= g.*.max_y) return;

    const idx: c_int = g.*.cur_x + g.*.cur_y;
    const p: [*c]stbi_uc = g.*.out + @as(usize, @intCast(idx));
    g.*.history[@intCast(@divTrunc(idx, 4))] = 1;

    const c: [*c]stbi_uc = g.*.color_table + @as(usize, g.*.codes[code].suffix) * 4;
    if (c[3] > 128) { // don't render transparent pixels;
        p[0] = c[2];
        p[1] = c[1];
        p[2] = c[0];
        p[3] = c[3];
    }
    g.*.cur_x += 4;

    if (g.*.cur_x >= g.*.max_x) {
        g.*.cur_x = g.*.start_x;
        g.*.cur_y += g.*.step;

        while (g.*.cur_y >= g.*.max_y and g.*.parse > 0) {
            g.*.step = (@as(c_int, 1) << @as(u5, @intCast(g.*.parse))) * g.*.line_size;
            g.*.cur_y = g.*.start_y + (g.*.step >> 1);
            g.*.parse -= 1;
        }
    }
}

fn stbi__process_gif_raster(s: [*c]stbi__context, g: [*c]stbi__gif) [*c]stbi_uc {
    const lzw_cs: stbi_uc = stbi__get8(s);
    if (lzw_cs > 12) return null;
    const clear: stbi__int32 = @as(stbi__int32, 1) << @as(u5, @intCast(lzw_cs));
    var first: stbi__uint32 = 1;
    var codesize: stbi__int32 = @as(stbi__int32, lzw_cs) + 1;
    var codemask: stbi__int32 = (@as(stbi__int32, 1) << @as(u5, @intCast(codesize))) - 1;
    var bits: stbi__int32 = 0;
    var valid_bits: stbi__int32 = 0;
    var init_code: stbi__int32 = 0;
    while (init_code < clear) : (init_code += 1) {
        const ic: usize = @intCast(init_code);
        g.*.codes[ic].prefix = -1;
        g.*.codes[ic].first = @truncate(@as(u32, @bitCast(init_code))); // (stbi_uc) init_code
        g.*.codes[ic].suffix = @truncate(@as(u32, @bitCast(init_code)));
    }

    // support no starting clear code
    var avail: stbi__int32 = clear + 2;
    var oldcode: stbi__int32 = -1;

    var len: stbi__int32 = 0;
    while (true) {
        if (valid_bits < codesize) {
            if (len == 0) {
                len = stbi__get8(s); // start new block
                if (len == 0) return g.*.out;
            }
            len -= 1;
            bits |= @as(stbi__int32, stbi__get8(s)) << @as(u5, @intCast(valid_bits));
            valid_bits += 8;
        } else {
            const code: stbi__int32 = bits & codemask;
            bits >>= @as(u5, @intCast(codesize));
            valid_bits -= codesize;
            // @OPTIMIZE: is there some way we can accelerate the non-clear path?
            if (code == clear) { // clear code
                codesize = @as(stbi__int32, lzw_cs) + 1;
                codemask = (@as(stbi__int32, 1) << @as(u5, @intCast(codesize))) - 1;
                avail = clear + 2;
                oldcode = -1;
                first = 0;
            } else if (code == clear + 1) { // end of stream code
                stbi__skip(s, len);
                len = stbi__get8(s);
                while (len > 0) {
                    stbi__skip(s, len);
                    len = stbi__get8(s);
                }
                return g.*.out;
            } else if (code <= avail) {
                if (first != 0) return stbi__errpuc("no clear code", "Corrupt GIF");

                if (oldcode >= 0) {
                    // C: p = &g->codes[avail++]; if (avail > 8192) error. The slot is only
                    // indexed when it is inside the table (the C code indexes it first).
                    const slot: usize = @intCast(avail);
                    avail += 1;
                    if (avail > 8192) return stbi__errpuc("too many codes", "Corrupt GIF");
                    const p: *stbi__gif_lzw = &g.*.codes[slot];

                    p.prefix = @intCast(oldcode); // (stbi__int16) oldcode
                    p.first = g.*.codes[@intCast(oldcode)].first;
                    p.suffix = if (code == avail) p.first else g.*.codes[@intCast(code)].first;
                } else if (code == avail) {
                    return stbi__errpuc("illegal code in raster", "Corrupt GIF");
                }

                stbi__out_gif_code(g, @intCast(code)); // (stbi__uint16) code

                if ((avail & codemask) == 0 and avail <= 0x0FFF) {
                    codesize += 1;
                    codemask = (@as(stbi__int32, 1) << @as(u5, @intCast(codesize))) - 1;
                }

                oldcode = code;
            } else {
                return stbi__errpuc("illegal code in raster", "Corrupt GIF");
            }
        }
    }
}

// this function is designed to support animated gifs, although stb_image doesn't support it
// two back is the image from two frames ago, used for a very specific disposal format
fn stbi__gif_load_next(s: [*c]stbi__context, g: [*c]stbi__gif, comp: [*c]c_int, req_comp: c_int, two_back: [*c]stbi_uc) [*c]stbi_uc {
    _ = req_comp; // STBI_NOTUSED(req_comp)
    var pcount: c_int = 0;

    // on first frame, any non-written pixels get the background colour (non-transparent)
    var first_frame: c_int = 0;
    if (g.*.out == null) {
        if (stbi__gif_header(s, g, comp, 0) == 0) return null; // stbi__g_failure_reason set by stbi__gif_header
        if (stbi__mad3sizes_valid(4, g.*.w, g.*.h, 0) == 0)
            return stbi__errpuc("too large", "GIF image is too large");
        pcount = g.*.w * g.*.h;
        g.*.out = @ptrCast(@alignCast(stbi__malloc(@as(usize, @intCast(4 * pcount)))));
        g.*.background = @ptrCast(@alignCast(stbi__malloc(@as(usize, @intCast(4 * pcount)))));
        g.*.history = @ptrCast(@alignCast(stbi__malloc(@as(usize, @intCast(pcount)))));
        if (g.*.out == null or g.*.background == null or g.*.history == null)
            return stbi__errpuc("outofmem", "Out of memory");

        // image is treated as "transparent" at the start - ie, nothing overwrites the current background;
        // background colour is only used for pixels that are not rendered first frame, after that "background"
        // color refers to the color that was there the previous frame.
        @memset(g.*.out[0..@as(usize, @intCast(4 * pcount))], 0x00);
        @memset(g.*.background[0..@as(usize, @intCast(4 * pcount))], 0x00); // state of the background (starts transparent)
        @memset(g.*.history[0..@as(usize, @intCast(pcount))], 0x00); // pixels that were affected previous frame
        first_frame = 1;
    } else {
        // second frame - how do we dispose of the previous one?
        var dispose: c_int = (g.*.eflags & 0x1C) >> 2;
        pcount = g.*.w * g.*.h;

        if (dispose == 3 and two_back == null) {
            dispose = 2; // if I don't have an image to revert back to, default to the old background
        }

        if (dispose == 3) { // use previous graphic
            var pi: c_int = 0;
            while (pi < pcount) : (pi += 1) {
                const upi: usize = @intCast(pi);
                if (g.*.history[upi] != 0) {
                    const dst: [*c]stbi_uc = g.*.out + upi * 4;
                    const src: [*c]stbi_uc = two_back + upi * 4;
                    @memcpy(dst[0..4], src[0..4]);
                }
            }
        } else if (dispose == 2) {
            // restore what was changed last frame to background before that frame;
            var pi: c_int = 0;
            while (pi < pcount) : (pi += 1) {
                const upi: usize = @intCast(pi);
                if (g.*.history[upi] != 0) {
                    const dst: [*c]stbi_uc = g.*.out + upi * 4;
                    const src: [*c]stbi_uc = g.*.background + upi * 4;
                    @memcpy(dst[0..4], src[0..4]);
                }
            }
        }
        // else: This is a non-disposal case eithe way, so just leave the pixels as is,
        // and they will become the new background (1: do not dispose, 0: not specified).

        // background is what out is after the undoing of the previou frame;
        const n: usize = @intCast(4 * g.*.w * g.*.h);
        @memcpy(g.*.background[0..n], g.*.out[0..n]);
    }

    // clear my history;
    @memset(g.*.history[0..@as(usize, @intCast(g.*.w * g.*.h))], 0x00); // pixels that were affected previous frame

    while (true) {
        const tag: c_int = stbi__get8(s);
        sw: switch (tag) {
            0x2C => { // Image Descriptor
                const x: stbi__int32 = stbi__get16le(s);
                const y: stbi__int32 = stbi__get16le(s);
                const w: stbi__int32 = stbi__get16le(s);
                const h: stbi__int32 = stbi__get16le(s);
                if (((x + w) > g.*.w) or ((y + h) > g.*.h))
                    return stbi__errpuc("bad Image Descriptor", "Corrupt GIF");

                g.*.line_size = g.*.w * 4;
                g.*.start_x = x * 4;
                g.*.start_y = y * g.*.line_size;
                g.*.max_x = g.*.start_x + w * 4;
                g.*.max_y = g.*.start_y + h * g.*.line_size;
                g.*.cur_x = g.*.start_x;
                g.*.cur_y = g.*.start_y;

                // if the width of the specified rectangle is 0, that means
                // we may not see *any* pixels or the image is malformed;
                // to make sure this is caught, move the current y down to
                // max_y (which is what out_gif_code checks).
                if (w == 0) g.*.cur_y = g.*.max_y;

                g.*.lflags = stbi__get8(s);

                if ((g.*.lflags & 0x40) != 0) {
                    g.*.step = 8 * g.*.line_size; // first interlaced spacing
                    g.*.parse = 3;
                } else {
                    g.*.step = g.*.line_size;
                    g.*.parse = 0;
                }

                if ((g.*.lflags & 0x80) != 0) {
                    const transp: c_int = if ((g.*.eflags & 0x01) != 0) g.*.transparent else -1;
                    stbi__gif_parse_colortable(s, &g.*.lpal, @as(c_int, 2) << @as(u5, @intCast(g.*.lflags & 7)), transp);
                    g.*.color_table = @as([*c]stbi_uc, @ptrCast(&g.*.lpal));
                } else if ((g.*.flags & 0x80) != 0) {
                    g.*.color_table = @as([*c]stbi_uc, @ptrCast(&g.*.pal));
                } else {
                    return stbi__errpuc("missing color table", "Corrupt GIF");
                }

                const o: [*c]stbi_uc = stbi__process_gif_raster(s, g);
                if (o == null) return null;

                // if this was the first frame,
                pcount = g.*.w * g.*.h;
                if (first_frame != 0 and g.*.bgindex > 0) {
                    // if first frame, any pixel not drawn to gets the background color
                    const bg: usize = @intCast(g.*.bgindex);
                    var pi: c_int = 0;
                    while (pi < pcount) : (pi += 1) {
                        const upi: usize = @intCast(pi);
                        if (g.*.history[upi] == 0) {
                            g.*.pal[bg][3] = 255; // just in case it was made transparent, undo that; It will be reset next frame if need be;
                            const dst: [*c]stbi_uc = g.*.out + upi * 4;
                            @memcpy(dst[0..4], g.*.pal[bg][0..4]);
                        }
                    }
                }

                return o;
            },
            0x21 => { // Comment Extension.
                var len: c_int = 0;
                const ext: c_int = stbi__get8(s);
                if (ext == 0xF9) { // Graphic Control Extension.
                    len = stbi__get8(s);
                    if (len == 4) {
                        g.*.eflags = stbi__get8(s);
                        g.*.delay = 10 * stbi__get16le(s); // delay - 1/100th of a second, saving as 1/1000ths.

                        // unset old transparent
                        if (g.*.transparent >= 0) {
                            g.*.pal[@intCast(g.*.transparent)][3] = 255;
                        }
                        if ((g.*.eflags & 0x01) != 0) {
                            g.*.transparent = stbi__get8(s);
                            if (g.*.transparent >= 0) {
                                g.*.pal[@intCast(g.*.transparent)][3] = 0;
                            }
                        } else {
                            // don't need transparent
                            stbi__skip(s, 1);
                            g.*.transparent = -1;
                        }
                    } else {
                        stbi__skip(s, len);
                        break :sw;
                    }
                }
                len = stbi__get8(s);
                while (len != 0) {
                    stbi__skip(s, len);
                    len = stbi__get8(s);
                }
            },
            0x3B => { // gif stream termination code
                return @as([*c]stbi_uc, @ptrCast(s)); // using '1' causes warning on some compilers
            },
            else => return stbi__errpuc("unknown code", "Corrupt GIF"),
        }
    }
}

fn stbi__load_gif_main_outofmem(g: [*c]stbi__gif, out: [*c]stbi_uc, delays: [*c][*c]c_int) ?*anyopaque {
    base.rvn_free(g.*.out);
    base.rvn_free(g.*.history);
    base.rvn_free(g.*.background);

    if (out != null) base.rvn_free(out);
    if (delays != null and delays.* != null) base.rvn_free(delays.*);
    return stbi__errpuc("outofmem", "Out of memory");
}

fn stbi__load_gif_main(s: [*c]stbi__context, delays: [*c][*c]c_int, x: [*c]c_int, y: [*c]c_int, z: [*c]c_int, comp: [*c]c_int, req_comp: c_int) ?*anyopaque {
    if (stbi__gif_test(s) != 0) {
        var layers: c_int = 0;
        var u: [*c]stbi_uc = null;
        var out: [*c]stbi_uc = null;
        var two_back: [*c]stbi_uc = null;
        var g: stbi__gif = std.mem.zeroes(stbi__gif);
        var stride: c_int = 0;
        // out_size and delays_size are only passed to STBI_REALLOC_SIZED, which ignores them
        // in this configuration (STBI_REALLOC(p, newsz) = rvn_realloc).

        if (delays != null) {
            delays.* = null;
        }

        while (true) {
            u = stbi__gif_load_next(s, &g, comp, req_comp, two_back);
            if (u == @as([*c]stbi_uc, @ptrCast(s))) u = null; // end of animated gif marker

            if (u != null) {
                x.* = g.w;
                y.* = g.h;
                layers += 1;
                stride = g.w * g.h * 4;
                const layers_n: usize = @intCast(layers);
                const stride_n: usize = @intCast(stride);

                if (out != null) {
                    const tmp: ?*anyopaque = base.rvn_realloc(out, layers_n * stride_n);
                    if (tmp == null) return stbi__load_gif_main_outofmem(&g, out, delays);
                    out = @ptrCast(@alignCast(tmp));

                    if (delays != null) {
                        const new_delays: ?*anyopaque = base.rvn_realloc(delays.*, @sizeOf(c_int) * layers_n);
                        if (new_delays == null) return stbi__load_gif_main_outofmem(&g, out, delays);
                        delays.* = @ptrCast(@alignCast(new_delays));
                    }
                } else {
                    out = @ptrCast(@alignCast(stbi__malloc(layers_n * stride_n)));
                    if (out == null) return stbi__load_gif_main_outofmem(&g, out, delays);
                    if (delays != null) {
                        delays.* = @ptrCast(@alignCast(stbi__malloc(@sizeOf(c_int) * layers_n)));
                        if (delays.* == null) return stbi__load_gif_main_outofmem(&g, out, delays);
                    }
                }
                const dst_off: usize = (layers_n - 1) * stride_n;
                @memcpy((out + dst_off)[0..stride_n], u[0..stride_n]);
                if (layers >= 2) {
                    two_back = out - 2 * stride_n;
                }

                if (delays != null) {
                    delays.*[layers_n - 1] = g.delay;
                }
            }

            if (u == null) break; // } while (u != 0);
        }

        // free temp buffer;
        base.rvn_free(g.out);
        base.rvn_free(g.history);
        base.rvn_free(g.background);

        // do the final conversion after loading everything;
        if (req_comp != 0 and req_comp != 4)
            out = stbi__convert_format(out, 4, req_comp, @bitCast(layers * g.w), @bitCast(g.h));

        z.* = layers;
        return out;
    } else {
        return stbi__errpuc("not GIF", "Image was not as a gif type.");
    }
}

fn stbi__gif_load(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info) ?*anyopaque {
    _ = ri; // STBI_NOTUSED(ri)
    var u: [*c]stbi_uc = null;
    var g: stbi__gif = std.mem.zeroes(stbi__gif);

    u = stbi__gif_load_next(s, &g, comp, req_comp, null);
    if (u == @as([*c]stbi_uc, @ptrCast(s))) u = null; // end of animated gif marker
    if (u != null) {
        x.* = g.w;
        y.* = g.h;

        // moved conversion to after successful load so that the same
        // can be done for multiple frames.
        if (req_comp != 0 and req_comp != 4)
            u = stbi__convert_format(u, 4, req_comp, @bitCast(g.w), @bitCast(g.h));
    } else if (g.out != null) {
        // if there was an error and we allocated an image buffer, free it!
        base.rvn_free(g.out);
    }

    // free buffers needed for multiple frame loading;
    base.rvn_free(g.history);
    base.rvn_free(g.background);

    return u;
}

fn stbi__gif_info(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    return stbi__gif_info_raw(s, x, y, comp);
}

fn stbi__vertical_flip_slices(image: ?*anyopaque, w: c_int, h: c_int, z: c_int, bytes_per_pixel: c_int) void {
    const slice_size: usize = @intCast(w * h * bytes_per_pixel);
    var bytes: [*c]stbi_uc = @ptrCast(@alignCast(image));
    var slice: c_int = 0;
    while (slice < z) : (slice += 1) {
        stbi__vertical_flip(bytes, w, h, bytes_per_pixel);
        bytes += slice_size;
    }
}

/// STBIDEF stbi_uc *stbi_load_gif_from_memory(stbi_uc const *buffer, int len, int **delays, int *x, int *y, int *z, int *comp, int req_comp)
fn stbi_load_gif_from_memory(buffer: [*c]const stbi_uc, len: c_int, delays: [*c][*c]c_int, x: [*c]c_int, y: [*c]c_int, z: [*c]c_int, comp: [*c]c_int, req_comp: c_int) [*c]stbi_uc {
    var s: stbi__context = undefined;
    stbi__start_mem(&s, buffer, len);

    const result: [*c]stbi_uc = @ptrCast(@alignCast(stbi__load_gif_main(&s, delays, x, y, z, comp, req_comp)));
    if (stbi__vertically_flip_on_load() != 0) {
        stbi__vertical_flip_slices(result, x.*, y.*, z.*, comp.*);
    }

    return result;
}

// ---- PSD (Photoshop) loader ----

fn stbi__psd_test(s: [*c]stbi__context) c_int {
    const r: c_int = @intFromBool(stbi__get32be(s) == 0x38425053);
    stbi__rewind(s);
    return r;
}

fn stbi__psd_decode_rle(s: [*c]stbi__context, p_: [*c]stbi_uc, pixelCount: c_int) c_int {
    var p = p_;
    var count: c_int = 0;
    while (pixelCount - count > 0) {
        const nleft: c_int = pixelCount - count;
        var len: c_int = stbi__get8(s);
        if (len == 128) {
            // No-op.
        } else if (len < 128) {
            // Copy next len+1 bytes literally.
            len += 1;
            if (len > nleft) return 0; // corrupt data
            count += len;
            while (len != 0) : (len -= 1) {
                p.* = stbi__get8(s);
                p += 4;
            }
        } else {
            // Next -len+1 bytes in the dest are replicated from next source byte.
            // (Interpret len as a negative 8-bit int.)
            len = 257 - len;
            if (len > nleft) return 0; // corrupt data
            const val: stbi_uc = stbi__get8(s);
            count += len;
            while (len != 0) : (len -= 1) {
                p.* = val;
                p += 4;
            }
        }
    }
    return 1;
}

fn stbi__psd_load(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info, bpc: c_int) ?*anyopaque {
    // Check identifier
    if (stbi__get32be(s) != 0x38425053) // "8BPS"
        return stbi__errpuc("not PSD", "Corrupt PSD image");

    // Check file type version.
    if (stbi__get16be(s) != 1)
        return stbi__errpuc("wrong version", "Unsupported version of PSD image");

    // Skip 6 reserved bytes.
    stbi__skip(s, 6);

    // Read the number of channels (R, G, B, A, etc).
    const channelCount: c_int = stbi__get16be(s);
    if (channelCount < 0 or channelCount > 16)
        return stbi__errpuc("wrong channel count", "Unsupported number of channels in PSD image");

    // Read the rows and columns of the image.
    const h: c_int = @bitCast(stbi__get32be(s));
    const w: c_int = @bitCast(stbi__get32be(s));

    if (h > STBI_MAX_DIMENSIONS) return stbi__errpuc("too large", "Very large image (corrupt?)");
    if (w > STBI_MAX_DIMENSIONS) return stbi__errpuc("too large", "Very large image (corrupt?)");

    // Make sure the depth is 8 bits.
    const bitdepth: c_int = stbi__get16be(s);
    if (bitdepth != 8 and bitdepth != 16)
        return stbi__errpuc("unsupported bit depth", "PSD bit depth is not 8 or 16 bit");

    // Make sure the color mode is RGB.
    // Valid options are:
    //   0: Bitmap
    //   1: Grayscale
    //   2: Indexed color
    //   3: RGB color
    //   4: CMYK color
    //   7: Multichannel
    //   8: Duotone
    //   9: Lab color
    if (stbi__get16be(s) != 3)
        return stbi__errpuc("wrong color format", "PSD is not in RGB color format");

    // Skip the Mode Data.  (It's the palette for indexed color; other info for other modes.)
    stbi__skip(s, @bitCast(stbi__get32be(s)));

    // Skip the image resources.  (resolution, pen tool paths, etc)
    stbi__skip(s, @bitCast(stbi__get32be(s)));

    // Skip the reserved data.
    stbi__skip(s, @bitCast(stbi__get32be(s)));

    // Find out if the data is compressed.
    // Known values:
    //   0: no compression
    //   1: RLE compressed
    const compression: c_int = stbi__get16be(s);
    if (compression > 1)
        return stbi__errpuc("bad compression", "PSD has an unknown compression format");

    // Check size
    if (stbi__mad3sizes_valid(4, w, h, 0) == 0)
        return stbi__errpuc("too large", "Corrupt PSD");

    // Create the destination image.
    var out: [*c]stbi_uc = undefined;
    if (compression == 0 and bitdepth == 16 and bpc == 16) {
        out = @ptrCast(@alignCast(stbi__malloc_mad3(8, w, h, 0)));
        ri.*.bits_per_channel = 16;
    } else {
        out = @ptrCast(@alignCast(stbi__malloc(@intCast(4 * w * h))));
    }

    if (out == null) return stbi__errpuc("outofmem", "Out of memory");
    const pixelCount: c_int = w * h;

    // Finally, the image data.
    if (compression != 0) {
        // RLE as used by .PSD and .TIFF
        // The RLE-compressed data is preceded by a 2-byte data count for each row in the data,
        // which we're going to just skip.
        stbi__skip(s, h * channelCount * 2);

        // Read the RLE data by channel.
        var channel: c_int = 0;
        while (channel < 4) : (channel += 1) {
            const p: [*c]stbi_uc = out + @as(usize, @intCast(channel));
            if (channel >= channelCount) {
                // Fill this channel with default data.
                var i: c_int = 0;
                var q = p;
                while (i < pixelCount) : (i += 1) {
                    q.* = if (channel == 3) 255 else 0;
                    q += 4;
                }
            } else {
                // Read the RLE data.
                if (stbi__psd_decode_rle(s, p, pixelCount) == 0) {
                    base.rvn_free(out);
                    return stbi__errpuc("corrupt", "bad RLE data");
                }
            }
        }
    } else {
        // We're at the raw image data.  It's each channel in order (Red, Green, Blue, Alpha, ...)
        // where each channel consists of an 8-bit (or 16-bit) value for each pixel in the image.

        // Read the data by channel.
        var channel: c_int = 0;
        while (channel < 4) : (channel += 1) {
            if (channel >= channelCount) {
                // Fill this channel with default data.
                if (bitdepth == 16 and bpc == 16) {
                    var q: [*c]stbi__uint16 = @ptrCast(@alignCast(out));
                    q += @as(usize, @intCast(channel));
                    const val: stbi__uint16 = if (channel == 3) 65535 else 0;
                    var i: c_int = 0;
                    while (i < pixelCount) : (i += 1) {
                        q.* = val;
                        q += 4;
                    }
                } else {
                    var p: [*c]stbi_uc = out + @as(usize, @intCast(channel));
                    const val: stbi_uc = if (channel == 3) 255 else 0;
                    var i: c_int = 0;
                    while (i < pixelCount) : (i += 1) {
                        p.* = val;
                        p += 4;
                    }
                }
            } else {
                if (ri.*.bits_per_channel == 16) { // output bpc
                    var q: [*c]stbi__uint16 = @ptrCast(@alignCast(out));
                    q += @as(usize, @intCast(channel));
                    var i: c_int = 0;
                    while (i < pixelCount) : (i += 1) {
                        q.* = @truncate(@as(c_uint, @bitCast(stbi__get16be(s))));
                        q += 4;
                    }
                } else {
                    var p: [*c]stbi_uc = out + @as(usize, @intCast(channel));
                    var i: c_int = 0;
                    if (bitdepth == 16) { // input bpc
                        while (i < pixelCount) : (i += 1) {
                            p.* = @truncate(@as(c_uint, @bitCast(stbi__get16be(s) >> 8)));
                            p += 4;
                        }
                    } else {
                        while (i < pixelCount) : (i += 1) {
                            p.* = stbi__get8(s);
                            p += 4;
                        }
                    }
                }
            }
        }
    }

    // remove weird white matte from PSD
    if (channelCount >= 4) {
        if (ri.*.bits_per_channel == 16) {
            const q16: [*c]stbi__uint16 = @ptrCast(@alignCast(out));
            var i: c_int = 0;
            while (i < w * h) : (i += 1) {
                const pixel: [*c]stbi__uint16 = q16 + @as(usize, @intCast(4 * i));
                if (pixel[3] != 0 and pixel[3] != 65535) {
                    const a: f32 = @as(f32, @floatFromInt(pixel[3])) / 65535.0;
                    const ra: f32 = 1.0 / a;
                    const inv_a: f32 = 65535.0 * (1 - ra);
                    pixel[0] = @truncate(@as(c_uint, @bitCast(stbi__float_to_int32(@as(f32, @floatFromInt(pixel[0])) * ra + inv_a))));
                    pixel[1] = @truncate(@as(c_uint, @bitCast(stbi__float_to_int32(@as(f32, @floatFromInt(pixel[1])) * ra + inv_a))));
                    pixel[2] = @truncate(@as(c_uint, @bitCast(stbi__float_to_int32(@as(f32, @floatFromInt(pixel[2])) * ra + inv_a))));
                }
            }
        } else {
            var i: c_int = 0;
            while (i < w * h) : (i += 1) {
                const pixel: [*c]stbi_uc = out + @as(usize, @intCast(4 * i));
                if (pixel[3] != 0 and pixel[3] != 255) {
                    const a: f32 = @as(f32, @floatFromInt(pixel[3])) / 255.0;
                    const ra: f32 = 1.0 / a;
                    const inv_a: f32 = 255.0 * (1 - ra);
                    pixel[0] = @truncate(@as(c_uint, @bitCast(stbi__float_to_int32(@as(f32, @floatFromInt(pixel[0])) * ra + inv_a))));
                    pixel[1] = @truncate(@as(c_uint, @bitCast(stbi__float_to_int32(@as(f32, @floatFromInt(pixel[1])) * ra + inv_a))));
                    pixel[2] = @truncate(@as(c_uint, @bitCast(stbi__float_to_int32(@as(f32, @floatFromInt(pixel[2])) * ra + inv_a))));
                }
            }
        }
    }

    // convert to desired output format
    if (req_comp != 0 and req_comp != 4) {
        if (ri.*.bits_per_channel == 16) {
            out = @ptrCast(stbi__convert_format16(@ptrCast(@alignCast(out)), 4, req_comp, @bitCast(w), @bitCast(h)));
        } else {
            out = stbi__convert_format(out, 4, req_comp, @bitCast(w), @bitCast(h));
        }
        if (out == null) return null; // stbi__convert_format frees input on failure
    }

    if (comp != null) comp.* = 4;
    y.* = h;
    x.* = w;

    return out;
}

fn stbi__psd_info(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    var dummy_x: c_int = 0;
    var dummy_y: c_int = 0;
    var dummy_comp: c_int = 0;
    const xp: [*c]c_int = if (x != null) x else &dummy_x;
    const yp: [*c]c_int = if (y != null) y else &dummy_y;
    const compp: [*c]c_int = if (comp != null) comp else &dummy_comp;
    if (stbi__get32be(s) != 0x38425053) {
        stbi__rewind(s);
        return 0;
    }
    if (stbi__get16be(s) != 1) {
        stbi__rewind(s);
        return 0;
    }
    stbi__skip(s, 6);
    const channelCount: c_int = stbi__get16be(s);
    if (channelCount < 0 or channelCount > 16) {
        stbi__rewind(s);
        return 0;
    }
    yp.* = @bitCast(stbi__get32be(s));
    xp.* = @bitCast(stbi__get32be(s));
    const depth: c_int = stbi__get16be(s);
    if (depth != 8 and depth != 16) {
        stbi__rewind(s);
        return 0;
    }
    if (stbi__get16be(s) != 3) {
        stbi__rewind(s);
        return 0;
    }
    compp.* = 4;
    return 1;
}

fn stbi__psd_is16(s: [*c]stbi__context) c_int {
    if (stbi__get32be(s) != 0x38425053) {
        stbi__rewind(s);
        return 0;
    }
    if (stbi__get16be(s) != 1) {
        stbi__rewind(s);
        return 0;
    }
    stbi__skip(s, 6);
    const channelCount: c_int = stbi__get16be(s);
    if (channelCount < 0 or channelCount > 16) {
        stbi__rewind(s);
        return 0;
    }
    _ = stbi__get32be(s);
    _ = stbi__get32be(s);
    const depth: c_int = stbi__get16be(s);
    if (depth != 16) {
        stbi__rewind(s);
        return 0;
    }
    return 1;
}

// ---- Softimage PIC loader ----

fn stbi__pic_is4(s: [*c]stbi__context, str: [*c]const u8) c_int {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (stbi__get8(s) != str[i]) return 0;
    }
    return 1;
}

fn stbi__pic_test_core(s: [*c]stbi__context) c_int {
    if (stbi__pic_is4(s, "\x53\x80\xF6\x34") == 0) return 0;

    var i: c_int = 0;
    while (i < 84) : (i += 1) _ = stbi__get8(s);

    if (stbi__pic_is4(s, "PICT") == 0) return 0;

    return 1;
}

const stbi__pic_packet = extern struct {
    size: stbi_uc,
    @"type": stbi_uc,
    channel: stbi_uc,
};

fn stbi__readval(s: [*c]stbi__context, channel: c_int, dest: [*c]stbi_uc) [*c]stbi_uc {
    var mask: c_int = 0x80;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if ((channel & mask) != 0) {
            if (stbi__at_eof(s) != 0) return stbi__errpuc("bad file", "PIC file too short");
            dest[i] = stbi__get8(s);
        }
        mask >>= 1;
    }
    return dest;
}

fn stbi__copyval(channel: c_int, dest: [*c]stbi_uc, src: [*c]const stbi_uc) void {
    var mask: c_int = 0x80;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if ((channel & mask) != 0) dest[i] = src[i];
        mask >>= 1;
    }
}

fn stbi__pic_load_core(s: [*c]stbi__context, width: c_int, height: c_int, comp: [*c]c_int, result: [*c]stbi_uc) [*c]stbi_uc {
    var act_comp: c_int = 0;
    var num_packets: usize = 0;
    var packets: [10]stbi__pic_packet = undefined;

    // this will (should...) cater for even some bizarre stuff like having data
    // for the same channel in multiple packets.
    while (true) {
        if (num_packets == packets.len) return stbi__errpuc("bad format", "too many packets");

        const packet: *stbi__pic_packet = &packets[num_packets];
        num_packets += 1;

        const chained: stbi_uc = stbi__get8(s);
        packet.size = stbi__get8(s);
        packet.@"type" = stbi__get8(s);
        packet.channel = stbi__get8(s);

        act_comp |= @as(c_int, packet.channel);

        if (stbi__at_eof(s) != 0) return stbi__errpuc("bad file", "file too short (reading packets)");
        if (packet.size != 8) return stbi__errpuc("bad format", "packet isn't 8bpp");
        if (chained == 0) break;
    }

    comp.* = if ((act_comp & 0x10) != 0) 4 else 3; // has alpha channel?

    var y: c_int = 0;
    while (y < height) : (y += 1) {
        var packet_idx: usize = 0;
        while (packet_idx < num_packets) : (packet_idx += 1) {
            const packet: *stbi__pic_packet = &packets[packet_idx];
            var dest: [*c]stbi_uc = result + @as(usize, @intCast(y * width * 4));

            switch (packet.@"type") {
                0 => { // uncompressed
                    var x: c_int = 0;
                    while (x < width) : (x += 1) {
                        if (stbi__readval(s, @as(c_int, packet.channel), dest) == null) return null;
                        dest += 4;
                    }
                },
                1 => { // Pure RLE
                    var left: c_int = width;
                    while (left > 0) {
                        var count: stbi_uc = stbi__get8(s);
                        if (stbi__at_eof(s) != 0) return stbi__errpuc("bad file", "file too short (pure read count)");

                        if (@as(c_int, count) > left) count = @intCast(left);

                        var value: [4]stbi_uc = undefined;
                        if (stbi__readval(s, @as(c_int, packet.channel), &value) == null) return null;

                        var i: stbi_uc = 0;
                        while (i < count) : (i += 1) {
                            stbi__copyval(@as(c_int, packet.channel), dest, &value);
                            dest += 4;
                        }
                        left -= @as(c_int, count);
                    }
                },
                2 => { // Mixed RLE
                    var left: c_int = width;
                    while (left > 0) {
                        var count: c_int = stbi__get8(s);
                        if (stbi__at_eof(s) != 0) return stbi__errpuc("bad file", "file too short (mixed read count)");

                        if (count >= 128) { // Repeated
                            var value: [4]stbi_uc = undefined;

                            if (count == 128) {
                                count = stbi__get16be(s);
                            } else {
                                count -= 127;
                            }
                            if (count > left) return stbi__errpuc("bad file", "scanline overrun");

                            if (stbi__readval(s, @as(c_int, packet.channel), &value) == null) return null;

                            var i: c_int = 0;
                            while (i < count) : (i += 1) {
                                stbi__copyval(@as(c_int, packet.channel), dest, &value);
                                dest += 4;
                            }
                        } else { // Raw
                            count += 1;
                            if (count > left) return stbi__errpuc("bad file", "scanline overrun");

                            var i: c_int = 0;
                            while (i < count) : (i += 1) {
                                if (stbi__readval(s, @as(c_int, packet.channel), dest) == null) return null;
                                dest += 4;
                            }
                        }
                        left -= count;
                    }
                },
                else => return stbi__errpuc("bad format", "packet has bad compression type"),
            }
        }
    }

    return result;
}

fn stbi__pic_load(s: [*c]stbi__context, px: [*c]c_int, py: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info) ?*anyopaque {
    _ = ri; // STBI_NOTUSED(ri)
    var internal_comp: c_int = 0;
    const comp_: [*c]c_int = if (comp != null) comp else &internal_comp;
    var req_comp_: c_int = req_comp;

    var i: c_int = 0;
    while (i < 92) : (i += 1) _ = stbi__get8(s);

    const x: c_int = stbi__get16be(s);
    const y: c_int = stbi__get16be(s);

    if (y > STBI_MAX_DIMENSIONS) return stbi__errpuc("too large", "Very large image (corrupt?)");
    if (x > STBI_MAX_DIMENSIONS) return stbi__errpuc("too large", "Very large image (corrupt?)");

    if (stbi__at_eof(s) != 0) return stbi__errpuc("bad file", "file too short (pic header)");
    if (stbi__mad3sizes_valid(x, y, 4, 0) == 0) return stbi__errpuc("too large", "PIC image too large to decode");

    _ = stbi__get32be(s); // skip `ratio'
    _ = stbi__get16be(s); // skip `fields'
    _ = stbi__get16be(s); // skip `pad'

    // intermediate buffer is RGBA
    var result: [*c]stbi_uc = @ptrCast(@alignCast(stbi__malloc_mad3(x, y, 4, 0)));
    if (result == null) return stbi__errpuc("outofmem", "Out of memory");
    @memset(result[0..@as(usize, @intCast(x * y * 4))], 0xff);

    if (stbi__pic_load_core(s, x, y, comp_, result) == null) {
        base.rvn_free(result);
        result = null;
    }
    px.* = x;
    py.* = y;
    if (req_comp_ == 0) req_comp_ = comp_.*;
    result = stbi__convert_format(result, 4, req_comp_, @bitCast(x), @bitCast(y));

    return result;
}

fn stbi__pic_test(s: [*c]stbi__context) c_int {
    const r: c_int = stbi__pic_test_core(s);
    stbi__rewind(s);
    return r;
}

fn stbi__pic_info(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    var act_comp: c_int = 0;
    var num_packets: usize = 0;
    var packets: [10]stbi__pic_packet = undefined;
    var dummy_x: c_int = 0;
    var dummy_y: c_int = 0;
    var dummy_comp: c_int = 0;
    const xp: [*c]c_int = if (x != null) x else &dummy_x;
    const yp: [*c]c_int = if (y != null) y else &dummy_y;
    const compp: [*c]c_int = if (comp != null) comp else &dummy_comp;

    if (stbi__pic_is4(s, "\x53\x80\xF6\x34") == 0) {
        stbi__rewind(s);
        return 0;
    }

    stbi__skip(s, 88);

    xp.* = stbi__get16be(s);
    yp.* = stbi__get16be(s);
    if (stbi__at_eof(s) != 0) {
        stbi__rewind(s);
        return 0;
    }
    if (xp.* != 0 and @divTrunc(@as(c_int, 1 << 28), xp.*) < yp.*) {
        stbi__rewind(s);
        return 0;
    }

    stbi__skip(s, 8);

    while (true) {
        if (num_packets == packets.len) return 0;

        const packet: *stbi__pic_packet = &packets[num_packets];
        num_packets += 1;
        const chained: stbi_uc = stbi__get8(s);
        packet.size = stbi__get8(s);
        packet.@"type" = stbi__get8(s);
        packet.channel = stbi__get8(s);
        act_comp |= @as(c_int, packet.channel);

        if (stbi__at_eof(s) != 0) {
            stbi__rewind(s);
            return 0;
        }
        if (packet.size != 8) {
            stbi__rewind(s);
            return 0;
        }
        if (chained == 0) break;
    }

    compp.* = if ((act_comp & 0x10) != 0) 4 else 3;

    return 1;
}

// ---- PNM (PGM / PPM) loader ----

fn stbi__pnm_test(s: [*c]stbi__context) c_int {
    const p: u8 = stbi__get8(s);
    const t: u8 = stbi__get8(s);
    if (p != 'P' or (t != '5' and t != '6')) {
        stbi__rewind(s);
        return 0;
    }
    return 1;
}

fn stbi__pnm_load(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int, req_comp: c_int, ri: [*c]stbi__result_info) ?*anyopaque {
    ri.*.bits_per_channel = stbi__pnm_info(s, @ptrCast(&s.*.img_x), @ptrCast(&s.*.img_y), @ptrCast(&s.*.img_n));
    if (ri.*.bits_per_channel == 0) return null;

    if (s.*.img_y > @as(u32, @intCast(STBI_MAX_DIMENSIONS))) return stbi__errpuc("too large", "Very large image (corrupt?)");
    if (s.*.img_x > @as(u32, @intCast(STBI_MAX_DIMENSIONS))) return stbi__errpuc("too large", "Very large image (corrupt?)");

    x.* = @bitCast(s.*.img_x);
    y.* = @bitCast(s.*.img_y);
    if (comp != null) comp.* = s.*.img_n;

    const bytes_per_channel: c_int = @divTrunc(ri.*.bits_per_channel, 8);
    const img_x: c_int = @bitCast(s.*.img_x);
    const img_y: c_int = @bitCast(s.*.img_y);
    if (stbi__mad4sizes_valid(s.*.img_n, img_x, img_y, bytes_per_channel, 0) == 0)
        return stbi__errpuc("too large", "PNM too large");

    var out: [*c]stbi_uc = @ptrCast(@alignCast(stbi__malloc_mad4(s.*.img_n, img_x, img_y, bytes_per_channel, 0)));
    if (out == null) return stbi__errpuc("outofmem", "Out of memory");
    if (stbi__getn(s, out, s.*.img_n * img_x * img_y * bytes_per_channel) == 0) {
        base.rvn_free(out);
        return stbi__errpuc("bad PNM", "PNM file truncated");
    }

    if (req_comp != 0 and req_comp != s.*.img_n) {
        if (ri.*.bits_per_channel == 16) {
            out = @ptrCast(stbi__convert_format16(@ptrCast(@alignCast(out)), s.*.img_n, req_comp, @bitCast(img_x), @bitCast(img_y)));
        } else {
            out = stbi__convert_format(out, s.*.img_n, req_comp, @bitCast(img_x), @bitCast(img_y));
        }
        if (out == null) return null; // stbi__convert_format frees input on failure
    }
    return out;
}

fn stbi__pnm_isspace(c: u8) c_int {
    return @intFromBool(c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r');
}

fn stbi__pnm_skip_whitespace(s: [*c]stbi__context, c: *u8) void {
    while (true) {
        while (stbi__at_eof(s) == 0 and stbi__pnm_isspace(c.*) != 0) c.* = stbi__get8(s);

        if (stbi__at_eof(s) != 0 or c.* != '#') break;

        while (stbi__at_eof(s) == 0 and c.* != '\n' and c.* != '\r') c.* = stbi__get8(s);
    }
}

fn stbi__pnm_isdigit(c: u8) c_int {
    return @intFromBool(c >= '0' and c <= '9');
}

fn stbi__pnm_getinteger(s: [*c]stbi__context, c: *u8) c_int {
    var value: c_int = 0;

    while (stbi__at_eof(s) == 0 and stbi__pnm_isdigit(c.*) != 0) {
        // C: value = value*10 + (*c - '0'); the overflow check below runs after this step.
        value = value *% 10 +% (@as(c_int, c.*) - '0');
        c.* = stbi__get8(s);
        if ((value > 214748364) or (value == 214748364 and c.* > '7'))
            return stbi__err("integer parse overflow", "Parsing an integer in the PPM header overflowed a 32-bit int");
    }

    return value;
}

fn stbi__pnm_info(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    var dummy_x: c_int = 0;
    var dummy_y: c_int = 0;
    var dummy_comp: c_int = 0;
    const xp: [*c]c_int = if (x != null) x else &dummy_x;
    const yp: [*c]c_int = if (y != null) y else &dummy_y;
    const compp: [*c]c_int = if (comp != null) comp else &dummy_comp;

    stbi__rewind(s);

    // Get identifier
    const p: u8 = stbi__get8(s);
    const t: u8 = stbi__get8(s);
    if (p != 'P' or (t != '5' and t != '6')) {
        stbi__rewind(s);
        return 0;
    }

    compp.* = if (t == '6') 3 else 1; // '5' is 1-component .pgm; '6' is 3-component .ppm

    var c: u8 = stbi__get8(s);
    stbi__pnm_skip_whitespace(s, &c);

    xp.* = stbi__pnm_getinteger(s, &c); // read width
    if (xp.* == 0) return stbi__err("invalid width", "PPM image header had zero or overflowing width");
    stbi__pnm_skip_whitespace(s, &c);

    yp.* = stbi__pnm_getinteger(s, &c); // read height
    if (yp.* == 0) return stbi__err("invalid width", "PPM image header had zero or overflowing width");
    stbi__pnm_skip_whitespace(s, &c);

    const maxv: c_int = stbi__pnm_getinteger(s, &c); // read max value
    if (maxv > 65535) {
        return stbi__err("max value > 65535", "PPM image supports only 8-bit and 16-bit images");
    } else if (maxv > 255) {
        return 16;
    } else {
        return 8;
    }
}

fn stbi__pnm_is16(s: [*c]stbi__context) c_int {
    if (stbi__pnm_info(s, null, null, null) == 16) return 1;
    return 0;
}

fn stbi__info_main(s: [*c]stbi__context, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    if (stbi__jpeg_info(s, x, y, comp) != 0) return 1;
    if (stbi__png_info(s, x, y, comp) != 0) return 1;
    if (stbi__gif_info(s, x, y, comp) != 0) return 1;
    if (stbi__bmp_info(s, x, y, comp) != 0) return 1;
    if (stbi__psd_info(s, x, y, comp) != 0) return 1;
    if (stbi__pic_info(s, x, y, comp) != 0) return 1;
    if (stbi__pnm_info(s, x, y, comp) != 0) return 1;
    // test tga last because it's a crappy test!
    if (stbi__tga_info(s, x, y, comp) != 0) return 1;
    return stbi__err("unknown image type", "Image not of any known type, or corrupt");
}

fn stbi__is_16_main(s: [*c]stbi__context) c_int {
    if (stbi__png_is16(s) != 0) return 1;
    if (stbi__psd_is16(s) != 0) return 1;
    if (stbi__pnm_is16(s) != 0) return 1;
    return 0;
}

/// STBIDEF int stbi_info_from_memory(stbi_uc const *buffer, int len, int *x, int *y, int *comp)
pub fn stbi_info_from_memory(buffer:[*c]const stbi_uc, len: c_int, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    var s: stbi__context = undefined;
    stbi__start_mem(&s, buffer, len);
    return stbi__info_main(&s, x, y, comp);
}

/// STBIDEF int stbi_info_from_callbacks(stbi_io_callbacks const *c, void *user, int *x, int *y, int *comp)
fn stbi_info_from_callbacks(c: [*c]const stbi_io_callbacks, user: ?*anyopaque, x: [*c]c_int, y: [*c]c_int, comp: [*c]c_int) c_int {
    var s: stbi__context = undefined;
    stbi__start_callbacks(&s, c, user);
    return stbi__info_main(&s, x, y, comp);
}

/// STBIDEF int stbi_is_16_bit_from_memory(stbi_uc const *buffer, int len)
fn stbi_is_16_bit_from_memory(buffer: [*c]const stbi_uc, len: c_int) c_int {
    var s: stbi__context = undefined;
    stbi__start_mem(&s, buffer, len);
    return stbi__is_16_main(&s);
}

/// STBIDEF int stbi_is_16_bit_from_callbacks(stbi_io_callbacks const *c, void *user)
fn stbi_is_16_bit_from_callbacks(c: [*c]const stbi_io_callbacks, user: ?*anyopaque) c_int {
    var s: stbi__context = undefined;
    stbi__start_callbacks(&s, c, user);
    return stbi__is_16_main(&s);
}
