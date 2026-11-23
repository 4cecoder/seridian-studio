// Translated to Zig from vendor/raven/web/src/web_posix.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Web - web_posix.c
// Linux and the other Unix systems: the browser process and its two pipes,
// the reading thread, folders.
//
// The "pipes" are socket pairs: a write to a browser that died then fails
// instead of killing the application with SIGPIPE, and a read that waits in
// another thread can be woken up (shutdown).
//
// `#if !defined(_WIN32) ... #endif` around the whole file: on Windows this file exports nothing (comptime below).

const std = @import("std");
const builtin = @import("builtin");
const web = @import("web_internal_h.zig");
const libc = @import("../sys/libc.zig");

const c = std.c;

// ---- the C library and POSIX functions this file needs that libc.zig does not declare ----
extern "c" fn socketpair(domain: c_int, type_: c_int, protocol: c_int, sv: *[2]c_int) c_int;
extern "c" fn send(socket: c_int, buffer: ?*const anyopaque, length: usize, flags: c_int) isize;
extern "c" fn recv(socket: c_int, buffer: ?*anyopaque, length: usize, flags: c_int) isize;
extern "c" fn shutdown(socket: c_int, how: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn setpgid(pid: c_int, pgid: c_int) c_int;
extern "c" fn execv(path: [*c]const u8, argv: [*c]const [*c]const u8) c_int;
extern "c" fn geteuid() c_uint;
extern "c" fn lstat(path: [*c]const u8, buf: *anyopaque) c_int;
extern "c" fn unlink(path: [*c]const u8) c_int;
extern "c" fn rmdir(path: [*c]const u8) c_int;
extern "c" fn mkdtemp(template: [*c]u8) [*c]u8;
extern "c" fn realpath(path: [*c]const u8, resolved: [*c]u8) [*c]u8;

// ---- the values of the C headers (sys/socket.h, fcntl.h, signal.h, sys/wait.h, unistd.h, limits.h, errno.h) ----
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const SHUT_RDWR: c_int = 2;
/// (0 where the system has no MSG_NOSIGNAL)
const MSG_NOSIGNAL: c_int = if (@hasDecl(c, "MSG") and @TypeOf(c.MSG) == type and @hasDecl(c.MSG, "NOSIGNAL")) c.MSG.NOSIGNAL else 0;
const F_DUPFD: c_int = 0;
const F_SETFD: c_int = 2;
const FD_CLOEXEC: c_int = 1;
const O_RDWR: c_int = 2;
const SIGKILL: c_int = 9;
const WNOHANG: c_int = 1;
const X_OK: c_int = 1;
const _SC_OPEN_MAX: c_int = if (builtin.os.tag.isDarwin()) 5 else 4;
const PATH_MAX: usize = if (builtin.os.tag.isDarwin()) 1024 else 4096;
const EINTR: c_int = 4;
const S_IFMT: u32 = 0o170000;
const S_IFREG: u32 = 0o100000;
const S_IFDIR: u32 = 0o040000;

fn errnoValue() c_int {
    return c._errno().*;
}

inline fn S_ISREG(mode: u32) bool {
    return (mode & S_IFMT) == S_IFREG;
}

inline fn S_ISDIR(mode: u32) bool {
    return (mode & S_IFMT) == S_IFDIR;
}

/// stat(path, &info) (or lstat when `follow` is false), keeping st_mode, the one field this file reads.
/// std.c has no `struct stat` on Linux (it goes through statx): there the mode comes from statx(AT_FDCWD, ...),
/// with AT_SYMLINK_NOFOLLOW for lstat (as core/fs.zig does).
fn statMode(path: [*c]const u8, follow: bool, mode: *u32) c_int {
    if (builtin.os.tag == .linux) {
        var buf: std.os.linux.Statx = undefined;
        const flags: u32 = if (follow) 0 else std.os.linux.AT.SYMLINK_NOFOLLOW;
        const rc = c.statx(std.os.linux.AT.FDCWD, path, flags, std.os.linux.STATX.BASIC_STATS, &buf);
        if (rc != 0) return rc;
        mode.* = buf.mode;
        return 0;
    } else {
        var st: c.Stat = undefined;
        const rc = if (follow) libc.stat(@ptrCast(path), &st) else lstat(path, &st);
        if (rc != 0) return rc;
        mode.* = @as(u32, st.mode);
        return 0;
    }
}

comptime {
    if (builtin.os.tag != .windows) {
        @export(&rw_process_start, .{ .name = "rw_process_start" });
        @export(&rw_process_write, .{ .name = "rw_process_write" });
        @export(&rw_process_read, .{ .name = "rw_process_read" });
        @export(&rw_process_hang_up, .{ .name = "rw_process_hang_up" });
        @export(&rw_process_stop, .{ .name = "rw_process_stop" });
        @export(&rw_thread_start, .{ .name = "rw_thread_start" });
        @export(&rw_thread_join, .{ .name = "rw_thread_join" });
        @export(&rw_mutex_create, .{ .name = "rw_mutex_create" });
        @export(&rw_mutex_destroy, .{ .name = "rw_mutex_destroy" });
        @export(&rw_mutex_lock, .{ .name = "rw_mutex_lock" });
        @export(&rw_mutex_unlock, .{ .name = "rw_mutex_unlock" });
        @export(&rw_is_program, .{ .name = "rw_is_program" });
        @export(&rw_find_browser, .{ .name = "rw_find_browser" });
        @export(&rw_temp_folder, .{ .name = "rw_temp_folder" });
        @export(&rw_remove_folder, .{ .name = "rw_remove_folder" });
        @export(&rw_file_url, .{ .name = "rw_file_url" });
        @export(&rw_needs_no_sandbox, .{ .name = "rw_needs_no_sandbox" });
    }
}

const rw_process_t = extern struct {
    pid: c_int,
    /// Our end of the pipe the child reads, and of the pipe it writes.
    to_child: c_int,
    from_child: c_int,
};

fn rw_process_start(arguments: [*c]const [*c]const u8) callconv(.c) ?*web.rw_process_t {
    var down: [2]c_int = undefined;
    var up: [2]c_int = undefined;

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, &down) != 0) return null;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, &up) != 0) {
        _ = libc.close(down[0]);
        _ = libc.close(down[1]);
        return null;
    }
    const pid = libc.fork();
    if (pid < 0) {
        _ = libc.close(down[0]);
        _ = libc.close(down[1]);
        _ = libc.close(up[0]);
        _ = libc.close(up[1]);
        return null;
    }
    if (pid == 0) {
        // the child: its ends become descriptors 3 and 4, everything else is closed
        const input = libc.fcntl(down[1], F_DUPFD, @as(c_int, 10));
        const output = libc.fcntl(up[1], F_DUPFD, @as(c_int, 10));
        var limit: c_int = @truncate(libc.sysconf(_SC_OPEN_MAX));
        if (input < 0 or output < 0) libc._exit(127);
        if (libc.dup2(input, 3) < 0 or libc.dup2(output, 4) < 0) libc._exit(127);
        if (limit < 0 or limit > 65536) limit = 65536;
        var fd: c_int = 5;
        while (fd < limit) : (fd += 1) _ = libc.close(fd);
        // a browser talks a lot on its error output: only shown when asked
        if (libc.getenv("RAVEN_WEB_DEBUG") == null) {
            const null_ = libc.open("/dev/null", O_RDWR);
            if (null_ >= 0) {
                _ = libc.dup2(null_, 0);
                _ = libc.dup2(null_, 1);
                _ = libc.dup2(null_, 2);
                if (null_ > 4) _ = libc.close(null_);
            }
        }
        // in its own group: a Ctrl+C in the terminal of the application is for the application
        _ = setpgid(0, 0);
        _ = execv(arguments[0], arguments);
        libc._exit(127);
    }
    _ = libc.close(down[1]);
    _ = libc.close(up[1]);
    const process: [*c]rw_process_t = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_process_t))));
    if (process == null) {
        _ = libc.close(down[0]);
        _ = libc.close(up[0]);
        _ = kill(pid, SIGKILL);
        _ = libc.waitpid(pid, null, 0);
        return null;
    }
    process.*.pid = pid;
    process.*.to_child = down[0];
    process.*.from_child = up[0];
    // (not passed on to the programs the application may start later)
    _ = libc.fcntl(process.*.to_child, F_SETFD, FD_CLOEXEC);
    _ = libc.fcntl(process.*.from_child, F_SETFD, FD_CLOEXEC);
    return @ptrCast(process);
}

