// Translated to Zig from vendor/raven/src/core/context.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/context.c
// Library lifecycle, main loop, posted tasks, timers, actions, clipboard.

const std = @import("std");
const raven = @import("raven");
const config = @import("raven_config");
const base = @import("base_h.zig");
const ctx = @import("context_h.zig");
const thread = @import("thread_h.zig");
const handle = @import("handle_h.zig");
const jobs = @import("jobs_h.zig");
const heap = @import("heap_h.zig");
const fs_watch = @import("fs_watch_h.zig");
const ext = @import("externs.zig");
const widget_h = @import("../widget/widget_h.zig");
const plat = @import("../platform/platform_h.zig");
const libc = @import("../sys/libc.zig");

// rvn_context_t g_rvn;
export var g_rvn: ctx.rvn_context_t = std.mem.zeroes(ctx.rvn_context_t);

// static RBackendVTable g_custom_backend;
var g_custom_backend: raven.RBackendVTable = std.mem.zeroes(raven.RBackendVTable);
// static int g_custom_backend_set;
var g_custom_backend_set: c_int = 0;

// (the C prototype `void rvn_tasks_run(void);` is not needed in Zig: the function is defined below.)

/// `g_rvn.platform` is typed ?*const anyopaque in context_h.zig: the platform table is cast here.
fn platformOf() [*c]const plat.rvn_platform_t {
    return @ptrCast(@alignCast(g_rvn.platform));
}

// ---- Guards ----

export fn rvn_api_check(function: [*c]const u8) c_int {
    if (g_rvn.initialized == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "%s: Raven is not initialized", function);
        return raven.R_FALSE;
    }
    if (thread.rvn_thread_id() != g_rvn.ui_thread) {
        base.rvn_error(raven.R_ERROR_WRONG_THREAD, raven.R_SEVERITY_ERROR, "%s must be called from the UI thread (use Rtask_post from other threads)", function);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_dispatch_begin() void {
    g_rvn.dispatch_depth += 1;
}

export fn rvn_dispatch_end() void {
    g_rvn.dispatch_depth -= 1;
    if (g_rvn.dispatch_depth > 0) return;
    g_rvn.dispatch_depth = 0;
    // nobody up the stack holds pointers any more: release what was deleted
    if (g_rvn.dead_widget_count != 0) ext.rvn_widgets_collect();
    if (g_rvn.dead_window_count != 0) ext.rvn_windows_collect();
}

export fn rvn_wake() void {
    if (g_rvn.initialized != 0 and g_rvn.platform != null) platformOf().*.wake.?();
}

// ---- Initialization ----

export fn Rbackend_register(vtable: [*c]const raven.RBackendVTable) void {
    if (g_rvn.initialized != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rbackend_register must be called before Rinit");
        return;
    }
    if (vtable == null or vtable.*.Init == null or vtable.*.Shutdown == null or vtable.*.CreateSurface == null or
        vtable.*.DestroySurface == null or vtable.*.CreateTexture == null or vtable.*.UpdateTexture == null or
        vtable.*.SetTextureFilter == null or vtable.*.DestroyTexture == null or vtable.*.RenderFrame == null or
        vtable.*.WaitIdle == null)
    {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rbackend_register: every function of the table is required");
        return;
    }
    g_custom_backend = vtable.*;
    g_custom_backend_set = raven.R_TRUE;
}

fn rvn_select_backend(backend: raven.RBackend) [*c]const raven.RBackendVTable {
    switch (backend) {
        raven.R_BACKEND_VULKAN => {
            if (config.backend_vulkan) {
                return ext.rvn_backend_vulkan();
            } else {
                base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_FATAL, "Raven was built without the Vulkan backend");
                return null;
            }
        },
        raven.R_BACKEND_NULL => return ext.rvn_backend_null(),
        raven.R_BACKEND_CUSTOM => {
            if (g_custom_backend_set == 0) {
                base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_FATAL, "R_BACKEND_CUSTOM needs Rbackend_register first");
                return null;
            }
            return &g_custom_backend;
        },
        else => {},
    }
    base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_FATAL, "Rinit: unknown backend");
    return null;
}

