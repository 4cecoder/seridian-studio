// Translated to Zig from vendor/raven/src/platform/win32/win32_uia.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - platform/win32/win32_uia.c
// The windows of Raven for the screen readers of Windows (Narrator, NVDA,
// JAWS): a UI Automation provider, in C.
//
// Each node of core/accessibility.h is a provider object made on first use
// and kept in a table: IRawElementProviderSimple and ...Fragment for all,
// ...FragmentRoot for the windows, and the patterns that apply: Invoke
// (buttons, menu items, tabs), Toggle (check boxes), Value (text fields),
// RangeValue (sliders, spin boxes, progress bars), ExpandCollapse (expanders,
// combo boxes, tree items), SelectionItem (rows, tabs).
//
// The window answers WM_GETOBJECT with the provider of its root
// (win32_platform.c). UI Automation is called in the apartment of the UI
// thread (CoInitializeEx STA, ProviderOptions_UseComThreading); a call that
// still arrives on another thread is sent to the UI thread with
// SendMessage, so the library is only ever touched there.
//
// UIAutomationCore.dll and OleAut32.dll are loaded when first needed: Raven
// links with nothing more.
//
// <windows.h>, <ole2.h>, <oleauto.h> and <uiautomation.h> are not available
// to Zig: the Win32 types, the UI Automation interfaces (vtables and GUIDs)
// and the constants used here are declared by hand below, from the SDK.
//
// Exports: this file defines Win32 entry points only. They are emitted by the
// comptime block at the end of the file, and only when the target is Windows
// (the C file is `#if defined(_WIN32)`), so the other platforms export nothing.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("../../core/base_h.zig");
const a11y = @import("../../core/accessibility_h.zig");
const libc = @import("../../sys/libc.zig");
const uia_h = @import("win32_uia_h.zig");

const HWND = uia_h.HWND;
const WPARAM = uia_h.WPARAM;
const LPARAM = uia_h.LPARAM;
const LRESULT = uia_h.LRESULT;
const UINT = uia_h.UINT;

// ---------------------------------------------------------------------------
//  Win32 and COM types (windef.h, wtypes.h, unknwn.h, oleauto.h, uiautomationcore.h)
// ---------------------------------------------------------------------------
const BOOL = c_int;
const DWORD = u32;
const HRESULT = i32;
const LONG = i32;
const ULONG = u32;
const HMODULE = ?*anyopaque;
const HKEY = ?*anyopaque;
const BSTR = [*c]u16;
const LPCWSTR = [*c]const u16;
const LCID = u32;
const VARTYPE = u16;
const VARIANT_BOOL = i16;
const PATTERNID = c_int;
const PROPERTYID = c_int;
const EVENTID = c_int;
const LSTATUS = i32;

const IUnknown = opaque {};
const SAFEARRAY = opaque {};

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};
const REFIID = *const GUID;

/// DECIMAL (wtypes.h): 16 bytes; it is the other member of the VARIANT union.
const DECIMAL = extern struct {
    wReserved: u16,
    scale: u8,
    sign: u8,
    Hi32: u32,
    Lo64: u64,
};

/// VARIANT (oleauto.h): 24 bytes on x64 (the 16-byte DECIMAL union follows the 8-byte header).
const VARIANT = extern struct {
    vt: VARTYPE,
    wReserved1: u16,
    wReserved2: u16,
    wReserved3: u16,
    u: extern union {
        lVal: LONG,
        dblVal: f64,
        boolVal: VARIANT_BOOL,
        bstrVal: BSTR,
        decVal: DECIMAL,
    },
};

/// struct UiaRect (uiautomationcore.h)
const UiaRect = extern struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,
};

const HIGHCONTRASTW = extern struct {
    cbSize: UINT,
    dwFlags: DWORD,
    lpszDefaultScheme: [*c]u16,
};

const TRUE: BOOL = 1;
const FALSE: BOOL = 0;
const VARIANT_TRUE: VARIANT_BOOL = -1;
const VARIANT_FALSE: VARIANT_BOOL = 0;

/// HRESULT values written as the unsigned constants of the SDK.
inline fn hresult(comptime v: u32) HRESULT {
    return @bitCast(v);
}

const S_OK: HRESULT = 0;
const E_OUTOFMEMORY: HRESULT = hresult(0x8007000E);
const E_INVALIDARG: HRESULT = hresult(0x80070057);
const E_NOINTERFACE: HRESULT = hresult(0x80004002);
const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = hresult(0x80040201);

const CP_UTF8: UINT = 65001;
const COINIT_APARTMENTTHREADED: DWORD = 0x2;
const LOCALE_NAME_MAX_LENGTH = 85;
const WM_APP = 0x8000;
const SPI_GETHIGHCONTRAST: UINT = 0x0042;
const SPI_GETSCREENREADER: UINT = 0x0046;
const SPI_GETCLIENTAREAANIMATION: UINT = 0x1042;
const HCF_HIGHCONTRASTON: DWORD = 0x00000001;
const RRF_RT_REG_DWORD: DWORD = 0x00000010;
const ERROR_SUCCESS: LSTATUS = 0;
/// ((HKEY)(ULONG_PTR)((LONG)0x80000001))
const HKEY_CURRENT_USER: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000001)))))));

const VT_EMPTY: VARTYPE = 0;
const VT_I4: VARTYPE = 3;
const VT_R8: VARTYPE = 5;
const VT_BSTR: VARTYPE = 8;
const VT_BOOL: VARTYPE = 11;

const RVN_WM_UIA: UINT = WM_APP + 0x5A1;

// UI Automation constants (uiautomationcore.h). Untyped, so that they can label switch cases.
const ProviderOptions_ClientSideProvider = 0x1;
const ProviderOptions_ServerSideProvider = 0x2;
const ProviderOptions_UseComThreading = 0x20;

const UiaRootObjectId = -25;
const UiaAppendRuntimeId = 3;

const UIA_ButtonControlTypeId = 50000;
const UIA_CheckBoxControlTypeId = 50002;
const UIA_ComboBoxControlTypeId = 50003;
const UIA_EditControlTypeId = 50004;
const UIA_HyperlinkControlTypeId = 50005;
const UIA_ImageControlTypeId = 50006;
const UIA_ListItemControlTypeId = 50007;
const UIA_ListControlTypeId = 50008;
const UIA_MenuControlTypeId = 50009;
const UIA_MenuBarControlTypeId = 50010;
const UIA_MenuItemControlTypeId = 50011;
const UIA_ProgressBarControlTypeId = 50012;
const UIA_RadioButtonControlTypeId = 50013;
const UIA_ScrollBarControlTypeId = 50014;
const UIA_SliderControlTypeId = 50015;
const UIA_SpinnerControlTypeId = 50016;
const UIA_StatusBarControlTypeId = 50017;
const UIA_TabControlTypeId = 50018;
const UIA_TabItemControlTypeId = 50019;
const UIA_TextControlTypeId = 50020;
const UIA_ToolBarControlTypeId = 50021;
const UIA_TreeControlTypeId = 50023;
const UIA_TreeItemControlTypeId = 50024;
const UIA_CustomControlTypeId = 50025;
const UIA_GroupControlTypeId = 50026;
const UIA_DocumentControlTypeId = 50030;
const UIA_WindowControlTypeId = 50032;
const UIA_PaneControlTypeId = 50033;
const UIA_TableControlTypeId = 50036;
const UIA_SeparatorControlTypeId = 50038;

const UIA_InvokePatternId = 10000;
const UIA_ValuePatternId = 10002;
const UIA_RangeValuePatternId = 10003;
const UIA_ExpandCollapsePatternId = 10005;
const UIA_TogglePatternId = 10015;
const UIA_SelectionItemPatternId = 10010;

const UIA_NamePropertyId = 30005;
const UIA_ValueValuePropertyId = 30045;
const UIA_RangeValueValuePropertyId = 30047;
const UIA_ToggleToggleStatePropertyId = 30086;
const UIA_ExpandCollapseExpandCollapseStatePropertyId = 30070;
const UIA_AutomationFocusChangedEventId = 20005;

const NavigateDirection_Parent = 0x0;
const NavigateDirection_NextSibling = 0x1;
const NavigateDirection_PreviousSibling = 0x2;
const NavigateDirection_FirstChild = 0x3;
const NavigateDirection_LastChild = 0x4;

const ToggleState_Off = 0x0;
const ToggleState_On = 0x1;

const ExpandCollapseState_Collapsed = 0x0;
const ExpandCollapseState_Expanded = 0x1;
const ExpandCollapseState_LeafNode = 0x3;

const StructureChangeType_ChildrenInvalidated = 0x2;

const NotificationKind_Other = 0x4;
const NotificationProcessing_ImportantMostRecent = 0x1;
const NotificationProcessing_MostRecent = 0x3;

/// The property ids of UI Automation (UIAutomationClient.h): MSVC declares them as
/// const variables in C, which a case label cannot use
const RVN_UIA_ControlType = 30003;
const RVN_UIA_LocalizedControlType = 30004;
const RVN_UIA_Name = 30005;
const RVN_UIA_HasKeyboardFocus = 30008;
const RVN_UIA_IsKeyboardFocusable = 30009;
const RVN_UIA_IsEnabled = 30010;
const RVN_UIA_AutomationId = 30011;
const RVN_UIA_ClassName = 30012;
const RVN_UIA_HelpText = 30013;
const RVN_UIA_Culture = 30015;
const RVN_UIA_IsControlElement = 30016;
const RVN_UIA_IsContentElement = 30017;
const RVN_UIA_IsPassword = 30019;
const RVN_UIA_IsOffscreen = 30022;
const RVN_UIA_FrameworkId = 30024;
const RVN_UIA_ProviderDescription = 30107;
const RVN_UIA_IsDialog = 30174;