fn rw_process_write(process_: ?*web.rw_process_t, data: ?*const anyopaque, size_: usize) callconv(.c) c_int {
    const process: [*c]rw_process_t = @ptrCast(@alignCast(process_));
    var cursor: [*c]const u8 = @ptrCast(data);
    var size = size_;
    while (size > 0) {
        const sent = send(process.*.to_child, cursor, size, MSG_NOSIGNAL);
        if (sent < 0) {
            if (errnoValue() == EINTR) continue;
            return 0;
        }
        cursor += @as(usize, @intCast(sent));
        size -= @intCast(sent);
    }
    return 1;
}

fn rw_process_read(process_: ?*web.rw_process_t, buffer: ?*anyopaque, size: usize) callconv(.c) c_int {
    const process: [*c]rw_process_t = @ptrCast(@alignCast(process_));
    while (true) {
        const got = recv(process.*.from_child, buffer, size, 0);
        if (got < 0 and errnoValue() == EINTR) continue;
        return if (got < 0) 0 else @intCast(got);
    }
}

fn rw_process_hang_up(process_: ?*web.rw_process_t) callconv(.c) void {
    const process: [*c]rw_process_t = @ptrCast(@alignCast(process_));
    _ = shutdown(process.*.to_child, SHUT_RDWR);
    _ = shutdown(process.*.from_child, SHUT_RDWR);
}

