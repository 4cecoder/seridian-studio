// Translated to Zig from vendor/raven/tools/designer/os.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Designer - os.c
// Folders, files and programs, for Windows and for POSIX systems. Paths are
// UTF-8; on Windows they go through the wide functions.

// #if !defined(_WIN32)  #define _POSIX_C_SOURCE 200809L  #define _DEFAULT_SOURCE  #endif

const std = @import("std");
const builtin = @import("builtin");
const ide = @import("ide_h.zig");
const libc = @import("../sys/libc.zig");

// ---------------------------------------------------------------------------
//  Win32 declarations (windows.h): used only in the Windows branches, which
//  are not analysed on other systems.
// ---------------------------------------------------------------------------

const WCHAR = u16;
const WORD = u16;
const DWORD = u32;
const BOOL = c_int;
const UINT = c_uint;
const HANDLE = ?*anyopaque;
const TRUE: BOOL = 1;
const CP_UTF8: UINT = 65001;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
const GetFileExInfoStandard: c_int = 0;
const HANDLE_FLAG_INHERIT: DWORD = 0x1;
const GENERIC_READ: DWORD = 0x80000000;
const FILE_SHARE_READ: DWORD = 0x1;
const FILE_SHARE_WRITE: DWORD = 0x2;
const OPEN_EXISTING: DWORD = 3;
const STARTF_USESTDHANDLES: DWORD = 0x100;
const CREATE_NO_WINDOW: DWORD = 0x08000000;
const WAIT_OBJECT_0: DWORD = 0;

const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]WCHAR,
    cAlternateFileName: [14]WCHAR,
};

const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
};

