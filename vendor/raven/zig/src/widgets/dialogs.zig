// Translated to Zig from vendor/raven/src/widgets/dialogs.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - widgets/dialogs.c
// Dialogs shown over a window, message boxes and file dialogs.
//
// A file dialog is the one of the operating system where there is one:
//   Win32   GetOpenFileNameW / GetSaveFileNameW, IFileOpenDialog for folders
//   Linux   zenity or kdialog, started as a child process
// and otherwise (or with R_FILE_DIALOG_RAVEN) a FileBrowser in a dialog of
// the window.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../core/base_h.zig");
const fs = @import("../core/fs_h.zig");
const ctx_h = @import("../core/context_h.zig");
const widget_h = @import("../widget/widget_h.zig");
const plat_h = @import("../platform/platform_h.zig");
const ext = @import("externs.zig");
const libc = @import("../sys/libc.zig");

// ---------------------------------------------------------------------------
//  Win32 types and functions (windows.h, commdlg.h, objbase.h, shobjidl.h),
//  declared by hand. Only analysed when the target is Windows.
// ---------------------------------------------------------------------------

const WCHAR = u16;
const BOOL = c_int;
const DWORD = u32;
const WORD = u16;
const UINT = c_uint;
const HRESULT = i32;
const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const LPWSTR = [*c]WCHAR;
const LPCWSTR = [*c]const WCHAR;
const FILEOPENDIALOGOPTIONS = u32;
const SIGDN = u32;

const CP_UTF8: UINT = 65001;
const COINIT_APARTMENTTHREADED: DWORD = 0x2;
const COINIT_DISABLE_OLE1DDE: DWORD = 0x4;
const CLSCTX_INPROC_SERVER: DWORD = 0x1;
const ERROR_CANCELLED: u32 = 1223;
const FOS_NOCHANGEDIR: FILEOPENDIALOGOPTIONS = 0x8;
const FOS_PICKFOLDERS: FILEOPENDIALOGOPTIONS = 0x20;
const FOS_FORCEFILESYSTEM: FILEOPENDIALOGOPTIONS = 0x40;
const SIGDN_FILESYSPATH: SIGDN = 0x80058000;
const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
const OFN_HIDEREADONLY: DWORD = 0x00000004;
const OFN_NOCHANGEDIR: DWORD = 0x00000008;
const OFN_ALLOWMULTISELECT: DWORD = 0x00000200;
const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_FILEMUSTEXIST: DWORD = 0x00001000;
const OFN_FORCESHOWHIDDEN: DWORD = 0x10000000;
const OFN_EXPLORER: DWORD = 0x00080000;

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

const OPENFILENAMEW = extern struct {
    lStructSize: DWORD,
    hwndOwner: HWND,
    hInstance: HINSTANCE,
    lpstrFilter: LPCWSTR,
    lpstrCustomFilter: LPWSTR,
    nMaxCustFilter: DWORD,
    nFilterIndex: DWORD,
    lpstrFile: LPWSTR,
    nMaxFile: DWORD,
    lpstrFileTitle: LPWSTR,
    nMaxFileTitle: DWORD,
    lpstrInitialDir: LPCWSTR,
    lpstrTitle: LPCWSTR,
    Flags: DWORD,
    nFileOffset: WORD,
    nFileExtension: WORD,
    lpstrDefExt: LPCWSTR,
    lCustData: isize,
    lpfnHook: ?*anyopaque,
    lpTemplateName: LPCWSTR,
    pvReserved: ?*anyopaque,
    dwReserved: DWORD,
    FlagsEx: DWORD,
};

/// IShellItem, the vtable in the order of shobjidl.h (IUnknown, then IShellItem).
const IShellItem = extern struct {
    lpVtbl: *const IShellItemVtbl,
};
const IShellItemVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (self: *IShellItem) callconv(.winapi) u32,
    BindToHandler: *const anyopaque,
    GetParent: *const anyopaque,
    GetDisplayName: *const fn (self: *IShellItem, sigdn: SIGDN, name: *LPWSTR) callconv(.winapi) HRESULT,
    GetAttributes: *const anyopaque,
    Compare: *const anyopaque,
};

/// IFileOpenDialog, the vtable in the order of shobjidl.h (IUnknown, IModalWindow, IFileDialog, IFileOpenDialog).
const IFileOpenDialog = extern struct {
    lpVtbl: *const IFileOpenDialogVtbl,
};
const IFileOpenDialogVtbl = extern struct {
    QueryInterface: *const anyopaque,
    AddRef: *const anyopaque,
    Release: *const fn (self: *IFileOpenDialog) callconv(.winapi) u32,
    Show: *const fn (self: *IFileOpenDialog, parent: HWND) callconv(.winapi) HRESULT,
    SetFileTypes: *const anyopaque,
    SetFileTypeIndex: *const anyopaque,
    GetFileTypeIndex: *const anyopaque,
    Advise: *const anyopaque,
    Unadvise: *const anyopaque,
    SetOptions: *const fn (self: *IFileOpenDialog, options: FILEOPENDIALOGOPTIONS) callconv(.winapi) HRESULT,
    GetOptions: *const fn (self: *IFileOpenDialog, options: *FILEOPENDIALOGOPTIONS) callconv(.winapi) HRESULT,
    SetDefaultFolder: *const anyopaque,
    SetFolder: *const fn (self: *IFileOpenDialog, item: *IShellItem) callconv(.winapi) HRESULT,
    GetFolder: *const anyopaque,
    GetCurrentSelection: *const anyopaque,
    SetFileName: *const anyopaque,
    GetFileName: *const anyopaque,
    SetTitle: *const fn (self: *IFileOpenDialog, title: LPCWSTR) callconv(.winapi) HRESULT,
    SetOkButtonLabel: *const anyopaque,
    SetFileNameLabel: *const anyopaque,
    GetResult: *const fn (self: *IFileOpenDialog, item: *?*IShellItem) callconv(.winapi) HRESULT,
    AddPlace: *const anyopaque,
    SetDefaultExtension: *const anyopaque,
    Close: *const anyopaque,
    SetClientGuid: *const anyopaque,
    ClearClientData: *const anyopaque,
    SetFilter: *const anyopaque,
    GetResults: *const anyopaque,
    GetSelectedItems: *const anyopaque,
};

