// Translated to Zig from vendor/raven/src/platform/win32/win32_platform.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/win32/win32_platform.c
// Win32 implementation of the platform interface. Only user32, gdi32,
// shell32 and kernel32 are needed.
//
//   - Unicode everywhere: the API of Raven is UTF-8, converted to UTF-16 here,
//   - per-monitor DPI awareness (the scale follows the window across monitors),
//   - frames keep coming while the user drags or resizes the window,
//   - child windows for native viewports (OpenGL, Direct3D, another swapchain),
//   - windows whose title bar is drawn by the application (custom header):
//     Windows still moves, snaps and resizes them, from the answers to
//     WM_NCHITTEST,
//   - files dropped from the Explorer (WM_DROPFILES),
//   - an event object so that other threads can wake the event loop.
//
// The whole file is `#if defined(_WIN32)` in C: here the export of rvn_platform_win32 is emitted
// only when the target is Windows (comptime block at the end), and the Win32 declarations and the
// window procedures are only analysed when they are reached (Zig analyses lazily), so nothing
// Windows-only is referenced on other systems.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const platform_h = @import("../platform_h.zig");
const uia = @import("win32_uia_h.zig");

// ---------------------------------------------------------------------------
//  Constants of <windows.h>, <windowsx.h>, <shellapi.h> (the #defines of the C file come first)
// ---------------------------------------------------------------------------

const RVN_WIN32_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("Raven_Window");
const RVN_WIN32_CHILD_CLASS = std.unicode.utf8ToUtf16LeStringLiteral("Raven_Viewport");
const RVN_WIN32_CURSOR_COUNT = 11;
const RVN_WIN32_MODAL_TIMER = 0x4855;
/// Window property that marks a window with a custom header before the core knows it.
const RVN_WIN32_CUSTOM_PROPERTY = std.unicode.utf8ToUtf16LeStringLiteral("Raven_CustomHeader");
/// Height, in logical units, of the band at the top of a custom header that resizes the window.
const RVN_WIN32_TOP_RESIZE = 6;

const WM_CLOSE = 0x0010;
const WM_ERASEBKGND = 0x0014;
const WM_SETCURSOR = 0x0020;
const WM_GETMINMAXINFO = 0x0024;
const WM_GETOBJECT = 0x003D;
const WM_SETFOCUS = 0x0007;
const WM_KILLFOCUS = 0x0008;
const WM_SIZE = 0x0005;
const WM_PAINT = 0x000F;
const WM_QUIT = 0x0012;
const WM_SETICON = 0x0080;
const WM_NCCALCSIZE = 0x0083;
const WM_NCHITTEST = 0x0084;
const WM_KEYDOWN = 0x0100;
const WM_KEYUP = 0x0101;
const WM_CHAR = 0x0102;
const WM_SYSKEYDOWN = 0x0104;
const WM_SYSKEYUP = 0x0105;
const WM_SYSCHAR = 0x0106;
const WM_SYSCOMMAND = 0x0112;
const WM_TIMER = 0x0113;
const WM_ENTERMENULOOP = 0x0211;
const WM_EXITMENULOOP = 0x0212;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_MOUSEWHEEL = 0x020A;
const WM_XBUTTONDOWN = 0x020B;
const WM_XBUTTONUP = 0x020C;
const WM_MOUSEHWHEEL = 0x020E;
const WM_CAPTURECHANGED = 0x0215;
const WM_ENTERSIZEMOVE = 0x0231;
const WM_EXITSIZEMOVE = 0x0232;
const WM_DROPFILES = 0x0233;
const WM_DPICHANGED = 0x02E0;
const WM_MOUSELEAVE = 0x02A3;

const USER_DEFAULT_SCREEN_DPI = 96;
const USER_TIMER_MINIMUM = 0x0000000A;
const QS_SENDMESSAGE = 0x0040;
const QS_ALLINPUT = 0x04FF;
const PM_QS_SENDMESSAGE = QS_SENDMESSAGE << 16;
const PM_NOREMOVE = 0x0000;
const PM_REMOVE = 0x0001;
const MWMO_INPUTAVAILABLE = 0x0004;
const INFINITE = 0xFFFFFFFF;

const SIZE_RESTORED = 0;
const SIZE_MINIMIZED = 1;
const SIZE_MAXIMIZED = 2;
const SC_SIZE = 0xF000;
const SC_MOVE = 0xF010;
const SC_KEYMENU = 0xF100;

const HTCLIENT = 1;
const HTCAPTION = 2;
const HTTOP = 12;
const HTTOPLEFT = 13;
const HTTOPRIGHT = 14;
const HTTRANSPARENT = -1;

const GWL_STYLE = -16;
const GWL_EXSTYLE = -20;
const GWLP_USERDATA = -21;

const WS_OVERLAPPED = 0x00000000;
const WS_POPUP = 0x80000000;
const WS_CHILD = 0x40000000;
const WS_VISIBLE = 0x10000000;
const WS_CLIPSIBLINGS = 0x04000000;
const WS_CLIPCHILDREN = 0x02000000;
const WS_CAPTION = 0x00C00000;
const WS_SYSMENU = 0x00080000;
const WS_MINIMIZEBOX = 0x00020000;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const WS_EX_APPWINDOW = 0x00040000;
const WS_EX_LAYERED = 0x00080000;
const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));

const SWP_NOSIZE = 0x0001;
const SWP_NOMOVE = 0x0002;
const SWP_NOZORDER = 0x0004;
const SWP_NOACTIVATE = 0x0010;
const SWP_FRAMECHANGED = 0x0020;
const SWP_SHOWWINDOW = 0x0040;

const SW_HIDE = 0;
const SW_SHOW = 5;
const SW_SHOWMAXIMIZED = 3;
const SW_MINIMIZE = 6;
const SW_MAXIMIZE = 3;
const SW_RESTORE = 9;

const SM_CXICON = 11;
const SM_CYICON = 12;
const SM_CYFRAME = 33;
const SM_CXSMICON = 49;
const SM_CYSMICON = 50;
const SM_CXPADDEDBORDER = 92;
const LOGPIXELSX = 88;
const MAPVK_VSC_TO_VK_EX = 3;
const MONITOR_DEFAULTTOPRIMARY = 1;
const TME_LEAVE = 0x00000002;
const WHEEL_DELTA = 120;
const XBUTTON1 = 1;
const LWA_ALPHA = 0x00000002;
const WCA_ACCENT_POLICY = 19;
const TRUE = 1;
const FALSE = 0;
const CS_OWNDC = 0x0020;
const CP_UTF8 = 65001;
const GMEM_MOVEABLE = 0x0002;
const CF_UNICODETEXT = 13;
const BI_BITFIELDS = 3;
const DIB_RGB_COLORS = 0;
const IMAGE_ICON = 1;
const ICON_SMALL = 0;
const ICON_BIG = 1;
const RT_GROUP_ICON = 14;

const VK_BACK = 0x08;
const VK_TAB = 0x09;
const VK_RETURN = 0x0D;
const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const VK_PAUSE = 0x13;
const VK_CAPITAL = 0x14;
const VK_ESCAPE = 0x1B;
const VK_SPACE = 0x20;
const VK_PRIOR = 0x21;
const VK_NEXT = 0x22;
const VK_END = 0x23;
const VK_HOME = 0x24;
const VK_LEFT = 0x25;
const VK_UP = 0x26;
const VK_RIGHT = 0x27;
const VK_DOWN = 0x28;
const VK_SNAPSHOT = 0x2C;
const VK_INSERT = 0x2D;
const VK_DELETE = 0x2E;
const VK_LWIN = 0x5B;
const VK_RWIN = 0x5C;
const VK_APPS = 0x5D;
const VK_NUMPAD0 = 0x60;
const VK_NUMPAD9 = 0x69;
const VK_MULTIPLY = 0x6A;
const VK_ADD = 0x6B;
const VK_SUBTRACT = 0x6D;
const VK_DECIMAL = 0x6E;
const VK_DIVIDE = 0x6F;
const VK_F1 = 0x70;
const VK_F12 = 0x7B;
const VK_RSHIFT = 0xA1;
const VK_RCONTROL = 0xA3;
const VK_RMENU = 0xA5;
const VK_OEM_1 = 0xBA;
const VK_OEM_PLUS = 0xBB;
const VK_OEM_COMMA = 0xBC;
const VK_OEM_MINUS = 0xBD;
const VK_OEM_PERIOD = 0xBE;
const VK_OEM_2 = 0xBF;
const VK_OEM_3 = 0xC0;
const VK_OEM_4 = 0xDB;
const VK_OEM_5 = 0xDC;
const VK_OEM_6 = 0xDD;
const VK_OEM_7 = 0xDE;

// MAKEINTRESOURCE(n): resource identifiers passed where a string is expected
const IDC_ARROW: ?*const anyopaque = @ptrFromInt(32512);
const IDC_IBEAM: ?*const anyopaque = @ptrFromInt(32513);
const IDC_CROSS: ?*const anyopaque = @ptrFromInt(32515);
const IDC_SIZENWSE: ?*const anyopaque = @ptrFromInt(32642);
const IDC_SIZENESW: ?*const anyopaque = @ptrFromInt(32643);
const IDC_SIZEWE: ?*const anyopaque = @ptrFromInt(32644);
const IDC_SIZENS: ?*const anyopaque = @ptrFromInt(32645);
const IDC_SIZEALL: ?*const anyopaque = @ptrFromInt(32646);
const IDC_NO: ?*const anyopaque = @ptrFromInt(32648);
const IDC_HAND: ?*const anyopaque = @ptrFromInt(32649);
const IDI_APPLICATION: ?*const anyopaque = @ptrFromInt(32512);
const RT_GROUP_ICON_PTR: ?*const anyopaque = @ptrFromInt(RT_GROUP_ICON);

const HWND_TOPMOST: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
const HWND_NOTOPMOST: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize) - 1);

// ---------------------------------------------------------------------------
//  Types of <windef.h>, <minwindef.h>, <windows.h>, declared by hand
// ---------------------------------------------------------------------------

const BOOL = c_int;
const BYTE = u8;
const WORD = u16;
const DWORD = u32;
const UINT = c_uint;
const LONG = c_long;
const HRESULT = c_long;
const LONG_PTR = isize;
const INT_PTR = isize;
const UINT_PTR = usize;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const SIZE_T = usize;
const WCHAR = u16;
const ATOM = u16;
const COLORREF = u32;
const HANDLE = ?*anyopaque;
const HWND = ?*anyopaque;
const HINSTANCE = ?*anyopaque;
const HMODULE = ?*anyopaque;
const HDC = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBITMAP = ?*anyopaque;
const HRGN = ?*anyopaque;
const HGDIOBJ = ?*anyopaque;
const HGLOBAL = ?*anyopaque;
const HMONITOR = ?*anyopaque;
const HDROP = ?*anyopaque;
const HMENU = ?*anyopaque;
const FARPROC = ?*const fn () callconv(.winapi) void;

