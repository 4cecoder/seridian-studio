// =============================================================================
// Audio Clip System
// =============================================================================
// Clips represent audio/MIDI content placed on the timeline.
// Each track can have multiple clips at different positions.

const std = @import("std");
const peak_cache = @import("peak_cache.zig");
const PeakCache = peak_cache.PeakCache;
const log = std.log.scoped(.clip);

/// Unique clip identifier
pub const ClipId = u64;

/// Clip types
pub const ClipType = enum(u8) {
    audio = 0,
    midi = 1,
    instrument = 2, // Virtual instrument pattern
};

/// A clip on the timeline
pub const Clip = struct {
    /// Unique identifier
    id: ClipId,

    /// Display name
    name: [64:0]u8 = std.mem.zeroes([64:0]u8),

    /// Visual color (RGB hex)
    color: u32 = 0x7aa2f7,

    /// Type of clip
    clip_type: ClipType = .audio,

    /// Timeline position (in seconds from start)
    start_time: f64 = 0.0,

    /// Duration on timeline (in seconds)
    duration: f64 = 1.0,

    /// Offset within source content (for trimmed clips)
    source_offset: f64 = 0.0,

    /// Audio data reference (for audio clips)
    audio_samples: ?[]const f32 = null,
    audio_sample_rate: u32 = 48000,
    audio_channels: u8 = 2,

    /// Cached waveform peaks for display
    peak_cache_ptr: ?*PeakCache = null,

    /// Legacy flat peaks (for backwards compatibility)
    peaks: ?[]f32 = null,
    peaks_per_second: u32 = 100, // Peak resolution

    /// Is clip muted?
    muted: bool = false,

    /// Volume adjustment (0.0 to 1.0)
    gain: f32 = 1.0,

    /// Fade in duration (seconds)
    fade_in: f32 = 0.0,

    /// Fade out duration (seconds)
    fade_out: f32 = 0.0,

    /// Check if clip contains a specific time point
    pub fn containsTime(self: *const Clip, time: f64) bool {
        return time >= self.start_time and time < self.start_time + self.duration;
    }

    /// Check if clip overlaps with a time range
    pub fn overlapsRange(self: *const Clip, range_start: f64, range_end: f64) bool {
        const clip_end = self.start_time + self.duration;
        return self.start_time < range_end and clip_end > range_start;
    }

    /// Get the end time of this clip
    pub fn endTime(self: *const Clip) f64 {
        return self.start_time + self.duration;
    }

    /// Set the clip name
    pub fn setName(self: *Clip, name: []const u8) void {
        const len = @min(name.len, 63);
        @memcpy(self.name[0..len], name[0..len]);
        self.name[len] = 0;
    }

    /// Get the clip name as a slice
    pub fn getName(self: *const Clip) []const u8 {
        var len: usize = 0;
        while (len < 64 and self.name[len] != 0) : (len += 1) {}
        return self.name[0..len];
    }

    /// Calculate fade gain at a position within the clip (0.0 to duration)
    /// Returns a gain multiplier (0.0 to 1.0) for fade in/out
    pub fn getFadeGain(self: *const Clip, position_in_clip: f64) f32 {
        const pos = @as(f32, @floatCast(position_in_clip));
        const dur = @as(f32, @floatCast(self.duration));

        var gain_mult: f32 = 1.0;

        // Fade in
        if (self.fade_in > 0.0 and pos < self.fade_in) {
            gain_mult *= pos / self.fade_in;
        }

        // Fade out
        const fade_out_start = dur - self.fade_out;
        if (self.fade_out > 0.0 and pos > fade_out_start) {
            gain_mult *= (dur - pos) / self.fade_out;
        }

        return @max(0.0, @min(1.0, gain_mult));
    }

    /// Trim the start of the clip (moves start time forward, reduces duration)
    /// amount: positive value in seconds to trim from the start
    pub fn trimStart(self: *Clip, amount: f64) void {
        if (amount <= 0 or amount >= self.duration) return;

        self.source_offset += amount;
        self.start_time += amount;
        self.duration -= amount;

        // Adjust fade_in if it extends beyond new clip start
        if (@as(f64, self.fade_in) > self.duration) {
            self.fade_in = @floatCast(self.duration);
        }
    }

    /// Trim the end of the clip (reduces duration)
    /// amount: positive value in seconds to trim from the end
    pub fn trimEnd(self: *Clip, amount: f64) void {
        if (amount <= 0 or amount >= self.duration) return;

        self.duration -= amount;

        // Adjust fade_out if it extends beyond new clip end
        if (@as(f64, self.fade_out) > self.duration) {
            self.fade_out = @floatCast(self.duration);
        }

        // Also adjust fade_in if needed
        if (@as(f64, self.fade_in) > self.duration) {
            self.fade_in = @floatCast(self.duration);
        }
    }

    /// Set clip start time to a new position (trim or extend left edge)
    /// new_start: the new absolute start time
    pub fn setStartTime(self: *Clip, new_start: f64) void {
        if (new_start < 0) return;

        const old_start = self.start_time;
        const old_end = old_start + self.duration;

        if (new_start >= old_end) return; // Can't start past end

        const delta = new_start - old_start;
        self.start_time = new_start;
        self.duration = old_end - new_start;

        if (delta > 0) {
            // Moved start forward (trimming)
            self.source_offset += delta;
        } else {
            // Moved start backward (extending) - source_offset can't go negative
            self.source_offset = @max(0, self.source_offset + delta);
        }
    }

    /// Set clip end time (duration based on current start)
    /// new_end: the new absolute end time
    pub fn setEndTime(self: *Clip, new_end: f64) void {
        if (new_end <= self.start_time) return;
        self.duration = new_end - self.start_time;
    }
};

