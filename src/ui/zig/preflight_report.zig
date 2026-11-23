//! System preflight for the window: the C layout of the engine's report (`daw_preflight_*`, see
//! src/system/preflight_types.zig), the summary the header indicator shows, and a background runner so the
//! check (it spawns tools and reads /proc, tens of milliseconds) never blocks a UI frame.
//!
//! Pure Zig, no Raven: tested in `zig build test-ui`. The layout is checked against the engine's own definition by
//! src/ui_abi_test.zig (part of `zig build test`).

const std = @import("std");

pub const max_checks = 32;

pub const status_ok: u32 = 0;
pub const status_info: u32 = 1;
pub const status_warn: u32 = 2;
pub const status_fail: u32 = 3;

/// One check, as `daw_preflight_run` writes it. Strings are NUL-terminated.
pub const CCheck = extern struct {
    /// preflight.CheckId.
    id: u32,
    /// status_ok / status_info / status_warn / status_fail.
    status: u32,
    /// preflight.FixId; 0 = no automatic fix.
    fix: u32,
    /// Stable machine name ("audio_server").
    key: [32]u8,
    title: [64]u8,
    detail: [256]u8,
    hint: [256]u8,
};

pub const CReport = extern struct {
    desktop: [32]u8,
    session: [16]u8,
    desktop_version: [32]u8,
    count: u32,
    checks: [max_checks]CCheck,

    /// The filled checks (count clamped to the array).
    pub fn items(self: *const CReport) []const CCheck {
        return self.checks[0..@min(self.count, max_checks)];
    }
};

/// Engine settings copied on the UI thread before a run (mirror of the engine's CEngineSnapshot).
pub const CEngineSnapshot = extern struct {
    has_engine: u32,
    sample_rate: u32,
    buffer_size: u32,
    backend: [16]u8,
};

/// `void daw_preflight_snapshot(void *engine, CEngineSnapshot *out)`, called on the thread that starts a run.
pub const SnapshotFn = *const fn (engine: ?*anyopaque, out: *CEngineSnapshot) callconv(.c) void;

/// `void daw_preflight_run_snapshot(CReport *out, const CEngineSnapshot *snap)`, called on the worker.
pub const RunFn = *const fn (out: *CReport, snap: ?*const CEngineSnapshot) callconv(.c) void;

/// NUL-terminated field as a slice.
pub fn text(field: []const u8) []const u8 {
    return std.mem.sliceTo(field, 0);
}

/// What the header indicator shows for a report.
pub const Summary = struct {
    worst: u32 = status_ok,
    warnings: u32 = 0,
    failures: u32 = 0,
    infos: u32 = 0,
    checks: u32 = 0,
};

pub fn summarize(report: *const CReport) Summary {
    var summary: Summary = .{};
    for (report.items()) |check| {
        summary.checks += 1;
        summary.worst = @max(summary.worst, @min(check.status, status_fail));
        switch (check.status) {
            status_ok => {},
            status_info => summary.infos += 1,
            status_warn => summary.warnings += 1,
            else => summary.failures += 1,
        }
    }
    return summary;
}

/// Header indicator text: "System OK", "2 warnings", "1 problem, 3 warnings". Writes into `buffer` (caller-owned)
/// and returns the NUL-terminated text; a too-small buffer gives error.NoSpaceLeft.
pub fn indicatorText(summary: Summary, buffer: []u8) error{NoSpaceLeft}![:0]const u8 {
    if (summary.failures == 0 and summary.warnings == 0) {
        return std.fmt.bufPrintSentinel(buffer, "System OK", .{}, 0);
    }
    if (summary.failures == 0) {
        return std.fmt.bufPrintSentinel(buffer, "{d} {s}", .{ summary.warnings, plural(summary.warnings, "warning", "warnings") }, 0);
    }
    if (summary.warnings == 0) {
        return std.fmt.bufPrintSentinel(buffer, "{d} {s}", .{ summary.failures, plural(summary.failures, "problem", "problems") }, 0);
    }
    return std.fmt.bufPrintSentinel(buffer, "{d} {s}, {d} {s}", .{
        summary.failures,
        plural(summary.failures, "problem", "problems"),
        summary.warnings,
        plural(summary.warnings, "warning", "warnings"),
    }, 0);
}

