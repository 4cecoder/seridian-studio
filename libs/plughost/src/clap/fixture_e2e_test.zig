// Translated to Zig from soundcraft/crates/clap-host/tests/it/fixture_e2e.rs, soundcraft/crates/clap-host/tests/common/mod.rs, soundcraft/crates/clap-host/tests/editor_main_thread.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! End-to-end tests of the CLAP host against the in-process fixture (`test_fixture.zig`),
//! through the public `clap.zig` and `Registry` API: register, scan, instantiate, prepare,
//! process blocks with sample-offset events, parameters, latency, state, editors and junk files.
//!
//! The Rust tests built the fixture as a cdylib and installed it in a temp folder. Here the
//! fixture entry is registered directly (`Registry.registerEntry`), which is the same code path
//! minus the dlopen. No test needs a real dylib, so none skips for that reason. The one skip is
//! the 16 x 64 layout control, which the Zig planar limit makes impossible (see that test).
//!
//! Seridian-specific: `process performs no allocation` swaps a `FailingAllocator` into the
//! plugin after `prepare`, so any allocation on the audio path is caught.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const abi = @import("abi.zig");
const clap = @import("clap.zig");
const plugin_clap = @import("plugin.zig");
const registry_mod = @import("registry.zig");
const test_fixture = @import("test_fixture.zig");
const plugin_api = @import("../plugin.zig");
const event = @import("../event.zig");

const Registry = registry_mod.Registry;
const ClapPlugin = plugin_clap.ClapPlugin;
const AudioBlock = plugin_api.AudioBlock;
const Plugin = plugin_api.Plugin;

const GAIN: []const u8 = "clap:org.soundcraft.test.gain";
const SYNTH: []const u8 = "clap:org.soundcraft.test.synth";
const WIDE17: []const u8 = "clap:org.soundcraft.test.wide17ports";
const WIDE65: []const u8 = "clap:org.soundcraft.test.wide65ch";
const FIXTURE_NAME: [:0]const u8 = "e2e-fixture";

fn testIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

/// A registry holding the five fixture plugins, registered as an in-process entry.
fn openFixture(io: Io) !Registry {
    test_fixture.reset();
    var reg: Registry = .{
        .gpa = testing.allocator,
        .infos_arena = std.heap.ArenaAllocator.init(testing.allocator),
    };
    errdefer reg.shutdown(io);
    const added = try reg.registerEntry(io, &test_fixture.entry, FIXTURE_NAME);
    try testing.expectEqual(@as(usize, 5), added);
    return reg;
}

fn findById(list: []const clap.ClapDescriptor, id: []const u8) ?clap.ClapDescriptor {
    for (list) |d| {
        if (std.mem.eql(u8, d.id, id)) return d;
    }
    return null;
}

// ---- scan, metadata and info ----------------------------------------------------------------

test "fixture e2e: registerEntry scans the five fixture plugins with their metadata" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    // The Rust test also ran `scan()` over the system folders; that depends on what is installed
    // on the machine, so only the registered fixture is checked here.
    const listed = (try reg.cached(io, testing.allocator)).?;
    defer clap.freeDescriptors(testing.allocator, listed);
    try testing.expectEqual(@as(usize, 5), listed.len);

    const g = findById(listed, GAIN) orelse return error.MissingGain;
    try testing.expectEqualStrings("org.soundcraft.test.gain", g.plugin_id);
    try testing.expectEqualStrings("Fixture Gain", g.name);
    try testing.expectEqualStrings("SoundCraft tests", g.vendor);
    try testing.expectEqual(@as(usize, 2), g.features.len);
    try testing.expectEqualStrings("audio-effect", g.features[0]);
    try testing.expectEqualStrings("stereo", g.features[1]);
    try testing.expectEqual(plugin_api.Category.other, g.category);
    try testing.expect(!g.is_instrument);
    try testing.expectEqualStrings(FIXTURE_NAME, g.path);

    const s = findById(listed, SYNTH) orelse return error.MissingSynth;
    try testing.expectEqual(plugin_api.Category.instrument, s.category);
    try testing.expect(s.is_instrument);
}