export fn Rinit(backend: raven.RBackend) c_int {
    var desc: raven.RInitDesc = undefined;
    desc = std.mem.zeroes(raven.RInitDesc);
    desc.backend = backend;
    return Rinit_ex(&desc);
}

export fn Rinit_ex(user_desc: [*c]const raven.RInitDesc) c_int {
    var desc: raven.RInitDesc = undefined;
    var info: raven.RBackendInitInfo = undefined;
    var backend: [*c]const raven.RBackendVTable = undefined;
    var workers: c_int = undefined;
    var threaded: c_int = undefined;

    if (g_rvn.initialized != 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_WARNING, "Rinit: already initialized");
        return raven.R_FALSE;
    }
    desc = std.mem.zeroes(raven.RInitDesc);
    if (user_desc != null) desc = user_desc.*;
    if (desc.backend == 0) desc.backend = raven.R_BACKEND_VULKAN;

    backend = rvn_select_backend(desc.backend);
    if (backend == null) return raven.R_FALSE;

    g_rvn = std.mem.zeroes(ctx.rvn_context_t);
    g_rvn.ui_thread = thread.rvn_thread_id();
    g_rvn.start_time = thread.rvn_clock_seconds();
    g_rvn.ui_scale = if (desc.ui_scale > 0.0) desc.ui_scale else 1.0;
    g_rvn.vsync = @intFromBool(desc.disable_vsync == 0);
    g_rvn.backend = desc.backend;
    g_rvn.default_font = raven.R_INVALID_ID;
    handle.rvn_pool_init(&g_rvn.windows, handle.RVN_HANDLE_WINDOW);
    handle.rvn_pool_init(&g_rvn.widgets, handle.RVN_HANDLE_WIDGET);
    handle.rvn_pool_init(&g_rvn.fonts, handle.RVN_HANDLE_FONT);
    handle.rvn_pool_init(&g_rvn.textures, handle.RVN_HANDLE_TEXTURE);
    handle.rvn_pool_init(&g_rvn.shaders, handle.RVN_HANDLE_SHADER);
    handle.rvn_pool_init(&g_rvn.timers, handle.RVN_HANDLE_TIMER);
    handle.rvn_pool_init(&g_rvn.tree_items, handle.RVN_HANDLE_TREE_ITEM);
    handle.rvn_pool_init(&g_rvn.xml_documents, handle.RVN_HANDLE_XML_DOCUMENT);
    handle.rvn_pool_init(&g_rvn.xml_nodes, handle.RVN_HANDLE_XML_NODE);
    thread.rvn_mutex_init(&g_rvn.task_mutex);

    fail_platform: {
        fail_renderer: {
            // windowing
            g_rvn.platform = ext.rvn_platform_select(desc.headless);
            if (g_rvn.platform == null or
                platformOf().*.init.?(&widget_h.rvn_window_on_platform_event, &widget_h.rvn_window_region_at) == 0)
            {
                base.rvn_error(raven.R_ERROR_PLATFORM, raven.R_SEVERITY_FATAL, "Rinit: cannot initialize the %s window system", if (g_rvn.platform != null) platformOf().*.name else @as([*c]const u8, "native"));
                break :fail_platform;
            }

            // job system: leave one core to the UI thread and one to the render thread
            threaded = @intFromBool(desc.disable_render_thread == 0);
            if (desc.worker_threads < 0) {
                workers = 0;
            } else if (desc.worker_threads > 0) {
                workers = desc.worker_threads;
            } else {
                workers = thread.rvn_cpu_count() - 1 - (if (threaded != 0) @as(c_int, 1) else 0);
                workers = base.rvn_clampi(workers, 1, 16);
            }
            jobs.rvn_jobs_init(workers);

            // rendering
            info = std.mem.zeroes(raven.RBackendInitInfo);
            info.app_name = if (desc.app_name != null) desc.app_name else "Raven application";
            info.enable_validation = desc.enable_validation;
            info.vsync = g_rvn.vsync;
            info.window_system = platformOf().*.system;
            info.native_display = platformOf().*.native_display.?();
            if (ext.rvn_renderer_init(backend, &info, threaded) == 0) {
                base.rvn_error(raven.R_ERROR_BACKEND, raven.R_SEVERITY_FATAL, "Rinit: cannot initialize the %s backend", backend.*.name);
                break :fail_renderer;
            }
            ext.rvn_renderer_set_wait_service(platformOf().*.wait_service);

            g_rvn.initialized = raven.R_TRUE;
            ext.rvn_paint_init();
            ext.rvn_themes_init();
            ext.rvn_theme_apply(raven.R_THEME_DARK);
            ext.rvn_fonts_init();
            g_rvn.theme.font = g_rvn.default_font;
            g_rvn.last_update_time = thread.rvn_clock_seconds();
            return raven.R_TRUE;
        }
        // fail_renderer:
        jobs.rvn_jobs_shutdown();
        platformOf().*.shutdown.?();
    }
    // fail_platform:
    thread.rvn_mutex_destroy(&g_rvn.task_mutex);
    handle.rvn_pool_free(&g_rvn.windows);
    handle.rvn_pool_free(&g_rvn.widgets);
    handle.rvn_pool_free(&g_rvn.fonts);
    handle.rvn_pool_free(&g_rvn.textures);
    handle.rvn_pool_free(&g_rvn.shaders);
    handle.rvn_pool_free(&g_rvn.timers);
    handle.rvn_pool_free(&g_rvn.tree_items);
    handle.rvn_pool_free(&g_rvn.xml_documents);
    handle.rvn_pool_free(&g_rvn.xml_nodes);
    g_rvn = std.mem.zeroes(ctx.rvn_context_t);
    return raven.R_FALSE;
}

