// Translated to Zig from vendor/raven/src/render/vulkan/vk_loader.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_loader.c
// Opens the Vulkan library at run time and fills the `rvn_vk` table.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const libc = @import("../../sys/libc.zig");
const vk_loader_h = @import("vk_loader_h.zig");
const vulkan_h = @import("vulkan_h.zig");

// #include <dlfcn.h> (non-Windows): RTLD_LOCAL is 0 on glibc and musl, 0x4 on Darwin (libc.zig declares RTLD_NOW only)
const RTLD_LOCAL: c_int = if (builtin.os.tag.isDarwin()) 0x4 else 0;

// #if defined(_WIN32) #include <windows.h>: the three loader calls, declared by hand (HMODULE is a pointer)
extern "kernel32" fn LoadLibraryA(name: [*c]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*c]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FreeLibrary(module: ?*anyopaque) callconv(.winapi) c_int;

export var rvn_vk: vk_loader_h.rvn_vk_functions_t = std.mem.zeroes(vk_loader_h.rvn_vk_functions_t);

var g_vk_library: ?*anyopaque = std.mem.zeroes(?*anyopaque);

// ---------------------------------------------------------------------------
//  Shared libraries
// ---------------------------------------------------------------------------

export fn rvn_vk_library_open(name: [*c]const u8) ?*anyopaque {
    if (builtin.os.tag == .windows) {
        return LoadLibraryA(name); // (void*)LoadLibraryA(name)
    } else {
        return libc.dlopen(name, libc.RTLD_NOW | RTLD_LOCAL); // dlopen(name, RTLD_NOW | RTLD_LOCAL)
    }
}

export fn rvn_vk_library_symbol(library: ?*anyopaque, name: [*c]const u8) ?*anyopaque {
    if (builtin.os.tag == .windows) {
        // a function pointer does not convert to void* in ISO C: go through an integer
        return GetProcAddress(library, name); // (void*)(uintptr_t)GetProcAddress((HMODULE)library, name)
    } else {
        return libc.dlsym(library, name); // dlsym(library, name)
    }
}

export fn rvn_vk_library_close(library: ?*anyopaque) void {
    if (library == null) return;
    if (builtin.os.tag == .windows) {
        _ = FreeLibrary(library); // FreeLibrary((HMODULE)library);
    } else {
        _ = libc.dlclose(library); // dlclose(library);
    }
}

// ---------------------------------------------------------------------------
//  Entry points
// ---------------------------------------------------------------------------

/// Converts the untyped result of the loaders to the type of a table entry.
/// #define RVN_VK_ASSIGN(target, pointer) do { void* rvn_vk_pointer_ = (void*)(uintptr_t)(pointer); memcpy(&(target), &rvn_vk_pointer_, sizeof(void*)); } while (0)
/// `target` is the address of the table entry (`&rvn_vk.name`).
inline fn RVN_VK_ASSIGN(target: anytype, pointer: anytype) void {
    const rvn_vk_pointer_: ?*anyopaque = @ptrFromInt(@intFromPtr(pointer));
    @memcpy(std.mem.asBytes(target), std.mem.asBytes(&rvn_vk_pointer_));
}

