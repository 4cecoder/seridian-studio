// Translated to Zig from vendor/raven/src/core/fs.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/fs.c
// Folders, paths and the usual places, for Win32 and POSIX.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("base_h.zig");
const fs = @import("fs_h.zig");
const libc = @import("../sys/libc.zig");

const R_TRUE = raven.R_TRUE;
const R_FALSE = raven.R_FALSE;

const STDOUT_FILENO: c_int = 1;
const STDERR_FILENO: c_int = 2;

// #define RVN_FS_DOWNLOAD_MAX (32u * 1024u * 1024u)
const RVN_FS_DOWNLOAD_MAX: usize = 32 * 1024 * 1024;

// ---------------------------------------------------------------------------
//  Win32 declarations (windows.h, winhttp.h, shellapi.h): used only in the
//  Windows branches, which are not analysed on other systems.
// ---------------------------------------------------------------------------

const WCHAR = u16;
const DWORD = u32;
const BOOL = c_int;
const HANDLE = ?*anyopaque;
const CP_UTF8: u32 = 65001;
const ERROR_FILE_NOT_FOUND: DWORD = 2;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
const FILE_ATTRIBUTE_HIDDEN: DWORD = 0x2;
const FILE_ATTRIBUTE_SYSTEM: DWORD = 0x4;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
const SW_SHOWNORMAL: c_int = 1;
const GetFileExInfoStandard: c_int = 0;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

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

const URL_COMPONENTS = extern struct {
    dwStructSize: DWORD,
    lpszScheme: [*c]WCHAR,
    dwSchemeLength: DWORD,
    nScheme: c_int,
    lpszHostName: [*c]WCHAR,
    dwHostNameLength: DWORD,
    nPort: u16,
    lpszUserName: [*c]WCHAR,
    dwUserNameLength: DWORD,
    lpszPassword: [*c]WCHAR,
    dwPasswordLength: DWORD,
    lpszUrlPath: [*c]WCHAR,
    dwUrlPathLength: DWORD,
    lpszExtraInfo: [*c]WCHAR,
    dwExtraInfoLength: DWORD,
};

const INTERNET_SCHEME_HTTPS: c_int = 2;
const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: DWORD = 0;
const WINHTTP_FLAG_SECURE: DWORD = 0x00800000;
const WINHTTP_QUERY_STATUS_CODE: DWORD = 19;
const WINHTTP_QUERY_FLAG_NUMBER: DWORD = 0x20000000;

extern "kernel32" fn MultiByteToWideChar(CodePage: u32, dwFlags: DWORD, lpMultiByteStr: [*c]const u8, cbMultiByte: c_int, lpWideCharStr: [*c]WCHAR, cchWideChar: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(CodePage: u32, dwFlags: DWORD, lpWideCharStr: [*c]const WCHAR, cchWideChar: c_int, lpMultiByteStr: [*c]u8, cbMultiByte: c_int, lpDefaultChar: ?*const anyopaque, lpUsedDefaultChar: ?*BOOL) callconv(.winapi) c_int;
extern "kernel32" fn FindFirstFileW(lpFileName: [*c]const WCHAR, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*c]const WCHAR) callconv(.winapi) DWORD;
extern "kernel32" fn GetFileAttributesExW(lpFileName: [*c]const WCHAR, fInfoLevelId: c_int, lpFileInformation: *anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetFullPathNameW(lpFileName: [*c]const WCHAR, nBufferLength: DWORD, lpBuffer: [*c]WCHAR, lpFilePart: ?*anyopaque) callconv(.winapi) DWORD;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*c]const WCHAR, lpBuffer: [*c]WCHAR, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn CreateDirectoryW(lpPathName: [*c]const WCHAR, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetLogicalDrives() callconv(.winapi) DWORD;
extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, lpOperation: [*c]const WCHAR, lpFile: [*c]const WCHAR, lpParameters: [*c]const WCHAR, lpDirectory: [*c]const WCHAR, nShowCmd: c_int) callconv(.winapi) ?*anyopaque;
extern "c" fn _wfopen(filename: [*c]const WCHAR, mode: [*c]const WCHAR) ?*libc.FILE;
extern "winhttp" fn WinHttpCrackUrl(pwszUrl: [*c]const WCHAR, dwUrlLength: DWORD, dwFlags: DWORD, lpUrlComponents: *URL_COMPONENTS) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpOpen(pwszUserAgent: [*c]const WCHAR, dwAccessType: DWORD, pwszProxyName: [*c]const WCHAR, pwszProxyBypass: [*c]const WCHAR, dwFlags: DWORD) callconv(.winapi) HANDLE;
extern "winhttp" fn WinHttpSetTimeouts(hInternet: HANDLE, nResolveTimeout: c_int, nConnectTimeout: c_int, nSendTimeout: c_int, nReceiveTimeout: c_int) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpConnect(hSession: HANDLE, pswzServerName: [*c]const WCHAR, nServerPort: u16, dwReserved: DWORD) callconv(.winapi) HANDLE;
extern "winhttp" fn WinHttpOpenRequest(hConnect: HANDLE, pwszVerb: [*c]const WCHAR, pwszObjectName: [*c]const WCHAR, pwszVersion: [*c]const WCHAR, pwszReferrer: [*c]const WCHAR, ppwszAcceptTypes: ?*anyopaque, dwFlags: DWORD) callconv(.winapi) HANDLE;
extern "winhttp" fn WinHttpSendRequest(hRequest: HANDLE, lpszHeaders: [*c]const WCHAR, dwHeadersLength: DWORD, lpOptional: ?*anyopaque, dwOptionalLength: DWORD, dwTotalLength: DWORD, dwContext: usize) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpReceiveResponse(hRequest: HANDLE, lpReserved: ?*anyopaque) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpQueryHeaders(hRequest: HANDLE, dwInfoLevel: DWORD, pwszName: [*c]const WCHAR, lpBuffer: ?*anyopaque, lpdwBufferLength: *DWORD, lpdwIndex: ?*DWORD) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpReadData(hRequest: HANDLE, lpBuffer: ?*anyopaque, dwNumberOfBytesToRead: DWORD, lpdwNumberOfBytesRead: *DWORD) callconv(.winapi) BOOL;
extern "winhttp" fn WinHttpCloseHandle(hInternet: HANDLE) callconv(.winapi) BOOL;

