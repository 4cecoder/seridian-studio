// Translated to Zig from soundcraft/crates/vst3-host/src/ffi/module.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Loading VST3 binaries: `dlopen` of the bundle's executable, the platform module entry
//! (`bundleEntry` with a `CFBundleRef` on macOS, `ModuleEntry` with the `dlopen` handle on
//! Linux), the factory, the dedicated MODULE THREAD, and the rules that order module exits
//! against plugin instances.
//!
//! Everything here is control-thread code. Nothing in this file may run on the audio thread: it
//! allocates, takes locks and calls `dlopen`.
//!
//! Exit-ordering rules (kept from the Rust code, with the reason for each):
//!
//! * A loaded binary is cached for the life of the process (see `Registry.load`): plugin code
//!   must never be unmapped while an instance may run, so `dlclose` is never called, and VST3
//!   modules are not required to support being re-entered after their exit function, which
//!   therefore runs once, at process exit (`Registry.exitModules`).
//! * Instances hold a reference on their bundle (`Bundle.acquire` / `Bundle.release`). A module
//!   with a live instance or leaked objects is never exited, so "never unload a module with live
//!   instances" holds even if the host shuts down first.
//! * The module exit runs on the thread that ran the module entry: Qt-based modules tie their
//!   application object to it (Native Instruments' Massive X crashes in `bundleExit` on another
//!   thread). Modules wanted on the main thread are entered there; any other thread's requests go
//!   to the module thread, because the asking thread may be gone by the time the process exits.
//! * Module exits run newest first (the reverse of loading) and before the C++ static
//!   destructors of the modules: an `atexit` hook is registered again after each load, and exit
//!   handlers run in reverse order of registration. VST3 modules expect their exit before their
//!   static destructors run, and some crash in those destructors without it (seen with
//!   Steinberg's HALion Sonic, after a plain scan).
//! * Once the exits have run the shutdown flag is set and later loads are refused.
//!
//! Differences from the Rust code, all deliberate:
//! * `Arc<Bundle>` becomes an explicit reference count on a heap `Bundle`.
//! * There is no panic catching; a plugin that crashes takes the process with it, as in Rust.
//! * The Rust `Bundle::instantiate` builds an `Instance` and host COM objects that belong to the
//!   instance and host translation units; this file provides `Bundle.create` (the factory call it
//!   is built on) and leaves `instantiate` to `instance.zig`.
//! * macOS `CoreFoundation` is reached through `dlopen`/`dlsym` so this library needs no
//!   framework link flag.
//! * Windows (`InitDll`/`ExitDll`) is not supported yet: loading reports `UnsupportedPlatform`.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const scan = @import("scan.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vst3);

pub const hex = abi.hex;

/// A `TUID` as raw bytes (the Rust `[i8; 16]` to `[u8; 16]` conversion; already bytes here).
pub fn tuidBytes(t: *const abi.TUID) [16]u8 {
    return t.*;
}

pub const LoadError = error{
    /// Plugin hosting has shut down (module exits already ran).
    ShutDown,
    /// The bundle has no loadable binary.
    NoBinary,
    /// `dlopen` failed.
    LibraryOpen,
    /// The module entry returned false.
    EntryFailed,
    /// The macOS bundle could not be made into a `CFBundle`.
    NotLoadable,
    /// No `GetPluginFactory` export.
    NotVst3,
    /// `GetPluginFactory` returned null.
    NullFactory,
    /// The module thread could not be started.
    ModuleThreadNotRunning,
    PathTooLong,
    UnsupportedPlatform,
    OutOfMemory,
};

/// One class as reported by the factory. Strings are owned (free with `deinit`).
pub const RawClass = struct {
    cid: [16]u8,
    category: []u8,
    name: []u8,
    vendor: []u8,
    version: []u8,
    sdk_version: []u8,
    sub_categories: []u8,

    pub fn deinit(self: RawClass, gpa: Allocator) void {
        gpa.free(self.category);
        gpa.free(self.name);
        gpa.free(self.vendor);
        gpa.free(self.version);
        gpa.free(self.sdk_version);
        gpa.free(self.sub_categories);
    }
};

/// Frees the result of `Bundle.classes`.
pub fn freeClasses(gpa: Allocator, classes: []RawClass) void {
    for (classes) |c| c.deinit(gpa);
    gpa.free(classes);
}