// ---------------------------------------------------------------------------
//  Interfaces: an interface pointer is a pointer to a struct whose first field
//  is the pointer to its vtable (COBJMACROS style, as the C file uses them).
// ---------------------------------------------------------------------------
const IRawElementProviderSimple = extern struct {
    lpVtbl: *const IRawElementProviderSimpleVtbl,
};
const IRawElementProviderSimpleVtbl = extern struct {
    QueryInterface: *const fn (*IRawElementProviderSimple, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IRawElementProviderSimple) callconv(.winapi) ULONG,
    Release: *const fn (*IRawElementProviderSimple) callconv(.winapi) ULONG,
    get_ProviderOptions: *const fn (*IRawElementProviderSimple, *c_int) callconv(.winapi) HRESULT,
    GetPatternProvider: *const fn (*IRawElementProviderSimple, PATTERNID, *?*IUnknown) callconv(.winapi) HRESULT,
    GetPropertyValue: *const fn (*IRawElementProviderSimple, PROPERTYID, *VARIANT) callconv(.winapi) HRESULT,
    get_HostRawElementProvider: *const fn (*IRawElementProviderSimple, *?*IRawElementProviderSimple) callconv(.winapi) HRESULT,
};

const IRawElementProviderFragment = extern struct {
    lpVtbl: *const IRawElementProviderFragmentVtbl,
};
const IRawElementProviderFragmentVtbl = extern struct {
    QueryInterface: *const fn (*IRawElementProviderFragment, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IRawElementProviderFragment) callconv(.winapi) ULONG,
    Release: *const fn (*IRawElementProviderFragment) callconv(.winapi) ULONG,
    Navigate: *const fn (*IRawElementProviderFragment, c_int, *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
    GetRuntimeId: *const fn (*IRawElementProviderFragment, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    get_BoundingRectangle: *const fn (*IRawElementProviderFragment, *UiaRect) callconv(.winapi) HRESULT,
    GetEmbeddedFragmentRoots: *const fn (*IRawElementProviderFragment, *?*SAFEARRAY) callconv(.winapi) HRESULT,
    SetFocus: *const fn (*IRawElementProviderFragment) callconv(.winapi) HRESULT,
    get_FragmentRoot: *const fn (*IRawElementProviderFragment, *?*IRawElementProviderFragmentRoot) callconv(.winapi) HRESULT,
};

const IRawElementProviderFragmentRoot = extern struct {
    lpVtbl: *const IRawElementProviderFragmentRootVtbl,
};
const IRawElementProviderFragmentRootVtbl = extern struct {
    QueryInterface: *const fn (*IRawElementProviderFragmentRoot, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IRawElementProviderFragmentRoot) callconv(.winapi) ULONG,
    Release: *const fn (*IRawElementProviderFragmentRoot) callconv(.winapi) ULONG,
    ElementProviderFromPoint: *const fn (*IRawElementProviderFragmentRoot, f64, f64, *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
    GetFocus: *const fn (*IRawElementProviderFragmentRoot, *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
};

const IInvokeProvider = extern struct {
    lpVtbl: *const IInvokeProviderVtbl,
};
const IInvokeProviderVtbl = extern struct {
    QueryInterface: *const fn (*IInvokeProvider, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IInvokeProvider) callconv(.winapi) ULONG,
    Release: *const fn (*IInvokeProvider) callconv(.winapi) ULONG,
    Invoke: *const fn (*IInvokeProvider) callconv(.winapi) HRESULT,
};

const IToggleProvider = extern struct {
    lpVtbl: *const IToggleProviderVtbl,
};
const IToggleProviderVtbl = extern struct {
    QueryInterface: *const fn (*IToggleProvider, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IToggleProvider) callconv(.winapi) ULONG,
    Release: *const fn (*IToggleProvider) callconv(.winapi) ULONG,
    Toggle: *const fn (*IToggleProvider) callconv(.winapi) HRESULT,
    get_ToggleState: *const fn (*IToggleProvider, *c_int) callconv(.winapi) HRESULT,
};

const IValueProvider = extern struct {
    lpVtbl: *const IValueProviderVtbl,
};
const IValueProviderVtbl = extern struct {
    QueryInterface: *const fn (*IValueProvider, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IValueProvider) callconv(.winapi) ULONG,
    Release: *const fn (*IValueProvider) callconv(.winapi) ULONG,
    SetValue: *const fn (*IValueProvider, LPCWSTR) callconv(.winapi) HRESULT,
    get_Value: *const fn (*IValueProvider, *BSTR) callconv(.winapi) HRESULT,
    get_IsReadOnly: *const fn (*IValueProvider, *BOOL) callconv(.winapi) HRESULT,
};

const IRangeValueProvider = extern struct {
    lpVtbl: *const IRangeValueProviderVtbl,
};
const IRangeValueProviderVtbl = extern struct {
    QueryInterface: *const fn (*IRangeValueProvider, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IRangeValueProvider) callconv(.winapi) ULONG,
    Release: *const fn (*IRangeValueProvider) callconv(.winapi) ULONG,
    SetValue: *const fn (*IRangeValueProvider, f64) callconv(.winapi) HRESULT,
    get_Value: *const fn (*IRangeValueProvider, *f64) callconv(.winapi) HRESULT,
    get_IsReadOnly: *const fn (*IRangeValueProvider, *BOOL) callconv(.winapi) HRESULT,
    get_Maximum: *const fn (*IRangeValueProvider, *f64) callconv(.winapi) HRESULT,
    get_Minimum: *const fn (*IRangeValueProvider, *f64) callconv(.winapi) HRESULT,
    get_LargeChange: *const fn (*IRangeValueProvider, *f64) callconv(.winapi) HRESULT,
    get_SmallChange: *const fn (*IRangeValueProvider, *f64) callconv(.winapi) HRESULT,
};

const IExpandCollapseProvider = extern struct {
    lpVtbl: *const IExpandCollapseProviderVtbl,
};
const IExpandCollapseProviderVtbl = extern struct {
    QueryInterface: *const fn (*IExpandCollapseProvider, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IExpandCollapseProvider) callconv(.winapi) ULONG,
    Release: *const fn (*IExpandCollapseProvider) callconv(.winapi) ULONG,
    Expand: *const fn (*IExpandCollapseProvider) callconv(.winapi) HRESULT,
    Collapse: *const fn (*IExpandCollapseProvider) callconv(.winapi) HRESULT,
    get_ExpandCollapseState: *const fn (*IExpandCollapseProvider, *c_int) callconv(.winapi) HRESULT,
};

const ISelectionItemProvider = extern struct {
    lpVtbl: *const ISelectionItemProviderVtbl,
};
const ISelectionItemProviderVtbl = extern struct {
    QueryInterface: *const fn (*ISelectionItemProvider, REFIID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*ISelectionItemProvider) callconv(.winapi) ULONG,
    Release: *const fn (*ISelectionItemProvider) callconv(.winapi) ULONG,
    Select: *const fn (*ISelectionItemProvider) callconv(.winapi) HRESULT,
    AddToSelection: *const fn (*ISelectionItemProvider) callconv(.winapi) HRESULT,
    RemoveFromSelection: *const fn (*ISelectionItemProvider) callconv(.winapi) HRESULT,
    get_IsSelected: *const fn (*ISelectionItemProvider, *BOOL) callconv(.winapi) HRESULT,
    get_SelectionContainer: *const fn (*ISelectionItemProvider, *?*IRawElementProviderSimple) callconv(.winapi) HRESULT,
};

// Interface identifiers (uiautomationcore.h, oleauto / unknwn)
const IID_IUnknown = GUID{ .Data1 = 0x00000000, .Data2 = 0x0000, .Data3 = 0x0000, .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };
const IID_IRawElementProviderSimple = GUID{ .Data1 = 0xd6dd68d1, .Data2 = 0x86fd, .Data3 = 0x4332, .Data4 = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c } };
const IID_IRawElementProviderFragment = GUID{ .Data1 = 0xf7063da8, .Data2 = 0x8359, .Data3 = 0x439c, .Data4 = .{ 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87 } };
const IID_IRawElementProviderFragmentRoot = GUID{ .Data1 = 0x620ce2a5, .Data2 = 0xab8f, .Data3 = 0x40a9, .Data4 = .{ 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58 } };
const IID_IInvokeProvider = GUID{ .Data1 = 0x54fcb24b, .Data2 = 0xe18e, .Data3 = 0x47a2, .Data4 = .{ 0xb4, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2 } };
const IID_IToggleProvider = GUID{ .Data1 = 0x56d00bd0, .Data2 = 0xc4f4, .Data3 = 0x433c, .Data4 = .{ 0xa8, 0x36, 0x1a, 0x52, 0xa5, 0x7e, 0x08, 0x92 } };
const IID_IValueProvider = GUID{ .Data1 = 0xc7935180, .Data2 = 0x6fb3, .Data3 = 0x4201, .Data4 = .{ 0xb1, 0x74, 0x7d, 0xf7, 0x3a, 0xdb, 0xf6, 0x4a } };
const IID_IRangeValueProvider = GUID{ .Data1 = 0x36dc7aef, .Data2 = 0x33e6, .Data3 = 0x4691, .Data4 = .{ 0xaf, 0xe1, 0x2b, 0xe7, 0x27, 0x4b, 0x3d, 0x33 } };
const IID_IExpandCollapseProvider = GUID{ .Data1 = 0xd847d3a5, .Data2 = 0xcab0, .Data3 = 0x4a98, .Data4 = .{ 0x8c, 0x32, 0xec, 0xb4, 0x5c, 0x59, 0xad, 0x24 } };
const IID_ISelectionItemProvider = GUID{ .Data1 = 0x2acad808, .Data2 = 0xb2d4, .Data3 = 0x452d, .Data4 = .{ 0xa4, 0x07, 0x91, 0xff, 0x1a, 0xd1, 0x67, 0xb2 } };

fn isEqualIID(a: REFIID, b: *const GUID) bool {
    return std.meta.eql(a.*, b.*);
}

// ---------------------------------------------------------------------------
//  Win32 functions loaded at run time (and the few linked directly)
// ---------------------------------------------------------------------------
extern "kernel32" fn LoadLibraryW(name: LPCWSTR) callconv(.winapi) HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn MultiByteToWideChar(code_page: UINT, flags: DWORD, src: [*c]const u8, src_len: c_int, dst: [*c]u16, dst_len: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(code_page: UINT, flags: DWORD, src: LPCWSTR, src_len: c_int, dst: [*c]u8, dst_len: c_int, default_char: [*c]const u8, used_default: ?*BOOL) callconv(.winapi) c_int;
extern "kernel32" fn LocaleNameToLCID(name: LPCWSTR, flags: DWORD) callconv(.winapi) LCID;
extern "user32" fn SendMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SystemParametersInfoW(action: UINT, param: UINT, pv: ?*anyopaque, win_ini: UINT) callconv(.winapi) BOOL;

const UiaHostProviderFromHwndFn = *const fn (HWND, *?*IRawElementProviderSimple) callconv(.winapi) HRESULT;
const UiaReturnRawElementProviderFn = *const fn (HWND, WPARAM, LPARAM, ?*IRawElementProviderSimple) callconv(.winapi) LRESULT;
const UiaRaiseAutomationEventFn = *const fn (*IRawElementProviderSimple, EVENTID) callconv(.winapi) HRESULT;
const UiaRaisePropertyChangedFn = *const fn (*IRawElementProviderSimple, PROPERTYID, VARIANT, VARIANT) callconv(.winapi) HRESULT;
const UiaRaiseStructureChangedFn = *const fn (*IRawElementProviderSimple, c_int, ?*c_int, c_int) callconv(.winapi) HRESULT;
const UiaRaiseNotificationFn = *const fn (*IRawElementProviderSimple, c_int, c_int, BSTR, BSTR) callconv(.winapi) HRESULT;
const UiaClientsAreListeningFn = *const fn () callconv(.winapi) BOOL;
const UiaDisconnectProviderFn = *const fn (*IRawElementProviderSimple) callconv(.winapi) HRESULT;
const SysAllocStringFn = *const fn ([*c]const u16) callconv(.winapi) BSTR;
const SysFreeStringFn = *const fn (BSTR) callconv(.winapi) void;
const SafeArrayCreateVectorFn = *const fn (VARTYPE, LONG, ULONG) callconv(.winapi) ?*SAFEARRAY;
const SafeArrayPutElementFn = *const fn (?*SAFEARRAY, *LONG, ?*anyopaque) callconv(.winapi) HRESULT;
const CoInitializeExFn = *const fn (?*anyopaque, DWORD) callconv(.winapi) HRESULT;
const RegGetValueWFn = *const fn (HKEY, LPCWSTR, LPCWSTR, DWORD, ?*DWORD, ?*anyopaque, ?*DWORD) callconv(.winapi) LSTATUS;

const RVN_WM_UIA_WPARAM = 0;

const HIGHCONTRAST_SIZE: UINT = @sizeOf(HIGHCONTRASTW);

/// The functions of UI Automation and OLE, loaded when first needed.
const UiaState = struct {
    loaded: c_int,
    failed: c_int,
    host: ?UiaHostProviderFromHwndFn,
    return_provider: ?UiaReturnRawElementProviderFn,
    raise_event: ?UiaRaiseAutomationEventFn,
    raise_property: ?UiaRaisePropertyChangedFn,
    raise_structure: ?UiaRaiseStructureChangedFn,
    raise_notification: ?UiaRaiseNotificationFn,
    listening: ?UiaClientsAreListeningFn,
    disconnect: ?UiaDisconnectProviderFn,
    sys_alloc: ?SysAllocStringFn,
    sys_free: ?SysFreeStringFn,
    sa_create: ?SafeArrayCreateVectorFn,
    sa_put: ?SafeArrayPutElementFn,
    ui_thread: DWORD,
    /// providers made so far, by node
    table: [*c]*rvn_uia_t,
    count: c_int,
    capacity: c_int,
};

var g_uia: UiaState = std.mem.zeroes(UiaState);

fn rvn_uia_load() c_int {
    if (g_uia.loaded != 0) return raven.R_TRUE;
    if (g_uia.failed != 0) return raven.R_FALSE;
    const core = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("UIAutomationCore.dll"));
    const oleaut = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("OleAut32.dll"));
    const ole = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("Ole32.dll"));
    if (core == null or oleaut == null) {
        g_uia.failed = raven.R_TRUE;
        return raven.R_FALSE;
    }
    g_uia.host = @ptrCast(GetProcAddress(core, "UiaHostProviderFromHwnd"));
    g_uia.return_provider = @ptrCast(GetProcAddress(core, "UiaReturnRawElementProvider"));
    g_uia.raise_event = @ptrCast(GetProcAddress(core, "UiaRaiseAutomationEvent"));
    g_uia.raise_property = @ptrCast(GetProcAddress(core, "UiaRaiseAutomationPropertyChangedEvent"));
    g_uia.raise_structure = @ptrCast(GetProcAddress(core, "UiaRaiseStructureChangedEvent"));
    // (Windows 10 1709 and later)
    g_uia.raise_notification = @ptrCast(GetProcAddress(core, "UiaRaiseNotificationEvent"));
    g_uia.listening = @ptrCast(GetProcAddress(core, "UiaClientsAreListening"));
    g_uia.disconnect = @ptrCast(GetProcAddress(core, "UiaDisconnectProvider"));
    g_uia.sys_alloc = @ptrCast(GetProcAddress(oleaut, "SysAllocString"));
    g_uia.sys_free = @ptrCast(GetProcAddress(oleaut, "SysFreeString"));
    g_uia.sa_create = @ptrCast(GetProcAddress(oleaut, "SafeArrayCreateVector"));
    g_uia.sa_put = @ptrCast(GetProcAddress(oleaut, "SafeArrayPutElement"));
    if (g_uia.host == null or g_uia.return_provider == null or g_uia.raise_event == null or g_uia.sys_alloc == null or g_uia.sa_create == null or g_uia.sa_put == null) {
        g_uia.failed = raven.R_TRUE;
        return raven.R_FALSE;
    }
    // the UI thread is a single-threaded apartment: UI Automation calls the providers there
    if (ole != null) {
        const init: ?CoInitializeExFn = @ptrCast(GetProcAddress(ole, "CoInitializeEx"));
        if (init) |f| _ = f(null, COINIT_APARTMENTTHREADED);
    }
    g_uia.ui_thread = GetCurrentThreadId();
    g_uia.loaded = raven.R_TRUE;
    return raven.R_TRUE;
}

// ---------------------------------------------------------------------------
//  The provider object
// ---------------------------------------------------------------------------

const rvn_uia_t = extern struct {
    simple: IRawElementProviderSimple,
    fragment: IRawElementProviderFragment,
    root: IRawElementProviderFragmentRoot,
    invoke: IInvokeProvider,
    toggle: IToggleProvider,
    value: IValueProvider,
    range: IRangeValueProvider,
    expand: IExpandCollapseProvider,
    selection: ISelectionItemProvider,
    refs: LONG,
    id: a11y.rvn_a11y_id_t,
    hwnd: HWND,
    disconnected: c_int,
};

/// FROM(pointer, member) of the C file: the provider that holds the interface
fn providerOf(comptime member: []const u8, p: anytype) *rvn_uia_t {
    return @ptrFromInt(@intFromPtr(p) - @offsetOf(rvn_uia_t, member));
}

fn rvn_uia_alive(self: *rvn_uia_t) bool {
    return self.disconnected == 0 and a11y.rvn_a11y_exists(self.id) != 0;
}

// ---- calls from other threads: done on the UI thread ----

const Call = struct {
    @"fn": *const fn (*Call) HRESULT,
    self: *rvn_uia_t,
    a: isize,
    b: isize,
    d: f64,
    text: LPCWSTR,
    out: ?*anyopaque,
    result: HRESULT,
};

fn rvn_uia_call(call: *Call) HRESULT {
    if (GetCurrentThreadId() == g_uia.ui_thread) return call.@"fn"(call);
    call.result = UIA_E_ELEMENTNOTAVAILABLE;
    if (call.self.hwnd) |hwnd| {
        _ = SendMessageW(hwnd, RVN_WM_UIA, RVN_WM_UIA_WPARAM, @bitCast(@intFromPtr(call)));
    }
    return call.result;
}

fn rvn_uia_handle_message(message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.c) c_int {
    _ = wparam;
    if (message != RVN_WM_UIA) return raven.R_FALSE;
    const call: *Call = @ptrFromInt(@as(usize, @bitCast(lparam)));
    call.result = call.@"fn"(call);
    return raven.R_TRUE;
}

/// The fields a CALL(...) macro of the C file sets before calling rvn_uia_call
const CallFields = struct {
    a: isize = 0,
    b: isize = 0,
    d: f64 = 0,
    text: LPCWSTR = null,
    out: ?*anyopaque = null,
};

/// CALL(name, iface, member, ...) of the C file: fills a call and runs it on the UI thread
fn callOn(comptime member: []const u8, handler: *const fn (*Call) HRESULT, iface: anytype, fields: CallFields) HRESULT {
    var call: Call = .{
        .@"fn" = handler,
        .self = providerOf(member, iface),
        .a = fields.a,
        .b = fields.b,
        .d = fields.d,
        .text = fields.text,
        .out = fields.out,
        .result = S_OK,
    };
    return rvn_uia_call(&call);
}

/// A pointer to an output slot of any type, as the `void* out` of the C file
fn anyOut(p: anytype) ?*anyopaque {
    return @ptrCast(@alignCast(p));
}

// ---- strings ----

fn rvn_uia_bstr(utf8_in: [*c]const u8) BSTR {
    var utf8: [*c]const u8 = utf8_in;
    if (utf8 == null) utf8 = "";
    const n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, null, 0);
    const wide: [*c]u16 = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(if (n > 0) n else 1)) * @sizeOf(u16))));
    wide[0] = 0;
    if (n > 0) _ = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, n);
    const result = g_uia.sys_alloc.?(wide);
    base.rvn_free(wide);
    return result;
}

