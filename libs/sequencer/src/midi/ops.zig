// Translated to Zig from soundcraft/crates/midi/src/ops.rs, soundcraft/crates/midi/tests/it/ops.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! MIDI editing operations (event operations): quantize, transpose, velocity, duration, split.
//!
//! All operations work in place on a slice of notes and never change the slice length, so they
//! can be applied to a selection. Randomised operations use a deterministic `XorShift` seeded
//! with `default_seed` (or an explicit seed via the `*WithSeed` variants).
//!
//! Control thread only: these edit a `Sequence` on the editing side and are never called from
//! the audio thread. The operations that need scratch space (`changeDuration` for Legato and
//! RemoveOverlap, `splitNotes`) take an allocator; they are the only ones that can fail.

const std = @import("std");
const testing = std.testing;
const sequence = @import("sequence.zig");
const rng_mod = @import("rng.zig");

const Allocator = std.mem.Allocator;
const Note = sequence.Note;
const Sequence = sequence.Sequence;
const CtrlEvent = sequence.CtrlEvent;
const CtrlKind = sequence.CtrlKind;
const XorShift = rng_mod.XorShift;

/// Seed used by `quantize` and `changeVelocity` for their random components.
pub const default_seed: u64 = 0x5EED_50DC_4AF7_0001;

/// Clamps a float to 0..=1; non-finite values become 0.
fn unit(x: f32) f64 {
    if (!std.math.isFinite(x)) return 0.0;
    return std.math.clamp(@as(f64, x), 0.0, 1.0);
}

/// Rounds half away from zero (like Rust `f64::round`) and saturates to the i64 range.
/// Non-finite input gives 0.
fn roundI64(x: f64) i64 {
    if (!std.math.isFinite(x)) return 0;
    const r = @round(x);
    // 2^63 is exactly representable; i64::MAX as f64 rounds up to it.
    if (r >= 9223372036854775808.0) return std.math.maxInt(i64);
    if (r <= -9223372036854775808.0) return std.math.minInt(i64);
    return @intFromFloat(r);
}

/// Options for `quantize`.
pub const QuantizeOptions = struct {
    /// Grid spacing in ticks (e.g. 240 = 1/16 note at 960 PPQ). Values <= 0 make quantize a no-op.
    grid_ticks: i64 = 240,
    /// How far notes move towards the grid line, 0..=1 (1 = all the way).
    strength: f32 = 1.0,
    /// Swing, 0..=1: every second grid line is delayed by `swing * grid / 3`, so 1.0 gives a
    /// triplet feel.
    swing: f32 = 0.0,
    /// Only notes within this fraction of half a grid step of their target are moved
    /// (1 = all notes).
    include_within: f32 = 1.0,
    /// Notes closer than this fraction of half a grid step to their target are left alone
    /// (0 = none excluded).
    exclude_within: f32 = 0.0,
    /// Also quantize note ends to the grid.
    quantize_ends: bool = false,
    /// Keep each note's length when its start moves (otherwise the end stays put). Ignored when
    /// `quantize_ends` is set.
    preserve_duration: bool = true,
    /// Random offset after quantizing, 0..=1 fraction of half a grid step.
    random: f32 = 0.0,
};

/// The swung grid line nearest to `t`. `grid` must be > 0.
fn nearestLine(t: i64, grid: i64, swing: f64) i64 {
    const swing_off = roundI64(swing * @as(f64, @floatFromInt(grid)) / 3.0);
    // div_euclid with a positive divisor is floor division.
    const k = @divFloor(t +| @divTrunc(grid, 2), grid);
    var best: i64 = std.math.maxInt(i64);
    var best_d: u64 = std.math.maxInt(u64);
    const candidates = [3]i64{ k -| 1, k, k +| 1 };
    for (candidates) |kk| {
        const off: i64 = if (@mod(kk, 2) == 1) swing_off else 0;
        const line = (kk *| grid) +| off;
        const diff: i128 = @as(i128, line) - @as(i128, t);
        const d: u64 = @intCast(@abs(diff));
        if (d < best_d) {
            best_d = d;
            best = line;
        }
    }
    return best;
}

