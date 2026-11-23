// Translated to Zig from vendor/raven/src/render/renderer.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - render/renderer.c
// Render thread and its command queue.

const std = @import("std");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const context_h = @import("../core/context_h.zig");
const thread_h = @import("../core/thread_h.zig");
const draw_h = @import("draw_h.zig");
const renderer_h = @import("renderer_h.zig");

// typedef enum rvn_rcmd_type_t {...} rvn_rcmd_type_t;   (private: integer constants)
const rvn_rcmd_type_t = c_uint;
const RVN_RCMD_INIT: rvn_rcmd_type_t = 0;
const RVN_RCMD_SHUTDOWN: rvn_rcmd_type_t = 1;
const RVN_RCMD_CREATE_SURFACE: rvn_rcmd_type_t = 2;
const RVN_RCMD_DESTROY_SURFACE: rvn_rcmd_type_t = 3;
const RVN_RCMD_CREATE_TEXTURE: rvn_rcmd_type_t = 4;
const RVN_RCMD_UPDATE_TEXTURE: rvn_rcmd_type_t = 5;
const RVN_RCMD_SET_TEXTURE_FILTER: rvn_rcmd_type_t = 6;
const RVN_RCMD_DESTROY_TEXTURE: rvn_rcmd_type_t = 7;
const RVN_RCMD_CREATE_SHADER: rvn_rcmd_type_t = 8;
const RVN_RCMD_DESTROY_SHADER: rvn_rcmd_type_t = 9;
const RVN_RCMD_FRAME: rvn_rcmd_type_t = 10;
const RVN_RCMD_CALL: rvn_rcmd_type_t = 11;
const RVN_RCMD_STOP: rvn_rcmd_type_t = 12;

/// Filled by the render thread for commands the UI thread waits for.
const rvn_rcmd_wait_t = extern struct {
    done: c_int,
    result: c_int,
};

const rvn_rcmd_t = extern struct {
    @"type": rvn_rcmd_type_t,
    id: raven.Rid,
    native: raven.RNativeWindow,
    desc: raven.RTextureDesc,
    init: raven.RBackendInitInfo,
    filter: raven.RFilterType,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    pixels: ?*anyopaque,
    frame: [*c]renderer_h.rvn_frame_t,
    function: renderer_h.rvn_render_fn,
    arg: ?*anyopaque,
    wait: [*c]rvn_rcmd_wait_t,
    next: [*c]rvn_rcmd_t,
};

const RVN_FRAME_POOL_MAX = 6;

const g_renderer_t = extern struct {
    backend: raven.RBackendVTable,
    threaded: c_int,
    running: c_int,
    thread: thread_h.rvn_thread_t,
    mutex: thread_h.rvn_mutex_t,
    /// Signalled when a command is queued.
    queue_cv: thread_h.rvn_cond_t,
    /// Broadcast when a waited command is done.
    done_cv: thread_h.rvn_cond_t,
    /// Broadcast when a frame has been rendered.
    frame_cv: thread_h.rvn_cond_t,
    head: [*c]rvn_rcmd_t,
    tail: [*c]rvn_rcmd_t,
    free_frames: [*c]renderer_h.rvn_frame_t,
    free_frame_count: c_int,
    /// Called while the UI thread waits for the render thread, or NULL.
    wait_service: ?*const fn () callconv(.c) void,
};

var g_renderer: g_renderer_t = std.mem.zeroes(g_renderer_t);

// ---------------------------------------------------------------------------
//  Execution (render thread, or the UI thread when not threaded)
// ---------------------------------------------------------------------------

fn rvn_frame_release(frame_: [*c]renderer_h.rvn_frame_t) void {
    var frame = frame_;
    thread_h.rvn_mutex_lock(&g_renderer.mutex);
    if (g_renderer.free_frame_count < RVN_FRAME_POOL_MAX) {
        frame.*.next = g_renderer.free_frames;
        g_renderer.free_frames = frame;
        g_renderer.free_frame_count += 1;
        frame = null;
    }
    thread_h.rvn_mutex_unlock(&g_renderer.mutex);
    if (frame != null) {
        draw_h.rvn_drawlist_free(&frame.*.list);
        base.rvn_free(frame);
    }
}