fn rvn_uia_utf8(wide_in: LPCWSTR) [*c]u8 {
    const empty = std.unicode.utf8ToUtf16LeStringLiteral("");
    var wide: LPCWSTR = empty;
    if (wide_in != null) wide = wide_in;
    const n = WideCharToMultiByte(CP_UTF8, 0, wide, -1, null, 0, null, null);
    const out: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(@as(usize, @intCast(if (n > 0) n else 1)))));
    out[0] = 0;
    if (n > 0) _ = WideCharToMultiByte(CP_UTF8, 0, wide, -1, out, n, null, null);
    return out;
}

// ---- IUnknown, shared by every interface of the object ----

fn rvn_uia_addref(self: *rvn_uia_t) ULONG {
    return @bitCast(@atomicRmw(LONG, &self.refs, .Add, 1, .seq_cst) +% 1);
}

fn rvn_uia_release(self: *rvn_uia_t) ULONG {
    const refs = @atomicRmw(LONG, &self.refs, .Sub, 1, .seq_cst) -% 1;
    if (refs == 0) base.rvn_free(self);
    return @bitCast(refs);
}

fn rvn_uia_query(self: *rvn_uia_t, riid: REFIID, out: *?*anyopaque) HRESULT {
    out.* = null;
    if (isEqualIID(riid, &IID_IUnknown) or isEqualIID(riid, &IID_IRawElementProviderSimple)) {
        out.* = &self.simple;
    } else if (isEqualIID(riid, &IID_IRawElementProviderFragment)) {
        out.* = &self.fragment;
    } else if (isEqualIID(riid, &IID_IRawElementProviderFragmentRoot) and (self.id >> 32) == 0 and a11y.rvn_a11y_parent(self.id) == 0) {
        out.* = &self.root;
    } else if (isEqualIID(riid, &IID_IInvokeProvider)) {
        out.* = &self.invoke;
    } else if (isEqualIID(riid, &IID_IToggleProvider)) {
        out.* = &self.toggle;
    } else if (isEqualIID(riid, &IID_IValueProvider)) {
        out.* = &self.value;
    } else if (isEqualIID(riid, &IID_IRangeValueProvider)) {
        out.* = &self.range;
    } else if (isEqualIID(riid, &IID_IExpandCollapseProvider)) {
        out.* = &self.expand;
    } else if (isEqualIID(riid, &IID_ISelectionItemProvider)) {
        out.* = &self.selection;
    } else {
        return E_NOINTERFACE;
    }
    _ = rvn_uia_addref(self);
    return S_OK;
}

