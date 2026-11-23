// Translated to Zig from vendor/raven/src/render/vulkan/vk_glass.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_glass.c
// Backdrop of the glass primitives.
//
// Glass shows, bent and frosted, what is behind it. A fragment shader cannot
// read the image it is drawing into, so a window that contains glass is
// rendered differently:
//
//   1. the frame is drawn into an offscreen image, the *scene*;
//   2. at each R_DRAW_BACKDROP command, drawing pauses and the scene is
//      copied into two textures: a half-size copy (the "sharp" backdrop)
//      and a blurred one, built by halving the image a few times and
//      enlarging it back (dual filtering: a wide blur for a handful of
//      texture reads per pixel);
//   3. drawing continues in the scene; glass instances sample the two
//      backdrop textures (set 1 of the UI pipeline);
//   4. the finished scene is drawn into the swapchain image.
//
// Windows without glass never come here and render straight to the
// swapchain, as before.

const std = @import("std");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const be = @import("vk_backend_h.zig");
const vk = be.vk;
const loader = be.loader;

const UINT32_MAX: u32 = std.math.maxInt(u32);

// ---------------------------------------------------------------------------
//  Targets
// ---------------------------------------------------------------------------

fn rvn_vk_target_destroy(target: [*c]be.rvn_vk_target_t) void {
    be.rvn_vk_set_free(target.*.set, target.*.pool);
    if (target.*.framebuffer != null) loader.rvn_vk.DestroyFramebuffer.?(be.g_vk.device, target.*.framebuffer, null);
    if (target.*.view != null) loader.rvn_vk.DestroyImageView.?(be.g_vk.device, target.*.view, null);
    if (target.*.image != null) loader.rvn_vk.DestroyImage.?(be.g_vk.device, target.*.image, null);
    if (target.*.memory != null) loader.rvn_vk.FreeMemory.?(be.g_vk.device, target.*.memory, null);
    target.* = std.mem.zeroes(be.rvn_vk_target_t); // memset(target, 0, sizeof(*target));
}