// POSIX status macros (sys/wait.h), same values on Linux and macOS.
fn WIFEXITED(status: c_int) bool {
    return (status & 0x7f) == 0;
}
fn WEXITSTATUS(status: c_int) c_int {
    return (status >> 8) & 0xff;
}

// POSIX open flags and errno values (fcntl.h, errno.h).
const O_WRONLY: c_int = @bitCast(std.c.O{ .ACCMODE = .WRONLY });
fn errnoValue() c_int {
    return std.c._errno().*;
}
const EINTR: c_int = @intFromEnum(std.c.E.INTR);

/// The fields of `struct stat` that this file reads: st_mode, st_size, st_mtime(spec).
const StatInfo = struct {
    mode: u32,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
};

/// S_ISDIR(mode)
fn S_ISDIR(mode: u32) bool {
    return (mode & std.c.S.IFMT) == std.c.S.IFDIR;
}

/// stat(path, &info). std.c has no `struct stat` on Linux (it goes through statx): there the same
/// data comes from statx(AT_FDCWD, path, 0, ...), which follows links as stat does.
fn statPath(path: [*c]const u8, info: *StatInfo) c_int {
    if (builtin.os.tag == .linux) {
        var buf: std.os.linux.Statx = undefined;
        const rc = std.c.statx(std.os.linux.AT.FDCWD, path, 0, std.os.linux.STATX.BASIC_STATS, &buf);
        if (rc != 0) return rc;
        info.* = .{
            .mode = buf.mode,
            .size = buf.size,
            .mtime_sec = buf.mtime.sec,
            .mtime_nsec = buf.mtime.nsec,
        };
        return 0;
    } else {
        var st: std.c.Stat = undefined;
        const rc = libc.stat(path, &st);
        if (rc != 0) return rc;
        const mtime = st.mtime();
        info.* = .{
            .mode = @as(u32, st.mode),
            .size = @bitCast(st.size),
            .mtime_sec = @intCast(mtime.sec),
            .mtime_nsec = @intCast(mtime.nsec),
        };
        return 0;
    }
}

// ---------------------------------------------------------------------------
//  Shared
// ---------------------------------------------------------------------------

export fn rvn_dir_free(entries: [*c]fs.rvn_dir_entry_t, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) base.rvn_free(entries[i].name);
    base.rvn_free(entries);
}

export fn rvn_path_name(path: [*c]const u8) [*c]const u8 {
    var name: [*c]const u8 = path;
    var cursor: [*c]const u8 = path;
    while (cursor[0] != 0) : (cursor += 1) {
        if (fs.rvn_path_is_separator(cursor[0]) != 0 and cursor[1] != 0) name = cursor + 1;
    }
    return name;
}

