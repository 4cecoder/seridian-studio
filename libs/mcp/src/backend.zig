// Translated to Zig from soundcraft/crates/automation/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The `Backend` interface: something that answers control-protocol methods (`engine.execute`,
//! `session.inspect`, `ui.*`). Written as a vtable so that `mcp` does not import `session`: the
//! session or the app wires a concrete backend in. The Rust `Headless` backend (an in-process
//! engine) is not translated here; it belongs to the session wiring. `Remote` (remote.zig) is the
//! client for a running app.
//!
//! Ownership: the `ok` value and the `err` text of a `Result` are allocated in the arena the caller
//! passes to `call`, so they stay valid as long as that arena does. This replaces the Rust `String`
//! and `Value` return types, which were owned by the callee.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// The outcome of one control call.
pub const Result = union(enum) {
    ok: std.json.Value,
    err: []const u8,
};

/// A control-protocol backend, as a pointer plus a vtable of its three methods.
pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        call: *const fn (ptr: *anyopaque, arena: Allocator, method: []const u8, params: std.json.Value) Result,
        hasUi: *const fn (ptr: *anyopaque) bool,
        describe: *const fn (ptr: *anyopaque, arena: Allocator) Allocator.Error![]const u8,
    };

    /// Answers `method` with `params`. Control thread only: a backend may allocate and do I/O.
    pub fn call(self: Backend, arena: Allocator, method: []const u8, params: std.json.Value) Result {
        return self.vtable.call(self.ptr, arena, method, params);
    }

    /// True when a UI is attached (screenshots, clicks).
    pub fn hasUi(self: Backend) bool {
        return self.vtable.hasUi(self.ptr);
    }

    /// A short human-readable description of the backend.
    pub fn describe(self: Backend, arena: Allocator) Allocator.Error![]const u8 {
        return self.vtable.describe(self.ptr, arena);
    }

    /// Wraps a pointer to any type `T` that has the methods
    /// `call(*T, Allocator, []const u8, std.json.Value) Result`, `hasUi(*T) bool` and
    /// `describe(*T, Allocator) Allocator.Error![]const u8`. `T` must outlive the returned value.
    pub fn from(pointer: anytype) Backend {
        const T = @typeInfo(@TypeOf(pointer)).pointer.child;
        const Gen = struct {
            const table: VTable = .{ .call = callFn, .hasUi = hasUiFn, .describe = describeFn };

            fn callFn(ptr: *anyopaque, arena: Allocator, method: []const u8, params: std.json.Value) Result {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.call(arena, method, params);
            }
            fn hasUiFn(ptr: *anyopaque) bool {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.hasUi();
            }
            fn describeFn(ptr: *anyopaque, arena: Allocator) Allocator.Error![]const u8 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.describe(arena);
            }
        };
        return .{ .ptr = pointer, .vtable = &Gen.table };
    }
};

/// A test backend: answers every method with its own name, refuses `ui.*` as the headless
/// backend does, and counts calls.
const Mock = struct {
    calls: usize = 0,

    pub fn call(self: *Mock, arena: Allocator, method: []const u8, params: std.json.Value) Result {
        _ = params;
        self.calls += 1;
        if (std.mem.startsWith(u8, method, "ui.")) {
            const text = std.fmt.allocPrint(arena, "`{s}` needs the desktop app", .{method}) catch return .{ .err = "out of memory" };
            return .{ .err = text };
        }
        return .{ .ok = .{ .string = method } };
    }

    pub fn hasUi(self: *Mock) bool {
        _ = self;
        return false;
    }

    pub fn describe(self: *Mock, arena: Allocator) Allocator.Error![]const u8 {
        _ = self;
        return std.fmt.allocPrint(arena, "mock backend", .{});
    }
};

test "Backend.from dispatches call, hasUi and describe through the vtable" {
    var mock = Mock{};
    const backend: Backend = .from(&mock);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const params: std.json.Value = .null;

    switch (backend.call(arena, "session.inspect", params)) {
        .ok => |v| try testing.expectEqualStrings("session.inspect", v.string),
        .err => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), mock.calls);
    try testing.expect(!backend.hasUi());
    try testing.expectEqualStrings("mock backend", try backend.describe(arena));
}

test "a ui method is refused by a backend without a UI" {
    var mock = Mock{};
    const backend: Backend = .from(&mock);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (backend.call(arena, "ui.click", .null)) {
        .err => |text| try testing.expectEqualStrings("`ui.click` needs the desktop app", text),
        .ok => return error.TestUnexpectedResult,
    }
}

test "headless_executes_and_inspects" {
    // Ported with the Headless backend in the session wiring: it wraps an in-process engine, which
    // this library cannot import (layering). The behaviour it checks is covered by the mock above.
    return error.SkipZigTest;
}
