//! Linux idle/suspend inhibitor backends for idle_inhibit.zig, all loaded at run time with dlopen so the UI has no
//! hard dependency on D-Bus or X11 extension libraries:
//!
//!   Logind       org.freedesktop.login1 Manager.Inhibit("idle:sleep", ..., "block") on the system bus, through
//!                sd-bus (libsystemd, libelogind or basu). Holding the returned fd blocks suspend and logind's
//!                idle action; closing it releases.
//!   ScreenSaver  org.freedesktop.ScreenSaver.Inhibit on the session bus (KDE, GNOME, Xfce, hypridle...), through
//!                the same sd-bus library. Some services drop the inhibit when the caller disconnects, so the bus
//!                connection stays open while inhibited.
//!   XScreenSaver XScreenSaverSuspend on the X display (libXss): stops X11 screen blanking.
//!
//! Each backend owns what it opened (library handles, bus connection, fd, display) and frees it in `release` or
//! `deinit`. Every call happens on the UI thread. Method calls time out after `call_timeout_usec`, so a wedged bus
//! cannot freeze the window for long.

const std = @import("std");
const inhibit = @import("idle_inhibit.zig");

const log = std.log.scoped(.idle_inhibit);

const RTLD_NOW: c_int = 2;
const RTLD_LOCAL: c_int = 0;
const F_DUPFD_CLOEXEC: c_int = 1030;

