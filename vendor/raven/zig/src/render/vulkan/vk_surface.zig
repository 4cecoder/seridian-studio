// Translated to Zig from vendor/raven/src/render/vulkan/vk_surface.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_surface.c
// One presentation surface and one swapchain per window.
//
// The window-system headers are not included: the create-info structures of
// the surface extensions are declared here with their exact layout, which
// keeps <windows.h> and <X11/Xlib.h> out of the renderer.

const std = @import("std");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const be = @import("vk_backend_h.zig");
const vk = be.vk;
const loader = be.loader;

// VkWin32SurfaceCreateInfoKHR
const rvn_vk_win32_surface_info_t = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    hinstance: ?*anyopaque,
    hwnd: ?*anyopaque,
};

// VkXlibSurfaceCreateInfoKHR
const rvn_vk_xlib_surface_info_t = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    dpy: ?*anyopaque,
    // Window is an XID, which Xlib defines as unsigned long
    window: c_ulong,
};

// VkXcbSurfaceCreateInfoKHR
const rvn_vk_xcb_surface_info_t = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    connection: ?*anyopaque,
    window: u32,
};

// VkMetalSurfaceCreateInfoEXT: declared locally so Metal headers/platform macros stay out of the C renderer.
const rvn_vk_metal_surface_info_t = extern struct {
    sType: vk.VkStructureType,
    pNext: ?*const anyopaque,
    flags: vk.VkFlags,
    layer: ?*const anyopaque,
};

const UINT32_MAX: u32 = std.math.maxInt(u32);
const UINT64_MAX: u64 = std.math.maxInt(u64);

// static const VkCompositeAlphaFlagBitsKHR opaque_modes[] = {...}
const opaque_modes = [_]vk.VkCompositeAlphaFlagBitsKHR{
    vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
    vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
    vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
};

// A window that is seen through: the frame is premultiplied, which is
// what the window systems blend. "Inherit" leaves the blending to the
// window itself (X11: its 32-bit visual; Win32: the desktop window
// manager), which is how most drivers offer it.
// static const VkCompositeAlphaFlagBitsKHR transparent_modes[] = {...}
const transparent_modes = [_]vk.VkCompositeAlphaFlagBitsKHR{
    vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
    vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
    vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
};

// ---------------------------------------------------------------------------
//  Native surface
// ---------------------------------------------------------------------------