export fn Rshutdown() void {
    var i: u32 = undefined;
    if (rvn_api_check("Rshutdown") == 0) return;

    // Stop native filesystem notifications before draining posted UI tasks.
    fs_watch.rvn_fs_watch_stop();
    // windows first: this deletes every widget that is shown
    ext.rvn_windows_destroy_all();
    // then the widgets the application created but never attached
    i = 0;
    while (i < g_rvn.widgets.used) : (i += 1) {
        const widget: [*c]widget_h.rvn_widget_t = @ptrCast(@alignCast(handle.rvn_pool_at(&g_rvn.widgets, i)));
        // internal widgets are destroyed by the widget that owns them
        if (widget != null and widget.*.parent == null and (widget.*.flags & widget_h.RVN_WF_INTERNAL) == 0) ext.rvn_widget_destroy(widget);
    }
    ext.rvn_widgets_collect();

    // let the running jobs finish and deliver their results
    jobs.rvn_jobs_shutdown();
    rvn_tasks_run();

    i = 0;
    while (i < g_rvn.timers.used) : (i += 1) {
        const timer: [*c]ctx.rvn_timer_t = @ptrCast(@alignCast(handle.rvn_pool_at(&g_rvn.timers, i)));
        if (timer != null) {
            handle.rvn_pool_remove(&g_rvn.timers, timer.*.id);
            base.rvn_free(timer);
        }
    }

    ext.rvn_xml_shutdown();
    ext.rvn_locale_shutdown();
    ext.rvn_a11y_shutdown();
    ext.rvn_themes_shutdown();
    ext.rvn_dialogs_shutdown();
    ext.rvn_islands_shutdown();
    ext.rvn_languages_shutdown();
    ext.rvn_fonts_shutdown();
    ext.rvn_shaders_shutdown();
    ext.rvn_textures_shutdown();
    ext.rvn_paint_shutdown();
    base.rvn_memory_files_shutdown();
    ext.rvn_renderer_shutdown();
    platformOf().*.shutdown.?();

    i = 0;
    while (i < g_rvn.action_count) : (i += 1) base.rvn_free(g_rvn.actions[i].name);
    base.rvn_free(g_rvn.actions);
    base.rvn_free(g_rvn.tasks);
    base.rvn_free(@ptrCast(g_rvn.dead_widgets));
    base.rvn_free(@ptrCast(g_rvn.dead_windows));
    base.rvn_free(g_rvn.clipboard);
    base.rvn_free(g_rvn.xml_base_path);
    thread.rvn_mutex_destroy(&g_rvn.task_mutex);
    handle.rvn_pool_free(&g_rvn.windows);
    handle.rvn_pool_free(&g_rvn.widgets);
    handle.rvn_pool_free(&g_rvn.fonts);
    handle.rvn_pool_free(&g_rvn.textures);
    handle.rvn_pool_free(&g_rvn.shaders);
    handle.rvn_pool_free(&g_rvn.timers);
    handle.rvn_pool_free(&g_rvn.tree_items);
    handle.rvn_pool_free(&g_rvn.xml_documents);
    handle.rvn_pool_free(&g_rvn.xml_nodes);
    g_rvn = std.mem.zeroes(ctx.rvn_context_t);
    // nothing is allocated any more: the regions of the heap return to the OS
    heap.rvn_heap_trim();
}