extern "kernel32" fn MultiByteToWideChar(CodePage: UINT, dwFlags: DWORD, lpMultiByteStr: [*c]const u8, cbMultiByte: c_int, lpWideCharStr: [*c]WCHAR, cchWideChar: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(CodePage: UINT, dwFlags: DWORD, lpWideCharStr: [*c]const WCHAR, cchWideChar: c_int, lpMultiByteStr: [*c]u8, cbMultiByte: c_int, lpDefaultChar: ?*const anyopaque, lpUsedDefaultChar: ?*BOOL) callconv(.winapi) c_int;
extern "comdlg32" fn GetOpenFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn GetSaveFileNameW(lpofn: *OPENFILENAMEW) callconv(.winapi) BOOL;
extern "comdlg32" fn CommDlgExtendedError() callconv(.winapi) DWORD;
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(rclsid: *const GUID, pUnkOuter: ?*anyopaque, dwClsContext: DWORD, riid: *const GUID, ppv: ?*?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
extern "shell32" fn SHCreateItemFromParsingName(pszPath: LPCWSTR, pbc: ?*anyopaque, riid: *const GUID, ppv: ?*?*anyopaque) callconv(.winapi) HRESULT;
extern "c" fn wcslen(s: LPCWSTR) usize;

/// FAILED-free: HRESULT_FROM_WIN32(ERROR_CANCELLED), 0x800704C7.
const HRESULT_FROM_WIN32_CANCELLED: HRESULT = @bitCast(@as(u32, 0x80000000 | (7 << 16) | ERROR_CANCELLED));

// ---------------------------------------------------------------------------
//  POSIX values of the Linux target (fcntl.h, poll.h, unistd.h, errno.h, sys/wait.h)
// ---------------------------------------------------------------------------

const RVN_DIALOG_MAX_ARGS = 48;
const STDOUT_FILENO: c_int = 1;
const STDERR_FILENO: c_int = 2;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const POLLIN = 0x001;
const X_OK: c_int = 1;

// POSIX status macros (sys/wait.h), same values on Linux and macOS.
fn WIFEXITED(status: c_int) bool {
    return (status & 0x7f) == 0;
}
fn WEXITSTATUS(status: c_int) c_int {
    return (status >> 8) & 0xff;
}

// POSIX open and fcntl flags, errno values (fcntl.h, errno.h).
const O_WRONLY: c_int = @bitCast(std.c.O{ .ACCMODE = .WRONLY });
const O_NONBLOCK: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
fn errnoValue() c_int {
    return std.c._errno().*;
}
const EINTR: c_int = @backingInt(std.c.E.INTR);
const EAGAIN: c_int = @backingInt(std.c.E.AGAIN);

/// What the last file dialog returned, and where it was.
const rvn_dialogs_state_t = extern struct {
    paths: [*c][*c]u8,
    count: c_int,
    cap: c_int,
    directory: [*c]u8,
};

var g_dialogs: rvn_dialogs_state_t = std.mem.zeroes(rvn_dialogs_state_t);

fn rvn_dialogs_clear_results() void {
    var i: c_int = 0;
    while (i < g_dialogs.count) : (i += 1) base.rvn_free(g_dialogs.paths[@intCast(i)]);
    g_dialogs.count = 0;
}

fn rvn_dialogs_add_result(path: [*c]const u8) void {
    if (path == null or path[0] == 0) return;
    if (g_dialogs.count + 1 > g_dialogs.cap) {
        g_dialogs.cap = if (g_dialogs.cap != 0) g_dialogs.cap * 2 else 8;
        g_dialogs.paths = @ptrCast(@alignCast(base.rvn_realloc(@ptrCast(g_dialogs.paths), @sizeOf([*c]u8) * @as(usize, @intCast(g_dialogs.cap)))));
    }
    g_dialogs.paths[@intCast(g_dialogs.count)] = base.rvn_strdup(path);
    g_dialogs.count += 1;
}

export fn rvn_dialogs_shutdown() void {
    rvn_dialogs_clear_results();
    base.rvn_free(@ptrCast(g_dialogs.paths));
    base.rvn_free(g_dialogs.directory);
    _ = libc.memset(&g_dialogs, 0, @sizeOf(rvn_dialogs_state_t));
}

// ---------------------------------------------------------------------------
//  Dialogs
// ---------------------------------------------------------------------------

const rvn_dialog_wait_t = extern struct {
    done: c_int,
    result: c_int,
};

fn rvn_dialog_wait_closed(content: raven.Rid, result: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const wait: [*c]rvn_dialog_wait_t = @ptrCast(@alignCast(user_data));
    _ = content;
    wait.*.done = raven.R_TRUE;
    wait.*.result = result;
}

/// One frame of the application, from inside a function that waits.
fn rvn_dialog_frame(timeout: f64) void {
    raven.Rwait_events(timeout);
    ext.rvn_update();
}

/// Shows a dialog and runs the application until it closes.
fn rvn_dialog_wait(window: [*c]widget_h.rvn_window_t, content: [*c]widget_h.rvn_widget_t) c_int {
    var wait: rvn_dialog_wait_t = undefined;
    const window_id = window.*.id;
    const content_id = content.*.id;
    // (called from a timer or a task, the frames must still run)
    const in_update = ext.g_rvn.in_update;

    wait.done = raven.R_FALSE;
    wait.result = 0;
    widget_h.rvn_window_open_dialog(window, content, rvn_dialog_wait_closed, &wait);
    if (widget_h.rvn_window_popup_index(window, content) < 0) {
        // it could not be shown
        if (widget_h.rvn_widget_get(content_id) != null) widget_h.rvn_widget_destroy(content);
        return 0;
    }
    ext.g_rvn.in_update = raven.R_FALSE;
    while (wait.done == 0 and raven.Ris_running() != 0 and widget_h.rvn_window_get(window_id) != null) rvn_dialog_frame(-1.0);
    ext.g_rvn.in_update = in_update;
    if (wait.done == 0) {
        // the application is quitting: nothing may keep a pointer to this stack
        const live = widget_h.rvn_widget_get(content_id);
        if (live != null) _ = widget_h.rvn_window_close_dialog(live, 0);
    }
    return wait.result;
}

/// A window to show a dialog in: the one given, else any, else a new one (*created).
fn rvn_dialog_window(id: raven.Rid, title: [*c]const u8, width: c_int, height: c_int, created: [*c]c_int) [*c]widget_h.rvn_window_t {
    var window = widget_h.rvn_window_get(id);
    var i: u32 = 0;
    created.* = raven.R_FALSE;
    while (window == null and i < ext.g_rvn.windows.used) : (i += 1) {
        const candidate: [*c]widget_h.rvn_window_t = @ptrCast(@alignCast(ext.rvn_pool_at(&ext.g_rvn.windows, i)));
        if (candidate != null and candidate.*.dead == 0 and candidate.*.visible != 0) window = candidate;
    }
    if (window == null) {
        window = widget_h.rvn_window_get(raven.Rwindow_create(title, width, height, raven.R_WINDOW_DEFAULT));
        created.* = @intFromBool(window != null);
    }
    return window;
}

export fn Rdialog_open(window_id: raven.Rid, content_id: raven.Rid, closed: raven.RDialogClosedCallback, user_data: ?*anyopaque) void {
    if (ctx_h.rvn_api_check("Rdialog_open") == 0) return;
    const window = widget_h.rvn_window_check(window_id, "Rdialog_open");
    const content = widget_h.rvn_widget_check(content_id, 0, "Rdialog_open");
    if (window == null or content == null) return;
    widget_h.rvn_window_open_dialog(window, content, closed, user_data);
}

export fn Rdialog_close(id: raven.Rid, result: c_int) void {
    const widget = widget_h.rvn_widget_check(id, 0, "Rdialog_close");
    if (widget == null) return;
    _ = widget_h.rvn_window_close_dialog(widget, result);
}

export fn Rdialog_run(window_id: raven.Rid, content_id: raven.Rid) c_int {
    if (ctx_h.rvn_api_check("Rdialog_run") == 0) return 0;
    const window = widget_h.rvn_window_check(window_id, "Rdialog_run");
    const content = widget_h.rvn_widget_check(content_id, 0, "Rdialog_run");
    if (window == null or content == null) return 0;
    return rvn_dialog_wait(window, content);
}

export fn Rwindow_has_dialog(id: raven.Rid) c_int {
    if (ctx_h.rvn_api_check("Rwindow_has_dialog") == 0) return raven.R_FALSE;
    const window = widget_h.rvn_window_check(id, "Rwindow_has_dialog");
    return @intFromBool(window != null and widget_h.rvn_window_top_dialog(window) != null);
}

// ---------------------------------------------------------------------------
//  Message box
// ---------------------------------------------------------------------------

fn rvn_message_clicked(button: raven.Rid, user_data: ?*anyopaque) callconv(.c) void {
    const widget = widget_h.rvn_widget_get(button);
    if (widget != null) _ = widget_h.rvn_window_close_dialog(widget, @truncate(@as(isize, @bitCast(@intFromPtr(user_data)))));
}

/// Enter presses the main button of the box.
fn rvn_message_event(widget_id: raven.Rid, event: [*c]const raven.REvent, user_data: ?*anyopaque) callconv(.c) c_int {
    const widget = widget_h.rvn_widget_get(widget_id);
    if (widget == null or event.*.type != raven.R_EVENT_KEY_DOWN) return raven.R_FALSE;
    if (event.*.key != raven.R_KEY_ENTER and event.*.key != raven.R_KEY_KP_ENTER) return raven.R_FALSE;
    _ = widget_h.rvn_window_close_dialog(widget, @truncate(@as(isize, @bitCast(@intFromPtr(user_data)))));
    return raven.R_TRUE;
}

fn rvn_message_button(row: [*c]widget_h.rvn_widget_t, text: [*c]const u8, result: raven.RMessageResult, primary: c_int) void {
    const button = widget_h.rvn_widget_create(raven.R_WIDGET_BUTTON);
    _ = ext.rvn_widget_set_attribute(button, "Text", text);
    if (primary != 0) _ = ext.rvn_widget_set_attribute(button, "Style", "Primary");
    button.*.min_size.x = 84.0;
    raven.Rbutton_set_clicked_callback(button.*.id, rvn_message_clicked, @ptrFromInt(@as(usize, result)));
    widget_h.rvn_widget_add_child(row, button, -1);
}

export fn Rmessage_box(window_id: raven.Rid, title: [*c]const u8, text: [*c]const u8, buttons: raven.RMessageButtons) raven.RMessageResult {
    var main_result: raven.RMessageResult = raven.R_MESSAGE_RESULT_OK;
    var created: c_int = undefined;

    if (ctx_h.rvn_api_check("Rmessage_box") == 0) return raven.R_MESSAGE_RESULT_CANCEL;
    if (buttons < raven.R_MESSAGE_OK or buttons > raven.R_MESSAGE_YES_NO_CANCEL) {
        base.rvn_error(raven.R_ERROR_INVALID_ENUM, raven.R_SEVERITY_ERROR, "Rmessage_box: invalid buttons");
        return raven.R_MESSAGE_RESULT_CANCEL;
    }
    const title_text: [*c]const u8 = if (title != null) title else "";
    const window = rvn_dialog_window(window_id, title_text, 460, 240, &created);
    if (window == null) return raven.R_MESSAGE_RESULT_CANCEL;

    const box = widget_h.rvn_widget_create(raven.R_WIDGET_VBOX);
    _ = ext.rvn_widget_set_attribute(box, "Spacing", "12");
    box.*.fixed_size.x = 380.0;
    if (title != null and title[0] != 0) {
        const title_label = widget_h.rvn_widget_create(raven.R_WIDGET_LABEL);
        _ = ext.rvn_widget_set_attribute(title_label, "Text", title);
        _ = ext.rvn_widget_set_attribute(title_label, "TextSize", "17");
        widget_h.rvn_widget_add_child(box, title_label, -1);
    }
    const label = widget_h.rvn_widget_create(raven.R_WIDGET_LABEL);
    _ = ext.rvn_widget_set_attribute(label, "Text", if (text != null) text else "");
    _ = ext.rvn_widget_set_attribute(label, "Wrap", "true");
    label.*.opacity = if (title != null and title[0] != 0) 0.8 else 1.0;
    widget_h.rvn_widget_add_child(box, label, -1);

    const row = widget_h.rvn_widget_create(raven.R_WIDGET_HBOX);
    _ = ext.rvn_widget_set_attribute(row, "Spacing", "8");
    row.*.slot.halign = raven.R_HALIGN_RIGHT;
    row.*.slot.padding.t = 6.0;
    switch (buttons) {
        raven.R_MESSAGE_OK => {
            rvn_message_button(row, "OK", raven.R_MESSAGE_RESULT_OK, raven.R_TRUE);
        },
        raven.R_MESSAGE_OK_CANCEL => {
            rvn_message_button(row, "Cancel", raven.R_MESSAGE_RESULT_CANCEL, raven.R_FALSE);
            rvn_message_button(row, "OK", raven.R_MESSAGE_RESULT_OK, raven.R_TRUE);
        },
        raven.R_MESSAGE_YES_NO => {
            rvn_message_button(row, "No", raven.R_MESSAGE_RESULT_NO, raven.R_FALSE);
            rvn_message_button(row, "Yes", raven.R_MESSAGE_RESULT_YES, raven.R_TRUE);
            main_result = raven.R_MESSAGE_RESULT_YES;
        },
        else => {
            rvn_message_button(row, "Cancel", raven.R_MESSAGE_RESULT_CANCEL, raven.R_FALSE);
            rvn_message_button(row, "No", raven.R_MESSAGE_RESULT_NO, raven.R_FALSE);
            rvn_message_button(row, "Yes", raven.R_MESSAGE_RESULT_YES, raven.R_TRUE);
            main_result = raven.R_MESSAGE_RESULT_YES;
        },
    }
    widget_h.rvn_widget_add_child(box, row, -1);
    // (a panel does not take the mouse, but keys reach the root of a dialog)
    box.*.event_callback = rvn_message_event;
    box.*.event_user = @ptrFromInt(@as(usize, main_result));

    const result = rvn_dialog_wait(window, box);
    if (created != 0 and window.*.dead == 0) widget_h.rvn_window_destroy(window);
    // a question dismissed with Escape is answered "no" when there is no Cancel
    if (result == 0 and buttons == raven.R_MESSAGE_YES_NO) return raven.R_MESSAGE_RESULT_NO;
    return @bitCast(result);
}

// ---------------------------------------------------------------------------
//  File dialog: the browser of Raven in a dialog
// ---------------------------------------------------------------------------

fn rvn_file_dialog_title(desc: [*c]const raven.RFileDialogDesc, mode: raven.RFileBrowserMode) [*c]const u8 {
    if (desc.*.title != null and desc.*.title[0] != 0) return desc.*.title;
    switch (mode) {
        raven.R_FILE_BROWSER_SAVE => return "Save as",
        raven.R_FILE_BROWSER_FOLDER => return "Select a folder",
        else => return if ((desc.*.flags & raven.R_FILE_DIALOG_MULTIPLE) != 0) "Open files" else "Open",
    }
}

fn rvn_file_dialog_accepted(browser: raven.Rid, path: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const widget = widget_h.rvn_widget_get(browser);
    const count = raven.Rfile_browser_get_selection_count(browser);
    var i: c_int = 0;
    var added: c_int = 0;
    _ = user_data;
    rvn_dialogs_clear_results();
    // several files: the whole selection, when the chosen path is part of it
    while (i < count and count > 1) : (i += 1) {
        const selected = raven.Rfile_browser_get_selection(browser, i);
        if (selected != null and fs.rvn_path_is_dir(selected) == 0) {
            rvn_dialogs_add_result(selected);
            added += 1;
        }
    }
    if (added < 2) {
        rvn_dialogs_clear_results();
        rvn_dialogs_add_result(path);
    }
    if (widget != null) _ = widget_h.rvn_window_close_dialog(widget, 1);
}

fn rvn_file_dialog_cancelled(browser: raven.Rid, path: [*c]const u8, user_data: ?*anyopaque) callconv(.c) void {
    const widget = widget_h.rvn_widget_get(browser);
    _ = path;
    _ = user_data;
    if (widget != null) _ = widget_h.rvn_window_close_dialog(widget, 0);
}

fn rvn_file_dialog_raven(desc: [*c]const raven.RFileDialogDesc, mode: raven.RFileBrowserMode, directory: [*c]const u8) void {
    const title = rvn_file_dialog_title(desc, mode);
    var created: c_int = undefined;

    var window = rvn_dialog_window(desc.*.parent, title, 820, 560, &created);
    if (window == null) return;
    const size = widget_h.rvn_window_size(window);

    const box = widget_h.rvn_widget_create(raven.R_WIDGET_VBOX);
    _ = ext.rvn_widget_set_attribute(box, "Spacing", "12");
    const label = widget_h.rvn_widget_create(raven.R_WIDGET_LABEL);
    _ = ext.rvn_widget_set_attribute(label, "Text", title);
    _ = ext.rvn_widget_set_attribute(label, "TextSize", "17");
    widget_h.rvn_widget_add_child(box, label, -1);

    const browser = widget_h.rvn_widget_create(raven.R_WIDGET_FILE_BROWSER);
    browser.*.slot.is_fill = raven.R_TRUE;
    browser.*.slot.fill = 1.0;
    widget_h.rvn_widget_add_child(box, browser, -1);
    // as large as a file dialog usually is, when the window has the room
    box.*.fixed_size = base.rvn_vec2(base.rvn_minf(760.0, base.rvn_maxf(size.x - 84.0, 200.0)), base.rvn_minf(500.0, base.rvn_maxf(size.y - 84.0, 160.0)));

    raven.Rfile_browser_set_mode(browser.*.id, mode);
    raven.Rfile_browser_set_multiple(browser.*.id, @intFromBool(mode == raven.R_FILE_BROWSER_OPEN and (desc.*.flags & raven.R_FILE_DIALOG_MULTIPLE) != 0));
    raven.Rfile_browser_set_show_hidden(browser.*.id, @intFromBool((desc.*.flags & raven.R_FILE_DIALOG_SHOW_HIDDEN) != 0));
    if (desc.*.filters != null and desc.*.filter_count > 0) raven.Rfile_browser_set_filters(browser.*.id, desc.*.filters, desc.*.filter_count);
    if (desc.*.default_extension != null) raven.Rfile_browser_set_default_extension(browser.*.id, desc.*.default_extension);
    if (directory != null) _ = raven.Rfile_browser_set_directory(browser.*.id, directory);
    if (desc.*.file_name != null) raven.Rfile_browser_set_file_name(browser.*.id, desc.*.file_name);
    raven.Rfile_browser_set_accepted_callback(browser.*.id, rvn_file_dialog_accepted, null);
    raven.Rfile_browser_set_cancelled_callback(browser.*.id, rvn_file_dialog_cancelled, null);

    {
        const window_id = window.*.id;
        const browser_id = browser.*.id;
        var wait: rvn_dialog_wait_t = undefined;
        const in_update = ext.g_rvn.in_update;
        wait.done = raven.R_FALSE;
        wait.result = 0;
        widget_h.rvn_window_open_dialog(window, box, rvn_dialog_wait_closed, &wait);
        // the list has the keyboard: arrows, letters and Enter work at once
        if (widget_h.rvn_widget_get(browser_id) != null) widget_h.rvn_widget_focus(browser);
        ext.g_rvn.in_update = raven.R_FALSE;
        while (wait.done == 0 and raven.Ris_running() != 0 and widget_h.rvn_window_get(window_id) != null) rvn_dialog_frame(-1.0);
        ext.g_rvn.in_update = in_update;
        if (wait.done == 0 and widget_h.rvn_widget_get(browser_id) != null) _ = widget_h.rvn_window_close_dialog(browser, 0);
        if (wait.result == 0) rvn_dialogs_clear_results();
        window = widget_h.rvn_window_get(window_id);
    }
    if (created != 0 and window != null) widget_h.rvn_window_destroy(window);
}

// ---------------------------------------------------------------------------
//  File dialog: Win32
// ---------------------------------------------------------------------------

fn rvn_dialog_wide(text: [*c]const u8) [*c]WCHAR {
    if (text == null) return null;
    const length = MultiByteToWideChar(CP_UTF8, 0, text, -1, null, 0);
    if (length <= 0) return null;
    const wide: [*c]WCHAR = @ptrCast(@alignCast(base.rvn_alloc(@sizeOf(WCHAR) * @as(usize, @intCast(length)))));
    _ = MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, length);
    return wide;
}

fn rvn_dialog_narrow(wide: LPCWSTR) [*c]u8 {
    const length = WideCharToMultiByte(CP_UTF8, 0, wide, -1, null, 0, null, null);
    if (length <= 0) return null;
    const text: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(length)))));
    _ = WideCharToMultiByte(CP_UTF8, 0, wide, -1, text, length, null, null);
    return text;
}

