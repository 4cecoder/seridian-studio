// Translated to Zig from vendor/raven/src/render/vulkan/vk_backend.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/vulkan/vk_backend.h
// State shared by the files of the Vulkan backend.
//
//   vk_loader.c    run-time loading of the Vulkan library
//   vk_device.c    instance, physical device, device, memory helpers
//   vk_pipeline.c  shaders, samplers, descriptor sets, render passes, pipelines
//   vk_texture.c   textures and uploads
//   vk_surface.c   one surface + swapchain per window
//   vk_glass.c     backdrop of the glass primitives: offscreen frame, blur
//   vk_frame.c     recording and presenting a frame, capture
//   vk_backend.c   the RBackendVTable
//   vk_public.c    public API of raven_vulkan.h
//
// Everything here runs on the render thread, except vk_public.c.
//
// Like vk_backend.h, this unit also makes renderer_h and vk_loader_h available: `be.renderer`, `be.loader`,
// `be.vk` (the Vulkan types of vulkan_h.zig).

const raven = @import("raven");
pub const renderer = @import("../renderer_h.zig");
pub const loader = @import("vk_loader_h.zig");
pub const vk = loader.vk;

/// Frames recorded ahead of the GPU, per window.
pub const RVN_VK_FRAMES = 2;
/// A swapchain never has more images than this.
pub const RVN_VK_MAX_IMAGES = 16;
/// Render pass + pipeline variants, one per swapchain color format.
pub const RVN_VK_MAX_PASSES = 4;
/// Descriptor sets (= textures) per descriptor pool.
pub const RVN_VK_SETS_PER_POOL = 256;
/// Times the frame is halved to blur the backdrop of glass: 3 gives a blur of about 16 pixels.
pub const RVN_VK_BLUR_LEVELS = 3;
/// Windows that can show glass at the same time.
pub const RVN_VK_MAX_BACKDROPS = 32;

// ---------------------------------------------------------------------------
//  Objects
// ---------------------------------------------------------------------------

pub const rvn_vk_buffer_t = extern struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    size: vk.VkDeviceSize,
    /// Persistently mapped, or NULL.
    mapped: ?*anyopaque,
};
pub const struct_rvn_vk_buffer_t = rvn_vk_buffer_t;

pub const rvn_vk_texture_t = extern struct {
    used: c_int,
    width: u32,
    height: u32,
    format: raven.RTextureFormat,
    filter: raven.RFilterType,
    /// VK_NULL_HANDLE for a wrapped image view.
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    view: vk.VkImageView,
    /// Sampler given by the application, or VK_NULL_HANDLE for the Raven samplers.
    sampler: vk.VkSampler,
    set: vk.VkDescriptorSet,
    pool: vk.VkDescriptorPool,
    /// The view belongs to the application.
    wrapped: c_int,
    /// The memory can be exported (Rvulkan_texture_create_shared).
    shared: c_int,
    allocation_size: vk.VkDeviceSize,
    /// R_FALSE until the first pixels are written: the image has no layout yet.
    initialized: c_int,
};
pub const struct_rvn_vk_texture_t = rvn_vk_texture_t;

/// Render passes and pipelines for one color format. The passes only differ
/// by what happens to the image before and after, so they are compatible:
/// the two pipelines work in all of them.
pub const rvn_vk_pass_t = extern struct {
    format: vk.VkFormat,
    /// Clears, ends ready for presentation: the swapchain.
    render_pass: vk.VkRenderPass,
    /// The UI.
    pipeline: vk.VkPipeline,
    /// The same, removing instead of drawing (R_DRAW_ERASE).
    erase_pipeline: vk.VkPipeline,
    /// Offscreen frame of a window with glass: cleared, then continued after each capture.
    scene_clear_pass: vk.VkRenderPass,
    scene_load_pass: vk.VkRenderPass,
    /// Overwrites a whole image that will then be sampled (blur).
    blur_pass: vk.VkRenderPass,
    /// Overwrites an area of such an image and keeps the rest.
    blur_load_pass: vk.VkRenderPass,
    /// Full-screen filter: reduce, enlarge or copy (blur.frag).
    blur_pipeline: vk.VkPipeline,
};
pub const struct_rvn_vk_pass_t = rvn_vk_pass_t;

/// An image the backend renders to and then samples.
pub const rvn_vk_target_t = extern struct {
    image: vk.VkImage,
    memory: vk.VkDeviceMemory,
    view: vk.VkImageView,
    framebuffer: vk.VkFramebuffer,
    /// Samples the image (set 0 of the pipelines).
    set: vk.VkDescriptorSet,
    pool: vk.VkDescriptorPool,
    width: u32,
    height: u32,
};
pub const struct_rvn_vk_target_t = rvn_vk_target_t;

