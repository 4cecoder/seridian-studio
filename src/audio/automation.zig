//! Automation lanes: time-stamped points (beat, value) that drive a mixer value while playing.
//!
//! A lane is written from the UI thread only and read from the audio thread. The handoff is
//! lock-free for the reader: the lane keeps two fixed tables. The writer edits the table that is
//! not active and then flips the active index. The reader announces which table it is reading, so
//! the writer never edits a table that is being read (it waits at most for the current audio block).
//!
//! Between points the value moves linearly. Before the first point and after the last point the
//! end values hold. A lane without points does nothing, so the manual value stays in force.

const std = @import("std");

/// Most points one lane can hold.
pub const MAX_POINTS = 128;

pub const Point = struct {
    beat: f64,
    value: f32,
};

const Table = struct {
    count: usize = 0,
    points: [MAX_POINTS]Point = undefined,

    /// Value at `beat`, or null when the table has no points.
    fn valueAt(self: *const Table, beat: f64) ?f32 {
        if (self.count == 0) return null;
        var next: usize = 0;
        while (next < self.count and self.points[next].beat <= beat) next += 1;
        return interpolate(self, next, beat);
    }

    /// `next` is the index of the first point after `beat` (count when there is none).
    fn interpolate(self: *const Table, next: usize, beat: f64) f32 {
        if (next == 0) return self.points[0].value;
        if (next >= self.count) return self.points[self.count - 1].value;
        const a = self.points[next - 1];
        const b = self.points[next];
        const span = b.beat - a.beat;
        if (span <= 0.0) return b.value;
        const t: f32 = @floatCast((beat - a.beat) / span);
        return a.value + (b.value - a.value) * t;
    }

    /// Fills `out[f]` with the value at `start_beat + f * beat_step`. Sample-accurate: a point in
    /// the middle of the block bends the curve at its own frame.
    fn fill(self: *const Table, start_beat: f64, beat_step: f64, out: []f32) void {
        var next: usize = 0;
        while (next < self.count and self.points[next].beat <= start_beat) next += 1;
        for (out, 0..) |*slot, frame| {
            const beat = start_beat + beat_step * @as(f64, @floatFromInt(frame));
            while (next < self.count and self.points[next].beat <= beat) next += 1;
            slot.* = interpolate(self, next, beat);
        }
    }
};