/// Clip list for a track
pub const ClipList = struct {
    allocator: std.mem.Allocator,
    clips: std.array_list.Aligned(Clip, null),
    next_id: ClipId = 1,

    pub fn init(allocator: std.mem.Allocator) ClipList {
        return .{
            .allocator = allocator,
            .clips = .empty,
        };
    }

    pub fn deinit(self: *ClipList) void {
        // Free any allocated peaks
        for (self.clips.items) |*clip| {
            if (clip.peaks) |peaks| {
                self.allocator.free(peaks);
            }
        }
        self.clips.deinit(self.allocator);
    }

    /// Add a new clip, returns its ID
    pub fn addClip(self: *ClipList, clip: Clip) !ClipId {
        var new_clip = clip;
        new_clip.id = self.next_id;
        self.next_id += 1;

        try self.clips.append(self.allocator, new_clip);
        log.info("Added clip '{s}' at {d:.2}s (id={})", .{
            new_clip.getName(),
            new_clip.start_time,
            new_clip.id,
        });
        return new_clip.id;
    }

    /// Remove a clip by ID
    pub fn removeClip(self: *ClipList, id: ClipId) bool {
        for (self.clips.items, 0..) |c, i| {
            if (c.id == id) {
                if (c.peaks) |peaks| {
                    self.allocator.free(peaks);
                }
                _ = self.clips.orderedRemove(i);
                log.info("Removed clip id={}", .{id});
                return true;
            }
        }
        return false;
    }

    /// Get clip by ID
    pub fn getClip(self: *ClipList, id: ClipId) ?*Clip {
        for (self.clips.items) |*c| {
            if (c.id == id) {
                return c;
            }
        }
        return null;
    }

    /// Get all clips overlapping a time range
    /// Note: Returns all clips - caller should filter using overlapsRange()
    pub fn getClipsInRange(self: *ClipList, start: f64, end: f64) []Clip {
        _ = start;
        _ = end;
        // For now, return all clips - caller filters
        return self.clips.items;
    }

    /// Get clip at specific time (first one found)
    pub fn getClipAt(self: *ClipList, time: f64) ?*Clip {
        for (self.clips.items) |*c| {
            if (c.containsTime(time)) {
                return c;
            }
        }
        return null;
    }

    /// Move a clip to a new position
    pub fn moveClip(self: *ClipList, id: ClipId, new_start: f64) bool {
        if (self.getClip(id)) |c| {
            c.start_time = if (new_start < 0) 0 else new_start;
            return true;
        }
        return false;
    }

    /// Split a clip at a given time, creating two clips
    /// Returns the ID of the new second clip, or null if split failed
    pub fn splitClip(self: *ClipList, id: ClipId, split_time: f64) !?ClipId {
        const clip = self.getClip(id) orelse return null;

        // Check if split point is within the clip
        if (split_time <= clip.start_time or split_time >= clip.endTime()) {
            return null;
        }

        // Calculate split point relative to clip
        const split_offset = split_time - clip.start_time;

        // Create the second half of the clip
        var new_clip = clip.*;
        new_clip.id = 0; // Will be assigned
        new_clip.start_time = split_time;
        new_clip.duration = clip.duration - split_offset;
        new_clip.source_offset = clip.source_offset + split_offset;
        new_clip.fade_in = 0.0; // New clip starts fresh

        // Preserve fade_out on the new clip, remove from old
        new_clip.fade_out = clip.fade_out;

        // Update the first clip
        clip.duration = split_offset;
        clip.fade_out = 0.0; // First clip ends at split point

        // Add the new clip
        const new_id = try self.addClip(new_clip);

        log.info("Split clip {} at {d:.2}s, created clip {}", .{ id, split_time, new_id });
        return new_id;
    }

    /// Get total number of clips
    pub fn count(self: *const ClipList) usize {
        return self.clips.items.len;
    }

    /// Get clip by index
    pub fn getByIndex(self: *ClipList, index: usize) ?*Clip {
        if (index < self.clips.items.len) {
            return &self.clips.items[index];
        }
        return null;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "clip basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = ClipList.init(allocator);
    defer list.deinit();

    // Add a clip
    var clip = Clip{
        .id = 0, // Will be assigned
        .start_time = 1.0,
        .duration = 2.0,
    };
    clip.setName("Test Clip");

    const id = try list.addClip(clip);
    try testing.expect(id > 0);
    try testing.expectEqual(@as(usize, 1), list.count());

    // Get clip
    const retrieved = list.getClip(id);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("Test Clip", retrieved.?.getName());

    // Check time containment
    try testing.expect(retrieved.?.containsTime(1.5));
    try testing.expect(!retrieved.?.containsTime(0.5));
    try testing.expect(!retrieved.?.containsTime(3.5));

    // Move clip
    try testing.expect(list.moveClip(id, 5.0));
    try testing.expectEqual(@as(f64, 5.0), retrieved.?.start_time);

    // Remove clip
    try testing.expect(list.removeClip(id));
    try testing.expectEqual(@as(usize, 0), list.count());
}

test "clip overlap detection" {
    const testing = std.testing;

    const clip = Clip{
        .id = 1,
        .start_time = 2.0,
        .duration = 3.0, // 2.0 to 5.0
    };

    // Overlapping ranges
    try testing.expect(clip.overlapsRange(1.0, 3.0)); // Starts before, ends inside
    try testing.expect(clip.overlapsRange(3.0, 6.0)); // Starts inside, ends after
    try testing.expect(clip.overlapsRange(3.0, 4.0)); // Fully inside
    try testing.expect(clip.overlapsRange(1.0, 6.0)); // Fully contains

    // Non-overlapping ranges
    try testing.expect(!clip.overlapsRange(0.0, 1.5)); // Before
    try testing.expect(!clip.overlapsRange(5.5, 7.0)); // After
}

test "clip fade gain calculation" {
    const testing = std.testing;

    var clip = Clip{
        .id = 1,
        .start_time = 0.0,
        .duration = 10.0,
        .fade_in = 2.0,
        .fade_out = 3.0,
    };

    // At start of fade in (position 0)
    try testing.expectApproxEqAbs(@as(f32, 0.0), clip.getFadeGain(0.0), 0.01);

    // Middle of fade in (position 1)
    try testing.expectApproxEqAbs(@as(f32, 0.5), clip.getFadeGain(1.0), 0.01);

    // End of fade in (position 2)
    try testing.expectApproxEqAbs(@as(f32, 1.0), clip.getFadeGain(2.0), 0.01);

    // Middle of clip (no fade)
    try testing.expectApproxEqAbs(@as(f32, 1.0), clip.getFadeGain(5.0), 0.01);

    // Start of fade out (position 7)
    try testing.expectApproxEqAbs(@as(f32, 1.0), clip.getFadeGain(7.0), 0.01);

    // Middle of fade out (position 8.5)
    try testing.expectApproxEqAbs(@as(f32, 0.5), clip.getFadeGain(8.5), 0.01);

    // End of clip (position 10)
    try testing.expectApproxEqAbs(@as(f32, 0.0), clip.getFadeGain(10.0), 0.01);
}

test "clip trim start" {
    const testing = std.testing;

    var clip = Clip{
        .id = 1,
        .start_time = 5.0,
        .duration = 10.0,
        .source_offset = 0.0,
        .fade_in = 1.0,
    };

    // Trim 2 seconds from start
    clip.trimStart(2.0);

    try testing.expectApproxEqAbs(@as(f64, 7.0), clip.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 8.0), clip.duration, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2.0), clip.source_offset, 0.001);

    // Fade should still be valid (1.0 < 8.0 duration)
    try testing.expectApproxEqAbs(@as(f32, 1.0), clip.fade_in, 0.001);
}