export fn Ris_initialized() c_int {
    return g_rvn.initialized;
}

export fn Rget_version() [*c]const u8 {
    return base.RVN_VERSION_STRING;
}

// ---- Tasks ----

export fn Rtask_post(task: raven.RTaskCallback, user_data: ?*anyopaque) void {
    if (task == null) return;
    if (g_rvn.initialized == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rtask_post: Raven is not initialized");
        return;
    }
    thread.rvn_mutex_lock(&g_rvn.task_mutex);
    base.RVN_ARRAY_RESERVE(&g_rvn.tasks, &g_rvn.task_cap, g_rvn.task_count + 1);
    g_rvn.tasks[g_rvn.task_count].function = task;
    g_rvn.tasks[g_rvn.task_count].user_data = user_data;
    g_rvn.task_count += 1;
    thread.rvn_mutex_unlock(&g_rvn.task_mutex);
    rvn_wake();
}

export fn rvn_tasks_run() void {
    var tasks: [*c]ctx.rvn_task_t = undefined;
    var count: u32 = undefined;
    var i: u32 = undefined;

    // take the whole batch: tasks posted while running wait for the next update
    thread.rvn_mutex_lock(&g_rvn.task_mutex);
    count = g_rvn.task_count;
    tasks = null;
    if (count != 0) {
        tasks = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(ctx.rvn_task_t) * count)));
        @memcpy(tasks[0..count], g_rvn.tasks[0..count]);
        g_rvn.task_count = 0;
    }
    thread.rvn_mutex_unlock(&g_rvn.task_mutex);

    if (count == 0) return;
    rvn_dispatch_begin();
    i = 0;
    while (i < count) : (i += 1) tasks[i].function.?(tasks[i].user_data);
    rvn_dispatch_end();
    base.rvn_free(tasks);
}

fn rvn_tasks_pending() c_int {
    var pending: c_int = undefined;
    thread.rvn_mutex_lock(&g_rvn.task_mutex);
    pending = @intFromBool(g_rvn.task_count > 0);
    thread.rvn_mutex_unlock(&g_rvn.task_mutex);
    return pending;
}

export fn Rtask_run_async(task: raven.RTaskCallback, user_data: ?*anyopaque) void {
    if (task == null) return;
    if (g_rvn.initialized == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_OPERATION, raven.R_SEVERITY_ERROR, "Rtask_run_async: Raven is not initialized");
        return;
    }
    jobs.rvn_jobs_submit(null, task, user_data);
}

export fn Rparallel_for(count: raven.Ruint, grain: raven.Ruint, function: raven.RParallelRangeCallback, user_data: ?*anyopaque) void {
    if (function == null) return;
    if (g_rvn.initialized == 0) {
        function.?(0, count, user_data);
        return;
    }
    jobs.rvn_jobs_parallel_for(count, grain, function, user_data);
}

