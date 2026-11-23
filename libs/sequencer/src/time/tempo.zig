// Translated to Zig from soundcraft/crates/time/src/tempo.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Tempo and meter maps: the conversion between musical time (ticks) and samples.
//!
//! Ownership and threads:
//! - `TempoMap` is the editable map. It owns two unmanaged lists, so every
//!   mutator takes the allocator. It is edited on the control thread only.
//! - `TempoMap.snapshot` makes an immutable, owned copy. The control thread
//!   publishes it to the audio thread (swap a pointer, reclaim the old copy later;
//!   that mechanism lives in `core`, not here). The audio thread reads it through
//!   `Snapshot.view()`.
//! - `View` holds only borrowed slices. Every read function on it (tick and sample
//!   conversion, bar and beat lookup) is pure arithmetic: no allocation, no lock,
//!   no logging, no I/O.
//!
//! Integer ticks stay the internal timebase (`ticks_per_quarter` = 960). Lanes and
//! clips are in beats, so `ticksToBeats` and `beatsToTicks` convert at the edge.

const std = @import("std");
const time = @import("time.zig");

const Samples = time.Samples;
const SampleRate = time.SampleRate;
const TimeError = time.TimeError;
const max_position = time.max_position;
const toSamples = time.toSamples;

/// Ticks per quarter note (Pro Tools' resolution).
pub const ticks_per_quarter: i64 = 960;

/// Errors from the editing methods: a rejected value, or the allocator failing.
pub const Error = TimeError || std.mem.Allocator.Error;

/// A tempo change at a tick position. `bpm` is quarter notes per minute.
pub const TempoEvent = struct {
    tick: i64,
    bpm: f64,
};

/// A meter (time signature) change at a tick position, which must fall on a bar line.
pub const MeterEvent = struct {
    tick: i64,
    numerator: u32,
    denominator: u32,

    pub fn ticksPerBeat(self: MeterEvent) i64 {
        const d: i64 = @max(@as(i64, self.denominator), 1);
        return @max(@divTrunc(ticks_per_quarter * 4, d), 1);
    }

    pub fn ticksPerBar(self: MeterEvent) i64 {
        return self.ticksPerBeat() *| @as(i64, @max(self.numerator, 1));
    }
};

/// A musical position: 1-based bar and beat plus ticks within the beat.
pub const BarBeat = struct {
    bar: i64,
    beat: i64,
    tick: i64,
};

/// Beats (quarter notes) to ticks. Rounds to nearest and saturates.
pub fn beatsToTicks(beats: f64) i64 {
    return toSamples(beats * @as(f64, @floatFromInt(ticks_per_quarter)));
}

/// Ticks to beats (quarter notes). Exact for every tick the map can hold.
pub fn ticksToBeats(tick: i64) f64 {
    return @as(f64, @floatFromInt(tick)) / @as(f64, @floatFromInt(ticks_per_quarter));
}

fn validBpm(bpm: f64) bool {
    return std.math.isFinite(bpm) and bpm >= 5.0 and bpm <= 1000.0;
}

fn checkBpm(bpm: f64) TimeError!f64 {
    if (validBpm(bpm)) return bpm;
    return error.Tempo;
}

fn validMeter(numerator: u32, denominator: u32) bool {
    if (numerator < 1 or numerator > 64) return false;
    return switch (denominator) {
        1, 2, 4, 8, 16, 32, 64 => true,
        else => false,
    };
}

fn samplesPerTick(bpm: f64, sr: SampleRate) f64 {
    return sr.asF64() * 60.0 / (bpm * @as(f64, @floatFromInt(ticks_per_quarter)));
}

/// Index of the first item whose tick is >= `tick` (items must be sorted by tick).
fn lowerBound(comptime T: type, items: []const T, tick: i64) usize {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (items[mid].tick < tick) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Stable insertion sort by tick. Lists are small (control thread), and stability
/// keeps the first of two events at the same tick, as Rust's `sort_by_key` does.
fn sortByTick(comptime T: type, items: []T) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        var j = i;
        while (j > 0 and items[j - 1].tick > items[j].tick) : (j -= 1) {
            std.mem.swap(T, &items[j - 1], &items[j]);
        }
    }
}

