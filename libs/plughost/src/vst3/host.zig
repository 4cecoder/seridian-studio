// Translated to Zig from soundcraft/crates/vst3-host/src/ffi/host.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Host-side VST3 COM objects: `IHostApplication` + `IComponentHandler` + `IComponentHandler2`
//! (`HostContext`), `IPlugFrame` (`HostPlugFrame`), and the `IMessage` / `IAttributeList` pair
//! the host hands to plugins through `IHostApplication::createInstance`.
//!
//! COM pattern (replaces the `vst3` crate's `Class` / `ComWrapper`): every interface a class
//! implements is an embedded `extern struct { vtbl: *const Vtbl }` field of a heap object. A
//! COM pointer is the address of that field. The vtable thunks recover the object with
//! `@fieldParentPtr`, `queryInterface` hands out the pointer of the matching field, and one
//! atomic `RefCount` per object frees it (through its allocator) on the last `release`.
//!
//! Threading: the plugin may call `beginEdit` / `performEdit` / `endEdit` / `restartComponent`
//! from any thread (editor UI thread, a worker, even the audio thread). Those four methods only
//! touch lock-free state (atomics and a bounded, preallocated edit table); they never allocate,
//! lock or log. `IMessage` / `IAttributeList` allocate and take a tiny spin lock: plugins use
//! them from control threads only (never from `process`).

const std = @import("std");
const abi = @import("abi.zig");

const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

// ---- reference counting ----------------------------------------------------------------------

/// Atomic COM reference count. A new object starts with one reference, owned by its creator.
pub const RefCount = struct {
    n: Atomic(u32) = .init(1),

    pub fn add(self: *RefCount) u32 {
        return self.n.fetchAdd(1, .monotonic) + 1;
    }

    /// Returns the new count; the caller frees the object when it is zero.
    pub fn sub(self: *RefCount) u32 {
        const prev = self.n.fetchSub(1, .release);
        if (prev == 1) {
            _ = self.n.load(.acquire);
        }
        return prev - 1;
    }
};

/// Builds the `FUnknown` vtable for class `T`, whose COM interface lives in field `field` (the
/// one whose pointer is passed in). `T` provides:
/// * `refs: RefCount`
/// * `fn queryImpl(self: *T, id: *const abi.TUID) ?*anyopaque` : the interface pointer for `id`
///   (including `FUnknown`'s own IID), or null
/// * `fn destroy(self: *T) void` : frees the object (called on the last release)
pub fn Unknown(comptime T: type, comptime field: []const u8) type {
    return struct {
        fn self_(this: *abi.FUnknown) *T {
            const f: *@FieldType(T, field) = @ptrCast(@alignCast(this));
            return @fieldParentPtr(field, f);
        }
        fn queryInterface(this: *abi.FUnknown, id: *const abi.TUID, obj: *?*anyopaque) callconv(.c) abi.tresult {
            const s = self_(this);
            if (s.queryImpl(id)) |p| {
                _ = s.refs.add();
                obj.* = p;
                return abi.kResultOk;
            }
            obj.* = null;
            return abi.kNoInterface;
        }
        fn addRef(this: *abi.FUnknown) callconv(.c) u32 {
            return self_(this).refs.add();
        }
        fn release(this: *abi.FUnknown) callconv(.c) u32 {
            const s = self_(this);
            const left = s.refs.sub();
            if (left == 0) s.destroy();
            return left;
        }
        pub const vtbl: abi.FUnknown.Vtbl = .{ .queryInterface = queryInterface, .addRef = addRef, .release = release };
    };
}

/// `FUnknown` vtable for objects whose lifetime is owned by a container (pool entries): the
/// reference count is a constant and nothing is ever freed through COM.
pub const StaticUnknown = struct {
    fn queryInterface(this: *abi.FUnknown, id: *const abi.TUID, obj: *?*anyopaque) callconv(.c) abi.tresult {
        if (std.mem.eql(u8, id, &abi.FUnknown.iid)) {
            obj.* = this;
            return abi.kResultOk;
        }
        obj.* = null;
        return abi.kNoInterface;
    }
    fn addRef(_: *abi.FUnknown) callconv(.c) u32 {
        return 2;
    }
    fn release(_: *abi.FUnknown) callconv(.c) u32 {
        return 1;
    }
    pub const vtbl: abi.FUnknown.Vtbl = .{ .queryInterface = queryInterface, .addRef = addRef, .release = release };
};

