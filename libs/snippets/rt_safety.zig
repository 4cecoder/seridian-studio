//! Audio-thread rules: allocate in init/prepare, never in process.
const std = @import("std");
const testing = std.testing;

/// A fixed-length delay line: the buffer is allocated once in init and
/// process() takes no allocator.
pub const Delay = struct {
    buf: []f32,
    pos: usize = 0,

    /// Allocation happens here (control thread).
    pub fn init(gpa: std.mem.Allocator, max_samples: usize) !Delay {
        const buf = try gpa.alloc(f32, max_samples);
        @memset(buf, 0);
        return .{ .buf = buf };
    }

    pub fn deinit(self: *Delay, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
    }

    /// Audio thread: no allocator parameter, no try, no I/O, no logging.
    pub fn process(self: *Delay, io: []f32) void {
        for (io) |*s| {
            const out = self.buf[self.pos];
            self.buf[self.pos] = s.*;
            self.pos = (self.pos + 1) % self.buf.len;
            s.* = out;
        }
    }
};

test "delay shifts by its length and allocates only in init" {
    var d = try Delay.init(testing.allocator, 2);
    defer d.deinit(testing.allocator);
    var block = [_]f32{ 1, 2, 3, 4 };
    // process() cannot allocate: it is never given an allocator.
    d.process(&block);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1, 2 }, &block);
}

/// Cross-thread parameter hand-off: a float published as bits in an atomic.
pub const AtomicF32 = struct {
    bits: std.atomic.Value(u32),

    pub fn init(v: f32) AtomicF32 {
        return .{ .bits = .init(@bitCast(v)) };
    }
    pub fn load(self: *const AtomicF32) f32 {
        return @bitCast(self.bits.load(.monotonic));
    }
    pub fn store(self: *AtomicF32, v: f32) void {
        self.bits.store(@bitCast(v), .monotonic);
    }
};

test "atomic float round trip" {
    var a = AtomicF32.init(0.5);
    a.store(0.75);
    try testing.expectEqual(@as(f32, 0.75), a.load());
}
