// Translated to Zig from vendor/raven/src/core/thread_win32.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/thread_win32.c
// Win32 implementation of core/thread.h (SRW locks, condition variables).

const std = @import("std");
const raven = @import("raven");
const base_h = @import("base_h.zig");
const thread_h = @import("thread_h.zig");

// Win32 API (windows.h), declared by hand. Handles are pointers, DWORD is u32, BOOL is c_int.
const INFINITE: u32 = 0xFFFFFFFF;

const LARGE_INTEGER = extern union {
    QuadPart: i64,
    u: extern struct {
        LowPart: u32,
        HighPart: i32,
    },
};

// SYSTEM_INFO (winnt.h), 48 bytes on x86_64.
const SYSTEM_INFO = extern struct {
    dwOemId: extern union {
        dwOemId: u32,
        s: extern struct {
            wProcessorArchitecture: u16,
            wReserved: u16,
        },
    },
    dwPageSize: u32,
    lpMinimumApplicationAddress: ?*anyopaque,
    lpMaximumApplicationAddress: ?*anyopaque,
    dwActiveProcessorMask: usize,
    dwNumberOfProcessors: u32,
    dwProcessorType: u32,
    dwAllocationGranularity: u32,
    wProcessorLevel: u16,
    wProcessorRevision: u16,
};