/// The IUnknown methods of one interface (UNKNOWN macro of the C file)
fn Unknown(comptime I: type, comptime member: []const u8) type {
    return struct {
        fn query(this: *I, riid: REFIID, out: *?*anyopaque) callconv(.winapi) HRESULT {
            return rvn_uia_query(providerOf(member, this), riid, out);
        }
        fn addref(this: *I) callconv(.winapi) ULONG {
            return rvn_uia_addref(providerOf(member, this));
        }
        fn release(this: *I) callconv(.winapi) ULONG {
            return rvn_uia_release(providerOf(member, this));
        }
    };
}

const U_simple = Unknown(IRawElementProviderSimple, "simple");
const U_fragment = Unknown(IRawElementProviderFragment, "fragment");
const U_root = Unknown(IRawElementProviderFragmentRoot, "root");
const U_invoke = Unknown(IInvokeProvider, "invoke");
const U_toggle = Unknown(IToggleProvider, "toggle");
const U_value = Unknown(IValueProvider, "value");
const U_range = Unknown(IRangeValueProvider, "range");
const U_expand = Unknown(IExpandCollapseProvider, "expand");
const U_selection = Unknown(ISelectionItemProvider, "selection");

// ---------------------------------------------------------------------------
//  IRawElementProviderSimple
// ---------------------------------------------------------------------------

fn rvn_uia_control_type(node: *const a11y.rvn_a11y_node_t) LONG {
    return switch (node.role) {
        raven.R_ROLE_WINDOW => UIA_WindowControlTypeId,
        raven.R_ROLE_GROUP => UIA_GroupControlTypeId,
        raven.R_ROLE_TEXT, raven.R_ROLE_HEADING => UIA_TextControlTypeId,
        raven.R_ROLE_LINK => UIA_HyperlinkControlTypeId,
        raven.R_ROLE_BUTTON, raven.R_ROLE_TOGGLE_BUTTON => UIA_ButtonControlTypeId,
        raven.R_ROLE_CHECKBOX => UIA_CheckBoxControlTypeId,
        raven.R_ROLE_RADIO_BUTTON => UIA_RadioButtonControlTypeId,
        raven.R_ROLE_SLIDER => UIA_SliderControlTypeId,
        raven.R_ROLE_PROGRESS_BAR => UIA_ProgressBarControlTypeId,
        raven.R_ROLE_SPIN_BUTTON => UIA_SpinnerControlTypeId,
        raven.R_ROLE_TEXT_FIELD => UIA_EditControlTypeId,
        raven.R_ROLE_DOCUMENT => UIA_DocumentControlTypeId,
        raven.R_ROLE_COMBO_BOX => UIA_ComboBoxControlTypeId,
        raven.R_ROLE_LIST => UIA_ListControlTypeId,
        raven.R_ROLE_LIST_ITEM => UIA_ListItemControlTypeId,
        raven.R_ROLE_TREE => UIA_TreeControlTypeId,
        raven.R_ROLE_TREE_ITEM => UIA_TreeItemControlTypeId,
        raven.R_ROLE_TABLE => UIA_TableControlTypeId,
        raven.R_ROLE_MENU_BAR => UIA_MenuBarControlTypeId,
        raven.R_ROLE_MENU => UIA_MenuControlTypeId,
        raven.R_ROLE_MENU_ITEM => UIA_MenuItemControlTypeId,
        raven.R_ROLE_TAB_LIST => UIA_TabControlTypeId,
        raven.R_ROLE_TAB => UIA_TabItemControlTypeId,
        raven.R_ROLE_TAB_PANEL => UIA_PaneControlTypeId,
        raven.R_ROLE_TOOLBAR => UIA_ToolBarControlTypeId,
        raven.R_ROLE_STATUS_BAR => UIA_StatusBarControlTypeId,
        raven.R_ROLE_DIALOG => UIA_WindowControlTypeId,
        raven.R_ROLE_ALERT => UIA_TextControlTypeId,
        raven.R_ROLE_IMAGE => UIA_ImageControlTypeId,
        raven.R_ROLE_SEPARATOR => UIA_SeparatorControlTypeId,
        raven.R_ROLE_SCROLL_BAR => UIA_ScrollBarControlTypeId,
        raven.R_ROLE_CANVAS, raven.R_ROLE_PANE => UIA_PaneControlTypeId,
        else => UIA_CustomControlTypeId,
    };
}

fn simple_options(This: *IRawElementProviderSimple, out: *c_int) callconv(.winapi) HRESULT {
    _ = This;
    out.* = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
    return S_OK;
}

