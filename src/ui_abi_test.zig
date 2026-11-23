//! The UI library declares the engine's C ABI structs by hand (it links libdaw-engine, it does not import its
//! source). These tests compare those mirrors with the engine's own definitions, so a layout change on either side
//! fails `zig build test` instead of corrupting memory at run time.

const std = @import("std");
const engine_types = @import("system/preflight_types.zig");
const ui_report = @import("ui/zig/preflight_report.zig");

fn expectSameLayout(comptime A: type, comptime B: type) !void {
    try std.testing.expectEqual(@sizeOf(A), @sizeOf(B));
    try std.testing.expectEqual(@alignOf(A), @alignOf(B));
    const a_fields = @typeInfo(A).@"struct".field_names;
    const b_fields = @typeInfo(B).@"struct".field_names;
    try std.testing.expectEqual(a_fields.len, b_fields.len);
    inline for (a_fields, b_fields) |a_name, b_name| {
        try std.testing.expectEqualStrings(a_name, b_name);
        try std.testing.expectEqual(@offsetOf(A, a_name), @offsetOf(B, b_name));
        try std.testing.expectEqual(@sizeOf(@FieldType(A, a_name)), @sizeOf(@FieldType(B, b_name)));
    }
}

test "UI preflight report mirrors the engine's C layout" {
    try expectSameLayout(engine_types.CCheck, ui_report.CCheck);
    try expectSameLayout(engine_types.CReport, ui_report.CReport);
    try expectSameLayout(engine_types.CEngineSnapshot, ui_report.CEngineSnapshot);
    try std.testing.expectEqual(engine_types.max_checks, ui_report.max_checks);
    try std.testing.expectEqual(engine_types.status_ok, ui_report.status_ok);
    try std.testing.expectEqual(engine_types.status_info, ui_report.status_info);
    try std.testing.expectEqual(engine_types.status_warn, ui_report.status_warn);
    try std.testing.expectEqual(engine_types.status_fail, ui_report.status_fail);
}

test "UI window class is the class the doctor's desktop rules match" {
    const desktop = @import("system/desktop.zig");
    const identity = @import("ui/zig/app_identity.zig");
    try std.testing.expectEqualStrings(desktop.app_wm_class, identity.window_class);
}