fn plural(count: u32, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

/// Bracketed label, the vocabulary of `seridian doctor`.
pub fn statusLabel(status: u32) [:0]const u8 {
    return switch (status) {
        status_ok => "PASS",
        status_info => "INFO",
        status_warn => "WARN",
        else => "FAIL",
    };
}

/// Pill colour per status, from the window palette: neon cyan, muted, amber, red.
pub fn statusColor(status: u32) [3]f32 {
    return switch (status) {
        status_ok => .{ 0.000, 0.941, 1.000 },
        status_info => .{ 0.420, 0.478, 0.600 },
        status_warn => .{ 1.000, 0.690, 0.125 },
        else => .{ 1.000, 0.302, 0.302 },
    };
}

/// True when a check deserves the user's attention (shown with its hint and fix).
pub fn needsAttention(check: *const CCheck) bool {
    return check.status == status_warn or check.status == status_fail;
}

/// Runs the preflight on a worker thread and hands finished reports to the UI thread.
///
/// Ownership: the runner owns two heap reports (from `allocator`): `back` is written only by the worker while
/// `state` is `.running`; `front` is read only by the UI thread. `poll` swaps them once the worker is done, so no
/// report is ever read and written at the same time. Call `deinit` (it joins the worker) before freeing.
///
/// Threading: the worker never sees the engine. `start` copies the engine settings into `snapshot` on the calling
/// (UI) thread through `snapshot_fn`; the worker reads only that copy, which is not written again until the run
/// has been collected.
pub const Runner = struct {
    allocator: std.mem.Allocator,
    run_fn: RunFn,
    snapshot_fn: SnapshotFn,
    engine: ?*anyopaque,
    snapshot: CEngineSnapshot = std.mem.zeroes(CEngineSnapshot),
    front: *CReport,
    back: *CReport,
    has_report: bool = false,
    thread: ?std.Thread = null,
    state: std.atomic.Value(State) = .init(.idle),

    pub const State = enum(u8) { idle, running, done };

    pub fn init(allocator: std.mem.Allocator, run_fn: RunFn, snapshot_fn: SnapshotFn, engine: ?*anyopaque) error{OutOfMemory}!Runner {
        const front = try allocator.create(CReport);
        errdefer allocator.destroy(front);
        const back = try allocator.create(CReport);
        front.* = std.mem.zeroes(CReport);
        back.* = std.mem.zeroes(CReport);
        return .{ .allocator = allocator, .run_fn = run_fn, .snapshot_fn = snapshot_fn, .engine = engine, .front = front, .back = back };
    }

    /// Joins a running worker, then frees both reports.
    pub fn deinit(self: *Runner) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.allocator.destroy(self.front);
        self.allocator.destroy(self.back);
        self.* = undefined;
    }

    /// Starts a run unless one is in flight (error.Busy). A finished run that `poll` has not collected yet is
    /// collected first, so its report is not lost.
    pub fn start(self: *Runner) (error{Busy} || std.Thread.SpawnError)!void {
        if (self.state.load(.acquire) == .running) return error.Busy;
        _ = self.poll();
        // No worker is alive here (poll joined it), so writing the snapshot cannot race.
        self.snapshot_fn(self.engine, &self.snapshot);
        self.state.store(.running, .release);
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch |err| {
            self.state.store(.idle, .release);
            return err;
        };
    }

    pub fn isRunning(self: *const Runner) bool {
        return self.state.load(.acquire) == .running;
    }

    /// UI thread, once per frame: returns the new report when a run has just finished, else null. The pointer stays
    /// valid until the next `poll` that returns non-null, or `deinit`.
    pub fn poll(self: *Runner) ?*const CReport {
        if (self.state.load(.acquire) != .done) return null;
        if (self.thread) |thread| thread.join();
        self.thread = null;
        std.mem.swap(*CReport, &self.front, &self.back);
        self.has_report = true;
        self.state.store(.idle, .release);
        return self.front;
    }

    /// The last collected report, or null before the first run finished.
    pub fn latest(self: *const Runner) ?*const CReport {
        return if (self.has_report) self.front else null;
    }

    fn worker(self: *Runner) void {
        self.back.* = std.mem.zeroes(CReport);
        self.run_fn(self.back, &self.snapshot);
        self.state.store(.done, .release);
    }
};

// ---- tests ----

fn setText(dest: []u8, value: []const u8) void {
    @memcpy(dest[0..value.len], value);
    dest[value.len] = 0;
}

fn fakeReport(statuses: []const u32) CReport {
    var report = std.mem.zeroes(CReport);
    for (statuses, 0..) |status, i| {
        report.checks[i].status = status;
        setText(&report.checks[i].title, "check");
    }
    report.count = @intCast(statuses.len);
    return report;
}

test "summarize counts each status and keeps the worst" {
    const report = fakeReport(&.{ status_ok, status_info, status_warn, status_warn, status_fail, status_ok });
    const summary = summarize(&report);
    try std.testing.expectEqual(@as(u32, 6), summary.checks);
    try std.testing.expectEqual(status_fail, summary.worst);
    try std.testing.expectEqual(@as(u32, 2), summary.warnings);
    try std.testing.expectEqual(@as(u32, 1), summary.failures);
    try std.testing.expectEqual(@as(u32, 1), summary.infos);
}

test "summarize clamps count and unknown statuses" {
    var report = fakeReport(&.{ status_ok, 9 });
    report.count = 1000;
    const summary = summarize(&report);
    try std.testing.expectEqual(@as(u32, max_checks), summary.checks);
    try std.testing.expectEqual(status_fail, summary.worst);
    try std.testing.expectEqual(@as(u32, 1), summary.failures);
}