fn rvn_dialog_add_wide(wide: LPCWSTR) void {
    const path = rvn_dialog_narrow(wide);
    rvn_dialogs_add_result(path);
    base.rvn_free(path);
}

fn rvn_dialog_owner(parent: raven.Rid) HWND {
    const window = widget_h.rvn_window_get(parent);
    var native: raven.RNativeWindow = undefined;
    if (window == null or window.*.platform == null) return null;
    _ = libc.memset(&native, 0, @sizeOf(raven.RNativeWindow));
    const plat: [*c]const plat_h.rvn_platform_t = @ptrCast(@alignCast(ext.g_rvn.platform));
    plat.*.window_get_native.?(window.*.platform, &native);
    return if (native.system == raven.R_WINDOW_SYSTEM_WIN32) @ptrFromInt(native.window) else null;
}

/// "Images\0*.png;*.jpg\0All files\0*\0\0"
fn rvn_dialog_filter_string(desc: [*c]const raven.RFileDialogDesc) LPWSTR {
    var used: usize = 0;
    var cap: usize = 2;
    var i: c_int = 0;
    if (desc.*.filters == null or desc.*.filter_count <= 0) return null;
    while (i < desc.*.filter_count) : (i += 1) {
        const filter = desc.*.filters[@intCast(i)];
        cap += (if (filter.name != null) libc.strlen(filter.name) else 0) + 1;
        cap += (if (filter.patterns != null) libc.strlen(filter.patterns) else 1) * 2 + 4;
    }
    const result: [*c]WCHAR = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(WCHAR) * cap)));
    i = 0;
    while (i < desc.*.filter_count) : (i += 1) {
        const filter = desc.*.filters[@intCast(i)];
        var patterns: [*c]const u8 = if (filter.patterns != null and filter.patterns[0] != 0) filter.patterns else "*";
        const name: [*c]const u8 = if (filter.name != null and filter.name[0] != 0) filter.name else patterns;
        used += @as(usize, @bitCast(@as(isize, MultiByteToWideChar(CP_UTF8, 0, name, -1, result + used, @intCast(cap - used)))));
        // "*" alone would hide the files without extension from old dialogs
        if (libc.strcmp(patterns, "*") == 0) patterns = "*.*";
        used += @as(usize, @bitCast(@as(isize, MultiByteToWideChar(CP_UTF8, 0, patterns, -1, result + used, @intCast(cap - used)))));
    }
    result[used] = 0;
    return result;
}

