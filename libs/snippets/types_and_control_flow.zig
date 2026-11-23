const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;

// 1 errors
const ParseError = error{ Empty, BadDigit };
fn parseDigit(s: []const u8) ParseError!u8 {
    if (s.len == 0) return error.Empty;
    if (s[0] < '0' or s[0] > '9') return error.BadDigit;
    return s[0] - '0';
}
fn twice(s: []const u8) ParseError!u8 {
    const d = try parseDigit(s);
    return d * 2;
}
test "errors" {
    try testing.expectEqual(@as(u8, 6), try twice("3"));
    try testing.expectError(error.Empty, twice(""));
    const v = parseDigit("x") catch |e| switch (e) {
        error.Empty => 0,
        error.BadDigit => 99,
    };
    try testing.expectEqual(@as(u8, 99), v);
    const w = parseDigit("") catch 7;
    try testing.expectEqual(@as(u8, 7), w);
}
const Owned = struct {
    buf: []f32,
    fn init(a: std.mem.Allocator, n: usize) !Owned {
        const buf = try a.alloc(f32, n);
        errdefer a.free(buf);
        @memset(buf, 0);
        return .{ .buf = buf };
    }
    fn deinit(self: *Owned, a: std.mem.Allocator) void {
        a.free(self.buf);
    }
};
test "owned" {
    var o = try Owned.init(gpa, 4);
    defer o.deinit(gpa);
    try testing.expectEqual(@as(usize, 4), o.buf.len);
}

// 2 option
fn find(xs: []const i32, x: i32) ?usize {
    for (xs, 0..) |v, i| if (v == x) return i;
    return null;
}
test "option" {
    const xs = [_]i32{ 1, 2, 3 };
    if (find(&xs, 2)) |i| try testing.expectEqual(@as(usize, 1), i) else return error.Fail;
    try testing.expectEqual(@as(usize, 0), find(&xs, 9) orelse 0);
    try testing.expect(find(&xs, 3).? == 2);
    var o: ?i32 = 5;
    if (o) |*p| p.* += 1;
    try testing.expectEqual(@as(?i32, 6), o);
    // while let Some(x) = it.next()
    var n: ?u8 = 3;
    while (n) |k| : (n = if (k > 0) k - 1 else null) {}
}

// 3 tagged unions
const Event = union(enum) {
    note_on: struct { note: u8, vel: u8 },
    note_off: u8,
    pitch_bend: i16,
    reset,
};
fn describe(e: Event) u32 {
    return switch (e) {
        .note_on => |n| n.note + n.vel,
        .note_off => |n| n,
        .pitch_bend => |b| @intCast(@abs(b)),
        .reset => 0,
    };
}
test "union" {
    try testing.expectEqual(@as(u32, 70), describe(.{ .note_on = .{ .note = 60, .vel = 10 } }));
    try testing.expectEqual(@as(u32, 5), describe(.{ .pitch_bend = -5 }));
    try testing.expectEqual(@as(u32, 0), describe(.reset));
    const e: Event = .{ .note_off = 3 };
    if (e == .note_off) try testing.expectEqual(@as(u8, 3), e.note_off);
    // match with range and guard
    const x: u8 = 7;
    const r: u8 = switch (x) {
        0 => 0,
        1...5 => 1,
        6, 7 => if (x == 7) 2 else 3,
        else => 4,
    };
    try testing.expectEqual(@as(u8, 2), r);
}