fn rvn_vk_target_create(target: [*c]be.rvn_vk_target_t, pass: [*c]const be.rvn_vk_pass_t, width: u32, height: u32) c_int {
    target.* = std.mem.zeroes(be.rvn_vk_target_t); // memset(target, 0, sizeof(*target));
    target.*.width = width;
    target.*.height = height;

    failed: {
        var image = std.mem.zeroes(vk.VkImageCreateInfo);
        image.sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image.imageType = vk.VK_IMAGE_TYPE_2D;
        // the format of the swapchain: the same pipelines draw into both
        image.format = pass.*.format;
        image.extent.width = width;
        image.extent.height = height;
        image.extent.depth = 1;
        image.mipLevels = 1;
        image.arrayLayers = 1;
        image.samples = vk.VK_SAMPLE_COUNT_1_BIT;
        image.tiling = vk.VK_IMAGE_TILING_OPTIMAL;
        image.usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT;
        image.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
        image.initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
        if (be.rvn_vk_failed(loader.rvn_vk.CreateImage.?(be.g_vk.device, &image, null, &target.*.image), "vkCreateImage") != 0) break :failed;

        var requirements: vk.VkMemoryRequirements = undefined;
        loader.rvn_vk.GetImageMemoryRequirements.?(be.g_vk.device, target.*.image, &requirements);
        var allocation = std.mem.zeroes(vk.VkMemoryAllocateInfo);
        allocation.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size;
        allocation.memoryTypeIndex = be.rvn_vk_find_memory_type(requirements.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        if (allocation.memoryTypeIndex == UINT32_MAX) allocation.memoryTypeIndex = be.rvn_vk_find_memory_type(requirements.memoryTypeBits, 0);
        if (allocation.memoryTypeIndex == UINT32_MAX or
            be.rvn_vk_failed(loader.rvn_vk.AllocateMemory.?(be.g_vk.device, &allocation, null, &target.*.memory), "vkAllocateMemory") != 0 or
            be.rvn_vk_failed(loader.rvn_vk.BindImageMemory.?(be.g_vk.device, target.*.image, target.*.memory, 0), "vkBindImageMemory") != 0) break :failed;

        var view = std.mem.zeroes(vk.VkImageViewCreateInfo);
        view.sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view.image = target.*.image;
        view.viewType = vk.VK_IMAGE_VIEW_TYPE_2D;
        view.format = image.format;
        view.subresourceRange.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
        view.subresourceRange.levelCount = 1;
        view.subresourceRange.layerCount = 1;
        if (be.rvn_vk_failed(loader.rvn_vk.CreateImageView.?(be.g_vk.device, &view, null, &target.*.view), "vkCreateImageView") != 0) break :failed;

        var framebuffer = std.mem.zeroes(vk.VkFramebufferCreateInfo);
        framebuffer.sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        // the offscreen passes are compatible with each other: any of them will do here
        framebuffer.renderPass = pass.*.blur_pass;
        framebuffer.attachmentCount = 1;
        framebuffer.pAttachments = &target.*.view;
        framebuffer.width = width;
        framebuffer.height = height;
        framebuffer.layers = 1;
        if (be.rvn_vk_failed(loader.rvn_vk.CreateFramebuffer.?(be.g_vk.device, &framebuffer, null, &target.*.framebuffer), "vkCreateFramebuffer") != 0) break :failed;

        if (be.rvn_vk_set_allocate(&target.*.set, &target.*.pool) == 0) break :failed;
        be.rvn_vk_set_write(target.*.set, target.*.view, be.g_vk.sampler_linear);
        return raven.R_TRUE;
    }

    rvn_vk_target_destroy(target);
    return raven.R_FALSE;
}

export fn rvn_vk_glass_release(surface: [*c]be.rvn_vk_surface_t) void {
    var i: u32 = undefined;
    be.rvn_vk_backdrop_set_destroy(surface.*.backdrop_set);
    surface.*.backdrop_set = null; // VK_NULL_HANDLE
    rvn_vk_target_destroy(&surface.*.scene);
    i = 0;
    while (i < be.RVN_VK_BLUR_LEVELS) : (i += 1) rvn_vk_target_destroy(&surface.*.down[i]);
    i = 0;
    while (i < be.RVN_VK_BLUR_LEVELS - 1) : (i += 1) rvn_vk_target_destroy(&surface.*.up[i]);
    surface.*.glass_ready = raven.R_FALSE;
    surface.*.glass_filled = raven.R_FALSE;
}

export fn rvn_vk_glass_prepare(surface: [*c]be.rvn_vk_surface_t) c_int {
    var i: u32 = undefined;

    if (surface.*.glass_ready != 0 and surface.*.scene.width == surface.*.extent.width and surface.*.scene.height == surface.*.extent.height) {
        return raven.R_TRUE;
    }
    if (surface.*.glass_ready != 0) {
        // (the swapchain was recreated: the frames that used the old images are finished)
        rvn_vk_glass_release(surface);
    }

    failed: {
        if (rvn_vk_target_create(&surface.*.scene, surface.*.pass, surface.*.extent.width, surface.*.extent.height) == 0) break :failed;
        i = 0;
        while (i < be.RVN_VK_BLUR_LEVELS) : (i += 1) {
            const width = base.rvn_maxu(surface.*.extent.width >> @intCast(i + 1), 1);
            const height = base.rvn_maxu(surface.*.extent.height >> @intCast(i + 1), 1);
            if (rvn_vk_target_create(&surface.*.down[i], surface.*.pass, width, height) == 0) break :failed;
            // enlarged copies exist for every size but the smallest
            if (i + 1 < be.RVN_VK_BLUR_LEVELS and rvn_vk_target_create(&surface.*.up[i], surface.*.pass, width, height) == 0) break :failed;
        }
        if (be.rvn_vk_backdrop_set_create(&surface.*.backdrop_set, surface.*.down[0].view, surface.*.up[0].view) == 0) break :failed;
        surface.*.glass_ready = raven.R_TRUE;
        surface.*.glass_filled = raven.R_FALSE;
        return raven.R_TRUE;
    }

    rvn_vk_glass_release(surface);
    return raven.R_FALSE;
}

// ---------------------------------------------------------------------------
//  Passes
// ---------------------------------------------------------------------------

fn rvn_vk_set_full_viewport(commands: vk.VkCommandBuffer, width: u32, height: u32) void {
    var viewport: vk.VkViewport = undefined;
    var scissor: vk.VkRect2D = undefined;
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(width);
    viewport.height = @floatFromInt(height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    scissor.offset.x = 0;
    scissor.offset.y = 0;
    scissor.extent.width = width;
    scissor.extent.height = height;
    loader.rvn_vk.CmdSetViewport.?(commands, 0, 1, &viewport);
    loader.rvn_vk.CmdSetScissor.?(commands, 0, 1, &scissor);
}

export fn rvn_vk_glass_begin_scene(commands: vk.VkCommandBuffer, surface: [*c]const be.rvn_vk_surface_t, clear: [*c]const vk.VkClearValue) void {
    var pass = std.mem.zeroes(vk.VkRenderPassBeginInfo);
    pass.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    pass.renderPass = if (clear != null) surface.*.pass.*.scene_clear_pass else surface.*.pass.*.scene_load_pass;
    pass.framebuffer = surface.*.scene.framebuffer;
    pass.renderArea.extent.width = surface.*.scene.width;
    pass.renderArea.extent.height = surface.*.scene.height;
    pass.clearValueCount = if (clear != null) 1 else 0;
    pass.pClearValues = clear;
    loader.rvn_vk.CmdBeginRenderPass.?(commands, &pass, vk.VK_SUBPASS_CONTENTS_INLINE);
}

// Filters `source` into `target`: all of it, or only `area` (pixels of the
// target), the rest keeping its content. mode: 0 = reduce, 1 = enlarge (blur.frag).
fn rvn_vk_glass_filter(commands: vk.VkCommandBuffer, surface: [*c]const be.rvn_vk_surface_t, source: [*c]const be.rvn_vk_target_t,
    target: [*c]const be.rvn_vk_target_t, mode: c_int, spread: f32, area: [*c]const vk.VkRect2D) void {

    var pass = std.mem.zeroes(vk.VkRenderPassBeginInfo);
    var constants: extern struct {
        step: [2]f32,
        mode: i32,
    } = undefined;

    pass.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    pass.renderPass = if (area != null) surface.*.pass.*.blur_load_pass else surface.*.pass.*.blur_pass;
    pass.framebuffer = target.*.framebuffer;
    if (area != null) {
        pass.renderArea = area.*;
    } else {
        pass.renderArea.extent.width = target.*.width;
        pass.renderArea.extent.height = target.*.height;
    }
    loader.rvn_vk.CmdBeginRenderPass.?(commands, &pass, vk.VK_SUBPASS_CONTENTS_INLINE);

    // offsets are in texels of the source: a whole one when reducing, halves when enlarging
    constants.step[0] = spread * (if (mode == 0) @as(f32, 1.0) else 0.5) / @as(f32, @floatFromInt(source.*.width));
    constants.step[1] = spread * (if (mode == 0) @as(f32, 1.0) else 0.5) / @as(f32, @floatFromInt(source.*.height));
    constants.mode = @intCast(mode);

    loader.rvn_vk.CmdBindPipeline.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, surface.*.pass.*.blur_pipeline);
    rvn_vk_set_full_viewport(commands, target.*.width, target.*.height);
    if (area != null) loader.rvn_vk.CmdSetScissor.?(commands, 0, 1, area);
    loader.rvn_vk.CmdBindDescriptorSets.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, be.g_vk.blur_layout, 0, 1, &source.*.set, 0, null);
    loader.rvn_vk.CmdPushConstants.?(commands, be.g_vk.blur_layout, vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(f32) * 2 + @sizeOf(i32), &constants);
    loader.rvn_vk.CmdDraw.?(commands, 3, 1, 0, 0);
    loader.rvn_vk.CmdEndRenderPass.?(commands);
}

