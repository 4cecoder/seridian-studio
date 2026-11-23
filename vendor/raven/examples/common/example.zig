// Translated to Zig from vendor/raven/examples/common/example.h (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven examples - helpers shared by the examples (not part of the library).
//
//   example_init          starts Raven and prints its errors to stderr
//   example_automated     scripted runs of the examples (see below)
//
// For automated runs, two environment variables make an example render a
// fixed number of frames, optionally save the last one, and exit:
//
//   RAVEN_EXAMPLE_FRAMES=30 RAVEN_EXAMPLE_CAPTURE=shot.ppm ./raven_editor
//
// RAVEN_EXAMPLE_FILM=prefix also saves one frame out of six as prefix000.ppm,
// prefix001.ppm..., with the animations advancing by 1/60 s per frame.
//
// Zig: this file is the module `example` of each example program (examples/CMakeLists.txt), which
// also gets the module `example_config` (generated: example_dir, the RAVEN_EXAMPLE_DIR of the C
// build, and ndebug). Each example is one object exporting main, linked with Raven by the C linker.

const std = @import("std");
const builtin = @import("builtin");
const raven = @import("raven");
const config = @import("example_config");

// ---- the C library functions the examples call (no @cImport in Zig 0.18) ----
pub const FILE = opaque {};
pub extern "c" fn printf(format: [*:0]const u8, ...) c_int;
pub extern "c" fn fprintf(file: ?*FILE, format: [*:0]const u8, ...) c_int;
pub extern "c" fn snprintf(buffer: [*c]u8, size: usize, format: [*:0]const u8, ...) c_int;
pub extern "c" fn fopen(path: [*c]const u8, mode: [*c]const u8) ?*FILE;
pub extern "c" fn fclose(file: ?*FILE) c_int;
pub extern "c" fn fwrite(data: ?*const anyopaque, size: usize, count: usize, file: ?*FILE) usize;
pub extern "c" fn fread(data: ?*anyopaque, size: usize, count: usize, file: ?*FILE) usize;
pub extern "c" fn strlen(text: [*c]const u8) usize;
pub extern "c" fn strcmp(a: [*c]const u8, b: [*c]const u8) c_int;
pub extern "c" fn strncmp(a: [*c]const u8, b: [*c]const u8, n: usize) c_int;
pub extern "c" fn strstr(haystack: [*c]const u8, needle: [*c]const u8) [*c]u8;
pub extern "c" fn strchr(text: [*c]const u8, ch: c_int) [*c]u8;
pub extern "c" fn strrchr(text: [*c]const u8, ch: c_int) [*c]u8;
pub extern "c" fn getenv(name: [*c]const u8) [*c]u8;
pub extern "c" fn atoi(text: [*c]const u8) c_int;
pub extern "c" fn malloc(size: usize) ?*anyopaque;
pub extern "c" fn calloc(count: usize, size: usize) ?*anyopaque;
pub extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?*anyopaque;
pub extern "c" fn free(ptr: ?*anyopaque) void;

/// The C `stderr` (a variable of the C library, named differently by each one).
extern "c" var stderr: ?*FILE;
extern "c" var __stderrp: ?*FILE;
pub fn c_stderr() ?*FILE {
    return if (builtin.os.tag == .macos) __stderrp else stderr;
}

/// RAVEN_EXAMPLE_DIR: where the example finds its data files when started from any folder.
pub const RAVEN_EXAMPLE_DIR: [:0]const u8 = config.example_dir;

fn example_on_error(code: raven.RError, severity: raven.RSeverity, detail: [*c]const u8) callconv(.c) void {
    _ = fprintf(c_stderr(), "[Raven] %s (%s): %s\n", raven.Rerror_to_string(code), raven.Rseverity_to_string(severity), detail);
}