/// `bundleExit` (macOS), `ExitDll` (Windows) or `ModuleExit` (Linux/BSD).
pub const ModuleExit = *const fn () callconv(.c) bool;
const GetFactory = *const fn () callconv(.c) ?*abi.IPluginFactory;
const ModuleEntry = *const fn (?*anyopaque) callconv(.c) bool;

/// Where a module's entry ran (see the module docs).
pub const EntryThread = enum { main, modules };

// ---- C library ------------------------------------------------------------------------------

const libc = struct {
    extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
    extern "c" fn atexit(f: *const fn () callconv(.c) void) c_int;
    extern "c" fn pthread_self() usize;
    extern "c" fn pthread_main_np() c_int;

    const RTLD_NOW: c_int = 2;
    const RTLD_LOCAL: c_int = if (builtin.os.tag.isDarwin()) 4 else 0;
};

/// CoreFoundation, resolved at run time (macOS only).
const cf = struct {
    const CreateUrl = *const fn (alloc: ?*const anyopaque, buf: [*]const u8, len: isize, is_dir: u8) callconv(.c) ?*const anyopaque;
    const CreateBundle = *const fn (alloc: ?*const anyopaque, url: *const anyopaque) callconv(.c) ?*anyopaque;
    const Release = *const fn (cf: *const anyopaque) callconv(.c) void;

    create_url: CreateUrl,
    create_bundle: CreateBundle,
    release: Release,

    fn load() ?cf {
        const h = libc.dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", libc.RTLD_NOW | libc.RTLD_LOCAL) orelse return null;
        const a = libc.dlsym(h, "CFURLCreateFromFileSystemRepresentation") orelse return null;
        const b = libc.dlsym(h, "CFBundleCreate") orelse return null;
        const r = libc.dlsym(h, "CFRelease") orelse return null;
        return .{ .create_url = @ptrCast(@alignCast(a)), .create_bundle = @ptrCast(@alignCast(b)), .release = @ptrCast(@alignCast(r)) };
    }
};

/// The OS id of the calling thread, which (unlike language-level thread handles) exit handlers
/// can use.
pub fn osThread() usize {
    if (builtin.os.tag == .windows) return 0;
    return libc.pthread_self();
}

/// Whether this is the process main thread.
fn onMainThread() bool {
    if (builtin.os.tag.isDarwin()) return libc.pthread_main_np() == 1;
    if (builtin.os.tag == .linux) return std.os.linux.gettid() == std.os.linux.getpid();
    return false;
}

fn globalIo() Io {
    return Io.Threaded.global_single_threaded.io();
}

// ---- the module thread -----------------------------------------------------------------------

/// One request for the module thread. Heap allocated and shared by the requester and the thread
/// (two references), so a requester that gave up waiting (timeout) leaves nothing dangling.
const Job = struct {
    gpa: Allocator,
    /// Run on the module thread. When the requester may time out, `ctx` must outlive the
    /// requester (heap or global) and `run` is responsible for it.
    run: *const fn (ctx: *anyopaque) void,
    ctx: *anyopaque,
    done: Io.Event = .unset,
    refs: std.atomic.Value(u32) = .init(2),
    next: ?*Job = null,

    fn unref(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.gpa.destroy(self);
    }
};

/// The module thread: started on first use, it runs jobs until the registry is deinitialised (the
/// global registry's thread lives until the process exits). A small mutex + condition queue: the
/// control thread is the only producer, the audio thread never touches it.
const ModuleThread = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    stop: bool = false,
    thread: ?std.Thread = null,
    /// OS id of the module thread (set by the thread itself on start).
    os_id: std.atomic.Value(usize) = .init(0),

    fn main(self: *ModuleThread) void {
        self.os_id.store(osThread(), .release);
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.head == null and !self.stop) self.cond.waitUncancelable(self.io, &self.mutex);
            const job = self.head orelse {
                // stop requested and the queue is drained
                self.mutex.unlock(self.io);
                return;
            };
            self.head = job.next;
            if (self.head == null) self.tail = null;
            self.mutex.unlock(self.io);

            job.run(job.ctx);
            job.done.set(self.io);
            job.unref();
        }
    }

    /// Queues `job`; false when the thread is stopping.
    fn push(self: *ModuleThread, job: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stop) return false;
        job.next = null;
        if (self.tail) |t| t.next = job else self.head = job;
        self.tail = job;
        self.cond.signal(self.io);
        return true;
    }
};

// ---- bundles ---------------------------------------------------------------------------------