fn rvn_file_dialog_win32_files(desc: [*c]const raven.RFileDialogDesc, mode: raven.RFileBrowserMode, directory: [*c]const u8) c_int {
    const BUFFER = 32768;
    var ofn: OPENFILENAMEW = undefined;
    const buffer: [*c]WCHAR = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(WCHAR) * BUFFER)));
    const filters = rvn_dialog_filter_string(desc);
    const title = rvn_dialog_wide(desc.*.title);
    const folder = rvn_dialog_wide(directory);
    const extension = rvn_dialog_wide(desc.*.default_extension);
    var ok: BOOL = undefined;

    if (desc.*.file_name != null) _ = MultiByteToWideChar(CP_UTF8, 0, desc.*.file_name, -1, buffer, BUFFER - 1);
    _ = libc.memset(&ofn, 0, @sizeOf(OPENFILENAMEW));
    ofn.lStructSize = @sizeOf(OPENFILENAMEW);
    ofn.hwndOwner = rvn_dialog_owner(desc.*.parent);
    ofn.lpstrFilter = filters;
    ofn.nFilterIndex = 1;
    ofn.lpstrFile = buffer;
    ofn.nMaxFile = BUFFER;
    ofn.lpstrInitialDir = folder;
    ofn.lpstrTitle = title;
    ofn.lpstrDefExt = if (extension != null and extension[0] == '.') extension + 1 else extension;
    ofn.Flags = OFN_EXPLORER | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_HIDEREADONLY;
    if ((desc.*.flags & raven.R_FILE_DIALOG_SHOW_HIDDEN) != 0) ofn.Flags |= OFN_FORCESHOWHIDDEN;
    if (mode == raven.R_FILE_BROWSER_SAVE) {
        ofn.Flags |= OFN_OVERWRITEPROMPT;
        ok = GetSaveFileNameW(&ofn);
    } else {
        ofn.Flags |= OFN_FILEMUSTEXIST;
        if ((desc.*.flags & raven.R_FILE_DIALOG_MULTIPLE) != 0) ofn.Flags |= OFN_ALLOWMULTISELECT;
        ok = GetOpenFileNameW(&ofn);
    }
    if (ok != 0) {
        const first = wcslen(buffer);
        if ((ofn.Flags & OFN_ALLOWMULTISELECT) != 0 and buffer[first + 1] != 0) {
            // several files: the folder, then each name, each ended by a zero
            var name: [*c]const WCHAR = buffer + first + 1;
            while (name[0] != 0) {
                var full: [2048]WCHAR = undefined;
                const full_ptr: [*c]WCHAR = &full;
                const length = wcslen(name);
                if (first + length + 2 < full.len) {
                    _ = libc.memcpy(full_ptr, buffer, @sizeOf(WCHAR) * first);
                    full_ptr[first] = '\\';
                    _ = libc.memcpy(full_ptr + first + (if (buffer[first - 1] == '\\') @as(usize, 0) else 1), name, @sizeOf(WCHAR) * (length + 1));
                    rvn_dialog_add_wide(full_ptr);
                }
                name += length + 1;
            }
        } else {
            rvn_dialog_add_wide(buffer);
        }
    }
    base.rvn_free(buffer);
    base.rvn_free(filters);
    base.rvn_free(title);
    base.rvn_free(folder);
    base.rvn_free(extension);
    // an error of the dialog itself (not a cancel) falls back to the browser of Raven
    return @intFromBool(ok != 0 or CommDlgExtendedError() == 0);
}