test "fixture e2e: plugin info exposes visible params with names, ranges and choices, cached per type" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const info = reg.pluginInfo(io, GAIN) orelse return error.NoInfo;
    try testing.expectEqualStrings(GAIN, info.id);
    try testing.expectEqualStrings("Fixture ", info.short_name);

    // Seridian deviation (registry.zig header): hidden param 9 is kept, in CLAP order after the
    // visible ones; Rust skips it. The ids are the CLAP ids as decimal strings.
    try testing.expectEqual(@as(usize, 3), info.params.len);
    try testing.expectEqualStrings("7", info.params[0].id);
    try testing.expectEqualStrings("3", info.params[1].id);
    try testing.expectEqualStrings("9", info.params[2].id);
    try testing.expectEqual(@as(?u32, 2), plugin_api.indexOfId(info, "9"));

    const gain = info.params[plugin_api.indexOfId(info, "7").?];
    try testing.expectEqualStrings("Gain", gain.name);
    try testing.expectEqual(@as(f32, 0.0), gain.min);
    try testing.expectEqual(@as(f32, 2.0), gain.max);
    try testing.expectEqual(@as(f32, 1.0), gain.default);

    const mode = info.params[plugin_api.indexOfId(info, "3").?];
    try testing.expectEqual(plugin_api.Unit.choice, mode.unit);
    try testing.expectEqual(@as(usize, 3), mode.choices.len);
    try testing.expectEqualStrings("A", mode.choices[0]);
    try testing.expectEqualStrings("B", mode.choices[1]);
    try testing.expectEqualStrings("C", mode.choices[2]);

    // Cached: the same info every time.
    try testing.expectEqual(info, reg.pluginInfo(io, GAIN).?);
    try testing.expect(reg.pluginInfo(io, SYNTH).?.is_instrument);
    try testing.expect(!info.is_instrument);
}

// ---- audio, params and blocks ---------------------------------------------------------------

test "fixture e2e: gain processes audio, follows params, chunks long blocks and survives hostile shapes" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const p = try reg.instantiate(io, GAIN);
    defer p.destroy();
    const plug = p.plugin();
    plug.prepare(44_100.0, 256, 2);
    try testing.expectEqual(@as(usize, 3), plug.latency());
    try testing.expectEqual(@as(?f32, 1.0), plug.getParam(0));

    var left: [256]f32 = @splat(0.5);
    var right: [256]f32 = @splat(-0.25);
    plug.process(AudioBlock.fromSlices(&.{ &left, &right }), &.{});
    for (left) |x| try testing.expectApproxEqAbs(@as(f32, 0.5), x, 1e-6);

    const info = plug.info();
    try testing.expect(plug.setParam(0, 2.0));
    // The hidden param is kept (Seridian deviation), and ids are CLAP numbers, not names.
    try testing.expectEqual(@as(?u32, 2), plugin_api.indexOfId(info, "9"));
    try testing.expectEqual(@as(?u32, null), plugin_api.indexOfId(info, "Gain"));
    try testing.expect(plug.setParam(0, 5.0));
    try testing.expectEqual(@as(?f32, 2.0), plug.getParam(0));

    // A block larger than max_block is chunked by the host.
    var big_l: [700]f32 = @splat(0.5);
    var big_r: [700]f32 = @splat(-0.25);
    plug.process(AudioBlock.fromSlices(&.{ &big_l, &big_r }), &.{});
    for (big_l) |x| try testing.expectApproxEqAbs(@as(f32, 1.0), x, 1e-6);
    for (big_r) |x| try testing.expectApproxEqAbs(@as(f32, -0.5), x, 1e-6);

    // Mono strip: the input is duplicated into the stereo port, and the output comes back.
    plug.prepare(48_000.0, 128, 1);
    var mono: [128]f32 = @splat(0.25);
    plug.process(AudioBlock.fromSlices(&.{&mono}), &.{});
    for (mono) |x| try testing.expectApproxEqAbs(@as(f32, 0.5), x, 1e-6);

    // Hostile shapes: no channels, and a channel shorter than the frame count.
    plug.process(AudioBlock.fromSlices(&.{}), &.{});
    var short: [4]f32 = @splat(1.0);
    plug.process(AudioBlock.fromSlices(&.{&short}), &.{});
    try testing.expectApproxEqAbs(@as(f32, 2.0), short[0], 1e-6);

    // NaN becomes the default; reset and a broken prepare must not crash.
    try testing.expect(plug.setParam(0, std.math.nan(f32)));
    try testing.expectEqual(@as(?f32, 1.0), plug.getParam(0));
    plug.reset();
    plug.prepare(std.math.nan(f32), 0, 0);
    var tiny: [8]f32 = @splat(0.1);
    plug.process(AudioBlock.fromSlices(&.{&tiny}), &.{});
}