/// End tick of the note's new length when only its end is quantized, or the length rule
/// otherwise. Helper for `quantizeWithSeed`.
fn quantizedLength(note: Note, opts: QuantizeOptions, grid: i64, swing: f64, strength: f64, new_start: i64, old_end: i64) i64 {
    if (opts.quantize_ends) {
        const end_target = nearestLine(old_end, grid, swing);
        const delta = roundI64(@as(f64, @floatFromInt(end_target -| old_end)) * strength);
        const new_end = old_end +| delta;
        return new_end -| new_start;
    }
    if (opts.preserve_duration) return note.length;
    return old_end -| new_start;
}

/// Quantizes note starts (and optionally ends) to a grid. See `QuantizeOptions`.
pub fn quantize(notes: []Note, opts: QuantizeOptions) void {
    quantizeWithSeed(notes, opts, default_seed);
}

/// `quantize` with an explicit seed for the `random` component.
pub fn quantizeWithSeed(notes: []Note, opts: QuantizeOptions, seed: u64) void {
    const grid = opts.grid_ticks;
    if (grid <= 0) return;
    const strength = unit(opts.strength);
    const swing = unit(opts.swing);
    const include = unit(opts.include_within);
    const exclude = unit(opts.exclude_within);
    const random = unit(opts.random);
    const half: f64 = @as(f64, @floatFromInt(grid)) / 2.0;
    var rng = XorShift.init(seed);

    for (notes) |*n| {
        const old_start = n.start;
        const old_end = n.end();
        const target = nearestLine(old_start, grid, swing);
        const d: i64 = target -| old_start;
        const dist: f64 = @floatFromInt(@abs(d));
        if (include < 1.0 and dist > include * half) continue;
        if (dist < exclude * half) continue;
        var new_start = old_start +| roundI64(@as(f64, @floatFromInt(d)) * strength);
        if (random > 0.0) {
            new_start = new_start +| roundI64(rng.nextSigned() * random * half);
        }
        n.start = new_start;
        const len = quantizedLength(n.*, opts, grid, swing, strength, new_start, old_end);
        n.length = @max(len, 1);
    }
}

/// Transposes notes by `semitones`. Pitches are **clamped** to 0..=127 (notes are never
/// dropped, so the slice length is unchanged); notes pushed past either end pile up on 0 or 127.
pub fn transpose(notes: []Note, semitones: i32) void {
    for (notes) |*n| {
        const p = @as(i32, n.pitch) +| semitones;
        n.pitch = @intCast(std.math.clamp(p, 0, 127));
    }
}

/// Velocity change for `changeVelocity`. Results are clamped to 1..=127.
pub const VelocityOp = union(enum) {
    set: u8,
    add: i32,
    /// Multiply (non-finite factors leave velocities unchanged).
    scale: f32,
    /// Clamp into `min..=max` (bounds are swapped if reversed).
    limit: struct { min: u8, max: u8 },
    /// Linear ramp over the notes' time span: the earliest note gets `from`, the latest `to`.
    ramp: struct { from: u8, to: u8 },
    /// Random offset of up to +/- the amount.
    humanize: u8,
};

fn clampVel(v: i64) u8 {
    return @intCast(std.math.clamp(v, 1, 127));
}

/// Changes note-on velocities. See `VelocityOp`.
pub fn changeVelocity(notes: []Note, op: VelocityOp) void {
    changeVelocityWithSeed(notes, op, default_seed);
}