fn rvn_vk_native_surface_create(native: [*c]const raven.RNativeWindow, out: [*c]vk.VkSurfaceKHR) c_int {
    var result: vk.VkResult = vk.VK_ERROR_EXTENSION_NOT_PRESENT;

    if (native.*.system == raven.R_WINDOW_SYSTEM_WIN32 and loader.rvn_vk.CreateWin32SurfaceKHR != null) {
        var info = std.mem.zeroes(rvn_vk_win32_surface_info_t);
        info.sType = vk.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
        info.hinstance = native.*.display;
        info.hwnd = @ptrFromInt(native.*.window);
        result = loader.rvn_vk.CreateWin32SurfaceKHR.?(be.g_vk.instance, &info, null, out);
    } else if (native.*.system == raven.R_WINDOW_SYSTEM_COCOA and loader.rvn_vk.CreateMetalSurfaceEXT != null) {
        var info = std.mem.zeroes(rvn_vk_metal_surface_info_t);
        info.sType = 1000217000; // VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT
        info.layer = @ptrFromInt(native.*.window);
        result = loader.rvn_vk.CreateMetalSurfaceEXT.?(be.g_vk.instance, &info, null, out);
    } else if (native.*.system == raven.R_WINDOW_SYSTEM_X11) {
        if (loader.rvn_vk.CreateXlibSurfaceKHR != null) {
            var info = std.mem.zeroes(rvn_vk_xlib_surface_info_t);
            info.sType = vk.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
            info.dpy = native.*.display;
            info.window = @as(c_ulong, native.*.window); // (unsigned long)native->window
            result = loader.rvn_vk.CreateXlibSurfaceKHR.?(be.g_vk.instance, &info, null, out);
        }
        if (result < 0 and loader.rvn_vk.CreateXcbSurfaceKHR != null) {
            // The driver only speaks XCB (some software and embedded drivers).
            // Every Xlib connection sits on an XCB connection, which
            // libX11-xcb returns; it is opened on demand so that Raven does
            // not depend on it.
            var get_connection: ?*const fn (display: ?*anyopaque) callconv(.c) ?*anyopaque = null;
            if (be.g_vk.xcb_library == null) be.g_vk.xcb_library = loader.rvn_vk_library_open("libX11-xcb.so.1");
            const symbol: ?*anyopaque = if (be.g_vk.xcb_library != null)
                loader.rvn_vk_library_symbol(be.g_vk.xcb_library, "XGetXCBConnection")
            else
                null;
            // memcpy(&get_connection, &symbol, sizeof(void*));
            get_connection = @ptrCast(symbol);
            if (get_connection != null) {
                var info = std.mem.zeroes(rvn_vk_xcb_surface_info_t);
                info.sType = vk.VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR;
                info.connection = get_connection.?(native.*.display);
                info.window = @truncate(native.*.window); // (uint32_t)native->window
                result = loader.rvn_vk.CreateXcbSurfaceKHR.?(be.g_vk.instance, &info, null, out);
            } else {
                base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: this driver needs libX11-xcb.so.1 to present to an X11 window");
                return raven.R_FALSE;
            }
        }
    } else if (native.*.system == raven.R_WINDOW_SYSTEM_NONE and loader.rvn_vk.CreateHeadlessSurfaceEXT != null) {
        // no window system (headless runs): frames are rendered and can be captured
        var info = std.mem.zeroes(vk.VkHeadlessSurfaceCreateInfoEXT);
        info.sType = vk.VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT;
        result = loader.rvn_vk.CreateHeadlessSurfaceEXT.?(be.g_vk.instance, &info, null, out);
    }

    if (result == vk.VK_ERROR_EXTENSION_NOT_PRESENT) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: the surface extension of this window system is not enabled on the instance");
        return raven.R_FALSE;
    }
    // return !rvn_vk_failed(result, ...);
    return @intFromBool(be.rvn_vk_failed(result, "creating the window surface") == 0);
}

// ---------------------------------------------------------------------------
//  Table of surfaces, indexed by the index part of the window handle
// ---------------------------------------------------------------------------

export fn rvn_vk_surface_find(window: raven.Rid) [*c]be.rvn_vk_surface_t {
    const index: u32 = raven.R_ID_INDEX(window);
    if (index >= be.g_vk.surface_cap or be.g_vk.surfaces[index].used == 0 or be.g_vk.surfaces[index].window != window) return null;
    return &be.g_vk.surfaces[index];
}

export fn rvn_vk_wait_frames() void {
    var i: u32 = 0;
    var f: u32 = 0;
    while (i < be.g_vk.surface_cap) : (i += 1) {
        const surface = &be.g_vk.surfaces[i];
        if (surface.*.used == 0) continue;
        f = 0;
        while (f < be.RVN_VK_FRAMES) : (f += 1) {
            const frame = &surface.*.frames[f];
            if (frame.*.submitted == 0) continue;
            _ = loader.rvn_vk.WaitForFences.?(be.g_vk.device, 1, &frame.*.fence, vk.VK_TRUE, UINT64_MAX);
            _ = loader.rvn_vk.ResetFences.?(be.g_vk.device, 1, &frame.*.fence);
            frame.*.submitted = raven.R_FALSE;
        }
    }
}

// ---------------------------------------------------------------------------
//  Swapchain
// ---------------------------------------------------------------------------

fn rvn_vk_clamp(value: u32, low: u32, high: u32) u32 {
    return if (value < low) low else if (value > high) high else value;
}

