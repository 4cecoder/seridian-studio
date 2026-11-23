const std = @import("std");

/// Reference-counted audio buffer for efficient memory sharing
pub const RefCountedAudioBuffer = struct {
    data: []f32,
    refcount: std.atomic.Value(usize),
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, samples: []const f32) !*RefCountedAudioBuffer {
        const buf = try allocator.create(RefCountedAudioBuffer);
        const data = try allocator.dupe(f32, samples);

        buf.* = .{
            .data = data,
            .refcount = std.atomic.Value(usize).init(1),
            .allocator = allocator,
        };

        return buf;
    }

    /// Increment reference count (thread-safe)
    pub fn retain(self: *RefCountedAudioBuffer) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    /// Decrement reference count and free if zero (thread-safe)
    pub fn release(self: *RefCountedAudioBuffer) void {
        const prev = self.refcount.fetchSub(1, .monotonic);
        if (prev == 1) {
            // Last reference - free memory
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }

    /// Get current reference count (for debugging)
    pub fn getRefCount(self: *const RefCountedAudioBuffer) usize {
        return self.refcount.load(.monotonic);
    }
};

test "RefCountedAudioBuffer reference counting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const samples = [_]f32{ 1.0, 2.0, 3.0, 4.0 };

    var buf = try RefCountedAudioBuffer.create(allocator, &samples);
    try testing.expectEqual(@as(usize, 1), buf.getRefCount());

    // Retain increases count
    buf.retain();
    try testing.expectEqual(@as(usize, 2), buf.getRefCount());

    buf.retain();
    try testing.expectEqual(@as(usize, 3), buf.getRefCount());

    // Release decreases count
    buf.release();
    try testing.expectEqual(@as(usize, 2), buf.getRefCount());

    buf.release();
    try testing.expectEqual(@as(usize, 1), buf.getRefCount());

    // Last release frees memory
    buf.release();
    // buf is now freed, can't check refcount
}
