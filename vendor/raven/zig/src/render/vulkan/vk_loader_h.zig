// Translated to Zig from vendor/raven/src/render/vulkan/vk_loader.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_loader.h
// Run-time loading of the Vulkan library.
//
// Raven never links against Vulkan: the loader library (vulkan-1.dll,
// libvulkan.so.1) is opened at run time and every entry point is resolved
// into the `rvn_vk` table, so an application starts even on a machine without
// a Vulkan driver (Rinit then fails cleanly).
//
// Call sites read like regular Vulkan with a dot:
//     rvn_vk.CreateImage.?(device, &info, null, &image);
//
// The Vulkan types themselves (the C file includes <vulkan/vulkan.h> with VK_NO_PROTOTYPES) are in vulkan_h.zig.
// The X-macro lists RVN_VK_{GLOBAL,INSTANCE,DEVICE}_FUNCTIONS are expanded below, in order, into the fields of
// rvn_vk_functions_t (the loader .zig file uses the same lists as comptime string arrays).

pub const vk = @import("vulkan_h.zig");

/// Entry points resolved without an instance.
pub const RVN_VK_GLOBAL_FUNCTIONS = [_][]const u8{ "CreateInstance", "EnumerateInstanceExtensionProperties", "EnumerateInstanceLayerProperties" };

/// Entry points resolved with vkGetInstanceProcAddr.
pub const RVN_VK_INSTANCE_FUNCTIONS = [_][]const u8{
    "DestroyInstance",
    "EnumeratePhysicalDevices",
    "GetPhysicalDeviceProperties",
    "GetPhysicalDeviceQueueFamilyProperties",
    "GetPhysicalDeviceMemoryProperties",
    "EnumerateDeviceExtensionProperties",
    "CreateDevice",
    "GetDeviceProcAddr",
    "DestroySurfaceKHR",
    "GetPhysicalDeviceSurfaceSupportKHR",
    "GetPhysicalDeviceSurfaceCapabilitiesKHR",
    "GetPhysicalDeviceSurfaceFormatsKHR",
    "GetPhysicalDeviceSurfacePresentModesKHR",
};

/// Entry points resolved with vkGetDeviceProcAddr: no dispatch overhead.
pub const RVN_VK_DEVICE_FUNCTIONS = [_][]const u8{
    "DestroyDevice",
    "GetDeviceQueue",
    "DeviceWaitIdle",
    "QueueSubmit",
    "CreateSwapchainKHR",
    "DestroySwapchainKHR",
    "GetSwapchainImagesKHR",
    "AcquireNextImageKHR",
    "QueuePresentKHR",
    "CreateImage",
    "DestroyImage",
    "GetImageMemoryRequirements",
    "BindImageMemory",
    "CreateImageView",
    "DestroyImageView",
    "CreateBuffer",
    "DestroyBuffer",
    "GetBufferMemoryRequirements",
    "BindBufferMemory",
    "AllocateMemory",
    "FreeMemory",
    "MapMemory",
    "UnmapMemory",
    "CreateSampler",
    "DestroySampler",
    "CreateShaderModule",
    "DestroyShaderModule",
    "CreateDescriptorSetLayout",
    "DestroyDescriptorSetLayout",
    "CreateDescriptorPool",
    "DestroyDescriptorPool",
    "AllocateDescriptorSets",
    "FreeDescriptorSets",
    "UpdateDescriptorSets",
    "CreatePipelineLayout",
    "DestroyPipelineLayout",
    "CreateRenderPass",
    "DestroyRenderPass",
    "CreateGraphicsPipelines",
    "DestroyPipeline",
    "CreateFramebuffer",
    "DestroyFramebuffer",
    "CreateCommandPool",
    "DestroyCommandPool",
    "AllocateCommandBuffers",
    "BeginCommandBuffer",
    "EndCommandBuffer",
    "CreateFence",
    "DestroyFence",
    "WaitForFences",
    "ResetFences",
    "CreateSemaphore",
    "DestroySemaphore",
    "CmdBeginRenderPass",
    "CmdEndRenderPass",
    "CmdBindPipeline",
    "CmdSetViewport",
    "CmdSetScissor",
    "CmdPushConstants",
    "CmdBindVertexBuffers",
    "CmdBindDescriptorSets",
    "CmdDraw",
    "CmdPipelineBarrier",
    "CmdCopyBufferToImage",
    "CmdCopyImageToBuffer",
};