test "clip trim end" {
    const testing = std.testing;

    var clip = Clip{
        .id = 1,
        .start_time = 0.0,
        .duration = 10.0,
        .fade_out = 2.0,
    };

    // Trim 3 seconds from end
    clip.trimEnd(3.0);

    try testing.expectApproxEqAbs(@as(f64, 0.0), clip.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 7.0), clip.duration, 0.001);

    // Fade out should still be valid
    try testing.expectApproxEqAbs(@as(f32, 2.0), clip.fade_out, 0.001);
}

test "clip trim adjusts fades" {
    const testing = std.testing;

    var clip = Clip{
        .id = 1,
        .start_time = 0.0,
        .duration = 10.0,
        .fade_in = 5.0,
        .fade_out = 5.0,
    };

    // Trim to 3 seconds duration
    clip.trimEnd(7.0);

    // Both fades should be adjusted to fit
    try testing.expectApproxEqAbs(@as(f64, 3.0), clip.duration, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.0), clip.fade_in, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.0), clip.fade_out, 0.001);
}

test "clip set start time" {
    const testing = std.testing;

    var clip = Clip{
        .id = 1,
        .start_time = 5.0,
        .duration = 10.0, // 5.0 to 15.0
        .source_offset = 0.0,
    };

    // Move start forward (trim)
    clip.setStartTime(7.0);
    try testing.expectApproxEqAbs(@as(f64, 7.0), clip.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 8.0), clip.duration, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2.0), clip.source_offset, 0.001);

    // Move start backward (extend) - source_offset can't go below 0
    clip.setStartTime(6.0);
    try testing.expectApproxEqAbs(@as(f64, 6.0), clip.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 9.0), clip.duration, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), clip.source_offset, 0.001);
}

