// Translated to Zig from vendor/raven/src/render/vulkan/vk_pipeline.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_pipeline.c
// Shaders, samplers, descriptor sets, render passes and pipelines.
//
// The whole UI is drawn with a single pipeline: an instanced triangle strip
// of four vertices whose only vertex buffer is the array of RDrawInstance.
// A texture is one descriptor set (combined image sampler, binding 0).

const std = @import("std");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const be = @import("vk_backend_h.zig");
const vk = be.vk;
const loader = be.loader;

const g_vk = &be.g_vk;
const rvn_vk = &loader.rvn_vk;

const ui_vert_spv = @import("generated/ui_vert_spv.zig").rvn_ui_vert_spv;
const ui_frag_spv = @import("generated/ui_frag_spv.zig").rvn_ui_frag_spv;
const blur_vert_spv = @import("generated/blur_vert_spv.zig").rvn_blur_vert_spv;
const blur_frag_spv = @import("generated/blur_frag_spv.zig").rvn_blur_frag_spv;

// ---------------------------------------------------------------------------
//  Device objects shared by every pipeline
// ---------------------------------------------------------------------------

fn rvn_vk_shader_create_module(code: [*c]const u32, size: usize, module: [*c]vk.VkShaderModule) c_int {
    var info = std.mem.zeroes(vk.VkShaderModuleCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = size;
    info.pCode = code;
    return @intFromBool(be.rvn_vk_failed(rvn_vk.CreateShaderModule.?(g_vk.device, &info, null, module), "vkCreateShaderModule") == raven.R_FALSE);
}

fn rvn_vk_sampler_create(filter: vk.VkFilter, sampler: [*c]vk.VkSampler) c_int {
    var info = std.mem.zeroes(vk.VkSamplerCreateInfo);
    info.sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    info.magFilter = filter;
    info.minFilter = filter;
    info.mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST;
    info.addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    info.addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    info.addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    info.maxAnisotropy = 1.0;
    return @intFromBool(be.rvn_vk_failed(rvn_vk.CreateSampler.?(g_vk.device, &info, null, sampler), "vkCreateSampler") == raven.R_FALSE);
}

export fn rvn_vk_pipeline_init() c_int {
    var binding = std.mem.zeroes(vk.VkDescriptorSetLayoutBinding);
    var backdrop_bindings = std.mem.zeroes([2]vk.VkDescriptorSetLayoutBinding);
    var set_info = std.mem.zeroes(vk.VkDescriptorSetLayoutCreateInfo);
    var set_layouts: [2]vk.VkDescriptorSetLayout = undefined;
    var pool_size: vk.VkDescriptorPoolSize = undefined;
    var pool_info = std.mem.zeroes(vk.VkDescriptorPoolCreateInfo);
    var push: vk.VkPushConstantRange = undefined;
    var layout_info = std.mem.zeroes(vk.VkPipelineLayoutCreateInfo);

    if (rvn_vk_shader_create_module(&ui_vert_spv, @sizeOf(@TypeOf(ui_vert_spv)), &g_vk.vertex_shader) == raven.R_FALSE) return raven.R_FALSE;
    if (rvn_vk_shader_create_module(&ui_frag_spv, @sizeOf(@TypeOf(ui_frag_spv)), &g_vk.fragment_shader) == raven.R_FALSE) return raven.R_FALSE;
    if (rvn_vk_shader_create_module(&blur_vert_spv, @sizeOf(@TypeOf(blur_vert_spv)), &g_vk.blur_vertex_shader) == raven.R_FALSE) return raven.R_FALSE;
    if (rvn_vk_shader_create_module(&blur_frag_spv, @sizeOf(@TypeOf(blur_frag_spv)), &g_vk.blur_fragment_shader) == raven.R_FALSE) return raven.R_FALSE;
    if (rvn_vk_sampler_create(vk.VK_FILTER_LINEAR, &g_vk.sampler_linear) == raven.R_FALSE) return raven.R_FALSE;
    if (rvn_vk_sampler_create(vk.VK_FILTER_NEAREST, &g_vk.sampler_nearest) == raven.R_FALSE) return raven.R_FALSE;

    binding.binding = 0;
    binding.descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    binding.descriptorCount = 1;
    binding.stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT;
    set_info.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    set_info.bindingCount = 1;
    set_info.pBindings = &binding;
    if (be.rvn_vk_failed(rvn_vk.CreateDescriptorSetLayout.?(g_vk.device, &set_info, null, &g_vk.set_layout), "vkCreateDescriptorSetLayout") != raven.R_FALSE) return raven.R_FALSE;

    // set 1 of the UI pipeline: the backdrop of glass, sharp and blurred
    backdrop_bindings[0] = binding;
    backdrop_bindings[1] = binding;
    backdrop_bindings[1].binding = 1;
    set_info.bindingCount = 2;
    set_info.pBindings = &backdrop_bindings;
    if (be.rvn_vk_failed(rvn_vk.CreateDescriptorSetLayout.?(g_vk.device, &set_info, null, &g_vk.backdrop_layout), "vkCreateDescriptorSetLayout") != raven.R_FALSE) return raven.R_FALSE;

    pool_size.@"type" = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    pool_size.descriptorCount = be.RVN_VK_MAX_BACKDROPS * 2;
    pool_info.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.flags = vk.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
    pool_info.maxSets = be.RVN_VK_MAX_BACKDROPS;
    pool_info.poolSizeCount = 1;
    pool_info.pPoolSizes = &pool_size;
    if (be.rvn_vk_failed(rvn_vk.CreateDescriptorPool.?(g_vk.device, &pool_info, null, &g_vk.backdrop_pool), "vkCreateDescriptorPool") != raven.R_FALSE) return raven.R_FALSE;

    // UI: vec2 scale, vec2 translate, vec2 pointer (for the effects), vec2 unused
    push.stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT;
    push.offset = 0;
    push.size = @sizeOf(f32) * 8;
    set_layouts[0] = g_vk.set_layout;
    set_layouts[1] = g_vk.backdrop_layout;
    layout_info.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout_info.setLayoutCount = 2;
    layout_info.pSetLayouts = &set_layouts;
    layout_info.pushConstantRangeCount = 1;
    layout_info.pPushConstantRanges = &push;
    if (be.rvn_vk_failed(rvn_vk.CreatePipelineLayout.?(g_vk.device, &layout_info, null, &g_vk.pipeline_layout), "vkCreatePipelineLayout") != raven.R_FALSE) return raven.R_FALSE;

    // blur: one source texture; vec2 step, int mode
    push.stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT;
    push.size = @sizeOf(f32) * 2 + @sizeOf(i32);
    layout_info.setLayoutCount = 1;
    if (be.rvn_vk_failed(rvn_vk.CreatePipelineLayout.?(g_vk.device, &layout_info, null, &g_vk.blur_layout), "vkCreatePipelineLayout") != raven.R_FALSE) return raven.R_FALSE;
    return raven.R_TRUE;
}

export fn rvn_vk_pipeline_shutdown() void {
    var i: u32 = undefined;
    i = 0;
    while (i < g_vk.shader_cap) : (i += 1) {
        if (g_vk.shaders[i].used != raven.R_FALSE) rvn_vk_shader_destroy(g_vk.shaders[i].id);
    }
    base.rvn_free(g_vk.shaders);
    g_vk.shaders = null;
    g_vk.shader_cap = 0;
    i = 0;
    while (i < g_vk.pass_count) : (i += 1) rvn_vk_pass_destroy(&g_vk.passes[i]);
    g_vk.pass_count = 0;
    if (g_vk.backdrop_pool != null) rvn_vk.DestroyDescriptorPool.?(g_vk.device, g_vk.backdrop_pool, null);
    if (g_vk.backdrop_layout != null) rvn_vk.DestroyDescriptorSetLayout.?(g_vk.device, g_vk.backdrop_layout, null);
    if (g_vk.blur_layout != null) rvn_vk.DestroyPipelineLayout.?(g_vk.device, g_vk.blur_layout, null);
    if (g_vk.blur_vertex_shader != null) rvn_vk.DestroyShaderModule.?(g_vk.device, g_vk.blur_vertex_shader, null);
    if (g_vk.blur_fragment_shader != null) rvn_vk.DestroyShaderModule.?(g_vk.device, g_vk.blur_fragment_shader, null);
    g_vk.backdrop_pool = null;
    g_vk.backdrop_layout = null;
    g_vk.backdrop_default = null;
    g_vk.blur_layout = null;
    g_vk.blur_vertex_shader = null;
    g_vk.blur_fragment_shader = null;
    i = 0;
    while (i < g_vk.pool_count) : (i += 1) rvn_vk.DestroyDescriptorPool.?(g_vk.device, g_vk.pools[i], null);
    base.rvn_free(@ptrCast(g_vk.pools));
    base.rvn_free(g_vk.pool_used);
    g_vk.pools = null;
    g_vk.pool_used = null;
    g_vk.pool_count = 0;
    g_vk.pool_cap = 0;
    if (g_vk.pipeline_layout != null) rvn_vk.DestroyPipelineLayout.?(g_vk.device, g_vk.pipeline_layout, null);
    if (g_vk.set_layout != null) rvn_vk.DestroyDescriptorSetLayout.?(g_vk.device, g_vk.set_layout, null);
    if (g_vk.sampler_linear != null) rvn_vk.DestroySampler.?(g_vk.device, g_vk.sampler_linear, null);
    if (g_vk.sampler_nearest != null) rvn_vk.DestroySampler.?(g_vk.device, g_vk.sampler_nearest, null);
    if (g_vk.vertex_shader != null) rvn_vk.DestroyShaderModule.?(g_vk.device, g_vk.vertex_shader, null);
    if (g_vk.fragment_shader != null) rvn_vk.DestroyShaderModule.?(g_vk.device, g_vk.fragment_shader, null);
    g_vk.pipeline_layout = null;
    g_vk.set_layout = null;
    g_vk.sampler_linear = null;
    g_vk.sampler_nearest = null;
    g_vk.vertex_shader = null;
    g_vk.fragment_shader = null;
}

// ---------------------------------------------------------------------------
//  Render pass + pipeline
// ---------------------------------------------------------------------------

// One color attachment, no depth. `present` = the swapchain: the image goes to
// the screen afterwards. Otherwise the image is sampled afterwards (offscreen
// frame of a window with glass, blur targets).
fn rvn_vk_render_pass_create(format: vk.VkFormat, load: vk.VkAttachmentLoadOp, present: c_int, render_pass: [*c]vk.VkRenderPass) c_int {
    var attachment = std.mem.zeroes(vk.VkAttachmentDescription);
    var reference = std.mem.zeroes(vk.VkAttachmentReference);
    var subpass = std.mem.zeroes(vk.VkSubpassDescription);
    var dependencies = std.mem.zeroes([2]vk.VkSubpassDependency);
    var info = std.mem.zeroes(vk.VkRenderPassCreateInfo);

    attachment.format = format;
    attachment.samples = vk.VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = load;
    attachment.storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachment.stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE;
    // continuing a frame keeps its content; anything else starts from scratch
    attachment.initialLayout = if (load == vk.VK_ATTACHMENT_LOAD_OP_LOAD) vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL else vk.VK_IMAGE_LAYOUT_UNDEFINED;
    attachment.finalLayout = if (present != 0) vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR else vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    reference.attachment = 0;
    reference.layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    subpass.pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &reference;

    dependencies[0].srcSubpass = vk.VK_SUBPASS_EXTERNAL;
    dependencies[0].dstSubpass = 0;
    dependencies[0].dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dependencies[0].dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | vk.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT;
    if (present != 0) {
        // the image is only ours once the semaphore of vkAcquireNextImageKHR is signaled
        dependencies[0].srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependencies[0].srcAccessMask = 0;
    } else {
        // wait for whatever still writes or samples the image, and make the next reader wait for us
        dependencies[0].srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        dependencies[0].srcAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | vk.VK_ACCESS_SHADER_READ_BIT;
        dependencies[1].srcSubpass = 0;
        dependencies[1].dstSubpass = vk.VK_SUBPASS_EXTERNAL;
        dependencies[1].srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependencies[1].srcAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        dependencies[1].dstStageMask = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        dependencies[1].dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
    }

    info.sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    info.attachmentCount = 1;
    info.pAttachments = &attachment;
    info.subpassCount = 1;
    info.pSubpasses = &subpass;
    info.dependencyCount = if (present != 0) 1 else 2;
    info.pDependencies = &dependencies;
    return @intFromBool(be.rvn_vk_failed(rvn_vk.CreateRenderPass.?(g_vk.device, &info, null, render_pass), "vkCreateRenderPass") == raven.R_FALSE);
}

fn rvn_vk_pipeline_create(render_pass: vk.VkRenderPass, erase: c_int, fragment: vk.VkShaderModule, pipeline: [*c]vk.VkPipeline) c_int {
    var stages = std.mem.zeroes([2]vk.VkPipelineShaderStageCreateInfo);
    var binding = std.mem.zeroes(vk.VkVertexInputBindingDescription);
    var attributes = std.mem.zeroes([8]vk.VkVertexInputAttributeDescription);
    var vertex_input = std.mem.zeroes(vk.VkPipelineVertexInputStateCreateInfo);
    var assembly = std.mem.zeroes(vk.VkPipelineInputAssemblyStateCreateInfo);
    var viewport = std.mem.zeroes(vk.VkPipelineViewportStateCreateInfo);
    var raster = std.mem.zeroes(vk.VkPipelineRasterizationStateCreateInfo);
    var multisample = std.mem.zeroes(vk.VkPipelineMultisampleStateCreateInfo);
    var blend_attachment = std.mem.zeroes(vk.VkPipelineColorBlendAttachmentState);
    var blend = std.mem.zeroes(vk.VkPipelineColorBlendStateCreateInfo);
    var dynamic = std.mem.zeroes(vk.VkPipelineDynamicStateCreateInfo);
    var info = std.mem.zeroes(vk.VkGraphicsPipelineCreateInfo);
    const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
    // must match RDrawInstance and the inputs of ui.vert
    const layout = [8]struct { format: vk.VkFormat, offset: u32 }{
        .{ .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(raven.RDrawInstance, "rect") },
        .{ .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(raven.RDrawInstance, "uv") },
        .{ .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(raven.RDrawInstance, "clip") },
        .{ .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = @offsetOf(raven.RDrawInstance, "radii") },
        .{ .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(raven.RDrawInstance, "color") },
        .{ .format = vk.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(raven.RDrawInstance, "border_color") },
        .{ .format = vk.VK_FORMAT_R32_SFLOAT, .offset = @offsetOf(raven.RDrawInstance, "border_width") },
        .{ .format = vk.VK_FORMAT_R32_UINT, .offset = @offsetOf(raven.RDrawInstance, "flags") },
    };
    var i: u32 = undefined;

    stages[0].sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = vk.VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = g_vk.vertex_shader;
    stages[0].pName = "main";
    stages[1].sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fragment;
    stages[1].pName = "main";

    binding.binding = 0;
    binding.stride = @sizeOf(raven.RDrawInstance);
    binding.inputRate = vk.VK_VERTEX_INPUT_RATE_INSTANCE;
    i = 0;
    while (i < 8) : (i += 1) {
        attributes[i].location = i;
        attributes[i].binding = 0;
        attributes[i].format = layout[i].format;
        attributes[i].offset = layout[i].offset;
    }
    vertex_input.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertex_input.vertexBindingDescriptionCount = 1;
    vertex_input.pVertexBindingDescriptions = &binding;
    vertex_input.vertexAttributeDescriptionCount = 8;
    vertex_input.pVertexAttributeDescriptions = &attributes;

    assembly.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    assembly.topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;

    viewport.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport.viewportCount = 1;
    viewport.scissorCount = 1;

    raster.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    raster.polygonMode = vk.VK_POLYGON_MODE_FILL;
    raster.cullMode = vk.VK_CULL_MODE_NONE;
    raster.frontFace = vk.VK_FRONT_FACE_CLOCKWISE;
    raster.lineWidth = 1.0;

    multisample.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisample.rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT;

    // the fragment shader outputs premultiplied colors
    blend_attachment.blendEnable = vk.VK_TRUE;
    blend_attachment.srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE;
    blend_attachment.dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blend_attachment.colorBlendOp = vk.VK_BLEND_OP_ADD;
    blend_attachment.srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE;
    blend_attachment.dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blend_attachment.alphaBlendOp = vk.VK_BLEND_OP_ADD;
    blend_attachment.colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT |
        vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT;
    if (erase != 0) {
        // nothing is added: what is there is kept by as much as the instance does not cover it
        blend_attachment.srcColorBlendFactor = vk.VK_BLEND_FACTOR_ZERO;
        blend_attachment.srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ZERO;
    }
    blend.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    blend.attachmentCount = 1;
    blend.pAttachments = &blend_attachment;

    dynamic.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic.dynamicStateCount = @intCast(dynamic_states.len);
    dynamic.pDynamicStates = &dynamic_states;

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
    info.layout = g_vk.pipeline_layout;
    info.renderPass = render_pass;
    info.subpass = 0;
    return @intFromBool(be.rvn_vk_failed(rvn_vk.CreateGraphicsPipelines.?(g_vk.device, null, 1, &info, null, pipeline), "vkCreateGraphicsPipelines") == raven.R_FALSE);
}

// Full-screen filter of the backdrop passes: three vertices made by blur.vert, no blending.
fn rvn_vk_blur_pipeline_create(render_pass: vk.VkRenderPass, pipeline: [*c]vk.VkPipeline) c_int {
    var stages = std.mem.zeroes([2]vk.VkPipelineShaderStageCreateInfo);
    var vertex_input = std.mem.zeroes(vk.VkPipelineVertexInputStateCreateInfo);
    var assembly = std.mem.zeroes(vk.VkPipelineInputAssemblyStateCreateInfo);
    var viewport = std.mem.zeroes(vk.VkPipelineViewportStateCreateInfo);
    var raster = std.mem.zeroes(vk.VkPipelineRasterizationStateCreateInfo);
    var multisample = std.mem.zeroes(vk.VkPipelineMultisampleStateCreateInfo);
    var blend_attachment = std.mem.zeroes(vk.VkPipelineColorBlendAttachmentState);
    var blend = std.mem.zeroes(vk.VkPipelineColorBlendStateCreateInfo);
    var dynamic = std.mem.zeroes(vk.VkPipelineDynamicStateCreateInfo);
    var info = std.mem.zeroes(vk.VkGraphicsPipelineCreateInfo);
    const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };

    stages[0].sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = vk.VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = g_vk.blur_vertex_shader;
    stages[0].pName = "main";
    stages[1].sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = g_vk.blur_fragment_shader;
    stages[1].pName = "main";

    vertex_input.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    assembly.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    assembly.topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    viewport.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport.viewportCount = 1;
    viewport.scissorCount = 1;
    raster.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    raster.polygonMode = vk.VK_POLYGON_MODE_FILL;
    raster.cullMode = vk.VK_CULL_MODE_NONE;
    raster.lineWidth = 1.0;
    multisample.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisample.rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT;
    blend_attachment.colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT |
        vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT;
    blend.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    blend.attachmentCount = 1;
    blend.pAttachments = &blend_attachment;
    dynamic.sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic.dynamicStateCount = @intCast(dynamic_states.len);
    dynamic.pDynamicStates = &dynamic_states;

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
    info.layout = g_vk.blur_layout;
    info.renderPass = render_pass;
    return @intFromBool(be.rvn_vk_failed(rvn_vk.CreateGraphicsPipelines.?(g_vk.device, null, 1, &info, null, pipeline), "vkCreateGraphicsPipelines") == raven.R_FALSE);
}

