// Translated to Zig from vendor/raven/src/core/thread_posix.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/thread_posix.c
// pthread implementation of core/thread.h (Linux, BSD, macOS).

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base_h = @import("base_h.zig");
const thread_h = @import("thread_h.zig");
const libc = @import("../sys/libc.zig");

// #define RVN_COND_CLOCK: macOS has no pthread_condattr_setclock, timed waits use the realtime clock there.
const RVN_COND_CLOCK = if (builtin.os.tag.isDarwin()) std.c.CLOCK.REALTIME else std.c.CLOCK.MONOTONIC;

// pthread_condattr_t and its functions are not declared by std.c: glibc's pthread_condattr_t is a union of 4 bytes.
// Only used by the non-Apple branch of rvn_cond_init (comptime-pruned on macOS).
const pthread_condattr_t = extern union {
    __size: [4]u8,
    __align: c_int,
};
extern "c" fn pthread_condattr_init(attr: *pthread_condattr_t) c_int;
extern "c" fn pthread_condattr_setclock(attr: *pthread_condattr_t, clock_id: std.c.clockid_t) c_int;
extern "c" fn pthread_condattr_destroy(attr: *pthread_condattr_t) c_int;

const rvn_thread_start_t = extern struct {
    function: thread_h.rvn_thread_fn,
    arg: ?*anyopaque,
    name: [16]u8,
};

fn rvn_thread_entry(param: ?*anyopaque) callconv(.c) ?*anyopaque {
    const start: rvn_thread_start_t = @as([*c]rvn_thread_start_t, @ptrCast(@alignCast(param))).*;
    base_h.rvn_free(param);
    if (comptime builtin.os.tag == .linux) {
        if (start.name[0] != 0) _ = std.c.pthread_setname_np(std.c.pthread_self(), @ptrCast(&start.name));
    } else if (comptime builtin.os.tag.isDarwin()) {
        if (start.name[0] != 0) _ = std.c.pthread_setname_np(@ptrCast(&start.name));
    }
    start.function.?(start.arg);
    return null;
}