/// Per-frame resources of a window: a frame is recorded while the previous one is on the GPU.
pub const rvn_vk_frame_t = extern struct {
    pool: vk.VkCommandPool,
    commands: vk.VkCommandBuffer,
    fence: vk.VkFence,
    acquired: vk.VkSemaphore,
    /// R_TRUE while the fence belongs to a submitted frame.
    submitted: c_int,
    instances: rvn_vk_buffer_t,
};
pub const struct_rvn_vk_frame_t = rvn_vk_frame_t;

pub const rvn_vk_surface_t = extern struct {
    used: c_int,
    window: raven.Rid,
    surface: vk.VkSurfaceKHR,
    swapchain: vk.VkSwapchainKHR,
    format: vk.VkSurfaceFormatKHR,
    pass: [*c]rvn_vk_pass_t,
    extent: vk.VkExtent2D,
    /// Size Raven asked for when the swapchain was created.
    requested_width: u32,
    requested_height: u32,
    image_count: u32,
    images: [RVN_VK_MAX_IMAGES]vk.VkImage,
    views: [RVN_VK_MAX_IMAGES]vk.VkImageView,
    framebuffers: [RVN_VK_MAX_IMAGES]vk.VkFramebuffer,
    /// Signaled when rendering to the image is finished; waited by the presentation.
    rendered: [RVN_VK_MAX_IMAGES]vk.VkSemaphore,
    frames: [RVN_VK_FRAMES]rvn_vk_frame_t,
    frame_cursor: u32,
    /// The swapchain no longer matches the window.
    out_of_date: c_int,
    /// vsync of the present mode of the swapchain
    present_vsync: c_int,
    /// The swapchain images can be read back (Rwindow_capture).
    can_capture: c_int,
    /// The window can be seen through: the swapchain is asked to carry alpha.
    transparent: c_int,

    // glass (vk_glass.c): created the first time a frame of the window contains glass
    glass_ready: c_int,
    /// The backdrop images hold a whole capture: the next ones may only refresh an area.
    glass_filled: c_int,
    /// The frame itself: glass cannot read the image it is drawn into, so it is drawn here.
    scene: rvn_vk_target_t,
    /// Halved copies of the frame; the first one is the "sharp" backdrop.
    down: [RVN_VK_BLUR_LEVELS]rvn_vk_target_t,
    /// Enlarged back; the last one is the blurred backdrop.
    up: [RVN_VK_BLUR_LEVELS - 1]rvn_vk_target_t,
    /// Set 1 of the UI pipeline: sharp + blurred backdrop.
    backdrop_set: vk.VkDescriptorSet,
};
pub const struct_rvn_vk_surface_t = rvn_vk_surface_t;

/// A fragment shader of an effect (raven_shader.h) and its pipeline for each pass.
pub const rvn_vk_shader_t = extern struct {
    used: c_int,
    id: raven.Rid,
    module: vk.VkShaderModule,
    /// By index in g_vk.passes, made the first time the shader is drawn with that pass.
    pipelines: [RVN_VK_MAX_PASSES]vk.VkPipeline,
    /// Making the pipeline failed (the shader does not match raven_effect.glsl): not tried again.
    failed: [RVN_VK_MAX_PASSES]c_int,
};
pub const struct_rvn_vk_shader_t = rvn_vk_shader_t;

// ---------------------------------------------------------------------------
//  Global state
// ---------------------------------------------------------------------------