export fn rvn_vk_load_library() c_int {
    const names: []const [*c]const u8 = if (builtin.os.tag == .windows)
        &.{"vulkan-1.dll"}
    else if (builtin.os.tag.isDarwin())
        // dyld does not search the Homebrew prefixes for bare names
        &.{ "libvulkan.1.dylib", "libvulkan.dylib", "libMoltenVK.dylib", "/opt/homebrew/lib/libvulkan.1.dylib", "/opt/homebrew/lib/libMoltenVK.dylib", "/usr/local/lib/libvulkan.1.dylib", "/usr/local/lib/libMoltenVK.dylib" }
    else
        &.{ "libvulkan.so.1", "libvulkan.so" };
    var i: usize = 0;
    var complete: c_int = raven.R_TRUE;

    // may already be open: raven_vulkan.h can be queried before Rinit
    if (g_vk_library != null) return raven.R_TRUE;
    @memset(std.mem.asBytes(&rvn_vk), 0); // memset(&rvn_vk, 0, sizeof(rvn_vk));
    while (i < names.len and g_vk_library == null) : (i += 1) {
        g_vk_library = rvn_vk_library_open(names[i]);
    }
    if (g_vk_library == null) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: the Vulkan library (%s) was not found; is a Vulkan driver installed?", names[0]);
        return raven.R_FALSE;
    }

    RVN_VK_ASSIGN(&rvn_vk.GetInstanceProcAddr, rvn_vk_library_symbol(g_vk_library, "vkGetInstanceProcAddr"));
    if (rvn_vk.GetInstanceProcAddr == null) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: vkGetInstanceProcAddr is missing from the Vulkan library");
        rvn_vk_unload_library();
        return raven.R_FALSE;
    }

    // #define RVN_VK_LOAD(name) RVN_VK_ASSIGN(rvn_vk.name, rvn_vk.GetInstanceProcAddr(NULL, "vk" #name)); if (!rvn_vk.name) complete = R_FALSE;
    inline for (vk_loader_h.RVN_VK_GLOBAL_FUNCTIONS) |fn_name| {
        RVN_VK_ASSIGN(&@field(rvn_vk, fn_name), rvn_vk.GetInstanceProcAddr.?(null, "vk" ++ fn_name));
        if (@field(rvn_vk, fn_name) == null) complete = raven.R_FALSE;
    }
    RVN_VK_ASSIGN(&rvn_vk.EnumerateInstanceVersion, rvn_vk.GetInstanceProcAddr.?(null, "vkEnumerateInstanceVersion"));

    if (complete == raven.R_FALSE) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: the Vulkan library is incomplete");
        rvn_vk_unload_library();
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_vk_unload_library() void {
    rvn_vk_library_close(g_vk_library);
    g_vk_library = null;
    @memset(std.mem.asBytes(&rvn_vk), 0); // memset(&rvn_vk, 0, sizeof(rvn_vk));
}

