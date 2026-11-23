//! DAW build graph, split by volatility:
//!
//!   libdaw-engine.so  Zig: audio engine, DSP, instruments, effects, MIDI,
//!                     project/config. Exposes only a C ABI (src/engine_lib.zig).
//!   libdaw-ui.so      Zig: the Seridian Studio window (src/ui/zig/ui_lib.zig)
//!                     over the vendored Raven toolkit. Calls the engine
//!                     through its C ABI. No C is compiled for it.
//!   seridian-studio   Thin launcher (src/main.zig): start the engine, run Raven.
//!
//! The executable finds both libraries through RUNPATH ($ORIGIN/../lib), so
//! `zig build` output and installed trees work without LD_LIBRARY_PATH.

const std = @import("std");

const c_flags = [_][]const u8{
    "-std=c11",
    "-D_GNU_SOURCE",
    "-Wall",
    "-Wextra",
};

const Ctx = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    is_macos: bool,
    headless: bool,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;

    const simd = b.option(bool, "simd", "Enable SIMD optimizations") orelse true;
    const default_backend: []const u8 = if (is_macos) "coreaudio" else "auto";
    const backend = b.option([]const u8, "backend", "Audio backend (auto/coreaudio/pulse/pipewire)") orelse default_backend;
    const headless = b.option(bool, "headless", "Headless build: Raven null platform, no X11, binary seridian-studio-headless") orelse false;
    const version = b.option([]const u8, "version", "Version string") orelse "0.1.0";

    const options = b.addOptions();
    options.addOption(bool, "simd", simd);
    options.addOption([]const u8, "backend", backend);
    options.addOption([]const u8, "version", version);

    const ctx: Ctx = .{ .b = b, .target = target, .optimize = optimize, .options = options, .is_macos = is_macos, .headless = headless };

    const engine = addEngineLib(ctx);
    const ui = addUiLib(ctx, engine, addRavenBuild(ctx));
    const exe = addExe(ctx, engine, ui);
    b.installArtifact(engine);
    b.installArtifact(ui);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the DAW").dependOn(&run_cmd.step);

    // Unit tests: everything below the UI, no display or audio server needed.
    const test_mod = engineModule(ctx, "src/test_main.zig");
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests (engine plus every library)");
    test_step.dependOn(&run_tests.step);

    addLibs(ctx, test_step);
    addSnippets(ctx, test_step);

    // `seridian` CLI: no audio or Raven dependencies, so it builds fast and runs
    // headless. Scripts and AI tools drive the app through it.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli_root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const cli = b.addExecutable(.{ .name = "seridian", .root_module = cli_mod });
    b.installArtifact(cli);
    const cli_tests = b.addTest(.{ .root_module = cli_mod });
    b.step("test-cli", "Run seridian CLI tests").dependOn(&b.addRunArtifact(cli_tests).step);

    // Liquid-glass UI kit demo window (src/uikit/demo.zig). Needs Raven and a display.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/uikit/demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_mod.addLibraryPath(.{ .cwd_relative = ravenBuildDir(ctx) });
    demo_mod.linkSystemLibrary("raven", .{});
    linkRavenPlatform(ctx, demo_mod);
    const demo = b.addExecutable(.{ .name = "uikit-demo", .root_module = demo_mod });
    demo.step.dependOn(addRavenBuild(ctx));
    const demo_install = b.addInstallArtifact(demo, .{});
    b.step("uikit-demo", "Build the UI kit demo window").dependOn(&demo_install.step);

    // Pure pactl list parser: no libc, no sound server, runs on any host.
    const device_parse_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audio/device_parse.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const devices_step = b.step("test-devices", "Run audio device list parser and C API tests");
    devices_step.dependOn(&b.addRunArtifact(device_parse_tests).step);

    // The C API bridge hands names to C as C strings, so it links libc (sys.zig).
    const devices_c_api_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/devices_test_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    devices_step.dependOn(&b.addRunArtifact(devices_c_api_tests).step);

    // Tests for the pure UI helpers (palette, UI math, knob, piano, state, input), no display needed.
    // tests/ui/all.zig runs them against `ui_impl`, the Zig helpers (src/ui/zig/helpers.zig), whose own test
    // block also runs the in-file tests of the pure widget logic (knob, piano, keymap, fader, meter, waveform).
    const test_ui_step = b.step("test-ui", "Run Raven UI tests (pure helpers, no display)");
    const ui_impl = b.createModule(.{
        .root_source_file = b.path("src/ui/zig/helpers.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ui_impl.addImport("raven", ravenApiModule(ctx));
    const ui_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/ui/all.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ui_tests_mod.addImport("ui_impl", ui_impl);
    test_ui_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ui_tests_mod })).step);
    test_ui_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ui_impl })).step);
    test_step.dependOn(test_ui_step);

    const fmt_step = b.step("fmt", "Check formatting (zig fmt)");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ b.path("src"), b.path("libs"), b.path("build.zig") }, .check = true }).step);
}