/// Keep the first event of each run of equal ticks (Rust `dedup_by_key`).
fn dedupByTick(comptime T: type, list: *std.ArrayList(T)) void {
    var w: usize = 0;
    for (list.items, 0..) |e, r| {
        if (r == 0 or e.tick != list.items[w - 1].tick) {
            list.items[w] = e;
            w += 1;
        }
    }
    list.shrinkRetainingCapacity(w);
}

/// Read-only tempo and meter data. Holds borrowed slices only, so it never allocates.
/// Both slices are sorted by tick; each is non-empty for a sanitized map.
pub const View = struct {
    tempos: []const TempoEvent,
    meters: []const MeterEvent,

    /// Tempo in effect at `tick`.
    pub fn tempoAtTick(self: View, tick: i64) f64 {
        var bpm: f64 = if (self.tempos.len > 0) self.tempos[0].bpm else 120.0;
        for (self.tempos) |e| {
            if (e.tick <= tick) {
                bpm = e.bpm;
            } else {
                break;
            }
        }
        return bpm;
    }

    /// Meter in effect at `tick`.
    pub fn meterAtTick(self: View, tick: i64) MeterEvent {
        var m: MeterEvent = if (self.meters.len > 0)
            self.meters[0]
        else
            .{ .tick = 0, .numerator = 4, .denominator = 4 };
        for (self.meters) |e| {
            if (e.tick <= tick) {
                m = e;
            } else {
                break;
            }
        }
        return m;
    }

    fn tickToSamplesF(self: View, tick: i64, sr: SampleRate) f64 {
        var acc: f64 = 0.0;
        var seg_tick: i64 = 0;
        var bpm: f64 = if (self.tempos.len > 0) self.tempos[0].bpm else 120.0;
        for (self.tempos, 0..) |e, i| {
            if (i == 0) continue; // Rust `skip(1)`: the first event sets the starting bpm.
            if (e.tick >= tick) break;
            acc += @as(f64, @floatFromInt(e.tick - seg_tick)) * samplesPerTick(bpm, sr);
            seg_tick = e.tick;
            bpm = e.bpm;
        }
        return acc + @as(f64, @floatFromInt(tick - seg_tick)) * samplesPerTick(bpm, sr);
    }

    /// Ticks -> samples, integrating the piecewise tempo segments.
    pub fn tickToSamples(self: View, tick: i64, sr: SampleRate) Samples {
        return toSamples(self.tickToSamplesF(tick, sr));
    }

    /// Samples -> ticks (fractional).
    pub fn samplesToTicksF(self: View, s_in: Samples, sr: SampleRate) f64 {
        const s: f64 = @floatFromInt(s_in);
        var acc: f64 = 0.0;
        var seg_tick: i64 = 0;
        var bpm: f64 = if (self.tempos.len > 0) self.tempos[0].bpm else 120.0;
        for (self.tempos, 0..) |e, i| {
            if (i == 0) continue;
            const seg = @as(f64, @floatFromInt(e.tick - seg_tick)) * samplesPerTick(bpm, sr);
            if (acc + seg > s) break;
            acc += seg;
            seg_tick = e.tick;
            bpm = e.bpm;
        }
        return @as(f64, @floatFromInt(seg_tick)) + (s - acc) / samplesPerTick(bpm, sr);
    }

    /// Samples -> ticks, rounded to nearest and saturated.
    pub fn samplesToTicks(self: View, s: Samples, sr: SampleRate) i64 {
        return toSamples(self.samplesToTicksF(s, sr));
    }

    /// Tick of the first beat of `bar` (1-based). Bars before 1 extend the first
    /// meter backwards. Saturates instead of overflowing.
    pub fn barStartTick(self: View, bar: i64) i64 {
        var cur_bar: i64 = 1;
        var cur_tick: i64 = 0;
        const first = self.meterAtTick(0);
        if (bar < 1) return (bar -| 1) *| first.ticksPerBar();
        for (self.meters, 0..) |m, i| {
            const tpb = m.ticksPerBar();
            const next_tick: ?i64 = if (i + 1 < self.meters.len) self.meters[i + 1].tick else null;
            const bars_in_seg: ?i64 = if (next_tick) |nt|
                @divTrunc((nt -| cur_tick) +| (tpb - 1), tpb)
            else
                null;
            if (bars_in_seg) |n| {
                if (bar >= cur_bar +| n) {
                    cur_bar +|= n;
                    cur_tick = next_tick.?;
                    continue;
                }
            }
            return cur_tick +| (bar - cur_bar) *| tpb;
        }
        return cur_tick;
    }

    /// Bar|beat|tick at `tick`.
    pub fn barBeatAtTick(self: View, tick: i64) BarBeat {
        const first = self.meterAtTick(0);
        if (tick < 0) {
            // Work on the magnitude so i64::MIN does not overflow when negated.
            const tpb: u64 = @intCast(first.ticksPerBar());
            const abs: u64 = @abs(tick);
            const bars_back_u: u64 = abs / tpb + @intFromBool(abs % tpb != 0);
            const bars_back: i64 = std.math.cast(i64, bars_back_u) orelse std.math.maxInt(i64);
            // Offset of `tick` inside its bar.
            const within: i64 = @intCast((tpb - abs % tpb) % tpb);
            const beat_t = first.ticksPerBeat();
            return .{
                .bar = 1 - bars_back,
                .beat = @divTrunc(within, beat_t) + 1,
                .tick = @rem(within, beat_t),
            };
        }
        var bar: i64 = 1;
        var seg_tick: i64 = 0;
        for (self.meters, 0..) |m, i| {
            const tpb = m.ticksPerBar();
            if (i + 1 < self.meters.len and tick >= self.meters[i + 1].tick) {
                const n = self.meters[i + 1].tick;
                bar +|= @divTrunc((n -| seg_tick) +| (tpb - 1), tpb);
                seg_tick = n;
                continue;
            }
            const rel = tick - seg_tick;
            const bars = @divTrunc(rel, tpb);
            const within = @rem(rel, tpb);
            const beat_t = m.ticksPerBeat();
            return .{
                .bar = bar +| bars,
                .beat = @divTrunc(within, beat_t) + 1,
                .tick = @rem(within, beat_t),
            };
        }
        return .{ .bar = bar, .beat = 1, .tick = 0 };
    }

    /// Bar|beat|tick -> tick. Saturates.
    pub fn tickAtBarBeat(self: View, bb: BarBeat) i64 {
        const start = self.barStartTick(bb.bar);
        const m = self.meterAtTick(start);
        const beats_back: i64 = @max(bb.beat -| 1, 0);
        return (start +| (beats_back *| m.ticksPerBeat())) +| bb.tick;
    }

    pub fn barBeatAt(self: View, s: Samples, sr: SampleRate) BarBeat {
        return self.barBeatAtTick(self.samplesToTicks(s, sr));
    }

    pub fn samplesAtBarBeat(self: View, bb: BarBeat, sr: SampleRate) Samples {
        return self.tickToSamples(self.tickAtBarBeat(bb), sr);
    }
};