fn rvn_rcmd_execute(cmd: [*c]rvn_rcmd_t) c_int {
    const backend: [*c]const raven.RBackendVTable = &g_renderer.backend;
    var result: c_int = raven.R_TRUE;

    switch (cmd.*.@"type") {
        RVN_RCMD_INIT => {
            result = backend.*.Init.?(&cmd.*.init);
        },
        RVN_RCMD_SHUTDOWN => {
            backend.*.WaitIdle.?();
            backend.*.Shutdown.?();
        },
        RVN_RCMD_CREATE_SURFACE => {
            result = backend.*.CreateSurface.?(cmd.*.id, &cmd.*.native, cmd.*.width, cmd.*.height);
        },
        RVN_RCMD_DESTROY_SURFACE => {
            backend.*.DestroySurface.?(cmd.*.id);
        },
        RVN_RCMD_CREATE_TEXTURE => {
            result = backend.*.CreateTexture.?(cmd.*.id, &cmd.*.desc, cmd.*.pixels);
            base.rvn_free(cmd.*.pixels);
        },
        RVN_RCMD_UPDATE_TEXTURE => {
            backend.*.UpdateTexture.?(cmd.*.id, cmd.*.x, cmd.*.y, cmd.*.width, cmd.*.height, cmd.*.pixels);
            base.rvn_free(cmd.*.pixels);
        },
        RVN_RCMD_SET_TEXTURE_FILTER => {
            backend.*.SetTextureFilter.?(cmd.*.id, cmd.*.filter);
        },
        RVN_RCMD_CREATE_SHADER => {
            result = if (backend.*.CreateShader) |create_shader| create_shader(
                cmd.*.id,
                @as([*c]const u32, @ptrCast(@alignCast(cmd.*.pixels))),
                @as(usize, cmd.*.width),
            ) else raven.R_FALSE;
            base.rvn_free(cmd.*.pixels);
            cmd.*.pixels = null;
        },
        RVN_RCMD_DESTROY_SHADER => {
            if (backend.*.DestroyShader) |destroy_shader| destroy_shader(cmd.*.id);
        },
        RVN_RCMD_DESTROY_TEXTURE => {
            backend.*.DestroyTexture.?(cmd.*.id);
        },
        RVN_RCMD_FRAME => {
            const frame = cmd.*.frame;
            const start = thread_h.rvn_clock_seconds();
            backend.*.RenderFrame.?(&frame.*.data, frame.*.capture);
            if (frame.*.render_us != null) {
                const render_us: c_int = @intFromFloat((thread_h.rvn_clock_seconds() - start) * 1e6);
                thread_h.rvn_atomic_store(frame.*.render_us, render_us);
            }
            if (frame.*.frames_in_flight != null) {
                _ = thread_h.rvn_atomic_add(frame.*.frames_in_flight, -1);
                thread_h.rvn_mutex_lock(&g_renderer.mutex);
                thread_h.rvn_cond_broadcast(&g_renderer.frame_cv);
                thread_h.rvn_mutex_unlock(&g_renderer.mutex);
            }
            rvn_frame_release(frame);
            // a continuously redrawing window is paced by this wake-up
            context_h.rvn_wake();
        },
        RVN_RCMD_CALL => {
            if (cmd.*.function) |function| function(cmd.*.arg);
        },
        RVN_RCMD_STOP => {},
        else => {},
    }
    return result;
}

fn rvn_render_thread(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    while (true) {
        thread_h.rvn_mutex_lock(&g_renderer.mutex);
        while (g_renderer.head == null) thread_h.rvn_cond_wait(&g_renderer.queue_cv, &g_renderer.mutex);
        const cmd: [*c]rvn_rcmd_t = g_renderer.head;
        g_renderer.head = cmd.*.next;
        if (g_renderer.head == null) g_renderer.tail = null;
        thread_h.rvn_mutex_unlock(&g_renderer.mutex);

        const stop = cmd.*.@"type" == RVN_RCMD_STOP;
        const result = rvn_rcmd_execute(cmd);
        if (cmd.*.wait != null) {
            thread_h.rvn_mutex_lock(&g_renderer.mutex);
            cmd.*.wait.*.result = result;
            cmd.*.wait.*.done = raven.R_TRUE;
            thread_h.rvn_cond_broadcast(&g_renderer.done_cv);
            thread_h.rvn_mutex_unlock(&g_renderer.mutex);
        }
        base.rvn_free(cmd);
        if (stop) break;
    }
}

