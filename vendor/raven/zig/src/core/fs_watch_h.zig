// Translated to Zig from vendor/raven/src/core/fs_watch.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/fs_watch.h
// Native directory notifications. Callbacks are raised on a system worker
// thread and must marshal UI work with Rtask_post.

pub const rvn_fs_watch_callback_t = ?*const fn (absolute_path: [*c]const u8, user: ?*anyopaque) callconv(.c) void;

pub extern fn rvn_fs_watch_start(callback: rvn_fs_watch_callback_t, user: ?*anyopaque) c_int;
pub extern fn rvn_fs_watch_add(path: [*c]const u8) c_int;
pub extern fn rvn_fs_watch_stop() void;
