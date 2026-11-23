// Translated to Zig from vendor/raven/src/render/vulkan/vk_texture.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_texture.c
// Textures and pixel uploads.
//
// A texture is an image, a view and one descriptor set. Uploads are batched:
// the pixels are copied into a staging buffer and the copy commands are
// recorded in one command buffer, submitted once before the next frame
// (rvn_vk_uploads_flush). The many small updates of the glyph atlas at
// start-up therefore cost a single submission.
//
// Textures can also wrap an image view owned by the application (zero-copy
// viewports) or export their memory to another API (shared textures).

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const be = @import("vk_backend_h.zig");
const vk = be.vk;
const loader = be.loader;

const g_vk = &be.g_vk;
const rvn_vk = &loader.rvn_vk;

/// First size of the staging buffer; it grows to the largest upload.
const RVN_VK_STAGING_SIZE: vk.VkDeviceSize = 4 * 1024 * 1024;

const UINT32_MAX: u32 = std.math.maxInt(u32);

// ---------------------------------------------------------------------------
//  Upload batch
// ---------------------------------------------------------------------------

export fn rvn_vk_uploads_flush() void {
    if (g_vk.upload_open == raven.R_FALSE) return;
    g_vk.upload_open = raven.R_FALSE;
    g_vk.staging_used = 0;
    if (be.rvn_vk_failed(rvn_vk.EndCommandBuffer.?(g_vk.upload_commands), "vkEndCommandBuffer") != raven.R_FALSE) return;

    var submit = std.mem.zeroes(vk.VkSubmitInfo);
    submit.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &g_vk.upload_commands;
    be.rvn_vk_queue_lock();
    const result = rvn_vk.QueueSubmit.?(g_vk.queue, 1, &submit, g_vk.upload_fence);
    be.rvn_vk_queue_unlock();
    if (be.rvn_vk_failed(result, "vkQueueSubmit") != raven.R_FALSE) return;

    // the staging buffer is reused right away, so the copies must be finished
    _ = rvn_vk.WaitForFences.?(g_vk.device, 1, &g_vk.upload_fence, vk.VK_TRUE, std.math.maxInt(u64));
    _ = rvn_vk.ResetFences.?(g_vk.device, 1, &g_vk.upload_fence);
}

// Starts the batch when needed.
fn rvn_vk_upload_begin() c_int {
    if (g_vk.upload_open != raven.R_FALSE) return raven.R_TRUE;
    var begin = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
    begin.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (be.rvn_vk_failed(rvn_vk.BeginCommandBuffer.?(g_vk.upload_commands, &begin), "vkBeginCommandBuffer") != raven.R_FALSE) return raven.R_FALSE;
    g_vk.upload_open = raven.R_TRUE;
    return raven.R_TRUE;
}

// Returns `size` bytes of the staging buffer, or NULL.
fn rvn_vk_staging_reserve(size: vk.VkDeviceSize, offset: [*c]vk.VkDeviceSize) ?*anyopaque {
    var start: vk.VkDeviceSize = (g_vk.staging_used + 15) & ~@as(vk.VkDeviceSize, 15);
    if (start + size > g_vk.staging.size) {
        // full: send what is pending, which frees the whole buffer
        rvn_vk_uploads_flush();
        start = 0;
        if (size > g_vk.staging.size) {
            var wanted: vk.VkDeviceSize = if (g_vk.staging.size != 0) g_vk.staging.size else RVN_VK_STAGING_SIZE;
            while (wanted < size) wanted *= 2;
            be.rvn_vk_buffer_destroy(&g_vk.staging);
            if (be.rvn_vk_buffer_create(&g_vk.staging, wanted, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT) == raven.R_FALSE) return null;
        }
    }
    offset.* = start;
    g_vk.staging_used = start + size;
    return @as([*c]u8, @ptrCast(g_vk.staging.mapped)) + @as(usize, @intCast(start));
}

