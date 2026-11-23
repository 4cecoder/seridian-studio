// Translated to Zig from vendor/raven/src/core/error.c (Raven, Apache-2.0). Modified by Seridian: C11 → Zig translation.
//
// Raven - core/error.c
// Last-error record and error callback. Usable before Rinit and from any thread.

const std = @import("std");
const raven = @import("raven");
const thread = @import("thread_h.zig");
const libc = @import("../sys/libc.zig");

const RVN_ERROR_TEXT_SIZE = 512;

var g_error_lock: thread.rvn_atomic_t = std.mem.zeroes(thread.rvn_atomic_t);
var g_error_code: raven.RError = raven.R_NO_ERROR;
var g_error_severity: raven.RSeverity = raven.R_SEVERITY_WEAK_WARNING;
var g_error_detail: [RVN_ERROR_TEXT_SIZE]u8 = std.mem.zeroes([RVN_ERROR_TEXT_SIZE]u8);
var g_error_returned: [RVN_ERROR_TEXT_SIZE]u8 = std.mem.zeroes([RVN_ERROR_TEXT_SIZE]u8);
var g_error_callback: raven.RErrorCallback = null;

// A spin lock: errors are rare and this must work with no initialization.
fn rvn_error_lock() void {
    while (thread.rvn_atomic_exchange(&g_error_lock, 1) != 0) {}
}

fn rvn_error_unlock() void {
    thread.rvn_atomic_store(&g_error_lock, 0);
}

export fn rvn_error(code: raven.RError, severity: raven.RSeverity, format: [*c]const u8, ...) callconv(.c) void {
    var text: [RVN_ERROR_TEXT_SIZE]u8 = undefined;
    var callback: raven.RErrorCallback = undefined;
    var args = @cVaStart();

    _ = libc.vsnprintf(&text, RVN_ERROR_TEXT_SIZE, format, &args);
    @cVaEnd(&args);

    rvn_error_lock();
    g_error_code = code;
    g_error_severity = severity;
    @memcpy(&g_error_detail, &text);
    callback = g_error_callback;
    rvn_error_unlock();

    if (callback) |f| f(code, severity, &text);
}

export fn Rerror_get_last(detail: [*c][*c]const u8, severity: [*c]raven.RSeverity) raven.RError {
    var code: raven.RError = undefined;
    rvn_error_lock();
    code = g_error_code;
    if (severity != null) severity.* = g_error_severity;
    @memcpy(&g_error_returned, &g_error_detail);
    g_error_code = raven.R_NO_ERROR;
    g_error_detail[0] = 0;
    rvn_error_unlock();
    if (detail != null) detail.* = &g_error_returned;
    return code;
}

export fn Rerror_set_callback(callback: raven.RErrorCallback) void {
    rvn_error_lock();
    g_error_callback = callback;
    rvn_error_unlock();
}

export fn Rerror_to_string(error_: raven.RError) [*c]const u8 {
    switch (error_) {
        raven.R_NO_ERROR => return "R_NO_ERROR",
        raven.R_ERROR_INVALID_ID => return "R_ERROR_INVALID_ID",
        raven.R_ERROR_INVALID_ENUM => return "R_ERROR_INVALID_ENUM",
        raven.R_ERROR_INVALID_VALUE => return "R_ERROR_INVALID_VALUE",
        raven.R_ERROR_INVALID_OPERATION => return "R_ERROR_INVALID_OPERATION",
        raven.R_ERROR_BACKEND => return "R_ERROR_BACKEND",
        raven.R_ERROR_PLATFORM => return "R_ERROR_PLATFORM",
        raven.R_ERROR_OUT_OF_MEMORY => return "R_ERROR_OUT_OF_MEMORY",
        raven.R_ERROR_INVALID_FILE_FORMAT => return "R_ERROR_INVALID_FILE_FORMAT",
        raven.R_ERROR_FILE_NOT_FOUND => return "R_ERROR_FILE_NOT_FOUND",
        raven.R_ERROR_XML => return "R_ERROR_XML",
        raven.R_ERROR_WRONG_THREAD => return "R_ERROR_WRONG_THREAD",
        else => {},
    }
    return "RVN_ERROR_UNKNOWN";
}

export fn Rseverity_to_string(severity: raven.RSeverity) [*c]const u8 {
    switch (severity) {
        raven.R_SEVERITY_WEAK_WARNING => return "R_SEVERITY_WEAK_WARNING",
        raven.R_SEVERITY_WARNING => return "R_SEVERITY_WARNING",
        raven.R_SEVERITY_ERROR => return "R_SEVERITY_ERROR",
        raven.R_SEVERITY_FATAL => return "R_SEVERITY_FATAL",
        else => {},
    }
    return "RVN_SEVERITY_UNKNOWN";
}