/// `changeVelocity` with an explicit seed for `VelocityOp.humanize`.
pub fn changeVelocityWithSeed(notes: []Note, op: VelocityOp, seed: u64) void {
    switch (op) {
        .set => |v| {
            for (notes) |*n| n.velocity = clampVel(@as(i64, v));
        },
        .add => |d| {
            for (notes) |*n| n.velocity = clampVel(@as(i64, n.velocity) + @as(i64, d));
        },
        .scale => |f| {
            if (std.math.isFinite(f)) {
                for (notes) |*n| {
                    n.velocity = clampVel(roundI64(@as(f64, @floatFromInt(n.velocity)) * @as(f64, f)));
                }
            }
        },
        .limit => |l| {
            const lo = @min(l.min, l.max);
            const hi = @max(l.min, l.max);
            for (notes) |*n| n.velocity = clampVel(@as(i64, std.math.clamp(n.velocity, lo, hi)));
        },
        .ramp => |r| {
            var first: i64 = 0;
            var last: i64 = 0;
            if (notes.len > 0) {
                first = notes[0].start;
                last = notes[0].start;
                for (notes[1..]) |n| {
                    first = @min(first, n.start);
                    last = @max(last, n.start);
                }
            }
            const span: f64 = @floatFromInt(@as(i128, last) - @as(i128, first));
            const from: f64 = @floatFromInt(r.from);
            const to: f64 = @floatFromInt(r.to);
            for (notes) |*n| {
                const offset: f64 = @floatFromInt(@as(i128, n.start) - @as(i128, first));
                const t: f64 = if (span > 0.0) offset / span else 0.0;
                const v = from + (to - from) * t;
                n.velocity = clampVel(roundI64(v));
            }
        },
        .humanize => |amount| {
            var rng = XorShift.init(seed);
            const amt: f64 = @floatFromInt(amount);
            for (notes) |*n| {
                const d = roundI64(rng.nextSigned() * amt);
                n.velocity = clampVel(@as(i64, n.velocity) + d);
            }
        },
    }
}

/// Duration change for `changeDuration`. Lengths are always kept >= 1 tick.
pub const DurationOp = union(enum) {
    set: i64,
    add: i64,
    /// Multiply (non-finite factors leave lengths unchanged).
    scale: f32,
    /// Each note extends to `gap` ticks before the next later note start (any pitch). The last
    /// note(s) keep their length.
    legato: struct { gap: i64 },
    /// Shortens notes so they end no later than the next note of the same pitch and channel.
    remove_overlap,
};

fn lessI64(_: void, a: i64, b: i64) bool {
    return a < b;
}

