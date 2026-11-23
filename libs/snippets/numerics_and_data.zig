const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;

// atomics
const Flag = struct {
    v: std.atomic.Value(u32) = .init(0),
};
test "atomics" {
    var f = Flag{};
    f.v.store(3, .release);
    try testing.expectEqual(@as(u32, 3), f.v.load(.acquire));
    _ = f.v.fetchAdd(1, .monotonic);
    try testing.expectEqual(@as(u32, 4), f.v.load(.monotonic));
    const old = f.v.swap(9, .acq_rel);
    try testing.expectEqual(@as(u32, 4), old);
    try testing.expect(f.v.cmpxchgStrong(9, 10, .acq_rel, .monotonic) == null);
    var b = std.atomic.Value(bool).init(false);
    b.store(true, .release);
    var fl = std.atomic.Value(u32).init(@bitCast(@as(f32, 0.5)));
    fl.store(@bitCast(@as(f32, 0.25)), .monotonic);
    try testing.expectEqual(@as(f32, 0.25), @as(f32, @bitCast(fl.load(.monotonic))));
}

// json
const Cfg = struct { name: []const u8, rate: u32 = 48000, tags: []const []const u8 = &.{}, gain: ?f32 = null };
test "json" {
    const parsed = try std.json.parseFromSlice(Cfg, gpa, "{\"name\":\"x\",\"tags\":[\"a\",\"b\"]}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try testing.expectEqualStrings("x", parsed.value.name);
    try testing.expectEqual(@as(u32, 48000), parsed.value.rate);
    try testing.expectEqual(@as(usize, 2), parsed.value.tags.len);
    const out = try std.json.Stringify.valueAlloc(gpa, Cfg{ .name = "y" }, .{});
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"y\"") != null);
    // dynamic
    const dyn = try std.json.parseFromSlice(std.json.Value, gpa, "{\"a\":[1,2.5,\"s\",null,true]}", .{});
    defer dyn.deinit();
    const arr = dyn.value.object.get("a").?.array;
    try testing.expectEqual(@as(i64, 1), arr.items[0].integer);
    try testing.expectEqual(@as(f64, 2.5), arr.items[1].float);
}

// math
test "math" {
    const x: f32 = 2.0;
    try testing.expectApproxEqAbs(@as(f32, 1.4142135), @sqrt(x), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.9092974), @sin(x), 1e-6);
    _ = @cos(x);
    _ = @exp(x);
    _ = @exp2(x);
    _ = @log(x);
    _ = @log2(x);
    _ = @log10(x);
    _ = @abs(x);
    _ = @floor(x);
    _ = @ceil(x);
    _ = @round(x);
    _ = @trunc(x);
    _ = std.math.pow(f32, x, 3.0);
    _ = std.math.tanh(x);
    _ = std.math.atan2(x, x);
    _ = std.math.hypot(x, x);
    _ = std.math.clamp(x, 0, 1);
    _ = @min(x, 1);
    _ = @max(x, 1);
    _ = std.math.sign(x);
    _ = std.math.isNan(x);
    _ = std.math.isFinite(x);
    _ = @mod(-1.5, 1.0); // Rust rem_euclid
    _ = @rem(-1.5, 1.0); // Rust %
    _ = std.math.degreesToRadians(x);
    _ = std.math.pi;
    _ = std.math.floatEps(f32);
    _ = std.math.floatMax(f32);
    _ = std.math.inf(f32);
    _ = std.math.nan(f32);
    _ = std.math.maxInt(u32);
    _ = std.math.copysign(x, -1);
    _ = @mulAdd(f32, x, x, x);
    const n: usize = 7;
    const f: f32 = @floatFromInt(n);
    const i: i32 = @intFromFloat(f);
    try testing.expectEqual(@as(i32, 7), i);
    try testing.expectEqual(@as(usize, 4), std.math.powi(usize, 2, 2) catch unreachable);
    _ = std.math.log2_int(u32, 8);
    _ = std.math.isPowerOfTwo(@as(u32, 8));
    _ = std.math.ceilPowerOfTwo(u32, 5) catch unreachable;
    try testing.expectEqual(@as(usize, 3), @divFloor(@as(usize, 7), 2));
    try testing.expectEqual(@as(usize, 4), std.math.divCeil(usize, 7, 2) catch unreachable);
}