test "fixture e2e: synth plays notes and MIDI CC at their sample offsets, and the fixture sees the same offsets" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const info = reg.pluginInfo(io, SYNTH) orelse return error.NoInfo;
    try testing.expect(info.is_instrument);
    const p = try reg.instantiate(io, SYNTH);
    defer p.destroy();
    const plug = p.plugin();
    plug.prepare(48_000.0, 64, 2);

    var left: [64]f32 = @splat(9.0);
    var right: [64]f32 = @splat(9.0);
    const notes = [_]event.Event{
        .{ .offset = 10, .kind = .{ .note_on = .{ .note = 60, .velocity = 127 } } },
        .{ .offset = 40, .kind = .{ .note_off = 60 } },
    };
    test_fixture.reset();
    plug.process(AudioBlock.fromSlices(&.{ &left, &right }), &notes);
    for (left, 0..) |x, i| {
        const want: f32 = if (i >= 10 and i < 40) 1.0 else 0.0;
        try testing.expectApproxEqAbs(want, x, 1e-6);
    }
    try testing.expectEqualSlices(f32, &left, &right);

    // The fixture saw the note on at offset 10 and the note off at offset 40.
    var rec: [8]test_fixture.RecordedEvent = undefined;
    const got = test_fixture.recordedEvents(&rec);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(abi.CLAP_EVENT_NOTE_ON, got[0].kind);
    try testing.expectEqual(@as(u32, 10), got[0].sample_offset);
    try testing.expectEqual(@as(i16, 60), got[0].key);
    try testing.expectEqual(abi.CLAP_EVENT_NOTE_OFF, got[1].kind);
    try testing.expectEqual(@as(u32, 40), got[1].sample_offset);

    // An offset past the block is clamped into it; a second note is held to the last frame.
    test_fixture.reset();
    const late = [_]event.Event{.{ .offset = 1000, .kind = .{ .note_on = .{ .note = 61, .velocity = 64 } } }};
    var io2_l: [64]f32 = @splat(0.0);
    var io2_r: [64]f32 = @splat(0.0);
    plug.process(AudioBlock.fromSlices(&.{ &io2_l, &io2_r }), &late);
    try testing.expectApproxEqAbs(@as(f32, 0.0), io2_l[62], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 127.0), io2_l[63], 1e-6);
    const got2 = test_fixture.recordedEvents(&rec);
    try testing.expectEqual(@as(usize, 1), got2.len);
    try testing.expectEqual(@as(u32, 63), got2[0].sample_offset);

    // Releasing the held note (offset 0 stands in for all_notes_off, which the Event model
    // does not carry) silences the block.
    var io3_l: [64]f32 = @splat(0.0);
    var io3_r: [64]f32 = @splat(0.0);
    const release = [_]event.Event{.{ .offset = 0, .kind = .{ .note_off = 61 } }};
    plug.process(AudioBlock.fromSlices(&.{ &io3_l, &io3_r }), &release);
    for (io3_l) |x| try testing.expectApproxEqAbs(@as(f32, 0.0), x, 1e-6);

    // MIDI controller 7 arrives as MIDI at its offset.
    test_fixture.reset();
    const cc = [_]event.Event{.{ .offset = 20, .kind = .{ .midi3 = .{ 0xB0, 7, 64 } } }};
    var io4_l: [64]f32 = @splat(0.0);
    var io4_r: [64]f32 = @splat(0.0);
    plug.process(AudioBlock.fromSlices(&.{ &io4_l, &io4_r }), &cc);
    try testing.expectApproxEqAbs(@as(f32, 0.0), io4_l[19], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 64.0 / 127.0), io4_l[20], 1e-6);
    const got4 = test_fixture.recordedEvents(&rec);
    try testing.expectEqual(@as(usize, 1), got4.len);
    try testing.expectEqual(abi.CLAP_EVENT_MIDI, got4[0].kind);
    try testing.expectEqual(@as(u32, 20), got4[0].sample_offset);
    try testing.expectEqualSlices(u8, &.{ 0xB0, 7, 64 }, &got4[0].midi);
}

