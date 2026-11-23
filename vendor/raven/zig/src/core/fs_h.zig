// Translated to Zig from vendor/raven/src/core/fs.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/fs.h
// The file system as the file browser and the dialogs need it: folders,
// paths, the usual places of the user. Paths are UTF-8 on every platform.

const builtin = @import("builtin");

pub const RVN_PATH_SEPARATOR: u8 = if (builtin.os.tag == .windows) '\\' else '/';

pub const rvn_dir_entry_t = extern struct {
    name: [*c]u8,
    is_dir: c_int,
    /// Hidden by the conventions of the OS (dot files, the hidden attribute).
    hidden: c_int,
    size: u64,
    /// Last modification, in seconds since 1970 (UTC).
    modified: i64,
};
pub const struct_rvn_dir_entry_t = rvn_dir_entry_t;

/// Lists a folder, without "." and "..", in no particular order. R_FALSE when it cannot be read.
pub extern fn rvn_dir_read(path: [*c]const u8, entries: [*c][*c]rvn_dir_entry_t, count: [*c]u32) c_int;
pub extern fn rvn_dir_free(entries: [*c]rvn_dir_entry_t, count: u32) void;

pub extern fn rvn_path_exists(path: [*c]const u8) c_int;
pub extern fn rvn_path_is_dir(path: [*c]const u8) c_int;
pub inline fn rvn_path_is_separator(c: u8) c_int {
    if (builtin.os.tag == .windows) {
        return @intFromBool(c == '\\' or c == '/');
    } else {
        return @intFromBool(c == '/');
    }
}
/// Absolute path without "." or "..", without a trailing separator except for a root. Free with rvn_free.
pub extern fn rvn_path_absolute(path: [*c]const u8) [*c]u8;
/// Folder containing a path (given absolute), or NULL for a root. Free with rvn_free.
pub extern fn rvn_path_parent(path: [*c]const u8) [*c]u8;
/// A name inside a folder. Free with rvn_free.
pub extern fn rvn_path_child(folder: [*c]const u8, name: [*c]const u8) [*c]u8;
/// Last component of a path: points inside `path`.
pub extern fn rvn_path_name(path: [*c]const u8) [*c]const u8;
/// Home folder of the user. Free with rvn_free.
pub extern fn rvn_path_home() [*c]u8;
/// When a file was last written (finer than a second where the file system
/// allows) and its size: both change when the file does. R_FALSE when it
/// cannot be read.
pub extern fn rvn_file_stamp(path: [*c]const u8, modified: [*c]u64, size: [*c]u64) c_int;
pub extern fn rvn_make_dir(path: [*c]const u8) c_int;
pub extern fn rvn_write_file(path: [*c]const u8, data: ?*const anyopaque, size: usize) c_int;
/// True when the address is an HTTP or HTTPS URL (case-insensitive scheme).
pub extern fn rvn_is_http_url(value: [*c]const u8) c_int;
/// Downloads a URL into an rvn_alloc'ed buffer. Limited to 32 MiB and 20 seconds.
pub extern fn rvn_fs_download_url(url: [*c]const u8, data: [*c][*c]u8, size: [*c]usize) c_int;

/// A folder the user goes to often: home, desktop, documents, a drive...
pub const rvn_place_t = extern struct {
    label: [*c]u8,
    path: [*c]u8,
};
pub const struct_rvn_place_t = rvn_place_t;

pub extern fn rvn_fs_places(places: [*c][*c]rvn_place_t, count: [*c]u32) void;
pub extern fn rvn_fs_places_free(places: [*c]rvn_place_t, count: u32) void;

/// Does a file name match one of the patterns ("*.xml;*.ui", "*")? Case is ignored. An empty list matches all.
pub extern fn rvn_pattern_match(patterns: [*c]const u8, name: [*c]const u8) c_int;