export fn rvn_path_child(folder: [*c]const u8, name: [*c]const u8) [*c]u8 {
    const folder_length: usize = libc.strlen(folder);
    const name_length: usize = libc.strlen(name);
    const separator = folder_length > 0 and fs.rvn_path_is_separator(folder[folder_length - 1]) == 0;
    const path: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(folder_length + name_length + 2)));
    _ = libc.memcpy(path, folder, folder_length);
    if (separator) path[folder_length] = fs.RVN_PATH_SEPARATOR;
    _ = libc.memcpy(path + folder_length + @as(usize, @intFromBool(separator)), name, name_length + 1);
    return path;
}

/// Length of the root at the start of an absolute path: "/" or "C:\" or "\\server\share\". 0 when there is none.
fn rvn_path_root_length(path: [*c]const u8) usize {
    if (builtin.os.tag == .windows) {
        if (((path[0] >= 'A' and path[0] <= 'Z') or (path[0] >= 'a' and path[0] <= 'z')) and path[1] == ':') {
            return if (fs.rvn_path_is_separator(path[2]) != 0) 3 else 2;
        }
        if (fs.rvn_path_is_separator(path[0]) != 0 and fs.rvn_path_is_separator(path[1]) != 0) {
            // \\server\share
            var i: usize = 2;
            var parts: c_int = 0;
            while (path[i] != 0 and parts < 2) {
                while (path[i] != 0 and fs.rvn_path_is_separator(path[i]) == 0) i += 1;
                parts += 1;
                if (path[i] != 0 and parts < 2) i += 1;
            }
            if (path[i] != 0) i += 1;
            return i;
        }
        return 0;
    } else {
        return if (path[0] == '/') 1 else 0;
    }
}

export fn rvn_path_parent(path: [*c]const u8) [*c]u8 {
    const root = rvn_path_root_length(path);
    var length: usize = libc.strlen(path);
    while (length > root and fs.rvn_path_is_separator(path[length - 1]) != 0) length -= 1;
    if (length <= root) return null;
    while (length > root and fs.rvn_path_is_separator(path[length - 1]) == 0) length -= 1;
    while (length > root and fs.rvn_path_is_separator(path[length - 1]) != 0) length -= 1;
    if (length == 0) return null;
    return base.rvn_strndup(path, length);
}

/// Removes "." and ".." and doubled or trailing separators from an absolute path, in place.
fn rvn_path_clean(path: [*c]u8) void {
    const root = rvn_path_root_length(path);
    var out: [*c]u8 = path + root;
    var in: [*c]const u8 = path + root;

    while (in[0] != 0) {
        var end: [*c]const u8 = in;
        while (end[0] != 0 and fs.rvn_path_is_separator(end[0]) == 0) end += 1;
        const length: usize = @intCast(end - in);
        if (length == 0 or (length == 1 and in[0] == '.')) {
            // nothing
        } else if (length == 2 and in[0] == '.' and in[1] == '.') {
            // back to the previous component
            if (out > path + root) {
                out -= 1;
                while (out > path + root and fs.rvn_path_is_separator((out - 1)[0]) == 0) out -= 1;
                if (out > path + root) out -= 1;
            }
        } else {
            if (out > path + root) {
                out[0] = fs.RVN_PATH_SEPARATOR;
                out += 1;
            }
            _ = libc.memmove(out, in, length);
            out += length;
        }
        in = if (end[0] != 0) end + 1 else end;
    }
    out[0] = 0;
    if (builtin.os.tag == .windows) {
        var cursor: [*c]u8 = path;
        while (cursor[0] != 0) : (cursor += 1) {
            if (cursor[0] == '/') cursor[0] = '\\';
        }
    }
}

export fn rvn_pattern_match(patterns: [*c]const u8, name: [*c]const u8) c_int {
    const name_length: usize = libc.strlen(name);
    var cursor: [*c]const u8 = patterns;
    if (patterns == null or patterns[0] == 0) return R_TRUE;
    while (cursor[0] != 0) {
        var end: [*c]const u8 = cursor;
        while (end[0] != 0 and end[0] != ';' and end[0] != ',' and end[0] != ' ') end += 1;
        const length: usize = @intCast(end - cursor);
        if (length == 1 and cursor[0] == '*') return R_TRUE;
        if (length == 3 and libc.memcmp(cursor, "*.*", 3) == 0) return R_TRUE;
        if (length >= 2 and cursor[0] == '*') {
            // "*.ext": the name ends with it
            const suffix = length - 1;
            if (name_length >= suffix and base.rvn_strnicmp(name + (name_length - suffix), cursor + 1, suffix) == 0) return R_TRUE;
        } else if (length > 0 and length == name_length and base.rvn_strnicmp(name, cursor, length) == 0) {
            return R_TRUE;
        }
        cursor = end;
        while (cursor[0] == ';' or cursor[0] == ',' or cursor[0] == ' ') cursor += 1;
    }
    return R_FALSE;
}