fn rvn_vk_swapchain_release_images(surface: [*c]be.rvn_vk_surface_t) void {
    var i: u32 = 0;
    while (i < surface.*.image_count) : (i += 1) {
        if (surface.*.framebuffers[i] != null) loader.rvn_vk.DestroyFramebuffer.?(be.g_vk.device, surface.*.framebuffers[i], null);
        if (surface.*.views[i] != null) loader.rvn_vk.DestroyImageView.?(be.g_vk.device, surface.*.views[i], null);
        surface.*.framebuffers[i] = null;
        surface.*.views[i] = null;
    }
    surface.*.image_count = 0;
}

// UI colors are sRGB values blended as they are, so a UNORM format is wanted.
fn rvn_vk_choose_format(surface: [*c]be.rvn_vk_surface_t) vk.VkSurfaceFormatKHR {
    var formats: [64]vk.VkSurfaceFormatKHR = undefined;
    var chosen: vk.VkSurfaceFormatKHR = undefined;
    var count: u32 = @intCast(formats.len);
    var i: u32 = 0;

    chosen.format = vk.VK_FORMAT_B8G8R8A8_UNORM;
    chosen.colorSpace = vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    if (loader.rvn_vk.GetPhysicalDeviceSurfaceFormatsKHR.?(be.g_vk.physical_device, surface.*.surface, &count, &formats) < 0 or count == 0) return chosen;
    // a single UNDEFINED entry means that any format is accepted
    if (count == 1 and formats[0].format == vk.VK_FORMAT_UNDEFINED) return chosen;
    while (i < count) : (i += 1) {
        if (formats[i].format == vk.VK_FORMAT_B8G8R8A8_UNORM or formats[i].format == vk.VK_FORMAT_R8G8B8A8_UNORM) return formats[i];
    }
    return formats[0];
}

fn rvn_vk_choose_present_mode(surface: [*c]be.rvn_vk_surface_t) vk.VkPresentModeKHR {
    var modes: [16]vk.VkPresentModeKHR = undefined;
    var count: u32 = @intCast(modes.len);
    var i: u32 = 0;
    var mailbox: c_int = raven.R_FALSE;
    var immediate: c_int = raven.R_FALSE;

    // FIFO is always available and is the vertical synchronization
    if (be.g_vk.info.vsync != 0) return vk.VK_PRESENT_MODE_FIFO_KHR;
    if (loader.rvn_vk.GetPhysicalDeviceSurfacePresentModesKHR.?(be.g_vk.physical_device, surface.*.surface, &count, &modes) < 0) {
        return vk.VK_PRESENT_MODE_FIFO_KHR;
    }
    while (i < count) : (i += 1) {
        if (modes[i] == vk.VK_PRESENT_MODE_MAILBOX_KHR) mailbox = raven.R_TRUE;
        if (modes[i] == vk.VK_PRESENT_MODE_IMMEDIATE_KHR) immediate = raven.R_TRUE;
    }
    if (mailbox != 0) return vk.VK_PRESENT_MODE_MAILBOX_KHR;
    if (immediate != 0) return vk.VK_PRESENT_MODE_IMMEDIATE_KHR;
    return vk.VK_PRESENT_MODE_FIFO_KHR;
}