const POINT = extern struct { x: LONG, y: LONG };
const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };
const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};
const WNDPROC = ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: ?*anyopaque,
    lpszMenuName: [*c]const WCHAR,
    lpszClassName: [*c]const WCHAR,
    hIconSm: HICON,
};
const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};
const WINDOWPOS = extern struct {
    hwnd: HWND,
    hwndInsertAfter: HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    flags: UINT,
};
const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*WINDOWPOS,
};
const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};
const ICONINFO = extern struct {
    fIcon: BOOL,
    xHotspot: DWORD,
    yHotspot: DWORD,
    hbmMask: HBITMAP,
    hbmColor: HBITMAP,
};
const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};
const OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: DWORD,
    dwMajorVersion: DWORD,
    dwMinorVersion: DWORD,
    dwBuildNumber: DWORD,
    dwPlatformId: DWORD,
    szCSDVersion: [128]WCHAR,
};
const CIEXYZ = extern struct { ciexyzX: DWORD, ciexyzY: DWORD, ciexyzZ: DWORD };
const CIEXYZTRIPLE = extern struct { ciexyzRed: CIEXYZ, ciexyzGreen: CIEXYZ, ciexyzBlue: CIEXYZ };
const BITMAPV5HEADER = extern struct {
    bV5Size: DWORD,
    bV5Width: LONG,
    bV5Height: LONG,
    bV5Planes: WORD,
    bV5BitCount: WORD,
    bV5Compression: DWORD,
    bV5SizeImage: DWORD,
    bV5XPelsPerMeter: LONG,
    bV5YPelsPerMeter: LONG,
    bV5ClrUsed: DWORD,
    bV5ClrImportant: DWORD,
    bV5RedMask: DWORD,
    bV5GreenMask: DWORD,
    bV5BlueMask: DWORD,
    bV5AlphaMask: DWORD,
    bV5CSType: DWORD,
    bV5Endpoints: CIEXYZTRIPLE,
    bV5GammaRed: DWORD,
    bV5GammaGreen: DWORD,
    bV5GammaBlue: DWORD,
    bV5Intent: DWORD,
    bV5ProfileData: DWORD,
    bV5ProfileSize: DWORD,
    bV5Reserved: DWORD,
};

// dynamic functions of user32 / dwmapi (looked up at run time, see rvn_win32_init and rvn_win32_dwm_load)
const rvn_win32_get_dpi_for_window_fn = ?*const fn (HWND) callconv(.winapi) UINT;
const rvn_win32_adjust_rect_for_dpi_fn = ?*const fn ([*c]RECT, DWORD, BOOL, DWORD, UINT) callconv(.winapi) BOOL;
const rvn_win32_set_awareness_context_fn = ?*const fn (HANDLE) callconv(.winapi) BOOL;
const rvn_win32_set_dpi_aware_fn = ?*const fn () callconv(.winapi) BOOL;

const rvn_win32_blur_behind_t = extern struct {
    flags: DWORD,
    enable: BOOL,
    region: HRGN,
    transition_on_maximized: BOOL,
};

const rvn_win32_margins_t = extern struct {
    left: c_int,
    right: c_int,
    top: c_int,
    bottom: c_int,
};

const rvn_win32_accent_t = extern struct {
    state: c_int,
    flags: c_int,
    gradient_color: DWORD,
    animation: c_int,
};

const rvn_win32_composition_t = extern struct {
    attribute: c_int,
    data: ?*anyopaque,
    size: SIZE_T,
};

const rvn_dwm_enable_blur_fn = ?*const fn (HWND, [*c]const rvn_win32_blur_behind_t) callconv(.winapi) HRESULT;
const rvn_dwm_extend_frame_fn = ?*const fn (HWND, [*c]const rvn_win32_margins_t) callconv(.winapi) HRESULT;
const rvn_dwm_set_attribute_fn = ?*const fn (HWND, DWORD, ?*const anyopaque, DWORD) callconv(.winapi) HRESULT;
const rvn_dwm_is_enabled_fn = ?*const fn ([*c]BOOL) callconv(.winapi) HRESULT;
const rvn_set_composition_fn = ?*const fn (HWND, [*c]rvn_win32_composition_t) callconv(.winapi) BOOL;
const rvn_rtl_get_version_fn = ?*const fn ([*c]OSVERSIONINFOW) callconv(.winapi) LONG;

/// rvn_pwindow_t of this platform (the C struct behind the opaque rvn_pwindow_t of platform.h).
const Win32Window = extern struct {
    handle: HWND,
    user: ?*anyopaque,
    flags: u32,
    /// Client size in pixels.
    width: c_int,
    height: c_int,
    min_width: c_int,
    min_height: c_int,
    scale: f32,
    cursor: HCURSOR,
    /// R_CURSOR_NONE: no pointer over the client area.
    cursor_none: c_int,
    /// Icon given by Rwindow_set_icon, destroyed with the window.
    icon: HICON,
    is_child: c_int,
    /// WM_MOUSELEAVE was requested.
    tracking: c_int,
    /// Mouse buttons held: the mouse is captured while it is not zero.
    buttons_down: c_int,
    high_surrogate: WCHAR,
    shown_once: c_int,
    /// The size changed while events could not be delivered.
    size_dirty: c_int,
    /// Last state reported to the core.
    state: platform_h.rvn_pwindow_state_t,
    /// Created to be seen through, with a desktop that composes windows.
    transparent: c_int,
    next: [*c]Win32Window,
};

const Win32State = struct {
    instance: HINSTANCE,
    handler: platform_h.rvn_pevent_handler_t,
    regions: platform_h.rvn_pregion_handler_t,
    wake_event: HANDLE,
    thread_id: DWORD,
    cursors: [RVN_WIN32_CURSOR_COUNT]HCURSOR,
    /// First icon of the executable (resource), or NULL.
    app_icon: HICON,
    app_icon_small: HICON,
    windows: [*c]Win32Window,
    /// Inside the modal loop Windows runs while a window is moved or resized.
    modal_loop: c_int,
    /// Inside rvn_win32_wait_service: nothing may be dispatched to the core.
    waiting: c_int,
    /// Windows 10 1607+; NULL on older systems
    get_dpi_for_window: rvn_win32_get_dpi_for_window_fn,
    adjust_rect_for_dpi: rvn_win32_adjust_rect_for_dpi_fn,
};

var g_win32: Win32State = std.mem.zeroes(Win32State);

const DwmState = struct {
    loaded: c_int,
    enable_blur: rvn_dwm_enable_blur_fn,
    extend_frame: rvn_dwm_extend_frame_fn,
    set_attribute: rvn_dwm_set_attribute_fn,
    is_enabled: rvn_dwm_is_enabled_fn,
    set_composition: rvn_set_composition_fn,
    build: DWORD,
};

var g_dwm: DwmState = std.mem.zeroes(DwmState);

// ---------------------------------------------------------------------------
//  Win32 functions used by this file
// ---------------------------------------------------------------------------

extern "user32" fn GetWindowLongW(hwnd: HWND, index: c_int) callconv(.winapi) LONG;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) LONG_PTR;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: LONG_PTR) callconv(.winapi) LONG_PTR;
extern "user32" fn GetPropW(hwnd: HWND, name: [*c]const WCHAR) callconv(.winapi) HANDLE;
extern "user32" fn SetPropW(hwnd: HWND, name: [*c]const WCHAR, data: HANDLE) callconv(.winapi) BOOL;
extern "user32" fn RemovePropW(hwnd: HWND, name: [*c]const WCHAR) callconv(.winapi) HANDLE;
extern "user32" fn GetDC(hwnd: HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(hwnd: HWND, hdc: HDC) callconv(.winapi) c_int;
extern "user32" fn AdjustWindowRectEx(rect: [*c]RECT, style: DWORD, menu: BOOL, ex_style: DWORD) callconv(.winapi) BOOL;
extern "user32" fn GetKeyState(vkey: c_int) callconv(.winapi) i16;
extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn IsZoomed(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn ScreenToClient(hwnd: HWND, point: [*c]POINT) callconv(.winapi) BOOL;
extern "user32" fn ClientToScreen(hwnd: HWND, point: [*c]POINT) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(hwnd: HWND, insert_after: HWND, x: c_int, y: c_int, cx: c_int, cy: c_int, flags: UINT) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
extern "user32" fn ValidateRect(hwnd: HWND, rect: [*c]const RECT) callconv(.winapi) BOOL;
extern "user32" fn SetTimer(hwnd: HWND, id: UINT_PTR, elapse: UINT, func: ?*anyopaque) callconv(.winapi) UINT_PTR;
extern "user32" fn KillTimer(hwnd: HWND, id: UINT_PTR) callconv(.winapi) BOOL;
extern "user32" fn TrackMouseEvent(event: [*c]TRACKMOUSEEVENT) callconv(.winapi) BOOL;
extern "user32" fn LoadImageW(instance: HINSTANCE, name: ?*const anyopaque, kind: UINT, cx: c_int, cy: c_int, load: UINT) callconv(.winapi) HANDLE;
extern "user32" fn LoadIconW(instance: HINSTANCE, name: ?*const anyopaque) callconv(.winapi) HICON;
extern "user32" fn LoadCursorW(instance: HINSTANCE, name: ?*const anyopaque) callconv(.winapi) HCURSOR;
extern "user32" fn SetCursor(cursor: HCURSOR) callconv(.winapi) HCURSOR;
extern "user32" fn GetCursorPos(point: [*c]POINT) callconv(.winapi) BOOL;
extern "user32" fn WindowFromPoint(point: POINT) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DestroyIcon(icon: HICON) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hwnd: HWND, rect: [*c]RECT) callconv(.winapi) BOOL;
extern "user32" fn GetWindowRect(hwnd: HWND, rect: [*c]RECT) callconv(.winapi) BOOL;
extern "user32" fn SendMessageW(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
extern "user32" fn MonitorFromWindow(hwnd: HWND, flags: DWORD) callconv(.winapi) HMONITOR;
extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: [*c]MONITORINFO) callconv(.winapi) BOOL;
extern "user32" fn SetWindowTextW(hwnd: HWND, text: [*c]const WCHAR) callconv(.winapi) BOOL;
extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, key: COLORREF, alpha: BYTE, flags: DWORD) callconv(.winapi) BOOL;
extern "user32" fn PeekMessageW(msg: [*c]MSG, hwnd: HWND, min: UINT, max: UINT, remove: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(msg: [*c]const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(msg: [*c]const MSG) callconv(.winapi) LRESULT;
extern "user32" fn MsgWaitForMultipleObjectsEx(count: DWORD, handles: [*c]const HANDLE, milliseconds: DWORD, wake_mask: DWORD, flags: DWORD) callconv(.winapi) DWORD;
extern "user32" fn OpenClipboard(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn SetClipboardData(format: UINT, mem: HANDLE) callconv(.winapi) HANDLE;
extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) HANDLE;
extern "user32" fn CreateIconIndirect(info: [*c]ICONINFO) callconv(.winapi) HICON;
extern "user32" fn MapVirtualKeyW(code: UINT, map_type: UINT) callconv(.winapi) UINT;
extern "user32" fn RegisterClassExW(class: [*c]const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn UnregisterClassW(class: [*c]const WCHAR, instance: HINSTANCE) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn CreateWindowExW(ex_style: DWORD, class: [*c]const WCHAR, name: [*c]const WCHAR, style: DWORD, x: c_int, y: c_int, width: c_int, height: c_int, parent: HWND, menu: HMENU, instance: HINSTANCE, param: ?*anyopaque) callconv(.winapi) HWND;
extern "kernel32" fn GetModuleHandleW(name: [*c]const WCHAR) callconv(.winapi) HMODULE;
extern "kernel32" fn LoadLibraryW(name: [*c]const WCHAR) callconv(.winapi) HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*c]const u8) callconv(.winapi) FARPROC;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn EnumResourceNamesW(module: HMODULE, kind: ?*const anyopaque, callback: ?*const fn (HMODULE, [*c]const WCHAR, [*c]WCHAR, LONG_PTR) callconv(.winapi) BOOL, param: LONG_PTR) callconv(.winapi) BOOL;
extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: [*c]const WCHAR) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(object: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: SIZE_T) callconv(.winapi) HGLOBAL;
extern "kernel32" fn GlobalLock(mem: HGLOBAL) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(mem: HGLOBAL) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalFree(mem: HGLOBAL) callconv(.winapi) HGLOBAL;
extern "gdi32" fn GetDeviceCaps(hdc: HDC, index: c_int) callconv(.winapi) c_int;
extern "gdi32" fn CreateRectRgn(left: c_int, top: c_int, right: c_int, bottom: c_int) callconv(.winapi) HRGN;
extern "gdi32" fn DeleteObject(object: HGDIOBJ) callconv(.winapi) BOOL;
extern "gdi32" fn CreateDIBSection(hdc: HDC, info: ?*const anyopaque, usage: UINT, bits: [*c]?*anyopaque, section: HANDLE, offset: DWORD) callconv(.winapi) HBITMAP;
extern "gdi32" fn CreateBitmap(width: c_int, height: c_int, planes: UINT, bit_count: UINT, bits: ?*const anyopaque) callconv(.winapi) HBITMAP;
extern "shell32" fn DragQueryFileW(drop: HDROP, index: UINT, file: [*c]WCHAR, count: UINT) callconv(.winapi) UINT;
extern "shell32" fn DragQueryPoint(drop: HDROP, point: [*c]POINT) callconv(.winapi) BOOL;
extern "shell32" fn DragFinish(drop: HDROP) callconv(.winapi) void;
extern "shell32" fn DragAcceptFiles(hwnd: HWND, accept: BOOL) callconv(.winapi) void;
extern "kernel32" fn MultiByteToWideChar(code_page: UINT, flags: DWORD, mb: [*c]const u8, mb_len: c_int, wc: [*c]WCHAR, wc_len: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(code_page: UINT, flags: DWORD, wc: [*c]const WCHAR, wc_len: c_int, mb: [*c]u8, mb_len: c_int, default_char: ?*const anyopaque, used_default: ?*anyopaque) callconv(.winapi) c_int;
extern "c" fn wcslen(s: [*c]const WCHAR) usize;

// ---------------------------------------------------------------------------
//  Macros of the Win32 headers (function-like macros become inline fn, see PORTING.md 4.8)
// ---------------------------------------------------------------------------

inline fn LOWORD(value: usize) WORD {
    return @truncate(value);
}

inline fn HIWORD(value: usize) WORD {
    return @truncate(value >> 16);
}

inline fn GET_X_LPARAM(lp: LPARAM) c_int {
    return @as(i16, @bitCast(LOWORD(@bitCast(lp))));
}

inline fn GET_Y_LPARAM(lp: LPARAM) c_int {
    return @as(i16, @bitCast(HIWORD(@bitCast(lp))));
}

inline fn GET_WHEEL_DELTA_WPARAM(wp: WPARAM) i16 {
    return @bitCast(HIWORD(wp));
}

/// (HWND)(LONG_PTR)value style conversions of the C file: a pointer stored in a message parameter.
inline fn paramPtr(comptime T: type, value: isize) T {
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

/// (LPARAM)pointer
inline fn ptrParam(p: anytype) isize {
    return @bitCast(@intFromPtr(p));
}

/// `GetKeyState(vk) & 0x8000`, as a condition
inline fn keyState(vk: c_int) u16 {
    return @bitCast(GetKeyState(vk));
}

inline fn keyDown(vk: c_int) bool {
    return (keyState(vk) & 0x8000) != 0;
}

/// The window of a rvn_pwindow_t the core handed back (window->user is its own pointer).
fn winOf(window_: ?*platform_h.rvn_pwindow_t) [*c]Win32Window {
    return @ptrCast(@alignCast(window_));
}

// ---------------------------------------------------------------------------
//  Helpers
// ---------------------------------------------------------------------------

// UTF-8 -> UTF-16. Free with rvn_free.
fn rvn_win32_widen(text_in: [*c]const u8) [*c]WCHAR {
    var text: [*c]const u8 = text_in;
    var count: c_int = undefined;
    var wide: [*c]WCHAR = undefined;
    if (text == null) text = "";
    count = MultiByteToWideChar(CP_UTF8, 0, text, -1, null, 0);
    const n: usize = if (count > 0) @intCast(count) else 1;
    wide = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(WCHAR) * n)));
    if (count > 0) _ = MultiByteToWideChar(CP_UTF8, 0, text, -1, wide, count);
    return wide;
}

