// Translated to Zig from vendor/raven/src/core/jobs.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/jobs.c
// Worker pool with a mutex-protected ring queue.

const std = @import("std");
const raven = @import("raven");
const base = @import("base_h.zig");
const thread = @import("thread_h.zig");
const jobs = @import("jobs_h.zig");
const libc = @import("../sys/libc.zig");

const RVN_JOBS_MAX_WORKERS = 64;

const rvn_job_t = extern struct {
    function: jobs.rvn_job_fn,
    arg: ?*anyopaque,
    group: [*c]jobs.rvn_job_group_t,
};

const rvn_jobs_state_t = extern struct {
    mutex: thread.rvn_mutex_t,
    /// Signalled when a job is queued (workers sleep on it).
    work_cv: thread.rvn_cond_t,
    /// Broadcast when a group completes or a job is queued (waiters sleep on it).
    done_cv: thread.rvn_cond_t,
    queue: [*c]rvn_job_t,
    queue_cap: u32,
    queue_head: u32,
    queue_count: u32,
    waiters: u32,
    workers: [RVN_JOBS_MAX_WORKERS]thread.rvn_thread_t,
    worker_count: c_int,
    stop: c_int,
    initialized: c_int,
};

var g_jobs: rvn_jobs_state_t = std.mem.zeroes(rvn_jobs_state_t);

// Caller holds the mutex.
fn rvn_jobs_pop(job: [*c]rvn_job_t) c_int {
    if (g_jobs.queue_count == 0) return raven.R_FALSE;
    job.* = g_jobs.queue[g_jobs.queue_head];
    g_jobs.queue_head = (g_jobs.queue_head +% 1) % g_jobs.queue_cap;
    g_jobs.queue_count -= 1;
    return raven.R_TRUE;
}

// Caller does not hold the mutex.
fn rvn_jobs_execute(job: [*c]const rvn_job_t) void {
    job.*.function.?(job.*.arg);
    if (job.*.group != null and thread.rvn_atomic_add(&job.*.group.*.pending, -1) == 0) {
        // Taking the mutex orders this broadcast after the waiter's check of
        // `pending`, so the wake-up cannot be lost.
        thread.rvn_mutex_lock(&g_jobs.mutex);
        thread.rvn_cond_broadcast(&g_jobs.done_cv);
        thread.rvn_mutex_unlock(&g_jobs.mutex);
    }
}

fn rvn_jobs_worker(arg: ?*anyopaque) callconv(.c) void {
    _ = arg;
    thread.rvn_mutex_lock(&g_jobs.mutex);
    while (true) {
        var job: rvn_job_t = undefined;
        if (rvn_jobs_pop(&job) != 0) {
            thread.rvn_mutex_unlock(&g_jobs.mutex);
            rvn_jobs_execute(&job);
            thread.rvn_mutex_lock(&g_jobs.mutex);
            continue;
        }
        if (g_jobs.stop != 0) break;
        thread.rvn_cond_wait(&g_jobs.work_cv, &g_jobs.mutex);
    }
    thread.rvn_mutex_unlock(&g_jobs.mutex);
}

export fn rvn_jobs_init(worker_count: c_int) void {
    @memset(std.mem.asBytes(&g_jobs), 0);
    thread.rvn_mutex_init(&g_jobs.mutex);
    thread.rvn_cond_init(&g_jobs.work_cv);
    thread.rvn_cond_init(&g_jobs.done_cv);
    g_jobs.queue_cap = 256;
    g_jobs.queue = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(rvn_job_t) * g_jobs.queue_cap)));
    g_jobs.initialized = raven.R_TRUE;
    const worker_count_ = base.rvn_clampi(worker_count, 0, RVN_JOBS_MAX_WORKERS);
    var i: c_int = 0;
    while (i < worker_count_) : (i += 1) {
        var name: [32]u8 = undefined;
        _ = libc.snprintf(&name, name.len, "raven-job-%d", i);
        if (thread.rvn_thread_create(&g_jobs.workers[@intCast(g_jobs.worker_count)], rvn_jobs_worker, null, &name) == 0) break;
        g_jobs.worker_count += 1;
    }
}

export fn rvn_jobs_shutdown() void {
    var i: c_int = 0;
    var job: rvn_job_t = undefined;
    if (g_jobs.initialized == 0) return;
    thread.rvn_mutex_lock(&g_jobs.mutex);
    g_jobs.stop = raven.R_TRUE;
    thread.rvn_cond_broadcast(&g_jobs.work_cv);
    thread.rvn_mutex_unlock(&g_jobs.mutex);
    while (i < g_jobs.worker_count) : (i += 1) thread.rvn_thread_join(&g_jobs.workers[@intCast(i)]);
    // workers drain the queue before leaving; with zero workers, run what is left
    thread.rvn_mutex_lock(&g_jobs.mutex);
    while (rvn_jobs_pop(&job) != 0) {
        thread.rvn_mutex_unlock(&g_jobs.mutex);
        rvn_jobs_execute(&job);
        thread.rvn_mutex_lock(&g_jobs.mutex);
    }
    thread.rvn_mutex_unlock(&g_jobs.mutex);
    base.rvn_free(g_jobs.queue);
    thread.rvn_cond_destroy(&g_jobs.done_cv);
    thread.rvn_cond_destroy(&g_jobs.work_cv);
    thread.rvn_mutex_destroy(&g_jobs.mutex);
    @memset(std.mem.asBytes(&g_jobs), 0);
}

