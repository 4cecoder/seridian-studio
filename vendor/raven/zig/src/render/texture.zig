// Translated to Zig from vendor/raven/src/render/texture.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/texture.c
// Texture objects and the public texture API, including asynchronous
// decoding on the job system.

const raven = @import("raven");
const base = @import("../core/base_h.zig");
const ctx = @import("../core/context_h.zig");
const thread = @import("../core/thread_h.zig");
const handle = @import("../core/handle_h.zig");
const jobs = @import("../core/jobs_h.zig");
const fs = @import("../core/fs_h.zig");
const renderer = @import("renderer_h.zig");

// void rvn_tasks_run(void); /* core/context.c */
extern fn rvn_tasks_run() void;

export fn rvn_texture_get(id: raven.Rid) [*c]renderer.rvn_texture_t {
    return @ptrCast(@alignCast(handle.rvn_pool_get(&ctx.g_rvn.textures, id)));
}

export fn rvn_texture_register() [*c]renderer.rvn_texture_t {
    const texture: [*c]renderer.rvn_texture_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(renderer.rvn_texture_t))));
    texture.*.format = raven.R_TEXTURE_RGBA8;
    texture.*.filter = raven.R_FILTER_LINEAR;
    texture.*.id = handle.rvn_pool_add(&ctx.g_rvn.textures, texture);
    if (texture.*.id == raven.R_INVALID_ID) {
        base.rvn_free(texture);
        return null;
    }
    return texture;
}

// Sends the pixels to the renderer. Takes ownership of `pixels`.
fn rvn_texture_upload(texture: [*c]renderer.rvn_texture_t, width: c_int, height: c_int, pixels: ?*anyopaque) void {
    var desc: raven.RTextureDesc = undefined;
    if (texture.*.created != 0) renderer.rvn_renderer_destroy_texture(texture.*.id);
    texture.*.width = width;
    texture.*.height = height;
    desc.width = @bitCast(width);
    desc.height = @bitCast(height);
    desc.format = texture.*.format;
    desc.filter = texture.*.filter;
    renderer.rvn_renderer_create_texture(texture.*.id, &desc, pixels);
    texture.*.created = raven.R_TRUE;
    thread.rvn_atomic_store(&texture.*.ready, 1);
}

export fn rvn_texture_create_raw(width: c_int, height: c_int, format: raven.RTextureFormat, filter: raven.RFilterType, pixels: ?*anyopaque) raven.Rid {
    var texture: [*c]renderer.rvn_texture_t = undefined;
    if (width <= 0 or height <= 0 or width > 16384 or height > 16384) {
        base.rvn_free(pixels);
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "invalid texture size %d x %d", width, height);
        return raven.R_INVALID_ID;
    }
    texture = rvn_texture_register();
    if (texture == null) {
        base.rvn_free(pixels);
        return raven.R_INVALID_ID;
    }
    texture.*.format = format;
    texture.*.filter = filter;
    rvn_texture_upload(texture, width, height, pixels);
    return texture.*.id;
}

export fn rvn_textures_shutdown() void {
    var i: u32 = 0;
    while (i < ctx.g_rvn.textures.used) : (i += 1) {
        const texture: [*c]renderer.rvn_texture_t = @ptrCast(@alignCast(handle.rvn_pool_at(&ctx.g_rvn.textures, i)));
        if (texture == null) continue;
        if (texture.*.created != 0) renderer.rvn_renderer_destroy_texture(texture.*.id);
        handle.rvn_pool_remove(&ctx.g_rvn.textures, texture.*.id);
        base.rvn_free(texture);
    }
}

// ---------------------------------------------------------------------------
//  Asynchronous decoding
// ---------------------------------------------------------------------------

const rvn_texture_job_t = extern struct {
    id: raven.Rid,
    data: [*c]u8,
    size: usize,
    path: [*c]u8,
    pixels: [*c]u8,
    width: c_int,
    height: c_int,
};