// UTF-16 -> UTF-8. Free with rvn_free.
fn rvn_win32_narrow(wide: [*c]const WCHAR) [*c]u8 {
    const count = WideCharToMultiByte(CP_UTF8, 0, wide, -1, null, 0, null, null);
    const n: usize = if (count > 0) @intCast(count) else 1;
    const text: [*c]u8 = @ptrCast(@alignCast(base.rvn_calloc(n)));
    if (count > 0) _ = WideCharToMultiByte(CP_UTF8, 0, wide, -1, text, count, null, null);
    return text;
}

// Looks up a function that only recent versions of Windows have.
fn rvn_win32_user32(name: [*c]const u8) FARPROC {
    const user32 = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"));
    return if (user32 != null) GetProcAddress(user32, name) else null;
}

fn rvn_win32_dpi(handle: HWND) UINT {
    var dpi: UINT = 0;
    if (g_win32.get_dpi_for_window != null and handle != null) dpi = g_win32.get_dpi_for_window.?(handle);
    if (dpi == 0) {
        const screen = GetDC(null);
        dpi = if (screen != null) @intCast(GetDeviceCaps(screen, LOGPIXELSX)) else USER_DEFAULT_SCREEN_DPI;
        if (screen != null) _ = ReleaseDC(null, screen);
    }
    return if (dpi != 0) dpi else USER_DEFAULT_SCREEN_DPI;
}

// Grows a client rectangle to the rectangle of the whole window (title bar, borders).
fn rvn_win32_adjust(handle: HWND, rect: [*c]RECT) void {
    const style: DWORD = @bitCast(GetWindowLongW(handle, GWL_STYLE));
    const ex_style: DWORD = @bitCast(GetWindowLongW(handle, GWL_EXSTYLE));
    const top = rect.*.top;
    if (g_win32.adjust_rect_for_dpi) |adjust| {
        _ = adjust(rect, style, FALSE, ex_style, rvn_win32_dpi(handle));
    } else {
        _ = AdjustWindowRectEx(rect, style, FALSE, ex_style);
    }
    // a custom header has no title bar above the client area (see WM_NCCALCSIZE)
    if (GetPropW(handle, RVN_WIN32_CUSTOM_PROPERTY) != null) rect.*.top = top;
}

fn rvn_win32_emit(window: [*c]Win32Window, event: [*c]platform_h.rvn_pevent_t) void {
    event.*.user = window.*.user;
    g_win32.handler.?(event);
}

fn rvn_win32_emit_resize(window: [*c]Win32Window) void {
    var event = std.mem.zeroes(platform_h.rvn_pevent_t);
    event.type = @intCast(platform_h.RVN_PEVENT_RESIZE);
    event.width = window.*.width;
    event.height = window.*.height;
    event.scale = window.*.scale;
    rvn_win32_emit(window, &event);
}

fn rvn_win32_emit_modal_tick() void {
    var event = std.mem.zeroes(platform_h.rvn_pevent_t);
    event.type = @intCast(platform_h.RVN_PEVENT_MODAL_TICK);
    g_win32.handler.?(&event);
}

fn rvn_win32_modifiers() u32 {
    var modifiers: u32 = 0;
    var ctrl = keyDown(VK_CONTROL);
    var alt = keyDown(VK_MENU);
    // AltGr is reported as Ctrl + right Alt: it types characters, it is not a shortcut
    if (ctrl and keyDown(VK_RMENU) and !keyDown(VK_RCONTROL)) {
        ctrl = false;
        alt = false;
    }
    if (keyDown(VK_SHIFT)) modifiers |= @as(u32, @intCast(raven.R_MOD_SHIFT));
    if (ctrl) modifiers |= @as(u32, @intCast(raven.R_MOD_CTRL));
    if (alt) modifiers |= @as(u32, @intCast(raven.R_MOD_ALT));
    if (((keyState(VK_LWIN) | keyState(VK_RWIN)) & 0x8000) != 0) modifiers |= @as(u32, @intCast(raven.R_MOD_SUPER));
    return modifiers;
}

fn rvn_win32_translate_key(virtual_key: WPARAM, info: LPARAM) raven.RKey {
    const extended: c_int = @intCast((info >> 24) & 1);
    const scancode: UINT = @intCast((info >> 16) & 0xFF);

    if (virtual_key >= 'A' and virtual_key <= 'Z') return @intCast(raven.R_KEY_A + @as(c_int, @intCast(virtual_key - 'A')));
    if (virtual_key >= '0' and virtual_key <= '9') return @intCast(raven.R_KEY_0 + @as(c_int, @intCast(virtual_key - '0')));
    if (virtual_key >= VK_F1 and virtual_key <= VK_F12) return @intCast(raven.R_KEY_F1 + @as(c_int, @intCast(virtual_key - VK_F1)));
    if (virtual_key >= VK_NUMPAD0 and virtual_key <= VK_NUMPAD9) return @intCast(raven.R_KEY_KP_0 + @as(c_int, @intCast(virtual_key - VK_NUMPAD0)));

    switch (virtual_key) {
        VK_SPACE => return @intCast(raven.R_KEY_SPACE),
        VK_OEM_7 => return @intCast(raven.R_KEY_APOSTROPHE),
        VK_OEM_COMMA => return @intCast(raven.R_KEY_COMMA),
        VK_OEM_MINUS => return @intCast(raven.R_KEY_MINUS),
        VK_OEM_PERIOD => return @intCast(raven.R_KEY_PERIOD),
        VK_OEM_2 => return @intCast(raven.R_KEY_SLASH),
        VK_OEM_1 => return @intCast(raven.R_KEY_SEMICOLON),
        VK_OEM_PLUS => return @intCast(raven.R_KEY_EQUAL),
        VK_OEM_4 => return @intCast(raven.R_KEY_LEFT_BRACKET),
        VK_OEM_5 => return @intCast(raven.R_KEY_BACKSLASH),
        VK_OEM_6 => return @intCast(raven.R_KEY_RIGHT_BRACKET),
        VK_OEM_3 => return @intCast(raven.R_KEY_GRAVE),

        VK_ESCAPE => return @intCast(raven.R_KEY_ESCAPE),
        VK_RETURN => return if (extended != 0) @intCast(raven.R_KEY_KP_ENTER) else @intCast(raven.R_KEY_ENTER),
        VK_TAB => return @intCast(raven.R_KEY_TAB),
        VK_BACK => return @intCast(raven.R_KEY_BACKSPACE),
        VK_INSERT => return @intCast(raven.R_KEY_INSERT),
        VK_DELETE => return @intCast(raven.R_KEY_DELETE),
        VK_RIGHT => return @intCast(raven.R_KEY_RIGHT),
        VK_LEFT => return @intCast(raven.R_KEY_LEFT),
        VK_DOWN => return @intCast(raven.R_KEY_DOWN),
        VK_UP => return @intCast(raven.R_KEY_UP),
        VK_PRIOR => return @intCast(raven.R_KEY_PAGE_UP),
        VK_NEXT => return @intCast(raven.R_KEY_PAGE_DOWN),
        VK_HOME => return @intCast(raven.R_KEY_HOME),
        VK_END => return @intCast(raven.R_KEY_END),
        VK_CAPITAL => return @intCast(raven.R_KEY_CAPS_LOCK),
        VK_SNAPSHOT => return @intCast(raven.R_KEY_PRINT_SCREEN),
        VK_PAUSE => return @intCast(raven.R_KEY_PAUSE),
        VK_APPS => return @intCast(raven.R_KEY_MENU),

        VK_DECIMAL => return @intCast(raven.R_KEY_KP_DECIMAL),
        VK_DIVIDE => return @intCast(raven.R_KEY_KP_DIVIDE),
        VK_MULTIPLY => return @intCast(raven.R_KEY_KP_MULTIPLY),
        VK_SUBTRACT => return @intCast(raven.R_KEY_KP_SUBTRACT),
        VK_ADD => return @intCast(raven.R_KEY_KP_ADD),

        // the generic codes do not tell left from right
        VK_SHIFT => return if (@as(usize, MapVirtualKeyW(scancode, MAPVK_VSC_TO_VK_EX)) == VK_RSHIFT) @intCast(raven.R_KEY_RIGHT_SHIFT) else @intCast(raven.R_KEY_LEFT_SHIFT),
        VK_CONTROL => return if (extended != 0) @intCast(raven.R_KEY_RIGHT_CTRL) else @intCast(raven.R_KEY_LEFT_CTRL),
        VK_MENU => return if (extended != 0) @intCast(raven.R_KEY_RIGHT_ALT) else @intCast(raven.R_KEY_LEFT_ALT),
        VK_LWIN => return @intCast(raven.R_KEY_LEFT_SUPER),
        VK_RWIN => return @intCast(raven.R_KEY_RIGHT_SUPER),
        else => return @intCast(raven.R_KEY_UNKNOWN),
    }
}