const ULARGE_INTEGER = extern union {
    u: extern struct {
        LowPart: DWORD,
        HighPart: DWORD,
    },
    QuadPart: u64,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: [*c]WCHAR,
    lpDesktop: [*c]WCHAR,
    lpTitle: [*c]WCHAR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: [*c]u8,
    hStdInput: HANDLE,
    hStdOutput: HANDLE,
    hStdError: HANDLE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

extern "kernel32" fn MultiByteToWideChar(CodePage: UINT, dwFlags: DWORD, lpMultiByteStr: [*c]const u8, cbMultiByte: c_int, lpWideCharStr: [*c]WCHAR, cchWideChar: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(CodePage: UINT, dwFlags: DWORD, lpWideCharStr: [*c]const WCHAR, cchWideChar: c_int, lpMultiByteStr: [*c]u8, cbMultiByte: c_int, lpDefaultChar: [*c]const u8, lpUsedDefaultChar: [*c]BOOL) callconv(.winapi) c_int;
extern "kernel32" fn FindFirstFileW(lpFileName: [*c]const WCHAR, lpFindFileData: [*c]WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: [*c]WIN32_FIND_DATAW) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*c]const WCHAR) callconv(.winapi) DWORD;
extern "kernel32" fn GetFileAttributesExW(lpFileName: [*c]const WCHAR, fInfoLevelId: c_int, lpFileInformation: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CreateDirectoryW(lpPathName: [*c]const WCHAR, lpSecurityAttributes: [*c]SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*c]WCHAR, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CreatePipe(hReadPipe: [*c]HANDLE, hWritePipe: [*c]HANDLE, lpPipeAttributes: [*c]SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(lpFileName: [*c]const WCHAR, dwDesiredAccess: DWORD, dwShareMode: DWORD, lpSecurityAttributes: [*c]SECURITY_ATTRIBUTES, dwCreationDisposition: DWORD, dwFlagsAndAttributes: DWORD, hTemplateFile: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn CreateProcessW(lpApplicationName: [*c]const WCHAR, lpCommandLine: [*c]WCHAR, lpProcessAttributes: [*c]SECURITY_ATTRIBUTES, lpThreadAttributes: [*c]SECURITY_ATTRIBUTES, bInheritHandles: BOOL, dwCreationFlags: DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: [*c]const WCHAR, lpStartupInfo: [*c]STARTUPINFOW, lpProcessInformation: [*c]PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?*anyopaque, nBufferSize: DWORD, lpBytesRead: [*c]DWORD, lpTotalBytesAvail: [*c]DWORD, lpBytesLeftThisMessage: [*c]DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: ?*anyopaque, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: [*c]DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: [*c]DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn SetEnvironmentVariableW(lpName: [*c]const WCHAR, lpValue: [*c]const WCHAR) callconv(.winapi) BOOL;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*c]const WCHAR, lpBuffer: [*c]WCHAR, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn SearchPathW(lpPath: [*c]const WCHAR, lpFileName: [*c]const WCHAR, lpExtension: [*c]const WCHAR, nBufferLength: DWORD, lpBuffer: [*c]WCHAR, lpFilePart: [*c][*c]WCHAR) callconv(.winapi) DWORD;
extern "kernel32" fn DeleteFileW(lpFileName: [*c]const WCHAR) callconv(.winapi) BOOL;
extern "c" fn wcsstr(haystack: [*c]const WCHAR, needle: [*c]const WCHAR) [*c]WCHAR;
extern "c" fn wcslen(s: [*c]const WCHAR) usize;
extern "c" fn swprintf(buffer: [*c]WCHAR, count: usize, format: [*c]const WCHAR, ...) c_int;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

// ---------------------------------------------------------------------------
//  POSIX declarations (unistd.h, fcntl.h, signal.h, sys/wait.h, errno.h,
//  stdlib.h, stdio.h, string.h, mach-o/dyld.h): the POSIX branches only.
// ---------------------------------------------------------------------------

extern "c" fn strpbrk(s: [*c]const u8, accept: [*c]const u8) [*c]u8;
extern "c" fn strerror(errnum: c_int) [*c]u8;
extern "c" fn fprintf(stream: ?*libc.FILE, format: [*c]const u8, ...) c_int;
extern "c" fn sprintf(str: [*c]u8, format: [*c]const u8, ...) c_int;
extern "c" fn setpgid(pid: c_int, pgid: c_int) c_int;
extern "c" fn chdir(path: [*c]const u8) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn setenv(name: [*c]const u8, value: [*c]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*c]const u8) c_int;
extern "c" fn readlink(path: [*c]const u8, buf: [*c]u8, bufsiz: usize) isize;
extern "c" fn unlink(path: [*c]const u8) c_int;
extern "c" fn _NSGetExecutablePath(buf: [*c]u8, bufsize: [*c]u32) c_int;

const O_RDONLY: c_int = 0;
const O_NONBLOCK: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const WNOHANG: c_int = 1;
const SIGKILL: c_int = 9;
const SIGTERM: c_int = 15;
const X_OK: c_int = 1;
const EINTR: c_int = @backingInt(std.c.E.INTR);
const EAGAIN: c_int = @backingInt(std.c.E.AGAIN);
/// (EWOULDBLOCK is EAGAIN on Linux and macOS)
const EWOULDBLOCK: c_int = EAGAIN;

fn errnoValue() c_int {
    return std.c._errno().*;
}

// POSIX status macros (sys/wait.h), same values on Linux and macOS.
fn WIFEXITED(status: c_int) bool {
    return (status & 0x7f) == 0;
}
fn WEXITSTATUS(status: c_int) c_int {
    return (status >> 8) & 0xff;
}
fn WIFSIGNALED(status: c_int) bool {
    return (status & 0x7f) != 0 and (status & 0x7f) != 0x7f;
}
fn WTERMSIG(status: c_int) c_int {
    return status & 0x7f;
}

/// The fields of `struct stat` that this file reads: st_mode, st_mtime.
const StatInfo = struct {
    mode: u32,
    mtime_sec: i64,
};

/// S_ISDIR(mode)
fn S_ISDIR(mode: u32) bool {
    return (mode & std.c.S.IFMT) == std.c.S.IFDIR;
}

/// S_ISREG(mode)
fn S_ISREG(mode: u32) bool {
    return (mode & std.c.S.IFMT) == std.c.S.IFREG;
}

/// stat(path, &s). std.c has no `struct stat` on Linux (it goes through statx): there the same
/// data comes from statx(AT_FDCWD, path, 0, ...), which follows links as stat does.
fn statPath(path: [*c]const u8, info: *StatInfo) c_int {
    if (builtin.os.tag == .linux) {
        var buf: std.os.linux.Statx = undefined;
        const rc = std.c.statx(std.os.linux.AT.FDCWD, path, 0, std.os.linux.STATX.BASIC_STATS, &buf);
        if (rc != 0) return rc;
        info.* = .{
            .mode = buf.mode,
            .mtime_sec = buf.mtime.sec,
        };
        return 0;
    } else {
        var st: std.c.Stat = undefined;
        const rc = libc.stat(path, &st);
        if (rc != 0) return rc;
        const mtime = st.mtime();
        info.* = .{
            .mode = @as(u32, st.mode),
            .mtime_sec = @intCast(mtime.sec),
        };
        return 0;
    }
}

// ---------------------------------------------------------------------------
//  Small things
// ---------------------------------------------------------------------------

export fn ide_strdup(text: [*c]const u8) [*c]u8 {
    const length: usize = if (text != null) libc.strlen(text) else 0;
    const copy: [*c]u8 = @ptrCast(libc.malloc(length + 1));
    if (length != 0) _ = libc.memcpy(copy, text, length);
    copy[length] = 0;
    return copy;
}

export fn ide_iequal(a_: [*c]const u8, b_: [*c]const u8) c_int {
    var a = a_;
    var b = b_;
    if (a == null or b == null) return @intFromBool(a == b);
    while (a[0] != 0 and b[0] != 0) : ({
        a += 1;
        b += 1;
    }) if (std.ascii.toLower(a[0]) != std.ascii.toLower(b[0])) return 0;
    return @intFromBool(a[0] == b[0]);
}

export fn ide_buffer_add(buffer: [*c]ide.ide_buffer_t, text: [*c]const u8, length: usize) void {
    if (buffer.*.size + length + 1 > buffer.*.cap) {
        var cap: usize = if (buffer.*.cap != 0) buffer.*.cap * 2 else 1024;
        while (cap < buffer.*.size + length + 1) cap *= 2;
        buffer.*.data = @ptrCast(libc.realloc(buffer.*.data, cap));
        buffer.*.cap = cap;
    }
    if (length != 0) _ = libc.memcpy(buffer.*.data + buffer.*.size, text, length);
    buffer.*.size += length;
    buffer.*.data[buffer.*.size] = 0;
}

export fn ide_buffer_printf(buffer: [*c]ide.ide_buffer_t, format: [*c]const u8, ...) callconv(.c) void {
    var small: [2048]u8 = undefined;
    var args = @cVaStart(); // va_start(args, format);
    const n: c_int = libc.vsnprintf(&small, small.len, format, &args);
    @cVaEnd(&args); // va_end(args);
    if (n < 0) return;
    if (@as(usize, @intCast(n)) < small.len) {
        ide_buffer_add(buffer, &small, @intCast(n));
    } else {
        const big: [*c]u8 = @ptrCast(libc.malloc(@as(usize, @intCast(n)) + 1));
        args = @cVaStart(); // va_start(args, format);
        _ = libc.vsnprintf(big, @as(usize, @intCast(n)) + 1, format, &args);
        @cVaEnd(&args); // va_end(args);
        ide_buffer_add(buffer, big, @intCast(n));
        libc.free(big);
    }
}

export fn ide_buffer_free(buffer: [*c]ide.ide_buffer_t) void {
    libc.free(buffer.*.data);
    buffer.* = std.mem.zeroes(ide.ide_buffer_t);
}

const g_ide_languages = [_]ide.ide_language_t{
    .{ .extension = "xmlc", .name = "C", .editor = "C" },
    .{ .extension = "xmlc++", .name = "C++", .editor = "C++" },
    .{ .extension = "xmlcpp", .name = "C++", .editor = "C++" },
    .{ .extension = "xmlrs", .name = "Rust", .editor = "Rust" },
    .{ .extension = "xmlpy", .name = "Python", .editor = "Python" },
    .{ .extension = "xmlgo", .name = "Go", .editor = "Go" },
    .{ .extension = "xmlcs", .name = "C#", .editor = "C#" },
    .{ .extension = "xmlzig", .name = "Zig", .editor = "Zig" },
    .{ .extension = "xmllua", .name = "Lua", .editor = "Lua" },
};

export fn ide_interface_language(path: [*c]const u8) [*c]const ide.ide_language_t {
    const ext = ide_extension(path);
    var i: usize = 0;
    while (i < g_ide_languages.len) : (i += 1) {
        if (ide_iequal(ext, g_ide_languages[i].extension) != 0) return &g_ide_languages[i];
    }
    return null;
}

export fn ide_language_count() c_int {
    return @intCast(g_ide_languages.len);
}

export fn ide_language_at(index: c_int) [*c]const ide.ide_language_t {
    return if (index >= 0 and index < ide_language_count()) &g_ide_languages[@intCast(index)] else null;
}

export fn ide_normalize(path: [*c]const u8) [*c]u8 {
    const copy = ide_strdup(path);
    var p: [*c]u8 = copy;
    while (p[0] != 0) : (p += 1) if (p[0] == '\\') {
        p[0] = '/';
    };
    return copy;
}

export fn ide_join(a: [*c]const u8, b: [*c]const u8) [*c]u8 {
    var la: usize = libc.strlen(a);
    const lb: usize = libc.strlen(b);
    const out: [*c]u8 = @ptrCast(libc.malloc(la + lb + 2));
    _ = libc.memcpy(out, a, la);
    if (la != 0 and a[la - 1] != '/' and a[la - 1] != '\\') {
        out[la] = '/';
        la += 1;
    }
    _ = libc.memcpy(out + la, b, lb + 1);
    return out;
}

export fn ide_basename(path: [*c]const u8) [*c]const u8 {
    var base: [*c]const u8 = path;
    var p: [*c]const u8 = path;
    while (p[0] != 0) : (p += 1) if (p[0] == '/' or p[0] == '\\') {
        base = p + 1;
    };
    return base;
}

export fn ide_extension(path: [*c]const u8) [*c]const u8 {
    const S = struct {
        var ext: [16]u8 = std.mem.zeroes([16]u8);
    };
    const base = ide_basename(path);
    const dot: [*c]const u8 = libc.strrchr(base, '.');
    var i: usize = 0;
    if (dot == null or dot == base) return "";
    while (dot[1 + i] != 0 and i + 1 < S.ext.len) : (i += 1) S.ext[i] = std.ascii.toLower(dot[1 + i]);
    S.ext[i] = 0;
    return &S.ext;
}

export fn ide_same_path(a_: [*c]const u8, b_: [*c]const u8) c_int {
    var a = a_;
    var b = b_;
    if (a == null or b == null) return 0;
    while (a[0] != 0 and b[0] != 0) : ({
        a += 1;
        b += 1;
    }) {
        var x: u8 = if (a[0] == '\\') '/' else a[0];
        var y: u8 = if (b[0] == '\\') '/' else b[0];
        if (builtin.os.tag == .windows) {
            x = std.ascii.toLower(x);
            y = std.ascii.toLower(y);
        }
        if (x != y) return 0;
    }
    return @intFromBool(a[0] == b[0]);
}

fn compare_entries(a: ?*const anyopaque, b: ?*const anyopaque) callconv(.c) c_int {
    const x: [*c]const ide.ide_entry_t = @ptrCast(@alignCast(a));
    const y: [*c]const ide.ide_entry_t = @ptrCast(@alignCast(b));
    var p: [*c]const u8 = undefined;
    var q: [*c]const u8 = undefined;
    if (x.*.is_dir != y.*.is_dir) return y.*.is_dir - x.*.is_dir;
    p = &x.*.name;
    q = &y.*.name;
    while (p[0] != 0 and q[0] != 0) : ({
        p += 1;
        q += 1;
    }) {
        const c: c_int = @as(c_int, std.ascii.toLower(p[0])) - @as(c_int, std.ascii.toLower(q[0]));
        if (c != 0) return c;
    }
    return @as(c_int, p[0]) - @as(c_int, q[0]);
}

// ---------------------------------------------------------------------------
//  Windows (the `if (builtin.os.tag == .windows)` branches below), and
//  POSIX (their `else` branches): one function each, in the order of the C.
// ---------------------------------------------------------------------------

fn widen(text: [*c]const u8) [*c]WCHAR {
    const n = MultiByteToWideChar(CP_UTF8, 0, text, -1, null, 0);
    const wide: [*c]WCHAR = @ptrCast(@alignCast(libc.malloc(@sizeOf(WCHAR) * @as(usize, @intCast(if (n > 0) n else 1)))));
    if (n <= 0 or MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, n) == 0) wide[0] = 0;
    return wide;
}

fn narrow(wide: [*c]const WCHAR, out: [*c]u8, size: usize) void {
    if (WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, @intCast(size), null, null) == 0) out[0] = 0;
}

