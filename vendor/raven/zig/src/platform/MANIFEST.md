# platform module: manifest

Source: `vendor/raven/src/platform`. Translated header units (all check clean with `check_unit.sh`, also for
`x86_64-linux-gnu` / `x86_64-windows-gnu` where the header is shared):

| C header | Zig header unit | import from `src/platform/*.zig` | from `src/platform/<os>/*.zig` |
|---|---|---|---|
| `platform.h` | `platform_h.zig` | `@import("platform_h.zig")` | `@import("../platform_h.zig")` |
| `atspi.h` | `atspi_h.zig` | `@import("atspi_h.zig")` | `@import("../atspi_h.zig")` |
| `win32/win32_uia.h` | `win32/win32_uia_h.zig` | `@import("win32/win32_uia_h.zig")` | `@import("win32_uia_h.zig")` |
| `x11/x11_internal.h` | `x11/x11_internal_h.zig` | `@import("x11/x11_internal_h.zig")` | `@import("x11_internal_h.zig")` |
| (other modules) | `externs.zig` (see end) | `@import("externs.zig")` | `@import("../externs.zig")` |

Types in `platform_h.zig`: `rvn_pwindow_t` (opaque, each platform defines its own struct and casts with
`@ptrCast(@alignCast(...))`; C `rvn_pwindow_t*` is `?*rvn_pwindow_t`), `rvn_pevent_type_t` / `rvn_pregion_t` /
`rvn_pwindow_state_t` (`c_uint`, enumerators `RVN_PEVENT_*`, `RVN_PREGION_*`, `RVN_PWINDOW_*` as `c_int` constants),
`rvn_pevent_t`, `rvn_pevent_handler_t`, `rvn_pregion_handler_t` (both already optional pointers, `?*const fn`),
`rvn_pwindow_desc_t`, `rvn_platform_t` (every table entry is an optional function pointer; build the table with
`.field = &fn` or `null`). Other pointers to data are `[*c]`. `RKey`, `RCursor`, `RNativeWindow`, `RWindowSystem`,
`RAccessibilitySettings` come from `raven`.

Layout: `zig/layout/platform_layout.c` + `zig/src/platform_layout.zig`, run by `zig/layout/platform_layout.sh`
(prints `PLATFORM LAYOUT OK (142 values)`: sizeof / alignof / every field offset of `rvn_pevent_t`,
`rvn_pwindow_desc_t`, `rvn_platform_t`, `rvn_a11y_node_t`, plus the enumerator and flag values). `check.sh` is not
edited by this job; the integrator should call that script after its step 3 (the pure C pass already compiled).

Every non-static symbol of this module is a function; there are no exported global variables. The module-level
state (`g_null`, `g_x11`, `g_win32`, `g_cocoa`, `g_atspi`, `g_uia`, ...) is `static` -> plain `var` in the Zig file.
Exports are listed below; Zig signature = C signature with the table of PORTING.md section 3 (`export fn`).
Each `rvn_platform_*()` returns a pointer to a function-local `static const rvn_platform_t platform = {...}`: in Zig a
file-level `const platform: platform_h.rvn_platform_t = .{...};` and `return &platform;`.

## platform/platform.c  ->  platform/platform.zig

```c
const rvn_platform_t* rvn_platform_select(int headless);
```
```zig
export fn rvn_platform_select(headless: c_int) [*c]const platform.rvn_platform_t
```
Uses `config.platform_win32` / `platform_x11` / `platform_cocoa` (comptime) for the `#if` chain, then
`platform.rvn_platform_null()`. Calls `rvn_platform_win32/x11/cocoa` only in the active branch (the others
are `pub extern fn` in `platform_h.zig`, never linked when unused).

## platform/null/null_platform.c  ->  platform/null/null_platform.zig

```c
const rvn_platform_t* rvn_platform_null(void);
```
```zig
export fn rvn_platform_null() [*c]const platform.rvn_platform_t
```
Needs from other modules: `rvn_mutex_*`, `rvn_cond_*`, `rvn_cond_wait_timeout` (core/thread.h; `externs.zig` re-exports them
and `rvn_mutex_t` / `rvn_cond_t`), `rvn_calloc`, `rvn_free`, `rvn_strdup`, `rvn_str_set` (`base_h.zig`),
(`Rwindow_inject_*` appears only in a comment of the C file).

## platform/x11/x11_keys.c  ->  platform/x11/x11_keys.zig   (check with `x86_64-linux-gnu`)

```c
RKey rvn_x11_translate_keysym(KeySym symbol);
uint32_t rvn_x11_translate_modifiers(unsigned int state);
```
```zig
export fn rvn_x11_translate_keysym(symbol: KeySym) raven.RKey            // KeySym = c_ulong (x11_internal_h.zig)
export fn rvn_x11_translate_modifiers(state: c_uint) u32
```
Needs `<X11/keysym.h>` constants (`XK_*`) and `ShiftMask`/`ControlMask`/`Mod1Mask`/`Mod4Mask`
values: not another Raven module; declare them as file-level `const`s in x11_keys.zig (hand-copied from keysym.h / X.h).

