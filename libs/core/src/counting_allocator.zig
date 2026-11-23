//! Counts every call into the wrapped allocator, so a test can prove that a
//! code path asks for memory at most where it is allowed to.
//!
//! Use it in tests: wrap `std.testing.allocator`, run `init`, note the count,
//! run the real-time path, and assert the count did not move. This is the
//! shared counting allocator the other libraries reference.

const std = @import("std");
const testing = std.testing;

pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    calls: usize = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Forgets the counts so far (the allocations themselves stay alive).
    pub fn reset(self: *CountingAllocator) void {
        self.calls = 0;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "CountingAllocator: counts alloc and free through the public API" {
    var counting: CountingAllocator = .{ .backing = testing.allocator };
    const gpa = counting.allocator();

    const buf = try gpa.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 1), counting.calls);
    gpa.free(buf);
    try testing.expectEqual(@as(usize, 2), counting.calls);

    const dup = try gpa.dupe(u8, "hello");
    try testing.expectEqual(@as(usize, 3), counting.calls);
    gpa.free(dup);
    try testing.expectEqual(@as(usize, 4), counting.calls);
}

test "CountingAllocator: counts resize and remap, reset clears" {
    var counting: CountingAllocator = .{ .backing = testing.allocator };
    const gpa = counting.allocator();

    // Resize in place; the caller re-slices on success.
    var buf = try gpa.alloc(u32, 4);
    if (gpa.resize(buf, 8)) buf = buf.ptr[0..8];
    gpa.free(buf);

    // Remap on a fresh allocation (remap after resize is not allowed).
    const buf2 = try gpa.alloc(u32, 4);
    const remapped = gpa.remap(buf2, 16) orelse buf2;
    gpa.free(remapped);

    try testing.expect(counting.calls >= 5);

    counting.reset();
    try testing.expectEqual(@as(usize, 0), counting.calls);
}
