// Translated to Zig from soundcraft/crates/midi/src/sequence.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! MIDI content of a region or track: notes and controller events, in model ticks
//! (`PPQ`, 960 per quarter note; see midi.zig).
//!
//! Serde is dropped; project serialization is Seridian's own. Sequences are edited on
//! the control thread with an allocator. The audio thread only reads immutable
//! snapshots, so nothing here locks. Sorting and de-duplication work in place and do
//! not allocate. Iterators borrow the sequence's storage and must not outlive a
//! mutation of it.

const std = @import("std");
const testing = std.testing;

/// A MIDI note. Times are in model ticks (`PPQ` per quarter note).
pub const Note = struct {
    /// MIDI pitch 0..=127 (60 = middle C, shown as "C3").
    pitch: u8,
    /// Note-on velocity 1..=127.
    velocity: u8,
    /// Note-off (release) velocity 0..=127; 64 when the source had none.
    release_velocity: u8,
    /// MIDI channel 0..=15.
    channel: u8,
    /// Start in ticks.
    start: i64,
    /// Length in ticks; always > 0.
    length: i64,

    /// Tick at which the note ends (`start + length`, saturating).
    pub fn end(self: Note) i64 {
        return self.start +| self.length;
    }
};

/// Kind of a continuous or channel controller event.
pub const CtrlKind = union(enum) {
    /// Control change with the controller number 0..=127. Value 0..=127.
    cc: u8,
    /// Pitch bend. Value is centred: -8192..=8191 (0 = no bend).
    pitch_bend,
    /// Channel (mono) aftertouch. Value 0..=127.
    channel_pressure,
    /// Polyphonic aftertouch for the given pitch. Value 0..=127.
    poly_pressure: u8,
    /// Program change. Value is the program number 0..=127.
    program,
};

/// A controller or channel event at a tick.
pub const CtrlEvent = struct {
    tick: i64,
    channel: u8,
    kind: CtrlKind,
    value: i32,
};

/// Group and argument of a `CtrlKind`, used to find events of the same kind.
const KindKey = struct {
    group: u8,
    arg: u8,
};

fn kindKey(k: CtrlKind) KindKey {
    return switch (k) {
        .cc => |n| .{ .group = 0, .arg = n },
        .pitch_bend => .{ .group = 1, .arg = 0 },
        .channel_pressure => .{ .group = 2, .arg = 0 },
        .poly_pressure => |p| .{ .group = 3, .arg = p },
        .program => .{ .group = 4, .arg = 0 },
    };
}

fn sameKind(a: CtrlKind, b: CtrlKind) bool {
    const ka = kindKey(a);
    const kb = kindKey(b);
    return ka.group == kb.group and ka.arg == kb.arg;
}

/// Note order for `Sequence.sort`: (start, pitch, channel, length, velocity).
fn noteSortLess(_: void, a: Note, b: Note) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.pitch != b.pitch) return a.pitch < b.pitch;
    if (a.channel != b.channel) return a.channel < b.channel;
    if (a.length != b.length) return a.length < b.length;
    return a.velocity < b.velocity;
}

/// Note order for de-duplication: (start, pitch, channel), then longest first.
fn noteDedupLess(_: void, a: Note, b: Note) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.pitch != b.pitch) return a.pitch < b.pitch;
    if (a.channel != b.channel) return a.channel < b.channel;
    return a.length > b.length;
}

fn ctrlSortLess(_: void, a: CtrlEvent, b: CtrlEvent) bool {
    return a.tick < b.tick;
}

/// Iterator over notes whose start lies in `[start, end)`.
pub const NotesIn = struct {
    items: []const Note,
    start: i64,
    end: i64,
    index: usize = 0,

    pub fn next(self: *NotesIn) ?*const Note {
        while (self.index < self.items.len) {
            const n = &self.items[self.index];
            self.index += 1;
            if (n.start >= self.start and n.start < self.end) return n;
        }
        return null;
    }
};

/// Iterator over notes that sound anywhere inside `[start, end)`.
pub const NotesOverlapping = struct {
    items: []const Note,
    start: i64,
    end: i64,
    index: usize = 0,

    pub fn next(self: *NotesOverlapping) ?*const Note {
        while (self.index < self.items.len) {
            const n = &self.items[self.index];
            self.index += 1;
            if (n.start < self.end and n.end() > self.start) return n;
        }
        return null;
    }
};

