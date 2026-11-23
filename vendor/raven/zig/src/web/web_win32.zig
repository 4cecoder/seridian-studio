// Translated to Zig from vendor/raven/web/src/web_win32.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven Web - web_win32.c
// Windows: the browser process and its two pipes, the reading thread,
// folders.
//
// The browser is told the handles of its ends of the pipes on its command
// line (--remote-debugging-io-pipes), and inherits them. It is put in a job
// that is closed with the application, so that it never outlives it.
//
// The C file is wrapped in `#if defined(_WIN32)`: the functions are exported only when the
// target is Windows (comptime block at the end); on other systems this file exports nothing.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const web = @import("web_internal_h.zig");
const libc = @import("../sys/libc.zig");

// Win32 API (windows.h, process.h, wchar.h), declared by hand. Handles are pointers, DWORD is u32,
// BOOL is c_int, WCHAR (wchar_t on Windows) is u16.
const HANDLE = ?*anyopaque;
const DWORD = u32;
const BOOL = c_int;
const UINT = c_uint;
const WORD = u16;

const TRUE: BOOL = 1;
const CP_UTF8: UINT = 65001;
const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
const CREATE_SUSPENDED: DWORD = 0x00000004;
const CREATE_NO_WINDOW: DWORD = 0x08000000;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
// JOBOBJECTINFOCLASS (an enum)
const JobObjectExtendedLimitInformation: c_int = 9;
const WAIT_OBJECT_0: DWORD = 0;
const INFINITE: DWORD = 0xFFFFFFFF;
const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
const FILE_ATTRIBUTE_READONLY: DWORD = 0x00000001;
const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x00000010;
const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x00000400;
const MAX_PATH = 260;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64, // LARGE_INTEGER
    PerJobUserTimeLimit: i64, // LARGE_INTEGER
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: usize,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
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
    lpReserved2: ?*u8,
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
    cFileName: [MAX_PATH]u16,
    cAlternateFileName: [14]u16,
};

// CRITICAL_SECTION (RTL_CRITICAL_SECTION, winnt.h)
const CRITICAL_SECTION = extern struct {
    DebugInfo: ?*anyopaque,
    LockCount: c_long,
    RecursionCount: c_long,
    OwningThread: HANDLE,
    LockSemaphore: HANDLE,
    SpinCount: usize,
};

comptime {
    if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64) {
        std.debug.assert(@sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) == 144);
        std.debug.assert(@sizeOf(STARTUPINFOW) == 104);
        std.debug.assert(@sizeOf(PROCESS_INFORMATION) == 24);
        std.debug.assert(@sizeOf(WIN32_FIND_DATAW) == 592);
        std.debug.assert(@sizeOf(CRITICAL_SECTION) == 40);
    }
}

