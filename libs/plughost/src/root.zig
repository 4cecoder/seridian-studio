//! plughost (layer L3): Plugin hosting (CLAP first, then VST3/AU) and sandbox process. Depends on core and analysis.
//! Re-exports every file of the library; see README.md.

const std = @import("std");

pub const lib_name = "plughost";

// --- file re-exports: add one line per file, keep alphabetical ---

pub const au = @import("au/au.zig");
pub const au_abi = @import("au/abi.zig");
pub const au_instance = @import("au/instance.zig");
pub const au_plugin = @import("au/plugin.zig");
pub const au_registry = @import("au/registry.zig");
pub const au_system_units_test = @import("au/system_units_test.zig");
// CLAP hosting: the namespace file of clap/ (see clap/clap.zig).
pub const clap = @import("clap/clap.zig");
pub const clap_fixture_e2e_test = @import("clap/fixture_e2e_test.zig");
pub const event = @import("event.zig");
pub const params = @import("params.zig");
pub const plugin = @import("plugin.zig");
// VST3 hosting: the namespace file of vst3/ (see vst3/vst3.zig).
pub const vst3 = @import("vst3/vst3.zig");
pub const vst3_fixture_e2e_test = @import("vst3/fixture_e2e_test.zig");
pub const vst3_module_exit_test = @import("vst3/module_exit_test.zig");

test {
    std.testing.refAllDecls(@This());
}

test "library identifies itself" {
    try std.testing.expectEqualStrings("plughost", lib_name);
}
