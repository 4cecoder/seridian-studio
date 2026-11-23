// Translated to Zig from soundcraft/crates/vst3-host/tests/it/fixture_e2e.rs, soundcraft/crates/vst3-host/tests/common/mod.rs, soundcraft/crates/vst3-host/tests/editor_main_thread.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! End to end through the public `vst3.zig` API against the Zig VST3 fixture (`test_fixture.zig`,
//! the port of the Rust test plugin in `tests/fixture`): scan, plugin info, instantiate, process
//! with sample-offset events and parameter changes in both directions, latency and tail, state
//! save / load / refusal, state readers on another thread, layouts, the editor (probe, edits,
//! main-thread enforcement), NaN output, junk files, and the rule that `process` never allocates.
//!
//! The fixture is registered once per test binary as the in-process bundle `FIXTURE_PATH` (no
//! file is loaded, which is what `common/mod.rs` builds with cargo). Each test resets the
//! fixture's switches and counters. No test calls `vst3.shutdownPluginHosts`: that ends the
//! process-wide registry for the whole binary, so the module exit tests are in
//! `module_exit_test.zig` (private registries, and a child process for the global shutdown).
//!
//! Translation notes:
//! * Rust `Plugin::param("7")` by VST3 ParamID becomes a dense index through `plug.indexOfId`;
//!   an id that is not exposed (hidden, bypass, a title) has no index, so the setter is `false`.
//! * Rust `note_on` / `note_off` / `midi` calls become `plug.Event`s in the sorted slice given to
//!   `process`. Rust `all_notes_off` has no separate entry here; `Vst3Plugin.reset` releases the
//!   held keys, which is what the Rust `reset` tests relied on.
//! * Rust `frames` is the numSamples of the call; here it is the shortest channel of the block.
//! * The Rust editor main-thread test is a `harness = false` binary that runs on the process main
//!   thread. The Zig test runner may not, so the main-thread expectations are branched on the
//!   thread the test actually runs on, and the off-main-thread refusals are always checked.