fn do_pattern(c: *Call) HRESULT {
    var node: a11y.rvn_a11y_node_t = undefined;
    const out: *?*IUnknown = @ptrCast(@alignCast(c.out));
    const pattern: PATTERNID = @intCast(c.a);
    var found: ?*anyopaque = null;
    out.* = null;
    if (!rvn_uia_alive(c.self) or a11y.rvn_a11y_describe(c.self.id, &node) == 0) return UIA_E_ELEMENTNOTAVAILABLE;
    if (pattern == UIA_InvokePatternId and (node.states & a11y.RVN_A11Y_INVOKABLE) != 0 and (node.states & a11y.RVN_A11Y_CHECKABLE) == 0 and
        node.role != raven.R_ROLE_COMBO_BOX and node.role != raven.R_ROLE_LIST_ITEM and node.role != raven.R_ROLE_TAB)
    {
        found = &c.self.invoke;
    } else if (pattern == UIA_TogglePatternId and (node.states & a11y.RVN_A11Y_CHECKABLE) != 0) {
        found = &c.self.toggle;
    } else if (pattern == UIA_ValuePatternId and ((node.states & a11y.RVN_A11Y_EDITABLE) != 0 or node.role == raven.R_ROLE_COMBO_BOX)) {
        found = &c.self.value;
    } else if (pattern == UIA_RangeValuePatternId and (node.states & a11y.RVN_A11Y_HAS_RANGE) != 0) {
        found = &c.self.range;
    } else if (pattern == UIA_ExpandCollapsePatternId and (node.states & a11y.RVN_A11Y_EXPANDABLE) != 0) {
        found = &c.self.expand;
    } else if (pattern == UIA_SelectionItemPatternId and (node.states & a11y.RVN_A11Y_SELECTABLE) != 0) {
        found = &c.self.selection;
    }
    if (found) |f| {
        _ = rvn_uia_addref(c.self);
        out.* = @ptrCast(@alignCast(f));
    }
    return S_OK;
}

fn simple_pattern(This: *IRawElementProviderSimple, pattern: PATTERNID, out: *?*IUnknown) callconv(.winapi) HRESULT {
    return callOn("simple", do_pattern, This, .{ .a = pattern, .out = anyOut(out) });
}

fn do_property(c: *Call) HRESULT {
    var node: a11y.rvn_a11y_node_t = undefined;
    const out: *VARIANT = @ptrCast(@alignCast(c.out));
    const property: PROPERTYID = @intCast(c.a);
    out.* = std.mem.zeroes(VARIANT);
    out.vt = VT_EMPTY;
    if (!rvn_uia_alive(c.self) or a11y.rvn_a11y_describe(c.self.id, &node) == 0) return UIA_E_ELEMENTNOTAVAILABLE;
    switch (property) {
        RVN_UIA_ControlType => {
            out.vt = VT_I4;
            out.u.lVal = rvn_uia_control_type(&node);
        },
        RVN_UIA_Name => {
            out.vt = VT_BSTR;
            out.u.bstrVal = rvn_uia_bstr(node.name);
        },
        RVN_UIA_HelpText => {
            if (node.description[0] != 0) {
                out.vt = VT_BSTR;
                out.u.bstrVal = rvn_uia_bstr(node.description);
            }
        },
        RVN_UIA_LocalizedControlType => {
            if (node.role == raven.R_ROLE_CANVAS or node.role == raven.R_ROLE_TAB_PANEL) {
                out.vt = VT_BSTR;
                out.u.bstrVal = rvn_uia_bstr(a11y.rvn_a11y_role_name(node.role));
            }
        },
        RVN_UIA_AutomationId => {
            var text: [32]u8 = undefined;
            _ = libc.snprintf(&text, text.len, "raven-%llx", @as(c_ulonglong, node.id));
            out.vt = VT_BSTR;
            out.u.bstrVal = rvn_uia_bstr(&text);
        },
        RVN_UIA_ClassName => {
            out.vt = VT_BSTR;
            out.u.bstrVal = rvn_uia_bstr("Raven");
        },
        RVN_UIA_FrameworkId => {
            out.vt = VT_BSTR;
            out.u.bstrVal = rvn_uia_bstr("Raven");
        },
        RVN_UIA_IsKeyboardFocusable => {
            out.vt = VT_BOOL;
            out.u.boolVal = if ((node.states & a11y.RVN_A11Y_FOCUSABLE) != 0) VARIANT_TRUE else VARIANT_FALSE;
        },
        RVN_UIA_HasKeyboardFocus => {
            out.vt = VT_BOOL;
            out.u.boolVal = if ((node.states & a11y.RVN_A11Y_FOCUSED) != 0) VARIANT_TRUE else VARIANT_FALSE;
        },
        RVN_UIA_IsEnabled => {
            out.vt = VT_BOOL;
            out.u.boolVal = if ((node.states & a11y.RVN_A11Y_DISABLED) != 0) VARIANT_FALSE else VARIANT_TRUE;
        },
        RVN_UIA_IsControlElement, RVN_UIA_IsContentElement => {
            out.vt = VT_BOOL;
            out.u.boolVal = VARIANT_TRUE;
        },
        RVN_UIA_IsPassword => {
            out.vt = VT_BOOL;
            out.u.boolVal = if ((node.states & a11y.RVN_A11Y_PASSWORD) != 0) VARIANT_TRUE else VARIANT_FALSE;
        },
        RVN_UIA_IsOffscreen => {
            out.vt = VT_BOOL;
            out.u.boolVal = VARIANT_FALSE;
        },
        RVN_UIA_IsDialog => {
            out.vt = VT_BOOL;
            out.u.boolVal = if ((node.states & a11y.RVN_A11Y_MODAL) != 0) VARIANT_TRUE else VARIANT_FALSE;
        },
        RVN_UIA_ProviderDescription => {
            out.vt = VT_BSTR;
            out.u.bstrVal = rvn_uia_bstr("Raven UI Automation provider");
        },
        RVN_UIA_Culture => {
            // the language of the application
            var wide: [LOCALE_NAME_MAX_LENGTH]u16 = undefined;
            if (MultiByteToWideChar(CP_UTF8, 0, a11y.rvn_a11y_locale(), -1, &wide, LOCALE_NAME_MAX_LENGTH) > 0) {
                out.vt = VT_I4;
                out.u.lVal = @bitCast(LocaleNameToLCID(&wide, 0));
            }
        },
        else => {},
    }
    return S_OK;
}

fn simple_property(This: *IRawElementProviderSimple, property: PROPERTYID, out: *VARIANT) callconv(.winapi) HRESULT {
    return callOn("simple", do_property, This, .{ .a = property, .out = anyOut(out) });
}

fn simple_host(This: *IRawElementProviderSimple, out: *?*IRawElementProviderSimple) callconv(.winapi) HRESULT {
    const self = providerOf("simple", This);
    out.* = null;
    // the window: UI Automation adds what it knows of the HWND (title bar, process...)
    if ((self.id >> 32) == 0 and a11y.rvn_a11y_parent(self.id) == 0) {
        if (self.hwnd) |hwnd| return g_uia.host.?(hwnd, out);
    }
    return S_OK;
}

// ---------------------------------------------------------------------------
//  IRawElementProviderFragment
// ---------------------------------------------------------------------------

fn do_navigate(c: *Call) HRESULT {
    const out: *?*IRawElementProviderFragment = @ptrCast(@alignCast(c.out));
    const id = c.self.id;
    var target: a11y.rvn_a11y_id_t = 0;
    var parent: a11y.rvn_a11y_id_t = undefined;
    var index: c_int = undefined;
    var count: c_int = undefined;
    out.* = null;
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    switch (c.a) {
        NavigateDirection_Parent => {
            target = a11y.rvn_a11y_parent(id);
        },
        NavigateDirection_FirstChild => {
            if (a11y.rvn_a11y_child_count(id) > 0) target = a11y.rvn_a11y_child(id, 0);
        },
        NavigateDirection_LastChild => {
            count = a11y.rvn_a11y_child_count(id);
            if (count > 0) target = a11y.rvn_a11y_child(id, count - 1);
        },
        NavigateDirection_NextSibling, NavigateDirection_PreviousSibling => {
            parent = a11y.rvn_a11y_parent(id);
            if (parent != 0) {
                index = a11y.rvn_a11y_index_in_parent(id);
                count = a11y.rvn_a11y_child_count(parent);
                index += if (c.a == NavigateDirection_NextSibling) 1 else -1;
                if (index >= 0 and index < count) target = a11y.rvn_a11y_child(parent, index);
            }
        },
        else => {},
    }
    if (target != 0) {
        if (rvn_uia_provider(c.self.hwnd, target)) |provider| {
            _ = rvn_uia_addref(provider);
            out.* = &provider.fragment;
        }
    }
    return S_OK;
}

fn fragment_navigate(This: *IRawElementProviderFragment, direction: c_int, out: *?*IRawElementProviderFragment) callconv(.winapi) HRESULT {
    return callOn("fragment", do_navigate, This, .{ .a = direction, .out = anyOut(out) });
}

fn fragment_runtime_id(This: *IRawElementProviderFragment, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
    const self = providerOf("fragment", This);
    var values: [3]c_int = undefined;
    out.* = null;
    // (the window takes the runtime id of its HWND)
    if ((self.id >> 32) == 0 and a11y.rvn_a11y_parent(self.id) == 0) return S_OK;
    values[0] = UiaAppendRuntimeId;
    values[1] = @bitCast(@as(u32, @truncate(self.id)));
    values[2] = @bitCast(@as(u32, @truncate(self.id >> 32)));
    out.* = g_uia.sa_create.?(VT_I4, 0, 3);
    if (out.* == null) return E_OUTOFMEMORY;
    var i: LONG = 0;
    while (i < 3) : (i += 1) {
        _ = g_uia.sa_put.?(out.*, &i, &values[@intCast(i)]);
    }
    return S_OK;
}