// The part of `target` that shows the pixels x0..x1, y0..y1 of the frame. R_FALSE: nothing.
fn rvn_vk_glass_area(surface: [*c]const be.rvn_vk_surface_t, target: [*c]const be.rvn_vk_target_t,
    x0: f32, y0: f32, x1: f32, y1: f32, area: [*c]vk.VkRect2D) c_int {

    const fx = @as(f32, @floatFromInt(target.*.width)) / @as(f32, @floatFromInt(surface.*.extent.width));
    const fy = @as(f32, @floatFromInt(target.*.height)) / @as(f32, @floatFromInt(surface.*.extent.height));
    const ax0: c_int = base.rvn_maxi(@intFromFloat(@floor(x0 * fx)), 0);
    const ay0: c_int = base.rvn_maxi(@intFromFloat(@floor(y0 * fy)), 0);
    const ax1: c_int = base.rvn_mini(@intFromFloat(@ceil(x1 * fx)), @intCast(target.*.width));
    const ay1: c_int = base.rvn_mini(@intFromFloat(@ceil(y1 * fy)), @intCast(target.*.height));
    if (ax1 <= ax0 or ay1 <= ay0) return raven.R_FALSE;
    area.*.offset.x = @intCast(ax0);
    area.*.offset.y = @intCast(ay0);
    area.*.extent.width = @intCast(ax1 - ax0);
    area.*.extent.height = @intCast(ay1 - ay0);
    return raven.R_TRUE;
}