// Waits on a condition of the renderer (mutex held). On some window systems
// the UI thread must keep answering the window system while it is blocked on
// the render thread (see rvn_renderer_set_wait_service): the wait is then cut
// into short slices with a call to the service in between. The caller loops
// on its predicate, so returning early is harmless.
fn rvn_renderer_wait(cond: [*c]thread_h.rvn_cond_t) void {
    if (g_renderer.wait_service == null) {
        thread_h.rvn_cond_wait(cond, &g_renderer.mutex);
        return;
    }
    if (thread_h.rvn_cond_wait_timeout(cond, &g_renderer.mutex, 0.002) != 0) return;
    thread_h.rvn_mutex_unlock(&g_renderer.mutex);
    g_renderer.wait_service.?();
    thread_h.rvn_mutex_lock(&g_renderer.mutex);
}

export fn rvn_renderer_set_wait_service(service: ?*const fn () callconv(.c) void) void {
    g_renderer.wait_service = service;
}

/// Queues a command. With `wait`, blocks until it was executed and returns
/// its result. Takes ownership of `cmd`.
fn rvn_rcmd_submit(cmd: [*c]rvn_rcmd_t, wait: c_int) c_int {
    if (g_renderer.running == 0) {
        // renderer not started or already stopped: drop the command
        if (cmd.*.@"type" == RVN_RCMD_CREATE_TEXTURE or cmd.*.@"type" == RVN_RCMD_UPDATE_TEXTURE or cmd.*.@"type" == RVN_RCMD_CREATE_SHADER) base.rvn_free(cmd.*.pixels);
        if (cmd.*.@"type" == RVN_RCMD_FRAME) {
            if (cmd.*.frame.*.frames_in_flight != null) _ = thread_h.rvn_atomic_add(cmd.*.frame.*.frames_in_flight, -1);
            draw_h.rvn_drawlist_free(&cmd.*.frame.*.list);
            base.rvn_free(cmd.*.frame);
        }
        base.rvn_free(cmd);
        return raven.R_FALSE;
    }

    if (g_renderer.threaded == 0) {
        const result = rvn_rcmd_execute(cmd);
        base.rvn_free(cmd);
        return result;
    }

    var waiter: rvn_rcmd_wait_t = undefined;
    waiter.done = raven.R_FALSE;
    waiter.result = raven.R_TRUE;
    cmd.*.wait = if (wait != 0) &waiter else null;
    cmd.*.next = null;

    thread_h.rvn_mutex_lock(&g_renderer.mutex);
    if (g_renderer.tail != null) {
        g_renderer.tail.*.next = cmd;
    } else {
        g_renderer.head = cmd;
    }
    g_renderer.tail = cmd;
    thread_h.rvn_cond_signal(&g_renderer.queue_cv);
    if (wait != 0) {
        while (waiter.done == 0) rvn_renderer_wait(&g_renderer.done_cv);
    }
    thread_h.rvn_mutex_unlock(&g_renderer.mutex);
    return waiter.result;
}

fn rvn_rcmd_new(type_: rvn_rcmd_type_t, id: raven.Rid) [*c]rvn_rcmd_t {
    const cmd: [*c]rvn_rcmd_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_rcmd_t))));
    cmd.*.@"type" = type_;
    cmd.*.id = id;
    return cmd;
}

// ---------------------------------------------------------------------------
//  Lifecycle
// ---------------------------------------------------------------------------