// (defined here so that no import library of GUIDs is needed)
const rvn_clsid_file_open_dialog = GUID{ .Data1 = 0xdc1c5a9c, .Data2 = 0xe88a, .Data3 = 0x4dde, .Data4 = .{ 0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7 } };
const rvn_iid_file_open_dialog = GUID{ .Data1 = 0xd57c7288, .Data2 = 0xd4ad, .Data3 = 0x4768, .Data4 = .{ 0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60 } };
const rvn_iid_shell_item = GUID{ .Data1 = 0x43826d1e, .Data2 = 0xe718, .Data3 = 0x42ee, .Data4 = .{ 0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe } };

fn rvn_file_dialog_win32_folder(desc: [*c]const raven.RFileDialogDesc, directory: [*c]const u8) c_int {
    var dialog: ?*IFileOpenDialog = null;
    var item: ?*IShellItem = null;
    const init = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    var hr: HRESULT = undefined;
    var shown: c_int = raven.R_FALSE;

    hr = CoCreateInstance(&rvn_clsid_file_open_dialog, null, CLSCTX_INPROC_SERVER, &rvn_iid_file_open_dialog, @ptrCast(&dialog));
    if (hr >= 0 and dialog != null) {
        const dlg = dialog.?;
        var options: FILEOPENDIALOGOPTIONS = 0;
        const title = rvn_dialog_wide(desc.*.title);
        const folder = rvn_dialog_wide(directory);
        _ = dlg.lpVtbl.GetOptions(dlg, &options);
        _ = dlg.lpVtbl.SetOptions(dlg, options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR);
        if (title != null) _ = dlg.lpVtbl.SetTitle(dlg, title);
        if (folder != null and SHCreateItemFromParsingName(folder, null, &rvn_iid_shell_item, @ptrCast(&item)) >= 0 and item != null) {
            _ = dlg.lpVtbl.SetFolder(dlg, item.?);
            _ = item.?.lpVtbl.Release(item.?);
            item = null;
        }
        hr = dlg.lpVtbl.Show(dlg, rvn_dialog_owner(desc.*.parent));
        // a cancel is an answer too
        shown = @intFromBool(hr >= 0 or hr == HRESULT_FROM_WIN32_CANCELLED);
        if (hr >= 0 and dlg.lpVtbl.GetResult(dlg, &item) >= 0 and item != null) {
            const it = item.?;
            var path: LPWSTR = null;
            if (it.lpVtbl.GetDisplayName(it, SIGDN_FILESYSPATH, &path) >= 0 and path != null) {
                rvn_dialog_add_wide(path);
                CoTaskMemFree(path);
            }
            _ = it.lpVtbl.Release(it);
        }
        _ = dlg.lpVtbl.Release(dlg);
        base.rvn_free(title);
        base.rvn_free(folder);
    }
    if (init >= 0) CoUninitialize();
    return shown;
}