extern "kernel32" fn MultiByteToWideChar(CodePage: UINT, dwFlags: DWORD, lpMultiByteStr: [*c]const u8, cbMultiByte: c_int, lpWideCharStr: [*c]u16, cchWideChar: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(CodePage: UINT, dwFlags: DWORD, lpWideCharStr: [*c]const u16, cchWideChar: c_int, lpMultiByteStr: [*c]u8, cbMultiByte: c_int, lpDefaultChar: [*c]const u8, lpUsedDefaultChar: [*c]BOOL) callconv(.winapi) c_int;
extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*SECURITY_ATTRIBUTES, nSize: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(lpApplicationName: [*c]const u16, lpCommandLine: [*c]u16, lpProcessAttributes: ?*SECURITY_ATTRIBUTES, lpThreadAttributes: ?*SECURITY_ATTRIBUTES, bInheritHandles: BOOL, dwCreationFlags: DWORD, lpEnvironment: ?*anyopaque, lpCurrentDirectory: [*c]const u16, lpStartupInfo: *STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.winapi) BOOL;
extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*SECURITY_ATTRIBUTES, lpName: [*c]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetInformationJobObject(hJob: HANDLE, JobObjectInformationClass: c_int, lpJobObjectInformation: ?*anyopaque, cbJobObjectInformationLength: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: ?*const anyopaque, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: ?*anyopaque, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn InitializeCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn DeleteCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn EnterCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn LeaveCriticalSection(lpCriticalSection: *CRITICAL_SECTION) callconv(.winapi) void;
extern "kernel32" fn GetFileAttributesW(lpFileName: [*c]const u16) callconv(.winapi) DWORD;
extern "kernel32" fn SetFileAttributesW(lpFileName: [*c]const u16, dwFileAttributes: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*c]const u16, lpBuffer: [*c]u16, nSize: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetTempPathW(nBufferLength: DWORD, lpBuffer: [*c]u16) callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
extern "kernel32" fn GetTickCount() callconv(.winapi) DWORD;
extern "kernel32" fn CreateDirectoryW(lpPathName: [*c]const u16, lpSecurityAttributes: ?*SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;
extern "kernel32" fn RemoveDirectoryW(lpPathName: [*c]const u16) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteFileW(lpFileName: [*c]const u16) callconv(.winapi) BOOL;
extern "kernel32" fn FindFirstFileW(lpFileName: [*c]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetFullPathNameW(lpFileName: [*c]const u16, nBufferLength: DWORD, lpBuffer: [*c]u16, lpFilePart: [*c][*c]u16) callconv(.winapi) DWORD;

// uintptr_t _beginthreadex(void*, unsigned, unsigned (__stdcall*)(void*), void*, unsigned, unsigned*)  (process.h)
extern "c" fn _beginthreadex(
    security: ?*anyopaque,
    stack_size: c_uint,
    start_address: *const fn (arg: ?*anyopaque) callconv(.winapi) c_uint,
    arglist: ?*anyopaque,
    initflag: c_uint,
    thrdaddr: ?*c_uint,
) usize;

// C library (string.h, wchar.h, stdio.h): not in libc.zig
extern "c" fn strpbrk(s: [*c]const u8, accept: [*c]const u8) [*c]u8;
extern "c" fn wcslen(s: [*c]const u16) usize;
extern "c" fn wcscpy(dst: [*c]u16, src: [*c]const u16) [*c]u16;
extern "c" fn wcscat(dst: [*c]u16, src: [*c]const u16) [*c]u16;
extern "c" fn wcscmp(a: [*c]const u16, b: [*c]const u16) c_int;
extern "c" fn _snwprintf(buffer: [*c]u16, count: usize, format: [*c]const u16, ...) c_int;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

// ---------------------------------------------------------------------------
//  Text: UTF-8 here, UTF-16 for Windows
// ---------------------------------------------------------------------------

fn rw_wide(text: [*c]const u8) [*c]u16 {
    var length: c_int = undefined;
    var wide: [*c]u16 = undefined;
    if (text == null) return null;
    length = MultiByteToWideChar(CP_UTF8, 0, text, -1, null, 0);
    if (length <= 0) return null;
    wide = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(u16) * @as(usize, @intCast(length)))));
    if (wide != null) _ = MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, length);
    return wide;
}

fn rw_narrow(wide: [*c]const u16) [*c]u8 {
    var length: c_int = undefined;
    var text: [*c]u8 = undefined;
    if (wide == null) return null;
    length = WideCharToMultiByte(CP_UTF8, 0, wide, -1, null, 0, null, null);
    if (length <= 0) return null;
    text = @ptrCast(web.rw_alloc(@as(usize, @intCast(length))));
    if (text != null) _ = WideCharToMultiByte(CP_UTF8, 0, wide, -1, text, length, null, null);
    return text;
}

// ---------------------------------------------------------------------------
//  Process
// ---------------------------------------------------------------------------

const rw_process_t = extern struct {
    process: HANDLE,
    job: HANDLE,
    to_child: HANDLE,
    from_child: HANDLE,
};

/// One argument, quoted the way the C runtime of the child will read it back.
fn rw_quote(line: [*c]web.rw_text_t, argument: [*c]const u8) void {
    var cursor: [*c]const u8 = undefined;
    var slashes: c_int = 0;
    if (line.*.length != 0) web.rw_text_puts(line, " ");
    if (argument[0] != 0 and strpbrk(argument, " \t\"") == null) {
        web.rw_text_puts(line, argument);
        return;
    }
    web.rw_text_puts(line, "\"");
    cursor = argument;
    while (cursor.* != 0) : (cursor += 1) {
        if (cursor.* == '\\') {
            slashes += 1;
        } else if (cursor.* == '"') {
            // the backslashes before a quote are doubled, and the quote escaped
            while (blk: {
                const before = slashes;
                slashes -= 1;
                break :blk before > 0;
            }) web.rw_text_puts(line, "\\");
            web.rw_text_puts(line, "\\");
            slashes = 0;
        } else {
            slashes = 0;
        }
        web.rw_text_add(line, cursor, 1);
    }
    // those before the closing quote are doubled too
    while (blk: {
        const before = slashes;
        slashes -= 1;
        break :blk before > 0;
    }) web.rw_text_puts(line, "\\");
    web.rw_text_puts(line, "\"");
}