test "fixture e2e: a parameter event applies at its sample offset and the fixture sees it there" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const p = try reg.instantiate(io, GAIN);
    defer p.destroy();
    const plug = p.plugin();
    plug.prepare(48_000.0, 64, 2);

    test_fixture.reset();
    var left: [16]f32 = @splat(1.0);
    var right: [16]f32 = @splat(1.0);
    const changes = [_]event.Event{.{ .offset = 5, .kind = .{ .param = .{ .index = 0, .value = 0.5 } } }};
    plug.process(AudioBlock.fromSlices(&.{ &left, &right }), &changes);
    for (left[0..5]) |x| try testing.expectApproxEqAbs(@as(f32, 1.0), x, 1e-6);
    for (left[5..]) |x| try testing.expectApproxEqAbs(@as(f32, 0.5), x, 1e-6);

    var rec: [4]test_fixture.RecordedEvent = undefined;
    const got = test_fixture.recordedEvents(&rec);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(abi.CLAP_EVENT_PARAM_VALUE, got[0].kind);
    try testing.expectEqual(@as(u32, 5), got[0].sample_offset);
    try testing.expectEqual(@as(abi.ClapId, 7), got[0].param_id);
    try testing.expectApproxEqAbs(@as(f64, 0.5), got[0].value, 1e-9);
}

test "fixture e2e: latency is reported after prepare; tail and synth latency are zero" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const g = try reg.instantiate(io, GAIN);
    defer g.destroy();
    const gp = g.plugin();
    gp.prepare(48_000.0, 64, 2);
    try testing.expectEqual(@as(usize, 3), gp.latency());
    try testing.expectEqual(@as(usize, 0), gp.tailSamples());

    const s = try reg.instantiate(io, SYNTH);
    defer s.destroy();
    const sp = s.plugin();
    sp.prepare(48_000.0, 64, 2);
    try testing.expectEqual(@as(usize, 0), sp.latency());
    try testing.expectEqual(@as(usize, 0), sp.tailSamples());
}

test "fixture e2e: a non-finite output is counted and the block is not written back" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const p = try reg.instantiate(io, GAIN);
    defer p.destroy();
    const plug = p.plugin();
    plug.prepare(48_000.0, 64, 2);

    // The fixture multiplies its input by the gain, so a NaN input sample gives a NaN output.
    // Rust hands that NaN to the caller unchanged. Here the instance reports NonFiniteOutput,
    // which ClapPlugin counts in `process_errors` and turns into a pass-through of the block.
    var left: [64]f32 = @splat(0.5);
    left[1] = std.math.nan(f32);
    var right: [64]f32 = @splat(0.5);
    plug.process(AudioBlock.fromSlices(&.{ &left, &right }), &.{});
    try testing.expectEqual(@as(u32, 1), p.process_errors.load(.monotonic));
    try testing.expectEqual(@as(f32, 0.5), left[0]);
    try testing.expect(std.math.isNan(left[1]));
    for (left[2..]) |x| try testing.expectEqual(@as(f32, 0.5), x);
    for (right) |x| try testing.expectEqual(@as(f32, 0.5), x);

    // A clean block afterwards is processed normally and the count stays put.
    var clean_l: [64]f32 = @splat(0.5);
    var clean_r: [64]f32 = @splat(0.5);
    plug.process(AudioBlock.fromSlices(&.{ &clean_l, &clean_r }), &.{});
    for (clean_l) |x| try testing.expectApproxEqAbs(@as(f32, 0.5), x, 1e-6);
    try testing.expectEqual(@as(u32, 1), p.process_errors.load(.monotonic));
}

// ---- layouts --------------------------------------------------------------------------------

test "fixture e2e: layouts beyond the host limits are rejected, not truncated" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    // 17 ports, or a 65-channel port: never activated, never processed with a cut-down layout.
    for ([_][]const u8{ WIDE17, WIDE65 }) |id| {
        const p = try reg.instantiate(io, id);
        defer p.destroy();
        const plug = p.plugin();
        plug.prepare(44_100.0, 64, 2);
        try testing.expectEqual(@as(usize, 0), plug.latency());
        var left: [64]f32 = @splat(0.5);
        var right: [64]f32 = @splat(0.5);
        plug.process(AudioBlock.fromSlices(&.{ &left, &right }), &.{});
        for (left) |x| try testing.expectEqual(@as(f32, 0.5), x);
        for (right) |x| try testing.expectEqual(@as(f32, 0.5), x);
    }
}