export fn rvn_vk_load_instance(instance: vulkan_h.VkInstance) c_int {
    var missing: [*c]const u8 = null;

    // #define RVN_VK_LOAD(name) RVN_VK_ASSIGN(rvn_vk.name, rvn_vk.GetInstanceProcAddr(instance, "vk" #name)); if (!rvn_vk.name && !missing) missing = "vk" #name;
    inline for (vk_loader_h.RVN_VK_INSTANCE_FUNCTIONS) |fn_name| {
        RVN_VK_ASSIGN(&@field(rvn_vk, fn_name), rvn_vk.GetInstanceProcAddr.?(instance, "vk" ++ fn_name));
        if (@field(rvn_vk, fn_name) == null and missing == null) missing = "vk" ++ fn_name;
    }

    // optional extensions: NULL when they are not enabled on the instance
    RVN_VK_ASSIGN(&rvn_vk.CreateWin32SurfaceKHR, rvn_vk.GetInstanceProcAddr.?(instance, "vkCreateWin32SurfaceKHR"));
    RVN_VK_ASSIGN(&rvn_vk.CreateXlibSurfaceKHR, rvn_vk.GetInstanceProcAddr.?(instance, "vkCreateXlibSurfaceKHR"));
    RVN_VK_ASSIGN(&rvn_vk.CreateXcbSurfaceKHR, rvn_vk.GetInstanceProcAddr.?(instance, "vkCreateXcbSurfaceKHR"));
    RVN_VK_ASSIGN(&rvn_vk.CreateMetalSurfaceEXT, rvn_vk.GetInstanceProcAddr.?(instance, "vkCreateMetalSurfaceEXT"));
    RVN_VK_ASSIGN(&rvn_vk.CreateHeadlessSurfaceEXT, rvn_vk.GetInstanceProcAddr.?(instance, "vkCreateHeadlessSurfaceEXT"));
    RVN_VK_ASSIGN(&rvn_vk.CreateDebugUtilsMessengerEXT, rvn_vk.GetInstanceProcAddr.?(instance, "vkCreateDebugUtilsMessengerEXT"));
    RVN_VK_ASSIGN(&rvn_vk.DestroyDebugUtilsMessengerEXT, rvn_vk.GetInstanceProcAddr.?(instance, "vkDestroyDebugUtilsMessengerEXT"));

    if (missing != null) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: %s is not available (is VK_KHR_surface enabled on the instance?)", missing);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_vk_load_device(device: vulkan_h.VkDevice) c_int {
    var missing: [*c]const u8 = null;

    // #define RVN_VK_LOAD(name) RVN_VK_ASSIGN(rvn_vk.name, rvn_vk.GetDeviceProcAddr(device, "vk" #name)); if (!rvn_vk.name && !missing) missing = "vk" #name;
    inline for (vk_loader_h.RVN_VK_DEVICE_FUNCTIONS) |fn_name| {
        RVN_VK_ASSIGN(&@field(rvn_vk, fn_name), rvn_vk.GetDeviceProcAddr.?(device, "vk" ++ fn_name));
        if (@field(rvn_vk, fn_name) == null and missing == null) missing = "vk" ++ fn_name;
    }

    RVN_VK_ASSIGN(&rvn_vk.GetMemoryFdKHR, rvn_vk.GetDeviceProcAddr.?(device, "vkGetMemoryFdKHR"));
    RVN_VK_ASSIGN(&rvn_vk.GetMemoryWin32HandleKHR, rvn_vk.GetDeviceProcAddr.?(device, "vkGetMemoryWin32HandleKHR"));

    if (missing != null) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: %s is not available (is VK_KHR_swapchain enabled on the device?)", missing);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_vk_result_name(result: vulkan_h.VkResult) [*c]const u8 {
    switch (result) {
        vulkan_h.VK_SUCCESS => return "VK_SUCCESS",
        vulkan_h.VK_NOT_READY => return "VK_NOT_READY",
        vulkan_h.VK_TIMEOUT => return "VK_TIMEOUT",
        vulkan_h.VK_INCOMPLETE => return "VK_INCOMPLETE",
        vulkan_h.VK_SUBOPTIMAL_KHR => return "VK_SUBOPTIMAL_KHR",
        vulkan_h.VK_ERROR_OUT_OF_HOST_MEMORY => return "VK_ERROR_OUT_OF_HOST_MEMORY",
        vulkan_h.VK_ERROR_OUT_OF_DEVICE_MEMORY => return "VK_ERROR_OUT_OF_DEVICE_MEMORY",
        vulkan_h.VK_ERROR_INITIALIZATION_FAILED => return "VK_ERROR_INITIALIZATION_FAILED",
        vulkan_h.VK_ERROR_DEVICE_LOST => return "VK_ERROR_DEVICE_LOST",
        vulkan_h.VK_ERROR_MEMORY_MAP_FAILED => return "VK_ERROR_MEMORY_MAP_FAILED",
        vulkan_h.VK_ERROR_LAYER_NOT_PRESENT => return "VK_ERROR_LAYER_NOT_PRESENT",
        vulkan_h.VK_ERROR_EXTENSION_NOT_PRESENT => return "VK_ERROR_EXTENSION_NOT_PRESENT",
        vulkan_h.VK_ERROR_FEATURE_NOT_PRESENT => return "VK_ERROR_FEATURE_NOT_PRESENT",
        vulkan_h.VK_ERROR_INCOMPATIBLE_DRIVER => return "VK_ERROR_INCOMPATIBLE_DRIVER",
        vulkan_h.VK_ERROR_TOO_MANY_OBJECTS => return "VK_ERROR_TOO_MANY_OBJECTS",
        vulkan_h.VK_ERROR_FORMAT_NOT_SUPPORTED => return "VK_ERROR_FORMAT_NOT_SUPPORTED",
        vulkan_h.VK_ERROR_FRAGMENTED_POOL => return "VK_ERROR_FRAGMENTED_POOL",
        vulkan_h.VK_ERROR_OUT_OF_POOL_MEMORY => return "VK_ERROR_OUT_OF_POOL_MEMORY",
        vulkan_h.VK_ERROR_SURFACE_LOST_KHR => return "VK_ERROR_SURFACE_LOST_KHR",
        vulkan_h.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => return "VK_ERROR_NATIVE_WINDOW_IN_USE_KHR",
        vulkan_h.VK_ERROR_OUT_OF_DATE_KHR => return "VK_ERROR_OUT_OF_DATE_KHR",
        else => return "VK_ERROR (unknown)",
    }
}