test "clip set end time" {
    const testing = std.testing;

    var clip = Clip{
        .id = 1,
        .start_time = 5.0,
        .duration = 10.0, // 5.0 to 15.0
    };

    // Shorten clip
    clip.setEndTime(12.0);
    try testing.expectApproxEqAbs(@as(f64, 5.0), clip.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 7.0), clip.duration, 0.001);

    // Extend clip
    clip.setEndTime(20.0);
    try testing.expectApproxEqAbs(@as(f64, 15.0), clip.duration, 0.001);

    // Can't set end before start
    clip.setEndTime(3.0);
    try testing.expectApproxEqAbs(@as(f64, 15.0), clip.duration, 0.001);
}

test "clip split" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = ClipList.init(allocator);
    defer list.deinit();

    var clip = Clip{
        .id = 0,
        .start_time = 0.0,
        .duration = 10.0,
        .source_offset = 0.0,
        .fade_in = 0.5,
        .fade_out = 1.0,
    };
    clip.setName("Original");

    const id = try list.addClip(clip);

    // Split at 4.0
    const new_id = try list.splitClip(id, 4.0);
    try testing.expect(new_id != null);

    // Check first part
    const first = list.getClip(id).?;
    try testing.expectApproxEqAbs(@as(f64, 0.0), first.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 4.0), first.duration, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), first.fade_in, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), first.fade_out, 0.001); // Fade out removed at split

    // Check second part
    const second = list.getClip(new_id.?).?;
    try testing.expectApproxEqAbs(@as(f64, 4.0), second.start_time, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 6.0), second.duration, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 4.0), second.source_offset, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), second.fade_in, 0.001); // Fade in removed at split
    try testing.expectApproxEqAbs(@as(f32, 1.0), second.fade_out, 0.001);
}

test "clip split invalid positions" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = ClipList.init(allocator);
    defer list.deinit();

    const clip = Clip{
        .id = 0,
        .start_time = 5.0,
        .duration = 10.0, // 5.0 to 15.0
    };

    const id = try list.addClip(clip);

    // Can't split at clip start
    const result1 = try list.splitClip(id, 5.0);
    try testing.expect(result1 == null);

    // Can't split at clip end
    const result2 = try list.splitClip(id, 15.0);
    try testing.expect(result2 == null);

    // Can't split before clip
    const result3 = try list.splitClip(id, 3.0);
    try testing.expect(result3 == null);

    // Can't split after clip
    const result4 = try list.splitClip(id, 20.0);
    try testing.expect(result4 == null);

    // Non-existent clip
    const result5 = try list.splitClip(999, 10.0);
    try testing.expect(result5 == null);
}

test "clip list get clip at time" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var list = ClipList.init(allocator);
    defer list.deinit();

    var clip1 = Clip{ .id = 0, .start_time = 0.0, .duration = 5.0 };
    clip1.setName("Clip 1");
    _ = try list.addClip(clip1);

    var clip2 = Clip{ .id = 0, .start_time = 10.0, .duration = 5.0 };
    clip2.setName("Clip 2");
    _ = try list.addClip(clip2);

    // Get clip at time 2.0 (should be Clip 1)
    const found1 = list.getClipAt(2.0);
    try testing.expect(found1 != null);
    try testing.expectEqualStrings("Clip 1", found1.?.getName());

    // Get clip at time 12.0 (should be Clip 2)
    const found2 = list.getClipAt(12.0);
    try testing.expect(found2 != null);
    try testing.expectEqualStrings("Clip 2", found2.?.getName());

    // Get clip at gap
    const found3 = list.getClipAt(7.0);
    try testing.expect(found3 == null);
}

test "clip gain" {
    const testing = std.testing;

    var clip = Clip{
        .id = 1,
        .gain = 0.5,
    };

    try testing.expectApproxEqAbs(@as(f32, 0.5), clip.gain, 0.001);

    clip.gain = 1.0;
    try testing.expectApproxEqAbs(@as(f32, 1.0), clip.gain, 0.001);
}
