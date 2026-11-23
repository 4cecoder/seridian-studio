//! Cross-thread atomics for float parameters.
//!
//! An audio thread must never lock, so a float parameter crosses threads as
//! its bit pattern in an atomic word. Reads and writes of a 32-bit word are
//! single-copy atomic on every platform Seridian ships; the reader sees either
//! the old or the new value, never a torn mix.

const std = @import("std");
const testing = std.testing;

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

test "AtomicF32: round-trips values including infinities" {
    var f = AtomicF32.init(0.5);
    try testing.expectEqual(@as(f32, 0.5), f.load());
    const values = [_]f32{ 0.0, -1.5, 96_000.0, std.math.inf(f32), -std.math.inf(f32), std.math.nan(f32) };
    for (values) |v| {
        f.store(v);
        const got = f.load();
        if (std.math.isNan(v)) {
            try testing.expect(std.math.isNan(got));
        } else {
            try testing.expectEqual(v, got);
        }
    }
}

test "AtomicF32: a value stored on another thread is observed" {
    var f = AtomicF32.init(0.0);

    const Writer = struct {
        fn run(a: *AtomicF32) void {
            var v: f32 = 1.0;
            while (v <= 16.0) : (v += 1.0) a.store(v);
        }
    };
    const t = try std.Thread.spawn(.{}, Writer.run, .{&f});
    // The final store is 16.0; the thread's exit gives it a happens-before edge.
    t.join();
    try testing.expectEqual(@as(f32, 16.0), f.load());
}
