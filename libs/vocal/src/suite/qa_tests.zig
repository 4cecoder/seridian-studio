// Translated to Zig from pitchpure/crates/pitchpure_suite/src/qa_tests.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Chain-level QA gate for `VocalChain`: objective DSP checks that must
//! hold before a build ships. Every signal is synthesized here and every
//! check is deterministic (CPU-time based where timing matters, so a loaded
//! build machine cannot flake the realtime budget).
//!
//! Seridian: Rust's `println!` lines are `std.log` info messages (shown in
//! Debug builds after raising `std.testing.log_level` to `.info`); a failed
//! check logs its measured value as an error before failing. The CPU-time
//! budgets (test 9 and the per-block check in test 4) only apply to
//! optimised builds, like the Rust crate which builds at opt-level 3.
//! `$HOME` redirection becomes an explicit temp `home` (see `takes.zig`).

const std = @import("std");
const builtin = @import("builtin");
const suite = @import("../suite.zig");
const BLOCK = suite.BLOCK;
const VocalChain = suite.VocalChain;
const Settings = suite.Settings;
const ScalePreset = suite.ScalePreset;
const takes = suite.takes;
const wav = suite.wav;

const testing = std.testing;
const log = std.log.scoped(.vocal_qa);

const RATE: u32 = 48_000;
const RATE_F: f32 = 48_000.0;
const C_MAJOR: ScalePreset = .major;

// ------------------------------------------------------------------ helpers

/// Rust `assert!(cond, fmt, args)`: log the message, then fail.
fn check(cond: bool, comptime fmt: []const u8, args: anytype) !void {
    if (!cond) {
        log.err(fmt, args);
        return error.TestUnexpectedResult;
    }
}

fn midiHz(m: f32) f32 {
    return 440.0 * std.math.pow(f32, 2.0, (m - 69.0) / 12.0);
}

fn cents(f: f32, reference: f32) f32 {
    return 1200.0 * @log2(f / reference);
}

fn db(x: f32) f32 {
    return 20.0 * @log10(@max(x, 1e-12));
}

/// Harmonic "voice": five harmonics with 1/k rolloff, no vibrato.
fn voice(gpa: std.mem.Allocator, hz: f32, seconds: f32, amp: f32) ![]f32 {
    const n: usize = @intFromFloat(seconds * RATE_F);
    const out = try gpa.alloc(f32, n);
    for (out, 0..) |*o, i| {
        const t = @as(f32, @floatFromInt(i)) / RATE_F;
        var s: f32 = 0.0;
        for (1..6) |k| {
            const kf: f32 = @floatFromInt(k);
            s += @sin(std.math.tau * hz * kf * t) / kf;
        }
        o.* = amp * s / 1.6;
    }
    return out;
}

/// Deterministic white noise (LCG) at peak `amp`.
fn noise(gpa: std.mem.Allocator, n: usize, amp: f32, seed: u32) ![]f32 {
    var x = seed;
    const out = try gpa.alloc(f32, n);
    for (out) |*o| {
        x = x *% 1_664_525 +% 1_013_904_223;
        o.* = amp * (@as(f32, @floatFromInt(x >> 8)) / @as(f32, @floatFromInt(@as(u32, 1) << 24)) * 2.0 - 1.0);
    }
    return out;
}

fn zeros(gpa: std.mem.Allocator, n: usize) ![]f32 {
    const out = try gpa.alloc(f32, n);
    @memset(out, 0.0);
    return out;
}

/// `a ++ b`, owned.
fn concat(gpa: std.mem.Allocator, a: []const f32, b: []const f32) ![]f32 {
    return std.mem.concat(gpa, f32, &.{ a, b });
}

/// Everything off except the tuner: the "dry" reference chain.
fn dryCfg() Settings {
    return .{
        .isolate_on = false,
        .eq_on = false,
        .dynamics_on = false,
        .space_on = false,
        .harmony_on = false,
        .scale = C_MAJOR,
        .root_note = 60,
    };
}

