//! Remembers the track names the window last showed, so a rename (from the command socket, `open` or a
//! future rename dialog) can tell which labels are stale. Pure: no Raven, no engine.

const std = @import("std");

/// Tracks in the mixer.
pub const TRACKS = 8;
/// Bytes kept per name, NUL included.
pub const NAME_CAPACITY = 64;

pub const NameCache = struct {
    names: [TRACKS][NAME_CAPACITY]u8 = @as([TRACKS][NAME_CAPACITY]u8, @splat(@as([NAME_CAPACITY]u8, @splat(0)))),
    known: [TRACKS]bool = @as([TRACKS]bool, @splat(false)),

    /// Records `name` for `track`. True when it differs from what was shown before (or nothing was shown),
    /// that is, when the track's labels must be refreshed. False for an unchanged name or a bad track.
    pub fn update(self: *NameCache, track: usize, name: []const u8) bool {
        if (track >= TRACKS) return false;
        const kept = name[0..@min(name.len, NAME_CAPACITY - 1)];
        const slot = &self.names[track];
        const current = std.mem.sliceTo(slot, 0);
        if (self.known[track] and std.mem.eql(u8, current, kept)) return false;
        @memset(slot, 0);
        @memcpy(slot[0..kept.len], kept);
        self.known[track] = true;
        return true;
    }

    /// Forgets everything, so the next `update` of every track reports a change.
    pub fn reset(self: *NameCache) void {
        self.known = @as([TRACKS]bool, @splat(false));
    }
};

test "update reports a name the first time and each time it changes" {
    var cache: NameCache = .{};
    try std.testing.expect(cache.update(0, "Track 1"));
    try std.testing.expect(!cache.update(0, "Track 1"));
    try std.testing.expect(cache.update(0, "Bass"));
    try std.testing.expect(!cache.update(0, "Bass"));
    try std.testing.expect(cache.update(0, "Track 1"));
    try std.testing.expect(cache.update(7, "Pad"));
    try std.testing.expect(!cache.update(7, "Pad"));
    // Another track is not affected.
    try std.testing.expect(!cache.update(0, "Track 1"));
}

test "update ignores a bad track and cuts a long name" {
    var cache: NameCache = .{};
    try std.testing.expect(!cache.update(8, "x"));
    const long: [100]u8 = @splat('n');
    try std.testing.expect(cache.update(1, &long));
    try std.testing.expect(!cache.update(1, &long));
}

test "reset makes every name stale again" {
    var cache: NameCache = .{};
    _ = cache.update(2, "Lead");
    try std.testing.expect(!cache.update(2, "Lead"));
    cache.reset();
    try std.testing.expect(cache.update(2, "Lead"));
}