/// An immutable, owned copy of a `TempoMap`, for the audio thread. Created with
/// `TempoMap.snapshot`; freed with `deinit` once no reader can see it.
pub const Snapshot = struct {
    tempos: []TempoEvent,
    meters: []MeterEvent,

    pub fn deinit(self: *Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(self.tempos);
        gpa.free(self.meters);
        self.* = undefined;
    }

    /// Borrowed read-only view. Valid while the snapshot is alive.
    pub fn view(self: *const Snapshot) View {
        return .{ .tempos = self.tempos, .meters = self.meters };
    }

    pub fn tickToSamples(self: *const Snapshot, tick: i64, sr: SampleRate) Samples {
        return self.view().tickToSamples(tick, sr);
    }

    pub fn samplesToTicks(self: *const Snapshot, s: Samples, sr: SampleRate) i64 {
        return self.view().samplesToTicks(s, sr);
    }

    pub fn barBeatAtTick(self: *const Snapshot, tick: i64) BarBeat {
        return self.view().barBeatAtTick(tick);
    }

    pub fn tickAtBarBeat(self: *const Snapshot, bb: BarBeat) i64 {
        return self.view().tickAtBarBeat(bb);
    }
};

/// Tempo and meter changes for a session. Always has at least one of each, at tick 0
/// (established by `initDefault`, `init`, or `sanitize`).
pub const TempoMap = struct {
    tempo_list: std.ArrayList(TempoEvent),
    meter_list: std.ArrayList(MeterEvent),

    /// A 120 bpm, 4/4 map. Allocates; free with `deinit`.
    pub fn initDefault(gpa: std.mem.Allocator) std.mem.Allocator.Error!TempoMap {
        var m: TempoMap = .{ .tempo_list = .empty, .meter_list = .empty };
        errdefer m.deinit(gpa);
        try m.tempo_list.append(gpa, .{ .tick = 0, .bpm = 120.0 });
        try m.meter_list.append(gpa, .{ .tick = 0, .numerator = 4, .denominator = 4 });
        return m;
    }

    /// A map with the given opening tempo and meter. Free with `deinit`.
    pub fn init(gpa: std.mem.Allocator, bpm: f64, numerator: u32, denominator: u32) Error!TempoMap {
        var m = try TempoMap.initDefault(gpa);
        errdefer m.deinit(gpa);
        try m.setTempo(gpa, 0, bpm);
        try m.setMeter(gpa, 0, numerator, denominator);
        return m;
    }

    pub fn deinit(self: *TempoMap, gpa: std.mem.Allocator) void {
        self.tempo_list.deinit(gpa);
        self.meter_list.deinit(gpa);
        self.* = undefined;
    }

    pub fn tempos(self: *const TempoMap) []const TempoEvent {
        return self.tempo_list.items;
    }

    pub fn meters(self: *const TempoMap) []const MeterEvent {
        return self.meter_list.items;
    }

    /// Borrowed read-only view of the current contents. Invalid after the next edit.
    pub fn view(self: *const TempoMap) View {
        return .{ .tempos = self.tempo_list.items, .meters = self.meter_list.items };
    }

    /// Repair a map read from a file: keep only valid tempos and meters within
    /// `0..=max_position` ticks, in tick order, with one of each at tick 0. Reserves
    /// its capacity first, so it fails before changing anything or not at all.
    pub fn sanitize(self: *TempoMap, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        try self.tempo_list.ensureUnusedCapacity(gpa, 1);
        try self.meter_list.ensureUnusedCapacity(gpa, 1);

        var tw: usize = 0;
        for (self.tempo_list.items) |e| {
            if (e.tick >= 0 and e.tick <= max_position and validBpm(e.bpm)) {
                self.tempo_list.items[tw] = e;
                tw += 1;
            }
        }
        self.tempo_list.shrinkRetainingCapacity(tw);
        sortByTick(TempoEvent, self.tempo_list.items);
        dedupByTick(TempoEvent, &self.tempo_list);
        if (self.tempo_list.items.len == 0 or self.tempo_list.items[0].tick > 0) {
            const bpm: f64 = if (self.tempo_list.items.len > 0) self.tempo_list.items[0].bpm else 120.0;
            self.tempo_list.insertAssumeCapacity(0, .{ .tick = 0, .bpm = bpm });
        }

        var mw: usize = 0;
        for (self.meter_list.items) |m| {
            if (m.tick >= 0 and m.tick <= max_position and validMeter(m.numerator, m.denominator)) {
                self.meter_list.items[mw] = m;
                mw += 1;
            }
        }
        self.meter_list.shrinkRetainingCapacity(mw);
        sortByTick(MeterEvent, self.meter_list.items);
        dedupByTick(MeterEvent, &self.meter_list);
        if (self.meter_list.items.len == 0 or self.meter_list.items[0].tick > 0) {
            const num: u32 = if (self.meter_list.items.len > 0) self.meter_list.items[0].numerator else 4;
            const den: u32 = if (self.meter_list.items.len > 0) self.meter_list.items[0].denominator else 4;
            self.meter_list.insertAssumeCapacity(0, .{ .tick = 0, .numerator = num, .denominator = den });
        }
    }

    /// Insert or replace the tempo at `tick` (negative ticks clamp to 0).
    pub fn setTempo(self: *TempoMap, gpa: std.mem.Allocator, tick_in: i64, bpm_in: f64) Error!void {
        const bpm = try checkBpm(bpm_in);
        const tick = @max(tick_in, 0);
        const i = lowerBound(TempoEvent, self.tempo_list.items, tick);
        if (i < self.tempo_list.items.len and self.tempo_list.items[i].tick == tick) {
            self.tempo_list.items[i].bpm = bpm;
        } else {
            try self.tempo_list.insert(gpa, i, .{ .tick = tick, .bpm = bpm });
        }
    }

    /// Remove a tempo event (the one at tick 0 is kept). Returns whether one was removed.
    pub fn removeTempo(self: *TempoMap, tick: i64) bool {
        if (tick == 0) return false;
        const before = self.tempo_list.items.len;
        var w: usize = 0;
        for (self.tempo_list.items) |e| {
            if (e.tick != tick) {
                self.tempo_list.items[w] = e;
                w += 1;
            }
        }
        self.tempo_list.shrinkRetainingCapacity(w);
        return before != w;
    }

    /// Insert or replace the meter at `tick`, snapped to the bar line at or before it.
    /// Later meter changes keep their bar numbers, so they stay on bar lines.
    pub fn setMeter(self: *TempoMap, gpa: std.mem.Allocator, tick: i64, numerator: u32, denominator: u32) Error!void {
        if (!validMeter(numerator, denominator)) return error.Meter;
        const at: i64 = if (tick <= 0) 0 else self.view().barStartTick(self.view().barBeatAtTick(tick).bar);
        var later = try self.collectMetersAfter(gpa, at);
        defer later.deinit(gpa);
        // Reserve before mutating: after this, every insert below fits in capacity.
        try self.meter_list.ensureUnusedCapacity(gpa, 1);
        self.dropMetersAfter(at);
        try self.putMeter(gpa, .{ .tick = at, .numerator = numerator, .denominator = denominator });
        try self.restoreMetersAtBars(gpa, later.items);
    }

    /// Remove a meter event (the one at tick 0 is kept). Later meter changes keep
    /// their bar numbers.
    pub fn removeMeter(self: *TempoMap, gpa: std.mem.Allocator, tick: i64) Error!bool {
        if (tick == 0) return false;
        var found = false;
        for (self.meter_list.items) |e| {
            if (e.tick == tick) found = true;
        }
        if (!found) return false;
        var later = try self.collectMetersAfter(gpa, tick);
        defer later.deinit(gpa);
        try self.meter_list.ensureUnusedCapacity(gpa, 1);
        self.dropMetersAfter(tick);
        var w: usize = 0;
        for (self.meter_list.items) |e| {
            if (e.tick != tick) {
                self.meter_list.items[w] = e;
                w += 1;
            }
        }
        self.meter_list.shrinkRetainingCapacity(w);
        try self.restoreMetersAtBars(gpa, later.items);
        return true;
    }

    const Later = struct { bar: i64, ev: MeterEvent };

    fn putMeter(self: *TempoMap, gpa: std.mem.Allocator, ev: MeterEvent) std.mem.Allocator.Error!void {
        const i = lowerBound(MeterEvent, self.meter_list.items, ev.tick);
        if (i < self.meter_list.items.len and self.meter_list.items[i].tick == ev.tick) {
            self.meter_list.items[i] = ev;
        } else {
            try self.meter_list.insert(gpa, i, ev);
        }
    }

    /// Copy the meters after `tick`, each with the bar it starts, without changing the map.
    fn collectMetersAfter(self: *const TempoMap, gpa: std.mem.Allocator, tick: i64) std.mem.Allocator.Error!std.ArrayList(Later) {
        var out: std.ArrayList(Later) = .empty;
        errdefer out.deinit(gpa);
        const v = self.view();
        for (self.meter_list.items) |e| {
            if (e.tick > tick) {
                try out.append(gpa, .{ .bar = v.barBeatAtTick(e.tick).bar, .ev = e });
            }
        }
        return out;
    }

    /// Drop every meter after `tick`.
    fn dropMetersAfter(self: *TempoMap, tick: i64) void {
        var w: usize = 0;
        for (self.meter_list.items) |e| {
            if (e.tick <= tick) {
                self.meter_list.items[w] = e;
                w += 1;
            }
        }
        self.meter_list.shrinkRetainingCapacity(w);
    }

    /// Put meters back at the start of their bars under the current earlier meters, in bar order.
    fn restoreMetersAtBars(self: *TempoMap, gpa: std.mem.Allocator, later: []const Later) std.mem.Allocator.Error!void {
        for (later) |l| {
            var ev = l.ev;
            ev.tick = self.view().barStartTick(l.bar);
            try self.putMeter(gpa, ev);
        }
    }

    pub fn tempoAtTick(self: *const TempoMap, tick: i64) f64 {
        return self.view().tempoAtTick(tick);
    }

    pub fn meterAtTick(self: *const TempoMap, tick: i64) MeterEvent {
        return self.view().meterAtTick(tick);
    }

    pub fn tickToSamples(self: *const TempoMap, tick: i64, sr: SampleRate) Samples {
        return self.view().tickToSamples(tick, sr);
    }

    pub fn samplesToTicks(self: *const TempoMap, s: Samples, sr: SampleRate) i64 {
        return self.view().samplesToTicks(s, sr);
    }

    pub fn samplesToTicksF(self: *const TempoMap, s: Samples, sr: SampleRate) f64 {
        return self.view().samplesToTicksF(s, sr);
    }

    pub fn barStartTick(self: *const TempoMap, bar: i64) i64 {
        return self.view().barStartTick(bar);
    }

    pub fn barBeatAtTick(self: *const TempoMap, tick: i64) BarBeat {
        return self.view().barBeatAtTick(tick);
    }

    pub fn tickAtBarBeat(self: *const TempoMap, bb: BarBeat) i64 {
        return self.view().tickAtBarBeat(bb);
    }

    pub fn barBeatAt(self: *const TempoMap, s: Samples, sr: SampleRate) BarBeat {
        return self.view().barBeatAt(s, sr);
    }

    pub fn samplesAtBarBeat(self: *const TempoMap, bb: BarBeat, sr: SampleRate) Samples {
        return self.view().samplesAtBarBeat(bb, sr);
    }

    /// An owned, immutable copy for the audio thread. Allocates; call on the control
    /// thread and free with `Snapshot.deinit`.
    pub fn snapshot(self: *const TempoMap, gpa: std.mem.Allocator) std.mem.Allocator.Error!Snapshot {
        const t = try gpa.dupe(TempoEvent, self.tempo_list.items);
        errdefer gpa.free(t);
        const m = try gpa.dupe(MeterEvent, self.meter_list.items);
        return .{ .tempos = t, .meters = m };
    }

    /// Scale every tempo by `factor` (Tempo Operations > Scale). All-or-nothing: if
    /// any result is out of range, no tempo changes.
    pub fn scaleTempos(self: *TempoMap, factor: f64) TimeError!void {
        for (self.tempo_list.items) |e| {
            _ = try checkBpm(e.bpm * factor);
        }
        for (self.tempo_list.items) |*e| {
            e.bpm = e.bpm * factor;
        }
    }
};

