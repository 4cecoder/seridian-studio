// Translated to Zig from the Vulkan headers (/usr/include/vulkan/vulkan_core.h; Apache-2.0 OR MIT) for
// vendor/raven/examples/viewport_vulkan/main.c. Modified by Seridian: C11 → Zig translation.
//
// The part of <vulkan/vulkan.h> that the viewport_vulkan example uses, declared by hand: handles, enum constants,
// flags, structs (extern struct, exact C layout) and the libvulkan entry points it calls (the program links with
// -lvulkan, like the C original). Type declarations copied from zig/src/render/vulkan/vulkan_h.zig (translate-c of
// vulkan_core.h); the functions are the prototypes of vulkan_core.h (VKAPI_CALL is the C calling convention on Linux).

// #define VK_NULL_HANDLE ((void*)0)   (64-bit: handles are pointers)
pub const VK_NULL_HANDLE = null;

pub const VkBool32 = u32;
pub const VkDeviceSize = u64;
pub const VkFlags = u32;
pub const VkSampleMask = u32;
pub const struct_VkPhysicalDevice_T = opaque {};
pub const VkPhysicalDevice = ?*struct_VkPhysicalDevice_T;
pub const struct_VkDevice_T = opaque {};
pub const VkDevice = ?*struct_VkDevice_T;
pub const struct_VkQueue_T = opaque {};
pub const VkQueue = ?*struct_VkQueue_T;
pub const struct_VkSemaphore_T = opaque {};
pub const VkSemaphore = ?*struct_VkSemaphore_T;
pub const struct_VkCommandBuffer_T = opaque {};
pub const VkCommandBuffer = ?*struct_VkCommandBuffer_T;
pub const struct_VkFence_T = opaque {};
pub const VkFence = ?*struct_VkFence_T;
pub const struct_VkDeviceMemory_T = opaque {};
pub const VkDeviceMemory = ?*struct_VkDeviceMemory_T;
pub const struct_VkImage_T = opaque {};
pub const VkImage = ?*struct_VkImage_T;
pub const struct_VkImageView_T = opaque {};
pub const VkImageView = ?*struct_VkImageView_T;
pub const struct_VkCommandPool_T = opaque {};
pub const VkCommandPool = ?*struct_VkCommandPool_T;
pub const struct_VkRenderPass_T = opaque {};
pub const VkRenderPass = ?*struct_VkRenderPass_T;
pub const struct_VkFramebuffer_T = opaque {};
pub const VkFramebuffer = ?*struct_VkFramebuffer_T;
pub const struct_VkShaderModule_T = opaque {};
pub const VkShaderModule = ?*struct_VkShaderModule_T;
pub const struct_VkPipelineCache_T = opaque {};
pub const VkPipelineCache = ?*struct_VkPipelineCache_T;
pub const struct_VkPipeline_T = opaque {};
pub const VkPipeline = ?*struct_VkPipeline_T;
pub const struct_VkPipelineLayout_T = opaque {};
pub const VkPipelineLayout = ?*struct_VkPipelineLayout_T;
pub const struct_VkDescriptorSetLayout_T = opaque {};
pub const VkDescriptorSetLayout = ?*struct_VkDescriptorSetLayout_T;
pub const VK_SUCCESS: c_int = 0;
pub const enum_VkResult = c_int;
pub const VkResult = enum_VkResult;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO: c_int = 4;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: c_int = 5;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO: c_int = 8;
pub const VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO: c_int = 14;
pub const VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO: c_int = 15;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: c_int = 16;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: c_int = 18;
pub const VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO: c_int = 19;
pub const VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO: c_int = 20;
pub const VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO: c_int = 22;
pub const VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO: c_int = 23;
pub const VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO: c_int = 24;
pub const VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO: c_int = 26;
pub const VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO: c_int = 27;
pub const VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO: c_int = 28;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: c_int = 30;
pub const VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO: c_int = 37;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO: c_int = 38;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: c_int = 39;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: c_int = 40;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: c_int = 42;
pub const VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO: c_int = 43;
pub const enum_VkStructureType = c_uint;
pub const VkStructureType = enum_VkStructureType;
pub const enum_VkSystemAllocationScope = c_uint;
pub const VkSystemAllocationScope = enum_VkSystemAllocationScope;
pub const enum_VkInternalAllocationType = c_uint;
pub const VkInternalAllocationType = enum_VkInternalAllocationType;
pub const VK_FORMAT_R8G8B8A8_UNORM: c_int = 37;
pub const enum_VkFormat = c_uint;
pub const VkFormat = enum_VkFormat;
pub const VK_IMAGE_TILING_OPTIMAL: c_int = 0;
pub const enum_VkImageTiling = c_uint;
pub const VkImageTiling = enum_VkImageTiling;
pub const VK_IMAGE_TYPE_2D: c_int = 1;
pub const enum_VkImageType = c_uint;
pub const VkImageType = enum_VkImageType;
pub const enum_VkSharingMode = c_uint;
pub const VkSharingMode = enum_VkSharingMode;
pub const VK_IMAGE_LAYOUT_UNDEFINED: c_int = 0;
pub const VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL: c_int = 2;
pub const VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL: c_int = 5;
pub const enum_VkImageLayout = c_uint;
pub const VkImageLayout = enum_VkImageLayout;
pub const enum_VkComponentSwizzle = c_uint;
pub const VkComponentSwizzle = enum_VkComponentSwizzle;
pub const VK_IMAGE_VIEW_TYPE_2D: c_int = 1;
pub const enum_VkImageViewType = c_uint;
pub const VkImageViewType = enum_VkImageViewType;
pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY: c_int = 0;
pub const enum_VkCommandBufferLevel = c_uint;
pub const VkCommandBufferLevel = enum_VkCommandBufferLevel;
pub const enum_VkCompareOp = c_uint;
pub const VkCompareOp = enum_VkCompareOp;
pub const VK_PIPELINE_BIND_POINT_GRAPHICS: c_int = 0;
pub const enum_VkPipelineBindPoint = c_uint;
pub const VkPipelineBindPoint = enum_VkPipelineBindPoint;
pub const enum_VkBlendFactor = c_uint;
pub const VkBlendFactor = enum_VkBlendFactor;
pub const enum_VkBlendOp = c_uint;
pub const VkBlendOp = enum_VkBlendOp;
pub const VK_DYNAMIC_STATE_VIEWPORT: c_int = 0;
pub const VK_DYNAMIC_STATE_SCISSOR: c_int = 1;
pub const enum_VkDynamicState = c_uint;
pub const VkDynamicState = enum_VkDynamicState;
pub const enum_VkFrontFace = c_uint;
pub const VkFrontFace = enum_VkFrontFace;
pub const enum_VkLogicOp = c_uint;
pub const VkLogicOp = enum_VkLogicOp;
pub const enum_VkStencilOp = c_uint;
pub const VkStencilOp = enum_VkStencilOp;
pub const enum_VkVertexInputRate = c_uint;
pub const VkVertexInputRate = enum_VkVertexInputRate;
pub const VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST: c_int = 3;
pub const enum_VkPrimitiveTopology = c_uint;
pub const VkPrimitiveTopology = enum_VkPrimitiveTopology;
pub const VK_POLYGON_MODE_FILL: c_int = 0;
pub const enum_VkPolygonMode = c_uint;
pub const VkPolygonMode = enum_VkPolygonMode;
pub const VK_ATTACHMENT_LOAD_OP_CLEAR: c_int = 1;
pub const VK_ATTACHMENT_LOAD_OP_DONT_CARE: c_int = 2;
pub const enum_VkAttachmentLoadOp = c_uint;
pub const VkAttachmentLoadOp = enum_VkAttachmentLoadOp;
pub const VK_ATTACHMENT_STORE_OP_STORE: c_int = 0;
pub const VK_ATTACHMENT_STORE_OP_DONT_CARE: c_int = 1;
pub const enum_VkAttachmentStoreOp = c_uint;
pub const VkAttachmentStoreOp = enum_VkAttachmentStoreOp;
pub const VK_SUBPASS_CONTENTS_INLINE: c_int = 0;
pub const enum_VkSubpassContents = c_uint;
pub const VkSubpassContents = enum_VkSubpassContents;
pub const VkImageCreateFlags = VkFlags;
pub const VK_SAMPLE_COUNT_1_BIT: c_int = 1;
pub const enum_VkSampleCountFlagBits = c_uint;
pub const VkSampleCountFlagBits = enum_VkSampleCountFlagBits;
pub const VK_IMAGE_USAGE_SAMPLED_BIT: c_int = 4;
pub const VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT: c_int = 16;
pub const VkImageUsageFlags = VkFlags;
pub const VkMemoryHeapFlags = VkFlags;
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: c_int = 1;
pub const VkMemoryPropertyFlags = VkFlags;
pub const VK_SHADER_STAGE_VERTEX_BIT: c_int = 1;
pub const VK_SHADER_STAGE_FRAGMENT_BIT: c_int = 16;
pub const enum_VkShaderStageFlagBits = c_uint;
pub const VkShaderStageFlagBits = enum_VkShaderStageFlagBits;
pub const VkShaderStageFlags = VkFlags;
pub const VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT: c_int = 128;
pub const VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT: c_int = 1024;
pub const VkPipelineStageFlags = VkFlags;
pub const VK_IMAGE_ASPECT_COLOR_BIT: c_int = 1;
pub const VkImageAspectFlags = VkFlags;
pub const VkFenceCreateFlags = VkFlags;
pub const VkQueryPipelineStatisticFlags = VkFlags;
pub const VkImageViewCreateFlags = VkFlags;
pub const VK_ACCESS_SHADER_READ_BIT: c_int = 32;
pub const VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT: c_int = 256;
pub const VkAccessFlags = VkFlags;
pub const VkDependencyFlags = VkFlags;
pub const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: c_int = 2;
pub const VkCommandPoolCreateFlags = VkFlags;
pub const VkQueryControlFlags = VkFlags;
pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: c_int = 1;
pub const VkCommandBufferUsageFlags = VkFlags;
pub const VkShaderModuleCreateFlags = VkFlags;
pub const VkPipelineCreateFlags = VkFlags;
pub const VkPipelineLayoutCreateFlags = VkFlags;
pub const VkPipelineShaderStageCreateFlags = VkFlags;
pub const VK_COLOR_COMPONENT_R_BIT: c_int = 1;
pub const VK_COLOR_COMPONENT_G_BIT: c_int = 2;
pub const VK_COLOR_COMPONENT_B_BIT: c_int = 4;
pub const VK_COLOR_COMPONENT_A_BIT: c_int = 8;
pub const VkColorComponentFlags = VkFlags;
pub const VK_CULL_MODE_NONE: c_int = 0;
pub const VkCullModeFlags = VkFlags;
pub const VkPipelineColorBlendStateCreateFlags = VkFlags;
pub const VkPipelineDepthStencilStateCreateFlags = VkFlags;
pub const VkPipelineDynamicStateCreateFlags = VkFlags;
pub const VkPipelineInputAssemblyStateCreateFlags = VkFlags;
pub const VkPipelineMultisampleStateCreateFlags = VkFlags;
pub const VkPipelineRasterizationStateCreateFlags = VkFlags;
pub const VkPipelineTessellationStateCreateFlags = VkFlags;
pub const VkPipelineVertexInputStateCreateFlags = VkFlags;
pub const VkPipelineViewportStateCreateFlags = VkFlags;
pub const VkAttachmentDescriptionFlags = VkFlags;
pub const VkFramebufferCreateFlags = VkFlags;
pub const VkRenderPassCreateFlags = VkFlags;
pub const VkSubpassDescriptionFlags = VkFlags;
pub const struct_VkExtent2D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
};
pub const VkExtent2D = struct_VkExtent2D;
pub const struct_VkExtent3D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
};
pub const VkExtent3D = struct_VkExtent3D;
pub const struct_VkOffset2D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};
pub const VkOffset2D = struct_VkOffset2D;
pub const struct_VkRect2D = extern struct {
    offset: VkOffset2D = @import("std").mem.zeroes(VkOffset2D),
    extent: VkExtent2D = @import("std").mem.zeroes(VkExtent2D),
};
pub const VkRect2D = struct_VkRect2D;
pub const PFN_vkAllocationFunction = ?*const fn (pUserData: ?*anyopaque, size: usize, alignment: usize, allocationScope: VkSystemAllocationScope) callconv(.c) ?*anyopaque;
pub const PFN_vkFreeFunction = ?*const fn (pUserData: ?*anyopaque, pMemory: ?*anyopaque) callconv(.c) void;
pub const PFN_vkInternalAllocationNotification = ?*const fn (pUserData: ?*anyopaque, size: usize, allocationType: VkInternalAllocationType, allocationScope: VkSystemAllocationScope) callconv(.c) void;
pub const PFN_vkInternalFreeNotification = ?*const fn (pUserData: ?*anyopaque, size: usize, allocationType: VkInternalAllocationType, allocationScope: VkSystemAllocationScope) callconv(.c) void;
pub const PFN_vkReallocationFunction = ?*const fn (pUserData: ?*anyopaque, pOriginal: ?*anyopaque, size: usize, alignment: usize, allocationScope: VkSystemAllocationScope) callconv(.c) ?*anyopaque;
pub const struct_VkAllocationCallbacks = extern struct {
    pUserData: ?*anyopaque = null,
    pfnAllocation: PFN_vkAllocationFunction = null,
    pfnReallocation: PFN_vkReallocationFunction = null,
    pfnFree: PFN_vkFreeFunction = null,
    pfnInternalAllocation: PFN_vkInternalAllocationNotification = null,
    pfnInternalFree: PFN_vkInternalFreeNotification = null,
};
pub const VkAllocationCallbacks = struct_VkAllocationCallbacks;
pub const struct_VkMemoryHeap = extern struct {
    size: VkDeviceSize = 0,
    flags: VkMemoryHeapFlags = 0,
};
pub const VkMemoryHeap = struct_VkMemoryHeap;
pub const struct_VkMemoryType = extern struct {
    propertyFlags: VkMemoryPropertyFlags = 0,
    heapIndex: u32 = 0,
};
pub const VkMemoryType = struct_VkMemoryType;
pub const struct_VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32 = 0,
    memoryTypes: [32]VkMemoryType = @import("std").mem.zeroes([32]VkMemoryType),
    memoryHeapCount: u32 = 0,
    memoryHeaps: [16]VkMemoryHeap = @import("std").mem.zeroes([16]VkMemoryHeap),
};
pub const VkPhysicalDeviceMemoryProperties = struct_VkPhysicalDeviceMemoryProperties;
pub const struct_VkSubmitInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: [*c]const VkSemaphore = null,
    pWaitDstStageMask: [*c]const VkPipelineStageFlags = null,
    commandBufferCount: u32 = 0,
    pCommandBuffers: [*c]const VkCommandBuffer = null,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: [*c]const VkSemaphore = null,
};
pub const VkSubmitInfo = struct_VkSubmitInfo;
pub const struct_VkMemoryAllocateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    allocationSize: VkDeviceSize = 0,
    memoryTypeIndex: u32 = 0,
};
pub const VkMemoryAllocateInfo = struct_VkMemoryAllocateInfo;
pub const struct_VkMemoryRequirements = extern struct {
    size: VkDeviceSize = 0,
    alignment: VkDeviceSize = 0,
    memoryTypeBits: u32 = 0,
};
pub const VkMemoryRequirements = struct_VkMemoryRequirements;
pub const struct_VkFenceCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkFenceCreateFlags = 0,
};
pub const VkFenceCreateInfo = struct_VkFenceCreateInfo;
pub const struct_VkImageCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkImageCreateFlags = 0,
    imageType: VkImageType = @import("std").mem.zeroes(VkImageType),
    format: VkFormat = @import("std").mem.zeroes(VkFormat),
    extent: VkExtent3D = @import("std").mem.zeroes(VkExtent3D),
    mipLevels: u32 = 0,
    arrayLayers: u32 = 0,
    samples: VkSampleCountFlagBits = @import("std").mem.zeroes(VkSampleCountFlagBits),
    tiling: VkImageTiling = @import("std").mem.zeroes(VkImageTiling),
    usage: VkImageUsageFlags = 0,
    sharingMode: VkSharingMode = @import("std").mem.zeroes(VkSharingMode),
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: [*c]const u32 = null,
    initialLayout: VkImageLayout = @import("std").mem.zeroes(VkImageLayout),
};
pub const VkImageCreateInfo = struct_VkImageCreateInfo;
pub const struct_VkComponentMapping = extern struct {
    r: VkComponentSwizzle = @import("std").mem.zeroes(VkComponentSwizzle),
    g: VkComponentSwizzle = @import("std").mem.zeroes(VkComponentSwizzle),
    b: VkComponentSwizzle = @import("std").mem.zeroes(VkComponentSwizzle),
    a: VkComponentSwizzle = @import("std").mem.zeroes(VkComponentSwizzle),
};
pub const VkComponentMapping = struct_VkComponentMapping;
pub const struct_VkImageSubresourceRange = extern struct {
    aspectMask: VkImageAspectFlags = 0,
    baseMipLevel: u32 = 0,
    levelCount: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 0,
};
pub const VkImageSubresourceRange = struct_VkImageSubresourceRange;
pub const struct_VkImageViewCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkImageViewCreateFlags = 0,
    image: VkImage = null,
    viewType: VkImageViewType = @import("std").mem.zeroes(VkImageViewType),
    format: VkFormat = @import("std").mem.zeroes(VkFormat),
    components: VkComponentMapping = @import("std").mem.zeroes(VkComponentMapping),
    subresourceRange: VkImageSubresourceRange = @import("std").mem.zeroes(VkImageSubresourceRange),
};
pub const VkImageViewCreateInfo = struct_VkImageViewCreateInfo;
pub const struct_VkCommandPoolCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkCommandPoolCreateFlags = 0,
    queueFamilyIndex: u32 = 0,
};
pub const VkCommandPoolCreateInfo = struct_VkCommandPoolCreateInfo;
pub const struct_VkCommandBufferAllocateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    commandPool: VkCommandPool = null,
    level: VkCommandBufferLevel = @import("std").mem.zeroes(VkCommandBufferLevel),
    commandBufferCount: u32 = 0,
};
pub const VkCommandBufferAllocateInfo = struct_VkCommandBufferAllocateInfo;
pub const struct_VkCommandBufferInheritanceInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    renderPass: VkRenderPass = null,
    subpass: u32 = 0,
    framebuffer: VkFramebuffer = null,
    occlusionQueryEnable: VkBool32 = 0,
    queryFlags: VkQueryControlFlags = 0,
    pipelineStatistics: VkQueryPipelineStatisticFlags = 0,
};
pub const VkCommandBufferInheritanceInfo = struct_VkCommandBufferInheritanceInfo;
pub const struct_VkCommandBufferBeginInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkCommandBufferUsageFlags = 0,
    pInheritanceInfo: [*c]const VkCommandBufferInheritanceInfo = null,
};
pub const VkCommandBufferBeginInfo = struct_VkCommandBufferBeginInfo;
pub const struct_VkShaderModuleCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkShaderModuleCreateFlags = 0,
    codeSize: usize = 0,
    pCode: [*c]const u32 = null,
};
pub const VkShaderModuleCreateInfo = struct_VkShaderModuleCreateInfo;
pub const struct_VkSpecializationMapEntry = extern struct {
    constantID: u32 = 0,
    offset: u32 = 0,
    size: usize = 0,
};
pub const VkSpecializationMapEntry = struct_VkSpecializationMapEntry;
pub const struct_VkSpecializationInfo = extern struct {
    mapEntryCount: u32 = 0,
    pMapEntries: [*c]const VkSpecializationMapEntry = null,
    dataSize: usize = 0,
    pData: ?*const anyopaque = null,
};
pub const VkSpecializationInfo = struct_VkSpecializationInfo;
pub const struct_VkPipelineShaderStageCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineShaderStageCreateFlags = 0,
    stage: VkShaderStageFlagBits = @import("std").mem.zeroes(VkShaderStageFlagBits),
    module: VkShaderModule = null,
    pName: [*c]const u8 = null,
    pSpecializationInfo: [*c]const VkSpecializationInfo = null,
};
pub const VkPipelineShaderStageCreateInfo = struct_VkPipelineShaderStageCreateInfo;
pub const struct_VkPushConstantRange = extern struct {
    stageFlags: VkShaderStageFlags = 0,
    offset: u32 = 0,
    size: u32 = 0,
};
pub const VkPushConstantRange = struct_VkPushConstantRange;
pub const struct_VkPipelineLayoutCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineLayoutCreateFlags = 0,
    setLayoutCount: u32 = 0,
    pSetLayouts: [*c]const VkDescriptorSetLayout = null,
    pushConstantRangeCount: u32 = 0,
    pPushConstantRanges: [*c]const VkPushConstantRange = null,
};
pub const VkPipelineLayoutCreateInfo = struct_VkPipelineLayoutCreateInfo;
pub const union_VkClearColorValue = extern union {
    float32: [4]f32,
    int32: [4]i32,
    uint32: [4]u32,
};
pub const VkClearColorValue = union_VkClearColorValue;
pub const struct_VkStencilOpState = extern struct {
    failOp: VkStencilOp = @import("std").mem.zeroes(VkStencilOp),
    passOp: VkStencilOp = @import("std").mem.zeroes(VkStencilOp),
    depthFailOp: VkStencilOp = @import("std").mem.zeroes(VkStencilOp),
    compareOp: VkCompareOp = @import("std").mem.zeroes(VkCompareOp),
    compareMask: u32 = 0,
    writeMask: u32 = 0,
    reference: u32 = 0,
};
pub const VkStencilOpState = struct_VkStencilOpState;
pub const struct_VkVertexInputAttributeDescription = extern struct {
    location: u32 = 0,
    binding: u32 = 0,
    format: VkFormat = @import("std").mem.zeroes(VkFormat),
    offset: u32 = 0,
};
pub const VkVertexInputAttributeDescription = struct_VkVertexInputAttributeDescription;
pub const struct_VkVertexInputBindingDescription = extern struct {
    binding: u32 = 0,
    stride: u32 = 0,
    inputRate: VkVertexInputRate = @import("std").mem.zeroes(VkVertexInputRate),
};
pub const VkVertexInputBindingDescription = struct_VkVertexInputBindingDescription;
pub const struct_VkViewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    minDepth: f32 = 0,
    maxDepth: f32 = 0,
};
pub const VkViewport = struct_VkViewport;
pub const struct_VkPipelineColorBlendAttachmentState = extern struct {
    blendEnable: VkBool32 = 0,
    srcColorBlendFactor: VkBlendFactor = @import("std").mem.zeroes(VkBlendFactor),
    dstColorBlendFactor: VkBlendFactor = @import("std").mem.zeroes(VkBlendFactor),
    colorBlendOp: VkBlendOp = @import("std").mem.zeroes(VkBlendOp),
    srcAlphaBlendFactor: VkBlendFactor = @import("std").mem.zeroes(VkBlendFactor),
    dstAlphaBlendFactor: VkBlendFactor = @import("std").mem.zeroes(VkBlendFactor),
    alphaBlendOp: VkBlendOp = @import("std").mem.zeroes(VkBlendOp),
    colorWriteMask: VkColorComponentFlags = 0,
};
pub const VkPipelineColorBlendAttachmentState = struct_VkPipelineColorBlendAttachmentState;
pub const struct_VkPipelineColorBlendStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineColorBlendStateCreateFlags = 0,
    logicOpEnable: VkBool32 = 0,
    logicOp: VkLogicOp = @import("std").mem.zeroes(VkLogicOp),
    attachmentCount: u32 = 0,
    pAttachments: [*c]const VkPipelineColorBlendAttachmentState = null,
    blendConstants: [4]f32 = @import("std").mem.zeroes([4]f32),
};
pub const VkPipelineColorBlendStateCreateInfo = struct_VkPipelineColorBlendStateCreateInfo;
pub const struct_VkPipelineDepthStencilStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineDepthStencilStateCreateFlags = 0,
    depthTestEnable: VkBool32 = 0,
    depthWriteEnable: VkBool32 = 0,
    depthCompareOp: VkCompareOp = @import("std").mem.zeroes(VkCompareOp),
    depthBoundsTestEnable: VkBool32 = 0,
    stencilTestEnable: VkBool32 = 0,
    front: VkStencilOpState = @import("std").mem.zeroes(VkStencilOpState),
    back: VkStencilOpState = @import("std").mem.zeroes(VkStencilOpState),
    minDepthBounds: f32 = 0,
    maxDepthBounds: f32 = 0,
};
pub const VkPipelineDepthStencilStateCreateInfo = struct_VkPipelineDepthStencilStateCreateInfo;
pub const struct_VkPipelineDynamicStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineDynamicStateCreateFlags = 0,
    dynamicStateCount: u32 = 0,
    pDynamicStates: [*c]const VkDynamicState = null,
};
pub const VkPipelineDynamicStateCreateInfo = struct_VkPipelineDynamicStateCreateInfo;
pub const struct_VkPipelineInputAssemblyStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineInputAssemblyStateCreateFlags = 0,
    topology: VkPrimitiveTopology = @import("std").mem.zeroes(VkPrimitiveTopology),
    primitiveRestartEnable: VkBool32 = 0,
};
pub const VkPipelineInputAssemblyStateCreateInfo = struct_VkPipelineInputAssemblyStateCreateInfo;
pub const struct_VkPipelineMultisampleStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineMultisampleStateCreateFlags = 0,
    rasterizationSamples: VkSampleCountFlagBits = @import("std").mem.zeroes(VkSampleCountFlagBits),
    sampleShadingEnable: VkBool32 = 0,
    minSampleShading: f32 = 0,
    pSampleMask: [*c]const VkSampleMask = null,
    alphaToCoverageEnable: VkBool32 = 0,
    alphaToOneEnable: VkBool32 = 0,
};
pub const VkPipelineMultisampleStateCreateInfo = struct_VkPipelineMultisampleStateCreateInfo;
pub const struct_VkPipelineRasterizationStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineRasterizationStateCreateFlags = 0,
    depthClampEnable: VkBool32 = 0,
    rasterizerDiscardEnable: VkBool32 = 0,
    polygonMode: VkPolygonMode = @import("std").mem.zeroes(VkPolygonMode),
    cullMode: VkCullModeFlags = 0,
    frontFace: VkFrontFace = @import("std").mem.zeroes(VkFrontFace),
    depthBiasEnable: VkBool32 = 0,
    depthBiasConstantFactor: f32 = 0,
    depthBiasClamp: f32 = 0,
    depthBiasSlopeFactor: f32 = 0,
    lineWidth: f32 = 0,
};
pub const VkPipelineRasterizationStateCreateInfo = struct_VkPipelineRasterizationStateCreateInfo;
pub const struct_VkPipelineTessellationStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineTessellationStateCreateFlags = 0,
    patchControlPoints: u32 = 0,
};
pub const VkPipelineTessellationStateCreateInfo = struct_VkPipelineTessellationStateCreateInfo;
pub const struct_VkPipelineVertexInputStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineVertexInputStateCreateFlags = 0,
    vertexBindingDescriptionCount: u32 = 0,
    pVertexBindingDescriptions: [*c]const VkVertexInputBindingDescription = null,
    vertexAttributeDescriptionCount: u32 = 0,
    pVertexAttributeDescriptions: [*c]const VkVertexInputAttributeDescription = null,
};
pub const VkPipelineVertexInputStateCreateInfo = struct_VkPipelineVertexInputStateCreateInfo;
pub const struct_VkPipelineViewportStateCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineViewportStateCreateFlags = 0,
    viewportCount: u32 = 0,
    pViewports: [*c]const VkViewport = null,
    scissorCount: u32 = 0,
    pScissors: [*c]const VkRect2D = null,
};
pub const VkPipelineViewportStateCreateInfo = struct_VkPipelineViewportStateCreateInfo;
pub const struct_VkGraphicsPipelineCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkPipelineCreateFlags = 0,
    stageCount: u32 = 0,
    pStages: [*c]const VkPipelineShaderStageCreateInfo = null,
    pVertexInputState: [*c]const VkPipelineVertexInputStateCreateInfo = null,
    pInputAssemblyState: [*c]const VkPipelineInputAssemblyStateCreateInfo = null,
    pTessellationState: [*c]const VkPipelineTessellationStateCreateInfo = null,
    pViewportState: [*c]const VkPipelineViewportStateCreateInfo = null,
    pRasterizationState: [*c]const VkPipelineRasterizationStateCreateInfo = null,
    pMultisampleState: [*c]const VkPipelineMultisampleStateCreateInfo = null,
    pDepthStencilState: [*c]const VkPipelineDepthStencilStateCreateInfo = null,
    pColorBlendState: [*c]const VkPipelineColorBlendStateCreateInfo = null,
    pDynamicState: [*c]const VkPipelineDynamicStateCreateInfo = null,
    layout: VkPipelineLayout = null,
    renderPass: VkRenderPass = null,
    subpass: u32 = 0,
    basePipelineHandle: VkPipeline = null,
    basePipelineIndex: i32 = 0,
};
pub const VkGraphicsPipelineCreateInfo = struct_VkGraphicsPipelineCreateInfo;
pub const struct_VkAttachmentDescription = extern struct {
    flags: VkAttachmentDescriptionFlags = 0,
    format: VkFormat = @import("std").mem.zeroes(VkFormat),
    samples: VkSampleCountFlagBits = @import("std").mem.zeroes(VkSampleCountFlagBits),
    loadOp: VkAttachmentLoadOp = @import("std").mem.zeroes(VkAttachmentLoadOp),
    storeOp: VkAttachmentStoreOp = @import("std").mem.zeroes(VkAttachmentStoreOp),
    stencilLoadOp: VkAttachmentLoadOp = @import("std").mem.zeroes(VkAttachmentLoadOp),
    stencilStoreOp: VkAttachmentStoreOp = @import("std").mem.zeroes(VkAttachmentStoreOp),
    initialLayout: VkImageLayout = @import("std").mem.zeroes(VkImageLayout),
    finalLayout: VkImageLayout = @import("std").mem.zeroes(VkImageLayout),
};
pub const VkAttachmentDescription = struct_VkAttachmentDescription;
pub const struct_VkAttachmentReference = extern struct {
    attachment: u32 = 0,
    layout: VkImageLayout = @import("std").mem.zeroes(VkImageLayout),
};
pub const VkAttachmentReference = struct_VkAttachmentReference;
pub const struct_VkFramebufferCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkFramebufferCreateFlags = 0,
    renderPass: VkRenderPass = null,
    attachmentCount: u32 = 0,
    pAttachments: [*c]const VkImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    layers: u32 = 0,
};
pub const VkFramebufferCreateInfo = struct_VkFramebufferCreateInfo;
pub const struct_VkSubpassDependency = extern struct {
    srcSubpass: u32 = 0,
    dstSubpass: u32 = 0,
    srcStageMask: VkPipelineStageFlags = 0,
    dstStageMask: VkPipelineStageFlags = 0,
    srcAccessMask: VkAccessFlags = 0,
    dstAccessMask: VkAccessFlags = 0,
    dependencyFlags: VkDependencyFlags = 0,
};
pub const VkSubpassDependency = struct_VkSubpassDependency;
pub const struct_VkSubpassDescription = extern struct {
    flags: VkSubpassDescriptionFlags = 0,
    pipelineBindPoint: VkPipelineBindPoint = @import("std").mem.zeroes(VkPipelineBindPoint),
    inputAttachmentCount: u32 = 0,
    pInputAttachments: [*c]const VkAttachmentReference = null,
    colorAttachmentCount: u32 = 0,
    pColorAttachments: [*c]const VkAttachmentReference = null,
    pResolveAttachments: [*c]const VkAttachmentReference = null,
    pDepthStencilAttachment: [*c]const VkAttachmentReference = null,
    preserveAttachmentCount: u32 = 0,
    pPreserveAttachments: [*c]const u32 = null,
};
pub const VkSubpassDescription = struct_VkSubpassDescription;
pub const struct_VkRenderPassCreateInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    flags: VkRenderPassCreateFlags = 0,
    attachmentCount: u32 = 0,
    pAttachments: [*c]const VkAttachmentDescription = null,
    subpassCount: u32 = 0,
    pSubpasses: [*c]const VkSubpassDescription = null,
    dependencyCount: u32 = 0,
    pDependencies: [*c]const VkSubpassDependency = null,
};
pub const VkRenderPassCreateInfo = struct_VkRenderPassCreateInfo;
pub const struct_VkClearDepthStencilValue = extern struct {
    depth: f32 = 0,
    stencil: u32 = 0,
};
pub const VkClearDepthStencilValue = struct_VkClearDepthStencilValue;
pub const union_VkClearValue = extern union {
    color: VkClearColorValue,
    depthStencil: VkClearDepthStencilValue,
};
pub const VkClearValue = union_VkClearValue;
pub const struct_VkRenderPassBeginInfo = extern struct {
    sType: VkStructureType = @import("std").mem.zeroes(VkStructureType),
    pNext: ?*const anyopaque = null,
    renderPass: VkRenderPass = null,
    framebuffer: VkFramebuffer = null,
    renderArea: VkRect2D = @import("std").mem.zeroes(VkRect2D),
    clearValueCount: u32 = 0,
    pClearValues: [*c]const VkClearValue = null,
};
pub const VkRenderPassBeginInfo = struct_VkRenderPassBeginInfo;
pub const VK_TRUE = @as(c_uint, 1);
pub const VK_SUBPASS_EXTERNAL = ~@as(c_uint, 0);