extern "kernel32" fn WaitForSingleObject(handle: ?*anyopaque, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetSystemInfo(info: *SYSTEM_INFO) callconv(.winapi) void;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceFrequency(frequency: *LARGE_INTEGER) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceCounter(counter: *LARGE_INTEGER) callconv(.winapi) c_int;
extern "kernel32" fn InitializeSRWLock(lock: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn AcquireSRWLockExclusive(lock: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn AcquireSRWLockShared(lock: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockShared(lock: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn InitializeConditionVariable(cond: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(cond: *anyopaque, lock: *anyopaque, milliseconds: u32, flags: u32) callconv(.winapi) c_int;
extern "kernel32" fn WakeConditionVariable(cond: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn WakeAllConditionVariable(cond: *anyopaque) callconv(.winapi) void;

// unsigned uintptr_t _beginthreadex(void*, unsigned, unsigned (__stdcall*)(void*), void*, unsigned, unsigned*)  (process.h)
extern "c" fn _beginthreadex(
    security: ?*anyopaque,
    stack_size: c_uint,
    start_address: *const fn (arg: ?*anyopaque) callconv(.winapi) c_uint,
    arglist: ?*anyopaque,
    initflag: c_uint,
    thrdaddr: ?*c_uint,
) usize;

const rvn_thread_start_t = extern struct {
    function: thread_h.rvn_thread_fn,
    arg: ?*anyopaque,
};

fn rvn_thread_entry(param: ?*anyopaque) callconv(.winapi) c_uint {
    const start: rvn_thread_start_t = @as([*c]rvn_thread_start_t, @ptrCast(@alignCast(param))).*;
    base_h.rvn_free(param);
    start.function.?(start.arg);
    return 0;
}

export fn rvn_thread_create(thread: [*c]thread_h.rvn_thread_t, function: thread_h.rvn_thread_fn, arg: ?*anyopaque, name: [*c]const u8) c_int {
    const start: [*c]rvn_thread_start_t = @ptrCast(@alignCast(base_h.rvn_calloc(@sizeOf(rvn_thread_start_t))));
    var handle: usize = undefined;
    _ = name;
    start.*.function = function;
    start.*.arg = arg;
    handle = _beginthreadex(null, 0, &rvn_thread_entry, start, 0, null);
    if (handle == 0) {
        base_h.rvn_free(start);
        return raven.R_FALSE;
    }
    thread.*.handle = @ptrFromInt(handle);
    return raven.R_TRUE;
}

export fn rvn_thread_join(thread: [*c]thread_h.rvn_thread_t) void {
    if (thread.*.handle == null) return;
    _ = WaitForSingleObject(thread.*.handle, INFINITE);
    _ = CloseHandle(thread.*.handle);
    thread.*.handle = null;
}

export fn rvn_thread_id() u64 {
    return @as(u64, GetCurrentThreadId());
}

export fn rvn_cpu_count() c_int {
    var info: SYSTEM_INFO = undefined;
    GetSystemInfo(&info);
    return if (info.dwNumberOfProcessors > 0) @as(c_int, @bitCast(info.dwNumberOfProcessors)) else 1;
}

export fn rvn_sleep_ms(milliseconds: c_int) void {
    if (milliseconds > 0) Sleep(@intCast(milliseconds));
}

export fn rvn_clock_seconds() f64 {
    // static LARGE_INTEGER frequency;
    const S = struct {
        var frequency: LARGE_INTEGER = std.mem.zeroes(LARGE_INTEGER);
    };
    var counter: LARGE_INTEGER = undefined;
    if (S.frequency.QuadPart == 0) _ = QueryPerformanceFrequency(&S.frequency);
    _ = QueryPerformanceCounter(&counter);
    return @as(f64, @floatFromInt(counter.QuadPart)) / @as(f64, @floatFromInt(S.frequency.QuadPart));
}

export fn rvn_mutex_init(mutex: [*c]thread_h.rvn_mutex_t) void {
    InitializeSRWLock(@ptrCast(&mutex.*.handle));
}
export fn rvn_mutex_destroy(mutex: [*c]thread_h.rvn_mutex_t) void {
    _ = mutex;
}
export fn rvn_mutex_lock(mutex: [*c]thread_h.rvn_mutex_t) void {
    AcquireSRWLockExclusive(@ptrCast(&mutex.*.handle));
}
export fn rvn_mutex_unlock(mutex: [*c]thread_h.rvn_mutex_t) void {
    ReleaseSRWLockExclusive(@ptrCast(&mutex.*.handle));
}

export fn rvn_rwlock_init(lock: [*c]thread_h.rvn_rwlock_t) void {
    InitializeSRWLock(@ptrCast(&lock.*.handle));
}
export fn rvn_rwlock_destroy(lock: [*c]thread_h.rvn_rwlock_t) void {
    _ = lock;
}
export fn rvn_rwlock_read_lock(lock: [*c]thread_h.rvn_rwlock_t) void {
    AcquireSRWLockShared(@ptrCast(&lock.*.handle));
}
export fn rvn_rwlock_read_unlock(lock: [*c]thread_h.rvn_rwlock_t) void {
    ReleaseSRWLockShared(@ptrCast(&lock.*.handle));
}
export fn rvn_rwlock_write_lock(lock: [*c]thread_h.rvn_rwlock_t) void {
    AcquireSRWLockExclusive(@ptrCast(&lock.*.handle));
}
export fn rvn_rwlock_write_unlock(lock: [*c]thread_h.rvn_rwlock_t) void {
    ReleaseSRWLockExclusive(@ptrCast(&lock.*.handle));
}

export fn rvn_cond_init(cond: [*c]thread_h.rvn_cond_t) void {
    InitializeConditionVariable(@ptrCast(&cond.*.handle));
}
export fn rvn_cond_destroy(cond: [*c]thread_h.rvn_cond_t) void {
    _ = cond;
}
export fn rvn_cond_wait(cond: [*c]thread_h.rvn_cond_t, mutex: [*c]thread_h.rvn_mutex_t) void {
    _ = SleepConditionVariableSRW(@ptrCast(&cond.*.handle), @ptrCast(&mutex.*.handle), INFINITE, 0);
}

export fn rvn_cond_wait_timeout(cond: [*c]thread_h.rvn_cond_t, mutex: [*c]thread_h.rvn_mutex_t, seconds: f64) c_int {
    const milliseconds: u32 = if (seconds <= 0.0) 0 else @intFromFloat(seconds * 1000.0 + 0.5);
    return @intFromBool(SleepConditionVariableSRW(@ptrCast(&cond.*.handle), @ptrCast(&mutex.*.handle), milliseconds, 0) != 0);
}

export fn rvn_cond_signal(cond: [*c]thread_h.rvn_cond_t) void {
    WakeConditionVariable(@ptrCast(&cond.*.handle));
}
export fn rvn_cond_broadcast(cond: [*c]thread_h.rvn_cond_t) void {
    WakeAllConditionVariable(@ptrCast(&cond.*.handle));
}