fn rw_process_start(arguments: [*c]const [*c]const u8) callconv(.c) [*c]rw_process_t {
    var child_read: HANDLE = null;
    var our_write: HANDLE = null;
    var our_read: HANDLE = null;
    var child_write: HANDLE = null;
    var process: [*c]rw_process_t = undefined;
    var wide: [*c]u16 = undefined;
    var i: c_int = undefined;
    var started: c_int = undefined;

    var inherit = std.mem.zeroes(SECURITY_ATTRIBUTES);
    inherit.nLength = @sizeOf(SECURITY_ATTRIBUTES);
    inherit.bInheritHandle = TRUE;
    if (CreatePipe(&child_read, &our_write, &inherit, 0) == 0) return null;
    if (CreatePipe(&our_read, &child_write, &inherit, 1 << 20) == 0) {
        _ = CloseHandle(child_read);
        _ = CloseHandle(our_write);
        return null;
    }
    // our ends stay ours
    _ = SetHandleInformation(our_write, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(our_read, HANDLE_FLAG_INHERIT, 0);

    var line = std.mem.zeroes(web.rw_text_t);
    i = 0;
    while (arguments[@intCast(i)] != null) : (i += 1) rw_quote(&line, arguments[@intCast(i)]);
    web.rw_text_printf(&line, " --remote-debugging-io-pipes=%u,%u", @as(c_uint, @truncate(@intFromPtr(child_read))), @as(c_uint, @truncate(@intFromPtr(child_write))));
    wide = rw_wide(line.data);
    web.rw_text_free(&line);

    var startup = std.mem.zeroes(STARTUPINFOW);
    startup.cb = @sizeOf(STARTUPINFOW);
    var information = std.mem.zeroes(PROCESS_INFORMATION);
    started = @intFromBool(wide != null and CreateProcessW(null, wide, null, null, TRUE, CREATE_NO_WINDOW | CREATE_SUSPENDED, null, null, &startup, &information) != 0);
    web.rw_free(wide);
    _ = CloseHandle(child_read);
    _ = CloseHandle(child_write);
    if (started == 0) {
        _ = CloseHandle(our_write);
        _ = CloseHandle(our_read);
        return null;
    }

    process = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_process_t))));
    if (process == null) {
        _ = TerminateProcess(information.hProcess, 1);
        _ = CloseHandle(information.hThread);
        _ = CloseHandle(information.hProcess);
        _ = CloseHandle(our_write);
        _ = CloseHandle(our_read);
        return null;
    }
    process.*.process = information.hProcess;
    process.*.to_child = our_write;
    process.*.from_child = our_read;
    // the browser and the processes it starts die when the job closes: at the latest when the application ends
    process.*.job = CreateJobObjectW(null, null);
    if (process.*.job != null) {
        var limits = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        _ = SetInformationJobObject(process.*.job, JobObjectExtendedLimitInformation, &limits, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        _ = AssignProcessToJobObject(process.*.job, process.*.process);
    }
    _ = ResumeThread(information.hThread);
    _ = CloseHandle(information.hThread);
    return process;
}

fn rw_process_write(process: [*c]rw_process_t, data: ?*const anyopaque, size_in: usize) callconv(.c) c_int {
    var size = size_in;
    var cursor: [*c]const u8 = @ptrCast(data);
    while (size > 0) {
        var written: DWORD = 0;
        const chunk: DWORD = if (size > 0x100000) 0x100000 else @intCast(size);
        if (process.*.to_child == null or WriteFile(process.*.to_child, cursor, chunk, &written, null) == 0 or written == 0) return 0;
        cursor += written;
        size -= written;
    }
    return 1;
}

fn rw_process_read(process: [*c]rw_process_t, buffer: ?*anyopaque, size: usize) callconv(.c) c_int {
    var got: DWORD = 0;
    if (ReadFile(process.*.from_child, buffer, if (size > 0x100000) 0x100000 else @intCast(size), &got, null) == 0) return 0;
    return @intCast(got);
}

fn rw_process_hang_up(process: [*c]rw_process_t) callconv(.c) void {
    // the child sees the end of its input, and the read that waits in the other thread gives up
    if (process.*.to_child != null) {
        // (a write that waits in the other thread gives up first)
        _ = CancelIoEx(process.*.to_child, null);
        _ = CloseHandle(process.*.to_child);
        process.*.to_child = null;
    }
    _ = CancelIoEx(process.*.from_child, null);
}