// 4 traits
const Processor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    const VTable = struct {
        process: *const fn (ptr: *anyopaque, buf: []f32) void,
    };
    fn process(self: Processor, buf: []f32) void {
        self.vtable.process(self.ptr, buf);
    }
};
const Gain = struct {
    g: f32,
    fn processImpl(ptr: *anyopaque, buf: []f32) void {
        const self: *Gain = @ptrCast(@alignCast(ptr));
        for (buf) |*s| s.* *= self.g;
    }
    fn processor(self: *Gain) Processor {
        return .{ .ptr = self, .vtable = &.{ .process = processImpl } };
    }
};
fn runStatic(comptime P: type, p: *P, buf: []f32) void {
    p.processImpl2(buf);
}
const Gain2 = struct {
    g: f32,
    fn processImpl2(self: *Gain2, buf: []f32) void {
        for (buf) |*s| s.* *= self.g;
    }
};
test "traits" {
    var g = Gain{ .g = 2 };
    var buf = [_]f32{ 1, 2 };
    g.processor().process(&buf);
    try testing.expectEqual(@as(f32, 4), buf[1]);
    var g2 = Gain2{ .g = 3 };
    runStatic(Gain2, &g2, &buf);
    try testing.expectEqual(@as(f32, 12), buf[1]);
}

// 5 ArrayList
test "arraylist" {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(gpa);
    try list.append(gpa, 1);
    try list.appendSlice(gpa, &.{ 2, 3, 4 });
    try list.ensureTotalCapacity(gpa, 16);
    list.appendAssumeCapacity(5);
    try list.insert(gpa, 0, 9);
    _ = list.orderedRemove(0);
    _ = list.swapRemove(0);
    try testing.expectEqual(@as(usize, 4), list.items.len);
    const last = list.pop();
    try testing.expectEqual(@as(?u32, 4), last);
    list.clearRetainingCapacity();
    var owned = try list.toOwnedSlice(gpa);
    gpa.free(owned);
    owned = &.{};
    var pre = try std.ArrayList(u8).initCapacity(gpa, 8);
    defer pre.deinit(gpa);
    pre.appendNTimesAssumeCapacity(0, 4);
    try pre.resize(gpa, 6);
}

// 6 maps
test "hashmap" {
    var m: std.AutoHashMap(u32, f32) = .init(gpa);
    defer m.deinit();
    try m.put(1, 1.5);
    try testing.expectEqual(@as(?f32, 1.5), m.get(1));
    if (m.getPtr(1)) |p| p.* += 1;
    const gop = try m.getOrPut(2);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    try testing.expect(m.contains(2));
    var it = m.iterator();
    var n: usize = 0;
    while (it.next()) |e| {
        _ = e.key_ptr.*;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    _ = m.remove(1);
    try testing.expectEqual(@as(u32, 1), m.count());
    var sm: std.StringHashMap(u8) = .init(gpa);
    defer sm.deinit();
    try sm.put("a", 1);
    try testing.expectEqual(@as(?u8, 1), sm.get("a"));
    // unmanaged
    var um: std.AutoHashMapUnmanaged(u8, u8) = .empty;
    defer um.deinit(gpa);
    try um.put(gpa, 1, 2);
}

// 7 iteration
test "iter" {
    const a = [_]i32{ 1, 2, 3 };
    const b = [_]i32{ 4, 5, 6 };
    var sum: i32 = 0;
    for (a, b) |x, y| sum += x * y;
    try testing.expectEqual(@as(i32, 32), sum);
    var i: usize = 0;
    while (i < a.len) : (i += 2) {}
    var k: usize = 0;
    while (k < a.len) : (k += 1) {
        _ = a[k];
    }
    var windows = std.mem.window(i32, &a, 2, 1);
    var cnt: usize = 0;
    while (windows.next()) |_| cnt += 1;
    try testing.expectEqual(@as(usize, 2), cnt);
    var ch = std.mem.tokenizeScalar(u8, "a b  c", ' ');
    var words: usize = 0;
    while (ch.next()) |_| words += 1;
    try testing.expectEqual(@as(usize, 3), words);
    const total = blk: {
        var t: i32 = 0;
        for (a) |x| t += x;
        break :blk t;
    };
    try testing.expectEqual(@as(i32, 6), total);
    outer: for (a) |x| {
        for (b) |y| {
            if (x * y > 8) break :outer;
        }
    }
    var j: u32 = 0;
    while (true) {
        j += 1;
        if (j == 3) break;
    }
}