/// A loaded VST3 binary and its plugin factory. Reference counted: the registry holds one
/// reference and every instance created from it holds one (`acquire` / `release`).
pub const Bundle = struct {
    gpa: Allocator,
    path: []u8,
    /// The factory, one reference owned by the bundle. Null only for bundles built in tests.
    factory: ?*abi.IPluginFactory,
    /// The module exit matching the entry that ran at load.
    exit_fn: ?ModuleExit,
    /// The thread that ran the module entry, and so must run the exit.
    entered_on: EntryThread,
    /// Set when plugin objects were leaked on purpose: the module exit must not run while any of
    /// its objects are alive.
    leaked: std.atomic.Value(bool) = .init(false),
    /// Registry reference + live instances.
    refs: std.atomic.Value(usize) = .init(1),
    // The library handle is never closed: code stays mapped for the process lifetime, even after
    // the module exit.

    /// Adds a reference (an instance holds one for its whole life; it must be released after the
    /// instance's plugin objects are destroyed).
    pub fn acquire(self: *Bundle) *Bundle {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }

    /// Drops a reference taken with `acquire` (or returned by `Registry.load`).
    pub fn release(self: *Bundle) void {
        const prev = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(prev > 1); // the registry's own reference keeps the bundle alive
    }

    /// Plugin objects of this module were leaked on purpose: never run its module exit.
    pub fn markLeaked(self: *Bundle) void {
        self.leaked.store(true, .release);
    }

    /// Releases the factory, then runs the module exit, as the VST3 SDK's own host does, and
    /// frees the bundle. Called once, with no other reference left (every instance is gone) and
    /// on the thread that ran the entry. The code stays mapped.
    fn exit(self: *Bundle) void {
        if (self.factory) |f| _ = abi.comRelease(f);
        self.factory = null;
        if (self.exit_fn) |f| {
            // Balanced with the entry that ran when the module was loaded.
            _ = f();
        }
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    /// The vendor from the factory info (fallback for classes without one). Caller frees.
    fn factoryVendor(self: *Bundle, gpa: Allocator) Allocator.Error![]u8 {
        const f = self.factory orelse return gpa.alloc(u8, 0);
        var info = std.mem.zeroes(abi.PFactoryInfo);
        if (abi.ok(f.getFactoryInfo(&info))) return abi.readC8Alloc(gpa, &info.vendor);
        return gpa.alloc(u8, 0);
    }

    /// Every class this binary exports (at most `abi.MAX_CLASSES`; the count is hostile input).
    /// Free with `freeClasses`.
    pub fn classes(self: *Bundle, gpa: Allocator) Allocator.Error![]RawClass {
        var out: std.ArrayList(RawClass) = .empty;
        errdefer {
            for (out.items) |cl| cl.deinit(gpa);
            out.deinit(gpa);
        }
        const f = self.factory orelse return out.toOwnedSlice(gpa);
        const n = std.math.clamp(f.countClasses(), 0, abi.MAX_CLASSES);
        const f2 = abi.comCast(abi.IPluginFactory2, f);
        defer if (f2) |p| {
            _ = abi.comRelease(p);
        };
        const vendor = try self.factoryVendor(gpa);
        defer gpa.free(vendor);

        var i: i32 = 0;
        while (i < n) : (i += 1) {
            if (f2) |p| {
                var ci = std.mem.zeroes(abi.PClassInfo2);
                if (abi.ok(p.getClassInfo2(i, &ci))) {
                    const v = abi.readC8(&ci.vendor);
                    var rc = RawClass{
                        .cid = tuidBytes(&ci.cid),
                        .category = &.{},
                        .name = &.{},
                        .vendor = &.{},
                        .version = &.{},
                        .sdk_version = &.{},
                        .sub_categories = &.{},
                    };
                    errdefer rc.deinit(gpa);
                    rc.category = try abi.readC8Alloc(gpa, &ci.category);
                    rc.name = try abi.readC8Alloc(gpa, &ci.name);
                    rc.vendor = if (v.len == 0) try gpa.dupe(u8, vendor) else try abi.readC8Alloc(gpa, &ci.vendor);
                    rc.version = try abi.readC8Alloc(gpa, &ci.version);
                    rc.sdk_version = try abi.readC8Alloc(gpa, &ci.sdkVersion);
                    rc.sub_categories = try abi.readC8Alloc(gpa, &ci.subCategories);
                    try out.append(gpa, rc);
                    continue;
                }
            }
            var ci = std.mem.zeroes(abi.PClassInfo);
            if (abi.ok(f.getClassInfo(i, &ci))) {
                var rc = RawClass{
                    .cid = tuidBytes(&ci.cid),
                    .category = &.{},
                    .name = &.{},
                    .vendor = &.{},
                    .version = &.{},
                    .sdk_version = &.{},
                    .sub_categories = &.{},
                };
                errdefer rc.deinit(gpa);
                rc.category = try abi.readC8Alloc(gpa, &ci.category);
                rc.name = try abi.readC8Alloc(gpa, &ci.name);
                rc.vendor = try gpa.dupe(u8, vendor);
                rc.version = try gpa.alloc(u8, 0);
                rc.sdk_version = try gpa.alloc(u8, 0);
                rc.sub_categories = try gpa.alloc(u8, 0);
                try out.append(gpa, rc);
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Creates an object of class `cid` and queries interface `I` on it. On success the result
    /// owns one reference. A hostile factory that reports success with a null object is treated
    /// as failure.
    pub fn create(self: *Bundle, comptime I: type, cid: *const [16]u8) ?*I {
        const f = self.factory orelse return null;
        var obj: ?*anyopaque = null;
        const id: abi.TUID = I.iid;
        if (!abi.ok(f.createInstance(cid, &id, &obj))) return null;
        const o = obj orelse return null;
        return @ptrCast(@alignCast(o));
    }
};

/// Opens the shared library and runs the platform module entry. Also returns the matching
/// module exit, when the entry ran and the module exports one.
fn openLibrary(bundle_path: []const u8, exe: [:0]const u8) LoadError!struct { handle: *anyopaque, exit: ?ModuleExit } {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            // SAFETY of loading: it runs the module's static initialisers. That is inherent to
            // hosting plugins; we only load files found in VST3 plugin folders or named
            // explicitly.
            const lib = libc.dlopen(exe.ptr, libc.RTLD_NOW | libc.RTLD_LOCAL) orelse return error.LibraryOpen;
            const entry_sym = libc.dlsym(lib, "bundleEntry") orelse libc.dlsym(lib, "BundleEntry");
            var exit: ?ModuleExit = null;
            // A bundle directory (not a single-file plugin) is needed to build the CFBundleRef.
            const is_bundle = !std.mem.eql(u8, bundle_path, exe);
            if (entry_sym) |sym| if (is_bundle) {
                const entry: ModuleEntry = @ptrCast(@alignCast(sym));
                const cfw = cf.load() orelse return error.NotLoadable;
                const len = std.math.cast(isize, bundle_path.len) orelse return error.PathTooLong;
                const url = cfw.create_url(null, bundle_path.ptr, len, 1) orelse return error.NotLoadable;
                const cfbundle = cfw.create_bundle(null, url);
                cfw.release(url);
                const b = cfbundle orelse return error.NotLoadable;
                // Called once with a valid CFBundleRef. The bundle ref is intentionally kept
                // (never released): the module may hold on to it for its whole life, and loaded
                // modules are never unloaded.
                if (!entry(b)) return error.EntryFailed;
                const exit_sym = libc.dlsym(lib, "bundleExit") orelse libc.dlsym(lib, "BundleExit");
                if (exit_sym) |e| exit = @ptrCast(@alignCast(e));
            };
            return .{ .handle = lib, .exit = exit };
        },
        .windows => return error.UnsupportedPlatform,
        else => {
            const lib = libc.dlopen(exe.ptr, libc.RTLD_NOW | libc.RTLD_LOCAL) orelse return error.LibraryOpen;
            var exit: ?ModuleExit = null;
            if (libc.dlsym(lib, "ModuleEntry")) |sym| {
                const entry: ModuleEntry = @ptrCast(@alignCast(sym));
                // Called once, with the module's own dlopen handle, as the spec requires.
                if (!entry(lib)) return error.EntryFailed;
                if (libc.dlsym(lib, "ModuleExit")) |e| exit = @ptrCast(@alignCast(e));
            }
            return .{ .handle = lib, .exit = exit };
        },
    }
}

// ---- the registry -----------------------------------------------------------------------------

/// The set of loaded binaries and the module thread. There is one process-wide instance, `global`
/// (what the host uses); tests make their own with `init`.
pub const Registry = struct {
    gpa: Allocator,
    io: Io,
    /// Loaded binaries, oldest first (module exits run newest first, the reverse of loading).
    mutex: Io.Mutex = .init,
    loaded: std.ArrayList(*Bundle) = .empty,
    /// Set once the module exits have run: loading another module after that is refused.
    modules_exited: std.atomic.Value(bool) = .init(false),
    /// The OS id of the main thread, recorded when it loads a module (0 until then).
    main_os_thread: std.atomic.Value(usize) = .init(0),
    /// Tests: pretend the calling thread is (true) or is not (false) the main thread.
    assume_main: ?bool = null,
    /// Whether `load` registers the `atexit` hook (the global registry only).
    exit_hook: bool = false,

    thread_mutex: Io.Mutex = .init,
    mt: ?*ModuleThread = null,

    pub fn init(gpa: Allocator) Registry {
        return .{ .gpa = gpa, .io = globalIo() };
    }

    /// Stops the module thread and frees every cached bundle without running any module exit
    /// (tests only; the global registry is never deinitialised).
    pub fn deinit(self: *Registry) void {
        if (self.mt) |mt| {
            mt.mutex.lockUncancelable(mt.io);
            mt.stop = true;
            mt.cond.broadcast(mt.io);
            mt.mutex.unlock(mt.io);
            if (mt.thread) |t| t.join();
            self.gpa.destroy(mt);
            self.mt = null;
        }
        for (self.loaded.items) |b| {
            self.gpa.free(b.path);
            self.gpa.destroy(b);
        }
        self.loaded.deinit(self.gpa);
    }

    fn isMainThread(self: *const Registry) bool {
        return self.assume_main orelse onMainThread();
    }

    /// The module thread (started on first use); null when it cannot be started.
    fn moduleThread(self: *Registry) ?*ModuleThread {
        self.thread_mutex.lockUncancelable(self.io);
        defer self.thread_mutex.unlock(self.io);
        if (self.mt) |mt| return mt;
        const mt = self.gpa.create(ModuleThread) catch return null;
        mt.* = .{ .io = self.io };
        mt.thread = std.Thread.spawn(.{}, ModuleThread.main, .{mt}) catch {
            self.gpa.destroy(mt);
            return null;
        };
        mt.thread.?.setName(self.io, "vst3-modules") catch {};
        self.mt = mt;
        return mt;
    }

    /// Runs `run(ctx)` on the module thread and waits for it (at most `timeout_ns`, when given).
    /// Returns false when the thread is not running or the wait timed out. With a timeout, `ctx`
    /// must outlive this call (the job may still run later) and `run` owns it.
    pub fn onModuleThread(self: *Registry, ctx: *anyopaque, run: *const fn (ctx: *anyopaque) void, timeout_ns: ?u64) bool {
        const mt = self.moduleThread() orelse return false;
        const job = self.gpa.create(Job) catch return false;
        job.* = .{ .gpa = self.gpa, .run = run, .ctx = ctx };
        if (!mt.push(job)) {
            self.gpa.destroy(job);
            return false;
        }
        defer job.unref();
        if (timeout_ns) |ns| {
            const t: Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(@intCast(ns)), .clock = .awake } };
            job.done.waitTimeout(self.io, t) catch return false;
        } else {
            job.done.waitUncancelable(self.io);
        }
        return true;
    }

    /// The OS id of the module thread, once started (0 before).
    pub fn moduleThreadId(self: *Registry) usize {
        const mt = self.mt orelse return 0;
        return mt.os_id.load(.acquire);
    }

    /// Adds an already built bundle to the cache (the caller's reference is the registry's).
    /// Used by `load` and by tests that build fake bundles.
    pub fn adopt(self: *Registry, b: *Bundle) Allocator.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.loaded.append(self.gpa, b);
    }

    /// Loads (once per path, then cached for the life of the process) a `.vst3`. The result
    /// carries a reference for the caller: `release` it when done.
    pub fn load(self: *Registry, path: []const u8) LoadError!*Bundle {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.loaded.items) |b| {
            if (std.mem.eql(u8, b.path, path)) return b.acquire();
        }
        if (self.modules_exited.load(.acquire)) return error.ShutDown;

        const b: *Bundle = if (self.isMainThread()) blk: {
            self.main_os_thread.store(osThread(), .release);
            break :blk try self.open(path, .main);
        } else blk: {
            // Not the main thread: the module thread loads (and later unloads) it.
            const Ctx = struct {
                reg: *Registry,
                path: []const u8,
                result: LoadError!*Bundle = error.ModuleThreadNotRunning,
                fn run(p: *anyopaque) void {
                    const s: *@This() = @ptrCast(@alignCast(p));
                    s.result = s.reg.open(s.path, .modules);
                }
            };
            var ctx: Ctx = .{ .reg = self, .path = path };
            if (!self.onModuleThread(&ctx, Ctx.run, null)) return error.ModuleThreadNotRunning;
            break :blk try ctx.result;
        };
        // One reference for the registry (already counted in `refs = 1`) and one for the caller.
        self.loaded.append(self.gpa, b) catch {
            // Balance the entry that ran; no plugin object exists yet.
            b.exit();
            return error.OutOfMemory;
        };
        _ = b.acquire();
        // After every new module, so that the exits run before its static destructors.
        if (self.exit_hook) registerExitHook();
        return b;
    }

    /// Runs on the thread chosen by `load`: opens the binary, runs the module entry and fetches
    /// the factory.
    fn open(self: *Registry, path: []const u8, entered_on: EntryThread) LoadError!*Bundle {
        const exe_alloc = (scan.bundleBinary(self.gpa, self.io, path) catch return error.OutOfMemory) orelse return error.NoBinary;
        defer self.gpa.free(exe_alloc);
        const exe = self.gpa.dupeSentinel(u8, exe_alloc, 0) catch return error.OutOfMemory;
        defer self.gpa.free(exe);

        const lib = try openLibrary(path, exe);
        // The module entry ran: balance it before giving up on the module.
        const get_sym = libc.dlsym(lib.handle, "GetPluginFactory") orelse {
            if (lib.exit) |f| _ = f();
            return error.NotVst3;
        };
        const get: GetFactory = @ptrCast(@alignCast(get_sym));
        // The module is loaded and its entry function (if any) has run. A non-null result is a
        // factory pointer with one reference owned by the caller (VST3 contract).
        const factory = get() orelse {
            if (lib.exit) |f| _ = f();
            return error.NullFactory;
        };
        const owned_path = self.gpa.dupe(u8, path) catch |e| {
            _ = abi.comRelease(factory);
            if (lib.exit) |f| _ = f();
            return e;
        };
        const b = self.gpa.create(Bundle) catch |e| {
            self.gpa.free(owned_path);
            _ = abi.comRelease(factory);
            if (lib.exit) |f| _ = f();
            return e;
        };
        b.* = .{ .gpa = self.gpa, .path = owned_path, .factory = factory, .exit_fn = lib.exit, .entered_on = entered_on };
        return b;
    }

    /// Runs the module exits at process exit, newest module first, each on the thread that ran
    /// its entry (see the module docs). A module with a live instance or leaked objects keeps
    /// running and is not exited, and so is one entered on the main thread when the process
    /// exits from another thread. Runs once; later loads are refused.
    pub fn exitModules(self: *Registry) void {
        if (self.modules_exited.swap(true, .acq_rel)) return;
        // Another thread is loading a module right now: leave every module as it is.
        if (!self.mutex.tryLock()) return;
        const main = self.main_os_thread.load(.acquire) == osThread() or (self.assume_main orelse false);

        var kept: std.ArrayList(*Bundle) = .empty;
        var here: std.ArrayList(*Bundle) = .empty;
        var there: std.ArrayList(*Bundle) = .empty;
        defer kept.deinit(self.gpa);
        defer here.deinit(self.gpa);
        defer there.deinit(self.gpa);

        while (self.loaded.pop()) |b| {
            // The registry's reference is the only one left only when no instance is alive.
            const idle = b.refs.load(.acquire) == 1;
            const skip = b.leaked.load(.acquire) or (b.entered_on == .main and !main) or !idle;
            if (skip) {
                kept.append(self.gpa, b) catch {};
                continue;
            }
            const list = if (b.entered_on == .main) &here else &there;
            list.append(self.gpa, b) catch kept.append(self.gpa, b) catch {};
        }
        std.mem.reverse(*Bundle, kept.items);
        self.loaded.clearRetainingCapacity();
        self.loaded.appendSlice(self.gpa, kept.items) catch {};
        self.mutex.unlock(self.io);

        for (here.items) |b| b.exit();
        if (there.items.len > 0) {
            // Bounded: a module thread stuck inside a plugin must not hang the process exit.
            const Batch = struct {
                gpa: Allocator,
                items: []*Bundle,
                fn run(p: *anyopaque) void {
                    const s: *@This() = @ptrCast(@alignCast(p));
                    for (s.items) |b| b.exit();
                    s.gpa.free(s.items);
                    s.gpa.destroy(s);
                }
            };
            const batch = self.gpa.create(Batch) catch return;
            const items = self.gpa.dupe(*Bundle, there.items) catch {
                self.gpa.destroy(batch);
                return;
            };
            batch.* = .{ .gpa = self.gpa, .items = items };
            if (!self.onModuleThread(batch, Batch.run, 5 * std.time.ns_per_s)) {
                // Timed out or no thread: the batch (if it was queued) frees itself when it runs.
                if (self.mt == null) {
                    self.gpa.free(items);
                    self.gpa.destroy(batch);
                }
            }
        }
    }
};