// ---------------------------------------------------------------------------
//  Window procedure
// ---------------------------------------------------------------------------

fn rvn_win32_mouse_button(window: [*c]Win32Window, button: raven.RMouseButton, pressed: c_int, position: LPARAM) void {
    // keep receiving the mouse while a button is held, also outside the window (drags)
    if (pressed != 0) {
        const was_up = window.*.buttons_down == 0;
        window.*.buttons_down += 1;
        if (was_up) _ = SetCapture(window.*.handle);
    } else if (window.*.buttons_down > 0) {
        window.*.buttons_down -= 1;
        if (window.*.buttons_down == 0) _ = ReleaseCapture();
    }

    var event = std.mem.zeroes(platform_h.rvn_pevent_t);
    event.type = @intCast(platform_h.RVN_PEVENT_MOUSE_BUTTON);
    event.button = @intCast(button);
    event.pressed = pressed;
    event.x = GET_X_LPARAM(position);
    event.y = GET_Y_LPARAM(position);
    event.modifiers = rvn_win32_modifiers();
    rvn_win32_emit(window, &event);
}

fn rvn_win32_key(window: [*c]Win32Window, virtual_key: WPARAM, info: LPARAM, pressed: c_int) void {
    var event = std.mem.zeroes(platform_h.rvn_pevent_t);
    event.type = @intCast(platform_h.RVN_PEVENT_KEY);
    event.key = rvn_win32_translate_key(virtual_key, info);
    event.pressed = pressed;
    event.modifiers = rvn_win32_modifiers();
    // bit 30: the key was already down before this message
    event.repeat = @as(c_int, @intFromBool(pressed != 0 and ((info >> 30) & 1) != 0));
    rvn_win32_emit(window, &event);
}

fn rvn_win32_char(window: [*c]Win32Window, unit: WCHAR) void {
    // characters outside the basic plane arrive as two messages
    var codepoint: u32 = unit;
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        window.*.high_surrogate = unit;
        return;
    }
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        if (window.*.high_surrogate == 0) return;
        codepoint = 0x10000 + (((@as(u32, window.*.high_surrogate) - 0xD800) << 10) + (@as(u32, unit) - 0xDC00));
    }
    window.*.high_surrogate = 0;
    if (codepoint < 32 or codepoint == 127) return;

    var event = std.mem.zeroes(platform_h.rvn_pevent_t);
    event.type = @intCast(platform_h.RVN_PEVENT_TEXT);
    event.codepoint = codepoint;
    rvn_win32_emit(window, &event);
}

// Files dropped from the Explorer.
fn rvn_win32_drop_files(window: [*c]Win32Window, drop: HDROP) void {
    const count: UINT = DragQueryFileW(drop, 0xFFFFFFFF, null, 0);
    const paths: [*c][*c]u8 = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf([*c]u8) * (if (count != 0) @as(usize, count) else 1))));
    var point: POINT = .{ .x = 0, .y = 0 };
    var i: UINT = 0;

    _ = DragQueryPoint(drop, &point);
    while (i < count) : (i += 1) {
        const length: UINT = DragQueryFileW(drop, i, null, 0);
        const wide: [*c]WCHAR = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(WCHAR) * (@as(usize, length) + 1))));
        _ = DragQueryFileW(drop, i, wide, length + 1);
        paths[i] = rvn_win32_narrow(wide);
        base.rvn_free(wide);
    }
    DragFinish(drop);

    if (count > 0) {
        var event = std.mem.zeroes(platform_h.rvn_pevent_t);
        event.type = @intCast(platform_h.RVN_PEVENT_DROP);
        event.x = @intCast(point.x);
        event.y = @intCast(point.y);
        event.drop_paths = @ptrCast(paths);
        event.drop_count = @intCast(count);
        rvn_win32_emit(window, &event);
    }
    i = 0;
    while (i < count) : (i += 1) base.rvn_free(paths[i]);
    base.rvn_free(@ptrCast(paths));
}

// Windows with a custom header. The title bar is removed from the non-client
// area, the borders stay: Windows keeps resizing the window from its left,
// right and bottom edges, and keeps its shadow.
fn rvn_win32_custom_calc_size(handle: HWND, wparam: WPARAM, lparam: LPARAM) LRESULT {
    const params: [*c]NCCALCSIZE_PARAMS = paramPtr([*c]NCCALCSIZE_PARAMS, lparam);
    if (wparam == 0) return DefWindowProcW(handle, WM_NCCALCSIZE, wparam, lparam);
    const top = params.*.rgrc[0].top;
    _ = DefWindowProcW(handle, WM_NCCALCSIZE, wparam, lparam);
    params.*.rgrc[0].top = top;
    // a maximized window is larger than the screen by the thickness of its frame
    if (IsZoomed(handle) != 0) params.*.rgrc[0].top += @as(c_long, GetSystemMetrics(SM_CYFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER));
    return 0;
}

// What the pointer is over: Windows moves, snaps and resizes the window from the answer.
fn rvn_win32_custom_hit_test(window: [*c]Win32Window, wparam: WPARAM, lparam: LPARAM) LRESULT {
    const hit = DefWindowProcW(window.*.handle, WM_NCHITTEST, wparam, lparam);
    var point: POINT = undefined;
    // the borders that are left around the client area
    if (hit != HTCLIENT) return hit;

    point.x = GET_X_LPARAM(lparam);
    point.y = GET_Y_LPARAM(lparam);
    _ = ScreenToClient(window.*.handle, &point);
    const band: c_int = @intFromFloat(@as(f32, RVN_WIN32_TOP_RESIZE) * window.*.scale + 0.5);
    const corner = band * 3;
    if (IsZoomed(window.*.handle) == 0 and (window.*.flags & @as(u32, @intCast(raven.R_WINDOW_NO_RESIZE))) == 0 and point.y < band) {
        if (point.x < corner) return HTTOPLEFT;
        if (point.x >= @as(c_long, window.*.width - corner)) return HTTOPRIGHT;
        return HTTOP;
    }
    if (g_win32.regions) |regions| {
        if (regions(window.*.user, @intCast(point.x), @intCast(point.y)) == @as(platform_h.rvn_pregion_t, @intCast(platform_h.RVN_PREGION_CAPTION))) return HTCAPTION;
    }
    return HTCLIENT;
}