fn rvn_vk_pass_destroy(pass: [*c]be.rvn_vk_pass_t) void {
    if (pass.*.pipeline != null) rvn_vk.DestroyPipeline.?(g_vk.device, pass.*.pipeline, null);
    if (pass.*.erase_pipeline != null) rvn_vk.DestroyPipeline.?(g_vk.device, pass.*.erase_pipeline, null);
    if (pass.*.blur_pipeline != null) rvn_vk.DestroyPipeline.?(g_vk.device, pass.*.blur_pipeline, null);
    if (pass.*.render_pass != null) rvn_vk.DestroyRenderPass.?(g_vk.device, pass.*.render_pass, null);
    if (pass.*.scene_clear_pass != null) rvn_vk.DestroyRenderPass.?(g_vk.device, pass.*.scene_clear_pass, null);
    if (pass.*.scene_load_pass != null) rvn_vk.DestroyRenderPass.?(g_vk.device, pass.*.scene_load_pass, null);
    if (pass.*.blur_pass != null) rvn_vk.DestroyRenderPass.?(g_vk.device, pass.*.blur_pass, null);
    if (pass.*.blur_load_pass != null) rvn_vk.DestroyRenderPass.?(g_vk.device, pass.*.blur_load_pass, null);
    pass.* = std.mem.zeroes(be.rvn_vk_pass_t);
}