/// A tiny test-and-set lock for control-thread-only COM objects (never contended in practice;
/// needs no `Io`, which a COM callback does not have). Never use it on the audio thread.
const SpinLock = struct {
    locked: Atomic(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

fn iidIs(id: *const abi.TUID, comptime T: type) bool {
    return std.mem.eql(u8, id, &T.iid);
}

// ---- interfaces missing from abi.zig ---------------------------------------------------------

/// `Steinberg::Vst::IComponentHandler2`.
pub const IComponentHandler2 = extern struct {
    vtbl: *const Vtbl,

    pub const iid = abi.uid(0xF040B4B3, 0xA36045EC, 0xABCDC045, 0xB4D5A2CC);

    pub const Vtbl = extern struct {
        unknown: abi.FUnknown.Vtbl,
        setDirty: *const fn (this: *IComponentHandler2, state: abi.TBool) callconv(.c) abi.tresult,
        requestOpenEditor: *const fn (this: *IComponentHandler2, name: ?[*:0]const u8) callconv(.c) abi.tresult,
        startGroupEdit: *const fn (this: *IComponentHandler2) callconv(.c) abi.tresult,
        finishGroupEdit: *const fn (this: *IComponentHandler2) callconv(.c) abi.tresult,
    };
};

/// `Steinberg::Vst::IAttributeList`.
pub const IAttributeList = extern struct {
    vtbl: *const Vtbl,

    pub const iid = abi.uid(0x1E5F0AEB, 0xCC7F4533, 0xA2544011, 0x38AD5EE4);
    pub const AttrID = ?[*:0]const u8;

    pub const Vtbl = extern struct {
        unknown: abi.FUnknown.Vtbl,
        setInt: *const fn (this: *IAttributeList, id: AttrID, value: i64) callconv(.c) abi.tresult,
        getInt: *const fn (this: *IAttributeList, id: AttrID, value: ?*i64) callconv(.c) abi.tresult,
        setFloat: *const fn (this: *IAttributeList, id: AttrID, value: f64) callconv(.c) abi.tresult,
        getFloat: *const fn (this: *IAttributeList, id: AttrID, value: ?*f64) callconv(.c) abi.tresult,
        setString: *const fn (this: *IAttributeList, id: AttrID, string: ?[*:0]const abi.TChar) callconv(.c) abi.tresult,
        getString: *const fn (this: *IAttributeList, id: AttrID, string: ?[*]abi.TChar, size_in_bytes: u32) callconv(.c) abi.tresult,
        setBinary: *const fn (this: *IAttributeList, id: AttrID, data: ?*const anyopaque, size_in_bytes: u32) callconv(.c) abi.tresult,
        getBinary: *const fn (this: *IAttributeList, id: AttrID, data: ?*?*const anyopaque, size_in_bytes: ?*u32) callconv(.c) abi.tresult,
    };
};

/// `Steinberg::Vst::IMessage` (the full vtable; `abi.IMessage` keeps it opaque).
pub const IMessage = extern struct {
    vtbl: *const Vtbl,

    pub const iid = abi.uid(0x936F033B, 0xC6C047DB, 0xBB0882F8, 0x13C1E613);

    pub const Vtbl = extern struct {
        unknown: abi.FUnknown.Vtbl,
        getMessageID: *const fn (this: *IMessage) callconv(.c) ?[*:0]const u8,
        setMessageID: *const fn (this: *IMessage, id: ?[*:0]const u8) callconv(.c) void,
        getAttributes: *const fn (this: *IMessage) callconv(.c) ?*IAttributeList,
    };
};

// ---- HostContext -----------------------------------------------------------------------------

/// One queued editor edit: a normalized value for a parameter.
pub const Edit = struct { id: abi.ParamID, value: f64 };

/// "No pending value" marker in an edit slot: an all-ones NaN, never a clamped finite value.
const NO_VALUE: u64 = std.math.maxInt(u64);

const slot_empty: u8 = 0;
const slot_claiming: u8 = 1;
const slot_ready: u8 = 2;
const slot_dead: u8 = 3;

/// Lock-free table of the latest `performEdit` value per parameter id, bounded by
/// `abi.EDIT_CAP` distinct ids. Any thread may `record`; one thread `take`s. A slot binds to an
/// id for the life of the table; its value is swapped out by `take`, so no edit is lost to a
/// race (an update lands either before the take, or stays for the next one).
pub const EditTable = struct {
    state: [abi.EDIT_CAP]Atomic(u8) = @splat(.init(slot_empty)),
    ids: [abi.EDIT_CAP]Atomic(u32) = @splat(.init(0)),
    values: [abi.EDIT_CAP]Atomic(u64) = @splat(.init(NO_VALUE)),
    /// Edits for a new id that found no free slot.
    dropped: Atomic(u32) = .init(0),

    /// Any thread, wait-free apart from bounded scans.
    pub fn record(self: *EditTable, id: u32, value: f64) void {
        const bits: u64 = @bitCast(value);
        var i: usize = 0;
        while (i < abi.EDIT_CAP) : (i += 1) {
            const st = self.state[i].load(.acquire);
            if (st == slot_ready and self.ids[i].load(.monotonic) == id) {
                self.values[i].store(bits, .release);
                return;
            }
            if (st == slot_empty) {
                if (self.state[i].cmpxchgStrong(slot_empty, slot_claiming, .acquire, .monotonic) != null) {
                    // Lost the race for this slot: look at it again.
                    continue;
                }
                self.ids[i].store(id, .monotonic);
                self.state[i].store(slot_ready, .release);
                // A concurrent writer of the same new id may have bound a lower slot first;
                // then this one is abandoned and the value goes to the lowest.
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    if (self.state[j].load(.acquire) == slot_ready and self.ids[j].load(.monotonic) == id) {
                        self.state[i].store(slot_dead, .release);
                        self.values[j].store(bits, .release);
                        return;
                    }
                }
                self.values[i].store(bits, .release);
                return;
            }
        }
        _ = self.dropped.fetchAdd(1, .monotonic);
    }

    /// Consumer thread: moves the pending edits into `out` (slot order, which is first-use
    /// order) and returns how many were written. Edits beyond `out.len` stay queued.
    pub fn take(self: *EditTable, out: []Edit) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < abi.EDIT_CAP and n < out.len) : (i += 1) {
            if (self.state[i].load(.acquire) != slot_ready) continue;
            const v = self.values[i].swap(NO_VALUE, .acquire);
            if (v == NO_VALUE) continue;
            out[n] = .{ .id = self.ids[i].load(.monotonic), .value = @bitCast(v) };
            n += 1;
        }
        return n;
    }
};

