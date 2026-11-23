// Translated to Zig from vendor/raven/src/render/vulkan/vk_frame.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_frame.c
// Records, submits and presents one frame of one window.
//
//   1. wait for the frame slot (two frames can be on the GPU per window)
//   2. acquire a swapchain image, recreating the swapchain when it is stale
//   3. copy the instances into the mapped vertex buffer of the slot
//   4. one render pass: one instanced draw per command, viewport callbacks
//   5. submit, present
//
// A frame that contains glass is drawn into an offscreen image instead, with
// pauses to capture the backdrop, and then copied to the swapchain image
// (vk_glass.c).

const std = @import("std");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const libc = @import("../../sys/libc.zig");
const be = @import("vk_backend_h.zig");
const vk = be.vk;
const loader = be.loader;

/// Smallest instance buffer: 1024 instances.
const RVN_VK_MIN_INSTANCE_BYTES: vk.VkDeviceSize = 1024 * @sizeOf(raven.RDrawInstance);

const UINT64_MAX: u64 = std.math.maxInt(u64);

// ---------------------------------------------------------------------------
//  State of the UI pipeline
// ---------------------------------------------------------------------------

// Binds everything the UI draws need. Also used to restore the state after a viewport callback.
fn rvn_vk_bind_ui_state(commands: vk.VkCommandBuffer, surface: [*c]const be.rvn_vk_surface_t, frame: [*c]const be.rvn_vk_frame_t, data: [*c]const raven.RDrawData, glass: c_int) void {
    const backdrop: vk.VkDescriptorSet = if (glass != 0) surface.*.backdrop_set else be.g_vk.backdrop_default;
    var viewport: vk.VkViewport = undefined;
    var scissor: vk.VkRect2D = undefined;
    var transform: [8]f32 = undefined;
    var offset: vk.VkDeviceSize = 0;

    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(surface.*.extent.width);
    viewport.height = @floatFromInt(surface.*.extent.height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    scissor.offset.x = 0;
    scissor.offset.y = 0;
    scissor.extent = surface.*.extent;

    // pixels, origin top-left -> clip space; Vulkan's Y axis already points down
    transform[0] = 2.0 / @as(f32, @floatFromInt(surface.*.extent.width));
    transform[1] = 2.0 / @as(f32, @floatFromInt(surface.*.extent.height));
    transform[2] = -1.0;
    transform[3] = -1.0;
    // where the pointer is, for the effects
    transform[4] = data.*.pointer[0];
    transform[5] = data.*.pointer[1];
    transform[6] = 0.0;
    transform[7] = 0.0;

    _ = loader.rvn_vk.CmdBindPipeline.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, surface.*.pass.*.pipeline);
    loader.rvn_vk.CmdSetViewport.?(commands, 0, 1, &viewport);
    loader.rvn_vk.CmdSetScissor.?(commands, 0, 1, &scissor);
    loader.rvn_vk.CmdPushConstants.?(commands, be.g_vk.pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(transform)), &transform);
    if (frame.*.instances.buffer != null) loader.rvn_vk.CmdBindVertexBuffers.?(commands, 0, 1, &frame.*.instances.buffer, &offset);
    // set 1: what the glass primitives see through
    loader.rvn_vk.CmdBindDescriptorSets.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, be.g_vk.pipeline_layout, 1, 1, &backdrop, 0, null);
}

