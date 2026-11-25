//! `seridian-studio` executable: starts libdaw-engine, then hands the engine
//! to the Raven window in libdaw-ui.

const std = @import("std");

const single_instance = @import("system/single_instance.zig");

const log = std.log.scoped(.main);

/// Escape hatch for developers and the e2e tests that deliberately run two apps.
const new_instance_flag = "--new-instance";
const socket_name = "seridian.sock";

const Runtime = opaque {};
const ProgressFn = *const fn (stage: c_int, detail: ?[*:0]const u8, user_data: ?*anyopaque) callconv(.c) void;
extern fn daw_runtime_create(progress: ?ProgressFn, user_data: ?*anyopaque) callconv(.c) ?*Runtime;
extern fn daw_runtime_engine(rt: *Runtime) callconv(.c) *anyopaque;
extern fn daw_runtime_destroy(rt: *Runtime) callconv(.c) void;
extern fn seridian_raven_run(engine: ?*anyopaque) callconv(.c) c_int;

pub const std_options: std.Options = .{
    .log_level = .info,
};

/// Applies the single-instance rule (src/system/single_instance.zig) to `$XDG_RUNTIME_DIR/seridian.sock`.
/// Returns true when this process must go on and start; false when another instance owns the socket.
fn claimInstance() bool {
    const dir_ptr = std.c.getenv("XDG_RUNTIME_DIR") orelse return true;
    const dir = std.mem.span(dir_ptr);
    var buffer: [107:0]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, socket_name }) catch return true;
    if (dir.len == 0 or text.len >= buffer.len) return true;
    buffer[text.len] = 0;
    const path: [:0]const u8 = buffer[0..text.len :0];

    const found = single_instance.probe(path);
    switch (single_instance.decide(found.state)) {
        .start => return true,
        .replace_stale => {
            if (!single_instance.removeStale(path)) log.warn("could not remove the stale socket {s}", .{path});
            return true;
        },
        .already_running => {
            // There is no raise command on the socket and the wm layer cannot focus a window, so this
            // only reports; the running window is left where it is.
            if (found.pid) |pid| {
                std.debug.print("Seridian Studio is already running (pid {d})\n", .{pid});
            } else {
                std.debug.print("Seridian Studio is already running (pid unknown)\n", .{});
            }
            return false;
        },
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var force_new = false;
    var args = init.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, new_instance_flag)) force_new = true;
    }
    if (!force_new and !claimInstance()) return;

    log.info("Starting Seridian Studio", .{});

    const rt = daw_runtime_create(null, null) orelse return error.EngineStartFailed;
    defer daw_runtime_destroy(rt);

    // Raven owns the window and event loop; the audio and MIDI engines remain Zig-owned.
    const status = seridian_raven_run(daw_runtime_engine(rt));
    log.info("Application exited with status: {d}", .{status});
    if (status != 0) return error.UiFailed;
}
