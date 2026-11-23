//! Keeps the machine awake while Seridian Studio plays or records: decides when to take and drop inhibitors, and
//! drives any number of backends (logind, org.freedesktop.ScreenSaver, X11 screensaver; see idle_inhibit_linux.zig).
//!
//! Pure state logic, no I/O: backends are injected, so the rules are unit-tested. Every backend is best effort: a
//! failure is logged (a warning the first time, debug afterwards) and the others still run.

const std = @import("std");

const log = std.log.scoped(.idle_inhibit);

/// Most backends an Inhibitor drives.
pub const max_backends = 4;

/// After playback stops, inhibitors are kept this long, so a quick stop/start does not churn D-Bus calls.
pub const default_grace_seconds: f64 = 3.0;

/// Why a backend could not inhibit. Backends map their failures onto these.
pub const Error = error{
    /// The library (libsystemd/libelogind, libXss...) is not installed.
    LibraryMissing,
    /// No X display, no session bus, no system bus.
    NotAvailable,
    /// The service answered with an error (not running, permission denied...).
    CallFailed,
    /// The reply did not have the expected shape.
    BadReply,
    OutOfMemory,
};

/// One way of inhibiting idle/suspend. `context` is owned by the caller and outlives the Inhibitor.
pub const Backend = struct {
    name: []const u8,
    context: *anyopaque,
    /// Takes the inhibitor. `why` is a human sentence ("Playing audio"), valid for the call only.
    acquire: *const fn (context: *anyopaque, why: [:0]const u8) Error!void,
    /// Drops an inhibitor `acquire` took. Never fails: a backend logs its own cleanup problems.
    release: *const fn (context: *anyopaque) void,
};

/// What the transport is doing this frame.
pub const Activity = struct {
    playing: bool = false,
    recording: bool = false,

    pub fn wantsInhibit(self: Activity) bool {
        return self.playing or self.recording;
    }

    pub fn reason(self: Activity) [:0]const u8 {
        return if (self.recording) "Recording audio" else "Playing audio";
    }
};

/// Takes every backend's inhibitor when playback or recording starts, and drops them `grace_seconds` after both
/// stopped. A backend that failed is retried at the next start. Borrows `backends`; call `releaseAll` before the
/// backends' contexts go away.
pub const Inhibitor = struct {
    backends: []const Backend,
    grace_seconds: f64 = default_grace_seconds,
    held: [max_backends]bool = @splat(false),
    warned: [max_backends]bool = @splat(false),
    /// True from the first frame that wanted inhibiting until the grace period after the last one ended.
    engaged: bool = false,
    idle_since: ?f64 = null,

    pub fn init(backends: []const Backend) error{TooManyBackends}!Inhibitor {
        if (backends.len > max_backends) return error.TooManyBackends;
        return .{ .backends = backends };
    }

    /// Call once per frame with the transport state and a monotonic clock in seconds.
    pub fn update(self: *Inhibitor, activity: Activity, now_seconds: f64) void {
        if (activity.wantsInhibit()) {
            self.idle_since = null;
            if (!self.engaged) {
                self.engaged = true;
                self.acquireAll(activity.reason());
            }
            return;
        }
        if (!self.engaged) return;
        const since = self.idle_since orelse {
            self.idle_since = now_seconds;
            return;
        };
        if (now_seconds - since >= self.grace_seconds) self.releaseAll();
    }

    /// Drops every held inhibitor now (also used at shutdown).
    pub fn releaseAll(self: *Inhibitor) void {
        for (self.backends, 0..) |backend, i| {
            if (!self.held[i]) continue;
            backend.release(backend.context);
            self.held[i] = false;
            log.debug("{s}: idle inhibitor released", .{backend.name});
        }
        self.engaged = false;
        self.idle_since = null;
    }

    /// Number of backends whose inhibitor is held.
    pub fn heldCount(self: *const Inhibitor) usize {
        var n: usize = 0;
        for (self.held[0..self.backends.len]) |h| n += @intFromBool(h);
        return n;
    }

    fn acquireAll(self: *Inhibitor, why: [:0]const u8) void {
        for (self.backends, 0..) |backend, i| {
            if (self.held[i]) continue;
            backend.acquire(backend.context, why) catch |err| {
                if (!self.warned[i]) {
                    self.warned[i] = true;
                    log.warn("{s}: cannot inhibit idle/suspend ({s}); continuing without it", .{ backend.name, @errorName(err) });
                } else {
                    log.debug("{s}: cannot inhibit idle/suspend ({s})", .{ backend.name, @errorName(err) });
                }
                continue;
            };
            self.held[i] = true;
            log.info("{s}: inhibiting idle/suspend: {s}", .{ backend.name, why });
        }
    }
};

// ---- tests ----

const Fake = struct {
    fail_with: ?Error = null,
    held: bool = false,
    acquires: u32 = 0,
    releases: u32 = 0,
    last_why: [32]u8 = @splat(0),

    fn acquire(context: *anyopaque, why: [:0]const u8) Error!void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.acquires += 1;
        if (self.fail_with) |err| return err;
        if (self.held) return error.CallFailed; // a double acquire is a bug in the Inhibitor
        self.held = true;
        @memset(&self.last_why, 0);
        @memcpy(self.last_why[0..why.len], why);
    }

    fn release(context: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.releases += 1;
        self.held = false;
    }

    fn backend(self: *Fake, name: []const u8) Backend {
        return .{ .name = name, .context = self, .acquire = acquire, .release = release };
    }

    fn lastWhy(self: *const Fake) []const u8 {
        return std.mem.sliceTo(&self.last_why, 0);
    }
};

