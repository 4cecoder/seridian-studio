// Translated to Zig from vendor/raven/src/render/null/null_backend.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/null/null_backend.c
// Backend that draws nothing. It is used for headless runs and unit tests,
// and is the smallest example of a RBackendVTable: copy it to start a
// new backend.

const std = @import("std");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");

fn rvn_null_init(info: [*c]const raven.RBackendInitInfo) callconv(.c) c_int {
    _ = info;
    return raven.R_TRUE;
}

fn rvn_null_shutdown() callconv(.c) void {}

fn rvn_null_create_surface(window: raven.Rid, native: [*c]const raven.RNativeWindow, width: raven.Ruint, height: raven.Ruint) callconv(.c) c_int {
    _ = window;
    _ = native;
    _ = width;
    _ = height;
    return raven.R_TRUE;
}

fn rvn_null_destroy_surface(window: raven.Rid) callconv(.c) void {
    _ = window;
}

fn rvn_null_create_texture(texture: raven.Rid, desc: [*c]const raven.RTextureDesc, pixels: ?*const anyopaque) callconv(.c) c_int {
    _ = texture;
    _ = desc;
    _ = pixels;
    return raven.R_TRUE;
}

fn rvn_null_update_texture(texture: raven.Rid, x: raven.Ruint, y: raven.Ruint, width: raven.Ruint, height: raven.Ruint, pixels: ?*const anyopaque) callconv(.c) void {
    _ = texture;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = pixels;
}

fn rvn_null_set_texture_filter(texture: raven.Rid, filter: raven.RFilterType) callconv(.c) void {
    _ = texture;
    _ = filter;
}

fn rvn_null_destroy_texture(texture: raven.Rid) callconv(.c) void {
    _ = texture;
}

fn rvn_null_render_frame(data: [*c]const raven.RDrawData, capture: [*c]raven.RCapture) callconv(.c) void {
    if (capture != null) {
        // a capture of the null backend is the clear color
        const count: usize = @as(usize, data.*.framebuffer_width) *% @as(usize, data.*.framebuffer_height);
        var i: usize = 0;
        const clear: base.rvn_color_t = base.rvn_rgba(data.*.clear_color[0], data.*.clear_color[1], data.*.clear_color[2], data.*.clear_color[3]);
        capture.*.width = @bitCast(data.*.framebuffer_width);
        capture.*.height = @bitCast(data.*.framebuffer_height);
        capture.*.pixels = if (count != 0) raven.Rpixels_alloc(count *% 4) else null;
        while (i < count) : (i += 1) {
            const dst: [*c]u8 = capture.*.pixels + i *% 4;
            @memcpy(dst[0..4], std.mem.asBytes(&clear)[0..4]); // memcpy(capture->pixels + i * 4, &clear, 4);
        }
    }
}

fn rvn_null_wait_idle() callconv(.c) void {}

export fn rvn_backend_null() [*c]const raven.RBackendVTable {
    const S = struct {
        const vtable: raven.RBackendVTable = .{
            .name = "null",
            .Init = &rvn_null_init,
            .Shutdown = &rvn_null_shutdown,
            .CreateSurface = &rvn_null_create_surface,
            .DestroySurface = &rvn_null_destroy_surface,
            .CreateTexture = &rvn_null_create_texture,
            .UpdateTexture = &rvn_null_update_texture,
            .SetTextureFilter = &rvn_null_set_texture_filter,
            .DestroyTexture = &rvn_null_destroy_texture,
            .RenderFrame = &rvn_null_render_frame,
            .WaitIdle = &rvn_null_wait_idle,
            // (no effects: their rectangles are not drawn either)
            .CreateShader = null,
            .DestroyShader = null,
        };
    };
    return &S.vtable;
}