export fn ide_list_dir(path: [*c]const u8, entries: [*c][*c]ide.ide_entry_t) c_int {
    if (builtin.os.tag == .windows) {
        var data: WIN32_FIND_DATAW = undefined;
        const pattern = ide_join(path, "*");
        const wide = widen(pattern);
        const find = FindFirstFileW(wide, &data);
        var count: c_int = 0;
        var cap: c_int = 0;
        libc.free(pattern);
        libc.free(wide);
        entries.* = null;
        if (find == INVALID_HANDLE_VALUE) return -1;
        // do { ... } while (FindNextFileW(find, &data)): the first pass is unconditional, `continue` goes to the test
        var first = true;
        while (first or FindNextFileW(find, &data) != 0) : (first = false) {
            var entry: ide.ide_entry_t = undefined;
            narrow(&data.cFileName, &entry.name, entry.name.len);
            if (libc.strcmp(&entry.name, ".") == 0 or libc.strcmp(&entry.name, "..") == 0) continue;
            entry.is_dir = @intFromBool((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0);
            if (count == cap) {
                cap = if (cap != 0) cap * 2 else 32;
                entries.* = @ptrCast(@alignCast(libc.realloc(entries.*, @sizeOf(ide.ide_entry_t) * @as(usize, @intCast(cap)))));
            }
            entries.*[@intCast(count)] = entry;
            count += 1;
        }
        _ = FindClose(find);
        if (count != 0) libc.qsort(entries.*, @intCast(count), @sizeOf(ide.ide_entry_t), &compare_entries);
        return count;
    } else {
        const dir = libc.opendir(@ptrCast(path));
        var count: c_int = 0;
        var cap: c_int = 0;
        entries.* = null;
        if (dir == null) return -1;
        while (libc.readdir(dir.?)) |item| {
            var entry: ide.ide_entry_t = undefined;
            const d_name: [*c]const u8 = @ptrCast(&item.name);
            if (libc.strcmp(d_name, ".") == 0 or libc.strcmp(d_name, "..") == 0) continue;
            _ = libc.snprintf(&entry.name, entry.name.len, "%s", d_name);
            const full = ide_join(path, d_name);
            entry.is_dir = ide_is_dir(full);
            libc.free(full);
            if (count == cap) {
                cap = if (cap != 0) cap * 2 else 32;
                entries.* = @ptrCast(@alignCast(libc.realloc(entries.*, @sizeOf(ide.ide_entry_t) * @as(usize, @intCast(cap)))));
            }
            entries.*[@intCast(count)] = entry;
            count += 1;
        }
        _ = libc.closedir(dir.?);
        if (count != 0) libc.qsort(entries.*, @intCast(count), @sizeOf(ide.ide_entry_t), &compare_entries);
        return count;
    }
}

export fn ide_is_dir(path: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        const wide = widen(path);
        const attributes: DWORD = GetFileAttributesW(wide);
        libc.free(wide);
        return @intFromBool(attributes != INVALID_FILE_ATTRIBUTES and (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0);
    } else {
        var s: StatInfo = undefined;
        return @intFromBool(statPath(path, &s) == 0 and S_ISDIR(s.mode));
    }
}

export fn ide_file_exists(path: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        const wide = widen(path);
        const attributes: DWORD = GetFileAttributesW(wide);
        libc.free(wide);
        return @intFromBool(attributes != INVALID_FILE_ATTRIBUTES and (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0);
    } else {
        var s: StatInfo = undefined;
        return @intFromBool(statPath(path, &s) == 0 and S_ISREG(s.mode));
    }
}

export fn ide_make_dirs(path: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        const copy = ide_strdup(path);
        var p: [*c]u8 = copy;
        while (p[0] != 0) : (p += 1) {
            if ((p[0] == '/' or p[0] == '\\') and p > copy and (p - 1)[0] != ':') {
                const keep: u8 = p[0];
                p[0] = 0;
                const wide = widen(copy);
                _ = CreateDirectoryW(wide, null);
                libc.free(wide);
                p[0] = keep;
            }
        }
        {
            const wide = widen(copy);
            _ = CreateDirectoryW(wide, null);
            libc.free(wide);
        }
        const ok = ide_is_dir(copy);
        libc.free(copy);
        return ok;
    } else {
        const copy = ide_strdup(path);
        var p: [*c]u8 = copy + 1;
        while (p[0] != 0) : (p += 1) {
            if (p[0] == '/') {
                p[0] = 0;
                _ = libc.mkdir(copy, 0o755);
                p[0] = '/';
            }
        }
        _ = libc.mkdir(copy, 0o755);
        const ok = ide_is_dir(copy);
        libc.free(copy);
        return ok;
    }
}

