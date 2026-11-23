//! `seridian-studio` executable: starts libdaw-engine, then hands the engine
//! to the Raven window in libdaw-ui.

const std = @import("std");

const log = std.log.scoped(.main);

const Runtime = opaque {};
const ProgressFn = *const fn (stage: c_int, detail: ?[*:0]const u8, user_data: ?*anyopaque) callconv(.c) void;
extern fn daw_runtime_create(progress: ?ProgressFn, user_data: ?*anyopaque) callconv(.c) ?*Runtime;
extern fn daw_runtime_engine(rt: *Runtime) callconv(.c) *anyopaque;
extern fn daw_runtime_destroy(rt: *Runtime) callconv(.c) void;
extern fn seridian_raven_run(engine: ?*anyopaque) callconv(.c) c_int;

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    log.info("Starting Seridian Studio", .{});

    const rt = daw_runtime_create(null, null) orelse return error.EngineStartFailed;
    defer daw_runtime_destroy(rt);

    // Raven owns the window and event loop; the audio and MIDI engines remain Zig-owned.
    const status = seridian_raven_run(daw_runtime_engine(rt));
    log.info("Application exited with status: {d}", .{status});
    if (status != 0) return error.UiFailed;
}