## platform/x11/x11_platform.c  ->  platform/x11/x11_platform.zig   (check with `x86_64-linux-gnu`)

```c
const rvn_platform_t* rvn_platform_x11(void);
```
```zig
export fn rvn_platform_x11() [*c]const platform.rvn_platform_t
```
From other Raven modules: `rvn_alloc`, `rvn_calloc`, `rvn_free`, `rvn_strdup`, `rvn_strndup`, `rvn_str_set`, `rvn_utf8_decode`,
`rvn_utf8_encode`, `rvn_error`, `rvn_maxi` (`base_h.zig`); `rvn_x11_translate_keysym/_modifiers`
(`x11_internal_h.zig`); `rvn_atspi_init/shutdown/fd/dispatch/event/announce/active/settings` (`atspi_h.zig`).
Xlib / Xkb / Xutil / Xatom / Xresource / cursorfont, `poll`, `fcntl`, `setlocale`... are OS APIs, not in `externs.zig`:
the translator of this file declares them (Xlib types, `XEvent` union, atoms, cursors) in its own
`x11_xlib.zig`-style hand-written extern block or `sys/libc.zig` additions; this manifest does not cover them.

## platform/atspi.c  ->  platform/atspi.zig   (whole file is `#if !_WIN32 && !__APPLE__`; check with `x86_64-linux-gnu`)

```c
int  rvn_atspi_init(void);
void rvn_atspi_shutdown(void);
int  rvn_atspi_fd(void);
void rvn_atspi_dispatch(void);
void rvn_atspi_event(rvn_pwindow_t* window, int event, uint64_t id);
void rvn_atspi_announce(rvn_pwindow_t* window, const char* text, int assertive);
int  rvn_atspi_active(void);
void rvn_atspi_settings(RAccessibilitySettings* settings);
```
```zig
export fn rvn_atspi_init() c_int
export fn rvn_atspi_shutdown() void
export fn rvn_atspi_fd() c_int
export fn rvn_atspi_dispatch() void
export fn rvn_atspi_event(window: ?*platform.rvn_pwindow_t, event: c_int, id: u64) void
export fn rvn_atspi_announce(window: ?*platform.rvn_pwindow_t, text: [*c]const u8, assertive: c_int) void
export fn rvn_atspi_active() c_int
export fn rvn_atspi_settings(settings: [*c]raven.RAccessibilitySettings) void
```
(The `.h` names the third parameter `node`, the `.c` `id`; same type.) From other modules (all in `externs.zig`):
`rvn_a11y_describe/exists/window/parent/child_count/child/index_in_parent/hit/act/set_value/set_number/screen_rect/
window_origin/locale/role_name`, `rvn_a11y_node_t`, `rvn_a11y_id_t`, `rvn_pool_at`;
`Rget_version`, `Raccessibility_is_screen_reader_active` (`raven`); `rvn_free`, `rvn_strdup`, `rvn_strndup`, `rvn_utf8_decode`
(`base_h.zig`); `dlopen` / `dlsym` / `dlclose` / `snprintf` / `strcmp` etc. (`sys/libc.zig`).
**Blocker to report:** atspi.c reads `g_rvn.windows` (`rvn_pool_t`, `core/context.h`: `g_rvn.windows.used`, `rvn_pool_at(&g_rvn.windows, i)`).
There is no `core/context_h.zig` yet; the translator needs `pub extern var g_rvn: rvn_context_t` from the core module's
header unit (the `windows` field offset must match), or the integrator adds it to `externs.zig` later.

## platform/win32/win32_uia.c  ->  platform/win32/win32_uia.zig   (`#if defined(_WIN32)`; check with `x86_64-windows-gnu`)