test "fixture e2e: a 16 ports x 64 channel layout is delivered in full" {
    // Not expressible here. The Rust host allows 64 channels per port; this host caps a port at
    // `plugin.MAX_CHANNELS` (16, the planar block limit; deviation 6 in plugin.zig), so the
    // 64-channel ports of wide16 are refused at prepare and the control case cannot activate.
    // The rejection half is covered by the 17-port and 65-channel test above.
    return error.SkipZigTest;
}

// ---- instances ------------------------------------------------------------------------------

test "fixture e2e: many instances create and drop cleanly" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    for (0..50) |_| {
        const a = try reg.instantiate(io, GAIN);
        defer a.destroy();
        const b = try reg.instantiate(io, SYNTH);
        defer b.destroy();
        a.plugin().prepare(48_000.0, 32, 2);
        b.plugin().prepare(48_000.0, 32, 2);
        var l: [32]f32 = @splat(0.0);
        var r: [32]f32 = @splat(0.0);
        a.plugin().process(AudioBlock.fromSlices(&.{ &l, &r }), &.{});
    }
}

// ---- state ----------------------------------------------------------------------------------

test "fixture e2e: state saves, restores into a new instance, and refuses hostile blobs" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const p = try reg.instantiate(io, GAIN);
    defer p.destroy();
    const plug = p.plugin();
    plug.prepare(48_000.0, 64, 2);
    try testing.expect(plug.setParam(0, 1.5));
    try testing.expect(plug.setParam(1, 2.0));
    var left: [64]f32 = @splat(0.5);
    var right: [64]f32 = @splat(0.5);
    plug.process(AudioBlock.fromSlices(&.{ &left, &right }), &.{});
    const blob = (try plug.saveState(testing.allocator)) orelse return error.NoState;
    defer testing.allocator.free(blob);
    try testing.expectEqual(@as(usize, 16), blob.len);

    const q_plug = try reg.instantiate(io, GAIN);
    defer q_plug.destroy();
    const q = q_plug.plugin();
    q.prepare(48_000.0, 64, 2);
    try testing.expectEqual(@as(?f32, 1.0), q.getParam(0));
    try testing.expect(q.loadState(blob));
    try testing.expectEqual(@as(?f32, 1.5), q.getParam(0));
    try testing.expectEqual(@as(?f32, 2.0), q.getParam(1));
    var ql: [64]f32 = @splat(0.5);
    var qr: [64]f32 = @splat(0.5);
    q.process(AudioBlock.fromSlices(&.{ &ql, &qr }), &.{});
    for (ql) |x| try testing.expectApproxEqAbs(@as(f32, 0.75), x, 1e-6);

    // Hostile blobs are refused and leave the plugin as it was.
    try testing.expect(!q.loadState("short"));
    const nan_blob: [16]u8 = @splat(0xff);
    try testing.expect(!q.loadState(&nan_blob));
    const long_blob: [4096]u8 = @splat(0);
    try testing.expect(!q.loadState(&long_blob));
    try testing.expectEqual(@as(?f32, 1.5), q.getParam(0));

    // Plugins without clap.state, and without a GUI.
    const s = try reg.instantiate(io, SYNTH);
    defer s.destroy();
    const sp = s.plugin();
    try testing.expect((try sp.saveState(testing.allocator)) == null);
    try testing.expect(sp.stateReader() == null);
    try testing.expect(!sp.loadState(blob));
    // The synth has no GUI.
    try testing.expect(sp.editor() == null);
    try testing.expectError(error.NoEditor, sp.openEditor());
}

