// Translated to Zig from vendor/raven/src/render/image_decode.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/image_decode.c
// The only file that includes stb_image. Compiled as static functions so it
// never clashes with another copy of stb linked into the application.
// Thread-safe: called from the job system for asynchronous textures.
//
// The stb_image implementation is the Zig translation in ../third_party/stb_image.zig, built for the
// configuration of the C file (STBI_NO_STDIO, STBI_NO_HDR, STBI_NO_LINEAR, STBI_NO_FAILURE_STRINGS,
// STBI_MALLOC / STBI_REALLOC / STBI_FREE = rvn_alloc / rvn_realloc / rvn_free). The C file's GCC
// diagnostic pragmas around the stb_image include have no counterpart here: they only silenced
// warnings of the C compiler inside the third-party code.

const config = @import("raven_config");
const stbi = @import("../third_party/stb_image.zig");

/// The #else branch of the C file: RVN_UNUSED on each parameter, then NULL.
fn rvnImageDecodeDisabled(data: [*c]const u8, size: usize, width: [*c]c_int, height: [*c]c_int) [*c]u8 {
    _ = data;
    _ = size;
    _ = width;
    _ = height;
    return null;
}

/// uint8_t* rvn_image_decode(const uint8_t* data, size_t size, int* width, int* height)
export fn rvn_image_decode(data: [*c]const u8, size: usize, width: [*c]c_int, height: [*c]c_int) [*c]u8 {
    if (config.with_stb_image) {
        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;
        if (data == null or size == 0 or size > 0x7FFFFFFF) return null;
        const pixels = stbi.stbi_load_from_memory(data, @intCast(size), &w, &h, &channels, 4);
        if (pixels == null) return null;
        width.* = w;
        height.* = h;
        return pixels;
    } else {
        return rvnImageDecodeDisabled(data, size, width, height);
    }
}