/// Index of the first element greater than `key` in a sorted slice.
fn upperBound(sorted: []const i64, key: i64) usize {
    var lo: usize = 0;
    var hi: usize = sorted.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (sorted[mid] <= key) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Legato: each note runs to `gap` ticks before the next distinct start after its own start.
fn legato(gpa: Allocator, notes: []Note, gap: i64) Allocator.Error!void {
    if (notes.len == 0) return;
    const starts = try gpa.alloc(i64, notes.len);
    defer gpa.free(starts);
    for (notes, 0..) |n, i| starts[i] = n.start;
    std.mem.sort(i64, starts, {}, lessI64);
    // Dedup in place: keep the first of each run of equal starts.
    var m: usize = 0;
    for (starts) |s| {
        if (m == 0 or starts[m - 1] != s) {
            starts[m] = s;
            m += 1;
        }
    }
    const uniq = starts[0..m];
    for (notes) |*n| {
        const idx = upperBound(uniq, n.start);
        if (idx < uniq.len) {
            const next = uniq[idx];
            n.length = @max((next -| gap) -| n.start, 1);
        }
    }
}

/// Order for RemoveOverlap: (channel, pitch, start), then original index. The index tie-break
/// makes the unstable `std.mem.sort` behave like the stable `sort_by_key` in Rust.
fn overlapOrderLess(ctx: []const Note, a: usize, b: usize) bool {
    const na = ctx[a];
    const nb = ctx[b];
    if (na.channel != nb.channel) return na.channel < nb.channel;
    if (na.pitch != nb.pitch) return na.pitch < nb.pitch;
    if (na.start != nb.start) return na.start < nb.start;
    return a < b;
}

/// RemoveOverlap: within each (channel, pitch) run, a note ends no later than the next one starts.
fn removeOverlap(gpa: Allocator, notes: []Note) Allocator.Error!void {
    if (notes.len == 0) return;
    const order = try gpa.alloc(usize, notes.len);
    defer gpa.free(order);
    for (order, 0..) |*o, i| o.* = i;
    const view: []const Note = notes;
    std.mem.sort(usize, order, view, overlapOrderLess);
    var k: usize = 0;
    while (k + 1 < order.len) : (k += 1) {
        const a = order[k];
        const nb = notes[order[k + 1]];
        const na = &notes[a];
        if (na.channel == nb.channel and na.pitch == nb.pitch and na.end() > nb.start) {
            na.length = @max(nb.start -| na.start, 1);
        }
    }
}

/// Changes note lengths. See `DurationOp`. `gpa` is used for scratch space by `legato` and
/// `remove_overlap` only; the other operations do not allocate.
pub fn changeDuration(gpa: Allocator, notes: []Note, op: DurationOp) Allocator.Error!void {
    switch (op) {
        .set => |l| {
            for (notes) |*n| n.length = @max(l, 1);
        },
        .add => |d| {
            for (notes) |*n| n.length = @max(n.length +| d, 1);
        },
        .scale => |f| {
            if (std.math.isFinite(f)) {
                for (notes) |*n| {
                    n.length = @max(roundI64(@as(f64, @floatFromInt(n.length)) * @as(f64, f)), 1);
                }
            }
        },
        .legato => |l| try legato(gpa, notes, l.gap),
        .remove_overlap => try removeOverlap(gpa, notes),
    }
}

/// Result of `splitNotes`: the notes inside the pitch range and the rest, both in input order.
/// Owns its storage; call `deinit`.
pub const Split = struct {
    inside: std.ArrayList(Note) = .empty,
    outside: std.ArrayList(Note) = .empty,

    pub fn deinit(self: *Split, gpa: Allocator) void {
        self.inside.deinit(gpa);
        self.outside.deinit(gpa);
    }
};

/// Select/Split Notes by pitch: returns the notes with pitch in `pitch_from..=pitch_to` and the
/// rest, both in input order. The bounds are swapped if reversed.
pub fn splitNotes(gpa: Allocator, notes: []const Note, pitch_from: u8, pitch_to: u8) Allocator.Error!Split {
    const lo = @min(pitch_from, pitch_to);
    const hi = @max(pitch_from, pitch_to);
    var out: Split = .{};
    errdefer out.deinit(gpa);
    for (notes) |n| {
        if (n.pitch >= lo and n.pitch <= hi) {
            try out.inside.append(gpa, n);
        } else {
            try out.outside.append(gpa, n);
        }
    }
    return out;
}

// --- Tests: ported from soundcraft/crates/midi/tests/it/ops.rs (in the same order).

fn mk(pitch: u8, start: i64, length: i64) Note {
    return .{ .pitch = pitch, .velocity = 100, .release_velocity = 64, .channel = 0, .start = start, .length = length };
}

fn nch(pitch: u8, start: i64, length: i64, channel: u8) Note {
    var note = mk(pitch, start, length);
    note.channel = channel;
    return note;
}

fn expectStarts(notes: []const Note, expected: []const i64) !void {
    try testing.expectEqual(expected.len, notes.len);
    for (notes, expected) |note, e| try testing.expectEqual(e, note.start);
}

fn expectLengths(notes: []const Note, expected: []const i64) !void {
    try testing.expectEqual(expected.len, notes.len);
    for (notes, expected) |note, e| try testing.expectEqual(e, note.length);
}

fn expectVelocities(notes: []const Note, expected: []const u8) !void {
    try testing.expectEqual(expected.len, notes.len);
    for (notes, expected) |note, e| try testing.expectEqual(e, note.velocity);
}

fn expectPitches(notes: []const Note, expected: []const u8) !void {
    try testing.expectEqual(expected.len, notes.len);
    for (notes, expected) |note, e| try testing.expectEqual(e, note.pitch);
}

fn sliceEql(a: []const Note, b: []const Note) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.pitch != y.pitch or x.velocity != y.velocity or x.release_velocity != y.release_velocity or
            x.channel != y.channel or x.start != y.start or x.length != y.length) return false;
    }
    return true;
}

test "quantize_full_strength" {
    var notes = [_]Note{ mk(60, 10, 200), mk(60, 230, 100), mk(60, 365, 50), mk(60, -20, 40) };
    quantize(&notes, .{ .grid_ticks = 240 });
    try expectStarts(&notes, &[_]i64{ 0, 240, 480, 0 });
    // Durations preserved by default.
    try expectLengths(&notes, &[_]i64{ 200, 100, 50, 40 });
}

