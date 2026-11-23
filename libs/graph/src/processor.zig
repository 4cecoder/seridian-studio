// Translated to Zig from soundcraft/crates/dsp/src/lib.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! Graph-side plugin interface.
//!
//! The graph library (layer L3) cannot import `plughost`, so it defines the minimal
//! plugin contract it needs as a vtable: plain function pointers, no strings, one indirect
//! call per block. `plughost`'s plugin wrapper adapts its own instance to this vtable at
//! wiring time (in `session`). Only the subset of SoundCraft's `Plugin` trait that the
//! graph calls is here: prepare, reset, process, latency, tail, transport, all-notes-off,
//! and the control-thread destructor.
//!
//! Real-time rules: `prepare`, `destroy` and any allocation are control-thread only.
//! `reset`, `process`, `latencySamples`, `tailSamples`, `setTransport` and `allNotesOff`
//! run on the audio thread and must not allocate, lock, log or do I/O.

const std = @import("std");

/// Timeline and tempo state handed to a plugin before a block. Mirrors the fields of
/// SoundCraft's `Transport` that the graph uses; `samples` is the timeline position.
pub const Transport = struct {
    playing: bool = false,
    recording: bool = false,
    /// Quarter notes per minute.
    tempo: f64 = 120.0,
    numerator: u32 = 4,
    denominator: u32 = 4,
    /// Timeline position in samples.
    samples: i64 = 0,
};

/// A MIDI message at a sample offset inside the current block.
pub const MidiEvent = struct {
    offset: u32,
    bytes: [3]u8,
};

/// A plugin instance as the graph sees it: an opaque pointer plus its vtable.
/// The owner (plughost, or a test fake) keeps the real object alive while the graph holds it.
pub const Processor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Control thread: prepare for a sample rate, max block size and channel count.
        prepare: *const fn (ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void,
        /// Audio thread: clear internal state (stop, seek).
        reset: *const fn (ptr: *anyopaque) void,
        /// Audio thread: process `frames` samples of planar `io` with the block's MIDI events.
        process: *const fn (ptr: *anyopaque, io: [][]f32, frames: usize, events: []const MidiEvent) void,
        /// Audio thread: latency the plugin adds, in samples.
        latency_samples: *const fn (ptr: *anyopaque) usize,
        /// Audio thread: samples the plugin keeps sounding after its input stops.
        tail_samples: *const fn (ptr: *anyopaque) usize,
        /// Audio thread: new transport state for the next block.
        set_transport: *const fn (ptr: *anyopaque, transport: *const Transport) void,
        /// Audio thread: release every sounding note.
        all_notes_off: *const fn (ptr: *anyopaque) void,
        /// Control thread only: free the instance. Never call on the audio thread.
        destroy: *const fn (ptr: *anyopaque) void,
    };

    pub fn prepare(self: Processor, sample_rate: f32, max_block: usize, channels: usize) void {
        self.vtable.prepare(self.ptr, sample_rate, max_block, channels);
    }

    pub fn reset(self: Processor) void {
        self.vtable.reset(self.ptr);
    }

    pub fn process(self: Processor, io: [][]f32, frames: usize, events: []const MidiEvent) void {
        self.vtable.process(self.ptr, io, frames, events);
    }

    pub fn latencySamples(self: Processor) usize {
        return self.vtable.latency_samples(self.ptr);
    }

    pub fn tailSamples(self: Processor) usize {
        return self.vtable.tail_samples(self.ptr);
    }

    pub fn setTransport(self: Processor, transport: *const Transport) void {
        self.vtable.set_transport(self.ptr, transport);
    }

    pub fn allNotesOff(self: Processor) void {
        self.vtable.all_notes_off(self.ptr);
    }

    /// Control thread only.
    pub fn destroy(self: Processor) void {
        self.vtable.destroy(self.ptr);
    }
};

test "Processor forwards each call through its vtable" {
    const Probe = struct {
        prepared: usize = 0,
        resets: usize = 0,
        processed: usize = 0,
        notes_off: usize = 0,
        destroyed: usize = 0,
        last_transport_samples: i64 = -1,

        fn prepare(ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = sample_rate;
            _ = max_block;
            _ = channels;
            self.prepared += 1;
        }
        fn reset(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.resets += 1;
        }
        fn process(ptr: *anyopaque, io: [][]f32, frames: usize, events: []const MidiEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = io;
            _ = frames;
            _ = events;
            self.processed += 1;
        }
        fn latency(ptr: *anyopaque) usize {
            _ = ptr;
            return 48;
        }
        fn tail(ptr: *anyopaque) usize {
            _ = ptr;
            return 7;
        }
        fn transport(ptr: *anyopaque, t: *const Transport) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last_transport_samples = t.samples;
        }
        fn notesOff(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.notes_off += 1;
        }
        fn destroy(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed += 1;
        }
    };
    const vt: Processor.VTable = .{
        .prepare = Probe.prepare,
        .reset = Probe.reset,
        .process = Probe.process,
        .latency_samples = Probe.latency,
        .tail_samples = Probe.tail,
        .set_transport = Probe.transport,
        .all_notes_off = Probe.notesOff,
        .destroy = Probe.destroy,
    };
    var probe: Probe = .{};
    const p: Processor = .{ .ptr = &probe, .vtable = &vt };

    p.prepare(48_000.0, 512, 2);
    p.reset();
    var l = [_]f32{0};
    var r = [_]f32{0};
    var chans = [_][]f32{ &l, &r };
    p.process(&chans, 1, &.{});
    const t: Transport = .{ .playing = true, .samples = 96_000 };
    p.setTransport(&t);
    p.allNotesOff();

    try std.testing.expectEqual(@as(usize, 1), probe.prepared);
    try std.testing.expectEqual(@as(usize, 1), probe.resets);
    try std.testing.expectEqual(@as(usize, 1), probe.processed);
    try std.testing.expectEqual(@as(usize, 48), p.latencySamples());
    try std.testing.expectEqual(@as(usize, 7), p.tailSamples());
    try std.testing.expectEqual(@as(i64, 96_000), probe.last_transport_samples);
    try std.testing.expectEqual(@as(usize, 1), probe.notes_off);
    try std.testing.expectEqual(@as(usize, 0), probe.destroyed);
    p.destroy();
    try std.testing.expectEqual(@as(usize, 1), probe.destroyed);
}
