//! System detection and configuration module
//!
//! Provides platform-agnostic system detection for:
//! - Operating system and architecture
//! - Available audio backends
//! - Available MIDI backends
//! - Hardware capabilities (CPU, GPU)
//!
//! Usage:
//!   const system = @import("system/system.zig");
//!   const caps = system.detect();
//!   caps.log_info();

pub const detect = @import("detect.zig");

// C API exports for settings modal
comptime {
    _ = @import("system_c_api.zig");
}

pub const OS = detect.OS;
pub const AudioBackend = detect.AudioBackend;
pub const MIDIBackend = detect.MIDIBackend;
pub const SystemCapabilities = detect.SystemCapabilities;

/// Detect system capabilities at runtime
pub fn detectSystem() SystemCapabilities {
    return detect.detect();
}

/// Get the current operating system
pub fn currentOS() OS {
    return OS.current();
}

/// Check if running on macOS
pub fn isMacOS() bool {
    return currentOS() == .macos;
}

/// Check if running on Linux
pub fn isLinux() bool {
    return currentOS() == .linux;
}

/// Check if running on Windows
pub fn isWindows() bool {
    return currentOS() == .windows;
}