fn rvn_places_add(places: [*c][*c]fs.rvn_place_t, count: [*c]u32, cap: [*c]u32, label: [*c]const u8, path: [*c]u8) void {
    var i: u32 = 0;
    if (path == null) return;
    while (i < count.*) : (i += 1) {
        if (libc.strcmp(places.*[i].path, path) == 0) {
            base.rvn_free(path);
            return;
        }
    }
    base.RVN_ARRAY_RESERVE(places, cap, count.* + 1);
    places.*[count.*].label = base.rvn_strdup(label);
    places.*[count.*].path = path;
    count.* += 1;
}

/// A folder of the home that exists, or NULL.
fn rvn_places_home_folder(home: [*c]const u8, name: [*c]const u8) [*c]u8 {
    const path = rvn_path_child(home, name);
    if (rvn_path_is_dir(path) != 0) return path;
    base.rvn_free(path);
    return null;
}

export fn rvn_fs_places_free(places: [*c]fs.rvn_place_t, count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        base.rvn_free(places[i].label);
        base.rvn_free(places[i].path);
    }
    base.rvn_free(places);
}

// ---------------------------------------------------------------------------
//  Win32 helpers
// ---------------------------------------------------------------------------

fn rvn_fs_wide(text: [*c]const u8) [*c]WCHAR {
    const length = MultiByteToWideChar(CP_UTF8, 0, text, -1, null, 0);
    if (length <= 0) return null;
    const wide: [*c]WCHAR = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(WCHAR) * @as(usize, @intCast(length)))));
    _ = MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, length);
    return wide;
}

fn rvn_fs_narrow(wide: [*c]const WCHAR) [*c]u8 {
    const length = WideCharToMultiByte(CP_UTF8, 0, wide, -1, null, 0, null, null);
    if (length <= 0) return null;
    const text: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(length)))));
    _ = WideCharToMultiByte(CP_UTF8, 0, wide, -1, text, length, null, null);
    return text;
}

/// 100 ns ticks since 1601 -> seconds since 1970
fn rvn_fs_unix_time(time: FILETIME) i64 {
    const ticks: u64 = (@as(u64, time.dwHighDateTime) << 32) | @as(u64, time.dwLowDateTime);
    return @as(i64, @intCast(ticks / 10000000)) - 11644473600;
}

fn rvn_fs_attributes(path: [*c]const u8) DWORD {
    const wide = rvn_fs_wide(path);
    if (wide == null) return INVALID_FILE_ATTRIBUTES;
    const attributes = GetFileAttributesW(wide);
    base.rvn_free(wide);
    return attributes;
}

// ---------------------------------------------------------------------------
//  Shared (continued): folders, paths, files
// ---------------------------------------------------------------------------

/// Lists a folder, without "." and "..", in no particular order. R_FALSE when it cannot be read.
export fn rvn_dir_read(path: [*c]const u8, entries: [*c][*c]fs.rvn_dir_entry_t, count: [*c]u32) c_int {
    var cap: u32 = 0;
    if (builtin.os.tag == .windows) {
        const pattern = rvn_path_child(path, "*");
        const wide = rvn_fs_wide(pattern);
        var data: WIN32_FIND_DATAW = undefined;

        entries.* = null;
        count.* = 0;
        base.rvn_free(pattern);
        if (wide == null) return R_FALSE;
        const find = FindFirstFileW(wide, &data);
        base.rvn_free(wide);
        if (find == INVALID_HANDLE_VALUE) return @intFromBool(GetLastError() == ERROR_FILE_NOT_FOUND);
        // do { ... } while (FindNextFileW(...)): the first pass is unconditional
        var first = true;
        while (first or FindNextFileW(find, &data) != 0) : (first = false) {
            const file_name = std.mem.sliceTo(&data.cFileName, 0);
            if (std.mem.eql(u16, file_name, std.unicode.utf8ToUtf16LeStringLiteral(".")) or
                std.mem.eql(u16, file_name, std.unicode.utf8ToUtf16LeStringLiteral("..")))
            {
                continue;
            }
            base.RVN_ARRAY_RESERVE(entries, &cap, count.* + 1);
            const entry: [*c]fs.rvn_dir_entry_t = &entries.*[count.*];
            entry.*.name = rvn_fs_narrow(&data.cFileName);
            if (entry.*.name == null) continue;
            entry.*.is_dir = @intFromBool((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0);
            entry.*.hidden = @intFromBool((data.dwFileAttributes & (FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM)) != 0);
            entry.*.size = (@as(u64, data.nFileSizeHigh) << 32) | @as(u64, data.nFileSizeLow);
            entry.*.modified = rvn_fs_unix_time(data.ftLastWriteTime);
            count.* += 1;
        }
        _ = FindClose(find);
        return R_TRUE;
    } else {
        entries.* = null;
        count.* = 0;
        const dir = libc.opendir(path) orelse return R_FALSE;
        while (libc.readdir(dir)) |item| {
            var info: StatInfo = undefined;
            if (libc.strcmp(&item.name, ".") == 0 or libc.strcmp(&item.name, "..") == 0) continue;
            base.RVN_ARRAY_RESERVE(entries, &cap, count.* + 1);
            const entry: [*c]fs.rvn_dir_entry_t = &entries.*[count.*];
            _ = libc.memset(entry, 0, @sizeOf(fs.rvn_dir_entry_t));
            entry.*.name = base.rvn_strdup(&item.name);
            entry.*.hidden = @intFromBool(item.name[0] == '.');
            // (stat follows links: a link to a folder is shown as a folder)
            const full = rvn_path_child(path, &item.name);
            if (statPath(full, &info) == 0) {
                entry.*.is_dir = @intFromBool(S_ISDIR(info.mode));
                entry.*.size = info.size;
                entry.*.modified = info.mtime_sec;
            }
            base.rvn_free(full);
            count.* += 1;
        }
        _ = libc.closedir(dir);
        return R_TRUE;
    }
}

export fn rvn_path_exists(path: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        return @intFromBool(rvn_fs_attributes(path) != INVALID_FILE_ATTRIBUTES);
    } else {
        var info: StatInfo = undefined;
        return @intFromBool(statPath(path, &info) == 0);
    }
}

