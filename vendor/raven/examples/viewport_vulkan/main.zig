// Translated to Zig from vendor/raven/examples/viewport_vulkan/main.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven example - viewport_vulkan
// A Vulkan scene shown inside the UI, in the two ways raven_viewport.h offers:
//
//   left   TEXTURE        the application renders the scene into its own
//                         image, and Raven samples that image like any texture
//                         (Rvulkan_texture_create_from_image_view): no copy,
//                         and the image keeps its own size, format and depth.
//
//   right  DRAW CALLBACK  Raven calls the application while it records its
//                         frame; the application draws straight into the
//                         window with the viewport and scissor of the widget.
//
// Here the application borrows the device of Raven (Rvulkan_get_device). An
// engine that already owns a device does the opposite: it gives its device
// to Raven with Rvulkan_set_external_device before Rinit; everything else
// in this file stays the same.
//
// Threads: Raven renders on its own thread, and a VkQueue must not be used by
// two threads at once. The application and Raven therefore agree on a lock
// (Rvulkan_set_queue_lock_callbacks) taken around every use of the queue.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const example = @import("example");

const vk = @import("vk.zig");

const shaders_spv = @import("shaders_spv.zig");

pub const panic = example.panic;

// #if defined(_WIN32): <windows.h>
extern "kernel32" fn InitializeCriticalSection(lpCriticalSection: [*c]std.os.windows.CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn EnterCriticalSection(lpCriticalSection: [*c]std.os.windows.CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn LeaveCriticalSection(lpCriticalSection: [*c]std.os.windows.CRITICAL_SECTION) callconv(.winapi) void;
// #else: <pthread.h>
extern "c" fn pthread_mutex_init(mutex: [*c]std.c.pthread_mutex_t, attr: ?*const anyopaque) c_int;
extern "c" fn pthread_mutex_lock(mutex: [*c]std.c.pthread_mutex_t) c_int;
extern "c" fn pthread_mutex_unlock(mutex: [*c]std.c.pthread_mutex_t) c_int;

const Mutex = if (builtin.os.tag == .windows) std.os.windows.CRITICAL_SECTION else std.c.pthread_mutex_t;
fn mutex_init(mutex: [*c]Mutex) void {
    if (builtin.os.tag == .windows) InitializeCriticalSection(mutex) else _ = pthread_mutex_init(mutex, null);
}
fn mutex_lock(mutex: [*c]Mutex) void {
    if (builtin.os.tag == .windows) EnterCriticalSection(mutex) else _ = pthread_mutex_lock(mutex);
}
fn mutex_unlock(mutex: [*c]Mutex) void {
    if (builtin.os.tag == .windows) LeaveCriticalSection(mutex) else _ = pthread_mutex_unlock(mutex);
}

/// Image the scene is rendered into (texture mode).
const Target = extern struct {
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    view: vk.VkImageView,
    framebuffer: vk.VkFramebuffer,
    width: c_int,
    height: c_int,
};

var app = std.mem.zeroes(extern struct {
    // borrowed from Raven
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
    // protects the queue, and `angle` which both threads read
    lock: Mutex,

    vertex_shader: vk.VkShaderModule,
    fragment_shader: vk.VkShaderModule,
    layout: vk.VkPipelineLayout,

    // texture mode
    offscreen_pass: vk.VkRenderPass,
    offscreen_pipeline: vk.VkPipeline,
    pool: vk.VkCommandPool,
    commands: vk.VkCommandBuffer,
    fence: vk.VkFence,
    submitted: c_int,
    target: Target,
    wanted_width: c_int,
    wanted_height: c_int,
    texture: raven.Rid,

    // callback mode: the pipeline is built for the render pass of Raven, on the render thread
    window_pass: vk.VkRenderPass,
    window_pipeline: vk.VkPipeline,

    window: raven.Rid,
    texture_viewport: raven.Rid,
    callback_viewport: raven.Rid,
    label: raven.Rid,
    angle: f32,
    paused: c_int,
});

fn queue_lock(user_data: ?*anyopaque) callconv(.c) void {
    mutex_lock(@ptrCast(@alignCast(user_data)));
}
fn queue_unlock(user_data: ?*anyopaque) callconv(.c) void {
    mutex_unlock(@ptrCast(@alignCast(user_data)));
}

// #define CHECK_VK(call): `call_text` is #call, the text of the call
inline fn CHECK_VK(call: vk.VkResult, call_text: [*:0]const u8) void {
    const check_result_: vk.VkResult = call;
    if (check_result_ != vk.VK_SUCCESS) _ = example.fprintf(example.c_stderr(), "viewport_vulkan: %s failed (%d)\n", call_text, @as(c_int, check_result_));
}

// ---------------------------------------------------------------------------
//  Pipeline (the same shaders are used by both modes)
// -------------------------------------------------------------------------

fn create_pipeline(render_pass: vk.VkRenderPass) vk.VkPipeline {
    var stages: [2]vk.VkPipelineShaderStageCreateInfo = undefined;
    var vertex_input: vk.VkPipelineVertexInputStateCreateInfo = undefined;
    var assembly: vk.VkPipelineInputAssemblyStateCreateInfo = undefined;
    var viewport: vk.VkPipelineViewportStateCreateInfo = undefined;
    var raster: vk.VkPipelineRasterizationStateCreateInfo = undefined;
    var multisample: vk.VkPipelineMultisampleStateCreateInfo = undefined;
    var blend_attachment: vk.VkPipelineColorBlendAttachmentState = undefined;
    var blend: vk.VkPipelineColorBlendStateCreateInfo = undefined;
    var dynamic: vk.VkPipelineDynamicStateCreateInfo = undefined;
    var info: vk.VkGraphicsPipelineCreateInfo = undefined;
    var pipeline: vk.VkPipeline = vk.VK_NULL_HANDLE;
    // the viewport and the scissor are dynamic: Raven sets them to the widget before the callback
    const static = struct {
        const dynamic_states = [2]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
    };

    @memset(std.mem.asBytes(&stages), 0);
    stages[0].sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = vk.VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = app.vertex_shader;
    stages[0].pName = "main";
    stages[1].sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = app.fragment_shader;
    stages[1].pName = "main";

    @memset(std.mem.asBytes(&vertex_input), 0);
    vertex_input.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    @memset(std.mem.asBytes(&assembly), 0);
    assembly.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    assembly.topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    @memset(std.mem.asBytes(&viewport), 0);
    viewport.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport.viewportCount = 1;
    viewport.scissorCount = 1;
    @memset(std.mem.asBytes(&raster), 0);
    raster.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    raster.polygonMode = vk.VK_POLYGON_MODE_FILL;
    raster.cullMode = vk.VK_CULL_MODE_NONE;
    raster.lineWidth = 1.0;
    @memset(std.mem.asBytes(&multisample), 0);
    multisample.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisample.rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT;
    @memset(std.mem.asBytes(&blend_attachment), 0);
    blend_attachment.colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT |
        vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT;
    @memset(std.mem.asBytes(&blend), 0);
    blend.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    blend.attachmentCount = 1;
    blend.pAttachments = &blend_attachment;
    @memset(std.mem.asBytes(&dynamic), 0);
    dynamic.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic.dynamicStateCount = 2;
    dynamic.pDynamicStates = &static.dynamic_states;

    @memset(std.mem.asBytes(&info), 0);
    info.sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    info.stageCount = 2;
    info.pStages = &stages;
    info.pVertexInputState = &vertex_input;
    info.pInputAssemblyState = &assembly;
    info.pViewportState = &viewport;
    info.pRasterizationState = &raster;
    info.pMultisampleState = &multisample;
    info.pColorBlendState = &blend;
    info.pDynamicState = &dynamic;
    info.layout = app.layout;
    info.renderPass = render_pass;
    CHECK_VK(vk.vkCreateGraphicsPipelines(app.device, vk.VK_NULL_HANDLE, 1, &info, null, &pipeline), "vkCreateGraphicsPipelines(app.device, VK_NULL_HANDLE, 1, &info, NULL, &pipeline)");
    return pipeline;
}

// Sets the viewport and draws the triangle. Used by both modes.
fn draw_scene(commands: vk.VkCommandBuffer, pipeline: vk.VkPipeline, x: f32, y: f32, width: f32, height: f32, angle: f32) void {
    var constants: [2]f32 = undefined;
    constants[0] = angle;
    constants[1] = width / height;
    if (x >= 0.0) {
        // the offscreen pass sets its own viewport; in the callback Raven already did
        var viewport: vk.VkViewport = undefined;
        var scissor: vk.VkRect2D = undefined;
        viewport.x = x;
        viewport.y = y;
        viewport.width = width;
        viewport.height = height;
        viewport.minDepth = 0.0;
        viewport.maxDepth = 1.0;
        scissor.offset.x = @intFromFloat(x);
        scissor.offset.y = @intFromFloat(y);
        scissor.extent.width = @intFromFloat(width);
        scissor.extent.height = @intFromFloat(height);
        vk.vkCmdSetViewport(commands, 0, 1, &viewport);
        vk.vkCmdSetScissor(commands, 0, 1, &scissor);
    }
    vk.vkCmdBindPipeline(commands, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vk.vkCmdPushConstants(commands, app.layout, vk.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(@TypeOf(constants)), &constants);
    vk.vkCmdDraw(commands, 3, 1, 0, 0);
}

// ---------------------------------------------------------------------------
//  Mode 1: texture
// -------------------------------------------------------------------------

fn create_offscreen_pass() void {
    var attachment: vk.VkAttachmentDescription = undefined;
    var reference: vk.VkAttachmentReference = undefined;
    var subpass: vk.VkSubpassDescription = undefined;
    var dependencies: [2]vk.VkSubpassDependency = undefined;
    var info: vk.VkRenderPassCreateInfo = undefined;

    @memset(std.mem.asBytes(&attachment), 0);
    attachment.format = vk.VK_FORMAT_R8G8B8A8_UNORM;
    attachment.samples = vk.VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachment.storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachment.stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED;
    // Raven requires the image to be in this layout whenever it renders
    attachment.finalLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    reference.attachment = 0;
    reference.layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    @memset(std.mem.asBytes(&subpass), 0);
    subpass.pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &reference;

    // wait for the previous frame of Raven to finish sampling the image, and make Raven wait for us
    @memset(std.mem.asBytes(&dependencies), 0);
    dependencies[0].srcSubpass = vk.VK_SUBPASS_EXTERNAL;
    dependencies[0].dstSubpass = 0;
    dependencies[0].srcStageMask = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    dependencies[0].dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[0].srcAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
    dependencies[0].dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dependencies[1].srcSubpass = 0;
    dependencies[1].dstSubpass = vk.VK_SUBPASS_EXTERNAL;
    dependencies[1].srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[1].dstStageMask = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
    dependencies[1].srcAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    dependencies[1].dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;

    @memset(std.mem.asBytes(&info), 0);
    info.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    info.attachmentCount = 1;
    info.pAttachments = &attachment;
    info.subpassCount = 1;
    info.pSubpasses = &subpass;
    info.dependencyCount = 2;
    info.pDependencies = &dependencies;
    CHECK_VK(vk.vkCreateRenderPass(app.device, &info, null, &app.offscreen_pass), "vkCreateRenderPass(app.device, &info, NULL, &app.offscreen_pass)");
}

fn target_create(target: [*c]Target, width: c_int, height: c_int) void {
    var image: vk.VkImageCreateInfo = undefined;
    var requirements: vk.VkMemoryRequirements = undefined;
    var memory: vk.VkPhysicalDeviceMemoryProperties = undefined;
    var allocation: vk.VkMemoryAllocateInfo = undefined;
    var view: vk.VkImageViewCreateInfo = undefined;
    var framebuffer: vk.VkFramebufferCreateInfo = undefined;
    var i: u32 = undefined;

    target.* = std.mem.zeroes(Target); // memset(target, 0, sizeof(*target));
    target.*.width = width;
    target.*.height = height;

    @memset(std.mem.asBytes(&image), 0);
    image.sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image.imageType = vk.VK_IMAGE_TYPE_2D;
    // UNORM: Raven shows the values of the image as they are
    image.format = vk.VK_FORMAT_R8G8B8A8_UNORM;
    image.extent.width = @bitCast(width);
    image.extent.height = @bitCast(height);
    image.extent.depth = 1;
    image.mipLevels = 1;
    image.arrayLayers = 1;
    image.samples = vk.VK_SAMPLE_COUNT_1_BIT;
    image.tiling = vk.VK_IMAGE_TILING_OPTIMAL;
    image.usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT;
    CHECK_VK(vk.vkCreateImage(app.device, &image, null, &target.*.image), "vkCreateImage(app.device, &image, NULL, &target->image)");

    vk.vkGetImageMemoryRequirements(app.device, target.*.image, &requirements);
    vk.vkGetPhysicalDeviceMemoryProperties(app.physical_device, &memory);
    @memset(std.mem.asBytes(&allocation), 0);
    allocation.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocation.allocationSize = requirements.size;
    i = 0;
    while (i < memory.memoryTypeCount) : (i += 1) {
        if ((requirements.memoryTypeBits & (@as(c_uint, 1) << @intCast(i))) != 0 and (memory.memoryTypes[i].propertyFlags & vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0) {
            allocation.memoryTypeIndex = i;
            break;
        }
    }
    CHECK_VK(vk.vkAllocateMemory(app.device, &allocation, null, &target.*.memory), "vkAllocateMemory(app.device, &allocation, NULL, &target->memory)");
    CHECK_VK(vk.vkBindImageMemory(app.device, target.*.image, target.*.memory, 0), "vkBindImageMemory(app.device, target->image, target->memory, 0)");

    @memset(std.mem.asBytes(&view), 0);
    view.sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view.image = target.*.image;
    view.viewType = vk.VK_IMAGE_VIEW_TYPE_2D;
    view.format = image.format;
    view.subresourceRange.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
    view.subresourceRange.levelCount = 1;
    view.subresourceRange.layerCount = 1;
    CHECK_VK(vk.vkCreateImageView(app.device, &view, null, &target.*.view), "vkCreateImageView(app.device, &view, NULL, &target->view)");

    @memset(std.mem.asBytes(&framebuffer), 0);
    framebuffer.sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    framebuffer.renderPass = app.offscreen_pass;
    framebuffer.attachmentCount = 1;
    framebuffer.pAttachments = &target.*.view;
    framebuffer.width = @bitCast(width);
    framebuffer.height = @bitCast(height);
    framebuffer.layers = 1;
    CHECK_VK(vk.vkCreateFramebuffer(app.device, &framebuffer, null, &target.*.framebuffer), "vkCreateFramebuffer(app.device, &framebuffer, NULL, &target->framebuffer)");
}

fn target_destroy(target: [*c]Target) void {
    if (target.*.framebuffer != null) vk.vkDestroyFramebuffer(app.device, target.*.framebuffer, null);
    if (target.*.view != null) vk.vkDestroyImageView(app.device, target.*.view, null);
    if (target.*.image != null) vk.vkDestroyImage(app.device, target.*.image, null);
    if (target.*.memory != null) vk.vkFreeMemory(app.device, target.*.memory, null);
    target.* = std.mem.zeroes(Target); // memset(target, 0, sizeof(*target));
}

// Waits until the GPU finished the last offscreen pass: its command buffer and target are then free.
fn offscreen_wait() void {
    if (app.submitted == 0) return;
    CHECK_VK(vk.vkWaitForFences(app.device, 1, &app.fence, vk.VK_TRUE, std.math.maxInt(u64)), "vkWaitForFences(app.device, 1, &app.fence, VK_TRUE, UINT64_MAX)");
    CHECK_VK(vk.vkResetFences(app.device, 1, &app.fence), "vkResetFences(app.device, 1, &app.fence)");
    app.submitted = 0;
}

// Renders the scene into the image of the application. UI thread, once per frame.
fn offscreen_render() void {
    var begin: vk.VkCommandBufferBeginInfo = undefined;
    var pass: vk.VkRenderPassBeginInfo = undefined;
    var clear: vk.VkClearValue = undefined;
    var submit: vk.VkSubmitInfo = undefined;

    if (app.wanted_width <= 0 or app.wanted_height <= 0) return;
    offscreen_wait();

    if (app.target.width != app.wanted_width or app.target.height != app.wanted_height) {
        // the viewport was resized: render into a new image and hand it to Raven
        var previous: Target = app.target;
        target_create(&app.target, app.wanted_width, app.wanted_height);
        if (app.texture == raven.R_INVALID_ID) {
            // sampler 0 = the linear sampler of Raven
            app.texture = raven.Rvulkan_texture_create_from_image_view(@as(u64, @intFromPtr(app.target.view)), 0, app.target.width, app.target.height);
            raven.Rviewport_set_texture(app.texture_viewport, app.texture);
        } else {
            // returns once Raven no longer uses the previous view, which can then be destroyed
            raven.Rvulkan_texture_set_image_view(app.texture, @as(u64, @intFromPtr(app.target.view)), 0, app.target.width, app.target.height);
        }
        target_destroy(&previous);
    }

    @memset(std.mem.asBytes(&begin), 0);
    begin.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    CHECK_VK(vk.vkBeginCommandBuffer(app.commands, &begin), "vkBeginCommandBuffer(app.commands, &begin)");

    clear.color.float32[0] = 0.05;
    clear.color.float32[1] = 0.06;
    clear.color.float32[2] = 0.10;
    clear.color.float32[3] = 1.0;
    @memset(std.mem.asBytes(&pass), 0);
    pass.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    pass.renderPass = app.offscreen_pass;
    pass.framebuffer = app.target.framebuffer;
    pass.renderArea.extent.width = @bitCast(app.target.width);
    pass.renderArea.extent.height = @bitCast(app.target.height);
    pass.clearValueCount = 1;
    pass.pClearValues = &clear;
    vk.vkCmdBeginRenderPass(app.commands, &pass, vk.VK_SUBPASS_CONTENTS_INLINE);
    draw_scene(app.commands, app.offscreen_pipeline, 0.0, 0.0, @floatFromInt(app.target.width), @floatFromInt(app.target.height), app.angle);
    vk.vkCmdEndRenderPass(app.commands);
    CHECK_VK(vk.vkEndCommandBuffer(app.commands), "vkEndCommandBuffer(app.commands)");

    @memset(std.mem.asBytes(&submit), 0);
    submit.sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &app.commands;
    // submitted before Raven submits the frame that samples the image: the queue keeps that order
    mutex_lock(&app.lock);
    CHECK_VK(vk.vkQueueSubmit(app.queue, 1, &submit, app.fence), "vkQueueSubmit(app.queue, 1, &submit, app.fence)");
    mutex_unlock(&app.lock);
    app.submitted = 1;
}

fn on_texture_viewport_resized(viewport: raven.Rid, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = viewport;
    _ = user_data;
    app.wanted_width = width;
    app.wanted_height = height;
}

// ---------------------------------------------------------------------------
//  Mode 2: draw callback (render thread, inside the render pass of Raven)
// -------------------------------------------------------------------------

fn on_draw(info: [*c]const raven.RViewportDrawInfo, user_data: ?*anyopaque) callconv(.c) void {
    const commands: vk.VkCommandBuffer = @ptrCast(info.*.command_buffer);
    const render_pass: vk.VkRenderPass = @ptrFromInt(@intFromPtr(info.*.render_pass));
    var angle: f32 = undefined;
    _ = user_data;

    // a pipeline must be compatible with the render pass it is used in: build it on first use
    if (app.window_pass != render_pass) {
        if (app.window_pipeline != null) vk.vkDestroyPipeline(app.device, app.window_pipeline, null);
        app.window_pipeline = create_pipeline(render_pass);
        app.window_pass = render_pass;
    }

    mutex_lock(&app.lock);
    angle = app.angle;
    mutex_unlock(&app.lock);

    // x < 0: keep the viewport and scissor Raven set to the widget (and to its visible part)
    draw_scene(commands, app.window_pipeline, -1.0, 0.0, @floatFromInt(info.*.width), @floatFromInt(info.*.height), -angle);
}

// ---------------------------------------------------------------------------
//  Application
// -------------------------------------------------------------------------

fn on_frame(delta_seconds: f64, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    if (raven.Rwindow_is_valid(app.window) == 0) return;
    if (app.paused == 0) {
        mutex_lock(&app.lock);
        app.angle += @floatCast(delta_seconds);
        mutex_unlock(&app.lock);
    }
    offscreen_render();
}

fn on_pause(checkbox: raven.Rid, checked: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = checkbox;
    _ = user_data;
    app.paused = checked;
    // realtime viewports redraw the window every frame; otherwise Raven only draws when needed
    raven.Rviewport_set_realtime(app.texture_viewport, @intFromBool(checked == 0));
    raven.Rviewport_set_realtime(app.callback_viewport, @intFromBool(checked == 0));
}

const g_layout =
    "<Window Title=\"Raven - Vulkan viewports\" Width=\"960\" Height=\"540\">" ++
    "  <VBox Spacing=\"8\" Slot.Padding=\"10\">" ++
    "    <HBox Spacing=\"12\">" ++
    "      <Checkbox Name=\"pause\" Text=\"Pause\" Style=\"Switch\"/>" ++
    "      <Label Name=\"info\" Slot.VAlign=\"Center\" Opacity=\"0.7\"/>" ++
    "    </HBox>" ++
    "    <Splitter Slot.Fill=\"1\">" ++
    "      <VBox Spacing=\"4\">" ++
    "        <Label>Texture: offscreen image of the application</Label>" ++
    "        <Overlay Slot.Fill=\"1\">" ++
    "          <Viewport Name=\"texture\" Realtime=\"true\"/>" ++
    "          <Button Text=\"UI over the scene\" Slot.HAlign=\"Right\" Slot.VAlign=\"Bottom\" Slot.Padding=\"12\"/>" ++
    "        </Overlay>" ++
    "      </VBox>" ++
    "      <VBox Spacing=\"4\">" ++
    "        <Label>Draw callback: drawn in the render pass of the window</Label>" ++
    "        <Overlay Slot.Fill=\"1\">" ++
    "          <Viewport Name=\"callback\" Realtime=\"true\"/>" ++
    "          <Button Text=\"UI over the scene\" Slot.HAlign=\"Right\" Slot.VAlign=\"Bottom\" Slot.Padding=\"12\"/>" ++
    "        </Overlay>" ++
    "      </VBox>" ++
    "    </Splitter>" ++
    "  </VBox>" ++
    "</Window>";

export fn main() c_int {
    var shader: vk.VkShaderModuleCreateInfo = undefined;
    var range: vk.VkPushConstantRange = undefined;
    var layout: vk.VkPipelineLayoutCreateInfo = undefined;
    var pool: vk.VkCommandPoolCreateInfo = undefined;
    var allocation: vk.VkCommandBufferAllocateInfo = undefined;
    var fence: vk.VkFenceCreateInfo = undefined;

    // the lock must be known before Raven starts its render thread
    mutex_init(&app.lock);
    raven.Rvulkan_set_queue_lock_callbacks(queue_lock, queue_unlock, &app.lock);
    if (example.example_init("viewport_vulkan") == 0) return 1;

    app.texture = raven.R_INVALID_ID;
    app.physical_device = @ptrCast(raven.Rvulkan_get_physical_device());
    app.device = @ptrCast(raven.Rvulkan_get_device());
    app.queue = @ptrCast(raven.Rvulkan_get_graphics_queue());
    app.queue_family = raven.Rvulkan_get_graphics_queue_family();

    // ---- Vulkan objects of the application ----
    @memset(std.mem.asBytes(&shader), 0);
    shader.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    shader.codeSize = @sizeOf(@TypeOf(shaders_spv.triangle_vert_spv));
    shader.pCode = &shaders_spv.triangle_vert_spv;
    CHECK_VK(vk.vkCreateShaderModule(app.device, &shader, null, &app.vertex_shader), "vkCreateShaderModule(app.device, &shader, NULL, &app.vertex_shader)");
    shader.codeSize = @sizeOf(@TypeOf(shaders_spv.triangle_frag_spv));
    shader.pCode = &shaders_spv.triangle_frag_spv;
    CHECK_VK(vk.vkCreateShaderModule(app.device, &shader, null, &app.fragment_shader), "vkCreateShaderModule(app.device, &shader, NULL, &app.fragment_shader)");

    range.stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT;
    range.offset = 0;
    range.size = @sizeOf(f32) * 2;
    @memset(std.mem.asBytes(&layout), 0);
    layout.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout.pushConstantRangeCount = 1;
    layout.pPushConstantRanges = &range;
    CHECK_VK(vk.vkCreatePipelineLayout(app.device, &layout, null, &app.layout), "vkCreatePipelineLayout(app.device, &layout, NULL, &app.layout)");

    create_offscreen_pass();
    app.offscreen_pipeline = create_pipeline(app.offscreen_pass);

    @memset(std.mem.asBytes(&pool), 0);
    pool.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = app.queue_family;
    CHECK_VK(vk.vkCreateCommandPool(app.device, &pool, null, &app.pool), "vkCreateCommandPool(app.device, &pool, NULL, &app.pool)");
    @memset(std.mem.asBytes(&allocation), 0);
    allocation.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocation.commandPool = app.pool;
    allocation.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocation.commandBufferCount = 1;
    CHECK_VK(vk.vkAllocateCommandBuffers(app.device, &allocation, &app.commands), "vkAllocateCommandBuffers(app.device, &allocation, &app.commands)");
    @memset(std.mem.asBytes(&fence), 0);
    fence.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    CHECK_VK(vk.vkCreateFence(app.device, &fence, null, &app.fence), "vkCreateFence(app.device, &fence, NULL, &app.fence)");

    // ---- user interface ----
    app.window = raven.Rwindow_create_from_xml(g_layout, g_layout.len); // sizeof(g_layout) - 1
    app.texture_viewport = raven.Rwidget_find(app.window, "texture");
    app.callback_viewport = raven.Rwidget_find(app.window, "callback");
    app.label = raven.Rwidget_find(app.window, "info");
    raven.Rlabel_set_text(app.label, "Both viewports are clipped, resized and covered by widgets like any other widget.");
    raven.Rcheckbox_set_changed_callback(raven.Rwidget_find(app.window, "pause"), on_pause, null);
    raven.Rviewport_set_resize_callback(app.texture_viewport, on_texture_viewport_resized, null);
    raven.Rviewport_set_draw_callback(app.callback_viewport, on_draw, null);
    raven.Rset_frame_callback(on_frame, null);

    // the loop belongs to the application: Raven draws one frame per call,
    // and Rwait_frame sleeps until there is something to draw
    if (example.example_automated(app.window) == 0) {
        while (raven.Rwait_frame(-1.0) != 0) {}
    }

    // ---- shutdown: the device belongs to Raven, so our objects go first ----
    raven.Rset_frame_callback(null, null);
    // deleting the window waits for its last frames: the draw callback will not run again
    if (raven.Rwindow_is_valid(app.window) != 0) raven.Rwindow_destroy(app.window);
    if (app.texture != raven.R_INVALID_ID) raven.Rtexture_destroy(app.texture);
    offscreen_wait();
    mutex_lock(&app.lock);
    _ = vk.vkDeviceWaitIdle(app.device);
    mutex_unlock(&app.lock);

    target_destroy(&app.target);
    vk.vkDestroyFence(app.device, app.fence, null);
    vk.vkDestroyCommandPool(app.device, app.pool, null);
    if (app.window_pipeline != null) vk.vkDestroyPipeline(app.device, app.window_pipeline, null);
    vk.vkDestroyPipeline(app.device, app.offscreen_pipeline, null);
    vk.vkDestroyRenderPass(app.device, app.offscreen_pass, null);
    vk.vkDestroyPipelineLayout(app.device, app.layout, null);
    vk.vkDestroyShaderModule(app.device, app.vertex_shader, null);
    vk.vkDestroyShaderModule(app.device, app.fragment_shader, null);

    raven.Rshutdown();
    return 0;
}