fn expectSameMap(a: *const TempoMap, b: *const TempoMap) !void {
    try std.testing.expectEqualSlices(TempoEvent, a.tempos(), b.tempos());
    try std.testing.expectEqualSlices(MeterEvent, a.meters(), b.meters());
}

test "default_map_is_120_4_4" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.initDefault(gpa);
    defer m.deinit(gpa);
    const sr = SampleRate.hz_48000;
    // One bar of 4/4 at 120 bpm = 2 seconds.
    try std.testing.expectEqual(@as(Samples, 96_000), m.samplesAtBarBeat(.{ .bar = 2, .beat = 1, .tick = 0 }, sr));
    try std.testing.expectEqual(BarBeat{ .bar = 2, .beat = 1, .tick = 0 }, m.barBeatAt(96_000, sr));
    try std.testing.expectEqual(BarBeat{ .bar = 1, .beat = 2, .tick = 0 }, m.barBeatAt(24_000, sr));
}

test "minimum_bar_saturates_instead_of_overflowing" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.initDefault(gpa);
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), m.barStartTick(std.math.minInt(i64)));
    try std.testing.expectEqual(-ticks_per_quarter * 4, m.barStartTick(0));
}

test "minimum_beat_is_clamped_without_overflow" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.initDefault(gpa);
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 0), m.tickAtBarBeat(.{ .bar = 1, .beat = std.math.minInt(i64), .tick = 0 }));
}