export fn rvn_vk_swapchain_create(surface: [*c]be.rvn_vk_surface_t, width: u32, height: u32) c_int {
    var caps: vk.VkSurfaceCapabilitiesKHR = undefined;
    var info = std.mem.zeroes(vk.VkSwapchainCreateInfoKHR);
    var created: vk.VkSwapchainKHR = null;
    var extent: vk.VkExtent2D = undefined;
    var image_count: u32 = undefined;
    var i: u32 = undefined;
    var present_mode: vk.VkPresentModeKHR = undefined;
    const alpha_modes: []const vk.VkCompositeAlphaFlagBitsKHR = if (surface.*.transparent != 0) &transparent_modes else &opaque_modes;

    surface.*.requested_width = width;
    surface.*.requested_height = height;
    surface.*.out_of_date = raven.R_TRUE;

    if (loader.rvn_vk.GetPhysicalDeviceSurfaceCapabilitiesKHR.?(be.g_vk.physical_device, surface.*.surface, &caps) < 0) return raven.R_FALSE;
    if (caps.currentExtent.width != UINT32_MAX) {
        // the window system dictates the size
        extent = caps.currentExtent;
    } else {
        extent.width = rvn_vk_clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width);
        extent.height = rvn_vk_clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height);
    }
    // minimized: nothing can be created, the frame is skipped
    if (extent.width == 0 or extent.height == 0) return raven.R_FALSE;

    // the previous images may still be in use by submitted frames
    rvn_vk_wait_frames();
    // the offscreen images of glass have the size of the swapchain: they are made again on demand
    be.rvn_vk_glass_release(surface);

    surface.*.format = rvn_vk_choose_format(surface);
    surface.*.pass = be.rvn_vk_pass_get(surface.*.format.format);
    if (surface.*.pass == null) return raven.R_FALSE;

    // With the vertical synchronization (FIFO) every image more is one more
    // frame waiting to be shown: what the pointer did shows that much later.
    // The fewest images the system allows (two at least) keep the interface
    // close to the hand; without it (mailbox, immediate) one more image lets
    // the GPU work while the screen shows the previous one.
    present_mode = rvn_vk_choose_present_mode(surface);
    image_count = if (present_mode == vk.VK_PRESENT_MODE_FIFO_KHR)
        (if (caps.minImageCount > 2) caps.minImageCount else 2)
    else
        caps.minImageCount +% 1;
    if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) image_count = caps.maxImageCount;

    info.sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    info.surface = surface.*.surface;
    info.minImageCount = image_count;
    info.imageFormat = surface.*.format.format;
    info.imageColorSpace = surface.*.format.colorSpace;
    info.imageExtent = extent;
    info.imageArrayLayers = 1;
    info.imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    // reading the images back is optional: it is only needed by Rwindow_capture
    surface.*.can_capture = @intFromBool((caps.supportedUsageFlags & vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT) != 0);
    if (surface.*.can_capture != 0) info.imageUsage |= vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    info.imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE;
    info.preTransform = if ((caps.supportedTransforms & vk.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR) != 0)
        vk.VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR
    else
        caps.currentTransform;
    info.compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    i = 0;
    while (i < 4) : (i += 1) {
        if ((caps.supportedCompositeAlpha & alpha_modes[i]) != 0) {
            info.compositeAlpha = alpha_modes[i];
            break;
        }
    }
    info.presentMode = present_mode;
    info.clipped = vk.VK_TRUE;
    info.oldSwapchain = surface.*.swapchain;

    if (be.rvn_vk_failed(loader.rvn_vk.CreateSwapchainKHR.?(be.g_vk.device, &info, null, &created), "vkCreateSwapchainKHR") != 0) return raven.R_FALSE;

    rvn_vk_swapchain_release_images(surface);
    if (surface.*.swapchain != null) loader.rvn_vk.DestroySwapchainKHR.?(be.g_vk.device, surface.*.swapchain, null);
    surface.*.swapchain = created;
    surface.*.extent = extent;
    surface.*.present_vsync = be.g_vk.info.vsync;

    image_count = 0;
    _ = loader.rvn_vk.GetSwapchainImagesKHR.?(be.g_vk.device, surface.*.swapchain, &image_count, null);
    if (image_count == 0 or image_count > be.RVN_VK_MAX_IMAGES) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: unsupported number of swapchain images (%u)", @as(c_uint, image_count));
        return raven.R_FALSE;
    }
    if (be.rvn_vk_failed(loader.rvn_vk.GetSwapchainImagesKHR.?(be.g_vk.device, surface.*.swapchain, &image_count, &surface.*.images), "vkGetSwapchainImagesKHR") != 0) return raven.R_FALSE;
    surface.*.image_count = image_count;

    i = 0;
    while (i < image_count) : (i += 1) {
        var view = std.mem.zeroes(vk.VkImageViewCreateInfo);
        var framebuffer = std.mem.zeroes(vk.VkFramebufferCreateInfo);

        view.sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view.image = surface.*.images[i];
        view.viewType = vk.VK_IMAGE_VIEW_TYPE_2D;
        view.format = surface.*.format.format;
        view.subresourceRange.aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT;
        view.subresourceRange.levelCount = 1;
        view.subresourceRange.layerCount = 1;
        if (be.rvn_vk_failed(loader.rvn_vk.CreateImageView.?(be.g_vk.device, &view, null, &surface.*.views[i]), "vkCreateImageView") != 0) return raven.R_FALSE;

        framebuffer.sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        framebuffer.renderPass = surface.*.pass.*.render_pass;
        framebuffer.attachmentCount = 1;
        framebuffer.pAttachments = &surface.*.views[i];
        framebuffer.width = extent.width;
        framebuffer.height = extent.height;
        framebuffer.layers = 1;
        if (be.rvn_vk_failed(loader.rvn_vk.CreateFramebuffer.?(be.g_vk.device, &framebuffer, null, &surface.*.framebuffers[i]), "vkCreateFramebuffer") != 0) return raven.R_FALSE;

        if (surface.*.rendered[i] == null) {
            var semaphore = std.mem.zeroes(vk.VkSemaphoreCreateInfo);
            semaphore.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
            if (be.rvn_vk_failed(loader.rvn_vk.CreateSemaphore.?(be.g_vk.device, &semaphore, null, &surface.*.rendered[i]), "vkCreateSemaphore") != 0) return raven.R_FALSE;
        }
    }
    surface.*.out_of_date = raven.R_FALSE;
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  Surface
// ---------------------------------------------------------------------------