/// The host context handed to `initialize` (`IHostApplication`) and to the controller
/// (`IComponentHandler` / `IComponentHandler2`): parameter edits made in the plugin's editor are
/// stored for the UI, which writes them into the session, from where they reach the processor.
pub const HostContext = struct {
    app: abi.IHostApplication,
    handler: abi.IComponentHandler,
    handler2: IComponentHandler2,
    refs: RefCount = .{},
    gpa: Allocator,
    latency_changed: Atomic(bool) = .init(false),
    restart_requested: Atomic(bool) = .init(false),
    /// Set by `IComponentHandler2::setDirty(true)`; cleared by the consumer.
    dirty: Atomic(bool) = .init(false),
    /// `performEdit` values (normalized), bounded by `abi.EDIT_CAP` ids.
    edits: EditTable = .{},

    const AppU = Unknown(HostContext, "app");
    const HandlerU = Unknown(HostContext, "handler");
    const Handler2U = Unknown(HostContext, "handler2");

    /// Control thread. The result has one reference, owned by the caller (`release` it).
    pub fn create(gpa: Allocator) Allocator.Error!*HostContext {
        const self = try gpa.create(HostContext);
        self.* = .{ .app = .{ .vtbl = &app_vtbl }, .handler = .{ .vtbl = &handler_vtbl }, .handler2 = .{ .vtbl = &handler2_vtbl }, .gpa = gpa };
        return self;
    }

    /// Drops the creator's reference. Plugins hold their own.
    pub fn release(self: *HostContext) void {
        _ = AppU.vtbl.release(@ptrCast(&self.app));
    }

    pub fn hostApplication(self: *HostContext) *abi.IHostApplication {
        return &self.app;
    }
    pub fn componentHandler(self: *HostContext) *abi.IComponentHandler {
        return &self.handler;
    }

    /// Takes the queued editor edits into `out`; returns how many. No allocation.
    pub fn takeEdits(self: *HostContext, out: []Edit) usize {
        return self.edits.take(out);
    }

    pub fn queryImpl(self: *HostContext, id: *const abi.TUID) ?*anyopaque {
        if (iidIs(id, abi.FUnknown) or iidIs(id, abi.IHostApplication)) return &self.app;
        if (iidIs(id, abi.IComponentHandler)) return &self.handler;
        if (iidIs(id, IComponentHandler2)) return &self.handler2;
        return null;
    }

    pub fn destroy(self: *HostContext) void {
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    // IHostApplication

    fn appSelf(this: *abi.IHostApplication) *HostContext {
        return @fieldParentPtr("app", this);
    }

    fn getName(_: *abi.IHostApplication, name: *abi.String128) callconv(.c) abi.tresult {
        abi.writeC16("Seridian Studio", name);
        return abi.kResultOk;
    }

    /// Creates the objects plugins may ask the host for: `IMessage` (what a controller and its
    /// processor send each other through `IConnectionPoint::notify`) and `IAttributeList`.
    /// Plugins that talk between their halves this way fail without them. Control thread.
    fn createInstance(this: *abi.IHostApplication, cid: *const abi.TUID, id: *const abi.TUID, obj: *?*anyopaque) callconv(.c) abi.tresult {
        obj.* = null;
        const gpa = appSelf(this).gpa;
        const wants_msg = std.mem.eql(u8, cid, &IMessage.iid) and (std.mem.eql(u8, id, &IMessage.iid) or iidIs(id, abi.FUnknown));
        const wants_attr = std.mem.eql(u8, cid, &IAttributeList.iid) and (std.mem.eql(u8, id, &IAttributeList.iid) or iidIs(id, abi.FUnknown));
        if (wants_msg) {
            const m = HostMessage.create(gpa) catch return abi.kOutOfMemory;
            obj.* = &m.iface;
            return abi.kResultOk;
        }
        if (wants_attr) {
            const a = HostAttributes.create(gpa) catch return abi.kOutOfMemory;
            obj.* = &a.iface;
            return abi.kResultOk;
        }
        return abi.kResultFalse;
    }

    // IComponentHandler

    fn handlerSelf(this: *abi.IComponentHandler) *HostContext {
        return @fieldParentPtr("handler", this);
    }

    fn beginEdit(_: *abi.IComponentHandler, _: abi.ParamID) callconv(.c) abi.tresult {
        return abi.kResultOk;
    }
    /// Any thread, lock-free, no allocation. Non-finite values are ignored, others clamped
    /// to 0..1.
    fn performEdit(this: *abi.IComponentHandler, id: abi.ParamID, value: f64) callconv(.c) abi.tresult {
        if (std.math.isFinite(value)) handlerSelf(this).edits.record(id, std.math.clamp(value, 0.0, 1.0));
        return abi.kResultOk;
    }
    fn endEdit(_: *abi.IComponentHandler, _: abi.ParamID) callconv(.c) abi.tresult {
        return abi.kResultOk;
    }
    fn restartComponent(this: *abi.IComponentHandler, flags: i32) callconv(.c) abi.tresult {
        const s = handlerSelf(this);
        if (@as(u32, @bitCast(flags)) & @as(u32, @bitCast(abi.kLatencyChanged)) != 0) s.latency_changed.store(true, .monotonic);
        s.restart_requested.store(true, .monotonic);
        return abi.kResultOk;
    }

    // IComponentHandler2

    fn handler2Self(this: *IComponentHandler2) *HostContext {
        return @fieldParentPtr("handler2", this);
    }
    fn setDirty(this: *IComponentHandler2, state: abi.TBool) callconv(.c) abi.tresult {
        if (state != 0) handler2Self(this).dirty.store(true, .monotonic);
        return abi.kResultOk;
    }
    fn requestOpenEditor(_: *IComponentHandler2, _: ?[*:0]const u8) callconv(.c) abi.tresult {
        return abi.kNotImplemented;
    }
    fn startGroupEdit(_: *IComponentHandler2) callconv(.c) abi.tresult {
        return abi.kResultOk;
    }
    fn finishGroupEdit(_: *IComponentHandler2) callconv(.c) abi.tresult {
        return abi.kResultOk;
    }

    const app_vtbl: abi.IHostApplication.Vtbl = .{ .unknown = AppU.vtbl, .getName = getName, .createInstance = createInstance };
    const handler_vtbl: abi.IComponentHandler.Vtbl = .{
        .unknown = HandlerU.vtbl,
        .beginEdit = beginEdit,
        .performEdit = performEdit,
        .endEdit = endEdit,
        .restartComponent = restartComponent,
    };
    const handler2_vtbl: IComponentHandler2.Vtbl = .{
        .unknown = Handler2U.vtbl,
        .setDirty = setDirty,
        .requestOpenEditor = requestOpenEditor,
        .startGroupEdit = startGroupEdit,
        .finishGroupEdit = finishGroupEdit,
    };
};

// ---- IPlugFrame ------------------------------------------------------------------------------

/// The host's `IPlugFrame`: records the size a plugin view asks for (`resizeView`) so the
/// window code can apply it on the UI thread.
pub const HostPlugFrame = struct {
    iface: abi.IPlugFrame,
    refs: RefCount = .{},
    gpa: Allocator,
    /// Requested size, valid once `resize_pending` is set.
    width: Atomic(i32) = .init(0),
    height: Atomic(i32) = .init(0),
    resize_pending: Atomic(bool) = .init(false),

    const U = Unknown(HostPlugFrame, "iface");

    pub fn create(gpa: Allocator) Allocator.Error!*HostPlugFrame {
        const self = try gpa.create(HostPlugFrame);
        self.* = .{ .iface = .{ .vtbl = &vtbl }, .gpa = gpa };
        return self;
    }

    pub fn release(self: *HostPlugFrame) void {
        _ = U.vtbl.release(@ptrCast(&self.iface));
    }

    /// Takes a pending resize request (UI thread).
    pub fn takeResize(self: *HostPlugFrame) ?struct { width: i32, height: i32 } {
        if (!self.resize_pending.swap(false, .acquire)) return null;
        return .{ .width = self.width.load(.monotonic), .height = self.height.load(.monotonic) };
    }

    pub fn queryImpl(self: *HostPlugFrame, id: *const abi.TUID) ?*anyopaque {
        if (iidIs(id, abi.FUnknown) or iidIs(id, abi.IPlugFrame)) return &self.iface;
        return null;
    }
    pub fn destroy(self: *HostPlugFrame) void {
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn resizeView(this: *abi.IPlugFrame, _: *abi.IPlugView, new_size: *abi.ViewRect) callconv(.c) abi.tresult {
        const self: *HostPlugFrame = @fieldParentPtr("iface", this);
        self.width.store(new_size.right - new_size.left, .monotonic);
        self.height.store(new_size.bottom - new_size.top, .monotonic);
        self.resize_pending.store(true, .release);
        return abi.kResultOk;
    }

    const vtbl: abi.IPlugFrame.Vtbl = .{ .unknown = U.vtbl, .resizeView = resizeView };
};

// ---- IAttributeList / IMessage ---------------------------------------------------------------

/// Longest string attribute kept, in UTF-16 units (longer ones are cut).
const ATTR_STRING_MAX: usize = 1 << 20;

/// Largest binary attribute kept.
const ATTR_BINARY_MAX: usize = 256 << 20;

/// One `IAttributeList` value. Strings and blobs live in their own allocation, so a pointer
/// handed out by `getBinary` stays valid while the list holds the value.
const Attr = union(enum) {
    int: i64,
    float: f64,
    str: []u16,
    bin: []u8,
};

/// The host's `IAttributeList`: what a plugin puts in an `IMessage`. Control-thread object.
pub const HostAttributes = struct {
    iface: IAttributeList,
    refs: RefCount = .{},
    gpa: Allocator,
    lock: SpinLock = .{},
    values: std.StringHashMapUnmanaged(Attr) = .empty,

    const U = Unknown(HostAttributes, "iface");

    pub fn create(gpa: Allocator) Allocator.Error!*HostAttributes {
        const self = try gpa.create(HostAttributes);
        self.* = .{ .iface = .{ .vtbl = &vtbl }, .gpa = gpa };
        return self;
    }

    pub fn release(self: *HostAttributes) void {
        _ = U.vtbl.release(@ptrCast(&self.iface));
    }

    pub fn queryImpl(self: *HostAttributes, id: *const abi.TUID) ?*anyopaque {
        if (iidIs(id, abi.FUnknown) or iidIs(id, IAttributeList)) return &self.iface;
        return null;
    }

    fn freeAttr(self: *HostAttributes, a: Attr) void {
        switch (a) {
            .str => |s| self.gpa.free(s),
            .bin => |b| self.gpa.free(b),
            else => {},
        }
    }

    pub fn destroy(self: *HostAttributes) void {
        const gpa = self.gpa;
        var it = self.values.iterator();
        while (it.next()) |e| {
            self.freeAttr(e.value_ptr.*);
            gpa.free(e.key_ptr.*);
        }
        self.values.deinit(gpa);
        gpa.destroy(self);
    }

    fn self_(this: *IAttributeList) *HostAttributes {
        return @fieldParentPtr("iface", this);
    }

    fn key(id: IAttributeList.AttrID) ?[]const u8 {
        const p = id orelse return null;
        return std.mem.span(p);
    }

    /// Stores `v` under `id`, taking ownership of its allocation (freed on failure).
    fn set(self: *HostAttributes, id: IAttributeList.AttrID, v: Attr) abi.tresult {
        const k = key(id) orelse {
            self.freeAttr(v);
            return abi.kInvalidArgument;
        };
        self.lock.lock();
        defer self.lock.unlock();
        const gop = self.values.getOrPut(self.gpa, k) catch {
            self.freeAttr(v);
            return abi.kOutOfMemory;
        };
        if (gop.found_existing) {
            self.freeAttr(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, k) catch {
                // Roll the half-made entry back (its key points at the caller's string).
                _ = self.values.remove(k);
                self.freeAttr(v);
                return abi.kOutOfMemory;
            };
        }
        gop.value_ptr.* = v;
        return abi.kResultOk;
    }

    fn setInt(this: *IAttributeList, id: IAttributeList.AttrID, value: i64) callconv(.c) abi.tresult {
        return self_(this).set(id, .{ .int = value });
    }

    fn getInt(this: *IAttributeList, id: IAttributeList.AttrID, value: ?*i64) callconv(.c) abi.tresult {
        const self = self_(this);
        const k = key(id) orelse return abi.kResultFalse;
        const out = value orelse return abi.kResultFalse;
        self.lock.lock();
        defer self.lock.unlock();
        const a = self.values.get(k) orelse return abi.kResultFalse;
        if (a != .int) return abi.kResultFalse;
        out.* = a.int;
        return abi.kResultOk;
    }

    fn setFloat(this: *IAttributeList, id: IAttributeList.AttrID, value: f64) callconv(.c) abi.tresult {
        return self_(this).set(id, .{ .float = value });
    }

    fn getFloat(this: *IAttributeList, id: IAttributeList.AttrID, value: ?*f64) callconv(.c) abi.tresult {
        const self = self_(this);
        const k = key(id) orelse return abi.kResultFalse;
        const out = value orelse return abi.kResultFalse;
        self.lock.lock();
        defer self.lock.unlock();
        const a = self.values.get(k) orelse return abi.kResultFalse;
        if (a != .float) return abi.kResultFalse;
        out.* = a.float;
        return abi.kResultOk;
    }

    fn setString(this: *IAttributeList, id: IAttributeList.AttrID, string: ?[*:0]const abi.TChar) callconv(.c) abi.tresult {
        const self = self_(this);
        const s = string orelse return abi.kInvalidArgument;
        // A non-null string is NUL-terminated UTF-16 owned by the caller; reading stops at the
        // NUL or at ATTR_STRING_MAX units.
        var n: usize = 0;
        while (n < ATTR_STRING_MAX and s[n] != 0) n += 1;
        const copy = self.gpa.dupe(u16, s[0..n]) catch return abi.kOutOfMemory;
        return self.set(id, .{ .str = copy });
    }

    fn getString(this: *IAttributeList, id: IAttributeList.AttrID, string: ?[*]abi.TChar, size_in_bytes: u32) callconv(.c) abi.tresult {
        const self = self_(this);
        const units: usize = size_in_bytes / 2;
        const dst = string orelse return abi.kInvalidArgument;
        if (units == 0) return abi.kInvalidArgument;
        const k = key(id) orelse return abi.kInvalidArgument;
        self.lock.lock();
        defer self.lock.unlock();
        const a = self.values.get(k) orelse return abi.kResultFalse;
        if (a != .str) return abi.kResultFalse;
        const n = @min(a.str.len, units - 1);
        @memcpy(dst[0..n], a.str[0..n]);
        dst[n] = 0;
        return abi.kResultOk;
    }

    fn setBinary(this: *IAttributeList, id: IAttributeList.AttrID, data: ?*const anyopaque, size_in_bytes: u32) callconv(.c) abi.tresult {
        const self = self_(this);
        const n: usize = size_in_bytes;
        if (n > ATTR_BINARY_MAX) return abi.kOutOfMemory;
        const copy = self.gpa.alloc(u8, if (data == null) 0 else n) catch return abi.kOutOfMemory;
        if (data) |d| {
            const src: [*]const u8 = @ptrCast(d);
            @memcpy(copy, src[0..copy.len]);
        }
        return self.set(id, .{ .bin = copy });
    }

    fn getBinary(this: *IAttributeList, id: IAttributeList.AttrID, data: ?*?*const anyopaque, size_in_bytes: ?*u32) callconv(.c) abi.tresult {
        const self = self_(this);
        const k = key(id) orelse return abi.kInvalidArgument;
        self.lock.lock();
        defer self.lock.unlock();
        const a = self.values.get(k) orelse return abi.kResultFalse;
        if (a != .bin) return abi.kResultFalse;
        const d = data orelse return abi.kInvalidArgument;
        const sz = size_in_bytes orelse return abi.kInvalidArgument;
        // The pointer handed out stays valid until this attribute is replaced or the list is
        // released (VST3 contract).
        d.* = a.bin.ptr;
        sz.* = std.math.cast(u32, a.bin.len) orelse std.math.maxInt(u32);
        return abi.kResultOk;
    }

    const vtbl: IAttributeList.Vtbl = .{
        .unknown = U.vtbl,
        .setInt = setInt,
        .getInt = getInt,
        .setFloat = setFloat,
        .getFloat = getFloat,
        .setString = setString,
        .getString = getString,
        .setBinary = setBinary,
        .getBinary = getBinary,
    };
};

/// The host's `IMessage`: an id and an attribute list, created for a plugin through
/// `IHostApplication::createInstance`.
pub const HostMessage = struct {
    iface: IMessage,
    refs: RefCount = .{},
    gpa: Allocator,
    lock: SpinLock = .{},
    /// NUL-terminated; its buffer lives until the next `setMessageID`, as the interface expects.
    id: [:0]u8,
    attributes: *HostAttributes,

    const U = Unknown(HostMessage, "iface");

    pub fn create(gpa: Allocator) Allocator.Error!*HostMessage {
        const attrs = try HostAttributes.create(gpa);
        errdefer attrs.release();
        const id = try gpa.allocSentinel(u8, 0, 0);
        errdefer gpa.free(id);
        const self = try gpa.create(HostMessage);
        self.* = .{ .iface = .{ .vtbl = &vtbl }, .gpa = gpa, .id = id, .attributes = attrs };
        return self;
    }

    pub fn release(self: *HostMessage) void {
        _ = U.vtbl.release(@ptrCast(&self.iface));
    }

    pub fn queryImpl(self: *HostMessage, id: *const abi.TUID) ?*anyopaque {
        if (iidIs(id, abi.FUnknown) or iidIs(id, IMessage)) return &self.iface;
        return null;
    }

    pub fn destroy(self: *HostMessage) void {
        const gpa = self.gpa;
        self.attributes.release();
        gpa.free(self.id);
        gpa.destroy(self);
    }

    fn self_(this: *IMessage) *HostMessage {
        return @fieldParentPtr("iface", this);
    }

    fn getMessageID(this: *IMessage) callconv(.c) ?[*:0]const u8 {
        const self = self_(this);
        self.lock.lock();
        defer self.lock.unlock();
        return self.id.ptr;
    }

    fn setMessageID(this: *IMessage, id: ?[*:0]const u8) callconv(.c) void {
        const self = self_(this);
        const src: []const u8 = if (id) |p| std.mem.span(p) else "";
        const copy = self.gpa.allocSentinel(u8, src.len, 0) catch return;
        @memcpy(copy, src);
        self.lock.lock();
        defer self.lock.unlock();
        self.gpa.free(self.id);
        self.id = copy;
    }

    /// Not add-ref'ed: the list belongs to the message (VST3 contract).
    fn getAttributes(this: *IMessage) callconv(.c) ?*IAttributeList {
        return &self_(this).attributes.iface;
    }

    const vtbl: IMessage.Vtbl = .{
        .unknown = U.vtbl,
        .getMessageID = getMessageID,
        .setMessageID = setMessageID,
        .getAttributes = getAttributes,
    };
};

// ---- tests -----------------------------------------------------------------------------------
// The Rust file has no #[cfg(test)] module; these cover the translated behaviour.

const testing = std.testing;

fn unknownOf(p: anytype) *abi.FUnknown {
    return abi.asUnknown(p);
}

test "HostContext getName reports the host" {
    const ctx = try HostContext.create(testing.allocator);
    defer ctx.release();
    var name: abi.String128 = undefined;
    const app = ctx.hostApplication();
    try testing.expectEqual(abi.kResultOk, app.vtbl.getName(app, &name));
    const text = try abi.readC16(testing.allocator, &name);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("Seridian Studio", text);
}

test "performEdit coalesces per id, clamps, ignores non-finite" {
    const ctx = try HostContext.create(testing.allocator);
    defer ctx.release();
    const h = ctx.componentHandler();
    _ = h.vtbl.performEdit(h, 7, 0.25);
    _ = h.vtbl.performEdit(h, 9, 2.0);
    _ = h.vtbl.performEdit(h, 7, 0.5);
    _ = h.vtbl.performEdit(h, 11, std.math.nan(f64));
    _ = h.vtbl.performEdit(h, 12, std.math.inf(f64));
    var out: [8]Edit = undefined;
    const n = ctx.takeEdits(&out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u32, 7), out[0].id);
    try testing.expectEqual(@as(f64, 0.5), out[0].value);
    try testing.expectEqual(@as(u32, 9), out[1].id);
    try testing.expectEqual(@as(f64, 1.0), out[1].value);
    // Taken edits are gone.
    try testing.expectEqual(@as(usize, 0), ctx.takeEdits(&out));
    // The id stays bound: a later edit is delivered again.
    _ = h.vtbl.performEdit(h, 7, 0.75);
    try testing.expectEqual(@as(usize, 1), ctx.takeEdits(&out));
    try testing.expectEqual(@as(f64, 0.75), out[0].value);
}

test "edit table is bounded by EDIT_CAP ids and counts drops" {
    const ctx = try HostContext.create(testing.allocator);
    defer ctx.release();
    const h = ctx.componentHandler();
    var id: u32 = 0;
    while (id < abi.EDIT_CAP + 10) : (id += 1) _ = h.vtbl.performEdit(h, id, 0.5);
    var out: [abi.EDIT_CAP + 10]Edit = undefined;
    try testing.expectEqual(@as(usize, abi.EDIT_CAP), ctx.takeEdits(&out));
    try testing.expectEqual(@as(u32, 10), ctx.edits.dropped.load(.monotonic));
    // Already-bound ids still update when the table is full.
    _ = h.vtbl.performEdit(h, 3, 0.125);
    try testing.expectEqual(@as(usize, 1), ctx.takeEdits(&out));
    try testing.expectEqual(@as(u32, 3), out[0].id);
}

test "takeEdits with a small buffer leaves the rest queued" {
    const ctx = try HostContext.create(testing.allocator);
    defer ctx.release();
    const h = ctx.componentHandler();
    _ = h.vtbl.performEdit(h, 1, 0.1);
    _ = h.vtbl.performEdit(h, 2, 0.2);
    _ = h.vtbl.performEdit(h, 3, 0.3);
    var out: [2]Edit = undefined;
    try testing.expectEqual(@as(usize, 2), ctx.takeEdits(&out));
    try testing.expectEqual(@as(usize, 1), ctx.takeEdits(&out));
    try testing.expectEqual(@as(u32, 3), out[0].id);
}

test "performEdit from several threads loses nothing" {
    const ctx = try HostContext.create(testing.allocator);
    defer ctx.release();
    const Worker = struct {
        fn run(c: *HostContext) void {
            const h = c.componentHandler();
            var k: u32 = 0;
            while (k < 2000) : (k += 1) _ = h.vtbl.performEdit(h, k % 16, 0.5);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ctx});
    for (threads) |t| t.join();
    var out: [32]Edit = undefined;
    const n = ctx.takeEdits(&out);
    try testing.expectEqual(@as(usize, 16), n);
    var seen: u32 = 0;
    for (out[0..n]) |e| {
        try testing.expectEqual(@as(f64, 0.5), e.value);
        seen |= @as(u32, 1) << @intCast(e.id);
    }
    try testing.expectEqual(@as(u32, 0xFFFF), seen);
}

test "restartComponent sets the flags" {
    const ctx = try HostContext.create(testing.allocator);
    defer ctx.release();
    const h = ctx.componentHandler();
    _ = h.vtbl.restartComponent(h, abi.kParamValuesChanged);
    try testing.expect(!ctx.latency_changed.load(.monotonic));
    try testing.expect(ctx.restart_requested.load(.monotonic));
    _ = h.vtbl.restartComponent(h, abi.kLatencyChanged);
    try testing.expect(ctx.latency_changed.load(.monotonic));
}

test "queryInterface hands out each interface and counts references" {
    const ctx = try HostContext.create(testing.allocator);
    // One reference owned by the test; queries add more.
    const h = abi.comCast(abi.IComponentHandler, ctx.hostApplication()) orelse return error.TestUnexpectedResult;
    try testing.expect(@intFromPtr(h) == @intFromPtr(&ctx.handler));
    const h2 = abi.comCast(IComponentHandler2, ctx.hostApplication()) orelse return error.TestUnexpectedResult;
    try testing.expect(@intFromPtr(h2) == @intFromPtr(&ctx.handler2));
    try testing.expectEqual(@as(u32, 3), ctx.refs.n.load(.monotonic));
    const bogus: abi.TUID = abi.IPlugFrame.iid;
    var obj: ?*anyopaque = null;
    try testing.expectEqual(abi.kNoInterface, unknownOf(h).queryInterface(&bogus, &obj));
    try testing.expect(obj == null);
    try testing.expectEqual(@as(u32, 2), abi.comRelease(h));
    try testing.expectEqual(@as(u32, 1), abi.comRelease(h2));
    ctx.release(); // frees; the testing allocator checks for leaks
}

test "IComponentHandler2 setDirty and group edits" {
    const ctx = try HostContext.create(testing.allocator);
    defer ctx.release();
    const h2 = abi.comCast(IComponentHandler2, ctx.hostApplication()) orelse return error.TestUnexpectedResult;
    defer _ = abi.comRelease(h2);
    try testing.expectEqual(abi.kResultOk, h2.vtbl.startGroupEdit(h2));
    try testing.expectEqual(abi.kResultOk, h2.vtbl.setDirty(h2, 1));
    try testing.expectEqual(abi.kResultOk, h2.vtbl.finishGroupEdit(h2));
    try testing.expect(ctx.dirty.load(.monotonic));
}

test "createInstance makes IMessage and IAttributeList, refuses others" {
    const ctx = try HostContext.create(testing.allocator);
    defer ctx.release();
    const app = ctx.hostApplication();
    var obj: ?*anyopaque = null;

    const mid: abi.TUID = IMessage.iid;
    try testing.expectEqual(abi.kResultOk, app.vtbl.createInstance(app, &mid, &mid, &obj));
    const msg: *IMessage = @ptrCast(@alignCast(obj.?));
    defer _ = abi.comRelease(msg);

    // setMessageID / getMessageID round trip.
    msg.vtbl.setMessageID(msg, "hello");
    try testing.expectEqualStrings("hello", std.mem.span(msg.vtbl.getMessageID(msg).?));
    msg.vtbl.setMessageID(msg, null);
    try testing.expectEqualStrings("", std.mem.span(msg.vtbl.getMessageID(msg).?));

    // The message's attributes are usable and not add-ref'ed.
    const attrs = msg.vtbl.getAttributes(msg).?;
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.setInt(attrs, "n", 42));
    var n: i64 = 0;
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.getInt(attrs, "n", &n));
    try testing.expectEqual(@as(i64, 42), n);

    const aid: abi.TUID = IAttributeList.iid;
    obj = null;
    const fid: abi.TUID = abi.FUnknown.iid;
    try testing.expectEqual(abi.kResultOk, app.vtbl.createInstance(app, &aid, &fid, &obj));
    _ = abi.comRelease(obj.?);

    obj = null;
    const other: abi.TUID = abi.IPlugFrame.iid;
    try testing.expectEqual(abi.kResultFalse, app.vtbl.createInstance(app, &other, &other, &obj));
    try testing.expect(obj == null);
    // Class and interface ids must agree.
    try testing.expectEqual(abi.kResultFalse, app.vtbl.createInstance(app, &mid, &aid, &obj));
}