export fn rvn_vk_pass_get(format: vk.VkFormat) [*c]be.rvn_vk_pass_t {
    var pass: [*c]be.rvn_vk_pass_t = undefined;
    var i: u32 = undefined;
    i = 0;
    while (i < g_vk.pass_count) : (i += 1) {
        if (g_vk.passes[i].format == format) return &g_vk.passes[i];
    }
    if (g_vk.pass_count == be.RVN_VK_MAX_PASSES) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: too many different swapchain formats");
        return null;
    }
    pass = &g_vk.passes[g_vk.pass_count];
    pass.* = std.mem.zeroes(be.rvn_vk_pass_t);
    pass.*.format = format;
    if (rvn_vk_render_pass_create(format, vk.VK_ATTACHMENT_LOAD_OP_CLEAR, raven.R_TRUE, &pass.*.render_pass) == raven.R_FALSE or
        rvn_vk_render_pass_create(format, vk.VK_ATTACHMENT_LOAD_OP_CLEAR, raven.R_FALSE, &pass.*.scene_clear_pass) == raven.R_FALSE or
        rvn_vk_render_pass_create(format, vk.VK_ATTACHMENT_LOAD_OP_LOAD, raven.R_FALSE, &pass.*.scene_load_pass) == raven.R_FALSE or
        rvn_vk_render_pass_create(format, vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE, raven.R_FALSE, &pass.*.blur_pass) == raven.R_FALSE or
        rvn_vk_render_pass_create(format, vk.VK_ATTACHMENT_LOAD_OP_LOAD, raven.R_FALSE, &pass.*.blur_load_pass) == raven.R_FALSE or
        rvn_vk_pipeline_create(pass.*.render_pass, raven.R_FALSE, g_vk.fragment_shader, &pass.*.pipeline) == raven.R_FALSE or
        rvn_vk_pipeline_create(pass.*.render_pass, raven.R_TRUE, g_vk.fragment_shader, &pass.*.erase_pipeline) == raven.R_FALSE or
        rvn_vk_blur_pipeline_create(pass.*.blur_pass, &pass.*.blur_pipeline) == raven.R_FALSE)
    {
        rvn_vk_pass_destroy(pass);
        return null;
    }
    g_vk.pass_count += 1;
    return pass;
}