// Calls the application with the viewport and scissor set to the widget.
fn rvn_vk_run_callback(commands: vk.VkCommandBuffer, surface: [*c]const be.rvn_vk_surface_t, data: [*c]const raven.RDrawData, command: [*c]const raven.RDrawCommand) void {
    var info: raven.RViewportDrawInfo = undefined;
    var viewport: vk.VkViewport = undefined;
    var scissor: vk.VkRect2D = undefined;
    const x0 = base.rvn_maxi(command.*.clip[0], 0);
    const y0 = base.rvn_maxi(command.*.clip[1], 0);
    const x1 = base.rvn_mini(command.*.clip[0] + command.*.clip[2], @bitCast(surface.*.extent.width));
    const y1 = base.rvn_mini(command.*.clip[1] + command.*.clip[3], @bitCast(surface.*.extent.height));

    if (command.*.callback == null or x1 <= x0 or y1 <= y0 or command.*.rect[2] <= 0 or command.*.rect[3] <= 0) return;

    viewport.x = @floatFromInt(command.*.rect[0]);
    viewport.y = @floatFromInt(command.*.rect[1]);
    viewport.width = @floatFromInt(command.*.rect[2]);
    viewport.height = @floatFromInt(command.*.rect[3]);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    scissor.offset.x = x0;
    scissor.offset.y = y0;
    scissor.extent.width = @intCast(x1 - x0);
    scissor.extent.height = @intCast(y1 - y0);
    loader.rvn_vk.CmdSetViewport.?(commands, 0, 1, &viewport);
    loader.rvn_vk.CmdSetScissor.?(commands, 0, 1, &scissor);

    info = std.mem.zeroes(raven.RViewportDrawInfo);
    info.backend = raven.R_BACKEND_VULKAN;
    info.viewport = command.*.viewport;
    info.window = data.*.window;
    info.x = command.*.rect[0];
    info.y = command.*.rect[1];
    info.width = command.*.rect[2];
    info.height = command.*.rect[3];
    info.clip_x = x0;
    info.clip_y = y0;
    info.clip_width = x1 - x0;
    info.clip_height = y1 - y0;
    info.framebuffer_width = @bitCast(surface.*.extent.width);
    info.framebuffer_height = @bitCast(surface.*.extent.height);
    info.frame_index = data.*.frame_index;
    info.command_buffer = commands;
    info.render_pass = surface.*.pass.*.render_pass;
    info.color_format = surface.*.format.format;
    command.*.callback.?(&info, command.*.user_data);
}

// Records the commands of the frame inside the render pass already begun.
// With `glass`, that pass is the offscreen scene: each backdrop command ends
// it, captures the backdrop and begins it again.
fn rvn_vk_record_commands(commands: vk.VkCommandBuffer, surface: [*c]be.rvn_vk_surface_t, frame: [*c]const be.rvn_vk_frame_t, data: [*c]const raven.RDrawData, glass: c_int) void {
    var bound: vk.VkDescriptorSet = null;
    var i: u32 = undefined;

    rvn_vk_bind_ui_state(commands, surface, frame, data, glass);
    i = 0;
    while (i < data.*.command_count) : (i += 1) {
        const command: [*c]const raven.RDrawCommand = &data.*.commands[i];
        if (command.*.type == raven.R_DRAW_CALLBACK) {
            rvn_vk_run_callback(commands, surface, data, command);
            // the application bound its own pipeline: start again from a known state
            rvn_vk_bind_ui_state(commands, surface, frame, data, glass);
            bound = null;
        } else if (command.*.type == raven.R_DRAW_BACKDROP) {
            if (glass == 0) continue;
            loader.rvn_vk.CmdEndRenderPass.?(commands);
            be.rvn_vk_glass_capture(commands, surface, data.*.scale, &command.*.rect);
            be.rvn_vk_glass_begin_scene(commands, surface, null);
            rvn_vk_bind_ui_state(commands, surface, frame, data, glass);
            bound = null;
        } else if (command.*.type == raven.R_DRAW_SHADER) {
            const texture: [*c]const be.rvn_vk_texture_t = be.rvn_vk_texture_find(command.*.texture);
            const set: vk.VkDescriptorSet = if (texture != null and texture.*.initialized != 0) texture.*.set else be.g_vk.white.set;
            const pipeline: vk.VkPipeline = be.rvn_vk_shader_pipeline(command.*.shader, surface.*.pass);
            if (pipeline == null or command.*.instance_count == 0 or command.*.first_instance +% command.*.instance_count > data.*.instance_count) continue;
            if (set != bound) {
                loader.rvn_vk.CmdBindDescriptorSets.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, be.g_vk.pipeline_layout, 0, 1, &set, 0, null);
                bound = set;
            }
            // (same layout as the UI: the sets and the push constants stay bound)
            loader.rvn_vk.CmdBindPipeline.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            loader.rvn_vk.CmdDraw.?(commands, 4, command.*.instance_count, 0, command.*.first_instance);
            loader.rvn_vk.CmdBindPipeline.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, surface.*.pass.*.pipeline);
        } else if (command.*.type == raven.R_DRAW_INSTANCES or command.*.type == raven.R_DRAW_ERASE) {
            const texture: [*c]const be.rvn_vk_texture_t = be.rvn_vk_texture_find(command.*.texture);
            const set: vk.VkDescriptorSet = if (texture != null and texture.*.initialized != 0) texture.*.set else be.g_vk.white.set;
            if (command.*.instance_count == 0 or command.*.first_instance +% command.*.instance_count > data.*.instance_count) continue;
            if (set != bound) {
                loader.rvn_vk.CmdBindDescriptorSets.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, be.g_vk.pipeline_layout, 0, 1, &set, 0, null);
                bound = set;
            }
            // (the two pipelines share their layout: what is bound stays bound)
            if (command.*.type == raven.R_DRAW_ERASE) loader.rvn_vk.CmdBindPipeline.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, surface.*.pass.*.erase_pipeline);
            // four vertices generated by the vertex shader, one instance per primitive
            loader.rvn_vk.CmdDraw.?(commands, 4, command.*.instance_count, 0, command.*.first_instance);
            if (command.*.type == raven.R_DRAW_ERASE) loader.rvn_vk.CmdBindPipeline.?(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, surface.*.pass.*.pipeline);
        }
    }
}

