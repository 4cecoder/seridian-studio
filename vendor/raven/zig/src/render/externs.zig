// Seridian: hand-written extern declarations of what the files of src/render need from OUTSIDE the module and that no
// header unit declares. Not a translation of a Raven file. Import as  const ext = @import("externs.zig");
// (from src/render/vulkan: @import("../externs.zig")).
//
// Everything else the render files call from other Raven modules is in a header unit that already exists:
//   core/base_h.zig        rvn_alloc/rvn_free/rvn_realloc/rvn_calloc, RVN_ARRAY_RESERVE, rvn_stricmp, rvn_error, utf8, rvn_box_*, rvn_rect_*
//   core/context_h.zig     g_rvn, RVN_API_GUARD(_VOID), RVN_THEME_METRIC, rvn_invalidate_all_windows, rvn_repaint_all_windows, rvn_wake
//   core/thread_h.zig      rvn_mutex_*, rvn_cond_*, rvn_thread_*, rvn_atomic_*, rvn_clock_seconds, rvn_sleep_ms
//   core/handle_h.zig      rvn_handle_*, rvn_pool_*          core/jobs_h.zig    rvn_jobs_submit
//   core/lfmap_h.zig       rvn_lfmap_*                       core/fs_h.zig      rvn_fs_download_url, rvn_is_http_url
//   render/font_h.zig      rvn_a11y_text_scale (defined by core/accessibility.c, declared by font.h)
//   render/draw_h.zig      rvn_window_pointer (defined by widget/window.c, declared by draw.h)
//   sys/libc.zig           the C library (string, stdio, stdlib, dlopen/dlsym/dlclose, ...);  std.c  dirent, stat, ...
//   @ceil/@floor/@abs      ceilf/floorf/fabsf
// The Vulkan entry points are NOT extern functions: they are the function pointers of the `rvn_vk` table (vk_loader_h.zig).
//
// What is declared here is what is left: Win32 loader / system calls used by vk_loader.c and font_system.c (only
// analysed when the code is compiled for Windows, `if (builtin.os.tag == .windows)`), and S_ISDIR.

const builtin = @import("builtin");

/// Win32 kernel32 functions, empty on other targets: use  `ext.win.LoadLibraryA(...)`  inside `if (builtin.os.tag == .windows)`.
pub const win = if (builtin.os.tag == .windows) struct {
    pub const HMODULE = ?*anyopaque;
    pub const FARPROC = ?*const anyopaque;
    // render/vulkan/vk_loader.c: vulkan-1.dll loading
    pub extern "kernel32" fn LoadLibraryA(lpLibFileName: [*c]const u8) callconv(.winapi) HMODULE;
    pub extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) c_int;
    pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*c]const u8) callconv(.winapi) FARPROC;
    // render/font_system.c: C:\Windows\Fonts
    pub extern "kernel32" fn GetWindowsDirectoryA(lpBuffer: [*c]u8, uSize: c_uint) callconv(.winapi) c_uint;
} else struct {};

// ---- POSIX <sys/stat.h> macro used by render/font_system.c ----
const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
/// S_ISDIR(mode)
pub inline fn S_ISDIR(mode: u32) bool {
    return (mode & S_IFMT) == S_IFDIR;
}
