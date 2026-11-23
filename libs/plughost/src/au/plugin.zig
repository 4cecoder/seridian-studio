// Translated to Zig from soundcraft/crates/au-host/src/plugin.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! `AuPlugin`: a loaded Audio Unit behind the plug-0 `Plugin` handle (`../plugin.zig`).
//!
//! Wraps one `Instance` (`instance.zig`). The Rust `Plugin` trait had `note_on`, `note_off`,
//! `midi` and `all_notes_off` methods that queued events; here the events arrive as a sorted
//! `[]Event` slice with each `process` call, so there is no queue. Parameters are addressed by
//! dense index, as in `plugin.zig`.
//!
//! Realtime rules: `process` allocates nothing, takes no locks and does no logging. Everything
//! sized (`ids`, `values`, the instance buffers) is built in `init`/`prepare`.
//!
//! No editor: Cocoa `AUCocoaUIBase` views are not hosted (same as the Rust crate). The state is
//! saved through the instance's `StateLink` (`save_state`); the UI-thread `state_reader` entry is
//! left null, see the note above the vtable.

const std = @import("std");
const plug = @import("../plugin.zig");
const instance = @import("instance.zig");

const Plugin = plug.Plugin;
const PluginInfo = plug.PluginInfo;
const AudioBlock = plug.AudioBlock;
const Event = plug.Event;
const Transport = plug.Transport;

const log = std.log.scoped(.plughost_au);

/// Largest MIDI 1.0 data byte (7 bits).
const MIDI_DATA_MAX: u8 = 127;
/// Smallest audible note-on velocity: a velocity of 0 would be a note-off.
const MIDI_VELOCITY_MIN: u8 = 1;
/// Channel-voice status bytes.
const STATUS_NOTE_OFF: u8 = 0x80;
const STATUS_NOTE_ON: u8 = 0x90;
const STATUS_MASK: u8 = 0xF0;
/// Lowest channel-voice status (poly pressure) and the first system status (sysex).
const STATUS_FIRST_CHANNEL_VOICE: u8 = 0xA0;
const STATUS_FIRST_SYSTEM: u8 = 0xF0;

/// Sample rate used when the host gives a non-positive or non-finite one.
const FALLBACK_SAMPLE_RATE: f64 = 48_000.0;