export fn rvn_file_stamp(path: [*c]const u8, modified: [*c]u64, size: [*c]u64) c_int {
    if (builtin.os.tag == .windows) {
        var data: WIN32_FILE_ATTRIBUTE_DATA = undefined;
        const wide = rvn_fs_wide(path);
        if (wide == null) return R_FALSE;
        const ok = GetFileAttributesExW(wide, GetFileExInfoStandard, &data);
        base.rvn_free(wide);
        if (ok == 0 or (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) return R_FALSE;
        modified.* = (@as(u64, data.ftLastWriteTime.dwHighDateTime) << 32) | @as(u64, data.ftLastWriteTime.dwLowDateTime);
        size.* = (@as(u64, data.nFileSizeHigh) << 32) | @as(u64, data.nFileSizeLow);
        return R_TRUE;
    } else {
        var info: StatInfo = undefined;
        if (path == null or statPath(path, &info) != 0 or S_ISDIR(info.mode)) return R_FALSE;
        // st_mtim (st_mtimespec on Apple) as a 64-bit nanosecond count, unsigned as in C
        const sec: u64 = @bitCast(info.mtime_sec);
        const nsec: u64 = @bitCast(info.mtime_nsec);
        modified.* = sec *% 1000000000 +% nsec;
        size.* = info.size;
        return R_TRUE;
    }
}

export fn rvn_path_is_dir(path: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        const attributes = rvn_fs_attributes(path);
        return @intFromBool(attributes != INVALID_FILE_ATTRIBUTES and (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0);
    } else {
        var info: StatInfo = undefined;
        return @intFromBool(statPath(path, &info) == 0 and S_ISDIR(info.mode));
    }
}

/// Absolute path without "." or "..", without a trailing separator except for a root. Free with rvn_free.
export fn rvn_path_absolute(path: [*c]const u8) [*c]u8 {
    if (builtin.os.tag == .windows) {
        const path_: [*c]const u8 = if (path != null and path[0] != 0) path else ".";
        const wide = rvn_fs_wide(path_);
        if (wide == null) return null;
        // WCHAR full[2048], on the heap (see the note in rvn_path_absolute's POSIX branch)
        const full: [*c]WCHAR = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(WCHAR) * 2048)));
        const length = GetFullPathNameW(wide, 2048, full, null);
        base.rvn_free(wide);
        if (length == 0 or length >= 2048) {
            base.rvn_free(full);
            return null;
        }
        const result = rvn_fs_narrow(full);
        base.rvn_free(full);
        if (result != null) rvn_path_clean(result);
        return result;
    } else {
        var path_: [*c]const u8 = path;
        if (path_ == null or path_[0] == 0) path_ = ".";
        var result: [*c]u8 = undefined;
        if (path_[0] == '~' and (path_[1] == '/' or path_[1] == 0)) {
            // "~/x": the home of the user, as a shell would understand it
            const home = rvn_path_home();
            const rest: [*c]const u8 = if (path_[1] != 0) path_ + 2 else "";
            result = rvn_path_child(home, rest);
            base.rvn_free(home);
        } else if (path_[0] == '/') {
            result = base.rvn_strdup(path_);
        } else {
            // char current[4096], on the heap: a 4 KiB stack frame needs a stack probe that the C link line
            // does not provide (the same storage, freed on every path)
            const current: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(4096)));
            if (libc.getcwd(current, 4096) == null) {
                base.rvn_free(current);
                return null;
            }
            result = rvn_path_child(current, path_);
            base.rvn_free(current);
        }
        rvn_path_clean(result);
        return result;
    }
}