// ---------------------------------------------------------------------------
//  File dialog: zenity / kdialog
// ---------------------------------------------------------------------------

const rvn_dialog_args_t = extern struct {
    items: [RVN_DIALOG_MAX_ARGS + 1][*c]u8,
    count: c_int,
};

fn rvn_dialog_tool_exists(name: [*c]const u8) c_int {
    var path: [*c]const u8 = libc.getenv("PATH");
    var candidate: [1024]u8 = undefined;
    const cand: [*c]u8 = &candidate;
    if (path == null) return raven.R_FALSE;
    while (path[0] != 0) {
        const length = libc.strcspn(path, ":");
        if (length > 0 and length + libc.strlen(name) + 2 < candidate.len) {
            _ = libc.memcpy(cand, path, length);
            cand[length] = '/';
            _ = libc.strcpy(cand + length + 1, name);
            if (libc.access(cand, X_OK) == 0) return raven.R_TRUE;
        }
        path += length;
        if (path[0] == ':') path += 1;
    }
    return raven.R_FALSE;
}

fn rvn_dialog_arg(args: [*c]rvn_dialog_args_t, prefix: [*c]const u8, value: [*c]const u8) void {
    const prefix_length = libc.strlen(prefix);
    const value_length: usize = if (value != null) libc.strlen(value) else 0;
    var item: [*c]u8 = undefined;
    if (args.*.count >= RVN_DIALOG_MAX_ARGS) return;
    item = @ptrCast(@alignCast(base.rvn_alloc(prefix_length + value_length + 1)));
    _ = libc.memcpy(item, prefix, prefix_length);
    if (value != null) _ = libc.memcpy(item + prefix_length, value, value_length);
    item[prefix_length + value_length] = 0;
    args.*.items[@intCast(args.*.count)] = item;
    args.*.count += 1;
    args.*.items[@intCast(args.*.count)] = null;
}

/// "*.png;*.jpg" -> "*.png *.jpg"
fn rvn_dialog_spaced(patterns: [*c]const u8) [*c]u8 {
    const copy: [*c]u8 = base.rvn_strdup(if (patterns != null and patterns[0] != 0) patterns else "*");
    var cursor: [*c]u8 = copy;
    while (cursor[0] != 0) : (cursor += 1) {
        if (cursor[0] == ';' or cursor[0] == ',') cursor[0] = ' ';
    }
    return copy;
}