pub const rvn_vk_state_t = extern struct {
    initialized: c_int,
    info: raven.RBackendInitInfo,

    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
    /// The instance and device belong to the application (Rvulkan_set_external_device).
    external: c_int,
    messenger: vk.VkDebugUtilsMessengerEXT,
    memory: vk.VkPhysicalDeviceMemoryProperties,
    api_version: u32,
    /// Memory of textures can be exported (external memory fd / win32).
    can_share: c_int,

    // vk_pipeline.c
    vertex_shader: vk.VkShaderModule,
    fragment_shader: vk.VkShaderModule,
    set_layout: vk.VkDescriptorSetLayout,
    pipeline_layout: vk.VkPipelineLayout,
    sampler_linear: vk.VkSampler,
    sampler_nearest: vk.VkSampler,
    passes: [RVN_VK_MAX_PASSES]rvn_vk_pass_t,
    pass_count: u32,
    pools: [*c]vk.VkDescriptorPool,
    pool_used: [*c]u32,
    pool_count: u32,
    pool_cap: u32,
    blur_vertex_shader: vk.VkShaderModule,
    blur_fragment_shader: vk.VkShaderModule,
    blur_layout: vk.VkPipelineLayout,
    /// Layout of set 1 of the UI pipeline: the two backdrop textures.
    backdrop_layout: vk.VkDescriptorSetLayout,
    backdrop_pool: vk.VkDescriptorPool,
    /// Bound when a window has no backdrop: both textures are white.
    backdrop_default: vk.VkDescriptorSet,
    /// Effects, by the index of their handle.
    shaders: [*c]rvn_vk_shader_t,
    shader_cap: u32,

    // vk_texture.c
    textures: [*c]rvn_vk_texture_t,
    texture_cap: u32,
    /// 1x1 white texture bound when a command has no texture.
    white: rvn_vk_texture_t,
    upload_pool: vk.VkCommandPool,
    upload_commands: vk.VkCommandBuffer,
    upload_fence: vk.VkFence,
    staging: rvn_vk_buffer_t,
    staging_used: vk.VkDeviceSize,
    /// R_TRUE while upload commands are recorded and not yet submitted.
    upload_open: c_int,

    // vk_surface.c
    surfaces: [*c]rvn_vk_surface_t,
    surface_cap: u32,
    xcb_library: ?*anyopaque,
};
pub const struct_rvn_vk_state_t = rvn_vk_state_t;

pub extern var g_vk: rvn_vk_state_t;

/// Reports a failed Vulkan call and evaluates to R_TRUE when `result` is an error.
pub extern fn rvn_vk_failed(result: vk.VkResult, what: [*c]const u8) c_int;

// ---------------------------------------------------------------------------
//  vk_device.c
// ---------------------------------------------------------------------------

/// Configuration set before Rinit through raven_vulkan.h.
pub const rvn_vk_config_t = extern struct {
    external: c_int,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
    lock: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    unlock: ?*const fn (user_data: ?*anyopaque) callconv(.c) void,
    lock_user_data: ?*anyopaque,
};
pub const struct_rvn_vk_config_t = rvn_vk_config_t;

pub extern var g_vk_config: rvn_vk_config_t;

pub extern fn rvn_vk_device_init() c_int;
pub extern fn rvn_vk_device_shutdown() void;

/// Names of the extensions Raven needs; used by raven_vulkan.h and by device creation.
/// `const char* const*` is `[*c]const [*c]const u8`.
pub extern fn rvn_vk_instance_extensions(count: [*c]u32) [*c]const [*c]const u8;
pub extern fn rvn_vk_device_extensions(count: [*c]u32) [*c]const [*c]const u8;

/// The queue may be shared with the application: every use is bracketed by these.
pub extern fn rvn_vk_queue_lock() void;
pub extern fn rvn_vk_queue_unlock() void;

/// Index of a memory type allowed by `type_bits` with all of `flags`, or UINT32_MAX.
pub extern fn rvn_vk_find_memory_type(type_bits: u32, flags: vk.VkMemoryPropertyFlags) u32;

/// Creates a host-visible, persistently mapped buffer.
pub extern fn rvn_vk_buffer_create(buffer: [*c]rvn_vk_buffer_t, size: vk.VkDeviceSize, usage: vk.VkBufferUsageFlags) c_int;
pub extern fn rvn_vk_buffer_destroy(buffer: [*c]rvn_vk_buffer_t) void;

// ---------------------------------------------------------------------------
//  vk_pipeline.c
// ---------------------------------------------------------------------------

pub extern fn rvn_vk_pipeline_init() c_int;
pub extern fn rvn_vk_pipeline_shutdown() void;
/// Returns the render pass + pipeline of a color format, creating them on first use.
pub extern fn rvn_vk_pass_get(format: vk.VkFormat) [*c]rvn_vk_pass_t;

/// Effects (raven_shader.h): the backend table entries, and the pipeline of a shader for a pass (NULL handle: cannot draw it).
pub extern fn rvn_vk_shader_create(shader: raven.Rid, spirv: [*c]const u32, size: usize) c_int;
pub extern fn rvn_vk_shader_destroy(shader: raven.Rid) void;
pub extern fn rvn_vk_shader_pipeline(shader: raven.Rid, pass: [*c]rvn_vk_pass_t) vk.VkPipeline;
/// Allocates the descriptor set of a texture.
pub extern fn rvn_vk_set_allocate(set: [*c]vk.VkDescriptorSet, pool: [*c]vk.VkDescriptorPool) c_int;
pub extern fn rvn_vk_set_free(set: vk.VkDescriptorSet, pool: vk.VkDescriptorPool) void;
pub extern fn rvn_vk_set_write(set: vk.VkDescriptorSet, view: vk.VkImageView, sampler: vk.VkSampler) void;
/// Allocates and fills a backdrop set (set 1 of the UI pipeline).
pub extern fn rvn_vk_backdrop_set_create(set: [*c]vk.VkDescriptorSet, sharp: vk.VkImageView, blurred: vk.VkImageView) c_int;
pub extern fn rvn_vk_backdrop_set_destroy(set: vk.VkDescriptorSet) void;