/// Home folder of the user. Free with rvn_free.
export fn rvn_path_home() [*c]u8 {
    if (builtin.os.tag == .windows) {
        var home: [1024]WCHAR = undefined;
        const length = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"), &home, @intCast(home.len));
        if (length == 0 or length >= home.len) return base.rvn_strdup("C:\\");
        return rvn_fs_narrow(&home);
    } else {
        const home = libc.getenv("HOME");
        const chosen: [*c]const u8 = if (home != null and home[0] != 0) home else "/";
        return base.rvn_strdup(chosen);
    }
}

export fn rvn_make_dir(path: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        const wide = rvn_fs_wide(path);
        if (wide == null) return R_FALSE;
        const ok = CreateDirectoryW(wide, null) != 0;
        base.rvn_free(wide);
        return @intFromBool(ok);
    } else {
        return @intFromBool(libc.mkdir(path, 0o777) == 0);
    }
}

export fn rvn_write_file(path: [*c]const u8, data: ?*const anyopaque, size: usize) c_int {
    if (builtin.os.tag == .windows) {
        const wide = rvn_fs_wide(path);
        if (wide == null) return R_FALSE;
        const file = _wfopen(wide, std.unicode.utf8ToUtf16LeStringLiteral("wb"));
        base.rvn_free(wide);
        const f = file orelse return R_FALSE;
        var ok: c_int = @intFromBool(size == 0 or libc.fwrite(data, 1, size, f) == size);
        if (libc.fclose(f) != 0) ok = R_FALSE;
        return ok;
    } else {
        const file = libc.fopen(path, "wb") orelse return R_FALSE;
        var ok: c_int = @intFromBool(size == 0 or libc.fwrite(data, 1, size, file) == size);
        if (libc.fclose(file) != 0) ok = R_FALSE;
        return ok;
    }
}

/// Opens a URL with the desktop's default application. R_FALSE when it cannot be started.
export fn Ropen_url(url: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        if (url == null or url[0] == 0) return R_FALSE;
        const wide = rvn_fs_wide(url);
        if (wide == null) return R_FALSE;
        const result = ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), wide, null, null, SW_SHOWNORMAL);
        base.rvn_free(wide);
        const code: usize = if (result) |p| @intFromPtr(p) else 0;
        return @intFromBool(@as(isize, @bitCast(code)) > 32);
    } else {
        if (url == null or url[0] == 0) return R_FALSE;
        const child = libc.fork();
        if (child < 0) return R_FALSE;
        if (child == 0) {
            // a grandchild runs the opener, so that nothing is left to wait for
            const opener = libc.fork();
            if (opener == 0) {
                if (builtin.os.tag.isDarwin()) {
                    _ = libc.execlp("open", "open", url, @as([*c]const u8, null));
                } else {
                    _ = libc.execlp("xdg-open", "xdg-open", url, @as([*c]const u8, null));
                }
                libc._exit(127);
            }
            libc._exit(if (opener < 0) 1 else 0);
        }
        var status: c_int = 0;
        _ = libc.waitpid(child, &status, 0);
        return @intFromBool(WIFEXITED(status) and WEXITSTATUS(status) == 0);
    }
}

/// A folder the user goes to often: home, desktop, documents, a drive...
export fn rvn_fs_places(places: [*c][*c]fs.rvn_place_t, count: [*c]u32) void {
    if (builtin.os.tag == .windows) {
        const home = rvn_path_home();
        var cap: u32 = 0;
        const drives = GetLogicalDrives();
        var i: c_int = 0;

        places.* = null;
        count.* = 0;
        rvn_places_add(places, count, &cap, "Home", base.rvn_strdup(home));
        rvn_places_add(places, count, &cap, "Desktop", rvn_places_home_folder(home, "Desktop"));
        rvn_places_add(places, count, &cap, "Documents", rvn_places_home_folder(home, "Documents"));
        rvn_places_add(places, count, &cap, "Downloads", rvn_places_home_folder(home, "Downloads"));
        rvn_places_add(places, count, &cap, "Pictures", rvn_places_home_folder(home, "Pictures"));
        while (i < 26) : (i += 1) {
            var drive: [4]u8 = undefined;
            if ((drives & (@as(DWORD, 1) << @as(u5, @intCast(i)))) == 0) continue;
            drive[0] = @intCast('A' + i);
            drive[1] = ':';
            drive[2] = '\\';
            drive[3] = 0;
            rvn_places_add(places, count, &cap, &drive, base.rvn_strdup(&drive));
        }
        base.rvn_free(home);
    } else {
        const home = rvn_path_home();
        var cap: u32 = 0;

        places.* = null;
        count.* = 0;
        rvn_places_add(places, count, &cap, "Home", base.rvn_strdup(home));
        rvn_places_add(places, count, &cap, "Desktop", rvn_places_home_folder(home, "Desktop"));
        rvn_places_add(places, count, &cap, "Documents", rvn_places_home_folder(home, "Documents"));
        rvn_places_add(places, count, &cap, "Downloads", rvn_places_home_folder(home, "Downloads"));
        rvn_places_add(places, count, &cap, "Pictures", rvn_places_home_folder(home, "Pictures"));
        rvn_places_add(places, count, &cap, "Computer", base.rvn_strdup("/"));
        base.rvn_free(home);
    }
}