const std = @import("std");
const builtin = @import("builtin");
const plug = @import("../plugin.zig");
const vst3 = @import("vst3.zig");
const fixture = @import("test_fixture.zig");
const registry = @import("registry.zig");
const module = @import("module.zig");
const plugin_mod = @import("plugin.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Vst3Plugin = plugin_mod.Vst3Plugin;
const AudioBlock = plug.AudioBlock;
const Event = plug.Event;
const Descriptor = vst3.Descriptor;

/// The bundle path the fixture is registered under (never loaded from disk).
pub const FIXTURE_PATH = "fixture/Fixture.vst3";

/// Frames per block in the Rust tests that use the default host block size.
const BLOCK: usize = 256;

/// Sample rate of the Rust tests.
const SR_44K: f32 = 44_100.0;
const SR_48K: f32 = 48_000.0;

/// The Rust fixture's `Gain` latency (`LATENCY` in test_fixture.zig).
const GAIN_LATENCY: usize = fixture.LATENCY;

/// Whether the fixture has been registered in this process (the registry takes one reference).
var registered: bool = false;

/// Registers the fixture once as an in-process bundle. Safe to call from every test.
fn ensureFixture() !void {
    if (registered) return;
    var token: u8 = 0;
    if (!fixture.moduleEntry(&token)) return error.EntryFailed;
    const factory = fixture.getPluginFactory() orelse return error.OutOfMemory;
    try vst3.registerFactory(FIXTURE_PATH, factory, fixture.moduleExit);
    registered = true;
}

/// Starts a test: fixture registered, switches and counters cleared.
fn begin() !void {
    try ensureFixture();
    fixture.reset();
}

/// The `vst3:` id of a fixture class, found through the scan (caller frees).
fn idOf(name: []const u8) ![]u8 {
    const all = try vst3.scanAll(testing.allocator);
    defer Descriptor.freeList(testing.allocator, all);
    for (all) |d| {
        if (std.mem.eql(u8, d.path, FIXTURE_PATH) and std.mem.eql(u8, d.name, name)) {
            return testing.allocator.dupe(u8, d.id);
        }
    }
    return error.FixtureNotScanned;
}

/// Dense index of a parameter by its VST3 ParamID string. The id must be exposed.
fn indexOf(p: *const Vst3Plugin, id: []const u8) u32 {
    return plug.indexOfId(p.info, id) orelse std.debug.panic("parameter {s} is not exposed", .{id});
}

/// `setParam` by ParamID: `false` when the id is not exposed (hidden, bypass, a title).
fn setById(p: *Vst3Plugin, id: []const u8, value: f32) bool {
    const i = plug.indexOfId(p.info, id) orelse return false;
    return p.setParam(i, value);
}

/// `getParam` by ParamID: `null` when the id is not exposed.
fn getById(p: *const Vst3Plugin, id: []const u8) ?f32 {
    const i = plug.indexOfId(p.info, id) orelse return null;
    return p.getParam(i);
}

fn noteOn(offset: u32, note: u8, velocity: u8) Event {
    return .{ .offset = offset, .kind = .{ .note_on = .{ .note = note, .velocity = velocity } } };
}

fn noteOff(offset: u32, note: u8) Event {
    return .{ .offset = offset, .kind = .{ .note_off = note } };
}

fn midi(offset: u32, bytes: [3]u8) Event {
    return .{ .offset = offset, .kind = .{ .midi3 = bytes } };
}

fn paramEvent(offset: u32, index: u32, value: f32) Event {
    return .{ .offset = offset, .kind = .{ .param = .{ .index = index, .value = value } } };
}

/// Creates a plugin of the fixture class `name` (caller frees with `vst3.destroyPlugin`).
fn make(name: []const u8) !*Vst3Plugin {
    const id = try idOf(name);
    defer testing.allocator.free(id);
    return vst3.instantiate(testing.allocator, id);
}

/// Whether the calling thread is the process main thread (see the module docs).
fn onMainThread() bool {
    if (builtin.os.tag.isDarwin()) return pthreadMainNp() == 1;
    if (builtin.os.tag == .linux) return std.os.linux.gettid() == std.os.linux.getpid();
    return false;
}

extern "c" fn pthread_main_np() c_int;

fn pthreadMainNp() c_int {
    return pthread_main_np();
}

/// Whether this platform hosts VST3 editor windows (macOS and Windows, as in the Rust tests).
fn editorsHosted() bool {
    return builtin.os.tag == .macos or builtin.os.tag == .windows;
}

// ---- scan and info ---------------------------------------------------------------------------

test "fixture e2e: scan lists both audio modules but not the controller class" {
    try begin();
    const all = try vst3.scanAll(testing.allocator);
    defer Descriptor.freeList(testing.allocator, all);

    var n: usize = 0;
    var gain: ?*const Descriptor = null;
    var synth: ?*const Descriptor = null;
    for (all) |*d| {
        if (!std.mem.eql(u8, d.path, FIXTURE_PATH)) continue;
        n += 1;
        if (std.mem.eql(u8, d.name, "Fixture Gain")) gain = d;
        if (std.mem.eql(u8, d.name, "Fixture Synth")) synth = d;
    }
    // Five audio modules; the edit controller class of the gain is not listed.
    try testing.expectEqual(@as(usize, 5), n);

    const g = gain orelse return error.TestUnexpectedResult;
    // `uid()` lays out the first 8 bytes differently on Windows (COM GUID order).
    const want: []const u8 = if (builtin.os.tag == .windows) "vst3:001D0A5C111122223333444455556666" else "vst3:5C0A1D00111122223333444455556666";
    try testing.expectEqualStrings(want, g.id);
    // The factory vendor fills an empty class vendor.
    try testing.expectEqualStrings("SoundCraft tests", g.vendor);
    try testing.expectEqualStrings("1.2.3", g.version);
    try testing.expectEqualStrings("VST 3.8.0", g.sdk_version);
    try testing.expectEqual(@as(usize, 1), g.sub_categories.len);
    try testing.expectEqualStrings("Fx", g.sub_categories[0]);
    try testing.expectEqual(plug.Category.other, g.category);
    try testing.expect(!g.is_instrument);
    try testing.expect(std.mem.endsWith(u8, g.path, "Fixture.vst3"));

    const s = synth orelse return error.TestUnexpectedResult;
    try testing.expectEqual(plug.Category.instrument, s.category);
    try testing.expect(s.is_instrument);

    // The global scan holds the same descriptors as the fixture's own folder.
    var seen_gain = false;
    var seen_synth = false;
    for (all) |d| {
        if (std.mem.eql(u8, d.id, g.id)) seen_gain = true;
        if (std.mem.eql(u8, d.id, s.id)) seen_synth = true;
    }
    try testing.expect(seen_gain and seen_synth);
}

test "fixture e2e: info exposes visible params with plain ranges" {
    try begin();
    const gain = try idOf("Fixture Gain");
    defer testing.allocator.free(gain);
    const info = vst3.pluginInfo(gain) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(gain, info.id);
    try testing.expectEqualStrings("Fixture ", info.short_name);

    // Hidden 9 and bypass 11 are skipped; the order is the controller's.
    const want_ids = [_][]const u8{ "7", "3", "12", "13", "14" };
    try testing.expectEqual(want_ids.len, info.params.len);
    for (want_ids, info.params) |want, p| try testing.expectEqualStrings(want, p.id);

    const g = info.params[plug.indexOfId(info, "7").?];
    try testing.expectEqualStrings("Gain", g.name);
    try testing.expectEqual(@as(f32, 0.0), g.min);
    try testing.expectEqual(@as(f32, 2.0), g.max);
    try testing.expectEqual(@as(f32, 1.0), g.default);
    try testing.expectEqual(plug.Unit.db, g.unit);
    try testing.expectEqual(plug.Taper.linear, g.taper);

    const mode = info.params[plug.indexOfId(info, "3").?];
    try testing.expectEqual(plug.Unit.choice, mode.unit);
    try testing.expectEqual(@as(f32, 0.0), mode.min);
    try testing.expectEqual(@as(f32, 2.0), mode.max);
    const want_choices = [_][]const u8{ "A", "B", "C" };
    try testing.expectEqual(want_choices.len, mode.choices.len);
    for (want_choices, mode.choices) |want, got| try testing.expectEqualStrings(want, got);

    const f = info.params[plug.indexOfId(info, "12").?];
    try testing.expectEqual(plug.Unit.hz, f.unit);
    try testing.expectEqual(plug.Taper.log, f.taper);
    try testing.expect(@abs(f.min - 20.0) < 1e-3 and @abs(f.max - 20_000.0) < 1e-1);

    // Cached: the same info every time.
    try testing.expect(info == vst3.pluginInfo(gain).?);
}

test "fixture e2e: identity-mapped param text is read on the main thread only" {
    try begin();
    const id = try idOf("Fixture Gain");
    defer testing.allocator.free(id);
    const info = vst3.pluginInfo(id) orelse return error.TestUnexpectedResult;
    const level = info.params[plug.indexOfId(info, "13").?];
    try testing.expectEqual(@as(f32, 0.0), level.min);
    try testing.expectEqual(@as(f32, 1.0), level.max);
    try testing.expectEqual(plug.Unit.db, level.unit);

    const p = try vst3.instantiate(testing.allocator, id);
    defer vst3.destroyPlugin(p);
    const ed = p.editor() orelse return error.TestUnexpectedResult;
    defer plugin_mod.releaseEditor(ed);
    const text = try ed.valueText(testing.allocator, indexOf(p, "13"), 0.375);
    defer if (text) |t| testing.allocator.free(t);
    if (onMainThread()) {
        try testing.expectEqualStrings("\u{2212}6.0 dB", text orelse return error.TestUnexpectedResult);
    } else {
        // Test threads are not the main thread: the plugin's own text is not read here.
        try testing.expectEqual(@as(?[]u8, null), text);
    }
}

// ---- processing ------------------------------------------------------------------------------

test "fixture e2e: gain processes audio and follows params" {
    try begin();
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    p.prepare(SR_44K, BLOCK, 2);
    try testing.expectEqual(GAIN_LATENCY, p.latencySamples());
    // The controller was synced from the component state (gain 0.5), not the declared default.
    try testing.expectEqual(@as(?f32, 0.5), getById(p, "7"));

    var l: [BLOCK]f32 = @splat(0.5);
    var r: [BLOCK]f32 = @splat(-0.25);
    var bufs = [_][]f32{ &l, &r };
    p.process(AudioBlock.fromSlices(&bufs), &.{});
    for (l) |x| try testing.expectApproxEqAbs(@as(f32, 0.25), x, 1e-6);

    try testing.expect(setById(p, "7", 2.0));
    try testing.expect(!setById(p, "9", 1.0)); // hidden params are not exposed
    try testing.expect(!setById(p, "Gain", 1.0)); // ids are VST3 ParamIDs
    try testing.expect(setById(p, "7", 5.0)); // clamped
    try testing.expectEqual(@as(?f32, 2.0), getById(p, "7"));
    try testing.expect(setById(p, "12", 2000.0));
    try testing.expectApproxEqAbs(@as(f32, 2000.0), getById(p, "12").?, 1e-2);
    try testing.expect(setById(p, "3", 1.6));
    try testing.expectEqual(@as(?f32, 2.0), getById(p, "3")); // choices round

    // A block larger than the prepared block is chunked.
    var l2: [700]f32 = @splat(0.5);
    var r2: [700]f32 = @splat(-0.25);
    var bufs2 = [_][]f32{ &l2, &r2 };
    p.process(AudioBlock.fromSlices(&bufs2), &.{});
    for (l2) |x| try testing.expectApproxEqAbs(@as(f32, 1.0), x, 1e-6);
    for (r2) |x| try testing.expectApproxEqAbs(@as(f32, -0.5), x, 1e-6);

    // Mono strip: the plugin accepts a mono arrangement and the session value is re-sent.
    p.prepare(SR_48K, 128, 1);
    var mono: [128]f32 = @splat(0.25);
    var mono_bufs = [_][]f32{&mono};
    p.process(AudioBlock.fromSlices(&mono_bufs), &.{});
    for (mono) |x| try testing.expectApproxEqAbs(@as(f32, 0.5), x, 1e-6);

    // Hostile shapes do not crash: no channels, and a block shorter than its declared length.
    p.process(AudioBlock.fromSlices(&.{}), &.{});
    var short: [4]f32 = @splat(1.0);
    var short_bufs = [_][]f32{&short};
    p.process(AudioBlock.fromSlices(&short_bufs), &.{});

    // NaN becomes the default.
    try testing.expect(setById(p, "7", std.math.nan(f32)));
    try testing.expectEqual(@as(?f32, 1.0), getById(p, "7"));
    p.reset();
    p.prepare(std.math.nan(f32), 0, 0);
    var eight: [8]f32 = @splat(0.1);
    var eight_bufs = [_][]f32{&eight};
    p.process(AudioBlock.fromSlices(&eight_bufs), &.{});
}

test "fixture e2e: latency and tail are reported through the plugin" {
    try begin();
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    p.prepare(SR_48K, BLOCK, 2);
    try testing.expectEqual(GAIN_LATENCY, p.latencySamples());
    try testing.expectEqual(@as(usize, 0), p.tailSamples());
    // Preparing again (a re-activation) reports the same latency.
    p.prepare(SR_44K, 64, 2);
    try testing.expectEqual(GAIN_LATENCY, p.latencySamples());
}

test "fixture e2e: synth plays notes at their offsets" {
    try begin();
    const p = try make("Fixture Synth");
    defer vst3.destroyPlugin(p);
    try testing.expect(p.info.is_instrument);
    try testing.expectEqual(@as(usize, 0), p.info.params.len);
    p.prepare(SR_48K, 64, 2);

    var l: [64]f32 = @splat(9.0);
    var r: [64]f32 = @splat(9.0);
    var bufs = [_][]f32{ &l, &r };
    {
        const ev = [_]Event{ noteOn(10, 60, 127), noteOff(40, 60) };
        p.process(AudioBlock.fromSlices(&bufs), &ev);
        for (l, 0..) |x, i| {
            const want: f32 = if (i >= 10 and i < 40) 1.0 else 0.0;
            try testing.expect(@abs(x - want) < 1e-6);
        }
        try testing.expectEqualSlices(f32, &l, &r);
    }

    // Offsets past the block are clamped into it; a reset releases held notes.
    {
        var l2: [64]f32 = @splat(0.0);
        var r2: [64]f32 = @splat(0.0);
        var b2 = [_][]f32{ &l2, &r2 };
        const ev = [_]Event{noteOn(1000, 61, 64)};
        p.process(AudioBlock.fromSlices(&b2), &ev);
        try testing.expect(@abs(l2[62]) < 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 64.0 / 127.0), l2[63], 1e-6);
        // Host forgets the held key: `reset` schedules its release for the next block.
        p.reset();
        p.process(AudioBlock.fromSlices(&b2), &.{});
        for (l2) |x| try testing.expect(@abs(x) < 1e-6);
    }

    // MIDI CC 7 reaches the parameter the plugin maps it to, and poly pressure arrives as an event,
    // each at its offset; an unmapped controller is dropped.
    {
        var l3: [64]f32 = @splat(0.0);
        var r3: [64]f32 = @splat(0.0);
        var b3 = [_][]f32{ &l3, &r3 };
        const ev = [_]Event{
            midi(10, .{ 0xA0, 60, 32 }),
            midi(20, .{ 0xB0, 7, 64 }),
            midi(30, .{ 0xB0, 1, 127 }),
        };
        p.process(AudioBlock.fromSlices(&b3), &ev);
        try testing.expect(@abs(l3[9]) < 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 32.0 / 127.0), l3[10], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 64.0 / 127.0), l3[20], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 64.0 / 127.0), l3[63], 1e-6);
    }
    {
        const ev = [_]Event{midi(0, .{ 0xB0, 7, 0 })};
        p.process(AudioBlock.fromSlices(&bufs), &ev);
    }

    // Notes in a later sub-block of a chunked call land at the right frame.
    p.prepare(SR_48K, 32, 2);
    var l4: [96]f32 = @splat(0.0);
    var r4: [96]f32 = @splat(0.0);
    var b4 = [_][]f32{ &l4, &r4 };
    const ev4 = [_]Event{noteOn(50, 62, 127)};
    p.process(AudioBlock.fromSlices(&b4), &ev4);
    try testing.expect(@abs(l4[49]) < 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l4[50], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l4[95], 1e-6);

    // A mono strip downmixes the stereo output; the note is still held.
    p.prepare(SR_48K, 64, 1);
    var mono: [64]f32 = @splat(0.0);
    var mono_bufs = [_][]f32{&mono};
    p.process(AudioBlock.fromSlices(&mono_bufs), &.{});
    for (mono) |x| try testing.expectApproxEqAbs(@as(f32, 1.0), x, 1e-6);
}