// ---------------------------------------------------------------------------
//  vk_glass.c
// ---------------------------------------------------------------------------

/// Creates the offscreen images of a window for its current swapchain. R_FALSE: draw without glass.
pub extern fn rvn_vk_glass_prepare(surface: [*c]rvn_vk_surface_t) c_int;
pub extern fn rvn_vk_glass_release(surface: [*c]rvn_vk_surface_t) void;
/// Begins drawing into the offscreen frame: cleared when `clear` is given, continued otherwise.
pub extern fn rvn_vk_glass_begin_scene(commands: vk.VkCommandBuffer, surface: [*c]const rvn_vk_surface_t, clear: [*c]const vk.VkClearValue) void;
/// Between two scene passes: copies and blurs the frame drawn so far into the
/// backdrop textures. `rect` is the area that changed, in pixels; the rest of
/// the textures keeps what the earlier captures put there.
pub extern fn rvn_vk_glass_capture(commands: vk.VkCommandBuffer, surface: [*c]rvn_vk_surface_t, scale: f32, rect: [*c]const c_int) void;
/// Inside the swapchain pass: draws the finished offscreen frame.
pub extern fn rvn_vk_glass_present_scene(commands: vk.VkCommandBuffer, surface: [*c]const rvn_vk_surface_t) void;

// ---------------------------------------------------------------------------
//  vk_texture.c
// ---------------------------------------------------------------------------

pub extern fn rvn_vk_textures_init() c_int;
pub extern fn rvn_vk_textures_shutdown() void;

pub extern fn rvn_vk_texture_create(texture: raven.Rid, desc: [*c]const raven.RTextureDesc, pixels: ?*const anyopaque) c_int;
pub extern fn rvn_vk_texture_update(texture: raven.Rid, x: raven.Ruint, y: raven.Ruint, width: raven.Ruint, height: raven.Ruint, pixels: ?*const anyopaque) void;
pub extern fn rvn_vk_texture_set_filter(texture: raven.Rid, filter: raven.RFilterType) void;
pub extern fn rvn_vk_texture_destroy(texture: raven.Rid) void;

/// Texture of a handle, or NULL.
pub extern fn rvn_vk_texture_find(texture: raven.Rid) [*c]rvn_vk_texture_t;
/// Makes a texture out of an image view of the application (replaces the previous view).
pub extern fn rvn_vk_texture_wrap(texture: raven.Rid, view: vk.VkImageView, sampler: vk.VkSampler, width: u32, height: u32) c_int;
/// Creates an RGBA8 texture whose memory can be exported.
pub extern fn rvn_vk_texture_create_shared(texture: raven.Rid, width: u32, height: u32) c_int;
/// Exports the memory of a shared texture as a new fd / HANDLE.
pub extern fn rvn_vk_texture_export(texture: raven.Rid, handle: [*c]isize, allocation_size: [*c]u64) c_int;

/// Submits the pending texture uploads and waits for them.
pub extern fn rvn_vk_uploads_flush() void;

// ---------------------------------------------------------------------------
//  vk_surface.c
// ---------------------------------------------------------------------------

pub extern fn rvn_vk_surface_create(window: raven.Rid, native: [*c]const raven.RNativeWindow, width: raven.Ruint, height: raven.Ruint) c_int;
pub extern fn rvn_vk_surface_destroy(window: raven.Rid) void;
pub extern fn rvn_vk_surfaces_shutdown() void;
pub extern fn rvn_vk_surface_find(window: raven.Rid) [*c]rvn_vk_surface_t;
/// (Re)creates the swapchain. Returns R_FALSE when the window cannot be rendered now (minimized).
pub extern fn rvn_vk_swapchain_create(surface: [*c]rvn_vk_surface_t, width: u32, height: u32) c_int;
/// Waits until the GPU finished every frame submitted for every window.
pub extern fn rvn_vk_wait_frames() void;

// ---------------------------------------------------------------------------
//  vk_frame.c
// ---------------------------------------------------------------------------

pub extern fn rvn_vk_render_frame(data: [*c]const raven.RDrawData, capture: [*c]raven.RCapture) void;