/// The process-wide registry used by the host.
pub var global: Registry = .{ .gpa = std.heap.smp_allocator, .io = undefined, .exit_hook = true };
var global_ready = std.atomic.Value(bool).init(false);

/// The process-wide registry (its `Io` is bound on first use).
pub fn globalRegistry() *Registry {
    if (!global_ready.load(.acquire)) {
        global.io = globalIo();
        global_ready.store(true, .release);
    }
    return &global;
}

/// Loads a bundle through the process-wide registry.
pub fn loadBundle(path: []const u8) LoadError!*Bundle {
    return globalRegistry().load(path);
}

/// Runs the process-wide module exits (what the `atexit` hook does).
pub fn exitModules() void {
    globalRegistry().exitModules();
}

/// Registers `exitModules` to run at process exit. Exit handlers run in reverse order of
/// registration, C++ static destructors included, so registering again after each module load
/// puts the exits ahead of the destructors of every module loaded so far.
fn registerExitHook() void {
    const hook = struct {
        fn run() callconv(.c) void {
            exitModules();
        }
    };
    if (libc.atexit(hook.run) != 0) {
        log.warn("cannot register the module exit handler", .{});
    }
}

// ---- tests -------------------------------------------------------------------------------------
//
// module.rs has no tests of its own; these cover the ordering rules it documents, using fake
// bundles (no plugin binary is loaded).