// ---------------------------------------------------------------------------
//  Effects: one fragment shader of the application each, the rest of the
//  pipeline as the UI (same vertex shader, layout, blending)
// ---------------------------------------------------------------------------

fn rvn_vk_shader_find(id: raven.Rid) [*c]be.rvn_vk_shader_t {
    const index: u32 = raven.R_ID_INDEX(id);
    if (index >= g_vk.shader_cap or g_vk.shaders[index].used == raven.R_FALSE or g_vk.shaders[index].id != id) return null;
    return &g_vk.shaders[index];
}

export fn rvn_vk_shader_create(id: raven.Rid, spirv: [*c]const u32, size: usize) c_int {
    const index: u32 = raven.R_ID_INDEX(id);
    var shader: [*c]be.rvn_vk_shader_t = undefined;
    if (index >= g_vk.shader_cap) {
        var cap: u32 = if (g_vk.shader_cap != 0) g_vk.shader_cap else 16;
        while (cap <= index) cap *= 2;
        g_vk.shaders = @ptrCast(@alignCast(base.rvn_realloc(g_vk.shaders, @sizeOf(be.rvn_vk_shader_t) * @as(usize, cap))));
        @memset(g_vk.shaders[@as(usize, g_vk.shader_cap)..@as(usize, cap)], std.mem.zeroes(be.rvn_vk_shader_t));
        g_vk.shader_cap = cap;
    }
    shader = &g_vk.shaders[index];
    if (shader.*.used != raven.R_FALSE) rvn_vk_shader_destroy(shader.*.id);
    shader.* = std.mem.zeroes(be.rvn_vk_shader_t);
    if (rvn_vk_shader_create_module(spirv, size, &shader.*.module) == raven.R_FALSE) return raven.R_FALSE;
    shader.*.used = raven.R_TRUE;
    shader.*.id = id;
    return raven.R_TRUE;
}