export fn Rwake_up() void {
    rvn_wake();
}

export fn Rget_worker_thread_count() c_int {
    return if (g_rvn.initialized != 0) jobs.rvn_jobs_worker_count() else 0;
}

export fn Ris_ui_thread() c_int {
    return @intFromBool(g_rvn.initialized != 0 and thread.rvn_thread_id() == g_rvn.ui_thread);
}

// ---- Timers ----

export fn Rtimer_create(interval_seconds: f64, repeat: c_int, callback: raven.RTimerCallback, user_data: ?*anyopaque) raven.Rid {
    var timer: [*c]ctx.rvn_timer_t = undefined;
    if (rvn_api_check("Rtimer_create") == 0) return raven.R_INVALID_ID;
    if (callback == null or interval_seconds < 0.0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Rtimer_create: invalid arguments");
        return raven.R_INVALID_ID;
    }
    timer = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(ctx.rvn_timer_t))));
    // a repeating timer of zero seconds would spin the loop
    timer.*.interval = if (repeat != 0 and interval_seconds < 0.001) 0.001 else interval_seconds;
    timer.*.deadline = thread.rvn_clock_seconds() + timer.*.interval;
    timer.*.repeat = @intFromBool(repeat != 0);
    timer.*.callback = callback;
    timer.*.user_data = user_data;
    timer.*.id = handle.rvn_pool_add(&g_rvn.timers, timer);
    if (timer.*.id == raven.R_INVALID_ID) {
        base.rvn_free(timer);
        return raven.R_INVALID_ID;
    }
    return timer.*.id;
}

export fn Rtimer_destroy(id: raven.Rid) void {
    var timer: [*c]ctx.rvn_timer_t = undefined;
    if (rvn_api_check("Rtimer_destroy") == 0) return;
    timer = @ptrCast(@alignCast(handle.rvn_pool_get(&g_rvn.timers, id)));
    if (timer == null) {
        base.rvn_error(raven.R_ERROR_INVALID_ID, raven.R_SEVERITY_ERROR, "Rtimer_destroy: invalid timer");
        return;
    }
    handle.rvn_pool_remove(&g_rvn.timers, id);
    base.rvn_free(timer);
}

export fn Rtimer_is_valid(timer: raven.Rid) c_int {
    return @intFromBool(g_rvn.initialized != 0 and handle.rvn_pool_get(&g_rvn.timers, timer) != null);
}

export fn rvn_timers_next_delay() f64 {
    const now = thread.rvn_clock_seconds();
    var best: f64 = -1.0;
    var i: u32 = 0;
    while (i < g_rvn.timers.used) : (i += 1) {
        const timer: [*c]ctx.rvn_timer_t = @ptrCast(@alignCast(handle.rvn_pool_at(&g_rvn.timers, i)));
        var delay: f64 = undefined;
        if (timer == null) continue;
        delay = timer.*.deadline - now;
        if (delay < 0.0) delay = 0.0;
        if (best < 0.0 or delay < best) best = delay;
    }
    return best;
}

fn rvn_timers_run() void {
    const now = thread.rvn_clock_seconds();
    const used = g_rvn.timers.used;
    var i: u32 = 0;

    rvn_dispatch_begin();
    while (i < used) : (i += 1) {
        const timer: [*c]ctx.rvn_timer_t = @ptrCast(@alignCast(handle.rvn_pool_at(&g_rvn.timers, i)));
        if (timer == null or timer.*.deadline > now) continue;
        const id = timer.*.id;
        const callback = timer.*.callback;
        const user_data = timer.*.user_data;
        if (timer.*.repeat != 0) {
            timer.*.deadline += timer.*.interval;
            // do not try to catch up after a long stall
            if (timer.*.deadline < now) timer.*.deadline = now + timer.*.interval;
        } else {
            handle.rvn_pool_remove(&g_rvn.timers, id);
            base.rvn_free(timer);
        }
        callback.?(id, user_data);
    }
    rvn_dispatch_end();
}

