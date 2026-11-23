// Seridian: hand-written extern declarations of the C library functions Raven calls (Zig 0.18 has no @cImport).
// Verified by zig/check_unit.sh and by the tests at the bottom. Not a translation of a Raven file.
//
//   const libc = @import("../sys/libc.zig");       // path relative to the importing file
//   const n = libc.strlen(text);
//
// Rules: raw C signatures (C pointers, c_int, usize, ...). For memcpy / memmove / memset use @memcpy / @memset
// (or the externs here when the C code passes unrelated pointers and sizes). Types whose layout depends on the OS
// (FILE, DIR, dirent, stat, timespec, pollfd, pthread_*_t, sockaddr...) come from std.c, which has them for
// every OS: std.c.Stat, std.c.dirent, std.c.timespec, std.c.pthread_mutex_t, ...
// Functions whose symbol differs by OS (stat on Intel macOS, readdir, opendir) are re-exported from std.c.
// Functions missing here: declare them in the translated file with `extern "c" fn`, like these.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const FILE = opaque {};
pub const size_t = usize;

// ---- memory ----
pub extern "c" fn malloc(size: usize) ?*anyopaque;
pub extern "c" fn calloc(count: usize, size: usize) ?*anyopaque;
pub extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
pub extern "c" fn free(ptr: ?*anyopaque) void;
pub extern "c" fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
pub extern "c" fn memchr(s: ?*const anyopaque, ch: c_int, n: usize) ?*anyopaque;
pub extern "c" fn memmove(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
pub extern "c" fn memcpy(dst: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
pub extern "c" fn memset(dst: ?*anyopaque, ch: c_int, n: usize) ?*anyopaque;

// ---- strings ----
pub extern "c" fn strlen(s: [*c]const u8) usize;
pub extern "c" fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;
pub extern "c" fn strncmp(a: [*c]const u8, b: [*c]const u8, n: usize) c_int;
pub extern "c" fn strchr(s: [*c]const u8, ch: c_int) [*c]u8;
pub extern "c" fn strrchr(s: [*c]const u8, ch: c_int) [*c]u8;
pub extern "c" fn strstr(haystack: [*c]const u8, needle: [*c]const u8) [*c]u8;
pub extern "c" fn strspn(s: [*c]const u8, accept: [*c]const u8) usize;
pub extern "c" fn strcspn(s: [*c]const u8, reject: [*c]const u8) usize;
pub extern "c" fn strcpy(dst: [*c]u8, src: [*c]const u8) [*c]u8;
pub extern "c" fn strncpy(dst: [*c]u8, src: [*c]const u8, n: usize) [*c]u8;
pub extern "c" fn strtod(s: [*c]const u8, end: [*c][*c]u8) f64;
pub extern "c" fn atoi(s: [*c]const u8) c_int;

// ---- stdio (variadic functions are called as in C: floats are passed as f64) ----
pub extern "c" fn fopen(path: [*c]const u8, mode: [*c]const u8) ?*FILE;
pub extern "c" fn fclose(f: *FILE) c_int;
pub extern "c" fn fread(ptr: ?*anyopaque, size: usize, count: usize, f: *FILE) usize;
pub extern "c" fn fwrite(ptr: ?*const anyopaque, size: usize, count: usize, f: *FILE) usize;
pub extern "c" fn fseek(f: *FILE, offset: c_long, whence: c_int) c_int;
pub extern "c" fn ftell(f: *FILE) c_long;
pub extern "c" fn fputs(s: [*c]const u8, f: *FILE) c_int;
pub extern "c" fn snprintf(buf: [*c]u8, size: usize, format: [*c]const u8, ...) c_int;
/// C's va_list. On non-Windows, vsnprintf takes a POINTER to it (a System V va_list is an array of one struct, which decays
/// to a pointer): call `vsnprintf(buf, n, fmt, &args)`.
/// @cVaStart() / @cVaArg() / @cVaEnd() give and use std.builtin.VaList, but this compiler
/// disables std.builtin.VaList on Windows (a char* there): functions that DEFINE variadic functions cannot be
/// analysed for x86_64-windows-gnu. See PORTING.md, "Variadic functions".
pub const va_list = if (builtin.os.tag == .windows) [*c]u8 else std.builtin.VaList;
pub extern "c" fn vsnprintf(buf: [*c]u8, size: usize, format: [*c]const u8, args: if (builtin.os.tag == .windows) va_list else *va_list) c_int;
pub extern "c" fn printf(format: [*c]const u8, ...) c_int;
pub const SEEK_SET: c_int = 0;
pub const SEEK_CUR: c_int = 1;
pub const SEEK_END: c_int = 2;
extern "c" var __stderrp: ?*FILE; // macOS
extern "c" var stderr: ?*FILE; // glibc, musl
extern "c" fn __acrt_iob_func(index: c_uint) ?*FILE; // Windows (UCRT / mingw)
extern "c" fn __getreent() *anyopaque;
/// C's `stderr` (a macro or a different symbol on each OS).
pub fn stderrFile() ?*FILE {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => __stderrp,
        .windows => __acrt_iob_func(2),
        else => stderr,
    };
}

// ---- stdlib ----
pub extern "c" fn qsort(base: ?*anyopaque, count: usize, size: usize, cmp: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int) void;
pub extern "c" fn getenv(name: [*c]const u8) [*c]u8;
pub extern "c" fn abort() noreturn;
pub extern "c" fn exit(status: c_int) noreturn;

// ---- math (sqrt, floor, ceil, abs, trunc, sin, cos, exp, log have builtins: @sqrt @floor @ceil @abs @trunc @sin @cos @exp @log) ----
pub extern "c" fn fmod(x: f64, y: f64) f64;
pub extern "c" fn fmodf(x: f32, y: f32) f32;
pub extern "c" fn powf(x: f32, y: f32) f32;
pub extern "c" fn expf(x: f32) f32;
pub extern "c" fn sinf(x: f32) f32;
pub extern "c" fn cosf(x: f32) f32;
pub extern "c" fn tanf(x: f32) f32;
pub extern "c" fn atan2f(y: f32, x: f32) f32;
pub extern "c" fn logf(x: f32) f32;
pub extern "c" fn roundf(x: f32) f32;

// ---- time ----
pub extern "c" fn clock_gettime(clock: c.clockid_t, ts: *c.timespec) c_int;
pub extern "c" fn nanosleep(req: *const c.timespec, rem: ?*c.timespec) c_int;
pub extern "c" fn strftime(buf: [*c]u8, size: usize, format: [*c]const u8, tm: ?*const anyopaque) usize;
pub extern "c" fn localtime(t: *const c.time_t) ?*anyopaque; // struct tm*

// ---- POSIX (not on Windows) ----
pub extern "c" fn open(path: [*c]const u8, flags: c_int, ...) c_int;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn read(fd: c_int, buf: ?*anyopaque, count: usize) isize;
pub extern "c" fn write(fd: c_int, buf: ?*const anyopaque, count: usize) isize;
pub extern "c" fn pipe(fds: *[2]c_int) c_int;
pub extern "c" fn dup2(old: c_int, new: c_int) c_int;
pub extern "c" fn fork() c_int;
pub extern "c" fn execvp(file: [*c]const u8, argv: [*c]const [*c]const u8) c_int;
pub extern "c" fn execlp(file: [*c]const u8, arg: [*c]const u8, ...) c_int;
pub extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
pub extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
pub extern "c" fn mkdir(path: [*c]const u8, mode: c.mode_t) c_int;
pub extern "c" fn getcwd(buf: [*c]u8, size: usize) [*c]u8;
pub extern "c" fn access(path: [*c]const u8, mode: c_int) c_int;
pub extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: c.off_t) ?*anyopaque;
pub extern "c" fn munmap(addr: ?*anyopaque, len: usize) c_int;
pub extern "c" fn poll(fds: [*c]c.pollfd, count: c_ulong, timeout_ms: c_int) c_int;
pub extern "c" fn sysconf(name: c_int) c_long;
pub extern "c" fn _exit(status: c_int) noreturn;
pub const stat = c.stat;
pub const opendir = c.opendir;
pub const readdir = c.readdir;
pub const closedir = c.closedir;

