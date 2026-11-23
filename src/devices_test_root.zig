//! Module root for the `test-devices` step's libc-linked tests.
//!
//! Zig only lets a module import files beneath its root file's directory.
//! devices_c_api.zig reaches src/utils/sys.zig through devices.zig, so the
//! module root sits in src/.

comptime {
    _ = @import("audio/devices_c_api.zig");
}