test "bar_beat_at_min_tick_does_not_overflow" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.initDefault(gpa);
    defer m.deinit(gpa);
    const bb = m.barBeatAtTick(std.math.minInt(i64));
    try std.testing.expect(bb.bar < 1);
    try std.testing.expect(bb.beat >= 1 and bb.tick >= 0);
    try std.testing.expectEqual(@as(i64, 0), m.barBeatAtTick(-1).bar);
}

test "tempo_change_is_integrated" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.initDefault(gpa);
    defer m.deinit(gpa);
    const sr = SampleRate.hz_48000;
    try m.setTempo(gpa, ticks_per_quarter * 4, 60.0);
    // Bar 1 at 120 = 96000 samples; bar 2 at 60 = 192000 samples.
    try std.testing.expectEqual(@as(Samples, 96_000 + 192_000), m.tickToSamples(ticks_per_quarter * 8, sr));
    try std.testing.expectEqual(@as(i64, ticks_per_quarter * 8), m.samplesToTicks(96_000 + 192_000, sr));
}

test "meter_change_counts_bars" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.initDefault(gpa);
    defer m.deinit(gpa);
    // 2 bars of 4/4 then 3/4.
    try m.setMeter(gpa, ticks_per_quarter * 8, 3, 4);
    try std.testing.expectEqual(BarBeat{ .bar = 3, .beat = 1, .tick = 0 }, m.barBeatAtTick(ticks_per_quarter * 8));
    try std.testing.expectEqual(BarBeat{ .bar = 4, .beat = 1, .tick = 0 }, m.barBeatAtTick(ticks_per_quarter * 11));
    try std.testing.expectEqual(@as(i64, ticks_per_quarter * 11), m.barStartTick(4));
    const bb = BarBeat{ .bar = 4, .beat = 2, .tick = 10 };
    try std.testing.expectEqual(bb, m.barBeatAtTick(m.tickAtBarBeat(bb)));
}