/// A library under libs/<name>/. `deps` lists the lower-layer libraries it
/// may import by name; docs/design/architecture.md defines the layering.
/// Importing anything not listed here fails to compile, which is the layer
/// check: to allow a new dependency, edit this table (and justify it).
const Lib = struct {
    name: []const u8,
    /// Architecture layer, 0 (most stable) to 4, for the build log and docs.
    layer: u8,
    deps: []const []const u8,
    /// Links the platform audio/MIDI frameworks (CoreAudio, CoreMIDI, ...).
    platform: bool = false,
};

const libs = [_]Lib{
    .{ .name = "core", .layer = 0, .deps = &.{} },
    .{ .name = "analysis", .layer = 2, .deps = &.{"core"} },
    .{ .name = "vocal", .layer = 2, .deps = &.{} },
    .{ .name = "io", .layer = 3, .deps = &.{ "core", "analysis" }, .platform = true },
    .{ .name = "plughost", .layer = 3, .deps = &.{ "core", "analysis" }, .platform = true },
    .{ .name = "graph", .layer = 3, .deps = &.{ "core", "analysis", "io" } },
    .{ .name = "sequencer", .layer = 3, .deps = &.{ "core", "analysis", "io" } },
    .{ .name = "automation", .layer = 3, .deps = &.{ "core", "analysis", "io" } },
    .{ .name = "session", .layer = 4, .deps = &.{ "core", "analysis", "io", "plughost", "graph", "sequencer", "automation" }, .platform = true },
    .{ .name = "mcp", .layer = 4, .deps = &.{ "core", "analysis", "io", "plughost", "graph", "sequencer", "automation" } },
};

const max_libs = libs.len;

/// Create each library as a named Zig module and register:
///   zig build test-<name>   that library's tests (src/root.zig and tests/all.zig)
///   zig build test          also runs all of them
fn addLibs(ctx: Ctx, test_step: *std.Build.Step) void {
    const b = ctx.b;
    var mods: [max_libs]*std.Build.Module = undefined;

    for (libs, 0..) |lib, i| {
        const root = b.fmt("libs/{s}/src/root.zig", .{lib.name});
        mods[i] = libModule(ctx, lib, root);
    }
    // Wire imports after all modules exist, so table order does not matter.
    for (libs, 0..) |lib, i| {
        for (lib.deps) |dep| mods[i].addImport(dep, mods[libIndex(dep)]);
    }

    for (libs, 0..) |lib, i| {
        const lib_step = b.step(b.fmt("test-{s}", .{lib.name}), b.fmt("Run tests of library {s} (layer L{d})", .{ lib.name, lib.layer }));

        // In-file tests: everything reachable from src/root.zig.
        const inline_tests = b.addTest(.{ .root_module = mods[i] });
        lib_step.dependOn(&b.addRunArtifact(inline_tests).step);

        // External tests: libs/<name>/tests/all.zig imports the library and
        // its allowed dependencies by name, exactly as a consumer would.
        const ext_mod = libModule(ctx, lib, b.fmt("libs/{s}/tests/all.zig", .{lib.name}));
        ext_mod.addImport(lib.name, mods[i]);
        for (lib.deps) |dep| ext_mod.addImport(dep, mods[libIndex(dep)]);
        const ext_tests = b.addTest(.{ .root_module = ext_mod });
        lib_step.dependOn(&b.addRunArtifact(ext_tests).step);

        test_step.dependOn(lib_step);
    }
}

/// libs/snippets/*.zig are the compiled examples that libs/RUST_TO_ZIG.md
/// quotes. Running them keeps the guide true as the toolchain moves.
fn addSnippets(ctx: Ctx, test_step: *std.Build.Step) void {
    const b = ctx.b;
    const step = b.step("test-snippets", "Compile and run the RUST_TO_ZIG.md examples");
    for ([_][]const u8{
        "types_and_control_flow",
        "numerics_and_data",
        "c_interop_and_systems",
        "misc_std",
        "rt_safety",
        "header_example",
    }) |name| {
        const mod = ctx.b.createModule(.{
            .root_source_file = b.path(b.fmt("libs/snippets/{s}.zig", .{name})),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
        });
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    }
    test_step.dependOn(step);
}