fn rvn_vk_image_barrier(
    commands: vk.VkCommandBuffer,
    image: vk.VkImage,
    from: vk.VkImageLayout,
    to: vk.VkImageLayout,
    source_access: vk.VkAccessFlags,
    target_access: vk.VkAccessFlags,
    source_stage: vk.VkPipelineStageFlags,
    target_stage: vk.VkPipelineStageFlags,
) void {
    var barrier = std.mem.zeroes(vk.VkImageMemoryBarrier);
    barrier.sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = source_access;
    barrier.dstAccessMask = target_access;
    barrier.oldLayout = from;
    barrier.newLayout = to;
    barrier.srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.layerCount = 1;
    rvn_vk.CmdPipelineBarrier.?(commands, source_stage, target_stage, 0, 0, null, 0, null, 1, &barrier);
}

// ---------------------------------------------------------------------------
//  Texture objects
// ---------------------------------------------------------------------------

fn rvn_vk_texel_size(format: raven.RTextureFormat) u32 {
    return if (format == raven.R_TEXTURE_ALPHA8) 1 else 4;
}

fn rvn_vk_texture_sampler(texture: [*c]const be.rvn_vk_texture_t) vk.VkSampler {
    if (texture.*.sampler != null) return texture.*.sampler;
    return if (texture.*.filter == raven.R_FILTER_NEAREST) g_vk.sampler_nearest else g_vk.sampler_linear;
}

fn rvn_vk_texture_release(texture: [*c]be.rvn_vk_texture_t) void {
    be.rvn_vk_set_free(texture.*.set, texture.*.pool);
    if (texture.*.wrapped == raven.R_FALSE and texture.*.view != null) rvn_vk.DestroyImageView.?(g_vk.device, texture.*.view, null);
    if (texture.*.image != null) rvn_vk.DestroyImage.?(g_vk.device, texture.*.image, null);
    if (texture.*.memory != null) rvn_vk.FreeMemory.?(g_vk.device, texture.*.memory, null);
    texture.* = std.mem.zeroes(be.rvn_vk_texture_t);
}

