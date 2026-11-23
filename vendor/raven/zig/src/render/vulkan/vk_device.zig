// Translated to Zig from vendor/raven/src/render/vulkan/vk_device.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_device.c
// Instance, physical device selection, logical device and memory helpers.
//
// Raven either creates its own instance and device, or adopts the ones of the
// application (Rvulkan_set_external_device) so that images can be shared
// with the renderer of the application without any copy.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const libc = @import("../../sys/libc.zig");
const be = @import("vk_backend_h.zig");
const vk = be.vk;
const loader = be.loader;

export var g_vk: be.rvn_vk_state_t = std.mem.zeroes(be.rvn_vk_state_t);
export var g_vk_config: be.rvn_vk_config_t = std.mem.zeroes(be.rvn_vk_config_t);

const RVN_VK_MAX_EXTENSIONS = 16;

const RVN_VK_EXTERNAL_MEMORY_EXTENSION: [*c]const u8 = if (builtin.os.tag == .windows)
    "VK_KHR_external_memory_win32"
else
    "VK_KHR_external_memory_fd";

const UINT32_MAX: u32 = std.math.maxInt(u32);

export fn rvn_vk_failed(result: vk.VkResult, what: [*c]const u8) c_int {
    if (result >= 0) return raven.R_FALSE;
    base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: %s failed (%s)", what, loader.rvn_vk_result_name(result));
    return raven.R_TRUE;
}

export fn rvn_vk_queue_lock() void {
    if (g_vk_config.lock) |lock| lock(g_vk_config.lock_user_data);
}

export fn rvn_vk_queue_unlock() void {
    if (g_vk_config.unlock) |unlock| unlock(g_vk_config.lock_user_data);
}

// ---------------------------------------------------------------------------
//  Extensions
// ---------------------------------------------------------------------------

fn rvn_vk_has_extension(list: [*c]const vk.VkExtensionProperties, count: u32, name: [*c]const u8) c_int {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (libc.strcmp(&list[i].extensionName, name) == 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

fn rvn_vk_enumerate_instance_extensions(count: [*c]u32) [*c]vk.VkExtensionProperties {
    var list: [*c]vk.VkExtensionProperties = undefined;
    count.* = 0;
    if (loader.rvn_vk.EnumerateInstanceExtensionProperties.?(null, count, null) < 0 or count.* == 0) return null;
    list = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(vk.VkExtensionProperties) * @as(usize, count.*))));
    if (loader.rvn_vk.EnumerateInstanceExtensionProperties.?(null, count, list) < 0) count.* = 0;
    return list;
}

// Surface extensions of the window systems Raven can run on. X11 windows work
// with either the Xlib or the XCB flavor: drivers do not all expose both.
const g_vk_surface_extensions: []const [*c]const u8 = if (builtin.os.tag == .windows)
    &[_][*c]const u8{ "VK_KHR_win32_surface", "VK_EXT_headless_surface" }
else if (builtin.os.tag.isDarwin())
    &[_][*c]const u8{ "VK_EXT_metal_surface", "VK_KHR_portability_enumeration", "VK_EXT_headless_surface" }
else
    &[_][*c]const u8{ "VK_KHR_xlib_surface", "VK_KHR_xcb_surface", "VK_EXT_headless_surface" };

export fn rvn_vk_instance_extensions(count: [*c]u32) [*c]const [*c]const u8 {
    const S = struct {
        // static const char* names[RVN_VK_MAX_EXTENSIONS];
        var names: [RVN_VK_MAX_EXTENSIONS][*c]const u8 = std.mem.zeroes([RVN_VK_MAX_EXTENSIONS][*c]const u8);
    };
    var available: [*c]vk.VkExtensionProperties = undefined;
    var available_count: u32 = 0;
    var used: u32 = 0;
    var i: usize = 0;

    count.* = 0;
    if (loader.rvn_vk_load_library() == raven.R_FALSE) return null;
    available = rvn_vk_enumerate_instance_extensions(&available_count);

    S.names[used] = "VK_KHR_surface";
    used += 1;
    while (i < g_vk_surface_extensions.len) : (i += 1) {
        if (rvn_vk_has_extension(available, available_count, g_vk_surface_extensions[i]) != raven.R_FALSE) {
            S.names[used] = g_vk_surface_extensions[i];
            used += 1;
        }
    }
    base.rvn_free(available);
    count.* = used;
    return &S.names;
}