// integers
test "ints" {
    var a: u8 = 250;
    a +%= 10; // wrapping_add
    try testing.expectEqual(@as(u8, 4), a);
    const s: u8 = 250 +| @as(u8, 10); // saturating_add
    try testing.expectEqual(@as(u8, 255), s);
    const c = std.math.add(u8, 250, 10);
    try testing.expectError(error.Overflow, c); // checked_add
    const ov = @addWithOverflow(@as(u8, 250), 10); // overflowing_add
    try testing.expectEqual(@as(u8, 4), ov[0]);
    try testing.expectEqual(@as(u1, 1), ov[1]);
    const big: i64 = 300;
    const t: u8 = @truncate(@as(u64, @bitCast(big))); // `as u8` truncation
    try testing.expectEqual(@as(u8, 44), t);
    const sat: u8 = @intCast(std.math.clamp(big, 0, 255)); // saturating cast
    try testing.expectEqual(@as(u8, 255), sat);
    const sh: u32 = @as(u32, 1) << 5;
    try testing.expectEqual(@as(u32, 32), sh);
    const rl = std.math.rotl(u32, 1, 33);
    try testing.expectEqual(@as(u32, 2), rl);
    const wm = @as(u32, 7) *% 3;
    _ = wm;
    // Rust float->int `as` saturates; @intFromFloat is UB out of range
    const fv: f32 = 1e10;
    const si: i32 = @intFromFloat(std.math.clamp(fv, -2147483648.0, 2147483520.0));
    _ = si;
}

// random
test "prng" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const f = rng.float(f32);
        try testing.expect(f >= 0 and f < 1);
        const v = rng.intRangeAtMost(i32, -5, 5);
        try testing.expect(v >= -5 and v <= 5);
        const g = rng.floatNorm(f32);
        try testing.expect(std.math.isFinite(g));
        _ = rng.boolean();
        _ = rng.uintLessThan(u32, 10);
    }
    var buf: [8]f32 = undefined;
    for (&buf) |*s| s.* = rng.float(f32) * 2 - 1;
}

// strings
test "strings" {
    const s = try std.fmt.allocPrint(gpa, "{s}-{d}-{d:.2}", .{ "a", 3, 1.5 });
    defer gpa.free(s);
    try testing.expectEqualStrings("a-3-1.50", s);
    var buf: [32]u8 = undefined;
    const t = try std.fmt.bufPrint(&buf, "{d}", .{42});
    try testing.expectEqualStrings("42", t);
    const d = try gpa.dupe(u8, "hi");
    defer gpa.free(d);
    try testing.expect(std.mem.startsWith(u8, d, "h"));
    try testing.expect(std.mem.eql(u8, d, "hi"));
    const n = try std.fmt.parseInt(i32, "-12", 10);
    const fl = try std.fmt.parseFloat(f32, "1.5");
    try testing.expectEqual(@as(i32, -12), n);
    try testing.expectEqual(@as(f32, 1.5), fl);
    var it = std.mem.splitScalar(u8, "a,b", ',');
    _ = it.next();
    var lower: [3]u8 = undefined;
    _ = std.ascii.lowerString(&lower, "ABC");
    var al = std.ArrayList(u8).empty;
    defer al.deinit(gpa);
    try al.print(gpa, "{d}", .{5});
}

// testing helpers
test "testing" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), 1.0000001, 1e-6);
    try testing.expectApproxEqRel(@as(f32, 100.0), 100.001, 1e-4);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, &[_]u8{ 1, 2 });
    try testing.expect(true);
    const arr = [_]f32{ 1, 2 };
    for (arr) |v| try testing.expect(!std.math.isNan(v));
}

// const generics
fn Ring(comptime T: type, comptime N: usize) type {
    return struct {
        const Self = @This();
        data: [N]T = @splat(0),
        pos: usize = 0,
        fn push(self: *Self, v: T) void {
            self.data[self.pos] = v;
            self.pos = (self.pos + 1) % N;
        }
    };
}
test "generic" {
    var r = Ring(f32, 4){};
    r.push(1);
    try testing.expectEqual(@as(usize, 1), r.pos);
    // Default / struct update syntax
    const Cfg2 = struct { a: u32 = 1, b: f32 = 2 };
    const c = Cfg2{};
    const d: Cfg2 = .{ .a = 5 };
    try testing.expectEqual(@as(u32, 1), c.a);
    try testing.expectEqual(@as(f32, 2), d.b);
    // enum
    const Mode = enum(u8) { off, on, _ };
    const m: Mode = @fromBackingInt(@intCast(1));
    try testing.expectEqual(Mode.on, m);
    try testing.expectEqualStrings("on", @tagName(m));
    const mm = std.enums.fromInt(Mode, @as(u8, 0)).?;
    try testing.expectEqual(Mode.off, mm);
}