fn do_bounds(c: *Call) HRESULT {
    const out: *UiaRect = @ptrCast(@alignCast(c.out));
    var x: c_int = undefined;
    var y: c_int = undefined;
    var w: c_int = undefined;
    var h: c_int = undefined;
    out.* = std.mem.zeroes(UiaRect);
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    a11y.rvn_a11y_screen_rect(c.self.id, &x, &y, &w, &h);
    out.left = @floatFromInt(x);
    out.top = @floatFromInt(y);
    out.width = @floatFromInt(w);
    out.height = @floatFromInt(h);
    return S_OK;
}

fn fragment_bounds(This: *IRawElementProviderFragment, out: *UiaRect) callconv(.winapi) HRESULT {
    return callOn("fragment", do_bounds, This, .{ .out = anyOut(out) });
}

fn fragment_embedded(This: *IRawElementProviderFragment, out: *?*SAFEARRAY) callconv(.winapi) HRESULT {
    _ = This;
    out.* = null;
    return S_OK;
}

fn do_set_focus(c: *Call) HRESULT {
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    _ = a11y.rvn_a11y_act(c.self.id, a11y.RVN_A11Y_FOCUS);
    return S_OK;
}

fn fragment_set_focus(This: *IRawElementProviderFragment) callconv(.winapi) HRESULT {
    return callOn("fragment", do_set_focus, This, .{});
}

fn do_fragment_root(c: *Call) HRESULT {
    const out: *?*IRawElementProviderFragmentRoot = @ptrCast(@alignCast(c.out));
    out.* = null;
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    if (rvn_uia_provider(c.self.hwnd, @as(a11y.rvn_a11y_id_t, a11y.rvn_a11y_window(c.self.id)))) |root| {
        _ = rvn_uia_addref(root);
        out.* = &root.root;
    }
    return S_OK;
}

fn fragment_root(This: *IRawElementProviderFragment, out: *?*IRawElementProviderFragmentRoot) callconv(.winapi) HRESULT {
    return callOn("fragment", do_fragment_root, This, .{ .out = anyOut(out) });
}

// ---------------------------------------------------------------------------
//  IRawElementProviderFragmentRoot
// ---------------------------------------------------------------------------

fn do_from_point(c: *Call) HRESULT {
    const out: *?*IRawElementProviderFragment = @ptrCast(@alignCast(c.out));
    var wx: c_int = undefined;
    var wy: c_int = undefined;
    var scale: f32 = undefined;
    out.* = null;
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    a11y.rvn_a11y_window_origin(c.self.id, &wx, &wy, &scale);
    const px: f32 = @floatCast(@as(f64, @floatFromInt(c.a)) - @as(f64, @floatFromInt(wx)));
    const py: f32 = @floatCast(@as(f64, @floatFromInt(c.b)) - @as(f64, @floatFromInt(wy)));
    const hit = a11y.rvn_a11y_hit(a11y.rvn_a11y_window(c.self.id), px / scale, py / scale);
    if (hit != 0) {
        if (rvn_uia_provider(c.self.hwnd, hit)) |provider| {
            _ = rvn_uia_addref(provider);
            out.* = &provider.fragment;
        }
    }
    return S_OK;
}

fn root_from_point(This: *IRawElementProviderFragmentRoot, x: f64, y: f64, out: *?*IRawElementProviderFragment) callconv(.winapi) HRESULT {
    return callOn("root", do_from_point, This, .{ .a = @intFromFloat(x), .b = @intFromFloat(y), .out = anyOut(out) });
}

fn do_get_focus(c: *Call) HRESULT {
    const out: *?*IRawElementProviderFragment = @ptrCast(@alignCast(c.out));
    out.* = null;
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    const focus = a11y.rvn_a11y_focus(a11y.rvn_a11y_window(c.self.id));
    if (focus != 0 and focus != c.self.id) {
        if (rvn_uia_provider(c.self.hwnd, focus)) |provider| {
            _ = rvn_uia_addref(provider);
            out.* = &provider.fragment;
        }
    }
    return S_OK;
}

fn root_get_focus(This: *IRawElementProviderFragmentRoot, out: *?*IRawElementProviderFragment) callconv(.winapi) HRESULT {
    return callOn("root", do_get_focus, This, .{ .out = anyOut(out) });
}

// ---------------------------------------------------------------------------
//  Patterns
// ---------------------------------------------------------------------------

fn do_act(c: *Call) HRESULT {
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    _ = a11y.rvn_a11y_act(c.self.id, @intCast(c.a));
    return S_OK;
}

fn invoke_invoke(This: *IInvokeProvider) callconv(.winapi) HRESULT {
    return callOn("invoke", do_act, This, .{ .a = a11y.RVN_A11Y_PRESS });
}

fn toggle_toggle(This: *IToggleProvider) callconv(.winapi) HRESULT {
    return callOn("toggle", do_act, This, .{ .a = a11y.RVN_A11Y_TOGGLE });
}

fn expand_expand(This: *IExpandCollapseProvider) callconv(.winapi) HRESULT {
    return callOn("expand", do_act, This, .{ .a = a11y.RVN_A11Y_EXPAND });
}

fn expand_collapse(This: *IExpandCollapseProvider) callconv(.winapi) HRESULT {
    return callOn("expand", do_act, This, .{ .a = a11y.RVN_A11Y_COLLAPSE });
}

fn selection_select(This: *ISelectionItemProvider) callconv(.winapi) HRESULT {
    return callOn("selection", do_act, This, .{ .a = a11y.RVN_A11Y_SELECT });
}

fn selection_add(This: *ISelectionItemProvider) callconv(.winapi) HRESULT {
    return callOn("selection", do_act, This, .{ .a = a11y.RVN_A11Y_SELECT });
}

fn selection_remove(This: *ISelectionItemProvider) callconv(.winapi) HRESULT {
    _ = This;
    return S_OK;
}

/// What is asked of a node: 0 states, 1 number, 2 minimum, 3 maximum, 4 step, 5 value text, 6 selection container
fn do_read(c: *Call) HRESULT {
    var node: a11y.rvn_a11y_node_t = undefined;
    if (!rvn_uia_alive(c.self) or a11y.rvn_a11y_describe(c.self.id, &node) == 0) return UIA_E_ELEMENTNOTAVAILABLE;
    switch (c.a) {
        0 => {
            const o: *u32 = @ptrCast(@alignCast(c.out));
            o.* = node.states;
        },
        1 => {
            const o: *f64 = @ptrCast(@alignCast(c.out));
            o.* = node.number;
        },
        2 => {
            const o: *f64 = @ptrCast(@alignCast(c.out));
            o.* = node.minimum;
        },
        3 => {
            const o: *f64 = @ptrCast(@alignCast(c.out));
            o.* = node.maximum;
        },
        4 => {
            const o: *f64 = @ptrCast(@alignCast(c.out));
            o.* = if (node.step > 0.0) node.step else 1.0;
        },
        5 => {
            const o: *BSTR = @ptrCast(@alignCast(c.out));
            o.* = rvn_uia_bstr(node.value);
        },
        6 => {
            const o: *?*IRawElementProviderSimple = @ptrCast(@alignCast(c.out));
            const parent = rvn_uia_provider(c.self.hwnd, a11y.rvn_a11y_parent(c.self.id));
            o.* = null;
            if (parent) |p| {
                _ = rvn_uia_addref(p);
                o.* = &p.simple;
            }
        },
        else => {},
    }
    return S_OK;
}

fn rvn_uia_read(self: *rvn_uia_t, what: isize, out: anytype) HRESULT {
    var call: Call = .{
        .@"fn" = do_read,
        .self = self,
        .a = what,
        .b = 0,
        .d = 0,
        .text = null,
        .out = anyOut(out),
        .result = S_OK,
    };
    return rvn_uia_call(&call);
}

fn toggle_state(This: *IToggleProvider, out: *c_int) callconv(.winapi) HRESULT {
    var states: u32 = 0;
    const hr = rvn_uia_read(providerOf("toggle", This), 0, &states);
    out.* = if ((states & a11y.RVN_A11Y_CHECKED) != 0) ToggleState_On else ToggleState_Off;
    return hr;
}

fn expand_state(This: *IExpandCollapseProvider, out: *c_int) callconv(.winapi) HRESULT {
    var states: u32 = 0;
    const hr = rvn_uia_read(providerOf("expand", This), 0, &states);
    out.* = if ((states & a11y.RVN_A11Y_EXPANDABLE) == 0)
        ExpandCollapseState_LeafNode
    else if ((states & a11y.RVN_A11Y_EXPANDED) != 0)
        ExpandCollapseState_Expanded
    else
        ExpandCollapseState_Collapsed;
    return hr;
}

fn selection_is_selected(This: *ISelectionItemProvider, out: *BOOL) callconv(.winapi) HRESULT {
    var states: u32 = 0;
    const hr = rvn_uia_read(providerOf("selection", This), 0, &states);
    out.* = if ((states & a11y.RVN_A11Y_SELECTED) != 0) TRUE else FALSE;
    return hr;
}

fn selection_container(This: *ISelectionItemProvider, out: *?*IRawElementProviderSimple) callconv(.winapi) HRESULT {
    return rvn_uia_read(providerOf("selection", This), 6, out);
}