/// Folder shown first, with the proposed name: "/home/me/" or "/home/me/name.txt".
fn rvn_dialog_start_path(desc: [*c]const raven.RFileDialogDesc, directory: [*c]const u8) [*c]u8 {
    const dir: [*c]const u8 = if (directory != null) directory else "/";
    const folder = fs.rvn_path_child(dir, "");
    var path: [*c]u8 = undefined;
    if (desc.*.file_name == null or desc.*.file_name[0] == 0) return folder;
    path = fs.rvn_path_child(folder, desc.*.file_name);
    base.rvn_free(folder);
    return path;
}

fn rvn_dialog_args_zenity(args: [*c]rvn_dialog_args_t, desc: [*c]const raven.RFileDialogDesc, mode: raven.RFileBrowserMode, directory: [*c]const u8) void {
    const start = rvn_dialog_start_path(desc, directory);
    var i: c_int = 0;
    rvn_dialog_arg(args, "zenity", null);
    rvn_dialog_arg(args, "--file-selection", null);
    rvn_dialog_arg(args, "--title=", rvn_file_dialog_title(desc, mode));
    rvn_dialog_arg(args, "--filename=", start);
    if (mode == raven.R_FILE_BROWSER_SAVE) {
        rvn_dialog_arg(args, "--save", null);
        rvn_dialog_arg(args, "--confirm-overwrite", null);
    } else if (mode == raven.R_FILE_BROWSER_FOLDER) {
        rvn_dialog_arg(args, "--directory", null);
    } else if ((desc.*.flags & raven.R_FILE_DIALOG_MULTIPLE) != 0) {
        rvn_dialog_arg(args, "--multiple", null);
        rvn_dialog_arg(args, "--separator=", "\n");
    }
    while (i < desc.*.filter_count and desc.*.filters != null and mode != raven.R_FILE_BROWSER_FOLDER) : (i += 1) {
        const filter = desc.*.filters[@intCast(i)];
        const patterns = rvn_dialog_spaced(filter.patterns);
        var filter_text: [512]u8 = undefined;
        _ = libc.snprintf(&filter_text, filter_text.len, "%.160s | %.300s", if (filter.name != null) filter.name else patterns, patterns);
        rvn_dialog_arg(args, "--file-filter=", &filter_text);
        base.rvn_free(patterns);
    }
    base.rvn_free(start);
}

fn rvn_dialog_args_kdialog(args: [*c]rvn_dialog_args_t, desc: [*c]const raven.RFileDialogDesc, mode: raven.RFileBrowserMode, directory: [*c]const u8) void {
    const start = rvn_dialog_start_path(desc, directory);
    var filter: [1024]u8 = undefined;
    var used: usize = 0;
    var i: c_int = 0;
    rvn_dialog_arg(args, "kdialog", null);
    rvn_dialog_arg(args, "--title", null);
    rvn_dialog_arg(args, rvn_file_dialog_title(desc, mode), null);
    if (mode == raven.R_FILE_BROWSER_FOLDER) {
        rvn_dialog_arg(args, "--getexistingdirectory", null);
        rvn_dialog_arg(args, start, null);
    } else {
        if (mode == raven.R_FILE_BROWSER_OPEN and (desc.*.flags & raven.R_FILE_DIALOG_MULTIPLE) != 0) {
            rvn_dialog_arg(args, "--multiple", null);
            rvn_dialog_arg(args, "--separate-output", null);
        }
        rvn_dialog_arg(args, if (mode == raven.R_FILE_BROWSER_SAVE) "--getsavefilename" else "--getopenfilename", null);
        rvn_dialog_arg(args, start, null);
        // "Images (*.png *.jpg)|All files (*)"
        filter[0] = 0;
        while (i < desc.*.filter_count and desc.*.filters != null) : (i += 1) {
            const filter_desc = desc.*.filters[@intCast(i)];
            const patterns = rvn_dialog_spaced(filter_desc.patterns);
            const bar: [*c]const u8 = if (i != 0) "|" else "";
            const name: [*c]const u8 = if (filter_desc.name != null) filter_desc.name else "Files";
            const written = libc.snprintf(@as([*c]u8, &filter) + used, filter.len - used, "%s%.160s (%.300s)", bar, name, patterns);
            base.rvn_free(patterns);
            if (written < 0 or @as(usize, @intCast(written)) >= filter.len - used) break;
            used += @as(usize, @intCast(written));
        }
        if (filter[0] != 0) rvn_dialog_arg(args, &filter, null);
    }
    base.rvn_free(start);
}

/// Runs the dialog program and reads the chosen paths from its output, one per
/// line. The application keeps running its frames meanwhile, without taking
/// input. Returns R_FALSE when the program could not show a dialog.
fn rvn_dialog_run_tool(args: [*c]rvn_dialog_args_t) c_int {
    var fds: [2]c_int = undefined;
    var status: c_int = 0;
    var shown: c_int = raven.R_FALSE;
    var output: [*c]u8 = null;
    var used: usize = 0;
    var cap: usize = 0;

    if (libc.pipe(&fds) != 0) return raven.R_FALSE;
    const child = libc.fork();
    if (child < 0) {
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
        return raven.R_FALSE;
    }
    if (child == 0) {
        const null_fd = libc.open("/dev/null", O_WRONLY);
        _ = libc.dup2(fds[1], STDOUT_FILENO);
        if (null_fd >= 0) _ = libc.dup2(null_fd, STDERR_FILENO);
        _ = libc.close(fds[0]);
        _ = libc.close(fds[1]);
        _ = libc.execvp(args.*.items[0], @ptrCast(&args.*.items));
        libc._exit(127);
    }
    _ = libc.close(fds[1]);
    _ = libc.fcntl(fds[0], F_SETFL, libc.fcntl(fds[0], F_GETFL, @as(c_int, 0)) | O_NONBLOCK);

    ext.g_rvn.input_blocked += 1;
    {
        const in_update = ext.g_rvn.in_update;
        ext.g_rvn.in_update = raven.R_FALSE;
        while (true) {
            var poll_fd: std.c.pollfd = undefined;
            var chunk: [1024]u8 = undefined;
            poll_fd.fd = fds[0];
            poll_fd.events = POLLIN;
            poll_fd.revents = 0;
            if (libc.poll(&poll_fd, 1, 0) > 0) {
                const count = libc.read(fds[0], &chunk, chunk.len);
                if (count > 0) {
                    const n: usize = @intCast(count);
                    if (used + n + 1 > cap) {
                        cap = (used + n + 1) * 2;
                        output = @ptrCast(@alignCast(base.rvn_realloc(output, cap)));
                    }
                    _ = libc.memcpy(output + used, &chunk, n);
                    used += n;
                    continue;
                }
                if (count == 0 or (errnoValue() != EAGAIN and errnoValue() != EINTR)) break;
            }
            // the windows of the application stay alive behind the dialog
            rvn_dialog_frame(0.03);
        }
        ext.g_rvn.in_update = in_update;
    }
    ext.g_rvn.input_blocked -= 1;
    _ = libc.close(fds[0]);
    while (libc.waitpid(child, &status, 0) < 0 and errnoValue() == EINTR) {}

    if (WIFEXITED(status) and WEXITSTATUS(status) != 127) {
        // 0: chosen, 1: cancelled
        shown = @intFromBool(WEXITSTATUS(status) == 0 or WEXITSTATUS(status) == 1);
        if (WEXITSTATUS(status) == 0 and output != null) {
            var line: [*c]u8 = output;
            output[used] = 0;
            while (line[0] != 0) {
                const length = libc.strcspn(line, "\n");
                const saved = line[length];
                line[length] = 0;
                rvn_dialogs_add_result(line);
                line[length] = saved;
                line += length;
                if (line[0] == '\n') line += 1;
            }
        }
    }
    base.rvn_free(output);
    return shown;
}