export fn rvn_vk_shader_destroy(id: raven.Rid) void {
    const shader = rvn_vk_shader_find(id);
    var i: u32 = undefined;
    if (shader == null) return;
    // (frames on the GPU may still draw with it)
    _ = rvn_vk.DeviceWaitIdle.?(g_vk.device);
    i = 0;
    while (i < be.RVN_VK_MAX_PASSES) : (i += 1) {
        if (shader.*.pipelines[i] != null) rvn_vk.DestroyPipeline.?(g_vk.device, shader.*.pipelines[i], null);
    }
    if (shader.*.module != null) rvn_vk.DestroyShaderModule.?(g_vk.device, shader.*.module, null);
    shader.* = std.mem.zeroes(be.rvn_vk_shader_t);
}

export fn rvn_vk_shader_pipeline(id: raven.Rid, pass: [*c]be.rvn_vk_pass_t) vk.VkPipeline {
    const shader = rvn_vk_shader_find(id);
    const passes_base: [*c]be.rvn_vk_pass_t = &g_vk.passes;
    var slot: u32 = undefined;
    if (shader == null or pass == null) return null;
    slot = @truncate(@as(usize, @bitCast(pass - passes_base)));
    if (slot >= be.RVN_VK_MAX_PASSES) return null;
    if (shader.*.pipelines[slot] == null and shader.*.failed[slot] == raven.R_FALSE) {
        if (rvn_vk_pipeline_create(pass.*.render_pass, raven.R_FALSE, shader.*.module, &shader.*.pipelines[slot]) == raven.R_FALSE) {
            shader.*.failed[slot] = raven.R_TRUE;
            base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: the effect shader cannot be used (is it written with raven_effect.glsl?)");
        }
    }
    return shader.*.pipelines[slot];
}

