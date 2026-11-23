// Translated to Zig from vendor/raven/src/core/fs_watch.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/fs_watch.c
// Native file-change notifications for Windows, macOS and Linux.
//
// The OS monitors containing directories rather than repeatedly calling stat
// on every file. A directory event is narrowed back to the paths Raven has
// registered; consumers compare stamps only after a notification arrives.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base_h = @import("base_h.zig");
const fs_h = @import("fs_h.zig");
const thread_h = @import("thread_h.zig");
const fs_watch_h = @import("fs_watch_h.zig");
const libc = @import("../sys/libc.zig");

// #if defined(_WIN32) / __APPLE__ / __linux__: comptime flags, the dead branches are not analysed.
const is_windows = builtin.os.tag == .windows;
const is_apple = builtin.os.tag.isDarwin();
const is_linux = builtin.os.tag == .linux;

// ---------------------------------------------------------------------------
//  Windows API (windows.h), declared by hand. Handles are optional pointers.
// ---------------------------------------------------------------------------

const HANDLE = *anyopaque;
const DWORD = u32;
const WCHAR = u16;
const BOOL = c_int;
// typedef struct _OVERLAPPED { ULONG_PTR Internal; ULONG_PTR InternalHigh;
//     union { struct { DWORD Offset; DWORD OffsetHigh; }; PVOID Pointer; };  HANDLE hEvent; } OVERLAPPED;
const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    DUMMYUNIONNAME: extern union {
        s: extern struct { Offset: DWORD, OffsetHigh: DWORD },
        Pointer: ?*anyopaque,
    },
    hEvent: ?HANDLE,
};
const CP_UTF8: u32 = 65001;
const TRUE: BOOL = 1;
const FALSE: BOOL = 0;
const ERROR_IO_PENDING: DWORD = 997;
const WAIT_OBJECT_0: DWORD = 0;
const INFINITE: DWORD = 0xFFFFFFFF;
const FILE_LIST_DIRECTORY: DWORD = 0x00000001;
const FILE_SHARE_READ: DWORD = 0x00000001;
const FILE_SHARE_WRITE: DWORD = 0x00000002;
const FILE_SHARE_DELETE: DWORD = 0x00000004;
const OPEN_EXISTING: DWORD = 3;
const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;
const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x00000001;
const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x00000002;
const FILE_NOTIFY_CHANGE_ATTRIBUTES: DWORD = 0x00000004;
const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x00000008;
const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x00000010;

