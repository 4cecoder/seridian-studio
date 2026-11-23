//! Platform-aware test framework
//!
//! This module provides compile-time platform detection and runtime backend
//! availability checks to ensure tests only run for available backends.
//!
//! Design:
//! - Compile-time platform detection (Linux/macOS/Windows)
//! - Runtime backend availability detection (PulseAudio/PipeWire/CoreAudio/WASAPI)
//! - Graceful test skipping when backends are unavailable
//! - Clear reporting of which tests were run vs skipped
//!
//! Usage:
//!   const platform_config = @import("platform_config.zig");
//!
//!   pub fn main() !void {
//!       var runner = platform_config.TestRunner.init(allocator);
//!       defer runner.deinit();
//!
//!       try runner.run();
//!       runner.printReport();
//!   }

const std = @import("std");
const builtin = @import("builtin");

/// Current platform being tested
pub const Platform = enum {
    linux,
    macos,
    windows,
    unknown,

    /// Get the current platform at compile time
    pub fn current() Platform {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            else => .unknown,
        };
    }

    /// Get platform name as string
    pub fn name(self: Platform) []const u8 {
        return switch (self) {
            .linux => "Linux",
            .macos => "macOS",
            .windows => "Windows",
            .unknown => "Unknown",
        };
    }
};

/// Audio backend types
pub const Backend = enum {
    pulseaudio,
    pipewire,
    coreaudio,
    wasapi,

    /// Get backend name as string
    pub fn name(self: Backend) []const u8 {
        return switch (self) {
            .pulseaudio => "PulseAudio",
            .pipewire => "PipeWire",
            .coreaudio => "CoreAudio",
            .wasapi => "WASAPI",
        };
    }

    /// Check if this backend is available on the current platform
    pub fn isAvailableOnPlatform(self: Backend, platform: Platform) bool {
        return switch (self) {
            .pulseaudio => platform == .linux,
            .pipewire => platform == .linux,
            .coreaudio => platform == .macos,
            .wasapi => platform == .windows,
        };
    }

    /// Detect if this backend is available at runtime
    pub fn detectRuntime(self: Backend) bool {
        return switch (self) {
            .pulseaudio => detectPulseAudio(),
            .pipewire => detectPipeWire(),
            .coreaudio => detectCoreAudio(),
            .wasapi => detectWASAPI(),
        };
    }
};

/// Test result status
pub const TestResult = enum {
    passed,
    failed,
    skipped,

    pub fn name(self: TestResult) []const u8 {
        return switch (self) {
            .passed => "PASSED",
            .failed => "FAILED",
            .skipped => "SKIPPED",
        };
    }
};

/// Individual test case
pub const TestCase = struct {
    name: []const u8,
    backend: Backend,
    test_fn: *const fn () anyerror!void,
    result: TestResult = .skipped,
    error_msg: ?[]const u8 = null,

    /// Run this test case
    pub fn run(self: *TestCase, platform: Platform) void {
        // Check if backend is available on this platform
        if (!self.backend.isAvailableOnPlatform(platform)) {
            self.result = .skipped;
            self.error_msg = "Backend not available on this platform";
            return;
        }

        // Check if backend is available at runtime
        if (!self.backend.detectRuntime()) {
            self.result = .skipped;
            self.error_msg = "Backend not detected at runtime";
            return;
        }

        // Run the test
        self.test_fn() catch |err| {
            self.result = .failed;
            self.error_msg = @errorName(err);
            return;
        };

        self.result = .passed;
    }
};