const testing = std.testing;

var exit_log: [8]usize = undefined;
var exit_threads: [8]usize = undefined;
var exit_count = std.atomic.Value(usize).init(0);

fn resetLog() void {
    exit_count.store(0, .seq_cst);
}

fn recordExit(tag: usize) bool {
    const i = exit_count.fetchAdd(1, .seq_cst);
    exit_log[i] = tag;
    exit_threads[i] = osThread();
    return true;
}
fn exitA() callconv(.c) bool {
    return recordExit(1);
}
fn exitB() callconv(.c) bool {
    return recordExit(2);
}
fn exitC() callconv(.c) bool {
    return recordExit(3);
}

fn fakeBundle(reg: *Registry, name: []const u8, exit_fn: ?ModuleExit, entered_on: EntryThread) !*Bundle {
    const b = try reg.gpa.create(Bundle);
    b.* = .{ .gpa = reg.gpa, .path = try reg.gpa.dupe(u8, name), .factory = null, .exit_fn = exit_fn, .entered_on = entered_on };
    try reg.adopt(b);
    return b;
}

test "tuidBytes and hex" {
    const t: abi.TUID = .{ 0xAB, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 0xFF };
    try testing.expectEqualSlices(u8, &t, &tuidBytes(&t));
    const h = hex(&t);
    try testing.expectEqualStrings("AB000102030405060708090A0B0C0DFF", &h);
}