// R_TRUE when the frame contains glass and the window can render it.
fn rvn_vk_frame_uses_glass(surface: [*c]be.rvn_vk_surface_t, data: [*c]const raven.RDrawData) c_int {
    var i: u32 = 0;
    while (i < data.*.command_count) : (i += 1) {
        if (data.*.commands[i].type == raven.R_DRAW_BACKDROP) return be.rvn_vk_glass_prepare(surface);
    }
    return raven.R_FALSE;
}

// ---------------------------------------------------------------------------
//  Capture
// ---------------------------------------------------------------------------

fn rvn_vk_capture_barrier(commands: vk.VkCommandBuffer, image: vk.VkImage, from: vk.VkImageLayout, to: vk.VkImageLayout, source_access: vk.VkAccessFlags, target_access: vk.VkAccessFlags, source_stage: vk.VkPipelineStageFlags, target_stage: vk.VkPipelineStageFlags) void {
    var barrier: vk.VkImageMemoryBarrier = undefined;
    barrier = std.mem.zeroes(vk.VkImageMemoryBarrier);
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
    loader.rvn_vk.CmdPipelineBarrier.?(commands, source_stage, target_stage, 0, 0, null, 0, null, 1, &barrier);
}

// Records the copy of the top-left `width` x `height` pixels of the rendered image into a host-visible buffer.
fn rvn_vk_record_capture(commands: vk.VkCommandBuffer, image: vk.VkImage, target: vk.VkBuffer, width: u32, height: u32) void {
    var region: vk.VkBufferImageCopy = undefined;

    rvn_vk_capture_barrier(commands, image, vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, vk.VK_ACCESS_TRANSFER_READ_BIT, vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, vk.VK_PIPELINE_STAGE_TRANSFER_BIT);
    region = std.mem.zeroes(vk.VkBufferImageCopy);
    region.imageSubresource.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageExtent.width = width;
    region.imageExtent.height = height;
    region.imageExtent.depth = 1;
    loader.rvn_vk.CmdCopyImageToBuffer.?(commands, image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, target, 1, &region);
    rvn_vk_capture_barrier(commands, image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, vk.VK_ACCESS_TRANSFER_READ_BIT, 0, vk.VK_PIPELINE_STAGE_TRANSFER_BIT, vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT);
}