fn rw_process_stop(process_: ?*web.rw_process_t) callconv(.c) void {
    const process: [*c]rw_process_t = @ptrCast(@alignCast(process_));
    var status: c_int = 0;
    var gone: c_int = 0;
    rw_process_hang_up(process_);
    // a browser leaves by itself when its pipe closes: it is given two seconds
    var i: c_int = 0;
    while (i < 200 and gone == 0) : (i += 1) {
        const pause: c.timespec = .{ .sec = 0, .nsec = 10 * 1000 * 1000 };
        if (libc.waitpid(process.*.pid, &status, WNOHANG) != 0) {
            gone = 1;
        } else {
            _ = libc.nanosleep(&pause, null);
        }
    }
    if (gone == 0) {
        // its group: the helpers it started go with it
        _ = kill(-process.*.pid, SIGKILL);
        _ = kill(process.*.pid, SIGKILL);
        _ = libc.waitpid(process.*.pid, &status, 0);
    }
    _ = libc.close(process.*.to_child);
    _ = libc.close(process.*.from_child);
    web.rw_free(process);
}

// ---------------------------------------------------------------------------
//  Thread and lock
// ---------------------------------------------------------------------------

const rw_thread_t = extern struct {
    handle: libc.pthread_t,
    function: ?*const fn (?*anyopaque) callconv(.c) void,
    argument: ?*anyopaque,
};

fn rw_thread_main(argument: ?*anyopaque) callconv(.c) ?*anyopaque {
    const thread: [*c]rw_thread_t = @ptrCast(@alignCast(argument));
    thread.*.function.?(thread.*.argument);
    return null;
}

fn rw_thread_start(function: ?*const fn (?*anyopaque) callconv(.c) void, argument: ?*anyopaque) callconv(.c) ?*web.rw_thread_t {
    const thread: [*c]rw_thread_t = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_thread_t))));
    if (thread == null) return null;
    thread.*.function = function;
    thread.*.argument = argument;
    if (libc.pthread_create(&thread.*.handle, null, &rw_thread_main, thread) != 0) {
        web.rw_free(thread);
        return null;
    }
    return @ptrCast(thread);
}

fn rw_thread_join(thread_: ?*web.rw_thread_t) callconv(.c) void {
    const thread: [*c]rw_thread_t = @ptrCast(@alignCast(thread_));
    if (thread == null) return;
    _ = libc.pthread_join(thread.*.handle, null);
    web.rw_free(thread);
}

const rw_mutex_t = extern struct {
    handle: libc.pthread_mutex_t,
};

fn rw_mutex_create() callconv(.c) ?*web.rw_mutex_t {
    const mutex: [*c]rw_mutex_t = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_mutex_t))));
    if (mutex != null) _ = libc.pthread_mutex_init(&mutex.*.handle, null);
    return @ptrCast(mutex);
}

fn rw_mutex_destroy(mutex_: ?*web.rw_mutex_t) callconv(.c) void {
    const mutex: [*c]rw_mutex_t = @ptrCast(@alignCast(mutex_));
    if (mutex == null) return;
    _ = libc.pthread_mutex_destroy(&mutex.*.handle);
    web.rw_free(mutex);
}

fn rw_mutex_lock(mutex_: ?*web.rw_mutex_t) callconv(.c) void {
    const mutex: [*c]rw_mutex_t = @ptrCast(@alignCast(mutex_));
    _ = libc.pthread_mutex_lock(&mutex.*.handle);
}

fn rw_mutex_unlock(mutex_: ?*web.rw_mutex_t) callconv(.c) void {
    const mutex: [*c]rw_mutex_t = @ptrCast(@alignCast(mutex_));
    _ = libc.pthread_mutex_unlock(&mutex.*.handle);
}

