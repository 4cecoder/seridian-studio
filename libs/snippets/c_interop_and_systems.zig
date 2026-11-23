const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const gpa = testing.allocator;

// C externs without @cImport
const CFile = opaque {};
extern "c" fn strlen(s: [*:0]const u8) usize;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*CFile;
extern "c" fn fclose(f: *CFile) c_int;
const Pt = extern struct { x: c_int, y: f64 };
const Callback = *const fn (user: ?*anyopaque, v: f32) callconv(.c) void;
fn cb(user: ?*anyopaque, v: f32) callconv(.c) void {
    const p: *f32 = @ptrCast(@alignCast(user.?));
    p.* = v;
}
export fn seridian_test_export(a: c_int) callconv(.c) c_int {
    return a + 1;
}
const Flags = packed struct(u8) { a: bool = false, b: bool = false, rest: u6 = 0 };
test "c" {
    try testing.expectEqual(@as(usize, 3), strlen("abc"));
    var out: f32 = 0;
    const f: Callback = &cb;
    f(&out, 2.5);
    try testing.expectEqual(@as(f32, 2.5), out);
    try testing.expectEqual(@as(usize, 16), @sizeOf(Pt));
    try testing.expectEqual(@as(usize, 1), @sizeOf(Flags));
    const fl: Flags = .{ .b = true };
    try testing.expectEqual(@as(u8, 2), @as(u8, @bitCast(fl)));
    const c_str: [*:0]const u8 = "xyz";
    const sl = std.mem.span(c_str);
    try testing.expectEqual(@as(usize, 3), sl.len);
    var arr = [_]f32{ 1, 2, 3 };
    const raw: [*]f32 = &arr;
    const back = raw[0..3];
    try testing.expectEqual(@as(usize, 3), back.len);
    try testing.expect(fopen("/nonexistent/x", "r") == null);
    // platform-conditional externs
    if (builtin.os.tag == .macos) {
        // declare per-OS functions inside a comptime-selected struct
        const mach = struct {
            extern "c" fn mach_absolute_time() u64;
        };
        _ = mach.mach_absolute_time();
    }
}

// dynlib
test "dynlib" {
    const name = if (builtin.os.tag == .macos) "/usr/lib/libSystem.B.dylib" else "libc.so.6";
    var lib = try std.DynLib.open(name);
    defer lib.close();
    const Fn = *const fn ([*:0]const u8) callconv(.c) usize;
    const f = lib.lookup(Fn, "strlen") orelse return error.MissingSymbol;
    try testing.expectEqual(@as(usize, 2), f("hi"));
}

// concurrency
test "threads" {
    var counter = std.atomic.Value(u32).init(0);
    const Worker = struct {
        fn run(c: *std.atomic.Value(u32)) void {
            _ = c.fetchAdd(1, .monotonic);
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{&counter});
    t.join();
    try testing.expectEqual(@as(u32, 1), counter.load(.monotonic));
}

// allocators
test "allocators" {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const a = fba.allocator();
    const xs = try a.alloc(f32, 8);
    try testing.expectEqual(@as(usize, 8), xs.len);
    fba.reset();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    _ = try arena.allocator().alloc(u8, 100);
    const one = try gpa.create(Pt);
    defer gpa.destroy(one);
    one.* = .{ .x = 1, .y = 2 };
}

// sorting / mem
test "sort" {
    var xs = [_]f32{ 3, 1, 2 };
    std.mem.sort(f32, &xs, {}, std.sort.asc(f32));
    try testing.expectEqual(@as(f32, 1), xs[0]);
    const Item = struct { t: u32 };
    var items = [_]Item{ .{ .t = 5 }, .{ .t = 2 } };
    std.mem.sort(Item, &items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return a.t < b.t;
        }
    }.lt);
    try testing.expectEqual(@as(u32, 2), items[0].t);
    const idx = std.sort.binarySearch(f32, &xs, @as(f32, 2), struct {
        fn order(k: f32, e: f32) std.math.Order {
            return std.math.order(k, e);
        }
    }.order);
    try testing.expectEqual(@as(?usize, 1), idx);
    var dst: [3]f32 = undefined;
    @memcpy(&dst, &xs);
    @memset(&dst, 0);
    std.mem.copyForwards(f32, dst[0..2], xs[1..3]);
    std.mem.reverse(f32, &dst);
    try testing.expectEqual(@as(?usize, 0), std.mem.indexOfScalar(f32, &xs, 1));
}

// SIMD
test "simd" {
    const V = @Vector(4, f32);
    const a: V = .{ 1, 2, 3, 4 };
    const b: V = @splat(2);
    const c = a * b + a;
    try testing.expectEqual(@as(f32, 12), c[3]);
    try testing.expectEqual(@as(f32, 30), @reduce(.Add, c));
    const arr: [4]f32 = c;
    _ = arr;
}

// file I/O (non-audio thread only)
test "file io" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "zz_probe.tmp";
    {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hello");
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
    defer gpa.free(data);
    try testing.expectEqualStrings("hello", data);
}

// state machines / misc
test "misc" {
    std.debug.assert(true);
    const T = struct {
        v: u8,
        fn init() @This() {
            return .{ .v = 1 };
        }
    };
    var t = T.init();
    t.v += 1;
    try testing.expectEqual(@as(usize, 2), @as(usize, t.v));
    const o: ?*T = &t;
    if (o) |p| p.v = 0;
    var tmp = [_]u8{ 1, 2 };
    std.mem.swap(u8, &tmp[0], &tmp[1]);
    try testing.expectEqual(@as(u8, 2), tmp[0]);
    comptime std.debug.assert(@sizeOf(u32) == 4);
    // unreachable / panic
    // std.debug.panic("msg {d}", .{1});
}