fn do_set_value(c: *Call) HRESULT {
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    const text = rvn_uia_utf8(c.text);
    const ok = a11y.rvn_a11y_set_value(c.self.id, text);
    base.rvn_free(text);
    return if (ok != 0) S_OK else UIA_E_ELEMENTNOTAVAILABLE;
}

fn value_set(This: *IValueProvider, text: LPCWSTR) callconv(.winapi) HRESULT {
    return callOn("value", do_set_value, This, .{ .text = text });
}

fn value_get(This: *IValueProvider, out: *BSTR) callconv(.winapi) HRESULT {
    return rvn_uia_read(providerOf("value", This), 5, out);
}

fn value_read_only(This: *IValueProvider, out: *BOOL) callconv(.winapi) HRESULT {
    var states: u32 = 0;
    const hr = rvn_uia_read(providerOf("value", This), 0, &states);
    out.* = if ((states & a11y.RVN_A11Y_EDITABLE) == 0 or (states & a11y.RVN_A11Y_READONLY) != 0) TRUE else FALSE;
    return hr;
}

fn do_set_number(c: *Call) HRESULT {
    if (!rvn_uia_alive(c.self)) return UIA_E_ELEMENTNOTAVAILABLE;
    return if (a11y.rvn_a11y_set_number(c.self.id, c.d) != 0) S_OK else E_INVALIDARG;
}

fn range_set(This: *IRangeValueProvider, value: f64) callconv(.winapi) HRESULT {
    return callOn("range", do_set_number, This, .{ .d = value });
}

fn range_value(This: *IRangeValueProvider, out: *f64) callconv(.winapi) HRESULT {
    return rvn_uia_read(providerOf("range", This), 1, out);
}

fn range_minimum(This: *IRangeValueProvider, out: *f64) callconv(.winapi) HRESULT {
    return rvn_uia_read(providerOf("range", This), 2, out);
}

fn range_maximum(This: *IRangeValueProvider, out: *f64) callconv(.winapi) HRESULT {
    return rvn_uia_read(providerOf("range", This), 3, out);
}

fn range_small(This: *IRangeValueProvider, out: *f64) callconv(.winapi) HRESULT {
    return rvn_uia_read(providerOf("range", This), 4, out);
}

fn range_large(This: *IRangeValueProvider, out: *f64) callconv(.winapi) HRESULT {
    var step: f64 = 1.0;
    const hr = rvn_uia_read(providerOf("range", This), 4, &step);
    out.* = step * 10.0;
    return hr;
}

fn range_read_only(This: *IRangeValueProvider, out: *BOOL) callconv(.winapi) HRESULT {
    var states: u32 = 0;
    const hr = rvn_uia_read(providerOf("range", This), 0, &states);
    out.* = if ((states & a11y.RVN_A11Y_READONLY) != 0) TRUE else FALSE;
    return hr;
}

// ---------------------------------------------------------------------------
//  Tables of functions
// ---------------------------------------------------------------------------

const g_simple_vtbl = IRawElementProviderSimpleVtbl{
    .QueryInterface = U_simple.query,
    .AddRef = U_simple.addref,
    .Release = U_simple.release,
    .get_ProviderOptions = simple_options,
    .GetPatternProvider = simple_pattern,
    .GetPropertyValue = simple_property,
    .get_HostRawElementProvider = simple_host,
};
const g_fragment_vtbl = IRawElementProviderFragmentVtbl{
    .QueryInterface = U_fragment.query,
    .AddRef = U_fragment.addref,
    .Release = U_fragment.release,
    .Navigate = fragment_navigate,
    .GetRuntimeId = fragment_runtime_id,
    .get_BoundingRectangle = fragment_bounds,
    .GetEmbeddedFragmentRoots = fragment_embedded,
    .SetFocus = fragment_set_focus,
    .get_FragmentRoot = fragment_root,
};
const g_root_vtbl = IRawElementProviderFragmentRootVtbl{
    .QueryInterface = U_root.query,
    .AddRef = U_root.addref,
    .Release = U_root.release,
    .ElementProviderFromPoint = root_from_point,
    .GetFocus = root_get_focus,
};
const g_invoke_vtbl = IInvokeProviderVtbl{
    .QueryInterface = U_invoke.query,
    .AddRef = U_invoke.addref,
    .Release = U_invoke.release,
    .Invoke = invoke_invoke,
};
const g_toggle_vtbl = IToggleProviderVtbl{
    .QueryInterface = U_toggle.query,
    .AddRef = U_toggle.addref,
    .Release = U_toggle.release,
    .Toggle = toggle_toggle,
    .get_ToggleState = toggle_state,
};
const g_value_vtbl = IValueProviderVtbl{
    .QueryInterface = U_value.query,
    .AddRef = U_value.addref,
    .Release = U_value.release,
    .SetValue = value_set,
    .get_Value = value_get,
    .get_IsReadOnly = value_read_only,
};
const g_range_vtbl = IRangeValueProviderVtbl{
    .QueryInterface = U_range.query,
    .AddRef = U_range.addref,
    .Release = U_range.release,
    .SetValue = range_set,
    .get_Value = range_value,
    .get_IsReadOnly = range_read_only,
    .get_Maximum = range_maximum,
    .get_Minimum = range_minimum,
    .get_LargeChange = range_large,
    .get_SmallChange = range_small,
};
const g_expand_vtbl = IExpandCollapseProviderVtbl{
    .QueryInterface = U_expand.query,
    .AddRef = U_expand.addref,
    .Release = U_expand.release,
    .Expand = expand_expand,
    .Collapse = expand_collapse,
    .get_ExpandCollapseState = expand_state,
};
const g_selection_vtbl = ISelectionItemProviderVtbl{
    .QueryInterface = U_selection.query,
    .AddRef = U_selection.addref,
    .Release = U_selection.release,
    .Select = selection_select,
    .AddToSelection = selection_add,
    .RemoveFromSelection = selection_remove,
    .get_IsSelected = selection_is_selected,
    .get_SelectionContainer = selection_container,
};

/// The provider of a node (made on first use; the table keeps a reference).
fn rvn_uia_provider(hwnd_in: HWND, id: a11y.rvn_a11y_id_t) ?*rvn_uia_t {
    var hwnd = hwnd_in;
    if (id == 0) return null;
    var i: c_int = 0;
    while (i < g_uia.count) : (i += 1) {
        const entry = g_uia.table[@intCast(i)];
        if (entry.id == id and entry.disconnected == 0) return entry;
    }
    if (hwnd == null) hwnd = rvn_uia_hwnd_of(id);
    const self: *rvn_uia_t = @ptrCast(@alignCast(base.rvn_calloc(@sizeOf(rvn_uia_t))));
    self.simple.lpVtbl = &g_simple_vtbl;
    self.fragment.lpVtbl = &g_fragment_vtbl;
    self.root.lpVtbl = &g_root_vtbl;
    self.invoke.lpVtbl = &g_invoke_vtbl;
    self.toggle.lpVtbl = &g_toggle_vtbl;
    self.value.lpVtbl = &g_value_vtbl;
    self.range.lpVtbl = &g_range_vtbl;
    self.expand.lpVtbl = &g_expand_vtbl;
    self.selection.lpVtbl = &g_selection_vtbl;
    self.refs = 1;
    self.id = id;
    self.hwnd = hwnd;
    if (g_uia.count == g_uia.capacity) {
        g_uia.capacity = if (g_uia.capacity != 0) g_uia.capacity * 2 else 64;
        g_uia.table = @ptrCast(@alignCast(base.rvn_realloc(@ptrCast(g_uia.table), @as(usize, @intCast(g_uia.capacity)) * @sizeOf(*rvn_uia_t))));
    }
    g_uia.table[@intCast(g_uia.count)] = self;
    g_uia.count += 1;
    return self;
}

/// The providers of nodes that are gone are dropped now and then.
fn rvn_uia_collect() void {
    var i: c_int = 0;
    while (i < g_uia.count) {
        const self = g_uia.table[@intCast(i)];
        if (self.disconnected == 0 and a11y.rvn_a11y_exists(self.id) != 0) {
            i += 1;
            continue;
        }
        if (self.disconnected == 0) {
            if (g_uia.disconnect) |d| _ = d(&self.simple);
        }
        self.disconnected = raven.R_TRUE;
        g_uia.count -= 1;
        g_uia.table[@intCast(i)] = g_uia.table[@intCast(g_uia.count)];
        _ = rvn_uia_release(self);
    }
}

// ---------------------------------------------------------------------------
//  Platform
// ---------------------------------------------------------------------------

const rvn_uia_window_t = extern struct {
    hwnd: HWND,
    user: ?*anyopaque,
};
var g_windows: [64]rvn_uia_window_t = std.mem.zeroes([64]rvn_uia_window_t);
var g_window_count: c_int = 0;

fn rvn_uia_hwnd_of(id: a11y.rvn_a11y_id_t) HWND {
    const window = a11y.rvn_a11y_window(id);
    var i: c_int = 0;
    while (i < g_window_count) : (i += 1) {
        if (a11y.rvn_a11y_window_of(g_windows[@intCast(i)].user) == window) return g_windows[@intCast(i)].hwnd;
    }
    return null;
}