export fn rvn_vk_device_extensions(count: [*c]u32) [*c]const [*c]const u8 {
    const S = struct {
        // static const char* const names[] = { "VK_KHR_swapchain" };
        const names = [_][*c]const u8{"VK_KHR_swapchain"};
    };
    count.* = @as(u32, S.names.len);
    return &S.names;
}

// ---------------------------------------------------------------------------
//  Validation messages
// ---------------------------------------------------------------------------

fn rvn_vk_debug_callback(
    severity: vk.VkDebugUtilsMessageSeverityFlagBitsEXT,
    types: vk.VkDebugUtilsMessageTypeFlagsEXT,
    data: [*c]const vk.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    _ = types;
    _ = user_data;
    const message: [*c]const u8 = if (data != null and data.*.pMessage != null) data.*.pMessage else "";
    const level: raven.RSeverity = if ((severity & vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) != 0)
        raven.R_SEVERITY_ERROR
    else
        raven.R_SEVERITY_WARNING;
    base.rvn_error(raven.R_ERROR_BACKEND, level, "Vulkan validation: %s", message);
    return vk.VK_FALSE;
}

// ---------------------------------------------------------------------------
//  Instance
// ---------------------------------------------------------------------------

fn rvn_vk_create_instance() c_int {
    var application: vk.VkApplicationInfo = undefined;
    var info: vk.VkInstanceCreateInfo = undefined;
    var messenger: vk.VkDebugUtilsMessengerCreateInfoEXT = undefined;
    var available: [*c]vk.VkExtensionProperties = undefined;
    var extensions: [RVN_VK_MAX_EXTENSIONS][*c]const u8 = undefined;
    var required: [*c]const [*c]const u8 = undefined;
    var layers: [1][*c]const u8 = undefined;
    var available_count: u32 = 0;
    var required_count: u32 = 0;
    var extension_count: u32 = 0;
    var layer_count: u32 = 0;
    var i: u32 = undefined;
    var loader_version: u32 = vk.VK_API_VERSION_1_0;
    var debug: c_int = raven.R_FALSE;

    required = rvn_vk_instance_extensions(&required_count);
    if (required_count < 2) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: the driver cannot present to a window (no surface extension)");
        return raven.R_FALSE;
    }
    i = 0;
    while (i < required_count) : (i += 1) {
        extensions[extension_count] = required[i];
        extension_count += 1;
    }

    if (loader.rvn_vk.EnumerateInstanceVersion) |enumerate_instance_version| {
        _ = enumerate_instance_version(&loader_version);
    }

    if (g_vk.info.enable_validation != raven.R_FALSE) {
        var layer_list: [*c]vk.VkLayerProperties = undefined;
        var count: u32 = 0;
        _ = loader.rvn_vk.EnumerateInstanceLayerProperties.?(&count, null);
        layer_list = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(vk.VkLayerProperties) * (@as(usize, count) + 1))));
        _ = loader.rvn_vk.EnumerateInstanceLayerProperties.?(&count, layer_list);
        i = 0;
        while (i < count) : (i += 1) {
            if (libc.strcmp(&layer_list[i].layerName, "VK_LAYER_KHRONOS_validation") == 0) {
                layers[layer_count] = "VK_LAYER_KHRONOS_validation";
                layer_count += 1;
            }
        }
        base.rvn_free(layer_list);
        if (layer_count == 0) {
            base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_WEAK_WARNING, "Vulkan: validation was requested but VK_LAYER_KHRONOS_validation is not installed");
        }
        available = rvn_vk_enumerate_instance_extensions(&available_count);
        if (layer_count != 0 and rvn_vk_has_extension(available, available_count, "VK_EXT_debug_utils") != raven.R_FALSE) {
            extensions[extension_count] = "VK_EXT_debug_utils";
            extension_count += 1;
            debug = raven.R_TRUE;
        }
        base.rvn_free(available);
    }

    @memset(std.mem.asBytes(&application), 0); // memset(&application, 0, sizeof(application));
    application.sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    application.pApplicationName = if (g_vk.info.app_name != null) g_vk.info.app_name else "Raven application";
    application.pEngineName = "Raven";
    application.engineVersion = vk.VK_MAKE_VERSION(0, 1, 0);
    // 1.1 only brings external memory in core; everything else is Vulkan 1.0
    application.apiVersion = if (loader_version >= vk.VK_API_VERSION_1_1) vk.VK_API_VERSION_1_1 else vk.VK_API_VERSION_1_0;

    @memset(std.mem.asBytes(&messenger), 0); // memset(&messenger, 0, sizeof(messenger));
    messenger.sType = vk.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    messenger.messageSeverity = vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | vk.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    messenger.messageType = vk.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | vk.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
        vk.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    messenger.pfnUserCallback = &rvn_vk_debug_callback;

    @memset(std.mem.asBytes(&info), 0); // memset(&info, 0, sizeof(info));
    info.sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    if (builtin.os.tag.isDarwin()) {
        // MoltenVK exposes portability devices through this enumeration flag.
        i = 0;
        while (i < extension_count) : (i += 1) {
            if (libc.strcmp(extensions[i], "VK_KHR_portability_enumeration") == 0) {
                info.flags |= 0x00000001; // VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR
                break;
            }
        }
    }
    info.pApplicationInfo = &application;
    info.enabledExtensionCount = extension_count;
    info.ppEnabledExtensionNames = &extensions;
    info.enabledLayerCount = layer_count;
    info.ppEnabledLayerNames = &layers;
    // also reports problems of instance creation itself
    if (debug != raven.R_FALSE) info.pNext = &messenger;

    const result = loader.rvn_vk.CreateInstance.?(&info, null, &g_vk.instance);
    if (rvn_vk_failed(result, "vkCreateInstance") != raven.R_FALSE) return raven.R_FALSE;
    if (loader.rvn_vk_load_instance(g_vk.instance) == raven.R_FALSE) return raven.R_FALSE;

    if (debug != raven.R_FALSE) {
        if (loader.rvn_vk.CreateDebugUtilsMessengerEXT) |create_messenger| {
            _ = create_messenger(g_vk.instance, &messenger, null, &g_vk.messenger);
        }
    }
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Physical device
// ---------------------------------------------------------------------------