/// Test runner that manages all test cases
pub const TestRunner = struct {
    allocator: std.mem.Allocator,
    platform: Platform,
    tests: std.ArrayListUnmanaged(TestCase),
    timer: std.time.Timer,

    pub fn init(allocator: std.mem.Allocator) !TestRunner {
        return TestRunner{
            .allocator = allocator,
            .platform = Platform.current(),
            .tests = .{},
            .timer = try std.time.Timer.start(),
        };
    }

    pub fn deinit(self: *TestRunner) void {
        self.tests.deinit(self.allocator);
    }

    /// Add a test case to the runner
    pub fn addTest(
        self: *TestRunner,
        name: []const u8,
        backend: Backend,
        test_fn: *const fn () anyerror!void,
    ) !void {
        try self.tests.append(self.allocator, TestCase{
            .name = name,
            .backend = backend,
            .test_fn = test_fn,
        });
    }

    /// Run all registered tests
    pub fn run(self: *TestRunner) void {
        std.debug.print("\n" ++ &@as([70]u8, @splat('=')) ++ "\n", .{});
        std.debug.print("Platform-Aware Test Runner\n", .{});
        std.debug.print("Platform: {s}\n", .{self.platform.name()});
        std.debug.print(&@as([70]u8, @splat('=')) ++ "\n\n", .{});

        // Detect available backends
        std.debug.print("Detecting available backends...\n", .{});
        const backends = [_]Backend{ .pulseaudio, .pipewire, .coreaudio, .wasapi };
        for (backends) |backend| {
            if (backend.isAvailableOnPlatform(self.platform)) {
                const available = backend.detectRuntime();
                std.debug.print("  {s}: {s}\n", .{
                    backend.name(),
                    if (available) "✓ Available" else "✗ Not detected",
                });
            }
        }
        std.debug.print("\n", .{});

        // Run tests
        std.debug.print("Running tests...\n\n", .{});
        for (self.tests.items) |*test_case| {
            std.debug.print("[{s}] {s}...", .{ test_case.backend.name(), test_case.name });
            test_case.run(self.platform);

            const status = switch (test_case.result) {
                .passed => " \x1b[32m✓ PASSED\x1b[0m\n",
                .failed => " \x1b[31m✗ FAILED\x1b[0m\n",
                .skipped => " \x1b[33m⊘ SKIPPED\x1b[0m\n",
            };
            std.debug.print("{s}", .{status});

            if (test_case.error_msg) |msg| {
                std.debug.print("    Reason: {s}\n", .{msg});
            }
        }
    }

    /// Print test summary report
    pub fn printReport(self: *TestRunner) void {
        const duration_ns = self.timer.read();
        const duration_ms = duration_ns / std.time.ns_per_ms;

        var passed: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;

        for (self.tests.items) |test_case| {
            switch (test_case.result) {
                .passed => passed += 1,
                .failed => failed += 1,
                .skipped => skipped += 1,
            }
        }

        std.debug.print("\n" ++ &@as([70]u8, @splat('=')) ++ "\n", .{});
        std.debug.print("Test Summary\n", .{});
        std.debug.print(&@as([70]u8, @splat('=')) ++ "\n", .{});
        std.debug.print("Total tests:   {d}\n", .{self.tests.items.len});
        std.debug.print("\x1b[32mPassed:        {d}\x1b[0m\n", .{passed});
        std.debug.print("\x1b[31mFailed:        {d}\x1b[0m\n", .{failed});
        std.debug.print("\x1b[33mSkipped:       {d}\x1b[0m\n", .{skipped});
        std.debug.print("Duration:      {d}ms\n", .{duration_ms});
        std.debug.print(&@as([70]u8, @splat('=')) ++ "\n\n", .{});

        // Exit with failure if any tests failed
        if (failed > 0) {
            std.process.exit(1);
        }
    }

    /// Get list of tests that should run on the current platform
    pub fn getExpectedTests(self: *TestRunner) !std.ArrayListUnmanaged([]const u8) {
        var expected: std.ArrayListUnmanaged([]const u8) = .{};

        for (self.tests.items) |test_case| {
            if (test_case.backend.isAvailableOnPlatform(self.platform)) {
                try expected.append(self.allocator, test_case.name);
            }
        }

        return expected;
    }
};

// =============================================================================
// Backend Detection Functions
// =============================================================================

