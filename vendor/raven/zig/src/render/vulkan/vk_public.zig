// Translated to Zig from vendor/raven/src/render/vulkan/vk_public.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_public.c
// Public API of raven_vulkan.h.
//
// These functions are called from the UI thread. Whatever touches Vulkan
// objects is forwarded to the render thread, in order with the frames.

const std = @import("std");
const raven = @import("raven");
const be = @import("vk_backend_h.zig");
const base = @import("../../core/base_h.zig");
const ctx = @import("../../core/context_h.zig");
const handle = @import("../../core/handle_h.zig");
const thread = @import("../../core/thread_h.zig");
const renderer = @import("../renderer_h.zig");

fn rvn_vk_active(function: [*c]const u8) c_int {
    if (ctx.g_rvn.initialized != 0 and ctx.g_rvn.backend == raven.R_BACKEND_VULKAN) return raven.R_TRUE;
    if (function != null) base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "%s: the Vulkan backend is not running", function);
    return raven.R_FALSE;
}

// ---------------------------------------------------------------------------
//  Sharing a device
// ---------------------------------------------------------------------------

export fn Rvulkan_get_required_instance_extensions(count: [*c]raven.Ruint) [*c]const [*c]const u8 {
    var found: u32 = 0;
    const names = be.rvn_vk_instance_extensions(&found);
    if (count != null) count.* = found;
    return names;
}

export fn Rvulkan_get_required_device_extensions(count: [*c]raven.Ruint) [*c]const [*c]const u8 {
    var found: u32 = 0;
    const names = be.rvn_vk_device_extensions(&found);
    if (count != null) count.* = found;
    return names;
}

export fn Rvulkan_set_external_device(instance: ?*anyopaque, physical_device: ?*anyopaque, device: ?*anyopaque, queue: ?*anyopaque, queue_family: raven.Ruint) void {
    if (ctx.g_rvn.initialized != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rvulkan_set_external_device must be called before Rinit");
        return;
    }
    // NULL handles go back to a device created by Raven
    be.g_vk_config.external = @intFromBool(instance != null and device != null);
    be.g_vk_config.instance = @ptrCast(instance);
    be.g_vk_config.physical_device = @ptrCast(physical_device);
    be.g_vk_config.device = @ptrCast(device);
    be.g_vk_config.queue = @ptrCast(queue);
    be.g_vk_config.queue_family = queue_family;
}

export fn Rvulkan_set_queue_lock_callbacks(lock: raven.RVulkanQueueLockCallback, unlock: raven.RVulkanQueueLockCallback, user_data: ?*anyopaque) void {
    if (ctx.g_rvn.initialized != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rvulkan_set_queue_lock_callbacks must be called before Rinit");
        return;
    }
    be.g_vk_config.lock = lock;
    be.g_vk_config.unlock = unlock;
    be.g_vk_config.lock_user_data = user_data;
}

// ---------------------------------------------------------------------------
//  Access to the device
// ---------------------------------------------------------------------------

export fn Rvulkan_get_instance() ?*anyopaque {
    return if (rvn_vk_active(null) != 0) @ptrCast(be.g_vk.instance) else null;
}

export fn Rvulkan_get_physical_device() ?*anyopaque {
    return if (rvn_vk_active(null) != 0) @ptrCast(be.g_vk.physical_device) else null;
}

export fn Rvulkan_get_device() ?*anyopaque {
    return if (rvn_vk_active(null) != 0) @ptrCast(be.g_vk.device) else null;
}

export fn Rvulkan_get_graphics_queue() ?*anyopaque {
    return if (rvn_vk_active(null) != 0) @ptrCast(be.g_vk.queue) else null;
}

export fn Rvulkan_get_graphics_queue_family() raven.Ruint {
    return if (rvn_vk_active(null) != 0) be.g_vk.queue_family else 0;
}

// ---------------------------------------------------------------------------
//  Textures
// ---------------------------------------------------------------------------

const rvn_vk_texture_call_t = extern struct {
    id: raven.Rid,
    view: be.vk.VkImageView,
    sampler: be.vk.VkSampler,
    width: u32,
    height: u32,
    handle: isize,
    allocation_size: u64,
    result: c_int,
};

fn rvn_vk_call_wrap(arg: ?*anyopaque) callconv(.c) void {
    const call: [*c]rvn_vk_texture_call_t = @ptrCast(@alignCast(arg));
    call.*.result = be.rvn_vk_texture_wrap(call.*.id, call.*.view, call.*.sampler, call.*.width, call.*.height);
}

fn rvn_vk_call_create_shared(arg: ?*anyopaque) callconv(.c) void {
    const call: [*c]rvn_vk_texture_call_t = @ptrCast(@alignCast(arg));
    call.*.result = be.rvn_vk_texture_create_shared(call.*.id, call.*.width, call.*.height);
}

fn rvn_vk_call_export(arg: ?*anyopaque) callconv(.c) void {
    const call: [*c]rvn_vk_texture_call_t = @ptrCast(@alignCast(arg));
    call.*.result = be.rvn_vk_texture_export(call.*.id, &call.*.handle, &call.*.allocation_size);
}