test "loading a missing path fails without starting anything" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = true;
    try testing.expectError(error.NoBinary, reg.load("/definitely/not/here.vst3"));
    try testing.expectEqual(@as(usize, 0), reg.loaded.items.len);
}

test "the module thread runs jobs on its own thread and returns" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const Ctx = struct {
        thread: usize = 0,
        n: u32 = 0,
        fn run(p: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(p));
            s.thread = osThread();
            s.n += 1;
        }
    };
    var ctx: Ctx = .{};
    try testing.expect(reg.onModuleThread(&ctx, Ctx.run, null));
    try testing.expect(reg.onModuleThread(&ctx, Ctx.run, null));
    try testing.expectEqual(@as(u32, 2), ctx.n);
    try testing.expect(ctx.thread != osThread());
    try testing.expectEqual(reg.moduleThreadId(), ctx.thread);
}

test "a wait that times out leaves the job to finish on its own" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const Ctx = struct {
        gpa: Allocator,
        flag: *std.atomic.Value(bool),
        fn run(p: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(p));
            Io.sleep(globalIo(), .fromMilliseconds(300), .awake) catch {};
            s.flag.store(true, .release);
            s.gpa.destroy(s);
        }
    };
    var flag: std.atomic.Value(bool) = .init(false);
    const ctx = try testing.allocator.create(Ctx);
    ctx.* = .{ .gpa = testing.allocator, .flag = &flag };
    try testing.expect(!reg.onModuleThread(ctx, Ctx.run, 20 * std.time.ns_per_ms));
    try testing.expect(!flag.load(.acquire));
    // deinit joins the thread, which finishes the queued job first.
    reg.deinit();
    try testing.expect(flag.load(.acquire));
    reg = Registry.init(testing.allocator);
}