test "eighth_note_meters" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.init(gpa, 120.0, 6, 8);
    defer m.deinit(gpa);
    try std.testing.expectEqual(BarBeat{ .bar = 2, .beat = 1, .tick = 0 }, m.barBeatAtTick(ticks_per_quarter * 3));
    try std.testing.expectEqual(BarBeat{ .bar = 1, .beat = 2, .tick = 0 }, m.barBeatAtTick(ticks_per_quarter / 2));
}

test "sanitize_keeps_what_the_setters_accept" {
    const gpa = std.testing.allocator;
    var m: TempoMap = .{ .tempo_list = .empty, .meter_list = .empty };
    defer m.deinit(gpa);
    try m.tempo_list.appendSlice(gpa, &.{
        .{ .tick = 960, .bpm = 4e9 },
        .{ .tick = 3840, .bpm = 90.0 },
        .{ .tick = -5, .bpm = 100.0 },
        .{ .tick = 1920, .bpm = 60.0 },
        .{ .tick = 1920, .bpm = 70.0 },
    });
    try m.meter_list.appendSlice(gpa, &.{
        .{ .tick = 0, .numerator = 0, .denominator = 4 },
        .{ .tick = 3840, .numerator = 3, .denominator = 4 },
    });
    try m.sanitize(gpa);
    try std.testing.expectEqualSlices(TempoEvent, &.{
        .{ .tick = 0, .bpm = 60.0 },
        .{ .tick = 1920, .bpm = 60.0 },
        .{ .tick = 3840, .bpm = 90.0 },
    }, m.tempos());
    try std.testing.expectEqualSlices(MeterEvent, &.{
        .{ .tick = 0, .numerator = 3, .denominator = 4 },
        .{ .tick = 3840, .numerator = 3, .denominator = 4 },
    }, m.meters());

    var empty: TempoMap = .{ .tempo_list = .empty, .meter_list = .empty };
    defer empty.deinit(gpa);
    try empty.sanitize(gpa);
    var def = try TempoMap.initDefault(gpa);
    defer def.deinit(gpa);
    try expectSameMap(&empty, &def);
}