export fn ide_file_time(path: [*c]const u8) f64 {
    if (builtin.os.tag == .windows) {
        var data: WIN32_FILE_ATTRIBUTE_DATA = undefined;
        const wide = widen(path);
        const ok: BOOL = GetFileAttributesExW(wide, GetFileExInfoStandard, &data);
        var t: ULARGE_INTEGER = undefined;
        libc.free(wide);
        if (ok == 0) return 0.0;
        t.u.LowPart = data.ftLastWriteTime.dwLowDateTime;
        t.u.HighPart = data.ftLastWriteTime.dwHighDateTime;
        return @as(f64, @floatFromInt(t.QuadPart / 10000000)) - 11644473600.0;
    } else {
        var s: StatInfo = undefined;
        if (statPath(path, &s) != 0) return 0.0;
        return @floatFromInt(s.mtime_sec);
    }
}

export fn ide_exe_dir() [*c]const u8 {
    const S = struct {
        var dir: [1024]u8 = std.mem.zeroes([1024]u8);
    };
    if (builtin.os.tag == .windows) {
        if (S.dir[0] == 0) {
            var wide: [1024]WCHAR = undefined;
            var slash: [*c]u8 = undefined;
            _ = GetModuleFileNameW(null, &wide, 1024);
            narrow(&wide, &S.dir, S.dir.len);
            slash = libc.strrchr(&S.dir, '\\');
            if (slash == null) slash = libc.strrchr(&S.dir, '/');
            if (slash != null) slash[0] = 0;
        }
        return &S.dir;
    } else {
        if (S.dir[0] == 0) {
            var slash: [*c]u8 = undefined;
            if (builtin.os.tag.isDarwin()) {
                var size: u32 = S.dir.len;
                if (_NSGetExecutablePath(&S.dir, &size) != 0) S.dir[0] = 0;
            } else {
                const n: isize = readlink("/proc/self/exe", &S.dir, S.dir.len - 1);
                S.dir[if (n > 0) @intCast(n) else 0] = 0;
            }
            slash = libc.strrchr(&S.dir, '/');
            if (slash != null) slash[0] = 0;
            if (S.dir[0] == 0) _ = libc.strcpy(&S.dir, ".");
        }
        return &S.dir;
    }
}