// ---- Actions ----

fn rvn_action_find(name: [*c]const u8) [*c]ctx.rvn_action_t {
    var i: u32 = 0;
    while (i < g_rvn.action_count) : (i += 1) {
        if (libc.strcmp(g_rvn.actions[i].name, name) == 0) return &g_rvn.actions[i];
    }
    return null;
}

export fn Raction_bind(name: [*c]const u8, callback: raven.RActionCallback, user_data: ?*anyopaque) void {
    if (rvn_api_check("Raction_bind") == 0) return;
    if (name == null or name[0] == 0) {
        base.rvn_error(raven.R_ERROR_INVALID_VALUE, raven.R_SEVERITY_ERROR, "Raction_bind: empty action name");
        return;
    }
    if (callback == null) {
        Raction_unbind(name);
        return;
    }
    var action = rvn_action_find(name);
    if (action == null) {
        base.RVN_ARRAY_RESERVE(&g_rvn.actions, &g_rvn.action_cap, g_rvn.action_count + 1);
        action = &g_rvn.actions[g_rvn.action_count];
        g_rvn.action_count += 1;
        action.*.name = base.rvn_strdup(name);
    }
    action.*.callback = callback;
    action.*.user_data = user_data;
}

export fn Raction_unbind(name: [*c]const u8) void {
    if (rvn_api_check("Raction_unbind") == 0) return;
    if (name == null) return;
    const action = rvn_action_find(name);
    if (action == null) return;
    base.rvn_free(action.*.name);
    g_rvn.action_count -= 1;
    action.* = g_rvn.actions[g_rvn.action_count];
}

export fn Raction_fire(name: [*c]const u8, sender: raven.Rid) void {
    if (rvn_api_check("Raction_fire") == 0) return;
    if (name == null or name[0] == 0) return;
    // (the function may unbind the action, or free what the name was read from)
    const copy = base.rvn_strdup(name);
    rvn_fire_action(sender, copy);
    base.rvn_free(copy);
}

export fn Raction_set_default_handler(callback: raven.RActionCallback, user_data: ?*anyopaque) void {
    if (rvn_api_check("Raction_set_default_handler") == 0) return;
    g_rvn.default_action = callback;
    g_rvn.default_action_user = user_data;
}

export fn rvn_fire_action(sender: raven.Rid, name: [*c]const u8) void {
    if (name == null or name[0] == 0) return;
    const action = rvn_action_find(name);
    if (action != null) {
        // copy: the callback may bind or unbind actions
        const callback = action.*.callback;
        const user_data = action.*.user_data;
        callback.?(sender, name, user_data);
    } else if (g_rvn.default_action != null) {
        g_rvn.default_action.?(sender, name, g_rvn.default_action_user);
    }
}

// ---- Clipboard ----

export fn Rclipboard_set_text(text: [*c]const u8) void {
    if (rvn_api_check("Rclipboard_set_text") == 0) return;
    platformOf().*.clipboard_set.?(if (text != null) text else "");
}

export fn Rclipboard_get_text() [*c]const u8 {
    if (rvn_api_check("Rclipboard_get_text") == 0) return "";
    base.rvn_free(g_rvn.clipboard);
    g_rvn.clipboard = platformOf().*.clipboard_get.?();
    return if (g_rvn.clipboard != null) g_rvn.clipboard else "";
}

// ---- Main loop ----

export fn Rquit(exit_code: c_int) void {
    if (g_rvn.initialized == 0) return;
    thread.rvn_atomic_store(&g_rvn.exit_code, exit_code);
    thread.rvn_atomic_store(&g_rvn.quit_requested, 1);
    rvn_wake();
}