test "exits run newest first and only once; later loads are refused" {
    resetLog();
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = true;
    const a = try fakeBundle(&reg, "a.vst3", exitA, .main);
    const b = try fakeBundle(&reg, "b.vst3", exitB, .main);
    const cb = try fakeBundle(&reg, "c.vst3", exitC, .main);
    _ = .{ a, b, cb };
    reg.exitModules();
    try testing.expectEqual(@as(usize, 3), exit_count.load(.seq_cst));
    try testing.expectEqualSlices(usize, &.{ 3, 2, 1 }, exit_log[0..3]);
    try testing.expectEqual(@as(usize, 0), reg.loaded.items.len);
    try testing.expect(reg.modules_exited.load(.acquire));
    reg.exitModules();
    try testing.expectEqual(@as(usize, 3), exit_count.load(.seq_cst));
    try testing.expectError(error.ShutDown, reg.load("/nope.vst3"));
}

test "a module with a live instance or leaked objects is never exited" {
    resetLog();
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = true;
    const a = try fakeBundle(&reg, "a.vst3", exitA, .main);
    const live = try fakeBundle(&reg, "live.vst3", exitB, .main);
    const leaked = try fakeBundle(&reg, "leaked.vst3", exitC, .main);
    _ = a;
    _ = live.acquire(); // an instance
    leaked.markLeaked();
    reg.exitModules();
    try testing.expectEqual(@as(usize, 1), exit_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 1), exit_log[0]);
    // The kept ones stay cached, oldest first.
    try testing.expectEqual(@as(usize, 2), reg.loaded.items.len);
    try testing.expectEqualStrings("live.vst3", reg.loaded.items[0].path);
    try testing.expectEqualStrings("leaked.vst3", reg.loaded.items[1].path);
    live.release();
}