/// struct ide_process_t (one per OS; ide.h knows it only as an opaque type)
const ide_process_t = if (builtin.os.tag == .windows) extern struct {
    process: HANDLE,
    read: HANDLE,
    ended: c_int,
    exit_code: c_int,
} else extern struct {
    pid: c_int,
    read: c_int,
    ended: c_int,
    exit_code: c_int,
};

/// One argument of a command line, quoted the way the C runtime reads it back.
fn append_argument(line: [*c]ide.ide_buffer_t, argument: [*c]const u8) void {
    var p: [*c]const u8 = undefined;
    const needs: c_int = @intFromBool(argument[0] == 0 or strpbrk(argument, " \t\"") != null);
    if (line.*.size != 0) ide_buffer_add(line, " ", 1);
    if (needs == 0) {
        ide_buffer_add(line, argument, libc.strlen(argument));
        return;
    }
    ide_buffer_add(line, "\"", 1);
    p = argument;
    while (true) : (p += 1) {
        var backslashes: c_int = 0;
        while (p[0] == '\\') {
            p += 1;
            backslashes += 1;
        }
        if (p[0] == 0) {
            var i: c_int = 0;
            while (i < backslashes * 2) : (i += 1) ide_buffer_add(line, "\\", 1);
            break;
        }
        if (p[0] == '"') {
            var i: c_int = 0;
            while (i < backslashes * 2 + 1) : (i += 1) ide_buffer_add(line, "\\", 1);
        } else {
            var i: c_int = 0;
            while (i < backslashes) : (i += 1) ide_buffer_add(line, "\\", 1);
        }
        ide_buffer_add(line, p, 1);
    }
    ide_buffer_add(line, "\"", 1);
}

