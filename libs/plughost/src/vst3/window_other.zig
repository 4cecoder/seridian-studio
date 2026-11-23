// Translated to Zig from soundcraft/crates/vst3-host/src/ffi/window/other.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Stub editor window for platforms without VST3 editor hosting: `Window.new`
//! always fails with `error.Unsupported`.

const std = @import("std");
const builtin = @import("builtin");

/// The IPlugView platform type string; none on this platform.
pub const platform_type: ?[*:0]const u8 = null;

/// Whether the caller is the process's main thread. On Linux the main thread is the one whose
/// thread id equals the process id; elsewhere the stub cannot tell and assumes it is.
pub fn onMainThread() bool {
    if (builtin.os.tag == .linux) {
        return std.os.linux.gettid() == std.os.linux.getpid();
    }
    return true;
}

pub const Error = error{Unsupported};

pub const Window = struct {
    pub fn new(title: []const u8, w: f64, h: f64) Error!Window {
        _ = title;
        _ = w;
        _ = h;
        return error.Unsupported;
    }
    pub fn raw(self: *const Window) ?*anyopaque {
        _ = self;
        return null;
    }
    pub fn parent(self: *const Window) ?*anyopaque {
        _ = self;
        return null;
    }
    pub fn raise(self: *const Window) void {
        _ = self;
    }
    pub fn isVisible(self: *const Window) bool {
        _ = self;
        return false;
    }
    pub fn close(self: *Window) void {
        _ = self;
    }
};

pub fn resize(window: ?*anyopaque, w: f64, h: f64) void {
    _ = window;
    _ = w;
    _ = h;
}

// Not in the Rust source: the stub's documented behaviour.
test "window_other: new is unsupported" {
    try std.testing.expectError(error.Unsupported, Window.new("x", 100, 100));
    try std.testing.expect(platform_type == null);
    try std.testing.expect(onMainThread());
    resize(null, 1, 1);
}