fn rvn_uia_get_object(hwnd: HWND, user: ?*anyopaque, wparam: WPARAM, lparam: LPARAM, result: [*c]LRESULT) callconv(.c) c_int {
    if (@as(i32, @truncate(lparam)) != UiaRootObjectId or rvn_uia_load() == raven.R_FALSE) return raven.R_FALSE;
    var i: c_int = 0;
    while (i < g_window_count and g_windows[@intCast(i)].hwnd != hwnd) : (i += 1) {}
    if (i == g_window_count and g_window_count < g_windows.len) {
        g_windows[@intCast(g_window_count)].hwnd = hwnd;
        g_windows[@intCast(g_window_count)].user = user;
        g_window_count += 1;
    }
    const window = a11y.rvn_a11y_window_of(user);
    if (window == 0) return raven.R_FALSE;
    rvn_uia_collect();
    const root = rvn_uia_provider(hwnd, @as(a11y.rvn_a11y_id_t, window)) orelse return raven.R_FALSE;
    result.* = g_uia.return_provider.?(hwnd, wparam, lparam, &root.simple);
    return raven.R_TRUE;
}

fn rvn_uia_window_destroyed(hwnd: HWND) callconv(.c) void {
    var i: c_int = 0;
    if (g_uia.loaded == 0) return;
    _ = g_uia.return_provider.?(hwnd, 0, 0, null);
    i = 0;
    while (i < g_uia.count) : (i += 1) {
        const entry = g_uia.table[@intCast(i)];
        if (entry.hwnd == hwnd and entry.disconnected == 0) {
            if (g_uia.disconnect) |d| _ = d(&entry.simple);
            entry.disconnected = raven.R_TRUE;
        }
    }
    rvn_uia_collect();
    i = 0;
    while (i < g_window_count) : (i += 1) {
        if (g_windows[@intCast(i)].hwnd == hwnd) {
            g_window_count -= 1;
            g_windows[@intCast(i)] = g_windows[@intCast(g_window_count)];
            break;
        }
    }
}

fn rvn_uia_shutdown() callconv(.c) void {
    var i: c_int = 0;
    while (i < g_uia.count) : (i += 1) {
        const entry = g_uia.table[@intCast(i)];
        if (entry.disconnected == 0) {
            if (g_uia.disconnect) |d| _ = d(&entry.simple);
        }
        entry.disconnected = raven.R_TRUE;
        _ = rvn_uia_release(entry);
    }
    base.rvn_free(@ptrCast(g_uia.table));
    g_uia.table = null;
    g_uia.count = 0;
    g_uia.capacity = 0;
    g_window_count = 0;
}

fn rvn_uia_active() callconv(.c) c_int {
    var reader: BOOL = FALSE;
    if (SystemParametersInfoW(SPI_GETSCREENREADER, 0, &reader, 0) != 0 and reader != 0) return raven.R_TRUE;
    if (rvn_uia_load() != raven.R_FALSE and g_uia.listening != null and g_uia.listening.?() != 0) return raven.R_TRUE;
    return raven.R_FALSE;
}

fn rvn_uia_event(hwnd: HWND, event: c_int, node: u64) callconv(.c) void {
    var info: a11y.rvn_a11y_node_t = undefined;
    var old_value: VARIANT = undefined;
    var new_value: VARIANT = undefined;
    if (rvn_uia_load() == raven.R_FALSE or (g_uia.listening != null and g_uia.listening.?() == 0)) return;
    const provider = rvn_uia_provider(hwnd, node) orelse return;
    switch (event) {
        a11y.RVN_A11Y_EVENT_FOCUS => {
            _ = g_uia.raise_event.?(&provider.simple, UIA_AutomationFocusChangedEventId);
        },
        a11y.RVN_A11Y_EVENT_VALUE, a11y.RVN_A11Y_EVENT_NAME, a11y.RVN_A11Y_EVENT_STATE => {
            if (g_uia.raise_property != null and a11y.rvn_a11y_describe(node, &info) != 0) {
                old_value = std.mem.zeroes(VARIANT);
                new_value = std.mem.zeroes(VARIANT);
                old_value.vt = VT_EMPTY;
                if ((info.states & a11y.RVN_A11Y_HAS_RANGE) != 0) {
                    new_value.vt = VT_R8;
                    new_value.u.dblVal = info.number;
                    _ = g_uia.raise_property.?(&provider.simple, UIA_RangeValueValuePropertyId, old_value, new_value);
                } else if ((info.states & a11y.RVN_A11Y_CHECKABLE) != 0) {
                    new_value.vt = VT_I4;
                    new_value.u.lVal = if ((info.states & a11y.RVN_A11Y_CHECKED) != 0) ToggleState_On else ToggleState_Off;
                    _ = g_uia.raise_property.?(&provider.simple, UIA_ToggleToggleStatePropertyId, old_value, new_value);
                } else if ((info.states & a11y.RVN_A11Y_EXPANDABLE) != 0) {
                    new_value.vt = VT_I4;
                    new_value.u.lVal = if ((info.states & a11y.RVN_A11Y_EXPANDED) != 0) ExpandCollapseState_Expanded else ExpandCollapseState_Collapsed;
                    _ = g_uia.raise_property.?(&provider.simple, UIA_ExpandCollapseExpandCollapseStatePropertyId, old_value, new_value);
                } else if (info.value[0] != 0 or (info.states & a11y.RVN_A11Y_EDITABLE) != 0) {
                    new_value.vt = VT_BSTR;
                    new_value.u.bstrVal = rvn_uia_bstr(info.value);
                    _ = g_uia.raise_property.?(&provider.simple, UIA_ValueValuePropertyId, old_value, new_value);
                    if (g_uia.sys_free) |f| f(new_value.u.bstrVal);
                } else {
                    new_value.vt = VT_BSTR;
                    new_value.u.bstrVal = rvn_uia_bstr(info.name);
                    _ = g_uia.raise_property.?(&provider.simple, UIA_NamePropertyId, old_value, new_value);
                    if (g_uia.sys_free) |f| f(new_value.u.bstrVal);
                }
            }
        },
        a11y.RVN_A11Y_EVENT_STRUCTURE => {
            rvn_uia_collect();
            if (g_uia.raise_structure) |f| _ = f(&provider.simple, StructureChangeType_ChildrenInvalidated, null, 0);
        },
        else => {},
    }
}

fn rvn_uia_announce(hwnd: HWND, user: ?*anyopaque, text: [*c]const u8, assertive: c_int) callconv(.c) void {
    if (rvn_uia_load() == raven.R_FALSE or g_uia.raise_notification == null) return;
    const root = rvn_uia_provider(hwnd, @as(a11y.rvn_a11y_id_t, a11y.rvn_a11y_window_of(user))) orelse return;
    const message = rvn_uia_bstr(text);
    const activity = rvn_uia_bstr("RavenAnnouncement");
    // NotificationKind_Other, NotificationProcessing_ImportantMostRecent / _MostRecent
    _ = g_uia.raise_notification.?(&root.simple, NotificationKind_Other, if (assertive != 0) NotificationProcessing_ImportantMostRecent else NotificationProcessing_MostRecent, message, activity);
    if (g_uia.sys_free) |f| {
        f(message);
        f(activity);
    }
}

fn rvn_uia_settings(settings: [*c]raven.RAccessibilitySettings) callconv(.c) void {
    var contrast = std.mem.zeroes(HIGHCONTRASTW);
    var animations: BOOL = TRUE;
    contrast.cbSize = HIGHCONTRAST_SIZE;
    if (SystemParametersInfoW(SPI_GETHIGHCONTRAST, HIGHCONTRAST_SIZE, &contrast, 0) != 0) {
        settings.*.high_contrast = @intFromBool((contrast.dwFlags & HCF_HIGHCONTRASTON) != 0);
    }
    if (SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &animations, 0) != 0) {
        settings.*.reduce_motion = @intFromBool(animations == 0);
    }
    // Settings > Accessibility > Text size: 100 to 225 %
    const advapi = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("Advapi32.dll"));
    if (advapi != null) {
        const get: ?RegGetValueWFn = @ptrCast(GetProcAddress(advapi, "RegGetValueW"));
        var percent: DWORD = 0;
        var size: DWORD = @sizeOf(DWORD);
        if (get) |f| {
            if (f(HKEY_CURRENT_USER, std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Accessibility"), std.unicode.utf8ToUtf16LeStringLiteral("TextScaleFactor"), RRF_RT_REG_DWORD, null, &percent, &size) == ERROR_SUCCESS and
                percent >= 100 and percent <= 400)
            {
                settings.*.text_scale = @as(f32, @floatFromInt(percent)) / 100.0;
            }
        }
    }
}

// The exports of the C file. The C file is `#if defined(_WIN32)`: on the other
// targets nothing is exported and the Win32 imports above are not analysed.
comptime {
    if (builtin.os.tag == .windows) {
        @export(&rvn_uia_handle_message, .{ .name = "rvn_uia_handle_message" });
        @export(&rvn_uia_get_object, .{ .name = "rvn_uia_get_object" });
        @export(&rvn_uia_window_destroyed, .{ .name = "rvn_uia_window_destroyed" });
        @export(&rvn_uia_shutdown, .{ .name = "rvn_uia_shutdown" });
        @export(&rvn_uia_active, .{ .name = "rvn_uia_active" });
        @export(&rvn_uia_event, .{ .name = "rvn_uia_event" });
        @export(&rvn_uia_announce, .{ .name = "rvn_uia_announce" });
        @export(&rvn_uia_settings, .{ .name = "rvn_uia_settings" });
    }
}