/// The MIDI content of a region or track. Owns its storage; call `deinit`.
pub const Sequence = struct {
    /// Notes, sorted by `(start, pitch)` after `sort`.
    notes: std.ArrayList(Note) = .empty,
    /// Controller events, sorted by tick after `sort`.
    ctrls: std.ArrayList(CtrlEvent) = .empty,

    pub fn deinit(self: *Sequence, gpa: std.mem.Allocator) void {
        self.notes.deinit(gpa);
        self.ctrls.deinit(gpa);
    }

    /// Sorts notes by `(start, pitch, channel, length, velocity)` and controller events by
    /// tick. Both sorts are stable, so same-tick events keep their order.
    pub fn sort(self: *Sequence) void {
        std.mem.sort(Note, self.notes.items, {}, noteSortLess);
        std.mem.sort(CtrlEvent, self.ctrls.items, {}, ctrlSortLess);
    }

    /// The last tick covered by any note end or controller event (0 when empty).
    pub fn endTick(self: *const Sequence) i64 {
        var best: ?i64 = null;
        for (self.notes.items) |n| best = foldMax(best, n.end());
        for (self.ctrls.items) |c| best = foldMax(best, c.tick);
        return best orelse 0;
    }

    /// Notes whose start lies in the half-open range `[start, end)`.
    pub fn notesIn(self: *const Sequence, start: i64, end: i64) NotesIn {
        return .{ .items = self.notes.items, .start = start, .end = end };
    }

    /// Notes that sound anywhere inside the half-open range `[start, end)`.
    pub fn notesOverlapping(self: *const Sequence, start: i64, end: i64) NotesOverlapping {
        return .{ .items = self.notes.items, .start = start, .end = end };
    }

    /// Removes duplicate notes (same channel, pitch and start; the longest one is kept) and
    /// duplicate controller events (same tick, channel and kind; the last one is kept, matching
    /// what a synth would end up with). Returns how many events were removed. The sequence is
    /// left sorted.
    ///
    /// Done in place: the kept events are compacted to the front of each list, so no
    /// allocation happens here.
    pub fn removeDuplicates(self: *Sequence) usize {
        const before = self.notes.items.len + self.ctrls.items.len;

        // Longest first within each (start, pitch, channel) group, then keep the first.
        std.mem.sort(Note, self.notes.items, {}, noteDedupLess);
        var nw: usize = 0;
        for (self.notes.items) |n| {
            if (nw > 0) {
                const kept = self.notes.items[nw - 1];
                if (n.start == kept.start and n.pitch == kept.pitch and n.channel == kept.channel) continue;
            }
            self.notes.items[nw] = n;
            nw += 1;
        }
        self.notes.shrinkRetainingCapacity(nw);

        // Within a tick, replace an earlier event of the same channel+kind. Only events at
        // the same tick (the tail of the kept prefix) can match.
        std.mem.sort(CtrlEvent, self.ctrls.items, {}, ctrlSortLess);
        var cw: usize = 0;
        for (self.ctrls.items) |c| {
            var slot: ?usize = null;
            var j = cw;
            while (j > 0) {
                j -= 1;
                const k = self.ctrls.items[j];
                if (k.tick != c.tick) break;
                if (k.channel == c.channel and sameKind(k.kind, c.kind)) {
                    slot = j;
                    break;
                }
            }
            if (slot) |s| {
                self.ctrls.items[s] = c;
            } else {
                self.ctrls.items[cw] = c;
                cw += 1;
            }
        }
        self.ctrls.shrinkRetainingCapacity(cw);

        self.sort();
        return before - (self.notes.items.len + self.ctrls.items.len);
    }
};

fn foldMax(acc: ?i64, v: i64) i64 {
    return if (acc) |a| @max(a, v) else v;
}

// --- Tests. The Rust crate has no inline tests for this file; these pin its behaviour
// directly (they are not ports of Rust tests).

fn note(start: i64, length: i64, pitch: u8, channel: u8, velocity: u8) Note {
    return .{ .pitch = pitch, .velocity = velocity, .release_velocity = 64, .channel = channel, .start = start, .length = length };
}

test "Note.end adds start and length and saturates" {
    try testing.expectEqual(@as(i64, 150), note(100, 50, 60, 0, 100).end());
    const big = note(std.math.maxInt(i64) - 1, 10, 60, 0, 100);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), big.end());
}

test "Sequence.endTick is 0 when empty, otherwise the latest note end or ctrl tick" {
    var empty: Sequence = .{};
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 0), empty.endTick());

    var s: Sequence = .{};
    defer s.deinit(testing.allocator);
    try s.notes.append(testing.allocator, note(0, 100, 60, 0, 100));
    try testing.expectEqual(@as(i64, 100), s.endTick());
    try s.ctrls.append(testing.allocator, .{ .tick = 500, .channel = 0, .kind = .program, .value = 3 });
    try testing.expectEqual(@as(i64, 500), s.endTick());
}