// UI thread: the decoded pixels become the texture, unless it was deleted meanwhile.
fn rvn_texture_job_finish(arg: ?*anyopaque) callconv(.c) void {
    const job: [*c]rvn_texture_job_t = @ptrCast(@alignCast(arg));
    const texture = if (ctx.g_rvn.initialized != 0) rvn_texture_get(job.*.id) else null;
    if (texture != null and job.*.pixels != null) {
        rvn_texture_upload(texture, job.*.width, job.*.height, job.*.pixels);
        job.*.pixels = null;
        ctx.rvn_invalidate_all_windows();
    } else if (texture != null) {
        thread.rvn_atomic_store(&texture.*.ready, 1);
        base.rvn_error(raven.R_ERROR_INVALID_FILE_FORMAT, raven.R_SEVERITY_ERROR, "asynchronous texture: cannot decode %s", if (job.*.path != null) job.*.path else @as([*c]const u8, "the image"));
    }
    base.rvn_free(job.*.pixels);
    base.rvn_free(job.*.path);
    base.rvn_free(job);
}

// Worker thread.
fn rvn_texture_job_run(arg: ?*anyopaque) callconv(.c) void {
    const job: [*c]rvn_texture_job_t = @ptrCast(@alignCast(arg));
    if (job.*.path != null) {
        if (fs.rvn_is_http_url(job.*.path) != 0) {
            var downloaded_size: usize = 0;
            var downloaded: [*c]u8 = null;
            if (fs.rvn_fs_download_url(job.*.path, &downloaded, &downloaded_size) != 0) {
                job.*.data = downloaded;
                job.*.size = downloaded_size;
            }
        } else job.*.data = base.rvn_read_file(job.*.path, &job.*.size);
    }
    if (job.*.data != null) job.*.pixels = renderer.rvn_image_decode(job.*.data, job.*.size, &job.*.width, &job.*.height);
    base.rvn_free(job.*.data);
    job.*.data = null;
    raven.Rtask_post(rvn_texture_job_finish, job);
}

fn rvn_texture_create_async(data: [*c]const u8, size: usize, path: [*c]const u8) raven.Rid {
    const texture = rvn_texture_register();
    var job: [*c]rvn_texture_job_t = undefined;
    if (texture == null) return raven.R_INVALID_ID;
    job = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_texture_job_t))));
    job.*.id = texture.*.id;
    if (path != null) {
        job.*.path = base.rvn_strdup(path);
    } else {
        job.*.data = @ptrCast(@alignCast(base.rvn_alloc(size)));
        @memcpy(job.*.data[0..size], data[0..size]);
        job.*.size = size;
    }
    jobs.rvn_jobs_submit(null, rvn_texture_job_run, job);
    return texture.*.id;
}

// ---------------------------------------------------------------------------
//  Public API
// ---------------------------------------------------------------------------

export fn Rtexture_create(data: [*c]const u8, data_size: usize) raven.Rid {
    var width: c_int = 0;
    var height: c_int = 0;
    var pixels: [*c]u8 = undefined;
    if (ctx.rvn_api_check("Rtexture_create") == 0) return raven.R_INVALID_ID;
    pixels = renderer.rvn_image_decode(data, data_size, &width, &height);
    if (pixels == null) {
        base.rvn_error(raven.R_ERROR_INVALID_FILE_FORMAT, raven.R_SEVERITY_ERROR, "Rtexture_create: cannot decode the image");
        return raven.R_INVALID_ID;
    }
    return rvn_texture_create_raw(width, height, raven.R_TEXTURE_RGBA8, raven.R_FILTER_LINEAR, pixels);
}

export fn Rtexture_create_async(data: [*c]const u8, data_size: usize) raven.Rid {
    if (ctx.rvn_api_check("Rtexture_create_async") == 0) return raven.R_INVALID_ID;
    if (data == null or data_size == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtexture_create_async: empty buffer");
        return raven.R_INVALID_ID;
    }
    return rvn_texture_create_async(data, data_size, null);
}