test "fixture e2e: a state reader reads while another thread processes" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const p = try reg.instantiate(io, GAIN);
    const plug = p.plugin();
    plug.prepare(48_000.0, 64, 2);
    try testing.expect(plug.setParam(0, 1.5));
    var warm_l: [64]f32 = @splat(0.5);
    var warm_r: [64]f32 = @splat(0.5);
    plug.process(AudioBlock.fromSlices(&.{ &warm_l, &warm_r }), &.{});
    const reader = plug.stateReader() orelse return error.NoStateReader;
    defer plugin_clap.releaseStateReader(reader);
    const blob = (try plug.saveState(testing.allocator)) orelse return error.NoState;
    defer testing.allocator.free(blob);

    var run: AudioRun = .{ .plug = plug };
    const audio = try std.Thread.spawn(.{}, audioRun, .{&run});
    while (!run.done.load(.acquire)) {
        const got = (try reader.saveState(testing.allocator)) orelse return error.ReaderLost;
        defer testing.allocator.free(got);
        try testing.expectEqualSlices(u8, blob, got);
    }
    audio.join();

    const after = (try reader.saveState(testing.allocator)) orelse return error.ReaderLost;
    defer testing.allocator.free(after);
    try testing.expectEqualSlices(u8, blob, after);

    // Once the plugin is destroyed the reader stays valid memory and reads nothing.
    p.destroy();
    try testing.expect((try reader.saveState(testing.allocator)) == null);
}

/// Shared between the test and the audio thread that processes blocks.
const AudioRun = struct {
    plug: Plugin,
    done: std.atomic.Value(bool) = .init(false),
};

fn audioRun(run: *AudioRun) void {
    var l: [64]f32 = @splat(0.5);
    var r: [64]f32 = @splat(0.5);
    const block = AudioBlock.fromSlices(&.{ &l, &r });
    for (0..2_000) |_| run.plug.process(block, &.{});
    run.done.store(true, .release);
}

// ---- editors (GUI) --------------------------------------------------------------------------

test "fixture e2e: an editor opens and closes on the main thread, and its edit reaches the host" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    // Test threads are not the process main thread in the Rust harness; the Zig test runner
    // runs tests on the main thread, so opening here is the main-thread path.
    const p = try reg.instantiate(io, GAIN);
    const plug = p.plugin();
    plug.prepare(48_000.0, 64, 2);
    const ed = plug.editor() orelse return error.NoEditor;
    defer plugin_clap.releaseEditor(ed);
    try testing.expect(!ed.isOpen());
    try ed.open();
    try testing.expect(ed.isOpen());
    try ed.open();
    try testing.expect(ed.isOpen());

    // The fixture "edits" the gain in its GUI; the edit arrives as an output event of the next
    // block and is reported (in SoundCraft units) by idle.
    var l: [64]f32 = @splat(1.0);
    var r: [64]f32 = @splat(1.0);
    plug.process(AudioBlock.fromSlices(&.{ &l, &r }), &.{});
    try testing.expectApproxEqAbs(@as(f32, 0.25), l[10], 1e-6);
    const edits = try ed.idle(testing.allocator);
    defer testing.allocator.free(edits);
    try testing.expectEqual(@as(usize, 1), edits.len);
    try testing.expectEqual(@as(u32, 0), edits[0].index);
    try testing.expectApproxEqAbs(@as(f32, 0.25), edits[0].value, 1e-6);
    const drained = try ed.idle(testing.allocator);
    defer testing.allocator.free(drained);
    try testing.expectEqual(@as(usize, 0), drained.len);

    ed.close();
    try testing.expect(!ed.isOpen());
    // Through the Plugin handle as well.
    try plug.openEditor();
    try testing.expect(ed.isOpen());
    plug.closeEditor();
    try testing.expect(!ed.isOpen());

    // Dropping the instance with its editor open destroys the GUI first; the handle then
    // refuses politely.
    try ed.open();
    p.destroy();
    try testing.expect(!ed.isOpen());
    try testing.expectError(error.NoEditor, ed.open());
    const after = try ed.idle(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqual(@as(usize, 0), after.len);
    ed.close();
}

test "fixture e2e: editors refuse to open off the main thread" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    const p = try reg.instantiate(io, GAIN);
    defer p.destroy();
    const plug = p.plugin();
    const ed = plug.editor() orelse return error.NoEditor;
    defer plugin_clap.releaseEditor(ed);

    // The main-thread rule is enforced on macOS (gui.zig `onMainThread`); elsewhere no thread
    // check is made, so only the close calls run.
    if (builtin.os.tag == .macos) {
        var ctx: OffMain = .{ .plug = plug, .ed = ed };
        const t = try std.Thread.spawn(.{}, openOffMain, .{&ctx});
        t.join();
        try testing.expectError(error.OpenFailed, ctx.open_handle);
        try testing.expectError(error.OpenFailed, ctx.open_plugin);
        try testing.expect(!ed.isOpen());
    }
    ed.close();
    plug.closeEditor();
}