fn rvn_vk_frame_create(frame: [*c]be.rvn_vk_frame_t) c_int {
    var pool = std.mem.zeroes(vk.VkCommandPoolCreateInfo);
    var allocation = std.mem.zeroes(vk.VkCommandBufferAllocateInfo);
    var fence = std.mem.zeroes(vk.VkFenceCreateInfo);
    var semaphore = std.mem.zeroes(vk.VkSemaphoreCreateInfo);

    pool.sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool.flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = be.g_vk.queue_family;
    if (be.rvn_vk_failed(loader.rvn_vk.CreateCommandPool.?(be.g_vk.device, &pool, null, &frame.*.pool), "vkCreateCommandPool") != 0) return raven.R_FALSE;

    allocation.sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    allocation.commandPool = frame.*.pool;
    allocation.level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocation.commandBufferCount = 1;
    if (be.rvn_vk_failed(loader.rvn_vk.AllocateCommandBuffers.?(be.g_vk.device, &allocation, &frame.*.commands), "vkAllocateCommandBuffers") != 0) return raven.R_FALSE;

    fence.sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    if (be.rvn_vk_failed(loader.rvn_vk.CreateFence.?(be.g_vk.device, &fence, null, &frame.*.fence), "vkCreateFence") != 0) return raven.R_FALSE;

    semaphore.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    if (be.rvn_vk_failed(loader.rvn_vk.CreateSemaphore.?(be.g_vk.device, &semaphore, null, &frame.*.acquired), "vkCreateSemaphore") != 0) return raven.R_FALSE;
    return raven.R_TRUE;
}