test "quantize_half_strength" {
    var notes = [_]Note{ mk(60, 20, 100), mk(60, 220, 100) };
    quantize(&notes, .{ .grid_ticks = 240, .strength = 0.5 });
    try expectStarts(&notes, &[_]i64{ 10, 230 });
}

test "quantize_swing" {
    // 100% swing on a 1/8 (480) grid moves odd lines by 480/3 = 160 (triplet feel).
    var notes = [_]Note{ mk(60, 0, 10), mk(60, 470, 10), mk(60, 650, 10), mk(60, 950, 10) };
    quantize(&notes, .{ .grid_ticks = 480, .swing = 1.0 });
    try expectStarts(&notes, &[_]i64{ 0, 640, 640, 960 });
    var one = [_]Note{mk(60, 480, 10)};
    quantize(&one, .{ .grid_ticks = 480, .swing = 0.5 });
    try expectStarts(&one, &[_]i64{560});
}

test "quantize_include_exclude" {
    // Half grid = 120; include within 60 ticks.
    const include_opts: QuantizeOptions = .{ .grid_ticks = 240, .include_within = 0.5 };
    var notes = [_]Note{ mk(60, 50, 10), mk(60, 100, 10) };
    quantize(&notes, include_opts);
    try expectStarts(&notes, &[_]i64{ 0, 100 });

    // Exclude closer than 30 ticks.
    const exclude_opts: QuantizeOptions = .{ .grid_ticks = 240, .exclude_within = 0.25 };
    var notes2 = [_]Note{ mk(60, 20, 10), mk(60, 50, 10) };
    quantize(&notes2, exclude_opts);
    try expectStarts(&notes2, &[_]i64{ 20, 0 });
}

test "quantize_ends_and_duration" {
    var notes = [_]Note{mk(60, 10, 220)};
    quantize(&notes, .{ .grid_ticks = 240, .quantize_ends = true });
    try testing.expectEqual(@as(i64, 0), notes[0].start);
    try testing.expectEqual(@as(i64, 240), notes[0].length);

    var notes2 = [_]Note{mk(60, 10, 220)};
    quantize(&notes2, .{ .grid_ticks = 240, .preserve_duration = false });
    try testing.expectEqual(@as(i64, 0), notes2[0].start);
    try testing.expectEqual(@as(i64, 230), notes2[0].length);

    // Ends quantized onto the start line still keep a length of at least 1.
    var notes3 = [_]Note{mk(60, 10, 5)};
    quantize(&notes3, .{ .grid_ticks = 240, .quantize_ends = true });
    try testing.expectEqual(@as(i64, 1), notes3[0].length);
}

test "quantize_random_is_deterministic_and_bounded" {
    const opts: QuantizeOptions = .{ .grid_ticks = 240, .random = 0.5 };
    var a: [50]Note = undefined;
    for (&a, 0..) |*note, i| note.* = mk(60, @as(i64, @intCast(i)) * 240 + 7, 10);
    var b = a;
    quantize(&a, opts);
    quantize(&b, opts);
    try testing.expect(sliceEql(&a, &b));
    for (a, 0..) |note, i| {
        const expected: i64 = @as(i64, @intCast(i)) * 240;
        const diff: u64 = @abs(note.start - expected);
        try testing.expect(diff <= 60);
    }
    var c: [50]Note = undefined;
    for (&c, 0..) |*note, i| note.* = mk(60, @as(i64, @intCast(i)) * 240 + 7, 10);
    quantizeWithSeed(&c, opts, 42);
    try testing.expect(!sliceEql(&a, &c));
}

test "quantize_degenerate_options" {
    var notes = [_]Note{mk(60, 17, 10)};
    quantize(&notes, .{ .grid_ticks = 0 });
    quantize(&notes, .{ .grid_ticks = -5 });
    try testing.expectEqual(@as(i64, 17), notes[0].start);
    quantize(&notes, .{ .grid_ticks = 240, .strength = std.math.nan(f32), .swing = std.math.inf(f32) });
    try testing.expectEqual(@as(i64, 17), notes[0].start);
    var extreme = [_]Note{ mk(60, std.math.maxInt(i64) - 10, 1), mk(60, std.math.minInt(i64) + 10, 1) };
    quantize(&extreme, .{ .grid_ticks = std.math.maxInt(i64), .random = 1.0 });
}