fn rvn_vk_device_has_extension(device: vk.VkPhysicalDevice, name: [*c]const u8) c_int {
    var list: [*c]vk.VkExtensionProperties = undefined;
    var count: u32 = 0;
    var found: c_int = undefined;
    if (loader.rvn_vk.EnumerateDeviceExtensionProperties.?(device, null, &count, null) < 0 or count == 0) return raven.R_FALSE;
    list = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(vk.VkExtensionProperties) * @as(usize, count))));
    if (loader.rvn_vk.EnumerateDeviceExtensionProperties.?(device, null, &count, list) < 0) count = 0;
    found = rvn_vk_has_extension(list, count, name);
    base.rvn_free(list);
    return found;
}

// First queue family able to draw, or UINT32_MAX.
fn rvn_vk_graphics_family(device: vk.VkPhysicalDevice) u32 {
    var families: [32]vk.VkQueueFamilyProperties = undefined;
    var count: u32 = @as(u32, families.len);
    var i: u32 = undefined;
    loader.rvn_vk.GetPhysicalDeviceQueueFamilyProperties.?(device, &count, &families);
    i = 0;
    while (i < count) : (i += 1) {
        if (families[i].queueCount > 0 and (families[i].queueFlags & vk.VK_QUEUE_GRAPHICS_BIT) != 0) return i;
    }
    return UINT32_MAX;
}