test "fixture e2e: reset after all notes off still releases held voices" {
    try begin();
    const p = try make("Fixture Synth");
    defer vst3.destroyPlugin(p);
    p.prepare(SR_48K, 64, 2);

    var l: [64]f32 = @splat(0.0);
    var r: [64]f32 = @splat(0.0);
    var bufs = [_][]f32{ &l, &r };
    const on = [_]Event{noteOn(0, 60, 127)};
    p.process(AudioBlock.fromSlices(&bufs), &on);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l[63], 1e-6);

    // Mixer::reset calls stop and then reset on an instrument (stop / seek).
    p.reset();
    @memset(&l, 9.0);
    @memset(&r, 9.0);
    p.process(AudioBlock.fromSlices(&bufs), &.{});
    for (l) |x| try testing.expect(@abs(x) < 1e-6);

    // A reset alone also releases what the host still holds.
    const on2 = [_]Event{noteOn(0, 61, 127)};
    p.process(AudioBlock.fromSlices(&bufs), &on2);
    try testing.expectApproxEqAbs(@as(f32, 1.0), l[63], 1e-6);
    p.reset();
    p.process(AudioBlock.fromSlices(&bufs), &.{});
    for (l) |x| try testing.expect(@abs(x) < 1e-6);
}

test "fixture e2e: many instances create and drop cleanly" {
    try begin();
    const g = try idOf("Fixture Gain");
    defer testing.allocator.free(g);
    const s = try idOf("Fixture Synth");
    defer testing.allocator.free(s);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const a = try vst3.instantiate(testing.allocator, g);
        const b = try vst3.instantiate(testing.allocator, s);
        var l: [32]f32 = @splat(0.0);
        var r: [32]f32 = @splat(0.0);
        var bufs = [_][]f32{ &l, &r };
        a.process(AudioBlock.fromSlices(&bufs), &.{});
        vst3.destroyPlugin(b);
        vst3.destroyPlugin(a);
    }
    try testing.expectEqual(@as(u32, 0), fixture.violations.load(.seq_cst));
}