// ---- dynamic loading (libdl) ----
pub extern "c" fn dlopen(path: [*c]const u8, mode: c_int) ?*anyopaque;
pub extern "c" fn dlsym(handle: ?*anyopaque, name: [*c]const u8) ?*anyopaque;
pub extern "c" fn dlclose(handle: ?*anyopaque) c_int;
pub const RTLD_LAZY: c_int = 0x1;
pub const RTLD_NOW: c_int = 0x2;

// ---- threads (types from std.c; see src/core/thread.h) ----
pub const pthread_t = c.pthread_t;
pub const pthread_mutex_t = c.pthread_mutex_t;
pub const pthread_cond_t = c.pthread_cond_t;
pub const pthread_rwlock_t = c.pthread_rwlock_t;
pub extern "c" fn pthread_create(thread: *c.pthread_t, attr: ?*const anyopaque, start: *const fn (?*anyopaque) callconv(.c) ?*anyopaque, arg: ?*anyopaque) c_int;
pub extern "c" fn pthread_join(thread: c.pthread_t, result: ?*?*anyopaque) c_int;
pub extern "c" fn pthread_mutex_init(m: *c.pthread_mutex_t, attr: ?*const anyopaque) c_int;
pub extern "c" fn pthread_mutex_destroy(m: *c.pthread_mutex_t) c_int;
pub extern "c" fn pthread_mutex_lock(m: *c.pthread_mutex_t) c_int;
pub extern "c" fn pthread_mutex_unlock(m: *c.pthread_mutex_t) c_int;
pub extern "c" fn pthread_cond_init(cv: *c.pthread_cond_t, attr: ?*const anyopaque) c_int;
pub extern "c" fn pthread_cond_destroy(cv: *c.pthread_cond_t) c_int;
pub extern "c" fn pthread_cond_wait(cv: *c.pthread_cond_t, m: *c.pthread_mutex_t) c_int;
pub extern "c" fn pthread_cond_timedwait(cv: *c.pthread_cond_t, m: *c.pthread_mutex_t, abstime: *const c.timespec) c_int;
pub extern "c" fn pthread_cond_signal(cv: *c.pthread_cond_t) c_int;
pub extern "c" fn pthread_cond_broadcast(cv: *c.pthread_cond_t) c_int;
pub extern "c" fn pthread_rwlock_init(l: *c.pthread_rwlock_t, attr: ?*const anyopaque) c_int;
pub extern "c" fn pthread_rwlock_destroy(l: *c.pthread_rwlock_t) c_int;
pub extern "c" fn pthread_rwlock_rdlock(l: *c.pthread_rwlock_t) c_int;
pub extern "c" fn pthread_rwlock_wrlock(l: *c.pthread_rwlock_t) c_int;
pub extern "c" fn pthread_rwlock_unlock(l: *c.pthread_rwlock_t) c_int;