test "sanitize_drops_events_beyond_the_position_range" {
    const gpa = std.testing.allocator;
    var m: TempoMap = .{ .tempo_list = .empty, .meter_list = .empty };
    defer m.deinit(gpa);
    try m.tempo_list.appendSlice(gpa, &.{
        .{ .tick = 0, .bpm = 120.0 },
        .{ .tick = std.math.maxInt(i64), .bpm = 90.0 },
    });
    try m.meter_list.appendSlice(gpa, &.{
        .{ .tick = 0, .numerator = 4, .denominator = 4 },
        .{ .tick = std.math.maxInt(i64), .numerator = 3, .denominator = 4 },
    });
    try m.sanitize(gpa);
    var def = try TempoMap.initDefault(gpa);
    defer def.deinit(gpa);
    try expectSameMap(&m, &def);
    try std.testing.expectEqual(ticks_per_quarter * 4, m.barStartTick(2));
}

test "rejects_bad_values" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.initDefault(gpa);
    defer m.deinit(gpa);
    try std.testing.expectError(error.Tempo, m.setTempo(gpa, 0, std.math.nan(f64)));
    try std.testing.expectError(error.Tempo, m.setTempo(gpa, 0, 0.0));
    try std.testing.expectError(error.Meter, m.setMeter(gpa, 0, 0, 4));
    try std.testing.expectError(error.Meter, m.setMeter(gpa, 0, 4, 3));
    try std.testing.expect(!m.removeTempo(0));
}