test "a bundle entered on the main thread is kept when exit runs elsewhere" {
    resetLog();
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = false;
    _ = try fakeBundle(&reg, "main.vst3", exitA, .main);
    reg.exitModules();
    try testing.expectEqual(@as(usize, 0), exit_count.load(.seq_cst));
    try testing.expectEqual(@as(usize, 1), reg.loaded.items.len);
}

test "a module entered on the module thread exits on the module thread" {
    resetLog();
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    reg.assume_main = false;
    // Start the thread so its id is known, then adopt bundles entered on it.
    const Nop = struct {
        fn run(_: *anyopaque) void {}
    };
    var dummy: u8 = 0;
    try testing.expect(reg.onModuleThread(&dummy, Nop.run, null));
    _ = try fakeBundle(&reg, "x.vst3", exitA, .modules);
    _ = try fakeBundle(&reg, "y.vst3", exitB, .modules);
    reg.exitModules();
    try testing.expectEqual(@as(usize, 2), exit_count.load(.seq_cst));
    try testing.expectEqualSlices(usize, &.{ 2, 1 }, exit_log[0..2]);
    try testing.expect(exit_threads[0] != osThread());
    try testing.expectEqual(reg.moduleThreadId(), exit_threads[0]);
    try testing.expectEqual(reg.moduleThreadId(), exit_threads[1]);
}

test "load returns the cached bundle with an extra reference" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    const b = try fakeBundle(&reg, "cached.vst3", null, .main);
    const again = try reg.load("cached.vst3");
    try testing.expect(again == b);
    try testing.expectEqual(@as(usize, 2), b.refs.load(.acquire));
    again.release();
    try testing.expectEqual(@as(usize, 1), b.refs.load(.acquire));
}