// Smoke test against whatever real VST3 plugins are installed (none are required): scan, then
// instantiate, prepare and process each one briefly. Opt in with `SOUNDCRAFT_VST3_SMOKE=1`.
test "fixture e2e: installed plugins smoke (opt-in)" {
    if (std.c.getenv("SOUNDCRAFT_VST3_SMOKE") == null) return;
    const all = try vst3.scanAll(testing.allocator);
    defer Descriptor.freeList(testing.allocator, all);
    for (all) |d| {
        const p = vst3.create(testing.allocator, d.id) orelse continue;
        defer vst3.destroyPlugin(p);
        p.prepare(SR_48K, 512, 2);
        var l: [512]f32 = @splat(0.1);
        var r: [512]f32 = @splat(0.1);
        var bufs = [_][]f32{ &l, &r };
        p.process(AudioBlock.fromSlices(&bufs), &.{});
    }
}

test "fixture e2e: processing with sample-offset events and parameter changes in both directions" {
    try begin();
    fixture.emit_param_output.store(true, .monotonic);
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    const ed = p.editor() orelse return error.TestUnexpectedResult;
    defer plugin_mod.releaseEditor(ed);
    p.prepare(SR_48K, BLOCK, 2);

    // Plugin to host: the plugin writes its own gain (normalized 0.25 = plain 0.5) into its
    // output parameter queue; the editor's idle hands it to the UI as a plain value.
    var l: [64]f32 = @splat(0.5);
    var r: [64]f32 = @splat(0.5);
    var bufs = [_][]f32{ &l, &r };
    p.process(AudioBlock.fromSlices(&bufs), &.{});
    const own = try ed.idle(testing.allocator);
    defer testing.allocator.free(own);
    // The first idle also carries the controller's setup edit (1.8), so look for the plugin's own.
    var found_own = false;
    for (own) |e| {
        if (e.index == indexOf(p, "7") and @abs(e.value - 0.5) < 1e-4) found_own = true;
    }
    try testing.expect(found_own);

    // Host to plugin: a parameter event at offset 10 reaches the plugin's input queue at that
    // offset with the normalized value, and it changes the output from that frame on.
    fixture.emit_param_output.store(false, .monotonic);
    const ev = [_]Event{paramEvent(10, indexOf(p, "7"), 2.0)};
    var l2: [64]f32 = @splat(0.5);
    var r2: [64]f32 = @splat(0.5);
    var bufs2 = [_][]f32{ &l2, &r2 };
    const points_before = fixture.param_points_seen.load(.monotonic);
    p.process(AudioBlock.fromSlices(&bufs2), &ev);
    try testing.expectEqual(points_before + 1, fixture.param_points_seen.load(.monotonic));
    try testing.expectEqual(@as(u32, 7), fixture.last_param_id.load(.monotonic));
    try testing.expectEqual(@as(i32, 10), fixture.last_param_offset.load(.monotonic));
    try testing.expectApproxEqAbs(@as(f64, 1.0), @as(f64, @bitCast(fixture.last_param_value_bits.load(.monotonic))), 1e-9);
    // The fixture reads the last point of its parameter queue and applies it to the whole block
    // (no ramp), so the new gain (plain 2.0, factor 2.0) holds from frame 0: 0.5 * 2.0 = 1.0. The
    // event's offset is what reached the plugin, checked above through `last_param_offset`.
    for (l2) |x| try testing.expectApproxEqAbs(@as(f32, 1.0), x, 1e-6);
}