fn libIndex(name: []const u8) usize {
    for (libs, 0..) |lib, i| {
        if (std.mem.eql(u8, lib.name, name)) return i;
    }
    @panic("unknown library in dependency table");
}

fn libModule(ctx: Ctx, lib: Lib, root: []const u8) *std.Build.Module {
    const mod = ctx.b.createModule(.{
        .root_source_file = ctx.b.path(root),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    mod.addImport("build_options", ctx.options.createModule());
    if (lib.platform) linkPlatformAudio(ctx, mod);
    return mod;
}

/// A Zig module over the engine sources with the platform audio libraries.
fn engineModule(ctx: Ctx, root: []const u8) *std.Build.Module {
    const mod = ctx.b.createModule(.{
        .root_source_file = ctx.b.path(root),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    mod.addImport("build_options", ctx.options.createModule());
    linkPlatformAudio(ctx, mod);
    // Libraries the engine consumes (see the layering table above).
    const vocal = libs[libIndex("vocal")];
    mod.addImport("vocal", libModule(ctx, vocal, "libs/vocal/src/root.zig"));
    return mod;
}

fn linkPlatformAudio(ctx: Ctx, mod: *std.Build.Module) void {
    if (ctx.is_macos) {
        for ([_][]const u8{ "AudioToolbox", "CoreAudio", "CoreFoundation", "AudioUnit", "CoreMIDI" }) |fw| {
            mod.linkFramework(fw, .{});
        }
    } else {
        mod.linkSystemLibrary("pulse", .{});
        mod.linkSystemLibrary("pulse-simple", .{});
        mod.linkSystemLibrary("pipewire-0.3", .{});
        mod.linkSystemLibrary("asound", .{});
    }
}

fn addEngineLib(ctx: Ctx) *std.Build.Step.Compile {
    const mod = engineModule(ctx, "src/engine_lib.zig");
    // Shared libraries resolve each other beside themselves.
    mod.addRPathSpecial(originPath(ctx, ""));
    return ctx.b.addLibrary(.{
        .name = "daw-engine",
        .linkage = .dynamic,
        .root_module = mod,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
}

/// Raven is a CMake-built native UI dependency. Keep its build output inside
/// the ignored vendor tree so `zig build` stays self-contained.
fn addRavenBuild(ctx: Ctx) *std.Build.Step {
    const b = ctx.b;
    // The headless build uses its own CMake tree so it never clobbers the GUI build's cache.
    const build_dir: []const u8 = if (ctx.headless) "vendor/raven/_build_headless" else "vendor/raven/_build";
    const platform: []const u8 = if (ctx.headless) "-DRAVEN_PLATFORM=null" else "-DRAVEN_PLATFORM=auto";
    const configure = b.addSystemCommand(&.{
        "cmake",                      "-S",                                   "vendor/raven",               "-B",                                                    build_dir,                  "-G",                         "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        // libraven.a is linked into the libdaw-ui shared library.
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", platform,                     "-DRAVEN_BACKEND_VULKAN=ON",                             "-DRAVEN_BUILD_SHARED=OFF", "-DRAVEN_BUILD_EXAMPLES=OFF", "-DRAVEN_BUILD_TESTS=OFF",
        "-DRAVEN_BUILD_TOOLS=OFF",    "-DRAVEN_BUILD_WEB=OFF",                "-DRAVEN_WITH_STB_IMAGE=OFF",
        // Raven's translated sources (vendor/raven/zig/ported.txt) are built with the zig that runs this build.
        b.fmt("-DRAVEN_ZIG_EXECUTABLE={s}", .{b.graph.zig_exe}),
    });
    const build_raven = b.addSystemCommand(&.{
        "cmake", "--build", build_dir, "--target", "raven", "--parallel",
    });
    build_raven.step.dependOn(&configure.step);
    return &build_raven.step;
}

fn addUiLib(ctx: Ctx, engine: *std.Build.Step.Compile, raven_build: *std.Build.Step) *std.Build.Step.Compile {
    const b = ctx.b;
    // The window is Zig (src/ui/zig/ui_lib.zig); Raven's public C API comes from its translated declarations.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/ui/zig/ui_lib.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    mod.addImport("raven", ravenApiModule(ctx));
    const ui_options = b.addOptions();
    ui_options.addOption(bool, "headless", ctx.headless);
    mod.addImport("ui_options", ui_options.createModule());
    // Zig widgets, exported with the C ABI (seridian_knob_create, ...).
    const knob_lib = b.addLibrary(.{
        .name = "daw-ui-knob",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/zig/knob.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
        }),
    });
    mod.linkLibrary(knob_lib);
    const piano_roll_lib = b.addLibrary(.{
        .name = "daw-ui-piano-roll",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/zig/piano_roll.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
        }),
    });
    mod.linkLibrary(piano_roll_lib);
    // Window keymap table (one table, Ctrl on Linux, Super on macOS), exported as seridian_keymap_lookup.
    const keymap_lib = b.addLibrary(.{
        .name = "daw-ui-keymap",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ui/zig/keymap.zig"),
            .target = ctx.target,
            .optimize = ctx.optimize,
            .link_libc = true,
        }),
    });
    mod.linkLibrary(keymap_lib);
    // libraven.a is linked by file, not through a library search path: a search path
    // would be recorded as a relative RUNPATH entry in the shared library.
    mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libraven.a", .{ravenBuildDir(ctx)}) });
    linkRavenPlatform(ctx, mod);
    linkShared(mod, engine);
    mod.addRPathSpecial(originPath(ctx, ""));
    const lib = b.addLibrary(.{
        .name = if (ctx.headless) "daw-ui-headless" else "daw-ui",
        .linkage = .dynamic,
        .root_module = mod,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    });
    lib.step.dependOn(raven_build);
    return lib;
}