export fn rvn_thread_create(thread: [*c]thread_h.rvn_thread_t, function: thread_h.rvn_thread_fn, arg: ?*anyopaque, name: [*c]const u8) c_int {
    const start: [*c]rvn_thread_start_t = @ptrCast(@alignCast(base_h.rvn_calloc(@sizeOf(rvn_thread_start_t))));
    start.*.function = function;
    start.*.arg = arg;
    if (name != null) {
        _ = libc.strncpy(&start.*.name, name, start.*.name.len - 1);
    }
    if (libc.pthread_create(&thread.*.handle, null, &rvn_thread_entry, start) != 0) {
        base_h.rvn_free(start);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

export fn rvn_thread_join(thread: [*c]thread_h.rvn_thread_t) void {
    _ = libc.pthread_join(thread.*.handle, null);
}

export fn rvn_thread_id() u64 {
    // the address of a thread-local object is unique per live thread
    const S = struct {
        threadlocal var marker: u8 = 0; // static _Thread_local char marker;
    };
    return @as(u64, @intFromPtr(&S.marker));
}

// _SC_NPROCESSORS_ONLN: the sysconf name of each OS (std.c._SC has it only for some systems).
const SC_NPROCESSORS_ONLN: c_int = if (builtin.os.tag == .linux) 84 else if (builtin.os.tag.isDarwin()) 58 else @compileError("_SC_NPROCESSORS_ONLN: value not known for this OS");

export fn rvn_cpu_count() c_int {
    const count: c_long = libc.sysconf(SC_NPROCESSORS_ONLN);
    return if (count > 0) @as(c_int, @truncate(count)) else 1;
}

export fn rvn_sleep_ms(milliseconds: c_int) void {
    var ts: std.c.timespec = undefined;
    if (milliseconds <= 0) return;
    ts.sec = @divTrunc(milliseconds, 1000);
    ts.nsec = @as(c_long, @rem(milliseconds, 1000)) * 1000000;
    while (libc.nanosleep(&ts, &ts) == -1 and std.c._errno().* == @intFromEnum(std.c.E.INTR)) {}
}

export fn rvn_clock_seconds() f64 {
    var ts: std.c.timespec = undefined;
    _ = libc.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) + @as(f64, @floatFromInt(ts.nsec)) * 1e-9;
}

export fn rvn_mutex_init(mutex: [*c]thread_h.rvn_mutex_t) void {
    _ = libc.pthread_mutex_init(&mutex.*.handle, null);
}
export fn rvn_mutex_destroy(mutex: [*c]thread_h.rvn_mutex_t) void {
    _ = libc.pthread_mutex_destroy(&mutex.*.handle);
}
export fn rvn_mutex_lock(mutex: [*c]thread_h.rvn_mutex_t) void {
    _ = libc.pthread_mutex_lock(&mutex.*.handle);
}
export fn rvn_mutex_unlock(mutex: [*c]thread_h.rvn_mutex_t) void {
    _ = libc.pthread_mutex_unlock(&mutex.*.handle);
}

export fn rvn_rwlock_init(lock: [*c]thread_h.rvn_rwlock_t) void {
    _ = libc.pthread_rwlock_init(&lock.*.handle, null);
}
export fn rvn_rwlock_destroy(lock: [*c]thread_h.rvn_rwlock_t) void {
    _ = libc.pthread_rwlock_destroy(&lock.*.handle);
}
export fn rvn_rwlock_read_lock(lock: [*c]thread_h.rvn_rwlock_t) void {
    _ = libc.pthread_rwlock_rdlock(&lock.*.handle);
}
export fn rvn_rwlock_read_unlock(lock: [*c]thread_h.rvn_rwlock_t) void {
    _ = libc.pthread_rwlock_unlock(&lock.*.handle);
}
export fn rvn_rwlock_write_lock(lock: [*c]thread_h.rvn_rwlock_t) void {
    _ = libc.pthread_rwlock_wrlock(&lock.*.handle);
}
export fn rvn_rwlock_write_unlock(lock: [*c]thread_h.rvn_rwlock_t) void {
    _ = libc.pthread_rwlock_unlock(&lock.*.handle);
}

export fn rvn_cond_init(cond: [*c]thread_h.rvn_cond_t) void {
    if (comptime builtin.os.tag.isDarwin()) {
        _ = libc.pthread_cond_init(&cond.*.handle, null);
    } else {
        var attr: pthread_condattr_t = undefined;
        _ = pthread_condattr_init(&attr);
        _ = pthread_condattr_setclock(&attr, std.c.CLOCK.MONOTONIC);
        _ = libc.pthread_cond_init(&cond.*.handle, &attr);
        _ = pthread_condattr_destroy(&attr);
    }
}

export fn rvn_cond_destroy(cond: [*c]thread_h.rvn_cond_t) void {
    _ = libc.pthread_cond_destroy(&cond.*.handle);
}
export fn rvn_cond_wait(cond: [*c]thread_h.rvn_cond_t, mutex: [*c]thread_h.rvn_mutex_t) void {
    _ = libc.pthread_cond_wait(&cond.*.handle, &mutex.*.handle);
}

export fn rvn_cond_wait_timeout(cond: [*c]thread_h.rvn_cond_t, mutex: [*c]thread_h.rvn_mutex_t, seconds_: f64) c_int {
    var ts: std.c.timespec = undefined;
    var seconds = seconds_;
    if (seconds < 0.0) seconds = 0.0;
    _ = libc.clock_gettime(RVN_COND_CLOCK, &ts);
    const whole = @floor(seconds);
    ts.sec += @intFromFloat(whole);
    ts.nsec += @intFromFloat((seconds - whole) * 1e9);
    if (ts.nsec >= 1000000000) {
        ts.sec += 1;
        ts.nsec -= 1000000000;
    }
    return @intFromBool(libc.pthread_cond_timedwait(&cond.*.handle, &mutex.*.handle, &ts) != @intFromEnum(std.c.E.TIMEDOUT));
}

export fn rvn_cond_signal(cond: [*c]thread_h.rvn_cond_t) void {
    _ = libc.pthread_cond_signal(&cond.*.handle);
}
export fn rvn_cond_broadcast(cond: [*c]thread_h.rvn_cond_t) void {
    _ = libc.pthread_cond_broadcast(&cond.*.handle);
}