export fn rvn_vk_glass_capture(commands: vk.VkCommandBuffer, surface: [*c]be.rvn_vk_surface_t, scale: f32, rect: [*c]const c_int) void {
    // the blur is sized in pixels: follow the scale of the window, within reason
    const spread = base.rvn_clampf(0.5 + scale * 0.5, 1.0, 2.5);
    // A pixel of the blurred image depends on the frame up to about 18 x
    // spread pixels away (1 + 2 + 4 + 8 + 4, minus the first step that does
    // not spread), plus the width of the bilinear samples: refreshing an
    // area means filtering that much around it.
    const margin = 18.0 * spread + 20.0;
    var x0 = @as(f32, @floatFromInt(rect[0])) - margin;
    var y0 = @as(f32, @floatFromInt(rect[1])) - margin;
    var x1 = @as(f32, @floatFromInt(rect[0] + rect[2])) + margin;
    var y1 = @as(f32, @floatFromInt(rect[1] + rect[3])) + margin;
    const width = @as(f32, @floatFromInt(surface.*.extent.width));
    const height = @as(f32, @floatFromInt(surface.*.extent.height));
    var i: c_int = undefined;

    if (rect[2] <= 0 or rect[3] <= 0) {
        // no area given: everything
        x0 = 0.0;
        y0 = 0.0;
        x1 = width;
        y1 = height;
    }
    x0 = base.rvn_maxf(x0, 0.0);
    y0 = base.rvn_maxf(y0, 0.0);
    x1 = base.rvn_minf(x1, width);
    y1 = base.rvn_minf(y1, height);
    if (x1 <= x0 or y1 <= y0) return;
    // an area is only worth its bookkeeping when it is clearly smaller than the frame,
    // and only possible once the images hold a whole capture
    const partial = surface.*.glass_filled != 0 and (x1 - x0) * (y1 - y0) < width * height * 0.8;

    // scene -> 1/2 -> 1/4 -> 1/8: down[0] doubles as the sharp backdrop
    i = 0;
    while (i < be.RVN_VK_BLUR_LEVELS) : (i += 1) {
        const source: [*c]const be.rvn_vk_target_t = if (i == 0) &surface.*.scene else &surface.*.down[@intCast(i - 1)];
        var area: vk.VkRect2D = undefined;
        if (partial and rvn_vk_glass_area(surface, &surface.*.down[@intCast(i)], x0, y0, x1, y1, &area) == 0) continue;
        rvn_vk_glass_filter(commands, surface, source, &surface.*.down[@intCast(i)], 0, if (i == 0) 1.0 else spread, if (partial) &area else null);
    }
    // ... and back up to half size: up[0] is the blurred backdrop
    i = be.RVN_VK_BLUR_LEVELS - 2;
    while (i >= 0) : (i -= 1) {
        const source: [*c]const be.rvn_vk_target_t = if (i == be.RVN_VK_BLUR_LEVELS - 2) &surface.*.down[be.RVN_VK_BLUR_LEVELS - 1] else &surface.*.up[@intCast(i + 1)];
        var area: vk.VkRect2D = undefined;
        if (partial and rvn_vk_glass_area(surface, &surface.*.up[@intCast(i)], x0, y0, x1, y1, &area) == 0) continue;
        rvn_vk_glass_filter(commands, surface, source, &surface.*.up[@intCast(i)], 1, spread, if (partial) &area else null);
    }
    surface.*.glass_filled = raven.R_TRUE;
}

export fn rvn_vk_glass_present_scene(commands: vk.VkCommandBuffer, surface: [*c]const be.rvn_vk_surface_t) void {
    var constants: extern struct {
        step: [2]f32,
        mode: i32,
    } = undefined;
    constants.step[0] = 0.0;
    constants.step[1] = 0.0;
    constants.mode = 2;
    loader.rvn_vk.CmdBindPipeline.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, surface.*.pass.*.blur_pipeline);
    rvn_vk_set_full_viewport(commands, surface.*.extent.width, surface.*.extent.height);
    loader.rvn_vk.CmdBindDescriptorSets.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, be.g_vk.blur_layout, 0, 1, &surface.*.scene.set, 0, null);
    loader.rvn_vk.CmdPushConstants.?(commands, be.g_vk.blur_layout, vk.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(f32) * 2 + @sizeOf(i32), &constants);
    loader.rvn_vk.CmdDraw.?(commands, 3, 1, 0, 0);
}