test "IAttributeList stores ints, floats, strings and blobs" {
    const a = try HostAttributes.create(testing.allocator);
    defer a.release();
    const l = &a.iface;

    try testing.expectEqual(abi.kInvalidArgument, l.vtbl.setInt(l, null, 1));
    try testing.expectEqual(abi.kResultOk, l.vtbl.setInt(l, "i", -5));
    try testing.expectEqual(abi.kResultOk, l.vtbl.setInt(l, "i", 6)); // replaces
    var i: i64 = 0;
    try testing.expectEqual(abi.kResultOk, l.vtbl.getInt(l, "i", &i));
    try testing.expectEqual(@as(i64, 6), i);
    // Wrong type and missing keys fail without touching the output.
    var f: f64 = 0;
    try testing.expectEqual(abi.kResultFalse, l.vtbl.getFloat(l, "i", &f));
    try testing.expectEqual(abi.kResultFalse, l.vtbl.getInt(l, "missing", &i));

    try testing.expectEqual(abi.kResultOk, l.vtbl.setFloat(l, "f", 1.5));
    try testing.expectEqual(abi.kResultOk, l.vtbl.getFloat(l, "f", &f));
    try testing.expectEqual(@as(f64, 1.5), f);

    const wide = std.unicode.utf8ToUtf16LeStringLiteral("abcdef");
    try testing.expectEqual(abi.kInvalidArgument, l.vtbl.setString(l, "s", null));
    try testing.expectEqual(abi.kResultOk, l.vtbl.setString(l, "s", wide));
    var buf: [16]u16 = undefined;
    try testing.expectEqual(abi.kResultOk, l.vtbl.getString(l, "s", &buf, 32));
    try testing.expectEqualSlices(u16, wide[0..6], buf[0..6]);
    try testing.expectEqual(@as(u16, 0), buf[6]);
    // A small buffer truncates and stays terminated: 4 units = room for 3 + NUL.
    try testing.expectEqual(abi.kResultOk, l.vtbl.getString(l, "s", &buf, 8));
    try testing.expectEqualSlices(u16, wide[0..3], buf[0..3]);
    try testing.expectEqual(@as(u16, 0), buf[3]);
    try testing.expectEqual(abi.kInvalidArgument, l.vtbl.getString(l, "s", &buf, 1));
    try testing.expectEqual(abi.kInvalidArgument, l.vtbl.getString(l, "s", null, 32));

    const blob = [_]u8{ 1, 2, 3, 4 };
    try testing.expectEqual(abi.kResultOk, l.vtbl.setBinary(l, "b", &blob, blob.len));
    var p: ?*const anyopaque = null;
    var sz: u32 = 0;
    try testing.expectEqual(abi.kResultOk, l.vtbl.getBinary(l, "b", &p, &sz));
    try testing.expectEqual(@as(u32, 4), sz);
    const got: [*]const u8 = @ptrCast(p.?);
    try testing.expectEqualSlices(u8, &blob, got[0..4]);
    // An empty blob with a null pointer is legal.
    try testing.expectEqual(abi.kResultOk, l.vtbl.setBinary(l, "e", null, 0));
    try testing.expectEqual(abi.kResultOk, l.vtbl.getBinary(l, "e", &p, &sz));
    try testing.expectEqual(@as(u32, 0), sz);
    try testing.expectEqual(abi.kResultFalse, l.vtbl.getBinary(l, "s", &p, &sz));
}