export fn rvn_is_http_url(value: [*c]const u8) c_int {
    if (value == null) return R_FALSE;
    return @intFromBool(base.rvn_strnicmp(value, "https://", 8) == 0 or base.rvn_strnicmp(value, "http://", 7) == 0);
}

/// Downloads a URL into an rvn_alloc'ed buffer. Limited to 32 MiB and 20 seconds.
export fn rvn_fs_download_url(url: [*c]const u8, data: [*c][*c]u8, size: [*c]usize) c_int {
    if (builtin.os.tag == .windows) {
        var wide_url: [*c]WCHAR = null;
        var parts: URL_COMPONENTS = undefined;
        var session: HANDLE = null;
        var connection: HANDLE = null;
        var request: HANDLE = null;
        var host: [*c]WCHAR = null;
        var object: [*c]WCHAR = null;
        var status: DWORD = 0;
        var status_size: DWORD = @sizeOf(DWORD);
        var read_count: DWORD = 0;
        var bytes: [*c]u8 = null;
        var used: usize = 0;
        var cap: usize = 0;
        var ok: c_int = R_FALSE;
        var chunk: [*c]u8 = null; // uint8_t chunk[8192], on the heap (see the POSIX branch)
        if (data != null) data.* = null;
        if (size != null) size.* = 0;
        if (url == null or data == null or size == null or rvn_is_http_url(url) == 0) return R_FALSE;
        // every "goto done" of the C file is a break to this label; the cleanup follows it
        done: {
            chunk = @ptrCast(@alignCast(base.rvn_alloc(8192)));
            wide_url = rvn_fs_wide(url);
            if (wide_url == null) break :done;
            parts = std.mem.zeroes(URL_COMPONENTS);
            parts.dwStructSize = @sizeOf(URL_COMPONENTS);
            parts.dwSchemeLength = std.math.maxInt(DWORD);
            parts.dwHostNameLength = std.math.maxInt(DWORD);
            parts.dwUrlPathLength = std.math.maxInt(DWORD);
            parts.dwExtraInfoLength = std.math.maxInt(DWORD);
            if (WinHttpCrackUrl(wide_url, 0, 0, &parts) == 0) break :done;
            host = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(WCHAR) * (@as(usize, parts.dwHostNameLength) + 1))));
            _ = libc.memcpy(host, parts.lpszHostName, @sizeOf(WCHAR) * @as(usize, parts.dwHostNameLength));
            host[parts.dwHostNameLength] = 0;
            {
                const path_len: usize = if (parts.dwUrlPathLength != 0) parts.dwUrlPathLength else 1;
                const object_len: usize = path_len + parts.dwExtraInfoLength;
                object = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(WCHAR) * (object_len + 1))));
                if (parts.dwUrlPathLength != 0) {
                    _ = libc.memcpy(object, parts.lpszUrlPath, @sizeOf(WCHAR) * @as(usize, parts.dwUrlPathLength));
                } else {
                    object[0] = '/';
                }
                if (parts.dwExtraInfoLength != 0) {
                    _ = libc.memcpy(object + path_len, parts.lpszExtraInfo, @sizeOf(WCHAR) * @as(usize, parts.dwExtraInfoLength));
                }
                object[object_len] = 0;
            }
            session = WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral("Raven/0.1"), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0);
            if (session == null) break :done;
            _ = WinHttpSetTimeouts(session, 5000, 5000, 10000, 10000);
            connection = WinHttpConnect(session, host, parts.nPort, 0);
            if (connection == null) break :done;
            request = WinHttpOpenRequest(
                connection,
                std.unicode.utf8ToUtf16LeStringLiteral("GET"),
                object,
                null,
                null,
                null,
                if (parts.nScheme == INTERNET_SCHEME_HTTPS) WINHTTP_FLAG_SECURE else 0,
            );
            if (request == null) break :done;
            if (WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0 or WinHttpReceiveResponse(request, null) == 0) break :done;
            if (WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null) == 0 or
                status < 200 or status >= 300)
            {
                break :done;
            }
            while (true) {
                if (WinHttpReadData(request, chunk, 8192, &read_count) == 0) break :done;
                if (read_count == 0) break;
                const count: usize = read_count;
                if (used + count > RVN_FS_DOWNLOAD_MAX) break :done;
                if (used + count > cap) {
                    var next: usize = if (cap != 0) cap * 2 else 16384;
                    while (next < used + count) next *= 2;
                    if (next > RVN_FS_DOWNLOAD_MAX) next = RVN_FS_DOWNLOAD_MAX;
                    bytes = @ptrCast(@alignCast(base.rvn_realloc(bytes, next)));
                    cap = next;
                }
                _ = libc.memcpy(bytes + used, chunk, count);
                used += count;
            }
            if (used == 0) break :done;
            data.* = bytes;
            size.* = used;
            bytes = null;
            ok = R_TRUE;
        }
        if (request != null) _ = WinHttpCloseHandle(request);
        if (connection != null) _ = WinHttpCloseHandle(connection);
        if (session != null) _ = WinHttpCloseHandle(session);
        base.rvn_free(wide_url);
        base.rvn_free(host);
        base.rvn_free(object);
        base.rvn_free(chunk);
        base.rvn_free(bytes);
        return ok;
    } else {
        var pipes: [2]c_int = .{ -1, -1 };
        var bytes: [*c]u8 = null;
        var used: usize = 0;
        var cap: usize = 0;
        var status: c_int = 0;
        var ok: c_int = R_FALSE;
        var overflow: c_int = R_FALSE;
        if (data != null) data.* = null;
        if (size != null) size.* = 0;
        if (url == null or data == null or size == null or rvn_is_http_url(url) == 0) return R_FALSE;
        if (libc.pipe(&pipes) != 0) return R_FALSE;
        const child = libc.fork();
        if (child < 0) {
            _ = libc.close(pipes[0]);
            _ = libc.close(pipes[1]);
            return R_FALSE;
        }
        if (child == 0) {
            _ = libc.close(pipes[0]);
            if (libc.dup2(pipes[1], STDOUT_FILENO) < 0) libc._exit(126);
            _ = libc.close(pipes[1]);
            const null_fd = libc.open("/dev/null", O_WRONLY);
            if (null_fd >= 0) {
                _ = libc.dup2(null_fd, STDERR_FILENO);
                _ = libc.close(null_fd);
            }
            _ = libc.execlp(
                "curl",
                "curl",
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--max-redirs",
                "5",
                "--max-time",
                "20",
                "--max-filesize",
                "33554432",
                "--proto",
                "=http,https",
                "--proto-redir",
                "=http,https",
                "--output",
                "-",
                "--",
                url,
                @as([*c]const u8, null),
            );
            libc._exit(127);
        }
        _ = libc.close(pipes[1]);
        // uint8_t chunk[8192], on the heap (a stack frame this big needs a stack probe the C link line does not provide)
        const chunk: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(8192)));
        while (true) {
            const n = libc.read(pipes[0], chunk, 8192);
            if (n < 0) {
                if (errnoValue() == EINTR) continue;
                break;
            }
            if (n == 0) break;
            const count: usize = @intCast(n);
            if (used + count > RVN_FS_DOWNLOAD_MAX) {
                overflow = R_TRUE;
                _ = std.c.kill(child, std.c.SIG.KILL);
                break;
            }
            if (used + count > cap) {
                var next: usize = if (cap != 0) cap * 2 else 16384;
                while (next < used + count) next *= 2;
                if (next > RVN_FS_DOWNLOAD_MAX) next = RVN_FS_DOWNLOAD_MAX;
                bytes = @ptrCast(@alignCast(base.rvn_realloc(bytes, next)));
                cap = next;
            }
            _ = libc.memcpy(bytes + used, chunk, count);
            used += count;
        }
        _ = libc.close(pipes[0]);
        while (libc.waitpid(child, &status, 0) < 0 and errnoValue() == EINTR) {}
        base.rvn_free(chunk);
        if (overflow == 0 and WIFEXITED(status) and WEXITSTATUS(status) == 0 and used > 0) {
            data.* = bytes;
            size.* = used;
            bytes = null;
            ok = R_TRUE;
        }
        base.rvn_free(bytes);
        return ok;
    }
}