export fn rvn_texture_create_from_url_async(url: [*c]const u8) raven.Rid {
    if (ctx.rvn_api_check("rvn_texture_create_from_url_async") == 0) return raven.R_INVALID_ID;
    if (url == null or fs.rvn_is_http_url(url) == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtexture_create_from_url_async: URL must use http:// or https://");
        return raven.R_INVALID_ID;
    }
    return rvn_texture_create_async(null, 0, url);
}

export fn Rtexture_create_from_file(path: [*c]const u8) raven.Rid {
    var size: usize = 0;
    var data: [*c]u8 = undefined;
    var width: c_int = 0;
    var height: c_int = 0;
    var pixels: [*c]u8 = undefined;
    if (ctx.rvn_api_check("Rtexture_create_from_file") == 0) return raven.R_INVALID_ID;
    data = base.rvn_read_file(path, &size);
    if (data == null) {
        base.rvn_error(raven.R_ERROR_FILE_NOT_FOUND, raven.R_SEVERITY_ERROR, "Rtexture_create_from_file: cannot read '%s'", if (path != null) path else @as([*c]const u8, ""));
        return raven.R_INVALID_ID;
    }
    pixels = renderer.rvn_image_decode(data, size, &width, &height);
    base.rvn_free(data);
    if (pixels == null) {
        base.rvn_error(raven.R_ERROR_INVALID_FILE_FORMAT, raven.R_SEVERITY_ERROR, "Rtexture_create_from_file: cannot decode '%s'", path);
        return raven.R_INVALID_ID;
    }
    return rvn_texture_create_raw(width, height, raven.R_TEXTURE_RGBA8, raven.R_FILTER_LINEAR, pixels);
}

export fn Rtexture_create_from_file_async(path: [*c]const u8) raven.Rid {
    if (ctx.rvn_api_check("Rtexture_create_from_file_async") == 0) return raven.R_INVALID_ID;
    if (path == null) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtexture_create_from_file_async: NULL path");
        return raven.R_INVALID_ID;
    }
    return rvn_texture_create_async(null, 0, path);
}

export fn Rtexture_create_from_pixels(rgba: [*c]const u8, width: c_int, height: c_int) raven.Rid {
    var copy: [*c]u8 = undefined;
    var size: usize = undefined;
    if (ctx.rvn_api_check("Rtexture_create_from_pixels") == 0) return raven.R_INVALID_ID;
    if (rgba == null or width <= 0 or height <= 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtexture_create_from_pixels: invalid arguments");
        return raven.R_INVALID_ID;
    }
    size = (@as(usize, @intCast(width)) *% @as(usize, @intCast(height))) *% 4;
    copy = @ptrCast(@alignCast(base.rvn_alloc(size)));
    @memcpy(copy[0..size], rgba[0..size]);
    return rvn_texture_create_raw(width, height, raven.R_TEXTURE_RGBA8, raven.R_FILTER_LINEAR, copy);
}

export fn Rtexture_update(id: raven.Rid, rgba: [*c]const u8, width: c_int, height: c_int) void {
    var texture: [*c]renderer.rvn_texture_t = undefined;
    var copy: [*c]u8 = undefined;
    var size: usize = undefined;
    if (ctx.rvn_api_check("Rtexture_update") == 0) return;
    texture = rvn_texture_get(id);
    if (texture == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rtexture_update: invalid texture");
        return;
    }
    if (texture.*.external != 0 or texture.*.format != raven.R_TEXTURE_RGBA8) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rtexture_update: this texture cannot be updated");
        return;
    }
    if (rgba == null or width <= 0 or height <= 0 or width > 16384 or height > 16384) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtexture_update: invalid arguments");
        return;
    }
    size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    copy = @ptrCast(@alignCast(base.rvn_alloc(size)));
    @memcpy(copy[0..size], rgba[0..size]);
    if (texture.*.created != 0 and texture.*.width == width and texture.*.height == height) {
        renderer.rvn_renderer_update_texture(id, 0, 0, @bitCast(width), @bitCast(height), copy);
        ctx.rvn_repaint_all_windows();
    } else {
        // widgets sized after the texture must be measured again
        rvn_texture_upload(texture, width, height, copy);
        ctx.rvn_invalidate_all_windows();
    }
}

