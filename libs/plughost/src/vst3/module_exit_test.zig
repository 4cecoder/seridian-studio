// Translated to Zig from soundcraft/crates/vst3-host/tests/module_exit.rs, soundcraft/crates/vst3-host/tests/module_exit_live_instance.rs, soundcraft/crates/vst3-host/tests/module_exit_shutdown.rs, soundcraft/crates/vst3-host/tests/module_exit_worker_thread.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Module exit ordering, checked through the fixture's event log (`test_fixture.zig`): the
//! entry and exit counts, the factory and object counts, the thread that ran the entry, and the
//! `violations` the fixture records when the host breaks the contract.
//!
//! The Rust tests are `harness = false` binaries whose process exit is the thing under test. The
//! in-process ports use private `module.Registry` values, so each test balances the fixture's
//! counters on its own and never shuts down the process-wide registry that the other tests load
//! through. The Zig test runner has no `--test-filter` to run one test in a child process, so the
//! child-process form is not expressible here; the shutdown ordering is checked in-process on a
//! private registry, and the late exit handler is skipped (see its test).

const std = @import("std");
const abi = @import("abi.zig");
const module = @import("module.zig");
const fixture = @import("test_fixture.zig");
const inst_mod = @import("instance.zig");

const testing = std.testing;

/// The bundle path the private registries adopt the fixture under.
const PATH = "module-exit/Fixture.vst3";

/// The fixture's counters must all be back at rest: nothing alive, no entries left, no breaks.
fn expectRest() !void {
    try testing.expectEqual(@as(i64, 0), fixture.entered.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), fixture.factories_alive.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), fixture.objects_alive.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), fixture.violations.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), fixture.contract_failures.load(.seq_cst));
}

test "module exit: a module with no instances exits once, with no violations" {
    fixture.reset();
    var reg = module.Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = true;

    const b = try fixture.adopt(&reg, PATH, .main);
    try testing.expectEqual(@as(i64, 1), fixture.entered.load(.seq_cst));
    try testing.expectEqual(@as(i64, 1), fixture.factories_alive.load(.seq_cst));

    // One instance, made and dropped before the exit (the Rust `drop(p)`).
    const inst = try inst_mod.Instance.create(testing.allocator, b, &fixture.GAIN_CID);
    inst.destroy();

    reg.exitModules();
    try expectRest();
    // The exits run once: a second shutdown does nothing.
    reg.exitModules();
    try expectRest();
}

test "module exit: a live instance keeps its module loaded" {
    fixture.reset();
    var reg = module.Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = true;

    const b = try fixture.adopt(&reg, PATH, .main);
    // Still alive at exit, like a plugin held by a mixer that is never torn down (the Rust
    // `std::mem::forget(p)`); it is released below so the counters balance again.
    const inst = try inst_mod.Instance.create(testing.allocator, b, &fixture.GAIN_CID);

    reg.exitModules();
    // The module was kept: no exit ran under the live object, and nothing was reported.
    try testing.expectEqual(@as(i64, 1), fixture.entered.load(.seq_cst));
    try testing.expect(fixture.objects_alive.load(.seq_cst) >= 1);
    try testing.expectEqual(@as(u32, 0), fixture.violations.load(.seq_cst));

    // Let go of the instance, then the factory, and run the exit by hand so the counters balance.
    inst.destroy();
    _ = abi.comRelease(b.factory);
    try testing.expect(fixture.moduleExit());
    try expectRest();
}

/// Shared state of the worker-thread test.
const WorkerResult = struct {
    reg: *module.Registry,
    /// OS thread that asked for the load (short-lived).
    worker_os: usize = 0,
    /// OS thread that ran the entry: the module thread.
    module_os: usize = 0,
    ok: bool = false,
    load_failed: bool = false,
};

fn enterOnModuleThread(ctx: *anyopaque) void {
    const r: *WorkerResult = @ptrCast(@alignCast(ctx));
    r.module_os = module.osThread();
    _ = fixture.adopt(r.reg, PATH, .modules) catch {
        r.load_failed = true;
        return;
    };
}

fn workerMain(r: *WorkerResult) void {
    r.worker_os = module.osThread();
    r.ok = r.reg.onModuleThread(r, enterOnModuleThread, null);
}

test "module exit: a module first loaded on a worker thread exits on the module thread" {
    fixture.reset();
    var reg = module.Registry.init(testing.allocator);
    defer reg.deinit();
    var result: WorkerResult = .{ .reg = &reg };

    // The worker asks for the module and is gone before the exit; the module thread outlives it.
    const worker = try std.Thread.spawn(.{}, workerMain, .{&result});
    worker.join();
    try testing.expect(result.ok);
    try testing.expect(!result.load_failed);
    try testing.expect(result.module_os != 0);
    try testing.expect(result.module_os != result.worker_os);
    // The fixture recorded the module thread as the entry thread.
    try testing.expectEqual(result.module_os, fixture.entry_thread.load(.seq_cst));
    try testing.expectEqual(@as(i64, 1), fixture.entered.load(.seq_cst));

    // The exit runs on the module thread, the same thread as the entry: no violation.
    reg.exitModules();
    try expectRest();
}

test "module exit: shutdown runs the module exit up front, and later loads are refused" {
    fixture.reset();
    var reg = module.Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = true;

    const b = try fixture.adopt(&reg, PATH, .main);
    // Makes and releases a plugin object, then shuts plugin hosting down (the Rust `shutdown()`,
    // which runs the exits before the process exit can tear state down).
    const inst = try inst_mod.Instance.create(testing.allocator, b, &fixture.GAIN_CID);
    inst.destroy();
    reg.exitModules();
    try expectRest();
    try testing.expect(reg.modules_exited.load(.acquire));
    // Loads fail after shutdown.
    try testing.expectError(error.ShutDown, reg.load("/nope.vst3"));
}

test "module exit: a shutdown with a live instance keeps that module until it is released" {
    fixture.reset();
    var reg = module.Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = true;

    const b = try fixture.adopt(&reg, PATH, .main);
    const inst = try inst_mod.Instance.create(testing.allocator, b, &fixture.GAIN_CID);
    // Shutdown with an instance alive: the module is kept, so its exit cannot run under it.
    reg.exitModules();
    try testing.expectEqual(@as(i64, 1), fixture.entered.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), fixture.violations.load(.seq_cst));
    inst.destroy();
    _ = abi.comRelease(b.factory);
    try testing.expect(fixture.moduleExit());
    try expectRest();
}

test "module exit: the exit handler alone comes too late (process exit state)" {
    // Rust: the `exit-handler` case runs only the module exit from the process exit handler,
    // after the fixture's late state (`VST3_FIXTURE_LATE_STATE`) was torn down, and the fixture
    // ends the process with status 3. The Zig fixture keeps no state that process exit tears
    // down and has no `atexit` check, so the ordering it would observe does not exist here.
    return error.SkipZigTest;
}
