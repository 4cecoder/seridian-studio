//! The C library and POSIX functions the window calls, declared by hand (there is no @cImport in this toolchain).
//! Prototypes follow the man pages; integer constants come from std.os.linux / std.c so they cannot drift.
//! Linux only, like the C it replaces (accept4, pipe2 and close_range are Linux APIs).

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

comptime {
    if (builtin.os.tag != .linux) @compileError("the Seridian Studio window is Linux-only (accept4, pipe2, close_range)");
}

pub const pid_t = std.c.pid_t;
pub const mode_t = std.c.mode_t;
pub const timespec = std.c.timespec;
pub const pollfd = std.c.pollfd;
pub const sockaddr = std.c.sockaddr;
pub const sockaddr_un = std.c.sockaddr.un;
pub const socklen_t = std.c.socklen_t;
pub const FILE = opaque {};

/// glibc `struct stat`. std.c.Stat is void on Linux in this Zig, so it is spelled out per architecture.
pub const Stat = switch (builtin.cpu.arch) {
    .x86_64 => extern struct {
        st_dev: u64,
        st_ino: u64,
        st_nlink: u64,
        st_mode: u32,
        st_uid: u32,
        st_gid: u32,
        __pad0: i32,
        st_rdev: u64,
        st_size: i64,
        st_blksize: i64,
        st_blocks: i64,
        st_atim: timespec,
        st_mtim: timespec,
        st_ctim: timespec,
        __glibc_reserved: [3]i64,
    },
    .aarch64 => extern struct {
        st_dev: u64,
        st_ino: u64,
        st_mode: u32,
        st_nlink: u32,
        st_uid: u32,
        st_gid: u32,
        st_rdev: u64,
        __pad1: u64,
        st_size: i64,
        st_blksize: i32,
        __pad2: i32,
        st_blocks: i64,
        st_atim: timespec,
        st_mtim: timespec,
        st_ctim: timespec,
        __glibc_reserved: [2]i32,
    },
    else => @compileError("struct stat layout not declared for this architecture"),
};
comptime {
    std.debug.assert(@sizeOf(Stat) == if (builtin.cpu.arch == .x86_64) 144 else 128);
}

/// S_ISDIR(mode)
pub fn S_ISDIR(mode: u32) bool {
    return (mode & 0o170000) == 0o040000;
}

// errno values (Linux).
pub const EEXIST: c_int = @backingInt(linux.E.EXIST);
pub const ENOTDIR: c_int = @backingInt(linux.E.NOTDIR);
pub const ENOENT: c_int = @backingInt(linux.E.NOENT);
pub const EINTR: c_int = @backingInt(linux.E.INTR);
pub const EAGAIN: c_int = @backingInt(linux.E.AGAIN);
pub const EWOULDBLOCK: c_int = EAGAIN;

/// The calling thread's errno.
pub fn errno() c_int {
    return std.c._errno().*;
}
/// `errno = value;`
pub fn set_errno(value: c_int) void {
    std.c._errno().* = value;
}

pub const AF_UNIX: c_int = linux.AF.UNIX;
pub const SOCK_STREAM: c_int = linux.SOCK.STREAM;
pub const SOCK_NONBLOCK: c_int = linux.SOCK.NONBLOCK;
pub const SOCK_CLOEXEC: c_int = linux.SOCK.CLOEXEC;
pub const MSG_NOSIGNAL: c_int = linux.MSG.NOSIGNAL;
pub const MSG_DONTWAIT: c_int = linux.MSG.DONTWAIT;
pub const O_RDWR: c_int = 0o2;
pub const O_CLOEXEC: c_int = 0o2000000;
pub const POLLIN: c_short = linux.POLL.IN;
pub const WNOHANG: c_int = 1;
pub const SIGKILL: c_int = 9;
pub const X_OK: c_int = 1;
pub const CLOCK_MONOTONIC: c_int = 1;
pub const TIME_UTC: c_int = 1;

/// WIFEXITED(status)
pub fn WIFEXITED(status: c_int) bool {
    return (status & 0x7f) == 0;
}
/// WEXITSTATUS(status)
pub fn WEXITSTATUS(status: c_int) c_int {
    return (status & 0xff00) >> 8;
}
/// WIFSIGNALED(status)
pub fn WIFSIGNALED(status: c_int) bool {
    // glibc: ((signed char)((status & 0x7f) + 1) >> 1) > 0
    return (@as(i8, @bitCast(@as(u8, @truncate(@as(c_uint, @bitCast((status & 0x7f) + 1)))))) >> 1) > 0;
}
/// WTERMSIG(status)
pub fn WTERMSIG(status: c_int) c_int {
    return status & 0x7f;
}