/// The window-system headers are not included, so the entry points of the
/// surface extensions take their create-info structure as an untyped pointer.
pub const rvn_vk_create_surface_fn = ?*const fn (instance: vk.VkInstance, create_info: ?*const anyopaque, allocator: [*c]const vk.VkAllocationCallbacks, surface: [*c]vk.VkSurfaceKHR) callconv(.c) vk.VkResult;
/// vkGetMemoryFdKHR / vkGetMemoryWin32HandleKHR.
pub const rvn_vk_get_memory_handle_fn = ?*const fn (device: vk.VkDevice, info: ?*const anyopaque, handle: ?*anyopaque) callconv(.c) vk.VkResult;

pub const rvn_vk_functions_t = extern struct {
    GetInstanceProcAddr: vk.PFN_vkGetInstanceProcAddr,
    /// NULL on a Vulkan 1.0 loader.
    EnumerateInstanceVersion: vk.PFN_vkEnumerateInstanceVersion,

    CreateInstance: vk.PFN_vkCreateInstance,
    EnumerateInstanceExtensionProperties: vk.PFN_vkEnumerateInstanceExtensionProperties,
    EnumerateInstanceLayerProperties: vk.PFN_vkEnumerateInstanceLayerProperties,
    DestroyInstance: vk.PFN_vkDestroyInstance,
    EnumeratePhysicalDevices: vk.PFN_vkEnumeratePhysicalDevices,
    GetPhysicalDeviceProperties: vk.PFN_vkGetPhysicalDeviceProperties,
    GetPhysicalDeviceQueueFamilyProperties: vk.PFN_vkGetPhysicalDeviceQueueFamilyProperties,
    GetPhysicalDeviceMemoryProperties: vk.PFN_vkGetPhysicalDeviceMemoryProperties,
    EnumerateDeviceExtensionProperties: vk.PFN_vkEnumerateDeviceExtensionProperties,
    CreateDevice: vk.PFN_vkCreateDevice,
    GetDeviceProcAddr: vk.PFN_vkGetDeviceProcAddr,
    DestroySurfaceKHR: vk.PFN_vkDestroySurfaceKHR,
    GetPhysicalDeviceSurfaceSupportKHR: vk.PFN_vkGetPhysicalDeviceSurfaceSupportKHR,
    GetPhysicalDeviceSurfaceCapabilitiesKHR: vk.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
    GetPhysicalDeviceSurfaceFormatsKHR: vk.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR,
    GetPhysicalDeviceSurfacePresentModesKHR: vk.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR,
    DestroyDevice: vk.PFN_vkDestroyDevice,
    GetDeviceQueue: vk.PFN_vkGetDeviceQueue,
    DeviceWaitIdle: vk.PFN_vkDeviceWaitIdle,
    QueueSubmit: vk.PFN_vkQueueSubmit,
    CreateSwapchainKHR: vk.PFN_vkCreateSwapchainKHR,
    DestroySwapchainKHR: vk.PFN_vkDestroySwapchainKHR,
    GetSwapchainImagesKHR: vk.PFN_vkGetSwapchainImagesKHR,
    AcquireNextImageKHR: vk.PFN_vkAcquireNextImageKHR,
    QueuePresentKHR: vk.PFN_vkQueuePresentKHR,
    CreateImage: vk.PFN_vkCreateImage,
    DestroyImage: vk.PFN_vkDestroyImage,
    GetImageMemoryRequirements: vk.PFN_vkGetImageMemoryRequirements,
    BindImageMemory: vk.PFN_vkBindImageMemory,
    CreateImageView: vk.PFN_vkCreateImageView,
    DestroyImageView: vk.PFN_vkDestroyImageView,
    CreateBuffer: vk.PFN_vkCreateBuffer,
    DestroyBuffer: vk.PFN_vkDestroyBuffer,
    GetBufferMemoryRequirements: vk.PFN_vkGetBufferMemoryRequirements,
    BindBufferMemory: vk.PFN_vkBindBufferMemory,
    AllocateMemory: vk.PFN_vkAllocateMemory,
    FreeMemory: vk.PFN_vkFreeMemory,
    MapMemory: vk.PFN_vkMapMemory,
    UnmapMemory: vk.PFN_vkUnmapMemory,
    CreateSampler: vk.PFN_vkCreateSampler,
    DestroySampler: vk.PFN_vkDestroySampler,
    CreateShaderModule: vk.PFN_vkCreateShaderModule,
    DestroyShaderModule: vk.PFN_vkDestroyShaderModule,
    CreateDescriptorSetLayout: vk.PFN_vkCreateDescriptorSetLayout,
    DestroyDescriptorSetLayout: vk.PFN_vkDestroyDescriptorSetLayout,
    CreateDescriptorPool: vk.PFN_vkCreateDescriptorPool,
    DestroyDescriptorPool: vk.PFN_vkDestroyDescriptorPool,
    AllocateDescriptorSets: vk.PFN_vkAllocateDescriptorSets,
    FreeDescriptorSets: vk.PFN_vkFreeDescriptorSets,
    UpdateDescriptorSets: vk.PFN_vkUpdateDescriptorSets,
    CreatePipelineLayout: vk.PFN_vkCreatePipelineLayout,
    DestroyPipelineLayout: vk.PFN_vkDestroyPipelineLayout,
    CreateRenderPass: vk.PFN_vkCreateRenderPass,
    DestroyRenderPass: vk.PFN_vkDestroyRenderPass,
    CreateGraphicsPipelines: vk.PFN_vkCreateGraphicsPipelines,
    DestroyPipeline: vk.PFN_vkDestroyPipeline,
    CreateFramebuffer: vk.PFN_vkCreateFramebuffer,
    DestroyFramebuffer: vk.PFN_vkDestroyFramebuffer,
    CreateCommandPool: vk.PFN_vkCreateCommandPool,
    DestroyCommandPool: vk.PFN_vkDestroyCommandPool,
    AllocateCommandBuffers: vk.PFN_vkAllocateCommandBuffers,
    BeginCommandBuffer: vk.PFN_vkBeginCommandBuffer,
    EndCommandBuffer: vk.PFN_vkEndCommandBuffer,
    CreateFence: vk.PFN_vkCreateFence,
    DestroyFence: vk.PFN_vkDestroyFence,
    WaitForFences: vk.PFN_vkWaitForFences,
    ResetFences: vk.PFN_vkResetFences,
    CreateSemaphore: vk.PFN_vkCreateSemaphore,
    DestroySemaphore: vk.PFN_vkDestroySemaphore,
    CmdBeginRenderPass: vk.PFN_vkCmdBeginRenderPass,
    CmdEndRenderPass: vk.PFN_vkCmdEndRenderPass,
    CmdBindPipeline: vk.PFN_vkCmdBindPipeline,
    CmdSetViewport: vk.PFN_vkCmdSetViewport,
    CmdSetScissor: vk.PFN_vkCmdSetScissor,
    CmdPushConstants: vk.PFN_vkCmdPushConstants,
    CmdBindVertexBuffers: vk.PFN_vkCmdBindVertexBuffers,
    CmdBindDescriptorSets: vk.PFN_vkCmdBindDescriptorSets,
    CmdDraw: vk.PFN_vkCmdDraw,
    CmdPipelineBarrier: vk.PFN_vkCmdPipelineBarrier,
    CmdCopyBufferToImage: vk.PFN_vkCmdCopyBufferToImage,
    CmdCopyImageToBuffer: vk.PFN_vkCmdCopyImageToBuffer,

    // optional: NULL when the extension is not enabled
    CreateWin32SurfaceKHR: rvn_vk_create_surface_fn,
    CreateXlibSurfaceKHR: rvn_vk_create_surface_fn,
    CreateXcbSurfaceKHR: rvn_vk_create_surface_fn,
    CreateMetalSurfaceEXT: rvn_vk_create_surface_fn,
    CreateHeadlessSurfaceEXT: rvn_vk_create_surface_fn,
    CreateDebugUtilsMessengerEXT: vk.PFN_vkCreateDebugUtilsMessengerEXT,
    DestroyDebugUtilsMessengerEXT: vk.PFN_vkDestroyDebugUtilsMessengerEXT,
    GetMemoryFdKHR: rvn_vk_get_memory_handle_fn,
    GetMemoryWin32HandleKHR: rvn_vk_get_memory_handle_fn,
};
pub const struct_rvn_vk_functions_t = rvn_vk_functions_t;

pub extern var rvn_vk: rvn_vk_functions_t;

/// Opens the Vulkan library and resolves the global entry points.
pub extern fn rvn_vk_load_library() c_int;
pub extern fn rvn_vk_unload_library() void;
/// Resolves the instance-level entry points. Returns R_FALSE when one is missing.
pub extern fn rvn_vk_load_instance(instance: vk.VkInstance) c_int;
/// Resolves the device-level entry points. Returns R_FALSE when one is missing.
pub extern fn rvn_vk_load_device(device: vk.VkDevice) c_int;

/// Opens a shared library / resolves a symbol with the OS loader (also used for libX11-xcb).
pub extern fn rvn_vk_library_open(name: [*c]const u8) ?*anyopaque;
pub extern fn rvn_vk_library_symbol(library: ?*anyopaque, name: [*c]const u8) ?*anyopaque;
pub extern fn rvn_vk_library_close(library: ?*anyopaque) void;

/// "VK_ERROR_..." for error messages.
pub extern fn rvn_vk_result_name(result: vk.VkResult) [*c]const u8;