extern "c" fn dlopen(path: ?[*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;
extern "c" fn fcntl(fd: c_int, command: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn strerror(code: c_int) [*:0]const u8;

pub const app_name: [:0]const u8 = "Seridian Studio";
/// Upper bound for one D-Bus method call.
pub const call_timeout_usec: u64 = 500_000;

/// Opens the first library of `names` that loads. The handle is owned by the caller (dlclose).
fn openFirst(names: []const [:0]const u8) ?*anyopaque {
    for (names) |name| {
        if (dlopen(name.ptr, RTLD_NOW | RTLD_LOCAL)) |handle| return handle;
    }
    return null;
}

/// Looks up `name` and casts it to the function pointer type `T`; null when the symbol is missing.
fn lookup(comptime T: type, handle: *anyopaque, name: [*:0]const u8) ?T {
    const symbol = dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

// ---- sd-bus ----

const Bus = opaque {};
const Message = opaque {};
/// `sd_bus_error`; SD_BUS_ERROR_NULL is all zeroes.
const BusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    _need_free: c_int = 0,
};

/// The sd-bus functions the backends call, from whichever library provides them.
pub const SdBus = struct {
    handle: *anyopaque,
    library: [:0]const u8,
    open_system: *const fn (bus: *?*Bus) callconv(.c) c_int,
    open_user: *const fn (bus: *?*Bus) callconv(.c) c_int,
    call_method: *const fn (bus: *Bus, destination: [*:0]const u8, path: [*:0]const u8, interface: [*:0]const u8, member: [*:0]const u8, err: *BusError, reply: ?*?*Message, types: [*:0]const u8, ...) callconv(.c) c_int,
    message_read: *const fn (message: *Message, types: [*:0]const u8, ...) callconv(.c) c_int,
    message_unref: *const fn (message: ?*Message) callconv(.c) ?*Message,
    error_free: *const fn (err: *BusError) callconv(.c) void,
    flush_close_unref: *const fn (bus: ?*Bus) callconv(.c) ?*Bus,
    /// Optional (systemd 240+): without it calls use the library's 25 s default.
    set_method_call_timeout: ?*const fn (bus: *Bus, usec: u64) callconv(.c) c_int,

    pub const candidates = [_][:0]const u8{ "libsystemd.so.0", "libelogind.so.0", "libbasu.so.0" };

    /// Loads sd-bus from the first available library. Release with `deinit`.
    pub fn load() inhibit.Error!SdBus {
        for (candidates) |library| {
            const handle = dlopen(library.ptr, RTLD_NOW | RTLD_LOCAL) orelse continue;
            if (bind(handle, library)) |bus| return bus;
            _ = dlclose(handle);
        }
        return error.LibraryMissing;
    }

    fn bind(handle: *anyopaque, library: [:0]const u8) ?SdBus {
        return .{
            .handle = handle,
            .library = library,
            .open_system = lookup(@FieldType(SdBus, "open_system"), handle, "sd_bus_open_system") orelse return null,
            .open_user = lookup(@FieldType(SdBus, "open_user"), handle, "sd_bus_open_user") orelse return null,
            .call_method = lookup(@FieldType(SdBus, "call_method"), handle, "sd_bus_call_method") orelse return null,
            .message_read = lookup(@FieldType(SdBus, "message_read"), handle, "sd_bus_message_read") orelse return null,
            .message_unref = lookup(@FieldType(SdBus, "message_unref"), handle, "sd_bus_message_unref") orelse return null,
            .error_free = lookup(@FieldType(SdBus, "error_free"), handle, "sd_bus_error_free") orelse return null,
            .flush_close_unref = lookup(@FieldType(SdBus, "flush_close_unref"), handle, "sd_bus_flush_close_unref") orelse return null,
            .set_method_call_timeout = lookup(*const fn (bus: *Bus, usec: u64) callconv(.c) c_int, handle, "sd_bus_set_method_call_timeout"),
        };
    }

    pub fn deinit(self: *SdBus) void {
        _ = dlclose(self.handle);
        self.* = undefined;
    }

    /// Opens the system (`user` false) or session bus with the call timeout set. Close with `closeBus`.
    fn openBus(self: *const SdBus, user: bool) inhibit.Error!*Bus {
        var bus: ?*Bus = null;
        const r = if (user) self.open_user(&bus) else self.open_system(&bus);
        if (r < 0) {
            log.debug("{s}: cannot open the {s} bus: {s}", .{ self.library, if (user) "session" else "system", strerror(-r) });
            return error.NotAvailable;
        }
        const opened = bus orelse return error.NotAvailable;
        if (self.set_method_call_timeout) |set_timeout| {
            const t = set_timeout(opened, call_timeout_usec);
            if (t < 0) log.debug("{s}: cannot set the call timeout: {s}", .{ self.library, strerror(-t) });
        }
        return opened;
    }

    fn closeBus(self: *const SdBus, bus: *Bus) void {
        _ = self.flush_close_unref(bus);
    }

    /// Logs a failed call with the D-Bus error name and message, then frees the error.
    fn logCallError(self: *const SdBus, what: []const u8, r: c_int, err: *BusError) void {
        defer self.error_free(err);
        const name = if (err.name) |n| std.mem.span(n) else "";
        const message = if (err.message) |m| std.mem.span(m) else std.mem.span(strerror(-r));
        log.debug("{s}: {s} failed: {s} {s}", .{ self.library, what, name, message });
    }
};

/// logind "idle:sleep" block inhibitor. `sd` is borrowed and must outlive the backend.
pub const Logind = struct {
    sd: *const SdBus,
    fd: c_int = -1,

    pub fn backend(self: *Logind) inhibit.Backend {
        return .{ .name = "logind", .context = self, .acquire = acquire, .release = release };
    }

    fn acquire(context: *anyopaque, why: [:0]const u8) inhibit.Error!void {
        const self: *Logind = @ptrCast(@alignCast(context));
        if (self.fd >= 0) return;
        const sd = self.sd;
        const bus = try sd.openBus(false);
        // The inhibitor lives as long as the fd, not the connection: the bus is closed right away.
        defer sd.closeBus(bus);
        var err: BusError = .{};
        var reply: ?*Message = null;
        const r = sd.call_method(bus, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "Inhibit", &err, &reply, "ssss", "idle:sleep", app_name.ptr, why.ptr, "block");
        if (r < 0) {
            sd.logCallError("login1 Inhibit", r, &err);
            return error.CallFailed;
        }
        sd.error_free(&err);
        const message = reply orelse return error.BadReply;
        defer _ = sd.message_unref(message);
        var fd: c_int = -1;
        if (sd.message_read(message, "h", &fd) < 0 or fd < 0) return error.BadReply;
        // The reply owns its fd; keep a duplicate of our own.
        const own = fcntl(fd, F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (own < 0) return error.CallFailed;
        self.fd = own;
    }

    fn release(context: *anyopaque) void {
        const self: *Logind = @ptrCast(@alignCast(context));
        if (self.fd < 0) return;
        if (close(self.fd) != 0) log.debug("logind: closing the inhibitor fd failed", .{});
        self.fd = -1;
    }
};

/// org.freedesktop.ScreenSaver cookie inhibitor on the session bus. `sd` is borrowed.
pub const ScreenSaver = struct {
    sd: *const SdBus,
    bus: ?*Bus = null,
    cookie: u32 = 0,

    pub fn backend(self: *ScreenSaver) inhibit.Backend {
        return .{ .name = "screensaver", .context = self, .acquire = acquire, .release = release };
    }

    fn acquire(context: *anyopaque, why: [:0]const u8) inhibit.Error!void {
        const self: *ScreenSaver = @ptrCast(@alignCast(context));
        if (self.bus != null) return;
        const sd = self.sd;
        const bus = try sd.openBus(true);
        errdefer sd.closeBus(bus);
        var err: BusError = .{};
        var reply: ?*Message = null;
        const r = sd.call_method(bus, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "Inhibit", &err, &reply, "ss", app_name.ptr, why.ptr);
        if (r < 0) {
            sd.logCallError("ScreenSaver Inhibit", r, &err);
            return error.CallFailed;
        }
        sd.error_free(&err);
        const message = reply orelse return error.BadReply;
        defer _ = sd.message_unref(message);
        var cookie: u32 = 0;
        if (sd.message_read(message, "u", &cookie) < 0) return error.BadReply;
        self.bus = bus;
        self.cookie = cookie;
    }

    fn release(context: *anyopaque) void {
        const self: *ScreenSaver = @ptrCast(@alignCast(context));
        const bus = self.bus orelse return;
        const sd = self.sd;
        var err: BusError = .{};
        const r = sd.call_method(bus, "org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "UnInhibit", &err, null, "u", self.cookie);
        if (r < 0) {
            // Closing the connection below releases it on services that track the caller.
            sd.logCallError("ScreenSaver UnInhibit", r, &err);
        } else {
            sd.error_free(&err);
        }
        sd.closeBus(bus);
        self.bus = null;
        self.cookie = 0;
    }
};

// ---- X11 screensaver extension ----

const Display = opaque {};

/// XScreenSaverSuspend on its own display connection (the suspension ends with the connection anyway).
pub const XScreenSaver = struct {
    x11: ?*anyopaque = null,
    xss: ?*anyopaque = null,
    open_display: ?OpenDisplayFn = null,
    close_display: ?DisplayFn = null,
    flush: ?DisplayFn = null,
    query_extension: ?QueryExtensionFn = null,
    suspend_fn: ?SuspendFn = null,
    display: ?*Display = null,

    const OpenDisplayFn = *const fn (name: ?[*:0]const u8) callconv(.c) ?*Display;
    const DisplayFn = *const fn (display: *Display) callconv(.c) c_int;
    const QueryExtensionFn = *const fn (display: *Display, event_base: *c_int, error_base: *c_int) callconv(.c) c_int;
    const SuspendFn = *const fn (display: *Display, suspend_: c_int) callconv(.c) void;

    pub fn backend(self: *XScreenSaver) inhibit.Backend {
        return .{ .name = "x11-screensaver", .context = self, .acquire = acquire, .release = release };
    }

    /// Frees the libraries (after `release`).
    pub fn deinit(self: *XScreenSaver) void {
        release(self);
        if (self.xss) |handle| _ = dlclose(handle);
        if (self.x11) |handle| _ = dlclose(handle);
        self.* = .{};
    }

    fn loadLibraries(self: *XScreenSaver) inhibit.Error!void {
        if (self.suspend_fn != null) return;
        const x11 = self.x11 orelse openFirst(&.{ "libX11.so.6", "libX11.so" }) orelse return error.LibraryMissing;
        self.x11 = x11;
        const xss = self.xss orelse openFirst(&.{ "libXss.so.1", "libXss.so" }) orelse return error.LibraryMissing;
        self.xss = xss;
        self.open_display = lookup(OpenDisplayFn, x11, "XOpenDisplay") orelse return error.LibraryMissing;
        self.close_display = lookup(DisplayFn, x11, "XCloseDisplay") orelse return error.LibraryMissing;
        self.flush = lookup(DisplayFn, x11, "XFlush") orelse return error.LibraryMissing;
        self.query_extension = lookup(QueryExtensionFn, xss, "XScreenSaverQueryExtension") orelse return error.LibraryMissing;
        self.suspend_fn = lookup(SuspendFn, xss, "XScreenSaverSuspend") orelse return error.LibraryMissing;
    }

    fn acquire(context: *anyopaque, why: [:0]const u8) inhibit.Error!void {
        _ = why;
        const self: *XScreenSaver = @ptrCast(@alignCast(context));
        if (self.display != null) return;
        const display_name = getenv("DISPLAY") orelse return error.NotAvailable;
        if (display_name[0] == 0) return error.NotAvailable;
        try self.loadLibraries();
        const display = self.open_display.?(null) orelse return error.NotAvailable;
        var event_base: c_int = 0;
        var error_base: c_int = 0;
        if (self.query_extension.?(display, &event_base, &error_base) == 0) {
            // No MIT-SCREEN-SAVER extension (XWayland, for one): nothing to suspend here.
            _ = self.close_display.?(display);
            return error.NotAvailable;
        }
        self.suspend_fn.?(display, 1);
        _ = self.flush.?(display);
        self.display = display;
    }

    fn release(context: *anyopaque) void {
        const self: *XScreenSaver = @ptrCast(@alignCast(context));
        const display = self.display orelse return;
        self.suspend_fn.?(display, 0);
        _ = self.flush.?(display);
        _ = self.close_display.?(display);
        self.display = null;
    }
};

/// Every backend this system offers, ready to hand to idle_inhibit.Inhibitor. Owns the sd-bus library handle and
/// the backend states: keep it at a fixed address while the Inhibitor uses it, and `deinit` after releaseAll.
pub const Backends = struct {
    sd: ?SdBus = null,
    logind: Logind = undefined,
    screensaver: ScreenSaver = undefined,
    xss: XScreenSaver = .{},
    list: [3]inhibit.Backend = undefined,
    count: usize = 0,

    /// Fills `list`. sd-bus backends need libsystemd/libelogind/basu; the X11 one is skipped when `with_x11` is
    /// false (headless). Missing pieces are logged at debug level; nothing here fails.
    pub fn init(self: *Backends, with_x11: bool) void {
        self.* = .{};
        if (SdBus.load()) |sd| {
            self.sd = sd;
            log.debug("sd-bus from {s}", .{sd.library});
            self.logind = .{ .sd = &self.sd.? };
            self.screensaver = .{ .sd = &self.sd.? };
            self.list[self.count] = self.logind.backend();
            self.count += 1;
            self.list[self.count] = self.screensaver.backend();
            self.count += 1;
        } else |err| {
            log.warn("no sd-bus library ({s}); idle/suspend inhibit uses X11 only", .{@errorName(err)});
        }
        if (with_x11) {
            self.list[self.count] = self.xss.backend();
            self.count += 1;
        }
    }

    pub fn slice(self: *const Backends) []const inhibit.Backend {
        return self.list[0..self.count];
    }

    /// Releases anything still held and unloads the libraries.
    pub fn deinit(self: *Backends) void {
        if (self.sd) |*sd| {
            Logind.release(&self.logind);
            ScreenSaver.release(&self.screensaver);
            sd.deinit();
        }
        self.xss.deinit();
        self.* = .{};
    }
};

test "X11 backend needs a display" {
    // With DISPLAY unset there is nothing to suspend: a soft NotAvailable, and release is a no-op.
    if (getenv("DISPLAY") != null) return error.SkipZigTest;
    var xss: XScreenSaver = .{};
    defer xss.deinit();
    const b = xss.backend();
    try std.testing.expectError(error.NotAvailable, b.acquire(b.context, "Playing audio"));
    b.release(b.context);
}

test "backends list sd-bus backends only when a library loads, and X11 only when asked" {
    var backends: Backends = undefined;
    backends.init(false);
    defer backends.deinit();
    const has_sd = backends.sd != null;
    try std.testing.expectEqual(@as(usize, if (has_sd) 2 else 0), backends.slice().len);
    if (has_sd) {
        try std.testing.expectEqualStrings("logind", backends.slice()[0].name);
        try std.testing.expectEqualStrings("screensaver", backends.slice()[1].name);
    }

    var with_x11: Backends = undefined;
    with_x11.init(true);
    defer with_x11.deinit();
    try std.testing.expectEqualStrings("x11-screensaver", with_x11.slice()[with_x11.slice().len - 1].name);
}

test "sd-bus loads from a known library name or reports it missing" {
    var sd = SdBus.load() catch |err| {
        try std.testing.expectEqual(error.LibraryMissing, err);
        return;
    };
    defer sd.deinit();
    var known = false;
    for (SdBus.candidates) |name| known = known or std.mem.eql(u8, name, sd.library);
    try std.testing.expect(known);
}

test "releasing never-acquired sd-bus backends is a no-op" {
    var sd = SdBus.load() catch return error.SkipZigTest;
    defer sd.deinit();
    var logind: Logind = .{ .sd = &sd };
    var screensaver: ScreenSaver = .{ .sd = &sd };
    Logind.release(&logind);
    ScreenSaver.release(&screensaver);
    try std.testing.expectEqual(@as(c_int, -1), logind.fd);
    try std.testing.expect(screensaver.bus == null);
}
