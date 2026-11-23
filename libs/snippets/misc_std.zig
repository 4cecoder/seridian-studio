const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
test "mutex" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var m: std.Io.Mutex = .init;
    m.lockUncancelable(io);
    m.unlock(io);
    try testing.expect(m.tryLock());
    m.unlock(io);
}
test "managed" {
    var l = std.array_list.Managed(u8).init(gpa);
    defer l.deinit();
    try l.append(1);
}
test "time" {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    _ = std.time.ns_per_s;
}
test "log" {
    const log = std.log.scoped(.probe);
    log.debug("x {d}", .{1});
}
test "sorted insert / dedupe / bit ops" {
    try testing.expectEqual(@as(u32, 3), @popCount(@as(u32, 7)));
    try testing.expectEqual(@as(u32, 29), @clz(@as(u32, 7)));
    try testing.expectEqual(@as(u32, 1), @ctz(@as(u32, 2)));
    try testing.expectEqual(@as(u32, 0x01000000), @byteSwap(@as(u32, 1)));
    const bytes = std.mem.toBytes(@as(u32, 1));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &bytes, .little));
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, 258, .big);
    try testing.expectEqual(@as(u8, 2), b[3]);
    const f: f32 = @bitCast(@as(u32, 0x3f800000));
    try testing.expectEqual(@as(f32, 1), f);
}

test "rust semantics: signum, signed division, shifts, chunks, rounding" {
    try std.testing.expectEqual(@as(f32, 0), std.math.sign(@as(f32, 0)));
    var a: i32 = -7;
    var b: i32 = 2;
    _ = .{ &a, &b };
    try std.testing.expectEqual(@as(i32, -3), @divTrunc(a, b));
    try std.testing.expectEqual(@as(i32, -1), @rem(a, b));
    try std.testing.expectEqual(@as(i32, 1), @mod(a, b));
    var n: usize = 5;
    _ = &n;
    const sh: u32 = @as(u32, 1) << @as(u5, @intCast(n));
    try std.testing.expectEqual(@as(u32, 32), sh);
    const arr = [_]i32{ 1, 2, 3, 4, 5 };
    var w = std.mem.window(i32, &arr, 2, 2);
    var cnt: usize = 0;
    var last: usize = 0;
    while (w.next()) |s| {
        cnt += 1;
        last = s.len;
    }
    try std.testing.expectEqual(@as(usize, 3), cnt);
    try std.testing.expectEqual(@as(usize, 1), last);
    try std.testing.expectEqual(@as(f32, 3), @round(@as(f32, 2.5)));
    try std.testing.expectEqual(@as(f32, -3), @round(@as(f32, -2.5)));
}