test "indicator text" {
    var buffer: [48]u8 = undefined;
    try std.testing.expectEqualStrings("System OK", try indicatorText(.{}, &buffer));
    try std.testing.expectEqualStrings("System OK", try indicatorText(.{ .infos = 3, .worst = status_info }, &buffer));
    try std.testing.expectEqualStrings("1 warning", try indicatorText(.{ .warnings = 1 }, &buffer));
    try std.testing.expectEqualStrings("3 warnings", try indicatorText(.{ .warnings = 3 }, &buffer));
    try std.testing.expectEqualStrings("1 problem", try indicatorText(.{ .failures = 1 }, &buffer));
    try std.testing.expectEqualStrings("2 problems, 1 warning", try indicatorText(.{ .failures = 2, .warnings = 1 }, &buffer));
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, indicatorText(.{}, &tiny));
}

test "status labels and colours" {
    try std.testing.expectEqualStrings("PASS", statusLabel(status_ok));
    try std.testing.expectEqualStrings("INFO", statusLabel(status_info));
    try std.testing.expectEqualStrings("WARN", statusLabel(status_warn));
    try std.testing.expectEqualStrings("FAIL", statusLabel(status_fail));
    try std.testing.expectEqualStrings("FAIL", statusLabel(77));
    // OK is the signature neon cyan; a failure is red, never cyan.
    try std.testing.expectEqual([3]f32{ 0.000, 0.941, 1.000 }, statusColor(status_ok));
    try std.testing.expect(statusColor(status_fail)[0] > 0.9 and statusColor(status_fail)[1] < 0.5);
    var check = std.mem.zeroes(CCheck);
    check.status = status_info;
    try std.testing.expect(!needsAttention(&check));
    check.status = status_warn;
    try std.testing.expect(needsAttention(&check));
}

const FakeRun = struct {
    var gate: std.atomic.Value(bool) = .init(true);
    var calls: std.atomic.Value(u32) = .init(0);

    var snapshot_thread: std.atomic.Value(std.Thread.Id) = .init(0);

    fn snapshot(engine: ?*anyopaque, out: *CEngineSnapshot) callconv(.c) void {
        snapshot_thread.store(std.Thread.getCurrentId(), .release);
        out.* = std.mem.zeroes(CEngineSnapshot);
        const marker: *u8 = @ptrCast(engine orelse return);
        out.has_engine = 1;
        out.sample_rate = marker.*;
    }

    fn run(out: *CReport, snap: ?*const CEngineSnapshot) callconv(.c) void {
        while (!gate.load(.acquire)) std.atomic.spinLoopHint();
        const n = calls.fetchAdd(1, .acq_rel) + 1;
        out.count = 2;
        out.checks[0].status = status_ok;
        out.checks[1].status = if (snap.?.has_engine != 0) status_fail else status_warn;
        out.checks[1].id = n;
        out.checks[0].fix = snap.?.sample_rate;
    }
};

fn waitForReport(runner: *Runner) !*const CReport {
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) {
        if (runner.poll()) |report| return report;
        std.atomic.spinLoopHint();
    }
    return error.TestTimedOut;
}

test "runner delivers reports from the worker and refuses overlapping runs" {
    FakeRun.calls.store(0, .release);
    FakeRun.gate.store(false, .release);
    var runner = try Runner.init(std.testing.allocator, FakeRun.run, FakeRun.snapshot, null);
    defer runner.deinit();
    try std.testing.expect(runner.latest() == null);
    try std.testing.expect(runner.poll() == null);

    try runner.start();
    try std.testing.expect(runner.isRunning());
    try std.testing.expectError(error.Busy, runner.start());
    try std.testing.expect(runner.poll() == null); // the worker is held at the gate
    FakeRun.gate.store(true, .release);
    const first = try waitForReport(&runner);
    try std.testing.expectEqual(@as(u32, 2), first.count);
    try std.testing.expectEqual(status_warn, first.checks[1].status);
    try std.testing.expectEqual(@as(u32, 1), first.checks[1].id);
    try std.testing.expect(!runner.isRunning());
    try std.testing.expect(runner.latest().? == first);

    try runner.start();
    const second = try waitForReport(&runner);
    try std.testing.expectEqual(@as(u32, 2), second.checks[1].id);
    try std.testing.expectEqual(@as(u32, 2), summarize(second).checks);
}

test "runner snapshots the engine on the starting thread and deinit joins an unfinished run" {
    FakeRun.gate.store(true, .release);
    var engine_marker: u8 = 7;
    var runner = try Runner.init(std.testing.allocator, FakeRun.run, FakeRun.snapshot, &engine_marker);
    try runner.start();
    try std.testing.expectEqual(std.Thread.getCurrentId(), FakeRun.snapshot_thread.load(.acquire));
    engine_marker = 9; // a later change is not seen by the run already started
    const report = try waitForReport(&runner);
    try std.testing.expectEqual(status_fail, report.checks[1].status);
    try std.testing.expectEqual(@as(u32, 7), report.checks[0].fix);
    try runner.start();
    runner.deinit(); // joins; the testing allocator reports any leak
}