/// What the off-thread open calls returned.
const OffMain = struct {
    plug: Plugin,
    ed: plugin_api.PluginEditor,
    open_handle: plugin_api.EditorError!void = {},
    open_plugin: plugin_api.EditorError!void = {},
};

fn openOffMain(ctx: *OffMain) void {
    ctx.open_handle = ctx.ed.open();
    ctx.open_plugin = ctx.plug.openEditor();
}

// ---- allocation ----------------------------------------------------------------------------

test "fixture e2e: process performs no allocation (counting allocator)" {
    const io = testIo();
    var reg = try openFixture(io);
    defer reg.shutdown(io);

    // Seridian addition. A FailingAllocator with fail_index 0 is swapped into the plugin and the
    // instance after prepare. Any allocation the audio path makes trips `has_induced_failure`.
    const p = try reg.instantiate(io, SYNTH);
    defer p.destroy();
    const plug = p.plugin();
    plug.prepare(48_000.0, 64, 2);

    var counter = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const real_plug_gpa = p.gpa;
    const real_inst_gpa = p.inst.gpa;
    p.gpa = counter.allocator();
    p.inst.gpa = counter.allocator();
    defer {
        p.gpa = real_plug_gpa;
        p.inst.gpa = real_inst_gpa;
    }

    var left: [64]f32 = @splat(0.0);
    var right: [64]f32 = @splat(0.0);
    const block = AudioBlock.fromSlices(&.{ &left, &right });
    const notes = [_]event.Event{
        .{ .offset = 3, .kind = .{ .note_on = .{ .note = 60, .velocity = 100 } } },
        .{ .offset = 30, .kind = .{ .note_off = 60 } },
        .{ .offset = 40, .kind = .{ .midi3 = .{ 0xB0, 7, 64 } } },
    };
    for (0..8) |_| plug.process(block, &notes);
    plug.process(block, &.{});

    try testing.expect(!counter.has_induced_failure);
    try testing.expectEqual(@as(usize, 0), counter.alloc_index);
}

// ---- junk files ----------------------------------------------------------------------------

test "fixture e2e: junk files are errors, never crashes" {
    const io = testIo();
    const gpa = testing.allocator;
    var reg: Registry = .{
        .gpa = gpa,
        .infos_arena = std.heap.ArenaAllocator.init(gpa),
    };
    defer reg.shutdown(io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Bundle.clap/Contents/MacOS");
    // A non-CLAP file, an empty file, a bundle whose binary is a truncated Mach-O header, and a
    // file that is a truncated ELF header.
    try tmp.dir.writeFile(io, .{ .sub_path = "garbage.clap", .data = "\x7fELF this is not a plugin \x00\x01\x02" });
    try tmp.dir.writeFile(io, .{ .sub_path = "empty.clap", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Bundle.clap/Contents/MacOS/Bundle", .data = &.{ 0xcf, 0xfa, 0xed, 0xfe } });
    try tmp.dir.writeFile(io, .{ .sub_path = "truncated.clap", .data = "\x7fELF\x02\x01\x01" });

    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    for ([_][]const u8{ "garbage.clap", "empty.clap", "Bundle.clap", "truncated.clap", "missing.clap" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ dir, name });
        defer gpa.free(path);
        if (reg.loadBundle(io, gpa, path)) |list| {
            clap.freeDescriptors(gpa, list);
            return error.ExpectedLoadFailure;
        } else |_| {}
    }

    const found = try reg.scanPaths(io, gpa, &.{dir});
    defer clap.freeDescriptors(gpa, found);
    try testing.expectEqual(@as(usize, 0), found.len);
    try testing.expectEqual(@as(usize, 0), try reg.addSearchDir(io, dir));
    try testing.expect(reg.create(io, "clap:does.not.exist") == null);
    try testing.expect(reg.pluginInfo(io, "clap:does.not.exist") == null);
    try testing.expectError(error.NotFound, reg.instantiate(io, "clap:does.not.exist"));
    try testing.expectError(error.NotFound, reg.instantiate(io, "eq_7band"));
}
