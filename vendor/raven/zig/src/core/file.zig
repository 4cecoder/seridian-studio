// Translated to Zig from vendor/raven/src/core/file.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/file.c
// Whole-file reading with UTF-8 paths on every platform.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const base = @import("base_h.zig");
const thread = @import("thread_h.zig");
const ctx = @import("context_h.zig");
const libc = @import("../sys/libc.zig");

// static FILE* rvn_fopen_read(const char* path)  (Windows: UTF-8 path to wide chars, then _wfopen)
const CP_UTF8: u32 = 65001;
extern "kernel32" fn MultiByteToWideChar(code_page: u32, flags: u32, multi_byte: [*c]const u8, multi_byte_len: c_int, wide: [*c]u16, wide_len: c_int) callconv(.winapi) c_int;
extern "c" fn _wfopen(path: [*c]const u16, mode: [*c]const u16) ?*libc.FILE;

fn rvn_fopen_read(path: [*c]const u8) ?*libc.FILE {
    if (builtin.os.tag == .windows) {
        var wide: [1024]u16 = undefined;
        if (MultiByteToWideChar(CP_UTF8, 0, path, -1, &wide, @intCast(wide.len)) <= 0) return null;
        return _wfopen(&wide, std.unicode.utf8ToUtf16LeStringLiteral("rb"));
    } else {
        return libc.fopen(path, "rb");
    }
}

// ---------------------------------------------------------------------------
//  Files held in memory (Rfile_register_memory): resources embedded in the
//  executable. Every file Raven reads is looked up here first.
// ---------------------------------------------------------------------------

const rvn_memory_file_t = extern struct {
    path: [*c]u8,
    data: [*c]const u8,
    size: usize,
    owned: c_int,
};

var g_memory_files: [*c]rvn_memory_file_t = null;
var g_memory_file_count: u32 = 0;
var g_memory_file_cap: u32 = 0;
var g_memory_files_lock: thread.rvn_mutex_t = std.mem.zeroes(thread.rvn_mutex_t);
var g_memory_files_lock_ready: c_int = 0;

// A path in a canonical spelling: '/' only, no "." segment, ".." folded into
// the folder before it. "ui/themes/../fonts/a.ttf" -> "ui/fonts/a.ttf".
fn rvn_memory_path_normalize(path: [*c]const u8, out: [*c]u8, cap: usize) void {
    var length: usize = 0;
    var segment: [*c]const u8 = path;
    if (cap == 0) return;
    while (segment[0] != 0) {
        var end: [*c]const u8 = segment;
        var size: usize = undefined;
        while (end[0] != 0 and end[0] != '/' and end[0] != '\\') end += 1;
        size = @intCast(end - segment);
        if (size == 0 and segment == path) {
            // a leading separator is kept: an absolute path
            if (length + 1 < cap) {
                out[length] = '/';
                length += 1;
            }
        } else if (size == 1 and segment[0] == '.') {
            // nothing
        } else if (size == 2 and segment[0] == '.' and segment[1] == '.' and length > 0 and
            !(length >= 2 and out[length - 1] == '.' and out[length - 2] == '.' and (length == 2 or out[length - 3] == '/')))
        {
            // back to the previous separator
            while (length > 0 and out[length - 1] != '/') length -= 1;
            if (length > 0 and !(length == 1 and out[0] == '/')) length -= 1;
        } else if (size > 0) {
            if (length > 0 and out[length - 1] != '/' and length + 1 < cap) {
                out[length] = '/';
                length += 1;
            }
            if (length + size >= cap) size = cap - length - 1;
            _ = libc.memcpy(out + length, segment, size);
            length += size;
        }
        segment = if (end[0] != 0) end + 1 else end;
    }
    out[length] = 0;
}

fn rvn_memory_path_equal(a: [*c]const u8, b: [*c]const u8) c_int {
    var na: [1024]u8 = undefined;
    var nb: [1024]u8 = undefined;
    rvn_memory_path_normalize(a, &na, @sizeOf(@TypeOf(na)));
    rvn_memory_path_normalize(b, &nb, @sizeOf(@TypeOf(nb)));
    return @intFromBool(libc.strcmp(&na, &nb) == 0);
}

fn rvn_memory_files_lock() void {
    if (g_memory_files_lock_ready == 0) {
        thread.rvn_mutex_init(&g_memory_files_lock);
        g_memory_files_lock_ready = raven.R_TRUE;
    }
    thread.rvn_mutex_lock(&g_memory_files_lock);
}

fn rvn_memory_file_find(path: [*c]const u8) c_int {
    var i: u32 = 0;
    while (i < g_memory_file_count) : (i += 1) {
        if (rvn_memory_path_equal(g_memory_files[i].path, path) != 0) return @intCast(i);
    }
    return -1;
}

export fn rvn_memory_file_exists(path: [*c]const u8) c_int {
    if (path == null or g_memory_file_count == 0) return raven.R_FALSE;
    rvn_memory_files_lock();
    const found = rvn_memory_file_find(path) >= 0;
    thread.rvn_mutex_unlock(&g_memory_files_lock);
    return @intFromBool(found);
}