test "fixture e2e: edits from the editor reach the next block" {
    try begin();
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    const ed = p.editor() orelse return error.TestUnexpectedResult;
    defer plugin_mod.releaseEditor(ed);
    p.prepare(SR_48K, BLOCK, 2);

    // The fixture "edits" Gain to 0.9 (normalized) when it gets the component handler.
    const first = try ed.idle(testing.allocator);
    defer testing.allocator.free(first);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqual(indexOf(p, "7"), first[0].index);
    try testing.expectApproxEqAbs(@as(f32, 1.8), first[0].value, 1e-4);
    const again = try ed.idle(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(usize, 0), again.len);

    // The edit was forwarded to the audio side: the next block runs at gain 1.8.
    var l: [64]f32 = @splat(0.5);
    var r: [64]f32 = @splat(0.5);
    var bufs = [_][]f32{ &l, &r };
    p.process(AudioBlock.fromSlices(&bufs), &.{});
    try testing.expectApproxEqAbs(@as(f32, 0.9), l[63], 1e-4);

    // Host to editor: set_param is not reported back as an edit.
    ed.setParam(indexOf(p, "7"), 1.5);
    const after = try ed.idle(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqual(@as(usize, 0), after.len);
}

// ---- state -----------------------------------------------------------------------------------

test "fixture e2e: state saves component and controller and restores them" {
    try begin();
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    p.prepare(SR_48K, 64, 2);
    try testing.expect(setById(p, "7", 1.5));
    var l: [64]f32 = @splat(0.5);
    var r: [64]f32 = @splat(0.5);
    var bufs = [_][]f32{ &l, &r };
    p.process(AudioBlock.fromSlices(&bufs), &.{});
    const blob = (try p.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(blob);
    try testing.expect(std.mem.startsWith(u8, blob, "SCV3"));

    const q = try make("Fixture Gain");
    defer vst3.destroyPlugin(q);
    q.prepare(SR_48K, 64, 2);
    try testing.expectEqual(@as(?f32, 0.5), getById(q, "7"));
    try testing.expect(q.loadState(blob));
    try testing.expectEqual(@as(?f32, 1.5), getById(q, "7")); // controller synced from the component
    var l2: [64]f32 = @splat(0.5);
    var r2: [64]f32 = @splat(0.5);
    var bufs2 = [_][]f32{ &l2, &r2 };
    q.process(AudioBlock.fromSlices(&bufs2), &.{});
    for (l2) |x| try testing.expectApproxEqAbs(@as(f32, 0.75), x, 1e-6);

    // The controller part (Freq) round-trips too: write one by hand.
    var custom: [4 + 4 + 8 + 4 + 8]u8 = undefined;
    @memcpy(custom[0..4], "SCV3");
    std.mem.writeInt(u32, custom[4..8], 8, .little);
    std.mem.writeInt(u64, custom[8..16], @bitCast(@as(f64, 0.25)), .little);
    std.mem.writeInt(u32, custom[16..20], 8, .little);
    std.mem.writeInt(u64, custom[20..28], @bitCast(@as(f64, 1.0)), .little);
    try testing.expect(q.loadState(&custom));
    try testing.expectEqual(@as(?f32, 0.5), getById(q, "7"));
    try testing.expectApproxEqAbs(@as(f32, 20_000.0), getById(q, "12").?, 1.0);

    // A bare component state is accepted; hostile blobs are refused.
    var bare: [8]u8 = undefined;
    std.mem.writeInt(u64, &bare, @bitCast(@as(f64, 0.5)), .little);
    try testing.expect(q.loadState(&bare));
    try testing.expectEqual(@as(?f32, 1.0), getById(q, "7"));
    var ff8: [8]u8 = @splat(0xff);
    const bad_blobs = [_][]const u8{
        "",
        "SCV3",
        "SCV3\xff\xff\xff\xff",
        &ff8,
        "abc",
    };
    for (bad_blobs) |bad| try testing.expect(!q.loadState(bad));
    try testing.expectEqual(@as(?f32, 1.0), getById(q, "7"));
}

test "fixture e2e: a state the component refuses keeps the previous state" {
    try begin();
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    p.prepare(SR_48K, 64, 2);
    try testing.expect(setById(p, "7", 0.8));
    const blob = (try p.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(blob);

    try testing.expect(setById(p, "7", 1.2));
    fixture.refuse_state.store(true, .monotonic);
    defer fixture.refuse_state.store(false, .monotonic);
    try testing.expect(!p.loadState(blob));
    try testing.expectEqual(@as(?f32, 1.2), getById(p, "7"));
    try testing.expect(fixture.state_refusals.load(.monotonic) >= 1);
}

test "fixture e2e: state reader reads while another thread processes" {
    try begin();
    const p = try make("Fixture Gain");
    p.prepare(SR_48K, 64, 2);
    try testing.expect(setById(p, "7", 1.5));
    var warm_l: [64]f32 = @splat(0.5);
    var warm_r: [64]f32 = @splat(0.5);
    var warm = [_][]f32{ &warm_l, &warm_r };
    p.process(AudioBlock.fromSlices(&warm), &.{});

    const reader = p.stateReader();
    defer plugin_mod.releaseStateReader(reader);
    const blob = (try p.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(blob);

    const Audio = struct {
        fn run(plugin: *Vst3Plugin, done: *std.atomic.Value(bool)) void {
            var l: [64]f32 = @splat(0.5);
            var r: [64]f32 = @splat(0.5);
            var bufs = [_][]f32{ &l, &r };
            var i: usize = 0;
            while (i < 2_000) : (i += 1) plugin.process(AudioBlock.fromSlices(&bufs), &.{});
            done.store(true, .release);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const audio = try std.Thread.spawn(.{}, Audio.run, .{ p, &done });
    while (!done.load(.acquire)) {
        const got = (try reader.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, blob, got);
    }
    audio.join();

    const after = (try reader.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, blob, after);

    // Once the plugin is gone, the reader reports no state.
    vst3.destroyPlugin(p);
    const gone = try reader.saveState(testing.allocator);
    try testing.expectEqual(@as(?[]u8, null), gone);
}

test "fixture e2e: host set controller param survives state round trip" {
    try begin();
    // Freq lives only in the controller (the processor ignores it), so processing never carries
    // the host's value there: the state save has to.
    const p = try make("Fixture Gain");
    p.prepare(SR_48K, 64, 2);
    try testing.expect(setById(p, "7", 1.5));
    try testing.expect(setById(p, "12", 200.0));

    const Audio = struct {
        fn run(plugin: *Vst3Plugin) void {
            var l: [64]f32 = @splat(0.5);
            var r: [64]f32 = @splat(0.5);
            var bufs = [_][]f32{ &l, &r };
            plugin.process(AudioBlock.fromSlices(&bufs), &.{});
            for (l) |x| std.debug.assert(@abs(x - 0.75) < 1e-4);
            for (r) |x| std.debug.assert(@abs(x - 0.75) < 1e-4);
        }
    };
    const th = try std.Thread.spawn(.{}, Audio.run, .{p});
    th.join();
    try testing.expectApproxEqAbs(@as(f32, 200.0), getById(p, "12").?, 0.01);

    const blob = (try p.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(blob);
    vst3.destroyPlugin(p);

    const q = try make("Fixture Gain");
    defer vst3.destroyPlugin(q);
    try testing.expect(q.loadState(blob));
    try testing.expectApproxEqAbs(@as(f32, 1.5), getById(q, "7").?, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 200.0), getById(q, "12").?, 0.01);
    try testing.expect(setById(q, "12", 300.0));
    try testing.expect(q.loadState(blob));

    const r = try make("Fixture Gain");
    defer vst3.destroyPlugin(r);
    const again = (try q.saveState(testing.allocator)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(again);
    try testing.expect(r.loadState(again));
    // A loaded state replaces earlier edits.
    try testing.expectApproxEqAbs(@as(f32, 200.0), getById(r, "12").?, 0.01);
}

// ---- layouts ---------------------------------------------------------------------------------

test "fixture e2e: layouts beyond the host limits are rejected, not truncated" {
    try begin();
    // Control: exactly at the limits (16 buses of 64 channels) activates and gets its full layout.
    const wide16 = try make("Fixture Wide 16x64");
    defer vst3.destroyPlugin(wide16);
    wide16.prepare(SR_44K, 64, 2);
    try testing.expectEqual(GAIN_LATENCY, wide16.latencySamples());
    var l: [64]f32 = @splat(0.5);
    var r: [64]f32 = @splat(0.5);
    var bufs = [_][]f32{ &l, &r };
    wide16.process(AudioBlock.fromSlices(&bufs), &.{});
    for (l) |x| try testing.expectEqual(@as(f32, 1.0), x);
    for (r) |x| try testing.expectEqual(@as(f32, 1.0), x);

    // 17 buses, or a 65-channel bus: never activated, never processed with a cut-down layout.
    const names = [_][]const u8{ "Fixture Wide 17 buses", "Fixture Wide 65 channels" };
    for (names) |name| {
        const p = try make(name);
        defer vst3.destroyPlugin(p);
        p.prepare(SR_44K, 64, 2);
        try testing.expectEqual(@as(usize, 0), p.latencySamples());
        var lx: [64]f32 = @splat(0.5);
        var rx: [64]f32 = @splat(0.5);
        var bx = [_][]f32{ &lx, &rx };
        p.process(AudioBlock.fromSlices(&bx), &.{});
        for (lx) |x| try testing.expectEqual(@as(f32, 0.5), x);
    }
}

// ---- editor ----------------------------------------------------------------------------------

test "fixture e2e: editor view size is probed without attaching" {
    try begin();
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    // Editor windows are hosted on macOS and Windows; elsewhere the probe reports "unsupported".
    if (editorsHosted()) {
        const size = try p.editorSize();
        try testing.expectEqual(@as(u32, 320), size.w);
        try testing.expectEqual(@as(u32, 240), size.h);
    } else {
        try testing.expect(std.meta.isError(p.editorSize()));
    }
    // The synth's controller has no view, so its size is an error.
    const synth = try make("Fixture Synth");
    defer vst3.destroyPlugin(synth);
    try testing.expect(std.meta.isError(synth.editorSize()));
}

test "fixture e2e: editor view is opened only on the main thread, and an editor-less controller has no window" {
    try begin();
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    const ed = p.editor() orelse return error.TestUnexpectedResult;
    defer plugin_mod.releaseEditor(ed);
    try testing.expect(!ed.isOpen());
    if (!onMainThread()) {
        // Opening a window is refused off the main thread (and everywhere without window hosting).
        try testing.expectError(error.OpenFailed, ed.open());
    }
    try testing.expect(!ed.isOpen());

    // The synth's controller has no view, so opening its editor fails.
    const synth = try make("Fixture Synth");
    defer vst3.destroyPlugin(synth);
    const sed = synth.editor() orelse return error.TestUnexpectedResult;
    defer plugin_mod.releaseEditor(sed);
    try testing.expect(std.meta.isError(sed.open()));
    try testing.expect(!sed.isOpen());
}

test "fixture e2e: editor on the main thread: value text, set_param, and inert handles after drop" {
    try begin();
    const p = try make("Fixture Gain");
    const ed = p.editor() orelse return error.TestUnexpectedResult;
    defer plugin_mod.releaseEditor(ed);
    try testing.expect(!ed.isOpen());

    const first = try ed.idle(testing.allocator);
    defer testing.allocator.free(first);
    try testing.expectEqual(@as(usize, 1), first.len);

    // Session to editor: the controller follows; the edit is not reported back.
    ed.setParam(indexOf(p, "7"), 1.5);
    const quiet = try ed.idle(testing.allocator);
    defer testing.allocator.free(quiet);
    try testing.expectEqual(@as(usize, 0), quiet.len);

    // identity-mapped (JUCE-style) parameters show the plugin's own text, verbatim, with its units
    // appended once; correctly mapped parameters and choices keep SoundCraft's format. Main thread
    // only: elsewhere the plugin's text is not read at all.
    const main = onMainThread();
    const cases = [_]struct { id: []const u8, value: f32, want: ?[]const u8 }{
        .{ .id = "13", .value = 0.375, .want = "\u{2212}6.0 dB" },
        .{ .id = "13", .value = 1.0, .want = "24.0 dB" },
        .{ .id = "14", .value = 0.25, .want = "3.0 dB" }, // units already in the text
        .{ .id = "7", .value = 1.5, .want = null }, // mapped: SoundCraft formats it
        .{ .id = "3", .value = 1.0, .want = null }, // choice: SoundCraft formats it
    };
    for (cases) |c| {
        const text = try ed.valueText(testing.allocator, indexOf(p, c.id), c.value);
        defer if (text) |t| testing.allocator.free(t);
        if (main and c.want != null) {
            try testing.expectEqualStrings(c.want.?, text orelse return error.TestUnexpectedResult);
        } else if (!main and c.want != null) {
            try testing.expectEqual(@as(?[]u8, null), text);
        } else {
            try testing.expectEqual(@as(?[]u8, null), text);
        }
    }

    // The plugin is gone: the handle stays valid and its calls do nothing.
    vst3.destroyPlugin(p);
    const gone = try ed.valueText(testing.allocator, 3, 0.375);
    try testing.expectEqual(@as(?[]u8, null), gone);
    try testing.expect(!ed.isOpen());
    try testing.expectError(error.OpenFailed, ed.open());
}

// ---- NaN, junk and allocation ----------------------------------------------------------------

test "fixture e2e: NaN output does not poison the next block" {
    try begin();
    const p = try make("Fixture Gain");
    defer vst3.destroyPlugin(p);
    p.prepare(SR_48K, 64, 2);

    fixture.nan_output.store(true, .monotonic);
    var l: [64]f32 = @splat(0.5);
    var r: [64]f32 = @splat(0.5);
    var bufs = [_][]f32{ &l, &r };
    p.process(AudioBlock.fromSlices(&bufs), &.{});
    fixture.nan_output.store(false, .monotonic);

    // The plugin's state is intact: the next block is finite and processed normally.
    var l2: [64]f32 = @splat(0.5);
    var r2: [64]f32 = @splat(0.5);
    var bufs2 = [_][]f32{ &l2, &r2 };
    p.process(AudioBlock.fromSlices(&bufs2), &.{});
    // Gain stayed at its plain 0.5 (factor 0.5): 0.5 * 0.5 = 0.25 in every frame.
    for (l2) |x| try testing.expectApproxEqAbs(@as(f32, 0.25), x, 1e-6);
    try testing.expectEqual(@as(?f32, 0.5), getById(p, "7"));
}

/// A fresh scratch folder under the system temp dir (absolute path, caller frees).
fn scratchDir(name: []const u8) ![]u8 {
    const io = registry.globalRegistry().io;
    const d = try std.fmt.allocPrint(testing.allocator, "/tmp/seridian-vst3-e2e-{s}-{d}", .{ name, std.c.getpid() });
    errdefer testing.allocator.free(d);
    std.Io.Dir.cwd().deleteTree(io, d) catch {};
    try std.Io.Dir.cwd().createDirPath(io, d);
    return d;
}

test "fixture e2e: junk bundles beside the fixture are skipped, not crashes" {
    try begin();
    const io = registry.globalRegistry().io;
    const d = try scratchDir("junk");
    defer {
        std.Io.Dir.cwd().deleteTree(io, d) catch {};
        testing.allocator.free(d);
    }
    // Not a binary, empty, a bundle with no binary, and a bundle with a truncated binary.
    const junk = [_]struct { sub: []const u8, bytes: []const u8 }{
        .{ .sub = "junk.vst3", .bytes = "\x7fELF this is not a plugin" },
        .{ .sub = "empty.vst3", .bytes = "" },
    };
    for (junk) |j| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ d, j.sub });
        defer testing.allocator.free(path);
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, j.bytes);
    }
    const nobin = try std.fmt.allocPrint(testing.allocator, "{s}/NoBinary.vst3/Contents", .{d});
    defer testing.allocator.free(nobin);
    try std.Io.Dir.cwd().createDirPath(io, nobin);

    const dirs = [_][]const u8{d};
    const found = try vst3.scanPaths(testing.allocator, &dirs);
    defer Descriptor.freeList(testing.allocator, found);
    try testing.expectEqual(@as(usize, 0), found.len);

    const junk_path = try std.fmt.allocPrint(testing.allocator, "{s}/junk.vst3", .{d});
    defer testing.allocator.free(junk_path);
    try testing.expectError(error.Load, vst3.loadBundle(testing.allocator, junk_path));

    // The fixture is unaffected by the junk next to it.
    const gain = try idOf("Fixture Gain");
    defer testing.allocator.free(gain);
    const p = try vst3.instantiate(testing.allocator, gain);
    defer vst3.destroyPlugin(p);
    try testing.expectError(error.NotFound, vst3.instantiate(testing.allocator, "vst3:00000000000000000000000000000000"));
}

/// Counts every allocation request made through it (the child allocator does the work).
const CountingAllocator = struct {
    child: Allocator,
    allocations: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocations += 1;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// Runs a fixture class through prepare and a warm-up, then counts the allocations made by many
/// `process` calls with note, MIDI and parameter events. Only the rule of `process` is checked:
/// preparing and warming up may allocate.
fn expectProcessDoesNotAllocate(name: []const u8, with_notes: bool) !void {
    const id = try idOf(name);
    defer testing.allocator.free(id);
    // Built through the registry, so the instance and the plugin both take the counting allocator.
    _ = vst3.pluginInfo(id) orelse return error.TestUnexpectedResult;
    var counting: CountingAllocator = .{ .child = testing.allocator };
    const reg = registry.globalRegistry();
    const saved = reg.gpa;
    reg.gpa = counting.allocator();
    const made = vst3.instantiate(counting.allocator(), id);
    reg.gpa = saved;
    const p = try made;
    defer vst3.destroyPlugin(p);

    p.prepare(SR_48K, 256, 2);
    var l: [256]f32 = @splat(0.5);
    var r: [256]f32 = @splat(0.5);
    var bufs = [_][]f32{ &l, &r };
    p.process(AudioBlock.fromSlices(&bufs), &.{});

    const ev_on = [_]Event{ noteOn(3, 60, 100), midi(20, .{ 0xB0, 7, 64 }), paramEvent(40, 0, 1.2) };
    const ev_off = [_]Event{ noteOff(5, 60), midi(9, .{ 0xA0, 60, 32 }) };
    counting.allocations = 0;
    var block: usize = 0;
    while (block < 200) : (block += 1) {
        if (with_notes) {
            p.process(AudioBlock.fromSlices(&bufs), if (block % 2 == 0) &ev_on else &ev_off);
        } else {
            p.process(AudioBlock.fromSlices(&bufs), &ev_on);
        }
    }
    try testing.expectEqual(@as(usize, 0), counting.allocations);
}

test "fixture e2e: process does not allocate (counting allocator)" {
    try begin();
    try expectProcessDoesNotAllocate("Fixture Gain", false);
    try expectProcessDoesNotAllocate("Fixture Synth", true);
}

test "fixture e2e: teardown shuts plugin hosting down and returns the fixture counters to rest" {
    // Must stay the last test of this file. This file registers the fixture with the process-wide
    // registry once; the fixture's own tests and `module_exit_test.zig` assume the counters start
    // at rest, so the registration is ended here, through the same shutdown the engine uses. The
    // global registry's `Io` and bundle list are then the only state left, and loads are refused.
    module.globalRegistry().assume_main = true;
    vst3.shutdownPluginHosts();
    try testing.expectEqual(@as(i64, 0), fixture.entered.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), fixture.factories_alive.load(.seq_cst));
    try testing.expectEqual(@as(i64, 0), fixture.objects_alive.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), fixture.violations.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), fixture.contract_failures.load(.seq_cst));
    // Loads fail after shutdown.
    const id = try idOf("Fixture Gain");
    defer testing.allocator.free(id);
    try testing.expectError(error.Load, vst3.instantiate(testing.allocator, id));
    fixture.reset();
}