/// Starts Raven with the Vulkan backend. Returns R_FALSE on failure.
pub fn example_init(name: [*c]const u8) c_int {
    var desc: raven.RInitDesc = std.mem.zeroes(raven.RInitDesc);
    desc.backend = raven.R_BACKEND_VULKAN;
    desc.app_name = name;
    if (!config.ndebug) {
        desc.enable_validation = raven.R_TRUE;
    }
    raven.Rerror_set_callback(example_on_error);
    if (raven.Rinit_ex(&desc) == 0) {
        _ = fprintf(c_stderr(), "%s: cannot start Raven (is a Vulkan driver installed?)\n", name);
        return raven.R_FALSE;
    }
    return raven.R_TRUE;
}

/// Saves a window as a binary PPM image; as a PAM image, which keeps the alpha of a window that is seen through, when the name ends with ".pam".
pub fn example_capture(window: raven.Rid, path: [*c]const u8) void {
    var width: c_int = 0;
    var height: c_int = 0;
    var i: c_int = undefined;
    const pixels: [*c]u8 = raven.Rwindow_capture(window, &width, &height);
    const file: ?*FILE = if (pixels != null) fopen(path, "wb") else null;
    const length: usize = strlen(path);
    if (file != null and length > 4 and strcmp(path + length - 4, ".pam") == 0) {
        _ = fprintf(file, "P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", width, height);
        _ = fwrite(pixels, 4, @as(usize, @intCast(width)) * @as(usize, @intCast(height)), file);
        _ = fclose(file);
    } else if (file != null) {
        _ = fprintf(file, "P6\n%d %d\n255\n", width, height);
        i = 0;
        while (i < width * height) : (i += 1) _ = fwrite(pixels + @as(usize, @intCast(i * 4)), 1, 3, file);
        _ = fclose(file);
    }
    raven.Rpixels_free(pixels);
}

/// Automated runs (RAVEN_EXAMPLE_FRAMES): renders a fixed number of frames,
/// optionally saves the last one, and returns R_TRUE: the example then skips
/// its loop. Returns R_FALSE when the example should run normally.
pub fn example_automated(window: raven.Rid) c_int {
    const frames: [*c]const u8 = getenv("RAVEN_EXAMPLE_FRAMES");
    const capture: [*c]const u8 = getenv("RAVEN_EXAMPLE_CAPTURE");
    const film: [*c]const u8 = getenv("RAVEN_EXAMPLE_FILM");
    var count: c_int = undefined;
    var i: c_int = undefined;
    if (frames == null) return raven.R_FALSE;
    count = atoi(frames);
    // a film: the animations advance by 1/60 s per frame whatever the time it takes to render one
    if (film != null) raven.Rset_animation_time_step(1.0 / 60.0);
    i = 0;
    while (i < count and raven.Ris_running() != 0) : (i += 1) {
        raven.Rwindow_request_redraw(window);
        _ = raven.Rwait_frame(0.01);
        if (film != null and @rem(i, 6) == 0 and raven.Rwindow_is_valid(window) != 0) {
            var path: [512]u8 = undefined;
            _ = snprintf(&path, path.len, "%s%03d.ppm", film, @divTrunc(i, 6));
            example_capture(window, &path);
        }
    }
    if (capture != null and raven.Rwindow_is_valid(window) != 0) example_capture(window, capture);
    if (raven.Rwindow_is_valid(window) != 0) {
        var stats: raven.RFrameStats = undefined;
        raven.Rwindow_get_frame_stats(window, &stats);
        _ = printf("last frame: %u widgets, %u primitives, %u draw calls, %u backdrop captures, paint %.2f ms, render %.2f ms\n", //
            stats.widget_count, stats.instance_count, stats.draw_call_count, stats.backdrop_count, stats.paint_ms, stats.render_ms);
    }
    return raven.R_TRUE;
}

/// The panic handler of the example programs: a trap in the safe build prints its message and aborts
/// (the standard handler would drag the stack trace machinery into an object linked by the C compiler).
/// Each example's root file has `pub const panic = example.panic;`.
extern "c" fn abort() noreturn;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
fn examplePanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = ret_addr;
    const prefix = "Raven example (Zig) panic: ";
    _ = write(2, prefix.ptr, prefix.len);
    _ = write(2, msg.ptr, msg.len);
    _ = write(2, "\n", 1);
    abort();
}
pub const panic = std.debug.FullPanic(examplePanic);