// Converts the read-back image to tightly packed RGBA8.
fn rvn_vk_finish_capture(surface: [*c]const be.rvn_vk_surface_t, source: [*c]const u8, width: u32, height: u32, capture: [*c]raven.RCapture) void {
    const count: usize = @as(usize, width) *% @as(usize, height);
    var i: usize = undefined;
    const swap = surface.*.format.format == vk.VK_FORMAT_B8G8R8A8_UNORM or surface.*.format.format == vk.VK_FORMAT_B8G8R8A8_SRGB;
    const pixels: [*c]u8 = raven.Rpixels_alloc(count *% 4);

    i = 0;
    while (i < count) : (i += 1) {
        pixels[i *% 4 +% 0] = source[i *% 4 +% (if (swap) @as(usize, 2) else @as(usize, 0))];
        pixels[i *% 4 +% 1] = source[i *% 4 +% 1];
        pixels[i *% 4 +% 2] = source[i *% 4 +% (if (swap) @as(usize, 0) else @as(usize, 2))];
        // a window is opaque whatever the alpha left in the swapchain, unless it is one that is seen through
        pixels[i *% 4 +% 3] = if (surface.*.transparent != 0) source[i *% 4 +% 3] else 255;
    }
    capture.*.pixels = pixels;
    capture.*.width = @bitCast(width);
    capture.*.height = @bitCast(height);
}

fn rvn_vk_capture_supported(surface: [*c]const be.rvn_vk_surface_t) c_int {
    switch (surface.*.format.format) {
        vk.VK_FORMAT_B8G8R8A8_UNORM,
        vk.VK_FORMAT_B8G8R8A8_SRGB,
        vk.VK_FORMAT_R8G8B8A8_UNORM,
        vk.VK_FORMAT_R8G8B8A8_SRGB,
        => return surface.*.can_capture,
        else => return raven.R_FALSE,
    }
}

// ---------------------------------------------------------------------------
//  Frame
// ---------------------------------------------------------------------------

// Makes the swapchain match the frame. Returns R_FALSE when the window cannot be rendered now.
fn rvn_vk_prepare_swapchain(surface: [*c]be.rvn_vk_surface_t, data: [*c]const raven.RDrawData) c_int {
    be.g_vk.info.vsync = data.*.vsync;
    const matches: bool = surface.*.swapchain != null and surface.*.out_of_date == 0 and surface.*.present_vsync == data.*.vsync and
        ((surface.*.extent.width == data.*.framebuffer_width and surface.*.extent.height == data.*.framebuffer_height) or
            (surface.*.requested_width == data.*.framebuffer_width and surface.*.requested_height == data.*.framebuffer_height));
    if (matches) return raven.R_TRUE;
    return be.rvn_vk_swapchain_create(surface, data.*.framebuffer_width, data.*.framebuffer_height);
}

// Copies the instances of the frame into the vertex buffer of the slot.
fn rvn_vk_upload_instances(frame: [*c]be.rvn_vk_frame_t, data: [*c]const raven.RDrawData) c_int {
    const needed: vk.VkDeviceSize = @as(vk.VkDeviceSize, data.*.instance_count) * @sizeOf(raven.RDrawInstance);
    if (needed == 0) return raven.R_TRUE;
    if (needed > frame.*.instances.size) {
        // the slot is idle (its fence was waited), so its buffer can be replaced
        var size: vk.VkDeviceSize = if (frame.*.instances.size != 0) frame.*.instances.size else RVN_VK_MIN_INSTANCE_BYTES;
        while (size < needed) size *%= 2;
        be.rvn_vk_buffer_destroy(&frame.*.instances);
        if (be.rvn_vk_buffer_create(&frame.*.instances, size, vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT) == raven.R_FALSE) return raven.R_FALSE;
    }
    _ = libc.memcpy(frame.*.instances.mapped, data.*.instances, @intCast(needed));
    return raven.R_TRUE;
}