fn rw_process_stop(process: [*c]rw_process_t) callconv(.c) void {
    rw_process_hang_up(process);
    // a browser leaves by itself when its pipe closes: it is given two seconds
    if (WaitForSingleObject(process.*.process, 2000) != WAIT_OBJECT_0) _ = TerminateProcess(process.*.process, 1);
    if (process.*.job != null) _ = CloseHandle(process.*.job);
    _ = CloseHandle(process.*.from_child);
    _ = CloseHandle(process.*.process);
    web.rw_free(process);
}

// ---------------------------------------------------------------------------
//  Thread and lock
// ---------------------------------------------------------------------------

const rw_thread_t = extern struct {
    handle: HANDLE,
    function: ?*const fn (?*anyopaque) callconv(.c) void,
    argument: ?*anyopaque,
};

fn rw_thread_main(argument: ?*anyopaque) callconv(.winapi) c_uint {
    const thread: [*c]rw_thread_t = @ptrCast(@alignCast(argument));
    thread.*.function.?(thread.*.argument);
    return 0;
}

fn rw_thread_start(function: ?*const fn (?*anyopaque) callconv(.c) void, argument: ?*anyopaque) callconv(.c) [*c]rw_thread_t {
    const thread: [*c]rw_thread_t = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_thread_t))));
    if (thread == null) return null;
    thread.*.function = function;
    thread.*.argument = argument;
    thread.*.handle = @ptrFromInt(_beginthreadex(null, 0, &rw_thread_main, thread, 0, null));
    if (thread.*.handle == null) {
        web.rw_free(thread);
        return null;
    }
    return thread;
}

fn rw_thread_join(thread: [*c]rw_thread_t) callconv(.c) void {
    if (thread == null) return;
    _ = WaitForSingleObject(thread.*.handle, INFINITE);
    _ = CloseHandle(thread.*.handle);
    web.rw_free(thread);
}

const rw_mutex_t = extern struct {
    section: CRITICAL_SECTION,
};

fn rw_mutex_create() callconv(.c) [*c]rw_mutex_t {
    const mutex: [*c]rw_mutex_t = @ptrCast(@alignCast(web.rw_alloc(@sizeOf(rw_mutex_t))));
    if (mutex != null) InitializeCriticalSection(&mutex.*.section);
    return mutex;
}

fn rw_mutex_destroy(mutex: [*c]rw_mutex_t) callconv(.c) void {
    if (mutex == null) return;
    DeleteCriticalSection(&mutex.*.section);
    web.rw_free(mutex);
}

fn rw_mutex_lock(mutex: [*c]rw_mutex_t) callconv(.c) void {
    EnterCriticalSection(&mutex.*.section);
}

fn rw_mutex_unlock(mutex: [*c]rw_mutex_t) callconv(.c) void {
    LeaveCriticalSection(&mutex.*.section);
}

// ---------------------------------------------------------------------------
//  Files
// ---------------------------------------------------------------------------