fn rvn_win32_window_proc(handle: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const window: [*c]Win32Window = paramPtr([*c]Win32Window, GetWindowLongPtrW(handle, GWLP_USERDATA));

    // (asked while the window is being created too, before the core knows it)
    if (message == WM_NCCALCSIZE and GetPropW(handle, RVN_WIN32_CUSTOM_PROPERTY) != null) {
        return rvn_win32_custom_calc_size(handle, wparam, lparam);
    }

    // being created or destroyed: the core does not know or no longer knows this window
    if (window == null) return DefWindowProcW(handle, message, wparam, lparam);

    if (g_win32.waiting != 0) {
        // The UI thread is blocked on the render thread and only answers
        // messages sent by other threads (see rvn_win32_wait_service). The
        // core is in the middle of something: nothing is dispatched to it.
        switch (message) {
            WM_SIZE => {
                if (wparam != SIZE_MINIMIZED) window.*.size_dirty = raven.R_TRUE;
                return 0;
            },
            WM_CLOSE => {
                _ = PostMessageW(handle, WM_CLOSE, 0, 0);
                return 0;
            },
            WM_ERASEBKGND => return 1,
            else => return DefWindowProcW(handle, message, wparam, lparam),
        }
    }

    // screen readers (win32_uia.c)
    if (uia.rvn_uia_handle_message(message, wparam, lparam) != 0) return 0;
    if (message == WM_GETOBJECT) {
        var result: LRESULT = undefined;
        if (uia.rvn_uia_get_object(handle, window.*.user, wparam, lparam, &result) != 0) return result;
        return DefWindowProcW(handle, message, wparam, lparam);
    }

    var event = std.mem.zeroes(platform_h.rvn_pevent_t);
    switch (message) {
        WM_CLOSE => {
            // the core decides: it destroys the window unless the application refuses
            event.type = @intCast(platform_h.RVN_PEVENT_CLOSE);
            rvn_win32_emit(window, &event);
            return 0;
        },

        WM_NCHITTEST => {
            if ((window.*.flags & @as(u32, @intCast(raven.R_WINDOW_CUSTOM_HEADER))) != 0) return rvn_win32_custom_hit_test(window, wparam, lparam);
        },

        WM_DROPFILES => {
            rvn_win32_drop_files(window, @ptrFromInt(wparam));
            return 0;
        },

        WM_SIZE => {
            const width: c_int = @as(c_int, LOWORD(@bitCast(lparam)));
            const height: c_int = @as(c_int, HIWORD(@bitCast(lparam)));
            const state: platform_h.rvn_pwindow_state_t = if (wparam == SIZE_MINIMIZED)
                @intCast(platform_h.RVN_PWINDOW_MINIMIZED)
            else if (wparam == SIZE_MAXIMIZED)
                @intCast(platform_h.RVN_PWINDOW_MAXIMIZED)
            else
                @intCast(platform_h.RVN_PWINDOW_NORMAL);
            if (state != window.*.state and (wparam == SIZE_MINIMIZED or wparam == SIZE_MAXIMIZED or wparam == SIZE_RESTORED)) {
                window.*.state = state;
                event.type = @intCast(platform_h.RVN_PEVENT_STATE);
                event.state = state;
                rvn_win32_emit(window, &event);
                event = std.mem.zeroes(platform_h.rvn_pevent_t);
            }
            // a minimized window keeps its size: there is nothing to lay out or render
            if (wparam == SIZE_MINIMIZED) return 0;
            if (width != window.*.width or height != window.*.height) {
                window.*.width = width;
                window.*.height = height;
                rvn_win32_emit_resize(window);
                // live resize: the loop of the application is not running, draw the new size now
                if (g_win32.modal_loop != 0) rvn_win32_emit_modal_tick();
            }
            return 0;
        },

        WM_DPICHANGED => {
            // moved to a monitor with another scale: Windows suggests the new rectangle
            const suggested: [*c]const RECT = paramPtr([*c]const RECT, lparam);
            window.*.scale = @as(f32, @floatFromInt(HIWORD(wparam))) / @as(f32, USER_DEFAULT_SCREEN_DPI);
            _ = SetWindowPos(handle, null, @intCast(suggested.*.left), @intCast(suggested.*.top), @intCast(suggested.*.right - suggested.*.left), @intCast(suggested.*.bottom - suggested.*.top), SWP_NOZORDER | SWP_NOACTIVATE);
            rvn_win32_emit_resize(window);
            return 0;
        },

        WM_GETMINMAXINFO => {
            if (window.*.min_width > 0 or window.*.min_height > 0) {
                const info: [*c]MINMAXINFO = paramPtr([*c]MINMAXINFO, lparam);
                var rect: RECT = .{ .left = 0, .top = 0, .right = @intCast(window.*.min_width), .bottom = @intCast(window.*.min_height) };
                rvn_win32_adjust(handle, &rect);
                info.*.ptMinTrackSize.x = rect.right - rect.left;
                info.*.ptMinTrackSize.y = rect.bottom - rect.top;
                return 0;
            }
        },

        WM_ERASEBKGND => {
            // the renderer covers the whole client area: erasing would only flicker
            return 1;
        },

        WM_PAINT => {
            _ = ValidateRect(handle, null);
            event.type = @intCast(platform_h.RVN_PEVENT_EXPOSE);
            rvn_win32_emit(window, &event);
            return 0;
        },

        // While the user moves or resizes the window, or uses the system
        // menu, Windows runs its own message loop and the loop of the application is not
        // called. A timer keeps frames coming.
        WM_ENTERSIZEMOVE, WM_ENTERMENULOOP => {
            g_win32.modal_loop += 1;
            _ = SetTimer(handle, RVN_WIN32_MODAL_TIMER, USER_TIMER_MINIMUM, null);
        },
        WM_EXITSIZEMOVE, WM_EXITMENULOOP => {
            if (g_win32.modal_loop > 0) g_win32.modal_loop -= 1;
            _ = KillTimer(handle, RVN_WIN32_MODAL_TIMER);
        },
        WM_TIMER => {
            if (wparam == RVN_WIN32_MODAL_TIMER) {
                rvn_win32_emit_modal_tick();
                return 0;
            }
        },

        WM_MOUSEMOVE => {
            if (window.*.tracking == 0) {
                var track = std.mem.zeroes(TRACKMOUSEEVENT);
                track.cbSize = @sizeOf(TRACKMOUSEEVENT);
                track.dwFlags = TME_LEAVE;
                track.hwndTrack = handle;
                _ = TrackMouseEvent(&track);
                window.*.tracking = raven.R_TRUE;
            }
            event.type = @intCast(platform_h.RVN_PEVENT_MOUSE_MOVE);
            event.x = GET_X_LPARAM(lparam);
            event.y = GET_Y_LPARAM(lparam);
            event.modifiers = rvn_win32_modifiers();
            rvn_win32_emit(window, &event);
            return 0;
        },

        WM_MOUSELEAVE => {
            window.*.tracking = raven.R_FALSE;
            event.type = @intCast(platform_h.RVN_PEVENT_MOUSE_LEAVE);
            rvn_win32_emit(window, &event);
            return 0;
        },

        WM_LBUTTONDOWN => {
            rvn_win32_mouse_button(window, @intCast(raven.R_MOUSE_LEFT), raven.R_TRUE, lparam);
            return 0;
        },
        WM_LBUTTONUP => {
            rvn_win32_mouse_button(window, @intCast(raven.R_MOUSE_LEFT), raven.R_FALSE, lparam);
            return 0;
        },
        WM_RBUTTONDOWN => {
            rvn_win32_mouse_button(window, @intCast(raven.R_MOUSE_RIGHT), raven.R_TRUE, lparam);
            return 0;
        },
        WM_RBUTTONUP => {
            rvn_win32_mouse_button(window, @intCast(raven.R_MOUSE_RIGHT), raven.R_FALSE, lparam);
            return 0;
        },
        WM_MBUTTONDOWN => {
            rvn_win32_mouse_button(window, @intCast(raven.R_MOUSE_MIDDLE), raven.R_TRUE, lparam);
            return 0;
        },
        WM_MBUTTONUP => {
            rvn_win32_mouse_button(window, @intCast(raven.R_MOUSE_MIDDLE), raven.R_FALSE, lparam);
            return 0;
        },
        WM_XBUTTONDOWN, WM_XBUTTONUP => {
            const button: raven.RMouseButton = @intCast(if (HIWORD(wparam) == XBUTTON1) raven.R_MOUSE_X1 else raven.R_MOUSE_X2);
            rvn_win32_mouse_button(window, button, @intFromBool(message == WM_XBUTTONDOWN), lparam);
            // these two messages must answer TRUE
            return TRUE;
        },

        WM_CAPTURECHANGED => {
            window.*.buttons_down = 0;
        },

        WM_MOUSEWHEEL, WM_MOUSEHWHEEL => {
            const notches: f32 = @as(f32, @floatFromInt(GET_WHEEL_DELTA_WPARAM(wparam))) / @as(f32, WHEEL_DELTA);
            event.type = @intCast(platform_h.RVN_PEVENT_MOUSE_WHEEL);
            // same convention as the other platforms: positive is up / left
            if (message == WM_MOUSEWHEEL) {
                event.wheel_y = notches;
            } else {
                event.wheel_x = -notches;
            }
            event.modifiers = rvn_win32_modifiers();
            rvn_win32_emit(window, &event);
            return 0;
        },

        WM_KEYDOWN => {
            rvn_win32_key(window, wparam, lparam, raven.R_TRUE);
            return 0;
        },
        WM_KEYUP => {
            rvn_win32_key(window, wparam, lparam, raven.R_FALSE);
            return 0;
        },
        WM_SYSKEYDOWN => {
            // keys pressed with Alt: report them, and let Windows keep Alt+F4 and Alt+Space
            rvn_win32_key(window, wparam, lparam, raven.R_TRUE);
        },
        WM_SYSKEYUP => {
            rvn_win32_key(window, wparam, lparam, raven.R_FALSE);
        },

        WM_CHAR => {
            rvn_win32_char(window, @truncate(wparam));
            return 0;
        },
        WM_SYSCHAR => {
            // Alt+letter would beep; Alt+Space still opens the system menu
            if (wparam != ' ') return 0;
        },
        WM_SYSCOMMAND => {
            // Alt or F10 alone would enter the (absent) menu bar and freeze the application
            if ((wparam & 0xFFF0) == SC_KEYMENU and lparam == 0) return 0;
        },

        WM_SETFOCUS => {
            event.type = @intCast(platform_h.RVN_PEVENT_FOCUS);
            event.focused = raven.R_TRUE;
            rvn_win32_emit(window, &event);
            return 0;
        },
        WM_KILLFOCUS => {
            if (window.*.buttons_down > 0) {
                window.*.buttons_down = 0;
                _ = ReleaseCapture();
            }
            window.*.high_surrogate = 0;
            event.type = @intCast(platform_h.RVN_PEVENT_FOCUS);
            event.focused = raven.R_FALSE;
            rvn_win32_emit(window, &event);
            return 0;
        },

        WM_SETCURSOR => {
            // over the client area the cursor is the one of the hovered widget
            if (LOWORD(@bitCast(lparam)) == HTCLIENT) {
                const cursor: HCURSOR = if (window.*.cursor_none != 0)
                    null
                else if (window.*.cursor != null)
                    window.*.cursor
                else
                    g_win32.cursors[0];
                _ = SetCursor(cursor);
                return TRUE;
            }
        },

        else => {},
    }
    return DefWindowProcW(handle, message, wparam, lparam);
}

// Child windows are surfaces for an external renderer: they take no input.
fn rvn_win32_child_proc(handle: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (message) {
        // the mouse goes through to the parent, so the viewport widget gets the events
        WM_NCHITTEST => return HTTRANSPARENT,
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            _ = ValidateRect(handle, null);
            return 0;
        },
        else => return DefWindowProcW(handle, message, wparam, lparam),
    }
}

// ---------------------------------------------------------------------------
//  Lifecycle
// ---------------------------------------------------------------------------

fn rvn_win32_first_icon(module: HMODULE, type_: [*c]const WCHAR, name: [*c]WCHAR, param: LONG_PTR) callconv(.winapi) BOOL {
    _ = type_;
    _ = param;
    g_win32.app_icon = LoadImageW(module, name, IMAGE_ICON, GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), 0);
    g_win32.app_icon_small = LoadImageW(module, name, IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0);
    return FALSE;
}

fn rvn_win32_init(handler: platform_h.rvn_pevent_handler_t, regions: platform_h.rvn_pregion_handler_t) callconv(.c) c_int {
    // same order as RCursor
    const cursor_names = [RVN_WIN32_CURSOR_COUNT]?*const anyopaque{ IDC_ARROW, IDC_IBEAM, IDC_HAND, IDC_CROSS, IDC_SIZEWE, IDC_SIZENS, IDC_SIZENWSE, IDC_SIZENESW, IDC_SIZEALL, IDC_NO, null };
    var window_class: WNDCLASSEXW = undefined;

    g_win32 = std.mem.zeroes(Win32State);
    g_win32.handler = handler;
    g_win32.regions = regions;
    g_win32.instance = GetModuleHandleW(null);
    g_win32.thread_id = GetCurrentThreadId();

    // sharp rendering on every monitor; ignored when the manifest of the application already chose
    var function: FARPROC = rvn_win32_user32("SetProcessDpiAwarenessContext");
    if (function != null) {
        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
        const set_awareness: rvn_win32_set_awareness_context_fn = @ptrCast(function);
        _ = set_awareness.?(@ptrFromInt(std.math.maxInt(usize) - 3));
    } else {
        function = rvn_win32_user32("SetProcessDPIAware");
        if (function != null) {
            const set_dpi_aware: rvn_win32_set_dpi_aware_fn = @ptrCast(function);
            _ = set_dpi_aware.?();
        }
    }
    g_win32.get_dpi_for_window = @ptrCast(rvn_win32_user32("GetDpiForWindow"));
    g_win32.adjust_rect_for_dpi = @ptrCast(rvn_win32_user32("AdjustWindowRectExForDpi"));

    var i: c_int = 0;
    while (i < RVN_WIN32_CURSOR_COUNT) : (i += 1) {
        const index: usize = @intCast(i);
        g_win32.cursors[index] = if (cursor_names[index] != null) LoadCursorW(null, cursor_names[index]) else null;
    }

    window_class = std.mem.zeroes(WNDCLASSEXW);
    window_class.cbSize = @sizeOf(WNDCLASSEXW);
    window_class.lpfnWndProc = &rvn_win32_window_proc;
    window_class.hInstance = g_win32.instance;
    // the icon of the executable, when it has one
    g_win32.app_icon = null;
    _ = EnumResourceNamesW(g_win32.instance, RT_GROUP_ICON_PTR, &rvn_win32_first_icon, 0);
    window_class.hIcon = if (g_win32.app_icon != null) g_win32.app_icon else LoadIconW(null, IDI_APPLICATION);
    window_class.hIconSm = g_win32.app_icon_small;
    window_class.lpszClassName = RVN_WIN32_CLASS;
    if (RegisterClassExW(&window_class) == 0) {
        base.rvn_error(@intCast(raven.R_ERROR_PLATFORM), @intCast(raven.R_SEVERITY_ERROR), "Win32: cannot register the window class (error %lu)", @as(c_ulong, GetLastError()));
        return raven.R_FALSE;
    }

    window_class = std.mem.zeroes(WNDCLASSEXW);
    window_class.cbSize = @sizeOf(WNDCLASSEXW);
    // a private device context, as OpenGL requires
    window_class.style = CS_OWNDC;
    window_class.lpfnWndProc = &rvn_win32_child_proc;
    window_class.hInstance = g_win32.instance;
    window_class.lpszClassName = RVN_WIN32_CHILD_CLASS;
    if (RegisterClassExW(&window_class) == 0) {
        _ = UnregisterClassW(RVN_WIN32_CLASS, g_win32.instance);
        base.rvn_error(@intCast(raven.R_ERROR_PLATFORM), @intCast(raven.R_SEVERITY_ERROR), "Win32: cannot register the viewport class (error %lu)", @as(c_ulong, GetLastError()));
        return raven.R_FALSE;
    }

    // auto-reset: one SetEvent wakes exactly one wait
    g_win32.wake_event = CreateEventW(null, FALSE, FALSE, null);
    return raven.R_TRUE;
}