export fn rvn_vk_render_frame(data: [*c]const raven.RDrawData, capture: [*c]raven.RCapture) void {
    const surface: [*c]be.rvn_vk_surface_t = be.rvn_vk_surface_find(data.*.window);
    var frame: [*c]be.rvn_vk_frame_t = undefined;
    var capture_buffer: be.rvn_vk_buffer_t = undefined;
    var begin: vk.VkCommandBufferBeginInfo = undefined;
    var pass: vk.VkRenderPassBeginInfo = undefined;
    var clear: vk.VkClearValue = undefined;
    var submit: vk.VkSubmitInfo = undefined;
    var present: vk.VkPresentInfoKHR = undefined;
    const wait_stage: vk.VkPipelineStageFlags = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    var image_index: u32 = 0;
    var capture_width: u32 = 0;
    var capture_height: u32 = 0;
    var capturing: c_int = raven.R_FALSE;
    var glass: c_int = undefined;
    var result: vk.VkResult = undefined;

    if (capture != null) capture.* = std.mem.zeroes(raven.RCapture);
    if (surface == null or data.*.framebuffer_width == 0 or data.*.framebuffer_height == 0) return;

    // textures changed since the last frame must be complete before they are sampled
    be.rvn_vk_uploads_flush();

    if (rvn_vk_prepare_swapchain(surface, data) == raven.R_FALSE) return;

    const cursor: u32 = surface.*.frame_cursor;
    surface.*.frame_cursor +%= 1;
    frame = &surface.*.frames[cursor % be.RVN_VK_FRAMES];
    if (frame.*.submitted != 0) {
        _ = loader.rvn_vk.WaitForFences.?(be.g_vk.device, 1, &frame.*.fence, vk.VK_TRUE, UINT64_MAX);
        _ = loader.rvn_vk.ResetFences.?(be.g_vk.device, 1, &frame.*.fence);
        frame.*.submitted = raven.R_FALSE;
    }

    result = loader.rvn_vk.AcquireNextImageKHR.?(be.g_vk.device, surface.*.swapchain, UINT64_MAX, frame.*.acquired, null, &image_index);
    if (result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
        // the window changed since the swapchain was created: try once more with a new one
        surface.*.out_of_date = raven.R_TRUE;
        if (rvn_vk_prepare_swapchain(surface, data) == raven.R_FALSE) return;
        result = loader.rvn_vk.AcquireNextImageKHR.?(be.g_vk.device, surface.*.swapchain, UINT64_MAX, frame.*.acquired, null, &image_index);
    }
    if (result == vk.VK_SUBOPTIMAL_KHR) {
        // still presentable: draw this frame, recreate for the next one
        surface.*.out_of_date = raven.R_TRUE;
    } else if (result != vk.VK_SUCCESS) {
        if (result != vk.VK_ERROR_OUT_OF_DATE_KHR) _ = be.rvn_vk_failed(result, "vkAcquireNextImageKHR");
        surface.*.out_of_date = raven.R_TRUE;
        return;
    }

    if (rvn_vk_upload_instances(frame, data) == raven.R_FALSE) return;
    glass = rvn_vk_frame_uses_glass(surface, data);

    capture_buffer = std.mem.zeroes(be.rvn_vk_buffer_t);
    if (capture != null and rvn_vk_capture_supported(surface) != 0) {
        // the swapchain can be larger than the frame when the window system imposes its size
        capture_width = base.rvn_minu(surface.*.extent.width, data.*.framebuffer_width);
        capture_height = base.rvn_minu(surface.*.extent.height, data.*.framebuffer_height);
        capturing = be.rvn_vk_buffer_create(&capture_buffer, @as(vk.VkDeviceSize, capture_width) * capture_height * 4, vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    }

    // ---- record ----
    begin = std.mem.zeroes(vk.VkCommandBufferBeginInfo);
    begin.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    _ = loader.rvn_vk.BeginCommandBuffer.?(frame.*.commands, &begin);

    clear.color.float32[0] = data.*.clear_color[0];
    clear.color.float32[1] = data.*.clear_color[1];
    clear.color.float32[2] = data.*.clear_color[2];
    clear.color.float32[3] = data.*.clear_color[3];
    pass = std.mem.zeroes(vk.VkRenderPassBeginInfo);
    pass.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    pass.renderPass = surface.*.pass.*.render_pass;
    pass.framebuffer = surface.*.framebuffers[image_index];
    pass.renderArea.extent = surface.*.extent;
    pass.clearValueCount = 1;
    pass.pClearValues = &clear;
    if (glass != 0) {
        // the frame goes to the offscreen scene, which is then drawn into the swapchain image
        be.rvn_vk_glass_begin_scene(frame.*.commands, surface, &clear);
        rvn_vk_record_commands(frame.*.commands, surface, frame, data, raven.R_TRUE);
        loader.rvn_vk.CmdEndRenderPass.?(frame.*.commands);
        loader.rvn_vk.CmdBeginRenderPass.?(frame.*.commands, &pass, vk.VK_SUBPASS_CONTENTS_INLINE);
        be.rvn_vk_glass_present_scene(frame.*.commands, surface);
        loader.rvn_vk.CmdEndRenderPass.?(frame.*.commands);
    } else {
        loader.rvn_vk.CmdBeginRenderPass.?(frame.*.commands, &pass, vk.VK_SUBPASS_CONTENTS_INLINE);
        rvn_vk_record_commands(frame.*.commands, surface, frame, data, raven.R_FALSE);
        loader.rvn_vk.CmdEndRenderPass.?(frame.*.commands);
    }

    if (capturing != 0) {
        rvn_vk_record_capture(frame.*.commands, surface.*.images[image_index], capture_buffer.buffer, capture_width, capture_height);
    }
    _ = loader.rvn_vk.EndCommandBuffer.?(frame.*.commands);

    // ---- submit and present ----
    submit = std.mem.zeroes(vk.VkSubmitInfo);
    submit.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &frame.*.acquired;
    submit.pWaitDstStageMask = &wait_stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &frame.*.commands;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &surface.*.rendered[image_index];

    present = std.mem.zeroes(vk.VkPresentInfoKHR);
    present.sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &surface.*.rendered[image_index];
    present.swapchainCount = 1;
    present.pSwapchains = &surface.*.swapchain;
    present.pImageIndices = &image_index;

    be.rvn_vk_queue_lock();
    result = loader.rvn_vk.QueueSubmit.?(be.g_vk.queue, 1, &submit, frame.*.fence);
    if (result == vk.VK_SUCCESS) {
        frame.*.submitted = raven.R_TRUE;
        result = loader.rvn_vk.QueuePresentKHR.?(be.g_vk.queue, &present);
        if (result == vk.VK_ERROR_OUT_OF_DATE_KHR or result == vk.VK_SUBOPTIMAL_KHR) {
            surface.*.out_of_date = raven.R_TRUE;
        } else {
            _ = be.rvn_vk_failed(result, "vkQueuePresentKHR");
        }
    } else {
        _ = be.rvn_vk_failed(result, "vkQueueSubmit");
    }
    be.rvn_vk_queue_unlock();

    if (capturing != 0) {
        if (frame.*.submitted != 0) {
            _ = loader.rvn_vk.WaitForFences.?(be.g_vk.device, 1, &frame.*.fence, vk.VK_TRUE, UINT64_MAX);
            rvn_vk_finish_capture(surface, @ptrCast(capture_buffer.mapped), capture_width, capture_height, capture);
        }
        be.rvn_vk_buffer_destroy(&capture_buffer);
    }
}