// ---------------------------------------------------------------------------
//  Files
// ---------------------------------------------------------------------------

fn rw_is_program(path: [*c]const u8) callconv(.c) c_int {
    var info: u32 = 0; // struct stat info;   (its st_mode)
    return @intFromBool(path != null and path[0] != 0 and statMode(path, true, &info) == 0 and S_ISREG(info) and libc.access(path, X_OK) == 0);
}

const names = [_][*c]const u8{
    "chromium",              "chromium-browser", "google-chrome", "google-chrome-stable", "microsoft-edge",
    "microsoft-edge-stable", "brave-browser",    "vivaldi",       "chrome",
};
const places = [_][*c]const u8{
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/snap/bin/chromium",
};

fn rw_find_browser() callconv(.c) [*c]u8 {
    const search: [*c]const u8 = libc.getenv("PATH");
    var candidate: [PATH_MAX]u8 = undefined;

    for (names) |name| {
        var cursor = search;
        while (cursor != null and cursor.* != 0) {
            const end: [*c]const u8 = libc.strchr(cursor, ':');
            const length: usize = if (end != null) @intCast(end - cursor) else libc.strlen(cursor);
            if (length > 0 and length + libc.strlen(name) + 2 < candidate.len) {
                _ = libc.snprintf(&candidate, candidate.len, "%.*s/%s", @as(c_int, @intCast(length)), cursor, name);
                if (rw_is_program(&candidate) != 0) return web.rw_strdup(&candidate);
            }
            cursor = if (end != null) end + 1 else null;
        }
    }
    for (places) |place| {
        if (rw_is_program(place) != 0) return web.rw_strdup(place);
    }
    return null;
}

fn rw_temp_folder() callconv(.c) [*c]u8 {
    var base: [*c]const u8 = libc.getenv("TMPDIR");
    var path: [PATH_MAX]u8 = undefined;
    if (base == null or base[0] == 0) base = "/tmp";
    _ = libc.snprintf(&path, path.len, "%s/raven-web-XXXXXX", base);
    return if (mkdtemp(&path) != null) web.rw_strdup(&path) else null;
}

fn rw_remove_folder(path: [*c]const u8) callconv(.c) void {
    if (path == null or path[0] == 0) return;
    const folder = libc.opendir(@ptrCast(path));
    if (folder) |dir| {
        while (libc.readdir(dir)) |entry| {
            var child: [PATH_MAX]u8 = undefined;
            var info: u32 = 0; // struct stat info;   (its st_mode)
            const name: [*c]const u8 = @ptrCast(&entry.name);
            if (libc.strcmp(name, ".") == 0 or libc.strcmp(name, "..") == 0) continue;
            if (@as(usize, @bitCast(@as(isize, libc.snprintf(&child, child.len, "%s/%s", path, name)))) >= child.len) continue;
            // (links are removed, never followed)
            if (statMode(&child, false, &info) == 0 and S_ISDIR(info)) {
                rw_remove_folder(&child);
            } else {
                _ = unlink(&child);
            }
        }
        _ = libc.closedir(dir);
    }
    _ = rmdir(path);
}

fn rw_file_url(path: [*c]const u8) callconv(.c) [*c]u8 {
    var absolute: [PATH_MAX]u8 = undefined;
    var url: web.rw_text_t = undefined;
    if (path == null) return null;
    if (realpath(path, &absolute) == null) {
        // a file that is not there: the browser will say so
        if (path[0] == '/') {
            _ = libc.snprintf(&absolute, absolute.len, "%s", path);
        } else {
            var folder: [PATH_MAX]u8 = undefined;
            if (libc.getcwd(&folder, folder.len) == null) folder[0] = 0;
            if (@as(usize, @bitCast(@as(isize, libc.snprintf(&absolute, absolute.len, "%s/%s", &folder, path)))) >= absolute.len) return null;
        }
    }
    url = std.mem.zeroes(web.rw_text_t);
    web.rw_text_puts(&url, "file://");
    var cursor: [*c]const u8 = &absolute;
    while (cursor.* != 0) : (cursor += 1) {
        const ch = cursor.*;
        if ((ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or libc.strchr("/-_.~", ch) != null) {
            web.rw_text_add(&url, &ch, 1);
        } else {
            web.rw_text_printf(&url, "%%%02X", @as(c_uint, ch));
        }
    }
    return url.data;
}

fn rw_needs_no_sandbox() callconv(.c) c_int {
    return @intFromBool(geteuid() == 0);
}