/// Raven's public API (vendor/raven/include/raven/*.h) as Zig declarations, generated and layout-checked by
/// vendor/raven/zig. Import it as `@import("raven")`.
fn ravenApiModule(ctx: Ctx) *std.Build.Module {
    return ctx.b.createModule(.{
        .root_source_file = ctx.b.path("vendor/raven/zig/src/raven/raven.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
    });
}

fn addExe(ctx: Ctx, engine: *std.Build.Step.Compile, ui: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const b = ctx.b;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    linkShared(mod, ui);
    linkShared(mod, engine);
    // Installed: bin/seridian-studio + lib/libdaw-*.so
    mod.addRPathSpecial(originPath(ctx, "/../lib"));
    return b.addExecutable(.{
        .name = if (ctx.headless) "seridian-studio-headless" else "seridian-studio",
        .root_module = mod,
        // macOS: use the system linker (ld64) for native framework linking.
        .use_lld = if (ctx.is_macos) false else null,
    });
}

/// Link a shared library built here by path. `linkLibrary` would also add
/// its build-cache directory to RUNPATH, a cwd-relative path that must never
/// ship; the binaries find each other through $ORIGIN instead.
fn linkShared(mod: *std.Build.Module, lib: *std.Build.Step.Compile) void {
    mod.addObjectFile(lib.getEmittedBin());
}

fn ravenBuildDir(ctx: Ctx) []const u8 {
    return if (ctx.headless) "vendor/raven/_build_headless" else "vendor/raven/_build";
}

fn linkRavenPlatform(ctx: Ctx, mod: *std.Build.Module) void {
    if (ctx.headless) {
        // Null platform: no window system, so no X11.
        for ([_][]const u8{ "pthread", "m", "dl" }) |lib| {
            mod.linkSystemLibrary(lib, .{});
        }
    } else if (ctx.is_macos) {
        for ([_][]const u8{ "AppKit", "QuartzCore", "Metal" }) |fw| {
            mod.linkFramework(fw, .{});
        }
    } else {
        // Raven's Linux renderer opens an X11 window. On Wayland, it runs
        // through XWayland, avoiding a GTK or compositor-specific dependency.
        for ([_][]const u8{ "X11", "pthread", "m", "dl" }) |lib| {
            mod.linkSystemLibrary(lib, .{});
        }
    }
}

/// RUNPATH relative to the binary: `$ORIGIN` on ELF, `@loader_path` on Mach-O.
fn originPath(ctx: Ctx, comptime suffix: []const u8) []const u8 {
    return if (ctx.is_macos) "@loader_path" ++ suffix else "$ORIGIN" ++ suffix;
}