test "libc externs link and work" {
    const t = std.testing;
    const p: [*c]u8 = @ptrCast(malloc(16));
    try t.expect(p != null);
    _ = strcpy(p, "hello");
    try t.expect(strlen(p) == 5 and strcmp(p, "hello") == 0 and strncmp(p, "help", 3) == 0);
    try t.expect(strchr(p, 'l') == p + 2 and strrchr(p, 'l') == p + 3 and strstr(p, "llo") == p + 2);
    try t.expect(strspn(p, "eh") == 2 and strcspn(p, "l") == 2);
    var buf: [32]u8 = undefined;
    const n = snprintf(&buf, buf.len, "%d:%s:%.1f", @as(c_int, 4), p, @as(f64, 2.5));
    try t.expect(n == 11 and std.mem.eql(u8, buf[0..11], "4:hello:2.5"));
    try t.expect(strtod("3.25xyz", null) == 3.25 and atoi("42") == 42);
    free(p);
    try t.expect(powf(2, 10) == 1024 and fmodf(5.5, 2) == 1.5);
    var ts: c.timespec = undefined;
    try t.expect(clock_gettime(c.CLOCK.MONOTONIC, &ts) == 0);
    const h = dlopen(null, RTLD_NOW);
    try t.expect(h != null and dlsym(h, "strlen") != null);
    _ = dlclose(h);
    try t.expect(getenv("RVN_SURELY_NOT_SET_12345") == null);
    try t.expect(stderrFile() != null);
    var m: pthread_mutex_t = undefined;
    try t.expect(pthread_mutex_init(&m, null) == 0 and pthread_mutex_lock(&m) == 0 and pthread_mutex_unlock(&m) == 0);
    _ = pthread_mutex_destroy(&m);
}