// (the header unit declares the process as `?*ide_process_t` (opaque): a pointer either way, same ABI)
export fn ide_process_start(argv: [*c]const [*c]const u8, directory: [*c]const u8) [*c]ide_process_t {
    if (builtin.os.tag == .windows) {
        var security: SECURITY_ATTRIBUTES = undefined;
        var startup: STARTUPINFOW = undefined;
        var info: PROCESS_INFORMATION = undefined;
        var read: HANDLE = null;
        var write: HANDLE = null;
        var line = std.mem.zeroes(ide.ide_buffer_t);
        var folder: [*c]WCHAR = null;
        var process: [*c]ide_process_t = undefined;
        var i: c_int = 0;

        security = std.mem.zeroes(SECURITY_ATTRIBUTES);
        security.nLength = @sizeOf(SECURITY_ATTRIBUTES);
        security.bInheritHandle = TRUE;
        if (CreatePipe(&read, &write, &security, 0) == 0) return null;
        _ = SetHandleInformation(read, HANDLE_FLAG_INHERIT, 0);
        const null_input: HANDLE = CreateFileW(L("NUL"), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, null);

        while (argv[@intCast(i)] != null) : (i += 1) append_argument(&line, argv[@intCast(i)]);
        const command = widen(if (line.data != null) line.data else "");
        ide_buffer_free(&line);
        if (directory != null and directory[0] != 0) folder = widen(directory);

        startup = std.mem.zeroes(STARTUPINFOW);
        startup.cb = @sizeOf(STARTUPINFOW);
        startup.dwFlags = STARTF_USESTDHANDLES;
        startup.hStdInput = null_input;
        startup.hStdOutput = write;
        startup.hStdError = write;
        info = std.mem.zeroes(PROCESS_INFORMATION);
        const ok: BOOL = CreateProcessW(null, command, null, null, TRUE, CREATE_NO_WINDOW, null, folder, &startup, &info);
        libc.free(command);
        libc.free(folder);
        _ = CloseHandle(write);
        if (null_input != INVALID_HANDLE_VALUE) _ = CloseHandle(null_input);
        if (ok == 0) {
            _ = CloseHandle(read);
            return null;
        }
        _ = CloseHandle(info.hThread);
        process = @ptrCast(@alignCast(libc.calloc(1, @sizeOf(ide_process_t))));
        process.*.process = info.hProcess;
        process.*.read = read;
        return process;
    } else {
        var fds: [2]c_int = undefined;
        var process: [*c]ide_process_t = undefined;
        if (libc.pipe(&fds) != 0) return null;
        const pid: c_int = libc.fork();
        if (pid < 0) {
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
            return null;
        }
        if (pid == 0) {
            const null_input: c_int = libc.open("/dev/null", O_RDONLY);
            if (null_input >= 0) _ = libc.dup2(null_input, 0);
            _ = libc.dup2(fds[1], 1);
            _ = libc.dup2(fds[1], 2);
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
            // its own group: Stop ends what it started too
            _ = setpgid(0, 0);
            if (directory != null and directory[0] != 0 and chdir(directory) != 0) libc._exit(126);
            _ = libc.execvp(argv[0], argv);
            _ = fprintf(libc.stderrFile(), "cannot start %s: %s\n", argv[0], strerror(errnoValue()));
            libc._exit(127);
        }
        _ = libc.close(fds[1]);
        _ = libc.fcntl(fds[0], F_SETFL, libc.fcntl(fds[0], F_GETFL) | O_NONBLOCK);
        process = @ptrCast(@alignCast(libc.calloc(1, @sizeOf(ide_process_t))));
        process.*.pid = pid;
        process.*.read = fds[0];
        return process;
    }
}

export fn ide_process_read(process: [*c]ide_process_t, buffer: [*c]u8, size: c_int) c_int {
    if (builtin.os.tag == .windows) {
        var available: DWORD = 0;
        var got: DWORD = 0;
        if (process.*.read == null) return -1;
        if (PeekNamedPipe(process.*.read, null, 0, null, &available, null) == 0) {
            _ = CloseHandle(process.*.read);
            process.*.read = null;
            return -1;
        }
        if (available == 0) return 0;
        if (available > @as(DWORD, @bitCast(size))) available = @bitCast(size);
        if (ReadFile(process.*.read, buffer, available, &got, null) == 0) return -1;
        return @bitCast(got);
    } else {
        var n: isize = undefined;
        if (process.*.read < 0) return -1;
        n = libc.read(process.*.read, buffer, @bitCast(@as(isize, size)));
        if (n > 0) return @intCast(n);
        if (n < 0 and (errnoValue() == EAGAIN or errnoValue() == EWOULDBLOCK or errnoValue() == EINTR)) return 0;
        _ = libc.close(process.*.read);
        process.*.read = -1;
        return -1;
    }
}