test "negative_positions" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.initDefault(gpa);
    defer m.deinit(gpa);
    try std.testing.expectEqual(BarBeat{ .bar = 0, .beat = 1, .tick = 0 }, m.barBeatAtTick(-ticks_per_quarter * 4));
    try std.testing.expectEqual(BarBeat{ .bar = 0, .beat = 4, .tick = 0 }, m.barBeatAtTick(-ticks_per_quarter));
}

test "snapshot_is_an_immutable_copy" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.init(gpa, 120.0, 4, 4);
    defer m.deinit(gpa);
    try m.setTempo(gpa, 3840, 60.0);
    var snap = try m.snapshot(gpa);
    defer snap.deinit(gpa);
    const sr = SampleRate.hz_48000;
    try std.testing.expectEqual(m.tickToSamples(7680, sr), snap.tickToSamples(7680, sr));
    try std.testing.expectEqual(@as(Samples, 96_000 + 192_000), snap.view().tickToSamples(7680, sr));
    // Editing the map afterwards does not change what the audio thread reads.
    try m.setTempo(gpa, 3840, 240.0);
    try std.testing.expectEqual(@as(Samples, 96_000 + 192_000), snap.tickToSamples(7680, sr));
}

test "beats_and_ticks_helpers" {
    try std.testing.expectEqual(@as(f64, 1.0), ticksToBeats(960));
    try std.testing.expectEqual(@as(i64, 2400), beatsToTicks(2.5));
    try std.testing.expectEqual(@as(i64, 0), beatsToTicks(std.math.nan(f64)));
}

test "scale_tempos_is_all_or_nothing" {
    const gpa = std.testing.allocator;
    var m = try TempoMap.init(gpa, 100.0, 4, 4);
    defer m.deinit(gpa);
    try m.setTempo(gpa, 960, 600.0);
    try std.testing.expectError(error.Tempo, m.scaleTempos(2.0));
    try std.testing.expectEqual(@as(f64, 600.0), m.tempos()[1].bpm);
    try m.scaleTempos(0.5);
    try std.testing.expectEqual(@as(f64, 50.0), m.tempos()[0].bpm);
}

test {
    std.testing.refAllDecls(@This());
}