extern "kernel32" fn MultiByteToWideChar(code_page: u32, flags: DWORD, text: [*c]const u8, text_len: c_int, wide: [*c]WCHAR, wide_len: c_int) callconv(.winapi) c_int;
extern "kernel32" fn CreateFileW(name: [*c]const WCHAR, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: [*c]const WCHAR) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(handle: ?HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SetEvent(handle: ?HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResetEvent(handle: ?HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn WaitForMultipleObjects(count: DWORD, handles: [*]const ?HANDLE, wait_all: BOOL, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CancelIoEx(handle: ?HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
extern "kernel32" fn GetOverlappedResult(handle: ?HANDLE, overlapped: *OVERLAPPED, transferred: *DWORD, wait: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn ReadDirectoryChangesW(directory: ?HANDLE, buffer: ?*anyopaque, buffer_len: DWORD, watch_subtree: BOOL, filter: DWORD, bytes_returned: ?*DWORD, overlapped: ?*OVERLAPPED, completion: ?*anyopaque) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
//  Apple kqueue (sys/event.h, fcntl.h), declared by hand where std.c lacks them.
// ---------------------------------------------------------------------------

extern "c" fn kevent(kq: c_int, changelist: ?*const std.c.Kevent, nchanges: c_int, eventlist: ?*std.c.Kevent, nevents: c_int, timeout: ?*const std.c.timespec) c_int;

// EV_SET(kev, ident, filter, flags, fflags, data, udata) as a function.
inline fn EV_SET(kev: *std.c.Kevent, ident: usize, filter: i16, flags: u16, fflags: u32, data: isize, udata: ?*anyopaque) void {
    kev.* = .{
        .ident = ident,
        .filter = filter,
        .flags = flags,
        .fflags = fflags,
        .data = data,
        .udata = @intFromPtr(udata),
    };
}

const O_EVTONLY: c_int = 0x00008000;
const EVFILT_VNODE: i16 = -4;
const EVFILT_USER: i16 = -10;
const NOTE_DELETE: u32 = 0x00000001;
const NOTE_WRITE: u32 = 0x00000002;
const NOTE_EXTEND: u32 = 0x00000004;
const NOTE_ATTRIB: u32 = 0x00000008;
const NOTE_RENAME: u32 = 0x00000020;
const NOTE_TRIGGER: u32 = 0x01000000;

// Linux inotify: glibc entry points are declared by std.c; the event record is std.os.linux.inotify_event.

// typedef struct rvn_fs_watch_path_t {
//     char* path;
//     char* directory;
//     struct rvn_fs_watch_path_t* next;
// } rvn_fs_watch_path_t;
const rvn_fs_watch_path_t = struct {
    path: [*c]u8,
    directory: [*c]u8,
    next: [*c]rvn_fs_watch_path_t,
};

// typedef struct rvn_fs_watch_dir_t {
//     /* path is the directory whose registered files must be checked. On macOS,
//        watch_path is either that directory or one watched file within it. */
//     char* path;
//     ...
//     struct rvn_fs_watch_dir_t* next;
// } rvn_fs_watch_dir_t;
const rvn_fs_watch_dir_t = struct {
    // path is the directory whose registered files must be checked. On macOS,
    // watch_path is either that directory or one watched file within it.
    path: [*c]u8,
    watch_path: if (is_apple) [*c]u8 else void,
    is_file_watch: if (is_apple) c_int else void,
    handle: if (is_windows) ?HANDLE else void,
    event: if (is_windows) ?HANDLE else if (is_apple) std.c.Kevent else void,
    stop_event: if (is_windows) ?HANDLE else void,
    overlapped: if (is_windows) OVERLAPPED else void,
    buffer: if (is_windows) [8192]u8 else void,
    thread: if (is_windows) thread_h.rvn_thread_t else void,
    thread_started: if (is_windows) c_int else void,
    fd: if (is_apple) c_int else void,
    descriptor: if (is_linux) c_int else void,
    next: [*c]rvn_fs_watch_dir_t,
};

// static struct { ... } g_fs_watch;   (zero-initialized)
const rvn_fs_watch_state_t = struct {
    mutex: thread_h.rvn_mutex_t,
    mutex_ready: c_int,
    started: c_int,
    stopping: c_int,
    callback: fs_watch_h.rvn_fs_watch_callback_t,
    user: ?*anyopaque,
    paths: [*c]rvn_fs_watch_path_t,
    directories: [*c]rvn_fs_watch_dir_t,
    queue_fd: if (is_apple) c_int else void,
    thread: if (is_apple or is_linux) thread_h.rvn_thread_t else void,
    inotify_fd: if (is_linux) c_int else void,
};

var g_fs_watch: rvn_fs_watch_state_t = std.mem.zeroes(rvn_fs_watch_state_t);

// The C buffer `uint8_t buffer[16384];` is a local of rvn_fs_watch_thread. It is file-scope here: a 16 KiB
// stack frame makes Zig emit a call to __zig_probe_stack, which the C link of libraven.a does not provide.
// Only one invocation runs at a time (start creates the single thread, stop joins it), so the storage is
// used exactly as the C uses it. The buffer is aligned for inotify_event, which is read through a pointer.
var linux_thread_buffer: [16384]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;

// static void rvn_fs_watch_mac_rearm_files(const char* directory)
fn rvn_fs_watch_mac_rearm_files(directory: [*c]const u8) void {
    var item: [*c]rvn_fs_watch_dir_t = undefined;
    thread_h.rvn_mutex_lock(&g_fs_watch.mutex);
    item = g_fs_watch.directories;
    while (item != null) : (item = item.*.next) {
        var change: std.c.Kevent = undefined;
        if (item.*.is_file_watch == 0 or item.*.fd >= 0 or libc.strcmp(item.*.path, directory) != 0) continue;
        const fd: c_int = libc.open(item.*.watch_path, O_EVTONLY);
        if (fd < 0) continue;
        EV_SET(&change, @as(usize, @intCast(fd)), EVFILT_VNODE, std.c.EV.ADD | std.c.EV.CLEAR, NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND, 0, item);
        if (kevent(g_fs_watch.queue_fd, &change, 1, null, 0, null) == 0) {
            item.*.fd = fd;
        } else {
            _ = libc.close(fd);
        }
    }
    thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
}

// static void rvn_fs_watch_notify_directory(const char* directory)
fn rvn_fs_watch_notify_directory(directory: [*c]const u8) void {
    var item: [*c]rvn_fs_watch_path_t = undefined;
    var paths: [*c][*c]u8 = null;
    var count: u32 = 0;
    var cap: u32 = 0;
    var i: u32 = 0;
    var callback: fs_watch_h.rvn_fs_watch_callback_t = undefined;
    var user: ?*anyopaque = undefined;

    if (g_fs_watch.started == 0 or g_fs_watch.stopping != 0) return;
    thread_h.rvn_mutex_lock(&g_fs_watch.mutex);
    callback = g_fs_watch.callback;
    user = g_fs_watch.user;
    item = g_fs_watch.paths;
    while (item != null) : (item = item.*.next) {
        if (libc.strcmp(item.*.directory, directory) != 0) continue;
        // RVN_ARRAY_RESERVE(paths, cap, count + 1) expanded here: base_h's macro cannot take a char** data pointer.
        if (count + 1 > cap) paths = @ptrCast(@alignCast(base_h.rvn_array_grow_(@ptrCast(paths), &cap, count + 1, @sizeOf([*c]u8))));
        paths[count] = base_h.rvn_strdup(item.*.path);
        count += 1;
    }
    thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);

    while (i < count) : (i += 1) {
        if (callback) |cb| cb(paths[i], user);
        base_h.rvn_free(paths[i]);
    }
    base_h.rvn_free(@ptrCast(paths));
}

// static WCHAR* rvn_fs_watch_wide(const char* text)
fn rvn_fs_watch_wide(text: [*c]const u8) [*c]WCHAR {
    const n = MultiByteToWideChar(CP_UTF8, 0, text, -1, null, 0);
    var result: [*c]WCHAR = undefined;
    if (n <= 0) return null;
    result = @ptrCast(@alignCast(base_h.rvn_alloc(@sizeOf(WCHAR) * @as(usize, @intCast(n)))));
    if (MultiByteToWideChar(CP_UTF8, 0, text, -1, result, n) <= 0) {
        base_h.rvn_free(result);
        return null;
    }
    return result;
}

// static void rvn_fs_watch_directory_thread(void* arg)
fn rvn_fs_watch_directory_thread(arg: ?*anyopaque) callconv(.c) void {
    const dir: [*c]rvn_fs_watch_dir_t = @ptrCast(@alignCast(arg));
    while (true) {
        var ignored: DWORD = 0;
        var ok: BOOL = undefined;
        var waits: [2]?HANDLE = undefined;
        if (g_fs_watch.stopping != 0) break;
        dir.*.overlapped = std.mem.zeroes(OVERLAPPED);
        dir.*.overlapped.hEvent = dir.*.event;
        _ = ResetEvent(dir.*.event);
        ok = ReadDirectoryChangesW(dir.*.handle, &dir.*.buffer, @sizeOf(@TypeOf(dir.*.buffer)), FALSE, FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_ATTRIBUTES, &ignored, &dir.*.overlapped, null);
        if (ok == FALSE and GetLastError() != ERROR_IO_PENDING) break;
        waits[0] = dir.*.stop_event;
        waits[1] = dir.*.event;
        if (WaitForMultipleObjects(2, &waits, FALSE, INFINITE) == WAIT_OBJECT_0) {
            _ = CancelIoEx(dir.*.handle, &dir.*.overlapped);
            break;
        }
        if (GetOverlappedResult(dir.*.handle, &dir.*.overlapped, &ignored, FALSE) != FALSE) {
            // We watch a directory, then validate the specific file's stamp on the UI thread.
            rvn_fs_watch_notify_directory(dir.*.path);
        }
    }
}

// Windows: rvn_fs_watch_thread is not defined (one thread per directory). Apple and Linux: one shared thread.
// The #else branch (other POSIX systems) is an empty function that is never started.
fn rvn_fs_watch_thread(unused: ?*anyopaque) callconv(.c) void {
    _ = unused;
    if (is_apple) {
        while (g_fs_watch.stopping == 0) {
            var events: [16]std.c.Kevent = undefined;
            var timeout: std.c.timespec = undefined;
            var n: c_int = undefined;
            var i: c_int = undefined;
            timeout.sec = 0;
            timeout.nsec = 250000000;
            n = kevent(g_fs_watch.queue_fd, null, 0, &events[0], @intCast(events.len), &timeout);
            if (n < 0) {
                if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                break;
            }
            i = 0;
            while (i < n and g_fs_watch.stopping == 0) : (i += 1) {
                const idx: usize = @intCast(i);
                const dir: [*c]rvn_fs_watch_dir_t = @ptrFromInt(events[idx].udata);
                if (dir == null or (events[idx].fflags & (NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND)) == 0) continue;
                if (dir.*.is_file_watch != 0 and (events[idx].fflags & (NOTE_DELETE | NOTE_RENAME)) != 0) {
                    // Drop the old inode watch; the parent directory event will
                    // re-arm it once the replacement file becomes visible.
                    if (dir.*.fd >= 0) _ = libc.close(dir.*.fd);
                    dir.*.fd = -1;
                }
                rvn_fs_watch_notify_directory(dir.*.path);
                if (dir.*.is_file_watch == 0) rvn_fs_watch_mac_rearm_files(dir.*.path);
            }
        }
    } else if (is_linux) {
        while (g_fs_watch.stopping == 0) {
            var pfd: std.c.pollfd = undefined;
            var ready: c_int = undefined;
            pfd.fd = g_fs_watch.inotify_fd;
            pfd.events = std.c.POLL.IN;
            pfd.revents = 0;
            ready = libc.poll(&pfd, 1, 250);
            if (ready < 0) {
                if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                break;
            }
            if (ready == 0 or (pfd.revents & std.c.POLL.IN) == 0) continue;
            while (true) {
                const bytes: isize = libc.read(g_fs_watch.inotify_fd, &linux_thread_buffer, linux_thread_buffer.len);
                var offset: usize = 0;
                if (bytes < 0) {
                    if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                    break;
                }
                if (bytes == 0) break;
                while (offset < @as(usize, @intCast(bytes))) {
                    const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(linux_thread_buffer[offset..].ptr));
                    var dir: [*c]rvn_fs_watch_dir_t = undefined;
                    var directory: [*c]u8 = null;
                    thread_h.rvn_mutex_lock(&g_fs_watch.mutex);
                    dir = g_fs_watch.directories;
                    while (dir != null) : (dir = dir.*.next) {
                        if (dir.*.descriptor == event.wd) {
                            directory = base_h.rvn_strdup(dir.*.path);
                            break;
                        }
                    }
                    thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
                    if (directory != null) {
                        rvn_fs_watch_notify_directory(directory);
                        base_h.rvn_free(directory);
                    }
                    offset += @sizeOf(std.os.linux.inotify_event) + event.len;
                }
                break;
            }
        }
    }
}

// int rvn_fs_watch_start(rvn_fs_watch_callback_t callback, void* user)
export fn rvn_fs_watch_start(callback: fs_watch_h.rvn_fs_watch_callback_t, user: ?*anyopaque) c_int {
    if (callback == null) return raven.R_FALSE;
    if (g_fs_watch.started != 0) {
        g_fs_watch.callback = callback;
        g_fs_watch.user = user;
        return raven.R_TRUE;
    }
    g_fs_watch = std.mem.zeroes(rvn_fs_watch_state_t);
    thread_h.rvn_mutex_init(&g_fs_watch.mutex);
    g_fs_watch.mutex_ready = raven.R_TRUE;
    g_fs_watch.callback = callback;
    g_fs_watch.user = user;
    if (is_linux) {
        g_fs_watch.inotify_fd = std.c.inotify_init1(std.os.linux.IN.CLOEXEC | std.os.linux.IN.NONBLOCK);
        if (g_fs_watch.inotify_fd < 0) {
            thread_h.rvn_mutex_destroy(&g_fs_watch.mutex);
            g_fs_watch = std.mem.zeroes(rvn_fs_watch_state_t);
            return raven.R_FALSE;
        }
        if (thread_h.rvn_thread_create(&g_fs_watch.thread, rvn_fs_watch_thread, null, "raven-fs-watch") == 0) {
            _ = libc.close(g_fs_watch.inotify_fd);
            thread_h.rvn_mutex_destroy(&g_fs_watch.mutex);
            g_fs_watch = std.mem.zeroes(rvn_fs_watch_state_t);
            return raven.R_FALSE;
        }
    } else if (is_apple) {
        g_fs_watch.queue_fd = std.c.kqueue();
        if (g_fs_watch.queue_fd < 0 or thread_h.rvn_thread_create(&g_fs_watch.thread, rvn_fs_watch_thread, null, "raven-fs-watch") == 0) {
            if (g_fs_watch.queue_fd >= 0) _ = libc.close(g_fs_watch.queue_fd);
            thread_h.rvn_mutex_destroy(&g_fs_watch.mutex);
            g_fs_watch = std.mem.zeroes(rvn_fs_watch_state_t);
            return raven.R_FALSE;
        }
    }
    if (!is_windows and !is_apple and !is_linux) {
        // Not every POSIX OS has inotify or Apple's vnode extensions. Tell the
        // caller to use its compatibility fallback instead of silently missing changes.
        thread_h.rvn_mutex_destroy(&g_fs_watch.mutex);
        g_fs_watch = std.mem.zeroes(rvn_fs_watch_state_t);
        return raven.R_FALSE;
    }
    g_fs_watch.started = raven.R_TRUE;
    return raven.R_TRUE;
}

// int rvn_fs_watch_add(const char* path)
export fn rvn_fs_watch_add(path: [*c]const u8) c_int {
    var item: [*c]rvn_fs_watch_path_t = undefined;
    var dir: [*c]rvn_fs_watch_dir_t = undefined;
    if (path == null or path[0] == 0 or g_fs_watch.started == 0 or g_fs_watch.stopping != 0) return raven.R_FALSE;
    const absolute: [*c]u8 = fs_h.rvn_path_absolute(path);
    if (absolute == null) return raven.R_FALSE;
    var directory: [*c]u8 = fs_h.rvn_path_parent(absolute);
    if (directory == null) directory = base_h.rvn_strdup(absolute);

    thread_h.rvn_mutex_lock(&g_fs_watch.mutex);
    item = g_fs_watch.paths;
    while (item != null) : (item = item.*.next) {
        if (libc.strcmp(item.*.path, absolute) == 0) {
            thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
            base_h.rvn_free(directory);
            base_h.rvn_free(absolute);
            return raven.R_TRUE;
        }
    }
    dir = g_fs_watch.directories;
    while (dir != null) : (dir = dir.*.next) {
        if (is_apple) {
            if (dir.*.is_file_watch != 0) continue;
        }
        if (libc.strcmp(dir.*.path, directory) == 0) break;
    }
    if (dir == null) {
        dir = @ptrCast(@alignCast(base_h.rvn_calloc(@sizeOf(rvn_fs_watch_dir_t))));
        dir.*.path = base_h.rvn_strdup(directory);
        if (is_apple) {
            dir.*.watch_path = base_h.rvn_strdup(directory);
        }
        if (is_windows) {
            const wide = rvn_fs_watch_wide(directory);
            if (wide != null) {
                dir.*.handle = CreateFileW(wide, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, null);
                base_h.rvn_free(wide);
            } else {
                dir.*.handle = std.os.windows.INVALID_HANDLE_VALUE;
            }
            dir.*.event = CreateEventW(null, TRUE, FALSE, null);
            dir.*.stop_event = CreateEventW(null, TRUE, FALSE, null);
            if (dir.*.handle == std.os.windows.INVALID_HANDLE_VALUE or dir.*.event == null or dir.*.stop_event == null) {
                if (dir.*.handle != std.os.windows.INVALID_HANDLE_VALUE and dir.*.handle != null) _ = CloseHandle(dir.*.handle);
                if (dir.*.event != null) _ = CloseHandle(dir.*.event);
                if (dir.*.stop_event != null) _ = CloseHandle(dir.*.stop_event);
                base_h.rvn_free(dir.*.path);
                base_h.rvn_free(dir);
                thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
                base_h.rvn_free(directory);
                base_h.rvn_free(absolute);
                return raven.R_FALSE;
            }
        } else if (is_apple) {
            dir.*.fd = libc.open(directory, O_EVTONLY);
            if (dir.*.fd < 0) {
                base_h.rvn_free(dir.*.watch_path);
                base_h.rvn_free(dir.*.path);
                base_h.rvn_free(dir);
                thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
                base_h.rvn_free(directory);
                base_h.rvn_free(absolute);
                return raven.R_FALSE;
            }
            var change: std.c.Kevent = undefined;
            EV_SET(&change, @as(usize, @intCast(dir.*.fd)), EVFILT_VNODE, std.c.EV.ADD | std.c.EV.CLEAR, NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND, 0, dir);
            if (kevent(g_fs_watch.queue_fd, &change, 1, null, 0, null) != 0) {
                _ = libc.close(dir.*.fd);
                base_h.rvn_free(dir.*.watch_path);
                base_h.rvn_free(dir.*.path);
                base_h.rvn_free(dir);
                thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
                base_h.rvn_free(directory);
                base_h.rvn_free(absolute);
                return raven.R_FALSE;
            }
        } else if (is_linux) {
            dir.*.descriptor = std.c.inotify_add_watch(g_fs_watch.inotify_fd, directory, std.os.linux.IN.CLOSE_WRITE | std.os.linux.IN.MODIFY | std.os.linux.IN.ATTRIB | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE | std.os.linux.IN.MOVED_FROM | std.os.linux.IN.MOVED_TO | std.os.linux.IN.DELETE_SELF | std.os.linux.IN.MOVE_SELF);
            if (dir.*.descriptor < 0) {
                base_h.rvn_free(dir.*.path);
                base_h.rvn_free(dir);
                thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
                base_h.rvn_free(directory);
                base_h.rvn_free(absolute);
                return raven.R_FALSE;
            }
        }
        dir.*.next = g_fs_watch.directories;
        g_fs_watch.directories = dir;
        if (is_windows) {
            if (thread_h.rvn_thread_create(&dir.*.thread, rvn_fs_watch_directory_thread, dir, "raven-fs-watch") == 0) {
                g_fs_watch.directories = dir.*.next;
                _ = CloseHandle(dir.*.handle);
                _ = CloseHandle(dir.*.event);
                _ = CloseHandle(dir.*.stop_event);
                base_h.rvn_free(dir.*.path);
                base_h.rvn_free(dir);
                thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
                base_h.rvn_free(directory);
                base_h.rvn_free(absolute);
                return raven.R_FALSE;
            }
            dir.*.thread_started = raven.R_TRUE;
        }
    }
    if (is_apple) {
        // Watch the file vnode too: writes to file contents need not change the
        // containing directory. Keep the directory vnode to catch atomic replaces.
        var found_file: c_int = raven.R_FALSE;
        dir = g_fs_watch.directories;
        while (dir != null) : (dir = dir.*.next) {
            if (dir.*.is_file_watch != 0 and libc.strcmp(dir.*.watch_path, absolute) == 0) {
                found_file = raven.R_TRUE;
                break;
            }
        }
        if (found_file == 0) {
            const file_watch: [*c]rvn_fs_watch_dir_t = @ptrCast(@alignCast(base_h.rvn_calloc(@sizeOf(rvn_fs_watch_dir_t))));
            file_watch.*.path = base_h.rvn_strdup(directory);
            file_watch.*.watch_path = base_h.rvn_strdup(absolute);
            file_watch.*.is_file_watch = raven.R_TRUE;
            file_watch.*.fd = -1;
            {
                const file_fd: c_int = libc.open(absolute, O_EVTONLY);
                if (file_fd >= 0) {
                    var change: std.c.Kevent = undefined;
                    EV_SET(&change, @as(usize, @intCast(file_fd)), EVFILT_VNODE, std.c.EV.ADD | std.c.EV.CLEAR, NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB | NOTE_EXTEND, 0, file_watch);
                    if (kevent(g_fs_watch.queue_fd, &change, 1, null, 0, null) == 0) {
                        file_watch.*.fd = file_fd;
                    } else {
                        _ = libc.close(file_fd);
                    }
                }
                // Keep even an unarmed vnode entry. The parent directory watch
                // can re-arm it when a missing file is created or atomically replaced.
                file_watch.*.next = g_fs_watch.directories;
                g_fs_watch.directories = file_watch;
            }
        }
    }
    item = @ptrCast(@alignCast(base_h.rvn_calloc(@sizeOf(rvn_fs_watch_path_t))));
    item.*.path = absolute;
    item.*.directory = directory;
    item.*.next = g_fs_watch.paths;
    g_fs_watch.paths = item;
    thread_h.rvn_mutex_unlock(&g_fs_watch.mutex);
    return raven.R_TRUE;
}

// void rvn_fs_watch_stop(void)
export fn rvn_fs_watch_stop() void {
    var path: [*c]rvn_fs_watch_path_t = undefined;
    var dir: [*c]rvn_fs_watch_dir_t = undefined;
    if (g_fs_watch.started == 0 and g_fs_watch.mutex_ready == 0) return;
    g_fs_watch.stopping = raven.R_TRUE;
    if (is_windows) {
        dir = g_fs_watch.directories;
        while (dir != null) : (dir = dir.*.next) {
            _ = SetEvent(dir.*.stop_event);
        }
        dir = g_fs_watch.directories;
        while (dir != null) : (dir = dir.*.next) {
            if (dir.*.thread_started != 0) thread_h.rvn_thread_join(&dir.*.thread);
        }
    } else if (is_apple) {
        if (g_fs_watch.queue_fd >= 0) {
            var wake_event: std.c.Kevent = undefined;
            EV_SET(&wake_event, 1, EVFILT_USER, std.c.EV.ADD | std.c.EV.ENABLE, 0, 0, null);
            _ = kevent(g_fs_watch.queue_fd, &wake_event, 1, null, 0, null);
            EV_SET(&wake_event, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0, null);
            _ = kevent(g_fs_watch.queue_fd, &wake_event, 1, null, 0, null);
        }
        if (g_fs_watch.started != 0) thread_h.rvn_thread_join(&g_fs_watch.thread);
    } else if (is_linux) {
        if (g_fs_watch.inotify_fd >= 0) _ = libc.close(g_fs_watch.inotify_fd);
        if (g_fs_watch.started != 0) thread_h.rvn_thread_join(&g_fs_watch.thread);
    }
    path = g_fs_watch.paths;
    while (path != null) {
        const next = path.*.next;
        base_h.rvn_free(path.*.path);
        base_h.rvn_free(path.*.directory);
        base_h.rvn_free(path);
        path = next;
    }
    dir = g_fs_watch.directories;
    while (dir != null) {
        const next = dir.*.next;
        if (is_windows) {
            if (dir.*.handle != null and dir.*.handle != std.os.windows.INVALID_HANDLE_VALUE) _ = CloseHandle(dir.*.handle);
            if (dir.*.event != null) _ = CloseHandle(dir.*.event);
            if (dir.*.stop_event != null) _ = CloseHandle(dir.*.stop_event);
        } else if (is_apple) {
            if (dir.*.fd >= 0) _ = libc.close(dir.*.fd);
            base_h.rvn_free(dir.*.watch_path);
        } else if (is_linux) {
            // All inotify descriptors belong to the shared fd, closed above.
            _ = dir.*.descriptor;
        }
        base_h.rvn_free(dir.*.path);
        base_h.rvn_free(dir);
        dir = next;
    }
    if (is_apple) {
        if (g_fs_watch.queue_fd >= 0) _ = libc.close(g_fs_watch.queue_fd);
    }
    if (g_fs_watch.mutex_ready != 0) thread_h.rvn_mutex_destroy(&g_fs_watch.mutex);
    g_fs_watch = std.mem.zeroes(rvn_fs_watch_state_t);
}