export fn Rfile_register_memory(path: [*c]const u8, data: ?*const anyopaque, size: usize, copy: c_int) c_int {
    if (ctx.rvn_api_check("Rfile_register_memory") == 0) return raven.R_FALSE;
    if (path == null or path[0] == 0 or (data == null and size != 0)) return raven.R_FALSE;
    rvn_memory_files_lock();
    const index = rvn_memory_file_find(path);
    var file: [*c]rvn_memory_file_t = undefined;
    if (index >= 0) {
        file = &g_memory_files[@intCast(index)];
        if (file.*.owned != 0) base.rvn_free(@constCast(file.*.data));
        base.rvn_free(file.*.path);
    } else {
        base.RVN_ARRAY_RESERVE(&g_memory_files, &g_memory_file_cap, g_memory_file_count + 1);
        file = &g_memory_files[g_memory_file_count];
        g_memory_file_count += 1;
    }
    file.*.path = base.rvn_strdup(path);
    file.*.size = size;
    file.*.owned = if (copy != 0) raven.R_TRUE else raven.R_FALSE;
    if (copy != 0) {
        const bytes: [*c]u8 = @ptrCast(@alignCast(base.rvn_alloc(size + 1)));
        if (size != 0) _ = libc.memcpy(bytes, data, size);
        bytes[size] = 0;
        file.*.data = bytes;
    } else {
        file.*.data = @ptrCast(data);
    }
    thread.rvn_mutex_unlock(&g_memory_files_lock);
    return raven.R_TRUE;
}

export fn Rfile_unregister_memory(path: [*c]const u8) void {
    if (path == null) return;
    rvn_memory_files_lock();
    const index = rvn_memory_file_find(path);
    if (index >= 0) {
        const file: [*c]rvn_memory_file_t = &g_memory_files[@intCast(index)];
        if (file.*.owned != 0) base.rvn_free(@constCast(file.*.data));
        base.rvn_free(file.*.path);
        g_memory_file_count -= 1;
        g_memory_files[@intCast(index)] = g_memory_files[g_memory_file_count];
    }
    thread.rvn_mutex_unlock(&g_memory_files_lock);
}

export fn rvn_memory_files_shutdown() void {
    var i: u32 = 0;
    if (g_memory_files_lock_ready == 0) return;
    while (i < g_memory_file_count) : (i += 1) {
        if (g_memory_files[i].owned != 0) base.rvn_free(@constCast(g_memory_files[i].data));
        base.rvn_free(g_memory_files[i].path);
    }
    base.rvn_free(g_memory_files);
    g_memory_files = null;
    g_memory_file_count = 0;
    g_memory_file_cap = 0;
    thread.rvn_mutex_destroy(&g_memory_files_lock);
    g_memory_files_lock_ready = raven.R_FALSE;
}

export fn Rfile_is_memory(path: [*c]const u8) c_int {
    return rvn_memory_file_exists(path);
}

export fn rvn_read_file(path: [*c]const u8, size: [*c]usize) [*c]u8 {
    var data: [*c]u8 = undefined;
    var read: usize = undefined;
    var length: c_long = undefined;

    if (size != null) size.* = 0;
    if (path == null) return null;
    if (g_memory_file_count != 0) {
        rvn_memory_files_lock();
        const index = rvn_memory_file_find(path);
        if (index >= 0) {
            const memory: [*c]rvn_memory_file_t = &g_memory_files[@intCast(index)];
            data = @ptrCast(@alignCast(base.rvn_alloc(memory.*.size + 1)));
            if (memory.*.size != 0) _ = libc.memcpy(data, memory.*.data, memory.*.size);
            data[memory.*.size] = '\x00';
            if (size != null) size.* = memory.*.size;
            thread.rvn_mutex_unlock(&g_memory_files_lock);
            return data;
        }
        thread.rvn_mutex_unlock(&g_memory_files_lock);
    }
    const file = rvn_fopen_read(path) orelse return null;
    // if (fseek(file, 0, SEEK_END) != 0 || (length = ftell(file)) < 0 || fseek(file, 0, SEEK_SET) != 0)
    var seek_ok = libc.fseek(file, 0, libc.SEEK_END) == 0;
    if (seek_ok) {
        length = libc.ftell(file);
        seek_ok = length >= 0;
    }
    if (seek_ok) seek_ok = libc.fseek(file, 0, libc.SEEK_SET) == 0;
    if (!seek_ok) {
        _ = libc.fclose(file);
        return null;
    }
    const length_bytes: usize = @intCast(length);
    data = @ptrCast(@alignCast(base.rvn_alloc(length_bytes + 1)));
    read = libc.fread(data, 1, length_bytes, file);
    _ = libc.fclose(file);
    if (read != length_bytes) {
        base.rvn_free(data);
        return null;
    }
    data[length_bytes] = '\x00';
    if (size != null) size.* = length_bytes;
    return data;
}