test "HostPlugFrame records resize requests" {
    const fr = try HostPlugFrame.create(testing.allocator);
    defer fr.release();
    try testing.expect(fr.takeResize() == null);
    var rect: abi.ViewRect = std.mem.zeroes(abi.ViewRect);
    rect.left = 10;
    rect.top = 20;
    rect.right = 410;
    rect.bottom = 320;
    var view: abi.IPlugView = undefined;
    try testing.expectEqual(abi.kResultOk, fr.iface.vtbl.resizeView(&fr.iface, &view, &rect));
    const r = fr.takeResize().?;
    try testing.expectEqual(@as(i32, 400), r.width);
    try testing.expectEqual(@as(i32, 300), r.height);
    try testing.expect(fr.takeResize() == null);
}

/// Asks the host for an object the way a plugin does.
fn createFromHost(ctx: *HostContext, cid: abi.TUID, iid: abi.TUID) ?*anyopaque {
    const app = ctx.hostApplication();
    var obj: ?*anyopaque = null;
    if (app.vtbl.createInstance(app, &cid, &iid, &obj) != abi.kResultOk) return null;
    return obj;
}

// Port of ffi.rs `plugins_get_messages_and_attribute_lists_from_the_host`.
test "plugins_get_messages_and_attribute_lists_from_the_host" {
    const host = try HostContext.create(testing.allocator);
    defer host.release();
    const msg: *IMessage = @ptrCast(@alignCast(createFromHost(host, IMessage.iid, IMessage.iid) orelse return error.TestUnexpectedResult));
    defer _ = abi.comRelease(msg);
    msg.vtbl.setMessageID(msg, "DatabaseInfo");
    try testing.expectEqualStrings("DatabaseInfo", std.mem.span(msg.vtbl.getMessageID(msg).?));
    const attrs = msg.vtbl.getAttributes(msg).?;
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.setInt(attrs, "count", 42));
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.setFloat(attrs, "gain", 0.5));
    const text = std.unicode.utf8ToUtf16LeStringLiteral("Helix");
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.setString(attrs, "name", text));
    const blob = [_]u8{ 1, 2, 3 };
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.setBinary(attrs, "blob", &blob, 3));

    var i: i64 = 0;
    var f: f64 = 0;
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.getInt(attrs, "count", &i));
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.getFloat(attrs, "gain", &f));
    try testing.expectEqual(@as(i64, 42), i);
    try testing.expectEqual(@as(f64, 0.5), f);
    // a float is not an int
    try testing.expectEqual(abi.kResultFalse, attrs.vtbl.getInt(attrs, "gain", &i));
    try testing.expectEqual(abi.kResultFalse, attrs.vtbl.getInt(attrs, "missing", &i));
    // A buffer of 4 units takes 3 characters and the NUL.
    var buf: [4]u16 = @splat(0xFFFF);
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.getString(attrs, "name", &buf, 8));
    try testing.expectEqualSlices(u16, &.{ 'H', 'e', 'l', 0 }, &buf);
    var p: ?*const anyopaque = null;
    var n: u32 = 0;
    try testing.expectEqual(abi.kResultOk, attrs.vtbl.getBinary(attrs, "blob", &p, &n));
    const got: [*]const u8 = @ptrCast(p.?);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, got[0..n]);
    // a null id is refused
    try testing.expectEqual(abi.kInvalidArgument, attrs.vtbl.setInt(attrs, null, 1));

    const al = createFromHost(host, IAttributeList.iid, IAttributeList.iid) orelse return error.TestUnexpectedResult;
    _ = abi.comRelease(al);
    // Anything else is still not provided.
    try testing.expect(createFromHost(host, abi.IComponentHandler.iid, IMessage.iid) == null);
}