pub extern "c" fn vkGetPhysicalDeviceMemoryProperties(physicalDevice: VkPhysicalDevice, pMemoryProperties: [*c]VkPhysicalDeviceMemoryProperties) void;
pub extern "c" fn vkQueueSubmit(queue: VkQueue, submitCount: u32, pSubmits: [*c]const VkSubmitInfo, fence: VkFence) VkResult;
pub extern "c" fn vkDeviceWaitIdle(device: VkDevice) VkResult;
pub extern "c" fn vkAllocateMemory(device: VkDevice, pAllocateInfo: [*c]const VkMemoryAllocateInfo, pAllocator: [*c]const VkAllocationCallbacks, pMemory: [*c]VkDeviceMemory) VkResult;
pub extern "c" fn vkFreeMemory(device: VkDevice, memory: VkDeviceMemory, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkBindImageMemory(device: VkDevice, image: VkImage, memory: VkDeviceMemory, memoryOffset: VkDeviceSize) VkResult;
pub extern "c" fn vkGetImageMemoryRequirements(device: VkDevice, image: VkImage, pMemoryRequirements: [*c]VkMemoryRequirements) void;
pub extern "c" fn vkCreateFence(device: VkDevice, pCreateInfo: [*c]const VkFenceCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pFence: [*c]VkFence) VkResult;
pub extern "c" fn vkDestroyFence(device: VkDevice, fence: VkFence, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkResetFences(device: VkDevice, fenceCount: u32, pFences: [*c]const VkFence) VkResult;
pub extern "c" fn vkWaitForFences(device: VkDevice, fenceCount: u32, pFences: [*c]const VkFence, waitAll: VkBool32, timeout: u64) VkResult;
pub extern "c" fn vkCreateImage(device: VkDevice, pCreateInfo: [*c]const VkImageCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pImage: [*c]VkImage) VkResult;
pub extern "c" fn vkDestroyImage(device: VkDevice, image: VkImage, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkCreateImageView(device: VkDevice, pCreateInfo: [*c]const VkImageViewCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pView: [*c]VkImageView) VkResult;
pub extern "c" fn vkDestroyImageView(device: VkDevice, imageView: VkImageView, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkCreateCommandPool(device: VkDevice, pCreateInfo: [*c]const VkCommandPoolCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pCommandPool: [*c]VkCommandPool) VkResult;
pub extern "c" fn vkDestroyCommandPool(device: VkDevice, commandPool: VkCommandPool, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkAllocateCommandBuffers(device: VkDevice, pAllocateInfo: [*c]const VkCommandBufferAllocateInfo, pCommandBuffers: [*c]VkCommandBuffer) VkResult;
pub extern "c" fn vkBeginCommandBuffer(commandBuffer: VkCommandBuffer, pBeginInfo: [*c]const VkCommandBufferBeginInfo) VkResult;
pub extern "c" fn vkEndCommandBuffer(commandBuffer: VkCommandBuffer) VkResult;
pub extern "c" fn vkCreateShaderModule(device: VkDevice, pCreateInfo: [*c]const VkShaderModuleCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pShaderModule: [*c]VkShaderModule) VkResult;
pub extern "c" fn vkDestroyShaderModule(device: VkDevice, shaderModule: VkShaderModule, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkDestroyPipeline(device: VkDevice, pipeline: VkPipeline, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkCreatePipelineLayout(device: VkDevice, pCreateInfo: [*c]const VkPipelineLayoutCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pPipelineLayout: [*c]VkPipelineLayout) VkResult;
pub extern "c" fn vkDestroyPipelineLayout(device: VkDevice, pipelineLayout: VkPipelineLayout, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkCmdBindPipeline(commandBuffer: VkCommandBuffer, pipelineBindPoint: VkPipelineBindPoint, pipeline: VkPipeline) void;
pub extern "c" fn vkCmdPushConstants(commandBuffer: VkCommandBuffer, layout: VkPipelineLayout, stageFlags: VkShaderStageFlags, offset: u32, size: u32, pValues: ?*const anyopaque) void;
pub extern "c" fn vkCreateGraphicsPipelines(device: VkDevice, pipelineCache: VkPipelineCache, createInfoCount: u32, pCreateInfos: [*c]const VkGraphicsPipelineCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pPipelines: [*c]VkPipeline) VkResult;
pub extern "c" fn vkCreateFramebuffer(device: VkDevice, pCreateInfo: [*c]const VkFramebufferCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pFramebuffer: [*c]VkFramebuffer) VkResult;
pub extern "c" fn vkDestroyFramebuffer(device: VkDevice, framebuffer: VkFramebuffer, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkCreateRenderPass(device: VkDevice, pCreateInfo: [*c]const VkRenderPassCreateInfo, pAllocator: [*c]const VkAllocationCallbacks, pRenderPass: [*c]VkRenderPass) VkResult;
pub extern "c" fn vkDestroyRenderPass(device: VkDevice, renderPass: VkRenderPass, pAllocator: [*c]const VkAllocationCallbacks) void;
pub extern "c" fn vkCmdSetViewport(commandBuffer: VkCommandBuffer, firstViewport: u32, viewportCount: u32, pViewports: [*c]const VkViewport) void;
pub extern "c" fn vkCmdSetScissor(commandBuffer: VkCommandBuffer, firstScissor: u32, scissorCount: u32, pScissors: [*c]const VkRect2D) void;
pub extern "c" fn vkCmdDraw(commandBuffer: VkCommandBuffer, vertexCount: u32, instanceCount: u32, firstVertex: u32, firstInstance: u32) void;
pub extern "c" fn vkCmdBeginRenderPass(commandBuffer: VkCommandBuffer, pRenderPassBegin: [*c]const VkRenderPassBeginInfo, contents: VkSubpassContents) void;
pub extern "c" fn vkCmdEndRenderPass(commandBuffer: VkCommandBuffer) void;