/// Run `input` through a fresh chain in BLOCK chunks (zero-padded tail).
fn run(gpa: std.mem.Allocator, cfg: *const Settings, input: []const f32) ![]f32 {
    var chain = try VocalChain.init(gpa, RATE, cfg);
    defer chain.deinit(gpa);
    return runWith(gpa, &chain, cfg, input);
}

fn runWith(gpa: std.mem.Allocator, chain: *VocalChain, cfg: *const Settings, input: []const f32) ![]f32 {
    chain.configure(cfg);
    const out = try gpa.alloc(f32, input.len);
    errdefer gpa.free(out);
    var block: [BLOCK]f32 = undefined;
    var wet: [BLOCK]f32 = undefined;
    var off: usize = 0;
    while (off < input.len) : (off += BLOCK) {
        const chunk = input[off..@min(off + BLOCK, input.len)];
        @memset(&block, 0.0);
        @memcpy(block[0..chunk.len], chunk);
        _ = try chain.process(&block, &wet, cfg);
        // Rust appends whole blocks, then `out.truncate(input.len())`.
        @memcpy(out[off .. off + chunk.len], wet[0..chunk.len]);
    }
    return out;
}

fn rms(x: []const f32) f32 {
    var sum: f32 = 0.0;
    for (x) |s| sum += s * s;
    return @sqrt(sum / @as(f32, @floatFromInt(@max(x.len, 1))));
}

fn peak(x: []const f32) f32 {
    var a: f32 = 0.0;
    for (x) |s| a = @max(a, @abs(s));
    return a;
}

fn allFinite(x: []const f32) bool {
    for (x) |s| if (!std.math.isFinite(s)) return false;
    return true;
}

/// Audible fundamental: strongest spectral line within +/-150 c of `near`
/// (0.1 Hz steps). Spectral rather than tracker-based, because what the
/// listener hears is the long-term spectrum, and frame-aligned trackers can
/// be fooled by block-periodic artefacts.
fn heardPitch(x: []const f32, near: f32) f32 {
    const lo = near * std.math.pow(f32, 2.0, -1.5 / 12.0);
    const hi = near * std.math.pow(f32, 2.0, 1.5 / 12.0);
    var best: f32 = 0.0;
    var best_f: f32 = near;
    var f = lo;
    while (f <= hi) : (f += 0.1) {
        const g = goertzel(x, f);
        if (g > best) {
            best = g;
            best_f = f;
        }
    }
    return best_f;
}

