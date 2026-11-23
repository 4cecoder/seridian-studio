// Translated to Zig from vendor/raven/src/core/thread.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/thread.h
// Portable threads, locks, condition variables, atomics and clock.
// Implemented by thread_posix.c and thread_win32.c.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");

// SRWLOCK and CONDITION_VARIABLE are both a single pointer: on Windows they stay opaque.
// Elsewhere the handle is the pthread type of the OS (std.c has the layout of every OS).
const is_windows = builtin.os.tag == .windows;
pub const rvn_mutex_t = extern struct { handle: if (is_windows) ?*anyopaque else std.c.pthread_mutex_t };
pub const struct_rvn_mutex_t = rvn_mutex_t;
pub const rvn_rwlock_t = extern struct { handle: if (is_windows) ?*anyopaque else std.c.pthread_rwlock_t };
pub const struct_rvn_rwlock_t = rvn_rwlock_t;
pub const rvn_cond_t = extern struct { handle: if (is_windows) ?*anyopaque else std.c.pthread_cond_t };
pub const struct_rvn_cond_t = rvn_cond_t;
pub const rvn_thread_t = extern struct { handle: if (is_windows) ?*anyopaque else std.c.pthread_t };
pub const struct_rvn_thread_t = rvn_thread_t;

pub const rvn_thread_fn = ?*const fn (arg: ?*anyopaque) callconv(.c) void;

pub extern fn rvn_thread_create(thread: [*c]rvn_thread_t, function: rvn_thread_fn, arg: ?*anyopaque, name: [*c]const u8) c_int;
pub extern fn rvn_thread_join(thread: [*c]rvn_thread_t) void;
/// Identifier of the calling thread, never 0.
pub extern fn rvn_thread_id() u64;
pub extern fn rvn_cpu_count() c_int;
pub extern fn rvn_sleep_ms(milliseconds: c_int) void;
/// Monotonic clock, in seconds.
pub extern fn rvn_clock_seconds() f64;

pub extern fn rvn_mutex_init(mutex: [*c]rvn_mutex_t) void;
pub extern fn rvn_mutex_destroy(mutex: [*c]rvn_mutex_t) void;
pub extern fn rvn_mutex_lock(mutex: [*c]rvn_mutex_t) void;
pub extern fn rvn_mutex_unlock(mutex: [*c]rvn_mutex_t) void;

pub extern fn rvn_rwlock_init(lock: [*c]rvn_rwlock_t) void;
pub extern fn rvn_rwlock_destroy(lock: [*c]rvn_rwlock_t) void;
pub extern fn rvn_rwlock_read_lock(lock: [*c]rvn_rwlock_t) void;
pub extern fn rvn_rwlock_read_unlock(lock: [*c]rvn_rwlock_t) void;
pub extern fn rvn_rwlock_write_lock(lock: [*c]rvn_rwlock_t) void;
pub extern fn rvn_rwlock_write_unlock(lock: [*c]rvn_rwlock_t) void;

pub extern fn rvn_cond_init(cond: [*c]rvn_cond_t) void;
pub extern fn rvn_cond_destroy(cond: [*c]rvn_cond_t) void;
pub extern fn rvn_cond_wait(cond: [*c]rvn_cond_t, mutex: [*c]rvn_mutex_t) void;
/// Returns R_FALSE when the wait timed out.
pub extern fn rvn_cond_wait_timeout(cond: [*c]rvn_cond_t, mutex: [*c]rvn_mutex_t, seconds: f64) c_int;
pub extern fn rvn_cond_signal(cond: [*c]rvn_cond_t) void;
pub extern fn rvn_cond_broadcast(cond: [*c]rvn_cond_t) void;

// ---------------------------------------------------------------------------
//  Atomic 32-bit integer (the stdatomic branch of the C header; sequentially consistent)
// ---------------------------------------------------------------------------

pub const rvn_atomic_t = extern struct { value: c_int };
pub const struct_rvn_atomic_t = rvn_atomic_t;
pub inline fn rvn_atomic_load(a: [*c]rvn_atomic_t) c_int {
    return @atomicLoad(c_int, &a.*.value, .seq_cst);
}
pub inline fn rvn_atomic_store(a: [*c]rvn_atomic_t, v: c_int) void {
    @atomicStore(c_int, &a.*.value, v, .seq_cst);
}
/// Adds and returns the new value.
pub inline fn rvn_atomic_add(a: [*c]rvn_atomic_t, v: c_int) c_int {
    return @atomicRmw(c_int, &a.*.value, .Add, v, .seq_cst) + v;
}
pub inline fn rvn_atomic_exchange(a: [*c]rvn_atomic_t, v: c_int) c_int {
    return @atomicRmw(c_int, &a.*.value, .Xchg, v, .seq_cst);
}
/// Atomic pointer.
pub const rvn_atomic_ptr_t = extern struct { value: ?*anyopaque };
pub const struct_rvn_atomic_ptr_t = rvn_atomic_ptr_t;
pub inline fn rvn_atomic_ptr_load(a: [*c]rvn_atomic_ptr_t) ?*anyopaque {
    return @atomicLoad(?*anyopaque, &a.*.value, .seq_cst);
}
pub inline fn rvn_atomic_ptr_store(a: [*c]rvn_atomic_ptr_t, v: ?*anyopaque) void {
    @atomicStore(?*anyopaque, &a.*.value, v, .seq_cst);
}