/// Detect PulseAudio availability at runtime
fn detectPulseAudio() bool {
    if (builtin.os.tag != .linux) return false;

    // Try to execute pactl info
    var child = std.process.Child.init(
        &[_][]const u8{ "pactl", "info" },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Detect PipeWire availability at runtime
fn detectPipeWire() bool {
    if (builtin.os.tag != .linux) return false;

    // Check for PipeWire runtime directory
    if (std.posix.getenv("PIPEWIRE_RUNTIME_DIR")) |_| {
        return true;
    }

    // Try to execute pw-cli
    var child = std.process.Child.init(
        &[_][]const u8{ "pw-cli", "ls", "Node" },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = child.spawnAndWait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// Detect CoreAudio availability at runtime
fn detectCoreAudio() bool {
    if (builtin.os.tag != .macos) return false;

    // On macOS, CoreAudio is always available as it's part of the system
    return true;
}

/// Detect WASAPI availability at runtime
fn detectWASAPI() bool {
    if (builtin.os.tag != .windows) return false;

    // On Windows, WASAPI is always available as it's part of the system
    // TODO: Implement actual WASAPI detection when Windows support is added
    return true;
}

// =============================================================================
// Platform-specific test configurations
// =============================================================================

/// Get the list of tests that should run on Linux
pub fn getLinuxTests() []const Backend {
    return &[_]Backend{ .pulseaudio, .pipewire };
}

/// Get the list of tests that should run on macOS
pub fn getMacOSTests() []const Backend {
    return &[_]Backend{.coreaudio};
}

/// Get the list of tests that should run on Windows
pub fn getWindowsTests() []const Backend {
    return &[_]Backend{.wasapi};
}

/// Get the list of tests for the current platform
pub fn getCurrentPlatformTests() []const Backend {
    return switch (Platform.current()) {
        .linux => getLinuxTests(),
        .macos => getMacOSTests(),
        .windows => getWindowsTests(),
        .unknown => &[_]Backend{},
    };
}

// =============================================================================
// Test helpers
// =============================================================================

/// Skip a test with a message
pub fn skipTest(comptime reason: []const u8) error{SkipZigTest} {
    _ = reason;
    return error.SkipZigTest;
}

/// Assert that a backend is available, or skip the test
pub fn requireBackend(backend: Backend) !void {
    const platform = Platform.current();

    if (!backend.isAvailableOnPlatform(platform)) {
        return error.SkipZigTest;
    }

    if (!backend.detectRuntime()) {
        return error.SkipZigTest;
    }
}

// =============================================================================
// Tests for the test framework itself
// =============================================================================

test "Platform detection works" {
    const platform = Platform.current();
    try std.testing.expect(platform != .unknown);
}

test "Backend platform availability check" {
    const platform = Platform.current();

    switch (platform) {
        .linux => {
            try std.testing.expect(Backend.pulseaudio.isAvailableOnPlatform(platform));
            try std.testing.expect(Backend.pipewire.isAvailableOnPlatform(platform));
            try std.testing.expect(!Backend.coreaudio.isAvailableOnPlatform(platform));
            try std.testing.expect(!Backend.wasapi.isAvailableOnPlatform(platform));
        },
        .macos => {
            try std.testing.expect(!Backend.pulseaudio.isAvailableOnPlatform(platform));
            try std.testing.expect(!Backend.pipewire.isAvailableOnPlatform(platform));
            try std.testing.expect(Backend.coreaudio.isAvailableOnPlatform(platform));
            try std.testing.expect(!Backend.wasapi.isAvailableOnPlatform(platform));
        },
        .windows => {
            try std.testing.expect(!Backend.pulseaudio.isAvailableOnPlatform(platform));
            try std.testing.expect(!Backend.pipewire.isAvailableOnPlatform(platform));
            try std.testing.expect(!Backend.coreaudio.isAvailableOnPlatform(platform));
            try std.testing.expect(Backend.wasapi.isAvailableOnPlatform(platform));
        },
        .unknown => {},
    }
}

test "Backend runtime detection doesn't crash" {
    // Just verify detection functions don't crash
    _ = detectPulseAudio();
    _ = detectPipeWire();
    _ = detectCoreAudio();
    _ = detectWASAPI();
}

test "Current platform tests are correct" {
    const tests = getCurrentPlatformTests();
    const platform = Platform.current();

    for (tests) |backend| {
        try std.testing.expect(backend.isAvailableOnPlatform(platform));
    }
}