test "transpose_clamps" {
    var notes = [_]Note{ mk(0, 0, 1), mk(60, 0, 1), mk(127, 0, 1) };
    transpose(&notes, 12);
    try expectPitches(&notes, &[_]u8{ 12, 72, 127 });
    transpose(&notes, -100);
    try expectPitches(&notes, &[_]u8{ 0, 0, 27 });
    transpose(&notes, std.math.maxInt(i32));
    for (notes) |note| try testing.expectEqual(@as(u8, 127), note.pitch);
}

test "ramp_full_tick_range" {
    var notes = [_]Note{ mk(60, std.math.minInt(i64), 1), mk(60, 0, 1), mk(60, std.math.maxInt(i64), 1) };
    changeVelocity(&notes, .{ .ramp = .{ .from = 1, .to = 127 } });
    try expectVelocities(&notes, &[_]u8{ 1, 64, 127 });
}

test "velocity_ops" {
    const base = [_]Note{ mk(60, 0, 1), mk(60, 100, 1), mk(60, 200, 1) };

    var v = base;
    changeVelocity(&v, .{ .set = 0 });
    try expectVelocities(&v, &[_]u8{ 1, 1, 1 });
    changeVelocity(&v, .{ .set = 200 });
    try expectVelocities(&v, &[_]u8{ 127, 127, 127 });

    var v2 = base;
    changeVelocity(&v2, .{ .add = 50 });
    try expectVelocities(&v2, &[_]u8{ 127, 127, 127 });
    changeVelocity(&v2, .{ .add = -500 });
    try expectVelocities(&v2, &[_]u8{ 1, 1, 1 });

    var v3 = base;
    changeVelocity(&v3, .{ .scale = 0.5 });
    try expectVelocities(&v3, &[_]u8{ 50, 50, 50 });
    changeVelocity(&v3, .{ .scale = std.math.nan(f32) });
    try expectVelocities(&v3, &[_]u8{ 50, 50, 50 });

    var v4 = [_]Note{ mk(60, 0, 1), mk(60, 0, 1) };
    v4[0].velocity = 10;
    v4[1].velocity = 120;
    changeVelocity(&v4, .{ .limit = .{ .min = 100, .max = 30 } });
    try expectVelocities(&v4, &[_]u8{ 30, 100 });

    var v5 = base;
    changeVelocity(&v5, .{ .ramp = .{ .from = 20, .to = 120 } });
    try expectVelocities(&v5, &[_]u8{ 20, 70, 120 });

    var a = base;
    var b = base;
    changeVelocity(&a, .{ .humanize = 10 });
    changeVelocity(&b, .{ .humanize = 10 });
    try testing.expect(sliceEql(&a, &b));
    for (a) |note| try testing.expect(note.velocity >= 90 and note.velocity <= 110);
}

test "duration_ops" {
    const base = [_]Note{ mk(60, 0, 100), mk(62, 480, 100), mk(64, 480, 50), mk(60, 960, 100) };

    var v = base;
    try changeDuration(testing.allocator, &v, .{ .set = 0 });
    try expectLengths(&v, &[_]i64{ 1, 1, 1, 1 });

    var v2 = base;
    try changeDuration(testing.allocator, &v2, .{ .add = -75 });
    try expectLengths(&v2, &[_]i64{ 25, 25, 1, 25 });

    var v3 = base;
    try changeDuration(testing.allocator, &v3, .{ .scale = 2.0 });
    try expectLengths(&v3, &[_]i64{ 200, 200, 100, 200 });

    var v4 = base;
    try changeDuration(testing.allocator, &v4, .{ .legato = .{ .gap = 10 } });
    try expectLengths(&v4, &[_]i64{ 470, 470, 470, 100 });

    var v5 = [_]Note{ mk(60, 0, 500), mk(60, 200, 500), mk(61, 100, 500), nch(60, 100, 500, 1) };
    try changeDuration(testing.allocator, &v5, .remove_overlap);
    try expectLengths(&v5, &[_]i64{ 200, 500, 500, 500 });
}