fn rvn_vk_device_score(type_: vk.VkPhysicalDeviceType) c_int {
    switch (type_) {
        vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => return 5,
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => return 4,
        vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => return 3,
        vk.VK_PHYSICAL_DEVICE_TYPE_CPU => return 1,
        else => return 2,
    }
}

// A UI needs very little from the GPU, so any device that can draw and
// present is accepted; discrete GPUs are preferred. The environment variable
// RAVEN_VK_DEVICE=<index> forces a choice (multi-GPU machines).
fn rvn_vk_pick_physical_device() c_int {
    var devices: [16]vk.VkPhysicalDevice = undefined;
    var count: u32 = @as(u32, devices.len);
    var i: u32 = undefined;
    var best_score: c_int = -1;
    const forced = libc.getenv("RAVEN_VK_DEVICE");
    const result = loader.rvn_vk.EnumeratePhysicalDevices.?(g_vk.instance, &count, &devices);

    if (result < 0 or count == 0) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: no graphics device found");
        return raven.R_FALSE;
    }
    i = 0;
    while (i < count) : (i += 1) {
        var properties: vk.VkPhysicalDeviceProperties = undefined;
        const family = rvn_vk_graphics_family(devices[i]);
        var score: c_int = undefined;
        if (family == UINT32_MAX or rvn_vk_device_has_extension(devices[i], "VK_KHR_swapchain") == raven.R_FALSE) continue;
        loader.rvn_vk.GetPhysicalDeviceProperties.?(devices[i], &properties);
        score = rvn_vk_device_score(properties.deviceType);
        if (forced != null and @as(u32, @bitCast(libc.atoi(forced))) == i) score = 100;
        if (score > best_score) {
            best_score = score;
            g_vk.physical_device = devices[i];
            g_vk.queue_family = family;
        }
    }
    if (best_score < 0) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: no device can render to a window (VK_KHR_swapchain missing)");
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Device
// ---------------------------------------------------------------------------

fn rvn_vk_create_device() c_int {
    var queue: vk.VkDeviceQueueCreateInfo = undefined;
    var info: vk.VkDeviceCreateInfo = undefined;
    var properties: vk.VkPhysicalDeviceProperties = undefined;
    var extensions: [RVN_VK_MAX_EXTENSIONS][*c]const u8 = undefined;
    var required: [*c]const [*c]const u8 = undefined;
    var required_count: u32 = 0;
    var extension_count: u32 = 0;
    var i: u32 = undefined;
    const priority: f32 = 1.0;
    var share: c_int = undefined;

    required = rvn_vk_device_extensions(&required_count);
    i = 0;
    while (i < required_count) : (i += 1) {
        extensions[extension_count] = required[i];
        extension_count += 1;
    }
    if (builtin.os.tag.isDarwin()) {
        // MoltenVK reports VK_KHR_portability_subset on conformant portability
        // devices and Vulkan requires applications to enable it when advertised.
        if (rvn_vk_device_has_extension(g_vk.physical_device, "VK_KHR_portability_subset") != raven.R_FALSE) {
            extensions[extension_count] = "VK_KHR_portability_subset";
            extension_count += 1;
        }
    }

    // optional: textures whose memory can be imported by OpenGL or another device
    loader.rvn_vk.GetPhysicalDeviceProperties.?(g_vk.physical_device, &properties);
    share = @intFromBool(properties.apiVersion >= vk.VK_API_VERSION_1_1 and g_vk.api_version >= vk.VK_API_VERSION_1_1 and
        rvn_vk_device_has_extension(g_vk.physical_device, RVN_VK_EXTERNAL_MEMORY_EXTENSION) != raven.R_FALSE);
    if (share != raven.R_FALSE) {
        extensions[extension_count] = RVN_VK_EXTERNAL_MEMORY_EXTENSION;
        extension_count += 1;
    }

    @memset(std.mem.asBytes(&queue), 0); // memset(&queue, 0, sizeof(queue));
    queue.sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue.queueFamilyIndex = g_vk.queue_family;
    queue.queueCount = 1;
    queue.pQueuePriorities = &priority;

    @memset(std.mem.asBytes(&info), 0); // memset(&info, 0, sizeof(info));
    info.sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    info.queueCreateInfoCount = 1;
    info.pQueueCreateInfos = &queue;
    info.enabledExtensionCount = extension_count;
    info.ppEnabledExtensionNames = &extensions;

    const result = loader.rvn_vk.CreateDevice.?(g_vk.physical_device, &info, null, &g_vk.device);
    if (rvn_vk_failed(result, "vkCreateDevice") != raven.R_FALSE) return raven.R_FALSE;
    if (loader.rvn_vk_load_device(g_vk.device) == raven.R_FALSE) return raven.R_FALSE;
    loader.rvn_vk.GetDeviceQueue.?(g_vk.device, g_vk.queue_family, 0, &g_vk.queue);
    return raven.R_TRUE;
}