// ---------------------------------------------------------------------------
//  Descriptor sets
// ---------------------------------------------------------------------------

export fn rvn_vk_set_allocate(set: [*c]vk.VkDescriptorSet, pool: [*c]vk.VkDescriptorPool) c_int {
    var allocation = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
    var i: u32 = undefined;

    allocation.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocation.descriptorSetCount = 1;
    allocation.pSetLayouts = &g_vk.set_layout;

    i = 0;
    while (i < g_vk.pool_count) : (i += 1) {
        if (g_vk.pool_used[i] < be.RVN_VK_SETS_PER_POOL) break;
    }
    if (i == g_vk.pool_count) {
        // every pool is full: add one
        var size: vk.VkDescriptorPoolSize = undefined;
        var info = std.mem.zeroes(vk.VkDescriptorPoolCreateInfo);
        var created: vk.VkDescriptorPool = undefined;
        size.@"type" = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        size.descriptorCount = be.RVN_VK_SETS_PER_POOL;
        info.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        info.flags = vk.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        info.maxSets = be.RVN_VK_SETS_PER_POOL;
        info.poolSizeCount = 1;
        info.pPoolSizes = &size;
        if (be.rvn_vk_failed(rvn_vk.CreateDescriptorPool.?(g_vk.device, &info, null, &created), "vkCreateDescriptorPool") != raven.R_FALSE) return raven.R_FALSE;
        if (g_vk.pool_count == g_vk.pool_cap) {
            g_vk.pool_cap = if (g_vk.pool_cap != 0) g_vk.pool_cap * 2 else 4;
            g_vk.pools = @ptrCast(@alignCast(base.rvn_realloc(@ptrCast(g_vk.pools), @sizeOf(vk.VkDescriptorPool) * @as(usize, g_vk.pool_cap))));
            g_vk.pool_used = @ptrCast(@alignCast(base.rvn_realloc(g_vk.pool_used, @sizeOf(u32) * @as(usize, g_vk.pool_cap))));
        }
        g_vk.pools[g_vk.pool_count] = created;
        g_vk.pool_used[g_vk.pool_count] = 0;
        g_vk.pool_count += 1;
    }

    allocation.descriptorPool = g_vk.pools[i];
    if (be.rvn_vk_failed(rvn_vk.AllocateDescriptorSets.?(g_vk.device, &allocation, set), "vkAllocateDescriptorSets") != raven.R_FALSE) return raven.R_FALSE;
    g_vk.pool_used[i] += 1;
    pool.* = g_vk.pools[i];
    return raven.R_TRUE;
}