export fn rvn_renderer_init(backend: [*c]const raven.RBackendVTable, info: [*c]const raven.RBackendInitInfo, threaded: c_int) c_int {
    @memset(std.mem.asBytes(&g_renderer), 0);
    g_renderer.backend = backend.*;
    g_renderer.threaded = threaded;
    thread_h.rvn_mutex_init(&g_renderer.mutex);
    thread_h.rvn_cond_init(&g_renderer.queue_cv);
    thread_h.rvn_cond_init(&g_renderer.done_cv);
    thread_h.rvn_cond_init(&g_renderer.frame_cv);

    if (threaded != 0 and thread_h.rvn_thread_create(&g_renderer.thread, &rvn_render_thread, null, "raven-render") == 0) {
        base.rvn_error(raven.R_ERROR_PLATFORM, raven.R_SEVERITY_WARNING, "cannot start the render thread, rendering on the UI thread");
        g_renderer.threaded = raven.R_FALSE;
    }
    g_renderer.running = raven.R_TRUE;

    // the backend is initialized on the thread that will use it
    const cmd = rvn_rcmd_new(RVN_RCMD_INIT, raven.R_INVALID_ID);
    cmd.*.init = info.*;
    const ok = rvn_rcmd_submit(cmd, raven.R_TRUE);
    if (ok == 0) {
        if (g_renderer.threaded != 0) {
            _ = rvn_rcmd_submit(rvn_rcmd_new(RVN_RCMD_STOP, raven.R_INVALID_ID), raven.R_FALSE);
            thread_h.rvn_thread_join(&g_renderer.thread);
        }
        g_renderer.running = raven.R_FALSE;
        thread_h.rvn_cond_destroy(&g_renderer.frame_cv);
        thread_h.rvn_cond_destroy(&g_renderer.done_cv);
        thread_h.rvn_cond_destroy(&g_renderer.queue_cv);
        thread_h.rvn_mutex_destroy(&g_renderer.mutex);
    }
    return ok;
}

export fn rvn_renderer_shutdown() void {
    if (g_renderer.running == 0) return;
    _ = rvn_rcmd_submit(rvn_rcmd_new(RVN_RCMD_SHUTDOWN, raven.R_INVALID_ID), raven.R_TRUE);
    if (g_renderer.threaded != 0) {
        _ = rvn_rcmd_submit(rvn_rcmd_new(RVN_RCMD_STOP, raven.R_INVALID_ID), raven.R_FALSE);
        thread_h.rvn_thread_join(&g_renderer.thread);
    }
    g_renderer.running = raven.R_FALSE;
    var frame = g_renderer.free_frames;
    while (frame != null) {
        const next = frame.*.next;
        draw_h.rvn_drawlist_free(&frame.*.list);
        base.rvn_free(frame);
        frame = next;
    }
    thread_h.rvn_cond_destroy(&g_renderer.frame_cv);
    thread_h.rvn_cond_destroy(&g_renderer.done_cv);
    thread_h.rvn_cond_destroy(&g_renderer.queue_cv);
    thread_h.rvn_mutex_destroy(&g_renderer.mutex);
    @memset(std.mem.asBytes(&g_renderer), 0);
}

export fn rvn_renderer_is_threaded() c_int {
    return g_renderer.threaded;
}

// ---------------------------------------------------------------------------
//  Commands
// ---------------------------------------------------------------------------

export fn rvn_renderer_create_surface(window: raven.Rid, native: [*c]const raven.RNativeWindow, width: u32, height: u32) c_int {
    const cmd = rvn_rcmd_new(RVN_RCMD_CREATE_SURFACE, window);
    cmd.*.native = native.*;
    cmd.*.width = width;
    cmd.*.height = height;
    return rvn_rcmd_submit(cmd, raven.R_TRUE);
}

export fn rvn_renderer_destroy_surface(window: raven.Rid) void {
    _ = rvn_rcmd_submit(rvn_rcmd_new(RVN_RCMD_DESTROY_SURFACE, window), raven.R_TRUE);
}

export fn rvn_renderer_create_texture(texture: raven.Rid, desc: [*c]const raven.RTextureDesc, pixels: ?*anyopaque) void {
    const cmd = rvn_rcmd_new(RVN_RCMD_CREATE_TEXTURE, texture);
    cmd.*.desc = desc.*;
    cmd.*.pixels = pixels;
    _ = rvn_rcmd_submit(cmd, raven.R_FALSE);
}

export fn rvn_renderer_update_texture(texture: raven.Rid, x: u32, y: u32, width: u32, height: u32, pixels: ?*anyopaque) void {
    const cmd = rvn_rcmd_new(RVN_RCMD_UPDATE_TEXTURE, texture);
    cmd.*.x = x;
    cmd.*.y = y;
    cmd.*.width = width;
    cmd.*.height = height;
    cmd.*.pixels = pixels;
    _ = rvn_rcmd_submit(cmd, raven.R_FALSE);
}