export fn rvn_vk_device_init() c_int {
    var properties: vk.VkPhysicalDeviceProperties = undefined;

    if (loader.rvn_vk_load_library() == raven.R_FALSE) return raven.R_FALSE;

    if (g_vk_config.external != raven.R_FALSE) {
        // the application owns everything: only resolve the entry points
        g_vk.external = raven.R_TRUE;
        g_vk.instance = g_vk_config.instance;
        g_vk.physical_device = g_vk_config.physical_device;
        g_vk.device = g_vk_config.device;
        g_vk.queue = g_vk_config.queue;
        g_vk.queue_family = g_vk_config.queue_family;
        if (g_vk.instance == null or g_vk.physical_device == null or g_vk.device == null or g_vk.queue == null) {
            base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rvulkan_set_external_device: NULL handle");
            return raven.R_FALSE;
        }
        if (loader.rvn_vk_load_instance(g_vk.instance) == raven.R_FALSE or loader.rvn_vk_load_device(g_vk.device) == raven.R_FALSE) {
            return raven.R_FALSE;
        }
        g_vk.api_version = vk.VK_API_VERSION_1_0;
    } else {
        var loader_version: u32 = vk.VK_API_VERSION_1_0;
        if (loader.rvn_vk.EnumerateInstanceVersion) |enumerate_instance_version| {
            _ = enumerate_instance_version(&loader_version);
        }
        g_vk.api_version = if (loader_version >= vk.VK_API_VERSION_1_1) vk.VK_API_VERSION_1_1 else vk.VK_API_VERSION_1_0;
        if (rvn_vk_create_instance() == raven.R_FALSE) return raven.R_FALSE;
        if (rvn_vk_pick_physical_device() == raven.R_FALSE) return raven.R_FALSE;
        if (rvn_vk_create_device() == raven.R_FALSE) return raven.R_FALSE;
    }

    loader.rvn_vk.GetPhysicalDeviceMemoryProperties.?(g_vk.physical_device, &g_vk.memory);
    loader.rvn_vk.GetPhysicalDeviceProperties.?(g_vk.physical_device, &properties);
    // the entry point only resolves when the extension is enabled on the device
    if (builtin.os.tag == .windows) {
        g_vk.can_share = if (loader.rvn_vk.GetMemoryWin32HandleKHR != null) raven.R_TRUE else raven.R_FALSE;
    } else {
        g_vk.can_share = if (loader.rvn_vk.GetMemoryFdKHR != null) raven.R_TRUE else raven.R_FALSE;
    }
    if (g_vk.external == raven.R_FALSE and
        !(properties.apiVersion >= vk.VK_API_VERSION_1_1 and g_vk.api_version >= vk.VK_API_VERSION_1_1))
    {
        g_vk.can_share = raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_vk_device_shutdown() void {
    if (g_vk.external == raven.R_FALSE) {
        if (g_vk.device != null and loader.rvn_vk.DestroyDevice != null) {
            loader.rvn_vk.DestroyDevice.?(g_vk.device, null);
        }
        if (g_vk.messenger != null and loader.rvn_vk.DestroyDebugUtilsMessengerEXT != null) {
            loader.rvn_vk.DestroyDebugUtilsMessengerEXT.?(g_vk.instance, g_vk.messenger, null);
        }
        if (g_vk.instance != null and loader.rvn_vk.DestroyInstance != null) {
            loader.rvn_vk.DestroyInstance.?(g_vk.instance, null);
        }
    }
    g_vk.device = null; // VK_NULL_HANDLE
    g_vk.instance = null;
    g_vk.physical_device = null;
    g_vk.queue = null;
    g_vk.messenger = null;
    loader.rvn_vk_unload_library();
}

// ---------------------------------------------------------------------------
//  Memory
// ---------------------------------------------------------------------------

export fn rvn_vk_find_memory_type(type_bits: u32, flags: vk.VkMemoryPropertyFlags) u32 {
    var i: u32 = 0;
    while (i < g_vk.memory.memoryTypeCount) : (i += 1) {
        const bit: u32 = @as(u32, 1) << @as(u5, @intCast(i)); // 1u << i
        if ((type_bits & bit) != 0 and (g_vk.memory.memoryTypes[i].propertyFlags & flags) == flags) return i;
    }
    return UINT32_MAX;
}

export fn rvn_vk_buffer_create(buffer: [*c]be.rvn_vk_buffer_t, size: vk.VkDeviceSize, usage: vk.VkBufferUsageFlags) c_int {
    var info: vk.VkBufferCreateInfo = undefined;
    var requirements: vk.VkMemoryRequirements = undefined;
    var allocation: vk.VkMemoryAllocateInfo = undefined;

    @memset(std.mem.asBytes(&buffer.*), 0); // memset(buffer, 0, sizeof(*buffer));
    @memset(std.mem.asBytes(&info), 0); // memset(&info, 0, sizeof(info));
    info.sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    info.size = size;
    info.usage = usage;
    info.sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
    if (rvn_vk_failed(loader.rvn_vk.CreateBuffer.?(g_vk.device, &info, null, &buffer.*.buffer), "vkCreateBuffer") != raven.R_FALSE) {
        return raven.R_FALSE;
    }

    loader.rvn_vk.GetBufferMemoryRequirements.?(g_vk.device, buffer.*.buffer, &requirements);
    @memset(std.mem.asBytes(&allocation), 0); // memset(&allocation, 0, sizeof(allocation));
    allocation.sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    allocation.allocationSize = requirements.size;
    // this combination is guaranteed to exist by the Vulkan specification
    allocation.memoryTypeIndex = rvn_vk_find_memory_type(requirements.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (allocation.memoryTypeIndex == UINT32_MAX or
        rvn_vk_failed(loader.rvn_vk.AllocateMemory.?(g_vk.device, &allocation, null, &buffer.*.memory), "vkAllocateMemory") != raven.R_FALSE or
        rvn_vk_failed(loader.rvn_vk.BindBufferMemory.?(g_vk.device, buffer.*.buffer, buffer.*.memory, 0), "vkBindBufferMemory") != raven.R_FALSE or
        rvn_vk_failed(loader.rvn_vk.MapMemory.?(g_vk.device, buffer.*.memory, 0, vk.VK_WHOLE_SIZE, 0, &buffer.*.mapped), "vkMapMemory") != raven.R_FALSE)
    {
        rvn_vk_buffer_destroy(buffer);
        return raven.R_FALSE;
    }
    buffer.*.size = size;
    return raven.R_TRUE;
}

export fn rvn_vk_buffer_destroy(buffer: [*c]be.rvn_vk_buffer_t) void {
    if (buffer.*.buffer != null) loader.rvn_vk.DestroyBuffer.?(g_vk.device, buffer.*.buffer, null);
    // freeing the memory also unmaps it
    if (buffer.*.memory != null) loader.rvn_vk.FreeMemory.?(g_vk.device, buffer.*.memory, null);
    @memset(std.mem.asBytes(&buffer.*), 0); // memset(buffer, 0, sizeof(*buffer));
}