```c
int  rvn_uia_handle_message(UINT message, WPARAM wparam, LPARAM lparam);
int  rvn_uia_get_object(HWND hwnd, void* user, WPARAM wparam, LPARAM lparam, LRESULT* result);
void rvn_uia_window_destroyed(HWND hwnd);
void rvn_uia_shutdown(void);
int  rvn_uia_active(void);
void rvn_uia_event(HWND hwnd, int event, uint64_t node);
void rvn_uia_announce(HWND hwnd, void* user, const char* text, int assertive);
void rvn_uia_settings(RAccessibilitySettings* settings);
```
```zig
export fn rvn_uia_handle_message(message: UINT, wparam: WPARAM, lparam: LPARAM) c_int
export fn rvn_uia_get_object(hwnd: HWND, user: ?*anyopaque, wparam: WPARAM, lparam: LPARAM, result: [*c]LRESULT) c_int
export fn rvn_uia_window_destroyed(hwnd: HWND) void
export fn rvn_uia_shutdown() void
export fn rvn_uia_active() c_int
export fn rvn_uia_event(hwnd: HWND, event: c_int, node: u64) void
export fn rvn_uia_announce(hwnd: HWND, user: ?*anyopaque, text: [*c]const u8, assertive: c_int) void
export fn rvn_uia_settings(settings: [*c]raven.RAccessibilitySettings) void
```
`HWND = ?*anyopaque`, `WPARAM = usize`, `LPARAM = isize`, `LRESULT = isize`, `UINT = c_uint` (`win32_uia_h.zig`).
From other modules (`externs.zig`): `rvn_a11y_*` (including `rvn_a11y_focus`, `rvn_a11y_window_of`), `rvn_alloc`, `rvn_calloc`,
`rvn_realloc`, `rvn_free` (`base_h.zig`). The COM interfaces (`IRawElementProviderSimple`, `IUnknown` vtables, `VARIANT`,
`SAFEARRAY`, `UiaHostProviderFromHwnd`, `UiaRaiseAutomationEvent` loaded with `GetProcAddress`...) are OS APIs: the translator
declares them by hand in the file (vtables are `extern struct` of function pointers, `callconv(.winapi)`).

## platform/win32/win32_platform.c  ->  platform/win32/win32_platform.zig   (`#if defined(_WIN32)`; check with `x86_64-windows-gnu`)

```c
const rvn_platform_t* rvn_platform_win32(void);
```
```zig
export fn rvn_platform_win32() [*c]const platform.rvn_platform_t
```
From other modules: `rvn_calloc`, `rvn_free`, `rvn_error`, `rvn_maxi` (`base_h.zig`); `Rwindow_set_icon` (`raven`);
`rvn_uia_get_object/handle_message/window_destroyed/shutdown/event/announce/active/settings` (`win32_uia_h.zig`). User32 /
gdi32 / dwmapi / shell32 / ole32 declarations are OS APIs (hand-written; the file loads several lazily with
`LoadLibrary`/`GetProcAddress` and has its own `*_fn` typedefs).

## platform/cocoa/cocoa_platform.m  ->  platform/cocoa/cocoa_platform.zig   (macOS; host check, no target flag)

```c
const rvn_platform_t* rvn_platform_cocoa(void);
```
```zig
export fn rvn_platform_cocoa() [*c]const platform.rvn_platform_t
```
From other modules: `rvn_calloc`, `rvn_free`, `rvn_strdup`, `rvn_clampf`, `rvn_maxi` (`base_h.zig`); `rvn_a11y_*`
(`rvn_a11y_act/child/child_count/describe/exists/focus/hit/parent/set_number/set_value/window_of`, `rvn_a11y_node_t`) via
`externs.zig`. **Objective-C blocker:** the file defines Objective-C classes (NSWindow / NSView / NSAccessibility subclasses,
`g_cocoa_elements`). Zig has no `@cImport` and no ObjC syntax: the translation has to go through `objc_msgSend` /
`objc_allocateClassPair` / `class_addMethod` hand-declared externs. The class `NSAccessibilityElement`-style methods become
`callconv(.c)` functions registered at runtime. Needs a shared `src/sys/objc.zig` (not part of this job).

## externs.zig (declared from OTHER modules)

`zig/src/platform/externs.zig` declares: `rvn_a11y_id_t`, the `RVN_A11Y_*` flags, `rvn_a11y_node_t` (exact layout,
checked), `rvn_a11y_event_t` / `rvn_a11y_action_t` + enumerators, and the 15 `rvn_a11y_*` prototypes of `core/accessibility.h`
(no `accessibility_h.zig` exists yet; this file is the stand-in). It re-exports `rvn_mutex_t`, `rvn_cond_t`, `rvn_mutex_*`,
`rvn_cond_*` from `core/thread_h.zig` and `rvn_pool_t`, `rvn_pool_at` from `core/handle_h.zig` (written by the core
module's jobs; if they are renamed, fix this file). Everything else the platform files call is already in `base_h.zig`
(allocator, strings, UTF-8, `rvn_error`) or `raven.zig` (`Rget_version`, `Raccessibility_is_screen_reader_active`,
`Rwindow_set_icon`, `Rwindow_inject_*`). Not available: `g_rvn` (see the atspi blocker).

## Layout check removed (2026-11-13)

The C-vs-Zig layout check of this module's private types (layout/*_layout.c and its Zig side) was removed: every C file of
the library is translated, so no C code compiles the private headers any more and the header units are the only definition
of these types. `check.sh` step 3 still compares the public types (include/raven) with the C compiler, and step 3b the
system types (pthread, timespec, pollfd, dirent) the Zig code takes from std.c (layout/system_layout.c).