export fn rvn_renderer_set_texture_filter(texture: raven.Rid, filter: raven.RFilterType) void {
    const cmd = rvn_rcmd_new(RVN_RCMD_SET_TEXTURE_FILTER, texture);
    cmd.*.filter = filter;
    _ = rvn_rcmd_submit(cmd, raven.R_FALSE);
}

export fn rvn_renderer_destroy_texture(texture: raven.Rid) void {
    _ = rvn_rcmd_submit(rvn_rcmd_new(RVN_RCMD_DESTROY_TEXTURE, texture), raven.R_FALSE);
}

export fn rvn_renderer_create_shader(shader: raven.Rid, spirv: [*c]u32, size: usize) void {
    const cmd = rvn_rcmd_new(RVN_RCMD_CREATE_SHADER, shader);
    cmd.*.pixels = spirv;
    cmd.*.width = @truncate(size);
    _ = rvn_rcmd_submit(cmd, raven.R_FALSE);
}

export fn rvn_renderer_destroy_shader(shader: raven.Rid) void {
    _ = rvn_rcmd_submit(rvn_rcmd_new(RVN_RCMD_DESTROY_SHADER, shader), raven.R_FALSE);
}

export fn rvn_renderer_call(function: renderer_h.rvn_render_fn, arg: ?*anyopaque, wait: c_int) void {
    const cmd = rvn_rcmd_new(RVN_RCMD_CALL, raven.R_INVALID_ID);
    cmd.*.function = function;
    cmd.*.arg = arg;
    _ = rvn_rcmd_submit(cmd, wait);
}

export fn rvn_renderer_sync() void {
    if (g_renderer.running != 0 and g_renderer.threaded != 0) rvn_renderer_call(null, null, raven.R_TRUE);
}

// ---------------------------------------------------------------------------
//  Frames
// ---------------------------------------------------------------------------

export fn rvn_renderer_acquire_frame() [*c]renderer_h.rvn_frame_t {
    var frame: [*c]renderer_h.rvn_frame_t = null;
    if (g_renderer.running != 0) {
        thread_h.rvn_mutex_lock(&g_renderer.mutex);
        frame = g_renderer.free_frames;
        if (frame != null) {
            g_renderer.free_frames = frame.*.next;
            g_renderer.free_frame_count -= 1;
        }
        thread_h.rvn_mutex_unlock(&g_renderer.mutex);
    }
    if (frame == null) {
        frame = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(renderer_h.rvn_frame_t))));
        draw_h.rvn_drawlist_init(&frame.*.list);
    }
    draw_h.rvn_drawlist_reset(&frame.*.list);
    @memset(std.mem.asBytes(&frame.*.data), 0);
    frame.*.capture = null;
    frame.*.frames_in_flight = null;
    frame.*.render_us = null;
    frame.*.next = null;
    return frame;
}

export fn rvn_renderer_throttle(frames_in_flight: [*c]thread_h.rvn_atomic_t, max_frames: c_int) void {
    if (g_renderer.running == 0 or g_renderer.threaded == 0) return;
    thread_h.rvn_mutex_lock(&g_renderer.mutex);
    while (thread_h.rvn_atomic_load(frames_in_flight) >= max_frames) rvn_renderer_wait(&g_renderer.frame_cv);
    thread_h.rvn_mutex_unlock(&g_renderer.mutex);
}

export fn rvn_renderer_submit_frame(frame: [*c]renderer_h.rvn_frame_t) void {
    const cmd = rvn_rcmd_new(RVN_RCMD_FRAME, frame.*.data.window);
    frame.*.data.instances = frame.*.list.instances;
    frame.*.data.instance_count = frame.*.list.instance_count;
    frame.*.data.commands = frame.*.list.commands;
    frame.*.data.command_count = frame.*.list.command_count;
    if (frame.*.frames_in_flight != null) _ = thread_h.rvn_atomic_add(frame.*.frames_in_flight, 1);
    cmd.*.frame = frame;
    _ = rvn_rcmd_submit(cmd, raven.R_FALSE);
}