fn rvn_file_dialog_native(desc: [*c]const raven.RFileDialogDesc, mode: raven.RFileBrowserMode, directory: [*c]const u8) c_int {
    if (builtin.os.tag == .windows) {
        if (mode == raven.R_FILE_BROWSER_FOLDER) return rvn_file_dialog_win32_folder(desc, directory);
        return rvn_file_dialog_win32_files(desc, mode, directory);
    } else {
        var args: rvn_dialog_args_t = undefined;
        const desktop = libc.getenv("XDG_CURRENT_DESKTOP");
        const kde = desktop != null and libc.strstr(desktop, "KDE") != null;
        var shown: c_int = undefined;

        if (libc.getenv("DISPLAY") == null and libc.getenv("WAYLAND_DISPLAY") == null) return raven.R_FALSE;
        const has_zenity = rvn_dialog_tool_exists("zenity");
        const has_kdialog = rvn_dialog_tool_exists("kdialog");
        if (has_zenity == 0 and has_kdialog == 0) return raven.R_FALSE;

        _ = libc.memset(&args, 0, @sizeOf(rvn_dialog_args_t));
        if (has_kdialog != 0 and (kde or has_zenity == 0)) rvn_dialog_args_kdialog(&args, desc, mode, directory) else rvn_dialog_args_zenity(&args, desc, mode, directory);
        shown = rvn_dialog_run_tool(&args);
        var i: c_int = 0;
        while (i < args.count) : (i += 1) base.rvn_free(args.items[@intCast(i)]);
        return shown;
    }
}

// ---------------------------------------------------------------------------
//  File dialogs: public API
// ---------------------------------------------------------------------------

fn rvn_file_dialog(user_desc: [*c]const raven.RFileDialogDesc, mode: raven.RFileBrowserMode) [*c]const u8 {
    var desc: raven.RFileDialogDesc = undefined;
    var directory: [*c]u8 = null;
    var shown: c_int = raven.R_FALSE;

    _ = libc.memset(&desc, 0, @sizeOf(raven.RFileDialogDesc));
    if (user_desc != null) desc = user_desc.*;
    if (desc.filter_count < 0 or desc.filters == null) desc.filter_count = 0;
    rvn_dialogs_clear_results();

    if (desc.directory != null and desc.directory[0] != 0) directory = fs.rvn_path_absolute(desc.directory);
    if ((directory == null or fs.rvn_path_is_dir(directory) == 0) and g_dialogs.directory != null) {
        base.rvn_free(directory);
        directory = base.rvn_strdup(g_dialogs.directory);
    }
    if (directory == null or fs.rvn_path_is_dir(directory) == 0) {
        base.rvn_free(directory);
        directory = fs.rvn_path_home();
    }

    // without a window system there is nobody to show a native dialog to
    const plat: [*c]const plat_h.rvn_platform_t = @ptrCast(@alignCast(ext.g_rvn.platform));
    if ((desc.flags & raven.R_FILE_DIALOG_RAVEN) == 0 and plat.*.system != raven.R_WINDOW_SYSTEM_NONE) {
        shown = rvn_file_dialog_native(&desc, mode, directory);
        if (shown == 0) rvn_dialogs_clear_results();
    }
    if (shown == 0) rvn_file_dialog_raven(&desc, mode, directory);
    base.rvn_free(directory);

    if (g_dialogs.count == 0) return null;
    // the next dialog starts where this one ended
    base.rvn_free(g_dialogs.directory);
    g_dialogs.directory = if (mode == raven.R_FILE_BROWSER_FOLDER) base.rvn_strdup(g_dialogs.paths[0]) else fs.rvn_path_parent(g_dialogs.paths[0]);
    return g_dialogs.paths[0];
}

export fn Rfile_dialog_open(desc: [*c]const raven.RFileDialogDesc) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rfile_dialog_open") == 0) return null;
    return rvn_file_dialog(desc, raven.R_FILE_BROWSER_OPEN);
}

export fn Rfile_dialog_save(desc: [*c]const raven.RFileDialogDesc) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rfile_dialog_save") == 0) return null;
    return rvn_file_dialog(desc, raven.R_FILE_BROWSER_SAVE);
}

export fn Rfile_dialog_select_folder(desc: [*c]const raven.RFileDialogDesc) [*c]const u8 {
    if (ctx_h.rvn_api_check("Rfile_dialog_select_folder") == 0) return null;
    return rvn_file_dialog(desc, raven.R_FILE_BROWSER_FOLDER);
}

export fn Rfile_dialog_get_result_count() c_int {
    return if (ext.g_rvn.initialized != 0) g_dialogs.count else 0;
}

export fn Rfile_dialog_get_result(index: c_int) [*c]const u8 {
    if (ext.g_rvn.initialized == 0 or index < 0 or index >= g_dialogs.count) return null;
    return g_dialogs.paths[@intCast(index)];
}

export fn Rfile_read(path: [*c]const u8, size: [*c]usize) [*c]u8 {
    return base.rvn_read_file(path, size);
}

export fn Rfile_write(path: [*c]const u8, data: ?*const anyopaque, size: usize) c_int {
    if (path == null or (data == null and size > 0)) return raven.R_FALSE;
    return fs.rvn_write_file(path, data, size);
}