// Registers a texture whose backend object is made by `function` on the render thread.
fn rvn_vk_create_external(function: renderer.rvn_render_fn, call: [*c]rvn_vk_texture_call_t) raven.Rid {
    const texture = renderer.rvn_texture_register();
    if (texture == null) return raven.R_INVALID_ID;
    call.*.id = texture.*.id;
    renderer.rvn_renderer_call(function, call, raven.R_TRUE);
    if (call.*.result == 0) {
        handle.rvn_pool_remove(&ctx.g_rvn.textures, texture.*.id);
        base.rvn_free(texture);
        return raven.R_INVALID_ID;
    }
    texture.*.width = @intCast(call.*.width);
    texture.*.height = @intCast(call.*.height);
    texture.*.external = raven.R_TRUE;
    texture.*.created = raven.R_TRUE;
    thread.rvn_atomic_store(&texture.*.ready, 1);
    return texture.*.id;
}

export fn Rvulkan_texture_create_from_image_view(image_view: u64, sampler: u64, width: c_int, height: c_int) raven.Rid {
    var call: rvn_vk_texture_call_t = undefined;
    if (ctx.rvn_api_check("Rvulkan_texture_create_from_image_view") == 0) return raven.R_INVALID_ID;
    if (rvn_vk_active("Rvulkan_texture_create_from_image_view") == 0) return raven.R_INVALID_ID;
    if (image_view == 0 or width <= 0 or height <= 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rvulkan_texture_create_from_image_view: invalid arguments");
        return raven.R_INVALID_ID;
    }
    @memset(std.mem.asBytes(&call), 0);
    call.view = @ptrFromInt(@as(usize, @intCast(image_view)));
    call.sampler = @ptrFromInt(@as(usize, @intCast(sampler)));
    call.width = @intCast(width);
    call.height = @intCast(height);
    return rvn_vk_create_external(&rvn_vk_call_wrap, &call);
}

export fn Rvulkan_texture_set_image_view(id: raven.Rid, image_view: u64, sampler: u64, width: c_int, height: c_int) void {
    var call: rvn_vk_texture_call_t = undefined;
    if (ctx.rvn_api_check("Rvulkan_texture_set_image_view") == 0) return;
    if (rvn_vk_active("Rvulkan_texture_set_image_view") == 0) return;
    const texture = renderer.rvn_texture_get(id);
    if (texture == null or texture.*.external == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rvulkan_texture_set_image_view: not a texture made from an image view");
        return;
    }
    if (image_view == 0 or width <= 0 or height <= 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rvulkan_texture_set_image_view: invalid arguments");
        return;
    }
    @memset(std.mem.asBytes(&call), 0);
    call.id = id;
    call.view = @ptrFromInt(@as(usize, @intCast(image_view)));
    call.sampler = @ptrFromInt(@as(usize, @intCast(sampler)));
    call.width = @intCast(width);
    call.height = @intCast(height);
    // waits: once this returns, Raven no longer uses the previous view and it can be destroyed
    renderer.rvn_renderer_call(&rvn_vk_call_wrap, &call, raven.R_TRUE);
    texture.*.width = width;
    texture.*.height = height;
    ctx.rvn_invalidate_all_windows();
}

export fn Rvulkan_texture_create_shared(width: c_int, height: c_int) raven.Rid {
    var call: rvn_vk_texture_call_t = undefined;
    if (ctx.rvn_api_check("Rvulkan_texture_create_shared") == 0) return raven.R_INVALID_ID;
    if (rvn_vk_active("Rvulkan_texture_create_shared") == 0) return raven.R_INVALID_ID;
    if (width <= 0 or height <= 0 or width > 16384 or height > 16384) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rvulkan_texture_create_shared: invalid size %d x %d", width, height);
        return raven.R_INVALID_ID;
    }
    @memset(std.mem.asBytes(&call), 0);
    call.width = @intCast(width);
    call.height = @intCast(height);
    const id = rvn_vk_create_external(&rvn_vk_call_create_shared, &call);
    if (id == raven.R_INVALID_ID) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Rvulkan_texture_create_shared: the device cannot export memory (external memory extension missing)");
    }
    return id;
}

export fn Rvulkan_texture_get_shared_info(id: raven.Rid, info: [*c]raven.RSharedTextureInfo) c_int {
    var call: rvn_vk_texture_call_t = undefined;
    if (ctx.rvn_api_check("Rvulkan_texture_get_shared_info") == 0) return raven.R_FALSE;
    if (rvn_vk_active("Rvulkan_texture_get_shared_info") == 0) return raven.R_FALSE;
    const texture = renderer.rvn_texture_get(id);
    if (texture == null or info == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rvulkan_texture_get_shared_info: invalid arguments");
        return raven.R_FALSE;
    }
    @memset(std.mem.asBytes(&call), 0);
    call.id = id;
    renderer.rvn_renderer_call(&rvn_vk_call_export, &call, raven.R_TRUE);
    if (call.result == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rvulkan_texture_get_shared_info: not a shared texture");
        return raven.R_FALSE;
    }
    info.*.handle = call.handle;
    info.*.allocation_size = call.allocation_size;
    info.*.width = texture.*.width;
    info.*.height = texture.*.height;
    return raven.R_TRUE;
}