test "activity wants inhibiting while playing or recording, with a matching reason" {
    try std.testing.expect(!(Activity{}).wantsInhibit());
    try std.testing.expect((Activity{ .playing = true }).wantsInhibit());
    try std.testing.expect((Activity{ .recording = true }).wantsInhibit());
    try std.testing.expectEqualStrings("Playing audio", (Activity{ .playing = true }).reason());
    try std.testing.expectEqualStrings("Recording audio", (Activity{ .playing = true, .recording = true }).reason());
}

test "init refuses more backends than it can track" {
    var fake: Fake = .{};
    const many: [max_backends + 1]Backend = @splat(fake.backend("a"));
    try std.testing.expectError(error.TooManyBackends, Inhibitor.init(&many));
    const enough: [max_backends]Backend = @splat(fake.backend("a"));
    _ = try Inhibitor.init(&enough);
}

test "inhibits on play, keeps it through the grace period, releases after" {
    var fake: Fake = .{};
    const backends = [_]Backend{fake.backend("fake")};
    var inhibitor = try Inhibitor.init(&backends);

    inhibitor.update(.{}, 0.0);
    try std.testing.expectEqual(@as(u32, 0), fake.acquires);

    inhibitor.update(.{ .playing = true }, 1.0);
    try std.testing.expect(fake.held);
    try std.testing.expectEqualStrings("Playing audio", fake.lastWhy());
    inhibitor.update(.{ .playing = true }, 1.1);
    try std.testing.expectEqual(@as(u32, 1), fake.acquires); // once per start, not per frame
    try std.testing.expectEqual(@as(usize, 1), inhibitor.heldCount());

    inhibitor.update(.{}, 2.0); // stopped: grace starts
    inhibitor.update(.{}, 4.9);
    try std.testing.expect(fake.held);
    inhibitor.update(.{}, 5.0); // 3 s later
    try std.testing.expect(!fake.held);
    try std.testing.expectEqual(@as(u32, 1), fake.releases);
    try std.testing.expectEqual(@as(usize, 0), inhibitor.heldCount());

    inhibitor.update(.{}, 10.0);
    try std.testing.expectEqual(@as(u32, 1), fake.releases);
}

test "a quick stop and start keeps the same inhibitor" {
    var fake: Fake = .{};
    const backends = [_]Backend{fake.backend("fake")};
    var inhibitor = try Inhibitor.init(&backends);
    inhibitor.update(.{ .playing = true }, 0.0);
    inhibitor.update(.{}, 1.0);
    inhibitor.update(.{}, 2.0);
    inhibitor.update(.{ .playing = true, .recording = true }, 2.5); // grace interrupted
    inhibitor.update(.{}, 3.0);
    inhibitor.update(.{}, 5.9); // grace restarted at 3.0
    try std.testing.expect(fake.held);
    try std.testing.expectEqual(@as(u32, 1), fake.acquires);
    try std.testing.expectEqual(@as(u32, 0), fake.releases);
    inhibitor.update(.{}, 6.0);
    try std.testing.expect(!fake.held);
}

test "a failing backend does not stop the others and is retried at the next start" {
    var broken: Fake = .{ .fail_with = error.LibraryMissing };
    var working: Fake = .{};
    const backends = [_]Backend{ broken.backend("broken"), working.backend("working") };
    var inhibitor = try Inhibitor.init(&backends);
    inhibitor.grace_seconds = 0.0;

    inhibitor.update(.{ .recording = true }, 0.0);
    try std.testing.expect(working.held);
    try std.testing.expectEqualStrings("Recording audio", working.lastWhy());
    try std.testing.expect(inhibitor.warned[0] and !inhibitor.warned[1]);
    try std.testing.expectEqual(@as(usize, 1), inhibitor.heldCount());

    inhibitor.update(.{}, 1.0);
    inhibitor.update(.{}, 1.0);
    try std.testing.expect(!working.held);
    try std.testing.expectEqual(@as(u32, 0), broken.releases); // never held, never released

    broken.fail_with = null; // e.g. the service came up
    inhibitor.update(.{ .playing = true }, 2.0);
    try std.testing.expect(broken.held and working.held);
    try std.testing.expectEqual(@as(u32, 2), broken.acquires);
}

test "releaseAll drops everything at shutdown, even mid-playback" {
    var a: Fake = .{};
    var b: Fake = .{};
    const backends = [_]Backend{ a.backend("a"), b.backend("b") };
    var inhibitor = try Inhibitor.init(&backends);
    inhibitor.update(.{ .playing = true }, 0.0);
    try std.testing.expectEqual(@as(usize, 2), inhibitor.heldCount());
    inhibitor.releaseAll();
    try std.testing.expect(!a.held and !b.held);
    try std.testing.expect(!inhibitor.engaged);
    inhibitor.releaseAll(); // idempotent
    try std.testing.expectEqual(@as(u32, 1), a.releases);
}