/// A hosted Audio Unit. Parameter ids are the unit's own global-scope `AudioUnitParameterID`s,
/// parsed back from the decimal strings in `info.params`. Values are the unit's own values
/// (names and ranges come from `info.params`).
pub const AuPlugin = struct {
    gpa: std.mem.Allocator,
    /// Owned: `deinit` disposes it.
    inst: *instance.Instance,
    info: *const PluginInfo,
    /// Audio Unit id of each `info.params` entry (same order).
    ids: []u32,
    values: []f32,
    /// Takes audio input (effects); instruments replace the buffer contents.
    has_input: bool,
    /// Accepts MIDI (instruments and music effects).
    takes_midi: bool,
    channels: usize = 2,
    latency: usize = 0,
    tail: usize = 0,

    /// Control thread. Takes ownership of `inst` (destroyed on error and by `deinit`).
    pub fn init(
        gpa: std.mem.Allocator,
        inst: *instance.Instance,
        info: *const PluginInfo,
        has_input: bool,
        takes_midi: bool,
    ) std.mem.Allocator.Error!AuPlugin {
        errdefer inst.destroy();
        const ids = try gpa.alloc(u32, info.params.len);
        errdefer gpa.free(ids);
        const values = try gpa.alloc(f32, info.params.len);
        errdefer gpa.free(values);
        for (info.params, ids, values) |p, *id, *slot| {
            // Rust: `id.parse::<u32>().unwrap_or(u32::MAX)`.
            id.* = std.fmt.parseInt(u32, p.id, 10) catch std.math.maxInt(u32);
            slot.* = if (inst.getParam(id.*)) |v| p.clamp(v) else p.default;
        }
        return .{
            .gpa = gpa,
            .inst = inst,
            .info = info,
            .ids = ids,
            .values = values,
            .has_input = has_input,
            .takes_midi = takes_midi,
        };
    }

    /// Control thread. Disposes the unit and frees the tables.
    pub fn deinit(self: *AuPlugin) void {
        self.inst.destroy();
        self.gpa.free(self.ids);
        self.gpa.free(self.values);
        self.* = undefined;
    }

    /// The plug-0 handle over this instance. Borrowed: the `AuPlugin` must outlive it.
    pub fn plugin(self: *AuPlugin) Plugin {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Re-reads every parameter value from the unit (after a state load). Control thread.
    fn refreshValues(self: *AuPlugin) void {
        for (self.info.params, self.ids, self.values) |p, id, *slot| {
            if (self.inst.getParam(id)) |v| slot.* = p.clamp(v);
        }
    }

    /// Sizes the unit for `sample_rate`, `max_block` frames and `channels` channels, then
    /// re-sends every value so a re-initialized unit matches the session. Control thread.
    pub fn prepare(self: *AuPlugin, sample_rate: f32, max_block: usize, channels: usize) void {
        const sr: f64 = if (std.math.isFinite(sample_rate) and sample_rate > 0.0)
            @as(f64, sample_rate)
        else
            FALLBACK_SAMPLE_RATE;
        // Rust clamps to 64 channels; the planar AudioBlock carries at most `plug.MAX_CHANNELS`.
        self.channels = std.math.clamp(channels, 1, plug.MAX_CHANNELS);
        if (self.inst.configure(sr, max_block, self.channels)) |_| {
            self.latency = self.inst.latency();
            self.tail = self.inst.tail();
        } else |err| {
            log.warn("{s}: {s}", .{ self.info.id, @errorName(err) });
            self.latency = 0;
            self.tail = 0;
        }
        for (self.ids, self.values) |id, v| {
            _ = self.inst.setParam(id, v);
        }
    }

    /// Control thread. Resets the unit's internal state (tails and held notes).
    pub fn reset(self: *AuPlugin) void {
        self.inst.reset();
    }

    /// Sets parameter `index` (clamped into its range). `false` when out of range.
    pub fn setParam(self: *AuPlugin, index: u32, value: f32) bool {
        if (index >= self.info.params.len) return false;
        const v = self.info.params[index].clamp(value);
        self.values[index] = v;
        _ = self.inst.setParam(self.ids[index], v);
        return true;
    }

    /// The last value set for parameter `index`, or null when out of range.
    pub fn getParam(self: *const AuPlugin, index: u32) ?f32 {
        if (index >= self.values.len) return null;
        return self.values[index];
    }

    /// Audio thread. Copies the block into the instance input (effects), applies the events at
    /// their offsets, renders, and copies the output back. Renders in slices of at most the
    /// unit's maximum frame count. Events must be sorted by offset.
    pub fn process(self: *AuPlugin, block: AudioBlock, events: []const Event) void {
        const ch = @min(self.channels, block.n_channels);
        const frames = block.frames;
        if (frames == 0 or ch == 0) return;
        if (!self.inst.isReady()) {
            // Effects pass through; instruments are silent.
            if (!self.has_input) silence(block, ch, 0, frames);
            return;
        }
        const max = self.inst.maxFrames();
        const au_ch = self.inst.channelCount();
        var start: usize = 0;
        var next: usize = 0;
        while (start < frames) {
            const n = @min(frames - start, max);
            const end = start + n;
            if (self.has_input) copyInput(self.inst, block, ch, au_ch, start, n);
            // Events at or after `end` wait for the next slice. Offsets past the block end are
            // clamped onto its last frame, as the Rust host did.
            while (next < events.len) : (next += 1) {
                const at = @min(@as(usize, events[next].offset), frames - 1);
                if (at >= end) break;
                self.sendEvent(events[next], @intCast(at -| start));
            }
            if (self.inst.render(n)) |_| {
                copyOutput(self.inst, block, ch, au_ch, start, n);
            } else |_| {
                // A failed render is silence for instruments and dry signal for effects (the
                // Rust host logged it at debug level; logging is not allowed here).
                if (!self.has_input) silence(block, ch, start, end);
            }
            start = end;
        }
    }

    /// Sends one event into the next render at `offset` frames. Audio thread.
    fn sendEvent(self: *AuPlugin, e: Event, offset: u32) void {
        switch (e.kind) {
            .note_on => |n| {
                if (!self.takes_midi or n.note > MIDI_DATA_MAX) return;
                const vel = std.math.clamp(n.velocity, MIDI_VELOCITY_MIN, MIDI_DATA_MAX);
                _ = self.inst.midi(STATUS_NOTE_ON, n.note, vel, offset);
            },
            .note_off => |note| {
                if (!self.takes_midi or note > MIDI_DATA_MAX) return;
                _ = self.inst.midi(STATUS_NOTE_OFF, note, 0, offset);
            },
            .midi3 => |m| {
                const kind = m[0] & STATUS_MASK;
                if (!self.takes_midi or kind < STATUS_FIRST_CHANNEL_VOICE or kind >= STATUS_FIRST_SYSTEM) return;
                _ = self.inst.midi(m[0], m[1] & MIDI_DATA_MAX, m[2] & MIDI_DATA_MAX, offset);
            },
            .param => |pc| {
                // Not in the Rust trait: a sample-accurate parameter change from the event list.
                if (pc.index >= self.info.params.len) return;
                const v = self.info.params[pc.index].clamp(pc.value);
                self.values[pc.index] = v;
                _ = self.inst.scheduleParamAt(pc.index, v, offset);
            },
        }
    }

    pub fn latencySamples(self: *const AuPlugin) usize {
        return self.latency;
    }

    pub fn tailSamples(self: *const AuPlugin) usize {
        return self.tail;
    }

    /// The unit's `ClassInfo` as a binary property list. Control thread.
    pub fn saveState(self: *AuPlugin, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
        return self.inst.link.saveState(gpa);
    }

    /// Restores a state blob, then re-reads the parameter values. Control thread.
    pub fn loadState(self: *AuPlugin, data: []const u8) bool {
        const ok = self.inst.loadState(data);
        if (ok) self.refreshValues();
        return ok;
    }
};

/// Copies the block's channels `start..start+n` into the unit's input buffers.
/// Audio thread: no allocation.
fn copyInput(inst: *instance.Instance, block: AudioBlock, ch: usize, au_ch: usize, start: usize, n: usize) void {
    for (0..au_ch) |c| {
        const src = block.channels[@min(c, ch - 1)][start .. start + n];
        const dst = inst.inputMut(c) orelse continue;
        if (dst.len < n) continue;
        @memcpy(dst[0..n], src);
    }
}

/// Copies the rendered output into the block's channels `start..start+n`. A mono strip fed by
/// a stereo unit gets the mean of the two outputs. Audio thread: no allocation.
fn copyOutput(inst: *const instance.Instance, block: AudioBlock, ch: usize, au_ch: usize, start: usize, n: usize) void {
    for (0..ch) |c| {
        const dst = block.channels[c][start .. start + n];
        if (ch == 1 and au_ch >= 2) {
            const l = inst.output(0, n) orelse continue;
            const r = inst.output(1, n) orelse continue;
            const m = @min(dst.len, @min(l.len, r.len));
            for (0..m) |k| dst[k] = 0.5 * (l[k] + r[k]);
        } else if (inst.output(@min(c, au_ch -| 1), n)) |src| {
            const m = @min(dst.len, src.len);
            @memcpy(dst[0..m], src[0..m]);
        }
    }
}

/// Zeroes channels `from..to` of the block. Audio thread.
fn silence(block: AudioBlock, ch: usize, from: usize, to: usize) void {
    for (0..ch) |c| @memset(block.channels[c][from..to], 0);
}

// --- plug-0 vtable ---
//
// Optional entries left null (Rust defaults): gain_reduction_db, editor entries (no editor is
// hosted), and state_reader. The Rust state reader handed a UI thread a retained `StateLink`;
// `PluginStateReader` has no release hook yet, so reading state while the audio thread renders
// goes unsupported for now. `save_state` reads the link directly on the control thread.

fn fromPtr(ptr: *anyopaque) *AuPlugin {
    return @ptrCast(@alignCast(ptr));
}

fn infoFn(ptr: *anyopaque) *const PluginInfo {
    return fromPtr(ptr).info;
}

fn prepareFn(ptr: *anyopaque, sample_rate: f32, max_block: usize, channels: usize) void {
    fromPtr(ptr).prepare(sample_rate, max_block, channels);
}

fn resetFn(ptr: *anyopaque) void {
    fromPtr(ptr).reset();
}

fn setParamFn(ptr: *anyopaque, index: u32, value: f32) bool {
    return fromPtr(ptr).setParam(index, value);
}

fn getParamFn(ptr: *anyopaque, index: u32) ?f32 {
    return fromPtr(ptr).getParam(index);
}

fn processFn(ptr: *anyopaque, block: AudioBlock, events: []const Event) void {
    fromPtr(ptr).process(block, events);
}

fn latencyFn(ptr: *anyopaque) usize {
    return fromPtr(ptr).latencySamples();
}

fn tailFn(ptr: *anyopaque) usize {
    return fromPtr(ptr).tailSamples();
}

fn setTransportFn(ptr: *anyopaque, transport: *const Transport) void {
    fromPtr(ptr).inst.setTransport(transport);
}

fn saveStateFn(ptr: *anyopaque, gpa: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
    return fromPtr(ptr).saveState(gpa);
}

fn loadStateFn(ptr: *anyopaque, data: []const u8) bool {
    return fromPtr(ptr).loadState(data);
}

const vtable: Plugin.VTable = .{
    .info = infoFn,
    .prepare = prepareFn,
    .reset = resetFn,
    .set_param = setParamFn,
    .get_param = getParamFn,
    .process = processFn,
    .latency = latencyFn,
    .tail_samples = tailFn,
    .set_transport = setTransportFn,
    .save_state = saveStateFn,
    .load_state = loadStateFn,
};

test "au plugin: the vtable exposes the plug-0 handle shape" {
    const std_testing = std.testing;
    // No instance can be built without an Audio Unit, so this only pins the wiring that does
    // not need one: the optional entries the handle relies on are present.
    try std_testing.expect(vtable.save_state != null);
    try std_testing.expect(vtable.load_state != null);
    try std_testing.expect(vtable.state_reader == null);
    try std_testing.expect(vtable.editor == null);
    try std_testing.expect(vtable.gain_reduction_db == null);
}