test "Sequence.sort orders notes by start then pitch, and ctrls by tick stably" {
    var s: Sequence = .{};
    defer s.deinit(testing.allocator);
    try s.notes.append(testing.allocator, note(960, 10, 64, 0, 90));
    try s.notes.append(testing.allocator, note(0, 10, 67, 0, 90));
    try s.notes.append(testing.allocator, note(0, 10, 60, 0, 90));
    try s.ctrls.append(testing.allocator, .{ .tick = 10, .channel = 0, .kind = .{ .cc = 7 }, .value = 1 });
    try s.ctrls.append(testing.allocator, .{ .tick = 0, .channel = 0, .kind = .{ .cc = 1 }, .value = 2 });
    try s.ctrls.append(testing.allocator, .{ .tick = 0, .channel = 0, .kind = .{ .cc = 2 }, .value = 3 });
    s.sort();
    try testing.expectEqual(@as(u8, 60), s.notes.items[0].pitch);
    try testing.expectEqual(@as(u8, 67), s.notes.items[1].pitch);
    try testing.expectEqual(@as(u8, 64), s.notes.items[2].pitch);
    try testing.expectEqual(@as(i32, 2), s.ctrls.items[0].value);
    try testing.expectEqual(@as(i32, 3), s.ctrls.items[1].value);
    try testing.expectEqual(@as(i32, 1), s.ctrls.items[2].value);
}

test "Sequence.notesIn uses the half-open start range" {
    var s: Sequence = .{};
    defer s.deinit(testing.allocator);
    try s.notes.append(testing.allocator, note(0, 10, 60, 0, 100));
    try s.notes.append(testing.allocator, note(50, 10, 62, 0, 100));
    try s.notes.append(testing.allocator, note(100, 10, 64, 0, 100));
    s.sort();

    var count: usize = 0;
    var it = s.notesIn(0, 100);
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);

    count = 0;
    var it2 = s.notesIn(100, 101);
    while (it2.next()) |n| {
        try testing.expectEqual(@as(u8, 64), n.pitch);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "Sequence.notesOverlapping includes notes that sound into the range" {
    var s: Sequence = .{};
    defer s.deinit(testing.allocator);
    try s.notes.append(testing.allocator, note(0, 100, 60, 0, 100)); // ends at 100: not in [105,106)
    try s.notes.append(testing.allocator, note(90, 20, 62, 0, 100)); // 90..110 overlaps
    try s.notes.append(testing.allocator, note(105, 1, 64, 0, 100)); // starts inside
    s.sort();

    var count: usize = 0;
    var it = s.notesOverlapping(105, 106);
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);

    count = 0;
    var it2 = s.notesOverlapping(100, 101);
    while (it2.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 1), count);
}

test "Sequence.removeDuplicates keeps the longest note and the last same-kind ctrl in a tick" {
    var s: Sequence = .{};
    defer s.deinit(testing.allocator);
    try s.notes.append(testing.allocator, note(0, 100, 60, 0, 100));
    try s.notes.append(testing.allocator, note(0, 300, 60, 0, 90));
    try s.notes.append(testing.allocator, note(0, 50, 60, 1, 90)); // other channel: kept
    try s.ctrls.append(testing.allocator, .{ .tick = 0, .channel = 0, .kind = .{ .cc = 7 }, .value = 10 });
    try s.ctrls.append(testing.allocator, .{ .tick = 0, .channel = 0, .kind = .{ .cc = 7 }, .value = 20 });
    try s.ctrls.append(testing.allocator, .{ .tick = 0, .channel = 0, .kind = .{ .cc = 8 }, .value = 30 });

    // One shorter note and one replaced cc7 event are removed.
    const removed = s.removeDuplicates();
    try testing.expectEqual(@as(usize, 2), removed);
    try testing.expectEqual(@as(usize, 2), s.notes.items.len);
    try testing.expectEqual(@as(i64, 300), s.notes.items[0].length);
    try testing.expectEqual(@as(u8, 1), s.notes.items[1].channel);
    try testing.expectEqual(@as(usize, 2), s.ctrls.items.len);
    try testing.expectEqual(@as(i32, 20), s.ctrls.items[0].value);
    try testing.expectEqual(@as(i32, 30), s.ctrls.items[1].value);

    try testing.expectEqual(@as(usize, 0), s.removeDuplicates());
}

test "Sequence.removeDuplicates does not merge different poly-pressure pitches" {
    var s: Sequence = .{};
    defer s.deinit(testing.allocator);
    try s.ctrls.append(testing.allocator, .{ .tick = 5, .channel = 0, .kind = .{ .poly_pressure = 60 }, .value = 1 });
    try s.ctrls.append(testing.allocator, .{ .tick = 5, .channel = 0, .kind = .{ .poly_pressure = 61 }, .value = 2 });
    try testing.expectEqual(@as(usize, 0), s.removeDuplicates());
    try testing.expectEqual(@as(usize, 2), s.ctrls.items.len);
}