export fn rvn_vk_set_free(set: vk.VkDescriptorSet, pool: vk.VkDescriptorPool) void {
    var i: u32 = undefined;
    if (set == null) return;
    _ = rvn_vk.FreeDescriptorSets.?(g_vk.device, pool, 1, &set);
    i = 0;
    while (i < g_vk.pool_count) : (i += 1) {
        if (g_vk.pools[i] == pool and g_vk.pool_used[i] > 0) g_vk.pool_used[i] -= 1;
    }
}

export fn rvn_vk_set_write(set: vk.VkDescriptorSet, view: vk.VkImageView, sampler: vk.VkSampler) void {
    var image: vk.VkDescriptorImageInfo = undefined;
    var write = std.mem.zeroes(vk.VkWriteDescriptorSet);
    image.sampler = sampler;
    image.imageView = view;
    image.imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    write.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = set;
    write.dstBinding = 0;
    write.descriptorCount = 1;
    write.descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &image;
    rvn_vk.UpdateDescriptorSets.?(g_vk.device, 1, &write, 0, null);
}

// Allocates and fills a backdrop set (set 1 of the UI pipeline).
export fn rvn_vk_backdrop_set_create(set: [*c]vk.VkDescriptorSet, sharp: vk.VkImageView, blurred: vk.VkImageView) c_int {
    var allocation = std.mem.zeroes(vk.VkDescriptorSetAllocateInfo);
    var images: [2]vk.VkDescriptorImageInfo = undefined;
    var write = std.mem.zeroes(vk.VkWriteDescriptorSet);

    allocation.sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocation.descriptorPool = g_vk.backdrop_pool;
    allocation.descriptorSetCount = 1;
    allocation.pSetLayouts = &g_vk.backdrop_layout;
    // too many windows with glass: the caller draws without a backdrop, nothing to report
    if (rvn_vk.AllocateDescriptorSets.?(g_vk.device, &allocation, set) < 0) {
        set.* = null;
        return raven.R_FALSE;
    }

    images[0].sampler = g_vk.sampler_linear;
    images[0].imageView = sharp;
    images[0].imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    images[1] = images[0];
    images[1].imageView = blurred;
    write.sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = set.*;
    write.dstBinding = 0;
    write.descriptorCount = 2;
    write.descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &images;
    rvn_vk.UpdateDescriptorSets.?(g_vk.device, 1, &write, 0, null);
    return raven.R_TRUE;
}

export fn rvn_vk_backdrop_set_destroy(set: vk.VkDescriptorSet) void {
    if (set != null) _ = rvn_vk.FreeDescriptorSets.?(g_vk.device, g_vk.backdrop_pool, 1, &set);
}