pub const Lane = struct {
    tables: [2]Table = .{ .{}, .{} },
    /// Index of the table the audio thread should read.
    active: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// 0 when the audio thread is not reading, otherwise the index of the table it reads plus one.
    reading: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub const Error = error{LaneFull};

    // ---- UI thread (single writer) ----

    /// Adds a point, or changes the value of the point already at `beat`. Points stay sorted.
    pub fn addPoint(self: *Lane, beat: f64, value: f32) Error!void {
        const current = &self.tables[self.active.load(.seq_cst)];
        const target = self.beginEdit();
        target.* = current.*;
        var at: usize = 0;
        while (at < target.count and target.points[at].beat < beat) at += 1;
        if (at < target.count and target.points[at].beat == beat) {
            target.points[at].value = value;
        } else {
            if (target.count == MAX_POINTS) return Error.LaneFull;
            var i = target.count;
            while (i > at) : (i -= 1) target.points[i] = target.points[i - 1];
            target.points[at] = .{ .beat = beat, .value = value };
            target.count += 1;
        }
        self.publish(target);
    }

    /// Removes every point.
    pub fn clear(self: *Lane) void {
        const target = self.beginEdit();
        target.count = 0;
        self.publish(target);
    }

    /// Copies the points into `out` (at most `out.len`, in beat order) and returns how many.
    pub fn copyPoints(self: *Lane, out: []Point) usize {
        const table = self.acquire();
        defer self.release();
        const n = @min(table.count, out.len);
        @memcpy(out[0..n], table.points[0..n]);
        return n;
    }

    /// Replaces every point of the lane with `points` (extra points beyond MAX_POINTS are dropped).
    pub fn setPoints(self: *Lane, points: []const Point) void {
        self.clear();
        for (points) |point| self.addPoint(point.beat, point.value) catch return;
    }

    /// Number of points (UI thread).
    pub fn count(self: *const Lane) usize {
        return self.tables[self.active.load(.seq_cst)].count;
    }

    /// The inactive table, once the audio thread is no longer reading it.
    fn beginEdit(self: *Lane) *Table {
        const target_index: u8 = 1 - self.active.load(.seq_cst);
        while (self.reading.load(.seq_cst) == target_index + 1) {
            std.Thread.yield() catch {};
        }
        return &self.tables[target_index];
    }

    fn publish(self: *Lane, target: *Table) void {
        const index: u8 = @intCast(target - &self.tables[0]);
        self.active.store(index, .seq_cst);
    }

    // ---- Audio thread ----

    fn acquire(self: *Lane) *const Table {
        while (true) {
            const index = self.active.load(.seq_cst);
            self.reading.store(index + 1, .seq_cst);
            if (self.active.load(.seq_cst) == index) return &self.tables[index];
        }
    }

    fn release(self: *Lane) void {
        self.reading.store(0, .seq_cst);
    }

    /// Whether the lane has any points. Real-time safe.
    pub fn hasPoints(self: *Lane) bool {
        const table = self.acquire();
        defer self.release();
        return table.count != 0;
    }

    /// Value at `beat`, or null when the lane has no points. Real-time safe.
    pub fn valueAt(self: *Lane, beat: f64) ?f32 {
        const table = self.acquire();
        defer self.release();
        return table.valueAt(beat);
    }

    /// Fills `out` with per-frame values starting at `start_beat`. Returns false and leaves `out`
    /// untouched when the lane has no points. Real-time safe.
    pub fn fill(self: *Lane, start_beat: f64, beat_step: f64, out: []f32) bool {
        const table = self.acquire();
        defer self.release();
        if (table.count == 0) return false;
        table.fill(start_beat, beat_step, out);
        return true;
    }
};

test "Lane - empty lane has no value" {
    var lane: Lane = .{};
    try std.testing.expect(!lane.hasPoints());
    try std.testing.expect(lane.valueAt(1.0) == null);
    var out: [4]f32 = @splat(7.0);
    try std.testing.expect(!lane.fill(0.0, 0.1, &out));
    try std.testing.expectEqual(@as(f32, 7.0), out[0]);
}

test "Lane - linear between points and held outside" {
    var lane: Lane = .{};
    try lane.addPoint(4.0, 1.0);
    try lane.addPoint(0.0, 0.0);
    try std.testing.expectEqual(@as(usize, 2), lane.count());
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), lane.valueAt(2.0).?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lane.valueAt(-3.0).?, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lane.valueAt(9.0).?, 0.0001);
}

test "Lane - a point at the same beat replaces the value" {
    var lane: Lane = .{};
    try lane.addPoint(1.0, 0.2);
    try lane.addPoint(1.0, 0.8);
    try std.testing.expectEqual(@as(usize, 1), lane.count());
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), lane.valueAt(0.0).?, 0.0001);
}

test "Lane - fill bends at a point inside the block" {
    var lane: Lane = .{};
    try lane.addPoint(0.0, 0.0);
    try lane.addPoint(1.0, 1.0);
    try lane.addPoint(2.0, 0.0);
    var out: [8]f32 = undefined;
    // Frames at beats 0.5 .. 2.0 step 0.25 -> up to the peak at beat 1, then down.
    try std.testing.expect(lane.fill(0.5, 0.25, &out));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[4], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[5], 0.0001);
}

test "Lane - clear removes the points and a full lane refuses more" {
    var lane: Lane = .{};
    for (0..MAX_POINTS) |i| try lane.addPoint(@floatFromInt(i), 0.5);
    try std.testing.expectError(Lane.Error.LaneFull, lane.addPoint(1000.0, 0.5));
    lane.clear();
    try std.testing.expectEqual(@as(usize, 0), lane.count());
    try std.testing.expect(lane.valueAt(1.0) == null);
}