fn rw_is_program(path: [*c]const u8) callconv(.c) c_int {
    const wide = rw_wide(path);
    const attributes: DWORD = if (wide != null and wide[0] != 0) GetFileAttributesW(wide) else INVALID_FILE_ATTRIBUTES;
    web.rw_free(wide);
    return @intFromBool(attributes != INVALID_FILE_ATTRIBUTES and (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0);
}

fn rw_find_browser() callconv(.c) [*c]u8 {
    const roots = [_][*c]const u16{ L("ProgramFiles(x86)"), L("ProgramFiles"), L("LocalAppData") };
    // Edge first: it is on every Windows 10 and 11
    const programs = [_][*c]const u16{
        L("\\Microsoft\\Edge\\Application\\msedge.exe"),
        L("\\Google\\Chrome\\Application\\chrome.exe"),
        L("\\Chromium\\Application\\chrome.exe"),
        L("\\BraveSoftware\\Brave-Browser\\Application\\brave.exe"),
        L("\\Vivaldi\\Application\\vivaldi.exe"),
    };
    var root: [MAX_PATH]u16 = undefined;
    var path: [MAX_PATH * 2]u16 = undefined;
    var p: usize = 0;
    while (p < programs.len) : (p += 1) {
        var r: usize = 0;
        while (r < roots.len) : (r += 1) {
            const length: DWORD = GetEnvironmentVariableW(roots[r], &root, MAX_PATH);
            var attributes: DWORD = undefined;
            if (length == 0 or length >= MAX_PATH) continue;
            if (wcslen(&root) + wcslen(programs[p]) + 1 > path.len) continue;
            _ = wcscpy(&path, &root);
            _ = wcscat(&path, programs[p]);
            attributes = GetFileAttributesW(&path);
            if (attributes != INVALID_FILE_ATTRIBUTES and (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0) return rw_narrow(&path);
        }
    }
    return null;
}

fn rw_temp_folder() callconv(.c) [*c]u8 {
    var base: [MAX_PATH]u16 = undefined;
    var path: [MAX_PATH + 64]u16 = undefined;
    const length: DWORD = GetTempPathW(MAX_PATH, &base);
    var attempt: c_int = undefined;
    if (length == 0 or length >= MAX_PATH) return null;
    attempt = 0;
    while (attempt < 16) : (attempt += 1) {
        _ = _snwprintf(&path, path.len, L("%lsraven-web-%lu-%lu"), @as([*c]const u16, &base), @as(c_ulong, GetCurrentProcessId()), @as(c_ulong, GetTickCount()) +% @as(c_ulong, @intCast(attempt)));
        path[path.len - 1] = 0;
        if (CreateDirectoryW(&path, null) != 0) return rw_narrow(&path);
    }
    return null;
}

fn rw_remove_folder_wide(path: [*c]const u16) void {
    var found: WIN32_FIND_DATAW = undefined;
    var pattern: [MAX_PATH * 2]u16 = undefined;
    var search: HANDLE = undefined;
    if (wcslen(path) + 3 > pattern.len) return;
    _ = wcscpy(&pattern, path);
    _ = wcscat(&pattern, L("\\*"));
    search = FindFirstFileW(&pattern, &found);
    if (search != INVALID_HANDLE_VALUE) {
        while (true) {
            body: {
                var child: [MAX_PATH * 2]u16 = undefined;
                if (wcscmp(&found.cFileName, L(".")) == 0 or wcscmp(&found.cFileName, L("..")) == 0) break :body; // continue
                if (wcslen(path) + wcslen(&found.cFileName) + 2 > child.len) break :body; // continue
                _ = wcscpy(&child, path);
                _ = wcscat(&child, L("\\"));
                _ = wcscat(&child, &found.cFileName);
                // (a link to a folder is removed, never followed)
                if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 and (found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
                    rw_remove_folder_wide(&child);
                } else {
                    if ((found.dwFileAttributes & FILE_ATTRIBUTE_READONLY) != 0) _ = SetFileAttributesW(&child, found.dwFileAttributes & ~FILE_ATTRIBUTE_READONLY);
                    if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                        _ = RemoveDirectoryW(&child);
                    } else {
                        _ = DeleteFileW(&child);
                    }
                }
            }
            if (FindNextFileW(search, &found) == 0) break;
        }
        _ = FindClose(search);
    }
    _ = RemoveDirectoryW(path);
}

fn rw_remove_folder(path: [*c]const u8) callconv(.c) void {
    const wide = rw_wide(path);
    if (wide != null and wide[0] != 0) rw_remove_folder_wide(wide);
    web.rw_free(wide);
}

fn rw_file_url(path: [*c]const u8) callconv(.c) [*c]u8 {
    const wide = rw_wide(path);
    var absolute: [MAX_PATH * 2]u16 = undefined;
    var narrow: [*c]u8 = undefined;
    var cursor: [*c]const u8 = undefined;
    var length: DWORD = undefined;
    if (wide == null) return null;
    length = GetFullPathNameW(wide, absolute.len, &absolute, null);
    web.rw_free(wide);
    if (length == 0 or length >= absolute.len) return null;
    narrow = rw_narrow(&absolute);
    if (narrow == null) return null;
    var url = std.mem.zeroes(web.rw_text_t);
    // "C:\folder\page.html" -> "file:///C:/folder/page.html"; "\\server\share" -> "file://server/share"
    if (narrow[0] == '\\' and narrow[1] == '\\') {
        web.rw_text_puts(&url, "file:");
    } else {
        web.rw_text_puts(&url, "file:///");
    }
    cursor = narrow;
    while (cursor.* != 0) : (cursor += 1) {
        const c: u8 = cursor.*;
        if (c == '\\') {
            web.rw_text_puts(&url, "/");
        } else if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or libc.strchr("/-_.~:", c) != null) {
            web.rw_text_add(&url, @ptrCast(&c), 1);
        } else {
            web.rw_text_printf(&url, "%%%02X", @as(c_uint, c));
        }
    }
    web.rw_free(narrow);
    return url.data;
}

fn rw_needs_no_sandbox() callconv(.c) c_int {
    return 0;
}

// #else typedef int rw_win32_unused_t; #endif /* _WIN32 */
// (on other systems nothing is exported)
comptime {
    if (builtin.os.tag == .windows) {
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