pub extern "c" fn snprintf(buffer: [*c]u8, size: usize, format: [*c]const u8, ...) c_int;
pub extern "c" fn fprintf(file: *FILE, format: [*c]const u8, ...) c_int;
pub extern "c" fn fopen(path: [*c]const u8, mode: [*c]const u8) ?*FILE;
pub extern "c" fn fclose(file: *FILE) c_int;
pub extern "c" fn strlen(text: [*c]const u8) usize;
pub extern "c" fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;
pub extern "c" fn strncmp(a: [*c]const u8, b: [*c]const u8, n: usize) c_int;
pub extern "c" fn strcasecmp(a: [*c]const u8, b: [*c]const u8) c_int;
pub extern "c" fn strchr(text: [*c]const u8, ch: c_int) [*c]u8;
pub extern "c" fn strrchr(text: [*c]const u8, ch: c_int) [*c]u8;
pub extern "c" fn strtok_r(text: [*c]u8, delimiters: [*c]const u8, save: [*c][*c]u8) [*c]u8;
pub extern "c" fn strtol(text: [*c]const u8, end: [*c][*c]u8, base: c_int) c_long;
pub extern "c" fn strtod(text: [*c]const u8, end: [*c][*c]u8) f64;
pub extern "c" fn strerror(code: c_int) [*c]u8;
pub extern "c" fn memchr(data: ?*const anyopaque, ch: c_int, n: usize) ?*anyopaque;
pub extern "c" fn memcmp(a: ?*const anyopaque, b: ?*const anyopaque, n: usize) c_int;
pub extern "c" fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
pub extern "c" fn getenv(name: [*c]const u8) [*c]u8;
pub extern "c" fn calloc(count: usize, size: usize) ?*anyopaque;
pub extern "c" fn free(pointer: ?*anyopaque) void;
pub extern "c" fn time(out: ?*c_long) c_long;
pub extern "c" fn clock_gettime(clock: c_int, now: *timespec) c_int;
pub extern "c" fn timespec_get(now: *timespec, base: c_int) c_int;

pub extern "c" fn stat(path: [*c]const u8, info: *Stat) c_int;
pub extern "c" fn lstat(path: [*c]const u8, info: *Stat) c_int;
pub extern "c" fn mkdir(path: [*c]const u8, mode: mode_t) c_int;
pub extern "c" fn access(path: [*c]const u8, mode: c_int) c_int;
pub extern "c" fn chmod(path: [*c]const u8, mode: mode_t) c_int;
pub extern "c" fn umask(mask: mode_t) mode_t;
pub extern "c" fn unlink(path: [*c]const u8) c_int;
pub extern "c" fn readlink(path: [*c]const u8, buffer: [*c]u8, size: usize) isize;
pub extern "c" fn open(path: [*c]const u8, flags: c_int, ...) c_int;
pub extern "c" fn read(fd: c_int, buffer: ?*anyopaque, size: usize) isize;
pub extern "c" fn close(fd: c_int) c_int;
pub extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
pub extern "c" fn dup2(old_fd: c_int, new_fd: c_int) c_int;
pub extern "c" fn close_range(first: c_uint, last: c_uint, flags: c_int) c_int;
pub extern "c" fn fork() pid_t;
pub extern "c" fn execv(path: [*c]const u8, argv: [*c]const [*c]u8) c_int;
pub extern "c" fn _exit(status: c_int) noreturn;
pub extern "c" fn waitpid(pid: pid_t, status: ?*c_int, options: c_int) pid_t;
pub extern "c" fn kill(pid: pid_t, signal: c_int) c_int;
pub extern "c" fn getpid() pid_t;
pub extern "c" fn poll(fds: [*c]pollfd, count: c_ulong, timeout_ms: c_int) c_int;

pub extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
pub extern "c" fn bind(fd: c_int, address: *const sockaddr, length: socklen_t) c_int;
pub extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
pub extern "c" fn accept4(fd: c_int, address: ?*sockaddr, length: ?*socklen_t, flags: c_int) c_int;
pub extern "c" fn recv(fd: c_int, buffer: ?*anyopaque, size: usize, flags: c_int) isize;
pub extern "c" fn send(fd: c_int, buffer: ?*const anyopaque, size: usize, flags: c_int) isize;

pub extern "c" fn powf(base: f32, exponent: f32) f32;
pub extern "c" fn fminf(a: f32, b: f32) f32;
pub extern "c" fn fmaxf(a: f32, b: f32) f32;
pub extern "c" fn fmin(a: f64, b: f64) f64;
pub extern "c" fn fmax(a: f64, b: f64) f64;
pub extern "c" fn fabs(value: f64) f64;
pub extern "c" fn fabsf(value: f32) f32;
pub extern "c" fn round(value: f64) f64;
pub extern "c" fn floor(value: f64) f64;

/// isfinite(value)
pub fn isfinite(value: f64) bool {
    return std.math.isFinite(value);
}

test "wait status macros decode like glibc" {
    // exit(3): status 0x0300; killed by SIGKILL: status 9.
    try std.testing.expect(WIFEXITED(0x0300));
    try std.testing.expectEqual(@as(c_int, 3), WEXITSTATUS(0x0300));
    try std.testing.expect(!WIFSIGNALED(0x0300));
    try std.testing.expect(WIFSIGNALED(9));
    try std.testing.expectEqual(@as(c_int, 9), WTERMSIG(9));
    try std.testing.expect(!WIFEXITED(9));
    // Stopped (0x137f) is neither exited nor signaled.
    try std.testing.expect(!WIFSIGNALED(0x137f));
}

test "S_ISDIR and constants" {
    try std.testing.expect(S_ISDIR(0o040755));
    try std.testing.expect(!S_ISDIR(0o100644));
    try std.testing.expectEqual(@as(c_int, 17), EEXIST);
    try std.testing.expectEqual(@as(c_int, 4), EINTR);
}
