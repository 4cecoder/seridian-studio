// Translated to Zig from pitchpure/crates/pitchpure_engine/src/chain.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Sequential mono render chain over Processor stages.
//!
//! `RenderChain` splits an arbitrary-length mono buffer into fixed-size
//! quanta (`RenderChain.init`), runs every quantum through each stage in
//! order, and stitches the results back together. Two preallocated scratch
//! buffers are ping-ponged between stages so `RenderChain.processMono`
//! performs no allocation after setup.
//!
//! Rust stores `Box<dyn Processor>`; here a stage is a `Stage` (pointer +
//! vtable, one indirect call per block). The chain borrows its stages: the
//! caller owns each stage and keeps it alive (and at a fixed address) for as
//! long as the chain uses it.

const std = @import("std");
const types = @import("types.zig");

/// Type-erased Processor (Rust `Box<dyn Processor>`, but borrowed).
pub const Stage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reset: *const fn (ptr: *anyopaque) void,
        process: *const fn (ptr: *anyopaque, input: []const f32, output: []f32) void,
        latency_samples: *const fn (ptr: *const anyopaque) usize,
    };

    /// Wrap a pointer to any type satisfying the Processor contract.
    pub fn from(comptime T: type, p: *T) Stage {
        types.assertProcessor(T);
        const Gen = struct {
            fn resetImpl(ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.reset();
            }
            fn processImpl(ptr: *anyopaque, input: []const f32, output: []f32) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                self.process(input, output);
            }
            fn latencyImpl(ptr: *const anyopaque) usize {
                const self: *const T = @ptrCast(@alignCast(ptr));
                return types.latencySamples(self);
            }
            const vtable: VTable = .{
                .reset = resetImpl,
                .process = processImpl,
                .latency_samples = latencyImpl,
            };
        };
        return .{ .ptr = p, .vtable = &Gen.vtable };
    }

    pub fn reset(self: Stage) void {
        self.vtable.reset(self.ptr);
    }

    pub fn process(self: Stage, input: []const f32, output: []f32) void {
        self.vtable.process(self.ptr, input, output);
    }

    pub fn latencySamples(self: Stage) usize {
        return self.vtable.latency_samples(self.ptr);
    }
};

pub const InitError = error{ZeroBlockLen} || std.mem.Allocator.Error;
pub const ProcessError = error{LengthMismatch};