export fn Rtexture_is_ready(id: raven.Rid) c_int {
    const texture = if (ctx.g_rvn.initialized != 0) rvn_texture_get(id) else null;
    return if (texture != null and thread.rvn_atomic_load(&texture.*.ready) != 0) raven.R_TRUE else raven.R_FALSE;
}

export fn Rtexture_wait(id: raven.Rid) void {
    if (ctx.rvn_api_check("Rtexture_wait") == 0) return;
    while (true) {
        var texture = rvn_texture_get(id);
        if (texture == null or thread.rvn_atomic_load(&texture.*.ready) != 0) return;
        // the result is delivered by a task posted to this thread
        rvn_tasks_run();
        texture = rvn_texture_get(id);
        if (texture == null or thread.rvn_atomic_load(&texture.*.ready) != 0) return;
        thread.rvn_sleep_ms(1);
    }
}

export fn Rtexture_destroy(id: raven.Rid) void {
    var texture: [*c]renderer.rvn_texture_t = undefined;
    if (ctx.rvn_api_check("Rtexture_destroy") == 0) return;
    texture = rvn_texture_get(id);
    if (texture == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rtexture_destroy: invalid texture");
        return;
    }
    if (texture.*.created != 0) renderer.rvn_renderer_destroy_texture(id);
    // the image behind an external texture belongs to the application, which is
    // about to destroy it: return only once the backend no longer uses it
    if (texture.*.external != 0) renderer.rvn_renderer_sync();
    handle.rvn_pool_remove(&ctx.g_rvn.textures, id);
    base.rvn_free(texture);
    ctx.rvn_invalidate_all_windows();
}

export fn Rtexture_is_valid(id: raven.Rid) c_int {
    return if (ctx.g_rvn.initialized != 0 and rvn_texture_get(id) != null) raven.R_TRUE else raven.R_FALSE;
}

export fn Rtexture_get_size(id: raven.Rid, width: [*c]c_int, height: [*c]c_int) void {
    const texture = if (ctx.g_rvn.initialized != 0) rvn_texture_get(id) else null;
    if (width != null) width.* = if (texture != null) texture.*.width else 0;
    if (height != null) height.* = if (texture != null) texture.*.height else 0;
}

export fn Rtexture_set_filter(id: raven.Rid, filter: raven.RFilterType) void {
    var texture: [*c]renderer.rvn_texture_t = undefined;
    if (ctx.rvn_api_check("Rtexture_set_filter") == 0) return;
    texture = rvn_texture_get(id);
    if (texture == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rtexture_set_filter: invalid texture");
        return;
    }
    if (filter != raven.R_FILTER_LINEAR and filter != raven.R_FILTER_NEAREST) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rtexture_set_filter: invalid filter");
        return;
    }
    if (texture.*.filter == filter) return;
    texture.*.filter = filter;
    if (texture.*.created != 0) renderer.rvn_renderer_set_texture_filter(id, filter);
    ctx.rvn_repaint_all_windows();
}

export fn Rimage_decode(data: ?*const anyopaque, data_size: usize, width: [*c]c_int, height: [*c]c_int) [*c]u8 {
    var w: c_int = 0;
    var h: c_int = 0;
    const pixels = renderer.rvn_image_decode(@ptrCast(@alignCast(data)), data_size, &w, &h);
    if (width != null) width.* = if (pixels != null) w else 0;
    if (height != null) height.* = if (pixels != null) h else 0;
    return pixels;
}