fn rvn_win32_shutdown() callconv(.c) void {
    uia.rvn_uia_shutdown();
    if (g_win32.wake_event != null) _ = CloseHandle(g_win32.wake_event);
    _ = UnregisterClassW(RVN_WIN32_CHILD_CLASS, g_win32.instance);
    _ = UnregisterClassW(RVN_WIN32_CLASS, g_win32.instance);
    g_win32 = std.mem.zeroes(Win32State);
}

fn rvn_win32_native_display() callconv(.c) ?*anyopaque {
    return g_win32.instance;
}

// ---------------------------------------------------------------------------
//  Windows
// ---------------------------------------------------------------------------

fn rvn_win32_read_client_size(window: [*c]Win32Window) void {
    var client: RECT = undefined;
    if (GetClientRect(window.*.handle, &client) != 0) {
        window.*.width = @intCast(client.right - client.left);
        window.*.height = @intCast(client.bottom - client.top);
    }
}

fn rvn_win32_window_set_size(window_: ?*platform_h.rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void {
    const window = winOf(window_);
    var rect: RECT = undefined;
    rect.left = 0;
    rect.top = 0;
    rect.right = @intCast(base.rvn_maxi(width, 1));
    rect.bottom = @intCast(base.rvn_maxi(height, 1));
    rvn_win32_adjust(window.*.handle, &rect);
    // answers with WM_SIZE, which reports the new size to the core
    _ = SetWindowPos(window.*.handle, null, 0, 0, @intCast(rect.right - rect.left), @intCast(rect.bottom - rect.top), SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

fn rvn_win32_window_create(desc: [*c]const platform_h.rvn_pwindow_desc_t) callconv(.c) ?*platform_h.rvn_pwindow_t {
    const window: [*c]Win32Window = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(Win32Window))));
    const title = rvn_win32_widen(desc.*.title);
    const flags: u32 = desc.*.flags;

    // (a custom header keeps the style of a normal window: that is what makes Windows snap and animate it)
    var style: DWORD = if ((flags & @as(u32, @intCast(raven.R_WINDOW_BORDERLESS))) != 0)
        WS_POPUP
    else if ((flags & @as(u32, @intCast(raven.R_WINDOW_NO_RESIZE))) != 0)
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX
    else
        WS_OVERLAPPEDWINDOW;
    // native viewports are child windows: never draw over them
    style |= WS_CLIPCHILDREN | WS_CLIPSIBLINGS;

    window.*.user = desc.*.user;
    window.*.flags = desc.*.flags;
    window.*.handle = CreateWindowExW(WS_EX_APPWINDOW, RVN_WIN32_CLASS, title, style, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, null, null, g_win32.instance, null);
    base.rvn_free(title);
    if (window.*.handle == null) {
        base.rvn_error(@intCast(raven.R_ERROR_PLATFORM), @intCast(raven.R_SEVERITY_ERROR), "Win32: cannot create the window (error %lu)", @as(c_ulong, GetLastError()));
        base.rvn_free(window);
        return null;
    }

    if ((flags & @as(u32, @intCast(raven.R_WINDOW_CUSTOM_HEADER))) != 0 and (flags & @as(u32, @intCast(raven.R_WINDOW_BORDERLESS))) == 0) {
        // from now on WM_NCCALCSIZE removes the title bar: have it asked again
        _ = SetPropW(window.*.handle, RVN_WIN32_CUSTOM_PROPERTY, @ptrFromInt(1));
        _ = SetWindowPos(window.*.handle, null, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    } else {
        window.*.flags &= ~@as(u32, @intCast(raven.R_WINDOW_CUSTOM_HEADER));
    }
    DragAcceptFiles(window.*.handle, TRUE);
    window.*.transparent = if ((flags & @as(u32, @intCast(raven.R_WINDOW_TRANSPARENT))) != 0 and rvn_win32_composited() != 0) raven.R_TRUE else raven.R_FALSE;

    // the scale is the one of the monitor Windows placed the window on
    window.*.scale = @as(f32, @floatFromInt(rvn_win32_dpi(window.*.handle))) / @as(f32, USER_DEFAULT_SCREEN_DPI);
    rvn_win32_window_set_size(@ptrCast(window), @intFromFloat(@as(f32, @floatFromInt(desc.*.width)) * window.*.scale + 0.5), @intFromFloat(@as(f32, @floatFromInt(desc.*.height)) * window.*.scale + 0.5));
    rvn_win32_read_client_size(window);

    // from now on the window procedure reports events to the core
    _ = SetWindowLongPtrW(window.*.handle, GWLP_USERDATA, ptrParam(window));
    window.*.next = g_win32.windows;
    g_win32.windows = window;
    return @ptrCast(window);
}

// ---------------------------------------------------------------------------
//  Windows that are seen through
//
//  The desktop window manager blends a window with what is behind it when
//  the window asks for "blur behind" on an empty region: the alpha of what
//  the application presents is then used. What it puts behind (nothing, a
//  blur, acrylic, mica) depends on the version of Windows:
//    Windows 11 22H2 and later   the system backdrops (DWMWA_SYSTEMBACKDROP_TYPE)
//    Windows 11 21H2             mica through its first attribute
//    Windows 10                  blur and acrylic through the accent policy
//                                of the window (SetWindowCompositionAttribute)
//  dwmapi.dll and the functions of user32 that are not in every SDK are
//  looked up at run time.
// ---------------------------------------------------------------------------

fn rvn_win32_dwm_load() void {
    if (g_dwm.loaded != 0) return;
    g_dwm.loaded = raven.R_TRUE;
    const dwm = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dwmapi.dll"));
    const user = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll"));
    const ntdll = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll"));
    if (dwm != null) {
        g_dwm.enable_blur = @ptrCast(GetProcAddress(dwm, "DwmEnableBlurBehindWindow"));
        g_dwm.extend_frame = @ptrCast(GetProcAddress(dwm, "DwmExtendFrameIntoClientArea"));
        g_dwm.set_attribute = @ptrCast(GetProcAddress(dwm, "DwmSetWindowAttribute"));
        g_dwm.is_enabled = @ptrCast(GetProcAddress(dwm, "DwmIsCompositionEnabled"));
    }
    if (user != null) g_dwm.set_composition = @ptrCast(GetProcAddress(user, "SetWindowCompositionAttribute"));
    if (ntdll != null) {
        // (GetVersionEx answers with the version the manifest of the program names, not the real one)
        const get_version: rvn_rtl_get_version_fn = @ptrCast(GetProcAddress(ntdll, "RtlGetVersion"));
        var version: OSVERSIONINFOW = std.mem.zeroes(OSVERSIONINFOW);
        version.dwOSVersionInfoSize = @sizeOf(OSVERSIONINFOW);
        if (get_version != null and get_version.?(&version) == 0) g_dwm.build = version.dwBuildNumber;
    }
}

fn rvn_win32_composited() c_int {
    var enabled: BOOL = FALSE;
    rvn_win32_dwm_load();
    if (g_dwm.enable_blur != null and g_dwm.is_enabled != null) {
        const hr = g_dwm.is_enabled.?(&enabled);
        if (hr >= 0 and enabled != 0) return raven.R_TRUE;
    }
    return raven.R_FALSE;
}

// The alpha of what is presented in the window counts (or no longer does).
fn rvn_win32_set_alpha(window: [*c]Win32Window, enabled: c_int) void {
    // an empty region: nothing is blurred by this call, but the window is composed with its alpha
    const region = CreateRectRgn(0, 0, -1, -1);
    var blur = std.mem.zeroes(rvn_win32_blur_behind_t);
    blur.flags = 0x1 | 0x2; // DWM_BB_ENABLE | DWM_BB_BLURREGION
    blur.enable = if (enabled != 0) TRUE else FALSE;
    blur.region = region;
    _ = g_dwm.enable_blur.?(window.*.handle, &blur);
    _ = DeleteObject(region);
}

fn rvn_win32_set_accent(window: [*c]Win32Window, state: c_int, color: DWORD) void {
    if (g_dwm.set_composition == null) return;
    var accent = std.mem.zeroes(rvn_win32_accent_t);
    accent.state = state;
    // (2: the gradient color is drawn over what is blurred)
    accent.flags = if (state == 4) 2 else 0;
    accent.gradient_color = color;
    var data: rvn_win32_composition_t = undefined;
    data.attribute = WCA_ACCENT_POLICY; // WCA_ACCENT_POLICY
    data.data = &accent;
    data.size = @sizeOf(rvn_win32_accent_t);
    _ = g_dwm.set_composition.?(window.*.handle, &data);
}

fn rvn_win32_window_set_backdrop(window_: ?*platform_h.rvn_pwindow_t, backdrop_in: c_int, dark: c_int) callconv(.c) c_int {
    const window = winOf(window_);
    const dark_mode: BOOL = if (dark != 0) TRUE else FALSE;
    var system_type: c_int = 1; // DWMSBT_NONE
    var backdrop = backdrop_in;
    var given = backdrop;
    var margins = std.mem.zeroes(rvn_win32_margins_t);

    if (window.*.transparent == 0) return raven.R_BACKDROP_NONE;
    // the materials of the system are light or dark with the theme of the application
    if (g_dwm.set_attribute) |set_attribute| _ = set_attribute(window.*.handle, 20, &dark_mode, @sizeOf(BOOL)); // DWMWA_USE_IMMERSIVE_DARK_MODE

    if (backdrop == raven.R_BACKDROP_MICA and g_dwm.build < 22000) {
        backdrop = raven.R_BACKDROP_ACRYLIC;
        given = backdrop;
    }
    rvn_win32_set_alpha(window, @intFromBool(backdrop != raven.R_BACKDROP_NONE));
    rvn_win32_set_accent(window, 0, 0);

    if (backdrop == raven.R_BACKDROP_BLUR) {
        // ACCENT_ENABLE_BLURBEHIND
        if (g_dwm.set_composition != null) rvn_win32_set_accent(window, 3, 0) else given = raven.R_BACKDROP_TRANSPARENT;
    } else if (backdrop == raven.R_BACKDROP_ACRYLIC) {
        if (g_dwm.build >= 22621 and g_dwm.set_attribute != null) {
            system_type = 3; // DWMSBT_TRANSIENTWINDOW: acrylic
        } else if (g_dwm.set_composition != null) {
            // ACCENT_ENABLE_ACRYLICBLURBEHIND, with a veil of the color of the theme (0xAABBGGRR)
            rvn_win32_set_accent(window, 4, if (dark != 0) 0x99202020 else 0x99F3F3F3);
        } else {
            given = raven.R_BACKDROP_TRANSPARENT;
        }
    } else if (backdrop == raven.R_BACKDROP_MICA) {
        if (g_dwm.build >= 22621) {
            system_type = 2; // DWMSBT_MAINWINDOW: mica
        } else if (g_dwm.set_attribute) |set_attribute| {
            var mica: BOOL = TRUE;
            _ = set_attribute(window.*.handle, 1029, &mica, @sizeOf(BOOL)); // DWMWA_MICA_EFFECT, Windows 11 21H2
        }
    }
    if (g_dwm.build >= 22621 and g_dwm.set_attribute != null) {
        _ = g_dwm.set_attribute.?(window.*.handle, 38, &system_type, @sizeOf(c_int)); // DWMWA_SYSTEMBACKDROP_TYPE
    }
    // the materials of the system are drawn in the frame of the window: the frame is extended over the whole of it
    if (g_dwm.extend_frame) |extend_frame| {
        if (backdrop == raven.R_BACKDROP_ACRYLIC or backdrop == raven.R_BACKDROP_MICA) {
            margins.left = -1;
            margins.right = -1;
            margins.top = -1;
            margins.bottom = -1;
        }
        _ = extend_frame(window.*.handle, &margins);
    }
    return given;
}

fn rvn_win32_window_set_opacity(window_: ?*platform_h.rvn_pwindow_t, opacity: f32) callconv(.c) c_int {
    const window = winOf(window_);
    const style: LONG_PTR = GetWindowLongPtrW(window.*.handle, GWL_EXSTYLE);
    if (opacity >= 0.999) {
        if ((style & WS_EX_LAYERED) != 0) _ = SetWindowLongPtrW(window.*.handle, GWL_EXSTYLE, style & ~@as(LONG_PTR, WS_EX_LAYERED));
        return raven.R_TRUE;
    }
    if ((style & WS_EX_LAYERED) == 0) _ = SetWindowLongPtrW(window.*.handle, GWL_EXSTYLE, style | WS_EX_LAYERED);
    return @intFromBool(SetLayeredWindowAttributes(window.*.handle, 0, @intFromFloat(opacity * 255.0 + 0.5), LWA_ALPHA) != 0);
}

fn rvn_win32_window_set_topmost(window_: ?*platform_h.rvn_pwindow_t, topmost: c_int) callconv(.c) c_int {
    const window = winOf(window_);
    return @intFromBool(SetWindowPos(window.*.handle, if (topmost != 0) HWND_TOPMOST else HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) != 0);
}

fn rvn_win32_window_center(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) void {
    const window = winOf(window_);
    var info: MONITORINFO = undefined;
    var rect: RECT = undefined;
    const monitor = MonitorFromWindow(window.*.handle, MONITOR_DEFAULTTOPRIMARY);
    info.cbSize = @sizeOf(MONITORINFO);
    if (GetMonitorInfoW(monitor, &info) == 0 or GetWindowRect(window.*.handle, &rect) == 0) return;
    {
        const w = rect.right - rect.left;
        const h = rect.bottom - rect.top;
        const x = info.rcWork.left + @divTrunc((info.rcWork.right - info.rcWork.left) - w, 2);
        const y = info.rcWork.top + @divTrunc((info.rcWork.bottom - info.rcWork.top) - h, 2);
        _ = SetWindowPos(window.*.handle, null, @intCast(x), @intCast(y), 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

fn rvn_win32_window_destroy(window: [*c]Win32Window) void {
    var link: [*c][*c]Win32Window = &g_win32.windows;
    while (link.* != null) : (link = &link.*.*.next) {
        if (link.* == window) {
            link.* = window.*.next;
            break;
        }
    }
    // the screen readers forget its providers
    uia.rvn_uia_window_destroyed(window.*.handle);
    // DestroyWindow sends messages: they must not reach the core any more
    _ = SetWindowLongPtrW(window.*.handle, GWLP_USERDATA, 0);
    _ = RemovePropW(window.*.handle, RVN_WIN32_CUSTOM_PROPERTY);
    _ = DestroyWindow(window.*.handle);
    if (window.*.icon != null) _ = DestroyIcon(window.*.icon);
    base.rvn_free(window);
}

fn rvn_win32_window_set_title(window_: ?*platform_h.rvn_pwindow_t, title: [*c]const u8) callconv(.c) void {
    const window = winOf(window_);
    const wide = rvn_win32_widen(title);
    _ = SetWindowTextW(window.*.handle, wide);
    base.rvn_free(wide);
}

fn rvn_win32_window_get_size(window_: ?*platform_h.rvn_pwindow_t, width: [*c]c_int, height: [*c]c_int) callconv(.c) void {
    const window = winOf(window_);
    width.* = window.*.width;
    height.* = window.*.height;
}

fn rvn_win32_window_set_min_size(window_: ?*platform_h.rvn_pwindow_t, width: c_int, height: c_int) callconv(.c) void {
    const window = winOf(window_);
    window.*.min_width = width;
    window.*.min_height = height;
}

fn rvn_win32_window_set_position(window_: ?*platform_h.rvn_pwindow_t, x: c_int, y: c_int) callconv(.c) void {
    const window = winOf(window_);
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    // x, y is the client area: find where the frame around it starts
    rvn_win32_adjust(window.*.handle, &rect);
    _ = SetWindowPos(window.*.handle, null, x + @as(c_int, @intCast(rect.left)), y + @as(c_int, @intCast(rect.top)), 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
}

fn rvn_win32_window_get_position(window_: ?*platform_h.rvn_pwindow_t, x: [*c]c_int, y: [*c]c_int) callconv(.c) void {
    const window = winOf(window_);
    var origin: POINT = .{ .x = 0, .y = 0 };
    _ = ClientToScreen(window.*.handle, &origin);
    x.* = @intCast(origin.x);
    y.* = @intCast(origin.y);
}

fn rvn_win32_window_get_scale(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) f32 {
    const window = winOf(window_);
    return if (window.*.scale > 0.0) window.*.scale else 1.0;
}

fn rvn_win32_window_show(window_: ?*platform_h.rvn_pwindow_t, visible: c_int) callconv(.c) void {
    const window = winOf(window_);
    if (visible == 0) {
        _ = ShowWindow(window.*.handle, SW_HIDE);
    } else if (window.*.shown_once == 0 and (window.*.flags & @as(u32, @intCast(raven.R_WINDOW_MAXIMIZED))) != 0) {
        _ = ShowWindow(window.*.handle, SW_SHOWMAXIMIZED);
    } else {
        _ = ShowWindow(window.*.handle, SW_SHOW);
    }
    if (visible != 0) window.*.shown_once = raven.R_TRUE;
}

fn rvn_win32_window_set_state(window_: ?*platform_h.rvn_pwindow_t, state: platform_h.rvn_pwindow_state_t) callconv(.c) void {
    const window = winOf(window_);
    switch (state) {
        @as(platform_h.rvn_pwindow_state_t, @intCast(platform_h.RVN_PWINDOW_MINIMIZED)) => _ = ShowWindow(window.*.handle, SW_MINIMIZE),
        @as(platform_h.rvn_pwindow_state_t, @intCast(platform_h.RVN_PWINDOW_MAXIMIZED)) => _ = ShowWindow(window.*.handle, SW_MAXIMIZE),
        @as(platform_h.rvn_pwindow_state_t, @intCast(platform_h.RVN_PWINDOW_NORMAL)) => _ = ShowWindow(window.*.handle, SW_RESTORE),
        else => {},
    }
    window.*.shown_once = raven.R_TRUE;
}

fn rvn_win32_window_get_state(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) platform_h.rvn_pwindow_state_t {
    const window = winOf(window_);
    if (IsIconic(window.*.handle) != 0) return @intCast(platform_h.RVN_PWINDOW_MINIMIZED);
    return if (IsZoomed(window.*.handle) != 0) @intCast(platform_h.RVN_PWINDOW_MAXIMIZED) else @intCast(platform_h.RVN_PWINDOW_NORMAL);
}

// Starts the move or the resize Windows does for a title bar or a border: it returns when the button is released.
fn rvn_win32_system_drag(window: [*c]Win32Window, command: WPARAM) void {
    if (window.*.buttons_down > 0) {
        window.*.buttons_down = 0;
        _ = ReleaseCapture();
    }
    _ = SendMessageW(window.*.handle, WM_SYSCOMMAND, command, 0);
}

fn rvn_win32_window_begin_move(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) void {
    const window = winOf(window_);
    // SC_MOVE with the code of the caption: a move with the mouse, not with the keyboard
    rvn_win32_system_drag(window, SC_MOVE | 0x0002);
}

fn rvn_win32_window_begin_resize(window_: ?*platform_h.rvn_pwindow_t, edge: platform_h.rvn_pregion_t) callconv(.c) void {
    const window = winOf(window_);
    // WMSZ_... codes, in the order of rvn_pregion_t from RVN_PREGION_LEFT
    const sides = [_]WPARAM{ 1, 2, 3, 6, 4, 5, 7, 8 };
    const first: platform_h.rvn_pregion_t = @intCast(platform_h.RVN_PREGION_LEFT);
    const last: platform_h.rvn_pregion_t = @intCast(platform_h.RVN_PREGION_BOTTOM_RIGHT);
    if (edge < first or edge > last) return;
    rvn_win32_system_drag(window, SC_SIZE | sides[edge - first]);
}

fn rvn_win32_window_set_cursor(window_: ?*platform_h.rvn_pwindow_t, cursor: raven.RCursor) callconv(.c) void {
    const window = winOf(window_);
    var index: c_int = @as(c_int, @intCast(cursor)) - raven.R_CURSOR_ARROW;
    var position: POINT = undefined;
    if (index < 0 or index >= RVN_WIN32_CURSOR_COUNT) index = 0;
    window.*.cursor_none = @intFromBool(cursor == @as(raven.RCursor, @intCast(raven.R_CURSOR_NONE)));
    window.*.cursor = if (window.*.cursor_none != 0) null else g_win32.cursors[@intCast(index)];
    // WM_SETCURSOR only comes with the next mouse move: apply now when the mouse is over the window
    if (GetCursorPos(&position) != 0 and WindowFromPoint(position) == window.*.handle) _ = SetCursor(window.*.cursor);
}

fn rvn_win32_window_set_icon(window_: ?*platform_h.rvn_pwindow_t, rgba: [*c]const u8, width: c_int, height: c_int) callconv(.c) void {
    const window = winOf(window_);
    var icon: HICON = null;
    if (rgba != null and width > 0 and height > 0) {
        var header = std.mem.zeroes(BITMAPV5HEADER);
        var info: ICONINFO = undefined;
        var bits: ?*anyopaque = null;
        const dc = GetDC(null);
        header.bV5Size = @sizeOf(BITMAPV5HEADER);
        header.bV5Width = width;
        header.bV5Height = -height;
        header.bV5Planes = 1;
        header.bV5BitCount = 32;
        header.bV5Compression = BI_BITFIELDS;
        header.bV5RedMask = 0x00FF0000;
        header.bV5GreenMask = 0x0000FF00;
        header.bV5BlueMask = 0x000000FF;
        header.bV5AlphaMask = 0xFF000000;
        const color = CreateDIBSection(dc, &header, DIB_RGB_COLORS, &bits, null, 0);
        _ = ReleaseDC(null, dc);
        if (color == null or bits == null) {
            if (color != null) _ = DeleteObject(color);
            return;
        }
        const out_base: [*c]u8 = @ptrCast(bits);
        var i: c_int = 0;
        while (i < width * height) : (i += 1) {
            const offset: usize = @as(usize, @intCast(i)) * 4;
            const out_ = out_base + offset;
            const in_ = rgba + offset;
            out_[0] = in_[2];
            out_[1] = in_[1];
            out_[2] = in_[0];
            out_[3] = in_[3];
        }
        const mask = CreateBitmap(width, height, 1, 1, null);
        info = std.mem.zeroes(ICONINFO);
        info.fIcon = TRUE;
        info.hbmColor = color;
        info.hbmMask = mask;
        icon = CreateIconIndirect(&info);
        _ = DeleteObject(color);
        if (mask != null) _ = DeleteObject(mask);
        if (icon == null) return;
    }
    _ = SendMessageW(window.*.handle, WM_SETICON, ICON_BIG, ptrParam(if (icon != null) icon else g_win32.app_icon));
    _ = SendMessageW(window.*.handle, WM_SETICON, ICON_SMALL, ptrParam(if (icon != null) icon else g_win32.app_icon_small));
    if (window.*.icon != null) _ = DestroyIcon(window.*.icon);
    window.*.icon = icon;
}

fn rvn_win32_window_get_native(window_: ?*platform_h.rvn_pwindow_t, native: [*c]raven.RNativeWindow) callconv(.c) void {
    const window = winOf(window_);
    native.*.system = @intCast(raven.R_WINDOW_SYSTEM_WIN32);
    native.*.display = g_win32.instance;
    native.*.window = @intFromPtr(window.*.handle);
    native.*.visual = 0;
    native.*.transparent = window.*.transparent;
}

// ---------------------------------------------------------------------------
//  Child windows (native viewports)
// ---------------------------------------------------------------------------

fn rvn_win32_child_create(parent_: ?*platform_h.rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) ?*platform_h.rvn_pwindow_t {
    const parent = winOf(parent_);
    const child: [*c]Win32Window = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(Win32Window))));
    child.*.user = user;
    child.*.is_child = raven.R_TRUE;
    child.*.width = base.rvn_maxi(width, 1);
    child.*.height = base.rvn_maxi(height, 1);
    child.*.scale = parent.*.scale;
    child.*.handle = CreateWindowExW(0, RVN_WIN32_CHILD_CLASS, std.unicode.utf8ToUtf16LeStringLiteral(""), WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS, x, y, child.*.width, child.*.height, parent.*.handle, null, g_win32.instance, null);
    if (child.*.handle == null) {
        base.rvn_free(child);
        return null;
    }
    return @ptrCast(child);
}

fn rvn_win32_child_set_rect(child_: ?*platform_h.rvn_pwindow_t, x: c_int, y: c_int, width: c_int, height: c_int, visible: c_int) callconv(.c) void {
    const child = winOf(child_);
    if (visible != 0) {
        child.*.width = base.rvn_maxi(width, 1);
        child.*.height = base.rvn_maxi(height, 1);
        _ = SetWindowPos(child.*.handle, null, x, y, child.*.width, child.*.height, SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    } else {
        _ = ShowWindow(child.*.handle, SW_HIDE);
    }
}

// Child windows are not in the list of windows and have no user data.
fn rvn_win32_any_destroy(window_: ?*platform_h.rvn_pwindow_t) callconv(.c) void {
    const window = winOf(window_);
    if (window.*.is_child != 0) {
        _ = DestroyWindow(window.*.handle);
        base.rvn_free(window);
    } else {
        rvn_win32_window_destroy(window);
    }
}

// ---------------------------------------------------------------------------
//  Clipboard
// ---------------------------------------------------------------------------

fn rvn_win32_clipboard_set(text: [*c]const u8) callconv(.c) void {
    const wide = rvn_win32_widen(text);
    const bytes: usize = (wcslen(wide) + 1) * @sizeOf(WCHAR);
    const memory = GlobalAlloc(GMEM_MOVEABLE, bytes);

    if (memory != null) {
        const target = GlobalLock(memory);
        if (target != null) {
            const dst: [*]u8 = @ptrCast(target);
            const src: [*]const u8 = @ptrCast(wide);
            @memcpy(dst[0..bytes], src[0..bytes]);
            _ = GlobalUnlock(memory);
        }
        if (target != null and OpenClipboard(null) != 0) {
            _ = EmptyClipboard();
            // on success the clipboard owns the memory
            if (SetClipboardData(CF_UNICODETEXT, memory) == null) _ = GlobalFree(memory);
            _ = CloseClipboard();
        } else {
            _ = GlobalFree(memory);
        }
    }
    base.rvn_free(wide);
}

fn rvn_win32_clipboard_get() callconv(.c) [*c]u8 {
    var text: [*c]u8 = null;
    if (OpenClipboard(null) == 0) return null;
    const memory = GetClipboardData(CF_UNICODETEXT);
    if (memory != null) {
        const wide: [*c]const WCHAR = @ptrCast(@alignCast(GlobalLock(memory)));
        if (wide != null) {
            text = rvn_win32_narrow(wide);
            _ = GlobalUnlock(memory);
        }
    }
    _ = CloseClipboard();
    return text;
}

// ---------------------------------------------------------------------------
//  Events
// ---------------------------------------------------------------------------

fn rvn_win32_pump(timeout_seconds: f64) callconv(.c) void {
    var message: MSG = undefined;

    if (timeout_seconds != 0.0) {
        const timeout: DWORD = if (timeout_seconds < 0.0) INFINITE else @intFromFloat(timeout_seconds * 1000.0 + 0.999);
        // returns when a message is available, when another thread calls wake, or after the timeout
        _ = MsgWaitForMultipleObjectsEx(if (g_win32.wake_event != null) 1 else 0, &g_win32.wake_event, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    }

    // sizes that changed while the core could not be told
    var window = g_win32.windows;
    while (window != null) : (window = window.*.next) {
        if (window.*.size_dirty != 0) {
            const width = window.*.width;
            const height = window.*.height;
            window.*.size_dirty = raven.R_FALSE;
            rvn_win32_read_client_size(window);
            if (window.*.width != width or window.*.height != height) {
                rvn_win32_emit_resize(window);
                // the event may have destroyed windows: the list is no longer safe to walk
                break;
            }
        }
    }

    while (PeekMessageW(&message, null, 0, 0, PM_REMOVE) != 0) {
        // WM_QUIT is not used: the application stops with Rquit
        if (message.message == WM_QUIT) continue;
        _ = TranslateMessage(&message);
        _ = DispatchMessageW(&message);
    }
}

fn rvn_win32_wake() callconv(.c) void {
    if (g_win32.wake_event != null) _ = SetEvent(g_win32.wake_event);
}

// Called while the UI thread waits for the render thread. Graphics drivers
// send messages to the window from the render thread when they create or
// resize a swapchain; if this thread did not answer them, both threads would
// wait for each other forever. PeekMessage delivers the messages sent by
// other threads; the posted ones (input, paint) stay in the queue.
fn rvn_win32_wait_service() callconv(.c) void {
    var message: MSG = undefined;
    if (GetCurrentThreadId() != g_win32.thread_id) return;
    g_win32.waiting += 1;
    _ = PeekMessageW(&message, null, 0, 0, PM_NOREMOVE | PM_QS_SENDMESSAGE);
    g_win32.waiting -= 1;
}

// ---- accessibility: UI Automation (win32_uia.c) ----

fn rvn_win32_a11y_event(window_: ?*platform_h.rvn_pwindow_t, event: c_int, node: u64) callconv(.c) void {
    const window = winOf(window_);
    uia.rvn_uia_event(window.*.handle, event, node);
}

fn rvn_win32_a11y_announce(window_: ?*platform_h.rvn_pwindow_t, text: [*c]const u8, assertive: c_int) callconv(.c) void {
    const window = winOf(window_);
    uia.rvn_uia_announce(window.*.handle, window.*.user, text, assertive);
}

/// The Win32 window system (platform.h: rvn_platform_win32). Exported only on Windows, see the comptime block below.
fn rvn_platform_win32() callconv(.c) [*c]const platform_h.rvn_platform_t {
    return &platform;
}

const platform: platform_h.rvn_platform_t = .{
    .name = "Win32",
    .system = @intCast(raven.R_WINDOW_SYSTEM_WIN32),
    .init = &rvn_win32_init,
    .shutdown = &rvn_win32_shutdown,
    .native_display = &rvn_win32_native_display,
    .window_create = &rvn_win32_window_create,
    .window_destroy = &rvn_win32_any_destroy,
    .window_set_title = &rvn_win32_window_set_title,
    .window_set_size = &rvn_win32_window_set_size,
    .window_get_size = &rvn_win32_window_get_size,
    .window_set_min_size = &rvn_win32_window_set_min_size,
    .window_set_position = &rvn_win32_window_set_position,
    .window_get_position = &rvn_win32_window_get_position,
    .window_get_scale = &rvn_win32_window_get_scale,
    .window_show = &rvn_win32_window_show,
    .window_set_state = &rvn_win32_window_set_state,
    .window_get_state = &rvn_win32_window_get_state,
    .window_begin_move = &rvn_win32_window_begin_move,
    .window_begin_resize = &rvn_win32_window_begin_resize,
    .native_regions = raven.R_TRUE,
    .window_set_backdrop = &rvn_win32_window_set_backdrop,
    .window_set_opacity = &rvn_win32_window_set_opacity,
    .window_set_topmost = &rvn_win32_window_set_topmost,
    .window_center = &rvn_win32_window_center,
    .window_set_icon = &rvn_win32_window_set_icon,
    .window_set_cursor = &rvn_win32_window_set_cursor,
    .window_get_native = &rvn_win32_window_get_native,
    .child_create = &rvn_win32_child_create,
    .child_set_rect = &rvn_win32_child_set_rect,
    .pump = &rvn_win32_pump,
    .wake = &rvn_win32_wake,
    .clipboard_set = &rvn_win32_clipboard_set,
    .clipboard_get = &rvn_win32_clipboard_get,
    .wait_service = &rvn_win32_wait_service,
    .a11y_event = &rvn_win32_a11y_event,
    .a11y_announce = &rvn_win32_a11y_announce,
    .a11y_active = &uia.rvn_uia_active,
    .a11y_settings = &uia.rvn_uia_settings,
};

// The exports of the C file. The C file is `#if defined(_WIN32)`: on the other
// targets nothing is exported (the same comptime block as win32_uia.zig).
comptime {
    if (builtin.os.tag == .windows) {
        @export(&rvn_platform_win32, .{ .name = "rvn_platform_win32" });
    }
}