test "split_by_pitch" {
    const notes = [_]Note{ mk(36, 0, 1), mk(60, 1, 1), mk(72, 2, 1), mk(48, 3, 1) };
    var parts = try splitNotes(testing.allocator, &notes, 60, 40);
    defer parts.deinit(testing.allocator);
    try expectPitches(parts.inside.items, &[_]u8{ 60, 48 });
    try expectPitches(parts.outside.items, &[_]u8{ 36, 72 });
}

test "sequence_helpers" {
    // Ported as-is from the Rust test. Its checks exercise `Sequence` (midi/sequence.zig, ported
    // with midi-1), which this file reuses; kept here so the Rust test is covered in full.
    const gpa = testing.allocator;
    var seq: Sequence = .{};
    defer seq.deinit(gpa);
    try seq.notes.appendSlice(gpa, &[_]Note{
        mk(64, 100, 50),
        mk(60, 100, 10),
        mk(60, 100, 30),
        mk(60, 0, 10),
        nch(60, 0, 10, 2),
    });
    try seq.ctrls.appendSlice(gpa, &[_]CtrlEvent{
        .{ .tick = 500, .channel = 0, .kind = .{ .cc = 1 }, .value = 1 },
        .{ .tick = 5, .channel = 0, .kind = .{ .cc = 1 }, .value = 2 },
        .{ .tick = 500, .channel = 0, .kind = .{ .cc = 1 }, .value = 3 },
        .{ .tick = 500, .channel = 0, .kind = .{ .cc = 2 }, .value = 4 },
    });
    try testing.expectEqual(@as(i64, 500), seq.endTick());
    seq.sort();
    try expectStarts(seq.notes.items, &[_]i64{ 0, 0, 100, 100, 100 });
    try testing.expectEqual(@as(u8, 60), seq.notes.items[2].pitch);
    var in_range: usize = 0;
    var it_in = seq.notesIn(0, 100);
    while (it_in.next()) |_| in_range += 1;
    try testing.expectEqual(@as(usize, 2), in_range);
    var overlapping: usize = 0;
    var it_ov = seq.notesOverlapping(105, 106);
    while (it_ov.next()) |_| overlapping += 1;
    try testing.expectEqual(@as(usize, 3), overlapping);

    const removed = seq.removeDuplicates();
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 4), seq.notes.items.len);
    var kept_len: ?i64 = null;
    for (seq.notes.items) |note| {
        if (note.start == 100 and note.pitch == 60) kept_len = note.length;
    }
    try testing.expectEqual(@as(i64, 30), kept_len.?);
    try testing.expectEqual(@as(i32, 2), seq.ctrls.items[0].value);
    try testing.expectEqual(@as(i32, 3), seq.ctrls.items[1].value);
    try testing.expectEqual(@as(i32, 4), seq.ctrls.items[2].value);
    try testing.expectEqual(@as(usize, 0), seq.removeDuplicates());

    var empty: Sequence = .{};
    defer empty.deinit(gpa);
    try testing.expectEqual(@as(i64, 0), empty.endTick());
}

test "sequence_serde_round_trip" {
    // Not ported: the Rust test round-trips the Sequence through serde JSON. Serde is dropped in
    // the Zig port (project serialization is Seridian's own), so there is nothing to round-trip here.
    return error.SkipZigTest;
}

test "roundI64 rounds half away from zero and saturates" {
    try testing.expectEqual(@as(i64, 3), roundI64(2.5));
    try testing.expectEqual(@as(i64, -3), roundI64(-2.5));
    try testing.expectEqual(@as(i64, 0), roundI64(std.math.nan(f64)));
    try testing.expectEqual(std.math.maxInt(i64), roundI64(1e30));
    try testing.expectEqual(std.math.minInt(i64), roundI64(-1e30));
}

test "nearestLine breaks ties towards the earlier (lower) line" {
    // 120 is equidistant from 0 and 240; the Rust loop keeps the first candidate (line 0).
    try testing.expectEqual(@as(i64, 0), nearestLine(120, 240, 0.0));
}