// Records the copy of `pixels` (tightly packed) into a region of the texture.
fn rvn_vk_texture_write(texture: [*c]be.rvn_vk_texture_t, x: u32, y: u32, width: u32, height: u32, pixels: ?*const anyopaque) void {
    // unsigned wrap-around of the C arithmetic is kept on purpose (bug for bug)
    const size: vk.VkDeviceSize = @as(vk.VkDeviceSize, width) *% @as(vk.VkDeviceSize, height) *% @as(vk.VkDeviceSize, rvn_vk_texel_size(texture.*.format));
    var offset: vk.VkDeviceSize = 0;
    var region: vk.VkBufferImageCopy = undefined;

    if (width == 0 or height == 0 or x +% width > texture.*.width or y +% height > texture.*.height) return;
    const staging_ptr = rvn_vk_staging_reserve(size, &offset);
    if (staging_ptr == null) return;
    if (rvn_vk_upload_begin() == raven.R_FALSE) return;
    const staging: [*c]u8 = @ptrCast(staging_ptr);
    const count: usize = @intCast(size);
    // no pixels: the texture starts transparent rather than with random memory
    if (pixels) |src| {
        const source: [*c]const u8 = @ptrCast(src);
        @memcpy(staging[0..count], source[0..count]);
    } else {
        @memset(staging[0..count], 0);
    }

    rvn_vk_image_barrier(g_vk.upload_commands, texture.*.image,
        if (texture.*.initialized != raven.R_FALSE) vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else vk.VK_IMAGE_LAYOUT_UNDEFINED,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        if (texture.*.initialized != raven.R_FALSE) vk.VK_ACCESS_SHADER_READ_BIT else 0,
        vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        if (texture.*.initialized != raven.R_FALSE) vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT else vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT);

    region = std.mem.zeroes(vk.VkBufferImageCopy);
    region.bufferOffset = offset;
    region.imageSubresource.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageOffset.x = @bitCast(x); // (int32_t)x
    region.imageOffset.y = @bitCast(y); // (int32_t)y
    region.imageExtent.width = width;
    region.imageExtent.height = height;
    region.imageExtent.depth = 1;
    rvn_vk.CmdCopyBufferToImage.?(g_vk.upload_commands, g_vk.staging.buffer, texture.*.image,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    rvn_vk_image_barrier(g_vk.upload_commands, texture.*.image,
        vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk.VK_ACCESS_TRANSFER_WRITE_BIT, vk.VK_ACCESS_SHADER_READ_BIT,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    texture.*.initialized = raven.R_TRUE;
}

// Creates the image, its memory, its view and its descriptor set.
fn rvn_vk_texture_build(texture: [*c]be.rvn_vk_texture_t, width: u32, height: u32, format: raven.RTextureFormat, filter: raven.RFilterType, shared: c_int) c_int {
    const handle_type: vk.VkExternalMemoryHandleTypeFlags = if (builtin.os.tag == .windows)
        vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT
    else
        vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;

    texture.* = std.mem.zeroes(be.rvn_vk_texture_t); // memset(texture, 0, sizeof(*texture));
    texture.*.used = raven.R_TRUE;
    texture.*.width = width;
    texture.*.height = height;
    texture.*.format = format;
    texture.*.filter = filter;
    texture.*.shared = shared;

    failed: {
        var image = std.mem.zeroes(vk.VkImageCreateInfo);
        var external_image = std.mem.zeroes(vk.VkExternalMemoryImageCreateInfo);
        var requirements: vk.VkMemoryRequirements = undefined;
        var allocation = std.mem.zeroes(vk.VkMemoryAllocateInfo);
        var export_allocation = std.mem.zeroes(vk.VkExportMemoryAllocateInfo);
        var view = std.mem.zeroes(vk.VkImageViewCreateInfo);

        image.sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image.imageType = vk.VK_IMAGE_TYPE_2D;
        image.format = if (format == raven.R_TEXTURE_ALPHA8) vk.VK_FORMAT_R8_UNORM else vk.VK_FORMAT_R8G8B8A8_UNORM;
        image.extent.width = width;
        image.extent.height = height;
        image.extent.depth = 1;
        image.mipLevels = 1;
        image.arrayLayers = 1;
        image.samples = vk.VK_SAMPLE_COUNT_1_BIT;
        image.tiling = vk.VK_IMAGE_TILING_OPTIMAL;
        image.usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        image.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
        image.initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
        if (shared != raven.R_FALSE) {
            // the other API typically renders into the image or copies from it
            image.usage |= vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
            external_image.sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
            external_image.handleTypes = handle_type;
            image.pNext = &external_image;
        }
        if (be.rvn_vk_failed(rvn_vk.CreateImage.?(g_vk.device, &image, null, &texture.*.image), "vkCreateImage") != raven.R_FALSE) break :failed;

        rvn_vk.GetImageMemoryRequirements.?(g_vk.device, texture.*.image, &requirements);
        allocation.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = be.rvn_vk_find_memory_type(requirements.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (allocation.memoryTypeIndex == UINT32_MAX) allocation.memoryTypeIndex = be.rvn_vk_find_memory_type(requirements.memoryTypeBits, 0);
        if (shared != raven.R_FALSE) {
            export_allocation.sType = vk.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
            export_allocation.handleTypes = handle_type;
            allocation.pNext = &export_allocation;
        }
        if (allocation.memoryTypeIndex == UINT32_MAX or
            be.rvn_vk_failed(rvn_vk.AllocateMemory.?(g_vk.device, &allocation, null, &texture.*.memory), "vkAllocateMemory") != raven.R_FALSE or
            be.rvn_vk_failed(rvn_vk.BindImageMemory.?(g_vk.device, texture.*.image, texture.*.memory, 0), "vkBindImageMemory") != raven.R_FALSE) break :failed;
        texture.*.allocation_size = requirements.size;

        view.sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view.image = texture.*.image;
        view.viewType = vk.VK_IMAGE_VIEW_TYPE_2D;
        view.format = image.format;
        if (format == raven.R_TEXTURE_ALPHA8) {
            // sampled as (1, 1, 1, value): the same shader path as color textures
            view.components.r = vk.VK_COMPONENT_SWIZZLE_ONE;
            view.components.g = vk.VK_COMPONENT_SWIZZLE_ONE;
            view.components.b = vk.VK_COMPONENT_SWIZZLE_ONE;
            view.components.a = vk.VK_COMPONENT_SWIZZLE_R;
        }
        view.subresourceRange.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
        view.subresourceRange.levelCount = 1;
        view.subresourceRange.layerCount = 1;
        if (be.rvn_vk_failed(rvn_vk.CreateImageView.?(g_vk.device, &view, null, &texture.*.view), "vkCreateImageView") != raven.R_FALSE) break :failed;

        if (be.rvn_vk_set_allocate(&texture.*.set, &texture.*.pool) == raven.R_FALSE) break :failed;
        be.rvn_vk_set_write(texture.*.set, texture.*.view, rvn_vk_texture_sampler(texture));
        return raven.R_TRUE;
    }

    rvn_vk_texture_release(texture);
    return raven.R_FALSE;
}

// ---------------------------------------------------------------------------
//  Table of textures, indexed by the index part of the handle
// ---------------------------------------------------------------------------

export fn rvn_vk_texture_find(texture: raven.Rid) [*c]be.rvn_vk_texture_t {
    const index: u32 = raven.R_ID_INDEX(texture);
    if (texture == raven.R_INVALID_ID or index >= g_vk.texture_cap or g_vk.textures[index].used == raven.R_FALSE) return null;
    return &g_vk.textures[index];
}

// Returns the (unused) slot of a handle, growing the table when needed.
fn rvn_vk_texture_slot(texture: raven.Rid) [*c]be.rvn_vk_texture_t {
    const index: u32 = raven.R_ID_INDEX(texture);
    if (index >= g_vk.texture_cap) {
        var cap: u32 = if (g_vk.texture_cap != 0) g_vk.texture_cap else 64;
        while (cap <= index) cap *= 2;
        g_vk.textures = @ptrCast(@alignCast(base.rvn_realloc(g_vk.textures, @sizeOf(be.rvn_vk_texture_t) * @as(usize, cap))));
        const tail: [*c]be.rvn_vk_texture_t = g_vk.textures + @as(usize, g_vk.texture_cap);
        @memset(std.mem.sliceAsBytes(tail[0 .. @as(usize, cap) - @as(usize, g_vk.texture_cap)]), 0);
        g_vk.texture_cap = cap;
    }
    return &g_vk.textures[index];
}

// The GPU may still be using a texture: nothing of it changes before it is idle.
fn rvn_vk_texture_quiesce() void {
    rvn_vk_uploads_flush();
    be.rvn_vk_wait_frames();
}

export fn rvn_vk_texture_create(id: raven.Rid, desc: [*c]const raven.RTextureDesc, pixels: ?*const anyopaque) c_int {
    const texture = rvn_vk_texture_slot(id);
    if (texture.*.used != raven.R_FALSE) {
        rvn_vk_texture_quiesce();
        rvn_vk_texture_release(texture);
    }
    if (rvn_vk_texture_build(texture, desc.*.width, desc.*.height, desc.*.format, desc.*.filter, raven.R_FALSE) == raven.R_FALSE) return raven.R_FALSE;
    rvn_vk_texture_write(texture, 0, 0, desc.*.width, desc.*.height, pixels);
    return raven.R_TRUE;
}

export fn rvn_vk_texture_update(id: raven.Rid, x: raven.Ruint, y: raven.Ruint, width: raven.Ruint, height: raven.Ruint, pixels: ?*const anyopaque) void {
    const texture = rvn_vk_texture_find(id);
    if (texture == null or texture.*.wrapped != raven.R_FALSE or pixels == null) return;
    rvn_vk_texture_write(texture, x, y, width, height, pixels);
}

export fn rvn_vk_texture_set_filter(id: raven.Rid, filter: raven.RFilterType) void {
    const texture = rvn_vk_texture_find(id);
    if (texture == null or texture.*.filter == filter) return;
    texture.*.filter = filter;
    // a descriptor set must not change while a submitted frame uses it
    rvn_vk_texture_quiesce();
    be.rvn_vk_set_write(texture.*.set, texture.*.view, rvn_vk_texture_sampler(texture));
}

export fn rvn_vk_texture_destroy(id: raven.Rid) void {
    const texture = rvn_vk_texture_find(id);
    if (texture == null) return;
    rvn_vk_texture_quiesce();
    rvn_vk_texture_release(texture);
}

// ---------------------------------------------------------------------------
//  Images of the application
// ---------------------------------------------------------------------------

export fn rvn_vk_texture_wrap(id: raven.Rid, view: vk.VkImageView, sampler: vk.VkSampler, width: u32, height: u32) c_int {
    const texture = rvn_vk_texture_slot(id);
    if (texture.*.used != raven.R_FALSE and texture.*.wrapped == raven.R_FALSE) {
        rvn_vk_texture_quiesce();
        rvn_vk_texture_release(texture);
    }
    if (texture.*.used == raven.R_FALSE) {
        texture.* = std.mem.zeroes(be.rvn_vk_texture_t); // memset(texture, 0, sizeof(*texture));
        if (be.rvn_vk_set_allocate(&texture.*.set, &texture.*.pool) == raven.R_FALSE) return raven.R_FALSE;
        texture.*.used = raven.R_TRUE;
        texture.*.wrapped = raven.R_TRUE;
        texture.*.format = raven.R_TEXTURE_RGBA8;
        texture.*.filter = raven.R_FILTER_LINEAR;
        texture.*.initialized = raven.R_TRUE;
    } else {
        // replacing the view: frames in flight still read the previous one
        rvn_vk_texture_quiesce();
    }
    texture.*.view = view;
    texture.*.sampler = sampler;
    texture.*.width = width;
    texture.*.height = height;
    be.rvn_vk_set_write(texture.*.set, view, rvn_vk_texture_sampler(texture));
    return raven.R_TRUE;
}

export fn rvn_vk_texture_create_shared(id: raven.Rid, width: u32, height: u32) c_int {
    if (g_vk.can_share == raven.R_FALSE) return raven.R_FALSE;
    const texture = rvn_vk_texture_slot(id);
    if (texture.*.used != raven.R_FALSE) {
        rvn_vk_texture_quiesce();
        rvn_vk_texture_release(texture);
    }
    if (rvn_vk_texture_build(texture, width, height, raven.R_TEXTURE_RGBA8, raven.R_FILTER_LINEAR, raven.R_TRUE) == raven.R_FALSE) return raven.R_FALSE;
    rvn_vk_texture_write(texture, 0, 0, width, height, null);
    return raven.R_TRUE;
}

export fn rvn_vk_texture_export(id: raven.Rid, handle: [*c]isize, allocation_size: [*c]u64) c_int {
    const texture = rvn_vk_texture_find(id);
    // VkMemoryGetWin32HandleKHR has the same layout: only the type differs
    var result: vk.VkResult = undefined;

    if (texture == null or texture.*.shared == raven.R_FALSE) return raven.R_FALSE;
    var info = std.mem.zeroes(vk.VkMemoryGetFdInfoKHR);
    info.memory = texture.*.memory;
    if (builtin.os.tag == .windows) {
        var win32_handle: ?*anyopaque = null;
        if (rvn_vk.GetMemoryWin32HandleKHR == null) return raven.R_FALSE;
        info.sType = vk.VK_STRUCTURE_TYPE_MEMORY_GET_WIN32_HANDLE_INFO_KHR;
        info.handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
        result = rvn_vk.GetMemoryWin32HandleKHR.?(g_vk.device, &info, @ptrCast(&win32_handle));
        handle.* = @bitCast(@intFromPtr(win32_handle));
    } else {
        var fd: c_int = -1;
        if (rvn_vk.GetMemoryFdKHR == null) return raven.R_FALSE;
        info.sType = vk.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
        info.handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_FD_BIT;
        result = rvn_vk.GetMemoryFdKHR.?(g_vk.device, &info, &fd);
        handle.* = @as(isize, fd);
    }
    if (be.rvn_vk_failed(result, "exporting the texture memory") != raven.R_FALSE) return raven.R_FALSE;
    allocation_size.* = @as(u64, texture.*.allocation_size);
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Module
// ---------------------------------------------------------------------------

export fn rvn_vk_textures_init() c_int {
    var pool = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
    var allocation = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
    var fence = std.mem.zeroes(vk.VkFenceCreateInfo);
    const white = [_]u8{ 255, 255, 255, 255 }; // static const uint8_t white[4]

    pool.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = g_vk.queue_family;
    if (be.rvn_vk_failed(rvn_vk.CreateCommandPool.?(g_vk.device, &pool, null, &g_vk.upload_pool), "vkCreateCommandPool") != raven.R_FALSE) return raven.R_FALSE;

    allocation.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocation.commandPool = g_vk.upload_pool;
    allocation.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocation.commandBufferCount = 1;
    if (be.rvn_vk_failed(rvn_vk.AllocateCommandBuffers.?(g_vk.device, &allocation, &g_vk.upload_commands),
        "vkAllocateCommandBuffers") != raven.R_FALSE) return raven.R_FALSE;

    fence.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (be.rvn_vk_failed(rvn_vk.CreateFence.?(g_vk.device, &fence, null, &g_vk.upload_fence), "vkCreateFence") != raven.R_FALSE) return raven.R_FALSE;

    if (be.rvn_vk_buffer_create(&g_vk.staging, RVN_VK_STAGING_SIZE, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT) == raven.R_FALSE) return raven.R_FALSE;

    if (rvn_vk_texture_build(&g_vk.white, 1, 1, raven.R_TEXTURE_RGBA8, raven.R_FILTER_NEAREST, raven.R_FALSE) == raven.R_FALSE) return raven.R_FALSE;
    rvn_vk_texture_write(&g_vk.white, 0, 0, 1, 1, &white);
    // what glass shows in a window that has no backdrop
    if (be.rvn_vk_backdrop_set_create(&g_vk.backdrop_default, g_vk.white.view, g_vk.white.view) == raven.R_FALSE) return raven.R_FALSE;
    return raven.R_TRUE;
}

export fn rvn_vk_textures_shutdown() void {
    var i: u32 = undefined;
    if (g_vk.device == null) return;
    if (g_vk.upload_commands != null) rvn_vk_uploads_flush();
    i = 0;
    while (i < g_vk.texture_cap) : (i += 1) {
        if (g_vk.textures[i].used != raven.R_FALSE) rvn_vk_texture_release(&g_vk.textures[i]);
    }
    base.rvn_free(g_vk.textures);
    g_vk.textures = null;
    g_vk.texture_cap = 0;
    if (g_vk.white.used != raven.R_FALSE) rvn_vk_texture_release(&g_vk.white);
    be.rvn_vk_buffer_destroy(&g_vk.staging);
    if (g_vk.upload_fence != null) rvn_vk.DestroyFence.?(g_vk.device, g_vk.upload_fence, null);
    if (g_vk.upload_pool != null) rvn_vk.DestroyCommandPool.?(g_vk.device, g_vk.upload_pool, null);
    g_vk.upload_fence = null;
    g_vk.upload_pool = null;
    g_vk.upload_commands = null;
    g_vk.upload_open = raven.R_FALSE;
    g_vk.staging_used = 0;
}