fn rvn_vk_surface_release(surface: [*c]be.rvn_vk_surface_t) void {
    var i: u32 = 0;
    rvn_vk_wait_frames();
    while (i < be.RVN_VK_FRAMES) : (i += 1) {
        const frame = &surface.*.frames[i];
        be.rvn_vk_buffer_destroy(&frame.*.instances);
        if (frame.*.acquired != null) loader.rvn_vk.DestroySemaphore.?(be.g_vk.device, frame.*.acquired, null);
        if (frame.*.fence != null) loader.rvn_vk.DestroyFence.?(be.g_vk.device, frame.*.fence, null);
        // destroying the pool frees its command buffer
        if (frame.*.pool != null) loader.rvn_vk.DestroyCommandPool.?(be.g_vk.device, frame.*.pool, null);
    }
    be.rvn_vk_glass_release(surface);
    rvn_vk_swapchain_release_images(surface);
    i = 0;
    while (i < be.RVN_VK_MAX_IMAGES) : (i += 1) {
        if (surface.*.rendered[i] != null) loader.rvn_vk.DestroySemaphore.?(be.g_vk.device, surface.*.rendered[i], null);
    }
    if (surface.*.swapchain != null) loader.rvn_vk.DestroySwapchainKHR.?(be.g_vk.device, surface.*.swapchain, null);
    if (surface.*.surface != null) loader.rvn_vk.DestroySurfaceKHR.?(be.g_vk.instance, surface.*.surface, null);
    surface.* = std.mem.zeroes(be.rvn_vk_surface_t); // memset(surface, 0, sizeof(*surface));
}

export fn rvn_vk_surface_create(window: raven.Rid, native: [*c]const raven.RNativeWindow, width: raven.Ruint, height: raven.Ruint) c_int {
    const index: u32 = raven.R_ID_INDEX(window);
    var i: u32 = undefined;
    var supported: vk.VkBool32 = undefined;

    if (index >= be.g_vk.surface_cap) {
        var cap: u32 = if (be.g_vk.surface_cap != 0) be.g_vk.surface_cap else 8;
        while (cap <= index) cap *%= 2;
        be.g_vk.surfaces = @ptrCast(@alignCast(base.rvn_realloc(be.g_vk.surfaces, @sizeOf(be.rvn_vk_surface_t) * @as(usize, cap))));
        // memset(g_vk.surfaces + g_vk.surface_cap, 0, sizeof(rvn_vk_surface_t) * (cap - g_vk.surface_cap));
        @memset(be.g_vk.surfaces[be.g_vk.surface_cap..cap], std.mem.zeroes(be.rvn_vk_surface_t));
        be.g_vk.surface_cap = cap;
    }
    const surface = &be.g_vk.surfaces[index];
    if (surface.*.used != 0) rvn_vk_surface_release(surface);

    surface.* = std.mem.zeroes(be.rvn_vk_surface_t);
    if (rvn_vk_native_surface_create(native, &surface.*.surface) == 0) return raven.R_FALSE;
    surface.*.used = raven.R_TRUE;
    surface.*.window = window;
    surface.*.transparent = @intFromBool(native.*.transparent != 0);

    supported = vk.VK_FALSE;
    _ = loader.rvn_vk.GetPhysicalDeviceSurfaceSupportKHR.?(be.g_vk.physical_device, be.g_vk.queue_family, surface.*.surface, &supported);
    if (supported == 0) {
        base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_ERROR, "Vulkan: the graphics queue cannot present to this window");
        rvn_vk_surface_release(surface);
        return raven.R_FALSE;
    }
    i = 0;
    while (i < be.RVN_VK_FRAMES) : (i += 1) {
        if (rvn_vk_frame_create(&surface.*.frames[i]) == 0) {
            rvn_vk_surface_release(surface);
            return raven.R_FALSE;
        }
    }
    // a window that is still hidden or minimized gets its swapchain on its first frame
    _ = rvn_vk_swapchain_create(surface, width, height);
    return raven.R_TRUE;
}

export fn rvn_vk_surface_destroy(window: raven.Rid) void {
    const surface = rvn_vk_surface_find(window);
    if (surface != null) rvn_vk_surface_release(surface);
}

export fn rvn_vk_surfaces_shutdown() void {
    var i: u32 = 0;
    while (i < be.g_vk.surface_cap) : (i += 1) {
        if (be.g_vk.surfaces[i].used != 0) rvn_vk_surface_release(&be.g_vk.surfaces[i]);
    }
    base.rvn_free(be.g_vk.surfaces);
    be.g_vk.surfaces = null;
    be.g_vk.surface_cap = 0;
    loader.rvn_vk_library_close(be.g_vk.xcb_library);
    be.g_vk.xcb_library = null;
}
