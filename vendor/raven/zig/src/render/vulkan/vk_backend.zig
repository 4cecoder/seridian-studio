// Translated to Zig from vendor/raven/src/render/vulkan/vk_backend.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_backend.c
// The Vulkan implementation of RBackendVTable.

const std = @import("std");
const raven = @import("raven");
const be = @import("vk_backend_h.zig");

fn rvn_vk_shutdown() callconv(.c) void {
    if (be.g_vk.device != null and be.loader.rvn_vk.DeviceWaitIdle != null) {
        be.rvn_vk_queue_lock();
        _ = be.loader.rvn_vk.DeviceWaitIdle.?(be.g_vk.device);
        be.rvn_vk_queue_unlock();
        be.rvn_vk_surfaces_shutdown();
        be.rvn_vk_textures_shutdown();
        be.rvn_vk_pipeline_shutdown();
    }
    be.rvn_vk_device_shutdown();
    @memset(std.mem.asBytes(&be.g_vk), 0); // memset(&g_vk, 0, sizeof(g_vk));
}

fn rvn_vk_init(info: [*c]const raven.RBackendInitInfo) callconv(.c) c_int {
    @memset(std.mem.asBytes(&be.g_vk), 0); // memset(&g_vk, 0, sizeof(g_vk));
    be.g_vk.info = info.*;
    if (be.rvn_vk_device_init() == 0 or be.rvn_vk_pipeline_init() == 0 or be.rvn_vk_textures_init() == 0) {
        rvn_vk_shutdown();
        return raven.R_FALSE;
    }
    be.g_vk.initialized = raven.R_TRUE;
    return raven.R_TRUE;
}

fn rvn_vk_wait_idle() callconv(.c) void {
    be.rvn_vk_uploads_flush();
    be.rvn_vk_wait_frames();
}

export fn rvn_backend_vulkan() [*c]const raven.RBackendVTable {
    const S = struct {
        const vtable: raven.RBackendVTable = .{
            .name = "Vulkan",
            .Init = &rvn_vk_init,
            .Shutdown = &rvn_vk_shutdown,
            .CreateSurface = &be.rvn_vk_surface_create,
            .DestroySurface = &be.rvn_vk_surface_destroy,
            .CreateTexture = &be.rvn_vk_texture_create,
            .UpdateTexture = &be.rvn_vk_texture_update,
            .SetTextureFilter = &be.rvn_vk_texture_set_filter,
            .DestroyTexture = &be.rvn_vk_texture_destroy,
            .RenderFrame = &be.rvn_vk_render_frame,
            .WaitIdle = &rvn_vk_wait_idle,
            .CreateShader = &be.rvn_vk_shader_create,
            .DestroyShader = &be.rvn_vk_shader_destroy,
        };
    };
    return &S.vtable;
}