export fn ide_process_done(process: [*c]ide_process_t, exit_code: [*c]c_int) c_int {
    if (builtin.os.tag == .windows) {
        var code: DWORD = undefined;
        if (process.*.ended == 0 and WaitForSingleObject(process.*.process, 0) == WAIT_OBJECT_0) {
            _ = GetExitCodeProcess(process.*.process, &code);
            process.*.exit_code = @bitCast(code);
            process.*.ended = 1;
        }
        if (process.*.ended != 0 and exit_code != null) exit_code.* = process.*.exit_code;
        return process.*.ended;
    } else {
        if (process.*.ended == 0) {
            var status: c_int = 0;
            if (libc.waitpid(process.*.pid, &status, WNOHANG) == process.*.pid) {
                process.*.ended = 1;
                process.*.exit_code = if (WIFEXITED(status)) WEXITSTATUS(status) else 128 + (if (WIFSIGNALED(status)) WTERMSIG(status) else 0);
            }
        }
        if (process.*.ended != 0 and exit_code != null) exit_code.* = process.*.exit_code;
        return process.*.ended;
    }
}

export fn ide_process_kill(process: [*c]ide_process_t) void {
    if (builtin.os.tag == .windows) {
        if (process.*.ended == 0) _ = TerminateProcess(process.*.process, 1);
    } else {
        if (process.*.ended == 0) _ = kill(-process.*.pid, SIGTERM);
    }
}

export fn ide_process_free(process: [*c]ide_process_t) void {
    if (builtin.os.tag == .windows) {
        if (process == null) return;
        if (process.*.read != null) _ = CloseHandle(process.*.read);
        _ = CloseHandle(process.*.process);
        libc.free(process);
    } else {
        if (process == null) return;
        if (process.*.read >= 0) _ = libc.close(process.*.read);
        if (process.*.ended == 0) {
            var status: c_int = undefined;
            _ = kill(-process.*.pid, SIGKILL);
            _ = libc.waitpid(process.*.pid, &status, 0);
        }
        libc.free(process);
    }
}

export fn ide_set_env(name: [*c]const u8, value: [*c]const u8) void {
    if (builtin.os.tag == .windows) {
        const wide_name = widen(name);
        const wide_value = widen(if (value != null) value else "");
        _ = SetEnvironmentVariableW(wide_name, if (value != null) wide_value else null);
        libc.free(wide_name);
        libc.free(wide_value);
    } else {
        if (value != null) {
            _ = setenv(name, value, 1);
        } else _ = unsetenv(name);
    }
}

export fn ide_prepend_path(folder: [*c]const u8) void {
    if (builtin.os.tag == .windows) {
        const wide = widen(folder);
        const n: DWORD = GetEnvironmentVariableW(L("PATH"), null, 0);
        const old: [*c]WCHAR = @ptrCast(@alignCast(libc.malloc(@sizeOf(WCHAR) * @as(usize, n +% 1))));
        var both: [*c]WCHAR = undefined;
        var length: usize = undefined;
        old[0] = 0;
        if (n != 0) _ = GetEnvironmentVariableW(L("PATH"), old, n +% 1);
        if (wcsstr(old, wide) != null) {
            libc.free(old);
            libc.free(wide);
            return;
        }
        length = wcslen(wide) + wcslen(old) + 2;
        both = @ptrCast(@alignCast(libc.malloc(@sizeOf(WCHAR) * length)));
        _ = swprintf(both, length, L("%ls;%ls"), wide, old);
        _ = SetEnvironmentVariableW(L("PATH"), both);
        libc.free(both);
        libc.free(old);
        libc.free(wide);
    } else {
        const old: [*c]const u8 = libc.getenv("PATH");
        var both: [*c]u8 = undefined;
        if (old != null and libc.strstr(old, folder) != null) return;
        both = @ptrCast(libc.malloc(libc.strlen(folder) + (if (old != null) libc.strlen(old) else 0) + 2));
        _ = sprintf(both, "%s%s%s", folder, @as([*c]const u8, if (old != null) ":" else ""), @as([*c]const u8, if (old != null) old else ""));
        _ = setenv("PATH", both, 1);
        libc.free(both);
    }
}