/// Sequential chain of mono stages sharing one block quantum.
///
/// Each block of at most `block_len` samples is copied into scratch space,
/// zero-padded to a full block when it is a short tail, pushed through every
/// stage in insertion order, and then truncated back to the block's live
/// length in the output. Stateless pass-through stages therefore produce
/// bit-identical output regardless of where block boundaries fall.
///
/// Owns `scratch_a`, `scratch_b` and the stage list (not the stages);
/// free them with `deinit`.
pub const RenderChain = struct {
    stages: std.ArrayList(Stage),
    block_len: usize,
    scratch_a: []f32,
    scratch_b: []f32,

    /// Create an empty chain with the given processing quantum.
    ///
    /// Both scratch buffers are preallocated here so processing never
    /// allocates; `addStage` only appends the stage itself.
    /// Rust panics on `block_len == 0`; this returns `error.ZeroBlockLen`.
    pub fn init(gpa: std.mem.Allocator, block_len: usize) InitError!RenderChain {
        if (block_len == 0) return error.ZeroBlockLen;
        const scratch_a = try gpa.alloc(f32, block_len);
        errdefer gpa.free(scratch_a);
        const scratch_b = try gpa.alloc(f32, block_len);
        @memset(scratch_a, 0.0);
        @memset(scratch_b, 0.0);
        return .{
            .stages = .empty,
            .block_len = block_len,
            .scratch_a = scratch_a,
            .scratch_b = scratch_b,
        };
    }

    pub fn deinit(self: *RenderChain, gpa: std.mem.Allocator) void {
        self.stages.deinit(gpa);
        gpa.free(self.scratch_a);
        gpa.free(self.scratch_b);
        self.* = undefined;
    }

    /// Append a stage to the end of the chain (control thread only).
    ///
    /// Stages run in insertion order. This may allocate for the stage list
    /// itself; processing afterwards does not allocate.
    pub fn addStage(self: *RenderChain, gpa: std.mem.Allocator, stage: Stage) std.mem.Allocator.Error!void {
        try self.stages.append(gpa, stage);
    }

    /// Process a full mono buffer through every stage in order.
    ///
    /// The input is split into `block_len` chunks; a short final chunk is
    /// zero-padded to a full block for the stages and only its live prefix
    /// is written back, so block boundaries are seamless. An empty chain
    /// copies input to output. Uses only the preallocated scratch buffers.
    /// Rust panics when lengths differ; this returns `error.LengthMismatch`.
    pub fn processMono(self: *RenderChain, input: []const f32, output: []f32) ProcessError!void {
        if (input.len != output.len) return error.LengthMismatch;
        if (input.len == 0) return;
        if (self.stages.items.len == 0) {
            @memcpy(output, input);
            return;
        }
        const block_len = self.block_len;
        const buf_a = self.scratch_a;
        const buf_b = self.scratch_b;
        var offset: usize = 0;
        while (offset < input.len) {
            const n = @min(input.len - offset, block_len);
            @memcpy(buf_a[0..n], input[offset .. offset + n]);
            @memset(buf_a[n..block_len], 0.0);
            var src_is_a = true;
            for (self.stages.items) |stage| {
                if (src_is_a) {
                    stage.process(buf_a[0..block_len], buf_b[0..block_len]);
                } else {
                    stage.process(buf_b[0..block_len], buf_a[0..block_len]);
                }
                src_is_a = !src_is_a;
            }
            if (src_is_a) {
                @memcpy(output[offset .. offset + n], buf_a[0..n]);
            } else {
                @memcpy(output[offset .. offset + n], buf_b[0..n]);
            }
            offset += n;
        }
    }

    /// Sum of every stage's reported latency in samples (0 for an empty chain).
    pub fn totalLatency(self: *const RenderChain) usize {
        var sum: usize = 0;
        for (self.stages.items) |s| sum += s.latencySamples();
        return sum;
    }

    /// Reset every stage in order and clear the scratch buffers.
    pub fn reset(self: *RenderChain) void {
        for (self.stages.items) |stage| stage.reset();
        @memset(self.scratch_a, 0.0);
        @memset(self.scratch_b, 0.0);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

const PassA = struct {
    pub fn reset(self: *PassA) void {
        _ = self;
    }
    pub fn process(self: *PassA, input: []const f32, output: []f32) void {
        _ = self;
        @memcpy(output, input);
    }
};

const PassB = struct {
    pub fn reset(self: *PassB) void {
        _ = self;
    }
    pub fn process(self: *PassB, input: []const f32, output: []f32) void {
        _ = self;
        @memcpy(output, input);
    }
};

const LatencyStub = struct {
    pub fn reset(self: *LatencyStub) void {
        _ = self;
    }
    pub fn process(self: *LatencyStub, input: []const f32, output: []f32) void {
        _ = self;
        @memcpy(output, input);
    }
    pub fn latencySamples(self: *const LatencyStub) usize {
        _ = self;
        return 7;
    }
};

fn sine(gpa: std.mem.Allocator, len: usize, freq_hz: f32, rate_hz: f32) ![]f32 {
    const v = try gpa.alloc(f32, len);
    for (v, 0..) |*s, i| {
        s.* = @sin(2.0 * std.math.pi * freq_hz * @as(f32, @floatFromInt(i)) / rate_hz);
    }
    return v;
}

test "empty_chain_passes_audio_through" {
    const gpa = testing.allocator;
    var chain = try RenderChain.init(gpa, 512);
    defer chain.deinit(gpa);
    const input = try sine(gpa, 1024, 440.0, 48_000.0);
    defer gpa.free(input);
    const output = try gpa.alloc(f32, input.len);
    defer gpa.free(output);
    @memset(output, 0.0);
    try chain.processMono(input, output);
    try testing.expectEqual(input.len, output.len);
    for (input, output) |a, b| try testing.expect(@abs(a - b) < 1e-6);
}

test "two_passthrough_stages_preserve_signal" {
    const gpa = testing.allocator;
    var chain = try RenderChain.init(gpa, 256);
    defer chain.deinit(gpa);
    var pa: PassA = .{};
    var pb: PassB = .{};
    try chain.addStage(gpa, Stage.from(PassA, &pa));
    try chain.addStage(gpa, Stage.from(PassB, &pb));
    const input = try sine(gpa, 1000, 220.0, 48_000.0);
    defer gpa.free(input);
    const output = try gpa.alloc(f32, input.len);
    defer gpa.free(output);
    @memset(output, 0.0);
    try chain.processMono(input, output);
    for (input, output) |a, b| try testing.expect(@abs(a - b) < 1e-6);
}

test "total_latency_sums_stub_stage" {
    const gpa = testing.allocator;
    var chain = try RenderChain.init(gpa, 512);
    defer chain.deinit(gpa);
    var s1: LatencyStub = .{};
    var s2: LatencyStub = .{};
    try testing.expectEqual(@as(usize, 0), chain.totalLatency());
    try chain.addStage(gpa, Stage.from(LatencyStub, &s1));
    try testing.expectEqual(@as(usize, 7), chain.totalLatency());
    try chain.addStage(gpa, Stage.from(LatencyStub, &s2));
    try testing.expectEqual(@as(usize, 14), chain.totalLatency());
}

test "block_splitting_is_seamless" {
    const gpa = testing.allocator;
    const input = try sine(gpa, 1000, 440.0, 48_000.0);
    defer gpa.free(input);
    var pa1: PassA = .{};
    var pb1: PassB = .{};
    var pa2: PassA = .{};
    var pb2: PassB = .{};

    var chunked = try RenderChain.init(gpa, 128);
    defer chunked.deinit(gpa);
    try chunked.addStage(gpa, Stage.from(PassA, &pa1));
    try chunked.addStage(gpa, Stage.from(PassB, &pb1));
    const chunked_out = try gpa.alloc(f32, input.len);
    defer gpa.free(chunked_out);
    @memset(chunked_out, 0.0);
    try chunked.processMono(input, chunked_out);

    var single = try RenderChain.init(gpa, input.len);
    defer single.deinit(gpa);
    try single.addStage(gpa, Stage.from(PassA, &pa2));
    try single.addStage(gpa, Stage.from(PassB, &pb2));
    const single_out = try gpa.alloc(f32, input.len);
    defer gpa.free(single_out);
    @memset(single_out, 0.0);
    try single.processMono(input, single_out);

    for (0..input.len) |i| {
        try testing.expect(@abs(chunked_out[i] - single_out[i]) < 1e-5);
        try testing.expect(@abs(chunked_out[i] - input[i]) < 1e-5);
    }
}

test "zero_block_len_panics" {
    // Rust #[should_panic]; the Zig init returns an error instead.
    try testing.expectError(error.ZeroBlockLen, RenderChain.init(testing.allocator, 0));
}

test "mismatched_lengths_panic" {
    // Rust #[should_panic]; the Zig processMono returns an error instead.
    const gpa = testing.allocator;
    var chain = try RenderChain.init(gpa, 64);
    defer chain.deinit(gpa);
    const input: [64]f32 = @splat(0.0);
    var output: [63]f32 = @splat(0.0);
    try testing.expectError(error.LengthMismatch, chain.processMono(&input, &output));
}

test "reset_clears_state_without_panicking" {
    const gpa = testing.allocator;
    var chain = try RenderChain.init(gpa, 64);
    defer chain.deinit(gpa);
    var pa: PassA = .{};
    try chain.addStage(gpa, Stage.from(PassA, &pa));
    const input = try sine(gpa, 100, 440.0, 48_000.0);
    defer gpa.free(input);
    const output = try gpa.alloc(f32, input.len);
    defer gpa.free(output);
    @memset(output, 0.0);
    try chain.processMono(input, output);
    chain.reset();
    try chain.processMono(input, output);
    for (input, output) |a, b| try testing.expect(@abs(a - b) < 1e-6);
}
