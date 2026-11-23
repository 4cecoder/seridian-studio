// Translated to Zig from pitchpure/crates/pitchpure_engine/src/router.rs (Copyright (c) 2026 the PitchPure authors, MIT). Modified by Seridian.
//! Channel routing between interleaved audio layouts.
//!
//! `Router` reshapes interleaved frames without allocating: passthrough,
//! mono downmix, or mid/side encode. `deinterleave` and `interleave` convert
//! between interleaved blocks and per-channel slices.
//!
//! Seridian: the Rust panics on misuse (zero channels, bad lengths, mid/side
//! with non-stereo); here those are returned as `Error`. `deinterleave`
//! writes into caller-sized slices instead of resizing `Vec`s, so nothing
//! allocates.

const std = @import("std");

pub const Error = error{
    /// `channels == 0`.
    ZeroChannels,
    /// A length is not a multiple of the channel count.
    LengthNotMultiple,
    /// Input and output (or per-channel) lengths differ.
    LengthMismatch,
    /// The number of channel slices differs from `channels`.
    ChannelCountMismatch,
    /// Mid/side routing requires exactly 2 channels.
    MidSideNeedsStereo,
};

/// Channel routing mode applied per frame by `Router.route`.
pub const RouteMode = enum {
    /// Copy input frames to the output unchanged.
    pass_through,
    /// Average all channels into channel 0, zero the rest.
    mono_mix,
    /// Stereo mid/side encode. Requires 2 channels.
    mid_side,
};

/// Stateless channel router for interleaved `f32` frames.
pub const Router = struct {
    channels_: usize,
    mode_: RouteMode,

    /// Create a router for `channel_count` interleaved channels.
    pub fn init(channel_count: usize, route_mode: RouteMode) Error!Router {
        if (channel_count == 0) return error.ZeroChannels;
        return .{ .channels_ = channel_count, .mode_ = route_mode };
    }

    /// Number of interleaved channels this router expects.
    pub fn channels(self: Router) usize {
        return self.channels_;
    }

    /// Routing mode applied by `route`.
    pub fn mode(self: Router) RouteMode {
        return self.mode_;
    }

    /// Route one block of interleaved frames; returns the number of frames.
    ///
    /// - `pass_through`: copies input to output.
    /// - `mono_mix`: per-frame mean into channel 0, other channels zeroed.
    /// - `mid_side`: orthonormal mid/side (`(l + r) / sqrt(2)`,
    ///   `(l - r) / sqrt(2)`), its own inverse.
    pub fn route(self: Router, interleaved_in: []const f32, interleaved_out: []f32) Error!usize {
        const ch = self.channels_;
        if (interleaved_in.len % ch != 0) return error.LengthNotMultiple;
        if (interleaved_out.len % ch != 0) return error.LengthNotMultiple;
        if (interleaved_in.len != interleaved_out.len) return error.LengthMismatch;
        const frames = interleaved_in.len / ch;
        switch (self.mode_) {
            .pass_through => @memcpy(interleaved_out, interleaved_in),
            .mono_mix => {
                const denom: f32 = @floatFromInt(ch);
                for (0..frames) |frame| {
                    const base = frame * ch;
                    var sum: f32 = 0.0;
                    for (interleaved_in[base .. base + ch]) |s| sum += s;
                    interleaved_out[base] = sum / denom;
                    @memset(interleaved_out[base + 1 .. base + ch], 0.0);
                }
            },
            .mid_side => {
                if (ch != 2) return error.MidSideNeedsStereo;
                const k: f32 = std.math.sqrt1_2;
                for (0..frames) |frame| {
                    const left = interleaved_in[2 * frame];
                    const right = interleaved_in[2 * frame + 1];
                    interleaved_out[2 * frame] = (left + right) * k;
                    interleaved_out[2 * frame + 1] = (left - right) * k;
                }
            },
        }
        return frames;
    }
};

/// Split interleaved samples into one slice per channel.
///
/// Seridian: `out[c]` must already be `interleaved.len / channels` long (the
/// Rust resized a `Vec` here).
pub fn deinterleave(interleaved: []const f32, channels: usize, out: []const []f32) Error!void {
    if (channels == 0) return error.ZeroChannels;
    if (out.len != channels) return error.ChannelCountMismatch;
    if (interleaved.len % channels != 0) return error.LengthNotMultiple;
    const frames = interleaved.len / channels;
    for (out) |dst| if (dst.len != frames) return error.LengthMismatch;
    for (out, 0..) |dst, ch| {
        for (dst, 0..) |*v, frame| v.* = interleaved[frame * channels + ch];
    }
}

/// Merge per-channel slices into one interleaved block.
/// Frame `i`, channel `c` is written to `out[i * channels.len + c]`.
pub fn interleave(channels: []const []const f32, out: []f32) Error!void {
    if (channels.len == 0) {
        if (out.len != 0) return error.LengthMismatch;
        return;
    }
    const frames = channels[0].len;
    for (channels[1..]) |channel| {
        if (channel.len != frames) return error.LengthMismatch;
    }
    if (out.len != frames * channels.len) return error.LengthMismatch;
    for (0..frames) |frame| {
        for (channels, 0..) |channel, ch| out[frame * channels.len + ch] = channel[frame];
    }
}

const testing = std.testing;

test "passthrough_identity" {
    const router = try Router.init(2, .pass_through);
    const input = [_]f32{ 1.0, -2.0, 3.5, 4.25, -5.5, 6.0 };
    var output: [input.len]f32 = @splat(0.0);
    const frames = try router.route(&input, &output);
    try testing.expectEqual(@as(usize, 3), frames);
    try testing.expectEqualSlices(f32, &input, &output);
}

test "mono_mix_averages_to_channel_zero" {
    const router = try Router.init(2, .mono_mix);
    const input = [_]f32{ 1.0, 3.0 };
    var output: [2]f32 = @splat(0.0);
    const frames = try router.route(&input, &output);
    try testing.expectEqual(@as(usize, 1), frames);
    try testing.expectEqualSlices(f32, &.{ 2.0, 0.0 }, &output);
}

test "mid_side_roundtrips" {
    const router = try Router.init(2, .mid_side);
    const input = [_]f32{ 1.0, 3.0, -2.0, 0.5, 4.25, -1.75 };
    var encoded: [input.len]f32 = @splat(0.0);
    var decoded: [input.len]f32 = @splat(0.0);
    try testing.expectEqual(@as(usize, 3), try router.route(&input, &encoded));
    try testing.expectEqual(@as(usize, 3), try router.route(&encoded, &decoded));
    for (decoded, input) |got, want| try testing.expect(@abs(got - want) < 1e-6);
}

test "deinterleave_interleave_roundtrip_three_channels" {
    const interleaved = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0 };
    var c0: [3]f32 = @splat(0.0);
    var c1: [3]f32 = @splat(0.0);
    var c2: [3]f32 = @splat(0.0);
    const chans = [_][]f32{ &c0, &c1, &c2 };
    try deinterleave(&interleaved, 3, &chans);
    try testing.expectEqualSlices(f32, &.{ 1.0, 4.0, 7.0 }, &c0);
    try testing.expectEqualSlices(f32, &.{ 2.0, 5.0, 8.0 }, &c1);
    try testing.expectEqualSlices(f32, &.{ 3.0, 6.0, 9.0 }, &c2);
    var back: [interleaved.len]f32 = @splat(0.0);
    const const_chans = [_][]const f32{ &c0, &c1, &c2 };
    try interleave(&const_chans, &back);
    try testing.expectEqualSlices(f32, &interleaved, &back);
}
