// Translated to Zig from soundcraft/crates/clap-host/src/ffi/hostwin/other.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The host window that carries an embedded CLAP editor, for platforms where
//! Seridian does not host embedded editors: a stub with `SUPPORTED = false`.
//!
//! `gui.zig` checks `SUPPORTED` before it asks for an embedded editor, so on these
//! platforms `HostWindow.new` is never reached and every method below is dead code
//! kept so the call sites compile. The Windows implementation (`windows.rs` in the
//! Rust crate) is not translated; on Windows this stub is still what gets compiled.
//!
//! Window calls are main-thread only. Nothing here locks or allocates.

const std = @import("std");
const testing = std.testing;

/// Whether this platform hosts embedded editors in a host window of ours.
pub const SUPPORTED = false;

/// Why a host window could not be made.
pub const HostWindowError = error{
    /// This platform does not host embedded editors.
    EmbeddedNotSupported,
};

/// A host window for an embedded editor. On this platform no value of this type is
/// ever made: `new` always fails.
pub const HostWindow = struct {
    /// Creates a window of `w` by `h` points titled `title`. Always fails here.
    pub fn new(title: []const u8, w: f64, h: f64) HostWindowError!HostWindow {
        _ = title;
        _ = w;
        _ = h;
        return error.EmbeddedNotSupported;
    }

    /// The native window handle, for the plugin to attach to. Null here.
    pub fn raw(self: *const HostWindow) ?*anyopaque {
        _ = self;
        return null;
    }

    /// The native parent view or window handle. Null here.
    pub fn parent(self: *const HostWindow) ?*anyopaque {
        _ = self;
        return null;
    }

    /// Brings the window to the front. No-op here.
    pub fn raise(self: *const HostWindow) void {
        _ = self;
    }

    /// Whether the window is still on screen. Always false here.
    pub fn isVisible(self: *const HostWindow) bool {
        _ = self;
        return false;
    }

    /// Closes and releases the window. No-op here.
    pub fn close(self: HostWindow) void {
        _ = self;
    }
};

/// Resizes the window behind a raw handle. No-op here.
pub fn resize(window: ?*anyopaque, w: f64, h: f64) void {
    _ = window;
    _ = w;
    _ = h;
}

// ---- tests ------------------------------------------------------------------------------------

test "HostWindow: the stub is unsupported and refuses to make a window" {
    try testing.expect(!SUPPORTED);
    try testing.expectError(error.EmbeddedNotSupported, HostWindow.new("Synth", 640, 480));
}

test "HostWindow: the stub's handles are null and it is never visible" {
    const w: HostWindow = .{};
    try testing.expect(w.raw() == null);
    try testing.expect(w.parent() == null);
    try testing.expect(!w.isVisible());
    w.raise();
    w.close();
}

test "HostWindow: resize on any handle, including null, does nothing" {
    resize(null, 640, 480);
    var sentinel: u8 = 0;
    resize(&sentinel, 1, 1);
    try testing.expectEqual(@as(u8, 0), sentinel);
}