export fn rvn_jobs_worker_count() c_int {
    return g_jobs.worker_count;
}

export fn rvn_jobs_submit(group: [*c]jobs.rvn_job_group_t, function: jobs.rvn_job_fn, arg: ?*anyopaque) void {
    const job: rvn_job_t = .{ .function = function, .arg = arg, .group = group };
    if (group != null) _ = thread.rvn_atomic_add(&group.*.pending, 1);

    if (g_jobs.initialized == 0 or (g_jobs.worker_count == 0 and group == null)) {
        // nobody will ever pick up an unowned job: run it now
        rvn_jobs_execute(&job);
        return;
    }

    thread.rvn_mutex_lock(&g_jobs.mutex);
    if (g_jobs.queue_count == g_jobs.queue_cap) {
        // grow the ring, unwrapping it to the start of the new storage
        const new_cap: u32 = g_jobs.queue_cap *% 2;
        const queue: [*c]rvn_job_t = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(rvn_job_t) * new_cap)));
        var i: u32 = 0;
        while (i < g_jobs.queue_count) : (i += 1) {
            queue[i] = g_jobs.queue[(g_jobs.queue_head +% i) % g_jobs.queue_cap];
        }
        base.rvn_free(g_jobs.queue);
        g_jobs.queue = queue;
        g_jobs.queue_cap = new_cap;
        g_jobs.queue_head = 0;
    }
    g_jobs.queue[(g_jobs.queue_head +% g_jobs.queue_count) % g_jobs.queue_cap] = job;
    g_jobs.queue_count += 1;
    thread.rvn_cond_signal(&g_jobs.work_cv);
    if (g_jobs.waiters != 0) thread.rvn_cond_broadcast(&g_jobs.done_cv);
    thread.rvn_mutex_unlock(&g_jobs.mutex);
}

export fn rvn_jobs_wait(group: [*c]jobs.rvn_job_group_t) void {
    if (g_jobs.initialized == 0) return;
    thread.rvn_mutex_lock(&g_jobs.mutex);
    while (thread.rvn_atomic_load(&group.*.pending) > 0) {
        var job: rvn_job_t = undefined;
        if (rvn_jobs_pop(&job) != 0) {
            thread.rvn_mutex_unlock(&g_jobs.mutex);
            rvn_jobs_execute(&job);
            thread.rvn_mutex_lock(&g_jobs.mutex);
        } else {
            g_jobs.waiters += 1;
            thread.rvn_cond_wait(&g_jobs.done_cv, &g_jobs.mutex);
            g_jobs.waiters -= 1;
        }
    }
    thread.rvn_mutex_unlock(&g_jobs.mutex);
}

// ---------------------------------------------------------------------------
//  parallel_for
// ---------------------------------------------------------------------------

const rvn_parallel_t = extern struct {
    next: thread.rvn_atomic_t,
    count: u32,
    grain: u32,
    function: jobs.rvn_job_range_fn,
    context: ?*anyopaque,
};

fn rvn_parallel_run(arg: ?*anyopaque) callconv(.c) void {
    const parallel: [*c]rvn_parallel_t = @ptrCast(@alignCast(arg));
    while (true) {
        var end: u32 = @bitCast(thread.rvn_atomic_add(&parallel.*.next, @bitCast(parallel.*.grain)));
        const begin = end -% parallel.*.grain;
        if (begin >= parallel.*.count) break;
        if (end > parallel.*.count) end = parallel.*.count;
        parallel.*.function.?(begin, end, parallel.*.context);
    }
}

export fn rvn_jobs_parallel_for(count: u32, grain: u32, function: jobs.rvn_job_range_fn, context: ?*anyopaque) void {
    var grain_ = grain;
    if (count == 0) return;
    if (grain_ == 0) grain_ = 1;
    if (grain_ > count) grain_ = count;
    const chunks: u32 = (count +% grain_ -% 1) / grain_;
    const helpers: u32 = base.rvn_minu(chunks - 1, @bitCast(g_jobs.worker_count));
    if (helpers == 0 or count > 0x3FFFFFFF) {
        function.?(0, count, context);
        return;
    }

    var parallel = std.mem.zeroes(rvn_parallel_t);
    var group = std.mem.zeroes(jobs.rvn_job_group_t);
    parallel.count = count;
    parallel.grain = grain_;
    parallel.function = function;
    parallel.context = context;
    var i: u32 = 0;
    while (i < helpers) : (i += 1) rvn_jobs_submit(&group, rvn_parallel_run, &parallel);
    rvn_parallel_run(&parallel);
    rvn_jobs_wait(&group);
}