/// Goertzel magnitude of `freq` in `x`.
fn goertzel(x: []const f32, freq: f32) f32 {
    const w = std.math.tau * freq / RATE_F;
    const coeff = 2.0 * @cos(w);
    var s1: f32 = 0.0;
    var s2: f32 = 0.0;
    for (x) |v| {
        const s0 = v + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return @sqrt(@max(s1 * s1 + s2 * s2 - coeff * s1 * s2, 0.0)) / @as(f32, @floatFromInt(x.len));
}

fn secs(s: f32) usize {
    return @intFromFloat(s * RATE_F);
}

/// Thread CPU time in seconds (immune to other load on the machine).
fn cpuSeconds() f64 {
    const ns = std.Io.Clock.cpu_thread.now(testing.io).toNanoseconds();
    return @as(f64, @floatFromInt(ns)) * 1e-9;
}

/// The realtime-budget checks only mean something on optimised code: the
/// Rust crate is built at `opt-level = 3` even in dev builds.
fn skipTimingInDebug() bool {
    return builtin.mode == .debug;
}

// ------------------------------------------------------------------- tests

// 1. Notes sung 30 c flat land within +/-8 c of the target, for hard and
// natural retune; with TUNE off they stay flat.
test "qa_pitch_accuracy" {
    const gpa = testing.allocator;
    for ([_]f32{ 0.0, 40.0 }) |retune| {
        for ([_]f32{ 57.0, 60.0, 64.0, 67.0 }) |note| {
            const cfg: Settings = .{ .retune_ms = retune, .scale = C_MAJOR, .root_note = 60 };
            const sig = try voice(gpa, midiHz(note) * std.math.pow(f32, 2.0, -30.0 / 1200.0), 2.0, 0.5);
            defer gpa.free(sig);
            const out = try run(gpa, &cfg, sig);
            defer gpa.free(out);
            const err = cents(heardPitch(out[secs(1.0)..secs(1.9)], midiHz(note)), midiHz(note));
            log.info("qa pitch: retune {d:>2} ms  note {d}  error {d:.1} c", .{ retune, note, err });
            try check(@abs(err) <= 8.0, "note {d} retune {d}: {d:.1} c off", .{ note, retune, err });
        }
    }
    const cfg: Settings = .{ .tune_on = false, .scale = C_MAJOR, .root_note = 60 };
    const sig = try voice(gpa, midiHz(64.0) * std.math.pow(f32, 2.0, -30.0 / 1200.0), 2.0, 0.5);
    defer gpa.free(sig);
    const out = try run(gpa, &cfg, sig);
    defer gpa.free(out);
    const err = cents(heardPitch(out[secs(1.0)..secs(1.9)], midiHz(64.0)), midiHz(64.0));
    log.info("qa pitch: tune off  error {d:.1} c (expect -30)", .{err});
    try check(@abs(err + 30.0) <= 8.0, "tune off moved the pitch: {d:.1} c", .{err});
}

// 2. A C# sung in C major snaps to C or D, never stays on C#.
test "qa_scale_snapping" {
    const gpa = testing.allocator;
    const cfg = dryCfg();
    const sig = try voice(gpa, midiHz(61.0), 2.0, 0.5);
    defer gpa.free(sig);
    const out = try run(gpa, &cfg, sig);
    defer gpa.free(out);
    const f = heardPitch(out[secs(1.0)..secs(1.9)], midiHz(61.0));
    const to_c = cents(f, midiHz(60.0));
    const to_d = cents(f, midiHz(62.0));
    log.info("qa snap: C#4 -> {d:.1} Hz ({d:.1} c from C4, {d:.1} c from D4)", .{ f, to_c, to_d });
    try check(@abs(to_c) <= 10.0 or @abs(to_d) <= 10.0, "C# did not snap: {d} Hz", .{f});
    try check(@abs(cents(f, midiHz(61.0))) > 50.0, "C# left unsnapped", .{});
}

fn hotSignal(gpa: std.mem.Allocator) ![]f32 {
    const x = try voice(gpa, midiHz(55.0), 2.0, 0.95);
    var i: usize = 0;
    while (i < x.len) : (i += 4800) x[i] = 1.0; // transients
    return x;
}

// 3. Hot input never crosses the limiter ceiling; with the limiter
// switched off, the safety clip still holds 0 dBFS.
test "qa_limiter_ceiling" {
    const gpa = testing.allocator;
    const hot = try hotSignal(gpa);
    defer gpa.free(hot);
    const cfg: Settings = .{ .input_gain_db = 12.0 };
    const out = try run(gpa, &cfg, hot);
    defer gpa.free(out);
    const p = db(peak(out));
    log.info("qa limiter: ceiling {d} dBFS, peak {d:.2} dBFS", .{ cfg.limiter_ceiling_db, p });
    try check(p <= cfg.limiter_ceiling_db + 0.05, "peak {d:.2} dBFS over ceiling", .{p});

    const off: Settings = .{ .input_gain_db = 12.0, .limiter_on = false };
    const out_off = try run(gpa, &off, hot);
    defer gpa.free(out_off);
    const p_off = db(peak(out_off));
    log.info("qa limiter: switched off, peak {d:.2} dBFS", .{p_off});
    try check(p_off <= 0.0 + 1e-3, "safety clip failed: {d:.2} dBFS", .{p_off});
}

// 4. Hostile inputs stay finite and cheap; silence decays to silence;
// reverb tails die on time.
test "qa_numerical_safety" {
    const gpa = testing.allocator;
    const n = secs(1.5);
    const burst_src = try noise(gpa, n, 1.0, 7);
    defer gpa.free(burst_src);
    const bursts = try zeros(gpa, n);
    defer gpa.free(bursts);
    for (burst_src, 0..) |v, i| {
        if ((i / 2400) % 3 == 0) bursts[i] = v;
    }
    const silence = try zeros(gpa, n);
    defer gpa.free(silence);
    const dc = try gpa.alloc(f32, n);
    defer gpa.free(dc);
    @memset(dc, 0.5);
    const noisy = try noise(gpa, n, 0.5, 3);
    defer gpa.free(noisy);
    const square = try gpa.alloc(f32, n);
    defer gpa.free(square);
    for (square, 0..) |*s, i| s.* = if ((i / 109) % 2 == 0) 1.0 else -1.0;
    const Signal = struct { name: []const u8, sig: []const f32 };
    const signals = [_]Signal{
        .{ .name = "silence", .sig = silence },
        .{ .name = "dc", .sig = dc },
        .{ .name = "noise -6dBFS", .sig = noisy },
        .{ .name = "square", .sig = square },
        .{ .name = "bursts", .sig = bursts },
    };
    var cfg: Settings = .{};
    cfg.harmony_on = true;
    cfg.delay_on = true;
    const tail_in = try zeros(gpa, secs(2.0));
    defer gpa.free(tail_in);
    for (signals) |s| {
        var chain = try VocalChain.init(gpa, RATE, &cfg);
        defer chain.deinit(gpa);
        const t0 = cpuSeconds();
        const out = try runWith(gpa, &chain, &cfg, s.sig);
        defer gpa.free(out);
        // Keep running on silence: denormal storms show up in decaying tails.
        const tail = try runWith(gpa, &chain, &cfg, tail_in);
        defer gpa.free(tail);
        const block_count: f64 = @floatFromInt((out.len + tail.len) / BLOCK);
        const per_block_ms = (cpuSeconds() - t0) * 1e3 / block_count;
        log.info("qa safety: {s:<13} peak {d:>7.2} dBFS  {d:.2} ms/block cpu", .{ s.name, db(peak(out)), per_block_ms });
        try check(allFinite(out) and allFinite(tail), "{s}: non-finite output", .{s.name});
        // Seridian: a CPU budget is only meaningful on optimised code (the
        // Rust crate builds at opt-level 3 even in dev); Debug skips it.
        if (!skipTimingInDebug()) {
            try check(per_block_ms < 10.0, "{s}: {d:.2} ms per block (denormals?)", .{ s.name, per_block_ms });
        }
    }

    // Silence in -> silence out once tails clear (space off).
    {
        const quiet: Settings = .{ .space_on = false };
        const v = try voice(gpa, 220.0, 0.5, 0.5);
        defer gpa.free(v);
        const z = try zeros(gpa, secs(3.0));
        defer gpa.free(z);
        const sig = try concat(gpa, v, z);
        defer gpa.free(sig);
        const out = try run(gpa, &quiet, sig);
        defer gpa.free(out);
        const floor = db(rms(out[secs(3.0)..]));
        log.info("qa safety: silence after voice (space off) {d:.1} dBFS", .{floor});
        try check(floor <= -90.0, "residual {d:.1} dBFS after silence", .{floor});
    }

    // Reverb tail below -60 dBFS within decay*1.5 + 1 s of the burst end.
    {
        const wet: Settings = .{ .reverb_mix = 0.5 };
        const v = try voice(gpa, 220.0, 0.5, 0.5);
        defer gpa.free(v);
        const end = v.len;
        const z = try zeros(gpa, secs(6.0));
        defer gpa.free(z);
        const sig = try concat(gpa, v, z);
        defer gpa.free(sig);
        const out = try run(gpa, &wet, sig);
        defer gpa.free(out);
        const deadline = end + secs(wet.reverb_decay_s * 1.5 + 1.0);
        const window = out[deadline .. deadline + secs(0.1)];
        const level = db(rms(window));
        log.info("qa safety: reverb {d:.1}s tail at {d:.2}s after end = {d:.1} dBFS", .{ wet.reverb_decay_s, wet.reverb_decay_s * 1.5 + 1.0, level });
        try check(level <= -60.0, "reverb tail still {d:.1} dBFS", .{level});
    }
}

// 5. Reported latency matches the measured impulse delay; takes line up.
test "qa_latency_and_take_alignment" {
    const gpa = testing.allocator;
    const io = testing.io;
    var cfg = dryCfg();
    cfg.tune_on = false;
    const latency = blk: {
        var chain = try VocalChain.init(gpa, RATE, &cfg);
        defer chain.deinit(gpa);
        break :blk chain.latencySamples();
    };
    // Broadband noise + cross-correlation: robust for a phase vocoder,
    // which smears single impulses.
    {
        const sig = try noise(gpa, secs(1.0), 0.3, 21);
        defer gpa.free(sig);
        const out = try run(gpa, &cfg, sig);
        defer gpa.free(out);
        const span_lo = secs(0.3);
        const span_hi = secs(0.6);
        // Rust `max_by` keeps the last maximum.
        var measured: i64 = 0;
        var best: f32 = -std.math.inf(f32);
        for (0..6000) |lag| {
            var xc: f32 = 0.0;
            for (span_lo..span_hi) |i| xc += sig[i] * out[i + lag];
            if (xc >= best) {
                best = xc;
                measured = @intCast(lag);
            }
        }
        log.info("qa latency: reported {d} samples, measured {d}", .{ latency, measured });
        const lat_i: i64 = @intCast(latency);
        try check(@abs(measured - lat_i) <= 2, "latency {d} != reported {d}", .{ measured, latency });
    }

    // Take.save: processed + raw files, same length, sample-aligned.
    // Rust: a temp dir that also stands in for `$HOME`.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Broadband: a periodic tone only pins alignment modulo its period
    // (and the phase vocoder rewrites phases even at ratio 1).
    const sig = try noise(gpa, secs(1.0), 0.3, 33);
    defer gpa.free(sig);
    var chain = try VocalChain.init(gpa, RATE, &cfg);
    defer chain.deinit(gpa);
    chain.configure(&cfg);
    var take = try takes.Take.init(gpa, RATE, chain.latencySamples());
    defer take.deinit(gpa);
    var block: [BLOCK]f32 = undefined;
    var wet_block: [BLOCK]f32 = undefined;
    var off: usize = 0;
    while (off + BLOCK <= sig.len) : (off += BLOCK) {
        @memcpy(&block, sig[off .. off + BLOCK]);
        _ = try chain.process(&block, &wet_block, &cfg);
        try take.push(gpa, &block, &wet_block);
    }
    const dir_path = try takes.takesDir(gpa, ".");
    defer gpa.free(dir_path);
    const now = std.Io.Clock.real.now(io).toSeconds();
    const wet_path = try take.save(gpa, io, tmp.dir, dir_path, now);
    defer gpa.free(wet_path);
    const raw_path = try std.mem.replaceOwned(u8, gpa, wet_path, ".wav", "-raw.wav");
    defer gpa.free(raw_path);
    var wet_audio = try wav.readWav(gpa, io, tmp.dir, wet_path);
    defer wet_audio.deinit(gpa);
    var raw_audio = try wav.readWav(gpa, io, tmp.dir, raw_path);
    defer raw_audio.deinit(gpa);
    const wet = wet_audio.samples;
    const raw = raw_audio.samples;
    log.info("qa take: raw {d} samples, processed {d}", .{ raw.len, wet.len });
    try check(raw.len == wet.len, "take files differ in length", .{});
    const n = wet.len - 4096;
    var best_lag: i64 = 0;
    var best: f32 = -std.math.inf(f32);
    var lag: i64 = -50;
    while (lag <= 50) : (lag += 1) {
        var xc: f32 = 0.0;
        for (2048..n) |i| {
            const j: usize = @intCast(@as(i64, @intCast(i)) + lag);
            xc += raw[i] * wet[j];
        }
        if (xc >= best) {
            best = xc;
            best_lag = lag;
        }
    }
    log.info("qa take: cross-correlation peak at lag {d}", .{best_lag});
    try check(@abs(best_lag) <= 2, "take misaligned by {d} samples", .{best_lag});
}

// 6. Bypass passes the (gained) input untouched, at the chain latency so
// toggling it never jumps in time.
test "qa_bypass_is_clean" {
    const gpa = testing.allocator;
    for ([_]f32{ 0.0, -6.0 }) |gain_db| {
        const cfg: Settings = .{ .bypass = true, .input_gain_db = gain_db };
        const sig = try voice(gpa, 300.0, 1.0, 0.4);
        defer gpa.free(sig);
        const latency = blk: {
            var chain = try VocalChain.init(gpa, RATE, &cfg);
            defer chain.deinit(gpa);
            break :blk chain.latencySamples();
        };
        const out = try run(gpa, &cfg, sig);
        defer gpa.free(out);
        const g = std.math.pow(f32, 10.0, gain_db / 20.0);
        var worst: f32 = 0.0;
        for (0..sig.len - latency) |i| worst = @max(worst, @abs(out[i + latency] - sig[i] * g));
        log.info("qa bypass: gain {d} dB, latency {d}, max error {e}", .{ gain_db, latency, worst });
        try check(worst <= 1e-6, "bypass altered the signal by {e}", .{worst});
    }
}

// 7. Each stage switch does something when on, and switching it off is
// clean (finite, no change beyond that stage).
test "qa_stage_switches" {
    const gpa = testing.allocator;
    const sig = try voice(gpa, midiHz(64.0) * std.math.pow(f32, 2.0, -30.0 / 1200.0), 2.0, 0.4);
    defer gpa.free(sig);
    const nz = try noise(gpa, secs(2.0), 0.05, 11);
    defer gpa.free(nz);
    for (sig, nz) |*s, v| s.* += v;
    var base = dryCfg();
    base.tune_on = false;
    const reference = try run(gpa, &base, sig);
    defer gpa.free(reference);

    var isolate = base;
    isolate.isolate_on = true;
    isolate.isolate_db = 24.0;
    var tune = base;
    tune.tune_on = true;
    var harmony = base;
    harmony.harmony_on = true;
    harmony.harmony_level = 0.7;
    var eq = base;
    eq.eq_on = true;
    eq.eq_amount = 1.0;
    eq.eq_air_db = 4.0;
    var dynamics = base;
    dynamics.dynamics_on = true;
    dynamics.tape_drive = 0.7;
    dynamics.rider_target_db = -10.0;
    var space = base;
    space.space_on = true;
    space.reverb_mix = 0.4;
    space.delay_on = true;
    const Stage = struct { name: []const u8, cfg: Settings };
    const stages = [_]Stage{
        .{ .name = "isolate", .cfg = isolate },
        .{ .name = "tune", .cfg = tune },
        .{ .name = "harmony", .cfg = harmony },
        .{ .name = "eq", .cfg = eq },
        .{ .name = "dynamics", .cfg = dynamics },
        .{ .name = "space", .cfg = space },
    };
    const lo = secs(0.8);
    const hi = secs(1.9);
    const diff = try gpa.alloc(f32, hi - lo);
    defer gpa.free(diff);
    for (stages) |st| {
        const out = try run(gpa, &st.cfg, sig);
        defer gpa.free(out);
        try check(allFinite(out), "{s}: non-finite output", .{st.name});
        for (diff, out[lo..hi], reference[lo..hi]) |*d, a, b| d.* = a - b;
        const change = db(rms(diff) / rms(reference[lo..hi]));
        log.info("qa switch: {s:<8} on changes output by {d:.1} dB", .{ st.name, change });
        try check(change > -40.0, "{s}: switching on had no measurable effect", .{st.name});
    }
    // Off again is identical to the reference (fresh chain, same input).
    const again = try run(gpa, &base, sig);
    defer gpa.free(again);
    try testing.expectEqualSlices(f32, reference, again);
}

// 8. Third-above harmony on E4 in C major sings G4.
test "qa_harmony_third" {
    const gpa = testing.allocator;
    const lead = midiHz(64.0);
    const g4 = midiHz(67.0);
    const sig = try voice(gpa, lead, 2.0, 0.4);
    defer gpa.free(sig);
    var on = dryCfg();
    on.harmony_on = true;
    on.harmony_mode = .third_above;
    on.harmony_level = 0.6;
    const out = try run(gpa, &on, sig);
    defer gpa.free(out);
    const w = out[secs(1.0)..secs(1.9)];
    const rel = db(goertzel(w, g4) / goertzel(w, lead));
    const dry = dryCfg();
    const without = try run(gpa, &dry, sig);
    defer gpa.free(without);
    const w0 = without[secs(1.0)..secs(1.9)];
    const rel0 = db(goertzel(w0, g4) / goertzel(w0, lead));
    log.info("qa harmony: G4 vs E4 = {d:.1} dB with harmony, {d:.1} dB without", .{ rel, rel0 });
    try check(rel >= -20.0, "harmony third too weak: {d:.1} dB", .{rel});
    try check(rel - rel0 >= 15.0, "harmony did not add the third", .{});
}

// 9. Full chain (everything on) runs well inside real time.
test "qa_realtime_budget" {
    // Seridian: the budget is defined for optimised code (the Rust crate
    // builds at opt-level 3 even in dev); a Debug build measures the
    // compiler's safety checks, not the DSP. Run with -O ReleaseFast.
    if (skipTimingInDebug()) return error.SkipZigTest;
    const gpa = testing.allocator;
    const cfg: Settings = .{
        .harmony_on = true,
        .harmony_mode = .third_and_fifth,
        .delay_on = true,
        .formant_semis = 2.0,
    };
    var sig: std.ArrayList(f32) = .empty;
    defer sig.deinit(gpa);
    for ([_]f32{ 57.0, 60.0, 64.0, 62.0, 60.0 }) |note| {
        const v = try voice(gpa, midiHz(note), 2.0, 0.4);
        defer gpa.free(v);
        try sig.appendSlice(gpa, v);
    }
    var chain = try VocalChain.init(gpa, RATE, &cfg);
    defer chain.deinit(gpa);
    const t0 = cpuSeconds();
    const out = try runWith(gpa, &chain, &cfg, sig.items);
    defer gpa.free(out);
    const ratio = (cpuSeconds() - t0) / (@as(f64, @floatFromInt(sig.items.len)) / @as(f64, @floatFromInt(RATE)));
    log.info("qa realtime: full chain {d:.1}% of real time (cpu)", .{ratio * 100.0});
    try check(allFinite(out), "non-finite output", .{});
    try check(ratio < 0.5, "full chain uses {d:.0}% of real time", .{ratio * 100.0});
}

// 10. Rendering the same file twice is bit-identical.
test "qa_offline_render_determinism" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const samples = try voice(gpa, midiHz(62.0) * 1.01, 1.5, 0.4);
    defer gpa.free(samples);
    const nz = try noise(gpa, secs(1.5), 0.03, 5);
    defer gpa.free(nz);
    for (samples, nz) |*s, v| s.* += v;
    try wav.writeWav(io, tmp.dir, "vox.wav", &.{ .sample_rate = RATE, .channels = 1, .samples = samples });
    const cfg: Settings = .{ .harmony_on = true, .delay_on = true };
    var progress = std.atomic.Value(u32).init(0);
    var r1 = try takes.processFile(gpa, io, tmp.dir, "vox.wav", ".", &cfg, &progress);
    defer r1.deinit(gpa);
    var first = try wav.readWav(gpa, io, tmp.dir, r1.out_path);
    defer first.deinit(gpa);
    var r2 = try takes.processFile(gpa, io, tmp.dir, "vox.wav", ".", &cfg, &progress);
    defer r2.deinit(gpa);
    var second = try wav.readWav(gpa, io, tmp.dir, r2.out_path);
    defer second.deinit(gpa);
    const identical = std.mem.eql(f32, first.samples, second.samples);
    log.info("qa determinism: {d} samples, identical = {}", .{ first.samples.len, identical });
    try testing.expectEqual(secs(1.5), first.samples.len);
    try check(identical, "offline render is not deterministic", .{});
}
