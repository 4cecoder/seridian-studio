// Translated to Zig from vendor/raven/src/render/renderer.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/renderer.h
// Bridge between the UI thread and the rendering backend.
//
// Every backend call is turned into a command and executed, in submission
// order, by a dedicated render thread. The UI thread never waits for the GPU
// except for back-pressure: it will not queue more than a couple of frames
// per window. When the render thread is disabled, commands run inline.
//
//      UI thread                               render thread
//   paint -> frame packet --+
//   texture create/update --+--> queue --> backend (Vulkan) --> present
//   surface create/destroy -+
//
// Needs core/thread_h.zig (rvn_atomic_t) - the header unit of core/thread.h.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const thread = @import("../core/thread_h.zig");
const draw = @import("draw_h.zig");

// ---------------------------------------------------------------------------
//  Textures (render/texture.c): UI-thread description of a GPU texture
// ---------------------------------------------------------------------------

pub const rvn_texture_t = extern struct {
    id: raven.Rid,
    width: c_int,
    height: c_int,
    format: raven.RTextureFormat,
    filter: raven.RFilterType,
    /// 1 once the pixels were handed to the renderer, or decoding failed.
    ready: thread.rvn_atomic_t,
    /// R_TRUE while the backend texture exists.
    created: c_int,
    /// Created by a backend-specific function (wrapped image view, shared memory).
    external: c_int,
};
pub const struct_rvn_texture_t = rvn_texture_t;

pub extern fn rvn_texture_get(id: raven.Rid) [*c]rvn_texture_t;
/// Allocates a handle with no backend texture yet.
pub extern fn rvn_texture_register() [*c]rvn_texture_t;
/// Creates a texture from raw pixels. Takes ownership of `pixels` (rvn_alloc'ed, may be NULL).
pub extern fn rvn_texture_create_raw(width: c_int, height: c_int, format: raven.RTextureFormat, filter: raven.RFilterType, pixels: ?*anyopaque) raven.Rid;
pub extern fn rvn_textures_shutdown() void;

// ---------------------------------------------------------------------------
//  Shaders (render/shader.c): fragment shaders of effects
// ---------------------------------------------------------------------------

pub const rvn_shader_t = extern struct {
    id: raven.Rid,
    /// R_SHADER_* flags given at creation (R_SHADER_BACKDROP: reads what is behind).
    flags: raven.Ruint,
    /// The backend accepted it (or the backend has no shaders: drawn as rectangles).
    created: c_int,
    /// Built-in effect it stands for, or -1.
    effect: c_int,
};
pub const struct_rvn_shader_t = rvn_shader_t;

pub extern fn rvn_shader_get(id: raven.Rid) [*c]rvn_shader_t;
pub extern fn rvn_shaders_shutdown() void;
/// The shader of a .spv file, made once per path and flags and kept until the end (the Effect attribute).
pub extern fn rvn_shader_from_file_cached(path: [*c]const u8, flags: raven.Ruint) raven.Rid;
/// The SPIR-V words are rvn_alloc'ed; the renderer takes ownership.
pub extern fn rvn_renderer_create_shader(shader: raven.Rid, spirv: [*c]u32, size: usize) void;
pub extern fn rvn_renderer_destroy_shader(shader: raven.Rid) void;

/// Decodes an image file into RGBA8 (render/image_decode.c). Free with rvn_free.
pub extern fn rvn_image_decode(data: [*c]const u8, size: usize, width: [*c]c_int, height: [*c]c_int) [*c]u8;
/// Downloads and decodes an HTTP(S) image asynchronously. Internal resource helper.
pub extern fn rvn_texture_create_from_url_async(url: [*c]const u8) raven.Rid;

// ---------------------------------------------------------------------------
//  Renderer (render/renderer.c)
// ---------------------------------------------------------------------------

pub extern fn rvn_renderer_init(backend: [*c]const raven.RBackendVTable, info: [*c]const raven.RBackendInitInfo, threaded: c_int) c_int;
pub extern fn rvn_renderer_shutdown() void;
pub extern fn rvn_renderer_is_threaded() c_int;
/// Sets a function called every few milliseconds while the UI thread is
/// blocked on the render thread (rvn_platform_t::wait_service). NULL = none.
/// Call after rvn_renderer_init.
pub extern fn rvn_renderer_set_wait_service(service: ?*const fn () callconv(.c) void) void;

/// Blocks until the surface exists.
pub extern fn rvn_renderer_create_surface(window: raven.Rid, native: [*c]const raven.RNativeWindow, width: u32, height: u32) c_int;
/// Blocks until every queued frame of the window is rendered and the surface destroyed.
pub extern fn rvn_renderer_destroy_surface(window: raven.Rid) void;

/// The pixel buffers are rvn_alloc'ed; the renderer takes ownership and frees them.
pub extern fn rvn_renderer_create_texture(texture: raven.Rid, desc: [*c]const raven.RTextureDesc, pixels: ?*anyopaque) void;
pub extern fn rvn_renderer_update_texture(texture: raven.Rid, x: u32, y: u32, width: u32, height: u32, pixels: ?*anyopaque) void;
pub extern fn rvn_renderer_set_texture_filter(texture: raven.Rid, filter: raven.RFilterType) void;
pub extern fn rvn_renderer_destroy_texture(texture: raven.Rid) void;

pub const rvn_render_fn = ?*const fn (arg: ?*anyopaque) callconv(.c) void;
/// Runs a function on the render thread, in order with the other commands.
pub extern fn rvn_renderer_call(function: rvn_render_fn, arg: ?*anyopaque, wait: c_int) void;
/// Blocks until every command queued so far has been executed.
pub extern fn rvn_renderer_sync() void;

/// One frame of one window travelling from the UI thread to the render thread.
pub const rvn_frame_t = extern struct {
    list: draw.rvn_drawlist_t,
    data: raven.RDrawData,
    /// Optional: receives the rendered pixels.
    capture: [*c]raven.RCapture,
    /// Optional counters owned by the window.
    frames_in_flight: [*c]thread.rvn_atomic_t,
    render_us: [*c]thread.rvn_atomic_t,
    next: [*c]rvn_frame_t,
};
pub const struct_rvn_frame_t = rvn_frame_t;

/// Returns an empty frame packet (recycled, so its arrays keep their capacity).
pub extern fn rvn_renderer_acquire_frame() [*c]rvn_frame_t;
/// Blocks while `frames_in_flight` is at least `max_frames`.
pub extern fn rvn_renderer_throttle(frames_in_flight: [*c]thread.rvn_atomic_t, max_frames: c_int) void;
/// Queues the frame. `frame->data` must be filled except for the instance / command arrays.
pub extern fn rvn_renderer_submit_frame(frame: [*c]rvn_frame_t) void;

// Built-in backends
pub extern fn rvn_backend_null() [*c]const raven.RBackendVTable;
/// Defined only when RAVEN_BACKEND_VULKAN_ENABLED (config.backend_vulkan).
pub extern fn rvn_backend_vulkan() [*c]const raven.RBackendVTable;
