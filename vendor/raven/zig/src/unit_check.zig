// Helper of zig/check_unit.sh (compile check of ONE translated file in isolation). Not part of the library.
const std = @import("std");

extern "c" fn abort() noreturn;

fn unitPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    _ = msg;
    _ = ret_addr;
    abort();
}

/// check_unit.sh puts this in its root file: `pub const panic = @import("unit_check.zig").panic;`
pub const panic = std.debug.FullPanic(unitPanic);

/// Forces semantic analysis of every pub declaration of module M: functions (their bodies),
/// types (their layout), constants, variables. Zig analyses lazily, so without this an unused function
/// or type would never be checked. Non-pub (static) functions are checked when something calls them.
/// check_unit.sh uses it as:   comptime { _ = &@import("unit_check.zig").RefAll(@import("x.zig")).run; }
pub fn RefAll(comptime M: type) type {
    return struct {
        pub fn run() void {
            @setEvalBranchQuota(1_000_000);
            inline for (@typeInfo(M).@"struct".decl_names) |name| {
                const T = @TypeOf(@field(M, name));
                if (T == type) {
                    const v = @field(M, name);
                    switch (@typeInfo(v)) {
                        .@"struct", .@"union" => _ = @sizeOf(v),
                        .@"enum" => |e| if (e.field_names.len > 0) {
                            _ = @sizeOf(v);
                        },
                        else => {},
                    }
                } else switch (@typeInfo(T)) {
                    .@"fn" => |f| if (!f.is_generic) {
                        _ = &@field(M, name);
                    },
                    else => _ = &@field(M, name),
                }
            }
        }
    };
}
