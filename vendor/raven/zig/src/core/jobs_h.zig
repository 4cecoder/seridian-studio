// Translated to Zig from vendor/raven/src/core/jobs.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/jobs.h
// Job system: a fixed pool of worker threads fed by one shared queue.
//
// A thread waiting for a group of jobs executes queued jobs itself instead of
// sleeping, so jobs may submit and wait for other jobs without deadlock and
// the pool also works with zero workers (everything then runs in the waiter).

const thread = @import("thread_h.zig");

pub const rvn_job_fn = ?*const fn (arg: ?*anyopaque) callconv(.c) void;
pub const rvn_job_range_fn = ?*const fn (begin: u32, end: u32, context: ?*anyopaque) callconv(.c) void;

/// Counts the unfinished jobs submitted with it. Zero-initialize before use.
pub const rvn_job_group_t = extern struct {
    pending: thread.rvn_atomic_t,
};
pub const struct_rvn_job_group_t = rvn_job_group_t;

/// @param worker_count Number of threads to start; 0 runs every job in the caller.
pub extern fn rvn_jobs_init(worker_count: c_int) void;
pub extern fn rvn_jobs_shutdown() void;
pub extern fn rvn_jobs_worker_count() c_int;

/// Queues a job. `group` may be NULL for fire-and-forget jobs. Thread-safe.
pub extern fn rvn_jobs_submit(group: [*c]rvn_job_group_t, function: rvn_job_fn, arg: ?*anyopaque) void;

/// Returns when every job of the group is finished. Runs queued jobs meanwhile.
pub extern fn rvn_jobs_wait(group: [*c]rvn_job_group_t) void;

/// Calls `function` for consecutive sub-ranges of [0, count), each holding at
/// most `grain` items, on the workers and on the calling thread.
pub extern fn rvn_jobs_parallel_for(count: u32, grain: u32, function: rvn_job_range_fn, context: ?*anyopaque) void;