export fn ide_find_program(name: [*c]const u8, out: [*c]u8, size: usize) c_int {
    if (builtin.os.tag == .windows) {
        var wide_name: [260]WCHAR = undefined;
        var found: [1024]WCHAR = undefined;
        _ = MultiByteToWideChar(CP_UTF8, 0, name, -1, &wide_name, 260);
        if (SearchPathW(null, &wide_name, L(".exe"), 1024, &found, null) == 0) return 0;
        narrow(&found, out, size);
        return 1;
    } else {
        var path: [*c]const u8 = libc.getenv("PATH");
        while (path != null and path[0] != 0) {
            const length: usize = libc.strcspn(path, ":");
            var candidate: [1024]u8 = undefined;
            _ = libc.snprintf(&candidate, candidate.len, "%.*s/%s", @as(c_int, @intCast(length)), path, name);
            if (libc.access(&candidate, X_OK) == 0 and ide_file_exists(&candidate) != 0) {
                _ = libc.snprintf(out, size, "%s", &candidate);
                return 1;
            }
            path += length;
            if (path[0] == ':') path += 1;
        }
        return 0;
    }
}

fn env_folder(name: [*c]const WCHAR, out: [*c]u8, size: usize) void {
    var value: [1024]WCHAR = undefined;
    const n: DWORD = GetEnvironmentVariableW(name, &value, 1024);
    out[0] = 0;
    if (n > 0 and n < 1024) narrow(&value, out, size);
}

export fn ide_home_dir() [*c]const u8 {
    const S = struct {
        var dir: [1024]u8 = std.mem.zeroes([1024]u8);
    };
    if (builtin.os.tag == .windows) {
        if (S.dir[0] == 0) {
            env_folder(L("USERPROFILE"), &S.dir, S.dir.len);
            if (S.dir[0] == 0) _ = libc.snprintf(&S.dir, S.dir.len, "C:/");
            const n = ide_normalize(&S.dir);
            _ = libc.snprintf(&S.dir, S.dir.len, "%s", n);
            libc.free(n);
        }
        return &S.dir;
    } else {
        if (S.dir[0] == 0) {
            const home: [*c]const u8 = libc.getenv("HOME");
            _ = libc.snprintf(&S.dir, S.dir.len, "%s", @as([*c]const u8, if (home != null and home[0] != 0) home else "/tmp"));
        }
        return &S.dir;
    }
}

export fn ide_config_dir() [*c]const u8 {
    const S = struct {
        var dir: [1100]u8 = std.mem.zeroes([1100]u8);
    };
    if (builtin.os.tag == .windows) {
        if (S.dir[0] == 0) {
            var base: [1024]u8 = undefined;
            env_folder(L("APPDATA"), &base, base.len);
            if (base[0] == 0) _ = libc.snprintf(&base, base.len, "%s/AppData/Roaming", ide_home_dir());
            const n = ide_normalize(&base);
            _ = libc.snprintf(&S.dir, S.dir.len, "%s/Raven", n);
            libc.free(n);
            _ = ide_make_dirs(&S.dir);
        }
        return &S.dir;
    } else {
        if (S.dir[0] == 0) {
            if (builtin.os.tag.isDarwin()) {
                _ = libc.snprintf(&S.dir, S.dir.len, "%s/Library/Application Support/Raven", ide_home_dir());
            } else {
                const xdg: [*c]const u8 = libc.getenv("XDG_CONFIG_HOME");
                if (xdg != null and xdg[0] == '/') {
                    _ = libc.snprintf(&S.dir, S.dir.len, "%s/raven", xdg);
                } else _ = libc.snprintf(&S.dir, S.dir.len, "%s/.config/raven", ide_home_dir());
            }
            _ = ide_make_dirs(&S.dir);
        }
        return &S.dir;
    }
}

export fn ide_remove_file(path: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        const wide = widen(path);
        const ok: BOOL = DeleteFileW(wide);
        libc.free(wide);
        return @intFromBool(ok != 0);
    } else {
        return @intFromBool(unlink(path) == 0);
    }
}

/// Where new projects go by default: Documents/Raven Projects (the Documents folder when there is one).
export fn ide_default_projects_dir() [*c]const u8 {
    const S = struct {
        var dir: [1200]u8 = std.mem.zeroes([1200]u8);
    };
    if (S.dir[0] == 0) {
        const documents = ide_join(ide_home_dir(), "Documents");
        _ = libc.snprintf(&S.dir, S.dir.len, "%s/Raven Projects", if (ide_is_dir(documents) != 0) @as([*c]const u8, documents) else ide_home_dir());
        libc.free(documents);
    }
    return &S.dir;
}

/// "C:/Users/ada/Documents/x" -> "~/Documents/x": shorter, for the eyes only.
export fn ide_pretty_path(path: [*c]const u8, out: [*c]u8, size: usize) void {
    const normalized = ide_normalize(path);
    const home = ide_normalize(ide_home_dir());
    const length: usize = libc.strlen(home);
    if (length > 1 and libc.strncmp(normalized, home, length) == 0 and (normalized[length] == '/' or normalized[length] == 0)) {
        _ = libc.snprintf(out, size, "~%s", normalized + length);
    } else {
        _ = libc.snprintf(out, size, "%s", normalized);
    }
    libc.free(normalized);
    libc.free(home);
}