export fn Ris_running() c_int {
    var i: u32 = 0;
    if (g_rvn.initialized == 0 or thread.rvn_atomic_load(&g_rvn.quit_requested) != 0) return raven.R_FALSE;
    if (g_rvn.had_window == 0) return raven.R_TRUE;
    while (i < g_rvn.windows.used) : (i += 1) {
        const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(handle.rvn_pool_at(&g_rvn.windows, i)));
        if (window != null and window.*.dead == 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

export fn Rset_frame_callback(callback: raven.RFrameCallback, user_data: ?*anyopaque) void {
    if (rvn_api_check("Rset_frame_callback") == 0) return;
    g_rvn.frame_callback = callback;
    g_rvn.frame_user = user_data;
}

export fn Rget_time() f64 {
    return if (g_rvn.initialized != 0) thread.rvn_clock_seconds() - g_rvn.start_time else 0.0;
}

export fn Rpoll_events() void {
    if (rvn_api_check("Rpoll_events") == 0) return;
    platformOf().*.pump.?(0.0);
}

export fn Rwait_events(timeout_seconds: f64) void {
    var timeout_seconds_ = timeout_seconds;
    var i: u32 = 0;
    if (rvn_api_check("Rwait_events") == 0) return;

    // do not sleep when there is already something to do
    if (rvn_tasks_pending() != 0 or thread.rvn_atomic_load(&g_rvn.redraw_all) != 0 or thread.rvn_atomic_load(&g_rvn.quit_requested) != 0) {
        timeout_seconds_ = 0.0;
    }
    while (i < g_rvn.windows.used and timeout_seconds_ != 0.0) : (i += 1) {
        const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(handle.rvn_pool_at(&g_rvn.windows, i)));
        if (window != null and ext.rvn_window_wants_frame(window) != 0) timeout_seconds_ = 0.0;
    }
    const timer_delay = rvn_timers_next_delay();
    if (timer_delay >= 0.0 and (timeout_seconds_ < 0.0 or timer_delay < timeout_seconds_)) timeout_seconds_ = timer_delay;
    platformOf().*.pump.?(timeout_seconds_);
}

export fn rvn_update() void {
    var i: u32 = 0;
    // a platform modal loop may call back while an update is already running
    if (g_rvn.in_update != 0) return;
    g_rvn.in_update = raven.R_TRUE;

    rvn_tasks_run();
    rvn_timers_run();

    const now = thread.rvn_clock_seconds();
    g_rvn.delta_time = now - g_rvn.last_update_time;
    if (g_rvn.frame_callback != null) {
        rvn_dispatch_begin();
        g_rvn.frame_callback.?(g_rvn.delta_time, g_rvn.frame_user);
        rvn_dispatch_end();
    }
    g_rvn.last_update_time = now;

    if (thread.rvn_atomic_exchange(&g_rvn.redraw_all, 0) != 0) ctx.rvn_repaint_all_windows();
    while (i < g_rvn.windows.used) : (i += 1) {
        const window: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(handle.rvn_pool_at(&g_rvn.windows, i)));
        if (window != null) ext.rvn_window_update(window);
    }
    g_rvn.in_update = raven.R_FALSE;
}

export fn Rdraw_frame() c_int {
    if (rvn_api_check("Rdraw_frame") == 0) return raven.R_FALSE;
    ext.rvn_windows_throttle();
    platformOf().*.pump.?(0.0);
    rvn_update();
    return Ris_running();
}

export fn Rwait_frame(timeout_seconds: f64) c_int {
    if (rvn_api_check("Rwait_frame") == 0) return raven.R_FALSE;
    Rwait_events(timeout_seconds);
    // a frame is coming: wait for the renderer first, then read the input that came meanwhile
    ext.rvn_windows_throttle();
    platformOf().*.pump.?(0.0);
    rvn_update();
    return Ris_running();
}

export fn Rget_exit_code() c_int {
    return if (g_rvn.initialized != 0) thread.rvn_atomic_load(&g_rvn.exit_code) else 0;
}

export fn Rget_delta_time() f64 {
    return if (g_rvn.initialized != 0) g_rvn.delta_time else 0.0;
}
